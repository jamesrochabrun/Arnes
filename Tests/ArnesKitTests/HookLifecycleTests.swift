import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The remaining lifecycle events (H3): UserPromptSubmit, SessionStart/End, PreCompact/
/// PostCompact, PostToolUseFailure, PermissionRequest, Notification, and Stop's block→continue.
/// Each gates or feeds back through the same `HookOutcome` contract the tool events use;
/// `HookEvent.isGate` decides which, and every gate keeps the narrow-only rule.
final class HookLifecycleTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hooklifecycle-\(UUID().uuidString).jsonl"))
  }

  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hooklifecycle-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tempFile(_ label: String) -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hooklifecycle-\(label)-\(UUID().uuidString)")
  }

  /// A hook command that appends its stdin payload (one JSON object per line) to `file`.
  private func capture(to file: URL, then tail: String = "") -> String {
    "cat >> '\(file.path)'; echo >> '\(file.path)'" + (tail.isEmpty ? "" : "; \(tail)")
  }

  private func payloads(in file: URL) throws -> [HookPayload] {
    guard let raw = try? String(contentsOf: file, encoding: .utf8) else { return [] }
    return try raw.split(separator: "\n").filter { !$0.isEmpty }
      .map { try JSONDecoder().decode(HookPayload.self, from: Data($0.utf8)) }
  }

  private func textTurn(_ text: String, promptTokens: Int = 10) -> [ChatCompletionChunk] {
    [Fixtures.textChunk(text), Fixtures.usageChunk(cost: 0, promptTokens: promptTokens)]
  }

  private func makeSession(
    root: URL? = nil,
    tools: [any AgentTool] = [],
    script: [[ChatCompletionChunk]],
    hooks: [HookDefinition],
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    mode: PermissionMode = .default,
    rules: PermissionRules = .empty,
    maxSteps: Int = 30,
    contextLength: Int = 8000,
    extraSystemSections: [String] = [],
    recordStore: RunRecordStore? = nil)
    -> (Session, MockOpenRouterService)
  {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: contextLength))
    mock.chunkScripts = script
    let session = Session(
      service: mock, tools: tools, permissions: permissions, store: recordStore ?? store(),
      configuration: .init(
        model: "test/model", maxStepsPerTurn: maxSteps, extraSystemSections: extraSystemSections,
        hooks: hooks, workingDirectory: root, permissionMode: mode, permissionRules: rules))
    return (session, mock)
  }

  private func userMessages(_ request: ChatCompletionRequest) -> [String] {
    request.messages.filter { $0.role == .user }.compactMap { $0.content?.plainText }
  }

  private func systemPrompt(_ request: ChatCompletionRequest) -> String {
    request.messages.first { $0.role == .system }?.content?.plainText ?? ""
  }

  // MARK: UserPromptSubmit

  func testUserPromptSubmitDenyBlocksTheTurnBeforeAnyRequestAndLeavesNoDanglingUserTurn() async throws {
    let recordStore = store()
    let (session, mock) = makeSession(
      script: [textTurn("should not run for the blocked prompt"), textTurn("hi there")],
      hooks: [HookDefinition(
        event: .userPromptSubmit, when: ["prompt": "(?i)secret"],
        command: "echo 'no secrets in prompts' >&2; exit 2")],
      recordStore: recordStore)
    var kinds: [AgentEvent.Kind] = []
    var blocked: String?
    for try await event in await session.send("here is my secret") {
      kinds.append(event.kind)
      if case .promptBlocked(let reason) = event { blocked = reason }
    }
    XCTAssertEqual(blocked, "no secrets in prompts")
    XCTAssertEqual(mock.requests.count, 0, "a blocked prompt costs no request")
    XCTAssertTrue(kinds.contains(.turnFinished), "the turn still ends with its footer")
    XCTAssertFalse(kinds.contains(.assistantText))
    let history = await session.history
    XCTAssertTrue(history.isEmpty, "the blocked text never entered history: \(history)")
    // The record still lands, and says why.
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .hookStopped)
    XCTAssertEqual(record?.hookBlocks, 1)
    XCTAssertEqual(record?.steps, 0)
    XCTAssertEqual(try recordStore.all().count, 1)

    // The next prompt runs on a valid history: exactly its own user message.
    for try await _ in await session.send("hello") {}
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertEqual(userMessages(mock.requests[0]), ["hello"])
    XCTAssertEqual(try recordStore.all().count, 2)
  }

  func testUserPromptSubmitStdoutRidesTheUserMessageAsContextWithThePromptIntact() async throws {
    let payloadFile = tempFile("prompt-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let (session, mock) = makeSession(
      script: [textTurn("ok")],
      hooks: [
        HookDefinition(event: .userPromptSubmit, command: capture(to: payloadFile, then: "echo 'today is Tuesday'")),
        HookDefinition(
          event: .userPromptSubmit,
          command: #"echo '{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":"branch: main"}}'"#),
      ])
    for try await _ in await session.send("what day is it?") {}
    let sent = userMessages(mock.requests[0])
    XCTAssertEqual(sent, ["what day is it?\n\n[context]\ntoday is Tuesday\nbranch: main"])
    let history = await session.history
    XCTAssertEqual(history.first?.content?.plainText, sent[0], "history carries what was sent")
    let record = await session.lastRecord
    XCTAssertEqual(record?.task, "what day is it?", "the record keeps the user's own words")
    // The payload carries the prompt under Claude Code's name.
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.count, 1)
    XCTAssertEqual(payload.first?.hookEventName, "UserPromptSubmit")
    XCTAssertEqual(payload.first?.prompt, "what day is it?")
    XCTAssertNil(payload.first?.toolName)
  }

  func testUserPromptSubmitMatcherIsIgnoredAndWhenFiltersOnThePrompt() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .userPromptSubmit, matcher: "some-tool", command: "echo matched-anyway"),
      HookDefinition(event: .userPromptSubmit, when: ["prompt": "^deploy"], command: "echo deploy-hook"),
    ])
    let deploy = await engine.userPromptSubmit(prompt: "deploy now")
    XCTAssertEqual(deploy.context, ["matched-anyway", "deploy-hook"])
    let hello = await engine.userPromptSubmit(prompt: "hello")
    XCTAssertEqual(hello.context, ["matched-anyway"], "no subject: the matcher never filters, `when` does")
  }

  // MARK: SessionStart / SessionEnd

  func testSessionStartContextRidesTheSystemPromptMatchedOnSource() async throws {
    let payloadFile = tempFile("start-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let (session, mock) = makeSession(
      script: [textTurn("a"), textTurn("b"), textTurn("c"), textTurn("d")],
      hooks: [
        HookDefinition(event: .sessionStart, matcher: "startup", command: capture(to: payloadFile, then: "echo 'REPO IS CLEAN'")),
        HookDefinition(event: .sessionStart, matcher: "resume", command: "echo 'RESUMED HERE'"),
      ],
      extraSystemSections: ["EXTRA SECTION"])

    // Nothing runs behind `send`'s back: without `start` there is no context.
    for try await _ in await session.send("one") {}
    XCTAssertFalse(systemPrompt(mock.requests[0]).contains("REPO IS CLEAN"))

    let notices = await session.start(source: .startup)
    XCTAssertEqual(notices, [])
    for try await _ in await session.send("two") {}
    let prompt = systemPrompt(mock.requests[1])
    XCTAssertTrue(prompt.contains("REPO IS CLEAN"), prompt)
    XCTAssertFalse(prompt.contains("RESUMED HERE"), "the resume hook did not match `startup`")
    // Fixed order: after the embedder's sections.
    let extra = prompt.range(of: "EXTRA SECTION")!.lowerBound
    let context = prompt.range(of: "REPO IS CLEAN")!.lowerBound
    XCTAssertLessThan(extra, context)
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.first?.hookEventName, "SessionStart")
    XCTAssertEqual(payload.first?.source, "startup")

    // A start that produces nothing keeps the context (a compaction must not drop it)…
    await session.start(source: .compact)
    for try await _ in await session.send("three") {}
    XCTAssertTrue(systemPrompt(mock.requests[2]).contains("REPO IS CLEAN"))
    // …and one that produces context replaces it.
    await session.start(source: .resume)
    for try await _ in await session.send("four") {}
    let replaced = systemPrompt(mock.requests[3])
    XCTAssertTrue(replaced.contains("RESUMED HERE"))
    XCTAssertFalse(replaced.contains("REPO IS CLEAN"))
  }

  func testClearHistoryEndsWithClearResetsTheContextAndStartsWithClear() async throws {
    let endMarker = tempFile("end-clear")
    defer { try? FileManager.default.removeItem(at: endMarker) }
    let (session, mock) = makeSession(
      script: [textTurn("a"), textTurn("b")],
      hooks: [
        HookDefinition(event: .sessionStart, matcher: "startup", command: "echo STARTUP-CTX"),
        HookDefinition(event: .sessionStart, matcher: "clear", command: "echo CLEARED-CTX"),
        HookDefinition(event: .sessionEnd, matcher: "clear", command: "echo ended >> '\(endMarker.path)'; echo bye"),
        HookDefinition(event: .sessionEnd, matcher: "exit", command: "echo SHOULD_NOT_RUN >> '\(endMarker.path)'"),
      ])
    await session.start(source: .startup)
    for try await _ in await session.send("one") {}
    XCTAssertTrue(systemPrompt(mock.requests[0]).contains("STARTUP-CTX"))

    let notices = await session.clearHistory()
    XCTAssertEqual(notices, [HookNotice(event: "SessionEnd", output: "bye")], "SessionEnd output is surfaced")
    XCTAssertEqual(try String(contentsOf: endMarker, encoding: .utf8), "ended\n", "only the `clear` reason matched")
    let remaining = await session.messageCount
    XCTAssertEqual(remaining, 0)
    for try await _ in await session.send("two") {}
    let prompt = systemPrompt(mock.requests[1])
    XCTAssertTrue(prompt.contains("CLEARED-CTX"), prompt)
    XCTAssertFalse(prompt.contains("STARTUP-CTX"), "clear resets what startup stored")
    XCTAssertEqual(userMessages(mock.requests[1]), ["two"])
  }

  func testSessionEndRunsUnderItsBudgetAndSurfacesItsOutput() async throws {
    let payloadFile = tempFile("end-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let quick = HookEngine(hooks: [
      HookDefinition(event: .sessionEnd, command: capture(to: payloadFile, then: "echo 'saved notes'")),
    ])
    let outcome = await quick.sessionEnd(reason: "exit")
    XCTAssertEqual(outcome.feedback, "saved notes")
    XCTAssertEqual(outcome.errors, [])
    XCTAssertEqual(try payloads(in: payloadFile).first?.reason, "exit")
    XCTAssertEqual(try payloads(in: payloadFile).first?.hookEventName, "SessionEnd")

    let slow = HookEngine(hooks: [
      HookDefinition(event: .sessionEnd, command: "sleep 10; echo too-late"),
    ])
    let started = Date()
    let late = await slow.sessionEnd(reason: "exit")
    let elapsed = Date().timeIntervalSince(started)
    XCTAssertLessThan(elapsed, 6, "the budget, not the hook's 10s, bounds SessionEnd")
    XCTAssertEqual(late.feedback, "")
    XCTAssertEqual(late.errors.count, 1)
    XCTAssertTrue(late.errors[0].contains("SessionEnd budget"), late.errors.description)

    // A session without hooks ends silently.
    let (bare, _) = makeSession(script: [], hooks: [])
    let none = await bare.end(reason: .exit)
    XCTAssertEqual(none, [])
  }

  // MARK: PreCompact / PostCompact

  private func twoTurnsThenCompact(hooks: [HookDefinition], contextLength: Int = 8000)
    -> (Session, MockOpenRouterService)
  {
    let (session, mock) = makeSession(
      script: [textTurn("answer one"), textTurn("answer two"), textTurn("answer three")],
      hooks: hooks, contextLength: contextLength)
    mock.chatResponses = [Fixtures.textResponse("SUMMARY NOTES", cost: 0.002)]
    return (session, mock)
  }

  func testManualPreCompactDenyCancelsTheCompaction() async throws {
    let (session, mock) = twoTurnsThenCompact(hooks: [
      HookDefinition(event: .preCompact, matcher: "manual", command: "echo 'not now' >&2; exit 2"),
    ])
    for try await _ in await session.send("turn one") {}
    for try await _ in await session.send("turn two") {}
    do {
      _ = try await session.compact()
      XCTFail("a PreCompact deny cancels a manual compaction")
    } catch SessionError.compactionCancelled(let reason) {
      XCTAssertEqual(reason, "not now")
    }
    XCTAssertEqual(mock.requests.count, 2, "no summarizer request was made")
    XCTAssertEqual(mock.chatResponses.count, 1, "the scripted summary was never consumed")
    let remaining = await session.messageCount
    XCTAssertEqual(remaining, 4, "history is untouched")
  }

  func testAutoPreCompactIgnoresADenyAndSaysSo() async throws {
    let (session, mock) = makeSession(
      script: [
        textTurn("a1", promptTokens: 20),
        textTurn("a2", promptTokens: 90), // 90% of a 100-token window → auto-compact next turn
        textTurn("a3", promptTokens: 30),
      ],
      hooks: [HookDefinition(event: .preCompact, matcher: "auto", command: "echo 'not now' >&2; exit 2")],
      contextLength: 100)
    mock.chatResponses = [Fixtures.textResponse("AUTO SUMMARY", cost: 0.001)]
    for try await _ in await session.send("turn one") {}
    for try await _ in await session.send("turn two") {}
    var compacted = false
    var notices: [String] = []
    for try await event in await session.send("turn three") {
      if case .compacted = event { compacted = true }
      if case .hookNotice("PreCompact", let output) = event { notices.append(output) }
    }
    XCTAssertTrue(compacted, "an automatic compaction goes ahead — the context is full either way")
    XCTAssertEqual(notices.count, 1)
    XCTAssertTrue(notices[0].contains("ignored"), notices.description)
    XCTAssertTrue(notices[0].contains("not now"), notices.description)
    XCTAssertTrue(systemPrompt(mock.requests.last!).contains("AUTO SUMMARY"))
  }

  func testPreCompactStdoutSteersTheSummarizerAndPostCompactPlusStartCompactRun() async throws {
    let payloadFile = tempFile("compact-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let (session, mock) = twoTurnsThenCompact(hooks: [
      HookDefinition(event: .preCompact, command: capture(to: payloadFile, then: "echo 'Keep every file path verbatim.'")),
      HookDefinition(event: .postCompact, matcher: "manual", command: "echo POSTED"),
      HookDefinition(event: .sessionStart, matcher: "compact", command: "echo AFTER-COMPACT"),
    ])
    for try await _ in await session.send("turn one") {}
    for try await _ in await session.send("turn two") {}
    let result = try await session.compact()
    XCTAssertEqual(result.summarizedMessages, 2)
    XCTAssertEqual(result.hookNotices, [HookNotice(event: "PostCompact", output: "POSTED")])
    // The summarizer got the base prompt plus the hook's instructions.
    let summarizer = mock.requests[2]
    let instructions = summarizer.messages[0].content?.plainText ?? ""
    XCTAssertTrue(instructions.hasPrefix("You compress an agent conversation"), instructions)
    XCTAssertTrue(instructions.hasSuffix(
      "Additional instructions from the user's PreCompact hook:\nKeep every file path verbatim."), instructions)
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.first?.hookEventName, "PreCompact")
    XCTAssertEqual(payload.first?.trigger, "manual")
    // SessionStart(compact) ran after the compaction: its context rides the next request.
    for try await _ in await session.send("turn three") {}
    let prompt = systemPrompt(mock.requests.last!)
    XCTAssertTrue(prompt.contains("AFTER-COMPACT"), prompt)
    XCTAssertTrue(prompt.contains("SUMMARY NOTES"), prompt)
  }

  // MARK: Stop block → continue

  func testStopBlockContinuesTheTurnWithTheReasonAsAUserMessageAndStopsAfterThree() async throws {
    let payloadFile = tempFile("stop-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let recordStore = store()
    let (session, mock) = makeSession(
      script: [textTurn("v1"), textTurn("v2"), textTurn("v3"), textTurn("v4"), textTurn("v5 never")],
      hooks: [HookDefinition(
        event: .stop,
        command: capture(to: payloadFile, then: #"echo '{"decision":"block","reason":"tests still failing"}'"#))],
      recordStore: recordStore)
    var notices: [String] = []
    var texts: [String] = []
    for try await event in await session.send("go") {
      if case .hookNotice("Stop", let output) = event { notices.append(output) }
      if case .assistantText(let text) = event { texts.append(text) }
    }
    XCTAssertEqual(mock.requests.count, 4, "the finish plus three continuations")
    XCTAssertEqual(texts, ["v1", "v2", "v3", "v4"])
    XCTAssertEqual(
      userMessages(mock.requests[3]),
      ["go", "[hook] tests still failing", "[hook] tests still failing", "[hook] tests still failing"])
    XCTAssertEqual(notices.count, 4)
    XCTAssertTrue(notices[0].hasPrefix("continuing the turn (1/3)"), notices[0])
    XCTAssertTrue(notices[2].hasPrefix("continuing the turn (3/3)"), notices[2])
    XCTAssertTrue(notices[3].contains("already continued 3 times"), notices[3])
    // One record for the whole turn.
    let records = try recordStore.all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].hookContinuations, 3)
    XCTAssertEqual(records[0].stopReason, .completed)
    XCTAssertEqual(records[0].steps, 4)
    XCTAssertTrue(records[0].finished)
    // The re-runs say so.
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.map(\.stopHookActive), [nil, true, true, true])
    XCTAssertEqual(payload.map(\.hookEventName), Array(repeating: "Stop", count: 4))
  }

  func testStopBlockOnceThenPlainOutputEndsNormally() async throws {
    let marker = tempFile("stop-once")
    defer { try? FileManager.default.removeItem(at: marker) }
    let (session, mock) = makeSession(
      script: [textTurn("first"), textTurn("second")],
      hooks: [HookDefinition(
        event: .stop,
        command: "if [ -e '\(marker.path)' ]; then echo all-green; else touch '\(marker.path)'; echo 'run the tests' >&2; exit 2; fi")])
    var notices: [String] = []
    for try await event in await session.send("go") {
      if case .hookNotice("Stop", let output) = event { notices.append(output) }
    }
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(userMessages(mock.requests[1]), ["go", "[hook] run the tests"], "exit 2 continues too")
    XCTAssertEqual(notices, ["continuing the turn (1/3): run the tests", "all-green"])
    let record = await session.lastRecord
    XCTAssertEqual(record?.hookContinuations, 1)
    XCTAssertEqual(record?.stopReason, .completed)
  }

  func testStopContinueFalseOutranksBlockAndTheRunsOtherOutputIsNotLost() async throws {
    // `{"decision":"block","continue":false}`: the hook wants the turn over, not the model
    // back at work — Claude Code's precedence. And when a block *does* continue, what the
    // other Stop hooks said in that run is surfaced rather than dropped with the outcome.
    var (session, mock) = makeSession(
      script: [textTurn("first"), textTurn("never")],
      hooks: [HookDefinition(
        event: .stop,
        command: #"echo '{"decision":"block","reason":"more to do","continue":false}'"#)])
    var notices: [String] = []
    for try await event in await session.send("go") {
      if case .hookNotice("Stop", let output) = event { notices.append(output) }
    }
    XCTAssertEqual(mock.requests.count, 1, "continue: false ends the turn")
    XCTAssertTrue(notices.contains { $0.contains("asked to continue (more to do)") }, "\(notices)")
    var record = await session.lastRecord
    XCTAssertNil(record?.hookContinuations)
    XCTAssertEqual(record?.stopReason, .completed)

    let marker = tempFile("stop-second-hook")
    defer { try? FileManager.default.removeItem(at: marker) }
    (session, mock) = makeSession(
      script: [textTurn("first"), textTurn("second")],
      hooks: [
        HookDefinition(
          event: .stop,
          command: "if [ -e '\(marker.path)' ]; then :; else touch '\(marker.path)'; echo 'keep going' >&2; exit 2; fi"),
        HookDefinition(event: .stop, command: "echo lint-clean"),
      ])
    notices = []
    for try await event in await session.send("go") {
      if case .hookNotice("Stop", let output) = event { notices.append(output) }
    }
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(
      notices, ["lint-clean", "continuing the turn (1/3): keep going", "lint-clean"],
      "the second hook's output from the run that continued is not lost")
    record = await session.lastRecord
    XCTAssertEqual(record?.hookContinuations, 1)
  }

  func testStopBlockIsOnlyReportedWhenTheTurnDidNotFinishNaturally() async throws {
    // maxSteps 1 with a tool call: the turn ends on the step limit, not a finish.
    let (session, mock) = makeSession(
      tools: [ThinkTool()],
      script: [
        [Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"hm"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("never"),
      ],
      hooks: [HookDefinition(event: .stop, command: #"echo '{"decision":"block","reason":"keep going"}'"#)],
      maxSteps: 1)
    var notices: [String] = []
    var kinds: [AgentEvent.Kind] = []
    for try await event in await session.send("go") {
      kinds.append(event.kind)
      if case .hookNotice("Stop", let output) = event { notices.append(output) }
    }
    XCTAssertEqual(mock.requests.count, 1, "a block on a step-limited turn cannot continue it")
    XCTAssertTrue(kinds.contains(.stepLimitReached))
    XCTAssertEqual(notices.count, 1)
    XCTAssertTrue(notices[0].contains("ended on max_steps"), notices[0])
    let record = await session.lastRecord
    XCTAssertNil(record?.hookContinuations)
  }

  func testStopHookThatCannotRunNeverForcesTheModelToContinueEvenFailClosed() async {
    let engine = HookEngine(hooks: [HookDefinition(event: .stop, command: "exit 1", failClosed: true)])
    let outcome = await engine.stop()
    XCTAssertEqual(outcome.decision, .none, "Stop is not a gate: a runner failure is an error, never a block")
    XCTAssertEqual(outcome.errors.count, 1)
  }

  // MARK: PostToolUseFailure

  func testPostToolUseFailureFiresOnAnErrorResultAndPostToolUseOnSuccessNeverBoth() async throws {
    let root = try tempRoot()
    try "hello".write(to: root.appendingPathComponent("present.txt"), atomically: true, encoding: .utf8)
    let payloadFile = tempFile("failure-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let (session, _) = makeSession(
      root: root, tools: [ReadFileTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "read_file", arguments: #"{"path":"missing.txt"}"#), Fixtures.usageChunk(cost: 0)],
        [Fixtures.toolCallChunk(id: "c2", name: "read_file", arguments: #"{"path":"present.txt"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [
        HookDefinition(event: .postToolUseFailure, matcher: "read_file", command: capture(to: payloadFile, then: "echo FAILED-HOOK")),
        HookDefinition(event: .postToolUse, matcher: "read_file", command: "echo SUCCESS-HOOK"),
      ])
    for try await _ in await session.send("read both") {}
    let history = await session.history
    let tools = history.filter { $0.role == .tool }.compactMap { $0.content?.plainText }
    XCTAssertEqual(tools.count, 2)
    XCTAssertTrue(tools[0].hasPrefix("error:"), tools[0])
    XCTAssertTrue(tools[0].hasSuffix("[hook]\nFAILED-HOOK"), tools[0])
    XCTAssertFalse(tools[0].contains("SUCCESS-HOOK"), "PostToolUse fires on success only")
    XCTAssertTrue(tools[1].hasSuffix("[hook]\nSUCCESS-HOOK"), tools[1])
    XCTAssertFalse(tools[1].contains("FAILED-HOOK"))
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.count, 1)
    XCTAssertEqual(payload[0].hookEventName, "PostToolUseFailure")
    XCTAssertEqual(payload[0].toolName, "read_file")
    XCTAssertTrue(payload[0].error?.hasPrefix("error:") == true, payload[0].error ?? "nil")
    XCTAssertNil(payload[0].toolResponse)
  }

  func testPostToolUseFailureNeverFiresForARefusal() async throws {
    let root = try tempRoot()
    let marker = tempFile("failure-marker")
    defer { try? FileManager.default.removeItem(at: marker) }
    let failureHook = HookDefinition(
      event: .postToolUseFailure, command: "echo fired >> '\(marker.path)'")
    let write = #"{"path":"a.txt","content":"x"}"#

    // Permission denial.
    var (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: write), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [failureHook], permissions: ScriptedPermissions([.deny(reason: "nope")]))
    for try await _ in await session.send("write") {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a permission denial is not a failure")

    // PreToolUse hook block.
    (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: write), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [failureHook, HookDefinition(event: .preToolUse, command: "exit 2")])
    for try await _ in await session.send("write") {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a hook block is not a failure")

    // Execute-time floor (a catastrophic command): refused, not failed.
    (session, _) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "bash", arguments: #"{"command":"rm -rf /"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [failureHook])
    for try await _ in await session.send("nuke") {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the floor is a refusal, not a failure")
  }

  // MARK: PermissionRequest

  private static func permissionRequestJSON(_ decision: String) -> String {
    #"echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":\#(decision)}}'"#
  }

  func testPermissionRequestAllowAnswersThePromptForOrdinaryMutationsOnly() async throws {
    // Ordinary in-tree write: the hook answers, the human is never asked.
    var root = try tempRoot()
    var perms = ScriptedPermissions([.deny(reason: "should not be asked")])
    var (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [HookDefinition(event: .permissionRequest, matcher: "write_file", command: Self.permissionRequestJSON(#"{"behavior":"allow"}"#))],
      permissions: perms)
    for try await _ in await session.send("write") {}
    XCTAssertEqual(perms.asks, [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    var record = await session.lastRecord
    var row = record?.decisions?.first
    XCTAssertEqual(row?.tool, "write_file")
    XCTAssertEqual(row?.decision, .allow)
    XCTAssertEqual(row?.source, .hook)

    // Destructive bash is .sensitive: the hook's allow does not lift the prompt.
    root = try tempRoot()
    perms = ScriptedPermissions([.deny(reason: "declined")])
    (session, _) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "bash", arguments: #"{"command":"rm -rf build"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [HookDefinition(event: .permissionRequest, command: Self.permissionRequestJSON(#"{"behavior":"allow"}"#))],
      permissions: perms)
    for try await _ in await session.send("clean") {}
    XCTAssertEqual(perms.asks, ["bash"], "a .sensitive call still reaches the human")
    record = await session.lastRecord
    row = record?.decisions?.first
    XCTAssertEqual(row?.decision, .deny)
    XCTAssertEqual(row?.source, .user)
  }

  func testPermissionRequestDenyRefusesBeforeTheDelegateAndIsAudited() async throws {
    let root = try tempRoot()
    let payloadFile = tempFile("permission-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let perms = ScriptedPermissions([.allow])
    let (session, mock) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [HookDefinition(
        event: .permissionRequest,
        command: capture(to: payloadFile, then: Self.permissionRequestJSON(#"{"behavior":"deny","message":"not on my watch"}"#)))],
      permissions: perms)
    var denied: String??
    for try await event in await session.send("write") {
      if case .toolDenied("write_file", let reason) = event { denied = reason }
    }
    XCTAssertEqual(denied, "blocked by hook: not on my watch")
    XCTAssertEqual(perms.asks, [], "the human was never asked")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    let toolMessage = mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertEqual(toolMessage, "blocked by hook: not on my watch")
    let record = await session.lastRecord
    let row = record?.decisions?.first
    XCTAssertEqual(row?.decision, .deny)
    XCTAssertEqual(row?.source, .hook)
    XCTAssertEqual(row?.reason, "not on my watch")
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.first?.hookEventName, "PermissionRequest")
    XCTAssertEqual(payload.first?.toolName, "write_file")
    XCTAssertEqual(payload.first?.permissionTier, "mutating")
    XCTAssertEqual(payload.first?.toolInput, .object(["path": .string("a.txt"), "content": .string("x")]))
  }

  func testPermissionRequestSkipsCallsTheDeterministicLayerAlreadyApproved() async throws {
    let root = try tempRoot()
    let marker = tempFile("permission-marker")
    defer { try? FileManager.default.removeItem(at: marker) }
    let (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: [
        [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#), Fixtures.usageChunk(cost: 0)],
        textTurn("done"),
      ],
      hooks: [HookDefinition(event: .permissionRequest, command: "echo fired >> '\(marker.path)'")],
      permissions: ScriptedPermissions([.deny(reason: "should not be asked")]),
      rules: PermissionRules(allow: ["write_file"]))
    for try await _ in await session.send("write") {}
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "no prompt, no PermissionRequest")
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
  }

  // MARK: Notification

  func testNotificationHookGetsTheTypeAndMessageAndMatchesOnType() async throws {
    let payloadFile = tempFile("notification-payload")
    defer { try? FileManager.default.removeItem(at: payloadFile) }
    let engine = HookEngine(hooks: [
      HookDefinition(event: .notification, matcher: "permission_prompt", command: capture(to: payloadFile)),
      HookDefinition(event: .notification, matcher: "idle", command: "echo SHOULD_NOT_RUN >> '\(payloadFile.path)'"),
    ])
    let outcome = await engine.notification(type: "permission_prompt", message: "bash rm -rf build")
    XCTAssertEqual(outcome.errors, [])
    let payload = try payloads(in: payloadFile)
    XCTAssertEqual(payload.count, 1)
    XCTAssertEqual(payload[0].hookEventName, "Notification")
    XCTAssertEqual(payload[0].notificationType, "permission_prompt")
    XCTAssertEqual(payload[0].message, "bash rm -rf build")
  }

  // MARK: Matcher subjects, parsing, inheritance

  func testSessionEventsMatchOnTheirOwnSubjects() async {
    func ran(_ event: HookEvent, matcher: String, subject: String) async -> Bool {
      let engine = HookEngine(hooks: [HookDefinition(event: event, matcher: matcher, command: "echo ran")])
      let outcome: HookOutcome
      switch event {
      case .sessionStart: outcome = await engine.sessionStart(source: subject)
      case .sessionEnd: outcome = await engine.sessionEnd(reason: subject)
      case .preCompact: outcome = await engine.preCompact(trigger: subject)
      case .postCompact: outcome = await engine.postCompact(trigger: subject)
      case .notification: outcome = await engine.notification(type: subject, message: "m")
      default: return false
      }
      return !outcome.feedback.isEmpty || !outcome.context.isEmpty
    }
    let cases: [(HookEvent, String, String, Bool)] = [
      (.sessionStart, "startup|resume", "resume", true),
      (.sessionStart, "startup", "compact", false),
      (.sessionEnd, "exit", "exit", true),
      (.sessionEnd, "exit", "clear", false),
      (.preCompact, "manual", "manual", true),
      (.preCompact, "manual", "auto", false),
      (.postCompact, "*", "auto", true),
      (.notification, "permission_prompt", "permission_prompt", true),
      (.notification, "permission_prompt", "idle", false),
    ]
    for (event, matcher, subject, expected) in cases {
      let did = await ran(event, matcher: matcher, subject: subject)
      XCTAssertEqual(did, expected, "\(event.rawValue) matcher \(matcher) vs \(subject)")
    }
    // Listings name the subject; Stop and UserPromptSubmit have none.
    XCTAssertEqual(HookEvent.sessionStart.matcherSubject, "source")
    XCTAssertEqual(HookEvent.sessionEnd.matcherSubject, "reason")
    XCTAssertEqual(HookEvent.preCompact.matcherSubject, "trigger")
    XCTAssertEqual(HookEvent.notification.matcherSubject, "type")
    XCTAssertEqual(HookEvent.permissionRequest.matcherSubject, "tool")
    XCTAssertNil(HookEvent.stop.matcherSubject)
    XCTAssertNil(HookEvent.userPromptSubmit.matcherSubject)
  }

  func testWhenFiltersSeeTheSessionEventsScalarsAndStillSitOutStop() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .sessionStart, when: ["source": "^resume$"], command: "echo on-resume"),
      HookDefinition(event: .postToolUseFailure, when: ["error": "timed out"], command: "echo on-timeout"),
      HookDefinition(event: .stop, when: ["anything": ".*"], command: "echo never"),
    ])
    let resume = await engine.sessionStart(source: "resume")
    XCTAssertEqual(resume.context, ["on-resume"])
    let startup = await engine.sessionStart(source: "startup")
    XCTAssertEqual(startup.context, [])
    let timeout = await engine.postToolUseFailure(
      tool: "bash", argumentsJSON: #"{"command":"sleep 99"}"#, error: "error: command timed out after 1s")
    XCTAssertEqual(timeout.feedback, "on-timeout")
    let other = await engine.postToolUseFailure(tool: "bash", argumentsJSON: "{}", error: "error: unknown")
    XCTAssertEqual(other.feedback, "")
    let stop = await engine.stop()
    XCTAssertEqual(stop, .none, "an event with no arguments never satisfies `when`")
  }

  func testParseSemanticsForTheNewEvents() {
    // Stop: exit 2 and `decision: block` are "don't stop yet"; plain output is for the user.
    XCTAssertEqual(HookOutcome.parse(exit: 2, output: "tests failing", event: .stop).decision, .deny(reason: "tests failing"))
    XCTAssertEqual(
      HookOutcome.parse(exit: 0, output: #"{"decision":"block","reason":"lint first"}"#, event: .stop).decision,
      .deny(reason: "lint first"))
    let silentStop = HookOutcome.parse(exit: 2, output: "", event: .stop)
    XCTAssertTrue(silentStop.blockReason?.contains("continue") == true, silentStop.blockReason ?? "nil")
    let plainStop = HookOutcome.parse(exit: 0, output: "all green\n", event: .stop)
    XCTAssertEqual(plainStop.decision, .none)
    XCTAssertEqual(plainStop.feedback, "all green")

    // UserPromptSubmit / SessionStart / PreCompact: plain stdout is context, not feedback.
    for event in [HookEvent.userPromptSubmit, .sessionStart, .preCompact] {
      let outcome = HookOutcome.parse(exit: 0, output: "some context\n", event: event)
      XCTAssertEqual(outcome.context, ["some context"], "\(event)")
      XCTAssertEqual(outcome.feedback, "", "\(event)")
      XCTAssertEqual(outcome.decision, .none, "\(event)")
    }
    XCTAssertEqual(
      HookOutcome.parse(exit: 0, output: #"{"decision":"block","reason":"no"}"#, event: .userPromptSubmit).decision,
      .deny(reason: "no"))
    XCTAssertEqual(HookOutcome.parse(exit: 2, output: "no", event: .preCompact).decision, .deny(reason: "no"))
    // SessionStart cannot block: exit 2 is just output.
    let startTwo = HookOutcome.parse(exit: 2, output: "hmm", event: .sessionStart)
    XCTAssertEqual(startTwo.decision, .none)
    XCTAssertEqual(startTwo.feedback, "hmm")

    // PermissionRequest: Claude Code's `decision.behavior`, with the PreToolUse spelling accepted.
    let allow = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}
      """, event: .permissionRequest)
    XCTAssertEqual(allow.decision, .allow)
    let deny = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny","message":"policy"}}}
      """, event: .permissionRequest)
    XCTAssertEqual(deny.decision, .deny(reason: "policy"))
    let legacy = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"old spelling"}}
      """, event: .permissionRequest)
    XCTAssertEqual(legacy.decision, .deny(reason: "old spelling"))

    // After-the-fact events feed back on exit 2.
    XCTAssertEqual(HookOutcome.parse(exit: 2, output: "retry", event: .postToolUseFailure).feedback, "retry")
    XCTAssertEqual(HookOutcome.parse(exit: 2, output: "late", event: .sessionEnd).decision, .none)
    XCTAssertEqual(HookOutcome.parse(exit: 0, output: "ignored", event: .notification).feedback, "ignored")
  }

  func testForSubagentDropsTheSessionEventsAndKeepsTheCallAndCompactionEvents() {
    let configuration = Session.Configuration(hooks: HookEvent.allCases.map {
      HookDefinition(event: $0, command: "x")
    })
    let nested = configuration.forSubagent(named: "helper", model: "m", systemSuffix: "role")
    XCTAssertEqual(
      Set(nested.hooks.map(\.event)),
      [.preToolUse, .postToolUse, .postToolUseFailure, .permissionRequest, .preCompact, .postCompact])
  }

  func testRunRecordWithoutHookContinuationsStillDecodesAndNewOnesRoundTrip() throws {
    let old = """
      {"id":"r1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic",\
      "steps":1,"toolCalls":0,"costUSD":0,"finished":true,"stopReason":"completed"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(RunRecord.self, from: Data(old.utf8))
    XCTAssertNil(record.hookContinuations)
    var fresh = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    fresh.hookContinuations = 2
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let again = try decoder.decode(RunRecord.self, from: encoder.encode(fresh))
    XCTAssertEqual(again.hookContinuations, 2)
  }

  func testPlanModeNaturalFinishRecordsPlanProposed() async throws {
    var (session, _) = makeSession(script: [textTurn("here is the plan")], hooks: [], mode: .plan)
    for try await _ in await session.send("plan it") {}
    var record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .planProposed)
    XCTAssertEqual(record?.finished, true)
    (session, _) = makeSession(script: [textTurn("done")], hooks: [])
    for try await _ in await session.send("do it") {}
    record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
  }

  // MARK: Headless

  func testAgentRunStartsAndEndsTheSessionAndSurfacesABlockedPrompt() async throws {
    let endMarker = tempFile("agent-end")
    defer { try? FileManager.default.removeItem(at: endMarker) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [textTurn("done")]
    let hooks = [
      HookDefinition(event: .sessionStart, matcher: "startup", command: "echo HEADLESS-CTX"),
      HookDefinition(event: .sessionEnd, matcher: "exit", command: "echo ended >> '\(endMarker.path)'"),
      HookDefinition(event: .userPromptSubmit, when: ["prompt": "^forbidden"], command: "echo denied-prompt >&2; exit 2"),
    ]
    let agent = Agent(
      service: mock, tools: [], store: store(),
      configuration: Session.Configuration(model: "test/model", hooks: hooks))
    let result = try await agent.run(task: "hello", model: "test/model")
    XCTAssertEqual(result.text, "done")
    XCTAssertTrue(systemPrompt(mock.requests[0]).contains("HEADLESS-CTX"), "SessionStart ran before the turn")
    XCTAssertEqual(try String(contentsOf: endMarker, encoding: .utf8), "ended\n", "SessionEnd ran after it")

    var kinds: [AgentEvent.Kind] = []
    let blocked = try await agent.run(task: "forbidden request", model: "test/model") { kinds.append($0.kind) }
    XCTAssertEqual(blocked.text, "")
    XCTAssertEqual(blocked.record.stopReason, .hookStopped)
    XCTAssertTrue(kinds.contains(.promptBlocked))
    XCTAssertEqual(mock.requests.count, 1, "the blocked run sent nothing")
  }

  func testAgentRunEndsTheSessionWithOtherWhenTheRunThrows() async throws {
    let endFile = tempFile("agent-end-thrown")
    defer { try? FileManager.default.removeItem(at: endFile) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [] // the first request fails: nothing scripted
    let agent = Agent(
      service: mock, tools: [], store: store(),
      configuration: Session.Configuration(
        model: "test/model",
        hooks: [HookDefinition(event: .sessionEnd, command: capture(to: endFile))]))
    do {
      _ = try await agent.run(task: "hello", model: "test/model")
      XCTFail("the run should have thrown")
    } catch {}
    let payload = try payloads(in: endFile)
    XCTAssertEqual(payload.map(\.hookEventName), ["SessionEnd"], "a notify-on-end hook sees a failed run too")
    XCTAssertEqual(payload.first?.reason, "other")
  }
}
