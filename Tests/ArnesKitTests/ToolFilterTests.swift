import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// `ToolFilter` — the `--allowed-tools` / `--disallowed-tools` ceiling on a headless run: a
/// pure list operation over tool names, never a permission decision.
final class ToolFilterTests: XCTestCase {
  private func tools(_ names: [String]) -> [any AgentTool] {
    names.map { SpyTool(name: $0) }
  }

  private func tools(_ names: String...) -> [any AgentTool] {
    tools(names)
  }

  private func names(_ tools: [any AgentTool]) -> [String] {
    tools.map(\.name)
  }

  private let run = ["read_file", "write_file", "edit_file", "bash", "grep", "glob", "mcp__github__issues", "mcp__github__pulls", "mcp__docs__search"]

  func testAllowedKeepsOnlyTheNamedTools() throws {
    let filtered = try ToolFilter.apply(tools(run), allowed: ["read_file", "grep"], disallowed: [])
    XCTAssertEqual(names(filtered), ["read_file", "grep"], "order follows the toolset, not the flag")
  }

  func testDisallowedRemovesAndNilAllowedKeepsTheRest() throws {
    let filtered = try ToolFilter.apply(tools(run), allowed: nil, disallowed: ["bash", "write_file"])
    XCTAssertEqual(names(filtered), ["read_file", "edit_file", "grep", "glob", "mcp__github__issues", "mcp__github__pulls", "mcp__docs__search"])
  }

  func testGlobMatchesAnMCPPrefix() throws {
    let allowed = try ToolFilter.apply(tools(run), allowed: ["mcp__github__*"], disallowed: [])
    XCTAssertEqual(names(allowed), ["mcp__github__issues", "mcp__github__pulls"])
    let disallowed = try ToolFilter.apply(tools(run), allowed: nil, disallowed: ["mcp__*"])
    XCTAssertEqual(names(disallowed), ["read_file", "write_file", "edit_file", "bash", "grep", "glob"])
    // The only glob form is a trailing `*`; a `*` anywhere else is a literal that matches nothing.
    XCTAssertFalse(ToolFilter.matches("mcp__*__issues", "mcp__github__issues"))
    XCTAssertTrue(ToolFilter.matches("*", "anything"))
  }

  func testClaudeCodeSpellingsCanonicalize() throws {
    let filtered = try ToolFilter.apply(tools(run), allowed: ["Read", "Edit", "Bash", "Glob"], disallowed: ["Write"])
    XCTAssertEqual(names(filtered), ["read_file", "edit_file", "bash", "glob"])
    XCTAssertEqual(ToolFilter.canonical(" Read "), "read_file")
    // `Task`/`Agent` name the task tool for the lead (a subagent's allowlist maps them to nothing).
    XCTAssertEqual(ToolFilter.canonical("Task"), "task")
    XCTAssertEqual(ToolFilter.canonical("Agent"), "task")
    XCTAssertEqual(ToolFilter.canonical("mcp__github__*"), "mcp__github__*", "a glob is never remapped")
    // An empty name is not a spelling of `task`: it stays empty and matches nothing (the CLI
    // drops empties before it gets here; an embedder calling `apply` directly gets a refusal).
    XCTAssertEqual(ToolFilter.canonical(""), "")
    XCTAssertEqual(ToolFilter.canonical("  "), "")
    XCTAssertThrowsError(try ToolFilter.apply(tools("task"), allowed: [""], disallowed: []))
    XCTAssertFalse(ToolFilter.permits("task", allowed: [""], disallowed: []))
  }

  func testUnknownNameThrowsWithTheAvailableList() {
    XCTAssertThrowsError(try ToolFilter.apply(tools("read_file", "bash"), allowed: ["read_fil"], disallowed: [])) { error in
      guard case ToolFilterError.unknownTool(let name, let available) = error else {
        return XCTFail("expected unknownTool, got \(error)")
      }
      XCTAssertEqual(name, "read_fil", "the raw spelling, so the user recognizes their typo")
      XCTAssertEqual(available, ["read_file", "bash"])
      XCTAssertTrue(String(describing: error).contains("read_file, bash"))
    }
    // A glob that matches nothing is unknown too — an MCP server that didn't connect.
    XCTAssertThrowsError(try ToolFilter.apply(tools("read_file"), allowed: nil, disallowed: ["mcp__github__*"]))
  }

  func testHarnessToolNamesAreAcceptedEvenWhenAbsentFromTheRun() throws {
    // `--disallowed-tools task,skill` on a run with no agents or skills is a no-op, not a typo.
    let filtered = try ToolFilter.apply(tools("read_file", "bash"), allowed: nil, disallowed: ["task", "skill", "Write"])
    XCTAssertEqual(names(filtered), ["read_file", "bash"])
    XCTAssertNoThrow(try ToolFilter.apply(tools("read_file"), allowed: ["read_file", "bash"], disallowed: []))
  }

  func testExplicitEmptyAllowedMeansNoTools() throws {
    let filtered = try ToolFilter.apply(tools(run), allowed: [], disallowed: [])
    XCTAssertEqual(names(filtered), [], "a pure-chat run: nothing to validate, nothing kept")
    XCTAssertEqual(ToolFilter.names(from: [""]), [], "`--allowed-tools \"\"` is the empty list")
  }

  func testDisallowBeatsAllow() throws {
    let filtered = try ToolFilter.apply(tools(run), allowed: ["read_file", "bash", "mcp__github__*"], disallowed: ["bash", "mcp__github__pulls"])
    XCTAssertEqual(names(filtered), ["read_file", "mcp__github__issues"])
    XCTAssertFalse(ToolFilter.permits("task", allowed: ["task"], disallowed: ["Task"]))
    XCTAssertTrue(ToolFilter.permits("task", allowed: nil, disallowed: ["bash"]))
    XCTAssertFalse(ToolFilter.permits("task", allowed: ["read_file"], disallowed: []))
    XCTAssertFalse(ToolFilter.permits("task", allowed: [], disallowed: []))
  }

  func testNamesSplitCommaSeparatedAndRepeatedValues() {
    XCTAssertEqual(ToolFilter.names(from: ["Read, Bash", "grep", " ", "mcp__x__*,"]), ["Read", "Bash", "grep", "mcp__x__*"])
  }

  func testAgentToolsetRuleIsSharedWithTheLead() {
    // `AgentLibrary.toolset(for:from:)` is the task tool's rule, now reusable over any list:
    // `(tools ?? every tool) ∩ tools − disallowedTools`, subtraction last.
    let agent = AgentDefinition(
      name: "reviewer", description: "", body: "Review.",
      tools: ["read_file", "grep", "bash"], disallowedTools: ["bash"])
    XCTAssertEqual(names(AgentLibrary.toolset(for: agent, from: tools(run))), ["read_file", "grep"])
    let everything = AgentDefinition(name: "all", description: "", body: "x", disallowedTools: ["write_file"])
    XCTAssertEqual(names(AgentLibrary.toolset(for: everything, from: tools("read_file", "write_file"))), ["read_file"])
  }
}
