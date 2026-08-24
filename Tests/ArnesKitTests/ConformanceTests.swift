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

  private func drain(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  // MARK: Store

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

    let events = try await drain(await session.send("say hi"))

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

    _ = try await drain(await session.send("say hi"))

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
      _ = try await drain(await session.send("say hi"))
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

    _ = try await drain(await session.send("say hi"))

    XCTAssertEqual(store.latest(model: "anthropic/claude-test", dialect: .messages)?.ok, true)
  }
}
