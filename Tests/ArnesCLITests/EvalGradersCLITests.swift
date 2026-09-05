import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// X4 at the CLI: the `arnes eval` grader flags, the progress line's grader facts, `arnes evals
/// transcript`, prune sweeping transcripts, and capture finding an eval trial's session.
final class EvalGradersCLITests: XCTestCase {
  private func tempStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-eval-cli-\(UUID().uuidString)"))
  }

  /// A trial-shaped transcript: meta, the prompt, a tool call, its result, the report.
  private func seedTrial(in store: SessionStore, id: String, model: String = "test/model") throws {
    try store.append(.meta(id: id, model: model, cwd: "/tmp/trial", origin: "eval"), to: id)
    try store.append(TranscriptEntry(message: .user("Work in the current directory.\n\nmake hello.txt")), to: id)
    let call = ToolCall(
      id: "c1", index: 0,
      function: .init(name: "write_file", arguments: #"{"path":"hello.txt","content":"hello"}"#))
    try store.append(
      TranscriptEntry(message: Message(role: .assistant, content: .text(""), toolCalls: [call])), to: id)
    try store.append(TranscriptEntry(message: .tool("created hello.txt (5 bytes)", toolCallId: "c1")), to: id)
    try store.append(TranscriptEntry(message: Message(role: .assistant, content: .text("created hello.txt"))), to: id)
  }

  private func outcome(
    task: String = "t", check: Bool = true, session: String? = nil, run: String? = nil,
    rubricScore: Double? = nil, rubricPassed: Bool? = nil, rubricUnknown: Bool? = nil,
    limitsPassed: Bool? = nil, violations: [String]? = nil, verifierPassed: Bool? = nil,
    passed: Bool? = nil, error: String? = nil, dialect: String? = "chat")
    -> EvalOutcome
  {
    EvalOutcome(
      suite: "unit", taskId: task, model: "test/model", trial: 1, checkPassed: check,
      agentFinished: true, steps: 3, toolCalls: 2, costUSD: 0.0123, durationSeconds: 4.26,
      startedAt: Date(), routedModels: [], error: error, dialect: dialect, sandboxed: true,
      rubricScore: rubricScore, rubricPassed: rubricPassed, rubricUnknown: rubricUnknown,
      limitsPassed: limitsPassed, limitsViolations: violations, verifierPassed: verifierPassed,
      sessionId: session, runId: run, passed: passed)
  }

  // MARK: Flags

  func testEvalGraderFlagsParse() throws {
    let plain = try Eval.parse(["evals/basics"])
    XCTAssertNil(plain.judge)
    XCTAssertNil(plain.verify)
    XCTAssertFalse(plain.noTranscripts)
    let graded = try Eval.parse([
      "evals/graded", "-m", "test/model", "--judge", "judge/m", "--verify", "verifier/v", "--no-transcripts",
    ])
    XCTAssertEqual(graded.judge, "judge/m")
    XCTAssertEqual(graded.verify, "verifier/v")
    XCTAssertTrue(graded.noTranscripts)
    XCTAssertEqual(graded.models, ["test/model"])
  }

  func testEvalsTranscriptParses() throws {
    let listing = try EvalsTranscript.parse([])
    XCTAssertNil(listing.id)
    let one = try EvalsTranscript.parse(["abc12345"])
    XCTAssertEqual(one.id, "abc12345")
    // Reachable as a subcommand of `evals`.
    let viaParent = try Evals.parseAsRoot(["transcript", "abc"]) as? EvalsTranscript
    XCTAssertEqual(viaParent?.id, "abc")
  }

  // MARK: Progress line

  /// The pre-X4 line, reproduced: an outcome with no grader must render exactly this.
  private func legacyLine(_ outcome: EvalOutcome) -> String {
    let mark = outcome.checkPassed ? ANSI.green("✓") : ANSI.red("✗")
    var line = "\(mark) \(outcome.taskId) · \(outcome.model)"
      + (outcome.dialect.map { " · \($0)" } ?? "")
      + " · \(outcome.steps) steps · \(Renderer.usd(outcome.costUSD))"
      + String(format: " · %.1fs", outcome.durationSeconds)
    if let error = outcome.error {
      line += ANSI.yellow(" · \(String(error.prefix(80)))")
    }
    return line
  }

  func testProgressLineIsByteIdenticalForAnUngradedOutcome() {
    for row in [
      outcome(),
      outcome(check: false),
      outcome(dialect: nil),
      outcome(check: false, error: "timeout after 300s"),
      // Trajectory facts alone (ids kept by default) change nothing on the line.
      outcome(session: "S1", run: "R1"),
    ] {
      XCTAssertEqual(Eval.progressLine(row), legacyLine(row))
    }
  }

  func testProgressLineAppendsGraderFactsAndKeysTheMarkOnIsPass() {
    // A rubric miss on a passing check: the mark follows the graded verdict.
    let rubricMiss = outcome(check: true, rubricScore: 0.5, rubricPassed: false, rubricUnknown: false, passed: false)
    let line = Eval.progressLine(rubricMiss)
    XCTAssertTrue(line.hasPrefix(ANSI.red("✗")), line)
    XCTAssertTrue(line.contains(" · rubric 0.50 \(ANSI.red("✗"))"), line)
    XCTAssertFalse(line.contains("limits"))
    XCTAssertFalse(line.contains("verify"))

    let rubricPass = outcome(rubricScore: 0.83, rubricPassed: true, rubricUnknown: false, passed: true)
    XCTAssertTrue(Eval.progressLine(rubricPass).contains(" · rubric 0.83 \(ANSI.green("✓"))"))

    let unknown = outcome(rubricScore: 0, rubricPassed: false, rubricUnknown: true, passed: false)
    XCTAssertTrue(Eval.progressLine(unknown).contains(" · rubric \(ANSI.red("✗")) (unknown)"))

    let limits = outcome(limitsPassed: false, violations: ["steps 9 > 6", "forbidden tool bash called 2×"], passed: true)
    let limitsLine = Eval.progressLine(limits)
    XCTAssertTrue(limitsLine.hasPrefix(ANSI.green("✓")), "limits recorded, not gating")
    XCTAssertTrue(limitsLine.contains(" · limits \(ANSI.red("✗")) steps 9 > 6, forbidden tool bash called 2×"), limitsLine)
    XCTAssertTrue(Eval.progressLine(outcome(limitsPassed: true, passed: true)).contains(" · limits \(ANSI.green("✓"))"))

    XCTAssertTrue(Eval.progressLine(outcome(verifierPassed: true)).contains(" · verify \(ANSI.green("✓"))"))
    XCTAssertTrue(Eval.progressLine(outcome(verifierPassed: false)).contains(" · verify \(ANSI.red("✗"))"))

    // Order: time, rubric, limits, verify, then the error.
    let everything = Eval.progressLine(outcome(
      rubricScore: 1, rubricPassed: true, rubricUnknown: false, limitsPassed: true, verifierPassed: true,
      passed: true, error: "late"))
    let rubricAt = try! XCTUnwrap(everything.range(of: "rubric")).lowerBound
    let limitsAt = try! XCTUnwrap(everything.range(of: "limits")).lowerBound
    let verifyAt = try! XCTUnwrap(everything.range(of: "verify")).lowerBound
    let errorAt = try! XCTUnwrap(everything.range(of: "late")).lowerBound
    XCTAssertTrue(rubricAt < limitsAt && limitsAt < verifyAt && verifyAt < errorAt, everything)
  }

  // MARK: evals transcript

  func testTranscriptResolvesByIdPrefixAndRunIdAndRendersMarkdown() throws {
    let store = tempStore()
    let id = "AAAA1111-0000-0000-0000-000000000001"
    try seedTrial(in: store, id: id)
    let sessions = try store.list()
    let rows = [outcome(task: "make-file", session: id, run: "RUN-7777-1")]

    // By id prefix (case-insensitive), by exact id, by run-id prefix.
    XCTAssertEqual(try EvalSessions.resolve("aaaa1111", sessions: sessions, outcomes: rows), id)
    XCTAssertEqual(try EvalSessions.resolve(id, sessions: sessions, outcomes: rows), id)
    XCTAssertEqual(try EvalSessions.resolve("RUN-7777", sessions: sessions, outcomes: rows), id)
    // A run id whose transcript was never kept (--no-transcripts) is unknown, not a guess.
    let orphan = [outcome(task: "gone", session: "ZZZZ-not-on-disk", run: "RUN-9999")]
    XCTAssertThrowsError(try EvalSessions.resolve("RUN-9999", sessions: sessions, outcomes: orphan)) { error in
      XCTAssertTrue(error is ValidationError)
    }
    XCTAssertThrowsError(try EvalSessions.resolve("nope", sessions: sessions, outcomes: rows)) { error in
      let text = "\(error)"
      XCTAssertTrue(text.contains("no eval transcript matching 'nope'"), text)
      XCTAssertTrue(text.contains("arnes evals"), text)
    }

    let markdown = try store.exportMarkdown(id: id)
    XCTAssertTrue(markdown.contains("## user\n\nWork in the current directory."), markdown)
    XCTAssertTrue(markdown.contains("> tool write_file("), markdown)
    XCTAssertTrue(markdown.contains("> ← write_file: created hello.txt"), markdown)
    XCTAssertTrue(markdown.contains("## assistant\n\ncreated hello.txt"), markdown)
  }

  func testTranscriptRefusesAnAmbiguousPrefix() throws {
    let store = tempStore()
    try seedTrial(in: store, id: "BBBB0000-1")
    try seedTrial(in: store, id: "BBBB0000-2")
    let sessions = try store.list()
    XCTAssertThrowsError(try EvalSessions.resolve("bbbb", sessions: sessions, outcomes: [])) { error in
      XCTAssertTrue("\(error)".contains("matches several eval transcripts"), "\(error)")
    }
    // Two rows with different sessions under one run-id prefix: refused too.
    let rows = [
      outcome(session: "BBBB0000-1", run: "RUN-1"),
      outcome(session: "BBBB0000-2", run: "RUN-2"),
    ]
    XCTAssertThrowsError(try EvalSessions.resolve("RUN-", sessions: sessions, outcomes: rows))
    // One session named by several rows (a re-run) is still one answer.
    let same = [outcome(session: "BBBB0000-1", run: "RUN-1"), outcome(session: "BBBB0000-1", run: "RUN-1b")]
    XCTAssertEqual(try EvalSessions.resolve("RUN-1", sessions: sessions, outcomes: same), "BBBB0000-1")
  }

  func testTranscriptListingNamesTheRowEachTranscriptBelongsTo() throws {
    let store = tempStore()
    try seedTrial(in: store, id: "CCCC0000-1", model: "a/model")
    try seedTrial(in: store, id: "CCCC0000-2", model: "b/model")
    let rows = [outcome(task: "fix-bug", check: true, session: "CCCC0000-1", passed: false)]
    let lines = EvalsTranscript.listingLines(sessions: try store.list(), outcomes: rows)
    XCTAssertEqual(lines.count, 2)
    let graded = try XCTUnwrap(lines.first { $0.hasPrefix("CCCC0000") && $0.contains("a/model") })
    XCTAssertTrue(graded.hasSuffix(" · unit/fix-bug ✗"), graded)
    let orphan = try XCTUnwrap(lines.first { $0.contains("b/model") })
    XCTAssertTrue(orphan.hasSuffix(" · (no eval row)"), orphan)
  }

  // MARK: evals prune

  func testPruneDeletesTheRemovedRowsTranscripts() throws {
    let store = tempStore()
    try seedTrial(in: store, id: "DDDD0000-1")
    try seedTrial(in: store, id: "DDDD0000-2")
    try seedTrial(in: store, id: "DDDD0000-3")
    let removed = [
      outcome(session: "DDDD0000-1"),
      outcome(session: "DDDD0000-1"), // the same trial twice: deleted once
      outcome(session: "not-kept"),   // --no-transcripts row: nothing to delete
      outcome(session: nil),
    ]
    XCTAssertEqual(EvalsPrune.deleteTranscripts(of: removed, in: store), 1)
    XCTAssertEqual(Set(try store.list().map(\.id)), ["DDDD0000-2", "DDDD0000-3"])
    XCTAssertEqual(EvalsPrune.deleteTranscripts(of: [], in: store), 0)
  }

  // MARK: evals capture --session

  func testCaptureResolvesAnEvalTrialSessionAfterTheUsersSessions() throws {
    let sessions = tempStore()
    let trials = tempStore()
    try sessions.append(.meta(id: "USER0000-1", model: "m", cwd: nil), to: "USER0000-1")
    try sessions.append(TranscriptEntry(message: .user("hi")), to: "USER0000-1")
    try seedTrial(in: trials, id: "EVAL0000-1")

    let user = try EvalsCapture.resolveSession("user0000", stores: [sessions, trials])
    XCTAssertEqual(user.0.id, "USER0000-1")
    let trial = try EvalsCapture.resolveSession("eval0000", stores: [sessions, trials])
    XCTAssertEqual(trial.0.id, "EVAL0000-1")
    XCTAssertEqual(trial.1.messages.count, 4)
    XCTAssertThrowsError(try EvalsCapture.resolveSession("zzz", stores: [sessions, trials])) { error in
      XCTAssertTrue("\(error)".contains("no session matching 'zzz'"), "\(error)")
    }
  }
}
