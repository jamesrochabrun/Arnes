import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Helpers

private final class BackgroundEventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AgentEvent] = []
  func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
  var events: [AgentEvent] { lock.withLock { stored } }
}

/// A sequential read-only tool that returns only once `latch` has been arrived at — how a test
/// holds a step open until a background run has finished, so the *next* step boundary is the
/// first one that can deliver it.
private final class WaitingTool: AgentTool, @unchecked Sendable {
  let name = "wait_for"
  let description = "test wait"
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  let permission = ToolPermission.readOnly
  private let latch: Latch

  init(latch: Latch) { self.latch = latch }

  func execute(arguments: [String: JSONValue]) async throws -> String {
    await latch.wait(for: 1)
    return "waited"
  }
}

// MARK: - BackgroundSubagentsTests

/// A4: `task` with `background: true` returns at once; the report is delivered into history at
/// a later step boundary as a tool exchange, a turn joins pending work before it ends (unless
/// the embedder opted out), and an interrupt cancels it. Cost is counted exactly once.
final class BackgroundSubagentsTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-background-runs-\(UUID().uuidString).jsonl"))
  }

  private func manifest() -> String {
    Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
  }

  private func helper(background: Bool = false) -> AgentDefinition {
    AgentDefinition(
      name: "helper", description: "helps", body: "Help.", model: "sub/model", background: background)
  }

  /// One lead step issuing `calls` in order.
  private func step(_ calls: [(id: String, tool: String, arguments: String)], cost: Double = 0)
    -> [ChatCompletionChunk]
  {
    var chunks = calls.enumerated().map { index, call in
      Fixtures.toolCallChunk(
        id: call.id, name: call.tool, arguments: call.arguments, index: index, model: "lead/model")
    }
    chunks.append(Fixtures.usageChunk(cost: cost, model: "lead/model"))
    return chunks
  }

  private func backgroundDelegation(id: String) -> (id: String, tool: String, arguments: String) {
    (id, "task", #"{"agent":"helper","task":"do the long thing","background":true}"#)
  }

  private func reply(_ text: String, cost: Double = 0) -> [ChatCompletionChunk] {
    [Fixtures.textChunk(text, model: "lead/model"), Fixtures.usageChunk(cost: cost, model: "lead/model")]
  }

  private func report(_ text: String, cost: Double = 0) -> [ChatCompletionChunk] {
    [Fixtures.textChunk(text, model: "sub/model"), Fixtures.usageChunk(cost: cost, model: "sub/model")]
  }

  private func lead(
    mock: MockOpenRouterService,
    tools: [any AgentTool] = [],
    defaults: TaskTool.Defaults = TaskTool.Defaults(),
    joinAtTurnEnd: Bool = true,
    hooks: [HookDefinition] = [],
    maxStepsPerTurn: Int = 30,
    maxCostUSD: Double? = nil,
    store: RunRecordStore? = nil,
    toolResultMaxChars: Int = ToolOutputLimiter.defaultMaxChars)
    -> (session: Session, task: TaskTool, store: RunRecordStore)
  {
    let store = store ?? tempStore()
    let configuration = Session.Configuration(
      model: "lead/model", maxStepsPerTurn: maxStepsPerTurn, maxCostUSD: maxCostUSD, hooks: hooks,
      joinBackgroundAtTurnEnd: joinAtTurnEnd, toolResultMaxChars: toolResultMaxChars)
    let taskTool = TaskTool(
      agents: [helper()], service: mock, tools: tools, store: store, defaults: defaults,
      configuration: configuration)
    let session = Session(
      service: mock, tools: tools + [taskTool], store: store, configuration: configuration)
    taskTool.parentModel = { await session.model }
    return (session, taskTool, store)
  }
  private func kinds(_ events: [AgentEvent]) -> [AgentEvent.Kind] { events.map(\.kind) }

  /// The lead's requests only (nested ones ask for `sub/model`).
  private func leadRequests(_ mock: MockOpenRouterService) -> [ChatCompletionRequest] {
    mock.requests.filter { $0.model == "lead/model" }
  }

  /// `(assistant tool-call ids, tool-result ids)` of a request's history — a valid history has
  /// every call answered.
  private func toolPairs(in request: ChatCompletionRequest) -> (calls: [String], results: [String]) {
    var calls: [String] = []
    var results: [String] = []
    for message in request.messages {
      if message.role == .assistant, let toolCalls = message.toolCalls {
        calls += toolCalls.compactMap(\.id)
      }
      if message.role == .tool, let id = message.toolCallId {
        results.append(id)
      }
    }
    return (calls, results)
  }

  // MARK: The tool call returns at once

  func testBackgroundExecuteReturnsBeforeTheNestedRunFinishes() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("late report", cost: 0.02)]
    // The nested stream is held until the test releases it — so a result in hand before the
    // release is proof the call didn't wait for the run.
    let release = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await release.wait(for: 1)
    }
    let tool = TaskTool(agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore())
    tool.parentModel = { "lead/model" }
    let collector = BackgroundEventCollector()
    tool.onEvent = { collector.append($0) }

    let result = try await withDeadline(seconds: 5) {
      try await tool.execute(arguments: [
        "agent": .string("helper"), "task": .string("long thing"), "background": .bool(true),
      ])
    }
    let text = try XCTUnwrap(result, "a background call must not wait for the nested run")
    XCTAssertTrue(text.hasPrefix("started background subagent 'helper' (id "), text)
    XCTAssertTrue(text.contains("Its report will arrive as a message when it finishes"), text)
    XCTAssertEqual(tool.pendingBackgroundCount(), 1)
    XCTAssertEqual(tool.backgroundSnapshot().map(\.finished), [false])

    // Backgrounded, not started: the ◇ line says so, and there is no finish yet.
    let seen = collector.events
    guard case .subagentBackgrounded(let name, let id, let model) = try XCTUnwrap(seen.first) else {
      return XCTFail("expected subagentBackgrounded first, got \(String(describing: seen.first))")
    }
    XCTAssertEqual(name, "helper")
    XCTAssertEqual(model, "sub/model")
    XCTAssertEqual(id.count, 8)
    XCTAssertTrue(text.contains("(id \(id))"), "the result names the run the events name")
    XCTAssertFalse(kinds(seen).contains(.subagentStarted))
    XCTAssertFalse(kinds(seen).contains(.subagentFinished))
    // Nothing accrued through the foreground channel: the outcome carries the cost instead.
    XCTAssertEqual(tool.drainAccruedCost(), 0)

    await release.arrive()
    let awaited = await tool.awaitAnyBackground()
    let outcome = try XCTUnwrap(awaited)
    XCTAssertEqual(outcome.id, id)
    XCTAssertEqual(outcome.agent, "helper")
    XCTAssertEqual(outcome.report, "late report")
    XCTAssertEqual(outcome.costUSD, 0.02, accuracy: 0.0001)
    XCTAssertFalse(outcome.partial)
    XCTAssertEqual(tool.pendingBackgroundCount(), 0)
    XCTAssertEqual(tool.drainAccruedCost(), 0, "a delivered outcome never also accrues")
    let nothing = await tool.awaitAnyBackground()
    XCTAssertNil(nothing, "nothing pending → nil, not a hang")
  }

  // MARK: Step-boundary delivery

  func testFinishedReportIsDeliveredAtTheNextStepBoundaryAsAToolExchange() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    // Step 1: spawn in the background, then a sequential tool that holds the step open until
    // the run has finished. Step 2 is therefore the first boundary that can deliver it.
    let finished = Latch()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([backgroundDelegation(id: "c1"), ("c2", "wait_for", "{}")], cost: 0.01),
        reply("read the report, done", cost: 0.005),
      ],
      "sub/model": [report("bg report: all clear", cost: 0.02)],
    ]
    let harness = lead(mock: mock, tools: [WaitingTool(latch: finished)])
    harness.task.onBackgroundFinished = { _ in Task { await finished.arrive() } }

    let raced = try await withDeadline(seconds: 5) {
      try await Events.drain(await harness.session.send("go"))
    }
    let events = try XCTUnwrap(raced)

    // Delivered before the step-2 request: the lead's second request carries the exchange.
    let requests = leadRequests(mock)
    XCTAssertEqual(requests.count, 2, "no join step was needed — the report was already in")
    let second = requests[1]
    let pairs = toolPairs(in: second)
    XCTAssertEqual(pairs.results.count, pairs.calls.count, "every call answered: \(pairs)")
    let bgCallId = try XCTUnwrap(pairs.calls.first { $0.hasPrefix("bg-") }, "synthetic call present: \(pairs.calls)")
    XCTAssertTrue(pairs.results.contains(bgCallId))
    let syntheticCall = try XCTUnwrap(second.messages.first { message in
      message.role == .assistant && (message.toolCalls ?? []).contains { $0.id == bgCallId }
    })
    XCTAssertNil(syntheticCall.content?.plainText.nilIfEmpty, "the synthetic call carries no prose")
    XCTAssertEqual(syntheticCall.toolCalls?.first?.function?.name, "task")
    XCTAssertEqual(
      syntheticCall.toolCalls?.first?.function?.arguments,
      #"{"agent":"helper","task":"(background result)"}"#)
    let deliveredResult = try XCTUnwrap(second.messages.first { $0.role == .tool && $0.toolCallId == bgCallId })
    let deliveredText = deliveredResult.content?.plainText ?? ""
    let runId = String(bgCallId.dropFirst("bg-".count))
    XCTAssertTrue(deliveredText.hasPrefix("[background subagent 'helper' (\(runId)) finished]\n\n"), deliveredText)
    XCTAssertTrue(deliveredText.hasSuffix("bg report: all clear"), deliveredText)
    // The original call was answered with the "started" text, in the tool channel.
    let started = try XCTUnwrap(second.messages.first { $0.role == .tool && $0.toolCallId == "c1" })
    XCTAssertTrue((started.content?.plainText ?? "").hasPrefix("started background subagent 'helper'"))
    // Never a user-role message: the principal's channel stays the principal's.
    let userMessages = second.messages.filter { $0.role == .user }
    XCTAssertEqual(userMessages.count, 1, "only the real prompt is a user message")

    // Events: the finish fires at delivery, after step 1's results and before step 2's text,
    // and no join was needed.
    let sequence = kinds(events)
    XCTAssertFalse(sequence.contains(.subagentJoining))
    XCTAssertTrue(sequence.contains(.subagentBackgrounded))
    let finishedAt = try XCTUnwrap(sequence.firstIndex(of: .subagentFinished))
    let lastToolResult = try XCTUnwrap(sequence.lastIndex(of: .toolResult))
    let finalText = try XCTUnwrap(sequence.lastIndex(of: .assistantText))
    XCTAssertGreaterThan(finishedAt, lastToolResult)
    XCTAssertLessThan(finishedAt, finalText)
    guard case .subagentFinished(let name, let id, _, _, let cost, let preview) = events[finishedAt] else {
      return XCTFail("not a subagentFinished")
    }
    XCTAssertEqual(name, "helper")
    XCTAssertEqual(id, runId)
    XCTAssertEqual(cost, 0.02, accuracy: 0.0001)
    XCTAssertTrue(preview.hasPrefix("bg report"))

    // Cost: lead 0.01 + 0.005, subagent 0.02 — once.
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.steps, 2)
    XCTAssertEqual(record.costUSD, 0.035, accuracy: 0.0001)
    XCTAssertEqual(record.toolCalls, 2, "the synthetic call is not a model call")
    XCTAssertEqual(harness.task.drainAccruedCost(), 0)
    XCTAssertEqual(harness.task.pendingBackgroundCount(), 0)
  }

  // MARK: Turn-end join

  func testTurnJoinsPendingBackgroundWorkBeforeEnding() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([backgroundDelegation(id: "c1")], cost: 0.01),
        reply("done for now", cost: 0.005),
        reply("folded the report in", cost: 0.002),
      ],
      "sub/model": [report("bg report", cost: 0.02)],
    ]
    // The nested run can't finish until the lead has started waiting for it — so the join
    // path, not the step-boundary drain, is what delivers.
    let joining = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await joining.wait(for: 1)
    }
    let harness = lead(mock: mock)

    let raced = try await withDeadline(seconds: 5) { () -> [AgentEvent] in
      var collected: [AgentEvent] = []
      for try await event in await harness.session.send("go") {
        collected.append(event)
        if case .subagentJoining = event { await joining.arrive() }
      }
      return collected
    }
    let events = try XCTUnwrap(raced)

    let sequence = kinds(events)
    let joinAt = try XCTUnwrap(sequence.firstIndex(of: .subagentJoining))
    guard case .subagentJoining(let pending) = events[joinAt] else { return XCTFail("not a join") }
    XCTAssertEqual(pending, 1)
    let finishedAt = try XCTUnwrap(sequence.firstIndex(of: .subagentFinished))
    XCTAssertGreaterThan(finishedAt, joinAt)
    // The reply that triggered the join was kept, then the model took one more step.
    let texts = events.compactMap { event -> String? in
      if case .assistantText(let text) = event { return text }
      return nil
    }
    XCTAssertEqual(texts, ["done for now", "folded the report in"])
    // The kept reply and the synthetic call share one assistant message — "says X and calls a
    // tool" — so roles keep alternating; never two assistant messages back to back.
    let history = await harness.session.history
    let roles = history.map(\.role)
    XCTAssertEqual(roles, [.user, .assistant, .tool, .assistant, .tool, .assistant], "\(roles)")
    XCTAssertEqual(history[3].content?.plainText, "done for now")
    XCTAssertEqual(history[3].toolCalls?.first?.id?.hasPrefix("bg-"), true)
    XCTAssertTrue((history[4].content?.plainText ?? "").hasSuffix("bg report"))

    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.stopReason, .completed)
    XCTAssertEqual(record.steps, 3, "the join costs a step, not a nudge")
    XCTAssertFalse(sequence.contains(.nudged))
    XCTAssertEqual(record.costUSD, 0.037, accuracy: 0.0001, "lead 0.017 + subagent 0.02, once")
    let stats = try XCTUnwrap(events.compactMap { event -> Session.TurnStats? in
      if case .turnFinished(let stats) = event { return stats }
      return nil
    }.last)
    XCTAssertEqual(stats.turnCostUSD, 0.037, accuracy: 0.0001)
    XCTAssertEqual(harness.task.drainAccruedCost(), 0)
    XCTAssertEqual(harness.task.pendingBackgroundCount(), 0)
  }

  /// A delivered background report is a tool result like any other: the session's output cap
  /// applies to it, so a background explorer's dump can't flood the context the way a
  /// foreground one can't.
  func testDeliveredBackgroundReportIsCappedLikeAnyToolResult() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let huge = String(repeating: "x", count: 5_000) + "TAIL-MARKER"
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([backgroundDelegation(id: "c1")]),
        reply("done for now"),
        reply("folded it in"),
      ],
      "sub/model": [report(huge)],
    ]
    let joining = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await joining.wait(for: 1)
    }
    let harness = lead(mock: mock, toolResultMaxChars: 1_000)
    let raced = try await withDeadline(seconds: 5) { () -> [AgentEvent] in
      var collected: [AgentEvent] = []
      for try await event in await harness.session.send("go") {
        collected.append(event)
        if case .subagentJoining = event { await joining.arrive() }
      }
      return collected
    }
    _ = try XCTUnwrap(raced)
    let history = await harness.session.history
    let delivered = try XCTUnwrap(history.first { $0.role == .tool && ($0.toolCallId ?? "").hasPrefix("bg-") })
    let text = delivered.content?.plainText ?? ""
    XCTAssertLessThan(text.count, 1_400, "capped near the limit plus the header and pointer")
    XCTAssertTrue(text.hasPrefix("[background subagent 'helper'"), "the header survives")
    XCTAssertTrue(text.contains("chars omitted"), "the pointer says what was cut: \(text.suffix(200))")
    XCTAssertTrue(text.hasSuffix("TAIL-MARKER"), "the tail survives the cut")
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.truncatedResults, 1)
  }

  // MARK: joinBackgroundAtTurnEnd: false (the REPL's mode)

  func testWithoutJoinTheReportLandsAtTheNextSendAndItsCostInThatRecord() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([backgroundDelegation(id: "c1")], cost: 0.01),
        reply("started it, back to you", cost: 0.005),
        reply("got the report", cost: 0.002),
      ],
      "sub/model": [report("bg report", cost: 0.02)],
    ]
    let release = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await release.wait(for: 1)
    }
    let harness = lead(mock: mock, joinAtTurnEnd: false)
    let finished = Latch()
    harness.task.onBackgroundFinished = { _ in Task { await finished.arrive() } }

    // Turn 1 ends with the run still out.
    let racedFirst = try await withDeadline(seconds: 5) {
      try await Events.drain(await harness.session.send("go"))
    }
    let first = try XCTUnwrap(racedFirst)
    XCTAssertFalse(kinds(first).contains(.subagentJoining))
    XCTAssertFalse(kinds(first).contains(.subagentFinished))
    let lastRecord1 = await harness.session.lastRecord
    let record1 = try XCTUnwrap(lastRecord1)
    XCTAssertTrue(record1.finished)
    XCTAssertEqual(record1.steps, 2)
    XCTAssertEqual(record1.costUSD, 0.015, accuracy: 0.0001, "the lead's spend only")
    XCTAssertEqual(harness.task.pendingBackgroundCount(), 1)
    let pendingAfterTurn1 = await harness.session.backgroundWorkPending
    XCTAssertEqual(pendingAfterTurn1, 1)

    // A manual compaction is refused while the report is out.
    do {
      _ = try await harness.session.compact()
      XCTFail("compact must refuse with background work pending")
    } catch SessionError.backgroundWorkPending(let count) {
      XCTAssertEqual(count, 1)
    }

    // The run finishes at the prompt: the tool tells whoever listens, the queue holds it.
    await release.arrive()
    let arrived = try await withDeadline(seconds: 5) { await finished.wait(for: 1); return true }
    XCTAssertEqual(arrived, true)
    XCTAssertEqual(harness.task.backgroundSnapshot().map(\.finished), [true])

    // Turn 2 delivers it first; that turn's record carries the cost.
    let racedSecond = try await withDeadline(seconds: 5) {
      try await Events.drain(await harness.session.send("anything new?"))
    }
    let second = try XCTUnwrap(racedSecond)
    let sequence = kinds(second)
    let finishedAt = try XCTUnwrap(sequence.firstIndex(of: .subagentFinished))
    let textAt = try XCTUnwrap(sequence.firstIndex(of: .assistantText))
    XCTAssertLessThan(finishedAt, textAt, "delivered before the model's reply")
    let request = try XCTUnwrap(leadRequests(mock).last)
    let pairs = toolPairs(in: request)
    XCTAssertEqual(pairs.results.count, pairs.calls.count)
    XCTAssertTrue(pairs.calls.contains { $0.hasPrefix("bg-") })
    // …and after the user's new message, so the history reads user → exchange → reply.
    let roles = request.messages.map(\.role)
    XCTAssertEqual(
      roles, [.system, .user, .assistant, .tool, .assistant, .user, .assistant, .tool], "\(roles)")
    let lastRecord2 = await harness.session.lastRecord
    let record2 = try XCTUnwrap(lastRecord2)
    XCTAssertEqual(record2.costUSD, 0.022, accuracy: 0.0001, "turn 2: lead 0.002 + subagent 0.02")
    let total = await harness.session.costUSD
    XCTAssertEqual(total, 0.037, accuracy: 0.0001, "session total counts the subagent once")
    XCTAssertEqual(harness.task.pendingBackgroundCount(), 0)
    let pendingAfterTurn2 = await harness.session.backgroundWorkPending
    XCTAssertEqual(pendingAfterTurn2, 0)
    // With nothing pending the compaction guard lifts and the summarizer runs.
    mock.chatResponses = [Fixtures.textResponse("summary of the earlier turn")]
    let compacted = try await harness.session.compact()
    XCTAssertGreaterThan(compacted.summarizedMessages, 0)
  }

  // MARK: Interrupt

  func testInterruptCancelsPendingBackgroundRunsAndLeavesNoDanglingCalls() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([backgroundDelegation(id: "c1")]),
        reply("waiting"),
      ],
      "sub/model": [report("never delivered", cost: 0.02)],
    ]
    // The nested run never gets its answer; the lead is interrupted once the nested run has
    // reached the mock (so the nested turn exists and will record its own interruption — a cancel
    // that landed before the run passed the limiter would just be "cancelled before it started").
    let held = Latch()
    let arrived = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await arrived.arrive()
      await held.wait(for: 99)
    }
    let harness = lead(mock: mock)

    let raced = try await withDeadline(seconds: 5) { () -> [AgentEvent] in
      var collected: [AgentEvent] = []
      for try await event in await harness.session.send("go") {
        collected.append(event)
        if case .subagentBackgrounded = event {
          await arrived.wait(for: 1)
          await harness.session.interrupt()
        }
      }
      return collected
    }
    let events = try XCTUnwrap(raced, "an interrupted turn with background work must still finish its stream")
    XCTAssertTrue(kinds(events).contains(.interrupted))
    // The cancelled run closes its own ◇ line — as cancelled, with the nested turn's real
    // figures — inside the lead's stream, before the turn reports.
    let finished = events.compactMap { event -> (name: String, preview: String)? in
      if case .subagentFinished(let name, _, _, _, _, let preview) = event { return (name, preview) }
      return nil
    }
    XCTAssertEqual(finished.count, 1)
    XCTAssertEqual(finished.first?.name, "helper")
    XCTAssertEqual(finished.first?.preview, "cancelled")
    XCTAssertEqual(harness.task.pendingBackgroundCount(), 0, "cancelled runs are gone")
    XCTAssertEqual(harness.task.backgroundSnapshot(), [])

    let history = await harness.session.history
    var calls: [String] = []
    var results: [String] = []
    for message in history {
      if message.role == .assistant { calls += (message.toolCalls ?? []).compactMap(\.id) }
      if message.role == .tool, let id = message.toolCallId { results.append(id) }
    }
    XCTAssertEqual(Set(calls), Set(results), "no dangling tool call: \(calls) vs \(results)")
    XCTAssertFalse(calls.contains { $0.hasPrefix("bg-") }, "a cancelled run delivers nothing")
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.stopReason, .interrupted)
    // The nested session recorded its own interrupted turn — the run was cancelled, not orphaned.
    // Deterministic: the task tool interrupts the nested session and reads its stream to the end,
    // so the lead's cancel returns only after the nested record is on disk.
    let nested = try harness.store.all().filter { $0.agent == "helper" }
    XCTAssertEqual(nested.count, 1)
    XCTAssertEqual(nested.first?.stopReason, .interrupted)
    for _ in 0..<99 { await held.arrive() }
  }

  // MARK: Turn ends some other way with work still out

  func testStepLimitWithBackgroundWorkPendingJoinsItBeforeTheTurnReports() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    // One step: it spawns the run, and the loop is over. The nested run can't finish until the
    // lead has started waiting — so the after-loop join is what delivers, not a step boundary.
    mock.chunkScriptsByModel = [
      "lead/model": [step([backgroundDelegation(id: "c1")], cost: 0.01)],
      "sub/model": [report("late but delivered", cost: 0.02)],
    ]
    let joining = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await joining.wait(for: 1)
    }
    let harness = lead(mock: mock, maxStepsPerTurn: 1)

    let raced = try await withDeadline(seconds: 5) { () -> [AgentEvent] in
      var collected: [AgentEvent] = []
      for try await event in await harness.session.send("go") {
        collected.append(event)
        if case .subagentJoining = event { await joining.arrive() }
      }
      return collected
    }
    let events = try XCTUnwrap(raced, "a step-limited turn must still settle its background work")

    let sequence = kinds(events)
    let limitAt = try XCTUnwrap(sequence.firstIndex(of: .stepLimitReached))
    let joinAt = try XCTUnwrap(sequence.firstIndex(of: .subagentJoining))
    let finishedAt = try XCTUnwrap(sequence.firstIndex(of: .subagentFinished))
    XCTAssertLessThan(limitAt, joinAt)
    XCTAssertLessThan(joinAt, finishedAt)
    XCTAssertLessThan(finishedAt, try XCTUnwrap(sequence.firstIndex(of: .turnFinished)))
    guard case .subagentFinished(_, _, _, _, let cost, let preview) = events[finishedAt] else {
      return XCTFail("not a subagentFinished")
    }
    XCTAssertEqual(cost, 0.02, accuracy: 0.0001)
    XCTAssertTrue(preview.hasPrefix("late but delivered"), "delivered, not cancelled: \(preview)")

    // Nothing left running; the report is in history for the next turn; the spend is in this
    // record; the nested run recorded a normal finish.
    XCTAssertEqual(harness.task.pendingBackgroundCount(), 0)
    let history = await harness.session.history
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool, .assistant, .tool], "\(history.map(\.role))")
    XCTAssertEqual(history[3].toolCalls?.first?.id?.hasPrefix("bg-"), true)
    XCTAssertNil(history[3].content, "no reply to fold in after a step-limit end")
    XCTAssertTrue((history[4].content?.plainText ?? "").hasSuffix("late but delivered"))
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.stopReason, .maxSteps)
    XCTAssertFalse(record.finished)
    XCTAssertEqual(record.costUSD, 0.03, accuracy: 0.0001, "lead 0.01 + the joined subagent's 0.02")
    let nested = try harness.store.all().filter { $0.agent == "helper" }
    XCTAssertEqual(nested.map(\.stopReason), [.completed])
    XCTAssertEqual(harness.task.drainAccruedCost(), 0, "delivered, so never accrued")
  }

  func testBudgetEndWithBackgroundWorkPendingCancelsItAndCountsItsSpend() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    // Lead step 1 spends past the budget while spawning the run, and holds (a sequential tool
    // waiting on a latch) until the nested run has taken one real step (0.02) and is parked on
    // its second request; the top of lead step 2 then stops the turn on budget. Cancelling the
    // run strands spend the lead's books must still see.
    mock.chunkScriptsByModel = [
      "lead/model": [step([backgroundDelegation(id: "c1"), ("c2", "wait_for", "{}")], cost: 0.01)],
      "sub/model": [
        [
          Fixtures.toolCallChunk(id: "n1", name: "think", arguments: #"{"thought":"hm"}"#, model: "sub/model"),
          Fixtures.usageChunk(cost: 0.02, model: "sub/model"),
        ],
        report("never sent"),
      ],
    ]
    let held = Latch()
    let nestedRequests = Latch()
    let leadRelease = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await nestedRequests.arrive()
      // The first nested request streams; the second lets the lead go on and is held open.
      if await nestedRequests.count >= 2 {
        await leadRelease.arrive()
        await held.wait(for: 99)
      }
    }
    let harness = lead(
      mock: mock, tools: [ThinkTool(), WaitingTool(latch: leadRelease)], maxCostUSD: 0.005)

    let raced = try await withDeadline(seconds: 5) {
      try await Events.drain(await harness.session.send("go"))
    }
    let events = try XCTUnwrap(raced, "a budget-stopped turn must still settle its background work")
    let sequence = kinds(events)
    XCTAssertTrue(sequence.contains(.budgetReached))
    XCTAssertFalse(sequence.contains(.subagentJoining), "no waiting for work there is no budget to fund")
    let finishedAt = try XCTUnwrap(sequence.firstIndex(of: .subagentFinished))
    guard case .subagentFinished(_, _, let steps, _, let cost, let preview) = events[finishedAt] else {
      return XCTFail("not a subagentFinished")
    }
    XCTAssertEqual(preview, "cancelled")
    XCTAssertEqual(steps, 2, "the nested turn's real figures: one step done, one interrupted")
    XCTAssertEqual(cost, 0.02, accuracy: 0.0001)

    XCTAssertEqual(harness.task.pendingBackgroundCount(), 0)
    let history = await harness.session.history
    XCTAssertFalse(history.contains { ($0.toolCalls ?? []).contains { $0.id?.hasPrefix("bg-") == true } },
                   "a cancelled run delivers nothing")
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.stopReason, .budget)
    XCTAssertEqual(record.costUSD, 0.03, accuracy: 0.0001, "lead 0.01 + the cancelled run's stranded 0.02")
    let nested = try harness.store.all().filter { $0.agent == "helper" }
    XCTAssertEqual(nested.map(\.stopReason), [.interrupted])
    XCTAssertEqual(nested.first?.costUSD ?? 0, 0.02, accuracy: 0.0001)
    XCTAssertEqual(harness.task.drainAccruedCost(), 0, "the stranded spend was drained into the turn")
    for _ in 0..<99 { await held.arrive() }
  }

  // MARK: Gates a background run still passes

  func testSubagentStartHookBlocksABackgroundRunBeforeAnythingIsSpent() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    // No nested script on purpose: a request would throw, not merely be recorded.
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStart, matcher: "*", command: "printf 'not now'; exit 2")])
    tool.parentModel = { "lead/model" }
    let collector = BackgroundEventCollector()
    tool.onEvent = { collector.append($0) }

    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("long thing"), "background": .bool(true),
    ])
    XCTAssertEqual(result, "subagent blocked by hook: not now")
    XCTAssertTrue(mock.requests.isEmpty)
    XCTAssertEqual(tool.pendingBackgroundCount(), 0)
    XCTAssertTrue(kinds(collector.events).contains(.subagentBlocked))
    XCTAssertFalse(kinds(collector.events).contains(.subagentBackgrounded))
  }

  func testExhaustedParentBudgetRefusesABackgroundSpawnToo() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let tool = TaskTool(agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore())
    tool.parentModel = { "lead/model" }
    tool.parentBudgetRemaining = { 0 }
    let result = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("long thing"), "background": .bool(true),
    ])
    XCTAssertEqual(result, "error: budget limit reached — cannot spawn subagent 'helper'")
    XCTAssertEqual(tool.pendingBackgroundCount(), 0)
    XCTAssertTrue(mock.requests.isEmpty)
  }

  func testBackgroundRunsRespectTheConcurrencyCap() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("first", cost: 0.01), report("second", cost: 0.01)]
    let arrived = Latch()
    let release = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await arrived.arrive()
      await release.wait(for: 1)
    }
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      defaults: TaskTool.Defaults(maxConcurrent: 1))
    tool.parentModel = { "lead/model" }

    for _ in 0..<2 {
      let result = try await tool.execute(arguments: [
        "agent": .string("helper"), "task": .string("long thing"), "background": .bool(true),
      ])
      XCTAssertTrue(result.hasPrefix("started background subagent"))
    }
    XCTAssertEqual(tool.pendingBackgroundCount(), 2)
    // Both were accepted at once, but only one may be running: wait for the first to reach the
    // mock (deterministic), then check the second is still parked on the limiter — a leaked slot
    // would let it reach the mock too. The negative half can only be sampled, so it is sampled
    // after the positive half is certain rather than on a timer alone.
    await arrived.wait(for: 1)
    try await Task.sleep(nanoseconds: 50_000_000)
    let early = await arrived.count
    XCTAssertEqual(early, 1, "maxConcurrent 1 holds the second background run")

    await release.arrive()
    let racedFirst = try await withDeadline(seconds: 5) { await tool.awaitAnyBackground() }
    let racedSecond = try await withDeadline(seconds: 5) { await tool.awaitAnyBackground() }
    let first = try XCTUnwrap(racedFirst)
    let second = try XCTUnwrap(racedSecond)
    XCTAssertEqual(Set([first?.report, second?.report]), ["first", "second"])
    let total = await arrived.count
    XCTAssertEqual(total, 2)
    XCTAssertEqual(tool.pendingBackgroundCount(), 0)
  }

  func testSubagentStopHookOutputRidesADeliveredReport() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("did it")]
    let tool = TaskTool(
      agents: [helper()], service: mock, tools: [ReadFileTool()], store: tempStore(),
      hooks: [HookDefinition(event: .subagentStop, command: "echo REVIEWED")])
    tool.parentModel = { "lead/model" }
    _ = try await tool.execute(arguments: [
      "agent": .string("helper"), "task": .string("long thing"), "background": .bool(true),
    ])
    let raced = try await withDeadline(seconds: 5) { await tool.awaitAnyBackground() }
    let outcome = try XCTUnwrap(raced)
    XCTAssertEqual(outcome?.report, "did it\n\n[hook]\nREVIEWED")
  }

  // MARK: Precedence

  func testBackgroundPrecedenceIsToolArgumentThenFrontmatterThenDefault() {
    let plain = helper()
    let detached = helper(background: true)
    let off = TaskTool.Defaults()
    let on = TaskTool.Defaults(background: true)
    XCTAssertFalse(TaskTool.runsInBackground(arguments: [:], agent: plain, defaults: off))
    XCTAssertTrue(TaskTool.runsInBackground(arguments: ["background": .bool(true)], agent: plain, defaults: off))
    XCTAssertTrue(TaskTool.runsInBackground(arguments: [:], agent: detached, defaults: off))
    XCTAssertTrue(TaskTool.runsInBackground(arguments: [:], agent: plain, defaults: on))
    // The tool argument is the model's word for this call and beats both standing settings.
    XCTAssertFalse(TaskTool.runsInBackground(arguments: ["background": .bool(false)], agent: detached, defaults: on))
    XCTAssertFalse(TaskTool.runsInBackground(arguments: ["background": .bool(false)], agent: plain, defaults: on))
    // A non-boolean argument is ignored, not read as true.
    XCTAssertFalse(TaskTool.runsInBackground(arguments: ["background": .string("yes")], agent: plain, defaults: off))
  }

  func testSchemaAndPromptMentionTheBackgroundField() {
    let tool = TaskTool(agents: [helper()], service: MockOpenRouterService(), tools: [], store: tempStore())
    let properties = tool.parameters.objectValue?["properties"]?.objectValue
    XCTAssertEqual(properties?["background"]?.objectValue?["type"], .string("boolean"))
    XCTAssertEqual(tool.parameters.objectValue?["required"], ["agent", "task"], "still optional")
    // The "when to use background" sentence is delegation guidance, so it lives in the pack
    // (A6), not in the listing section.
    XCTAssertTrue(PromptPack.baseDelegation.contains("background: true"))
    XCTAssertFalse(tool.promptSection.contains("background: true"))
  }

  // MARK: The synthetic exchange translates to the native dialects

  func testDeliveredExchangeTranslatesToMessagesAndResponses() throws {
    let arguments = Session.backgroundCallArguments(agent: "helper")
    XCTAssertEqual(arguments, #"{"agent":"helper","task":"(background result)"}"#)
    let callId = Session.backgroundCallIdPrefix + "a1b2c3d4"
    // The turn-end join's shape: the kept reply is the synthetic call's content.
    let history: [Message] = [
      .user("go"),
      Message(role: .assistant, content: nil, toolCalls: [
        ToolCall(id: "c1", function: .init(name: "task", arguments: #"{"agent":"helper","task":"x","background":true}"#)),
      ]),
      .tool("started background subagent 'helper' (id a1b2c3d4). …", toolCallId: "c1"),
      Message(role: .assistant, content: .text("done for now"), toolCalls: [
        ToolCall(id: callId, function: .init(name: "task", arguments: arguments)),
      ]),
      .tool("[background subagent 'helper' (a1b2c3d4) finished]\n\nbg report", toolCallId: callId),
    ]

    // /messages: the synthetic tool_use and its tool_result round-trip on the same id, and the
    // kept reply rides the same assistant message as the tool_use.
    let anthropic = Fixtures.jsonValue(MessagesTranslator.history(history))
    let anthropicText = HeadlessJSON.line(anthropic)
    XCTAssertTrue(anthropicText.contains(#""id":"bg-a1b2c3d4""#), anthropicText)
    XCTAssertTrue(anthropicText.contains(#""tool_use_id":"bg-a1b2c3d4""#), anthropicText)
    XCTAssertTrue(anthropicText.contains("done for now"), anthropicText)
    XCTAssertEqual(MessagesTranslator.history(history).count, 5, "user, assistant, user(results), assistant, user(results)")

    // /responses: function_call / function_call_output on the same call_id.
    let openai = HeadlessJSON.line(Fixtures.jsonValue(ResponsesTranslator.history(history)))
    XCTAssertEqual(openai.components(separatedBy: #""call_id":"bg-a1b2c3d4""#).count - 1, 2, openai)
  }

  // MARK: The registry

  func testRegistryAwaitReturnsNilWhenCancelledWhileWaiting() async throws {
    let registry = BackgroundSubagents()
    registry.register(id: "r1", agent: "helper", model: "m")
    let waiting = Task { await registry.awaitAny() }
    try await Task.sleep(nanoseconds: 20_000_000)
    waiting.cancel()
    let result = try await withDeadline(seconds: 2) { await waiting.value }
    XCTAssertNotNil(result, "cancellation releases the waiter")
    XCTAssertNil(result ?? nil, "…with nil, not an outcome")
    // The run is still registered; completing it now queues the outcome instead of resuming
    // a waiter that is gone.
    let queued = registry.complete(id: "r1", outcome: BackgroundOutcome(
      id: "r1", agent: "helper", model: "m", report: "r", steps: 1, toolCalls: 0, costUSD: 0.5, partial: false))
    XCTAssertTrue(queued)
    XCTAssertEqual(registry.pendingCount, 1)
    XCTAssertEqual(registry.drainFinished().map(\.id), ["r1"])
    XCTAssertEqual(registry.pendingCount, 0)
  }

  func testRegistryCancelDropsFinishedOutcomesAndReportsTheirSpend() async {
    let registry = BackgroundSubagents()
    registry.register(id: "r1", agent: "helper", model: "m")
    registry.complete(id: "r1", outcome: BackgroundOutcome(
      id: "r1", agent: "helper", model: "m", report: "r", steps: 1, toolCalls: 0, costUSD: 0.25, partial: false))
    registry.register(id: "r2", agent: "helper", model: "m")
    let body = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
    registry.attach(task: body, to: "r2")
    let dropped = await registry.cancelAll()
    XCTAssertEqual(dropped.map(\.id), ["r1"])
    XCTAssertEqual(dropped.first?.costUSD ?? 0, 0.25, accuracy: 0.0001)
    XCTAssertEqual(registry.pendingCount, 0)
    XCTAssertTrue(body.isCancelled)
  }

  func testRegistryRefusesACompletionForARunCancelAlreadyTook() async {
    // A run finishing between `cancelAll`'s snapshot and its `cancel()` sees no cancellation,
    // yet its report must not land in the queue after the turn that owned it has ended.
    let registry = BackgroundSubagents()
    registry.register(id: "r1", agent: "helper", model: "m")
    let body = Task<Void, Never> { _ = try? await Task.sleep(nanoseconds: 5_000_000_000) }
    registry.attach(task: body, to: "r1")
    _ = await registry.cancelAll()
    let queued = registry.complete(id: "r1", outcome: BackgroundOutcome(
      id: "r1", agent: "helper", model: "m", report: "r", steps: 1, toolCalls: 0, costUSD: 0.5, partial: false))
    XCTAssertFalse(queued, "not registered any more: the caller drops it and accrues the spend")
    XCTAssertEqual(registry.pendingCount, 0)
    XCTAssertTrue(registry.drainFinished().isEmpty)
  }
}
