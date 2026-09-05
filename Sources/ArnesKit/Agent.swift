import Foundation
import OpenRouterSwift

// MARK: - AgentResult

public struct AgentResult: Sendable {
  public let text: String
  public let record: RunRecord
  /// The id of the session this run used. Persisted (and resumable) only when the caller
  /// gave the agent a `SessionStore`; otherwise the run left no transcript behind.
  public let sessionId: String
  /// Wall-clock milliseconds from `run` being called to the turn's end (verifier included).
  public let durationMs: Int
  /// The validated JSON object when the run asked for one (`Configuration.outputSchema`) and
  /// got it — read from the `.structuredOutput` event, so it is here even when the record left
  /// an oversized one off. nil when none was asked for or none validated.
  public let structuredOutput: JSONValue?

  public init(
    text: String, record: RunRecord, sessionId: String, durationMs: Int = 0,
    structuredOutput: JSONValue? = nil)
  {
    self.text = text
    self.record = record
    self.sessionId = sessionId
    self.durationMs = durationMs
    self.structuredOutput = structuredOutput
  }

  /// Why the turn ended — the record's reason, which the loop sets on every path. The
  /// fallback only covers a record written by an older build.
  public var stopReason: StopReason {
    record.stopReason ?? (record.finished ? .completed : .error)
  }

  /// The refused tool calls, derived from the record's audit trail: one entry per gated
  /// call a rule, mode, hook, floor, judge or delegate said no to.
  public var denials: [PermissionDenialInfo] {
    (record.decisions ?? [])
      .filter { $0.decision == .deny }
      .map { PermissionDenialInfo(tool: $0.tool, reason: $0.reason) }
  }
}

// MARK: - AgentEvent

