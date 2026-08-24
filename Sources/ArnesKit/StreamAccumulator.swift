import Foundation
import OpenRouterSwift

/// Folds a stream of `ChatCompletionChunk`s into a complete assistant step: full text,
/// merged tool calls, usage (arrives on the final chunk), and routing metadata.
///
/// Tool-call fragments are merged keyed on `index`: the first fragment for an index
/// carries `id` and `function.name`, later fragments append to `function.arguments`.
/// Pure and synchronous so it can be unit-tested with hand-built chunks.
struct StreamAccumulator {
  /// The new increments from one chunk, for immediate emission to the caller.
  struct Deltas {
    var text: String?
    var reasoning: String?
  }

  private(set) var text = ""
  private(set) var reasoning = ""
  private(set) var usage: Usage?
  private(set) var routedModel: String?
  private(set) var provider: String?
  private(set) var finishReason: String?
  private var toolCallsByIndex: [Int: ToolCall] = [:]

  /// Merged tool calls in index order.
  var toolCalls: [ToolCall] {
    toolCallsByIndex.sorted { $0.key < $1.key }.map(\.value)
  }

  mutating func ingest(_ chunk: ChatCompletionChunk) -> Deltas {
    var deltas = Deltas()
    if let model = chunk.model {
      routedModel = model
    }
    if let chunkProvider = chunk.provider {
      provider = chunkProvider
    }
    if let chunkUsage = chunk.usage {
      usage = chunkUsage
    }
    guard let choice = chunk.choices?.first else {
      return deltas
    }
    if let finish = choice.finishReason {
      finishReason = finish
    }
    guard let delta = choice.delta else {
      return deltas
    }
    if let content = delta.content, !content.isEmpty {
      text += content
      deltas.text = content
    }
    if let reasoningDelta = delta.reasoning, !reasoningDelta.isEmpty {
      reasoning += reasoningDelta
      deltas.reasoning = reasoningDelta
    }
    for fragment in delta.toolCalls ?? [] {
      merge(fragment)
    }
    return deltas
  }

  private mutating func merge(_ fragment: ToolCall) {
    let key: Int
    if let index = fragment.index {
      key = index
    } else if fragment.id != nil || toolCallsByIndex.isEmpty {
      // No index but a fresh id (or nothing yet): treat as a new call.
      key = toolCallsByIndex.count
    } else {
      // No index and no id: a continuation of the most recent call.
      key = toolCallsByIndex.keys.max() ?? 0
    }

    var merged = toolCallsByIndex[key] ?? ToolCall(id: nil, type: nil, index: key, function: nil)
    if let id = fragment.id {
      merged.id = id
    }
    if let type = fragment.type {
      merged.type = type
    }
    var function = merged.function ?? ToolCall.Function(name: nil, arguments: nil)
    if let name = fragment.function?.name, function.name == nil {
      function.name = name
    }
    if let argumentsFragment = fragment.function?.arguments {
      function.arguments = (function.arguments ?? "") + argumentsFragment
    }
    merged.function = function
    toolCallsByIndex[key] = merged
  }
}
