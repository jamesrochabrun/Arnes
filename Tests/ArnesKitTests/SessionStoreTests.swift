import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class SessionStoreTests: XCTestCase {
  private func tempStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-sessions-\(UUID().uuidString)"))
  }

  func testRoundtripWithToolCalls() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: "/tmp"), to: id)
    try store.append(TranscriptEntry(message: .user("hi")), to: id)
    let toolCall = ToolCall(
      id: "c1",
      index: 0,
      function: .init(name: "bash", arguments: "{\"command\":\"ls\"}"))
    try store.append(
      TranscriptEntry(message: Message(role: .assistant, content: .text("running"), toolCalls: [toolCall])),
      to: id)
    try store.append(TranscriptEntry(message: .tool("exit 0", toolCallId: "c1")), to: id)
    try store.append(.cost(turnUSD: 0.02, sessionUSD: 0.02), to: id)

    let loaded = try store.load(id: id)
    XCTAssertEqual(loaded.messages.count, 3)
    XCTAssertEqual(loaded.model, "test/model")
    XCTAssertEqual(loaded.costUSD, 0.02, accuracy: 0.0001)
    XCTAssertEqual(loaded.turnCount, 1)
    let assistant = loaded.messages[1]
    XCTAssertEqual(assistant.toolCalls?.first?.id, "c1")
    XCTAssertEqual(assistant.toolCalls?.first?.function?.arguments, "{\"command\":\"ls\"}")
    XCTAssertEqual(loaded.messages[2].toolCallId, "c1")
  }

  func testModelChangeReplayWins() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "alpha/one", cwd: nil), to: id)
    try store.append(TranscriptEntry(message: .user("hi")), to: id)
    try store.append(.modelChange("openai/gpt-test"), to: id)

    let loaded = try store.load(id: id)
    XCTAssertEqual(loaded.model, "openai/gpt-test")
  }

  func testClearEntryResetsMessages() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    try store.append(TranscriptEntry(message: .user("old")), to: id)
    try store.append(.clear(), to: id)
    try store.append(TranscriptEntry(message: .user("new")), to: id)

    let loaded = try store.load(id: id)
    XCTAssertEqual(loaded.messages.count, 1)
    XCTAssertEqual(loaded.messages[0].content?.plainText, "new")
  }

  func testRenameShowsUpInList() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    try store.rename(id: id, name: "my-session")

    let list = try store.list()
    XCTAssertEqual(list.count, 1)
    XCTAssertEqual(list[0].id, id)
    XCTAssertEqual(list[0].name, "my-session")
  }

  func testSessionPersistsAndResumesAcrossInstances() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("first answer"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("second answer"), Fixtures.usageChunk(cost: 0.02)],
    ]
    let sessionStore = tempStore()
    let recordStore = RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-runs-\(UUID().uuidString).jsonl"))

    let first = Session(
      service: mock,
      tools: [],
      store: recordStore,
      sessionStore: sessionStore,
      configuration: .init(model: "test/model"))
    for try await _ in await first.send("turn one") { }

    // A "new process": load from disk and continue the conversation.
    let loaded = try sessionStore.load(id: first.id)
    XCTAssertEqual(loaded.costUSD, 0.01, accuracy: 0.0001)
    let resumed = Session(
      resuming: loaded,
      service: mock,
      tools: [],
      store: recordStore,
      sessionStore: sessionStore)
    for try await _ in await resumed.send("turn two") { }

    let secondRequest = mock.requests[1]
    // system + [user, assistant, user] — the resumed session carries prior history.
    XCTAssertEqual(secondRequest.messages.count, 4)
    XCTAssertEqual(secondRequest.messages[1].content?.plainText, "turn one")
    XCTAssertEqual(secondRequest.messages[2].content?.plainText, "first answer")
    let cost = await resumed.costUSD
    XCTAssertEqual(cost, 0.03, accuracy: 0.0001)
    // Resumed turns continue the turn index.
    let records = try recordStore.all()
    XCTAssertEqual(records.map(\.turnIndex), [0, 1])
    XCTAssertEqual(Set(records.compactMap(\.sessionId)), [first.id])
  }
}
