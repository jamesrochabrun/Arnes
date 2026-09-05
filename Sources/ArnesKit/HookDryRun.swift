import Foundation
import OpenRouterSwift

// MARK: - HookEngine.dryRun

/// `arnes hooks test`: run one event's hooks against a synthetic payload and report, **per
/// hook**, whether it applied (and which filter excluded it), what it printed, how it exited
/// and what the loop would have made of that. The hook commands really run — no tool does —
/// so a mistyped `when` path glob that silently disables a guardrail shows up as
/// `skipped (when: path)` instead of being discovered when the guardrail fails to fire.
extension HookEngine {
  /// One hook's row in a dry run.
  public struct DryRunReport: Sendable, Equatable {
    /// Why a hook sat the call out. The order is the engine's (`applies`): a disabled hook is
    /// never matched, a matcher miss is reported before an `agent` or `when` miss.
    public enum Skip: String, Sendable, Equatable {
      /// `enabled: false`.
      case disabled
      /// The `matcher` didn't accept the subject (tool name, agent name, source, …).
      case matcher
      /// The `agent` filter didn't accept the agent the event is about.
      case agent
      /// Some `when` entry didn't match the arguments — `failedWhenKeys` names them.
      case when
      /// A `type: prompt` hook: a dry run spends no model request, so it is listed, not asked.
      case prompt
    }

    public let hook: HookDefinition
    /// nil when the hook ran.
    public let skipped: Skip?
    /// The `when` keys that didn't match (or weren't in the arguments), when `skipped == .when`.
    public let failedWhenKeys: [String]
    /// The exit status, when the command ran to completion.
    public let exitCode: Int32?
    /// Combined stdout+stderr, clipped like a real run's.
    public let output: String
    /// What the loop would have made of the run — parsed per the decision contract, a
    /// project hook's `allow`/`updatedInput` already dropped, a `failClosed` runner failure
    /// already a deny. nil when the hook was skipped.
    public let outcome: HookOutcome?
    /// The runner failure (failed to start, timed out), when the command couldn't run.
    public let failure: String?

    /// Whether a real run would execute this hook: it ran here, or it is a prompt hook the dry
    /// run listed instead of asking a model.
    public var applied: Bool { skipped == nil || skipped == .prompt }
  }

  /// The session id every dry-run payload carries, so a hook can tell a test from a run.
  public static let dryRunSessionId = "hooks-test"

  /// Runs every configured hook for `event` that applies to a synthetic call, one at a time
  /// and **without** short-circuiting on a deny — a dry run wants to show every hook's
  /// answer, not the merged verdict. `subject` is what the event's matcher is tested against
  /// (`HookEvent.matcherSubject`: a tool name, an agent name, a source/reason/trigger/type);
  /// for `UserPromptSubmit` it is the prompt text and for `Stop` it is ignored. nil takes the
  /// event's default (`defaultDryRunSubject`) — which the matcher then sees too, so a hook
  /// with `matcher: resume` is reported skipped for a `SessionStart` test that named no
  /// source, exactly as `sessionStart(source: "startup")` would skip it.
  /// `argumentsJSON` is the tool input for the tool events.
  public func dryRun(
    event: HookEvent,
    subject: String?,
    argumentsJSON: String? = nil)
    async -> [DryRunReport]
  {
    // Whatever this engine was built with, a dry run identifies itself: `session_id` in the
    // payload and `ARNES_SESSION_ID` in the environment are `dryRunSessionId`.
    let engine = HookEngine(
      hooks: hooks, handlers: handlers, promptRunner: promptRunner, cwd: cwd,
      environment: environment, sessionId: Self.dryRunSessionId, agent: agent)
    // One effective subject for both the payload and the matcher test — the real engine's
    // entry points always pass the same value to both.
    let subject = subject ?? engine.defaultDryRunSubject(for: event)
    let payload = engine.dryRunPayload(event: event, subject: subject, argumentsJSON: argumentsJSON)
    // Stop and UserPromptSubmit have no matcher subject: the engine ignores `matcher` there.
    let matched: String? = event.matcherSubject == nil ? nil : subject
    var reports: [DryRunReport] = []
    for hook in hooks where hook.event == event {
      if let skip = engine.skipReason(hook, subject: matched, payload: payload) {
        reports.append(DryRunReport(
          hook: hook, skipped: skip.reason, failedWhenKeys: skip.failedWhenKeys,
          exitCode: nil, output: "", outcome: nil, failure: nil))
        continue
      }
      // A prompt hook would spend a model request to answer; a dry run reports that it applies
      // and stops there — the point is to see which hooks fire, not to bill a judge.
      if hook.type == .prompt {
        reports.append(DryRunReport(
          hook: hook, skipped: .prompt, failedWhenKeys: [],
          exitCode: nil, output: "", outcome: nil, failure: nil))
        continue
      }
      switch await engine.run(hook, payload: payload) {
      case .exited(let code, let output):
        var parsed = HookOutcome.parse(exit: code, output: output, event: event)
        if !parsed.errors.isEmpty, hook.failClosed == true, event.isGate {
          parsed = HookOutcome(decision: .deny(reason: "blocked: \(parsed.errors.joined(separator: "; ")) (hook is failClosed)"))
        }
        if hook.source == .project { parsed = parsed.narrowedToRefusals() }
        reports.append(DryRunReport(
          hook: hook, skipped: nil, failedWhenKeys: [], exitCode: code, output: output,
          outcome: parsed, failure: nil))
      case .failed(let message):
        let outcome = hook.failClosed == true && event.isGate
          ? HookOutcome(decision: .deny(reason: "blocked: \(message) (hook is failClosed)"))
          : HookOutcome(errors: [message])
        reports.append(DryRunReport(
          hook: hook, skipped: nil, failedWhenKeys: [], exitCode: nil, output: "",
          outcome: hook.source == .project ? outcome.narrowedToRefusals() : outcome, failure: message))
      }
    }
    return reports
  }

