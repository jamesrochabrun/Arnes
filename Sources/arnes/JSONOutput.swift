import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - JSONOut

/// The one encoder behind every `--json` listing: sorted keys (stable diffs), ISO-8601 dates,
/// slashes unescaped, one document per command. It mirrors `HeadlessJSON`'s configuration
/// (RunResult.swift) rather than calling it, so a listing's shape can't change under a
/// change to the run envelope — and adds the date strategy the envelope never needed.
///
/// Non-finite doubles have no JSON spelling; DTOs pass their doubles through `finite(_:)`
/// so a NaN or an infinity encodes as `null` instead of failing the whole document.
enum JSONOut {
  static func line<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }

  /// Prints the one document a `--json` command emits on stdout. Everything else a command
  /// says (connection chatter, warnings) goes to stderr, like `do --output-format json`.
  static func print<T: Encodable>(_ value: T) throws {
    Swift.print(try line(value))
  }

  /// nil for a NaN or an infinity — the value a DTO field takes so it encodes as `null`.
  static func finite(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return value
  }

  static func stderr(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
  }
}

/// An optional field that always appears in the document — `null` when unset — so every
/// documented key of a listing row is present in every row (a synthesized `Encodable` drops
/// a nil optional, and `has("model")` would then depend on the row).
@propertyWrapper
struct Nullable<Value: Encodable & Equatable>: Encodable, Equatable {
  var wrappedValue: Value?

  init(wrappedValue: Value?) {
    self.wrappedValue = wrappedValue
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    if let wrappedValue { try container.encode(wrappedValue) } else { try container.encodeNil() }
  }
}

// MARK: - models --json

/// One manifest row. A DTO over `ModelProfile` (which stays non-Codable) so a manifest
/// field added later can't leak into the contract by accident. Keys are additive forever.
struct ModelRow: Encodable, Equatable {
  let id: String
  let family: String
  let dialect: String
  @Nullable var contextLength: Int?
  let supportsTools: Bool
  let supportsReasoning: Bool
  let supportsStructuredOutputs: Bool
  /// T5: whether the model takes images (what turns `view_image` on for it). Additive.
  let supportsVision: Bool
  @Nullable var promptPricePerToken: Double?
  @Nullable var completionPricePerToken: Double?

  init(_ profile: ModelProfile) {
    id = profile.id
    family = profile.family.rawValue
    dialect = profile.dialect.rawValue
    contextLength = profile.contextLength
    supportsTools = profile.supportsTools
    supportsReasoning = profile.supportsReasoning
    supportsStructuredOutputs = profile.supportsStructuredOutputs
    supportsVision = profile.supportsVision
    promptPricePerToken = JSONOut.finite(profile.promptPricePerToken)
    completionPricePerToken = JSONOut.finite(profile.completionPricePerToken)
  }

  enum CodingKeys: String, CodingKey {
    case id, family, dialect
    case contextLength = "context_length"
    case supportsTools = "supports_tools"
    case supportsReasoning = "supports_reasoning"
    case supportsStructuredOutputs = "supports_structured_outputs"
    case supportsVision = "supports_vision"
    case promptPricePerToken = "prompt_price_per_token"
    case completionPricePerToken = "completion_price_per_token"
  }
}

// MARK: - providers --json

/// One configured provider, as `arnes providers` reads it — offline. `base_host` is
/// `host[:port]`, never the URL path (gateway paths routinely carry a token).
struct ProviderRow: Encodable, Equatable {
  let name: String
  let kind: String
  let active: Bool
  let resolves: Bool
  /// Where the key would come from (`env NAME`, `config`, a credentials path, `command …`);
  /// nil when the entry doesn't resolve. Never the key.
  @Nullable var keySource: String?
  @Nullable var baseHost: String?
  @Nullable var defaultModel: String?
  /// Why the entry doesn't resolve, when it doesn't.
  @Nullable var error: String?
  /// How a chat request to this provider spells the reasoning dial (`ReasoningShape`:
  /// `openrouter` · `openai` · `none`) — the entry's override, else its kind's default; present
  /// on every row, resolving or not.
  let reasoningShape: String

  enum CodingKeys: String, CodingKey {
    case name, kind, active, resolves, error
    case keySource = "key_source"
    case baseHost = "base_host"
    case defaultModel = "default_model"
    case reasoningShape = "reasoning_shape"
  }
}

// MARK: - status --json

/// What `arnes status` prints, one key per line of the text view. Credits/spend appear only
/// when the text view fetched them (they need the network); the rest is configuration.
struct StatusReport: Encodable {
  struct Provider: Encodable {
    let name: String
    let kind: String
    /// `host[:port]` — never a path, header value or token.
    let baseHost: String
    let keySource: String
    @Nullable var defaultModel: String?

    enum CodingKeys: String, CodingKey {
      case name, kind
      case baseHost = "base_host"
      case keySource = "key_source"
      case defaultModel = "default_model"
    }
  }

  struct Key: Encodable, Equatable {
    @Nullable var label: String?
    @Nullable var freeTier: Bool?
    @Nullable var limit: Double?
    @Nullable var limitRemaining: Double?
    @Nullable var spend: Double?
    @Nullable var maxBudget: Double?
    @Nullable var models: [String]?
    @Nullable var expires: String?

    enum CodingKeys: String, CodingKey {
      case label, limit, spend, models, expires
      case freeTier = "free_tier"
      case limitRemaining = "limit_remaining"
      case maxBudget = "max_budget"
    }
  }

  struct Credits: Encodable, Equatable {
    @Nullable var remaining: Double?
    @Nullable var total: Double?
  }

  struct SubprocessEnv: Encodable {
    let inherit: String
    let withheld: [String]
    let excluded: [String]
    let excludeSecrets: Bool
    @Nullable var includeOnly: [String]?
    let summary: String

    enum CodingKeys: String, CodingKey {
      case inherit, withheld, excluded, summary
      case excludeSecrets = "exclude_secrets"
      case includeOnly = "include_only"
    }
  }

  struct Limits: Encodable {
    struct LoopGuard: Encodable {
      let maxConsecutiveErrors: Int
      let maxIdenticalCalls: Int
      let maxEditsPerFile: Int
      let nudgeAt: Int

      enum CodingKeys: String, CodingKey {
        case maxConsecutiveErrors = "max_consecutive_errors"
        case maxIdenticalCalls = "max_identical_calls"
        case maxEditsPerFile = "max_edits_per_file"
        case nudgeAt = "nudge_at"
      }
    }

