import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

/// Single source of truth for the CLI version — shown in the header and `--version`.
let arnesVersion = "0.7.0"

// MARK: - Shared setup

func parseDialect(_ raw: String) throws -> DialectOverride {
  guard let dialect = DialectOverride(rawValue: raw) else {
    throw ValidationError("unknown dialect '\(raw)' — use auto, chat, messages, or responses")
  }
  return dialect
}

/// The reasoning-effort dial, or nil when the flag is unset (leaving requests unchanged).
func parseEffort(_ raw: String?) throws -> Reasoning.Effort? {
  guard let raw, !raw.isEmpty else { return nil }
  guard let effort = Reasoning.Effort(rawValue: raw) else {
    throw ValidationError("unknown effort '\(raw)' — use minimal, low, medium, high, xhigh, max, or none")
  }
  return effort
}

/// The permission mode, or `default` when the flag is unset.
func parsePermissionMode(_ raw: String?) throws -> PermissionMode {
  guard let raw, !raw.isEmpty else { return .default }
  guard let mode = PermissionMode(rawValue: raw) else {
    throw ValidationError("unknown permission mode '\(raw)' — use default, acceptEdits, plan, or bypass")
  }
  return mode
}

// Provider resolution (key, base URL, manifest source) lives in Runtime.swift:
// `ArnesRuntime.make(providerOptions)` is what every networked command starts with.

// MARK: - Root

@main
struct Arnes: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "arnes",
    abstract: "Arnes — a model-adaptive agent harness for OpenRouter and OpenAI-compatible gateways.",
    version: arnesVersion,
    subcommands: [Interactive.self, Chat.self, Do.self, Resume.self, Models.self, Status.self, Providers.self, Runs.self, Sessions.self, Eval.self, Evals.self, Probe.self, Mcp.self, Skills.self, Agents.self, Hooks.self, Trust.self, Doctor.self, Debug.self, ReviewCommand.self, MemoryCommand.self, InitCommand.self, ACPCommand.self],
    defaultSubcommand: Interactive.self)
}

// MARK: - chat

struct Chat: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Stream a one-shot chat reply.")

  @Argument(help: "The prompt.")
  var prompt: String

  @Option(name: .shortAndLong, help: "Model slug (default: the provider's default model — openrouter/auto on OpenRouter).")
  var model: String?

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  @OptionGroup var providerOptions: ProviderOptions

  func run() async throws {
    let runtime = try ArnesRuntime.make(providerOptions)
    let traits = runtime.traits
    let fallbacks = fallback.split(separator: ",").map(String.init)
    let stream = try await runtime.service.chatCompletionStream(
      ChatCompletionRequest(
        model: try runtime.model(model),
        models: traits.fallbackStyle == .models && !fallbacks.isEmpty ? fallbacks : nil,
        messages: [.user(prompt)],
        streamOptions: traits.requestsStreamUsage ? StreamOptions(includeUsage: true) : nil,
        extraBody: traits.fallbackStyle == .litellmFallbacks && !fallbacks.isEmpty
          ? ["fallbacks": .array(fallbacks.map { .string($0) })]
          : nil))
    var cost: Double?
    var routedModel: String?
    for try await chunk in stream {
      if let delta = chunk.choices?.first?.delta?.content {
        print(TerminalText.sanitize(delta), terminator: "")
      }
      if let usage = chunk.usage { cost = usage.cost }
      if let model = chunk.model { routedModel = model }
    }
    print()
    if let routedModel {
      let priced = cost.map { " · $\(String(format: "%.6f", $0))" } ?? ""
      FileHandle.standardError.write(Data(TerminalText.sanitize("[\(routedModel)\(priced)]\n").utf8))
    }
  }
}

// MARK: - do

