import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - MCPOptions

/// The two flags that decide *which* MCP config a run uses, shared by `do`,
/// `interactive`, and `mcp` so the listing and the run always agree.
struct MCPOptions: ParsableArguments {
  @Option(
    name: .customLong("mcp-config"),
    help: ArgumentHelp(
      "MCP config to use: a path, or inline JSON. Overrides ARNES_MCP_CONFIG; merges over ~/.arnes/mcp.json unless --strict-mcp-config.",
      valueName: "path|json"))
  var mcpConfig: String?

  @Flag(
    name: .customLong("strict-mcp-config"),
    help: "Ignore ~/.arnes/mcp.json and ARNES_MCP_CONFIG — connect only what --mcp-config names.")
  var strictMcpConfig = false
}

// MARK: - MCPSetup

/// Shared CLI-side MCP bootstrap: resolves the config, connects the servers, and prints
/// one status line per server (`quiet` skips the ok lines for callers that summarize
/// servers themselves; warnings always print). Callers own the returned provider and must
/// `shutdown()` it so the server processes die with the CLI.
enum MCPSetup {
  /// What a bootstrap produced. `tools` and `provider` keep their old names so callers
  /// read the same; `requiredFailure` is the one thing a headless run must act on.
  struct Connected {
    let provider: MCPToolProvider
    let tools: [any AgentTool]
    let statuses: [MCPToolProvider.ServerStatus]
    /// The config files that contributed entries, lowest precedence first (`/mcp` names them).
    var configPaths: [String] = []

    /// The first `required: true` server that didn't come up, phrased for a human.
    var requiredFailure: String? {
      statuses
        .first { $0.required && $0.error != nil }
        .map { "mcp server \($0.server) is required but failed: \($0.error ?? "unknown error")" }
    }
  }

  /// - Parameters:
  ///   - options: `--mcp-config` / `--strict-mcp-config`.
  ///   - redacting: environment variables withheld from server processes — the provider
  ///     tokens (`ArnesRuntime.redactedEnvironmentKeys`).
  ///   - output: where the status lines go — stdout by default; a headless JSON run routes
  ///     them to stderr so its stdout stays one object per line.
  ///   - pins: where each server's tool definitions are pinned at first sight and checked on
  ///     every later connect (`~/.arnes/trusted.json` by default) — a tool whose description or
  ///     schema changed since is withheld with a notice until `arnes mcp --approve <server>`.
  ///   - project: the repository's `.mcp.json` (X9), passed **only when the directory is trusted**;
  ///     its entries run untrusted, never `required`, and never override the user's — the notices
  ///     for a shadowed or de-required entry print here. nil = the pre-X9 resolution.
  /// - Throws: when `--mcp-config` names something unreadable. A broken *ambient* config
  ///   only warns (MCP is opt-in by presence), but a config the user named by hand has
  ///   to fail loudly rather than silently disable every server.
  static func connect(
    enabled: Bool,
    options: MCPOptions = MCPOptions(),
    spinner: Spinner? = nil,
    quiet: Bool = false,
    redacting: Set<String> = ProcessMCPTransport.defaultRedactedEnvironmentKeys,
    pins: (any MCPToolPins)? = ProjectTrustStore(),
    project: URL? = nil,
    output: (String) -> Void = { print($0) })
    async throws -> Connected
  {
    let provider = MCPToolProvider(redactingEnvironment: redacting)
    guard enabled else { return Connected(provider: provider, tools: [], statuses: []) }
    let config: MCPConfig
    let resolution: MCPConfig.Resolution
    do {
      resolution = try MCPConfig.resolved(
        explicit: options.mcpConfig, strict: options.strictMcpConfig, project: project)
      guard let loaded = resolution.config, !loaded.mcpServers.isEmpty else {
        for notice in resolution.notices { output(ANSI.yellow(TerminalText.sanitize("⚠ \(notice)"))) }
        return Connected(provider: provider, tools: [], statuses: [], configPaths: resolution.sources)
      }
      config = loaded
    } catch {
      guard options.mcpConfig == nil else { throw error }
      output(ANSI.yellow(TerminalText.sanitize(
        "⚠ \(MCPConfig.defaultURL.path) is invalid: \(error) — continuing without MCP")))
      return Connected(provider: provider, tools: [], statuses: [])
    }
    // A repository file that names commands: whoever can write it chooses what runs.
    if let project, !options.strictMcpConfig, SecureFiles.isWritableByOthers(project) {
      output(ANSI.yellow(TerminalText.sanitize(
        "⚠ \(project.path) is writable by other users — chmod 644 it; it names the MCP servers arnes starts")))
    }
    for notice in resolution.notices { output(ANSI.yellow(TerminalText.sanitize("⚠ \(notice)"))) }
    spinner?.start("connecting mcp servers")
    let (tools, statuses) = await provider.connect(config: config, pins: pins)
    spinner?.stop()
    for status in statuses where !status.disabled {
      if let error = status.error {
        let text = TerminalText.sanitize("mcp \(status.server): \(error)")
        output(status.required ? ANSI.red("✘ \(text) (required)") : ANSI.yellow("⚠ \(text)"))
      } else if !quiet {
        output(ANSI.dim(TerminalText.sanitize("mcp \(status.server) · \(status.toolCount) tools")))
      }
      // Withheld tools always print: a run must not look like it has a tool it silently dropped.
      if let notice = status.withheldNotice {
        output(ANSI.yellow(TerminalText.sanitize("⚠ \(notice)")))
      }
    }
    return Connected(provider: provider, tools: tools, statuses: statuses, configPaths: resolution.sources)
  }
}

