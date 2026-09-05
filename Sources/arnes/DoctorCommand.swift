import ArgumentParser
import ArnesKit
import Foundation

// MARK: - doctor

/// `arnes doctor` — the configuration checks a run performs silently, done out loud and all
/// at once: does the config parse, does the provider resolve a key, do the hook commands
/// exist, do the MCP servers, are the rules well-formed, is the sandbox enforceable, which
/// instruction files load. Offline by default (no manifest, no MCP handshake, no model
/// request); `--connect` adds the two that need the network. Exit 1 when any check is an
/// error, so a CI step can gate on it.
struct Doctor: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check the configuration a run would load: config, key, hooks, MCP, rules, sandbox, packs, trust, data files, tools, instruction files.",
    discussion: """
      One line per check: ✓ ok · ! warning · ✗ error, with a `fix:` line where there is one.
      Nothing is executed — no hook command runs, no model is asked, no MCP server is
      started unless --connect. Exit 0 when nothing is an error, 1 otherwise; warnings never
      change the exit code.

        arnes doctor
        arnes doctor --connect        # also fetch the model manifest and connect MCP servers
        arnes doctor --json           # {"checks": [...], "errors": N, "warnings": N}
      """)

  @Flag(help: "Also fetch the model manifest and connect the MCP servers (tool counts).")
  var connect = false

  @Flag(help: "Print one JSON object {checks: [{name, level, detail, fix}], errors, warnings} instead of text.")
  var json = false

  @OptionGroup var providerOptions: ProviderOptions

  func run() async throws {
    var environment = ProcessInfo.processInfo.environment
    if let provider = providerOptions.provider { environment["ARNES_PROVIDER"] = provider }
    let checks = await DoctorChecks.run(
      home: URL(fileURLWithPath: NSHomeDirectory()),
      cwd: ArnesRuntime.workingDirectory,
      environment: environment,
      connect: connect)
    if json {
      try JSONOut.print(DoctorReport(checks: checks))
    } else {
      for line in DoctorChecks.textLines(checks) { print(line) }
    }
    let code = DoctorChecks.exitCode(for: checks)
    if code != 0 { throw ExitCode(code) }
  }
}

/// The `--json` document.
struct DoctorReport: Encodable {
  let checks: [DoctorChecks.Check]
  let errors: Int
  let warnings: Int

  init(checks: [DoctorChecks.Check]) {
    self.checks = checks
    errors = checks.filter { $0.level == .error }.count
    warnings = checks.filter { $0.level == .warn }.count
  }
}

// MARK: - DoctorChecks

/// The checks, each a pure-ish function over an injected home directory, working directory
/// and environment — so a test runs them against a temp home without touching `~/.arnes`
/// (`NSHomeDirectory()` ignores `$HOME`). Nothing here prints; the command renders.
enum DoctorChecks {
  enum Level: String, Encodable, Comparable {
    case ok, warn, error

    static func < (lhs: Level, rhs: Level) -> Bool {
      let order: [Level] = [.ok, .warn, .error]
      return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
  }

  struct Check: Encodable, Equatable {
    let name: String
    let level: Level
    let detail: String
    let fix: String?

    init(_ name: String, _ level: Level, _ detail: String, fix: String? = nil) {
      self.name = name
      self.level = level
      self.detail = detail
      self.fix = fix
    }
  }

  /// Where a run reads each file for `home` + `environment`: the `ARNES_*_CONFIG` overrides
  /// win over the `~/.arnes` defaults, as they do for the run itself.
  struct Paths {
    let home: URL
    let cwd: URL
    let environment: [String: String]

    var arnesDir: URL { home.appendingPathComponent(".arnes") }
    var config: URL { override("ARNES_CONFIG") ?? arnesDir.appendingPathComponent("config.json") }
    var credentials: URL { arnesDir.appendingPathComponent("credentials") }
    var hooks: URL { override("ARNES_HOOKS_CONFIG") ?? arnesDir.appendingPathComponent("hooks.json") }
    var projectHooks: URL { HookConfig.projectURL(in: cwd) }
    var mcp: URL { override("ARNES_MCP_CONFIG") ?? arnesDir.appendingPathComponent("mcp.json") }
    var rules: URL { override("ARNES_RULES_CONFIG") ?? arnesDir.appendingPathComponent("rules.json") }
    var projectRules: URL { cwd.appendingPathComponent(".arnes/rules.json") }
    var trusted: URL { arnesDir.appendingPathComponent("trusted.json") }
    var packs: URL { arnesDir.appendingPathComponent("packs") }
    var runs: URL { arnesDir.appendingPathComponent("runs.jsonl") }
    var evals: URL { arnesDir.appendingPathComponent("evals.jsonl") }
    var dialects: URL { arnesDir.appendingPathComponent("dialects.jsonl") }
    var sessions: URL { arnesDir.appendingPathComponent("sessions") }
    var tmp: URL { arnesDir.appendingPathComponent("tmp") }
    /// The catalog's cached manifests, one `<provider>.json` each (`ManifestCache`).
    var models: URL { arnesDir.appendingPathComponent("models") }
    /// The REPL's file checkpoints, one `<session id>/` (an `index.json` beside `blobs/`) each
    /// (`FileCheckpointStore`; `ArnesRuntime.checkpointRoot`).
    var checkpoints: URL { arnesDir.appendingPathComponent("checkpoints") }

