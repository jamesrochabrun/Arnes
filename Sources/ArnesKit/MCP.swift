import Foundation
import OpenRouterSwift

// MARK: - MCPError

public enum MCPError: Error, CustomStringConvertible, Sendable {
  /// The transport was used before `start()` or after the server went away.
  case notConnected(server: String)
  /// The server process exited or closed its pipe while requests were pending.
  case disconnected(server: String)
  /// The server answered a request with a JSON-RPC error.
  case server(String)
  /// No response within the request timeout.
  case timedOut(method: String, seconds: Double)
  /// The entry can't be used as written: no `command` and no `url`, or a URL the
  /// `URLPolicy` refuses.
  case misconfigured(server: String, detail: String)
  /// The HTTP transport could not deliver a message (bad status, refused redirect).
  case transport(server: String, detail: String)

  public var description: String {
    switch self {
    case .notConnected(let server): return "mcp server \(server) is not connected"
    case .disconnected(let server): return "mcp server \(server) disconnected"
    case .server(let message): return "mcp server error: \(message)"
    case .timedOut(let method, let seconds):
      return "mcp request \(method) timed out after \(Int(seconds))s"
    case .misconfigured(let server, let detail):
      return "mcp server \(server) is misconfigured: \(detail)"
    case .transport(let server, let detail):
      return "mcp server \(server): \(detail)"
    }
  }
}

// MARK: - MCPConfig

/// One server entry in `~/.arnes/mcp.json`, in Claude Code's `.mcp.json` spelling: a
/// `command` (stdio — arnes launches it and speaks JSON-RPC over its pipes) or a `url`
/// (streamable HTTP — arnes POSTs each message to it). `type` names the transport when
/// an entry carries both.
public struct MCPServerConfig: Codable, Sendable {
  public enum Transport: String, Sendable {
    case stdio
    case http
  }

  /// `stdio` or `http` (`streamable-http`/`sse` are accepted spellings). Optional:
  /// `command` implies stdio, `url` implies http.
  public var type: String?
  /// stdio: the executable, resolved via PATH.
  public var command: String?
  public var args: [String]?
  /// Extra environment merged over the inherited process environment (stdio only).
  public var env: [String: String]?
  /// http: the endpoint every JSON-RPC message is POSTed to.
  public var url: String?
  /// http: extra request headers. `${NAME}` expands from the environment the way `env`
  /// does, so `"Authorization": "Bearer ${MY_TOKEN}"` keeps the token out of the file.
  public var headers: [String: String]?
  /// http: allow plain `http://` to a non-loopback host (a trusted network). Off by
  /// default — the headers usually carry a bearer token.
  public var insecure: Bool?
  /// A server the run can't do without: failing to connect stops `arnes do` (exit 1)
  /// instead of quietly continuing with the remaining servers.
  public var required: Bool?
  /// `false` keeps the entry in the file but skips the server.
  public var enabled: Bool?
  /// Seconds the handshake and `tools/list` may take (default 30).
  public var startupTimeoutSeconds: Int?
  /// Seconds one `tools/call` may take (default 120) — MCP tools do real work.
  public var toolTimeoutSeconds: Int?
  /// An explicit inner bound on a tool result from this server, in characters: over it the
  /// client keeps the head and the tail and drops the middle before the session sees it.
  /// Unset (the default), a result reaches the session whole and the session's universal
  /// cap (`limits.toolResultChars`, 30000) decides what the model reads — spilling the full
  /// text to a file the model can `read_file`. Set it only to hold one chatty server below
  /// that cap; a result cut here never reaches the spill.
  public var maxResultChars: Int?
  /// How far the server's word is taken: `"trusted"` (the default — a user who installed a
  /// server chose to run its code; its `readOnlyHint` lifts the prompt, exactly as before) or
  /// `"untrusted"`: `readOnlyHint` is ignored (every tool is at least `.mutating`, so it prompts),
  /// `destructiveHint`/`openWorldHint` still make a tool `.sensitive`, and every result taints
  /// the session (`TaintingTool`) — the posture for a remote server or a repository's own.
  public var trust: String?

  public init(
    type: String? = nil,
    command: String? = nil,
    args: [String]? = nil,
    env: [String: String]? = nil,
    url: String? = nil,
    headers: [String: String]? = nil,
    insecure: Bool? = nil,
    required: Bool? = nil,
    enabled: Bool? = nil,
    startupTimeoutSeconds: Int? = nil,
    toolTimeoutSeconds: Int? = nil,
    maxResultChars: Int? = nil,
    trust: String? = nil)
  {
    self.type = type
    self.command = command
    self.args = args
    self.env = env
    self.url = url
    self.headers = headers
    self.insecure = insecure
    self.required = required
    self.enabled = enabled
    self.startupTimeoutSeconds = startupTimeoutSeconds
    self.toolTimeoutSeconds = toolTimeoutSeconds
    self.maxResultChars = maxResultChars
    self.trust = trust
  }

  /// `trust: "untrusted"`; any other spelling (or none) keeps today's behavior.
  public var isUntrusted: Bool {
    trust?.lowercased().trimmingCharacters(in: .whitespaces) == "untrusted"
  }

  /// Which transport this entry means: `type` when it says, otherwise `url` → http and
  /// anything else → stdio (so every config written before HTTP existed still means stdio).
  public var transport: Transport {
    switch type?.lowercased().trimmingCharacters(in: .whitespaces) {
    case "http", "streamable-http", "streamablehttp", "http-stream", "sse":
      return .http
    case "stdio":
      return .stdio
    default:
      return (url?.isEmpty == false) ? .http : .stdio
    }
  }

  public var isEnabled: Bool { enabled ?? true }
  public var isRequired: Bool { required ?? false }
  /// Handshake budget. Floored at a second so a typo can't make every server fail.
  public var startupTimeout: TimeInterval { max(1, TimeInterval(startupTimeoutSeconds ?? 30)) }
  public var toolTimeout: TimeInterval { max(1, TimeInterval(toolTimeoutSeconds ?? 120)) }
  /// The explicit per-server bound, floored at 500; nil when the server sets none (the
  /// session's universal cap then applies).
  public var resultCharLimit: Int? { maxResultChars.map { max(500, $0) } }

