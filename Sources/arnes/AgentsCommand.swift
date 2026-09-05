import ArgumentParser
import ArnesKit
import Foundation

/// `arnes agents` — list the subagents the loop would load from the current directory:
/// name, model, description, and which file each one came from. `arnes agents apply` folds an
/// isolated subagent's snapshot into the tree.
struct Agents: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List subagents loaded from .arnes/agents, .claude/agents, ~/.arnes/agents, and ~/.claude/agents "
      + "(the default); `apply` folds an isolated subagent's snapshot into the working tree.",
    subcommands: [AgentsApply.self])

  @Flag(help: "Print one JSON array of {name, description, model, tools, disallowed_tools, permission_mode, max_steps, budget_usd, effort, skills, background, isolation, warnings, source, builtin} rows instead of text.")
  var json = false

  func run() async throws {
    let agents = AgentLibrary.discover()
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let trusted = ProjectTrustStore().isTrusted(cwd)
    // The skill library a run here would hand the task tool — the directory's own skills
    // only once it is trusted, exactly as `do`/`interactive` load them — so a `skills:` list
    // is checked against what would really preload: an unknown name or a body past the cap
    // is a warning here, the way a bad frontmatter value is, and a name that resolves only
    // among the not-yet-trusted project skills is reported as that, not as unknown.
    let skills = SkillLibrary.discover(includeProject: trusted)
    let untrustedProjectSkills = trusted ? [] : SkillLibrary.projectSkills(workdir: cwd).map(\.name)
    if json {
      try JSONOut.print(agents.map { agent in
        AgentRow(agent, extraWarnings: AgentsFormat.preloadWarnings(
          for: agent, library: skills, untrustedProjectSkills: untrustedProjectSkills))
      })
      return
    }
    let home = NSHomeDirectory()
    // Agent files are project content — names, models, and descriptions are untrusted.
    for agent in agents {
      print(TerminalText.sanitize("\(ANSI.bold(agent.name))  \(ANSI.secondary(agent.model ?? "inherit"))"))
      if !agent.description.isEmpty { print(TerminalText.sanitize("  \(agent.description)")) }
      if let tools = agent.tools { print(ANSI.dim(TerminalText.sanitize("  tools: \(tools.joined(separator: ", "))"))) }
      if let disallowed = agent.disallowedTools {
        print(ANSI.dim(TerminalText.sanitize("  disallowed: \(disallowed.joined(separator: ", "))")))
      }
      // Caps and posture: what this file actually narrows, so a typo'd guardrail is visible.
      var facts: [String] = []
      if agent.permissionMode == .readOnly { facts.append("read-only") }
      if let steps = agent.maxSteps { facts.append("max \(steps) steps") }
      if let budget = agent.budgetUSD { facts.append("budget $\(String(format: "%.2f", budget))") }
      if let effort = agent.effort { facts.append("effort \(effort.rawValue)") }
      // Preloading happens in the task tool; a lead run as this agent (`do --agent`) gets
      // the role, not the skills — the label says which.
      if let names = agent.skills { facts.append("skills (preloaded when delegated): \(names.joined(separator: ", "))") }
      if agent.background { facts.append("background") }
      facts += AgentsFormat.contextModeFacts(for: agent)
      if let memory = agent.memory { facts.append("memory \(memory)") }
      if !facts.isEmpty { print(ANSI.dim(TerminalText.sanitize("  \(facts.joined(separator: " · "))"))) }
      let preload = AgentsFormat.preloadWarnings(
        for: agent, library: skills, untrustedProjectSkills: untrustedProjectSkills)
      for warning in agent.warnings + preload {
        print(ANSI.yellow(TerminalText.sanitize("  ⚠ \(warning)")))
      }
      let origin = agent.source.map {
        $0.path.hasPrefix(home) ? "~" + $0.path.dropFirst(home.count) : $0.path
      } ?? "built-in"
      print(ANSI.dim("  \(origin)"))
    }
    print(ANSI.dim(
      "\n\(agents.count) agent\(agents.count == 1 ? "" : "s") — the model delegates with the "
        + "task tool; add <name>.md files (Claude Code agent format) under .arnes/agents, "
        + ".claude/agents, ~/.arnes/agents, or ~/.claude/agents"))
    if !AgentLibrary.projectAgents(workdir: cwd).isEmpty, !trusted {
      print(ANSI.yellow("this directory's own agents load only once it is trusted — `arnes trust` here, or --trust-project"))
    }
  }
}

// MARK: - agents apply

