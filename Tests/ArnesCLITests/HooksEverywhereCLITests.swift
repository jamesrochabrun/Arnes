import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// H6 at the CLI: `arnes hooks test` (the dry run's report, driven with injected hooks) and
/// the `hooks` column `arnes runs` grows only when a run carries hook telemetry.
final class HooksEverywhereCLITests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h6-cli-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func loaded(_ hooks: [HookDefinition], trust: LoadedHook.Trust = .trusted) -> LoadedHooks {
    LoadedHooks(hooks: hooks.map { LoadedHook(definition: $0, trust: trust) })
  }

  // MARK: hooks test

  func testHooksTestReportsTheDenyDecisionAndTheRawOutput() async throws {
    let cwd = try tempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let hooks = loaded([
      HookDefinition(event: .preToolUse, matcher: "bash", command: "echo 'no rm here' >&2; exit 2", id: "no-rm"),
      HookDefinition(event: .preToolUse, matcher: "bash", prompt: "Safe? $ARGUMENTS", model: "cheap", id: "judge"),
    ])
    let lines = await HooksTest.report(
      loaded: hooks, event: .preToolUse, subject: "bash",
      argumentsJSON: #"{"command":"rm -rf /tmp/x"}"#, agent: nil, cwd: cwd)

    XCTAssertTrue(lines[0].hasPrefix("⚠ dry run: the hook commands below really run"), lines[0])
    XCTAssertTrue(lines[0].contains("no tool does"), lines[0])
    XCTAssertTrue(lines.contains { $0.hasPrefix("PreToolUse no-rm") }, "\(lines)")
    XCTAssertTrue(lines.contains("  ran · exit 2 · deny: no rm here"), "\(lines)")
    XCTAssertTrue(lines.contains("  │ no rm here"), "\(lines)")
    // The prompt hook applies but a dry run asks no model; it still counts as one that would run.
    XCTAssertTrue(lines.contains { $0.hasPrefix("PreToolUse judge") }, "\(lines)")
    XCTAssertTrue(lines.contains("  skipped (prompt hook — applies, but a dry run asks no model)"), "\(lines)")
    XCTAssertEqual(lines.last, "2 of 2 PreToolUse hooks would run for this call")
  }

  func testHooksTestNamesTheWhenKeyThatExcludedAHook() async throws {
    let cwd = try tempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let hooks = loaded([
      HookDefinition(event: .preToolUse, matcher: "edit_file", when: ["path": "**/*.swfit"], command: "exit 2", id: "typo"),
      HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 2", id: "other"),
      HookDefinition(event: .preToolUse, matcher: "edit_file", agent: "explore", command: "exit 2", id: "scoped"),
      HookDefinition(event: .preToolUse, matcher: "edit_file", command: "exit 2", id: "off", enabled: false),
      HookDefinition(event: .postToolUse, matcher: "edit_file", command: "echo after", id: "after"),
    ])
    let lines = await HooksTest.report(
      loaded: hooks, event: .preToolUse, subject: "edit_file",
      argumentsJSON: #"{"path":"src/x.swift"}"#, agent: nil, cwd: cwd)

    XCTAssertTrue(lines.contains("  skipped (when: path)"), "\(lines)")
    XCTAssertTrue(lines.contains("  skipped (matcher)"), "\(lines)")
    XCTAssertTrue(lines.contains("  skipped (agent)"), "\(lines)")
    XCTAssertTrue(lines.contains("  skipped (disabled)"), "\(lines)")
    XCTAssertFalse(lines.contains { $0.hasPrefix("PostToolUse") }, "only the tested event's hooks are listed")
    XCTAssertEqual(lines.last, "0 of 4 PreToolUse hooks would run for this call")

    // The same call as the explorer: the scoped hook now applies.
    let asExplorer = await HooksTest.report(
      loaded: hooks, event: .preToolUse, subject: "edit_file",
      argumentsJSON: #"{"path":"src/x.swift"}"#, agent: "explore", cwd: cwd)
    XCTAssertFalse(asExplorer.contains("  skipped (agent)"), "\(asExplorer)")
    XCTAssertEqual(asExplorer.last, "1 of 4 PreToolUse hooks would run for this call")
  }

  func testHooksTestShowsUntrustedProjectHooksAsSkippedAndClipsLongOutput() async throws {
    let cwd = try tempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    var project = HookDefinition(event: .stop, command: "true", id: "repo-check")
    project.source = .project
    let chatty = HookDefinition(event: .stop, command: "seq 1 30", id: "chatty")
    let hooks = LoadedHooks(hooks: [
      LoadedHook(definition: project, trust: .untrustedDirectory),
      LoadedHook(definition: chatty, trust: .trusted),
    ])
    let lines = await HooksTest.report(
      loaded: hooks, event: .stop, subject: nil, argumentsJSON: nil, agent: nil, cwd: cwd)

    XCTAssertTrue(lines.contains("  skipped (directory not trusted — run `arnes trust`, then `arnes hooks trust`)"), "\(lines)")
    XCTAssertTrue(lines.contains { $0.hasPrefix("  ran · exit 0 · no decision · feedback: 1") }, "\(lines)")
    XCTAssertTrue(lines.contains("  │ 20"), "\(lines)")
    XCTAssertFalse(lines.contains("  │ 21"), "output is clipped to 20 lines: \(lines)")
    XCTAssertTrue(lines.contains("  │ … 10 more lines"), "\(lines)")
    XCTAssertEqual(lines.last, "1 of 2 Stop hooks would run for this call")
  }

  /// A user hook and an identical trusted project hook share a fingerprint, so a run executes
  /// it once (`LoadedHooks.active`); the report says so on the copy and counts one run — and
  /// the loader's own notices (a loose-permission file) print under the warning, as in
  /// `arnes hooks`.
  func testHooksTestReportsAnIdenticalProjectCopyOnceAndShowsTheLoaderNotices() async throws {
    let cwd = try tempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let user = HookDefinition(event: .preToolUse, matcher: "bash", command: "echo twice", id: "same")
    var project = user
    project.source = .project
    XCTAssertEqual(user.fingerprint, project.fingerprint, "`source` is deliberately not hashed")
    let hooks = LoadedHooks(
      hooks: [LoadedHook(definition: user, trust: .trusted), LoadedHook(definition: project, trust: .trusted)],
      notices: ["⚠ /repo/.arnes/hooks.json is writable by other users — chmod 644 it; its hooks run commands"])
    let lines = await HooksTest.report(
      loaded: hooks, event: .preToolUse, subject: "bash", argumentsJSON: #"{"command":"ls"}"#, agent: nil, cwd: cwd)

    XCTAssertEqual(lines[1], "⚠ /repo/.arnes/hooks.json is writable by other users — chmod 644 it; its hooks run commands")
    XCTAssertEqual(lines.filter { $0.hasPrefix("  ran · exit 0") }.count, 1, "\(lines)")
    XCTAssertEqual(lines.filter { $0 == "  │ twice" }.count, 1, "\(lines)")
    XCTAssertTrue(lines.contains("  skipped (identical to a hook above — a run executes it once)"), "\(lines)")
    XCTAssertEqual(lines.last, "1 of 2 PreToolUse hooks would run for this call")
  }

  /// The defaulted subject reaches the matcher: `hooks test SubagentStart --agent explore`
  /// reports a `matcher: reviewer` hook skipped, as `subagentStart(agent: "explore")` would.
  func testHooksTestMatchesTheDefaultedSubjectForTheDelegationAndSessionEvents() async throws {
    let cwd = try tempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let hooks = loaded([
      HookDefinition(event: .subagentStart, matcher: "reviewer", command: "exit 2", id: "reviewers-only"),
      HookDefinition(event: .subagentStart, matcher: "explore", command: "echo ok", id: "explorers"),
      HookDefinition(event: .sessionStart, matcher: "resume", command: "echo resumed", id: "on-resume"),
    ])
    let spawn = await HooksTest.report(
      loaded: hooks, event: .subagentStart, subject: nil, argumentsJSON: nil, agent: "explore", cwd: cwd)
    XCTAssertTrue(spawn.contains("  skipped (matcher)"), "\(spawn)")
    XCTAssertTrue(spawn.contains("  ran · exit 0 · no decision"), "a gate's plain stdout is nothing: \(spawn)")
    XCTAssertTrue(spawn.contains("  │ ok"), "\(spawn)")
    XCTAssertEqual(spawn.last, "1 of 2 SubagentStart hooks would run for this call")

    let start = await HooksTest.report(
      loaded: hooks, event: .sessionStart, subject: nil, argumentsJSON: nil, agent: nil, cwd: cwd)
    XCTAssertTrue(start.contains("  skipped (matcher)"), "the default source is `startup`: \(start)")
    XCTAssertEqual(start.last, "0 of 1 SessionStart hook would run for this call")
  }

  func testHooksTestWithNoHooksForTheEventSaysSo() async throws {
    let cwd = try tempDir()
    defer { try? FileManager.default.removeItem(at: cwd) }
    let lines = await HooksTest.report(
      loaded: loaded([HookDefinition(event: .stop, command: "true")]), event: .preToolUse,
      subject: "bash", argumentsJSON: "{}", agent: nil, cwd: cwd)
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines[1], "no PreToolUse hooks configured (1 hook in total)")
  }

  func testHooksTestUnknownEventIsAUsageError() throws {
    XCTAssertThrowsError(try HooksTest.parseEvent("Bogus")) { error in
      let message = "\(error)"
      XCTAssertTrue(message.contains("unknown hook event 'Bogus'"), message)
      XCTAssertTrue(message.contains("PreToolUse"), "the valid names are listed: \(message)")
      XCTAssertTrue(message.contains("Notification"), message)
    }
    XCTAssertEqual(try HooksTest.parseEvent("pretooluse"), .preToolUse, "case is a courtesy")
    // Through the parser: validation fails → exit 64, the usage code.
    XCTAssertThrowsError(try HooksTest.parse(["Bogus"])) { error in
      XCTAssertEqual(HooksTest.exitCode(for: error).rawValue, 64)
    }
    XCTAssertThrowsError(try HooksTest.parse(["PreToolUse"])) { error in
      XCTAssertEqual(HooksTest.exitCode(for: error).rawValue, 64, "a tool event needs its tool name")
    }
    XCTAssertThrowsError(try HooksTest.parse(["PreToolUse", "bash", "not json"])) { error in
      XCTAssertEqual(HooksTest.exitCode(for: error).rawValue, 64)
    }
    let ok = try HooksTest.parse(["PreToolUse", "edit_file", #"{"path":"src/x.swift"}"#, "--agent", "explore"])
    XCTAssertEqual(ok.subject, "edit_file")
    XCTAssertEqual(ok.agent, "explore")
    XCTAssertNoThrow(try HooksTest.parse(["Stop"]))
    XCTAssertNoThrow(try HooksTest.parse(["SubagentStart", "--agent", "explore"]))
    XCTAssertNoThrow(try Hooks.parseAsRoot(["test", "SessionStart", "resume"]))
  }

  // MARK: headless text — a subagent's hook lines

  /// A subagent's hook notices, blocks and stops print indented with the `[name#id]` tag, the
  /// way its tool calls do; the lead's own hook lines are unchanged.
  func testHeadlessTextRendersASubagentsHookLinesIndentedWithTheRunTag() {
    func line(_ event: AgentEvent) -> String? {
      HeadlessEmitter.textLine(for: .subagent(name: "explore", id: "a1b2c3d4", event: event))
    }
    XCTAssertEqual(line(.hookNotice(event: "PermissionRequest", output: "asked twice")),
                   "  ⎔ [explore#a1b2c3d4] PermissionRequest hook: asked twice")
    XCTAssertEqual(line(.hookBlocked(tool: "bash", reason: "no rm")),
                   "  ⊘ [explore#a1b2c3d4] bash blocked by hook: no rm")
    XCTAssertEqual(line(.hookStopped(reason: nil)), "  ⏹ [explore#a1b2c3d4] asked to stop by hook")
    XCTAssertEqual(line(.hookStopped(reason: "enough")), "  ⏹ [explore#a1b2c3d4] asked to stop by hook: enough")
    XCTAssertEqual(line(.hookBlocked(tool: "bash", reason: String(repeating: "r", count: 200))),
                   "  ⊘ [explore#a1b2c3d4] bash blocked by hook: " + String(repeating: "r", count: 120),
                   "clipped like the lead's line")
    // Nested prose and results stay silent, as before.
    XCTAssertNil(line(.assistantText("thinking aloud")))
    XCTAssertNil(line(.toolResult(name: "bash", preview: "ok")))
    // The lead's lines are untouched.
    XCTAssertEqual(HeadlessEmitter.textLine(for: .hookNotice(event: "Stop", output: "tests green")), "⎔ Stop hook: tests green")
    XCTAssertEqual(HeadlessEmitter.textLine(for: .hookStopped(reason: nil)), "⏹ turn ended by hook")
  }

  // MARK: runs — hooks column

  private func record(model: String, cost: Double, hookBlocks: Int? = nil, hookContinuations: Int? = nil) -> RunRecord {
    var record = RunRecord(task: "t", model: model, dialect: "chat", packFamily: "generic")
    record.costUSD = cost
    record.finished = true
    record.hookBlocks = hookBlocks
    record.hookContinuations = hookContinuations
    return record
  }

  func testRunsScoreboardIsByteIdenticalWhenNoHookEverFired() {
    let records = [
      record(model: "a/model", cost: 0.01),
      record(model: "a/model", cost: 0.02, hookBlocks: 0, hookContinuations: 0),
      record(model: "b/model", cost: 0.10),
    ]
    XCTAssertEqual(Runs.scoreboardLines(records), [
      "a/model                                  runs=2\tcost=$0.0300\tverified=n/a",
      "b/model                                  runs=1\tcost=$0.1000\tverified=n/a",
    ])
  }

  func testRunsScoreboardGrowsTheHooksColumnWhenARunCarriesTelemetry() {
    let records = [
      record(model: "a/model", cost: 0.01, hookBlocks: 2),
      record(model: "a/model", cost: 0.02, hookContinuations: 1),
      record(model: "b/model", cost: 0.10),
    ]
    XCTAssertEqual(Runs.scoreboardLines(records), [
      "a/model                                  runs=2\tcost=$0.0300\tverified=n/a\thooks: blocks=2 cont=1",
      "b/model                                  runs=1\tcost=$0.1000\tverified=n/a\thooks: blocks=0 cont=0",
    ])
  }
}