  /// The headers actually sent, with `${NAME}` expanded from the environment.
  public func expandedHeaders(
    environment: [String: String] = ProcessInfo.processInfo.environment)
    -> [String: String]
  {
    (headers ?? [:]).mapValues { VariableExpansion.expand($0, environment: environment) }
  }

  /// One line for `arnes mcp`: the command for stdio, the *host* for http. Never a
  /// header value and never the URL's path or query — both routinely carry tokens.
  public var transportSummary: String {
    switch transport {
    case .stdio:
      let words = ([command].compactMap { $0 } + (args ?? [])).joined(separator: " ")
      return "stdio \(String(words.prefix(60)))"
    case .http:
      let host = url.flatMap { URL(string: $0) }.flatMap { URLPolicy.host(of: $0) }
      return "http \(host ?? "?")"
    }
  }
}

// MARK: - MCPConfigError

public enum MCPConfigError: Error, CustomStringConvertible, Sendable, Equatable {
  case fileNotFound(String)
  case invalid(source: String, detail: String)

  public var description: String {
    switch self {
    case .fileNotFound(let path):
      return "no MCP config at \(path)"
    case .invalid(let source, let detail):
      return "\(source) is not valid MCP config JSON: \(detail)"
    }
  }
}

// MARK: - MCPConfig

/// The MCP config file, mirroring the `mcpServers` shape used by Claude Desktop and
/// Claude Code so existing configs can be copied verbatim.
public struct MCPConfig: Codable, Sendable {
  public var mcpServers: [String: MCPServerConfig]

  public init(mcpServers: [String: MCPServerConfig]) {
    self.mcpServers = mcpServers
  }

