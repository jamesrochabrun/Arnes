import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The jev (decisions) grader: the `jev` task key, the fold across repeats, the rubric
/// bridge, the runner wiring (gate, unknown, repeats, second judge) — all over the mock's
/// scriptable `decide`, no network.
final class EvalJevJudgeTests: XCTestCase {
  // MARK: Fixtures

  private static let evidence = RubricJudge.Evidence(
    report: "I fixed it",
    diff: "diff -ruN base/f.txt candidate/f.txt\n+world",
    checkPassed: true,
    checkOutput: "ok")

  private static func task(jev: EvalTask.Jev? = nil, rubric: EvalTask.Rubric? = nil) -> EvalTask {
    EvalTask(id: "t", prompt: "fix f.txt", check: "true", rubric: rubric, jev: jev)
  }

  private static func noulJev(
    min: Double = 0.7, repeats: Int? = nil, gate: Bool? = nil, threshold: Double? = nil)
    -> EvalTask.Jev
  {
    EvalTask.Jev(
      questions: ["grounded": .init(
        type: .noul, instructions: "The report matches the diff.",
        expect: .init(min: min))],
      gate: gate, repeats: repeats, threshold: threshold)
  }

  private func tempStores() -> (EvalStore, RunRecordStore) {
    let base = FileManager.default.temporaryDirectory
    return (
      EvalStore(url: base.appendingPathComponent("arnes-evals-\(UUID().uuidString).jsonl")),
      RunRecordStore(url: base.appendingPathComponent("arnes-eval-runs-\(UUID().uuidString).jsonl")))
  }

  private func writeFileScript(_ mock: MockOpenRouterService, manifest: String...) {
    mock.manifestJSON = Fixtures.manifest(
      ([Fixtures.manifestModel(id: "test/model")] + manifest).joined(separator: ","))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(
          id: "c1", name: "write_file",
          arguments: #"{"path": "hello.txt", "content": "hello"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("created hello.txt"), Fixtures.usageChunk(cost: 0.01)],
    ]
  }

  // MARK: Task file

  /// The shipped jev suite decodes; a task with every jev key round-trips; the two criteria
  /// wire shapes both parse; defaults where the file says nothing.
  func testJevTaskDecodesWithBothCriteriaShapesAndDefaults() throws {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let suite = try EvalSuite.load(path: root.appendingPathComponent("evals/jev").path)
    XCTAssertEqual(suite.tasks.map(\.id), ["add-docstring-jev", "rename-constant-bridge", "explain-fix-variance"])
    XCTAssertEqual(suite.tasks[0].jev?.questions.count, 3)
    XCTAssertNil(suite.tasks[1].jev, "the bridge task declares a plain rubric")
    XCTAssertNotNil(suite.tasks[1].rubric)
    XCTAssertEqual(suite.tasks[2].jev?.repeats, 3)
    XCTAssertNil(suite.tasks[2].jev?.questions["report_brevity"]?.expect, "recorded only")

    let json = """
      {"id":"j","prompt":"p","check":"true",
       "jev":{"model":"typesafe/jev-1.13","gate":false,"repeats":3,"threshold":0.5,
              "questions":{
                "q1":{"type":"noul","instructions":"i1","expect":{"min":0.6,"max":0.9}},
                "q2":{"type":"choice","instructions":"i2",
                      "criteria":{"a":"first","b":"second"},"expect":{"choice":"a"}},
                "q3":{"type":"score","instructions":"i3","criteria":["low","high"]}}}}
      """
    let task = try JSONDecoder().decode(EvalTask.self, from: Data(json.utf8))
    let jev = try XCTUnwrap(task.jev)
    XCTAssertEqual(jev.model, "typesafe/jev-1.13")
    XCTAssertEqual(jev.gates, false)
    XCTAssertEqual(jev.repeats, 3)
    XCTAssertEqual(jev.effectiveThreshold, 0.5)
    XCTAssertEqual(jev.questions["q1"]?.type, .noul)
    XCTAssertEqual(jev.questions["q1"]?.expect, EvalTask.Jev.Expectation(min: 0.6, max: 0.9))
    guard case .labeled(let options)? = jev.questions["q2"]?.criteria else {
      return XCTFail("choice criteria should parse as labeled options")
    }
    XCTAssertEqual(options, ["a": "first", "b": "second"])
    guard case .levels(let levels)? = jev.questions["q3"]?.criteria else {
      return XCTFail("score criteria should parse as ordered levels")
    }
    XCTAssertEqual(levels, ["low", "high"])
    // Defaults where the file says nothing.
    let bare = EvalTask.Jev(questions: [:])
    XCTAssertTrue(bare.gates)
    XCTAssertEqual(bare.effectiveThreshold, 1.0)
  }

