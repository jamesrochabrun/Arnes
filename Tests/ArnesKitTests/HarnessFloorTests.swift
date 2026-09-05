import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - HarnessFloorTests

/// The write-side floor: the harness's own state (`~/.arnes/**`, and whatever the `ARNES_*`
/// config variables point at) is refused inside `execute`, before anything is created and
/// independent of any permission decision — the twin of `ShellCommand.isCatastrophic`. An
/// agent that could rewrite `hooks.json` or `rules.json` could delete every guardrail it is
/// judged by, so this one isn't a prompt.
final class HarnessFloorTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-floor-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A rules value whose harness locations are a temp directory, so the tests never go
  /// anywhere near the real `~/.arnes`.
  private func rules(harness: URL) -> PathScope.Rules {
    PathScope.Rules(harnessPaths: [PathScope.physicalPath(harness.path)])
  }

  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-floor-runs-\(UUID().uuidString).jsonl"))
  }

  // MARK: Classification

  func testTheRealArnesDirectoryClassifiesAsHarness() {
    // Classification only — nothing is written, so this can safely name the user's own
    // `~/.arnes` and prove `defaultHarnessPaths` really covers it.
    let home = NSHomeDirectory()
    let root = URL(fileURLWithPath: "/tmp/some-project")
    for path in [".arnes/hooks.json", ".arnes/rules.json", ".arnes/credentials", ".arnes/agents/x.md"] {
      XCTAssertEqual(
        PathScope.classify(forWriting: home + "/" + path, root: root), .harness, path)
    }
    // A neighbour that merely shares the prefix is not harness state.
    XCTAssertNotEqual(PathScope.classify(forWriting: home + "/.arnesrc", root: root), .harness)
  }

  func testConfigOverrideVariablesRelocateTheHarnessFloor() throws {
    let elsewhere = try tempDir()
    let home = try tempDir()
    let hooks = elsewhere.appendingPathComponent("hooks.json").path
    let paths = PathScope.harnessPaths(
      home: home.path,
      environment: ["ARNES_HOOKS_CONFIG": hooks, "ARNES_RULES_CONFIG": ""])
    XCTAssertTrue(paths.contains(PathScope.physicalPath(hooks)), "\(paths)")
    // Empty values are ignored rather than making everything harness state.
    XCTAssertEqual(paths.count, 2)
    let rules = PathScope.Rules(harnessPaths: paths)
    XCTAssertEqual(PathScope.classify(forWriting: hooks, root: elsewhere, rules: rules), .harness)
    XCTAssertEqual(
      PathScope.classify(forWriting: elsewhere.appendingPathComponent("notes.md").path, root: elsewhere, rules: rules),
      .inside,
      "only the file the variable names is harness state, not its whole directory")
  }

  // MARK: The floor in execute

  func testWriteFileRefusesHarnessPathsInExecute() async throws {
    let harness = try tempDir()
    let root = try tempDir()
    let target = harness.appendingPathComponent("hooks.json")
    let tool = WriteFileTool(root: root, rules: rules(harness: harness))
    let output = try await tool.execute(arguments: [
      "path": .string(target.path), "content": .string("[]"),
    ])
    XCTAssertEqual(output, "error: refused — harness files are not editable by tools; edit them yourself")
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path), "nothing was written")
    XCTAssertEqual(
      tool.permission(for: ["path": .string(target.path), "content": .string("[]")]), .sensitive,
      "it also gates as sensitive, so an interactive user sees it before the refusal")
  }

  func testConfigOverridePathIsRefusedInExecute() async throws {
    let elsewhere = try tempDir()
    let home = try tempDir()
    let hooks = elsewhere.appendingPathComponent("hooks.json")
    try "[]".write(to: hooks, atomically: true, encoding: .utf8)
    let rules = PathScope.Rules(harnessPaths: PathScope.harnessPaths(
      home: home.path, environment: ["ARNES_HOOKS_CONFIG": hooks.path]))
    let write = WriteFileTool(root: elsewhere, rules: rules)
    let written = try await write.execute(arguments: [
      "path": .string("hooks.json"), "content": .string("pwned"),
    ])
    XCTAssertTrue(written.hasPrefix("error: refused — harness files"), written)
    let edit = EditFileTool(root: elsewhere, rules: rules)
    let edited = try await edit.execute(arguments: [
      "path": .string("hooks.json"), "old_string": .string("[]"), "new_string": .string("pwned"),
    ])
    XCTAssertTrue(edited.hasPrefix("error: refused — harness files"), edited)
    XCTAssertEqual(try String(contentsOf: hooks, encoding: .utf8), "[]", "the file is untouched")
  }

  func testTheFloorHoldsUnderAutoApproveAndBypassMode() async throws {
    let harness = try tempDir()
    let root = try tempDir()
    let target = harness.appendingPathComponent("rules.json")
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(
        id: "c1", name: "write_file",
        arguments: #"{"path": "\#(target.path)", "content": "{\"allow\":[\"bash\"]}"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    // Everything that could possibly approve the call, all at once: a delegate that says
    // yes to anything, bypass mode, and an allow rule.
    let session = Session(
      service: mock,
      tools: [WriteFileTool(root: root, rules: rules(harness: harness))],
      permissions: AutoApprovePermissions(denySensitive: false),
      store: store(),
      configuration: .init(
        model: "test/model",
        workingDirectory: root,
        permissionMode: .bypass,
        permissionRules: PermissionRules(allow: ["write_file"])))
    var denied = false
    for try await event in await session.send("rewrite the rules") {
      if case .toolDenied = event { denied = true }
    }
    XCTAssertFalse(denied, "no permission layer stopped it — the tool's own floor did")
    let history = await session.history
    let toolMessage = history.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.hasPrefix("error: refused — harness files"), toolMessage)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
  }
}

