import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Helpers

/// A read-only stand-in for `read_file` that reports when it ran, so a test can prove the
/// step's sequential work happened *while* its delegations were in flight.
private final class LatchedReadTool: AgentTool, @unchecked Sendable {
  let name = "read_file"
  let description = "test read"
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  let permission = ToolPermission.readOnly
  private let latch: Latch

  init(latch: Latch) { self.latch = latch }

  func execute(arguments: [String: JSONValue]) async throws -> String {
    await latch.arrive()
    return "sequential read"
  }
}

/// Counts how many `decide` calls are inside the delegate at once.
private actor ReentrancyProbe {
  private var inside = 0
  private(set) var maxOverlap = 0

  func enter() {
    inside += 1
    maxOverlap = Swift.max(maxOverlap, inside)
  }

  func leave() { inside -= 1 }
}

/// A delegate whose answer takes a moment, so overlapping callers are observable.
private struct ProbingPermissions: PermissionDelegate {
  let probe: ReentrancyProbe
  /// When set, every call arrives here and waits for `arrivals` — only concurrent callers
  /// get through, which is how the control below proves the probe can see overlap at all.
  var latch: Latch?
  var arrivals = 0

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await probe.enter()
    if let latch {
      await latch.arrive()
      await latch.wait(for: arrivals)
    } else {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    await probe.leave()
    return .allow
  }
}

/// Ordered markers, for asserting that concurrent work still lands in one order.
private actor Marks {
  private(set) var items: [String] = []
  func append(_ item: String) { items.append(item) }
}

// MARK: - ParallelTasksTests

