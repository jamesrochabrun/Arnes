import Foundation

// MARK: - ToolPermission

/// How much a tool call needs the user's say-so. `.readOnly` calls run freely; anything
/// else goes through the session's `PermissionDelegate` first.
public enum ToolPermission: Sendable, Equatable {
  case readOnly
  case mutating
  /// Doesn't mutate, but the user should still see it: a read outside the run's working
  /// directory, or of a known credential location (`~/.ssh`, `~/.aws`, …). Gated exactly
  /// like a mutation — the prompt's summary says which it was.
  case sensitive
}

// MARK: - PermissionDecision

/// The answer to "may this tool run?".
public enum PermissionDecision: Sendable {
  case allow
  /// Allow, and stop asking for this tool for the rest of the session.
  case allowAlwaysThisSession
  /// Refuse; the reason is reported to the model as the tool result so it can adapt.
  case deny(reason: String?)
}

// MARK: - PermissionRequest

/// One "may this run?" question, with everything a delegate needs to answer it — including
/// the `tier`, which the three-argument form couldn't carry. Unattended delegates need it:
/// approving every `.mutating` call is what `--yes` means, approving a `.sensitive` one
/// (a write outside the working tree, a credential file, a shell startup file) is not.
public struct PermissionRequest: Sendable {
  public var toolName: String
  /// One-line description of this specific call, from the tool (plus any hook or judge
  /// note). Model-supplied text — sanitize before printing to a terminal.
  public var summary: String
  public var argumentsJSON: String
  /// The gate this call needs. `.readOnly` reaches a delegate only when a rule or a hook
  /// forced a prompt for it.
  public var tier: ToolPermission
  /// True when the deterministic layer already approved this call — an `allow` rule, a
  /// standing session grant, a hook `allow`, or `bypass`/`acceptEdits` — and the delegate
  /// is being *informed*, not asked. Only a delegate that sets `wantsPreApprovedCalls`
  /// sees these, and it must answer `.allow` unless it means to escalate (the safety judge
  /// is the one that does; it clears the flag before forwarding, so the human is asked).
  ///
  /// An `ask` rule or a hook `ask` clears it: those un-approve a call, and the prompt they
  /// demanded is a real question.
  public var preApproved: Bool
  /// True when the session has read untrusted content (a scanner flag, an untrusted MCP
  /// server's result) and this call acts on the world after it — a network-reaching `bash`
  /// command (escalated to `.sensitive` for the purpose) or a call that was `.sensitive`
  /// already. The `summary` then starts with `[after untrusted content from <source>: <reason>]`.
  /// An unattended delegate refuses such a call; an interactive one shows the prefix.
  public var tainted: Bool
  /// For a *plain out-of-tree read* (a `PathGatedReadTool` call gated only by location —
  /// never a credential or `paths.denyRead` path): the directory "always this session"
  /// would remember as a `Read(<dir>/**)` grant. The interactive prompt shows it so the
  /// user knows what `a` covers; nil for every other call, where `a` keeps its old meaning.
  public var grantScope: String?
  /// Optional presentation correlation, not a permission grant or a model instruction.
  public var toolActivityID: String?

  public init(
    toolName: String,
    summary: String,
    argumentsJSON: String,
    tier: ToolPermission,
    preApproved: Bool = false,
    tainted: Bool = false,
    grantScope: String? = nil,
    toolActivityID: String? = nil)
  {
    self.toolName = toolName
    self.summary = summary
    self.argumentsJSON = argumentsJSON
    self.tier = tier
    self.preApproved = preApproved
    self.tainted = tainted
    self.grantScope = grantScope
    self.toolActivityID = toolActivityID
  }

  /// The `[after untrusted content from …]` note the session prefixed to a tainted call's
  /// summary, when there is one — for a refusal that names the source.
  public var taintNote: String? {
    guard tainted, summary.hasPrefix("[after untrusted content"),
          let close = summary.firstIndex(of: "]")
    else { return nil }
    return String(summary[summary.index(after: summary.startIndex)..<close])
  }
}

// MARK: - PermissionDelegate

/// Decides whether a gated tool call may execute. The CLI implements this with an
/// interactive y/n/a prompt; headless callers use `AutoApprovePermissions` (`--yes`) or
/// `DenyMutationsPermissions` (the headless default, and `--safe`).
///
/// This is deliberately separate from `AgentEvent`: events are one-way notifications,
/// a permission check is a request that needs an answer.
///
/// `decide(_:)` is what the session calls; it is a protocol *requirement* with a default
/// implementation, so a delegate that only implements the legacy three-argument method
/// keeps working (the default forwards) while one that implements the tier-aware form is
/// dispatched dynamically through `any PermissionDelegate`.
public protocol PermissionDelegate: Sendable {
  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision
  /// Tier-aware entry point. Default: forward to the legacy method.
  func decide(_ request: PermissionRequest) async -> PermissionDecision
  /// Whether this delegate wants to see calls the deterministic layer already approved (an
  /// `allow` rule, a session grant, `bypass`/`acceptEdits`). Default false — an approved
  /// call executes without a round trip, exactly as before.
  ///
  /// Two delegates opt in, for opposite reasons: `JudgingPermissions` may *escalate* an approved
  /// `bash` command (it answers `.allow` unless the judge flags it — it is being informed, not
  /// asked), and `DenyMutationsPermissions` is a read-only posture that outranks every approval
  /// (it refuses). `preApprovedDenialSource` says which kind refused.
  var wantsPreApprovedCalls: Bool { get }
  /// Which audit `source` this delegate's answers are attributed to when the session
  /// records them. Default `.user` (a human at a prompt).
  var decisionSource: ToolDecision.Source { get }
  /// Which audit `source` a *refusal of a pre-approved call* is attributed to. Only a delegate
  /// that `wantsPreApprovedCalls` can refuse one: the escalating judge (`.judge`, the default)
  /// or a read-only posture that outranks every approval (`.mode`).
  var preApprovedDenialSource: ToolDecision.Source { get }
}