// MARK: - mcp

struct Mcp: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Connect the configured MCP servers and list the tools and prompts they expose; add/remove/get/list edit and read the config offline.",
    discussion: """
      `arnes mcp` alone connects every configured server and lists what it exposes (the status
      view). The verbs edit or read the config files without connecting:

        arnes mcp add <name> [--scope user|project] [--env K=V]… -- <command> [args…]
        arnes mcp add <name> --url https://… [--header "Name: ${VAR}"]…
        arnes mcp add-json <name> '<json object>'
        arnes mcp remove <name>            arnes mcp get <name> [--json]        arnes mcp list [--json]

      Scopes: `user` is ~/.arnes/mcp.json (or ARNES_MCP_CONFIG); `project` is the repository's
      .mcp.json, which arnes loads only in a trusted directory (`arnes trust`) and always as
      `trust: untrusted` — every result taints the session and no project entry can be `required`
      or override a user entry of the same name. Secrets go in as `${NAME}` templates, never as
      literals (`--allow-literal` overrides, 0600, this machine only). A connected session keeps
      its toolset; a config change shows up in the next session.
      """,
    subcommands: [McpStatus.self, McpAdd.self, McpAddJSON.self, McpRemove.self, McpGet.self, McpList.self],
    defaultSubcommand: McpStatus.self)
}

// MARK: - mcp status

