import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - HookEvent

/// Lifecycle points where a user-configured shell command can run. Deterministic guardrails
/// and reactions that must happen *every* time — the thing a prompt can only ask for.
public enum HookEvent: String, Codable, Sendable, CaseIterable {
  /// Before a tool executes — and before the permission prompt. Exit 2 (or JSON
  /// `permissionDecision: deny`) **blocks** the call with the output as the reason; `ask`
  /// forces a prompt; `allow` skips the prompt for an ordinary mutation; `updatedInput`
  /// rewrites the arguments. The "block this command / validate first" guardrail.
  case preToolUse = "PreToolUse"
  /// After a tool executed. Its output is appended to the tool result the model sees — a
  /// formatter, a linter, a test run reacting to an edit; `continue: false` ends the turn.
  case postToolUse = "PostToolUse"
  /// After a tool call **failed** — `execute` threw or the tool returned an `error:` result
  /// (never a permission, hook or floor refusal: nothing ran). Mutually exclusive with
  /// `PostToolUse`, which fires on success only. Output is fed back like `PostToolUse`.
  case postToolUseFailure = "PostToolUseFailure"
  /// When a turn finishes (the model stopped calling tools). Plain output is surfaced to the
  /// user; exit 2 or `decision: block` with a `reason` means **don't stop yet** — the reason
  /// becomes the model's next instruction and the turn continues (at most
  /// `Session.maxStopContinuations` times; `stop_hook_active` is true on a continued turn).
  case stop = "Stop"
  /// Before a subagent is spawned by the `task` tool, after its model resolved. Exit 2 (or
  /// JSON `permissionDecision: deny`) **blocks the delegation** — the lead gets the reason
  /// as the tool result and no nested request is made. The matcher is the *agent name*, so
  /// a guardrail can veto delegating to one agent without touching the others.
  case subagentStart = "SubagentStart"
  /// After a subagent's nested run, before its report goes back to the lead. Its output is
  /// appended to that report (like `PostToolUse`), so a reviewer/linter can post-process
  /// delegated work. The matcher is the agent name. Not the same as `Stop`: a subagent's
  /// turn end is not the user's.
  case subagentStop = "SubagentStop"
  /// Before the user's text is appended to history. Exit 2 or `decision: block` **blocks the
  /// prompt** — no request is sent and the text never enters history; plain stdout (or
  /// `additionalContext`) rides the user message as a trailing `[context]` block. No matcher
  /// subject; `when` may filter on `prompt`.
  case userPromptSubmit = "UserPromptSubmit"
  /// A session (re)starts: `Session.start(source:)`. The matcher is the **source** —
  /// `startup`, `resume`, `clear`, `compact`. Plain stdout and `additionalContext` are kept
  /// as system-prompt context for the rest of the session.
  case sessionStart = "SessionStart"
  /// A session ends: `Session.end(reason:)`. The matcher is the **reason** — `exit`,
  /// `clear`, `other`. Advisory, run under a short budget; output is surfaced.
  case sessionEnd = "SessionEnd"
  /// Before history is compacted, ahead of the summarizer request. The matcher is the
  /// **trigger** — `manual` (`/compact`) or `auto`. Exit 2 or `decision: block` cancels a
  /// manual compaction (an automatic one ignores it — the context is full either way);
  /// plain stdout is appended to the summarizer's instructions for that run.
  case preCompact = "PreCompact"
  /// After a compaction succeeded. Matcher is the trigger; output is surfaced.
  case postCompact = "PostCompact"
  /// Inside the permission gate, immediately before the human would be asked. The matcher is
  /// the tool name. `hookSpecificOutput.decision.behavior: deny` refuses the call; `allow`
  /// answers the prompt for an **ordinary mutation only** — never `.sensitive`, a deny rule,
  /// plan mode or the floor (the same narrowing as a PreToolUse `allow`).
  case permissionRequest = "PermissionRequest"
  /// The UI is about to show something that needs the user — fired by the CLI (`type` is the
  /// matcher, e.g. `permission_prompt`, `user_question`), never by the loop. Advisory; output is ignored.
  case notification = "Notification"

  /// Whether a refusal from this event's hooks *prevents* something from starting:
  /// `PreToolUse` blocks the tool call, `SubagentStart` the spawn, `UserPromptSubmit` the
  /// turn, `PreCompact` a manual compaction, `PermissionRequest` the call. The one switch the
  /// contract keys on — a gating event's deny short-circuits later hooks and is where
  /// `failClosed` denies. For the after-the-fact events the thing already happened, so a
  /// hook's output can only be fed back — never enforced.
  public var isGate: Bool {
    switch self {
    case .preToolUse, .subagentStart, .userPromptSubmit, .preCompact, .permissionRequest:
      return true
    case .postToolUse, .postToolUseFailure, .stop, .subagentStop, .sessionStart, .sessionEnd,
         .postCompact, .notification:
      return false
    }
  }

  /// Whether exit 2 (or a `block`/`deny` verdict) is a **decision** the caller acts on
  /// rather than text fed back: every gate, plus `Stop`, where a block means "don't stop
  /// yet" and the reason becomes the model's next instruction. `Stop` is not a gate — a
  /// hook that *couldn't run* must never force the model to keep working (`failClosed`).
  public var canBlock: Bool { isGate || self == .stop }

  /// Whether plain stdout on exit 0 is **context** for the model rather than user-facing
  /// output: `UserPromptSubmit` (rides the user message), `SessionStart` (rides the system
  /// prompt), `PreCompact` (rides the summarizer's instructions). Claude Code's contract.
  public var stdoutIsContext: Bool {
    self == .userPromptSubmit || self == .sessionStart || self == .preCompact
  }

  /// Whether a hook's `matcher` is tested against an **agent name** for this event (the two
  /// delegation events) rather than a tool name.
  public var matchesAgentName: Bool {
    self == .subagentStart || self == .subagentStop
  }

  /// What a hook's `matcher` is tested against, for listings — nil when the event has no
  /// subject and a matcher is ignored (`Stop`, `UserPromptSubmit`).
  public var matcherSubject: String? {
    switch self {
    case .preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest: return "tool"
    case .subagentStart, .subagentStop: return "agent"
    case .sessionStart: return "source"
    case .sessionEnd: return "reason"
    case .preCompact, .postCompact: return "trigger"
    case .notification: return "type"
    case .stop, .userPromptSubmit: return nil
    }
  }
}

// MARK: - HookSource

/// Where a hook definition came from. The user's own `~/.arnes/hooks.json` is theirs, so it
/// decides freely; a repository's `.arnes/hooks.json` is **narrow-only** — it may deny, ask
/// and feed text back, but its `allow` and `updatedInput` are dropped, so a cloned repo can
/// never pre-approve or rewrite its own tool calls.
public enum HookSource: String, Codable, Sendable, Equatable {
  case user
  case project
}

// MARK: - HookType

/// What a hook definition runs. `command` (the default, and what every file written before
/// prompt hooks existed means) spawns a shell command; `prompt` asks a cheap model one
/// question and reads its verdict — see `PromptHookRunner`.
public enum HookType: String, Codable, Sendable, Equatable {
  case command
  case prompt
}

// MARK: - HookDefinition

