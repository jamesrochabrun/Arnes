import ArnesKit
import XCTest
@testable import arnes

/// The `arnes do` exit-code table, row by row, plus the precedence when several rows apply.
final class ExitCodeTests: XCTestCase {
  private func result(
    _ stopReason: StopReason?,
    verifierPassed: Bool? = nil,
    denied: Int = 0,
    isError: Bool? = nil)
    -> RunResult
  {
    RunResult(
      sessionId: "S", runId: "R", stopReason: stopReason,
      isError: isError ?? (stopReason == .error), error: nil, result: "", structuredOutput: nil,
      model: "m", routedModels: [], dialect: "chat", provider: nil, steps: 1, toolCalls: 0,
      deniedCalls: denied, permissionDenials: [], costUSD: 0, costEstimated: false,
      promptTokens: nil, completionTokens: nil, durationMs: 0, verifierPassed: verifierPassed, verdict: nil)
  }

  func testTable() {
    let rows: [(StopReason, Int32)] = [
      (.completed, 0),
      (.planProposed, 0),
      (.error, 1),
      (.maxSteps, 3),
      (.budget, 3),
      (.timeout, 3),
      (.structuredOutputFailed, 3),
      (.stuck, 3),
      (.deniedLoop, 3),
      (.truncated, 3),
      (.hookStopped, 3),
      (.interrupted, 130),
    ]
    for (reason, code) in rows {
      XCTAssertEqual(ArnesExit.code(for: result(reason), failOnDenied: false), code, "\(reason)")
    }
    // Every reason has a row above — a new StopReason must be added here too.
    XCTAssertEqual(Set(rows.map(\.0)), Set(StopReason.allCases))
  }

  func testRawValuesAreTheDocumentedNumbers() {
    XCTAssertEqual(ArnesExit.ok.rawValue, 0)
    XCTAssertEqual(ArnesExit.error.rawValue, 1)
    XCTAssertEqual(ArnesExit.verifierFailed.rawValue, 2)
    XCTAssertEqual(ArnesExit.stopped.rawValue, 3)
    XCTAssertEqual(ArnesExit.denied.rawValue, 4)
    XCTAssertEqual(ArnesExit.usage.rawValue, 64)
    XCTAssertEqual(ArnesExit.interrupted.rawValue, 130)
    XCTAssertEqual(ArnesExit.terminated.rawValue, 143)
  }

  func testVerifierFailIsTwoOnlyWhenTheRunCompleted() {
    XCTAssertEqual(ArnesExit.code(for: result(.completed, verifierPassed: false), failOnDenied: false), 2)
    XCTAssertEqual(ArnesExit.code(for: result(.completed, verifierPassed: true), failOnDenied: false), 0)
    // A verifier never runs on an unfinished turn, but the table would still say 3 first.
    XCTAssertEqual(ArnesExit.code(for: result(.maxSteps, verifierPassed: false), failOnDenied: false), 2,
                   "a recorded FAIL outranks a stopped-short reason")
  }

  func testFailOnDeniedOutranksVerifierAndStoppedButNotErrorOrInterrupt() {
    XCTAssertEqual(ArnesExit.code(for: result(.completed, denied: 1), failOnDenied: false), 0, "opt-in only")
    XCTAssertEqual(ArnesExit.code(for: result(.completed, denied: 1), failOnDenied: true), 4)
    XCTAssertEqual(ArnesExit.code(for: result(.completed, verifierPassed: false, denied: 1), failOnDenied: true), 4)
    XCTAssertEqual(ArnesExit.code(for: result(.deniedLoop, denied: 3), failOnDenied: true), 4)
    XCTAssertEqual(ArnesExit.code(for: result(.deniedLoop, denied: 3), failOnDenied: false), 3)
    XCTAssertEqual(ArnesExit.code(for: result(.error, denied: 1), failOnDenied: true), 1)
    XCTAssertEqual(ArnesExit.code(for: result(.interrupted, denied: 1), failOnDenied: true), 130)
  }

  func testSignalDecidesBetween130And143() {
    XCTAssertEqual(ArnesExit.code(for: result(.interrupted), failOnDenied: false, signal: .sigint), 130)
    XCTAssertEqual(ArnesExit.code(for: result(.interrupted), failOnDenied: false, signal: .sigterm), 143)
    XCTAssertEqual(ArnesExit.code(for: result(.interrupted), failOnDenied: false, signal: nil), 130,
                   "an Agent.interrupt() with no signal reads as Ctrl-C")
    // A signal only matters for an interrupted run.
    XCTAssertEqual(ArnesExit.code(for: result(.completed), failOnDenied: false, signal: .sigterm), 0)
    XCTAssertEqual(ArnesExit.Signal.sigint.exitCode, 130)
    XCTAssertEqual(ArnesExit.Signal.sigterm.exitCode, 143)
  }

  func testIsErrorOrAMissingReasonIsOne() {
    XCTAssertEqual(ArnesExit.code(for: result(nil), failOnDenied: false), 1)
    XCTAssertEqual(ArnesExit.code(for: result(.completed, isError: true), failOnDenied: false), 1)
    XCTAssertEqual(ArnesExit.code(for: result(.timeout, isError: true), failOnDenied: true), 1)
  }

  func testSignalStateNotesTheFirstAndFlagsARepeat() {
    let state = SignalState()
    XCTAssertNil(state.received)
    XCTAssertFalse(state.note(.sigterm))
    XCTAssertEqual(state.received, .sigterm)
    XCTAssertTrue(state.note(.sigint), "the second signal is the user insisting")
    XCTAssertEqual(state.received, .sigterm, "the first cause is the one reported")
  }
}
