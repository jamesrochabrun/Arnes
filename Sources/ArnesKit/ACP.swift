import Foundation
import OpenRouterSwift

/// ACP v1's baseline stdio MCP descriptor. The connection validates it; the session factory
/// owns startup policy and cleanup. Remote HTTP/SSE transports are not advertised.
public struct ACPMCPServer: Decodable, Sendable {
  public struct Variable: Decodable, Sendable {
    public let name: String
    public let value: String
  }
  public let name: String
  public let command: String
  public let args: [String]
  public let env: [Variable]
  public let type: String?

  public var configuration: MCPServerConfig {
    MCPServerConfig(type: "stdio", command: command, args: args,
      env: Dictionary(env.map { ($0.name, $0.value) }, uniquingKeysWith: { _, last in last }),
      required: true, trust: "untrusted")
  }
}

/// A Session and the external resources belonging to it (for example its MCP connections).
/// No second agent loop: ACP forwards prompts to Session.send and records remain Session's.
public struct ACPSession: Sendable {
  public let session: Session
  public let cleanup: @Sendable () async -> Void

  public init(session: Session, cleanup: @escaping @Sendable () async -> Void = {}) {
    self.session = session
    self.cleanup = cleanup
  }
}

public struct ACPError: Error, Sendable, CustomStringConvertible {
  public let code: Int
  public let description: String
  public init(code: Int = -32602, message: String) {
    self.code = code
    description = message
  }
}

