import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// `AgentEvent.jsonObject` — the `stream-json` wire shape: `type` is the event's `kind`,
/// every object carries `session_id`, payload keys are fixed snake_case, nested subagent
/// events encode recursively, and tool arguments are JSON when they parse.
final class EventJSONTests: XCTestCase {
  private static let stats = Session.TurnStats(
    steps: 2, toolCalls: 1, turnCostUSD: 0.5, sessionCostUSD: 1.5, requestedModel: "req",
    routedModels: ["served"], promptTokens: 321, contextLength: 8000, durationSeconds: 2.5)

  /// One fixture per case — the same list `HarnessAssemblyTests.testEveryEventCaseHasAKind`
  /// keeps, so a new case must be added to both (the exhaustive switch fails first anyway).
  private static let fixtures: [AgentEvent] = [
    .textDelta("a"), .reasoningDelta("r"), .assistantText("t"),
    .toolCall(name: "bash", arguments: #"{"command":"ls"}"#), .toolResult(name: "bash", preview: "ok"),
    .toolDenied(name: "bash", reason: nil), .verifier(passed: true, verdict: "PASS"),
    .userQuestion(question: "Which one?", options: ["a", "b"]),
    .structuredOutput(json: ["ok": true], valid: true, errors: []),
    .routed(model: "m", provider: nil), .dialectFellBack(dialect: "messages", reason: "x"),
    .interrupted, .nudged(reason: "empty"), .stepLimitReached(maxSteps: 3),
    .budgetReached(spentUSD: 1, budgetUSD: 1), .hookNotice(event: "Stop", output: "o"),
    .hookBlocked(tool: "bash", reason: "no"), .hookStopped(reason: nil),
    .promptBlocked(reason: "not now"), .deniedLoop(count: 3),
    .stuckDetected(reason: "the same edit_file call failed 6 times"),
    .contentFlagged(tool: "read_file", patterns: ["role_imitation", "instruction_phrase"]),
    .jobStarted(id: 1, command: "npm run dev"),
    .jobFinished(id: 1, exitStatus: 143),
    .retrying(attempt: 2, reason: "provider overloaded (529)"),
    .truncated,
    .planUpdated(steps: [(text: "read the code", status: "completed"), (text: "edit", status: "in_progress")]),
    .compacted(summarizedMessages: 2, keptMessages: 1),
    .toolResultsCleared(count: 3, freedChars: 12000),
    .contextWarning("context at 96% of the window with nothing left to clear"),
    .subagentBlocked(name: "explore", id: "a1b2c3d4", reason: "no"),
    .subagentStarted(name: "explore", id: "a1b2c3d4", model: "m", task: "t"),
    .subagent(name: "explore", id: "a1b2c3d4", event: .interrupted),
    .subagentFinished(
      name: "explore", id: "a1b2c3d4", steps: 1, toolCalls: 0, costUSD: 0, resultPreview: ""),
    .subagentBackgrounded(name: "explore", id: "a1b2c3d4", model: "m"),
    .subagentJoining(pending: 1),
    .turnFinished(stats),
  ]

  private func object(_ event: AgentEvent, agent: String? = nil) throws -> [String: JSONValue] {
    try XCTUnwrap(event.jsonObject(sessionId: "S-1", agent: agent).objectValue)
  }

  func testEveryCaseHasATypeEqualToItsKindAndASessionId() throws {
    XCTAssertEqual(Self.fixtures.count, AgentEvent.Kind.allCases.count, "the fixture list covers every case")
    XCTAssertEqual(Set(Self.fixtures.map(\.kind)), Set(AgentEvent.Kind.allCases))
    for event in Self.fixtures {
      let object = try object(event)
      XCTAssertEqual(object["type"], .string(event.kind.rawValue), "\(event.kind)")
      XCTAssertEqual(object["session_id"], .string("S-1"), "\(event.kind)")
      XCTAssertNil(object["agent"], "the lead's own events name no agent")
      // Every object serializes to one line.
      XCTAssertFalse(event.jsonLine(sessionId: "S-1").contains("\n"))
    }
  }

  func testNestedSubagentEventEncodesRecursivelyAndNamesTheAgent() throws {
    let nested = AgentEvent.subagent(
      name: "explore", id: "a1b2c3d4",
      event: .toolCall(name: "grep", arguments: #"{"pattern":"TODO"}"#))
    let object = try object(nested)
    XCTAssertEqual(object["type"], .string("subagent"))
    XCTAssertEqual(object["name"], .string("explore"))
    XCTAssertEqual(object["id"], .string("a1b2c3d4"))
    let inner = try XCTUnwrap(object["event"]?.objectValue)
    XCTAssertEqual(inner["type"], .string("tool_call"))
    XCTAssertEqual(inner["session_id"], .string("S-1"), "the stream is the lead's; the nested object rides it")
    XCTAssertEqual(inner["agent"], .string("explore"))
    XCTAssertEqual(inner["name"], .string("grep"))
    XCTAssertEqual(inner["arguments"], ["pattern": "TODO"])
  }

  func testToolCallArgumentsAreParsedWhenValidJSONElseKeptRaw() throws {
    let parsed = try object(.toolCall(name: "read_file", arguments: #"{"path":"a.txt","limit":10}"#))
    XCTAssertEqual(parsed["arguments"], ["path": "a.txt", "limit": 10])
    let raw = try object(.toolCall(name: "bash", arguments: #"{"command": "ls"#))
    XCTAssertEqual(raw["arguments"], .string(#"{"command": "ls"#), "a truncated blob is kept, not dropped")
  }

  func testOptionalPayloadsEncodeAsNull() throws {
    XCTAssertEqual(try object(.toolDenied(name: "bash", reason: nil))["reason"], .null)
    XCTAssertEqual(try object(.toolDenied(name: "bash", reason: "no"))["reason"], .string("no"))
    XCTAssertEqual(try object(.routed(model: "m", provider: nil))["provider"], .null)
    XCTAssertEqual(try object(.hookStopped(reason: nil))["reason"], .null)
    let stats = Session.TurnStats(
      steps: 1, toolCalls: 0, turnCostUSD: 0, sessionCostUSD: 0, requestedModel: "m",
      routedModels: [], promptTokens: nil, contextLength: nil, durationSeconds: 0)
    let finished = try object(.turnFinished(stats))
    XCTAssertEqual(finished["prompt_tokens"], .null)
    XCTAssertEqual(finished["context_length"], .null)
  }

  // MARK: Golden lines — the keys a consumer switches on

  func testGoldenLines() {
    XCTAssertEqual(
      AgentEvent.toolCall(name: "bash", arguments: #"{"command":"ls"}"#).jsonLine(sessionId: "S"),
      #"{"arguments":{"command":"ls"},"name":"bash","session_id":"S","type":"tool_call"}"#)
    XCTAssertEqual(
      AgentEvent.toolResult(name: "bash", preview: "ok").jsonLine(sessionId: "S"),
      #"{"name":"bash","preview":"ok","session_id":"S","type":"tool_result"}"#)
    XCTAssertEqual(
      AgentEvent.toolDenied(name: "bash", reason: "nope").jsonLine(sessionId: "S"),
      #"{"name":"bash","reason":"nope","session_id":"S","type":"tool_denied"}"#)
    XCTAssertEqual(
      AgentEvent.userQuestion(question: "Which config?", options: ["dev", "prod"]).jsonLine(sessionId: "S"),
      #"{"options":["dev","prod"],"question":"Which config?","session_id":"S","type":"user_question"}"#)
    XCTAssertEqual(
      AgentEvent.userQuestion(question: "Name?", options: []).jsonLine(sessionId: "S"),
      #"{"options":[],"question":"Name?","session_id":"S","type":"user_question"}"#)
    XCTAssertEqual(
      AgentEvent.verifier(passed: false, verdict: "FAIL").jsonLine(sessionId: "S"),
      #"{"passed":false,"session_id":"S","type":"verifier","verdict":"FAIL"}"#)
    XCTAssertEqual(
      AgentEvent.routed(model: "m", provider: "p").jsonLine(sessionId: "S"),
      #"{"model":"m","provider":"p","session_id":"S","type":"routed"}"#)
    XCTAssertEqual(
      AgentEvent.dialectFellBack(dialect: "messages", reason: "404").jsonLine(sessionId: "S"),
      #"{"dialect":"messages","reason":"404","session_id":"S","type":"dialect_fell_back"}"#)
    XCTAssertEqual(
      AgentEvent.interrupted.jsonLine(sessionId: "S"),
      #"{"session_id":"S","type":"interrupted"}"#)
    XCTAssertEqual(
      AgentEvent.nudged(reason: "empty reply").jsonLine(sessionId: "S"),
      #"{"reason":"empty reply","session_id":"S","type":"nudged"}"#)
    XCTAssertEqual(
      AgentEvent.stepLimitReached(maxSteps: 30).jsonLine(sessionId: "S"),
      #"{"max_steps":30,"session_id":"S","type":"step_limit"}"#)
    XCTAssertEqual(
      AgentEvent.budgetReached(spentUSD: 0.5, budgetUSD: 0.5).jsonLine(sessionId: "S"),
      #"{"budget_usd":0.5,"session_id":"S","spent_usd":0.5,"type":"budget"}"#)
    XCTAssertEqual(
      AgentEvent.hookNotice(event: "Stop", output: "ran tests").jsonLine(sessionId: "S"),
      #"{"event":"Stop","output":"ran tests","session_id":"S","type":"hook_notice"}"#)
    XCTAssertEqual(
      AgentEvent.hookBlocked(tool: "bash", reason: "no").jsonLine(sessionId: "S"),
      #"{"reason":"no","session_id":"S","tool":"bash","type":"hook_blocked"}"#)
    XCTAssertEqual(
      AgentEvent.hookStopped(reason: "enough").jsonLine(sessionId: "S"),
      #"{"reason":"enough","session_id":"S","type":"hook_stopped"}"#)
    XCTAssertEqual(
      AgentEvent.promptBlocked(reason: "not now").jsonLine(sessionId: "S"),
      #"{"reason":"not now","session_id":"S","type":"prompt_blocked"}"#)
    XCTAssertEqual(
      AgentEvent.deniedLoop(count: 3).jsonLine(sessionId: "S"),
      #"{"count":3,"session_id":"S","type":"denied_loop"}"#)
    XCTAssertEqual(
      AgentEvent.stuckDetected(reason: "6 tool calls failed in a row").jsonLine(sessionId: "S"),
      #"{"reason":"6 tool calls failed in a row","session_id":"S","type":"stuck_detected"}"#)
    XCTAssertEqual(
      AgentEvent.contentFlagged(tool: "read_file", patterns: ["role_imitation", "frame_forgery"]).jsonLine(sessionId: "S"),
      #"{"patterns":["role_imitation","frame_forgery"],"session_id":"S","tool":"read_file","type":"content_flagged"}"#)
    XCTAssertEqual(
      AgentEvent.jobStarted(id: 2, command: "npm run dev").jsonLine(sessionId: "S"),
      #"{"command":"npm run dev","id":2,"session_id":"S","type":"job_started"}"#)
    XCTAssertEqual(
      AgentEvent.jobFinished(id: 2, exitStatus: 143).jsonLine(sessionId: "S"),
      #"{"exit_status":143,"id":2,"session_id":"S","type":"job_finished"}"#)
    XCTAssertEqual(
      AgentEvent.retrying(attempt: 2, reason: "rate limited (429)").jsonLine(sessionId: "S"),
      #"{"attempt":2,"reason":"rate limited (429)","session_id":"S","type":"retrying"}"#)
    XCTAssertEqual(
      AgentEvent.truncated.jsonLine(sessionId: "S"),
      #"{"session_id":"S","type":"truncated"}"#)
    XCTAssertEqual(
      AgentEvent.planUpdated(steps: [(text: "read the code", status: "completed"), (text: "edit", status: "in_progress")])
        .jsonLine(sessionId: "S"),
      #"{"session_id":"S","steps":[{"status":"completed","step":"read the code"},{"status":"in_progress","step":"edit"}],"type":"plan_updated"}"#)
    XCTAssertEqual(
      AgentEvent.compacted(summarizedMessages: 4, keptMessages: 2).jsonLine(sessionId: "S"),
      #"{"kept_messages":2,"session_id":"S","summarized_messages":4,"type":"compacted"}"#)
    XCTAssertEqual(
      AgentEvent.toolResultsCleared(count: 3, freedChars: 12000).jsonLine(sessionId: "S"),
      #"{"count":3,"freed_chars":12000,"session_id":"S","type":"tool_results_cleared"}"#)
    XCTAssertEqual(
      AgentEvent.contextWarning("context at 96% of the window").jsonLine(sessionId: "S"),
      #"{"message":"context at 96% of the window","session_id":"S","type":"context_warning"}"#)
    XCTAssertEqual(
      AgentEvent.structuredOutput(json: ["answer": 42], valid: true, errors: []).jsonLine(sessionId: "S"),
      #"{"errors":[],"json":{"answer":42},"session_id":"S","type":"structured_output","valid":true}"#)
    XCTAssertEqual(
      AgentEvent.structuredOutput(json: nil, valid: false, errors: ["$: missing required property 'answer'"]).jsonLine(sessionId: "S"),
      #"{"errors":["$: missing required property 'answer'"],"json":null,"session_id":"S","type":"structured_output","valid":false}"#)
    XCTAssertEqual(
      AgentEvent.subagentBlocked(name: "explore", id: "a1b2c3d4", reason: "no").jsonLine(sessionId: "S"),
      #"{"id":"a1b2c3d4","name":"explore","reason":"no","session_id":"S","type":"subagent_blocked"}"#)
    XCTAssertEqual(
      AgentEvent.subagentStarted(name: "explore", id: "a1b2c3d4", model: "m", task: "look").jsonLine(sessionId: "S"),
      #"{"id":"a1b2c3d4","model":"m","name":"explore","session_id":"S","task":"look","type":"subagent_started"}"#)
    XCTAssertEqual(
      AgentEvent.subagentFinished(
        name: "explore", id: "a1b2c3d4", steps: 2, toolCalls: 1, costUSD: 0.25, resultPreview: "found").jsonLine(sessionId: "S"),
      #"{"cost_usd":0.25,"id":"a1b2c3d4","name":"explore","result_preview":"found","session_id":"S","steps":2,"tool_calls":1,"type":"subagent_finished"}"#)
    XCTAssertEqual(
      AgentEvent.subagentBackgrounded(name: "explore", id: "a1b2c3d4", model: "m").jsonLine(sessionId: "S"),
      #"{"id":"a1b2c3d4","model":"m","name":"explore","session_id":"S","type":"subagent_backgrounded"}"#)
    XCTAssertEqual(
      AgentEvent.subagentJoining(pending: 2).jsonLine(sessionId: "S"),
      #"{"pending":2,"session_id":"S","type":"subagent_joining"}"#)
    XCTAssertEqual(
      AgentEvent.turnFinished(Self.stats).jsonLine(sessionId: "S"),
      #"{"cached_prompt_tokens":null,"context_length":8000,"duration_seconds":2.5,"prompt_tokens":321,"requested_model":"req","routed_models":["served"],"session_cost_usd":1.5,"session_id":"S","steps":2,"tool_calls":1,"turn_cost_usd":0.5,"type":"turn_finished"}"#)
    // The prompt-cache figure rides the event when a turn read anything from the cache (C7's
    // `TurnStats.cachedPromptTokens`); a turn that measured none says `null`, never omits the key.
    let cached = Session.TurnStats(
      steps: 2, toolCalls: 1, turnCostUSD: 0.5, sessionCostUSD: 1.5, requestedModel: "req",
      routedModels: ["served"], promptTokens: 321, contextLength: 8000, durationSeconds: 2.5,
      cachedPromptTokens: 200, totalPromptTokens: 321)
    XCTAssertEqual(
      AgentEvent.turnFinished(cached).jsonLine(sessionId: "S"),
      #"{"cached_prompt_tokens":200,"context_length":8000,"duration_seconds":2.5,"prompt_tokens":321,"requested_model":"req","routed_models":["served"],"session_cost_usd":1.5,"session_id":"S","steps":2,"tool_calls":1,"turn_cost_usd":0.5,"type":"turn_finished"}"#)
    XCTAssertEqual(
      AgentEvent.assistantText("hi").jsonLine(sessionId: "S"),
      #"{"session_id":"S","text":"hi","type":"assistant"}"#)
    XCTAssertEqual(
      AgentEvent.textDelta("h").jsonLine(sessionId: "S"),
      #"{"session_id":"S","text":"h","type":"text_delta"}"#)
    XCTAssertEqual(
      AgentEvent.reasoningDelta("r").jsonLine(sessionId: "S"),
      #"{"session_id":"S","text":"r","type":"reasoning_delta"}"#)
  }

  func testModelTextIsEscapedByTheEncoderNotSanitized() {
    // A control character in model text is JSON-escaped; the terminal sanitizer is text
    // mode's job and never touches these bytes.
    let line = AgentEvent.assistantText("a\u{1B}[31mb\n").jsonLine(sessionId: "S")
    XCTAssertEqual(line, #"{"session_id":"S","text":"a\u001b[31mb\n","type":"assistant"}"#)
    XCTAssertFalse(line.unicodeScalars.contains { $0.value < 0x20 }, "no raw control byte reaches the wire")
  }
}