    let toolResultChars: Int
    let bashOutputChars: Int
    /// The per-command default a `bash` call runs under when it names no `timeout_seconds`
    /// (`limits.bashTimeoutSeconds`, clamped).
    let bashTimeoutSeconds: Int
    let loopGuard: LoopGuard

    enum CodingKeys: String, CodingKey {
      case toolResultChars = "tool_result_chars"
      case bashOutputChars = "bash_output_chars"
      case bashTimeoutSeconds = "bash_timeout_seconds"
      case loopGuard = "loop_guard"
    }
  }

  struct Paths: Encodable {
    let protected: [String]
    let sensitiveWrite: [String]
    let denyRead: [String]

    enum CodingKeys: String, CodingKey {
      case protected
      case sensitiveWrite = "sensitive_write"
      case denyRead = "deny_read"
    }
  }

  struct Sandbox: Encodable {
    let configured: Bool
    let enabled: Bool
    let network: Bool
    let supported: Bool
    let failIfUnavailable: Bool

    enum CodingKeys: String, CodingKey {
      case configured, enabled, network, supported
      case failIfUnavailable = "fail_if_unavailable"
    }
  }

  /// `policies.transport` over the built-in numbers; 0 = off (`TransportPolicy`).
  struct Transport: Encodable {
    let maxRequestRetries: Int
    let maxStreamRetries: Int
    let streamIdleTimeoutMs: Int

    enum CodingKeys: String, CodingKey {
      case maxRequestRetries = "max_request_retries"
      case maxStreamRetries = "max_stream_retries"
      case streamIdleTimeoutMs = "stream_idle_timeout_ms"
    }
  }

  /// `policies.promptCache` (`CachePolicy`): `ttl` null = the provider's default.
  struct PromptCache: Encodable {
    let anthropicBreakpoints: Bool
    @Nullable var ttl: String?

    enum CodingKeys: String, CodingKey {
      case ttl
      case anthropicBreakpoints = "anthropic_breakpoints"
    }
  }

  /// `policies.manifestCache`: `enabled` false = every process fetches, and `ttl_hours` is null.
  struct ManifestCache: Encodable {
    let enabled: Bool
    @Nullable var ttlHours: Double?

    enum CodingKeys: String, CodingKey {
      case enabled
      case ttlHours = "ttl_hours"
    }
  }

  /// The top-level `compaction` block, defaults filled in (`CompactionPolicy`).
  struct Compaction: Encodable {
    let threshold: Double
    let keepRecentToolResults: Int
    let clearMinChars: Int
    let maxPerTurn: Int
    let keepRecentImages: Int

    enum CodingKeys: String, CodingKey {
      case threshold
      case keepRecentToolResults = "keep_recent_tool_results"
      case clearMinChars = "clear_min_chars"
      case maxPerTurn = "max_per_turn"
      case keepRecentImages = "keep_recent_images"
    }
  }

  /// The top-level `checkpoints` block, defaults filled in, and the root the REPL keeps them under
  /// (a full path — the X8 convention).
  struct Checkpoints: Encodable {
    let enabled: Bool
    let root: String
    let maxFileBytes: Int
    let maxTurns: Int

    enum CodingKeys: String, CodingKey {
      case enabled, root
      case maxFileBytes = "max_file_bytes"
      case maxTurns = "max_turns"
    }
  }

  /// The top-level `memory` block, defaults filled in, and the root a run reads
  /// (`ARNES_MEMORY_DIR` > `memory.directory` > `~/.arnes/memory`; a full path).
  struct Memory: Encodable {
    let enabled: Bool
    let root: String
    let maxLines: Int
    let maxBytes: Int

    enum CodingKeys: String, CodingKey {
      case enabled, root
      case maxLines = "max_lines"
      case maxBytes = "max_bytes"
    }
  }

  /// The top-level `web` block (`WebFetchPolicy`), defaults filled in — null on the document when
  /// there is none, since then no run has `web_fetch`.
  struct Web: Encodable, Equatable {
    let allowedDomains: [String]
    let deniedDomains: [String]
    let maxBytes: Int
    let timeoutSeconds: Int

    enum CodingKeys: String, CodingKey {
      case allowedDomains = "allowed_domains"
      case deniedDomains = "denied_domains"
      case maxBytes = "max_bytes"
      case timeoutSeconds = "timeout_seconds"
    }
  }

  /// The provider's `subagents` block over the built-in defaults (`TaskTool.Defaults`):
  /// `default_model` null = inherit the lead's, `max_steps` null = unlimited, `budget_usd` null =
  /// only the parent's remaining budget applies.
  struct Subagents: Encodable {
    @Nullable var defaultModel: String?
    @Nullable var maxSteps: Int?
    @Nullable var budgetUSD: Double?
    let maxConcurrent: Int
    let maxDepth: Int
    let background: Bool
    let joinAtTurnEnd: Bool
    let persistTranscripts: Bool

    enum CodingKeys: String, CodingKey {
      case background
      case defaultModel = "default_model"
      case maxSteps = "max_steps"
      case budgetUSD = "budget_usd"
      case maxConcurrent = "max_concurrent"
      case maxDepth = "max_depth"
      case joinAtTurnEnd = "join_at_turn_end"
      case persistTranscripts = "persist_transcripts"
    }
  }

  let provider: Provider
  @Nullable var key: Key?
  @Nullable var credits: Credits?
  /// Why `key`/`credits` are null when the provider's key lookup failed (an HTTP 404 from a
  /// gateway that has no `/key/info`, an outage); null when it succeeded.
  @Nullable var keyError: String?
  /// Manifest size when the text view counted it (litellm / openai-compatible).
  @Nullable var manifestModels: Int?
  /// Where that manifest came from: `network` (fetched this process), `cache` (the disk copy,
  /// within its TTL), `stale-cache` (the disk copy standing in for a failed fetch) or
  /// `unavailable`; null when the text view didn't consult the catalog (openrouter).
  @Nullable var manifestSource: String?
  /// When the served cached copy was fetched; null unless `manifest_source` is a cache.
  @Nullable var manifestFetchedAt: Date?
  let subprocessEnv: SubprocessEnv
  let environmentContext: Bool
  let limits: Limits
  let paths: Paths
  let sandbox: Sandbox
  @Nullable var judge: String?
  /// `policies.toolResultFraming`: whether tool results enter history wrapped in
  /// `<tool_result …>` tags (on unless switched off).
  let toolResultFraming: Bool
  /// `policies.adaptiveThink`: whether a natively reasoning model under `--effort` goes without
  /// the `think` tool (on by default since the batch-13 A/B).
  let adaptiveThink: Bool
  let transport: Transport
  let promptCache: PromptCache
  let manifestCache: ManifestCache
  let compaction: Compaction
  let checkpoints: Checkpoints
  let memory: Memory
  @Nullable var web: Web?
  let subagents: Subagents
  /// How a chat request to the active provider spells the reasoning dial (`ReasoningShape`:
  /// `openrouter` · `openai` · `none`) — the entry's `reasoningShape` override, else its kind's
  /// default. Always present (Q2).
  let reasoningShape: String
  /// `policies.panelOnVerifierFail` (P2): the panel size a `do --verify … --yes` run escalates
  /// to on a verifier FAIL; null when unset (off). Always present.
  @Nullable var panelOnVerifierFail: Int?

