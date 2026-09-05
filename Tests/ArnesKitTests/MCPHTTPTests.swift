import Foundation
import OpenRouterSwift
import XCTest
@testable import ArnesKit

// MARK: - StubMCPHTTPPerformer

/// Scripted HTTP for the MCP transport: answers from a handler and records every request,
/// the same shape `GatewayTests` uses to stub the model client's `HTTPClient`.
final class StubMCPHTTPPerformer: MCPHTTPPerformer, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [MCPHTTPRequest] = []
  private let handler: @Sendable (MCPHTTPRequest, Int) -> MCPHTTPResponse

  init(handler: @escaping @Sendable (MCPHTTPRequest, Int) -> MCPHTTPResponse) {
    self.handler = handler
  }

  /// Answers every POST with the same JSON body.
  convenience init(json: String, headers: [String: String] = [:]) {
    self.init { _, _ in
      MCPHTTPResponse(
        statusCode: 200,
        headers: headers.merging(["Content-Type": "application/json"]) { current, _ in current },
        body: Data(json.utf8))
    }
  }

  var requests: [MCPHTTPRequest] { lock.withLock { recorded } }
  var posts: [MCPHTTPRequest] { requests.filter { $0.method == "POST" } }

  func perform(_ request: MCPHTTPRequest) async throws -> MCPHTTPResponse {
    let index = lock.withLock { () -> Int in
      recorded.append(request)
      return recorded.count - 1
    }
    return handler(request, index)
  }
}

// MARK: - MCPHTTPTests

final class MCPHTTPTests: XCTestCase {

  private func config(
    url: String = "https://mcp.example.com/mcp",
    headers: [String: String]? = nil,
    insecure: Bool? = nil)
    -> MCPServerConfig
  {
    MCPServerConfig(type: "http", url: url, headers: headers, insecure: insecure)
  }

