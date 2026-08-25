import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class EvalCaptureTests: XCTestCase {

  // MARK: Parsing

  func testParseTaskFromFencedChattyReply() {
    let reply = """
      Sure — here is the task:
      ```json
      {"id": "fix-regex", "prompt": "fix the regex in filter.py", "setup": "echo x > filter.py", "check": "grep -q y filter.py"}
      ```
      """
    let task = EvalTaskDistiller.parseTask(reply)
    XCTAssertEqual(task?.id, "fix-regex")
    XCTAssertEqual(task?.setup, "echo x > filter.py")
    XCTAssertNil(EvalTaskDistiller.parseTask("no json here"))
  }

  // MARK: Validation

  func testValidateAcceptsRealTaskAndRejectsVacuousOrBrokenOnes() {
    // Real test: check fails pre-work, setup succeeds.
    let good = EvalTask(
      id: "edit-line", prompt: "change VALUE to 2",
      setup: "echo 'VALUE=1' > state.txt",
      check: "grep -q 'VALUE=2' state.txt")
    XCTAssertNil(EvalCapture.validate(good))

    // Vacuous: the check already passes on the fresh setup — tests nothing.
    let vacuous = EvalTask(
      id: "vacuous", prompt: "p",
      setup: "echo done > out.txt",
      check: "grep -q done out.txt")
    XCTAssertTrue(EvalCapture.validate(vacuous)?.contains("vacuous") == true)

    // Broken setup.
    let broken = EvalTask(id: "broken", prompt: "p", setup: "exit 3", check: "true")
    XCTAssertTrue(EvalCapture.validate(broken)?.contains("setup failed") == true)

    // Missing fields.
    let empty = EvalTask(id: "", prompt: "p", check: "false")
    XCTAssertNotNil(EvalCapture.validate(empty))
  }

  // MARK: Distiller

  func testDistillerRetriesWithFeedbackThenSucceeds() async throws {
    let mock = MockOpenRouterService()
    // First reply is vacuous (check passes pre-work) → rejected with feedback;
    // second is a real test.
    mock.chatResponses = [
      Fixtures.textResponse(
        #"{"id": "bad", "prompt": "p", "setup": "echo hi > a.txt", "check": "test -f a.txt"}"#,
        cost: 0.001),
      Fixtures.textResponse(
        #"{"id": "count-todos", "prompt": "write the TODO count to n.txt", "setup": "printf 'TODO\nTODO\n' > a.txt", "check": "test \"$(cat n.txt)\" = 2"}"#,
        cost: 0.001),
    ]
    let distiller = EvalTaskDistiller(service: mock)

    let output = try await distiller.distill(from: "transcript...", model: "test/writer")

    XCTAssertEqual(output.task.id, "count-todos")
    XCTAssertEqual(output.attempts, 2)
    XCTAssertEqual(output.costUSD, 0.002, accuracy: 0.0001)
    // The retry request carried the validation feedback.
    let secondRequest = mock.requests[1]
    let user = secondRequest.messages.last?.content?.plainText ?? ""
    XCTAssertTrue(user.contains("vacuous"))
  }

  func testDistillerDropsUnrealisticallyTightTimeouts() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Fixtures.textResponse(
        #"{"id": "quick", "prompt": "p", "setup": "echo 1 > a.txt", "check": "grep -q 2 a.txt", "timeoutSeconds": 10}"#,
        cost: 0.001),
    ]
    let output = try await EvalTaskDistiller(service: mock).distill(from: "…", model: "test/writer")
    // 10s can't cover agent wall-clock (network included); the default applies instead.
    XCTAssertNil(output.task.timeoutSeconds)
  }

  // MARK: Split

  func testSplitSourcesSliceByUserTurnWithRollingContext() {
    let messages: [Message] = [
      .user("create colors.txt with red green blue"),
      Message(role: .assistant, content: nil, toolCalls: [
        ToolCall(id: "c1", type: "function", index: 0,
                 function: .init(name: "write_file", arguments: #"{"path":"colors.txt"}"#)),
      ]),
      .tool("wrote 15 bytes", toolCallId: "c1"),
      .assistant("created colors.txt"),
      .user("now count its lines into count.txt"),
      .assistant("done, count.txt has 3"),
    ]
    let sources = EvalCapture.splitSources(messages)
    XCTAssertEqual(sources.count, 2)
    // First turn: no context preamble, full transcript including the tool call.
    XCTAssertFalse(sources[0].contains("Earlier in the session"))
    XCTAssertTrue(sources[0].contains("write_file"))
    // Second turn: carries the earlier request as context so "its lines" resolves.
    XCTAssertTrue(sources[1].contains("Earlier in the session"))
    XCTAssertTrue(sources[1].contains("create colors.txt"))
    XCTAssertTrue(sources[1].contains("now count its lines"))
    // But not the first turn's tool plumbing — context is a summary, not a replay.
    XCTAssertFalse(sources[1].contains("write_file"))
  }

  func testDistillIfTaskReturnsNilOnSkipWithoutRetry() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("SKIP", cost: 0.0002)]
    let distiller = EvalTaskDistiller(service: mock)

    let output = try await distiller.distillIfTask(from: "user: /cost", model: "test/writer")

    XCTAssertNil(output)
    XCTAssertEqual(mock.requests.count, 1)
    // The skip instruction only rides in split mode.
    XCTAssertTrue(mock.requests[0].messages.first?.content?.plainText.contains("SKIP") == true)
  }

  // MARK: Transcript rendering

  func testRenderTranscriptShowsRolesToolCallsAndOutputs() {
    let messages: [Message] = [
      .user("fix the bug"),
      Message(role: .assistant, content: .text("on it"), toolCalls: [
        ToolCall(id: "c1", type: "function", index: 0,
                 function: .init(name: "edit_file", arguments: #"{"path":"a.py"}"#)),
      ]),
      .tool("error: old_string not found", toolCallId: "c1"),
    ]
    let text = EvalCapture.renderTranscript(messages)
    XCTAssertTrue(text.contains("user: fix the bug"))
    XCTAssertTrue(text.contains("edit_file"))
    XCTAssertTrue(text.contains("old_string not found"))
  }

  // MARK: Prune

  func testRewriteKeepsMatchingRowsAtomically() throws {
    let store = EvalStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-prune-\(UUID().uuidString).jsonl"))
    func outcome(_ suite: String, daysAgo: Double) -> EvalOutcome {
      EvalOutcome(
        suite: suite, taskId: "t", model: "m", trial: 1,
        checkPassed: true, agentFinished: true, steps: 1, toolCalls: 0,
        costUSD: 0.01, durationSeconds: 1,
        startedAt: Date().addingTimeInterval(-daysAgo * 86_400),
        routedModels: [], error: nil, dialect: nil)
    }
    try store.append(outcome("basics", daysAgo: 40))
    try store.append(outcome("basics", daysAgo: 1))
    try store.append(outcome("panel", daysAgo: 1))

    // Drop the "panel" suite.
    var result = try store.rewrite { $0.suite != "panel" }
    XCTAssertEqual(result.removed, 1)
    XCTAssertEqual(result.kept, 2)

    // Drop rows older than 30 days.
    let cutoff = Date().addingTimeInterval(-30 * 86_400)
    result = try store.rewrite { $0.startedAt >= cutoff }
    XCTAssertEqual(result.removed, 1)
    XCTAssertEqual(try store.all().count, 1)
    XCTAssertEqual(try store.all().first?.suite, "basics")
  }

  // MARK: History aggregation

  func testHistoryRowsGroupBySuiteModelDialect() {
    func outcome(_ suite: String, _ model: String, dialect: String?, passed: Bool) -> EvalOutcome {
      EvalOutcome(
        suite: suite, taskId: "t", model: model, trial: 1,
        checkPassed: passed, agentFinished: true, steps: 1, toolCalls: 0,
        costUSD: 0.01, durationSeconds: 1, startedAt: Date(),
        routedModels: [], error: nil, dialect: dialect)
    }
    let rows = EvalHistoryRow.aggregate([
      outcome("basics", "a/x", dialect: "chat", passed: true),
      outcome("basics", "a/x", dialect: "chat", passed: false),
      outcome("basics", "a/x", dialect: "messages", passed: true),
      outcome("panel", "b/y", dialect: nil, passed: true),
    ])
    XCTAssertEqual(rows.count, 3)
    // Same model splits by dialect — that's what makes A/Bs visible.
    let chat = rows.first { $0.dialect == "chat" }
    XCTAssertEqual(chat?.trials, 2)
    XCTAssertEqual(chat?.passed, 1)
    let messages = rows.first { $0.dialect == "messages" }
    XCTAssertEqual(messages?.passRate, 1.0)
    XCTAssertEqual(rows.last?.suite, "panel")
  }
}
