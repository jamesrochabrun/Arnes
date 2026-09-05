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

  /// A trial's tools are bound to its own temp directory instead of the runner `chdir`-ing
  /// the whole process. The process CWD is shared with everything else in the program
  /// (parallel trials, an embedder on another thread), so moving it was never a per-trial
  /// isolation mechanism — the root on the `ToolContext` is.
  func testTrialResolvesRelativePathsWithoutMovingTheProcess() async throws {
    final class Sample: @unchecked Sendable {
      private let lock = NSLock()
      private var value: String?
      func record(_ path: String) { lock.withLock { if value == nil { value = path } } }
      var recorded: String? { lock.withLock { value } }
    }
    let cwdDuringRun = Sample()
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // Sampled while the agent is mid-turn: this is where a chdir would show up.
    mock.streamGate = { _ in cwdDuringRun.record(FileManager.default.currentDirectoryPath) }
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(
          id: "c1", name: "write_file",
          arguments: #"{"path": "nested/made.txt", "content": "done"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("created it"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let before = FileManager.default.currentDirectoryPath
    let suite = EvalSuite(name: "unit", tasks: [
      // The check runs in the trial directory: a relative path only resolves there if the
      // tool was root-bound.
      EvalTask(id: "nested-write", prompt: "p", check: "test \"$(cat nested/made.txt)\" = done"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertTrue(outcomes[0].checkPassed)
    XCTAssertEqual(cwdDuringRun.recorded, before, "the runner must not chdir the process")
    XCTAssertEqual(FileManager.default.currentDirectoryPath, before)
    // No sandbox builder passed: trials run unconfined and say so.
    XCTAssertEqual(outcomes[0].sandboxed, false)
  }

  func testTrialToolsAreConfinedWhenTheRunnerIsGivenASandbox() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // The trial dir is the writable root; a write to the harness's own corner of it is the
    // sandbox's call, not the permission delegate's (evals auto-approve everything).
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(
          id: "c1", name: "write_file",
          arguments: #"{"path": ".claude/settings.json", "content": "{}"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("tried"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore,
      makeSandbox: { root in ShellSandbox(writableRoots: [root]) })
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "confined", prompt: "p", check: "test ! -e .claude/settings.json"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertTrue(outcomes[0].checkPassed, "the sandbox must have refused the write")
    XCTAssertEqual(outcomes[0].sandboxed, true)
    XCTAssertEqual(try evalStore.all().first?.sandboxed, true)
  }

  /// A trial runs the user's per-call hooks with its own temp directory as `cwd`: the deny
  /// lands on the trial's record, and a file the hook writes lands in the trial directory —
  /// where the check script finds it and confirms the payload's `cwd` is that directory.
  func testTrialDenyHookRecordsHookBlocksAndRunsInTheTrialDirectory() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "bash", arguments: #"{"command":"echo made > out.txt"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("could not run it"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let stopMarker = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-eval-stop-\(UUID().uuidString).marker")
    defer { try? FileManager.default.removeItem(at: stopMarker) }
    let hooks = [
      // Relative path: lands wherever the hook's cwd is. `ARNES_CWD` is the payload's `cwd`.
      HookDefinition(
        event: .preToolUse, matcher: "bash",
        command: "printf '%s' \"$ARNES_CWD\" > hook-cwd.txt; echo 'no bash in evals' >&2; exit 2"),
      HookDefinition(event: .stop, command: "touch '\(stopMarker.path)'"),
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore, hooks: hooks)
    let suite = EvalSuite(name: "unit", tasks: [
      // Passes only if the hook ran here and its payload named this very directory
      // (compared resolved: temp paths spell /var and /private/var interchangeably).
      EvalTask(
        id: "hooked", prompt: "write out.txt",
        check: "test ! -e out.txt && test -e hook-cwd.txt && test \"$(cd \"$(cat hook-cwd.txt)\" && pwd -P)\" = \"$(pwd -P)\""),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertTrue(outcomes[0].checkPassed, "the hook ran in the trial directory and its payload said so")
    XCTAssertTrue(outcomes[0].agentFinished)
    XCTAssertNil(outcomes[0].error)
    let record = try XCTUnwrap(try recordStore.all().first)
    XCTAssertEqual(record.hookBlocks, 1)
    XCTAssertEqual(record.deniedCalls, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: stopMarker.path), "a trial's end is not the user's turn end")
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

  // MARK: X4 — graders and transcripts

  /// The write_file → "created it" script every graded trial below starts from.
  private func writeFileScript(_ mock: MockOpenRouterService) {
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
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

  private func tempTranscriptStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-eval-sessions-\(UUID().uuidString)"))
  }

  private func judgeReply(score: Double, pass: Bool, unknown: Bool = false, cost: Double = 0.002) -> ChatCompletionResponse {
    Fixtures.textResponse(
      #"{"score": \#(score), "pass": \#(pass), "unknown": \#(unknown), "notes": "n", "criteria": []}"#,
      cost: cost)
  }

  /// An ungraded trial is what it always was: no snapshot, no side request, every grader
  /// field nil — only the trajectory facts (ids, tokens, stop reason) are new.
  func testUngradedTrialHasNoGraderFieldsAndNoExtraRequests() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore,
      judgeModel: "judge/model", verifierModel: "verifier/model")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "plain", prompt: "make hello.txt", check: "test -e hello.txt"),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertTrue(outcome.checkPassed)
    XCTAssertTrue(outcome.isPass)
    XCTAssertNil(outcome.passed)
    XCTAssertNil(outcome.rubricScore)
    XCTAssertNil(outcome.rubricPassed)
    XCTAssertNil(outcome.rubricUnknown)
    XCTAssertNil(outcome.rubricNotes)
    XCTAssertNil(outcome.limitsPassed)
    XCTAssertNil(outcome.limitsViolations)
    XCTAssertNil(outcome.verifierPassed, "--verify without verify: true on the task grades nothing")
    XCTAssertNil(outcome.graderCostUSD)
    XCTAssertEqual(outcome.stopReason, "completed")
    XCTAssertNotNil(outcome.runId)
    XCTAssertNotNil(outcome.sessionId, "the join key to runs.jsonl, transcript or not")
    XCTAssertEqual(outcome.runId, try recordStore.all().first?.id)
    XCTAssertEqual(mock.requests.count, 2, "two loop steps, no judge, no verifier")
    XCTAssertTrue(sideRequests(mock).isEmpty)
  }

  /// The judge's and the verifier's requests: the loop always sends its toolset, a side
  /// request over evidence or a report never does.
  private func sideRequests(_ mock: MockOpenRouterService) -> [ChatCompletionRequest] {
    mock.requests.filter { ($0.tools ?? []).isEmpty }
  }

  func testTrialWithTranscriptStoreLeavesATranscript() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    let (evalStore, recordStore) = tempStores()
    let transcripts = tempTranscriptStore()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, transcriptStore: transcripts)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "kept", prompt: "make hello.txt", check: "test -e hello.txt"),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    let sessionId = try XCTUnwrap(outcome.sessionId)
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: transcripts.directory.appendingPathComponent("\(sessionId).jsonl").path))
    let loaded = try transcripts.load(id: sessionId)
    XCTAssertEqual(loaded.meta.origin, "eval")
    XCTAssertTrue(loaded.messages.contains { $0.role == .tool }, "the trajectory has the tool exchange")
    let markdown = try transcripts.exportMarkdown(id: sessionId)
    XCTAssertTrue(markdown.contains("write_file"))
    XCTAssertEqual(try evalStore.all().first?.sessionId, sessionId)
    XCTAssertEqual(outcome.runId, try recordStore.all().first?.id)
  }

  /// `verify: true` + a verifier model: the one non-streaming request is the verifier (V1: run
  /// by the runner over the post-setup → post-run snapshot diff, not by the trial's session),
  /// its verdict lands on the outcome, and its spend is on `graderCostUSD` — apart from
  /// `costUSD`, which stays the agent's own.
  func testVerifyTaskRunsTheVerifierWhenAModelIsGiven() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.chatResponses = [
      Fixtures.textResponse(
        #"{"pass": true, "confidence": "high", "reasons": ["the file is there"], "unmet": []}"#, cost: 0.003),
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, verifierModel: "verifier/model")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "verified", prompt: "make hello.txt", check: "test -e hello.txt", verify: true),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertEqual(outcome.verifierPassed, true)
    XCTAssertNil(outcome.passed, "the verifier is recorded, not gating")
    XCTAssertTrue(outcome.isPass)
    XCTAssertEqual(outcome.costUSD, 0.02, accuracy: 0.0001, "the agent's two steps; the verifier's spend is apart")
    XCTAssertEqual(outcome.graderCostUSD ?? 0, 0.003, accuracy: 0.0001, "the verifier's spend is grader cost")
    let side = sideRequests(mock)
    XCTAssertEqual(side.count, 1)
    XCTAssertEqual(side[0].model, "verifier/model")
    XCTAssertEqual(side[0].messages.first?.role, .system)
    let user = side[0].messages.last?.content?.plainText ?? ""
    XCTAssertTrue(user.contains("candidate/hello.txt"), "the snapshot diff reaches the verifier: \(user)")
    XCTAssertTrue(user.contains("+hello"), user)
    XCTAssertFalse(user.contains("write_file"), "never the transcript or the tool calls")
    // The session ran no verifier of its own: the record carries no verdict, the row does.
    XCTAssertNil(try recordStore.all().first?.verifierPassed)
    XCTAssertEqual(try evalStore.all().first?.verifierPassed, true)

    // The same task without a verifier model: nothing asked, nothing recorded.
    let quiet = MockOpenRouterService()
    writeFileScript(quiet)
    let quietRunner = EvalRunner(service: quiet, store: evalStore, recordStore: recordStore)
    let unverified = await quietRunner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertNil(unverified.verifierPassed)
    XCTAssertEqual(quiet.requests.count, 2)
  }

  /// The history row scores the verifier against the check (V1): over the rows it graded, how
  /// many verdicts agreed with the ground truth — a row without a verdict counts for neither.
  func testHistoryRowCountsVerifierAgreementWithTheCheck() {
    func outcome(check: Bool, verifier: Bool?, model: String = "a/one") -> EvalOutcome {
      EvalOutcome(
        suite: "s", taskId: "t", model: model, trial: 1,
        checkPassed: check, agentFinished: true, steps: 1, toolCalls: 0,
        costUSD: 0.01, durationSeconds: 1, startedAt: Date(), routedModels: [], error: nil,
        dialect: "chat", verifierPassed: verifier)
    }
    let rows = EvalHistoryRow.aggregate([
      outcome(check: true, verifier: true),    // agrees
      outcome(check: false, verifier: false),  // agrees
      outcome(check: true, verifier: false),   // the verifier was wrong
      outcome(check: true, verifier: nil),     // never verified
      outcome(check: true, verifier: nil, model: "b/two"),
    ])
    let a = try! XCTUnwrap(rows.first { $0.model == "a/one" })
    XCTAssertEqual(a.trials, 4)
    XCTAssertEqual(a.verifierVerdicts, 3)
    XCTAssertEqual(a.verifierAgreements, 2)
    XCTAssertEqual(a.verifierAgreement ?? 0, 2.0 / 3.0, accuracy: 0.0001)
    let b = try! XCTUnwrap(rows.first { $0.model == "b/two" })
    XCTAssertEqual(b.verifierVerdicts, 0)
    XCTAssertEqual(b.verifierAgreements, 0)
    XCTAssertNil(b.verifierAgreement, "no verdict → no rate, not 0 %")
  }

  /// `limits.maxSteps` caps the run itself: one step means the model's tool call is the whole
  /// turn, the record says `max_steps`, and the grader reads that as the violation.
  func testLimitsMaxStepsCapsTheRunAndGrades() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "capped", prompt: "make hello.txt", check: "test -e hello.txt",
        limits: EvalTask.Limits(maxSteps: 1, forbiddenTools: ["bash"], requiredTools: ["write_file"], gate: true)),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertEqual(outcome.steps, 1)
    XCTAssertEqual(outcome.stopReason, "max_steps")
    XCTAssertTrue(outcome.checkPassed, "the file was written on the one step")
    XCTAssertEqual(outcome.limitsPassed, false)
    XCTAssertEqual(outcome.limitsViolations, ["stopped by the step cap (max_steps)"])
    XCTAssertEqual(outcome.passed, false, "the gating limit fails the graded verdict")
    XCTAssertFalse(outcome.isPass)
    XCTAssertEqual(mock.requests.count, 1, "the agent stopped at the cap")
    XCTAssertNil(outcome.graderCostUSD)

    // Recorded, not gating: the same miss keeps passed == checkPassed.
    let recorded = MockOpenRouterService()
    writeFileScript(recorded)
    let recordedRunner = EvalRunner(service: recorded, store: evalStore, recordStore: recordStore)
    let lenient = await recordedRunner.run(
      suite: EvalSuite(name: "unit", tasks: [
        EvalTask(
          id: "noted", prompt: "make hello.txt", check: "test -e hello.txt",
          limits: EvalTask.Limits(maxToolCalls: 0)),
      ]),
      models: ["test/model"])[0]
    XCTAssertEqual(lenient.limitsPassed, false)
    XCTAssertEqual(lenient.limitsViolations, ["tool calls 1 > 0"])
    XCTAssertEqual(lenient.passed, true)
    XCTAssertEqual(lenient.steps, 2, "no step cap declared: the runner's 30 applies")
  }

  /// A misspelled tool in the limits is a task error before any request: a typo must not
  /// grade as "never used".
  func testLimitsWithAnUnknownToolNameIsATaskError() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "typo", prompt: "p", check: "true",
        limits: EvalTask.Limits(forbiddenTools: ["bsh"])),
      // Harness names may be absent from a trial (no task tool here) and are still valid.
      EvalTask(
        id: "harness-name", prompt: "make hello.txt", check: "test -e hello.txt",
        limits: EvalTask.Limits(forbiddenTools: ["task", "skill"])),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    XCTAssertEqual(outcomes[0].error, "limits: unknown tool 'bsh'")
    XCTAssertFalse(outcomes[0].checkPassed)
    XCTAssertNil(outcomes[0].limitsPassed)
    XCTAssertEqual(outcomes[1].limitsPassed, true)
    XCTAssertNil(outcomes[1].error)
    XCTAssertEqual(mock.requests.count, 2, "only the second task ran the agent")
  }

  /// A rubric trial snapshots the post-setup tree and hands the judge the diff of what the
  /// agent wrote — and only that: no transcript, no tool arguments.
  func testRubricTrialJudgesTheDiffAndBooksTheGraderCostApart() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.chatResponses = [judgeReply(score: 1, pass: true, cost: 0.004)]
    let (evalStore, recordStore) = tempStores()
    let transcripts = tempTranscriptStore()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, transcriptStore: transcripts,
      judgeModel: "judge/model")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "graded", prompt: "make hello.txt say hello",
        setup: "echo seed > seed.txt",
        check: "test \"$(cat hello.txt)\" = hello",
        rubric: EvalTask.Rubric(criteria: ["hello.txt contains hello", "nothing else changed"])),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertTrue(outcome.checkPassed)
    XCTAssertEqual(outcome.rubricPassed, true)
    XCTAssertEqual(outcome.rubricScore, 1)
    XCTAssertEqual(outcome.rubricUnknown, false)
    XCTAssertEqual(outcome.passed, true)
    XCTAssertEqual(outcome.graderCostUSD ?? 0, 0.004, accuracy: 0.00001)
    XCTAssertEqual(outcome.costUSD, 0.02, accuracy: 0.0001, "the judge's spend is not the candidate's")
    let judge = try XCTUnwrap(sideRequests(mock).first)
    XCTAssertEqual(judge.model, "judge/model")
    let user = try XCTUnwrap(judge.messages.last?.content?.plainText)
    XCTAssertTrue(user.contains("candidate/hello.txt"), "the diff names the written file")
    XCTAssertFalse(user.contains("candidate-base/"), "the base side reads base/, never candidate-base/: \(user)")
    XCTAssertTrue(user.contains("base/hello.txt"), user)
    XCTAssertTrue(user.contains("+hello"))
    XCTAssertFalse(user.contains("seed.txt"), "the post-setup file is the base, not a change")
    XCTAssertTrue(user.contains("1. hello.txt contains hello"))
    XCTAssertTrue(user.contains("Programmatic check: PASSED"))
    XCTAssertFalse(judge.messages.contains { $0.role == .tool })
    XCTAssertFalse(user.contains(#""path": "hello.txt""#), "no tool-call arguments reach the judge")
    // The snapshot is gone with the workdir (the transcript's meta names the workdir).
    let workdir = try XCTUnwrap(try transcripts.load(id: XCTUnwrap(outcome.sessionId)).meta.cwd)
    XCTAssertFalse(FileManager.default.fileExists(atPath: workdir))
    XCTAssertFalse(FileManager.default.fileExists(atPath: workdir + "-base"))
    XCTAssertEqual(try evalStore.all().first?.rubricPassed, true)
  }

  /// The diff's reference sits beside the workdir under the temp directory a sandbox keeps
  /// writable: a rubric trial's sandbox protects it, so the run's own bash cannot rewrite the
  /// base and launder its changes out of the diff the judge reads.
  func testRubricTrialSandboxProtectsTheSnapshotBase() async throws {
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox backend on this platform")
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        // In-tree change, then an attempt on the base: `<parent>/base-<workdir name>` is the
        // runner's layout (a sibling, never prefixed by the workdir's own path).
        Fixtures.toolCallChunk(
          id: "c1", name: "bash",
          arguments: #"{"command":"echo hello > hello.txt; base=\"$(dirname \"$(pwd)\")/base-$(basename \"$(pwd)\")\"; test -d \"$base\" || { echo no-base; exit 3; }; echo hello > \"$base/hello.txt\" 2>/dev/null; echo done"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [judgeReply(score: 1, pass: true)]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore,
      makeSandbox: { root in ShellSandbox(writableRoots: [root]) }, judgeModel: "judge/model")
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "guarded", prompt: "make hello.txt", check: "test -e hello.txt",
        rubric: EvalTask.Rubric(criteria: ["hello.txt was created"])),
    ])

    let outcome = await runner.run(suite: suite, models: ["test/model"])[0]

    XCTAssertTrue(outcome.checkPassed)
    XCTAssertEqual(outcome.sandboxed, true)
    // The command found the base where the runner puts it (else it prints no-base and exits 3).
    let toolResult = try XCTUnwrap(mock.requests[1].messages.last { $0.role == .tool }?.content?.plainText)
    XCTAssertTrue(toolResult.contains("done"), toolResult)
    XCTAssertFalse(toolResult.contains("no-base"), toolResult)
    let judge = try XCTUnwrap(sideRequests(mock).first)
    let user = try XCTUnwrap(judge.messages.last?.content?.plainText)
    // The base kept its post-setup state (no hello.txt), so the diff still shows the file as new.
    XCTAssertTrue(user.contains("candidate/hello.txt"), user)
    XCTAssertTrue(user.contains("+hello"), user)
    XCTAssertFalse(user.contains("(no changes to the working directory)"), "the base write must have been refused")
  }

  /// A judge that misses the schema twice, or cannot be reached at all, leaves the trial on
  /// its check with `rubricUnknown`; a gating rubric then fails the graded verdict.
  func testRubricJudgeFailuresAreUnknownNeverAThrownTrial() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.chatResponses = [
      Fixtures.textResponse("looks good", cost: 0.001),
      Fixtures.textResponse("still prose", cost: 0.001),
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore, judgeModel: "judge/model")
    let rubric = EvalTask.Rubric(criteria: ["hello.txt exists"])
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "graded", prompt: "make hello.txt", check: "test -e hello.txt", rubric: rubric),
    ])

    let invalid = await runner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertTrue(invalid.checkPassed)
    XCTAssertEqual(invalid.rubricUnknown, true)
    XCTAssertEqual(invalid.rubricPassed, false)
    XCTAssertTrue(invalid.rubricNotes?.hasPrefix("judge reply invalid:") == true, invalid.rubricNotes ?? "")
    XCTAssertEqual(invalid.graderCostUSD ?? 0, 0.002, accuracy: 0.00001, "both attempts booked")
    XCTAssertEqual(invalid.passed, false)
    XCTAssertNil(invalid.error)

    // No reply scripted at all → the mock throws → the runner records a judge error.
    let down = MockOpenRouterService()
    writeFileScript(down)
    let downRunner = EvalRunner(service: down, store: evalStore, recordStore: recordStore, judgeModel: "judge/model")
    let errored = await downRunner.run(suite: suite, models: ["test/model"])[0]
    XCTAssertTrue(errored.checkPassed)
    XCTAssertEqual(errored.rubricUnknown, true)
    XCTAssertTrue(errored.rubricNotes?.hasPrefix("judge error:") == true, errored.rubricNotes ?? "")
    XCTAssertEqual(errored.passed, false)
    XCTAssertNil(errored.error, "a judge failure is not a trial error")

    // gate: false — the same miss is recorded and passed follows the check.
    let lenient = MockOpenRouterService()
    writeFileScript(lenient)
    let lenientRunner = EvalRunner(service: lenient, store: evalStore, recordStore: recordStore, judgeModel: "judge/model")
    let recorded = await lenientRunner.run(
      suite: EvalSuite(name: "unit", tasks: [
        EvalTask(
          id: "graded", prompt: "make hello.txt", check: "test -e hello.txt",
          rubric: EvalTask.Rubric(criteria: ["x"], gate: false)),
      ]),
      models: ["test/model"])[0]
    XCTAssertEqual(recorded.rubricUnknown, true)
    XCTAssertEqual(recorded.passed, true)
  }

  /// The judge ladder: the task's own model, else the runner's, else the candidate — and the
  /// self-grading case is warned once, before any trial.
  func testJudgeLadderAndSelfGradingWarning() async throws {
    let mock = MockOpenRouterService()
    writeFileScript(mock)
    mock.chunkScripts += mock.chunkScripts // two trials
    mock.chatResponses = [judgeReply(score: 1, pass: true), judgeReply(score: 1, pass: true)]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(
        id: "own-judge", prompt: "make hello.txt", check: "true",
        rubric: EvalTask.Rubric(criteria: ["x"], model: "task/judge")),
      EvalTask(
        id: "self", prompt: "make hello.txt", check: "true",
        rubric: EvalTask.Rubric(criteria: ["x"])),
    ])
    final class Warnings: @unchecked Sendable {
      private let lock = NSLock()
      private var lines: [String] = []
      func add(_ line: String) { lock.withLock { lines.append(line) } }
      var all: [String] { lock.withLock { lines } }
    }
    let warnings = Warnings()

    _ = await runner.run(suite: suite, models: ["test/model"]) { progress in
      if case .warning(let text) = progress { warnings.add(text) }
    }

    let judges = sideRequests(mock).map(\.model)
    XCTAssertEqual(judges, ["task/judge", "test/model"])
    XCTAssertEqual(warnings.all.count, 1)
    XCTAssertTrue(warnings.all[0].hasPrefix("self-grading: judge == candidate for test/model"), warnings.all[0])

    // With a runner judge, no self-grading and no warning.
    let independent = MockOpenRouterService()
    writeFileScript(independent)
    independent.chatResponses = [judgeReply(score: 1, pass: true)]
    let quiet = Warnings()
    let independentRunner = EvalRunner(
      service: independent, store: evalStore, recordStore: recordStore, judgeModel: "judge/model")
    _ = await independentRunner.run(
      suite: EvalSuite(name: "unit", tasks: [suite.tasks[1]]), models: ["test/model"])
    { progress in
      if case .warning(let text) = progress { quiet.add(text) }
    }
    XCTAssertTrue(quiet.all.isEmpty)
    XCTAssertEqual(sideRequests(independent).map(\.model), ["judge/model"])
  }

  // MARK: X5 — parallel trials, per-trial dials

  /// Collects the runner's progress events in arrival order, from any task.
  private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func add(_ progress: EvalRunner.Progress) {
      let line: String
      switch progress {
      case .trialStarted(let taskId, _, let trial): line = "started \(taskId)#\(trial)"
      case .trialFinished(let outcome): line = "finished \(outcome.taskId)#\(outcome.trial)"
      case .warning(let text): line = "warning \(text)"
      }
      lock.withLock { events.append(line) }
    }
    var all: [String] { lock.withLock { events } }
  }

  /// A two-step conversation per trial chosen from the request itself — a request that already
  /// carries a tool result is a trial's second step — so concurrent trials over one model can't
  /// hand each other the wrong script (the shared queues are consumed in arrival order).
  private func writeOutTxtPerRequest(_ mock: MockOpenRouterService) {
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScriptSelector = { request in
      if request.messages.contains(where: { $0.role == .tool }) {
        return [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)]
      }
      return [
        Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "out.txt", "content": "x"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ]
    }
  }

  private var twoTaskSuite: EvalSuite {
    EvalSuite(name: "unit", tasks: [
      EvalTask(id: "first", prompt: "write out.txt", check: "test -f out.txt"),
      EvalTask(id: "second", prompt: "write out.txt", check: "test -f out.txt"),
    ])
  }

  func testParallelTrialsUseIsolatedWorkdirsAndKeepOrder() async throws {
    let mock = MockOpenRouterService()
    writeOutTxtPerRequest(mock)
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let log = ProgressLog()
    let before = FileManager.default.currentDirectoryPath

    let outcomes = await runner.run(suite: twoTaskSuite, models: ["test/model"], trials: 2, concurrency: 3) {
      log.add($0)
    }

    // Every trial wrote its own out.txt in its own workdir and passed.
    XCTAssertEqual(outcomes.count, 4)
    XCTAssertTrue(outcomes.allSatisfy(\.checkPassed), "\(outcomes.map { ($0.taskId, $0.trial, $0.error ?? "") })")
    XCTAssertTrue(outcomes.allSatisfy { $0.error == nil })
    // The returned array is in (task, trial) enumeration order whatever order the trials finished in.
    XCTAssertEqual(outcomes.map { "\($0.taskId)#\($0.trial)" }, ["first#1", "first#2", "second#1", "second#2"])
    XCTAssertEqual(try evalStore.all().count, 4)
    XCTAssertEqual(try recordStore.all().count, 4)
    XCTAssertEqual(FileManager.default.currentDirectoryPath, before, "no trial moved the process")
    // Four starts and four finishes — possibly interleaved, all present.
    let events = log.all
    XCTAssertEqual(events.filter { $0.hasPrefix("started") }.count, 4)
    XCTAssertEqual(events.filter { $0.hasPrefix("finished") }.count, 4)
    XCTAssertEqual(Set(events.filter { $0.hasPrefix("finished") }),
                   ["finished first#1", "finished first#2", "finished second#1", "finished second#2"])
    // The window is real: with three slots, the first three trials start before any finishes.
    let firstFinish = try XCTUnwrap(events.firstIndex { $0.hasPrefix("finished") })
    XCTAssertGreaterThanOrEqual(firstFinish, 3, "\(events)")
  }

  func testConcurrencyOneIsToday() async throws {
    let mock = MockOpenRouterService()
    writeOutTxtPerRequest(mock)
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore)
    let log = ProgressLog()

    let outcomes = await runner.run(suite: twoTaskSuite, models: ["test/model"], trials: 2) { log.add($0) }

    // Started/finished alternate in enumeration order — exactly the sequential loops' sequence.
    XCTAssertEqual(log.all, [
      "started first#1", "finished first#1",
      "started first#2", "finished first#2",
      "started second#1", "finished second#1",
      "started second#2", "finished second#2",
    ])
    XCTAssertEqual(outcomes.map { "\($0.taskId)#\($0.trial)" }, ["first#1", "first#2", "second#1", "second#2"])
    // The store received the rows in the same order.
    XCTAssertEqual(try evalStore.all().map { "\($0.taskId)#\($0.trial)" }, ["first#1", "first#2", "second#1", "second#2"])
    XCTAssertTrue(outcomes.allSatisfy(\.checkPassed))
  }

  func testEffortAndBudgetReachTheTrialConfiguration() async throws {
    let mock = MockOpenRouterService()
    // A thinking model, so the dial is actually sent; the two-step script costs $0.01 a step.
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "out.txt", "content": "x"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = tempStores()
    let runner = EvalRunner(
      service: mock, store: evalStore, recordStore: recordStore,
      reasoningEffort: .high, budgetUSD: 0.001)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "dials", prompt: "write out.txt", check: "test -f out.txt"),
    ])

    let outcomes = await runner.run(suite: suite, models: ["test/model"])

    // The dial rode the request.
    XCTAssertEqual(mock.requests.first?.reasoning?.effort, .high)
    // The $0.001 ceiling stopped the trial after its first ($0.01) step: the file was written,
    // the second step never ran, the row says `budget`.
    XCTAssertEqual(outcomes[0].stopReason, "budget")
    XCTAssertFalse(outcomes[0].agentFinished)
    XCTAssertEqual(outcomes[0].steps, 1)
    XCTAssertTrue(outcomes[0].checkPassed)
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testBudgetTakesTheTighterOfTheFlagAndTheTaskCap() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "out.txt", "content": "x"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let (evalStore, recordStore) = tempStores()
    // A generous flag, a tight task cap: the task's wins.
    let runner = EvalRunner(service: mock, store: evalStore, recordStore: recordStore, budgetUSD: 5)
    let suite = EvalSuite(name: "unit", tasks: [
      EvalTask(id: "capped", prompt: "p", check: "true", limits: EvalTask.Limits(maxCostUSD: 0.005)),
    ])
    let outcomes = await runner.run(suite: suite, models: ["test/model"])
    XCTAssertEqual(outcomes[0].stopReason, "budget")
    XCTAssertEqual(outcomes[0].limitsPassed, false)
    // No dial, no budget: the request carries no reasoning and the run finishes.
    let plain = MockOpenRouterService()
    plain.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model"))
    plain.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)]]
    let plainRunner = EvalRunner(service: plain, store: evalStore, recordStore: recordStore)
    let finished = await plainRunner.run(
      suite: EvalSuite(name: "unit", tasks: [EvalTask(id: "plain", prompt: "p", check: "true")]), models: ["test/model"])
    XCTAssertNil(plain.requests.first?.reasoning)
    XCTAssertEqual(finished[0].stopReason, "completed")
  }
}
