import Foundation
import OpenRouterSwift

// MARK: - MessagesTranslator

/// Chat-shaped history → Anthropic Messages request pieces. History stays canonical in
/// the chat dialect; translation happens per request, which is what keeps mid-session
/// `/model` swaps working across dialects.
enum MessagesTranslator {

  /// Anthropic requires `max_tokens`; this is a generous ceiling, not a target.
  static let maxOutputTokens = 8192

  static func history(_ messages: [Message]) -> [AnthropicMessage] {
    var result: [AnthropicMessage] = []
    // tool_result blocks must ride a single user message following the assistant's
    // tool_use turn, so consecutive chat `.tool` messages merge into one.
    var pendingToolResults: [AnthropicContentBlock] = []
    func flushToolResults() {
      guard !pendingToolResults.isEmpty else { return }
      result.append(AnthropicMessage(role: .user, content: .blocks(pendingToolResults)))
      pendingToolResults = []
    }

    for message in messages {
      switch message.role {
      case .user:
        flushToolResults()
        result.append(.user(message.content?.plainText ?? ""))
      case .assistant:
        flushToolResults()
        var blocks: [AnthropicContentBlock] = []
        if let text = message.content?.plainText, !text.isEmpty {
          blocks.append(.text(text))
        }
        for call in message.toolCalls ?? [] {
          blocks.append(.toolUse(
            id: call.id ?? "",
            name: call.function?.name ?? "",
            input: jsonValue(call.function?.arguments)))
        }
        guard !blocks.isEmpty else { continue }
        result.append(AnthropicMessage(role: .assistant, content: .blocks(blocks)))
      case .tool:
        pendingToolResults.append(.toolResult(
          toolUseId: message.toolCallId ?? "",
          content: message.content?.plainText ?? ""))
      default:
        continue // system rides the request's `system` field
      }
    }
    flushToolResults()
    return result
  }

  static func tool(_ tool: any AgentTool) -> AnthropicTool {
    .custom(name: tool.name, inputSchema: tool.parameters, description: tool.description)
  }

  /// Chat tool-call arguments are a JSON string; Anthropic wants the object.
  static func jsonValue(_ argumentsJSON: String?) -> JSONValue {
    guard
      let argumentsJSON,
      let value = try? JSONDecoder().decode(JSONValue.self, from: Data(argumentsJSON.utf8))
    else {
      return .object([:])
    }
    return value
  }
}

// MARK: - MessagesAccumulator

/// Folds a `MessagesStreamEvent` stream into one assistant step, mirroring what
/// `StreamAccumulator` does for chat chunks: full text, merged tool calls (as
/// chat-shaped `ToolCall`s so the canonical history never changes shape), usage,
/// and the served model. Pure and synchronous for unit testing.
struct MessagesAccumulator {
  struct Deltas {
    var text: String?
    var reasoning: String?
  }

  private(set) var text = ""
  private(set) var reasoning = ""
  private(set) var routedModel: String?
  private(set) var stopReason: String?
  private(set) var cost: Double?
  private(set) var promptTokens: Int?

  private struct PartialToolUse {
    var id: String
    var name: String
    var argumentsJSON: String
  }

  private var toolUsesByIndex: [Int: PartialToolUse] = [:]

  /// Merged tool calls in block order, chat-shaped for the canonical history.
  var toolCalls: [ToolCall] {
    toolUsesByIndex.sorted { $0.key < $1.key }.map { index, partial in
      ToolCall(
        id: partial.id,
        type: "function",
        index: index,
        function: ToolCall.Function(
          name: partial.name,
          arguments: partial.argumentsJSON.isEmpty ? "{}" : partial.argumentsJSON))
    }
  }

  mutating func ingest(_ event: MessagesStreamEvent) -> Deltas {
    var deltas = Deltas()
    switch event {
    case .messageStart(let message):
      if let model = message["model"]?.stringValue {
        routedModel = model
      }
      if let input = message["usage"]?["input_tokens"]?.intValue {
        promptTokens = input
      }
    case .contentBlockStart(let index, let block):
      if block["type"]?.stringValue == "tool_use" {
        toolUsesByIndex[index] = PartialToolUse(
          id: block["id"]?.stringValue ?? "",
          name: block["name"]?.stringValue ?? "",
          argumentsJSON: "")
      }
    case .contentBlockDelta(let index, let delta):
      switch delta {
      case .textDelta(let piece):
        text += piece
        deltas.text = piece
      case .thinkingDelta(let piece):
        reasoning += piece
        deltas.reasoning = piece
      case .inputJSONDelta(let partialJSON):
        toolUsesByIndex[index]?.argumentsJSON += partialJSON
      case .signatureDelta, .other:
        break
      }
    case .messageDelta(let delta, let usage):
      if let stop = delta["stop_reason"]?.stringValue {
        stopReason = stop
      }
      if let value = usage?["cost"]?.doubleValue {
        cost = value
      }
      if let input = usage?["input_tokens"]?.intValue {
        promptTokens = input
      }
    case .contentBlockStop, .messageStop, .ping, .other:
      break
    }
    return deltas
  }
}