  /// The user-global file.
  public static var homeURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/mcp.json")
  }

  /// `~/.arnes/mcp.json`, or the `ARNES_MCP_CONFIG` env override (per-project configs).
  public static var defaultURL: URL {
    if let override = ProcessInfo.processInfo.environment["ARNES_MCP_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return homeURL
  }

  /// Loads the config, or nil when the file doesn't exist (MCP is opt-in by presence).
  public static func load(from url: URL = defaultURL) throws -> MCPConfig? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(MCPConfig.self, from: Data(contentsOf: url))
  }

  /// A `--mcp-config` value: inline JSON when it starts with `{`, a file path otherwise.
  /// Unlike `load`, a path that isn't there throws — the user named it, so a typo has to
  /// be loud rather than silently disable MCP.
  public static func parse(_ raw: String) throws -> MCPConfig {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("{") {
      do {
        return try JSONDecoder().decode(MCPConfig.self, from: Data(trimmed.utf8))
      } catch {
        throw MCPConfigError.invalid(source: "--mcp-config JSON", detail: "\(error)")
      }
    }
    let url = URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      throw MCPConfigError.fileNotFound(url.path)
    }
    do {
      return try JSONDecoder().decode(MCPConfig.self, from: Data(contentsOf: url))
    } catch {
      throw MCPConfigError.invalid(source: url.path, detail: "\(error)")
    }
  }

  /// What a run should actually connect.
  ///
  /// - `explicit` is `--mcp-config` (inline JSON or a path); it *replaces*
  ///   `ARNES_MCP_CONFIG` as the chosen file and its entries win on name collisions.
  /// - `strict` is `--strict-mcp-config`: ignore `~/.arnes/mcp.json` entirely, so only
  ///   what the flag names is connected (and nothing at all when it names nothing).
  ///
  /// With neither, this is exactly the old behavior: `ARNES_MCP_CONFIG` or the home file.
  public static func resolve(
    explicit: String? = nil,
    strict: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeURL: URL = MCPConfig.homeURL,
    project: URL? = nil)
    throws -> MCPConfig?
  {
    try resolved(explicit: explicit, strict: strict, environment: environment, homeURL: homeURL, project: project)
      .config
  }

  /// What `resolve` decided and why — the notices a run prints (X9): a repository entry shadowed
  /// by the user's, a `required: true` a repository asked for and did not get.
  public struct Resolution: Sendable {
    public let config: MCPConfig?
    /// The names of the servers that came from the project file (already forced untrusted).
    public let projectServers: Set<String>
    /// One line each, phrased for a human; empty when nothing was overridden or dropped.
    public let notices: [String]
    /// The files that contributed entries, in precedence order (lowest first) — what `/mcp`
    /// names as "the config in play". A `--mcp-config` inline JSON is `--mcp-config`.
    public let sources: [String]

    public init(config: MCPConfig?, projectServers: Set<String> = [], notices: [String] = [], sources: [String] = []) {
      self.config = config
      self.projectServers = projectServers
      self.notices = notices
      self.sources = sources
    }
  }

  /// `resolve` with the reasons. The precedence is `--mcp-config` > the ambient user file
  /// (`ARNES_MCP_CONFIG` or `~/.arnes/mcp.json`) > the project's `.mcp.json` — a repository's
  /// entry never overrides the user's of the same name (narrow, never widen), and every project
  /// entry is forced `trust: "untrusted"` whatever the file says and stripped of `required: true`
  /// (a clone must not be able to make every headless run fail). `strict` ignores the project file
  /// along with the ambient one; `project == nil` is byte-for-byte the pre-X9 resolution.
  public static func resolved(
    explicit: String? = nil,
    strict: Bool = false,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeURL: URL = MCPConfig.homeURL,
    project: URL? = nil)
    throws -> Resolution
  {
    let named = explicit?.trimmingCharacters(in: .whitespacesAndNewlines)
    var servers: [String: MCPServerConfig] = [:]
    var projectServers: Set<String> = []
    var notices: [String] = []
    var sources: [String] = []
    if !strict {
      var ambient = homeURL
      if named == nil || named?.isEmpty == true,
         let override = environment["ARNES_MCP_CONFIG"], !override.isEmpty
      {
        ambient = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
      }
      if let project, FileManager.default.fileExists(atPath: project.path) {
        var entries: [String: MCPServerConfig] = [:]
        do {
          entries = (try load(from: project))?.mcpServers ?? [:]
        } catch {
          notices.append("\(project.path) is invalid — this project's MCP servers are not loaded: \(error)")
        }
        for (name, entry) in entries {
          servers[name] = Self.projectPosture(entry, name: name, notices: &notices)
          projectServers.insert(name)
        }
        if !entries.isEmpty { sources.append(project.path) }
      }
      let user = (try load(from: ambient))?.mcpServers ?? [:]
      for (name, entry) in user {
        if projectServers.contains(name) {
          notices.append(
            "mcp \(name): the repository's .mcp.json entry is shadowed by \(Self.abbreviate(ambient.path))")
          projectServers.remove(name)
        }
        servers[name] = entry
      }
      if !user.isEmpty { sources.append(ambient.path) }
    }
    if let named, !named.isEmpty {
      for (name, entry) in try parse(named).mcpServers {
        if projectServers.contains(name) {
          notices.append("mcp \(name): the repository's .mcp.json entry is shadowed by --mcp-config")
          projectServers.remove(name)
        }
        servers[name] = entry
      }
      sources.append(named.hasPrefix("{") ? "--mcp-config" : (named as NSString).expandingTildeInPath)
    }
    return Resolution(
      config: servers.isEmpty ? nil : MCPConfig(mcpServers: servers),
      projectServers: projectServers,
      notices: notices.sorted(),
      sources: sources)
  }

  /// A project entry as a run uses it: untrusted whatever the file says, never `required`.
  /// Public so `arnes mcp get`/`list` show a project entry the way a run would load it.
  public static func projectPosture(_ entry: MCPServerConfig, name: String, notices: inout [String]) -> MCPServerConfig {
    var forced = entry
    forced.trust = "untrusted"
    if entry.isRequired {
      forced.required = nil
      notices.append(
        "mcp \(name): the repository's .mcp.json says required: true — ignored (a project entry cannot make a run fail)")
    }
    return forced
  }

  // MARK: Project file (X9)

  /// Claude Code's project-scoped MCP file, at the repository root.
  public static let projectFileName = ".mcp.json"

  /// Where a directory's project MCP file lives whether or not it exists: `<repo root>/.mcp.json`,
  /// the root being the nearest ancestor holding a root marker (`.git` by default — the same rule
  /// `MemoryStore.forProject` and the instruction files use), else the directory itself.
  public static func projectFileURL(
    for directory: URL, options: ProjectInstructions.Options = .default) -> URL
  {
    let root = ProjectInstructions.directoryChain(workdir: directory, options: options).first ?? directory
    return root.appendingPathComponent(projectFileName)
  }

  /// `projectFileURL` when the file exists, nil otherwise — what a run passes as `project:` once
  /// the directory is trusted.
  public static func projectURL(
    for directory: URL, options: ProjectInstructions.Options = .default) -> URL?
  {
    let url = projectFileURL(for: directory, options: options)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  /// The servers a directory's project file declares — what a trust prompt lists. Names and
  /// transports only; [] when there is no file or it doesn't parse.
  public static func projectServers(
    in directory: URL, options: ProjectInstructions.Options = .default) -> [MCPServerSummary]
  {
    guard let url = projectURL(for: directory, options: options),
          let config = try? load(from: url)
    else { return [] }
    return config.mcpServers
      .map { MCPServerSummary(name: $0.key, transport: $0.value.transportSummary) }
      .sorted { $0.name < $1.name }
  }

  static func abbreviate(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}

// MARK: - MCPServerSummary

/// One server as a trust prompt or a listing names it: the name and `ServerStatus.transport`'s
/// `stdio <cmd…>` / `http <host>` line — never a header value, never a URL path (X9).
public struct MCPServerSummary: Sendable, Equatable, Hashable {
  public let name: String
  public let transport: String

  public init(name: String, transport: String) {
    self.name = name
    self.transport = transport
  }
}

// MARK: - MCPTransport

/// A newline-delimited JSON-RPC pipe to one MCP server. Injected as a protocol so the
/// client is testable with a scripted transport, matching how `OpenRouterService` is mocked.
public protocol MCPTransport: Sendable {
  /// Launches the server and returns its incoming message lines. The stream finishing
  /// means the server went away.
  func start() async throws -> AsyncStream<String>
  /// Sends one JSON-RPC message (a single line, no trailing newline).
  func send(_ line: String) async throws
  func stop() async
}

/// The real transport: spawns the configured command and frames messages as one JSON
/// object per line over stdin/stdout (the MCP stdio transport).
///
/// The server inherits the environment so `npx`/`uvx`-style commands resolve, minus
/// Arnes's own secrets: the provider token must not leak into third-party server
/// processes. A server that genuinely needs one of those variables gets it through the
/// config's `env`, where `${NAME}` expands from the parent environment.
public actor ProcessMCPTransport: MCPTransport {
  /// Variables withheld from servers unless their config sets them explicitly — the
  /// names Arnes's provider tokens travel under. The CLI adds the active provider's
  /// `apiKeyEnv`. Shared with `bash`/hook scrubbing via `SubprocessEnvironment`.
  public static let defaultRedactedEnvironmentKeys = SubprocessEnvironment.providerTokenKeys

  private let name: String
  private let config: MCPServerConfig
  private let redactedEnvironmentKeys: Set<String>
  private let workingDirectory: URL?
  private let expandEnvironmentVariables: Bool
  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stderrTask: Task<Void, Never>?
  private var stopTask: Task<Void, Never>?
  /// Tail of the server's stderr, surfaced when startup fails.
  private var stderrTail = ""

  public init(
    name: String,
    config: MCPServerConfig,
    redactingEnvironment redacted: Set<String> = ProcessMCPTransport.defaultRedactedEnvironmentKeys,
    workingDirectory: URL? = nil,
    expandEnvironmentVariables: Bool = true)
  {
    self.name = name
    self.config = config
    redactedEnvironmentKeys = redacted
    self.workingDirectory = workingDirectory
    self.expandEnvironmentVariables = expandEnvironmentVariables
  }

  /// The child's environment: the parent's, minus redacted secrets, plus the config's
  /// `env` (with `${NAME}` references expanded from the parent — the only way to pass a
  /// redacted variable through on purpose).
  static func environment(
    for config: MCPServerConfig,
    inheriting parent: [String: String],
    redacting redacted: Set<String>, expandingValues: Bool = true)
    -> [String: String]
  {
    var environment = parent
    for key in redacted {
      environment.removeValue(forKey: key)
    }
    for (key, value) in config.env ?? [:] {
      environment[key] = expandingValues ? expand(value, from: parent) : value
    }
    return environment
  }

  /// Replaces every `${NAME}` with the parent's value (empty when unset).
  static func expand(_ value: String, from parent: [String: String]) -> String {
    VariableExpansion.expand(value, environment: parent)
  }

  public func start() async throws -> AsyncStream<String> {
    guard process == nil, stopTask == nil else {
      throw MCPError.transport(server: name, detail: "transport is already started or stopping")
    }
    guard let command = config.command, !command.isEmpty else {
      throw MCPError.misconfigured(
        server: name,
        detail: #"no "command" — a stdio server needs one (or set "url" for an http server)"#)
    }
    let process = Process()
    // `env` resolves the command via PATH — configs say "npx", not an absolute path.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [command] + (config.args ?? [])
    process.currentDirectoryURL = workingDirectory
    process.environment = Self.environment(
      for: config,
      inheriting: ProcessInfo.processInfo.environment,
      redacting: redactedEnvironmentKeys, expandingValues: expandEnvironmentVariables)

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    self.process = process
    stdinHandle = stdin.fileHandleForWriting

    let stderrLines = Self.lineStream(from: stderr.fileHandleForReading)
    stderrTask = Task { [weak self] in
      for await line in stderrLines {
        await self?.noteStderr(line)
      }
    }
    return Self.lineStream(from: stdout.fileHandleForReading)
  }

  /// Drain each readiness notification through EOF or EAGAIN. Corelibs FileHandle's
  /// readabilityHandler can omit a final EOF callback after delivering the last bytes.
  /// Nonblocking reads on a serial queue also keep idle servers off cooperative executors.
  private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
      let buffer = LineBuffer()
      do {
        let reader = try ProcessPipeReader(handle: handle, onData: { chunk in
          for line in buffer.split(appending: chunk) { continuation.yield(line) }
        }, onEOF: { continuation.finish() })
        continuation.onTermination = { @Sendable _ in reader.stop() }
      } catch {
        continuation.finish()
      }
    }
  }

  /// Accumulates pipe chunks and emits complete lines. Only touched from the pipe's
  /// serial handler queue, hence the unchecked conformance.
  private final class LineBuffer: @unchecked Sendable {
    private var data = Data()

    func split(appending chunk: Data) -> [String] {
      data.append(chunk)
      var lines: [String] = []
      while let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
        var lineData = data[data.startIndex..<newline]
        if lineData.last == UInt8(ascii: "\r") {
          lineData = lineData.dropLast()
        }
        lines.append(String(decoding: lineData, as: UTF8.self))
        data.removeSubrange(data.startIndex...newline)
      }
      return lines
    }
  }

  public func send(_ line: String) async throws {
    guard let stdinHandle, process?.isRunning == true else {
      throw MCPError.notConnected(server: name)
    }
    try stdinHandle.write(contentsOf: Data((line + "\n").utf8))
  }

  public func stop() async {
    if let stopTask { await stopTask.value; return }
    let task = Task { await self.stopProcess() }
    stopTask = task
    await task.value
    stopTask = nil
  }

  private func stopProcess() async {
    stderrTask?.cancel()
    // EOF can make a wrapper exit and orphan its children. Snapshot them before closing
    // stdin, while the ancestry still exists, even if the wrapper exits before kill().
    let descendants = process.map { ShellRunner.ProcessTree.descendants(of: $0.processIdentifier) } ?? []
    try? stdinHandle?.close()
    if let process {
      let box = ShellRunner.ProcessBox(process: process)
      box.kill()
      for _ in 0..<100 where box.isRunning {
        do { try await Task.sleep(nanoseconds: 20_000_000) } catch { break }
      }
      // A server wrapper may exit before a child that ignored SIGTERM. Preserve the
      // original identity-checked descendant snapshot for the final cleanup pass.
      box.forceKill(snapshot: descendants)
    }
    process = nil
    stdinHandle = nil
  }

  /// The last stderr output — the only clue when a server dies during the handshake.
  public func recentStderr() -> String {
    stderrTail
  }

  private func noteStderr(_ line: String) {
    stderrTail = String((stderrTail + "\n" + line).suffix(2000))
  }
}