/// The connecting view — `arnes mcp` alone, through `defaultSubcommand`. It is a subcommand of its
/// own rather than the parent's `run()` because swift-argument-parser lets a parent consume its
/// options from anywhere in the argument list: a `--json` declared here on `Mcp` swallowed the
/// `--json` of `arnes mcp get <name> --json` and `arnes mcp list --json`, and the verbs never
/// saw it. With the parent declaring nothing, each subcommand owns its flags; `arnes mcp
/// [--json] [--approve <server>] [--mcp-config …] [--strict-mcp-config]` parses exactly as before.
struct McpStatus: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "status",
    abstract: "Connect every configured MCP server and list the tools and prompts it exposes — what `arnes mcp` alone runs.")

  @OptionGroup var mcpOptions: MCPOptions

  @Flag(help: "Print one JSON array of {name, transport, host_or_command, required, enabled, connected, tools, prompts, error, withheld_tools} rows instead of text (still connects).")
  var json = false

  @Option(
    name: .customLong("approve"),
    help: ArgumentHelp(
      "Re-pin every tool of this server after connecting: tool definitions are pinned by hash at first sight, and one whose description or schema changed since is withheld until approved here. Read the new descriptions first.",
      valueName: "server"))
  var approve: String?

  func run() async throws {
    // The project's .mcp.json joins the status view exactly when a run here would load it: the
    // directory is trusted (the REPL and `do` pass it under the same rule).
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let project = ProjectTrustStore().isTrusted(cwd)
      ? MCPConfig.projectURL(for: cwd, options: McpFiles.instructionOptions())
      : nil
    let resolution = try MCPConfig.resolved(
      explicit: mcpOptions.mcpConfig, strict: mcpOptions.strictMcpConfig, project: project)
    for notice in resolution.notices { JSONOut.stderr(ANSI.yellow(TerminalText.sanitize("⚠ \(notice)"))) }
    guard let config = resolution.config, !config.mcpServers.isEmpty else {
      if json {
        try JSONOut.print([MCPServerRow]())
        return
      }
      print("""
        no MCP servers configured — create \(MCPConfig.defaultURL.path), e.g.:

        {
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
            },
            "docs": {
              "type": "http",
              "url": "https://mcp.example.com/mcp",
              "headers": {"Authorization": "Bearer ${DOCS_TOKEN}"},
              "required": true
            }
          }
        }
        """)
      return
    }
    if let approve, config.mcpServers[approve] == nil {
      throw ValidationError(
        "--approve \(approve): no such server in the config (\(config.mcpServers.keys.sorted().joined(separator: ", ")))")
    }
    let provider = MCPToolProvider()
    let store = ProjectTrustStore()
    let (tools, statuses) = await provider.connect(
      config: config, pins: store, approving: approve.map { [$0] } ?? [])
    let prompts = await provider.prompts
    if json {
      let rows = statuses.map { status in
        MCPServerRow(
          status,
          tools: tools.compactMap { $0 as? MCPTool }.filter { $0.server == status.server }.map(\.name),
          prompts: prompts.filter { $0.server == status.server }.map(\.slashName),
          scope: resolution.projectServers.contains(status.server) ? "project" : "user")
      }
      await provider.shutdown()
      try JSONOut.print(rows)
      return
    }
    for status in statuses {
      // The transport line never carries a header value or a URL path — both routinely
      // hold a bearer token, and this output gets pasted into issues.
      let detail = ANSI.dim(TerminalText.sanitize(" · \(status.transport)"))
        + (resolution.projectServers.contains(status.server) ? ANSI.dim(" · project") : "")
      let flags = status.required ? ANSI.yellow(" [required]") : ""
      if status.disabled {
        print(ANSI.dim(TerminalText.sanitize(status.server)) + detail + ANSI.dim(" · disabled") + flags)
        continue
      }
      if let error = status.error {
        print(ANSI.red(TerminalText.sanitize("✘ \(status.server)")) + detail + flags
          + ANSI.red(TerminalText.sanitize(" — \(error)")))
        continue
      }
      let counts = " · \(status.toolCount) tools"
        + (status.promptCount > 0 ? " · \(status.promptCount) prompts" : "")
        + (status.withheldTools.isEmpty ? "" : " · \(status.withheldTools.count) withheld")
      let trust = config.mcpServers[status.server]?.isUntrusted == true ? ANSI.yellow(" [untrusted]") : ""
      print(ANSI.bold(TerminalText.sanitize(status.server)) + detail + ANSI.dim(counts) + flags + trust)
      for tool in tools.compactMap({ $0 as? MCPTool }) where tool.server == status.server {
        let gate = tool.permission == .readOnly
          ? ANSI.dim("read-only")
          : (tool.permission == .sensitive ? ANSI.red("sensitive") : ANSI.yellow("mutating"))
        let brief = tool.description.split(separator: "\n").first.map(String.init) ?? ""
        print(TerminalText.sanitize("  \(tool.name)  [\(gate)]  \(ANSI.dim(String(brief.prefix(100))))"))
      }
      // A withheld tool is shown where it would have been listed, with the description the user
      // is asked to read — the model never saw it.
      for name in status.withheldTools {
        let brief = status.withheldDescriptions[name] ?? ""
        print(ANSI.yellow(TerminalText.sanitize(
          "  \(name)  [withheld (changed since first seen — arnes mcp --approve \(status.server))]  "))
          + ANSI.dim(TerminalText.sanitize(brief)))
      }
      if approve == status.server {
        print(status.repinnedTools.isEmpty
          ? ANSI.dim("  approved: every tool already matched its pin")
          : ANSI.green(TerminalText.sanitize(
              "  approved: pinned \(status.repinnedTools.joined(separator: ", "))")))
      }
      for prompt in prompts where prompt.server == status.server {
        let arguments = (prompt.info.arguments ?? []).map { "<\($0.name)>" }.joined(separator: " ")
        print(TerminalText.sanitize("  /\(prompt.slashName) \(arguments)  "
          + ANSI.dim(String((prompt.info.description ?? "").prefix(100)))))
      }
    }
    await provider.shutdown()
  }
}

// MARK: - McpScope

/// Which config file a setup verb edits or reads (X9): the user's (`~/.arnes/mcp.json`, or
/// `ARNES_MCP_CONFIG`) or the repository's `.mcp.json` at the repo root.
enum McpScope: String, ExpressibleByArgument, CaseIterable {
  case user
  case project

  /// The word a listing shows.
  var label: String { rawValue }
}

// MARK: - McpFiles

/// Where the two MCP scopes live for one directory, plus whether that directory is trusted —
/// what decides if the project file loads. Built from the real home by `current()`; tests inject
/// a temp home, cwd, environment and trust store so no verb ever touches `~/.arnes`.
struct McpFiles {
  let cwd: URL
  let home: URL
  let environment: [String: String]
  let store: ProjectTrustStore
  let options: ProjectInstructions.Options
  let shellPolicy: ShellEnvironmentPolicy?

  init(
    cwd: URL,
    home: URL,
    environment: [String: String],
    store: ProjectTrustStore,
    options: ProjectInstructions.Options = .default,
    shellPolicy: ShellEnvironmentPolicy? = nil)
  {
    self.cwd = cwd
    self.home = home
    self.environment = environment
    self.store = store
    self.options = options
    self.shellPolicy = shellPolicy
  }

