import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// V1 — verifier v2: the schema-validated, diff-aware verdict (`Verifier.run`), its prose
/// fallback, what does and does not reach the verifier (the diff of a real repository, never
/// the transcript), the manifest-gated `response_format`, and the panel judge on the same
/// request path (`Verifier.judge`).
final class VerifierTests: XCTestCase {
  // MARK: Helpers

  private static let hermeticConfigHome: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-verifier-xdg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  /// The host's git configuration out of the way, so a user's `diff.noprefix` can't shape a diff.
  private static let hermeticGit = [
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": hermeticConfigHome.path,
  ]

  private static let hermeticEnvironment = SubprocessEnvironment(
    policy: ShellEnvironmentPolicy(set: hermeticGit))

  private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-verifier-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-verifier-runs-\(UUID().uuidString).jsonl"))
  }

  /// `git` through `/bin/sh`, hermetic, in `root`.
  private func sh(_ script: String, in root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script]
    process.currentDirectoryURL = root
    process.environment = ProcessInfo.processInfo.environment.merging(Self.hermeticGit) { _, pinned in pinned }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "sh -c \(script) failed")
  }

  /// A repository with one commit of `notes.txt` ("one\n").
  private func makeRepository(_ label: String) throws -> URL {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = try tempDirectory(label)
    try "one\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try sh(
      "git init -q && git add -A && git -c user.name=t -c user.email=t@example.com commit -q -m initial",
      in: root)
    return root
  }

  private func verdictReply(pass: Bool, confidence: String = "high", reasons: [String] = ["file exists"], unmet: [String] = [], cost: Double = 0.002) -> ChatCompletionResponse {
    let object: JSONValue = [
      "pass": .bool(pass), "confidence": .string(confidence),
      "reasons": .array(reasons.map(JSONValue.string)), "unmet": .array(unmet.map(JSONValue.string)),
    ]
    return Fixtures.textResponse(HeadlessJSON.line(object), cost: cost)
  }

  private func userText(of mock: MockOpenRouterService, request index: Int = 0) -> String {
    mock.requests[index].messages.last?.content?.plainText ?? ""
  }

  /// A manifest for `verifier/model` advertising, or not, `response_format`.
  private func catalog(structured: Bool) -> ModelCatalog {
    let parameters = structured ? #""tools","response_format""# : #""tools""#
    let manifest = """
      [{"id":"verifier/model","context_length":8000,"supported_parameters":[\(parameters)],"pricing":{"prompt":"0.000001","completion":"0.000002"}}]
      """
    let service = MockOpenRouterService()
    service.manifestJSON = manifest
    return ModelCatalog(service: service)
  }

  // MARK: Schema

  func testVerdictSchemaAcceptsTheGoldenObjectAndRejectsABadOne() throws {
    let schema = try OutputSchema(schema: Verifier.schema)
    XCTAssertEqual(schema.name, "verdict")
    let golden: JSONValue = ["pass": true, "confidence": "high", "reasons": ["file exists"], "unmet": []]
    XCTAssertEqual(JSONSchemaLite.validate(golden, against: Verifier.schema), [])
    XCTAssertFalse(
      JSONSchemaLite.validate(
        ["pass": true, "confidence": "certain", "reasons": [], "unmet": []], against: Verifier.schema).isEmpty,
      "confidence is an enum")
    XCTAssertFalse(
      JSONSchemaLite.validate(["pass": true, "confidence": "high", "reasons": []], against: Verifier.schema).isEmpty,
      "every property is required")
    XCTAssertFalse(
      JSONSchemaLite.validate(
        ["pass": true, "confidence": "high", "reasons": [], "unmet": [], "extra": 1], against: Verifier.schema).isEmpty,
      "no extra keys")
    XCTAssertFalse(
      JSONSchemaLite.validate(
        ["pass": "yes", "confidence": "high", "reasons": [], "unmet": []], against: Verifier.schema).isEmpty)
  }

  func testJudgeSchemaAcceptsTheGoldenObjectAndRejectsABadOne() throws {
    let schema = try OutputSchema(schema: Verifier.judgeSchema)
    XCTAssertEqual(schema.name, "winner")
    XCTAssertEqual(JSONSchemaLite.validate(["winner": 2, "reasons": ["better"]], against: Verifier.judgeSchema), [])
    XCTAssertFalse(JSONSchemaLite.validate(["winner": "2", "reasons": []], against: Verifier.judgeSchema).isEmpty)
    XCTAssertFalse(JSONSchemaLite.validate(["winner": 2], against: Verifier.judgeSchema).isEmpty)
  }

  // MARK: The verdict

  func testStructuredReplyYieldsAPricedVerdictWithItsConfidence() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply(pass: true, confidence: "high", reasons: ["file exists"], cost: 0.002)]
    let verdict = try await Verifier.run(
      task: "make notes.txt", outcome: "made it", model: "verifier/model", service: mock)
    XCTAssertTrue(verdict.passed)
    XCTAssertEqual(verdict.confidence, "high")
    XCTAssertEqual(verdict.text, "PASS (high) — file exists")
    XCTAssertEqual(verdict.costUSD ?? 0, 0.002, accuracy: 0.000001, "usage.cost through the default pricing")
    XCTAssertNil(verdict.usage)
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertEqual(mock.requests[0].messages.map(\.role), [.system, .user])
    XCTAssertNil(mock.requests[0].tools)
  }

  func testFailVerdictRendersUnmetThenReasons() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      verdictReply(pass: false, confidence: "medium", reasons: ["the diff adds no file"], unmet: ["notes.txt created", "content is one"]),
    ]
    let verdict = try await Verifier.run(
      task: "make notes.txt", outcome: "made it", model: "verifier/model", service: mock)
    XCTAssertFalse(verdict.passed)
    XCTAssertEqual(verdict.confidence, "medium")
    XCTAssertEqual(verdict.text, "FAIL (medium) — unmet: notes.txt created; content is one; the diff adds no file")
    // Pure rendering: a pass drops `unmet`, an empty verdict is just the head, newlines fold.
    XCTAssertEqual(Verifier.render(passed: true, confidence: "low", reasons: [], unmet: ["x"]), "PASS (low)")
    XCTAssertEqual(Verifier.strings(.array([.string("a\nb "), .string(" "), .int(1)])), ["a b"])
  }

  func testProseReplyFallsBackToTheLegacyReadWithLowConfidence() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Fixtures.textResponse("FAIL because the file is missing.\nMore prose.", cost: 0.001),
      Fixtures.textResponse("FAIL because the file is still missing.", cost: 0.001),
    ]
    let verdict = try await Verifier.run(
      task: "make notes.txt", outcome: "made it", model: "verifier/model", service: mock)
    XCTAssertFalse(verdict.passed)
    XCTAssertEqual(verdict.confidence, "low")
    XCTAssertEqual(verdict.text, "(unstructured) FAIL because the file is still missing.")
    XCTAssertEqual(verdict.costUSD ?? 0, 0.002, accuracy: 0.000001, "both attempts booked")
    XCTAssertEqual(mock.requests.count, 2, "one correction, then the fallback — never a throw")
    XCTAssertTrue(
      (mock.requests[1].messages.last?.content?.plainText ?? "").hasPrefix("Invalid JSON for the required schema"))

    // The legacy read is the first line's PASS prefix; an empty reply is a FAIL.
    let passing = MockOpenRouterService()
    passing.chatResponses = [Fixtures.textResponse("PASS fine"), Fixtures.textResponse("PASS fine")]
    let passed = try await Verifier.run(task: "t", outcome: "o", model: "verifier/model", service: passing)
    XCTAssertTrue(passed.passed)
    XCTAssertEqual(passed.text, "(unstructured) PASS fine")
    let empty = Verifier.fallbackVerdict(raw: "   ", costUSD: 0)
    XCTAssertFalse(empty.passed)
    XCTAssertEqual(empty.text, "(unstructured) FAIL no verdict")
  }

  func testATransportErrorStillThrows() async throws {
    let mock = MockOpenRouterService()  // no scripted reply → the mock throws
    do {
      _ = try await Verifier.run(task: "t", outcome: "o", model: "verifier/model", service: mock)
      XCTFail("expected the transport error")
    } catch {
      XCTAssertTrue(error is MockError)
    }
  }

  // MARK: The evidence

  func testUserMessageCarriesTheDiffOfTheWorkingDirectory() async throws {
    let repo = try makeRepository("dirty")
    defer { try? FileManager.default.removeItem(at: repo) }
    try "one changed\n".write(to: repo.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply(pass: true)]

    _ = try await Verifier.run(
      task: "change notes.txt", outcome: "changed it", model: "verifier/model", service: mock,
      context: Verifier.Context(workingDirectory: repo, environment: Self.hermeticEnvironment))

    let text = userText(of: mock)
    XCTAssertTrue(text.hasPrefix("Task:\nchange notes.txt\n\nAgent's final report:\nchanged it\n"), text)
    XCTAssertTrue(text.contains("Changes to the working tree (unified diff, taken after the agent ran):\ndiff --git a/notes.txt b/notes.txt"), text)
    XCTAssertTrue(text.contains("-one\n+one changed"), text)
    XCTAssertTrue(text.contains("+++ b/new.txt"), "untracked files are pasted like `arnes review` pastes them: \(text)")
    XCTAssertTrue(text.contains("+fresh"), text)
    XCTAssertFalse(text.contains("no diff available"), text)
  }

  func testNoWorkingDirectorySaysNoDiffIsAvailable() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply(pass: true)]
    _ = try await Verifier.run(task: "t", outcome: "o", model: "verifier/model", service: mock)
    XCTAssertTrue(userText(of: mock).contains("taken after the agent ran):\n(no diff available: no working directory)"), userText(of: mock))
  }

  func testCleanRepositorySaysTheTreeHasNoChanges() async throws {
    let repo = try makeRepository("clean")
    defer { try? FileManager.default.removeItem(at: repo) }
    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply(pass: false)]
    _ = try await Verifier.run(
      task: "t", outcome: "o", model: "verifier/model", service: mock,
      context: Verifier.Context(workingDirectory: repo, environment: Self.hermeticEnvironment))
    XCTAssertTrue(userText(of: mock).contains("taken after the agent ran):\n(the working tree has no uncommitted changes)"), userText(of: mock))
  }

  func testANonRepositorySaysNotARepository() async throws {
    let directory = try tempDirectory("plain")
    defer { try? FileManager.default.removeItem(at: directory) }
    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply(pass: true)]
    _ = try await Verifier.run(
      task: "t", outcome: "o", model: "verifier/model", service: mock,
      context: Verifier.Context(workingDirectory: directory, environment: Self.hermeticEnvironment))
    XCTAssertTrue(userText(of: mock).contains("taken after the agent ran):\n(no diff available: not a git repository)"), userText(of: mock))
  }

  func testAnExplicitDiffIsUsedInsteadOfTheWorkingDirectory() async throws {
    let directory = try tempDirectory("eval-like")
    defer { try? FileManager.default.removeItem(at: directory) }
    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply(pass: true)]
    _ = try await Verifier.run(
      task: "t", outcome: "o", model: "verifier/model", service: mock,
      context: Verifier.Context(workingDirectory: directory),
      diff: "diff -ruN base/x.txt candidate/x.txt\n+++ candidate/x.txt\n+hello\n")
    let text = userText(of: mock)
    XCTAssertTrue(text.contains("+++ candidate/x.txt\n+hello"), text)
    XCTAssertFalse(text.contains("no diff available"), text)
    // An empty diff handed in reads as an unchanged tree.
    let quiet = MockOpenRouterService()
    quiet.chatResponses = [verdictReply(pass: false)]
    _ = try await Verifier.run(task: "t", outcome: "o", model: "verifier/model", service: quiet, diff: "")
    XCTAssertTrue(userText(of: quiet).contains("taken after the agent ran):\n(the working tree has no uncommitted changes)"))
  }

  func testReportAndDiffAreClippedWithANote() {
    let longReport = String(repeating: "r", count: Verifier.maxReportChars + 10)
    let longDiff = String(repeating: "d", count: Verifier.maxDiffChars + 1)
    let text = Verifier.userText(task: "t", report: longReport, changes: .diff(longDiff))
    XCTAssertTrue(text.contains("… [report truncated, 10 more chars]"), "the report cap")
    XCTAssertTrue(text.contains("… [diff truncated, 1 more chars]"), "the diff cap")
    XCTAssertFalse(text.contains(String(repeating: "r", count: Verifier.maxReportChars + 1)))
    let short = Verifier.userText(task: "t", report: "ok", changes: .unavailable("git failed: exit 1"))
    XCTAssertTrue(short.hasSuffix("(no diff available: git failed: exit 1)"))
  }

  func testResponseFormatIsSentOnlyWhenTheProfileAdvertisesIt() async throws {
    let structured = MockOpenRouterService()
    structured.chatResponses = [verdictReply(pass: true)]
    _ = try await Verifier.run(
      task: "t", outcome: "o", model: "verifier/model", service: structured,
      context: Verifier.Context(catalog: catalog(structured: true)))
    let withFormat = structured.requests[0]
    XCTAssertEqual(Fixtures.jsonValue(withFormat.responseFormat)["type"], "json_schema")
    XCTAssertEqual(Fixtures.jsonValue(withFormat.responseFormat)["json_schema"]?["name"], "verdict")
    XCTAssertFalse(userText(of: structured).contains("Reply with only a JSON object"), "no fallback text with response_format")

    let plain = MockOpenRouterService()
    plain.chatResponses = [verdictReply(pass: true)]
    _ = try await Verifier.run(
      task: "t", outcome: "o", model: "verifier/model", service: plain,
      context: Verifier.Context(catalog: catalog(structured: false)))
    XCTAssertNil(plain.requests[0].responseFormat, "never a response_format the manifest didn't advertise")
    XCTAssertTrue(userText(of: plain).contains("Reply with only a JSON object matching this schema"), userText(of: plain))
  }

  /// The verifier judges the claim against the evidence, never the narration: a tool-using
  /// run's verifier request is system + one user message, with no `.tool` content and none of
  /// the tool calls' text — and the session books the self-priced verdict exactly once.
  func testTheTranscriptNeverReachesTheVerifier() async throws {
    let root = try tempDirectory("session")
    defer { try? FileManager.default.removeItem(at: root) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(
          id: "c1", name: "write_file", arguments: #"{"path": "hello.txt", "content": "hello"}"#),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("created hello.txt"), Fixtures.usageChunk(cost: 0.01)],
    ]
    mock.chatResponses = [verdictReply(pass: true, confidence: "high", cost: 0.001)]
    let store = tempRecordStore()
    let agent = Agent(
      service: mock,
      tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      permissions: AutoApprovePermissions(),
      store: store,
      configuration: Session.Configuration(model: "test/model", workingDirectory: root))

    let result = try await agent.run(task: "make hello.txt", model: "test/model", verifierModel: "verifier/model")

    XCTAssertEqual(result.record.verifierPassed, true)
    XCTAssertEqual(result.record.verifierConfidence, "high")
    XCTAssertEqual(result.record.costUSD, 0.021, accuracy: 0.0001, "two steps + the verdict, booked once")
    let verifierRequest = try XCTUnwrap(mock.requests.first { $0.model == "verifier/model" })
    XCTAssertEqual(verifierRequest.messages.count, 2)
    XCTAssertEqual(verifierRequest.messages.map(\.role), [.system, .user])
    XCTAssertFalse(verifierRequest.messages.contains { $0.role == .tool })
    XCTAssertNil(verifierRequest.tools)
    let text = verifierRequest.messages[1].content?.plainText ?? ""
    XCTAssertFalse(text.contains("write_file"), text)
    XCTAssertFalse(text.contains(#""content": "hello""#), "tool arguments never ride along: \(text)")
    XCTAssertTrue(text.contains("Agent's final report:\ncreated hello.txt"), text)
    XCTAssertTrue(text.contains("(no diff available: not a git repository)"), "a temp dir is not a repository: \(text)")
  }

  // MARK: The panel judge

  func testJudgeUserTextListsEveryAttemptWithItsReportAndChanges() {
    let text = Verifier.judgeUserText(task: "write x", candidates: [
      Verifier.Candidate(index: 0, model: "a", report: "did it", changes: "+x"),
      Verifier.Candidate(index: 1, model: "b", report: "", changes: ""),
    ])
    XCTAssertTrue(text.hasPrefix("Task:\nwrite x\n\n## Attempt 1 (a)\nReport:\ndid it\nFile changes:\n+x"), text)
    XCTAssertTrue(text.contains("## Attempt 2 (b)\nReport:\n(no report)\nFile changes:\n(no file changes)"), text)
    let long = Verifier.judgeUserText(task: "t", candidates: [
      Verifier.Candidate(index: 0, model: "a", report: "r", changes: String(repeating: "d", count: Verifier.maxJudgeDiffChars + 5)),
    ])
    XCTAssertTrue(long.contains("… [diff truncated, 5 more chars]"))
  }

  func testJudgeStructuredPickResolvesTheOneBasedAttemptToTheCandidateIndex() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [Fixtures.textResponse(#"{"winner": 6, "reasons": ["complete", "minimal"]}"#, cost: 0.003)]
    let verdict = try await Verifier.judge(
      task: "t",
      candidates: [
        Verifier.Candidate(index: 3, model: "a", report: "r", changes: "+a"),
        Verifier.Candidate(index: 5, model: "b", report: "r", changes: "+b"),
      ],
      model: "judge/model", service: mock)
    XCTAssertEqual(verdict.winnerIndex, 5, "attempt 6 is the candidate at index 5")
    XCTAssertEqual(verdict.reasons, ["complete", "minimal"])
    XCTAssertEqual(verdict.text, "attempt 6 (b) — complete; minimal")
    XCTAssertEqual(verdict.costUSD, 0.003, accuracy: 0.000001)
    XCTAssertEqual(try OutputSchema(schema: Verifier.judgeSchema).name, "winner")
    XCTAssertEqual(mock.requests[0].messages.map(\.role), [.system, .user])
    XCTAssertNil(mock.requests[0].tools)
  }

  func testJudgeProseFallbackAndNoPick() async throws {
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Fixtures.textResponse("Thinking…", cost: 0.001),
      Fixtures.textResponse("Winner: attempt 2, it is complete.", cost: 0.001),
    ]
    let candidates = [
      Verifier.Candidate(index: 0, model: "a", report: "r", changes: "+a"),
      Verifier.Candidate(index: 1, model: "b", report: "r", changes: "+b"),
    ]
    let picked = try await Verifier.judge(task: "t", candidates: candidates, model: "judge/model", service: mock)
    XCTAssertEqual(picked.winnerIndex, 1)
    XCTAssertEqual(picked.reasons, [])
    XCTAssertEqual(picked.text, "(unstructured) Winner: attempt 2, it is complete.")
    XCTAssertEqual(picked.costUSD, 0.002, accuracy: 0.000001)

    let undecided = MockOpenRouterService()
    undecided.chatResponses = [Fixtures.textResponse("no idea"), Fixtures.textResponse("still no idea")]
    let none = try await Verifier.judge(task: "t", candidates: candidates, model: "judge/model", service: undecided)
    XCTAssertNil(none.winnerIndex)
    XCTAssertEqual(none.text, "still no idea")
    // `2.0` is the integer 2 (as `JSONSchemaLite` reads it); a fraction is no pick.
    XCTAssertEqual(Verifier.integer(.double(2.0)), 2)
    XCTAssertNil(Verifier.integer(.double(2.5)))
    XCTAssertNil(Verifier.integer(.string("2")))
  }

  /// `pricing` is what a runner without a session hands the context: the router's cost when
  /// reported, else the manifest estimate only on a provider that estimates.
  func testPricingFallsBackToTheManifestOnlyWhenTheProviderEstimates() async {
    let profile = ModelProfile(
      id: "m", contextLength: 8000, supportsTools: true, supportsReasoning: false,
      supportsStructuredOutputs: false, promptPricePerToken: 0.000001, completionPricePerToken: 0.000002)
    let usage = Fixtures.response("""
      {"id":"g","model":"m","choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":500}}
      """).usage
    let priced = Fixtures.textResponse("x", cost: 0.05).usage
    let estimating = Verifier.pricing(profile: profile, estimatesCost: true)
    let reporting = Verifier.pricing(profile: profile, estimatesCost: false)
    let estimated = await estimating(usage)
    let reported = await reporting(usage)
    let routerFigure = await estimating(priced)
    let nothing = await estimating(nil)
    XCTAssertEqual(estimated ?? 0, 0.002, accuracy: 0.000001)
    XCTAssertNil(reported, "OpenRouter reports cost itself; nothing to estimate")
    XCTAssertEqual(routerFigure ?? 0, 0.05, accuracy: 0.000001, "a reported cost wins")
    XCTAssertNil(nothing)
  }
}
