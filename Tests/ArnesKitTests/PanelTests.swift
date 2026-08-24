import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class PanelTests: XCTestCase {
  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-panel-test-\(label)-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tempStores() -> (EvalStore, RunRecordStore) {
    let base = FileManager.default.temporaryDirectory
    return (
      EvalStore(url: base.appendingPathComponent("arnes-panel-evals-\(UUID().uuidString).jsonl")),
      RunRecordStore(url: base.appendingPathComponent("arnes-panel-runs-\(UUID().uuidString).jsonl")))
  }

  // MARK: Root-bound tools

  func testRootBoundToolsResolveRelativePathsAndBashRunsThere() async throws {
    let root = try tempDir("tools")
    defer { try? FileManager.default.removeItem(at: root) }

    _ = try await WriteFileTool(root: root).execute(
      arguments: ["path": "sub/note.txt", "content": "v1"])
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("sub/note.txt"), encoding: .utf8),
      "v1")

    let read = try await ReadFileTool(root: root).execute(arguments: ["path": "sub/note.txt"])
    XCTAssertTrue(read.contains("v1"))

    let edit = try await EditFileTool(root: root).execute(
      arguments: ["path": "sub/note.txt", "old_string": "v1", "new_string": "v2"])
    XCTAssertTrue(edit.hasPrefix("edited"), edit)

    let pwd = try await BashTool(root: root).execute(arguments: ["command": "pwd"])
    XCTAssertTrue(pwd.contains(root.path), pwd)

    let grep = try await GrepTool(root: root).execute(arguments: ["pattern": "v2"])
    XCTAssertTrue(grep.contains("note.txt"), grep)

    let glob = try await GlobTool(root: root).execute(arguments: ["pattern": "*.txt"])
    XCTAssertTrue(glob.contains("sub/note.txt"), glob)
  }

  // MARK: Verdict parsing

  func testParseWinner() {
    XCTAssertEqual(PanelRunner.parseWinner("WINNER: 2 — better diff"), 2)
    XCTAssertEqual(PanelRunner.parseWinner("Some preamble.\nwinner: 13\nmore"), 13)
    XCTAssertNil(PanelRunner.parseWinner("I cannot decide."))
    XCTAssertNil(PanelRunner.parseWinner("WINNER: none"))
  }

  // MARK: Sync

  func testSyncMirrorsWinnerIncludingDeletionsButKeepsGit() throws {
    let source = try tempDir("sync-src")
    let destination = try tempDir("sync-dst")
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: destination)
    }
    try "new".write(to: source.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
    try "same".write(to: source.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
    try "same".write(to: destination.appendingPathComponent("kept.txt"), atomically: true, encoding: .utf8)
    try "old".write(to: destination.appendingPathComponent("removed.txt"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(
      at: destination.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "ref".write(
      to: destination.appendingPathComponent(".git/HEAD"), atomically: true, encoding: .utf8)

    try PanelRunner.sync(from: source, into: destination)

    XCTAssertEqual(
      try String(contentsOf: destination.appendingPathComponent("added.txt"), encoding: .utf8),
      "new")
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("kept.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("removed.txt").path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(".git/HEAD").path))
  }

  // MARK: Full panel run

  func testPanelJudgesAppliesWinnerAndLabelsOutcomes() async throws {
    let base = try tempDir("panel-base")
    defer { try? FileManager.default.removeItem(at: base) }
    try "original".write(to: base.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/alpha"),
      Fixtures.manifestModel(id: "test/beta"))
    // Candidates run concurrently, so scripts are keyed by model to stay deterministic.
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
      Fixtures.textResponse("WINNER: 2 — beta's change matches the task.", cost: 0.001),
    ]

    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    let result = try await runner.run(
      task: "write answer.txt",
      models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertEqual(result.verdict.winnerIndex, 1)
    XCTAssertEqual(result.winner.model, "test/beta")
    XCTAssertTrue(result.applied)
    // The winner's work landed in the base directory; existing files survived.
    XCTAssertEqual(
      try String(contentsOf: base.appendingPathComponent("answer.txt"), encoding: .utf8),
      "beta attempt")
    XCTAssertEqual(
      try String(contentsOf: base.appendingPathComponent("state.txt"), encoding: .utf8),
      "original")
    // Both candidates produced judgeable diffs against the base.
    XCTAssertTrue(result.candidates.allSatisfy { !$0.diff.isEmpty })
    // Labeled eval rows: the winner is the positive label.
    let outcomes = try evalStore.all()
    XCTAssertEqual(outcomes.count, 2)
    XCTAssertTrue(outcomes.allSatisfy { $0.suite == "panel" })
    XCTAssertEqual(outcomes.first { $0.model == "test/beta" }?.checkPassed, true)
    XCTAssertEqual(outcomes.first { $0.model == "test/alpha" }?.checkPassed, false)
    // Every candidate run fed the RunRecord scoreboard too.
    XCTAssertEqual(try recordStore.all().count, 2)
  }

  func testPanelSingleSurvivorWinsWithoutJudge() async throws {
    let base = try tempDir("panel-survivor")
    defer { try? FileManager.default.removeItem(at: base) }

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/broken"),
      Fixtures.manifestModel(id: "test/working"))
    // test/broken has no script → its stream throws; test/working completes.
    mock.chunkScriptsByModel = [
      "test/working": [
        [
          Fixtures.toolCallChunk(
            id: "w1", name: "write_file",
            arguments: #"{"path": "out.txt", "content": "done"}"#),
          Fixtures.usageChunk(cost: 0.01),
        ],
        [Fixtures.textChunk("finished"), Fixtures.usageChunk(cost: 0.01)],
      ],
    ]

    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    let result = try await runner.run(
      task: "write out.txt",
      models: ["test/broken", "test/working"],
      judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertEqual(result.verdict.winnerIndex, 1)
    XCTAssertEqual(result.verdict.judgeCostUSD, 0)
    XCTAssertEqual(result.verdict.reason, "only surviving candidate")
    XCTAssertEqual(
      try String(contentsOf: base.appendingPathComponent("out.txt"), encoding: .utf8),
      "done")
    let outcomes = try evalStore.all()
    XCTAssertEqual(outcomes.count, 2)
    XCTAssertNotNil(outcomes.first { $0.model == "test/broken" }?.error)
  }
}