// MARK: - MCPToolInfo

/// A tool as advertised by `tools/list`.
public struct MCPToolInfo: Codable, Sendable {
  public struct Annotations: Codable, Sendable {
    public var title: String?
    public var readOnlyHint: Bool?
    /// The server's own hint that a non-read-only tool may perform destructive,
    /// irreversible updates (MCP `destructiveHint`, default true in the spec).
    public var destructiveHint: Bool?
    /// The tool may reach the open world (network, other systems) — MCP `openWorldHint`.
    public var openWorldHint: Bool?

    public init(
      title: String? = nil,
      readOnlyHint: Bool? = nil,
      destructiveHint: Bool? = nil,
      openWorldHint: Bool? = nil)
    {
      self.title = title
      self.readOnlyHint = readOnlyHint
      self.destructiveHint = destructiveHint
      self.openWorldHint = openWorldHint
    }
  }

  public var name: String
  public var description: String?
  public var inputSchema: JSONValue?
  public var annotations: Annotations?

  public init(
    name: String,
    description: String? = nil,
    inputSchema: JSONValue? = nil,
    annotations: Annotations? = nil)
  {
    self.name = name
    self.description = description
    self.inputSchema = inputSchema
    self.annotations = annotations
  }

  /// SHA-256 of the definition's canonical JSON — `{name, description, inputSchema,
  /// annotations}`, sorted keys, no whitespace, nulls omitted. What `MCPToolPins` records at
  /// first sight and checks on every later connect: a server that rewrites a tool's description
  /// (the model's instructions for it) after the user saw it changes the hash, and the tool is
  /// withheld until `arnes mcp --approve <server>`.
  public var fingerprint: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = (try? encoder.encode(self)) ?? Data(name.utf8)
    return HookHash.sha256Hex(data)
  }
}

// MARK: - MCPToolPins