  /// The process's own: the real home and trust store, the config's root markers and shell
  /// policy (a config that doesn't parse falls back to the defaults — the verbs are offline
  /// and must not fail on it; `arnes doctor` reports it).
  static func current() -> McpFiles {
    let config = loadedConfig()
    return McpFiles(
      cwd: ArnesRuntime.workingDirectory,
      home: URL(fileURLWithPath: NSHomeDirectory()),
      environment: ProcessInfo.processInfo.environment,
      store: ProjectTrustStore(),
      options: ProjectInstructions.Options(config: config?.instructions),
      shellPolicy: config?.shellEnvironment)
  }

  /// The `instructions` block's root markers, or the defaults — how `--scope project` and the
  /// status view find the repository root (the same rule `MemoryStore.forProject` uses).
  static func instructionOptions() -> ProjectInstructions.Options {
    ProjectInstructions.Options(config: loadedConfig()?.instructions)
  }

  private static func loadedConfig() -> ArnesConfig? {
    (try? ArnesConfig.load()) ?? nil
  }

  /// `~/.arnes/mcp.json`, or what `ARNES_MCP_CONFIG` names.
  var userURL: URL {
    if let override = environment["ARNES_MCP_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return home.appendingPathComponent(".arnes/mcp.json")
  }

  /// `<repo root>/.mcp.json`, whether or not it exists.
  var projectURL: URL { MCPConfig.projectFileURL(for: cwd, options: options) }

  /// Whether a run here would load the project file (the trust gate's remembered answer).
  var projectTrusted: Bool { store.isTrusted(cwd) }

  func url(for scope: McpScope) -> URL {
    switch scope {
    case .user: return userURL
    case .project: return projectURL
    }
  }

  /// Whether a stdio `command` resolves on the scrubbed PATH a server would inherit — the
  /// doctor's resolver, so `add` warns about exactly what `doctor` would.
  func resolves(_ command: String) -> Bool {
    DoctorChecks.resolveExecutable(command, environment: environment, cwd: cwd, home: home, policy: shellPolicy) != nil
  }

  func abbreviate(_ path: String) -> String {
    path.hasPrefix(home.path) ? "~" + path.dropFirst(home.path.count) : path
  }
}

// MARK: - MCPConfiguredEntry

/// One configured server in one scope, as a run would use it: a project entry already carries
/// the forced posture (`trust: untrusted`, never `required`). What `get` and `list` render.
struct MCPConfiguredEntry {
  let name: String
  let scope: McpScope
  let file: URL
  let config: MCPServerConfig
  /// A project entry with a user entry of the same name — the user's wins, this one never loads.
  let shadowed: Bool
  /// Project entries only: whether the directory is trusted (else the file is not loaded).
  let directoryTrusted: Bool?
  /// What the project posture changed about the file's entry (`required` dropped).
  let notices: [String]
}

/// Every configured entry across the scopes a directory would consult, plus the files that
/// could not be read (a broken file is reported, never fatal to the listing).
struct McpListing {
  var entries: [MCPConfiguredEntry] = []
  var problems: [String] = []
  let files: McpFiles

  var userEntries: [MCPConfiguredEntry] { entries.filter { $0.scope == .user } }
  var projectEntries: [MCPConfiguredEntry] { entries.filter { $0.scope == .project } }
}

// MARK: - McpEntries

/// The offline pieces of the setup verbs, pure over `McpFiles` (X9): reading both scopes,
/// writing a validated entry, and the `get`/`list` text. Never a header value or an env value —
/// a `${NAME}` template is shown verbatim, anything else as `<set>`.
enum McpEntries {
  static let projectNote =
    "the repository's .mcp.json: arnes loads it only in a trusted directory (arnes trust), as "
    + "untrusted (every result taints); it is written 0600 — chmod 644 it before committing"

  /// `KEY=VALUE` → the pair; nil without a `=` or with an empty key.
  static func parseAssignment(_ raw: String) -> (key: String, value: String)? {
    guard let split = raw.firstIndex(of: "=") else { return nil }
    let key = String(raw[..<split]).trimmingCharacters(in: .whitespaces)
    guard !key.isEmpty else { return nil }
    return (key, String(raw[raw.index(after: split)...]))
  }

  /// `Name: value` → the pair; nil without a `:` or with an empty name.
  static func parseHeader(_ raw: String) -> (name: String, value: String)? {
    guard let split = raw.firstIndex(of: ":") else { return nil }
    let name = String(raw[..<split]).trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty else { return nil }
    return (name, String(raw[raw.index(after: split)...]).trimmingCharacters(in: .whitespaces))
  }

  /// How a value prints: a `${NAME}` template as written, anything else `<set>`.
  static func display(_ value: String) -> String {
    MCPEntryValidation.isTemplate(value) ? value : "<set>"
  }

  // MARK: Reading

