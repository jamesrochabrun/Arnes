import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The permission mode + rules seam inside the live loop: plan denies gated tools,
/// acceptEdits auto-approves in-tree edits, a deny rule refuses, an allow rule skips the
/// prompt.
final class SessionPermissionModeTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-mode-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-mode-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// One write to `path`, then a final text step.
  private func writeScript(_ path: String) -> [[ChatCompletionChunk]] {
    [
      [Fixtures.toolCallChunk(id: "w1", name: "write_file", arguments: #"{"path":"\#(path)","content":"x"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
  }

  private func session(root: URL, mode: PermissionMode = .default, rules: PermissionRules = .empty, permissions: any PermissionDelegate) -> Session {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = writeScript("in-tree.txt")
    return Session(
      service: mock, tools: [WriteFileTool(root: root)], permissions: permissions, store: store(),
      configuration: .init(model: "test/model", workingDirectory: root, permissionMode: mode, permissionRules: rules))
  }

  func testPlanModeDeniesAnInTreeWriteWithoutAsking() async throws {
    let root = try tempRoot()
    let perms = ScriptedPermissions([.allow]) // should never be consulted
    let session = session(root: root, mode: .plan, permissions: perms)
    var denied = false
    for try await event in await session.send("write it") {
      if case .toolDenied = event { denied = true }
    }
    XCTAssertTrue(denied)
    XCTAssertEqual(perms.asks, [], "plan mode denies before the delegate is asked")
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("in-tree.txt").path))
  }

  /// The propose-before-execute posture in one turn: the read the plan needs runs, the write
  /// it would make is refused with the plan-mode reason (what tells the model to describe
  /// instead of narrate execution), and the delegate is never consulted for either.
  func testPlanModeReadsRunAndWritesAreDeniedWithThePlanReason() async throws {
    let root = try tempRoot()
    try "hello".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "r1", name: "read_file", arguments: #"{"path":"notes.txt"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "w1", name: "write_file", arguments: #"{"path":"notes.txt","content":"changed"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("Plan: rewrite notes.txt"), Fixtures.usageChunk(cost: 0)],
    ]
    let perms = ScriptedPermissions([.allow])
    let session = Session(
      service: mock, tools: [ReadFileTool(root: root), WriteFileTool(root: root)],
      permissions: perms, store: store(),
      configuration: .init(model: "test/model", workingDirectory: root, permissionMode: .plan))
    var readResult: String?
    var denial: (tool: String, reason: String?)?
    for try await event in await session.send("plan the rewrite") {
      switch event {
      case .toolResult(let name, let preview) where name == "read_file": readResult = preview
      case .toolDenied(let name, let reason): denial = (name, reason)
      default: break
      }
    }
    XCTAssertEqual(readResult?.contains("hello"), true, "a read-only tool runs under plan mode")
    XCTAssertEqual(denial?.tool, "write_file")
    XCTAssertEqual(denial?.reason?.contains("plan mode is on"), true, "the denial names plan mode: \(denial?.reason ?? "nil")")
    XCTAssertEqual(denial?.reason?.contains("Describe what you would do"), true)
    XCTAssertEqual(perms.asks, [], "neither call reaches the delegate")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("notes.txt"), encoding: .utf8), "hello")
    // The record is the run's proof of a dry run: nothing changed, the turn finished on its
    // own, and the decision row says which gate refused.
    let record = await session.lastRecord
    XCTAssertTrue(record?.stopReason == .completed || record?.stopReason == .planProposed, "\(String(describing: record?.stopReason))")
    XCTAssertEqual(record?.decisions?.map(\.source), [.mode])
  }

  func testAcceptEditsAutoApprovesInTreeWrite() async throws {
    let root = try tempRoot()
    let perms = ScriptedPermissions([.deny(reason: "should not be asked")])
    let session = session(root: root, mode: .acceptEdits, permissions: perms)
    for try await _ in await session.send("write it") {}
    XCTAssertEqual(perms.asks, [], "acceptEdits skips the prompt for an in-tree edit")
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("in-tree.txt").path))
  }

  func testAcceptEditsStillGatesAnOutOfTreeWrite() async throws {
    let root = try tempRoot()
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-mode-out-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: outside) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = writeScript(outside.path)
    let perms = ScriptedPermissions([.deny(reason: "no")])
    let session = Session(
      service: mock, tools: [WriteFileTool(root: root)], permissions: perms, store: store(),
      configuration: .init(model: "test/model", workingDirectory: root, permissionMode: .acceptEdits))
    for try await _ in await session.send("write outside") {}
    XCTAssertEqual(perms.asks, ["write_file"], "an out-of-tree write is .sensitive and still prompts under acceptEdits")
    XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path))
  }

  func testDenyRuleRefusesWithoutAsking() async throws {
    let root = try tempRoot()
    let perms = ScriptedPermissions([.allow])
    let session = session(root: root, rules: PermissionRules(deny: ["write_file"]), permissions: perms)
    var denied = false
    for try await event in await session.send("write it") {
      if case .toolDenied(_, let reason) = event { denied = reason?.contains("permission rule") == true }
    }
    XCTAssertTrue(denied)
    XCTAssertEqual(perms.asks, [])
  }

  func testAllowRuleSkipsThePromptInDefaultMode() async throws {
    let root = try tempRoot()
    let perms = ScriptedPermissions([.deny(reason: "should not be asked")])
    let session = session(root: root, rules: PermissionRules(allow: ["Edit(**)"]), permissions: perms)
    for try await _ in await session.send("write it") {}
    XCTAssertEqual(perms.asks, [], "an allow rule covering write_file skips the prompt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("in-tree.txt").path))
  }

  func testSetPermissionModeMidSession() async throws {
    let root = try tempRoot()
    let session = session(root: root, mode: .default, permissions: ScriptedPermissions([.allow]))
    let initial = await session.permissionMode
    XCTAssertEqual(initial, .default)
    await session.setPermissionMode(.plan)
    let updated = await session.permissionMode
    XCTAssertEqual(updated, .plan)
  }
}
