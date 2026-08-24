import Foundation
import OpenRouterSwift

// MARK: - SessionError

public enum SessionError: Error, Sendable {
  /// `send` was called while a previous turn is still streaming.
  case turnInFlight
  /// `verifyLastTurn` was called before any completed turn.
  case nothingToVerify
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

    public init(
      model: String = "openrouter/auto",
      fallbackModels: [String] = [],
      maxStepsPerTurn: Int = 30)
    {
      self.model = model
      self.fallbackModels = fallbackModels
      self.maxStepsPerTurn = maxStepsPerTurn
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
  private let fallbackModels: [String]
  private let maxStepsPerTurn: Int
  private var alwaysAllowedTools: Set<String> = []
  private var turnTask: Task<Void, Never>?
  private var turnIndex: Int
  private var metaWritten: Bool
  private var lastUserText: String?
  private var lastAssistantText: String?

  // MARK: Init

  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    sessionStore: SessionStore? = nil,
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
    fallbackModels = configuration.fallbackModels
    maxStepsPerTurn = configuration.maxStepsPerTurn
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
    fallbackModels = configuration.fallbackModels
    maxStepsPerTurn = configuration.maxStepsPerTurn
    turnIndex = loaded.turnCount
    metaWritten = true
  }

  public static let defaultTools: [any AgentTool] = [
    ReadFileTool(), WriteFileTool(), EditFileTool(), BashTool(), GrepTool(), GlobTool(),
  ]

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
    persist(.clear())
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
    var record = RunRecord(
      task: text,
      model: model,
      dialect: profile.dialect.rawValue,
      packFamily: profile.family.rawValue)
    record.sessionId = id
    record.turnIndex = turnIndex
    turnIndex += 1
    lastUserText = text

    appendToHistory(.user(text))

    var turnCost = 0.0
    var finalText = ""
    var lastRouted: String?
    var interrupted = false
    var turnError: Error?

    loop: for _ in 0..<maxStepsPerTurn {
      if Task.isCancelled {
        interrupted = true
        break
      }
      record.steps += 1

      var accumulator = StreamAccumulator()
      do {
        let stream = try await service.chatCompletionStream(
          ChatCompletionRequest(
            model: model,
            models: fallbackModels.isEmpty ? nil : fallbackModels,
            messages: [.system(pack.text)] + history,
            tools: profile.supportsTools ? tools.map(\.toolDefinition) : nil))
        for try await chunk in stream {
          let deltas = accumulator.ingest(chunk)
          // Surface routing as soon as the served model is known, before any text.
          if let routed = accumulator.routedModel, routed != lastRouted {
            lastRouted = routed
            if !record.routedModels.contains(routed) {
              record.routedModels.append(routed)
            }
            continuation.yield(.routed(model: routed, provider: accumulator.provider))
          }
          if let textDelta = deltas.text {
            continuation.yield(.textDelta(textDelta))
          }
          if let reasoningDelta = deltas.reasoning {
            continuation.yield(.reasoningDelta(reasoningDelta))
          }
        }
      } catch is CancellationError {
        interrupted = true
      } catch {
        turnError = error
        break loop
      }

      if let cost = accumulator.usage?.cost {
        record.costUSD += cost
        turnCost += cost
        costUSD += cost
      }
      if Task.isCancelled {
        // Nothing from this step is in the history yet — safe to stop here.
        interrupted = true
        break loop
      }

      if !accumulator.text.isEmpty {
        finalText = accumulator.text
        lastAssistantText = accumulator.text
        continuation.yield(.assistantText(accumulator.text))
      }

      let toolCalls = accumulator.toolCalls
      guard !toolCalls.isEmpty else {
        if !accumulator.text.isEmpty {
          appendToHistory(.assistant(accumulator.text))
        }
        record.finished = true
        break loop
      }

      appendToHistory(Message(
        role: .assistant,
        content: accumulator.text.isEmpty ? nil : .text(accumulator.text),
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
      routedModels: record.routedModels)))
    continuation.finish()
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
