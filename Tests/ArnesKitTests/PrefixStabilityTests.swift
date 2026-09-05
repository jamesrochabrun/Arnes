import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// C7 — the prefix a prompt cache keys on (system text + tool definitions + the oldest kept
/// history) must be byte-stable across the requests of a turn, and across turns until a
/// compaction rebuilds it at a turn boundary. This audits every contributor: the pack, the
/// project instructions, the `# Environment` and `# Memory` sections, a tool's prompt section,
/// the `# Subagents` listing and the `# Delegation` text, the suffix — and the things that must
/// ride a **user** message instead (notices, the loop guard's nudge, a plan update).
final class PrefixStabilityTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-prefix-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-prefix-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  private struct ListingTool: AgentTool, PromptContributing {
    let name = "listing_probe"
    let description = "A tool that also lists things in the prompt."
    let parameters: JSONValue = ["type": "object", "properties": ["q": ["type": "string"]], "required": ["q"]]
    var permission: ToolPermission { .readOnly }
    var promptSection: String { "# Probe listing\n- one\n- two" }
    func execute(arguments: [String: JSONValue]) async throws -> String { "ok" }
  }

  /// The system message of a chat request, as sent.
  private func systemText(_ request: ChatCompletionRequest) -> String? {
    request.messages.first { $0.role == .system }?.content?.plainText
  }

  /// The tool definitions of a chat request, encoded with sorted keys — the pin is *structural*:
  /// every request offers the same set of tools with the same schemas. A plain `JSONEncoder` is
  /// not byte-stable even for one value encoded twice in one process: the encoder's own object
  /// storage is a Swift `Dictionary`, seeded per instance by its storage address, so an object's
  /// key order in the output is decided per encode, not by the value (the Q1 diagnosis: 500
  /// encodes of one `[Tool]` gave 500 distinct byte strings in the runs where the allocator moved
  /// the storage, and one string in the rest — the ~1-in-6 flake). The values were always equal.
  /// OpenRouterSwift's transport encoder is the same unconfigured kind, so the *wire's* key order
  /// varies the same way; sorting there is an upstream fix, and no concern of this pin.
  private func toolBytes(_ request: ChatCompletionRequest) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(request.tools ?? [])
  }

  /// The one `# Environment` block every request in these tests carries — rendered the way the
  /// CLI renders it, from facts captured once.
  private static func environmentBlock() -> String {
    EnvironmentContext.render(
      cwd: URL(fileURLWithPath: "/work/project"),
      os: "TestOS 1.0 (Kernel 2.0, arm64)",
      date: "2026-01-02",
      git: GitSnapshot(branch: "main", status: [" M a.swift"], statusCount: 1, recentSubjects: ["Initial commit"]),
      model: "test/model",
      permissionMode: .default,
      sandbox: nil,
      effort: nil)
  }

  private func memoryStore() throws -> MemoryStore {
    let directory = try tempDirectory("memory")
    try "- Prefers tabs.\n- Runs tests with swift test.\n".write(
      to: directory.appendingPathComponent("MEMORY.md"), atomically: true, encoding: .utf8)
    return MemoryStore(directory: directory)
  }

  /// A fully dressed session: instructions, an environment block, a memory section, a
  /// prompt-contributing tool, the task tool (so the `# Subagents` and `# Delegation` sections
  /// render), a scripted tool the model calls, and a suffix.
  private func dressedSession(mock: MockOpenRouterService, scripted: ScriptedTool) throws -> Session {
    let task = TaskTool(agents: [.general], service: mock, tools: [], store: tempRecordStore())
    return Session(
      service: mock,
      tools: [ListingTool(), scripted, PlanTool(), task],
      store: tempRecordStore(),
      configuration: .init(
        model: "test/model",
        systemSuffix: "# Role\n\nYou review pull requests.",
        projectInstructions: "# Project rules\nAlways do X.",
        extraSystemSections: [Self.environmentBlock(), try memoryStore().promptSection()]))
  }

  // MARK: (a) system text + tool definitions are byte-identical across requests

  func testConsecutiveRequestsShareByteIdenticalSystemTextAndToolDefinitions() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // Turn 1: two tool steps then a finish; turn 2: one finish.
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: #"{"text":"1"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: #"{"text":"2"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("again"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let scripted = ScriptedTool(name: "spy", results: ["a", "b"])
    let session = try dressedSession(mock: mock, scripted: scripted)
    _ = try await Events.drain(await session.send("first"))
    _ = try await Events.drain(await session.send("second"))
    XCTAssertEqual(mock.requests.count, 4)

    let first = try XCTUnwrap(systemText(mock.requests[0]))
    for (index, request) in mock.requests.enumerated() {
      XCTAssertEqual(systemText(request), first, "request \(index): the system text moved")
      XCTAssertEqual(try toolBytes(request), try toolBytes(mock.requests[0]), "request \(index): the tool definitions moved")
    }
    // Every contributor is in the prefix, so the equalities above are not vacuous.
    for expected in ["# Project rules", "# Environment", "# Memory", "Prefers tabs", "# Probe listing", "# Subagents", "# Delegation", "# Role"] {
      XCTAssertTrue(first.contains(expected), "missing \(expected)")
    }
    // The prefix carries no clock: a date at most, never a time (the one thing that would
    // make an otherwise identical prompt miss the cache every minute).
    XCTAssertNil(first.range(of: #"\d{2}:\d{2}(:\d{2})?"#, options: .regularExpression), "a time in the system text: \(first)")
    XCTAssertTrue(first.contains("- Date: 2026-01-02"))
    // And the rendered prompt is the request's system message, so the audit reads the real thing.
    let rendered = try await session.renderedSystemPrompt()
    XCTAssertEqual(rendered, first)
  }

  // MARK: (b) what must never touch the prefix mid-turn rides a user message

  func testNoticesNudgesAndPlanUpdatesRideUserMessagesNeverTheSystemText() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let planArguments = #"{"plan":[{"step":"look","status":"in_progress"},{"step":"fix","status":"pending"}]}"#
    // Turn 1: a plan update, then the same call three times (the loop guard nudges at 3),
    // then a finish. Turn 2 (after a `notify`): a finish.
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "p1", name: "update_plan", arguments: planArguments), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: #"{"text":"same"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: #"{"text":"same"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c3", name: "spy", arguments: #"{"text":"same"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("again"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let scripted = ScriptedTool(name: "spy", results: ["ok", "ok", "ok"])
    let session = try dressedSession(mock: mock, scripted: scripted)
    let events = try await Events.drain(await session.send("first"))
    await session.notify("background job 1 exited 0")
    _ = try await Events.drain(await session.send("second"))
    XCTAssertEqual(mock.requests.count, 6)

    // The nudge fired and the plan landed, so the turn exercised both channels.
    XCTAssertTrue(events.contains { if case .nudged = $0 { return true } else { return false } })
    XCTAssertTrue(events.contains { if case .planUpdated = $0 { return true } else { return false } })
    let plan = await session.lastPlanSteps
    XCTAssertEqual(plan?.map(\.text), ["look", "fix"])

    // The system text never moved — across the nudge, the plan and the notice.
    let first = try XCTUnwrap(systemText(mock.requests[0]))
    for (index, request) in mock.requests.enumerated() {
      XCTAssertEqual(systemText(request), first, "request \(index): the system text moved")
      XCTAssertEqual(try toolBytes(request), try toolBytes(mock.requests[0]), "request \(index)")
      XCTAssertFalse(first.contains("[arnes]"), "no harness notice in the prefix")
    }
    // The nudge rode a user message before the fifth request; the notice rode one before the
    // sixth — appended history, the part of the request that is meant to grow.
    let nudge = mock.requests[4].messages.last
    XCTAssertEqual(nudge?.role, .user)
    XCTAssertTrue(nudge?.content?.plainText.hasPrefix("[arnes]") == true, nudge?.content?.plainText ?? "")
    let sixth = mock.requests[5].messages
    XCTAssertTrue(sixth.contains { $0.role == .user && ($0.content?.plainText.contains("background job 1 exited 0") ?? false) })
    // Every request's prefix (system + tools + the history it shares with the previous one) is
    // the previous request's prefix: history only grows within the turn.
    for index in 1..<5 {
      let previous = mock.requests[index - 1].messages.map(Fixtures.jsonValue)
      let current = mock.requests[index].messages.map(Fixtures.jsonValue)
      XCTAssertEqual(Array(current.prefix(previous.count)), previous, "request \(index): the shared history changed under the model")
    }
  }

  // MARK: (c) a compaction is the one prefix mutation, and it lands at a turn boundary

  func testCompactionIsTheOnlyPrefixMutationAndHappensAtATurnBoundary() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    mock.chunkScripts = [
      [Fixtures.textChunk("a1"), Fixtures.usageChunk(cost: 0.01, promptTokens: 20)],
      [Fixtures.textChunk("a2"), Fixtures.usageChunk(cost: 0.01, promptTokens: 90)], // 90% full
      // Turn 3: compaction first, then two steps that must share the rebuilt prefix.
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: #"{"text":"x"}"#), Fixtures.usageChunk(cost: 0.01, promptTokens: 30)],
      [Fixtures.textChunk("a3"), Fixtures.usageChunk(cost: 0.01, promptTokens: 35)],
    ]
    mock.chatResponses = [Fixtures.textResponse("AUTO SUMMARY", cost: 0.001)]
    let scripted = ScriptedTool(name: "spy", results: ["ok"])
    let session = Session(
      service: mock, tools: [scripted], store: tempRecordStore(),
      configuration: .init(model: "test/model", projectInstructions: "# Rules\nBe brief."))

    _ = try await Events.drain(await session.send("turn one"))
    _ = try await Events.drain(await session.send("turn two"))
    let events = try await Events.drain(await session.send("turn three"))
    XCTAssertTrue(events.contains { if case .compacted = $0 { return true } else { return false } })
    // The mock records the summarizer's own (non-streaming) request too — the one request that
    // carries no tool definitions; the loop's requests all carry `spy`.
    let loopRequests = mock.requests.filter { $0.tools != nil }
    XCTAssertEqual(mock.requests.count, 5)
    XCTAssertEqual(loopRequests.count, 4)

    let before = try XCTUnwrap(systemText(loopRequests[0]))
    XCTAssertEqual(systemText(loopRequests[1]), before, "turns one and two share one prefix")
    let after = try XCTUnwrap(systemText(loopRequests[2]))
    XCTAssertNotEqual(after, before, "the compaction rebuilt the prefix")
    XCTAssertTrue(after.contains("AUTO SUMMARY"))
    XCTAssertTrue(after.hasPrefix(before), "the summary is appended; everything before it is the old prefix, byte for byte")
    // Both steps of turn three — either side of a tool call — share the rebuilt prefix.
    XCTAssertEqual(systemText(loopRequests[3]), after, "the prefix moved mid-turn")
    XCTAssertEqual(try toolBytes(loopRequests[3]), try toolBytes(loopRequests[2]))
    // The compaction happened before turn three's first request, never between its steps.
    let compactedAt = events.firstIndex { if case .compacted = $0 { return true } else { return false } }
    let firstToolCall = events.firstIndex { if case .toolCall = $0 { return true } else { return false } }
    XCTAssertLessThan(try XCTUnwrap(compactedAt), try XCTUnwrap(firstToolCall))
  }

  // MARK: The section renderers themselves are pure

  func testEnvironmentAndMemorySectionsRenderByteIdenticallyTwice() throws {
    XCTAssertEqual(Self.environmentBlock(), Self.environmentBlock())
    let store = try memoryStore()
    XCTAssertEqual(store.promptSection(), store.promptSection())
    XCTAssertEqual(store.indexSection(), store.indexSection())
    // An empty store renders the fixed header too — stable, and never a clock.
    let empty = MemoryStore(directory: try tempDirectory("empty-memory"))
    XCTAssertEqual(empty.promptSection(), empty.promptSection())
    XCTAssertNil(empty.promptSection().range(of: #"\d{2}:\d{2}"#, options: .regularExpression))
    XCTAssertNil(store.promptSection().range(of: #"\d{2}:\d{2}"#, options: .regularExpression))
  }
}
