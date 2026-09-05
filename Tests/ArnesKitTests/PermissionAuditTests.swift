import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Test doubles

/// A `bash` stand-in: classifies exactly like `BashTool` (so the grant/tier logic under
/// test is the real one) but never spawns a shell.
private struct StubBash: AgentTool {
  let name = "bash"
  let description = "run a shell command"
  var parameters: JSONValue { .object(["type": .string("object")]) }
  var permission: ToolPermission { .mutating }

  func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    switch ShellCommand.risk(arguments["command"]?.stringValue ?? "") {
    case .readOnly: return .readOnly
    case .ordinary: return .mutating
    case .destructive, .catastrophic: return .sensitive
    }
  }

  func summary(arguments: [String: JSONValue]) -> String {
    "run: \(arguments["command"]?.stringValue ?? "")"
  }

  func execute(arguments: [String: JSONValue]) async throws -> String { "exit 0" }
}

/// Answers scripted decisions and remembers the requests it saw (tier and `preApproved`
/// included), so a test can assert both what was asked and what was never asked.
private final class RecordingPermissions: PermissionDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [PermissionDecision]
  private(set) var requests: [PermissionRequest] = []

  init(_ answers: [PermissionDecision]) { self.answers = answers }

  var asked: [String] { lock.withLock { requests.map(\.toolName) } }
  var commands: [String] {
    lock.withLock { requests.map { JudgingPermissions.command(fromJSON: $0.argumentsJSON) ?? "" } }
  }

  func decide(_ request: PermissionRequest) async -> PermissionDecision {
    lock.withLock {
      requests.append(request)
      return answers.isEmpty ? .allow : answers.removeFirst()
    }
  }

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await decide(PermissionRequest(
      toolName: toolName, summary: summary, argumentsJSON: argumentsJSON, tier: .mutating))
  }
}

// MARK: - PermissionAuditTests

