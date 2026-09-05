import Foundation
import OpenRouterSwift

// MARK: - MessagesTranslator

/// Chat-shaped history → Anthropic Messages request pieces. History stays canonical in
/// the chat dialect; translation happens per request, which is what keeps mid-session
/// `/model` swaps working across dialects.
enum MessagesTranslator {

  /// Anthropic requires `max_tokens`; this is a generous ceiling, not a target — the
  /// manifest's `max_completion_tokens` caps it when the model states one (`outputPlan`).
  static let maxOutputTokens = 8192

  /// The smallest thinking budget worth sending, and the headroom `max_tokens` keeps above the
  /// budget when a manifest ceiling forces a clamp (Anthropic requires `max_tokens > budget_tokens`).
  static let minimumThinkingBudget = 1024

  /// `max_tokens` and the thinking budget for one request, under the manifest's ceiling.
  /// No ceiling → exactly the pre-manifest numbers (8192, or budget + 8192 with thinking on); a
  /// ceiling caps `max_tokens`, and the budget is then clamped to `max_tokens − 1024` — never
  /// below 1024 — so the request stays valid instead of asking for more than the model serves.
  /// A ceiling too small for the minimum budget *plus* that headroom (under 2048) yields
  /// `budget: nil`: thinking is off for that model, because the only budget that would fit is
  /// one Anthropic refuses (`budget_tokens ≥ max_tokens`) — and would refuse every turn.
  /// Invariant: whenever `budget` is non-nil, `budget < maxTokens`.
  static func outputPlan(maxCompletionTokens: Int?, thinkingBudget: Int?) -> (maxTokens: Int, budget: Int?) {
    guard let thinkingBudget else {
      let want = maxOutputTokens
      return (maxCompletionTokens.map { min($0, want) } ?? want, nil)
    }
    let want = thinkingBudget + maxOutputTokens
    let maxTokens = maxCompletionTokens.map { min($0, want) } ?? want
    let room = maxTokens - minimumThinkingBudget
    // Under 2048 `maxTokens` is the ceiling itself (below both `want` and the default), so the
    // thinking-off plan is the same cap with no budget.
    guard room >= minimumThinkingBudget else { return (maxTokens, nil) }
    return (maxTokens, min(thinkingBudget, room))
  }

  /// **The thinking rule.** With thinking enabled, Anthropic requires the final assistant
  /// message's `tool_use` blocks to be preceded by a `thinking`/`redacted_thinking` block; a
  /// history whose last assistant message calls tools without one — a pre-R1 transcript resumed
  /// with `--effort`, a step that ran on chat after a fallback, a synthetic background delivery,
  /// an unsigned block that was dropped — is a 400 whatever the translator does. So the request
  /// disables thinking for that step instead of sending one it knows is invalid. Note the reach:
  /// a step that ran without thinking produces a tool-call turn with no thinking block of its
  /// own, so the next step is disabled by the same rule, and so on — thinking is off for **the
  /// rest of that turn's tool steps** and back with the next user message (a text finish carries
  /// no `tool_use`, so the rule is satisfied again). A turn's tail without thinking beats a
  /// failure that would pin the model to chat. Pure, over the chat-shaped history.
  static func canEnableThinking(history messages: [Message]) -> Bool {
    guard let last = messages.last(where: { $0.role == .assistant }) else { return true }
    guard let calls = last.toolCalls, !calls.isEmpty else { return true }
    return !thinkingBlocks(for: last).isEmpty
  }

  /// The replayable Anthropic blocks an assistant message carries, in entry order: one
  /// `thinking` per signed `reasoning.text`, one `redacted_thinking` per `reasoning.encrypted`,
  /// every other format skipped (a block signed by another dialect is not Anthropic's).
  static func thinkingBlocks(for message: Message) -> [AnthropicContentBlock] {
    (message.reasoningDetails ?? []).compactMap { entry in
      guard ReasoningDetails.entry(entry, hasFormat: ReasoningDetails.Format.anthropic) else { return nil }
      switch entry["type"]?.stringValue {
      case ReasoningDetails.EntryType.text:
        guard let text = entry["text"]?.stringValue,
              let signature = entry["signature"]?.stringValue, !signature.isEmpty
        else { return nil }
        return .thinking(text, signature: signature)
      case ReasoningDetails.EntryType.encrypted:
        guard let data = entry["data"]?.stringValue, !data.isEmpty else { return nil }
        return .redactedThinking(data: data)
      default:
        return nil
      }
    }
  }

