import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// X4 — eval graders: the task-file keys (`rubric`, `limits`, `verify`), the outcome fields,
/// the rubric judge over the evidence (never the transcript), the pure limits grader, and
/// the graded verdict a scoreboard counts.
final class EvalGradersTests: XCTestCase {
  // MARK: Fixtures

  private static let judgeProfile = ModelProfile(unknownModelId: "judge/model")

  private static func structuredJudgeProfile() -> ModelProfile {
    let json = """
      {"id":"judge/strict","context_length":8000,"supported_parameters":["tools","response_format"],"pricing":{"prompt":"0.000001","completion":"0.000002"}}
      """
    return ModelProfile(model: try! JSONDecoder().decode(OpenRouterModel.self, from: Data(json.utf8)))
  }

  private static func judgeReply(
    score: Double, pass: Bool, unknown: Bool = false, notes: String = "fine", cost: Double = 0.002)
    -> ChatCompletionResponse
  {
    Fixtures.textResponse(
      """
      {"score": \(score), "pass": \(pass), "unknown": \(unknown), "notes": "\(notes)", "criteria": [{"criterion": "c1", "met": \(pass)}]}
      """,
      cost: cost)
  }

  private static func rubricTask(threshold: Double? = nil, gate: Bool? = nil) -> EvalTask {
    EvalTask(
      id: "t", prompt: "make hello.txt", check: "true",
      rubric: EvalTask.Rubric(criteria: ["hello.txt exists", "it says hello"], threshold: threshold, gate: gate))
  }

  private static let evidence = RubricJudge.Evidence(
    report: "I created hello.txt",
    diff: "diff -ruN base/hello.txt candidate/hello.txt\n+hello",
    checkPassed: true,
    checkOutput: "")

  private static let neverCharged: @Sendable (Usage?) async -> Double? = { $0?.cost }

  private func record(
    steps: Int = 3, toolCalls: Int = 2, cost: Double = 0.01, stop: StopReason? = .completed,
    stats: [String: Int] = [:])
    -> RunRecord
  {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.steps = steps
    record.toolCalls = toolCalls
    record.costUSD = cost
    record.stopReason = stop
    for (tool, calls) in stats {
      for _ in 0..<calls { record.noteToolCall(tool, failed: false) }
    }
    return record
  }

  // MARK: Task file

