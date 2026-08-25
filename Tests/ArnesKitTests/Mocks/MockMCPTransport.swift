import Foundation
import OpenRouterSwift
@testable import ArnesKit

/// Scripted MCP transport: decodes each sent JSON-RPC message, pops the next script for
/// its method, and echoes a response line with the matching request id. Notifications
/// (no id) are recorded but never answered, like a real server.
actor MockMCPTransport: MCPTransport {
  enum Script {
    case result(JSONValue)
    case error(String)
    /// Never respond — for timeout tests.
    case silence
  }

  private var scripts: [String: [Script]]
  private let failOnStart: Bool
  private var continuation: AsyncStream<String>.Continuation?
  private(set) var sent: [[String: JSONValue]] = []
  private(set) var stopped = false

  init(scripts: [String: [Script]], failOnStart: Bool = false) {
    self.scripts = scripts
    self.failOnStart = failOnStart
  }

  func start() async throws -> AsyncStream<String> {
    if failOnStart {
      throw MCPError.notConnected(server: "mock")
    }
    let (stream, continuation) = AsyncStream<String>.makeStream()
    self.continuation = continuation
    return stream
  }

  func send(_ line: String) async throws {
    let message = try JSONDecoder().decode([String: JSONValue].self, from: Data(line.utf8))
    sent.append(message)
    guard
      let method = message["method"]?.stringValue,
      let id = message["id"]?.intValue,
      var queue = scripts[method], !queue.isEmpty
    else {
      return
    }
    let script = queue.removeFirst()
    scripts[method] = queue
    switch script {
    case .result(let result):
      yield(["jsonrpc": "2.0", "id": .int(id), "result": result])
    case .error(let text):
      yield(["jsonrpc": "2.0", "id": .int(id), "error": ["code": -1, "message": .string(text)]])
    case .silence:
      break
    }
  }

  func stop() async {
    stopped = true
    continuation?.finish()
  }

  /// Injects a server-initiated message (e.g. a ping request).
  func push(_ message: [String: JSONValue]) {
    yield(message)
  }

  private func yield(_ message: [String: JSONValue]) {
    guard
      let data = try? JSONEncoder().encode(JSONValue.object(message)),
      let continuation
    else { return }
    continuation.yield(String(decoding: data, as: UTF8.self))
  }
}
