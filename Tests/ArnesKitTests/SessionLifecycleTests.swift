import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// Session lifecycle: fork, delete, prune, markdown export, the effort dial's replay, the
/// `list()` index, and the headless persistence seam (`Agent(sessionStore:)`).
final class SessionLifecycleTests: XCTestCase {
  /// A store under its own root, so `delete` can be checked against the sibling scratch
  /// directories (`checkpoints/<id>`, `tmp/<id>`) without touching the real ~/.arnes.
  private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-lifecycle-\(UUID().uuidString)")
  }

  private func tempStore(root: URL? = nil) -> SessionStore {
    SessionStore(directory: (root ?? tempRoot()).appendingPathComponent("sessions"))
  }

  private func seed(_ store: SessionStore, name: String? = nil, model: String = "test/model") throws -> String {
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: model, cwd: "/tmp", name: name), to: id)
    try store.append(TranscriptEntry(message: .user("hi")), to: id)
    try store.append(TranscriptEntry(message: Message(role: .assistant, content: .text("hello"))), to: id)
    return id
  }

  private func touch(_ store: SessionStore, id: String, daysAgo: Int) throws {
    let url = store.directory.appendingPathComponent("\(id).jsonl")
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-Double(daysAgo) * 86_400)],
      ofItemAtPath: url.path)
  }

  // MARK: Fork

  func testForkCopiesTranscriptAndRecordsParent() throws {
    let store = tempStore()
    let id = try seed(store, name: "original")

    let forkId = try store.fork(id: id, name: "branch")
    XCTAssertNotEqual(forkId, id)

    let forked = try store.load(id: forkId)
    let original = try store.load(id: id)
    // Same conversation, new identity, parent recorded.
    XCTAssertEqual(forked.messages.map { $0.content?.plainText }, original.messages.map { $0.content?.plainText })
    XCTAssertEqual(forked.model, original.model)
    XCTAssertEqual(forked.meta.id, forkId)
    XCTAssertEqual(forked.meta.name, "branch")
    XCTAssertEqual(forked.meta.forkedFrom, id)
    // The original is untouched: same name, no parent, same message count.
    XCTAssertEqual(original.meta.name, "original")
    XCTAssertNil(original.meta.forkedFrom)
    XCTAssertEqual(original.messages.count, 2)
  }

  func testForkedSessionsDivergeIndependently() throws {
    let store = tempStore()
    let id = try seed(store)
    let forkId = try store.fork(id: id, name: nil)

    try store.append(TranscriptEntry(message: .user("only in the fork")), to: forkId)

    XCTAssertEqual(try store.load(id: forkId).messages.count, 3)
    XCTAssertEqual(try store.load(id: id).messages.count, 2)
    // And the other way: the parent keeps growing without the fork noticing.
    try store.append(TranscriptEntry(message: .user("only in the original")), to: id)
    XCTAssertEqual(try store.load(id: id).messages.count, 3)
    XCTAssertEqual(try store.load(id: forkId).messages.count, 3)
    XCTAssertEqual(
      try store.load(id: forkId).messages.last?.content?.plainText, "only in the fork")
  }

  func testForkOfUnknownSessionThrows() {
    let store = tempStore()
    XCTAssertThrowsError(try store.fork(id: "does-not-exist", name: nil))
  }

  // MARK: Delete

  func testDeleteRemovesTranscriptAndCheckpointDir() throws {
    let root = tempRoot()
    let store = tempStore(root: root)
    let id = try seed(store)
    let checkpoints = root.appendingPathComponent("checkpoints").appendingPathComponent(id)
    let scratch = root.appendingPathComponent("tmp").appendingPathComponent(id)
    for directory in [checkpoints, scratch] {
      try SecureFiles.ensureDirectory(directory)
      try Data("x".utf8).write(to: directory.appendingPathComponent("note.txt"))
    }
    let other = root.appendingPathComponent("tmp").appendingPathComponent("another-run")
    try SecureFiles.ensureDirectory(other)

    try store.delete(id: id)

    XCTAssertFalse(FileManager.default.fileExists(
      atPath: store.directory.appendingPathComponent("\(id).jsonl").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: checkpoints.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path))
    // Only this session's scratch goes.
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    XCTAssertTrue(try store.list().isEmpty)
    // Deleting again is a no-op, not an error.
    XCTAssertNoThrow(try store.delete(id: id))
  }

  // MARK: Prune

  func testPruneOlderThanKeepsNamedByDefault() throws {
    let store = tempStore()
    let oldUnnamed = try seed(store)
    let oldNamed = try seed(store, name: "keep-me")
    let recent = try seed(store)
    try touch(store, id: oldUnnamed, daysAgo: 40)
    try touch(store, id: oldNamed, daysAgo: 40)

    let deleted = try store.prune(olderThan: 30)

    XCTAssertEqual(deleted, 1)
    let remaining = Set(try store.list().map(\.id))
    XCTAssertEqual(remaining, [oldNamed, recent])
    // --all sweeps the named one too; the recent session still survives.
    XCTAssertEqual(try store.prune(olderThan: 30, keepNamed: false), 1)
    XCTAssertEqual(try store.list().map(\.id), [recent])
  }

  func testPruneOfEmptyStoreIsZero() throws {
    XCTAssertEqual(try tempStore().prune(olderThan: 30), 0)
  }

  // MARK: Export

  func testExportMarkdownShape() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: "/tmp", name: "demo"), to: id)
    try store.append(TranscriptEntry(message: .user("list the files")), to: id)
    let call = ToolCall(
      id: "c1", index: 0,
      function: .init(name: "bash", arguments: "{\"command\":\"ls\"}"))
    try store.append(
      TranscriptEntry(message: Message(role: .assistant, content: .text("on it"), toolCalls: [call])),
      to: id)
    try store.append(
      TranscriptEntry(message: .tool("total 0\nfile.txt\nother.txt", toolCallId: "c1")), to: id)
    try store.append(.compaction(summary: "earlier: set up the repo"), to: id)
    try store.append(TranscriptEntry(message: Message(role: .assistant, content: .text("done"))), to: id)
    try store.append(.cost(turnUSD: 0.02, sessionUSD: 0.02), to: id)

    let markdown = try store.exportMarkdown(id: id)

    XCTAssertTrue(markdown.hasPrefix("# demo\n"), markdown)
    XCTAssertTrue(markdown.contains("- id: \(id)"))
    XCTAssertTrue(markdown.contains("- model: test/model"))
    XCTAssertTrue(markdown.contains("- cost: $0.0200"))
    XCTAssertTrue(markdown.contains("## user\n\nlist the files"))
    XCTAssertTrue(markdown.contains("## assistant\n\non it"))
    XCTAssertTrue(markdown.contains("> tool bash({\"command\":\"ls\"})"))
    // Results collapse to their first line — a 10k-line build log can't drown the export.
    XCTAssertTrue(markdown.contains("> ← bash: total 0"))
    XCTAssertFalse(markdown.contains("file.txt"))
    XCTAssertTrue(markdown.contains("> compacted older turns: earlier: set up the repo"))
    XCTAssertTrue(markdown.contains("## assistant\n\ndone"))
  }

  func testExportMarkdownClampsLongToolArguments() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    let long = String(repeating: "a", count: 500)
    let call = ToolCall(id: "c1", index: 0, function: .init(name: "write_file", arguments: long))
    try store.append(
      TranscriptEntry(message: Message(role: .assistant, content: .text(""), toolCalls: [call])), to: id)

    let line = try XCTUnwrap(
      try store.exportMarkdown(id: id).split(separator: "\n").first { $0.hasPrefix("> tool ") })
    XCTAssertTrue(line.hasSuffix("…)"), String(line))
    XCTAssertLessThan(line.count, 230)
    // An assistant message that is only a tool call gets no empty prose heading.
    XCTAssertFalse(try store.exportMarkdown(id: id).contains("## assistant"))
  }

  func testExportMarkdownIncludesForkParent() throws {
    let store = tempStore()
    let id = try seed(store)
    let forkId = try store.fork(id: id, name: nil)
    XCTAssertTrue(try store.exportMarkdown(id: forkId).contains("- forked from: \(id)"))
  }

  // MARK: Effort dial

  func testEffortChangeReplays() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    XCTAssertNil(try store.load(id: id).reasoningEffort)

    try store.append(.effortChange(.high), to: id)
    XCTAssertEqual(try store.load(id: id).reasoningEffort, .high)
    // Last one wins, and it survives a fork.
    try store.append(.effortChange(.low), to: id)
    XCTAssertEqual(try store.load(id: id).reasoningEffort, .low)
    let forkId = try store.fork(id: id, name: nil)
    XCTAssertEqual(try store.load(id: forkId).reasoningEffort, .low)
  }

  func testUnknownEffortLevelLeavesTheDialAlone() throws {
    let store = tempStore()
    let id = UUID().uuidString
    try store.append(.meta(id: id, model: "test/model", cwd: nil), to: id)
    try store.append(.effortChange(.medium), to: id)
    var future = TranscriptEntry(type: .effortChange)
    future.text = "ludicrous" // written by a newer arnes
    try store.append(future, to: id)

    XCTAssertEqual(try store.load(id: id).reasoningEffort, .medium)
  }

  // MARK: list() index

  func testListStaysCorrectAcrossTheIndexCache() throws {
    let store = tempStore()
    let first = try seed(store, name: "alpha", model: "one/model")
    let second = try seed(store, model: "two/model")
    try touch(store, id: first, daysAgo: 2)

    // Cold: nothing cached yet.
    let cold = try store.list()
    XCTAssertEqual(cold.map(\.id), [second, first]) // most recent first
    XCTAssertEqual(cold[1].name, "alpha")
    XCTAssertEqual(cold[1].model, "one/model")
    XCTAssertEqual(cold[1].messageCount, 2)
    XCTAssertTrue(FileManager.default.fileExists(atPath: store.indexURL.path))

    // Warm: same rows, served from the index.
    let warm = try store.list()
    XCTAssertEqual(warm.map(\.id), cold.map(\.id))
    XCTAssertEqual(warm.map(\.messageCount), cold.map(\.messageCount))
    XCTAssertEqual(warm.map(\.name), cold.map(\.name))

    // Appending invalidates the cached row (mtime + size both move).
    try store.append(TranscriptEntry(message: .user("another turn")), to: first)
    try store.rename(id: first, name: "renamed")
    let after = try store.list()
    XCTAssertEqual(after[0].id, first) // it is the most recently touched now
    XCTAssertEqual(after[0].name, "renamed")
    XCTAssertEqual(after[0].messageCount, 3)

    // A corrupt index is a cache miss, never a failure.
    try Data("not json".utf8).write(to: store.indexURL)
    XCTAssertEqual(try store.list().map(\.id), after.map(\.id))
  }

  func testIndexFileIsNotListedAsASession() throws {
    let store = tempStore()
    let id = try seed(store)
    _ = try store.list() // writes the index beside the transcript
    XCTAssertEqual(try store.list().map(\.id), [id])
  }

  // MARK: Headless persistence seam

  func testAgentRunPersistsWhenStoreGiven() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("task done"), Fixtures.usageChunk(cost: 0.01)]]
    let sessionStore = tempStore()
    let agent = Agent(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      sessionStore: sessionStore,
      configuration: .init(model: "test/model"))

    let result = try await agent.run(task: "do the thing", model: "test/model")

    XCTAssertFalse(result.sessionId.isEmpty)
    let listed = try sessionStore.list()
    XCTAssertEqual(listed.map(\.id), [result.sessionId])
    let loaded = try sessionStore.load(id: result.sessionId)
    XCTAssertEqual(loaded.meta.model, "test/model") // the meta line was written
    XCTAssertEqual(loaded.messages.map { $0.content?.plainText }, ["do the thing", "task done"])
    XCTAssertEqual(loaded.costUSD, 0.01, accuracy: 0.0001)
    XCTAssertEqual(loaded.turnCount, 1)
  }

  func testAgentRunWithoutStoreWritesNothing() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("task done"), Fixtures.usageChunk(cost: 0.01)]]
    let sessionStore = tempStore() // never handed to the agent
    let agent = Agent(
      service: mock, tools: [], store: tempRecordStore(), configuration: .init(model: "test/model"))

    let result = try await agent.run(task: "do the thing", model: "test/model")

    XCTAssertFalse(result.sessionId.isEmpty) // the run still has an identity
    XCTAssertTrue(try sessionStore.list().isEmpty)
    XCTAssertFalse(FileManager.default.fileExists(atPath: sessionStore.directory.path))
  }

  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-runs-\(UUID().uuidString).jsonl"))
  }
}