/// One configured hook: which event, which tools it applies to, and the command to run —
/// or, for `type: prompt`, the question to put to a model.
public struct HookDefinition: Codable, Sendable, Equatable {
  public var event: HookEvent
  /// Subject filter: nil or "*" matches everything; otherwise matched as a regex against
  /// the subject (falling back to an exact-string compare when it isn't valid regex). The
  /// subject is the tool name for the tool events (`bash`, `edit_file|write_file`,
  /// `mcp__.*`), the **agent name** for `SubagentStart`/`SubagentStop` (`explore`,
  /// `reviewer|verifier`), the `source` for `SessionStart` (`startup|resume`), the `reason`
  /// for `SessionEnd`, the `trigger` for `PreCompact`/`PostCompact` (`manual`), the `type`
  /// for `Notification` (`permission_prompt`, `user_question`) — see `HookEvent.matcherSubject`. Ignored for
  /// `Stop` and `UserPromptSubmit` (no subject).
  public var matcher: String?
  /// Argument filter: tool-argument name → pattern, **all** of which must match for the hook
  /// to run. Lets a guardrail target the calls it cares about without parsing stdin —
  /// `{"command": "^git (push|reset --hard)"}` on `bash`, `{"path": "**/*.swift"}` on
  /// `edit_file`. The value is a **glob** for the path-shaped keys (`pathArgumentKeys`:
  /// `path`, `file_path`, `old_path`, `new_path` — `**` crosses directories) and an
  /// unanchored **regex** for every other key (an invalid pattern falls back to an exact
  /// compare). An argument the call didn't send never matches, so a `when` hook is skipped
  /// on an event that carries no arguments at all (`Stop`, `SubagentStart`/`SubagentStop`).
  /// The session events expose their own scalars to `when` under the payload's key names —
  /// `prompt` (UserPromptSubmit), `source`, `reason`, `trigger`, `error`,
  /// `notification_type`/`message` (see `HookPayload.whenArguments`). A key absent at the top
  /// level is also looked for inside `edit_file`'s `edits` array (`nestedArgumentArrays`) and
  /// matches when **any** element matches — `{"old_string": "TODO"}` fires whether the TODO
  /// edit is the call's only one or the third of five (T7).
  public var when: [String: String]?
  /// Agent filter, matched like `matcher` against the **agent name** the event is about: the
  /// spawned agent for `SubagentStart`/`SubagentStop`, the agent a nested session runs as for
  /// its tool events. A hook that sets it never fires on the lead's own calls, so a policy
  /// can be scoped to delegated work. nil/`*` matches everything.
  public var agent: String?
  /// `command` (default) or `prompt`. Absent in every file written before prompt hooks
  /// existed, and deliberately not encoded for a command hook, so the fingerprints recorded
  /// by `arnes hooks trust` stay valid.
  public var type: HookType
  /// The shell command, run via `/bin/sh -c`. Receives the event as JSON on stdin
  /// (`HookPayload`: `hook_event_name`, `tool_name`, `tool_input`, `cwd`, `agent_type`, …)
  /// plus `ARNES_HOOK_EVENT` / `ARNES_TOOL_NAME` / `ARNES_SESSION_ID` / `ARNES_CWD` /
  /// `ARNES_AGENT_NAME` / `ARNES_AGENT_ID` in the environment. Empty for a `prompt` hook,
  /// which runs no shell at all.
  public var command: String
  /// `type: prompt` only — the question put to the model. `$ARGUMENTS` is replaced by the
  /// event payload as JSON (the same object a command hook reads on stdin); without the
  /// placeholder the payload is appended after a blank line. Required for a prompt hook.
  public var prompt: String?
  /// `type: prompt` only — the model to ask, an id or a configured alias. nil means the
  /// provider's `bashJudge`; with neither set the hook is unusable and is skipped with a
  /// notice (never silently, never as an approval).
  public var model: String?
  /// Hard timeout; a hook that hangs must not hang the turn. Default 30s.
  public var timeoutSeconds: Int?
  /// Whether a hook that *cannot run* (fails to start, times out) blocks the call. Default
  /// false: such a failure is reported to the user and the call proceeds — a flaky
  /// formatter must not deny every tool. Set true on a guardrail hook, where "I couldn't
  /// check" must mean "no".
  public var failClosed: Bool?
  /// Optional stable name, used in listings and in the "changed since trusted" notice —
  /// worth setting on a project hook, whose command is otherwise its only identity.
  public var id: String?
  /// Optional human note, shown by `arnes hooks` and in the trust prompt.
  public var description: String?
  /// `false` skips the hook without deleting it. Default (nil) is on.
  public var enabled: Bool?
  /// Which file this came from. Deliberately **not** decoded: a project hooks file that
  /// spelled `"source": "user"` would be claiming privileges it doesn't have.
  public var source: HookSource = .user

  /// Argument names whose `when` pattern is a path glob rather than a regex.
  public static let pathArgumentKeys: Set<String> = ["path", "file_path", "old_path", "new_path"]

  /// Arguments whose object elements a `when` key is also matched against when the key is
  /// absent at the top level: `edit_file`'s `edits` array (T7). The hook fires when **any**
  /// element matches, so a guardrail on `old_string`/`new_string` cannot be bypassed by putting
  /// the same edit into the array form of the same call (narrow, never widen). Path keys are
  /// unaffected — `path` stays top-level and is never repeated per edit.
  public static let nestedArgumentArrays: Set<String> = ["edits"]

  enum CodingKeys: String, CodingKey {
    case event, matcher, when, agent, type, command, prompt, model, timeoutSeconds, failClosed, id,
         description, enabled
  }

  /// A command hook.
  public init(
    event: HookEvent,
    matcher: String? = nil,
    when: [String: String]? = nil,
    agent: String? = nil,
    command: String,
    timeoutSeconds: Int? = nil,
    failClosed: Bool? = nil,
    id: String? = nil,
    description: String? = nil,
    enabled: Bool? = nil,
    source: HookSource = .user)
  {
    self.event = event
    self.matcher = matcher
    self.when = when
    self.agent = agent
    type = .command
    self.command = command
    self.timeoutSeconds = timeoutSeconds
    self.failClosed = failClosed
    self.id = id
    self.description = description
    self.enabled = enabled
    self.source = source
  }

  /// A prompt hook: `prompt` is put to `model` (or the provider's `bashJudge` when nil).
  public init(
    event: HookEvent,
    matcher: String? = nil,
    when: [String: String]? = nil,
    agent: String? = nil,
    prompt: String,
    model: String? = nil,
    timeoutSeconds: Int? = nil,
    failClosed: Bool? = nil,
    id: String? = nil,
    description: String? = nil,
    enabled: Bool? = nil,
    source: HookSource = .user)
  {
    self.event = event
    self.matcher = matcher
    self.when = when
    self.agent = agent
    type = .prompt
    command = ""
    self.prompt = prompt
    self.model = model
    self.timeoutSeconds = timeoutSeconds
    self.failClosed = failClosed
    self.id = id
    self.description = description
    self.enabled = enabled
    self.source = source
  }