  enum CodingKeys: String, CodingKey {
    case provider, key, credits, limits, paths, sandbox, judge
    case transport, compaction, checkpoints, memory, web, subagents
    case keyError = "key_error"
    case manifestModels = "manifest_models"
    case manifestSource = "manifest_source"
    case manifestFetchedAt = "manifest_fetched_at"
    case subprocessEnv = "subprocess_env"
    case environmentContext = "environment_context"
    case toolResultFraming = "tool_result_framing"
    case adaptiveThink = "adaptive_think"
    case promptCache = "prompt_cache"
    case manifestCache = "manifest_cache"
    case reasoningShape = "reasoning_shape"
    case panelOnVerifierFail = "panel_on_verifier_fail"
  }

  static func subprocessEnv(_ environment: SubprocessEnvironment) -> SubprocessEnv {
    let policy = environment.policy
    return SubprocessEnv(
      inherit: (policy.inherit ?? .all).rawValue,
      withheld: environment.redactedKeys.sorted(),
      excluded: policy.exclude ?? [],
      excludeSecrets: policy.excludeSecrets ?? false,
      includeOnly: policy.includeOnly,
      summary: environment.summary)
  }

  static func limits(_ limits: LimitsConfig) -> Limits {
    let guardPolicy = limits.effectiveLoopGuard
    return Limits(
      toolResultChars: limits.effectiveToolResultChars,
      bashOutputChars: limits.effectiveBashOutputChars,
      bashTimeoutSeconds: limits.effectiveBashTimeoutSeconds,
      loopGuard: .init(
        maxConsecutiveErrors: guardPolicy.maxConsecutiveErrors,
        maxIdenticalCalls: guardPolicy.maxIdenticalCalls,
        maxEditsPerFile: guardPolicy.maxEditsPerFile,
        nudgeAt: guardPolicy.nudgeAt))
  }

  static func sandbox(_ config: SandboxConfig?) -> Sandbox {
    Sandbox(
      configured: config != nil,
      enabled: config?.enabled ?? false,
      network: config?.network ?? true,
      supported: ShellSandbox.isSupported,
      failIfUnavailable: config?.failIfUnavailable ?? true)
  }

  static func transport(_ policy: TransportPolicy) -> Transport {
    Transport(
      maxRequestRetries: policy.maxRequestRetries,
      maxStreamRetries: policy.maxStreamRetries,
      streamIdleTimeoutMs: policy.streamIdleTimeoutMs)
  }

  static func promptCache(_ policy: CachePolicy) -> PromptCache {
    PromptCache(anthropicBreakpoints: policy.anthropicBreakpoints, ttl: policy.ttl)
  }

  /// nil = the cache is off (`policies.manifestCache.enabled: false`).
  static func manifestCache(_ policy: ManifestCachePolicy?) -> ManifestCache {
    ManifestCache(enabled: policy != nil, ttlHours: policy.map { JSONOut.finite($0.ttl / 3600) ?? 0 })
  }

  static func compaction(_ policy: CompactionPolicy) -> Compaction {
    Compaction(
      threshold: policy.threshold,
      keepRecentToolResults: policy.keepRecentToolResults,
      clearMinChars: policy.clearMinChars,
      maxPerTurn: policy.maxPerTurn,
      keepRecentImages: policy.keepRecentImages)
  }

  static func checkpoints(_ config: CheckpointsConfig?, root: URL) -> Checkpoints {
    let config = config ?? CheckpointsConfig()
    return Checkpoints(
      enabled: config.isEnabled, root: root.path,
      maxFileBytes: config.policy.maxFileBytes, maxTurns: config.policy.maxTurns)
  }

  static func memory(_ config: MemoryConfig?, root: URL) -> Memory {
    let config = config ?? MemoryConfig()
    return Memory(
      enabled: config.isEnabled, root: root.path,
      maxLines: config.effectiveMaxLines, maxBytes: config.effectiveMaxBytes)
  }

  /// nil without a `web` block — the block's presence is the tool's opt-in.
  static func web(_ config: WebConfig?) -> Web? {
    guard let policy = config?.policy else { return nil }
    return Web(
      allowedDomains: policy.allowedDomains, deniedDomains: policy.deniedDomains,
      maxBytes: policy.maxBytes, timeoutSeconds: policy.timeoutSeconds)
  }

  static func subagents(_ defaults: TaskTool.Defaults) -> Subagents {
    Subagents(
      defaultModel: defaults.defaultModel,
      maxSteps: defaults.maxSteps == .max ? nil : defaults.maxSteps,
      budgetUSD: JSONOut.finite(defaults.budgetUSD),
      maxConcurrent: defaults.maxConcurrent,
      maxDepth: defaults.maxDepth,
      background: defaults.background,
      joinAtTurnEnd: defaults.joinAtTurnEnd,
      persistTranscripts: defaults.persistTranscripts)
  }
}

// MARK: - runs --json

/// One scoreboard row (`arnes runs --json`): the text view's `provider · model` line as
/// fields, with the sums the line prints and the averages it doesn't.
struct RunsScoreboardRow: Encodable, Equatable {
  let provider: String
  let model: String
  let runs: Int
  let finished: Int
  @Nullable var avgSteps: Double?
  @Nullable var avgCostUSD: Double?
  @Nullable var totalCostUSD: Double?
  /// Runs that carried a verifier verdict, and how many of those passed.
  let verified: Int
  let verifierPassed: Int
  let hookBlocks: Int
  let hookContinuations: Int
  /// Prompt tokens the runs sent in total, and how many of those were read from the provider's
  /// prompt cache (`RunRecord.promptTokens` / `cachedTokens`, summed; 0 when none reported).
  let promptTokens: Int
  let cachedTokens: Int
  /// How many of the verified runs stated each confidence (`RunRecord.verifierConfidence` —
  /// only a verifier that graded with a schema states one); 0 when none did.
  let verifierHigh: Int
  let verifierMedium: Int
  let verifierLow: Int

