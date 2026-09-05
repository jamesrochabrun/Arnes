import Foundation
import OpenRouterSwift

// MARK: - Verifier

/// Loop 1: adversarial verification of a turn's outcome on a separate (usually cheaper)
/// model. The verifier is kept apart from the actor on purpose — it sees the task, the
/// agent's report and (v2) a diff of the working tree, never the transcript — so it judges
/// the claim against the evidence, not the narration. The verdict is one structured object
/// (`schema`, validated in-process through `StructuredCompletion`); a model that will not
/// produce JSON still yields a verdict through the legacy `PASS`/`FAIL` read of its prose.
///
/// The same request path judges a panel (`judge(task:candidates:…)`): the attempt whose file
/// changes best complete the task, as a `winner` number plus reasons.
public enum Verifier {
  public struct Verdict: Sendable {
    public let passed: Bool
    /// The rendered one-liner the `.verifier` event and `RunResult.verdict` show:
    /// `PASS (high) — <reasons>` / `FAIL (medium) — unmet: <unmet>; <reasons>`, or
    /// `(unstructured) <first line>` when the model's reply never validated.
    public let text: String
    /// Token usage of the verifier request, for the session to price. nil on the structured
    /// path (several requests may have been made; the spend is on `costUSD`).
    public let usage: Usage?
    /// The verdict's spend when the verifier priced its own requests (several of them, or one
    /// priced through `Context.costOf`); nil means "one request, the caller prices `usage`".
    public var costUSD: Double?
    /// The verifier's stated confidence (`high` / `medium` / `low`) once it grades against a
    /// schema; `low` for a verdict read out of prose.
    public var confidence: String?

    public init(passed: Bool, text: String, usage: Usage?, costUSD: Double? = nil, confidence: String? = nil) {
      self.passed = passed
      self.text = text
      self.usage = usage
      self.costUSD = costUSD
      self.confidence = confidence
    }
  }

  /// What the caller knows about the run a verdict is about, beyond the task and the report:
  /// the working tree the agent changed (the verifier diffs it), the run's subprocess
  /// environment (the one the diff's `git` inherits), the manifest (for the verifier model's
  /// `response_format` support) and the caller's pricing. Every field is optional — the
  /// default context verifies from the report alone and says so in the prompt.
  public struct Context: Sendable {
    public var workingDirectory: URL?
    public var environment: SubprocessEnvironment
    public var catalog: ModelCatalog?
    /// Prices one request's usage the way the session does (`usage.cost`, else the manifest
    /// estimate); nil books `usage.cost` alone.
    public var costOf: (@Sendable (Usage?) async -> Double?)?
    /// The run's path rules — `paths.denyRead`/`protected`/`sensitiveWrite` globs, `--add-dir`
    /// roots, the harness root — the untracked-file paste is gated by (S7): a file `read_file`
    /// would refuse the model is named under skipped and never pasted into the verifier's
    /// request. `.default` knows the credential locations and the harness root alone.
    public var rules: PathScope.Rules

    public init(
      workingDirectory: URL? = nil,
      environment: SubprocessEnvironment = .default,
      catalog: ModelCatalog? = nil,
      costOf: (@Sendable (Usage?) async -> Double?)? = nil,
      rules: PathScope.Rules = .default)
    {
      self.workingDirectory = workingDirectory
      self.environment = environment
      self.catalog = catalog
      self.costOf = costOf
      self.rules = rules
    }
  }

  /// What the verifier knows about the working tree.
  public enum Changes: Sendable, Equatable {
    /// A unified diff of what the agent changed; empty = the tree is unchanged, which is
    /// evidence too (the prompt says so).
    case diff(String)
    /// No diff could be taken; the reason is said in the prompt in place of the diff.
    case unavailable(String)
  }

  // MARK: Verdict schema

