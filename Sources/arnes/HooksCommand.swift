import ArgumentParser
import ArnesKit
import Foundation

// MARK: - hooks

/// `arnes hooks` — list the lifecycle hooks configured for this directory: which event,
/// what they match, where each came from and whether it will run. `arnes hooks trust`
/// approves this project's hooks by content hash; `arnes hooks test` dry-runs an event.
struct Hooks: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "hooks",
    abstract: "List lifecycle hooks (PreToolUse / PostToolUse / PostToolUseFailure / PermissionRequest / Stop / SubagentStart / SubagentStop / UserPromptSubmit / SessionStart / SessionEnd / PreCompact / PostCompact / Notification).",
    subcommands: [HooksList.self, HooksTrust.self, HooksTest.self],
    defaultSubcommand: HooksList.self)
}

// MARK: - hooks list

struct HooksList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List hooks from ~/.arnes/hooks.json and, in a trusted directory, ./.arnes/hooks.json.")

  @Flag(help: "Print one JSON array of {id, event, matcher, type, command_or_prompt, model, when, agent, enabled, fail_closed, source, trusted, trust} rows instead of text.")
  var json = false

  func run() async throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    do {
      _ = try HookConfig.load()
    } catch {
      guard !json else { throw ValidationError("\(HookConfig.defaultURL.path) is invalid: \(error)") }
      print(ANSI.yellow("⚠ \(HookConfig.defaultURL.path) is invalid: \(error)"))
      return
    }
    let loaded = (try? HookConfig.load(project: cwd)) ?? LoadedHooks()
    if json {
      let defaultPromptModel = Self.defaultPromptModel()
      for notice in loaded.notices { JSONOut.stderr(TerminalText.sanitize(notice)) }
      try JSONOut.print(loaded.hooks.map { HookRow($0, defaultPromptModel: defaultPromptModel) })
      return
    }
    guard !loaded.isEmpty else {
      print("no hooks configured — add them to \(HooksFormat.abbreviate(HookConfig.defaultURL.path))")
      print(ANSI.dim("""

        example:
        {
          "hooks": [
            {"event": "PreToolUse", "matcher": "bash", "when": {"command": "^git (push|reset --hard)"},
             "id": "no-force-push", "command": "my-guardrail.sh"},
            {"event": "PostToolUse", "matcher": "edit_file|write_file", "when": {"path": "**/*.swift"},
             "command": "swiftformat ."},
            {"event": "Stop", "command": "swift test 2>&1 | tail -3"},
            {"event": "SubagentStart", "matcher": "explore|reviewer", "command": "my-delegation-policy.sh"},
            {"event": "SubagentStop", "matcher": "*", "command": "my-report-check.sh"},
            {"event": "SessionStart", "matcher": "startup|resume", "command": "git status --short | head -20"},
            {"event": "UserPromptSubmit", "when": {"prompt": "(?i)password"}, "command": "echo 'no secrets in prompts' >&2; exit 2"},
            {"event": "PreCompact", "matcher": "manual", "command": "echo 'keep every file path mentioned'"},
            {"event": "PreToolUse", "matcher": "bash", "type": "prompt", "model": "cheap-model-alias",
             "prompt": "Does this command delete or overwrite anything outside the working tree? $ARGUMENTS"}
          ]
        }
        """))
      return
    }
    // A prompt hook without its own `model` runs on the active provider's `bashJudge`; with
    // neither it is unusable, and the listing says so instead of letting it look armed.
    let defaultPromptModel = Self.defaultPromptModel()
    for hook in loaded.hooks {
      for line in HooksFormat.rows(for: hook, defaultPromptModel: defaultPromptModel) { print(line) }
    }
    for notice in loaded.notices { print(ANSI.yellow(TerminalText.sanitize(notice))) }
    let active = loaded.active.count
    print(ANSI.dim("\n\(active) active hook\(active == 1 ? "" : "s") of \(loaded.hooks.count) "
      + "— PreToolUse runs before the permission prompt "
      + "(exit 2 or permissionDecision deny blocks; ask forces a prompt; allow skips it for ordinary mutations), "
      + "PostToolUse feeds output back to the model (continue:false ends the turn), PostToolUseFailure does the same "
      + "for a call that returned an error, PermissionRequest runs right before a human would be asked "
      + "(decision.behavior deny refuses; allow answers the prompt for ordinary mutations only), and Stop runs at "
      + "turn end (exit 2 or decision:block with a reason sends the model back to work, at most 3 times per turn).\n"
      + "SubagentStart runs before a subagent is spawned and can veto the delegation (exit 2 blocks it; the lead "
      + "gets the reason instead of a report); SubagentStop runs after the nested run and its output is appended "
      + "to the report. Both match on the agent name, not a tool name; a subagent's own tool calls run the "
      + "PreToolUse/PostToolUse hooks, so a guardrail can't be delegated around.\n"
      + "UserPromptSubmit runs before the user's text is sent (exit 2 blocks the prompt; stdout rides it as context), "
      + "SessionStart (matcher: startup/resume/clear/compact) adds its stdout to the system prompt, SessionEnd "
      + "(exit/clear/other) is advisory under a 1.5s budget, PreCompact (manual/auto) can cancel a /compact and its "
      + "stdout steers the summarizer, PostCompact runs after, Notification (permission_prompt, user_question) fires before the "
      + "REPL asks a question.\n"
      + "`when` narrows a hook to the calls it cares about — a regex per string argument, a glob for "
      + "path/file_path/old_path/new_path; every entry must match and a missing argument never does. The session "
      + "events expose prompt, source, reason, trigger, error, notification_type and message to it. A key absent at "
      + "the top level of an edit_file call is matched against each element of its `edits` array and fires when any "
      + "element matches, so a guardrail on old_string/new_string covers the multi-edit form too.\n"
      + "Project hooks (./.arnes/hooks.json) run only in a trusted directory and only after `arnes hooks trust`; "
      + "they may deny, ask and feed text back, never allow a call or rewrite its arguments.\n"
      + "Each hook reads the event as JSON on stdin (hook_event_name, tool_name, tool_input, cwd, agent_type, "
      + "agent_id, task, report, prompt, source, trigger, stop_hook_active, …); other non-zero exits are reported, "
      + "not enforced, unless the hook sets \"failClosed\": true.\n"
      + "A \"type\": \"prompt\" hook asks a model instead of running a command: its \"prompt\" (with $ARGUMENTS "
      + "replaced by the same JSON) goes to \"model\" — or the provider's bashJudge — and the reply OK / BLOCK: "
      + "reason / ASK: reason is read as the decision. Escalate-only: it can deny or ask, never allow, rewrite or "
      + "end the turn; an error or an unreadable reply is a notice, not a verdict; replies are cached per payload "
      + "and the spend lands in the turn's cost."))
  }

  /// The active provider's `bashJudge`, read straight from the config — the listing must not
  /// need a resolvable key, so the runtime isn't built here.
  static func defaultPromptModel() -> String? {
    guard let config = try? ArnesConfig.load() else { return nil }
    let entry = config.allProviders[ProviderResolver.activeName(config: config)]
    return entry?.bashJudge.flatMap { $0.isEmpty ? nil : $0 }
  }
}

