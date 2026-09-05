import XCTest

@testable import ArnesKit

/// `UserShell` — the runner behind the REPL's `!` escape: the bash tool's runner outside
/// every tool gate (the user typed the command), cancellation-aware, output bounded.
final class UserShellTests: XCTestCase {
  func testRunsTheCommandAndReportsExitStatusAndOutput() async {
    let outcome = await UserShell.run("printf hi; exit 3", cwd: nil, timeoutSeconds: 30)
    XCTAssertEqual(outcome.exitStatus, 3)
    XCTAssertTrue(outcome.output.contains("hi"))
    XCTAssertFalse(outcome.timedOut)
    XCTAssertFalse(outcome.cancelled)
    XCTAssertFalse(outcome.failedToStart)
  }

  func testRunsInTheGivenDirectory() async throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("user-shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let outcome = await UserShell.run("pwd", cwd: dir, timeoutSeconds: 30)
    XCTAssertEqual(outcome.exitStatus, 0)
    XCTAssertTrue(outcome.output.contains(dir.lastPathComponent))
  }

  func testCancellationKillsTheCommand() async {
    let task = Task { await UserShell.run("sleep 30", cwd: nil, timeoutSeconds: 60) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    let outcome = await task.value
    XCTAssertTrue(outcome.cancelled)
  }

  func testWithholdsTheProviderToken() async {
    // The output reaches the model and the transcript, so the user's own command gets the
    // same scrubbed environment the bash tool gets (`SubprocessEnvironment`).
    setenv("OPENROUTER_API_KEY", "sk-or-secret-for-user-shell-test", 1)
    defer { unsetenv("OPENROUTER_API_KEY") }
    let outcome = await UserShell.run(
      "echo token=[$OPENROUTER_API_KEY]", cwd: nil, timeoutSeconds: 30)
    XCTAssertTrue(outcome.output.contains("token=[]"))
    XCTAssertFalse(outcome.output.contains("sk-or-secret-for-user-shell-test"))
  }
}
