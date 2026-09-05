import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class HooksTests: XCTestCase {

  // MARK: Matcher

  func testMatcher() {
    XCTAssertTrue(HookDefinition(event: .preToolUse, command: "x").matches(tool: "bash"))  // nil = all
    XCTAssertTrue(HookDefinition(event: .preToolUse, matcher: "*", command: "x").matches(tool: "bash"))
    XCTAssertTrue(HookDefinition(event: .preToolUse, matcher: "bash", command: "x").matches(tool: "bash"))
    XCTAssertFalse(HookDefinition(event: .preToolUse, matcher: "bash", command: "x").matches(tool: "read_file"))
    let alt = HookDefinition(event: .preToolUse, matcher: "edit_file|write_file", command: "x")
    XCTAssertTrue(alt.matches(tool: "edit_file"))
    XCTAssertTrue(alt.matches(tool: "write_file"))
    XCTAssertFalse(alt.matches(tool: "read_file"))
    let mcp = HookDefinition(event: .preToolUse, matcher: "mcp__.*", command: "x")
    XCTAssertTrue(mcp.matches(tool: "mcp__github__search"))
    XCTAssertFalse(mcp.matches(tool: "bash"))
  }

  // MARK: PreToolUse block

  func testPreToolUseBlocksOnExitTwo() async {
    // A guardrail that exits 2, matching bash → the tool must be blocked with the hook's output.
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, matcher: "bash",
                     command: "echo 'no shell in this repo' >&2; exit 2"),
    ])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome.blockReason, "no shell in this repo")
    XCTAssertTrue(outcome.errors.isEmpty)
  }

  func testPreToolUseOtherNonZeroExitIsAnErrorNotABlock() async {
    // Claude Code's contract: only exit 2 blocks; a crashing hook is reported, not enforced.
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, matcher: "bash", command: "echo boom >&2; exit 3"),
    ])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertNil(outcome.blockReason)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("exited 3: boom"), outcome.errors[0])
  }

  func testPreToolUseAllowsOnZeroExit() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 0"),
    ])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#)
    XCTAssertEqual(outcome, .none)
  }

  func testPreToolUseIgnoresNonMatchingTool() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 1"),
    ])
    // The hook targets bash; a read_file call sails past untouched.
    let outcome = await engine.preToolUse(tool: "read_file", argumentsJSON: "{}")
    XCTAssertNil(outcome.blockReason)
  }

  // MARK: PostToolUse append + input plumbing

  func testPostToolUseAppendsOutput() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .postToolUse, matcher: "edit_file", command: "echo formatted"),
    ])
    let outcome = await engine.postToolUse(tool: "edit_file", argumentsJSON: "{}", result: "edited")
    // Unprefixed here; the session labels it `[hook]` when it appends it to the tool result.
    XCTAssertEqual(outcome.feedback, "formatted")
  }

  func testHookReceivesContextViaEnv() async {
    // The hook echoes env vars the engine sets; they should reach it — and the arguments
    // must not (stdin is the only channel for them).
    let engine = HookEngine(
      hooks: [HookDefinition(event: .postToolUse, command: #"echo "$ARNES_HOOK_EVENT/$ARNES_TOOL_NAME/$ARNES_SESSION_ID/$ARNES_CWD/[$ARNES_TOOL_ARGUMENTS]""#)],
      cwd: URL(fileURLWithPath: "/tmp"),
      sessionId: "sess-1")
    let out = await engine.postToolUse(tool: "bash", argumentsJSON: #"{"command":"ls"}"#, result: "")
    XCTAssertTrue(out.feedback.contains("PostToolUse/bash/sess-1/"), out.feedback)
    XCTAssertTrue(out.feedback.contains("/tmp/[]"), out.feedback)
  }

  func testHookReceivesClaudeCodeShapedJSONOnStdin() async throws {
    // The payload on stdin uses Claude Code's field names, so hook scripts port unchanged.
    let capture = FileManager.default.temporaryDirectory.appendingPathComponent("hook-payload-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: capture) }
    let cwd = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    let engine = HookEngine(
      hooks: [HookDefinition(event: .postToolUse, command: "cat > '\(capture.path)'")],
      cwd: cwd,
      sessionId: "sess-9",
      agent: "explore")
    _ = await engine.postToolUse(
      tool: "bash", argumentsJSON: #"{"command":"ls -la"}"#, result: "exit 0\nfiles",
      toolUseId: "call_1", turnIndex: 3)
    let payload = try JSONDecoder().decode(HookPayload.self, from: Data(contentsOf: capture))
    XCTAssertEqual(payload.hookEventName, "PostToolUse")
    XCTAssertEqual(payload.sessionId, "sess-9")
    XCTAssertEqual(payload.toolName, "bash")
    XCTAssertEqual(payload.toolInput, .object(["command": .string("ls -la")]))
    XCTAssertEqual(payload.toolUseId, "call_1")
    XCTAssertEqual(payload.toolResponse, "exit 0\nfiles")
    XCTAssertEqual(payload.cwd, cwd.path)
    XCTAssertEqual(payload.agent, "explore")
    XCTAssertEqual(payload.turnIndex, 3)
    // Raw keys are the Claude Code spelling.
    let raw = try String(contentsOf: capture, encoding: .utf8)
    for key in ["hook_event_name", "session_id", "tool_name", "tool_input", "tool_use_id", "tool_response", "cwd", "turn_index"] {
      XCTAssertTrue(raw.contains("\"\(key)\""), "missing \(key) in \(raw)")
    }
  }

  func testHookRunsInAndReportsTheConfiguredWorkingDirectory() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("hook-cwd-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let engine = HookEngine(hooks: [HookDefinition(event: .stop, command: "pwd")], cwd: dir)
    let outcome = await engine.stop()
    // `pwd` may spell the temp dir with its `/private` prefix; compare canonical forms.
    XCTAssertEqual(URL(fileURLWithPath: outcome.feedback).resolvingSymlinksInPath().path, dir.path)
  }

  // MARK: Runner hardening

  func testLargeArgumentsNeverBlockAHookThatMatchesEverything() async {
    // 512KB of arguments used to blow the exec env limit and "block" every call with a
    // spawn error; the payload rides stdin now and the env carries no copy.
    let big = String(repeating: "x", count: 512 * 1024)
    let engine = HookEngine(hooks: [HookDefinition(event: .preToolUse, matcher: "*", command: "exit 0")])
    let outcome = await engine.preToolUse(
      tool: "write_file", argumentsJSON: #"{"path":"big.txt","content":"\#(big)"}"#)
    XCTAssertEqual(outcome, .none)
  }

  func testHookThatNeverReadsAOneMegabytePayloadStillCompletes() async {
    // The stdin writer must not deadlock the runner when the hook exits without reading.
    let big = String(repeating: "y", count: 1024 * 1024)
    let engine = HookEngine(hooks: [HookDefinition(event: .preToolUse, command: "exit 0")])
    let started = Date()
    let outcome = await engine.preToolUse(tool: "write_file", argumentsJSON: #"{"content":"\#(big)"}"#)
    XCTAssertEqual(outcome, .none)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testHookReturnsWhenShellExitsEvenIfAChildKeepsRunning() async {
    // A backgrounded child inherits the output pipe; the wait must end at sh's exit, not EOF.
    let engine = HookEngine(hooks: [HookDefinition(event: .postToolUse, command: "sleep 30 & echo started")])
    let started = Date()
    let outcome = await engine.postToolUse(tool: "bash", argumentsJSON: "{}", result: "")
    XCTAssertTrue(outcome.feedback.contains("started"), outcome.feedback)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testTimedOutHookIsKilledEvenWhenItTrapsTERMAndReportsNotBlocks() async {
    // SIGTERM is ignored by the hook; SIGKILL two seconds later must still end it, and by
    // default a hook that couldn't finish is an error notice, not a block.
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, command: "trap '' TERM; sleep 60", timeoutSeconds: 1),
    ])
    let started = Date()
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: "{}")
    XCTAssertLessThan(Date().timeIntervalSince(started), 8)
    XCTAssertNil(outcome.blockReason)
    XCTAssertEqual(outcome.errors.count, 1)
    XCTAssertTrue(outcome.errors[0].contains("timed out after 1s"), outcome.errors[0])
  }

  func testFailClosedHookBlocksWhenItCannotRun() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, command: "sleep 60", timeoutSeconds: 1, failClosed: true),
    ])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: "{}")
    let reason = outcome.blockReason ?? ""
    XCTAssertTrue(reason.contains("timed out"), reason)
    XCTAssertTrue(reason.contains("failClosed"), reason)
  }

  func testProviderTokenIsAbsentFromHookEnvironment() async {
    setenv("OPENROUTER_API_KEY", "sk-or-secret-for-test", 1)
    defer { unsetenv("OPENROUTER_API_KEY") }
    let engine = HookEngine(hooks: [HookDefinition(event: .stop, command: #"echo "[$OPENROUTER_API_KEY]""#)])
    let outcome = await engine.stop()
    XCTAssertEqual(outcome.feedback, "[]")
  }

  func testOverlongHookOutputIsClippedHeadAndTail() {
    let text = String(repeating: "a", count: 6_000) + String(repeating: "z", count: 6_000)
    let clipped = HookEngine.clip(text)
    XCTAssertLessThan(clipped.count, 11_000)
    XCTAssertTrue(clipped.hasPrefix("aaaa"))
    XCTAssertTrue(clipped.hasSuffix("zzzz"))
    XCTAssertTrue(clipped.contains("characters elided"))
    XCTAssertEqual(HookEngine.clip("short"), "short")
  }

  // MARK: Session integration

  func testPostToolUseFormatterDoesNotMakeTheNextEditLookStale() async throws {
    // A formatter hook rewrites the file right after edit_file; the session re-records the
    // file's version after the hook, so the model's follow-up edit is fresh, not refused.
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-hookfmt-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("a.txt")
    try "alpha\nbeta\n".write(to: file, atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "r", name: "read_file", arguments: #"{"path":"a.txt"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "e1", name: "edit_file", arguments: #"{"path":"a.txt","old_string":"alpha","new_string":"ALPHA"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "e2", name: "edit_file", arguments: #"{"path":"a.txt","old_string":"beta","new_string":"BETA"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let store = RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hookfmt-\(UUID().uuidString).jsonl"))
    let session = Session(
      service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)), store: store,
      configuration: .init(
        model: "test/model",
        // The "formatter": appends a trailing comment line after every edit.
        hooks: [HookDefinition(event: .postToolUse, matcher: "edit_file", command: "printf '# formatted\\n' >> '\(file.path)'")],
        workingDirectory: root))
    var results: [String] = []
    for try await event in await session.send("edit twice") {
      if case .toolResult("edit_file", let preview) = event { results.append(preview) }
    }
    XCTAssertEqual(results.count, 2)
    XCTAssertFalse(results[1].hasPrefix("error"), "second edit must not be refused as stale: \(results[1])")
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "ALPHA\nBETA\n# formatted\n# formatted\n")
  }

  func testSessionSurfacesHookRunnerErrorsAsNoticesAndProceeds() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"x"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let store = RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hooks-\(UUID().uuidString).jsonl"))
    let session = Session(
      service: mock, tools: [ThinkTool()], store: store,
      configuration: .init(
        model: "test/model",
        hooks: [HookDefinition(event: .preToolUse, command: "sleep 30", timeoutSeconds: 1)]))
    var notices: [String] = []
    var toolRan = false
    for try await event in await session.send("go") {
      if case .hookNotice("PreToolUse", let output) = event { notices.append(output) }
      if case .toolResult("think", _) = event { toolRan = true }
    }
    XCTAssertEqual(notices.count, 1)
    XCTAssertTrue(notices[0].contains("timed out"), notices[0])
    XCTAssertTrue(toolRan, "a hook that cannot run must not block the call by default")
  }

  // MARK: Config

  func testConfigLoadsFromFile() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString).json")
    let json = #"{"hooks":[{"event":"PreToolUse","matcher":"bash","command":"exit 0","failClosed":true}]}"#
    try json.write(to: url, atomically: true, encoding: .utf8)
    let config = try XCTUnwrap(HookConfig.load(from: url))
    XCTAssertEqual(config.hooks.count, 1)
    XCTAssertEqual(config.hooks[0].event, .preToolUse)
    XCTAssertEqual(config.hooks[0].matcher, "bash")
    XCTAssertEqual(config.hooks[0].failClosed, true)
  }

  func testMissingConfigIsNil() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("nope-\(UUID().uuidString).json")
    XCTAssertNil(try HookConfig.load(from: url))
  }
}
