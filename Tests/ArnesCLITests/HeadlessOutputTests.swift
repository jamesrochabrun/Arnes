import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// `HeadlessEmitter` — the three output formats of `arnes do`. Text mode is a golden test
/// against the lines `Do.run` printed before the emitter existed: those bytes are what the
/// Terminal-Bench adapter and the agent skill read.
final class HeadlessOutputTests: XCTestCase {
  /// Captures both sinks, in order.
  private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var stdout: [String] = []
    private(set) var stderr: [String] = []

    func out(_ line: String) { lock.withLock { stdout.append(line) } }
    func err(_ line: String) { lock.withLock { stderr.append(line) } }
  }

  private func emitter(
    _ format: HeadlessOutputFormat, includePartial: Bool = false, verbose: Bool = false)
    -> (HeadlessEmitter, Capture)
  {
    let capture = Capture()
    let emitter = HeadlessEmitter(
      format: format, includePartial: includePartial, verbose: verbose,
      stdout: { capture.out($0) }, stderr: { capture.err($0) })
    return (emitter, capture)
  }

  private static func sampleResult(
    stopReason: StopReason = .completed, verifierPassed: Bool? = nil, denied: Int = 0, text: String = "all done")
    -> RunResult
  {
    var record = RunRecord(task: "t", model: "req/model", dialect: "chat", packFamily: "generic")
    record.sessionId = "S-1"
    record.steps = 3
    record.toolCalls = 2
    record.routedModels = ["served/model", "other/model"]
    record.costUSD = 0.01234
    record.finished = stopReason == .completed
    record.stopReason = stopReason
    record.verifierPassed = verifierPassed
    record.deniedCalls = denied == 0 ? nil : denied
    return RunResult(result: AgentResult(text: text, record: record, sessionId: "S-1", durationMs: 7), costEstimated: false)
  }

  private static let initInfo = InitInfo(
    sessionId: "S-1", version: "0.0-test", model: "req/model", dialect: "auto", provider: "openrouter",
    cwd: "/work", tools: ["read_file", "bash"], mcpServers: [.init(name: "docs", tools: 3, error: nil)],
    skills: ["init"], agents: ["explore"], hooks: 1, sandbox: "sandbox", effort: nil)

  // MARK: Text — golden

  func testTextModeLinesAreExactlyTheOldDoRunLines() {
    let (emitter, capture) = emitter(.text)
    emitter.emitInit(Self.initInfo)
    XCTAssertEqual(capture.stdout, [], "text mode prints no init line")

    let events: [AgentEvent] = [
      .textDelta("ignored"), .reasoningDelta("ignored"),
      .assistantText("Here is the plan."),
      .toolCall(name: "bash", arguments: #"{"command":"ls"}"#),
      .toolResult(name: "bash", preview: "a.txt"),
      .toolDenied(name: "write_file", reason: "no"),
      .userQuestion(question: "Which database?", options: ["sqlite", "postgres"]),
      .toolResult(name: "ask_user", preview: "error: cannot ask the user (no user is present in this headless run)"),
      .userQuestion(question: "What should the file be called?", options: []),
      .verifier(passed: true, verdict: "PASS: fine"),
      .verifier(passed: false, verdict: "FAIL: nope"),
      .routed(model: "served/model", provider: "Anthropic"),
      .routed(model: "served/model", provider: nil),
      .dialectFellBack(dialect: "messages", reason: "404"),
      .compacted(summarizedMessages: 4, keptMessages: 2),
      .toolResultsCleared(count: 3, freedChars: 12000),
      .toolResultsCleared(count: 1, freedChars: 2500),
      .contextWarning("context at 96% of the window with nothing left to clear"),
      .nudged(reason: "empty reply"),
      .stepLimitReached(maxSteps: 30),
      .budgetReached(spentUSD: 0.5, budgetUSD: 0.5),
      .hookNotice(event: "Stop", output: "tests green"),
      .hookBlocked(tool: "bash", reason: "no rm"),
      .hookStopped(reason: nil),
      .hookStopped(reason: "enough"),
      .promptBlocked(reason: "not now"),
      .deniedLoop(count: 3),
      .stuckDetected(reason: "the same edit_file call failed 6 times"),
      .contentFlagged(tool: "read_file", patterns: ["role_imitation", "instruction_phrase"]),
      .jobStarted(id: 1, command: "npm run dev"),
      .jobFinished(id: 1, exitStatus: 143),
      .retrying(attempt: 1, reason: "rate limited (429)"),
      .truncated,
      .planUpdated(steps: [
        (text: "read the code", status: "completed"), (text: "make the change", status: "in_progress"),
        (text: "run the tests", status: "pending"),
      ]),
      .planUpdated(steps: [(text: "read the code", status: "completed"), (text: "run the tests", status: "pending")]),
      .planUpdated(steps: [(text: "read the code", status: "completed")]),
      .subagentBlocked(name: "explore", id: "a1b2c3d4", reason: "no"),
      .subagentStarted(name: "explore", id: "a1b2c3d4", model: "sub/model", task: "look around"),
      .subagent(name: "explore", id: "a1b2c3d4", event: .toolCall(name: "grep", arguments: #"{"pattern":"x"}"#)),
      .subagent(name: "explore", id: "a1b2c3d4", event: .stepLimitReached(maxSteps: 5)),
      .subagent(name: "explore", id: "a1b2c3d4", event: .contentFlagged(tool: "bash", patterns: ["special_token"])),
      .subagent(name: "explore", id: "a1b2c3d4", event: .jobStarted(id: 1, command: "make -j8")),
      .subagent(name: "explore", id: "a1b2c3d4", event: .jobFinished(id: 1, exitStatus: 0)),
      .subagent(name: "explore", id: "a1b2c3d4", event: .retrying(attempt: 3, reason: "HTTP 503")),
      .subagent(name: "explore", id: "a1b2c3d4", event: .truncated),
      .subagent(name: "explore", id: "a1b2c3d4", event: .assistantText("nested prose is not printed")),
      .subagentFinished(name: "explore", id: "a1b2c3d4", steps: 2, toolCalls: 1, costUSD: 0.0042, resultPreview: "found"),
      .subagentBackgrounded(name: "general", id: "e5f6a7b8", model: "sub/model"),
      .subagentJoining(pending: 1),
      .subagentJoining(pending: 2),
      .subagentFinished(name: "general", id: "e5f6a7b8", steps: 2, toolCalls: 1, costUSD: 0.01, resultPreview: "cancelled"),
      .interrupted,
    ]
    for event in events { emitter.emit(event) }

    XCTAssertEqual(capture.stdout, [
      "Here is the plan.",
      #"→ bash {"command":"ls"}"#,
      "← bash: a.txt",
      "⊘ write_file denied",
      "? Which database? [sqlite | postgres]",
      "← ask_user: error: cannot ask the user (no user is present in this headless run)",
      "? What should the file be called?",
      "✔ PASS: fine",
      "✘ FAIL: nope",
      "⇄ routed to served/model (Anthropic)",
      "⇄ routed to served/model",
      "⤵ messages dialect failed (404) — fell back to chat",
      "◈ compacted 4 older messages",
      "◈ cleared 3 older tool results from the request (12000 chars)",
      "◈ cleared 1 older tool result from the request (2500 chars)",
      "⚠ context: context at 96% of the window with nothing left to clear",
      "↻ paused without finishing — nudged to continue",
      "⚠ step limit (30) reached before the task finished",
      "⚠ budget reached ($0.5000 ≥ $0.5000) — stopped before finishing",
      "⎔ Stop hook: tests green",
      "⊘ bash blocked by hook: no rm",
      "⏹ turn ended by hook",
      "⏹ turn ended by hook: enough",
      "⊘ prompt blocked by hook: not now",
      "⊘ stopped after 3 consecutive denials",
      "⚠ stuck: the same edit_file call failed 6 times",
      "⚠ flagged: read_file result matched role_imitation, instruction_phrase — treated as data",
      "⧗ job 1 started: npm run dev",
      "⧗ job 1 finished (exit 143)",
      "✂ reply hit the output limit",
      "☰ plan 1/3 · [~] make the change",
      "☰ plan 1/2 · [ ] run the tests",
      "☰ plan 1/1",
      "⊘ explore#a1b2c3d4 blocked by hook: no",
      "◇ explore#a1b2c3d4 (sub/model) look around",
      #"  ∙ [explore#a1b2c3d4] grep {"pattern":"x"}"#,
      "  ⚠ [explore#a1b2c3d4] hit its step limit (5)",
      "  ⚠ [explore#a1b2c3d4] flagged: bash result matched special_token — treated as data",
      "  ⧗ [explore#a1b2c3d4] job 1 started: make -j8",
      "  ⧗ [explore#a1b2c3d4] job 1 finished (exit 0)",
      "  ✂ [explore#a1b2c3d4] reply hit the output limit",
      "◆ explore#a1b2c3d4 · 2 steps · 1 tools · $0.0042",
      "◇ general#e5f6a7b8 (sub/model) … [background]",
      "⧗ waiting for 1 background subagent",
      "⧗ waiting for 2 background subagents",
      "◆ general#e5f6a7b8 · 2 steps · 1 tools · $0.0100 · cancelled",
    ])
    // A retry — the lead's or a subagent's — is wire chatter: stderr, never the run's stdout.
    XCTAssertEqual(capture.stderr, [
      "↻ retrying (attempt 1: rate limited (429))",
      "  ↻ [explore#a1b2c3d4] retrying (attempt 3: HTTP 503)",
    ])

    emitter.finish(Self.sampleResult())
    XCTAssertEqual(
      capture.stdout.last,
      "\n[requested req/model → served by served/model, other/model · dialect chat · 3 steps · 2 tool calls · $0.0123]")
  }

  func testTextModeClipsLongArgumentsAndReasonsLikeBefore() {
    let (emitter, capture) = emitter(.text)
    let longArguments = String(repeating: "x", count: 200)
    emitter.emit(.toolCall(name: "bash", arguments: longArguments))
    XCTAssertEqual(capture.stdout.last, "→ bash " + String(repeating: "x", count: 120))
    let longReason = String(repeating: "r", count: 200)
    emitter.emit(.hookBlocked(tool: "bash", reason: longReason))
    XCTAssertEqual(capture.stdout.last, "⊘ bash blocked by hook: " + String(repeating: "r", count: 120))
    emitter.emit(.dialectFellBack(dialect: "responses", reason: longReason))
    XCTAssertEqual(capture.stdout.last, "⤵ responses dialect failed (\(String(repeating: "r", count: 80))) — fell back to chat")
    emitter.emit(.subagentStarted(name: "a", id: "1", model: "m", task: String(repeating: "t", count: 100)))
    XCTAssertEqual(capture.stdout.last, "◇ a#1 (m) " + String(repeating: "t", count: 80))
  }

  func testTextFooterShowsAQuestionMarkWhenNothingWasRouted() {
    var result = Self.sampleResult()
    result.routedModels = []
    XCTAssertEqual(
      HeadlessEmitter.footer(for: result),
      "\n[requested req/model → served by ? · dialect chat · 3 steps · 2 tool calls · $0.0123]")
  }

  // MARK: json

  func testJSONModeWritesOnlyTheResultToStdout() throws {
    let (emitter, capture) = emitter(.json)
    emitter.emitInit(Self.initInfo)
    emitter.emit(.assistantText("hi"))
    emitter.emit(.toolCall(name: "bash", arguments: "{}"))
    emitter.emit(.verifier(passed: true, verdict: "PASS"))
    XCTAssertEqual(capture.stdout, [], "nothing until the run ends")
    XCTAssertEqual(capture.stderr, [], "no progress without --verbose")
    XCTAssertEqual(emitter.verdict, "PASS", "the verdict is captured for the envelope")

    emitter.finish(Self.sampleResult())
    XCTAssertEqual(capture.stdout.count, 1)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(capture.stdout[0].utf8)) as? [String: Any])
    XCTAssertEqual(object["type"] as? String, "result")
    XCTAssertEqual(object["session_id"] as? String, "S-1")
    XCTAssertEqual(object["stop_reason"] as? String, "completed")
    XCTAssertEqual(object["result"] as? String, "all done")
    XCTAssertEqual(object["steps"] as? Int, 3)
  }

  func testJSONModeVerboseMirrorsTextLinesToStderr() {
    let (emitter, capture) = emitter(.json, verbose: true)
    emitter.emit(.assistantText("hi"))
    emitter.emit(.toolCall(name: "bash", arguments: "{}"))
    emitter.emit(.textDelta("h"))
    XCTAssertEqual(capture.stdout, [])
    XCTAssertEqual(capture.stderr, ["hi", "→ bash {}"])
  }

  // MARK: stream-json

  func testStreamJSONEmitsInitFirstEventsInOrderAndResultLast() throws {
    let (emitter, capture) = emitter(.streamJson)
    emitter.emitInit(Self.initInfo)
    emitter.emit(.textDelta("h"))
    emitter.emit(.reasoningDelta("r"))
    emitter.emit(.toolCall(name: "bash", arguments: #"{"command":"ls"}"#))
    emitter.emit(.toolResult(name: "bash", preview: "a.txt"))
    emitter.emit(.assistantText("done"))
    emitter.emit(.toolDenied(name: "write_file", reason: "no"))
    emitter.finish(Self.sampleResult())

    let types = try capture.stdout.map { line -> String in
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      return try XCTUnwrap(object["type"] as? String)
    }
    XCTAssertEqual(types, ["init", "tool_call", "tool_result", "assistant", "tool_denied", "result"])
    XCTAssertEqual(capture.stderr, [])
    // Every object after init carries the session id the init announced.
    for line in capture.stdout.dropFirst() {
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      XCTAssertEqual(object["session_id"] as? String, "S-1", line)
    }
    // The init line is the assembled run.
    let initObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(capture.stdout[0].utf8)) as? [String: Any])
    XCTAssertEqual(initObject["model"] as? String, "req/model")
    XCTAssertEqual(initObject["tools"] as? [String], ["read_file", "bash"])
    XCTAssertEqual((initObject["mcp_servers"] as? [[String: Any]])?.first?["name"] as? String, "docs")
    XCTAssertEqual(initObject["hooks"] as? Int, 1)
    XCTAssertEqual(initObject["sandbox"] as? String, "sandbox")
    XCTAssertEqual(initObject["permission_mode"] as? String, "default")
    XCTAssertEqual(initObject["cwd"] as? String, "/work")
    XCTAssertEqual(initObject["version"] as? String, "0.0-test")
  }

  func testStreamJSONIncludesDeltasOnlyWithIncludePartial() throws {
    let (emitter, capture) = emitter(.streamJson, includePartial: true)
    emitter.emitInit(Self.initInfo)
    emitter.emit(.textDelta("h"))
    emitter.emit(.reasoningDelta("r"))
    emitter.emit(.assistantText("h"))
    let types = try capture.stdout.map { line -> String in
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
      return try XCTUnwrap(object["type"] as? String)
    }
    XCTAssertEqual(types, ["init", "text_delta", "reasoning_delta", "assistant"])
  }

  func testStreamJSONVerboseMirrorsTextToStderrWhileStdoutStaysJSON() {
    let (emitter, capture) = emitter(.streamJson, verbose: true)
    emitter.emitInit(Self.initInfo)
    emitter.emit(.toolCall(name: "bash", arguments: "{}"))
    XCTAssertEqual(capture.stderr, ["→ bash {}"])
    XCTAssertEqual(capture.stdout.count, 2)
    XCTAssertTrue(capture.stdout[1].hasPrefix("{"))
  }

  func testInitLineUsesSnakeCaseKeys() throws {
    let line = HeadlessJSON.line(Self.initInfo)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    XCTAssertEqual(
      Set(object.keys),
      ["type", "session_id", "version", "model", "dialect", "provider", "cwd", "tools", "mcp_servers", "skills", "agents", "hooks", "sandbox", "permission_mode", "withheld_tools"],
      "nil effort is omitted; everything else is present (H1 added `withheld_tools`, always present)")
    XCTAssertEqual(object["withheld_tools"] as? [String], [], "nothing withheld → an empty list, never absent")
  }

  func testInitLineCarriesTheParityKeysOnlyWhenSet() throws {
    // X3: `agent`, `resumed`, `forked_from` are additive — a plain run's init line is the one
    // above; a `--agent`/`--resume --fork` run adds them.
    var info = Self.initInfo
    info.agent = "reviewer"
    info.resumed = true
    info.forkedFrom = "S-0"
    info.withheldTools = ["view_image"]
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(HeadlessJSON.line(info).utf8)) as? [String: Any])
    XCTAssertEqual(object["agent"] as? String, "reviewer")
    XCTAssertEqual(object["resumed"] as? Bool, true)
    XCTAssertEqual(object["forked_from"] as? String, "S-0")
    // H1: `withheld_tools` is always present (the offered set's complement, `[]` when nothing is withheld).
    XCTAssertEqual(object["withheld_tools"] as? [String], ["view_image"])
    XCTAssertEqual(
      Set(object.keys).subtracting(["type", "session_id", "version", "model", "dialect", "provider", "cwd", "tools", "mcp_servers", "skills", "agents", "hooks", "sandbox", "permission_mode", "withheld_tools"]),
      ["agent", "resumed", "forked_from"])
  }

  // MARK: Flags

  func testDoParsesTheHeadlessFlags() throws {
    let command = try Do.parse([
      "do it", "--output-format", "stream-json", "--include-partial", "--verbose", "--fail-on-denied",
      "--output-last-message", "/tmp/last.txt", "--max-steps", "5", "--timeout", "12.5", "--bare",
      "-C", "/tmp",
    ])
    XCTAssertEqual(command.task, "do it")
    XCTAssertEqual(command.outputFormat, .streamJson)
    XCTAssertTrue(command.includePartial)
    XCTAssertTrue(command.verbose)
    XCTAssertTrue(command.failOnDenied)
    XCTAssertEqual(command.outputLastMessage, "/tmp/last.txt")
    XCTAssertEqual(command.maxSteps, 5)
    XCTAssertEqual(command.timeout, 12.5)
    XCTAssertTrue(command.bare)
    XCTAssertEqual(command.workingDirectoryPath, "/tmp")
    let long = try Do.parse(["x", "--cwd", "/tmp", "--output-format", "json"])
    XCTAssertEqual(long.workingDirectoryPath, "/tmp")
    XCTAssertEqual(long.outputFormat, .json)
  }

  func testDoDefaultsLeaveTodaysBehaviorAlone() throws {
    let command = try Do.parse(["say hi"])
    XCTAssertEqual(command.outputFormat, .text)
    XCTAssertFalse(command.includePartial)
    XCTAssertFalse(command.verbose)
    XCTAssertFalse(command.failOnDenied)
    XCTAssertFalse(command.bare)
    XCTAssertNil(command.outputLastMessage)
    XCTAssertNil(command.maxSteps)
    XCTAssertNil(command.timeout)
    XCTAssertNil(command.workingDirectoryPath)
    // The task is optional now (stdin can carry it) — parsing without one still succeeds.
    XCTAssertNil(try Do.parse([]).task)
    XCTAssertThrowsError(try Do.parse(["x", "--output-format", "yaml"]))
  }

  func testChangeDirectoryRejectsANonDirectory() {
    XCTAssertThrowsError(try Do.changeDirectory(to: "/definitely/not/here/\(UUID().uuidString)"))
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-cwd-\(UUID().uuidString).txt")
    try? "x".write(to: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: file) }
    XCTAssertThrowsError(try Do.changeDirectory(to: file.path))
  }

  func testWriteLastMessageWritesTheTextAtomically() throws {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-last-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: file) }
    try Do.writeLastMessage("final words\n", to: file.path)
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "final words\n")
  }

  // MARK: REPL — background subagents (A4: `/tasks`, the notes, the guards)

  func testSlashTasksParsesAndIsDocumented() throws {
    guard case .tasks? = SlashCommand.parse("/tasks") else { return XCTFail("expected .tasks") }
    XCTAssertTrue(SlashCommand.helpText.contains("/tasks"))
  }

  func testTasksListingNamesRunsAndSaysHowTheyEnd() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let empty = Interactive.tasksListing([], now: now)
    XCTAssertTrue(empty.contains("no background subagents"))
    XCTAssertTrue(empty.contains("Ctrl-C during a turn cancels them"))
    let listing = Interactive.tasksListing([
      BackgroundRun(id: "a1b2c3d4", agent: "explore", model: "sub/model", startedAt: now.addingTimeInterval(-12), finished: false),
      BackgroundRun(id: "e5f6a7b8", agent: "general", model: "sub/model", startedAt: now.addingTimeInterval(-90), finished: true),
    ], now: now)
    let lines = listing.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].contains("explore#a1b2c3d4"), lines[0])
    XCTAssertTrue(lines[0].contains("12.0s"), lines[0])
    XCTAssertTrue(lines[0].contains("running"), lines[0])
    XCTAssertTrue(lines[1].contains("general#e5f6a7b8"), lines[1])
    XCTAssertTrue(lines[1].contains("1m30s"), lines[1])
    XCTAssertTrue(lines[1].contains("finished — delivered with your next message"), lines[1])
  }

  func testBackgroundNotesCountRunningAndReady() {
    XCTAssertNil(Interactive.backgroundPendingNote([]))
    let now = Date()
    let running = BackgroundRun(id: "1", agent: "a", model: "m", startedAt: now, finished: false)
    let ready = BackgroundRun(id: "2", agent: "b", model: "m", startedAt: now, finished: true)
    XCTAssertEqual(
      Interactive.backgroundPendingNote([running]),
      "1 background subagent still running — delivered with your next message (/tasks lists them)")
    XCTAssertEqual(
      Interactive.backgroundPendingNote([running, running, ready]),
      "2 background subagents still running · 1 background result ready — delivered with your next message (/tasks lists them)")
    let line = Interactive.backgroundFinishedLine(BackgroundOutcome(
      id: "a1b2c3d4", agent: "explore", model: "m", report: "r", steps: 3, toolCalls: 2, costUSD: 0.0042, partial: false))
    XCTAssertTrue(line.contains("◆ explore#a1b2c3d4"), line)
    XCTAssertTrue(line.contains("3 steps · 2 tools · $0.0042"), line)
    XCTAssertTrue(line.contains("background result ready — delivered with your next message"), line)
  }

  func testHistorySwappingCommandsAreGuardedWhileBackgroundWorkIsPending() {
    XCTAssertTrue(Interactive.swapsHistory(.resume(query: nil)))
    XCTAssertTrue(Interactive.swapsHistory(.fork(name: nil)))
    XCTAssertTrue(Interactive.swapsHistory(.clear))
    // /model keeps working: a background run has its own model and delivers into the same history.
    XCTAssertFalse(Interactive.swapsHistory(.model(query: "sonnet")))
    XCTAssertFalse(Interactive.swapsHistory(.tasks))
    XCTAssertFalse(Interactive.swapsHistory(.compact(argument: nil)), "compact is refused Session-side")
  }

  func testPermissionPromptBetweenTurnsIsDeniedInsteadOfReadingStdin() async {
    // No turn in flight and no key watcher: the line editor owns stdin, so the request from a
    // background subagent is refused outright — never a raw read racing the editor for a byte.
    let permissions = TerminalPermissions(turnInFlight: { false })
    let decision = await permissions.decide(
      toolName: "write_file", summary: "write_file notes.md", argumentsJSON: "{}")
    guard case .deny(let reason) = decision else {
      return XCTFail("expected a denial, got \(decision)")
    }
    XCTAssertEqual(reason, TerminalPermissions.noTurnDenial)
    XCTAssertTrue(reason?.contains("no turn in flight") == true)
    // The turn-bracketing flag the REPL feeds it: raised before the turn's task exists.
    let interrupts = InterruptController()
    XCTAssertFalse(interrupts.isTurnInFlight)
    interrupts.beginTurn()
    XCTAssertTrue(interrupts.isTurnInFlight)
    interrupts.endTurn()
    XCTAssertFalse(interrupts.isTurnInFlight)
  }
}
