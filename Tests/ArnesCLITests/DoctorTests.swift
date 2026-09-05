import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// `arnes doctor` against a temp home — every check runs offline, nothing is executed, and
/// the output never carries the key the fixture puts in the environment.
final class DoctorTests: XCTestCase {
  private let secret = "sk-or-FIXTURE-SECRET-9f8e7d"

  /// A home with `.arnes/` (0700), a project directory, and a `bin/` on PATH holding an
  /// executable `git` and `my-guardrail.sh` — the all-ok fixture the others perturb.
  private struct Fixture {
    let root: URL
    var home: URL { root.appendingPathComponent("home") }
    var arnes: URL { home.appendingPathComponent(".arnes") }
    var cwd: URL { root.appendingPathComponent("project") }
    var bin: URL { root.appendingPathComponent("bin") }
    var environment: [String: String]

    func write(_ text: String, to relative: String, mode: Int = 0o600) throws {
      let url = root.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
      try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    func executable(_ name: String) throws {
      try write("#!/bin/sh\nexit 0\n", to: "bin/\(name)", mode: 0o755)
    }
  }

  private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-doctor-\(UUID().uuidString)")
    var fixture = Fixture(root: root, environment: [:])
    try FileManager.default.createDirectory(at: fixture.arnes, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try FileManager.default.createDirectory(at: fixture.cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixture.bin, withIntermediateDirectories: true)
    try fixture.executable("git")
    try fixture.executable("my-guardrail.sh")
    fixture.environment = ["OPENROUTER_API_KEY": secret, "PATH": fixture.bin.path, "HOME": fixture.home.path]
    return fixture
  }

  private func run(_ fixture: Fixture) async -> [DoctorChecks.Check] {
    await DoctorChecks.run(home: fixture.home, cwd: fixture.cwd, environment: fixture.environment, connect: false)
  }

  private func level(_ checks: [DoctorChecks.Check], _ name: String) -> DoctorChecks.Level? {
    checks.filter { $0.name == name }.map(\.level).max()
  }

  /// The first check named `name` after a run, or a failed test.
  private func first(_ fixture: Fixture, _ name: String) async throws -> DoctorChecks.Check {
    let checks = await run(fixture)
    return try XCTUnwrap(checks.first { $0.name == name }, "no \(name) check in \(checks)")
  }

  // MARK: all ok

  func testAllOkFixtureHasNoErrorsAndNeverPrintsTheKey() async throws {
    let fixture = try makeFixture()
    let checks = await run(fixture)
    XCTAssertEqual(DoctorChecks.exitCode(for: checks), 0, "\(checks)")
    XCTAssertEqual(checks.filter { $0.level == .error }, [])
    for name in ["config", "provider", "permissions", "hooks", "mcp", "rules", "sandbox", "packs", "trust", "data", "tools", "instructions"] {
      XCTAssertNotNil(level(checks, name), "no \(name) check")
    }
    XCTAssertEqual(level(checks, "provider"), .ok)
    let provider = try XCTUnwrap(checks.first { $0.name == "provider" })
    XCTAssertTrue(provider.detail.contains("key from env OPENROUTER_API_KEY"), provider.detail)
    let text = DoctorChecks.textLines(checks).joined(separator: "\n")
    let json = try JSONOut.line(DoctorReport(checks: checks))
    XCTAssertFalse(text.contains(secret))
    XCTAssertFalse(json.contains(secret))
    XCTAssertTrue(text.contains("checks · 0 errors"), text)
  }

  // MARK: config / provider

  func testMalformedConfigIsAnErrorWithTheDecodeMessage() async throws {
    let fixture = try makeFixture()
    try fixture.write("{not json", to: "home/.arnes/config.json")
    let checks = await run(fixture)
    let config = try XCTUnwrap(checks.first { $0.name == "config" })
    XCTAssertEqual(config.level, .error)
    XCTAssertTrue(config.detail.contains("is invalid"), config.detail)
    XCTAssertNotNil(config.fix)
    XCTAssertEqual(DoctorChecks.exitCode(for: checks), 1)
  }

