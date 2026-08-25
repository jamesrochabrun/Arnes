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

  public var description: String {
    switch self {
    case .notConnected(let server): return "mcp server \(server) is not connected"
    case .disconnected(let server): return "mcp server \(server) disconnected"
    case .server(let message): return "mcp server error: \(message)"
    case .timedOut(let method, let seconds):
      return "mcp request \(method) timed out after \(Int(seconds))s"
    }
  }
}

// MARK: - MCPConfig

/// One server entry in `~/.arnes/mcp.json`. Only stdio servers for now: arnes launches
/// `command` (resolved via PATH) and speaks JSON-RPC over its stdin/stdout.
public struct MCPServerConfig: Codable, Sendable {
  public var command: String
  public var args: [String]?
  /// Extra environment merged over the inherited process environment.
  public var env: [String: String]?

  public init(command: String, args: [String]? = nil, env: [String: String]? = nil) {
    self.command = command
    self.args = args
    self.env = env
  }
}

/// The MCP config file, mirroring the `mcpServers` shape used by Claude Desktop and
/// Claude Code so existing configs can be copied verbatim.
public struct MCPConfig: Codable, Sendable {
  public var mcpServers: [String: MCPServerConfig]

  public init(mcpServers: [String: MCPServerConfig]) {
    self.mcpServers = mcpServers
  }

  /// `~/.arnes/mcp.json`, or the `ARNES_MCP_CONFIG` env override (per-project configs).
  public static var defaultURL: URL {
    if let override = ProcessInfo.processInfo.environment["ARNES_MCP_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/mcp.json")
  }