  /// `command` is required exactly as it always was for a command hook (a definition without
  /// one fails to decode, so a typo disables the file loudly rather than one guardrail
  /// quietly); for `type: prompt` it is ignored and `prompt` is required instead — a prompt
  /// hook runs no shell, so a `command` beside it is dropped rather than carried where no
  /// listing or trust prompt would show it. An unknown `type` fails the same way.
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    event = try c.decode(HookEvent.self, forKey: .event)
    matcher = try c.decodeIfPresent(String.self, forKey: .matcher)
    when = try c.decodeIfPresent([String: String].self, forKey: .when)
    agent = try c.decodeIfPresent(String.self, forKey: .agent)
    type = try c.decodeIfPresent(HookType.self, forKey: .type) ?? .command
    switch type {
    case .command:
      command = try c.decode(String.self, forKey: .command)
      prompt = try c.decodeIfPresent(String.self, forKey: .prompt)
      model = try c.decodeIfPresent(String.self, forKey: .model)
    case .prompt:
      command = ""
      guard let text = try c.decodeIfPresent(String.self, forKey: .prompt), !text.isEmpty else {
        throw DecodingError.dataCorruptedError(
          forKey: .prompt, in: c, debugDescription: "a prompt hook needs a non-empty \"prompt\"")
      }
      prompt = text
      model = try c.decodeIfPresent(String.self, forKey: .model)
    }
    timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
    failClosed = try c.decodeIfPresent(Bool.self, forKey: .failClosed)
    id = try c.decodeIfPresent(String.self, forKey: .id)
    description = try c.decodeIfPresent(String.self, forKey: .description)
    enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled)
  }

  /// `type` is written only for a prompt hook and `command` only when it has one, so a
  /// command hook's canonical JSON — and therefore its recorded fingerprint — is exactly
  /// what it was before prompt hooks existed.
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(event, forKey: .event)
    try c.encodeIfPresent(matcher, forKey: .matcher)
    try c.encodeIfPresent(when, forKey: .when)
    try c.encodeIfPresent(agent, forKey: .agent)
    if type == .prompt { try c.encode(type, forKey: .type) }
    if type == .command || !command.isEmpty { try c.encode(command, forKey: .command) }
    try c.encodeIfPresent(prompt, forKey: .prompt)
    try c.encodeIfPresent(model, forKey: .model)
    try c.encodeIfPresent(timeoutSeconds, forKey: .timeoutSeconds)
    try c.encodeIfPresent(failClosed, forKey: .failClosed)
    try c.encodeIfPresent(id, forKey: .id)
    try c.encodeIfPresent(description, forKey: .description)
    try c.encodeIfPresent(enabled, forKey: .enabled)
  }

  /// `enabled: false` is the off switch; anything else runs.
  public var isEnabled: Bool { enabled != false }

  /// How the hook is named in notices and listings: the `id`, else the first 60 characters
  /// of the command (or, for a prompt hook, of the prompt).
  public var label: String {
    id ?? String((type == .prompt ? (prompt ?? "") : command).prefix(60))
  }

  /// The definition as it appears in a file — sorted keys, no whitespace. `source` is not
  /// part of it, so the same JSON always hashes the same whichever file it came from.
  public var canonicalJSON: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8)
    else { return command }
    return text
  }

  /// SHA-256 of `canonicalJSON`, hex. What `arnes hooks trust` records and what a project
  /// hook is checked against on every run — editing a trusted hook revokes its trust.
  public var fingerprint: String { HookHash.sha256Hex(Data(canonicalJSON.utf8)) }

  /// Whether this hook applies to `subject` — a tool name, or an agent name for the
  /// subagent events.
  func matches(subject: String) -> Bool {
    Self.matcherAccepts(matcher, subject: subject)
  }

  /// The one matcher rule, shared with `HookHandler`: nil, `*` or empty accepts everything;
  /// otherwise a whole-token regex (falling back to an exact compare).
  static func matcherAccepts(_ matcher: String?, subject: String) -> Bool {
    guard let matcher, matcher != "*", !matcher.isEmpty else { return true }
    return matchesAnchored(pattern: matcher, subject)
  }

  func matches(tool: String) -> Bool { matches(subject: tool) }

  /// Whether the hook's `agent` filter accepts the agent this event is about (nil = the
  /// lead's own work, which only an unfiltered hook matches).
  func matchesAgent(_ name: String?) -> Bool {
    guard let agent, agent != "*", !agent.isEmpty else { return true }
    guard let name else { return false }
    return Self.matchesAnchored(pattern: agent, name)
  }

  /// Whether every `when` entry matches the call's decoded arguments. A missing argument,
  /// a non-scalar one, or arguments that aren't an object at all mean no match; a key missing
  /// at the top level but present in a `nestedArgumentArrays` element matches through it.
  func matches(arguments: JSONValue?, root: URL?) -> Bool {
    guard let when, !when.isEmpty else { return true }
    guard case .object(let object) = arguments ?? .null else { return false }
    for (key, pattern) in when {
      guard Self.whenMatches(key: key, pattern: pattern, texts: Self.matchTexts(for: key, in: object), root: root)
      else { return false }
    }
    return true
  }

  /// The texts a `when` key is matched against: the top-level value when the key is present
  /// (a non-scalar there is no text — the key was sent, it just cannot match), else the key's
  /// scalar in every object element of a `nestedArgumentArrays` argument.
  static func matchTexts(for key: String, in object: [String: JSONValue]) -> [String] {
    if let value = object[key] { return Self.matchText(value).map { [$0] } ?? [] }
    var texts: [String] = []
    for arrayKey in nestedArgumentArrays.sorted() {
      guard case .array(let elements)? = object[arrayKey] else { continue }
      for element in elements {
        if case .object(let nested) = element, let value = nested[key], let text = Self.matchText(value) {
          texts.append(text)
        }
      }
    }
    return texts
  }

  /// One `when` entry against its candidate texts — a glob for the path keys, an unanchored
  /// regex otherwise; true when any text matches, false for none (a missing argument).
  static func whenMatches(key: String, pattern: String, texts: [String], root: URL?) -> Bool {
    texts.contains { text in
      Self.pathArgumentKeys.contains(key)
        ? GlobMatch.matches(glob: pattern, path: text, root: root)
        : Self.matchesUnanchored(pattern: pattern, text)
    }
  }

  /// A scalar argument as text; containers and null never match a pattern.
  static func matchText(_ value: JSONValue) -> String? {
    switch value {
    case .string(let text): return text
    case .int(let number): return String(number)
    case .double(let number): return String(number)
    case .bool(let flag): return flag ? "true" : "false"
    case .null, .array, .object: return nil
    }
  }

  /// Whole-token match (tool and agent names): the pattern must cover the entire subject.
  static func matchesAnchored(pattern: String, _ subject: String) -> Bool {
    if pattern == subject { return true }
    guard let regex = try? NSRegularExpression(pattern: "^(?:\(pattern))$") else { return false }
    return regex.firstMatch(in: subject, range: NSRange(subject.startIndex..., in: subject)) != nil
  }

  /// Substring match (argument values), so `"^git push"` and `"secret"` both read naturally.
  /// An uncompilable pattern degrades to an exact compare rather than matching everything.
  static func matchesUnanchored(pattern: String, _ text: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return pattern == text }
    return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }
}

// MARK: - HookConfig

/// `~/.arnes/hooks.json` (or `ARNES_HOOKS_CONFIG`), layered over a **trusted** working
/// directory's `.arnes/hooks.json`.
///
/// A hook runs arbitrary code on every tool call, so a repository's hooks are gated twice:
/// the directory must be trusted (`ProjectTrustStore`, the same yes/no as its skills and
/// agents) *and* each definition's `fingerprint` must be one the user recorded with
/// `arnes hooks trust`. Editing a trusted hook — or adding one — revokes that hook's trust
/// until the user looks again, so a `git pull` can't quietly change what runs. On top of
/// that, a project hook is narrow-only (see `HookSource`).
public struct HookConfig: Codable, Sendable, Equatable {
  public var hooks: [HookDefinition]

  public init(hooks: [HookDefinition] = []) { self.hooks = hooks }

  public static var defaultURL: URL {
    if let override = ProcessInfo.processInfo.environment["ARNES_HOOKS_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/hooks.json")
  }

  /// The hooks file a working directory may contribute. `ARNES_HOOKS_CONFIG` overrides the
  /// *user* file only — a per-project override of the project file would defeat the point.
  public static func projectURL(in directory: URL) -> URL {
    directory.appendingPathComponent(".arnes/hooks.json")
  }