  enum CodingKeys: String, CodingKey {
    case provider, model, runs, finished, verified
    case avgSteps = "avg_steps"
    case avgCostUSD = "avg_cost_usd"
    case totalCostUSD = "total_cost_usd"
    case verifierPassed = "verifier_passed"
    case hookBlocks = "hook_blocks"
    case hookContinuations = "hook_continuations"
    case promptTokens = "prompt_tokens"
    case cachedTokens = "cached_tokens"
    case verifierHigh = "verifier_high"
    case verifierMedium = "verifier_medium"
    case verifierLow = "verifier_low"
  }
}

/// One `--by-agent` row: `provider · model · agent` (lead runs as `lead`) with the partial
/// count — runs that ended on `max_steps` or `budget`.
struct RunsAgentRow: Encodable, Equatable {
  let provider: String
  let model: String
  let agent: String
  let runs: Int
  @Nullable var avgSteps: Double?
  @Nullable var avgCostUSD: Double?
  @Nullable var totalCostUSD: Double?
  let partial: Int

  enum CodingKeys: String, CodingKey {
    case provider, model, agent, runs, partial
    case avgSteps = "avg_steps"
    case avgCostUSD = "avg_cost_usd"
    case totalCostUSD = "total_cost_usd"
  }
}

/// One audit-trail row (`--decisions`): a gated call and who decided it.
struct RunsDecisionRow: Encodable, Equatable {
  @Nullable var sessionId: String?
  @Nullable var turnIndex: Int?
  let startedAt: Date
  let model: String
  let tool: String
  let tier: String
  let decision: String
  let source: String
  @Nullable var reason: String?

  enum CodingKeys: String, CodingKey {
    case model, tool, tier, decision, source, reason
    case sessionId = "session_id"
    case turnIndex = "turn_index"
    case startedAt = "started_at"
  }
}

extension Runs {
  /// The scoreboard as rows, grouped and ordered exactly as `scoreboardLines` groups and
  /// orders its lines (records without a provider are OpenRouter's).
  static func scoreboardRows(_ records: [RunRecord]) -> [RunsScoreboardRow] {
    let grouped = Dictionary(grouping: records) { "\($0.provider ?? "openrouter")\u{0}\($0.model)" }
    return grouped.sorted(by: { $0.key < $1.key }).map { _, runs in
      let count = Double(runs.count)
      let cost = runs.reduce(0) { $0 + $1.costUSD }
      let verified = runs.filter { $0.verifierPassed != nil }
      return RunsScoreboardRow(
        provider: runs[0].provider ?? "openrouter",
        model: runs[0].model,
        runs: runs.count,
        finished: runs.filter(\.finished).count,
        avgSteps: JSONOut.finite(Double(runs.reduce(0) { $0 + $1.steps }) / count),
        avgCostUSD: JSONOut.finite(cost / count),
        totalCostUSD: JSONOut.finite(cost),
        verified: verified.count,
        verifierPassed: verified.filter { $0.verifierPassed == true }.count,
        hookBlocks: runs.reduce(0) { $0 + ($1.hookBlocks ?? 0) },
        hookContinuations: runs.reduce(0) { $0 + ($1.hookContinuations ?? 0) },
        promptTokens: runs.reduce(0) { $0 + ($1.promptTokens ?? 0) },
        cachedTokens: runs.reduce(0) { $0 + ($1.cachedTokens ?? 0) },
        verifierHigh: confidenceCounts(runs).high,
        verifierMedium: confidenceCounts(runs).medium,
        verifierLow: confidenceCounts(runs).low)
    }
  }

  /// `--by-agent` as rows, grouped like `byAgentLines`.
  static func agentRows(_ records: [RunRecord]) -> [RunsAgentRow] {
    let grouped = Dictionary(grouping: records) {
      "\($0.provider ?? "openrouter")\u{0}\($0.model)\u{0}\($0.agent ?? "lead")"
    }
    return grouped.sorted(by: { $0.key < $1.key }).map { _, runs in
      let count = Double(runs.count)
      let cost = runs.reduce(0) { $0 + $1.costUSD }
      return RunsAgentRow(
        provider: runs[0].provider ?? "openrouter",
        model: runs[0].model,
        agent: runs[0].agent ?? "lead",
        runs: runs.count,
        avgSteps: JSONOut.finite(Double(runs.reduce(0) { $0 + $1.steps }) / count),
        avgCostUSD: JSONOut.finite(cost / count),
        totalCostUSD: JSONOut.finite(cost),
        partial: runs.filter(\.partial).count)
    }
  }

  /// `--decisions` as rows: the last `limit` audited runs (as the text view shows), one row
  /// per gated call, in record order.
  static func decisionRows(_ records: [RunRecord], limit: Int) -> [RunsDecisionRow] {
    let audited = records.filter { !($0.decisions ?? []).isEmpty }
    return audited.suffix(max(1, limit)).flatMap { record in
      (record.decisions ?? []).map { row in
        RunsDecisionRow(
          sessionId: record.sessionId,
          turnIndex: record.turnIndex,
          startedAt: record.startedAt,
          model: record.model,
          tool: row.tool,
          tier: row.tier.rawValue,
          decision: row.decision.rawValue,
          source: row.source.rawValue,
          reason: row.reason)
      }
    }
  }

  /// The `--days` / `--agent` / `--dialect` / `--provider` filters, applied to both the text
  /// and the JSON views. Every filter unset returns the records unchanged, so an unfiltered
  /// scoreboard is byte-identical to before the flags existed. `--agent lead` selects runs
  /// with no agent; records without a provider count as `openrouter`.
  static func filter(
    _ records: [RunRecord],
    days: Int?,
    agent: String?,
    dialect: String?,
    provider: String?,
    now: Date = Date())
    -> [RunRecord]
  {
    var kept = records
    if let days {
      let since = now.addingTimeInterval(-Double(max(0, days)) * 86_400)
      kept = kept.filter { $0.startedAt >= since }
    }
    if let agent, !agent.isEmpty {
      kept = kept.filter { ($0.agent ?? "lead") == agent }
    }
    if let dialect, !dialect.isEmpty {
      kept = kept.filter { $0.dialect == dialect }
    }
    if let provider, !provider.isEmpty {
      kept = kept.filter { ($0.provider ?? "openrouter") == provider }
    }
    return kept
  }
}

