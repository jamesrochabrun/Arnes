import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

/// Appends one line to a JSONL file with `O_APPEND` semantics, so concurrent writers
/// (parallel panel candidates) never clobber each other the way seek-then-write would.
/// New files are owner-only (see `SecureFiles`).
func appendJSONLLine(_ line: Data, to url: URL) throws {
  let descriptor = try SecureFiles.openForAppend(url)
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  defer { close(descriptor) }
  try handle.write(contentsOf: line)
}

// MARK: - StopReason

/// Why a turn ended. One vocabulary for the `RunRecord`, the headless result envelope and
/// exit codes, so "the run stopped" is never ambiguous between "finished", "ran out of
/// steps" and "was cut off". Raw values are the stable snake_case spelling on disk.
public enum StopReason: String, Codable, Sendable, CaseIterable {
  /// The model stopped calling tools and delivered its reply.
  case completed
  /// `maxStepsPerTurn` ran out before the model finished.
  case maxSteps = "max_steps"
  /// The cost budget was reached before the next step.
  case budget
  /// A wall-clock limit ended the run (headless `--timeout`, eval/panel deadlines).
  case timeout
  /// Cancelled: Ctrl-C, `Session.interrupt`, or a signal.
  case interrupted
  /// A transport or provider error ended the turn.
  case error
  /// A required structured output never validated.
  case structuredOutputFailed = "structured_output_failed"
  /// The loop guard stopped a model repeating itself (identical calls, consecutive errors).
  case stuck
  /// Repeated permission denials in one turn — the model kept asking for what it can't have.
  case deniedLoop = "denied_loop"
  /// The reply hit the output-token limit mid-answer.
  case truncated
  /// Plan mode: the model proposed a plan and nothing was executed.
  case planProposed = "plan_proposed"
  /// A hook ended the turn (`continue: false`).
  case hookStopped = "hook_stopped"
}

// MARK: - ToolDecision

/// One row of the permission audit trail: what was asked for, which gate answered, and
/// what it said. Written for every *gated* call — a free read-only call is not a decision,
/// so `grep` doesn't fill the record with noise.
///
/// The point is answerability after the fact: "the agent pushed to main — who allowed
/// that?" is a question about `source`, not about the tool name. Rows ride the turn's
/// `RunRecord` (`decisions`) and print with `arnes runs --decisions`.
public struct ToolDecision: Codable, Sendable, Equatable {
  /// The permission tier the call was classified at, in the on-disk spelling.
  public enum Tier: String, Codable, Sendable {
    case readOnly = "read_only"
    case mutating
    case sensitive

    public init(_ permission: ToolPermission) {
      switch permission {
      case .readOnly: self = .readOnly
      case .mutating: self = .mutating
      case .sensitive: self = .sensitive
      }
    }
  }

  public enum Outcome: String, Codable, Sendable {
    case allow
    case deny
  }

  /// Which layer answered. Ordered roughly by precedence in `Session.permissionDenial`.
  public enum Source: String, Codable, Sendable {
    /// An execute-time floor refused it (catastrophic command, harness file) — no gate
    /// could have approved it.
    case floor
    /// A PreToolUse hook blocked the call.
    case hook
    /// An entry in the rules file (`~/.arnes/rules.json`).
    case rule
    /// The permission mode (`plan` denies, `bypass`/`acceptEdits` approve), or a
    /// delegate that stands in for one (`--safe`).
    case mode
    /// A standing "always allow this session" grant.
    case grant
    /// A human answered the prompt.
    case user
    /// The `bashJudge` escalated a call the deterministic layer had already approved.
    case judge
    /// An unattended run approving its own work (`--yes`).
    case yes
  }

  public var tool: String
  public var tier: Tier
  public var decision: Outcome
  public var source: Source
  /// Why, when there is a why — the denial text, the rule that fired, the judge's note.
  public var reason: String?

  public init(tool: String, tier: Tier, decision: Outcome, source: Source, reason: String? = nil) {
    self.tool = tool
    self.tier = tier
    self.decision = decision
    self.source = source
    self.reason = reason.map { String($0.prefix(ToolDecision.maxReasonLength)) }
  }

  /// Reasons are trimmed: an audit row is a pointer, not a transcript.
  public static let maxReasonLength = 200

  /// Rows per record. A pathological turn (a model hammering a denied tool) must not turn
  /// `runs.jsonl` into a log file.
  public static let maxPerRecord = 200

  /// The prefix every execute-time floor refusal carries (`BashTool`'s catastrophic
  /// block, the write tools' harness/TOCTOU refusals). The loop reads it to record a
  /// `.floor` row for a call no permission gate ever saw.
  public static let floorRefusalPrefix = "error: refused — "