  /// Loads the config, or nil when the file doesn't exist. Throws on malformed JSON so a
  /// typo surfaces instead of silently disabling the user's guardrails.
  public static func load(from url: URL = defaultURL) throws -> HookConfig? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(HookConfig.self, from: Data(contentsOf: url))
  }

  /// A directory's own hook definitions, whatever their trust — what a trust prompt lists.
  /// Returns [] when there is no file or it doesn't parse.
  public static func projectHooks(in directory: URL) -> [HookDefinition] {
    guard let config = try? load(from: projectURL(in: directory)) else { return [] }
    return config.hooks.map {
      var definition = $0
      definition.source = .project
      return definition
    }
  }

  /// The user's hooks plus a trusted directory's, each tagged with where it came from and
  /// whether it will run.
  ///
  /// `directory` is the caller's working directory — passed in rather than read from the
  /// process, so a panel candidate running in a snapshot still resolves the trust of the
  /// *original* project instead of a temp path nobody ever trusted. `directoryTrusted` is
  /// the run's own decision (the trust gate); the store is consulted on top of it, so a
  /// caller can only narrow.
  ///
  /// Throws only for a malformed **user** file (the caller's guardrails silently vanishing
  /// is the thing worth shouting about); a project file that won't parse becomes a notice.
  /// `project` has no default on purpose: it keeps this overload distinct from
  /// `load(from:)`, and a caller must say which directory's trust it means.
  public static func load(
    user userURL: URL = defaultURL,
    project directory: URL?,
    trust store: ProjectTrustStore = ProjectTrustStore(),
    directoryTrusted: Bool = true)
    throws -> LoadedHooks
  {
    var loaded = LoadedHooks()
    for definition in (try load(from: userURL))?.hooks ?? [] {
      var user = definition
      user.source = .user
      loaded.hooks.append(LoadedHook(definition: user, trust: .trusted))
    }
    if let directory {
      loaded.append(project: directory, trust: store, directoryTrusted: directoryTrusted)
    }
    return loaded
  }
}

// MARK: - LoadedHook

/// One hook as loaded: the definition, where it came from, and whether it will run.
public struct LoadedHook: Sendable, Equatable {
  /// Why a hook is (not) running.
  public enum Trust: String, Sendable, Equatable {
    /// The user's own hook, or a project hook whose fingerprint was recorded.
    case trusted
    /// A project hook whose fingerprint isn't recorded — new, or edited since.
    case changed
    /// The project file exists but the directory isn't trusted.
    case untrustedDirectory
  }

  public var definition: HookDefinition
  public var trust: Trust

  public init(definition: HookDefinition, trust: Trust) {
    self.definition = definition
    self.trust = trust
  }

  public var source: HookSource { definition.source }
  /// Whether this hook actually runs (`enabled: false` is off however trusted it is).
  public var trusted: Bool { trust == .trusted && definition.isEnabled }
}

// MARK: - LoadedHooks

/// The result of layering the user's hooks over a project's: every definition with its trust,
/// the ones that will actually run, and the lines to show the user about the rest.
public struct LoadedHooks: Sendable, Equatable {
  public var hooks: [LoadedHook] = []
  /// One line per skipped hook or unreadable/loose-permission file, deduplicated.
  public var notices: [String] = []

  public init(hooks: [LoadedHook] = [], notices: [String] = []) {
    self.hooks = hooks
    self.notices = notices
  }

  /// What the session runs: user hooks first, then the project's trusted ones, with an
  /// identical definition kept only once (a repo that copies a user hook doesn't run it twice).
  public var active: [HookDefinition] {
    var seen: Set<String> = []
    var out: [HookDefinition] = []
    for hook in hooks where hook.trusted {
      let fingerprint = hook.definition.fingerprint
      guard seen.insert(fingerprint).inserted else { continue }
      out.append(hook.definition)
    }
    return out
  }

  public var isEmpty: Bool { hooks.isEmpty }

  mutating func note(_ line: String) {
    guard !notices.contains(line) else { return }
    notices.append(line)
  }

  /// Appends a directory's hooks, classified. A file group/other-writable is called out: its
  /// contents become commands, so anyone who can write it can run code as the user.
  mutating func append(project directory: URL, trust store: ProjectTrustStore, directoryTrusted: Bool) {
    let url = HookConfig.projectURL(in: directory)
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    guard let config = try? HookConfig.load(from: url) else {
      note("⚠ \(url.path) is invalid — this project's hooks are not loaded")
      return
    }
    if SecureFiles.isWritableByOthers(url) {
      note("⚠ \(url.path) is writable by other users — chmod 644 it; its hooks run commands")
    }
    let directoryIsTrusted = directoryTrusted && store.isTrusted(directory)
    let approved = directoryIsTrusted ? store.trustedHookHashes(for: directory) : []
    var skipped = 0
    for definition in config.hooks {
      var project = definition
      project.source = .project
      let trust: LoadedHook.Trust
      if !directoryIsTrusted {
        trust = .untrustedDirectory
        skipped += 1
      } else if approved.contains(project.fingerprint) {
        trust = .trusted
      } else {
        trust = .changed
        note("hook '\(project.label)' changed since trusted — run `arnes hooks trust`")
      }
      hooks.append(LoadedHook(definition: project, trust: trust))
    }
    if skipped > 0 {
      note("skipping \(skipped) project hook\(skipped == 1 ? "" : "s") from \(url.path) — "
        + "directory not trusted; run `arnes trust` there, then `arnes hooks trust`")
    }
  }
}

// MARK: - HookHash

/// SHA-256, for hook fingerprints. Small enough to carry here rather than take a crypto
/// dependency for one call site, and it must be a real hash: a project hook's trust is
/// exactly "this content, which the user looked at", so a second preimage would be a way to
/// swap in another command under an approved fingerprint.
enum HookHash {
  static func sha256Hex(_ message: Data) -> String {
    var h: [UInt32] = [
      0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ]
    let k: [UInt32] = [
      0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
      0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
      0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
      0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
      0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
      0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
      0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
      0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ]
    // Padding: the message, a 1 bit, zeros, then the bit length as a big-endian UInt64.
    var bytes = [UInt8](message)
    let bitLength = UInt64(bytes.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
    }
    var w = [UInt32](repeating: 0, count: 64)
    for chunk in stride(from: 0, to: bytes.count, by: 64) {
      for i in 0..<16 {
        let base = chunk + i * 4
        w[i] = UInt32(bytes[base]) << 24 | UInt32(bytes[base + 1]) << 16
          | UInt32(bytes[base + 2]) << 8 | UInt32(bytes[base + 3])
      }
      for i in 16..<64 {
        let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
        let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
        w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
      }
      var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
      for i in 0..<64 {
        let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
        let ch = (e & f) ^ (~e & g)
        let temp1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
        let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
        let maj = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = s0 &+ maj
        hh = g; g = f; f = e; e = d &+ temp1
        d = c; c = b; b = a; a = temp1 &+ temp2
      }
      h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d
      h[4] = h[4] &+ e; h[5] = h[5] &+ f; h[6] = h[6] &+ g; h[7] = h[7] &+ hh
    }
    return h.map { String(format: "%08x", $0) }.joined()
  }

  private static func rotr(_ value: UInt32, _ bits: UInt32) -> UInt32 {
    (value >> bits) | (value << (32 - bits))
  }
}

// MARK: - HookPayload