  /// The reply shape, in the OpenAI strict subset (`additionalProperties: false`, every
  /// property required, `confidence` an enum). `title` names it `verdict` on the wire.
  public static let schema: JSONValue = [
    "title": "verdict",
    "type": "object",
    "properties": [
      "pass": [
        "type": "boolean",
        "description": "true only when the evidence shows the task was completed.",
      ],
      "confidence": [
        "type": "string",
        "enum": ["high", "medium", "low"],
        "description": "high only when the diff settles the question; low when the diff is missing or truncated, or the report alone carries the claim.",
      ],
      "reasons": [
        "type": "array",
        "items": ["type": "string"],
        "description": "The observations the verdict rests on, one short sentence each.",
      ],
      "unmet": [
        "type": "array",
        "items": ["type": "string"],
        "description": "Requirements of the task the evidence does not show as met; empty on a pass.",
      ],
    ],
    "required": ["pass", "confidence", "reasons", "unmet"],
    "additionalProperties": false,
  ]

  /// The report the verifier reads, at most (clipped with a note).
  public static let maxReportChars = 4_000
  /// The diff the verifier reads, at most (the rubric judge's cap; clipped with a note).
  public static let maxDiffChars = 30_000
  /// Corrections after an invalid first reply: one. A verifier is a cheap model on a short
  /// prompt; a second miss falls back to the prose read, not a third paid request.
  public static let maxRetries = 1

  /// Fixed and family-neutral: harness plumbing, not a pack line. The format is the parser's
  /// contract, so it lives in code.
  static let systemPrompt = """
    You are a skeptical verifier. You are given a task, the agent's final report and, when \
    one could be taken, a unified diff of the working tree after the agent ran. You never see \
    the agent's reasoning or transcript. Decide whether the task was completed by judging the \
    report against the diff: the report is a claim, the diff is the evidence. Set pass to true \
    only when the diff shows the work the task asked for, or the task needed no file changes \
    and the report is consistent with the evidence. List every requirement the evidence does \
    not show as met under unmet, and the observations your verdict rests on under reasons, \
    one short sentence each. Confidence is high only when the diff settles the question; use \
    low when the diff is missing or truncated, or the report alone carries the claim. When \
    uncertain, fail.
    """

  /// The user message — the task, the clipped report, the diff (or why there is none). Pure,
  /// so a test can pin what does and does not reach the verifier.
  public static func userText(task: String, report: String, changes: Changes) -> String {
    """
    Task:
    \(task)

    Agent's final report:
    \(clip(report, maxChars: maxReportChars, what: "report"))

    Changes to the working tree (unified diff, taken after the agent ran):
    \(render(changes))
    """
  }

  /// One structured request (plus at most one correction) over the task, the report and the
  /// diff of `context.workingDirectory` — or of `diff` when the caller took one itself (an
  /// eval trial's base→work diff; a trial's workdir is not a repository). A reply that never
  /// validated falls back to the legacy read — the first line's `PASS` prefix — with
  /// `confidence: low`, its spend still booked. Only a transport error throws.
  ///
  /// - Parameter diff: the unified diff to judge against; nil = diff `context.workingDirectory`
  ///   (`ReviewDiff.build(.uncommitted)`: repo-config pins, untracked files through the
  ///   `read_file` gate, 60 000-char cap), and "no diff available" when there is no directory
  ///   or it is not a repository. Never the transcript, never tool arguments.
  public static func run(
    task: String,
    outcome: String,
    model: String,
    service: OpenRouterService,
    context: Context = Context(),
    diff: String? = nil)
    async throws -> Verdict
  {
    let changes: Changes
    if let diff {
      changes = .diff(diff)
    } else if let directory = context.workingDirectory {
      changes = await Self.changes(in: directory, environment: context.environment, rules: context.rules)
    } else {
      changes = .unavailable("no working directory")
    }
    let profile = await profile(for: model, in: context.catalog)
    let costOf: @Sendable (Usage?) async -> Double? = context.costOf ?? { usage in usage?.cost }
    let result = try await StructuredCompletion.request(
      service: service,
      model: model,
      profile: profile,
      messages: [
        .system(systemPrompt),
        .user(userText(task: task, report: outcome, changes: changes)),
      ],
      schema: try OutputSchema(schema: schema),
      maxRetries: maxRetries,
      costOf: costOf)
    guard let value = result.value else {
      return fallbackVerdict(raw: result.raw, costUSD: result.costUSD)
    }
    return verdict(from: value, costUSD: result.costUSD)
  }

