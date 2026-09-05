import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class ReasoningEffortTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-effort-runs-\(UUID().uuidString).jsonl"))
  }

  private func reasoningManifest(supportsReasoning: Bool) -> String {
    let params = supportsReasoning ? "\"tools\",\"reasoning\"" : "\"tools\""
    return #"[{"id":"test/model","context_length":8000,"supported_parameters":[\#(params)],"pricing":{"prompt":"0","completion":"0"}}]"#
  }

  private func run(effort: Reasoning.Effort?, supportsReasoning: Bool) async throws -> ChatCompletionRequest? {
    let mock = MockOpenRouterService()
    mock.manifestJSON = reasoningManifest(supportsReasoning: supportsReasoning)
    mock.chunkScripts = [[Fixtures.textChunk("hi"), Fixtures.usageChunk(cost: 0)]]
    let session = Session(
      service: mock, tools: [], store: tempStore(),
      configuration: .init(model: "test/model", reasoningEffort: effort))
    for try await _ in await session.send("go") { }
    return mock.requests.first
  }

  func testEffortSetsReasoningWhenModelSupportsIt() async throws {
    let request = try await run(effort: .high, supportsReasoning: true)
    XCTAssertEqual(request?.reasoning?.effort, .high)
  }

  func testNoEffortLeavesReasoningUnset() async throws {
    let request = try await run(effort: nil, supportsReasoning: true)
    XCTAssertNil(request?.reasoning, "default path must be byte-for-byte unchanged")
  }

  func testEffortGatedOffWhenModelLacksReasoning() async throws {
    // The dial is set, but the manifest says the model doesn't support reasoning → never sent.
    let request = try await run(effort: .high, supportsReasoning: false)
    XCTAssertNil(request?.reasoning)
  }

  // MARK: C6 — the live dial (`/effort`)

  private func reasoningMock(steps: Int) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = reasoningManifest(supportsReasoning: true)
    mock.chunkScripts = (0..<steps).map { _ in [Fixtures.textChunk("hi"), Fixtures.usageChunk(cost: 0)] }
    return mock
  }

  func testSetReasoningEffortMidSessionChangesNextRequestOnly() async throws {
    let mock = reasoningMock(steps: 3)
    let session = Session(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    let initial = await session.currentReasoningEffort
    XCTAssertNil(initial)
    for try await _ in await session.send("one") { }
    await session.setReasoningEffort(.high)
    let moved = await session.currentReasoningEffort
    XCTAssertEqual(moved, .high)
    for try await _ in await session.send("two") { }
    await session.setReasoningEffort(.low)
    for try await _ in await session.send("three") { }

    XCTAssertNil(mock.requests[0].reasoning, "the turn before the dial moved is untouched")
    XCTAssertEqual(mock.requests[1].reasoning?.effort, .high)
    XCTAssertEqual(mock.requests[2].reasoning?.effort, .low)
    XCTAssertNil(session.configuration.reasoningEffort, "the configuration stays the seed")
  }

  func testOffRestoresByteIdenticalRequest() async throws {
    let mock = reasoningMock(steps: 2)
    let session = Session(
      service: mock, tools: [], store: tempStore(),
      configuration: .init(model: "test/model", reasoningEffort: .high))
    for try await _ in await session.send("one") { }
    await session.setReasoningEffort(nil)
    for try await _ in await session.send("two") { }

    XCTAssertEqual(mock.requests[0].reasoning?.effort, .high)
    XCTAssertNil(mock.requests[1].reasoning, "off = no reasoning field at all")
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    // Exactly the request a session with no dial sends for the same history.
    let control = reasoningMock(steps: 2)
    let plain = Session(service: control, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    for try await _ in await plain.send("one") { }
    for try await _ in await plain.send("two") { }
    XCTAssertEqual(try encoder.encode(mock.requests[1]), try encoder.encode(control.requests[1]))
  }

  func testEffortPersistedAndRestoredOnResume() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-effort-sessions-\(UUID().uuidString)")
    let store = SessionStore(directory: directory)
    let mock = reasoningMock(steps: 2)
    let session = Session(
      service: mock, tools: [], store: tempStore(), sessionStore: store,
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("one") { }
    await session.setReasoningEffort(.xhigh)
    XCTAssertEqual(try store.load(id: session.id).reasoningEffort, .xhigh, "the writer half of C5's effort_change")

    // `off` is a change too: a resume must not fall back to a level set earlier.
    await session.setReasoningEffort(nil)
    XCTAssertNil(try store.load(id: session.id).reasoningEffort)
    await session.setReasoningEffort(.medium)
    let loaded = try store.load(id: session.id)
    XCTAssertEqual(loaded.reasoningEffort, .medium)

    // The resumed session seeds its dial from the configuration the CLI folds the replay into.
    let resumed = Session(
      resuming: loaded, service: mock, tools: [], store: tempStore(), sessionStore: store,
      configuration: .init(model: "test/model", reasoningEffort: loaded.reasoningEffort))
    let restored = await resumed.currentReasoningEffort
    XCTAssertEqual(restored, .medium)
    for try await _ in await resumed.send("two") { }
    XCTAssertEqual(mock.requests.last?.reasoning?.effort, .medium)
    // The transcript reads the dial history back for humans too.
    XCTAssertTrue(try store.exportMarkdown(id: session.id).contains("> effort → off"))
  }

  func testThinkingBudgetMapping() {
    // Monotonic non-decreasing with effort; every budget is a positive token count.
    XCTAssertEqual(Session.thinkingBudget(for: .low), 4096)
    XCTAssertEqual(Session.thinkingBudget(for: .medium), 8192)
    XCTAssertEqual(Session.thinkingBudget(for: .high), 16384)
    XCTAssertGreaterThan(Session.thinkingBudget(for: .max), Session.thinkingBudget(for: .high))
    XCTAssertGreaterThan(Session.thinkingBudget(for: .minimal), 0)
  }

  /// R1: the `/messages` `max_tokens` follows the dial exactly as before when the manifest
  /// states no output ceiling, and every budget fits under a stated one.
  func testMessagesOutputPlanKeepsEveryBudgetUnderTheCeiling() {
    for effort in [Reasoning.Effort.minimal, .low, .medium, .high, .xhigh, .max] {
      let budget = Session.thinkingBudget(for: effort)
      let uncapped = MessagesTranslator.outputPlan(maxCompletionTokens: nil, thinkingBudget: budget)
      XCTAssertEqual(uncapped.maxTokens, budget + MessagesTranslator.maxOutputTokens, "\(effort): today's number")
      XCTAssertEqual(uncapped.budget, budget)
      let capped = MessagesTranslator.outputPlan(maxCompletionTokens: 8192, thinkingBudget: budget)
      XCTAssertEqual(capped.maxTokens, 8192, "\(effort): the ceiling holds")
      XCTAssertLessThan(capped.budget ?? .max, capped.maxTokens, "\(effort): max_tokens > budget_tokens")
      XCTAssertGreaterThanOrEqual(capped.budget ?? 0, MessagesTranslator.minimumThinkingBudget)
    }
  }
}
