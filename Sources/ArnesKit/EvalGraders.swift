import Foundation
import OpenRouterSwift

// MARK: - RubricResult

/// What the rubric judge came back with for one trial, with its spend.
public struct RubricResult: Sendable, Equatable {
  /// One criterion as the judge answered it.
  public struct Criterion: Sendable, Equatable, Codable {
    public let criterion: String
    public let met: Bool

    public init(criterion: String, met: Bool) {
      self.criterion = criterion
      self.met = met
    }
  }

  /// The fraction of criteria met, clamped to `0...1` in code whatever the model wrote.
  public let score: Double
  /// The judge said pass, the score reached the threshold, and nothing was unknown.
  public let passed: Bool
  /// The evidence could not settle at least one criterion — or the judge's reply never
  /// validated, or the request failed (`notes` says which). Never a pass.
  public let unknown: Bool
  public let notes: String
  public let criteria: [Criterion]
  /// The judge's spend over every attempt, booked valid or not.
  public let costUSD: Double
  public let promptTokens: Int?
  public let completionTokens: Int?

  public init(
    score: Double,
    passed: Bool,
    unknown: Bool,
    notes: String,
    criteria: [Criterion],
    costUSD: Double,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil)
  {
    self.score = score
    self.passed = passed
    self.unknown = unknown
    self.notes = notes
    self.criteria = criteria
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
    -> RubricResult
  {
    RubricResult(
      score: 0, passed: false, unknown: true, notes: notes, criteria: [], costUSD: costUSD,
      promptTokens: promptTokens, completionTokens: completionTokens)
  }
}

// MARK: - RubricJudge

/// The rubric grader (X4): one structured side request to a judge model, over the evidence a
/// trial leaves behind — the task, the agent's final report, the diff of the working
/// directory against its post-setup state, and the check's verdict with its output. **Never
/// the transcript**: the judge is kept apart from the actor the way `Verifier` is, so the
/// actor's narration cannot argue its case (the report is a claim; the diff and the check
/// are the proof). Fixed, family-neutral prompt — harness plumbing, like `Verifier.systemPrompt`.
public enum RubricJudge {
  /// What the judge sees besides the task and the criteria.
  public struct Evidence: Sendable, Equatable {
    /// The agent's final reply.
    public var report: String
    /// `WorkspaceSnapshot.diff` of the trial's workdir against its post-setup clone.
    public var diff: String
    public var checkPassed: Bool
    /// The check script's output.
    public var checkOutput: String

    public init(report: String, diff: String, checkPassed: Bool, checkOutput: String) {
      self.report = report
      self.diff = diff
      self.checkPassed = checkPassed
      self.checkOutput = checkOutput
    }
  }

  /// The diff the judge reads, at most (clipped with `WorkspaceSnapshot.clippedDiff`).
  public static let maxDiffChars = 30_000
  /// The check output the judge reads, at most.
  public static let maxCheckOutputChars = 2_000
  /// The notes an outcome row keeps, at most.
  public static let maxNotesChars = 500
  /// Corrections after an invalid first reply: one. A judge is a cheap model on a short
  /// prompt; a second miss is an `unknown`, not a third paid request.
  public static let maxRetries = 1

  /// The reply shape, in the OpenAI strict subset (`additionalProperties: false` everywhere,
  /// every property required, bounds enforced in code). `met` is never null: a criterion the
  /// evidence cannot settle is `met: false` with `unknown: true` at the top.
  public static let schema: JSONValue = [
    "type": "object",
    "properties": [
      "score": [
        "type": "number",
        "description": "The fraction of the criteria met, from 0 to 1.",
      ],
      "pass": [
        "type": "boolean",
        "description": "true only when every criterion is met.",
      ],
      "unknown": [
        "type": "boolean",
        "description": "true when the evidence cannot settle at least one criterion.",
      ],
      "notes": [
        "type": "string",
        "description": "One or two sentences: which criteria were not met or could not be judged, and why.",
      ],
      "criteria": [
        "type": "array",
        "description": "One entry per criterion, in the order given.",
        "items": [
          "type": "object",
          "properties": [
            "criterion": ["type": "string"],
            "met": ["type": "boolean"],
          ],
          "required": ["criterion", "met"],
          "additionalProperties": false,
        ],
      ],
    ],
    "required": ["score", "pass", "unknown", "notes", "criteria"],
    "additionalProperties": false,
  ]

  static let systemPrompt = """
    You grade an AI coding agent's work against a rubric, from the evidence only: the task, \
    the agent's final report, the diff of the working directory after the run, and the verdict \
    of a programmatic check. You never see the agent's reasoning or transcript. For each \
    criterion decide met or not met from what the diff and the check show — the report is a \
    claim, not proof. When the evidence cannot settle a criterion, mark it not met and set \
    unknown to true. score is the fraction of criteria met; pass is true only when every \
    criterion is met. Judge the criteria as written: no opinions on style, and nothing the \
    rubric does not ask about.
    """

