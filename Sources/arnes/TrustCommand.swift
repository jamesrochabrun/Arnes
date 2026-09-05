import ArgumentParser
import ArnesKit
import Foundation

// MARK: - ProjectTrustGate

/// Decides whether a run loads the working directory's own `.arnes/` and `.claude/`
/// skills and agents — and its `AGENTS.md` / `CLAUDE.md`. Those files are the
/// repository's, not the user's: they put text in the system prompt and define subagents
/// (prompt, tools, model). The REPL asks once per directory and remembers the answer;
/// headless runs never guess — untrusted project content is skipped with a notice until
/// `--trust-project` or `arnes trust`.
enum ProjectTrustGate {
  struct Outcome {
    let includeProject: Bool
    /// One line for the transcript/stderr explaining what happened, when anything did.
    let notice: String?
  }

  static func evaluate(
    trustFlag: Bool,
    interactive: Bool,
    store: ProjectTrustStore = ProjectTrustStore(),
    cwd: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    instructionOptions: ProjectInstructions.Options = .default,
    print out: (String) -> Void = { Swift.print($0) })
    -> Outcome
  {
    let content = ProjectContent.discover(workdir: cwd, instructionOptions: instructionOptions)
    guard !content.isEmpty else {
      return Outcome(includeProject: true, notice: nil)
    }
    let what = content.describe()
    if trustFlag {
      return Outcome(includeProject: true, notice: remember(cwd, in: store, what: what, remembered: "— loading its \(what)"))
    }
    if store.isTrusted(cwd) {
      return Outcome(includeProject: true, notice: nil)
    }
    guard interactive, TerminalInput.isInteractive else {
      // A repository's MCP servers are commands the run would start: name them, so a headless
      // log says exactly what stayed off (X9).
      let servers = content.mcpServers.map { "\n  mcp: \($0.name) (\($0.transport))" }.joined()
      return Outcome(
        includeProject: false,
        notice: "skipping \(what) from \(abbreviate(cwd.path)) — directory not trusted; "
          + "pass --trust-project, or run `arnes trust` there once" + servers)
    }

    out(ANSI.yellow("⚠ this directory defines \(what):"))
    for row in listing(content) { out(row) }
    out(ANSI.dim("  They add instructions to the model's system prompt and can run as subagents with"))
    out(ANSI.dim("  their own prompt and model. Only load files you'd read yourself."))
    if !content.hooks.isEmpty {
      out(ANSI.dim("  Hooks run shell commands around every tool call: trusting the directory is only"))
      out(ANSI.dim("  half of it — they stay off until `arnes hooks trust` approves each one by hash."))
    }
    if !content.mcpServers.isEmpty {
      out(ANSI.dim("  MCP servers from a repository run as untrusted: every result taints the session,"))
      out(ANSI.dim("  none can be required, and a user entry of the same name always wins."))
    }
    out("  load them? " + ANSI.bold("[y]es and remember · [o]nce · [n]o") + " ")
    let key = TerminalInput.readKey()?.lowercased()
    switch key {
    case "y":
      return Outcome(
        includeProject: true,
        notice: remember(cwd, in: store, what: what, remembered: "(remembered in \(abbreviate(store.url.path)))"))
    case "o":
      return Outcome(includeProject: true, notice: "loading this directory's \(what) for this session only")
    default:
      return Outcome(
        includeProject: false,
        notice: "project skills/agents/instructions not loaded — `arnes trust` here, or --trust-project, to allow them")
    }
  }

  /// Records trust for `cwd` and says so — or, when the store refuses (the home directory, an
  /// ancestor of it, `/`) or cannot be written, loads the content **for this session only**
  /// and says that instead: the `[o]nce` outcome, never a "trusted" line for a trust that was
  /// not recorded (the next run would ask again).
  static func remember(_ cwd: URL, in store: ProjectTrustStore, what: String, remembered: String) -> String {
    do {
      try store.trust(cwd)
      return "trusted \(abbreviate(cwd.path)) \(remembered)"
    } catch let error as ProjectTrustError {
      return "loading this directory's \(what) for this session only — \(error.description)"
    } catch {
      return "loading this directory's \(what) for this session only — could not write "
        + "\(abbreviate(store.url.path)): \(error.localizedDescription)"
    }
  }

  /// What the prompt shows before asking: one row per file, already terminal-safe.
  static func listing(_ content: ProjectContent) -> [String] {
    var rows: [String] = []
    for skill in content.skills {
      rows.append(TerminalText.sanitize(
        "  skill  \(skill.name)  \(ANSI.dim(String(skill.description.prefix(70))))"))
    }
    for agent in content.agents {
      let model = agent.model ?? "inherit"
      rows.append(TerminalText.sanitize(
        "  agent  \(agent.name)  \(ANSI.dim("model \(model) · \(String(agent.description.prefix(50)))"))"))
    }
    for source in content.instructions {
      // An instruction file is pure system-prompt text, so the size is the useful signal.
      let imports = source.imports.isEmpty
        ? ""
        : " · imports \(source.imports.map(\.lastPathComponent).joined(separator: ", "))"
      rows.append(TerminalText.sanitize(
        "  instructions: \(ProjectInstructions.abbreviate(source.path))  "
          + ANSI.dim("(\(source.byteCount) bytes)\(imports)")))
    }
    for hook in content.hooks {
      // A hook is a shell command (or, for a prompt hook, a question put to a model), so the
      // text itself is what the user must read.
      let body = hook.type == .prompt ? "prompt: \(hook.prompt ?? "")" : hook.command
      rows.append(TerminalText.sanitize(
        "  hook   \(hook.event.rawValue) \(hook.label)  "
          + ANSI.dim("\(String(body.prefix(60))) — needs `arnes hooks trust` too")))
    }
    for server in content.mcpServers {
      // An MCP server is a command the run starts (or a host it talks to): the transport line
      // is the whole story — never a header value or a URL path (X9).
      rows.append(TerminalText.sanitize(
        "  mcp    \(server.name)  "
          + ANSI.dim("\(server.transport) — loads as untrusted (every result taints), never required")))
    }
    return rows
  }