  /// The uncommitted changes under `directory` through `ReviewDiff` — the one sanctioned way
  /// to run `git diff` for a model. Every `ReviewError` is a reason in the prompt, never a
  /// thrown verifier: a clean tree is an empty diff (evidence), a non-repository or a failed
  /// git is "no diff available". Unsandboxed, like the `# Environment` probe of an
  /// interactive session: the verifier runs after the loop, in the harness process.
  static func changes(
    in directory: URL, environment: SubprocessEnvironment, rules: PathScope.Rules = .default)
    async -> Changes
  {
    do {
      let built = try await ReviewDiff.build(
        target: .uncommitted,
        cwd: directory,
        sandbox: nil,
        environment: ReviewDiff.pinningGit(environment),
        rules: rules)
      // What the paste left out is evidence too (S7): the names and the reasons, never a byte —
      // a verifier told "server.pem was not read" can say so instead of guessing.
      guard !built.skipped.isEmpty else { return .diff(built.diff) }
      let note = "[untracked files present but not read — the run's path rules refuse them: "
        + built.skipped.joined(separator: "; ") + "]"
      return .diff(built.diff.isEmpty ? note : built.diff + "\n" + note)
    } catch let error as ReviewError {
      switch error {
      case .nothingToReview: return .diff("")
      case .notAGitRepo: return .unavailable("not a git repository")
      case .gitFailed(let detail): return .unavailable("git failed: \(detail)")
      case .badRef(let ref): return .unavailable("cannot resolve \(ref)")
      }
    } catch {
      return .unavailable("\(error)")
    }
  }

  /// A validated reply → the verdict and its one-liner.
  static func verdict(from value: JSONValue, costUSD: Double) -> Verdict {
    let passed = value["pass"]?.boolValue ?? false
    let confidence = value["confidence"]?.stringValue ?? "low"
    let reasons = strings(value["reasons"])
    let unmet = strings(value["unmet"])
    return Verdict(
      passed: passed,
      text: render(passed: passed, confidence: confidence, reasons: reasons, unmet: unmet),
      usage: nil,
      costUSD: costUSD,
      confidence: confidence)
  }

  /// The pre-V1 read, kept as the last resort: the trimmed first line of the prose, `PASS`
  /// prefix = passed. So a model that won't produce JSON still yields a verdict, never a throw.
  static func fallbackVerdict(raw: String, costUSD: Double) -> Verdict {
    let firstLine = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    let line = firstLine.isEmpty ? "FAIL no verdict" : firstLine
    return Verdict(
      passed: line.hasPrefix("PASS"),
      text: "(unstructured) " + line,
      usage: nil,
      costUSD: costUSD,
      confidence: "low")
  }

  /// `PASS (high) — r1; r2` / `FAIL (medium) — unmet: u1; u2; r1` — one line whatever the
  /// model wrote.
  static func render(passed: Bool, confidence: String, reasons: [String], unmet: [String]) -> String {
    var details: [String] = []
    if !passed, !unmet.isEmpty {
      details.append("unmet: " + unmet.joined(separator: "; "))
    }
    if !reasons.isEmpty {
      details.append(reasons.joined(separator: "; "))
    }
    let head = "\(passed ? "PASS" : "FAIL") (\(confidence))"
    return details.isEmpty ? head : head + " — " + details.joined(separator: "; ")
  }

