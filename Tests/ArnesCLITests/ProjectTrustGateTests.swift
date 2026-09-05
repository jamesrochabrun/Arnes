import ArnesKit
import XCTest
@testable import arnes

/// The gate that decides whether a run loads the working directory's own skills, agents
/// and instruction files. Headless behavior is what's testable here (an interactive prompt
/// needs a TTY), and it's the behavior that matters for `arnes do`.
final class ProjectTrustGateTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-gate-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func repoWithClaudeMd() throws -> URL {
    let repo = try tempDir()
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "REPO RULES".write(
      to: repo.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    return repo
  }

  private func store() throws -> ProjectTrustStore {
    ProjectTrustStore(url: try tempDir().appendingPathComponent("trusted.json"))
  }

  func testInstructionOnlyRepoIsGatedHeadlessAndTheNoticeSaysWhy() throws {
    let repo = try repoWithClaudeMd()
    let outcome = ProjectTrustGate.evaluate(
      trustFlag: false, interactive: false, store: try store(), cwd: repo)
    XCTAssertFalse(outcome.includeProject, "a repo shipping only CLAUDE.md still needs trust")
    let notice = try XCTUnwrap(outcome.notice)
    XCTAssertTrue(notice.contains("1 instruction file"))
    XCTAssertTrue(notice.contains("--trust-project"))
  }

  func testMCPOnlyRepoIsGatedHeadlessAndTheNoticeNamesTheServers() throws {
    let repo = try tempDir()
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try #"{"mcpServers": {"docs": {"url": "https://mcp.example.com/private/path", "headers": {"Authorization": "Bearer SECRET"}}}}"#
      .write(to: repo.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    let outcome = ProjectTrustGate.evaluate(trustFlag: false, interactive: false, store: try store(), cwd: repo)
    XCTAssertFalse(outcome.includeProject, "a repo shipping only a .mcp.json still needs trust")
    let notice = try XCTUnwrap(outcome.notice)
    XCTAssertTrue(notice.contains("skipping 1 MCP server from"), notice)
    XCTAssertTrue(notice.contains("\n  mcp: docs (http mcp.example.com)"), notice)
    XCTAssertFalse(notice.contains("SECRET") || notice.contains("/private/path"), notice)
  }

  func testTrustFlagAndRememberedTrustBothLoadIt() throws {
    let repo = try repoWithClaudeMd()
    let trustStore = try store()
    let flagged = ProjectTrustGate.evaluate(
      trustFlag: true, interactive: false, store: trustStore, cwd: repo)
    XCTAssertTrue(flagged.includeProject)
    XCTAssertTrue(trustStore.isTrusted(repo), "--trust-project remembers the directory")

    let remembered = ProjectTrustGate.evaluate(
      trustFlag: false, interactive: false, store: trustStore, cwd: repo)
    XCTAssertTrue(remembered.includeProject)
    XCTAssertNil(remembered.notice, "a trusted directory says nothing")
  }

  /// `--trust-project` in the home directory (a `~/CLAUDE.md` makes it a project): the store
  /// refuses the root, so the content loads for this session only and the notice says exactly
  /// that — never a "trusted" line for a trust that was not recorded.
  func testTrustFlagOnARefusedRootLoadsForTheSessionAndSaysSo() throws {
    let home = try tempDir()
    try "HOME RULES".write(to: home.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
    let trustStore = ProjectTrustStore(url: try tempDir().appendingPathComponent("trusted.json"), home: home)
    let outcome = ProjectTrustGate.evaluate(trustFlag: true, interactive: false, store: trustStore, cwd: home)
    XCTAssertTrue(outcome.includeProject, "the flag still loads it — for this run")
    let notice = try XCTUnwrap(outcome.notice)
    XCTAssertTrue(notice.hasPrefix("loading this directory's 1 instruction file for this session only — refusing to trust"), notice)
    XCTAssertFalse(notice.hasPrefix("trusted"), notice)
    XCTAssertFalse(trustStore.isTrusted(home))
    XCTAssertTrue(trustStore.all().isEmpty, "nothing was written")
  }

  func testEmptyDirectoryIsNeverGated() throws {
    let outcome = ProjectTrustGate.evaluate(
      trustFlag: false, interactive: false, store: try store(), cwd: try tempDir())
    XCTAssertTrue(outcome.includeProject)
    XCTAssertNil(outcome.notice)
  }

  func testListingNamesTheInstructionFileAndItsImports() throws {
    let repo = try repoWithClaudeMd()
    try "STYLE".write(
      to: repo.appendingPathComponent("style.md"), atomically: true, encoding: .utf8)
    try "# Rules\n@style.md".write(
      to: repo.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)

    let content = ProjectContent.discover(workdir: repo)
    let rows = ProjectTrustGate.listing(content)
    let instructionRow = try XCTUnwrap(rows.first { $0.contains("instructions:") })
    XCTAssertTrue(instructionRow.contains("AGENTS.md"))
    XCTAssertTrue(instructionRow.contains("bytes"))
    XCTAssertTrue(instructionRow.contains("imports style.md"), "imports reach the prompt too")
  }
}
