import Foundation

// MARK: - EvalModelSummary

/// One run's outcomes for one model × dialect, summarized (X5): the scoreboard row's figures
/// plus the per-task counts pass@k and pass^k are computed from. Pure data over
/// `EvalOutcome`s — `EvalReport.summaries` builds it.
public struct EvalModelSummary: Sendable, Equatable {
  public var model: String
  /// The wire dialect the rows executed with; nil for rows written before dialects were
  /// recorded. A model that fell back mid-run has one summary per dialect.
  public var dialect: String?
  /// Rows, and rows whose counted verdict (`EvalOutcome.isPass`) is a pass.
  public var trials: Int
  public var passed: Int
  /// Distinct task ids in the group.
  public var tasks: Int
  /// Tasks with at least one passing trial — the pass@k numerator.
  public var tasksWithAnyPass: Int
  /// Tasks whose every trial passed — the pass^k numerator.
  public var tasksWithAllPass: Int
  /// The `k`: trials per task, the largest number of rows any one task has in the group (every
  /// task has the same count in a single run). pass@k / pass^k are meaningless at 1.
  public var trialsPerTask: Int
  /// The candidate's spend, and the rubric judge's (kept apart, as on the rows).
  public var costUSD: Double
  public var graderCostUSD: Double
  public var avgSteps: Double
  public var avgSeconds: Double
  /// Rows that carry an `error` (timeout, thrown run, setup failure…).
  public var errors: Int
  /// Rows a decisions judge (jev) graded — a `jev` block or the rubric bridge.
  public var jevGraded: Int
  /// Mean of the rows' `jevVariance` (the per-repeat score variance); nil when no row was
  /// judged more than once.
  public var avgJevVariance: Double?

  public var passRate: Double { trials == 0 ? 0 : Double(passed) / Double(trials) }

  public init(
    model: String,
    dialect: String?,
    trials: Int,
    passed: Int,
    tasks: Int,
    tasksWithAnyPass: Int,
    tasksWithAllPass: Int,
    trialsPerTask: Int,
    costUSD: Double,
    graderCostUSD: Double,
    avgSteps: Double,
    avgSeconds: Double,
    errors: Int,
    jevGraded: Int = 0,
    avgJevVariance: Double? = nil)
  {
    self.model = model
    self.dialect = dialect
    self.trials = trials
    self.passed = passed
    self.tasks = tasks
    self.tasksWithAnyPass = tasksWithAnyPass
    self.tasksWithAllPass = tasksWithAllPass
    self.trialsPerTask = trialsPerTask
    self.costUSD = costUSD
    self.graderCostUSD = graderCostUSD
    self.avgSteps = avgSteps
    self.avgSeconds = avgSeconds
    self.errors = errors
    self.jevGraded = jevGraded
    self.avgJevVariance = avgJevVariance
  }
}

// MARK: - EvalRegression

/// One task × model × dialect of a run set against its baseline: the pass rate over the
/// baseline window and the pass rate now. The type carries a regression, a fix, and — with
/// `previousPassRate` nil — a key the window held no row for (neither, `n/a`).
public struct EvalRegression: Sendable, Equatable {
  public var taskId: String
  public var model: String
  public var dialect: String?
  /// Passes over rows in the baseline window; nil when the window held no row for this key
  /// (`previousTrials == 0`).
  public var previousPassRate: Double?
  public var previousTrials: Int
  public var currentPassRate: Double
  public var currentTrials: Int

  public init(
    taskId: String,
    model: String,
    dialect: String?,
    previousPassRate: Double?,
    previousTrials: Int,
    currentPassRate: Double,
    currentTrials: Int)
  {
    self.taskId = taskId
    self.model = model
    self.dialect = dialect
    self.previousPassRate = previousPassRate
    self.previousTrials = previousTrials
    self.currentPassRate = currentPassRate
    self.currentTrials = currentTrials
  }
}

/// What `EvalReport.compare` found: the keys that regressed, the ones that were fixed, and
/// the ones with nothing to compare against (a new task, a fresh history).
public struct EvalComparison: Sendable, Equatable {
  public var regressions: [EvalRegression]
  public var fixes: [EvalRegression]
  /// This run's keys with no baseline row inside the window — neither a regression nor a fix;
  /// the compare block prints them as `n/a`.
  public var withoutBaseline: [EvalRegression]