struct Do: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run the agent loop on a task (read/write/bash tools).",
    discussion: """
      Exit codes: 0 completed (or plan proposed) · 1 error · 2 --verify said FAIL · \
      3 stopped short (max_steps, budget, timeout, denied_loop, hook_stopped, …) · \
      4 a tool call was refused and --fail-on-denied is set · 64 usage · \
      130 interrupted (SIGINT) · 143 terminated (SIGTERM).
      """)

  @Argument(help: "The task. Omit it (or pass `-`) to read the task from stdin; when both are given and stdin is piped, its contents ride along in a <stdin> block.")
  var task: String?

  @Option(name: .shortAndLong, help: "Model slug (default: the provider's default model). With --panel, a comma-separated list fans out to those models.")
  var model: String?

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  @Option(help: "Verify the outcome with this (cheaper) model after the run.")
  var verify: String?

  @Option(help: "Stop once the run's cost reaches this many USD (a budget stop; estimated on gateways that don't report cost).")
  var budget: Double?

  @Option(help: "Reasoning effort for models that support it: minimal, low, medium, high, xhigh, max, none.")
  var effort: String?

  @Option(name: .customLong("permission-mode"), help: "Permission mode: default, acceptEdits (auto in-tree edits), plan (read-only dry run: every gated tool is denied, the final reply is the plan and nothing executes), or bypass.")
  var permissionMode: String?

  @Flag(
    name: [.customShort("y"), .customLong("yes")],
    help: "Auto-approve ordinary work: mutations inside the working directory (bash, write_file, edit_file, MCP). Reads and writes outside it — and credential, shell-startup or protected paths — stay denied; widen the run with --add-dir instead. Without --yes even ordinary mutations are denied and the model is told to report instead.")
  var yes = false

  @Flag(help: "Deny all gated tools explicitly (read-only run, no hint about --yes).")
  var safe = false

  @Option(
    name: .customLong("add-dir"),
    help: ArgumentHelp(
      "Also treat this directory as inside the run: reads and writes there are ordinary work instead of gated escapes. Repeatable.",
      valueName: "path"))
  var addDir: [String] = []

  @Flag(help: "Load this directory's own .arnes/.claude skills and agents and remember it as trusted (otherwise untrusted project definitions are skipped).")
  var trustProject = false

  @Option(help: "Wire dialect: auto (native per model family), chat, messages, or responses.")
  var dialect = "auto"

  @Option(help: "Fan the task to N isolated candidates (models from -m, cycled to N) and keep the judged winner.")
  var panel: Int?

  @Option(help: "Judge model for --panel (default: the provider's default model).")
  var judge: String?

  @Flag(help: "With --panel: keep the winner in its snapshot instead of applying its changes here.")
  var noApply = false

  @Option(
    name: .customLong("panel-on-fail"),
    help: ArgumentHelp(
      "With --verify and --yes: when the verifier says FAIL, re-run the task as a panel of N candidates (models from -m, cycled to N; the first entry ran the initial attempt) over a snapshot of the working tree taken before the run, apply the judged winner here, re-verify it and exit by that verdict (0 PASS, 2 FAIL). The failed attempt is kept beside the snapshot — `arnes agents apply <layout>` restores it. 0 switches a `policies.panelOnVerifierFail` config default off for this run; N ≥ 2 otherwise. Not with --panel.",
      valueName: "N"))
  var panelOnFail: Int?

  @Flag(help: "Skip connecting MCP servers from ~/.arnes/mcp.json.")
  var noMcp = false

  @Flag(help: "Run unconfined: skip the OS sandbox that otherwise wraps an unattended run (--yes / --panel) on a platform that supports it.")
  var noSandbox = false

  @Flag(help: "Skip loading skills from .arnes/skills, .claude/skills, ~/.arnes/skills and ~/.claude/skills.")
  var noSkills = false

  @Flag(help: "Disable subagents (the task tool and .arnes/.claude agents).")
  var noAgents = false

  @Flag(name: .customLong("no-memory"), help: "Skip the project's memory (~/.arnes/memory/<project>/MEMORY.md): no # Memory section, and the directory stays harness state the tools cannot touch. Memory is read by default; writes there are .sensitive — refused under --yes unless --add-dir names the memory directory.")
  var noMemory = false

  @Flag(help: "Persist this run's transcript, so it can be resumed (`arnes resume <id>`) or captured (`arnes evals capture --session <id>`). Off by default: headless runs leave no trace.")
  var session = false

  @Option(
    name: .customLong("session-id"),
    help: ArgumentHelp(
      "Use this UUID as the run's session id instead of a fresh one, so a pipeline can name the transcript it will resume (--session persists it; the run records carry the id either way). Refused when a saved session already has the id — --resume that one instead. Not with --resume/--continue/--fork/--panel.",
      valueName: "uuid"))
  var sessionId: String?

  @Option(
    name: .customLong("agent-model"),
    help: ArgumentHelp(
      "Pin a subagent to a model: <agent>=<model>. Repeatable.",
      valueName: "agent=model"))
  var agentModel: [String] = []

  @Option(
    name: [.customShort("C"), .customLong("cwd")],
    help: ArgumentHelp(
      "Run in this directory: tools, instruction files, trust and the sandbox root all follow it.",
      valueName: "dir"))
  var workingDirectoryPath: String?

  @Option(name: .customLong("max-steps"), help: "Stop the turn after this many model steps (default unlimited — the loop guard and --budget are the guardrails) — stop_reason max_steps, exit 3.")
  var maxSteps: Int?

  @Option(help: "Wall-clock limit in seconds. At the deadline the run is interrupted (its record says interrupted) and reported as stop_reason timeout, exit 3.")
  var timeout: Double?

  @Option(help: "Keep a completed session and its managed services alive for this many seconds after emitting the result (0...3600, default 0). For external verifiers; no further agent steps. SIGINT/SIGTERM closes it early. Not with --panel or --verify.")
  var keepAlive: Int = 0

  @Flag(help: "Reproducible CI mode: no MCP servers, skills, subagents, hooks, project instruction files or memory — only the harness's own tools and prompt.")
  var bare = false

  @Option(
    name: .customLong("output-format"),
    help: "text (the human-readable lines, default) · json (nothing on stdout until one result object at the end) · stream-json (one JSON object per line: init, every event, then the result). Not available with --panel.")
  var outputFormat: HeadlessOutputFormat = .text

  @Option(
    name: .customLong("output-last-message"),
    help: ArgumentHelp("Write the final assistant message to this file (atomically) when the run ends.", valueName: "path"))
  var outputLastMessage: String?

  @Flag(name: .customLong("include-partial"), help: "With --output-format stream-json: also stream text/reasoning deltas as they arrive.")
  var includePartial = false

  @Flag(help: "With a JSON output format: mirror the text progress lines to stderr.")
  var verbose = false

  @Flag(name: .customLong("fail-on-denied"), help: "Exit 4 when any tool call was refused (permission gate or hook), even if the run completed.")
  var failOnDenied = false

  @Option(
    help: ArgumentHelp(
      "Continue a saved session (id, unique id prefix, or name — see `arnes sessions`): the task runs as its next turn and the transcript is appended to. The transcript's model and effort apply unless -m / --effort name others; --budget is this run's allowance on top of what the session already spent (the figures a budget stop reports are session-cumulative).",
      valueName: "session"))
  var resume: String?

  @Flag(name: .customLong("continue"), help: "Continue the most recent saved session (see --resume).")
  var continueMostRecent = false

  @Flag(help: "With --resume/--continue: continue in a copy of the session; the original transcript is left where it was.")
  var fork = false

  @Option(help: "Name the fork (with --fork).")
  var name: String?

  @Option(
    name: .customLong("append-system-prompt"),
    help: ArgumentHelp(
      "Append this text to the system prompt — after the prompt pack, instruction files, environment block and tool sections (after the --agent role too). There is no replace: packs own the base prompt.",
      valueName: "text"))
  var appendSystemPrompt: String?

  @Option(
    name: .customLong("append-system-prompt-file"),
    help: ArgumentHelp(
      "Append this file's contents to the system prompt (after --append-system-prompt when both are given; 64 KB cap).",
      valueName: "path"))
  var appendSystemPromptFile: String?

  @Option(
    name: .customLong("agent"),
    help: ArgumentHelp(
      "Run as this agent: its body becomes the lead's role, its tools/disallowedTools scope the toolset (an explicit tools list leaves delegation out too, unless --allowed-tools names task), and its model, effort, maxTurns and budget apply unless the flag names one; permissionMode readOnly makes the run read-only. Built-ins (general, explore), .arnes/.claude agents (trusted directories) and --agents definitions.",
      valueName: "name"))
  var agentName: String?

  @Option(
    help: ArgumentHelp(
      "Inline agent definitions — Claude Code's JSON ({\"name\": {\"description\", \"prompt\", \"tools\", \"model\", …}}, or an array of such objects with a \"name\" key), or @path to a file holding it (64 KB cap). Available to --agent and as subagents; an inline agent shadows a discovered one of the same name.",
      valueName: "json|@path"))
  var agents: String?

  @Option(
    name: .customLong("allowed-tools"),
    help: ArgumentHelp(
      "Keep only these tools (exact names or prefix globs like mcp__github__*; Claude Code spellings such as Read/Edit/Bash/Task accepted). Repeatable or comma-separated; an empty value (\"\") means no tools. Applied before subagents are built, so they inherit the same ceiling. Argument rules (Bash(git status:*)) belong in ~/.arnes/rules.json, not here.",
      valueName: "names"))
  var allowedTools: [String] = []

  @Option(
    name: .customLong("disallowed-tools"),
    help: ArgumentHelp(
      "Remove these tools (same spellings as --allowed-tools; disallow wins where both name a tool). `--disallowed-tools task` removes delegation.",
      valueName: "names"))
  var disallowedTools: [String] = []

  @Option(
    name: .customLong("output-schema"),
    help: ArgumentHelp(
      "Ask for the final answer as JSON matching this schema (a file path or inline JSON object); the envelope's structured_output carries it, exit 3 when the model can't produce a valid one. Sent as response_format only to models whose manifest advertises it, otherwise as an instruction.",
      valueName: "file|json"))
  var outputSchema: String?

  @OptionGroup var mcpOptions: MCPOptions

  @OptionGroup var providerOptions: ProviderOptions

  /// Runs before `run()` (ArgumentParser calls it after parsing), so a refused combination
  /// costs no side effect — no provider resolved, no MCP server started, no notice printed.
  ///
  /// `--yes` stays the one consent switch for an unattended run. `acceptEdits` and `bypass`
  /// pre-approve work *before* the delegate is consulted (`Session.permissionDenial`), so
  /// without `--yes` they would run mutations past the read-only delegate, unsandboxed
  /// (`--yes` is what turns the sandbox on) and past the judge's headless veto, under a
  /// stderr line claiming the run is read-only — and `--safe` promises the same read-only
  /// run, so a widening mode contradicts it too. A panel never reaches the configuration
  /// this flag feeds: candidates run unattended in their snapshots, so a mode would be
  /// silently ignored — and `plan` ignored means a dry run that applies a winner's diff.
  func validate() throws {
    guard (0...3600).contains(keepAlive) else {
      throw ValidationError("--keep-alive must be between 0 and 3600 seconds.")
    }
    if keepAlive > 0, panel != nil || verify != nil {
      throw ValidationError("--keep-alive does not combine with --panel or --verify.")
    }
    if let maxSteps, maxSteps < 1 {
      throw ValidationError("--max-steps must be at least 1.")
    }
    if let timeout, timeout <= 0 {
      throw ValidationError("--timeout must be a positive number of seconds.")
    }
    // Session continuation: one way to name the session, a fork needs one, and a panel is
    // N throwaway candidate runs — not a session's next turn.
    if resume != nil, continueMostRecent {
      throw ValidationError("--resume and --continue don't combine: name the session, or take the most recent one.")
    }
    if fork, resume == nil, !continueMostRecent {
      throw ValidationError("--fork needs a session to fork: pass --resume <session> or --continue.")
    }
    if name != nil, !fork {
      throw ValidationError("--name names a fork — pass --fork too.")
    }
    if panel != nil, resume != nil || continueMostRecent || fork {
      throw ValidationError("--panel and --resume/--continue/--fork don't combine: a panel is N throwaway candidate runs, not a session's next turn.")
    }
    // `--session-id` names a *fresh* session's id: a resumed or forked run keeps its transcript's,
    // a panel's candidates have ids of their own. The store collision is run()'s check (a read).
    if let sessionId {
      guard UUID(uuidString: sessionId) != nil else {
        throw ValidationError("--session-id must be a UUID (e.g. 6BA7B810-9DAD-11D1-80B4-00C04FD430C8), got '\(sessionId)'.")
      }
      if resume != nil || continueMostRecent || fork {
        throw ValidationError("--session-id and --resume/--continue/--fork don't combine: a continued run keeps its transcript's id.")
      }
      if panel != nil {
        throw ValidationError("--panel and --session-id don't combine: candidates are throwaway runs with ids of their own.")
      }
    }
    // The lead's shape (role, toolset, system-prompt appendix) never reaches a panel's
    // candidates either — refused rather than silently ignored, like --permission-mode.
    if panel != nil,
      agentName != nil || agents != nil || appendSystemPrompt != nil || appendSystemPromptFile != nil
        || !allowedTools.isEmpty || !disallowedTools.isEmpty
    {
      throw ValidationError("--panel and --agent/--agents/--allowed-tools/--disallowed-tools/--append-system-prompt don't combine: candidates run with the plain toolset and prompt in their snapshots.")
    }
    // A missing or oversized file, or malformed agents JSON, is a usage error before anything
    // connects: reading them here has no side effect and the message names the flag. A
    // relative path is read against `-C/--cwd` — where run() reads it again after changing
    // directory — not against the directory the command was typed in.
    _ = try Self.systemPromptAppendix(
      text: appendSystemPrompt, file: appendSystemPromptFile, relativeTo: workingDirectoryPath)
    _ = try Self.parseInlineAgents(agents, relativeTo: workingDirectoryPath)
    // The structured-output schema is loaded here for the same reason: a schema that isn't an
    // object, isn't JSON or is over the cap is a usage error before anything connects. A panel
    // never reaches the configuration it would feed.
    if panel != nil, outputSchema != nil {
      throw ValidationError("--panel and --output-schema don't combine: candidates answer in prose and the judge reads their reports.")
    }
    _ = try Self.loadOutputSchema(outputSchema, relativeTo: workingDirectoryPath)
    // A bad dialect is a usage error too — before run() has connected servers or forked a
    // session on its behalf. So is a bad effort level, panel or not: the non-panel path parsed
    // it in run(), after the runtime; a panel's candidates now take the dial too (batch 14).
    _ = try parseDialect(dialect)
    _ = try parseEffort(effort)
    let mode = try parsePermissionMode(permissionMode)
    if panel != nil, permissionMode != nil {
      throw ValidationError("--panel and --permission-mode don't combine: candidates run unattended in their snapshots, so a mode can't be applied to them.")
    }
    // `--panel-on-fail` (P2) runs a panel when the verifier says FAIL, so it refuses what a panel
    // refuses — plus what makes the trigger meaningless: no verifier (nothing to trigger on), no
    // `--yes` (candidates run unattended), `--panel` (pick one), `--no-apply` (applying the
    // winner is the point), a size under 2. `0` alone is accepted: it switches a configured
    // `policies.panelOnVerifierFail` off for this run, and needs nothing else.
    if let panelOnFail {
      if panelOnFail != 0, panelOnFail < 2 {
        throw ValidationError("--panel-on-fail needs at least 2 candidates (0 switches a configured default off for this run).")
      }
      if panel != nil {
        throw ValidationError("--panel and --panel-on-fail don't combine: pick one — a panel now, or a panel only when --verify says FAIL.")
      }
      if panelOnFail != 0 {
        if verify == nil {
          throw ValidationError("--panel-on-fail needs --verify <model>: the panel is triggered by the verifier's FAIL.")
        }
        if !yes {
          throw ValidationError("--panel-on-fail runs every candidate unattended (bash included) in a snapshot and applies the winner here — pass --yes to allow that.")
        }
        if safe {
          throw ValidationError("--panel-on-fail and --safe don't combine: candidates must be able to write in their snapshots.")
        }
        if noApply {
          throw ValidationError("--panel-on-fail and --no-apply don't combine: the trigger exists to apply the judged winner over the failed attempt (the failed attempt is kept beside the snapshot either way).")
        }
        if !addDir.isEmpty {
          throw ValidationError("--panel-on-fail and --add-dir don't combine: each candidate's world is its own snapshot of the working directory, so an extra directory would be shared side effects rather than a widened root.")
        }
        if resume != nil || continueMostRecent || fork {
          throw ValidationError("--panel-on-fail and --resume/--continue/--fork don't combine: a panel is N throwaway candidate runs, not a session's next turn.")
        }
        if sessionId != nil {
          throw ValidationError("--panel-on-fail and --session-id don't combine: candidates are throwaway runs with ids of their own.")
        }
        if permissionMode != nil {
          throw ValidationError("--panel-on-fail and --permission-mode don't combine: candidates run unattended in their snapshots, so a mode can't be applied to them.")
        }
        if outputSchema != nil {
          throw ValidationError("--panel-on-fail and --output-schema don't combine: candidates answer in prose and the judge reads their reports.")
        }
        if agentName != nil || agents != nil || appendSystemPrompt != nil || appendSystemPromptFile != nil
          || !allowedTools.isEmpty || !disallowedTools.isEmpty
        {
          throw ValidationError("--panel-on-fail and --agent/--agents/--allowed-tools/--disallowed-tools/--append-system-prompt don't combine: candidates run with the plain toolset and prompt in their snapshots.")
        }
      }
    }
    guard mode == .acceptEdits || mode == .bypass else { return }
    if safe {
      throw ValidationError("--safe and --permission-mode \(mode.label) contradict: --safe is a read-only run, and \(mode.label) pre-approves mutations.")
    }
    if !yes {
      throw ValidationError("--permission-mode \(mode.label) needs --yes: a headless run approves nothing unless asked (--yes also turns the sandbox on).")
    }
  }

  /// The largest stdin a run takes as prompt/context — past this it is a file, so the task
  /// should name a path and let the model read it in windows.
  static let maxStdinBytes = 10 * 1024 * 1024

  func run() async throws {
    if let workingDirectoryPath {
      try Self.changeDirectory(to: workingDirectoryPath)
    }
    if outputFormat != .text, panel != nil {
      throw ValidationError("--output-format \(outputFormat.rawValue) doesn't combine with --panel yet — a panel keeps its text report.")
    }
    if outputFormat != .text, let panelOnFail, panelOnFail != 0 {
      throw ValidationError("--output-format \(outputFormat.rawValue) doesn't combine with --panel-on-fail yet — an escalated run keeps its text report.")
    }
    // The task: the argument, stdin, or both (stdin as a context block). Read before the
    // runtime so a missing task fails fast, without a manifest fetch.
    let prompt = try Self.composePrompt(
      task: task, stdin: try Self.readPipedStdin(limit: Self.maxStdinBytes))
    // `--resume`/`--continue`/`--fork`: the session this task continues, loaded before the
    // runtime so a bad id fails fast. This is the *original* transcript — with `--fork` the
    // copy is made only once everything that can refuse the run has passed (below, before the
    // agent is built), so a refused run leaves no orphan fork. The store it came from is
    // where the continued transcript lands — continuation implies persistence.
    let sessionStore = SessionStore()
    let resumed = try loadResumedSession(store: sessionStore)
    // `--session-id`: the id this fresh session takes, canonical (uppercase, like every other).
    // A transcript already holding it is refused before anything connects — two transcripts
    // must never share an id — whether or not `--session` persists this one.
    let pinnedSessionId = try Self.pinnedSessionId(sessionId, store: sessionStore)
    let inlineAgents = try Self.parseInlineAgents(agents)
    let runtime = try ArnesRuntime.make(providerOptions)
    let service = runtime.service
    // `--panel-on-fail` (P2): the loop-2 trigger, armed only for a run that verifies and runs
    // unattended — the flag, else `policies.panelOnVerifierFail`; a JSON run never arms from the
    // key (its envelope has no room for an escalation yet, and a plain JSON run must stay one).
    // The roster is `-m`'s comma list as for `--panel`; the initial attempt runs on its first entry.
    var panelOnFailSize = outputFormat == .text
      ? Self.panelOnFailArmed(flag: panelOnFail, policy: runtime.panelOnVerifierFail, verify: verify, yes: yes)
      : nil
    if panel != nil {
      // A panel never combines with --resume or --agent (validate()), so its roster is the
      // flag or the provider default, as before.
      try await runPanel(runtime: runtime, roster: try runtime.model(self.model), task: prompt)
      return
    }
    let stderr = FileHandle.standardError
    // Project-local skills, agents, instruction files and hooks load only in a trusted
    // directory (the notice prints below, with the rest of the project-scoped setup).
    let trust = ProjectTrustGate.evaluate(
      trustFlag: trustProject, interactive: false,
      instructionOptions: runtime.instructionOptions)
    // `--agent`: the lead runs *as* this definition. Resolved before the permission posture
    // is decided, because a read-only agent decides it.
    let leadAgent = try agentName.map { leadName in
      try Self.resolveLeadAgent(
        named: leadName,
        in: AgentLibrary.merge(
          inline: inlineAgents,
          discovered: bare
            ? AgentDefinition.builtins
            : AgentLibrary.discover(includeProject: trust.includeProject)))
    }
    for warning in leadAgent?.warnings ?? [] {
      stderr.write(Data((TerminalText.sanitize("⚠ agent '\(leadAgent?.name ?? "")': \(warning)") + "\n").utf8))
    }
    // The permission posture, decided once: the mode the session runs under (narrowed out of
    // an auto-approving one when the lead is read-only — the task tool's rule) and which
    // delegate guards the run. `leadPosture` is pure so the narrow-never-widen rule is tested
    // apart from the delegate objects it selects.
    let posture = Self.leadPosture(
      agent: leadAgent, mode: try parsePermissionMode(permissionMode), safe: safe, yes: yes)
    let mode = posture.mode
    // The model ladder: -m > the transcript's (a resumed session keeps its model, as in the
    // REPL) > the agent's frontmatter (resolved against the manifest like a subagent's) >
    // the provider default.
    let model = try await Self.resolveLeadModel(
      flag: panelOnFailSize == nil ? self.model : self.model.map(Self.firstRosterEntry),
      resumed: resumed?.loaded, agent: leadAgent, runtime: runtime)
    if let resumed, let startedIn = resumed.loaded.meta.cwd,
      Self.startedElsewhere(startedIn, cwd: ArnesRuntime.workingDirectory)
    {
      // The transcript's paths and instructions were about another tree; say so, don't refuse.
      stderr.write(Data((TerminalText.sanitize(
        "⚠ session \(resumed.label) was started in \(startedIn) — continuing it in \(ArnesRuntime.workingDirectory.path)") + "\n").utf8))
    }
    // Everything a JSON run says about its setup goes to stderr: stdout is the contract.
    let jsonOutput = outputFormat != .text
    let emitter = HeadlessEmitter(format: outputFormat, includePartial: includePartial, verbose: verbose)
    let setupLine: (String) -> Void = { line in
      if jsonOutput {
        stderr.write(Data((line + "\n").utf8))
      } else {
        print(line)
      }
    }
    // `--bare` is the reproducible run: nothing discovered from the machine or the repo.
    let mcpEnabled = !noMcp && !bare
    let skillsEnabled = !noSkills && !bare
    let agentsEnabled = !noAgents && !bare
    // Headless runs approve nothing unless asked: a prompt-injected repository must not
    // get a shell just because someone ran `arnes do "summarize this"` in it.
    // Which delegate is `posture.gate`'s call (`--safe` > a read-only agent > `--yes` > deny),
    // so the order can't drift here; this switch only builds the object each gate names.
    let baseDelegate: any PermissionDelegate
    switch posture.gate {
    case .safe:
      baseDelegate = DenyMutationsPermissions()
    case .agentReadOnly(let leadName):
      // The agent declared itself read-only: that holds whatever --yes says (narrow-only,
      // as for a subagent), and the model is told why rather than nudged toward --yes.
      baseDelegate = DenyMutationsPermissions(
        reason: "agent '\(leadName)' is read-only (permissionMode) — report what you would change instead")
    case .autoApprove:
      // The judge (if configured) can veto a risky command here — no human reads the prompt.
      baseDelegate = runtime.judging(AutoApprovePermissions(), headlessVeto: true)
    case .denyWithoutConsent:
      baseDelegate = DenyMutationsPermissions(
        reason: "this headless run was started without --yes, so mutations and reads outside the working directory are denied — finish with what you can read and report what you would have changed")
      // Under `plan` the mode denies every gated call before the delegate is asked, so
      // `--yes` would change nothing: a dry run was asked for, not a run missing its consent.
      if mode != .plan {
        stderr.write(Data("read-only run: pass --yes (-y) to let the agent modify files and run commands\n".utf8))
      }
    }
    // One gate for the lead and every subagent it spawns: concurrent delegations decide one
    // call at a time, so the judge's cache (and any other state under here) is never raced.
    let permissions: any PermissionDelegate = SerializedPermissions(baseDelegate)
    if let failure = await runtime.manifestWarning() {
      stderr.write(Data((TerminalText.sanitize(failure) + "\n").utf8))
    }
    if let warning = runtime.sandboxSupportWarning {
      stderr.write(Data((warning + "\n").utf8))
    }
    if let warning = runtime.hooksWarning {
      stderr.write(Data((TerminalText.sanitize(warning) + "\n").utf8))
    }
    let subprocessEnvironment = runtime.subprocessEnvironment
    // `--add-dir` widens what counts as inside; the config's `paths` globs tighten it.
    let addedDirectories = try ArnesRuntime.parseAddedDirectories(addDir)
    let cwd = ArnesRuntime.workingDirectory
    // Auto-memory (C3): the project's `~/.arnes/memory/<key>/`, read by a headless run too. Its
    // directory is the carve-out the path rules and the sandbox open — reads free, a write
    // `.sensitive` (vetoed under `--yes` unless `--add-dir` names it) — and its index rides the
    // prompt as the `# Memory` section below. `--bare` reads nothing from the machine, memory included.
    let memoryStore = noMemory || bare ? nil : runtime.memoryStore(workdir: cwd)
    let pathRules = runtime.pathRules(
      addedDirectories: addedDirectories, memoryRoot: memoryStore?.directory)
    // The sandbox: opt-in as ever, but **on by default for `--yes`** where the platform can
    // enforce it — an unattended run has nobody watching what the shell does. `--add-dir`
    // widens it too, so bash can write wherever the file tools can.
    let sandboxResolution = runtime.sandboxResolution(
      root: cwd, addedDirectories: addedDirectories, autonomous: yes,
      memoryRoot: memoryStore?.directory)
    if noSandbox, sandboxResolution.sandbox != nil {
      stderr.write(Data((ANSI.red(ArnesRuntime.sandboxOptOutWarning) + "\n").utf8))
    }
    var sandbox = noSandbox ? nil : sandboxResolution.sandbox
    // The trigger's pre-run snapshot: a clone of the tree as it is now, the `base` of a 0700
    // `arnes-agent-*` layout (the failed attempt lands in `work` if the verifier says FAIL —
    // exactly what `arnes agents apply` accepts). The layout is protected from this run's own
    // shell the way an isolated subagent's base is. A copy failure disarms the trigger, never
    // the run; a run that never escalates removes the layout (the `defer`, thrown runs included).
    var panelOnFailLayout: WorkspaceSnapshot.Layout?
    var keepPanelOnFailLayout = false
    if panelOnFailSize != nil {
      switch Self.preRunSnapshot(of: cwd, leadId: pinnedSessionId) {
      case .success(let layout):
        panelOnFailLayout = layout
        sandbox?.protectedSubpaths.append(layout.directory)
      case .failure(let error):
        panelOnFailSize = nil
        stderr.write(Data((TerminalText.sanitize(
          "⚠ --panel-on-fail: could not snapshot \(cwd.path) (\(error)) — the trigger is off for this run") + "\n").utf8))
      }
    }
    defer {
      if let layout = panelOnFailLayout, !keepPanelOnFailLayout { Self.removeLayout(layout) }
    }
    if let warning = runtime.sandboxDenyReadWarning(sandboxResolution), !noSandbox {
      stderr.write(Data((TerminalText.sanitize(warning) + "\n").utf8))
    }
    // Background shell jobs (`bash … background: true`, the `job` tool): one registry for the
    // run, its jobs killed when the session ends (`Agent.run` → `end` → `shutdown`).
    let jobs = runtime.jobRegistry()
    // Kept: an `isolation: worktree` subagent rebuilds this context over its snapshot. `web_fetch`
    // rides only when the config has a `web` block (and the sandbox allows the network).
    let toolContext = ToolContext(
      sandbox: sandbox, environment: subprocessEnvironment, pathRules: pathRules,
      bashOutputChars: runtime.limits.effectiveBashOutputChars, jobs: jobs,
      bashTimeoutSeconds: runtime.limits.effectiveBashTimeoutSeconds, web: runtime.webPolicy)
    let baseTools = HarnessAssembly.coreTools(toolContext)
    // Panels stay MCP-free: candidates run in isolated snapshots, and shared server
    // processes would let them trample each other through side effects.
    let mcp = try await MCPSetup.connect(
      enabled: mcpEnabled, options: mcpOptions, redacting: runtime.redactedEnvironmentKeys,
      // The repository's .mcp.json joins only in a trusted directory and never under --bare
      // (nothing project-scoped loads there), as untrusted servers (X9).
      project: trust.includeProject && !bare
        ? MCPConfig.projectURL(for: cwd, options: runtime.instructionOptions)
        : nil,
      output: setupLine)
    // A `required: true` server that didn't come up means the run can't do what it was
    // asked to — better a clear exit 1 than a model improvising without its tools.
    if let failure = mcp.requiredFailure {
      await mcp.provider.shutdown()
      stderr.write(Data((TerminalText.sanitize(failure) + "\n").utf8))
      throw ExitCode(1)
    }
    // A bare run loads no project skills, agents, instructions or hooks whatever the trust
    // state, so "skipping … not trusted" would describe a choice that wasn't made.
    if let notice = trust.notice, !bare {
      stderr.write(Data((notice + "\n").utf8))
    }
    if let warning = runtime.rulesWarning {
      stderr.write(Data((TerminalText.sanitize(warning) + "\n").utf8))
    }
    // Deny/ask rules apply even under --yes (they are consulted before the delegate), so a
    // rules file is a real headless guardrail; a trusted project's allow rules are ignored.
    let rulesResult = runtime.permissionRules(includeProject: trust.includeProject, workdir: cwd)
    // A trusted repo's own hooks, hash-approved only. Whatever is skipped says so on stderr:
    // a headless run in an untrusted clone must not look like the guardrails were applied.
    // `--bare` loads none and says nothing: the point is a run with no ambient inputs.
    let hooks = bare ? LoadedHooks() : runtime.hooks(cwd: cwd, trusted: trust.includeProject)
    for notice in hooks.notices {
      stderr.write(Data((TerminalText.sanitize(notice) + "\n").utf8))
    }
    let instructions = bare ? nil : ProjectInstructions.discovered(
      includeProject: trust.includeProject, options: runtime.instructionOptions)
    if let notice = instructions?.truncationNotice(maxBytes: runtime.instructionOptions.maxBytes) {
      FileHandle.standardError.write(Data((ANSI.yellow(TerminalText.sanitize("⚠ " + notice)) + "\n").utf8))
    }
    // One configuration for the run and for every subagent it spawns.
    var configuration = Session.Configuration(
      model: model,
      maxStepsPerTurn: maxSteps ?? .max,
      projectInstructions: instructions?.text,
      maxCostUSD: budget,
      hooks: hooks.active,
      reasoningEffort: try parseEffort(effort),
      provider: runtime.traits,
      subprocessEnvironment: subprocessEnvironment,
      workingDirectory: cwd,
      permissionMode: mode,
      permissionRules: rulesResult.rules,
      hookPromptRunner: runtime.promptHookRunner,
      // `--output-schema`, read against the cwd `-C` already changed into (validate() checked it).
      outputSchema: try Self.loadOutputSchema(outputSchema))
    // `limits`: the tool-result cap (spilled under ~/.arnes/tmp/<session>), the loop guard.
    runtime.applyLimits(to: &configuration)
    // A project's `## Compact instructions` steer every compaction's summarizer (C2).
    configuration.compactionInstructions = instructions?.compactInstructions
    configuration.pathRules = pathRules
    // The lead's role and the user's appendix ride the system prompt after the pack,
    // instructions, environment and tool sections (`Session.systemText` places `systemSuffix`
    // there) — role first, appendix after.
    configuration.systemSuffix = Self.composeSystemSuffix(
      agent: leadAgent,
      appendix: try Self.systemPromptAppendix(text: appendSystemPrompt, file: appendSystemPromptFile))
    // How this session was started, on its transcript's meta line (a resumed one keeps its own).
    configuration.sessionOrigin = "do"
    // Caps and dial: the flag wins, then a resumed transcript's recorded effort, then the
    // agent's frontmatter (the same "flag absent → frontmatter" rule a subagent gets).
    if let leadAgent {
      if maxSteps == nil, let steps = leadAgent.maxSteps { configuration.maxStepsPerTurn = steps }
      if budget == nil { configuration.maxCostUSD = leadAgent.budgetUSD }
      if configuration.reasoningEffort == nil { configuration.reasoningEffort = leadAgent.effort }
    }
    if let resumed, effort == nil, let replayed = resumed.loaded.reasoningEffort {
      configuration.reasoningEffort = replayed
    }
    // `--budget` (or the agent's) is *this run's* allowance. A resumed session starts with
    // the transcript's cumulative spend in `costUSD`, which is what `Session` compares the
    // ceiling against — so the ceiling is lifted by that spend, or a `--continue --budget
    // 0.20` on a session that already cost $0.30 would stop before its first request.
    configuration.maxCostUSD = Self.budgetCeiling(
      configuration.maxCostUSD, resumedCostUSD: resumed?.loaded.costUSD)
    // The `# Environment` block (cwd, platform, date, git snapshot, run posture), captured once
    // for the run; subagents render their own from the same facts. Without `--yes` (or with
    // `--safe`, or a read-only `--agent`) the delegate refuses every mutation, and the block
    // says `read-only` rather than the mode label, so the model doesn't plan writes the gate
    // will refuse.
    let environmentFacts = runtime.environmentFacts(sandbox: sandbox)
    if let environmentFacts {
      configuration.extraSystemSections = [
        await EnvironmentContext.block(
          for: configuration, facts: environmentFacts, readOnly: posture.readOnly),
      ]
    }
    // The `# Memory` section, after the environment block: the project's MEMORY.md (capped,
    // scanned) or a header saying nothing is saved yet; captured once for the run.
    if let memoryStore {
      configuration.extraSystemSections.append(memoryStore.promptSection())
    }
    let skills = skillsEnabled ? SkillLibrary.discover(includeProject: trust.includeProject) : []
    let skillTools: [any AgentTool] = skills.isEmpty ? [] : [SkillTool(skills: skills, listingMaxBytes: runtime.skillListingMaxBytes)]
    // `--allowed-tools`/`--disallowed-tools` scope the run's toolset before subagents are
    // built, so delegated work inherits the same ceiling; the `--agent`'s own
    // tools/disallowedTools narrow it further. `task` is decided here too — it is built
    // after the filter, from the filtered list — and an agent with an explicit tools list
    // didn't ask for it either.
    let scopedTools = try Self.scopedTools(
      baseTools + skillTools + mcp.tools, allowed: allowedTools, disallowed: disallowedTools,
      agent: leadAgent)
    let taskToolPermitted = Self.taskToolPermitted(
      allowed: allowedTools, disallowed: disallowedTools, agent: leadAgent)
    let subagents = agentsEnabled && taskToolPermitted
      ? AgentLibrary.merge(inline: inlineAgents, discovered: AgentLibrary.discover(includeProject: trust.includeProject))
      : []
    // An isolated subagent's snapshot is confined the way this run is (`--yes` = unattended).
    var snapshotSandbox: (@Sendable (URL) -> ShellSandbox?)?
    if !noSandbox {
      let unattended = yes
      let memoryRoot = memoryStore?.directory
      snapshotSandbox = { root in
        runtime.shellSandbox(root: root, autonomous: unattended, memoryRoot: memoryRoot)
      }
    }
    let taskTool: TaskTool? = subagents.isEmpty ? nil : TaskTool(
      agents: subagents,
      service: service,
      tools: scopedTools,
      permissions: permissions,
      modelOverrides: try Interactive.parseAgentModels(agentModel),
      catalog: runtime.catalog,
      defaults: runtime.subagentDefaults,
      environment: ProcessInfo.processInfo.environment,
      environmentContext: environmentFacts,
      sessionStore: session || resumed != nil ? sessionStore : nil,
      skills: skills,
      toolContext: toolContext,
      makeSandbox: snapshotSandbox,
      memory: memoryStore,
      configuration: configuration)
    // Inherited subagents follow the requested model; headless runs never swap it.
    let requestedModel = model
    taskTool?.parentModel = { requestedModel }
    let allTools = scopedTools + (taskTool.map { [$0] } ?? [])
    // `--fork` copies the transcript only now: everything that could still refuse the run —
    // an unknown --agent or tool name, a required MCP server down, a bad --agent-model — has
    // passed, so a refused run leaves no orphan fork in the store. The run continues in the
    // copy (`continuing`); `resumed` stays the original it was derived from.
    let continuing = try resumed.map { try forkIfRequested($0, store: sessionStore) }
    let agent = Agent(
      service: service,
      tools: allTools,
      permissions: permissions,
      sessionStore: session || resumed != nil ? sessionStore : nil,
      catalog: runtime.catalog,
      configuration: configuration)
    // Deltas only matter to a consumer streaming them on; text mode prints whole messages.
    agent.includesDeltaEvents = outputFormat == .streamJson && includePartial
    // What this run was assembled from — the first `stream-json` line, once the session
    // exists and has an id. `tools` is the *offered* set (H1): the toolset minus every tool the
    // model's manifest rules out, so a text model's line never names `view_image`; the profile
    // fetch falls back to the whole toolset — an init line must never fail a run.
    let allToolNames = allTools.map(\.name)
    let offeredToolNames: [String]
    if let profile = try? await runtime.catalog.profile(for: model) {
      offeredToolNames = Session.offeredTools(allTools, profile: profile, configuration: configuration).map(\.name)
    } else {
      offeredToolNames = allToolNames
    }
    let initInfo = InitInfo(
      sessionId: "",
      version: arnesVersion,
      model: model,
      dialect: dialect,
      provider: runtime.traits.name,
      cwd: cwd.path,
      tools: offeredToolNames,
      mcpServers: mcp.statuses.filter { !$0.disabled }.map {
        InitInfo.MCPServer(name: $0.server, tools: $0.toolCount, error: $0.error)
      },
      skills: skills.map(\.name),
      agents: subagents.map(\.name),
      hooks: hooks.active.count,
      sandbox: ArnesRuntime.bannerSandbox(sandbox),
      effort: configuration.reasoningEffort?.rawValue,
      permissionMode: mode.label,
      agent: leadAgent?.name,
      resumed: continuing == nil ? nil : true,
      forkedFrom: continuing?.forkedFrom,
      withheldTools: allToolNames.filter { !offeredToolNames.contains($0) })
    // `--budget` is the run's ceiling, so it is also the subagents': each spawn is capped
    // by what is left, and once nothing is left the task tool refuses to spawn at all.
    agent.onSessionStart = { session in
      var info = initInfo
      info.sessionId = session.id
      emitter.emitInit(info)
      // A background job exiting on its own reaches the model as a `[arnes]` notice at the
      // next step boundary; mid-turn the `.jobFinished` event prints it.
      jobs.setExitHandler { job in
        Task { await session.notify(job.exitNotice) }
      }
      if let taskTool {
        // The delegation hooks report which session spawned the agent.
        taskTool.parentSessionId = session.id
        taskTool.parentBudgetRemaining = {
          guard let limit = session.configuration.maxCostUSD else { return nil }
          return max(0, limit - (await session.costUSD))
        }
        // A `fork: true` subagent starts from this run's conversation.
        taskTool.parentHistory = { (await session.history, await session.compactionSummary) }
        // The dial a spawn runs with is the session's live one (the same as the launch dial
        // here — headless has no /effort — bound for parity with the REPL).
        taskTool.parentEffort = { await session.currentReasoningEffort }
      }
    }

    // SIGINT/SIGTERM interrupt the session the way Ctrl-C does in the REPL: outstanding tool
    // calls are answered, the record is appended, the envelope still prints, and the exit
    // code says which signal it was (130/143). A second signal while that is in progress
    // ends the process outright — a run that won't stop must still be stoppable.
    let signals = SignalState()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler {
      if signals.note(.sigint) { ArnesExit.terminateProcess(ArnesExit.Signal.sigint.exitCode) }
      agent.interrupt()
    }
    sigintSource.resume()
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    sigtermSource.setEventHandler {
      if signals.note(.sigterm) { ArnesExit.terminateProcess(ArnesExit.Signal.sigterm.exitCode) }
      agent.interrupt()
    }
    sigtermSource.resume()
    defer {
      sigintSource.cancel()
      sigtermSource.cancel()
    }

    let startedAt = Date()
    let fallbackModels = fallback.split(separator: ",").map(String.init)
    // An alias (`haiku`) resolves like `-m` does — `eval --verify` and `probe` already did; a verbatim
    // alias reached the gateway as an invalid model name and ended the run `error` after the work.
    let verifierModel = verify.map { runtime.provider.resolveAlias($0) }
    let dialectOverride = try parseDialect(dialect)
    let raced = await Self.race(
      agent: agent, timeout: timeout,
      run: {
        try await agent.run(
          task: prompt,
          model: model,
          fallbackModels: fallbackModels,
          verifierModel: verifierModel,
          dialect: dialectOverride,
          resuming: continuing?.loaded,
          onEvent: { emitter.emit($0) },
          sessionId: pinnedSessionId,
          keepAliveSeconds: keepAlive)
      })
    // The servers are closed on every path (a thrown run included) — the process may well
    // stay up to print the envelope, so stdin EOF alone can't be relied on to end them.
    await mcp.provider.shutdown()
    let costEstimated = runtime.traits.estimatesCost
    let result: RunResult
    var finishedResult: AgentResult?
    switch raced {
    case .finished(let agentResult, let deadlineFired):
      finishedResult = agentResult
      // A deadline interrupts the session, so the record says `interrupted`; the envelope
      // knows the cause and says `timeout`.
      let override: StopReason? = deadlineFired && agentResult.stopReason == .interrupted ? .timeout : nil
      result = RunResult(
        result: agentResult, costEstimated: costEstimated, verdict: emitter.verdict, stopReason: override)
    case .failed(let error):
      // Text mode keeps its old failure path: ArgumentParser prints the error, exit 1. A JSON
      // consumer gets the envelope instead — `is_error`, `stop_reason: error`, and whatever
      // the loop recorded before it rethrew.
      guard jsonOutput else { throw error }
      result = RunResult.failure(
        stopReason: .error,
        error: "\(error)",
        sessionId: agent.lastSession?.id,
        model: model,
        provider: runtime.traits.name,
        record: await agent.lastSession?.lastRecord,
        costEstimated: costEstimated,
        durationMs: Int(Date().timeIntervalSince(startedAt) * 1000))
    case .deadlineWithoutResult:
      // Interrupted at the deadline and still not back after the grace period — a tool that
      // ignores cancellation. Report what is known and leave; exiting ends the tool too.
      let notice = "⚠ timeout after \(Int(timeout ?? 0))s — the run did not stop in time"
      stderr.write(Data((notice + "\n").utf8))
      result = RunResult.failure(
        stopReason: .timeout,
        error: nil,
        sessionId: agent.lastSession?.id,
        model: model,
        provider: runtime.traits.name,
        record: await agent.lastSession?.lastRecord,
        costEstimated: costEstimated,
        durationMs: Int(Date().timeIntervalSince(startedAt) * 1000))
    }
    // A retained session must also close if writing the final artifact fails. Successful
    // retained runs publish it before the result, which is an external verifier's handoff.
    if keepAlive > 0, let outputLastMessage {
      do {
        try Self.writeLastMessage(result.structuredOutput.map(HeadlessJSON.line) ?? result.result,
          to: outputLastMessage)
      } catch {
        _ = await agent.close()
        throw error
      }
    }
    emitter.finish(result)
    if keepAlive == 0, let outputLastMessage {
      // With a schema the file is the validated object (one line); the prose otherwise — and
      // when the structured request never validated, so a consumer always gets *an* answer.
      let lastMessage = result.structuredOutput.map(HeadlessJSON.line) ?? result.result
      try Self.writeLastMessage(lastMessage, to: outputLastMessage)
    }
    if session || resumed != nil {
      // stderr, so piping the run's output somewhere still leaves the id visible.
      stderr.write(Data("session \(result.sessionId) — resume with: arnes resume \(result.sessionId)\n".utf8))
    }
    var code = ArnesExit.code(for: result, failOnDenied: failOnDenied, signal: signals.received)
    if keepAlive > 0 {
      if code != ArnesExit.ok.rawValue { _ = await agent.close() }
      // The result stays the final stdout event. Lifecycle hook notices after the handoff
      // go to stderr, and a signal still controls the process's eventual exit status.
      for notice in await agent.waitForClose() {
        if let line = HeadlessEmitter.textLine(for: .hookNotice(event: notice.event, output: notice.output)) {
          stderr.write(Data((line + "\n").utf8))
        }
      }
      if let received = signals.received { code = received.exitCode }
    }
    // The trigger (P2): a *finished* run whose verifier said FAIL — a run that stopped short was
    // never verified, an interrupted or thrown one neither — re-runs the task as a panel over the
    // pre-run snapshot, applies the winner and re-verifies; the final verdict decides the exit
    // code. `--fail-on-denied` keeps outranking (4 over 2 and 0), as `ArnesExit.code` orders them.
    if let layout = panelOnFailLayout, let size = panelOnFailSize, let verifierModel,
      let agentResult = finishedResult, agentResult.record.finished, agentResult.record.verifierPassed == false
    {
      // Kept while the escalation runs (its steps name the layout); afterwards only when it
      // still holds something the working tree lacks.
      keepPanelOnFailLayout = true
      let escalation = await escalatePanelOnFail(
        runtime: runtime, layout: layout, size: size, task: prompt, verifierModel: verifierModel, cwd: cwd)
      keepPanelOnFailLayout = escalation.keepLayout
      if code != ArnesExit.denied.rawValue {
        code = Self.panelOnFailExit(reverified: escalation.reverified, panelError: escalation.panelError)
      }
    }
    if code != ArnesExit.ok.rawValue {
      throw ExitCode(code)
    }
  }

  // MARK: Panel on verifier FAIL (P2)

  /// Whether `--panel-on-fail` is armed for this run, and with how many candidates: the flag
  /// outranks `policies.panelOnVerifierFail`, `0` on the command line switches a configured
  /// default off, nil/0/1 from either source is off, and nothing arms without both `--verify` (the
  /// FAIL the panel is triggered by) and `--yes` (candidates run unattended). Pure.
  static func panelOnFailArmed(flag: Int?, policy: Int?, verify: String?, yes: Bool) -> Int? {
    guard verify != nil, yes else { return nil }
    guard let size = flag ?? policy, size >= 2 else { return nil }
    return size
  }

  /// The escalated run's exit code — the *final* result's, whatever the first attempt said: the
  /// re-verification passed → 0; it failed, or could not be had (a transport error: the winner is
  /// applied but unverified) → 2; a panel that produced no winner (`PanelError`) → 2, the original
  /// FAIL standing with the failed attempt restored. `--fail-on-denied`'s 4 is the caller's to
  /// keep on top. Pure.
  static func panelOnFailExit(reverified: Bool?, panelError: Bool) -> Int32 {
    if panelError { return ArnesExit.verifierFailed.rawValue }
    return reverified == true ? ArnesExit.ok.rawValue : ArnesExit.verifierFailed.rawValue
  }

  /// The model the initial attempt runs on when the trigger is armed: the first entry of `-m`'s
  /// comma list (the roster the panel cycles), so `-m deepseek,haiku` runs deepseek first.
  static func firstRosterEntry(_ roster: String) -> String {
    roster.split(separator: ",").first.map(String.init) ?? roster
  }

  /// `-m`'s comma roster as the models a panel cycles: each entry trimmed and alias-resolved on
  /// its own. `runtime.model("deepseek,haiku")` looks the whole string up as one alias and misses,
  /// so a comma roster of configured aliases used to reach the gateway verbatim and 400 on every
  /// candidate (`--panel` and the trigger alike); a single entry is what `runtime.model` returned.
  static func rosterModels(_ roster: String, resolve: (String) -> String) -> [String] {
    let entries = roster.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return entries.isEmpty ? [roster] : entries.map(resolve)
  }

  /// Clones `cwd` into a fresh `arnes-agent-<lead8>/<run8>/base` (0700) before the run. A failure
  /// leaves nothing behind and is the caller's warning — the run itself is never refused over it.
  static func preRunSnapshot(of cwd: URL, leadId: String?) -> Result<WorkspaceSnapshot.Layout, Error> {
    let layout = WorkspaceSnapshot.Layout(leadId: leadId ?? UUID().uuidString, runId: UUID().uuidString)
    do {
      try layout.createDirectories()
      try WorkspaceSnapshot.snapshot(of: cwd, to: layout.base)
      return .success(layout)
    } catch {
      removeLayout(layout)
      return .failure(error)
    }
  }

  /// Removes a layout nobody will apply — the run directory and, when that leaves it empty, its
  /// `arnes-agent-<lead8>` parent.
  static func removeLayout(_ layout: WorkspaceSnapshot.Layout) {
    layout.remove()
  }

  /// What the trigger did once it fired — the pieces `panelOnFailExit` reads.
  struct PanelOnFailOutcome {
    /// The re-verification's verdict over the applied winner; nil when it could not be had.
    var reverified: Bool?
    /// The panel produced no winner (or a step around it failed): the failed attempt was restored
    /// and the original FAIL stands.
    var panelError: Bool
    /// Whether the layout still holds something worth `arnes agents apply`: the applied winner's
    /// pre-run `base` beside the failed attempt in `work` (the success path), or a failed attempt
    /// the restore could not put back. A failure that restored the tree — or never moved it —
    /// leaves nothing the tree doesn't already have, and the caller removes the layout.
    var keepLayout: Bool
  }

  /// The escalation, after the initial run's lines and footer printed exactly as always:
  /// 1. keep the failed attempt beside the pre-run `base` (`layout.work`), so nothing the first run
  ///    wrote is lost and `arnes agents apply <layout>` restores it;
  /// 2. revert the working tree to `base` (`WorkspaceSnapshot.sync`, the mirror `--panel`'s apply
  ///    uses; `.git` untouched) — the candidates and the winner are judged against the original
  ///    tree, and the failed edits must not survive under the winner's (`WorkspaceSnapshot.apply`
  ///    would have listed every one of them as a conflict and left them in place);
  /// 3. the panel, built exactly as `--panel` builds one, over `base`, its candidates tagged
  ///    `agent: panel-on-fail` and its rows `label: verifier-fail`;
  /// 4. the winner mirrored into the (now pristine) working tree, its snapshot deleted, the layout kept;
  /// 5. the winner re-verified by the same verifier model over the working tree — its spend joins
  ///    the footer and lands on no record, like `/verify`.
  /// A `PanelError`, or a failed step around the panel, restores the failed attempt and leaves the
  /// original FAIL standing. Prints to stdout like `--panel`'s report.
  private func escalatePanelOnFail(
    runtime: ArnesRuntime,
    layout: WorkspaceSnapshot.Layout,
    size: Int,
    task: String,
    verifierModel: String,
    cwd: URL)
    async -> PanelOnFailOutcome
  {
    print("↯ verifier FAIL — panel of \(size) over the pre-run snapshot (--panel-on-fail)")
    // 1. Keep the failed attempt.
    do {
      try WorkspaceSnapshot.snapshot(of: cwd, to: layout.work)
    } catch {
      print(TerminalText.sanitize("✘ --panel-on-fail: could not keep the failed attempt (\(error)) — the working tree is untouched and the verifier's FAIL stands"))
      return PanelOnFailOutcome(reverified: nil, panelError: true, keepLayout: false)
    }
    // From here the failed attempt is safe in `work`; every failure below puts it back. A restore
    // that succeeds leaves the tree as the first run left it, so the layout has nothing the tree
    // lacks and goes; one that fails keeps it and names it.
    func restoreFailedAttempt(_ why: String) -> PanelOnFailOutcome {
      print(TerminalText.sanitize("✘ \(why) — restoring the failed attempt; the verifier's FAIL stands"))
      do {
        try WorkspaceSnapshot.sync(from: layout.work, into: cwd)
      } catch {
        print(TerminalText.sanitize("✘ could not restore the failed attempt (\(error)) — it is kept at \(layout.work.path); arnes agents apply \(layout.directory.path) restores it"))
        return PanelOnFailOutcome(reverified: nil, panelError: true, keepLayout: true)
      }
      return PanelOnFailOutcome(reverified: nil, panelError: true, keepLayout: false)
    }
    // 2. Revert the working tree to the pre-run base.
    do {
      try WorkspaceSnapshot.sync(from: layout.base, into: cwd)
    } catch {
      return restoreFailedAttempt("--panel-on-fail: could not revert \(cwd.path) to the pre-run snapshot (\(error))")
    }
    // 3. The panel — the roster and judge as `--panel` reads them.
    let roster: [String]
    let judgeModel: String
    do {
      roster = Self.rosterModels(try runtime.model(self.model)) { runtime.provider.resolveAlias($0) }
      judgeModel = try runtime.model(judge)
    } catch {
      return restoreFailedAttempt("--panel-on-fail: \(error)")
    }
    let candidateModels = (0..<size).map { roster[$0 % roster.count] }
    print("panel of \(size): \(candidateModels.joined(separator: ", ")) — judge: \(judgeModel)")
    // The initial run printed the sandbox/hook/trust notices once already.
    let (runner, _) = makePanelRunner(runtime: runtime, candidateAgent: "panel-on-fail", label: "verifier-fail")
    let result: PanelResult
    do {
      result = try await runner.run(
        task: task,
        models: candidateModels,
        judgeModel: judgeModel,
        baseDirectory: layout.base,
        apply: false,
        dialect: parseDialect(dialect),
        onProgress: Self.printPanelProgress)
    } catch {
      return restoreFailedAttempt("panel failed: \(error)")
    }
    let winner = result.winner
    print("\nwinner: candidate \(winner.index + 1) (\(winner.model))")
    if !winner.report.isEmpty {
      print(TerminalText.sanitize(winner.report))
    }
    // 4. Apply the winner over the pristine tree; drop its snapshot, keep the layout.
    if let winnerDirectory = result.winnerDirectory {
      do {
        try WorkspaceSnapshot.sync(from: winnerDirectory, into: cwd)
      } catch {
        try? FileManager.default.removeItem(at: winnerDirectory.deletingLastPathComponent())
        return restoreFailedAttempt("--panel-on-fail: could not apply the winner (\(error))")
      }
      try? FileManager.default.removeItem(at: winnerDirectory.deletingLastPathComponent())
    }
    print("\napplied the winner's changes to \(cwd.path)")
    print("failed attempt kept at \(layout.directory.path) (arnes agents apply \(layout.directory.path) restores it)")
    // 5. Re-verify the winner with the same verifier over the working tree.
    var reverified: Bool?
    var verifierCost = 0.0
    do {
      let pricing = await PanelRunner.verifierPricing(
        for: verifierModel, catalog: runtime.catalog, provider: runtime.traits)
      let verdict = try await Verifier.run(
        task: task,
        outcome: winner.report,
        model: verifierModel,
        service: runtime.service,
        context: Verifier.Context(
          workingDirectory: cwd,
          environment: runtime.subprocessEnvironment,
          catalog: runtime.catalog,
          costOf: pricing,
          rules: runtime.pathRules()))
      reverified = verdict.passed
      verifierCost = verdict.costUSD ?? 0
      print(TerminalText.sanitize("\(verdict.passed ? "✔" : "✘") \(verdict.text)"))
    } catch {
      print(TerminalText.sanitize("✘ re-verify failed: \(error) — the winner is applied but unverified; the verifier's FAIL stands"))
    }
    let totalCost = result.candidates.reduce(result.verdict.judgeCostUSD + verifierCost) { $0 + ($1.record?.costUSD ?? 0) }
    print("[panel-on-fail cost $\(String(format: "%.4f", totalCost)) (candidates + judge + verifier) · outcomes labeled verifier-fail in ~/.arnes/evals.jsonl]")
    return PanelOnFailOutcome(reverified: reverified, panelError: false, keepLayout: true)
  }

  // MARK: Headless plumbing

  /// How the race between the run and its deadline ended.
  enum Raced {
    /// The run returned; `deadlineFired` says whether the deadline interrupted it first.
    case finished(AgentResult, deadlineFired: Bool)
    case failed(Error)
    /// The deadline passed, the session was interrupted, and the run still hadn't returned
    /// after the grace period.
    case deadlineWithoutResult
  }

  /// How long after the deadline's interrupt a run gets to come back with its record before
  /// the CLI gives up on it and reports without one.
  static let deadlineGraceSeconds: Double = 10

  /// Runs `run` against `timeout`. The deadline doesn't drop the run on the floor: it calls
  /// `agent.interrupt()` — the way Eval's race never could — so the session answers its
  /// tool calls, appends its record and returns normally; only a run that still isn't back
  /// after the grace period is abandoned. No timeout: the run simply runs.
  static func race(
    agent: Agent,
    timeout: Double?,
    run: @escaping @Sendable () async throws -> AgentResult)
    async -> Raced
  {
    guard let timeout, timeout > 0 else {
      do { return .finished(try await run(), deadlineFired: false) } catch { return .failed(error) }
    }
    let fired = OnceFlag()
    return await withTaskGroup(of: Raced?.self) { group in
      group.addTask {
        do {
          return .finished(try await run(), deadlineFired: false)
        } catch {
          return .failed(error)
        }
      }
      group.addTask {
        do {
          try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        } catch {
          return nil // the run finished first
        }
        fired.set()
        agent.interrupt()
        try? await Task.sleep(nanoseconds: UInt64(Self.deadlineGraceSeconds * 1_000_000_000))
        return .deadlineWithoutResult
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      switch first {
      case .finished(let result, _)?:
        return .finished(result, deadlineFired: fired.isSet)
      case let other?:
        return other
      case nil:
        return .deadlineWithoutResult
      }
    }
  }

  /// `-C/--cwd`: the directory every later step keys on (tools, trust, instructions, sandbox).
  static func changeDirectory(to path: String) throws {
    let expanded = (path as NSString).expandingTildeInPath
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ValidationError("--cwd \(path) is not a directory")
    }
    guard FileManager.default.changeCurrentDirectoryPath(expanded) else {
      throw ValidationError("could not change into --cwd \(path)")
    }
  }

  /// Stdin when it is not a terminal (piped or redirected), read to EOF up to `limit` bytes;
  /// nil at a terminal or when nothing arrived. Over the limit is an error, not a silent
  /// truncation — a prompt cut in half is worse than no run.
  static func readPipedStdin(limit: Int) throws -> String? {
    guard isatty(0) == 0 else { return nil }
    var data = Data()
    let handle = FileHandle.standardInput
    while true {
      let chunk = handle.readData(ofLength: 64 * 1024)
      if chunk.isEmpty { break }
      data.append(chunk)
      if data.count > limit {
        throw ValidationError("stdin is larger than \(limit / (1024 * 1024)) MB — name the file in the task and let the agent read it in windows instead")
      }
    }
    guard !data.isEmpty else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// The prompt a run gets from its two possible sources. Pure, so it is testable:
  /// - task only → the task;
  /// - stdin only (task omitted, `-`, or blank) → stdin is the task;
  /// - both → the task, then stdin in a `<stdin>` block the model can tell apart from the
  ///   instruction;
  /// - neither → a usage error.
  /// Whitespace-only stdin counts as absent; trailing newlines are trimmed from stdin so a
  /// `echo` doesn't end the prompt with a blank line.
  static func composePrompt(task: String?, stdin: String?) throws -> String {
    let task = task.flatMap { raw -> String? in
      let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty || trimmed == "-" ? nil : raw
    }
    let stdin = stdin.flatMap { raw -> String? in
      guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
      var text = Substring(raw)
      // `Character.isNewline` covers "\r\n" too, which is one grapheme, not two.
      while let last = text.last, last.isNewline { text.removeLast() }
      return String(text)
    }
    switch (task, stdin) {
    case (nil, nil):
      throw ValidationError("no task given — pass one as the argument, or pipe it on stdin (`echo 'the task' | arnes do`)")
    case (nil, let stdin?):
      return stdin
    case (let task?, nil):
      return task
    case (let task?, let stdin?):
      return task + "\n\n<stdin>\n" + stdin + "\n</stdin>"
    }
  }

  /// `--output-last-message`: the final assistant text, written atomically (a reader never
  /// sees a half file) with `~` expanded.
  static func writeLastMessage(_ text: String, to path: String) throws {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: Session continuation (--resume / --continue / --fork)

  /// The session a run continues: the transcript as loaded — the original's until
  /// `forkIfRequested` swaps in the copy — and, for a fork, the id it was copied from.
  struct ResumedSession {
    let loaded: LoadedSession
    /// Set when the run continues in a fork: the original session's id.
    let forkedFrom: String?

    /// `<name>` or the short id, for messages about the session.
    var label: String {
      TerminalText.sanitize(loaded.meta.name ?? String(loaded.meta.id.prefix(8)))
    }
  }

  /// Resolves `--resume`/`--continue` the way `arnes resume` does (exact id, unique prefix,
  /// name; the most recent for `--continue`) and loads the *original* transcript — its
  /// model, effort, spend and cwd are what the run derives from. `--fork` is not done here:
  /// `forkIfRequested` copies once everything that can refuse the run has passed, so a bad
  /// flag never leaves an orphan fork behind. nil when the run starts a fresh session.
  /// Errors are usage errors: nothing has connected yet.
  func loadResumedSession(store: SessionStore) throws -> ResumedSession? {
    guard resume != nil || continueMostRecent else { return nil }
    let sessions = try store.list()
    guard !sessions.isEmpty else {
      throw ValidationError("no sessions to continue — start one with `arnes` or `arnes do --session`.")
    }
    let resolved = try Resume.resolve(resume, in: sessions, refusingSubagentsOf: store)
    return ResumedSession(loaded: try store.load(id: resolved.id), forkedFrom: nil)
  }

  /// `--fork`: copies the transcript now (append-only, so a session open elsewhere is safe
  /// to fork) and returns the copy as the session to continue — the branch point stays
  /// intact. Without `--fork`, `resumed` as it was.
  func forkIfRequested(_ resumed: ResumedSession, store: SessionStore) throws -> ResumedSession {
    guard fork else { return resumed }
    let original = resumed.loaded.meta.id
    let id = try store.fork(id: original, name: name)
    FileHandle.standardError.write(Data("forked \(resumed.label) → \(id)\n".utf8))
    return ResumedSession(loaded: try store.load(id: id), forkedFrom: original)
  }

  /// Whether a resumed session's recorded working directory names a different place than
  /// the run's — symlink-resolved on both sides, so `/tmp/x` and `/private/tmp/x` (or a
  /// project reached through a symlink) don't read as a mismatch.
  static func startedElsewhere(_ startedIn: String, cwd: URL) -> Bool {
    URL(fileURLWithPath: startedIn).resolvingSymlinksInPath().standardizedFileURL.path
      != cwd.resolvingSymlinksInPath().standardizedFileURL.path
  }

  /// The `maxCostUSD` a run hands `Session`: `budget` (the flag's or the agent's; nil = no
  /// ceiling) plus what a resumed transcript already cost. `Session(resuming:)` seeds
  /// `costUSD` with the transcript's cumulative spend and compares the ceiling against it,
  /// so without the offset a run's budget would be charged for turns it never ran — and a
  /// `--continue --budget 0.20` on a $0.30 session would stop before its first request, with
  /// a user turn appended and no reply. The `.budgetReached` figures and
  /// `parentBudgetRemaining` (`limit − costUSD`) stay session-cumulative and consistent.
  /// `--session-id` → the id a fresh session takes: the UUID canonicalized (`UUID(uuidString:)`
  /// → `uuidString`, so a lowercase spelling is accepted and the stored id is uppercase like
  /// every other), refused when `store` already holds a transcript with it — the message names
  /// `--resume <id>`. nil flag → nil (a random id, as always).
  static func pinnedSessionId(_ flag: String?, store: SessionStore) throws -> String? {
    guard let flag else { return nil }
    guard let uuid = UUID(uuidString: flag) else {
      throw ValidationError("--session-id must be a UUID (e.g. 6BA7B810-9DAD-11D1-80B4-00C04FD430C8), got '\(flag)'.")
    }
    let id = uuid.uuidString
    if (try? store.load(id: id)) != nil {
      throw ValidationError("--session-id \(id): a saved session already has this id — continue it with --resume \(id), or pick another id.")
    }
    return id
  }

  static func budgetCeiling(_ budget: Double?, resumedCostUSD: Double?) -> Double? {
    guard let budget else { return nil }
    return budget + (resumedCostUSD ?? 0)
  }

  /// The model a run uses: `-m` (an id or alias) > the transcript's when resuming > the
  /// `--agent`'s frontmatter, fuzzy-resolved against the manifest the way a subagent's is
  /// (`inherit`/nil means none) > the provider default.
  static func resolveLeadModel(
    flag: String?, resumed: LoadedSession?, agent: AgentDefinition?, runtime: ArnesRuntime)
    async throws -> String
  {
    if let flag { return try runtime.model(flag) }
    if let resumed { return resumed.model }
    if let configured = agent?.model, configured.lowercased() != "inherit" {
      // Manifest unavailable or no match: send the name as-is and let the request surface
      // the real error rather than guessing here.
      if let best = try? await runtime.catalog.search(configured, limit: 1).first { return best.id }
      return runtime.catalog.resolve(configured)
    }
    return try runtime.model(nil)
  }

  // MARK: Lead persona (--agent / --agents / --append-system-prompt)

  /// The run's permission posture once `--agent`, `--permission-mode`, `--safe` and `--yes`
  /// are known: the mode the session runs under and which delegate guards it. One pure
  /// decision, so the narrow-never-widen rule for a read-only lead is tested apart from the
  /// delegate objects `Do.run` builds from it.
  struct LeadPosture: Equatable {
    /// Which delegate guards the run, in precedence order.
    enum Gate: Equatable {
      /// `--safe`: every mutation denied, no hint about `--yes`.
      case safe
      /// The `--agent` declared `permissionMode: readOnly`: every mutation denied *whatever
      /// `--yes` said* (narrow-only, as for a subagent); the model is told which agent and why.
      case agentReadOnly(name: String)
      /// `--yes`: ordinary work auto-approved (the judge may still veto).
      case autoApprove
      /// Neither: mutations denied, with the `--yes` hint on stderr.
      case denyWithoutConsent
    }

    /// The requested mode, narrowed out of an auto-approving one (`acceptEdits`/`bypass` →
    /// `default`) when the lead is read-only — those modes answer before the delegate is
    /// asked, so left alone they would run mutations past it. `plan` denies more and stays.
    let mode: PermissionMode
    let gate: Gate

    /// Whether the delegate refuses every mutation — what the `# Environment` block reports.
    var readOnly: Bool { gate != .autoApprove }
  }

  /// `--safe` > a read-only `--agent` > `--yes` > deny — the same order the pre-X3 chain had,
  /// with the agent's veto slotted where only `--safe` outranks it. Consent (`--yes`) can
  /// never turn a read-only agent into an auto-approving run.
  static func leadPosture(agent: AgentDefinition?, mode: PermissionMode, safe: Bool, yes: Bool) -> LeadPosture {
    if let agent, agent.permissionMode == .readOnly {
      let narrowed: PermissionMode = mode == .plan ? .plan : .default
      return LeadPosture(mode: narrowed, gate: safe ? .safe : .agentReadOnly(name: agent.name))
    }
    if safe { return LeadPosture(mode: mode, gate: .safe) }
    if yes { return LeadPosture(mode: mode, gate: .autoApprove) }
    return LeadPosture(mode: mode, gate: .denyWithoutConsent)
  }

  /// The largest `--append-system-prompt-file` or `--agents @path` the run reads. Over it is a
  /// usage error, never a silent truncation — a system prompt cut in half is worse than none.
  static let maxPromptFileBytes = 64 * 1024

  /// `--agent <name>` against the pool the run can see; an unknown name lists what is there.
  static func resolveLeadAgent(named name: String, in pool: [AgentDefinition]) throws -> AgentDefinition {
    guard let agent = pool.first(where: { $0.name == name }) else {
      let available = pool.map(\.name).joined(separator: ", ")
      throw ValidationError("--agent \(name): no such agent — available: \(available.isEmpty ? "(none)" : available)")
    }
    return agent
  }

  /// `--agents`: inline definitions from JSON text or `@path`; nil/blank means none. A
  /// relative `@path` is read against `directory` when given (validate() passes `-C`).
  static func parseInlineAgents(_ raw: String?, relativeTo directory: String? = nil) throws -> [AgentDefinition] {
    guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
    let json = raw.hasPrefix("@")
      ? try readPromptFile(String(raw.dropFirst()), flag: "--agents", relativeTo: directory)
      : raw
    do {
      return try AgentLibrary.parseInline(json: json)
    } catch let error as AgentLibrary.InlineError {
      throw ValidationError(error.description)
    }
  }

  /// `--append-system-prompt` then `--append-system-prompt-file`, separated by a blank line;
  /// nil when neither was given (or both are blank). A relative file path is read against
  /// `directory` when given (validate() passes `-C`).
  static func systemPromptAppendix(text: String?, file: String?, relativeTo directory: String? = nil) throws -> String? {
    var parts: [String] = []
    if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      parts.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    if let file {
      let contents = try readPromptFile(file, flag: "--append-system-prompt-file", relativeTo: directory)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !contents.isEmpty { parts.append(contents) }
    }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }

  /// `--output-schema`: inline JSON (starts with `{`) or a path, a relative one read against
  /// `directory` when given (validate() passes `-C`; run() reads it after changing directory).
  /// nil when the flag is absent. A schema that isn't an object, isn't JSON, is over the 64 KB
  /// cap or can't be read is a usage error naming the flag.
  static func loadOutputSchema(_ flag: String?, relativeTo directory: String? = nil) throws -> OutputSchema? {
    guard let flag else { return nil }
    let base = directory.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    do {
      return try OutputSchema.load(flag, relativeTo: base)
    } catch let error as StructuredOutputError {
      throw ValidationError("--output-schema: \(error.description)")
    }
  }

  /// The lead's system suffix: the agent's role (`AgentLibrary.leadSystemSuffix`, never the
  /// subagent framing — this session talks to the user), then the user's appendix.
  static func composeSystemSuffix(agent: AgentDefinition?, appendix: String?) -> String? {
    let parts = [agent.map(AgentLibrary.leadSystemSuffix), appendix].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
  }

  /// A small text file a flag names (`~` expanded; a relative path against `directory` when
  /// given, else the process cwd), capped at `maxPromptFileBytes`.
  static func readPromptFile(_ path: String, flag: String, relativeTo directory: String? = nil) throws -> String {
    var expanded = (path as NSString).expandingTildeInPath
    if let directory, !expanded.hasPrefix("/") {
      expanded = ((directory as NSString).expandingTildeInPath as NSString).appendingPathComponent(expanded)
    }
    guard let data = FileManager.default.contents(atPath: expanded) else {
      throw ValidationError("\(flag) \(path): cannot read the file")
    }
    guard data.count <= maxPromptFileBytes else {
      throw ValidationError("\(flag) \(path) is \(data.count) bytes — over the \(maxPromptFileBytes / 1024) KB cap; put the bulk in a file the model can read_file instead")
    }
    return String(decoding: data, as: UTF8.self)
  }

  /// The run's toolset after `--allowed-tools`/`--disallowed-tools` (`ToolFilter`; an
  /// unknown name is a usage error) and the `--agent`'s own `tools`/`disallowedTools`. An
  /// agent whose allowlist leaves nothing of a non-empty toolset is refused, as the task tool
  /// refuses such a spawn — a run with no tools is asked for explicitly (`--allowed-tools ""`).
  static func scopedTools(
    _ tools: [any AgentTool], allowed: [String], disallowed: [String], agent: AgentDefinition?)
    throws -> [any AgentTool]
  {
    let scoped: [any AgentTool]
    do {
      scoped = try ToolFilter.apply(
        tools,
        allowed: allowed.isEmpty ? nil : ToolFilter.names(from: allowed),
        disallowed: ToolFilter.names(from: disallowed))
    } catch let error as ToolFilterError {
      throw ValidationError("--allowed-tools/--disallowed-tools: \(error.description)")
    }
    guard let agent else { return scoped }
    let narrowed = AgentLibrary.toolset(for: agent, from: scoped)
    if narrowed.isEmpty, !scoped.isEmpty {
      throw ValidationError("--agent \(agent.name) resolves to zero tools — its tools/disallowedTools leave nothing this run has (\(scoped.map(\.name).joined(separator: ", ")))")
    }
    return narrowed
  }

  /// Whether the run gets the task tool. It is built *after* the filter, so the flags are
  /// consulted by name here (`Task`/`Agent` spellings included; disallow wins), and an
  /// `--agent` with an explicit `tools:` list governs it too: the list didn't name delegation
  /// (`Task` is not a spelling an agent file can use for it), so `task` stays out unless
  /// `--allowed-tools` names it. An agent without a list, or no agent, leaves the flags' verdict.
  static func taskToolPermitted(allowed: [String], disallowed: [String], agent: AgentDefinition?) -> Bool {
    let allowedNames = allowed.isEmpty ? nil : ToolFilter.names(from: allowed)
    guard ToolFilter.permits("task", allowed: allowedNames, disallowed: ToolFilter.names(from: disallowed)) else {
      return false
    }
    guard let agent, agent.tools != nil else { return true }
    return allowedNames?.contains { ToolFilter.canonical($0) == "task" } ?? false
  }

  private func runPanel(runtime: ArnesRuntime, roster: String, task: String) async throws {
    guard let size = panel, size >= 2 else {
      throw ValidationError("--panel needs at least 2 candidates — use plain `arnes do` for one.")
    }
    guard !safe else {
      throw ValidationError("--panel and --safe don't combine: candidates must be able to write in their snapshots.")
    }
    // `--panel` with `--permission-mode` is refused earlier, in `validate()`, for the same reason.
    guard yes else {
      throw ValidationError("--panel runs every candidate unattended (bash included) in a snapshot and applies the winner here — pass --yes to allow that.")
    }
    guard addDir.isEmpty else {
      throw ValidationError("--panel and --add-dir don't combine: each candidate's world is its own snapshot of the working directory, so an extra directory would be shared side effects rather than a widened root.")
    }
    guard !session else {
      throw ValidationError("--panel and --session don't combine: a panel is N throwaway candidate runs, not one session — the outcomes land in ~/.arnes/evals.jsonl instead.")
    }
    let roster = Self.rosterModels(roster) { runtime.provider.resolveAlias($0) }
    let candidateModels = (0..<size).map { roster[$0 % roster.count] }
    let judgeModel = try runtime.model(judge)
    print("panel of \(size): \(candidateModels.joined(separator: ", ")) — judge: \(judgeModel)")

    let (runner, notices) = makePanelRunner(runtime: runtime)
    for notice in notices {
      FileHandle.standardError.write(Data((notice + "\n").utf8))
    }
    let result = try await runner.run(
      task: task,
      models: candidateModels,
      judgeModel: judgeModel,
      baseDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      apply: !noApply,
      dialect: parseDialect(dialect),
      onProgress: Self.printPanelProgress)

    let winner = result.winner
    print("\nwinner: candidate \(winner.index + 1) (\(winner.model))")
    if !winner.report.isEmpty {
      print(TerminalText.sanitize(winner.report))
    }
    if result.applied {
      print("\napplied the winner's changes to \(FileManager.default.currentDirectoryPath)")
    } else if let kept = result.winnerDirectory {
      print("\nwinner's snapshot kept at \(kept.path) (--no-apply)")
    }
    let totalCost = result.candidates.reduce(result.verdict.judgeCostUSD) { $0 + ($1.record?.costUSD ?? 0) }
    print("[panel cost $\(String(format: "%.4f", totalCost)) · outcomes labeled in ~/.arnes/evals.jsonl]")
  }

  /// The panel runner `--panel` runs — and `--panel-on-fail` (P2), which tags its candidates
  /// (`candidateAgent` → `Session.Configuration.agent`) and rows (`label` → `EvalOutcome.label`);
  /// `--panel` passes neither, so its records are byte-identical. Returns the setup notices in
  /// the order `--panel` prints them on stderr (the caller prints — the trigger's initial run
  /// already printed the same ones for the working directory).
  ///
  /// Candidates run unattended (AutoApprove), so each one's tools are confined to its own
  /// snapshot by default — the sandbox is on unless the config turned it off or `--no-sandbox`
  /// did. The user's hooks ride along (a guardrail a panel skipped would be the way around every
  /// hook) and the provider token is withheld from every command. The project's own hooks
  /// (hash-trusted, narrow-only) reach the candidates too, keyed on the *original* directory —
  /// the trust question is about this repository, not the temp snapshots. Same gate as a plain
  /// `do`; a panel loads no project skills, agents or instructions, so only the hooks' own
  /// notices are returned (they say exactly what was skipped and why), plus the gate's when
  /// `--trust-project` recorded something. `--bare` means no hooks here as it does for a plain `do`.
  private func makePanelRunner(
    runtime: ArnesRuntime, candidateAgent: String? = nil, label: String? = nil)
    -> (runner: PanelRunner, notices: [String])
  {
    var notices: [String] = []
    if noSandbox,
      runtime.shellSandbox(root: ArnesRuntime.workingDirectory, autonomous: true) != nil
    {
      notices.append(ANSI.red(ArnesRuntime.sandboxOptOutWarning))
    }
    var makeSandbox: (@Sendable (URL) -> ShellSandbox?)?
    if !noSandbox {
      makeSandbox = { root in runtime.shellSandbox(root: root, autonomous: true) }
    }
    if let warning = runtime.hooksWarning {
      notices.append(TerminalText.sanitize(warning))
    }
    let cwd = ArnesRuntime.workingDirectory
    let trust = ProjectTrustGate.evaluate(
      trustFlag: trustProject, interactive: false,
      instructionOptions: runtime.instructionOptions)
    if trustProject, !bare, let notice = trust.notice {
      notices.append(notice)
    }
    let hooks = bare ? LoadedHooks() : runtime.hooks(cwd: cwd, trusted: trust.includeProject)
    for notice in hooks.notices {
      notices.append(TerminalText.sanitize(notice))
    }
    let runner = PanelRunner(
      service: runtime.service, catalog: runtime.catalog, provider: runtime.traits,
      makeSandbox: makeSandbox,
      subprocessEnvironment: runtime.subprocessEnvironment,
      // The runner keeps the per-call and compaction hooks (`forNestedRun`); a candidate's
      // finish is not the user's turn end.
      hooks: hooks.active,
      hookPromptRunner: runtime.promptHookRunner,
      environmentContext: runtime.environmentContextEnabled,
      toolResultGuard: runtime.toolResultGuard,
      adaptiveThink: runtime.adaptiveThink,
      // `--effort` reaches every candidate (batch 14) — validated at parse time, so this cannot
      // throw here; the judge's structured request stays dial-less.
      reasoningEffort: (try? parseEffort(effort)) ?? nil,
      candidateAgent: candidateAgent,
      label: label,
      commandDiagnostics: runtime.commandDiagnostics,
      compaction: runtime.compaction)
    return (runner, notices)
  }

  /// The panel's progress lines, shared by `--panel` and `--panel-on-fail`.
  @Sendable
  private static func printPanelProgress(_ progress: PanelRunner.Progress) {
    switch progress {
    case .candidateStarted(let index, let model):
      print("· candidate \(index + 1) (\(model)) started")
    case .candidateFinished(let candidate):
      if let error = candidate.error {
        print(TerminalText.sanitize("✘ candidate \(candidate.index + 1) (\(candidate.model)) failed after \(Int(candidate.durationSeconds))s: \(error.prefix(120))"))
      } else {
        let record = candidate.record
        print("✔ candidate \(candidate.index + 1) (\(candidate.model)) finished — \(record?.steps ?? 0) steps · $\(String(format: "%.4f", record?.costUSD ?? 0)) · \(Int(candidate.durationSeconds))s")
      }
    case .judged(let verdict):
      print(TerminalText.sanitize("⚖ \(verdict.reason)"))
    }
  }
}

// MARK: - resume

struct Resume: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Resume a saved session by id, unique id prefix, or name (most recent when omitted).")

  @Argument(help: "Session id, unique id prefix, or saved name (see `arnes sessions`).")
  var session: String?

  @Flag(help: "Continue in a copy instead: the original transcript is left where it was.")
  var fork = false

  @Option(help: "Name the fork (with --fork).")
  var name: String?

  @OptionGroup var providerOptions: ProviderOptions

  func run() async throws {
    let store = SessionStore()
    let sessions = try store.list()
    guard !sessions.isEmpty else {
      throw ValidationError("no sessions yet — start one with `arnes`.")
    }
    let resolved = try Self.resolve(session, in: sessions, refusingSubagentsOf: store)
    guard fork || name == nil else {
      throw ValidationError("--name names a fork — pass --fork too, or /save the session once it's open.")
    }
    // Forking copies the transcript (append-only, so a session open elsewhere is safe to
    // fork) and continues in the copy: the branch point stays intact.
    let id = fork ? try store.fork(id: resolved.id, name: name) : resolved.id
    if fork {
      FileHandle.standardError.write(Data(
        ANSI.dim("forked \(Sessions.label(resolved)) → \(id)\n").utf8))
    }
    var arguments = ["--resume", id]
    if let provider = providerOptions.provider {
      arguments += ["--provider", provider]
    }
    let interactive = try Interactive.parse(arguments)
    try await interactive.run()
  }

  /// Exact id wins; otherwise a unique id prefix or saved name (case-insensitive) — the Kit's
  /// `SessionStore.match`, worded for the terminal. `sessions` is most-recent-first, so a nil
  /// query resumes the latest. A query matching nothing here but naming a subagent transcript
  /// (when a lead store is given) is refused with a pointer to `sessions export`: a subagent's
  /// run is the lead's to continue, not a session of its own.
  static func resolve(
    _ query: String?, in sessions: [SessionMeta], refusingSubagentsOf store: SessionStore? = nil)
    throws -> SessionMeta
  {
    guard let query else { return sessions[0] }
    switch SessionStore.match(query, in: sessions) {
    case .found(let meta):
      return meta
    case .none:
      if let nested = store?.subagentStore, let sessions = try? nested.list(),
         case .found(let meta) = SessionStore.match(query, in: sessions)
      {
        throw ValidationError(
          "\(meta.id) is a subagent run of \(String((meta.parent ?? "?").prefix(8))); inspect it with "
            + "`arnes sessions export \(query)` (its lead session is what you resume).")
      }
      throw ValidationError("no session matches \"\(query)\" — see `arnes sessions`.")
    case .ambiguous(let matches):
      let listing = matches.map { "  \($0.id)  \($0.name ?? "(unnamed)")" }.joined(separator: "\n")
      throw ValidationError("\"\(query)\" matches several sessions:\n\(listing)")
    }
  }
}