/// S3: session grants are *patterns*, every gated call leaves an audit row naming the gate
/// that answered, and a model that keeps asking for what it can't have stops the turn.
final class PermissionAuditTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-audit-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDir(_ label: String = "dir") throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-audit-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// One bash call per step, then a final text step.
  private func bashScript(_ commands: [String]) -> [[ChatCompletionChunk]] {
    var scripts = commands.enumerated().map { index, command in
      [Fixtures.toolCallChunk(
        id: "c\(index)", name: "bash",
        arguments: #"{"command":"\#(command.replacingOccurrences(of: "\"", with: "\\\""))"}"#),
       Fixtures.usageChunk(cost: 0)]
    }
    scripts.append([Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)])
    return scripts
  }

  private func session(
    tools: [any AgentTool],
    permissions: any PermissionDelegate,
    mock: MockOpenRouterService,
    root: URL? = nil,
    mode: PermissionMode = .default,
    rules: PermissionRules = .empty,
    hooks: [HookDefinition] = [])
    -> Session
  {
    Session(
      service: mock, tools: tools, permissions: permissions, store: store(),
      configuration: .init(
        model: "test/model", hooks: hooks, workingDirectory: root, permissionMode: mode,
        permissionRules: rules))
  }

  private func mock(_ scripts: [[ChatCompletionChunk]]) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = scripts
    return mock
  }

  // MARK: Grant generation

  func testGrantPatternsAreNarrowAndSkipTheDestructiveSegment() {
    XCTAssertEqual(
      ShellCommand.sessionGrantPatterns(for: "npm test && git push"),
      ["Bash(npm test *)"],
      "the approved test command becomes a pattern; the push never does")
    XCTAssertEqual(ShellCommand.sessionGrantPatterns(for: "git commit -m hi"), ["Bash(git commit *)"])
    XCTAssertEqual(
      ShellCommand.sessionGrantPatterns(for: "sudo npm install"), [],
      "sudo makes the segment destructive, and stripping the wrapper must not launder it")
    XCTAssertEqual(
      ShellCommand.sessionGrantPatterns(for: "env CI=1 npm test"), ["Bash(npm test *)"],
      "a harmless wrapper is stripped, so the grant matches what the rule matcher compares")
    XCTAssertEqual(
      ShellCommand.sessionGrantPatterns(for: "ls -la"), [],
      "a read-only command never prompted, so there is nothing to remember")
    XCTAssertEqual(ShellCommand.sessionGrantPatterns(for: "rm -rf build"), [])
    XCTAssertEqual(
      ShellCommand.sessionGrantPatterns(for: "mkdir out && swift build"),
      ["Bash(mkdir out *)", "Bash(swift build *)"],
      "one pattern per ordinary segment")
  }

  func testInterpretersAndOpaqueCommandsGrantNothing() {
    for command in [
      "bash -c 'rm -rf /tmp/x'", "sh script.sh", "python3 tool.py", "node build.js",
      "eval \"$CMD\"", "npx cowsay hi", "xargs rm < list",
    ] {
      XCTAssertEqual(
        ShellCommand.sessionGrantPatterns(for: command), [],
        "an interpreter grant would cover everything it can run: \(command)")
    }
    XCTAssertEqual(
      ShellCommand.sessionGrantPatterns(for: "make $(cat target)"), [],
      "substitution can hide a second command — approve this call, remember nothing")
    XCTAssertEqual(ShellCommand.sessionGrantPatterns(for: "tee out.txt < in.txt"), [])
  }

  func testAlwaysOnAMixedCommandGrantsOnlyTheOrdinarySegment() async throws {
    let permissions = RecordingPermissions([.allowAlwaysThisSession])
    let mock = mock(bashScript(["npm test && git push"]))
    let session = session(tools: [StubBash()], permissions: permissions, mock: mock)
    for try await _ in await session.send("ship it") {}

    let grants = await session.sessionGrants
    XCTAssertEqual(grants, ["Bash(npm test *)"])
    // And the grant cannot cover the push later: an allow pattern must match every segment.
    let set = SessionGrantSet(grants)
    XCTAssertTrue(set.allows(tool: "bash", arguments: ["command": .string("npm test -- --watch")], root: nil))
    XCTAssertFalse(set.allows(tool: "bash", arguments: ["command": .string("git push origin main")], root: nil))
    XCTAssertFalse(
      set.allows(tool: "bash", arguments: ["command": .string("npm test && git push")], root: nil),
      "the same mixed command still prompts — the grant covers one segment, not the pair")
  }

  func testAlwaysOnAnInterpreterGrantsNothingAndTheNextCallPromptsAgain() async throws {
    let permissions = RecordingPermissions([.allowAlwaysThisSession, .deny(reason: "no")])
    let mock = mock(bashScript(["bash -c 'make all'", "bash -c 'make clean'"]))
    let session = session(tools: [StubBash()], permissions: permissions, mock: mock)
    for try await _ in await session.send("build") {}

    let grants = await session.sessionGrants
    XCTAssertEqual(grants, [], "answering always to an interpreter grants nothing")
    XCTAssertEqual(permissions.asked, ["bash", "bash"], "so the second call prompts too")
  }

  func testAGrantedPatternSkipsThePromptAndANonMatchingCallStillAsks() async throws {
    let permissions = RecordingPermissions([.allowAlwaysThisSession])
    let mock = mock(bashScript(["swift build", "swift build --verbose", "mkdir out"]))
    let session = session(tools: [StubBash()], permissions: permissions, mock: mock)
    for try await _ in await session.send("build twice, then a dir") {}

    let grants = await session.sessionGrants
    XCTAssertEqual(grants, ["Bash(swift build *)"])
    XCTAssertEqual(
      permissions.commands, ["swift build", "mkdir out"],
      "the second `swift build` rode the grant; `mkdir` is a different command and asked")
  }

  func testAlwaysOnAFileToolStillGrantsTheBareToolName() async throws {
    let root = try tempDir("write")
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "w1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "w2", name: "write_file", arguments: #"{"path":"b.txt","content":"y"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let permissions = RecordingPermissions([.allowAlwaysThisSession])
    let session = session(
      tools: [WriteFileTool(root: root)], permissions: permissions, mock: mock, root: root)
    for try await _ in await session.send("write two files") {}

    let grants = await session.sessionGrants
    XCTAssertEqual(grants, ["write_file"])
    XCTAssertEqual(permissions.asked, ["write_file"], "the second in-tree write rode the grant")
  }

  // MARK: The audit trail

  func testDecisionsCarryTheirSource() async throws {
    let root = try tempDir("sources")
    let mock = mock(bashScript(["swift build", "swift build --release", "npm run lint"]))
    // An allow rule covers `npm run …`; the first two calls are answered by the user, the
    // second riding the grant the first one created.
    let permissions = RecordingPermissions([.allowAlwaysThisSession])
    let session = session(
      tools: [StubBash()], permissions: permissions, mock: mock, root: root,
      rules: PermissionRules(allow: ["Bash(npm run:*)"]))
    for try await _ in await session.send("go") {}

    let decisions = await session.lastRecord?.decisions
    let rows = try XCTUnwrap(decisions)
    XCTAssertEqual(rows.map(\.source), [.user, .grant, .rule])
    XCTAssertEqual(rows.map(\.decision), [.allow, .allow, .allow])
    XCTAssertEqual(rows.map(\.tier), [.mutating, .mutating, .mutating])
    XCTAssertEqual(rows.map(\.tool), ["bash", "bash", "bash"])
  }

  func testPlanModeAndDenyRulesAreRecordedWithTheirGate() async throws {
    let root = try tempDir("deny")
    let planMock = mock(bashScript(["mkdir out"]))
    let plan = session(
      tools: [StubBash()], permissions: RecordingPermissions([]), mock: planMock, root: root,
      mode: .plan)
    for try await _ in await plan.send("make it") {}
    let planDecisions = await plan.lastRecord?.decisions
    let planRows = try XCTUnwrap(planDecisions)
    XCTAssertEqual(planRows.map(\.source), [.mode])
    XCTAssertEqual(planRows.map(\.decision), [.deny])
    let planStop = await plan.lastRecord?.stopReason
    // One denial is not a loop — and in plan mode a natural finish is a proposal, not work.
    XCTAssertEqual(planStop, .planProposed)

    let ruleMock = mock(bashScript(["mkdir out"]))
    let ruled = session(
      tools: [StubBash()], permissions: RecordingPermissions([]), mock: ruleMock, root: root,
      rules: PermissionRules(deny: ["Bash(mkdir:*)"]))
    for try await _ in await ruled.send("make it") {}
    let ruleDecisions = await ruled.lastRecord?.decisions
    let ruleRows = try XCTUnwrap(ruleDecisions)
    XCTAssertEqual(ruleRows.map(\.source), [.rule])
    XCTAssertEqual(ruleRows.map(\.decision), [.deny])
  }

  func testAUserDenialIsRecordedAndAFreeReadIsNot() async throws {
    let root = try tempDir("free")
    try "hello".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "r1", name: "read_file", arguments: #"{"path":"a.txt"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "w1", name: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let session = session(
      tools: [ReadFileTool(root: root), WriteFileTool(root: root)],
      permissions: RecordingPermissions([.deny(reason: "not that one")]), mock: mock, root: root)
    for try await _ in await session.send("read then write") {}

    let decisions = await session.lastRecord?.decisions
    let rows = try XCTUnwrap(decisions)
    XCTAssertEqual(rows.count, 1, "an ungated in-tree read is not a decision")
    XCTAssertEqual(rows[0].tool, "write_file")
    XCTAssertEqual(rows[0].source, .user)
    XCTAssertEqual(rows[0].decision, .deny)
    XCTAssertEqual(rows[0].reason, "not that one")
  }

  func testAnExecuteTimeFloorRefusalIsRecordedAsFloor() async throws {
    let harness = try tempDir("harness")
    let root = try tempDir("root")
    let target = harness.appendingPathComponent("rules.json")
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(
        id: "c1", name: "write_file",
        arguments: #"{"path":"\#(target.path)","content":"{}"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let rules = PathScope.Rules(harnessPaths: [PathScope.physicalPath(harness.path)])
    // Everything approves it — bypass mode plus an unattended delegate that says yes to
    // anything. Only the tool's own floor refuses, and the row names the layer that did.
    let session = session(
      tools: [WriteFileTool(root: root, rules: rules)],
      permissions: AutoApprovePermissions(denySensitive: false), mock: mock, root: root,
      mode: .bypass)
    for try await _ in await session.send("rewrite the rules") {}

    let decisions = await session.lastRecord?.decisions
    let rows = try XCTUnwrap(decisions)
    XCTAssertEqual(
      rows.map(\.source), [.yes, .floor],
      "a harness path is .sensitive, so bypass never covered it — --yes approved, the floor refused")
    XCTAssertEqual(rows[0].tier, .sensitive)
    XCTAssertEqual(rows.map(\.decision), [.allow, .deny])
    XCTAssertTrue(rows[1].reason?.contains("harness files") == true, rows[1].reason ?? "")
  }

  func testAHookBlockIsRecordedAsHook() async throws {
    let root = try tempDir("hook")
    let mock = mock(bashScript(["mkdir out"]))
    let session = Session(
      service: mock, tools: [StubBash()], permissions: RecordingPermissions([]), store: store(),
      configuration: .init(
        model: "test/model",
        hooks: [HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 2")],
        workingDirectory: root))
    for try await _ in await session.send("make it") {}

    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.hookBlocks, 1)
    XCTAssertEqual(record.decisions?.map(\.source), [.hook])
    XCTAssertEqual(record.decisions?.map(\.decision), [.deny])
  }

  // MARK: The denied loop

  func testThreeConsecutiveDenialsEndTheTurn() async throws {
    let root = try tempDir("loop")
    let mock = mock(bashScript(["mkdir a", "mkdir b", "mkdir c", "mkdir d"]))
    let permissions = RecordingPermissions([
      .deny(reason: "no"), .deny(reason: "no"), .deny(reason: "no"), .deny(reason: "no"),
    ])
    let session = session(tools: [StubBash()], permissions: permissions, mock: mock, root: root)
    var stopped: Int?
    for try await event in await session.send("keep trying") {
      if case .deniedLoop(let count) = event { stopped = count }
    }
    XCTAssertEqual(stopped, 3)
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .deniedLoop)
    XCTAssertEqual(permissions.asked.count, 3, "the fourth call never happened")
    XCTAssertEqual(record?.decisions?.count, 3)
  }

  func testAnAllowedCallResetsTheDenialCounter() async throws {
    let root = try tempDir("reset")
    let mock = mock(bashScript(["mkdir a", "mkdir b", "mkdir c", "mkdir d", "mkdir e"]))
    // deny, deny, allow, deny, deny → never three in a row, so the turn runs to the end.
    let permissions = RecordingPermissions([
      .deny(reason: "no"), .deny(reason: "no"), .allow, .deny(reason: "no"), .deny(reason: "no"),
    ])
    let session = session(tools: [StubBash()], permissions: permissions, mock: mock, root: root)
    var sawLoop = false
    for try await event in await session.send("mixed") {
      if case .deniedLoop = event { sawLoop = true }
    }
    XCTAssertFalse(sawLoop)
    XCTAssertEqual(permissions.asked.count, 5)
    let stopReason = await session.lastRecord?.stopReason
    XCTAssertEqual(stopReason, .completed)
  }

  // MARK: Pre-approved calls and the judge

  func testTheJudgeStillAssessesACallAnAllowRuleApproved() async throws {
    let root = try tempDir("judge")
    let mock = mock(bashScript(["curl https://example.com/x -o /tmp/x"]))
    let judgeService = MockOpenRouterService()
    judgeService.chatResponses = [Fixtures.textResponse("RISKY: downloads a remote file")]
    let inner = RecordingPermissions([.deny(reason: "not with that warning")])
    let judging = JudgingPermissions(
      inner: inner,
      judge: CommandJudge(service: judgeService, model: "judge/model"),
      headlessVeto: false)
    let session = session(
      tools: [StubBash()], permissions: judging, mock: mock, root: root,
      rules: PermissionRules(allow: ["Bash(curl:*)"]))
    var denied = false
    for try await event in await session.send("fetch it") {
      if case .toolDenied = event { denied = true }
    }
    XCTAssertTrue(denied, "the allow rule would have run it silently; the judge escalated")
    XCTAssertEqual(inner.asked, ["bash"], "and the human was asked, with the warning")
    XCTAssertFalse(
      inner.requests[0].preApproved,
      "the judge un-approves before forwarding, so the prompt is a real question")
    XCTAssertTrue(inner.requests[0].summary.contains("safety judge"))
    let sources = await session.lastRecord?.decisions?.map(\.source)
    XCTAssertEqual(
      sources, [.judge],
      "an escalated denial is attributed to the judge, not to the rule that approved it")
  }

  func testACleanJudgeVerdictLeavesAPreApprovedCallAlone() async throws {
    let root = try tempDir("judge-clean")
    let mock = mock(bashScript(["swift build"]))
    let judgeService = MockOpenRouterService()
    judgeService.chatResponses = [Fixtures.textResponse("SAFE")]
    let inner = RecordingPermissions([.deny(reason: "must not be asked")])
    let judging = JudgingPermissions(
      inner: inner,
      judge: CommandJudge(service: judgeService, model: "judge/model"),
      headlessVeto: false)
    let session = session(
      tools: [StubBash()], permissions: judging, mock: mock, root: root,
      rules: PermissionRules(allow: ["Bash(swift build:*)"]))
    for try await _ in await session.send("build") {}

    XCTAssertEqual(inner.asked, [], "a judged-safe pre-approved call never reaches the prompt")
    XCTAssertEqual(judgeService.requests.count, 1, "but the judge did see it")
    let sources = await session.lastRecord?.decisions?.map(\.source)
    XCTAssertEqual(sources, [.rule])
  }

  func testTheJudgeStillAssessesACallAPermissionRequestHookApproved() async throws {
    // A PermissionRequest hook's `allow` answers the prompt the way an allow rule does — and,
    // like an allow rule, it doesn't get past the safety judge when one is configured.
    let root = try tempDir("judge-hook")
    let allowHook = HookDefinition(
      event: .permissionRequest,
      command: #"echo '{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}'"#)
    // An in-tree download is an *ordinary* mutation (a hook's allow never lifts `.sensitive`).
    var mock = mock(bashScript(["curl https://example.com/x -o x.tgz"]))
    var judgeService = MockOpenRouterService()
    judgeService.chatResponses = [Fixtures.textResponse("RISKY: downloads a remote file")]
    var inner = RecordingPermissions([.deny(reason: "not with that warning")])
    var session = session(
      tools: [StubBash()],
      permissions: JudgingPermissions(
        inner: inner, judge: CommandJudge(service: judgeService, model: "judge/model"), headlessVeto: false),
      mock: mock, root: root, hooks: [allowHook])
    var denied = false
    for try await event in await session.send("fetch it") {
      if case .toolDenied = event { denied = true }
    }
    XCTAssertTrue(denied, "the hook would have run it silently; the judge escalated")
    XCTAssertEqual(inner.asked, ["bash"], "and the human was asked, with the warning")
    XCTAssertFalse(inner.requests[0].preApproved, "the judge un-approves before forwarding")
    var sources = await session.lastRecord?.decisions?.map(\.source)
    XCTAssertEqual(sources, [.judge])

    // A clean verdict: the judge saw it, nobody was asked, and the row names the hook.
    mock = self.mock(bashScript(["swift build"]))
    judgeService = MockOpenRouterService()
    judgeService.chatResponses = [Fixtures.textResponse("SAFE")]
    inner = RecordingPermissions([.deny(reason: "must not be asked")])
    session = self.session(
      tools: [StubBash()],
      permissions: JudgingPermissions(
        inner: inner, judge: CommandJudge(service: judgeService, model: "judge/model"), headlessVeto: false),
      mock: mock, root: root, hooks: [allowHook])
    for try await _ in await session.send("build") {}
    XCTAssertEqual(inner.asked, [])
    XCTAssertEqual(judgeService.requests.count, 1, "the judge did see the hook-approved call")
    sources = await session.lastRecord?.decisions?.map(\.source)
    XCTAssertEqual(sources, [.hook])
  }

  func testAnExecuteTimeFloorRefusalCountsAsADeniedCall() async throws {
    // The floor refuses after every gate said yes; the record still counts it, so
    // `denied_calls` and the `permission_denials` rows agree.
    let root = try tempDir("floor")
    let mock = mock(bashScript(["rm -rf /"]))
    let session = session(tools: [BashTool(root: root)], permissions: AutoApprovePermissions(), mock: mock, root: root)
    for try await _ in await session.send("nuke") {}
    let record = await session.lastRecord
    XCTAssertEqual(record?.decisions?.map(\.source), [.yes, .floor], "the gate said yes; the floor refused")
    XCTAssertEqual(record?.deniedCalls, 1)
  }

  func testWithoutAJudgeAPreApprovedCallSkipsTheDelegateEntirely() async throws {
    let root = try tempDir("nojudge")
    let mock = mock(bashScript(["swift build"]))
    let permissions = RecordingPermissions([.deny(reason: "must not be asked")])
    let session = session(
      tools: [StubBash()], permissions: permissions, mock: mock, root: root,
      rules: PermissionRules(allow: ["Bash(swift build:*)"]))
    for try await _ in await session.send("build") {}
    XCTAssertEqual(permissions.asked, [], "no round trip for a call the rules already answered")
  }

  // MARK: Saving grants

  func testPermissionsSaveRoundTripsThroughTheRulesFile() throws {
    let directory = try tempDir("rules")
    let url = directory.appendingPathComponent("rules.json")
    // A file that already carries the user's guardrails.
    let existing = PermissionRules(deny: ["Bash(rm:*)"], ask: ["write_file"], allow: ["Bash(ls:*)"])
    try SecureFiles.writePrivate(JSONEncoder().encode(existing), to: url)

    let added = try PermissionRules.appendAllowRules(
      ["Bash(npm test *)", "write_file", "Bash(ls:*)"], to: url)
    XCTAssertEqual(added, ["Bash(npm test *)", "write_file"], "an entry already present is skipped")

    let reloaded = try XCTUnwrap(PermissionRules.load(from: url))
    XCTAssertEqual(reloaded.deny, ["Bash(rm:*)"], "the user's deny list is untouched")
    XCTAssertEqual(reloaded.ask, ["write_file"])
    XCTAssertEqual(reloaded.allow, ["Bash(ls:*)", "Bash(npm test *)", "write_file"])
    // Saved rules are as private as the rest of ~/.arnes.
    let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o600)
    // And they behave as rules on the next run.
    let set = PermissionRuleSet(reloaded)
    XCTAssertEqual(set.outcome(tool: "bash", arguments: ["command": .string("npm test")], root: nil), .allow)
  }

  func testSaveCreatesTheRulesFileWhenThereIsNone() throws {
    let directory = try tempDir("rules-new")
    let url = directory.appendingPathComponent("nested/rules.json")
    XCTAssertEqual(try PermissionRules.appendAllowRules(["Bash(git status *)"], to: url), ["Bash(git status *)"])
    XCTAssertEqual(try PermissionRules.load(from: url)?.allow, ["Bash(git status *)"])
    XCTAssertEqual(try PermissionRules.appendAllowRules([], to: url), [], "nothing to add, nothing written")
  }

  func testSaveRefusesToClobberAMalformedRulesFile() throws {
    let directory = try tempDir("rules-bad")
    let url = directory.appendingPathComponent("rules.json")
    try Data("{ not json".utf8).write(to: url)
    XCTAssertThrowsError(
      try PermissionRules.appendAllowRules(["bash"], to: url),
      "a typo in the file must not cost the user their deny list")
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{ not json")
  }

  // MARK: Record shape

  func testDecisionsSurviveTheRecordStoreAndOlderRecordsStillDecode() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-audit-store-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = RunRecordStore(url: url)
    var record = RunRecord(task: "t", model: "test/model", dialect: "chat", packFamily: "generic")
    record.costUSD = 0.25
    record.verifierPassed = true
    record.note(ToolDecision(tool: "bash", tier: .sensitive, decision: .deny, source: .rule, reason: "deny rule"))
    try store.append(record)

    let read = try store.all()
    XCTAssertEqual(read.count, 1)
    // The scoreboard fields `arnes runs` prints are exactly as before…
    XCTAssertEqual(read[0].model, "test/model")
    XCTAssertEqual(read[0].costUSD, 0.25)
    XCTAssertEqual(read[0].verifierPassed, true)
    // …and the new rows ride alongside.
    XCTAssertEqual(read[0].decisions?.count, 1)
    XCTAssertEqual(read[0].decisions?[0].source, .rule)
    XCTAssertEqual(read[0].decisions?[0].tier, .sensitive)

    // A record written before the field existed still decodes (and prints) unchanged.
    let legacy = #"{"id":"x","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0.5,"finished":true}"#
    try appendJSONLLine(Data((legacy + "\n").utf8), to: url)
    let both = try store.all()
    XCTAssertEqual(both.count, 2)
    XCTAssertNil(both[1].decisions)
    XCTAssertEqual(both[1].costUSD, 0.5)
  }

  func testTheAuditTrailIsCapped() {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    for _ in 0..<(ToolDecision.maxPerRecord + 50) {
      record.note(ToolDecision(tool: "bash", tier: .mutating, decision: .deny, source: .user))
    }
    XCTAssertEqual(record.decisions?.count, ToolDecision.maxPerRecord)
    let long = String(repeating: "x", count: 1000)
    XCTAssertEqual(
      ToolDecision(tool: "bash", tier: .mutating, decision: .deny, source: .user, reason: long)
        .reason?.count,
      ToolDecision.maxReasonLength)
  }
}