  public init(regressions: [EvalRegression], fixes: [EvalRegression], withoutBaseline: [EvalRegression]) {
    self.regressions = regressions
    self.fixes = fixes
    self.withoutBaseline = withoutBaseline
  }
}

// MARK: - EvalReport

/// Pure functions over eval outcomes (X5): per-model summaries with pass@k / pass^k, and a
/// comparison of a run against the history that preceded it. Nothing here reads a file or a
/// clock — the CLI passes the rows it read before the run and the rows the run produced.
public enum EvalReport {
  /// How much history a comparison reads per (suite, task, model, dialect) key.
  public enum Window: Sendable, Equatable {
    /// The newest `rows` rows of the key (the default baseline: `last` = 5).
    case last(rows: Int)
    /// The rows within this many days before the compared run started.
    case days(Int)

    public static let defaultLastRows = 5
  }

  /// A key's previous pass rate at or above this, and a current one below `regressionCeiling`,
  /// is a regression.
  public static let regressionFloor = 0.8
  public static let regressionCeiling = 0.5
  /// A key's previous pass rate at or below this, and a current one at or above `fixFloor`, is
  /// a fix.
  public static let fixCeiling = 0.2
  public static let fixFloor = 0.5

  /// One summary per model × dialect, ordered like `EvalStats.aggregate` — pass rate down,
  /// then cost up — with model and dialect as tie-breakers so the order is total.
  public static func summaries(_ outcomes: [EvalOutcome]) -> [EvalModelSummary] {
    struct Key: Hashable {
      let model: String
      let dialect: String?
    }
    let grouped = Dictionary(grouping: outcomes) { Key(model: $0.model, dialect: $0.dialect) }
    return grouped.map { key, rows in
      let byTask = Dictionary(grouping: rows, by: \.taskId)
      let count = Double(rows.count)
      return EvalModelSummary(
        model: key.model,
        dialect: key.dialect,
        trials: rows.count,
        passed: rows.filter(\.isPass).count,
        tasks: byTask.count,
        tasksWithAnyPass: byTask.values.filter { $0.contains(where: \.isPass) }.count,
        tasksWithAllPass: byTask.values.filter { $0.allSatisfy(\.isPass) }.count,
        trialsPerTask: byTask.values.map(\.count).max() ?? 0,
        costUSD: rows.reduce(0) { $0 + $1.costUSD },
        graderCostUSD: rows.reduce(0) { $0 + ($1.graderCostUSD ?? 0) },
        avgSteps: count == 0 ? 0 : Double(rows.reduce(0) { $0 + $1.steps }) / count,
        avgSeconds: count == 0 ? 0 : rows.reduce(0) { $0 + $1.durationSeconds } / count,
        errors: rows.filter { $0.error != nil }.count,
        jevGraded: rows.filter { $0.jevScore != nil || $0.jevQuestions != nil }.count,
        avgJevVariance: {
          let variances = rows.compactMap(\.jevVariance)
          return variances.isEmpty ? nil : variances.reduce(0, +) / Double(variances.count)
        }())
    }
    .sorted {
      if $0.passRate != $1.passRate { return $0.passRate > $1.passRate }
      if $0.costUSD != $1.costUSD { return $0.costUSD < $1.costUSD }
      if $0.model != $1.model { return $0.model < $1.model }
      return ($0.dialect ?? "") < ($1.dialect ?? "")
    }
  }

  /// pass@k — the share of tasks with at least one passing trial. nil for a single trial per
  /// task (where it would just repeat the pass rate) or with no tasks.
  public static func passAtK(_ summary: EvalModelSummary) -> Double? {
    guard summary.trialsPerTask > 1, summary.tasks > 0 else { return nil }
    return Double(summary.tasksWithAnyPass) / Double(summary.tasks)
  }

  /// pass^k — the share of tasks whose every trial passed (the reliability figure). nil on the
  /// same terms as `passAtK`.
  public static func passPowK(_ summary: EvalModelSummary) -> Double? {
    guard summary.trialsPerTask > 1, summary.tasks > 0 else { return nil }
    return Double(summary.tasksWithAllPass) / Double(summary.tasks)
  }