  func testMissingKeyIsAnErrorNamingTheFix() async throws {
    var fixture = try makeFixture()
    fixture.environment.removeValue(forKey: "OPENROUTER_API_KEY")
    let checks = await run(fixture)
    let provider = try XCTUnwrap(checks.first { $0.name == "provider" })
    XCTAssertEqual(provider.level, .error)
    XCTAssertTrue(provider.fix?.contains("export OPENROUTER_API_KEY=") == true, provider.fix ?? "nil")
    XCTAssertTrue(provider.fix?.contains(fixture.arnes.appendingPathComponent("credentials").path) == true, provider.fix ?? "nil")
  }

  func testEmptyAliasIsAWarning() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      #"{"providers": {"openrouter": {"kind": "openrouter", "baseURL": "https://openrouter.ai/api/v1", "aliases": {"haiku": "", "": "x/y"}}}}"#,
      to: "home/.arnes/config.json")
    let checks = await run(fixture)
    XCTAssertEqual(level(checks, "aliases"), .warn)
    XCTAssertEqual(level(checks, "config"), .ok)
  }

  // MARK: permissions

  func testLooseCredentialsModeIsAWarningWithTheChmodFix() async throws {
    let fixture = try makeFixture()
    try fixture.write("OPENROUTER_API_KEY=\(secret)\n", to: "home/.arnes/credentials", mode: 0o644)
    let checks = await run(fixture)
    let permissions = try XCTUnwrap(checks.first { $0.name == "permissions" })
    XCTAssertEqual(permissions.level, .warn)
    XCTAssertTrue(permissions.detail.contains("credentials is readable by other users"), permissions.detail)
    XCTAssertTrue(permissions.fix?.contains("chmod 600") == true)
    XCTAssertFalse(DoctorChecks.textLines(checks).joined().contains(secret))
    // Warnings never fail the command.
    XCTAssertEqual(DoctorChecks.exitCode(for: checks), 0)
  }

  func testGroupReachableArnesDirIsAWarning() async throws {
    let fixture = try makeFixture()
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.arnes.path)
    let checks = await run(fixture)
    let permissions = try XCTUnwrap(checks.first { $0.name == "permissions" })
    XCTAssertEqual(permissions.level, .warn)
    XCTAssertTrue(permissions.fix?.contains("chmod 700") == true)
  }

  // MARK: hooks

  func testMissingHookExecutableIsAnErrorNamingTheHook() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      #"{"hooks": [{"event": "PreToolUse", "matcher": "bash", "id": "no-force-push", "command": "my-guardrial.sh --strict"}]}"#,
      to: "home/.arnes/hooks.json")
    let checks = await run(fixture)
    let hook = try XCTUnwrap(checks.first { $0.name == "hooks" && $0.level == .error })
    XCTAssertTrue(hook.detail.contains("'no-force-push'"), hook.detail)
    XCTAssertTrue(hook.detail.contains("`my-guardrial.sh`"), hook.detail)
    XCTAssertTrue(hook.detail.contains("silently disables the gate"), hook.detail)
    XCTAssertEqual(DoctorChecks.exitCode(for: checks), 1)
  }

  func testResolvableHooksBuiltinsAndProjectTrustStates() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      #"{"hooks": [{"event": "PreToolUse", "matcher": "bash", "command": "my-guardrail.sh"}, {"event": "Stop", "command": "echo done >&2; exit 0"}, {"event": "Stop", "command": "not-installed-but-off", "enabled": false}]}"#,
      to: "home/.arnes/hooks.json")
    // A project hook in an untrusted directory: parsed, reported as not running.
    try fixture.write(
      #"{"hooks": [{"event": "PostToolUse", "matcher": "edit_file", "id": "fmt", "command": "my-guardrail.sh --format"}]}"#,
      to: "project/.arnes/hooks.json", mode: 0o644)
    let checks = await run(fixture)
    let hooks = checks.filter { $0.name == "hooks" }
    XCTAssertFalse(hooks.contains { $0.level == .error }, "\(hooks)")
    XCTAssertTrue(hooks.contains { $0.level == .ok && $0.detail.hasPrefix("2 of 3 enabled hooks resolve") }, "\(hooks)")
    let project = try XCTUnwrap(hooks.first { $0.level == .warn })
    XCTAssertTrue(project.detail.contains("'fmt'"), project.detail)
    XCTAssertTrue(project.detail.contains("isn't trusted"), project.detail)
    XCTAssertTrue(project.fix?.contains("arnes hooks trust") == true)
  }

  func testPromptHookWithoutAModelOrJudgeIsAWarning() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      #"{"hooks": [{"event": "PreToolUse", "matcher": "bash", "type": "prompt", "prompt": "safe? $ARGUMENTS"}]}"#,
      to: "home/.arnes/hooks.json")
    var checks = await run(fixture)
    XCTAssertEqual(level(checks, "hooks"), .warn)
    XCTAssertTrue(checks.first { $0.name == "hooks" }?.detail.contains("no bashJudge") == true)
    // With a judge configured the same hook is usable.
    try fixture.write(
      #"{"providers": {"openrouter": {"kind": "openrouter", "baseURL": "https://openrouter.ai/api/v1", "bashJudge": "cheap/model"}}}"#,
      to: "home/.arnes/config.json")
    checks = await run(fixture)
    XCTAssertEqual(level(checks, "hooks"), .ok)
  }

  func testMalformedHooksFileIsAnError() async throws {
    let fixture = try makeFixture()
    try fixture.write("[", to: "home/.arnes/hooks.json")
    let checks = await run(fixture)
    XCTAssertEqual(level(checks, "hooks"), .error)
  }

  func testHookProgramSkipsAssignmentsEnvAndBuiltins() {
    XCTAssertEqual(DoctorChecks.hookProgram("my-guardrail.sh --strict"), "my-guardrail.sh")
    XCTAssertEqual(DoctorChecks.hookProgram("FOO=1 BAR=two swiftformat ."), "swiftformat")
    XCTAssertEqual(DoctorChecks.hookProgram("env -i FOO=1 swiftlint lint"), "swiftlint")
    XCTAssertEqual(DoctorChecks.hookProgram("./scripts/check.sh | tail -3"), "./scripts/check.sh")
    XCTAssertEqual(DoctorChecks.hookProgram("\"my prog\" arg"), "my prog")
    XCTAssertEqual(DoctorChecks.hookProgram("swift test 2>&1 | tail -3"), "swift")
    XCTAssertNil(DoctorChecks.hookProgram("echo 'no secrets' >&2; exit 2"))
    XCTAssertNil(DoctorChecks.hookProgram("sh -c 'rm -rf x'"))
    XCTAssertNil(DoctorChecks.hookProgram("if [ -f x ]; then cat x; fi"))
    XCTAssertNil(DoctorChecks.hookProgram("$GUARD --flag"))
    XCTAssertNil(DoctorChecks.hookProgram(""))
    XCTAssertNil(DoctorChecks.hookProgram("   "))
    // `sh -c` expands a leading tilde, so a `~/…` program is a path to check, not an expansion.
    XCTAssertEqual(DoctorChecks.hookProgram("~/.arnes/hooks/guard.sh --strict"), "~/.arnes/hooks/guard.sh")
  }

  func testTildeHookPathResolvesAgainstTheInjectedHome() async throws {
    let fixture = try makeFixture()
    try fixture.write("#!/bin/sh\n", to: "home/.arnes/hooks/guard.sh", mode: 0o755)
    XCTAssertEqual(
      DoctorChecks.resolveExecutable("~/.arnes/hooks/guard.sh", environment: fixture.environment, cwd: fixture.cwd, home: fixture.home),
      fixture.home.appendingPathComponent(".arnes/hooks/guard.sh").path)
    XCTAssertNil(DoctorChecks.resolveExecutable("~/.arnes/hooks/missing.sh", environment: fixture.environment, cwd: fixture.cwd, home: fixture.home))
    try fixture.write(
      #"{"hooks": [{"event": "PreToolUse", "matcher": "bash", "id": "guard", "command": "~/.arnes/hooks/guard.sh"}, {"event": "Stop", "id": "gone", "command": "~/.arnes/hooks/missing.sh"}]}"#,
      to: "home/.arnes/hooks.json")
    let checks = await run(fixture)
    let hooks = checks.filter { $0.name == "hooks" }
    let missing = try XCTUnwrap(hooks.first { $0.level == .error })
    XCTAssertTrue(missing.detail.contains("'gone'"), missing.detail)
    XCTAssertTrue(hooks.contains { $0.level == .ok && $0.detail.hasPrefix("1 of 2 enabled hooks resolve") }, "\(hooks)")
  }

  func testUntrustedProjectHookWithAMissingProgramIsOnlyAWarning() async throws {
    let fixture = try makeFixture()
    // Inert (the directory isn't trusted), so its missing program disables no gate: one warn
    // row about trust, no error, exit 0.
    try fixture.write(
      #"{"hooks": [{"event": "PreToolUse", "matcher": "bash", "id": "repo-guard", "command": "tool-the-runner-lacks --check"}]}"#,
      to: "project/.arnes/hooks.json", mode: 0o644)
    let checks = await run(fixture)
    let hooks = checks.filter { $0.name == "hooks" }
    XCTAssertFalse(hooks.contains { $0.level == .error }, "\(hooks)")
    let project = try XCTUnwrap(hooks.first { $0.level == .warn })
    XCTAssertTrue(project.detail.contains("'repo-guard'"), project.detail)
    XCTAssertTrue(project.detail.contains("isn't trusted"), project.detail)
    XCTAssertEqual(DoctorChecks.exitCode(for: checks), 0)
  }

  func testResolveExecutableSearchesTheGivenPathAndChecksPathsDirectly() throws {
    let fixture = try makeFixture()
    XCTAssertEqual(
      DoctorChecks.resolveExecutable("git", environment: fixture.environment, cwd: fixture.cwd),
      fixture.bin.appendingPathComponent("git").path)
    XCTAssertNil(DoctorChecks.resolveExecutable("definitely-not-here", environment: fixture.environment, cwd: fixture.cwd))
    try fixture.write("#!/bin/sh\n", to: "project/scripts/x.sh", mode: 0o755)
    XCTAssertNotNil(DoctorChecks.resolveExecutable("./scripts/x.sh", environment: fixture.environment, cwd: fixture.cwd))
    XCTAssertNil(DoctorChecks.resolveExecutable("./scripts/missing.sh", environment: fixture.environment, cwd: fixture.cwd))
    XCTAssertNotNil(DoctorChecks.resolveExecutable("/bin/sh", environment: fixture.environment, cwd: fixture.cwd))
  }

  func testResolveExecutableSearchesThePathTheConfiguredPolicyGivesARun() throws {
    // A `shellEnvironment` that reshapes PATH is what the run's hooks inherit; the doctor must
    // look where they will look, not where the doctor process would.
    let fixture = try makeFixture()
    let other = fixture.root.appendingPathComponent("other-bin")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try fixture.write("#!/bin/sh\n", to: "other-bin/only-there", mode: 0o755)
    let policy = ShellEnvironmentPolicy(inherit: .empty, set: ["PATH": other.path])
    XCTAssertEqual(
      DoctorChecks.resolveExecutable("only-there", environment: fixture.environment, cwd: fixture.cwd, policy: policy),
      other.appendingPathComponent("only-there").path)
    XCTAssertNil(DoctorChecks.resolveExecutable("git", environment: fixture.environment, cwd: fixture.cwd, policy: policy),
                 "the fixture's bin is not on the policy's PATH")
    XCTAssertNotNil(DoctorChecks.resolveExecutable("git", environment: fixture.environment, cwd: fixture.cwd))
  }

  // MARK: mcp

  func testMalformedMCPConfigIsAnError() async throws {
    let fixture = try makeFixture()
    try fixture.write(#"{"mcpServers": {"fs": {"command": 3}}}"#, to: "home/.arnes/mcp.json")
    let checks = await run(fixture)
    let mcp = try XCTUnwrap(checks.first { $0.name == "mcp" })
    XCTAssertEqual(mcp.level, .error)
    XCTAssertTrue(mcp.detail.contains("mcp.json is invalid"), mcp.detail)
  }

  func testMCPEntriesAreCheckedOfflineForCommandsAndURLs() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      """
      {"mcpServers": {
        "ok": {"command": "git"},
        "missing": {"command": "no-such-server"},
        "missing-required": {"command": "no-such-server", "required": true},
        "docs": {"url": "https://mcp.example.com/mcp"},
        "plain": {"url": "http://mcp.example.com/mcp"},
        "off": {"command": "no-such-server", "enabled": false}
      }}
      """,
      to: "home/.arnes/mcp.json")
    let checks = await run(fixture).filter { $0.name == "mcp" }
    XCTAssertTrue(checks.contains { $0.level == .warn && $0.detail.hasPrefix("server missing:") }, "\(checks)")
    XCTAssertTrue(checks.contains { $0.level == .error && $0.detail.hasPrefix("server missing-required:") && $0.detail.contains("required") }, "\(checks)")
    let plain = try XCTUnwrap(checks.first { $0.level == .warn && $0.detail.hasPrefix("server plain:") }, "\(checks)")
    XCTAssertTrue(plain.detail.contains("mcp.example.com"), plain.detail)
    XCTAssertFalse(plain.detail.contains("/mcp"), "the row names the host, never the URL path: \(plain.detail)")
    XCTAssertFalse(checks.contains { $0.detail.contains("server off") }, "\(checks)")
    XCTAssertTrue(checks.contains { $0.level == .ok && $0.detail.hasPrefix("2 of 5 enabled servers resolve") }, "\(checks)")
    XCTAssertTrue(checks.contains { $0.detail.contains("--connect") }, "\(checks)")
  }

  func testProjectMCPFileWithABadURLIsAWarningNamingTheHostOnly() async throws {
    let fixture = try makeFixture()
    try fixture.write(#"{"mcpServers": {"plain": {"url": "http://mcp.example.com/mcp?token=SECRET"}}}"#, to: "project/.mcp.json")
    let checks = await run(fixture).filter { $0.name == "mcp" }
    XCTAssertEqual(checks.count, 2, checks.description)
    XCTAssertTrue(checks[0].detail.contains("project") && checks[0].detail.contains("1 server") && checks[0].detail.contains("not trusted"), checks[0].detail)
    XCTAssertEqual(checks[0].level, .warn)
    XCTAssertTrue(checks[1].detail.contains("project server plain") && checks[1].detail.contains("mcp.example.com"), checks[1].detail)
    XCTAssertEqual(checks[1].level, .warn, "a project entry is never an error")
    XCTAssertFalse(checks[1].detail.contains("SECRET") || checks[1].detail.contains("/mcp"), checks[1].detail)
    XCTAssertFalse(checks.contains { $0.detail == "no MCP servers configured" }, "the user file is empty, but the project file is not nothing")
  }

  // MARK: rules

  func testRulesFileProblemsAreWarningsAndAMalformedFileIsAnError() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      #"{"deny": ["Bash(rm:*)", "Frobnicate", "Frob(x)"], "allow": ["read_file", "mcp__github__*"]}"#,
      to: "home/.arnes/rules.json")
    var checks = await run(fixture).filter { $0.name == "rules" }
    XCTAssertTrue(checks.contains { $0.level == .warn && $0.detail.contains("don't parse") && $0.detail.contains("Frob(x)") }, "\(checks)")
    XCTAssertTrue(checks.contains { $0.level == .warn && $0.detail.contains("Frobnicate") }, "\(checks)")
    XCTAssertFalse(checks.contains { $0.detail.contains("mcp__github__*") && $0.level == .warn }, "\(checks)")
    try fixture.write("nope", to: "home/.arnes/rules.json")
    checks = await run(fixture).filter { $0.name == "rules" }
    XCTAssertEqual(checks.map(\.level), [.error])
  }

  // MARK: sandbox

  func testSandboxEnabledIsJudgedAgainstPlatformSupportAndFailIfUnavailable() async throws {
    let fixture = try makeFixture()
    try fixture.write(
      #"{"providers": {"openrouter": {"kind": "openrouter", "baseURL": "https://openrouter.ai/api/v1", "sandbox": {"enabled": true}}}}"#,
      to: "home/.arnes/config.json")
    var sandbox = try await first(fixture, "sandbox")
    XCTAssertEqual(sandbox.level, ShellSandbox.isSupported ? .ok : .error, sandbox.detail)
    try fixture.write(
      #"{"providers": {"openrouter": {"kind": "openrouter", "baseURL": "https://openrouter.ai/api/v1", "sandbox": {"enabled": true, "failIfUnavailable": false}}}}"#,
      to: "home/.arnes/config.json")
    sandbox = try await first(fixture, "sandbox")
    XCTAssertEqual(sandbox.level, ShellSandbox.isSupported ? .ok : .warn, sandbox.detail)
    try fixture.write(
      #"{"providers": {"openrouter": {"kind": "openrouter", "baseURL": "https://openrouter.ai/api/v1", "sandbox": {"enabled": false}}}}"#,
      to: "home/.arnes/config.json")
    sandbox = try await first(fixture, "sandbox")
    XCTAssertEqual(sandbox.level, .ok)
    XCTAssertTrue(sandbox.detail.contains("disabled explicitly"), sandbox.detail)
  }

  // MARK: packs

  func testOversizedPackIsAWarning() async throws {
    let fixture = try makeFixture()
    try fixture.write(String(repeating: "x", count: DoctorChecks.packSizeWarningBytes + 1), to: "home/.arnes/packs/deepseek.md")
    try fixture.write("# Small\nfine", to: "home/.arnes/packs/anthropic.md")
    let packs = await run(fixture).filter { $0.name == "packs" }
    XCTAssertEqual(packs.count, 2)
    XCTAssertEqual(packs.first { $0.detail.hasPrefix("anthropic:") }?.level, .ok)
    let big = try XCTUnwrap(packs.first { $0.detail.hasPrefix("deepseek:") })
    XCTAssertEqual(big.level, .warn)
    XCTAssertTrue(big.fix?.contains("arnes debug prompt") == true)
  }

  // MARK: trust

  func testStaleTrustedDirectoryIsAWarning() async throws {
    let fixture = try makeFixture()
    let gone = fixture.root.appendingPathComponent("gone-project").path
    try fixture.write(#"{"directories": ["\#(fixture.cwd.path)", "\#(gone)"]}"#, to: "home/.arnes/trusted.json")
    let trust = try await first(fixture, "trust")
    XCTAssertEqual(trust.level, .warn)
    XCTAssertTrue(trust.detail.contains("gone-project"), trust.detail)
    XCTAssertTrue(trust.fix?.contains("arnes trust --forget") == true)
  }

  // MARK: data

  func testMalformedDataRowsAreAWarningAndCountsAreReported() async throws {
    let fixture = try makeFixture()
    try fixture.write("{\"a\":1}\nnot json\n{\"b\":2}\n", to: "home/.arnes/runs.jsonl")
    try fixture.write("{}\n", to: "home/.arnes/sessions/S1.jsonl")
    let data = try await first(fixture, "data")
    XCTAssertEqual(data.level, .warn)
    XCTAssertTrue(data.detail.contains("runs.jsonl 3 rows"), data.detail)
    XCTAssertTrue(data.detail.contains("(1 malformed)"), data.detail)
    XCTAssertTrue(data.detail.contains("sessions/ 1 transcripts"), data.detail)
  }

  func testDataCountsCheckpointsAndMemoryAndLeavesThemOutWhenEmpty() async throws {
    let fixture = try makeFixture()
    try fixture.write("{}\n", to: "home/.arnes/sessions/S1.jsonl")
    // Absent or empty directories are no part at all — the all-ok output is unchanged.
    try FileManager.default.createDirectory(at: fixture.arnes.appendingPathComponent("checkpoints"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: fixture.arnes.appendingPathComponent("memory"), withIntermediateDirectories: true)
    var data = try await first(fixture, "data")
    XCTAssertFalse(data.detail.contains("checkpoints/"), data.detail)
    XCTAssertFalse(data.detail.contains("memory/"), data.detail)

    // One session (an index beside two blobs); a directory without an index is not a session.
    let index = "{\"schema\":1}"
    let blobs = ["blob-one", "blob-two!"]
    try fixture.write(index, to: "home/.arnes/checkpoints/S1/index.json")
    try fixture.write(blobs[0], to: "home/.arnes/checkpoints/S1/blobs/aaa")
    try fixture.write(blobs[1], to: "home/.arnes/checkpoints/S1/blobs/bbb")
    try fixture.write("stray", to: "home/.arnes/checkpoints/junk/notes.txt")
    // Two projects, one with an agent scope; the bytes are the indexes'.
    let notes = ["- fact one\n", "- agent fact\n", "- other\n"]
    try fixture.write(notes[0], to: "home/.arnes/memory/-a-project/MEMORY.md")
    try fixture.write(notes[1], to: "home/.arnes/memory/-a-project/agents/explore/MEMORY.md")
    try fixture.write(notes[2], to: "home/.arnes/memory/-b-project/MEMORY.md")
    data = try await first(fixture, "data")
    XCTAssertEqual(data.level, .ok)
    let checkpointBytes = index.utf8.count + blobs.reduce(0) { $0 + $1.utf8.count }
    XCTAssertTrue(data.detail.contains("checkpoints/ 1 session, 2 blobs, \(checkpointBytes) bytes"), data.detail)
    let memoryBytes = notes.reduce(0) { $0 + $1.utf8.count }
    XCTAssertTrue(data.detail.contains("memory/ 2 projects, 1 agent scope, \(memoryBytes) bytes"), data.detail)
    XCTAssertFalse(data.detail.contains(" at /"), "the default root is not named")
  }

  func testDataHonoursTheMemoryRootOverrideAndNamesIt() async throws {
    var fixture = try makeFixture()
    let elsewhere = fixture.root.appendingPathComponent("notes")
    try fixture.write("- moved\n", to: "notes/-a-project/MEMORY.md")
    // `ARNES_MEMORY_DIR` outranks `memory.directory`, which outranks the default.
    try fixture.write(#"{"memory": {"directory": "/nonexistent/arnes-memory-config"}}"#, to: "home/.arnes/config.json")
    fixture.environment["ARNES_MEMORY_DIR"] = elsewhere.path
    let data = try await first(fixture, "data")
    XCTAssertTrue(
      data.detail.contains("memory/ 1 project, 0 agent scopes, \("- moved\n".utf8.count) bytes at \(elsewhere.standardizedFileURL.path)"),
      data.detail)
  }

  // MARK: tools

  func testMissingGitIsAWarning() async throws {
    var fixture = try makeFixture()
    try FileManager.default.removeItem(at: fixture.bin.appendingPathComponent("git"))
    fixture.environment["PATH"] = fixture.bin.path
    let tools = try await first(fixture, "tools")
    XCTAssertEqual(tools.level, .warn)
    XCTAssertTrue(tools.detail.contains("git is not on PATH"), tools.detail)
  }

  // MARK: instructions

  func testInstructionFilesAreListedWithTheTrustNoteAndTheCap() async throws {
    let fixture = try makeFixture()
    try fixture.write("# Rules\nRun the tests.", to: "project/AGENTS.md", mode: 0o644)
    var instructions = try await first(fixture, "instructions")
    XCTAssertEqual(instructions.level, .ok)
    XCTAssertTrue(instructions.detail.contains("AGENTS.md"), instructions.detail)
    XCTAssertTrue(instructions.detail.contains("only once this directory is trusted"), instructions.detail)
    // Over the configured cap: a warning that names the truncation.
    try fixture.write(
      #"{"instructions": {"maxBytes": 10}}"#, to: "home/.arnes/config.json")
    instructions = try await first(fixture, "instructions")
    XCTAssertEqual(instructions.level, .warn)
    XCTAssertTrue(instructions.detail.contains("over the 10-byte cap"), instructions.detail)
  }

  // MARK: output shape

  func testExitCodeTextAndJSONShape() throws {
    let checks = [
      DoctorChecks.Check("config", .ok, "parses"),
      DoctorChecks.Check("hooks", .warn, "one skipped", fix: "arnes hooks trust"),
    ]
    XCTAssertEqual(DoctorChecks.exitCode(for: checks), 0)
    XCTAssertEqual(DoctorChecks.exitCode(for: checks + [DoctorChecks.Check("mcp", .error, "bad")]), 1)
    let text = DoctorChecks.textLines(checks).map {
      $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
    }
    XCTAssertEqual(text, ["✓ config: parses", "! hooks: one skipped", "    fix: arnes hooks trust", "", "2 checks · 0 errors · 1 warning"])
    XCTAssertEqual(
      try JSONOut.line(DoctorReport(checks: checks)),
      #"{"checks":[{"detail":"parses","level":"ok","name":"config"},{"detail":"one skipped","fix":"arnes hooks trust","level":"warn","name":"hooks"}],"errors":0,"warnings":1}"#)
  }
}