/// What a hook reads on stdin. Field names follow Claude Code's hook JSON (`hook_event_name`,
/// `session_id`, `tool_name`, `tool_input`, `tool_use_id`, `tool_response`, `cwd`,
/// `agent_type`, `prompt`, `source`, `reason`, `trigger`, `error`, `stop_hook_active`,
/// `notification_type`, `message`) so scripts written for it port unchanged; `agent`,
/// `turn_index`, `permission_tier` and the rest of the delegation block (`agent_id`, `model`,
/// `task`, `parent_session_id`, `report`, `steps`, `tool_calls`, `cost_usd`, `partial`) are
/// Arnes additions. Every field except `hook_event_name` and `cwd` is optional and omitted
/// when it doesn't apply to the event.
public struct HookPayload: Codable, Sendable, Equatable {
  public var hookEventName: String
  public var sessionId: String?
  public var cwd: String
  /// The tool being called (PreToolUse/PostToolUse/PostToolUseFailure/PermissionRequest);
  /// absent for the session-level events.
  public var toolName: String?
  /// The call's arguments as a JSON object (the authoritative copy — never in the environment).
  public var toolInput: JSONValue?
  public var toolUseId: String?
  /// The tool's output, for PostToolUse (clipped to 4000 characters).
  public var toolResponse: String?
  /// PostToolUseFailure: the `error:` result or the thrown error (clipped to 4000 characters).
  public var error: String?
  /// PermissionRequest: the tier the call was classified at (`read_only`/`mutating`/`sensitive`).
  public var permissionTier: String?
  /// UserPromptSubmit: the user's text, as typed.
  public var prompt: String?
  /// SessionStart: `startup`, `resume`, `clear` or `compact`.
  public var source: String?
  /// SessionEnd: `exit`, `clear` or `other`.
  public var reason: String?
  /// PreCompact/PostCompact: `manual` or `auto`.
  public var trigger: String?
  /// Stop: true when the turn is already continuing because an earlier Stop hook blocked —
  /// a hook that keeps blocking should check this so it can't loop.
  public var stopHookActive: Bool?
  /// Notification: what kind (`permission_prompt`, `user_question`), and the text about to be shown.
  public var notificationType: String?
  public var message: String?
  /// The subagent this session runs as, when nested.
  public var agent: String?
  public var turnIndex: Int?
  /// SubagentStart/SubagentStop: the delegation's own id, stable across the two events.
  public var agentId: String?
  /// SubagentStart/SubagentStop: the agent's name (Claude Code's spelling for the same
  /// thing `agent` carries on a nested session's tool events).
  public var agentType: String?
  /// SubagentStart/SubagentStop: the model the subagent runs on, already resolved.
  public var model: String?
  /// SubagentStart/SubagentStop: the task text the lead delegated (clipped to 4000 chars).
  public var task: String?
  /// SubagentStart/SubagentStop: the session that spawned this agent. Also reported as
  /// `session_id`, so a script written for Claude Code still finds it.
  public var parentSessionId: String?
  /// SubagentStop: the report going back to the lead (clipped to 4000 chars).
  public var report: String?
  /// SubagentStop: steps the nested run took.
  public var steps: Int?
  /// SubagentStop: tool calls the nested run made.
  public var toolCalls: Int?
  /// SubagentStop: what the nested run cost.
  public var costUSD: Double?
  /// SubagentStop: true when the run stopped on its step limit or budget, so the report is
  /// partial — a post-processing hook should not treat it as the whole answer.
  public var partial: Bool?

  enum CodingKeys: String, CodingKey {
    case hookEventName = "hook_event_name"
    case sessionId = "session_id"
    case cwd
    case toolName = "tool_name"
    case toolInput = "tool_input"
    case toolUseId = "tool_use_id"
    case toolResponse = "tool_response"
    case error
    case permissionTier = "permission_tier"
    case prompt
    case source
    case reason
    case trigger
    case stopHookActive = "stop_hook_active"
    case notificationType = "notification_type"
    case message
    case agent
    case turnIndex = "turn_index"
    case agentId = "agent_id"
    case agentType = "agent_type"
    case model
    case task
    case parentSessionId = "parent_session_id"
    case report
    case steps
    case toolCalls = "tool_calls"
    case costUSD = "cost_usd"
    case partial
  }

  public init(
    hookEventName: String,
    sessionId: String? = nil,
    cwd: String,
    toolName: String? = nil,
    toolInput: JSONValue? = nil,
    toolUseId: String? = nil,
    toolResponse: String? = nil,
    agent: String? = nil,
    turnIndex: Int? = nil,
    agentId: String? = nil,
    agentType: String? = nil,
    model: String? = nil,
    task: String? = nil,
    parentSessionId: String? = nil,
    report: String? = nil,
    steps: Int? = nil,
    toolCalls: Int? = nil,
    costUSD: Double? = nil,
    partial: Bool? = nil,
    error: String? = nil,
    permissionTier: String? = nil,
    prompt: String? = nil,
    source: String? = nil,
    reason: String? = nil,
    trigger: String? = nil,
    stopHookActive: Bool? = nil,
    notificationType: String? = nil,
    message: String? = nil)
  {
    self.hookEventName = hookEventName
    self.sessionId = sessionId
    self.cwd = cwd
    self.toolName = toolName
    self.toolInput = toolInput
    self.toolUseId = toolUseId
    self.toolResponse = toolResponse
    self.agent = agent
    self.turnIndex = turnIndex
    self.agentId = agentId
    self.agentType = agentType
    self.model = model
    self.task = task
    self.parentSessionId = parentSessionId
    self.report = report
    self.steps = steps
    self.toolCalls = toolCalls
    self.costUSD = costUSD
    self.partial = partial
    self.error = error
    self.permissionTier = permissionTier
    self.prompt = prompt
    self.source = source
    self.reason = reason
    self.trigger = trigger
    self.stopHookActive = stopHookActive
    self.notificationType = notificationType
    self.message = message
  }

  /// What a hook's `when` filter is matched against: the tool arguments when the event has
  /// them, plus the event's own scalars under their wire names (`prompt`, `source`, `reason`,
  /// `trigger`, `error`, `notification_type`, `message`, `permission_tier`). Nil for an event
  /// carrying none of them (`Stop`, the delegation events) — a `when` hook sits those out,
  /// as it always has.
  var whenArguments: JSONValue? {
    var fields: [String: JSONValue] = [:]
    if case .object(let object) = toolInput ?? .null { fields = object }
    for (key, value) in [
      "prompt": prompt, "source": source, "reason": reason, "trigger": trigger, "error": error,
      "notification_type": notificationType, "message": message, "permission_tier": permissionTier,
    ] {
      if let value, fields[key] == nil { fields[key] = .string(value) }
    }
    if fields.isEmpty { return toolInput }
    return .object(fields)
  }
}

// MARK: - HookHandler

/// An in-process hook: the embedder's own code at a lifecycle point, on the same
/// `HookPayload` in and `HookOutcome` out as a shell hook, merged by the same rule
/// (deny > ask > allow > none) and short-circuited by the same gating deny. Handlers run
/// **before** the configured hooks of the same event.
///
/// A handler is the embedding application's code, so — unlike a project hook or a prompt
/// hook — its outcome is **not** clamped: it may `allow` an ordinary mutation, rewrite
/// arguments with `updatedInput`, or end the turn. The session's own narrowing still applies
/// on top (an `allow` never lifts a `.sensitive` prompt, a deny rule, plan mode or the floor).
public protocol HookHandler: Sendable {
  /// The event this handler answers.
  var event: HookEvent { get }
  /// Subject filter with `HookDefinition.matcher`'s semantics: nil or `*` matches every
  /// subject (tool name, agent name, source, …); otherwise a whole-token regex.
  var matcher: String? { get }
  func handle(_ payload: HookPayload) async -> HookOutcome
}

/// A handler that spends money (one that asks a model, say) reports it here so the session
/// can book it against the turn — `HookEngine.drainAccruedCostUSD` sums every conforming
/// handler with the prompt runner's spend.
public protocol CostReportingHookHandler: HookHandler {
  /// USD accrued since the last drain; resets the accumulator.
  func drainAccruedCostUSD() async -> Double
}

// MARK: - HookEngine

