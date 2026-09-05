import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// R1 — `arnes probe <model> --effort <level>`: the flag parses like `do`'s, an unknown level
/// is a usage error before anything connects, and the success/failure lines say what the
/// reasoning round-trip did.
final class ProbeEffortFlagTests: XCTestCase {
  func testProbeRecordsAThrownTransportFailureAsTransportNotAnEndpointVerdict() {
    // A 429 storm or an idle stream during a probe used to record a plain failed verdict — the
    // model pinned to chat for 7 days by a probe that never reached the endpoint's dialect.
    let model = "anthropic/claude-test"
    let exhausted = TransportError.retriesExhausted(
      reason: "rate limited (429)", retries: 4, underlying: OpenRouterError.rateLimited(message: "slow", retryAfter: nil))
    XCTAssertEqual(Probe.verdictCategory(thrown: exhausted, text: "\(exhausted)", model: model), DialectVerdict.transportCategory)
    XCTAssertEqual(
      Probe.verdictCategory(thrown: TransportError.streamIdle(seconds: 300), text: "stream idle", model: model),
      DialectVerdict.transportCategory)
    XCTAssertEqual(
      Probe.verdictCategory(thrown: OpenRouterError.serviceOverloaded(message: "busy"), text: "busy", model: model),
      DialectVerdict.transportCategory, "a retryable error thrown bare is the wire's too")
    // Everything else is the failure text's own classification, as before.
    let thinking = "messages.1.content.0: Expected `thinking` or `redacted_thinking`, but found `tool_use`"
    XCTAssertEqual(
      Probe.verdictCategory(thrown: DialectError.nativeDialectFailed("messages", thinking), text: thinking, model: model),
      DialectVerdict.thinkingCategory)
    XCTAssertEqual(
      Probe.verdictCategory(thrown: nil, text: "messages.0.content.0.cache_control: Extra inputs are not permitted", model: model),
      DialectVerdict.cacheControlCategory)
    XCTAssertNil(Probe.verdictCategory(thrown: DialectError.nativeDialectFailed("messages", "404 model not found"), text: "404 model not found", model: model))
    XCTAssertNil(Probe.verdictCategory(thrown: nil, text: "loop did not finish", model: model))

    XCTAssertTrue(Probe.recordedLine(DialectVerdict.transportCategory).contains("for the next 15 minutes only"))
    XCTAssertTrue(Probe.recordedLine(DialectVerdict.cacheControlCategory).contains("never pins"))
    XCTAssertTrue(Probe.recordedLine(DialectVerdict.thinkingCategory).contains("never pins"))
    XCTAssertEqual(Probe.recordedLine(nil), "  recorded — auto dialect selection will use chat for this model")
    XCTAssertTrue(Probe.categoryNote(DialectVerdict.transportCategory).contains("category: transport"))
    XCTAssertTrue(Probe.categoryNote(DialectVerdict.cacheControlCategory).contains("category: cache_control"))
    XCTAssertEqual(Probe.categoryNote(nil), "")
  }

  func testProbeParsesEffort() throws {
    let command = try Probe.parse(["anthropic/claude-test", "--effort", "medium"])
    XCTAssertEqual(command.model, "anthropic/claude-test")
    XCTAssertEqual(command.effort, "medium")
    XCTAssertEqual(try parseEffort(command.effort), .medium)

    let plain = try Probe.parse(["anthropic/claude-test"])
    XCTAssertNil(plain.effort, "unset leaves the probe exactly as it was")
    XCTAssertNil(try parseEffort(plain.effort))

    // `none` is the dial's own value, not an unset flag: the probe must tell the two apart
    // (thinking is off, the session sends `thinking: disabled`, the line says nothing about replay).
    let off = try Probe.parse(["anthropic/claude-test", "--effort", "none"])
    XCTAssertEqual(try parseEffort(off.effort), Reasoning.Effort.none)
    XCTAssertNotNil(try parseEffort(off.effort))
  }

  func testProbeRefusesAnUnknownEffortAtParseTime() {
    XCTAssertThrowsError(try Probe.parse(["anthropic/claude-test", "--effort", "turbo"])) { error in
      XCTAssertTrue(Probe.message(for: error).contains("unknown effort"), Probe.message(for: error))
    }
  }

  func testSuccessAndFailureLinesNameTheReasoningRoundTrip() {
    var record = RunRecord(task: "t", model: "m", dialect: "messages", packFamily: "anthropic")
    XCTAssertEqual(Probe.reasoningNote(thinking: false, target: .messages, record: record), "",
                   "without effort the line is byte-identical to before")
    XCTAssertEqual(Probe.reasoningNote(thinking: true, target: .messages, record: record), " (no reasoning blocks returned)")
    // Produced but never sent back is not a round-trip: the line says so instead of claiming one.
    record.reasoningBlocks = 1
    XCTAssertEqual(
      Probe.reasoningNote(thinking: true, target: .messages, record: record),
      " (reasoning returned but not replayed — the second step sent no block)")
    XCTAssertEqual(
      Probe.reasoningNote(thinking: true, target: .responses, record: record),
      " (reasoning returned but not replayed — the second step sent no block)")
    // Only a request that replayed a block earns the replay note.
    record.reasoningReplayed = 1
    XCTAssertEqual(Probe.reasoningNote(thinking: true, target: .messages, record: record), " (thinking replayed)")
    XCTAssertEqual(Probe.reasoningNote(thinking: true, target: .responses, record: record), " (encrypted reasoning replayed)")

    XCTAssertEqual(Probe.categoryNote(nil), "")
    XCTAssertEqual(
      Probe.categoryNote(DialectVerdict.thinkingCategory),
      " (category: thinking — not pinned; the endpoint is fine, the request was not)")
  }
}