/// `arnes agents apply <snapshot> [--into <dir>] [--yes]` — fold the changes an
/// `isolation: worktree` subagent made in its snapshot into a working tree. The snapshot's
/// `work` is compared with its pristine `base`; a file the tree changed meanwhile is a
/// conflict, listed and left alone (`WorkspaceSnapshot.apply`). Only arnes snapshots
/// (`arnes-agent-*/<run>/{work,base}`) are accepted — this applies a subagent's run, not an
/// arbitrary directory.
struct AgentsApply: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "apply",
    abstract: "Fold an isolated subagent's snapshot into the working tree, skipping files that changed meanwhile.")

  @Argument(help: "The snapshot: its run directory, or the work/ (or base/) path a report named.")
  var snapshot: String

  @Option(name: .customLong("into"), help: "The tree to apply into (default: the current directory).")
  var into: String?

  @Flag(name: .customLong("yes"), help: "Apply without confirming (required when stdin is not a terminal).")
  var yes = false

  func run() async throws {
    guard let layout = WorkspaceSnapshot.Layout.resolve(URL(fileURLWithPath: snapshot)) else {
      throw ValidationError(
        "\(snapshot) is not an arnes agent snapshot (expected <tmp>/\(WorkspaceSnapshot.Layout.prefix)<lead>/<run> "
          + "with work/ and base/ inside, as an isolated subagent's report names it)")
    }
    let destination = URL(fileURLWithPath: into ?? FileManager.default.currentDirectoryPath)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw ValidationError("\(destination.path) is not a directory")
    }

    let plan = try WorkspaceSnapshot.apply(from: layout.work, base: layout.base, into: destination, dryRun: true)
    for line in AgentsApplyFormat.lines(plan, destination: destination, applied: false) {
      print(TerminalText.sanitize(line))
    }
    guard !plan.applied.isEmpty || !plan.deleted.isEmpty else { return }
    if !yes {
      guard TerminalInput.isInteractive else {
        throw ValidationError("pass --yes to apply without a terminal")
      }
      guard TerminalInput.confirm("apply these changes to \(destination.path)? [y/N]") else {
        print("not applied")
        return
      }
    }
    let report = try WorkspaceSnapshot.apply(from: layout.work, base: layout.base, into: destination)
    for line in AgentsApplyFormat.lines(report, destination: destination, applied: true) {
      print(TerminalText.sanitize(line))
    }
  }
}

/// How `arnes agents apply` prints a plan and a report. Pure.
enum AgentsApplyFormat {
  /// One line per file under a heading per kind, then the summary: what would be (or was)
  /// applied and deleted, and the conflicts left in place.
  static func lines(_ report: WorkspaceSnapshot.ApplyReport, destination: URL, applied: Bool) -> [String] {
    var lines: [String] = []
    if report.isEmpty {
      return ["nothing to apply: the snapshot matches \(destination.path)"]
    }
    let verb = applied ? "applied" : "would apply"
    let deleteVerb = applied ? "deleted" : "would delete"
    if !report.applied.isEmpty {
      lines.append("\(verb) (\(report.applied.count)):")
      lines += report.applied.map { "  + \($0)" }
    }
    if !report.deleted.isEmpty {
      lines.append("\(deleteVerb) (\(report.deleted.count)):")
      lines += report.deleted.map { "  - \($0)" }
    }
    if !report.conflicts.isEmpty {
      lines.append("conflicts — changed in \(destination.path) since the snapshot, left as they are (\(report.conflicts.count)):")
      lines += report.conflicts.map { "  ! \($0)" }
    }
    if applied {
      lines.append("\(report.applied.count) applied · \(report.deleted.count) deleted · \(report.conflicts.count) conflict\(report.conflicts.count == 1 ? "" : "s")")
    } else if report.applied.isEmpty, report.deleted.isEmpty {
      lines.append("nothing to apply: every changed file conflicts")
    }
    return lines
  }
}

/// How `arnes agents` reports an agent's `skills:` preload and context modes. Pure, so it is
/// testable without a directory or a trust store.
enum AgentsFormat {
  /// The listing facts for an agent's context modes: `fork` when it starts from the lead's
  /// conversation, `isolation <value>` as written — with `(not applied)` when the value isn't
  /// one the task tool enforces (the warning says why).
  static func contextModeFacts(for agent: AgentDefinition) -> [String] {
    var facts: [String] = []
    if agent.fork { facts.append("fork") }
    if let isolation = agent.isolation {
      facts.append("isolation \(isolation)" + (agent.isSnapshotIsolated ? "" : " (not applied)"))
    }
    return facts
  }

  /// The preload warnings for `agent` against `library` — the skills a run here would hand
  /// the task tool, trust-gated like `Do.run`/`Interactive.run` gate them — with a name that
  /// resolves only among this directory's own, not-yet-trusted skills
  /// (`untrustedProjectSkills`) reported as such rather than as unknown.
  static func preloadWarnings(
    for agent: AgentDefinition, library: [Skill], untrustedProjectSkills: [String])
    -> [String]
  {
    var warnings = AgentLibrary.preloadedSkillsSection(for: agent, from: library).warnings
    let known = Set(library.map(\.name))
    var reported = Set<String>()
    for name in agent.skills ?? []
      where !known.contains(name) && untrustedProjectSkills.contains(name) && reported.insert(name).inserted
    {
      warnings.removeAll { $0 == "skills: no skill named '\(name)' — not preloaded" }
      warnings.append("skills: '\(name)' is this directory's own skill — preloaded only once the directory is trusted")
    }
    return warnings
  }
}
