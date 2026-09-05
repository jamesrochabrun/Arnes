import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - PathScopeTests

final class PathScopeTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-scope-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func testInsideOutsideAndTraversal() throws {
    let root = try tempDir()
    try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    XCTAssertEqual(PathScope.classify("a.txt", root: root), .inside)
    XCTAssertEqual(PathScope.classify(".", root: root), .inside)
    XCTAssertEqual(PathScope.classify("sub/deeper.swift", root: root), .inside)
    XCTAssertEqual(PathScope.classify(root.appendingPathComponent("a.txt").path, root: root), .inside)
    XCTAssertEqual(PathScope.classify("../sibling", root: root), .outside)
    XCTAssertEqual(PathScope.classify("/etc/hosts", root: root), .outside)
    // A sibling whose name merely starts with the root's name is not inside it.
    XCTAssertEqual(PathScope.classify(root.path + "-evil/x", root: root), .outside)
  }

  func testSymlinkOutOfTheTreeIsOutside() throws {
    let root = try tempDir()
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"),
      withDestinationURL: URL(fileURLWithPath: "/etc"))
    XCTAssertEqual(PathScope.classify("escape/hosts", root: root), .outside)
  }

  func testCredentialLocationsAreSensitiveEvenWhenInsideTheRoot() throws {
    let home = try tempDir()
    let root = try tempDir()
    XCTAssertEqual(PathScope.classify(home.appendingPathComponent(".ssh/id_rsa").path, root: root, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(home.appendingPathComponent(".aws").path, root: root, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(home.appendingPathComponent(".arnes/credentials").path, root: root, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify(home.appendingPathComponent("code/app.swift").path, root: root, home: home.path), .outside)
    // Working inside the home directory itself: the tree is "inside", the secrets still aren't free.
    XCTAssertEqual(PathScope.classify(".ssh/config", root: home, home: home.path), .sensitive)
    XCTAssertEqual(PathScope.classify("notes.md", root: home, home: home.path), .inside)
  }

  func testReadToolsGateByPath() throws {
    let root = try tempDir()
    let read = ReadFileTool(root: root)
    XCTAssertEqual(read.permission, .readOnly)
    XCTAssertEqual(read.permission(for: ["path": .string("a.txt")]), .readOnly)
    XCTAssertEqual(read.permission(for: ["path": .string("/etc/hosts")]), .sensitive)
    XCTAssertEqual(read.permission(for: [:]), .readOnly, "a missing path fails in execute, not at the gate")
    XCTAssertEqual(read.summary(arguments: ["path": .string("/etc/hosts")]), "read_file /etc/hosts (outside the working directory)")

    let grep = GrepTool(root: root)
    XCTAssertEqual(grep.permission(for: ["pattern": .string("x")]), .readOnly)
    XCTAssertEqual(grep.permission(for: ["pattern": .string("x"), "path": .string("..")]), .sensitive)
    XCTAssertTrue(grep.summary(arguments: ["pattern": .string("x"), "path": .string("..")]).contains("outside"))

    let glob = GlobTool(root: root)
    XCTAssertEqual(glob.permission(for: ["pattern": .string("*.swift")]), .readOnly)
    XCTAssertEqual(glob.permission(for: ["pattern": .string("*"), "path": .string("/")]), .sensitive)
  }
}

// MARK: - SessionReadGateTests

final class SessionReadGateTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-gate-runs-\(UUID().uuidString).jsonl"))
  }

  private func script(reading path: String) -> [[ChatCompletionChunk]] {
    [
      [Fixtures.toolCallChunk(id: "c1", name: "read_file", arguments: #"{"path": "\#(path)"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
  }

  func testReadOutsideTheWorkingDirectoryAsksAndCanBeDenied() async throws {
    let outside = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-outside-\(UUID().uuidString).txt")
    try "secret".write(to: outside, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: outside) }

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = script(reading: outside.path)
    let permissions = ScriptedPermissions([.deny(reason: "not that file")])
    let session = Session(
      service: mock, tools: [ReadFileTool()], permissions: permissions, store: store(),
      configuration: .init(model: "test/model"))
    var denied = false
    for try await event in await session.send("read it") {
      if case .toolDenied(let name, _) = event { denied = name == "read_file" }
    }
    XCTAssertTrue(denied)
    XCTAssertEqual(permissions.asks, ["read_file"])
    let history = await session.history
    let toolResult = history.first { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolResult.contains("denied"), "the model is told, not the file")
    XCTAssertFalse(toolResult.contains("secret"))
  }

  func testReadInsideTheWorkingDirectoryRunsFreely() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = script(reading: "Package.swift") // relative to the process CWD (the package)
    let permissions = ScriptedPermissions([.deny(reason: "should never be asked")])
    let session = Session(
      service: mock, tools: [ReadFileTool()], permissions: permissions, store: store(),
      configuration: .init(model: "test/model"))
    for try await _ in await session.send("read it") {}
    XCTAssertEqual(permissions.asks, [])
    let history = await session.history
    XCTAssertTrue(history.first { $0.role == .tool }?.content?.plainText.contains("swift-tools-version") == true)
  }
}

// MARK: - SecureFilesTests

final class SecureFilesTests: XCTestCase {
  private func mode(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
  }

  func testDirectoriesAreOwnerOnlyAndFilesAre0600() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-secure-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: base) }
    let nested = base.appendingPathComponent("a/b")
    try SecureFiles.ensureDirectory(nested)
    XCTAssertEqual(try mode(base) & 0o777, 0o700)
    XCTAssertEqual(try mode(nested) & 0o777, 0o700)
    try SecureFiles.ensureDirectory(nested) // idempotent

    let file = nested.appendingPathComponent("trusted.json")
    try SecureFiles.writePrivate(Data("{}".utf8), to: file)
    XCTAssertEqual(try mode(file) & 0o777, 0o600)
    XCTAssertFalse(SecureFiles.isReadableByOthers(file))

    // Appended stores (runs, sessions, evals, verdicts) are created 0600 too.
    let runs = RunRecordStore(url: base.appendingPathComponent("c/runs.jsonl"))
    try runs.append(RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "other"))
    XCTAssertEqual(try mode(runs.url) & 0o777, 0o600)
    XCTAssertEqual(try mode(base.appendingPathComponent("c")) & 0o777, 0o700)

    let sessions = SessionStore(directory: base.appendingPathComponent("sessions"))
    try sessions.append(.meta(id: "S1", model: "m", cwd: nil), to: "S1")
    XCTAssertEqual(try mode(base.appendingPathComponent("sessions/S1.jsonl")) & 0o777, 0o600)

    let loose = base.appendingPathComponent("loose")
    try Data("k".utf8).write(to: loose)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: loose.path)
    XCTAssertTrue(SecureFiles.isReadableByOthers(loose))
    XCTAssertFalse(SecureFiles.isReadableByOthers(base.appendingPathComponent("missing")))
  }
}
