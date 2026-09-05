import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// A checkpoint store that only counts what `edit_file` snapshots.
private final class CountingCheckpointStore: CheckpointStore, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [String] = []
  var snapshots: [String] { lock.withLock { recorded } }

  func snapshot(path: String) async -> Checkpoint? {
    lock.withLock { recorded.append(path) }
    return nil
  }

  func rewind(toTurn turn: Int) async throws -> CheckpointRestore { CheckpointRestore() }
}

/// T7 — `edit_file`'s `edits` array: sequential, atomic, one prompt / checkpoint / write.
final class MultiEditTests: XCTestCase {
  private typealias Edit = EditFileTool.Edit

  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-multiedit-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, named name: String = "a.swift", in directory: URL) throws -> String {
    let path = directory.appendingPathComponent(name).path
    try text.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  private func edit(_ old: String, _ new: String, all: Bool = false) -> JSONValue {
    var object: [String: JSONValue] = ["old_string": .string(old), "new_string": .string(new)]
    if all { object["replace_all"] = .bool(true) }
    return .object(object)
  }

  private func contents(_ path: String) throws -> String {
    try String(contentsOfFile: path, encoding: .utf8)
  }

  /// A tool over a file the session has read, with a counting store.
  private func readTool(for path: String) async -> (tool: EditFileTool, store: CountingCheckpointStore) {
    let versions = FileVersions()
    await versions.record(path: path)
    let store = CountingCheckpointStore()
    return (EditFileTool(versions: versions, checkpoints: store), store)
  }

  // MARK: apply

  func testApplyIsSequentialAndAnOldStringAnEarlierEditRemovedIsNotFound() throws {
    let text = "let a = 1\nlet b = 2\n"
    let applied = try XCTUnwrap(try? EditFileTool.apply([
      Edit(oldString: "let a = 1", newString: "let alpha = 10"),
      Edit(oldString: "alpha = 10", newString: "alpha = 11"), // matches what edit 1 produced
    ], to: text).get())
    XCTAssertEqual(applied.updated, "let alpha = 11\nlet b = 2\n")
    XCTAssertEqual(applied.replaced, 2)
    XCTAssertEqual(applied.spans.count, 1, "the second edit rewrote part of the first's span — merged")
    XCTAssertEqual(applied.removedBytes, "let a = 1".utf8.count + "alpha = 10".utf8.count)
    XCTAssertEqual(applied.addedBytes, "let alpha = 10".utf8.count + "alpha = 11".utf8.count)

    guard case .failure(let failure) = EditFileTool.apply([
      Edit(oldString: "let a = 1", newString: "let alpha = 10"),
      Edit(oldString: "let a = 1", newString: "x"),
    ], to: text) else { return XCTFail("edit 2's old text was removed by edit 1") }
    XCTAssertEqual(failure.index, 2)
    XCTAssertEqual(failure.reason, .notFound)
    XCTAssertEqual(failure.edit.newString, "x")
  }

  func testApplyJudgesUniquenessAgainstTheRunningTextAndHonorsReplaceAllPerEdit() throws {
    let text = "same\nother\n"
    guard case .failure(let failure) = EditFileTool.apply([
      Edit(oldString: "other", newString: "same"), // now "same" appears twice
      Edit(oldString: "same", newString: "x"),
    ], to: text) else { return XCTFail("edit 2 is ambiguous in the text edit 1 produced") }
    XCTAssertEqual(failure.index, 2)
    XCTAssertEqual(failure.reason, .ambiguous(count: 2))

    let all = try XCTUnwrap(try? EditFileTool.apply([
      Edit(oldString: "other", newString: "same"),
      Edit(oldString: "same", newString: "x", replaceAll: true),
    ], to: text).get())
    XCTAssertEqual(all.updated, "x\nx\n")
    XCTAssertEqual(all.replaced, 3)
    XCTAssertEqual(all.spans, [0..<1, 2..<3])

    guard case .failure(let empty) = EditFileTool.apply([Edit(oldString: "", newString: "x")], to: text)
    else { return XCTFail("an empty old_string never applies") }
    XCTAssertEqual(empty.reason, .empty)
    XCTAssertEqual(empty.index, 1)
  }

  func testApplyKeepsSpansInFinalTextCoordinates() throws {
    // Edits in reverse position order, so every later edit shifts the earlier spans: the
    // second is shorter than its old text (−3), the third longer (+2).
    let edits = [
      Edit(oldString: "cccc", newString: "CCCCCCCC"),
      Edit(oldString: "bbbb", newString: "B"),
      Edit(oldString: "aaaa", newString: "AAAAAA"),
    ]
    let applied = try XCTUnwrap(try? EditFileTool.apply(edits, to: "aaaa\nbbbb\ncccc\n").get())
    XCTAssertEqual(applied.updated, "AAAAAA\nB\nCCCCCCCC\n")
    XCTAssertEqual(applied.spans, [0..<6, 7..<8, 9..<17])
    let final = Array(applied.updated)
    for (span, edit) in zip(applied.spans, edits.reversed()) {
      XCTAssertEqual(String(final[span]), edit.newString, "span \(span) must cover the text the edit wrote")
    }
    XCTAssertEqual(applied.removedBytes, 12)
    XCTAssertEqual(applied.addedBytes, 15)

    // An overlapping pair is one span: edit 2 rewrites part of what edit 1 inserted.
    let overlapping = try XCTUnwrap(try? EditFileTool.apply([
      Edit(oldString: "hello", newString: "hello big"),
      Edit(oldString: "big world", newString: "small world"),
    ], to: "hello world").get())
    XCTAssertEqual(overlapping.updated, "hello small world")
    XCTAssertEqual(overlapping.spans, [0..<17])
  }

  func testTheSingleFormIsReplacingByteForByte() {
    let cases: [(old: String, new: String, all: Bool, text: String)] = [
      ("let y = 2", "let y = 3", false, "let x = 1\nlet y = 2\n"),
      ("old", "new", true, "old\nkeep\nold\nkeep\nold\n"),
      ("old", "", true, "old\nkeep\nold\n"),
      ("a\nb", "one\ntwo\nthree", false, "x\na\nb\ny\n"),
      ("é", "e", true, "café\nrésumé\n"),
    ]
    for c in cases {
      let legacy = EditFileTool.replacing(c.old, with: c.new, in: c.text, all: c.all)
      guard case .success(let applied) = EditFileTool.apply(
        [Edit(oldString: c.old, newString: c.new, replaceAll: c.all)], to: c.text)
      else { return XCTFail("\(c) should apply") }
      XCTAssertEqual(applied.updated, legacy.updated, "\(c)")
      XCTAssertEqual(applied.spans, legacy.spans, "\(c)")
    }
  }

  // MARK: execute

  func testMultiFormWritesOnceTakesOneCheckpointAndRecordsTheVersion() async throws {
    let directory = try tempDirectory()
    let path = try write("one\ntwo\nthree\n", in: directory)
    let (tool, store) = await readTool(for: path)

    let result = try await tool.execute(arguments: [
      "path": .string(path),
      "edits": .array([edit("one", "1"), edit("two", "2"), edit("three", "3")]),
    ])
    XCTAssertTrue(result.hasPrefix("edited \(path): applied 3 edits (replaced 11 bytes with 3 bytes)\n"), result)
    XCTAssertEqual(try contents(path), "1\n2\n3\n")
    XCTAssertEqual(store.snapshots, [path], "one checkpoint for the whole call")
    for line in ["1\t1", "2\t2", "3\t3"] {
      XCTAssertTrue(result.contains(line), "the window covers every span: \(result)")
    }
    XCTAssertFalse(result.contains("outside it"), "nothing was clipped")

    // `versions.record` ran after the write: a follow-up single edit passes the staleness gate.
    let again = try await tool.execute(arguments: [
      "path": .string(path), "old_string": .string("2"), "new_string": .string("two"),
    ])
    XCTAssertTrue(again.hasPrefix("edited"), again)
    XCTAssertEqual(store.snapshots, [path, path])
  }

  func testAnUnreadFileIsRefusedBeforeAnythingHappens() async throws {
    let directory = try tempDirectory()
    let path = try write("one\ntwo\n", in: directory)
    let store = CountingCheckpointStore()
    let tool = EditFileTool(versions: FileVersions(), checkpoints: store)
    let result = try await tool.execute(arguments: [
      "path": .string(path),
      "edits": .array([edit("one", "1"), edit("two", "2")]),
    ])
    XCTAssertTrue(result.contains("has not been read this session"), result)
    XCTAssertEqual(try contents(path), "one\ntwo\n")
    XCTAssertTrue(store.snapshots.isEmpty)
  }

  func testAFailureAtEditThreeOfFiveWritesNothingAndTakesNoCheckpoint() async throws {
    let directory = try tempDirectory()
    let original = "a\nb\nc\nd\ne\n"
    let path = try write(original, in: directory)
    let (tool, store) = await readTool(for: path)

    let missing = try await tool.execute(arguments: [
      "path": .string(path),
      "edits": .array([edit("a", "A"), edit("b", "B"), edit("zzz", "Z"), edit("d", "D"), edit("e", "E")]),
    ])
    XCTAssertEqual(
      missing,
      "error: edit 3 of 5: old_string not found in \(path) — nothing was written; re-read the file "
        + "and copy the exact text (edits 1–2 would have applied)")
    XCTAssertEqual(try contents(path), original, "byte-identical after a failed multi-edit")
    XCTAssertTrue(store.snapshots.isEmpty, "no checkpoint for a call that wrote nothing")

    let ambiguousPath = try write("x\nx\ny\n", named: "b.swift", in: directory)
    let (ambiguousTool, ambiguousStore) = await readTool(for: ambiguousPath)
    let ambiguous = try await ambiguousTool.execute(arguments: [
      "path": .string(ambiguousPath),
      "edits": .array([edit("y", "Y"), edit("x", "X")]),
    ])
    XCTAssertEqual(
      ambiguous,
      "error: edit 2 of 2: old_string appears 2 times in \(ambiguousPath) — nothing was written; "
        + "include more surrounding context or set replace_all on that edit (edit 1 would have applied)")
    XCTAssertEqual(try contents(ambiguousPath), "x\nx\ny\n")
    XCTAssertTrue(ambiguousStore.snapshots.isEmpty)

    // The first edit failing names no earlier edits.
    let first = try await ambiguousTool.execute(arguments: [
      "path": .string(ambiguousPath),
      "edits": .array([edit("nope", "Y"), edit("y", "Y")]),
    ])
    XCTAssertTrue(first.hasSuffix("copy the exact text"), first)
  }

  func testBothFormsNeitherFormAndMalformedArraysAreCoached() async throws {
    let directory = try tempDirectory()
    let path = try write("one\n", in: directory)
    let (tool, store) = await readTool(for: path)
    let base: [String: JSONValue] = ["path": .string(path)]

    func run(_ extra: [String: JSONValue]) async throws -> String {
      try await tool.execute(arguments: base.merging(extra) { $1 })
    }
    let both = try await run(["old_string": .string("one"), "new_string": .string("1"), "edits": .array([edit("one", "1")])])
    XCTAssertEqual(both, "error: pass either old_string/new_string or edits, not both")
    let neither = try await run([:])
    XCTAssertEqual(neither, "error: missing 'old_string' and 'new_string' (or an edits array)")
    let empty = try await run(["edits": .array([])])
    XCTAssertTrue(empty.hasPrefix("error: edits is empty"), empty)
    let notArray = try await run(["edits": .string("one")])
    XCTAssertTrue(notArray.hasPrefix("error: edits must be an array"), notArray)
    let tooMany = try await run(["edits": .array((0..<101).map { edit("one", "\($0)") })])
    XCTAssertTrue(tooMany.hasPrefix("error: edits has 101 entries — at most 100 per call"), tooMany)
    let malformed = try await run(["edits": .array([edit("one", "1"), .object(["old_string": .string("x")])])])
    XCTAssertTrue(malformed.hasPrefix("error: edit 2 of 2 is missing old_string or new_string"), malformed)
    let emptyOld = try await run(["edits": .array([edit("one", "1"), edit("", "x")])])
    XCTAssertEqual(
      emptyOld,
      "error: edit 2 of 2: old_string is empty — nothing was written; every edit replaces existing "
        + "text (use write_file to create a new file)")
    XCTAssertEqual(try contents(path), "one\n")
    XCTAssertTrue(store.snapshots.isEmpty)
  }

  func testTheWindowCoversEverySpanAndNamesTheRegionsPastTheCap() async throws {
    let directory = try tempDirectory()
    let path = try write((1...80).map { "line \($0)" }.joined(separator: "\n") + "\n", in: directory)
    let (tool, _) = await readTool(for: path)
    let result = try await tool.execute(arguments: [
      "path": .string(path),
      "edits": .array([edit("line 1\n", "LINE 1\n"), edit("line 10\n", "LINE 10\n"),
                       edit("line 60\n", "LINE 60\n"), edit("line 70\n", "LINE 70\n")]),
    ])
    XCTAssertTrue(result.hasPrefix("edited \(path): applied 4 edits"), result)
    XCTAssertTrue(result.contains("\n1\tLINE 1\n"), result)
    XCTAssertTrue(result.contains("\n10\tLINE 10\n"), result)
    XCTAssertTrue(result.contains("… window clipped to 40 lines"), result)
    XCTAssertTrue(
      result.hasSuffix("[… the window is capped at 40 lines; 2 edited regions are outside it — "
        + "read_file with offset to check them]"), result)
    XCTAssertFalse(result.contains("LINE 60"), "past the cap, named not shown")

    let small = try write("a\nb\nc\nd\ne\n", named: "small.swift", in: directory)
    let (smallTool, _) = await readTool(for: small)
    let shown = try await smallTool.execute(arguments: [
      "path": .string(small), "edits": .array([edit("a", "A"), edit("e", "E")]),
    ])
    XCTAssertTrue(shown.contains("1\tA") && shown.contains("5\tE"), shown)
    XCTAssertFalse(shown.contains("capped"), shown)
  }

  func testTheSingleFormResultsAreUntouched() async throws {
    let directory = try tempDirectory()
    let path = try write("old\nkeep\nold\n", in: directory)
    let (tool, _) = await readTool(for: path)
    let ambiguous = try await tool.execute(arguments: [
      "path": .string(path), "old_string": .string("old"), "new_string": .string("new"),
    ])
    XCTAssertEqual(
      ambiguous,
      "error: old_string appears 2 times in \(path) — include more surrounding context to make it "
        + "unique, or pass replace_all: true to change all of them")
    let all = try await tool.execute(arguments: [
      "path": .string(path), "old_string": .string("old"), "new_string": .string("new"), "replace_all": .bool(true),
    ])
    XCTAssertTrue(all.hasPrefix("edited \(path): replaced 2 occurrences (6 bytes with 6 bytes)\n"), all)
    let one = try await tool.execute(arguments: [
      "path": .string(path), "old_string": .string("keep"), "new_string": .string("kept"),
    ])
    XCTAssertTrue(one.hasPrefix("edited \(path): replaced 4 bytes with 4 bytes\n"), one)
    let empty = try await tool.execute(arguments: [
      "path": .string(path), "old_string": .string(""), "new_string": .string("x"),
    ])
    XCTAssertEqual(empty, "error: old_string is empty — use write_file to create a new file")
  }

  // MARK: summary, schema

  func testSummaryNamesTheEditCountAndShowsTheFirstEdit() {
    let tool = EditFileTool()
    let summary = tool.summary(arguments: [
      "path": .string("a.swift"),
      "edits": .array([edit("let a = 1", "let a = 2"), edit("b", "c"), edit("d\ne", "f")]),
    ])
    let lines = summary.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.first, "edit_file a.swift (3 edits, -4 +3 lines)")
    XCTAssertTrue(lines.contains("  - let a = 1"), summary)
    XCTAssertTrue(lines.contains("  + let a = 2"), summary)
    XCTAssertEqual(lines.last, "  … (2 more edits)")
    XCTAssertFalse(summary.contains("- b"), "only the first edit's rows are shown")
    XCTAssertEqual(tool.summary(arguments: ["path": .string("a.swift"), "edits": .string("bad")]), "edit_file a.swift (edits)")
    // The single form's summary is what it was.
    XCTAssertEqual(
      tool.summary(arguments: ["path": .string("a.swift"), "old_string": .string("x"), "new_string": .string("y")]),
      "edit_file a.swift (-1 +1 lines)\n  - x\n  + y")
  }

  func testSchemaRequiresOnlyPathAndDescribesTheArray() throws {
    let tool = EditFileTool()
    XCTAssertEqual(tool.parameters["required"], ["path"])
    let edits = try XCTUnwrap(tool.parameters["properties"]?["edits"])
    XCTAssertEqual(edits["type"], "array")
    XCTAssertEqual(edits["items"]?["required"], ["old_string", "new_string"])
    XCTAssertEqual(edits["items"]?["properties"]?["replace_all"]?["type"], "boolean")
    XCTAssertTrue(tool.description.contains("pass edits instead"), tool.description)
    XCTAssertEqual(EditFileTool.edits(from: ["edits": .array([edit("a", "b", all: true)])]),
                   [Edit(oldString: "a", newString: "b", replaceAll: true)])
    XCTAssertNil(EditFileTool.edits(from: ["edits": .array([])]))
  }

  // MARK: preflight (the session refuses a missing path; the array form reaches the tool)

  func testPreflightStillRefusesAMissingPathAndTheArrayFormReachesTheTool() async throws {
    let directory = try tempDirectory()
    let path = try write("old\n", named: "a.txt", in: directory)
    let tool = EditFileTool(root: directory)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let edits = #"[{"old_string":"old","new_string":"new"}]"#
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "edit_file", arguments: #"{"edits": \#(edits)}"#),
       Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c2", name: "edit_file", arguments: #"{"path": "a.txt", "edits": \#(edits)}"#),
       Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let session = Session(
      service: mock, tools: [tool], store: TestPaths.recordStore(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("go"))
    func toolMessages(_ request: ChatCompletionRequest) -> [String] {
      request.messages.filter { $0.role == .tool }.map { $0.content?.plainText ?? "" }
    }
    XCTAssertEqual(toolMessages(mock.requests[1]).first, "error: edit_file needs path. Got: edits.")
    XCTAssertEqual(try contents(path), "new\n", "a call with edits and no old_string ran")
    XCTAssertTrue(toolMessages(mock.requests[2]).last?.contains("applied 1 edit (") == true,
                  toolMessages(mock.requests[2]).last ?? "")
  }

  // MARK: hooks — a `when` on old_string covers the array form

  func testAWhenHookOnOldStringFiresOnTheMatchingElementOfAnEditsArray() async {
    let noTodo = HookDefinition(
      event: .preToolUse, matcher: "edit_file", when: ["old_string": "TODO"], command: "exit 2", id: "no-todo")
    let engine = HookEngine(hooks: [noTodo])
    let hit = await engine.dryRun(
      event: .preToolUse, subject: "edit_file",
      argumentsJSON: #"{"path":"a.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"},{"old_string":"// TODO later","new_string":""}]}"#)
    XCTAssertEqual(hit.count, 1)
    XCTAssertNil(hit[0].skipped, "the third edit matches — the hook fires")
    XCTAssertTrue(hit[0].applied)
    XCTAssertEqual(hit[0].exitCode, 2)

    let miss = await engine.dryRun(
      event: .preToolUse, subject: "edit_file",
      argumentsJSON: #"{"path":"a.swift","edits":[{"old_string":"a","new_string":"b"},{"old_string":"c","new_string":"d"}]}"#)
    XCTAssertEqual(miss[0].skipped, .when)
    XCTAssertEqual(miss[0].failedWhenKeys, ["old_string"])

    let root: URL? = nil
    let topLevel: JSONValue = .object(["path": .string("a.swift"), "old_string": .string("// TODO")])
    XCTAssertTrue(noTodo.matches(arguments: topLevel, root: root), "the top-level form still matches")
    let nonScalar: JSONValue = .object([
      "path": .string("a.swift"),
      "old_string": .array([.string("TODO")]),
      "edits": .array([.object(["old_string": .string("TODO")])]),
    ])
    XCTAssertFalse(noTodo.matches(arguments: nonScalar, root: root),
                   "a non-scalar top-level value is the key being sent — the array is not consulted")
    let bareElements: JSONValue = .object(["path": .string("a.swift"), "edits": .array([.string("TODO")])])
    XCTAssertFalse(noTodo.matches(arguments: bareElements, root: root), "a non-object element carries no key")
    let pathHook = HookDefinition(event: .preToolUse, matcher: "edit_file", when: ["path": "**/*.swift"], command: "true")
    let pathOnly: JSONValue = .object(["path": .string("src/a.swift"), "edits": .array([])])
    XCTAssertTrue(pathHook.matches(arguments: pathOnly, root: root))
  }

  func testCanonicalToolNameMapsMultiEditOntoEditFile() {
    XCTAssertEqual(AgentLibrary.canonicalToolName("MultiEdit"), "edit_file")
    XCTAssertEqual(AgentLibrary.canonicalToolName("multi_edit"), "edit_file")
    XCTAssertEqual(AgentLibrary.canonicalToolName("Edit"), "edit_file")
  }
}