// MARK: - models

struct Models: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Search the provider's model manifest.")

  @Argument(help: "Free-text query (OpenRouter searches server-side; other providers match the model id).")
  var query: String?

  @Option(help: "Only models supporting these parameters (comma-separated), e.g. tools,reasoning.")
  var supports = ""

  @Option(help: "Max results.")
  var limit = 20

  @Flag(help: "Print one JSON array of {id, family, dialect, context_length, supports_*, *_price_per_token} rows instead of text (same filters).")
  var json = false

  @Flag(help: ArgumentHelp(
    "Fetch the manifest from the provider now and rewrite the cached copy.",
    discussion: """
      The manifest is kept under ~/.arnes/models/<provider>.json and served from there without a
      fetch while it is younger than policies.manifestCache.ttlHours (24 by default); a model the
      copy doesn't know still costs one fetch when it is first asked for. Use --refresh after the
      provider added models or changed prices.
      """))
  var refresh = false

  @OptionGroup var providerOptions: ProviderOptions

  func run() async throws {
    let runtime = try ArnesRuntime.make(providerOptions)
    let supported = supports.split(separator: ",").map(String.init)
    if refresh {
      await runtime.catalog.refresh()
      if runtime.provider.kind == .openrouter {
        // The OpenRouter listing below is a server-side search; the refresh is for the copy every
        // other command reads, so say what it did.
        if let failure = await runtime.catalog.manifestFailure {
          JSONOut.stderr(TerminalText.sanitize("⚠ manifest refresh failed: \(failure.prefix(200))"))
        } else if !json {
          let count = (try? await runtime.catalog.all().count) ?? 0
          print(ANSI.dim("manifest refreshed — \(count) models cached"))
        }
      }
    }
    if runtime.provider.kind == .openrouter {
      let models = try await runtime.service.models(
        filter: ModelsFilter(
          supportedParameters: supported.isEmpty ? nil : supported,
          q: query,
          limit: limit))
      if json {
        try JSONOut.print(models.map { ModelRow(ModelProfile(model: $0)) })
        return
      }
      for model in models {
        let context = model.contextLength.map { "\($0 / 1000)k" } ?? "?"
        let price = model.pricing?.prompt ?? "?"
        print(TerminalText.sanitize("\(model.id.padding(toLength: 45, withPad: " ", startingAt: 0)) ctx=\(context)\tin=$\(price)/tok"))
      }
      return
    }
    // Other providers: the catalog already holds everything their manifest knows.
    var profiles = try await runtime.catalog.all()
    let aliases = runtime.provider.aliases
    if !aliases.isEmpty, !json {
      print(ANSI.dim("aliases (\(ArnesConfig.defaultURL.path)):"))
      for (alias, target) in aliases.sorted(by: { $0.key < $1.key }) {
        print(TerminalText.sanitize("  \(alias.padding(toLength: 12, withPad: " ", startingAt: 0)) → \(target)"))
      }
    }
    if let failure = await runtime.catalog.manifestFailure {
      let explanation = "\(failure)\nThe provider's baseURL must be the LiteLLM (OpenAI-compatible) root that serves /model/info or /v1/models — "
        + "check it in \(ArnesConfig.defaultURL.path). Runs still work with -m <model or alias> (capabilities assumed)."
      guard !aliases.isEmpty else { throw ValidationError(explanation) }
      if json {
        // Nothing the manifest knows: an empty document on stdout, the explanation on stderr.
        JSONOut.stderr(TerminalText.sanitize("⚠ no manifest on this path — only the configured aliases are known. " + explanation))
        try JSONOut.print([ModelRow]())
        return
      }
      print(ANSI.yellow(TerminalText.sanitize("\n⚠ no manifest on this path — only the aliases above are known. " + explanation)))
      return
    }
    if let query, !query.isEmpty {
      profiles = profiles.filter { $0.id.localizedCaseInsensitiveContains(query) }
    }
    for parameter in supported {
      switch parameter {
      case "tools": profiles = profiles.filter(\.supportsTools)
      case "reasoning", "include_reasoning": profiles = profiles.filter(\.supportsReasoning)
      case "response_format", "structured_outputs": profiles = profiles.filter(\.supportsStructuredOutputs)
      default:
        throw ValidationError(
          "--supports \(parameter) isn't known for \(runtime.provider.kind.rawValue) providers — use tools, reasoning, or structured_outputs")
      }
    }
    if json {
      try JSONOut.print(profiles.prefix(limit).map(ModelRow.init))
      return
    }
    guard !profiles.isEmpty else {
      print("no models match on \(runtime.provider.name) (\(runtime.provider.endpointDescription))")
      return
    }
    for profile in profiles.prefix(limit) {
      let context = profile.contextLength.map { "\($0 / 1000)k" } ?? "?"
      let price = profile.promptPricePerToken.map { String(format: "%.8f", $0) } ?? "?"
      print(TerminalText.sanitize(
        "\(profile.id.padding(toLength: 45, withPad: " ", startingAt: 0)) ctx=\(context)\tin=$\(price)/tok\t\(profile.family.rawValue)"))
    }
    // A listing served from disk says so; one fetched this process prints exactly what it did.
    if let note = await runtime.manifestSourceNote() {
      print(ANSI.dim("manifest \(note) · arnes models --refresh refetches"))
    }
  }
}