/// Runs the configured hooks for the tool lifecycle. Injected into `Session`; a nil engine
/// (no config) means zero overhead — the loop calls straight through.
///
/// Three kinds of hook share one dispatch: in-process `HookHandler`s (first), then the
/// configured definitions in order — a `command` hook through `ShellRunner`, a `prompt` hook
/// through the `PromptHookRunner` the engine was given (skipped with a notice when it has
/// none — a deny on a gate if that hook is `failClosed`). Every outcome is merged deny > ask
/// > allow > none; a gating deny stops the rest.
public struct HookEngine: Sendable {
  public let hooks: [HookDefinition]
  /// In-process hooks, run ahead of the configured ones. Empty by default.
  public let handlers: [any HookHandler]
  /// Executes the `type: prompt` definitions; nil means every prompt hook is skipped with an
  /// `errors` notice naming it (a missing runner must never read as an approval — and, for a
  /// `failClosed` hook on a gate, it is the deny a command hook that couldn't spawn would be).
  let promptRunner: PromptHookRunner?
  /// Where hooks run and what their payload reports as `cwd`; the process CWD when nil.
  let cwd: URL?
  /// What a hook subprocess inherits of the environment — the provider token is withheld
  /// the same way it is from `bash`, so a `PostToolUse` hook can't log the key out.
  let environment: SubprocessEnvironment
  /// Identity carried in every payload: the session id and, for nested sessions, the agent.
  let sessionId: String?
  let agent: String?

  public init(
    hooks: [HookDefinition],
    handlers: [any HookHandler] = [],
    promptRunner: PromptHookRunner? = nil,
    cwd: URL? = nil,
    environment: SubprocessEnvironment = .default,
    sessionId: String? = nil,
    agent: String? = nil)
  {
    self.hooks = hooks
    self.handlers = handlers
    self.promptRunner = promptRunner
    self.cwd = cwd
    self.environment = environment
    self.sessionId = sessionId
    self.agent = agent
  }

  /// nil when there are no hooks *and* no handlers to run — lets the caller skip the
  /// machinery entirely.
  public static func make(
    hooks: [HookDefinition],
    handlers: [any HookHandler] = [],
    promptRunner: PromptHookRunner? = nil,
    cwd: URL? = nil,
    environment: SubprocessEnvironment = .default,
    sessionId: String? = nil,
    agent: String? = nil)
    -> HookEngine?
  {
    hooks.isEmpty && handlers.isEmpty
      ? nil
      : HookEngine(
        hooks: hooks, handlers: handlers, promptRunner: promptRunner, cwd: cwd,
        environment: environment, sessionId: sessionId, agent: agent)
  }

  public var isEmpty: Bool { hooks.isEmpty && handlers.isEmpty }

  /// What the prompt hooks and the cost-reporting handlers have spent since the last drain
  /// — the session adds it to the turn's books after each executed tool call, so a judge's
  /// or a prompt hook's request reaches `RunRecord.costUSD` like any other dollar. Spend on
  /// a *denied* call, or on `Stop`/session hooks after the last tool call, waits for the next
  /// executed call (or the record's final drain).
  public func drainAccruedCostUSD() async -> Double {
    var total = await promptRunner?.drainAccruedCostUSD() ?? 0
    for case let costly as any CostReportingHookHandler in handlers {
      total += await costly.drainAccruedCostUSD()
    }
    return total
  }

  /// Cap on what a hook's output can inject into the conversation: head and tail kept, the
  /// middle elided. Context hygiene — a chatty linter can't flood the model.
  static let maxOutputChars = 10_000
  /// PostToolUse payloads carry this much of the tool result.
  static let maxResponseChars = 4_000
  public static let defaultTimeoutSeconds = 30

  /// Runs PreToolUse hooks and merges their decisions (deny > ask > allow > none). A hook
  /// that could not run lands in `errors` unless it is `failClosed`, in which case the
  /// failure itself denies.
  public func preToolUse(
    tool: String,
    argumentsJSON: String,
    toolUseId: String? = nil,
    turnIndex: Int? = nil)
    async -> HookOutcome
  {
    await run(event: .preToolUse, tool: tool, argumentsJSON: argumentsJSON, toolUseId: toolUseId,
              response: nil, turnIndex: turnIndex)
  }

  /// Runs PostToolUse hooks. `feedback` carries their output to append to the tool result, so
  /// a formatter/linter/test result (or a `decision: "block"` reason) reaches the model;
  /// `continueRun == false` asks the session to end the turn.
  public func postToolUse(
    tool: String,
    argumentsJSON: String,
    result: String,
    toolUseId: String? = nil,
    turnIndex: Int? = nil)
    async -> HookOutcome
  {
    await run(event: .postToolUse, tool: tool, argumentsJSON: argumentsJSON, toolUseId: toolUseId,
              response: result, turnIndex: turnIndex)
  }

  /// Runs PostToolUseFailure hooks after a tool call failed (`execute` threw, or the result
  /// carries the `error:` prefix). `feedback` is appended to the result the way PostToolUse
  /// output is; `continueRun == false` asks the session to end the turn. Never called for a
  /// refusal — a call that didn't run didn't fail.
  public func postToolUseFailure(
    tool: String,
    argumentsJSON: String,
    error: String,
    toolUseId: String? = nil,
    turnIndex: Int? = nil)
    async -> HookOutcome
  {
    var payload = payload(
      for: .postToolUseFailure, tool: tool, argumentsJSON: argumentsJSON, toolUseId: toolUseId,
      response: nil, turnIndex: turnIndex)
    payload.error = String(error.prefix(Self.maxResponseChars))
    return await run(event: .postToolUseFailure, subject: tool, payload: payload)
  }

  /// Runs PermissionRequest hooks just before a human would be asked about `tool`. A deny
  /// (`blockReason`) refuses the call; `.allow` answers the prompt — the caller applies the
  /// narrowing (ordinary mutations only). `tier` is the call's classification, in the
  /// on-disk spelling (`read_only`/`mutating`/`sensitive`).
  public func permissionRequest(
    tool: String,
    argumentsJSON: String,
    tier: String,
    toolUseId: String? = nil,
    turnIndex: Int? = nil)
    async -> HookOutcome
  {
    var payload = payload(
      for: .permissionRequest, tool: tool, argumentsJSON: argumentsJSON, toolUseId: toolUseId,
      response: nil, turnIndex: turnIndex)
    payload.permissionTier = tier
    return await run(event: .permissionRequest, subject: tool, payload: payload)
  }

  /// Runs Stop hooks at turn end. Plain output is `feedback` for the user; a block
  /// (`blockReason`) means "don't stop yet" and the session continues the turn with the
  /// reason. `stopHookActive` is true when this turn is already a continuation, so a hook
  /// can see it is being asked again.
  public func stop(turnIndex: Int? = nil, stopHookActive: Bool = false) async -> HookOutcome {
    var payload = payload(
      for: .stop, tool: nil, argumentsJSON: nil, toolUseId: nil, response: nil, turnIndex: turnIndex)
    if stopHookActive { payload.stopHookActive = true }
    return await run(event: .stop, subject: nil, payload: payload)
  }

  /// Runs UserPromptSubmit hooks before the user's text enters history. A deny
  /// (`blockReason`) means the turn must not send; `additionalContext` (plain stdout
  /// included) is for the caller to append to the user message. No matcher subject.
  public func userPromptSubmit(prompt: String, turnIndex: Int? = nil) async -> HookOutcome {
    var payload = sessionPayload(for: .userPromptSubmit)
    payload.prompt = prompt
    payload.turnIndex = turnIndex
    return await run(event: .userPromptSubmit, subject: nil, payload: payload)
  }

  /// Runs SessionStart hooks. Matched on `source`; `additionalContext` (plain stdout
  /// included) is context the caller keeps for the system prompt.
  public func sessionStart(source: String) async -> HookOutcome {
    var payload = sessionPayload(for: .sessionStart)
    payload.source = source
    return await run(event: .sessionStart, subject: source, payload: payload)
  }

  /// SessionEnd hooks share this much wall-clock: the process (or the user) is leaving, and
  /// nothing they say can change what happened.
  public static let sessionEndBudgetSeconds: Double = 1.5