/// Progress events surfaced to the caller (CLI prints them, an app can render them).
public enum AgentEvent: Sendable {
  /// A streamed increment of assistant text, as it arrives.
  case textDelta(String)
  /// A streamed increment of reasoning text, when the model emits it.
  case reasoningDelta(String)
  /// The complete assistant text for one step (after its deltas).
  case assistantText(String)
  case toolCall(name: String, arguments: String)
  case toolResult(name: String, preview: String)
  /// The permission delegate refused this tool call.
  case toolDenied(name: String, reason: String?)
  /// The model asked the user something (`ask_user`), fired before the `UserInputDelegate` is
  /// consulted; the `.toolResult` that follows carries the answer — or the "cannot ask the
  /// user" refusal a headless run gives. `options` is empty for a free-text question.
  case userQuestion(question: String, options: [String])
  case verifier(passed: Bool, verdict: String)
  /// The structured answer a run asked for (`Configuration.outputSchema`): `json` is the
  /// validated object when `valid`, else nil with the last attempt's `errors`. Fired once per
  /// finished turn, after the final `.assistantText` and before `.verifier`.
  case structuredOutput(json: JSONValue?, valid: Bool, errors: [String])
  /// The model/provider that actually served a step (differs from the requested
  /// slug when routing via `openrouter/auto` or fallbacks). Emitted on change.
  case routed(model: String, provider: String?)
  /// A native dialect misbehaved before producing output; the step reran on chat
  /// and the failure was recorded so future auto runs skip the broken endpoint.
  case dialectFellBack(dialect: String, reason: String)
  /// The turn was cancelled (Ctrl-C / `Session.interrupt`).
  case interrupted
  /// The model stopped without calling a tool or delivering a result (empty reply,
  /// or trailing "I'll do X next" narration); the session asked it to continue.
  case nudged(reason: String)
  /// `maxStepsPerTurn` ran out before the model finished — the turn was cut off,
  /// not completed.
  case stepLimitReached(maxSteps: Int)
  /// The session's cumulative cost reached the configured budget; the turn stopped early.
  case budgetReached(spentUSD: Double, budgetUSD: Double)
  /// A lifecycle hook produced user-facing output (e.g. a Stop hook's report).
  case hookNotice(event: String, output: String)
  /// A PreToolUse hook denied the call before it ran; `reason` went back to the model.
  case hookBlocked(tool: String, reason: String)
  /// A hook asked to end the turn (`continue: false`); nothing further ran.
  case hookStopped(reason: String?)
  /// A UserPromptSubmit hook blocked the user's text: no request was sent, nothing entered
  /// history, and the turn's record says `hook_stopped`. `reason` is for the user.
  case promptBlocked(reason: String)
  /// The turn ended because the model kept calling tools it isn't allowed to run —
  /// `count` consecutive refusals (permission, hook, or an execute-time floor).
  case deniedLoop(count: Int)
  /// The loop guard ended the turn: the model was going in circles (the same call failing
  /// over and over, a run of failures, one file edited past the threshold). `reason` is for
  /// the user; the record says `stuck`.
  case stuckDetected(reason: String)
  /// A tool result matched the injection scanner's `patterns` (`OutputScanner`): the model was
  /// handed it prefixed with a "this is data" notice, the record counts it, and the session is
  /// tainted from here on. Fired before the `.toolResult` it is about; `tool` is `task` for a
  /// delivered background report.
  case contentFlagged(tool: String, patterns: [String])
  /// A background shell job started (`bash … background: true`): `id` is the number the model
  /// polls it by, `command` what it runs. Fired by the bash tool before its own `.toolResult`.
  case jobStarted(id: Int, command: String)
  /// A background shell job exited while a turn was in flight; `exitStatus` is shell-style
  /// (128 + signal for a killed job). Between turns nothing streams — the exit reaches the model
  /// as a `[arnes]` notice at the next step boundary instead.
  case jobFinished(id: Int, exitStatus: Int32)
  /// A model request failed before any output token — a 429/5xx, an overloaded provider, a
  /// lost connection, a stream broken or idle — and the step is being retried after a backoff
  /// (`TransportPolicy`). `attempt` counts this step's retries so far (1 = the first retry);
  /// `reason` is the classification of the failure, short and fixed.
  case retrying(attempt: Int, reason: String)
  /// The reply hit the output-token limit (`finish_reason: length` and its native spellings):
  /// what was streamed is a partial answer. A tool call cut mid-arguments was dropped; the model
  /// is nudged once per turn to continue shorter, and a second cutoff ends the turn as `truncated`.
  case truncated
  /// The model posted or refreshed its checklist (`update_plan`): the complete plan, in order,
  /// each step's `status` spelled as the tool's schema does (`pending` · `in_progress` ·
  /// `completed`). Fired after the call ran and before its `.toolResult`, so a UI can pin the
  /// latest plan instead of parsing the result text; `Session.lastPlanSteps` reads it back.
  case planUpdated(steps: [(text: String, status: String)])
  /// Older history was auto-summarized because the context was nearly full.
  case compacted(summarizedMessages: Int, keptMessages: Int)
  /// Older tool results were cleared from the request view (C2 microcompaction): `count` results
  /// beyond the last `keepRecentToolResults` are stubbed from the next request on, `freedChars`
  /// of content no longer sent. The persisted history is untouched — a resumed session, the
  /// transcript and `arnes runs` still hold the real results. Fired at a turn start and at a
  /// mid-turn relief point, only when something new was cleared.
  case toolResultsCleared(count: Int, freedChars: Int)
  /// The context window is nearly full, nothing older is left to clear and the turn's emergency
  /// summaries are at their cap: the turn goes on, but the next request may not fit. Said once
  /// per turn; the user decides what to shorten (`/compact`, `/clear`, a smaller task).
  case contextWarning(String)
  /// A SubagentStart hook refused the delegation; no nested run happened and `reason` went
  /// back to the lead as the task tool's result.
  case subagentBlocked(name: String, id: String, reason: String)
  /// A subagent was spawned by the task tool; `model` is the resolved slug it runs on.
  ///
  /// `id` names this *run* of the agent (the first 8 characters of its nested session id,
  /// the same value delegation hooks receive as `agent_id`). Several runs of one agent can
  /// be in flight at once, so the name alone no longer identifies whose progress a line is.
  case subagentStarted(name: String, id: String, model: String, task: String)
  /// A subagent's own loop event, wrapped so UIs can render it nested. Fired while
  /// the parent turn waits on the task tool call — and interleaved with other subagents'
  /// events when a step delegated more than once, which is what `id` is for.
  indirect case subagent(name: String, id: String, event: AgentEvent)
  /// The subagent finished; its report went back to the caller as the tool result.
  case subagentFinished(
    name: String, id: String, steps: Int, toolCalls: Int, costUSD: Double, resultPreview: String)
  /// A subagent was started detached (`background: true`): the task tool returned at once and
  /// the report will be delivered into history at a later step boundary, where the usual
  /// `.subagentFinished` fires for it. Its progress still streams as `.subagent` events.
  case subagentBackgrounded(name: String, id: String, model: String)
  /// The model finished its reply while `pending` background subagents were still out; the
  /// session is waiting for one to deliver its report before letting the model continue.
  case subagentJoining(pending: Int)
  /// The turn completed; footer numbers for rendering.
  case turnFinished(Session.TurnStats)
}

