import Foundation
import OpenRouterSwift

// MARK: - JevResult

/// What the jev (decisions) judge came back with for one trial, folded across its repeats,
/// with its spend.
public struct JevResult: Sendable {
  /// One question as the fold read it across the repeats.
  public struct Question: Sendable, Equatable {
    public let name: String
    public let kind: DecisionQuestion.Kind
    /// The mean answer: noul — mean P(yes); score — mean expected level; choice — mean
    /// probability of the target key (the expected one, else the modal pick).
    public let mean: Double
    /// Unbiased sample variance of the answer across repeats; nil when judged once.
    public let variance: Double?
    /// The expectation's verdict, checked against the mean; nil when the question declared
    /// none (recorded, never counted).
    public let passed: Bool?
    /// choice only: the modal picked key across repeats.
    public let choice: String?

    public init(
      name: String,
      kind: DecisionQuestion.Kind,
      mean: Double,
      variance: Double? = nil,
      passed: Bool? = nil,
      choice: String? = nil)
    {
      self.name = name
      self.kind = kind
      self.mean = mean
      self.variance = variance
      self.passed = passed
      self.choice = choice
    }
  }

  /// The fraction of expected questions whose expectation held, checked on the means.
  public let score: Double
  /// `score` at or above the threshold, and nothing unknown.
  public let passed: Bool
  /// The request failed, or an answer was missing or the wrong shape (`notes` says which).
  /// Never a pass.
  public let unknown: Bool
  public let notes: String
  public let questions: [Question]
  /// How many times the trial was judged.
  public let repeats: Int
  /// Sample variance of the per-repeat score — the repeatability signal. nil when judged once.
  public let scoreVariance: Double?
  /// The judge's spend over every repeat, booked complete or not.
  public let costUSD: Double
  public let promptTokens: Int?
  public let completionTokens: Int?

  public init(
    score: Double,
    passed: Bool,
    unknown: Bool,
    notes: String,
    questions: [Question],
    repeats: Int,
    scoreVariance: Double? = nil,
    costUSD: Double,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil)
  {
    self.score = score
    self.passed = passed
    self.unknown = unknown
    self.notes = notes
    self.questions = questions
    self.repeats = repeats
    self.scoreVariance = scoreVariance
    self.costUSD = costUSD
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
  }

  /// The verdict for a judge that could not judge: score 0, not passed, `unknown`, the spend
  /// (if any) still carried.
  public static func unknown(
    notes: String,
    costUSD: Double = 0,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil)
    -> JevResult
  {
    JevResult(
      score: 0, passed: false, unknown: true, notes: notes, questions: [], repeats: 0,
      costUSD: costUSD, promptTokens: promptTokens, completionTokens: completionTokens)
  }

  /// The per-question fold as outcome rows keep it.
  public var questionRecords: [JevQuestionRecord] {
    questions.map {
      JevQuestionRecord(
        name: $0.name, kind: $0.kind.rawValue, mean: $0.mean, variance: $0.variance,
        passed: $0.passed, choice: $0.choice)
    }
  }
}

// MARK: - JevJudge

/// The decisions grader: typed questions to a System One model (jev) over the same evidence
/// the rubric judge reads — the task, the agent's final report, the diff, and the check's
/// verdict. **Never the transcript**, for the same reason as `RubricJudge`: the report is a
/// claim; the diff and the check are the proof. Unlike the LLM judge there is no prompt, no
/// schema and no retry machinery — the wire is already typed, so a failed or malformed reply
/// is an `unknown` verdict, never a re-ask.
///
/// Repeats: the same state and questions are asked `repeats` times (1…9) and folded — per
/// question the repeat value xᵣ is P(yes) (noul), the expected level (score), or the
/// probability of the target key (choice; the expected key, else the modal pick). The mean
/// decides every expectation, so the verdict is deterministic given the answers; the
/// unbiased sample variance (n−1) of xᵣ — and of the per-repeat score — is the
/// repeatability signal the row records.
public enum JevJudge {
  /// The structured state jev reads — the rubric judge's evidence, as typed fields instead
  /// of prose. Same clip caps, and never the transcript. Pure, so a test can pin what does
  /// and does not reach the judge.
  public static func state(task: EvalTask, evidence: RubricJudge.Evidence) -> JSONValue {
    let diff = evidence.diff.isEmpty
      ? "(no changes to the working directory)"
      : WorkspaceSnapshot.clippedDiff(evidence.diff, maxChars: RubricJudge.maxDiffChars)
    return .object([
      "task": .string(task.prompt),
      "report": .string(evidence.report),
      "diff": .string(diff),
      "check_passed": .bool(evidence.checkPassed),
      "check_output": .string(String(evidence.checkOutput.prefix(RubricJudge.maxCheckOutputChars))),
    ])
  }

