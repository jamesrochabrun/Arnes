import OpenRouterSwift
import XCTest
@testable import ArnesKit

/// The stale-buffer gate: `edit_file`/`write_file` refuse a file this session never read
/// or that changed underneath it, and `read_file` (or a write, or a hook refresh) is what
/// makes it fresh again.
final class FileVersionsTests: XCTestCase {
  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-versions-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func file(_ contents: String, named name: String = "a.swift", in directory: URL) throws -> String {
    let path = directory.appendingPathComponent(name).path
    try contents.write(toFile: path, atomically: true, encoding: .utf8)
    return path
  }

  // MARK: edit_file

  func testEditRefusesUnreadFile() async throws {
    let directory = try tempDirectory()
    let path = try file("let x = 1\n", in: directory)
    let edit = EditFileTool(versions: FileVersions())

    let refused = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
    ])
    XCTAssertTrue(refused.contains("has not been read this session"), refused)
    XCTAssertTrue(refused.contains("read_file"), "the error names the fix")
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let x = 1\n", "nothing written")
  }

  func testEditRefusesStaleFileAfterExternalModification() async throws {
    let directory = try tempDirectory()
    let path = try file("let x = 1\n", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])

    // Something else wrote the file: another tool's bash command, the user, a formatter.
    // Different content, not merely a new mtime — a 1s-granularity filesystem must not be
    // what this depends on.
    try "let x = 42\nlet y = 7\n".write(toFile: path, atomically: true, encoding: .utf8)

    let refused = try await EditFileTool(versions: versions).execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
    ])
    XCTAssertTrue(refused.contains("changed on disk since you read it"), refused)
    XCTAssertEqual(
      try String(contentsOfFile: path, encoding: .utf8), "let x = 42\nlet y = 7\n",
      "the other writer's work survives")
  }

  func testSameSizeRewriteIsStale() async throws {
    let directory = try tempDirectory()
    let path = try file("let x = 1\n", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])
    // Same byte count, different bytes: size alone would call this fresh; the digest doesn't.
    try "let x = 9\n".write(toFile: path, atomically: true, encoding: .utf8)

    let refused = try await EditFileTool(versions: versions).execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 9"), "new_string": .string("let x = 2"),
    ])
    XCTAssertTrue(refused.contains("changed on disk"), refused)
  }

  func testNoOpTouchIsNotStale() async throws {
    let directory = try tempDirectory()
    let path = try file("let x = 1\n", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])
    // A formatter hook that decided there was nothing to reformat still moves the mtime.
    try FileManager.default.setAttributes(
      [.modificationDate: Date(timeIntervalSinceNow: 120)], ofItemAtPath: path)

    let status = await versions.check(path: path)
    XCTAssertEqual(status, .fresh, "content is what matters, not the timestamp")
  }

  func testReadThenEditIsFresh() async throws {
    let directory = try tempDirectory()
    let path = try file("let x = 1\n", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])

    let edit = EditFileTool(versions: versions)
    let edited = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
    ])
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
    // The edit itself re-records, so a follow-up edit doesn't need another read.
    let again = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 2"), "new_string": .string("let x = 3"),
    ])
    XCTAssertTrue(again.hasPrefix("edited "), again)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let x = 3\n")
  }

  func testWindowedReadCountsAsRead() async throws {
    let directory = try tempDirectory()
    let body = (1...100).map { "line\($0)" }.joined(separator: "\n")
    let path = try file(body, named: "big.txt", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: [
      "path": .string(path), "offset": .int(50), "limit": .int(5),
    ])

    let edited = try await EditFileTool(versions: versions).execute(arguments: [
      "path": .string(path), "old_string": .string("line52"), "new_string": .string("changed"),
    ])
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
  }

  // MARK: write_file

  func testWriteFileCreatesNewFileWithoutRead() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("new.txt").path
    let write = WriteFileTool(versions: FileVersions())

    let created = try await write.execute(arguments: [
      "path": .string(path), "content": .string("hello"),
    ])
    XCTAssertEqual(created, "created \(path) (5 bytes)")
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "hello")
  }

  func testWriteFileRefusesOverwritingUnreadFile() async throws {
    let directory = try tempDirectory()
    let path = try file("precious\n", named: "existing.txt", in: directory)

    let refused = try await WriteFileTool(versions: FileVersions()).execute(arguments: [
      "path": .string(path), "content": .string("clobbered"),
    ])
    XCTAssertTrue(refused.contains("has not been read this session"), refused)
    XCTAssertTrue(refused.contains("use edit_file for a targeted change"), refused)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "precious\n", "nothing written")
  }

  func testWriteFileOverwriteAfterReadReportsPreviousSize() async throws {
    let directory = try tempDirectory()
    let path = try file("precious\n", named: "existing.txt", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])

    let write = WriteFileTool(versions: versions)
    let overwritten = try await write.execute(arguments: [
      "path": .string(path), "content": .string("new body"),
    ])
    XCTAssertEqual(overwritten, "overwrote \(path) (8 bytes, was 9)")
    // Writing re-records too, so a second write in the same turn isn't refused.
    let again = try await write.execute(arguments: [
      "path": .string(path), "content": .string("third"),
    ])
    XCTAssertTrue(again.hasPrefix("overwrote "), again)
  }

  func testWriteFileRefusesStaleFile() async throws {
    let directory = try tempDirectory()
    let path = try file("one\n", named: "existing.txt", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])
    try "changed elsewhere\n".write(toFile: path, atomically: true, encoding: .utf8)

    let refused = try await WriteFileTool(versions: versions).execute(arguments: [
      "path": .string(path), "content": .string("clobbered"),
    ])
    XCTAssertTrue(refused.contains("changed on disk since you read it"), refused)
    XCTAssertTrue(refused.contains("use edit_file for a targeted change"), refused)
  }

  // MARK: Opting out

  func testNilVersionsDisablesChecks() async throws {
    let directory = try tempDirectory()
    let path = try file("let x = 1\n", in: directory)

    // No tracker (the pre-T3 shape, and what an unattended runner may choose): editing and
    // overwriting an unread file both go through.
    let edited = try await EditFileTool().execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
    ])
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
    let written = try await WriteFileTool().execute(arguments: [
      "path": .string(path), "content": .string("whatever"),
    ])
    XCTAssertTrue(written.hasPrefix("overwrote "), written)
  }

  func testCoreToolsWithoutATrackerSkipTheGate() async throws {
    let root = try tempDirectory()
    let path = try file("let x = 1\n", in: root)
    let tools = HarnessAssembly.coreTools(ToolContext(root: root, versions: nil))
    let edit = try XCTUnwrap(tools.first { $0.name == "edit_file" })

    let edited = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
    ])
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
  }

  // MARK: Wiring

  func testCoreToolsShareOneTrackerPerContext() async throws {
    let root = try tempDirectory()
    _ = try file("let x = 1\n", in: root)
    // The default context makes its own tracker, and all three file tools get that one —
    // reading through `read_file` is what frees `edit_file`.
    let tools = HarnessAssembly.coreTools(ToolContext(root: root))
    let read = try XCTUnwrap(tools.first { $0.name == "read_file" })
    let edit = try XCTUnwrap(tools.first { $0.name == "edit_file" })
    let arguments: [String: JSONValue] = [
      "path": .string("a.swift"), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
    ]

    let refused = try await edit.execute(arguments: arguments)
    XCTAssertTrue(refused.contains("has not been read this session"), refused)
    _ = try await read.execute(arguments: ["path": .string("a.swift")])
    let edited = try await edit.execute(arguments: arguments)
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
  }

  func testSeparateContextsDoNotShareReads() async throws {
    let root = try tempDirectory()
    let path = try file("let x = 1\n", in: root)
    let readerTools = HarnessAssembly.coreTools(ToolContext(root: root))
    _ = try await XCTUnwrap(readerTools.first { $0.name == "read_file" })
      .execute(arguments: ["path": .string(path)])

    // A subagent (or panel candidate) is a fresh context: it must read for itself.
    let otherTools = HarnessAssembly.coreTools(ToolContext(root: root))
    let refused = try await XCTUnwrap(otherTools.first { $0.name == "edit_file" })
      .execute(arguments: [
        "path": .string(path), "old_string": .string("let x = 1"), "new_string": .string("let x = 2"),
      ])
    XCTAssertTrue(refused.contains("has not been read this session"), refused)
  }

  // MARK: Hook refresh

  func testRefreshMakesAHookReformattedFileFreshAgain() async throws {
    let directory = try tempDirectory()
    let path = try file("let x=1\n", in: directory)
    let versions = FileVersions()
    _ = try await ReadFileTool(versions: versions).execute(arguments: ["path": .string(path)])
    let edit = EditFileTool(versions: versions)
    _ = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x=1"), "new_string": .string("let x=2"),
    ])

    // A PostToolUse formatter hook rewrites the file the edit just touched.
    try "let x = 2\n".write(toFile: path, atomically: true, encoding: .utf8)
    let stale = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 2"), "new_string": .string("let x = 3"),
    ])
    XCTAssertTrue(stale.contains("changed on disk"), stale)

    // …which is why the session re-records after hooks run (`FileVersionTracking`).
    await edit.recordCurrentVersion(ofPath: path)
    let edited = try await edit.execute(arguments: [
      "path": .string(path), "old_string": .string("let x = 2"), "new_string": .string("let x = 3"),
    ])
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
  }

  func testEveryFileToolCanRecordAVersion() async throws {
    let directory = try tempDirectory()
    let path = try file("body\n", in: directory)
    let versions = FileVersions()
    // The session calls this on whichever file tool ran; all three must honour it.
    let trackers: [any FileVersionTracking] = [
      ReadFileTool(versions: versions),
      WriteFileTool(versions: versions),
      EditFileTool(versions: versions),
    ]
    for tracker in trackers {
      await tracker.recordCurrentVersion(ofPath: path)
      let status = await versions.check(path: path)
      XCTAssertEqual(status, .fresh, "\(tracker.name) did not record")
    }
    // A tool with no tracker takes the call and does nothing.
    await EditFileTool().recordCurrentVersion(ofPath: path)
  }

  // MARK: The tracker itself

  func testCheckReportsUnreadFreshAndStale() async throws {
    let directory = try tempDirectory()
    let path = try file("hello\n", in: directory)
    let versions = FileVersions()

    var status = await versions.check(path: path)
    XCTAssertEqual(status, .unread)
    await versions.record(path: path)
    status = await versions.check(path: path)
    XCTAssertEqual(status, .fresh)
    try "hello there\n".write(toFile: path, atomically: true, encoding: .utf8)
    status = await versions.check(path: path)
    XCTAssertEqual(status, .stale)
    // A file that disappeared is stale, not fresh.
    try FileManager.default.removeItem(atPath: path)
    status = await versions.check(path: path)
    XCTAssertEqual(status, .stale)
  }

  func testPathSpellingsShareOneEntry() async throws {
    let directory = try tempDirectory()
    let path = try file("hello\n", in: directory)
    let versions = FileVersions()
    await versions.record(path: directory.appendingPathComponent("./a.swift").path)

    let status = await versions.check(path: path)
    XCTAssertEqual(status, .fresh, "paths are keyed physically, however the model spells them")
  }

  func testDigestSeesChangesBeyondTheFirstWindow() async throws {
    let directory = try tempDirectory()
    let head = String(repeating: "a", count: FileVersions.digestWindow)
    let tail = String(repeating: "b", count: FileVersions.digestWindow)
    let path = try file(head + tail, named: "big.txt", in: directory)
    let versions = FileVersions()
    await versions.record(path: path)

    // Same length, changed only in the trailing window.
    try (head + String(repeating: "c", count: FileVersions.digestWindow))
      .write(toFile: path, atomically: true, encoding: .utf8)
    let status = await versions.check(path: path)
    XCTAssertEqual(status, .stale)
  }
}