// MARK: - status

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show the active provider, key limits, and balance.")

  @OptionGroup var providerOptions: ProviderOptions

  @Flag(help: "Print one JSON object (provider, key, credits, subprocess_env, limits, paths, sandbox, …) instead of text.")
  var json = false

  func run() async throws {
    let runtime = try ArnesRuntime.make(providerOptions)
    let provider = runtime.provider
    if json {
      try JSONOut.print(try await Self.report(runtime))
      return
    }
    print(TerminalText.sanitize(
      "provider: \(provider.name) (\(provider.kind.rawValue)) · \(provider.endpointDescription) · default model \(provider.defaultModel ?? "(none — pass -m)")"))
    // The key/credits lookup is advisory: a gateway without `/key/info` (a 404) or a router
    // whose key endpoint is down must not fail `status` — the manifest and the run's settings
    // still print, and the key line says what happened.
    switch provider.kind {
    case .openrouter:
      do {
        let key = try await runtime.service.keyInfo()
        let credits = try await runtime.service.credits()
        print(TerminalText.sanitize("key: \(key.label ?? "?")\(key.isFreeTier == true ? " (free tier)" : "")"))
        if let limit = key.limit {
          print("limit: \(limit)  remaining: \(key.limitRemaining ?? 0)")
        }
        print("credits: \(String(format: "%.4f", credits.remaining)) remaining of \(credits.totalCredits)")
      } catch {
        print(TerminalText.sanitize(Self.keyUnavailableLine(error, endpoint: "/key")))
      }
    case .litellm:
      let client = LiteLLMClient(
        baseURL: provider.baseURL, apiKey: provider.apiKey, headers: provider.headers,
        tokens: provider.apiKeyCommand.map { BearerTokenSource(command: $0) })
      do {
        let info = try await client.keyInfo()
        print(TerminalText.sanitize("key: \(info.keyAlias ?? "?")"))
        if let spend = info.spend {
          let budget = info.maxBudget.map { String(format: " of $%.2f budget", $0) } ?? " (no budget cap)"
          print(String(format: "spend: $%.4f", spend) + budget)
        }
        if let models = info.models, !models.isEmpty {
          print(TerminalText.sanitize("models: \(models.joined(separator: ", "))"))
        }
        if let expires = info.expires {
          print(TerminalText.sanitize("expires: \(expires)"))
        }
      } catch {
        print(TerminalText.sanitize(Self.keyUnavailableLine(error, endpoint: "/key/info")))
      }
      let count = try await runtime.catalog.all().count
      let note = await runtime.manifestSourceNote().map { " (\($0))" } ?? ""
      print("manifest: \(count) chat models\(note)")
    case .openaiCompatible:
      let count = try await runtime.catalog.all().count
      let note = await runtime.manifestSourceNote().map { "; \($0)" } ?? ""
      print("manifest: \(count) models (capabilities assumed — this kind has no capability manifest\(note))")
    }
    // What a `bash` command or a hook actually inherits — "is my key withheld?" answered
    // without having to run a command to find out.
    print(TerminalText.sanitize("subprocess env: \(runtime.subprocessEnvironment.summary)"))
    // Whether every session's system prompt opens with the `# Environment` block
    // (`policies.environmentContext` in the config; on unless switched off).
    print("environment context: \(runtime.environmentContextEnabled ? "on" : "off (policies.environmentContext)")")
    // Every other switch a run reads from the config, one row each — the same facts the JSON
    // document carries, in words (`Settings` is the one derivation both views read).
    for line in Self.settingsLines(Settings(runtime)) {
      print(TerminalText.sanitize(line))
    }
    let paths = runtime.pathPolicy
    if !paths.isEmpty {
      var parts: [String] = []
      if !paths.protected.isEmpty { parts.append("protected: " + paths.protected.joined(separator: ", ")) }
      if !paths.sensitiveWrite.isEmpty { parts.append("sensitive-write: " + paths.sensitiveWrite.joined(separator: ", ")) }
      if !paths.denyRead.isEmpty { parts.append("deny-read: " + paths.denyRead.joined(separator: ", ")) }
      print(TerminalText.sanitize("paths: " + parts.joined(separator: " · ")))
    }
  }

  /// The text view's line for a key/credits lookup that failed: the error (an HTTP 404 from a
  /// gateway that has no such endpoint, a router outage), and which endpoint it was.
  static func keyUnavailableLine(_ error: any Error, endpoint: String) -> String {
    "key: unavailable — \("\(error)".prefix(200)) (the provider's \(endpoint) lookup; the rest of status stands)"
  }

  /// Every switch a run reads from the config, gathered once from the runtime (and the
  /// environment and home a test injects) — what `settingsLines` and the JSON document's
  /// settings keys both render, so the two views can never disagree. Pure over the runtime's
  /// values: nothing here touches `~/.arnes` or the network.
  struct Settings {
    var sandbox: SandboxConfig?
    /// Whether this platform can enforce a sandbox (`ShellSandbox.isSupported`; injectable).
    var sandboxSupported: Bool
    /// `policies.toolResultFraming`.
    var framing: Bool
    /// `policies.adaptiveThink` (on by default since the batch-13 A/B).
    var adaptiveThink: Bool
    var transport: TransportPolicy
    var cachePolicy: CachePolicy
    /// nil = the manifest cache is off and every process fetches.
    var manifestCache: ManifestCachePolicy?
    var compaction: CompactionPolicy
    var checkpoints: CheckpointsConfig
    var checkpointRoot: URL
    var memory: MemoryConfig
    var memoryRoot: URL
    /// Whether `ARNES_MEMORY_DIR` set the root (over `memory.directory` and the default).
    var memoryRootFromEnvironment: Bool
    var web: WebConfig?
    var limits: LimitsConfig
    var subagents: TaskTool.Defaults
    var judge: String?
    /// How a chat request spells the reasoning dial (`ProviderTraits.reasoningShape`): the
    /// entry's override, else the kind's default.
    var reasoningShape: ReasoningShape
    /// Whether the config entry set `reasoningShape` itself (`ResolvedProvider.reasoningShape`
    /// non-nil); the row then names the kind's default it overrides.
    var reasoningShapeOverridden: Bool
    /// The active provider's kind — what `ReasoningShape.forKind` answers for.
    var providerKind: ProviderKind
    /// `policies.panelOnVerifierFail` (P2): the panel size a `do --verify … --yes` run escalates
    /// to on a verifier FAIL; nil/0/1 = off.
    var panelOnVerifierFail: Int?
    /// The home `~` abbreviates in the text rows (the JSON keeps full paths).
    var home: String

    init(
      _ runtime: ArnesRuntime,
      environment: [String: String] = ProcessInfo.processInfo.environment,
      home: String = NSHomeDirectory(),
      sandboxSupported: Bool = ShellSandbox.isSupported)
    {
      sandbox = runtime.provider.sandbox
      self.sandboxSupported = sandboxSupported
      framing = runtime.toolResultGuard.framing
      adaptiveThink = runtime.adaptiveThink
      transport = runtime.transport
      cachePolicy = runtime.cachePolicy
      manifestCache = runtime.manifestCache?.policy
      compaction = runtime.compaction
      checkpoints = runtime.checkpoints ?? CheckpointsConfig()
      // `ArnesRuntime.checkpointRoot`'s expression over the injected home, so a test never reads
      // the real one.
      checkpointRoot = URL(fileURLWithPath: home).appendingPathComponent(".arnes/checkpoints")
      memory = runtime.memory ?? MemoryConfig()
      memoryRoot = MemoryStore.root(configured: memory.directory, environment: environment, home: home)
      memoryRootFromEnvironment = !(environment["ARNES_MEMORY_DIR"] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
      web = runtime.web
      limits = runtime.limits
      subagents = runtime.subagentDefaults
      judge = runtime.provider.bashJudge
      reasoningShape = runtime.provider.traits.reasoningShape
      reasoningShapeOverridden = runtime.provider.reasoningShape != nil
      providerKind = runtime.provider.kind
      panelOnVerifierFail = runtime.panelOnVerifierFail
      self.home = home
    }
  }

  /// The settings rows of the text view, one fact each as `label: value (config key)`, in a
  /// fixed order: sandbox, framing, adaptive think, transport, prompt cache, manifest cache, compaction,
  /// checkpoints, memory, web, limits, subagents, judge, reasoning shape. Paths are `~`-abbreviated;
  /// never a key, a header or a URL path.
  static func settingsLines(_ settings: Settings) -> [String] {
    var lines: [String] = []
    lines.append("sandbox: " + sandboxFact(settings.sandbox, supported: settings.sandboxSupported))
    lines.append("tool-result framing: \(settings.framing ? "on" : "off") (policies.toolResultFraming)")
    lines.append(
      settings.adaptiveThink
        ? "adaptive think: on · no think tool for a natively reasoning model under --effort (policies.adaptiveThink)"
        : "adaptive think: off · the think tool is offered to every model (policies.adaptiveThink)")
    let transport = settings.transport
    let idle = transport.streamIdleTimeoutMs > 0
      ? "stream idle timeout \(seconds(milliseconds: transport.streamIdleTimeoutMs))"
      : "stream idle timeout off"
    lines.append(
      "transport: \(transport.maxRequestRetries) request retries · \(transport.maxStreamRetries) stream retries · \(idle) (policies.transport)")
    var cache = "prompt cache: anthropic breakpoints \(settings.cachePolicy.anthropicBreakpoints ? "on" : "off")"
    if let ttl = settings.cachePolicy.ttl { cache += " · ttl \(ttl)" }
    lines.append(cache + " (policies.promptCache)")
    if let manifest = settings.manifestCache {
      lines.append("manifest cache: on · ttl \(String(format: "%g", manifest.ttl / 3600)) h (policies.manifestCache)")
    } else {
      lines.append("manifest cache: off (policies.manifestCache)")
    }
    let compaction = settings.compaction
    lines.append(
      "compaction: threshold \(Int((compaction.threshold * 100).rounded()))%"
        + " · keep \(compaction.keepRecentToolResults) recent tool result\(compaction.keepRecentToolResults == 1 ? "" : "s")"
        + " · clear results ≥ \(compaction.clearMinChars) chars"
        + " · ≤ \(compaction.maxPerTurn) emergency summar\(compaction.maxPerTurn == 1 ? "y" : "ies")/turn"
        + " · keep \(compaction.keepRecentImages) recent image\(compaction.keepRecentImages == 1 ? "" : "s") (compaction)")
    if settings.checkpoints.isEnabled {
      let policy = settings.checkpoints.policy
      lines.append(
        "checkpoints: on · \(MemoryFormat.abbreviate(settings.checkpointRoot.path, home: settings.home))"
          + " · files ≤ \(bytesLabel(policy.maxFileBytes)) · \(policy.maxTurns) turns (checkpoints)")
    } else {
      lines.append("checkpoints: off (checkpoints.enabled)")
    }
    if settings.memory.isEnabled {
      var row = "memory: on · \(MemoryFormat.abbreviate(settings.memoryRoot.path, home: settings.home))"
      if settings.memoryRootFromEnvironment { row += " · ARNES_MEMORY_DIR" }
      row += " · \(settings.memory.effectiveMaxLines) lines / \(settings.memory.effectiveMaxBytes) bytes (memory)"
      lines.append(row)
    } else {
      lines.append("memory: off (memory.enabled)")
    }
    if let web = settings.web?.policy {
      var row = "web: allowed: \(domainList(web.allowedDomains)) · denied: \(domainList(web.deniedDomains))"
        + " · ≤ \(web.maxBytes) bytes · \(web.timeoutSeconds) s"
      if let sandbox = settings.sandbox, sandbox.enabled, sandbox.network == false {
        row += " · off under sandbox.network false"
      }
      lines.append(row + " (web)")
    } else {
      lines.append("web: not configured — web_fetch is not registered (add a top-level web block)")
    }
    let limits = settings.limits
    let loopGuard = limits.effectiveLoopGuard
    lines.append(
      "limits: tool result \(limits.effectiveToolResultChars) chars · bash output \(limits.effectiveBashOutputChars) chars"
        + " · bash timeout \(limits.effectiveBashTimeoutSeconds) s"
        + " · loop guard errors \(loopGuard.maxConsecutiveErrors) / identical \(loopGuard.maxIdenticalCalls)"
        + " / edits per file \(loopGuard.maxEditsPerFile) / nudge at \(loopGuard.nudgeAt) (limits)")
    let subagents = settings.subagents
    var delegation = "subagents: default model \(subagents.defaultModel ?? "inherit")"
    if subagents.maxSteps != .max { delegation += " · max steps \(subagents.maxSteps)" }
    if let budget = subagents.budgetUSD { delegation += " · budget \(String(format: "$%.2f", budget))" }
    delegation += " · max concurrent \(subagents.maxConcurrent) · max depth \(subagents.maxDepth)"
      + " · background \(subagents.background ? "on" : "off")"
      + " · join at turn end \(subagents.joinAtTurnEnd ? "on" : "off")"
      + " · transcripts \(subagents.persistTranscripts ? "on" : "off") (subagents)"
    lines.append(delegation)
    lines.append("judge: \(settings.judge ?? "none") (bashJudge)")
    // The shape a chat request carries `--effort` in (R3); an entry that overrode its kind's
    // default says which default it overrides — the providers listing's `reasoningTag` rule.
    var shape = "reasoning shape: \(settings.reasoningShape.rawValue)"
    if settings.reasoningShapeOverridden {
      shape += " · overrides the \(settings.providerKind.rawValue) default \(ReasoningShape.forKind(settings.providerKind).rawValue)"
    }
    lines.append(shape + " (provider.reasoningShape)")
    // The loop-2 trigger's default (P2): a `do --verify … --yes` run escalates a verifier FAIL to a
    // panel of this many candidates; `--panel-on-fail N` outranks it, `0` switches it off.
    lines.append("panel on fail: \(Self.panelOnFailFact(settings.panelOnVerifierFail)) (policies.panelOnVerifierFail)")
    return lines
  }

  /// The `panel on fail:` row's value: `off` for nil/0/1 (the arming rule's off values), else
  /// `N candidates` — what `Do.panelOnFailArmed` would read as the default.
  static func panelOnFailFact(_ size: Int?) -> String {
    guard let size, size >= 2 else { return "off" }
    return "\(size) candidates"
  }

  /// The `sandbox:` row's value — the facts `StatusReport.sandbox` encodes, in words.
  static func sandboxFact(_ config: SandboxConfig?, supported: Bool) -> String {
    guard let config else {
      return supported
        ? "not configured — unattended runs (do --yes, eval, panel) are confined by default where the platform supports it; interactive opt-in (sandbox)"
        : "not configured — this platform cannot enforce one, so every run is unconfined (sandbox)"
    }
    guard config.enabled else {
      return "off — every run is unconfined, unattended ones included (sandbox.enabled)"
    }
    var row = "on · network \(config.network ?? true ? "on" : "off")"
      + " · \(config.failIfUnavailable ?? true ? "fail if unavailable" : "run unconfined if unavailable")"
    if !supported { row += " — enabled but unsupported on this platform" }
    return row + " (sandbox)"
  }

  /// `300000` → `300 s`, `1500` → `1.5 s`.
  static func seconds(milliseconds: Int) -> String {
    String(format: "%g s", Double(milliseconds) / 1000)
  }

  /// `5000000` → `5 MB`, `256000` → `256 KB`, anything else in bytes.
  static func bytesLabel(_ bytes: Int) -> String {
    if bytes > 0, bytes % 1_000_000 == 0 { return "\(bytes / 1_000_000) MB" }
    if bytes > 0, bytes % 1000 == 0 { return "\(bytes / 1000) KB" }
    return "\(bytes) bytes"
  }

  static func domainList(_ domains: [String]) -> String {
    domains.isEmpty ? "none" : domains.joined(separator: ", ")
  }

  /// `arnes status --json`: every line of the text view as a key. The key/credits fetch is
  /// the same network call the text view makes for the provider kind; a failure there leaves
  /// `key`/`credits` null with `key_error` naming it, never a failed command (a gateway that
  /// has no `/key/info` would otherwise make the whole document unavailable).
  static func report(_ runtime: ArnesRuntime) async throws -> StatusReport {
    let provider = runtime.provider
    var host = provider.baseURL.host ?? ""
    if let port = provider.baseURL.port { host += ":\(port)" }
    var key: StatusReport.Key?
    var credits: StatusReport.Credits?
    var keyError: String?
    var manifestModels: Int?
    switch provider.kind {
    case .openrouter:
      do {
        let info = try await runtime.service.keyInfo()
        let balance = try await runtime.service.credits()
        key = .init(
          label: info.label, freeTier: info.isFreeTier, limit: JSONOut.finite(info.limit),
          limitRemaining: JSONOut.finite(info.limitRemaining), spend: nil, maxBudget: nil,
          models: nil, expires: nil)
        credits = .init(
          remaining: JSONOut.finite(balance.remaining), total: JSONOut.finite(balance.totalCredits))
      } catch {
        keyError = String("\(error)".prefix(200))
      }
    case .litellm:
      let client = LiteLLMClient(
        baseURL: provider.baseURL, apiKey: provider.apiKey, headers: provider.headers,
        tokens: provider.apiKeyCommand.map { BearerTokenSource(command: $0) })
      do {
        let info = try await client.keyInfo()
        key = .init(
          label: info.keyAlias, freeTier: nil, limit: nil, limitRemaining: nil,
          spend: JSONOut.finite(info.spend), maxBudget: JSONOut.finite(info.maxBudget),
          models: info.models, expires: info.expires)
      } catch {
        keyError = String("\(error)".prefix(200))
      }
      manifestModels = try await runtime.catalog.all().count
    case .openaiCompatible:
      manifestModels = try await runtime.catalog.all().count
    }
    // Where the counted manifest came from — only once the catalog was consulted.
    var manifestSource: String?
    var manifestFetchedAt: Date?
    if manifestModels != nil {
      switch await runtime.catalog.manifestSource {
      case .network?: manifestSource = "network"
      case .cache(let at)?: manifestSource = "cache"; manifestFetchedAt = at
      case .staleCache(let at)?: manifestSource = "stale-cache"; manifestFetchedAt = at
      case nil: manifestSource = "unavailable"
      }
    }
    let paths = runtime.pathPolicy
    let settings = Settings(runtime)
    return StatusReport(
      provider: .init(
        name: provider.name, kind: provider.kind.rawValue, baseHost: host,
        keySource: provider.apiKeySource, defaultModel: provider.defaultModel),
      key: key,
      credits: credits,
      keyError: keyError,
      manifestModels: manifestModels,
      manifestSource: manifestSource,
      manifestFetchedAt: manifestFetchedAt,
      subprocessEnv: StatusReport.subprocessEnv(runtime.subprocessEnvironment),
      environmentContext: runtime.environmentContextEnabled,
      limits: StatusReport.limits(runtime.limits),
      paths: .init(protected: paths.protected, sensitiveWrite: paths.sensitiveWrite, denyRead: paths.denyRead),
      sandbox: StatusReport.sandbox(provider.sandbox),
      judge: provider.bashJudge,
      toolResultFraming: settings.framing,
      adaptiveThink: settings.adaptiveThink,
      transport: StatusReport.transport(settings.transport),
      promptCache: StatusReport.promptCache(settings.cachePolicy),
      manifestCache: StatusReport.manifestCache(settings.manifestCache),
      compaction: StatusReport.compaction(settings.compaction),
      checkpoints: StatusReport.checkpoints(settings.checkpoints, root: settings.checkpointRoot),
      memory: StatusReport.memory(settings.memory, root: settings.memoryRoot),
      web: StatusReport.web(settings.web),
      subagents: StatusReport.subagents(settings.subagents),
      reasoningShape: settings.reasoningShape.rawValue,
      panelOnVerifierFail: settings.panelOnVerifierFail)
  }
}

