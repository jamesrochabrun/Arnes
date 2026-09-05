import Foundation
import OpenRouterSwift

// MARK: - DialectError

public enum DialectError: Error, Sendable {
  /// A native endpoint misbehaved and the run could not (or was told not to) fall
  /// back to chat: `(dialect, reason)`.
  case nativeDialectFailed(String, String)
}

// MARK: - ResponsesTranslator

/// Chat-shaped history → OpenAI Responses input items. The system prompt travels as
/// the request's `instructions`; chat tool-call ids round-trip as `call_id`s.
enum ResponsesTranslator {

  /// The `include` entry that asks the endpoint to return each reasoning item's
  /// `encrypted_content` — what a stateless follow-up request echoes so the model keeps its
  /// reasoning across a tool loop.
  static let encryptedReasoningInclude = "reasoning.encrypted_content"

  /// The reasoning items an assistant message carries, reconstructed for echoing: one
  /// `{"type":"reasoning","id":…,"encrypted_content":…,"summary":[]}` per
  /// `reasoning.encrypted` entry in the Responses format; every other format skipped.
  static func reasoningItems(for message: Message) -> [ResponseInputItem] {
    (message.reasoningDetails ?? []).compactMap { entry in
      guard ReasoningDetails.entry(entry, hasFormat: ReasoningDetails.Format.openaiResponses),
            entry["type"]?.stringValue == ReasoningDetails.EntryType.encrypted,
            let id = entry["id"]?.stringValue,
            let data = entry["data"]?.stringValue, !data.isEmpty
      else { return nil }
      return .other(.object([
        "type": .string("reasoning"),
        "id": .string(id),
        "encrypted_content": .string(data),
        "summary": .array([]),
      ]))
    }
  }

  static func history(_ messages: [Message]) -> [ResponseInputItem] {
    var items: [ResponseInputItem] = []
    for message in messages {
      switch message.role {
      case .user:
        items.append(userItem(message))
      case .assistant:
        // A reasoning item precedes the message's own text and function calls, as it did in
        // the response that produced them.
        items.append(contentsOf: reasoningItems(for: message))
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

  /// A user message as the Responses API wants it: plain text stays a text message; a message
  /// of content parts (a `view_image` attachment — T5) becomes `input_text`/`input_image` parts
  /// (an `input_image` takes a `data:` URL as it is). Parts the wire has no item for are dropped,
  /// as `plainText` drops them.
  static func userItem(_ message: Message) -> ResponseInputItem {
    guard case .parts(let parts)? = message.content else {
      return .user(message.content?.plainText ?? "")
    }
    var converted: [ResponseInputContentPart] = []
    for part in parts {
      switch part {
      case .text(let text, _): converted.append(.inputText(text))
      case .imageURL(let url, let detail, _): converted.append(.inputImage(url: url, detail: detail ?? "auto"))
      default: continue
      }
    }
    return converted.isEmpty
      ? .user(message.content?.plainText ?? "")
      : .message(role: "user", content: .parts(converted))
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
  private(set) var completionTokens: Int?
  /// `usage.input_tokens_details.cached_tokens`: input tokens served from OpenAI's automatic
  /// prompt cache (a subset of `promptTokens`); nil when the usage carries none.
  private(set) var cachedPromptTokens: Int?
  /// Set when the stream reports a failed/errored response.
  private(set) var failure: String?
  /// Why a `response.incomplete` response stopped short (`incomplete_details.reason` —
  /// `max_output_tokens` when it hit the output limit); nil for a completed response. The
  /// Responses dialect's finish word, read by the session the way chat reads `finish_reason`.
  private(set) var incompleteReason: String?

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

  private struct PartialReasoning {
    var data: String
    var order: Int
  }

  /// Reasoning items with `encrypted_content`, keyed by item id — the same item arrives on
  /// `output_item.added`, `output_item.done` and in the completed response's `output`, and
  /// must land once.
  private var reasoningById: [String: PartialReasoning] = [:]

  /// The step's replayable reasoning state: one `reasoning.encrypted` per reasoning item that
  /// carried `encrypted_content`, in output order, `format` the Responses dialect's. An item
  /// without encrypted content (or without an id to echo it under) leaves nothing to replay.
  var reasoningDetails: [JSONValue] {
    reasoningById.sorted { $0.value.order < $1.value.order }.map { id, partial in
      ReasoningDetails.encrypted(data: partial.data, id: id, format: ReasoningDetails.Format.openaiResponses)
    }
  }

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
      // An incomplete response (the `response.incomplete` event, or a final response whose
      // status says so) names why under `incomplete_details.reason`; the bare status is kept
      // when the reason is missing, so a cutoff is never read as a finish.
      var incomplete = response.status == "incomplete"
      if case .incomplete = event { incomplete = true }
      if incomplete {
        incompleteReason = response.incompleteDetails?["reason"]?.stringValue ?? "incomplete"
      }
      if let usage = response.usage {
        cost = usage.cost
        promptTokens = usage.inputTokens
        completionTokens = usage.outputTokens
        cachedPromptTokens = usage.inputTokensDetails?.cachedTokens
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
    if case .reasoning(let id, _, _, let encryptedContent) = item {
      guard let id, let encryptedContent, !encryptedContent.isEmpty else { return }
      if let existing = reasoningById[id] {
        reasoningById[id] = PartialReasoning(data: encryptedContent, order: existing.order)
      } else {
        reasoningById[id] = PartialReasoning(data: encryptedContent, order: nextOrder)
        nextOrder += 1
      }
      return
    }
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