/// Where a server's tool fingerprints are remembered between runs (`ProjectTrustStore` conforms;
/// the file stays out of MCP.swift). `pinned` is what was recorded for a server — remote tool
/// name → `MCPToolInfo.fingerprint` — and `pin` replaces it.
public protocol MCPToolPins: Sendable {
  func pinned(for server: String) -> [String: String]
  func pin(_ hashes: [String: String], for server: String) throws
}

// MARK: - MCPPromptInfo

/// A prompt as advertised by `prompts/list` — a server-authored message template the
/// user runs as a turn (`/mcp__<server>__<prompt>` in the REPL).
public struct MCPPromptInfo: Codable, Sendable {
  public struct Argument: Codable, Sendable {
    public var name: String
    public var description: String?
    public var required: Bool?

    public init(name: String, description: String? = nil, required: Bool? = nil) {
      self.name = name
      self.description = description
      self.required = required
    }
  }

  public var name: String
  public var description: String?
  public var arguments: [Argument]?

  public init(name: String, description: String? = nil, arguments: [Argument]? = nil) {
    self.name = name
    self.description = description
    self.arguments = arguments
  }
}

// MARK: - MCPClient

/// A minimal MCP client: initialize handshake, `tools/list`, `tools/call`, and
/// `prompts/list`/`prompts/get` when the server advertises prompts. Requests are
/// correlated by id; server pings are answered so long-lived servers stay happy.
/// Resources, sampling, and elicitation stay out of scope.
public actor MCPClient {
  public let serverName: String

  private let transport: any MCPTransport
  private let requestTimeout: TimeInterval
  private let callTimeout: TimeInterval
  private let maxResultChars: Int?
  private var nextId = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var readerTask: Task<Void, Never>?
  private var closed = false
  /// The server's `initialize` capabilities — what it's worth asking for at all.
  private var capabilities: JSONValue = .object([:])

  private static let protocolVersion = "2025-06-18"
  /// Tool executions get longer than handshake calls — MCP tools can do real work.
  public static let defaultCallTimeout: TimeInterval = 120

  /// - Parameters:
  ///   - requestTimeout: the handshake/list budget (`startupTimeoutSeconds`).
  ///   - callTimeout: the `tools/call` budget (`toolTimeoutSeconds`).
  ///   - maxResultChars: the server's explicit inner bound (`MCPServerConfig.maxResultChars`);
  ///     nil hands results to the session whole, where the universal cap and spill apply.
  public init(
    serverName: String,
    transport: any MCPTransport,
    requestTimeout: TimeInterval = 30,
    callTimeout: TimeInterval = MCPClient.defaultCallTimeout,
    maxResultChars: Int? = nil)
  {
    self.serverName = serverName
    self.transport = transport
    self.requestTimeout = requestTimeout
    self.callTimeout = callTimeout
    self.maxResultChars = maxResultChars
  }

  /// Starts the transport and performs the initialize handshake.
  public func connect() async throws {
    let lines = try await transport.start()
    readerTask = Task { [weak self] in
      for await line in lines {
        await self?.handle(line: line)
      }
      await self?.connectionClosed()
    }
    let result = try await request(
      method: "initialize",
      params: [
        "protocolVersion": .string(Self.protocolVersion),
        "capabilities": [:],
        "clientInfo": ["name": "arnes", "version": "0.2"],
      ])
    capabilities = result["capabilities"] ?? .object([:])
    try await send(message: ["jsonrpc": "2.0", "method": "notifications/initialized"])
  }

  /// Whether the server said it serves prompts (asking otherwise just earns an error).
  public var servesPrompts: Bool {
    capabilities["prompts"] != nil
  }

  public func close() async {
    closed = true
    readerTask?.cancel()
    await transport.stop()
    failAllPending(with: MCPError.disconnected(server: serverName))
  }

  /// All tools the server advertises, following `nextCursor` pagination.
  public func listTools() async throws -> [MCPToolInfo] {
    var tools: [MCPToolInfo] = []
    var cursor: String?
    repeat {
      let result = try await request(
        method: "tools/list",
        params: cursor.map { ["cursor": .string($0)] })
      let page: ToolsPage = try Self.reify(result)
      tools += page.tools
      cursor = page.nextCursor
    } while cursor != nil
    return tools
  }

  /// Executes one tool and renders the result the way `AgentTool` expects: plain text
  /// for the model, `error:`-prefixed when the server flags a failure. The session's
  /// `ToolOutputLimiter` caps and spills the result like any other tool's; an explicit
  /// per-server `maxResultChars` is applied first, as an inner bound.
  public func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> String {
    let result = try await request(
      method: "tools/call",
      params: ["name": .string(name), "arguments": .object(arguments)],
      timeout: callTimeout)
    let call: CallResult = try Self.reify(result)
    var parts: [String] = []
    for item in call.content ?? [] {
      if let text = item.text {
        parts.append(text)
      } else if let type = item.type {
        parts.append("[\(type) content omitted]")
      }
    }
    if parts.isEmpty, let structured = call.structuredContent,
       let data = try? Self.encoder.encode(structured)
    {
      parts.append(String(decoding: data, as: UTF8.self))
    }
    let rendered = Self.bounded(parts.joined(separator: "\n"), to: maxResultChars)
    return call.isError == true ? "error: \(rendered)" : rendered
  }

  /// The explicit per-server bound: head 60 % + tail 40 % with the gap named — the shape the
  /// session's cap uses, so a result cut here still keeps its ending. nil = unchanged.
  static func bounded(_ text: String, to limit: Int?) -> String {
    guard let limit, text.count > limit else { return text }
    let headChars = limit * 6 / 10
    let tailChars = limit - headChars
    let omitted = text.count - headChars - tailChars
    return String(text.prefix(headChars))
      + "\n[… \(omitted) chars omitted by the server's maxResultChars …]\n"
      + String(text.suffix(tailChars))
  }

  // MARK: Prompts

  /// Every prompt the server advertises, following `nextCursor`. Empty when the server
  /// never claimed the prompts capability.
  public func listPrompts() async throws -> [MCPPromptInfo] {
    guard servesPrompts else { return [] }
    var prompts: [MCPPromptInfo] = []
    var cursor: String?
    repeat {
      let result = try await request(
        method: "prompts/list",
        params: cursor.map { ["cursor": .string($0)] })
      let page: PromptsPage = try Self.reify(result)
      prompts += page.prompts
      cursor = page.nextCursor
    } while cursor != nil
    return prompts
  }

  /// One prompt rendered as plain text: each message's text content, prefixed with the
  /// role when the server used more than the plain `user` voice.
  public func getPrompt(_ name: String, arguments: [String: String] = [:]) async throws -> String {
    var params: [String: JSONValue] = ["name": .string(name)]
    if !arguments.isEmpty {
      params["arguments"] = .object(arguments.mapValues { .string($0) })
    }
    let result = try await request(method: "prompts/get", params: .object(params))
    let payload: PromptResult = try Self.reify(result)
    var lines: [String] = []
    for message in payload.messages ?? [] {
      guard let text = message.content?.text, !text.isEmpty else { continue }
      let role = message.role ?? "user"
      lines.append(role == "user" ? text : "\(role): \(text)")
    }
    return lines.joined(separator: "\n\n")
  }

  // MARK: Wire shapes

  private struct ToolsPage: Decodable {
    let tools: [MCPToolInfo]
    let nextCursor: String?
  }

  private struct PromptsPage: Decodable {
    let prompts: [MCPPromptInfo]
    let nextCursor: String?
  }

  private struct PromptResult: Decodable {
    struct Message: Decodable {
      struct Content: Decodable {
        let type: String?
        let text: String?
      }

      let role: String?
      let content: Content?
    }

    let description: String?
    let messages: [Message]?
  }

  private struct CallResult: Decodable {
    struct ContentItem: Decodable {
      let type: String?
      let text: String?
    }

    let content: [ContentItem]?
    let isError: Bool?
    let structuredContent: JSONValue?
  }

  // MARK: JSON-RPC plumbing

  private static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    return encoder
  }()

  private func request(
    method: String,
    params: JSONValue? = nil,
    timeout: TimeInterval? = nil)
    async throws -> JSONValue
  {
    guard !closed else { throw MCPError.disconnected(server: serverName) }
    let id = nextId
    nextId += 1
    var message: [String: JSONValue] = [
      "jsonrpc": "2.0",
      "id": .int(id),
      "method": .string(method),
    ]
    if let params {
      message["params"] = params
    }
    let deadline = timeout ?? requestTimeout
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      Task {
        do {
          try await self.send(message: message)
        } catch {
          self.fail(id: id, with: error)
        }
      }
      Task {
        try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
        await self.fail(id: id, with: MCPError.timedOut(method: method, seconds: deadline))
      }
    }
  }

  private func send(message: [String: JSONValue]) async throws {
    let data = try Self.encoder.encode(JSONValue.object(message))
    try await transport.send(String(decoding: data, as: UTF8.self))
  }

  private func handle(line: String) async {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
      return // non-JSON noise on stdout (a misbehaving server logging there)
    }
    if let id = value["id"]?.intValue, value["result"] != nil || value["error"] != nil {
      guard let continuation = pending.removeValue(forKey: id) else { return }
      if let error = value["error"] {
        let message = error["message"]?.stringValue ?? "unknown error"
        continuation.resume(throwing: MCPError.server(message))
      } else {
        continuation.resume(returning: value["result"] ?? .null)
      }
      return
    }
    // Server-initiated request: answer pings; ignore everything else (notifications,
    // sampling requests we don't support).
    if value["method"]?.stringValue == "ping", let id = value["id"] {
      try? await send(message: ["jsonrpc": "2.0", "id": id, "result": [:]])
    }
  }

  private func fail(id: Int, with error: Error) {
    pending.removeValue(forKey: id)?.resume(throwing: error)
  }

  private func failAllPending(with error: Error) {
    for continuation in pending.values {
      continuation.resume(throwing: error)
    }
    pending.removeAll()
  }

  private func connectionClosed() {
    closed = true
    failAllPending(with: MCPError.disconnected(server: serverName))
  }

  /// Re-decodes a lenient `JSONValue` into a typed wire shape.
  private static func reify<T: Decodable>(_ value: JSONValue) throws -> T {
    try JSONDecoder().decode(T.self, from: encoder.encode(value))
  }
}