// MARK: - sessions

struct Sessions: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List saved sessions (the default) — and delete, prune, or export them. "
      + "Resume one with `arnes resume <id>`.",
    subcommands: [SessionsList.self, SessionsDelete.self, SessionsPrune.self, SessionsExport.self],
    defaultSubcommand: SessionsList.self)

  /// Resolves a session the way `arnes resume` does — exact id, unique id prefix, or
  /// saved name — with a clear message when there is nothing to resolve against. A query
  /// that names no lead session but a subagent transcript resolves to that, in the nested
  /// store (`subagents/`), so `export` and `delete` work on a subagent's run as they do on
  /// a session; the returned store is the one the transcript lives in.
  static func resolve(_ query: String, in store: SessionStore) throws -> (meta: SessionMeta, store: SessionStore) {
    let sessions = try store.list()
    let nested = store.subagentStore
    let nestedSessions = (try? nested.list()) ?? []
    guard !sessions.isEmpty || !nestedSessions.isEmpty else {
      throw ValidationError("no sessions yet — start one with `arnes`.")
    }
    if case .none = SessionStore.match(query, in: sessions),
       case .found(let meta) = SessionStore.match(query, in: nestedSessions)
    {
      return (meta, nested)
    }
    return (try Resume.resolve(query, in: sessions), store)
  }

  /// `<name>` or the short id, for messages about a session.
  static func label(_ meta: SessionMeta) -> String {
    TerminalText.sanitize(meta.name ?? String(meta.id.prefix(8)))
  }
}