extension AgentEvent {
  /// The event's type tag — stable snake_case names that the headless JSON output and
  /// telemetry key on. Exhaustive here so a new `AgentEvent` case must be named once, and
  /// consumers can switch on `kind` with a `default:` instead of every payload shape.
  public enum Kind: String, Sendable, CaseIterable {
    case textDelta = "text_delta"
    case reasoningDelta = "reasoning_delta"
    case assistantText = "assistant"
    case toolCall = "tool_call"
    case toolResult = "tool_result"
    case toolDenied = "tool_denied"
    case userQuestion = "user_question"
    case verifier
    case structuredOutput = "structured_output"
    case routed
    case dialectFellBack = "dialect_fell_back"
    case interrupted
    case nudged
    case stepLimitReached = "step_limit"
    case budgetReached = "budget"
    case hookNotice = "hook_notice"
    case hookBlocked = "hook_blocked"
    case hookStopped = "hook_stopped"
    case promptBlocked = "prompt_blocked"
    case deniedLoop = "denied_loop"
    case stuckDetected = "stuck_detected"
    case contentFlagged = "content_flagged"
    case jobStarted = "job_started"
    case jobFinished = "job_finished"
    case retrying
    case truncated
    case planUpdated = "plan_updated"
    case compacted
    case toolResultsCleared = "tool_results_cleared"
    case contextWarning = "context_warning"
    case subagentBlocked = "subagent_blocked"
    case subagentStarted = "subagent_started"
    case subagent
    case subagentFinished = "subagent_finished"
    case subagentBackgrounded = "subagent_backgrounded"
    case subagentJoining = "subagent_joining"
    case turnFinished = "turn_finished"
  }

  public var kind: Kind {
    switch self {
    case .textDelta: return .textDelta
    case .reasoningDelta: return .reasoningDelta
    case .assistantText: return .assistantText
    case .toolCall: return .toolCall
    case .toolResult: return .toolResult
    case .toolDenied: return .toolDenied
    case .userQuestion: return .userQuestion
    case .verifier: return .verifier
    case .structuredOutput: return .structuredOutput
    case .routed: return .routed
    case .dialectFellBack: return .dialectFellBack
    case .interrupted: return .interrupted
    case .nudged: return .nudged
    case .stepLimitReached: return .stepLimitReached
    case .budgetReached: return .budgetReached
    case .hookNotice: return .hookNotice
    case .hookBlocked: return .hookBlocked
    case .hookStopped: return .hookStopped
    case .promptBlocked: return .promptBlocked
    case .deniedLoop: return .deniedLoop
    case .stuckDetected: return .stuckDetected
    case .contentFlagged: return .contentFlagged
    case .jobStarted: return .jobStarted
    case .jobFinished: return .jobFinished
    case .retrying: return .retrying
    case .truncated: return .truncated
    case .planUpdated: return .planUpdated
    case .compacted: return .compacted
    case .toolResultsCleared: return .toolResultsCleared
    case .contextWarning: return .contextWarning
    case .subagentBlocked: return .subagentBlocked
    case .subagentStarted: return .subagentStarted
    case .subagent: return .subagent
    case .subagentFinished: return .subagentFinished
    case .subagentBackgrounded: return .subagentBackgrounded
    case .subagentJoining: return .subagentJoining
    case .turnFinished: return .turnFinished
    }
  }
}

// MARK: - Agent