extension PermissionDelegate {
  public func decide(_ request: PermissionRequest) async -> PermissionDecision {
    await decide(
      toolName: request.toolName, summary: request.summary, argumentsJSON: request.argumentsJSON)
  }

  public var wantsPreApprovedCalls: Bool { false }
  public var decisionSource: ToolDecision.Source { .user }
  public var preApprovedDenialSource: ToolDecision.Source { .judge }
}

/// Approves ordinary work without asking — for unattended runs the user explicitly asked
/// for (`--yes`), evals in throwaway directories, panel candidates in their snapshots.
///
/// `.sensitive` file calls are *not* ordinary work: `--yes` means "don't ask me about the
/// task", not "you may read my `~/.ssh` or rewrite my `.zshrc`". Those are denied with a
/// reason that points at the real fix — `--add-dir <directory>` widens what a run counts as
/// inside, so a legitimate task that needs a sibling checkout says so up front.
public struct AutoApprovePermissions: PermissionDelegate {
  /// Refuse `.sensitive` calls from the path-gated tools. On by default.
  public let denySensitive: Bool

  public init(denySensitive: Bool = true) { self.denySensitive = denySensitive }

  /// The tools whose `.sensitive` tier means "this path is outside what the run was pointed
  /// at" — the class an unattended run must not silently approve. `view_image` reads a file
  /// under the same gate as `read_file`; `web_fetch`'s `.sensitive` is a host outside the
  /// configured allowlist (T5) — network egress an unattended run must not approve either, so
  /// `--yes` only ever fetches allowlisted hosts.
  ///
  /// Deliberately not here: `bash`, whose floor is the catastrophic classifier plus the
  /// optional `CommandJudge` veto (denying every `rm`/`git push` would break panels, evals
  /// and Terminal-Bench runs), and MCP tools, whose `.sensitive` tier comes from a server's
  /// own `destructiveHint` annotation rather than from a path escape.
  public static let pathGatedTools: Set<String> = [
    "read_file", "write_file", "edit_file", "grep", "glob", ViewImageTool.toolName, WebFetchTool.toolName,
  ]

  /// An unattended approval is `--yes`, not a person — the audit trail says so.
  public var decisionSource: ToolDecision.Source { .yes }

  public func decide(_ request: PermissionRequest) async -> PermissionDecision {
    // After untrusted content, a `.sensitive` call — a network command, an out-of-tree write, a
    // destructive command, an MCP tool the server flags — is refused for *every* tool: an
    // unattended run has no human to read the prompt that names what the session read.
    if request.tainted, request.tier == .sensitive {
      let what = request.taintNote ?? "after untrusted content"
      return .deny(reason:
        "this session read untrusted content (\(what)) — a network or out-of-tree action after it "
        + "needs a human; re-run interactively or split the task")
    }
    guard denySensitive, request.tier == .sensitive,
          Self.pathGatedTools.contains(request.toolName)
    else {
      return .allow
    }
    if request.toolName == WebFetchTool.toolName {
      return .deny(reason:
        "an unattended run fetches only hosts listed in web.allowedDomains (~/.arnes/config.json), and "
        + "this one is not (or is denied). Ask the user to add the domain there, or to run interactively.")
    }
    if request.grantScope != nil {
      return .deny(reason:
        "an unattended run reads freely inside the working directory only, and this path is "
        + "outside it. Stay inside the working directory, or ask the user to re-run with "
        + "--add-dir <directory> (or --permission-mode acceptEdits, which auto-approves plain "
        + "out-of-tree reads).")
    }
    return .deny(reason:
      "an unattended run approves ordinary work inside the working directory only, and this "
      + "path is outside it (or a credential, shell-startup, or protected location). Stay "
      + "inside the working directory, or ask the user to re-run with --add-dir <directory> "
      + "to include it.")
  }

  public func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    .allow
  }
}

// MARK: - SerializedPermissions