  /// - Parameter thinkingEnabled: whether this request enables thinking. Only then are the
  ///   assistant messages' thinking blocks replayed (first, before text and `tool_use`, on every
  ///   message that has them — Anthropic strips older turns' blocks itself); a request without
  ///   thinking must not carry thinking blocks, so the default renders exactly the pre-R1 shape.
  /// - Parameter breakpointOnLast: a prompt-cache breakpoint for the last content block of the
  ///   last message (`withBreakpointOnLast`) — the moving breakpoint of `CachePolicy`. nil (the
  ///   default) renders exactly the shape without one.
  static func history(
    _ messages: [Message],
    thinkingEnabled: Bool = false,
    breakpointOnLast: CacheControl? = nil)
    -> [AnthropicMessage]
  {
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
        // An attachment (a `view_image` result's image) that follows tool results rides the
        // user message carrying them — the canonical shape — instead of a second user turn.
        if !pendingToolResults.isEmpty, case .parts? = message.content {
          pendingToolResults.append(contentsOf: userBlocks(message))
          continue
        }
        flushToolResults()
        result.append(userMessage(message))
      case .assistant:
        flushToolResults()
        var blocks: [AnthropicContentBlock] = []
        if thinkingEnabled {
          blocks.append(contentsOf: thinkingBlocks(for: message))
        }
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
    guard let breakpointOnLast else { return result }
    return withBreakpointOnLast(result, breakpointOnLast)
  }

  /// A copy of `messages` whose **last content block of the last message** carries `control`
  /// — the moving prompt-cache breakpoint: each step reads the prefix the previous step cached
  /// and writes its own. A text (or image/document) block takes the field directly; a
  /// `tool_result` block — the usual last block in an agent loop, a tool step's answer — is
  /// re-rendered through `.other` with the same keys plus `cache_control` (Anthropic accepts a
  /// breakpoint on a `tool_result`; the package's typed case has no slot for it). A plain-text
  /// message becomes one text block carrying it (the same content, block-shaped). A last block
  /// that cannot take a breakpoint (`tool_use`, a thinking block — never the last message of a
  /// request the session builds — or an opaque `.other`) is left as it is: a missing breakpoint
  /// costs money, a wrong one risks a 400. Empty in, empty out.
  static func withBreakpointOnLast(_ messages: [AnthropicMessage], _ control: CacheControl) -> [AnthropicMessage] {
    guard var last = messages.last else { return messages }
    switch last.content {
    case .text(let text):
      last.content = .blocks([.text(text, cacheControl: control)])
    case .blocks(var blocks):
      guard let block = blocks.last, let marked = marking(block, with: control) else { return messages }
      blocks[blocks.count - 1] = marked
      last.content = .blocks(blocks)
    }
    var result = messages
    result[result.count - 1] = last
    return result
  }

  /// A user message as Anthropic wants it: plain text stays a text message; a message of content
  /// parts (a `view_image` attachment — T5) becomes blocks, its `data:` image URL an
  /// `imageBase64` block and any other image URL an `imageURL` one, text parts text. Parts the
  /// wire has no block for (audio, files) are dropped, as `plainText` drops them.
  static func userMessage(_ message: Message) -> AnthropicMessage {
    guard case .parts? = message.content else {
      return .user(message.content?.plainText ?? "")
    }
    let blocks = userBlocks(message)
    return blocks.isEmpty
      ? .user(message.content?.plainText ?? "")
      : AnthropicMessage(role: .user, content: .blocks(blocks))
  }

