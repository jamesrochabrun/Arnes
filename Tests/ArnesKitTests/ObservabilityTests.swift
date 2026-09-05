import Foundation
import XCTest
@testable import ArnesKit

/// O1 — the read-side telemetry the Kit exposes: `RunRecord.reasoningReplayed` decodes with
/// `decodeIfPresent` (an old row is untouched and re-encodes without the key; a turn that
/// replayed nothing writes none), and `RunResult.cached_tokens` mirrors the record's cached
/// prompt tokens — nil, and so omitted like `verifier_passed`, where the record carries none,
/// and never set by `failure`. The per-dialect counts themselves are pinned beside the
/// `reasoningBlocks` asserts in `ReasoningRoundTripTests`.
final class ObservabilityTests: XCTestCase {
  private static let legacyRow = """
    {"id":"1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0,"finished":true,"reasoningBlocks":2}
    """

  private func record(cachedTokens: Int?) -> RunRecord {
    var record = RunRecord(task: "t", model: "req/model", dialect: "chat", packFamily: "generic")
    record.finished = true
    record.stopReason = .completed
    record.promptTokens = 900
    record.cachedTokens = cachedTokens
    return record
  }

  // MARK: RunRecord.reasoningReplayed

  func testOldRowDecodesWithoutReasoningReplayedAndReencodesTheSameKeys() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601

    let decoded = try decoder.decode(RunRecord.self, from: Data(Self.legacyRow.utf8))
    XCTAssertEqual(decoded.reasoningBlocks, 2, "what the row said it produced")
    XCTAssertNil(decoded.reasoningReplayed, "an older row never said what it replayed")

    // The new field adds nothing to a row that never had it: the re-encoded row carries the
    // legacy keys (plus `routedModels`, which every row has always written), never
    // `reasoningReplayed`, and every legacy value survives.
    let reencoded = try XCTUnwrap(JSONSerialization.jsonObject(with: try encoder.encode(decoded)) as? [String: Any])
    let legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.legacyRow.utf8)) as? [String: Any])
    XCTAssertNil(reencoded["reasoningReplayed"])
    XCTAssertEqual(Set(reencoded.keys).subtracting(["routedModels"]), Set(legacy.keys))
    for (key, value) in legacy {
      XCTAssertEqual(reencoded[key] as? NSObject, value as? NSObject, key)
    }
  }

  func testReasoningReplayedRoundTripsAndIsWrittenOnlyWhenSet() throws {
    var record = RunRecord(task: "t", model: "m", dialect: "messages", packFamily: "anthropic")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    XCTAssertFalse(String(decoding: try encoder.encode(record), as: UTF8.self).contains("reasoningReplayed"))
    record.reasoningBlocks = 3
    record.reasoningReplayed = 2
    let text = String(decoding: try encoder.encode(record), as: UTF8.self)
    XCTAssertTrue(text.contains(#""reasoningReplayed":2"#), text)
    let back = try decoder.decode(RunRecord.self, from: Data(text.utf8))
    XCTAssertEqual(back.reasoningBlocks, 3, "produced stays what it was")
    XCTAssertEqual(back.reasoningReplayed, 2)
  }

  // MARK: RunResult.cached_tokens

  func testRunResultCarriesTheRecordsCachedTokensAndStaysNilWithoutThem() throws {
    let with = RunResult(
      result: AgentResult(text: "ok", record: record(cachedTokens: 120), sessionId: "S"), costEstimated: false)
    XCTAssertEqual(with.cachedTokens, 120)
    let line = HeadlessJSON.line(with)
    XCTAssertTrue(line.contains(#""cached_tokens":120"#), line)
    XCTAssertEqual(try JSONDecoder().decode(RunResult.self, from: Data(line.utf8)), with, "round-trips")

    let without = RunResult(
      result: AgentResult(text: "ok", record: record(cachedTokens: nil), sessionId: "S"), costEstimated: false)
    XCTAssertNil(without.cachedTokens, "a record that cached nothing carries none")
    XCTAssertFalse(HeadlessJSON.line(without).contains("cached_tokens"), "nil is omitted, the way verifier_passed encodes nil")
    XCTAssertEqual(without.promptTokens, 900, "the neighbouring keys are untouched")
  }

  func testFailureEnvelopeLeavesCachedTokensNilAndTheMemberwiseInitDefaultsIt() {
    let failure = RunResult.failure(
      stopReason: .error, error: "boom", sessionId: "S", model: "m", provider: nil,
      record: record(cachedTokens: 120), costEstimated: false, durationMs: 1)
    XCTAssertNil(failure.cachedTokens, "a run that never returned reports no cache figure, even with a record")
    XCTAssertEqual(failure.promptTokens, 900, "the record's other figures still ride the failure")

    let assembled = RunResult(
      sessionId: "S", runId: nil, stopReason: .completed, isError: false, error: nil, result: "",
      structuredOutput: nil, model: "m", routedModels: [], dialect: nil, provider: nil, steps: 0,
      toolCalls: 0, deniedCalls: 0, permissionDenials: [], costUSD: 0, costEstimated: false,
      promptTokens: nil, completionTokens: nil, durationMs: 0, verifierPassed: nil, verdict: nil)
    XCTAssertNil(assembled.cachedTokens, "the field-by-field init keeps every existing caller: it defaults to nil")
  }
}
