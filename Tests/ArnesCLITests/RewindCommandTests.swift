import ArnesKit
import XCTest
@testable import arnes

/// The REPL side of C4 without a terminal: `/rewind`, `/undo`, `/diff` parsing, the rewind
/// argument grammar, the listing and summary formatters, and the diff coloring. The y/N
/// confirmation itself reads a key (`Interactive.confirm`) and is exercised live.
final class RewindCommandTests: XCTestCase {

  // MARK: Slash commands

  func testSlashCommandsParse() throws {
    guard case .rewind(let none)? = SlashCommand.parse("/rewind") else { return XCTFail("expected .rewind") }
    XCTAssertNil(none)
    guard case .rewind(let scoped)? = SlashCommand.parse("/rewind 3 code") else { return XCTFail("expected .rewind") }
    XCTAssertEqual(scoped, "3 code")
    guard case .undo? = SlashCommand.parse("/undo") else { return XCTFail("expected .undo") }
    guard case .diff? = SlashCommand.parse("  /DIFF ") else { return XCTFail("expected .diff") }
    XCTAssertFalse(Interactive.swapsHistory(.rewind(argument: "1")), "the method refuses on pending work itself")
  }

  func testHelpTextDocumentsTheThree() {
    XCTAssertTrue(SlashCommand.helpText.contains("/rewind [n [what]]"))
    XCTAssertTrue(SlashCommand.helpText.contains("/undo"))
    XCTAssertTrue(SlashCommand.helpText.contains("/diff"))
    XCTAssertTrue(SlashCommand.helpText.contains("bash edits and commits are not checkpointed"))
  }

  // MARK: /rewind arguments

  func testRewindRequestGrammar() {
    XCTAssertEqual(RewindRequest.parse("3"), RewindRequest(turn: 3, scope: .both))
    XCTAssertEqual(RewindRequest.parse("#3"), RewindRequest(turn: 3, scope: .both))
    XCTAssertEqual(RewindRequest.parse("3 code"), RewindRequest(turn: 3, scope: .code))
    XCTAssertEqual(RewindRequest.parse("3 Conversation"), RewindRequest(turn: 3, scope: .conversation))
    XCTAssertEqual(RewindRequest.parse("0 both"), RewindRequest(turn: 0, scope: .both))
    XCTAssertNil(RewindRequest.parse("three"))
    XCTAssertNil(RewindRequest.parse("-1"))
    XCTAssertNil(RewindRequest.parse("3 files"))
    XCTAssertNil(RewindRequest.parse("3 code now"))
    XCTAssertTrue(RewindRequest.Scope.code.restoresCode)
    XCTAssertFalse(RewindRequest.Scope.code.restoresConversation)
    XCTAssertTrue(RewindRequest.Scope.conversation.restoresConversation)
    XCTAssertFalse(RewindRequest.Scope.conversation.restoresCode)
    XCTAssertTrue(RewindRequest.Scope.both.restoresCode && RewindRequest.Scope.both.restoresConversation)
  }

  // MARK: Listing + summary

  func testListingShowsTurnsPromptsAndFiles() {
    let lines = RewindListing.lines([
      RewindListing.Turn(turn: 0, prompt: "add a README\nwith details", files: ["README.md"]),
      RewindListing.Turn(
        turn: 1,
        prompt: String(repeating: "x", count: 80),
        files: ["Sources/App/Router.swift", "Tests/RouterTests.swift"]),
      RewindListing.Turn(turn: 2, prompt: "just talk", files: []),
    ], checkpointOnlyTurns: [7])
    XCTAssertEqual(lines.count, 5)
    XCTAssertTrue(lines[0].hasPrefix("#0   add a README"), lines[0])
    XCTAssertTrue(lines[0].hasSuffix("files: README.md"), lines[0])
    XCTAssertTrue(lines[1].contains("…"), "a long prompt is clipped")
    XCTAssertTrue(lines[1].hasSuffix("files: Sources/App/Router.swift, Tests/RouterTests.swift"), lines[1])
    XCTAssertFalse(lines[2].contains("files:"), "a turn that changed nothing lists no files")
    XCTAssertTrue(lines[3].contains("#7"), lines[3])
    XCTAssertTrue(lines[3].contains("no longer in the conversation"), lines[3])
    XCTAssertTrue(lines[4].contains("/undo"), lines[4])
    XCTAssertEqual(RewindListing.lines([]), [RewindListing.empty])
  }

  func testFirstLineClipsAndRelativePathsStripTheCwd() {
    XCTAssertEqual(RewindListing.firstLine("  one\ntwo"), "one")
    let long = String(repeating: "a", count: 100)
    XCTAssertEqual(RewindListing.firstLine(long).count, RewindListing.promptChars)
    XCTAssertTrue(RewindListing.firstLine(long).hasSuffix("…"))
    let cwd = URL(fileURLWithPath: "/work/project")
    XCTAssertEqual(RewindListing.relativePath("/work/project/src/a.swift", to: cwd), "src/a.swift")
    XCTAssertEqual(RewindListing.relativePath("/elsewhere/b.swift", to: cwd), "/elsewhere/b.swift")
    XCTAssertEqual(RewindListing.relativePath("/work/project-2/c.swift", to: cwd), "/work/project-2/c.swift")
  }

  func testSummaryLine() {
    let result = RewindResult(
      restoredFiles: ["/w/a", "/w/b"], deletedFiles: ["/w/c"], skipped: [], removedMessages: 1)
    XCTAssertEqual(RewindListing.summary(result), "↶ restored 2 files, deleted 1, removed 1 message")
    let codeOnly = RewindResult(restoredFiles: ["/w/a"], deletedFiles: [], skipped: ["x"], removedMessages: 0)
    XCTAssertEqual(RewindListing.summary(codeOnly), "↶ restored 1 file, removed 0 messages")
  }

  // MARK: Diff coloring

  func testDiffLineKinds() {
    XCTAssertEqual(DiffColoring.kind(of: "--- a/x.txt"), .header)
    XCTAssertEqual(DiffColoring.kind(of: "+++ b/x.txt"), .header)
    XCTAssertEqual(DiffColoring.kind(of: "diff --git a/x b/x"), .header)
    XCTAssertEqual(DiffColoring.kind(of: "@@ -1,3 +1,4 @@"), .hunk)
    XCTAssertEqual(DiffColoring.kind(of: "+added"), .added)
    XCTAssertEqual(DiffColoring.kind(of: "-removed"), .removed)
    XCTAssertEqual(DiffColoring.kind(of: " context"), .context)
    XCTAssertEqual(DiffColoring.kind(of: ""), .context)
  }

  func testColoredDiffKeepsEveryLine() {
    let diff = UnifiedDiff.diff(old: "a\nb\n", new: "a\nc\n", path: "t.txt")
    let colored = DiffColoring.colored(diff)
    XCTAssertEqual(
      colored.split(separator: "\n", omittingEmptySubsequences: false).count,
      diff.split(separator: "\n", omittingEmptySubsequences: false).count)
    XCTAssertTrue(colored.contains("+c"))
    XCTAssertTrue(colored.contains("-b"))
    // Every line goes through `TerminalText.sanitize` (TTY-gated, so a piped test sees the raw
    // text); the pure transform it applies on a terminal is pinned in TerminalTextTests.
    XCTAssertEqual(TerminalText.visibleControls("c\u{1B}[31m"), "c␛[31m")
  }
}
