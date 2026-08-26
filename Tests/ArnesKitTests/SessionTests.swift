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

private func drain(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
  var events: [AgentEvent] = []
  for try await event in stream {
    events.append(event)
  }
  return events
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

    _ = try await drain(await session.send("hi"))
    _ = try await drain(await session.send("more"))

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

    let events = try await drain(await session.send("do it"))

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

    _ = try await drain(await session.send("go"))

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

    _ = try await drain(await session.send("go"))

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

    _ = try await drain(await session.send("turn one"))
    let profile = try await session.setModel("openai/gpt-test")
    XCTAssertTrue(profile.supportsTools)
    _ = try await drain(await session.send("turn two"))

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

    _ = try await drain(await session.send("a"))
    _ = try await drain(await session.send("b"))

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

    let events = try await drain(await session.send("fix it"))

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

    let events = try await drain(await session.send("go"))

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

    let events = try await drain(await session.send("rename it"))

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

    let events = try await drain(await session.send("go"))

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
      Fixtures.textResponse("PASS looks plausible", cost: 0.001),
    ]
    let store = tempRecordStore()
    let agent = Agent(service: mock, tools: [], store: store)

    let result = try await agent.run(
      task: "do the thing",
      model: "test/model",
      verifierModel: "cheap/verifier")

    XCTAssertEqual(result.text, "task done")
    XCTAssertEqual(result.record.verifierPassed, true)
    XCTAssertEqual(result.record.costUSD, 0.011, accuracy: 0.0001)
    let records = try store.all()
    XCTAssertEqual(records.count, 1)
    XCTAssertEqual(records[0].verifierPassed, true)
  }
}