  /// The engine's `applies` check, unrolled so the report can say *which* filter excluded a
  /// hook. Same primitives (`matches(subject:)`, `matchesAgent`, the `when` matcher), same
  /// order.
  func skipReason(
    _ hook: HookDefinition,
    subject: String?,
    payload: HookPayload)
    -> (reason: DryRunReport.Skip, failedWhenKeys: [String])?
  {
    guard hook.isEnabled else { return (.disabled, []) }
    if let subject, !hook.matches(subject: subject) { return (.matcher, []) }
    guard hook.matchesAgent(payload.agentType ?? payload.agent) else { return (.agent, []) }
    let failed = hook.failingWhenKeys(arguments: payload.whenArguments, root: cwd)
    return failed.isEmpty ? nil : (.when, failed)
  }

  /// The subject a dry run uses when the caller named none — what the engine's own entry
  /// points pass in the common case: this engine's agent (or `general`) for the delegation
  /// pair, `startup`/`exit`/`manual`/`permission_prompt` for the session events. The tool
  /// events have no default (a tool event needs its tool — the CLI refuses one without), and
  /// neither do `Stop` and `UserPromptSubmit` (no matcher subject; an absent prompt is empty).
  func defaultDryRunSubject(for event: HookEvent) -> String? {
    switch event {
    case .subagentStart, .subagentStop: return agent ?? "general"
    case .sessionStart: return Session.StartSource.startup.rawValue
    case .sessionEnd: return Session.EndReason.exit.rawValue
    case .preCompact, .postCompact: return "manual"
    case .notification: return "permission_prompt"
    case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .stop, .userPromptSubmit:
      return nil
    }
  }

  /// The synthetic payload for a dry run: identity from the engine (`session_id` is
  /// `dryRunSessionId`), the event's own fields filled from `subject`/`argumentsJSON` (a nil
  /// subject takes `defaultDryRunSubject`), and placeholder text where a real run would carry
  /// a tool's output or a subagent's report.
  func dryRunPayload(event: HookEvent, subject: String?, argumentsJSON: String?) -> HookPayload {
    let placeholder = "(dry run — no tool ran)"
    let subject = subject ?? defaultDryRunSubject(for: event)
    switch event {
    case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest:
      var payload = payload(
        for: event, tool: subject, argumentsJSON: argumentsJSON ?? "{}",
        toolUseId: Self.dryRunSessionId, response: event == .postToolUse ? placeholder : nil,
        turnIndex: 0)
      if event == .postToolUseFailure { payload.error = "error: \(placeholder)" }
      if event == .permissionRequest { payload.permissionTier = "mutating" }
      return payload
    case .stop:
      return payload(for: .stop, tool: nil, argumentsJSON: nil, toolUseId: nil, response: nil, turnIndex: 0)
    case .subagentStart, .subagentStop:
      return subagentPayload(
        for: event, agent: subject ?? "general", id: Self.dryRunSessionId, model: placeholder, task: placeholder,
        report: event == .subagentStop ? placeholder : nil,
        steps: event == .subagentStop ? 0 : nil,
        toolCalls: event == .subagentStop ? 0 : nil,
        costUSD: event == .subagentStop ? 0 : nil,
        partial: event == .subagentStop ? false : nil)
    case .userPromptSubmit:
      var payload = sessionPayload(for: event)
      payload.prompt = subject ?? ""
      payload.turnIndex = 0
      return payload
    case .sessionStart:
      var payload = sessionPayload(for: event)
      payload.source = subject
      return payload
    case .sessionEnd:
      var payload = sessionPayload(for: event)
      payload.reason = subject
      return payload
    case .preCompact, .postCompact:
      var payload = sessionPayload(for: event)
      payload.trigger = subject
      payload.turnIndex = 0
      return payload
    case .notification:
      var payload = sessionPayload(for: event)
      payload.notificationType = subject
      payload.message = placeholder
      return payload
    }
  }
}

// MARK: - HookDefinition.failingWhenKeys

extension HookDefinition {
  /// The `when` keys this call's arguments don't satisfy — empty means the hook applies.
  /// The per-key twin of `matches(arguments:root:)`, built on the same primitives (a glob for
  /// `pathArgumentKeys`, an unanchored regex otherwise; a missing or non-scalar argument never
  /// matches, an `edits` element's does), so the dry run can name the entry that disabled a guardrail.
  func failingWhenKeys(arguments: JSONValue?, root: URL?) -> [String] {
    guard let when, !when.isEmpty else { return [] }
    guard case .object(let object) = arguments ?? .null else { return when.keys.sorted() }
    return when.keys.sorted().filter { key in
      !Self.whenMatches(
        key: key, pattern: when[key] ?? "", texts: Self.matchTexts(for: key, in: object), root: root)
    }
  }
}