// MARK: - PermissionRequestTests

/// The tier-aware delegate: `Session` asks with a `PermissionRequest` carrying the gate the
/// call needs, an embedder's legacy three-argument delegate still gets asked through the
/// protocol's default implementation, and an unattended run stops approving `.sensitive`
/// file work.
final class PermissionRequestTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-runs-\(UUID().uuidString).jsonl"))
  }

  /// Implements only the legacy method — what an embedder wrote before this existed.
  private final class LegacyDelegate: PermissionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var seen: [String] = []

    func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
      lock.withLock { seen.append(toolName) }
      return .deny(reason: "legacy said no")
    }
  }

  /// Records the whole request, to prove the tier survives the call.
  private final class RecordingDelegate: PermissionDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [PermissionRequest] = []

    func decide(_ request: PermissionRequest) async -> PermissionDecision {
      lock.withLock { requests.append(request) }
      return .allow
    }

    func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
      .allow
    }
  }

  func testLegacyDelegateIsReachedThroughTheDefaultExtension() async {
    let delegate = LegacyDelegate()
    let decision = await (delegate as any PermissionDelegate).decide(PermissionRequest(
      toolName: "write_file", summary: "write_file a.txt", argumentsJSON: "{}", tier: .sensitive))
    guard case .deny(let reason) = decision else { return XCTFail("expected a deny, got \(decision)") }
    XCTAssertEqual(reason, "legacy said no")
    XCTAssertEqual(delegate.seen, ["write_file"], "the request was forwarded to the three-argument form")
  }

  func testSessionAsksWithTheCallsTier() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-outside-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outside) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "in-tree.txt", "content": "x"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "c2", name: "write_file", arguments: #"{"path": "\#(outside.path)", "content": "x"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let delegate = RecordingDelegate()
    let session = Session(
      service: mock, tools: [WriteFileTool(root: root)], permissions: delegate, store: store(),
      configuration: .init(model: "test/model", workingDirectory: root))
    for try await _ in await session.send("write both") {}
    XCTAssertEqual(delegate.requests.map(\.tier), [.mutating, .sensitive])
    XCTAssertEqual(delegate.requests.map(\.preApproved), [false, false])
    XCTAssertTrue(delegate.requests[1].summary.contains("outside the working directory"))
  }

  /// S3 changed what `preApproved` means, deliberately. It used to say "a mode or a rule
  /// would have skipped this, and an `ask` rule is why you're being asked" — but a
  /// delegate that trusts the flag (`TerminalPermissions` returns `.allow` silently for
  /// it, so the safety judge can see approved commands without a prompt) would then
  /// silently allow exactly the calls an `ask` rule exists to surface. So `ask`
  /// **un-approves**: the flag now means "already approved, you are being informed", and
  /// an ask-forced prompt is a real question.
  func testAskRuleForcesARealPromptAndClearsPreApproved() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-ask-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "a.txt", "content": "x"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let delegate = RecordingDelegate()
    let session = Session(
      service: mock, tools: [WriteFileTool(root: root)], permissions: delegate, store: store(),
      configuration: .init(
        model: "test/model", workingDirectory: root, permissionMode: .bypass,
        permissionRules: PermissionRules(ask: ["write_file"])))
    for try await _ in await session.send("write") {}
    XCTAssertEqual(delegate.requests.count, 1, "bypass mode would have skipped this; the ask rule asked anyway")
    XCTAssertFalse(
      delegate.requests[0].preApproved,
      "an ask rule un-approves the call, so the delegate must treat it as a real question")
  }

  // MARK: AutoApprovePermissions

  func testAutoApproveDeniesSensitiveFileCallsAndAllowsOrdinaryOnes() async {
    let auto = AutoApprovePermissions()
    func decide(_ tool: String, _ tier: ToolPermission) async -> PermissionDecision {
      await (auto as any PermissionDelegate).decide(PermissionRequest(
        toolName: tool, summary: "\(tool) …", argumentsJSON: "{}", tier: tier))
    }
    for tool in AutoApprovePermissions.pathGatedTools {
      guard case .deny(let reason) = await decide(tool, .sensitive) else {
        return XCTFail("\(tool): expected a deny for a sensitive call")
      }
      // The fix named is the tool's: `--add-dir` for a path outside the tree, the config's
      // allowlist for a host `web_fetch` may not reach unattended (T5).
      let fix = tool == WebFetchTool.toolName ? "web.allowedDomains" : "--add-dir"
      XCTAssertTrue(reason?.contains(fix) == true, "the reason points at the fix: \(reason ?? "")")
      guard case .allow = await decide(tool, .mutating) else {
        return XCTFail("\(tool): ordinary mutations are what --yes is for")
      }
    }
    // bash keeps its own floor (catastrophic classifier + judge veto), so a destructive
    // command still runs unattended — panels, evals and Terminal-Bench depend on it.
    guard case .allow = await decide("bash", .sensitive) else {
      return XCTFail("bash is deliberately exempt")
    }
    // MCP tools annotate their own destructiveness; that is not a path escape.
    guard case .allow = await decide("mcp__server__delete", .sensitive) else {
      return XCTFail("MCP tools are deliberately exempt")
    }
    // Opting out restores the old blanket approval.
    guard case .allow = await (AutoApprovePermissions(denySensitive: false) as any PermissionDelegate)
      .decide(PermissionRequest(toolName: "write_file", summary: "s", argumentsJSON: "{}", tier: .sensitive))
    else {
      return XCTFail("denySensitive: false approves everything, as before")
    }
  }

  func testHeadlessRunRefusesAWriteOutsideTheTreeAndTellsTheModelAboutAddDir() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-yes-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-yes-outside-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outside) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "\#(outside.path)", "content": "pwned"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("could not"), Fixtures.usageChunk(cost: 0)],
    ]
    let session = Session(
      service: mock, tools: [WriteFileTool(root: root)],
      permissions: AutoApprovePermissions(), store: store(),
      configuration: .init(model: "test/model", workingDirectory: root))
    var denied = false
    for try await event in await session.send("write outside") {
      if case .toolDenied("write_file", _) = event { denied = true }
    }
    XCTAssertTrue(denied, "--yes no longer approves a write outside the working tree")
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
    let history = await session.history
    let toolMessage = history.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.contains("--add-dir"), toolMessage)
  }

  func testAddDirIsHowAHeadlessRunLegitimatelyReachesASiblingDirectory() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-add-\(UUID().uuidString)")
    let sibling = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-preq-sibling-\(UUID().uuidString)")
    for url in [root, sibling] {
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
    defer { for url in [root, sibling] { try? FileManager.default.removeItem(at: url) } }
    let target = sibling.appendingPathComponent("generated.txt")
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "\#(target.path)", "content": "ok"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let rules = PathScope.Rules(roots: .init(additional: [sibling]))
    let session = Session(
      service: mock, tools: [WriteFileTool(root: root, rules: rules)],
      permissions: AutoApprovePermissions(), store: store(),
      configuration: .init(model: "test/model", workingDirectory: root))
    for try await _ in await session.send("write next door") {}
    XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "ok")
  }
}
