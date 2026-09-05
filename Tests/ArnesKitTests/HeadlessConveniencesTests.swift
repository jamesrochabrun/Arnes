import Foundation
import OpenRouterSwift
import XCTest
@testable import ArnesKit

/// H1 headless conveniences, Kit side: a pinned session id (`Session.init(id:)`,
/// `Agent.run(sessionId:)`), the offered-tools seam (`Session.offeredTools` /
/// `availableToolDefinitions()`), the `/schema` dial (`setOutputSchema` /
/// `currentOutputSchema`, not persisted) and `SessionStore.entries(id:)`.
final class HeadlessConveniencesTests: XCTestCase {
  private static let pinned = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"

  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h1-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDialectStore() -> DialectVerdictStore {
    DialectVerdictStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h1-verdicts-\(UUID().uuidString).jsonl"))
  }

  private func tempSessionStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h1-sessions-\(UUID().uuidString)"))
  }

  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-h1-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func structuredEvent(in events: [AgentEvent]) -> (json: JSONValue?, valid: Bool)? {
    for event in events {
      if case .structuredOutput(let json, let valid, _) = event { return (json, valid) }
    }
    return nil
  }

  // MARK: --session-id

  func testAPinnedIdIsTheSessionsIdAndLandsOnTheTranscriptAndTheRecord() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0.01)]]
    let sessions = tempSessionStore()
    let records = tempRecordStore()
    let session = Session(
      service: mock, tools: [], store: records, sessionStore: sessions, dialectStore: tempDialectStore(),
      configuration: .init(model: "test/model"), id: Self.pinned)
    let id = await session.id
    XCTAssertEqual(id, Self.pinned)

    _ = try await Events.drain(await session.send("hi"))
    // The transcript is the pinned id's, with a real `meta` line (never the resuming trick).
    XCTAssertEqual(try sessions.list().map(\.id), [Self.pinned])
    XCTAssertEqual(try sessions.load(id: Self.pinned).meta.id, Self.pinned)
    let entries = try sessions.entries(id: Self.pinned)
    XCTAssertEqual(entries.first?.type, .meta)
    XCTAssertTrue(entries.contains { $0.type == .message && $0.role == "user" })
    // The run record carries it too.
    XCTAssertEqual(try records.all().last?.sessionId, Self.pinned)

    // Without the parameter the id is a fresh UUID, as always.
    let fresh = Session(
      service: mock, tools: [], store: records, dialectStore: tempDialectStore(),
      configuration: .init(model: "test/model"))
    let freshId = await fresh.id
    XCTAssertNotNil(UUID(uuidString: freshId))
    XCTAssertNotEqual(freshId, Self.pinned)
  }

  func testAgentRunPinsAFreshSessionsIdAndAResumedRunKeepsItsOwn() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let sessions = tempSessionStore()
    let agent = Agent(
      service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions,
      configuration: .init(model: "test/model"))
    let first = try await agent.run(task: "hi", model: "test/model", sessionId: Self.pinned)
    XCTAssertEqual(first.sessionId, Self.pinned)
    XCTAssertEqual(try sessions.list().map(\.id), [Self.pinned])

    // A resumed run keeps its transcript's id; a pin passed beside `resuming` is ignored.
    let loaded = try sessions.load(id: Self.pinned)
    let second = try await agent.run(
      task: "again", model: "test/model", resuming: loaded, sessionId: UUID().uuidString)
    XCTAssertEqual(second.sessionId, Self.pinned)
    XCTAssertEqual(try sessions.list().map(\.id), [Self.pinned], "no second transcript")
    XCTAssertEqual(try sessions.load(id: Self.pinned).turnCount, 2)
  }

  // MARK: Offered tools

  func testOfferedToolsIsTheRequestsToolListForATextAndAVisionModel() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools: [any AgentTool] = [ViewImageTool(root: root), SpyTool()]
    let text = try JSONDecoder().decode(OpenRouterModel.self, from: Data(Fixtures.manifestModel(id: "acme/text").utf8))
    let vision = try JSONDecoder().decode(OpenRouterModel.self, from: Data(Fixtures.visionManifestModel(id: "acme/vision").utf8))
    // The pure rule: definition order, minus what the manifest rules out.
    XCTAssertEqual(
      Session.offeredTools(tools, profile: ModelProfile(model: text), configuration: .init(model: "acme/text")).map(\.name),
      ["spy"])
    XCTAssertEqual(
      Session.offeredTools(tools, profile: ModelProfile(model: vision), configuration: .init(model: "acme/vision")).map(\.name),
      ["view_image", "spy"])

    // And the session's view of it equals the first request's `tools`, both ways.
    for (model, expected) in [("acme/text", ["spy"]), ("acme/vision", ["view_image", "spy"])] {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(
        Fixtures.manifestModel(id: "acme/text"), Fixtures.visionManifestModel(id: "acme/vision"))
      mock.chunkScripts = [[Fixtures.textChunk("ok", model: model), Fixtures.usageChunk(cost: 0.01, model: model)]]
      let session = Session(
        service: mock, tools: tools, store: tempRecordStore(), dialectStore: tempDialectStore(),
        configuration: .init(model: model))
      let offered = try await session.availableToolDefinitions().map(\.function.name)
      XCTAssertEqual(offered, expected, model)
      XCTAssertEqual(mock.requests.count, 0, "introspection never sends")
      let toolset = await session.toolDefinitions.map(\.function.name)
      XCTAssertEqual(toolset, ["view_image", "spy"], "the toolset lists everything")
      _ = try await Events.drain(await session.send("look"))
      XCTAssertEqual(mock.requests.first?.tools?.map(\.function.name), offered, model)
    }
  }

  func testAModelWhoseManifestTakesNoToolsIsOfferedNone() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "acme/plain", supportsTools: false))
    let session = Session(
      service: mock, tools: [SpyTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "acme/plain"))
    let offered = try await session.availableToolDefinitions()
    XCTAssertEqual(offered.count, 0)
    let toolset = await session.toolDefinitions
    XCTAssertEqual(toolset.map(\.function.name), ["spy"])
  }

  // MARK: /schema

  private static let schema: JSONValue = [
    "type": "object",
    "properties": ["answer": ["type": "string"]],
    "required": ["answer"],
    "additionalProperties": false,
  ]

  private static func structuredManifestModel(id: String) -> String {
    """
    {"id":"\(id)","context_length":8000,"supported_parameters":["tools","response_format"],"pricing":{"prompt":"0.000001","completion":"0.000002"}}
    """
  }

  private static func reply(_ text: String) -> ChatCompletionResponse {
    let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    return Fixtures.response("""
      {"id":"gen-s","model":"test/model","choices":[{"index":0,"message":{"role":"assistant","content":\(encoded)},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":8,"cost":0}}
      """)
  }

  func testSetOutputSchemaDrivesTheNextTurnsSideRequestAndIsNotPersisted() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.structuredManifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("three"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [Self.reply(#"{"answer":"x"}"#)]
    let sessions = tempSessionStore()
    let session = Session(
      service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions, dialectStore: tempDialectStore(),
      configuration: .init(model: "test/model"))
    let before = await session.currentOutputSchema
    XCTAssertNil(before, "no --output-schema → no schema")
    _ = try await Events.drain(await session.send("one?"))
    XCTAssertEqual(mock.requests.count, 1, "no schema → no side request")

    // `/schema <json>`: the next finished turn makes the structured side request.
    let schema = try OutputSchema(schema: Self.schema)
    await session.setOutputSchema(schema)
    let current = await session.currentOutputSchema
    XCTAssertEqual(current?.schema, Self.schema)
    XCTAssertEqual(current?.name, schema.name)
    let events = try await Events.drain(await session.send("two?"))
    XCTAssertEqual(mock.requests.count, 3, "the loop's request plus the structured side request")
    let side = mock.requests[2]
    XCTAssertEqual(Fixtures.jsonValue(side.responseFormat)["type"], "json_schema")
    XCTAssertEqual(Fixtures.jsonValue(side.responseFormat)["json_schema"]?["schema"], Self.schema)
    let structured = try XCTUnwrap(structuredEvent(in: events))
    XCTAssertTrue(structured.valid)
    XCTAssertEqual(structured.json, ["answer": "x"])
    let record = await session.lastRecord
    XCTAssertEqual(record?.structuredOutput, ["answer": "x"])

    // `/schema off`: no side request again.
    await session.setOutputSchema(nil)
    let cleared = await session.currentOutputSchema
    XCTAssertNil(cleared)
    let plainEvents = try await Events.drain(await session.send("three?"))
    XCTAssertEqual(mock.requests.count, 4)
    XCTAssertNil(structuredEvent(in: plainEvents))

    // Not persisted: nothing in the transcript names a schema, and a resume starts without one —
    // unless its own configuration passes `--output-schema`, which seeds the dial as on a fresh run.
    let id = await session.id
    let kinds = Set(try sessions.entries(id: id).map(\.type))
    XCTAssertEqual(kinds.subtracting([.meta, .message, .cost]), [])
    let loaded = try sessions.load(id: id)
    let resumed = Session(
      resuming: loaded, service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions,
      dialectStore: tempDialectStore(), configuration: .init(model: "test/model"))
    let resumedSchema = await resumed.currentOutputSchema
    XCTAssertNil(resumedSchema)
    let seeded = Session(
      resuming: loaded, service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions,
      dialectStore: tempDialectStore(), configuration: .init(model: "test/model", outputSchema: schema))
    let seededSchema = await seeded.currentOutputSchema
    XCTAssertEqual(seededSchema?.schema, Self.schema)
  }

  // MARK: SessionStore.entries

  func testEntriesReturnsTheLinesAsStoredAndThrowsForAMissingTranscript() throws {
    let sessions = tempSessionStore()
    let id = UUID().uuidString
    try sessions.append(.meta(id: id, model: "test/model", cwd: "/work"), to: id)
    try sessions.append(TranscriptEntry(message: .user("hi"), turn: 0), to: id)
    try sessions.append(TranscriptEntry(message: .assistant("hello"), turn: 0), to: id)
    let entries = try sessions.entries(id: id)
    XCTAssertEqual(entries.map(\.type), [.meta, .message, .message])
    XCTAssertEqual(entries[1].role, "user")
    XCTAssertEqual(entries[1].text, "hi")
    XCTAssertEqual(entries[2].role, "assistant")
    XCTAssertEqual(entries[2].text, "hello")
    XCTAssertThrowsError(try sessions.entries(id: UUID().uuidString))
  }
}
