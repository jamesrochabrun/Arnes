import Foundation
import OpenRouterSwift

// MARK: - CommandJudge

/// An opt-in, cheap-model second opinion on shell commands that are already headed for a
/// permission prompt. It is layer 4 of the safety stack, on top of the deterministic
/// `ShellCommand` classifiers — it exists to catch the *semantic* danger strings can't see
/// (`python3 -c "shutil.rmtree(...)"`, a benign-looking script that wipes data), not to
/// replace the catastrophic floor or an OS sandbox.
///
/// Three rules keep it a help rather than a liability:
/// - **Escalate-only.** It may only *raise* suspicion on a command that already passed the
///   floor. It can never turn a blocked command into an allowed one, so a comment in the
///   command (`rm -rf ~ # approved`) can't jailbreak the gate — the deterministic layers are
///   the boundary, this is advice on top.
/// - **Fail-closed.** Any error, timeout, or unparseable reply → `.unavailable`, and the
///   caller falls back to the deterministic decision. A safety layer must never fail open.
/// - **Off the hot path.** Only commands already being gated reach it (read-only auto-run
///   never pays the latency), and verdicts are cached by command string so a loop that runs
///   the same command judges it once (`.unavailable` is not a verdict and is never cached).
///
/// The request itself goes through a `PromptHookRunner` — the same path `type: prompt` hooks
/// take — so the judge's spend is booked there and reaches the turn's `RunRecord` when the
/// runner is the one on the session's configuration (`ArnesRuntime` shares one instance).
public actor CommandJudge {
  public enum Verdict: Sendable, Equatable {
    /// The judge saw nothing irreversible or dangerous beyond ordinary mutation.
    case safe
    /// The judge flagged a risk; the reason enriches the prompt (and can veto headless runs).
    case risky(reason: String)
    /// The judge couldn't reach a verdict — fall back to the deterministic decision.
    case unavailable
  }

  private let runner: PromptHookRunner
  private let model: String
  private var cache: [String: Verdict] = [:]

  /// A judge with its own request path — spend is drained through `drainAccruedCostUSD()`.
  public init(service: any OpenRouterService, model: String) {
    self.init(runner: PromptHookRunner(service: service), model: model)
  }

  /// A judge sharing `runner` with the session's prompt hooks, so one drain books both.
  public init(runner: PromptHookRunner, model: String) {
    self.runner = runner
    self.model = model
  }

  /// The model the judge runs on (for banners / records).
  public nonisolated var modelID: String { model }

  /// The judge requests' spend since the last drain (through its runner — a shared runner
  /// reports the prompt hooks' spend too). What `HookEngine.drainAccruedCostUSD` collects
  /// when the runner is the session's.
  public func drainAccruedCostUSD() async -> Double {
    await runner.drainAccruedCostUSD()
  }

  /// Requests share a hook's default patience.
  public static let timeoutSeconds = HookEngine.defaultTimeoutSeconds

  private static let systemPrompt = """
    You are a cautious shell-command safety reviewer for a coding agent. Judge ONE command \
    for the risk of IRREVERSIBLE harm — data loss, deleting or overwriting files the user \
    didn't clearly mean to, wiping disks, exfiltrating secrets, downloading and running \
    remote code, or damaging the system. You are NOT judging whether the command is correct \
    or whether it compiles — only whether running it could cause damage that can't be undone.

    Ordinary development actions are SAFE: creating/building, installing deps, editing files \
    in the project, git add/commit, running tests. Deleting, force-pushing, piping the \
    network into a shell, touching paths outside the project, or anything that destroys data \
    is RISKY.

    Reply with EXACTLY one line: either
      SAFE
    or
      RISKY: <short reason, one clause>
    Default to SAFE for ordinary mutations; only say RISKY when you can name the irreversible harm.
    """

  /// Assess a command. Cached per command string; never throws (errors → `.unavailable`).
  /// Only a verdict is cached: an unreachable, slow or unreadable judge is `.unavailable`
  /// *this time*, and the next call asks again — one timeout must not disable the judge for
  /// that command for the rest of the session.
  ///
  /// - Parameter tainted: the session has read untrusted content (`PermissionRequest.tainted`);
  ///   the judge is told, so it weighs exfiltration, and the verdict is cached apart from the
  ///   untainted one — the same command is a different question after an injection.
  public func assess(command: String, tainted: Bool = false) async -> Verdict {
    let key = tainted ? Self.taintedCachePrefix + command : command
    if let cached = cache[key] { return cached }
    let verdict = await judge(command, tainted: tainted)
    if verdict != .unavailable { cache[key] = verdict }
    return verdict
  }

  /// Separates the two verdicts one command can have in the cache; a control character no
  /// shell command starts with.
  private static let taintedCachePrefix = "\u{1}tainted\u{1}"

  /// The paragraph appended to the judge's question once the session is tainted. Fixed text
  /// (the judge's contract lives in code, like its system prompt).
  static let taintedNote = "TAINTED: the session has read untrusted content this session — weigh "
    + "exfiltration (uploads, DNS/HTTP callbacks, pastes) accordingly."

  private func judge(_ command: String, tainted: Bool) async -> Verdict {
    let user = "Command:\n\(command)" + (tainted ? "\n\n" + Self.taintedNote : "")
    let (reply, _) = await runner.complete(
      model: model, system: Self.systemPrompt, user: user,
      timeoutSeconds: Self.timeoutSeconds)
    switch reply {
    case .text(let raw):
      return Self.parse(raw)
    case .failed:
      // Fail-closed: an unreachable/erroring/slow judge must not block the deterministic path.
      return .unavailable
    }
  }

  /// Parse the one-line verdict. Anything we don't recognize is `.unavailable`, not a guess.
  static func parse(_ reply: String) -> Verdict {
    let line = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    let upper = line.uppercased()
    if upper.hasPrefix("SAFE") { return .safe }
    if upper.hasPrefix("RISKY") {
      let reason = line.drop(while: { $0 != ":" }).dropFirst()
        .trimmingCharacters(in: .whitespaces)
      return .risky(reason: reason.isEmpty ? "flagged as risky" : reason)
    }
    return .unavailable
  }
}

