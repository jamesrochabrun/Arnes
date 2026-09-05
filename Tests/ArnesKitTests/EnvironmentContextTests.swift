import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// E1 — the `# Environment` block: a fixed-order, byte-stable system-prompt section carrying
/// cwd, platform, date, git snapshot and run posture, rendered once per session and handed
/// to `Session` through `Configuration.extraSystemSections`.
final class EnvironmentContextTests: XCTestCase {
  private func tempDirectory(_ label: String = "env") throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-env-runs-\(UUID().uuidString).jsonl"))
  }

  private func systemPrompt(of request: ChatCompletionRequest) throws -> String {
    try XCTUnwrap(request.messages.first { $0.role == .system }?.content?.plainText)
  }

  private static let sampleGit = GitSnapshot(
    branch: "main",
    status: [" M Sources/a.swift", "?? notes.txt", "A  Tests/b.swift"],
    recentSubjects: ["Add the thing", "Fix the other thing", "Refactor", "Docs", "Initial commit"])

  private func render(
    cwd: URL = URL(fileURLWithPath: "/work/project"),
    git: GitSnapshot? = sampleGit,
    model: String = "acme/model-1",
    mode: PermissionMode = .default,
    readOnly: Bool = false,
    sandbox: ShellSandbox? = nil,
    effort: Reasoning.Effort? = nil)
    -> String
  {
    EnvironmentContext.render(
      cwd: cwd, os: "TestOS 1.0 (Kernel 2.0, arm64)", date: "2026-01-02", git: git,
      model: model, permissionMode: mode, readOnly: readOnly, sandbox: sandbox, effort: effort)
  }

  // MARK: Rendering

  func testRenderIsByteIdenticalFixedOrderAndTight() throws {
    let first = render()
    let second = render()
    XCTAssertEqual(first, second, "identical inputs must render identical bytes (cache prefix)")
    XCTAssertLessThanOrEqual(first.split(separator: "\n", omittingEmptySubsequences: false).count, 25)
    XCTAssertTrue(first.hasPrefix("# Environment\n"))

    // Fixed order: every fact in its place, git last.
    let markers = [
      "- Working directory: /work/project",
      "- Platform: TestOS 1.0 (Kernel 2.0, arm64)",
      "- Date: 2026-01-02",
      "- Model: acme/model-1",
      "- Permission mode: default",
      "- Sandbox: off",
      "- Git branch: main",
      "- Git status (3 entries):",
      "   M Sources/a.swift",
      "  ?? notes.txt",
      "- Recent commits (newest first):",
      "  Add the thing",
      "  Initial commit",
    ]
    var cursor = first.startIndex
    for marker in markers {
      let range = try XCTUnwrap(first.range(of: marker, range: cursor..<first.endIndex), "missing or out of order: \(marker)")
      cursor = range.upperBound
    }
    // The preamble tells the model it may rely on the block instead of probing.
    XCTAssertTrue(first.contains("Rely on them instead of probing"))
  }

  func testRenderNeverExceedsMaxLines() {
    // Everything on: effort set, a dirty repository past the status cap, a full commit list.
    let worst = GitSnapshot(
      branch: "main", status: (1...45).map { "?? file-\($0).txt" }, statusCount: 45,
      recentSubjects: ["a", "b", "c", "d", "e"])
    let block = render(git: worst, effort: .high)
    let lines = block.split(separator: "\n", omittingEmptySubsequences: false).count
    XCTAssertEqual(lines, EnvironmentContext.maxLines, "the documented bound is the real worst case")
    XCTAssertEqual(EnvironmentContext.maxLines, 39)
    // The common cases stay small: no repository → 9 lines; a clean one with one commit → 13
    // (branch, `clean`, the commits header, the subject).
    XCTAssertEqual(render(git: nil).split(separator: "\n", omittingEmptySubsequences: false).count, 9)
    XCTAssertEqual(
      render(git: GitSnapshot(branch: "main", recentSubjects: ["one"]))
        .split(separator: "\n", omittingEmptySubsequences: false).count, 13)
  }

  func testRenderOmitsWhatIsAbsentAndNamesTheRunPosture() {
    let bare = render(git: nil)
    XCTAssertFalse(bare.contains("Git"), "no repository → no git lines at all")
    XCTAssertFalse(bare.contains("Reasoning effort"), "unset effort → no line")
    XCTAssertLessThanOrEqual(bare.split(separator: "\n").count, 25)

    let confined = ShellSandbox(
      writableRoots: [URL(fileURLWithPath: "/work/project")], allowNetwork: false, home: "/home/u")
    let full = render(git: nil, mode: .acceptEdits, sandbox: confined, effort: .high)
    XCTAssertTrue(full.contains("- Permission mode: acceptEdits"))
    XCTAssertTrue(full.contains("- Sandbox: on (writes confined to the working tree; network off)"))
    XCTAssertTrue(full.contains("- Reasoning effort: high"))

    let open = ShellSandbox(
      writableRoots: [URL(fileURLWithPath: "/work/project")], allowNetwork: true, home: "/home/u")
    XCTAssertTrue(render(git: nil, sandbox: open).hasSuffix("- Sandbox: on (writes confined to the working tree)"))

    // `--add-dir` / `sandbox.writable` widen the boundary; the line says so instead of
    // claiming a confinement narrower than the real one.
    let widened = ShellSandbox(
      writableRoots: [URL(fileURLWithPath: "/work/project"), URL(fileURLWithPath: "/work/shared")],
      allowNetwork: true, home: "/home/u")
    XCTAssertTrue(render(git: nil, sandbox: widened)
      .hasSuffix("- Sandbox: on (writes confined to the working tree + 1 other directory)"))
    let wider = ShellSandbox(
      writableRoots: ["/work/project", "/work/a", "/work/b"].map { URL(fileURLWithPath: $0) },
      allowNetwork: false, home: "/home/u")
    XCTAssertTrue(render(git: nil, sandbox: wider)
      .hasSuffix("- Sandbox: on (writes confined to the working tree + 2 other directories; network off)"))

    // A read-only delegate overrides the mode label: the model shouldn't plan writes.
    XCTAssertTrue(render(git: nil, mode: .bypass, readOnly: true).contains("- Permission mode: read-only"))

    // A clean tree says so instead of listing nothing.
    let clean = render(git: GitSnapshot(branch: "dev", recentSubjects: ["one"]))
    XCTAssertTrue(clean.contains("- Git branch: dev\n- Git status: clean\n- Recent commits (newest first):\n  one"))
  }

  func testRenderCapsStatusAtTwentyLinesWithATailAndScrubsLines() {
    let lines = (1...45).map { "?? file-\($0).txt" }
    let snapshot = GitSnapshot(branch: "main", status: lines, statusCount: 45, recentSubjects: [])
    XCTAssertEqual(snapshot.status.count, GitSnapshot.statusLineCap)
    XCTAssertEqual(snapshot.statusCount, 45)

    let block = render(git: snapshot)
    XCTAssertTrue(block.contains("- Git status (45 entries):"))
    XCTAssertTrue(block.contains("  ?? file-20.txt\n  (25 more)"))
    XCTAssertFalse(block.contains("file-21.txt"))
    XCTAssertFalse(block.contains("Recent commits"), "an unborn repository has no commits to list")

    // Repository text is data: control characters can't reach the prompt, lines are clipped.
    let hostile = GitSnapshot(
      branch: "feat/\u{1b}[31mred\u{07}",
      status: ["?? " + String(repeating: "x", count: 500)],
      recentSubjects: ["ok"])
    let scrubbed = render(git: hostile)
    XCTAssertTrue(scrubbed.contains("- Git branch: feat/[31mred\n"))
    XCTAssertFalse(scrubbed.contains("\u{1b}"))
    let longest = scrubbed.split(separator: "\n").map(\.count).max() ?? 0
    XCTAssertLessThanOrEqual(longest, GitSnapshot.lineWidthCap + 2)
    XCTAssertTrue(scrubbed.contains("…"))
  }

  func testTodayAndPlatformAreStableStrings() {
    XCTAssertEqual(
      EnvironmentContext.today(Date(timeIntervalSince1970: 0), timeZone: TimeZone(identifier: "UTC")!),
      "1970-01-01")
    XCTAssertEqual(
      EnvironmentContext.today(Date(timeIntervalSince1970: 86_400 * 365), timeZone: TimeZone(identifier: "UTC")!),
      "1971-01-01")
    let platform = EnvironmentContext.platform()
    XCTAssertFalse(platform.isEmpty)
    XCTAssertFalse(platform.contains("\n"))
    XCTAssertEqual(platform, EnvironmentContext.platform(), "captured facts don't drift")
    #if os(macOS)
    XCTAssertTrue(platform.hasPrefix("macOS "), platform)
    XCTAssertTrue(platform.contains("Darwin"), platform)
    #endif
  }

  // MARK: GitSnapshot

  func testParseReadsTaggedProbeOutputAndIgnoresLookalikes() throws {
    let output = """
      branch main
      status  M a.swift
      status ?? count 99
      count 2
      commit status fake
      commit branch fake

      """
    let snapshot = try XCTUnwrap(GitSnapshot.parse(output))
    XCTAssertEqual(snapshot.branch, "main")
    XCTAssertEqual(snapshot.status, [" M a.swift", "?? count 99"])
    XCTAssertEqual(snapshot.statusCount, 2)
    XCTAssertEqual(snapshot.recentSubjects, ["status fake", "branch fake"])
    XCTAssertNil(GitSnapshot.parse(""), "no branch line → nothing usable")
    XCTAssertNil(GitSnapshot.parse("fatal: not a git repository"))
  }

  func testCaptureReturnsNilOutsideARepository() async throws {
    let root = try tempDirectory("nogit")
    defer { try? FileManager.default.removeItem(at: root) }
    let snapshot = await GitSnapshot.capture(root: root)
    XCTAssertNil(snapshot)
    // And the block for it has no git lines.
    let block = await EnvironmentContext.block(
      cwd: root, facts: EnvironmentContext.Facts(os: "T", date: "2026-01-02"),
      model: "m", permissionMode: .default, effort: nil)
    XCTAssertFalse(block.contains("Git"))
    XCTAssertTrue(block.contains("- Working directory: \(root.path)"))
  }

  func testCaptureReadsBranchStatusAndSubjectsFromATempRepository() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = try tempDirectory("git")
    defer { try? FileManager.default.removeItem(at: root) }
    try git(["init", "-q"], in: root)
    // Force the branch name regardless of the host's init.defaultBranch.
    try git(["symbolic-ref", "HEAD", "refs/heads/main"], in: root)
    for index in 0..<25 {
      try "v1\n".write(to: root.appendingPathComponent("f\(String(format: "%02d", index)).txt"), atomically: true, encoding: .utf8)
    }
    try git(["add", "."], in: root)
    try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "initial commit"], in: root)
    try "second\n".write(to: root.appendingPathComponent("f00.txt"), atomically: true, encoding: .utf8)
    try git(["add", "."], in: root)
    try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "second: tweak f00"], in: root)
    // Tracked modifications, so the count doesn't depend on untracked-file handling.
    for index in 0..<25 {
      try "v3\n".write(to: root.appendingPathComponent("f\(String(format: "%02d", index)).txt"), atomically: true, encoding: .utf8)
    }

    let captured = await capture(root)
    let snapshot = try XCTUnwrap(captured)
    XCTAssertEqual(snapshot.branch, "main")
    XCTAssertEqual(snapshot.recentSubjects, ["second: tweak f00", "initial commit"])
    XCTAssertEqual(snapshot.statusCount, 25)
    XCTAssertEqual(snapshot.status.count, GitSnapshot.statusLineCap, "25 changes, 20 shown")
    XCTAssertTrue(snapshot.status.allSatisfy { $0.hasPrefix(" M f") }, "\(snapshot.status)")

    let block = await EnvironmentContext.block(
      cwd: root, facts: EnvironmentContext.Facts(os: "T", date: "2026-01-02"),
      model: "m", permissionMode: .default, effort: nil)
    XCTAssertTrue(block.contains("- Git branch: main"))
    XCTAssertTrue(block.contains("- Git status (25 entries):"))
    XCTAssertTrue(block.contains("  (5 more)"))
    XCTAssertTrue(block.contains("- Recent commits (newest first):\n  second: tweak f00\n  initial commit"))
    // Two captures of an unchanged tree render the same bytes.
    let again = await EnvironmentContext.block(
      cwd: root, facts: EnvironmentContext.Facts(os: "T", date: "2026-01-02"),
      model: "m", permissionMode: .default, effort: nil)
    XCTAssertEqual(block, again)

    // A detached HEAD is named by its commit rather than dropped.
    try git(["checkout", "-q", "--detach"], in: root)
    let detached = await capture(root)
    XCTAssertTrue(try XCTUnwrap(detached).branch.hasPrefix("HEAD (detached at "), "\(String(describing: detached))")
  }

  func testCaptureGivesUpOnASlowProbeInsteadOfThrowing() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    // A real repository, so a nil can only mean the watchdog: the same root answers normally.
    let root = try makeRepository("slow")
    defer { try? FileManager.default.removeItem(at: root) }
    let control = await capture(root)
    XCTAssertNotNil(control, "the repository is readable — the control capture works")

    // `git` shadowed on PATH by a script that outlives the budget: the probe is killed and
    // that is a nil, not an error and not a partial block.
    let shims = try tempDirectory("shims")
    defer { try? FileManager.default.removeItem(at: shims) }
    try writeScript("/bin/sleep 3", to: shims.appendingPathComponent("git"))
    let started = Date()
    let snapshot = await capture(root, timeoutSeconds: 1, environment: ["PATH": shims.path])
    XCTAssertNil(snapshot)
    XCTAssertLessThan(Date().timeIntervalSince(started), 2.5, "the budget, not the shim's sleep, ended the probe")
  }

  // MARK: The probe is a shell in an untrusted directory

  func testCaptureNeutralizesCommandsTheRepositoryConfigures() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    // `.git/config` is the repository's, not the user's: a tarball can arrive with
    // `core.fsmonitor` naming a script, which every `git status` would then run.
    let root = try makeRepository("fsmon")
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("MARKER")
    let hook = root.appendingPathComponent("evil.sh")
    try writeScript("touch '\(marker.path)'\nprintf '/'", to: hook)
    try git(["config", "core.fsmonitor", hook.path], in: root)

    // Control: with the neutralization switched off, this git does run the hook — otherwise
    // the assertion below would prove nothing on this host.
    _ = await capture(root, environment: ["GIT_CONFIG_COUNT": "0"])
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: marker.path),
      "this git doesn't run core.fsmonitor hooks — nothing to neutralize")
    try FileManager.default.removeItem(at: marker)

    let neutralized = await capture(root)
    let snapshot = try XCTUnwrap(neutralized)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the repository's fsmonitor command must not run")
    XCTAssertEqual(snapshot.branch, "main", "and the probe still answers")
    XCTAssertEqual(snapshot.recentSubjects, ["initial commit"])

    // Both command-running keys are pinned off, through git's environment config so that a
    // git the probe's git spawns (a submodule's status) inherits them too.
    let env = GitSnapshot.probeEnvironment
    XCTAssertEqual(env["GIT_CONFIG_COUNT"], "2")
    XCTAssertEqual(env["GIT_CONFIG_KEY_0"], "core.fsmonitor")
    XCTAssertEqual(env["GIT_CONFIG_VALUE_0"], "false")
    XCTAssertEqual(env["GIT_CONFIG_KEY_1"], "log.showSignature")
    XCTAssertEqual(env["GIT_CONFIG_VALUE_1"], "false")
    XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
  }

  func testCaptureRunsInsideTheRunsSandbox() async throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = try makeRepository("sbx")
    defer { try? FileManager.default.removeItem(at: root) }
    // The run's confinement: writes only under the project (and the temp dirs, which is why
    // the escape marker below goes under $HOME, as in ShellSandboxTests).
    let sandbox = ShellSandbox(writableRoots: [root], allowNetwork: true)

    // The probe works confined (it writes nothing), so the block keeps its git lines...
    let block = await EnvironmentContext.block(
      cwd: root, facts: EnvironmentContext.Facts(os: "T", date: "2026-01-02", sandbox: sandbox),
      model: "m", permissionMode: .default, effort: nil)
    XCTAssertTrue(block.contains("- Git branch: main"), block)
    XCTAssertTrue(block.contains("- Recent commits (newest first):\n  initial commit"), block)
    XCTAssertTrue(block.contains("- Sandbox: on (writes confined to the working tree)"), block)

    // ...and a command the repository smuggles past the config neutralization (switched off
    // here on purpose) runs inside the same boundary as the run's own bash: its write outside
    // the project is refused by the kernel, and the probe still answers.
    let marker = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".arnes_env_probe_escape_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: marker) }
    let hook = root.appendingPathComponent("evil.sh")
    try writeScript("touch '\(marker.path)'\nprintf '/'", to: hook)
    try git(["config", "core.fsmonitor", hook.path], in: root)
    // Control: unconfined, the hook does reach $HOME — so what follows is the kernel's doing.
    _ = await capture(root, sandbox: nil, environment: ["GIT_CONFIG_COUNT": "0"])
    try XCTSkipUnless(
      FileManager.default.fileExists(atPath: marker.path),
      "this git doesn't run core.fsmonitor hooks — nothing to confine")
    try FileManager.default.removeItem(at: marker)

    let snapshot = await capture(root, sandbox: sandbox, environment: ["GIT_CONFIG_COUNT": "0"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the sandbox confines the probe's children too")
    XCTAssertEqual(snapshot?.branch, "main")
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  func testCaptureIgnoresAnInheritedGitDir() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    // Started from a git hook, the process inherits GIT_DIR/GIT_WORK_TREE naming *that*
    // repository; the probe is about `cwd` and must say so.
    let root = try makeRepository("cwd")
    defer { try? FileManager.default.removeItem(at: root) }
    let other = try makeRepository("other")
    defer { try? FileManager.default.removeItem(at: other) }
    try git(["checkout", "-q", "-b", "elsewhere"], in: other)

    let captured = await capture(root, environment: [
      "GIT_DIR": other.appendingPathComponent(".git").path,
      "GIT_WORK_TREE": other.path,
    ])
    let snapshot = try XCTUnwrap(captured)
    XCTAssertEqual(snapshot.branch, "main", "cwd's branch, not the inherited repository's")
  }

  // MARK: Session placement

  func testSessionRendersTheBlockAfterInstructionsAndBeforeToolSections() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)]]
    let block = render(git: nil, model: "test/model")
    let task = TaskTool(agents: [.general], service: mock, tools: [], store: tempStore())
    let session = Session(
      service: mock,
      tools: [task],
      store: tempStore(),
      configuration: .init(
        model: "test/model",
        projectInstructions: "# Project rules\nAlways do X.",
        extraSystemSections: [block]))
    for try await _ in await session.send("hi") {}

    let system = try systemPrompt(of: try XCTUnwrap(mock.requests.first))
    XCTAssertTrue(system.contains(block), "the block rides the system prompt verbatim")
    let instructions = try XCTUnwrap(system.range(of: "# Project rules"))
    let environment = try XCTUnwrap(system.range(of: "# Environment"))
    let subagents = try XCTUnwrap(system.range(of: "# Subagents"))
    XCTAssertLessThan(instructions.lowerBound, environment.lowerBound)
    XCTAssertLessThan(environment.lowerBound, subagents.lowerBound)
  }

  // MARK: Subagents

  func testSubagentBlockUsesTheAgentsRootModelAndPosture() async throws {
    let root = try tempDirectory("sub")
    defer { try? FileManager.default.removeItem(at: root) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("done", model: "sub/model"), Fixtures.usageChunk(cost: 0.001, model: "sub/model")],
      [Fixtures.textChunk("done", model: "sub/model"), Fixtures.usageChunk(cost: 0.001, model: "sub/model")],
    ]
    let writer = AgentDefinition(name: "writer", description: "writes", body: "Write.", model: "sub/model")
    let reader = AgentDefinition(
      name: "reader", description: "reads", body: "Read.", model: "sub/model",
      permissionMode: .readOnly)
    let parent = Session.Configuration(
      model: "lead/model",
      extraSystemSections: ["# Environment\n- Model: lead/model\n- Working directory: /lead"],
      reasoningEffort: .low,
      workingDirectory: root,
      permissionMode: .bypass)
    let tool = TaskTool(
      agents: [writer, reader],
      service: mock,
      tools: [ReadFileTool()],
      store: tempStore(),
      environmentContext: EnvironmentContext.Facts(os: "TestOS 1.0", date: "2026-01-02"),
      configuration: parent)
    tool.parentModel = { "lead/model" }

    _ = try await tool.execute(arguments: ["agent": .string("writer"), "task": .string("go")])
    let system = try systemPrompt(of: try XCTUnwrap(mock.requests.first))
    XCTAssertTrue(system.contains("# Environment"))
    XCTAssertTrue(system.contains("- Working directory: \(root.path)"), "the subagent's root, not the lead's")
    XCTAssertFalse(system.contains("/lead"), "the lead's block is not inherited")
    XCTAssertTrue(system.contains("- Model: sub/model"), "the resolved model, not the lead's")
    XCTAssertFalse(system.contains("lead/model"))
    XCTAssertTrue(system.contains("- Platform: TestOS 1.0"), "the lead's facts, captured once")
    XCTAssertTrue(system.contains("- Date: 2026-01-02"))
    XCTAssertTrue(system.contains("- Permission mode: bypass"), "inherited mode for a writer")
    XCTAssertTrue(system.contains("- Reasoning effort: low"), "inherited effort")
    XCTAssertTrue(system.contains("- Sandbox: off"))
    // Its own section order: environment before the role suffix.
    let environment = try XCTUnwrap(system.range(of: "# Environment"))
    let role = try XCTUnwrap(system.range(of: "# Subagent role"))
    XCTAssertLessThan(environment.lowerBound, role.lowerBound)

    _ = try await tool.execute(arguments: ["agent": .string("reader"), "task": .string("look")])
    let readOnly = try systemPrompt(of: try XCTUnwrap(mock.requests.last))
    XCTAssertTrue(readOnly.contains("- Permission mode: read-only"), "a read-only agent's posture, not the parent's bypass")
  }

  func testSubagentsGetNoBlockWithoutFacts() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")]]
    let agent = AgentDefinition(name: "helper", description: "helps", body: "Help.", model: "sub/model")
    let tool = TaskTool(
      agents: [agent], service: mock, tools: [], store: tempStore(),
      configuration: Session.Configuration(
        model: "lead/model",
        extraSystemSections: ["# Environment\n- Model: lead/model"]))
    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("go")])
    let system = try systemPrompt(of: try XCTUnwrap(mock.requests.first))
    XCTAssertFalse(system.contains("# Environment"), "policy off (nil facts) → no block, and never the lead's")
  }

  // MARK: Eval trials

  func testEvalTrialGetsItsOwnBlockOnlyWhenEnabled() async throws {
    for enabled in [true, false] {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
      mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)]]
      let base = FileManager.default.temporaryDirectory
      let runner = EvalRunner(
        service: mock,
        store: EvalStore(url: base.appendingPathComponent("arnes-env-evals-\(UUID().uuidString).jsonl")),
        recordStore: tempStore(),
        environmentContext: enabled)
      let suite = EvalSuite(name: "unit", tasks: [EvalTask(id: "noop", prompt: "say done", check: "true")])
      let outcomes = await runner.run(suite: suite, models: ["test/model"])
      XCTAssertEqual(outcomes.count, 1)
      XCTAssertTrue(outcomes[0].checkPassed)

      let system = try systemPrompt(of: try XCTUnwrap(mock.requests.first))
      if enabled {
        XCTAssertTrue(system.contains("# Environment"))
        XCTAssertTrue(system.contains("- Working directory: "))
        XCTAssertTrue(system.contains("arnes-eval-"), "the trial's own temp root")
        XCTAssertTrue(system.contains("- Model: test/model"))
        XCTAssertTrue(system.contains("- Sandbox: off"))
      } else {
        XCTAssertFalse(system.contains("# Environment"))
      }
    }
  }

  // MARK: Config

  func testPoliciesConfigDecodesWhenAbsentAndOptsOut() throws {
    let absent = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"provider":"openrouter"}"#.utf8))
    XCTAssertNil(absent.policies)
    XCTAssertTrue(EnvironmentContext.isEnabled(in: absent))
    XCTAssertTrue(EnvironmentContext.isEnabled(in: nil), "no config file at all → on")

    let empty = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies":{}}"#.utf8))
    XCTAssertEqual(empty.policies, PoliciesConfig())
    XCTAssertTrue(EnvironmentContext.isEnabled(in: empty))

    let off = try JSONDecoder().decode(
      ArnesConfig.self, from: Data(#"{"policies":{"environmentContext":false}}"#.utf8))
    XCTAssertEqual(off.policies?.environmentContext, false)
    XCTAssertFalse(EnvironmentContext.isEnabled(in: off))

    let on = try JSONDecoder().decode(
      ArnesConfig.self, from: Data(#"{"policies":{"environmentContext":true}}"#.utf8))
    XCTAssertTrue(EnvironmentContext.isEnabled(in: on))

    // Round-trips, and the umbrella is part of equality.
    let encoded = try JSONEncoder().encode(ArnesConfig(policies: PoliciesConfig(environmentContext: false)))
    XCTAssertEqual(try JSONDecoder().decode(ArnesConfig.self, from: encoded), off)
  }

  // MARK: Helpers

  /// The host's own git configuration kept out of every test git (and, layered onto the
  /// probe, out of every capture): a `commit.gpgsign`, `status.relativePaths=false` or
  /// fsmonitor daemon in `~/.gitconfig` must not decide these tests.
  private static let hermeticGit = ["GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"]

  private func capture(
    _ root: URL,
    sandbox: ShellSandbox? = nil,
    timeoutSeconds: Int = GitSnapshot.timeoutSeconds,
    environment: [String: String] = [:])
    async -> GitSnapshot?
  {
    await GitSnapshot.capture(
      root: root, sandbox: sandbox, timeoutSeconds: timeoutSeconds,
      extraEnvironment: Self.hermeticGit.merging(environment) { _, override in override })
  }

  private func git(_ arguments: [String], in root: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.environment = ProcessInfo.processInfo.environment.merging(Self.hermeticGit) { _, pinned in pinned }
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
  }

  /// A repository on `main` with one commit of `README.md`.
  private func makeRepository(_ label: String) throws -> URL {
    let root = try tempDirectory(label)
    try git(["init", "-q"], in: root)
    try git(["symbolic-ref", "HEAD", "refs/heads/main"], in: root)
    try "hello\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "."], in: root)
    try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "initial commit"], in: root)
    return root
  }

  /// An executable `sh` script at `url`.
  private func writeScript(_ body: String, to url: URL) throws {
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }
}