// MARK: - MCPTool

/// An MCP server tool bridged into the agent loop. Names are namespaced
/// `mcp__<server>__<tool>` so servers can't collide with the built-ins or each other,
/// and the schema is the server's own `inputSchema`, passed through untouched.
/// `.mutating` unless the server annotates `readOnlyHint` — untrusted-by-default, so
/// every MCP call goes through the permission gate like `bash` does. A tool the server
/// marks destructive or open-world is `.sensitive` instead: the louder prompt, never
/// covered by "always allow this session".
public struct MCPTool: AgentTool, TaintingTool {
  public let name: String
  public let description: String
  public let parameters: JSONValue
  public let permission: ToolPermission
  /// The tool's name on the server (un-namespaced), for display and the wire call.
  public let remoteName: String
  /// The configured server name this tool belongs to.
  public let server: String
  /// The server was configured `trust: untrusted`: every result taints the session.
  public let taintsResults: Bool
  /// `MCPToolInfo.fingerprint` of the definition this tool was built from.
  public let fingerprint: String

  private let client: MCPClient

  /// - Parameter trusted: false for a `trust: untrusted` server — `readOnlyHint` is then ignored
  ///   and results taint. Default true: today's behavior.
  public init(serverName: String, info: MCPToolInfo, client: MCPClient, trusted: Bool = true) {
    server = serverName
    remoteName = info.name
    name = Self.sanitize("mcp__\(serverName)__\(info.name)")
    description = info.description ?? "Tool \(info.name) from MCP server \(serverName)."
    parameters = info.inputSchema ?? ["type": "object", "properties": [:]]
    permission = Self.tier(for: info.annotations, trusted: trusted)
    taintsResults = !trusted
    fingerprint = info.fingerprint
    self.client = client
  }

  /// How the taint names this tool's source.
  public var taintSource: String { "mcp:\(server)" }

  /// read-only → `.readOnly`; a tool the server flags as destructive or open-world →
  /// `.sensitive` (louder prompt, never "always"); anything else → `.mutating`.
  static func tier(for annotations: MCPToolInfo.Annotations?) -> ToolPermission {
    tier(for: annotations, trusted: true)
  }

