import ArgumentParser
import ArnesKit
import Foundation

// MARK: - arnes memory

/// `arnes memory` — the model's own notes (C3): what is kept for which project under
/// `~/.arnes/memory`, the current project's index, and a way to forget it. Offline: reads the
/// config for the root and the repo-root markers, never a provider or a key.
struct MemoryCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "memory",
    abstract: "Auto-memory: the notes the model keeps per project under ~/.arnes/memory (list, show, forget).",
    discussion: "Each project gets `<root>/<project key>/MEMORY.md` — the index the model loads into its "
      + "system prompt as the `# Memory` section — plus topic files it links from there, and "
      + "`agents/<name>/` for subagents whose frontmatter asks for memory. The model edits them with "
      + "write_file/edit_file; every such write asks the user first (and is refused under `do --yes` "
      + "unless --add-dir names the directory). Config: top-level `memory` in ~/.arnes/config.json "
      + "({enabled, directory, maxLines, maxBytes}); ARNES_MEMORY_DIR overrides the root.",
    subcommands: [MemoryList.self, MemoryShow.self, MemoryForget.self],
    defaultSubcommand: MemoryList.self)
}

/// What every `memory` subcommand starts from: the root, the caps and the current project's store.
struct MemorySetup {
  let root: URL
  let config: MemoryConfig
  let current: MemoryStore

  init(workdir: URL = ArnesRuntime.workingDirectory) throws {
    let loaded: ArnesConfig?
    do {
      loaded = try ArnesConfig.load()
    } catch {
      throw ValidationError("\(ArnesConfig.defaultURL.path) is invalid: \(error)")
    }
    config = loaded?.memory ?? MemoryConfig()
    root = MemoryStore.root(configured: config.directory)
    current = MemoryStore.forProject(
      workdir: workdir, memoryRoot: root, options: ProjectInstructions.Options(config: loaded?.instructions),
      maxLines: config.effectiveMaxLines, maxBytes: config.effectiveMaxBytes)
  }

  /// The scope a subcommand's `--agent` names, or the project's own.
  func scope(agent: String?) -> MemoryStore {
    agent.map { current.agentScope(named: $0) } ?? current
  }
}

// MARK: list

struct MemoryList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list", abstract: "Every project with memory under the root, this project marked.")

  @Flag(help: "Print one JSON array of {key, directory, index_path, exists, lines, bytes, loaded_lines, truncated, flagged, agents, current} rows instead of text.")
  var json = false

  func run() async throws {
    let setup = try MemorySetup()
    let stores = MemoryStore.projects(
      under: setup.root, maxLines: setup.config.effectiveMaxLines, maxBytes: setup.config.effectiveMaxBytes)
    let home = NSHomeDirectory()
    if json {
      try JSONOut.print(stores.map { MemoryRow($0, current: $0.directory == setup.current.directory) })
      return
    }
    guard !stores.isEmpty else {
      print("no memory yet — the model writes \(MemoryFormat.abbreviate(setup.current.indexURL.path, home: home)) when it learns something worth keeping")
      if !setup.config.isEnabled { print(ANSI.yellow("memory is disabled in config (memory.enabled: false)")) }
      return
    }
    for store in stores {
      for line in MemoryFormat.rows(for: store, home: home, current: store.directory == setup.current.directory) {
        print(line)
      }
    }
    print(ANSI.dim("\n\(stores.count) project\(stores.count == 1 ? "" : "s") under \(MemoryFormat.abbreviate(setup.root.path, home: home)) — `arnes memory show` prints this project's index"))
    if !setup.config.isEnabled { print(ANSI.yellow("memory is disabled in config (memory.enabled: false) — nothing here is loaded")) }
  }
}

// MARK: show

struct MemoryShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show", abstract: "This project's MEMORY.md (or a subagent's, with --agent) as the model reads it.")

  @Option(help: "Show the scope of this subagent (agents/<name>/) instead of the project's.")
  var agent: String?

  @Flag(help: "Print one JSON object {key, directory, index_path, exists, lines, bytes, flagged, text} instead of text.")
  var json = false

  func run() async throws {
    let setup = try MemorySetup()
    let store = setup.scope(agent: agent)
    if json {
      try JSONOut.print(MemoryShowReport(store))
      return
    }
    for line in MemoryFormat.showLines(for: store, home: NSHomeDirectory()) { print(line) }
  }
}

// MARK: forget