// MARK: - sessions list

struct SessionsList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "List saved sessions, most recently updated first (--agents: subagent transcripts instead).")

  @Flag(help: "List subagent transcripts (id, lead session, agent, model, messages) instead of sessions.")
  var agents = false

  @Flag(help: "Print one JSON array of {id, created_at, updated_at, name, model, cwd, message_count, forked_from, parent, agent, depth, origin} rows instead of text.")
  var json = false

  func run() throws {
    if json {
      let store = agents ? SessionStore().subagentStore : SessionStore()
      try JSONOut.print(try store.list().map(SessionRow.init))
      return
    }
    if agents {
      for line in Self.agentLines(try SessionStore().subagentStore.list()) { print(line) }
      return
    }
    let sessions = try SessionStore().list()
    guard !sessions.isEmpty else {
      print("no sessions yet — start one with `arnes`")
      return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for meta in sessions {
      let name = meta.name ?? "(unnamed)"
      let model = meta.model ?? "?"
      print("\(meta.id)  \(formatter.string(from: meta.updatedAt))  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(model)  \(meta.messageCount) msgs")
    }
  }

  /// `arnes sessions --agents`: one row per subagent transcript — id, when, the lead session
  /// it belongs to (short id), the agent that ran, its model and message count. Agent names
  /// come from agent files, so they are terminal-sanitized.
  static func agentLines(_ transcripts: [SessionMeta]) -> [String] {
    guard !transcripts.isEmpty else {
      return ["no subagent transcripts yet — they are written when a session delegates with the task tool"]
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return transcripts.map { meta in
      let parent = String((meta.parent ?? "?").prefix(8))
      let agent = TerminalText.sanitize(meta.agent ?? "?")
      let model = meta.model ?? "?"
      return "\(meta.id)  \(formatter.string(from: meta.updatedAt))  lead \(parent)  "
        + "\(agent.padding(toLength: 16, withPad: " ", startingAt: 0)) \(model)  \(meta.messageCount) msgs"
    }
  }
}

// MARK: - sessions delete

struct SessionsDelete: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "delete",
    abstract: "Delete a saved session: its transcript and any scratch kept for it.")

  @Argument(help: "Session id, unique id prefix, or saved name.")
  var session: String

  func run() throws {
    let (meta, store) = try Sessions.resolve(session, in: SessionStore())
    try store.delete(id: meta.id)
    print("deleted \(meta.id) (\(Sessions.label(meta)))")
  }
}

