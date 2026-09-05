import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// PreToolUse hooks run *before* the permission prompt and may narrow it — deny, force a
/// prompt, lift the ordinary-mutation prompt, rewrite arguments — but never widen it past
/// `.sensitive`, a deny rule, plan mode or the catastrophic floor.
final class HookDecisionTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hookdecision-\(UUID().uuidString).jsonl"))
  }

  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-hookdecision-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
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
    hooks: [HookDefinition],
    permissions: any PermissionDelegate,
    mode: PermissionMode = .default,
    rules: PermissionRules = .empty)
    -> (Session, MockOpenRouterService)
  {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = script
    let session = Session(
      service: mock, tools: tools, permissions: permissions, store: store(),
      configuration: .init(
        model: "test/model", hooks: hooks, workingDirectory: root, permissionMode: mode, permissionRules: rules))
    return (session, mock)
  }

  private static func allowJSON(_ extra: String = "") -> String {
    #"echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow"\#(extra)}}'"#
  }

  // MARK: deny

  func testHookDenyBlocksBeforeTheDelegateIsAskedAndIsRecorded() async throws {
    let root = try tempRoot()
    let perms = ScriptedPermissions([.allow])
    let (session, mock) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [HookDefinition(event: .preToolUse, matcher: "write_file", command: "echo 'no writes today' >&2; exit 2")],
      permissions: perms)
    var blocked: (String, String)?
    var sawToolDenied = false
    for try await event in await session.send("write") {
      if case .hookBlocked(let tool, let reason) = event { blocked = (tool, reason) }
      if case .toolDenied = event { sawToolDenied = true }
    }
    XCTAssertEqual(blocked?.0, "write_file")
    XCTAssertEqual(blocked?.1, "no writes today")
    XCTAssertFalse(sawToolDenied, "a hook block is its own event, not a permission denial")
    XCTAssertEqual(perms.asks, [], "the delegate is never consulted about a call the hook denied")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
    let toolMessage = mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertEqual(toolMessage, "blocked by hook: no writes today")
    let record = await session.lastRecord
    XCTAssertEqual(record?.hookBlocks, 1)
  }

  // MARK: allow

  func testHookAllowSkipsThePromptForAnOrdinaryMutationButNotASensitiveOne() async throws {
    // Ordinary in-tree write: allow → no prompt, file written.
    var root = try tempRoot()
    var perms = ScriptedPermissions([.deny(reason: "should not be asked")])
    var (session, _) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [HookDefinition(event: .preToolUse, command: Self.allowJSON())],
      permissions: perms)
    for try await _ in await session.send("write") {}
    XCTAssertEqual(perms.asks, [])
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))

    // Destructive bash (`rm -rf x` is .sensitive): allow does not lift the prompt.
    root = try tempRoot()
    perms = ScriptedPermissions([.deny(reason: "declined")])
    (session, _) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: script(tool: "bash", arguments: #"{"command":"rm -rf build"}"#),
      hooks: [HookDefinition(event: .preToolUse, command: Self.allowJSON())],
      permissions: perms)
    var denied = false
    for try await event in await session.send("clean") {
      if case .toolDenied("bash", _) = event { denied = true }
    }
    XCTAssertEqual(perms.asks, ["bash"], "a .sensitive call still prompts despite the hook's allow")
    XCTAssertTrue(denied)
  }

  func testHookAllowNeverLiftsTheCatastrophicFloorADenyRuleOrPlanMode() async throws {
    // Catastrophic: BashTool refuses in execute regardless.
    var root = try tempRoot()
    var (session, mock) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: script(tool: "bash", arguments: #"{"command":"rm -rf /"}"#),
      hooks: [HookDefinition(event: .preToolUse, command: Self.allowJSON())],
      permissions: AutoApprovePermissions())
    for try await _ in await session.send("nuke") {}
    var toolMessage = mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.hasPrefix("error: refused"), toolMessage)

    // Deny rule beats a hook allow.
    root = try tempRoot()
    (session, mock) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [HookDefinition(event: .preToolUse, command: Self.allowJSON())],
      permissions: AutoApprovePermissions(),
      rules: PermissionRules(deny: ["write_file"]))
    for try await _ in await session.send("write") {}
    toolMessage = mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.hasPrefix("denied by a permission rule"), toolMessage)

    // Plan mode beats a hook allow.
    root = try tempRoot()
    (session, mock) = makeSession(
      root: root, tools: [WriteFileTool(root: root)],
      script: script(tool: "write_file", arguments: #"{"path":"a.txt","content":"x"}"#),
      hooks: [HookDefinition(event: .preToolUse, command: Self.allowJSON())],
      permissions: AutoApprovePermissions(),
      mode: .plan)
    for try await _ in await session.send("write") {}
    toolMessage = mock.requests.last?.messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.hasPrefix("plan mode is on"), toolMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a.txt").path))
  }

  // MARK: ask

  func testHookAskForcesAPromptOnAReadInsideTheTreeAndBlocksAStandingGrant() async throws {
    let root = try tempRoot()
    try "secret".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let perms = ScriptedPermissions([.allowAlwaysThisSession])
    let (session, _) = makeSession(
      root: root, tools: [ReadFileTool(root: root)],
      script: script(tool: "read_file", arguments: #"{"path":"notes.txt"}"#),
      hooks: [HookDefinition(
        event: .preToolUse, matcher: "read_file",
        command: #"echo '{"hookSpecificOutput":{"permissionDecision":"ask","permissionDecisionReason":"audited read"}}'"#)],
      permissions: perms)
    var readRan = false
    for try await event in await session.send("read") {
      if case .toolResult("read_file", let preview) = event, preview.contains("secret") { readRan = true }
    }
    XCTAssertEqual(perms.asks, ["read_file"], "ask forces a prompt even on a free read")
    XCTAssertTrue(readRan)
  }

  // MARK: updatedInput

  func testUpdatedInputRewritesTheCommandTheToolRunsAndThePromptShows() async throws {
    let root = try tempRoot()
    let recorder = SummaryRecordingPermissions()
    let (session, mock) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: script(tool: "bash", arguments: #"{"command":"echo original > out.txt"}"#),
      hooks: [HookDefinition(
        event: .preToolUse, matcher: "bash",
        command: #"echo '{"hookSpecificOutput":{"permissionDecision":"ask","updatedInput":{"command":"echo rewritten > out.txt"}}}'"#)],
      permissions: recorder)
    var rewriteNotice = false
    for try await event in await session.send("run") {
      if case .hookNotice("PreToolUse", let output) = event, output.contains("rewritten by hook") { rewriteNotice = true }
    }
    XCTAssertTrue(rewriteNotice)
    XCTAssertTrue(recorder.summaries.first?.contains("echo rewritten") == true, recorder.summaries.description)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8), "rewritten\n")
    // The model's own call stays in history as it was made.
    let assistant = mock.requests.last?.messages.first { $0.role == .assistant && $0.toolCalls != nil }
    XCTAssertTrue(assistant?.toolCalls?.first?.function?.arguments?.contains("echo original") == true)
  }

  func testUpdatedInputIsReclassifiedSoAHookCannotDowngradeASensitiveCall() async throws {
    // The model asks for `ls`; the hook rewrites it into a destructive command and says allow.
    // The rewritten command is what gets classified, so it still prompts.
    let root = try tempRoot()
    let perms = ScriptedPermissions([.deny(reason: "declined")])
    let (session, _) = makeSession(
      root: root, tools: [BashTool(root: root)],
      script: script(tool: "bash", arguments: #"{"command":"ls"}"#),
      hooks: [HookDefinition(
        event: .preToolUse, matcher: "bash",
        command: #"echo '{"hookSpecificOutput":{"permissionDecision":"allow","updatedInput":{"command":"rm -rf build"}}}'"#)],
      permissions: perms)
    for try await _ in await session.send("list") {}
    XCTAssertEqual(perms.asks, ["bash"])
  }

  // MARK: additionalContext + PostToolUse continue:false

  func testAdditionalContextIsAppendedAndPostToolUseContinueFalseEndsTheTurn() async throws {
    let root = try tempRoot()
    let (session, mock) = makeSession(
      root: root, tools: [ThinkTool()],
      script: [
        [Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"hm"}"#), Fixtures.usageChunk(cost: 0)],
        [Fixtures.textChunk("should not be requested"), Fixtures.usageChunk(cost: 0)],
      ],
      hooks: [
        HookDefinition(event: .preToolUse, command: #"echo '{"hookSpecificOutput":{"additionalContext":"remember the deadline"}}'"#),
        HookDefinition(event: .postToolUse, command: #"echo '{"continue":false,"stopReason":"enough thinking"}'"#),
      ],
      permissions: AutoApprovePermissions())
    var stopped: String??
    var kinds: [AgentEvent.Kind] = []
    for try await event in await session.send("think") {
      kinds.append(event.kind)
      if case .hookStopped(let reason) = event { stopped = reason }
    }
    XCTAssertEqual(stopped, "enough thinking")
    XCTAssertFalse(kinds.contains(.stepLimitReached))
    XCTAssertEqual(mock.requests.count, 1, "the turn ended after the hook said stop — no second request")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .hookStopped)
    // The context rode the tool result the model would have seen next.
    let history = await session.history
    let toolMessage = history.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.contains("[hook context]\nremember the deadline"), toolMessage)
  }
}

/// Records the summaries shown at the prompt, so a test can check what the human would see.
private final class SummaryRecordingPermissions: PermissionDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [String] = []
  var summaries: [String] { lock.withLock { stored } }
  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    lock.withLock { stored.append(summary) }
    return .allow
  }
}
