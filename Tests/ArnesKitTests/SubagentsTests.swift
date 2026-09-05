import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class SubagentsTests: XCTestCase {
  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-agents-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeAgent(
    in root: URL, file: String, frontmatter: String?, body: String) throws
  {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let content = frontmatter.map { "---\n\($0)\n---\n\n\(body)" } ?? body
    try content.write(
      to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-agents-runs-\(UUID().uuidString).jsonl"))
  }

  // MARK: Parsing

  func testLoadParsesFrontmatterModelAndToolAliases() throws {
    let root = try tempDirectory()
    try writeAgent(
      in: root, file: "reviewer.md",
      frontmatter: """
        name: reviewer
        description: "Reviews diffs: correctness first."
        model: sonnet
        tools: Read, Grep, Glob, Task
        """,
      body: "You are a meticulous reviewer.")

    let agent = try XCTUnwrap(AgentLibrary.load(file: root.appendingPathComponent("reviewer.md")))
    XCTAssertEqual(agent.name, "reviewer")
    XCTAssertEqual(agent.description, "Reviews diffs: correctness first.")
    XCTAssertEqual(agent.model, "sonnet")
    // Claude Code tool names map to arnes names; Task never survives (no recursion).
    XCTAssertEqual(agent.tools, ["read_file", "grep", "glob"])
    XCTAssertEqual(agent.body, "You are a meticulous reviewer.")
  }

  func testLoadDefaultsNameToFilenameAndInheritModelToNil() throws {
    let root = try tempDirectory()
    try writeAgent(
      in: root, file: "digger.md",
      frontmatter: "description: digs\nmodel: inherit",
      body: "Dig.")

    let agent = try XCTUnwrap(AgentLibrary.load(file: root.appendingPathComponent("digger.md")))
    XCTAssertEqual(agent.name, "digger")
    XCTAssertNil(agent.model)
    XCTAssertNil(agent.tools)
  }

  func testLoadReturnsNilForMissingOrBodylessFile() throws {
    let root = try tempDirectory()
    XCTAssertNil(AgentLibrary.load(file: root.appendingPathComponent("absent.md")))
    try writeAgent(in: root, file: "empty.md", frontmatter: "name: empty", body: "")
    XCTAssertNil(AgentLibrary.load(file: root.appendingPathComponent("empty.md")))
  }

  // MARK: Discovery

  func testDiscoverPrefersProjectShadowsAndAppendsBuiltins() throws {
    let workdir = try tempDirectory()
    let home = try tempDirectory()
    try writeAgent(
      in: workdir.appendingPathComponent(".arnes/agents"), file: "reviewer.md",
      frontmatter: "name: reviewer\ndescription: project", body: "project version")
    try writeAgent(
      in: workdir.appendingPathComponent(".claude/agents"), file: "reviewer.md",
      frontmatter: "name: reviewer\ndescription: claude", body: "claude version")
    try writeAgent(
      in: home.appendingPathComponent(".arnes/agents"), file: "scout.md",
      frontmatter: "name: scout\ndescription: global", body: "scout body")

    let agents = AgentLibrary.discover(workdir: workdir, home: home)
    XCTAssertEqual(agents.map(\.name), ["reviewer", "scout", "general", "explore", "fork"])
    XCTAssertEqual(agents.first?.description, "project")
    XCTAssertNil(agents.last?.source) // built-ins carry no source file
    // The built-in explore agent is read-only by construction.
    let explore = try XCTUnwrap(agents.first { $0.name == "explore" })
    XCTAssertEqual(explore.tools, ["read_file", "grep", "glob"])
  }

  func testDiscoverWorksWithNoAgentFilesAtAll() throws {
    let agents = AgentLibrary.discover(workdir: try tempDirectory(), home: try tempDirectory())
    XCTAssertEqual(agents.map(\.name), ["general", "explore", "fork"])
  }

  func testDiscoverLetsAFileShadowTheBuiltinGeneral() throws {
    let workdir = try tempDirectory()
    let home = try tempDirectory()
    try writeAgent(
      in: workdir.appendingPathComponent(".arnes/agents"), file: "general.md",
      frontmatter: "name: general\ndescription: custom general\nmodel: sub/model",
      body: "Custom.")

    let agents = AgentLibrary.discover(workdir: workdir, home: home)
    XCTAssertEqual(agents.map(\.name), ["general", "explore", "fork"])
    XCTAssertEqual(agents.first?.description, "custom general")
    XCTAssertNotNil(agents.first?.source)
  }

  // MARK: Prompt section

  func testPromptSectionListsAgents() {
    let tool = TaskTool(
      agents: [
        AgentDefinition(name: "reviewer", description: "reviews diffs", body: "b"),
        .general,
      ],
      service: MockOpenRouterService(),
      tools: [],
      store: tempStore())
    XCTAssertTrue(tool.promptSection.contains("# Subagents"))
    XCTAssertTrue(tool.promptSection.contains("- reviewer: reviews diffs"))
    XCTAssertTrue(tool.promptSection.contains("- general"))
  }

  // MARK: Execution

  func testExecuteRunsNestedSessionAndReturnsReport() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("dug through it. verdict: fine", model: "sub/model"),
      Fixtures.usageChunk(cost: 0.02, model: "sub/model"),
    ]]

    let agent = AgentDefinition(
      name: "helper", description: "helps", body: "Help hard.", model: "sub/model")
    let tool = TaskTool(
      agents: [agent],
      service: mock,
      tools: [ReadFileTool()],
      store: tempStore())
    tool.parentModel = { "lead/model" }

    var events: [AgentEvent] = []
    tool.onEvent = { _ in }
    let collector = EventCollector()
    tool.onEvent = { collector.append($0) }

    let report = try await tool.execute(arguments: [
      "agent": .string("helper"),
      "task": .string("dig through the thing"),
    ])
    events = collector.events

    XCTAssertEqual(report, "dug through it. verdict: fine")
    // The nested request ran on the agent's model with its role in the system prompt.
    let request = try XCTUnwrap(mock.requests.first)
    XCTAssertEqual(request.model, "sub/model")
    let system = try XCTUnwrap(request.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertTrue(system.contains("You are 'helper'"))
    XCTAssertTrue(system.contains("Help hard."))
    // Spend accrued for the parent turn to drain; a second drain returns zero.
    XCTAssertEqual(tool.drainAccruedCost(), 0.02, accuracy: 0.0001)
    XCTAssertEqual(tool.drainAccruedCost(), 0)
    // Started → nested events → finished, in order.
    guard case .subagentStarted(let name, let id, let model, _) = try XCTUnwrap(events.first) else {
      return XCTFail("expected subagentStarted first, got \(String(describing: events.first))")
    }
    XCTAssertEqual(name, "helper")
    XCTAssertEqual(model, "sub/model")
    XCTAssertEqual(id.count, 8, "the run id is the nested session id, shortened")
    guard case .subagentFinished(_, let finishedId, _, _, let cost, let preview) = try XCTUnwrap(events.last) else {
      return XCTFail("expected subagentFinished last, got \(String(describing: events.last))")
    }
    XCTAssertEqual(cost, 0.02, accuracy: 0.0001)
    XCTAssertTrue(preview.hasPrefix("dug through it"))
    XCTAssertEqual(finishedId, id, "one delegation, one id from start to finish")
  }

  func testExecuteInheritsParentModelAndFuzzyResolvesQueries() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "acme/sonnet-9"))
    mock.chunkScripts = [
      [Fixtures.textChunk("a"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("b"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let inheriting = AgentDefinition(name: "kid", description: "", body: "b")
    let fuzzy = AgentDefinition(name: "fz", description: "", body: "b", model: "sonnet")
    let tool = TaskTool(
      agents: [inheriting, fuzzy], service: mock, tools: [], store: tempStore())
    tool.parentModel = { "lead/model" }

    _ = try await tool.execute(arguments: ["agent": .string("kid"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.model, "lead/model")

    // `model: sonnet` resolves against the manifest, never a hardcoded slug.
    _ = try await tool.execute(arguments: ["agent": .string("fz"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.model, "acme/sonnet-9")
  }

  func testModelOverrideBeatsFrontmatterAndInheritRestoresParent() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"),
      Fixtures.manifestModel(id: "other/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("a"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("b"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let agent = AgentDefinition(name: "helper", description: "", body: "b", model: "sub/model")
    let tool = TaskTool(agents: [agent], service: mock, tools: [], store: tempStore())
    tool.parentModel = { "lead/model" }

    tool.setModelOverride(agent: "helper", model: "other/model")
    XCTAssertEqual(tool.configuredModel(for: agent), "other/model")
    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.model, "other/model")

    tool.setModelOverride(agent: "helper", model: "inherit")
    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.model, "lead/model")

    tool.setModelOverride(agent: "helper", model: nil)
    XCTAssertEqual(tool.configuredModel(for: agent), "sub/model")
  }

  func testPerCallModelRequestBeatsFrontmatterButNotPins() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "sub/model"),
      Fixtures.manifestModel(id: "asked/model"),
      Fixtures.manifestModel(id: "pinned/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("a"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("b"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let agent = AgentDefinition(name: "helper", description: "", body: "b", model: "sub/model")
    let tool = TaskTool(agents: [agent], service: mock, tools: [], store: tempStore())

    // The lead relaying the user's in-prompt wish (fuzzy query) wins over frontmatter…
    _ = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("t"), "model": .string("asked"),
    ])
    XCTAssertEqual(mock.requests.last?.model, "asked/model")

    // …but an explicit user pin still beats the per-call request.
    tool.setModelOverride(agent: "helper", model: "pinned/model")
    _ = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("t"), "model": .string("asked"),
    ])
    XCTAssertEqual(mock.requests.last?.model, "pinned/model")
  }

  func testSubagentToolsetExcludesTaskToolAndHonorsAllowlist() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0.001)]]

    let restricted = AgentDefinition(
      name: "reader", description: "", body: "b", model: "sub/model",
      tools: ["read_file", "grep"])
    // The parent toolset deliberately includes another TaskTool — it must not leak in.
    let decoy = TaskTool(agents: [.general], service: mock, tools: [], store: tempStore())
    let tool = TaskTool(
      agents: [restricted],
      service: mock,
      tools: [ReadFileTool(), WriteFileTool(), BashTool(), decoy],
      store: tempStore())
    tool.parentModel = { "sub/model" }

    _ = try await tool.execute(arguments: ["agent": .string("reader"), "task": .string("t")])
    let names = (mock.requests.last?.tools ?? []).map(\.function.name)
    XCTAssertEqual(Set(names), ["read_file"]) // grep wasn't in the parent set; write/bash/task filtered
  }

  func testExecuteRejectsUnknownAgentAndMissingArguments() async throws {
    let tool = TaskTool(
      agents: [.general], service: MockOpenRouterService(), tools: [], store: tempStore())
    let unknown = try await tool.execute(arguments: [
      "agent": .string("nope"), "task": .string("t"),
    ])
    XCTAssertTrue(unknown.hasPrefix("error:"))
    XCTAssertTrue(unknown.contains("general"))
    let missing = try await tool.execute(arguments: ["agent": .string("general")])
    XCTAssertTrue(missing.hasPrefix("error:"))
  }

  // MARK: Session integration

  func testParentTurnAbsorbsSubagentCostAndRecordsAreTagged() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
    // Parent step 1 delegates; the subagent turn answers; parent step 2 wraps up.
    mock.chunkScriptsByModel = [
      "lead/model": [
        [
          Fixtures.toolCallChunk(
            id: "c1", name: "task",
            arguments: #"{"agent":"helper","task":"do the thing"}"#,
            model: "lead/model"),
          Fixtures.usageChunk(cost: 0.01, model: "lead/model"),
        ],
        [
          Fixtures.textChunk("all done", model: "lead/model"),
          Fixtures.usageChunk(cost: 0.01, model: "lead/model"),
        ],
      ],
      "sub/model": [[
        Fixtures.textChunk("sub report", model: "sub/model"),
        Fixtures.usageChunk(cost: 0.02, model: "sub/model"),
      ]],
    ]

    let store = tempStore()
    let agent = AgentDefinition(
      name: "helper", description: "helps", body: "Help.", model: "sub/model")
    let taskTool = TaskTool(agents: [agent], service: mock, tools: [], store: store)
    let session = Session(
      service: mock,
      tools: [taskTool],
      store: store,
      configuration: .init(model: "lead/model"))
    taskTool.parentModel = { await session.model }

    var stats: Session.TurnStats?
    for try await event in await session.send("go") {
      if case .turnFinished(let turnStats) = event { stats = turnStats }
    }

    // 0.01 + 0.01 parent + 0.02 subagent, all in the parent turn.
    XCTAssertEqual(try XCTUnwrap(stats).turnCostUSD, 0.04, accuracy: 0.0001)
    let sessionCost = await session.costUSD
    XCTAssertEqual(sessionCost, 0.04, accuracy: 0.0001)
    // The subagent listing rode the parent's system prompt.
    let leadSystem = mock.requests
      .first { $0.model == "lead/model" }?
      .messages.first { $0.role == .system }?.content?.plainText
    XCTAssertTrue(try XCTUnwrap(leadSystem).contains("# Subagents"))
    // Two records: the tagged subagent run and the lead turn carrying total cost.
    let records = try store.all()
    let subRecord = try XCTUnwrap(records.first { $0.agent == "helper" })
    XCTAssertEqual(subRecord.model, "sub/model")
    XCTAssertEqual(subRecord.costUSD, 0.02, accuracy: 0.0001)
    let leadRecord = try XCTUnwrap(records.first { $0.agent == nil })
    XCTAssertEqual(leadRecord.costUSD, 0.04, accuracy: 0.0001)
    XCTAssertTrue(leadRecord.finished)
  }

  // MARK: Frontmatter (the full Claude Code field set)

  func testLoadParsesDisallowedToolsPermissionModeCapsEffortColor() throws {
    let root = try tempDirectory()
    try writeAgent(
      in: root, file: "worker.md",
      frontmatter: """
        name: worker
        description: does the work
        tools: Read, Grep, Bash
        disallowedTools: Bash, Task
        permissionMode: plan
        maxTurns: 7
        budget: 0.25
        effort: low
        skills: arnes, review
        background: true
        isolation: worktree
        memory: project
        color: cyan
        """,
      body: "Work.")

    let agent = try XCTUnwrap(AgentLibrary.load(file: root.appendingPathComponent("worker.md")))
    XCTAssertEqual(agent.tools, ["read_file", "grep", "bash"])
    XCTAssertEqual(agent.disallowedTools, ["bash"], "Task maps to nothing, as in `tools:`")
    XCTAssertEqual(agent.permissionMode, .readOnly)
    XCTAssertEqual(agent.maxSteps, 7)
    XCTAssertEqual(agent.budgetUSD, 0.25)
    XCTAssertEqual(agent.effort, .low)
    XCTAssertEqual(agent.skills, ["arnes", "review"])
    XCTAssertTrue(agent.background)
    XCTAssertEqual(agent.isolation, "worktree")
    XCTAssertEqual(agent.memory, "project")
    XCTAssertEqual(agent.color, "cyan")
    XCTAssertTrue(agent.warnings.isEmpty, "\(agent.warnings)")
    // A read-only declaration is enough to make it an explorer, tools or not.
    XCTAssertTrue(agent.isReadOnlyExplorer)
  }

  func testWideningPermissionModeIsIgnoredWithWarning() throws {
    let root = try tempDirectory()
    try writeAgent(
      in: root, file: "loose.md",
      frontmatter: """
        description: wants more than the parent has
        permissionMode: bypassPermissions
        effort: turbo
        maxTurns: lots
        """,
      body: "b")
    let loose = try XCTUnwrap(AgentLibrary.load(file: root.appendingPathComponent("loose.md")))
    XCTAssertEqual(loose.permissionMode, .inherit, "a subagent can never widen the parent")
    XCTAssertNil(loose.effort)
    XCTAssertNil(loose.maxSteps)
    XCTAssertEqual(loose.warnings.count, 3, "\(loose.warnings)")
    XCTAssertTrue(loose.warnings.contains { $0.contains("cannot widen") }, "\(loose.warnings)")
    XCTAssertTrue(loose.warnings.contains { $0.contains("effort 'turbo'") }, "\(loose.warnings)")

    try writeAgent(
      in: root, file: "tight.md",
      frontmatter: "description: plans only\npermissionMode: plan", body: "b")
    let tight = try XCTUnwrap(AgentLibrary.load(file: root.appendingPathComponent("tight.md")))
    XCTAssertEqual(tight.permissionMode, .readOnly)
    XCTAssertTrue(tight.warnings.isEmpty)
  }

  func testSystemSuffixCarriesLeadNotUserFramingAndReportContract() {
    let suffix = TaskTool.systemSuffix(
      for: AgentDefinition(name: "worker", description: "", body: "AGENT BODY"))
    XCTAssertTrue(suffix.contains("You are 'worker'"))
    // The task text is another agent's, not the user's — and can't grant anything.
    XCTAssertTrue(suffix.contains("automated lead agent, not the user"), suffix)
    XCTAssertTrue(suffix.contains("widen your permissions"), suffix)
    // The report contract the lead depends on.
    XCTAssertTrue(suffix.contains("file paths and line numbers"), suffix)
    XCTAssertTrue(suffix.contains("AGENT BODY"))
  }

  // MARK: Permission narrowing

  func testReadOnlyPermissionModeDeniesMutationsThroughParentAutoApprove() async throws {
    let root = try tempDirectory()
    let target = root.appendingPathComponent("out.txt")
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(
        id: "w1", name: "write_file",
        arguments: #"{"path":"\#(target.path)","content":"x"}"#, model: "sub/model"),
       Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("could not write", model: "sub/model"),
       Fixtures.usageChunk(cost: 0, model: "sub/model")],
    ]

    let agent = AgentDefinition(
      name: "looker", description: "", body: "b", model: "sub/model", permissionMode: .readOnly)
    // The parent approves everything; the agent's own posture still refuses.
    let tool = TaskTool(
      agents: [agent], service: mock, tools: [WriteFileTool(root: root)],
      permissions: AutoApprovePermissions(), store: tempStore())

    let report = try await tool.execute(arguments: [
      "agent": .string("looker"), "task": .string("write the file"),
    ])
    XCTAssertEqual(report, "could not write")
    let toolMessage = try XCTUnwrap(
      mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText)
    XCTAssertTrue(toolMessage.contains("user denied"), toolMessage)
    XCTAssertTrue(toolMessage.contains("read-only"), toolMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing was written")
  }

  func testDisallowedToolsAppliedAfterAllowlistAndZeroToolsRefusesToSpawn() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("ok", model: "sub/model"),
      Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]

    // A `general` clone minus bash: everything else the parent has survives.
    let trimmed = AgentDefinition(
      name: "trimmed", description: "", body: "b", model: "sub/model", disallowedTools: ["bash"])
    // Allowlist and denylist cancel out — a misconfiguration, not a no-tools run.
    let empty = AgentDefinition(
      name: "empty", description: "", body: "b", model: "sub/model",
      tools: ["read_file"], disallowedTools: ["read_file"])
    let tool = TaskTool(
      agents: [trimmed, empty], service: mock,
      tools: [ReadFileTool(), WriteFileTool(), BashTool()], store: tempStore())

    _ = try await tool.execute(arguments: ["agent": .string("trimmed"), "task": .string("t")])
    XCTAssertEqual(
      Set((mock.requests.last?.tools ?? []).map(\.function.name)), ["read_file", "write_file"])

    let refused = try await tool.execute(arguments: ["agent": .string("empty"), "task": .string("t")])
    XCTAssertTrue(refused.hasPrefix("error:"), refused)
    XCTAssertTrue(refused.contains("zero tools"), refused)
    XCTAssertEqual(mock.requests.count, 1, "a zero-tool agent never spawns")
  }

  // MARK: Budget

  func testPerAgentBudgetStopsNestedRunAndReportIsMarkedPartial() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    // One step costs more than the whole budget; the pre-step check stops the next one.
    mock.chunkScripts = [[
      Fixtures.textChunk("found the file", model: "sub/model"),
      Fixtures.toolCallChunk(
        id: "t1", name: "think", arguments: #"{"thought":"more to do"}"#, model: "sub/model"),
      Fixtures.usageChunk(cost: 0.03, model: "sub/model"),
    ]]

    let agent = AgentDefinition(
      name: "spender", description: "", body: "b", model: "sub/model", budgetUSD: 0.02)
    let tool = TaskTool(agents: [agent], service: mock, tools: [ThinkTool()], store: tempStore())
    let collector = EventCollector()
    tool.onEvent = { collector.append($0) }

    let report = try await tool.execute(arguments: [
      "agent": .string("spender"), "task": .string("t"),
    ])
    XCTAssertTrue(report.hasPrefix("[subagent hit its budget"), report)
    XCTAssertTrue(report.contains("found the file"), "partial work still comes back: \(report)")
    XCTAssertEqual(mock.requests.count, 1, "the second step was never requested")
    let sawBudget = collector.events.contains {
      if case .subagent(_, _, .budgetReached) = $0 { return true }
      return false
    }
    XCTAssertTrue(sawBudget, "the nested budget stop should ride the subagent event stream")
  }

  func testParentRemainingBudgetCapsSubagentAndBlocksSpawnWhenExhausted() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[
      Fixtures.textChunk("partway", model: "sub/model"),
      Fixtures.toolCallChunk(
        id: "t1", name: "think", arguments: #"{"thought":"more"}"#, model: "sub/model"),
      Fixtures.usageChunk(cost: 0.02, model: "sub/model"),
    ]]

    // No budget of its own: the cap can only have come from the parent's remainder.
    let agent = AgentDefinition(name: "helper", description: "", body: "b", model: "sub/model")
    let tool = TaskTool(agents: [agent], service: mock, tools: [ThinkTool()], store: tempStore())
    let remaining = RemainingBudget(0.01)
    tool.parentBudgetRemaining = { await remaining.value }

    let capped = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("t")])
    XCTAssertTrue(capped.hasPrefix("[subagent hit its budget"), capped)
    XCTAssertTrue(capped.contains("of $0.0100"), capped)

    // Nothing left: delegating is not a way to keep spending.
    await remaining.set(0)
    let refused = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("t")])
    XCTAssertTrue(refused.contains("budget limit reached"), refused)
    XCTAssertEqual(mock.requests.count, 1, "the refused spawn sent nothing")
  }

  // MARK: Inheritance

  /// Both models advertise reasoning, so the effort dial is actually sent.
  private func reasoningManifest() -> String {
    let entry = { (id: String) in
      #"{"id":"\#(id)","context_length":8000,"supported_parameters":["tools","reasoning"],"pricing":{"prompt":"0","completion":"0"}}"#
    }
    return "[\(entry("lead/model")),\(entry("sub/model"))]"
  }

  func testSubagentFollowsTheLeadsLiveDialWhenBoundAndItsOwnFrontmatterFirst() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = reasoningManifest()
    mock.chunkScripts = [
      [Fixtures.textChunk("a", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("b", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("c", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
    ]
    let parent = Session.Configuration(model: "lead/model", dialect: .chat, reasoningEffort: .low)
    let worker = AgentDefinition(name: "worker", description: "", body: "b", model: "sub/model")
    let pinned = AgentDefinition(name: "pinned", description: "", body: "b", model: "sub/model", effort: .minimal)
    let tool = TaskTool(
      agents: [worker, pinned], service: mock, tools: [ReadFileTool()],
      store: tempStore(), configuration: parent)
    tool.parentModel = { "lead/model" }

    // `/effort high` after startup: the next spawn runs with the live dial, not the launch one.
    tool.parentEffort = { .high }
    _ = try await tool.execute(arguments: ["agent": .string("worker"), "task": .string("t")])
    var request = try XCTUnwrap(mock.requests.last)
    XCTAssertEqual(request.reasoning?.effort, .high, "the live dial, not the configuration's .low")

    // The agent's own frontmatter still wins over the lead's dial.
    _ = try await tool.execute(arguments: ["agent": .string("pinned"), "task": .string("t")])
    request = try XCTUnwrap(mock.requests.last)
    XCTAssertEqual(request.reasoning?.effort, .minimal)

    // `/effort off`: a bound nil is the dial switched off, not "inherit the launch dial".
    tool.parentEffort = { nil }
    _ = try await tool.execute(arguments: ["agent": .string("worker"), "task": .string("t")])
    request = try XCTUnwrap(mock.requests.last)
    XCTAssertNil(request.reasoning, "no reasoning field under /effort off")
  }

  func testSubagentInheritsEffortDialectAndProjectInstructions() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = reasoningManifest()
    mock.chunkScripts = [
      [Fixtures.textChunk("a", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
      [Fixtures.textChunk("b", model: "lead/model"), Fixtures.usageChunk(cost: 0, model: "lead/model")],
    ]

    let parent = Session.Configuration(
      model: "lead/model",
      dialect: .chat,
      projectInstructions: "CONVENTION X",
      reasoningEffort: .low)
    let worker = AgentDefinition(name: "worker", description: "", body: "b", model: "sub/model")
    let tool = TaskTool(
      agents: [worker, .explore], service: mock, tools: [ReadFileTool()],
      store: tempStore(), configuration: parent)
    tool.parentModel = { "lead/model" }

    _ = try await tool.execute(arguments: ["agent": .string("worker"), "task": .string("t")])
    var request = try XCTUnwrap(mock.requests.last)
    XCTAssertEqual(request.model, "sub/model")
    XCTAssertEqual(request.reasoning?.effort, .low, "the parent's dial follows delegated work")
    var system = try XCTUnwrap(request.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertTrue(system.contains("CONVENTION X"), "repo conventions ride along")

    // The read-only explorer can't act on repo conventions — it shouldn't pay for them.
    _ = try await tool.execute(arguments: ["agent": .string("explore"), "task": .string("t")])
    request = try XCTUnwrap(mock.requests.last)
    system = try XCTUnwrap(request.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertFalse(system.contains("CONVENTION X"), system)
    XCTAssertEqual(request.reasoning?.effort, .low)
  }

  func testFrontmatterEffortBeatsParentEffort() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = reasoningManifest()
    mock.chunkScripts = [[
      Fixtures.textChunk("a", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model"),
    ]]
    let parent = Session.Configuration(model: "lead/model", reasoningEffort: .low)
    let agent = AgentDefinition(
      name: "thinker", description: "", body: "b", model: "sub/model", effort: .high)
    let tool = TaskTool(
      agents: [agent], service: mock, tools: [], store: tempStore(), configuration: parent)

    _ = try await tool.execute(arguments: ["agent": .string("thinker"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.reasoning?.effort, .high)
  }

  // MARK: Model ladder

  func testModelLadderConfigDefaultAndEnvOverride() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"),
      Fixtures.manifestModel(id: "env/model"),
      Fixtures.manifestModel(id: "pinned/model"))
    mock.chunkScripts = Array(
      repeating: [Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)], count: 3)

    // No frontmatter model: the configured subagent default stands in before "inherit".
    let bare = AgentDefinition(name: "bare", description: "", body: "b")
    let defaults = TaskTool.Defaults(SubagentsConfig(defaultModel: "sub/model"))
    let configured = TaskTool(
      agents: [bare], service: mock, tools: [], store: tempStore(), defaults: defaults)
    configured.parentModel = { "lead/model" }
    XCTAssertEqual(configured.configuredModel(for: bare), "sub/model")
    _ = try await configured.execute(arguments: ["agent": .string("bare"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.model, "sub/model")

    // ARNES_SUBAGENT_MODEL re-points every agent for the run, beating frontmatter…
    let framed = AgentDefinition(name: "framed", description: "", body: "b", model: "sub/model")
    let overridden = TaskTool(
      agents: [framed], service: mock, tools: [], store: tempStore(),
      environment: ["ARNES_SUBAGENT_MODEL": "env/model"])
    overridden.parentModel = { "lead/model" }
    _ = try await overridden.execute(arguments: [
      "agent": .string("framed"), "task": .string("t"), "model": .string("sub/model"),
    ])
    XCTAssertEqual(mock.requests.last?.model, "env/model")

    // …but never the user's explicit pin.
    overridden.setModelOverride(agent: "framed", model: "pinned/model")
    _ = try await overridden.execute(arguments: ["agent": .string("framed"), "task": .string("t")])
    XCTAssertEqual(mock.requests.last?.model, "pinned/model")
  }
}

/// A parent budget a test can spend down between spawns.
private actor RemainingBudget {
  var value: Double?
  init(_ value: Double?) { self.value = value }
  func set(_ value: Double?) { self.value = value }
}

/// Collects events synchronously — TaskTool fires its hook inline on the executing task.
private final class EventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AgentEvent] = []
  var events: [AgentEvent] { lock.withLock { stored } }
  func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
}

final class SubagentAliasTests: XCTestCase {
  func testTaskToolModelFieldResolvesConfiguredAliasesWithoutAManifest() async throws {
    struct Down: Error {}
    let mock = MockOpenRouterService()
    mock.chunkScriptsByModel = ["claude-haiku-4-5-20251001": [[Fixtures.textChunk("report"), Fixtures.usageChunk(cost: 0)]]]
    let store = RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-alias-runs-\(UUID().uuidString).jsonl"))
    let tool = TaskTool(
      agents: [.explore], service: mock, tools: [], store: store,
      catalog: ModelCatalog(loader: { throw Down() }, aliases: ["haiku": "claude-haiku-4-5-20251001"]),
      provider: ProviderTraits(
        name: "gw", defaultModel: "claude-sonnet-5", fallbackStyle: .litellmFallbacks,
        requestsStreamUsage: true, estimatesCost: true, nativeDialects: false))
    tool.parentModel = { "claude-sonnet-5" }
    let result = try await tool.execute(arguments: ["agent": .string("explore"), "task": .string("look"), "model": .string("haiku")])
    XCTAssertEqual(result, "report")
    XCTAssertEqual(mock.requests.last?.model, "claude-haiku-4-5-20251001")

    // An unresolvable name goes out verbatim, fails, and the lead is told what would work.
    let failed = try await tool.execute(arguments: ["agent": .string("explore"), "task": .string("look"), "model": .string("flash")])
    XCTAssertTrue(failed.hasPrefix("error: subagent 'explore' failed"))
    XCTAssertTrue(failed.contains("configured aliases (haiku)"), failed)
  }
}