    /// The memory root a run here reads: `ARNES_MEMORY_DIR` > the decoded config's
    /// `memory.directory` > `~/.arnes/memory` (`MemoryStore.root`).
    func memory(config: ArnesConfig?) -> URL {
      MemoryStore.root(configured: config?.memory?.directory, environment: environment, home: home.path)
    }

    private func override(_ key: String) -> URL? {
      guard let raw = environment[key], !raw.isEmpty else { return nil }
      return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
    }
  }

  /// A pack override past this many bytes is flagged as bloat — it rides every request.
  static let packSizeWarningBytes = 16 * 1024

  static func run(home: URL, cwd: URL, environment: [String: String], connect: Bool) async -> [Check] {
    let paths = Paths(home: home, cwd: cwd, environment: environment)
    let loadedConfig = try? ArnesConfig.load(from: paths.config)
    var checks: [Check] = []
    checks += config(paths, loaded: loadedConfig)
    checks += permissions(paths)
    checks += hooks(paths, config: loadedConfig)
    checks += await mcp(paths, config: loadedConfig, connect: connect)
    checks += rules(paths)
    checks += sandbox(paths, config: loadedConfig)
    checks += packs(paths)
    checks += trust(paths)
    checks += data(paths, config: loadedConfig)
    checks += tools(paths, config: loadedConfig)
    checks += instructions(paths, config: loadedConfig)
    if connect {
      checks += await manifest(paths, config: loadedConfig)
    }
    return checks
  }

  /// 1 when any check is an error, else 0 — warnings never fail the command.
  static func exitCode(for checks: [Check]) -> Int32 {
    checks.contains { $0.level == .error } ? 1 : 0
  }

  /// One line per check plus a summary. Details may quote file contents (a hook command, a
  /// rule), so they are terminal-sanitized.
  static func textLines(_ checks: [Check]) -> [String] {
    var lines: [String] = []
    for check in checks {
      let mark: String
      switch check.level {
      case .ok: mark = ANSI.green("✓")
      case .warn: mark = ANSI.yellow("!")
      case .error: mark = ANSI.red("✗")
      }
      lines.append("\(mark) \(ANSI.bold(check.name)): \(TerminalText.sanitize(check.detail))")
      if let fix = check.fix {
        lines.append(ANSI.dim("    fix: \(TerminalText.sanitize(fix))"))
      }
    }
    let errors = checks.filter { $0.level == .error }.count
    let warnings = checks.filter { $0.level == .warn }.count
    let summary = "\(checks.count) checks · \(errors) error\(errors == 1 ? "" : "s") · \(warnings) warning\(warnings == 1 ? "" : "s")"
    lines.append("")
    lines.append(errors > 0 ? ANSI.red(summary) : (warnings > 0 ? ANSI.yellow(summary) : ANSI.dim(summary)))
    return lines
  }

  // MARK: config

  static func config(_ paths: Paths, loaded: ArnesConfig?) -> [Check] {
    var checks: [Check] = []
    let exists = FileManager.default.fileExists(atPath: paths.config.path)
    if exists {
      do {
        _ = try ArnesConfig.load(from: paths.config)
        checks.append(Check("config", .ok, "\(paths.config.path) parses"))
      } catch {
        return [Check("config", .error, "\(paths.config.path) is invalid: \(error)",
                      fix: "fix the JSON — every run reads this file before anything else")]
      }
    } else {
      checks.append(Check("config", .ok, "no \(paths.config.path) — built-in openrouter defaults"))
    }
    let name = ProviderResolver.activeName(config: loaded, environment: paths.environment)
    do {
      let resolved = try ProviderResolver.resolve(
        requested: nil, config: loaded, environment: paths.environment, credentialsURL: paths.credentials)
      var detail = "\(resolved.name) (\(resolved.kind.rawValue)) · key from \(resolved.apiKeySource)"
      if let model = resolved.defaultModel { detail += " · default model \(model)" } else { detail += " · no default model (pass -m)" }
      checks.append(Check("provider", .ok, detail))
    } catch let error as ProviderError {
      let fix: String
      switch error {
      case .missingAPIKey(_, let env, let credentialsPath):
        fix = "export \(env)=… or add a `\(env)=…` line to \(credentialsPath) (chmod 600)"
      case .unknownProvider(_, let available):
        fix = "set `provider` in \(paths.config.path) to one of: \(available.joined(separator: ", "))"
      default:
        fix = "check the provider entry in \(paths.config.path)"
      }
      checks.append(Check("provider", .error, error.description, fix: fix))
    } catch {
      checks.append(Check("provider", .error, "\(name): \(error)"))
    }
    // Aliases the resolver silently drops: an empty name or target.
    if let entry = (loaded ?? ArnesConfig()).allProviders[name], let aliases = entry.aliases {
      let malformed = aliases.filter { $0.key.trimmingCharacters(in: .whitespaces).isEmpty || $0.value.trimmingCharacters(in: .whitespaces).isEmpty }
      if !malformed.isEmpty {
        checks.append(Check("aliases", .warn,
                            "\(malformed.count) alias\(malformed.count == 1 ? "" : "es") with an empty name or target ignored",
                            fix: "remove or complete them in \(paths.config.path)"))
      }
    }
    return checks
  }

  // MARK: permissions

