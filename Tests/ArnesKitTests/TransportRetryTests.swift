import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Helpers

/// Records every wait the retry loop asked for instead of sleeping — the seam that lets a test
/// prove a retry *happened* (and how long it would have waited) without waiting.
private final class SleepRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [Double] = []

  var waits: [Double] {
    lock.withLock { recorded }
  }

  /// A policy over this recorder: instant sleeps, a fixed jitter (`random` = 0.5 → ×1.0), the
  /// given budgets.
  func policy(
    maxRequestRetries: Int = TransportPolicy.defaultMaxRequestRetries,
    maxStreamRetries: Int = TransportPolicy.defaultMaxStreamRetries,
    streamIdleTimeoutMs: Int = TransportPolicy.defaultStreamIdleTimeoutMs,
    maxRetryWaitSeconds: Double = TransportPolicy.defaultMaxRetryWaitSeconds)
    -> TransportPolicy
  {
    TransportPolicy(
      maxRequestRetries: maxRequestRetries,
      maxStreamRetries: maxStreamRetries,
      streamIdleTimeoutMs: streamIdleTimeoutMs,
      maxRetryWaitSeconds: maxRetryWaitSeconds,
      sleep: { [self] nanoseconds in
        lock.withLock { recorded.append(Double(nanoseconds) / 1_000_000_000) }
      },
      random: { 0.5 })
  }
}

private func tempRecordStore() -> RunRecordStore {
  RunRecordStore(url: FileManager.default.temporaryDirectory
    .appendingPathComponent("arnes-transport-runs-\(UUID().uuidString).jsonl"))
}

private func tempDialectStore() -> DialectVerdictStore {
  DialectVerdictStore(url: FileManager.default.temporaryDirectory
    .appendingPathComponent("arnes-transport-verdicts-\(UUID().uuidString).jsonl"))
}
/// Drains the stream and hands back the error it ended with (nil when it finished cleanly).
private func drainCatching(_ stream: AsyncThrowingStream<AgentEvent, Error>) async -> (events: [AgentEvent], error: Error?) {
  var events: [AgentEvent] = []
  do {
    for try await event in stream {
      events.append(event)
    }
    return (events, nil)
  } catch {
    return (events, error)
  }
}

/// The record the most recent turn appended (an `await` cannot sit inside `XCTUnwrap`).
private func lastRecord(of session: Session, file: StaticString = #filePath, line: UInt = #line) async throws -> RunRecord {
  let record = await session.lastRecord
  return try XCTUnwrap(record, "no record was appended", file: file, line: line)
}

private extension Array where Element == AgentEvent {
  var retries: [(attempt: Int, reason: String)] {
    compactMap { if case .retrying(let attempt, let reason) = $0 { return (attempt, reason) } else { return nil } }
  }

  var truncations: Int {
    filter { if case .truncated = $0 { return true } else { return false } }.count
  }

  var fellBack: Bool {
    contains { if case .dialectFellBack = $0 { return true } else { return false } }
  }

  var interrupted: Bool {
    contains { if case .interrupted = $0 { return true } else { return false } }
  }
}

/// A tool that records its executions.
private final class CountingTool: AgentTool, @unchecked Sendable {
  let name = "spy"
  let description = "test tool"
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  let permission: ToolPermission = .readOnly
  private let lock = NSLock()
  private var count = 0

  var executions: Int { lock.withLock { count } }

  func execute(arguments: [String: JSONValue]) async throws -> String {
    lock.withLock { count += 1 }
    return "ok"
  }
}

// MARK: - TransportRetryTests

final class TransportRetryTests: XCTestCase {
  private func session(
    _ mock: MockOpenRouterService,
    tools: [any AgentTool] = [],
    model: String = "test/model",
    dialect: DialectOverride = .auto,
    transport: TransportPolicy,
    dialectStore: DialectVerdictStore? = nil)
    -> Session
  {
    Session(
      service: mock,
      tools: tools,
      store: tempRecordStore(),
      dialectStore: dialectStore ?? tempDialectStore(),
      configuration: .init(model: model, dialect: dialect, transport: transport))
  }

