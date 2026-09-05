import Foundation
import OpenRouterSwift

// MARK: - HookOutcome

/// What the hooks for one lifecycle point decided, merged across every matching hook.
///
/// The contract is Claude Code's, so hook scripts port unchanged:
/// - **exit 0** with a JSON object on stdout carries the decision
///   (`hookSpecificOutput.permissionDecision` allow|deny|ask, `permissionDecisionReason`,
///   `updatedInput`, `additionalContext`; `hookSpecificOutput.decision.behavior` allow|deny|ask
///   on PermissionRequest — or the bare string `hookSpecificOutput.decision: "deny"`; legacy
///   top-level `decision: "block"` (`"deny"` reads the same) + `reason`;
///   `continue`/`stopReason`/`systemMessage`). Plain text on exit 0 is just output — except
///   on `UserPromptSubmit`, `SessionStart` and `PreCompact`, where it is **context** for the
///   model (`additionalContext`), as in Claude Code.
/// - **exit 2** blocks on the gating events (PreToolUse blocks the call, SubagentStart the
///   spawn, UserPromptSubmit the turn, PreCompact a manual compaction, PermissionRequest the
///   call), means "don't stop yet" on `Stop`, and is fed back to the model on the
///   after-the-fact ones (PostToolUse, PostToolUseFailure, SubagentStop) or surfaced
///   (SessionEnd, PostCompact); the output is the reason.
/// - **any other non-zero exit** is a non-blocking error shown to the user — unless the hook
///   is `failClosed`, in which case it denies (gating events only).
///
/// A hook may **narrow but never widen** the deterministic layer: `allow` lifts only the
/// ordinary-mutation prompt (never `.sensitive`, a deny rule, plan mode or the catastrophic
/// floor), `updatedInput` is re-classified before it runs, and `deny > ask > allow > none`
/// when several hooks answer.
public struct HookOutcome: Sendable, Equatable {
  public enum Decision: Sendable, Equatable {
    /// No opinion — the permission layer decides as usual.
    case none
    /// Skip the permission prompt for an ordinary mutation (never a `.sensitive` call).
    case allow
    /// Force a prompt, even where a rule, mode or session grant would auto-approve.
    case ask(reason: String?)
    /// Refuse the call; the reason goes back to the model.
    case deny(reason: String)

    /// Strictness order for merging: deny > ask > allow > none.
    var rank: Int {
      switch self {
      case .none: return 0
      case .allow: return 1
      case .ask: return 2
      case .deny: return 3
      }
    }
  }

  public var decision: Decision
  /// Replacement arguments for the call (`updatedInput`); nil leaves them as the model sent them.
  public var updatedInput: [String: JSONValue]?
  /// Extra context for the model, appended to the tool result as `[hook context]`.
  public var additionalContext: [String]
  /// Messages for the *user* (`systemMessage`), surfaced as notices, never fed to the model.
  public var systemMessages: [String]
  /// `continue: false` — the turn should end after this call, with `stopReason` as the why.
  public var continueRun: Bool
  public var stopReason: String?
  /// Hook output to feed back to the model (PostToolUse) or surface (Stop): plain stdout, an
  /// exit-2 reason, a PostToolUse `decision: "block"` reason. Joined, unprefixed.
  public var feedback: String
  /// Runner problems that did not block — a hook failed to start, timed out, or exited with
  /// a non-2 status without `failClosed`. Surfaced to the user, never silently swallowed.
  public var errors: [String]
  /// What reaching this outcome cost in USD — a prompt hook's request, a paying handler's;
  /// 0 for shell hooks and cached replies. Informational (summed by `merge`): the books are
  /// kept by `HookEngine.drainAccruedCostUSD`, so a caller reads one or the other, not both.
  public var costUSD: Double

  public init(
    decision: Decision = .none,
    updatedInput: [String: JSONValue]? = nil,
    additionalContext: [String] = [],
    systemMessages: [String] = [],
    continueRun: Bool = true,
    stopReason: String? = nil,
    feedback: String = "",
    errors: [String] = [],
    costUSD: Double = 0)
  {
    self.decision = decision
    self.updatedInput = updatedInput
    self.additionalContext = additionalContext
    self.systemMessages = systemMessages
    self.continueRun = continueRun
    self.stopReason = stopReason
    self.feedback = feedback
    self.errors = errors
    self.costUSD = costUSD
  }

  public static let none = HookOutcome()

  /// The deny reason, when the decision is a deny.
  public var blockReason: String? {
    if case .deny(let reason) = decision { return reason }
    return nil
  }