// MARK: - sessions prune

struct SessionsPrune: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Delete sessions untouched for a while (named ones are kept unless --all); "
      + "subagent transcripts (`sessions --agents`) are swept by the same age.")

  @Option(name: .customLong("older-than"), help: "Delete sessions untouched for this many days.")
  var olderThan: Int

  @Flag(help: "Also delete named (/save'd) sessions.")
  var all = false

  func run() throws {
    guard olderThan >= 1 else {
      throw ValidationError("--older-than needs at least 1 day (0 would delete everything).")
    }
    let deleted = try SessionStore().prune(olderThan: olderThan, keepNamed: !all)
    guard deleted > 0 else {
      print("nothing to prune — no \(all ? "" : "unnamed ")sessions older than \(olderThan) days")
      return
    }
    print("pruned \(deleted) session\(deleted == 1 ? "" : "s") older than \(olderThan) days")
  }
}

// MARK: - sessions export

struct SessionsExport: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "export",
    abstract: "Write a session out as markdown (stdout, or a file with --out).")

  @Argument(help: "Session id, unique id prefix, or saved name.")
  var session: String

  @Option(name: .customLong("out"), help: "Write to this file instead of stdout.")
  var out: String?

  func run() throws {
    let (meta, store) = try Sessions.resolve(session, in: SessionStore())
    let markdown = try store.exportMarkdown(id: meta.id)
    guard let out else {
      // The transcript carries tool output — model- and command-originated text — so it is
      // made terminal-safe on the way to a terminal. The file gets the document verbatim.
      print(TerminalText.sanitize(markdown), terminator: "")
      return
    }
    let url = URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    print("wrote \(url.path) (\(meta.messageCount) messages)")
  }
}

