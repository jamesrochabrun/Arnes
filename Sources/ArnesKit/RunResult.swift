import Foundation
import OpenRouterSwift

// MARK: - PermissionDenialInfo

/// One refused tool call, as the headless envelope reports it: which tool, and the gate's
/// reason when it gave one. Derived from the record's audit trail (`ToolDecision` deny rows).
public struct PermissionDenialInfo: Codable, Sendable, Equatable {
  public let tool: String
  public let reason: String?

  public init(tool: String, reason: String?) {
    self.tool = tool
    self.reason = reason
  }
}

// MARK: - RunResult

/// The headless run contract — what `arnes do --output-format json` prints as its one line,
/// and what `stream-json` ends with. One envelope for every way a run can end, so a script
/// checks `stop_reason` (and the exit code derived from it) instead of parsing prose.
///
/// Keys are stable snake_case on the wire (the same spelling the event stream uses, and the
/// one Claude Code's `--output-format json` consumers already parse). `stop_reason` is the
/// record's `StopReason` vocabulary — with one addition the loop can't know: a headless
/// `--timeout` interrupts the session (the record says `interrupted`) and the envelope says
/// `timeout`, because the envelope knows the cause and the record only the effect.
public struct RunResult: Codable, Sendable, Equatable {
  /// Always `"result"` — the discriminator a `stream-json` reader keys on.
  public var type: String
  public var sessionId: String
  /// The `RunRecord.id` this run appended; nil when the run failed before a record existed.
  public var runId: String?
  public var stopReason: StopReason?
  /// A transport/provider error ended the run (`stop_reason == error`), or nothing ran at all.
  public var isError: Bool
  /// The error's description when `isError`; nil otherwise.
  public var error: String?
  /// The final assistant message — empty when the run produced none.
  public var result: String
  /// The validated JSON object when the run asked for one (`--output-schema`) and got it; nil
  /// when none was asked for, and when none validated (`stop_reason` is then
  /// `structured_output_failed` and `result` still carries the prose).
  public var structuredOutput: JSONValue?
  /// The requested model.
  public var model: String
  /// The models that actually served steps (post-routing).
  public var routedModels: [String]
  /// The wire dialect that executed; nil when no request was made.
  public var dialect: String?
  public var provider: String?
  public var steps: Int
  public var toolCalls: Int
  /// Tool calls the permission gate or a PreToolUse hook refused.
  public var deniedCalls: Int
  public var permissionDenials: [PermissionDenialInfo]
  public var costUSD: Double
  /// `true` when the provider doesn't price responses and `cost_usd` is usage × manifest
  /// prices (`ProviderTraits.estimatesCost`) — say "estimated" when you relay it.
  public var costEstimated: Bool
  public var promptTokens: Int?
  public var completionTokens: Int?
  /// Prompt tokens the run's requests read from the provider's prompt cache
  /// (`RunRecord.cachedTokens`, a subset of `prompt_tokens`); nil when the record carries none —
  /// a run that cached nothing, an older record, or a run that never returned.
  public var cachedTokens: Int?
  /// Wall-clock milliseconds from the run's start to its end.
  public var durationMs: Int
  /// The loop-1 verifier's verdict when `--verify` ran; nil otherwise.
  public var verifierPassed: Bool?
  /// The verifier's text, when it ran.
  public var verdict: String?
  /// Tool results the output cap cut (head + tail kept, the rest in a spill file when one was
  /// configured). 0 when nothing was cut.
  public var truncatedResults: Int

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
    case runId = "run_id"
    case stopReason = "stop_reason"
    case isError = "is_error"
    case error
    case result
    case structuredOutput = "structured_output"
    case model
    case routedModels = "routed_models"
    case dialect
    case provider
    case steps
    case toolCalls = "tool_calls"
    case deniedCalls = "denied_calls"
    case permissionDenials = "permission_denials"
    case costUSD = "cost_usd"
    case costEstimated = "cost_estimated"
    case promptTokens = "prompt_tokens"
    case completionTokens = "completion_tokens"
    case cachedTokens = "cached_tokens"
    case durationMs = "duration_ms"
    case verifierPassed = "verifier_passed"
    case verdict
    case truncatedResults = "truncated_results"
  }

  /// The envelope for a run that returned.
  ///
  /// - Parameters:
  ///   - costEstimated: `ProviderTraits.estimatesCost` of the provider the run went through.
  ///   - verdict: the verifier's text, captured from the `.verifier` event by the caller.
  ///   - stopReason: overrides the record's reason when the caller knows the cause the loop
  ///     doesn't — `.timeout` for a deadline the caller enforced by interrupting the session.
  public init(
    result: AgentResult,
    costEstimated: Bool,
    verdict: String? = nil,
    stopReason: StopReason? = nil)
  {
    let record = result.record
    let reason = stopReason ?? result.stopReason
    type = "result"
    sessionId = result.sessionId
    runId = record.id
    self.stopReason = reason
    isError = reason == .error
    error = nil
    self.result = result.text
    structuredOutput = result.structuredOutput
    model = record.model
    routedModels = record.routedModels
    dialect = record.dialect
    provider = record.provider
    steps = record.steps
    toolCalls = record.toolCalls
    deniedCalls = record.deniedCalls ?? 0
    permissionDenials = result.denials
    costUSD = record.costUSD
    self.costEstimated = costEstimated
    promptTokens = record.promptTokens
    completionTokens = record.completionTokens
    cachedTokens = record.cachedTokens
    durationMs = result.durationMs
    verifierPassed = record.verifierPassed
    self.verdict = verdict
    truncatedResults = record.truncatedResults ?? 0
  }

  /// The envelope for a run that did *not* return a result — the turn threw, or a deadline
  /// passed without the session stopping. Carries whatever the caller still knows: the
  /// record when the loop appended one before rethrowing, else the requested model alone.
  ///
  /// - Parameters:
  ///   - stopReason: `.error` for a thrown run (also sets `isError`), `.timeout` for a run
  ///     that never came back.
  public static func failure(
    stopReason: StopReason,
    error: String?,
    sessionId: String?,
    model: String,
    provider: String?,
    record: RunRecord?,
    costEstimated: Bool,
    durationMs: Int)
    -> RunResult
  {
    RunResult(
      type: "result",
      sessionId: sessionId ?? record?.sessionId ?? "",
      runId: record?.id,
      stopReason: stopReason,
      isError: stopReason == .error,
      error: error,
      result: record?.summary ?? "",
      structuredOutput: nil,
      model: record?.model ?? model,
      routedModels: record?.routedModels ?? [],
      dialect: record?.dialect,
      provider: record?.provider ?? provider,
      steps: record?.steps ?? 0,
      toolCalls: record?.toolCalls ?? 0,
      deniedCalls: record?.deniedCalls ?? 0,
      permissionDenials: (record?.decisions ?? [])
        .filter { $0.decision == .deny }
        .map { PermissionDenialInfo(tool: $0.tool, reason: $0.reason) },
      costUSD: record?.costUSD ?? 0,
      costEstimated: costEstimated,
      promptTokens: record?.promptTokens,
      completionTokens: record?.completionTokens,
      durationMs: durationMs,
      verifierPassed: record?.verifierPassed,
      verdict: nil,
      truncatedResults: record?.truncatedResults ?? 0)
  }

  /// Field-by-field, for embedders assembling an envelope from their own bookkeeping.
  public init(
    type: String = "result",
    sessionId: String,
    runId: String?,
    stopReason: StopReason?,
    isError: Bool,
    error: String?,
    result: String,
    structuredOutput: JSONValue?,
    model: String,
    routedModels: [String],
    dialect: String?,
    provider: String?,
    steps: Int,
    toolCalls: Int,
    deniedCalls: Int,
    permissionDenials: [PermissionDenialInfo],
    costUSD: Double,
    costEstimated: Bool,
    promptTokens: Int?,
    completionTokens: Int?,
    durationMs: Int,
    verifierPassed: Bool?,
    verdict: String?,
    truncatedResults: Int = 0,
    cachedTokens: Int? = nil)
  {
    self.type = type
    self.sessionId = sessionId
    self.runId = runId
    self.stopReason = stopReason
    self.isError = isError
    self.error = error
    self.result = result
    self.structuredOutput = structuredOutput
    self.model = model
    self.routedModels = routedModels
    self.dialect = dialect
    self.provider = provider
    self.steps = steps
    self.toolCalls = toolCalls
    self.deniedCalls = deniedCalls
    self.permissionDenials = permissionDenials
    self.costUSD = costUSD
    self.costEstimated = costEstimated
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.durationMs = durationMs
    self.verifierPassed = verifierPassed
    self.verdict = verdict
    self.truncatedResults = truncatedResults
    self.cachedTokens = cachedTokens
  }
}

// MARK: - HeadlessJSON

/// The one JSON encoding every headless line uses: keys sorted (so two runs of the same
/// event print the same bytes), slashes unescaped (paths stay readable), no pretty-printing
/// (one object per line is the contract). Control characters in model-originated text are
/// escaped by the encoder — nothing here needs the terminal sanitizer.
public enum HeadlessJSON {
  public static func line<T: Encodable>(_ value: T) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else {
      // Every type this is used with is a plain Codable value; an encoding failure would be a
      // programming error, and an empty object still keeps the stream one-object-per-line.
      return "{}"
    }
    return String(decoding: data, as: UTF8.self)
  }
}
