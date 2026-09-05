import XCTest
import ArnesKit
@testable import arnes

/// T6, the REPL side: `TerminalUserInput` refuses between turns and past the per-turn cap,
/// maps a typed number to its option, and `KeyWatcher` splits the type-ahead buffer so completed
/// lines stay queued while the fragment starts the answer; the headless line for the event.
final class TerminalUserInputTests: XCTestCase {
  // MARK: TerminalUserInput

  func testQuestionBetweenTurnsIsRefusedInsteadOfReadingStdin() async {
    // No turn in flight and no key watcher: the line editor owns stdin, so the question is
    // refused outright — never a raw read racing the editor for the user's next line.
    let input = TerminalUserInput(turnInFlight: { false })
    let answer = await input.answer(question: "Which one?", options: ["a", "b"])
    XCTAssertEqual(answer, .unavailable(reason: TerminalUserInput.noTurnReason))
    XCTAssertTrue(TerminalUserInput.noTurnReason.contains("no turn in flight"))
  }

  /// Scripted piped-stdin lines, so the test never touches the process's stdin.
  private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String?]
    init(_ lines: [String?]) { self.lines = lines }
    func next() -> String? { lock.withLock { lines.isEmpty ? nil : lines.removeFirst() } }
    var remaining: Int { lock.withLock { lines.count } }
  }

  func testPerTurnCapRefusesTheFourthQuestionUntilTheTurnResets() async {
    // A turn in flight, no key watcher (piped stdin): each answer is the next input line.
    let lines = Lines(["one", "2", "three", "never read", "after reset"])
    let input = TerminalUserInput(turnInFlight: { true }, readPipedLine: { lines.next() })
    XCTAssertEqual(input.maxQuestionsPerTurn, 3, "the default cap")
    let first = await input.answer(question: "q1", options: [])
    let second = await input.answer(question: "q2", options: ["a", "b"])
    let third = await input.answer(question: "q3", options: [])
    XCTAssertEqual(first, .text("one"))
    XCTAssertEqual(second, .text("b"), "a number picks the option")
    XCTAssertEqual(third, .text("three"))
    let fourth = await input.answer(question: "q4", options: [])
    XCTAssertEqual(fourth, .unavailable(reason: "question limit for this turn reached (3)"))
    XCTAssertEqual(lines.remaining, 2, "a refused question reads nothing")
    input.resetTurn()
    let afterReset = await input.answer(question: "q5", options: [])
    XCTAssertEqual(afterReset, .text("never read"))
    // Piped Esc/empty/EOF lines carry their own reasons.
    let terse = TerminalUserInput(turnInFlight: { true }, readPipedLine: { lines.next() })
    _ = await terse.answer(question: "q", options: []) // "after reset"
    let eof = await terse.answer(question: "q", options: [])
    XCTAssertEqual(eof, .unavailable(reason: "user gave no answer"), "input closed")
  }

  func testTypedLineResolvesToTheAnswer() {
    let options = ["sqlite", "postgres", "mysql"]
    XCTAssertEqual(TerminalUserInput.resolve("2", options: options), .text("postgres"))
    XCTAssertEqual(TerminalUserInput.resolve(" 3 ", options: options), .text("mysql"))
    XCTAssertEqual(TerminalUserInput.resolve("4", options: options), .text("4"), "out of range is free text")
    XCTAssertEqual(TerminalUserInput.resolve("0", options: options), .text("0"))
    XCTAssertEqual(TerminalUserInput.resolve("1", options: []), .text("1"), "no options: a number is text")
    XCTAssertEqual(TerminalUserInput.resolve("use the one in prod", options: options), .text("use the one in prod"))
    XCTAssertEqual(TerminalUserInput.resolve("", options: options), .unavailable(reason: "user gave no answer"))
    XCTAssertEqual(TerminalUserInput.resolve("   ", options: options), .unavailable(reason: "user gave no answer"))
    XCTAssertEqual(TerminalUserInput.resolve(nil, options: options), .unavailable(reason: "user gave no answer"))
    XCTAssertEqual(TerminalUserInput.resolve("\u{1B}", options: options), .unavailable(reason: "user declined to answer"))
  }

  // MARK: KeyWatcher.splitAnswer

  func testCompletedLinesStayQueuedAndTheFragmentStartsTheAnswer() {
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "a\nb\nfrag").queued, ["a", "b"])
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "a\nb\nfrag").fragment, "frag")
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "frag").queued, [])
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "frag").fragment, "frag")
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "a\n").queued, ["a"])
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "a\n").fragment, "")
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "").queued, [])
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "").fragment, "")
    XCTAssertEqual(KeyWatcher.splitAnswer(buffer: "\n\n").queued, ["", ""], "empty completed lines are still lines")
    // The byte form keeps the newlines with the queued part, so the buffer can be put back as is.
    let (queued, fragment) = KeyWatcher.splitAnswer(buffer: Array("x\ny".utf8))
    XCTAssertEqual(queued, Array("x\n".utf8))
    XCTAssertEqual(fragment, Array("y".utf8))
  }

  // MARK: KeyWatcher.LineCapture

  private func feed(_ capture: inout KeyWatcher.LineCapture, _ bytes: [UInt8]) -> [KeyWatcher.LineCapture.Event] {
    bytes.map { capture.feed($0) }
  }

  func testLineCaptureAssemblesTheAnswerUntilEnter() {
    var capture = KeyWatcher.LineCapture()
    XCTAssertFalse(capture.started)
    let events = feed(&capture, Array("yes\n".utf8))
    XCTAssertEqual(events, [.changed, .changed, .changed, .line("yes")])
    XCTAssertTrue(capture.started)
    // Carriage return completes a line too (some terminals send it for Enter).
    var cr = KeyWatcher.LineCapture(bytes: Array("ok".utf8))
    XCTAssertTrue(cr.started, "a fragment gives the answer its start")
    XCTAssertEqual(cr.feed(0x0D), .line("ok"))
  }

  func testLineCaptureBackspaceRemovesAWholeCharacter() {
    var capture = KeyWatcher.LineCapture(bytes: Array("caf".utf8))
    _ = feed(&capture, Array("é".utf8)) // two bytes
    XCTAssertEqual(capture.text, "café")
    XCTAssertEqual(capture.feed(0x7F), .changed)
    XCTAssertEqual(capture.text, "caf", "the multibyte character went as one")
    _ = feed(&capture, [0x08, 0x08, 0x08])
    XCTAssertEqual(capture.text, "")
    XCTAssertEqual(capture.feed(0x7F), .none, "nothing left to erase")
    XCTAssertTrue(capture.started, "erasing does not un-start the answer")
  }

  func testLineCaptureSwallowsEscapeSequencesAndControlKeys() {
    var capture = KeyWatcher.LineCapture()
    // An arrow key (CSI), a Home key (SS3), an Alt+key pair: none of it is text.
    XCTAssertEqual(feed(&capture, [0x1B, UInt8(ascii: "["), UInt8(ascii: "A")]), [.none, .none, .none])
    XCTAssertFalse(capture.isMidEscape)
    XCTAssertEqual(feed(&capture, [0x1B, UInt8(ascii: "O"), UInt8(ascii: "H")]), [.none, .none, .none])
    XCTAssertEqual(feed(&capture, [0x1B, UInt8(ascii: "x")]), [.none, .none])
    // A cursor-position report with parameters is consumed through its final byte.
    XCTAssertEqual(feed(&capture, Array("\u{1B}[12;40R".utf8)).allSatisfy { $0 == .none }, true)
    XCTAssertEqual(capture.text, "")
    XCTAssertFalse(capture.started, "sequences never start the answer")
    // Tab and other control bytes are ignored; text after them is kept.
    XCTAssertEqual(feed(&capture, [0x09, UInt8(ascii: "a")]), [.none, .changed])
    XCTAssertEqual(capture.text, "a")
    // Mid-sequence the watcher must not read the next byte as a bare Esc.
    _ = capture.feed(0x1B)
    XCTAssertTrue(capture.isMidEscape)
  }

  // MARK: The event's headless line

  func testHeadlessTextLineForAQuestion() {
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .userQuestion(question: "Which database?", options: ["sqlite", "postgres"])),
      "? Which database? [sqlite | postgres]")
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .userQuestion(question: "What name?", options: [])),
      "? What name?")
    // Nested (unreachable today — the tool is stripped from subagents) prints nothing headless,
    // like a subagent's other prose; the REPL renderer has a dim line for it.
    XCTAssertNil(HeadlessEmitter.textLine(for: .subagent(name: "x", id: "a1b2c3d4", event: .userQuestion(question: "q", options: []))))
  }
}
