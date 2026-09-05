import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class PermissionRulesParsingTests: XCTestCase {
  func testParsesBareToolAndMcpWildcard() {
    guard case .tool("bash")? = PermissionRule("bash")?.matcher else { return XCTFail() }
    guard case .tool("write_file")? = PermissionRule("write_file")?.matcher else { return XCTFail() }
    guard case .mcpServer("github")? = PermissionRule("mcp__github__*")?.matcher else { return XCTFail() }
    guard case .tool("mcp__github__search")? = PermissionRule("mcp__github__search")?.matcher else { return XCTFail() }
    XCTAssertNil(PermissionRule("  "))
  }

  func testParsesBashPrefixForms() {
    guard case .bashPrefix("git commit")? = PermissionRule("Bash(git commit:*)")?.matcher else { return XCTFail("colon-star") }
    guard case .bashPrefix("npm run")? = PermissionRule("Bash(npm run *)")?.matcher else { return XCTFail("space-star") }
    guard case .bashPrefix("ls")? = PermissionRule("Bash(ls)")?.matcher else { return XCTFail("exact") }
  }

  func testParsesPathForms() {
    guard case .path(let tools, "~/.ssh/**")? = PermissionRule("Read(~/.ssh/**)")?.matcher else { return XCTFail() }
    XCTAssertTrue(tools.contains("read_file"))
    guard case .path(let editTools, "src/**")? = PermissionRule("Edit(src/**)")?.matcher else { return XCTFail() }
    XCTAssertTrue(editTools.contains("edit_file"))
    XCTAssertTrue(editTools.contains("write_file"), "Edit covers write_file too")
  }
}

final class GlobMatchTests: XCTestCase {
  func testDoubleStarCrossesDirectories() {
    let root = URL(fileURLWithPath: "/work")
    XCTAssertTrue(GlobMatch.matches(glob: "src/**", path: "/work/src/a/b.swift", root: root))
    XCTAssertTrue(GlobMatch.matches(glob: "src/**", path: "src/main.swift", root: root))
    XCTAssertFalse(GlobMatch.matches(glob: "src/**", path: "/work/tests/x.swift", root: root))
  }

  func testSingleStarStaysInOneSegment() {
    let root = URL(fileURLWithPath: "/work")
    XCTAssertTrue(GlobMatch.matches(glob: "*.swift", path: "main.swift", root: root))
    // A slashless pattern matches the basename at any depth (gitignore semantics) — so
    // `Read(*.pem)` covers a nested cert, which is what a deny rule wants.
    XCTAssertTrue(GlobMatch.matches(glob: "*.swift", path: "a/main.swift", root: root))
    // A pattern WITH a slash is anchored: `a/*.swift` does not cross into `a/b/`.
    XCTAssertTrue(GlobMatch.matches(glob: "a/*.swift", path: "a/main.swift", root: root))
    XCTAssertFalse(GlobMatch.matches(glob: "a/*.swift", path: "a/b/main.swift", root: root), "* does not cross /")
    XCTAssertTrue(GlobMatch.matches(glob: "**/*.swift", path: "a/b/main.swift", root: root))
  }

  func testAbsoluteAndHomeAnchors() {
    let home = NSHomeDirectory()
    XCTAssertTrue(GlobMatch.matches(glob: "~/.ssh/**", path: "\(home)/.ssh/id_rsa", root: nil))
    XCTAssertTrue(GlobMatch.matches(glob: "//etc/**", path: "/etc/hosts", root: nil))
    XCTAssertFalse(GlobMatch.matches(glob: "//etc/**", path: "/usr/bin/ls", root: nil))
  }
}

final class PermissionRuleSetTests: XCTestCase {
  private func args(_ command: String) -> [String: JSONValue] { ["command": .string(command)] }

  func testBashPrefixAllowRequiresEverySegmentToMatch() {
    let set = PermissionRuleSet(PermissionRules(allow: ["Bash(git status:*)"]))
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("git status"), root: nil), .allow)
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("git status -s"), root: nil), .allow)
    // A chained command isn't allowed just because its first segment matches.
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("git status; rm -rf /"), root: nil), .unset)
  }

  func testBashDenyFiresOnAnySegment() {
    let set = PermissionRuleSet(PermissionRules(deny: ["Bash(rm:*)"]))
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("ls && rm x"), root: nil), .deny)
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("ls"), root: nil), .unset)
  }

  func testWrappersAreStrippedBeforeMatching() {
    let set = PermissionRuleSet(PermissionRules(allow: ["Bash(npm test:*)"]))
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("sudo npm test"), root: nil), .allow)
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("env CI=1 npm test"), root: nil), .allow)
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("timeout 30 npm test"), root: nil), .allow)
  }

  func testDenyWinsOverAllow() {
    let set = PermissionRuleSet(PermissionRules(deny: ["Bash(git push:*)"], allow: ["Bash(git:*)"]))
    XCTAssertEqual(set.outcome(tool: "bash", arguments: args("git push origin main"), root: nil), .deny)
  }

  func testPathRuleMatchesReadOutsideTree() {
    let set = PermissionRuleSet(PermissionRules(deny: ["Read(~/.ssh/**)"]))
    let home = NSHomeDirectory()
    XCTAssertEqual(set.outcome(tool: "read_file", arguments: ["path": .string("\(home)/.ssh/id_rsa")], root: nil), .deny)
    XCTAssertEqual(set.outcome(tool: "read_file", arguments: ["path": .string("\(home)/notes.md")], root: nil), .unset)
  }

  func testMcpServerWildcard() {
    let set = PermissionRuleSet(PermissionRules(ask: ["mcp__deploy__*"]))
    XCTAssertEqual(set.outcome(tool: "mcp__deploy__ship", arguments: [:], root: nil), .ask)
    XCTAssertEqual(set.outcome(tool: "mcp__search__query", arguments: [:], root: nil), .unset)
  }

  func testProjectAllowsAreDropped() {
    let (merged, dropped) = PermissionRules.merged(
      user: PermissionRules(allow: ["Bash(ls:*)"]),
      project: PermissionRules(deny: ["Bash(rm:*)"], ask: ["Bash(git push:*)"], allow: ["Bash(anything:*)"]))
    XCTAssertEqual(dropped, 1, "a project may tighten with deny/ask but its allow entries are ignored")
    XCTAssertTrue(merged.deny.contains("Bash(rm:*)"))
    XCTAssertTrue(merged.ask.contains("Bash(git push:*)"))
    XCTAssertEqual(merged.allow, ["Bash(ls:*)"], "only the user's allow list survives")
  }
}