  static func listing(_ files: McpFiles) -> McpListing {
    var listing = McpListing(files: files)
    var userNames: Set<String> = []
    switch loadConfig(files.userURL) {
    case .success(let config):
      for (name, entry) in (config?.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
        userNames.insert(name)
        listing.entries.append(MCPConfiguredEntry(
          name: name, scope: .user, file: files.userURL, config: entry, shadowed: false,
          directoryTrusted: nil, notices: []))
      }
    case .failure(let error):
      listing.problems.append("\(files.abbreviate(files.userURL.path)) does not parse — no server in it loads: \(error)")
    }
    switch loadConfig(files.projectURL) {
    case .success(let config):
      let trusted = files.projectTrusted
      for (name, entry) in (config?.mcpServers ?? [:]).sorted(by: { $0.key < $1.key }) {
        var notices: [String] = []
        let forced = MCPConfig.projectPosture(entry, name: name, notices: &notices)
        listing.entries.append(MCPConfiguredEntry(
          name: name, scope: .project, file: files.projectURL, config: forced,
          shadowed: userNames.contains(name), directoryTrusted: trusted,
          notices: notices.map { $0.replacingOccurrences(of: "mcp \(name): ", with: "") }))
      }
    case .failure(let error):
      listing.problems.append("\(files.abbreviate(files.projectURL.path)) does not parse — the project's servers are not loaded: \(error)")
    }
    return listing
  }

  private static func loadConfig(_ url: URL) -> Result<MCPConfig?, Error> {
    Result { try MCPConfig.load(from: url) }
  }

  // MARK: Writing

  /// Validates and writes `entry` under `name` in `scope`; the lines a verb prints. Every
  /// refusal is a `ValidationError` (exit 64) phrased by `MCPSetupError`.
  static func write(
    name: String, entry: JSONValue, scope: McpScope, files: McpFiles, allowLiteral: Bool)
    throws -> [String]
  {
    let validated: MCPEntryValidation.Validated
    do {
      validated = try MCPEntryValidation.validate(
        name: name, entry: entry, allowLiteral: allowLiteral, commandResolves: { files.resolves($0) })
    } catch let error as MCPSetupError {
      throw ValidationError(error.description)
    }
    if scope == .project, validated.config.isRequired {
      throw ValidationError(
        "a project entry cannot be required (a clone must not be able to make every run fail) — drop required, or add it in the user scope")
    }
    let url = files.url(for: scope)
    var file: MCPConfigFile
    do {
      file = try MCPConfigFile.load(url)
    } catch let error as MCPSetupError {
      throw ValidationError(error.description)
    }
    let replaced = file.upsert(name: name, entry: entry)
    try file.save(to: url)
    var lines = ["\(replaced ? "replaced" : "added") \(name) (\(validated.config.transportSummary)) → \(files.abbreviate(url.path))"]
    lines += validated.warnings.map { ANSI.yellow("⚠ \($0)") }
    if scope == .project {
      if validated.config.trust != nil, !validated.config.isUntrusted {
        lines.append(ANSI.yellow("⚠ trust: \"\(validated.config.trust ?? "")\" is ignored for a project entry — it always loads as untrusted"))
      }
      lines.append(ANSI.dim(projectNote))
    }
    return lines
  }

  // MARK: get / list text

  static func getLines(_ entry: MCPConfiguredEntry, files: McpFiles) -> [String] {
    let config = entry.config
    var where_ = "\(entry.scope.label) · \(files.abbreviate(entry.file.path))"
    if entry.scope == .project {
      where_ += entry.directoryTrusted == true
        ? " — loads as untrusted (the directory is trusted)"
        : " — not loaded: the directory is not trusted (`arnes trust` there)"
    }
    var lines = [TerminalText.sanitize("\(ANSI.bold(entry.name))  \(ANSI.dim(where_))")]
    if entry.shadowed {
      lines.append(ANSI.yellow("  shadowed by the user entry of the same name — the user's wins, this one never loads"))
    }
    for notice in entry.notices { lines.append(ANSI.yellow(TerminalText.sanitize("  ⚠ \(notice)"))) }
    func row(_ label: String, _ value: String) -> String {
      TerminalText.sanitize("  \(label.padding(toLength: 11, withPad: " ", startingAt: 0))\(value)")
    }
    lines.append(row("transport", config.transportSummary))
    if config.transport == .stdio {
      if let args = config.args, !args.isEmpty { lines.append(row("args", args.joined(separator: " "))) }
      let env = (config.env ?? [:]).sorted { $0.key < $1.key }
      if !env.isEmpty {
        lines.append(row("env", env.map { "\($0.key)=\(display($0.value))" }.joined(separator: " · ")))
      }
    } else {
      let headers = (config.headers ?? [:]).sorted { $0.key < $1.key }
      if !headers.isEmpty {
        lines.append(row("headers", headers.map { "\($0.key): \(display($0.value))" }.joined(separator: " · ")))
      }
      if config.insecure == true { lines.append(row("insecure", "yes — plain http allowed off loopback")) }
    }
    lines.append(row("required", config.isRequired ? "yes" : "no"))
    lines.append(row("enabled", config.isEnabled ? "yes" : "no"))
    lines.append(row("trust", config.isUntrusted ? "untrusted — every result taints, readOnlyHint ignored" : "trusted"))
    lines.append(row("timeouts", "startup \(Int(config.startupTimeout))s · tool \(Int(config.toolTimeout))s"))
    if let bound = config.resultCharLimit { lines.append(row("results", "capped at \(bound) chars (head + tail)")) }
    return lines
  }

