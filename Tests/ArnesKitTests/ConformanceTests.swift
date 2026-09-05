import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class ConformanceTests: XCTestCase {
  private func tempStoreURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-dialects-\(UUID().uuidString).jsonl")
  }

  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-conformance-runs-\(UUID().uuidString).jsonl"))
  }
  // MARK: Store

  func testCacheControlAndTransportCategoriesNeverPinForTheFailureTTL() throws {
    // The classifier names a refused cache_control field first (the block it sat on may be a
    // thinking block); a transport failure is never read from text — the callers know its type.
    XCTAssertEqual(
      DialectVerdict.category(forFailure: "messages.0.content.0.cache_control: Extra inputs are not permitted"),
      DialectVerdict.cacheControlCategory)
    XCTAssertEqual(DialectVerdict.category(forFailure: "Unsupported parameter: cacheControl"), DialectVerdict.cacheControlCategory)
    XCTAssertEqual(
      DialectVerdict.category(forFailure: "cache_control is not allowed on a thinking block"),
      DialectVerdict.cacheControlCategory)
    XCTAssertEqual(DialectVerdict.category(forFailure: "Invalid signature in thinking block"), DialectVerdict.thinkingCategory)
    XCTAssertNil(DialectVerdict.category(forFailure: "rate limited (429) after 4 retries: Rate limited: slow"))
    XCTAssertNil(DialectVerdict.category(forFailure: "404 model not found"))

    let store = DialectVerdictStore(url: tempStoreURL())
    store.record(model: "anthropic/x", dialect: .messages, ok: false, reason: "cache_control refused", category: DialectVerdict.cacheControlCategory)
    XCTAssertFalse(store.isKnownBad(model: "anthropic/x", dialect: .messages), "the request's fault, never pinned")
    XCTAssertNotNil(store.latest(model: "anthropic/x", dialect: .messages), "recorded for arnes probe to show")

    store.record(model: "anthropic/y", dialect: .messages, ok: false, reason: "rate limited (429) after 4 retries", category: DialectVerdict.transportCategory)
    XCTAssertTrue(store.isKnownBad(model: "anthropic/y", dialect: .messages), "a transport failure cools the route …")
    let cooled = DialectVerdictStore(url: store.url, transportCooldown: 0)
    XCTAssertFalse(cooled.isKnownBad(model: "anthropic/y", dialect: .messages), "… for minutes, not the failure TTL")
    XCTAssertNotNil(cooled.latest(model: "anthropic/y", dialect: .messages), "and still stands as a verdict")

    // An endpoint failure (no category) pins for the failure TTL exactly as before.
    store.record(model: "anthropic/z", dialect: .messages, ok: false, reason: "404 model not found")
    XCTAssertTrue(store.isKnownBad(model: "anthropic/z", dialect: .messages))
    XCTAssertTrue(DialectVerdictStore(url: store.url).isKnownBad(model: "anthropic/z", dialect: .messages), "a fresh reader agrees")
  }

  func testLatestVerdictWinsAndOkRunsAreDeduplicated() {
    let url = tempStoreURL()
    let store = DialectVerdictStore(url: url)
    store.record(model: "anthropic/x", dialect: .messages, ok: false, reason: "boom")
    XCTAssertTrue(store.isKnownBad(model: "anthropic/x", dialect: .messages))

    store.record(model: "anthropic/x", dialect: .messages, ok: true)
    XCTAssertFalse(store.isKnownBad(model: "anthropic/x", dialect: .messages))
    store.record(model: "anthropic/x", dialect: .messages, ok: true)
    store.record(model: "anthropic/x", dialect: .messages, ok: true)

    // Two verdict changes + no lines for the repeat oks; a fresh reader agrees.
    let lines = (try? String(contentsOf: url, encoding: .utf8))?
      .split(separator: "\n").count ?? 0
    XCTAssertEqual(lines, 2)
    let reread = DialectVerdictStore(url: url)
    XCTAssertEqual(reread.latest(model: "anthropic/x", dialect: .messages)?.ok, true)
    XCTAssertNil(reread.latest(model: "anthropic/x", dialect: .responses))
  }

  func testFailedVerdictsExpire() throws {
    let url = tempStoreURL()
    // A failure recorded far beyond the TTL, written in the store's own format.
    let stale = #"{"model":"openai/x","dialect":"responses","ok":false,"reason":"500","at":"2020-01-01T00:00:00Z"}"#
    try (stale + "\n").write(to: url, atomically: true, encoding: .utf8)
    let store = DialectVerdictStore(url: url)
    // Stale failure — worth trying natively again.
    XCTAssertFalse(store.isKnownBad(model: "openai/x", dialect: .responses))
    XCTAssertNil(store.latest(model: "openai/x", dialect: .responses))
    // A fresh failure is honored.
    store.record(model: "openai/x", dialect: .responses, ok: false, reason: "500")
    XCTAssertTrue(store.isKnownBad(model: "openai/x", dialect: .responses))
  }

  // MARK: Session fallback

  func testNativeFailureFallsBackToChatAndRecordsVerdict() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    // No messages script → the native stream throws before emitting anything;
    // the chat script then serves the fallback step.
    mock.chunkScripts = [
      [Fixtures.textChunk("recovered"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let store = DialectVerdictStore(url: tempStoreURL())
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test"))

    let events = try await Events.drain(await session.send("say hi"))

    let fellBack = events.contains {
      if case .dialectFellBack(let dialect, _) = $0 { return dialect == "messages" }
      return false
    }
    XCTAssertTrue(fellBack)
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "chat")
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.summary, "recovered")
    XCTAssertEqual(mock.messagesRequests.count, 1)
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertTrue(store.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
  }

  /// R1: a refusal about the *thinking shape* of the request is not the endpoint's fault. The
  /// turn still falls back to chat for this step, but the verdict is categorized and never
  /// pins the model — the next turn tries `/messages` again.
  func testThinkingFailureFallsBackForTheTurnButNeverPins() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesStreamErrors = [MockError.nativeRefusal(
      "400: messages.1.content.0: Expected `thinking` or `redacted_thinking`, but found `tool_use`. "
        + "When `thinking` is enabled, a final `assistant` message must start with a thinking block")]
    mock.chunkScripts = [
      [Fixtures.textChunk("recovered"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let store = DialectVerdictStore(url: tempStoreURL())
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test"))

    let events = try await Events.drain(await session.send("say hi"))

    XCTAssertTrue(events.contains {
      if case .dialectFellBack(let dialect, _) = $0 { return dialect == "messages" }
      return false
    }, "the step still fell back")
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "chat")
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.summary, "recovered")
    let verdict = store.latest(model: "anthropic/claude-test", dialect: .messages)
    XCTAssertEqual(verdict?.ok, false)
    XCTAssertEqual(verdict?.category, DialectVerdict.thinkingCategory)
    XCTAssertFalse(store.isKnownBad(model: "anthropic/claude-test", dialect: .messages),
                   "a thinking failure is recorded but never pins the model to chat")
  }

  func testForcedNativeThinkingFailureIsCategorizedToo() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesStreamErrors = [MockError.nativeRefusal("400: `max_tokens` must be greater than `thinking.budget_tokens`")]
    let store = DialectVerdictStore(url: tempStoreURL())
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test", dialect: .messages))

    do {
      _ = try await Events.drain(await session.send("say hi"))
      XCTFail("expected the forced native failure to surface")
    } catch DialectError.nativeDialectFailed {
      // expected — the forced flow is unchanged
    }
    XCTAssertEqual(store.latest(model: "anthropic/claude-test", dialect: .messages)?.category, "thinking")
    XCTAssertFalse(store.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
  }

  func testKnownBadVerdictPinsAutoToChatWithoutTouchingNativeEndpoint() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.chunkScripts = [
      [Fixtures.textChunk("hi"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let store = DialectVerdictStore(url: tempStoreURL())
    store.record(model: "anthropic/claude-test", dialect: .messages, ok: false, reason: "prior failure")
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test"))

    _ = try await Events.drain(await session.send("say hi"))

    XCTAssertTrue(mock.messagesRequests.isEmpty)
    XCTAssertEqual(mock.requests.count, 1)
    let maybeRecord = await session.lastRecord
    XCTAssertEqual(maybeRecord?.dialect, "chat")
  }

  func testForcedNativeDialectFailsLoudlyInsteadOfFallingBack() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    let store = DialectVerdictStore(url: tempStoreURL())
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test", dialect: .messages))

    do {
      _ = try await Events.drain(await session.send("say hi"))
      XCTFail("expected the forced native failure to surface")
    } catch let DialectError.nativeDialectFailed(dialect, _) {
      XCTAssertEqual(dialect, "messages")
    }
    // No silent chat rerun, but the failure is still recorded for auto callers.
    XCTAssertTrue(mock.requests.isEmpty)
    XCTAssertTrue(store.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
  }

  func testCleanNativeStepRecordsOkVerdict() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let store = DialectVerdictStore(url: tempStoreURL())
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test"))

    _ = try await Events.drain(await session.send("say hi"))

    XCTAssertEqual(store.latest(model: "anthropic/claude-test", dialect: .messages)?.ok, true)
  }
}

final class ConformanceAmbiguityTests: XCTestCase {
  /// A model the gateway doesn't know fails on every dialect. That must not be
  /// remembered as "messages is broken for this model" — the next turn (with the right
  /// name) should try the native endpoint again.
  func testFailureOnBothDialectsRecordsNoVerdict() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    // No messages script and no chat script: both paths throw before any output.
    let storeURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-verdicts-\(UUID().uuidString).jsonl")
    let store = DialectVerdictStore(url: storeURL)
    let session = Session(
      service: mock, tools: [],
      store: RunRecordStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("arnes-runs-\(UUID().uuidString).jsonl")),
      dialectStore: store,
      configuration: .init(model: "anthropic/claude-test"))
    var fellBack = false
    do {
      for try await event in await session.send("hi") {
        if case .dialectFellBack = event { fellBack = true }
      }
      XCTFail("expected the chat retry to fail too")
    } catch {
      // expected: the chat script is exhausted as well
    }
    XCTAssertTrue(fellBack, "the loop did try chat")
    XCTAssertFalse(store.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
    XCTAssertNil(store.latest(model: "anthropic/claude-test", dialect: .messages))
  }
}
