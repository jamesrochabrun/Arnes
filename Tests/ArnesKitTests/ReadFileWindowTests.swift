import XCTest
@testable import ArnesKit

final class ReadFileWindowTests: XCTestCase {
  private func tempFile(lines: Int) throws -> String {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-read-\(UUID().uuidString).txt")
    let body = (1...lines).map { "line\($0)" }.joined(separator: "\n")
    try body.write(to: url, atomically: true, encoding: .utf8)
    return url.path
  }

  func testOffsetAndLimitWindow() async throws {
    let path = try tempFile(lines: 100)
    let out = try await ReadFileTool().execute(
      arguments: ["path": .string(path), "offset": .int(10), "limit": .int(3)])
    XCTAssertTrue(out.contains("10\tline10"), out)
    XCTAssertTrue(out.contains("12\tline12"), out)
    XCTAssertFalse(out.contains("13\tline13"), out)
    // Line numbers reflect true position, and the tail is summarized with a resume hint.
    XCTAssertTrue(out.contains("more line"), out)
    XCTAssertTrue(out.contains("offset 13"), out)
  }

  func testDefaultCapTruncatesHugeFile() async throws {
    let path = try tempFile(lines: ReadFileTool.defaultLineCap + 500)
    let out = try await ReadFileTool().execute(arguments: ["path": .string(path)])
    XCTAssertTrue(out.contains("1\tline1"), "starts at the top")
    XCTAssertTrue(out.contains("capped at \(ReadFileTool.defaultLineCap) lines"), out)
    XCTAssertTrue(out.contains("500 more lines"), out)
    XCTAssertFalse(out.contains("line\(ReadFileTool.defaultLineCap + 1)\t"), "past the cap not returned")
  }

  func testSmallFileUnchanged() async throws {
    let path = try tempFile(lines: 3)
    let out = try await ReadFileTool().execute(arguments: ["path": .string(path)])
    XCTAssertEqual(out, "1\tline1\n2\tline2\n3\tline3")
    XCTAssertFalse(out.contains("more line"))
  }

  func testOffsetPastEnd() async throws {
    let path = try tempFile(lines: 5)
    let out = try await ReadFileTool().execute(
      arguments: ["path": .string(path), "offset": .int(99)])
    XCTAssertTrue(out.contains("past end of file"), out)
  }
}
