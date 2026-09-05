import Foundation
import OpenRouterSwift

// MARK: - ReasoningDetails

/// The vocabulary for the reasoning state an assistant step leaves behind and a later request
/// must replay: OpenRouter's own `reasoning_details` entry shape, so a block produced by the
/// native `/messages` or `/responses` path and one returned by chat completions are the same
/// object on `Message.reasoningDetails` — history stays chat-shaped, the translators read the
/// entries back into each dialect's blocks, and `format` is the dialect tag.
///
/// ```
/// {"type": "reasoning.text",      "text": …, "signature": …, "format": "anthropic-claude-v1"}
/// {"type": "reasoning.encrypted", "data": …,                 "format": "anthropic-claude-v1"}   // redacted_thinking
/// {"type": "reasoning.encrypted", "data": …, "id": …,        "format": "openai-responses-v1"}   // encrypted_content
/// ```
///
/// A `reasoning.summary` entry (chat completions on some routers) is carried as-is and never
/// needed by a translator.
public enum ReasoningDetails {
  /// `type` values.
  public enum EntryType {
    public static let text = "reasoning.text"
    public static let encrypted = "reasoning.encrypted"
    public static let summary = "reasoning.summary"
  }

  /// `format` values — which dialect can replay the entry.
  public enum Format {
    public static let anthropic = "anthropic-claude-v1"
    public static let openaiResponses = "openai-responses-v1"
  }

  /// A signed thinking block. Anthropic only accepts a block with its signature, so an entry
  /// is never built without one (`MessagesAccumulator` drops unsigned blocks instead).
  public static func text(_ text: String, signature: String, format: String) -> JSONValue {
    .object([
      "type": .string(EntryType.text),
      "text": .string(text),
      "signature": .string(signature),
      "format": .string(format),
    ])
  }

  /// An opaque block — `redacted_thinking` data or a Responses `encrypted_content` (with the
  /// item id the echo needs).
  public static func encrypted(data: String, id: String?, format: String) -> JSONValue {
    var entry: [String: JSONValue] = [
      "type": .string(EntryType.encrypted),
      "data": .string(data),
      "format": .string(format),
    ]
    if let id {
      entry["id"] = .string(id)
    }
    return .object(entry)
  }

  /// Whether the entry is one the given dialect format can replay.
  static func entry(_ value: JSONValue, hasFormat format: String) -> Bool {
    value["format"]?.stringValue == format
  }

  /// The same history with every `reasoningDetails` removed — what a request sends on a
  /// provider that may reject the field, and what a model swap leaves behind (a signed block
  /// is bound to the model that produced it). Never mutates the input.
  public static func stripped(_ messages: [Message]) -> [Message] {
    messages.map { message in
      guard message.reasoningDetails != nil else { return message }
      var copy = message
      copy.reasoningDetails = nil
      return copy
    }
  }

  /// The chat-completions stream delivers `reasoning_details` as fragments: entries sharing an
  /// `index` (or an `id`) are one block whose `text`/`summary`/`data` arrive in pieces and whose
  /// `signature` lands on the last one. Folds them back into whole entries, in index order.
  struct FragmentMerger {
    private struct Partial {
      var order: Int
      var entry: [String: JSONValue]
    }

    private var partialsByKey: [String: Partial] = [:]
    private var nextOrder = 0

    /// Whole entries in the order their first fragment arrived (index order on the wire).
    var entries: [JSONValue] {
      partialsByKey.values.sorted { $0.order < $1.order }.map { .object($0.entry) }
    }

    mutating func ingest(_ fragment: JSONValue) {
      guard let object = fragment.objectValue else { return }
      let key: String
      if let index = object["index"]?.intValue {
        key = "index:\(index)"
      } else if let id = object["id"]?.stringValue {
        key = "id:\(id)"
      } else {
        // Nothing to place it by: keep it whole, in arrival order.
        key = "anonymous:\(nextOrder)"
      }
      var partial = partialsByKey[key] ?? Partial(order: nextOrder, entry: [:])
      if partialsByKey[key] == nil {
        nextOrder += 1
      }
      for (field, value) in object {
        switch field {
        case "text", "summary", "data":
          // Streamed content concatenates across fragments.
          if let piece = value.stringValue {
            partial.entry[field] = .string((partial.entry[field]?.stringValue ?? "") + piece)
          } else if partial.entry[field] == nil {
            partial.entry[field] = value
          }
        default:
          // `signature`, `id`, `format`, `type`, `index`, …: the last non-null wins.
          if case .null = value { continue }
          partial.entry[field] = value
        }
      }
      partialsByKey[key] = partial
    }
  }
}
