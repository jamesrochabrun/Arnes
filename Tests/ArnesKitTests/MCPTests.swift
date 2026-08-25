import OpenRouterSwift
import XCTest
@testable import ArnesKit

final class MCPTests: XCTestCase {

  private static let initializeResult: JSONValue = [
    "protocolVersion": "2025-06-18",
    "capabilities": [:],
    "serverInfo": ["name": "mock", "version": "1.0"],
  ]

  private func connectedClient(
    extraScripts: [String: [MockMCPTransport.Script]] = [:],
    timeout: TimeInterval = 2)
    async throws -> (MCPClient, MockMCPTransport)
  {
    var scripts: [String: [MockMCPTransport.Script]] = ["initialize": [.result(Self.initializeResult)]]
    scripts.merge(extraScripts) { _, new in new }
    let transport = MockMCPTransport(scripts: scripts)
    let client = MCPClient(serverName: "mock", transport: transport, requestTimeout: timeout)
    try await client.connect()
    return (client, transport)
  }

  // MARK: Handshake

  func testConnectPerformsInitializeHandshake() async throws {
    let (_, transport) = try await connectedClient()
    let sent = await transport.sent
    XCTAssertEqual(sent.count, 2)
    XCTAssertEqual(sent[0]["method"]?.stringValue, "initialize")
    XCTAssertEqual(sent[0]["params"]?["protocolVersion"]?.stringValue, "2025-06-18")
    XCTAssertEqual(sent[0]["params"]?["clientInfo"]?["name"]?.stringValue, "arnes")
    XCTAssertEqual(sent[1]["method"]?.stringValue, "notifications/initialized")
    XCTAssertNil(sent[1]["id"], "notifications must not carry a request id")
  }

  func testRequestTimesOutWhenServerNeverAnswers() async throws {
    let transport = MockMCPTransport(scripts: ["initialize": [.silence]])
    let client = MCPClient(serverName: "mock", transport: transport, requestTimeout: 0.2)
    do {
      try await client.connect()
      XCTFail("expected timeout")
    } catch let error as MCPError {
      guard case .timedOut(let method, _) = error else {
        return XCTFail("expected timedOut, got \(error)")
      }
      XCTAssertEqual(method, "initialize")
    }
  }

  // MARK: tools/list

  func testListToolsFollowsPagination() async throws {
    let pageOne: JSONValue = [
      "tools": [["name": "alpha", "description": "First.", "inputSchema": ["type": "object"]]],
      "nextCursor": "page2",
    ]
    let pageTwo: JSONValue = [
      "tools": [["name": "beta", "annotations": ["readOnlyHint": true]]],
    ]
    let (client, transport) = try await connectedClient(
      extraScripts: ["tools/list": [.result(pageOne), .result(pageTwo)]])

    let tools = try await client.listTools()
    XCTAssertEqual(tools.map(\.name), ["alpha", "beta"])
    XCTAssertEqual(tools[1].annotations?.readOnlyHint, true)

    let listRequests = await transport.sent.filter { $0["method"]?.stringValue == "tools/list" }
    XCTAssertEqual(listRequests.count, 2)
    XCTAssertNil(listRequests[0]["params"]?["cursor"])
    XCTAssertEqual(listRequests[1]["params"]?["cursor"]?.stringValue, "page2")
  }

  // MARK: tools/call

  func testCallToolJoinsTextAndMarksNonText() async throws {
    let result: JSONValue = [
      "content": [
        ["type": "text", "text": "line one"],
        ["type": "image", "data": "…"],
        ["type": "text", "text": "line two"],
      ],
    ]
    let (client, transport) = try await connectedClient(extraScripts: ["tools/call": [.result(result)]])
    let output = try await client.callTool("echo", arguments: ["text": .string("hi")])
    XCTAssertEqual(output, "line one\n[image content omitted]\nline two")

    let call = await transport.sent.first { $0["method"]?.stringValue == "tools/call" }
    XCTAssertEqual(call?["params"]?["name"]?.stringValue, "echo")
    XCTAssertEqual(call?["params"]?["arguments"]?["text"]?.stringValue, "hi")
  }

  func testCallToolPrefixesServerFlaggedErrors() async throws {
    let result: JSONValue = [
      "content": [["type": "text", "text": "file not found"]],
      "isError": true,
    ]
    let (client, _) = try await connectedClient(extraScripts: ["tools/call": [.result(result)]])
    let output = try await client.callTool("read", arguments: [:])
    XCTAssertEqual(output, "error: file not found")
  }

  func testJSONRPCErrorSurfacesAsMCPError() async throws {
    let (client, _) = try await connectedClient(extraScripts: ["tools/list": [.error("no tools capability")]])
    do {
      _ = try await client.listTools()
      XCTFail("expected server error")
    } catch let error as MCPError {
      guard case .server(let message) = error else {
        return XCTFail("expected .server, got \(error)")
      }
      XCTAssertEqual(message, "no tools capability")
    }
  }

  // MARK: Server-initiated traffic

