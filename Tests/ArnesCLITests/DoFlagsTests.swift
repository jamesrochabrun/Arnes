import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// A named tool and nothing else — what `Do.scopedTools` looks at.
private struct NamedTool: AgentTool {
  let name: String
  let description = "test tool"
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  let permission: ToolPermission = .readOnly
  func execute(arguments: [String: JSONValue]) async throws -> String { "ok" }
}

/// X3 — the headless parity flags on `arnes do`: `--resume/--continue/--fork`,
/// `--append-system-prompt(-file)`, `--agent`, `--agents`, `--allowed-tools/--disallowed-tools`.
/// Parse-time refusals go through `Do.parse` (ArgumentParser runs `validate()`); the pure
/// helpers are called directly.
final class DoFlagsTests: XCTestCase {
  private func tempFile(_ contents: String, name: String = "x.txt") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-doflags-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func assertValidationError(_ arguments: [String], contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try Do.parse(arguments), arguments.joined(separator: " "), file: file, line: line) { error in
      let message = Do.message(for: error)
      XCTAssertTrue(message.contains(needle), "\(arguments.joined(separator: " ")): \(message)", file: file, line: line)
    }
  }

  // MARK: Parsing

  func testDoParsesTheParityFlags() throws {
    let appendix = try tempFile("From the file.")
    let command = try Do.parse([
      "do it", "--resume", "abc123", "--fork", "--name", "branch",
      "--append-system-prompt", "Be terse.", "--append-system-prompt-file", appendix.path,
      "--agent", "reviewer", "--agents", "{}",
      "--allowed-tools", "Read,Bash", "--allowed-tools", "grep", "--disallowed-tools", "task",
    ])
    XCTAssertEqual(command.resume, "abc123")
    XCTAssertTrue(command.fork)
    XCTAssertEqual(command.name, "branch")
    XCTAssertEqual(command.appendSystemPrompt, "Be terse.")
    XCTAssertEqual(command.appendSystemPromptFile, appendix.path)
    XCTAssertEqual(command.agentName, "reviewer")
    XCTAssertEqual(command.agents, "{}")
    XCTAssertEqual(command.allowedTools, ["Read,Bash", "grep"])
    XCTAssertEqual(ToolFilter.names(from: command.allowedTools), ["Read", "Bash", "grep"])
    XCTAssertEqual(command.disallowedTools, ["task"])
    let continued = try Do.parse(["do it", "--continue"])
    XCTAssertTrue(continued.continueMostRecent)
    XCTAssertNil(continued.resume)
  }

  func testAnExplicitlyEmptyAllowedToolsMeansNoTools() throws {
    let command = try Do.parse(["chat only", "--allowed-tools", ""])
    XCTAssertEqual(command.allowedTools, [""])
    XCTAssertEqual(ToolFilter.names(from: command.allowedTools), [])
    let scoped = try Do.scopedTools([NamedTool(name: "bash"), NamedTool(name: "read_file")], allowed: command.allowedTools, disallowed: [], agent: nil)
    XCTAssertEqual(scoped.map(\.name), [])
    // No flag at all: everything stays.
    let plain = try Do.scopedTools([NamedTool(name: "bash")], allowed: [], disallowed: [], agent: nil)
    XCTAssertEqual(plain.map(\.name), ["bash"])
  }

  // MARK: Session continuation refusals

  func testResumeAndContinueDontCombine() {
    assertValidationError(["x", "--resume", "abc", "--continue"], contains: "--resume and --continue")
  }

  func testForkNeedsASessionToFork() {
    assertValidationError(["x", "--fork"], contains: "--fork needs a session")
    assertValidationError(["x", "--fork", "--name", "b"], contains: "--fork needs a session")
    XCTAssertNoThrow(try Do.parse(["x", "--continue", "--fork"]))
    XCTAssertNoThrow(try Do.parse(["x", "--resume", "abc", "--fork", "--name", "b"]))
  }

  func testNameNeedsFork() {
    assertValidationError(["x", "--resume", "abc", "--name", "b"], contains: "--name names a fork")
  }

  func testPanelRefusesContinuationAndLeadShapeFlags() {
    for extra in [["--resume", "abc"], ["--continue"], ["--continue", "--fork"]] {
      assertValidationError(["x", "--panel", "2", "--yes"] + extra, contains: "--panel and --resume/--continue/--fork")
    }
    for extra in [
      ["--agent", "explore"], ["--agents", "{}"], ["--append-system-prompt", "t"],
      ["--append-system-prompt-file", "/nonexistent/never-read.md"], ["--allowed-tools", "bash"], ["--disallowed-tools", "bash"],
    ] {
      assertValidationError(["x", "--panel", "2", "--yes"] + extra, contains: "--panel and --agent")
    }
  }

  // MARK: --append-system-prompt / --append-system-prompt-file

  func testAppendixConcatenatesTextThenFileWithABlankLine() throws {
    let file = try tempFile("From the file.\n")
    XCTAssertEqual(
      try Do.systemPromptAppendix(text: "From the flag.", file: file.path),
      "From the flag.\n\nFrom the file.")
    XCTAssertEqual(try Do.systemPromptAppendix(text: nil, file: file.path), "From the file.")
    XCTAssertEqual(try Do.systemPromptAppendix(text: "  only text ", file: nil), "only text")
    XCTAssertNil(try Do.systemPromptAppendix(text: nil, file: nil))
    XCTAssertNil(try Do.systemPromptAppendix(text: "   ", file: nil), "blank text appends nothing")
  }

  func testMissingAppendFileIsAValidationError() {
    XCTAssertThrowsError(try Do.systemPromptAppendix(text: nil, file: "/nonexistent/arnes-\(UUID().uuidString).md")) { error in
      XCTAssertTrue(error is ValidationError)
      XCTAssertTrue(String(describing: error).contains("--append-system-prompt-file"))
    }
    // And at parse time, before anything connects.
    assertValidationError(["x", "--append-system-prompt-file", "/nonexistent/arnes-\(UUID().uuidString).md"], contains: "cannot read")
  }

  func testOversizedAppendFileIsAValidationErrorNotATruncation() throws {
    let big = try tempFile(String(repeating: "x", count: Do.maxPromptFileBytes + 1))
    XCTAssertThrowsError(try Do.systemPromptAppendix(text: nil, file: big.path)) { error in
      XCTAssertTrue(String(describing: error).contains("64 KB"), String(describing: error))
    }
    let exact = try tempFile(String(repeating: "y", count: Do.maxPromptFileBytes))
    XCTAssertEqual(try Do.systemPromptAppendix(text: nil, file: exact.path)?.count, Do.maxPromptFileBytes)
  }

  func testRelativePromptFilesAreReadAgainstTheCwdFlagAtParseTime() throws {
    // `-C /other --append-system-prompt-file persona.md`: run() reads the file after changing
    // directory, so validate() must look in the same place — not where the command was typed
    // (a spurious "cannot read", or a different file of the same name).
    let dir = try tempFile("From the project.", name: "persona.md").deletingLastPathComponent()
    try #"{"local": {"prompt": "Local."}}"#.write(
      to: dir.appendingPathComponent("agents.json"), atomically: true, encoding: .utf8)
    XCTAssertEqual(
      try Do.systemPromptAppendix(text: nil, file: "persona.md", relativeTo: dir.path), "From the project.")
    XCTAssertEqual(try Do.parseInlineAgents("@agents.json", relativeTo: dir.path).map(\.name), ["local"])
    // Absolute (and `~`) paths are left alone.
    XCTAssertEqual(
      try Do.systemPromptAppendix(text: nil, file: dir.appendingPathComponent("persona.md").path, relativeTo: "/nonexistent"),
      "From the project.")
    // Through the parser: with -C the file resolves; without it the same relative name is
    // read against the process cwd, where it does not exist.
    XCTAssertNoThrow(try Do.parse(["x", "-C", dir.path, "--append-system-prompt-file", "persona.md", "--agents", "@agents.json"]))
    assertValidationError(
      ["x", "--append-system-prompt-file", "arnes-\(UUID().uuidString).md"], contains: "cannot read")
  }

  func testComposedSuffixPutsTheRoleBeforeTheAppendix() {
    let agent = AgentDefinition(name: "reviewer", description: "", body: "Review diffs.")
    XCTAssertEqual(Do.composeSystemSuffix(agent: agent, appendix: "Be terse."), "# Role\n\nReview diffs.\n\nBe terse.")
    XCTAssertEqual(Do.composeSystemSuffix(agent: agent, appendix: nil), "# Role\n\nReview diffs.")
    XCTAssertEqual(Do.composeSystemSuffix(agent: nil, appendix: "Be terse."), "Be terse.")
    XCTAssertNil(Do.composeSystemSuffix(agent: nil, appendix: nil))
  }

  // MARK: --agents (inline definitions)

  func testInlineAgentsObjectForm() throws {
    let agents = try Do.parseInlineAgents(#"""
      {"reviewer": {"description": "Reviews diffs", "prompt": "You review.", "tools": ["Read", "Grep", "Task"], "model": "sonnet",
                    "permissionMode": "plan", "maxTurns": 7, "budget": "$0.50", "effort": "low", "unknownKey": 1},
       "writer": {"prompt": "You write.", "disallowedTools": "Bash, Write"}}
      """#)
    XCTAssertEqual(agents.map(\.name), ["reviewer", "writer"])
    let reviewer = agents[0]
    XCTAssertEqual(reviewer.description, "Reviews diffs")
    XCTAssertEqual(reviewer.body, "You review.")
    XCTAssertEqual(reviewer.tools, ["read_file", "grep"], "Claude Code names canonicalized; Task drops out as in a file")
    XCTAssertEqual(reviewer.model, "sonnet")
    XCTAssertEqual(reviewer.permissionMode, .readOnly)
    XCTAssertEqual(reviewer.maxSteps, 7)
    XCTAssertEqual(reviewer.budgetUSD, 0.5)
    XCTAssertEqual(reviewer.effort, .low)
    XCTAssertTrue(reviewer.warnings.isEmpty)
    XCTAssertNil(reviewer.source, "inline, not a file")
    let writer = agents[1]
    XCTAssertEqual(writer.description, "")
    XCTAssertNil(writer.tools)
    XCTAssertEqual(writer.disallowedTools, ["bash", "write_file"], "a comma-separated string works like frontmatter")
    XCTAssertNil(writer.model)
  }

  func testInlineAgentsArrayForm() throws {
    let agents = try Do.parseInlineAgents(#"""
      [{"name": "a", "prompt": "A.", "model": "inherit"}, {"name": "b", "prompt": "B.", "tools": "Edit"}]
      """#)
    XCTAssertEqual(agents.map(\.name), ["a", "b"])
    XCTAssertNil(agents[0].model, "`inherit` is the parent's model, as in a file")
    XCTAssertEqual(agents[1].tools, ["edit_file"])
  }

  func testInlineAgentsBadValuesWarnInsteadOfDropping() throws {
    let agents = try Do.parseInlineAgents(#"{"x": {"prompt": "X.", "permissionMode": "bypassPermissions", "effort": "turbo", "maxTurns": 0}}"#)
    let agent = try XCTUnwrap(agents.first)
    XCTAssertEqual(agent.permissionMode, .inherit, "a widening mode never applies")
    XCTAssertNil(agent.effort)
    XCTAssertNil(agent.maxSteps)
    XCTAssertEqual(agent.warnings.count, 3, "\(agent.warnings)")
  }

  func testInlineAgentsExplicitEmptyToolsMeansNoToolsAndAnUnmappedListWarns() throws {
    // JSON can say `[]` where frontmatter can't: that is *no tools* (the lead is refused as
    // resolving to zero tools), not "every tool". A list that canonicalizes to nothing
    // (`["Task"]`) still means every tool, as from a file — but says so.
    let agents = try Do.parseInlineAgents(#"""
      {"none": {"prompt": "N.", "tools": []},
       "taskonly": {"prompt": "T.", "tools": ["Task"], "disallowedTools": ["Agent"]},
       "blank": {"prompt": "B.", "tools": ""}}
      """#)
    let none = try XCTUnwrap(agents.first { $0.name == "none" })
    XCTAssertEqual(none.tools, [])
    XCTAssertTrue(none.warnings.isEmpty)
    XCTAssertThrowsError(try Do.scopedTools([NamedTool(name: "bash")], allowed: [], disallowed: [], agent: none)) { error in
      XCTAssertTrue(String(describing: error).contains("resolves to zero tools"), String(describing: error))
    }
    let taskOnly = try XCTUnwrap(agents.first { $0.name == "taskonly" })
    XCTAssertNil(taskOnly.tools)
    XCTAssertNil(taskOnly.disallowedTools)
    XCTAssertEqual(taskOnly.warnings.count, 2, "\(taskOnly.warnings)")
    XCTAssertTrue(taskOnly.warnings.contains { $0.contains("tools") && $0.contains("Task") && $0.contains("every tool") }, "\(taskOnly.warnings)")
    XCTAssertTrue(taskOnly.warnings.contains { $0.contains("disallowedtools") && $0.contains("nothing removed") }, "\(taskOnly.warnings)")
    // A blank string is frontmatter's "nothing after the colon": unset, no warning.
    let blank = try XCTUnwrap(agents.first { $0.name == "blank" })
    XCTAssertNil(blank.tools)
    XCTAssertTrue(blank.warnings.isEmpty)
  }

  func testInlineAgentsRefusals() {
    for (json, needle) in [
      ("{not json", "not valid JSON"),
      ("42", "neither an object nor an array"),
      (#"{"a": "just a string"}"#, "is not an object"),
      (#"[{"prompt": "no name"}]"#, "has no \"name\""),
      (#"{"a": {"description": "no prompt"}}"#, "has no \"prompt\""),
    ] {
      XCTAssertThrowsError(try Do.parseInlineAgents(json), json) { error in
        XCTAssertTrue(error is ValidationError, json)
        XCTAssertTrue(String(describing: error).contains(needle), "\(json): \(error)")
      }
    }
    // The same refusal at parse time.
    assertValidationError(["x", "--agents", "{not json"], contains: "not valid JSON")
    XCTAssertEqual(try Do.parseInlineAgents(nil), [])
    XCTAssertEqual(try Do.parseInlineAgents("  "), [])
  }

  func testInlineAgentsReadFromAFileWithAtPath() throws {
    let file = try tempFile(#"{"fromfile": {"prompt": "Hi."}}"#, name: "agents.json")
    let agents = try Do.parseInlineAgents("@" + file.path)
    XCTAssertEqual(agents.map(\.name), ["fromfile"])
    XCTAssertThrowsError(try Do.parseInlineAgents("@/nonexistent/arnes-\(UUID().uuidString).json")) { error in
      XCTAssertTrue(String(describing: error).contains("--agents"))
    }
  }

  // MARK: --agent

  func testUnknownLeadAgentListsTheAvailableNames() {
    let pool = [AgentDefinition.general, AgentDefinition.explore]
    XCTAssertThrowsError(try Do.resolveLeadAgent(named: "revewer", in: pool)) { error in
      XCTAssertTrue(error is ValidationError)
      let message = String(describing: error)
      XCTAssertTrue(message.contains("revewer"), message)
      XCTAssertTrue(message.contains("general, explore"), message)
    }
    XCTAssertEqual(try Do.resolveLeadAgent(named: "explore", in: pool).name, "explore")
  }

  func testInlineAgentWinsOverADiscoveredOneForTheLead() throws {
    let inline = try Do.parseInlineAgents(#"{"explore": {"prompt": "Mine."}}"#)
    let pool = AgentLibrary.merge(inline: inline, discovered: AgentDefinition.builtins)
    XCTAssertEqual(try Do.resolveLeadAgent(named: "explore", in: pool).body, "Mine.")
  }

  // MARK: --allowed-tools / --disallowed-tools over the run's toolset

  func testScopedToolsAppliesTheFlagsThenTheAgent() throws {
    let run: [any AgentTool] = ["read_file", "write_file", "bash", "grep", "mcp__gh__issues", "skill"].map(NamedTool.init)
    let flagsOnly = try Do.scopedTools(run, allowed: ["Read,Bash,grep", "mcp__gh__*"], disallowed: ["bash"], agent: nil)
    XCTAssertEqual(flagsOnly.map(\.name), ["read_file", "grep", "mcp__gh__issues"])
    let agent = AgentDefinition(name: "reader", description: "", body: "Read.", tools: ["read_file", "bash"])
    let narrowed = try Do.scopedTools(run, allowed: ["Read,Bash,grep"], disallowed: ["bash"], agent: agent)
    XCTAssertEqual(narrowed.map(\.name), ["read_file"], "the agent narrows what the flags left; it can't restore bash")
  }

  func testScopedToolsRefusesATypoAndAnAgentThatLeavesNothing() {
    let run: [any AgentTool] = ["read_file", "bash"].map(NamedTool.init)
    XCTAssertThrowsError(try Do.scopedTools(run, allowed: ["read_fil"], disallowed: [], agent: nil)) { error in
      XCTAssertTrue(error is ValidationError)
      XCTAssertTrue(String(describing: error).contains("--allowed-tools/--disallowed-tools"), String(describing: error))
      XCTAssertTrue(String(describing: error).contains("read_file, bash"))
    }
    let mcpOnly = AgentDefinition(name: "gh", description: "", body: "x", tools: ["mcp__gh__issues"])
    XCTAssertThrowsError(try Do.scopedTools(run, allowed: [], disallowed: [], agent: mcpOnly)) { error in
      XCTAssertTrue(String(describing: error).contains("resolves to zero tools"), String(describing: error))
    }
    // An empty run (a pure-chat `--allowed-tools ""`) with an agent is fine: nothing to lose.
    XCTAssertEqual(try Do.scopedTools([], allowed: [], disallowed: [], agent: mcpOnly).count, 0)
  }

  func testTaskToolFollowsTheFlagsAndAnAgentsExplicitToolsList() {
    // The flags alone: present unless removed or left out of an allowlist (Claude Code spellings too).
    XCTAssertTrue(Do.taskToolPermitted(allowed: [], disallowed: [], agent: nil))
    XCTAssertFalse(Do.taskToolPermitted(allowed: [], disallowed: ["task"], agent: nil))
    XCTAssertFalse(Do.taskToolPermitted(allowed: [], disallowed: ["bash,Task"], agent: nil))
    XCTAssertFalse(Do.taskToolPermitted(allowed: ["Read,Grep"], disallowed: [], agent: nil))
    XCTAssertTrue(Do.taskToolPermitted(allowed: ["Read", "Agent"], disallowed: [], agent: nil))
    XCTAssertFalse(Do.taskToolPermitted(allowed: ["task"], disallowed: ["task"], agent: nil), "disallow wins")
    // An agent without a tools list leaves the flags' verdict; one with a list didn't ask
    // for delegation, so `--agent explore` runs with its three read tools and no `task`…
    XCTAssertTrue(Do.taskToolPermitted(allowed: [], disallowed: [], agent: .general))
    XCTAssertFalse(Do.taskToolPermitted(allowed: [], disallowed: [], agent: .explore))
    XCTAssertFalse(Do.taskToolPermitted(allowed: ["*"], disallowed: [], agent: .explore), "a glob is not an explicit request")
    // …unless --allowed-tools names it explicitly (and disallow still wins).
    XCTAssertTrue(Do.taskToolPermitted(allowed: ["Read,Task"], disallowed: [], agent: .explore))
    XCTAssertFalse(Do.taskToolPermitted(allowed: ["Read,Task"], disallowed: ["task"], agent: .explore))
  }

  // MARK: Permission posture (--agent readOnly vs --yes / --permission-mode)

  func testReadOnlyLeadAgentNarrowsAnAutoApprovingModeWhateverYesSays() {
    // `arnes do --yes --permission-mode bypass --agent auditor` with a read-only auditor: the
    // mode drops to default (bypass/acceptEdits answer before the delegate is asked) and the
    // gate is the agent's denial — `--yes` never turns it into an auto-approving run.
    let auditor = AgentDefinition(name: "auditor", description: "", body: "Audit.", permissionMode: .readOnly)
    for mode in [PermissionMode.bypass, .acceptEdits, .default] {
      let posture = Do.leadPosture(agent: auditor, mode: mode, safe: false, yes: true)
      XCTAssertEqual(posture.mode, .default, "\(mode)")
      XCTAssertEqual(posture.gate, .agentReadOnly(name: "auditor"), "\(mode)")
      XCTAssertTrue(posture.readOnly, "\(mode)")
    }
    // `plan` denies more than the agent does and stays.
    let planned = Do.leadPosture(agent: auditor, mode: .plan, safe: false, yes: true)
    XCTAssertEqual(planned, Do.LeadPosture(mode: .plan, gate: .agentReadOnly(name: "auditor")))
    // Without --yes the agent's reason still names the agent (not the "pass --yes" hint).
    XCTAssertEqual(
      Do.leadPosture(agent: auditor, mode: .default, safe: false, yes: false),
      Do.LeadPosture(mode: .default, gate: .agentReadOnly(name: "auditor")))
    // `--safe` outranks the agent's gate (same denial, no reason); the mode is narrowed all the same.
    XCTAssertEqual(
      Do.leadPosture(agent: auditor, mode: .default, safe: true, yes: true),
      Do.LeadPosture(mode: .default, gate: .safe))
  }

  func testLeadPostureWithoutAReadOnlyAgentIsThePreX3Chain() {
    // No agent, or one that inherits: --safe > --yes > deny, the mode untouched.
    let inheriting = AgentDefinition(name: "writer", description: "", body: "Write.")
    XCTAssertEqual(inheriting.permissionMode, .inherit)
    for agent in [nil, inheriting] {
      XCTAssertEqual(
        Do.leadPosture(agent: agent, mode: .bypass, safe: false, yes: true),
        Do.LeadPosture(mode: .bypass, gate: .autoApprove))
      XCTAssertFalse(Do.leadPosture(agent: agent, mode: .bypass, safe: false, yes: true).readOnly)
      XCTAssertEqual(
        Do.leadPosture(agent: agent, mode: .acceptEdits, safe: false, yes: true),
        Do.LeadPosture(mode: .acceptEdits, gate: .autoApprove))
      XCTAssertEqual(
        Do.leadPosture(agent: agent, mode: .default, safe: false, yes: false),
        Do.LeadPosture(mode: .default, gate: .denyWithoutConsent))
      XCTAssertTrue(Do.leadPosture(agent: agent, mode: .default, safe: false, yes: false).readOnly)
      XCTAssertEqual(
        Do.leadPosture(agent: agent, mode: .plan, safe: false, yes: true),
        Do.LeadPosture(mode: .plan, gate: .autoApprove), "plan denies at the mode; the delegate is still --yes's")
      XCTAssertEqual(
        Do.leadPosture(agent: agent, mode: .default, safe: true, yes: true),
        Do.LeadPosture(mode: .default, gate: .safe), "--safe outranks --yes")
    }
  }

  // MARK: --budget on a resumed session

  func testBudgetCeilingIsLiftedByAResumedSessionsSpend() {
    // `Session(resuming:)` starts `costUSD` at the transcript's cumulative spend and compares
    // the ceiling against it, so the run's allowance rides on top of what was already spent.
    XCTAssertNil(Do.budgetCeiling(nil, resumedCostUSD: 0.30), "no budget, no ceiling")
    XCTAssertNil(Do.budgetCeiling(nil, resumedCostUSD: nil))
    XCTAssertEqual(try XCTUnwrap(Do.budgetCeiling(0.20, resumedCostUSD: nil)), 0.20, accuracy: 1e-9, "a fresh run: the flag as-is")
    XCTAssertEqual(try XCTUnwrap(Do.budgetCeiling(0.20, resumedCostUSD: 0.30)), 0.50, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(Do.budgetCeiling(0.20, resumedCostUSD: 0)), 0.20, accuracy: 1e-9)
  }

  // MARK: cwd mismatch warning

  func testStartedElsewhereResolvesSymlinksBeforeComparing() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-doflags-cwd-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    let link = base.appendingPathComponent("link")
    let other = base.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: base) }
    XCTAssertFalse(Do.startedElsewhere(real.path, cwd: real))
    XCTAssertFalse(Do.startedElsewhere(link.path, cwd: real), "a project reached through a symlink is the same place")
    XCTAssertFalse(Do.startedElsewhere(real.path, cwd: link))
    XCTAssertFalse(Do.startedElsewhere(real.path + "/", cwd: real), "a trailing slash is not a different directory")
    XCTAssertTrue(Do.startedElsewhere(other.path, cwd: real))
  }
}