  /// Sets a run (`current`) against the rows that preceded it (`history` — the caller passes
  /// the store's rows from before the run), per (suite, task, model, dialect) key. The
  /// baseline is the window's rows for the key: the newest `rows` of them (`.last`) or those
  /// within `days` before the run started (`.days`, measured from the earliest `startedAt` in
  /// `current`). A regression is `previous ≥ 0.8 → current < 0.5`, a fix `previous ≤ 0.2 →
  /// current ≥ 0.5`; a key the window holds nothing for is neither and is listed apart.
  /// Every list is ordered by task, model, dialect.
  public static func compare(
    history: [EvalOutcome],
    current: [EvalOutcome],
    window: Window)
    -> EvalComparison
  {
    struct Key: Hashable, Comparable {
      let suite: String
      let taskId: String
      let model: String
      let dialect: String?

      static func < (lhs: Key, rhs: Key) -> Bool {
        if lhs.taskId != rhs.taskId { return lhs.taskId < rhs.taskId }
        if lhs.model != rhs.model { return lhs.model < rhs.model }
        if lhs.suite != rhs.suite { return lhs.suite < rhs.suite }
        return (lhs.dialect ?? "") < (rhs.dialect ?? "")
      }
    }
    func key(_ row: EvalOutcome) -> Key {
      Key(suite: row.suite, taskId: row.taskId, model: row.model, dialect: row.dialect)
    }
    func passRate(_ rows: [EvalOutcome]) -> Double {
      rows.isEmpty ? 0 : Double(rows.filter(\.isPass).count) / Double(rows.count)
    }
    let runStart = current.map(\.startedAt).min() ?? Date()
    let baselines = Dictionary(grouping: history, by: key)
    var comparison = EvalComparison(regressions: [], fixes: [], withoutBaseline: [])
    for (key, rows) in Dictionary(grouping: current, by: key).sorted(by: { $0.key < $1.key }) {
      let baseline: [EvalOutcome]
      switch window {
      case .last(let count):
        baseline = Array(
          (baselines[key] ?? []).sorted { $0.startedAt > $1.startedAt }.prefix(max(0, count)))
      case .days(let days):
        let cutoff = runStart.addingTimeInterval(-Double(max(0, days)) * 86_400)
        baseline = (baselines[key] ?? []).filter { $0.startedAt >= cutoff && $0.startedAt < runStart }
      }
      let now = passRate(rows)
      var entry = EvalRegression(
        taskId: key.taskId, model: key.model, dialect: key.dialect,
        previousPassRate: nil, previousTrials: baseline.count,
        currentPassRate: now, currentTrials: rows.count)
      guard !baseline.isEmpty else {
        comparison.withoutBaseline.append(entry)
        continue
      }
      let previous = passRate(baseline)
      entry.previousPassRate = previous
      if previous >= regressionFloor, now < regressionCeiling {
        comparison.regressions.append(entry)
      } else if previous <= fixCeiling, now >= fixFloor {
        comparison.fixes.append(entry)
      }
    }
    return comparison
  }
}

// MARK: - EvalGate

/// The CI gate over a run (X5): a minimum pass rate every model must reach and/or "no
/// regression against the baseline". `exitCode` is 0 or 2 — 2 being the code `--verify FAIL`
/// and `review --fail-on` already use for "the judge said no".
public struct EvalGate: Sendable, Equatable {
  /// Every model's (× dialect) pass rate must be at least this; nil = no minimum.
  public var minPass: Double?
  /// Any regression the comparison found fails the gate.
  public var failOnRegression: Bool

  public static let failedExitCode: Int32 = 2

  public init(minPass: Double? = nil, failOnRegression: Bool = false) {
    self.minPass = minPass
    self.failOnRegression = failOnRegression
  }

  /// Whether the gate is set at all (a run without one always passes).
  public var isSet: Bool { minPass != nil || failOnRegression }

  /// `false` when any summary is under `minPass`, or when `failOnRegression` and `regressions`
  /// is non-empty.
  public func passes(summaries: [EvalModelSummary], regressions: [EvalRegression]) -> Bool {
    if let minPass, summaries.contains(where: { $0.passRate < minPass }) { return false }
    if failOnRegression, !regressions.isEmpty { return false }
    return true
  }

