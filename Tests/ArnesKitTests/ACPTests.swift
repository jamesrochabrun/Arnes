import XCTest
@testable import ArnesKit
import OpenRouterSwift

private actor ACPMailbox {
  var messages: [JSONValue] = []
  func add(_ value: JSONValue) { messages.append(value) }
  func matching(_ predicate: @Sendable (JSONValue) -> Bool) -> JSONValue? { messages.first(where: predicate) }
  func all() -> [JSONValue] { messages }
}

private actor ACPFinishOrder {
  var values: [String] = []
  func append(_ value: String) { values.append(value) }
}

final class ACPTests: XCTestCase {
  private struct Mutation: AgentTool {
    let name = "mutate"
    let description = "A test mutation."
    let parameters: JSONValue = ["type": "object", "properties": [:]]
    func execute(arguments: [String: JSONValue]) async throws -> String { "changed" }
  }
  private struct ConcurrentRead: ConcurrentTool {
    let name = "read_test"
    let description = "A concurrent test read."
    let parameters: JSONValue = ["type": "object", "properties": ["value": ["type": "string"]]]
    let order: ACPFinishOrder
    func permission(for arguments: [String: JSONValue]) -> ToolPermission { .readOnly }
    func execute(arguments: [String: JSONValue]) async throws -> String {
      let value = arguments["value"]?.stringValue ?? ""
      if value == "first" { try await Task.sleep(nanoseconds: 100_000_000) }
      if value == "wait" { try await Task.sleep(nanoseconds: 30_000_000_000) }
      await order.append(value)
      return value == "error" ? "error: test failure" : "result: \(value)"
    }
  }

