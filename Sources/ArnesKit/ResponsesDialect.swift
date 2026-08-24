import Foundation
import OpenRouterSwift

// MARK: - DialectError

public enum DialectError: Error, Sendable {
  /// The Responses endpoint reported a failed or errored response.
  case responsesFailed(String)
}

// MARK: - ResponsesTranslator

/// Chat-shaped history → OpenAI Responses input items. The system prompt travels as
/// the request's `instructions`; chat tool-call ids round-trip as `call_id`s.
enum ResponsesTranslator {

  static func history(_ messages: [Message]) -> [ResponseInputItem] {
    var items: [ResponseInputItem] = []
    for message in messages {
      switch message.role {
      case .user:
        items.append(.user(message.content?.plainText ?? ""))
      case .assistant:
        if let text = message.content?.plainText, !text.isEmpty {
          items.append(.assistant(text))
        }
        for call in message.toolCalls ?? [] {
          items.append(.functionCall(
            callId: call.id ?? "",
            name: call.function?.name ?? "",
            arguments: call.function?.arguments ?? "{}"))
        }
      case .tool:
        items.append(.functionCallOutput(
          callId: message.toolCallId ?? "",
          output: message.content?.plainText ?? ""))
      default:
        continue // system rides the request's `instructions` field
      }
    }
    return items
  }

  static func tool(_ tool: any AgentTool) -> ResponsesTool {
    .function(name: tool.name, parameters: tool.parameters, description: tool.description)
  }
}

// MARK: - ResponsesAccumulator

/// Folds a `ResponsesStreamEvent` stream into one assistant step: full text, merged
/// tool calls (chat-shaped, with `call_id` as the id so results round-trip), usage,
/// and the served model. Pure and synchronous for unit testing.
struct ResponsesAccumulator {
  struct Deltas {
    var text: String?
    var reasoning: String?
  }

  private(set) var text = ""
  private(set) var reasoning = ""
  private(set) var routedModel: String?
  private(set) var cost: Double?
  private(set) var promptTokens: Int?
  /// Set when the stream reports a failed/errored response.
  private(set) var failure: String?

  private struct PartialCall {
    var callId: String
    var name: String
    var arguments: String
    var order: Int
  }

  /// Keyed by the output item's own id (argument deltas reference it); `call_id`
  /// is what lands in the chat-shaped `ToolCall`.
  private var callsByItemId: [String: PartialCall] = [:]
  private var lastItemId: String?
  private var nextOrder = 0

  var toolCalls: [ToolCall] {
    callsByItemId.values.sorted { $0.order < $1.order }.enumerated().map { index, partial in
      ToolCall(
        id: partial.callId,
        type: "function",
        index: index,
        function: ToolCall.Function(
          name: partial.name,
          arguments: partial.arguments.isEmpty ? "{}" : partial.arguments))
    }
  }

  mutating func ingest(_ event: ResponsesStreamEvent) -> Deltas {
    var deltas = Deltas()
    switch event {
    case .created(let response), .inProgress(let response):
      if let model = response.model {
        routedModel = model
      }
    case .outputItemAdded(_, let item), .outputItemDone(_, let item):
      merge(item)
    case .outputTextDelta(_, _, let delta):
      text += delta
      deltas.text = delta
    case .outputTextDone(_, _, let full):
      if !full.isEmpty {
        text = full
      }
    case .reasoningTextDelta(_, _, let delta):
      reasoning += delta
      deltas.reasoning = delta
    case .functionCallArgumentsDelta(let itemId, _, let delta):
      if let key = itemId ?? lastItemId {
        callsByItemId[key]?.arguments += delta
      }
    case .functionCallArgumentsDone(let itemId, _, let arguments):
      if let key = itemId ?? lastItemId, !arguments.isEmpty {
        callsByItemId[key]?.arguments = arguments
      }
    case .completed(let response), .incomplete(let response):
      if let model = response.model {
        routedModel = model
      }
      if let usage = response.usage {
        cost = usage.cost
        promptTokens = usage.inputTokens
      }
      // The final response's output is authoritative — merge any call the event
      // stream under-delivered.
      for item in response.output {
        merge(item)
      }
    case .failed(let response):
      failure = response.error?.message ?? "response failed"
    case .error(let code, let message):
      failure = message ?? code ?? "stream error"
    case .refusalDelta, .other:
      break
    }
    return deltas
  }

  private mutating func merge(_ item: ResponseOutputItem) {
    guard case .functionCall(let callId, let name, let arguments, let id, _) = item else {
      return
    }
    let key = id ?? callId
    var call = callsByItemId[key]
      ?? PartialCall(callId: callId, name: name, arguments: "", order: nextOrder)
    if callsByItemId[key] == nil {
      nextOrder += 1
    }
    call.callId = callId
    call.name = name
    if !arguments.isEmpty {
      call.arguments = arguments
    }
    callsByItemId[key] = call
    lastItemId = key
  }
}