  /// The blocks of a `.parts` user message (empty for a plain-text one).
  static func userBlocks(_ message: Message) -> [AnthropicContentBlock] {
    guard case .parts(let parts)? = message.content else { return [] }
    var blocks: [AnthropicContentBlock] = []
    for part in parts {
      switch part {
      case .text(let text, _):
        blocks.append(.text(text))
      case .imageURL(let url, _, _):
        if let image = DataURL.parse(url) {
          blocks.append(.imageBase64(mediaType: image.mediaType, data: image.base64))
        } else {
          blocks.append(.imageURL(url))
        }
      default:
        continue
      }
    }
    return blocks
  }

  /// `block` carrying `control`, or nil when the block's kind cannot take a breakpoint.
  static func marking(_ block: AnthropicContentBlock, with control: CacheControl) -> AnthropicContentBlock? {
    switch block {
    case .text(let text, _):
      return .text(text, cacheControl: control)
    case .imageBase64(let mediaType, let data, _):
      return .imageBase64(mediaType: mediaType, data: data, cacheControl: control)
    case .imageURL(let url, _):
      return .imageURL(url, cacheControl: control)
    case .documentURL(let url, let title, _):
      return .documentURL(url, title: title, cacheControl: control)
    case .documentBase64(let mediaType, let data, let title, _):
      return .documentBase64(mediaType: mediaType, data: data, title: title, cacheControl: control)
    case .toolResult(let toolUseId, let content, let isError):
      // The typed case has no `cache_control` slot: the same wire shape, rendered verbatim.
      var object: [String: JSONValue] = [
        "type": .string("tool_result"),
        "tool_use_id": .string(toolUseId),
        "content": .string(content),
        "cache_control": cacheControlValue(control),
      ]
      if let isError {
        object["is_error"] = .bool(isError)
      }
      return .other(.object(object))
    case .toolUse, .thinking, .redactedThinking, .other:
      return nil
    }
  }

  /// `CacheControl` as the `JSONValue` an `.other` block embeds.
  static func cacheControlValue(_ control: CacheControl) -> JSONValue {
    var object: [String: JSONValue] = ["type": .string(control.type)]
    if let ttl = control.ttl {
      object["ttl"] = .string(ttl)
    }
    return .object(object)
  }

  static func tool(_ tool: any AgentTool) -> AnthropicTool {
    .custom(name: tool.name, inputSchema: tool.parameters, description: tool.description)
  }

