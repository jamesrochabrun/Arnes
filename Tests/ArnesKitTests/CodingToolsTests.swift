import XCTest
@testable import ArnesKit

final class CodingToolsTests: XCTestCase {
  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-coding-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testEditReplacesUniqueString() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("a.swift").path
    try "let x = 1\nlet y = 2\n".write(toFile: path, atomically: true, encoding: .utf8)

    let result = try await EditFileTool().execute(arguments: [
      "path": .string(path),
      "old_string": .string("let y = 2"),
      "new_string": .string("let y = 3"),
    ])
    XCTAssertTrue(result.hasPrefix("edited"))
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "let x = 1\nlet y = 3\n")
  }

  func testEditCoachesOnMissingAndAmbiguousMatches() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("b.swift").path
    try "same\nsame\n".write(toFile: path, atomically: true, encoding: .utf8)

    let missing = try await EditFileTool().execute(arguments: [
      "path": .string(path),
      "old_string": .string("absent"),
      "new_string": .string("x"),
    ])
    XCTAssertTrue(missing.contains("not found"))
    XCTAssertTrue(missing.contains("re-read"))

    let ambiguous = try await EditFileTool().execute(arguments: [
      "path": .string(path),
      "old_string": .string("same"),
      "new_string": .string("x"),
    ])
    XCTAssertTrue(ambiguous.contains("2 times"))
    XCTAssertTrue(ambiguous.contains("more surrounding context"))
    // Nothing was written on either failure.
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "same\nsame\n")
  }

  func testGrepFindsMatchesWithLineNumbers() async throws {
    let directory = try tempDirectory()
    try "alpha\nneedle here\nbeta\n".write(
      toFile: directory.appendingPathComponent("one.txt").path, atomically: true, encoding: .utf8)
    try "no match\n".write(
      toFile: directory.appendingPathComponent("two.txt").path, atomically: true, encoding: .utf8)

    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"),
      "path": .string(directory.path),
    ])
    XCTAssertTrue(result.contains("one.txt:2:needle here"))
    XCTAssertFalse(result.contains("two.txt"))
  }

  func testGrepReportsInvalidRegexAndNoMatches() async throws {
    let directory = try tempDirectory()
    let invalid = try await GrepTool().execute(arguments: [
      "pattern": .string("(unclosed"),
      "path": .string(directory.path),
    ])
    XCTAssertTrue(invalid.contains("error: invalid regex"))

    let empty = try await GrepTool().execute(arguments: [
      "pattern": .string("nothing"),
      "path": .string(directory.path),
    ])
    XCTAssertTrue(empty.contains("no matches"))
  }

  func testGlobMatchesRelativePathsAndBasenames() async throws {
    let directory = try tempDirectory()
    let nested = directory.appendingPathComponent("Sources/Deep")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try "x".write(toFile: nested.appendingPathComponent("File.swift").path, atomically: true, encoding: .utf8)
    try "x".write(toFile: directory.appendingPathComponent("README.md").path, atomically: true, encoding: .utf8)

    let swiftOnly = try await GlobTool().execute(arguments: [
      "pattern": .string("*.swift"),
      "path": .string(directory.path),
    ])
    XCTAssertTrue(swiftOnly.contains("Sources/Deep/File.swift"))
    XCTAssertFalse(swiftOnly.contains("README.md"))

    let none = try await GlobTool().execute(arguments: [
      "pattern": .string("*.kt"),
      "path": .string(directory.path),
    ])
    XCTAssertTrue(none.contains("no files matching"))
  }

  func testPermissionClassification() {
    XCTAssertEqual(ReadFileTool().permission, .readOnly)
    XCTAssertEqual(GrepTool().permission, .readOnly)
    XCTAssertEqual(GlobTool().permission, .readOnly)
    XCTAssertEqual(BashTool().permission, .mutating)
    XCTAssertEqual(WriteFileTool().permission, .mutating)
    XCTAssertEqual(EditFileTool().permission, .mutating)
  }

  func testBashSummaryShowsCommandVerbatim() {
    let summary = BashTool().summary(arguments: ["command": .string("rm -rf build")])
    XCTAssertEqual(summary, "bash: rm -rf build")
  }
}
