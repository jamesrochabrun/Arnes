import ArnesKit
import XCTest
@testable import arnes

/// C2 — `/compact [model] [instructions]` parsing, and how the REPL and headless text render the
/// microcompaction events (`tool_results_cleared`, `context_warning`), lead and nested.
final class CompactCommandTests: XCTestCase {
  private final class Capture {
    var lines: [String] = []
  }

  private func renderer() -> (Renderer, Capture) {
    let capture = Capture()
    let renderer = Renderer(lineSink: { capture.lines.append($0) })
    return (renderer, capture)
  }

  // MARK: /compact arguments

  func testCompactParsesToTheRawArgument() {
    guard case .compact(nil)? = SlashCommand.parse("/compact") else { return XCTFail("/compact") }
    guard case .compact("haiku focus on the tests")? = SlashCommand.parse("/compact haiku focus on the tests") else {
      return XCTFail("/compact with an argument")
    }
    guard case .compact("x")? = SlashCommand.parse("  /COMPACT   x  ") else { return XCTFail("case-insensitive, trimmed") }
  }

  func testCompactArgumentsSplitModelFromInstructions() {
    let aliases = ["haiku": "anthropic/claude-haiku-4.5", "Cheap": "openai/gpt-4o-mini"]
    // Nothing → neither.
    XCTAssertEqual(SlashCommand.compactArguments(nil, aliases: aliases).model, nil)
    XCTAssertEqual(SlashCommand.compactArguments("   ", aliases: aliases).instructions, nil)
    // A slug alone, a slug plus steering.
    let slug = SlashCommand.compactArguments("openai/gpt-4o-mini", aliases: aliases)
    XCTAssertEqual(slug.model, "openai/gpt-4o-mini")
    XCTAssertNil(slug.instructions)
    let slugAndText = SlashCommand.compactArguments("openai/gpt-4o-mini keep every failing test name", aliases: aliases)
    XCTAssertEqual(slugAndText.model, "openai/gpt-4o-mini")
    XCTAssertEqual(slugAndText.instructions, "keep every failing test name")
    // An alias resolves to its target, case-insensitively; the rest steers.
    let alias = SlashCommand.compactArguments("HAIKU focus on errors", aliases: aliases)
    XCTAssertEqual(alias.model, "anthropic/claude-haiku-4.5")
    XCTAssertEqual(alias.instructions, "focus on errors")
    XCTAssertEqual(SlashCommand.compactArguments("cheap", aliases: aliases).model, "openai/gpt-4o-mini")
    // A first word that names no model is instructions, whole.
    let prose = SlashCommand.compactArguments("focus on the failing test", aliases: aliases)
    XCTAssertNil(prose.model)
    XCTAssertEqual(prose.instructions, "focus on the failing test")
    // Without aliases a bare word is never a model.
    XCTAssertNil(SlashCommand.compactArguments("haiku").model)
    XCTAssertEqual(SlashCommand.compactArguments("haiku").instructions, "haiku")
  }

  func testHelpNamesTheSteeringForm() {
    XCTAssertTrue(SlashCommand.helpText.contains("/compact [model] [instructions]"))
  }

  // MARK: Rendering

  func testRendererPrintsClearedAndWarningLines() {
    let (renderer, capture) = renderer()
    renderer.render(.toolResultsCleared(count: 4, freedChars: 12000))
    renderer.render(.toolResultsCleared(count: 1, freedChars: 2500))
    renderer.render(.contextWarning("context at 96% of the window with nothing left to clear"))
    XCTAssertEqual(capture.lines, [
      "◈ cleared 4 older tool results from the request (12000 chars) — history untouched",
      "◈ cleared 1 older tool result from the request (2500 chars) — history untouched",
      "⚠ context: context at 96% of the window with nothing left to clear — /compact or /clear to make room",
    ])
  }

  func testNestedClearedAndWarningLinesNameTheSubagent() {
    let (renderer, capture) = renderer()
    renderer.render(.subagentStarted(name: "explore", id: "a1b2c3d4", model: "m", task: "t"))
    renderer.render(.subagent(name: "explore", id: "a1b2c3d4", event: .toolResultsCleared(count: 2, freedChars: 6000)))
    renderer.render(.subagent(name: "explore", id: "a1b2c3d4", event: .contextWarning("context at 97% of the window")))
    XCTAssertEqual(Array(capture.lines.suffix(2)), [
      "  ◈ explore cleared 2 older tool results from its request",
      "  ⚠ explore context: context at 97% of the window — report may be incomplete",
    ])
  }

  func testHeadlessTextLinesForTheNewEvents() {
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .toolResultsCleared(count: 2, freedChars: 6000)),
      "◈ cleared 2 older tool results from the request (6000 chars)")
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .contextWarning("context at 96% of the window")),
      "⚠ context: context at 96% of the window")
    // Nested: no text line, like a subagent's other progress the headless text doesn't print.
    XCTAssertNil(HeadlessEmitter.textLine(for: .subagent(name: "explore", id: "a1b2c3d4", event: .toolResultsCleared(count: 2, freedChars: 6000))))
    // Neither is wire chatter: stdout, with the run's other progress.
    XCTAssertFalse(HeadlessEmitter.isRetryChatter(.toolResultsCleared(count: 1, freedChars: 1)))
    XCTAssertFalse(HeadlessEmitter.isRetryChatter(.contextWarning("x")))
  }
}
