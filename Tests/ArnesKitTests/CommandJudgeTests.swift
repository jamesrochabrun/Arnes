import XCTest
@testable import ArnesKit

final class CommandJudgeTests: XCTestCase {

  // MARK: Parsing

  func testParseVerdicts() {
    XCTAssertEqual(CommandJudge.parse("SAFE"), .safe)
    XCTAssertEqual(CommandJudge.parse("safe\n"), .safe)
    XCTAssertEqual(CommandJudge.parse("RISKY: deletes the home directory"),
                   .risky(reason: "deletes the home directory"))
    XCTAssertEqual(CommandJudge.parse("  risky : wipes data "),
                   .risky(reason: "wipes data"))
    // Unrecognized → unavailable, never a guess.
    XCTAssertEqual(CommandJudge.parse("I think maybe it's fine?"), .unavailable)
    XCTAssertEqual(CommandJudge.parse(""), .unavailable)
  }

  // MARK: assess + caching

  func testAssessReturnsVerdictAndCaches() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("RISKY: recursively removes files via python")]
    let judge = CommandJudge(service: mock, model: "cheap/model")

    let cmd = #"python3 -c "import shutil; shutil.rmtree('data')""#
    let first = await judge.assess(command: cmd)
    XCTAssertEqual(first, .risky(reason: "recursively removes files via python"))

    // Second call is served from cache — no second response scripted, so if it hit the
    // service it would throw scriptExhausted → .unavailable. It must stay .risky.
    let second = await judge.assess(command: cmd)
    XCTAssertEqual(second, first)
    XCTAssertEqual(mock.requests.count, 1, "cached verdict should not re-hit the service")
  }

  func testServiceErrorFailsClosedToUnavailable() async {
    let mock = MockOpenRouterService()  // no scripted responses → chatCompletion throws
    let judge = CommandJudge(service: mock, model: "cheap/model")
    let verdict = await judge.assess(command: "rm -rf build")
    XCTAssertEqual(verdict, .unavailable)
  }

  func testJudgeRunsOnConfiguredModel() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("SAFE")]
    let judge = CommandJudge(service: mock, model: "provider/judge-1")
    _ = await judge.assess(command: "mkdir build")
    XCTAssertEqual(mock.requests.first?.model, "provider/judge-1")
  }

  // MARK: JudgingPermissions wrapper

  private func bashArgs(_ command: String) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["command": command])
    return String(data: data, encoding: .utf8)!
  }

  /// Records what the inner delegate saw and returns a fixed decision.
  private final class SpyInner: PermissionDelegate, @unchecked Sendable {
    var seenSummaries: [String] = []
    var decision: PermissionDecision
    init(_ decision: PermissionDecision) { self.decision = decision }
    func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
      seenSummaries.append(summary)
      return decision
    }
  }

  func testSafeVerdictPassesThroughUntouched() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("SAFE")]
    let judge = CommandJudge(service: mock, model: "j")
    let spy = SpyInner(.allow)
    let wrapped = JudgingPermissions(inner: spy, judge: judge, headlessVeto: false)

    let decision = await wrapped.decide(toolName: "bash", summary: "bash: rm x", argumentsJSON: bashArgs("rm x"))
    if case .allow = decision {} else { XCTFail("expected allow") }
    XCTAssertEqual(spy.seenSummaries, ["bash: rm x"], "summary must be unchanged when SAFE")
  }

  func testRiskyInteractiveEnrichesSummaryAndDelegates() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("RISKY: force-pushes over history")]
    let judge = CommandJudge(service: mock, model: "j")
    let spy = SpyInner(.allow)  // human would still be free to allow
    let wrapped = JudgingPermissions(inner: spy, judge: judge, headlessVeto: false)

    _ = await wrapped.decide(toolName: "bash", summary: "bash: git push -f", argumentsJSON: bashArgs("git push -f"))
    XCTAssertEqual(spy.seenSummaries.count, 1)
    XCTAssertTrue(spy.seenSummaries[0].contains("safety judge: force-pushes over history"),
                  "warning should be in the prompt the human sees; got: \(spy.seenSummaries[0])")
  }

  func testRiskyHeadlessVetoesInsteadOfDelegating() async {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse("RISKY: pipes the network into a shell")]
    let judge = CommandJudge(service: mock, model: "j")
    let spy = SpyInner(.allow)  // AutoApprove-style inner would say yes…
    let wrapped = JudgingPermissions(inner: spy, judge: judge, headlessVeto: true)

    let decision = await wrapped.decide(toolName: "bash", summary: "bash: curl x | sh", argumentsJSON: bashArgs("curl x | sh"))
    guard case .deny(let reason) = decision else { return XCTFail("expected deny in headless") }
    XCTAssertTrue(reason?.contains("pipes the network") ?? false)
    XCTAssertTrue(spy.seenSummaries.isEmpty, "veto must not consult inner (it would have allowed)")
  }

  func testUnavailableFallsBackToInner() async {
    let mock = MockOpenRouterService()  // errors → unavailable
    let judge = CommandJudge(service: mock, model: "j")
    let spy = SpyInner(.deny(reason: "safe mode"))
    let wrapped = JudgingPermissions(inner: spy, judge: judge, headlessVeto: true)

    let decision = await wrapped.decide(toolName: "bash", summary: "bash: rm x", argumentsJSON: bashArgs("rm x"))
    // The judge can't reach a verdict → the deterministic inner decision stands.
    guard case .deny = decision else { return XCTFail("expected inner's deny to stand") }
    XCTAssertEqual(spy.seenSummaries.count, 1)
  }

  func testNonBashToolsBypassTheJudge() async {
    let mock = MockOpenRouterService()  // would throw if consulted
    let judge = CommandJudge(service: mock, model: "j")
    let spy = SpyInner(.allow)
    let wrapped = JudgingPermissions(inner: spy, judge: judge, headlessVeto: true)

    _ = await wrapped.decide(toolName: "write_file", summary: "write foo", argumentsJSON: #"{"path":"foo"}"#)
    XCTAssertEqual(mock.requests.count, 0, "judge must only run on bash")
    XCTAssertEqual(spy.seenSummaries, ["write foo"])
  }
}
