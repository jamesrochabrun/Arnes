import ArgumentParser
import XCTest
@testable import arnes

/// `Do.composePrompt` — the task from the argument, stdin, or both.
final class StdinPromptTests: XCTestCase {
  func testTaskOnly() throws {
    XCTAssertEqual(try Do.composePrompt(task: "fix the bug", stdin: nil), "fix the bug")
    XCTAssertEqual(try Do.composePrompt(task: "fix the bug", stdin: ""), "fix the bug")
    XCTAssertEqual(try Do.composePrompt(task: "fix the bug", stdin: "  \n"), "fix the bug", "blank stdin is no stdin")
  }

  func testStdinOnlyBecomesTheTask() throws {
    XCTAssertEqual(try Do.composePrompt(task: nil, stdin: "summarize this\n"), "summarize this")
    XCTAssertEqual(try Do.composePrompt(task: "-", stdin: "summarize this\n"), "summarize this", "`-` means stdin")
    XCTAssertEqual(try Do.composePrompt(task: "  ", stdin: "summarize this"), "summarize this", "a blank task means stdin")
    XCTAssertEqual(try Do.composePrompt(task: nil, stdin: "line 1\nline 2\r\n\n"), "line 1\nline 2",
                   "trailing newlines are trimmed, interior ones kept")
  }

  func testBothWrapStdinInAContextBlock() throws {
    XCTAssertEqual(
      try Do.composePrompt(task: "review this diff", stdin: "--- a\n+++ b\n"),
      "review this diff\n\n<stdin>\n--- a\n+++ b\n</stdin>")
    // The task is passed through untouched — its own whitespace is the user's.
    XCTAssertEqual(
      try Do.composePrompt(task: "  review  ", stdin: "x"),
      "  review  \n\n<stdin>\nx\n</stdin>")
  }

  func testNeitherIsAUsageError() {
    XCTAssertThrowsError(try Do.composePrompt(task: nil, stdin: nil)) { error in
      XCTAssertTrue(error is ValidationError)
      XCTAssertTrue("\(error)".contains("no task given"))
    }
    XCTAssertThrowsError(try Do.composePrompt(task: "-", stdin: nil))
    XCTAssertThrowsError(try Do.composePrompt(task: "", stdin: "\n"))
  }

  func testStdinCapIsTenMegabytes() {
    // `readPipedStdin` itself reads the process's fd 0, which a test must not touch (an open
    // pipe would block the run) — the cap is asserted here and enforced there.
    XCTAssertEqual(Do.maxStdinBytes, 10 * 1024 * 1024)
  }
}