struct MemoryForget: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "forget", abstract: "Delete this project's memory directory (or one subagent's scope, or every project's with --all), after a y/N.")

  @Option(help: "Forget only this subagent's scope (agents/<name>/ under the project's directory).")
  var agent: String?

  @Flag(help: "Forget every project's memory under the root, not just this project's.")
  var all = false

  @Flag(name: .customLong("yes"), help: "Delete without confirming (required when stdin is not a terminal).")
  var yes = false

  func validate() throws {
    if all, agent != nil { throw ValidationError("--all and --agent contradict: --all forgets every project, --agent one subagent's scope") }
  }

  func run() async throws {
    let setup = try MemorySetup()
    let home = NSHomeDirectory()
    let targets: [MemoryStore] = all
      ? MemoryStore.projects(under: setup.root)
      : [setup.scope(agent: agent)]
    let existing = targets.filter(\.exists)
    guard !existing.isEmpty else {
      print("nothing to forget — \(MemoryFormat.abbreviate((targets.first ?? setup.current).directory.path, home: home)) does not exist")
      return
    }
    for store in existing { print("would delete \(MemoryFormat.abbreviate(store.directory.path, home: home))") }
    if !yes {
      guard TerminalInput.isInteractive else {
        throw ValidationError("pass --yes to forget without a terminal")
      }
      guard TerminalInput.confirm("delete \(existing.count == 1 ? "this directory" : "these \(existing.count) directories") and everything in \(existing.count == 1 ? "it" : "them")? [y/N]") else {
        print("kept")
        return
      }
    }
    for store in existing {
      try store.forget()
      print("forgot \(MemoryFormat.abbreviate(store.directory.path, home: home))")
    }
  }
}

// MARK: - MemoryFormat

/// How memory reads in `arnes memory` and the REPL's `/memory`. The index is the model's
/// writing (and may quote anything it read), so every line of it is terminal-sanitized. Pure.
enum MemoryFormat {
  /// `~`-abbreviated path.
  static func abbreviate(_ path: String, home: String) -> String {
    path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
  }

  /// One project in the listing: the key (marked when it is this project's), the index's path,
  /// lines and bytes (or that there is none yet), the agent scopes, and the scanner's warning.
  static func rows(for store: MemoryStore, home: String, current: Bool) -> [String] {
    var rows = [ANSI.bold(TerminalText.sanitize(store.key)) + (current ? ANSI.dim("  (this project)") : "")]
    let index = abbreviate(store.indexURL.path, home: home)
    if let loaded = store.load() {
      var facts = "\(index) · \(loaded.lineCount) line\(loaded.lineCount == 1 ? "" : "s") · \(bytes(loaded.byteCount))"
      if loaded.truncated {
        facts += " · \(loaded.loadedLines) loaded (over the \(store.maxLines)-line / \(bytes(store.maxBytes)) cap)"
      }
      rows.append(ANSI.dim(TerminalText.sanitize("  " + facts)))
      if !loaded.flaggedPatterns.isEmpty {
        rows.append(ANSI.yellow(TerminalText.sanitize(
          "  ⚠ MEMORY.md matched instruction-shaped patterns (\(loaded.flaggedPatterns.joined(separator: ", "))) — loaded as data, under a notice")))
      }
    } else {
      rows.append(ANSI.dim(TerminalText.sanitize("  \(index) — nothing saved yet")))
    }
    let agents = store.agentScopes().map(\.key)
    if !agents.isEmpty {
      rows.append(ANSI.dim(TerminalText.sanitize("  agents: " + agents.joined(separator: ", "))))
    }
    return rows
  }

  /// `arnes memory show`: the header line, then the index verbatim (sanitized), or the empty note.
  static func showLines(for store: MemoryStore, home: String) -> [String] {
    let index = abbreviate(store.indexURL.path, home: home)
    guard let text = store.indexText(), let loaded = store.load() else {
      return [ANSI.dim("\(index) — nothing saved yet")]
    }
    var lines = [ANSI.dim("\(index) · \(loaded.lineCount) line\(loaded.lineCount == 1 ? "" : "s") · \(bytes(loaded.byteCount))"
      + (loaded.truncated ? " · the model sees the first \(loaded.loadedLines)" : ""))]
    if !loaded.flaggedPatterns.isEmpty {
      lines.append(ANSI.yellow(
        "⚠ matched instruction-shaped patterns (\(loaded.flaggedPatterns.joined(separator: ", "))) — the model reads it under a data-not-instructions notice"))
    }
    lines.append(TerminalText.sanitize(text.hasSuffix("\n") ? String(text.dropLast()) : text))
    return lines
  }

  /// The REPL's `/memory`: off, nothing yet, or the path with counts and the index.
  static func replLines(for store: MemoryStore?, home: String) -> [String] {
    guard let store else {
      return [ANSI.dim("memory off (--no-memory, or memory.enabled: false in ~/.arnes/config.json)")]
    }
    let index = abbreviate(store.indexURL.path, home: home)
    guard let text = store.indexText(), let loaded = store.load() else {
      return [ANSI.dim("memory \(index) — nothing saved yet; the model writes it when it learns something worth keeping (a write there asks you first)")]
    }
    var lines = [ANSI.dim("memory \(index) · \(loaded.lineCount) line\(loaded.lineCount == 1 ? "" : "s") (\(loaded.loadedLines) loaded) · \(bytes(loaded.byteCount))")]
    if !loaded.flaggedPatterns.isEmpty {
      lines.append(ANSI.yellow("⚠ matched instruction-shaped patterns (\(loaded.flaggedPatterns.joined(separator: ", "))) — loaded as data, under a notice"))
    }
    lines.append(TerminalText.sanitize(text.hasSuffix("\n") ? String(text.dropLast()) : text))
    return lines
  }

  /// `1.2 KB` / `340 B`.
  static func bytes(_ count: Int) -> String {
    count >= 1024 ? String(format: "%.1f KB", Double(count) / 1024) : "\(count) B"
  }
}
