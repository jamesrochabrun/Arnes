import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Test doubles

/// Records executions; optionally sleeps so tests can interrupt mid-execution.
final class SpyTool: AgentTool, @unchecked Sendable {
  let name: String
  let description = "test tool"
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  let permission: ToolPermission
  var sleepNanoseconds: UInt64 = 0
  private let lock = NSLock()
  private var recorded: [String] = []

  init(name: String = "spy", permission: ToolPermission = .mutating) {
    self.name = name
    self.permission = permission
  }

  var executions: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func execute(arguments: [String: JSONValue]) async throws -> String {
    lock.withLock { recorded.append(name) }
    if sleepNanoseconds > 0 {
      try await Task.sleep(nanoseconds: sleepNanoseconds)
    }
    return "ok"
  }
}

final class ScriptedPermissions: PermissionDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var decisions: [PermissionDecision]
  private var recorded: [String] = []

  init(_ decisions: [PermissionDecision]) {
    self.decisions = decisions
  }

  var asks: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    lock.withLock {
      recorded.append(toolName)
      return decisions.isEmpty ? .allow : decisions.removeFirst()
    }
  }
}

// MARK: - Helpers

private func tempRecordStore() -> RunRecordStore {
  RunRecordStore(url: FileManager.default.temporaryDirectory
    .appendingPathComponent("arnes-session-runs-\(UUID().uuidString).jsonl"))
}
extension Message.Content {
  fileprivate var testText: String { plainText }
}

// MARK: - SessionTests

