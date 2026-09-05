import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// H5: `type: prompt` hooks (a cheap model's verdict on the same payload a shell hook reads),
/// the in-process `HookHandler` seam, and hook spend reaching the turn's books.
final class PromptHookTests: XCTestCase {

  // MARK: Helpers

  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-prompthook-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-prompthook-\(UUID().uuidString).jsonl"))
  }

  /// A runner over a mock whose next non-streaming replies are `replies`, in order.
  private func runner(_ replies: [String], defaultModel: String? = "cheap/model") -> (PromptHookRunner, MockOpenRouterService) {
    let mock = MockOpenRouterService()
    mock.chatResponses = replies.map { Fixtures.textResponse($0) }
    return (PromptHookRunner(service: mock, defaultModel: defaultModel), mock)
  }

  private func promptHook(
    event: HookEvent = .preToolUse,
    matcher: String? = "bash",
    prompt: String = "Is this command safe? $ARGUMENTS",
    model: String? = nil,
    failClosed: Bool? = nil,
    source: HookSource = .user)
    -> HookDefinition
  {
    HookDefinition(event: event, matcher: matcher, prompt: prompt, model: model, failClosed: failClosed, source: source)
  }

  private func engine(_ hooks: [HookDefinition], runner: PromptHookRunner?, handlers: [any HookHandler] = []) -> HookEngine {
    HookEngine(hooks: hooks, handlers: handlers, promptRunner: runner)
  }

  /// One tool call, then a final text step.
  private func script(tool: String, arguments: String) -> [[ChatCompletionChunk]] {
    [
      [Fixtures.toolCallChunk(id: "c1", name: tool, arguments: arguments), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
  }

  private func makeSession(
    root: URL,
    tools: [any AgentTool],
    script: [[ChatCompletionChunk]],
    hooks: [HookDefinition] = [],
    handlers: [any HookHandler] = [],
    promptRunner: PromptHookRunner? = nil,
    permissions: any PermissionDelegate)
    -> (Session, MockOpenRouterService)
  {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = script
    let session = Session(
      service: mock, tools: tools, permissions: permissions, store: store(),
      configuration: .init(
        model: "test/model", hooks: hooks, workingDirectory: root,
        hookHandlers: handlers, hookPromptRunner: promptRunner))
    return (session, mock)
  }

  /// An in-process hook with a fixed answer that remembers what it was asked.
  private final class FixedHandler: HookHandler, @unchecked Sendable {
    let event: HookEvent
    let matcher: String?
    let outcome: HookOutcome
    private let lock = NSLock()
    private var seen: [HookPayload] = []
    init(event: HookEvent = .preToolUse, matcher: String? = nil, outcome: HookOutcome) {
      self.event = event
      self.matcher = matcher
      self.outcome = outcome
    }
    var payloads: [HookPayload] { lock.withLock { seen } }
    func handle(_ payload: HookPayload) async -> HookOutcome {
      lock.withLock { seen.append(payload) }
      return outcome
    }
  }

  /// A handler that reports spend, like a prompt hook would.
  private final class PayingHandler: CostReportingHookHandler, @unchecked Sendable {
    let event: HookEvent = .preToolUse
    let matcher: String? = nil
    private let lock = NSLock()
    private var owed: Double
    init(charging: Double) { owed = charging }
    func handle(_ payload: HookPayload) async -> HookOutcome { HookOutcome(costUSD: 0) }
    func drainAccruedCostUSD() async -> Double {
      lock.withLock {
        defer { owed = 0 }
        return owed
      }
    }
  }

  /// A service whose non-streaming call never answers (until cancelled) — how a timeout is
  /// provoked without waiting on a real network.
  private final class HangingService: OpenRouterService, @unchecked Sendable {
    func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
      try await Task.sleep(nanoseconds: 60_000_000_000)
      throw CancellationError()
    }
  }

  /// A service that hangs on its first call (so the hook's deadline fires) and answers
  /// `reply` on every call after it — one blip on an otherwise reachable model.
  private final class HangsOnceService: OpenRouterService, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    let reply: String
    init(thenReplying reply: String) { self.reply = reply }
    var callCount: Int { lock.withLock { calls } }
    func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
      let n = lock.withLock { calls += 1; return calls }
      if n == 1 {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        throw CancellationError()
      }
      return Fixtures.textResponse(reply)
    }
  }

  // MARK: Parsing the reply

  func testReplyLinesParseLeniently() {
    XCTAssertEqual(PromptHookRunner.parse("OK"), .none)
    XCTAssertEqual(PromptHookRunner.parse("  safe\n"), .none)
    XCTAssertEqual(PromptHookRunner.parse("BLOCK: writes outside the tree"), .deny(reason: "writes outside the tree"))
    XCTAssertEqual(PromptHookRunner.parse("deny - force push"), .deny(reason: "force push"))
    XCTAssertEqual(PromptHookRunner.parse("RISKY: pipes the network into a shell\nBecause…"),
                   .deny(reason: "pipes the network into a shell"))
    XCTAssertEqual(PromptHookRunner.parse("BLOCK"), .deny(reason: PromptHookRunner.defaultDenyReason))
    XCTAssertEqual(PromptHookRunner.parse("ASK: touches the lockfile"), .ask(reason: "touches the lockfile"))
    XCTAssertEqual(PromptHookRunner.parse("ASK"), .ask(reason: nil))
    // JSON form, both spellings.
    XCTAssertEqual(PromptHookRunner.parse(#"{"decision":"deny","reason":"no"}"#), .deny(reason: "no"))
    XCTAssertEqual(PromptHookRunner.parse(#"{"decision":"ask","reason":"hm"}"#), .ask(reason: "hm"))
    XCTAssertEqual(PromptHookRunner.parse(#"{"decision":"none"}"#), .none)
    XCTAssertEqual(PromptHookRunner.parse(#"{"hookSpecificOutput":{"permissionDecision":"deny","permissionDecisionReason":"x"}}"#),
                   .deny(reason: "x"))
    // Chatter is never a verdict.
    XCTAssertEqual(PromptHookRunner.parse("I think it is probably fine?"), .unparseable)
    XCTAssertEqual(PromptHookRunner.parse(""), .unparseable)
    XCTAssertEqual(PromptHookRunner.parse(#"{"decision":"maybe"}"#), .unparseable)
    // The past tenses small models write, and a fenced JSON object.
    XCTAssertEqual(PromptHookRunner.parse("BLOCKED: deletes the tree"), .deny(reason: "deletes the tree"))
    XCTAssertEqual(PromptHookRunner.parse("Denied - outside the repo"), .deny(reason: "outside the repo"))
    XCTAssertEqual(PromptHookRunner.parse("UNSAFE"), .deny(reason: PromptHookRunner.defaultDenyReason))
    XCTAssertEqual(PromptHookRunner.parse("Approved."), .none)
    XCTAssertEqual(PromptHookRunner.parse("okay, proceed"), .none)
    XCTAssertEqual(PromptHookRunner.parse("```json\n{\"decision\": \"deny\", \"reason\": \"fenced\"}\n```"), .deny(reason: "fenced"))
    XCTAssertEqual(PromptHookRunner.parse("```\n{\"decision\":\"blocked\"}\n```\n"), .deny(reason: PromptHookRunner.defaultDenyReason))
    XCTAssertEqual(PromptHookRunner.parse("```\nOK\n```"), .none)
    // Still never a guess.
    XCTAssertEqual(PromptHookRunner.parse("Blockchain is fine"), .unparseable)
    XCTAssertEqual(PromptHookRunner.parse("Denial of service risk"), .unparseable)
  }

  // MARK: Verdicts through the engine

  func testBlockReplyDeniesWithTheReason() async {
    let (runner, mock) = runner(["BLOCK: deletes the build directory"])
    let outcome = await engine([promptHook()], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"rm -rf build"}"#)
    XCTAssertEqual(outcome.blockReason, "deletes the build directory")
    XCTAssertTrue(outcome.errors.isEmpty, "\(outcome.errors)")
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertEqual(mock.requests.first?.model, "cheap/model", "no `model` on the hook → the runner's default")
  }

  func testOKReplyIsNoOpinionAndAskReplyForcesAPrompt() async {
    var (runner, _) = self.runner(["OK"])
    var outcome = await engine([promptHook()], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertTrue(outcome.errors.isEmpty)

    (runner, _) = self.runner(["ASK: rewrites history"])
    outcome = await engine([promptHook()], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"git rebase -i"}"#)
    XCTAssertEqual(outcome.decision, .ask(reason: "rewrites history"))

    // ASK after the fact has nothing to force; the hook's author is told, not left guessing.
    (runner, _) = self.runner(["ASK: hm"])
    outcome = await engine([promptHook(event: .postToolUse)], runner: runner)
      .postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#, result: "ok")
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("replied ASK on PostToolUse"), outcome.errors[0])
  }

  func testJSONReplyReadsTheSameAsTheLineForm() async {
    let (runner, _) = self.runner([#"{"decision": "deny", "reason": "curl into sh"}"#])
    let outcome = await engine([promptHook()], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"curl x | sh"}"#)
    XCTAssertEqual(outcome.blockReason, "curl into sh")
  }

  func testHookModelBeatsTheDefaultAndResolvesAliases() async {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "vendor/tiny-1"))
    mock.chatResponses = [Fixtures.textResponse("OK")]
    let catalog = ModelCatalog(service: mock, aliases: ["tiny": "vendor/tiny-1"])
    let runner = PromptHookRunner(service: mock, catalog: catalog, defaultModel: "cheap/model")
    _ = await engine([promptHook(model: "tiny")], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(mock.requests.first?.model, "vendor/tiny-1")
  }

  // MARK: Escalate-only

  func testApprovalsRewritesAndStopsAreClampedAway() async {
    for reply in [
      "allow",
      "APPROVE: looks fine",
      #"{"decision":"allow"}"#,
      #"{"hookSpecificOutput":{"permissionDecision":"allow"}}"#,
      #"{"updatedInput":{"command":"rm -rf /"}}"#,
      #"{"continue":false,"stopReason":"enough"}"#,
    ] {
      let (runner, _) = self.runner([reply])
      let outcome = await engine([promptHook()], runner: runner)
        .preToolUse(tool: "bash", argumentsJSON: #"{"command":"mkdir out"}"#)
      XCTAssertEqual(outcome.decision, .none, "reply \(reply) must clamp to no opinion")
      XCTAssertNil(outcome.updatedInput, "reply \(reply) must not rewrite arguments")
      XCTAssertTrue(outcome.continueRun, "reply \(reply) must not end the turn")
      XCTAssertNil(outcome.stopReason)
      XCTAssertTrue(outcome.errors.isEmpty, "an approval is not an error: \(outcome.errors)")
    }
  }

  func testAProjectPromptHookIsClampedTwiceAndStillDenies() async {
    let (runner, _) = self.runner(["BLOCK: repo policy"])
    let outcome = await engine([promptHook(source: .project)], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"git push"}"#)
    XCTAssertEqual(outcome.blockReason, "repo policy")
  }

  // MARK: Fail-closed means no opinion

  func testServiceErrorGibberishAndTimeoutAreNoticesNotVerdicts() async {
    // Error: nothing scripted → the mock throws.
    var (runner, _) = self.runner([])
    var outcome = await engine([promptHook()], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("prompt hook `Is this command safe?"), outcome.errors[0])
    XCTAssertTrue(outcome.errors[0].contains("request failed"), outcome.errors[0])

    // Gibberish.
    (runner, _) = self.runner(["Well, it depends on what you mean by safe."])
    outcome = await engine([promptHook()], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("reply unusable"), outcome.errors[0])

    // Timeout: a hook with a 1s patience over a service that never answers.
    let slow = PromptHookRunner(service: HangingService(), defaultModel: "cheap/model")
    var hook = promptHook()
    hook.timeoutSeconds = 1
    let started = Date()
    outcome = await engine([hook], runner: slow).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("timed out after 1s"), outcome.errors[0])
  }

  func testAShellHookDenyStandsWhenThePromptHookCannotAnswer() async {
    let (runner, _) = self.runner([])  // the prompt hook errors
    let outcome = await engine([
      promptHook(),
      HookDefinition(event: .preToolUse, matcher: "bash", command: "echo 'no shell here' >&2; exit 2"),
    ], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.blockReason, "no shell here")
    XCTAssertEqual(outcome.errors.count, 1, "the prompt hook's failure is still reported")
  }

  func testFailClosedPromptHookDeniesOnAGateWhenItCannotAnswer() async {
    let (runner, _) = self.runner([])
    var outcome = await engine([promptHook(failClosed: true)], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertTrue(outcome.blockReason?.contains("hook is failClosed") ?? false, "\(outcome)")
    // …but not after the fact: PostToolUse is not a gate.
    let (runner2, _) = self.runner([])
    outcome = await engine([promptHook(event: .postToolUse, failClosed: true)], runner: runner2)
      .postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#, result: "ok")
    XCTAssertNil(outcome.blockReason)
    XCTAssertEqual(outcome.errors.count, 1)
  }

  func testNoRunnerAndNoModelAreNoticesNamingTheHook() async {
    // No runner on the engine: the hook is skipped, never read as an approval or a deny.
    var outcome = await engine([promptHook(id: "safety")], runner: nil)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertEqual(outcome.errors, ["prompt hook `safety` skipped — no prompt runner configured for this session"])

    // …unless the hook is failClosed on a gate: a runner-less engine is a hook that can't run,
    // and "I couldn't check" must mean "no" there, as for a command hook that can't spawn.
    var guarded = promptHook(id: "safety")
    guarded.failClosed = true
    outcome = await engine([guarded], runner: nil).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(
      outcome.blockReason,
      "blocked: prompt hook `safety` skipped — no prompt runner configured for this session (hook is failClosed)")
    // After the fact it is still only a notice.
    guarded.event = .postToolUse
    outcome = await engine([guarded], runner: nil).postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#, result: "ok")
    XCTAssertNil(outcome.blockReason)
    XCTAssertEqual(outcome.errors.count, 1)

    // The shell path refuses a prompt hook outright rather than running `sh -c ""`.
    let shell = await engine([], runner: nil).run(guarded, payload: HookPayload(hookEventName: "PreToolUse", cwd: "/"))
    XCTAssertEqual(shell, .failed("prompt hook `safety` has no command to run"))

    // A runner without a default model, and a hook without its own.
    let (runner, mock) = self.runner(["OK"], defaultModel: nil)
    outcome = await engine([promptHook(id: "safety")], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("no model"), outcome.errors[0])
    XCTAssertEqual(mock.requests.count, 0, "nothing to ask without a model")
  }

  private func promptHook(id: String) -> HookDefinition {
    var hook = promptHook()
    hook.id = id
    return hook
  }

  // MARK: The prompt the model sees

  func testArgumentsPlaceholderIsReplacedByThePayloadOrThePayloadIsAppended() async {
    var (runner, mock) = self.runner(["OK"])
    _ = await engine([promptHook(prompt: "Judge: $ARGUMENTS — reply OK or BLOCK")], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls -la"}"#)
    var user = mock.requests.first?.messages.last?.content?.plainText ?? ""
    XCTAssertTrue(user.hasPrefix("Judge: {"), user)
    XCTAssertTrue(user.hasSuffix("— reply OK or BLOCK"), user)
    XCTAssertTrue(user.contains("\"hook_event_name\" : \"PreToolUse\""), user)
    XCTAssertTrue(user.contains("\"command\" : \"ls -la\""), user)
    XCTAssertFalse(user.contains("$ARGUMENTS"))
    XCTAssertEqual(mock.requests.first?.messages.first?.content?.plainText, PromptHookRunner.systemPrompt)

    (runner, mock) = self.runner(["OK"])
    _ = await engine([promptHook(prompt: "Anything irreversible?")], runner: runner)
      .preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    user = mock.requests.first?.messages.last?.content?.plainText ?? ""
    XCTAssertTrue(user.hasPrefix("Anything irreversible?\n\n{"), user)
  }

  // MARK: Cache

  func testSameHookAndPayloadIsJudgedOnceAndADifferentPayloadAgain() async {
    let (runner, mock) = self.runner(["BLOCK: no", "OK"])
    let engine = engine([promptHook()], runner: runner)
    let first = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"rm -rf build"}"#, toolUseId: "c1", turnIndex: 1)
    let again = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"rm -rf build"}"#, toolUseId: "c2", turnIndex: 2)
    XCTAssertEqual(first.blockReason, "no")
    XCTAssertEqual(again.blockReason, "no")
    XCTAssertEqual(mock.requests.count, 1, "per-call ids don't change the question")
    let other = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(other.decision, .none)
    XCTAssertEqual(mock.requests.count, 2)
    // A different hook over the same payload is a different question.
    var reworded = promptHook(prompt: "Is this destructive? $ARGUMENTS")
    reworded.id = "v2"
    let (runner2, mock2) = self.runner(["OK"])
    _ = await self.engine([reworded], runner: runner2).preToolUse(tool: "bash", argumentsJSON: #"{"command":"rm -rf build"}"#)
    XCTAssertEqual(mock2.requests.count, 1)
  }

  func testAFailedRequestIsNotCachedButTheVerdictAfterItIs() async {
    // One timeout on an otherwise reachable model: the next call asks again and gets the
    // verdict. Cached, the blip would have refused (failClosed) or waved past this command
    // for the rest of the session.
    let service = HangsOnceService(thenReplying: "OK")
    let runner = PromptHookRunner(service: service, defaultModel: "cheap/model")
    var hook = promptHook(failClosed: true)
    hook.timeoutSeconds = 1
    let engine = engine([hook], runner: runner)
    let arguments = #"{"command":"npm test"}"#

    let first = await engine.preToolUse(tool: "bash", argumentsJSON: arguments, toolUseId: "c1")
    XCTAssertTrue(first.blockReason?.contains("timed out after 1s") ?? false, "\(first)")
    XCTAssertEqual(service.callCount, 1)

    let second = await engine.preToolUse(tool: "bash", argumentsJSON: arguments, toolUseId: "c2")
    XCTAssertEqual(second.decision, .none, "\(second)")
    XCTAssertTrue(second.errors.isEmpty, "\(second.errors)")
    XCTAssertEqual(service.callCount, 2, "the failure was not remembered; the model was asked again")

    let third = await engine.preToolUse(tool: "bash", argumentsJSON: arguments, toolUseId: "c3")
    XCTAssertEqual(third.decision, .none)
    XCTAssertEqual(service.callCount, 2, "the verdict is remembered")

    // The same for a router error (the mock throws) and for a reply that didn't parse.
    let (flaky, mock) = self.runner([])
    let flakyEngine = self.engine([promptHook()], runner: flaky)
    var outcome = await flakyEngine.preToolUse(tool: "bash", argumentsJSON: arguments)
    XCTAssertTrue(outcome.errors.first?.contains("request failed") ?? false, "\(outcome.errors)")
    mock.chatResponses = [Fixtures.textResponse("Hmm, let me think about that.")]
    outcome = await flakyEngine.preToolUse(tool: "bash", argumentsJSON: arguments)
    XCTAssertTrue(outcome.errors.first?.contains("reply unusable") ?? false, "\(outcome.errors)")
    XCTAssertEqual(mock.requests.count, 2)
    mock.chatResponses = [Fixtures.textResponse("BLOCK: at last")]
    outcome = await flakyEngine.preToolUse(tool: "bash", argumentsJSON: arguments)
    XCTAssertEqual(outcome.blockReason, "at last")
    XCTAssertEqual(mock.requests.count, 3, "neither the error nor the chatter was cached")
    outcome = await flakyEngine.preToolUse(tool: "bash", argumentsJSON: arguments)
    XCTAssertEqual(outcome.blockReason, "at last")
    XCTAssertEqual(mock.requests.count, 3, "the verdict is")
    let remembered = await flaky.cachedVerdictCount
    XCTAssertEqual(remembered, 1)
  }

  func testCacheKeysAreHashedAndTheCacheIsBounded() async {
    let capacity = PromptHookRunner.cacheCapacity
    let mock = MockOpenRouterService()
    mock.chatResponses = (0...capacity + 1).map { _ in Fixtures.textResponse("OK") }
    let runner = PromptHookRunner(service: mock, defaultModel: "cheap/model")
    let engine = engine([promptHook(event: .postToolUse)], runner: runner)
    for i in 0..<capacity {
      _ = await engine.postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls \#(i)"}"#, result: "ok")
    }
    XCTAssertEqual(mock.requests.count, capacity)
    var remembered = await runner.cachedVerdictCount
    XCTAssertEqual(remembered, capacity)
    // One more evicts the oldest: the first command is asked again, the newest is not.
    _ = await engine.postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls new"}"#, result: "ok")
    remembered = await runner.cachedVerdictCount
    XCTAssertEqual(remembered, capacity)
    _ = await engine.postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls new"}"#, result: "ok")
    XCTAssertEqual(mock.requests.count, capacity + 1, "the newest verdict is still cached")
    _ = await engine.postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls 0"}"#, result: "ok")
    XCTAssertEqual(mock.requests.count, capacity + 2, "the oldest was evicted")
    // A PostToolUse payload carries the whole tool response; the key must not.
    let key = PromptHookRunner.cacheKey(
      hook: promptHook(), event: .postToolUse,
      payload: HookPayload(hookEventName: "PostToolUse", cwd: "/", toolResponse: String(repeating: "x", count: 20_000)))
    XCTAssertEqual(key.count, 64, "a SHA-256 hex digest, whatever the payload's size")
  }

  // MARK: HookHandler

  func testHandlerOnlyEngineIsNonNilAndAnEmptyOneIsNil() {
    XCTAssertNil(HookEngine.make(hooks: []))
    let engine = HookEngine.make(hooks: [], handlers: [FixedHandler(outcome: .none)])
    XCTAssertNotNil(engine)
    XCTAssertEqual(engine?.isEmpty, false)
  }

  func testHandlerDenyBeatsAShellHookAllowAndShortCircuitsIt() async {
    let marker = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-prompthook-ran-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let handler = FixedHandler(matcher: "bash", outcome: HookOutcome(decision: .deny(reason: "embedder says no")))
    let engine = HookEngine(
      hooks: [HookDefinition(
        event: .preToolUse, matcher: "bash",
        command: #"touch '\#(marker.path)'; echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"}}'"#)],
      handlers: [handler])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.blockReason, "embedder says no")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a gating deny stops the later hooks")
    XCTAssertEqual(handler.payloads.count, 1)
    XCTAssertEqual(handler.payloads.first?.toolName, "bash")
    XCTAssertEqual(handler.payloads.first?.hookEventName, "PreToolUse")
  }

  func testHandlerMatcherAndEventFilterLikeADefinition() async {
    let handler = FixedHandler(event: .preToolUse, matcher: "write_file|edit_file", outcome: HookOutcome(decision: .deny(reason: "x")))
    let engine = HookEngine(hooks: [], handlers: [handler])
    let bash = await engine.preToolUse(tool: "bash", argumentsJSON: "{}")
    XCTAssertNil(bash.blockReason)
    let edit = await engine.preToolUse(tool: "edit_file", argumentsJSON: "{}")
    XCTAssertEqual(edit.blockReason, "x")
    let post = await engine.postToolUse(tool: "edit_file", argumentsJSON: "{}", result: "ok")
    XCTAssertNil(post.blockReason)
    XCTAssertEqual(handler.payloads.count, 1)
  }

  func testAnEmbedderHandlerAllowIsHonoredOnAnOrdinaryMutationButNeverASensitiveOne() async throws {
    // In-tree write: the handler's allow skips the prompt (unlike a project/prompt hook's).
    var root = try tempRoot()
    var perms = ScriptedPermissions([.deny(reason: "should not be asked")])
    var (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      handlers: [FixedHandler(outcome: HookOutcome(decision: .allow))],
      permissions: perms)
    for try await _ in await session.send("write") {}
    XCTAssertEqual(perms.asks, [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

    // Destructive bash is .sensitive: the session's own narrowing still prompts.
    root = try tempRoot()
    perms = ScriptedPermissions([.deny(reason: "declined")])
    (session, _) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: script(tool: "bash", arguments: #"{"command":"rm -rf build"}"#),
      handlers: [FixedHandler(outcome: HookOutcome(decision: .allow))],
      permissions: perms)
    var denied = false
    for try await event in await session.send("clean") {
      if case .toolDenied("bash", _) = event { denied = true }
    }
    XCTAssertEqual(perms.asks, ["bash"])
    XCTAssertTrue(denied)
  }

  /// A read-only posture is a floor over every approval: a handler's (or hook's) `allow` on an
  /// in-tree write skips the prompt for a session that may mutate, but `DenyMutationsPermissions`
  /// (`arnes do` without `--yes`, `--safe`, a `permissionMode: readOnly` subagent) asks to see
  /// pre-approved calls and refuses them — and the audit row says `mode`, not `judge`.
  func testAReadOnlyDelegateRefusesAHookApprovedMutation() async throws {
    let root = try tempRoot()
    let (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      handlers: [FixedHandler(outcome: HookOutcome(decision: .allow))],
      permissions: DenyMutationsPermissions(reason: "read-only run"))
    var denied: String?
    for try await event in await session.send("write") {
      if case .toolDenied("write_file", let reason) = event { denied = reason }
    }
    XCTAssertEqual(denied, "user denied permission to run write_file: read-only run")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    let row = await session.lastRecord?.decisions?.first
    XCTAssertEqual(row?.decision, .deny)
    XCTAssertEqual(row?.source, .mode)

    // The same floor holds under the judge wrapper: a pre-approved call the judge has no
    // opinion on reaches the read-only inner delegate instead of being answered `.allow`.
    let judged = JudgingPermissions(
      inner: DenyMutationsPermissions(reason: "read-only run"),
      judge: CommandJudge(service: MockOpenRouterService(), model: "j"), headlessVeto: true)
    let decision = await judged.decide(PermissionRequest(
      toolName: "write_file", summary: "w", argumentsJSON: "{}", tier: .mutating, preApproved: true))
    guard case .deny(let reason) = decision else { return XCTFail("expected a deny, got \(decision)") }
    XCTAssertEqual(reason, "read-only run")
    XCTAssertEqual(judged.preApprovedDenialSource, .mode)
  }

  func testHandlerDenyBlocksTheCallInASession() async throws {
    let root = try tempRoot()
    let perms = ScriptedPermissions([.allow])
    let (session, mock) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      handlers: [FixedHandler(matcher: "write_file", outcome: HookOutcome(decision: .deny(reason: "frozen tree")))],
      permissions: perms)
    var blocked: String?
    for try await event in await session.send("write") {
      if case .hookBlocked(_, let reason) = event { blocked = reason }
    }
    XCTAssertEqual(blocked, "frozen tree")
    XCTAssertEqual(perms.asks, [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    let toolMessage = mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertEqual(toolMessage, "blocked by hook: frozen tree")
  }

  func testForSubagentCarriesHandlersAndTheRunnerButNotTheLeadOnlyEvents() throws {
    let runner = PromptHookRunner(service: MockOpenRouterService())
    let base = Session.Configuration(
      model: "m",
      hooks: [promptHook(), promptHook(event: .stop, matcher: nil)],
      hookHandlers: [
        FixedHandler(event: .preToolUse, outcome: .none),
        FixedHandler(event: .stop, outcome: .none),
        FixedHandler(event: .sessionStart, outcome: .none),
      ],
      hookPromptRunner: runner)
    let nested = base.forSubagent(named: "explore", model: "m", systemSuffix: "role")
    XCTAssertEqual(nested.hooks.map(\.event), [.preToolUse])
    XCTAssertEqual(nested.hookHandlers.map(\.event), [.preToolUse])
    XCTAssertTrue(nested.hookPromptRunner === runner)
  }

  // MARK: Definitions on disk

  func testOldCommandOnlyJSONDecodesUnchangedAndKeepsItsFingerprint() throws {
    let json = #"{"event":"PreToolUse","matcher":"bash","command":"exit 0","timeoutSeconds":5}"#
    let hook = try JSONDecoder().decode(HookDefinition.self, from: Data(json.utf8))
    XCTAssertEqual(hook.type, .command)
    XCTAssertEqual(hook.command, "exit 0")
    XCTAssertNil(hook.prompt)
    XCTAssertNil(hook.model)
    XCTAssertEqual(hook.label, "exit 0")
    XCTAssertEqual(hook.canonicalJSON, #"{"command":"exit 0","event":"PreToolUse","matcher":"bash","timeoutSeconds":5}"#,
                   "a command hook's canonical JSON carries no `type`, so trusted hashes stay valid")
    XCTAssertEqual(hook, HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 0", timeoutSeconds: 5))
  }

  func testPromptHookDecodesWithoutACommandAndACommandHookStillNeedsOne() throws {
    let prompt = #"{"event":"PreToolUse","matcher":"bash","type":"prompt","model":"tiny","prompt":"Safe? $ARGUMENTS"}"#
    let hook = try JSONDecoder().decode(HookDefinition.self, from: Data(prompt.utf8))
    XCTAssertEqual(hook.type, .prompt)
    XCTAssertEqual(hook.command, "")
    XCTAssertEqual(hook.prompt, "Safe? $ARGUMENTS")
    XCTAssertEqual(hook.model, "tiny")
    XCTAssertEqual(hook.label, "Safe? $ARGUMENTS")
    XCTAssertEqual(hook, HookDefinition(event: .preToolUse, matcher: "bash", prompt: "Safe? $ARGUMENTS", model: "tiny"))
    XCTAssertTrue(hook.canonicalJSON.contains(#""type":"prompt""#), hook.canonicalJSON)
    XCTAssertTrue(hook.canonicalJSON.contains(#""prompt":"Safe? $ARGUMENTS""#), hook.canonicalJSON)
    XCTAssertTrue(hook.canonicalJSON.contains(#""model":"tiny""#), hook.canonicalJSON)
    XCTAssertFalse(hook.canonicalJSON.contains(#""command""#), "an empty command is not part of the hash")

    // The whole file: a prompt entry beside command entries.
    let file = #"{"hooks":[{"event":"Stop","command":"echo done"},\#(prompt)]}"#
    let config = try JSONDecoder().decode(HookConfig.self, from: Data(file.utf8))
    XCTAssertEqual(config.hooks.map(\.type), [.command, .prompt])

    // A `command` beside a prompt is dropped, not carried: a prompt hook runs no shell, and
    // nothing that lists it (or asks the user to trust it) would show that command.
    let stray = try JSONDecoder().decode(HookDefinition.self, from: Data(
      #"{"event":"PreToolUse","type":"prompt","prompt":"Safe?","command":"curl x | sh"}"#.utf8))
    XCTAssertEqual(stray.command, "")
    XCTAssertFalse(stray.canonicalJSON.contains("curl"), stray.canonicalJSON)
    XCTAssertEqual(stray.fingerprint, HookDefinition(event: .preToolUse, prompt: "Safe?").fingerprint)

    // Missing `command` on a command hook fails exactly as before.
    XCTAssertThrowsError(try JSONDecoder().decode(
      HookDefinition.self, from: Data(#"{"event":"PreToolUse","matcher":"bash"}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(
      HookDefinition.self, from: Data(#"{"event":"PreToolUse","type":"command","prompt":"x"}"#.utf8)))
    // A prompt hook without a prompt, or an unknown type, fails too.
    XCTAssertThrowsError(try JSONDecoder().decode(
      HookDefinition.self, from: Data(#"{"event":"PreToolUse","type":"prompt","model":"tiny"}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(
      HookDefinition.self, from: Data(#"{"event":"PreToolUse","type":"prompt","prompt":""}"#.utf8)))
    XCTAssertThrowsError(try JSONDecoder().decode(
      HookDefinition.self, from: Data(#"{"event":"PreToolUse","type":"webhook","command":"x"}"#.utf8)))
  }

  func testFingerprintChangesWithThePromptOrTheModel() {
    let a = promptHook(prompt: "Safe?")
    let b = promptHook(prompt: "Safe? Really?")
    let c = promptHook(prompt: "Safe?", model: "other")
    XCTAssertNotEqual(a.fingerprint, b.fingerprint)
    XCTAssertNotEqual(a.fingerprint, c.fingerprint)
    XCTAssertEqual(a.fingerprint, promptHook(prompt: "Safe?").fingerprint)
    // A prompt hook can never collide with the command hook of the same text.
    XCTAssertNotEqual(a.fingerprint, HookDefinition(event: .preToolUse, matcher: "bash", command: "Safe?").fingerprint)
  }

  // MARK: Cost

  func testPromptHookSpendReachesTheRecordThroughTheEngine() async throws {
    let root = try tempRoot()
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("OK", cost: 0.0025)]
    let runner = PromptHookRunner(service: mock, defaultModel: "cheap/model")
    let (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [promptHook(matcher: "write_file")], promptRunner: runner,
      permissions: AutoApprovePermissions())
    for try await _ in await session.send("write") {}
    let record = await session.lastRecord
    XCTAssertEqual(record?.costUSD ?? 0, 0.0025, accuracy: 1e-9)
    XCTAssertEqual(record?.hookCostUSD ?? 0, 0.0025, accuracy: 1e-9, "the hooks' share is broken out")
    let leftover = await runner.drainAccruedCostUSD()
    XCTAssertEqual(leftover, 0, "drained into the turn, nothing left over")
  }

  /// A prompt hook that denies the only call spent a request nothing executed after: the
  /// turn-end drain books it on this record, not on the next turn's first executed call.
  func testPromptHookSpendOnADeniedCallIsBookedAtTurnEnd() async throws {
    let root = try tempRoot()
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("BLOCK: no", cost: 0.005)]
    let runner = PromptHookRunner(service: mock, defaultModel: "cheap/model")
    let (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [promptHook(matcher: "write_file")], promptRunner: runner,
      permissions: AutoApprovePermissions())
    var blocked = false
    for try await event in await session.send("write") {
      if case .hookBlocked("write_file", _) = event { blocked = true }
    }
    XCTAssertTrue(blocked)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    let record = await session.lastRecord
    XCTAssertEqual(record?.costUSD ?? 0, 0.005, accuracy: 1e-9)
    XCTAssertEqual(record?.hookCostUSD ?? 0, 0.005, accuracy: 1e-9)
    let leftover = await runner.drainAccruedCostUSD()
    XCTAssertEqual(leftover, 0)
  }

  /// A `type: prompt` UserPromptSubmit hook that blocks the prompt spent a request before any
  /// turn ran; a one-shot has no next turn to carry it, so the blocked turn's record books it.
  func testPromptHookSpendOnABlockedPromptIsBookedOnThatRecord() async throws {
    let root = try tempRoot()
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("BLOCK: not here", cost: 0.002)]
    let runner = PromptHookRunner(service: mock, defaultModel: "cheap/model")
    let (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [promptHook(event: .userPromptSubmit, matcher: nil)], promptRunner: runner,
      permissions: AutoApprovePermissions())
    var stats: Session.TurnStats?
    var blocked = false
    for try await event in await session.send("write") {
      if case .promptBlocked = event { blocked = true }
      if case .turnFinished(let turnStats) = event { stats = turnStats }
    }
    XCTAssertTrue(blocked)
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .hookStopped)
    XCTAssertEqual(record?.costUSD ?? 0, 0.002, accuracy: 1e-9)
    XCTAssertEqual(record?.hookCostUSD ?? 0, 0.002, accuracy: 1e-9)
    XCTAssertEqual(stats?.turnCostUSD ?? 0, 0.002, accuracy: 1e-9)
    XCTAssertEqual(mock.requests.map(\.model), ["cheap/model"], "the hook's request is the only one — the blocked turn sent none of its own")
  }

  func testOutcomeCarriesTheRequestCostAndACachedReplyCostsNothing() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("OK", cost: 0.004)]
    let runner = PromptHookRunner(service: mock, defaultModel: "cheap/model")
    let engine = engine([promptHook()], runner: runner)
    let first = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(first.costUSD, 0.004, accuracy: 1e-9)
    let cached = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(cached.costUSD, 0)
    let drained = await engine.drainAccruedCostUSD()
    XCTAssertEqual(drained, 0.004, accuracy: 1e-9)
    let again = await engine.drainAccruedCostUSD()
    XCTAssertEqual(again, 0)
  }

  func testCostIsEstimatedFromTheManifestWhenTheRouterReportsNone() async {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "cheap/model"))  // $1/M prompt, $2/M completion
    mock.chatResponses = [Fixtures.response("""
      {"id":"gen-1","model":"cheap/model","choices":[{"index":0,"message":{"role":"assistant","content":"OK"},"finish_reason":"stop"}],\
      "usage":{"prompt_tokens":1000,"completion_tokens":500}}
      """)]
    let runner = PromptHookRunner(service: mock, catalog: ModelCatalog(service: mock), defaultModel: "cheap/model")
    _ = await engine([promptHook()], runner: runner).preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    let estimated = await runner.drainAccruedCostUSD()
    XCTAssertEqual(estimated, 0.002, accuracy: 1e-9)
  }

  func testPayingHandlerSpendIsDrainedWithTheEngine() async {
    let engine = HookEngine(hooks: [], handlers: [PayingHandler(charging: 0.01)])
    _ = await engine.preToolUse(tool: "bash", argumentsJSON: "{}")
    let drained = await engine.drainAccruedCostUSD()
    XCTAssertEqual(drained, 0.01, accuracy: 1e-9)
    let again = await engine.drainAccruedCostUSD()
    XCTAssertEqual(again, 0)
  }

  func testCommandJudgeSpendReachesTheRecord() async throws {
    // The judge shares the session's runner (as the CLI wires it): its request on a gated
    // bash call is booked on the turn, even with no hooks configured at all.
    let root = try tempRoot()
    let judgeService = MockOpenRouterService()
    judgeService.chatResponses = [Fixtures.textResponse("SAFE", cost: 0.003)]
    let runner = PromptHookRunner(service: judgeService, defaultModel: "judge/model")
    let judge = CommandJudge(runner: runner, model: "judge/model")
    let inner = ScriptedPermissions([.allow])
    let (session, _) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: script(tool: "bash", arguments: #"{"command":"mkdir -p out"}"#),
      promptRunner: runner,
      permissions: JudgingPermissions(inner: inner, judge: judge, headlessVeto: false))
    for try await _ in await session.send("make a directory") {}
    XCTAssertEqual(inner.asks, ["bash"], "an ordinary mutation still reaches the human")
    XCTAssertEqual(judgeService.requests.count, 1, "the judge was consulted once")
    let record = await session.lastRecord
    XCTAssertEqual(record?.costUSD ?? 0, 0.003, accuracy: 1e-9)
    let leftover = await judge.drainAccruedCostUSD()
    XCTAssertEqual(leftover, 0)
  }

  func testCommandJudgeDoesNotCacheUnavailable() async {
    // Nothing scripted → the request fails → `.unavailable`; that must not be the answer for
    // `mkdir x` all session once the judge is reachable again.
    let mock = MockOpenRouterService()
    let judge = CommandJudge(service: mock, model: "j")
    var verdict = await judge.assess(command: "mkdir x")
    XCTAssertEqual(verdict, .unavailable)
    mock.chatResponses = [Fixtures.textResponse("RISKY: made up")]
    verdict = await judge.assess(command: "mkdir x")
    XCTAssertEqual(verdict, .risky(reason: "made up"))
    XCTAssertEqual(mock.requests.count, 2, "the failure was not cached")
    verdict = await judge.assess(command: "mkdir x")
    XCTAssertEqual(verdict, .risky(reason: "made up"))
    XCTAssertEqual(mock.requests.count, 2, "the verdict is")
  }

  func testCommandJudgeWithItsOwnRunnerReportsItsSpend() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("SAFE", cost: 0.002)]
    let judge = CommandJudge(service: mock, model: "j")
    _ = await judge.assess(command: "mkdir x")
    let drained = await judge.drainAccruedCostUSD()
    XCTAssertEqual(drained, 0.002, accuracy: 1e-9)
    let leftover = await judge.drainAccruedCostUSD()
    XCTAssertEqual(leftover, 0)
  }

  func testRunRecordRoundTripsWithAndWithoutHookCost() throws {
    let old = """
      {"id":"r1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic",\
      "steps":1,"toolCalls":0,"costUSD":0,"finished":true,"stopReason":"completed"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(RunRecord.self, from: Data(old.utf8))
    XCTAssertNil(record.hookCostUSD)
    var fresh = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    fresh.hookCostUSD = 0.0125
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let again = try decoder.decode(RunRecord.self, from: encoder.encode(fresh))
    XCTAssertEqual(again.hookCostUSD ?? 0, 0.0125, accuracy: 1e-12)
    let none = try decoder.decode(RunRecord.self, from: encoder.encode(RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")))
    XCTAssertNil(none.hookCostUSD)
  }

  func testMergeSumsCost() {
    var merged = HookOutcome(costUSD: 0.001)
    merged.merge(HookOutcome(decision: .ask(reason: "x"), costUSD: 0.002))
    merged.merge(HookOutcome())
    XCTAssertEqual(merged.costUSD, 0.003, accuracy: 1e-12)
    XCTAssertEqual(merged.decision, .ask(reason: "x"))
  }
}