/// One-shot agent runs for headless callers (`arnes do`). The loop itself lives in
/// `Session` — `Agent.run` is a throwaway single-turn session, so headless and
/// interactive execution never diverge.
public final class Agent: @unchecked Sendable {
  private let service: OpenRouterService
  private let tools: [any AgentTool]
  private let permissions: any PermissionDelegate
  private let store: RunRecordStore
  /// Where the run's transcript lands, or nil to leave no trace. Headless runs default to
  /// nil: an eval or panel trial persisting a session per candidate would flood the store.
  private let sessionStore: SessionStore?
  private let catalog: ModelCatalog?
  /// The base configuration every run starts from; `run` overrides only the model,
  /// fallbacks and dialect it is handed.
  public let configuration: Session.Configuration
  /// Called with the live session at the start of each `run`, before the first request.
  /// Headless runs build their session inside `run`, so this is the only moment a caller
  /// can bind live state to it — the task tool's parent model and remaining budget.
  public var onSessionStart: (@Sendable (Session) -> Void)?
  /// Forward `.textDelta`/`.reasoningDelta` to `onEvent` as well. Off by default: headless
  /// output prints whole messages, and the deltas only matter to a caller streaming them on
  /// (`--output-format stream-json --include-partial`).
  public var includesDeltaEvents = false

  private let sessionLock = NSLock()
  private var liveSession: Session?

  /// The session of the run in flight — or of the last run, once it ended. What
  /// `interrupt()` cancels, and where the `RunRecord` of a run that *threw* can still be
  /// read (`lastSession?.lastRecord`): the loop appends the record before it rethrows.
  public var lastSession: Session? {
    sessionLock.withLock { liveSession }
  }

  /// Cancels the run in flight, if any — the headless twin of Ctrl-C. The session answers
  /// its outstanding tool calls with `[interrupted by user]`, appends a `RunRecord` with
  /// `stopReason == .interrupted`, and `run` returns normally with that record. Safe to call
  /// from a signal handler or a deadline task; a no-op with nothing running.
  public func interrupt() {
    guard let session = lastSession else { return }
    Task { await session.interrupt() }
  }