// MARK: - sessions --json

/// One transcript, lead or nested (`--agents`). A DTO, not `SessionMeta: Encodable` — the
/// Kit type carries no wire commitment.
struct SessionRow: Encodable, Equatable {
  let id: String
  @Nullable var createdAt: Date?
  let updatedAt: Date
  @Nullable var name: String?
  @Nullable var model: String?
  @Nullable var cwd: String?
  let messageCount: Int
  @Nullable var forkedFrom: String?
  @Nullable var parent: String?
  @Nullable var agent: String?
  @Nullable var depth: Int?
  @Nullable var origin: String?

  init(_ meta: SessionMeta) {
    id = meta.id
    createdAt = meta.createdAt
    updatedAt = meta.updatedAt
    name = meta.name
    model = meta.model
    cwd = meta.cwd
    messageCount = meta.messageCount
    forkedFrom = meta.forkedFrom
    parent = meta.parent
    agent = meta.agent
    depth = meta.depth
    origin = meta.origin
  }

  enum CodingKeys: String, CodingKey {
    case id, name, model, cwd, parent, agent, depth, origin
    case createdAt = "created_at"
    case updatedAt = "updated_at"
    case messageCount = "message_count"
    case forkedFrom = "forked_from"
  }
}

// MARK: - skills --json

struct SkillRow: Encodable, Equatable {
  let name: String
  let description: String
  /// The skill's directory as a full path, or `built-in`.
  let source: String
  @Nullable var directory: String?
  /// Parsed, not applied (see `arnes skills`): the frontmatter `allowed-tools` and `model`.
  @Nullable var allowedTools: [String]?
  @Nullable var model: String?
  let warnings: [String]
  let builtin: Bool

  init(_ skill: Skill) {
    name = skill.name
    description = skill.description
    source = skill.sourceDescription
    directory = skill.directory?.path
    allowedTools = skill.allowedTools
    model = skill.model
    warnings = skill.warnings
    builtin = skill.directory == nil
  }

  enum CodingKeys: String, CodingKey {
    case name, description, source, directory, model, warnings, builtin
    case allowedTools = "allowed_tools"
  }
}

// MARK: - agents --json

struct AgentRow: Encodable, Equatable {
  let name: String
  let description: String
  @Nullable var model: String?
  @Nullable var tools: [String]?
  @Nullable var disallowedTools: [String]?
  /// `inherit` or `readOnly` — the narrow-only posture the file declares.
  let permissionMode: String
  @Nullable var maxSteps: Int?
  @Nullable var budgetUSD: Double?
  @Nullable var effort: String?
  @Nullable var skills: [String]?
  let background: Bool
  let fork: Bool
  @Nullable var isolation: String?
  /// The file's own warnings plus the preload warnings `arnes agents` prints.
  let warnings: [String]
  /// The agent file as a full path, or `built-in`.
  let source: String
  let builtin: Bool

  init(_ agent: AgentDefinition, extraWarnings: [String] = []) {
    name = agent.name
    description = agent.description
    model = agent.model
    tools = agent.tools
    disallowedTools = agent.disallowedTools
    permissionMode = agent.permissionMode.rawValue
    maxSteps = agent.maxSteps
    budgetUSD = JSONOut.finite(agent.budgetUSD)
    effort = agent.effort?.rawValue
    skills = agent.skills
    background = agent.background
    fork = agent.fork
    isolation = agent.isolation
    warnings = agent.warnings + extraWarnings
    source = agent.source?.path ?? "built-in"
    builtin = agent.source == nil
  }

  enum CodingKeys: String, CodingKey {
    case name, description, model, tools, effort, skills, background, fork, isolation, warnings, source, builtin
    case disallowedTools = "disallowed_tools"
    case permissionMode = "permission_mode"
    case maxSteps = "max_steps"
    case budgetUSD = "budget_usd"
  }
}

// MARK: - hooks --json

/// One configured hook. The command text is what the text view prints; an environment
/// value never appears here (the payload a hook reads is not part of its definition).
struct HookRow: Encodable, Equatable {
  @Nullable var id: String?
  let event: String
  @Nullable var matcher: String?
  /// `command` or `prompt`.
  let type: String
  let commandOrPrompt: String
  /// A prompt hook's model: its own, else the provider's `bashJudge`; nil = unusable.
  @Nullable var model: String?
  @Nullable var when: [String: String]?
  @Nullable var agent: String?
  let enabled: Bool
  let failClosed: Bool
  let timeoutSeconds: Int
  @Nullable var description: String?
  /// `user` or `project`.
  let source: String
  /// Whether the hook will run: a user hook always, a project hook only when its directory is
  /// trusted and its hash was approved (`arnes hooks trust`).
  let trusted: Bool
  /// `trusted`, `changed`, or `untrustedDirectory` — why a project hook isn't running.
  let trust: String

  init(_ hook: LoadedHook, defaultPromptModel: String?) {
    let definition = hook.definition
    id = definition.id
    event = definition.event.rawValue
    matcher = definition.matcher
    type = definition.type.rawValue
    commandOrPrompt = definition.type == .prompt ? (definition.prompt ?? "") : definition.command
    model = definition.type == .prompt ? (definition.model ?? defaultPromptModel) : nil
    when = definition.when
    agent = definition.agent
    enabled = definition.isEnabled
    failClosed = definition.failClosed ?? false
    timeoutSeconds = definition.timeoutSeconds ?? HookEngine.defaultTimeoutSeconds
    description = definition.description
    source = definition.source.rawValue
    trusted = hook.trust == .trusted
    trust = hook.trust.rawValue
  }

  enum CodingKeys: String, CodingKey {
    case id, event, matcher, type, model, when, agent, enabled, description, source, trusted, trust
    case commandOrPrompt = "command_or_prompt"
    case failClosed = "fail_closed"
    case timeoutSeconds = "timeout_seconds"
  }
}

// MARK: - mcp --json

