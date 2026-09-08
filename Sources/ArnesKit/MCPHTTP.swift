import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - MCPHTTPRequest

/// One HTTP round-trip, reduced to what the MCP transport needs.
public struct MCPHTTPRequest: Sendable {
  public var url: URL
  public var method: String
  public var headers: [String: String]
  public var body: Data?

  public init(url: URL, method: String, headers: [String: String] = [:], body: Data? = nil) {
    self.url = url
    self.method = method
    self.headers = headers
    self.body = body
  }
}

// MARK: - MCPHTTPResponse

public struct MCPHTTPResponse: Sendable {
  public var statusCode: Int
  public var headers: [String: String]
  public var body: Data

  public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
    self.statusCode = statusCode
    self.headers = headers
    self.body = body
  }

  /// Case-insensitive lookup: HTTP header names aren't case-sensitive and servers
  /// disagree about `Mcp-Session-Id` vs `mcp-session-id`.
  public func header(_ name: String) -> String? {
    headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
  }

  public var text: String { String(decoding: body, as: UTF8.self) }
}

// MARK: - MCPHTTPPerformer

/// The injectable HTTP seam, mirroring how the model client's `HTTPClient` is stubbed in
/// `GatewayTests`: tests script responses instead of opening a socket.
///
/// Implementations **must not follow redirects** — the transport decides, because a
/// `302` to another host must never carry the configured headers (they hold the token).
public protocol MCPHTTPPerformer: Sendable {
  func perform(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse
}

/// The real performer. Redirects are surfaced rather than followed (the task delegate
/// answers every `3xx` with "don't"), so `HTTPMCPTransport` can apply the host rule.
public final class URLSessionMCPPerformer: NSObject, MCPHTTPPerformer, URLSessionTaskDelegate,
  @unchecked Sendable
{
  private let session: URLSession

  public init(timeout: TimeInterval = 120) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.httpShouldSetCookies = false
    // Corelibs Foundation does not apply per-task redirect delegates consistently.
    session = URLSession(configuration: configuration, delegate: MCPRedirectBlocker(), delegateQueue: nil)
    super.init()
  }

  public func perform(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse {
    var urlRequest = URLRequest(url: request.url)
    urlRequest.httpMethod = request.method
    urlRequest.httpBody = request.body
    for (name, value) in request.headers {
      urlRequest.setValue(value, forHTTPHeaderField: name)
    }
    let (data, response) = try await session.data(for: urlRequest)
    guard let http = response as? HTTPURLResponse else {
      return MCPHTTPResponse(statusCode: 0, headers: [:], body: data)
    }
    var headers: [String: String] = [:]
    for (key, value) in http.allHeaderFields {
      if let key = key as? String, let value = value as? String {
        headers[key] = value
      }
    }
    return MCPHTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
  }

  public func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest)
    async -> URLRequest?
  {
    nil // never automatically — the transport checks the host first
  }
}

/// Corelibs Foundation invokes the completion-handler delegate requirement on Linux;
/// implementing only its async convenience overload silently follows redirects there.
private final class MCPRedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping @Sendable (URLRequest?) -> Void)
  {
    completionHandler(nil)
  }
}

// MARK: - HTTPMCPTransport