  private func toolUpdates(_ messages: [JSONValue]) -> [[String: JSONValue]] {
    messages.compactMap { message in
      guard let update = message.objectValue?["params"]?.objectValue?["update"]?.objectValue,
        ["tool_call", "tool_call_update"].contains(update["sessionUpdate"]?.stringValue ?? "")
      else { return nil }
      return update
    }
  }
  private func root() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-acp-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return root
  }
  private func connection(mock: MockOpenRouterService, root: URL, mailbox: ACPMailbox,
    tools: [any AgentTool] = [], timeout: Int = 300) -> ACPConnection
  {
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let connection = ACPConnection(version: "test", permissionTimeoutSeconds: timeout,
      factory: { id, cwd, _, permissions in
        ACPSession(session: Session(service: mock, tools: tools, permissions: permissions,
          store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
          sessionStore: SessionStore(directory: root.appendingPathComponent("sessions")),
          configuration: .init(model: "test/model", workingDirectory: cwd, packsDirectory: root), id: id))
      }, output: { value in await mailbox.add(value) })
    addTeardownBlock { await connection.shutdown() }
    return connection
  }
  private func wait(_ mailbox: ACPMailbox, matching predicate: @escaping @Sendable (JSONValue) -> Bool) async throws -> JSONValue {
    for _ in 0..<600 {
      if let value = await mailbox.matching(predicate) { return value }
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    throw ACPError(message: "Timed out waiting for a protocol message")
  }
  private func response(_ id: Int, in mailbox: ACPMailbox) async throws -> JSONValue {
    try await wait(mailbox) { $0.objectValue?["id"]?.intValue == id }
  }
  private func initialize(_ connection: ACPConnection) async {
    await connection.receive(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": 1]])
  }
  private func create(_ connection: ACPConnection, root: URL, mailbox: ACPMailbox) async throws -> String {
    await initialize(connection)
    await connection.receive(["jsonrpc": "2.0", "id": 1, "method": "session/new",
      "params": ["cwd": .string(root.path), "mcpServers": []]])
    let result = try await response(1, in: mailbox)
    return try XCTUnwrap(result.objectValue?["result"]?.objectValue?["sessionId"]?.stringValue)
  }
  private func send(_ connection: ACPConnection, id: Int = 2, session: String) async {
    await connection.receive(["jsonrpc": "2.0", "id": .int(id), "method": "session/prompt",
      "params": ["sessionId": .string(session), "prompt": [["type": "text", "text": "Do the task."]]]])
  }

  func testInitializeRequiresNoSessionAndNegotiatesVersion() async throws {
    let mailbox = ACPMailbox()
    let connection = ACPConnection(version: "test", factory: { _, _, _, _ in
      throw ACPError(message: "Factory must not run during initialization")
    }, output: { await mailbox.add($0) })
    await connection.receive(["jsonrpc": "2.0", "id": 0, "method": "initialize", "params": ["protocolVersion": 999]])
    let reply = try await response(0, in: mailbox)
    XCTAssertEqual(reply.objectValue?["result"]?.objectValue?["protocolVersion"]?.intValue, 1)
    XCTAssertEqual(reply.objectValue?["result"]?.objectValue?["agentCapabilities"]?.objectValue?["loadSession"]?.boolValue, false)
    await connection.shutdown()
  }

  func testInvalidJSONAndUnknownRequestsAndNotifications() async throws {
    let mailbox = ACPMailbox(), mock = MockOpenRouterService()
    let connection = connection(mock: mock, root: try root(), mailbox: mailbox)
    await connection.receive(line: Data("{".utf8))
    await connection.receive(["jsonrpc": "2.0", "method": "unknown"])
    var messages = await mailbox.all()
    XCTAssertEqual(messages.count, 1)
    XCTAssertEqual(messages[0].objectValue?["error"]?.objectValue?["code"]?.intValue, -32700)
    await connection.receive(["jsonrpc": "2.0", "id": 5, "method": "session/new"])
    let beforeInitialization = try await response(5, in: mailbox)
    XCTAssertEqual(beforeInitialization.objectValue?["error"]?.objectValue?["code"]?.intValue, -32002)
    await initialize(connection)
    await connection.receive(["jsonrpc": "2.0", "id": 6, "method": "unknown"])
    messages = await mailbox.all()
    XCTAssertEqual(messages.last?.objectValue?["error"]?.objectValue?["code"]?.intValue, -32601)
    await connection.shutdown()
  }

  func testPromptStreamsOnceAndPersistsRunAndTranscript() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.textChunk("hello", model: "served/model"), Fixtures.usageChunk(cost: 0.01)]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox)
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    let reply = try await response(2, in: mailbox)
    XCTAssertEqual(reply.objectValue?["result"]?.objectValue?["stopReason"]?.stringValue, "end_turn")
    let messages = await mailbox.all()
    let chunks = messages.compactMap { $0.objectValue?["params"]?.objectValue?["update"]?.objectValue?["content"]?.objectValue?["text"]?.stringValue }
    XCTAssertEqual(chunks.joined(), "hello")
    let records = try RunRecordStore(url: root.appendingPathComponent("runs.jsonl")).all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].sessionId, session)
    XCTAssertEqual(records[0].stopReason, .completed)
    XCTAssertTrue(records[0].routedModels.contains("served/model"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("sessions/\(session).jsonl").path))
    await connection.shutdown()
  }

  func testPermissionRequiresRecognizedExplicitAllow() async throws {
    for option in ["allow-once", "allow-always", "reject-once"] {
      let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
      mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "mutate", arguments: "{}")], [Fixtures.textChunk("done")]]
      let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [Mutation()])
      let session = try await create(connection, root: root, mailbox: mailbox)
      await send(connection, session: session)
      let question = try await wait(mailbox) { $0.objectValue?["method"]?.stringValue == "session/request_permission" }
      let callID = try XCTUnwrap(question.objectValue?["params"]?.objectValue?["toolCall"]?.objectValue?["toolCallId"]?.stringValue)
      let pending = toolUpdates(await mailbox.all())
      XCTAssertEqual(pending.count, 1, "Call must be announced before its permission question")
      XCTAssertEqual(pending.first?["toolCallId"]?.stringValue, callID)
      await connection.receive(["jsonrpc": "2.0", "id": question.objectValue!["id"]!,
        "result": ["outcome": ["outcome": "selected", "optionId": .string(option)]]])
      _ = try await response(2, in: mailbox)
      let record = try XCTUnwrap(RunRecordStore(url: root.appendingPathComponent("runs.jsonl")).all().first)
      XCTAssertEqual(record.deniedCalls ?? 0, option == "allow-once" ? 0 : 1)
      let updates = toolUpdates(await mailbox.all())
      XCTAssertEqual(Set(updates.compactMap { $0["toolCallId"]?.stringValue }), [callID])
      XCTAssertEqual(updates.compactMap { $0["status"]?.stringValue }, option == "allow-once"
        ? ["pending", "in_progress", "completed"] : ["pending", "failed"])
      await connection.shutdown()
    }
  }

  func testCancellationReleasesPendingPermissionAndRecordsBeforeReply() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "mutate", arguments: "{}")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [Mutation()])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await wait(mailbox) { $0.objectValue?["method"]?.stringValue == "session/request_permission" }
    await connection.receive(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": .string(session)]])
    let reply = try await response(2, in: mailbox)
    XCTAssertEqual(reply.objectValue?["result"]?.objectValue?["stopReason"]?.stringValue, "cancelled")
    let updates = toolUpdates(await mailbox.all())
    XCTAssertEqual(updates.last?["status"]?.stringValue, "failed")
    XCTAssertEqual(try RunRecordStore(url: root.appendingPathComponent("runs.jsonl")).all().count, 1)
    await connection.shutdown()
  }

  func testCloseDuringPermissionWaitDrainsTurnAndRemovesSession() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "mutate", arguments: "{}")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [Mutation()])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await wait(mailbox) { $0.objectValue?["method"]?.stringValue == "session/request_permission" }
    await connection.receive(["jsonrpc": "2.0", "id": 3, "method": "session/close", "params": ["sessionId": .string(session)]])
    _ = try await response(3, in: mailbox)
    await send(connection, id: 4, session: session)
    let reply = try await response(4, in: mailbox)
    XCTAssertNotNil(reply.objectValue?["error"])
    await connection.shutdown()
  }

  func testEOFReleasesPermissionsAndDoesNotSendMoreMessages() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "mutate", arguments: "{}")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [Mutation()])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await wait(mailbox) { $0.objectValue?["method"]?.stringValue == "session/request_permission" }
    let before = await mailbox.all().count
    await connection.shutdown()
    let after = await mailbox.all().count
    XCTAssertEqual(before, after)
    XCTAssertEqual(try RunRecordStore(url: root.appendingPathComponent("runs.jsonl")).all().count, 1)
  }

  func testContentAndFramingValidation() throws {
    let text = try ACPConnection.prompt([["type": "resource_link", "name": "source", "uri": "file:///outside/file"]])
    XCTAssertTrue(text.contains("file:///outside/file"))
    XCTAssertThrowsError(try ACPConnection.prompt([["type": "image", "data": "x"]]))
    var framer = ACPLineFramer()
    XCTAssertTrue(try framer.append(Data("{\"text\":\"".utf8)).isEmpty)
    let lines = try framer.append(Data("hello\"}\r\n\n{}\n".utf8))
    XCTAssertEqual(lines.count, 2)
    try framer.finish()
    _ = try framer.append(Data("incomplete".utf8))
    XCTAssertThrowsError(try framer.finish())
    var oversized = ACPLineFramer()
    XCTAssertThrowsError(try oversized.append(Data(repeating: 120, count: ACPConnection.maximumMessageBytes + 1)))
  }

  func testSecondPromptIsRefusedWhileFirstAwaitsPermission() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "mutate", arguments: "{}")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [Mutation()])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await wait(mailbox) { $0.objectValue?["method"]?.stringValue == "session/request_permission" }
    await send(connection, id: 3, session: session)
    let reply = try await response(3, in: mailbox)
    XCTAssertEqual(reply.objectValue?["error"]?.objectValue?["code"]?.intValue, -32000)
    await connection.shutdown()
  }

  func testPermissionTimeoutDeniesAndCompletes() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "mutate", arguments: "{}")], [Fixtures.textChunk("denied")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [Mutation()], timeout: 1)
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await response(2, in: mailbox)
    XCTAssertEqual(try RunRecordStore(url: root.appendingPathComponent("runs.jsonl")).all().first?.deniedCalls, 1)
    await connection.shutdown()
  }

  func testInvalidCwdAndMCPTransportDoNotCreateSessions() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    let connection = connection(mock: mock, root: root, mailbox: mailbox)
    await initialize(connection)
    await connection.receive(["jsonrpc": "2.0", "id": 1, "method": "session/new",
      "params": ["cwd": "relative", "mcpServers": []]])
    let cwdError = try await response(1, in: mailbox)
    XCTAssertNotNil(cwdError.objectValue?["error"])
    await connection.receive(["jsonrpc": "2.0", "id": 2, "method": "session/new",
      "params": ["cwd": .string(root.path), "mcpServers": [
        ["type": "http", "name": "server", "command": "/bin/true", "args": [], "env": []]]]])
    let transportError = try await response(2, in: mailbox)
    XCTAssertNotNil(transportError.objectValue?["error"])
    for (index, server) in [
      JSONValue.object(["name": "server", "command": "/bin/true", "args": ["bad\0argument"], "env": []]),
      JSONValue.object(["name": "server", "command": "/bin/true", "args": [],
        "env": [["name": "VAR", "value": "bad\0value"]]]),
    ].enumerated() {
      await connection.receive(["jsonrpc": "2.0", "id": .int(3 + index), "method": "session/new",
        "params": ["cwd": .string(root.path), "mcpServers": .array([server])]])
      let error = try await response(3 + index, in: mailbox)
      XCTAssertNotNil(error.objectValue?["error"], "POSIX arguments cannot contain NUL")
    }
    await connection.shutdown()
  }

  func testMCPEnvironmentIsLiteralWhenRequestedByACP() {
    let environment = ProcessMCPTransport.environment(
      for: MCPServerConfig(command: "/bin/true", env: ["COPY": "${PRIVATE_VALUE}"]),
      inheriting: ["PRIVATE_VALUE": "secret", "OPENROUTER_API_KEY": "withheld"],
      redacting: ["PRIVATE_VALUE", "OPENROUTER_API_KEY"], expandingValues: false)
    XCTAssertEqual(environment, ["COPY": "${PRIVATE_VALUE}"])
  }

  func testMCPProcessUsesSessionWorkingDirectory() async throws {
    let root = try root()
    let transport = ProcessMCPTransport(name: "cwd-probe",
      config: .init(command: "/bin/pwd"), workingDirectory: root)
    addTeardownBlock { await transport.stop() }
    let stream = try await transport.start()
    let drained = try await withDeadline(seconds: 3) {
      var lines: [String] = []
      for await line in stream { lines.append(line) }
      return lines
    }
    await transport.stop()
    let lines = try XCTUnwrap(drained, "an exited MCP process must close its output stream")
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(try XCTUnwrap(FileIdentity.of(try XCTUnwrap(lines.first))),
      try XCTUnwrap(FileIdentity.of(root.path)))
  }

  func testMCPExitDrainsMultipleOutputChunksBeforeEOF() async throws {
    let root = try root()
    let transport = ProcessMCPTransport(name: "drain-probe", config: .init(command: "/bin/sh",
      args: ["-c", "i=0; while [ \"$i\" -lt 2000 ]; do printf 'line-%s\\n' \"$i\"; i=$((i + 1)); done"]),
      workingDirectory: root)
    addTeardownBlock { await transport.stop() }
    let stream = try await transport.start()
    let drained = try await withDeadline(seconds: 5) {
      var lines: [String] = []
      for await line in stream { lines.append(line) }
      return lines
    }
    let lines = try XCTUnwrap(drained, "an exited process must finish even with idle stderr")
    XCTAssertEqual(lines, (0..<2000).map { "line-\($0)" })
  }

  func testMCPConcurrentStopKillsStubbornDescendantsAndAllowsRestart() async throws {
    let root = try root()
    let transport = ProcessMCPTransport(name: "tree-probe", config: .init(command: "/bin/sh",
      args: ["-c", "sh -c 'trap \"\" TERM; while :; do sleep 1; done' & echo $!; read answer"]),
      workingDirectory: root)
    addTeardownBlock { await transport.stop() }
    for _ in 0..<2 {
      let stream = try await transport.start()
      var iterator = stream.makeAsyncIterator()
      let line = await iterator.next()
      let pid = try XCTUnwrap(Int32(try XCTUnwrap(line)))
      async let first: Void = transport.stop()
      async let second: Void = transport.stop()
      _ = await (first, second)
      // Signal delivery/reaping can trail shutdown by a scheduling slice.
      for _ in 0..<100 where kill(pid, 0) == 0 {
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      if kill(pid, 0) != 0 { continue }
      let state = try await ShellRunner.run("ps -o stat= -p \(pid)", cwd: root, timeoutSeconds: 3)
      let label = state.output.trimmingCharacters(in: .whitespacesAndNewlines)
      XCTAssertTrue(label.isEmpty || label.hasPrefix("Z"), "MCP descendant survived shutdown: \(label)")
    }
  }

  func testFactoryPermissionsWaitUntilClientKnowsSessionId() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done")]]
    let connection = ACPConnection(version: "test", factory: { id, cwd, _, permissions in
      let decision = await permissions.decide(.init(toolName: "mcp_start", summary: "Start test server",
        argumentsJSON: "{}", tier: .sensitive))
      guard case .allow = decision else { throw CancellationError() }
      return ACPSession(session: Session(service: mock, tools: [], permissions: permissions,
        store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
        configuration: .init(model: "test/model", workingDirectory: cwd), id: id))
    }, output: { await mailbox.add($0) })
    addTeardownBlock { await connection.shutdown() }
    let session = try await create(connection, root: root, mailbox: mailbox)
    let before = await mailbox.all()
    XCTAssertFalse(before.contains { $0.objectValue?["method"]?.stringValue == "session/request_permission" })
    await send(connection, session: session)
    let question = try await wait(mailbox) { $0.objectValue?["method"]?.stringValue == "session/request_permission" }
    XCTAssertEqual(question.objectValue?["params"]?.objectValue?["sessionId"]?.stringValue, session)
    await connection.receive(["jsonrpc": "2.0", "id": question.objectValue!["id"]!,
      "result": ["outcome": ["outcome": "selected", "optionId": "allow-once"]]])
    _ = try await response(2, in: mailbox)
    await connection.shutdown()
  }

  func testConcurrentSameNameCallsHaveDistinctCorrelatedResults() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService(), order = ACPFinishOrder()
    mock.chunkScripts = [[
      Fixtures.toolCallChunk(id: "c1", name: "read_test", arguments: "{\"value\":\"first\"}"),
      Fixtures.toolCallChunk(id: "c2", name: "read_test", arguments: "{\"value\":\"second\"}", index: 1),
    ], [Fixtures.textChunk("done")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [ConcurrentRead(order: order)])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await response(2, in: mailbox)
    let finished = await order.values
    XCTAssertEqual(finished, ["second", "first"], "Exercise out-of-order execution")
    let updates = toolUpdates(await mailbox.all())
    let calls = updates.filter { $0["sessionUpdate"]?.stringValue == "tool_call" }
    XCTAssertEqual(calls.count, 2)
    let ids = calls.compactMap { $0["toolCallId"]?.stringValue }
    XCTAssertEqual(Set(ids).count, 2)
    for (index, id) in ids.enumerated() {
      let sequence = updates.filter { $0["toolCallId"]?.stringValue == id }
      XCTAssertEqual(sequence.compactMap { $0["status"]?.stringValue }, ["pending", "in_progress", "completed"])
      let text = sequence.last?["content"]?.arrayValue?.first?.objectValue?["content"]?.objectValue?["text"]?.stringValue
      XCTAssertEqual(text, index == 0 ? "result: first" : "result: second")
    }
  }

  func testPresentationIDsStayUniqueWhenModelIDsRepeatAcrossTurns() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService(), order = ACPFinishOrder()
    let call = Fixtures.toolCallChunk(id: "reused", name: "read_test", arguments: "{}")
    mock.chunkScripts = [[call], [Fixtures.textChunk("done")], [call], [Fixtures.textChunk("done")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [ConcurrentRead(order: order)])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await response(2, in: mailbox)
    await send(connection, id: 3, session: session)
    _ = try await response(3, in: mailbox)
    let calls = toolUpdates(await mailbox.all()).filter { $0["sessionUpdate"]?.stringValue == "tool_call" }
    XCTAssertEqual(calls.count, 2)
    XCTAssertEqual(Set(calls.compactMap { $0["toolCallId"]?.stringValue }).count, 2)
  }

  func testCancellationClosesRunningConcurrentToolBeforeReply() async throws {
    let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService(), order = ACPFinishOrder()
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "wait", name: "read_test", arguments: "{\"value\":\"wait\"}")]]
    let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [ConcurrentRead(order: order)])
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await wait(mailbox) {
      $0.objectValue?["params"]?.objectValue?["update"]?.objectValue?["status"]?.stringValue == "in_progress"
    }
    await connection.receive(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": .string(session)]])
    let reply = try await response(2, in: mailbox)
    XCTAssertEqual(reply.objectValue?["result"]?.objectValue?["stopReason"]?.stringValue, "cancelled")
    let messages = await mailbox.all()
    XCTAssertEqual(toolUpdates(messages).compactMap { $0["status"]?.stringValue }, ["pending", "in_progress", "failed"])
    let finalUpdate = messages.lastIndex { $0.objectValue?["params"]?.objectValue?["update"]?.objectValue?["status"]?.stringValue == "failed" }
    let responseIndex = messages.firstIndex { $0.objectValue?["id"]?.intValue == 2 }
    XCTAssertLessThan(try XCTUnwrap(finalUpdate), try XCTUnwrap(responseIndex))
  }

  func testToolFailureAndPreflightFailureCloseTheirLifecycles() async throws {
    for name in ["read_test", "unknown"] {
      let root = try root(), mailbox = ACPMailbox(), mock = MockOpenRouterService(), order = ACPFinishOrder()
      mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: name, arguments: "{\"value\":\"error\"}")], [Fixtures.textChunk("done")]]
      let connection = connection(mock: mock, root: root, mailbox: mailbox, tools: [ConcurrentRead(order: order)])
      let session = try await create(connection, root: root, mailbox: mailbox)
      await send(connection, session: session)
      _ = try await response(2, in: mailbox)
      let updates = toolUpdates(await mailbox.all())
      XCTAssertEqual(updates.compactMap { $0["status"]?.stringValue }, name == "read_test"
        ? ["pending", "in_progress", "failed"] : ["pending", "failed"])
    }
  }

  func testProtocolErrorScrubsSecretsBeforeTruncating() async throws {
    let root = try root(), mailbox = ACPMailbox()
    let secret = "sk-or-v1-" + String(repeating: "a1b2c3d4", count: 8)
    let connection = ACPConnection(version: "test", factory: { _, _, _, _ in
      throw ACPError(message: String(repeating: "x", count: 1_970) + " " + secret)
    }, output: { await mailbox.add($0) })
    addTeardownBlock { await connection.shutdown() }
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    let reply = try await response(2, in: mailbox)
    let text = try XCTUnwrap(reply.objectValue?["error"]?.objectValue?["message"]?.stringValue)
    XCTAssertFalse(text.contains("sk-or-v1-"))
    XCTAssertLessThanOrEqual(text.count, 2_000)
  }

  func testOutputWriterFramesJSONAndReportsWriteFailure() async throws {
    let pipe = Pipe()
    let writer = ACPOutputWriter(handle: pipe.fileHandleForWriting)
    try await writer.write(["jsonrpc": "2.0", "id": 1, "result": ["text": "line\nnext"]])
    try pipe.fileHandleForWriting.close()
    let bytes = try XCTUnwrap(pipe.fileHandleForReading.readToEnd())
    XCTAssertEqual(bytes.filter { $0 == 10 }.count, 1, "embedded newlines must be escaped")
    XCTAssertNotNil(try JSONDecoder().decode(JSONValue.self, from: bytes).objectValue?["result"])
    do {
      try await writer.write([:])
      XCTFail("closed output must fail")
    } catch { }
    let failed = await writer.failed
    XCTAssertTrue(failed)
    try pipe.fileHandleForReading.close()
  }

  func testInputStopWakesAnIdlePipeWithoutWaitingForEOF() async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
    let reader = ACPInputReader(handle: pipe.fileHandleForReading)
    let drain = Task { () throws -> Int in
      var count = 0
      for try await data in reader.stream { count += data.count }
      return count
    }
    reader.stop()
    let bytes = try await withDeadline(seconds: 2) { try await drain.value }
    XCTAssertEqual(bytes, 0)
  }

  func testOutputBackpressureHasABoundedDeadline() async throws {
    let pipe = Pipe()
    defer { try? pipe.fileHandleForReading.close(); try? pipe.fileHandleForWriting.close() }
    let writer = ACPOutputWriter(handle: pipe.fileHandleForWriting, writeTimeoutMilliseconds: 50)
    let start = Date()
    do {
      try await writer.write(["text": .string(String(repeating: "x", count: 1_048_576))])
      XCTFail("an unread pipe must time out")
    } catch {
      XCTAssertTrue(String(describing: error).contains("timed out"))
    }
    XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    let failed = await writer.failed
    XCTAssertTrue(failed)
  }

  func testCancellationFromRunningObserverPreventsASynchronousFileWrite() async throws {
    let root = try root(), mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "write", name: "write_file",
      arguments: #"{"path":"must-not-exist","content":"cancelled"}"#)]]
    let session = Session(service: mock, tools: [WriteFileTool(root: root)],
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      configuration: .init(model: "test/model", packsDirectory: root))
    try await session.observeToolActivity { activity in
      if activity.phase == .running { await session.interrupt() }
    }
    _ = try await Events.drain(await session.send("write"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("must-not-exist").path))
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .interrupted)
    let rows = try RunRecordStore(url: root.appendingPathComponent("runs.jsonl")).all()
    XCTAssertEqual(rows.count, 1)
  }

  func testConcurrentShutdownCallersBothWaitForResourceCleanup() async throws {
    let root = try root(), mailbox = ACPMailbox()
    let cleaning = Latch(), release = Latch(), finished = Latch()
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done")]]
    let connection = ACPConnection(version: "test", factory: { id, _, _, permissions in
      ACPSession(session: Session(service: mock, tools: [], permissions: permissions,
        store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
        configuration: .init(model: "test/model", packsDirectory: root), id: id), cleanup: {
          await cleaning.arrive()
          await release.wait(for: 1)
        })
    }, output: { await mailbox.add($0) })
    let session = try await create(connection, root: root, mailbox: mailbox)
    await send(connection, session: session)
    _ = try await response(2, in: mailbox)
    let first = Task { await connection.shutdown() }
    await cleaning.wait(for: 1)
    let second = Task { await connection.shutdown(); await finished.arrive() }
    try await Task.sleep(nanoseconds: 50_000_000)
    let before = await finished.count
    XCTAssertEqual(before, 0, "a second shutdown must not allow the process to exit during cleanup")
    await release.arrive()
    await first.value
    await second.value
    let calls = await cleaning.count
    XCTAssertEqual(calls, 1)
  }
}
