import XCTest
@testable import ArnesKit
import OpenRouterSwift

private final class LifecycleEventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AgentEvent] = []
  func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
  var events: [AgentEvent] { lock.withLock { stored } }
}

/// The delegation lifecycle: `SubagentStart` can veto a spawn before a request is spent and
/// `SubagentStop` post-processes the report on its way back to the lead. Both are the
/// *parent's* hooks, run by the task tool around the nested session — never inside it.
final class SubagentLifecycleHooksTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-sublifecycle-\(UUID().uuidString).jsonl"))
  }

  private func tempFile(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-\(label)-\(UUID().uuidString)")
  }

  private func helper(name: String = "helper", maxSteps: Int? = nil) -> AgentDefinition {
    AgentDefinition(
      name: name, description: "helps", body: "Help.", model: "sub/model", maxSteps: maxSteps)
  }

  // MARK: SubagentStart

  func testSubagentStartHookBlocksSpawnWithReason() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    // Deliberately no chunk script: a nested request would throw, not just be recorded.
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(
        event: .subagentStart, matcher: "*", command: "printf 'no git push tasks'; exit 2")])
    tool.parentModel = { "sub/model" }
    let collector = LifecycleEventCollector()
    tool.onEvent = { collector.append($0) }

    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("push the branch"),
    ])
    XCTAssertEqual(result, "subagent blocked by hook: no git push tasks")
    XCTAssertTrue(mock.requests.isEmpty, "a blocked delegation must not spend a nested request")

    let blocked = collector.events.compactMap { event -> (String, String)? in
      if case .subagentBlocked(let name, _, let reason) = event { return (name, reason) }
      return nil
    }
    XCTAssertEqual(blocked.count, 1)
    XCTAssertEqual(blocked.first?.0, "helper")
    XCTAssertEqual(blocked.first?.1, "no git push tasks")
    XCTAssertFalse(
      collector.events.contains { if case .subagentStarted = $0 { return true } else { return false } },
      "a blocked delegation never starts")
  }

  func testSubagentStartDenialViaDecisionJSONAlsoBlocks() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    let json = #"{"hookSpecificOutput":{"hookEventName":"SubagentStart","permissionDecision":"deny","permissionDecisionReason":"delegation is disabled today"}}"#
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStart, command: "echo '\(json)'")])
    tool.parentModel = { "sub/model" }
    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("look around"),
    ])
    XCTAssertEqual(result, "subagent blocked by hook: delegation is disabled today")
    XCTAssertTrue(mock.requests.isEmpty)
  }

  // MARK: SubagentStop

  func testSubagentStopHookOutputAppendedToReport() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("did the thing", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStop, command: "echo REVIEWED")])
    tool.parentModel = { "sub/model" }

    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("do it"),
    ])
    XCTAssertEqual(result, "did the thing\n\n[hook]\nREVIEWED")
  }

  func testForegroundFinishLineFiresBeforeTheSubagentStopHookSpeaks() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("did the thing", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    // A Stop hook asking for `continue: false` surfaces a nested `.hookStopped` — which must
    // come *after* the ◆ finish line: the finish fires as the nested turn ends, and never waits
    // on the hook's runtime.
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(
        event: .subagentStop, command: #"echo '{"continue":false,"stopReason":"enough"}'"#)])
    tool.parentModel = { "sub/model" }
    let collector = LifecycleEventCollector()
    tool.onEvent = { collector.append($0) }

    _ = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("do it"),
    ])
    let events = collector.events
    let finishedAt = try XCTUnwrap(events.firstIndex { $0.kind == .subagentFinished })
    let hookStoppedAt = try XCTUnwrap(events.firstIndex { event in
      if case .subagent(_, _, .hookStopped) = event { return true }
      return false
    })
    XCTAssertLessThan(finishedAt, hookStoppedAt)
  }

  func testSubagentStopAdditionalContextRidesTheReportToo() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("report body", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let json = #"{"hookSpecificOutput":{"hookEventName":"SubagentStop","additionalContext":"tests still pass"}}"#
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStop, command: "echo '\(json)'")])
    tool.parentModel = { "sub/model" }
    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("do it"),
    ])
    XCTAssertTrue(result.hasSuffix("[hook]\ntests still pass"), result)
  }

  // MARK: Matching on the agent name

  func testSubagentEventMatcherMatchesAgentNameRegex() async throws {
    let definition = HookDefinition(event: .subagentStart, matcher: "explore|reviewer", command: "x")
    XCTAssertTrue(definition.matches(subject: "reviewer"))
    XCTAssertTrue(definition.matches(subject: "explore"))
    XCTAssertFalse(definition.matches(subject: "general"))
    // The subject is the agent, never the tool doing the delegating.
    XCTAssertFalse(definition.matches(subject: "task"))

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("general finished", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper(name: "reviewer"), helper(name: "general")],
      service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(
        event: .subagentStart, matcher: "explore|reviewer", command: "printf 'not this agent'; exit 2")])
    tool.parentModel = { "sub/model" }

    let blocked = try await tool.execute(arguments: [
      "agent": .string("reviewer"), "task": .string("review"),
    ])
    XCTAssertEqual(blocked, "subagent blocked by hook: not this agent")
    let allowed = try await tool.execute(arguments: [
      "agent": .string("general"), "task": .string("work"),
    ])
    XCTAssertEqual(allowed, "general finished")
  }

  // MARK: Payload

  func testSubagentHookPayloadCarriesAgentIdTaskReportAndPartial() async throws {
    let start = tempFile("substart").appendingPathExtension("json")
    let stop = tempFile("substop").appendingPathExtension("json")
    defer {
      try? FileManager.default.removeItem(at: start)
      try? FileManager.default.removeItem(at: stop)
    }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("found it", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [
        HookDefinition(event: .subagentStart, command: "cat > '\(start.path)'"),
        HookDefinition(event: .subagentStop, command: "cat > '\(stop.path)'"),
      ])
    tool.parentModel = { "sub/model" }
    tool.parentSessionId = "lead-session-1"

    _ = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("look around the repo"),
    ])

    let startPayload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: start))
    XCTAssertEqual(startPayload.hookEventName, "SubagentStart")
    XCTAssertEqual(startPayload.agentType, "helper")
    XCTAssertEqual(startPayload.agent, "helper")
    XCTAssertEqual(startPayload.model, "sub/model")
    XCTAssertEqual(startPayload.task, "look around the repo")
    XCTAssertEqual(startPayload.parentSessionId, "lead-session-1")
    XCTAssertEqual(startPayload.sessionId, "lead-session-1")
    XCTAssertFalse((startPayload.agentId ?? "").isEmpty)
    XCTAssertNil(startPayload.report, "nothing has run yet at SubagentStart")
    XCTAssertNil(startPayload.toolName, "a delegation is not a tool call")

    let stopPayload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: stop))
    XCTAssertEqual(stopPayload.hookEventName, "SubagentStop")
    XCTAssertEqual(stopPayload.agentId, startPayload.agentId, "one delegation, one id")
    XCTAssertEqual(stopPayload.report, "found it")
    XCTAssertEqual(stopPayload.steps, 1)
    XCTAssertEqual(stopPayload.toolCalls, 0)
    XCTAssertEqual(stopPayload.costUSD, 0)
    XCTAssertEqual(stopPayload.partial, false)

    // Claude-Code-shaped keys, so a ported script finds them.
    let raw = try String(contentsOf: stop, encoding: .utf8)
    for key in ["hook_event_name", "agent_id", "agent_type", "parent_session_id", "task",
                "report", "steps", "tool_calls", "cost_usd", "partial", "cwd"]
    {
      XCTAssertTrue(raw.contains("\"\(key)\""), "missing \(key) in \(raw)")
    }
  }

  func testStopPayloadMarksACutShortRunPartial() async throws {
    let stop = tempFile("subpartial").appendingPathExtension("json")
    defer { try? FileManager.default.removeItem(at: stop) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    // One step, and it spends it on a tool call — the nested run is cut off mid-work.
    mock.chunkScripts = [[
      Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"hm"}"#, model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper(maxSteps: 1)], service: mock, tools: [ThinkTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStop, command: "cat > '\(stop.path)'")])
    tool.parentModel = { "sub/model" }

    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("think hard"),
    ])
    XCTAssertTrue(result.contains("step limit"), result)
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: stop))
    XCTAssertEqual(payload.partial, true)
    XCTAssertEqual(payload.toolCalls, 1)
  }

  func testDelegationHookEnvironmentNamesTheAgentAndDelegation() async {
    let engine = HookEngine(hooks: [HookDefinition(
      event: .subagentStop, command: #"echo "$ARNES_HOOK_EVENT/$ARNES_AGENT_NAME/$ARNES_AGENT_ID""#)])
    let outcome = await engine.subagentStop(
      agent: "reviewer", id: "deleg-7", model: "m", task: "t", report: "r",
      steps: 1, toolCalls: 0, costUSD: 0, partial: false)
    XCTAssertEqual(outcome.feedback, "SubagentStop/reviewer/deleg-7")
  }

  // MARK: The nested session never runs them itself

  func testForSubagentDropsTheTurnEndAndDelegationHooks() {
    let configuration = Session.Configuration(hooks: [
      HookDefinition(event: .preToolUse, command: "a"),
      HookDefinition(event: .postToolUse, command: "b"),
      HookDefinition(event: .stop, command: "c"),
      HookDefinition(event: .subagentStart, command: "d"),
      HookDefinition(event: .subagentStop, command: "e"),
    ])
    let nested = configuration.forSubagent(named: "helper", model: "m", systemSuffix: "role")
    XCTAssertEqual(nested.hooks.map(\.event), [.preToolUse, .postToolUse])
  }

  func testDelegationHooksRunOncePerDelegationNotAgainInsideTheNestedSession() async throws {
    let marker = tempFile("submarker").appendingPathExtension("log")
    defer { try? FileManager.default.removeItem(at: marker) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("done", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [
        HookDefinition(event: .subagentStart, command: "echo start >> '\(marker.path)'"),
        HookDefinition(event: .subagentStop, command: "echo stop >> '\(marker.path)'"),
      ])
    tool.parentModel = { "sub/model" }
    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("go")])

    let lines = try String(contentsOf: marker, encoding: .utf8)
      .split(separator: "\n").map(String.init)
    XCTAssertEqual(lines, ["start", "stop"], "each delegation hook fires exactly once")
  }

  // MARK: Runner failures

  func testDelegationHookRunnerErrorsSurfaceAsNoticesAndDoNotBlock() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("ran anyway", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStart, command: "echo boom >&2; exit 3")])
    tool.parentModel = { "sub/model" }
    let collector = LifecycleEventCollector()
    tool.onEvent = { collector.append($0) }

    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("go"),
    ])
    XCTAssertEqual(result, "ran anyway", "only exit 2 (or a deny) blocks a delegation")
    let notices = collector.events.compactMap { event -> String? in
      if case .subagent(_, _, .hookNotice("SubagentStart", let output)) = event { return output }
      return nil
    }
    XCTAssertEqual(notices.count, 1)
    XCTAssertTrue(notices[0].contains("exited 3"), notices[0])
  }

  func testFailClosedSubagentStartHookBlocksWhenItCannotRun() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(
        event: .subagentStart, command: "exit 3", failClosed: true)])
    tool.parentModel = { "sub/model" }
    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("go"),
    ])
    XCTAssertTrue(result.hasPrefix("subagent blocked by hook:"), result)
    XCTAssertTrue(result.contains("failClosed"), result)
    XCTAssertTrue(mock.requests.isEmpty)
  }

  // MARK: No hooks configured

  func testNoHooksLeavesTheDelegationPathUntouched() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("plain report", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore())
    tool.parentModel = { "sub/model" }
    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("go"),
    ])
    XCTAssertEqual(result, "plain report")
  }
}
