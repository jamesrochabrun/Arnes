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

  /// The prose read is the judge's last resort now (V1) — it lives with the judge in `Verifier`.
  func testParseWinner() {
    XCTAssertEqual(Verifier.parseWinner("WINNER: 2 — better diff"), 2)
    XCTAssertEqual(Verifier.parseWinner("Some preamble.\nwinner: 13\nmore"), 13)
    XCTAssertNil(Verifier.parseWinner("I cannot decide."))
    XCTAssertNil(Verifier.parseWinner("WINNER: none"))
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
      Fixtures.textResponse(#"{"winner": 2, "reasons": ["beta's change matches the task."]}"#, cost: 0.001),
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
    XCTAssertEqual(result.verdict.reason, "attempt 2 (test/beta) — beta's change matches the task.")
    XCTAssertEqual(result.verdict.judgeCostUSD, 0.001, accuracy: 0.000001, "the router's figure, through the priced closure")
    XCTAssertTrue(result.applied)
    // The judge saw one structured request over both attempts' reports and diffs — no tools.
    let judgeRequest = try XCTUnwrap(mock.requests.first { $0.model == "test/judge" })
    XCTAssertNil(judgeRequest.tools)
    let judgeText = judgeRequest.messages.last?.content?.plainText ?? ""
    XCTAssertTrue(judgeText.contains("## Attempt 1 (test/alpha)"), judgeText)
    XCTAssertTrue(judgeText.contains("## Attempt 2 (test/beta)"), judgeText)
    XCTAssertTrue(judgeText.contains("+beta attempt"), "the diff is the evidence: \(judgeText)")
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

  /// Candidates run unattended under AutoApprove, so the sandbox the runner is handed has to
  /// reach the tools they actually use — the file tools included, since those never touch a
  /// shell for the kernel to confine.
  func testCandidateToolsAreConfinedBySandboxAndTheOutcomeSaysSo() async throws {
    let base = try tempDir("panel-sandbox")
    defer { try? FileManager.default.removeItem(at: base) }
    try "original".write(to: base.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/alpha"),
      Fixtures.manifestModel(id: "test/beta"))
    // Both candidates try to plant agent configuration in their own snapshot.
    let script: [[ChatCompletionChunk]] = [
      [
        Fixtures.toolCallChunk(
          id: "h1", name: "write_file",
          arguments: #"{"path": ".claude/settings.json", "content": "{}"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chunkScriptsByModel = ["test/alpha": script, "test/beta": script]
    mock.chatResponses = [
      Fixtures.textResponse(#"{"winner": 1, "reasons": ["neither did anything."]}"#, cost: 0.001),
    ]

    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60,
      makeSandbox: { root in ShellSandbox(writableRoots: [root]) })
    let result = try await runner.run(
      task: "add agent settings",
      models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertTrue(result.candidates.allSatisfy(\.sandboxed))
    // Nothing was written, so nothing syncs back into the real working directory.
    XCTAssertFalse(FileManager.default.fileExists(
      atPath: base.appendingPathComponent(".claude/settings.json").path))
    XCTAssertTrue(try evalStore.all().allSatisfy { $0.sandboxed == true })
  }

  /// The user's guardrails reach unattended candidates: a project-sourced PreToolUse deny
  /// blocks a candidate's bash under AutoApprove and lands on its record — while a `Stop`
  /// hook in the same set never runs, because a candidate's finish is not the user's turn end.
  func testProjectDenyHookBlocksCandidateBashAndStopHooksNeverRunForCandidates() async throws {
    let base = try tempDir("panel-hooks")
    defer { try? FileManager.default.removeItem(at: base) }
    let stopMarker = base.appendingPathComponent("stop-ran.marker")
    let startMarker = base.appendingPathComponent("start-ran.marker")

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/alpha"),
      Fixtures.manifestModel(id: "test/beta"))
    func script(_ model: String) -> [[ChatCompletionChunk]] {
      [
        [
          Fixtures.toolCallChunk(
            id: "s1", name: "bash", arguments: #"{"command":"echo made > out.txt"}"#, model: model),
          Fixtures.usageChunk(cost: 0.01, model: model),
        ],
        [Fixtures.textChunk("could not run it", model: model), Fixtures.usageChunk(cost: 0.01, model: model)],
      ]
    }
    mock.chunkScriptsByModel = ["test/alpha": script("test/alpha"), "test/beta": script("test/beta")]
    mock.chatResponses = [
      Fixtures.textResponse(#"{"winner": 1, "reasons": ["neither could run anything."]}"#, cost: 0.001),
    ]

    let hooks = [
      HookDefinition(
        event: .preToolUse, matcher: "bash",
        command: "echo 'no bash in panels' >&2; exit 2", id: "no-bash", source: .project),
      HookDefinition(event: .stop, command: "touch '\(stopMarker.path)'"),
      HookDefinition(event: .sessionStart, command: "touch '\(startMarker.path)'"),
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60, hooks: hooks)
    let result = try await runner.run(
      task: "write out.txt", models: ["test/alpha", "test/beta"], judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertEqual(result.candidates.count, 2)
    for candidate in result.candidates {
      XCTAssertNil(candidate.error)
      XCTAssertEqual(candidate.record?.hookBlocks, 1, "the deny is on the candidate's record")
      XCTAssertEqual(candidate.record?.deniedCalls, 1)
      XCTAssertTrue(candidate.diff.isEmpty, "the blocked command wrote nothing: \(candidate.diff)")
    }
    // The model was told why, in the candidate's own transcript.
    let toolMessages = mock.requests.compactMap { $0.messages.last { $0.role == .tool }?.content?.plainText }
    XCTAssertEqual(toolMessages.count, 2)
    XCTAssertTrue(toolMessages.allSatisfy { $0.contains("no bash in panels") }, "\(toolMessages)")
    XCTAssertFalse(FileManager.default.fileExists(atPath: base.appendingPathComponent("out.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopMarker.path), "Stop is the user's turn end")
    XCTAssertFalse(FileManager.default.fileExists(atPath: startMarker.path), "SessionStart is the user's session")
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

  // MARK: V1 — the structured judge and its prose fallback

  /// Two candidates that each write `answer.txt`, keyed by model (they run concurrently).
  private func twoCandidateMock() -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/alpha"),
      Fixtures.manifestModel(id: "test/beta"),
      Fixtures.manifestModel(id: "test/judge"))
    func script(_ label: String, cost: Double) -> [[ChatCompletionChunk]] {
      [
        [
          Fixtures.toolCallChunk(
            id: "\(label)1", name: "write_file",
            arguments: #"{"path": "answer.txt", "content": "\#(label) attempt"}"#),
          Fixtures.usageChunk(cost: cost),
        ],
        [Fixtures.textChunk("\(label) done"), Fixtures.usageChunk(cost: cost)],
      ]
    }
    mock.chunkScriptsByModel = ["test/alpha": script("alpha", cost: 0.01), "test/beta": script("beta", cost: 0.02)]
    return mock
  }

  /// A judge that answers in prose both times still picks a winner through the pre-V1
  /// `WINNER: <n>` read — the last resort, kept so a panel never ends without a winner over a
  /// model that won't write JSON.
  func testJudgeProseReplyFallsBackToTheWinnerLine() async throws {
    let base = try tempDir("panel-prose")
    defer { try? FileManager.default.removeItem(at: base) }
    let mock = twoCandidateMock()
    mock.chatResponses = [
      Fixtures.textResponse("WINNER: 2 — beta's change matches the task.", cost: 0.001),
      Fixtures.textResponse("WINNER: 2 — still beta.", cost: 0.001),
    ]

    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    let result = try await runner.run(
      task: "write answer.txt", models: ["test/alpha", "test/beta"], judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertEqual(result.verdict.winnerIndex, 1)
    XCTAssertEqual(result.verdict.reason, "(unstructured) WINNER: 2 — still beta.")
    XCTAssertEqual(result.verdict.judgeCostUSD, 0.002, accuracy: 0.000001, "both attempts booked")
    XCTAssertEqual(mock.requests.filter { $0.model == "test/judge" }.count, 2, "one correction, then the fallback")
  }

  /// A reply that names no attempt, structured or not, is `judgeFailed` with the reply.
  func testJudgeReplyNamingNoAttemptIsJudgeFailed() async throws {
    let base = try tempDir("panel-nopick")
    defer { try? FileManager.default.removeItem(at: base) }
    let mock = twoCandidateMock()
    mock.chatResponses = [
      Fixtures.textResponse("I cannot decide.", cost: 0.001),
      Fixtures.textResponse("Both are fine.", cost: 0.001),
    ]

    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    do {
      _ = try await runner.run(
        task: "write answer.txt", models: ["test/alpha", "test/beta"], judgeModel: "test/judge",
        baseDirectory: base)
      XCTFail("expected judgeFailed")
    } catch PanelError.judgeFailed(let text) {
      XCTAssertEqual(text, "Both are fine.")
    }
    // A structured pick of an attempt that isn't in the panel is a failure too, never a guess.
    let numbered = twoCandidateMock()
    numbered.chatResponses = [Fixtures.textResponse(#"{"winner": 7, "reasons": []}"#, cost: 0.001)]
    let numberedRunner = PanelRunner(
      service: numbered, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    do {
      _ = try await numberedRunner.run(
        task: "write answer.txt", models: ["test/alpha", "test/beta"], judgeModel: "test/judge",
        baseDirectory: base)
      XCTFail("expected judgeFailed")
    } catch PanelError.judgeFailed(let text) {
      XCTAssertTrue(text.hasPrefix("winner 7 is not one of the attempts (1…2)"), text)
    }
  }

  /// On a provider that reports no cost the judge is priced from the manifest, like a
  /// session's own steps — pre-V1 it was booked at $0 there.
  func testJudgeCostIsEstimatedFromTheManifestWhenTheRouterReportsNone() async throws {
    let base = try tempDir("panel-priced")
    defer { try? FileManager.default.removeItem(at: base) }
    let mock = twoCandidateMock()
    // 1000 prompt tokens × $0.000001 + 500 completion tokens × $0.000002 = $0.002, no `cost`.
    mock.chatResponses = [
      Fixtures.response("""
        {"id":"gen-j","model":"test/judge","choices":[{"index":0,"message":{"role":"assistant",\
        "content":"{\\"winner\\": 2, \\"reasons\\": [\\"beta\\"]}"},"finish_reason":"stop"}],\
        "usage":{"prompt_tokens":1000,"completion_tokens":500}}
        """),
    ]

    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60,
      catalog: ModelCatalog(service: mock),
      provider: ProviderTraits.forKind(.litellm, name: "gw", defaultModel: "test/judge", nativeDialects: false))
    let result = try await runner.run(
      task: "write answer.txt", models: ["test/alpha", "test/beta"], judgeModel: "test/judge",
      baseDirectory: base)

    XCTAssertEqual(result.verdict.winnerIndex, 1)
    XCTAssertEqual(result.verdict.judgeCostUSD, 0.002, accuracy: 0.000001)
  }
}
