import Foundation
import OpenRouterSwift

// MARK: - CachePolicy

/// Prompt-cache discipline for a session's requests (C7). The system prompt and the tool
/// definitions are a stable prefix every step of a turn re-sends; on the Anthropic family that
/// prefix is billed again on every step unless the request marks it with `cache_control`
/// breakpoints. This policy says whether the session marks it, and how long the entries live.
///
/// The stable prefix a cache keys on is `system + tools + the oldest kept history`, so the
/// breakpoints are applied **at request-build time on the view the request sends**
/// (`Session.requestHistory()`), never on a persisted message — a compaction's stubs must be
/// stable across the steps of a turn for the prefix to hold, and the history itself is never
/// mutated by a request.
///
/// The gate is three-fold and every leg must hold: this switch, the model's family
/// (`ModelProfile.family == .anthropic`, the manifest's word — a gateway alias like `sonnet`
/// resolves to the family too), and the provider's `ProviderTraits.supportsCacheControl` (a
/// generic OpenAI-compatible endpoint may reject the field). A request to any other model
/// carries no `cache_control` anywhere — byte-identical to a session without the policy.
public struct CachePolicy: Sendable, Equatable {
  /// Mark the stable prefix of every Anthropic-family request: the system text and the last
  /// history message on chat completions (a message-level breakpoint that moves with the
  /// growing conversation, so it caches incrementally), the last tool definition and the last
  /// content block on `/messages`. Two breakpoints of Anthropic's four.
  public var anthropicBreakpoints: Bool
  /// The entries' time to live where the provider supports one (`"5m"`, `"1h"`); nil = the
  /// provider's default. Rides `cache_control.ttl` verbatim.
  public var ttl: String?

  public init(anthropicBreakpoints: Bool = true, ttl: String? = nil) {
    self.anthropicBreakpoints = anthropicBreakpoints
    self.ttl = ttl
  }

  /// Breakpoints on for the Anthropic family, the provider's TTL — what every session runs
  /// with unless the CLI's `policies.promptCache` says otherwise.
  public static let `default` = CachePolicy()

  /// No breakpoint anywhere — the request shape from before C7, for A/Bs.
  public static let off = CachePolicy(anthropicBreakpoints: false)

  /// The breakpoint every marked block carries: `{"type": "ephemeral"[, "ttl": …]}`.
  public var cacheControl: CacheControl {
    CacheControl(type: "ephemeral", ttl: ttl)
  }
}

// MARK: - PromptCache

/// The pure request-shaping behind the chat-completions breakpoints — what `Session.chatStep`
/// hands `ChatCompletionRequest.messages`. Pure so the byte-identity of the unmarked shape and
/// the placement of the marked one are pinned without a session.
enum PromptCache {
  /// The `.retrying` reason for the one re-send after an endpoint refused the request's
  /// `cache_control` markers (`Session.streamStep`): breakpoints stay off for the session.
  static let refusalRetryReason =
    "cache_control refused by the endpoint — re-sent without prompt-cache breakpoints (off for the rest of this session)"

  /// The messages a chat request sends: the system text first, then the history. With no
  /// breakpoint this is exactly `[.system(text)] + history` — the shape every non-Anthropic
  /// request has always had. With one, the system message becomes a single text **part**
  /// carrying it (the shape OpenRouter documents for Anthropic caching — a breakpoint rides a
  /// content part, and system + tools cache as one prefix behind it) and the last history
  /// message carries a message-level breakpoint: the moving one, so each step reads the
  /// previous step's prefix and writes its own. A `.tool`-role last message takes it too — a
  /// tool-result turn is a valid breakpoint, and in an agent loop it is the usual last message.
  /// The history passed in is never mutated; an empty history marks nothing.
  static func chatMessages(system: String, history: [Message], breakpoint: CacheControl?) -> [Message] {
    guard let breakpoint else {
      return [.system(system)] + history
    }
    let systemMessage = Message(role: .system, content: .parts([.text(system, cacheControl: breakpoint)]))
    return [systemMessage] + markingLast(history, with: breakpoint)
  }

  /// A copy of `messages` whose last element carries `cacheControl` — the moving breakpoint.
  /// Empty in, empty out.
  static func markingLast(_ messages: [Message], with control: CacheControl) -> [Message] {
    guard !messages.isEmpty else { return messages }
    var marked = messages
    marked[marked.count - 1].cacheControl = control
    return marked
  }
}