  /// Runs SessionEnd hooks, matched on `reason`, under `sessionEndBudgetSeconds` in total —
  /// a hook still running at the deadline is killed and reported in `errors`. Advisory:
  /// `feedback` is output for the user, nothing here can block.
  public func sessionEnd(reason: String) async -> HookOutcome {
    var payload = sessionPayload(for: .sessionEnd)
    payload.reason = reason
    let engine = self
    let work = Task { await engine.run(event: .sessionEnd, subject: reason, payload: payload) }
    let deadline = Task {
      try await Task.sleep(nanoseconds: UInt64(Self.sessionEndBudgetSeconds * 1_000_000_000))
      work.cancel()
    }
    var outcome = await work.value
    deadline.cancel()
    if work.isCancelled {
      // The deadline fired: cancellation killed the running hook (and any after it), which
      // the runner reports as an interruption — name the real cause.
      outcome.errors = outcome.errors.map {
        $0.replacingOccurrences(
          of: "was interrupted",
          with: "exceeded the \(Self.sessionEndBudgetSeconds)s SessionEnd budget and was killed")
      }
    }
    return outcome
  }

  /// Runs PreCompact hooks before the summarizer request. Matched on `trigger` (`manual` /
  /// `auto`). A deny (`blockReason`) cancels a manual compaction — the caller decides for an
  /// automatic one; `additionalContext` (plain stdout included) is extra summarizer
  /// instructions for this run.
  public func preCompact(trigger: String, turnIndex: Int? = nil) async -> HookOutcome {
    var payload = sessionPayload(for: .preCompact)
    payload.trigger = trigger
    payload.turnIndex = turnIndex
    return await run(event: .preCompact, subject: trigger, payload: payload)
  }

  /// Runs PostCompact hooks after a compaction succeeded. Matched on `trigger`; output is
  /// `feedback` for the user.
  public func postCompact(trigger: String, turnIndex: Int? = nil) async -> HookOutcome {
    var payload = sessionPayload(for: .postCompact)
    payload.trigger = trigger
    payload.turnIndex = turnIndex
    return await run(event: .postCompact, subject: trigger, payload: payload)
  }

  /// Runs Notification hooks: the UI is about to show `message` of kind `type`
  /// (`permission_prompt`). Matched on `type`. Advisory — only `errors` matter to the caller.
  public func notification(type: String, message: String) async -> HookOutcome {
    var payload = sessionPayload(for: .notification)
    payload.notificationType = type
    payload.message = String(message.prefix(Self.maxResponseChars))
    return await run(event: .notification, subject: type, payload: payload)
  }

  /// Runs SubagentStart hooks before a delegation. A deny (`blockReason`) means the spawn
  /// must not happen: the caller reports the reason to the lead instead of making a nested
  /// request. Matched on the agent name, not a tool name.
  public func subagentStart(
    agent: String,
    id: String,
    model: String,
    task: String)
    async -> HookOutcome
  {
    await run(
      event: .subagentStart,
      subject: agent,
      payload: subagentPayload(
        for: .subagentStart, agent: agent, id: id, model: model, task: task))
  }

  /// Runs SubagentStop hooks after a nested run, before its report goes back to the lead.
  /// `feedback` is appended to that report the way `PostToolUse` output is appended to a
  /// tool result; `continueRun == false` is recorded for the caller to act on.
  public func subagentStop(
    agent: String,
    id: String,
    model: String,
    task: String,
    report: String,
    steps: Int,
    toolCalls: Int,
    costUSD: Double,
    partial: Bool)
    async -> HookOutcome
  {
    await run(
      event: .subagentStop,
      subject: agent,
      payload: subagentPayload(
        for: .subagentStop, agent: agent, id: id, model: model, task: task,
        report: report, steps: steps, toolCalls: toolCalls, costUSD: costUSD, partial: partial))
  }

  // MARK: Running

  /// The tool-lifecycle events: builds their payload and runs every hook matching `tool`.
  func run(
    event: HookEvent,
    tool: String?,
    argumentsJSON: String?,
    toolUseId: String?,
    response: String?,
    turnIndex: Int?)
    async -> HookOutcome
  {
    await run(
      event: event,
      subject: tool,
      payload: payload(
        for: event, tool: tool, argumentsJSON: argumentsJSON, toolUseId: toolUseId,
        response: response, turnIndex: turnIndex))
  }

  /// Every handler, then every hook for `event` that applies to this call, in configuration
  /// order, merged. On a gating event a deny short-circuits — later hooks don't run for
  /// something that won't happen — and a `failClosed` hook that *couldn't* run denies rather
  /// than waving it past. A project hook's outcome is clamped on the way out: it may refuse,
  /// never approve; a prompt hook's is clamped the same way whoever configured it (a model's
  /// opinion escalates, it never approves).
  func run(event: HookEvent, subject: String?, payload: HookPayload) async -> HookOutcome {
    var merged = HookOutcome()
    for handler in handlers where applies(handler, event: event, subject: subject) {
      merged.merge(await handler.handle(payload))
      if event.isGate, merged.blockReason != nil { return merged }
    }
    for hook in hooks where applies(hook, event: event, subject: subject, payload: payload) {
      var outcome: HookOutcome
      switch hook.type {
      case .command:
        outcome = await runCommand(hook, event: event, payload: payload)
      case .prompt:
        outcome = await runPrompt(hook, event: event, payload: payload)
      }
      if hook.source == .project { outcome = outcome.narrowedToRefusals() }
      merged.merge(outcome)
      if event.isGate, merged.blockReason != nil { break }
    }
    return merged
  }

  /// One command hook: spawned, parsed per the exit-code contract, `failClosed` applied.
  private func runCommand(_ hook: HookDefinition, event: HookEvent, payload: HookPayload) async -> HookOutcome {
    switch await run(hook, payload: payload) {
    case .exited(let code, let output):
      var parsed = HookOutcome.parse(exit: code, output: output, event: event)
      if !parsed.errors.isEmpty {
        let label = "hook `\(String(hook.command.prefix(60)))`"
        if hook.failClosed == true, event.isGate {
          parsed = HookOutcome(decision: .deny(reason: "blocked: \(label) \(parsed.errors.joined(separator: "; ")) (hook is failClosed)"))
        } else {
          parsed.errors = parsed.errors.map { "\(label) \($0)" }
        }
      }
      return parsed
    case .failed(let message):
      if hook.failClosed == true, event.isGate {
        return HookOutcome(decision: .deny(reason: "blocked: \(message) (hook is failClosed)"))
      }
      return HookOutcome(errors: [message])
    }
  }

  /// One prompt hook, through the runner. No runner, or a reply the runner couldn't use, is
  /// an `errors` notice — and a deny when the hook is `failClosed` on a gate, exactly as a
  /// command hook that couldn't run (an engine built without a runner *is* a hook that can't
  /// run, and a guardrail marked fail-closed must not wave the call past because of it). The
  /// runner already clamped the outcome to refusals.
  private func runPrompt(_ hook: HookDefinition, event: HookEvent, payload: HookPayload) async -> HookOutcome {
    let label = "prompt hook `\(hook.label)`"
    guard let promptRunner else {
      let message = "\(label) skipped — no prompt runner configured for this session"
      if hook.failClosed == true, event.isGate {
        return HookOutcome(decision: .deny(reason: "blocked: \(message) (hook is failClosed)"))
      }
      return HookOutcome(errors: [message])
    }
    var outcome = await promptRunner.run(hook, event: event, payload: payload)
    if !outcome.errors.isEmpty, hook.failClosed == true, event.isGate {
      let reasons = outcome.errors.joined(separator: "; ")
      outcome = HookOutcome(
        decision: .deny(reason: "blocked: \(label) \(reasons) (hook is failClosed)"),
        costUSD: outcome.costUSD)
    }
    return outcome
  }

