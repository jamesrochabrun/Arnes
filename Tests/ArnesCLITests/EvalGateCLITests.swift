import ArgumentParser
import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// X5 at the CLI: the `arnes eval` gate flags and their usage errors, the JSON documents'
/// documented keys (golden strings), the compare block and the pass@k lines, the text table's
/// byte-identity for a run without the new flags, and `evals show --json/--task`.
final class EvalGateCLITests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func outcome(
    task: String = "t", model: String = "test/model", trial: Int = 1, passed: Bool = true,
    dialect: String? = "chat", suite: String = "unit", cost: Double = 0.0123, steps: Int = 3,
    seconds: Double = 4.26, error: String? = nil, at: Date? = nil)
    -> EvalOutcome
  {
    EvalOutcome(
      suite: suite, taskId: task, model: model, trial: trial, checkPassed: passed, agentFinished: error == nil,
      steps: steps, toolCalls: 2, costUSD: cost, durationSeconds: seconds, startedAt: at ?? t0,
      routedModels: [], error: error, dialect: dialect, sandboxed: true, sessionId: "S-\(task)-\(trial)",
      runId: "R-\(task)-\(trial)", stopReason: error == nil ? "completed" : "error")
  }

  // MARK: Flags

  func testGateFlagsParseWithDefaults() throws {
    let plain = try Eval.parse(["evals/basics"])
    XCTAssertEqual(plain.parallel, 1)
    XCTAssertNil(plain.minPass)
    XCTAssertNil(plain.compare)
    XCTAssertFalse(plain.failOnRegression)
    XCTAssertFalse(plain.json)
    XCTAssertNil(plain.effort)
    XCTAssertNil(plain.budget)

    let gated = try Eval.parse([
      "evals/basics", "-m", "test/model", "--parallel", "4", "--min-pass", "1.0", "--compare", "7d",
      "--fail-on-regression", "--json", "--effort", "medium", "--budget", "0.05",
    ])
    XCTAssertEqual(gated.parallel, 4)
    XCTAssertEqual(gated.minPass, 1.0)
    XCTAssertEqual(gated.compare, "7d")
    XCTAssertTrue(gated.failOnRegression)
    XCTAssertTrue(gated.json)
    XCTAssertEqual(gated.effort, "medium")
    XCTAssertEqual(gated.budget, 0.05)
    XCTAssertEqual(try Eval.parseCompare("last"), .last(rows: 5))
    XCTAssertEqual(try Eval.parseCompare(" 7D "), .days(7))
    XCTAssertNil(try Eval.parseCompare(nil))
  }

  func testGateFlagUsageErrors() {
    func refused(_ arguments: [String], _ fragment: String, line: UInt = #line) {
      XCTAssertThrowsError(try Eval.parse(arguments), "\(arguments) must be refused", line: line) { error in
        let message = Eval.message(for: error)
        XCTAssertTrue(message.contains(fragment), "\(arguments): \(message)", line: line)
      }
    }
    refused(["evals/basics", "--parallel", "0"], "--parallel must be at least 1")
    refused(["evals/basics", "--compare", "weekly"], "unknown --compare 'weekly'")
    refused(["evals/basics", "--compare", "0d"], "unknown --compare")
    refused(["evals/basics", "--fail-on-regression"], "--fail-on-regression needs a baseline")
    refused(["evals/basics", "--min-pass", "1.5"], "--min-pass must be a fraction between 0 and 1")
    refused(["evals/basics", "--effort", "turbo"], "unknown effort 'turbo'")
    refused(["evals/basics", "--budget", "0"], "--budget must be a positive number")
    refused(["evals/basics", "--dialect", "smoke"], "unknown dialect 'smoke'")
  }

  func testEvalsShowFlagsParse() throws {
    let show = try EvalsShow.parse(["--json", "--task", "x"])
    XCTAssertTrue(show.json)
    XCTAssertEqual(show.task, "x")
    let plain = try EvalsShow.parse([])
    XCTAssertFalse(plain.json)
    XCTAssertNil(plain.task)
    let viaParent = try Evals.parseAsRoot(["show", "--task", "fix-bug", "--json"]) as? EvalsShow
    XCTAssertEqual(viaParent?.task, "fix-bug")
    XCTAssertEqual(viaParent?.json, true)
  }

  // MARK: Table

  /// The pre-X5 table, reproduced: a run without the new flags (and one trial per task) must
  /// render exactly this.
  private func legacyTable(_ stats: [EvalStats]) -> String {
    var lines = [
      "model                                     pass        cost      steps    time   errors",
      String(repeating: "─", count: 88),
    ]
    for row in stats {
      let model = row.model.padding(toLength: 40, withPad: " ", startingAt: 0)
      let pass = "\(row.passed)/\(row.trials) (\(Int(row.passRate * 100))%)"
        .padding(toLength: 12, withPad: " ", startingAt: 0)
      let cost = String(format: "$%.4f", row.totalCostUSD)
        .padding(toLength: 10, withPad: " ", startingAt: 0)
      let steps = String(format: "%.1f", row.averageSteps)
        .padding(toLength: 7, withPad: " ", startingAt: 0)
      let time = String(format: "%.1fs", row.averageDurationSeconds)
        .padding(toLength: 7, withPad: " ", startingAt: 0)
      lines.append("\(model)  \(pass)\(cost)\(steps)\(time)\(row.errors)")
    }
    return lines.joined(separator: "\n")
  }

  func testStatsTableIsByteIdenticalWithoutTheNewFlags() {
    let outcomes = [
      outcome(task: "a", model: "b/model", passed: true),
      outcome(task: "b", model: "b/model", passed: false, error: "timeout after 300s"),
      outcome(task: "a", model: "a/model", passed: true, cost: 0.5),
    ]
    let stats = EvalStats.aggregate(outcomes)
    let summaries = EvalReport.summaries(outcomes)
    XCTAssertEqual(Eval.renderStats(stats, taskCount: 2, trials: 1), legacyTable(stats))
    // One trial per task: the summaries add no line.
    XCTAssertEqual(Eval.renderStats(stats, summaries: summaries, taskCount: 2, trials: 1), legacyTable(stats))
    XCTAssertTrue(Eval.passAtKLines(for: "b/model", summaries: summaries).isEmpty)
  }

  func testPassAtKLinesAppearUnderAModelRowOnlyForSeveralTrials() {
    let outcomes = [
      outcome(task: "a", trial: 1, passed: true), outcome(task: "a", trial: 2, passed: true), outcome(task: "a", trial: 3, passed: true),
      outcome(task: "b", trial: 1, passed: false), outcome(task: "b", trial: 2, passed: true), outcome(task: "b", trial: 3, passed: false),
    ]
    let stats = EvalStats.aggregate(outcomes)
    let summaries = EvalReport.summaries(outcomes)
    XCTAssertEqual(Eval.passAtKLines(for: "test/model", summaries: summaries), ["  pass@3 2/2 · pass^3 1/2"])
    let table = Eval.renderStats(stats, summaries: summaries, taskCount: 2, trials: 3)
    let lines = table.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 4)
    XCTAssertTrue(lines[2].hasPrefix("test/model"), lines[2])
    XCTAssertEqual(lines[3], "  pass@3 2/2 · pass^3 1/2")
    // A model split across two dialects gets one tagged line per dialect.
    let split = EvalReport.summaries(outcomes + [
      outcome(task: "a", trial: 1, passed: true, dialect: "messages"), outcome(task: "a", trial: 2, passed: false, dialect: "messages"),
    ])
    XCTAssertEqual(Set(Eval.passAtKLines(for: "test/model", summaries: split)),
                   ["  pass@3 2/2 · pass^3 1/2 · chat", "  pass@2 1/1 · pass^2 0/1 · messages"])
  }

  // MARK: Compare block and gate line

  func testCompareLinesAndGateLine() {
    let history = (1...5).map { outcome(task: "reg", trial: $0, passed: true, at: t0.addingTimeInterval(-86_400)) }
      + (1...5).map { outcome(task: "fix", trial: $0, passed: false, at: t0.addingTimeInterval(-86_400)) }
    let current = [
      outcome(task: "reg", passed: false), outcome(task: "fix", passed: true), outcome(task: "new", passed: true),
    ]
    let comparison = EvalReport.compare(history: history, current: current, window: .last(rows: 5))
    XCTAssertEqual(Eval.compareLines(comparison, window: .last(rows: 5)), [
      "compare against the newest 5 row(s) per task:",
      "regressions:",
      "  reg · test/model · chat: 100% → 0%",
      "fixes:",
      "  fix · test/model · chat: 0% → 100%",
      "no baseline in the window:",
      "  new · test/model · chat: n/a → 100%",
    ])
    let empty = EvalReport.compare(history: [], current: [], window: .days(7))
    XCTAssertEqual(Eval.compareLines(empty, window: .days(7)), [
      "compare against the 7 day(s) before this run:",
      "regressions:",
      "  (none)",
      "fixes:",
      "  (none)",
    ])
    let gate = EvalGate(minPass: 0.9, failOnRegression: true)
    XCTAssertEqual(Eval.gateLine(gate, passed: true), "gate passed (min pass 90%, no regression)")
    XCTAssertEqual(Eval.gateLine(EvalGate(minPass: 1.0), passed: false), "gate FAILED (min pass 100%) — exit 2")
    XCTAssertEqual(Eval.gateLine(EvalGate(failOnRegression: true), passed: false), "gate FAILED (no regression) — exit 2")
  }

  // MARK: JSON documents

  func testEvalReportDocumentKeysAndNulls() throws {
    let outcomes = [outcome(task: "a", passed: true), outcome(task: "b", passed: false, dialect: nil, error: "timeout after 300s")]
    let summaries = EvalReport.summaries(outcomes)
    XCTAssertEqual(summaries.count, 2, "a nil dialect is its own group")
    // Uncompared, ungated: the compare keys are null, pass_at_k is null for one trial per task.
    let document = EvalReportDocument(
      suite: "unit", outcomes: outcomes, summaries: summaries, comparison: nil, compare: nil,
      gate: EvalGate(), exitCode: 0)
    let line = try JSONOut.line(document)
    XCTAssertEqual(
      line,
      #"{"collapsed_models":[],"compare":null,"exit_code":0,"fixes":null,"gate":{"fail_on_regression":false,"min_pass":null,"passed":true},"models":[{"avg_seconds":4.26,"avg_steps":3,"cost_usd":0.0123,"dialect":"chat","errors":0,"grader_cost_usd":0,"k":1,"model":"test/model","pass_at_k":null,"pass_pow_k":null,"pass_rate":1,"passed":1,"trials":1},{"avg_seconds":4.26,"avg_steps":3,"cost_usd":0.0123,"dialect":null,"errors":1,"grader_cost_usd":0,"k":1,"model":"test/model","pass_at_k":null,"pass_pow_k":null,"pass_rate":0,"passed":0,"trials":1}],"no_baseline":null,"outcomes":[{"check_passed":true,"cost_usd":0.0123,"dialect":"chat","error":null,"grader_cost_usd":null,"label":null,"limits_passed":null,"model":"test/model","passed":true,"rubric_passed":null,"rubric_score":null,"run_id":"R-a-1","sandboxed":true,"seconds":4.26,"session_id":"S-a-1","started_at":"2023-11-14T22:13:20Z","steps":3,"stop_reason":"completed","suite":"unit","task":"a","tool_calls":2,"trial":1,"verifier_passed":null},{"check_passed":false,"cost_usd":0.0123,"dialect":null,"error":"timeout after 300s","grader_cost_usd":null,"label":null,"limits_passed":null,"model":"test/model","passed":false,"rubric_passed":null,"rubric_score":null,"run_id":"R-b-1","sandboxed":true,"seconds":4.26,"session_id":"S-b-1","started_at":"2023-11-14T22:13:20Z","steps":3,"stop_reason":"error","suite":"unit","task":"b","tool_calls":2,"trial":1,"verifier_passed":null}],"regressions":null,"suite":"unit","type":"eval"}"#)
  }

  func testEvalReportDocumentCarriesTheComparisonAndTheGate() throws {
    let outcomes = [
      outcome(task: "a", trial: 1, passed: true), outcome(task: "a", trial: 2, passed: false),
      outcome(task: "b", trial: 1, passed: true), outcome(task: "b", trial: 2, passed: true),
    ]
    let history = (1...5).map { outcome(task: "a", trial: $0, passed: true, at: t0.addingTimeInterval(-3_600)) }
    let summaries = EvalReport.summaries(outcomes)
    let comparison = EvalReport.compare(history: history, current: outcomes, window: .last(rows: 5))
    XCTAssertEqual(comparison.regressions.count, 0, "1/2 is at the ceiling boundary: 0.5 is not < 0.5")
    let gate = EvalGate(minPass: 1.0, failOnRegression: true)
    let exitCode = gate.exitCode(summaries: summaries, regressions: comparison.regressions)
    XCTAssertEqual(exitCode, 2, "3/4 is under the minimum")
    let document = EvalReportDocument(
      suite: "unit", outcomes: outcomes, summaries: summaries, comparison: comparison, compare: "last",
      gate: gate, exitCode: exitCode)
    let line = try JSONOut.line(document)
    XCTAssertTrue(line.contains(#""compare":"last""#), line)
    XCTAssertTrue(line.contains(#""exit_code":2"#), line)
    XCTAssertTrue(line.contains(#""gate":{"fail_on_regression":true,"min_pass":1,"passed":false}"#), line)
    XCTAssertTrue(line.contains(#""k":2,"model":"test/model","pass_at_k":1,"pass_pow_k":0.5,"pass_rate":0.75,"passed":3,"trials":4"#), line)
    XCTAssertTrue(line.contains(#""regressions":[]"#), line)
    XCTAssertTrue(line.contains(#""fixes":[]"#), line)
    XCTAssertTrue(line.contains(#""no_baseline":[{"current_pass_rate":1,"current_trials":2,"dialect":"chat","model":"test/model","previous_pass_rate":null,"previous_trials":0,"task":"b"}]"#), line)
    // A regression row spells every key.
    let regressed = EvalReport.compare(
      history: history, current: [outcome(task: "a", passed: false)], window: .last(rows: 5))
    XCTAssertEqual(
      try JSONOut.line(regressed.regressions.map(EvalRegressionRow.init)),
      #"[{"current_pass_rate":0,"current_trials":1,"dialect":"chat","model":"test/model","previous_pass_rate":1,"previous_trials":5,"task":"a"}]"#)
  }

  func testEvalsShowJSONRowsGroupLikeTheTableAndSpellTheKeys() throws {
    let rows = EvalsShow.jsonRows([
      outcome(task: "a", model: "b/model", passed: true, suite: "basics", cost: 0.25, at: t0),
      outcome(task: "b", model: "b/model", passed: false, suite: "basics", cost: 0.5, at: t0.addingTimeInterval(60)),
      outcome(task: "a", model: "a/model", passed: true, suite: "basics", cost: 0.5),
      outcome(task: "a", model: "z/model", passed: true, dialect: nil, suite: "alpha"),
    ])
    // Suite up, pass rate down, model up.
    XCTAssertEqual(rows.map { "\($0.suite)/\($0.model)" }, ["alpha/z/model", "basics/a/model", "basics/b/model"])
    XCTAssertEqual(
      try JSONOut.line(EvalsDocument(rows: [rows[2]])),
      #"{"rows":[{"cost_usd":0.75,"dialect":"chat","last_run":"2023-11-14T22:14:20Z","model":"b/model","pass_rate":0.5,"passed":1,"suite":"basics","trials":2,"verifier_agreement":null,"verifier_agreements":0,"verifier_verdicts":0}],"type":"evals"}"#)
    XCTAssertNil(rows[0].dialect)
    XCTAssertEqual(try JSONOut.line(EvalsDocument(rows: [])), #"{"rows":[],"type":"evals"}"#)
  }

  func testEvalsShowJSONCarriesVerifierAgreement() throws {
    // Two rows carry a verdict (one agrees with the check, one disagrees), one has none.
    func row(check: Bool, verifier: Bool?) -> EvalOutcome {
      EvalOutcome(
        suite: "basics", taskId: "t", model: "m", trial: 1, checkPassed: check,
        agentFinished: true, steps: 1, toolCalls: 0, costUSD: 0, durationSeconds: 0,
        startedAt: t0, routedModels: [], verifierPassed: verifier)
    }
    let rows = EvalsShow.jsonRows([
      row(check: true, verifier: true),   // agrees
      row(check: true, verifier: false),  // disagrees
      row(check: false, verifier: nil),   // no verdict
    ])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].verifierVerdicts, 2)
    XCTAssertEqual(rows[0].verifierAgreements, 1)
    XCTAssertEqual(rows[0].verifierAgreement, 0.5)
  }
}
