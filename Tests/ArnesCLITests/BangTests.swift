import ArnesKit
import XCTest

@testable import arnes

/// The `!` shell escape's pure pieces (`Bang`): parsing, the shell-mode buffer check the
/// input box tints on, the output cap, and the notice the model is told with the next
/// message. Running is `UserShell` (ArnesKit) and the loop's wiring in `Interactive`.
final class BangTests: XCTestCase {
  // MARK: Parsing

  func testParseTakesTheBangLinesCommand() {
    XCTAssertEqual(Bang.parse("!ls -la"), "ls -la")
    XCTAssertEqual(Bang.parse("! git status"), "git status")
  }

  func testParseOfABareBangIsAnEmptyCommand() {
    // A bang line with nothing to run — the loop prints usage instead of spawning a shell.
    XCTAssertEqual(Bang.parse("!"), "")
    XCTAssertEqual(Bang.parse("!   "), "")
  }

  func testParseLeavesOrdinaryMessagesAlone() {
    XCTAssertNil(Bang.parse("ls -la"))
    XCTAssertNil(Bang.parse("/help"))
    XCTAssertNil(Bang.parse("hey! how are you")) // the `!` must be the first character
    XCTAssertNil(Bang.parse(""))
  }

  func testShellBufferDetectionIsTheFirstCharacter() {
    XCTAssertTrue(Bang.isShellBuffer("!"))
    XCTAssertTrue(Bang.isShellBuffer("!npm test"))
    XCTAssertFalse(Bang.isShellBuffer(""))
    XCTAssertFalse(Bang.isShellBuffer(" !ls")) // not the first character — a normal message
    XCTAssertFalse(Bang.isShellBuffer("hi!"))
  }

  // MARK: Output cap

  func testCapKeepsShortOutputVerbatim() {
    XCTAssertEqual(Bang.capped("hello", maxChars: 100), "hello")
    let exact = String(repeating: "x", count: 100)
    XCTAssertEqual(Bang.capped(exact, maxChars: 100), exact)
  }

  func testCapKeepsHeadAndTailAndCountsTheOmitted() {
    let output = String(repeating: "a", count: 500) + String(repeating: "z", count: 500)
    let capped = Bang.capped(output, maxChars: 100)
    XCTAssertTrue(capped.hasPrefix(String(repeating: "a", count: 60))) // head 60%
    XCTAssertTrue(capped.hasSuffix(String(repeating: "z", count: 40))) // tail 40%
    XCTAssertTrue(capped.contains("[… 900 chars omitted …]"))
  }

  func testCapWithASillyBudgetIsANoOp() {
    // A cap too small to hold its own marker leaves the text alone rather than mangling it.
    let output = String(repeating: "a", count: 100)
    XCTAssertEqual(Bang.capped(output, maxChars: 10), output)
  }

  // MARK: Result line

  func testResultLines() {
    XCTAssertEqual(
      Bang.resultLine(
        exitStatus: 0, timedOut: false, cancelled: false, failedToStart: false,
        timeoutSeconds: 300),
      "exit 0")
    XCTAssertEqual(
      Bang.resultLine(
        exitStatus: 2, timedOut: false, cancelled: false, failedToStart: false,
        timeoutSeconds: 300),
      "exit 2")
    XCTAssertEqual(
      Bang.resultLine(
        exitStatus: 143, timedOut: true, cancelled: false, failedToStart: false,
        timeoutSeconds: 30),
      "timed out after 30s — the process tree was killed")
    XCTAssertEqual(
      Bang.resultLine(
        exitStatus: 130, timedOut: false, cancelled: true, failedToStart: false,
        timeoutSeconds: 300),
      "interrupted before it finished")
    XCTAssertEqual(
      Bang.resultLine(
        exitStatus: 127, timedOut: false, cancelled: false, failedToStart: true,
        timeoutSeconds: 300),
      "the shell could not start (exit 127)")
  }

  // MARK: The model-facing notice

  func testNoticeCarriesCommandResultAndOutput() {
    let notice = Bang.notice(
      command: "git status", output: " clean \n", exitStatus: 0, timedOut: false,
      cancelled: false, failedToStart: false, timeoutSeconds: 300, maxChars: 20_000)
    XCTAssertTrue(notice.contains("$ git status"))
    XCTAssertTrue(notice.contains("exit 0"))
    XCTAssertTrue(notice.contains("clean"))
    // The framing matters: the model must read this as the user's action, not its own tool.
    XCTAssertTrue(notice.contains("not a tool call"))
  }

  func testNoticeSaysNoOutput() {
    let notice = Bang.notice(
      command: "true", output: "  \n ", exitStatus: 0, timedOut: false,
      cancelled: false, failedToStart: false, timeoutSeconds: 300, maxChars: 20_000)
    XCTAssertTrue(notice.contains("(no output)"))
  }

  func testNoticeCapsOversizedOutput() {
    let notice = Bang.notice(
      command: "yes", output: String(repeating: "y\n", count: 5_000), exitStatus: 0,
      timedOut: false, cancelled: false, failedToStart: false, timeoutSeconds: 300,
      maxChars: 200)
    XCTAssertTrue(notice.contains("chars omitted"))
    XCTAssertLessThan(notice.count, 600) // the cap holds, whatever the command printed
  }

  func testNoticeNamesAnInterrupt() {
    let notice = Bang.notice(
      command: "sleep 100", output: "", exitStatus: 130, timedOut: false,
      cancelled: true, failedToStart: false, timeoutSeconds: 300, maxChars: 20_000)
    XCTAssertTrue(notice.contains("interrupted before it finished"))
  }

  // MARK: The turn a completed command sends

  func testTurnPromptCarriesTheExchangeAndTheResponseContract() {
    let prompt = Bang.turnPrompt(
      command: "git status", output: "On branch main\nnothing to commit", exitStatus: 0,
      timedOut: false, failedToStart: false, timeoutSeconds: 300, maxChars: 20_000)
    // Harness-authored, so it opens with the [arnes] prefix like every other notice.
    XCTAssertTrue(prompt.hasPrefix("[arnes] "))
    XCTAssertTrue(prompt.contains("$ git status"))
    XCTAssertTrue(prompt.contains("exit 0"))
    XCTAssertTrue(prompt.contains("nothing to commit"))
    // The contract this exists for: explain / recover, never "what do you want to do?".
    XCTAssertTrue(prompt.contains("do not ask what to do with it"))
    XCTAssertTrue(prompt.contains("how to recover"))
  }

  func testTurnPromptCapsOversizedOutputLikeTheNotice() {
    let prompt = Bang.turnPrompt(
      command: "yes", output: String(repeating: "y\n", count: 5_000), exitStatus: 0,
      timedOut: false, failedToStart: false, timeoutSeconds: 300, maxChars: 200)
    XCTAssertTrue(prompt.contains("chars omitted"))
    XCTAssertLessThan(prompt.count, 1_000)
  }
}