  func testServerPingIsAnswered() async throws {
    let (_, transport) = try await connectedClient()
    await transport.push(["jsonrpc": "2.0", "id": 99, "method": "ping"])
    // The reply arrives via the client's reader task; poll briefly.
    for _ in 0..<50 {
      let reply = await transport.sent.first { $0["id"]?.intValue == 99 && $0["result"] != nil }
      if reply != nil { return }
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("ping was never answered")
  }

  // MARK: AgentTool bridging

  func testMCPToolNamespacingSchemaAndPermissions() async throws {
    let (client, _) = try await connectedClient()
    let schema: JSONValue = [
      "type": "object",
      "properties": ["path": ["type": "string"]],
      "required": ["path"],
    ]
    let readOnly = MCPTool(
      serverName: "files",
      info: MCPToolInfo(
        name: "list.files",
        description: "List files.",
        inputSchema: schema,
        annotations: MCPToolInfo.Annotations(readOnlyHint: true)),
      client: client)
    XCTAssertEqual(readOnly.name, "mcp__files__list_files", "dots are sanitized for provider name rules")
    XCTAssertEqual(readOnly.permission, .readOnly)
    XCTAssertEqual(readOnly.parameters, schema, "the server schema passes through untouched")
    XCTAssertTrue(readOnly.summary(arguments: ["path": .string("/tmp")]).contains("files:list.files"))

    let unannotated = MCPTool(
      serverName: "files",
      info: MCPToolInfo(name: "delete"),
      client: client)
    XCTAssertEqual(unannotated.permission, .mutating, "no readOnlyHint means gated")
    XCTAssertEqual(unannotated.parameters, ["type": "object", "properties": [:]])
  }

  func testMCPToolExecuteRoutesToServer() async throws {
    let result: JSONValue = ["content": [["type": "text", "text": "ok"]]]
    let (client, transport) = try await connectedClient(extraScripts: ["tools/call": [.result(result)]])
    let tool = MCPTool(serverName: "srv", info: MCPToolInfo(name: "do.thing"), client: client)
    let output = try await tool.execute(arguments: ["x": .int(1)])
    XCTAssertEqual(output, "ok")
    let call = await transport.sent.first { $0["method"]?.stringValue == "tools/call" }
    XCTAssertEqual(call?["params"]?["name"]?.stringValue, "do.thing", "the wire call uses the un-sanitized name")
  }

  // MARK: Provider

  func testProviderAggregatesToolsAndReportsFailures() async throws {
    let listResult: JSONValue = ["tools": [["name": "echo", "description": "Echo."]]]
    let provider = MCPToolProvider(transportFactory: { name, _ in
      name == "good"
        ? MockMCPTransport(scripts: [
            "initialize": [.result(Self.initializeResult)],
            "tools/list": [.result(listResult)],
          ])
        : MockMCPTransport(scripts: [:], failOnStart: true)
    })
    let config = MCPConfig(mcpServers: [
      "good": MCPServerConfig(command: "unused"),
      "broken": MCPServerConfig(command: "unused"),
    ])
    let (tools, statuses) = await provider.connect(config: config, requestTimeout: 2)

    XCTAssertEqual(tools.map(\.name), ["mcp__good__echo"])
    XCTAssertEqual(statuses.map(\.server), ["broken", "good"], "statuses are sorted by server name")
    XCTAssertNotNil(statuses[0].error)
    XCTAssertNil(statuses[1].error)
    XCTAssertEqual(statuses[1].toolCount, 1)
    await provider.shutdown()
  }

  // MARK: Config

  func testConfigDecodingMatchesClaudeDesktopShape() throws {
    let json = """
      {"mcpServers": {"filesystem": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"],
        "env": {"DEBUG": "1"}
      }}}
      """
    let config = try JSONDecoder().decode(MCPConfig.self, from: Data(json.utf8))
    let server = config.mcpServers["filesystem"]
    XCTAssertEqual(server?.command, "npx")
    XCTAssertEqual(server?.args, ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"])
    XCTAssertEqual(server?.env, ["DEBUG": "1"])
  }

  func testConfigLoadReturnsNilWhenAbsent() throws {
    let missing = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-mcp-\(UUID().uuidString).json")
    XCTAssertNil(try MCPConfig.load(from: missing))
  }

  // MARK: End-to-end over a real process

  func testProcessTransportAgainstFakeBashServer() async throws {
    let script = """
      #!/bin/bash
      while IFS= read -r line; do
        case "$line" in
          *'"method":"initialize"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{},"serverInfo":{"name":"fake","version":"1"}}}' ;;
          *'"tools/list"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":2,"result":{"tools":[{"name":"echo","description":"Echo text back.","inputSchema":{"type":"object","properties":{"text":{"type":"string"}},"required":["text"]},"annotations":{"readOnlyHint":true}}]}}' ;;
          *'"tools/call"'*)
            printf '%s\\n' '{"jsonrpc":"2.0","id":3,"result":{"content":[{"type":"text","text":"echo: hi"}]}}' ;;
        esac
      done
      """
    let scriptURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-fake-mcp-\(UUID().uuidString).sh")
    try script.write(to: scriptURL, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: scriptURL) }

    let provider = MCPToolProvider()
    let config = MCPConfig(mcpServers: [
      "fake": MCPServerConfig(command: "/bin/bash", args: [scriptURL.path]),
    ])
    let (tools, statuses) = await provider.connect(config: config, requestTimeout: 10)

    guard let tool = tools.first, statuses.first?.error == nil else {
      await provider.shutdown()
      return XCTFail("fake server did not connect: \(statuses.first?.error ?? "no status")")
    }
    XCTAssertEqual(tool.name, "mcp__fake__echo")
    XCTAssertEqual((tool as? MCPTool)?.permission, .readOnly)
    let output = try await tool.execute(arguments: ["text": .string("hi")])
    XCTAssertEqual(output, "echo: hi")
    await provider.shutdown()
  }
}