  /// Whether a handler runs for this event: right event and a matcher that accepts the
  /// subject (a handler has no `when`/`agent` filter — it can read the payload itself).
  func applies(_ handler: any HookHandler, event: HookEvent, subject: String?) -> Bool {
    guard handler.event == event else { return false }
    if let subject, !HookDefinition.matcherAccepts(handler.matcher, subject: subject) { return false }
    return true
  }

  /// Whether one hook runs for this event: right event, switched on, and every filter it
  /// declares accepts the call — the subject (tool or agent name), the `agent` the event is
  /// about, and the `when` map against the call's arguments.
  func applies(_ hook: HookDefinition, event: HookEvent, subject: String?, payload: HookPayload) -> Bool {
    guard hook.event == event, hook.isEnabled else { return false }
    if let subject, !hook.matches(subject: subject) { return false }
    guard hook.matchesAgent(payload.agentType ?? payload.agent) else { return false }
    return hook.matches(arguments: payload.whenArguments, root: cwd)
  }

  enum RunResult: Equatable {
    /// The hook ran to completion (or was killed and reported a status) — `output` is its
    /// combined stdout+stderr, clipped.
    case exited(code: Int32, output: String)
    /// The hook could not run: failed to start, or timed out and was killed.
    case failed(String)
  }

  func payload(
    for event: HookEvent,
    tool: String?,
    argumentsJSON: String?,
    toolUseId: String?,
    response: String?,
    turnIndex: Int?)
    -> HookPayload
  {
    var input: JSONValue?
    if let argumentsJSON {
      input = (try? JSONDecoder().decode(JSONValue.self, from: Data(argumentsJSON.utf8))) ?? .object([:])
    }
    return HookPayload(
      hookEventName: event.rawValue,
      sessionId: sessionId,
      cwd: cwd?.path ?? FileManager.default.currentDirectoryPath,
      toolName: tool,
      toolInput: input,
      toolUseId: toolUseId,
      toolResponse: response.map { String($0.prefix(Self.maxResponseChars)) },
      agent: agent,
      turnIndex: turnIndex)
  }

  /// The bare payload for a session-level event (UserPromptSubmit, SessionStart/End,
  /// Pre/PostCompact, Notification): identity and cwd; the caller sets the event's field.
  func sessionPayload(for event: HookEvent) -> HookPayload {
    HookPayload(
      hookEventName: event.rawValue,
      sessionId: sessionId,
      cwd: cwd?.path ?? FileManager.default.currentDirectoryPath,
      agent: agent)
  }

  /// The delegation payload for `SubagentStart`/`SubagentStop`. The parent session's id
  /// rides both `session_id` (Claude Code's spelling, so a ported script finds it) and
  /// `parent_session_id`; long text is clipped like a tool response.
  func subagentPayload(
    for event: HookEvent,
    agent: String,
    id: String,
    model: String,
    task: String,
    report: String? = nil,
    steps: Int? = nil,
    toolCalls: Int? = nil,
    costUSD: Double? = nil,
    partial: Bool? = nil)
    -> HookPayload
  {
    HookPayload(
      hookEventName: event.rawValue,
      sessionId: sessionId,
      cwd: cwd?.path ?? FileManager.default.currentDirectoryPath,
      agent: agent,
      agentId: id,
      agentType: agent,
      model: model,
      task: String(task.prefix(Self.maxResponseChars)),
      parentSessionId: sessionId,
      report: report.map { String($0.prefix(Self.maxResponseChars)) },
      steps: steps,
      toolCalls: toolCalls,
      costUSD: costUSD,
      partial: partial)
  }

  /// One command hook, through the same spawn chokepoint as the `bash` tool: payload on stdin
  /// (written off-thread, so a hook that never reads can't deadlock), the wait ends when
  /// `sh` exits (a backgrounded child doesn't hold the turn), SIGTERM→SIGKILL at the
  /// deadline, and the scrubbed environment plus a few `ARNES_*` context variables. A prompt
  /// hook has no command and never reaches the shell — whoever calls this directly gets a
  /// failure, not `sh -c ""`.
  func run(_ hook: HookDefinition, payload: HookPayload) async -> RunResult {
    guard hook.type == .command else {
      return .failed("prompt hook `\(hook.label)` has no command to run")
    }
    let stdin = (try? JSONEncoder().encode(payload)) ?? Data("{}".utf8)
    var extra: [String: String] = [
      "ARNES_HOOK_EVENT": payload.hookEventName,
      "ARNES_TOOL_NAME": payload.toolName ?? "",
      "ARNES_CWD": payload.cwd,
    ]
    if let sessionId { extra["ARNES_SESSION_ID"] = sessionId }
    // The agent this session runs as, or — on the delegation events — the agent being
    // spawned, so a `*`-matched hook can tell who the event is about without parsing stdin.
    if let name = payload.agentType ?? agent { extra["ARNES_AGENT_NAME"] = name }
    if let agentId = payload.agentId { extra["ARNES_AGENT_ID"] = agentId }
    let timeout = hook.timeoutSeconds ?? Self.defaultTimeoutSeconds
    let outcome = await ShellRunner.run(
      hook.command, cwd: cwd, timeoutSeconds: timeout, environment: environment,
      extraEnvironment: extra, stdin: stdin, shell: .sh)
    let label = "hook `\(String(hook.command.prefix(60)))`"
    if outcome.failedToStart {
      return .failed("\(label) failed to start: \(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    if outcome.timedOut {
      return .failed("\(label) timed out after \(timeout)s and was killed")
    }
    if outcome.cancelled {
      return .failed("\(label) was interrupted")
    }
    return .exited(code: outcome.exitStatus, output: Self.clip(outcome.output))
  }

  /// Head + tail of an overlong output, with the elision marked.
  static func clip(_ text: String, max: Int = maxOutputChars) -> String {
    guard text.count > max else { return text }
    let keep = max / 2
    let head = text.prefix(keep)
    let tail = text.suffix(keep)
    return "\(head)\n[… \(text.count - 2 * keep) characters elided …]\n\(tail)"
  }
}

// MARK: - Nested runs

extension HookEvent {
  /// The events a run *inside* the user's session never fires itself — they belong to the
  /// session that contains it. `Stop` is the user's turn end (a subagent's, a panel
  /// candidate's or an eval trial's finish is not), `SubagentStart`/`SubagentStop` are run by
  /// the task tool *around* a nested session, and the session-level events
  /// (`SessionStart`/`SessionEnd`/`UserPromptSubmit`/`Notification`) are about the user's
  /// session, which a nested one is not: its prompt is a task text, and it is never started
  /// or ended the way the user's session is. Everything else — the per-call hooks
  /// (`PreToolUse`/`PostToolUse`/`PostToolUseFailure`/`PermissionRequest`) and the
  /// compaction pair — follows the work wherever it runs, so a guardrail can't be delegated
  /// or fanned out around.
  public static let keptByTheLead: Set<HookEvent> = [
    .stop, .subagentStart, .subagentStop, .sessionStart, .sessionEnd, .userPromptSubmit, .notification,
  ]
}

extension Array where Element == HookDefinition {
  /// What a nested run inherits of these hooks: the per-call and compaction events, with
  /// `HookEvent.keptByTheLead` filtered out. The one filter behind `Configuration.forSubagent`
  /// (a subagent's session), `PanelRunner` (a candidate) and `EvalRunner` (a trial) — so all
  /// three agree on which of the user's hooks reach unattended or delegated work.
  public var forNestedRun: [HookDefinition] {
    filter { !HookEvent.keptByTheLead.contains($0.event) }
  }
}

extension Array where Element == any HookHandler {
  /// The in-process twin of `[HookDefinition].forNestedRun`: handlers for the events a nested
  /// run keeps, so definitions and handlers are filtered by one set.
  public var forNestedRun: [any HookHandler] {
    filter { !HookEvent.keptByTheLead.contains($0.event) }
  }
}