/// Serializes overlapping permission questions onto one delegate.
///
/// A step can now run several subagents at once, and each of them gates its own tool calls
/// against the *same* delegate as the lead. Two prompts racing for one terminal is not a
/// question a human can answer — the second would overwrite the first's status line and steal
/// its keypress — so every `decide` passes through a one-at-a-time gate here and the others
/// wait their turn.
///
/// Note that actor isolation *alone* would not do this: actors are reentrant, so the `await`
/// on the base delegate would let the next caller straight in. The queue below is the real
/// mutual exclusion; the actor only makes it thread-safe.
///
/// Wrap once, at the CLI, and hand the same instance to the `Session` and the `TaskTool` —
/// then lead prompts and nested prompts share the one queue. A stateful wrapper underneath
/// (the `bashJudge`'s cache) also stops being raced by construction.
///
/// The model's clarifying questions (`ask_user`) go through the **same** queue: give the
/// wrapper a `UserInputDelegate` and hand the wrapper itself to `ToolContext.userInput`, so a
/// question can never open while a y/n prompt from a concurrent subagent is waiting for its
/// key — both want the one terminal. Without one, every question is `NoUserInput`'s answer.
public actor SerializedPermissions: PermissionDelegate, UserInputDelegate {
  private let base: any PermissionDelegate
  private let userInput: any UserInputDelegate
  private var busy = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  public init(_ base: any PermissionDelegate, userInput: any UserInputDelegate = NoUserInput()) {
    self.base = base
    self.userInput = userInput
  }

  public func decide(_ request: PermissionRequest) async -> PermissionDecision {
    await enter()
    defer { leave() }
    return await base.decide(request)
  }

  public func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await enter()
    defer { leave() }
    return await base.decide(
      toolName: toolName, summary: summary, argumentsJSON: argumentsJSON)
  }

  public func answer(question: String, options: [String]) async -> UserAnswer {
    await enter()
    defer { leave() }
    return await userInput.answer(question: question, options: options)
  }

  /// Forwarded unchanged: what the wrapped delegate wants to see, and how its answers are
  /// attributed, are its own — this wrapper only decides *when* it is asked.
  public nonisolated var wantsPreApprovedCalls: Bool { base.wantsPreApprovedCalls }
  public nonisolated var decisionSource: ToolDecision.Source { base.decisionSource }
  public nonisolated var preApprovedDenialSource: ToolDecision.Source { base.preApprovedDenialSource }

  private func enter() async {
    guard busy else {
      busy = true
      return
    }
    await withCheckedContinuation { continuation in
      waiting.append(continuation)
    }
    // Resumed by `leave`, which hands the slot over rather than clearing `busy`.
  }

  private func leave() {
    guard !waiting.isEmpty else {
      busy = false
      return
    }
    waiting.removeFirst().resume()
  }
}

/// Denies every gated tool call — mutations and out-of-tree reads — telling the model
/// why, so it can finish with what it can do freely.
public struct DenyMutationsPermissions: PermissionDelegate {
  public let reason: String

  /// - Parameter reason: what the model is told; the default fits `--safe`. Headless
  ///   `arnes do` without `--yes` passes a hint about the flag instead.
  public init(reason: String = "mutating tools and reads outside the working directory are disabled (--safe mode)") {
    self.reason = reason
  }

  public func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    .deny(reason: reason)
  }

  /// A read-only posture is a floor, not a prompt: an allow rule, a session grant, a hook's
  /// `allow` or an auto-approving mode pre-approves a mutation for a session that *may* mutate —
  /// this one may not, so it asks to see those calls and refuses them too. (`--yes` is the one
  /// consent switch for a headless run; a `permissionMode: readOnly` subagent keeps its posture
  /// whatever the lead's hooks and rules would let through.)
  public var wantsPreApprovedCalls: Bool { true }

  /// Nobody is asked here: the run itself is read-only, which is a mode, not an answer.
  public var decisionSource: ToolDecision.Source { .mode }
  public var preApprovedDenialSource: ToolDecision.Source { .mode }
}

// MARK: - UserInputDelegate

/// What the human said when the model asked a question mid-turn — or why nobody could.
public enum UserAnswer: Sendable, Equatable {
  case text(String)
  /// No answer is coming: a headless run, a declined prompt, a timeout, a per-turn cap. The
  /// reason reaches the model, which is told to pick the most reasonable option and state the
  /// assumption in its summary.
  case unavailable(reason: String)
}

/// Answers a model's clarifying question. The seam the `ask_user` tool is built on: the REPL
/// binds a terminal prompt, headless runs bind `NoUserInput`, tests script answers. Injected
/// through `ToolContext.userInput`, so the Kit stays UI-free and a nested session inherits
/// whatever the lead was given. An answer is text the model reads — never a permission grant.
public protocol UserInputDelegate: Sendable {
  /// - Parameter options: up to a few short choices the model offered; empty for free text.
  func answer(question: String, options: [String]) async -> UserAnswer
}

/// The headless default: nobody is present, so every question is unavailable with a fixed
/// reason. `arnes do`, panels, evals and subagents run with this unless told otherwise.
public struct NoUserInput: UserInputDelegate {
  public let reason: String

  public init(reason: String = "no user is present in this headless run") {
    self.reason = reason
  }

  public func answer(question: String, options: [String]) async -> UserAnswer {
    .unavailable(reason: reason)
  }
}
