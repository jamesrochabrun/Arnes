import XCTest
@testable import ArnesKit

/// X5's pure report layer: per-model summaries with pass@k / pass^k, the baseline comparison
/// (regressions, fixes, the two windows) and the CI gate's exit code.
final class EvalReportTests: XCTestCase {
  private let day: TimeInterval = 86_400
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func row(
    task: String, model: String = "m", trial: Int = 1, passed: Bool, dialect: String? = "chat",
    suite: String = "s", at: Date? = nil, cost: Double = 0.01, steps: Int = 3, seconds: Double = 2,
    error: String? = nil, graderCost: Double? = nil)
    -> EvalOutcome
  {
    EvalOutcome(
      suite: suite, taskId: task, model: model, trial: trial, checkPassed: passed, agentFinished: true,
      steps: steps, toolCalls: 1, costUSD: cost, durationSeconds: seconds, startedAt: at ?? t0,
      routedModels: [], error: error, dialect: dialect, graderCostUSD: graderCost)
  }

  // MARK: Summaries, pass@k, pass^k

  /// Two tasks × 3 trials: one task 3/3, the other 1/3 → pass rate 4/6, pass@3 2/2, pass^3 1/2.
  private var threeTrialFixture: [EvalOutcome] {
    [
      row(task: "a", trial: 1, passed: true), row(task: "a", trial: 2, passed: true), row(task: "a", trial: 3, passed: true),
      row(task: "b", trial: 1, passed: false), row(task: "b", trial: 2, passed: true), row(task: "b", trial: 3, passed: false),
    ]
  }

  func testPassAtKAndPassPowKFromThreeTrials() throws {
    let summaries = EvalReport.summaries(threeTrialFixture)
    XCTAssertEqual(summaries.count, 1)
    let summary = try XCTUnwrap(summaries.first)
    XCTAssertEqual(summary.model, "m")
    XCTAssertEqual(summary.dialect, "chat")
    XCTAssertEqual(summary.trials, 6)
    XCTAssertEqual(summary.passed, 4)
    XCTAssertEqual(summary.passRate, 4.0 / 6.0, accuracy: 1e-9)
    XCTAssertEqual(summary.tasks, 2)
    XCTAssertEqual(summary.tasksWithAnyPass, 2)
    XCTAssertEqual(summary.tasksWithAllPass, 1)
    XCTAssertEqual(summary.trialsPerTask, 3)
    XCTAssertEqual(EvalReport.passAtK(summary), 1.0)
    XCTAssertEqual(EvalReport.passPowK(summary), 0.5)
    XCTAssertEqual(summary.costUSD, 0.06, accuracy: 1e-9)
    XCTAssertEqual(summary.avgSteps, 3)
    XCTAssertEqual(summary.avgSeconds, 2)
    XCTAssertEqual(summary.errors, 0)
    XCTAssertEqual(summary.graderCostUSD, 0)
  }

  func testPassAtKIsNilForASingleTrialPerTask() {
    let single = EvalReport.summaries([row(task: "a", passed: true), row(task: "b", passed: false)])
    XCTAssertEqual(single.count, 1)
    XCTAssertEqual(single[0].trialsPerTask, 1)
    XCTAssertNil(EvalReport.passAtK(single[0]))
    XCTAssertNil(EvalReport.passPowK(single[0]))
    XCTAssertEqual(single[0].passRate, 0.5)
  }

  func testSummariesGroupByModelAndDialectAndSortLikeEvalStats() {
    let summaries = EvalReport.summaries([
      row(task: "a", model: "cheap", passed: true, cost: 0.001),
      row(task: "a", model: "dear", passed: true, cost: 0.1, error: "timeout after 300s", graderCost: 0.002),
      row(task: "a", model: "weak", passed: false, cost: 0.0001),
      // The same model under a second dialect is its own summary.
      row(task: "a", model: "weak", passed: true, dialect: "messages", cost: 0.0001),
    ])
    // Pass rate first, then cost — the scoreboard's rule: the three full passes by cost, then
    // the miss; the same model under two dialects is two summaries.
    XCTAssertEqual(summaries.map(\.model), ["weak", "cheap", "dear", "weak"])
    XCTAssertEqual(summaries.map(\.dialect), ["messages", "chat", "chat", "chat"])
    XCTAssertEqual(summaries[1].costUSD, 0.001, accuracy: 1e-9)
    XCTAssertEqual(summaries[2].errors, 1)
    XCTAssertEqual(summaries[2].graderCostUSD, 0.002, accuracy: 1e-9)
    XCTAssertEqual(summaries[3].passRate, 0)
    XCTAssertTrue(EvalReport.summaries([]).isEmpty)
  }

