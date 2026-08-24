import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class CompactionTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-compact-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempSessionStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-compact-sessions-\(UUID().uuidString)"))
  }

  func testManualCompactSummarizesOlderTurnsAndInjectsSummary() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("answer one"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("answer two"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("answer three"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [
      Fixtures.textResponse("SUMMARY NOTES", cost: 0.002, model: "cheap/summarizer"),
    ]
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    for try await _ in await session.send("turn one") { }
    for try await _ in await session.send("turn two") { }

    let result = try await session.compact()
    // History was [u1, a1, u2, a2]; the cut keeps the last user turn verbatim.
    XCTAssertEqual(result.summarizedMessages, 2)
    XCTAssertEqual(result.keptMessages, 2)
    XCTAssertEqual(result.costUSD, 0.002, accuracy: 0.0001)
    let history = await session.history
    XCTAssertEqual(history.count, 2)
    XCTAssertEqual(history[0].content?.plainText, "turn two")

    for try await _ in await session.send("turn three") { }
    let third = mock.requests.last!
    // system (with summary) + [u2, a2, u3]
    XCTAssertEqual(third.messages.count, 4)
    XCTAssertTrue(third.messages[0].content?.plainText.contains("SUMMARY NOTES") == true)
    XCTAssertEqual(third.messages[1].content?.plainText, "turn two")
    // The dropped turn was handed to the summarizer.
    let summarizerRequest = mock.requests[2]
    XCTAssertTrue(summarizerRequest.messages[1].content?.plainText.contains("turn one") == true)
    XCTAssertTrue(summarizerRequest.messages[1].content?.plainText.contains("answer one") == true)
  }

  func testCompactWithNothingToDropIsANoOp() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("only answer"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("only turn") { }

    let result = try await session.compact()
    XCTAssertEqual(result.summarizedMessages, 0)
    XCTAssertEqual(result.costUSD, 0)
    // No summarizer call happened.
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testAutoCompactTriggersWhenContextNearlyFull() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "test/model", contextLength: 100))
    mock.chunkScripts = [
      [Fixtures.textChunk("a1"), Fixtures.usageChunk(cost: 0.01, promptTokens: 20)],
      [Fixtures.textChunk("a2"), Fixtures.usageChunk(cost: 0.01, promptTokens: 90)], // 90% full
      [Fixtures.textChunk("a3"), Fixtures.usageChunk(cost: 0.01, promptTokens: 30)],
    ]
    mock.chatResponses = [
      Fixtures.textResponse("AUTO SUMMARY", cost: 0.001),
    ]
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    for try await _ in await session.send("turn one") { }
    for try await _ in await session.send("turn two") { }

    var compactedEvent: (summarized: Int, kept: Int)?
    for try await event in await session.send("turn three") {
      if case .compacted(let summarized, let kept) = event {
        compactedEvent = (summarized, kept)
      }
    }
    XCTAssertEqual(compactedEvent?.summarized, 2)
    XCTAssertEqual(compactedEvent?.kept, 2)
    let finalRequest = mock.requests.last!
    XCTAssertTrue(finalRequest.messages[0].content?.plainText.contains("AUTO SUMMARY") == true)
    // system + [u2, a2, u3] — turn one lives only in the summary now.
    XCTAssertEqual(finalRequest.messages.count, 4)
  }

  func testCompactionSurvivesResume() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("a1"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("a2"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("a3"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [
      Fixtures.textResponse("PERSISTED SUMMARY", cost: 0.001),
    ]
    let sessionStore = tempSessionStore()
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      sessionStore: sessionStore,
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("turn one") { }
    for try await _ in await session.send("turn two") { }
    try await session.compact()

    let loaded = try sessionStore.load(id: session.id)
    XCTAssertEqual(loaded.compactionSummary, "PERSISTED SUMMARY")
    XCTAssertEqual(loaded.messages.count, 2) // the kept turn, re-appended after the entry

    let resumed = Session(
      resuming: loaded,
      service: mock,
      tools: [],
      store: tempRecordStore(),
      sessionStore: sessionStore)
    for try await _ in await resumed.send("turn three") { }
    let finalRequest = mock.requests.last!
    XCTAssertTrue(finalRequest.messages[0].content?.plainText.contains("PERSISTED SUMMARY") == true)
    XCTAssertEqual(finalRequest.messages.count, 4)
  }
}