  static func permissions(_ paths: Paths) -> [Check] {
    var problems: [String] = []
    var fixes: [String] = []
    if let mode = fileMode(paths.arnesDir), mode & 0o077 != 0 {
      problems.append("\(paths.arnesDir.path) is mode \(String(mode, radix: 8)) (group/other can reach it)")
      fixes.append("chmod 700 \(paths.arnesDir.path)")
    }
    for file in [paths.credentials, paths.config] where SecureFiles.isReadableByOthers(file) {
      problems.append("\(file.path) is readable by other users")
      fixes.append("chmod 600 \(file.path)")
    }
    if SecureFiles.isWritableByOthers(paths.projectHooks) {
      problems.append("\(paths.projectHooks.path) is writable by other users — its hooks run commands")
      fixes.append("chmod 644 \(paths.projectHooks.path)")
    }
    guard !problems.isEmpty else {
      return [Check("permissions", .ok, "\(paths.arnesDir.path) and its token files are owner-only")]
    }
    return [Check("permissions", .warn, problems.joined(separator: "; "), fix: fixes.joined(separator: " && "))]
  }

  private static func fileMode(_ url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          let permissions = attributes[.posixPermissions] as? NSNumber
    else { return nil }
    return permissions.intValue
  }

  // MARK: hooks

  static func hooks(_ paths: Paths, config: ArnesConfig?) -> [Check] {
    var checks: [Check] = []
    do {
      _ = try HookConfig.load(from: paths.hooks)
    } catch {
      checks.append(Check("hooks", .error, "\(paths.hooks.path) is invalid: \(error) — every hook is disabled",
                          fix: "fix the JSON; `arnes hooks` shows what loads"))
      return checks
    }
    if FileManager.default.fileExists(atPath: paths.projectHooks.path) {
      do { _ = try HookConfig.load(from: paths.projectHooks) }
      catch {
        checks.append(Check("hooks", .error, "\(paths.projectHooks.path) is invalid: \(error)",
                            fix: "fix the JSON, then `arnes hooks trust`"))
      }
    }
    let store = ProjectTrustStore(url: paths.trusted)
    let loaded = (try? HookConfig.load(
      user: paths.hooks, project: paths.cwd, trust: store, directoryTrusted: store.isTrusted(paths.cwd)))
      ?? LoadedHooks()
    guard !loaded.hooks.isEmpty else {
      checks.append(Check("hooks", .ok, "no hooks configured"))
      return checks
    }
    let judge = activeBashJudge(config, environment: paths.environment)
    var okCount = 0
    for hook in loaded.hooks {
      let definition = hook.definition
      // A hook switched off is not a gate; nothing about it can silently fail.
      guard definition.isEnabled else { continue }
      let label = definition.id.map { "'\($0)'" } ?? "\(definition.event.rawValue) hook"
      let file = definition.source == .project ? paths.projectHooks.path : paths.hooks.path
      // Trust first: a project hook that isn't trusted (or changed since it was) does not run,
      // so nothing about its command can silently disable a gate — one warn row, no lookup.
      switch hook.trust {
      case .changed:
        checks.append(Check("hooks", .warn, "project \(label) changed since it was trusted — it does not run",
                            fix: "review it, then `arnes hooks trust`"))
        continue
      case .untrustedDirectory:
        checks.append(Check("hooks", .warn, "project \(label) is in a directory that isn't trusted — it does not run",
                            fix: "`arnes trust` here, then `arnes hooks trust`"))
        continue
      case .trusted:
        break
      }
      switch definition.type {
      case .command:
        if let program = hookProgram(definition.command) {
          if resolveExecutable(program, environment: paths.environment, cwd: paths.cwd, home: paths.home,
                               policy: config?.shellEnvironment) == nil {
            checks.append(Check("hooks", .error,
                                "\(label) runs `\(program)`, which is not on PATH — a mistyped hook path silently disables the gate",
                                fix: "install it, or fix the command in \(file)"))
            continue
          }
        }
      case .prompt:
        if definition.model == nil, judge == nil {
          checks.append(Check("hooks", .warn,
                              "\(label) is a prompt hook with no model and the provider has no bashJudge — it is skipped",
                              fix: "set \"model\" on the hook or `bashJudge` on the provider"))
          continue
        }
      }
      okCount += 1
    }
    let enabled = loaded.hooks.filter { $0.definition.isEnabled }.count
    if okCount > 0 {
      let project = loaded.hooks.filter { $0.definition.isEnabled && $0.definition.source == .project && $0.trust == .trusted }.count
      checks.append(Check("hooks", .ok,
                          "\(okCount) of \(enabled) enabled hook\(enabled == 1 ? "" : "s") resolve"
                            + (project > 0 ? " (\(project) project)" : "")))
    } else if enabled == 0 {
      checks.append(Check("hooks", .ok, "no enabled hooks (\(loaded.hooks.count) disabled)"))
    }
    // The loader's own notices (untrusted directory, changed hash, unreadable or loose file)
    // are each already a row above or in `permissions` — repeating them would double-count.
    return checks
  }

  /// The active provider's `bashJudge`, straight from the config — what a prompt hook
  /// without a `model` would run on.
  static func activeBashJudge(_ config: ArnesConfig?, environment: [String: String]) -> String? {
    let name = ProviderResolver.activeName(config: config, environment: environment)
    let judge = (config ?? ArnesConfig()).allProviders[name]?.bashJudge
    return judge.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
  }

