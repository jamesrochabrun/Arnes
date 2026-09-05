import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - EchoTool

/// The probe's only tool: proves a native tool round-trip works end to end —
/// definition accepted, call streamed, arguments parsed, result fed back.
private final class EchoTool: AgentTool, @unchecked Sendable {
  let name = "echo"
  let description = "Echo the given text back. Call this exactly once."
  let permission = ToolPermission.readOnly
  let parameters: JSONValue = [
    "type": "object",
    "properties": ["text": ["type": "string", "description": "Text to echo"]],
    "required": ["text"],
  ]

  private let lock = NSLock()
  private(set) var echoed: [String] = []

  func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let text = arguments["text"]?.stringValue else {
      return "error: missing 'text'"
    }
    lock.withLock { echoed.append(text) }
    return text
  }
}

// MARK: - probe

struct Probe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check a model's native-dialect conformance with one tiny tool round-trip.",
    discussion: """
      Sends one cheap request on the model's native dialect and verifies the tool call
      arrives structurally intact (definition → call → parsed arguments → result). The
      verdict is recorded in ~/.arnes/dialects.jsonl, where auto dialect selection reads
      it. Agent runs also record verdicts optimistically, so probing is optional — this
      command exists to check a model before relying on it, or to retest after a failure.
      --dialect chat probes the floor itself (a gateway's chat completions, the reasoning
      dial in the provider's spelling) and records no verdict.
      """)

  @Argument(help: "Model slug (e.g. anthropic/claude-haiku-4.5).")
  var model: String

  @Option(help: ArgumentHelp(
    "Dialect to probe (messages, responses or chat; default: the model family's native dialect).",
    discussion: """
      chat is the universal floor auto dialect selection falls back to and never consults a
      verdict for, so `--dialect chat` runs the same echo round-trip on the forced chat
      dialect and records nothing — the check that a gateway takes the request as this
      provider spells it (with --effort: the reasoning dial in the provider's reasoningShape).
      """))
  var dialect: String?

  @Option(help: ArgumentHelp(
    "Reasoning effort for the probe (minimal, low, medium, high, xhigh, max, none).",
    discussion: """
      Enables thinking on the probe session so the two-step echo loop also exercises the
      reasoning round-trip: step 1 thinks and calls echo, step 2 must replay the signed
      thinking block (/messages) or the encrypted reasoning item (/responses). Ignored,
      like a session ignores it, for a model whose manifest doesn't list reasoning.
      """))
  var effort: String?

  @OptionGroup var providerOptions: ProviderOptions

  func validate() throws {
    _ = try parseEffort(effort)
  }

  func run() async throws {
    let reasoningEffort = try parseEffort(effort)
    let runtime = try ArnesRuntime.make(providerOptions)
    let service = runtime.service
    let catalog = runtime.catalog
    // An alias (`haiku`) resolves here as it does for `do -m`: the native endpoint sees the id.
    let model = runtime.provider.resolveAlias(model)
    let profile = try await catalog.profile(for: model)
    let target: Dialect
    if let dialect {
      guard let forced = Dialect(rawValue: dialect) else {
        throw ValidationError("probe a dialect: messages, responses or chat")
      }
      // A forced chat probe is the one way to run the floor: the default never picks it.
      target = forced
    } else {
      target = profile.dialect
      guard target != .chat else {
        print("\(model) prefers the chat dialect — nothing to probe.")
        return
      }
    }

    let echo = EchoTool()
    let store = DialectVerdictStore()
    let session = Session(
      service: service,
      tools: [echo],
      store: RunRecordStore(),
      dialectStore: store,
      catalog: catalog,
      configuration: .init(
        model: model,
        maxStepsPerTurn: 4,
        // Forced, so a broken endpoint fails loudly here instead of falling back.
        dialect: DialectOverride(rawValue: target.rawValue) ?? .auto,
        reasoningEffort: reasoningEffort,
        provider: runtime.traits))

    // The dial applies only where a session would apply it: a model whose manifest lists
    // reasoning. Elsewhere nothing is sent and the probe is the plain tool round-trip.
    // Spelled out: against an optional, a bare `.none` is `Optional.none`, not the dial's `none`.
    let thinking = (reasoningEffort.map { $0 != Reasoning.Effort.none } ?? false) && profile.supportsReasoning
    print("probing \(model) on /\(target.rawValue)\(thinking ? " with thinking (effort \(effort ?? ""))" : "") …")
    var failure: String?
    var thrown: (any Error)?
    do {
      for try await event in await session.send(
        "Call the echo tool exactly once with the text \"ping\", then reply with one word: done.")
      {
        if case .toolCall(let name, _) = event {
          print("→ \(name) call streamed")
        }
      }
    } catch {
      failure = "\(error)"
      thrown = error
    }

    let record = await session.lastRecord
    let echoedPing = echo.echoed.contains { $0.contains("ping") }
    let conformant = failure == nil && record?.finished == true && echoedPing
    let reason = failure
      ?? (echoedPing ? "loop did not finish" : "tool call missing or arguments unparsed")
    let category = conformant ? nil : Self.verdictCategory(thrown: thrown, text: reason, model: model)
    // Chat is the floor `DialectVerdictStore.isKnownBad` never consults: a verdict for it would
    // be a row nothing reads, so a chat probe records nothing and says so.
    if target != .chat {
      store.record(model: model, dialect: target, ok: conformant, reason: conformant ? nil : reason, category: category)
    }
    let note = target == .chat
      ? Self.chatReasoningNote(thinking: thinking, shape: runtime.traits.reasoningShape, record: record)
      : Self.reasoningNote(thinking: thinking, target: target, record: record)

    if conformant {
      let cost = record.map { String(format: "$%.4f", $0.costUSD) } ?? "?"
      print("✔ conformant — tool round-trip intact on /\(target.rawValue)\(note) (\(cost)); \(target == .chat ? Self.chatFloorNote : "recorded ok")")
    } else {
      print(TerminalText.sanitize("✘ not conformant on /\(target.rawValue): \(String(reason.prefix(200)))\(Self.categoryNote(category))"))
      print(target == .chat ? "  \(Self.chatFloorNote)" : Self.recordedLine(category))
      throw ExitCode.failure
    }
  }

  /// What a chat probe says where a native one says `recorded`: chat is the floor `.auto` falls
  /// back to and `DialectVerdictStore.isKnownBad` never consults, so nothing is written.
  static let chatFloorNote = "chat is the universal floor — nothing recorded"

  /// The chat probe's reasoning note: how the dial rode the request — the provider's
  /// `reasoningShape` (`reasoning_effort` for LiteLLM/OpenAI-compatible, OpenRouter's
  /// `reasoning` object, or not at all under `none`) — plus `reasoning_details replayed` only
  /// when the provider replays them (`RunRecord.reasoningReplayed`; OpenRouter does, a gateway
  /// strips them). Nothing when thinking was off, like `reasoningNote`.
  static func chatReasoningNote(thinking: Bool, shape: ReasoningShape, record: RunRecord?) -> String {
    guard thinking else { return "" }
    let sent: String
    switch shape {
    case .openai: sent = "dial sent as reasoning_effort"
    case .openrouter: sent = "dial sent as the reasoning object"
    case .none: sent = "dial not sent — reasoningShape none"
    }
    let replay = (record?.reasoningReplayed ?? 0) > 0 ? ", reasoning_details replayed" : ""
    return " (\(sent)\(replay))"
  }

  /// What the success line says about the reasoning round-trip: nothing when thinking was off;
  /// `(thinking replayed)` / `(encrypted reasoning replayed)` only when a request actually sent a
  /// block back (`RunRecord.reasoningReplayed`); when the model returned reasoning the second
  /// step never replayed (`reasoningBlocks` set, nothing replayed) the line says so instead of
  /// claiming a round-trip; and a plain note when the model returned none at all.
  static func reasoningNote(thinking: Bool, target: Dialect, record: RunRecord?) -> String {
    guard thinking else { return "" }
    if (record?.reasoningReplayed ?? 0) > 0 {
      return target == .messages ? " (thinking replayed)" : " (encrypted reasoning replayed)"
    }
    if (record?.reasoningBlocks ?? 0) > 0 {
      return " (reasoning returned but not replayed — the second step sent no block)"
    }
    return " (no reasoning blocks returned)"
  }

  /// The category the probe records for a failed run. A transport failure the session surfaced
  /// — exhausted retries, an idle stream, or a retryable error thrown bare — is `transport`: the
  /// wire's, not the dialect's, so it cools the route for minutes instead of pinning it for a
  /// week (a 429 storm during a probe used to pin the model to chat for 7 days). Anything else
  /// is the failure text's own classification: `thinking`, `cache_control`, or the endpoint's nil.
  static func verdictCategory(thrown: (any Error)?, text: String, model: String) -> String? {
    if let thrown, thrown is TransportError || TransportPolicy.retryReason(for: thrown) != nil {
      return DialectVerdict.transportCategory
    }
    return DialectVerdict.category(forFailure: text, model: model)
  }

  /// The failure line's tail for a categorized verdict.
  static func categoryNote(_ category: String?) -> String {
    switch category {
    case DialectVerdict.thinkingCategory:
      return " (category: thinking — not pinned; the endpoint is fine, the request was not)"
    case DialectVerdict.cacheControlCategory:
      return " (category: cache_control — not pinned; the endpoint refused the request's prompt-cache markers, not the dialect)"
    case DialectVerdict.transportCategory:
      return " (category: transport — the wire failed, not the dialect)"
    default:
      return ""
    }
  }

  /// What the verdict does to auto dialect selection, said under the failure line.
  static func recordedLine(_ category: String?) -> String {
    switch category {
    case DialectVerdict.thinkingCategory:
      return "  recorded — a thinking failure never pins the model; auto dialect selection is unchanged"
    case DialectVerdict.cacheControlCategory:
      return "  recorded — a cache_control refusal never pins the model; auto dialect selection is unchanged (set policies.promptCache.anthropicBreakpoints: false if it repeats)"
    case DialectVerdict.transportCategory:
      let minutes = Int(DialectVerdictStore.defaultTransportCooldown / 60)
      return "  recorded — auto dialect selection uses chat for this model for the next \(minutes) minutes only, then tries the native dialect again; probe again once the wire is healthy"
    default:
      return "  recorded — auto dialect selection will use chat for this model"
    }
  }
}
