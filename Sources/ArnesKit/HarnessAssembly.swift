import Foundation

// MARK: - ToolContext

/// Where a toolset operates: the directory paths resolve against and bash runs in, the OS
/// sandbox around bash, and the environment policy every subprocess inherits. One value
/// describes the context for a REPL, a headless run, a panel candidate's snapshot, an eval
/// trial or a subagent — so none of them can forget a piece of it.
public struct ToolContext: Sendable {
  /// Root for relative paths and bash's CWD; nil = the process CWD. Panel candidates and
  /// eval trials each bind their own snapshot here, so parallel runs never touch the
  /// process CWD.
  public var root: URL?
  /// OS confinement for the run (`ShellSandbox`), when the provider opted in or the run is
  /// unattended. It wraps `bash` at the kernel level and gates `write_file`/`edit_file`
  /// in-process (they never reach a shell), so one value means one boundary. nil = unconfined.
  public var sandbox: ShellSandbox?
  /// What bash (and hooks) inherit of the environment; the provider token is withheld
  /// regardless.
  public var environment: SubprocessEnvironment
  /// How paths classify beyond the root: the directories `--add-dir` opened (they count as
  /// inside) and the config's extra protected / deny-read globs. See `PathScope.Rules`.
  public var pathRules: PathScope.Rules
  /// What the run has read of each file, shared by `read_file`/`write_file`/`edit_file` so
  /// an edit to a never-read or changed-underneath file is refused instead of clobbering
  /// it. Defaults to a fresh tracker per context — one per REPL session, headless run,
  /// panel candidate, eval trial or subagent, which is the scope "this session has read it"
  /// means. nil disables the checks.
  public var versions: FileVersions?
  /// The output size `bash` is built for (`limits.bashOutputChars`): the runner keeps 2× this
  /// of head and of tail per command. The session's `toolResultMaxChars` decides what the model
  /// reads. See `BashTool.defaultOutputChars`.
  public var bashOutputChars: Int
  /// Who answers the model's clarifying questions (the `ask_user` tool). The REPL binds a
  /// terminal prompt; every unattended runner keeps the default, which tells the model no
  /// user is present. A nested session inherits the lead's through its `ToolContext`.
  public var userInput: any UserInputDelegate
  /// Where `write_file`/`edit_file` keep each file's pre-image before they write, so the REPL's
  /// `/rewind` can put the tree back to the start of a turn. nil (the default, and what every
  /// unattended runner keeps) records nothing. See `FileCheckpointStore`.
  public var checkpoints: (any CheckpointStore)?
  /// Where `bash … background: true` runs its jobs and what the `job` tool polls
  /// (`JobRegistry`, one per session). nil (the default, and what panels, evals and the probe
  /// keep) = no background jobs and no `job` tool in the toolset.
  public var jobs: JobRegistry?
  /// The per-command `bash` timeout when a call names none (`limits.bashTimeoutSeconds`; a call's
  /// own `timeout_seconds` overrides it up to `BashTool.maxTimeoutSeconds`).
  public var bashTimeoutSeconds: Int
  /// What `web_fetch` may reach (`WebFetchPolicy`, from the config's `web` block). nil (the
  /// default, and what panels, evals, the probe and `review` keep) = no `web_fetch` tool. Even
  /// when set, the tool is left out under a sandbox that denies the network — the tool is
  /// network egress, and "network off" means off for every tool.
  public var web: WebFetchPolicy?

  public init(
    root: URL? = nil,
    sandbox: ShellSandbox? = nil,
    environment: SubprocessEnvironment = .default,
    pathRules: PathScope.Rules = .default,
    versions: FileVersions? = FileVersions(),
    bashOutputChars: Int = BashTool.defaultOutputChars,
    userInput: any UserInputDelegate = NoUserInput(),
    checkpoints: (any CheckpointStore)? = nil,
    jobs: JobRegistry? = nil,
    bashTimeoutSeconds: Int = BashTool.defaultTimeoutSeconds,
    web: WebFetchPolicy? = nil)
  {
    self.root = root
    self.sandbox = sandbox
    self.environment = environment
    self.pathRules = pathRules
    self.versions = versions
    self.bashOutputChars = bashOutputChars
    self.userInput = userInput
    self.checkpoints = checkpoints
    self.jobs = jobs
    self.bashTimeoutSeconds = bashTimeoutSeconds
    self.web = web
  }
}

// MARK: - HarnessAssembly

/// The one place a toolset is put together. Every execution path — interactive, `do`,
/// panel candidates, eval trials, subagents, the conformance probe — builds its tools here
/// from a `ToolContext`, so a confinement or policy that lands in the context reaches all
/// of them at once instead of being wired (or forgotten) per caller.
public enum HarnessAssembly {
  /// The coding toolset for a context: read/write/edit, bash (+ `job` when the context has a
  /// registry), grep/glob, `view_image` (+ `web_fetch` when the context has a `web` policy and
  /// the sandbox allows the network), the planning tools and `ask_user`. Order is what the model
  /// sees in its tool list. `view_image` is built for every context and *offered* per model
  /// (`CapabilityGatedTool`: only one whose manifest says it takes images) — a request-time
  /// absence, not a toolset absence.
  public static func coreTools(_ context: ToolContext = ToolContext()) -> [any AgentTool] {
    var tools: [any AgentTool] = [
      ReadFileTool(root: context.root, rules: context.pathRules, versions: context.versions),
      // The write tools take the sandbox too: they don't go through a shell, so without the
      // in-process mirror a confined run would still let them write anywhere. And the
      // checkpoint store, when the context has one: the pre-image before every write.
      WriteFileTool(
        root: context.root, rules: context.pathRules, versions: context.versions,
        sandbox: context.sandbox, checkpoints: context.checkpoints),
      EditFileTool(
        root: context.root, rules: context.pathRules, versions: context.versions,
        sandbox: context.sandbox, checkpoints: context.checkpoints),
      BashTool(
        root: context.root, rules: context.pathRules, timeoutSeconds: context.bashTimeoutSeconds,
        sandbox: context.sandbox, environment: context.environment,
        outputChars: context.bashOutputChars, jobs: context.jobs),
    ]
    // The job tool right after bash, over the same registry: without one there are no jobs to
    // poll, and bash says so when asked for `background: true`.
    if let jobs = context.jobs {
      tools.append(JobTool(registry: jobs))
    }
    tools += [
      GrepTool(root: context.root, rules: context.pathRules),
      GlobTool(root: context.root, rules: context.pathRules),
      // Reads a file like `read_file` (same root, same path gate); offered only to a model with
      // vision, decided per request by the session.
      ViewImageTool(root: context.root, rules: context.pathRules),
    ]
    // Network egress, only where the user configured it and the sandbox allows the network:
    // a run confined with `network: false` gets no fetch tool either.
    if let web = context.web, context.sandbox?.allowNetwork != false {
      tools.append(WebFetchTool(policy: web))
    }
    tools += [
      PlanTool(),
      ThinkTool(),
      // Last, and answered by whoever the context binds: a terminal prompt in the REPL, "no
      // user is present" everywhere unattended. A nested toolset drops it (Subagents.swift).
      AskUserTool(userInput: context.userInput),
    ]
    return tools
  }

  /// Core tools plus the caller's additions — skills, MCP bridges, the task tool — in the
  /// order the model sees them.
  public static func tools(_ context: ToolContext, extras: [any AgentTool] = []) -> [any AgentTool] {
    coreTools(context) + extras
  }
}