// MARK: - hooks trust

/// `arnes hooks trust` — record this directory's hook definitions as approved, by content
/// hash. Codex's model: the user reads the commands once, and any later edit (or a new hook
/// arriving with a `git pull`) revokes trust until they look again.
struct HooksTrust: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "trust",
    abstract: "Approve this directory's .arnes/hooks.json by content hash (or --forget them).",
    discussion: """
      Project hooks run shell commands around every tool call, so they are gated twice: the
      directory must be trusted (`arnes trust`) and each hook definition must be one you
      approved here. Editing a hook, or pulling a new one, revokes that hook until you run
      this again. A project hook can only deny, ask, or feed text back — never approve a
      call or rewrite its arguments.
      """)

  @Argument(help: "Directory (default: the current one).")
  var directory: String?

  @Flag(help: "Forget this directory's approved hooks instead of recording them.")
  var forget = false

  func run() async throws {
    let target = URL(fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath)
    let store = ProjectTrustStore()
    if forget {
      try store.trustHooks([], in: target)
      print("forgot approved hooks for \(HooksFormat.abbreviate(target.path))")
      return
    }
    let url = HookConfig.projectURL(in: target)
    guard FileManager.default.fileExists(atPath: url.path) else {
      print("no project hooks at \(HooksFormat.abbreviate(url.path))")
      return
    }
    let hooks = HookConfig.projectHooks(in: target)
    guard !hooks.isEmpty else {
      // Either an empty list or a file that doesn't parse; say which.
      let invalid = (try? HookConfig.load(from: url)) == nil
      print(invalid
        ? ANSI.yellow("⚠ \(HooksFormat.abbreviate(url.path)) is invalid — nothing trusted")
        : "\(HooksFormat.abbreviate(url.path)) defines no hooks — nothing to trust")
      return
    }
    if SecureFiles.isWritableByOthers(url) {
      print(ANSI.yellow("⚠ \(url.path) is writable by other users — chmod 644 it; its hooks run commands"))
    }
    print("approving \(hooks.count) hook\(hooks.count == 1 ? "" : "s") from \(HooksFormat.abbreviate(url.path)):")
    for hook in hooks {
      for line in HooksFormat.rows(
        for: LoadedHook(definition: hook, trust: .trusted), showTrust: false,
        defaultPromptModel: HooksList.defaultPromptModel())
      {
        print(line)
      }
    }
    try store.trustHooks(hooks.map(\.fingerprint), in: target)
    if store.isTrusted(target) {
      print(ANSI.dim("recorded in \(HooksFormat.abbreviate(store.url.path)) — they run until the file changes"))
    } else {
      // Hashes alone don't arm them: the directory-trust question is the other half.
      print(ANSI.yellow("note: \(HooksFormat.abbreviate(target.path)) is not a trusted directory yet — "
        + "run `arnes trust` there (or answer yes in the REPL) before these hooks load"))
    }
  }
}

