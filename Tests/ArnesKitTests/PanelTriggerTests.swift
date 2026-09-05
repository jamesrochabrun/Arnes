import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// P2 — the Kit side of `arnes do --verify X --panel-on-fail N`: a `PanelRunner` whose candidates
/// are tagged (`candidateAgent` → every candidate record's `agent`, `label` → every eval row's
/// `label`), a runner without the two byte-identical to today, and the revert-then-mirror
/// sequence the trigger performs over three directories (pre-run `base`, the failed attempt in
/// `work`, the working tree) as a unit test — no CLI, no network.
final class PanelTriggerTests: XCTestCase {
  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-panel-trigger-\(label)-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tempStores() -> (EvalStore, RunRecordStore) {
    let base = FileManager.default.temporaryDirectory
    return (
      EvalStore(url: base.appendingPathComponent("arnes-panel-trigger-evals-\(UUID().uuidString).jsonl")),
      RunRecordStore(url: base.appendingPathComponent("arnes-panel-trigger-runs-\(UUID().uuidString).jsonl")))
  }

  /// Two candidates that each write `answer.txt`; the judge picks beta.
  private func mockPanel() -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/alpha"),
      Fixtures.manifestModel(id: "test/beta"))
    mock.chunkScriptsByModel = [
      "test/alpha": [
        [
          Fixtures.toolCallChunk(
            id: "a1", name: "write_file",
            arguments: #"{"path": "answer.txt", "content": "alpha attempt"}"#),
          Fixtures.usageChunk(cost: 0.01),
        ],
        [Fixtures.textChunk("alpha done"), Fixtures.usageChunk(cost: 0.01)],
      ],
      "test/beta": [
        [
          Fixtures.toolCallChunk(
            id: "b1", name: "write_file",
            arguments: #"{"path": "answer.txt", "content": "beta attempt"}"#),
          Fixtures.usageChunk(cost: 0.02),
        ],
        [Fixtures.textChunk("beta done"), Fixtures.usageChunk(cost: 0.02)],
      ],
    ]
    mock.chatResponses = [
      Fixtures.textResponse(#"{"winner": 2, "reasons": ["beta's change matches the task."]}"#, cost: 0.001),
    ]
    return mock
  }

  // MARK: Tagging

  func testTaggedRunnerMarksEveryCandidateRecordAndLabelsEveryRow() async throws {
    let base = try tempDir("tagged")
    defer { try? FileManager.default.removeItem(at: base) }
    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mockPanel(), recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60,
      candidateAgent: "panel-on-fail", label: "verifier-fail")
    let result = try await runner.run(
      task: "write answer.txt",
      models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertEqual(result.winner.model, "test/beta")
    let records = try recordStore.all()
    XCTAssertEqual(records.count, 2)
    XCTAssertTrue(records.allSatisfy { $0.agent == "panel-on-fail" }, "\(records.map(\.agent))")
    let rows = try evalStore.all()
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows.allSatisfy { $0.label == "verifier-fail" }, "\(rows.map(\.label))")
    XCTAssertTrue(rows.allSatisfy { $0.suite == "panel" })
    // The row is what `arnes evals show --suite panel --label verifier-fail` reads back.
    let encoded = String(decoding: try JSONEncoder().encode(rows[0]), as: UTF8.self)
    XCTAssertTrue(encoded.contains(#""label":"verifier-fail""#), encoded)
  }

  func testUntaggedRunnerRecordsAndRowsAreByteIdenticalToToday() async throws {
    let base = try tempDir("untagged")
    defer { try? FileManager.default.removeItem(at: base) }
    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mockPanel(), recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    _ = try await runner.run(
      task: "write answer.txt",
      models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertTrue(try recordStore.all().allSatisfy { $0.agent == nil }, "a plain --panel's candidates carry no agent tag")
    let rows = try evalStore.all()
    XCTAssertEqual(rows.count, 2)
    XCTAssertTrue(rows.allSatisfy { $0.label == nil })
    let encoded = String(decoding: try JSONEncoder().encode(rows[0]), as: UTF8.self)
    XCTAssertFalse(encoded.contains("\"label\""), "an unlabelled row writes no key: \(encoded)")
  }

  // MARK: The revert-then-mirror sequence

  /// The trigger's moves over three directories: the pre-run `base` snapshot, the failed attempt
  /// kept in `work`, and the working tree — reverted to `base`, then mirrored from the winner.
  /// `WorkspaceSnapshot.apply` would have listed the failed run's edits as conflicts and left
  /// them in place; `sync` is the mirror that makes the winner's tree the working tree.
  func testRevertToBaseThenMirrorWinnerReplacesTheFailedAttempt() async throws {
    let temp = try tempDir("sequence")
    defer { try? FileManager.default.removeItem(at: temp) }
    let cwd = temp.appendingPathComponent("cwd")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    try "original".write(to: cwd.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: cwd.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "ref".write(to: cwd.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

    // Before the run: the pre-run snapshot.
    let layout = WorkspaceSnapshot.Layout(leadId: "LEAD1234ABCD", runId: "RUN5678EFGH", temporaryDirectory: temp)
    try layout.createDirectories()
    try WorkspaceSnapshot.snapshot(of: cwd, to: layout.base)
    XCTAssertEqual(try String(contentsOf: layout.base.appendingPathComponent("state.txt"), encoding: .utf8), "original")

    // The failed run dirties the tree: an edit and an extra file.
    try "broken".write(to: cwd.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)
    try "junk".write(to: cwd.appendingPathComponent("failed.txt"), atomically: true, encoding: .utf8)

    // 1. Keep the failed attempt beside the base.
    try WorkspaceSnapshot.snapshot(of: cwd, to: layout.work)
    XCTAssertEqual(try String(contentsOf: layout.work.appendingPathComponent("failed.txt"), encoding: .utf8), "junk")
    XCTAssertNotNil(WorkspaceSnapshot.Layout.resolve(layout.directory, temporaryDirectory: temp),
                    "the layout is what `arnes agents apply` accepts")

    // 2. Revert the working tree to the pre-run base.
    try WorkspaceSnapshot.sync(from: layout.base, into: cwd)
    XCTAssertEqual(try String(contentsOf: cwd.appendingPathComponent("state.txt"), encoding: .utf8), "original")
    XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("failed.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: cwd.appendingPathComponent(".git/HEAD").path), ".git untouched")

    // 3. The panel over the base, the winner kept in its snapshot.
    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mockPanel(), recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60,
      candidateAgent: "panel-on-fail", label: "verifier-fail")
    let result = try await runner.run(
      task: "write answer.txt",
      models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge",
      baseDirectory: layout.base,
      apply: false)
    XCTAssertFalse(result.applied)
    let winnerDirectory = try XCTUnwrap(result.winnerDirectory)
    XCTAssertEqual(try String(contentsOf: winnerDirectory.appendingPathComponent("answer.txt"), encoding: .utf8), "beta attempt")
    // The base is the reference, never written by a candidate.
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.base.appendingPathComponent("answer.txt").path))

    // 4. Mirror the winner into the pristine working tree.
    try WorkspaceSnapshot.sync(from: winnerDirectory, into: cwd)
    XCTAssertEqual(try String(contentsOf: cwd.appendingPathComponent("answer.txt"), encoding: .utf8), "beta attempt")
    XCTAssertEqual(try String(contentsOf: cwd.appendingPathComponent("state.txt"), encoding: .utf8), "original")
    XCTAssertFalse(FileManager.default.fileExists(atPath: cwd.appendingPathComponent("failed.txt").path),
                   "the failed run's extra file does not survive under the winner's")
    XCTAssertTrue(FileManager.default.fileExists(atPath: cwd.appendingPathComponent(".git/HEAD").path))

    // The failed attempt is still whole in `work`, and `arnes agents apply <layout>` restores it:
    // the working tree still has base's bytes where the failed run changed them.
    let report = try WorkspaceSnapshot.apply(from: layout.work, base: layout.base, into: cwd)
    XCTAssertEqual(report.applied.sorted(), ["failed.txt", "state.txt"])
    // The winner's own file is neither in `work` nor in `base`: `apply` never visits it, so it stays.
    XCTAssertTrue(report.conflicts.isEmpty, "\(report.conflicts)")
    XCTAssertEqual(try String(contentsOf: cwd.appendingPathComponent("answer.txt"), encoding: .utf8), "beta attempt")
    XCTAssertEqual(try String(contentsOf: cwd.appendingPathComponent("state.txt"), encoding: .utf8), "broken")
    XCTAssertEqual(try String(contentsOf: cwd.appendingPathComponent("failed.txt"), encoding: .utf8), "junk")
  }

  // MARK: Re-verification pricing

  func testVerifierPricingBooksTheRoutersCostElseTheEstimateOnAnEstimatingProvider() async throws {
    func usage(_ json: String) throws -> Usage { try JSONDecoder().decode(Usage.self, from: Data(json.utf8)) }
    let reported = try usage(#"{"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15, "cost": 0.25}"#)
    let unpriced = try usage(#"{"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}"#)
    let openrouter = await PanelRunner.verifierPricing(for: "test/model", catalog: nil, provider: .openrouter)
    let reportedCost = await openrouter(reported)
    XCTAssertEqual(reportedCost, 0.25)
    let unreported = await openrouter(unpriced)
    XCTAssertNil(unreported, "OpenRouter reports cost; nothing to estimate")
    let none = await openrouter(nil)
    XCTAssertNil(none)
  }

  // MARK: Layout.remove (batch-16 housekeeping)

  /// The one removal every snapshot owner uses — the isolated subagent's `[snapshot: no changes]`,
  /// a blocked or cancelled spawn, `Do.removeLayout`: the run directory goes, and the
  /// `arnes-agent-<lead>` parent goes only once it is empty (a sibling run's layout keeps it).
  func testLayoutRemoveSweepsAnEmptiedParentAndKeepsAPopulatedOne() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-layout-remove-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let first = WorkspaceSnapshot.Layout(leadId: "LEAD-ASK-1111", runId: "RUN-A", temporaryDirectory: temp)
    let second = WorkspaceSnapshot.Layout(leadId: "LEAD-ASK-1111", runId: "RUN-B", temporaryDirectory: temp)
    try first.createDirectories()
    try second.createDirectories()
    let parent = first.directory.deletingLastPathComponent()
    XCTAssertEqual(parent, second.directory.deletingLastPathComponent(), "one lead, one parent")
    XCTAssertTrue(parent.lastPathComponent.hasPrefix("arnes-agent-lead-ask"))

    first.remove()
    XCTAssertFalse(FileManager.default.fileExists(atPath: first.directory.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: parent.path), "the sibling run still lives there")

    second.remove()
    XCTAssertFalse(FileManager.default.fileExists(atPath: second.directory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path), "an emptied arnes-agent-<lead> directory goes with its last run")

    // Idempotent, and harmless on a layout that was never created.
    second.remove()
    WorkspaceSnapshot.Layout(leadId: "never", runId: "made", temporaryDirectory: temp).remove()
  }
}
