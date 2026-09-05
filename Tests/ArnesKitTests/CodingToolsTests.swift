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

  // MARK: edit_file v2

  func testReplaceAllReplacesEveryOccurrence() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("c.swift").path
    try "old\nkeep\nold\nkeep\nold\n".write(toFile: path, atomically: true, encoding: .utf8)

    let result = try await EditFileTool().execute(arguments: [
      "path": .string(path),
      "old_string": .string("old"),
      "new_string": .string("new"),
      "replace_all": .bool(true),
    ])
    XCTAssertTrue(result.contains("replaced 3 occurrences"), result)
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "new\nkeep\nnew\nkeep\nnew\n")
  }

  func testEditWithoutReplaceAllStillCoachesOnAmbiguity() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("d.swift").path
    try "old\nkeep\nold\n".write(toFile: path, atomically: true, encoding: .utf8)

    let ambiguous = try await EditFileTool().execute(arguments: [
      "path": .string(path), "old_string": .string("old"), "new_string": .string("new"),
    ])
    XCTAssertTrue(ambiguous.contains("appears 2 times"), ambiguous)
    XCTAssertTrue(ambiguous.contains("more surrounding context"), ambiguous)
    XCTAssertTrue(ambiguous.contains("replace_all"), "the other way out is named too")
    XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "old\nkeep\nold\n", "nothing written")
  }

  func testEditResultShowsPostEditWindowWithLineNumbers() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("e.swift").path
    try (1...20).map { "line\($0)" }.joined(separator: "\n")
      .write(toFile: path, atomically: true, encoding: .utf8)

    let result = try await EditFileTool().execute(arguments: [
      "path": .string(path), "old_string": .string("line10"), "new_string": .string("changed"),
    ])
    XCTAssertTrue(result.hasPrefix("edited \(path): replaced 6 bytes with 7 bytes\n"), result)
    // Three lines of context each side of the change, numbered as read_file numbers them.
    XCTAssertTrue(result.contains("\n7\tline7\n"), result)
    XCTAssertTrue(result.contains("\n10\tchanged\n"), result)
    XCTAssertTrue(result.hasSuffix("\n13\tline13"), result)
    XCTAssertFalse(result.contains("6\tline6"), "the window stops three lines out")
    XCTAssertFalse(result.contains("14\tline14"), result)
  }

  func testPostEditWindowIsCappedForABigReplacement() async throws {
    let directory = try tempDirectory()
    let path = directory.appendingPathComponent("f.swift").path
    try "head\nBODY\ntail\n".write(toFile: path, atomically: true, encoding: .utf8)

    let replacement = (1...100).map { "new\($0)" }.joined(separator: "\n")
    let result = try await EditFileTool().execute(arguments: [
      "path": .string(path), "old_string": .string("BODY"), "new_string": .string(replacement),
    ])
    let numbered = result.split(separator: "\n").filter { $0.contains("\t") }
    XCTAssertEqual(numbered.count, EditFileTool.maxWindowLines)
    XCTAssertTrue(result.contains("window clipped to \(EditFileTool.maxWindowLines) lines"), result)
  }

  func testEditSummaryShowsMiniDiff() {
    let directory = try? tempDirectory()
    let tool = EditFileTool(root: directory)
    let summary = tool.summary(arguments: [
      "path": .string("Sources/x.swift"),
      "old_string": .string("let a = 1\nlet b = 2"),
      "new_string": .string("let a = 9"),
    ])
    let lines = summary.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines, [
      "edit_file Sources/x.swift (-2 +1 lines)",
      "  - let a = 1",
      "  - let b = 2",
      "  + let a = 9",
    ])
  }

  func testEditSummaryClipsLongLinesAndFlagsReplaceAll() {
    let directory = try? tempDirectory()
    let tool = EditFileTool(root: directory)
    let longLine = String(repeating: "x", count: 300)
    let summary = tool.summary(arguments: [
      "path": .string("x.swift"),
      "old_string": .string(([longLine] + (2...6).map { "line\($0)" }).joined(separator: "\n")),
      "new_string": .string("short"),
      "replace_all": .bool(true),
    ])
    let lines = summary.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines[0], "edit_file x.swift (-6 +1 lines, all occurrences)")
    XCTAssertEqual(lines.count, 5, "header plus at most 4 diff lines")
    XCTAssertEqual(lines[1].count, EditFileTool.summaryLineChars + 5, "clipped to 100 chars + ellipsis")
    XCTAssertTrue(lines[3].hasSuffix(" …"), "the elided remainder is visible: \(lines[3])")
    XCTAssertEqual(lines[4], "  + short")
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

  // MARK: grep/glob v2

  private func write(_ text: String, to relative: String, in directory: URL) throws {
    let url = directory.appendingPathComponent(relative)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  func testGrepSearchesHiddenDirectoriesButSkipsVCSAndBuildDirs() async throws {
    let directory = try tempDirectory()
    try write("needle: ci", to: ".github/workflows/ci.yml", in: directory)
    try write("needle = git internals", to: ".git/config", in: directory)
    try write("needle in build", to: ".build/debug/out.txt", in: directory)
    try write("needle in deps", to: "node_modules/pkg/index.js", in: directory)
    try write("needle in src", to: "Sources/main.swift", in: directory)

    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path),
    ])
    XCTAssertTrue(result.contains(".github/workflows/ci.yml"), result)
    XCTAssertTrue(result.contains("Sources/main.swift"), result)
    XCTAssertFalse(result.contains(".git/config"), result)
    XCTAssertFalse(result.contains(".build/"), result)
    XCTAssertFalse(result.contains("node_modules"), result)
  }

  func testGitignorePatternsAreSkipped() async throws {
    let directory = try tempDirectory()
    try write("*.log\ngenerated/\n# comment\n!keep.log\n", to: ".gitignore", in: directory)
    try write("needle", to: "app.log", in: directory)
    try write("needle", to: "generated/out.swift", in: directory)
    try write("needle", to: "src/real.swift", in: directory)

    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path),
    ])
    XCTAssertTrue(result.contains("src/real.swift"), result)
    XCTAssertFalse(result.contains("app.log"), result)
    XCTAssertFalse(result.contains("generated/"), result)
  }

  func testGrepCaseInsensitiveAndGlobFilter() async throws {
    let directory = try tempDirectory()
    try write("Needle here", to: "a.swift", in: directory)
    try write("needle there", to: "b.md", in: directory)

    let sensitive = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path),
    ])
    XCTAssertFalse(sensitive.contains("a.swift"))
    XCTAssertTrue(sensitive.contains("b.md"))

    let insensitive = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path), "case_insensitive": .bool(true),
    ])
    XCTAssertTrue(insensitive.contains("a.swift"))
    XCTAssertTrue(insensitive.contains("b.md"))

    let swiftOnly = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path),
      "case_insensitive": .bool(true), "glob": .string("*.swift"),
    ])
    XCTAssertTrue(swiftOnly.contains("a.swift"))
    XCTAssertFalse(swiftOnly.contains("b.md"))
  }

  func testGrepContextLinesRenderedRipgrepStyle() async throws {
    let directory = try tempDirectory()
    try write("one\ntwo\nneedle\nfour\nfive\nsix\nseven\nneedle\nnine\n", to: "f.txt", in: directory)
    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path), "context": .int(1),
    ])
    let lines = result.split(separator: "\n").map(String.init)
    let path = directory.appendingPathComponent("f.txt").path
    XCTAssertEqual(lines, [
      "\(path)-2-two", "\(path):3:needle", "\(path)-4-four",
      "--",
      "\(path)-7-seven", "\(path):8:needle", "\(path)-9-nine",
    ])
  }

  func testGrepContextWithTwoHitsNearTheEndOfAFileDoesNotTrap() async throws {
    // Batch 14: the first hit's context window already reached the last line, so the second
    // hit's window was empty — and the empty `first...end` range trapped, killing the process
    // (a whole eval arm died on a model's `context: 3` grep). No trailing newline: the trap
    // needs the hits within `context` of the last line.
    let directory = try tempDirectory()
    try write("one\ntwo\nthree\nneedle\nneedle", to: "f.txt", in: directory)
    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path), "context": .int(3),
    ])
    let path = directory.appendingPathComponent("f.txt").path
    XCTAssertEqual(result.split(separator: "\n").map(String.init), [
      "\(path)-1-one", "\(path)-2-two", "\(path)-3-three", "\(path):4:needle", "\(path):5:needle",
    ])
  }

  func testGrepRenderPrintsEveryHitOnceForEveryOverlap() {
    // Every pair of hits over a ten-line file at every context: each line at most once, in
    // order, every hit present — the windows may overlap or run past either end.
    let lines = (1...10).map { "l\($0)" }
    for context in 1...12 {
      for a in 0..<10 {
        for b in a..<10 {
          let hits = a == b ? [a] : [a, b]
          let rendered = GrepTool.render(file: "f", lines: lines, hits: hits, context: context)
          let numbers = rendered.filter { $0 != "--" }.compactMap { line -> Int? in
            Int(line.dropFirst(2).prefix { $0.isNumber })
          }
          XCTAssertEqual(numbers.count, Set(numbers).count, "repeated line for hits \(hits), context \(context)")
          XCTAssertEqual(numbers, numbers.sorted(), "out of order for hits \(hits), context \(context)")
          for hit in hits {
            XCTAssertTrue(numbers.contains(hit + 1), "hit \(hit) missing for context \(context)")
          }
        }
      }
    }
  }

  func testGrepFilesOnlyModeListsFilesWithCounts() async throws {
    let directory = try tempDirectory()
    try write("needle\nneedle\n", to: "two.txt", in: directory)
    try write("needle\n", to: "one.txt", in: directory)
    try write("nothing\n", to: "zero.txt", in: directory)
    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path), "files_only": .bool(true),
    ])
    XCTAssertTrue(result.contains("one.txt (1)"), result)
    XCTAssertTrue(result.contains("two.txt (2)"), result)
    XCTAssertFalse(result.contains("zero.txt"), result)
    XCTAssertFalse(result.contains(":1:"), "files_only must not list lines")
  }

  func testGrepTruncationSteersTheModel() async throws {
    let directory = try tempDirectory()
    try write(Array(repeating: "needle", count: 300).joined(separator: "\n"), to: "many.txt", in: directory)
    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path),
    ])
    XCTAssertEqual(result.split(separator: "\n").filter { $0.contains(":needle") }.count, GrepTool.maxMatches)
    XCTAssertTrue(result.contains("[\(GrepTool.maxMatches) matches shown — refine the pattern, add glob, or narrow path]"), result)
  }

  func testGrepClipsLongLines() async throws {
    let directory = try tempDirectory()
    try write("needle " + String(repeating: "x", count: 1000), to: "long.txt", in: directory)
    let result = try await GrepTool().execute(arguments: [
      "pattern": .string("needle"), "path": .string(directory.path),
    ])
    XCTAssertTrue(result.hasSuffix("…"), result.suffix(20).description)
    XCTAssertLessThan(result.count, 500)
  }

  func testGlobSortsByMtimeNewestFirstAndIncludesHiddenFiles() async throws {
    let directory = try tempDirectory()
    try write("a", to: "older.swift", in: directory)
    try write("b", to: ".hidden/newer.swift", in: directory)
    try write("c", to: ".git/objects/x.swift", in: directory)
    let older = directory.appendingPathComponent("older.swift").path
    let newer = directory.appendingPathComponent(".hidden/newer.swift").path
    try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: older)
    try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer)

    let result = try await GlobTool().execute(arguments: [
      "pattern": .string("*.swift"), "path": .string(directory.path),
    ])
    XCTAssertEqual(result.split(separator: "\n").map(String.init), [".hidden/newer.swift", "older.swift"])
  }

  func testGlobTruncationReportsTotal() async throws {
    let directory = try tempDirectory()
    for index in 0..<(GlobTool.maxResults + 20) {
      try write("x", to: "f\(index).txt", in: directory)
    }
    let result = try await GlobTool().execute(arguments: [
      "pattern": .string("*.txt"), "path": .string(directory.path),
    ])
    let listed = result.split(separator: "\n").filter { $0.hasSuffix(".txt") }.count
    XCTAssertEqual(listed, GlobTool.maxResults)
    XCTAssertTrue(result.contains("[\(GlobTool.maxResults) of \(GlobTool.maxResults + 20) shown, newest first — narrow the pattern or path]"), result)
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