/// The streamable-HTTP MCP transport: every JSON-RPC message is POSTed to one endpoint
/// and the reply comes back in the same response — either a single JSON object or an
/// SSE stream of them. The session id the server hands out at `initialize` rides every
/// later request, and `stop()` DELETEs it.
///
/// v1 is request/response. A server that pushes unsolicited messages down a long-lived
/// `GET` SSE stream won't be heard (arnes answers pings on stdio only); the tools that
/// matter — `tools/list`, `tools/call` — are all client-initiated.
public actor HTTPMCPTransport: MCPTransport {
  /// Same-host redirects we'll follow before giving up.
  private static let maxRedirects = 3
  private static let protocolVersion = "2025-06-18"

  private let name: String
  private let endpoint: URL
  private let headers: [String: String]
  private let performer: any MCPHTTPPerformer
  private let policy: URLPolicy
  private var continuation: AsyncStream<String>.Continuation?
  /// `Mcp-Session-Id`, learned from the initialize response and echoed from then on.
  private var sessionId: String?
  /// The spec wants `MCP-Protocol-Version` on every request *after* initialize.
  private var negotiated = false
  private var stopped = false

  /// - Throws: `MCPError.misconfigured` when the entry has no usable `url` — the URL is
  ///   checked once here (scheme, loopback rule) instead of on every request.
  public init(
    name: String,
    config: MCPServerConfig,
    performer: (any MCPHTTPPerformer)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment)
    throws
  {
    guard let raw = config.url, !raw.isEmpty else {
      throw MCPError.misconfigured(
        server: name,
        detail: #"no "url" — an http server needs one (or set "command" for a stdio server)"#)
    }
    let policy = URLPolicy(insecure: config.insecure ?? false)
    do {
      endpoint = try policy.validate(string: raw)
    } catch let failure as URLPolicy.Failure {
      throw MCPError.misconfigured(server: name, detail: failure.description)
    }
    self.name = name
    self.policy = policy
    self.headers = config.expandedHeaders(environment: environment)
    self.performer = performer ?? URLSessionMCPPerformer(timeout: config.toolTimeout)
  }

  // MARK: MCPTransport

  public func start() async throws -> AsyncStream<String> {
    let (stream, continuation) = AsyncStream<String>.makeStream()
    self.continuation = continuation
    stopped = false
    return stream
  }

  public func send(_ line: String) async throws {
    guard let continuation, !stopped else { throw MCPError.notConnected(server: name) }
    let response = try await post(body: Data(line.utf8))
    if let id = response.header("Mcp-Session-Id"), !id.isEmpty {
      sessionId = id
    }
    negotiated = true
    guard (200..<300).contains(response.statusCode) else {
      throw MCPError.transport(
        server: name,
        detail: "HTTP \(response.statusCode) from \(endpoint.absoluteString): "
          + String(response.text.prefix(200)))
    }
    // 202 with no body is the correct answer to a notification.
    guard !response.body.isEmpty else { return }
    let contentType = response.header("Content-Type")?.lowercased() ?? ""
    if contentType.contains("text/event-stream") {
      for event in Self.sseEvents(in: response.text) {
        continuation.yield(event)
      }
    } else {
      // One JSON object per response; pretty-printed bodies stay one message, so the
      // whole body is yielded as a single "line".
      let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
      if !text.isEmpty { continuation.yield(text) }
    }
  }

  public func stop() async {
    guard !stopped else { return }
    stopped = true
    continuation?.finish()
    continuation = nil
    guard let sessionId else { return }
    // Best effort, and bounded: a hung gateway must not hold the CLI's exit open.
    let request = MCPHTTPRequest(
      url: endpoint,
      method: "DELETE",
      headers: requestHeaders(includeContentType: false, sessionId: sessionId))
    let performer = performer
    await withTaskGroup(of: Void.self) { group in
      group.addTask { _ = try? await performer.perform(request) }
      group.addTask { try? await Task.sleep(nanoseconds: 5_000_000_000) }
      await group.next()
      group.cancelAll()
    }
  }

  // MARK: Requests

  private func post(body: Data) async throws -> MCPHTTPResponse {
    var target = endpoint
    for _ in 0...Self.maxRedirects {
      let response = try await performer.perform(MCPHTTPRequest(
        url: target,
        method: "POST",
        headers: requestHeaders(includeContentType: true, sessionId: sessionId),
        body: body))
      guard (300..<400).contains(response.statusCode) else { return response }
      guard let location = response.header("Location"), !location.isEmpty else { return response }
      do {
        target = try policy.redirect(from: target, to: location)
      } catch let failure as URLPolicy.Failure {
        throw MCPError.transport(server: name, detail: failure.description)
      }
    }
    throw MCPError.transport(
      server: name,
      detail: URLPolicy.Failure.tooManyRedirects(endpoint.absoluteString).description)
  }

  /// Configured headers first, then the ones the protocol owns — a config can't override
  /// `Accept` or the session id into something the server won't understand.
  private func requestHeaders(includeContentType: Bool, sessionId: String?) -> [String: String] {
    var merged = headers
    merged["Accept"] = "application/json, text/event-stream"
    if includeContentType {
      merged["Content-Type"] = "application/json"
    }
    if let sessionId, !sessionId.isEmpty {
      merged["Mcp-Session-Id"] = sessionId
    }
    if negotiated {
      merged["MCP-Protocol-Version"] = Self.protocolVersion
    }
    return merged
  }

  // MARK: SSE

  /// The `data:` payload of every event in an SSE body, in order. Events are separated by
  /// a blank line; a multi-line event's `data:` lines join with newlines (the SSE rule),
  /// and one leading space after the colon is dropped. CRLF, LF, and bare CR all frame.
  static func sseEvents(in body: String) -> [String] {
    var events: [String] = []
    var current: [String] = []
    func flush() {
      guard !current.isEmpty else { return }
      let payload = current.joined(separator: "\n")
      if !payload.isEmpty { events.append(payload) }
      current = []
    }
    for rawLine in body.replacingOccurrences(of: "\r\n", with: "\n").split(
      omittingEmptySubsequences: false,
      whereSeparator: { $0 == "\n" || $0 == "\r" })
    {
      let line = String(rawLine)
      if line.isEmpty {
        flush()
        continue
      }
      if line.hasPrefix(":") { continue } // comment/keep-alive
      guard let colon = line.firstIndex(of: ":") else { continue } // bare field name, no value
      let field = String(line[line.startIndex..<colon])
      var value = String(line[line.index(after: colon)...])
      if value.hasPrefix(" ") { value.removeFirst() }
      if field == "data" { current.append(value) }
    }
    flush()
    return events
  }
}
