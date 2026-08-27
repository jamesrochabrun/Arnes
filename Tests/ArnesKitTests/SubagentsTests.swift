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
    XCTAssertEqual(agents.map(\.name), ["reviewer", "scout", "general", "explore"])
    XCTAssertEqual(agents.first?.description, "project")
    XCTAssertNil(agents.last?.source) // built-ins carry no source file
    // The built-in explore agent is read-only by construction.
    let explore = try XCTUnwrap(agents.first { $0.name == "explore" })
    XCTAssertEqual(explore.tools, ["read_file", "grep", "glob"])
  }

  func testDiscoverWorksWithNoAgentFilesAtAll() throws {
    let agents = AgentLibrary.discover(workdir: try tempDirectory(), home: try tempDirectory())
    XCTAssertEqual(agents.map(\.name), ["general", "explore"])
  }

  func testDiscoverLetsAFileShadowTheBuiltinGeneral() throws {
    let workdir = try tempDirectory()
    let home = try tempDirectory()
    try writeAgent(
      in: workdir.appendingPathComponent(".arnes/agents"), file: "general.md",
      frontmatter: "name: general\ndescription: custom general\nmodel: sub/model",
      body: "Custom.")

    let agents = AgentLibrary.discover(workdir: workdir, home: home)
    XCTAssertEqual(agents.map(\.name), ["general", "explore"])
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
    guard case .subagentStarted(let name, let model, _) = try XCTUnwrap(events.first) else {
      return XCTFail("expected subagentStarted first, got \(String(describing: events.first))")
    }
    XCTAssertEqual(name, "helper")
    XCTAssertEqual(model, "sub/model")
    guard case .subagentFinished(_, _, _, let cost, let preview) = try XCTUnwrap(events.last) else {
      return XCTFail("expected subagentFinished last, got \(String(describing: events.last))")
    }
    XCTAssertEqual(cost, 0.02, accuracy: 0.0001)
    XCTAssertTrue(preview.hasPrefix("dug through it"))
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
}

/// Collects events synchronously — TaskTool fires its hook inline on the executing task.
private final class EventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AgentEvent] = []
  var events: [AgentEvent] { lock.withLock { stored } }
  func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
}