// MARK: - hooks test

/// `arnes hooks test <event> [subject] [args-json]` — dry-run one event's hooks against a
/// synthetic call and report per hook whether it applied (and which filter excluded it), how
/// it exited, what it printed and what the loop would have decided. The commands really run;
/// no tool does. The point is the check a real run can't give you: a mistyped `when` path
/// glob doesn't fail loudly, it just never fires — here it reads `skipped (when: path)`.
struct HooksTest: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "test",
    abstract: "Dry-run one event's hooks against a synthetic call: which apply, what each prints, what the loop would decide.",
    discussion: """
      The hook commands really run (in the current directory, with the environment a run
      gives them) — no tool does, and nothing is recorded. Every hook of the event is
      reported: skipped ones say which filter excluded them (disabled, matcher, agent, when:
      <keys>, or the project trust gate), the rest show exit code, decision and raw output. A
      `type: prompt` hook that applies is listed but not asked — a dry run spends no model
      request — and counts as one that would run.

        arnes hooks test PreToolUse bash '{"command":"rm -rf /tmp/x"}'
        arnes hooks test PreToolUse edit_file '{"path":"src/x.swift"}' --agent explore
        arnes hooks test SubagentStart explore
        arnes hooks test UserPromptSubmit "delete the production database"
        arnes hooks test Stop

      Exit 0 whatever the hooks decide (it is a dry run); 64 for an unknown event.
      """)

  @Argument(help: "The event: \(HookEvent.allCases.map(\.rawValue).joined(separator: ", ")).")
  var event: String

  @Argument(help: "What the matcher is tested against — the tool name (tool events), the agent name (SubagentStart/SubagentStop), the source/reason/trigger/type (session events; defaults startup/exit/manual/permission_prompt), or the prompt text (UserPromptSubmit). Ignored for Stop.")
  var subject: String?

  @Argument(help: "The tool arguments as a JSON object, for the tool events — what `when` and the hook's stdin see.")
  var argumentsJSON: String?

  @Option(help: "Run as this subagent: the payload's `agent` and any `agent` filter see it, so a hook scoped to delegated work fires here and not for the lead. Also the default agent name for SubagentStart/SubagentStop.")
  var agent: String?

  func validate() throws {
    let parsed = try Self.parseEvent(event)
    if parsed.matcherSubject == "tool", subject == nil {
      throw ValidationError("\(parsed.rawValue) needs a tool name: arnes hooks test \(parsed.rawValue) <tool> ['{\"arg\":…}']")
    }
    if parsed.matchesAgentName, subject == nil, agent == nil {
      throw ValidationError("\(parsed.rawValue) needs an agent name: arnes hooks test \(parsed.rawValue) <agent>")
    }
    if let argumentsJSON {
      guard let data = argumentsJSON.data(using: .utf8),
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil
      else {
        throw ValidationError("the arguments must be a JSON object, e.g. '{\"command\":\"git status\"}'")
      }
    }
  }

  func run() async throws {
    let parsed = try Self.parseEvent(event)
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    do {
      _ = try HookConfig.load()
    } catch {
      print(ANSI.yellow("⚠ \(HookConfig.defaultURL.path) is invalid: \(error) — nothing to test"))
      return
    }
    // The same layering a run gets: the user's file plus this directory's hash-trusted
    // project hooks; and the same scrubbed environment (`shellEnvironment` in the config,
    // the built-in provider token names withheld plus every configured provider's own key
    // variable — a run withholds the active provider's; a dry run doesn't resolve a provider,
    // so it withholds all of them rather than hand a hook a token a run never would).
    let loaded = (try? HookConfig.load(project: cwd)) ?? LoadedHooks()
    let config = (try? ArnesConfig.load()) ?? nil
    let policy = config?.shellEnvironment ?? ShellEnvironmentPolicy()
    let configuredKeys = Set((config?.providers ?? [:]).values.compactMap(\.apiKeyEnv))
    let lines = await Self.report(
      loaded: loaded, event: parsed, subject: subject, argumentsJSON: argumentsJSON, agent: agent,
      cwd: cwd,
      environment: SubprocessEnvironment(
        policy: policy, redactedKeys: SubprocessEnvironment.providerTokenKeys.union(configuredKeys)),
      defaultPromptModel: HooksList.defaultPromptModel())
    for line in lines { print(line) }
  }

  /// The event named on the command line, or a usage error naming the valid ones.
  static func parseEvent(_ name: String) throws -> HookEvent {
    if let event = HookEvent(rawValue: name) { return event }
    // Case-insensitive as a courtesy; the listing prints the canonical spelling.
    if let event = HookEvent.allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) {
      return event
    }
    throw ValidationError(
      "unknown hook event '\(name)' — one of: \(HookEvent.allCases.map(\.rawValue).joined(separator: ", "))")
  }

  /// How many lines of a hook's raw output are shown.
  static let outputLineCap = 20

  /// The whole report, as lines: a red warning first (then the loader's own notices — an
  /// unreadable or loose-permission file, the way `arnes hooks` shows them), then one block
  /// per configured hook of the event — `HooksFormat`'s listing rows, a status line, and the
  /// raw output indented. Pure over `loaded` (no process state read), so tests inject their
  /// own hooks.
  static func report(
    loaded: LoadedHooks,
    event: HookEvent,
    subject: String?,
    argumentsJSON: String?,
    agent: String?,
    cwd: URL,
    environment: SubprocessEnvironment = .default,
    defaultPromptModel: String? = nil)
    async -> [String]
  {
    var lines = [
      ANSI.red("⚠ dry run: the hook commands below really run (in \(HooksFormat.abbreviate(cwd.path))) — no tool does, nothing is recorded"),
    ]
    for notice in loaded.notices {
      lines.append(ANSI.yellow(TerminalText.sanitize(notice)))
    }
    let configured = loaded.hooks.filter { $0.definition.event == event }
    guard !configured.isEmpty else {
      lines.append("no \(event.rawValue) hooks configured (\(loaded.hooks.count) hook\(loaded.hooks.count == 1 ? "" : "s") in total)")
      return lines
    }
    let engine = HookEngine(
      hooks: loaded.active, cwd: cwd, environment: environment,
      sessionId: HookEngine.dryRunSessionId, agent: agent)
    let reports = await engine.dryRun(event: event, subject: subject, argumentsJSON: argumentsJSON)
    let byFingerprint = Dictionary(reports.map { ($0.hook.fingerprint, $0) }, uniquingKeysWith: { first, _ in first })
    var applied = 0
    // `LoadedHooks.active` runs an identical definition once (a repo that copies a user hook
    // doesn't run it twice); the report says so on the copy instead of counting it twice.
    var reported: Set<String> = []
    for hook in configured {
      lines.append("")
      lines.append(contentsOf: HooksFormat.rows(for: hook, defaultPromptModel: defaultPromptModel))
      guard hook.trusted else {
        lines.append(ANSI.yellow("  skipped (\(trustReason(hook)))"))
        continue
      }
      let fingerprint = hook.definition.fingerprint
      guard reported.insert(fingerprint).inserted else {
        lines.append(ANSI.dim("  skipped (identical to a hook above — a run executes it once)"))
        continue
      }
      guard let report = byFingerprint[fingerprint] else { continue }
      if report.applied { applied += 1 }
      lines.append(contentsOf: statusLines(report))
    }
    lines.append("")
    lines.append(ANSI.dim("\(applied) of \(configured.count) \(event.rawValue) hook\(configured.count == 1 ? "" : "s") would run for this call"))
    return lines
  }

  /// One hook's verdict lines: why it was skipped, or how it ran plus its output.
  static func statusLines(_ report: HookEngine.DryRunReport) -> [String] {
    if let skip = report.skipped {
      let detail: String
      switch skip {
      case .when: detail = "when: \(report.failedWhenKeys.joined(separator: ", "))"
      case .prompt: detail = "prompt hook — applies, but a dry run asks no model"
      default: detail = skip.rawValue
      }
      return [ANSI.dim("  skipped (\(detail))")]
    }
    var status: String
    if let failure = report.failure {
      status = ANSI.yellow("  could not run") + ANSI.dim(" · \(TerminalText.sanitize(failure))")
    } else {
      status = "  ran · exit \(report.exitCode ?? 0)"
    }
    if let outcome = report.outcome {
      status += " · " + decision(outcome)
      if outcome.updatedInput != nil { status += " · updatedInput" }
      if !outcome.additionalContext.isEmpty {
        status += " · context: " + TerminalText.sanitize(String(outcome.additionalContext.joined(separator: " ").prefix(60)))
      }
      if !outcome.continueRun { status += " · continue: false" }
      if !outcome.feedback.isEmpty, report.failure == nil {
        status += " · feedback: " + TerminalText.sanitize(String(outcome.feedback.prefix(60)))
      }
      for error in outcome.errors where report.failure == nil {
        status += ANSI.yellow(" · " + TerminalText.sanitize(error))
      }
    }
    var lines = [status]
    let trimmed = report.output.trimmingCharacters(in: .whitespacesAndNewlines)
    let output = trimmed.isEmpty
      ? []
      : trimmed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for line in output.prefix(outputLineCap) {
      lines.append(ANSI.dim("  │ " + TerminalText.sanitize(line)))
    }
    if output.count > outputLineCap {
      let more = output.count - outputLineCap
      lines.append(ANSI.dim("  │ … \(more) more line\(more == 1 ? "" : "s")"))
    }
    return lines
  }

  /// The decision as the loop would read it, colored by weight.
  static func decision(_ outcome: HookOutcome) -> String {
    switch outcome.decision {
    case .none: return "no decision"
    case .allow: return ANSI.green("allow")
    case .ask(let reason):
      return ANSI.yellow("ask") + (reason.map { ": " + TerminalText.sanitize($0) } ?? "")
    case .deny(let reason): return ANSI.yellow("deny") + ": " + TerminalText.sanitize(reason)
    }
  }

  static func trustReason(_ hook: LoadedHook) -> String {
    switch hook.trust {
    case .trusted: return hook.definition.isEnabled ? "trusted" : "disabled"
    case .changed: return "changed since trusted — run `arnes hooks trust`"
    case .untrustedDirectory: return "directory not trusted — run `arnes trust`, then `arnes hooks trust`"
    }
  }
}