  static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

// MARK: - trust

/// `arnes trust` — trust the current directory's project-local skills, agents and
/// instruction files, list trusted directories, or forget one.
struct Trust: ParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Trust this directory's .arnes/.claude skills, agents and AGENTS.md (or --list / --forget / --show).",
    discussion: """
      Project-local skills, agents and instruction files (AGENTS.md / CLAUDE.md) come from
      whoever wrote the repository, so the REPL asks before loading them and headless
      `arnes do` skips them until the directory is trusted. Trust is remembered per
      resolved directory path in ~/.arnes/trusted.json, and a trusted directory covers its
      subdirectories up to the repository root (the nearest `.git`) — never its neighbors, and
      never through your home directory, which cannot be trusted (nor can its parents or /).

      A directory's .arnes/hooks.json needs this *and* `arnes hooks trust`, which approves
      each hook by content hash — hooks run shell commands around every tool call.
      """)

  @Argument(help: "Directory (default: the current one).")
  var directory: String?

  @Flag(help: "List trusted directories.")
  var list = false

  @Flag(help: "Forget the directory instead of trusting it.")
  var forget = false

  @Flag(help: "Show what the directory defines and whether it is trusted (and through which directory); changes nothing.")
  var show = false

  func validate() throws {
    if [list, forget, show].filter({ $0 }).count > 1 {
      throw ValidationError("--list, --forget and --show are exclusive")
    }
  }

  func run() throws {
    let store = ProjectTrustStore()
    if list {
      let all = store.all()
      guard !all.isEmpty else {
        print("no trusted directories yet — run `arnes trust` inside a project to add one")
        return
      }
      for path in all { print(TerminalText.sanitize(ProjectTrustGate.abbreviate(path))) }
      return
    }
    let target = URL(fileURLWithPath: directory ?? FileManager.default.currentDirectoryPath)
    if show {
      for line in TrustShow.lines(for: target, store: store) { print(line) }
      return
    }
    if forget {
      try store.forget(target)
      print("forgot \(ProjectTrustGate.abbreviate(target.path))")
      return
    }
    do {
      try store.trust(target)
    } catch let error as ProjectTrustError {
      throw ValidationError(error.description)
    }
    let content = ProjectContent.discover(workdir: target)
    let what = content.isEmpty
      ? "it defines no skills, agents, instruction files or hooks right now"
      : "it defines \(content.describe())"
    print("trusted \(ProjectTrustGate.abbreviate(target.path)) — \(what)")
    if !content.hooks.isEmpty {
      // Trusting a directory is not approving the commands it runs; that is a second yes.
      print(ANSI.dim("its hooks still need `arnes hooks trust` — they run shell commands "
        + "around every tool call, and each one is approved by content hash"))
    }
  }
}

// MARK: - TrustShow

/// `arnes trust --show`: the discovery report for a directory — what it defines, whether it is
/// trusted and through which directory, and which of its hooks are approved by hash. Pure over
/// the store and the directory, so it is testable against a temp home.
enum TrustShow {
  static func lines(for directory: URL, store: ProjectTrustStore) -> [String] {
    var lines: [String] = []
    let shown = ProjectTrustGate.abbreviate(directory.path)
    let resolved = URL(fileURLWithPath: directory.path).standardizedFileURL.resolvingSymlinksInPath().path
    if let via = store.trustingDirectory(for: directory) {
      let through = via == resolved ? "" : " (via \(ProjectTrustGate.abbreviate(via)))"
      lines.append(TerminalText.sanitize("\(shown): trusted\(through)"))
    } else {
      lines.append(TerminalText.sanitize("\(shown): not trusted — `arnes trust` here, or --trust-project on a run"))
    }
    let content = ProjectContent.discover(workdir: directory)
    guard !content.isEmpty else {
      lines.append(ANSI.dim("defines no skills, agents, instruction files or hooks"))
      return lines
    }
    lines.append(TerminalText.sanitize("defines \(content.describe()):"))
    lines.append(contentsOf: ProjectTrustGate.listing(content))
    if !content.hooks.isEmpty {
      let approved = store.trustedHookHashes(for: directory)
      let unapproved = content.hooks.filter { !approved.contains($0.fingerprint) }
      lines.append(unapproved.isEmpty
        ? ANSI.dim("hooks: every hook approved by hash (`arnes hooks trust`)")
        : ANSI.yellow(TerminalText.sanitize(
            "hooks: \(unapproved.count) of \(content.hooks.count) not approved by hash — "
              + "`arnes hooks trust` after reading them")))
    }
    return lines
  }
}
