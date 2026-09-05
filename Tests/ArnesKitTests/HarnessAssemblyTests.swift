import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The wave-0 structural contract: one `ToolContext` → one toolset everywhere, one
/// `Session.Configuration` that nested sessions derive from, one `StopReason` on every
/// record, one event stream that nested progress rides, and a `kind` per event.
final class HarnessAssemblyTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-assembly-\(UUID().uuidString).jsonl"))
  }

  // MARK: ToolContext / HarnessAssembly

  func testEveryRunnerBuildsTheSameToolsetForTheSameContext() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("assembly-\(UUID().uuidString)")
    let context = ToolContext(root: root, sandbox: nil, environment: .default)
    let core = HarnessAssembly.coreTools(context).map(\.name)
    XCTAssertEqual(core, ["read_file", "write_file", "edit_file", "bash", "grep", "glob", "view_image", "update_plan", "think", "ask_user"])
    // The unbound default set is the same toolset, bound to the process CWD.
    XCTAssertEqual(Session.defaultTools.map(\.name), core)
    // Extras land after the core tools, in the caller's order.
    let mock = MockOpenRouterService()
    let task = TaskTool(agents: [.general], service: mock, tools: [], store: tempStore())
    let full = HarnessAssembly.tools(context, extras: [task]).map(\.name)
    XCTAssertEqual(full, core + ["task"])
    // A context with a job registry adds the `job` tool right after bash; without one the
    // toolset is exactly the list above and `bash` refuses `background: true`.
    var withJobs = context
    withJobs.jobs = JobRegistry()
    XCTAssertEqual(
      HarnessAssembly.coreTools(withJobs).map(\.name),
      ["read_file", "write_file", "edit_file", "bash", "job", "grep", "glob", "view_image", "update_plan", "think", "ask_user"])
    // A `web` policy adds `web_fetch` after `view_image` — unless the sandbox denies the network,
    // where a fetch tool would be egress the confinement said no to (T5).
    var withWeb = context
    withWeb.web = WebFetchPolicy(allowedDomains: ["docs.example.com"])
    XCTAssertEqual(
      HarnessAssembly.coreTools(withWeb).map(\.name),
      ["read_file", "write_file", "edit_file", "bash", "grep", "glob", "view_image", "web_fetch", "update_plan", "think", "ask_user"])
    withWeb.sandbox = ShellSandbox(writableRoots: [root], allowNetwork: false)
    XCTAssertEqual(HarnessAssembly.coreTools(withWeb).map(\.name), core, "network off: no fetch tool")
  }

  func testRootBoundToolsResolveRelativePathsAgainstTheContextRoot() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("assembly-root-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try "hello".write(to: root.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
    let tools = HarnessAssembly.coreTools(ToolContext(root: root))
    let read = try XCTUnwrap(tools.first { $0.name == "read_file" })
    let output = try await read.execute(arguments: ["path": .string("note.txt")])
    XCTAssertTrue(output.contains("hello"), output)
  }

  // MARK: Configuration.forSubagent

  func testForSubagentCarriesPlumbingAndDropsTheUsersStopHooks() {
    let rules = PermissionRules(deny: ["Bash(git push:*)"], ask: [], allow: [])
    let cwd = URL(fileURLWithPath: "/tmp/project")
    let gateway = ProviderTraits(
      name: "gw", defaultModel: "sonnet", fallbackStyle: .litellmFallbacks,
      requestsStreamUsage: true, estimatesCost: true, nativeDialects: false)
    let parent = Session.Configuration(
      model: "lead/model",
      fallbackModels: ["lead/fallback"],
      maxStepsPerTurn: 12,
      dialect: .messages,
      projectInstructions: "CONVENTION X",
      hooks: [
        HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 1"),
        HookDefinition(event: .stop, command: "notify"),
      ],
      reasoningEffort: .high,
      provider: gateway,
      subprocessEnvironment: SubprocessEnvironment(policy: ShellEnvironmentPolicy(), redactedKeys: ["X_TOKEN"]),
      workingDirectory: cwd,
      permissionMode: .acceptEdits,
      permissionRules: rules)

    let nested = parent.forSubagent(named: "explore", model: "sub/model", systemSuffix: "# role")

    XCTAssertEqual(nested.model, "sub/model")
    XCTAssertEqual(nested.agent, "explore")
    XCTAssertEqual(nested.systemSuffix, "# role")
    XCTAssertEqual(nested.maxStepsPerTurn, 12)
    XCTAssertEqual(nested.provider, gateway)
    XCTAssertEqual(nested.subprocessEnvironment, parent.subprocessEnvironment)
    XCTAssertEqual(nested.workingDirectory, cwd)
    XCTAssertEqual(nested.permissionRules.deny, rules.deny)
    // Per-tool guardrails follow the work; the user's turn-end hook does not.
    XCTAssertEqual(nested.hooks.map(\.event), [.preToolUse])
    // Inherited: the wire dialect, the repo's standing instructions, the effort dial and
    // the permission posture all follow delegated work.
    XCTAssertEqual(nested.dialect, .messages)
    XCTAssertEqual(nested.projectInstructions, "CONVENTION X")
    XCTAssertEqual(nested.reasoningEffort, .high)
    XCTAssertEqual(nested.permissionMode, .acceptEdits)
    // Not inherited: the parent's fallbacks are chosen for the parent's model.
    XCTAssertEqual(nested.fallbackModels, [])
    // Uncapped unless the caller resolved a cap.
    XCTAssertNil(nested.maxCostUSD)
  }

  func testForSubagentNarrowsOnlyForCapsEffortAndReadOnlyAgents() {
    let parent = Session.Configuration(
      model: "lead/model",
      maxStepsPerTurn: 12,
      projectInstructions: "CONVENTION X",
      reasoningEffort: .high,
      permissionMode: .bypass)

    // A read-only explorer: no repo conventions it can act on, and a mode that never
    // auto-approves so the read-only delegate is always reached.
    let explorer = parent.forSubagent(
      named: "explore", model: "sub/model", systemSuffix: "# role",
      maxStepsPerTurn: 5, maxCostUSD: 0.02, reasoningEffort: .low,
      readOnly: true, inheritsProjectInstructions: false)
    XCTAssertEqual(explorer.maxStepsPerTurn, 5)
    XCTAssertEqual(explorer.maxCostUSD, 0.02)
    XCTAssertEqual(explorer.reasoningEffort, .low, "the agent's own dial beats the parent's")
    XCTAssertNil(explorer.projectInstructions)
    XCTAssertEqual(explorer.permissionMode, .default, "bypass must not auto-approve for a read-only agent")

    // Plan mode is narrower than "always ask", so it survives.
    var planning = parent
    planning.permissionMode = .plan
    let planned = planning.forSubagent(
      named: "explore", model: "sub/model", systemSuffix: "# role", readOnly: true)
    XCTAssertEqual(planned.permissionMode, .plan)
  }

  func testSessionKeepsItsConfigurationWhole() {
    let configuration = Session.Configuration(model: "test/model", maxStepsPerTurn: 3, maxCostUSD: 1.5)
    let session = Session(service: MockOpenRouterService(), tools: [], store: tempStore(), configuration: configuration)
    XCTAssertEqual(session.configuration.model, "test/model")
    XCTAssertEqual(session.configuration.maxStepsPerTurn, 3)
    XCTAssertEqual(session.configuration.maxCostUSD, 1.5)
  }

  // MARK: extraSystemSections

  func testExtraSystemSectionsRenderAfterInstructionsAndBeforeToolSections() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)]]
    let task = TaskTool(agents: [.general], service: mock, tools: [], store: tempStore())
    let session = Session(
      service: mock,
      tools: [task],
      store: tempStore(),
      configuration: .init(
        model: "test/model",
        projectInstructions: "# Project rules\nAlways do X.",
        extraSystemSections: ["# Environment\ncwd: /tmp", "", "# Note\nsecond"]))
    for try await _ in await session.send("hi") {}

    let system = try XCTUnwrap(mock.requests.first?.messages.first { $0.role == .system }?.content?.plainText)
    let instructions = try XCTUnwrap(system.range(of: "# Project rules"))
    let environment = try XCTUnwrap(system.range(of: "# Environment"))
    let note = try XCTUnwrap(system.range(of: "# Note"))
    let subagents = try XCTUnwrap(system.range(of: "# Subagents"))
    XCTAssertLessThan(instructions.lowerBound, environment.lowerBound)
    XCTAssertLessThan(environment.lowerBound, note.lowerBound)
    XCTAssertLessThan(note.lowerBound, subagents.lowerBound)
    // An empty section adds nothing (no stray separators).
    XCTAssertFalse(system.contains("\n\n\n\n"))
  }

  // MARK: StopReason

  func testStopReasonRecordedForCompletedMaxStepsBudgetAndError() async throws {
    // completed
    var mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)]]
    var session = Session(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    for try await _ in await session.send("go") {}
    var reason = await session.lastRecord?.stopReason
    XCTAssertEqual(reason, .completed)

    // max steps: every step calls the (free) think tool and the cap is 2.
    mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "a", name: "think", arguments: #"{"thought":"1"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "b", name: "think", arguments: #"{"thought":"2"}"#), Fixtures.usageChunk(cost: 0)],
    ]
    session = Session(
      service: mock, tools: [ThinkTool()], store: tempStore(),
      configuration: .init(model: "test/model", maxStepsPerTurn: 2))
    var sawStepLimit = false
    for try await event in await session.send("go") {
      if case .stepLimitReached = event { sawStepLimit = true }
    }
    XCTAssertTrue(sawStepLimit)
    reason = await session.lastRecord?.stopReason
    XCTAssertEqual(reason, .maxSteps)

    // budget: the stop is a budget stop, not also a step-limit stop.
    mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"x"}"#), Fixtures.usageChunk(cost: 0.01)],
    ]
    session = Session(
      service: mock, tools: [ThinkTool()], store: tempStore(),
      configuration: .init(model: "test/model", maxCostUSD: 0.005))
    var kinds: [AgentEvent.Kind] = []
    for try await event in await session.send("go") { kinds.append(event.kind) }
    XCTAssertTrue(kinds.contains(.budgetReached))
    XCTAssertFalse(kinds.contains(.stepLimitReached), "a budget stop must not also report a step limit")
    reason = await session.lastRecord?.stopReason
    XCTAssertEqual(reason, .budget)

    // error: the script runs out, the stream throws, the record still lands with .error.
    mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    session = Session(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    do {
      for try await _ in await session.send("go") {}
      XCTFail("expected the exhausted mock to throw")
    } catch {}
    reason = await session.lastRecord?.stopReason
    XCTAssertEqual(reason, .error)
  }

  func testRunRecordRoundTripsWithAndWithoutStopReason() throws {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.stopReason = .maxSteps
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoded = try encoder.encode(record)
    XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""stopReason":"max_steps""#))
    XCTAssertEqual(try decoder.decode(RunRecord.self, from: encoded).stopReason, .maxSteps)

    // A pre-field row decodes with nil; an unknown future reason also reads as nil
    // rather than dropping the row.
    let legacy = """
      {"id":"1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0,"finished":true}
      """
    XCTAssertNil(try decoder.decode(RunRecord.self, from: Data(legacy.utf8)).stopReason)
    let future = legacy.dropLast() + #","stopReason":"warp_core_breach"}"#
    XCTAssertNil(try decoder.decode(RunRecord.self, from: Data(future.utf8)).stopReason)
  }

  // MARK: Event kinds

  func testEveryEventCaseHasAKind() {
    let stats = Session.TurnStats(
      steps: 1, toolCalls: 0, turnCostUSD: 0, sessionCostUSD: 0, requestedModel: "m",
      routedModels: [], promptTokens: nil, contextLength: nil, durationSeconds: 0)
    // One fixture per case. Adding an `AgentEvent` case fails the exhaustive `kind` switch
    // in ArnesKit first; this asserts the fixture list here caught up too.
    let fixtures: [AgentEvent] = [
      .textDelta("a"), .reasoningDelta("r"), .assistantText("t"),
      .toolCall(name: "bash", arguments: "{}"), .toolResult(name: "bash", preview: "ok"),
      .toolDenied(name: "bash", reason: nil), .verifier(passed: true, verdict: "PASS"),
      .userQuestion(question: "Which one?", options: ["a", "b"]),
      .structuredOutput(json: ["ok": true], valid: true, errors: []),
      .routed(model: "m", provider: nil), .dialectFellBack(dialect: "messages", reason: "x"),
      .interrupted, .nudged(reason: "empty"), .stepLimitReached(maxSteps: 3),
      .budgetReached(spentUSD: 1, budgetUSD: 1), .hookNotice(event: "Stop", output: "o"),
      .hookBlocked(tool: "bash", reason: "no"), .hookStopped(reason: nil),
      .promptBlocked(reason: "no secrets"),
      .deniedLoop(count: 3),
      .stuckDetected(reason: "6 tool calls failed in a row"),
      .contentFlagged(tool: "read_file", patterns: ["role_imitation"]),
      .jobStarted(id: 1, command: "npm run dev"),
      .jobFinished(id: 1, exitStatus: 0),
      .retrying(attempt: 1, reason: "rate limited (429)"),
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
    XCTAssertEqual(Set(fixtures.map(\.kind)), Set(AgentEvent.Kind.allCases))
    XCTAssertEqual(fixtures.count, AgentEvent.Kind.allCases.count)
    XCTAssertEqual(AgentEvent.toolResultsCleared(count: 1, freedChars: 1).kind.rawValue, "tool_results_cleared")
    XCTAssertEqual(AgentEvent.contextWarning("x").kind.rawValue, "context_warning")
    XCTAssertEqual(AgentEvent.jobStarted(id: 1, command: "x").kind.rawValue, "job_started")
    XCTAssertEqual(AgentEvent.jobFinished(id: 1, exitStatus: 0).kind.rawValue, "job_finished")
    XCTAssertEqual(AgentEvent.planUpdated(steps: []).kind.rawValue, "plan_updated")
    // Stable wire spellings — the headless JSON keys on these.
    XCTAssertEqual(AgentEvent.toolCall(name: "x", arguments: "{}").kind.rawValue, "tool_call")
    XCTAssertEqual(AgentEvent.stepLimitReached(maxSteps: 1).kind.rawValue, "step_limit")
    XCTAssertEqual(AgentEvent.turnFinished(stats).kind.rawValue, "turn_finished")
    XCTAssertEqual(
      AgentEvent.structuredOutput(json: nil, valid: false, errors: []).kind.rawValue, "structured_output")
    XCTAssertEqual(AgentEvent.userQuestion(question: "q", options: []).kind.rawValue, "user_question")
    XCTAssertEqual(AgentEvent.contentFlagged(tool: "bash", patterns: []).kind.rawValue, "content_flagged")
    XCTAssertEqual(AgentEvent.retrying(attempt: 1, reason: "r").kind.rawValue, "retrying")
    XCTAssertEqual(AgentEvent.truncated.kind.rawValue, "truncated")
  }

  // MARK: Event funnel

  func testSubagentEventsRideTheParentSessionsStream() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScriptsByModel = [
      "lead/model": [
        [Fixtures.toolCallChunk(id: "c1", name: "task", arguments: #"{"agent":"helper","task":"look"}"#, model: "lead/model"),
         Fixtures.usageChunk(cost: 0, model: "lead/model")],
        [Fixtures.textChunk("done", model: "lead/model"), Fixtures.usageChunk(cost: 0, model: "lead/model")],
      ],
      "sub/model": [[
        Fixtures.toolCallChunk(id: "s1", name: "think", arguments: #"{"thought":"hm"}"#, model: "sub/model"),
        Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ], [
        Fixtures.textChunk("sub report", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ]],
    ]
    let store = tempStore()
    let helper = AgentDefinition(name: "helper", description: "", body: "b", model: "sub/model")
    let taskTool = TaskTool(agents: [helper], service: mock, tools: [ThinkTool()], store: store)
    let session = Session(service: mock, tools: [taskTool], store: store, configuration: .init(model: "lead/model"))
    taskTool.parentModel = { await session.model }

    var kinds: [AgentEvent.Kind] = []
    var nestedToolCalls: [String] = []
    for try await event in await session.send("go") {
      kinds.append(event.kind)
      if case .subagent("helper", _, .toolCall(let tool, _)) = event { nestedToolCalls.append(tool) }
    }
    // No side channel was wired, yet the nested progress arrived in the parent's stream,
    // between the lead's tool call and its result, in order.
    let started = try XCTUnwrap(kinds.firstIndex(of: .subagentStarted))
    let finished = try XCTUnwrap(kinds.firstIndex(of: .subagentFinished))
    let leadCall = try XCTUnwrap(kinds.firstIndex(of: .toolCall))
    let leadResult = try XCTUnwrap(kinds.firstIndex(of: .toolResult))
    XCTAssertLessThan(leadCall, started)
    XCTAssertLessThan(started, finished)
    XCTAssertLessThan(finished, leadResult)
    XCTAssertEqual(nestedToolCalls, ["think"])
    // After the turn the tool no longer points at the finished stream.
    XCTAssertNil(taskTool.onEvent)
  }

  // MARK: Notices

  func testNotifyIsDeliveredAsOneArnesUserMessageBeforeTheNextRequest() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)]]
    let session = Session(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    await session.notify("background job 1 finished")
    await session.notify("  ") // blank notices are dropped
    await session.notify("background job 2 finished")
    for try await _ in await session.send("what happened?") {}

    let messages = try XCTUnwrap(mock.requests.first?.messages)
    let users = messages.filter { $0.role == .user }.compactMap { $0.content?.plainText }
    XCTAssertEqual(users, ["what happened?", "[arnes] background job 1 finished\nbackground job 2 finished"])
    // Drained: the next turn carries no notice.
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)]]
    for try await _ in await session.send("again") {}
    let second = try XCTUnwrap(mock.requests.last?.messages).filter { $0.role == .user }
    XCTAssertEqual(second.compactMap { $0.content?.plainText }.filter { $0.hasPrefix("[arnes]") }.count, 1)
  }

  // MARK: Latching mock

  func testLatchingMockHoldsAStreamOpenUntilASecondStreamStarts() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0)],
    ]
    let latch = Latch()
    // Each stream arrives, then waits for both to have arrived: only concurrent consumers finish.
    mock.streamGate = { _ in
      await latch.arrive()
      await latch.wait(for: 2)
    }
    let store = tempStore()
    let a = Session(service: mock, tools: [], store: store, configuration: .init(model: "test/model"))
    let b = Session(service: mock, tools: [], store: store, configuration: .init(model: "test/model"))
    let finished = try await withDeadline(seconds: 5) {
      async let first: Void = { for try await _ in await a.send("x") {} }()
      async let second: Void = { for try await _ in await b.send("y") {} }()
      _ = try await (first, second)
      return true
    }
    XCTAssertEqual(finished, true, "two concurrent sessions should release each other's latch")
    let arrivals = await latch.count
    XCTAssertEqual(arrivals, 2)
  }
}
