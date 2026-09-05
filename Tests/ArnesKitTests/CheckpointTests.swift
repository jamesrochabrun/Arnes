import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// C4: file checkpoints before every `write_file`/`edit_file`, `Session.rewind` restoring code
/// and/or conversation to a turn, and the `rewind` transcript entry replay honors.
final class CheckpointTests: XCTestCase {
  private func tempDirectory(_ label: String = "root") throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-checkpoints-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func recordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-checkpoint-runs-\(UUID().uuidString).jsonl"))
  }

  private func sessionStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-checkpoint-sessions-\(UUID().uuidString)"))
  }

  /// A turn counter the tests move by hand, standing in for the session's `turnIndex`.
  private final class TurnBox: @unchecked Sendable {
    var turn = 0
  }

  /// A bound store over `checkpointRoot` and the coding tools that snapshot into it.
  private func boundTools(
    root: URL, checkpointRoot: URL, sessionId: String = "session-1",
    policy: CheckpointPolicy = .default, turn: TurnBox)
    async -> (store: FileCheckpointStore, write: any AgentTool, edit: any AgentTool, read: any AgentTool)
  {
    let store = FileCheckpointStore(root: checkpointRoot, policy: policy)
    await store.bind(sessionId: sessionId) { turn.turn }
    let tools = HarnessAssembly.coreTools(ToolContext(root: root, checkpoints: store))
    return (
      store,
      tools.first { $0.name == "write_file" }!,
      tools.first { $0.name == "edit_file" }!,
      tools.first { $0.name == "read_file" }!)
  }

  private func write(_ tool: any AgentTool, _ path: String, _ content: String) async throws -> String {
    try await tool.execute(arguments: ["path": .string(path), "content": .string(content)])
  }

  private func edit(_ tool: any AgentTool, _ path: String, _ old: String, _ new: String) async throws -> String {
    try await tool.execute(arguments: [
      "path": .string(path), "old_string": .string(old), "new_string": .string(new),
    ])
  }

  private func contents(_ url: URL) -> String? {
    try? String(contentsOf: url, encoding: .utf8)
  }

  private func exists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
  }

  // MARK: The store

  func testWriteFileNewFileRecordsExistedFalseAndRewindDeletesIt() async throws {
    let root = try tempDirectory()
    let turn = TurnBox()
    let (store, write, _, _) = await boundTools(root: root, checkpointRoot: try tempDirectory("cp"), turn: turn)
    let file = root.appendingPathComponent("new.txt")

    let result = try await self.write(write, "new.txt", "hello")
    XCTAssertTrue(result.hasPrefix("created "), result)
    let checkpoints = await store.checkpoints
    XCTAssertEqual(checkpoints.count, 1)
    let checkpoint = try XCTUnwrap(checkpoints.first)
    XCTAssertEqual(checkpoint.path, file.path)
    XCTAssertFalse(checkpoint.existed)
    XCTAssertNil(checkpoint.blob)
    XCTAssertEqual(checkpoint.bytes, 0)
    XCTAssertEqual(checkpoint.turn, 0)
    XCTAssertTrue(checkpoint.restorable, "a file that didn't exist is restored by deleting it")

    let outcome = try await store.rewind(toTurn: 0)
    XCTAssertEqual(outcome, CheckpointRestore(restored: [], deleted: [file.path], skipped: []))
    XCTAssertFalse(exists(file))
    let remaining = await store.checkpoints
    XCTAssertTrue(remaining.isEmpty, "the rewound turn's checkpoints are forgotten")
  }

  func testEditFilePreImageRestoredToBeforeTheFirstEditOfTheTurn() async throws {
    let root = try tempDirectory()
    let file = root.appendingPathComponent("a.swift")
    try "let x = 1\n".write(to: file, atomically: true, encoding: .utf8)
    let turn = TurnBox()
    let (store, _, edit, read) = await boundTools(root: root, checkpointRoot: try tempDirectory("cp"), turn: turn)

    _ = try await read.execute(arguments: ["path": .string("a.swift")])
    let first = try await self.edit(edit, "a.swift", "let x = 1", "let x = 2")
    XCTAssertTrue(first.hasPrefix("edited "), first)
    let second = try await self.edit(edit, "a.swift", "let x = 2", "let x = 3")
    XCTAssertTrue(second.hasPrefix("edited "), second)
    XCTAssertEqual(contents(file), "let x = 3\n")

    // One checkpoint per (turn, path): the turn's first write to the file recorded its pre-image,
    // the second edit found it already kept.
    let checkpoints = await store.checkpoints
    XCTAssertEqual(checkpoints.count, 1)
    XCTAssertTrue(checkpoints[0].existed)
    XCTAssertEqual(checkpoints[0].bytes, "let x = 1\n".utf8.count)
    let sha = try XCTUnwrap(checkpoints[0].blob)
    let blob = await store.blobData(sha)
    XCTAssertEqual(blob, Data("let x = 1\n".utf8))

    let outcome = try await store.rewind(toTurn: 0)
    XCTAssertEqual(outcome.restored, [file.path])
    XCTAssertEqual(contents(file), "let x = 1\n")
    // The blob nothing references any more is gone with the checkpoint.
    let sessionDirectory = await store.sessionDirectory
    let directory = try XCTUnwrap(sessionDirectory)
    let blobs = try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("blobs").path)
    XCTAssertEqual(blobs ?? [], [])
  }

  func testRewindToAnEarlierTurnRestoresAcrossTurnsToTheEarliestPreImage() async throws {
    let root = try tempDirectory()
    let a = root.appendingPathComponent("a.txt")
    let b = root.appendingPathComponent("b.txt")
    let turn = TurnBox()
    let (store, write, edit, _) = await boundTools(root: root, checkpointRoot: try tempDirectory("cp"), turn: turn)

    _ = try await self.write(write, "a.txt", "v1\n")          // turn 0 creates it
    turn.turn = 1
    _ = try await self.edit(edit, "a.txt", "v1", "v2")        // turn 1
    turn.turn = 2
    _ = try await self.edit(edit, "a.txt", "v2", "v3")        // turn 2
    _ = try await self.write(write, "b.txt", "b\n")           // turn 2 creates another
    var turns = await store.turns
    XCTAssertEqual(turns, [0, 1, 2])
    let inTurnTwo = await store.checkpoints(forTurn: 2)
    XCTAssertEqual(inTurnTwo.count, 2)

    // Back to the start of turn 1: a.txt is what turn 0 left (v1), b.txt never existed yet.
    let outcome = try await store.rewind(toTurn: 1)
    XCTAssertEqual(outcome.restored, [a.path])
    XCTAssertEqual(outcome.deleted, [b.path])
    XCTAssertEqual(contents(a), "v1\n")
    XCTAssertFalse(exists(b))
    // Turn 0's checkpoint (a.txt didn't exist) is still there for a deeper rewind.
    turns = await store.turns
    XCTAssertEqual(turns, [0])
    let further = try await store.rewind(toTurn: 0)
    XCTAssertEqual(further.deleted, [a.path])
    XCTAssertFalse(exists(a))
  }

  func testAFileOverTheSizeCapIsRecordedAsSkippedAndNeverRestored() async throws {
    let root = try tempDirectory()
    let file = root.appendingPathComponent("big.txt")
    let content = "start\n" + String(repeating: "x", count: 190) + "\n"
    try content.write(to: file, atomically: true, encoding: .utf8)
    let turn = TurnBox()
    let (store, _, edit, read) = await boundTools(
      root: root, checkpointRoot: try tempDirectory("cp"),
      policy: CheckpointPolicy(maxFileBytes: 100), turn: turn)

    _ = try await read.execute(arguments: ["path": .string("big.txt")])
    let edited = try await self.edit(edit, "big.txt", "start", "begin")
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
    let checkpoints = await store.checkpoints
    let checkpoint = try XCTUnwrap(checkpoints.first)
    XCTAssertTrue(checkpoint.existed)
    XCTAssertNil(checkpoint.blob, "the pre-image was not saved")
    XCTAssertEqual(checkpoint.bytes, content.utf8.count)
    XCTAssertFalse(checkpoint.restorable)

    let outcome = try await store.rewind(toTurn: 0)
    XCTAssertEqual(outcome.restored, [])
    XCTAssertEqual(outcome.skipped.count, 1)
    XCTAssertTrue(outcome.skipped[0].contains("big.txt"), outcome.skipped[0])
    XCTAssertTrue(outcome.skipped[0].contains("not saved"), outcome.skipped[0])
    XCTAssertTrue(try XCTUnwrap(contents(file)).hasPrefix("begin"), "the file was left as it is")
    do {
      _ = try await store.restore(checkpoint)
      XCTFail("an un-restorable checkpoint must throw")
    } catch let error as CheckpointError {
      XCTAssertEqual(error, .notRestorable(file.path))
    }
  }

  func testTheTurnCapDropsTheOldestTurnsCheckpoints() async throws {
    let root = try tempDirectory()
    let turn = TurnBox()
    let (store, write, _, _) = await boundTools(
      root: root, checkpointRoot: try tempDirectory("cp"),
      policy: CheckpointPolicy(maxTurns: 2), turn: turn)
    for index in 0..<4 {
      turn.turn = index
      _ = try await self.write(write, "f\(index).txt", "\(index)")
    }
    let turns = await store.turns
    XCTAssertEqual(turns, [2, 3], "only the newest two turns are kept")
  }

  func testRestoreRefusesAPathThatNowResolvesElsewhere() async throws {
    let root = try tempDirectory()
    let outside = try tempDirectory("outside")
    let secret = outside.appendingPathComponent("secret.txt")
    try "keep me".write(to: secret, atomically: true, encoding: .utf8)
    let file = root.appendingPathComponent("a.txt")
    try "v1".write(to: file, atomically: true, encoding: .utf8)
    let turn = TurnBox()
    let (store, _, edit, read) = await boundTools(root: root, checkpointRoot: try tempDirectory("cp"), turn: turn)
    _ = try await read.execute(arguments: ["path": .string("a.txt")])
    _ = try await self.edit(edit, "a.txt", "v1", "v2")

    // The run (say, through bash) replaced the file with a link to something it may not touch.
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: secret)

    let outcome = try await store.rewind(toTurn: 0)
    XCTAssertEqual(outcome.restored, [])
    XCTAssertEqual(outcome.skipped.count, 1)
    XCTAssertTrue(outcome.skipped[0].contains("resolves elsewhere"), outcome.skipped[0])
    XCTAssertEqual(contents(secret), "keep me", "nothing was written through the link")
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: file.path), secret.path,
      "the link itself is left alone too")
  }

  func testTheIndexPersistsAcrossStoreInstancesAndAForkInheritsIt() async throws {
    let root = try tempDirectory()
    let checkpointRoot = try tempDirectory("cp")
    let turn = TurnBox()
    let (store, write, _, _) = await boundTools(root: root, checkpointRoot: checkpointRoot, turn: turn)
    _ = try await self.write(write, "a.txt", "v1")
    let saved = await store.checkpoints

    // A new process: another store over the same root, bound to the same session.
    let again = FileCheckpointStore(root: checkpointRoot)
    await again.bind(sessionId: "session-1") { 0 }
    let reloaded = await again.checkpoints
    XCTAssertEqual(reloaded, saved)
    // The files are owner-only, like everything under ~/.arnes.
    let sessionDirectory = await again.sessionDirectory
    let directory = try XCTUnwrap(sessionDirectory)
    let mode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode.map { $0 & 0o777 }, 0o700)
    let indexMode = try FileManager.default.attributesOfItem(
      atPath: directory.appendingPathComponent("index.json").path)[.posixPermissions] as? Int
    XCTAssertEqual(indexMode.map { $0 & 0o777 }, 0o600)

    // A fork bound for the first time copies its parent's checkpoints, so it can rewind past
    // the branch point; the parent's directory is untouched by what the fork does next.
    let fork = FileCheckpointStore(root: checkpointRoot)
    await fork.bind(sessionId: "fork-1", inheritingFrom: "session-1") { 0 }
    let inherited = await fork.checkpoints
    XCTAssertEqual(inherited, saved)
    _ = try await fork.rewind(toTurn: 0)
    let forkAfter = await fork.checkpoints
    XCTAssertTrue(forkAfter.isEmpty)
    let parentAgain = FileCheckpointStore(root: checkpointRoot)
    await parentAgain.bind(sessionId: "session-1") { 0 }
    let parentAfter = await parentAgain.checkpoints
    XCTAssertEqual(parentAfter, saved)
  }

  func testAnUnboundStoreRecordsNothing() async throws {
    let root = try tempDirectory()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let tools = HarnessAssembly.coreTools(ToolContext(root: root, checkpoints: store))
    let write = try XCTUnwrap(tools.first { $0.name == "write_file" })
    _ = try await self.write(write, "a.txt", "v1")
    let checkpoints = await store.checkpoints
    XCTAssertTrue(checkpoints.isEmpty)
    let directory = await store.sessionDirectory
    XCTAssertNil(directory)
    let outcome = try await store.rewind(toTurn: 0)
    XCTAssertEqual(outcome, .nothing)
  }

  // MARK: Wiring

  func testHeadlessCoreToolsSnapshotNothing() async throws {
    let root = try tempDirectory()
    let tools = HarnessAssembly.coreTools(ToolContext(root: root))
    for tool in tools {
      if let mutating = tool as? any FileMutatingTool {
        XCTAssertNil(mutating.checkpoints, "\(tool.name) has no store unless the context binds one")
      }
    }
    let write = try XCTUnwrap(tools.first { $0.name == "write_file" })
    _ = try await self.write(write, "a.txt", "v1")
    XCTAssertFalse(exists(root.appendingPathComponent("checkpoints")))
    XCTAssertNil(Session.defaultTools.compactMap { ($0 as? any FileMutatingTool)?.checkpoints }.first)
  }

  func testMutatedPathsNameTheRootResolvedPath() throws {
    let root = try tempDirectory()
    let write = WriteFileTool(root: root)
    let edit = EditFileTool(root: root)
    XCTAssertEqual(
      write.mutatedPaths(arguments: ["path": .string("a.txt"), "content": .string("x")]),
      [root.appendingPathComponent("a.txt").path])
    XCTAssertEqual(
      edit.mutatedPaths(arguments: ["path": .string("/abs/b.txt"), "old_string": .string("a"), "new_string": .string("b")]),
      ["/abs/b.txt"])
    XCTAssertEqual(write.mutatedPaths(arguments: ["content": .string("x")]), [])
  }

  func testTheHarnessFloorStillRefusesWithAStoreSetAndLeavesNoCheckpoint() async throws {
    let harness = try tempDirectory("harness")
    let root = try tempDirectory()
    let turn = TurnBox()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    await store.bind(sessionId: "s") { turn.turn }
    let rules = PathScope.Rules(harnessPaths: [PathScope.physicalPath(harness.path)])
    let target = harness.appendingPathComponent("hooks.json")
    let write = WriteFileTool(root: root, rules: rules, checkpoints: store)
    let output = try await write.execute(arguments: ["path": .string(target.path), "content": .string("[]")])
    XCTAssertEqual(output, "error: refused — harness files are not editable by tools; edit them yourself")
    XCTAssertFalse(exists(target))
    let checkpoints = await store.checkpoints
    XCTAssertTrue(checkpoints.isEmpty, "a refused write is not checkpointed")
  }

  func testCheckpointsConfigDecodesAndFillsDefaults() throws {
    let json = #"{"checkpoints": {"maxFileBytes": 1000}}"#
    let config = try JSONDecoder().decode(ArnesConfig.self, from: Data(json.utf8))
    let checkpoints = try XCTUnwrap(config.checkpoints)
    XCTAssertTrue(checkpoints.isEnabled)
    XCTAssertEqual(checkpoints.policy, CheckpointPolicy(maxFileBytes: 1000, maxTurns: 100))
    let off = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"checkpoints": {"enabled": false}}"#.utf8))
    XCTAssertFalse(try XCTUnwrap(off.checkpoints).isEnabled)
    let absent = try JSONDecoder().decode(ArnesConfig.self, from: Data("{}".utf8))
    XCTAssertNil(absent.checkpoints)
  }

  // MARK: Session.rewind

  /// A session over the mock whose tools snapshot into `store`, bound to the session's turn.
  private func session(
    mock: MockOpenRouterService, root: URL, store: FileCheckpointStore,
    sessionStore: SessionStore? = nil, records: RunRecordStore)
    async -> Session
  {
    let tools = HarnessAssembly.coreTools(ToolContext(root: root, checkpoints: store))
    let session = Session(
      service: mock, tools: tools, store: records, sessionStore: sessionStore,
      configuration: .init(model: "test/model", workingDirectory: root))
    // The REPL's binding: the turn in flight is `turnIndex - 1`.
    await store.bind(sessionId: session.id) { max(0, (await session.turnIndex) - 1) }
    return session
  }

  /// Turn 0 creates a.txt; turn 1 edits it and creates b.txt.
  private func twoTurnMock() -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "a.txt", "content": "v1\n"}"#),
       Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("created a"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c2", name: "edit_file", arguments: #"{"path": "a.txt", "old_string": "v1", "new_string": "v2"}"#),
       Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c3", name: "write_file", arguments: #"{"path": "b.txt", "content": "b\n"}"#),
       Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("edited a, created b"), Fixtures.usageChunk(cost: 0.01)],
    ]
    return mock
  }

  func testSessionRewindRestoresCodeAndConversationAndReplays() async throws {
    let root = try tempDirectory()
    let a = root.appendingPathComponent("a.txt")
    let b = root.appendingPathComponent("b.txt")
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let sessionStore = self.sessionStore()
    let session = await session(
      mock: twoTurnMock(), root: root, store: store, sessionStore: sessionStore, records: recordStore())
    for try await _ in await session.send("create a") {}
    for try await _ in await session.send("edit a, create b") {}
    XCTAssertEqual(contents(a), "v2\n")
    XCTAssertEqual(contents(b), "b\n")
    let historyBefore = await session.history.count
    let startsBefore = await session.turnStarts
    XCTAssertEqual(startsBefore, [TurnStart(turn: 0, index: 0), TurnStart(turn: 1, index: 4)])
    let checkpointsBefore = await store.checkpoints
    XCTAssertEqual(checkpointsBefore.map(\.turn), [0, 1, 1])

    let result = try await session.rewind(toTurn: 1)
    XCTAssertEqual(result.restoredFiles, [a.path])
    XCTAssertEqual(result.deletedFiles, [b.path])
    XCTAssertEqual(result.skipped, [])
    XCTAssertEqual(result.removedMessages, historyBefore - 4)
    XCTAssertEqual(contents(a), "v1\n")
    XCTAssertFalse(exists(b))
    // History is the first turn: user, assistant(tool call), tool, assistant.
    let history = await session.history
    XCTAssertEqual(history.count, 4)
    XCTAssertEqual(history[0].content?.plainText, "create a")
    XCTAssertEqual(history[3].content?.plainText, "created a")
    let starts = await session.turnStarts
    XCTAssertEqual(starts, [TurnStart(turn: 0, index: 0)])
    let turnIndex = await session.turnIndex
    XCTAssertEqual(turnIndex, 2, "turns are monotonic: the next turn is 2, not 1")
    let turns = await store.turns
    XCTAssertEqual(turns, [0], "turn 1's checkpoints are gone; turn 0's stay")

    // The transcript replays the same cut.
    let loaded = try sessionStore.load(id: session.id)
    XCTAssertEqual(loaded.messages.count, 4)
    XCTAssertEqual(loaded.turnStarts, [TurnStart(turn: 0, index: 0)])
    XCTAssertEqual(loaded.messages.map { $0.content?.plainText }, history.map { $0.content?.plainText })
  }

  func testTheNextTurnAfterARewindContinuesFromTheCut() async throws {
    let root = try tempDirectory()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let sessionStore = self.sessionStore()
    let mock = twoTurnMock()
    mock.chunkScripts.append([Fixtures.textChunk("third"), Fixtures.usageChunk(cost: 0.01)])
    let session = await session(mock: mock, root: root, store: store, sessionStore: sessionStore, records: recordStore())
    for try await _ in await session.send("create a") {}
    for try await _ in await session.send("edit a, create b") {}
    _ = try await session.rewind(toTurn: 1)
    for try await _ in await session.send("something else") {}

    // The request after the rewind carried turn 0 and the new message — never turn 1.
    let request = mock.requests.last!
    let texts = request.messages.compactMap { $0.content?.plainText }
    XCTAssertTrue(texts.contains("create a"))
    XCTAssertTrue(texts.contains("something else"))
    XCTAssertFalse(texts.contains("edit a, create b"))
    let starts = await session.turnStarts
    XCTAssertEqual(starts, [TurnStart(turn: 0, index: 0), TurnStart(turn: 2, index: 4)])
    // And so does the replayed transcript.
    let loaded = try sessionStore.load(id: session.id)
    XCTAssertEqual(loaded.turnStarts, starts)
    XCTAssertEqual(loaded.messages.count, 6)
  }

  func testCodeOnlyRewindKeepsTheConversation() async throws {
    let root = try tempDirectory()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let sessionStore = self.sessionStore()
    let session = await session(
      mock: twoTurnMock(), root: root, store: store, sessionStore: sessionStore, records: recordStore())
    for try await _ in await session.send("create a") {}
    for try await _ in await session.send("edit a, create b") {}
    let before = await session.history

    let result = try await session.rewind(toTurn: 1, code: true, conversation: false)
    XCTAssertEqual(result.removedMessages, 0)
    XCTAssertEqual(result.restoredFiles.count, 1)
    XCTAssertEqual(result.deletedFiles.count, 1)
    XCTAssertEqual(contents(root.appendingPathComponent("a.txt")), "v1\n")
    let after = await session.history
    XCTAssertEqual(after.count, before.count)
    let starts = await session.turnStarts
    XCTAssertEqual(starts, [TurnStart(turn: 0, index: 0), TurnStart(turn: 1, index: 4)])
    // Replay: the rewind line carries no keepMessages, so the messages stand.
    let loaded = try sessionStore.load(id: session.id)
    XCTAssertEqual(loaded.messages.count, before.count)
    XCTAssertEqual(loaded.turnStarts.count, 2)
  }

  func testConversationOnlyRewindKeepsTheFilesAndTheirCheckpoints() async throws {
    let root = try tempDirectory()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let session = await session(mock: twoTurnMock(), root: root, store: store, records: recordStore())
    for try await _ in await session.send("create a") {}
    for try await _ in await session.send("edit a, create b") {}

    let result = try await session.rewind(toTurn: 1, code: false, conversation: true)
    XCTAssertEqual(result.restoredFiles, [])
    XCTAssertEqual(result.deletedFiles, [])
    XCTAssertGreaterThan(result.removedMessages, 0)
    XCTAssertEqual(contents(root.appendingPathComponent("a.txt")), "v2\n", "files untouched")
    XCTAssertTrue(exists(root.appendingPathComponent("b.txt")))
    let history = await session.history
    XCTAssertEqual(history.count, 4)
    // The checkpoints stay: the files are still changed, and a later code rewind undoes them.
    let turns = await store.turns
    XCTAssertEqual(turns, [0, 1])
    let later = try await session.rewind(toTurn: 1, code: true, conversation: false)
    XCTAssertEqual(later.restoredFiles.count, 1)
    XCTAssertEqual(contents(root.appendingPathComponent("a.txt")), "v1\n")
  }

  func testRewindRefusesUnknownTurnsAndTurnsACompactionSummarizedAway() async throws {
    let root = try tempDirectory()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let mock = twoTurnMock()
    mock.chatResponses = [Fixtures.textResponse("older turns summarized", cost: 0.001)]
    let session = await session(mock: mock, root: root, store: store, records: recordStore())
    do {
      _ = try await session.rewind(toTurn: 0)
      XCTFail("no turn has run")
    } catch let error as RewindError {
      XCTAssertEqual(error, .noSuchTurn(0))
    }
    for try await _ in await session.send("create a") {}
    for try await _ in await session.send("edit a, create b") {}
    do {
      _ = try await session.rewind(toTurn: 2)
      XCTFail("turn 2 never started")
    } catch let error as RewindError {
      XCTAssertEqual(error, .noSuchTurn(2))
    }
    _ = try await session.compact()
    let starts = await session.turnStarts
    XCTAssertEqual(starts, [TurnStart(turn: 1, index: 0)])
    do {
      _ = try await session.rewind(toTurn: 0)
      XCTFail("turn 0's messages were compacted away")
    } catch let error as RewindError {
      XCTAssertEqual(error, .acrossCompaction(0))
      XCTAssertTrue(error.description.contains("compacted"))
    }
    // Its files can still be rewound, code only: both files go (neither existed before turn 0).
    let result = try await session.rewind(toTurn: 0, code: true, conversation: false)
    XCTAssertEqual(result.deletedFiles.count, 2)
    XCTAssertFalse(exists(root.appendingPathComponent("a.txt")))
    XCTAssertFalse(exists(root.appendingPathComponent("b.txt")))
  }

  func testTheTranscriptHoldsOneRewindLineAndNoCheckpoint() async throws {
    let root = try tempDirectory()
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let sessionStore = self.sessionStore()
    let session = await session(
      mock: twoTurnMock(), root: root, store: store, sessionStore: sessionStore, records: recordStore())
    for try await _ in await session.send("create a") {}
    for try await _ in await session.send("edit a, create b") {}
    _ = try await session.rewind(toTurn: 1)

    let data = try Data(contentsOf: sessionStore.directory.appendingPathComponent("\(session.id).jsonl"))
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    let rewinds = lines.filter { $0.contains(#""type":"rewind""#) }
    XCTAssertEqual(rewinds.count, 1)
    let object = try JSONSerialization.jsonObject(with: Data(rewinds[0].utf8)) as? [String: Any]
    XCTAssertEqual(object?["turn"] as? Int, 1)
    XCTAssertEqual(object?["keepMessages"] as? Int, 4)
    XCTAssertEqual((object?["restoredPaths"] as? [String])?.count, 2)
    // Pre-images live beside the transcript, never in it: no line carries a blob hash or a
    // checkpoint's fields.
    XCTAssertFalse(lines.contains { $0.contains("\"blob\"") || $0.contains("physicalPath") || $0.contains("existed") })
    // The export says what happened.
    let markdown = try sessionStore.exportMarkdown(id: session.id)
    XCTAssertTrue(markdown.contains("> rewound to turn 1 (kept 4 messages) · restored a.txt, b.txt"), markdown)
  }

  func testASubagentsWriteIsCheckpointedUnderTheLeadsSession() async throws {
    let root = try tempDirectory()
    let file = root.appendingPathComponent("sub.txt")
    let store = FileCheckpointStore(root: try tempDirectory("cp"))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"), Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScriptsByModel = [
      "lead/model": [
        [Fixtures.toolCallChunk(
          id: "c1", name: "task", arguments: #"{"agent":"helper","task":"write sub.txt"}"#, model: "lead/model"),
         Fixtures.usageChunk(cost: 0.01, model: "lead/model")],
        [Fixtures.textChunk("delegated", model: "lead/model"), Fixtures.usageChunk(cost: 0.01, model: "lead/model")],
      ],
      "sub/model": [
        [Fixtures.toolCallChunk(
          id: "s1", name: "write_file", arguments: #"{"path": "sub.txt", "content": "from the subagent"}"#,
          model: "sub/model"),
         Fixtures.usageChunk(cost: 0.01, model: "sub/model")],
        [Fixtures.textChunk("wrote it", model: "sub/model"), Fixtures.usageChunk(cost: 0.01, model: "sub/model")],
      ],
    ]
    let records = recordStore()
    let coreTools = HarnessAssembly.coreTools(ToolContext(root: root, checkpoints: store))
    let helper = AgentDefinition(name: "helper", description: "helps", body: "Help.", model: "sub/model")
    let configuration = Session.Configuration(model: "lead/model", workingDirectory: root)
    let taskTool = TaskTool(
      agents: [helper], service: mock, tools: coreTools, store: records, configuration: configuration)
    let session = Session(service: mock, tools: coreTools + [taskTool], store: records, configuration: configuration)
    taskTool.parentModel = { await session.model }
    await store.bind(sessionId: session.id) { max(0, (await session.turnIndex) - 1) }

    for try await _ in await session.send("delegate") {}
    XCTAssertEqual(contents(file), "from the subagent")
    // The nested run used the lead's tool instances, so its write landed in the lead's store,
    // filed under the lead's turn.
    let checkpoints = await store.checkpoints
    XCTAssertEqual(checkpoints.map(\.turn), [0])
    XCTAssertEqual(checkpoints.first?.path, file.path)
    XCTAssertEqual(checkpoints.first?.existed, false)
    let result = try await session.rewind(toTurn: 0, code: true, conversation: false)
    XCTAssertEqual(result.deletedFiles, [file.path])
    XCTAssertFalse(exists(file))
  }

  // MARK: UnifiedDiff

  func testUnifiedDiffOfATwoLineChange() {
    let diff = UnifiedDiff.diff(
      old: "a\nb\nc\nd\ne\nf\ng\nh\n", new: "a\nb\nc\nD\ne\nf\ng\nH\n", path: "x.txt")
    XCTAssertEqual(diff, """
      --- a/x.txt
      +++ b/x.txt
      @@ -1,8 +1,8 @@
       a
       b
       c
      -d
      +D
       e
       f
       g
      -h
      +H

      """)
  }

  func testUnifiedDiffSplitsDistantChangesIntoHunksAndMarksNewAndDeletedFiles() {
    let old = (1...20).map(String.init).joined(separator: "\n") + "\n"
    let new = old
      .replacingOccurrences(of: "\n2\n", with: "\ntwo\n")
      .replacingOccurrences(of: "\n19\n", with: "\nnineteen\n")
    let diff = UnifiedDiff.diff(old: old, new: new, path: "n.txt")
    XCTAssertEqual(diff.components(separatedBy: "\n@@ ").count - 1, 2, diff)
    XCTAssertTrue(diff.contains("@@ -1,5 +1,5 @@\n 1\n-2\n+two\n 3\n 4\n 5\n"), diff)
    XCTAssertTrue(diff.contains("@@ -16,5 +16,5 @@\n 16\n 17\n 18\n-19\n+nineteen\n 20\n"), diff)

    let created = UnifiedDiff.diff(old: nil, new: "hi\n", path: "c.txt")
    XCTAssertEqual(created, "--- /dev/null\n+++ b/c.txt\n@@ -0,0 +1,1 @@\n+hi\n")
    let deleted = UnifiedDiff.diff(old: "bye\n", new: nil, path: "d.txt")
    XCTAssertEqual(deleted, "--- a/d.txt\n+++ /dev/null\n@@ -1,1 +0,0 @@\n-bye\n")
    XCTAssertEqual(UnifiedDiff.diff(old: "same\n", new: "same\n", path: "s.txt"), "")
    XCTAssertEqual(UnifiedDiff.diff(old: nil, new: nil, path: "none"), "")
  }

  func testUnifiedDiffFallsBackToOneReplacementPastTheAlignmentLimit() {
    let count = UnifiedDiff.dpLineLimit + 5
    let old = (0..<count).map { "old \($0)" }.joined(separator: "\n")
    let new = (0..<count).map { "new \($0)" }.joined(separator: "\n")
    let diff = UnifiedDiff.diff(old: old, new: new, path: "big.txt")
    let removed = diff.split(separator: "\n").filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
    let added = diff.split(separator: "\n").filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
    XCTAssertEqual(removed, count)
    XCTAssertEqual(added, count)
    XCTAssertTrue(diff.hasPrefix("--- a/big.txt\n+++ b/big.txt\n@@ -1,\(count) +1,\(count) @@\n"), diff)
  }
}