/// One MCP server as `arnes mcp` connects it. `host_or_command` is the transport line's
/// tail — a command or a host, never a header value or a URL path.
struct MCPServerRow: Encodable, Equatable {
  let name: String
  /// `stdio` or `http`.
  let transport: String
  let hostOrCommand: String
  let required: Bool
  let enabled: Bool
  let connected: Bool
  let tools: [String]
  let prompts: [String]
  @Nullable var error: String?
  /// Remote tool names withheld because their definition changed since first pinned
  /// (`arnes mcp --approve <server>` re-pins them). Empty when none.
  let withheldTools: [String]
  /// `user` (the ambient file or `--mcp-config`) or `project` (the repository's `.mcp.json`,
  /// loaded untrusted in a trusted directory) — X9, additive.
  let scope: String

  init(_ status: MCPToolProvider.ServerStatus, tools: [String], prompts: [String], scope: String = "user") {
    name = status.server
    // `ServerStatus.transport` reads `stdio <command…>` / `http <host>`.
    let parts = status.transport.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    transport = parts.first.map(String.init) ?? "stdio"
    hostOrCommand = parts.count > 1 ? String(parts[1]) : ""
    required = status.required
    enabled = !status.disabled
    connected = !status.disabled && status.error == nil
    self.tools = tools
    self.prompts = prompts
    error = status.error
    withheldTools = status.withheldTools
    self.scope = scope
  }

  enum CodingKeys: String, CodingKey {
    case name, transport, required, enabled, connected, tools, prompts, error, scope
    case hostOrCommand = "host_or_command"
    case withheldTools = "withheld_tools"
  }
}

/// One configured MCP server in one scope, as `arnes mcp get --json` / `list --json` print it
/// (X9) — offline, from the config files alone. Never a header or env value: `env_keys` and
/// `header_names` name what is set, nothing more. A project entry carries the posture a run
/// gives it (`trust: untrusted`, never required). Keys are additive forever.
struct MCPEntryRow: Encodable, Equatable {
  let name: String
  /// `user` or `project`.
  let scope: String
  /// The file the entry came from.
  let file: String
  /// `stdio` or `http`.
  let transport: String
  let hostOrCommand: String
  let required: Bool
  let enabled: Bool
  /// `trusted` or `untrusted`.
  let trust: String
  let envKeys: [String]
  let headerNames: [String]
  /// A project entry with a user entry of the same name — the user's wins, this one never loads.
  let shadowed: Bool
  /// Project entries only: whether the directory is trusted (else the file is not loaded).
  @Nullable var directoryTrusted: Bool?

  init(_ entry: MCPConfiguredEntry, files: McpFiles) {
    name = entry.name
    scope = entry.scope.label
    file = entry.file.path
    let parts = entry.config.transportSummary.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    transport = parts.first.map(String.init) ?? "stdio"
    hostOrCommand = parts.count > 1 ? String(parts[1]) : ""
    required = entry.config.isRequired
    enabled = entry.config.isEnabled
    trust = entry.config.isUntrusted ? "untrusted" : "trusted"
    envKeys = (entry.config.env ?? [:]).keys.sorted()
    headerNames = (entry.config.headers ?? [:]).keys.sorted()
    shadowed = entry.shadowed
    directoryTrusted = entry.directoryTrusted
  }

  enum CodingKeys: String, CodingKey {
    case name, scope, file, transport, required, enabled, trust, shadowed
    case hostOrCommand = "host_or_command"
    case envKeys = "env_keys"
    case headerNames = "header_names"
    case directoryTrusted = "directory_trusted"
  }
}

// MARK: - eval --json

/// One model × dialect of an `arnes eval --json` run: the scoreboard row's figures plus
/// pass@k / pass^k (`null` for a single trial per task) and `k`, the trials per task.
struct EvalModelRow: Encodable, Equatable {
  let model: String
  @Nullable var dialect: String?
  let trials: Int
  let passed: Int
  @Nullable var passRate: Double?
  @Nullable var passAtK: Double?
  @Nullable var passPowK: Double?
  let k: Int
  @Nullable var costUSD: Double?
  @Nullable var graderCostUSD: Double?
  @Nullable var avgSteps: Double?
  @Nullable var avgSeconds: Double?
  let errors: Int

  init(_ summary: EvalModelSummary) {
    model = summary.model
    dialect = summary.dialect
    trials = summary.trials
    passed = summary.passed
    passRate = JSONOut.finite(summary.passRate)
    passAtK = JSONOut.finite(EvalReport.passAtK(summary))
    passPowK = JSONOut.finite(EvalReport.passPowK(summary))
    k = summary.trialsPerTask
    costUSD = JSONOut.finite(summary.costUSD)
    graderCostUSD = JSONOut.finite(summary.graderCostUSD)
    avgSteps = JSONOut.finite(summary.avgSteps)
    avgSeconds = JSONOut.finite(summary.avgSeconds)
    errors = summary.errors
  }

  enum CodingKeys: String, CodingKey {
    case model, dialect, trials, passed, k, errors
    case passRate = "pass_rate"
    case passAtK = "pass_at_k"
    case passPowK = "pass_pow_k"
    case costUSD = "cost_usd"
    case graderCostUSD = "grader_cost_usd"
    case avgSteps = "avg_steps"
    case avgSeconds = "avg_seconds"
  }
}

/// One task × model × dialect set against its baseline (a regression, a fix, or — with
/// `previous_pass_rate` null — a key the window held no row for).
struct EvalRegressionRow: Encodable, Equatable {
  let task: String
  let model: String
  @Nullable var dialect: String?
  @Nullable var previousPassRate: Double?
  let previousTrials: Int
  @Nullable var currentPassRate: Double?
  let currentTrials: Int

  init(_ entry: EvalRegression) {
    task = entry.taskId
    model = entry.model
    dialect = entry.dialect
    previousPassRate = JSONOut.finite(entry.previousPassRate)
    previousTrials = entry.previousTrials
    currentPassRate = JSONOut.finite(entry.currentPassRate)
    currentTrials = entry.currentTrials
  }

  enum CodingKeys: String, CodingKey {
    case task, model, dialect
    case previousPassRate = "previous_pass_rate"
    case previousTrials = "previous_trials"
    case currentPassRate = "current_pass_rate"
    case currentTrials = "current_trials"
  }
}