  /// The model-facing context this outcome carries: `additionalContext` entries, in order.
  /// On `UserPromptSubmit`, `SessionStart` and `PreCompact` plain stdout lands here too.
  public var context: [String] { additionalContext }

  /// The user-facing lines of this outcome — runner errors and `systemMessage`s, plus the
  /// plain output when `includeFeedback` (the advisory events: SessionEnd, PostCompact) —
  /// tagged with the event, for callers outside a turn's event stream (`Session.start`,
  /// `Session.end`, a manual `/compact`) to print the way the loop yields `.hookNotice`.
  public func notices(for event: HookEvent, includeFeedback: Bool = false) -> [HookNotice] {
    var lines = errors + systemMessages
    if includeFeedback, !feedback.isEmpty { lines.append(feedback) }
    return lines.map { HookNotice(event: event.rawValue, output: $0) }
  }

  // MARK: Parsing

  /// One hook's exit status + combined output → its outcome, per the contract above.
  public static func parse(exit: Int32, output: String, event: HookEvent) -> HookOutcome {
    let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
    switch exit {
    case 0:
      if trimmed.hasPrefix("{"),
         let json = try? JSONDecoder().decode(HookJSON.self, from: Data(trimmed.utf8))
      {
        return fromJSON(json, event: event)
      }
      // Plain text (or JSON that doesn't parse — treated as text, never as a decision): on
      // the context events it is context for the model; an after-the-fact hook's output is
      // feedback; any other gating hook's stdout is nothing.
      var outcome = HookOutcome()
      if !trimmed.isEmpty {
        if event.stdoutIsContext {
          outcome.additionalContext = [trimmed]
        } else if !event.isGate {
          outcome.feedback = trimmed
        }
      }
      return outcome
    case 2:
      // Before the fact (the gates) exit 2 refuses, and on Stop it refuses the *stop*; after
      // the fact (PostToolUse, SubagentStop, …) the thing already happened, so the reason
      // is fed back.
      guard event.canBlock else { return HookOutcome(feedback: trimmed) }
      return HookOutcome(decision: .deny(reason: trimmed.isEmpty ? Self.defaultBlockReason(event) : trimmed))
    default:
      let detail = trimmed.isEmpty ? "" : ": \(String(trimmed.prefix(300)))"
      return HookOutcome(errors: ["exited \(exit)\(detail)"])
    }
  }

  /// What a silent refusal says when the hook printed nothing. On `Stop` the reason is the
  /// model's next instruction, so it has to read as one.
  static func defaultBlockReason(_ event: HookEvent) -> String {
    switch event {
    case .stop: return "a Stop hook says the task is not finished yet — continue working on it"
    default: return "blocked by a \(event.rawValue) hook"
    }
  }

  static func fromJSON(_ json: HookJSON, event: HookEvent) -> HookOutcome {
    var outcome = HookOutcome()
    let specific = json.hookSpecificOutput
    switch event {
    case .preToolUse, .subagentStart, .permissionRequest:
      // PermissionRequest's own spelling is `decision: {behavior, message}`; the PreToolUse
      // spelling is accepted on it too, since that is the mistake everyone makes.
      let verdict = specific?.decision?.behavior ?? specific?.permissionDecision
      let why = specific?.decision?.message ?? specific?.permissionDecisionReason ?? json.reason
      switch verdict?.lowercased() {
      case "allow":
        outcome.decision = .allow
      case "deny":
        outcome.decision = .deny(reason: why ?? defaultBlockReason(event))
      case "ask":
        outcome.decision = .ask(reason: why)
      default:
        // Legacy top-level spelling.
        switch json.decision?.lowercased() {
        case "block", "deny": outcome.decision = .deny(reason: json.reason ?? defaultBlockReason(event))
        case "approve", "allow": outcome.decision = .allow
        default: break
        }
      }
      if case .object(let object) = specific?.updatedInput ?? specific?.decision?.updatedInput ?? .null {
        outcome.updatedInput = object
      }
    case .userPromptSubmit, .preCompact, .stop:
      // Claude Code's spelling for these is the top-level `decision: "block"` + `reason`;
      // a `permissionDecision: deny` is read the same way. On Stop the block means "keep
      // going" and the reason is what the model is told.
      let blocked = json.decision?.lowercased() == "block" || json.decision?.lowercased() == "deny"
        || specific?.permissionDecision?.lowercased() == "deny"
      if blocked {
        let reason = json.reason ?? specific?.permissionDecisionReason
        outcome.decision = .deny(reason: reason.flatMap { $0.isEmpty ? nil : $0 } ?? defaultBlockReason(event))
      }
    case .postToolUse, .postToolUseFailure, .subagentStop:
      // `block` after the fact means "tell the model why" — the reason rides the feedback.
      if json.decision?.lowercased() == "block", let reason = json.reason, !reason.isEmpty {
        outcome.feedback = reason
      }
    case .sessionStart, .sessionEnd, .postCompact, .notification:
      // Nothing to decide; `reason` on a `block` is surfaced like any other output.
      if json.decision?.lowercased() == "block", let reason = json.reason, !reason.isEmpty {
        outcome.feedback = reason
      }
    }
    if let context = specific?.additionalContext, !context.isEmpty {
      outcome.additionalContext.append(context)
    }
    if let message = json.systemMessage, !message.isEmpty {
      outcome.systemMessages.append(message)
    }
    if json.continueRun == false {
      outcome.continueRun = false
      outcome.stopReason = json.stopReason
    }
    return outcome
  }

