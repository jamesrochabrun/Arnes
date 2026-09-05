import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// REPL parity: the lead-shape flags `arnes do` had (`--agent`, `--agents`, `--allowed-tools`,
/// `--disallowed-tools`, `--append-system-prompt(-file)`) on `arnes interactive`, the banner and
/// `/status` naming the agent, and the rule a skill's `model:` frontmatter follows on a `/name` turn.
final class InteractiveFlagsTests: XCTestCase {
  private func tempFile(_ contents: String) throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-replflags-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("appendix.md")
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  func testInteractiveParsesTheLeadShapeFlags() throws {
    let appendix = try tempFile("From the file.")
    let command = try Interactive.parse([
      "--agent", "reviewer", "--agents", "{}",
      "--allowed-tools", "Read,Bash", "--allowed-tools", "grep", "--disallowed-tools", "task",
      "--append-system-prompt", "Be terse.", "--append-system-prompt-file", appendix.path,
    ])
    XCTAssertEqual(command.agentName, "reviewer")
    XCTAssertEqual(command.inlineAgents, "{}")
    XCTAssertEqual(ToolFilter.names(from: command.allowedTools), ["Read", "Bash", "grep"])
    XCTAssertEqual(command.disallowedTools, ["task"])
    XCTAssertEqual(command.appendSystemPrompt, "Be terse.")
    XCTAssertEqual(command.appendSystemPromptFile, appendix.path)
    // `--agent-model` (the subagent pin) and `--agent` (the lead) are distinct flags.
    let both = try Interactive.parse(["--agent", "general", "--agent-model", "explore=haiku"])
    XCTAssertEqual(both.agentName, "general")
    XCTAssertEqual(both.agentModel, ["explore=haiku"])
  }

  func testMalformedInlineAgentsAndAMissingAppendixFileAreUsageErrors() {
    XCTAssertThrowsError(try Interactive.parse(["--agents", "{not json"]))
    XCTAssertThrowsError(try Interactive.parse(["--append-system-prompt-file", "/nonexistent/arnes-appendix.md"]))
    XCTAssertNoThrow(try Interactive.parse(["--agents", #"{"helper": {"description": "d", "prompt": "p"}}"#]))
  }

  func testTheBannerAndStatusNameTheLeadAgent() {
    // Tests run piped, so the banner is its plain one-line form.
    let plain = Header.banner(version: "0", model: "m/x", dialect: "auto", mode: "plan", agent: "explore")
    XCTAssertTrue(plain.contains(" · agent explore · mode plan"), plain)
    XCTAssertFalse(Header.banner(version: "0", model: "m/x", dialect: "auto").contains("agent"))
    let facts = StatusFormat.Facts(
      sessionId: "s", model: "m/x", agent: "explore", dialectFlag: "auto", provider: "p",
      mode: .default, readOnly: true, messages: 0, turns: 0, costUSD: 0, tainted: false)
    let lines = StatusFormat.lines(facts)
    let agentRow = try? XCTUnwrap(lines.first { $0.contains("agent") })
    XCTAssertTrue(agentRow?.hasSuffix("explore") == true, lines.joined(separator: "\n"))
    XCTAssertTrue(lines.firstIndex { $0.contains("agent") }! > lines.firstIndex { $0.contains("m/x") }!, "after the model row")
  }

  func testASkillTurnSwitchesOnlyToAResolvedDifferentModel() {
    XCTAssertNil(Interactive.skillModelSwitch(resolved: nil, current: "a/x"), "no manifest match: the turn stays put")
    XCTAssertNil(Interactive.skillModelSwitch(resolved: "a/x", current: "a/x"), "already on it")
    XCTAssertEqual(Interactive.skillModelSwitch(resolved: "b/y", current: "a/x"), "b/y")
    XCTAssertEqual(
      Interactive.skillModelLine(skill: "review", model: "b/y", previous: "a/x"),
      "↳ /review runs on b/y (skill frontmatter) — back to a/x after this turn")
  }
}
