import Foundation
import OpenRouterSwift

// MARK: - SessionError

public enum SessionError: Error, Sendable {
  /// `send` was called while a previous turn is still streaming.
  case turnInFlight
  /// `verifyLastTurn` was called before any completed turn.
  case nothingToVerify
  /// The summarizer model returned no usable summary.
  case compactionFailed
  /// A `PreCompact` hook refused a manual compaction (`/compact`); nothing was summarized.
  case compactionCancelled(reason: String)
  /// `compact` was called while `count` background subagents are still running or have
  /// reports waiting to be delivered — summarizing now would cut the exchange they answer.
  case backgroundWorkPending(count: Int)
}

// MARK: - GatedCall

/// One tool call of a step, carried from the gating pass through execution into the history
/// so results can be assembled in call order however they were executed.
struct GatedCall: Sendable {
  /// Position in the step's `toolCalls` — the order history and records are written in.
  let index: Int
  let name: String
  /// Arguments as the tool will see them (a PreToolUse hook may have rewritten them).
  let argumentsJSON: String
  let callId: String
  /// PreToolUse `additionalContext`, appended to the result the model reads.
  let additionalContext: [String]
  /// The gate's refusal text, or nil when the call may run.
  let refusal: String?
  /// Whether this call runs in the step's task group (`ConcurrentTool`).
  let concurrent: Bool
}

// MARK: - Session

