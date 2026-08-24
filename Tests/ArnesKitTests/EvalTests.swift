import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class EvalTests: XCTestCase {
  private func tempStores() -> (EvalStore, RunRecordStore) {
    let base = FileManager.default.temporaryDirectory
    return (
      EvalStore(url: base.appendingPathComponent("arnes-evals-\(UUID().uuidString).jsonl")),
      RunRecordStore(url: base.appendingPathComponent("arnes-eval-runs-\(UUID().uuidString).jsonl")))
  }

  func testSuiteLoadsFromDirectorySortedAndFromSingleFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-suite-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try #"{"id":"b-task","prompt":"p","check":"true"}"#
      .write(to: dir.appendingPathComponent("2.json"), atomically: true, encoding: .utf8)
    try #"[{"id":"a-task","prompt":"p","check":"true"}]"#
      .write(to: dir.appendingPathComponent("1.json"), atomically: true, encoding: .utf8)

    let suite = try EvalSuite.load(path: dir.path)
    XCTAssertEqual(suite.tasks.map(\.id), ["a-task", "b-task"])

    let single = try EvalSuite.load(path: dir.appendingPathComponent("2.json").path)
    XCTAssertEqual(single.tasks.map(\.id), ["b-task"])

    XCTAssertThrowsError(try EvalSuite.load(path: "/nonexistent-\(UUID().uuidString)"))
  }

  func testTrialPassesWhenAgentDoesTheWork() async throws {
    // The mock streams a write_file tool call; the REAL tool executes in the trial's
    // temp workdir; the check script scores the artifact. End-to-end, no network.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(
          id: "c1",
          name: "write_file",
          arguments: #"{"path": "made.txt", "content": "done"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("created it"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "make-file", prompt: "create made.txt", check: "test \"$(cat made.txt)\" = done"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertEqual(outcomes.count, 1)
    XCTAssertTrue(outcomes[0].checkPassed)
    XCTAssertTrue(outcomes[0].agentFinished)
    XCTAssertEqual(outcomes[0].toolCalls, 1)
    XCTAssertEqual(outcomes[0].costUSD, 0.02, accuracy: 0.0001)
    XCTAssertNil(outcomes[0].error)
    // Outcomes persisted; agent runs fed the RunRecord scoreboard too.
    XCTAssertEqual(try evalStore.all().count, 1)
    XCTAssertEqual(try recordStore.all().count, 1)
  }

  func testTrialFailsWhenCheckFailsAndSetupRuns() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("I did nothing"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "needs-edit",
        prompt: "change VALUE to 2 in state.txt",
        setup: "echo 'VALUE=1' > state.txt",
        check: "grep -q 'VALUE=2' state.txt"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertFalse(outcomes[0].checkPassed)
    XCTAssertTrue(outcomes[0].agentFinished)
    XCTAssertNil(outcomes[0].error) // setup ran fine; the agent just didn't do the work
  }

  func testSetupFailureIsReportedWithoutRunningAgent() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "broken", prompt: "p", setup: "exit 3", check: "true"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertFalse(outcomes[0].checkPassed)
    XCTAssertTrue(outcomes[0].error?.contains("setup failed") == true)
    XCTAssertTrue(mock.requests.isEmpty) // agent never ran
  }

  func testStatsAggregateByModel() {
    func outcome(_ model: String, passed: Bool, cost: Double, steps: Int) -> EvalOutcome {
      EvalOutcome(
        suite: "s", taskId: "t", model: model, trial: 1,
        checkPassed: passed, agentFinished: true, steps: steps, toolCalls: 0,
        costUSD: cost, durationSeconds: 1, startedAt: Date(), routedModels: [], error: nil)
    }
    let stats = EvalStats.aggregate([
      outcome("a/one", passed: true, cost: 0.01, steps: 2),
      outcome("a/one", passed: false, cost: 0.03, steps: 4),
      outcome("b/two", passed: true, cost: 0.005, steps: 1),
    ])
    XCTAssertEqual(stats.count, 2)
    // b/two has the higher pass rate → first.
    XCTAssertEqual(stats[0].model, "b/two")
    XCTAssertEqual(stats[0].passRate, 1.0)
    let a = stats.first { $0.model == "a/one" }!
    XCTAssertEqual(a.passed, 1)
    XCTAssertEqual(a.trials, 2)
    XCTAssertEqual(a.totalCostUSD, 0.04, accuracy: 0.0001)
    XCTAssertEqual(a.averageSteps, 3.0, accuracy: 0.0001)
  }
}