// MARK: - runs

struct Runs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show the local run scoreboard (per-model cost and verifier pass rate).")

  @Flag(help: "Print the permission audit trail (tool · tier · decision · source · reason) instead of the scoreboard.")
  var decisions = false

  @Flag(name: .customLong("by-agent"), help: "Group runs by provider · model · agent (lead runs as `lead`) with average cost/steps and the partial rate — how often a subagent hit its step or budget cap.")
  var byAgent = false

  @Option(help: "With --decisions: how many recent runs to show (default 10).")
  var limit: Int = 10

  @Option(help: "Only runs started in the last N days.")
  var days: Int?

  @Option(help: "Only runs by this subagent (`lead` for the lead's own turns).")
  var agent: String?

  @Option(help: "Only runs that executed on this wire dialect (chat, messages, responses).")
  var dialect: String?

  @Option(help: "Only runs on this provider (records without one are openrouter).")
  var provider: String?

  @Flag(help: "Print one JSON array instead of text: scoreboard rows, --by-agent rows, or --decisions rows.")
  var json = false

  func run() throws {
    let records = Self.filter(
      try RunRecordStore().all(), days: days, agent: agent, dialect: dialect, provider: provider)
    if json {
      if decisions {
        try JSONOut.print(Self.decisionRows(records, limit: limit))
      } else if byAgent {
        try JSONOut.print(Self.agentRows(records))
      } else {
        try JSONOut.print(Self.scoreboardRows(records))
      }
      return
    }
    guard !records.isEmpty else {
      print("no runs recorded yet — try `arnes do \"...\"`")
      return
    }
    if decisions {
      printDecisions(records)
      return
    }
    if byAgent {
      for line in Self.byAgentLines(records) { print(line) }
      return
    }
    for line in Self.scoreboardLines(records) { print(line) }
  }

  /// `arnes runs --by-agent`: one line per `provider · model · agent` (delegated runs by
  /// their agent name, everything else `lead`), with the run count, average cost and steps,
  /// and the partial rate — the share of runs that ended on `max_steps` or `budget`, what the
  /// lead saw as a `[subagent hit its …]` report. Sorted by key; the provider is shown only
  /// when the history spans more than one, as in the scoreboard. Agent names come from agent
  /// files, so they are terminal-sanitized.
  static func byAgentLines(_ records: [RunRecord]) -> [String] {
    let providers = Set(records.map { $0.provider ?? "openrouter" })
    let grouped = Dictionary(grouping: records) { record -> String in
      let agent = record.agent ?? "lead"
      let modelAgent = "\(record.model) · \(agent)"
      return providers.count > 1 ? "\(record.provider ?? "openrouter") · \(modelAgent)" : modelAgent
    }
    return grouped.sorted(by: { $0.key < $1.key }).map { key, runs in
      let count = Double(runs.count)
      let cost = runs.reduce(0) { $0 + $1.costUSD } / count
      let steps = Double(runs.reduce(0) { $0 + $1.steps }) / count
      let partial = runs.filter(\.partial).count
      return "\(TerminalText.sanitize(key).padding(toLength: 56, withPad: " ", startingAt: 0))"
        + " runs=\(runs.count)\tavg cost=$\(String(format: "%.4f", cost))"
        + "\tavg steps=\(String(format: "%.1f", steps))\tpartial=\(partial)/\(runs.count)"
    }
  }

  /// The per-model scoreboard, one line each. The provider shows only when the history
  /// spans more than one (records predate providers → OpenRouter), the `hooks` column
  /// — PreToolUse blocks and Stop continuations, summed — only when some shown run has hook
  /// telemetry, and the `cache` column — the share of the model's prompt tokens read from the
  /// provider's prompt cache — only when some shown run cached anything, so a scoreboard where
  /// no hook ever fired and nothing was cached is byte-identical to before.
  static func scoreboardLines(_ records: [RunRecord]) -> [String] {
    let providers = Set(records.map { $0.provider ?? "openrouter" })
    let byModel = Dictionary(grouping: records) { record in
      providers.count > 1 ? "\(record.provider ?? "openrouter") · \(record.model)" : record.model
    }
    let anyHookTelemetry = records.contains { ($0.hookBlocks ?? 0) > 0 || ($0.hookContinuations ?? 0) > 0 }
    let anyCached = records.contains { ($0.cachedTokens ?? 0) > 0 }
    let anyConfidence = records.contains { $0.verifierConfidence != nil }
    var lines: [String] = []
    for (model, runs) in byModel.sorted(by: { $0.key < $1.key }) {
      let cost = runs.reduce(0) { $0 + $1.costUSD }
      let verified = runs.filter { $0.verifierPassed != nil }
      let passed = verified.filter { $0.verifierPassed == true }.count
      let passRate = verified.isEmpty ? "n/a" : "\(passed)/\(verified.count)"
      var line = "\(model.padding(toLength: 40, withPad: " ", startingAt: 0)) runs=\(runs.count)\tcost=$\(String(format: "%.4f", cost))\tverified=\(passRate)"
      if anyConfidence {
        line += "\tconfidence=\(confidenceColumn(runs))"
      }
      if anyHookTelemetry {
        let blocks = runs.reduce(0) { $0 + ($1.hookBlocks ?? 0) }
        let continuations = runs.reduce(0) { $0 + ($1.hookContinuations ?? 0) }
        line += "\thooks: blocks=\(blocks) cont=\(continuations)"
      }
      if anyCached {
        line += "\tcache=\(cacheRate(runs))"
      }
      lines.append(line)
    }
    return lines
  }

  /// The loop-1 verifier's stated confidence over a group of runs, by level. Only a verifier that
  /// graded with a schema states one (`RunRecord.verifierConfidence`), so a run whose verdict was
  /// a one-line PASS/FAIL adds to none.
  static func confidenceCounts(_ runs: [RunRecord]) -> (high: Int, medium: Int, low: Int) {
    let stated = runs.compactMap(\.verifierConfidence)
    return (
      stated.filter { $0 == "high" }.count,
      stated.filter { $0 == "medium" }.count,
      stated.filter { $0 == "low" }.count)
  }

  /// The `confidence=` column — the levels with a count, in the fixed order high · medium · low
  /// (`high:2 medium:1`), or `n/a` for a group whose verified runs stated none. The column shows
  /// only when some shown run stated a confidence, gated like `hooks:` and `cache=`.
  static func confidenceColumn(_ runs: [RunRecord]) -> String {
    let counts = confidenceCounts(runs)
    let parts = [("high", counts.high), ("medium", counts.medium), ("low", counts.low)]
      .filter { $0.1 > 0 }
      .map { "\($0.0):\($0.1)" }
    return parts.isEmpty ? "n/a" : parts.joined(separator: " ")
  }

  /// The cache hit rate of a group of runs — cached prompt tokens over prompt tokens, summed
  /// over the runs that reported prompt tokens — as `N%`, or `n/a` when none reported any.
  static func cacheRate(_ runs: [RunRecord]) -> String {
    let counted = runs.filter { $0.promptTokens != nil }
    let prompt = counted.reduce(0) { $0 + ($1.promptTokens ?? 0) }
    guard prompt > 0 else { return "n/a" }
    let cached = counted.reduce(0) { $0 + ($1.cachedTokens ?? 0) }
    return "\(min(100, cached * 100 / prompt))%"
  }

  /// `arnes runs --decisions` — the permission audit trail, newest run last, one row per
  /// gated call. Answers "who allowed that?" after the fact; the scoreboard above answers
  /// "what did it cost?". Tool names and reasons come from tools and hooks, so they are
  /// sanitized before printing.
  private func printDecisions(_ records: [RunRecord]) {
    let audited = records.filter { !($0.decisions ?? []).isEmpty }
    guard !audited.isEmpty else {
      print("no permission decisions recorded yet — every gated tool call lands here")
      return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for record in audited.suffix(max(1, limit)) {
      let rows = record.decisions ?? []
      let stop = record.stopReason.map { " · \($0.rawValue)" } ?? ""
      print("\(formatter.string(from: record.startedAt))  \(TerminalText.sanitize(record.model))"
        + "  \(rows.count) decision\(rows.count == 1 ? "" : "s")\(stop)")
      for row in rows {
        let outcome = row.decision == .allow ? ANSI.green("allow") : ANSI.yellow("deny ")
        let reason = row.reason.map { " · " + TerminalText.sanitize($0) } ?? ""
        print("  \(TerminalText.sanitize(row.tool).padding(toLength: 16, withPad: " ", startingAt: 0))"
          + " \(row.tier.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0))"
          + " \(outcome) \(row.source.rawValue)\(reason)")
      }
    }
  }
}