/// One trial as the run recorded it. `passed` is the counted verdict (`EvalOutcome.isPass`:
/// the graded one when the task had graders, else the check's); `check_passed` the check's.
struct EvalOutcomeRow: Encodable, Equatable {
  let suite: String
  let task: String
  let model: String
  @Nullable var dialect: String?
  let trial: Int
  let passed: Bool
  let checkPassed: Bool
  @Nullable var rubricScore: Double?
  @Nullable var rubricPassed: Bool?
  @Nullable var limitsPassed: Bool?
  @Nullable var verifierPassed: Bool?
  @Nullable var costUSD: Double?
  @Nullable var graderCostUSD: Double?
  let steps: Int
  let toolCalls: Int
  @Nullable var seconds: Double?
  @Nullable var error: String?
  @Nullable var sessionId: String?
  @Nullable var runId: String?
  @Nullable var stopReason: String?
  @Nullable var sandboxed: Bool?
  let startedAt: Date
  /// The A/B arm the row was written under (`arnes eval --label`); null for an unlabelled row.
  @Nullable var label: String?

  init(_ outcome: EvalOutcome) {
    suite = outcome.suite
    task = outcome.taskId
    model = outcome.model
    dialect = outcome.dialect
    trial = outcome.trial
    passed = outcome.isPass
    checkPassed = outcome.checkPassed
    rubricScore = JSONOut.finite(outcome.rubricScore)
    rubricPassed = outcome.rubricPassed
    limitsPassed = outcome.limitsPassed
    verifierPassed = outcome.verifierPassed
    costUSD = JSONOut.finite(outcome.costUSD)
    graderCostUSD = JSONOut.finite(outcome.graderCostUSD)
    steps = outcome.steps
    toolCalls = outcome.toolCalls
    seconds = JSONOut.finite(outcome.durationSeconds)
    error = outcome.error
    sessionId = outcome.sessionId
    runId = outcome.runId
    stopReason = outcome.stopReason
    sandboxed = outcome.sandboxed
    startedAt = outcome.startedAt
    label = outcome.label
  }

  enum CodingKeys: String, CodingKey {
    case suite, task, model, dialect, trial, passed, steps, seconds, error, sandboxed
    case label
    case checkPassed = "check_passed"
    case rubricScore = "rubric_score"
    case rubricPassed = "rubric_passed"
    case limitsPassed = "limits_passed"
    case verifierPassed = "verifier_passed"
    case costUSD = "cost_usd"
    case graderCostUSD = "grader_cost_usd"
    case toolCalls = "tool_calls"
    case sessionId = "session_id"
    case runId = "run_id"
    case stopReason = "stop_reason"
    case startedAt = "started_at"
  }
}

/// The gate the run was held to and whether it passed.
struct EvalGateRow: Encodable, Equatable {
  @Nullable var minPass: Double?
  let failOnRegression: Bool
  let passed: Bool

  enum CodingKeys: String, CodingKey {
    case passed
    case minPass = "min_pass"
    case failOnRegression = "fail_on_regression"
  }
}

/// The one document `arnes eval --json` prints: `type: "eval"`, the suite, one row per
/// model × dialect, the comparison (`regressions`/`fixes`/`no_baseline` — null without
/// `--compare`), every outcome, the gate and the exit code the process ends with.
struct EvalReportDocument: Encodable, Equatable {
  let type = "eval"
  let suite: String
  let models: [EvalModelRow]
  /// The `--compare` spelling (`last`, `7d`); null when the run was not compared.
  @Nullable var compare: String?
  @Nullable var regressions: [EvalRegressionRow]?
  @Nullable var fixes: [EvalRegressionRow]?
  @Nullable var noBaseline: [EvalRegressionRow]?
  let outcomes: [EvalOutcomeRow]
  let gate: EvalGateRow
  let exitCode: Int32
  /// The models `-m` named more than once (directly, or through an alias resolving to the same
  /// id) that the run collapsed to one — each once, in encounter order, alias-resolved; `[]` when
  /// none. Always present, never null (Q2).
  let collapsedModels: [String]

  init(
    suite: String,
    outcomes: [EvalOutcome],
    summaries: [EvalModelSummary],
    comparison: EvalComparison?,
    compare: String?,
    gate: EvalGate,
    exitCode: Int32,
    collapsedModels: [String] = [])
  {
    self.suite = suite
    self.collapsedModels = collapsedModels
    models = summaries.map(EvalModelRow.init)
    self.compare = compare
    regressions = comparison.map { $0.regressions.map(EvalRegressionRow.init) }
    fixes = comparison.map { $0.fixes.map(EvalRegressionRow.init) }
    noBaseline = comparison.map { $0.withoutBaseline.map(EvalRegressionRow.init) }
    self.outcomes = outcomes.map(EvalOutcomeRow.init)
    self.gate = EvalGateRow(minPass: JSONOut.finite(gate.minPass), failOnRegression: gate.failOnRegression, passed: exitCode == 0)
    self.exitCode = exitCode
  }

  enum CodingKeys: String, CodingKey {
    case type, suite, models, compare, regressions, fixes, outcomes, gate
    case noBaseline = "no_baseline"
    case exitCode = "exit_code"
    case collapsedModels = "collapsed_models"
  }
}

// MARK: - evals show --json

/// One suite × model × dialect of the eval history (`arnes evals show --json`), grouped and
/// ordered as the text table groups and orders its rows.
struct EvalHistoryJSONRow: Encodable, Equatable {
  let suite: String
  let model: String
  @Nullable var dialect: String?
  let trials: Int
  let passed: Int
  @Nullable var passRate: Double?
  @Nullable var costUSD: Double?
  let lastRun: Date
  /// V1: how many of the rows' loop-1 verifier verdicts agreed with the bash check, over how
  /// many rows carried a verdict (0 when none did); `verifierAgreement` is the fraction (null
  /// when there were no verdicts) — the text table's `verifier` column, as JSON.
  let verifierAgreements: Int
  let verifierVerdicts: Int
  @Nullable var verifierAgreement: Double?

  enum CodingKeys: String, CodingKey {
    case suite, model, dialect, trials, passed
    case passRate = "pass_rate"
    case costUSD = "cost_usd"
    case lastRun = "last_run"
    case verifierAgreements = "verifier_agreements"
    case verifierVerdicts = "verifier_verdicts"
    case verifierAgreement = "verifier_agreement"
  }
}

/// The one document `arnes evals show --json` prints.
struct EvalsDocument: Encodable, Equatable {
  let type = "evals"
  let rows: [EvalHistoryJSONRow]
}