  /// 0 when the gate passes, 2 when it fails.
  public func exitCode(summaries: [EvalModelSummary], regressions: [EvalRegression]) -> Int32 {
    passes(summaries: summaries, regressions: regressions) ? 0 : Self.failedExitCode
  }
}

// MARK: - JudgeAlignment

/// One suite × judge-pair of rows both judges graded (`arnes eval --second-judge`):
/// how often the verdicts agree, and how far the scores sit apart.
public struct JudgeAlignmentRow: Sendable, Equatable {
  public var suite: String
  /// The primary judge (`EvalOutcome.judgeModel`).
  public var judge: String
  public var secondJudge: String
  /// Rows carrying both verdicts.
  public var trials: Int
  /// Rows where neither verdict is unknown — the agreement denominator.
  public var decided: Int
  /// Decided rows where both said pass or both said fail.
  public var agreements: Int
  /// Mean |primary score − second score| over decided rows.
  public var meanAbsScoreDelta: Double?
  public var primaryUnknowns: Int
  public var secondUnknowns: Int
  /// Mean of the rows' `jevVariance`, where recorded (a decisions judge under repeats).
  public var meanJevVariance: Double?

  public var agreementRate: Double? {
    decided == 0 ? nil : Double(agreements) / Double(decided)
  }

  public init(
    suite: String,
    judge: String,
    secondJudge: String,
    trials: Int,
    decided: Int,
    agreements: Int,
    meanAbsScoreDelta: Double?,
    primaryUnknowns: Int,
    secondUnknowns: Int,
    meanJevVariance: Double?)
  {
    self.suite = suite
    self.judge = judge
    self.secondJudge = secondJudge
    self.trials = trials
    self.decided = decided
    self.agreements = agreements
    self.meanAbsScoreDelta = meanAbsScoreDelta
    self.primaryUnknowns = primaryUnknowns
    self.secondUnknowns = secondUnknowns
    self.meanJevVariance = meanJevVariance
  }
}

/// Pure aggregation of dual-judged rows — what `arnes evals judges` prints over the history
/// and `arnes eval --second-judge` prints over a run. Nothing here reads a file or a clock.
public enum JudgeAlignment {
  /// One row per suite × (judge, second judge) pair, over the rows that carry both a rubric
  /// verdict and a second one. Ordered by suite, then judge, then second judge.
  public static func compute(_ rows: [EvalOutcome]) -> [JudgeAlignmentRow] {
    struct Key: Hashable, Comparable {
      let suite: String
      let judge: String
      let second: String

      static func < (lhs: Key, rhs: Key) -> Bool {
        if lhs.suite != rhs.suite { return lhs.suite < rhs.suite }
        if lhs.judge != rhs.judge { return lhs.judge < rhs.judge }
        return lhs.second < rhs.second
      }
    }
    let paired = rows.filter {
      $0.judgeModel != nil && $0.secondJudgeModel != nil
        && $0.rubricPassed != nil && $0.secondRubricPassed != nil
    }
    let grouped = Dictionary(grouping: paired) {
      Key(suite: $0.suite, judge: $0.judgeModel ?? "", second: $0.secondJudgeModel ?? "")
    }
    return grouped.sorted { $0.key < $1.key }.map { key, group in
      let decided = group.filter { $0.rubricUnknown != true && $0.secondRubricUnknown != true }
      let deltas = decided.compactMap { row -> Double? in
        guard let primary = row.rubricScore, let second = row.secondRubricScore else { return nil }
        return abs(primary - second)
      }
      let variances = group.compactMap(\.jevVariance)
      return JudgeAlignmentRow(
        suite: key.suite,
        judge: key.judge,
        secondJudge: key.second,
        trials: group.count,
        decided: decided.count,
        agreements: decided.filter { $0.rubricPassed == $0.secondRubricPassed }.count,
        meanAbsScoreDelta: deltas.isEmpty ? nil : deltas.reduce(0, +) / Double(deltas.count),
        primaryUnknowns: group.filter { $0.rubricUnknown == true }.count,
        secondUnknowns: group.filter { $0.secondRubricUnknown == true }.count,
        meanJevVariance: variances.isEmpty ? nil : variances.reduce(0, +) / Double(variances.count))
    }
  }
}