  static func render(_ changes: Changes) -> String {
    switch changes {
    case .diff(let diff):
      if diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return "(the working tree has no uncommitted changes)"
      }
      return clip(diff, maxChars: maxDiffChars, what: "diff")
    case .unavailable(let reason):
      return "(no diff available: \(reason))"
    }
  }

  // MARK: Panel judge

  /// One attempt the panel judge compares.
  public struct Candidate: Sendable, Equatable {
    /// Zero-based, as the panel numbers candidates; the prompt lists it as attempt `index + 1`.
    public var index: Int
    public var model: String
    /// The agent's final report ("" when it gave none — say why in the text instead).
    public var report: String
    /// The unified diff of the attempt's changes; "" = it changed nothing.
    public var changes: String

    public init(index: Int, model: String, report: String, changes: String) {
      self.index = index
      self.model = model
      self.report = report
      self.changes = changes
    }
  }

  public struct JudgeVerdict: Sendable, Equatable {
    /// The winning candidate's `index`; nil when the reply named no attempt (or one that
    /// isn't in the panel) — structured or prose alike.
    public let winnerIndex: Int?
    public let reasons: [String]
    /// The one-liner a panel prints: `attempt 2 (model) — reasons`, or `(unstructured) <reply>`
    /// when the pick came from the prose fallback, or the reply itself when nothing parsed.
    public let text: String
    /// Every attempt's spend, priced through `Context.costOf`.
    public let costUSD: Double

    public init(winnerIndex: Int?, reasons: [String], text: String, costUSD: Double) {
      self.winnerIndex = winnerIndex
      self.reasons = reasons
      self.text = text
      self.costUSD = costUSD
    }
  }

  /// The judge's reply shape (strict subset): the 1-based attempt number as listed in the
  /// prompt, and the reasons for the pick.
  public static let judgeSchema: JSONValue = [
    "title": "winner",
    "type": "object",
    "properties": [
      "winner": [
        "type": "integer",
        "description": "The attempt number, as listed (1-based), whose file changes best complete the task.",
      ],
      "reasons": [
        "type": "array",
        "items": ["type": "string"],
        "description": "Why that attempt beats the others, one short sentence each.",
      ],
    ],
    "required": ["winner", "reasons"],
    "additionalProperties": false,
  ]

  /// Each attempt's diff the judge reads, at most (the panel's cap).
  public static let maxJudgeDiffChars = 12_000

  static let judgeSystemPrompt = """
    You judge several agents' attempts at the same task. Pick the attempt whose file changes \
    best complete the task: working and complete beats partial, minimal beats sprawling, and \
    a report is only as good as the changes backing it. Answer with the attempt number, as \
    listed, and the reasons for the pick.
    """

  /// The judge's user message: the task, then one section per attempt with its clipped
  /// report and clipped file changes. Pure.
  public static func judgeUserText(task: String, candidates: [Candidate]) -> String {
    var sections: [String] = ["Task:\n\(task)"]
    for candidate in candidates {
      let report = candidate.report.isEmpty
        ? "(no report)"
        : clip(candidate.report, maxChars: maxReportChars, what: "report")
      let changes = candidate.changes.isEmpty
        ? "(no file changes)"
        : clip(candidate.changes, maxChars: maxJudgeDiffChars, what: "diff")
      sections.append("""
        ## Attempt \(candidate.index + 1) (\(candidate.model))
        Report:
        \(report)
        File changes:
        \(changes)
        """)
    }
    return sections.joined(separator: "\n\n")
  }

  /// Picks the winning attempt on `model` — the verifier's request path over `judgeSchema`.
  /// A reply that never validated is read the pre-V1 way (`WINNER: <n>` in the prose, the
  /// last resort); when neither names an attempt `winnerIndex` is nil and `text` carries the
  /// reply for the caller's error. Only a transport error throws.
  public static func judge(
    task: String,
    candidates: [Candidate],
    model: String,
    service: OpenRouterService,
    context: Context = Context())
    async throws -> JudgeVerdict
  {
    let profile = await profile(for: model, in: context.catalog)
    let costOf: @Sendable (Usage?) async -> Double? = context.costOf ?? { usage in usage?.cost }
    let result = try await StructuredCompletion.request(
      service: service,
      model: model,
      profile: profile,
      messages: [
        .system(judgeSystemPrompt),
        .user(judgeUserText(task: task, candidates: candidates)),
      ],
      schema: try OutputSchema(schema: judgeSchema),
      maxRetries: maxRetries,
      costOf: costOf)
    let raw = result.raw.trimmingCharacters(in: .whitespacesAndNewlines)
    func attempt(_ number: Int?) -> Candidate? {
      guard let number else { return nil }
      return candidates.first { $0.index + 1 == number }
    }
    if let value = result.value {
      let number = integer(value["winner"])
      let reasons = strings(value["reasons"])
      guard let winner = attempt(number) else {
        return JudgeVerdict(
          winnerIndex: nil, reasons: reasons,
          text: "winner \(number.map(String.init) ?? "?") is not one of the attempts (1…\(candidates.count)): \(raw)",
          costUSD: result.costUSD)
      }
      let text = "attempt \(winner.index + 1) (\(winner.model))"
        + (reasons.isEmpty ? "" : " — " + reasons.joined(separator: "; "))
      return JudgeVerdict(winnerIndex: winner.index, reasons: reasons, text: text, costUSD: result.costUSD)
    }
    if let winner = attempt(parseWinner(raw)) {
      return JudgeVerdict(
        winnerIndex: winner.index, reasons: [], text: "(unstructured) " + raw, costUSD: result.costUSD)
    }
    return JudgeVerdict(winnerIndex: nil, reasons: [], text: raw, costUSD: result.costUSD)
  }

  /// The pre-V1 read: `<n>` from the first `WINNER: <n>` line of a prose reply.
  static func parseWinner(_ text: String) -> Int? {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.uppercased().hasPrefix("WINNER") else { continue }
      let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
      return Int(digits)
    }
    return nil
  }

  // MARK: Shared pieces

  /// The manifest profile a request is shaped by (`response_format` only when it advertises
  /// it); an unknown model, or no catalog, gets the assumed profile — the prompt fallback.
  static func profile(for model: String, in catalog: ModelCatalog?) async -> ModelProfile {
    guard let catalog else { return ModelProfile(unknownModelId: model) }
    return (try? await catalog.profile(for: model)) ?? ModelProfile(unknownModelId: model)
  }

  /// Prices a response the way a session prices its own steps: `usage.cost` when the router
  /// reports it, else the manifest estimate on a provider that needs one. What a runner
  /// without a session (the panel, an eval trial) hands `Context.costOf`.
  static func pricing(profile: ModelProfile, estimatesCost: Bool) -> @Sendable (Usage?) async -> Double? {
    { usage in
      if let cost = usage?.cost { return cost }
      guard estimatesCost, let usage else { return nil }
      return Session.estimatedCost(
        promptTokens: usage.promptTokens, completionTokens: usage.completionTokens, profile: profile)
    }
  }

  /// `text` cut at `maxChars` with a note naming the remainder; whole when it fits.
  static func clip(_ text: String, maxChars: Int, what: String) -> String {
    guard text.count > maxChars else { return text }
    return String(text.prefix(maxChars)) + "\n… [\(what) truncated, \(text.count - maxChars) more chars]"
  }

  /// The non-empty strings of a JSON array, newlines folded so the one-liner stays one line.
  static func strings(_ value: JSONValue?) -> [String] {
    (value?.arrayValue ?? []).compactMap { entry in
      guard let string = entry.stringValue else { return nil }
      let folded = string.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
      return folded.isEmpty ? nil : folded
    }
  }

  /// A JSON integer, `2` or `2.0` (`JSONSchemaLite` accepts the whole double as an integer).
  static func integer(_ value: JSONValue?) -> Int? {
    if let int = value?.intValue { return int }
    if let double = value?.doubleValue, double == double.rounded(), abs(double) < Double(Int.max) {
      return Int(double)
    }
    return nil
  }
}