/// A2: when one assistant step issues several `task` calls, the subagents run together —
/// bounded by `subagents.maxConcurrent`, prompting one at a time, and still assembled into
/// history in call order.
final class ParallelTasksTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-parallel-runs-\(UUID().uuidString).jsonl"))
  }

  private func manifest() -> String {
    Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "alpha/model"),
      Fixtures.manifestModel(id: "beta/model"),
      Fixtures.manifestModel(id: "sub/model"))
  }

  /// One lead step that issues `calls` in order, then stops.
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

  private func delegation(id: String, agent: String) -> (id: String, tool: String, arguments: String) {
    (id, "task", #"{"agent":"\#(agent)","task":"do \#(agent)"}"#)
  }

  private func reply(_ text: String, cost: Double = 0) -> [ChatCompletionChunk] {
    [Fixtures.textChunk(text, model: "lead/model"), Fixtures.usageChunk(cost: cost, model: "lead/model")]
  }

  private func report(_ text: String, model: String, cost: Double = 0) -> [ChatCompletionChunk] {
    [Fixtures.textChunk(text, model: model), Fixtures.usageChunk(cost: cost, model: model)]
  }

  private func agent(_ name: String, model: String) -> AgentDefinition {
    AgentDefinition(name: name, description: "", body: "Work.", model: model)
  }

  /// A lead session with a task tool over `agents`, sharing one permission delegate the way
  /// the CLI does.
  private func lead(
    mock: MockOpenRouterService,
    agents: [AgentDefinition],
    tools: [any AgentTool] = [],
    defaults: TaskTool.Defaults = TaskTool.Defaults(),
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    hooks: [HookDefinition] = [])
    -> (session: Session, task: TaskTool)
  {
    let store = tempStore()
    let configuration = Session.Configuration(model: "lead/model", hooks: hooks)
    let taskTool = TaskTool(
      agents: agents,
      service: mock,
      tools: tools,
      permissions: permissions,
      store: store,
      defaults: defaults,
      configuration: configuration)
    let session = Session(
      service: mock,
      tools: tools + [taskTool],
      permissions: permissions,
      store: store,
      configuration: configuration)
    taskTool.parentModel = { await session.model }
    return (session, taskTool)
  }
  private func toolResults(of session: Session) async -> [(id: String, text: String)] {
    await session.history
      .filter { $0.role == .tool }
      .map { ($0.toolCallId ?? "", $0.content?.plainText ?? "") }
  }

  // MARK: Concurrency

  func testStepWithTwoTaskCallsRunsSubagentsConcurrently() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "alpha"), delegation(id: "c2", agent: "beta")]),
        reply("both done"),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model")],
      "beta/model": [report("beta report", model: "beta/model")],
    ]
    // Each nested stream arrives, then waits for the other to arrive: only a step that runs
    // its delegations together can finish. A serialized loop deadlocks here, which is what
    // the deadline catches.
    let latch = Latch()
    mock.streamGate = { request in
      guard request.model != "lead/model" else { return }
      await latch.arrive()
      await latch.wait(for: 2)
    }
    let harness = lead(
      mock: mock, agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")])

    let events = try await withDeadline(seconds: 5) {
      try await Events.drain(await harness.session.send("go"))
    }
    XCTAssertNotNil(events, "two task calls in one step must run their subagents concurrently")
    let arrivals = await latch.count
    XCTAssertEqual(arrivals, 2)
    let results = await toolResults(of: harness.session)
    XCTAssertEqual(results.map(\.id), ["c1", "c2"])
  }

  func testConcurrentToolOutputsAreAppendedInCallOrder() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "alpha"), delegation(id: "c2", agent: "beta")]),
        reply("both done"),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model")],
      "beta/model": [report("beta report", model: "beta/model")],
    ]
    // The *second* call finishes first: alpha's request is held until beta's whole run is
    // done. History, records and the next request must not notice.
    let betaFinished = Latch()
    mock.streamGate = { request in
      guard request.model == "alpha/model" else { return }
      await betaFinished.wait(for: 1)
    }
    let harness = lead(
      mock: mock, agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")])

    let events = try await withDeadline(seconds: 5) { () -> [AgentEvent] in
      var collected: [AgentEvent] = []
      for try await event in await harness.session.send("go") {
        if case .subagentFinished("beta", _, _, _, _, _) = event { await betaFinished.arrive() }
        collected.append(event)
      }
      return collected
    }
    let seen = try XCTUnwrap(events)

    let results = await toolResults(of: harness.session)
    XCTAssertEqual(results.map(\.id), ["c1", "c2"], "history follows call order, not finish order")
    XCTAssertEqual(results.map(\.text), ["alpha report", "beta report"])
    // The result events the UI sees are ordered too.
    let previews = seen.compactMap { event -> String? in
      if case .toolResult(_, let preview) = event { return preview }
      return nil
    }
    XCTAssertEqual(previews, ["alpha report", "beta report"])
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.toolCalls, 2)
  }

  func testMixedStepKeepsSequentialToolsInOrderWhileTasksOverlap() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([
          delegation(id: "c1", agent: "alpha"),
          ("c2", "read_file", #"{"path":"notes.md"}"#),
          delegation(id: "c3", agent: "beta"),
        ]),
        reply("all done"),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model")],
      "beta/model": [report("beta report", model: "beta/model")],
    ]
    // Both subagents are held until the lead's own read has run. If the sequential call
    // waited for the delegations instead of running beside them, nothing would ever move.
    let readRan = Latch()
    mock.streamGate = { request in
      guard request.model != "lead/model" else { return }
      await readRan.wait(for: 1)
    }
    let harness = lead(
      mock: mock,
      agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")],
      tools: [LatchedReadTool(latch: readRan)])

    let events = try await withDeadline(seconds: 5) {
      try await Events.drain(await harness.session.send("go"))
    }
    XCTAssertNotNil(events, "the step's sequential tool must run while its tasks are in flight")
    let results = await toolResults(of: harness.session)
    XCTAssertEqual(results.map(\.id), ["c1", "c2", "c3"])
    XCTAssertEqual(results.map(\.text), ["alpha report", "sequential read", "beta report"])
  }

  func testInterruptCancelsAllRunningConcurrentSubagents() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "alpha"), delegation(id: "c2", agent: "beta")]),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model")],
      "beta/model": [report("beta report", model: "beta/model")],
    ]
    // Neither subagent ever gets an answer; the turn is cancelled with both in flight.
    let held = Latch()
    mock.streamGate = { request in
      guard request.model != "lead/model" else { return }
      await held.wait(for: 99)
    }
    let harness = lead(
      mock: mock, agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")])

    let events = try await withDeadline(seconds: 5) { () -> [AgentEvent] in
      var collected: [AgentEvent] = []
      var started = 0
      for try await event in await harness.session.send("go") {
        collected.append(event)
        if case .subagentStarted = event {
          started += 1
          if started == 2 { await harness.session.interrupt() }
        }
      }
      return collected
    }
    let seen = try XCTUnwrap(events, "an interrupted step must still finish its stream")
    XCTAssertTrue(seen.contains { if case .interrupted = $0 { return true } else { return false } })

    // Both delegations were in flight, and both are answered — a dangling tool call would
    // make the next request invalid.
    let results = await toolResults(of: harness.session)
    XCTAssertEqual(results.map(\.id), ["c1", "c2"])
    XCTAssertEqual(results.map(\.text), ["[interrupted by user]", "[interrupted by user]"])
    // Release the parked mock streams so the test leaves nothing waiting.
    for _ in 0..<99 { await held.arrive() }
  }

  func testStepWithoutConcurrentToolsStillGatesAndRunsOneCallAtATime() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([("c1", "read_file", #"{"path":"a"}"#), ("c2", "read_file", #"{"path":"b"}"#)]),
        reply("done"),
      ],
    ]
    let harness = lead(
      mock: mock, agents: [agent("alpha", model: "alpha/model")],
      tools: [LatchedReadTool(latch: Latch())])

    let events = try await Events.drain(await harness.session.send("go"))
    let shape = events.compactMap { event -> String? in
      switch event {
      case .toolCall(let name, _): return "call:\(name)"
      case .toolResult(let name, _): return "result:\(name)"
      default: return nil
      }
    }
    // Nothing opted into concurrency, so the step is what it always was: each call is gated
    // and run, and its result recorded, before the next one is even looked at. A PreToolUse
    // guardrail on the second call still sees the tree the first one left behind.
    XCTAssertEqual(
      shape, ["call:read_file", "result:read_file", "call:read_file", "result:read_file"])
  }

  // MARK: Concurrency cap

  func testSubagentLimiterQueuesOverTheCapAndHandsTheSlotOver() async throws {
    let limiter = SubagentLimiter(max: 1)
    await limiter.acquire()
    let marks = Marks()
    let queued = Task {
      await limiter.acquire()
      await marks.append("second")
      await limiter.release()
    }
    // A short wait, because the assertion is that *nothing* happened: the one slot is taken,
    // so the queued acquire is parked rather than refused.
    try await Task.sleep(nanoseconds: 50_000_000)
    let early = await marks.items
    XCTAssertEqual(early, [], "over the cap, acquire waits instead of failing")

    await marks.append("first")
    await limiter.release()
    await queued.value
    let order = await marks.items
    XCTAssertEqual(order, ["first", "second"], "the released slot is handed to the waiter")
  }

  func testSubagentLimiterCapsOverlap() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "alpha"), delegation(id: "c2", agent: "beta")]),
        reply("done"),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model")],
      "beta/model": [report("beta report", model: "beta/model")],
    ]
    let harness = lead(
      mock: mock,
      agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")],
      defaults: TaskTool.Defaults(maxConcurrent: 1))

    let events = try await Events.drain(await harness.session.send("go"))
    let markers = events.compactMap { event -> String? in
      switch event {
      case .subagentStarted(let name, _, _, _): return "start:\(name)"
      case .subagentFinished(let name, _, _, _, _, _): return "end:\(name)"
      default: return nil
      }
    }
    XCTAssertEqual(markers.count, 4)
    // Whichever run took the single slot first, the other only started once it ended.
    let first = String(markers[0].dropFirst("start:".count))
    XCTAssertTrue(markers[0].hasPrefix("start:"), markers.joined(separator: " "))
    XCTAssertEqual(markers[1], "end:\(first)", "maxConcurrent 1 must not overlap: \(markers)")
    XCTAssertEqual(markers[3], "end:\(String(markers[2].dropFirst("start:".count)))")
    // Both still ran, and both reports came back in call order.
    let results = await toolResults(of: harness.session)
    XCTAssertEqual(results.map(\.text), ["alpha report", "beta report"])
  }

  // MARK: Run ids

  func testSubagentEventsCarryDistinctIdsForSameAgentName() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "explore"), delegation(id: "c2", agent: "explore")]),
        reply("done"),
      ],
      // Two runs of one agent, so only the id can tell their progress apart.
      "sub/model": [
        report("first sweep", model: "sub/model"),
        report("second sweep", model: "sub/model"),
      ],
    ]
    let harness = lead(mock: mock, agents: [agent("explore", model: "sub/model")])

    let events = try await Events.drain(await harness.session.send("go"))
    let started = events.compactMap { event -> String? in
      if case .subagentStarted(let name, let id, _, _) = event, name == "explore" { return id }
      return nil
    }
    let finished = events.compactMap { event -> String? in
      if case .subagentFinished(let name, let id, _, _, _, _) = event, name == "explore" { return id }
      return nil
    }
    XCTAssertEqual(started.count, 2)
    XCTAssertEqual(Set(started).count, 2, "each run of an agent gets its own id: \(started)")
    XCTAssertEqual(Set(finished), Set(started), "a run finishes under the id it started with")
    XCTAssertTrue(started.allSatisfy { $0.count == 8 }, "the id is the nested session id, shortened")
    // Nested progress is attributable too.
    let nested = events.compactMap { event -> String? in
      if case .subagent(_, let id, _) = event { return id }
      return nil
    }
    XCTAssertTrue(Set(nested).isSubset(of: Set(started)))
  }

  // MARK: Serialized prompts

  func testSerializedPermissionsNeverOverlapsDecisions() async throws {
    let probe = ReentrancyProbe()
    let serialized = SerializedPermissions(ProbingPermissions(probe: probe))
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<10 {
        group.addTask {
          _ = await serialized.decide(PermissionRequest(
            toolName: "bash", summary: "call \(index)", argumentsJSON: "{}", tier: .mutating))
        }
      }
    }
    let overlap = await probe.maxOverlap
    XCTAssertEqual(overlap, 1, "two prompts must never be open at once")
  }

  func testUnserializedDelegateWouldOverlap() async throws {
    // The control: the same probe, unwrapped, does let two decisions overlap — so the
    // assertion above is about the wrapper, not about the scheduler being lazy.
    let probe = ReentrancyProbe()
    let latch = Latch()
    let bare = ProbingPermissions(probe: probe, latch: latch, arrivals: 2)
    let finished = try await withDeadline(seconds: 5) { () -> Bool in
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<2 {
          group.addTask {
            _ = await bare.decide(
              toolName: "bash", summary: "call \(index)", argumentsJSON: "{}")
          }
        }
      }
      return true
    }
    XCTAssertEqual(finished, true)
    let overlap = await probe.maxOverlap
    XCTAssertEqual(overlap, 2)
  }

  // MARK: Cost

  func testCostFromConcurrentSubagentsAllDrainsIntoParentTurn() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "alpha"), delegation(id: "c2", agent: "beta")], cost: 0.01),
        reply("done", cost: 0.005),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model", cost: 0.02)],
      "beta/model": [report("beta report", model: "beta/model", cost: 0.03)],
    ]
    let harness = lead(
      mock: mock, agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")])

    let events = try await Events.drain(await harness.session.send("go"))
    let stats = events.compactMap { event -> Session.TurnStats? in
      if case .turnFinished(let stats) = event { return stats }
      return nil
    }
    let turn = try XCTUnwrap(stats.last)
    XCTAssertEqual(turn.turnCostUSD, 0.065, accuracy: 0.0001, "lead + both subagents")
    let sessionCost = await harness.session.costUSD
    XCTAssertEqual(sessionCost, 0.065, accuracy: 0.0001)
    let lastRecord = await harness.session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.costUSD, 0.065, accuracy: 0.0001)
    XCTAssertEqual(harness.task.drainAccruedCost(), 0, "every dollar was already drained")
  }

  // MARK: Hooks

  func testPostToolUseHooksForConcurrentCallsRunSequentially() async throws {
    let log = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-parallel-hook-\(UUID().uuidString).log")
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScriptsByModel = [
      "lead/model": [
        step([delegation(id: "c1", agent: "alpha"), delegation(id: "c2", agent: "beta")]),
        reply("done"),
      ],
      "alpha/model": [report("alpha report", model: "alpha/model")],
      "beta/model": [report("beta report", model: "beta/model")],
    ]
    // The hook brackets its own run. Interleaved brackets (in, in, out, out) would mean two
    // PostToolUse hooks ran at once — a formatter racing itself over the same tree.
    let harness = lead(
      mock: mock,
      agents: [agent("alpha", model: "alpha/model"), agent("beta", model: "beta/model")],
      hooks: [HookDefinition(
        event: .postToolUse,
        matcher: "task",
        command: "printf 'in\\n' >> '\(log.path)'; sleep 0.05; printf 'out\\n' >> '\(log.path)'")])

    _ = try await Events.drain(await harness.session.send("go"))
    let lines = (try String(contentsOf: log, encoding: .utf8))
      .split(separator: "\n").map(String.init)
    XCTAssertEqual(lines, ["in", "out", "in", "out"], "PostToolUse hooks run one at a time")
    // Both concurrent calls were still recorded, in call order.
    let results = await toolResults(of: harness.session)
    XCTAssertEqual(results.map(\.id), ["c1", "c2"])
    try? FileManager.default.removeItem(at: log)
  }
}
