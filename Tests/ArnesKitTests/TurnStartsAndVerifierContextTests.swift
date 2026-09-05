import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The batch-9 prelude seams: where each turn begins in history (`Session.turnStarts`, the
/// transcript's `turn` tags, `LoadedSession.turnStarts`) and what the loop hands the verifier
/// beyond task + report (`Verifier.Context`, `Verdict.costUSD`/`confidence`,
/// `RunRecord.verifierConfidence`). Both are seams: the loop's behavior is unchanged until a
/// consumer reads them.
final class TurnStartsAndVerifierContextTests: XCTestCase {
  private func tempStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-sessions-\(UUID().uuidString)"))
  }

  private func recordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-runs-\(UUID().uuidString).jsonl"))
  }

  private func mock(turns: Int) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = (1...turns).map { [Fixtures.textChunk("answer \($0)"), Fixtures.usageChunk(cost: 0.01)] }
    return mock
  }

  // MARK: turn starts

  func testEachUserTurnRecordsWhereItBeganInHistory() async throws {
    let session = Session(
      service: mock(turns: 2), tools: [], store: recordStore(), configuration: .init(model: "test/model"))
    for try await _ in await session.send("turn one") { }
    var starts = await session.turnStarts
    var turnIndex = await session.turnIndex
    XCTAssertEqual(starts, [TurnStart(turn: 0, index: 0)])
    XCTAssertEqual(turnIndex, 1)

    for try await _ in await session.send("turn two") { }
    starts = await session.turnStarts
    turnIndex = await session.turnIndex
    let historyCount = await session.history.count
    // history: user, assistant, user, assistant — the second turn opens at index 2.
    XCTAssertEqual(starts, [TurnStart(turn: 0, index: 0), TurnStart(turn: 1, index: 2)])
    XCTAssertEqual(historyCount, 4)
    XCTAssertEqual(turnIndex, 2)
  }

  func testTurnTagsPersistAndRebuildTheStartsOnResume() async throws {
    let mock = mock(turns: 3)
    let sessionStore = tempStore()
    let records = recordStore()
    let first = Session(
      service: mock, tools: [], store: records, sessionStore: sessionStore,
      configuration: .init(model: "test/model"))
    for try await _ in await first.send("turn one") { }
    for try await _ in await first.send("turn two") { }

    // Every message line carries the turn it was written in.
    let data = try Data(contentsOf: sessionStore.directory.appendingPathComponent("\(first.id).jsonl"))
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    let messageTurns = lines.compactMap { line -> Int? in
      guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            object["type"] as? String == "message" else { return nil }
      return object["turn"] as? Int
    }
    XCTAssertEqual(messageTurns, [0, 0, 1, 1])

    let loaded = try sessionStore.load(id: first.id)
    XCTAssertEqual(loaded.turnStarts, [TurnStart(turn: 0, index: 0), TurnStart(turn: 1, index: 2)])
    XCTAssertEqual(loaded.turnCount, 2)

    let resumed = Session(resuming: loaded, service: mock, tools: [], store: records, sessionStore: sessionStore)
    let seeded = await resumed.turnStarts
    XCTAssertEqual(seeded, loaded.turnStarts)
    for try await _ in await resumed.send("turn three") { }
    let afterThree = await resumed.turnStarts
    XCTAssertEqual(
      afterThree,
      [TurnStart(turn: 0, index: 0), TurnStart(turn: 1, index: 2), TurnStart(turn: 2, index: 4)])
  }

  func testATranscriptWrittenBeforeTheTagsYieldsNoTurnStarts() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    try store.append(TranscriptEntry(message: .user("one")), to: id)
    try store.append(TranscriptEntry(message: .assistant("a")), to: id)
    try store.append(TranscriptEntry(message: .user("two")), to: id)
    try store.append(TranscriptEntry(message: .assistant("b")), to: id)

    let loaded = try store.load(id: id)
    XCTAssertEqual(loaded.messages.count, 4)
    XCTAssertEqual(loaded.turnCount, 2, "the user-message count is what it always was")
    XCTAssertEqual(loaded.turnStarts, [], "untagged lines can't be told apart by turn")
  }

  func testClearAndCompactionCutTheStartsWithTheHistory() async throws {
    let mock = mock(turns: 2)
    mock.chatResponses = [Fixtures.textResponse("older turns summarized", cost: 0.001)]
    let sessionStore = tempStore()
    let session = Session(
      service: mock, tools: [], store: recordStore(), sessionStore: sessionStore,
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("turn one") { }
    for try await _ in await session.send("turn two") { }

    _ = try await session.compact()
    // Only the last turn's tail is kept; it now opens the history.
    let keptCount = await session.history.count
    let compacted = await session.turnStarts
    XCTAssertEqual(keptCount, 2)
    XCTAssertEqual(compacted, [TurnStart(turn: 1, index: 0)])
    // The transcript replays to the same cut.
    XCTAssertEqual(try sessionStore.load(id: session.id).turnStarts, [TurnStart(turn: 1, index: 0)])

    await session.clearHistory()
    let cleared = await session.turnStarts
    XCTAssertEqual(cleared, [])
    XCTAssertEqual(try sessionStore.load(id: session.id).turnStarts, [])
  }

  // MARK: verifier context

  func testTheVerifierContextPricesTheVerdictAndCarriesItsConfidence() async throws {
    // The seam the prelude opened, exercised by V1's verifier: `costOf` prices the verdict
    // (the caller books `costUSD`, never `usage`), `confidence` is what the model stated, and
    // the request is still system + one user message carrying the task and the report.
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Fixtures.textResponse(#"{"pass": true, "confidence": "high", "reasons": ["fine"], "unmet": []}"#, cost: 0.002),
    ]
    let verdict = try await Verifier.run(
      task: "make a file", outcome: "made it", model: "verifier/model", service: mock,
      context: Verifier.Context(costOf: { _ in 42 }))
    XCTAssertTrue(verdict.passed)
    XCTAssertEqual(verdict.costUSD, 42, "priced through the context, not the router's figure")
    XCTAssertNil(verdict.usage, "the spend is on costUSD")
    XCTAssertEqual(verdict.confidence, "high")
    let request = mock.requests[0]
    XCTAssertEqual(request.messages.count, 2)
    XCTAssertEqual(request.messages[0].role, .system)
    let user = request.messages[1].content?.plainText ?? ""
    XCTAssertTrue(user.hasPrefix("Task:\nmake a file\n\nAgent's final report:\nmade it\n"), user)
  }

  func testASelfPricedVerdictIsBookedAsPricedAndItsConfidenceLandsOnTheRecord() async throws {
    // A verifier that priced itself (V1's shape) must not be priced twice by the session: the
    // record books `costUSD`, and `confidence` rides `verifierConfidence`. Exercised through
    // `RunRecord` directly — the loop's booking is one `if let priced` above the old line.
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.verifierPassed = true
    record.verifierConfidence = "high"
    let encoded = try JSONEncoder().encode(record)
    let decoded = try JSONDecoder().decode(RunRecord.self, from: encoded)
    XCTAssertEqual(decoded.verifierConfidence, "high")
    XCTAssertEqual(decoded.verifierPassed, true)
  }

  func testAnOldRunRecordRowDecodesWithoutVerifierConfidence() throws {
    let old = """
      {"id":"r1","task":"t","model":"m","dialect":"chat","packFamily":"generic","startedAt":0,\
      "steps":1,"toolCalls":0,"costUSD":0,"routedModels":[],"finished":true,"verifierPassed":false}
      """
    let record = try JSONDecoder().decode(RunRecord.self, from: Data(old.utf8))
    XCTAssertEqual(record.verifierPassed, false)
    XCTAssertNil(record.verifierConfidence)
  }

  func testAVerifiedTurnRecordsTheVerifiersConfidenceAndBooksItsSpendOnce() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("task done"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatResponses = [
      Fixtures.textResponse(
        #"{"pass": true, "confidence": "medium", "reasons": ["looks plausible"], "unmet": []}"#, cost: 0.001),
    ]
    let session = Session(
      service: mock, tools: [], store: recordStore(), configuration: .init(model: "test/model"))
    for try await _ in await session.send("do it", verifyWith: "verifier/model") { }
    let record = await session.lastRecord
    XCTAssertEqual(record?.verifierPassed, true)
    XCTAssertEqual(record?.verifierConfidence, "medium")
    XCTAssertEqual(record?.costUSD ?? 0, 0.011, accuracy: 0.0001, "the self-priced verdict is booked once")
  }
}