// MARK: - HooksFormat

/// Shared rendering for the hook listings.
enum HooksFormat {
  /// Two lines per hook: the event with its scope and tags, then the command (or, for a
  /// prompt hook, the prompt). `defaultPromptModel` is the provider's `bashJudge`, what a
  /// prompt hook without `model` would run on; nil with no `model` marks the hook unusable.
  static func rows(for hook: LoadedHook, showTrust: Bool = true, defaultPromptModel: String? = nil) -> [String] {
    let definition = hook.definition
    // The matcher is a tool name for the tool events, an agent name for the delegation ones,
    // the source/reason/trigger/type for the session events — and nothing for Stop and
    // UserPromptSubmit, which always fire.
    let subject = definition.event.matcherSubject.map { "all \($0)s" } ?? "always"
    let scope = definition.matcher.map { $0 == "*" ? subject : $0 } ?? subject
    var tags = [scope]
    switch definition.type {
    case .command:
      tags.append("command")
    case .prompt:
      if let model = definition.model ?? defaultPromptModel {
        tags.append("prompt \(model)")
      } else {
        tags.append(ANSI.yellow("prompt — no model: set \"model\" or the provider's bashJudge"))
      }
    }
    if let agent = definition.agent { tags.append("agent \(agent)") }
    if let when = definition.when, !when.isEmpty {
      tags.append("when " + when.keys.sorted().map { "\($0)=\(when[$0] ?? "")" }.joined(separator: ", "))
    }
    tags.append("\(definition.timeoutSeconds ?? HookEngine.defaultTimeoutSeconds)s")
    if definition.failClosed == true { tags.append("fail-closed") }
    tags.append(definition.source.rawValue)
    if showTrust {
      switch hook.trust {
      case .trusted: break
      case .changed: tags.append(ANSI.yellow("changed — run `arnes hooks trust`"))
      case .untrustedDirectory: tags.append(ANSI.yellow("directory not trusted"))
      }
    }
    if !definition.isEnabled { tags.append(ANSI.dim("disabled")) }
    var rows = [TerminalText.sanitize(
      ANSI.bold(definition.event.rawValue)
        + (definition.id.map { " " + $0 } ?? "")
        + ANSI.dim("  (\(tags.joined(separator: " · ")))"))]
    if let description = definition.description {
      rows.append(TerminalText.sanitize(ANSI.dim("  \(description)")))
    }
    let body = definition.type == .prompt ? (definition.prompt ?? "") : definition.command
    rows.append(TerminalText.sanitize("  \(body)"))
    return rows
  }

  static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}
