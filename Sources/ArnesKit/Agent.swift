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
  case assistantText(String)
  case toolCall(name: String, arguments: String)
  case toolResult(name: String, preview: String)
  case verifier(passed: Bool, verdict: String)
}

// MARK: - Agent

/// The Arnes agent loop, v0.
///
/// v0 runs every model over the `.chat` dialect (OpenRouter normalizes it for all
/// families); the prompt pack still adapts per family. Dialect-native execution
/// (`/messages` for Anthropic, `/responses` for OpenAI) is the next milestone —
/// see DESIGN.md.
public final class Agent: @unchecked Sendable {
  private let service: OpenRouterService
  private let catalog: ModelCatalog
  private let tools: [any AgentTool]
  private let store: RunRecordStore
  private let maxSteps: Int

  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = [ReadFileTool(), WriteFileTool(), BashTool()],
    store: RunRecordStore = RunRecordStore(),
    maxSteps: Int = 30)
  {
    self.service = service
    catalog = ModelCatalog(service: service)
    self.tools = tools
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
    let profile = try await catalog.profile(for: model)
    let pack = PromptPack.load(for: profile.family)
    var record = RunRecord(
      task: task,
      model: model,
      dialect: profile.dialect.rawValue,
      packFamily: profile.family.rawValue)

    var messages: [Message] = [
      .system(pack.text),
      .user(task),
    ]
    var finalText = ""

    for _ in 0..<maxSteps {
      record.steps += 1
      let response = try await service.chatCompletion(
        ChatCompletionRequest(
          model: model,
          models: fallbackModels.isEmpty ? nil : fallbackModels,
          messages: messages,
          tools: profile.supportsTools ? tools.map(\.toolDefinition) : nil))
      record.costUSD += response.usage?.cost ?? 0

      guard let message = response.choices.first?.message else { break }
      if let content = message.content, !content.isEmpty {
        finalText = content
        onEvent(.assistantText(content))
      }

      guard let toolCalls = message.toolCalls, !toolCalls.isEmpty else {
        record.finished = true
        break
      }

      messages.append(Message(
        role: .assistant,
        content: message.content.map { .text($0) },
        toolCalls: toolCalls))

      for call in toolCalls {
        record.toolCalls += 1
        let name = call.function?.name ?? ""
        let argumentsJSON = call.function?.arguments ?? "{}"
        onEvent(.toolCall(name: name, arguments: argumentsJSON))
        let output = await execute(name: name, argumentsJSON: argumentsJSON)
        onEvent(.toolResult(name: name, preview: String(output.prefix(200))))
        messages.append(.tool(output, toolCallId: call.id ?? ""))
      }
    }

    if let verifierModel, record.finished {
      let verdict = try await verify(
        task: task,
        outcome: finalText,
        model: verifierModel,
        costInto: &record)
      record.verifierPassed = verdict.passed
      onEvent(.verifier(passed: verdict.passed, verdict: verdict.text))
    }

    record.summary = String(finalText.prefix(500))
    try? store.append(record)
    return AgentResult(text: finalText, record: record)
  }

  private func execute(name: String, argumentsJSON: String) async -> String {
    guard let tool = tools.first(where: { $0.name == name }) else {
      return "error: unknown tool \(name)"
    }
    let arguments = (try? JSONDecoder().decode(
      [String: JSONValue].self,
      from: Data(argumentsJSON.utf8))) ?? [:]
    do {
      return try await tool.execute(arguments: arguments)
    } catch {
      return "error: \(error)"
    }
  }

  /// Loop 1: adversarial verification on a different (usually cheaper) model.
  private func verify(
    task: String,
    outcome: String,
    model: String,
    costInto record: inout RunRecord)
    async throws -> (passed: Bool, text: String)
  {
    let response = try await service.chatCompletion(
      ChatCompletionRequest(
        model: model,
        messages: [
          .system("""
            You are a skeptical verifier. Given a task and an agent's report, decide whether \
            the task was plausibly completed. Reply with exactly one line starting with \
            PASS or FAIL, followed by a one-sentence reason. Default to FAIL when uncertain.
            """),
          .user("Task:\n\(task)\n\nAgent report:\n\(outcome)"),
        ]))
    record.costUSD += response.usage?.cost ?? 0
    let text = response.choices.first?.message.content ?? "FAIL no verdict"
    return (text.hasPrefix("PASS"), text)
  }
}