  /// Shell builtins and keywords — never a file on PATH, so never a "not found". `sh`/`bash`
  /// are on every system; a hook written as `sh -c "…"` is checked no further.
  static let shellWordsToSkip: Set<String> = [
    "sh", "bash", "zsh", "dash", "if", "then", "else", "fi", "for", "while", "until", "do", "done",
    "case", "esac", "test", "[", "[[", "!", "{", "(", "cd", "echo", "printf", "exit", "return", "true",
    "false", ".", "source", "eval", "exec", "command", "builtin", "set", "unset", "export", "read",
    "shift", "trap", "wait", "type", "alias", "local", "declare", "typeset", ":", "time",
  ]

  /// The program a hook command starts with: the first word after leading `NAME=value`
  /// assignments and `env`, or nil when it is a shell builtin/keyword (nothing to look up),
  /// an expansion (`$X`), or the command is empty. A `~/…` program is kept: `sh -c` expands the
  /// tilde, so it is a path to check (against the doctor's home), not an expansion to skip.
  static func hookProgram(_ command: String) -> String? {
    var words = shellWords(command)
    while let first = words.first, first.contains("="), !first.hasPrefix("="),
          first.prefix(upTo: first.firstIndex(of: "=")!).allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" })
    {
      words.removeFirst()
    }
    while words.first == "env" {
      words.removeFirst()
      while let first = words.first, first.hasPrefix("-") || (first.contains("=") && !first.hasPrefix("=")) {
        words.removeFirst()
      }
    }
    guard let program = words.first, !program.isEmpty else { return nil }
    if shellWordsToSkip.contains(program) { return nil }
    if program.hasPrefix("$") || program.hasPrefix("`") { return nil }
    return program
  }

  /// A quote-aware split of the first simple command: stops at `;`, `|`, `&`, `>`/`<`
  /// redirections and newlines outside quotes. Enough to find the program; not a shell.
  static func shellWords(_ command: String) -> [String] {
    var words: [String] = []
    var current = ""
    var quote: Character?
    var escaped = false
    var hasWord = false
    for character in command {
      if escaped {
        current.append(character)
        escaped = false
        hasWord = true
        continue
      }
      if let open = quote {
        if character == open { quote = nil } else { current.append(character) }
        continue
      }
      switch character {
      case "\\":
        escaped = true
      case "'", "\"":
        quote = character
        hasWord = true
      case " ", "\t":
        if hasWord { words.append(current); current = ""; hasWord = false }
      case ";", "|", "&", "\n", ">", "<":
        if hasWord { words.append(current) }
        return words
      default:
        current.append(character)
        hasWord = true
      }
    }
    if hasWord { words.append(current) }
    return words
  }

  /// `command -v` without a shell: a program with a `/` is checked as a path (relative to
  /// `cwd`; `~/` expanded against `home`, the doctor's injected one, never the process's); a
  /// bare name is searched along the *scrubbed* PATH a hook or an MCP server inherits — under
  /// the configured `shellEnvironment` policy when given, so the doctor and the run search the
  /// same directories. Returns the executable's path, or nil.
  static func resolveExecutable(
    _ program: String, environment: [String: String], cwd: URL, home: URL? = nil,
    policy: ShellEnvironmentPolicy? = nil) -> String?
  {
    let manager = FileManager.default
    if program.contains("/") {
      let expanded: String
      if program.hasPrefix("~/"), let home {
        expanded = home.appendingPathComponent(String(program.dropFirst(2))).path
      } else {
        expanded = (program as NSString).expandingTildeInPath
      }
      let path = expanded.hasPrefix("/") ? expanded : cwd.appendingPathComponent(expanded).path
      return manager.isExecutableFile(atPath: path) ? path : nil
    }
    let scrubbed = SubprocessEnvironment(policy: policy ?? ShellEnvironmentPolicy()).resolve(inheriting: environment)
    let searchPath = scrubbed["PATH"] ?? environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    for directory in searchPath.split(separator: ":", omittingEmptySubsequences: true) {
      let candidate = "\(directory)/\(program)"
      var isDirectory: ObjCBool = false
      if manager.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
         manager.isExecutableFile(atPath: candidate)
      {
        return candidate
      }
    }
    return nil
  }

  // MARK: mcp

  static func mcp(_ paths: Paths, config arnesConfig: ArnesConfig?, connect: Bool) async -> [Check] {
    let config: MCPConfig?
    do {
      config = try MCPConfig.load(from: paths.mcp)
    } catch {
      return [Check("mcp", .error, "\(paths.mcp.path) is invalid: \(error) — no MCP server connects",
                    fix: "fix the JSON; `arnes mcp` lists what connects")]
        + projectMCP(paths, config: arnesConfig, userNames: [])
    }
    let project = projectMCP(paths, config: arnesConfig, userNames: Set(config?.mcpServers.keys.map { $0 } ?? []))
    guard let config, !config.mcpServers.isEmpty else {
      return project.isEmpty ? [Check("mcp", .ok, "no MCP servers configured")] : project
    }
    var checks: [Check] = []
    var resolvable = 0
    for (name, entry) in config.mcpServers.sorted(by: { $0.key < $1.key }) where entry.isEnabled {
      if let problem = mcpEntryProblem(name: name, entry: entry, file: paths.mcp, paths: paths, config: arnesConfig) {
        checks.append(Check("mcp", entry.isRequired || problem.structural ? .error : .warn,
                            "server \(name): \(problem.detail)"
                              + (entry.isRequired && problem.kind == .commandNotFound ? " (required — the run would stop)" : ""),
                            fix: problem.fix))
        continue
      }
      resolvable += 1
    }
    let enabled = config.mcpServers.values.filter(\.isEnabled).count
    if resolvable > 0 {
      checks.append(Check("mcp", .ok, "\(resolvable) of \(enabled) enabled server\(enabled == 1 ? "" : "s") resolve"
                          + (connect ? "" : " (not connected — pass --connect for tool counts)")))
    }
    if connect {
      let provider = MCPToolProvider()
      let (_, statuses) = await provider.connect(config: config)
      await provider.shutdown()
      for status in statuses where !status.disabled {
        if let error = status.error {
          checks.append(Check("mcp", status.required ? .error : .warn, "server \(status.server) failed to connect: \(error)"))
        } else {
          checks.append(Check("mcp", .ok, "server \(status.server) connected · \(status.toolCount) tools"
                              + (status.promptCount > 0 ? " · \(status.promptCount) prompts" : "")))
        }
      }
    }
    return checks + project
  }

