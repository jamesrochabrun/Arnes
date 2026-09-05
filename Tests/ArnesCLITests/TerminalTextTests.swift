import XCTest
@testable import arnes

final class TerminalTextTests: XCTestCase {
  func testPlainTextIsUntouched() {
    let text = "edit_file Sources/App.swift (replace 12 chars with 40 chars)\n\twith tabs"
    XCTAssertEqual(TerminalText.visibleControls(text), text)
  }

  func testCarriageReturnCannotRewriteThePromptLine() {
    // The classic spoof: the real command, then \r and a harmless-looking command
    // that the terminal would draw over it.
    let spoofed = "bash: rm -rf ~/work\r\u{1B}[Kbash: ls -la"
    let shown = TerminalText.visibleControls(spoofed)
    XCTAssertEqual(shown, "bash: rm -rf ~/work␍␛[Kbash: ls -la")
    XCTAssertFalse(shown.contains("\r"))
    XCTAssertFalse(shown.contains("\u{1B}"))
  }

  func testEscapeSequencesAndDeleteBecomeVisible() {
    XCTAssertEqual(TerminalText.visibleControls("\u{1B}]52;c;aGk=\u{07}"), "␛]52;c;aGk=␇")
    XCTAssertEqual(TerminalText.visibleControls("a\u{7F}b"), "a␡b")
    XCTAssertEqual(TerminalText.visibleControls("\u{00}"), "␀")
  }

  func testC1AndBidiControlsAreSpelledOut() {
    XCTAssertEqual(TerminalText.visibleControls("x\u{9B}y"), "x<U+009B>y")
    // Right-to-left override would render `rm -rf /` visually reversed after `# `.
    XCTAssertEqual(TerminalText.visibleControls("echo ok # \u{202E}/ fr- mr"), "echo ok # <U+202E>/ fr- mr")
    XCTAssertEqual(TerminalText.visibleControls("\u{2066}a\u{2069}"), "<U+2066>a<U+2069>")
  }

  func testNewlinesAndUnicodeProseSurvive() {
    let text = "first line\nsecond — «quoted» 日本語 🚀\nthird"
    XCTAssertEqual(TerminalText.visibleControls(text), text)
  }
}
