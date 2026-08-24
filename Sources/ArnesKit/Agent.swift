import Foundation
import OpenRouterSwift

// MARK: - AgentResult

public struct AgentResult: Sendable {
  public let text: String
  public let record: RunRecord
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
  case verifier(passed: Bool, verdict: String)
  /// The model/provider that actually served a step (differs from the requested
  /// slug when routing via `openrouter/auto` or fallbacks). Emitted on change.
  case routed(model: String, provider: String?)
  /// The turn was cancelled (Ctrl-C / `Session.interrupt`).
  case interrupted
  /// Older history was auto-summarized because the context was nearly full.
  case compacted(summarizedMessages: Int, keptMessages: Int)
  /// The turn completed; footer numbers for rendering.
  case turnFinished(Session.TurnStats)
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
  private let maxSteps: Int

  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    maxSteps: Int = 30)
  {
    self.service = service
    self.tools = tools
    self.permissions = permissions
    self.store = store
    self.maxSteps = maxSteps
  }

  /// Runs the agent loop until the model stops calling tools, then optionally runs a
  /// loop-1 verifier on a separate model. Appends a `RunRecord` either way.
  public func run(
    task: String,
    model: String,
    fallbackModels: [String] = [],
    verifierModel: String? = nil,
    onEvent: @escaping @Sendable (AgentEvent) -> Void = { _ in })
    async throws -> AgentResult
  {
    let session = Session(
      service: service,
      tools: tools,
      permissions: permissions,
      store: store,
      configuration: Session.Configuration(
        model: model,
        fallbackModels: fallbackModels,
        maxStepsPerTurn: maxSteps))

    var finalText = ""
    for try await event in await session.send(task, verifyWith: verifierModel) {
      switch event {
      case .textDelta, .reasoningDelta:
        // Headless output prints whole messages; deltas are for interactive rendering.
        continue
      case .assistantText(let text):
        finalText = text
        onEvent(event)
      default:
        onEvent(event)
      }
    }

    guard let record = await session.lastRecord else {
      // The turn loop always appends a record before finishing without error.
      throw SessionError.nothingToVerify
    }
    return AgentResult(text: finalText, record: record)
  }
}