  /// What is wrong with one entry, offline: a stdio entry without a command or whose command
  /// is not on the scrubbed PATH, an http entry without a url or whose url the policy refuses.
  /// `structural` = the entry can never connect whatever is installed (always an error for a
  /// user entry). The row names a host, never a URL path (a path may carry a token).
  struct MCPEntryProblem {
    enum Kind { case missingCommand, commandNotFound, missingURL, urlRefused }
    let kind: Kind
    let detail: String
    let fix: String
    /// The entry can never connect whatever is installed — always an error for a user entry.
    var structural: Bool { kind == .missingCommand || kind == .missingURL }
  }

  static func mcpEntryProblem(
    name: String, entry: MCPServerConfig, file: URL, paths: Paths, config arnesConfig: ArnesConfig?)
    -> MCPEntryProblem?
  {
    switch entry.transport {
    case .stdio:
      guard let command = entry.command, !command.isEmpty else {
        return MCPEntryProblem(kind: .missingCommand, detail: "stdio entry without a command", fix: "add \"command\" in \(file.path)")
      }
      if resolveExecutable(command, environment: paths.environment, cwd: paths.cwd, home: paths.home,
                           policy: arnesConfig?.shellEnvironment) == nil {
        return MCPEntryProblem(kind: .commandNotFound, detail: "`\(command)` is not on PATH",
                               fix: "install it, or fix \"command\" in \(file.path)")
      }
    case .http:
      guard let raw = entry.url, !raw.isEmpty else {
        return MCPEntryProblem(kind: .missingURL, detail: "http entry without a url", fix: "add \"url\" in \(file.path)")
      }
      do {
        _ = try URLPolicy(insecure: entry.insecure ?? false).validate(string: raw)
      } catch {
        // The policy's message quotes the URL; the row names the host only (a path may carry a token).
        let host = URL(string: raw)?.host.map { "\($0)" } ?? "its URL"
        return MCPEntryProblem(
          kind: .urlRefused,
          detail: "\(host) is refused by the URL policy (https required; http only to loopback or with `insecure: true`)",
          fix: "use https, or `insecure: true` for a trusted plain-http host")
      }
    }
    return nil
  }

  /// The repository's `.mcp.json` (X9): parsed and checked like the user file, every finding a
  /// warning — a project entry never stops a run (it cannot be `required`, and it loads only in
  /// a trusted directory, as untrusted). Says whether this directory is trusted, and which
  /// entries the user's file shadows. Nothing when there is no such file.
  static func projectMCP(_ paths: Paths, config arnesConfig: ArnesConfig?, userNames: Set<String>) -> [Check] {
    let options = ProjectInstructions.Options(config: arnesConfig?.instructions)
    let url = MCPConfig.projectFileURL(for: paths.cwd, options: options)
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let trusted = ProjectTrustStore(url: paths.trusted, home: paths.home).isTrusted(paths.cwd)
    let posture = trusted
      ? "directory trusted — they load as untrusted (every result taints)"
      : "directory not trusted — not loaded"
    let config: MCPConfig?
    do {
      config = try MCPConfig.load(from: url)
    } catch {
      return [Check("mcp", .warn, "project \(url.path) is invalid: \(error) — its servers are not loaded",
                    fix: "fix the JSON, or remove the file")]
    }
    guard let config, !config.mcpServers.isEmpty else {
      return [Check("mcp", .ok, "project \(url.path) names no servers")]
    }
    let count = config.mcpServers.count
    var checks = [Check("mcp", trusted ? .ok : .warn,
                        "project \(url.path): \(count) server\(count == 1 ? "" : "s") — \(posture)",
                        fix: trusted ? nil : "`arnes trust` in the repository to load them (as untrusted)")]
    for (name, entry) in config.mcpServers.sorted(by: { $0.key < $1.key }) where entry.isEnabled {
      if let problem = mcpEntryProblem(name: name, entry: entry, file: url, paths: paths, config: arnesConfig) {
        checks.append(Check("mcp", .warn, "project server \(name): \(problem.detail)", fix: problem.fix))
      }
      if entry.isRequired {
        checks.append(Check("mcp", .warn, "project server \(name) says required: true — ignored (a project entry cannot make a run fail)",
                            fix: "drop \"required\" from \(url.path), or add the server in ~/.arnes/mcp.json"))
      }
      if userNames.contains(name) {
        checks.append(Check("mcp", .warn, "project server \(name) is shadowed by the entry of the same name in \(paths.mcp.path) — the user's wins",
                            fix: "rename one of them"))
      }
    }
    if SecureFiles.isWritableByOthers(url) {
      checks.append(Check("mcp", .warn, "project \(url.path) is writable by other users — it names the MCP servers arnes starts",
                          fix: "chmod 644 \(url.path)"))
    }
    return checks
  }

