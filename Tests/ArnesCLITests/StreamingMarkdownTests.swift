import ArnesKit
import XCTest
@testable import arnes

final class StreamingMarkdownTests: XCTestCase {
  private func render(_ chunks: [String]) -> String {
    let markdown = StreamingMarkdown(styled: true)
    var out = chunks.reduce(into: "") { $0 += markdown.feed($1) }
    out += markdown.flush()
    return out
  }

  func testUnstyledPassesThrough() {
    let markdown = StreamingMarkdown(styled: false)
    let input = "## Title\n```swift\nlet x = 1\n```\n**bold**"
    XCTAssertEqual(markdown.feed(input), input)
    XCTAssertEqual(markdown.flush(), "")
  }

  func testHeadingStripsHashesAndStyles() {
    let out = render(["## Hello\nworld\n"])
    XCTAssertFalse(out.contains("##"))
    XCTAssertTrue(out.contains("\u{1B}[1m\u{1B}[36mHello\u{1B}[0m"))
    XCTAssertTrue(out.contains("world\n"))
  }

  func testBulletBecomesDot() {
    let out = render(["- first\n- second\n"])
    XCTAssertFalse(out.contains("- first"))
    XCTAssertTrue(out.contains("•"))
    XCTAssertTrue(out.contains("first"))
  }

  func testInlineCodeAndBoldMarkersAreConsumed() {
    let out = render(["use `grep` and **really** mean it"])
    XCTAssertFalse(out.contains("`"))
    XCTAssertFalse(out.contains("**"))
    XCTAssertTrue(out.contains("\u{1B}[36mgrep\u{1B}[39m"))
    XCTAssertTrue(out.contains("\u{1B}[1mreally\u{1B}[22m"))
  }

  func testBoldMarkerSplitAcrossDeltas() {
    let out = render(["a *", "*b*", "* c"])
    XCTAssertTrue(out.contains("\u{1B}[1mb\u{1B}[22m"))
    XCTAssertFalse(out.contains("*"))
  }

  func testLoneAsteriskSurvives() {
    let out = render(["2 * 3 = 6\n"])
    XCTAssertTrue(out.contains("2 * 3 = 6"))
  }

  func testCodeFenceGetsGutterAndCloses() {
    let out = render(["```python\nprint(1)\n```\nafter\n"])
    XCTAssertTrue(out.contains("╭─ python"))
    XCTAssertTrue(out.contains("│ "))
    XCTAssertTrue(out.contains("print(1)"))
    XCTAssertTrue(out.contains("╰─"))
    XCTAssertTrue(out.contains("after\n"))
  }

  func testSwiftFenceIsHighlighted() {
    let out = render(["```swift\nlet x = \"hi\"\n```\n"])
    XCTAssertTrue(out.contains("\u{1B}[35mlet\u{1B}[0m"), "keywords should be colored")
    XCTAssertTrue(out.contains("╭─ swift"))
  }

  func testFenceSplitAcrossDeltas() {
    let out = render(["`", "``sw", "ift\nlet x", " = 1\n`", "``\n"])
    XCTAssertTrue(out.contains("╭─ swift"))
    XCTAssertTrue(out.contains("╰─"))
    XCTAssertFalse(out.contains("```"))
  }

  func testAmbiguousLineFlushedAsPlainText() {
    let out = render(["-\n###\n12\n"])
    XCTAssertTrue(out.contains("-\n"))
    XCTAssertTrue(out.contains("###\n"))
    XCTAssertTrue(out.contains("12\n"))
  }

  func testBlockquoteIsDimmedWithBar() {
    let out = render(["> quoted words\nplain\n"])
    XCTAssertTrue(out.contains("│ quoted words"))
    XCTAssertFalse(out.contains("> quoted"))
    XCTAssertTrue(out.contains("plain\n"))
  }

  func testFlushEmitsPartialCodeLineAndClosesBox() {
    let markdown = StreamingMarkdown(styled: true)
    _ = markdown.feed("```\nhalf a li")
    let out = markdown.flush()
    XCTAssertTrue(out.contains("half a li"))
    XCTAssertTrue(out.contains("╰─"))
  }

  func testFenceClosingAtEndOfMessageClosesBox() {
    let out = render(["```swift\nlet x = 1\n```"])
    XCTAssertTrue(out.contains("╰─"))
    XCTAssertFalse(out.contains("```"))
  }

  func testOrderedListPassesThrough() {
    let out = render(["1. one\n2. two\n"])
    XCTAssertTrue(out.contains("1. one"))
    XCTAssertTrue(out.contains("2. two"))
  }
}
