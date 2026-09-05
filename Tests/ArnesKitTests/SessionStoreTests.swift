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

  // MARK: rewind entries (C4)

  func testRewindEntryTruncatesOnReplay() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    for turn in 0..<3 {
      try store.append(TranscriptEntry(message: .user("turn \(turn)"), turn: turn), to: id)
      try store.append(TranscriptEntry(message: .assistant("answer \(turn)"), turn: turn), to: id)
    }
    // The live session rewound to the start of turn 1: the first two messages were kept.
    try store.append(.rewind(toTurn: 1, keepMessages: 2, restoredPaths: ["/work/a.txt"]), to: id)
    try store.append(TranscriptEntry(message: .user("turn 3"), turn: 3), to: id)
    try store.append(TranscriptEntry(message: .assistant("answer 3"), turn: 3), to: id)

    let loaded = try store.load(id: id)
    XCTAssertEqual(
      loaded.messages.map { $0.content?.plainText },
      ["turn 0", "answer 0", "turn 3", "answer 3"])
    XCTAssertEqual(loaded.turnStarts, [TurnStart(turn: 0, index: 0), TurnStart(turn: 3, index: 2)])
    // Turns are monotonic: the count is every turn that ran, rewound-away ones included, exactly
    // as the live session's `turnIndex` counts them.
    XCTAssertEqual(loaded.turnCount, 4)

    let markdown = try store.exportMarkdown(id: id)
    XCTAssertTrue(markdown.contains("> rewound to turn 1 (kept 2 messages) · restored a.txt"), markdown)
    // An export is a record of the session: the rewound turns are still shown where they happened.
    XCTAssertTrue(markdown.contains("turn 2"))
  }

  func testACodeOnlyRewindLineAndAnOldRewindLineLeaveTheMessagesAlone() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    try store.append(TranscriptEntry(message: .user("one"), turn: 0), to: id)
    try store.append(TranscriptEntry(message: .assistant("a"), turn: 0), to: id)
    try store.append(TranscriptEntry(message: .user("two"), turn: 1), to: id)
    try store.append(TranscriptEntry(message: .assistant("b"), turn: 1), to: id)
    // Files restored, conversation kept.
    try store.append(.rewind(toTurn: 1, keepMessages: nil, restoredPaths: ["/work/a.txt"]), to: id)
    // A line with only the type and the turn (what a leaner writer might produce) is inert too.
    let bare = Data(#"{"type":"rewind","turn":0}"#.utf8) + Data("\n".utf8)
    let url = store.directory.appendingPathComponent("\(id).jsonl")
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: bare)
    try handle.close()

    let loaded = try store.load(id: id)
    XCTAssertEqual(loaded.messages.count, 4)
    XCTAssertEqual(loaded.turnStarts, [TurnStart(turn: 0, index: 0), TurnStart(turn: 1, index: 2)])
    XCTAssertTrue(try store.exportMarkdown(id: id).contains("> rewound files to turn 1 (conversation kept) · restored a.txt"))
  }

  func testRewindEntryRoundTripsItsFields() throws {
    let entry = TranscriptEntry.rewind(toTurn: 4, keepMessages: 9, restoredPaths: ["/x/a", "/x/b"])
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
    XCTAssertEqual(decoded.type, .rewind)
    XCTAssertEqual(decoded.turn, 4)
    XCTAssertEqual(decoded.keepMessages, 9)
    XCTAssertEqual(decoded.restoredPaths, ["/x/a", "/x/b"])
    // The new keys are absent from every other line — a message line is what it always was.
    let message = try JSONEncoder().encode(TranscriptEntry(message: .user("hi"), turn: 1))
    let object = try JSONSerialization.jsonObject(with: message) as? [String: Any]
    XCTAssertNil(object?["keepMessages"])
    XCTAssertNil(object?["restoredPaths"])
  }
}