extension EvalsShow {
  /// The history as rows over the filtered outcomes: suite × model × dialect, suite up, pass
  /// rate down, model up, then dialect — the text table's grouping and order.
  static func jsonRows(_ outcomes: [EvalOutcome]) -> [EvalHistoryJSONRow] {
    struct Key: Hashable {
      let suite: String
      let model: String
      let dialect: String?
    }
    let grouped = Dictionary(grouping: outcomes) { Key(suite: $0.suite, model: $0.model, dialect: $0.dialect) }
    return grouped.map { key, rows in
      let passed = rows.filter(\.isPass).count
      // Verifier-vs-check agreement over the rows that carried a verdict (V1's column).
      let verdicts = rows.filter { $0.verifierPassed != nil }
      let agreements = verdicts.filter { $0.verifierPassed == $0.checkPassed }.count
      return EvalHistoryJSONRow(
        suite: key.suite,
        model: key.model,
        dialect: key.dialect,
        trials: rows.count,
        passed: passed,
        passRate: JSONOut.finite(rows.isEmpty ? 0 : Double(passed) / Double(rows.count)),
        costUSD: JSONOut.finite(rows.reduce(0) { $0 + $1.costUSD }),
        lastRun: rows.map(\.startedAt).max() ?? Date.distantPast,
        verifierAgreements: agreements,
        verifierVerdicts: verdicts.count,
        verifierAgreement: verdicts.isEmpty ? nil : JSONOut.finite(Double(agreements) / Double(verdicts.count)))
    }
    .sorted {
      if $0.suite != $1.suite { return $0.suite < $1.suite }
      if $0.passRate != $1.passRate { return ($0.passRate ?? 0) > ($1.passRate ?? 0) }
      if $0.model != $1.model { return $0.model < $1.model }
      return ($0.dialect ?? "") < ($1.dialect ?? "")
    }
  }
}

// MARK: - memory --json

/// One project (or agent scope) in `arnes memory list --json`. Keys are additive forever; every
/// documented key is present in every row.
struct MemoryRow: Encodable, Equatable {
  let key: String
  let directory: String
  let indexPath: String
  /// Whether `MEMORY.md` exists with something in it.
  let exists: Bool
  @Nullable var lines: Int?
  @Nullable var bytes: Int?
  /// Lines that ride the prompt (the cap applied); null when there is no index.
  @Nullable var loadedLines: Int?
  let truncated: Bool
  /// The S6 scanner's pattern names when the index looked like instructions.
  let flagged: [String]
  /// Agent scopes kept beneath this project, by name.
  let agents: [String]
  /// Whether this is the current working directory's project.
  let current: Bool

  init(_ store: MemoryStore, current: Bool) {
    let loaded = store.load()
    key = store.key
    directory = store.directory.path
    indexPath = store.indexURL.path
    exists = loaded != nil
    lines = loaded?.lineCount
    bytes = loaded?.byteCount
    loadedLines = loaded?.loadedLines
    truncated = loaded?.truncated ?? false
    flagged = loaded?.flaggedPatterns ?? []
    agents = store.agentScopes().map(\.key)
    self.current = current
  }

  enum CodingKeys: String, CodingKey {
    case key, directory, exists, lines, bytes, truncated, flagged, agents, current
    case indexPath = "index_path"
    case loadedLines = "loaded_lines"
  }
}

/// `arnes memory show --json`: one scope's index verbatim.
struct MemoryShowReport: Encodable, Equatable {
  let key: String
  let directory: String
  let indexPath: String
  let exists: Bool
  @Nullable var lines: Int?
  @Nullable var bytes: Int?
  let flagged: [String]
  /// The whole index as written (not capped, not scanned); null when there is none.
  @Nullable var text: String?

  init(_ store: MemoryStore) {
    let loaded = store.load()
    key = store.key
    directory = store.directory.path
    indexPath = store.indexURL.path
    exists = loaded != nil
    lines = loaded?.lineCount
    bytes = loaded?.byteCount
    flagged = loaded?.flaggedPatterns ?? []
    text = loaded == nil ? nil : store.indexText()
  }

  enum CodingKeys: String, CodingKey {
    case key, directory, exists, lines, bytes, flagged, text
    case indexPath = "index_path"
  }
}

// MARK: - evals transcript --json

/// `arnes evals transcript <id> --json`: one trial's transcript with the eval row it belongs
/// to. `entries` are the transcript's lines **as stored** — `TranscriptEntry`, the on-disk JSONL
/// contract (kinds `meta`, `message`, `model_change`, `cost`, `clear`, `compaction`,
/// `effort_change`, `rewind`), re-encoded with sorted keys; the eval fields come from the
/// matching `EvalOutcome` row and are null when it was pruned. Keys are additive forever (H1).
struct EvalTranscriptDocument: Encodable {
  let type = "eval_transcript"
  let sessionId: String
  @Nullable var runId: String?
  @Nullable var suite: String?
  @Nullable var task: String?
  @Nullable var model: String?
  @Nullable var dialect: String?
  /// The graded verdict (`isPass`), null without a row.
  @Nullable var passed: Bool?
  @Nullable var costUSD: Double?
  let entries: [TranscriptEntry]

  init(sessionId: String, row: EvalOutcome?, entries: [TranscriptEntry]) {
    self.sessionId = sessionId
    runId = row?.runId
    suite = row?.suite
    task = row?.taskId
    model = row?.model
    dialect = row?.dialect
    passed = row?.isPass
    costUSD = JSONOut.finite(row?.costUSD)
    self.entries = entries
  }

  enum CodingKeys: String, CodingKey {
    case type, suite, task, model, dialect, passed, entries
    case sessionId = "session_id"
    case runId = "run_id"
    case costUSD = "cost_usd"
  }
}

/// One kept transcript in `arnes evals transcript --json` (no id): what the text listing
/// prints, as data — the store's meta plus the row's suite/task/verdict, null without a row.
struct EvalTranscriptRow: Encodable, Equatable {
  let sessionId: String
  let updatedAt: Date
  @Nullable var model: String?
  @Nullable var suite: String?
  @Nullable var task: String?
  @Nullable var passed: Bool?

  enum CodingKeys: String, CodingKey {
    case model, suite, task, passed
    case sessionId = "session_id"
    case updatedAt = "updated_at"
  }
}

/// The one document `arnes evals transcript --json` prints without an id.
struct EvalTranscriptsDocument: Encodable, Equatable {
  let type = "eval_transcripts"
  let rows: [EvalTranscriptRow]
}
