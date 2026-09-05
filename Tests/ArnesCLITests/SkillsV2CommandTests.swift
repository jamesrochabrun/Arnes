import ArnesKit
import XCTest
@testable import arnes

/// A7: how a skill reads in `arnes skills` — the parsed-not-applied frontmatter facts, the
/// warnings, and the `~`-abbreviated source so a `~/.claude/skills` drop-in is visibly one.
final class SkillsV2CommandTests: XCTestCase {
  private func strip(_ rows: [String]) -> [String] {
    rows.map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
  }

  func testRowsShowFactsWarningsAndAbbreviatedSource() {
    let home = "/Users/someone"
    let skill = Skill(
      name: "git-flow",
      description: "git helper",
      body: "Use git carefully.",
      directory: URL(fileURLWithPath: "\(home)/.claude/skills/git-flow"),
      allowedTools: ["read_file", "bash(git add:*)"],
      model: "haiku",
      warnings: ["allowed-tools entry 'Broken(' is malformed; dropped"])

    XCTAssertEqual(strip(SkillsFormat.rows(for: skill, home: home)), [
      "git-flow",
      "  git helper",
      "  allowed-tools: read_file, bash(git add:*) (parsed, not applied)",
      "  model: haiku (applied to /git-flow turns in the REPL)",
      "  ⚠ allowed-tools entry 'Broken(' is malformed; dropped",
      "  ~/.claude/skills/git-flow",
    ])
  }

  func testRowsForABareSkillAreNameDescriptionSourceOnly() {
    let rows = strip(SkillsFormat.rows(for: BuiltinSkills.initInstructions, home: "/Users/someone"))
    XCTAssertEqual(rows.count, 3, rows.joined(separator: "\n"))
    XCTAssertEqual(rows[0], "init")
    XCTAssertEqual(rows[2], "  built-in")

    let terse = Skill(name: "terse", description: "", body: "b", directory: URL(fileURLWithPath: "/srv/skills/terse"))
    XCTAssertEqual(strip(SkillsFormat.rows(for: terse, home: "/Users/someone")), ["terse", "  /srv/skills/terse"])
  }

  /// `arnes agents` checks a `skills:` list against the trust-gated library a run would get;
  /// a name that lives only among the directory's not-yet-trusted skills is reported as that.
  func testPreloadWarningsNameUntrustedProjectSkillsInsteadOfCallingThemUnknown() {
    let library = [Skill(name: "release", description: "", body: "b", directory: nil)]
    let agent = AgentDefinition(
      name: "shipper", description: "", body: "role", skills: ["release", "proj", "nope", "proj"])

    XCTAssertEqual(
      AgentsFormat.preloadWarnings(for: agent, library: library, untrustedProjectSkills: ["proj"]),
      [
        "skills: no skill named 'nope' — not preloaded",
        "skills: 'proj' is this directory's own skill — preloaded only once the directory is trusted",
      ])
    // Trusted (or no project skill of that name): the Kit's own warnings, untouched.
    XCTAssertEqual(
      AgentsFormat.preloadWarnings(for: agent, library: library, untrustedProjectSkills: []),
      [
        "skills: no skill named 'proj' — not preloaded",
        "skills: no skill named 'nope' — not preloaded",
      ])
    // A project skill shadowed by a user-global one of the same name is known — no trust line.
    let shadowed = library + [Skill(name: "proj", description: "", body: "b", directory: nil)]
    XCTAssertEqual(
      AgentsFormat.preloadWarnings(for: agent, library: shadowed, untrustedProjectSkills: ["proj"]),
      ["skills: no skill named 'nope' — not preloaded"])
    XCTAssertEqual(
      AgentsFormat.preloadWarnings(
        for: AgentDefinition(name: "plain", description: "", body: "r"), library: library, untrustedProjectSkills: ["proj"]),
      [])
  }
}
