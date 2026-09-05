import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - WriteScopeTests

/// The write-side path gate: `write_file`/`edit_file` are routine inside the working tree
/// and `.sensitive` (never covered by "always", vetoed headless) anywhere that a write
/// changes what runs — outside the tree, credential/startup files, `.git/hooks`, CI.
final class WriteScopeTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-wscope-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testInsideIsOrdinaryAndOutsideIsSensitive() throws {
    let root = try tempDir()
    XCTAssertEqual(PathScope.classify(forWriting: "src/main.swift", root: root), .inside)
    XCTAssertEqual(PathScope.classify(forWriting: "new/dir/file.txt", root: root), .inside, "a file that doesn't exist yet still classifies")
    XCTAssertEqual(PathScope.classify(forWriting: "../sibling.txt", root: root), .outside)
    XCTAssertEqual(PathScope.classify(forWriting: "/etc/hosts", root: root), .outside)
    XCTAssertEqual(PathScope.permission(forWriting: "src/main.swift", root: root), .mutating)
    XCTAssertEqual(PathScope.permission(forWriting: "/etc/hosts", root: root), .sensitive)
  }

  func testProtectedInTreePathsAreSensitive() throws {
    let root = try tempDir()
    for path in [".git/hooks/pre-commit", ".git/config", ".github/workflows/ci.yml", ".arnes/agents/evil.md", ".claude/skills/x/SKILL.md", ".mcp.json"] {
      XCTAssertEqual(PathScope.classify(forWriting: path, root: root), .sensitive, path)
    }
    // Neighbours that merely share a prefix stay routine.
    XCTAssertEqual(PathScope.classify(forWriting: ".github/CODEOWNERS", root: root), .inside)
    XCTAssertEqual(PathScope.classify(forWriting: ".gitignore", root: root), .inside)
    XCTAssertEqual(PathScope.classify(forWriting: ".arnesrc", root: root), .inside)
  }

  func testShellStartupAndCredentialFilesAreSensitiveWherever() throws {
    let home = try tempDir()
    let root = try tempDir()
    XCTAssertEqual(PathScope.classify(forWriting: home.appendingPathComponent(".zshrc").path, root: root, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(forWriting: home.appendingPathComponent(".gitconfig").path, root: root, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(forWriting: home.appendingPathComponent("Library/LaunchAgents/x.plist").path, root: root, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(forWriting: home.appendingPathComponent(".ssh/authorized_keys").path, root: root, home: home.path), .sensitive)
    // Working *in* the home directory: notes are routine, the rc file is not.
    XCTAssertEqual(PathScope.classify(forWriting: ".zshrc", root: home, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(forWriting: "notes.md", root: home, home: home.path), .inside)
  }

  func testSymlinkOutOfTheTreeIsSensitive() throws {
    let root = try tempDir()
    let outside = try tempDir()
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    XCTAssertEqual(PathScope.permission(forWriting: "escape/payload.sh", root: root), .sensitive)
  }

  func testWriteAndEditToolsGateByPath() throws {
    let root = try tempDir()
    let write = WriteFileTool(root: root)
    XCTAssertEqual(write.permission, .mutating)
    XCTAssertEqual(write.permission(for: ["path": .string("a.txt"), "content": .string("x")]), .mutating)
    XCTAssertEqual(write.permission(for: ["path": .string("/etc/hosts"), "content": .string("x")]), .sensitive)
    XCTAssertEqual(write.permission(for: ["path": .string(".git/hooks/post-checkout"), "content": .string("x")]), .sensitive)
    XCTAssertEqual(write.permission(for: [:]), .mutating, "a missing path fails in execute, not at the gate")
    XCTAssertEqual(
      write.summary(arguments: ["path": .string("/etc/hosts"), "content": .string("x")]),
      "write_file /etc/hosts (1 bytes) (outside the working directory)")
    XCTAssertTrue(write.summary(arguments: ["path": .string(".git/hooks/x"), "content": .string("x")]).hasSuffix("(protected path)"))

    let edit = EditFileTool(root: root)
    XCTAssertEqual(edit.permission(for: ["path": .string("a.txt")]), .mutating)
    XCTAssertEqual(edit.permission(for: ["path": .string("../x")]), .sensitive)
    XCTAssertTrue(edit.summary(arguments: ["path": .string("../x")]).contains("outside"))
  }

  // MARK: --add-dir

  func testAddDirMakesASiblingInsideWhileEverythingElseStaysSensitive() throws {
    let root = try tempDir()
    let sibling = try tempDir()
    let unrelated = try tempDir()
    let rules = PathScope.Rules(roots: .init(additional: [sibling]))

    let file = sibling.appendingPathComponent("src/generated.swift").path
    XCTAssertEqual(PathScope.classify(file, root: root), .outside, "without --add-dir it is an escape")
    XCTAssertEqual(PathScope.classify(file, root: root, rules: rules), .inside)
    XCTAssertEqual(PathScope.classify(forWriting: file, root: root, rules: rules), .inside)
    XCTAssertEqual(PathScope.permission(forReading: file, root: root, rules: rules), .readOnly)
    XCTAssertEqual(PathScope.permission(forWriting: file, root: root, rules: rules), .mutating)

    // A directory that wasn't named stays gated.
    let other = unrelated.appendingPathComponent("x.txt").path
    XCTAssertEqual(PathScope.classify(forWriting: other, root: root, rules: rules), .outside)
    XCTAssertEqual(PathScope.permission(forWriting: other, root: root, rules: rules), .sensitive)

    // Widening the roots never reaches a credential or protected path.
    let home = try tempDir()
    XCTAssertEqual(
      PathScope.classify(forWriting: home.appendingPathComponent(".ssh/config").path,
                         root: root, rules: PathScope.Rules(roots: .init(additional: [home])), home: home.path),
      .sensitive)
    XCTAssertEqual(
      PathScope.classify(forWriting: sibling.appendingPathComponent(".git/hooks/pre-push").path,
                         root: root, rules: rules),
      .sensitive,
      "an added directory's .git/hooks is protected like the working tree's")

    // Bash's read-only fast path follows the same roots: an absolute path is rejected
    // outright when no directory was added, and classified when one was.
    let existing = sibling.appendingPathComponent("real.txt")
    try "x".write(to: existing, atomically: true, encoding: .utf8)
    XCTAssertFalse(ShellCommand.isReadOnly("cat \(existing.path)", root: root))
    XCTAssertTrue(ShellCommand.isReadOnly("cat \(existing.path)", root: root, rules: rules))
    XCTAssertEqual(ShellCommand.risk("cat \(existing.path)", root: root, rules: rules), .readOnly)
    // …but only for the directories that were actually named.
    let elsewhere = unrelated.appendingPathComponent("secret.txt")
    try "x".write(to: elsewhere, atomically: true, encoding: .utf8)
    XCTAssertFalse(ShellCommand.isReadOnly("cat \(elsewhere.path)", root: root, rules: rules))
    XCTAssertFalse(ShellCommand.isReadOnly("cat ~/.ssh/id_rsa", root: root, rules: rules))
  }

  func testAddDirReachesTheToolsThroughTheToolContext() {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wscope-ctx-\(UUID().uuidString)")
    let sibling = FileManager.default.temporaryDirectory.appendingPathComponent("wscope-sib-\(UUID().uuidString)")
    let tools = HarnessAssembly.coreTools(ToolContext(
      root: root, pathRules: PathScope.Rules(roots: .init(additional: [sibling]))))
    let target = sibling.appendingPathComponent("notes.md").path
    for name in ["write_file", "edit_file"] {
      let tool = tools.first { $0.name == name }
      XCTAssertEqual(tool?.permission(for: ["path": .string(target)]), .mutating, name)
    }
    XCTAssertEqual(
      tools.first { $0.name == "read_file" }?.permission(for: ["path": .string(target)]), .readOnly)
  }

  // MARK: config `paths`

  func testConfigProtectedAndDenyReadGlobsTightenTheClassification() throws {
    let root = try tempDir()
    let rules = PathScope.Rules(policy: PathPolicy(
      protected: ["deploy/**", "*.tfstate"],
      sensitiveWrite: [],
      denyRead: ["**/.env*", "**/*.pem"]))
    // An in-tree write the built-in list wouldn't flag is promoted to `.sensitive`.
    XCTAssertEqual(PathScope.classify(forWriting: "deploy/prod.yml", root: root), .inside)
    XCTAssertEqual(PathScope.classify(forWriting: "deploy/prod.yml", root: root, rules: rules), .sensitive)
    XCTAssertEqual(PathScope.classify(forWriting: "infra/main.tfstate", root: root, rules: rules), .sensitive)
    XCTAssertEqual(PathScope.classify(forWriting: "src/main.swift", root: root, rules: rules), .inside)
    XCTAssertTrue(
      PathScope.writeNote(for: "deploy/prod.yml", root: root, rules: rules).hasSuffix("(protected path)"))
    // denyRead makes an in-tree *read* sensitive.
    XCTAssertEqual(PathScope.permission(forReading: "config/.env.local", root: root, rules: rules), .sensitive)
    XCTAssertEqual(PathScope.permission(forReading: "certs/server.pem", root: root, rules: rules), .sensitive)
    XCTAssertEqual(PathScope.permission(forReading: "README.md", root: root, rules: rules), .readOnly)
    // …and reaches read_file / grep / glob.
    let tools = HarnessAssembly.coreTools(ToolContext(root: root, pathRules: rules))
    XCTAssertEqual(
      tools.first { $0.name == "read_file" }?.permission(for: ["path": .string(".env")]), .sensitive)
    XCTAssertEqual(
      tools.first { $0.name == "grep" }?.permission(for: ["pattern": .string("x"), "path": .string(".env")]),
      .sensitive)
  }

  func testDenyReadKeepsGrepAndGlobFromListingMatchingFiles() async throws {
    let root = try tempDir()
    try "TOKEN=secret".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try "TOKEN=example".write(to: root.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
    try "let token = 1".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
    let rules = PathScope.Rules(policy: PathPolicy(denyRead: ["**/.env", "**/.env.*"]))

    // Without the policy, grep happily prints the secret.
    let open = GrepTool(root: root)
    let openOutput = try await open.execute(arguments: ["pattern": .string("TOKEN")])
    XCTAssertTrue(openOutput.contains("secret"), openOutput)

    // With it, the search root is still readable but the named files are skipped — gating
    // only the `path` argument would leak them through a recursive search.
    let closed = GrepTool(root: root, rules: rules)
    let output = try await closed.execute(arguments: ["pattern": .string("TOKEN")])
    XCTAssertFalse(output.contains("secret"), output)
    XCTAssertFalse(output.contains("example"), output)
    let listed = try await GlobTool(root: root, rules: rules).execute(arguments: ["pattern": .string("*")])
    XCTAssertTrue(listed.contains("main.swift"), listed)
    XCTAssertFalse(listed.contains(".env"), listed)
  }

  func testConfigPathsDecodeAndDefaultToEmpty() throws {
    let json = #"{"paths": {"denyRead": ["**/.env*"]}}"#
    let config = try JSONDecoder().decode(ArnesConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.paths?.denyRead, ["**/.env*"])
    XCTAssertEqual(config.paths?.protected, [], "absent keys decode as empty, not nil")
    XCTAssertNil(try JSONDecoder().decode(ArnesConfig.self, from: Data("{}".utf8)).paths)
  }

  // MARK: TOCTOU

  func testParentDirectorySwappedBetweenCheckAndWriteIsRefused() throws {
    let root = try tempDir()
    let real = root.appendingPathComponent("real")
    let decoy = try tempDir()
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("workdir")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

    // What a write to `workdir/out.txt` would have been checked against.
    let checked = FileIdentity.of(PathScope.physicalPath(link.path))
    XCTAssertNotNil(checked)
    XCTAssertTrue(FileIdentity.unchanged(link.path, since: checked), "nothing moved yet")

    // Now flip the link at somebody else's directory, the way a race would.
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: decoy)
    XCTAssertFalse(
      FileIdentity.unchanged(link.path, since: checked),
      "the name now reaches a different directory — the write must refuse")

    // A directory that doesn't exist yet has nothing to compare against, so ordinary
    // `write_file` into a new folder is unaffected.
    XCTAssertNil(FileIdentity.of(root.appendingPathComponent("nope").path))
    XCTAssertTrue(FileIdentity.unchanged(root.appendingPathComponent("nope").path, since: nil))
  }

  func testOrdinaryWritesAndEditsStillSucceedWithTheGuardInPlace() async throws {
    let root = try tempDir()
    let write = WriteFileTool(root: root)
    let created = try await write.execute(arguments: [
      "path": .string("new/dir/file.txt"), "content": .string("hello"),
    ])
    XCTAssertTrue(created.hasPrefix("created "), created)
    let edit = EditFileTool(root: root)
    let edited = try await edit.execute(arguments: [
      "path": .string("new/dir/file.txt"), "old_string": .string("hello"), "new_string": .string("bye"),
    ])
    XCTAssertTrue(edited.hasPrefix("edited "), edited)
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("new/dir/file.txt"), encoding: .utf8), "bye")
  }
}

// MARK: - SessionWriteGateTests

final class SessionWriteGateTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-wgate-runs-\(UUID().uuidString).jsonl"))
  }

  /// One write attempt, then a final text step.
  private func script(writing path: String) -> [[ChatCompletionChunk]] {
    [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path": "\#(path)", "content": "pwned"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
  }

  func testAlwaysAllowOnASensitiveWriteDoesNotBecomeAStandingGrant() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-wgate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-wgate-outside-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outside) }

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // Turn 1: a sensitive write answered "always". Turn 2: an ordinary in-tree write —
    // must still ask, because "always" on a sensitive call covers that call only.
    mock.chunkScripts = script(writing: outside.path) + script(writing: "in-tree.txt")
    let permissions = ScriptedPermissions([.allowAlwaysThisSession, .deny(reason: "asked again, good")])
    let session = Session(
      service: mock, tools: [WriteFileTool(root: root)], permissions: permissions, store: store(),
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("write outside") {}
    XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "pwned", "the one approved call ran")
    for try await _ in await session.send("write inside") {}
    XCTAssertEqual(permissions.asks, ["write_file", "write_file"], "the second write prompted instead of riding the grant")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("in-tree.txt").path))
  }

  func testHeadlessDenyRefusesTheOutOfTreeWriteAndTellsTheModel() async throws {
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-wgate-headless-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outside) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = script(writing: outside.path)
    let session = Session(
      service: mock, tools: [WriteFileTool()], permissions: DenyMutationsPermissions(), store: store(),
      configuration: .init(model: "test/model"))
    var denied = false
    for try await event in await session.send("write it") {
      if case .toolDenied(let name, _) = event { denied = name == "write_file" }
    }
    XCTAssertTrue(denied)
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
  }
}
