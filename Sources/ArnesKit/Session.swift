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

  // MARK: Configuration

  public struct Configuration: Sendable {
    public var model: String
    public var fallbackModels: [String]
    public var maxStepsPerTurn: Int
    /// Wire dialect selection; `.auto` follows the model's profile (native for
    /// Anthropic/OpenAI families, chat otherwise).
    public var dialect: DialectOverride

    public init(
      model: String = "openrouter/auto",
      fallbackModels: [String] = [],
      maxStepsPerTurn: Int = 30,
      dialect: DialectOverride = .auto)
    {
      self.model = model
      self.fallbackModels = fallbackModels
      self.maxStepsPerTurn = maxStepsPerTurn
      self.dialect = dialect
    }
  }

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
  }

  /// What a compaction did.
  public struct CompactionResult: Sendable {
    public let summarizedMessages: Int
    public let keptMessages: Int
    public let costUSD: Double
  }

  // MARK: State

  public nonisolated let id: String
  public private(set) var model: String
  public private(set) var costUSD: Double
  /// The conversation so far, system prompt excluded (it is rebuilt per request
  /// from the prompt pack for the current model's family).
  public private(set) var history: [Message]

  private let service: OpenRouterService
  private let catalog: ModelCatalog
  private let tools: [any AgentTool]
  private let permissions: any PermissionDelegate
  private let store: RunRecordStore
  private let sessionStore: SessionStore?
  private let dialectStore: DialectVerdictStore
  private let fallbackModels: [String]
  private let maxStepsPerTurn: Int
  private let dialectOverride: DialectOverride
  private var alwaysAllowedTools: Set<String> = []
  private var turnTask: Task<Void, Never>?
  private var turnIndex: Int
  private var metaWritten: Bool
  private var lastUserText: String?
  private var lastAssistantText: String?
  /// Summary of history that was compacted away; injected into the system prompt.
  private var compactionSummary: String?
  /// Prompt tokens reported by the most recent request — drives auto-compaction.
  public private(set) var lastPromptTokens: Int?
  /// Auto-compact when the context is this full (fraction of `contextLength`).
  private let compactionThreshold = 0.8

  // MARK: Init

  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    sessionStore: SessionStore? = nil,
    dialectStore: DialectVerdictStore = DialectVerdictStore(),
    configuration: Configuration = Configuration())
  {
    id = UUID().uuidString
    model = configuration.model
    costUSD = 0
    history = []
    self.service = service
    catalog = ModelCatalog(service: service)
    self.tools = tools
    self.permissions = permissions
    self.store = store
    self.sessionStore = sessionStore
    self.dialectStore = dialectStore
    fallbackModels = configuration.fallbackModels
    maxStepsPerTurn = configuration.maxStepsPerTurn
    dialectOverride = configuration.dialect
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
    configuration: Configuration = Configuration())
  {
    id = loaded.meta.id
    model = loaded.model
    costUSD = loaded.costUSD
    history = loaded.messages
    self.service = service
    catalog = ModelCatalog(service: service)
    self.tools = tools
    self.permissions = permissions
    self.store = store
    self.sessionStore = sessionStore
    self.dialectStore = dialectStore
    fallbackModels = configuration.fallbackModels
    maxStepsPerTurn = configuration.maxStepsPerTurn
    dialectOverride = configuration.dialect
    turnIndex = loaded.turnCount
    metaWritten = true
    compactionSummary = loaded.compactionSummary
  }

  public static let defaultTools: [any AgentTool] = [
    ReadFileTool(), WriteFileTool(), EditFileTool(), BashTool(), GrepTool(), GlobTool(),
  ]

  /// The default toolset bound to a working directory: relative paths resolve there and
  /// bash runs with it as CWD. This is what lets panel candidates run in parallel without
  /// touching the process CWD.
  public static func tools(root: URL) -> [any AgentTool] {
    [
      ReadFileTool(root: root), WriteFileTool(root: root), EditFileTool(root: root),
      BashTool(root: root), GrepTool(root: root), GlobTool(root: root),
    ]
  }

  // MARK: Public API

  public var messageCount: Int { history.count }

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

  /// Mid-conversation model swap. History is untouched; the next request carries the
  /// new model and the prompt pack for its family. Returns the profile so callers can
  /// warn when the model doesn't support tools.
  public func setModel(_ slug: String) async throws -> ModelProfile {
    let profile = try await catalog.profile(for: slug)
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
    let verdict = try await runVerifier(task: task, outcome: outcome, model: verifierModel)
    costUSD += verdict.costUSD
    return (verdict.passed, verdict.text)
  }

  public func clearHistory() {
    history.removeAll()
    lastUserText = nil
    lastAssistantText = nil
    compactionSummary = nil
    lastPromptTokens = nil
    persist(.clear())
  }

  /// Compacts the conversation: everything before the last user message is summarized
  /// by `summarizerModel` (default `openrouter/auto`) into a note that rides in the
  /// system prompt; the last turn stays verbatim. Also triggered automatically when a
  /// turn starts with the context ~80% full (`profile.contextLength` from the manifest).
  @discardableResult
  public func compact(with summarizerModel: String? = nil) async throws -> CompactionResult {
    guard turnTask == nil else { throw SessionError.turnInFlight }
    return try await performCompaction(with: summarizerModel)
  }

  private func performCompaction(with summarizerModel: String?) async throws -> CompactionResult {
    // Cut at the last user message so the current turn (including any tool exchanges
    // after it) survives verbatim and no tool call is separated from its result.
    guard let keepFrom = history.lastIndex(where: { $0.role == .user }), keepFrom > 0 else {
      return CompactionResult(summarizedMessages: 0, keptMessages: history.count, costUSD: 0)
    }
    let dropped = Array(history[..<keepFrom])
    let kept = Array(history[keepFrom...])
    let response = try await service.chatCompletion(
      ChatCompletionRequest(
        model: summarizerModel ?? "openrouter/auto",
        messages: [
          .system(Self.compactionPrompt),
          .user(Self.renderTranscript(dropped, existingSummary: compactionSummary)),
        ]))
    guard let summary = response.choices.first?.message.content, !summary.isEmpty else {
      throw SessionError.compactionFailed
    }
    let cost = response.usage?.cost ?? 0
    costUSD += cost
    compactionSummary = summary
    history = kept
    lastPromptTokens = nil // stale until the next request reports usage
    persist(.compaction(summary: summary))
    for message in kept {
      persist(TranscriptEntry(message: message))
    }
    persist(.cost(turnUSD: cost, sessionUSD: costUSD))
    return CompactionResult(summarizedMessages: dropped.count, keptMessages: kept.count, costUSD: cost)
  }

  // MARK: Anti-stall nudge

  /// At most this many continuation nudges per turn — enough to recover a stall,
  /// bounded so a model with nothing left to do can't loop on nudges.
  static let maxNudgesPerTurn = 2

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

  private static let compactionPrompt = """
    You compress an agent conversation into notes the assistant will rely on to continue \
    seamlessly. Preserve: the user's goals and constraints, decisions made, file paths and \
    code entities touched, the current state of the task, and unresolved items. Be specific \
    and terse. Reply with only the notes.
    """

  private static func renderTranscript(_ messages: [Message], existingSummary: String?) -> String {
    var lines: [String] = []
    if let existingSummary {
      lines.append("[earlier summary]\n\(existingSummary)")
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

    // Auto-compact before this turn when the previous request reported a nearly full
    // context. The whole previous turn stays verbatim; older history becomes a note.
    if let contextLength = profile.contextLength,
       let used = lastPromptTokens,
       Double(used) >= Double(contextLength) * compactionThreshold,
       let result = try? await performCompaction(with: nil),
       result.summarizedMessages > 0
    {
      continuation.yield(.compacted(
        summarizedMessages: result.summarizedMessages,
        keptMessages: result.keptMessages))
    }

    // The dialect actually executed this turn — recorded, not just preferred. A fresh
    // failed conformance verdict pins `.auto` to chat before the first request.
    var dialect = dialectOverride.effective(for: profile)
    if dialectOverride == .auto, dialect != .chat,
       dialectStore.isKnownBad(model: model, dialect: dialect)
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
    turnIndex += 1
    lastUserText = text

    appendToHistory(.user(text))

    var turnCost = 0.0
    var finalText = ""
    var interrupted = false
    var turnError: Error?
    var nudgesUsed = 0

    loop: for _ in 0..<maxStepsPerTurn {
      if Task.isCancelled {
        interrupted = true
        break
      }
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
        turnError = error
        break loop
      }

      if dialect != .chat {
        if let failure = step.failure {
          // The native endpoint misbehaved. Record it either way; rerun this step on
          // chat only when nothing streamed yet (a mid-stream retry would duplicate
          // output) and the user didn't force the dialect.
          dialectStore.record(model: model, dialect: dialect, ok: false, reason: failure)
          guard dialectOverride == .auto, !step.emittedOutput, !step.interrupted else {
            turnError = DialectError.nativeDialectFailed(dialect.rawValue, failure)
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
          } catch {
            turnError = error
            break loop
          }
        } else if !step.interrupted {
          // A clean native step is the conformance probe, for free.
          dialectStore.record(model: model, dialect: dialect, ok: true)
        }
      }

      for served in step.routed where !record.routedModels.contains(served) {
        record.routedModels.append(served)
      }
      if let cost = step.cost {
        record.costUSD += cost
        turnCost += cost
        costUSD += cost
      }
      if let promptTokens = step.promptTokens {
        lastPromptTokens = promptTokens
      }
      if step.interrupted || Task.isCancelled {
        // Nothing from this step is in the history yet — safe to stop here.
        interrupted = true
        break loop
      }

      if !step.text.isEmpty {
        finalText = step.text
        lastAssistantText = step.text
        continuation.yield(.assistantText(step.text))
      }

      let toolCalls = step.toolCalls
      guard !toolCalls.isEmpty else {
        // The model stopped calling tools. An empty reply, or one trailing off with
        // "let me check X" narration, is a stall — not a finish. Nudge it back into
        // the loop instead of silently ending the turn; bounded so a model that
        // genuinely has nothing to do can't ping-pong forever.
        if profile.supportsTools, !tools.isEmpty, nudgesUsed < Self.maxNudgesPerTurn,
           Self.looksUnfinished(step.text)
        {
          nudgesUsed += 1
          if !step.text.isEmpty {
            appendToHistory(.assistant(step.text))
          }
          appendToHistory(.user(Self.continueNudge))
          continuation.yield(.nudged(
            reason: step.text.isEmpty ? "empty reply" : "announced more work"))
          continue
        }
        if !step.text.isEmpty {
          appendToHistory(.assistant(step.text))
        }
        record.finished = true
        break loop
      }

      appendToHistory(Message(
        role: .assistant,
        content: step.text.isEmpty ? nil : .text(step.text),
        toolCalls: toolCalls))

      var answered: Set<String> = []
      for call in toolCalls {
        if Task.isCancelled {
          interrupted = true
          break
        }
        record.toolCalls += 1
        let name = call.function?.name ?? ""
        let argumentsJSON = call.function?.arguments ?? "{}"
        let callId = call.id ?? ""
        continuation.yield(.toolCall(name: name, arguments: argumentsJSON))

        let output: String
        if let denial = await permissionDenial(name: name, argumentsJSON: argumentsJSON) {
          output = denial
          continuation.yield(.toolDenied(name: name, reason: denial))
        } else {
          output = await execute(name: name, argumentsJSON: argumentsJSON)
          continuation.yield(.toolResult(name: name, preview: String(output.prefix(200))))
        }
        appendToHistory(.tool(output, toolCallId: callId))
        answered.insert(callId)
      }

      if interrupted || Task.isCancelled {
        interrupted = true
        // Answer any outstanding calls so the history has no dangling tool calls —
        // the next request would otherwise be rejected by the API.
        for call in toolCalls where !answered.contains(call.id ?? "") {
          appendToHistory(.tool("[interrupted by user]", toolCallId: call.id ?? ""))
        }
        break loop
      }
    }

    if !record.finished, !interrupted, turnError == nil {
      // The for-loop ran out of steps mid-task — surface it instead of ending the
      // turn as if the model had chosen to stop.
      continuation.yield(.stepLimitReached(maxSteps: maxStepsPerTurn))
    }

    if interrupted {
      continuation.yield(.interrupted)
    }

    if let verifyWith, record.finished {
      do {
        let verdict = try await runVerifier(task: text, outcome: finalText, model: verifyWith)
        record.costUSD += verdict.costUSD
        turnCost += verdict.costUSD
        costUSD += verdict.costUSD
        record.verifierPassed = verdict.passed
        continuation.yield(.verifier(passed: verdict.passed, verdict: verdict.text))
      } catch {
        if turnError == nil { turnError = error }
      }
    }

    record.summary = String(finalText.prefix(500))
    try? store.append(record)
    lastRecord = record
    persist(.cost(turnUSD: turnCost, sessionUSD: costUSD))

    if let turnError {
      continuation.finish(throwing: turnError)
      return
    }
    continuation.yield(.turnFinished(TurnStats(
      steps: record.steps,
      toolCalls: record.toolCalls,
      turnCostUSD: turnCost,
      sessionCostUSD: costUSD,
      requestedModel: record.model,
      routedModels: record.routedModels,
      promptTokens: lastPromptTokens,
      contextLength: profile.contextLength)))
    continuation.finish()
  }

  // MARK: Dialect steps

  /// One streamed assistant step, accumulated dialect-agnostically. The loop above
  /// consumes this shape regardless of the wire format the step spoke.
  private struct StepOutcome {
    var text = ""
    var toolCalls: [ToolCall] = []
    var cost: Double?
    var promptTokens: Int?
    /// Served models observed this step, in order.
    var routed: [String] = []
    var interrupted = false
    /// Native-endpoint misbehavior (thrown transport error or a failed response).
    /// Chat steps never set this — chat is the floor there's no falling back from.
    var failure: String?
    /// Whether any text/reasoning delta reached the caller (a fallback rerun after
    /// output would duplicate what the user already saw).
    var emittedOutput = false
  }

  private func streamStep(
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
    do {
      let stream = try await service.chatCompletionStream(
        ChatCompletionRequest(
          model: model,
          models: fallbackModels.isEmpty ? nil : fallbackModels,
          messages: [.system(systemText(pack: pack))] + history,
          tools: profile.supportsTools ? tools.map(\.toolDefinition) : nil))
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
    }
    outcome.text = accumulator.text
    outcome.toolCalls = accumulator.toolCalls
    outcome.cost = accumulator.usage?.cost
    outcome.promptTokens = accumulator.usage?.promptTokens
    return outcome
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
    do {
      let stream = try await service.messageStream(
        MessagesRequest(
          model: model,
          messages: MessagesTranslator.history(history),
          maxTokens: MessagesTranslator.maxOutputTokens,
          system: systemText(pack: pack),
          tools: profile.supportsTools ? tools.map(MessagesTranslator.tool) : nil,
          models: fallbackModels.isEmpty ? nil : fallbackModels))
      for try await event in stream {
        let deltas = accumulator.ingest(event)
        noteRouted(
          accumulator.routedModel, provider: nil,
          outcome: &outcome, knownRouted: knownRouted, continuation: continuation)
        yieldDeltas(text: deltas.text, reasoning: deltas.reasoning, outcome: &outcome, continuation: continuation)
      }
    } catch is CancellationError {
      outcome.interrupted = true
    } catch {
      outcome.failure = "\(error)"
    }
    outcome.text = accumulator.text
    outcome.toolCalls = accumulator.toolCalls
    outcome.cost = accumulator.cost
    outcome.promptTokens = accumulator.promptTokens
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
    do {
      let stream = try await service.responseStream(
        ResponsesRequest(
          model: model,
          models: fallbackModels.isEmpty ? nil : fallbackModels,
          input: .items(ResponsesTranslator.history(history)),
          instructions: systemText(pack: pack),
          tools: profile.supportsTools ? tools.map(ResponsesTranslator.tool) : nil))
      for try await event in stream {
        let deltas = accumulator.ingest(event)
        noteRouted(
          accumulator.routedModel, provider: nil,
          outcome: &outcome, knownRouted: knownRouted, continuation: continuation)
        yieldDeltas(text: deltas.text, reasoning: deltas.reasoning, outcome: &outcome, continuation: continuation)
      }
    } catch is CancellationError {
      outcome.interrupted = true
    } catch {
      outcome.failure = "\(error)"
    }
    if !outcome.interrupted, let failure = accumulator.failure {
      outcome.failure = failure
    }
    outcome.text = accumulator.text
    outcome.toolCalls = accumulator.toolCalls
    outcome.cost = accumulator.cost
    outcome.promptTokens = accumulator.promptTokens
    return outcome
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

  /// The prompt pack for the current model, plus the skill listing when a `SkillTool`
  /// is in the toolset, plus the compaction summary when one exists.
  private func systemText(pack: PromptPack) -> String {
    var text = pack.text
    if let section = tools.lazy.compactMap({ $0 as? SkillTool }).first?.promptSection,
       !section.isEmpty
    {
      text += "\n\n" + section
    }
    if let compactionSummary {
      text += "\n\n# Conversation summary\nEarlier context was compacted. Rely on these notes:\n"
        + compactionSummary
    }
    return text
  }

  // MARK: Helpers

  /// Returns the model-facing denial text when the delegate refuses, nil when allowed.
  private func permissionDenial(name: String, argumentsJSON: String) async -> String? {
    guard
      let tool = tools.first(where: { $0.name == name }),
      tool.permission == .mutating,
      !alwaysAllowedTools.contains(name)
    else {
      return nil
    }
    let arguments = Self.decodeArguments(argumentsJSON)
    let decision = await permissions.decide(
      toolName: name,
      summary: tool.summary(arguments: arguments),
      argumentsJSON: argumentsJSON)
    switch decision {
    case .allow:
      return nil
    case .allowAlwaysThisSession:
      alwaysAllowedTools.insert(name)
      return nil
    case .deny(let reason):
      return "user denied permission to run \(name)\(reason.map { ": \($0)" } ?? "")"
    }
  }

  private func execute(name: String, argumentsJSON: String) async -> String {
    guard let tool = tools.first(where: { $0.name == name }) else {
      return "error: unknown tool \(name)"
    }
    do {
      return try await tool.execute(arguments: Self.decodeArguments(argumentsJSON))
    } catch {
      return "error: \(error)"
    }
  }

  private static func decodeArguments(_ json: String) -> [String: JSONValue] {
    (try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))) ?? [:]
  }

  /// Loop 1: adversarial verification on a different (usually cheaper) model.
  private func runVerifier(
    task: String,
    outcome: String,
    model verifierModel: String)
    async throws -> (passed: Bool, text: String, costUSD: Double)
  {
    let response = try await service.chatCompletion(
      ChatCompletionRequest(
        model: verifierModel,
        messages: [
          .system("""
            You are a skeptical verifier. Given a task and an agent's report, decide whether \
            the task was plausibly completed. Reply with exactly one line starting with \
            PASS or FAIL, followed by a one-sentence reason. Default to FAIL when uncertain.
            """),
          .user("Task:\n\(task)\n\nAgent report:\n\(outcome)"),
        ]))
    let text = response.choices.first?.message.content ?? "FAIL no verdict"
    return (text.hasPrefix("PASS"), text, response.usage?.cost ?? 0)
  }

  private func appendToHistory(_ message: Message) {
    history.append(message)
    persist(TranscriptEntry(message: message))
  }

  private func persist(_ entry: TranscriptEntry) {
    guard let sessionStore else { return }
    writeMetaIfNeeded()
    try? sessionStore.append(entry, to: id)
  }

  private func writeMetaIfNeeded() {
    guard let sessionStore, !metaWritten else { return }
    metaWritten = true
    try? sessionStore.append(
      .meta(id: id, model: model, cwd: FileManager.default.currentDirectoryPath),
      to: id)
  }
}