  /// Every shipped task decodes with the new keys absent: the schema grew, the files did not.
  func testEvalTaskDecodesLegacyShape() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let suite = try EvalSuite.load(path: root.appendingPathComponent("evals/basics").path)
    XCTAssertGreaterThanOrEqual(suite.tasks.count, 8)
    for task in suite.tasks {
      XCTAssertNil(task.rubric, task.id)
      XCTAssertNil(task.limits, task.id)
      XCTAssertNil(task.verify, task.id)
    }
    // The shipped graded suite exercises every key.
    let graded = try EvalSuite.load(path: root.appendingPathComponent("evals/graded").path)
    XCTAssertEqual(graded.tasks.map(\.id), ["add-docstring-rubric", "fix-typo-efficiently", "multi-edit-one-call"])
    // T7's task records the tool-call count without gating on it.
    XCTAssertEqual(graded.tasks[2].limits?.maxToolCalls, 4)
    XCTAssertEqual(graded.tasks[2].limits?.gates, false)
    XCTAssertNil(graded.tasks[2].rubric)
    XCTAssertEqual(graded.tasks[0].rubric?.criteria.count, 3)
    XCTAssertEqual(graded.tasks[0].limits?.gates, false)
    XCTAssertEqual(graded.tasks[1].limits?.gates, true)
    XCTAssertEqual(graded.tasks[1].limits?.forbiddenTools, ["bash", "write_file"])
    XCTAssertEqual(graded.tasks[1].verify, true)
    // And a task with every new key round-trips through the plain synthesized coding.
    let json = """
      {"id":"g","prompt":"p","check":"true",
       "rubric":{"criteria":["a","b"],"threshold":0.5,"model":"judge/x","gate":false},
       "limits":{"maxSteps":6,"maxToolCalls":8,"maxCostUSD":0.05,"forbiddenTools":["bash"],"requiredTools":["edit_file"],"gate":true},
       "verify":true}
      """
    let task = try JSONDecoder().decode(EvalTask.self, from: Data(json.utf8))
    XCTAssertEqual(task.rubric?.criteria, ["a", "b"])
    XCTAssertEqual(task.rubric?.effectiveThreshold, 0.5)
    XCTAssertEqual(task.rubric?.model, "judge/x")
    XCTAssertEqual(task.rubric?.gates, false)
    XCTAssertEqual(task.limits?.maxSteps, 6)
    XCTAssertEqual(task.limits?.forbiddenTools, ["bash"])
    XCTAssertEqual(task.limits?.gates, true)
    XCTAssertEqual(task.verify, true)
    // Defaults where the file says nothing.
    XCTAssertEqual(EvalTask.Rubric(criteria: []).effectiveThreshold, 0.7)
    XCTAssertTrue(EvalTask.Rubric(criteria: []).gates)
    XCTAssertFalse(EvalTask.Limits().gates)
  }

  // MARK: Outcome rows

  func testEvalOutcomeOldRowDecodesAndNewFieldsRoundTrip() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    // A row exactly as written before X4: only the pre-X4 keys.
    let old = """
      {"suite":"basics","taskId":"create-file","model":"m","trial":1,"checkPassed":true,"agentFinished":true,"steps":2,"toolCalls":1,"costUSD":0.01,"durationSeconds":1.5,"startedAt":"2026-01-01T00:00:00Z","routedModels":["m"],"dialect":"chat","sandboxed":true}
      """
    let row = try decoder.decode(EvalOutcome.self, from: Data(old.utf8))
    XCTAssertTrue(row.checkPassed)
    XCTAssertNil(row.rubricScore)
    XCTAssertNil(row.rubricPassed)
    XCTAssertNil(row.rubricUnknown)
    XCTAssertNil(row.rubricNotes)
    XCTAssertNil(row.limitsPassed)
    XCTAssertNil(row.limitsViolations)
    XCTAssertNil(row.verifierPassed)
    XCTAssertNil(row.graderCostUSD)
    XCTAssertNil(row.sessionId)
    XCTAssertNil(row.runId)
    XCTAssertNil(row.promptTokens)
    XCTAssertNil(row.completionTokens)
    XCTAssertNil(row.stopReason)
    XCTAssertNil(row.passed)
    XCTAssertTrue(row.isPass, "a row without graders counts its check")

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    // Encoding an old row adds no key: the nil optionals are omitted.
    let reencoded = try JSONSerialization.jsonObject(with: try encoder.encode(row)) as? [String: Any]
    XCTAssertNil(reencoded?["passed"])
    XCTAssertNil(reencoded?["rubricScore"])

    let full = EvalOutcome(
      suite: "s", taskId: "t", model: "m", trial: 2, checkPassed: true, agentFinished: true,
      steps: 4, toolCalls: 3, costUSD: 0.02, durationSeconds: 2, startedAt: Date(timeIntervalSince1970: 1000),
      routedModels: ["m"], error: nil, dialect: "chat", sandboxed: true,
      rubricScore: 0.5, rubricPassed: false, rubricUnknown: false, rubricNotes: "half",
      limitsPassed: false, limitsViolations: ["steps 4 > 3"], verifierPassed: true,
      graderCostUSD: 0.003, sessionId: "S1", runId: "R1", promptTokens: 100, completionTokens: 20,
      stopReason: "completed", passed: false)
    let back = try decoder.decode(EvalOutcome.self, from: try encoder.encode(full))
    XCTAssertEqual(back.rubricScore, 0.5)
    XCTAssertEqual(back.rubricPassed, false)
    XCTAssertEqual(back.rubricUnknown, false)
    XCTAssertEqual(back.rubricNotes, "half")
    XCTAssertEqual(back.limitsPassed, false)
    XCTAssertEqual(back.limitsViolations, ["steps 4 > 3"])
    XCTAssertEqual(back.verifierPassed, true)
    XCTAssertEqual(back.graderCostUSD, 0.003)
    XCTAssertEqual(back.sessionId, "S1")
    XCTAssertEqual(back.runId, "R1")
    XCTAssertEqual(back.promptTokens, 100)
    XCTAssertEqual(back.completionTokens, 20)
    XCTAssertEqual(back.stopReason, "completed")
    XCTAssertEqual(back.passed, false)
    XCTAssertFalse(back.isPass, "the graded verdict outranks the check")
  }

  // MARK: Rubric judge

  func testRubricPassesOnAValidReplyAtOrAboveThreshold() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.judgeReply(score: 0.9, pass: true, notes: "both met")]
    let result = try await RubricJudge.grade(
      task: Self.rubricTask(), evidence: Self.evidence, model: "judge/model",
      profile: Self.judgeProfile, service: mock, costOf: Self.neverCharged)
    XCTAssertTrue(result.passed)
    XCTAssertFalse(result.unknown)
    XCTAssertEqual(result.score, 0.9, accuracy: 0.0001)
    XCTAssertEqual(result.notes, "both met")
    XCTAssertEqual(result.criteria, [RubricResult.Criterion(criterion: "c1", met: true)])
    XCTAssertEqual(result.costUSD, 0.002, accuracy: 0.00001)
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testRubricFailsWhenPassIsTrueButScoreIsBelowThreshold() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.judgeReply(score: 0.5, pass: true)]
    let result = try await RubricJudge.grade(
      task: Self.rubricTask(threshold: 0.7), evidence: Self.evidence, model: "judge/model",
      profile: Self.judgeProfile, service: mock, costOf: Self.neverCharged)
    XCTAssertFalse(result.passed)
    XCTAssertFalse(result.unknown)
    XCTAssertEqual(result.score, 0.5, accuracy: 0.0001)
  }

  func testRubricUnknownIsNeverAPassAndTheScoreIsClamped() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.judgeReply(score: 1.7, pass: true, unknown: true, notes: "cannot see the file")]
    let result = try await RubricJudge.grade(
      task: Self.rubricTask(), evidence: Self.evidence, model: "judge/model",
      profile: Self.judgeProfile, service: mock, costOf: Self.neverCharged)
    XCTAssertFalse(result.passed)
    XCTAssertTrue(result.unknown)
    XCTAssertEqual(result.score, 1.0, "clamped to 0…1 in code")
    XCTAssertEqual(result.notes, "cannot see the file")
  }

  /// One correction, then `unknown` — with the spend of both attempts booked.
  func testRubricInvalidRepliesBecomeUnknownWithCostBooked() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Fixtures.textResponse("I think it passed.", cost: 0.001),
      Fixtures.textResponse(#"{"score": "high"}"#, cost: 0.001),
    ]
    let result = try await RubricJudge.grade(
      task: Self.rubricTask(), evidence: Self.evidence, model: "judge/model",
      profile: Self.judgeProfile, service: mock, costOf: Self.neverCharged)
    XCTAssertTrue(result.unknown)
    XCTAssertFalse(result.passed)
    XCTAssertEqual(result.score, 0)
    XCTAssertTrue(result.notes.hasPrefix("judge reply invalid:"), result.notes)
    XCTAssertEqual(result.costUSD, 0.002, accuracy: 0.00001)
    XCTAssertEqual(mock.requests.count, 2, "maxRetries 1: two attempts, never a third")
  }

  func testRubricTransportErrorThrows() async {
    let mock = MockOpenRouterService() // no scripted reply → the mock throws
    do {
      _ = try await RubricJudge.grade(
        task: Self.rubricTask(), evidence: Self.evidence, model: "judge/model",
        profile: Self.judgeProfile, service: mock, costOf: Self.neverCharged)
      XCTFail("a transport error must throw (the runner turns it into unknown)")
    } catch {
      // expected
    }
  }

  /// The judge sees the evidence and nothing else: no `.tool` message, no tool-call arguments,
  /// the criteria numbered, the diff and the check verdict present.
  func testJudgeRequestCarriesEvidenceOnlyAndNeverTheTranscript() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.judgeReply(score: 1, pass: true)]
    let evidence = RubricJudge.Evidence(
      report: "created hello.txt", diff: "+hello", checkPassed: false,
      checkOutput: "cat: hello.txt: No such file")
    _ = try await RubricJudge.grade(
      task: Self.rubricTask(), evidence: evidence, model: "judge/model",
      profile: Self.judgeProfile, service: mock, costOf: Self.neverCharged)
    let request = try XCTUnwrap(mock.requests.last)
    XCTAssertEqual(request.messages.map(\.role), [.system, .user])
    XCTAssertFalse(request.messages.contains { $0.role == .tool })
    XCTAssertTrue(request.messages.allSatisfy { ($0.toolCalls ?? []).isEmpty })
    XCTAssertNil(request.tools)
    let user = try XCTUnwrap(request.messages[1].content?.plainText)
    XCTAssertTrue(user.contains("1. hello.txt exists"))
    XCTAssertTrue(user.contains("2. it says hello"))
    XCTAssertTrue(user.contains("make hello.txt"))
    XCTAssertTrue(user.contains("created hello.txt"))
    XCTAssertTrue(user.contains("+hello"))
    XCTAssertTrue(user.contains("Programmatic check: FAILED"))
    XCTAssertTrue(user.contains("No such file"))
    XCTAssertFalse(user.contains("write_file"), "no tool call of the agent's reaches the judge")
    // The judge's profile advertises no response_format: the schema rides the prompt.
    XCTAssertNil(request.responseFormat)
    XCTAssertTrue(user.contains("Reply with only a JSON object matching this schema"))
  }

  func testJudgeUsesResponseFormatOnlyWhenTheProfileAdvertisesIt() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.judgeReply(score: 1, pass: true)]
    _ = try await RubricJudge.grade(
      task: Self.rubricTask(), evidence: Self.evidence, model: "judge/strict",
      profile: Self.structuredJudgeProfile(), service: mock, costOf: Self.neverCharged)
    let request = try XCTUnwrap(mock.requests.last)
    XCTAssertEqual(Fixtures.jsonValue(request.responseFormat)["type"], "json_schema")
    XCTAssertEqual(
      Fixtures.jsonValue(request.responseFormat)["json_schema"]?["schema"], RubricJudge.schema)
    let user = try XCTUnwrap(request.messages[1].content?.plainText)
    XCTAssertFalse(user.contains("Reply with only a JSON object"))
  }

  func testUserTextClipsTheDiffAndTheCheckOutput() {
    let longDiff = String(repeating: "x", count: RubricJudge.maxDiffChars + 500)
    let longOutput = String(repeating: "y", count: RubricJudge.maxCheckOutputChars + 100)
    let text = RubricJudge.userText(
      task: Self.rubricTask(),
      evidence: RubricJudge.Evidence(report: "r", diff: longDiff, checkPassed: true, checkOutput: longOutput))
    XCTAssertTrue(text.contains("[diff truncated, 500 more chars"))
    XCTAssertFalse(text.contains(String(repeating: "y", count: RubricJudge.maxCheckOutputChars + 1)))
    let empty = RubricJudge.userText(
      task: Self.rubricTask(),
      evidence: RubricJudge.Evidence(report: "r", diff: "", checkPassed: true, checkOutput: ""))
    XCTAssertTrue(empty.contains("(no changes to the working directory)"))
    XCTAssertTrue(empty.contains("Check output:\n(none)"))
  }

  /// The schema is in the strict subset: every object closed, every property required.
  func testRubricSchemaIsStrictSubset() throws {
    let schema = try OutputSchema(schema: RubricJudge.schema)
    XCTAssertEqual(schema.schema["additionalProperties"], false)
    XCTAssertEqual(
      Set(schema.schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []),
      Set(schema.schema["properties"]?.objectValue?.keys.map { $0 } ?? []))
    let item = schema.schema["properties"]?["criteria"]?["items"]
    XCTAssertEqual(item?["additionalProperties"], false)
    XCTAssertEqual(Set(item?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []), ["criterion", "met"])
    // A valid reply validates; `met: null` does not.
    XCTAssertTrue(JSONSchemaLite.validate(
      ["score": 0.5, "pass": false, "unknown": false, "notes": "", "criteria": [["criterion": "a", "met": false]]],
      against: RubricJudge.schema).isEmpty)
    XCTAssertFalse(JSONSchemaLite.validate(
      ["score": 0.5, "pass": false, "unknown": true, "notes": "", "criteria": [["criterion": "a", "met": nil]]],
      against: RubricJudge.schema).isEmpty)
  }

  // MARK: Limits grader

  func testLimitsGraderTable() {
    func grade(_ limits: EvalTask.Limits, _ record: RunRecord) -> [String] {
      LimitsGrader.evaluate(record: record, limits: limits).violations
    }
    // Nothing declared → nothing violated.
    XCTAssertTrue(LimitsGrader.evaluate(record: record(), limits: EvalTask.Limits()).passed)
    // Steps.
    XCTAssertEqual(grade(EvalTask.Limits(maxSteps: 6), record(steps: 9)), ["steps 9 > 6"])
    XCTAssertEqual(grade(EvalTask.Limits(maxSteps: 6), record(steps: 6)), [])
    XCTAssertEqual(
      grade(EvalTask.Limits(maxSteps: 6), record(steps: 6, stop: .maxSteps)),
      ["stopped by the step cap (max_steps)"])
    // A max_steps stop with no step limit declared is not this grader's business.
    XCTAssertEqual(grade(EvalTask.Limits(maxToolCalls: 10), record(steps: 30, stop: .maxSteps)), [])
    // A max_steps stop *below* the task's cap was the runner's lower `--max-steps`, not this
    // limit's failure (a task asking for 6 run under --max-steps 3 stops at 3).
    XCTAssertEqual(grade(EvalTask.Limits(maxSteps: 6), record(steps: 3, stop: .maxSteps)), [])
    // Tool calls.
    XCTAssertEqual(grade(EvalTask.Limits(maxToolCalls: 2), record(toolCalls: 5)), ["tool calls 5 > 2"])
    // Cost.
    XCTAssertEqual(grade(EvalTask.Limits(maxCostUSD: 0.05), record(cost: 0.0625)), ["cost $0.0625 > $0.0500"])
    XCTAssertEqual(
      grade(EvalTask.Limits(maxCostUSD: 0.05), record(cost: 0.05, stop: .budget)),
      ["stopped by the cost cap (budget)"])
    // Forbidden / required tools read the per-tool counts.
    let stats = record(stats: ["bash": 2, "read_file": 1])
    XCTAssertEqual(grade(EvalTask.Limits(forbiddenTools: ["bash"]), stats), ["forbidden tool bash called 2×"])
    XCTAssertEqual(grade(EvalTask.Limits(forbiddenTools: ["edit_file"]), stats), [])
    XCTAssertEqual(grade(EvalTask.Limits(requiredTools: ["edit_file"]), stats), ["required tool edit_file never called"])
    XCTAssertEqual(grade(EvalTask.Limits(requiredTools: ["read_file"]), stats), [])
    // A record with no stats at all: required missing, forbidden fine.
    XCTAssertEqual(
      grade(EvalTask.Limits(forbiddenTools: ["bash"], requiredTools: ["glob"]), record()),
      ["required tool glob never called"])
    // Several at once, in a fixed order.
    let many = grade(
      EvalTask.Limits(maxSteps: 1, maxToolCalls: 1, maxCostUSD: 0.001, forbiddenTools: ["bash"]),
      record(steps: 3, toolCalls: 2, cost: 0.01, stats: ["bash": 1]))
    XCTAssertEqual(many, ["steps 3 > 1", "tool calls 2 > 1", "cost $0.0100 > $0.0010", "forbidden tool bash called 1×"])
    // Unknown names against a toolset.
    let available: Set<String> = ["read_file", "bash", "task"]
    XCTAssertEqual(
      LimitsGrader.unknownTools(
        in: EvalTask.Limits(forbiddenTools: ["bash", "edit_fil"], requiredTools: ["read_file", "wirte"]),
        available: available),
      ["edit_fil", "wirte"])
  }

  // MARK: Graded verdict

  func testPassedCombinesCheckAndGatedGraders() {
    let plain = EvalTask(id: "t", prompt: "p", check: "true")
    XCTAssertNil(EvalOutcome.gradedVerdict(task: plain, checkPassed: true, rubricPassed: nil, limitsPassed: nil))
    XCTAssertNil(EvalOutcome.gradedVerdict(task: plain, checkPassed: false, rubricPassed: nil, limitsPassed: nil))
    // verify alone never grades: the verifier is recorded, not gating.
    let verifyOnly = EvalTask(id: "t", prompt: "p", check: "true", verify: true)
    XCTAssertNil(EvalOutcome.gradedVerdict(task: verifyOnly, checkPassed: true, rubricPassed: nil, limitsPassed: nil))

    // A rubric that does not gate records its verdict and keeps passed == checkPassed.
    let recorded = Self.rubricTask(gate: false)
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: recorded, checkPassed: true, rubricPassed: false, limitsPassed: nil), true)
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: recorded, checkPassed: false, rubricPassed: true, limitsPassed: nil), false)
    // A gating rubric (the default) fails the trial on a miss, on unknown, and when it never ran.
    let gated = Self.rubricTask()
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: gated, checkPassed: true, rubricPassed: true, limitsPassed: nil), true)
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: gated, checkPassed: true, rubricPassed: false, limitsPassed: nil), false)
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: gated, checkPassed: true, rubricPassed: nil, limitsPassed: nil), false)
    // The check is the ground truth: a rubric pass never rescues a failed check.
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: gated, checkPassed: false, rubricPassed: true, limitsPassed: nil), false)
    // Limits gate only when asked; a run with no record is not a violation.
    let limitsRecorded = EvalTask(id: "t", prompt: "p", check: "true", limits: EvalTask.Limits(maxSteps: 2))
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: limitsRecorded, checkPassed: true, rubricPassed: nil, limitsPassed: false), true)
    let limitsGated = EvalTask(id: "t", prompt: "p", check: "true", limits: EvalTask.Limits(maxSteps: 2, gate: true))
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: limitsGated, checkPassed: true, rubricPassed: nil, limitsPassed: false), false)
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: limitsGated, checkPassed: true, rubricPassed: nil, limitsPassed: true), true)
    XCTAssertEqual(EvalOutcome.gradedVerdict(task: limitsGated, checkPassed: true, rubricPassed: nil, limitsPassed: nil), true)

    // isPass: the graded verdict when there is one, else the check.
    func row(_ model: String, check: Bool, passed: Bool?) -> EvalOutcome {
      EvalOutcome(
        suite: "s", taskId: "t", model: model, trial: 1, checkPassed: check, agentFinished: true,
        steps: 1, toolCalls: 0, costUSD: 0.01, durationSeconds: 1, startedAt: Date(), routedModels: [],
        passed: passed)
    }
    XCTAssertTrue(row("m", check: true, passed: nil).isPass)
    XCTAssertFalse(row("m", check: true, passed: false).isPass)
    XCTAssertFalse(row("m", check: false, passed: nil).isPass)

    // Both aggregations count isPass: graded and ungraded rows mixed.
    let rows = [
      row("a", check: true, passed: nil),    // ungraded pass
      row("a", check: true, passed: false),  // check passed, rubric failed
      row("a", check: false, passed: nil),   // ungraded fail
      row("b", check: true, passed: true),
    ]
    let stats = EvalStats.aggregate(rows)
    XCTAssertEqual(stats.first { $0.model == "a" }?.passed, 1)
    XCTAssertEqual(stats.first { $0.model == "a" }?.trials, 3)
    XCTAssertEqual(stats.first { $0.model == "b" }?.passed, 1)
    let history = EvalHistoryRow.aggregate(rows)
    XCTAssertEqual(history.first { $0.model == "a" }?.passed, 1)
    XCTAssertEqual(history.first { $0.model == "b" }?.passRate, 1.0)
  }

  // MARK: Store

  func testRewriteReturnsTheRemovedRows() throws {
    let store = EvalStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-evals-x4-\(UUID().uuidString).jsonl"))
    func row(_ suite: String, session: String?) -> EvalOutcome {
      EvalOutcome(
        suite: suite, taskId: "t", model: "m", trial: 1, checkPassed: true, agentFinished: true,
        steps: 1, toolCalls: 0, costUSD: 0, durationSeconds: 1, startedAt: Date(), routedModels: [],
        sessionId: session)
    }
    try store.append(row("keep", session: "K"))
    try store.append(row("drop", session: "D1"))
    try store.append(row("drop", session: nil))
    let result = try store.rewrite { $0.suite == "keep" }
    XCTAssertEqual(result.kept, 1)
    XCTAssertEqual(result.removed, 2)
    XCTAssertEqual(result.removedRows.compactMap(\.sessionId), ["D1"])
    XCTAssertEqual(try store.all().map(\.suite), ["keep"])
  }

  func testRubricWithNothingToJudgeOrAnImpossibleThresholdIsATaskError() {
    XCTAssertEqual(EvalRunner.rubricProblem(EvalTask.Rubric(criteria: [])), "no criteria")
    XCTAssertEqual(EvalRunner.rubricProblem(EvalTask.Rubric(criteria: ["  ", ""])), "no criteria")
    XCTAssertEqual(
      EvalRunner.rubricProblem(EvalTask.Rubric(criteria: ["a"], threshold: 1.5)),
      "threshold 1.5 is not between 0 and 1")
    XCTAssertEqual(
      EvalRunner.rubricProblem(EvalTask.Rubric(criteria: ["a"], threshold: -0.1)),
      "threshold -0.1 is not between 0 and 1")
    XCTAssertNil(EvalRunner.rubricProblem(EvalTask.Rubric(criteria: ["a"])))
    XCTAssertNil(EvalRunner.rubricProblem(EvalTask.Rubric(criteria: ["a"], threshold: 1)))
    XCTAssertNil(EvalRunner.rubricProblem(EvalTask.Rubric(criteria: ["a"], threshold: 0)))
  }
}