  /// The same, for a server whose word isn't taken: an untrusted server's `readOnlyHint` lifts
  /// nothing (its "read-only" tool prompts like a mutation), while its destructive/open-world
  /// hints still count — a hint that tightens is honored, one that loosens is not.
  static func tier(for annotations: MCPToolInfo.Annotations?, trusted: Bool) -> ToolPermission {
    if trusted, annotations?.readOnlyHint == true { return .readOnly }
    if annotations?.destructiveHint == true || annotations?.openWorldHint == true { return .sensitive }
    return .mutating
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    let rendered = arguments
      .sorted { $0.key < $1.key }
      .compactMap { key, value in value.stringValue.map { "\(key): \($0)" } }
      .joined(separator: ", ")
    return "mcp \(server):\(remoteName) \(String(rendered.prefix(120)))"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    try await client.callTool(remoteName, arguments: arguments)
  }

  /// Tool names must satisfy the providers' `[a-zA-Z0-9_-]{1,64}` pattern.
  private static func sanitize(_ raw: String) -> String {
    let mapped = raw.map { character -> Character in
      character.isLetter || character.isNumber || character == "_" || character == "-"
        ? character
        : "_"
    }
    return String(String(mapped).prefix(64))
  }
}

// MARK: - MCPPrompt

/// A server prompt bridged into the REPL as `/mcp__<server>__<prompt>`. Not a tool: the
/// *user* invokes it, the model never sees it, and running it just sends the rendered
/// text as a turn.
public struct MCPPrompt: Sendable {
  public let server: String
  public let info: MCPPromptInfo
  /// `mcp__<server>__<prompt>` — what the user types after the slash.
  public let slashName: String

  private let client: MCPClient

  public init(server: String, info: MCPPromptInfo, client: MCPClient) {
    self.server = server
    self.info = info
    slashName = "mcp__\(server)__\(info.name)"
    self.client = client
  }

  /// Fetches the prompt with the user's words mapped onto its declared arguments,
  /// positionally: one word each, and the last declared argument takes the rest of the
  /// line (so a trailing free-text argument works). A prompt with no declared arguments
  /// gets none.
  public func render(arguments line: String) async throws -> String {
    try await client.getPrompt(info.name, arguments: Self.map(line, onto: info.arguments ?? []))
  }

  static func map(_ line: String, onto declared: [MCPPromptInfo.Argument]) -> [String: String] {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !declared.isEmpty, !trimmed.isEmpty else { return [:] }
    var remaining = Substring(trimmed)
    var mapped: [String: String] = [:]
    for (index, argument) in declared.enumerated() {
      if remaining.isEmpty { break }
      if index == declared.count - 1 {
        mapped[argument.name] = String(remaining)
        break
      }
      let split = remaining.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard let word = split.first else { break }
      mapped[argument.name] = String(word)
      remaining = split.count > 1 ? split[1] : ""
    }
    return mapped
  }
}

// MARK: - MCPToolProvider