/// An ACP connection, independent of terminals or any UI. `receive` accepts one decoded
/// JSON-RPC message and returns promptly: long-running requests live in tracked tasks so
/// permission replies, cancellation and other sessions can still be serviced.
public actor ACPConnection {
  public typealias Factory = @Sendable (
    _ id: String, _ directory: URL, _ servers: [ACPMCPServer], _ permissions: any PermissionDelegate
  ) async throws -> ACPSession
  public typealias Output = @Sendable (JSONValue) async throws -> Void
  public static let maximumMessageBytes = 1_048_576

  private let factory: Factory
  private let output: Output
  private let version: String
  private let permissionTimeout: UInt64
  private var initialized = false
  private var closed = false
  private var shutdownTask: Task<Void, Never>?
  private var sessions: [String: ACPSession] = [:]
  private struct PendingSession {
    let cwd: URL
    let servers: [ACPMCPServer]
  }
  private var pendingSessions: [String: PendingSession] = [:]
  private var requests: [String: Task<Void, Never>] = [:]
  private var busy: [String: String] = [:]
  private var closing: Set<String> = []
  private var cancelled: Set<String> = []
  private struct PendingPermission {
    let sessionId: String
    let continuation: CheckedContinuation<PermissionDecision, Never>
    let timeout: Task<Void, Never>
  }
  private var permissions: [String: PendingPermission] = [:]

  public init(version: String, permissionTimeoutSeconds: Int = 300,
    factory: @escaping Factory, output: @escaping Output)
  {
    self.version = version
    self.factory = factory
    self.output = output
    permissionTimeout = UInt64(min(max(permissionTimeoutSeconds, 1), 3_600)) * 1_000_000_000
  }

  public func receive(line: Data) async {
    guard line.count <= Self.maximumMessageBytes else {
      await failure(id: .null, ACPError(code: -32600, message: "Message exceeds 1 MiB"))
      return
    }
    do { await receive(try JSONDecoder().decode(JSONValue.self, from: line)) }
    catch { await failure(id: .null, ACPError(code: -32700, message: "Invalid JSON")) }
  }

  public func receive(_ message: JSONValue) async {
    guard !closed else { return }
    guard let object = message.objectValue, object["jsonrpc"]?.stringValue == "2.0" else {
      await failure(id: .null, ACPError(code: -32600, message: "Expected a JSON-RPC 2.0 object"))
      return
    }
    let id = object["id"]
    guard let method = object["method"]?.stringValue else {
      // Replies belong only to this connection's outstanding permission requests. A bad
      // or unknown option is a denial, never implicit consent. Late replies are ignored.
      if let key = id?.stringValue, permissions[key] != nil {
        let outcome = object["result"]?.objectValue?["outcome"]?.objectValue
        let allowed = object["error"] == nil && outcome?["outcome"]?.stringValue == "selected"
          && outcome?["optionId"]?.stringValue == "allow-once"
        resolvePermission(key, allowed ? .allow : .deny(reason: "ACP client denied permission"))
      } else if object["result"] == nil && object["error"] == nil {
        await failure(id: id ?? .null, ACPError(code: -32600, message: "Missing method"))
      }
      return
    }
    guard object["result"] == nil && object["error"] == nil else {
      if let id { await failure(id: id, ACPError(code: -32600, message: "Request also contains a response")) }
      return
    }
    let params = object["params"]?.objectValue ?? [:]
    if id == nil {
      if method == "session/cancel", let sessionId = params["sessionId"]?.stringValue {
        await cancel(sessionId)
      }
      return // Notifications never receive responses, including unknown methods.
    }
    guard let id, Self.validID(id) else {
      await failure(id: .null, ACPError(code: -32600, message: "Invalid request id"))
      return
    }
    let key = Self.key(id)
    guard requests[key] == nil else {
      await failure(id: id, ACPError(code: -32600, message: "Request id already in flight"))
      return
    }
    do {
      if method == "initialize" {
        guard !initialized, params["protocolVersion"]?.intValue != nil else {
          throw ACPError(message: "Initialize once with an integer protocolVersion")
        }
        initialized = true
        await success(id: id, [
          "protocolVersion": 1,
          "agentInfo": ["name": "arnes", "version": .string(version)],
          "agentCapabilities": ["loadSession": false,
            "promptCapabilities": ["image": false, "audio": false, "embeddedContext": false],
            "sessionCapabilities": ["close": [:]]],
          "authMethods": [],
        ])
        return
      }
      guard initialized else { throw ACPError(code: -32002, message: "Initialize the connection first") }
      guard requests.count < 64 else { throw ACPError(code: -32000, message: "Too many outstanding requests") }
      switch method {
      case "session/new":
        guard sessions.count + pendingSessions.count < 32 else {
          throw ACPError(code: -32000, message: "Close a session before creating another (limit 32)")
        }
        guard let cwd = params["cwd"]?.stringValue, cwd.hasPrefix("/"), !cwd.contains("\0"),
          let serversJSON = params["mcpServers"]?.arrayValue
        else { throw ACPError(message: "session/new requires absolute cwd and mcpServers array") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue else {
          throw ACPError(message: "cwd must be an existing directory")
        }
        guard params["additionalDirectories"] == nil else {
          throw ACPError(message: "Additional workspace roots are not supported")
        }
        let servers = try Self.servers(serversJSON)
        let sessionId = UUID().uuidString
        // Return the ID before invoking a factory that may need permission replies. Editors
        // can only associate those permission requests with a session they already know.
        pendingSessions[sessionId] = PendingSession(cwd: URL(fileURLWithPath: cwd), servers: servers)
        await success(id: id, ["sessionId": .string(sessionId)])
      case "session/prompt":
        let sessionId = try session(params)
        guard busy[sessionId] == nil else { throw ACPError(code: -32000, message: "Session already has an active turn") }
        let text = try Self.prompt(params["prompt"])
        busy[sessionId] = key
        cancelled.remove(sessionId)
        requests[key] = Task { await self.prompt(id: id, key: key, sessionId: sessionId,
          text: text) }
      case "session/close":
        let sessionId = try session(params)
        closing.insert(sessionId)
        requests[key] = Task {
          let running = self.runningTask(sessionId)
          await self.cancel(sessionId)
          await running?.value
          if let managed = self.sessions[sessionId] {
            await managed.session.end(reason: .other)
            await managed.cleanup()
          }
          await self.finishClose(id: id, key: key, sessionId: sessionId)
        }
      default:
        throw ACPError(code: -32601, message: "Unsupported method: \(method)")
      }
    } catch {
      await failure(id: id, error)
    }
  }

  private func materialize(_ sessionId: String) async throws -> ACPSession {
    if let managed = sessions[sessionId] { return managed }
    guard let pending = pendingSessions[sessionId] else { throw ACPError(message: "Unknown sessionId") }
    do {
      let delegate = ACPPermissions { [weak self] request in
        guard let self else { return .deny(reason: "ACP connection closed") }
        return await self.requestPermission(request, sessionId: sessionId)
      }
      let managed = try await factory(sessionId, pending.cwd, pending.servers, delegate)
      guard !closed, !Task.isCancelled, !cancelled.contains(sessionId) else {
        await managed.session.end(reason: .other)
        await managed.cleanup()
        throw CancellationError()
      }
      do {
        try await managed.session.observeToolActivity { [weak self] activity in
          await self?.toolActivity(activity, sessionId: sessionId)
        }
      } catch {
        await managed.session.end(reason: .other)
        await managed.cleanup()
        throw error
      }
      sessions[sessionId] = managed
      pendingSessions.removeValue(forKey: sessionId)
      return managed
    } catch { throw error }
  }

  private func prompt(id: JSONValue, key: String, sessionId: String, text: String) async {
    var hadTextDeltas = false
    do {
      guard !Task.isCancelled, !cancelled.contains(sessionId) else { throw CancellationError() }
      let managed = try await materialize(sessionId)
      let stream = await managed.session.send(text)
      if cancelled.contains(sessionId) { await managed.session.interrupt() }
      for try await event in stream {
        switch event {
        case .textDelta(let text):
          hadTextDeltas = true
          await chunk(sessionId, kind: "agent_message_chunk", text: text)
        case .reasoningDelta(let text):
          await chunk(sessionId, kind: "agent_thought_chunk", text: text)
        case .assistantText(let text):
          if !hadTextDeltas { await chunk(sessionId, kind: "agent_message_chunk", text: text) }
          hadTextDeltas = false
        case .planUpdated(let steps):
          let entries: [JSONValue] = steps.map { ["content": .string($0.text),
            "priority": "medium", "status": .string($0.status)] }
          await update(sessionId, ["sessionUpdate": "plan", "entries": .array(entries)])
        default: break
        }
      }
      let record = await managed.session.lastRecord
      if record?.stopReason == .error, !cancelled.contains(sessionId) {
        throw ACPError(code: -32603, message: "Agent turn failed; inspect its Arnes run record")
      }
      let reason = cancelled.contains(sessionId) ? "cancelled" : Self.stopReason(record?.stopReason)
      finishPrompt(key: key, sessionId: sessionId)
      await success(id: id, ["stopReason": .string(reason)])
    } catch {
      if cancelled.contains(sessionId) || Task.isCancelled || error is CancellationError {
        await sessions[sessionId]?.session.interrupt()
        finishPrompt(key: key, sessionId: sessionId)
        await success(id: id, ["stopReason": "cancelled"])
      } else {
        finishPrompt(key: key, sessionId: sessionId)
        await failure(id: id, error)
      }
    }
  }

  private func finishPrompt(key: String, sessionId: String) {
    requests.removeValue(forKey: key)
    busy.removeValue(forKey: sessionId)
    cancelled.remove(sessionId)
  }

  private func session(_ params: [String: JSONValue]) throws -> String {
    guard let id = params["sessionId"]?.stringValue, !closing.contains(id),
      sessions[id] != nil || pendingSessions[id] != nil else {
      throw ACPError(message: "Unknown sessionId")
    }
    return id
  }

  private func runningTask(_ sessionId: String) -> Task<Void, Never>? {
    busy[sessionId].flatMap { requests[$0] }
  }

  private func cancel(_ sessionId: String) async {
    guard busy[sessionId] != nil else { return }
    cancelled.insert(sessionId)
    for key in permissions.keys.filter({ permissions[$0]?.sessionId == sessionId }) {
      resolvePermission(key, .deny(reason: "ACP turn cancelled"))
    }
    if let managed = sessions[sessionId] {
      // Interrupt Session, but keep draining its stream so its RunRecord is durable before
      // acknowledging cancellation. Cancelling the consumer would cut that drain short.
      await managed.session.interrupt()
      await managed.session.shutdown()
    } else if let key = busy[sessionId] { requests[key]?.cancel() }
  }

  private func finishClose(id: JSONValue, key: String, sessionId: String) async {
    requests.removeValue(forKey: key)
    sessions.removeValue(forKey: sessionId)
    pendingSessions.removeValue(forKey: sessionId)
    closing.remove(sessionId)
    cancelled.remove(sessionId)
    await success(id: id, [:])
  }

  /// EOF/transport failure cleanup: answer all suspended permission continuations, stop
  /// active turns, wait for their records, then release jobs and MCP transports.
  public func shutdown() async {
    if let shutdownTask { await shutdownTask.value; return }
    closed = true
    let task = Task { await self.drainAndClose() }
    shutdownTask = task
    await task.value
  }

  private func drainAndClose() async {
    for key in Array(permissions.keys) { resolvePermission(key, .deny(reason: "ACP connection closed")) }
    for id in Array(busy.keys) { await cancel(id) }
    let pending = Array(requests.values)
    for task in pending { await task.value }
    let managed = sessions
    sessions.removeAll()
    pendingSessions.removeAll()
    for session in managed.values {
      await session.session.end(reason: .other)
      await session.cleanup()
    }
  }

  private func requestPermission(_ request: PermissionRequest, sessionId: String) async -> PermissionDecision {
    guard !closed, !cancelled.contains(sessionId), !Task.isCancelled else {
      return .deny(reason: "ACP turn is no longer active")
    }
    let key = "permission-" + UUID().uuidString
    let decision = await withCheckedContinuation { continuation in
      let timeout = Task { [weak self, permissionTimeout] in
        do { try await Task.sleep(nanoseconds: permissionTimeout) } catch { return }
        await self?.resolvePermission(key, .deny(reason: "ACP permission request timed out"))
      }
      permissions[key] = PendingPermission(sessionId: sessionId, continuation: continuation, timeout: timeout)
      Task {
        await self.emit(["jsonrpc": "2.0", "id": .string(key), "method": "session/request_permission",
          "params": ["sessionId": .string(sessionId),
            "toolCall": ["toolCallId": .string(request.toolActivityID ?? key),
              "title": .string(String(SecretScrubber.scrub(request.summary).text.prefix(2_000))),
              "kind": "other", "status": "pending"],
            "options": [
              ["optionId": "allow-once", "name": "Allow once", "kind": "allow_once"],
              ["optionId": "reject-once", "name": "Reject", "kind": "reject_once"],
            ]]])
      }
    }
    return decision
  }

  private func resolvePermission(_ key: String, _ decision: PermissionDecision) {
    guard let pending = permissions.removeValue(forKey: key) else { return }
    pending.timeout.cancel()
    pending.continuation.resume(returning: decision)
  }

  private func toolActivity(_ activity: ToolActivity, sessionId: String) async {
    let status: String
    switch activity.phase {
    case .pending: status = "pending"
    case .running: status = "in_progress"
    case .completed: status = "completed"
    case .failed: status = "failed"
    }
    var value: [String: JSONValue] = [
      "sessionUpdate": .string(activity.phase == .pending ? "tool_call" : "tool_call_update"),
      "toolCallId": .string(activity.id), "status": .string(status),
    ]
    if activity.phase == .pending {
      value["title"] = .string(activity.name)
      value["kind"] = "other"
    }
    if let preview = activity.preview {
      value["content"] = [["type": "content", "content": ["type": "text", "text": .string(preview)]]]
    }
    await update(sessionId, .object(value))
  }

  private func chunk(_ sessionId: String, kind: String, text: String) async {
    guard !text.isEmpty else { return }
    await update(sessionId, ["sessionUpdate": .string(kind), "content": ["type": "text", "text": .string(text)]])
  }
  private func update(_ sessionId: String, _ update: JSONValue) async {
    await emit(["jsonrpc": "2.0", "method": "session/update",
      "params": ["sessionId": .string(sessionId), "update": update]])
  }
  private func success(id: JSONValue, _ result: JSONValue) async {
    await emit(["jsonrpc": "2.0", "id": id, "result": result])
  }
  private func failure(id: JSONValue, _ error: Error) async {
    let code = (error as? ACPError)?.code ?? -32603
    let text = error is CancellationError ? "Operation cancelled" : String(describing: error)
    await emit(["jsonrpc": "2.0", "id": id,
      "error": ["code": .int(code), "message": .string(String(SecretScrubber.scrub(text).text.prefix(2_000)))]])
  }
  private func emit(_ message: JSONValue) async {
    guard !closed else { return }
    do { try await output(message) }
    catch { Task { await self.shutdown() } }
  }
  private static func validID(_ id: JSONValue) -> Bool {
    switch id { case .string, .int: return true; default: return false }
  }
  private static func key(_ id: JSONValue) -> String {
    (try? JSONEncoder().encode(id).base64EncodedString()) ?? "invalid"
  }
  private static func servers(_ json: [JSONValue]) throws -> [ACPMCPServer] {
    guard json.count <= 16 else { throw ACPError(message: "At most 16 MCP servers per session") }
    let servers = try JSONDecoder().decode([ACPMCPServer].self, from: JSONEncoder().encode(json))
    var names: Set<String> = []
    for server in servers {
      guard (server.type == nil || server.type == "stdio"), server.command.hasPrefix("/"),
        !server.command.contains("\0"), !server.name.isEmpty, names.insert(server.name).inserted,
        !server.name.contains("\0"), server.args.allSatisfy({ !$0.contains("\0") }),
        server.env.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("=")
          && !$0.name.contains("\0") && !$0.value.contains("\0") })
      else { throw ACPError(message: "MCP servers need unique names, absolute commands and stdio transport") }
    }
    return servers
  }
  static func prompt(_ value: JSONValue?) throws -> String {
    guard let blocks = value?.arrayValue, !blocks.isEmpty else { throw ACPError(message: "prompt must be a nonempty content array") }
    let parts: [String] = try blocks.map { value in
      guard let block = value.objectValue else { throw ACPError(message: "Invalid content block") }
      switch block["type"]?.stringValue {
      case "text":
        guard let text = block["text"]?.stringValue else { throw ACPError(message: "Text block requires text") }
        return text
      case "resource_link":
        guard let uri = block["uri"]?.stringValue, let name = block["name"]?.stringValue else {
          throw ACPError(message: "Resource link requires uri and name")
        }
        // This is a reference, not authority to read outside the root or fetch a URL. The
        // model must use the normal, permission-gated file/network tools to inspect it.
        return "[resource reference: \(name)]\n\(uri)"
      default: throw ACPError(message: "Only text and resource_link prompts are supported")
      }
    }
    let text = parts.joined(separator: "\n\n")
    guard text.utf8.count <= maximumMessageBytes else { throw ACPError(message: "Prompt exceeds 1 MiB") }
    return text
  }
  static func stopReason(_ reason: StopReason?) -> String {
    switch reason {
    case .completed, .planProposed: return "end_turn"
    case .maxSteps: return "max_turn_requests"
    case .truncated: return "max_tokens"
    case .interrupted, .timeout: return "cancelled"
    default: return "refusal"
    }
  }
}

private struct ACPPermissions: PermissionDelegate {
  let answer: @Sendable (PermissionRequest) async -> PermissionDecision
  func decide(_ request: PermissionRequest) async -> PermissionDecision { await answer(request) }
  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await answer(.init(toolName: toolName, summary: summary, argumentsJSON: argumentsJSON, tier: .sensitive))
  }
}