  /// The user message — the task, the numbered criteria, the report, the clipped diff, the
  /// check's verdict and output. Pure, so a test can pin what does and does not reach the judge.
  public static func userText(task: EvalTask, evidence: Evidence) -> String {
    let criteria = (task.rubric?.criteria ?? []).enumerated()
      .map { "\($0.offset + 1). \($0.element)" }
      .joined(separator: "\n")
    let diff = evidence.diff.isEmpty
      ? "(no changes to the working directory)"
      : WorkspaceSnapshot.clippedDiff(evidence.diff, maxChars: maxDiffChars)
    let checkOutput = String(evidence.checkOutput.prefix(maxCheckOutputChars))
    return """
      Task:
      \(task.prompt)

      Criteria:
      \(criteria)

      Agent's final report:
      \(evidence.report)

      Changes to the working directory (unified diff, base = before the agent ran):
      \(diff)

      Programmatic check: \(evidence.checkPassed ? "PASSED" : "FAILED")
      Check output:
      \(checkOutput.isEmpty ? "(none)" : checkOutput)
      """
  }

  /// Grades one trial. A reply that never validated is an `unknown` result with the spend
  /// booked; only a transport error throws (the runner turns that into `unknown` too).
  ///
  /// - Parameters:
  ///   - model: the judge model id to send (alias already resolved).
  ///   - profile: the judge's manifest profile — decides `response_format` vs the prompt fallback.
  ///   - costOf: prices one response the way the caller prices its own requests.
  public static func grade(
    task: EvalTask,
    evidence: Evidence,
    model: String,
    profile: ModelProfile,
    service: OpenRouterService,
    costOf: @Sendable (Usage?) async -> Double?)
    async throws -> RubricResult
  {
    let threshold = task.rubric?.effectiveThreshold ?? EvalTask.Rubric.defaultThreshold
    let result = try await StructuredCompletion.request(
      service: service,
      model: model,
      profile: profile,
      messages: [.system(systemPrompt), .user(userText(task: task, evidence: evidence))],
      schema: try OutputSchema(schema: schema),
      maxRetries: maxRetries,
      costOf: costOf)
    guard let value = result.value else {
      return .unknown(
        notes: "judge reply invalid: \(result.errors.first ?? "no JSON object")",
        costUSD: result.costUSD,
        promptTokens: result.promptTokens,
        completionTokens: result.completionTokens)
    }
    return verdict(
      from: value, threshold: threshold, costUSD: result.costUSD,
      promptTokens: result.promptTokens, completionTokens: result.completionTokens)
  }

  /// A validated reply → the result: the score clamped to `0...1`, `passed` only when the
  /// judge said pass, the score reached the threshold and nothing was unknown.
  static func verdict(
    from value: JSONValue,
    threshold: Double,
    costUSD: Double,
    promptTokens: Int?,
    completionTokens: Int?)
    -> RubricResult
  {
    let score = min(1, max(0, value["score"]?.doubleValue ?? 0))
    let pass = value["pass"]?.boolValue ?? false
    let unknown = value["unknown"]?.boolValue ?? false
    let notes = value["notes"]?.stringValue ?? ""
    let criteria = (value["criteria"]?.arrayValue ?? []).compactMap { entry -> RubricResult.Criterion? in
      guard let criterion = entry["criterion"]?.stringValue, let met = entry["met"]?.boolValue else {
        return nil
      }
      return RubricResult.Criterion(criterion: criterion, met: met)
    }
    return RubricResult(
      score: score,
      passed: pass && score >= threshold && !unknown,
      unknown: unknown,
      notes: notes,
      criteria: criteria,
      costUSD: costUSD,
      promptTokens: promptTokens,
      completionTokens: completionTokens)
  }
}

// MARK: - LimitsGrader

/// The efficiency grader (X4): pure over the trial's `RunRecord` and the task's `Limits`.
public enum LimitsGrader {
  /// Every limit checked against the record; violations are short, in a fixed order.
  public static func evaluate(record: RunRecord, limits: EvalTask.Limits) -> (passed: Bool, violations: [String]) {
    var violations: [String] = []
    if let maxSteps = limits.maxSteps {
      if record.steps > maxSteps {
        violations.append("steps \(record.steps) > \(maxSteps)")
      } else if record.stopReason == .maxSteps, record.steps >= maxSteps {
        // The task's cap stopped the run: the model did not finish within the limit. A run the
        // runner's lower `--max-steps` stopped first is not this limit's failure.
        violations.append("stopped by the step cap (max_steps)")
      }
    }
    if let maxToolCalls = limits.maxToolCalls, record.toolCalls > maxToolCalls {
      violations.append("tool calls \(record.toolCalls) > \(maxToolCalls)")
    }
    if let maxCostUSD = limits.maxCostUSD {
      if record.costUSD > maxCostUSD {
        violations.append("cost \(usd(record.costUSD)) > \(usd(maxCostUSD))")
      } else if record.stopReason == .budget {
        violations.append("stopped by the cost cap (budget)")
      }
    }
    let stats = record.toolStats ?? [:]
    for tool in limits.forbiddenTools ?? [] {
      let calls = stats[tool]?.calls ?? 0
      if calls > 0 {
        violations.append("forbidden tool \(tool) called \(calls)×")
      }
    }
    for tool in limits.requiredTools ?? [] where (stats[tool]?.calls ?? 0) == 0 {
      violations.append("required tool \(tool) never called")
    }
    return (violations.isEmpty, violations)
  }

  /// The names in `forbiddenTools`/`requiredTools` that are neither a tool the trial has nor
  /// a harness tool name — a typo, refused before the agent runs.
  public static func unknownTools(in limits: EvalTask.Limits, available: Set<String>) -> [String] {
    ((limits.forbiddenTools ?? []) + (limits.requiredTools ?? []))
      .filter { !available.contains($0) }
  }

  private static func usd(_ value: Double) -> String {
    String(format: "$%.4f", value)
  }
}