  // MARK: rules

  /// Tool names a rule may name bare: the core toolset plus the harness's own two, and any
  /// `mcp__…` id (a server's tools are not known offline).
  static var knownToolNames: Set<String> {
    Set(HarnessAssembly.coreTools().map(\.name)).union(["skill", "task"])
  }

  static func rules(_ paths: Paths) -> [Check] {
    var checks: [Check] = []
    for (label, url) in [("rules", paths.rules), ("project rules", paths.projectRules)] {
      guard FileManager.default.fileExists(atPath: url.path) else { continue }
      let rules: PermissionRules?
      do {
        rules = try PermissionRules.load(from: url)
      } catch {
        checks.append(Check("rules", .error, "\(url.path) is invalid: \(error) — every rule in it is disabled",
                            fix: "fix the JSON; `deny`, `ask`, `allow` are arrays of Tool / Bash(prefix:*) / Read(glob) strings"))
        continue
      }
      guard let rules else { continue }
      var unparseable: [String] = []
      var unknown: [String] = []
      for raw in rules.deny + rules.ask + rules.allow {
        guard let rule = PermissionRule(raw) else {
          unparseable.append(raw)
          continue
        }
        if case .tool(let name) = rule.matcher, !name.hasPrefix("mcp__"), !knownToolNames.contains(name) {
          unknown.append(name)
        }
      }
      let total = rules.deny.count + rules.ask.count + rules.allow.count
      if !unparseable.isEmpty {
        checks.append(Check("rules", .warn, "\(label): \(unparseable.count) rule\(unparseable.count == 1 ? "" : "s") don't parse and never match: \(unparseable.joined(separator: ", "))",
                            fix: "use a bare tool name, Bash(prefix:*), Read/Edit/Write/Grep/Glob(glob) or mcp__server__*"))
      }
      if !unknown.isEmpty {
        checks.append(Check("rules", .warn, "\(label): rules name tools this build doesn't have: \(unknown.joined(separator: ", "))",
                            fix: "tools are read_file, write_file, edit_file, bash, grep, glob, update_plan, think, skill, task, mcp__…"))
      }
      if unparseable.isEmpty, unknown.isEmpty {
        checks.append(Check("rules", .ok, "\(label): \(total) rule\(total == 1 ? "" : "s") parse (\(url.path))"))
      }
    }
    if checks.isEmpty {
      checks.append(Check("rules", .ok, "no rules file — every gated call asks (or is denied headless)"))
    }
    return checks
  }

  // MARK: sandbox

  static func sandbox(_ paths: Paths, config: ArnesConfig?) -> [Check] {
    let name = ProviderResolver.activeName(config: config, environment: paths.environment)
    let block = (config ?? ArnesConfig()).allProviders[name]?.sandbox
    let supported = ShellSandbox.isSupported
    guard let block else {
      return [Check("sandbox", .ok, supported
        ? "not configured — unattended runs (do --yes, eval, --panel) are confined by default; interactive sessions are not"
        : "not configured — this platform can't enforce one, so unattended runs are NOT confined")]
    }
    guard block.enabled else {
      return [Check("sandbox", .ok, "disabled explicitly (sandbox.enabled: false) — no run is confined")]
    }
    if supported {
      return [Check("sandbox", .ok, "enabled" + (block.network == false ? ", network off" : "") + " · enforceable here")]
    }
    if block.failIfUnavailable == false {
      return [Check("sandbox", .warn, "enabled but unsupported on this platform — runs continue UNCONFINED (failIfUnavailable: false)",
                    fix: "run on macOS (sandbox-exec), or drop failIfUnavailable so runs fail closed")]
    }
    return [Check("sandbox", .error, "enabled but unsupported on this platform — every bash command fails closed",
                  fix: "set sandbox.enabled: false (or failIfUnavailable: false) in \(paths.config.path), or run on macOS")]
  }

  // MARK: packs

  static func packs(_ paths: Paths) -> [Check] {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: paths.packs.path) else {
      return [Check("packs", .ok, "no prompt-pack overrides (\(paths.packs.path))")]
    }
    let files = names.filter { $0.hasSuffix(".md") }.sorted()
    guard !files.isEmpty else {
      return [Check("packs", .ok, "no prompt-pack overrides (\(paths.packs.path))")]
    }
    var checks: [Check] = []
    for file in files {
      let url = paths.packs.appendingPathComponent(file)
      let size = (try? manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
      let family = String(file.dropLast(3))
      if size > packSizeWarningBytes {
        checks.append(Check("packs", .warn, "\(family): \(size) bytes — rides every request of that family",
                            fix: "trim \(url.path) below \(packSizeWarningBytes / 1024) KB; `arnes debug prompt` shows the section sizes"))
      } else {
        checks.append(Check("packs", .ok, "\(family): \(size) bytes"))
      }
    }
    return checks
  }