  static func listLines(_ listing: McpListing) -> [String] {
    var lines: [String] = []
    let files = listing.files
    for problem in listing.problems { lines.append(ANSI.yellow(TerminalText.sanitize("⚠ \(problem)"))) }
    guard !listing.entries.isEmpty else {
      lines.append("no MCP servers configured — arnes mcp add <name> -- <command>, or arnes mcp add <name> --url https://…")
      return lines
    }
    let width = listing.entries.map(\.name.count).max() ?? 0
    for entry in listing.entries {
      let name = entry.name.padding(toLength: width, withPad: " ", startingAt: 0)
      let scope: String
      switch entry.scope {
      case .user:
        scope = "user"
      case .project:
        scope = entry.directoryTrusted == true
          ? "project · untrusted"
          : "project · not trusted — arnes trust"
      }
      var tags: [String] = []
      if entry.config.isRequired { tags.append(ANSI.yellow("[required]")) }
      if !entry.config.isEnabled { tags.append(ANSI.dim("[disabled]")) }
      if entry.scope == .user, entry.config.isUntrusted { tags.append(ANSI.yellow("[untrusted]")) }
      if entry.shadowed { tags.append(ANSI.yellow("[shadowed by the user entry]")) }
      let styledName = entry.shadowed || !entry.config.isEnabled ? ANSI.dim(name) : ANSI.bold(name)
      lines.append(TerminalText.sanitize(
        "\(styledName)  \(ANSI.dim(scope))  \(entry.config.transportSummary)"
          + (tags.isEmpty ? "" : "  " + tags.joined(separator: " "))))
    }
    var footer = "files: \(files.abbreviate(files.userURL.path))"
    if listing.projectEntries.isEmpty == false || FileManager.default.fileExists(atPath: files.projectURL.path) {
      footer += " · \(files.abbreviate(files.projectURL.path))"
        + (files.projectTrusted ? "" : " (not trusted — not loaded)")
    }
    lines.append(ANSI.dim(TerminalText.sanitize(footer)))
    lines.append(ANSI.dim("arnes mcp connects them and lists tools · arnes mcp get <name> shows one entry"))
    return lines
  }
}

// MARK: - mcp add

struct McpAdd: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add",
    abstract: "Add (or replace) an MCP server: a stdio command after --, or an http --url. Offline.",
    discussion: """
      arnes mcp add filesystem -- npx -y @modelcontextprotocol/server-filesystem /tmp
      arnes mcp add docs --url https://mcp.example.com/mcp --header 'Authorization: Bearer ${DOCS_TOKEN}'
      arnes mcp add gateway --env 'GATEWAY_TOKEN=${GATEWAY_TOKEN}' -- gateway-mcp --stdio

      Secrets go in as ${NAME} templates (single-quote them so the shell leaves them alone):
      arnes expands them from the environment at connect time, so the file never holds a
      token. An env or header value that looks like a literal secret is refused unless
      --allow-literal (0600, this machine only).

      --scope project writes <repo root>/.mcp.json (Claude Code's file), 0600 like every file
      arnes writes — chmod 644 it before committing. arnes loads it only in a trusted directory
      (arnes trust) and always as trust: untrusted; a project entry cannot be required and never
      overrides a user entry of the same name. A running session keeps its toolset — the new
      server joins the next one.
      """)

  @Argument(help: "Server name: letters, digits, _ or -, no __ (its tools become mcp__<name>__<tool>).")
  var name: String

  @Argument(
    parsing: .postTerminator,
    help: ArgumentHelp("The stdio command and its arguments, after --.", valueName: "command"))
  var command: [String] = []

  @Option(help: "user (~/.arnes/mcp.json, or ARNES_MCP_CONFIG) or project (<repo root>/.mcp.json).")
  var scope: McpScope = .user

  @Option(
    name: .customLong("env"),
    help: ArgumentHelp("KEY=VALUE for the server process (stdio); repeatable. Write ${NAME} for a secret.", valueName: "KEY=VALUE"))
  var env: [String] = []

  @Option(help: ArgumentHelp("The http endpoint (streamable HTTP) instead of a command.", valueName: "https://…"))
  var url: String?

  @Option(
    name: .customLong("header"),
    help: ArgumentHelp("\"Name: value\" request header (http); repeatable. Write ${NAME} for a token.", valueName: "Name: value"))
  var header: [String] = []

  @Flag(help: "Allow plain http:// to a non-loopback host (a trusted network).")
  var insecure = false

  @Flag(help: "A failure to connect stops `arnes do` with exit 1. Refused in the project scope.")
  var required = false

  @Flag(help: "trust: untrusted — readOnlyHint ignored, every result taints the session (a project entry always is).")
  var untrusted = false

  @Option(name: .customLong("startup-timeout"), help: ArgumentHelp("Seconds the handshake may take (default 30).", valueName: "N"))
  var startupTimeout: Int?

  @Option(name: .customLong("tool-timeout"), help: ArgumentHelp("Seconds one tool call may take (default 120).", valueName: "N"))
  var toolTimeout: Int?

  @Option(name: .customLong("max-result-chars"), help: ArgumentHelp("Inner bound on a tool result from this server (head + tail kept).", valueName: "N"))
  var maxResultChars: Int?

  @Flag(name: .customLong("allow-literal"), help: "Write an env/header value that looks like a secret anyway (0600, this machine only).")
  var allowLiteral = false

  func validate() throws {
    switch (url != nil, !command.isEmpty) {
    case (true, true):
      throw ValidationError("give a stdio command after -- or an http --url, not both")
    case (false, false):
      throw ValidationError("give a stdio command after -- (arnes mcp add <name> -- <command> [args…]) or an http --url")
    default:
      break
    }
    if url != nil, !env.isEmpty { throw ValidationError("--env is for a stdio server's process; an http server takes --header") }
    if url == nil, !header.isEmpty { throw ValidationError("--header is for an http server; a stdio server takes --env") }
    if url == nil, insecure { throw ValidationError("--insecure applies to an http --url") }
    for raw in env where McpEntries.parseAssignment(raw) == nil {
      throw ValidationError("--env takes KEY=VALUE (got '\(raw)')")
    }
    for raw in header where McpEntries.parseHeader(raw) == nil {
      throw ValidationError("--header takes \"Name: value\" (got '\(raw)')")
    }
    if scope == .project, required {
      throw ValidationError("--required is not allowed in the project scope — a clone must not be able to make every run fail")
    }
    for (label, value) in [("--startup-timeout", startupTimeout), ("--tool-timeout", toolTimeout), ("--max-result-chars", maxResultChars)] {
      if let value, value < 1 { throw ValidationError("\(label) must be at least 1") }
    }
  }

  /// The entry as JSON — the file is edited as a tree, so this is exactly what lands in it.
  func entry() -> JSONValue {
    var object: [String: JSONValue] = [:]
    if let url {
      object["type"] = .string("http")
      object["url"] = .string(url)
      let headers = header.compactMap(McpEntries.parseHeader)
      if !headers.isEmpty {
        object["headers"] = .object(Dictionary(headers.map { ($0.name, JSONValue.string($0.value)) }, uniquingKeysWith: { _, last in last }))
      }
      if insecure { object["insecure"] = .bool(true) }
    } else {
      object["command"] = .string(command[0])
      if command.count > 1 { object["args"] = .array(command.dropFirst().map { .string($0) }) }
      let pairs = env.compactMap(McpEntries.parseAssignment)
      if !pairs.isEmpty {
        object["env"] = .object(Dictionary(pairs.map { ($0.key, JSONValue.string($0.value)) }, uniquingKeysWith: { _, last in last }))
      }
    }
    if required { object["required"] = .bool(true) }
    if untrusted { object["trust"] = .string("untrusted") }
    if let startupTimeout { object["startupTimeoutSeconds"] = .int(startupTimeout) }
    if let toolTimeout { object["toolTimeoutSeconds"] = .int(toolTimeout) }
    if let maxResultChars { object["maxResultChars"] = .int(maxResultChars) }
    return .object(object)
  }

  func run() async throws {
    for line in try perform(files: McpFiles.current()) { print(line) }
  }

  func perform(files: McpFiles) throws -> [String] {
    try McpEntries.write(name: name, entry: entry(), scope: scope, files: files, allowLiteral: allowLiteral)
  }
}

