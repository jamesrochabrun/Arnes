import XCTest
import OpenRouterSwift
@testable import ArnesKit

final class PlanningToolsTests: XCTestCase {

  // MARK: update_plan

  private func plan(_ steps: [(String, String)], explanation: String? = nil) -> [String: JSONValue] {
    let items: [JSONValue] = steps.map { ["step": .string($0.0), "status": .string($0.1)] }
    var args: [String: JSONValue] = ["plan": .array(items)]
    if let explanation { args["explanation"] = .string(explanation) }
    return args
  }

  func testRendersChecklistWithMarks() async throws {
    let out = try await PlanTool().execute(arguments: plan([
      ("read the code", "completed"),
      ("make the change", "in_progress"),
      ("run the tests", "pending"),
    ], explanation: "starting the edit"))
    XCTAssertTrue(out.contains("starting the edit"))
    XCTAssertTrue(out.contains("[x] read the code"), out)
    XCTAssertTrue(out.contains("[~] make the change"), out)
    XCTAssertTrue(out.contains("[ ] run the tests"), out)
  }

  func testSummaryCountsCompleted() {
    let s = PlanTool().summary(arguments: plan([
      ("a", "completed"), ("b", "completed"), ("c", "pending"),
    ]))
    XCTAssertEqual(s, "update_plan (2/3 done)")
  }

  func testEmptyPlanIsAnError() async throws {
    let out = try await PlanTool().execute(arguments: ["plan": .array([])])
    XCTAssertTrue(out.contains("error"), out)
  }

  func testUnknownStatusFallsBackToPending() async throws {
    let out = try await PlanTool().execute(arguments: plan([("x", "banana")]))
    XCTAssertTrue(out.contains("[ ] x"), out)
  }

  func testPlanToolIsUngated() {
    XCTAssertEqual(PlanTool().permission, .readOnly)
  }

  // MARK: think

  func testThinkReturnsEmptyAndIsUngated() async throws {
    let think = ThinkTool()
    XCTAssertEqual(think.permission, .readOnly)
    let out = try await think.execute(arguments: ["thought": .string("I should check the tests first")])
    XCTAssertEqual(out, "")
    XCTAssertTrue(think.summary(arguments: ["thought": .string("check tests")]).contains("check tests"))
  }

  func testThinkMissingThoughtIsError() async throws {
    let out = try await ThinkTool().execute(arguments: [:])
    XCTAssertTrue(out.contains("error"), out)
  }

  // MARK: wiring

  func testDefaultToolsetIncludesPlanningTools() {
    let names = Set(Session.defaultTools.map(\.name))
    XCTAssertTrue(names.contains("update_plan"))
    XCTAssertTrue(names.contains("think"))
  }