  /// A task's jev block as wire questions. Pure.
  public static func questions(from jev: EvalTask.Jev) -> [String: DecisionQuestion] {
    jev.questions.mapValues {
      DecisionQuestion(type: $0.type, instructions: $0.instructions, criteria: $0.criteria)
    }
  }

  /// The rubric bridge's questions: each non-blank criterion as one noul statement, keyed
  /// `c1`…`cN` in the rubric's order. Pure.
  public static func bridgedQuestions(criteria: [String]) -> [String: DecisionQuestion] {
    var questions: [String: DecisionQuestion] = [:]
    for (index, criterion) in bridgeableCriteria(criteria).enumerated() {
      questions["c\(index + 1)"] = .noul(criterion)
    }
    return questions
  }

  /// Grades one trial: `repeats` sequential decisions requests, folded. Any thrown request
  /// or missing answer is an `unknown` result with the spend so far — never a thrown trial.
  public static func grade(
    jev: EvalTask.Jev,
    task: EvalTask,
    evidence: RubricJudge.Evidence,
    model: String,
    repeats: Int,
    service: OpenRouterService)
    async -> JevResult
  {
    let request = DecisionRequest(
      model: model, state: state(task: task, evidence: evidence), questions: questions(from: jev))
    var responses: [DecisionResponse] = []
    for _ in 0..<max(1, repeats) {
      do {
        responses.append(try await service.decide(request))
      } catch {
        return .unknown(
          notes: "judge error: \(String("\(error)".prefix(300)))",
          costUSD: cost(of: responses))
      }
    }
    return fold(responses, jev: jev)
  }

  /// The rubric bridge: the criteria as noul questions on the same call path, folded into
  /// the existing rubric contract — criterion met ⇔ mean P(yes) ≥ `bridgeCut`, score = the
  /// fraction met, passed ⇔ score ≥ the rubric's threshold. The jev detail rides beside it
  /// for the row's audit fields.
  public static func gradeBridge(
    criteria: [String],
    threshold: Double,
    task: EvalTask,
    evidence: RubricJudge.Evidence,
    model: String,
    repeats: Int,
    service: OpenRouterService)
    async -> (rubric: RubricResult, detail: JevResult)
  {
    let usable = bridgeableCriteria(criteria)
    var questions: [String: EvalTask.Jev.Question] = [:]
    for (index, criterion) in usable.enumerated() {
      questions["c\(index + 1)"] = EvalTask.Jev.Question(
        type: .noul, instructions: criterion,
        expect: EvalTask.Jev.Expectation(min: bridgeCut))
    }
    let jev = EvalTask.Jev(questions: questions, threshold: threshold)
    let detail = await grade(
      jev: jev, task: task, evidence: evidence, model: model, repeats: repeats, service: service)
    if detail.unknown {
      return (RubricResult.unknown(
        notes: detail.notes, costUSD: detail.costUSD,
        promptTokens: detail.promptTokens, completionTokens: detail.completionTokens), detail)
    }
    let byName = Dictionary(uniqueKeysWithValues: detail.questions.map { ($0.name, $0) })
    let folded = usable.enumerated().map { index, criterion in
      RubricResult.Criterion(criterion: criterion, met: byName["c\(index + 1)"]?.passed ?? false)
    }
    let rubric = RubricResult(
      score: detail.score,
      passed: detail.passed,
      unknown: false,
      notes: detail.notes,
      criteria: folded,
      costUSD: detail.costUSD,
      promptTokens: detail.promptTokens,
      completionTokens: detail.completionTokens)
    return (rubric, detail)
  }

  /// A bridged criterion counts as met at or above this mean P(yes) — the midpoint, since a
  /// noul statement is the criterion verbatim. The per-question means stay on the row for
  /// audit either way.
  public static let bridgeCut = 0.5

  static func bridgeableCriteria(_ criteria: [String]) -> [String] {
    criteria.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }

  /// Responses → the result: means, variances, and the expectation table. Pure — what a
  /// test pins.
  static func fold(_ responses: [DecisionResponse], jev: EvalTask.Jev) -> JevResult {
    let repeats = responses.count
    guard repeats > 0 else { return .unknown(notes: "no responses") }
    let spend = cost(of: responses)
    let promptTokens = tokens(of: responses, \.inputTokens)
    let completionTokens = tokens(of: responses, \.outputTokens)

    var questions: [JevResult.Question] = []
    // Per repeat: how many expected questions held in that repeat alone — the per-repeat
    // score whose variance the row records.
    var expectedHeldPerRepeat = [Int](repeating: 0, count: repeats)
    var expectedCount = 0
    var misses: [String] = []

    for (name, question) in jev.questions.sorted(by: { $0.key < $1.key }) {
      let answers = responses.map { $0.answers[name] }
      guard !answers.contains(where: { $0 == nil }) else {
        return .unknown(notes: "no answer for '\(name)'", costUSD: spend,
                        promptTokens: promptTokens, completionTokens: completionTokens)
      }
      let present = answers.compactMap { $0 }

      var values: [Double] = []
      var picks: [String] = []
      switch question.type {
      case .noul:
        let nouls = present.compactMap(\.noul)
        guard nouls.count == repeats else {
          return .unknown(notes: "answer for '\(name)' has no noul value", costUSD: spend,
                          promptTokens: promptTokens, completionTokens: completionTokens)
        }
        values = nouls
      case .score:
        let scores = present.compactMap(\.score)
        guard scores.count == repeats else {
          return .unknown(notes: "answer for '\(name)' has no score value", costUSD: spend,
                          promptTokens: promptTokens, completionTokens: completionTokens)
        }
        values = scores
      case .choice:
        picks = present.compactMap { $0.choice ?? topKey(of: $0.probabilities) }
        guard picks.count == repeats else {
          return .unknown(notes: "answer for '\(name)' has no choice", costUSD: spend,
                          promptTokens: promptTokens, completionTokens: completionTokens)
        }
        guard let target = question.expect?.choice ?? modal(of: picks) else {
          return .unknown(notes: "answer for '\(name)' has no choice", costUSD: spend,
                          promptTokens: promptTokens, completionTokens: completionTokens)
        }
        values = present.enumerated().map { index, answer in
          answer.probabilities?[target] ?? (picks[index] == target ? 1 : 0)
        }
      }

      let mean = values.reduce(0, +) / Double(repeats)
      let modalPick = question.type == .choice ? modal(of: picks) : nil
      var passed: Bool?
      if let expect = question.expect {
        expectedCount += 1
        var held = within(mean, expect)
        if question.type == .choice, let expected = expect.choice {
          held = held && modalPick == expected
        }
        passed = held
        if !held {
          misses.append(miss(name: name, mean: mean, modal: modalPick, expect: expect))
        }
        for repeatIndex in 0..<repeats {
          var repeatHeld = within(values[repeatIndex], expect)
          if question.type == .choice, let expected = expect.choice {
            repeatHeld = repeatHeld && picks[repeatIndex] == expected
          }
          if repeatHeld { expectedHeldPerRepeat[repeatIndex] += 1 }
        }
      }
      questions.append(JevResult.Question(
        name: name, kind: question.type, mean: mean, variance: variance(of: values),
        passed: passed, choice: modalPick))
    }

    let score: Double
    let repeatScores: [Double]
    if expectedCount > 0 {
      score = Double(expectedCount - misses.count) / Double(expectedCount)
      repeatScores = expectedHeldPerRepeat.map { Double($0) / Double(expectedCount) }
    } else {
      // Every question recorded only: nothing to hold, nothing to miss.
      score = 1
      repeatScores = [Double](repeating: 1, count: repeats)
    }
    return JevResult(
      score: score,
      passed: score >= jev.effectiveThreshold,
      unknown: false,
      notes: String(misses.joined(separator: "; ").prefix(RubricJudge.maxNotesChars)),
      questions: questions,
      repeats: repeats,
      scoreVariance: variance(of: repeatScores),
      costUSD: spend,
      promptTokens: promptTokens,
      completionTokens: completionTokens)
  }

  static func within(_ value: Double, _ expect: EvalTask.Jev.Expectation) -> Bool {
    if let low = expect.min, value < low { return false }
    if let high = expect.max, value > high { return false }
    return true
  }

  /// Unbiased sample variance (n−1); nil for a single observation.
  static func variance(of values: [Double]) -> Double? {
    guard values.count > 1 else { return nil }
    let mean = values.reduce(0, +) / Double(values.count)
    let squared = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
    return squared / Double(values.count - 1)
  }

  /// The most frequent element, ties broken by name so the fold is deterministic.
  static func modal(of picks: [String]) -> String? {
    let counts = picks.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
    return counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key
  }

  static func topKey(of probabilities: [String: Double]?) -> String? {
    probabilities?.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.first?.key
  }

  static func cost(of responses: [DecisionResponse]) -> Double {
    responses.reduce(0) { $0 + ($1.usage?.cost ?? 0) }
  }

  static func tokens(of responses: [DecisionResponse], _ key: (DecisionUsage) -> Int?) -> Int? {
    let counts = responses.compactMap { $0.usage.flatMap(key) }
    return counts.isEmpty ? nil : counts.reduce(0, +)
  }

  static func miss(name: String, mean: Double, modal: String?, expect: EvalTask.Jev.Expectation) -> String {
    if let expected = expect.choice, let modal, modal != expected {
      return "\(name): chose '\(modal)', expected '\(expected)'"
    }
    if let low = expect.min, mean < low {
      return "\(name): mean \(rounded(mean)) < min \(rounded(low))"
    }
    if let high = expect.max, mean > high {
      return "\(name): mean \(rounded(mean)) > max \(rounded(high))"
    }
    return "\(name): missed"
  }

  private static func rounded(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
