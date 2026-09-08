import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class EditRecoveryTests: XCTestCase {
  func testFailedEditRereadAndExactEditRecoverInTheActualLoop() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-edit-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("example.txt")
    let original = "first line\r\nsecond line\r\n"
    try original.write(to: file, atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    func call(_ id: String, _ name: String, _ arguments: [String: String]) throws -> [ChatCompletionChunk] {
      [Fixtures.toolCallChunk(id: id, name: name,
        arguments: String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self))]
    }
    mock.chunkScripts = [
      try call("r1", "read_file", ["path": "example.txt"]),
      try call("e1", "edit_file", ["path": "example.txt", "old_string": "first line\nsecond line", "new_string": "wrong"]),
      try call("r2", "read_file", ["path": "example.txt"]),
      try call("e2", "edit_file", ["path": "example.txt", "old_string": "first line\r\nsecond line", "new_string": "first line\r\nrecovered"]),
      [Fixtures.textChunk("Recovered.")],
    ]
    let session = Session(service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      configuration: .init(model: "test/model", packsDirectory: root))
    _ = try await Events.drain(await session.send("Make the exact edit."))
    let results = try XCTUnwrap(mock.requests.last).messages.filter { $0.role == .tool }
    XCTAssertEqual(results.count, 4)
    XCTAssertTrue(results[1].content?.plainText.contains("CRLF/LF") == true)
    XCTAssertEqual(results[0].content?.plainText, results[2].content?.plainText, "failed edit wrote nothing")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "first line\r\nrecovered\r\n")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
    XCTAssertEqual(record?.toolStats?["edit_file"]?.errors, 1)
  }

  func testLineEndingMismatchIsDiagnosticOnly() {
    let old = "first line\nsecond line"
    let content = "first line\r\nsecond line"
    XCTAssertTrue(EditFileTool.matchRecoveryHint(old: old, content: content).contains("CRLF/LF"))
    guard case .failure = EditFileTool.apply([.init(oldString: old, newString: "changed")], to: content) else {
      return XCTFail("A diagnostic must not enable a fuzzy replacement")
    }
  }

  func testLocationHintDoesNotDiscloseExtraContents() {
    let hint = EditFileTool.matchRecoveryHint(old: "  function example() {\n  wrong",
      content: "private value\nfunction example() {\n  actual")
    XCTAssertTrue(hint.contains("line(s) 2"))
    XCTAssertFalse(hint.contains("private value"))
    XCTAssertFalse(hint.contains("actual"))
  }

  func testNoInventedLocationAndBoundedRepeatedMatches() {
    XCTAssertEqual(EditFileTool.matchRecoveryHint(old: "missing anchor", content: "unrelated"), "")
    let hint = EditFileTool.matchRecoveryHint(old: "repeated anchor\nmissing",
      content: String(repeating: "repeated anchor\n", count: 100))
    XCTAssertTrue(hint.contains("1, 2, 3, 4, 5"))
    XCTAssertTrue(hint.contains("more matches omitted"))
    XCTAssertLessThan(hint.count, 400)
  }
}
