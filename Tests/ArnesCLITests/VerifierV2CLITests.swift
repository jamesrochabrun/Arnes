import ArnesKit
import XCTest
@testable import arnes

/// V1 at the CLI: the `arnes evals` table gains one trailing `verifier` column — the loop-1
/// verifier's agreement with the bash check over the rows it graded, `–` where none was.
final class VerifierV2CLITests: XCTestCase {
  private func outcome(check: Bool, verifier: Bool?, model: String, cost: Double = 0.01) -> EvalOutcome {
    EvalOutcome(
      suite: "basics", taskId: "t", model: model, trial: 1, checkPassed: check, agentFinished: true,
      steps: 2, toolCalls: 1, costUSD: cost, durationSeconds: 1, startedAt: Date(), routedModels: [],
      error: nil, dialect: "chat", verifierPassed: verifier)
  }

  func testHeaderEndsWithTheVerifierColumn() {
    XCTAssertTrue(
      EvalsShow.header.hasSuffix("cost      last run    verifier"),
      "the pre-V1 columns, then the verifier column: \(EvalsShow.header)")
    XCTAssertTrue(EvalsShow.header.hasPrefix("suite        model "), "the leading columns are untouched")
  }

  func testRowAppendsAgreementOrADashAsItsLastColumn() throws {
    let rows = EvalHistoryRow.aggregate([
      outcome(check: true, verifier: true, model: "a/verified"),
      outcome(check: false, verifier: false, model: "a/verified"),
      outcome(check: true, verifier: false, model: "a/verified"),
      outcome(check: true, verifier: nil, model: "b/plain"),
    ])
    let verified = try XCTUnwrap(rows.first { $0.model == "a/verified" })
    let plain = try XCTUnwrap(rows.first { $0.model == "b/plain" })

    let verifiedLine = EvalsShow.line(for: verified, suiteLabel: "basics", lastRun: "08-31 12:00")
    XCTAssertTrue(verifiedLine.hasSuffix("08-31 12:00  2/3 agree"), verifiedLine)
    XCTAssertTrue(verifiedLine.hasPrefix("basics       a/verified "), verifiedLine)
    XCTAssertTrue(verifiedLine.contains("2/3 (66%)"), "the pass column is what it was: \(verifiedLine)")

    let plainLine = EvalsShow.line(for: plain, suiteLabel: "", lastRun: "08-31 12:00")
    XCTAssertTrue(plainLine.hasSuffix("08-31 12:00  –"), "no verdict → a dash, never 0/0: \(plainLine)")
    XCTAssertEqual(EvalsShow.verifierCell(plain), "–")
    XCTAssertEqual(EvalsShow.verifierCell(verified), "2/3 agree")

    // The verifier cell starts where the header says it does.
    let column = try XCTUnwrap(EvalsShow.header.range(of: "verifier")).lowerBound
    let offset = EvalsShow.header.distance(from: EvalsShow.header.startIndex, to: column)
    let cellStart = try XCTUnwrap(verifiedLine.range(of: "2/3 agree")).lowerBound
    XCTAssertEqual(verifiedLine.distance(from: verifiedLine.startIndex, to: cellStart), offset)
  }
}