/// A persistent conversation with the agent loop — the interactive core of Arnes.
///
/// The session owns the message history (client-side, system prompt excluded), the
/// cumulative cost, and the current model. Because every request is rebuilt as
/// `[system(pack for current model)] + history` and OpenRouter is stateless,
/// `setModel` mid-conversation moves the *entire* conversation to any model with
/// zero setup — the router superpower no single-vendor harness has.
///
/// `.mutating` tools are gated through the `PermissionDelegate` before executing;
/// `.readOnly` tools run freely. When a `SessionStore` is provided every turn is
/// persisted as it happens, so sessions survive crashes and resume with `--continue`.
public actor Session {

  // `Session.Configuration` lives in SessionConfiguration.swift.

  /// Footer numbers for one completed turn.
  public struct TurnStats: Sendable {
    public let steps: Int
    public let toolCalls: Int
    public let turnCostUSD: Double
    public let sessionCostUSD: Double
    public let requestedModel: String
    public let routedModels: [String]
    /// Prompt tokens of the turn's last request — the live context footprint.
    public let promptTokens: Int?
    /// The model's context window, when the manifest knows it.
    public let contextLength: Int?
    /// Wall-clock seconds from the turn's first request to its finish.
    public let durationSeconds: Double
    /// Prompt tokens the turn's requests read from the provider's prompt cache, summed over the
    /// steps (`RunRecord.cachedTokens`); nil when none did.
    public var cachedPromptTokens: Int? = nil
    /// Prompt tokens the turn's requests sent in total, summed over the steps
    /// (`RunRecord.promptTokens`) — the denominator of the turn's cache hit rate; nil when no
    /// request reported usage.
    public var totalPromptTokens: Int? = nil

    public init(
      steps: Int,
      toolCalls: Int,
      turnCostUSD: Double,
      sessionCostUSD: Double,
      requestedModel: String,
      routedModels: [String],
      promptTokens: Int?,
      contextLength: Int?,
      durationSeconds: Double,
      cachedPromptTokens: Int? = nil,
      totalPromptTokens: Int? = nil)
    {
      self.steps = steps
      self.toolCalls = toolCalls
      self.turnCostUSD = turnCostUSD
      self.sessionCostUSD = sessionCostUSD
      self.requestedModel = requestedModel
      self.routedModels = routedModels
      self.promptTokens = promptTokens
      self.contextLength = contextLength
      self.durationSeconds = durationSeconds
      self.cachedPromptTokens = cachedPromptTokens
      self.totalPromptTokens = totalPromptTokens
    }
  }

  /// What a compaction did.
  public struct CompactionResult: Sendable {
    public let summarizedMessages: Int
    public let keptMessages: Int
    public let costUSD: Double
    /// What the PreCompact/PostCompact/SessionStart hooks had to say to the user (runner
    /// errors, `systemMessage`s, PostCompact output). Empty when no hook ran.
    public var hookNotices: [HookNotice] = []
    /// Tool results the request view stubs in the kept tail after this compaction — what the
    /// microcompaction (`Microcompaction`) frees on top of the summary (C2). 0 when none.
    public var clearedToolResults: Int = 0
  }

  /// Why a compaction ran — the `PreCompact`/`PostCompact` matcher subject.
  public enum CompactionTrigger: String, Sendable {
    /// `/compact` (`Session.compact(with:)`). A PreCompact deny cancels it.
    case manual
    /// The context crossed the threshold before a turn. A PreCompact deny is ignored — the
    /// context is full either way, and refusing to summarize would just fail the turn.
    case auto
  }

  /// Which lifecycle moment a `SessionStart` is about — the hooks' matcher subject.
  public enum StartSource: String, Sendable {
    /// A new session.
    case startup
    /// A persisted session picked up again (`--resume`, `/resume`, `/fork`).
    case resume
    /// `clearHistory` — the same session, emptied.
    case clear
    /// A compaction rebuilt the context.
    case compact
  }

  /// Why a `SessionEnd` fired — the hooks' matcher subject.
  public enum EndReason: String, Sendable {
    /// The user (or the headless run) is done with the session.
    case exit
    /// `clearHistory` — the history is about to be emptied.
    case clear
    /// Anything else an embedder wants to report.
    case other
  }

  // MARK: State

  public nonisolated let id: String
  /// What this session was built with, kept whole: nested and resumed sessions derive
  /// from it (`Configuration.forSubagent`), and every setting is read from here rather
  /// than from a copy that could drift.
  public nonisolated let configuration: Configuration
  public private(set) var model: String
  public private(set) var costUSD: Double
  /// The conversation so far, system prompt excluded (it is rebuilt per request
  /// from the prompt pack for the current model's family).
  public private(set) var history: [Message]
  /// Where each turn begins in `history`: the turn's index (`RunRecord.turnIndex`) and the
  /// position of the user message that opened it. Appended as a turn's user message enters
  /// history, emptied by `clearHistory`, cut to the kept tail by a compaction, rebuilt from the
  /// transcript's `turn` tags on resume (a transcript written before the tags yields none).
  /// The seam a rewind cuts history at; a turn whose prompt a hook blocked never appears.
  public private(set) var turnStarts: [TurnStart] = []

  private let service: OpenRouterService
  private let catalog: ModelCatalog
  private let tools: [any AgentTool]
  private let permissions: any PermissionDelegate
  private let store: RunRecordStore
  private let sessionStore: SessionStore?
  private let dialectStore: DialectVerdictStore
  private let hooks: HookEngine?
  private let permissionRuleSet: PermissionRuleSet
  /// The current permission mode; mutable mid-session via `setPermissionMode` (`/permissions`).
  public private(set) var permissionMode: PermissionMode
  /// Standing "always allow this session" grants, as rules-file patterns rather than tool
  /// names — see `SessionGrantSet`. `/permissions save` writes them to the rules file.
  /// The *configuration's* store, shared with every session `forSubagent` derives, so a
  /// grant answered on a nested prompt covers the lead and the sibling agents too.
  private var grants: SessionGrants { configuration.grants }
  private var turnTask: Task<Void, Never>?
  /// The index the next turn's record will carry (turns started so far, resumed count
  /// included); the checkpoint store the REPL keeps beside a session is keyed on it.
  public private(set) var turnIndex: Int
  private var metaWritten: Bool
  private var lastUserText: String?
  private var lastAssistantText: String?
  /// Summary of history that was compacted away; injected into the system prompt. Readable
  /// so a fork of this session (a `LoadedSession` seeded from `history`) can carry it.
  public private(set) var compactionSummary: String?
  /// Prompt tokens reported by the most recent request — drives auto-compaction.
  public private(set) var lastPromptTokens: Int?
  /// Auto-compact when the context is this full (fraction of `contextLength`) — the policy's
  /// threshold (`CompactionPolicy.threshold`, 0.8 by default).
  private var compactionThreshold: Double { configuration.compaction.threshold }
  /// The microcompaction cutoff (C2): the `history` index below which large tool results are
  /// stubbed in the request view (`requestHistory()` → `Microcompaction.view`). Advanced to
  /// `Microcompaction.clearingCutoff` at every turn start and at a mid-turn relief point — never on
  /// an ordinary step, never backwards within a turn — so the set of stubbed messages only grows
  /// while a turn runs (a prompt cache's stable prefix). Recomputed after a compaction; read through
  /// `effectiveClearingCutoff`, which also bounds it after a rewind or a clear shrank the history.
  private var clearedBelow = 0
  /// Harness notices waiting for the next step boundary (see `notify`).
  private var pendingNotices: [String] = []
  /// The nonce every framed tool result carries (`ToolResultFrame`): per session, created with
  /// it, and never written into the system prompt — content the model reads cannot know it.
  private let resultNonce = ToolResultFrame.nonce()
  /// Untrusted content this session has read: a scanner flag, or a result from a tool whose
  /// server the user marked untrusted. Set once, never cleared — from then on a network
  /// `bash` command and every `.sensitive` call are escalated (`permissionDenial`), the prompt
  /// names the source, and every later record says `tainted`.
  private var taint: Taint?

  /// Where a session's taint came from and why.
  struct Taint: Sendable, Equatable {
    let source: String
    let reason: String
  }

  /// Whether this session has read untrusted content (`Taint`), for a status line.
  public var isTainted: Bool { taint != nil }
  /// What the `SessionStart` hooks said (`start(source:)`), appended to the system prompt
  /// after the embedder's sections. Replaced by a later start that produces context, kept
  /// by one that doesn't, reset by `clearHistory`.
  private var hookContext: [String] = []

  /// Shorthands for the configuration fields the loop reads on every step.
  private var traits: ProviderTraits { configuration.provider }
  /// The reasoning dial in force: the configuration's until `setReasoningEffort` moves it.
  private var reasoningEffort: Reasoning.Effort? { reasoningEffortOverride }
  /// The live effort dial (`/effort`), seeded from the configuration in both inits — the
  /// configuration itself is immutable, so the dials that move mid-session live here.
  private var reasoningEffortOverride: Reasoning.Effort?
  /// The live cost ceiling (`/budget`), seeded from `configuration.maxCostUSD`; what the loop's
  /// budget check compares the cumulative spend against. nil = no ceiling.
  private var budgetUSD: Double?
  /// The embedder's system-prompt sections in force (the `# Environment` block…): the
  /// configuration's until `setExtraSystemSections` replaces them, so a `/model` or
  /// `/permissions` change can re-render the block without rebuilding the session.
  private var extraSystemSections: [String]
  /// The structured-output schema in force (H1): the configuration's until `setOutputSchema`
  /// replaces it — the REPL's `/schema`. Read by the structured side request after a finished
  /// turn; nil = no side request. Not persisted, like the budget.
  private var outputSchemaOverride: OutputSchema?
  /// This turn's event stream, readable off the actor: `bindEventEmitters` sets it and the
  /// nonisolated `execute` hands it to each tool as `ToolEventSink.current` for the duration
  /// of the call — per execution, so a tool instance shared with a nested session (every core
  /// tool is) emits into whichever session is running it.
  private let turnSink = EventSinkBox()

  /// A lock-protected slot for the turn's sink (`turnSink`); a class so the nonisolated tool
  /// path can read what the actor set.
  final class EventSinkBox: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (AgentEvent) -> Void)?
    var current: (@Sendable (AgentEvent) -> Void)? {
      get { lock.withLock { sink } }
      set { lock.withLock { sink = newValue } }
    }
  }

  // MARK: Init

  /// - Parameter catalog: the model manifest to consult; pass one shared instance per
  ///   process so the manifest is fetched once (defaults to OpenRouter's `GET /models`).
  /// - Parameter id: the session id to use instead of a fresh UUID — `arnes do --session-id`,
  ///   so a script can name the transcript it will resume later. The caller checks the store
  ///   for a collision; the session itself never reads the store on init.
  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    sessionStore: SessionStore? = nil,
    dialectStore: DialectVerdictStore = DialectVerdictStore(),
    catalog: ModelCatalog? = nil,
    configuration: Configuration = Configuration(),
    id: String? = nil)
  {
    let sessionId = id ?? UUID().uuidString
    self.id = sessionId
    self.configuration = configuration
    model = configuration.model
    costUSD = 0
    history = []
    self.service = service
    self.catalog = catalog ?? ModelCatalog(service: service)
    self.tools = tools
    self.permissions = permissions
    self.store = store
    self.sessionStore = sessionStore
    self.dialectStore = dialectStore
    hooks = HookEngine.make(
      hooks: configuration.hooks, handlers: configuration.hookHandlers,
      promptRunner: configuration.hookPromptRunner, cwd: configuration.workingDirectory,
      environment: configuration.subprocessEnvironment,
      sessionId: sessionId, agent: configuration.agent)
    permissionRuleSet = PermissionRuleSet(configuration.permissionRules)
    permissionMode = configuration.permissionMode
    reasoningEffortOverride = configuration.reasoningEffort
    budgetUSD = configuration.maxCostUSD
    extraSystemSections = configuration.extraSystemSections
    outputSchemaOverride = configuration.outputSchema
    turnIndex = 0
    metaWritten = false
  }

  /// Resumes a previously persisted session: same id, replayed history, model, and cost.
  public init(
    resuming loaded: LoadedSession,
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    sessionStore: SessionStore? = nil,
    dialectStore: DialectVerdictStore = DialectVerdictStore(),
    catalog: ModelCatalog? = nil,
    configuration: Configuration = Configuration())
  {
    id = loaded.meta.id
    self.configuration = configuration
    model = loaded.model
    costUSD = loaded.costUSD
    history = loaded.messages
    self.service = service
    self.catalog = catalog ?? ModelCatalog(service: service)
    self.tools = tools
    self.permissions = permissions
    self.store = store
    self.sessionStore = sessionStore
    self.dialectStore = dialectStore
    hooks = HookEngine.make(
      hooks: configuration.hooks, handlers: configuration.hookHandlers,
      promptRunner: configuration.hookPromptRunner, cwd: configuration.workingDirectory,
      environment: configuration.subprocessEnvironment,
      sessionId: loaded.meta.id, agent: configuration.agent)
    permissionRuleSet = PermissionRuleSet(configuration.permissionRules)
    permissionMode = configuration.permissionMode
    // The dial the CLI already folded the transcript's `effort_change` replay into.
    reasoningEffortOverride = configuration.reasoningEffort
    budgetUSD = configuration.maxCostUSD
    extraSystemSections = configuration.extraSystemSections
    outputSchemaOverride = configuration.outputSchema
    turnIndex = loaded.turnCount
    turnStarts = loaded.turnStarts
    metaWritten = true
    compactionSummary = loaded.compactionSummary
    // Seed the microcompaction cutoff from the resumed history so `/context` and `/btw` right
    // after `--continue` measure the stubbed request view, not the unstubbed transcript; the
    // first turn start would recompute it anyway (a follow-up flagged by C2).
    clearedBelow = Microcompaction.clearingCutoff(
      in: history, keepingRecent: configuration.compaction.keepRecentToolResults)
  }

  /// The coding toolset bound to the process CWD, unconfined. Everything else builds its
  /// tools through `HarnessAssembly` with a `ToolContext`.
  public static let defaultTools: [any AgentTool] = HarnessAssembly.coreTools()

  // MARK: Public API

  public var messageCount: Int { history.count }

  /// The system prompt exactly as the next request would carry it: `systemText` for the
  /// current model's pack over the same instructions, extra sections, hook context, tool
  /// listings, suffix and compaction summary a step sends — no copy that could drift. For
  /// `arnes debug prompt` and an embedder's introspection; resolving the model's family
  /// consults the catalog (one manifest fetch per process).
  public func renderedSystemPrompt() async throws -> String {
    let profile = try await catalog.profile(for: model)
    return systemText(pack: PromptPack.load(for: profile.family), profile: profile)
  }

  /// Every tool definition in the toolset, in definition order — the toolset, not the
  /// per-model *offered* set: a `CapabilityGatedTool` the current model's manifest rules out
  /// (`view_image` for a text model) is listed here and absent from the request.
  /// `availableToolDefinitions()` is the request's view.
  public var toolDefinitions: [Tool] { tools.map(\.toolDefinition) }

  /// The tool definitions the next request would carry for the current model, in the order
  /// they are sent — `toolDefinitions` minus every `CapabilityGatedTool` the manifest rules
  /// out, under the live dials (`/effort` folds into the `think` gate); `[]` when the manifest
  /// says the model takes no tools at all. Resolving the profile consults the catalog (one
  /// manifest fetch per process). What `arnes debug prompt` and the stream-json `init` line
  /// list, so a text model's `init.tools` never names `view_image`.
  public func availableToolDefinitions() async throws -> [Tool] {
    let profile = try await catalog.profile(for: model)
    return requestTools(for: profile)?.map(\.toolDefinition) ?? []
  }

  /// Runs one turn of the agent loop: appends the user message, streams model output
  /// (text deltas as they arrive), executes tool calls (gated through the permission
  /// delegate), and repeats until the model stops calling tools or `maxStepsPerTurn`.
  /// Ends with `.turnFinished(TurnStats)`. Appends one `RunRecord` per turn.
  ///
  /// Terminating the returned stream (or calling `interrupt()`) cancels the in-flight
  /// turn; interrupted tool calls get synthetic results so the history stays valid.
  ///
  /// - Parameter verifyWith: run the loop-1 verifier on this model after the turn
  ///   finishes, landing the verdict in the turn's `RunRecord` (headless `--verify`).
  public func send(_ text: String, verifyWith: String? = nil) -> AsyncThrowingStream<AgentEvent, Error> {
    AsyncThrowingStream { continuation in
      guard turnTask == nil else {
        continuation.finish(throwing: SessionError.turnInFlight)
        return
      }
      let task = Task {
        await self.runTurn(text, verifyWith: verifyWith, continuation: continuation)
        self.clearTurnTask()
      }
      turnTask = task
      continuation.onTermination = { @Sendable _ in task.cancel() }
    }
  }

  /// The `RunRecord` appended by the most recent turn.
  public private(set) var lastRecord: RunRecord?

  /// Cancels the in-flight turn, if any.
  public func interrupt() {
    turnTask?.cancel()
  }

  /// Queues harness text for the model to see at the next step boundary — a background
  /// job finished, a delegated report arrived. Notices never interrupt a streaming step:
  /// they are drained into one `[arnes]` user message right before the next request (or
  /// the next turn's first request), so history stays valid and the model sees them in
  /// order with its own tool results.
  public func notify(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    pendingNotices.append(trimmed)
  }

  /// Runs the `SessionStart` hooks for `source` and keeps what they said as system-prompt
  /// context for the rest of the session (after the embedder's `extraSystemSections`, before
  /// the tool-contributed sections). Context replaces what an earlier start stored; a start
  /// that produces none keeps it, so a hook matching only `startup` still rides the prompt
  /// after a compaction. The CLI calls this at startup/resume, `Agent.run` at startup, and
  /// the session itself on `clearHistory` (`clear`) and after a compaction (`compact`).
  ///
  /// A lifecycle contract with the caller, not something the first `send` runs behind its
  /// back: **an embedder that never calls `start` gets no SessionStart context**, and a nested
  /// subagent session is never started this way (`forSubagent` drops the event).
  ///
  /// - Returns: user-facing notices (runner errors, `systemMessage`s) — nothing the model sees.
  @discardableResult
  public func start(source: StartSource) async -> [HookNotice] {
    guard let engine = hooks else { return [] }
    let outcome = await engine.sessionStart(source: source.rawValue)
    let context = outcome.context.filter { !$0.isEmpty }
    if !context.isEmpty { hookContext = context }
    return outcome.notices(for: .sessionStart)
  }

  /// Runs the `SessionEnd` hooks for `reason`. Advisory: they share a
  /// `HookEngine.sessionEndBudgetSeconds` budget, nothing they say changes what happened, and
  /// their output comes back as notices for the caller to surface. The CLI calls it on exit,
  /// `Agent.run` after its turn, the session itself on `clearHistory` (`clear`). Never for a
  /// nested subagent session.
  @discardableResult
  public func end(reason: EndReason) async -> [HookNotice] {
    await shutdown() // background jobs die with the session, before its SessionEnd hooks run
    // The spill carve-out closes and the files die with the session (`ARNES_KEEP_TMP=1` keeps them).
    defer { releaseSpillDirectory() }
    guard let engine = hooks else { return [] }
    let outcome = await engine.sessionEnd(reason: reason.rawValue)
    return outcome.notices(for: .sessionEnd, includeFeedback: true)
  }

  /// Kills every background shell job the toolset still runs (`JobHosting` — the `bash` and
  /// `job` tools over their `JobRegistry`, found by conformance like the background sources).
  /// Idempotent. `end(reason:)` calls it, so a REPL exit, `/resume`, `/fork`, `/clear` and a
  /// headless run's end all kill their jobs; a nested subagent session is never `end`ed, which
  /// is why this is public and separate — the task tool calls it when the nested turn returns.
  public func shutdown() async {
    for case let host as any JobHosting in tools {
      await host.shutdownJobs()
    }
  }

  /// Mid-conversation model swap. History is kept — only the model-bound content is stripped from
  /// it: the reasoning state a model signed or encrypted, when the slug changes (a signed thinking
  /// block is bound to the model that produced it; replaying it to another is refused), and every
  /// image part, when the new model's manifest says it takes no images (a `view_image` attachment
  /// left in history would fail *every* later request to a text model, not one tool call — the
  /// caption naming the file stays as text; T5) — and the next request carries the new model and
  /// the prompt pack for its family. Returns the profile so callers can warn when the model
  /// doesn't support tools.
  public func setModel(_ slug: String) async throws -> ModelProfile {
    let profile = try await catalog.profile(for: slug)
    if slug != model {
      // Nothing new is persisted: the `model_change` entry records the swap, and
      // `SessionStore.load` applies the same strip when it replays that entry.
      history = ReasoningDetails.stripped(history)
    }
    if !profile.supportsVision {
      // Nothing to persist either: a transcript keeps an attachment as its text already.
      history = ViewImageTool.strippingImages(from: history)
    }
    model = slug
    persist(.modelChange(slug))
    return profile
  }

  /// Fuzzy model lookup against the live manifest (backs the CLI's `/model`).
  public func searchModels(_ query: String, limit: Int = 10) async throws -> [ModelProfile] {
    try await catalog.search(query, limit: limit)
  }

  /// Loop-1 verification of the most recent turn on a separate model. The verdict is
  /// returned (and its cost added to the session), but the turn's already-appended
  /// `RunRecord` is not rewritten — pass `verifyWith:` to `send` to land the verdict
  /// in the record instead.
  public func verifyLastTurn(model verifierModel: String) async throws -> (passed: Bool, verdict: String) {
    guard let task = lastUserText, let outcome = lastAssistantText else {
      throw SessionError.nothingToVerify
    }
    let verdict = try await Verifier.run(
      task: task, outcome: outcome, model: verifierModel, service: service,
      context: verifierContext(model: verifierModel))
    if let priced = verdict.costUSD {
      costUSD += priced
    } else {
      costUSD += await cost(of: verdict.usage, model: verifierModel) ?? 0
    }
    return (verdict.passed, verdict.text)
  }

  /// Empties the conversation. The `SessionEnd` hooks see `clear` first, then the
  /// `SessionStart` hooks (`clear`) run for the emptied session — their context replaces
  /// whatever an earlier start had stored, which is reset here.
  ///
  /// - Returns: the hooks' user-facing notices.
  @discardableResult
  public func clearHistory() async -> [HookNotice] {
    // Pending background work would deliver into a history that no longer holds the call it
    // answers: cancel it first, like an interrupt does (the REPL refuses `/clear` while pending;
    // an embedder calling this directly gets the same outcome without a dangling report).
    _ = await cancelBackgroundWork()
    var notices = await end(reason: .clear)
    history.removeAll()
    turnStarts.removeAll()
    lastUserText = nil
    lastAssistantText = nil
    compactionSummary = nil
    lastPromptTokens = nil
    hookContext = []
    persist(.clear())
    notices += await start(source: .clear)
    return notices
  }

  /// Restores the files and/or the conversation to the start of `turn` (`turnStarts`) — the
  /// REPL's `/rewind` and `/undo`. **Code**: every path the toolset's `FileMutatingTool`s
  /// checkpointed in turns `>= turn` (a shared `CheckpointStore`, found by protocol like the
  /// background sources) goes back to its earliest pre-image in that span, a file created there
  /// is removed, and those turns' checkpoints are forgotten. **Conversation**: history is cut to
  /// the turn's start, `turnStarts` with it, and a `rewind` transcript entry is appended so a
  /// resumed session replays the same cut (append-only — nothing already written is rewritten).
  /// `turnIndex` is not rewound: turns are monotonic, and the next turn simply starts a new
  /// entry at the truncated length. Refused while a turn is in flight or background work is
  /// pending (`compact`'s guard), for a turn that never started, and — for the conversation —
  /// for a turn whose messages a compaction has already summarized away.
  @discardableResult
  public func rewind(toTurn turn: Int, code: Bool = true, conversation: Bool = true) async throws -> RewindResult {
    guard turnTask == nil else { throw RewindError.turnInFlight }
    let pending = pendingBackgroundCount
    guard pending == 0 else { throw RewindError.backgroundWorkPending(count: pending) }
    guard turn >= 0, turn < turnIndex else { throw RewindError.noSuchTurn(turn) }
    var keep: Int?
    if conversation {
      guard let start = turnStarts.first(where: { $0.turn == turn }), start.index <= history.count else {
        throw RewindError.acrossCompaction(turn)
      }
      keep = start.index
    }
    var restore = CheckpointRestore()
    if code {
      var stores = Set<ObjectIdentifier>()
      for case let tool as any FileMutatingTool in tools {
        guard let store = tool.checkpoints, stores.insert(ObjectIdentifier(store)).inserted else { continue }
        restore.merge(try await store.rewind(toTurn: turn))
      }
    }
    var removed = 0
    if let keep {
      removed = history.count - keep
      history = Array(history.prefix(keep))
      turnStarts.removeAll { $0.index >= keep }
      lastUserText = history.last { $0.role == .user }?.content?.plainText
      lastAssistantText = history.last { $0.role == .assistant && $0.content?.plainText.isEmpty == false }?
        .content?.plainText
      lastPromptTokens = nil // stale until the next request reports usage
    }
    persist(.rewind(toTurn: turn, keepMessages: keep, restoredPaths: restore.restored + restore.deleted))
    return RewindResult(
      restoredFiles: restore.restored, deletedFiles: restore.deleted, skipped: restore.skipped,
      removedMessages: removed)
  }

  /// Compacts the conversation: everything before the last user message is summarized
  /// by `summarizerModel` (default: the provider's default model, `openrouter/auto` on
  /// OpenRouter) into a note that rides in the system prompt; the last turn stays
  /// verbatim. Also triggered automatically when a turn starts with the context ~80%
  /// full (`profile.contextLength` from the manifest) and clearing older tool results alone
  /// would not bring it under. A manual compaction is what the `PreCompact` hooks can cancel
  /// (`SessionError.compactionCancelled`).
  ///
  /// - Parameter instructions: the user's steering for this one summary (`/compact [model]
  ///   [instructions]`), appended to the rubric after the project's compaction instructions.
  @discardableResult
  public func compact(with summarizerModel: String? = nil, instructions: String? = nil) async throws -> CompactionResult {
    guard turnTask == nil else { throw SessionError.turnInFlight }
    // A background report is delivered as a tool exchange answering the call that started it;
    // a manual compaction now would summarize that call away from under it. Refused, cheaply
    // (an automatic compaction inside a turn is not — the context is full either way).
    let pending = pendingBackgroundCount
    guard pending == 0 else { throw SessionError.backgroundWorkPending(count: pending) }
    return try await performCompaction(with: summarizerModel, trigger: .manual, instructions: instructions)
  }

  /// Where a compaction cuts the history.
  enum CompactionCut: Sendable, Equatable {
    /// Everything before the last user message is summarized; that message and what followed it
    /// (the current turn, tool exchanges included) stay verbatim — the standard cut, so no tool
    /// call is separated from its result.
    case beforeLastUserMessage
    /// Everything but the message at this index — the in-flight turn's opening user message — is
    /// summarized: mid-turn relief's emergency, when the turn's own exchanges are the bulk of a
    /// nearly full window and nothing older is left to clear. Taken at a step boundary only, so
    /// the dropped exchanges are whole tool batches.
    case allButMessage(at: Int)
  }

  /// The compaction seam: `PreCompact` hooks before the summarizer request (a deny cancels a
  /// manual run, is ignored on an automatic one; their context is appended to the
  /// summarizer's instructions), `PostCompact` hooks after, then the `SessionStart` hooks
  /// with `source: compact`. The rubric is the fixed `compactionPrompt` plus, in order, the
  /// project's `## Compact instructions` (`configuration.compactionInstructions`), the caller's
  /// `instructions` (`/compact … <text>`) and the PreCompact hooks' stdout.
  ///
  /// - Parameter currentRequest: the user request the notes will serve, named to the summarizer as
  ///   kept verbatim. At a turn start it is the message about to run (not yet in `history`, so the
  ///   kept tail's first user message would be the *previous* turn's); nil = the kept tail's first
  ///   user message (a manual `/compact`, the emergency cut — where it is the opening message).
  private func performCompaction(
    with summarizerModel: String?,
    trigger: CompactionTrigger,
    instructions: String? = nil,
    cut: CompactionCut = .beforeLastUserMessage,
    currentRequest: String? = nil)
    async throws -> CompactionResult
  {
    let dropped: [Message]
    let kept: [Message]
    switch cut {
    case .beforeLastUserMessage:
      // Cut at the last user message so the current turn (including any tool exchanges
      // after it) survives verbatim and no tool call is separated from its result.
      guard let keepFrom = history.lastIndex(where: { $0.role == .user }), keepFrom > 0 else {
        return CompactionResult(summarizedMessages: 0, keptMessages: history.count, costUSD: 0)
      }
      dropped = Array(history[..<keepFrom])
      kept = Array(history[keepFrom...])
    case .allButMessage(let index):
      guard index >= 0, index < history.count, history.count > 1 else {
        return CompactionResult(summarizedMessages: 0, keptMessages: history.count, costUSD: 0)
      }
      dropped = Array(history[..<index]) + Array(history[(index + 1)...])
      kept = [history[index]]
    }
    var notices: [HookNotice] = []
    var prompt = Self.compactionPrompt
    if let project = configuration.compactionInstructions?.trimmingCharacters(in: .whitespacesAndNewlines),
       !project.isEmpty
    {
      prompt += "\n\nAdditional instructions from the project's instruction files:\n" + project
    }
    if let steering = instructions?.trimmingCharacters(in: .whitespacesAndNewlines), !steering.isEmpty {
      prompt += "\n\nAdditional instructions from the user for this summary:\n" + steering
    }
    if let engine = hooks {
      let pre = await engine.preCompact(trigger: trigger.rawValue, turnIndex: turnIndex)
      notices += pre.notices(for: .preCompact)
      if let reason = pre.blockReason {
        switch trigger {
        case .manual:
          throw SessionError.compactionCancelled(reason: reason)
        case .auto:
          // Nothing to cancel into: the context is full. Say so, and compact anyway.
          notices.append(HookNotice(
            event: HookEvent.preCompact.rawValue,
            output: "asked to cancel an automatic compaction (\(reason)) — ignored; the context is full"))
        }
      }
      let extra = pre.context.filter { !$0.isEmpty }
      if !extra.isEmpty {
        prompt += "\n\nAdditional instructions from the user's PreCompact hook:\n" + extra.joined(separator: "\n")
      }
    }
    let summarizer = summarizerModel ?? utilityModel
    let response = try await service.chatCompletion(
      ChatCompletionRequest(
        model: summarizer,
        messages: [
          .system(prompt),
          .user(Self.renderTranscript(
            dropped, existingSummary: compactionSummary,
            currentRequest: currentRequest ?? kept.first { $0.role == .user }?.content?.plainText)),
        ]))
    guard let summary = response.choices.first?.message.content, !summary.isEmpty else {
      throw SessionError.compactionFailed
    }
    let cost = await cost(of: response.usage, model: summarizer) ?? 0
    costUSD += cost
    compactionSummary = summary
    history = kept
    // The kept tail belongs to the last turn started; it now begins the history. Older turns
    // are gone with the messages they opened, so a rewind can't cross the compaction.
    turnStarts = turnStarts.last.map { [TurnStart(turn: $0.turn, index: 0)] } ?? []
    lastPromptTokens = nil // stale until the next request reports usage
    // The kept tail keeps its own last N tool results verbatim; older ones stay stubbed in the
    // request view exactly as they were before the cut (the cutoff maps onto the new indices).
    clearedBelow = Microcompaction.clearingCutoff(in: history, keepingRecent: configuration.compaction.keepRecentToolResults)
    persist(.compaction(summary: summary))
    for message in kept {
      persist(TranscriptEntry(message: message, turn: currentTurnTag))
    }
    persist(.cost(turnUSD: cost, sessionUSD: costUSD))
    if let engine = hooks {
      let post = await engine.postCompact(trigger: trigger.rawValue, turnIndex: turnIndex)
      notices += post.notices(for: .postCompact, includeFeedback: true)
    }
    notices += await start(source: .compact)
    var result = CompactionResult(summarizedMessages: dropped.count, keptMessages: kept.count, costUSD: cost)
    result.hookNotices = notices
    result.clearedToolResults = requestClearance().count
    return result
  }

  // MARK: Microcompaction (C2)

  /// The cutoff the request view clears below, right now: `clearedBelow` bounded by what the
  /// current history would give — a no-op while a turn runs (the cutoff only ever came from an
  /// earlier, shorter history), a correction after a rewind or a clear shrank the history under
  /// it, so a `/btw` or `/context` between turns never stubs the results that are now the most
  /// recent. The one place the two are combined.
  private var effectiveClearingCutoff: Int {
    min(clearedBelow, Microcompaction.clearingCutoff(in: history, keepingRecent: configuration.compaction.keepRecentToolResults))
  }

  /// What the request view clears at the current cutoff (count + freed characters).
  private func requestClearance() -> Microcompaction.Clearance {
    Microcompaction.clearance(of: history, below: effectiveClearingCutoff, policy: configuration.compaction)
  }

  /// Moves the cutoff to what the current history gives — the last `keepRecentToolResults` tool
  /// results stay verbatim, everything large before them is cleared from the next request on —
  /// and returns what that newly cleared. Called at turn start (the turn boundary is where the
  /// view changes for a turn) and at a mid-turn relief point; never on an ordinary step, so the
  /// stubs a turn's requests carry are stable from one step to the next.
  private func advanceClearing() -> Microcompaction.Clearance {
    let before = requestClearance()
    clearedBelow = Microcompaction.clearingCutoff(in: history, keepingRecent: configuration.compaction.keepRecentToolResults)
    return requestClearance() - before
  }

  /// The one warning a turn says past its emergency-summary cap (`.contextWarning`): the usage
  /// the request reported, what the clearing at this boundary did, and the summaries used.
  static func contextWarning(
    used: Int, contextLength: Int, cleared: Int, emergencySummaries: Int, maxPerTurn: Int) -> String
  {
    let percent = contextLength > 0 ? used * 100 / contextLength : 100
    let clearing = cleared > 0
      ? " (clearing \(cleared) older tool result\(cleared == 1 ? "" : "s") was not enough)"
      : " with nothing left to clear"
    let summaries: String
    switch emergencySummaries {
    case 0: summaries = "no emergency summary allowed this turn (compaction.maxPerTurn \(maxPerTurn))"
    case 1: summaries = "1 emergency summary already taken this turn"
    default: summaries = "\(emergencySummaries) emergency summaries already taken this turn"
    }
    return "context at \(percent)% of the window\(clearing) and \(summaries)"
      + " — the turn continues, but the next request may not fit the model's context"
  }

  /// A compaction failure as a sentence for a notice: the summarizer's empty reply named, any
  /// other error by its `LocalizedError` text (never an enum dump).
  static func describeCompactionFailure(_ error: any Error) -> String {
    if case SessionError.compactionFailed = error { return "the summarizer returned no usable summary" }
    return TransportError.describe(error)
  }

  // MARK: Anti-stall nudge

  /// At most this many continuation nudges per turn — enough to recover a stall,
  /// bounded so a model with nothing left to do can't loop on nudges.
  static let maxNudgesPerTurn = 2

  /// Consecutive refused tool calls that end the turn (`StopReason.deniedLoop`). Three is
  /// enough to tell "the model adapted after being told no" from "the model is going to
  /// keep asking" — one denial is normal, three in a row is a wall.
  static let maxRefusalsPerTurn = 3

  /// How many times per turn a `Stop` hook may send the model back to work by blocking the
  /// finish. A hook that blocks unconditionally would otherwise run the model until the
  /// budget did; past the cap the block is surfaced and the turn ends normally.
  public static let maxStopContinuations = 3

  /// What the model sees when it stalls (rides the history as a user message, so it
  /// survives dialect translation and resume).
  static let continueNudge = """
    [arnes] Your reply ended without a tool call or a final result. If the task is \
    complete, reply now with the final summary only. Otherwise continue immediately: \
    make the next tool call instead of describing what you will do.
    """

  /// Whether a no-tool-call reply reads like a stall: empty, ends with a colon, or
  /// its last sentence announces work ("let me check…", "I'll now…") instead of
  /// reporting a result. Conservative on purpose — false positives cost one bounded
  /// extra request; false negatives end the turn early.
  static func looksUnfinished(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return true }
    if trimmed.hasSuffix(":") { return true }
    let sentences = trimmed.split(whereSeparator: { ".!?\n".contains($0) })
    guard let last = sentences.last?.trimmingCharacters(in: .whitespaces).lowercased(),
          !last.isEmpty
    else { return false }
    if last.contains("let me know") { return false }
    let intents = [
      "let me ", "i'll ", "i will ", "i'm going to ", "im going to ", "going to ",
      "about to ", "now i ", "next i ", "next, i ", "then i ", "first, i ",
      "let's ", "time to ",
    ]
    return intents.contains { last.contains($0) }
  }

  /// The summarizer's rubric — harness plumbing, family-neutral and fixed. The last sentence is
  /// C2's (a proposal, invariant 6): what a continuing model cannot re-derive must survive
  /// verbatim, and `renderTranscript` ends the transcript with the sections it names.
  static let compactionPrompt = """
    You compress an agent conversation into notes the assistant will rely on to continue \
    seamlessly. Preserve: the user's goals and constraints, decisions made, file paths and \
    code entities touched, the current state of the task, and unresolved items. Be specific \
    and terse. Reply with only the notes. Preserve verbatim: the paths of files modified, the \
    commands that verify the work, unresolved errors and what was tried, and the current plan \
    checklist — the transcript ends with [files touched] and [current plan] sections when the \
    conversation had them; carry them into the notes.
    """

  /// The dropped messages as the summarizer reads them: the earlier summary first, then the
  /// user's current request (kept verbatim in the conversation — named so the notes don't
  /// restate it and do keep what serves it), the transcript, and the rubric's two sections —
  /// `[files touched]` (the `read_file`/`write_file`/`edit_file` paths, with what was done to
  /// each) and `[current plan]` (the last `update_plan` checklist) — when the dropped messages
  /// carried them (`CompactionRubric`).
  static func renderTranscript(_ messages: [Message], existingSummary: String?, currentRequest: String? = nil) -> String {
    var lines: [String] = []
    if let existingSummary {
      lines.append("[earlier summary]\n\(existingSummary)")
    }
    if let currentRequest = currentRequest?.trimmingCharacters(in: .whitespacesAndNewlines), !currentRequest.isEmpty {
      lines.append("[current user request — kept verbatim in the conversation, do not restate it]\n\(String(currentRequest.prefix(2000)))")
    }
    for message in messages {
      var text = message.content?.plainText ?? ""
      if let calls = message.toolCalls, !calls.isEmpty {
        let rendered = calls
          .map { "\($0.function?.name ?? "?")(\(String(($0.function?.arguments ?? "").prefix(200))))" }
          .joined(separator: ", ")
        text += (text.isEmpty ? "" : "\n") + "[tool calls: \(rendered)]"
      }
      lines.append("\(message.role.rawValue): \(String(text.prefix(2000)))")
    }
    if let touched = CompactionRubric.touchedPathsSection(in: messages) {
      lines.append(touched)
    }
    if let plan = CompactionRubric.planSection(in: messages) {
      lines.append(plan)
    }
    return lines.joined(separator: "\n\n")
  }

  /// Names this session in the store (`/save`).
  public func save(name: String) throws {
    guard let sessionStore else { return }
    writeMetaIfNeeded()
    try sessionStore.rename(id: id, name: name)
  }

  // MARK: Turn loop

  private func clearTurnTask() {
    turnTask = nil
  }

  private func runTurn(
    _ text: String,
    verifyWith: String?,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async
  {
    let profile: ModelProfile
    do {
      profile = try await catalog.profile(for: model)
    } catch {
      continuation.finish(throwing: error)
      return
    }
    let pack = PromptPack.load(for: profile.family)

    // Microcompaction (C2), at the turn boundary: the request view keeps the last N tool results
    // verbatim and stubs older large ones; the cutoff advances here — once per turn, so a turn's
    // requests carry stable stubs (a prompt cache's prefix) — and again only at a mid-turn relief
    // point. What the advance newly cleared is the cheap relief; a summary is the expensive one.
    let clearedAtTurnStart = advanceClearing()
    /// Tool results cleared this turn, for the record (which doesn't exist yet): folded in at the
    /// first step boundary with any mid-turn clearing.
    var clearedToolResults = clearedAtTurnStart.count
    if clearedAtTurnStart.count > 0 {
      continuation.yield(.toolResultsCleared(
        count: clearedAtTurnStart.count, freedChars: clearedAtTurnStart.freedChars))
    }

    // Auto-compact before this turn when the previous request reported a nearly full
    // context — unless what the clearing above just freed (estimated at 4 chars a token)
    // already puts the next request under the threshold: clearing is cheaper than summarizing
    // and loses no structure, so the summarizer is asked only when clearing alone won't do. A
    // wrong estimate costs one extra request at most, never correctness — the next turn start
    // measures again. The whole previous turn stays verbatim; older history becomes a note. The
    // summarizer is told the request about to run is the one its notes serve (`text` is not in
    // the history yet). A manifest that says the window is 0 wide asks for nothing.
    if let contextLength = profile.contextLength, contextLength > 0,
       let used = lastPromptTokens,
       Double(used) >= Double(contextLength) * compactionThreshold
    {
      let estimatedAfterClearing = used - clearedAtTurnStart.freedChars / Microcompaction.charsPerToken
      let clearingSuffices = clearedAtTurnStart.count > 0
        && Double(estimatedAfterClearing) < Double(contextLength) * compactionThreshold
      if !clearingSuffices,
         let result = try? await performCompaction(with: nil, trigger: .auto, currentRequest: text),
         result.summarizedMessages > 0
      {
        for notice in result.hookNotices {
          continuation.yield(.hookNotice(event: notice.event, output: notice.output))
        }
        continuation.yield(.compacted(
          summarizedMessages: result.summarizedMessages,
          keptMessages: result.keptMessages))
      }
    }

    // The dialect actually executed this turn — recorded, not just preferred. A fresh
    // failed conformance verdict pins `.auto` to chat before the first request, and a
    // provider that doesn't serve the native endpoints pins it always.
    let dialectOverride = configuration.dialect
    var dialect = dialectOverride.effective(for: profile)
    if dialectOverride == .auto, dialect != .chat,
       !traits.nativeDialects || dialectStore.isKnownBad(model: model, dialect: dialect)
    {
      dialect = .chat
    }
    var record = RunRecord(
      task: text,
      model: model,
      dialect: dialect.rawValue,
      packFamily: profile.family.rawValue)
    record.sessionId = id
    record.turnIndex = turnIndex
    record.agent = configuration.agent
    record.provider = traits.name
    // Lineage: a nested session writes who spawned it and how; `background` only for nested
    // runs (a lead is never detached), so a lead's row gains one key (`depth: 0`), no more.
    record.parentSessionId = configuration.parentSessionId
    record.depth = configuration.depth
    record.background = configuration.depth > 0 ? configuration.spawnedInBackground : nil
    turnIndex += 1

    // UserPromptSubmit hooks see the text before it enters history. A block ends the turn
    // before any request — the text is never appended, so no dangling user turn is left
    // behind, and the record says why. Context (plain stdout or `additionalContext`) rides
    // the user message as a trailing block; the user's own words are never rewritten.
    var userText = text
    if let engine = hooks {
      let submitted = await engine.userPromptSubmit(prompt: text, turnIndex: record.turnIndex)
      for notice in submitted.notices(for: .userPromptSubmit) {
        continuation.yield(.hookNotice(event: notice.event, output: notice.output))
      }
      if let reason = submitted.blockReason {
        record.stopReason = .hookStopped
        record.hookBlocks = (record.hookBlocks ?? 0) + 1
        record.summary = "prompt blocked by hook: \(String(reason.prefix(200)))"
        // A `type: prompt` UserPromptSubmit hook that blocked spent a request: booked on this
        // record — in a one-shot run there is no next turn to carry it.
        let hookSpend = await drainHookSpend()
        if hookSpend > 0 {
          record.costUSD += hookSpend
          record.hookCostUSD = (record.hookCostUSD ?? 0) + hookSpend
          costUSD += hookSpend
        }
        try? store.append(record)
        lastRecord = record
        continuation.yield(.promptBlocked(reason: reason))
        continuation.yield(.turnFinished(TurnStats(
          steps: 0, toolCalls: 0, turnCostUSD: hookSpend, sessionCostUSD: costUSD,
          requestedModel: record.model, routedModels: [], promptTokens: lastPromptTokens,
          contextLength: profile.contextLength,
          durationSeconds: Date().timeIntervalSince(record.startedAt))))
        continuation.finish()
        return
      }
      let context = submitted.context.filter { !$0.isEmpty }
      if !context.isEmpty {
        userText += "\n\n[context]\n" + context.joined(separator: "\n")
      }
    }
    lastUserText = text

    // Tools that stream progress of their own (the task tool's nested subagent events)
    // emit into this turn's stream, so the caller sees one ordered sequence.
    bindEventEmitters { continuation.yield($0) }
    defer { bindEventEmitters(nil) }

    // `turnIndex` already counts this turn (incremented above), so its index is one less.
    turnStarts.append(TurnStart(turn: turnIndex - 1, index: history.count))
    appendToHistory(.user(userText))

    var turnCost = 0.0
    var finalText = ""
    var interrupted = false
    var turnError: Error?
    var nudgesUsed = 0
    /// Output-limit cutoffs the model was told to continue from, this turn (`maxTruncationNudgesPerTurn`).
    var truncationNudges = 0
    /// Consecutive refused tool calls (permission, hook, or an execute-time floor). Reset
    /// by any call that actually ran; `maxRefusalsPerTurn` of them ends the turn.
    var refusalsInARow = 0
    /// Times a Stop hook has sent the model back to work this turn (`maxStopContinuations`).
    var stopContinuations = 0
    /// What the Stop hooks said when the turn ended. Set at the natural finish (where a
    /// block can send the model back to work) or, for every other end, after the loop —
    /// so they run exactly once per turn end, and are surfaced once the record is written.
    var stopOutcome: HookOutcome?
    let maxStepsPerTurn = configuration.maxStepsPerTurn
    /// Steps taken since the turn (or its latest Stop-hook continuation) began.
    var stepsThisRun = 0
    /// The loop guard's per-turn counters (consecutive errors, identical calls, edits per
    /// file); fed by `commitReady` for every committed model call, never by a background
    /// report's synthetic exchange. See `LoopGuardPolicy`.
    var loopGuard = LoopGuard(policy: configuration.loopGuard)
    /// The loop guard's nudge waiting for the next step boundary. A turn-local, not a session
    /// notice: one earned on a turn's last step (a stuck raised later in the same step, the
    /// step limit, a hook stop) refers to calls the next turn won't be about, so it dies with
    /// the turn instead of landing after the user's next message.
    var guardNudge: String?
    /// Emergency summaries this turn attempted — a failed one counts, and is said as it fails
    /// (`CompactionPolicy.maxPerTurn`) — and whether the one `contextWarning` past that cap was
    /// said — mid-turn relief's bounds (C2).
    var emergencyCompactions = 0
    var contextWarned = false

    loop: while stepsThisRun < maxStepsPerTurn {
      stepsThisRun += 1
      if Task.isCancelled {
        interrupted = true
        break
      }
      if let maxCostUSD = budgetUSD, costUSD >= maxCostUSD {
        record.stopReason = .budget
        continuation.yield(.budgetReached(spentUSD: costUSD, budgetUSD: maxCostUSD))
        break loop
      }
      drainPendingNotices(turnNudge: &guardNudge)
      // Background subagents that finished since the last request: their reports enter
      // history here, as tool exchanges, before the model's next step sees them.
      deliverFinishedBackground(record: &record, turnCost: &turnCost, continuation: continuation)
      record.steps += 1

      var step: StepOutcome
      do {
        step = try await streamStep(
          dialect: dialect,
          pack: pack,
          profile: profile,
          knownRouted: record.routedModels,
          continuation: continuation)
      } catch {
        // A step that exhausted its transport retries carries the count it burned; fold it in
        // (a successful step folds `step.retries` below — an exhausted one never returns).
        if case TransportError.retriesExhausted(_, let n, _) = error {
          record.retries = (record.retries ?? 0) + n
        }
        turnError = error
        break loop
      }

      if dialect != .chat {
        if let failure = step.failure {
          // The native endpoint misbehaved. Rerun this step on chat only when nothing
          // streamed yet (a mid-stream retry would duplicate output) and the user
          // didn't force the dialect; a forced run surfaces the failure and records it
          // for auto callers, as an explicit A/B should.
          let nativeDialect = dialect
          // A thinking-shape refusal (a missing/unsigned thinking block, a rejected budget) or a
          // refused `cache_control` is the request's fault, not the endpoint's: recorded under
          // its category so it never pins the model to chat, while the turn still falls back
          // for this step. An exhausted transport retry is the wire's: its `transport` verdict
          // cools the route for minutes (`DialectVerdictStore.transportCooldown`), never the
          // week an endpoint failure earns. The model id is excluded from the text match (a
          // `:thinking` slug in an endpoint error is not a refusal).
          let category = step.transportFailure != nil
            ? DialectVerdict.transportCategory
            : DialectVerdict.category(forFailure: failure, model: model)
          // The failed native attempt's own re-sends count, whether or not chat takes over
          // (the chat rerun replaces `step`, so the fold below would never see them).
          if step.retries > 0 {
            record.retries = (record.retries ?? 0) + step.retries
          }
          guard dialectOverride == .auto, !step.emittedOutput, !step.interrupted else {
            dialectStore.record(model: model, dialect: dialect, ok: false, reason: failure, category: category)
            // A forced dialect keeps the error's own shape: exhausted retries read as the
            // transport failure they are, a refusal as the dialect's.
            if let transportFailure = step.transportFailure {
              turnError = transportFailure
            } else {
              turnError = DialectError.nativeDialectFailed(dialect.rawValue, failure)
            }
            break loop
          }
          continuation.yield(.dialectFellBack(dialect: dialect.rawValue, reason: failure))
          dialect = .chat
          record.dialect = Dialect.chat.rawValue
          do {
            step = try await streamStep(
              dialect: .chat,
              pack: pack,
              profile: profile,
              knownRouted: record.routedModels,
              continuation: continuation)
            // Chat worked where the native endpoint didn't: that is a dialect problem,
            // worth remembering. Had chat failed too (unknown model, bad key, gateway
            // down) the dialect was never the issue and no verdict is recorded.
            dialectStore.record(model: model, dialect: nativeDialect, ok: false, reason: failure, category: category)
          } catch {
            if case TransportError.retriesExhausted(_, let n, _) = error {
              record.retries = (record.retries ?? 0) + n
            }
            turnError = error
            break loop
          }
        } else if !step.interrupted {
          // A clean native step is the conformance probe, for free.
          dialectStore.record(model: model, dialect: dialect, ok: true)
        }
      }
      if !step.reasoningDetails.isEmpty {
        record.reasoningBlocks = (record.reasoningBlocks ?? 0) + step.reasoningDetails.count
      }
      if step.reasoningReplayed > 0 {
        record.reasoningReplayed = (record.reasoningReplayed ?? 0) + step.reasoningReplayed
      }

      for served in step.routed where !record.routedModels.contains(served) {
        record.routedModels.append(served)
      }
      if let cost = step.cost ?? estimatedCost(of: step, profile: profile) {
        record.costUSD += cost
        turnCost += cost
        costUSD += cost
      }
      if let promptTokens = step.promptTokens {
        lastPromptTokens = promptTokens
        record.promptTokens = (record.promptTokens ?? 0) + promptTokens
      }
      if let completionTokens = step.completionTokens {
        record.completionTokens = (record.completionTokens ?? 0) + completionTokens
      }
      if let cachedTokens = step.cachedPromptTokens, cachedTokens > 0 {
        record.cachedTokens = (record.cachedTokens ?? 0) + cachedTokens
      }
      if step.retries > 0 {
        record.retries = (record.retries ?? 0) + step.retries
      }
      if step.interrupted || Task.isCancelled {
        // Nothing from this step is in the history yet — safe to stop here.
        interrupted = true
        break loop
      }

      // Mid-turn relief (C2). The history is at a step boundary here — the previous step's tool
      // batch is complete, this step's reply is not yet appended — so nothing done to it splits a
      // tool call from its result. When this request reported the window past the threshold and
      // the turn goes on (it has tool calls), the cutoff advances: the tool results older than
      // the last N are cleared from the next request on (the ordinary case, free). The emergency
      // is gated on the *estimated* usage after that clearing (4 chars a token), not on whether
      // anything was cleared: a turn adding one large result per step clears exactly one result
      // per step — never nothing — while the kept N results alone can be the bulk of a small
      // window. When the estimate still stands at `emergencyThreshold`, everything but this turn's
      // opening message is summarized into the conversation note, at most `maxPerTurn` times — a
      // failed attempt is said (`contextWarning`) and counts, or a failing summarizer would be
      // asked again on every step past the threshold; past the cap the turn runs on and says so
      // once (`contextWarning`) — the next request may not fit, and the user decides what to
      // shorten. A finishing step (no tool calls) asks for nothing: the turn ends, and the next
      // turn start does its own clearing and summarizing. A manifest that says the window is 0
      // wide asks for nothing either.
      if clearedToolResults > 0 {
        record.toolResultsCleared = (record.toolResultsCleared ?? 0) + clearedToolResults
        clearedToolResults = 0
      }
      if !step.toolCalls.isEmpty, let contextLength = profile.contextLength, contextLength > 0,
         let used = step.promptTokens,
         Double(used) >= Double(contextLength) * compactionThreshold
      {
        let cleared = advanceClearing()
        if cleared.count > 0 {
          record.toolResultsCleared = (record.toolResultsCleared ?? 0) + cleared.count
          continuation.yield(.toolResultsCleared(count: cleared.count, freedChars: cleared.freedChars))
        }
        let estimatedAfterClearing = used - cleared.freedChars / Microcompaction.charsPerToken
        if Double(estimatedAfterClearing) >= Double(contextLength) * CompactionPolicy.emergencyThreshold {
          if emergencyCompactions < configuration.compaction.maxPerTurn, let start = turnStarts.last?.index {
            emergencyCompactions += 1
            do {
              let result = try await performCompaction(with: nil, trigger: .auto, cut: .allButMessage(at: start))
              if result.summarizedMessages > 0 {
                // `performCompaction` booked the summarizer's spend on the session; this turn's
                // record and stats take it too (a turn-start compaction has no record yet).
                record.costUSD += result.costUSD
                turnCost += result.costUSD
                for notice in result.hookNotices {
                  continuation.yield(.hookNotice(event: notice.event, output: notice.output))
                }
                continuation.yield(.compacted(
                  summarizedMessages: result.summarizedMessages, keptMessages: result.keptMessages))
              }
            } catch {
              // An interrupt landing under the summarizer request is the loop's next check, not
              // a warning; anything else is said — nothing else would say why the window stays full.
              if !Task.isCancelled {
                continuation.yield(.contextWarning(
                  "emergency summary \(emergencyCompactions) of \(configuration.compaction.maxPerTurn) failed"
                    + " (\(Self.describeCompactionFailure(error)))"
                    + " — the turn continues, but the next request may not fit the model's context"))
              }
            }
          } else if !contextWarned {
            contextWarned = true
            continuation.yield(.contextWarning(Self.contextWarning(
              used: used, contextLength: contextLength, cleared: cleared.count,
              emergencySummaries: emergencyCompactions, maxPerTurn: configuration.compaction.maxPerTurn)))
          }
        }
      }

      if !step.text.isEmpty {
        finalText = step.text
        lastAssistantText = step.text
        continuation.yield(.assistantText(step.text))
      }

      if step.isTruncated {
        // The reply hit the output-token limit: what came back is a partial answer, not the
        // model's finish. A tool call the cutoff landed inside of was already dropped in
        // `streamStep`, so nothing half-formed enters history. With no whole call left the model
        // is asked once per turn to continue shorter (the partial text stays in history, as the
        // stall nudge keeps it); a second cutoff ends the turn as `truncated` — more of the same
        // would not fit either, and the user decides what to shorten. Whole calls that survived
        // run as usual, and the model hears about the cutoff at the next step boundary, through
        // the turn-local nudge channel the loop guard uses (a step-limit end drops it with the
        // turn instead of landing after the user's next message).
        continuation.yield(.truncated)
        let nudge = OutputTruncation.nudge(droppedToolCall: step.droppedToolCalls.first)
        if step.toolCalls.isEmpty {
          if !step.text.isEmpty {
            appendToHistory(.assistant(step.text))
          }
          if truncationNudges < OutputTruncation.maxNudgesPerTurn {
            truncationNudges += 1
            record.nudges = (record.nudges ?? 0) + 1
            appendToHistory(.user("[arnes] " + nudge))
            continue
          }
          record.stopReason = .truncated
          break loop
        }
        if truncationNudges < OutputTruncation.maxNudgesPerTurn, guardNudge == nil {
          truncationNudges += 1
          record.nudges = (record.nudges ?? 0) + 1
          guardNudge = nudge
        }
      }

      let toolCalls = step.toolCalls
      guard !toolCalls.isEmpty else {
        // The model stopped calling tools. An empty reply, or one trailing off with
        // "let me check X" narration, is a stall — not a finish. Nudge it back into
        // the loop instead of silently ending the turn; bounded so a model that
        // genuinely has nothing to do can't ping-pong forever.
        if let usable = requestTools(for: profile), !usable.isEmpty, nudgesUsed < Self.maxNudgesPerTurn,
           Self.looksUnfinished(step.text)
        {
          nudgesUsed += 1
          record.nudges = (record.nudges ?? 0) + 1
          if !step.text.isEmpty {
            appendToHistory(.assistant(step.text))
          }
          appendToHistory(.user(Self.continueNudge))
          continuation.yield(.nudged(
            reason: step.text.isEmpty ? "empty reply" : "announced more work"))
          continue
        }
        // Background subagents still out: the reply the model just gave is kept, one report
        // is awaited and delivered, and the model takes another step to fold it in — a
        // step out of `maxStepsPerTurn`, not a nudge. A turn never ends with delegated work
        // unaccounted for unless the embedder asked for that (the REPL's
        // `joinBackgroundAtTurnEnd: false`: the report then lands at the next `send`).
        if configuration.joinBackgroundAtTurnEnd, pendingBackgroundCount > 0 {
          continuation.yield(.subagentJoining(pending: pendingBackgroundCount))
          if let joined = await awaitAnyBackground() {
            // The kept reply rides the synthetic call's message — one assistant turn that says
            // X and calls a tool, the shape every step with tool calls has — so the history
            // keeps alternating roles for the chat templates that insist on it.
            deliver(
              joined.outcome, via: joined.source, leadText: step.text,
              record: &record, turnCost: &turnCost, continuation: continuation)
            continue loop
          }
          // Nothing arrived: the wait was cancelled — the interrupt path takes over — or the
          // work vanished from under the count; either way the turn ends as it was going to.
          if !step.text.isEmpty {
            appendToHistory(.assistant(step.text))
          }
          if Task.isCancelled {
            interrupted = true
            break loop
          }
        } else if !step.text.isEmpty {
          appendToHistory(.assistant(step.text))
        }
        record.finished = true
        // In plan mode nothing gated ran: what the model delivered is a proposal, not work.
        record.stopReason = permissionMode == .plan ? .planProposed : .completed
        // Stop hooks run at the natural finish, where a block still means something: the
        // model is sent back to work with the reason as its next instruction. Bounded, and
        // the re-run's payload says `stop_hook_active`, so a hook can't loop the model
        // forever; past the cap the block is surfaced and the turn ends as it was going to.
        if let engine = hooks {
          let outcome = await engine.stop(
            turnIndex: record.turnIndex, stopHookActive: stopContinuations > 0)
          stopOutcome = outcome
          // `continue: false` outranks `block` (Claude Code's precedence): a hook that says
          // both wants the turn over, not the model back at work.
          if let reason = outcome.blockReason, outcome.continueRun,
             stopContinuations < Self.maxStopContinuations
          {
            // What this run of the hooks had to say besides the block — another hook's
            // output, a runner error — is surfaced now; the re-run below produces its own.
            for notice in outcome.notices(for: .stop, includeFeedback: true) {
              continuation.yield(.hookNotice(event: notice.event, output: notice.output))
            }
            stopContinuations += 1
            record.hookContinuations = stopContinuations
            record.finished = false
            record.stopReason = nil
            stopOutcome = nil
            stepsThisRun = 0
            appendToHistory(.user("[hook] " + reason))
            continuation.yield(.hookNotice(
              event: HookEvent.stop.rawValue,
              output: "continuing the turn (\(stopContinuations)/\(Self.maxStopContinuations)): \(reason)"))
            continue loop
          }
        }
        break loop
      }

      appendToHistory(Message(
        role: .assistant,
        content: step.text.isEmpty ? nil : .text(step.text),
        toolCalls: toolCalls,
        reasoningDetails: step.reasoningDetails.isEmpty ? nil : step.reasoningDetails))

      // The step's calls are gated and executed in call order, exactly as they always were,
      // with one difference: a `ConcurrentTool` call (today only `task`) is *dispatched*
      // instead of awaited, so the delegations of one step overlap with each other and with
      // the lead's own tool calls. Results are committed strictly in call order — a call
      // whose turn has come but whose output hasn't arrived holds the queue — so history,
      // records, result events and PostToolUse hooks are what a sequential step would have
      // produced, and a step that delegates nothing behaves identically to before.
      var answered: Set<String> = []
      var hookStop: String??
      /// Set when the loop guard called the turn stuck; handled after the step like `hookStop`.
      var stuckReason: String?
      var gated: [GatedCall] = []
      var outputs: [Int: String] = [:]
      /// How far the in-order commit has got through `gated`.
      var committed = 0
      /// What the step's `AttachingTool` calls attached (an image `view_image` read), in commit
      /// order — appended as user messages once every result of the step is in history, never
      /// between two results (a chat request wants an assistant's tool results contiguous).
      var stepAttachments: [Message] = []
      /// The refusal streak the *gate* sees. It runs ahead of `refusalsInARow` while a
      /// dispatched call's verdict is still outstanding, and is resynchronized with the
      /// authoritative count whenever the commit has caught up — which, with nothing
      /// dispatched, is after every call.
      var gateRefusals = refusalsInARow

      /// Commits every gated call whose output has arrived, oldest first, stopping at the
      /// first one still in flight. Called only from this task, so two PostToolUse hooks
      /// never overlap however many tools ran at once.
      func commitReady() async {
        while committed < gated.count, var output = outputs[gated[committed].index] {
          let call = gated[committed]
          committed += 1
          /// How this call went as far as the loop guard is concerned: a refusal (the gate's or
          /// the floor's), an `error:` result (the tool's own, or a validation error), or a result.
          let outcome: LoopGuard.Outcome
          if call.refusal != nil {
            refusalsInARow += 1
            outcome = .refused
            // A refused call is a call the model made: counted, but not as the tool's error
            // (it never ran; `deniedCalls` has it).
            record.noteToolCall(call.name, failed: false)
          } else {
            // An execute-time floor (a catastrophic command, a harness file) refuses after
            // every gate has already said yes — it gets its own audit row, and it counts
            // toward the denial loop and the record's denied calls like any other refusal.
            let floorRefused = output.hasPrefix(ToolDecision.floorRefusalPrefix)
            if floorRefused {
              record.note(decisionRow(
                name: call.name, argumentsJSON: call.argumentsJSON, .deny, source: .floor,
                reason: String(output.dropFirst(ToolDecision.floorRefusalPrefix.count))))
              record.deniedCalls = (record.deniedCalls ?? 0) + 1
              refusalsInARow += 1
            } else {
              refusalsInARow = 0
            }
            let errored = output.hasPrefix(Self.toolErrorPrefix)
            outcome = floorRefused ? .refused : errored ? .error : .ok
            record.noteToolCall(call.name, failed: errored && !floorRefused)
            if !call.additionalContext.isEmpty {
              output += "\n\n[hook context]\n" + call.additionalContext.joined(separator: "\n")
            }
            let post = await afterToolExecuted(
              name: call.name, argumentsJSON: call.argumentsJSON, callId: call.callId,
              turnIndex: record.turnIndex, output: &output, continuation: continuation)
            if post.accruedCost > 0 {
              record.costUSD += post.accruedCost
              turnCost += post.accruedCost
              costUSD += post.accruedCost
            }
            if post.hookCost > 0 {
              record.hookCostUSD = (record.hookCostUSD ?? 0) + post.hookCost
            }
            if post.truncated {
              record.truncatedResults = (record.truncatedResults ?? 0) + 1
            }
            if post.redactions > 0 {
              record.redactions = (record.redactions ?? 0) + post.redactions
            }
            // Instruction-shaped content: the result already carries the scanner's notice line;
            // the record counts it, the user sees it, and the session is tainted from here on.
            // A result from an untrusted source taints without a flag — nothing suspicious was
            // seen, the source is the reason.
            if !post.flagged.isEmpty {
              record.flagged = (record.flagged ?? 0) + 1
              markTainted(source: call.name, reason: "flagged: " + post.flagged.joined(separator: ", "))
              continuation.yield(.contentFlagged(tool: call.name, patterns: post.flagged))
            }
            if let tainting = tools.first(where: { $0.name == call.name }) as? any TaintingTool {
              // Per result (S7): the tool answers for *this* call — every result of an untrusted
              // MCP server, a `web_fetch` of a host outside the allowlist — so an allowlisted
              // page stays under the scanner alone. The lenient decode the gate uses, not a
              // second parser; a malformed call was the model's error result already.
              let arguments = Self.decodeArguments(call.argumentsJSON)
              if tainting.taintsResult(arguments: arguments) {
                markTainted(
                  source: tainting.taintSource(arguments: arguments),
                  reason: tainting.taintReason(arguments: arguments))
              }
            }
            if post.stop != nil, hookStop == nil { hookStop = post.stop }
            continuation.yield(.toolResult(name: call.name, preview: String(output.prefix(200))))
          }
          // Every result — a refusal and a preflight error included: they are results too —
          // enters history framed when the policy says so; the preview above stays unframed.
          appendToHistory(.tool(framed(output, source: call.name), toolCallId: call.callId))
          answered.insert(call.callId)
          // A result the model must see as content (an image): its parts wait for the step's
          // last result, then ride a user message. Asked only of a call that ran.
          if call.refusal == nil,
             let attaching = tools.first(where: { $0.name == call.name }) as? any AttachingTool,
             let attachment = await attaching.takeAttachment(callId: call.callId),
             !attachment.parts.isEmpty
          {
            stepAttachments.append(Message(role: .user, content: .parts(attachment.parts)))
          }
          // T2: count a bash call that actually started a background job — `background: true`
          // and a result that isn't a refusal or "jobs unavailable" error — for `arnes runs`.
          if call.name == "bash", !output.hasPrefix(Self.toolErrorPrefix),
             let bashArgs = Self.decodeArgumentObject(call.argumentsJSON),
             BashTool.backgroundFlag(from: bashArgs) == true
          {
            record.backgroundJobs = (record.backgroundJobs ?? 0) + 1
          }
          // The loop guard sees every committed model call, in commit order. A nudge waits for
          // the next step boundary (drained with the notices into one `[arnes]` user message
          // before the next request; dropped if the turn ends first); a hard threshold ends the
          // turn once the step's calls are answered.
          switch loopGuard.observe(tool: call.name, argumentsJSON: call.argumentsJSON, outcome: outcome) {
          case .none:
            break
          case .nudge(let reason, let text):
            record.nudges = (record.nudges ?? 0) + 1
            // Join, don't overwrite: a truncation nudge set earlier in this step must survive a
            // loop-guard nudge landing in the same step (both drain into one `[arnes]` message).
            guardNudge = [guardNudge, text].compactMap { $0 }.joined(separator: "\n")
            continuation.yield(.nudged(reason: reason))
          case .stuck(let reason):
            if stuckReason == nil { stuckReason = reason }
          }
        }
      }

      await withTaskGroup(of: (index: Int, output: String?).self) { group in
        for (index, call) in toolCalls.enumerated() {
          if Task.isCancelled {
            interrupted = true
            break
          }
          record.toolCalls += 1
          let name = call.function?.name ?? ""
          var argumentsJSON = call.function?.arguments ?? "{}"
          let callId = call.id ?? ""
          continuation.yield(.toolCall(name: name, arguments: argumentsJSON))

          // PreToolUse hooks run first — before the permission prompt — so a deterministic
          // guardrail can deny (nobody is asked about a call that won't happen), force a
          // prompt, lift the ordinary-mutation prompt, or rewrite the arguments. A hook that
          // could not run is reported to the user and (unless failClosed) has no effect.
          let pre = await hooks?.preToolUse(
            tool: name, argumentsJSON: argumentsJSON, toolUseId: callId, turnIndex: record.turnIndex) ?? .none
          for error in pre.errors {
            continuation.yield(.hookNotice(event: HookEvent.preToolUse.rawValue, output: error))
          }
          for message in pre.systemMessages {
            continuation.yield(.hookNotice(event: HookEvent.preToolUse.rawValue, output: message))
          }
          if let updated = pre.updatedInput,
             let data = try? JSONEncoder().encode(updated),
             let rewritten = String(data: data, encoding: .utf8)
          {
            // The rewritten arguments are what the tool runs *and* what the prompt shows; the
            // permission tier is re-derived from them below, so a hook can't downgrade a
            // `.sensitive` call by rewriting it after classification.
            argumentsJSON = rewritten
            continuation.yield(.hookNotice(
              event: HookEvent.preToolUse.rawValue, output: "\(name) arguments rewritten by hook"))
          }

          var refusal: String?
          /// A call that can't run as sent (unknown tool, malformed or incomplete arguments):
          /// answered with a coaching error instead of being gated — a result, not a refusal.
          var preflight: String?
          if let block = pre.blockReason {
            refusal = "blocked by hook: \(block)"
            record.hookBlocks = (record.hookBlocks ?? 0) + 1
            record.deniedCalls = (record.deniedCalls ?? 0) + 1
            record.note(decisionRow(
              name: name, argumentsJSON: argumentsJSON, .deny, source: .hook, reason: block))
            continuation.yield(.hookBlocked(tool: name, reason: block))
          } else if let problem = preflightError(name: name, argumentsJSON: argumentsJSON) {
            preflight = problem
          } else {
            let gate = await permissionDenial(
              name: name, argumentsJSON: argumentsJSON, callId: callId, turnIndex: record.turnIndex,
              hookDecision: pre.decision)
            for notice in gate.notices {
              continuation.yield(.hookNotice(event: notice.event, output: notice.output))
            }
            if let row = gate.decision { record.note(row) }
            if let denial = gate.denial {
              refusal = denial
              record.deniedCalls = (record.deniedCalls ?? 0) + 1
              continuation.yield(.toolDenied(name: name, reason: denial))
            }
          }

          let call = GatedCall(
            index: index,
            name: name,
            argumentsJSON: argumentsJSON,
            callId: callId,
            additionalContext: pre.additionalContext,
            refusal: refusal,
            concurrent: refusal == nil && preflight == nil && isConcurrent(name))
          gated.append(call)
          gateRefusals = refusal == nil ? 0 : gateRefusals + 1

          if let refusal {
            outputs[index] = refusal
          } else if let preflight {
            // Nothing to run: the error is the result, committed like an executed call's.
            outputs[index] = preflight
          } else if call.concurrent {
            // Dispatched, not awaited: the next call is gated and run while this one works.
            group.addTask { [self] in
              guard !Task.isCancelled else { return (index, nil) }
              let output = await execute(name: name, argumentsJSON: argumentsJSON)
              // A cancelled call's partial output is not an answer — left unanswered, the
              // interrupt path below says so in the history instead.
              return (index, Task.isCancelled ? nil : output)
            }
          } else {
            outputs[index] = await execute(name: name, argumentsJSON: argumentsJSON)
          }

          await commitReady()
          // With nothing outstanding the gate's streak is the real one again, so a step that
          // delegates nothing stops asking after exactly the refusals the old loop counted.
          if committed == gated.count { gateRefusals = refusalsInARow }
          if hookStop != nil || stuckReason != nil || gateRefusals >= Self.maxRefusalsPerTurn { break }
        }

        for await finished in group {
          if let output = finished.output { outputs[finished.index] = output }
        }
      }

      // A delegation cancelled in flight still spent what it spent, and its call is answered
      // as interrupted rather than committed — so the spend is drained here instead, or the
      // turn's books (and the record) would miss it.
      if Task.isCancelled {
        let stranded = tools
          .compactMap { $0 as? CostReportingTool }
          .reduce(0.0) { $0 + $1.drainAccruedCost() }
        if stranded > 0 {
          record.costUSD += stranded
          turnCost += stranded
          costUSD += stranded
        }
      }
      await commitReady()

      if interrupted || Task.isCancelled {
        interrupted = true
        // Answer any outstanding calls so the history has no dangling tool calls —
        // the next request would otherwise be rejected by the API.
        for call in toolCalls where !answered.contains(call.id ?? "") {
          appendToHistory(.tool("[interrupted by user]", toolCallId: call.id ?? ""))
        }
        break loop
      }

      if let stop = hookStop {
        // A PostToolUse hook asked to end the turn (`continue: false`). Outstanding calls
        // are answered so the history stays valid, then the loop stops here.
        for call in toolCalls where !answered.contains(call.id ?? "") {
          appendToHistory(.tool("[turn ended by hook]", toolCallId: call.id ?? ""))
        }
        record.stopReason = .hookStopped
        continuation.yield(.hookStopped(reason: stop))
        break loop
      }

      if let stuckReason {
        // The loop guard: the model is repeating itself — the same failing call, a run of
        // failures, one file rewritten past the threshold. More steps would be the same steps;
        // the turn ends unfinished and the user redirects it. Outstanding calls are answered so
        // the history stays valid.
        for call in toolCalls where !answered.contains(call.id ?? "") {
          appendToHistory(.tool("[turn ended by the loop guard]", toolCallId: call.id ?? ""))
        }
        record.stopReason = .stuck
        continuation.yield(.stuckDetected(reason: stuckReason))
        break loop
      }

      if refusalsInARow >= Self.maxRefusalsPerTurn {
        // The model keeps asking for what it isn't allowed to have. Retrying is what a
        // model does; burning the step budget (and the user's money) on refusals isn't
        // work, so the turn ends here and the user decides — widen the permissions, or
        // ask for something else.
        for call in toolCalls where !answered.contains(call.id ?? "") {
          appendToHistory(.tool("[turn ended after repeated denials]", toolCallId: call.id ?? ""))
        }
        record.stopReason = .deniedLoop
        continuation.yield(.deniedLoop(count: refusalsInARow))
        break loop
      }

      // Every result of the step is in history: what the step's tools attached follows them,
      // in commit order, before the model's next request.
      for attachment in stepAttachments {
        appendToHistory(attachment)
      }
    }

    if !record.finished, !interrupted, turnError == nil, record.stopReason == nil {
      // The for-loop ran out of steps mid-task — surface it instead of ending the
      // turn as if the model had chosen to stop.
      record.stopReason = .maxSteps
      continuation.yield(.stepLimitReached(maxSteps: maxStepsPerTurn))
    }

    // Background work the loop didn't settle. The natural finish joined it above; any other
    // end — the step limit (the join itself may have spent the last step with a second run
    // still out), a hook's `continue: false`, a denied loop, the budget, a request error —
    // would otherwise leave the detached runs to outlive the turn: a one-shot exits on them
    // (no nested record, no SubagentStop, their spend missing from the envelope, whatever bash
    // they spawned abandoned) and the REPL hands them to an idle prompt. So a turn that still
    // has a conversation to deliver into joins them all — each report lands in history for the
    // next turn, its cost in this record — while a turn that ended on budget or an error
    // cancels them the way an interrupt does. Either way nothing is left running when `send`
    // returns, unless the embedder opted out of joining (`joinBackgroundAtTurnEnd: false`).
    if !interrupted, configuration.joinBackgroundAtTurnEnd, pendingBackgroundCount > 0 {
      if record.stopReason == .budget || turnError != nil {
        let stranded = await cancelBackgroundWork()
        if stranded > 0 {
          record.costUSD += stranded
          turnCost += stranded
          costUSD += stranded
        }
      } else {
        continuation.yield(.subagentJoining(pending: pendingBackgroundCount))
        while let joined = await awaitAnyBackground() {
          deliver(joined.outcome, via: joined.source, record: &record, turnCost: &turnCost, continuation: continuation)
        }
        // The wait was cut short by an interrupt: what is still out is cancelled below.
        if Task.isCancelled { interrupted = true }
      }
    }

    if interrupted {
      // Background work belongs to the turn that started it: an interrupt cancels it too, and
      // what the cancelled runs had spent is drained like any stranded delegation's.
      let stranded = await cancelBackgroundWork()
      if stranded > 0 {
        record.costUSD += stranded
        turnCost += stranded
        costUSD += stranded
      }
      record.stopReason = .interrupted
      continuation.yield(.interrupted)
    }
    if turnError != nil {
      record.stopReason = .error
    }

    // Structured output: a finished turn is asked, in one side request over chat completions,
    // to restate its answer as the JSON object the configuration's schema describes. The
    // request never enters history (a resumed session must not see a JSON monologue); the
    // validated object lands on the record and the event, its spend on this turn's books. A
    // turn that ended any other way — step limit, budget, hook stop, interrupt, error — asked
    // nothing: there is no answer to structure. A model that never validates is not a thrown
    // turn: the prose stands, the record says `structured_output_failed`, the envelope says why.
    if let outputSchema = outputSchemaOverride, record.finished, !interrupted, turnError == nil {
      do {
        let structured = try await StructuredCompletion.request(
          service: service,
          model: model,
          profile: profile,
          messages: [.system(systemText(pack: pack, profile: profile))] + chatReplayHistory + [.user(Self.structuredFinalPrompt)],
          schema: outputSchema,
          tools: requestTools(for: profile)?.map(\.toolDefinition),
          costOf: { [self] usage in await self.cost(of: usage, model: self.model) })
        // Every attempt is paid for, valid or not.
        record.costUSD += structured.costUSD
        turnCost += structured.costUSD
        costUSD += structured.costUSD
        if let tokens = structured.promptTokens {
          record.promptTokens = (record.promptTokens ?? 0) + tokens
        }
        if let tokens = structured.completionTokens {
          record.completionTokens = (record.completionTokens ?? 0) + tokens
        }
        if let value = structured.value {
          record.structuredOutputValid = true
          record.structuredOutput = Self.recordableStructuredOutput(value)
          continuation.yield(.structuredOutput(json: value, valid: true, errors: []))
        } else {
          record.structuredOutputValid = false
          record.stopReason = .structuredOutputFailed
          continuation.yield(.structuredOutput(json: nil, valid: false, errors: structured.errors))
        }
      } catch {
        if error is CancellationError || Task.isCancelled {
          // Ctrl-C or a `--timeout` deadline landing during the side request is the interrupt
          // it would have been during the loop — up to three full-history requests is a wide
          // window for one — so the turn ends the way an interrupted loop ends: the record says
          // `interrupted` and is not `finished` (so the verifier isn't asked into a cancelled
          // task), pending background work is cancelled with it, `.interrupted` is yielded, and
          // nothing is thrown. The prose the model gave stands in history.
          let stranded = await cancelBackgroundWork()
          if stranded > 0 {
            record.costUSD += stranded
            turnCost += stranded
            costUSD += stranded
          }
          interrupted = true
          record.finished = false
          record.stopReason = .interrupted
          continuation.yield(.interrupted)
        } else {
          // A transport error on the side request is the verifier's shape: the turn is
          // reported as an error, with everything the loop had already recorded.
          turnError = error
          record.stopReason = .error
        }
      }
    }

    if let verifyWith, record.finished {
      do {
        let verdict = try await Verifier.run(
          task: text, outcome: finalText, model: verifyWith, service: service,
          context: verifierContext(model: verifyWith))
        let verifierCost: Double
        if let priced = verdict.costUSD {
          verifierCost = priced
        } else {
          verifierCost = await cost(of: verdict.usage, model: verifyWith) ?? 0
        }
        record.costUSD += verifierCost
        turnCost += verifierCost
        costUSD += verifierCost
        record.verifierPassed = verdict.passed
        record.verifierConfidence = verdict.confidence
        continuation.yield(.verifier(passed: verdict.passed, verdict: verdict.text))
      } catch {
        if turnError == nil {
          turnError = error
          record.stopReason = .error
        }
      }
    }

    // Hook spend the per-call drain missed — a prompt hook or the judge on a call that was then
    // denied, the Stop hooks of a natural finish — is booked on this turn, not the next one's
    // first executed call. (The Stop hooks of every other end and the SessionEnd hooks run after
    // the record is written and land on the next turn, or nowhere in a one-shot; documented
    // residue.)
    let hookSpend = await drainHookSpend()
    if hookSpend > 0 {
      record.costUSD += hookSpend
      turnCost += hookSpend
      costUSD += hookSpend
      record.hookCostUSD = (record.hookCostUSD ?? 0) + hookSpend
    }

    // The summary is scrubbed too: the model may have repeated a secret it saw before a hook's
    // `updatedInput`, or from memory — runs.jsonl is not the place for it.
    record.summary = String(
      (configuration.toolResultGuard.redaction ? SecretScrubber.scrub(finalText).text : finalText).prefix(500))
    if taint != nil { record.tainted = true }
    try? store.append(record)
    lastRecord = record
    persist(.cost(turnUSD: turnCost, sessionUSD: costUSD))

    if let turnError {
      continuation.finish(throwing: turnError)
      return
    }
    // Stop hooks run once per turn end that wasn't an interrupt — a final gate (run the
    // tests, notify). The natural finish already ran them (where a block could continue the
    // turn); every other end runs them here, and a block now can only be reported.
    if let engine = hooks, !interrupted {
      let outcome: HookOutcome
      if let ran = stopOutcome {
        outcome = ran
      } else {
        outcome = await engine.stop(turnIndex: record.turnIndex, stopHookActive: stopContinuations > 0)
      }
      for notice in outcome.notices(for: .stop, includeFeedback: true) {
        continuation.yield(.hookNotice(event: notice.event, output: notice.output))
      }
      if let reason = outcome.blockReason {
        let why = record.finished
          ? "the turn was already continued \(stopContinuations) times"
          : "the turn ended on \(record.stopReason?.rawValue ?? "an unknown reason"), not a finish"
        continuation.yield(.hookNotice(
          event: HookEvent.stop.rawValue, output: "asked to continue (\(reason)) — \(why); ending"))
      }
    }
    continuation.yield(.turnFinished(TurnStats(
      steps: record.steps,
      toolCalls: record.toolCalls,
      turnCostUSD: turnCost,
      sessionCostUSD: costUSD,
      requestedModel: record.model,
      routedModels: record.routedModels,
      promptTokens: lastPromptTokens,
      contextLength: profile.contextLength,
      durationSeconds: Date().timeIntervalSince(record.startedAt),
      cachedPromptTokens: record.cachedTokens,
      totalPromptTokens: record.promptTokens)))
    continuation.finish()
  }

  // MARK: Structured output

  /// The one user turn the structured side request ends with. Fixed and family-neutral —
  /// harness plumbing, not a pack line: the schema itself rides `response_format` (or
  /// `StructuredCompletion`'s fallback instruction when the manifest doesn't advertise it),
  /// never the prompt pack.
  static let structuredFinalPrompt =
    "Now answer the task above as one JSON object matching the required schema. No prose, no code fences."

  /// The validated object as the record keeps it: itself when it encodes within
  /// `RunRecord.maxStructuredOutputBytes`, else nil — `structuredOutputValid` still says it
  /// validated, and the run's result carries the value whatever its size.
  static func recordableStructuredOutput(_ value: JSONValue) -> JSONValue? {
    guard let encoded = try? JSONEncoder().encode(value),
          encoded.count <= RunRecord.maxStructuredOutputBytes
    else { return nil }
    return value
  }

  // MARK: Dialect steps

  /// One streamed assistant step, accumulated dialect-agnostically. The loop above
  /// consumes this shape regardless of the wire format the step spoke.
  private struct StepOutcome {
    var text = ""
    var toolCalls: [ToolCall] = []
    /// `usage.cost` as reported; nil when the provider doesn't price responses.
    var cost: Double?
    var promptTokens: Int?
    var completionTokens: Int?
    /// Prompt tokens this request read from the provider's prompt cache — a subset of
    /// `promptTokens` (chat `prompt_tokens_details.cached_tokens`, `/messages`
    /// `cache_read_input_tokens`, `/responses` `input_tokens_details.cached_tokens`); nil when
    /// the usage carried no such figure. Summed onto `RunRecord.cachedTokens`.
    var cachedPromptTokens: Int?
    /// Served models observed this step, in order.
    var routed: [String] = []
    var interrupted = false
    /// Native-endpoint misbehavior (thrown transport error or a failed response).
    /// Chat steps never set this — chat is the floor there's no falling back from.
    var failure: String?
    /// Whether any text/reasoning delta reached the caller (a fallback rerun after
    /// output would duplicate what the user already saw).
    var emittedOutput = false
    /// The step's replayable reasoning state (`ReasoningDetails` entries: signed thinking
    /// blocks, encrypted reasoning, chat `reasoning_details`), carried on the assistant
    /// message so the next request can replay it. Empty on a router that sends none.
    var reasoningDetails: [JSONValue] = []
    /// Reasoning entries this step's request *replayed* from the history it sent — Anthropic
    /// thinking blocks on `/messages` (only while thinking was enabled for the step), `reasoning`
    /// items on `/responses`, `reasoning_details` on a chat request to a replaying provider.
    /// Summed onto `RunRecord.reasoningReplayed`; a retried attempt rebuilds the request, and the
    /// returned outcome's count is the one that stands.
    var reasoningReplayed = 0
    /// The wire's word for why the reply ended — chat's `finish_reason`, `/messages`'
    /// `stop_reason`, `/responses`' `incomplete_details.reason`; nil when the stream never
    /// said. `OutputTruncation.isTruncation` reads the output-limit cutoff out of it.
    var finishReason: String?
    /// Names of the tool calls the output-limit cutoff landed inside of, dropped before the
    /// step's calls reach history (`OutputTruncation.droppingPartialToolCall`) — a call with
    /// half its JSON would otherwise burn a coaching step or be refused by the next request.
    var droppedToolCalls: [String] = []
    /// Attempts this step retried before the one that produced it (`TransportPolicy`); summed
    /// onto `RunRecord.retries`.
    var retries = 0
    /// The exhausted transport failure a native step ended on before any output — `retries`
    /// re-sends and the last attempt still failed on the wire (never chat's: chat throws it).
    /// The fallback block reads it as a `transport`-category failure: the step reruns on chat
    /// under `.auto`, and the verdict cools the native route for minutes, never a week.
    var transportFailure: TransportError?

    /// Whether the reply hit the output-token limit.
    var isTruncated: Bool { OutputTruncation.isTruncation(finishReason) }
  }

  /// One step on the dialect, retried on the wire's transient failures. The dispatch is the
  /// single chokepoint for every dialect, so the retry decision is one decision: a step that
  /// failed **before any output token** with a `TransportPolicy.retryReason` — a 429/5xx, an
  /// overloaded or timed-out provider, a lost connection, a mid-stream error event, a stream
  /// gone idle — waits the jittered backoff (`.retrying` on the event stream) and runs again,
  /// the request budget for HTTP-level failures and the stream budget for streams that broke,
  /// both under the total wait cap; a pre-output failure the policy doesn't retry keeps its
  /// dialect's own shape (chat propagates the error, native records it as a `failure` for the
  /// fallback block); a failure after output is never retried — chat propagates it as always,
  /// and a native step propagates a transport-class one the same way while recording any other
  /// as a `failure`. Exhausted retries throw `TransportError.retriesExhausted` on chat (the floor
  /// has nothing to fall back to); on a native dialect they come back as a step failure carrying
  /// the error (`StepOutcome.transportFailure`), so the fallback block reruns the step on chat
  /// under `.auto` and records a `transport` verdict — a cooldown of minutes, never the week-long
  /// pin an endpoint failure earns. A `cache_control` refusal (a gateway that rejects the field)
  /// is re-sent once without prompt-cache breakpoints, which stay off for the session. A
  /// truncated reply's cut-off tool call is dropped here too, before it can enter history.
  private func streamStep(
    dialect: Dialect,
    pack: PromptPack,
    profile: ModelProfile,
    knownRouted: [String],
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async throws -> StepOutcome
  {
    let transport = configuration.transport
    var requestRetries = 0
    var streamRetries = 0
    /// Re-sends outside the transport budgets: the one after a refused `cache_control`.
    var recoveryRetries = 0
    var waitedSeconds = 0.0
    // Exhausted retries on chat throw — the floor has nothing to fall back to. On a native
    // dialect they come back as a step failure carrying the error, so the fallback block can
    // rerun the step on chat under `.auto` and record a `transport` verdict (a cooldown, never
    // the week-long pin an endpoint failure earns): a native route that is down no longer
    // errors every turn, and a 429 storm never pins the model to chat for a week.
    func giveUp(_ error: TransportError, retries: Int) throws -> StepOutcome {
      switch dialect {
      case .chat:
        throw error
      case .messages, .responses:
        var outcome = StepOutcome()
        outcome.failure = "\(error)"
        outcome.transportFailure = error
        outcome.retries = retries
        return outcome
      }
    }
    while true {
      do {
        var outcome = try await dispatchStep(
          dialect: dialect, pack: pack, profile: profile, knownRouted: knownRouted, continuation: continuation)
        outcome.retries = requestRetries + streamRetries + recoveryRetries
        let calls = OutputTruncation.droppingPartialToolCall(from: outcome.toolCalls, truncated: outcome.isTruncated)
        if let dropped = calls.dropped {
          outcome.toolCalls = calls.kept
          outcome.droppedToolCalls.append(dropped.function?.name ?? "?")
        }
        return outcome
      } catch let failed as StepTransportError {
        let retries = requestRetries + streamRetries + recoveryRetries
        if Task.isCancelled {
          // The turn was interrupted under the request: the loop's interrupt path takes over.
          var interrupted = StepOutcome()
          interrupted.interrupted = true
          interrupted.retries = retries
          return interrupted
        }
        guard let reason = TransportPolicy.retryReason(for: failed.underlying) else {
          // A gateway refusing the request's `cache_control` markers is neither the dialect's
          // failure nor the wire's: the step is re-sent once without prompt-cache breakpoints,
          // which stay off for the rest of the session (`cacheControlRefused`). On chat the 400
          // would otherwise end every turn (no fallback there); on a native dialect it would
          // fall back and record a verdict against an endpoint that is fine.
          if !cacheControlRefused, cacheBreakpointsEnabled(profile: profile),
             DialectVerdict.category(forFailure: "\(failed.underlying)", model: model)
               == DialectVerdict.cacheControlCategory
          {
            cacheControlRefused = true
            recoveryRetries += 1
            continuation.yield(.retrying(attempt: retries + 1, reason: PromptCache.refusalRetryReason))
            continue
          }
          // Not a retry: exactly what the dialect did with the error before the retry layer
          // existed — chat throws it, a native step reports it for the fallback block.
          switch dialect {
          case .chat:
            throw failed.underlying
          case .messages, .responses:
            var outcome = StepOutcome()
            outcome.failure = "\(failed.underlying)"
            outcome.retries = retries
            return outcome
          }
        }
        let exhausted: Bool
        switch failed.phase {
        case .request:
          requestRetries += 1
          exhausted = requestRetries > transport.maxRequestRetries
        case .stream:
          streamRetries += 1
          exhausted = streamRetries > transport.maxStreamRetries
        }
        let delay = transport.delay(forAttempt: requestRetries + streamRetries, retryAfter: reason.retryAfter)
        if exhausted {
          return try giveUp(
            .retriesExhausted(reason: reason.text, retries: retries, underlying: failed.underlying), retries: retries)
        }
        if waitedSeconds + delay > transport.maxRetryWaitSeconds {
          // Still in budget by count, but the wait would cross the cap: the error names the cap
          // it hit, not just the 429 (a `Retry-After: 120` reads as what stopped the retries).
          let note = TransportPolicy.waitCapNote(delay: delay, retryAfter: reason.retryAfter, cap: transport.maxRetryWaitSeconds)
          return try giveUp(
            .retriesExhausted(reason: reason.text + note, retries: retries, underlying: failed.underlying), retries: retries)
        }
        continuation.yield(.retrying(attempt: requestRetries + streamRetries, reason: reason.text))
        do {
          try await transport.sleep(UInt64(delay * 1_000_000_000))
        } catch is CancellationError {
          var interrupted = StepOutcome()
          interrupted.interrupted = true
          interrupted.retries = requestRetries + streamRetries + recoveryRetries
          return interrupted
        }
        waitedSeconds += delay
      }
    }
  }

  /// The dialect dispatch `streamStep` retries around.
  private func dispatchStep(
    dialect: Dialect,
    pack: PromptPack,
    profile: ModelProfile,
    knownRouted: [String],
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async throws -> StepOutcome
  {
    switch dialect {
    case .chat:
      return try await chatStep(
        pack: pack, profile: profile, knownRouted: knownRouted, continuation: continuation)
    case .messages:
      return try await messagesStep(
        pack: pack, profile: profile, knownRouted: knownRouted, continuation: continuation)
    case .responses:
      return try await responsesStep(
        pack: pack, profile: profile, knownRouted: knownRouted, continuation: continuation)
    }
  }

  private func chatStep(
    pack: PromptPack,
    profile: ModelProfile,
    knownRouted: [String],
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async throws -> StepOutcome
  {
    var outcome = StepOutcome()
    var accumulator = StreamAccumulator()
    // The history this request sends (`chatReplayHistory`: the entries already stripped on a
    // provider that doesn't replay them), read once — what it carries is what the step replayed.
    let replay = chatReplayHistory
    outcome.reasoningReplayed = replay.reduce(0) { $0 + ($1.reasoningDetails?.count ?? 0) }
    // The request itself: an HTTP-level refusal or a connection failure lands here, before any
    // token, and goes to the retry loop typed by phase (`StepTransportError`); a cancellation
    // is the interrupt it always was.
    let stream: AsyncThrowingStream<ChatCompletionChunk, Error>
    do {
      stream = configuration.transport.idleGuarded(try await service.chatCompletionStream(
        ChatCompletionRequest(
          model: model,
          models: fallbackModelsField,
          // The system text and the last history message carry the prompt-cache breakpoints
          // on the Anthropic family (`CachePolicy`); without one this is exactly
          // `[.system(text)] + history`.
          messages: PromptCache.chatMessages(
            system: systemText(pack: pack, profile: profile),
            history: replay,
            breakpoint: cacheBreakpoint(profile: profile)),
          reasoning: chatReasoning(profile: profile),
          reasoningEffort: chatReasoningEffort(profile: profile),
          tools: requestTools(for: profile)?.map(\.toolDefinition),
          streamOptions: traits.requestsStreamUsage ? StreamOptions(includeUsage: true) : nil,
          extraBody: fallbackExtraBody)))
    } catch is CancellationError {
      outcome.interrupted = true
      return outcome
    } catch {
      throw StepTransportError(phase: .request, underlying: error)
    }
    do {
      for try await chunk in stream {
        let deltas = accumulator.ingest(chunk)
        // Surface routing as soon as the served model is known, before any text.
        noteRouted(
          accumulator.routedModel, provider: accumulator.provider,
          outcome: &outcome, knownRouted: knownRouted, continuation: continuation)
        yieldDeltas(text: deltas.text, reasoning: deltas.reasoning, outcome: &outcome, continuation: continuation)
      }
    } catch is CancellationError {
      outcome.interrupted = true
    } catch let error where !outcome.emittedOutput {
      // The stream broke before the model said anything — retryable in principle; after
      // output the error propagates exactly as it always did (a rerun would repeat the text).
      throw StepTransportError(phase: .stream, underlying: error)
    }
    outcome.text = accumulator.text
    outcome.toolCalls = accumulator.toolCalls
    outcome.reasoningDetails = accumulator.reasoningDetails
    outcome.finishReason = accumulator.finishReason
    outcome.cost = accumulator.usage?.cost
    outcome.promptTokens = accumulator.usage?.promptTokens
    outcome.completionTokens = accumulator.usage?.completionTokens
    outcome.cachedPromptTokens = accumulator.cachedPromptTokens
    return outcome
  }

  /// The history a request is built from, in the order it is sent — the one point where every
  /// dialect step (and every side request over the conversation) reads the conversation:
  /// `chatStep` through `chatReplayHistory`, `messagesStep` through `MessagesTranslator.history`,
  /// `responsesStep` through `ResponsesTranslator.history`, the thinking rule, the structured
  /// side request, `aside` and `contextReport`. The microcompacted **view** (C2): `history` with
  /// every large tool result below the clearing cutoff replaced by a one-line stub
  /// (`Microcompaction.view` — the last `keepRecentToolResults` results stay verbatim, a result
  /// under `clearMinChars` too, an `error:` result keeps its first line, a framed result keeps its
  /// frame), the persisted `history` untouched. Pure over `history` and `clearedBelow`, so the
  /// translators see one view per step; the cutoff moves only at turn start and at a mid-turn
  /// relief point, so the view is byte-stable from one step to the next.
  private func requestHistory() -> [Message] {
    Microcompaction.view(of: history, clearedBelow: effectiveClearingCutoff, policy: configuration.compaction)
  }

  /// The names `availableTools(for:)` last answered with — what the current model was offered.
  /// Written at request-build time (every step's request and system text pass through the gate
  /// before the step's tool calls arrive), read by `preflightError` so a call to a tool this
  /// session *has* but the model was *not* offered — a hallucinated `view_image` from a text
  /// model, or one remembered from before a `/model` swap — is answered with a coaching error
  /// instead of running (an image part in the next request would fail it whole). nil until the
  /// first request is built.
  private var availableToolNames: Set<String>?

  /// The tools a model may use this session, given what its manifest says about it: `tools` in
  /// definition order, minus every `CapabilityGatedTool` whose `isAvailable(for:configuration:)`
  /// says no for this profile (`view_image` without vision, `think` under adaptive omission for a
  /// natively reasoning model). A tool that doesn't conform is always available — byte-identical
  /// to before for every existing tool. The place a tool's presence is decided per model: what
  /// the tool sections of the system prompt list, and what `requestTools(for:)` sends. A tool
  /// absent here is absent from the prompt and the request alike, so the two never disagree.
  ///
  /// The gate reads the configuration *as it stands*: the immutable seed with the live dials
  /// folded in (`/effort` moves `reasoningEffortOverride`, not `configuration.reasoningEffort`),
  /// so an `/effort off` brings `think` back on the very next request.
  private func availableTools(for profile: ModelProfile) -> [any AgentTool] {
    var effective = configuration
    effective.reasoningEffort = reasoningEffort
    let available = Self.offeredTools(tools, profile: profile, configuration: effective)
    availableToolNames = Set(available.map(\.name))
    return available
  }

  /// The pure rule behind `availableTools(for:)`: `tools` in definition order minus every
  /// `CapabilityGatedTool` whose `isAvailable(for:configuration:)` says no for `profile`
  /// under `configuration` (a non-conforming tool is always kept). Public so a caller that
  /// has no session yet — `arnes do` writing its stream-json `init` line before the first
  /// request — can name the offered set exactly as the session will; pass the configuration
  /// the session will run with, live dials folded in (`reasoningEffort` is what the `think`
  /// gate reads).
  public static func offeredTools(
    _ tools: [any AgentTool], profile: ModelProfile, configuration: Configuration
  ) -> [any AgentTool] {
    tools.filter { tool in
      (tool as? any CapabilityGatedTool)?.isAvailable(for: profile, configuration: configuration) ?? true
    }
  }

  /// The tool definitions a request to `profile` carries, in definition order — nil when the
  /// manifest says the model takes no tools (the field is then omitted, exactly as before), else
  /// `availableTools(for:)`, each dialect mapping its own definition shape over it. The one
  /// expression every request builder reads instead of `profile.supportsTools ? tools : nil`.
  private func requestTools(for profile: ModelProfile) -> [any AgentTool]? {
    profile.supportsTools ? availableTools(for: profile) : nil
  }

  /// History as a chat-completions request may carry it. A router that documents replaying
  /// `reasoning_details` (`ProviderTraits.replaysReasoningDetails` — OpenRouter) gets the
  /// assistant messages as they are; any other gets a copy with the entries stripped, since a
  /// generic gateway may reject an unknown message field. History itself is never mutated by a
  /// request. The one rule for every chat request over the history: `chatStep`, and the
  /// structured-output side request, which is a chat request whatever dialect the turn spoke —
  /// a `/messages` turn under `--effort` leaves Anthropic entries on its tool-call messages.
  /// Reads `requestHistory()`, so a chat request sends the same view the native dialects do.
  private var chatReplayHistory: [Message] {
    let view = requestHistory()
    return traits.replaysReasoningDetails ? view : ReasoningDetails.stripped(view)
  }

  // MARK: Prompt cache

  /// Whether an endpoint refused this session's `cache_control` markers (a gateway that does
  /// not accept the field): set by `streamStep` when a request fails naming the field, after
  /// which the step is re-sent once without breakpoints and no later request carries any —
  /// the session's answer to a 400 that would otherwise end every chat turn or pin a native
  /// dialect. Sticky for the session: the gateway has not changed.
  public private(set) var cacheControlRefused = false

  /// Whether requests to `profile` mark their stable prefix with `cache_control` breakpoints
  /// (`CachePolicy`): the policy says so, the model is Anthropic's (the manifest's family — a
  /// gateway alias resolves to it too), the provider accepts the field
  /// (`ProviderTraits.supportsCacheControl`) **and** no endpoint has refused it this session
  /// (`cacheControlRefused`). Every other request carries no `cache_control` anywhere —
  /// byte-identical to a session without the policy.
  private func cacheBreakpointsEnabled(profile: ModelProfile) -> Bool {
    !cacheControlRefused
      && configuration.cachePolicy.anthropicBreakpoints
      && profile.family == .anthropic
      && traits.supportsCacheControl
  }

  /// The breakpoint a request to `profile` marks its prefix with, or nil when it marks nothing.
  /// Applied at request-build time only, on the view `requestHistory()` returns — never on a
  /// persisted message.
  private func cacheBreakpoint(profile: ModelProfile) -> CacheControl? {
    cacheBreakpointsEnabled(profile: profile) ? configuration.cachePolicy.cacheControl : nil
  }

  // MARK: Reasoning effort

  /// OpenRouter's `reasoning` object for a chat request — nil unless the dial is set *and* the
  /// model advertises reasoning support, so a model that doesn't understand it never receives
  /// it, *and* the provider speaks that spelling (`ProviderTraits.reasoningShape == .openrouter`):
  /// a LiteLLM or OpenAI-compatible gateway refuses the object (`400 reasoning: Extra inputs are
  /// not permitted`) and takes `chatReasoningEffort` instead; `.none` sends neither, so the dial
  /// applies to no chat request there (the native dialects have their own shapes).
  private func chatReasoning(profile: ModelProfile) -> Reasoning? {
    guard traits.reasoningShape == .openrouter, let reasoningEffort, profile.supportsReasoning else { return nil }
    return Reasoning(effort: reasoningEffort)
  }

  /// OpenAI's chat-completions spelling of the same dial — the top-level `reasoning_effort`
  /// string LiteLLM translates and an OpenAI-compatible server accepts natively — under the
  /// same two gates (the dial set, the manifest advertising reasoning) and only for
  /// `reasoningShape == .openai`. The level rides verbatim (`Reasoning.Effort.rawValue`), never
  /// remapped: a level the gateway rejects is the gateway's message to the user.
  private func chatReasoningEffort(profile: ModelProfile) -> Reasoning.Effort? {
    guard traits.reasoningShape == .openai, let reasoningEffort, profile.supportsReasoning else { return nil }
    return reasoningEffort
  }

  private func responsesReasoning(profile: ModelProfile) -> ResponsesReasoning? {
    guard let reasoningEffort, profile.supportsReasoning else { return nil }
    return ResponsesReasoning(effort: reasoningEffort)
  }

  /// Anthropic `/messages` uses a token *budget*, not an effort word — map the dial to one.
  /// `.none` disables thinking; everything else enables it with a budget that fits under the
  /// bumped `max_tokens`. The budget here is the dial's; the request clamps it under the
  /// manifest's output ceiling (`messagesRequestShape`).
  private func messagesThinking(profile: ModelProfile) -> Thinking? {
    guard let reasoningEffort, profile.supportsReasoning else { return nil }
    guard reasoningEffort != .none else { return .disabled }
    return .enabled(budgetTokens: Self.thinkingBudget(for: reasoningEffort))
  }

  /// Whether this request enables thinking: the dial says so, the manifest allows it, and the
  /// history can carry it (`MessagesTranslator.canEnableThinking` — the thinking rule).
  private func messagesThinkingEnabled(profile: ModelProfile) -> Bool {
    guard case .enabled = messagesThinking(profile: profile) else { return false }
    // The rule reads the history the request will carry — the same view `messagesStep` sends.
    return MessagesTranslator.canEnableThinking(history: requestHistory())
  }

  /// The `max_tokens` and `thinking` a `/messages` request sends — the output cap bumped above
  /// the thinking budget when thinking is on (Anthropic requires `max_tokens > budget_tokens`),
  /// otherwise the usual default, both under the manifest's `max_completion_tokens` when the
  /// model states one (invariant 1). Thinking enabled → the dial's budget clamped under the
  /// ceiling; the dial off (`.none`) → the explicit `disabled`; the dial set but the history
  /// unable to carry a thinking block → no `thinking` field for this step (and, since the step's
  /// own tool-call turn then carries no block either, for the rest of the turn's tool steps —
  /// thinking is back with the next user message); a ceiling with no room for the minimum
  /// budget plus its headroom (`outputPlan` returns no budget) → no `thinking` field either.
  /// `thinking` is `.enabled` exactly when the request replays thinking blocks — the caller reads
  /// the replay decision off this shape so the two never disagree.
  private func messagesRequestShape(profile: ModelProfile, thinkingEnabled: Bool) -> (maxTokens: Int, thinking: Thinking?) {
    let dial = messagesThinking(profile: profile)
    guard thinkingEnabled, case .enabled(let budgetTokens, _) = dial else {
      let plan = MessagesTranslator.outputPlan(maxCompletionTokens: profile.maxCompletionTokens, thinkingBudget: nil)
      // A dial the history can't honor this step sends no thinking field; `.disabled` stays.
      let thinking: Thinking? = { if case .disabled = dial { return .disabled } else { return nil } }()
      return (plan.maxTokens, thinking)
    }
    let plan = MessagesTranslator.outputPlan(maxCompletionTokens: profile.maxCompletionTokens, thinkingBudget: budgetTokens)
    guard let budget = plan.budget else { return (plan.maxTokens, nil) }
    return (plan.maxTokens, .enabled(budgetTokens: budget))
  }

  static func thinkingBudget(for effort: Reasoning.Effort) -> Int {
    switch effort {
    case .minimal: return 1024
    case .low: return 4096
    case .medium: return 8192
    case .high: return 16384
    case .xhigh, .max: return 24576
    case .none: return 1024
    }
  }

  private func messagesStep(
    pack: PromptPack,
    profile: ModelProfile,
    knownRouted: [String],
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async throws -> StepOutcome
  {
    var outcome = StepOutcome()
    var accumulator = MessagesAccumulator()
    // Thinking blocks are replayed only on a request that enables thinking, and thinking is
    // enabled only when the history can carry it (the thinking rule) and the manifest ceiling
    // leaves room for a budget — the replay decision is read off the shape the request sends,
    // so a request never contradicts itself.
    let shape = messagesRequestShape(profile: profile, thinkingEnabled: messagesThinkingEnabled(profile: profile))
    let replaysThinking: Bool = { if case .enabled = shape.thinking { return true } else { return false } }()
    // The history this request sends, read once: its Anthropic blocks are replayed only while
    // thinking is enabled for the step, and only then does the step count them as replayed.
    let history = requestHistory()
    outcome.reasoningReplayed = replaysThinking
      ? history.reduce(0) { $0 + MessagesTranslator.thinkingBlocks(for: $1).count }
      : 0
    // A request-level failure goes to the retry loop typed by phase; what it doesn't retry
    // comes back as the `failure` string the fallback block has always read.
    let stream: AsyncThrowingStream<MessagesStreamEvent, Error>
    // The prompt-cache breakpoints (`CachePolicy`): the last tool definition and the last content
    // block of the last message — the system text has no block form on this endpoint in the
    // client, so it is cached behind the message breakpoint rather than marked itself. nil marks
    // nothing and the request is exactly what it was.
    let breakpoint = cacheBreakpoint(profile: profile)
    do {
      stream = configuration.transport.idleGuarded(try await service.messageStream(
        MessagesRequest(
          model: model,
          messages: MessagesTranslator.history(
            history, thinkingEnabled: replaysThinking, breakpointOnLast: breakpoint),
          maxTokens: shape.maxTokens,
          system: systemText(pack: pack, profile: profile),
          thinking: shape.thinking,
          tools: requestTools(for: profile).map { MessagesTranslator.tools($0, breakpointOnLast: breakpoint) },
          models: fallbackModelsField,
          extraBody: fallbackExtraBody)))
    } catch is CancellationError {
      outcome.interrupted = true
      return outcome
    } catch {
      throw StepTransportError(phase: .request, underlying: error)
    }
    do {
      for try await event in stream {
        let deltas = accumulator.ingest(event)
        noteRouted(
          accumulator.routedModel, provider: nil,
          outcome: &outcome, knownRouted: knownRouted, continuation: continuation)
        yieldDeltas(text: deltas.text, reasoning: deltas.reasoning, outcome: &outcome, continuation: continuation)
      }
    } catch is CancellationError {
      outcome.interrupted = true
    } catch let error where !outcome.emittedOutput {
      throw StepTransportError(phase: .stream, underlying: error)
    } catch let error where TransportPolicy.retryReason(for: error) != nil {
      // A transport-class failure after output — a lost connection, a 5xx error event, the
      // idle timeout — is the wire's, not the endpoint's dialect: never retried (a rerun would
      // repeat the text), never a `failure` for the fallback block to record against the
      // endpoint, propagated exactly as chat propagates its own.
      throw error
    } catch {
      outcome.failure = "\(error)"
    }
    outcome.text = accumulator.text
    outcome.toolCalls = accumulator.toolCalls
    outcome.reasoningDetails = accumulator.reasoningDetails
    outcome.finishReason = accumulator.stopReason
    outcome.cost = accumulator.cost
    outcome.promptTokens = accumulator.promptTokens
    outcome.completionTokens = accumulator.completionTokens
    outcome.cachedPromptTokens = accumulator.cachedPromptTokens
    return outcome
  }

  private func responsesStep(
    pack: PromptPack,
    profile: ModelProfile,
    knownRouted: [String],
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async throws -> StepOutcome
  {
    var outcome = StepOutcome()
    var accumulator = ResponsesAccumulator()
    // With reasoning requested, ask for each reasoning item's `encrypted_content` so the
    // next (stateless) request can echo it; without, the request is exactly what it was.
    let reasoning = responsesReasoning(profile: profile)
    // The history this request sends, read once: every `reasoning` item echoed into it is a
    // replayed entry.
    let history = requestHistory()
    outcome.reasoningReplayed = history.reduce(0) { $0 + ResponsesTranslator.reasoningItems(for: $1).count }
    let stream: AsyncThrowingStream<ResponsesStreamEvent, Error>
    do {
      stream = configuration.transport.idleGuarded(try await service.responseStream(
        ResponsesRequest(
          model: model,
          models: fallbackModelsField,
          input: .items(ResponsesTranslator.history(history)),
          instructions: systemText(pack: pack, profile: profile),
          include: reasoning == nil ? nil : [ResponsesTranslator.encryptedReasoningInclude],
          reasoning: reasoning,
          tools: requestTools(for: profile)?.map(ResponsesTranslator.tool),
          extraBody: fallbackExtraBody)))
    } catch is CancellationError {
      outcome.interrupted = true
      return outcome
    } catch {
      throw StepTransportError(phase: .request, underlying: error)
    }
    do {
      for try await event in stream {
        let deltas = accumulator.ingest(event)
        noteRouted(
          accumulator.routedModel, provider: nil,
          outcome: &outcome, knownRouted: knownRouted, continuation: continuation)
        yieldDeltas(text: deltas.text, reasoning: deltas.reasoning, outcome: &outcome, continuation: continuation)
      }
    } catch is CancellationError {
      outcome.interrupted = true
    } catch let error where !outcome.emittedOutput {
      throw StepTransportError(phase: .stream, underlying: error)
    } catch let error where TransportPolicy.retryReason(for: error) != nil {
      // The wire's failure after output, not the endpoint's dialect — propagated like chat's.
      throw error
    } catch {
      outcome.failure = "\(error)"
    }
    if !outcome.interrupted, let failure = accumulator.failure {
      outcome.failure = failure
    }
    outcome.text = accumulator.text
    outcome.toolCalls = accumulator.toolCalls
    outcome.reasoningDetails = accumulator.reasoningDetails
    outcome.finishReason = accumulator.incompleteReason
    outcome.cost = accumulator.cost
    outcome.promptTokens = accumulator.promptTokens
    outcome.completionTokens = accumulator.completionTokens
    outcome.cachedPromptTokens = accumulator.cachedPromptTokens
    return outcome
  }

  // MARK: Provider shaping

  /// The model for work the user didn't name (compaction): the provider's default, or
  /// this session's own model when the provider has none configured.
  private var utilityModel: String {
    traits.defaultModel.isEmpty ? model : traits.defaultModel
  }

  /// OpenRouter spells request-level fallbacks as `models`; LiteLLM as `fallbacks`
  /// (see `fallbackExtraBody`); plain OpenAI-compatible endpoints have none.
  private var fallbackModelsField: [String]? {
    let fallbackModels = configuration.fallbackModels
    return traits.fallbackStyle == .models && !fallbackModels.isEmpty ? fallbackModels : nil
  }

  private var fallbackExtraBody: [String: JSONValue]? {
    let fallbackModels = configuration.fallbackModels
    guard traits.fallbackStyle == .litellmFallbacks, !fallbackModels.isEmpty else { return nil }
    return ["fallbacks": .array(fallbackModels.map { .string($0) })]
  }

  /// Cost for a step whose response carried no `usage.cost`: tokens × the manifest's
  /// per-token prices for the requested model, when the provider is one we estimate
  /// for and the manifest prices it. Nil otherwise — unknown, not zero.
  private func estimatedCost(of step: StepOutcome, profile: ModelProfile) -> Double? {
    guard traits.estimatesCost else { return nil }
    return Self.estimatedCost(
      promptTokens: step.promptTokens, completionTokens: step.completionTokens, profile: profile)
  }

  /// `usage.cost` when reported, else the token estimate for `model` (nil when neither
  /// is available). For the one-shot helper calls: compaction, verification.
  private func cost(of usage: Usage?, model: String) async -> Double? {
    if let cost = usage?.cost { return cost }
    guard traits.estimatesCost, let usage else { return nil }
    let profile = try? await catalog.profile(for: model)
    return Self.estimatedCost(
      promptTokens: usage.promptTokens, completionTokens: usage.completionTokens, profile: profile)
  }

  /// What the verifier may look at besides the task and the report: this run's working
  /// tree and subprocess environment, the manifest, and this session's pricing for the
  /// verifier model — so a diff-aware verifier never needs the loop to change again.
  private func verifierContext(model: String) -> Verifier.Context {
    Verifier.Context(
      workingDirectory: configuration.workingDirectory,
      environment: configuration.subprocessEnvironment,
      catalog: catalog,
      costOf: { [self] usage in await self.cost(of: usage, model: model) },
      rules: configuration.pathRules)
  }

  static func estimatedCost(promptTokens: Int?, completionTokens: Int?, profile: ModelProfile?) -> Double? {
    guard
      let profile,
      let promptPrice = profile.promptPricePerToken,
      let completionPrice = profile.completionPricePerToken,
      promptTokens != nil || completionTokens != nil
    else {
      return nil
    }
    return Double(promptTokens ?? 0) * promptPrice + Double(completionTokens ?? 0) * completionPrice
  }

  /// Records a served model on the step and surfaces it once per turn.
  private func noteRouted(
    _ served: String?,
    provider: String?,
    outcome: inout StepOutcome,
    knownRouted: [String],
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
  {
    guard let served, !outcome.routed.contains(served) else { return }
    outcome.routed.append(served)
    if !knownRouted.contains(served) {
      continuation.yield(.routed(model: served, provider: provider))
    }
  }

  private func yieldDeltas(
    text: String?,
    reasoning: String?,
    outcome: inout StepOutcome,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
  {
    if let text {
      outcome.emittedOutput = true
      continuation.yield(.textDelta(text))
    }
    if let reasoning {
      outcome.emittedOutput = true
      continuation.yield(.reasoningDelta(reasoning))
    }
  }

  /// The prompt pack for the current model, then the project instructions, the embedder's
  /// extra sections, the `SessionStart` hooks' context (`start(source:)`), any
  /// tool-contributed sections (skill and subagent listings), the subagent role suffix when
  /// this is a nested session, plus the compaction summary when one exists. Fixed order: a
  /// stable prefix is what prompt caching keys on.
  private func systemText(pack: PromptPack, profile: ModelProfile) -> String {
    contextSections(pack: pack, profile: profile).map(\.text).joined(separator: "\n\n")
  }

  /// One entry per contributor to the system prompt, in the order `systemText` sends them
  /// (`systemText` is their `"\n\n"` join — the same bytes the request carries): the pack, the
  /// project instructions, each extra section, the hooks' context, each tool's listing, the
  /// delegation guidance, the suffix, the compaction summary. Named for `contextReport`:
  /// a section that starts with a markdown heading is named after it (`Environment`,
  /// `Skills`, `Subagents`, `Role`), the rest by what contributed them. The tool sections are
  /// those of the tools available to `profile` (`availableTools(for:)`) — what a request to
  /// this model carries, never a listing for a tool it won't be given.
  func contextSections(pack: PromptPack, profile: ModelProfile) -> [(name: String, text: String)] {
    var sections: [(name: String, text: String)] = [(name: "pack", text: pack.text)]
    if let projectInstructions = configuration.projectInstructions, !projectInstructions.isEmpty {
      sections.append((name: "project instructions", text: projectInstructions))
    }
    for (index, section) in extraSystemSections.enumerated() where !section.isEmpty {
      sections.append((name: Self.sectionName(section, fallback: "extra section \(index + 1)"), text: section))
    }
    for (index, section) in hookContext.enumerated() where !section.isEmpty {
      sections.append((name: Self.sectionName(section, fallback: "SessionStart hook context \(index + 1)"), text: section))
    }
    let available = availableTools(for: profile)
    for tool in available {
      guard let section = (tool as? PromptContributing)?.promptSection, !section.isEmpty else { continue }
      sections.append((name: Self.sectionName(section, fallback: "\(tool.name) listing"), text: section))
    }
    // The pack's delegation guidance, only for a session that can delegate (name-based: the
    // task tool is the one tool named `task`); it follows the agent listing it refers to.
    if available.contains(where: { $0.name == "task" }) {
      sections.append((name: "Delegation", text: pack.delegation))
    }
    if let systemSuffix = configuration.systemSuffix {
      sections.append((name: Self.sectionName(systemSuffix, fallback: "system suffix"), text: systemSuffix))
    }
    if let compactionSummary {
      sections.append((
        name: "Conversation summary",
        text: "# Conversation summary\nEarlier context was compacted. Rely on these notes:\n" + compactionSummary))
    }
    return sections
  }

  /// A section's display name: its first line's markdown heading without the `#`s, or
  /// `fallback` when the section doesn't open with one.
  static func sectionName(_ text: String, fallback: String) -> String {
    let first = text.prefix { $0 != "\n" }
    guard first.hasPrefix("#") else { return fallback }
    let heading = first.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
    return heading.isEmpty ? fallback : heading
  }

  // MARK: Helpers

  /// What the permission gate decided about one call: the model-facing denial text (nil
  /// when the call may run) and the audit row. The row is nil only for a call that was
  /// never gated — a free read-only call is not a decision, and recording one would fill
  /// the record with `grep` noise.
  struct GateOutcome {
    var denial: String?
    var decision: ToolDecision?
    /// What a `PermissionRequest` hook had to say to the user (runner errors, `systemMessage`s).
    var notices: [HookNotice] = []
  }

  /// Decides whether one tool call may run, and produces its audit row.
  /// The gate is per call: the read tools are free inside the working directory and
  /// ask outside it (`AgentTool.permission(for:)`). `hookDecision` is what the PreToolUse
  /// hooks said (already-denied calls never get here): `ask` forces a prompt even on a
  /// read-only or pre-approved call; `allow` lifts the prompt for an ordinary mutation
  /// only — a hook narrows the deterministic layer, it never widens it past `.sensitive`,
  /// a deny rule or plan mode.
  ///
  /// Precedence: deny rule → plan mode → the deterministic approvals (allow rule, hook
  /// allow, session grant, bypass/acceptEdits) → the `PermissionRequest` hooks → the
  /// delegate. An `ask` rule or hook overrides every approval below it and forces the
  /// prompt; a PermissionRequest hook then answers that prompt (deny always, allow for an
  /// ordinary mutation only) or lets the human have it.
  private func permissionDenial(
    name: String,
    argumentsJSON: String,
    callId: String? = nil,
    turnIndex: Int? = nil,
    hookDecision: HookOutcome.Decision = .none)
    async -> GateOutcome
  {
    guard let tool = tools.first(where: { $0.name == name }) else { return GateOutcome() }
    let arguments = Self.decodeArguments(argumentsJSON)
    var level = tool.permission(for: arguments)
    // Taint: after untrusted content, a `bash` command that reaches the network is escalated
    // to `.sensitive` — so `bypass`/`acceptEdits`, grants and hook allows stop applying, the
    // interactive prompt is the loud one, and an unattended run refuses it — and a call that is
    // `.sensitive` already (an out-of-tree write, a destructive command) is marked so the
    // delegate knows. Read-only work stays free: the taint is about *acting*, not reading — with
    // one exception, `web_fetch` (T5): an allowlisted host is `.readOnly` for a clean session,
    // but a fetch is network-reaching whatever its tier, and after untrusted content its URL is
    // exactly the channel an injected instruction would carry data out through (`?k=<the .env>`
    // to a host under an allowlisted parent domain), so every fetch is escalated too.
    var taintedCall = false
    var taintPrefix = ""
    /// The audit row's word for a tainted call whose delegate said yes.
    var taintNote: String?
    let fetch = name == WebFetchTool.toolName
    if let taint, configuration.toolResultGuard.taint, level != .readOnly || fetch {
      let network = fetch || (name == "bash" && ShellCommand.reachesNetwork(arguments["command"]?.stringValue ?? ""))
      if level == .sensitive || network {
        level = .sensitive
        taintedCall = true
        taintPrefix = "[after untrusted content from \(taint.source): \(taint.reason)] "
        taintNote = fetch ? "tainted web fetch" : network ? "tainted network command" : "tainted sensitive call"
      }
    }
    var hookAsks = false
    if case .ask = hookDecision { hookAsks = true }
    guard level != .readOnly || hookAsks else { return GateOutcome() }
    let root = configuration.workingDirectory
    let tier = ToolDecision.Tier(level)
    func row(_ outcome: ToolDecision.Outcome, _ source: ToolDecision.Source, _ reason: String? = nil)
      -> ToolDecision
    {
      ToolDecision(tool: name, tier: tier, decision: outcome, source: source, reason: reason)
    }

    // The rules file speaks first: a deny rule refuses outright; an ask rule forces a
    // prompt even where a mode or a session grant would otherwise auto-approve; an allow
    // rule skips the prompt entirely.
    let ruleOutcome = permissionRuleSet.outcome(tool: name, arguments: arguments, root: root)
    if ruleOutcome == .deny {
      let denial = "denied by a permission rule (deny list in \(PermissionRules.defaultURL.lastPathComponent))"
      return GateOutcome(denial: denial, decision: row(.deny, .rule, "deny rule"))
    }

    // Plan mode is read-only: nothing gated executes, so the model plans and reports.
    if permissionMode == .plan, level != .readOnly {
      let denial = "plan mode is on — \(name) would change state, so it is denied. Describe what "
        + "you would do; the user will switch out of plan mode to run it."
      return GateOutcome(denial: denial, decision: row(.deny, .mode, "plan mode"))
    }

    // What the deterministic layer says before anyone is asked. `.sensitive` is never
    // auto-approved — not by a mode, a hook, or a standing grant — with one carved-out
    // exception: a *plain out-of-tree read* (a `PathGatedReadTool` call gated only by
    // location, never a credential or `paths.denyRead` path — the classifier decides, so no
    // grant glob can reach past it). There a scoped `Read(<dir>/**)` grant the user made, or
    // an auto-approving mode (`acceptEdits`/`bypass`), skips the prompt: reading a sibling
    // checkout is the mildest thing in the `.sensitive` bucket, and the actions its contents
    // could ask for stay gated (the taint escalation covers the network, the write side is
    // untouched). A tainted call keeps the loud prompt whatever a grant or mode says.
    /// The plain-out-of-tree-read path of this call, when it is one (resolved, physical).
    let outsideReadPath = (tool as? PathGatedReadTool)?.outsideReadPath(arguments: arguments)
    var approval: ToolDecision.Source?
    if ruleOutcome == .allow {
      approval = .rule
    } else if level == .mutating {
      if hookDecision == .allow {
        approval = .hook
      } else if grants.allows(tool: name, arguments: arguments, root: root) {
        approval = .grant
      } else if permissionMode == .bypass {
        approval = .mode
      } else if permissionMode == .acceptEdits, name == "write_file" || name == "edit_file" {
        approval = .mode
      }
    } else if level == .sensitive, !taintedCall, outsideReadPath != nil {
      // Never a hook's `allow` here: a hook approves ordinary mutations only (H2), and this
      // stays true for reads — grants and modes are the user's own standing answers.
      if grants.allows(tool: name, arguments: arguments, root: root) {
        approval = .grant
      } else if permissionMode == .bypass || permissionMode == .acceptEdits {
        approval = .mode
      }
    }
    // An `ask` rule (or hook) outranks every approval above: the human is asked anyway.
    let askForced = ruleOutcome == .ask || hookAsks
    let preApproved = approval != nil && !askForced
    // An approved call skips the delegate entirely, unless the delegate asked to see approved
    // calls: `JudgingPermissions` (so the safety judge still assesses a command an allow rule or
    // a grant would run silently) and `DenyMutationsPermissions` (a read-only posture outranks
    // every approval).
    if preApproved, !permissions.wantsPreApprovedCalls {
      return GateOutcome(decision: row(.allow, approval ?? .rule))
    }

    // A human is about to be asked: the PermissionRequest hooks get the question first. A
    // deny is always honored; an allow answers it for an ordinary mutation only — never
    // `.sensitive` (the same narrowing as a PreToolUse allow, and the deny rule, plan mode
    // and the floor were settled above). Anything else leaves the prompt to the delegate.
    var notices: [HookNotice] = []
    /// A PermissionRequest hook answered "allow": the human isn't asked, but — like an allow
    /// rule or a grant — the safety judge still sees the call when the delegate wants to.
    var answeredByHook = false
    if !preApproved, let engine = hooks {
      let request = await engine.permissionRequest(
        tool: name, argumentsJSON: argumentsJSON, tier: tier.rawValue, toolUseId: callId,
        turnIndex: turnIndex)
      notices = request.notices(for: .permissionRequest)
      if let reason = request.blockReason {
        return GateOutcome(
          denial: "blocked by hook: \(reason)", decision: row(.deny, .hook, reason), notices: notices)
      }
      if request.decision == .allow, level == .mutating {
        guard permissions.wantsPreApprovedCalls else {
          return GateOutcome(decision: row(.allow, .hook, "PermissionRequest hook"), notices: notices)
        }
        answeredByHook = true
      }
    }
    let informing = preApproved || answeredByHook

    var summary = taintPrefix + tool.summary(arguments: arguments)
    if case .ask(let reason?) = hookDecision, !reason.isEmpty {
      summary += " — hook: \(reason)"
    }
    let decision = await permissions.decide(PermissionRequest(
      toolName: name,
      summary: summary,
      argumentsJSON: argumentsJSON,
      tier: level,
      preApproved: informing,
      tainted: taintedCall,
      // What "always" would remember for a plain out-of-tree read — shown by the prompt so
      // the user knows what `a` covers; nil for a tainted call, whose approval is never
      // remembered.
      grantScope: taintedCall
        ? nil
        : outsideReadPath.flatMap { PathScope.readGrantDirectory(forResolvedPath: $0) }))
    switch decision {
    case .allow:
      let source: ToolDecision.Source = answeredByHook ? .hook : (approval ?? .rule)
      return GateOutcome(
        decision: row(.allow, informing ? source : permissions.decisionSource,
                      answeredByHook ? "PermissionRequest hook" : taintNote),
        notices: notices)
    case .allowAlwaysThisSession:
      // "always" is remembered as a *pattern*, not as a tool name: answered on
      // `git commit -m x` it grants `Bash(git commit *)`, never every future shell command.
      // A prompt an `ask` rule (or hook) demanded never becomes a standing grant, and neither
      // does a call the taint escalated: the `curl` a flagged file asked for is approved once,
      // not for the session (and never persisted by `/permissions save`).
      if !askForced, !taintedCall { addGrants(tool: name, level: level, arguments: arguments) }
      return GateOutcome(
        decision: row(.allow, permissions.decisionSource, "always this session"), notices: notices)
    case .deny(let reason):
      let denial = "user denied permission to run \(name)\(reason.map { ": \($0)" } ?? "")"
      // Only a delegate that asked to see approved calls refuses one the deterministic layer
      // had already approved — the escalating `bashJudge`, or a read-only posture that outranks
      // every approval — and it says which it is.
      let source: ToolDecision.Source = informing ? permissions.preApprovedDenialSource : permissions.decisionSource
      return GateOutcome(denial: denial, decision: row(.deny, source, reason), notices: notices)
    }
  }

  /// Turns an approved call into standing session grants, in the rules-file spelling.
  ///
  /// `bash` grants one pattern per segment worth one (`ShellCommand.sessionGrantPatterns`
  /// decides: never a destructive segment, an interpreter, or a command with substitution
  /// in it). The filter is per *segment*, not per call, which is why a `.sensitive` command
  /// still grants something: "always" on `npm test && git push` grants `Bash(npm test *)`
  /// and never the push — and since an allow pattern must match every segment, the same
  /// mixed command prompts again next time.
  ///
  /// A *plain out-of-tree read* (a `PathGatedReadTool` call gated only by location) grants
  /// the enclosing directory — the repo root when there is one — as `Read(<dir>)` +
  /// `Read(<dir>/**)`, so one `a` covers the rest of that tree for the session instead of a
  /// prompt per file. A credential or `paths.denyRead` path yields nothing (approve-once, as
  /// ever — and even a broad grant pattern could never cover one: the approval branch runs
  /// the classifier first), and so does a path directly under the home directory (too broad
  /// to remember).
  ///
  /// Every other tool grants its bare name, and only for an ordinary mutation — "always" on
  /// a `.sensitive` write covers that call alone, as it always has.
  private func addGrants(tool name: String, level: ToolPermission, arguments: [String: JSONValue]) {
    if name == "bash" {
      let command = arguments["command"]?.stringValue ?? ""
      for pattern in ShellCommand.sessionGrantPatterns(
        for: command, root: configuration.workingDirectory)
      {
        grants.insert(pattern)
      }
      return
    }
    if level == .mutating {
      grants.insert(name)
      return
    }
    guard level == .sensitive,
          let resolved = (tools.first(where: { $0.name == name }) as? PathGatedReadTool)?
            .outsideReadPath(arguments: arguments),
          let directory = PathScope.readGrantDirectory(forResolvedPath: resolved)
    else { return }
    // Both spellings: `<dir>/**` covers everything under it, the bare `<dir>` covers a
    // grep/glob whose path argument *is* the directory.
    grants.insert("Read(\(directory))")
    grants.insert("Read(\(directory)/**)")
  }

  /// The audit row for a refusal the loop itself made — a PreToolUse hook block, or an
  /// execute-time floor — where no permission gate produced one. The tier is re-derived
  /// from the (possibly hook-rewritten) arguments, so the row describes the call that was
  /// actually attempted.
  private func decisionRow(
    name: String,
    argumentsJSON: String,
    _ outcome: ToolDecision.Outcome,
    source: ToolDecision.Source,
    reason: String?)
    -> ToolDecision
  {
    let level = tools.first(where: { $0.name == name })?
      .permission(for: Self.decodeArguments(argumentsJSON)) ?? .mutating
    return ToolDecision(
      tool: name, tier: ToolDecision.Tier(level), decision: outcome, source: source, reason: reason)
  }

  /// The standing grants this session has accumulated, in the rules-file spelling —
  /// what `/permissions show` lists and `/permissions save` appends to `rules.json`.
  public var sessionGrants: [String] { grants.patterns }

  /// Switch the permission mode mid-session (`/permissions <mode>`).
  public func setPermissionMode(_ mode: PermissionMode) {
    permissionMode = mode
  }

  // MARK: Dials and introspection

  /// The reasoning-effort dial in force: the configuration's until `setReasoningEffort` moved it.
  public var currentReasoningEffort: Reasoning.Effort? { reasoningEffortOverride }

  /// Moves the reasoning-effort dial mid-session (`/effort <level>`; nil = off, so requests go
  /// out exactly as they would with no dial at all). The next request is the first to carry it.
  /// Persisted as an `effort_change` transcript entry when the session is stored — `off` too,
  /// written as the level `off` — so a resume restores the dial as it was left, not as the flag
  /// that started the earlier run had it. (`setPermissionMode` persists nothing: a mode is the
  /// run's posture, chosen per launch; the dial is a conversation setting.)
  ///
  /// The parameter is optional, so a literal `.none` here is `Optional.none` — **off** — not the
  /// `none` level (`--effort none`, which asks the model for no reasoning explicitly): spell
  /// that one `Reasoning.Effort.none`. A task tool whose `parentEffort` the CLI bound reads
  /// `currentReasoningEffort` at spawn time, so subagents spawned afterwards run with the new
  /// dial; an unbound one derives theirs from the configuration (`forSubagent`), the launch dial.
  public func setReasoningEffort(_ effort: Reasoning.Effort?) {
    reasoningEffortOverride = effort
    persist(.effortChange(effort))
  }

  /// The cost ceiling in force (`Configuration.maxCostUSD` until `setBudget` moved it), in
  /// session-cumulative dollars like `costUSD` — the number a `.budgetReached` stop reports.
  public var currentBudgetUSD: Double? { budgetUSD }

  /// Moves the cost ceiling mid-session (`/budget <usd>`; nil lifts it). Session-cumulative:
  /// a ceiling at or below what is already spent stops the next turn at its first step, so the
  /// REPL adds the new allowance to `costUSD` before calling this. Not persisted — a budget is
  /// the run's, like a permission mode; a resume passes its own `--budget`.
  public func setBudget(_ usd: Double?) {
    budgetUSD = usd
  }

  /// The structured-output schema in force: the configuration's `outputSchema` until
  /// `setOutputSchema` replaced it; nil = a finished turn makes no structured side request.
  public var currentOutputSchema: OutputSchema? { outputSchemaOverride }

  /// Sets (or, with nil, clears) the schema a finished turn's answer is asked for as one JSON
  /// object — the REPL's `/schema <file|json>` / `/schema off`. Takes effect from the next
  /// turn; a turn in flight keeps the schema it started with. Not persisted — like the budget,
  /// a schema is the run's; a resume passes its own `--output-schema`. Nothing in the loop's
  /// own requests changes (the side request is separate), so the cache prefix holds.
  public func setOutputSchema(_ schema: OutputSchema?) {
    outputSchemaOverride = schema
  }

  /// Replaces the embedder's system-prompt sections (`Configuration.extraSystemSections` seeds
  /// them) for every request from here on — how the REPL re-renders the `# Environment` block
  /// after `/model`, `/permissions` or `/effort` changed the facts it states, and how a resumed
  /// session sheds the block of the run that wrote its transcript. Same order, same place in the
  /// prompt as the configuration's.
  public func setExtraSystemSections(_ sections: [String]) {
    extraSystemSections = sections
  }

  /// The extra sections in force (`setExtraSystemSections`, else the configuration's).
  public var currentExtraSystemSections: [String] { extraSystemSections }

  /// The wire dialect the most recent turn actually executed (`RunRecord.dialect`: `chat`,
  /// `messages` or `responses` — what `.auto` resolved to, or what a fallback landed on), nil
  /// before the first turn.
  public var lastDialectUsed: String? { lastRecord?.dialect }

  /// The checklist the model posted last with `update_plan` — the arguments of the most recent
  /// such call in `history`, so it survives a resume, is per session (a subagent's plan lives
  /// in its own history) and goes with the history on `/clear`, a rewind or a compaction that
  /// summarized it away. nil when no usable plan is in the conversation.
  public var lastPlanSteps: [(text: String, status: String)]? {
    for message in history.reversed() where message.role == .assistant {
      for call in (message.toolCalls ?? []).reversed() where call.function?.name == PlanTool.toolName {
        let steps = PlanTool.planSteps(fromArgumentsJSON: call.function?.arguments ?? "")
        if !steps.isEmpty { return steps }
      }
    }
    return nil
  }

  /// What the next request would spend the context window on, by contributor: every system
  /// prompt section (`contextSections`), the history by role, and the tool definitions — each
  /// in bytes and estimated tokens, the estimates scaled to the last request's real prompt
  /// tokens when one has been reported (`lastPromptTokens`), else bytes/4. Resolving the
  /// model's family and context window consults the catalog (one manifest fetch per process).
  public func contextReport() async throws -> ContextReport {
    let profile = try await catalog.profile(for: model)
    return ContextReport.build(
      promptSections: contextSections(pack: PromptPack.load(for: profile.family), profile: profile),
      history: requestHistory(),
      tools: toolDefinitions,
      lastPromptTokens: lastPromptTokens,
      contextLength: profile.contextLength,
      compactionThreshold: compactionThreshold)
  }

  /// A side question over the conversation (`/btw`): one non-streaming chat request carrying
  /// the system prompt, the history as the next step would replay it and `text` as the final
  /// user message — **nothing is appended to history**, so the model's next step never sees the
  /// question or the answer, and a resumed session doesn't either. The spend is booked on the
  /// session (and its `cost` line persisted) but on no turn's record. Like the structured-output
  /// side request, the tool definitions ride along with `tool_choice: none` whenever the history
  /// carries a tool call (Anthropic refuses `tool_use` blocks in a request that defines no
  /// tools). Refused while a turn is in flight.
  public func aside(_ text: String) async throws -> (text: String, costUSD: Double) {
    guard turnTask == nil else { throw SessionError.turnInFlight }
    let profile = try await catalog.profile(for: model)
    let pack = PromptPack.load(for: profile.family)
    let messages = [Message.system(systemText(pack: pack, profile: profile))] + chatReplayHistory + [.user(text)]
    let historyCallsTools = messages.contains { !($0.toolCalls ?? []).isEmpty }
    let definitions = requestTools(for: profile)?.map(\.toolDefinition) ?? []
    let sideTools: [Tool]? = historyCallsTools && !definitions.isEmpty ? definitions : nil
    let response = try await service.chatCompletion(
      ChatCompletionRequest(
        model: model,
        messages: messages,
        tools: sideTools,
        // `ToolChoice.none` spelled out: a bare `.none` here is `Optional.none`, i.e. no field.
        toolChoice: sideTools == nil ? nil : ToolChoice.none))
    let reply = response.choices.first?.message.content ?? ""
    let spent = await cost(of: response.usage, model: model) ?? 0
    costUSD += spent
    persist(.cost(turnUSD: spent, sessionUSD: costUSD))
    return (reply, spent)
  }

  /// Runs one tool call. `nonisolated` so a step's concurrent calls actually overlap rather
  /// than queueing on the session's executor — it reads only the immutable `tools`.
  /// `preflightError` has already answered unknown tools and bad arguments; the guards here
  /// are the fallback for a call that reaches this without it.
  private nonisolated func execute(name: String, argumentsJSON: String) async -> String {
    guard let tool = tools.first(where: { $0.name == name }) else {
      return Self.unknownToolError(name, available: tools.map(\.name))
    }
    do {
      // The turn's stream is this execution's `ToolEventSink` — scoped to the call (and any
      // child task it spawns), which is what lets a tool instance shared with a nested session
      // emit into whichever session is running it (`PlanTool`'s `.planUpdated`).
      return try await ToolEventSink.$current.withValue(turnSink.current) {
        try await tool.execute(arguments: Self.decodeArguments(argumentsJSON))
      }
    } catch {
      return "error: \(error)"
    }
  }

  /// What the model reads for a call that can't run as sent — an unknown tool, arguments that
  /// aren't a JSON object, a required key missing — decided **after the PreToolUse hooks**
  /// (an `updatedInput` may have fixed the arguments) and **before the permission gate** (nobody
  /// is asked about, and no audit row written for, a call that will not run). nil when the
  /// call is well-formed. These are results, not refusals: they reset the denial streak, count
  /// as errors for the loop guard and the tool stats, and run the PostToolUseFailure hooks
  /// like any other `error:` result — the tool itself is never invoked.
  ///
  /// The unknown-tool branch also answers a tool this session has but the current model was not
  /// offered (`availableToolNames`, the per-model gate's last answer — T5): a `view_image` a
  /// text-only model hallucinated or remembered from before a `/model` swap must not run, since
  /// its image would ride the next request and fail it whole. Isolated (it reads that cache);
  /// its one caller is the step loop, on the actor.
  private func preflightError(name: String, argumentsJSON: String) -> String? {
    guard let tool = tools.first(where: { $0.name == name }) else {
      return Self.unknownToolError(name, available: tools.map(\.name))
    }
    if let available = availableToolNames, !available.contains(name) {
      return Self.unavailableToolError(name, available: tools.map(\.name).filter(available.contains))
    }
    let required = Self.requiredKeys(of: tool.parameters)
    guard let arguments = Self.decodeArgumentObject(argumentsJSON) else {
      let shown = argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
      let example = required.isEmpty
        ? "a JSON object"
        : "exactly {" + required.map { "\"\($0)\": …" }.joined(separator: ", ") + "}"
      return "error: arguments for \(name) were not a valid JSON object (\(String(shown.prefix(80)))). "
        + "Send \(example) per the tool schema."
    }
    // A required key that is absent, or sent as `null` where the schema doesn't allow null
    // (an MCP property typed `["string", "null"]` may legitimately be null).
    let missing = required.filter { key in
      switch arguments[key] {
      case nil: return true
      case .null?: return !Self.allowsNull(parameters: tool.parameters, key: key)
      default: return false
      }
    }
    guard !missing.isEmpty else { return nil }
    let named = missing.map { key in
      if case .null? = arguments[key] { return "\(key) (sent as null)" }
      return key
    }
    let got = arguments.keys.sorted().joined(separator: ", ")
    return "error: \(name) needs \(named.joined(separator: ", ")). Got: \(got.isEmpty ? "no arguments" : got)."
  }

  static func unknownToolError(_ name: String, available: [String]) -> String {
    "error: unknown tool \(name). Available: \(available.joined(separator: ", "))"
  }

  /// A tool the session has but the current model was not offered (`CapabilityGatedTool`).
  static func unavailableToolError(_ name: String, available: [String]) -> String {
    "error: \(name) is not available for the current model. Available: \(available.joined(separator: ", "))"
  }

  /// The `required` list of a tool's JSON Schema, when it names one.
  static func requiredKeys(of parameters: JSONValue) -> [String] {
    guard case .array(let items)? = parameters["required"] else { return [] }
    return items.compactMap(\.stringValue)
  }

  /// Whether the schema lets `key` be `null`: a `type` of `"null"` or a list containing it, or
  /// OpenAPI's `nullable: true`. Anything else (no property, no type) does not.
  static func allowsNull(parameters: JSONValue, key: String) -> Bool {
    guard let property = parameters["properties"]?[key] else { return false }
    if property["nullable"]?.boolValue == true { return true }
    switch property["type"] {
    case .string(let type)?: return type == "null"
    case .array(let types)?: return types.contains { $0.stringValue == "null" }
    default: return false
    }
  }

  /// Whether this tool opted into running alongside the step's other calls (`ConcurrentTool`
  /// — the task tool). Unknown names are sequential: the conservative answer.
  private nonisolated func isConcurrent(_ name: String) -> Bool {
    tools.first(where: { $0.name == name }) is any ConcurrentTool
  }

  /// The prefix every failed tool result carries — a tool's own `error:` reply, or the
  /// loop's wrapping of a thrown error (`execute`). What tells `PostToolUseFailure` apart
  /// from `PostToolUse`.
  static let toolErrorPrefix = "error:"

  /// Everything that happens to a tool's output between execution and history: subagent
  /// spend is drained (returned, for the turn's books), the PostToolUse hooks — or, for an
  /// `error:` result, the PostToolUseFailure hooks; never both — append their output so the
  /// model sees a formatter's or test's reaction, and then the **universal output cap**
  /// (`ToolOutputLimiter`) trims what the model reads to head + tail, spilling the whole thing
  /// to `spillDirectory` when one is configured — last, so a chatty hook is capped too, and
  /// once, for every tool alike. A refusal never gets here (`commitReady` commits it without
  /// hooks), so a call that didn't run is never reported as a failure. The one seam later work
  /// extends — post-edit windows, checkpoints — instead of the loop body.
  ///
  /// The untrusted-content guard (`ToolResultGuardPolicy`) lives here too, in a fixed order:
  /// **redact** (`SecretScrubber`, before the cap so the spill file never holds the secret) →
  /// **cap/spill** → **scan** (`OutputScanner`, on the capped text — what the model will read;
  /// a flag prefixes its notice line and escapes the structural tokens). The frame is added by
  /// the caller, on what enters history only. `redactions` and `flagged` report what happened.
  private func afterToolExecuted(
    name: String,
    argumentsJSON: String,
    callId: String,
    turnIndex: Int?,
    output: inout String,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
    async -> (accruedCost: Double, hookCost: Double, stop: String??, truncated: Bool, redactions: Int, flagged: [String])
  {
    // Subagent spend (task tool) belongs to this turn: the caller adds it to the record so
    // `/cost` and the scoreboard see the true total.
    var accrued = 0.0
    if let costly = tools.first(where: { $0.name == name }) as? CostReportingTool {
      accrued = costly.drainAccruedCost()
    }
    var stop: String?? = nil
    // An execute-time floor refusal (`error: refused — …`) is a refusal like any gate's:
    // nothing ran, so neither the success nor the failure hooks have anything to react to.
    if let engine = hooks, !output.hasPrefix(ToolDecision.floorRefusalPrefix) {
      let failed = output.hasPrefix(Self.toolErrorPrefix)
      let event: HookEvent = failed ? .postToolUseFailure : .postToolUse
      let post = failed
        ? await engine.postToolUseFailure(
          tool: name, argumentsJSON: argumentsJSON, error: output, toolUseId: callId, turnIndex: turnIndex)
        : await engine.postToolUse(
          tool: name, argumentsJSON: argumentsJSON, result: output, toolUseId: callId, turnIndex: turnIndex)
      for notice in post.notices(for: event) {
        continuation.yield(.hookNotice(event: notice.event, output: notice.output))
      }
      var feedback = post.feedback
      if !post.additionalContext.isEmpty {
        feedback += (feedback.isEmpty ? "" : "\n") + post.additionalContext.joined(separator: "\n")
      }
      if !feedback.isEmpty {
        output += "\n\n[hook]\n" + feedback
      }
      if !post.continueRun { stop = .some(post.stopReason) }
      // A PostToolUse formatter may have rewritten the file the tool just touched; re-record
      // its version so the model's next edit to its own change isn't refused as stale. Only
      // after a call that *ran*: a failed one (a validation error, the tool's own unread/stale
      // refusal) touched nothing, and recording it would mark a file the model never read as seen.
      if !failed,
         let tracking = tools.first(where: { $0.name == name }) as? FileVersionTracking,
         let path = Self.decodeArguments(argumentsJSON)["path"]?.stringValue
      {
        await tracking.recordCurrentVersion(ofPath: path)
      }
    }
    // What the hooks themselves spent — a prompt hook's request, the command judge's (they
    // share the CLI's runner), a paying handler's — joins the subagent spend so it reaches the
    // record through the same tuple. Drained after the post hooks, so this call's own
    // PostToolUse prompt hook is booked now rather than on the next call. With no engine at
    // all (no hooks, no handlers) the runner is still the judge's ledger, so it is drained
    // directly.
    let hookCost = await drainHookSpend()
    // Redaction first — before the cap writes the spill file, before anything of the result is
    // stored or shown. The hooks above saw the raw output: they are the user's own scripts, run
    // in the user's environment, and a formatter's feedback is redacted with the rest here.
    let guarded = guardResult(output, tool: name, callId: callId)
    output = guarded.text
    // Something was written under this session's spill directory: open it for reads now — the
    // pointer the model just got names a path it must be able to `read_file` — and not before,
    // so an empty carve-out is never open.
    if guarded.spilled { openSpillDirectory() }
    return (accrued + hookCost, hookCost, stop, guarded.truncated, guarded.redactions, guarded.flagged)
  }

  /// What the guard did to one result on its way to history.
  struct GuardedResult {
    var text: String
    var truncated: Bool
    var spilled: Bool
    var redactions: Int
    var flagged: [String]
  }

  /// The guard's fixed order over one result: redact → cap/spill → scan. Shared by the tool
  /// path (`afterToolExecuted`) and the background delivery (`deliver`), so a subagent's report
  /// is treated exactly like a tool's own output. The frame is the caller's (`framed`).
  private func guardResult(_ text: String, tool: String, callId: String) -> GuardedResult {
    let policy = configuration.toolResultGuard
    var output = text
    var redactions = 0
    if policy.redaction {
      let scrubbed = SecretScrubber.scrub(output)
      output = scrubbed.text
      redactions = scrubbed.redactions.count
    }
    // The cap: what the model reads is bounded whatever the tool and the hooks produced; the
    // spill file holds the redacted text.
    let capped = outputLimiter.cap(output, tool: tool, callId: callId)
    if capped.truncated { output = capped.text }
    var flagged: [String] = []
    if policy.scanner {
      let scan = OutputScanner.scan(output)
      if !scan.patterns.isEmpty {
        output = scan.text
        flagged = scan.patterns
      }
    }
    return GuardedResult(
      text: output, truncated: capped.truncated, spilled: capped.spillURL != nil,
      redactions: redactions, flagged: flagged)
  }

  /// The result as it enters history: wrapped in the session's frame when the policy frames,
  /// else exactly the text — the request shape without framing is byte-identical to before.
  private func framed(_ text: String, source: String) -> String {
    configuration.toolResultGuard.framing ? ToolResultFrame.wrap(text, source: source, nonce: resultNonce) : text
  }

  /// Records untrusted content: the first source sticks, later ones change nothing — the
  /// taint is a session-scoped bit, not a log.
  private func markTainted(source: String, reason: String) {
    guard taint == nil else { return }
    taint = Taint(source: source, reason: reason)
  }

  /// The session's output cap: `configuration.toolResultMaxChars`, spilling under this
  /// session's own directory when a spill scope is configured.
  private var outputLimiter: ToolOutputLimiter {
    ToolOutputLimiter(maxChars: configuration.toolResultMaxChars, spillDirectory: spillDirectory)
  }

  /// `<scope.root>/<session id>` — where this session's capped results are written in full;
  /// nil when no spill scope is configured. Created on the first spill, removed by `end`.
  private nonisolated var spillDirectory: URL? {
    configuration.spillScope?.root.appendingPathComponent(id)
  }

  /// Opens this session's spill directory — and only it — for reads through the shared
  /// `SpillScope` the toolset's path rules consult. Idempotent.
  private func openSpillDirectory() {
    guard let scope = configuration.spillScope, let spillDirectory else { return }
    scope.open(spillDirectory)
  }

  /// When the session ends: the carve-out closes (a kept file is for the user to read, not for
  /// the next session's model) and the directory goes — unless the user asked to keep the files
  /// (`ARNES_KEEP_TMP=1`). A directory that was never created is a no-op.
  private func releaseSpillDirectory() {
    guard let scope = configuration.spillScope, let spillDirectory else { return }
    scope.close(spillDirectory)
    if !scope.keepsFiles {
      try? FileManager.default.removeItem(at: spillDirectory)
    }
  }

  /// What the hooks (and the command judge, which shares the CLI's runner) have spent since
  /// the last drain. Called per executed call and once more when a turn's record is finalized,
  /// so spend on a denied call or a Stop hook lands on the turn that caused it.
  private func drainHookSpend() async -> Double {
    if let engine = hooks {
      return await engine.drainAccruedCostUSD()
    } else if let runner = configuration.hookPromptRunner {
      return await runner.drainAccruedCostUSD()
    }
    return 0
  }

  /// Points every `EventEmittingTool` at this turn's stream (nil after the turn, so a
  /// finished continuation isn't kept alive by a tool), and parks the same sink in `turnSink`
  /// for the per-execution `ToolEventSink` the tool path hands every tool it runs.
  private func bindEventEmitters(_ sink: (@Sendable (AgentEvent) -> Void)?) {
    turnSink.current = sink
    for case let emitter as any EventEmittingTool in tools {
      emitter.onEvent = sink
    }
  }

  /// Delivers queued notices — and the loop guard's nudge, when the turn has one waiting — as
  /// one `[arnes]` user message before the next request. The nudge is the turn's, passed in
  /// from `runTurn`'s locals, so it never outlives the turn the way a session notice does.
  private func drainPendingNotices(turnNudge: inout String?) {
    var lines = pendingNotices
    if let nudge = turnNudge {
      lines.append(nudge)
      turnNudge = nil
    }
    guard !lines.isEmpty else { return }
    pendingNotices.removeAll()
    appendToHistory(.user("[arnes] " + lines.joined(separator: "\n")))
  }

  // MARK: Background subagents

  /// The tools that run work detached (`BackgroundWorkSource` — the task tool), discovered by
  /// protocol the way the cost reporters are, never by type name.
  private var backgroundSources: [any BackgroundWorkSource] {
    tools.compactMap { $0 as? any BackgroundWorkSource }
  }

  /// Background runs in flight or finished-but-undelivered, across every source.
  private var pendingBackgroundCount: Int {
    backgroundSources.reduce(0) { $0 + $1.pendingBackgroundCount() }
  }

  /// The number of background subagents still running or waiting to be delivered — what
  /// `/tasks` reports and what a `compact` refuses on.
  public var backgroundWorkPending: Int { pendingBackgroundCount }

  /// Step-boundary delivery: every finished background outcome, oldest first, enters history
  /// and its spend the turn's books. Nothing happens for a toolset without a source.
  private func deliverFinishedBackground(
    record: inout RunRecord,
    turnCost: inout Double,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
  {
    for source in backgroundSources {
      for outcome in source.drainFinishedBackground() {
        deliver(outcome, via: source, record: &record, turnCost: &turnCost, continuation: continuation)
      }
    }
  }

  /// Waits for the next background outcome from the first source that has work pending.
  /// nil when nothing is pending or this task was cancelled while waiting.
  private func awaitAnyBackground() async -> (outcome: BackgroundOutcome, source: any BackgroundWorkSource)? {
    for source in backgroundSources where source.pendingBackgroundCount() > 0 {
      if let outcome = await source.awaitAnyBackground() {
        return (outcome, source)
      }
      if Task.isCancelled { return nil }
    }
    return nil
  }

  /// Cancels every source's background work and returns the spend this drained into the
  /// cost reporters — the stranded-cost path a cancelled foreground delegation takes.
  private func cancelBackgroundWork() async -> Double {
    guard pendingBackgroundCount > 0 else { return 0 }
    for source in backgroundSources {
      await source.cancelBackground()
    }
    return tools
      .compactMap { $0 as? CostReportingTool }
      .reduce(0.0) { $0 + $1.drainAccruedCost() }
  }

  /// How a background report enters history: as a tool exchange, never a user message. The
  /// call that started the run was answered `started background subagent …` when it was made,
  /// so the report rides a synthetic follow-up pair — an assistant message carrying one `task`
  /// call (`id: bg-<run id>`, the agent named, the task `(background result)`) and its `.tool`
  /// result holding the report under a `[background subagent … finished]` header. Both go
  /// through `appendToHistory`, so they persist and translate to `/messages` and `/responses`
  /// like any other pair. The user role stays the principal's channel: a report may quote a
  /// file that quotes instructions, and the model should read it as a tool result.
  ///
  /// The spend lands here, once — a background run never accrues into `drainAccruedCost`.
  ///
  /// - Parameter leadText: the reply the model gave as it finished (the turn-end join) — carried
  ///   as the synthetic message's content so the history never holds two assistant messages in a
  ///   row, a shape some chat templates reject.
  private func deliver(
    _ outcome: BackgroundOutcome,
    via source: any BackgroundWorkSource,
    leadText: String? = nil,
    record: inout RunRecord,
    turnCost: inout Double,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation)
  {
    let callId = Self.backgroundCallIdPrefix + outcome.id
    let content: Message.Content? = leadText.flatMap { $0.isEmpty ? nil : Message.Content.text($0) }
    appendToHistory(Message(
      role: .assistant,
      content: content,
      toolCalls: [ToolCall(
        id: callId,
        function: .init(
          name: source.name,
          arguments: Self.backgroundCallArguments(agent: outcome.agent)))]))
    var header = "[background subagent '\(outcome.agent)' (\(outcome.id)) finished"
    if outcome.partial { header += " (partial)" }
    header += "]"
    // A delivered report is a tool result like any other: redacted, capped (and spilled) by the
    // same limiter — so a background explorer's 200 K-char dump can't flood the context the way
    // a foreground one can't — scanned, and framed as a subagent's. A flagged report taints the
    // session and is reported on the task tool, whose channel it arrives through.
    let guarded = guardResult(outcome.report, tool: source.name, callId: callId)
    if guarded.truncated {
      record.truncatedResults = (record.truncatedResults ?? 0) + 1
      if guarded.spilled { openSpillDirectory() }
    }
    if guarded.redactions > 0 {
      record.redactions = (record.redactions ?? 0) + guarded.redactions
    }
    if !guarded.flagged.isEmpty {
      record.flagged = (record.flagged ?? 0) + 1
      markTainted(source: source.name, reason: "flagged: " + guarded.flagged.joined(separator: ", "))
      continuation.yield(.contentFlagged(tool: source.name, patterns: guarded.flagged))
    }
    appendToHistory(.tool(
      framed(header + "\n\n" + guarded.text, source: ToolResultFrame.subagentSource), toolCallId: callId))
    if outcome.costUSD > 0 {
      record.costUSD += outcome.costUSD
      turnCost += outcome.costUSD
      costUSD += outcome.costUSD
    }
    continuation.yield(.subagentFinished(
      name: outcome.agent,
      id: outcome.id,
      steps: outcome.steps,
      toolCalls: outcome.toolCalls,
      costUSD: outcome.costUSD,
      resultPreview: String(outcome.report.prefix(120))))
  }

  /// The tool-call id a delivered background report answers: `bg-` + the run id.
  static let backgroundCallIdPrefix = "bg-"

  /// The synthetic call's arguments, keys sorted so the history is byte-stable.
  static func backgroundCallArguments(agent: String) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(["agent": agent, "task": "(background result)"])) ?? Data()
    return String(decoding: data, as: UTF8.self)
  }

  /// The arguments as a JSON object, or nil when the text isn't one. An empty or blank string
  /// reads as `{}` — what several models send for a tool that takes no arguments.
  static func decodeArgumentObject(_ json: String) -> [String: JSONValue]? {
    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return [:] }
    return try? JSONDecoder().decode([String: JSONValue].self, from: Data(trimmed.utf8))
  }

  /// Lenient decode for the paths that only *read* arguments (the permission gate, the file
  /// version refresh): malformed text is an empty object there, because `preflightError` has
  /// already turned it into the model's error result.
  private static func decodeArguments(_ json: String) -> [String: JSONValue] {
    decodeArgumentObject(json) ?? [:]
  }

  private func appendToHistory(_ message: Message) {
    history.append(message)
    persist(TranscriptEntry(message: message, turn: currentTurnTag))
  }

  /// The turn a message written now belongs to: `turnIndex` already counts the turn in
  /// flight (and, between turns, the one just finished — the only writer then is a
  /// compaction re-appending that turn's tail). nil before the first turn.
  private var currentTurnTag: Int? { turnIndex > 0 ? turnIndex - 1 : nil }

  private func persist(_ entry: TranscriptEntry) {
    guard let sessionStore else { return }
    writeMetaIfNeeded()
    try? sessionStore.append(entry, to: id)
  }

  private func writeMetaIfNeeded() {
    guard let sessionStore, !metaWritten else { return }
    metaWritten = true
    // Lineage rides the first meta line: a nested session names the session that delegated
    // (`parent`), its agent and depth; any session names how it was started (`origin`). A lead
    // without an origin writes the line it always did.
    try? sessionStore.append(
      .meta(
        id: id, model: model,
        cwd: configuration.workingDirectory?.path ?? FileManager.default.currentDirectoryPath,
        parent: configuration.parentSessionId,
        agent: configuration.agent,
        depth: configuration.depth > 0 ? configuration.depth : nil,
        origin: configuration.sessionOrigin),
      to: id)
  }
}