  /// Sends one line, closes the transport, and returns everything the stream produced.
  private func lines(
    from transport: HTTPMCPTransport,
    sending line: String = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
    async throws -> [String]
  {
    let stream = try await transport.start()
    try await transport.send(line)
    await transport.stop()
    var collected: [String] = []
    for await line in stream { collected.append(line) }
    return collected
  }

  // MARK: Requests

  func testPostCarriesAcceptAndConfiguredHeadersWithEnvExpansion() async throws {
    let stub = StubMCPHTTPPerformer(json: #"{"jsonrpc":"2.0","id":1,"result":{}}"#)
    let transport = try HTTPMCPTransport(
      name: "docs",
      config: config(headers: ["Authorization": "Bearer ${DOCS_TOKEN}", "X-Team": "ios"]),
      performer: stub,
      environment: ["DOCS_TOKEN": "s3cr3t"])
    let body = #"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#
    _ = try await lines(from: transport, sending: body)

    let post = try XCTUnwrap(stub.posts.first)
    XCTAssertEqual(post.url.absoluteString, "https://mcp.example.com/mcp")
    XCTAssertEqual(post.headers["Accept"], "application/json, text/event-stream")
    XCTAssertEqual(post.headers["Content-Type"], "application/json")
    XCTAssertEqual(post.headers["Authorization"], "Bearer s3cr3t", "${NAME} expands like env does")
    XCTAssertEqual(post.headers["X-Team"], "ios")
    XCTAssertEqual(post.body, Data(body.utf8))
  }

  func testJSONResponseYieldsOneLine() async throws {
    // Pretty-printed on purpose: one JSON object is one message however it's formatted.
    let pretty = """
      {
        "jsonrpc": "2.0",
        "id": 1,
        "result": {"protocolVersion": "2025-06-18"}
      }
      """
    let transport = try HTTPMCPTransport(
      name: "docs", config: config(), performer: StubMCPHTTPPerformer(json: pretty))
    let collected = try await lines(from: transport)
    XCTAssertEqual(collected.count, 1)
    XCTAssertEqual(collected.first, pretty)
  }

  func testSSEResponseYieldsEachDataEvent() async throws {
    // CRLF framing, a comment keep-alive, and a multi-line data payload.
    let body = "event: message\r\ndata: {\"id\":1}\r\n\r\n: ping\r\n\r\ndata: {\"id\":\r\ndata: 2}\r\n\r\n"
    let stub = StubMCPHTTPPerformer { _, _ in
      MCPHTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "text/event-stream; charset=utf-8"],
        body: Data(body.utf8))
    }
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    let collected = try await lines(from: transport)
    XCTAssertEqual(collected, [#"{"id":1}"#, "{\"id\":\n2}"])
  }

  func testSSEParserJoinsDataLinesAndTolerantOfLineEndings() {
    XCTAssertEqual(HTTPMCPTransport.sseEvents(in: "data: a\n\ndata: b\n\n"), ["a", "b"])
    XCTAssertEqual(HTTPMCPTransport.sseEvents(in: "data:a\r\ndata:b\r\n\r\n"), ["a\nb"])
    XCTAssertEqual(HTTPMCPTransport.sseEvents(in: "data: last-without-blank-line"), ["last-without-blank-line"])
    XCTAssertEqual(HTTPMCPTransport.sseEvents(in: ": keep-alive\n\n"), [])
    XCTAssertEqual(HTTPMCPTransport.sseEvents(in: ""), [])
  }

  func testSessionIdCapturedFromInitializeAndEchoed() async throws {
    let stub = StubMCPHTTPPerformer { _, index in
      MCPHTTPResponse(
        statusCode: 200,
        headers: index == 0
          ? ["Content-Type": "application/json", "mcp-session-id": "sess-42"]
          : ["Content-Type": "application/json"],
        body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
    }
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    let stream = try await transport.start()
    try await transport.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
    try await transport.send(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    await transport.stop()
    for await _ in stream {} // drain

    let posts = stub.posts
    XCTAssertEqual(posts.count, 2)
    XCTAssertNil(posts[0].headers["Mcp-Session-Id"], "nothing to echo before initialize answers")
    XCTAssertNil(posts[0].headers["MCP-Protocol-Version"])
    XCTAssertEqual(posts[1].headers["Mcp-Session-Id"], "sess-42", "captured case-insensitively")
    XCTAssertEqual(posts[1].headers["MCP-Protocol-Version"], "2025-06-18")
  }

  func testStopSendsDelete() async throws {
    let stub = StubMCPHTTPPerformer(
      json: #"{"jsonrpc":"2.0","id":1,"result":{}}"#,
      headers: ["Mcp-Session-Id": "sess-7"])
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    _ = try await lines(from: transport)

    let deletes = stub.requests.filter { $0.method == "DELETE" }
    XCTAssertEqual(deletes.count, 1)
    XCTAssertEqual(deletes.first?.url.absoluteString, "https://mcp.example.com/mcp")
    XCTAssertEqual(deletes.first?.headers["Mcp-Session-Id"], "sess-7")
    XCTAssertNil(deletes.first?.body)
  }

  func testNonSuccessStatusBecomesATransportError() async throws {
    let stub = StubMCPHTTPPerformer { _, _ in
      MCPHTTPResponse(statusCode: 401, headers: [:], body: Data("no token".utf8))
    }
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    _ = try await transport.start()
    do {
      try await transport.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
      XCTFail("expected a transport error")
    } catch let error as MCPError {
      guard case .transport(let server, let detail) = error else {
        return XCTFail("expected .transport, got \(error)")
      }
      XCTAssertEqual(server, "docs")
      XCTAssertTrue(detail.contains("401"))
      XCTAssertTrue(detail.contains("no token"))
    }
  }

  // MARK: URL policy

  func testHttpOffLoopbackRefusedUnlessInsecure() throws {
    XCTAssertThrowsError(try HTTPMCPTransport(
      name: "docs", config: config(url: "http://mcp.example.com/mcp"), performer: StubMCPHTTPPerformer(json: "{}")))
    { error in
      guard case .misconfigured(let server, let detail)? = error as? MCPError else {
        return XCTFail("expected .misconfigured, got \(error)")
      }
      XCTAssertEqual(server, "docs")
      XCTAssertTrue(detail.contains("plain http"), detail)
    }
    // Loopback is how a local server is reached, and `insecure` is the trusted-network
    // escape hatch — both stay usable.
    XCTAssertNoThrow(try HTTPMCPTransport(
      name: "local", config: config(url: "http://127.0.0.1:9000/mcp"), performer: StubMCPHTTPPerformer(json: "{}")))
    XCTAssertNoThrow(try HTTPMCPTransport(
      name: "lan", config: config(url: "http://mcp.example.com/mcp", insecure: true),
      performer: StubMCPHTTPPerformer(json: "{}")))
    // No url at all is a config error, not a crash.
    XCTAssertThrowsError(try HTTPMCPTransport(
      name: "docs", config: MCPServerConfig(type: "http"), performer: StubMCPHTTPPerformer(json: "{}")))
  }

  func testRedirectToOtherHostRefused() async throws {
    let stub = StubMCPHTTPPerformer { _, _ in
      MCPHTTPResponse(statusCode: 307, headers: ["Location": "https://evil.example.net/mcp"], body: Data())
    }
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    _ = try await transport.start()
    do {
      try await transport.send(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#)
      XCTFail("expected the redirect to be refused")
    } catch let error as MCPError {
      guard case .transport(_, let detail) = error else {
        return XCTFail("expected .transport, got \(error)")
      }
      XCTAssertTrue(detail.contains("evil.example.net"), detail)
      XCTAssertTrue(detail.contains("another host"), detail)
    }
    XCTAssertEqual(stub.requests.count, 1, "the redirect was never followed")
  }

  func testSameHostRedirectIsFollowed() async throws {
    let stub = StubMCPHTTPPerformer { request, _ in
      request.url.path == "/mcp"
        ? MCPHTTPResponse(statusCode: 308, headers: ["Location": "/mcp/v2"], body: Data())
        : MCPHTTPResponse(
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: Data(#"{"jsonrpc":"2.0","id":1,"result":{}}"#.utf8))
    }
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    let collected = try await lines(from: transport)
    XCTAssertEqual(collected, [#"{"jsonrpc":"2.0","id":1,"result":{}}"#])
    XCTAssertEqual(stub.posts.map(\.url.path), ["/mcp", "/mcp/v2"])
  }

  // MARK: End to end through MCPClient

  func testClientHandshakeAndToolCallOverHTTP() async throws {
    let stub = StubMCPHTTPPerformer { request, _ in
      let body = String(decoding: request.body ?? Data(), as: UTF8.self)
      let payload: String
      if body.contains("notifications/") {
        return MCPHTTPResponse(statusCode: 202) // notifications get an empty ack
      } else if body.contains(#""method":"initialize""#) {
        payload = #"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{}}}"#
      } else if body.contains("tools/list") {
        payload = #"{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"search","description":"Search docs."}]}}"#
      } else if body.contains("tools/call") {
        payload = #"{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"found it"}]}}"#
      } else {
        return MCPHTTPResponse(statusCode: 202)
      }
      // Real streamable-HTTP servers answer with SSE; exercise that path end to end.
      return MCPHTTPResponse(
        statusCode: 200,
        headers: ["Content-Type": "text/event-stream", "Mcp-Session-Id": "sess-1"],
        body: Data("event: message\r\ndata: \(payload)\r\n\r\n".utf8))
    }
    let transport = try HTTPMCPTransport(name: "docs", config: config(), performer: stub)
    let client = MCPClient(serverName: "docs", transport: transport, requestTimeout: 5)
    try await client.connect()
    let tools = try await client.listTools()
    XCTAssertEqual(tools.map(\.name), ["search"])
    let output = try await client.callTool("search", arguments: ["q": .string("mcp")])
    XCTAssertEqual(output, "found it")
    await client.close()
  }
}
