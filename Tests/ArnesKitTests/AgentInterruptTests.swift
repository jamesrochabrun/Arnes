import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// Collects event kinds from `onEvent`, which is `@Sendable` and so can't append to a plain var.
private final class KindCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var kinds: [AgentEvent.Kind] = []

  func note(_ event: AgentEvent) {
    lock.withLock { kinds.append(event.kind) }
  }

  var all: [AgentEvent.Kind] {
    lock.withLock { kinds }
  }
}

/// `Agent.interrupt()` — the headless twin of Ctrl-C, what `arnes do` calls on SIGINT/SIGTERM
/// and at a `--timeout` deadline. The run comes back normally with an `interrupted` record,
/// no dangling tool call, and the session still reachable for its record.
final class AgentInterruptTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-agentinterrupt-\(UUID().uuidString).jsonl"))
  }

  private func mock(_ scripts: [[ChatCompletionChunk]]) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = scripts
    return mock
  }

  func testInterruptDuringASleepingToolAppendsAnInterruptedRecordAndAnswersTheCalls() async throws {
    let mock = mock([[
      Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}", index: 0),
      Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: "{}", index: 1),
      Fixtures.usageChunk(cost: 0.01),
    ]])
    let spy = SpyTool()
    spy.sleepNanoseconds = 60_000_000_000 // cancelled long before this elapses
    let store = tempStore()
    let agent = Agent(service: mock, tools: [spy], store: store, configuration: .init(model: "test/model"))
    XCTAssertNil(agent.lastSession, "nothing to interrupt before a run")

    let started = Date()
    let result = try await agent.run(task: "go", model: "test/model", onEvent: { event in
      if case .toolCall = event { agent.interrupt() }
    })

    XCTAssertEqual(result.stopReason, .interrupted)
    XCTAssertEqual(result.record.stopReason, .interrupted)
    XCTAssertFalse(result.record.finished)
    XCTAssertLessThan(Date().timeIntervalSince(started), 30, "the interrupt cut the 60s sleep short")
    XCTAssertGreaterThanOrEqual(result.durationMs, 0)
    // The record landed in the store — the run left its row like any other.
    XCTAssertEqual(try store.all().count, 1)
    XCTAssertEqual(try store.all().first?.stopReason, .interrupted)
    // The session is still reachable, and its history has no dangling tool call.
    let session = try XCTUnwrap(agent.lastSession)
    XCTAssertEqual(session.id, result.sessionId)
    let history = await session.history
    let calls = Set(history.flatMap { $0.toolCalls ?? [] }.compactMap(\.id))
    let answered = Set(history.filter { $0.role == .tool }.compactMap(\.toolCallId))
    XCTAssertEqual(calls, answered)
    XCTAssertTrue(history.contains { $0.role == .tool && $0.content?.plainText == "[interrupted by user]" })
  }

  func testInterruptWithNothingRunningIsANoOp() async throws {
    let mock = mock([
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("again"), Fixtures.usageChunk(cost: 0)],
    ])
    let store = tempStore()
    let agent = Agent(service: mock, tools: [], store: store, configuration: .init(model: "test/model"))
    agent.interrupt() // before any run: nothing to cancel
    let first = try await agent.run(task: "hi", model: "test/model")
    XCTAssertEqual(first.stopReason, .completed)
    agent.interrupt() // after the run: the finished session has no turn to cancel
    let second = try await agent.run(task: "hi", model: "test/model")
    XCTAssertEqual(second.stopReason, .completed, "a stale interrupt never leaks into the next run")
    XCTAssertEqual(try store.all().count, 2)
  }

  func testInterruptFromAnotherTaskWhileTheModelStreams() async throws {
    // The stream is held open by the gate until the interrupt lands, so the cancellation
    // arrives mid-step rather than between steps — the case a signal handler hits.
    let mock = mock([[Fixtures.textChunk("partial"), Fixtures.usageChunk(cost: 0)]])
    let agent = Agent(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    let opened = Latch()
    mock.streamGate = { _ in
      await opened.arrive()
      try? await Task.sleep(nanoseconds: 5_000_000_000)
    }
    let interrupter = Task {
      await opened.wait(for: 1)
      agent.interrupt()
    }
    let result = try await withDeadline(seconds: 10) {
      try await agent.run(task: "go", model: "test/model")
    }
    _ = await interrupter.value
    let unwrapped = try XCTUnwrap(result, "the interrupted run must return, not hang")
    XCTAssertEqual(unwrapped.stopReason, .interrupted)
  }

  func testAgentResultDerivesDenialsAndStopReasonFromTheRecord() async throws {
    let mock = mock([
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("ok then"), Fixtures.usageChunk(cost: 0)],
    ])
    let agent = Agent(
      service: mock, tools: [SpyTool()], permissions: DenyMutationsPermissions(reason: "read-only run"),
      store: tempStore(), configuration: .init(model: "test/model"))
    let result = try await agent.run(task: "go", model: "test/model")
    XCTAssertEqual(result.stopReason, .completed)
    XCTAssertEqual(result.record.deniedCalls, 1)
    XCTAssertEqual(result.denials.count, 1)
    XCTAssertEqual(result.denials.first?.tool, "spy")
    XCTAssertEqual(result.denials.first?.reason, "read-only run")
  }

  func testDeltasReachOnEventOnlyWhenAsked() async throws {
    let script = [[Fixtures.textChunk("hel"), Fixtures.textChunk("lo"), Fixtures.usageChunk(cost: 0)]]
    let quiet = Agent(service: mock(script), tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    let kinds = KindCollector()
    _ = try await quiet.run(task: "hi", model: "test/model", onEvent: { kinds.note($0) })
    XCTAssertFalse(kinds.all.contains(.textDelta), "headless callers see whole messages by default")
    XCTAssertTrue(kinds.all.contains(.assistantText))

    let streaming = Agent(service: mock(script), tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    streaming.includesDeltaEvents = true
    let streamed = KindCollector()
    _ = try await streaming.run(task: "hi", model: "test/model", onEvent: { streamed.note($0) })
    XCTAssertEqual(streamed.all.filter { $0 == .textDelta }.count, 2)
    XCTAssertTrue(streamed.all.contains(.assistantText), "the whole message still follows its deltas")
  }

  func testSystemSuffixReachesTheConfigurationThroughTheConvenienceInit() {
    let agent = Agent(service: MockOpenRouterService(), tools: [], systemSuffix: "You are the reviewer.")
    XCTAssertEqual(agent.configuration.systemSuffix, "You are the reviewer.")
    let plain = Agent(service: MockOpenRouterService(), tools: [])
    XCTAssertNil(plain.configuration.systemSuffix)
  }

  func testLastSessionExposesTheRecordOfARunThatThrew() async throws {
    // The first request throws (no script to serve it): the loop records `error` and rethrows,
    // and `lastSession` is still there for the caller to read that record from.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [] // the first request finds no script and throws
    let agent = Agent(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    do {
      _ = try await agent.run(task: "go", model: "test/model")
      XCTFail("expected the exhausted script to throw")
    } catch {
      let session = try XCTUnwrap(agent.lastSession)
      let record = await session.lastRecord
      XCTAssertEqual(record?.stopReason, .error, "the loop appended its record before rethrowing")
    }
  }
}