/// Connects the configured MCP servers and bridges their tools into `[any AgentTool]`.
/// Owns the clients so the CLI can shut the server processes down on exit.
public actor MCPToolProvider {
  /// One server's connection outcome, for the CLI to report.
  public struct ServerStatus: Sendable {
    public let server: String
    public let toolCount: Int
    public let promptCount: Int
    /// nil when the server connected and listed tools cleanly.
    public let error: String?
    /// The entry said `required: true` — a failure here stops a headless run.
    public let required: Bool
    /// The entry said `enabled: false`; nothing was connected.
    public let disabled: Bool
    /// `stdio <command…>` or `http <host>` — never a header value, never a URL path.
    public let transport: String
    /// Remote tool names whose definition changed since the pins first saw them: not built into
    /// a tool, not offered to the model, until `arnes mcp --approve <server>` re-pins them.
    public let withheldTools: [String]
    /// The first 80 characters of a withheld tool's *new* description, by remote name — what the
    /// user is asked to read before approving (the pin is a hash; the old text isn't kept).
    public let withheldDescriptions: [String: String]
    /// In approve mode: the tools whose pin was written afresh — `name (new)` for one never seen,
    /// `name (changed)` for one whose definition moved.
    public let repinnedTools: [String]
    /// The entry said `trust: "untrusted"` (a repository's `.mcp.json` entry always does): every
    /// result taints the session and `readOnlyHint` is ignored. X9: what `/mcp` tags.
    public let untrusted: Bool

    /// Public so a CLI formatter's tests can build a status without a server (X9); the provider
    /// is still the only writer in a run.
    public init(
      server: String,
      toolCount: Int = 0,
      promptCount: Int = 0,
      error: String? = nil,
      required: Bool = false,
      disabled: Bool = false,
      transport: String = "",
      withheldTools: [String] = [],
      withheldDescriptions: [String: String] = [:],
      repinnedTools: [String] = [],
      untrusted: Bool = false)
    {
      self.server = server
      self.toolCount = toolCount
      self.promptCount = promptCount
      self.error = error
      self.required = required
      self.disabled = disabled
      self.transport = transport
      self.withheldTools = withheldTools
      self.withheldDescriptions = withheldDescriptions
      self.repinnedTools = repinnedTools
      self.untrusted = untrusted
    }

    /// The one line a run prints when tools were withheld; nil otherwise.
    public var withheldNotice: String? {
      guard !withheldTools.isEmpty else { return nil }
      let n = withheldTools.count
      return "mcp server \(server): \(n) tool\(n == 1 ? "" : "s") changed since first seen and "
        + "\(n == 1 ? "was" : "were") withheld — run `arnes mcp --approve \(server)` after reading the new "
        + "descriptions"
    }
  }

  private let transportFactory: @Sendable (String, MCPServerConfig) throws -> any MCPTransport
  private var clients: [MCPClient] = []
  /// Prompts every connected server advertises, for the REPL's slash fallthrough.
  public private(set) var prompts: [MCPPrompt] = []

  /// - Parameters:
  ///   - redactingEnvironment: variables withheld from server processes (the default
  ///     list plus whatever the caller adds — the CLI adds the active provider's token).
  ///   - transportFactory: test seam; the default picks stdio or HTTP per entry.
  public init(
    redactingEnvironment redacted: Set<String> = ProcessMCPTransport.defaultRedactedEnvironmentKeys,
    transportFactory: (@Sendable (String, MCPServerConfig) throws -> any MCPTransport)? = nil)
  {
    self.transportFactory = transportFactory ?? { name, config in
      switch config.transport {
      case .stdio:
        return ProcessMCPTransport(name: name, config: config, redactingEnvironment: redacted)
      case .http:
        return try HTTPMCPTransport(name: name, config: config)
      }
    }
  }

  /// Connects every enabled server in parallel (npx-style servers take seconds to boot).
  /// A server that fails to connect or list tools becomes a `ServerStatus` error; the
  /// others still contribute their tools. `requestTimeout` is the startup budget for
  /// entries that don't set `startupTimeoutSeconds`.
  ///
  /// **Pinning** (`pins` non-nil): each tool's `MCPToolInfo.fingerprint` is compared with what
  /// the pins recorded for the server. A tool never seen is pinned now — first sight is the
  /// user's approval, so the first run is untouched; one whose definition changed is **withheld**
  /// (not built, listed on `ServerStatus.withheldTools` with the notice) until the user re-pins
  /// it; an unchanged one is served. A server named in `approving` is re-pinned wholesale — every
  /// tool kept, its current definitions recorded, the changed and new ones listed on
  /// `repinnedTools` (`arnes mcp --approve`). `pins == nil` pins nothing (embedders, tests).
  public func connect(
    config: MCPConfig,
    requestTimeout: TimeInterval = 30,
    pins: (any MCPToolPins)? = nil,
    approving: Set<String> = [])
    async -> (tools: [any AgentTool], statuses: [ServerStatus])
  {
    let factory = transportFactory
    let outcomes = await withTaskGroup(
      of: (String, MCPServerConfig, Result<(MCPClient, [MCPToolInfo], [MCPPromptInfo]), Error>).self)
    { group in
      for (name, serverConfig) in config.mcpServers where serverConfig.isEnabled {
        group.addTask {
          do {
            let client = MCPClient(
              serverName: name,
              transport: try factory(name, serverConfig),
              requestTimeout: serverConfig.startupTimeoutSeconds == nil
                ? requestTimeout
                : serverConfig.startupTimeout,
              callTimeout: serverConfig.toolTimeout,
              maxResultChars: serverConfig.resultCharLimit)
            do {
              try await client.connect()
              let tools = try await client.listTools()
              // Prompts are optional and never fatal: a server that advertises them but
              // fumbles the list still contributes its tools.
              let prompts = (try? await client.listPrompts()) ?? []
              return (name, serverConfig, .success((client, tools, prompts)))
            } catch {
              await client.close()
              return (name, serverConfig, .failure(error))
            }
          } catch {
            return (name, serverConfig, .failure(error))
          }
        }
      }
      var results: [(String, MCPServerConfig, Result<(MCPClient, [MCPToolInfo], [MCPPromptInfo]), Error>)] = []
      for await outcome in group {
        results.append(outcome)
      }
      return results
    }

    var tools: [any AgentTool] = []
    var statuses: [ServerStatus] = []
    for (name, entry) in config.mcpServers.sorted(by: { $0.key < $1.key }) where !entry.isEnabled {
      statuses.append(ServerStatus(
        server: name, required: entry.isRequired, disabled: true, transport: entry.transportSummary,
        untrusted: entry.isUntrusted))
    }
    for (name, entry, outcome) in outcomes.sorted(by: { $0.0 < $1.0 }) {
      switch outcome {
      case .success(let (client, infos, promptInfos)):
        clients.append(client)
        let checked = Self.check(infos, server: name, pins: pins, approving: approving.contains(name))
        tools += checked.served.map {
          MCPTool(serverName: name, info: $0, client: client, trusted: !entry.isUntrusted)
        }
        prompts += promptInfos.map { MCPPrompt(server: name, info: $0, client: client) }
        statuses.append(ServerStatus(
          server: name,
          toolCount: checked.served.count,
          promptCount: promptInfos.count,
          required: entry.isRequired,
          transport: entry.transportSummary,
          withheldTools: checked.withheld,
          withheldDescriptions: checked.withheldDescriptions,
          repinnedTools: checked.repinned,
          untrusted: entry.isUntrusted))
      case .failure(let error):
        statuses.append(ServerStatus(
          server: name,
          error: "\(error)",
          required: entry.isRequired,
          transport: entry.transportSummary,
          untrusted: entry.isUntrusted))
      }
    }
    statuses.sort { $0.server < $1.server }
    return (tools, statuses)
  }

  public func shutdown() async {
    for client in clients {
      await client.close()
    }
    clients.removeAll()
    prompts.removeAll()
  }

  /// What the pins made of one server's tool list.
  struct Checked {
    var served: [MCPToolInfo]
    var withheld: [String] = []
    var withheldDescriptions: [String: String] = [:]
    var repinned: [String] = []
  }

  /// The pinning rule, pure over the listed tools and the recorded hashes. Without pins every
  /// tool is served and nothing is recorded.
  static func check(
    _ infos: [MCPToolInfo], server: String, pins: (any MCPToolPins)?, approving: Bool)
    -> Checked
  {
    guard let pins else { return Checked(served: infos) }
    let recorded = pins.pinned(for: server)
    // Approving starts from nothing: a tool the server no longer lists drops out of the pins.
    var next: [String: String] = approving ? [:] : recorded
    var checked = Checked(served: [])
    for info in infos {
      let hash = info.fingerprint
      if approving {
        next[info.name] = hash
        if recorded[info.name] != hash {
          checked.repinned.append("\(info.name) (\(recorded[info.name] == nil ? "new" : "changed"))")
        }
        checked.served.append(info)
      } else if let old = recorded[info.name] {
        if old == hash {
          checked.served.append(info)
        } else {
          checked.withheld.append(info.name)
          checked.withheldDescriptions[info.name] = String((info.description ?? "").prefix(80))
        }
      } else {
        next[info.name] = hash
        checked.served.append(info)
      }
    }
    // A pin that couldn't be written costs a re-check next run, never a served changed tool.
    if next != recorded { try? pins.pin(next, for: server) }
    return checked
  }
}
