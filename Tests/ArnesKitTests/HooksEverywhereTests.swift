import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// H6 — hooks everywhere: the one filter behind every nested run (`forNestedRun`), the
/// guarantees a nested session's hook engine gives (agent name, the parent's cwd, no
/// session-level events), and the dry-run engine behind `arnes hooks test`.
final class HooksEverywhereTests: XCTestCase {
  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h6-\(label)-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h6-runs-\(UUID().uuidString).jsonl"))
  }

  private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

  // MARK: forNestedRun

  func testForNestedRunKeepsThePerCallAndCompactionHooksAndDropsTheLeadsOwn() {
    let all = HookEvent.allCases.map { HookDefinition(event: $0, command: "true") }
    let nested = all.forNestedRun.map(\.event)
    XCTAssertEqual(
      Set(nested),
      [.preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .preCompact, .postCompact])
    XCTAssertEqual(
      Set(HookEvent.allCases).subtracting(nested), HookEvent.keptByTheLead,
      "every event is either inherited by a nested run or kept by the lead — no third state")
    // Configuration order is preserved: the filter is a filter, not a regrouping.
    XCTAssertEqual(nested, all.map(\.event).filter { !HookEvent.keptByTheLead.contains($0) })
  }

  func testForSubagentUsesTheSameFilterAsThePanelAndEvalRunners() {
    let all = HookEvent.allCases.map { HookDefinition(event: $0, command: "true") }
    let parent = Session.Configuration(hooks: all)
    let nested = parent.forSubagent(named: "helper", model: "m", systemSuffix: "s")
    XCTAssertEqual(nested.hooks, all.forNestedRun)
  }

  /// `Session.Configuration.hookEventsKeptByTheLead` is the older spelling of the same set —
  /// kept as a forwarding alias so a second filter written against it (a handler list) can
  /// never disagree with `forNestedRun`.
  func testConfigurationsKeptByTheLeadSpellingIsTheOneHookEventSet() {
    XCTAssertEqual(Session.Configuration.hookEventsKeptByTheLead, HookEvent.keptByTheLead)
    let all = HookEvent.allCases.map { HookDefinition(event: $0, command: "true") }
    XCTAssertEqual(
      all.filter { !Session.Configuration.hookEventsKeptByTheLead.contains($0.event) },
      all.forNestedRun)
  }

  // MARK: Nested engine guarantees

  /// A nested session's hook payload names the agent it runs as and the parent's working
  /// directory — what an `agent`-scoped guardrail and a path-relative hook both rely on.
  func testNestedSessionHookPayloadCarriesTheAgentNameAndTheParentsCwd() async throws {
    let root = try tempDir("nested-payload")
    defer { try? FileManager.default.removeItem(at: root) }
    let payloadFile = root.appendingPathComponent("payload.json")
    let envFile = root.appendingPathComponent("env.txt")

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "b1", name: "bash", arguments: #"{"command":"echo hi"}"#, model: "sub/model"),
       Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("done", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
    ]
    let hooks = [HookDefinition(
      event: .preToolUse, matcher: "bash",
      command: "cat > payload.json; printf '%s\\n%s\\n' \"$ARNES_AGENT_NAME\" \"$ARNES_CWD\" > env.txt")]
    let parent = Session.Configuration(hooks: hooks, workingDirectory: root)
    let tool = TaskTool(
      agents: [AgentDefinition(name: "helper", description: "helps", body: "Help.", model: "sub/model")],
      service: mock, tools: [BashTool(root: root)], store: tempStore(), configuration: parent)
    tool.parentModel = { "sub/model" }

    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("go")])

    // The hook ran in the parent's working directory (that's where the files landed) and the
    // payload says so; `agent` is the nested session's identity.
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: payloadFile))
    XCTAssertEqual(payload.agent, "helper")
    XCTAssertNil(payload.agentType, "agent_type is the delegation events' field; a tool event carries `agent`")
    XCTAssertEqual(payload.cwd, root.path)
    XCTAssertEqual(payload.toolName, "bash")
    XCTAssertEqual(payload.hookEventName, "PreToolUse")
    let env = try String(contentsOf: envFile, encoding: .utf8).split(separator: "\n").map(String.init)
    XCTAssertEqual(env, ["helper", root.path])
  }

  /// The lead's session-level and turn-end hooks are about the lead's session: none of them
  /// fires inside a delegation, whatever the nested run does.
  func testStopUserPromptSubmitAndSessionStartHooksNeverFireInsideANestedSession() async throws {
    let root = try tempDir("nested-lifecycle")
    defer { try? FileManager.default.removeItem(at: root) }
    let markers: [HookEvent: URL] = [
      .stop: root.appendingPathComponent("stop.marker"),
      .userPromptSubmit: root.appendingPathComponent("prompt.marker"),
      .sessionStart: root.appendingPathComponent("start.marker"),
      .sessionEnd: root.appendingPathComponent("end.marker"),
      .preToolUse: root.appendingPathComponent("pre.marker"),
    ]
    let hooks = markers.map { event, marker in
      HookDefinition(event: event, command: "touch '\(marker.path)'")
    }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "r1", name: "read_file", arguments: #"{"path":"none.txt"}"#, model: "sub/model"),
       Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("done", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
    ]
    let tool = TaskTool(
      agents: [AgentDefinition(name: "helper", description: "helps", body: "Help.", model: "sub/model")],
      service: mock, tools: [ReadFileTool(root: root)], store: tempStore(),
      configuration: Session.Configuration(hooks: hooks, workingDirectory: root))
    tool.parentModel = { "sub/model" }

    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("go")])

    XCTAssertTrue(exists(markers[.preToolUse]!), "the per-call hook follows the work")
    for event in [HookEvent.stop, .userPromptSubmit, .sessionStart, .sessionEnd] {
      XCTAssertFalse(exists(markers[event]!), "\(event.rawValue) must not fire inside a nested session")
    }
  }

  /// `agent: explore` on a PreToolUse hook: the explorer's bash is blocked, the lead's runs.
  func testAgentScopedPreToolUseHookFiresForTheExplorerAndNotForTheLead() async throws {
    let root = try tempDir("agent-scoped")
    defer { try? FileManager.default.removeItem(at: root) }
    let hooks = [HookDefinition(
      event: .preToolUse, matcher: "bash", agent: "explore",
      command: "echo 'explorers do not run commands' >&2; exit 2")]
    let configuration = Session.Configuration(model: "lead/model", hooks: hooks, workingDirectory: root)

    // The lead: same configuration, same hook — not about it.
    let leadMock = MockOpenRouterService()
    leadMock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "lead/model"))
    leadMock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "l1", name: "bash", arguments: #"{"command":"echo lead-ran"}"#, model: "lead/model"),
       Fixtures.usageChunk(cost: 0, model: "lead/model")],
      [Fixtures.textChunk("done", model: "lead/model"), Fixtures.usageChunk(cost: 0, model: "lead/model")],
    ]
    let lead = Session(
      service: leadMock, tools: [BashTool(root: root)], permissions: AutoApprovePermissions(),
      store: tempStore(), configuration: configuration)
    for try await _ in await lead.send("run it") {}
    let leadToolMessage = try XCTUnwrap(leadMock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText)
    XCTAssertTrue(leadToolMessage.contains("lead-ran"), leadToolMessage)
    XCTAssertFalse(leadToolMessage.contains("blocked by hook"), leadToolMessage)

    // The explorer: the nested engine carries `agent: explore`, so the same hook applies.
    let subMock = MockOpenRouterService()
    subMock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    subMock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "e1", name: "bash", arguments: #"{"command":"echo explorer-ran"}"#, model: "sub/model"),
       Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("blocked", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
    ]
    let tool = TaskTool(
      agents: [AgentDefinition(name: "explore", description: "looks", body: "Look.", model: "sub/model")],
      service: subMock, tools: [BashTool(root: root)], store: tempStore(), configuration: configuration)
    tool.parentModel = { "lead/model" }
    _ = try await tool.execute(arguments: ["agent": .string("explore"), "task": .string("go")])
    let nestedToolMessage = try XCTUnwrap(subMock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText)
    XCTAssertTrue(nestedToolMessage.contains("blocked by hook"), nestedToolMessage)
    XCTAssertTrue(nestedToolMessage.contains("explorers do not run commands"), nestedToolMessage)
    XCTAssertFalse(nestedToolMessage.contains("explorer-ran"), nestedToolMessage)
  }

  // MARK: Dry run

  func testDryRunReportsEveryHookOfTheEventWithWhyItWasSkipped() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, matcher: "bash", command: "echo 'no rm' >&2; exit 2", id: "no-rm"),
      HookDefinition(event: .preToolUse, matcher: "edit_file", command: "exit 2", id: "other-tool"),
      HookDefinition(event: .preToolUse, matcher: "bash", when: ["command": "^git push"], command: "exit 2", id: "push-only"),
      HookDefinition(event: .preToolUse, matcher: "bash", agent: "explore", command: "exit 2", id: "explorers"),
      HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 2", id: "off", enabled: false),
      HookDefinition(event: .postToolUse, matcher: "bash", command: "echo after", id: "after"),
      HookDefinition(event: .preToolUse, matcher: "bash", prompt: "Safe? $ARGUMENTS", id: "judge"),
    ])
    let reports = await engine.dryRun(
      event: .preToolUse, subject: "bash", argumentsJSON: #"{"command":"rm -rf /tmp/x"}"#)
    XCTAssertEqual(reports.map { $0.hook.id }, ["no-rm", "other-tool", "push-only", "explorers", "off", "judge"],
                   "every PreToolUse hook is reported, in configuration order; the PostToolUse one is not")
    XCTAssertEqual(reports.map(\.skipped), [nil, .matcher, .when, .agent, .disabled, .prompt])
    XCTAssertEqual(reports[2].failedWhenKeys, ["command"])
    // A prompt hook that applies is listed, not asked: no runner failure, and it still counts as
    // one a real run would execute.
    XCTAssertNil(reports[5].failure)
    XCTAssertTrue(reports[5].applied)

    let ran = reports[0]
    XCTAssertTrue(ran.applied)
    XCTAssertEqual(ran.exitCode, 2)
    XCTAssertEqual(ran.output.trimmingCharacters(in: .whitespacesAndNewlines), "no rm")
    XCTAssertEqual(ran.outcome?.decision, .deny(reason: "no rm"))
    XCTAssertNil(ran.failure)
  }

  func testDryRunNamesTheMistypedWhenPathAndRunsWhenItMatches() async throws {
    let root = try tempDir("dry-when")
    defer { try? FileManager.default.removeItem(at: root) }
    // The check the command exists for: a path glob that never matches disables the hook
    // silently in a real run; the dry run says which key.
    let engine = HookEngine(hooks: [
      HookDefinition(event: .postToolUse, matcher: "edit_file", when: ["path": "**/*.swfit"], command: "echo formatted", id: "typo"),
      HookDefinition(event: .postToolUse, matcher: "edit_file", when: ["path": "**/*.swift"], command: "echo formatted", id: "right"),
    ], cwd: root)
    let reports = await engine.dryRun(
      event: .postToolUse, subject: "edit_file", argumentsJSON: #"{"path":"src/x.swift"}"#)
    XCTAssertEqual(reports[0].skipped, .when)
    XCTAssertEqual(reports[0].failedWhenKeys, ["path"])
    XCTAssertNil(reports[1].skipped)
    XCTAssertEqual(reports[1].outcome?.feedback, "formatted")
  }

  func testDryRunDoesNotShortCircuitAndHonorsTheProjectNarrowing() async {
    // A real gate stops at the first deny; the dry run wants every hook's own answer.
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, command: "exit 2", id: "first"),
      HookDefinition(event: .preToolUse, command: "echo also >&2; exit 2", id: "second"),
      HookDefinition(
        event: .preToolUse,
        command: #"echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'"#, id: "project-allow", source: .project),
      HookDefinition(event: .preToolUse, command: "exit 1", failClosed: true, id: "closed"),
    ])
    let reports = await engine.dryRun(event: .preToolUse, subject: "bash", argumentsJSON: "{}")
    XCTAssertEqual(reports.count, 4)
    XCTAssertTrue(reports.allSatisfy(\.applied))
    XCTAssertEqual(reports[0].outcome?.decision, .deny(reason: "blocked by a PreToolUse hook"))
    XCTAssertEqual(reports[1].outcome?.decision, .deny(reason: "also"))
    XCTAssertEqual(reports[2].outcome?.decision, HookOutcome.Decision.none, "a project hook's allow is dropped, as in a run")
    XCTAssertEqual(reports[3].exitCode, 1)
    XCTAssertTrue(reports[3].outcome?.blockReason?.contains("failClosed") == true, "\(reports[3])")
  }

  func testDryRunPayloadNamesTheTestAndTheAgentAndCarriesTheSubjectForSessionEvents() async throws {
    let root = try tempDir("dry-payload")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = HookEngine(
      hooks: [
        HookDefinition(event: .preToolUse, command: "cat > pre.json"),
        HookDefinition(event: .sessionStart, matcher: "resume", command: "cat > start.json"),
        HookDefinition(event: .subagentStart, matcher: "explore", command: "cat > spawn.json"),
        HookDefinition(event: .userPromptSubmit, when: ["prompt": "(?i)password"], command: "cat > prompt.json"),
        HookDefinition(event: .stop, matcher: "ignored-on-stop", command: "cat > stop.json"),
      ],
      cwd: root, agent: "explore")

    _ = await engine.dryRun(event: .preToolUse, subject: "bash", argumentsJSON: #"{"command":"ls"}"#)
    let pre = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: root.appendingPathComponent("pre.json")))
    XCTAssertEqual(pre.sessionId, HookEngine.dryRunSessionId)
    XCTAssertEqual(pre.agent, "explore")
    XCTAssertEqual(pre.toolInput, .object(["command": .string("ls")]))
    XCTAssertEqual(pre.cwd, root.path)

    let start = await engine.dryRun(event: .sessionStart, subject: "resume")
    XCTAssertEqual(start.first?.skipped, nil)
    let startPayload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: root.appendingPathComponent("start.json")))
    XCTAssertEqual(startPayload.source, "resume")
    let startup = await engine.dryRun(event: .sessionStart, subject: "startup")
    XCTAssertEqual(startup.first?.skipped, .matcher)

    let spawn = await engine.dryRun(event: .subagentStart, subject: "explore")
    XCTAssertNil(spawn.first?.skipped)
    let spawnPayload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: root.appendingPathComponent("spawn.json")))
    XCTAssertEqual(spawnPayload.agentType, "explore")
    XCTAssertEqual(spawnPayload.agentId, HookEngine.dryRunSessionId)

    let prompt = await engine.dryRun(event: .userPromptSubmit, subject: "what is the password")
    XCTAssertNil(prompt.first?.skipped, "UserPromptSubmit's subject is the prompt, seen by `when`")
    let harmless = await engine.dryRun(event: .userPromptSubmit, subject: "hello")
    XCTAssertEqual(harmless.first?.skipped, .when)

    let stop = await engine.dryRun(event: .stop, subject: nil)
    XCTAssertNil(stop.first?.skipped, "Stop has no matcher subject; a matcher on it is ignored, as in a run")
  }

  /// A dry run that names no subject takes the event's default — and the matcher is tested
  /// against that default, not skipped: `hooks test SubagentStart --agent explore` must
  /// report a `matcher: reviewer` hook skipped, the way `subagentStart(agent: "explore")`
  /// skips it, and `hooks test SessionStart` (source `startup`) a `matcher: resume` one.
  func testDryRunTestsTheMatcherAgainstTheDefaultedSubject() async throws {
    let root = try tempDir("dry-default-subject")
    defer { try? FileManager.default.removeItem(at: root) }
    let engine = HookEngine(
      hooks: [
        HookDefinition(event: .subagentStart, matcher: "reviewer", command: "cat > reviewer.json", id: "reviewer"),
        HookDefinition(event: .subagentStart, matcher: "explore", command: "cat > explore.json", id: "explore"),
        HookDefinition(event: .sessionStart, matcher: "resume", command: "true", id: "on-resume"),
        HookDefinition(event: .sessionStart, matcher: "startup", command: "cat > startup.json", id: "on-startup"),
        HookDefinition(event: .sessionEnd, matcher: "clear", command: "true", id: "on-clear"),
        HookDefinition(event: .preCompact, matcher: "auto", command: "true", id: "on-auto"),
        HookDefinition(event: .notification, matcher: "permission_prompt", command: "true", id: "on-prompt"),
      ],
      cwd: root, agent: "explore")

    let spawn = await engine.dryRun(event: .subagentStart, subject: nil)
    XCTAssertEqual(spawn.map(\.skipped), [.matcher, nil], "the engine's agent is the subject; `reviewer` doesn't match it")
    let spawnPayload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: root.appendingPathComponent("explore.json")))
    XCTAssertEqual(spawnPayload.agentType, "explore", "payload and matcher saw the same subject")
    XCTAssertFalse(exists(root.appendingPathComponent("reviewer.json")))

    let start = await engine.dryRun(event: .sessionStart, subject: nil)
    XCTAssertEqual(start.map(\.skipped), [.matcher, nil])
    let startPayload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: root.appendingPathComponent("startup.json")))
    XCTAssertEqual(startPayload.source, "startup")

    let end = await engine.dryRun(event: .sessionEnd, subject: nil)
    XCTAssertEqual(end.first?.skipped, .matcher, "default reason is `exit`")
    let compact = await engine.dryRun(event: .preCompact, subject: nil)
    XCTAssertEqual(compact.first?.skipped, .matcher, "default trigger is `manual`")
    let notification = await engine.dryRun(event: .notification, subject: nil)
    XCTAssertNil(notification.first?.skipped, "default type is `permission_prompt`")

    // An engine with no agent falls back to `general` for the delegation pair.
    let lead = HookEngine(
      hooks: [HookDefinition(event: .subagentStop, matcher: "general", command: "true", id: "general")], cwd: root)
    let stop = await lead.dryRun(event: .subagentStop, subject: nil)
    XCTAssertNil(stop.first?.skipped)
  }
}