  enum CodingKeys: String, CodingKey { case tool, tier, decision, source, reason }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    tool = try c.decode(String.self, forKey: .tool)
    // A tier/decision/source spelling this build doesn't know (written by a newer arnes)
    // reads as its closest safe neighbor rather than dropping the whole record.
    tier = try Tier(rawValue: c.decode(String.self, forKey: .tier)) ?? .mutating
    decision = try Outcome(rawValue: c.decode(String.self, forKey: .decision)) ?? .deny
    source = try Source(rawValue: c.decode(String.self, forKey: .source)) ?? .user
    reason = try c.decodeIfPresent(String.self, forKey: .reason)
  }
}

// MARK: - ToolStat

/// Per-tool telemetry for one turn (`RunRecord.toolStats`): how often the model called the tool
/// and how many of those calls came back failed — an `error:` result, whether the tool ran and
/// failed or the loop refused to run it over malformed/missing arguments. Refusals (permission,
/// hook, floor) are not errors here: they never reached the tool and `deniedCalls` counts them.
public struct ToolStat: Codable, Sendable, Equatable {
  public var calls: Int
  public var errors: Int

  public init(calls: Int = 0, errors: Int = 0) {
    self.calls = calls
    self.errors = errors
  }
}

/// One row of the evaluation substrate. Every agent execution appends a record;
/// the panel judge (loop 2) and routing scoreboard (loop 3) read them back.
public struct RunRecord: Codable, Sendable {
  public var id: String
  public var startedAt: Date
  public var task: String
  public var model: String
  public var dialect: String
  public var packFamily: String
  public var steps: Int
  public var toolCalls: Int
  /// The models that actually served steps (post-routing) — differs from `model`
  /// when using `openrouter/auto` or fallbacks.
  public var routedModels: [String]
  /// Total USD cost, summed from `usage.cost` across every request in the run.
  public var costUSD: Double
  public var finished: Bool
  /// Loop-1 verifier verdict, when a verifier ran.
  public var verifierPassed: Bool?
  public var summary: String?
  /// The interactive session this turn belongs to (nil for pre-v0.2 records).
  public var sessionId: String?
  /// Zero-based turn number within the session.
  public var turnIndex: Int?
  /// Subagent name when this run was delegated via the task tool; nil for lead runs.
  public var agent: String?
  /// The provider the run went through (`openrouter`, or a configured gateway name);
  /// nil for records written before providers existed. Keeps the scoreboard honest
  /// when the same slug means different things behind different routers.
  public var provider: String?
  /// Why the turn ended; nil for records written before the field existed. `finished`
  /// stays the coarse flag (`stopReason == .completed`).
  public var stopReason: StopReason?
  /// Tool calls a PreToolUse hook denied this turn; nil for records written before hooks.
  public var hookBlocks: Int?
  /// Times a Stop hook sent the model back to work this turn (`decision: block`); nil for
  /// records written before the field existed and for turns no hook continued.
  public var hookContinuations: Int?
  /// The permission audit trail: one row per *gated* call, with the gate that answered.
  /// nil for records written before the field existed (and for turns that gated nothing).
  public var decisions: [ToolDecision]?
  /// Tool calls refused this turn — by the permission gate or a PreToolUse hook (the
  /// execute-time floor refusals ride `decisions` only). nil for records written before the
  /// field existed and for turns that refused nothing; the headless envelope reads it as 0.
  public var deniedCalls: Int?
  /// Prompt tokens summed over the turn's requests, when the provider reported usage. nil
  /// for older records and for providers that report nothing.
  public var promptTokens: Int?
  /// Completion tokens summed over the turn's requests, when reported.
  public var completionTokens: Int?
  /// What the turn's hooks themselves spent — prompt hooks, the command judge, paying
  /// handlers — already included in `costUSD`, broken out so a scoreboard can tell guardrail
  /// spend from model spend. nil for records written before the field existed and for turns
  /// whose hooks spent nothing.
  public var hookCostUSD: Double?
  /// Lineage of a delegated run: the session that spawned this one (`agent` names which
  /// definition ran; the nested session's own id is `sessionId`). nil for lead runs and for
  /// records written before the field existed.
  public var parentSessionId: String?
  /// How deep the run nests: 0 for a lead, 1 for its subagents. nil for older records.
  public var depth: Int?
  /// Whether a delegated run was started detached (`task` with `background: true`). Written
  /// for nested runs only; nil for lead runs and older records.
  public var background: Bool?