  /// A pre-jev row decodes with every new field nil and re-encodes without adding a key;
  /// a full row round-trips.
  func testEvalOutcomeOldRowLeavesJevFieldsNilAndNewFieldsRoundTrip() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let old = """
      {"suite":"basics","taskId":"create-file","model":"m","trial":1,"checkPassed":true,"agentFinished":true,"steps":2,"toolCalls":1,"costUSD":0.01,"durationSeconds":1.5,"startedAt":"2026-01-01T00:00:00Z","routedModels":["m"]}
      """
    let row = try decoder.decode(EvalOutcome.self, from: Data(old.utf8))
    XCTAssertNil(row.judgeModel)
    XCTAssertNil(row.jevScore)
    XCTAssertNil(row.jevPassed)
    XCTAssertNil(row.jevUnknown)
    XCTAssertNil(row.jevNotes)
    XCTAssertNil(row.jevRepeats)
    XCTAssertNil(row.jevVariance)
    XCTAssertNil(row.jevQuestions)
    XCTAssertNil(row.secondJudgeModel)
    XCTAssertNil(row.secondRubricScore)
    XCTAssertNil(row.secondRubricPassed)
    XCTAssertNil(row.secondRubricUnknown)

    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let reencoded = try JSONSerialization.jsonObject(with: try encoder.encode(row)) as? [String: Any]
    XCTAssertNil(reencoded?["jevScore"])
    XCTAssertNil(reencoded?["judgeModel"])
    XCTAssertNil(reencoded?["jevQuestions"])

