import ArgumentParser
import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// S6's CLI surface: `arnes mcp --approve`, `arnes trust --show`, the flagged-content line,
/// the `withheld_tools` JSON key, and the config key that switches framing.
final class McpTrustCLITests: XCTestCase {
  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-mcptrust-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  // MARK: Flags

  func testMcpParsesApprove() throws {
    // The status view is the `status` default subcommand since X9 (the parent declares no flags, so
    // the verbs own their `--json`); `arnes mcp --approve <server> [--json]` parses to it as before.
    let command = try XCTUnwrap(try Mcp.parseAsRoot(["--approve", "docs"]) as? McpStatus)
    XCTAssertEqual(command.approve, "docs")
    XCTAssertFalse(command.json)
    let plain = try XCTUnwrap(try Mcp.parseAsRoot([]) as? McpStatus)
    XCTAssertNil(plain.approve)
    let both = try XCTUnwrap(try Mcp.parseAsRoot(["--approve", "docs", "--json"]) as? McpStatus)
    XCTAssertEqual(both.approve, "docs")
    XCTAssertTrue(both.json)
  }

  func testTrustParsesShowAndRefusesItWithListOrForget() throws {
    let show = try Trust.parse(["--show"])
    XCTAssertTrue(show.show)
    XCTAssertFalse(show.list)
    XCTAssertFalse(show.forget)
    let elsewhere = try Trust.parse(["--show", "/tmp/somewhere"])
    XCTAssertEqual(elsewhere.directory, "/tmp/somewhere")
    XCTAssertThrowsError(try Trust.parse(["--show", "--list"]))
    XCTAssertThrowsError(try Trust.parse(["--show", "--forget"]))
    XCTAssertThrowsError(try Trust.parse(["--list", "--forget"]))
    // Today's spellings are untouched.
    XCTAssertTrue(try Trust.parse(["--list"]).list)
    XCTAssertTrue(try Trust.parse(["--forget"]).forget)
  }

  // MARK: trust --show

  func testTrustShowNamesTheTrustingDirectoryAndTheContent() throws {
    let home = try tempDir("home")
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"), home: home)
    let repo = try tempDir("repo")
    let src = repo.appendingPathComponent("src")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try "# Repo\nuse tabs".write(to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

    let before = TrustShow.lines(for: repo, store: store)
    XCTAssertTrue(before[0].contains("not trusted"), before[0])
    XCTAssertTrue(before[0].contains("`arnes trust` here"), before[0])
    XCTAssertTrue(before.contains { $0.contains("defines 1 instruction file:") }, before.description)
    XCTAssertTrue(before.contains { $0.contains("instructions:") && $0.contains("AGENTS.md") }, before.description)

    try store.trust(repo)
    let after = TrustShow.lines(for: repo, store: store)
    XCTAssertTrue(after[0].hasSuffix(": trusted"), after[0])
    let sub = TrustShow.lines(for: src, store: store)
    XCTAssertTrue(sub[0].contains(": trusted (via "), sub[0])
    XCTAssertTrue(sub[0].contains(repo.lastPathComponent), sub[0])
    XCTAssertTrue(sub.contains { $0.contains("AGENTS.md") }, "the repository's instruction file applies to its subdirectory too")
    let empty = TrustShow.lines(for: try tempDir("empty"), store: store)
    XCTAssertTrue(empty[0].contains("not trusted"), empty[0])
    XCTAssertTrue(empty.contains { $0.contains("defines no skills, agents, instruction files or hooks") }, empty.description)
  }

  func testTrustShowReportsUnapprovedHooks() throws {
    let home = try tempDir("home")
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"), home: home)
    let repo = try tempDir("hooked")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".arnes"), withIntermediateDirectories: true)
    try #"{"hooks": [{"event": "PreToolUse", "matcher": "bash", "command": "echo hi"}]}"#
      .write(to: repo.appendingPathComponent(".arnes/hooks.json"), atomically: true, encoding: .utf8)
    try store.trust(repo)
    let lines = TrustShow.lines(for: repo, store: store)
    XCTAssertTrue(lines.contains { $0.contains("hooks: 1 of 1 not approved by hash") }, lines.description)
    let hooks = HookConfig.projectHooks(in: repo)
    try store.trustHooks(hooks.map(\.fingerprint), in: repo)
    let approved = TrustShow.lines(for: repo, store: store)
    XCTAssertTrue(approved.contains { $0.contains("every hook approved by hash") }, approved.description)
  }

  // MARK: Output

  func testFlaggedContentLinesInTextMode() {
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .contentFlagged(tool: "read_file", patterns: ["role_imitation", "frame_forgery"])),
      "⚠ flagged: read_file result matched role_imitation, frame_forgery — treated as data")
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .subagent(name: "explore", id: "a1b2c3d4", event: .contentFlagged(tool: "bash", patterns: ["special_token"]))),
      "  ⚠ [explore#a1b2c3d4] flagged: bash result matched special_token — treated as data")
  }

  func testMCPServerRowNamesWithheldToolsInSnakeCase() throws {
    // `ServerStatus.init` is internal to the Kit (no fixture row here, as X8 noted); the wire
    // key is the contract scripts read.
    XCTAssertEqual(MCPServerRow.CodingKeys.withheldTools.rawValue, "withheld_tools")
    XCTAssertEqual(try JSONOut.line([MCPServerRow]()), "[]")
  }

  // MARK: Config

  func testPoliciesToolResultFramingSwitchesTheCLIPolicy() throws {
    let decoded = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {"toolResultFraming": false}}"#.utf8))
    XCTAssertEqual(decoded.policies?.toolResultFraming, false)
    XCTAssertEqual(ToolResultGuardPolicy.cli(framing: decoded.policies?.toolResultFraming ?? true), ToolResultGuardPolicy(framing: false))
    let absent = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {}}"#.utf8))
    XCTAssertNil(absent.policies?.toolResultFraming)
    XCTAssertEqual(ToolResultGuardPolicy.cli(framing: absent.policies?.toolResultFraming ?? true), .cli)
    XCTAssertTrue(ToolResultGuardPolicy.cli.framing)
    XCTAssertTrue(ToolResultGuardPolicy.cli.scanner && ToolResultGuardPolicy.cli.redaction && ToolResultGuardPolicy.cli.taint)
  }
}
