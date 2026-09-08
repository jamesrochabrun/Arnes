import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class ToolGuidanceTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-guidance-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private struct Probe: AgentTool {
    let name = "probe"
    let description = "Original contract."
    let parameters: JSONValue = ["type": "object", "properties": [:]]
    var permission: ToolPermission { .readOnly }
    var changeFile: URL? = nil
    func execute(arguments: [String: JSONValue]) async throws -> String {
      if let changeFile {
        try #"{"probe":"Next turn guidance."}"#.write(to: changeFile, atomically: true, encoding: .utf8)
      }
      return "ok"
    }
  }

  func testAbsentInvalidAndOversizedOverridesLeaveDefaults() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("openai.tools.json")
    for contents in [nil, "not JSON", #"{"probe":42}"#, String(repeating: "x", count: 65_537)] {
      if let contents { try contents.write(to: file, atomically: true, encoding: .utf8) }
      let pack = PromptPack.load(for: .openai, overridesDirectory: root)
      XCTAssertEqual(pack.toolGuidance.description(for: Probe()), Probe().description)
    }
    let guidance = ToolGuidance(entries: ["probe": "  ", "absent": "Does not create a tool."])
    XCTAssertEqual(guidance.description(for: Probe()), Probe().description)
  }

  func testGuidanceAppendsWithoutChangingSchemaAcrossDialects() throws {
    let probe = Probe()
    let guidance = ToolGuidance(entries: ["probe": "Use exact arguments."])
    let rendered = guidance.rendering(probe)
    XCTAssertEqual(rendered.name, probe.name)
    XCTAssertEqual(rendered.parameters, probe.parameters)
    XCTAssertEqual(rendered.permission, probe.permission)
    let encoder = JSONEncoder()
    let definitions = [
      try encoder.encode(rendered.toolDefinition),
      try encoder.encode(MessagesTranslator.tool(rendered)),
      try encoder.encode(ResponsesTranslator.tool(rendered)),
    ]
    for data in definitions {
      let text = String(decoding: data, as: UTF8.self)
      XCTAssertTrue(text.contains("Original contract."))
      XCTAssertTrue(text.contains("Use exact arguments."))
    }
  }

  func testGuidanceNeverFollowsALeafSymlink() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target.json")
    try #"{"probe":"Should not load."}"#.write(to: target, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("other.tools.json"),
      withDestinationURL: target)
    XCTAssertEqual(PromptPack.load(for: .other, overridesDirectory: root)
      .toolGuidance.description(for: Probe()), Probe().description)
  }

  func testFamilyIsolationAndSubagentInheritance() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    try #"{"probe":"Family guidance."}"#.write(
      to: root.appendingPathComponent("openai.tools.json"), atomically: true, encoding: .utf8)
    XCTAssertTrue(PromptPack.load(for: .openai, overridesDirectory: root)
      .toolGuidance.description(for: Probe()).contains("Family guidance."))
    XCTAssertEqual(PromptPack.load(for: .anthropic, overridesDirectory: root)
      .toolGuidance.description(for: Probe()), Probe().description)
    let child = Session.Configuration(packsDirectory: root)
      .forSubagent(named: "worker", model: "test/model", systemSuffix: "Work.")
    XCTAssertEqual(child.packsDirectory, root)
  }

  func testGuidanceSnapshotIsStableWithinTurnAndReloadsNextTurn() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("other.tools.json")
    try #"{"probe":"First turn guidance."}"#.write(to: file, atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: "{}")],
      [Fixtures.textChunk("done")],
      [Fixtures.textChunk("again")],
    ]
    let session = Session(service: mock, tools: [Probe(changeFile: file)],
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      configuration: .init(model: "test/model", packsDirectory: root))
    _ = try await Events.drain(await session.send("first"))
    _ = try await Events.drain(await session.send("second"))
    XCTAssertEqual(mock.requests.count, 3)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let definitions = try mock.requests.map { try encoder.encode($0.tools) }
    XCTAssertEqual(definitions[0], definitions[1])
    XCTAssertTrue(String(decoding: definitions[0], as: UTF8.self).contains("First turn guidance."))
    XCTAssertTrue(String(decoding: definitions[2], as: UTF8.self).contains("Next turn guidance."))
    let diagnostic = try await session.availableToolDefinitions()
    XCTAssertEqual(try encoder.encode(diagnostic), try encoder.encode(mock.requests[2].tools ?? []))
  }

  func testActualRequestsKeepGuidanceStableAcrossEveryDialectAndForcedChat() async throws {
    for (model, family, dialect) in [
      ("test/model", "other", DialectOverride.chat),
      ("anthropic/claude-test", "anthropic", .chat),
      ("openai/gpt-test", "openai", .chat),
      ("anthropic/claude-test", "anthropic", .auto),
      ("openai/gpt-test", "openai", .auto),
    ] {
      let root = try directory()
      defer { try? FileManager.default.removeItem(at: root) }
      let file = root.appendingPathComponent("\(family).tools.json")
      try #"{"probe":"First turn guidance.","view_image":"Never offer a withheld tool."}"#
        .write(to: file, atomically: true, encoding: .utf8)
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: model))
      mock.chunkScripts = [
        [Fixtures.toolCallChunk(id: "call", name: "probe", arguments: "{}")],
        [Fixtures.textChunk("done")], [Fixtures.textChunk("again")],
      ]
      mock.messagesEventScripts = [
        [Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"call","name":"probe","input":{}}}"#),
         Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"}}"#)],
        [Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#)],
        [Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"again"}}"#)],
      ]
      mock.responsesEventScripts = [
        [Fixtures.responsesEvent(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call","name":"probe","arguments":"{}","id":"item"}}"#)],
        [Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"done"}"#)],
        [Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"again"}"#)],
      ]
      let session = Session(service: mock, tools: [Probe(changeFile: file), ViewImageTool(root: root)],
        store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
        dialectStore: DialectVerdictStore(url: root.appendingPathComponent("dialects.jsonl")),
        configuration: .init(model: model, dialect: dialect, packsDirectory: root))
      _ = try await Events.drain(await session.send("first"))
      _ = try await Events.drain(await session.send("second"))
      let requests = mock.requests.map(Fixtures.jsonValue)
        + mock.messagesRequests.map(Fixtures.jsonValue) + mock.responsesRequests.map(Fixtures.jsonValue)
      XCTAssertEqual(requests.count, 3, "\(model) \(dialect)")
      guard requests.count == 3 else { continue }
      XCTAssertEqual(requests[0]["tools"], requests[1]["tools"])
      let system: (JSONValue) -> JSONValue? = {
        $0["system"] ?? $0["instructions"] ?? $0["messages"]?.arrayValue?.first
      }
      XCTAssertEqual(system(requests[0]), system(requests[1]))
      for (index, request) in requests.enumerated() {
        let tools = try XCTUnwrap(request["tools"]?.arrayValue)
        XCTAssertEqual(tools.count, 1, "vision gate must precede guidance")
        let definition = tools[0]["function"] ?? tools[0]
        XCTAssertEqual(definition["name"]?.stringValue, "probe")
        XCTAssertEqual(definition["parameters"] ?? definition["input_schema"], Probe().parameters)
        XCTAssertEqual(definition["description"]?.stringValue,
          "Original contract.\n\nModel guidance:\n" + (index < 2 ? "First turn guidance." : "Next turn guidance."))
      }
    }
  }

  func testModelSwitchReloadsFamilyAndAbsentOverridesDoNotPersist() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    for family in ["openai", "anthropic"] {
      try JSONEncoder().encode(["probe": "\(family) guidance"]).write(
        to: root.appendingPathComponent("\(family).tools.json"))
    }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "openai/gpt-test"),
      Fixtures.manifestModel(id: "anthropic/claude-test"), Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = Array(repeating: [Fixtures.textChunk("done")], count: 3)
    let session = Session(service: mock, tools: [Probe()],
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      configuration: .init(model: "openai/gpt-test", dialect: .chat, packsDirectory: root))
    for model in ["openai/gpt-test", "anthropic/claude-test", "test/model"] {
      _ = try await session.setModel(model)
      _ = try await Events.drain(await session.send("continue"))
    }
    for (index, family) in ["openai", "anthropic", "other"].enumerated() {
      let definition = Fixtures.jsonValue(mock.requests[index])["tools"]?.arrayValue?.first?["function"]
      XCTAssertEqual(definition?["description"]?.stringValue, Probe().description
        + (family == "other" ? "" : "\n\nModel guidance:\n\(family) guidance"))
    }
  }
}