// MARK: - mcp add-json

struct McpAddJSON: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "add-json",
    abstract: "Add (or replace) an MCP server from a raw JSON entry, validated like `add`. Offline.",
    discussion: """
      arnes mcp add-json docs '{"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer ${DOCS_TOKEN}"}}'

      The object is the entry as Claude Code writes it (command/args/env, or url/headers, plus
      required, enabled, trust, timeouts). Keys arnes doesn't model are kept. A ${NAME} value
      stays a template; a literal secret is refused unless --allow-literal.
      """)

  @Argument(help: "Server name: letters, digits, _ or -, no __.")
  var name: String

  @Argument(help: ArgumentHelp("The entry as a JSON object.", valueName: "json"))
  var json: String

  @Option(help: "user (~/.arnes/mcp.json, or ARNES_MCP_CONFIG) or project (<repo root>/.mcp.json).")
  var scope: McpScope = .user

  @Flag(name: .customLong("allow-literal"), help: "Write an env/header value that looks like a secret anyway (0600, this machine only).")
  var allowLiteral = false

  func entry() throws -> JSONValue {
    let value: JSONValue
    do {
      value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    } catch {
      throw ValidationError("the entry is not valid JSON: \(error)")
    }
    guard value.objectValue != nil else { throw ValidationError("the entry must be a JSON object") }
    return value
  }

  func run() async throws {
    for line in try perform(files: McpFiles.current()) { print(line) }
  }

  func perform(files: McpFiles) throws -> [String] {
    try McpEntries.write(name: name, entry: try entry(), scope: scope, files: files, allowLiteral: allowLiteral)
  }
}

