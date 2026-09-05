import ArnesKit
import XCTest
@testable import arnes

/// C6 — the REPL's plan pin and reasoning toggle: `.planUpdated` renders the checklist in
/// concise mode (other tool results stay hidden), `think` collapses to its name, a nested plan
/// is one progress line, and `/thinking` gates the reasoning deltas.
final class RendererPlanTests: XCTestCase {
  private final class Capture {
    var lines: [String] = []
  }

  private func renderer() -> (Renderer, Capture) {
    let capture = Capture()
    let renderer = Renderer(lineSink: { capture.lines.append($0) })
    return (renderer, capture)
  }

  private static let plan: [(text: String, status: String)] = [
    (text: "read the code", status: "completed"),
    (text: "make the change", status: "in_progress"),
    (text: "run the tests", status: "pending"),
  ]

  func testUpdatePlanResultRenderedInConciseMode() {
    let (renderer, capture) = renderer()
    renderer.beginTurn()
    renderer.render(.toolCall(name: "update_plan", arguments: #"{"plan":[]}"#))
    renderer.render(.planUpdated(steps: Self.plan))
    renderer.render(.toolResult(name: "update_plan", preview: "[x] read the code\n[~] make the change"))
    // Another tool's successful result stays quiet in concise mode, as before.
    renderer.render(.toolCall(name: "bash", arguments: #"{"command":"ls"}"#))
    renderer.render(.toolResult(name: "bash", preview: "a.txt"))

    XCTAssertEqual(capture.lines, [
      "• update_plan ",
      "  [x] read the code",
      "  [~] make the change",
      "  [ ] run the tests",
      "• bash ls",
    ])
  }

  func testThinkIsJustItsNameInConciseModeAndTheThoughtWhenVerbose() {
    let (renderer, capture) = renderer()
    renderer.render(.toolCall(name: "think", arguments: #"{"thought":"the tests come first"}"#))
    XCTAssertEqual(capture.lines, ["• think"])
    renderer.toggleVerbose()
    renderer.render(.toolCall(name: "think", arguments: #"{"thought":"the tests come first"}"#))
    XCTAssertEqual(capture.lines.last, #"→ think {"thought":"the tests come first"}"#)
  }

  func testNestedPlanIsOneProgressLine() {
    let (renderer, capture) = renderer()
    renderer.render(.subagentStarted(name: "helper", id: "a1b2c3d4", model: "m", task: "t"))
    renderer.render(.subagent(name: "helper", id: "a1b2c3d4", event: .planUpdated(steps: Self.plan)))
    XCTAssertEqual(capture.lines.last, "  ☰ plan 1/3 · [~] make the change")
  }

  func testReasoningDisplayToggles() {
    let (renderer, _) = renderer()
    XCTAssertTrue(renderer.showReasoning, "shown by default")
    XCTAssertFalse(renderer.toggleReasoning())
    XCTAssertFalse(renderer.showReasoning)
    XCTAssertTrue(renderer.setShowReasoning(true))
    XCTAssertFalse(renderer.setShowReasoning(false))
    XCTAssertTrue(renderer.toggleReasoning())
  }

  /// `/thinking off` drops the reasoning deltas from the display — nothing is streamed for them
  /// — while the answer's own deltas still print; back on, the dimmed reasoning streams again.
  func testHiddenReasoningStreamsNothing() {
    let streamed = Capture()
    let renderer = Renderer(lineSink: { _ in }, streamSink: { streamed.lines.append($0) })
    renderer.beginTurn()
    renderer.setShowReasoning(false)
    renderer.render(.reasoningDelta("let me think"))
    XCTAssertEqual(streamed.lines, [], "hidden reasoning leaves no output")
    renderer.render(.textDelta("The answer"))
    XCTAssertEqual(streamed.lines.joined(), "The answer", "the reply streams as usual, with no reasoning separator")

    renderer.beginTurn()
    streamed.lines.removeAll()
    renderer.setShowReasoning(true)
    renderer.render(.reasoningDelta("let me think"))
    XCTAssertEqual(streamed.lines.count, 1)
    XCTAssertTrue(streamed.lines[0].contains("let me think"), streamed.lines[0])
    renderer.render(.textDelta("The answer"))
    XCTAssertEqual(streamed.lines.count, 3, "the reasoning line is closed before the answer starts")
    XCTAssertEqual(streamed.lines.last, "The answer")
  }

  // MARK: PlanFormat

  func testPlanFormatLines() {
    XCTAssertEqual(PlanFormat.progressLine(Self.plan), "☰ plan 1/3 · [~] make the change")
    XCTAssertEqual(
      PlanFormat.progressLine([(text: "a", status: "completed"), (text: "b", status: "pending")]),
      "☰ plan 1/2 · [ ] b", "no step in progress: the next pending one is the current step")
    XCTAssertEqual(PlanFormat.progressLine([(text: "a", status: "completed")]), "☰ plan 1/1")
    XCTAssertEqual(PlanFormat.summary(Self.plan), "plan 1/3")
    XCTAssertEqual(PlanFormat.checklistLines(Self.plan), ["[x] read the code", "[~] make the change", "[ ] run the tests"])
    XCTAssertEqual(PlanFormat.mark("banana"), "[ ]", "an unknown status reads as pending, as the tool renders it")
  }
}