  /// Every tool in definition order, the **last** one carrying `breakpointOnLast` when given —
  /// Anthropic caches tools ahead of the system text, so a breakpoint on the last definition
  /// caches the whole toolset as one prefix. nil renders exactly `tools.map(tool)`.
  static func tools(_ tools: [any AgentTool], breakpointOnLast control: CacheControl?) -> [AnthropicTool] {
    var result = tools.map(tool)
    guard let control, let last = tools.last else { return result }
    result[result.count - 1] = .custom(
      name: last.name, inputSchema: last.parameters, description: last.description, cacheControl: control)
    return result
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
  /// The request's whole input: Anthropic's `input_tokens` **plus** its cache figures —
  /// `input_tokens` alone excludes what was read from or written to the prompt cache, so a
  /// cached step would otherwise read as a few hundred tokens of context and the compaction
  /// threshold (`lastPromptTokens`) would never trip. Exactly `input_tokens` when the usage
  /// carries no cache figure (the pre-C7 number).
  private(set) var promptTokens: Int?
  private(set) var completionTokens: Int?
  /// `cache_read_input_tokens`: prompt tokens served from the cache (a subset of
  /// `promptTokens`); nil when the usage carries none.
  private(set) var cachedPromptTokens: Int?
  /// `cache_creation_input_tokens`: prompt tokens written to the cache this request (billed as
  /// a write, not a hit); nil when the usage carries none.
  private(set) var cacheCreationTokens: Int?

  private struct PartialToolUse {
    var id: String
    var name: String
    var argumentsJSON: String
  }

  private var toolUsesByIndex: [Int: PartialToolUse] = [:]

  /// A thinking block under construction, by content-block index like the tool uses: the
  /// text streams in `thinking_delta`s and the signature lands last in a `signature_delta`;
  /// a `redacted_thinking` block arrives whole on its `content_block_start`.
  private enum PartialThinking {
    case thinking(text: String, signature: String?)
    case redacted(data: String)
  }

  private var thinkingByIndex: [Int: PartialThinking] = [:]

  /// The step's replayable reasoning state, in block order: one `reasoning.text` per *signed*
  /// thinking block, one `reasoning.encrypted` per redacted block, `format` Anthropic's. A
  /// thinking block that ended without a signature cannot be replayed (Anthropic refuses an
  /// unsigned block) and is dropped — counted in `unsignedThinkingBlocks`.
  var reasoningDetails: [JSONValue] {
    thinkingByIndex.sorted { $0.key < $1.key }.compactMap { _, partial in
      switch partial {
      case .thinking(let text, let signature):
        guard let signature, !signature.isEmpty else { return nil }
        return ReasoningDetails.text(text, signature: signature, format: ReasoningDetails.Format.anthropic)
      case .redacted(let data):
        return ReasoningDetails.encrypted(data: data, id: nil, format: ReasoningDetails.Format.anthropic)
      }
    }
  }

  /// Thinking blocks the stream closed without a signature — not replayable, so not carried.
  var unsignedThinkingBlocks: Int {
    thinkingByIndex.values.filter {
      if case .thinking(_, let signature) = $0 { return signature?.isEmpty ?? true }
      return false
    }.count
  }

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
      readUsage(message["usage"])
    case .contentBlockStart(let index, let block):
      switch block["type"]?.stringValue {
      case "tool_use":
        toolUsesByIndex[index] = PartialToolUse(
          id: block["id"]?.stringValue ?? "",
          name: block["name"]?.stringValue ?? "",
          argumentsJSON: "")
      case "thinking":
        thinkingByIndex[index] = .thinking(text: block["thinking"]?.stringValue ?? "", signature: nil)
      case "redacted_thinking":
        if let data = block["data"]?.stringValue, !data.isEmpty {
          thinkingByIndex[index] = .redacted(data: data)
        }
      default:
        break
      }
    case .contentBlockDelta(let index, let delta):
      switch delta {
      case .textDelta(let piece):
        text += piece
        deltas.text = piece
      case .thinkingDelta(let piece):
        reasoning += piece
        deltas.reasoning = piece
        if case .thinking(let soFar, let signature) = thinkingByIndex[index] {
          thinkingByIndex[index] = .thinking(text: soFar + piece, signature: signature)
        }
      case .signatureDelta(let piece):
        if case .thinking(let soFar, let signature) = thinkingByIndex[index] {
          thinkingByIndex[index] = .thinking(text: soFar, signature: (signature ?? "") + piece)
        }
      case .inputJSONDelta(let partialJSON):
        toolUsesByIndex[index]?.argumentsJSON += partialJSON
      case .other:
        break
      }
    case .messageDelta(let delta, let usage):
      if let stop = delta["stop_reason"]?.stringValue {
        stopReason = stop
      }
      if let value = usage?["cost"]?.doubleValue {
        cost = value
      }
      readUsage(usage)
    case .contentBlockStop, .messageStop, .ping, .other:
      break
    }
    return deltas
  }

  /// The token counts of one usage object — `message_start`'s or `message_delta`'s, the same
  /// keys in both. `input_tokens` is only the uncached part of the input, so the cache figures
  /// are folded into `promptTokens` when the usage carries any; each figure is read only when
  /// present, so a later usage that repeats fewer keys never clears an earlier one.
  private mutating func readUsage(_ usage: JSONValue?) {
    guard let usage else { return }
    if let read = usage["cache_read_input_tokens"]?.intValue {
      cachedPromptTokens = read
    }
    if let written = usage["cache_creation_input_tokens"]?.intValue {
      cacheCreationTokens = written
    }
    if let input = usage["input_tokens"]?.intValue {
      promptTokens = input + (cachedPromptTokens ?? 0) + (cacheCreationTokens ?? 0)
    }
    if let output = usage["output_tokens"]?.intValue {
      completionTokens = output
    }
  }
}