  /// - Parameters:
  ///   - catalog: the shared model manifest; each run builds its own OpenRouter catalog when nil.
  ///   - sessionStore: persist the run's transcript here (`arnes do --session`), making a
  ///     headless run resumable and capturable. Nil (the default) writes nothing.
  ///   - configuration: everything else a session needs (provider traits, instructions,
  ///     budget, hooks, effort, environment policy, permission mode/rules, working
  ///     directory). `run` overrides the model, fallbacks and dialect per call.
  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    sessionStore: SessionStore? = nil,
    catalog: ModelCatalog? = nil,
    configuration: Session.Configuration)
  {
    self.service = service
    self.tools = tools
    self.permissions = permissions
    self.store = store
    self.sessionStore = sessionStore
    self.catalog = catalog
    self.configuration = configuration
  }

  /// Field-by-field convenience over `init(configuration:)` for callers that don't hold a
  /// `Session.Configuration`.
  public convenience init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    sessionStore: SessionStore? = nil,
    maxSteps: Int = .max,
    catalog: ModelCatalog? = nil,
    provider: ProviderTraits = .openrouter,
    projectInstructions: String? = nil,
    maxCostUSD: Double? = nil,
    hooks: [HookDefinition] = [],
    reasoningEffort: Reasoning.Effort? = nil,
    subprocessEnvironment: SubprocessEnvironment = .default,
    permissionMode: PermissionMode = .default,
    permissionRules: PermissionRules = .empty,
    workingDirectory: URL? = nil,
    systemSuffix: String? = nil,
    hookHandlers: [any HookHandler] = [])
  {
    self.init(
      service: service,
      tools: tools,
      permissions: permissions,
      store: store,
      sessionStore: sessionStore,
      catalog: catalog,
      configuration: Session.Configuration(
        maxStepsPerTurn: maxSteps,
        systemSuffix: systemSuffix,
        projectInstructions: projectInstructions,
        maxCostUSD: maxCostUSD,
        hooks: hooks,
        reasoningEffort: reasoningEffort,
        provider: provider,
        subprocessEnvironment: subprocessEnvironment,
        workingDirectory: workingDirectory,
        permissionMode: permissionMode,
        permissionRules: permissionRules,
        hookHandlers: hookHandlers))
  }

  /// Runs the agent loop until the model stops calling tools, then optionally runs a
  /// loop-1 verifier on a separate model. Appends a `RunRecord` either way.
  ///
  /// - Parameter resuming: continue a persisted session instead of starting a fresh one
  ///   (`arnes do --resume/--continue/--fork`): same id, replayed history, cost and turn
  ///   index, `SessionStart` fired with `resume`. `model` still names the model to run —
  ///   pass `resuming.model` to keep the transcript's; anything else is a `/model`-style
  ///   swap, recorded in the transcript. The `sessionStore` this agent was built with is
  ///   where the continued transcript lands, so pass the store the session came from.
  /// - Parameter sessionId: the id a *fresh* session takes instead of a random UUID
  ///   (`arnes do --session-id`), so a pipeline can name the transcript it will resume; the
  ///   caller checks the store for a collision. Ignored when `resuming` — a resumed run keeps
  ///   its transcript's id.
  public func run(
    task: String,
    model: String,
    fallbackModels: [String] = [],
    verifierModel: String? = nil,
    dialect: DialectOverride = .auto,
    resuming: LoadedSession? = nil,
    onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in },
    sessionId: String? = nil)
    async throws -> AgentResult
  {
    let startedAt = Date()
    var runConfiguration = configuration
    runConfiguration.model = model
    runConfiguration.fallbackModels = fallbackModels
    runConfiguration.dialect = dialect
    // A one-shot run has no next turn to deliver a background report into: the turn joins
    // every background subagent before it ends, whatever the caller's configuration said.
    runConfiguration.joinBackgroundAtTurnEnd = true
    let session: Session
    if let resuming {
      session = Session(
        resuming: resuming,
        service: service,
        tools: tools,
        permissions: permissions,
        store: store,
        sessionStore: sessionStore,
        catalog: catalog,
        configuration: runConfiguration)
    } else {
      session = Session(
        service: service,
        tools: tools,
        permissions: permissions,
        store: store,
        sessionStore: sessionStore,
        catalog: catalog,
        configuration: runConfiguration,
        id: sessionId)
    }
    // Published before the first request so `interrupt()` has something to cancel from the
    // very start, and kept after the run so a thrown run's record is still reachable.
    sessionLock.withLock { liveSession = session }
    onSessionStart?(session)
    // The session lifecycle a headless run has: SessionStart before the one turn, SessionEnd
    // after it — on a thrown run too, so a notify-on-end hook sees every run, with `other`
    // as the reason since the run didn't reach its exit.
    for notice in await session.start(source: resuming == nil ? .startup : .resume) {
      onEvent(.hookNotice(event: notice.event, output: notice.output))
    }

    var finalText = ""
    var structuredOutput: JSONValue?
    do {
      // A resumed session runs on the transcript's model unless the caller named another —
      // the same swap `/model` does, and persisted the same way (`model_change`). Inside the
      // lifecycle pair: a manifest that can't be fetched for the new model fails the run the
      // way a failed request does, with SessionEnd still fired.
      if let resuming, model != resuming.model {
        _ = try await session.setModel(model)
      }
      for try await event in await session.send(task, verifyWith: verifierModel) {
        switch event {
        case .textDelta, .reasoningDelta:
          // Headless output prints whole messages; deltas are for interactive rendering —
          // forwarded only to a caller that asked to stream them on.
          if includesDeltaEvents { onEvent(event) }
        case .assistantText(let text):
          finalText = text
          onEvent(event)
        case .structuredOutput(let json, _, _):
          // The event, not the record: an oversized object is left off the record and would
          // otherwise be lost to the envelope.
          structuredOutput = json
          onEvent(event)
        default:
          onEvent(event)
        }
      }
    } catch {
      for notice in await session.end(reason: .other) {
        onEvent(.hookNotice(event: notice.event, output: notice.output))
      }
      throw error
    }
    for notice in await session.end(reason: .exit) {
      onEvent(.hookNotice(event: notice.event, output: notice.output))
    }

    guard let record = await session.lastRecord else {
      // The turn loop always appends a record before finishing without error.
      throw SessionError.nothingToVerify
    }
    return AgentResult(
      text: finalText, record: record, sessionId: session.id,
      durationMs: Int(Date().timeIntervalSince(startedAt) * 1000),
      structuredOutput: structuredOutput)
  }
}