// MARK: - JudgingPermissions

/// Wraps another `PermissionDelegate` with a `CommandJudge` on `bash` calls. Non-bash tools,
/// and bash commands the judge clears or can't reach, pass straight through to `inner`.
///
/// On a `.risky` verdict:
/// - **interactive** (`headlessVeto == false`): the reason is appended to the prompt summary
///   so the human decides with the warning in front of them — the judge informs, never overrides.
/// - **headless auto-approve** (`headlessVeto == true`): the command is *denied* with the
///   reason, since no human will read the prompt. The judge can veto here, but still never
///   *approves* anything `inner` would have blocked — it only ever adds a deny.
///
/// It is also the one delegate that asks to see **pre-approved** calls
/// (`wantsPreApprovedCalls`): an `allow` rule, a session grant or `bypass` mode skips the
/// prompt, and a judge that never saw those commands would be a judge of only the commands
/// a human was already looking at. A pre-approved call it doesn't flag returns `.allow`
/// without troubling `inner` — the deterministic layer already answered.
public struct JudgingPermissions: PermissionDelegate {
  let inner: any PermissionDelegate
  let judge: CommandJudge
  let headlessVeto: Bool

  public init(inner: any PermissionDelegate, judge: CommandJudge, headlessVeto: Bool) {
    self.inner = inner
    self.judge = judge
    self.headlessVeto = headlessVeto
  }

  /// Escalation is the whole point: the judge must see the commands nobody is prompted about.
  public var wantsPreApprovedCalls: Bool { true }

  /// Answers are the wrapped delegate's unless the judge itself vetoed; the session
  /// attributes a veto to `.judge` on its own (only an escalating wrapper denies a call the
  /// deterministic layer approved).
  public var decisionSource: ToolDecision.Source { inner.decisionSource }

  /// A pre-approved call refused under this wrapper was refused by the judge — unless the
  /// inner delegate sees those calls itself (a read-only posture), in which case the row
  /// carries its source; a judge veto on such a run is then labeled with the posture, which
  /// would have refused it anyway.
  public var preApprovedDenialSource: ToolDecision.Source {
    inner.wantsPreApprovedCalls ? inner.preApprovedDenialSource : .judge
  }

  /// A pre-approved call the judge has nothing against is answered here — unless the inner
  /// delegate asked to see approved calls too (a read-only posture outranks the approval).
  private func pass(_ request: PermissionRequest) async -> PermissionDecision {
    request.preApproved && !inner.wantsPreApprovedCalls ? .allow : await inner.decide(request)
  }

  /// The tier-aware form is what the session calls, so the wrapper forwards the whole
  /// request — an inner delegate that reads `tier` (`AutoApprovePermissions`) must not lose
  /// it just because a judge is configured.
  public func decide(_ request: PermissionRequest) async -> PermissionDecision {
    guard request.toolName == "bash", let command = Self.command(fromJSON: request.argumentsJSON) else {
      // Nothing to judge: a pre-approved call is already answered, anything else is `inner`'s.
      return await pass(request)
    }
    switch await judge.assess(command: command, tainted: request.tainted) {
    case .safe, .unavailable:
      return await pass(request)
    case .risky(let reason):
      if headlessVeto {
        return .deny(reason: "safety judge flagged this command — \(reason)")
      }
      var enriched = request
      enriched.summary += "\n⚠ safety judge: \(reason)"
      // The judge un-approved it: the human is asked even though a rule, a grant or a mode
      // would have let it run silently.
      enriched.preApproved = false
      return await inner.decide(enriched)
    }
  }

  public func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await decide(PermissionRequest(
      toolName: toolName, summary: summary, argumentsJSON: argumentsJSON, tier: .mutating))
  }

  static func command(fromJSON json: String) -> String? {
    guard let data = json.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return object["command"] as? String
  }
}