  /// This outcome with everything *widening* removed — what a **project** hook is allowed to
  /// say. It can deny, ask, feed text back and end the turn; its `allow` becomes no opinion
  /// and its `updatedInput` is dropped, so a cloned repo can neither pre-approve a call nor
  /// rewrite the arguments of one. Narrow-only in code, not in documentation.
  public func narrowedToRefusals() -> HookOutcome {
    var narrowed = self
    if case .allow = decision { narrowed.decision = .none }
    narrowed.updatedInput = nil
    return narrowed
  }

  /// Folds another hook's outcome into this one: the stricter decision wins, contexts and
  /// messages concatenate, a later `updatedInput` replaces an earlier one, any hook asking
  /// to stop stops, and spend adds up.
  mutating func merge(_ other: HookOutcome) {
    costUSD += other.costUSD
    if other.decision.rank > decision.rank { decision = other.decision }
    if let input = other.updatedInput { updatedInput = input }
    additionalContext += other.additionalContext
    systemMessages += other.systemMessages
    if !other.continueRun {
      continueRun = false
      stopReason = stopReason ?? other.stopReason
    }
    if !other.feedback.isEmpty {
      feedback = feedback.isEmpty ? other.feedback : feedback + "\n" + other.feedback
    }
    errors += other.errors
  }
}

// MARK: - HookJSON

/// The stdout JSON a hook may print (Claude Code field names, verbatim).
struct HookJSON: Decodable {
  var continueRun: Bool?
  var stopReason: String?
  var systemMessage: String?
  var decision: String?
  var reason: String?
  var hookSpecificOutput: Specific?

  struct Specific: Decodable {
    var hookEventName: String?
    var permissionDecision: String?
    var permissionDecisionReason: String?
    var updatedInput: JSONValue?
    var additionalContext: String?
    /// PermissionRequest: `{"behavior": "allow"|"deny", "message": …, "updatedInput": …}` —
    /// or the bare string (`"decision": "deny"`), which is read as the behavior alone.
    var decision: Decision?

    struct Decision: Decodable {
      var behavior: String?
      var message: String?
      var updatedInput: JSONValue?

      enum CodingKeys: String, CodingKey {
        case behavior, message, updatedInput
      }

      /// Either shape: a string is the behavior (`"deny"`, `"allow"`, `"ask"`), an object
      /// carries it under `behavior` with the optional message and rewrite. Anything else
      /// (a number, an array) fails the decode — and the whole reply is then text, never a
      /// decision, like any other malformed JSON.
      init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
          behavior = text
          return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        behavior = try container.decodeIfPresent(String.self, forKey: .behavior)
        message = try container.decodeIfPresent(String.self, forKey: .message)
        updatedInput = try container.decodeIfPresent(JSONValue.self, forKey: .updatedInput)
      }
    }
  }

  enum CodingKeys: String, CodingKey {
    case continueRun = "continue"
    case stopReason
    case systemMessage
    case decision
    case reason
    case hookSpecificOutput
  }
}

// MARK: - HookNotice

/// A hook's user-facing line outside a turn's event stream — what `Session.start`,
/// `Session.end` and a manual compaction hand back so the caller can print it the way the
/// loop yields `.hookNotice(event:output:)`.
public struct HookNotice: Sendable, Equatable {
  public let event: String
  public let output: String

  public init(event: String, output: String) {
    self.event = event
    self.output = output
  }
}