  // MARK: Compare

  private func history(task: String, passes: [Bool], daysAgo: Double = 1, model: String = "m") -> [EvalOutcome] {
    passes.enumerated().map { index, passed in
      row(task: task, model: model, trial: index + 1, passed: passed, at: t0.addingTimeInterval(-daysAgo * day - Double(index)))
    }
  }

  func testCompareFindsRegressionsFixesAndNeither() {
    let history = history(task: "reg", passes: [true, true, true, true, true])
      + history(task: "fix", passes: [false, false, false, false, false])
      + history(task: "meh", passes: [true, true, true, false, false])
      + history(task: "held", passes: [true, true])
    let current = [
      row(task: "reg", passed: false),   // 5/5 → 0/1: a regression
      row(task: "fix", passed: true),    // 0/5 → 1/1: a fix
      row(task: "meh", passed: false),   // 3/5 → 0/1: neither (the baseline wasn't reliable)
      row(task: "held", passed: true),   // 2/2 → 1/1: neither
      row(task: "new", passed: true),    // no baseline: neither, listed apart
    ]
    let comparison = EvalReport.compare(history: history, current: current, window: .last(rows: 5))
    XCTAssertEqual(comparison.regressions.map(\.taskId), ["reg"])
    XCTAssertEqual(comparison.fixes.map(\.taskId), ["fix"])
    XCTAssertEqual(comparison.withoutBaseline.map(\.taskId), ["new"])

    let regression = comparison.regressions[0]
    XCTAssertEqual(regression.model, "m")
    XCTAssertEqual(regression.dialect, "chat")
    XCTAssertEqual(regression.previousPassRate, 1.0)
    XCTAssertEqual(regression.previousTrials, 5)
    XCTAssertEqual(regression.currentPassRate, 0)
    XCTAssertEqual(regression.currentTrials, 1)
    let fix = comparison.fixes[0]
    XCTAssertEqual(fix.previousPassRate, 0)
    XCTAssertEqual(fix.currentPassRate, 1)
    let fresh = comparison.withoutBaseline[0]
    XCTAssertNil(fresh.previousPassRate)
    XCTAssertEqual(fresh.previousTrials, 0)
    XCTAssertEqual(fresh.currentPassRate, 1)
  }

  func testCompareKeysOnModelAndDialectAndSuite() {
    // A perfect history under another model, dialect or suite is nobody's baseline.
    let history = history(task: "t", passes: [true, true, true], model: "other")
      + [row(task: "t", passed: true, dialect: "messages", at: t0.addingTimeInterval(-day))]
      + [row(task: "t", passed: true, suite: "elsewhere", at: t0.addingTimeInterval(-day))]
    let comparison = EvalReport.compare(
      history: history, current: [row(task: "t", passed: false)], window: .last(rows: 5))
    XCTAssertTrue(comparison.regressions.isEmpty)
    XCTAssertEqual(comparison.withoutBaseline.map(\.taskId), ["t"])
  }

  func testLastWindowKeepsTheNewestRowsOnly() {
    // Seven rows: the five newest pass, the two oldest fail — `.last(rows: 5)` sees 5/5.
    let older = history(task: "t", passes: [false, false], daysAgo: 30)
    let newer = history(task: "t", passes: [true, true, true, true, true], daysAgo: 1)
    let comparison = EvalReport.compare(
      history: older + newer, current: [row(task: "t", passed: false)], window: .last(rows: 5))
    XCTAssertEqual(comparison.regressions.count, 1)
    XCTAssertEqual(comparison.regressions[0].previousTrials, 5)
    XCTAssertEqual(comparison.regressions[0].previousPassRate, 1.0)
    // All seven: 5/7 = 0.71 is under the regression floor → neither.
    let wide = EvalReport.compare(
      history: older + newer, current: [row(task: "t", passed: false)], window: .last(rows: 10))
    XCTAssertTrue(wide.regressions.isEmpty)
    XCTAssertTrue(wide.withoutBaseline.isEmpty)
  }