  // MARK: trust

  static func trust(_ paths: Paths) -> [Check] {
    guard let data = try? Data(contentsOf: paths.trusted) else {
      return [Check("trust", .ok, "no trusted directories yet (\(paths.trusted.path))")]
    }
    guard (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil else {
      return [Check("trust", .error, "\(paths.trusted.path) is not a JSON object — no directory is trusted",
                    fix: "fix or delete the file, then `arnes trust` the directories again")]
    }
    let directories = ProjectTrustStore(url: paths.trusted).all()
    let missing = directories.filter { !FileManager.default.fileExists(atPath: $0) }
    if !missing.isEmpty {
      return [Check("trust", .warn, "\(missing.count) trusted director\(missing.count == 1 ? "y" : "ies") no longer exist: \(missing.joined(separator: ", "))",
                    fix: "`arnes trust --forget <dir>` for each")]
    }
    return [Check("trust", .ok, "\(directories.count) trusted director\(directories.count == 1 ? "y" : "ies")")]
  }

  // MARK: data

  static func data(_ paths: Paths, config: ArnesConfig? = nil) -> [Check] {
    var parts: [String] = []
    var malformed: [String] = []
    for (label, url) in [("runs.jsonl", paths.runs), ("evals.jsonl", paths.evals), ("dialects.jsonl", paths.dialects)] {
      guard let data = try? Data(contentsOf: url) else { continue }
      let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { !$0.isEmpty }
      let bad = lines.filter { (try? JSONSerialization.jsonObject(with: Data($0.utf8))) == nil }.count
      parts.append("\(label) \(lines.count) rows, \(data.count) bytes" + (bad > 0 ? " (\(bad) malformed)" : ""))
      if bad > 0 { malformed.append("\(label): \(bad) row\(bad == 1 ? "" : "s") don't parse") }
    }
    let manager = FileManager.default
    if let names = try? manager.contentsOfDirectory(atPath: paths.sessions.path) {
      let transcripts = names.filter { $0.hasSuffix(".jsonl") }
      let bytes = transcripts.reduce(0) { total, name in
        total + ((try? manager.attributesOfItem(atPath: paths.sessions.appendingPathComponent(name).path)[.size] as? NSNumber)?.intValue ?? 0)
      }
      parts.append("sessions/ \(transcripts.count) transcripts, \(bytes) bytes")
    }
    if let names = try? manager.contentsOfDirectory(atPath: paths.tmp.path), !names.isEmpty {
      parts.append("tmp/ \(names.count) spill director\(names.count == 1 ? "y" : "ies") (a running session owns one; sessions delete/prune sweeps the rest)")
    }
    if let names = try? manager.contentsOfDirectory(atPath: paths.models.path) {
      let manifests = names.filter { $0.hasSuffix(".json") }.sorted()
      if !manifests.isEmpty {
        // The file name is the cache key, so a listed name reads back through the same cache.
        let cache = ManifestCache(directory: paths.models)
        let described = manifests.map { name -> String in
          guard let entry = cache.load(provider: String(name.dropLast(5))) else {
            return "\(name) unreadable (arnes models --refresh rewrites it)"
          }
          return "\(name) \(entry.profiles.count) models, fetched \(ManifestCache.describeAgeAgo(cache.age(of: entry)))"
        }
        parts.append("models/ " + described.joined(separator: ", "))
      }
    }
    // The REPL's file checkpoints: a session is a subdirectory holding an `index.json`, its blobs
    // the files under `blobs/`. Absent or empty, the part is left out.
    if let names = try? manager.contentsOfDirectory(atPath: paths.checkpoints.path) {
      var sessions = 0, blobs = 0, bytes = 0
      for name in names.sorted() {
        let directory = paths.checkpoints.appendingPathComponent(name)
        guard let indexBytes = fileSize(directory.appendingPathComponent(FileCheckpointStore.indexFileName)) else { continue }
        sessions += 1
        bytes += indexBytes
        let blobDirectory = directory.appendingPathComponent(FileCheckpointStore.blobsDirectoryName)
        for blob in (try? manager.contentsOfDirectory(atPath: blobDirectory.path)) ?? [] {
          guard let blobBytes = fileSize(blobDirectory.appendingPathComponent(blob)) else { continue }
          blobs += 1
          bytes += blobBytes
        }
      }
      if sessions > 0 {
        parts.append("checkpoints/ \(sessions) session\(sessions == 1 ? "" : "s"), \(blobs) blob\(blobs == 1 ? "" : "s"), \(bytes) bytes")
      }
    }
    // The model's memory: one project scope per directory under the root, each with its agent
    // scopes; the bytes are the `MEMORY.md` indexes. The root follows `ARNES_MEMORY_DIR` and
    // `memory.directory`, so the part names it when it isn't `~/.arnes/memory`. A scanner warning
    // on an index is `arnes memory`'s to give, not the doctor's.
    let memoryRoot = paths.memory(config: config)
    let projects = MemoryStore.projects(under: memoryRoot)
    if !projects.isEmpty {
      var scopes = 0, bytes = 0
      for project in projects {
        bytes += fileSize(project.indexURL) ?? 0
        let agents = project.agentScopes()
        scopes += agents.count
        bytes += agents.reduce(0) { $0 + (fileSize($1.indexURL) ?? 0) }
      }
      let defaultRoot = paths.arnesDir.appendingPathComponent("memory").standardizedFileURL.path
      let location = memoryRoot.standardizedFileURL.path == defaultRoot ? "" : " at \(memoryRoot.path)"
      parts.append(
        "memory/ \(projects.count) project\(projects.count == 1 ? "" : "s"), \(scopes) agent scope\(scopes == 1 ? "" : "s"), \(bytes) bytes\(location)")
    }
    guard !parts.isEmpty else {
      return [Check("data", .ok, "no runs, evals, verdicts or sessions recorded yet")]
    }
    if !malformed.isEmpty {
      return [Check("data", .warn, parts.joined(separator: " · "),
                    fix: malformed.joined(separator: "; ") + " — those rows are skipped by the scoreboards; remove them")]
    }
    return [Check("data", .ok, parts.joined(separator: " · "))]
  }

  /// The size of a regular file, nil when there is none at the path.
  private static func fileSize(_ url: URL) -> Int? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attributes[.type] as? FileAttributeType) == .typeRegular
    else { return nil }
    return (attributes[.size] as? NSNumber)?.intValue
  }