final class SessionTests: XCTestCase {
  func testHistoryRetainedAcrossTurnsAndCostAccumulates() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("Hello!"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("Again"), Fixtures.usageChunk(cost: 0.02)],
    ]
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    _ = try await Events.drain(await session.send("hi"))
    _ = try await Events.drain(await session.send("more"))

    let requests = mock.requests
    XCTAssertEqual(requests.count, 2)
    // Second request: system + [user hi, assistant Hello!, user more].
    XCTAssertEqual(requests[1].messages.count, 4)
    XCTAssertEqual(requests[1].messages[0].role, .system)
    XCTAssertEqual(requests[1].messages[1].content?.testText, "hi")
    XCTAssertEqual(requests[1].messages[2].role, .assistant)
    XCTAssertEqual(requests[1].messages[2].content?.testText, "Hello!")
    XCTAssertEqual(requests[1].messages[3].content?.testText, "more")

    let cost = await session.costUSD
    XCTAssertEqual(cost, 0.03, accuracy: 0.0001)
  }

  /// C6 `/btw`: a side question rides one non-streaming request over the system prompt, the
  /// history and the question — never into history — and its spend lands on the session.
  func testAsideDoesNotAppendToHistoryButAddsCost() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("Hello!"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("Again"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [Fixtures.textResponse("On the side: 42.", cost: 0.02)]
    let transcripts = SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-aside-sessions-\(UUID().uuidString)"))
    let session = Session(
      service: mock,
      tools: [SpyTool()],
      store: tempRecordStore(),
      sessionStore: transcripts,
      configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("hi"))
    let before = await session.history.count
    let cost = await session.costUSD
    let persistedBefore = try transcripts.load(id: session.id)

    let (reply, spent) = try await session.aside("what did I say?")

    XCTAssertEqual(reply, "On the side: 42.")
    XCTAssertEqual(spent, 0.02, accuracy: 0.0001)
    let after = await session.costUSD
    XCTAssertEqual(after, cost + 0.02, accuracy: 0.0001)
    let count = await session.history.count
    XCTAssertEqual(count, before, "nothing entered history")
    // The spend is on the transcript too (a `cost` line): a resume starts from the true total,
    // while the messages are exactly what they were — the question and the answer never persist.
    let persisted = try transcripts.load(id: session.id)
    XCTAssertEqual(persisted.costUSD, persistedBefore.costUSD + 0.02, accuracy: 0.0001)
    XCTAssertEqual(persisted.messages.count, persistedBefore.messages.count)
    XCTAssertFalse(persisted.messages.contains { $0.content?.testText.contains("On the side") == true })
    // The side request: system + the history + the question, no tools (the history called none).
    let side = mock.requests[1]
    XCTAssertEqual(side.messages.map(\.role), [.system, .user, .assistant, .user])
    XCTAssertEqual(side.messages.last?.content?.testText, "what did I say?")
    XCTAssertEqual(side.messages[1].content?.testText, "hi")
    XCTAssertNil(side.tools)
    XCTAssertNil(side.responseFormat)
    // The next turn's request is unaware of it.
    _ = try await Events.drain(await session.send("more"))
    let next = mock.requests[2]
    XCTAssertEqual(next.messages.map(\.role), [.system, .user, .assistant, .user])
    XCTAssertFalse(next.messages.contains { $0.content?.testText.contains("what did I say") == true })
    XCTAssertFalse(next.messages.contains { $0.content?.testText.contains("On the side") == true })
  }

  /// A history that called a tool needs the definitions on the side request too (Anthropic
  /// refuses `tool_use` blocks without `tools`); `tool_choice: none` keeps it an answer.
  func testAsideCarriesToolDefinitionsWhenTheHistoryCalledOne() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [Fixtures.textResponse("yes", cost: 0)]
    let session = Session(
      service: mock, tools: [SpyTool()], store: tempRecordStore(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("do it"))
    _ = try await session.aside("did it run?")
    let side = mock.requests.last!
    XCTAssertEqual(side.tools?.map(\.function.name), ["spy"])
    XCTAssertNotNil(side.toolChoice)
    XCTAssertTrue(side.messages.contains { $0.role == .tool }, "the tool exchange is replayed as the next step would")
  }

  func testDeniedToolIsNotExecutedAndModelSeesDenial() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("understood"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = SpyTool()
    let session = Session(
      service: mock,
      tools: [spy],
      permissions: ScriptedPermissions([.deny(reason: "nope")]),
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    let events = try await Events.drain(await session.send("do it"))

    XCTAssertTrue(spy.executions.isEmpty)
    XCTAssertTrue(events.contains { if case .toolDenied = $0 { return true } else { return false } })
    // The denial is visible to the model in the next request's tool message.
    let secondRequest = mock.requests[1]
    let toolMessage = secondRequest.messages.last { $0.role == .tool }
    XCTAssertEqual(toolMessage?.toolCallId, "c1")
    XCTAssertTrue(toolMessage?.content?.testText.contains("user denied permission") == true)
    XCTAssertTrue(toolMessage?.content?.testText.contains("nope") == true)
  }

  func testAllowAlwaysPromptsOnlyOnce() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}", index: 0),
        Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: "{}", index: 1),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = SpyTool()
    let permissions = ScriptedPermissions([.allowAlwaysThisSession])
    let session = Session(
      service: mock,
      tools: [spy],
      permissions: permissions,
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    _ = try await Events.drain(await session.send("go"))

    XCTAssertEqual(permissions.asks.count, 1)
    XCTAssertEqual(spy.executions.count, 2)
  }

  func testReadOnlyToolsSkipThePermissionDelegate() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = SpyTool(permission: .readOnly)
    let permissions = ScriptedPermissions([.deny(reason: "should never be asked")])
    let session = Session(
      service: mock,
      tools: [spy],
      permissions: permissions,
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    _ = try await Events.drain(await session.send("go"))

    XCTAssertTrue(permissions.asks.isEmpty)
    XCTAssertEqual(spy.executions.count, 1)
  }

  func testSetModelSwapsModelPackAndKeepsHistory() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "alpha/one"),
      Fixtures.manifestModel(id: "openai/gpt-test"))
    mock.chunkScripts = [
      [Fixtures.textChunk("first"), Fixtures.usageChunk(cost: 0.01)],
    ]
    // The swap lands on an openai/* model, which executes natively on /responses.
    mock.responsesEventScripts = [
      [
        Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"second"}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r1","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":5}}}"#),
      ],
    ]
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      dialectStore: DialectVerdictStore(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("arnes-swap-verdicts-\(UUID().uuidString).jsonl")),
      configuration: .init(model: "alpha/one"))

    _ = try await Events.drain(await session.send("turn one"))
    let profile = try await session.setModel("openai/gpt-test")
    XCTAssertTrue(profile.supportsTools)
    _ = try await Events.drain(await session.send("turn two"))

    let second = try XCTUnwrap(mock.responsesRequests.first)
    XCTAssertEqual(second.model, "openai/gpt-test")
    // The system prompt is rebuilt for the new family's pack (as `instructions`)…
    XCTAssertTrue(second.instructions?.contains("exact JSON arguments") == true)
    // …and the full prior conversation rides along, translated to input items.
    let items = Fixtures.jsonValue(second.input).arrayValue ?? []
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items[0]["role"]?.stringValue, "user")
    XCTAssertEqual(items[0]["content"]?.stringValue, "turn one")
    XCTAssertEqual(items[1]["role"]?.stringValue, "assistant")
    XCTAssertEqual(items[1]["content"]?.stringValue, "first")
    XCTAssertEqual(items[2]["content"]?.stringValue, "turn two")
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "responses")
  }

  func testInterruptLeavesNoDanglingToolCalls() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}", index: 0),
        Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: "{}", index: 1),
        Fixtures.usageChunk(cost: 0.01),
      ],
    ]
    let spy = SpyTool()
    spy.sleepNanoseconds = 60_000_000_000 // cancelled long before this elapses
    let session = Session(
      service: mock,
      tools: [spy],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    var events: [AgentEvent] = []
    for try await event in await session.send("go") {
      events.append(event)
      if case .toolCall = event {
        await session.interrupt()
      }
    }

    XCTAssertTrue(events.contains { if case .interrupted = $0 { return true } else { return false } })
    // Every tool call in the history has an answering tool message.
    let history = await session.history
    let assistantCalls = history.flatMap { $0.toolCalls ?? [] }.compactMap(\.id)
    let answered = Set(history.filter { $0.role == .tool }.compactMap(\.toolCallId))
    XCTAssertEqual(Set(assistantCalls), answered)
    // The second call never ran; it was answered synthetically.
    let syntheticResults = history.filter {
      $0.role == .tool && $0.content?.testText == "[interrupted by user]"
    }
    XCTAssertFalse(syntheticResults.isEmpty)
  }

  func testEachTurnAppendsARunRecordWithSessionId() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let store = tempRecordStore()
    let session = Session(
      service: mock,
      tools: [],
      store: store,
      configuration: .init(model: "test/model"))

    _ = try await Events.drain(await session.send("a"))
    _ = try await Events.drain(await session.send("b"))

    let records = try store.all()
    XCTAssertEqual(records.count, 2)
    XCTAssertEqual(records[0].sessionId, session.id)
    XCTAssertEqual(records[0].turnIndex, 0)
    XCTAssertEqual(records[1].turnIndex, 1)
    XCTAssertTrue(records.allSatisfy(\.finished))
  }

  func testStallingReplyIsNudgedBackIntoTheLoop() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      // Stall: narrates intent instead of calling the tool.
      [Fixtures.textChunk("Let me check the file next."), Fixtures.usageChunk(cost: 0.01)],
      // After the nudge, it actually works…
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0.01)],
      // …and finishes.
      [Fixtures.textChunk("Done. Updated the file."), Fixtures.usageChunk(cost: 0.01)],
    ]
    let spy = SpyTool(permission: .readOnly)
    let session = Session(
      service: mock,
      tools: [spy],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    let events = try await Events.drain(await session.send("fix it"))

    XCTAssertTrue(events.contains { if case .nudged = $0 { return true } else { return false } })
    XCTAssertEqual(spy.executions.count, 1)
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.steps, 3)
    // The nudge rode the history as a user message so the model saw it.
    let nudgeRequest = mock.requests[1]
    XCTAssertEqual(nudgeRequest.messages.last?.role, .user)
    XCTAssertTrue(nudgeRequest.messages.last?.content?.testText.contains("without a tool call") == true)
  }

  func testNudgesAreBoundedSoAStubbornModelStillFinishes() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("I'll start by looking around."), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("Now I will inspect the code."), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("Next I plan to read the file."), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [SpyTool(permission: .readOnly)],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    let events = try await Events.drain(await session.send("go"))

    let nudges = events.filter { if case .nudged = $0 { return true } else { return false } }
    XCTAssertEqual(nudges.count, 2)
    XCTAssertEqual(mock.requests.count, 3)
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertTrue(record.finished)
  }

  func testCompleteReplyIsNotNudged() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("The task is complete. I renamed the symbol in both files."), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [SpyTool(permission: .readOnly)],
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))

    let events = try await Events.drain(await session.send("rename it"))

    XCTAssertFalse(events.contains { if case .nudged = $0 { return true } else { return false } })
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testStepLimitExhaustionIsSurfaced() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [SpyTool(permission: .readOnly)],
      store: tempRecordStore(),
      configuration: .init(model: "test/model", maxStepsPerTurn: 1))

    let events = try await Events.drain(await session.send("go"))

    XCTAssertTrue(events.contains { if case .stepLimitReached = $0 { return true } else { return false } })
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertFalse(record.finished)
  }

  func testLooksUnfinishedHeuristic() {
    XCTAssertTrue(Session.looksUnfinished(""))
    XCTAssertTrue(Session.looksUnfinished("I found the bug. Now to fix it:"))
    XCTAssertTrue(Session.looksUnfinished("Let me check the tests"))
    XCTAssertTrue(Session.looksUnfinished("The switch is wrong. I'll fix ThreadScreen now."))
    XCTAssertFalse(Session.looksUnfinished("Renamed the symbol in both files."))
    XCTAssertFalse(Session.looksUnfinished("Done. Let me know if you need anything else."))
    XCTAssertFalse(Session.looksUnfinished("The fix is in place and the tests pass."))
  }

  func testAgentRunWrapsSessionAndLandsVerifierInRecord() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("task done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [
      Fixtures.textResponse(
        #"{"pass": true, "confidence": "high", "reasons": ["looks plausible"], "unmet": []}"#, cost: 0.001),
    ]
    let store = tempRecordStore()
    let agent = Agent(service: mock, tools: [], store: store)

    let result = try await agent.run(
      task: "do the thing",
      model: "test/model",
      verifierModel: "cheap/verifier")

    XCTAssertEqual(result.text, "task done")
    XCTAssertEqual(result.record.verifierPassed, true)
    XCTAssertEqual(result.record.verifierConfidence, "high")
    XCTAssertEqual(result.record.costUSD, 0.011, accuracy: 0.0001, "the verdict's spend is booked once")
    let records = try store.all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].verifierPassed, true)
  }

  // MARK: Background jobs (T2)

  /// A job the model started in the background exits while the turn goes on: the exit reaches
  /// the model as a `[arnes]` notice before its next request (the `Session.notify` route the
  /// CLI and the task tool bind), and the `.jobStarted`/`.jobFinished` events ride the stream.
  /// Deterministic in both directions: the job itself waits for a marker the mock writes only
  /// once the second request has arrived (so nothing can be queued before that request's
  /// notice drain), and the second stream is then held until the exit has been queued (so the
  /// third request must carry it).
  func testFinishedJobNoticeReachesTheModel() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-job-release-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let jobCommand = "while [ ! -e '\(marker.path)' ]; do sleep 0.02; done; echo hi"
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "bash", arguments: #"{"command":"\#(jobCommand)","background":true}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c2", name: "bash", arguments: #"{"command":"echo second"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let noticed = Latch()
    // The second request has arrived — its notice drain is behind us — so release the job now
    // and hold this stream until its exit has been queued on the session: the third request is
    // the first that can carry the notice, and it must.
    mock.streamGate = { request in
      if request.messages.filter({ $0.role == .tool }).count == 1 {
        try? Data().write(to: marker)
        await noticed.wait(for: 1)
      }
    }
    let registry = JobRegistry(logRoot: FileManager.default.temporaryDirectory)
    let tools = HarnessAssembly.coreTools(ToolContext(root: FileManager.default.temporaryDirectory, jobs: registry))
    let session = Session(
      service: mock, tools: tools, permissions: AutoApprovePermissions(), store: tempRecordStore(),
      configuration: .init(model: "test/model"))
    // What the CLI binds (`Interactive.bindAgents`, `Do.run`) and the task tool binds for a
    // nested session: the exit becomes a notice on the live session.
    registry.setExitHandler { job in
      Task {
        await session.notify(job.exitNotice)
        await noticed.arrive()
      }
    }

    let raced = try await withDeadline(seconds: 20) { try await Events.drain(await session.send("start it")) }
    let events = try XCTUnwrap(raced, "the turn hung — the gated stream was never released")
    let kinds = events.map(\.kind)
    XCTAssertTrue(kinds.contains(.jobStarted), "the start is an event: \(kinds)")
    XCTAssertTrue(kinds.contains(.jobFinished), "the exit fired into the turn's stream: \(kinds)")
    // The bash result named the job and the log; the third request carries the notice.
    let requests = mock.requests
    XCTAssertEqual(requests.count, 3)
    let bashResult = try XCTUnwrap(requests[1].messages.last { $0.role == .tool }?.content?.testText)
    XCTAssertTrue(bashResult.contains("job 1 started (pid "), bashResult)
    XCTAssertTrue(bashResult.contains("job-1.log"), bashResult)
    let notices = requests[2].messages.filter { $0.role == .user }.compactMap { $0.content?.testText }
      .filter { $0.hasPrefix("[arnes]") }
    XCTAssertEqual(notices.count, 1, "one [arnes] message: \(notices)")
    XCTAssertTrue(notices[0].contains("background job 1 exited 0"), notices[0])
    XCTAssertTrue(notices[0].contains("job-1.log"), notices[0])
    XCTAssertFalse(requests[1].messages.contains { $0.content?.testText.hasPrefix("[arnes]") == true },
                   "nothing had exited before the second request")
    await session.shutdown()
  }

  /// The `job` tool is read-only: polling, waiting for and killing a job the harness itself
  /// started never asks the permission delegate — only harness-owned pids are addressable.
  func testJobToolIsUngated() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "job", arguments: #"{"id":"7"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c2", name: "job", arguments: #"{"id":"7","action":"kill"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let registry = JobRegistry(logRoot: FileManager.default.temporaryDirectory)
    let permissions = ScriptedPermissions([.deny(reason: "must never be asked")])
    let session = Session(
      service: mock, tools: [JobTool(registry: registry)], permissions: permissions,
      store: tempRecordStore(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("check job 7"))
    XCTAssertTrue(permissions.asks.isEmpty, "the job tool is never gated")
    let results = mock.requests[2].messages.filter { $0.role == .tool }.compactMap { $0.content?.testText }
    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results.allSatisfy { $0.contains("no such job '7'") }, "\(results)")
    XCTAssertEqual(JobTool(registry: registry).permission(for: ["id": "1", "action": "kill"]), .readOnly)
  }
}