  /// Loads the config, or nil when the file doesn't exist (MCP is opt-in by presence).
  public static func load(from url: URL = defaultURL) throws -> MCPConfig? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(MCPConfig.self, from: Data(contentsOf: url))
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
public actor ProcessMCPTransport: MCPTransport {
  private let name: String
  private let config: MCPServerConfig
  private var process: Process?
  private var stdinHandle: FileHandle?
  private var stderrTask: Task<Void, Never>?
  /// Tail of the server's stderr, surfaced when startup fails.
  private var stderrTail = ""

  public init(name: String, config: MCPServerConfig) {
    self.name = name
    self.config = config
  }

  public func start() async throws -> AsyncStream<String> {
    let process = Process()
    // `env` resolves the command via PATH — configs say "npx", not an absolute path.
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [config.command] + (config.args ?? [])
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in config.env ?? [:] {
      environment[key] = value
    }
    process.environment = environment

    let stdin = Pipe()
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()
    self.process = process
    stdinHandle = stdin.fileHandleForWriting

    // Deliberately not `FileHandle.bytes.lines`: AsyncBytes funnels every handle
    // through one shared IO actor with blocking reads, so a second reader (another
    // server, or just this server's idle stderr) starves the first one forever.
    let stderrLines = Self.lineStream(from: stderr.fileHandleForReading)
    stderrTask = Task { [weak self] in
      for await line in stderrLines {
        await self?.noteStderr(line)
      }
    }
    return Self.lineStream(from: stdout.fileHandleForReading)
  }

  /// Newline-framed text from a pipe, fed by `readabilityHandler` callbacks (which run
  /// on a plain dispatch queue and can't starve any actor). Finishes on EOF.
  private static func lineStream(from handle: FileHandle) -> AsyncStream<String> {
    AsyncStream { continuation in
      let buffer = LineBuffer()
      handle.readabilityHandler = { handle in
        let chunk = handle.availableData
        guard !chunk.isEmpty else {
          handle.readabilityHandler = nil
          continuation.finish()
          return
        }
        for line in buffer.split(appending: chunk) {
          continuation.yield(line)
        }
      }
      continuation.onTermination = { @Sendable _ in
        handle.readabilityHandler = nil
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
    stderrTask?.cancel()
    try? stdinHandle?.close()
    if let process, process.isRunning {
      process.terminate()
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

    public init(title: String? = nil, readOnlyHint: Bool? = nil) {
      self.title = title
      self.readOnlyHint = readOnlyHint
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
}

// MARK: - MCPClient

/// A minimal MCP client: initialize handshake, `tools/list`, `tools/call`. Requests are
/// correlated by id; server pings are answered so long-lived servers stay happy. Every
/// other server capability (resources, prompts, sampling) is deliberately out of scope —
/// arnes consumes tools only.
public actor MCPClient {
  public let serverName: String

  private let transport: any MCPTransport
  private let requestTimeout: TimeInterval
  private var nextId = 1
  private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
  private var readerTask: Task<Void, Never>?
  private var closed = false

  private static let protocolVersion = "2025-06-18"
  /// Tool executions get longer than handshake calls — MCP tools can do real work.
  private static let callTimeout: TimeInterval = 120

  public init(serverName: String, transport: any MCPTransport, requestTimeout: TimeInterval = 30) {
    self.serverName = serverName
    self.transport = transport
    self.requestTimeout = requestTimeout
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
    _ = try await request(
      method: "initialize",
      params: [
        "protocolVersion": .string(Self.protocolVersion),
        "capabilities": [:],
        "clientInfo": ["name": "arnes", "version": "0.2"],
      ])
    try await send(message: ["jsonrpc": "2.0", "method": "notifications/initialized"])
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
  /// for the model, `error:`-prefixed when the server flags a failure.
  public func callTool(_ name: String, arguments: [String: JSONValue]) async throws -> String {
    let result = try await request(
      method: "tools/call",
      params: ["name": .string(name), "arguments": .object(arguments)],
      timeout: max(requestTimeout, Self.callTimeout))
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
    let text = parts.joined(separator: "\n")
    let truncated = text.count > 20000 ? String(text.prefix(20000)) + "\n[truncated]" : text
    return call.isError == true ? "error: \(truncated)" : truncated
  }

  // MARK: Wire shapes

  private struct ToolsPage: Decodable {
    let tools: [MCPToolInfo]
    let nextCursor: String?
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
/// every MCP call goes through the permission gate like `bash` does.
public struct MCPTool: AgentTool {
  public let name: String
  public let description: String
  public let parameters: JSONValue
  public let permission: ToolPermission
  /// The tool's name on the server (un-namespaced), for display and the wire call.
  public let remoteName: String
  /// The configured server name this tool belongs to.
  public let server: String

  private let client: MCPClient

  public init(serverName: String, info: MCPToolInfo, client: MCPClient) {
    server = serverName
    remoteName = info.name
    name = Self.sanitize("mcp__\(serverName)__\(info.name)")
    description = info.description ?? "Tool \(info.name) from MCP server \(serverName)."
    parameters = info.inputSchema ?? ["type": "object", "properties": [:]]
    permission = info.annotations?.readOnlyHint == true ? .readOnly : .mutating
    self.client = client
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

// MARK: - MCPToolProvider

/// Connects the configured MCP servers and bridges their tools into `[any AgentTool]`.
/// Owns the clients so the CLI can shut the server processes down on exit.
public actor MCPToolProvider {
  /// One server's connection outcome, for the CLI to report.
  public struct ServerStatus: Sendable {
    public let server: String
    public let toolCount: Int
    /// nil when the server connected and listed tools cleanly.
    public let error: String?
  }

  private let transportFactory: @Sendable (String, MCPServerConfig) -> any MCPTransport
  private var clients: [MCPClient] = []

  public init(
    transportFactory: @escaping @Sendable (String, MCPServerConfig) -> any MCPTransport = {
      ProcessMCPTransport(name: $0, config: $1)
    })
  {
    self.transportFactory = transportFactory
  }

  /// Connects every configured server in parallel (npx-style servers take seconds to
  /// boot). A server that fails to connect or list tools becomes a `ServerStatus` error;
  /// the others still contribute their tools.
  public func connect(
    config: MCPConfig,
    requestTimeout: TimeInterval = 30)
    async -> (tools: [any AgentTool], statuses: [ServerStatus])
  {
    let factory = transportFactory
    let outcomes = await withTaskGroup(
      of: (String, Result<(MCPClient, [MCPToolInfo]), Error>).self)
    { group in
      for (name, serverConfig) in config.mcpServers {
        group.addTask {
          let client = MCPClient(
            serverName: name,
            transport: factory(name, serverConfig),
            requestTimeout: requestTimeout)
          do {
            try await client.connect()
            return (name, .success((client, try await client.listTools())))
          } catch {
            await client.close()
            return (name, .failure(error))
          }
        }
      }
      var results: [(String, Result<(MCPClient, [MCPToolInfo]), Error>)] = []
      for await outcome in group {
        results.append(outcome)
      }
      return results
    }

    var tools: [any AgentTool] = []
    var statuses: [ServerStatus] = []
    for (name, outcome) in outcomes.sorted(by: { $0.0 < $1.0 }) {
      switch outcome {
      case .success(let (client, infos)):
        clients.append(client)
        tools += infos.map { MCPTool(serverName: name, info: $0, client: client) }
        statuses.append(ServerStatus(server: name, toolCount: infos.count, error: nil))
      case .failure(let error):
        statuses.append(ServerStatus(server: name, toolCount: 0, error: "\(error)"))
      }
    }
    return (tools, statuses)
  }

  public func shutdown() async {
    for client in clients {
      await client.close()
    }
    clients.removeAll()
  }
}