  /// A delegated run that was cut short by a cap — what the lead saw prefixed
  /// `[subagent hit its …]`. Derived, so no field: `stopReason ∈ {max_steps, budget}`.
  public var partial: Bool {
    stopReason == .maxSteps || stopReason == .budget
  }

  /// Tool results the universal output cap cut this turn (`ToolOutputLimiter`; the rest of each
  /// went to a spill file when one was configured). nil for older records and for turns where
  /// nothing was cut.
  public var truncatedResults: Int?
  /// Calls and failures per tool name this turn. nil for older records and for turns that
  /// called no tool.
  public var toolStats: [String: ToolStat]?
  /// `[arnes]` nudges the session sent the model this turn — the stall nudge ("your reply
  /// ended without a tool call") and the loop guard's. nil for older records and for turns
  /// that needed none.
  public var nudges: Int?
  /// Whether the structured answer a run asked for (`Configuration.outputSchema`) validated:
  /// true when it did, false when every attempt came back invalid (`stopReason` is then
  /// `structured_output_failed`). nil for runs that asked for none and for older records.
  public var structuredOutputValid: Bool?
  /// The validated object itself, when it fits `RunRecord.maxStructuredOutputBytes` encoded —
  /// a larger one is left off the record (the headless envelope still carries it from the
  /// run's result) so one run can't bloat `runs.jsonl`. nil otherwise.
  public var structuredOutput: JSONValue?
  /// Reasoning entries the turn's steps *produced* and carried for replay (signed `thinking`
  /// blocks, `redacted_thinking`, Responses `encrypted_content`, chat `reasoning_details`
  /// entries) — a natural-finish text step's included. What the requests actually *replayed* is
  /// `reasoningReplayed`: a row with this set and that nil produced reasoning no later request
  /// sent back. nil for older records and for turns that produced none.
  public var reasoningBlocks: Int?
  /// Reasoning entries this turn's requests *replayed* — Anthropic thinking blocks put back into
  /// a `/messages` request while thinking was enabled for that step, `reasoning` items echoed
  /// into a `/responses` request, `reasoning_details` sent on a chat request to a provider that
  /// replays them (`ProviderTraits.replaysReasoningDetails`) — summed over the steps: the
  /// telemetry that says the round-trip happened. nil for older records and for turns whose
  /// requests replayed nothing.
  public var reasoningReplayed: Int?
  /// The loop-1 verifier's stated confidence (`high` / `medium` / `low`) when it graded
  /// against a schema; nil for a one-line PASS/FAIL verdict, for turns without a verifier, and
  /// for rows written before the field.
  public var verifierConfidence: String?
  /// Secrets the guard replaced in this turn's tool results before they reached history or the
  /// spill (`SecretScrubber`). nil for older records and for turns that redacted nothing.
  public var redactions: Int?
  /// Tool results the scanner flagged as instruction-shaped this turn (`OutputScanner`). nil
  /// for older records and for turns with none.
  public var flagged: Int?
  /// True on every turn written after the session read untrusted content — a scanner flag or an
  /// untrusted MCP server's result — this turn or an earlier one. nil until then and for older
  /// records.
  public var tainted: Bool?
  /// Background shell jobs this turn started (`bash … background: true`). nil for older records
  /// and for turns that started none.
  public var backgroundJobs: Int?
  /// Model requests this turn retried before they went through (`TransportPolicy`: a 429/5xx,
  /// an overloaded provider, a lost connection, a stream broken or idle before any output) — how
  /// flaky the wire was. nil for older records and for turns that retried nothing; a step that
  /// gave up is counted in the error it ended the turn with, not here.
  public var retries: Int?
  /// Prompt tokens this turn's requests read from the provider's prompt cache, summed over the
  /// steps (chat `prompt_tokens_details.cached_tokens`, `/messages` `cache_read_input_tokens`,
  /// `/responses` `input_tokens_details.cached_tokens`) — a subset of `promptTokens`, so the
  /// turn's hit rate is `cachedTokens / promptTokens`. nil for older records and for turns
  /// whose requests read nothing from a cache.
  public var cachedTokens: Int?
  /// Tool results the microcompaction cleared from the request view this turn (C2): at the turn
  /// start and at mid-turn relief points, the results older than the last N stubbed for the
  /// requests that followed. nil for older records and for turns that cleared nothing.
  public var toolResultsCleared: Int?

  /// The largest structured output kept on a record.
  public static let maxStructuredOutputBytes = 64 * 1024