  // MARK: tools

  static func tools(_ paths: Paths, config: ArnesConfig?) -> [Check] {
    var checks: [Check] = []
    if let git = resolveExecutable("git", environment: paths.environment, cwd: paths.cwd) {
      checks.append(Check("tools", .ok, "git at \(git)"))
    } else {
      checks.append(Check("tools", .warn, "git is not on PATH — the # Environment block loses its branch/status/commit lines",
                          fix: "install git, or ignore if this machine never runs inside a repository"))
    }
    #if os(macOS)
    let name = ProviderResolver.activeName(config: config, environment: paths.environment)
    if let block = (config ?? ArnesConfig()).allProviders[name]?.sandbox, block.enabled {
      checks.append(ShellSandbox.isSupported
        ? Check("tools", .ok, "sandbox-exec present — the configured sandbox is enforceable")
        : Check("tools", .error, "/usr/bin/sandbox-exec is missing — the configured sandbox can't be enforced",
                fix: "restore sandbox-exec (part of macOS) or disable the sandbox"))
    }
    #endif
    return checks
  }

  // MARK: instructions

  static func instructions(_ paths: Paths, config: ArnesConfig?) -> [Check] {
    let options = ProjectInstructions.Options(config: config?.instructions)
    guard let discovered = ProjectInstructions.discovered(
      workdir: paths.cwd, home: paths.home, includeProject: true, options: options)
    else {
      return [Check("instructions", .ok, "no AGENTS.md/CLAUDE.md here or in \(paths.arnesDir.path)")]
    }
    let trusted = ProjectTrustStore(url: paths.trusted).isTrusted(paths.cwd)
    let projectSources = discovered.sources.filter { !$0.path.path.hasPrefix(paths.arnesDir.path) }
    var listed = discovered.sources.map { source -> String in
      let imports = source.imports.isEmpty ? "" : " (+\(source.imports.count) import\(source.imports.count == 1 ? "" : "s"))"
      return "\(source.path.path) \(source.byteCount) bytes\(imports)"
    }
    let total = discovered.sources.reduce(0) { $0 + $1.byteCount }
    var level: Level = .ok
    var fix: String?
    if total > options.maxBytes {
      level = .warn
      listed.append("\(total) bytes over the \(options.maxBytes)-byte cap — the tail is truncated in the prompt")
      fix = "shorten the files or raise instructions.maxBytes in \(paths.config.path)"
    }
    let skipped = discovered.text.components(separatedBy: "[import skipped:").count - 1
    if skipped > 0 {
      level = .warn
      listed.append("\(skipped) @path import\(skipped == 1 ? "" : "s") skipped (cycle, depth, outside the root, or a credential path)")
      fix = (fix.map { $0 + "; " } ?? "") + "check the @path lines — the prompt carries an [import skipped: …] note for each"
    }
    if !projectSources.isEmpty, !trusted {
      listed.append("the project's own files load only once this directory is trusted (`arnes trust`, or --trust-project)")
    }
    return [Check("instructions", level, listed.joined(separator: " · "), fix: fix)]
  }

  // MARK: manifest (--connect)

  static func manifest(_ paths: Paths, config: ArnesConfig?) async -> [Check] {
    let resolved: ResolvedProvider
    do {
      resolved = try ProviderResolver.resolve(
        requested: nil, config: config, environment: paths.environment, credentialsURL: paths.credentials)
    } catch {
      return []  // the `provider` check already said why
    }
    let runtime = ArnesRuntime(provider: resolved)
    // Host only, on both rows — a gateway path routinely carries a token, which is why the
    // JSON rows say `base_host` and not the URL (the REPL banner's wording names the path; the
    // doctor reads the catalog's failure directly instead).
    var host = resolved.baseURL.host ?? "the provider"
    if let port = resolved.baseURL.port { host += ":\(port)" }
    _ = try? await runtime.catalog.all()
    if let failure = await runtime.catalog.manifestFailure {
      return [Check("manifest", .error, "model manifest unavailable from \(host): \(failure.prefix(160)) — capabilities assumed (tools on, no pricing)",
                    fix: "check baseURL and the key with `arnes providers`; runs continue with assumed capabilities")]
    }
    let count = (try? await runtime.catalog.all().count) ?? 0
    return [Check("manifest", .ok, "\(count) models from \(host)")]
  }
}