  private func chatMock() -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    return mock
  }

  // MARK: Classification (pure)

  func testRetryReasonIsNarrow() {
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.rateLimited(message: "slow", retryAfter: 3)),
      TransportPolicy.RetryReason(text: "rate limited (429)", retryAfter: 3))
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.serviceOverloaded(message: "x"))?.text,
      "provider overloaded (529)")
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.providerTimeout(message: "x"))?.text,
      "provider timeout (524)")
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.api(statusCode: 503, message: "x", metadata: nil))?.text,
      "HTTP 503")
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.transport(URLError(.networkConnectionLost)))?.text,
      "connection lost")
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.transport(URLError(.timedOut)))?.text,
      "connection timed out")
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 502, message: "upstream\nreset", metadata: nil))?.text,
      "stream error (502): upstream reset")
    XCTAssertEqual(
      TransportPolicy.retryReason(for: TransportError.streamIdle(seconds: 300))?.text,
      "stream idle for 300s")
    // A connection lost inside the stream arrives as a bare URLError (OpenRouterSwift wraps only
    // the request phase's), classified like the wrapped one.
    XCTAssertEqual(TransportPolicy.retryReason(for: URLError(.networkConnectionLost))?.text, "connection lost")
    XCTAssertEqual(TransportPolicy.retryReason(for: URLError(.timedOut))?.text, "connection timed out")
    // A mid-stream error event is gated on its upstream code like an HTTP status: none, 408,
    // 429 and 5xx are transient …
    XCTAssertEqual(
      TransportPolicy.retryReason(for: OpenRouterError.streamError(code: nil, message: "overloaded_error", metadata: nil))?.text,
      "stream error: overloaded_error")
    XCTAssertNotNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 529, message: "x", metadata: nil)))
    XCTAssertNotNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 429, message: "x", metadata: nil)))
    XCTAssertNotNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 408, message: "x", metadata: nil)))
    XCTAssertNotNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 503, message: "x", metadata: nil)))
    XCTAssertTrue(TransportPolicy.isTransientStreamErrorCode(nil))
    XCTAssertTrue(TransportPolicy.isTransientStreamErrorCode(599))
    XCTAssertFalse(TransportPolicy.isTransientStreamErrorCode(400))
    XCTAssertFalse(TransportPolicy.isTransientStreamErrorCode(200))

    // Never a retry: a 4xx — on the HTTP layer or relayed one line later as a 4xx-coded stream
    // error (a request-shape 400, 402 credits, 403 moderation, 404 no endpoints) —, credits, a
    // guardrail, a decoding failure, a cancelled or unknown transport error (wrapped or bare),
    // the mock's exhausted script, a native refusal, a cancellation.
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.api(statusCode: 400, message: "bad", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.api(statusCode: 404, message: "no", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 400, message: "Expected `thinking`", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 402, message: "credits", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 403, message: "moderation", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.streamError(code: 404, message: "no endpoints", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.insufficientCredits(message: "x")))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.guardrailViolation(message: "x", metadata: nil)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.decodingFailure(description: "x", raw: Data())))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.invalidResponse(description: "x")))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.transport(URLError(.cancelled))))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.transport(URLError(.cannotFindHost))))
    XCTAssertNil(TransportPolicy.retryReason(for: URLError(.cancelled)))
    XCTAssertNil(TransportPolicy.retryReason(for: URLError(.cannotFindHost)))
    XCTAssertNil(TransportPolicy.retryReason(for: OpenRouterError.transport(CancellationError())))
    XCTAssertNil(TransportPolicy.retryReason(for: MockError.scriptExhausted))
    XCTAssertNil(TransportPolicy.retryReason(for: MockError.nativeRefusal("no")))
    XCTAssertNil(TransportPolicy.retryReason(for: CancellationError()))
    XCTAssertNil(TransportPolicy.retryReason(for: TransportError.retriesExhausted(reason: "r", retries: 1, underlying: MockError.scriptExhausted)))
  }

  func testTheExhaustedErrorDescribesTheCauseAsASentenceNotAnEnumDump() {
    let exhausted = TransportError.retriesExhausted(
      reason: "rate limited (429)", retries: 2,
      underlying: OpenRouterError.rateLimited(message: "slow down", retryAfter: nil))
    XCTAssertEqual("\(exhausted)", "rate limited (429) after 2 retries: Rate limited: slow down")
    XCTAssertFalse("\(exhausted)".contains("rateLimited(message:"))
    // An error without a localized text falls back to its plain description.
    let plain = TransportError.retriesExhausted(reason: "r", retries: 0, underlying: MockError.scriptExhausted)
    XCTAssertEqual("\(plain)", "r: scriptExhausted")
    // The wait-cap note names the wait and the cap.
    XCTAssertEqual(
      TransportPolicy.waitCapNote(delay: 120, retryAfter: 120, cap: 60),
      " (Retry-After 120s would take the wait past the 60s cap)")
    XCTAssertEqual(
      TransportPolicy.waitCapNote(delay: 2.5, retryAfter: nil, cap: 3),
      " (a 2.5s backoff would take the wait past the 3s cap)")
  }

  func testBackoffDoublesFromHalfASecondUnderTheCapWithJitterAndHonorsRetryAfter() {
    // ×1.0 at random 0.5: 0.5, 1, 2, 4, 8, 8 (the per-attempt cap).
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 1, retryAfter: nil, random: 0.5), 0.5, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 2, retryAfter: nil, random: 0.5), 1, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 3, retryAfter: nil, random: 0.5), 2, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 4, retryAfter: nil, random: 0.5), 4, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 5, retryAfter: nil, random: 0.5), 8, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 9, retryAfter: nil, random: 0.5), 8, accuracy: 1e-9)
    // Jitter spans [0.5, 1.5) of the exponential.
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 2, retryAfter: nil, random: 0), 0.5, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 2, retryAfter: nil, random: 0.999_999), 1.5, accuracy: 1e-3)
    // A server-stated wait wins over the schedule, verbatim.
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 1, retryAfter: 2.5, random: 0.5), 2.5, accuracy: 1e-9)
    XCTAssertEqual(TransportPolicy.delay(forAttempt: 4, retryAfter: 0, random: 0.5), 4, accuracy: 1e-9, "a zero Retry-After is no Retry-After")
    // The defaults' worst-case waits stay well under the cap.
    let worstRequest = (1...4).reduce(0.0) { $0 + TransportPolicy.delay(forAttempt: $1, retryAfter: nil, random: 0.999_999) }
    XCTAssertLessThan(worstRequest, TransportPolicy.defaultMaxRetryWaitSeconds)
    XCTAssertEqual(TransportPolicy.default.maxRequestRetries, 4)
    XCTAssertEqual(TransportPolicy.default.maxStreamRetries, 5)
    XCTAssertEqual(TransportPolicy.default.streamIdleTimeoutMs, 300_000)
    XCTAssertEqual(TransportPolicy.off.maxRequestRetries, 0)
    XCTAssertEqual(TransportPolicy.off.streamIdleTimeoutMs, 0)
    XCTAssertEqual(TransportPolicy(maxRequestRetries: -3).maxRequestRetries, 0, "negatives clamp to off")
  }

  func testTruncationVocabularyAndPartialToolCallRule() {
    XCTAssertTrue(OutputTruncation.isTruncation("length"))
    XCTAssertTrue(OutputTruncation.isTruncation("max_tokens"))
    XCTAssertTrue(OutputTruncation.isTruncation("max_output_tokens"))
    XCTAssertFalse(OutputTruncation.isTruncation("stop"))
    XCTAssertFalse(OutputTruncation.isTruncation("tool_calls"))
    XCTAssertFalse(OutputTruncation.isTruncation("end_turn"))
    XCTAssertFalse(OutputTruncation.isTruncation(nil))

    let whole = ToolCall(id: "c1", type: "function", index: 0, function: .init(name: "spy", arguments: #"{"a": 1}"#))
    let cut = ToolCall(id: "c2", type: "function", index: 1, function: .init(name: "edit_file", arguments: #"{"path": "a.txt", "old"#))
    let empty = ToolCall(id: "c3", type: "function", index: 2, function: .init(name: "spy", arguments: "{}"))
    let none = ToolCall(id: "c4", type: "function", index: 3, function: .init(name: "spy", arguments: nil))
    XCTAssertTrue(OutputTruncation.hasCompleteArguments(whole))
    XCTAssertTrue(OutputTruncation.hasCompleteArguments(empty))
    XCTAssertFalse(OutputTruncation.hasCompleteArguments(cut))
    XCTAssertFalse(OutputTruncation.hasCompleteArguments(none))
    XCTAssertFalse(OutputTruncation.hasCompleteArguments(
      ToolCall(id: "c5", type: "function", index: 4, function: .init(name: "spy", arguments: "[1, 2]"))),
      "an array is not the object a tool takes")

    // Only the last call can be cut, and only a truncated step drops it.
    let dropped = OutputTruncation.droppingPartialToolCall(from: [whole, cut], truncated: true)
    XCTAssertEqual(dropped.kept.map(\.id), ["c1"])
    XCTAssertEqual(dropped.dropped?.function?.name, "edit_file")
    let kept = OutputTruncation.droppingPartialToolCall(from: [whole, cut], truncated: false)
    XCTAssertEqual(kept.kept.count, 2)
    XCTAssertNil(kept.dropped)
    let intact = OutputTruncation.droppingPartialToolCall(from: [whole, empty], truncated: true)
    XCTAssertEqual(intact.kept.count, 2)
    XCTAssertNil(intact.dropped)
    XCTAssertNil(OutputTruncation.droppingPartialToolCall(from: [], truncated: true).dropped)

    // The nudge is fixed text; a dropped call is named.
    XCTAssertEqual(
      OutputTruncation.nudge(droppedToolCall: nil),
      "Your reply was cut off at the output limit; continue from where you stopped, shorter.")
    XCTAssertTrue(OutputTruncation.nudge(droppedToolCall: "edit_file").hasSuffix("The incomplete edit_file call was dropped — re-issue it in full."))
    XCTAssertEqual(OutputTruncation.maxNudgesPerTurn, 1)
  }

  // MARK: Request retries

  func testRateLimitThenSuccessRetriesOnceWithoutDuplicatingHistory() async throws {
    let mock = chatMock()
    mock.chatStreamErrors = [OpenRouterError.rateLimited(message: "slow down", retryAfter: nil)]
    mock.chunkScripts = [[Fixtures.textChunk("Hello!"), Fixtures.usageChunk(cost: 0.01)]]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy())

    let events = try await Events.drain(await session.send("hi"))

    // Two requests, the same shape each time — nothing was appended between them.
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(mock.requests[0].messages.count, 2)
    XCTAssertEqual(mock.requests[1].messages.count, 2)
    XCTAssertEqual(events.retries.count, 1)
    XCTAssertEqual(events.retries.first?.attempt, 1)
    XCTAssertEqual(events.retries.first?.reason, "rate limited (429)")
    // The first retry waits the base delay (jitter ×1.0 here) — not a real sleep.
    XCTAssertEqual(sleeps.waits, [0.5])
    // The reply landed once; the record counts the retry and finished normally.
    let history = await session.history
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history.last?.content?.plainText, "Hello!")
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.retries, 1)
    XCTAssertEqual(record.steps, 1, "a retried attempt is not a step")
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.stopReason, .completed)
    XCTAssertEqual(record.costUSD, 0.01, accuracy: 0.0001)
  }

  func testRetryAfterIsHonoredOverTheBackoffAndAWaitPastTheCapEndsTheRetries() async throws {
    let mock = chatMock()
    mock.chatStreamErrors = [OpenRouterError.rateLimited(message: "slow", retryAfter: 2.5)]
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0.01)]]
    let sleeps = SleepRecorder()
    _ = try await Events.drain(await session(mock, transport: sleeps.policy()).send("hi"))
    XCTAssertEqual(sleeps.waits, [2.5])

    // A Retry-After the wait cap can't hold: no wait, no retry — the error stands.
    let capped = chatMock()
    capped.chatStreamErrors = [OpenRouterError.rateLimited(message: "slow", retryAfter: 120)]
    capped.chunkScripts = [[Fixtures.textChunk("never"), Fixtures.usageChunk(cost: 0.01)]]
    let cappedSleeps = SleepRecorder()
    let (events, error) = await drainCatching(await session(capped, transport: cappedSleeps.policy()).send("hi"))
    XCTAssertEqual(capped.requests.count, 1)
    XCTAssertEqual(cappedSleeps.waits, [])
    XCTAssertTrue(events.retries.isEmpty)
    guard case .retriesExhausted(let reason, let retries, _)? = error as? TransportError else {
      return XCTFail("expected retriesExhausted, got \(String(describing: error))")
    }
    // The reason names the cap the retries ended on, not a bare 429.
    XCTAssertEqual(reason, "rate limited (429) (Retry-After 120s would take the wait past the 60s cap)")
    XCTAssertEqual(retries, 0)
    XCTAssertEqual("\(error!)", "rate limited (429) (Retry-After 120s would take the wait past the 60s cap): Rate limited: slow Retry after 120.0s.")
  }

  func testExhaustedRequestRetriesEndTheTurnWithATransportErrorNamingTheCount() async throws {
    let mock = chatMock()
    mock.chatStreamErrors = Array(repeating: OpenRouterError.serviceOverloaded(message: "busy"), count: 3)
    mock.chunkScripts = [[Fixtures.textChunk("never reached"), Fixtures.usageChunk(cost: 0.01)]]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy(maxRequestRetries: 2))

    let (events, error) = await drainCatching(await session.send("hi"))

    XCTAssertEqual(mock.requests.count, 3, "the first attempt plus two retries")
    XCTAssertEqual(events.retries.map(\.attempt), [1, 2])
    XCTAssertEqual(sleeps.waits, [0.5, 1.0])
    guard case .retriesExhausted(let reason, let retries, let underlying)? = error as? TransportError else {
      return XCTFail("expected retriesExhausted, got \(String(describing: error))")
    }
    XCTAssertEqual(reason, "provider overloaded (529)")
    XCTAssertEqual(retries, 2)
    XCTAssertTrue(underlying is OpenRouterError)
    XCTAssertEqual(
      (error as? LocalizedError)?.errorDescription,
      "provider overloaded (529) after 2 retries: Provider overloaded: busy")
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .error)
    XCTAssertFalse(record.finished)
    // The user turn stands alone — no assistant message was ever produced.
    let history = await session.history
    XCTAssertEqual(history.count, 1)
  }

  func testANonRetryableErrorIsThrownAsBeforeWithoutARetry() async throws {
    let mock = chatMock()
    mock.chatStreamErrors = [OpenRouterError.api(statusCode: 400, message: "bad request", metadata: nil)]
    mock.chunkScripts = [[Fixtures.textChunk("never reached"), Fixtures.usageChunk(cost: 0.01)]]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy())

    let (events, error) = await drainCatching(await session.send("hi"))

    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertEqual(sleeps.waits, [])
    guard case .api(let status, _, _)? = error as? OpenRouterError else {
      return XCTFail("the raw error propagates, got \(String(describing: error))")
    }
    XCTAssertEqual(status, 400)
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .error)
  }

  func testRetriesOffThrowsTheFirstRetryableErrorUnwrapped() async throws {
    let mock = chatMock()
    mock.chatStreamErrors = [OpenRouterError.rateLimited(message: "slow", retryAfter: nil)]
    let session = session(mock, transport: .off)
    let (events, error) = await drainCatching(await session.send("hi"))
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertTrue(events.retries.isEmpty)
    guard case .retriesExhausted(_, let retries, _)? = error as? TransportError else {
      return XCTFail("expected retriesExhausted, got \(String(describing: error))")
    }
    XCTAssertEqual(retries, 0)
    XCTAssertTrue(((error as? LocalizedError)?.errorDescription ?? "").hasPrefix("rate limited (429): "))
  }

  // MARK: Stream retries

  func testAStreamThatBreaksBeforeAnyOutputIsRetriedOnTheStreamBudget() async throws {
    let mock = chatMock()
    // The first stream yields nothing and then dies; the second is the reply.
    mock.chunkScripts = [[], [Fixtures.textChunk("Hello!"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatStreamTrailingErrors = [OpenRouterError.streamError(code: 502, message: "upstream reset", metadata: nil), nil]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy(maxRequestRetries: 0, maxStreamRetries: 1))

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(events.retries.map(\.reason), ["stream error (502): upstream reset"])
    XCTAssertEqual(sleeps.waits, [0.5])
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.retries, 1)
    XCTAssertTrue(record.finished)
    let lastText = await session.history.last?.content?.plainText
    XCTAssertEqual(lastText, "Hello!")

    // The same failure with the stream budget at 0 is not retried — the request budget is
    // not the stream budget.
    let strict = chatMock()
    strict.chunkScripts = [[], [Fixtures.textChunk("never"), Fixtures.usageChunk(cost: 0.01)]]
    strict.chatStreamTrailingErrors = [OpenRouterError.streamError(code: nil, message: "reset", metadata: nil), nil]
    let (strictEvents, error) = await drainCatching(await self.session(strict, transport: sleeps.policy(maxRequestRetries: 4, maxStreamRetries: 0)).send("hi"))
    XCTAssertEqual(strict.requests.count, 1)
    XCTAssertTrue(strictEvents.retries.isEmpty)
    XCTAssertNotNil(error as? TransportError)
  }

  func testAnErrorAfterTheFirstDeltaIsNeverRetried() async throws {
    let mock = chatMock()
    mock.chunkScripts = [[Fixtures.textChunk("Hel")], [Fixtures.textChunk("never"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatStreamTrailingErrors = [OpenRouterError.streamError(code: 502, message: "upstream reset", metadata: nil), nil]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy())

    let (events, error) = await drainCatching(await session.send("hi"))

    // Output reached the user: a rerun would repeat it, so the error propagates as it always did.
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertEqual(sleeps.waits, [])
    XCTAssertTrue(events.contains { if case .textDelta("Hel") = $0 { return true } else { return false } })
    guard case .streamError? = error as? OpenRouterError else {
      return XCTFail("the raw stream error propagates, got \(String(describing: error))")
    }
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .error)
    XCTAssertNil(record.retries)
  }

  func testAFourHundredCodedStreamErrorBeforeOutputIsARefusalNotARetry() async throws {
    // OpenRouter relays a provider's 400 that lands after the response started as an SSE error
    // event under HTTP 200 — the same deterministic refusal one line later than usual. Sending
    // it five more times with backoff would only delay the answer.
    let mock = chatMock()
    mock.chunkScripts = [[], [Fixtures.textChunk("never"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatStreamTrailingErrors = [OpenRouterError.streamError(code: 400, message: "context length exceeded", metadata: nil), nil]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy())

    let (events, error) = await drainCatching(await session.send("hi"))

    XCTAssertEqual(mock.requests.count, 1, "exactly one request — a 4xx is never re-sent")
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertEqual(sleeps.waits, [])
    guard case .streamError(let code, _, _)? = error as? OpenRouterError else {
      return XCTFail("the raw stream error propagates, got \(String(describing: error))")
    }
    XCTAssertEqual(code, 400)
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .error)
    XCTAssertNil(record.retries)
  }

  func testAFourHundredCodedStreamErrorOnANativeDialectFallsBackToChatUnretried() async throws {
    // The pre-R2 path for a native refusal that arrives inside the stream: no retry, the step
    // reruns on chat within the turn, and the verdict is recorded against the endpoint.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [[]]
    mock.messagesStreamTrailingErrors = [OpenRouterError.streamError(code: 400, message: "invalid request", metadata: nil)]
    mock.chunkScripts = [[Fixtures.textChunk("from chat"), Fixtures.usageChunk(cost: 0.01)]]
    let verdicts = tempDialectStore()
    let sleeps = SleepRecorder()
    let session = session(mock, model: "anthropic/claude-test", transport: sleeps.policy(), dialectStore: verdicts)

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(mock.messagesRequests.count, 1, "one /messages request — the 400 is not retried")
    XCTAssertEqual(mock.requests.count, 1, "one chat request — the fallback")
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertEqual(sleeps.waits, [])
    XCTAssertTrue(events.fellBack)
    XCTAssertTrue(verdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages), "the verdict is recorded, as before R2")
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.dialect, "chat")
    XCTAssertTrue(record.finished)
    XCTAssertNil(record.retries)
    let lastText = await session.history.last?.content?.plainText
    XCTAssertEqual(lastText, "from chat")
  }

  func testAConnectionLostInsideTheStreamBeforeOutputIsRetried() async throws {
    // The byte stream's URLError is rethrown bare by the SSE producer (only the request phase's
    // is wrapped in `.transport`): still a connection loss, still a stream retry.
    let mock = chatMock()
    mock.chunkScripts = [[], [Fixtures.textChunk("Hello!"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatStreamTrailingErrors = [URLError(.networkConnectionLost), nil]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy())

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(events.retries.map(\.reason), ["connection lost"])
    XCTAssertEqual(sleeps.waits, [0.5])
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.retries, 1)
    XCTAssertTrue(record.finished)
  }

  func testATransportFailureAfterOutputOnANativeDialectIsNeitherRetriedNorAVerdict() async throws {
    // After output a rerun would repeat the text, so nothing is retried — and a lost connection,
    // a 5xx error event or the idle timeout is the wire's failure, not the endpoint's dialect:
    // it propagates as chat's does instead of becoming a `failure` the fallback block records
    // (which would pin the model to chat for a week).
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [[
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
    ]]
    mock.messagesStreamTrailingErrors = [OpenRouterError.streamError(code: 502, message: "upstream reset", metadata: nil)]
    mock.chunkScripts = [[Fixtures.textChunk("never — no fallback"), Fixtures.usageChunk(cost: 0.01)]]
    let verdicts = tempDialectStore()
    let sleeps = SleepRecorder()
    let session = session(mock, model: "anthropic/claude-test", transport: sleeps.policy(), dialectStore: verdicts)

    let (events, error) = await drainCatching(await session.send("hi"))

    XCTAssertEqual(mock.messagesRequests.count, 1)
    XCTAssertEqual(mock.requests.count, 0, "no chat rerun after output")
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertFalse(events.fellBack)
    XCTAssertTrue(events.contains { if case .textDelta("Hel") = $0 { return true } else { return false } })
    guard case .streamError(let code, _, _)? = error as? OpenRouterError else {
      return XCTFail("the raw stream error propagates, got \(String(describing: error))")
    }
    XCTAssertEqual(code, 502)
    XCTAssertNil(verdicts.latest(model: "anthropic/claude-test", dialect: .messages), "a transport failure is not a dialect verdict")
    XCTAssertFalse(verdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .error)
    XCTAssertEqual(record.dialect, "messages")

    // A refusal after output (not a transport shape) keeps the pre-R2 path: recorded, and the
    // forced-or-emitted guard surfaces it as the dialect's failure.
    let refusing = MockOpenRouterService()
    refusing.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    refusing.messagesEventScripts = [[
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hel"}}"#),
    ]]
    refusing.messagesStreamTrailingErrors = [MockError.nativeRefusal("unsupported")]
    let refusedVerdicts = tempDialectStore()
    let refusedSession = self.session(refusing, model: "anthropic/claude-test", transport: sleeps.policy(), dialectStore: refusedVerdicts)
    let (_, refusedError) = await drainCatching(await refusedSession.send("hi"))
    XCTAssertNotNil(refusedError as? DialectError)
    XCTAssertTrue(refusedVerdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
  }

  func testTheGuardCancelsATaskRegisteredAfterTheStreamAlreadyTerminated() async throws {
    // The watchdog can be registered after a pre-filled source was drained and the guarded
    // stream finished (the consumer runs on another thread): the termination handler is set
    // first, and a task registered after termination is cancelled on the spot instead of
    // sleeping out the whole idle window.
    let tasks = TransportPolicy.GuardTasks()
    let parked = Latch()
    let late = Task<Void, Never> { await parked.wait(for: 1) }
    tasks.cancelAll()
    XCTAssertFalse(late.isCancelled)
    tasks.register(late)
    XCTAssertTrue(late.isCancelled, "registered after termination → cancelled at once")

    let fresh = TransportPolicy.GuardTasks()
    let early = Task<Void, Never> { await parked.wait(for: 1) }
    fresh.register(early)
    XCTAssertFalse(early.isCancelled)
    fresh.cancelAll()
    XCTAssertTrue(early.isCancelled, "registered before termination → cancelled by it")
    // The latch's wait is not cancellation-aware; release both parked tasks before leaving.
    await parked.arrive()
    _ = await late.value
    _ = await early.value
  }

  func testAnIdleStreamIsCancelledAfterTheTimeoutAndRetried() async throws {
    let mock = chatMock()
    // The first stream never yields (its gate never opens); the retry's stream opens at once.
    let never = Latch()
    mock.streamGate = { _ in
      if mock.requests.count == 1 {
        await never.wait(for: 1)
      }
    }
    mock.chunkScripts = [
      [Fixtures.textChunk("never streamed"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("Hello!"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let sleeps = SleepRecorder()
    let session = session(mock, transport: sleeps.policy(streamIdleTimeoutMs: 100))

    let drained = try await withDeadline(seconds: 10) { try await Events.drain(await session.send("hi")) }
    let events = try XCTUnwrap(drained, "the idle stream must be cut, not waited on")

    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(events.retries.map(\.reason), ["stream idle for 0.1s"])
    XCTAssertEqual(sleeps.waits, [0.5])
    let lastText = await session.history.last?.content?.plainText
    XCTAssertEqual(lastText, "Hello!")
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.retries, 1)
    XCTAssertTrue(record.finished)
  }

  func testTheIdleGuardPassesAHealthyStreamThroughAndFailsASilentOne() async throws {
    // Healthy: every element, in order, then a clean finish.
    let healthy = AsyncThrowingStream<Int, Error> { continuation in
      for value in 1...3 { continuation.yield(value) }
      continuation.finish()
    }
    var seen: [Int] = []
    for try await value in TransportPolicy.guarded(healthy, idleMilliseconds: 50) {
      seen.append(value)
    }
    XCTAssertEqual(seen, [1, 2, 3])

    // Silent after one element: the element arrives, then `streamIdle`.
    let silent = AsyncThrowingStream<Int, Error> { continuation in
      continuation.yield(7)
      // never finishes
    }
    var got: [Int] = []
    var failure: Error?
    do {
      for try await value in TransportPolicy.guarded(silent, idleMilliseconds: 50) {
        got.append(value)
      }
    } catch {
      failure = error
    }
    XCTAssertEqual(got, [7])
    guard case .streamIdle(let seconds)? = failure as? TransportError else {
      return XCTFail("expected streamIdle, got \(String(describing: failure))")
    }
    XCTAssertEqual(seconds, 0.05, accuracy: 1e-9)

    // A source error passes through as itself.
    let broken = AsyncThrowingStream<Int, Error> { continuation in
      continuation.finish(throwing: MockError.scriptExhausted)
    }
    do {
      for try await _ in TransportPolicy.guarded(broken, idleMilliseconds: 50) {}
      XCTFail("expected the source error")
    } catch {
      XCTAssertTrue(error is MockError)
    }
    // Off = the source itself.
    XCTAssertEqual(TransportPolicy.off.streamIdleTimeoutMs, 0)
  }

  func testAnInterruptDuringTheBackoffEndsTheTurnAsInterrupted() async throws {
    let mock = chatMock()
    mock.chatStreamErrors = [OpenRouterError.serviceOverloaded(message: "busy")]
    mock.chunkScripts = [[Fixtures.textChunk("never"), Fixtures.usageChunk(cost: 0.01)]]
    let box = SessionBox()
    let transport = TransportPolicy(
      sleep: { _ in
        // The user hits Ctrl-C while the step waits to retry.
        await box.session?.interrupt()
        throw CancellationError()
      },
      random: { 0.5 })
    let session = session(mock, transport: transport)
    await box.set(session)

    let (events, error) = await drainCatching(await session.send("hi"))

    XCTAssertNil(error)
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertEqual(events.retries.count, 1)
    XCTAssertTrue(events.interrupted)
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .interrupted)
    XCTAssertEqual(record.retries, 1, "the retry that was waiting counts")
  }

  // MARK: Native dialects

  func testARateLimitedNativeEndpointIsRetriedAndOnExhaustionFallsBackToChatUnderACooldownNotAWeekPin() async throws {
    // Exhausted retries on a native dialect are the wire's failure, not the dialect's: the step
    // reruns on chat within the turn (a native route that is down no longer errors every turn),
    // and the recorded verdict cools the route for `transportCooldown` instead of pinning it
    // for the week an endpoint failure earns.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesStreamErrors = Array(repeating: OpenRouterError.rateLimited(message: "slow", retryAfter: nil), count: 3)
    mock.chunkScripts = [[Fixtures.textChunk("chat answered"), Fixtures.usageChunk(cost: 0.01)]]
    let verdicts = tempDialectStore()
    let sleeps = SleepRecorder()
    let session = session(
      mock, model: "anthropic/claude-test", transport: sleeps.policy(maxRequestRetries: 2), dialectStore: verdicts)

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(mock.messagesRequests.count, 3, "two retries on /messages")
    XCTAssertEqual(mock.requests.count, 1, "then the step reruns on chat, within the turn")
    XCTAssertEqual(events.retries.map(\.attempt), [1, 2])
    XCTAssertTrue(events.fellBack)
    let record = try await lastRecord(of: session)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.dialect, "chat")
    XCTAssertEqual(record.retries, 2, "the native attempt's re-sends are counted")
    let lastText = await session.history.last?.content?.plainText
    XCTAssertEqual(lastText, "chat answered")
    let verdict = try XCTUnwrap(verdicts.latest(model: "anthropic/claude-test", dialect: .messages))
    XCTAssertFalse(verdict.ok)
    XCTAssertEqual(verdict.category, DialectVerdict.transportCategory)
    XCTAssertTrue(verdict.reason?.contains("rate limited (429) after 2 retries") == true, verdict.reason ?? "")
    XCTAssertTrue(
      verdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages),
      "cooled: the next turns go straight to chat instead of paying the retries again …")
    let cooled = DialectVerdictStore(url: verdicts.url, transportCooldown: 0)
    XCTAssertFalse(
      cooled.isKnownBad(model: "anthropic/claude-test", dialect: .messages),
      "… and once the cooldown passes the native dialect is tried again — never the week-long pin")
    XCTAssertNotNil(cooled.latest(model: "anthropic/claude-test", dialect: .messages), "the verdict itself stands for arnes probe to show")
  }

  func testExhaustedRetriesOnAForcedNativeDialectKeepTheTransportErrorAndCoolTheRoute() async throws {
    // `--dialect messages` (and `arnes probe`, which forces the dialect): no chat fallback — the
    // turn ends on the transport failure it is, not a `nativeDialectFailed`, and the verdict is
    // a `transport` cooldown, so a 429 storm during a probe never pins the model for a week.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesStreamErrors = Array(repeating: OpenRouterError.serviceOverloaded(message: "busy"), count: 2)
    mock.chunkScripts = [[Fixtures.textChunk("never — a forced dialect does not fall back"), Fixtures.usageChunk(cost: 0.01)]]
    let verdicts = tempDialectStore()
    let sleeps = SleepRecorder()
    let session = session(
      mock, model: "anthropic/claude-test", dialect: .messages, transport: sleeps.policy(maxRequestRetries: 1),
      dialectStore: verdicts)

    let (events, error) = await drainCatching(await session.send("hi"))

    XCTAssertEqual(mock.messagesRequests.count, 2, "one retry on /messages")
    XCTAssertEqual(mock.requests.count, 0, "a forced dialect never falls back")
    XCTAssertFalse(events.fellBack)
    guard case .retriesExhausted(let reason, let retries, _)? = error as? TransportError else {
      return XCTFail("the transport error keeps its shape, got \(String(describing: error))")
    }
    XCTAssertEqual(reason, "provider overloaded (529)")
    XCTAssertEqual(retries, 1)
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .error)
    XCTAssertEqual(record.dialect, "messages")
    XCTAssertEqual(record.retries, 1)
    let verdict = try XCTUnwrap(verdicts.latest(model: "anthropic/claude-test", dialect: .messages))
    XCTAssertEqual(verdict.category, DialectVerdict.transportCategory)
    XCTAssertTrue(verdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages), "cooled for now")
    XCTAssertFalse(
      DialectVerdictStore(url: verdicts.url, transportCooldown: 0).isKnownBad(model: "anthropic/claude-test", dialect: .messages),
      "never pinned past the cooldown")
  }

  func testANativeRefusalStillFallsBackToChatUnretried() async throws {
    // The pre-R2 path, byte for byte: a non-retryable native failure reruns the step on chat
    // and records the verdict — no `.retrying`, one request per dialect.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesStreamErrors = [MockError.nativeRefusal("unsupported")]
    mock.chunkScripts = [[Fixtures.textChunk("from chat"), Fixtures.usageChunk(cost: 0.01)]]
    let verdicts = tempDialectStore()
    let sleeps = SleepRecorder()
    let session = session(mock, model: "anthropic/claude-test", transport: sleeps.policy(), dialectStore: verdicts)

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(mock.messagesRequests.count, 1)
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertTrue(events.fellBack)
    XCTAssertEqual(sleeps.waits, [])
    XCTAssertTrue(verdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.dialect, "chat")
    XCTAssertNil(record.retries)
  }

  func testAMessagesStepThatHitsMaxTokensIsTruncated() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":10}}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The answer begins"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"and ends."}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = session(mock, model: "anthropic/claude-test", transport: .default)

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(events.truncations, 1)
    XCTAssertEqual(mock.messagesRequests.count, 2)
    // The nudge rides the second request as a user turn after the partial text.
    let second = Fixtures.jsonValue(mock.messagesRequests[1].messages).arrayValue ?? []
    XCTAssertEqual(second.map { $0["role"]?.stringValue }, ["user", "assistant", "user"])
    XCTAssertTrue((second[2]["content"]?.stringValue ?? second[2]["content"]?.arrayValue?.first?["text"]?.stringValue ?? "")
      .contains("cut off at the output limit"))
    let record = try await lastRecord(of: session)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.stopReason, .completed)
    XCTAssertEqual(record.nudges, 1)
  }

  func testAResponsesStepThatIsIncompleteOnMaxOutputTokensIsTruncated() async throws {
    var accumulator = ResponsesAccumulator()
    _ = accumulator.ingest(Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"partial"}"#))
    XCTAssertNil(accumulator.incompleteReason)
    _ = accumulator.ingest(Fixtures.responsesEvent(
      #"{"type":"response.incomplete","response":{"id":"r0","status":"incomplete","model":"openai/gpt-test","output":[],"incomplete_details":{"reason":"max_output_tokens"},"usage":{"cost":0.01,"input_tokens":10}}}"#))
    XCTAssertEqual(accumulator.incompleteReason, "max_output_tokens")
    XCTAssertTrue(OutputTruncation.isTruncation(accumulator.incompleteReason))

    var completed = ResponsesAccumulator()
    _ = completed.ingest(Fixtures.responsesEvent(
      #"{"type":"response.completed","response":{"id":"r1","status":"completed","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":10}}}"#))
    XCTAssertNil(completed.incompleteReason)

    // End to end on the /responses dialect: the cut-off step is nudged, the next finishes.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "openai/gpt-test"))
    mock.responsesEventScripts = [
      [
        Fixtures.responsesEvent(#"{"type":"response.created","response":{"id":"r0","model":"openai/gpt-test","output":[]}}"#),
        Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"partial"}"#),
        Fixtures.responsesEvent(#"{"type":"response.incomplete","response":{"id":"r0","status":"incomplete","model":"openai/gpt-test","output":[],"incomplete_details":{"reason":"max_output_tokens"},"usage":{"cost":0.01,"input_tokens":10}}}"#),
      ],
      [
        Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"done"}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r1","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":12}}}"#),
      ],
    ]
    let session = session(mock, model: "openai/gpt-test", transport: .default)
    let events = try await Events.drain(await session.send("hi"))
    XCTAssertEqual(events.truncations, 1)
    XCTAssertEqual(mock.responsesRequests.count, 2)
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.dialect, "responses")
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.nudges, 1)
  }

  // MARK: Truncation

  func testALengthCutoffInsideToolArgumentsDropsTheCallAndNudgesOnce() async throws {
    let mock = chatMock()
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: #"{"path": "a.txt", "old"#),
        Fixtures.finishChunk("length"),
      ],
      [Fixtures.textChunk("Done."), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = CountingTool()
    let session = session(mock, tools: [spy], transport: .default)

    let events = try await Events.drain(await session.send("edit it"))

    XCTAssertEqual(spy.executions, 0, "a half-formed call never runs")
    XCTAssertEqual(events.truncations, 1)
    XCTAssertFalse(events.contains { if case .toolCall = $0 { return true } else { return false } })
    XCTAssertEqual(mock.requests.count, 2)
    // The second request: system, the user's turn, the nudge — no dangling tool call, no
    // orphan tool result, and the nudge names the dropped call.
    let second = mock.requests[1].messages
    XCTAssertEqual(second.map(\.role), [.system, .user, .user])
    let nudge = second[2].content?.plainText ?? ""
    XCTAssertTrue(nudge.hasPrefix("[arnes] Your reply was cut off at the output limit; continue from where you stopped, shorter."))
    XCTAssertTrue(nudge.contains("The incomplete spy call was dropped — re-issue it in full."))
    let record = try await lastRecord(of: session)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.stopReason, .completed)
    XCTAssertEqual(record.nudges, 1)
    XCTAssertEqual(record.toolCalls, 0)
    let lastText = await session.history.last?.content?.plainText
    XCTAssertEqual(lastText, "Done.")
  }

  func testASecondCutoffEndsTheTurnTruncatedWithThePartialTextKept() async throws {
    let mock = chatMock()
    mock.chunkScripts = [
      [Fixtures.textChunk("Part one, which runs long and"), Fixtures.finishChunk("length")],
      [Fixtures.textChunk("Part two, also cut"), Fixtures.finishChunk("length")],
      [Fixtures.textChunk("never asked"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = session(mock, transport: .default)

    let events = try await Events.drain(await session.send("explain"))

    XCTAssertEqual(mock.requests.count, 2, "one nudge per turn; the second cutoff ends it")
    XCTAssertEqual(events.truncations, 2)
    XCTAssertTrue(events.contains { if case .assistantText("Part two, also cut") = $0 { return true } else { return false } })
    let record = try await lastRecord(of: session)
    XCTAssertEqual(record.stopReason, .truncated)
    XCTAssertFalse(record.finished)
    XCTAssertEqual(record.nudges, 1)
    XCTAssertEqual(record.steps, 2)
    // History: user, the first partial, the nudge, the second partial — the next turn continues
    // from a valid conversation.
    let history = await session.history
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .user, .assistant])
    XCTAssertEqual(history[1].content?.plainText, "Part one, which runs long and")
    XCTAssertEqual(history[3].content?.plainText, "Part two, also cut")
    // No stall nudge fired for the cut-off replies.
    XCTAssertFalse(events.contains { if case .nudged = $0 { return true } else { return false } })
  }

  func testWholeCallsBeforeTheCutoffRunAndTheModelHearsAboutTheDroppedOne() async throws {
    let mock = chatMock()
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}", index: 0),
        Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: #"{"x": "cut off he"#, index: 1),
        Fixtures.finishChunk("length"),
      ],
      [Fixtures.textChunk("Done."), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = CountingTool()
    let session = session(mock, tools: [spy], transport: .default)

    let events = try await Events.drain(await session.send("do both"))

    XCTAssertEqual(spy.executions, 1, "the whole call ran, the cut one did not")
    XCTAssertEqual(events.truncations, 1)
    XCTAssertEqual(mock.requests.count, 2)
    let second = mock.requests[1].messages
    XCTAssertEqual(second.map(\.role), [.system, .user, .assistant, .tool, .user])
    XCTAssertEqual(second[2].toolCalls?.map(\.id), ["c1"], "only the whole call entered history")
    XCTAssertEqual(second[3].toolCallId, "c1")
    let notice = second[4].content?.plainText ?? ""
    XCTAssertTrue(notice.hasPrefix("[arnes] "))
    XCTAssertTrue(notice.contains("cut off at the output limit"))
    XCTAssertTrue(notice.contains("The incomplete spy call was dropped"))
    let record = try await lastRecord(of: session)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.toolCalls, 1)
    XCTAssertEqual(record.nudges, 1)
  }

  // MARK: Byte-identical without errors

  func testANoErrorRunRecordsNoRetriesAndEmitsNoTransportEvents() async throws {
    let mock = chatMock()
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("Done."), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = CountingTool()
    let session = session(mock, tools: [spy], transport: .default)
    let events = try await Events.drain(await session.send("go"))
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(spy.executions, 1)
    XCTAssertTrue(events.retries.isEmpty)
    XCTAssertEqual(events.truncations, 0)
    let record = try await lastRecord(of: session)
    XCTAssertNil(record.retries)
    XCTAssertNil(record.nudges)
    XCTAssertEqual(record.stopReason, .completed)
  }

  // MARK: Records and config

  func testRunRecordRetriesIsOptionalAndOldRowsDecode() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = """
      {"id":"1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0,"finished":true}
      """
    XCTAssertNil(try decoder.decode(RunRecord.self, from: Data(legacy.utf8)).retries)
    let retried = legacy.dropLast() + #","retries":3}"#
    XCTAssertEqual(try decoder.decode(RunRecord.self, from: Data(retried.utf8)).retries, 3)

    // A record that retried nothing writes no key — a no-retry row is byte-identical.
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    XCTAssertFalse(String(decoding: try encoder.encode(record), as: UTF8.self).contains("retries"))
    record.retries = 2
    XCTAssertTrue(String(decoding: try encoder.encode(record), as: UTF8.self).contains(#""retries":2"#))
    XCTAssertEqual(try decoder.decode(RunRecord.self, from: try encoder.encode(record)).retries, 2)
  }

  func testTransportPolicyConfigDecodesUnderPoliciesAndResolvesOverDefaults() throws {
    let decoder = JSONDecoder()
    // An old config: no `transport` key, the built-in numbers.
    let old = try decoder.decode(ArnesConfig.self, from: Data(#"{"policies":{"environmentContext":false}}"#.utf8))
    XCTAssertNil(old.policies?.transport)
    XCTAssertEqual(old.policies?.environmentContext, false)
    XCTAssertEqual((old.policies?.transport?.policy ?? .default).maxRequestRetries, 4)

    let configured = try decoder.decode(ArnesConfig.self, from: Data(
      #"{"policies":{"transport":{"maxRequestRetries":1,"streamIdleTimeoutMs":0}}}"#.utf8))
    let transport = try XCTUnwrap(configured.policies?.transport)
    XCTAssertEqual(transport, TransportPolicyConfig(maxRequestRetries: 1, maxStreamRetries: nil, streamIdleTimeoutMs: 0))
    let policy = transport.policy
    XCTAssertEqual(policy.maxRequestRetries, 1)
    XCTAssertEqual(policy.maxStreamRetries, 5, "an unset key is the default")
    XCTAssertEqual(policy.streamIdleTimeoutMs, 0, "0 switches the idle timeout off")
    XCTAssertEqual(policy.maxRetryWaitSeconds, 60)

    // Round trip keeps the keys' spelling.
    let encoded = String(decoding: try JSONEncoder().encode(PoliciesConfig(transport: TransportPolicyConfig(maxStreamRetries: 2))), as: UTF8.self)
    XCTAssertTrue(encoded.contains(#""transport":{"maxStreamRetries":2}"#))
  }

  func testForSubagentCarriesTheTransportPolicy() {
    let lead = Session.Configuration(model: "lead/model", transport: TransportPolicy(maxRequestRetries: 7, streamIdleTimeoutMs: 1234))
    let nested = lead.forSubagent(named: "explore", model: "sub/model", systemSuffix: "role")
    XCTAssertEqual(nested.transport.maxRequestRetries, 7)
    XCTAssertEqual(nested.transport.streamIdleTimeoutMs, 1234)
    XCTAssertEqual(Session.Configuration(model: "m").transport.maxRequestRetries, TransportPolicy.defaultMaxRequestRetries)
  }
}

/// Lets a sleep seam reach the session it is waiting inside of.
private actor SessionBox {
  var session: Session?

  func set(_ session: Session) {
    self.session = session
  }
}