  /// Counts one committed call for `toolStats`.
  public mutating func noteToolCall(_ tool: String, failed: Bool) {
    var stats = toolStats ?? [:]
    var stat = stats[tool] ?? ToolStat()
    stat.calls += 1
    if failed { stat.errors += 1 }
    stats[tool] = stat
    toolStats = stats
  }

  /// Appends one audit row, capped so a denial loop can't bloat the record.
  public mutating func note(_ decision: ToolDecision) {
    var rows = decisions ?? []
    guard rows.count < ToolDecision.maxPerRecord else { return }
    rows.append(decision)
    decisions = rows
  }

  public init(
    task: String,
    model: String,
    dialect: String,
    packFamily: String)
  {
    id = UUID().uuidString
    startedAt = Date()
    self.task = task
    self.model = model
    self.dialect = dialect
    self.packFamily = packFamily
    steps = 0
    toolCalls = 0
    routedModels = []
    costUSD = 0
    finished = false
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    task = try container.decode(String.self, forKey: .task)
    model = try container.decode(String.self, forKey: .model)
    dialect = try container.decode(String.self, forKey: .dialect)
    packFamily = try container.decode(String.self, forKey: .packFamily)
    steps = try container.decode(Int.self, forKey: .steps)
    toolCalls = try container.decode(Int.self, forKey: .toolCalls)
    routedModels = try container.decodeIfPresent([String].self, forKey: .routedModels) ?? []
    costUSD = try container.decode(Double.self, forKey: .costUSD)
    finished = try container.decode(Bool.self, forKey: .finished)
    verifierPassed = try container.decodeIfPresent(Bool.self, forKey: .verifierPassed)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    turnIndex = try container.decodeIfPresent(Int.self, forKey: .turnIndex)
    agent = try container.decodeIfPresent(String.self, forKey: .agent)
    provider = try container.decodeIfPresent(String.self, forKey: .provider)
    // A reason this build doesn't know (written by a newer arnes) reads as nil rather than
    // dropping the whole row from the scoreboard.
    stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
      .flatMap(StopReason.init(rawValue:))
    hookBlocks = try container.decodeIfPresent(Int.self, forKey: .hookBlocks)
    hookContinuations = try container.decodeIfPresent(Int.self, forKey: .hookContinuations)
    decisions = try container.decodeIfPresent([ToolDecision].self, forKey: .decisions)
    deniedCalls = try container.decodeIfPresent(Int.self, forKey: .deniedCalls)
    promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
    completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
    hookCostUSD = try container.decodeIfPresent(Double.self, forKey: .hookCostUSD)
    parentSessionId = try container.decodeIfPresent(String.self, forKey: .parentSessionId)
    depth = try container.decodeIfPresent(Int.self, forKey: .depth)
    background = try container.decodeIfPresent(Bool.self, forKey: .background)
    truncatedResults = try container.decodeIfPresent(Int.self, forKey: .truncatedResults)
    toolStats = try container.decodeIfPresent([String: ToolStat].self, forKey: .toolStats)
    nudges = try container.decodeIfPresent(Int.self, forKey: .nudges)
    structuredOutputValid = try container.decodeIfPresent(Bool.self, forKey: .structuredOutputValid)
    structuredOutput = try container.decodeIfPresent(JSONValue.self, forKey: .structuredOutput)
    reasoningBlocks = try container.decodeIfPresent(Int.self, forKey: .reasoningBlocks)
    reasoningReplayed = try container.decodeIfPresent(Int.self, forKey: .reasoningReplayed)
    verifierConfidence = try container.decodeIfPresent(String.self, forKey: .verifierConfidence)
    redactions = try container.decodeIfPresent(Int.self, forKey: .redactions)
    flagged = try container.decodeIfPresent(Int.self, forKey: .flagged)
    tainted = try container.decodeIfPresent(Bool.self, forKey: .tainted)
    backgroundJobs = try container.decodeIfPresent(Int.self, forKey: .backgroundJobs)
    retries = try container.decodeIfPresent(Int.self, forKey: .retries)
    cachedTokens = try container.decodeIfPresent(Int.self, forKey: .cachedTokens)
    toolResultsCleared = try container.decodeIfPresent(Int.self, forKey: .toolResultsCleared)
  }
}

/// Append-only JSONL store at `~/.arnes/runs.jsonl`.
public struct RunRecordStore: Sendable {
  public let url: URL

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/runs.jsonl"))
  {
    self.url = url
  }

  public func append(_ record: RunRecord) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(record)
    line.append(Data("\n".utf8))
    try appendJSONLLine(line, to: url)
  }

  public func all() throws -> [RunRecord] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { try? decoder.decode(RunRecord.self, from: Data($0.utf8)) }
  }
}
