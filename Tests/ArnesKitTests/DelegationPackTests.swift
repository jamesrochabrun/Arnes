import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// A6 — delegation guidance lives in the prompt pack (`PromptPack.delegation`), rendered by
/// the session only when the toolset carries the `task` tool; the `# Subagents` section
/// shrinks to the listing; a `## Delegation` section in a pack override replaces the text;
/// `EvalRunner(subagents:)` gives a trial the task tool so `evals/subagents` can score it.
final class DelegationPackTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-delegation-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func systemPrompt(of request: ChatCompletionRequest) throws -> String {
    try XCTUnwrap(request.messages.first { $0.role == .system }?.content?.plainText)
  }

  /// The `# Delegation` section of a system prompt: from its heading to the next `\n\n# `
  /// heading or the end.
  private func delegationSection(in system: String) throws -> String {
    let start = try XCTUnwrap(system.range(of: "# Delegation"))
    let rest = system[start.lowerBound...]
    if let next = rest.dropFirst().range(of: "\n\n# ") {
      return String(rest[..<next.lowerBound])
    }
    return String(rest)
  }

  private func mockWithOneReply(_ replies: Int = 1) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = (0..<replies).map { _ in
      [Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)]
    }
    return mock
  }

  private static var repoRoot: URL {
    // Tests/ArnesKitTests/DelegationPackTests.swift → the repository root.
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  // MARK: The section rides the system prompt only with the task tool

  func testDelegationSectionFollowsTheSubagentListingWhenTheTaskToolIsPresent() async throws {
    let mock = mockWithOneReply()
    let task = TaskTool(agents: [.general, .explore], service: mock, tools: [], store: tempStore())
    let session = Session(
      service: mock,
      tools: [task],
      store: tempStore(),
      configuration: .init(model: "test/model", systemSuffix: "# Role\n\nBe brief."))
    for try await _ in await session.send("hi") {}

    let system = try systemPrompt(of: try XCTUnwrap(mock.requests.first))
    let subagents = try XCTUnwrap(system.range(of: "# Subagents"))
    let delegation = try XCTUnwrap(system.range(of: "# Delegation"))
    let role = try XCTUnwrap(system.range(of: "# Role"))
    XCTAssertLessThan(subagents.lowerBound, delegation.lowerBound, "after the listing it refers to")
    XCTAssertLessThan(delegation.lowerBound, role.lowerBound, "before the embedder's suffix")
    // The section is the pack's, verbatim — compared against what the session itself loads
    // for this model's family (the default `~/.arnes/packs`; the Session has no override
    // seam), so a developer's own `other.md` doesn't fail the test. With no override that is
    // `baseDelegation` (pinned by testFamilyDefaultsAppendAParagraphOnlyWhereConfigured).
    let expected = PromptPack.load(for: .other).delegation
    XCTAssertTrue(system.contains(expected))
    XCTAssertEqual(try delegationSection(in: system), expected)
  }

  func testNoDelegationSectionWithoutTheTaskTool() async throws {
    let mock = mockWithOneReply()
    let root = try tempDirectory("no-task")
    defer { try? FileManager.default.removeItem(at: root) }
    let session = Session(
      service: mock,
      tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      store: tempStore(),
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("hi") {}

    let system = try systemPrompt(of: try XCTUnwrap(mock.requests.first))
    XCTAssertFalse(system.contains("# Delegation"))
    XCTAssertFalse(system.contains("Do simple tasks yourself"))
  }

  func testDelegationSectionIsByteIdenticalAcrossTurns() async throws {
    let mock = mockWithOneReply(2)
    let task = TaskTool(agents: [.general], service: mock, tools: [], store: tempStore())
    let session = Session(
      service: mock, tools: [task], store: tempStore(), configuration: .init(model: "test/model"))
    for try await _ in await session.send("one") {}
    for try await _ in await session.send("two") {}

    XCTAssertEqual(mock.requests.count, 2)
    let first = try delegationSection(in: try systemPrompt(of: mock.requests[0]))
    let second = try delegationSection(in: try systemPrompt(of: mock.requests[1]))
    XCTAssertEqual(first, second, "a stable prefix is what prompt caching keys on")
  }

  // MARK: Family defaults

  func testFamilyDefaultsAppendAParagraphOnlyWhereConfigured() {
    let none = URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)")
    let other = PromptPack.load(for: .other, overridesDirectory: none)
    let anthropic = PromptPack.load(for: .anthropic, overridesDirectory: none)
    let deepseek = PromptPack.load(for: .deepseek, overridesDirectory: none)

    XCTAssertEqual(other.delegation, PromptPack.baseDelegation, "no entry → the base alone")
    XCTAssertTrue(anthropic.delegation.hasPrefix(PromptPack.baseDelegation))
    XCTAssertNotEqual(anthropic.delegation, other.delegation)
    XCTAssertTrue(anthropic.delegation.contains("Prefer working directly"), "the damping lean")
    XCTAssertTrue(deepseek.delegation.hasPrefix(PromptPack.baseDelegation))
    // The nudge names the *kind* of agent first and the built-in only as the usual instance,
    // so an embedder's custom agent list leaves no dangling reference.
    XCTAssertTrue(deepseek.delegation.contains("read-only search subagent (explore, when it is listed)"), "the explore nudge")
    XCTAssertFalse(anthropic.delegation.contains("read-only search subagent"))
    // Every section opens with the heading the session places it under, exactly once.
    for pack in [other, anthropic, deepseek] {
      XCTAssertTrue(pack.delegation.hasPrefix("# Delegation\n\n"))
      XCTAssertEqual(pack.delegation.components(separatedBy: "# Delegation").count, 2)
    }
    // The adapter text is untouched by the delegation split.
    XCTAssertTrue(anthropic.text.contains("step by step"))
    XCTAssertFalse(anthropic.text.contains("# Delegation"), "delegation is its own section, not part of `text`")
    // The base stays small: it rides every request of a session that can delegate.
    let words = PromptPack.baseDelegation.split(whereSeparator: { $0.isWhitespace }).count
    XCTAssertLessThanOrEqual(words, 200, "baseDelegation is \(words) words")
  }

  // MARK: User override

  func testPackOverrideDelegationSectionReplacesTheTextAndTheRestStaysTheAdapter() throws {
    let dir = try tempDirectory("packs")
    defer { try? FileManager.default.removeItem(at: dir) }
    try """
      CUSTOM RULES for openai.

      ### delegation:

      Never delegate. Do everything yourself.

      #### A sub-point

      Still part of the delegation section.

      ## Other heading

      Kept in the adapter.
      """.write(to: dir.appendingPathComponent("openai.md"), atomically: true, encoding: .utf8)

    let pack = PromptPack.load(for: .openai, overridesDirectory: dir)
    XCTAssertEqual(
      pack.delegation,
      "# Delegation\n\nNever delegate. Do everything yourself.\n\n#### A sub-point\n\nStill part of the delegation section.")
    XCTAssertFalse(pack.delegation.contains("Do simple tasks yourself"), "the whole section is replaced")
    // The adapter is the file minus the section: heading matched at any level, case-insensitive,
    // trailing colon tolerated; the section ends at the next heading of the same or higher level.
    XCTAssertTrue(pack.text.hasPrefix(PromptPack.basePrompt), "the base prompt still leads")
    XCTAssertTrue(pack.text.contains("CUSTOM RULES for openai."))
    XCTAssertTrue(pack.text.contains("## Other heading\n\nKept in the adapter."))
    XCTAssertFalse(pack.text.contains("Never delegate"))
    XCTAssertFalse(pack.text.contains("### delegation"))
    XCTAssertFalse(pack.text.contains("A sub-point"))
  }

  func testPackOverrideWithoutTheHeadingChangesNothing() throws {
    let dir = try tempDirectory("packs-plain")
    defer { try? FileManager.default.removeItem(at: dir) }
    let override = "CUSTOM RULES\n\nA line mentioning delegation in prose, not a heading.\n"
    try override.write(to: dir.appendingPathComponent("anthropic.md"), atomically: true, encoding: .utf8)

    let pack = PromptPack.load(for: .anthropic, overridesDirectory: dir)
    XCTAssertEqual(pack.text, PromptPack.basePrompt + "\n\n" + override, "byte for byte as before")
    XCTAssertEqual(
      pack.delegation,
      PromptPack.load(for: .anthropic, overridesDirectory: URL(fileURLWithPath: "/nonexistent")).delegation,
      "the family default still applies")
  }

  func testPackOverrideWithAnEmptyDelegationSectionKeepsTheDefaultAndLiftsTheHeading() throws {
    let dir = try tempDirectory("packs-empty")
    defer { try? FileManager.default.removeItem(at: dir) }
    // A heading with nothing under it — before the next heading, or at the end of the file.
    for override in ["Adapter.\n\n## Delegation\n\n## More\n\nStill adapter.\n", "Adapter.\n\n## Delegation\n"] {
      try override.write(to: dir.appendingPathComponent("qwen.md"), atomically: true, encoding: .utf8)

      let pack = PromptPack.load(for: .qwen, overridesDirectory: dir)
      XCTAssertEqual(pack.delegation, PromptPack.baseDelegation, "an empty section is the built-in text")
      XCTAssertFalse(pack.text.contains("Delegation"), "the bare heading never rides the adapter: \(override)")
      XCTAssertTrue(pack.text.hasPrefix(PromptPack.basePrompt + "\n\nAdapter."))
    }
    // The compact-instructions split keeps its contract: an empty section is no guidance.
    let compact = ProjectInstructions.splitCompactInstructions("Rules.\n\n## Compact instructions\n")
    XCTAssertNil(compact.compact)
    XCTAssertEqual(compact.body, "Rules.")
  }

  func testDelegationHeadingInsideAFenceIsNotASection() throws {
    let dir = try tempDirectory("packs-fence")
    defer { try? FileManager.default.removeItem(at: dir) }
    let override = "Adapter.\n\n```\n## Delegation\nnot a section\n```\n"
    try override.write(to: dir.appendingPathComponent("other.md"), atomically: true, encoding: .utf8)

    let pack = PromptPack.load(for: .other, overridesDirectory: dir)
    XCTAssertEqual(pack.delegation, PromptPack.baseDelegation)
    XCTAssertEqual(pack.text, PromptPack.basePrompt + "\n\n" + override)
  }

  // MARK: The listing section is listing-only

  func testPromptSectionIsTheListingAndTheModelSentenceOnly() {
    let tool = TaskTool(
      agents: [AgentDefinition(name: "reviewer", description: "reviews diffs", body: "b"), .explore],
      service: MockOpenRouterService(), tools: [], store: tempStore())
    let section = tool.promptSection
    XCTAssertTrue(section.hasPrefix("# Subagents\n\n"))
    XCTAssertTrue(section.contains("- reviewer: reviews diffs"))
    XCTAssertTrue(section.contains("- explore:"))
    // Harness plumbing stays: the user owns subagent models.
    XCTAssertTrue(section.contains("Never choose a subagent's model yourself"))
    // The orchestration prose moved into the pack.
    XCTAssertFalse(section.contains("fresh context"))
    XCTAssertFalse(section.contains("keep a large exploration out of your own context"))
    XCTAssertFalse(section.contains("background: true"))
    XCTAssertTrue(PromptPack.baseDelegation.contains("background: true"))
    XCTAssertTrue(PromptPack.baseDelegation.contains("sees only the task text you pass"))
  }

  // MARK: evals/subagents

  func testSubagentsSuiteDecodes() throws {
    let suite = try EvalSuite.load(path: Self.repoRoot.appendingPathComponent("evals/subagents").path)
    XCTAssertEqual(suite.name, "subagents")
    // P1 added the noisy probe and A9 the judgment one; every check reads `ARNES_SESSION_ID` first and keeps the
    // `.runs-before` line delta as its fallback (ProposalsABTests pins the rest).
    XCTAssertEqual(suite.tasks.map(\.id), ["wide-search-delegates", "trivial-task-stays-direct", "noisy-search-delegates", "judgment-search-delegates", "context-search-delegates"])
    for task in suite.tasks {
      XCTAssertNotNil(task.setup, "\(task.id) snapshots the runs.jsonl line count in setup")
      XCTAssertTrue(task.check.contains(".runs-before"), "\(task.id) compares against the snapshot")
    }
    XCTAssertTrue(suite.tasks[0].check.contains(#""agent":"explore""#))
    XCTAssertTrue(suite.tasks[1].check.contains("! {"), "asserts that no nested record landed")
  }

  // MARK: EvalRunner(subagents:)

  private func evalStores() -> (EvalStore, RunRecordStore) {
    let base = FileManager.default.temporaryDirectory
    return (
      EvalStore(url: base.appendingPathComponent("arnes-delegation-evals-\(UUID().uuidString).jsonl")),
      RunRecordStore(url: base.appendingPathComponent("arnes-delegation-eval-runs-\(UUID().uuidString).jsonl")))
  }

  func testEvalTrialWithSubagentsCarriesTheTaskToolAndTagsTheNestedRun() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // Lead step 1 delegates; the nested turn answers; lead step 2 writes the answer.
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(
          id: "c1", name: "task", arguments: #"{"agent":"helper","task":"find the name"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("it is TAMARIND"), Fixtures.usageChunk(cost: 0.02)],
      [
        Fixtures.toolCallChunk(
          id: "c2", name: "write_file", arguments: #"{"path": "answer.txt", "content": "TAMARIND"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = evalStores()
    let helper = AgentDefinition(name: "helper", description: "finds things", body: "Find it.")
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, subagents: [helper])
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "wide", prompt: "find the name", check: "test \"$(cat answer.txt)\" = TAMARIND"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertEqual(outcomes.count, 1)
    XCTAssertTrue(outcomes[0].checkPassed)
    XCTAssertNil(outcomes[0].error)
    // The lead's request offered the task tool and carried the delegation section.
    let lead = try XCTUnwrap(mock.requests.first)
    XCTAssertTrue(lead.tools?.contains { $0.function.name == "task" } == true)
    XCTAssertTrue(try systemPrompt(of: lead).contains("# Delegation"))
    // The nested session ran the same mock (its request is the second one) without the task
    // tool — one level of nesting — and its record is tagged with the agent's name.
    let nested = mock.requests[1]
    XCTAssertFalse(nested.tools?.contains { $0.function.name == "task" } == true)
    XCTAssertTrue(nested.tools?.contains { $0.function.name == "write_file" } == true, "the trial's own tools")
    let records = try recordStore.all()
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records.filter { $0.agent == "helper" }.count, 1)
    XCTAssertEqual(records.filter { $0.agent == nil }.count, 1)
    // The subagent's spend drains into the trial's outcome.
    XCTAssertEqual(outcomes[0].costUSD, 0.05, accuracy: 0.0001)
  }

  func testEvalTrialRunsTheUsersDelegationHooksAtTheDelegationBoundaryOnly() async throws {
    // A trial that delegates is the lead of its own delegations, so the user's SubagentStart
    // guardrail vetoes a spawn exactly as it does under `arnes do` — while Stop stays with the
    // command (a trial's end is not the user's turn end) and the nested session never sees
    // the delegation pair (a SubagentStop hook fires once, at the boundary).
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      // Lead step 1: delegate to the vetoed agent → blocked, nothing nested runs.
      [
        Fixtures.toolCallChunk(
          id: "c1", name: "task", arguments: #"{"agent":"scribe","task":"write it"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      // Lead step 2: delegate to the allowed agent → the nested turn answers.
      [
        Fixtures.toolCallChunk(
          id: "c2", name: "task", arguments: #"{"agent":"helper","task":"find it"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("found it"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let stopMarker = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-delegation-eval-stop-\(UUID().uuidString).marker")
    let stopCount = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-delegation-eval-substop-\(UUID().uuidString).log")
    defer {
      try? FileManager.default.removeItem(at: stopMarker)
      try? FileManager.default.removeItem(at: stopCount)
    }
    let hooks = [
      HookDefinition(
        event: .subagentStart, matcher: "scribe", command: "printf 'no writers in evals'; exit 2"),
      HookDefinition(event: .subagentStop, command: "echo once >> '\(stopCount.path)'; echo REVIEWED"),
      HookDefinition(event: .stop, command: "touch '\(stopMarker.path)'"),
    ]
    let (evalStore, recordStore) = evalStores()
    let agents = [
      AgentDefinition(name: "scribe", description: "writes", body: "Write."),
      AgentDefinition(name: "helper", description: "finds things", body: "Find it."),
    ]
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, hooks: hooks, subagents: agents)
    let suite = EvalSuite(name: "unit", tasks: [EvalTask(id: "hooked", prompt: "p", check: "true")])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertNil(outcomes[0].error)
    XCTAssertTrue(outcomes[0].agentFinished)
    // Lead 1 → lead 2 → nested → lead 3: the vetoed delegation cost no nested request.
    XCTAssertEqual(mock.requests.count, 4)
    let blocked = try XCTUnwrap(mock.requests[1].messages.first { $0.role == .tool && $0.toolCallId == "c1" })
    XCTAssertEqual(blocked.content?.plainText, "subagent blocked by hook: no writers in evals")
    let report = try XCTUnwrap(mock.requests[3].messages.first { $0.role == .tool && $0.toolCallId == "c2" })
    XCTAssertEqual(report.content?.plainText, "found it\n\n[hook]\nREVIEWED", "SubagentStop post-processed the report")
    let records = try recordStore.all()
    XCTAssertEqual(records.count, 2, "the lead and the one delegation that ran")
    XCTAssertEqual(records.filter { $0.agent == "helper" }.count, 1)
    XCTAssertEqual(records.filter { $0.agent == "scribe" }.count, 0, "a blocked spawn records nothing")
    XCTAssertEqual(
      try String(contentsOf: stopCount, encoding: .utf8).split(separator: "\n").count, 1,
      "SubagentStop fired once, at the boundary — not again inside the nested session")
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopMarker.path), "Stop stays with the command")
  }

  func testEvalTrialWithoutSubagentsIsUnchanged() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("nothing to do"), Fixtures.usageChunk(cost: 0.01)]]
    let (evalStore, recordStore) = evalStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [EvalTask(id: "t", prompt: "p", check: "true")])

    _ = await runner.run(suite: suite, models: ["test/model"])

    let request = try XCTUnwrap(mock.requests.first)
    XCTAssertFalse(request.tools?.contains { $0.function.name == "task" } == true)
    let system = try systemPrompt(of: request)
    XCTAssertFalse(system.contains("# Delegation"))
    XCTAssertFalse(system.contains("# Subagents"))
  }
}