// MARK: - mcp remove

struct McpRemove: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "remove",
    abstract: "Remove an MCP server entry (the user scope first, then the project's, unless --scope names one). Offline.")

  @Argument(help: "The server to remove.")
  var name: String

  @Option(help: "Only this scope: user or project (default: whichever names it, user first).")
  var scope: McpScope?

  func run() async throws {
    for line in try perform(files: McpFiles.current()) { print(line) }
  }

  func perform(files: McpFiles) throws -> [String] {
    let scopes = scope.map { [$0] } ?? McpScope.allCases
    var removedFrom: McpScope?
    for candidate in scopes {
      let url = files.url(for: candidate)
      var file: MCPConfigFile
      do {
        file = try MCPConfigFile.load(url)
      } catch let error as MCPSetupError {
        throw ValidationError(error.description)
      }
      guard file.remove(name: name) else { continue }
      try file.save(to: url)
      removedFrom = candidate
      break
    }
    guard let removedFrom else {
      let searched = scopes.map { files.abbreviate(files.url(for: $0).path) }.joined(separator: " or ")
      throw ValidationError("no server named \(name) in \(searched) — arnes mcp list shows what is configured")
    }
    var lines = ["removed \(name) from \(files.abbreviate(files.url(for: removedFrom).path))"]
    // The pins recorded the server's tool definitions at first sight; a name nobody configures
    // any more should start fresh when it comes back. One still configured elsewhere keeps them.
    let elsewhere = McpScope.allCases.filter { $0 != removedFrom }.first { other in
      ((try? MCPConfigFile.load(files.url(for: other)))?.entry(named: name)) != nil
    }
    if let elsewhere {
      lines.append(ANSI.dim("its tool pins are kept — \(files.abbreviate(files.url(for: elsewhere).path)) still names it"))
    } else {
      try files.store.forgetMCPTools(for: name)
      lines.append(ANSI.dim("forgot its tool pins — a re-add starts with a fresh first sight"))
    }
    return lines
  }
}

// MARK: - mcp get

struct McpGet: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "get",
    abstract: "Show one configured server as arnes will use it (no values — a ${NAME} template verbatim, a literal as <set>). Offline.")

  @Argument(help: "The server name.")
  var name: String

  @Flag(help: "Print one JSON array of {name, scope, file, transport, host_or_command, required, enabled, trust, env_keys, header_names, shadowed, directory_trusted} rows (one per scope that names it).")
  var json = false

  func run() async throws {
    let files = McpFiles.current()
    let listing = McpEntries.listing(files)
    let matching = listing.entries.filter { $0.name == name }
    guard !matching.isEmpty else {
      let known = listing.entries.map(\.name)
      throw ValidationError(
        "no server named \(name)"
          + (known.isEmpty ? " — none configured" : " — configured: \(Set(known).sorted().joined(separator: ", "))")
          + "; arnes mcp list shows every scope")
    }
    if json {
      try JSONOut.print(matching.map { MCPEntryRow($0, files: files) })
      return
    }
    for problem in listing.problems { print(ANSI.yellow(TerminalText.sanitize("⚠ \(problem)"))) }
    for (index, entry) in matching.enumerated() {
      if index > 0 { print("") }
      for line in McpEntries.getLines(entry, files: files) { print(line) }
    }
  }
}

// MARK: - mcp list

struct McpList: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "list",
    abstract: "Every configured server across the scopes this directory would load, without connecting. Offline.")

  @Flag(help: "Print one JSON array of {name, scope, file, transport, host_or_command, required, enabled, trust, env_keys, header_names, shadowed, directory_trusted} rows.")
  var json = false

  func run() async throws {
    let files = McpFiles.current()
    let listing = McpEntries.listing(files)
    if json {
      for problem in listing.problems { JSONOut.stderr(ANSI.yellow(TerminalText.sanitize("⚠ \(problem)"))) }
      try JSONOut.print(listing.entries.map { MCPEntryRow($0, files: files) })
      return
    }
    for line in McpEntries.listLines(listing) { print(line) }
  }
}