  // MARK: C6 — the plan as an event (T9)

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-plan-runs-\(UUID().uuidString).jsonl"))
  }

  private static let planArguments = #"{"plan":[{"step":"read","status":"completed"},{"step":"edit","status":"in_progress"},{"step":"test","status":"pending"}]}"#

  func testSeveralInProgressStepsGetTheKeepExactlyOneNote() async throws {
    let out = try await PlanTool().execute(arguments: plan([("a", "in_progress"), ("b", "in_progress"), ("c", "pending")]))
    XCTAssertTrue(out.contains("[arnes: 2 steps are in_progress — keep exactly one]"), out)
    let fine = try await PlanTool().execute(arguments: plan([("a", "completed"), ("b", "in_progress")]))
    XCTAssertFalse(fine.contains("[arnes:"), fine)
    let allDone = try await PlanTool().execute(arguments: plan([("a", "completed")]))
    XCTAssertFalse(allDone.contains("[arnes:"), "none in progress is fine — the work is done")
  }

  func testPlanStepsParseTheArgumentsJSON() {
    let steps = PlanTool.planSteps(fromArgumentsJSON: Self.planArguments)
    XCTAssertEqual(steps.map(\.text), ["read", "edit", "test"])
    XCTAssertEqual(steps.map(\.status), ["completed", "in_progress", "pending"])
    XCTAssertTrue(PlanTool.planSteps(fromArgumentsJSON: "not json").isEmpty)
    XCTAssertTrue(PlanTool.planSteps(fromArgumentsJSON: #"{"plan":"nope"}"#).isEmpty)
  }

  func testCallingTheToolOutsideASessionEmitsNothing() async throws {
    // No task-local sink: the tool still renders, nothing is emitted, nothing crashes.
    XCTAssertNil(ToolEventSink.current)
    let out = try await PlanTool().execute(arguments: plan([("a", "pending")]))
    XCTAssertTrue(out.contains("[ ] a"))
  }

  /// A turn that calls `update_plan` yields `.planUpdated` between the call and its result,
  /// with the complete plan; `lastPlanSteps` reads the same plan back off the history.
  func testUpdatePlanYieldsPlanUpdatedAndLastPlanStepsReadsIt() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "update_plan", arguments: Self.planArguments), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("working"), Fixtures.usageChunk(cost: 0)],
    ]
    let session = Session(service: mock, tools: [PlanTool()], store: tempStore(), configuration: .init(model: "test/model"))
    let initialPlan = await session.lastPlanSteps
    XCTAssertNil(initialPlan)

    var kinds: [AgentEvent.Kind] = []
    var planned: [(text: String, status: String)]?
    for try await event in await session.send("go") {
      kinds.append(event.kind)
      if case .planUpdated(let steps) = event { planned = steps }
    }
    XCTAssertEqual(planned?.map(\.text), ["read", "edit", "test"])
    XCTAssertEqual(planned?.map(\.status), ["completed", "in_progress", "pending"])
    let call = try XCTUnwrap(kinds.firstIndex(of: .toolCall))
    let updated = try XCTUnwrap(kinds.firstIndex(of: .planUpdated))
    let result = try XCTUnwrap(kinds.firstIndex(of: .toolResult))
    XCTAssertLessThan(call, updated)
    XCTAssertLessThan(updated, result)

    let lastPlan = await session.lastPlanSteps
    let last = try XCTUnwrap(lastPlan)
    XCTAssertEqual(last.map(\.text), ["read", "edit", "test"])
    XCTAssertEqual(last.map(\.status), ["completed", "in_progress", "pending"])
    // The plan goes with the history.
    _ = await session.clearHistory()
    let cleared = await session.lastPlanSteps
    XCTAssertNil(cleared)
  }

  /// The core tools are shared with a nested session (the task tool reuses the lead's
  /// instances), so the sink is per execution: a subagent's plan reaches the lead only as a
  /// nested event, and the lead's own `lastPlanSteps` never picks it up.
  func testASubagentsPlanArrivesNestedAndNeverAsTheLeads() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScriptsByModel = [
      "lead/model": [
        [Fixtures.toolCallChunk(id: "c1", name: "task", arguments: #"{"agent":"helper","task":"plan it"}"#, model: "lead/model"),
         Fixtures.usageChunk(cost: 0, model: "lead/model")],
        [Fixtures.textChunk("done", model: "lead/model"), Fixtures.usageChunk(cost: 0, model: "lead/model")],
      ],
      "sub/model": [[
        Fixtures.toolCallChunk(id: "s1", name: "update_plan", arguments: Self.planArguments, model: "sub/model"),
        Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ], [
        Fixtures.textChunk("sub report", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ]],
    ]
    let store = tempStore()
    let helper = AgentDefinition(name: "helper", description: "", body: "b", model: "sub/model")
    let planTool = PlanTool()
    let taskTool = TaskTool(agents: [helper], service: mock, tools: [planTool], store: store)
    let session = Session(service: mock, tools: [planTool, taskTool], store: store, configuration: .init(model: "lead/model"))
    taskTool.parentModel = { await session.model }

    var topLevelPlans = 0
    var nestedPlans: [[(text: String, status: String)]] = []
    for try await event in await session.send("go") {
      switch event {
      case .planUpdated: topLevelPlans += 1
      case .subagent("helper", _, .planUpdated(let steps)): nestedPlans.append(steps)
      default: break
      }
    }
    XCTAssertEqual(topLevelPlans, 0, "the shared PlanTool instance emitted into the subagent's stream, not the lead's")
    XCTAssertEqual(nestedPlans.count, 1)
    XCTAssertEqual(nestedPlans.first?.map(\.text), ["read", "edit", "test"])
    let leadPlan = await session.lastPlanSteps
    XCTAssertNil(leadPlan, "the lead's history holds no update_plan call")
  }
}
