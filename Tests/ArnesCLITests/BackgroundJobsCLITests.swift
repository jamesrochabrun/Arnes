import XCTest
@testable import arnes
import ArnesKit

/// T2 in the CLI: the `/tasks` jobs half, the between-turns exit line, the `job` tool in the
/// runtime's toolset, and the `limits.bashTimeoutSeconds` default reaching `bash`.
final class BackgroundJobsCLITests: XCTestCase {
  func testJobsListingNamesEachJobWithStateElapsedAndCommand() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let log = URL(fileURLWithPath: "/tmp/arnes-jobs-abc/job-1.log")
    let running = JobRegistry.Job(
      id: 1, command: "npm run dev -- --port 3000", pid: 4242, logURL: log,
      startedAt: now.addingTimeInterval(-12))
    let exited = JobRegistry.Job(
      id: 2, command: "make -j8\nand more", pid: 4243, logURL: log,
      startedAt: now.addingTimeInterval(-90), exitStatus: 143, exitedAt: now.addingTimeInterval(-30), killed: true)
    let lines = Interactive.jobsListing([running, exited], now: now).split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 2)
    XCTAssertTrue(lines[0].contains("job 1"), lines[0])
    XCTAssertTrue(lines[0].contains("running"), lines[0])
    XCTAssertTrue(lines[0].contains("12.0s"), lines[0])
    XCTAssertTrue(lines[0].contains("npm run dev -- --port 3000"), lines[0])
    XCTAssertTrue(lines[1].contains("job 2"), lines[1])
    XCTAssertTrue(lines[1].contains("exited 143 (killed)"), lines[1])
    XCTAssertTrue(lines[1].contains("1m00s"), "elapsed stops at the exit: \(lines[1])")
    XCTAssertTrue(lines[1].contains("make -j8 and more"), "newlines folded: \(lines[1])")
    // A job that exited on its own while the user was at the prompt.
    var own = running
    own.exitStatus = 0
    let line = Interactive.jobFinishedLine(own)
    XCTAssertTrue(line.contains("⧗ job 1 exited 0"), line)
    XCTAssertTrue(line.contains(log.path), line)
    XCTAssertTrue(line.contains("told with your next message"), line)
  }

  func testRuntimeToolsetCarriesTheJobToolAndTheConfiguredTimeout() throws {
    let provider = try ProviderResolver.resolve(
      config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
    let runtime = ArnesRuntime(provider: provider, limits: LimitsConfig(bashTimeoutSeconds: 42))
    XCTAssertEqual(runtime.limits.effectiveBashTimeoutSeconds, 42)
    XCTAssertEqual(LimitsConfig.default.effectiveBashTimeoutSeconds, 300)
    // The `job` tool rides every CLI toolset built with a registry, right after bash.
    let tools = HarnessAssembly.coreTools(ToolContext(
      jobs: runtime.jobRegistry(), bashTimeoutSeconds: runtime.limits.effectiveBashTimeoutSeconds))
    XCTAssertEqual(
      tools.map(\.name),
      ["read_file", "write_file", "edit_file", "bash", "job", "grep", "glob", "view_image", "update_plan", "think", "ask_user"])
    // Each call to `jobRegistry()` is a run's own registry, never shared across runs.
    XCTAssertFalse(runtime.jobRegistry() === runtime.jobRegistry())
  }

  func testHandlesEventLinesForJobs() {
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .jobStarted(id: 3, command: String(repeating: "c", count: 100))),
      "⧗ job 3 started: " + String(repeating: "c", count: 80))
    XCTAssertEqual(HeadlessEmitter.textLine(for: .jobFinished(id: 3, exitStatus: 1)), "⧗ job 3 finished (exit 1)")
  }
}