  func testDaysWindowExcludesOlderRowsMeasuredFromTheRunStart() {
    let old = history(task: "t", passes: [true, true, true], daysAgo: 10)
    let recent = history(task: "t", passes: [false], daysAgo: 1)
    // Within 7 days of the run: only the recent failure → 0/1 → the current pass is a fix.
    let comparison = EvalReport.compare(
      history: old + recent, current: [row(task: "t", passed: true)], window: .days(7))
    XCTAssertEqual(comparison.fixes.count, 1)
    XCTAssertEqual(comparison.fixes[0].previousTrials, 1)
    // A 30-day window sees all four: 3/4 → neither.
    let wide = EvalReport.compare(
      history: old + recent, current: [row(task: "t", passed: true)], window: .days(30))
    XCTAssertTrue(wide.fixes.isEmpty)
    XCTAssertTrue(wide.withoutBaseline.isEmpty)
    // Nothing in the window at all → listed as having no baseline.
    let none = EvalReport.compare(history: old, current: [row(task: "t", passed: true)], window: .days(7))
    XCTAssertEqual(none.withoutBaseline.count, 1)
  }

  func testCompareUsesTheCountedVerdictAndAveragesTheCurrentTrials() {
    // A graded row counts its graded verdict, not its check.
    var gradedMiss = row(task: "t", passed: true, at: t0.addingTimeInterval(-day))
    gradedMiss.passed = false
    let history = [gradedMiss, gradedMiss, gradedMiss, gradedMiss, gradedMiss]
    // Two current trials, one pass → 0.5: at the fix floor.
    let comparison = EvalReport.compare(
      history: history, current: [row(task: "t", trial: 1, passed: true), row(task: "t", trial: 2, passed: false)],
      window: .last(rows: 5))
    XCTAssertEqual(comparison.fixes.count, 1)
    XCTAssertEqual(comparison.fixes[0].currentPassRate, 0.5)
    XCTAssertEqual(comparison.fixes[0].currentTrials, 2)
  }

  // MARK: Gate

  func testGateTable() {
    let good = EvalReport.summaries([row(task: "a", model: "good", passed: true), row(task: "b", model: "good", passed: true)])
    let mixed = EvalReport.summaries([row(task: "a", model: "so-so", passed: true), row(task: "b", model: "so-so", passed: false)])
    let regression = EvalRegression(
      taskId: "t", model: "m", dialect: "chat", previousPassRate: 1, previousTrials: 5, currentPassRate: 0, currentTrials: 1)

    // No gate → 0 whatever happened.
    XCTAssertFalse(EvalGate().isSet)
    XCTAssertEqual(EvalGate().exitCode(summaries: mixed, regressions: [regression]), 0)
    // Min pass met → 0; one model under → 2.
    XCTAssertEqual(EvalGate(minPass: 1.0).exitCode(summaries: good, regressions: []), 0)
    XCTAssertEqual(EvalGate(minPass: 0.5).exitCode(summaries: good + mixed, regressions: []), 0)
    XCTAssertEqual(EvalGate(minPass: 1.0).exitCode(summaries: good + mixed, regressions: []), 2)
    XCTAssertEqual(EvalGate(minPass: 0.75).exitCode(summaries: mixed, regressions: []), 2)
    // A regression fails only with the flag.
    XCTAssertEqual(EvalGate(minPass: 0.5).exitCode(summaries: mixed, regressions: [regression]), 0)
    XCTAssertEqual(EvalGate(failOnRegression: true).exitCode(summaries: mixed, regressions: [regression]), 2)
    XCTAssertEqual(EvalGate(failOnRegression: true).exitCode(summaries: mixed, regressions: []), 0)
    XCTAssertTrue(EvalGate(failOnRegression: true).passes(summaries: [], regressions: []))
    XCTAssertEqual(EvalGate.failedExitCode, 2)
  }
}
