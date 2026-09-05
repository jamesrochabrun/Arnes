import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Test doubles

/// Answers scripted decisions and remembers every request it saw.
private final class RecordingPermissions: PermissionDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [PermissionDecision]
  private(set) var requests: [PermissionRequest] = []

  init(_ answers: [PermissionDecision]) { self.answers = answers }

  var asked: [String] { lock.withLock { requests.map(\.toolName) } }
  var seen: [PermissionRequest] { lock.withLock { requests } }

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

/// A read-only tool whose every result taints the session (an untrusted MCP server's shape).
private struct TaintSourceTool: AgentTool, TaintingTool {
  let name = "untrusted_fetch"
  let description = "taints"
  var parameters: JSONValue { .object(["type": .string("object")]) }
  var permission: ToolPermission { .readOnly }
  var taintsResults: Bool { true }
  var taintSource: String { "mcp:test" }
  func summary(arguments: [String: JSONValue]) -> String { name }
  func execute(arguments: [String: JSONValue]) async throws -> String { "data" }
}

// MARK: - AutoReadTests

/// The safe-auto UX for plain out-of-tree reads: "always this session" remembers a scoped
/// `Read(<dir>/**)` grant (one prompt per tree, not per file), `acceptEdits`/`bypass`
/// auto-approve such reads outright, the grant store is shared with subagents — and none of
/// it reaches a credential/`denyRead` path, a tainted session, or a read-only posture.
final class AutoReadTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-autoread-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-autoread-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A sibling "checkout": a directory holding a `.git` marker and two source files.
  private func makeRepo() throws -> URL {
    let repo = try tempDir("repo")
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
    try "let a = 1".write(to: repo.appendingPathComponent("Sources/a.swift"), atomically: true, encoding: .utf8)
    try "let b = 2".write(to: repo.appendingPathComponent("Sources/b.swift"), atomically: true, encoding: .utf8)
    return repo
  }

  private func mock(_ scripts: [[ChatCompletionChunk]]) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = scripts
    return mock
  }

  private func readScript(_ paths: [String], grepIn grepPath: String? = nil) -> [[ChatCompletionChunk]] {
    var scripts = paths.enumerated().map { index, path in
      [Fixtures.toolCallChunk(id: "r\(index)", name: "read_file", arguments: #"{"path":"\#(path)"}"#),
       Fixtures.usageChunk(cost: 0)]
    }
    if let grepPath {
      scripts.append(
        [Fixtures.toolCallChunk(
          id: "g0", name: "grep", arguments: #"{"pattern":"let","path":"\#(grepPath)"}"#),
         Fixtures.usageChunk(cost: 0)])
    }
    scripts.append([Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)])
    return scripts
  }

  private func session(
    tools: [any AgentTool],
    permissions: any PermissionDelegate,
    mock: MockOpenRouterService,
    root: URL,
    mode: PermissionMode = .default)
    -> Session
  {
    Session(
      service: mock, tools: tools, permissions: permissions, store: store(),
      configuration: .init(
        model: "test/model", workingDirectory: root, permissionMode: mode))
  }

  // MARK: PathScope.outsideReadPath — only a *plain* outside read qualifies

  func testOutsideReadPathAnswersForPlainOutsideAndNilEverywhereElse() throws {
    let root = try tempDir("root")
    let repo = try makeRepo()
    let outside = repo.appendingPathComponent("Sources/a.swift").path

    XCTAssertEqual(
      PathScope.outsideReadPath(outside, root: root),
      PathScope.physicalPath(outside),
      "a plain outside read answers its resolved path")
    XCTAssertNil(
      PathScope.outsideReadPath("inside.txt", root: root),
      "an in-tree read is not gated at all")
    XCTAssertNil(
      PathScope.outsideReadPath(NSHomeDirectory() + "/.ssh/id_rsa", root: root),
      "a credential location is never a plain read")
    let rules = PathScope.Rules(policy: PathPolicy(denyRead: ["*.pem"]))
    XCTAssertNil(
      PathScope.outsideReadPath(repo.appendingPathComponent("key.pem").path, root: root, rules: rules),
      "a paths.denyRead match is never a plain read")
  }

  // MARK: PathScope.readGrantDirectory — the scope "always" remembers

  func testReadGrantDirectoryFindsTheRepoRootAndRefusesHome() throws {
    let repo = try makeRepo()
    let resolvedRepo = PathScope.physicalPath(repo.path)
    let file = PathScope.physicalPath(repo.appendingPathComponent("Sources/a.swift").path)
    XCTAssertEqual(
      PathScope.readGrantDirectory(forResolvedPath: file), resolvedRepo,
      "a file inside a checkout grants the checkout root")
    XCTAssertEqual(
      PathScope.readGrantDirectory(forResolvedPath: resolvedRepo), resolvedRepo,
      "the directory itself (a grep/glob path argument) grants itself")

    let plain = try tempDir("plain")
    let resolvedPlain = PathScope.physicalPath(plain.path)
    try "x".write(to: plain.appendingPathComponent("f.txt"), atomically: true, encoding: .utf8)
    XCTAssertEqual(
      PathScope.readGrantDirectory(forResolvedPath: resolvedPlain + "/f.txt"), resolvedPlain,
      "no repo → the file's own directory")

    // The home directory, an ancestor of it, and `/` grant nothing — too broad to remember.
    let fakeHome = try tempDir("home")
    let home = PathScope.physicalPath(fakeHome.path)
    XCTAssertNil(PathScope.readGrantDirectory(forResolvedPath: home + "/notes.txt", home: home))
    let parent = (home as NSString).deletingLastPathComponent
    XCTAssertNil(
      PathScope.readGrantDirectory(forResolvedPath: parent + "/stray.txt", home: home),
      "a file whose directory is an ancestor of home grants nothing")
    // A `.git` at the home level is never consulted: the walk stops before home.
    try FileManager.default.createDirectory(
      at: fakeHome.appendingPathComponent(".git"), withIntermediateDirectories: true)
    let sub = fakeHome.appendingPathComponent("sub/proj")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    XCTAssertEqual(
      PathScope.readGrantDirectory(forResolvedPath: PathScope.physicalPath(sub.path) + "/f.txt", home: home),
      PathScope.physicalPath(sub.path))
  }

  // MARK: `Read(...)` rules and grants reach view_image too

  func testReadRuleMatchesViewImage() {
    let rule = try! XCTUnwrap(PermissionRule("Read(/x/**)"))
    XCTAssertTrue(rule.matches(
      tool: "view_image", arguments: ["path": .string("/x/shot.png")], root: nil,
      bashSegments: [], matchAll: true))
  }

  // MARK: default mode — one `a` covers the tree, for every read tool, subagents included

  func testAlwaysOnAnOutsideReadGrantsTheRepoAndTheFanOutRunsFree() async throws {
    let root = try tempDir("root")
    let repo = try makeRepo()
    let a = repo.appendingPathComponent("Sources/a.swift").path
    let b = repo.appendingPathComponent("Sources/b.swift").path
    let permissions = RecordingPermissions([.allowAlwaysThisSession])
    let mock = mock(readScript([a, b], grepIn: repo.path))
    let session = session(
      tools: [ReadFileTool(root: root), GrepTool(root: root)],
      permissions: permissions, mock: mock, root: root)
    for try await _ in await session.send("survey the sibling checkout") {}

    let resolved = PathScope.physicalPath(repo.path)
    let grants = await session.sessionGrants
    XCTAssertEqual(grants, ["Read(\(resolved))", "Read(\(resolved)/**)"])
    XCTAssertEqual(
      permissions.asked, ["read_file"],
      "the second read and the grep rode the grant — one prompt for the whole tree")
    let request = try XCTUnwrap(permissions.seen.first)
    XCTAssertEqual(request.grantScope, resolved, "the prompt was told what `a` would cover")
    let decisions = await session.lastRecord?.decisions
    let rows = try XCTUnwrap(decisions)
    XCTAssertEqual(rows.map(\.source), [.user, .grant, .grant])
    XCTAssertEqual(rows.map(\.decision), [.allow, .allow, .allow])
  }

  func testAlwaysOnACredentialReadGrantsNothingAndAsksAgain() async throws {
    let root = try tempDir("root")
    let key = NSHomeDirectory() + "/.ssh/arnes-autoread-nonexistent"
    let permissions = RecordingPermissions([.allowAlwaysThisSession, .deny(reason: "asked again, good")])
    let mock = mock(readScript([key, key]))
    let session = session(
      tools: [ReadFileTool(root: root)], permissions: permissions, mock: mock, root: root)
    for try await _ in await session.send("read the key twice") {}

    let grants = await session.sessionGrants
    XCTAssertEqual(grants, [], "a credential location is approve-once, never a standing grant")
    XCTAssertEqual(permissions.asked, ["read_file", "read_file"])
    XCTAssertNil(permissions.seen.first?.grantScope, "and the prompt offers no scope for it")
  }

  // MARK: acceptEdits / bypass — plain outside reads run free, guarded classes still ask

  func testAcceptEditsAndBypassAutoApprovePlainOutsideReads() async throws {
    for mode in [PermissionMode.acceptEdits, .bypass] {
      let root = try tempDir("root")
      let repo = try makeRepo()
      let permissions = RecordingPermissions([])
      let mock = mock(readScript([repo.appendingPathComponent("Sources/a.swift").path]))
      let session = session(
        tools: [ReadFileTool(root: root)], permissions: permissions, mock: mock, root: root,
        mode: mode)
      for try await _ in await session.send("read the sibling file") {}

      XCTAssertEqual(permissions.asked, [], "\(mode): the plain outside read never prompted")
      let decisions = await session.lastRecord?.decisions
    let rows = try XCTUnwrap(decisions)
      XCTAssertEqual(rows.map(\.source), [.mode], "\(mode)")
      XCTAssertEqual(rows.map(\.decision), [.allow], "\(mode)")
      XCTAssertEqual(rows.map(\.tier), [.sensitive], "\(mode)")
    }
  }

  func testBypassStillAsksForACredentialRead() async throws {
    let root = try tempDir("root")
    let key = NSHomeDirectory() + "/.ssh/arnes-autoread-nonexistent"
    let permissions = RecordingPermissions([.deny(reason: "no")])
    let mock = mock(readScript([key]))
    let session = session(
      tools: [ReadFileTool(root: root)], permissions: permissions, mock: mock, root: root,
      mode: .bypass)
    for try await _ in await session.send("read the key") {}

    XCTAssertEqual(permissions.asked, ["read_file"], "bypass never covers a credential location")
  }

  func testDefaultModeStillPromptsForEveryOutsideRead() async throws {
    let root = try tempDir("root")
    let repo = try makeRepo()
    let permissions = RecordingPermissions([.allow, .allow])
    let mock = mock(readScript(
      [repo.appendingPathComponent("Sources/a.swift").path,
       repo.appendingPathComponent("Sources/b.swift").path]))
    let session = session(
      tools: [ReadFileTool(root: root)], permissions: permissions, mock: mock, root: root)
    for try await _ in await session.send("read both") {}

    XCTAssertEqual(
      permissions.asked, ["read_file", "read_file"],
      "a plain `y` approves that call only — default mode is unchanged")
    let grants = await session.sessionGrants
    XCTAssertEqual(grants, [])
  }

  // MARK: taint — after untrusted content the auto path closes

  func testTaintClosesAStandingReadGrant() async throws {
    let root = try tempDir("root")
    let repo = try makeRepo()
    let a = repo.appendingPathComponent("Sources/a.swift").path
    let b = repo.appendingPathComponent("Sources/b.swift").path
    // Default mode: read a (granted by `a`), taint the session, read b — the grant must
    // stop applying and the prompt must carry the taint.
    let permissions = RecordingPermissions([.allowAlwaysThisSession, .deny(reason: "human says no")])
    var scripts = readScript([a])
    scripts.removeLast() // drop the closing text step; continue the same turn
    scripts.append(
      [Fixtures.toolCallChunk(id: "t0", name: "untrusted_fetch", arguments: "{}"),
       Fixtures.usageChunk(cost: 0)])
    scripts.append(
      [Fixtures.toolCallChunk(id: "r9", name: "read_file", arguments: #"{"path":"\#(b)"}"#),
       Fixtures.usageChunk(cost: 0)])
    scripts.append([Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)])
    let mock = mock(scripts)
    let session = session(
      tools: [ReadFileTool(root: root), TaintSourceTool()],
      permissions: permissions, mock: mock, root: root)
    for try await _ in await session.send("read, fetch, read") {}

    let grants = await session.sessionGrants
    XCTAssertFalse(grants.isEmpty, "the pre-taint `a` did record the scoped grant")
    XCTAssertEqual(
      permissions.asked, ["read_file", "read_file"],
      "after the taint the second read prompted again — the grant stopped applying")
    let second = try XCTUnwrap(permissions.seen.last)
    XCTAssertTrue(second.tainted, "the delegate was told the session is tainted")
    XCTAssertNil(second.grantScope, "and a tainted approval is never remembered")
  }

  func testTaintClosesTheBypassModeApprovalToo() async throws {
    let root = try tempDir("root")
    let repo = try makeRepo()
    let b = repo.appendingPathComponent("Sources/b.swift").path
    // Bypass mode: taint first, then read — the mode that would have waved the read
    // through must not, and the prompt carries the taint.
    let permissions = RecordingPermissions([.deny(reason: "human says no")])
    let mock = mock([
      [Fixtures.toolCallChunk(id: "t0", name: "untrusted_fetch", arguments: "{}"),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "r0", name: "read_file", arguments: #"{"path":"\#(b)"}"#),
       Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ])
    let session = session(
      tools: [ReadFileTool(root: root), TaintSourceTool()],
      permissions: permissions, mock: mock, root: root, mode: .bypass)
    for try await _ in await session.send("fetch, then read") {}

    XCTAssertEqual(permissions.asked, ["read_file"], "bypass did not cover the tainted read")
    let request = try XCTUnwrap(permissions.seen.last)
    XCTAssertTrue(request.tainted)
    XCTAssertNil(request.grantScope)
  }

  // MARK: the grant store is shared with subagents

  func testForSubagentSharesTheGrantStore() {
    let configuration = Session.Configuration(model: "test/model")
    let nested = configuration.forSubagent(named: "explore", model: "test/model", systemSuffix: "role")
    XCTAssertTrue(nested.grants === configuration.grants, "one store, not a copy")
    nested.grants.insert("Read(/x/**)")
    XCTAssertEqual(configuration.grants.patterns, ["Read(/x/**)"],
                   "a grant answered on a nested prompt covers the lead too")
  }

  func testAGrantFromTheConfigurationStoreSkipsThePromptInAnotherSession() async throws {
    // Two sessions over one configuration-shaped store — the lead/subagent shape without
    // spawning a task tool: a grant recorded in the first frees the second.
    let root = try tempDir("root")
    let repo = try makeRepo()
    let a = repo.appendingPathComponent("Sources/a.swift").path
    let shared = SessionGrants()
    func makeSession(_ permissions: RecordingPermissions, mock: MockOpenRouterService) -> Session {
      Session(
        service: mock, tools: [ReadFileTool(root: root)], permissions: permissions, store: store(),
        configuration: .init(model: "test/model", workingDirectory: root, grants: shared))
    }
    let first = RecordingPermissions([.allowAlwaysThisSession])
    let one = makeSession(first, mock: mock(readScript([a])))
    for try await _ in await one.send("read it") {}
    XCTAssertEqual(first.asked, ["read_file"])

    let second = RecordingPermissions([])
    let two = makeSession(second, mock: mock(readScript([a])))
    for try await _ in await two.send("read it again") {}
    XCTAssertEqual(second.asked, [], "the second session rode the first one's grant")
    let decisions = await two.lastRecord?.decisions
    let rows = try XCTUnwrap(decisions)
    XCTAssertEqual(rows.map(\.source), [.grant])
  }

  // MARK: a read-only posture outranks the mode

  func testReadOnlyPostureRefusesTheModeApprovedRead() async throws {
    let root = try tempDir("root")
    let repo = try makeRepo()
    let mock = mock(readScript([repo.appendingPathComponent("Sources/a.swift").path]))
    let session = session(
      tools: [ReadFileTool(root: root)], permissions: DenyMutationsPermissions(),
      mock: mock, root: root, mode: .acceptEdits)
    var denied = false
    for try await event in await session.send("read the sibling file") {
      if case .toolDenied(let name, _) = event { denied = name == "read_file" }
    }
    XCTAssertTrue(denied, "DenyMutationsPermissions sees the pre-approved read and refuses it")
  }
}
