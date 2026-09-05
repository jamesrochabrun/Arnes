import Foundation
import OpenRouterSwift

// MARK: - PromptHookRunner

/// Executes `type: prompt` hooks: one chat request on a cheap model with a fixed system
/// prompt, the reply read leniently as a verdict, cached, timed out, and paid for on the
/// turn's books. `CommandJudge` is a client of the same request path, so the judge's spend
/// is finally counted too.
///
/// The rules are the command judge's, applied in code rather than in documentation:
/// - **Escalate-only.** A prompt hook may deny or ask; it can never `allow`, rewrite
///   arguments, or end the turn — the outcome goes through `narrowedToRefusals()` and
///   `continue: false` is dropped, whatever the model wrote. A model's opinion is advice on
///   top of the deterministic layers, never a key past them.
/// - **Fail-closed means "no opinion", never "allow".** A service error, a timeout, or a
///   reply that doesn't parse yields `.none` plus an `errors` entry naming the hook; the
///   deterministic decision (and any shell hook's deny) stands. `failClosed: true` on the
///   definition turns that into a deny on the gating events, exactly as for a command hook
///   that couldn't run.
/// - **Cached** by `(hook fingerprint, event, payload)` — with the per-call identity fields
///   (`tool_use_id`, `turn_index`) left out of the key, since they change on every call
///   without changing the question — so a model retrying the same command is judged once.
///   Only a **verdict** is remembered: a timeout, a router error, a cancelled turn or a reply
///   that didn't parse is not one, and caching it would refuse (`failClosed`) or wave past
///   (otherwise) that command for the rest of the session with the model perfectly reachable.
///   The next call asks again. Keys are hashed (a `PostToolUse` payload carries the whole tool
///   response) and the cache holds `cacheCapacity` entries, oldest out first.
///
/// Cost is `usage.cost` when the router reports it, else tokens × the model's manifest prices
/// through the catalog (nil catalog → only reported cost counts), accumulated until
/// `drainAccruedCostUSD()` — which `HookEngine.drainAccruedCostUSD` calls and the session
/// books after each executed tool call.
public actor PromptHookRunner {
  /// Why a request produced no reply text.
  public enum Failure: Sendable, Equatable {
    case timedOut(seconds: Int)
    case error(String)
    case emptyReply

    var description: String {
      switch self {
      case .timedOut(let seconds): return "timed out after \(seconds)s"
      case .error(let message): return "request failed: \(message)"
      case .emptyReply: return "the model returned no text"
      }
    }
  }

  /// A reply, or why there is none. Spend is booked either way.
  public enum Reply: Sendable, Equatable {
    case text(String)
    case failed(Failure)
  }

  private let service: any OpenRouterService
  private let catalog: ModelCatalog?
  /// The model a hook without `model` runs on — the provider's `bashJudge`. nil means such a
  /// hook is unusable and is skipped with a notice.
  public let defaultModel: String?
  /// Remembered verdicts by hashed key, plus their insertion order for eviction.
  private var cache: [String: HookOutcome] = [:]
  private var cacheOrder: [String] = []
  private var accruedCostUSD: Double = 0

  /// How many verdicts the cache keeps before the oldest is dropped. A long session with a
  /// `*`-matched hook asks about every distinct call; the answers must not grow without bound.
  static let cacheCapacity = 256

  /// - Parameters:
  ///   - catalog: resolves aliases and prices the request when the router reports no cost;
  ///     nil leaves aliases as written and counts only reported cost.
  ///   - defaultModel: the fallback for hooks that name none (the provider's `bashJudge`).
  public init(service: any OpenRouterService, catalog: ModelCatalog? = nil, defaultModel: String? = nil) {
    self.service = service
    self.catalog = catalog
    self.defaultModel = defaultModel
  }

  /// What a prompt hook's model is told before the hook's own prompt. Fixed: the format is
  /// the contract the parser reads, so it lives here rather than in a pack.
  static let systemPrompt = """
    You are a hook in a coding agent's harness: a guardrail that reviews ONE lifecycle event \
    and answers whether the agent may proceed. The event is described below as JSON \
    (hook_event_name, tool_name, tool_input, cwd, and so on). You cannot approve anything the \
    harness has not already approved — you can only object, or ask for a human to look.

    Reply with EXACTLY one line, one of:
      OK
      BLOCK: <short reason>
      ASK: <short reason>
    or a JSON object {"decision": "none" | "deny" | "ask", "reason": "<short reason>"}.
    Default to OK; say BLOCK or ASK only when you can name the problem.
    """

  /// USD accrued since the last drain; resets the accumulator.
  public func drainAccruedCostUSD() -> Double {
    defer { accruedCostUSD = 0 }
    return accruedCostUSD
  }

  // MARK: Prompt hooks

  /// Runs one prompt-type definition for `event`. Never throws; the result is already clamped
  /// to refusals, and anything that went wrong is in `errors`.
  public func run(_ hook: HookDefinition, event: HookEvent, payload: HookPayload) async -> HookOutcome {
    let label = "prompt hook `\(hook.label)`"
    guard hook.type == .prompt, let prompt = hook.prompt, !prompt.isEmpty else {
      return HookOutcome(errors: ["\(label) has no prompt"])
    }
    guard let requested = hook.model ?? defaultModel else {
      return HookOutcome(errors: [
        "\(label) skipped — no model: set \"model\" on the hook or `bashJudge` on the provider",
      ])
    }
    let model = catalog?.resolve(requested) ?? requested
    let payloadJSON = Self.payloadJSON(payload)
    let key = Self.cacheKey(hook: hook, event: event, payload: payload)
    if var cached = cache[key] {
      cached.costUSD = 0
      return cached
    }
    let user = prompt.contains("$ARGUMENTS")
      ? prompt.replacingOccurrences(of: "$ARGUMENTS", with: payloadJSON)
      : prompt + "\n\n" + payloadJSON
    let timeout = hook.timeoutSeconds ?? HookEngine.defaultTimeoutSeconds
    let (reply, cost) = await complete(model: model, system: Self.systemPrompt, user: user, timeoutSeconds: timeout)
    var outcome: HookOutcome
    // Only a verdict is worth remembering. A request that failed (timeout, router error, the
    // turn cancelled under it) or a reply that didn't parse says nothing about the call, and
    // caching it would make one blip the answer for the rest of the session.
    var isVerdict = false
    switch reply {
    case .failed(let failure):
      outcome = HookOutcome(errors: ["\(label) \(failure.description)"])
    case .text(let text):
      switch Self.parse(text) {
      case .none:
        outcome = HookOutcome()
        isVerdict = true
      case .deny(let reason):
        // The exit-2 contract: a refusal on the gates and on Stop, feedback after the fact.
        outcome = HookOutcome.parse(exit: 2, output: reason, event: event)
        isVerdict = true
      case .ask(let reason):
        if event.isGate {
          outcome = HookOutcome(decision: .ask(reason: reason))
        } else {
          // Nothing to ask about once the thing has happened; say so rather than sit silent.
          outcome = HookOutcome(errors: [
            "\(label) replied ASK on \(event.rawValue), where there is no prompt to force — ignored",
          ])
        }
        isVerdict = true
      case .unparseable:
        outcome = HookOutcome(errors: [
          "\(label) reply unusable: \(String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(120)))",
        ])
      }
    }
    outcome = Self.clamped(outcome)
    outcome.costUSD = cost
    if isVerdict { remember(outcome, forKey: key) }
    return outcome
  }

  /// `(hook fingerprint, event, payload minus the per-call ids)`, hashed — a payload can
  /// carry a whole tool response, and the key must not.
  static func cacheKey(hook: HookDefinition, event: HookEvent, payload: HookPayload) -> String {
    let material = [hook.fingerprint, event.rawValue, payloadJSON(stripped(payload))].joined(separator: "\u{0}")
    return HookHash.sha256Hex(Data(material.utf8))
  }

  /// Stores a verdict, dropping the oldest once the cache is full.
  private func remember(_ outcome: HookOutcome, forKey key: String) {
    if cache.updateValue(outcome, forKey: key) == nil {
      cacheOrder.append(key)
      while cacheOrder.count > Self.cacheCapacity {
        cache.removeValue(forKey: cacheOrder.removeFirst())
      }
    }
  }

  /// How many verdicts are currently remembered (for tests).
  var cachedVerdictCount: Int { cache.count }

  /// What a prompt hook is allowed to say: deny, ask, feedback, context — never allow,
  /// never `updatedInput`, never `continue: false`.
  static func clamped(_ outcome: HookOutcome) -> HookOutcome {
    var narrowed = outcome.narrowedToRefusals()
    narrowed.continueRun = true
    narrowed.stopReason = nil
    return narrowed
  }

  /// The model's line, read leniently.
  enum Verdict: Equatable {
    case none
    case deny(reason: String)
    case ask(reason: String?)
    case unparseable
  }

  static let defaultDenyReason = "blocked by a prompt hook"

  /// The spellings read as "no objection" — every one an approval, which is clamped to no
  /// opinion anyway — and as a refusal. Past tenses are here because small models write them;
  /// anything not on either list is unparseable, never a guess.
  static let approvingWords: Set<String> = [
    "OK", "OKAY", "SAFE", "NONE", "ALLOW", "ALLOWED", "APPROVE", "APPROVED", "PASS", "FINE", "PROCEED",
  ]
  static let refusingWords: Set<String> = [
    "BLOCK", "BLOCKED", "DENY", "DENIED", "RISKY", "REFUSE", "REFUSED", "REJECT", "REJECTED", "UNSAFE",
  ]

  /// `OK`/`SAFE`/`NONE`/`ALLOW`/`APPROVE` → none (an approval is clamped to no opinion),
  /// `BLOCK`/`DENY`/`RISKY` → deny with the text after the colon, `ASK` → ask (past tenses
  /// accepted); a JSON object with `decision` (or Claude Code's
  /// `hookSpecificOutput.permissionDecision`) reads the same way — a ```` ``` ````-fenced one
  /// included — and `updatedInput`/`continue` in it are ignored. Anything else is unparseable
  /// — never a guess.
  static func parse(_ reply: String) -> Verdict {
    let line = unfenced(reply)
    if line.hasPrefix("{"), let data = line.data(using: .utf8),
       let json = try? JSONDecoder().decode(ReplyJSON.self, from: data)
    {
      let decision = (json.decision ?? json.hookSpecificOutput?.permissionDecision ?? "").uppercased()
      let reason = json.reason ?? json.hookSpecificOutput?.permissionDecisionReason
      switch decision {
      case let word where refusingWords.contains(word):
        return .deny(reason: reason.flatMap { $0.isEmpty ? nil : $0 } ?? defaultDenyReason)
      case "ASK": return .ask(reason: reason)
      // No decision at all (`{"updatedInput": …}`, `{"continue": false}`) is no opinion too.
      case let word where approvingWords.contains(word) || word.isEmpty: return .none
      default: return .unparseable
      }
    }
    // Only the first line carries the verdict; a chatty model's explanation below it is
    // ignored rather than mistaken for one.
    let first = line.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? line
    let word = first.prefix { $0.isLetter }.uppercased()
    let rest = first.dropFirst(word.count).drop { $0 == ":" || $0 == " " || $0 == "-" }
      .trimmingCharacters(in: .whitespaces)
    if approvingWords.contains(word) { return .none }
    if refusingWords.contains(word) { return .deny(reason: rest.isEmpty ? defaultDenyReason : rest) }
    if word == "ASK" { return .ask(reason: rest.isEmpty ? nil : rest) }
    return .unparseable
  }

  /// The reply trimmed, with a surrounding Markdown code fence (```` ```json … ``` ````)
  /// removed — the one wrapper a model adds to a JSON answer without changing it.
  static func unfenced(_ reply: String) -> String {
    let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("```") else { return trimmed }
    var lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    lines.removeFirst()
    if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") { lines.removeLast() }
    return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// The JSON a prompt hook's model may answer with. `updatedInput` and `continue` are
  /// decoded only so the object parses; their values are never used.
  struct ReplyJSON: Decodable {
    var decision: String?
    var reason: String?
    var updatedInput: JSONValue?
    var continueRun: Bool?
    var hookSpecificOutput: Specific?

    struct Specific: Decodable {
      var permissionDecision: String?
      var permissionDecisionReason: String?
    }

    enum CodingKeys: String, CodingKey {
      case decision, reason, updatedInput, hookSpecificOutput
      case continueRun = "continue"
    }
  }

  /// The event as the model reads it: sorted keys, pretty-printed, the same object a
  /// command hook gets on stdin.
  static func payloadJSON(_ payload: HookPayload) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(payload) else { return "{}" }
    return String(decoding: data, as: UTF8.self)
  }

  /// The payload minus the fields that change on every call without changing the question.
  static func stripped(_ payload: HookPayload) -> HookPayload {
    var key = payload
    key.toolUseId = nil
    key.turnIndex = nil
    return key
  }

  // MARK: The shared request

  /// One chat completion on `model` — the path both prompt hooks and the command judge take.
  /// Raced against `timeoutSeconds`; the spend (reported cost, else the manifest estimate) is
  /// booked whatever the reply. Never throws.
  public func complete(
    model: String,
    system: String,
    user: String,
    timeoutSeconds: Int)
    async -> (reply: Reply, costUSD: Double)
  {
    let service = self.service
    let request = ChatCompletionRequest(model: model, messages: [.system(system), .user(user)])
    let response: ChatCompletionResponse
    do {
      response = try await withThrowingTaskGroup(of: ChatCompletionResponse.self) { group in
        group.addTask { try await service.chatCompletion(request) }
        group.addTask {
          try await Task.sleep(nanoseconds: UInt64(max(1, timeoutSeconds)) * 1_000_000_000)
          throw TimeoutError()
        }
        // The first to finish decides; the other is cancelled.
        guard let first = try await group.next() else { throw TimeoutError() }
        group.cancelAll()
        return first
      }
    } catch is TimeoutError {
      return (.failed(.timedOut(seconds: timeoutSeconds)), 0)
    } catch {
      return (.failed(.error("\(error)")), 0)
    }
    let cost = await book(response.usage, model: model)
    guard let text = response.choices.first?.message.content,
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      return (.failed(.emptyReply), cost)
    }
    return (.text(text), cost)
  }

  private struct TimeoutError: Error {}

  /// Adds a request's spend to the accumulator and returns it: `usage.cost` when reported,
  /// else tokens × the manifest's prices for `model` (0 when neither is known).
  private func book(_ usage: Usage?, model: String) async -> Double {
    guard let usage else { return 0 }
    var cost = usage.cost
    if cost == nil, let catalog {
      let profile = try? await catalog.profile(for: model)
      cost = Session.estimatedCost(
        promptTokens: usage.promptTokens, completionTokens: usage.completionTokens, profile: profile)
    }
    let spent = cost ?? 0
    accruedCostUSD += spent
    return spent
  }
}