    let full = EvalOutcome(
      suite: "s", taskId: "t", model: "m", trial: 1, checkPassed: true, agentFinished: true,
      steps: 2, toolCalls: 1, costUSD: 0.01, durationSeconds: 1, startedAt: Date(timeIntervalSince1970: 1000),
      routedModels: ["m"],
      judgeModel: "typesafe/jev-1.13", jevScore: 0.5, jevPassed: false, jevUnknown: false,
      jevNotes: "grounded: mean 0.42 < min 0.70", jevRepeats: 3, jevVariance: 0.01,
      jevQuestions: [JevQuestionRecord(name: "grounded", kind: "noul", mean: 0.42, variance: 0.01, passed: false)],
      secondJudgeModel: "judge/llm", secondRubricScore: 0.9, secondRubricPassed: true,
      secondRubricUnknown: false)
    let back = try decoder.decode(EvalOutcome.self, from: try encoder.encode(full))
    XCTAssertEqual(back.judgeModel, "typesafe/jev-1.13")
    XCTAssertEqual(back.jevScore, 0.5)
    XCTAssertEqual(back.jevPassed, false)
    XCTAssertEqual(back.jevRepeats, 3)
    XCTAssertEqual(back.jevVariance, 0.01)
    XCTAssertEqual(back.jevQuestions, full.jevQuestions)
    XCTAssertEqual(back.secondJudgeModel, "judge/llm")
    XCTAssertEqual(back.secondRubricPassed, true)
  }

  // MARK: The fold

  /// Means, n−1 variance, and the expectation table across three repeats — checked against
  /// the mean, so the verdict is deterministic.
  func testFoldMeansVarianceAndExpectations() {
    let jev = Self.noulJev(min: 0.7)
    let responses = [0.9, 0.6, 0.9].map { Fixtures.noulDecision(values: ["grounded": $0]) }
    let result = JevJudge.fold(responses, jev: jev)
    XCTAssertFalse(result.unknown)
    XCTAssertEqual(result.repeats, 3)
    let question = try! XCTUnwrap(result.questions.first)
    XCTAssertEqual(question.mean, 0.8, accuracy: 0.0001)
    XCTAssertEqual(try! XCTUnwrap(question.variance), 0.03, accuracy: 0.0001)
    XCTAssertEqual(question.passed, true, "the mean 0.8 clears min 0.7 though one repeat missed")
    XCTAssertEqual(result.score, 1)
    XCTAssertTrue(result.passed)
    // Per-repeat scores were 1, 0, 1 — their sample variance is 1/3.
    XCTAssertEqual(try! XCTUnwrap(result.scoreVariance), 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(result.costUSD, 0.00006, accuracy: 0.0000001)
    XCTAssertEqual(result.promptTokens, 300)

    // A single repeat records no variance.
    let single = JevJudge.fold([Fixtures.noulDecision(values: ["grounded": 0.9])], jev: jev)
    XCTAssertNil(single.questions.first?.variance)
    XCTAssertNil(single.scoreVariance)
    XCTAssertEqual(single.repeats, 1)

    // max bounds fail high means; misses are named in the notes.
    let capped = EvalTask.Jev(
      questions: ["cheated": .init(type: .noul, instructions: "i", expect: .init(max: 0.3))])
    let missed = JevJudge.fold([Fixtures.noulDecision(values: ["cheated": 0.8])], jev: capped)
    XCTAssertEqual(missed.questions.first?.passed, false)
    XCTAssertEqual(missed.score, 0)
    XCTAssertFalse(missed.passed)
    XCTAssertTrue(missed.notes.contains("cheated: mean 0.80 > max 0.30"), missed.notes)
  }

  /// Choice: the expected key must win the modal pick and clear `min` on its mean
  /// probability; without an expected key the modal pick is the target. Score: the mean
  /// expected level against the bounds. A question without `expect` is recorded, never
  /// counted.
  func testFoldChoiceScoreAndRecordedOnlyQuestions() {
    let response = Fixtures.decisionResponse(Self.liveShapedReply)
    let jev = EvalTask.Jev(
      questions: [
        "department": .init(
          type: .choice, instructions: "which team",
          criteria: .labeled(["billing": "b", "technical": "t", "sales": "s"]),
          expect: .init(min: 0.6, choice: "billing")),
        "frustration": .init(
          type: .score, instructions: "how angry",
          criteria: .levels(["Calm", "Frustrated", "Very angry"]),
          expect: .init(max: 1.5)),
        "is_urgent": .init(type: .noul, instructions: "urgent?"),
      ])
    let result = JevJudge.fold([response], jev: jev)
    XCTAssertFalse(result.unknown)
    let byName = Dictionary(uniqueKeysWithValues: result.questions.map { ($0.name, $0) })
    XCTAssertEqual(byName["department"]?.choice, "billing")
    XCTAssertEqual(byName["department"]?.mean ?? 0, 0.87, accuracy: 0.0001)
    XCTAssertEqual(byName["department"]?.passed, true)
    XCTAssertEqual(byName["frustration"]?.mean ?? 0, 1.03, accuracy: 0.0001)
    XCTAssertEqual(byName["frustration"]?.passed, true)
    XCTAssertNil(byName["is_urgent"]?.passed, "no expect: recorded only")
    XCTAssertEqual(byName["is_urgent"]?.mean ?? 0, 0.95, accuracy: 0.0001)
    XCTAssertEqual(result.score, 1, "two expected questions held; the recorded one never counts")

    // The wrong winner fails the expected key even with a probability above min.
    let wrongWinner = EvalTask.Jev(
      questions: ["department": .init(
        type: .choice, instructions: "which team",
        criteria: .labeled(["billing": "b", "technical": "t", "sales": "s"]),
        expect: .init(choice: "technical"))])
    let missed = JevJudge.fold([response], jev: wrongWinner)
    XCTAssertEqual(missed.questions.first?.passed, false)
    XCTAssertTrue(missed.notes.contains("chose 'billing', expected 'technical'"), missed.notes)
  }

  /// A response missing an answer — or carrying the wrong shape for the question — is an
  /// unknown verdict with the spend kept, never a crash or a partial fold.
  func testFoldMissingOrMisshapenAnswerIsUnknown() {
    let jev = Self.noulJev()
    let empty = Fixtures.decisionResponse(#"{"model":"typesafe/jev-1.13","answers":{},"usage":{"cost":0.00002}}"#)
    let missing = JevJudge.fold([empty], jev: jev)
    XCTAssertTrue(missing.unknown)
    XCTAssertFalse(missing.passed)
    XCTAssertTrue(missing.notes.contains("no answer for 'grounded'"), missing.notes)
    XCTAssertEqual(missing.costUSD, 0.00002, accuracy: 0.0000001)

    let wrongShape = Fixtures.decisionResponse(
      #"{"model":"typesafe/jev-1.13","answers":{"grounded":{"type":"choice","choice":"a"}}}"#)
    let misshapen = JevJudge.fold([wrongShape], jev: jev)
    XCTAssertTrue(misshapen.unknown)
    XCTAssertTrue(misshapen.notes.contains("no noul value"), misshapen.notes)
  }

  // MARK: State and bridge questions

  /// The state is the rubric judge's evidence as typed fields — same clip caps, never the
  /// transcript.
  func testStateCarriesClippedEvidenceOnly() throws {
    let longDiff = String(repeating: "x", count: RubricJudge.maxDiffChars + 500)
    let longOutput = String(repeating: "y", count: RubricJudge.maxCheckOutputChars + 500)
    let state = JevJudge.state(
      task: Self.task(),
      evidence: RubricJudge.Evidence(report: "r", diff: longDiff, checkPassed: false, checkOutput: longOutput))
    guard case .object(let fields) = state else { return XCTFail("state should be an object") }
    XCTAssertEqual(Set(fields.keys), ["task", "report", "diff", "check_passed", "check_output"])
    XCTAssertEqual(fields["task"], .string("fix f.txt"))
    XCTAssertEqual(fields["check_passed"], .bool(false))
    guard case .string(let diff)? = fields["diff"] else { return XCTFail("diff should be a string") }
    XCTAssertLessThan(diff.count, RubricJudge.maxDiffChars + 100)
    XCTAssertTrue(diff.contains("truncated"), "the clip is announced, like the rubric judge's")
    guard case .string(let output)? = fields["check_output"] else { return XCTFail() }
    XCTAssertEqual(output.count, RubricJudge.maxCheckOutputChars)

    let emptyDiff = JevJudge.state(task: Self.task(), evidence: RubricJudge.Evidence(
      report: "r", diff: "", checkPassed: true, checkOutput: ""))
    guard case .object(let quiet) = emptyDiff else { return XCTFail() }
    XCTAssertEqual(quiet["diff"], .string("(no changes to the working directory)"))
  }

  /// Criteria → noul questions keyed `c1`…`cN` in order, blanks skipped.
  func testBridgedQuestions() {
    let questions = JevJudge.bridgedQuestions(criteria: ["first thing", "  ", "second thing"])
    XCTAssertEqual(Set(questions.keys), ["c1", "c2"])
    XCTAssertEqual(questions["c1"]?.type, .noul)
    XCTAssertEqual(questions["c1"]?.instructions, "first thing")
    XCTAssertEqual(questions["c2"]?.instructions, "second thing")
  }

  // MARK: Pre-flight refusals

  func testJevProblemTable() {
    func problem(_ jev: EvalTask.Jev) -> String? { EvalRunner.jevProblem(jev) }
    XCTAssertEqual(problem(EvalTask.Jev(questions: [:])), "no questions")
    // A gating block where nothing is expected would pass vacuously.
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .noul, instructions: "i")]))?.contains("no expectations") == true)
    XCTAssertNil(problem(EvalTask.Jev(
      questions: ["q": .init(type: .noul, instructions: "i")], gate: false)), "recording only is fine")
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .noul, instructions: "  ", expect: .init(min: 0.5))]))?
      .contains("no instructions") == true)
    // Score needs 2–10 ordered levels.
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .score, instructions: "i", criteria: .levels(["only"]),
                             expect: .init(min: 0.5))]))?.contains("2–10") == true)
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .score, instructions: "i",
                             criteria: .levels((1...11).map(String.init)),
                             expect: .init(min: 0.5))]))?.contains("2–10") == true)
    // Choice needs at least two options, and the expected key must be one of them.
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .choice, instructions: "i", criteria: .labeled(["a": "x"]),
                             expect: .init(choice: "a"))]))?.contains("at least 2") == true)
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .choice, instructions: "i",
                             criteria: .labeled(["a": "x", "b": "y"]),
                             expect: .init(choice: "c"))]))?.contains("not one of its options") == true)
    // noul bounds live in 0…1 and must not cross; a choice expectation needs a choice question.
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .noul, instructions: "i", expect: .init(min: 1.5))]))?
      .contains("not between 0 and 1") == true)
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .noul, instructions: "i", expect: .init(min: 0.8, max: 0.2))]))?
      .contains("above max") == true)
    XCTAssertTrue(problem(EvalTask.Jev(
      questions: ["q": .init(type: .noul, instructions: "i", expect: .init(choice: "a"))]))?
      .contains("not a choice question") == true)
    // A score expectation bounds the level, not a probability — 1.5 is fine there.
    XCTAssertNil(problem(EvalTask.Jev(
      questions: ["q": .init(type: .score, instructions: "i", criteria: .levels(["a", "b", "c"]),
                             expect: .init(min: 1.5))])))
    XCTAssertTrue(problem(Self.noulJev(repeats: 10))?.contains("repeats") == true)
    XCTAssertTrue(problem(Self.noulJev(threshold: 1.5))?.contains("threshold") == true)
    XCTAssertNil(problem(Self.noulJev(repeats: 3, threshold: 0.5)))
  }

  // MARK: The graded verdict

  func testGradedVerdictWithJev() {
    let gated = Self.task(jev: Self.noulJev())
    XCTAssertEqual(EvalOutcome.gradedVerdict(
      task: gated, checkPassed: true, rubricPassed: nil, limitsPassed: nil, jevPassed: true), true)
    XCTAssertEqual(EvalOutcome.gradedVerdict(
      task: gated, checkPassed: true, rubricPassed: nil, limitsPassed: nil, jevPassed: false), false)
    XCTAssertEqual(
      EvalOutcome.gradedVerdict(
        task: gated, checkPassed: true, rubricPassed: nil, limitsPassed: nil, jevPassed: nil),
      false, "an unknown jev verdict never passes a gated task")
    XCTAssertEqual(EvalOutcome.gradedVerdict(
      task: gated, checkPassed: false, rubricPassed: nil, limitsPassed: nil, jevPassed: true),
      false, "the check stays the ground truth")
    let recorded = Self.task(jev: Self.noulJev(gate: false))
    XCTAssertEqual(EvalOutcome.gradedVerdict(
      task: recorded, checkPassed: true, rubricPassed: nil, limitsPassed: nil, jevPassed: false),
      true, "gate: false records only")
    // The 4-argument spelling still stands and never counts a jev verdict.
    XCTAssertNil(EvalOutcome.gradedVerdict(
      task: Self.task(), checkPassed: true, rubricPassed: nil, limitsPassed: nil))
    XCTAssertEqual(EvalOutcome.gradedVerdict(
      task: gated, checkPassed: true, rubricPassed: nil, limitsPassed: nil), false)
  }

  // MARK: End-to-end trials (mock service)

  /// A jev-gated trial: the block's own model is the judge, the decisions request carries
  /// the typed state, the verdict gates, the spend books apart from the candidate's.
  func testJevTrialGradesAndBooksTheSpendApart() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.decisionResponses = [Fixtures.noulDecision(values: ["grounded": 0.9], cost: 0.00002)]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    var jev = Self.noulJev()
    jev.model = "typesafe/jev-1.13"
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "jev-graded", prompt: "make hello.txt", check: "test -e hello.txt", jev: jev),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertTrue(outcome.checkPassed)
    XCTAssertEqual(outcome.jevPassed, true)
    XCTAssertEqual(outcome.jevScore, 1)
    XCTAssertEqual(outcome.jevUnknown, false)
    XCTAssertEqual(outcome.passed, true)
    XCTAssertEqual(outcome.judgeModel, "typesafe/jev-1.13")
    XCTAssertNil(outcome.jevRepeats, "a single judgment writes no repeat fields")
    XCTAssertNil(outcome.jevVariance)
    XCTAssertEqual(outcome.jevQuestions?.count, 1)
    XCTAssertEqual(outcome.jevQuestions?.first?.name, "grounded")
    XCTAssertEqual(outcome.graderCostUSD ?? 0, 0.00002, accuracy: 0.0000001)
    XCTAssertEqual(outcome.costUSD, 0.02, accuracy: 0.0001, "the judge's spend is not the candidate's")
    // The decisions request carried the typed evidence, to the block's model.
    let request = try XCTUnwrap(mock.decisionRequests.first)
    XCTAssertEqual(request.model, "typesafe/jev-1.13")
    guard case .object(let state) = request.state else { return XCTFail("state should be an object") }
    XCTAssertEqual(state["task"], .string("make hello.txt"))
    XCTAssertEqual(state["check_passed"], .bool(true))
    guard case .string(let diff)? = state["diff"] else { return XCTFail() }
    XCTAssertTrue(diff.contains("hello.txt"), diff)
    XCTAssertEqual(request.questions["grounded"]?.type, .noul)
    XCTAssertEqual(try evalStore.all().first?.jevPassed, true)
  }

  /// A failed decisions request is `jevUnknown` — a gated fail, never a thrown trial. With
  /// no judge configured anywhere the note says so.
  func testJevJudgeFailuresAreUnknownNeverAThrownTrial() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.decisionErrors = [MockError.nativeRefusal("404 no decisions endpoint")]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, decisionJudge: "typesafe/jev-1.13")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "jev-graded", prompt: "make hello.txt", check: "test -e hello.txt", jev: Self.noulJev()),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertTrue(outcome.checkPassed)
    XCTAssertEqual(outcome.jevUnknown, true)
    XCTAssertEqual(outcome.jevPassed, false)
    XCTAssertTrue(outcome.jevNotes?.hasPrefix("judge error:") == true, outcome.jevNotes ?? "")
    XCTAssertEqual(outcome.passed, false)
    XCTAssertNil(outcome.error, "a judge failure is not a trial error")

    // No block model, no --judge, no decisions default: unknown with an actionable note.
    let bare = MockOpenRouterService()
    writeFileScript(bare)
    let bareRunner = EvalRunner(service: bare, store: evalStore, recordStore: recordStore)
    let unjudged = await bareRunner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertEqual(unjudged.jevUnknown, true)
    XCTAssertTrue(unjudged.jevNotes?.contains("no decisions judge") == true, unjudged.jevNotes ?? "")
    XCTAssertTrue(bare.decisionRequests.isEmpty, "nothing was asked")
  }

  /// `repeats: 3` consumes three responses and records the mean, the variance, and the
  /// summed spend; the runner's `--judge-repeats` is the fallback the task overrides.
  func testJevRepeatsFoldsAcrossResponses() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.decisionResponses = [0.9, 0.6, 0.9].map {
      Fixtures.noulDecision(values: ["grounded": $0], cost: 0.00002)
    }
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, decisionJudge: "typesafe/jev-1.13")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "jev-repeats", prompt: "make hello.txt", check: "test -e hello.txt",
        jev: Self.noulJev(repeats: 3)),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertEqual(mock.decisionRequests.count, 3)
    XCTAssertEqual(outcome.jevPassed, true, "the mean 0.8 clears min 0.7")
    XCTAssertEqual(outcome.jevRepeats, 3)
    XCTAssertEqual(try XCTUnwrap(outcome.jevVariance), 1.0 / 3.0, accuracy: 0.0001)
    XCTAssertEqual(try XCTUnwrap(outcome.jevQuestions?.first?.variance), 0.03, accuracy: 0.0001)
    XCTAssertEqual(outcome.graderCostUSD ?? 0, 0.00006, accuracy: 0.0000001)
  }

  /// The bridge: a `--judge` whose manifest entry says decisions grades plain rubric
  /// criteria through `decide` — the rubric fields fill as ever, zero chat side-requests.
  /// A chat judge on the same task stays on the chat path.
  func testRubricBridgeRoutesADecisionsJudgeThroughDecide() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock, manifest: Fixtures.decisionsManifestModel(id: "typesafe/jev-1.13"))
    mock.decisionResponses = [Fixtures.noulDecision(values: ["c1": 0.9, "c2": 0.2], cost: 0.00002)]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, judgeModel: "typesafe/jev-1.13")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "bridged", prompt: "make hello.txt", check: "test -e hello.txt",
        rubric: EvalTask.Rubric(criteria: ["hello.txt was created", "nothing else changed"])),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertEqual(mock.decisionRequests.count, 1)
    XCTAssertEqual(mock.requests.count, 2, "the agent's two steps — no chat judge request")
    XCTAssertEqual(outcome.judgeModel, "typesafe/jev-1.13")
    XCTAssertEqual(outcome.rubricScore ?? 0, 0.5, accuracy: 0.0001, "one criterion met at the 0.5 cut")
    XCTAssertEqual(outcome.rubricPassed, false, "0.5 misses the default 0.7 threshold")
    XCTAssertEqual(outcome.rubricUnknown, false)
    XCTAssertEqual(outcome.passed, false)
    XCTAssertEqual(outcome.jevQuestions?.count, 2, "the per-criterion means stay for audit")
    XCTAssertEqual(outcome.graderCostUSD ?? 0, 0.00002, accuracy: 0.0000001)
    // The bridged questions are the criteria verbatim, as nouls.
    let request = try XCTUnwrap(mock.decisionRequests.first)
    XCTAssertEqual(request.questions["c1"]?.instructions, "hello.txt was created")
    XCTAssertEqual(request.questions["c1"]?.type, .noul)

    // A judge the manifest doesn't mark as decisions stays on the chat path.
    let chat = MockOpenRouterService()
    writeFileScript(chat)
    chat.chatResponses = [Fixtures.textResponse(
      #"{"score": 1, "pass": true, "unknown": false, "notes": "n", "criteria": []}"#, cost: 0.002)]
    let chatRunner = EvalRunner(
      service: chat, store: evalStore, recordStore: recordStore, judgeModel: "judge/llm")
    let ungated = await chatRunner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertEqual(ungated.rubricPassed, true)
    XCTAssertTrue(chat.decisionRequests.isEmpty, "no decisions request for a chat judge")
    XCTAssertNil(ungated.jevQuestions)
  }

  /// `--second-judge`: the same evidence graded again, the second verdict recorded and never
  /// gating, both spends on `graderCostUSD`.
  func testSecondJudgeRecordsAlignmentWithoutGating() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock, manifest: Fixtures.decisionsManifestModel(id: "typesafe/jev-1.13"))
    // Primary (chat) judge passes; the second (decisions) judge fails the same evidence.
    mock.chatResponses = [Fixtures.textResponse(
      #"{"score": 1, "pass": true, "unknown": false, "notes": "n", "criteria": []}"#, cost: 0.002)]
    mock.decisionResponses = [Fixtures.noulDecision(values: ["c1": 0.1], cost: 0.00002)]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore,
      judgeModel: "judge/llm", secondJudgeModel: "typesafe/jev-1.13")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "dual", prompt: "make hello.txt", check: "test -e hello.txt",
        rubric: EvalTask.Rubric(criteria: ["hello.txt was created"])),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertEqual(outcome.rubricPassed, true)
    XCTAssertEqual(outcome.passed, true, "the second verdict never gates")
    XCTAssertEqual(outcome.judgeModel, "judge/llm")
    XCTAssertEqual(outcome.secondJudgeModel, "typesafe/jev-1.13")
    XCTAssertEqual(outcome.secondRubricPassed, false)
    XCTAssertEqual(outcome.secondRubricScore, 0)
    XCTAssertEqual(outcome.secondRubricUnknown, false)
    XCTAssertEqual(outcome.graderCostUSD ?? 0, 0.00202, accuracy: 0.0000001)
    // The pair is what JudgeAlignment aggregates.
    let alignment = JudgeAlignment.compute([outcome])
    XCTAssertEqual(alignment.count, 1)
    XCTAssertEqual(alignment[0].trials, 1)
    XCTAssertEqual(alignment[0].decided, 1)
    XCTAssertEqual(alignment[0].agreements, 0)
    XCTAssertEqual(try XCTUnwrap(alignment[0].meanAbsScoreDelta), 1, accuracy: 0.0001)
  }

  /// A jev block that cannot be judged is a task error before the agent runs — no paid
  /// request of any kind.
  func testJevPreflightProblemIsATaskError() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "bad-jev", prompt: "p", check: "true",
        jev: EvalTask.Jev(questions: [:])),
    ])
    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertEqual(outcome.error, "jev: no questions")
    XCTAssertTrue(mock.requests.isEmpty, "the agent never ran")
    XCTAssertTrue(mock.decisionRequests.isEmpty)
  }

  /// The live jev-1.13 fixture (verbatim from `arnes decide`'s capture) folds cleanly —
  /// the wire shape the grader reads is the one the API actually returns.
  func testLiveFixtureFolds() {
    let response = Fixtures.decisionResponse(Fixtures.liveDecisionFixture)
    let jev = EvalTask.Jev(
      questions: [
        "is_urgent": .init(type: .noul, instructions: "urgent?", expect: .init(min: 0.9)),
        "department": .init(
          type: .choice, instructions: "team",
          criteria: .labeled(["billing": "b", "technical": "t", "sales": "s"]),
          expect: .init(choice: "billing")),
        "frustration": .init(
          type: .score, instructions: "anger",
          criteria: .levels(["Calm", "Frustrated", "Very angry"]),
          expect: .init(min: 1.5)),
      ])
    let result = JevJudge.fold([response], jev: jev)
    XCTAssertFalse(result.unknown)
    XCTAssertEqual(result.score, 2.0 / 3.0, accuracy: 0.0001, "frustration 1.03 misses min 1.5")
    XCTAssertFalse(result.passed, "threshold defaults to every expectation")
    XCTAssertTrue(result.notes.contains("frustration"), result.notes)
    XCTAssertEqual(result.costUSD, 1.7934e-05, accuracy: 1e-9)
    XCTAssertEqual(result.promptTokens, 427)
    XCTAssertEqual(result.completionTokens, 73)
  }

  // MARK: Fixture

  /// The live fixture's shape with the same three answers (see `Fixtures.liveDecisionFixture`).
  private static let liveShapedReply = Fixtures.liveDecisionFixture
}
