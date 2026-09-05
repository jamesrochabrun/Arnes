import XCTest
@testable import ArnesKit

final class ShellRunnerTests: XCTestCase {
  func testReturnsWhenBashExitsEvenIfAGrandchildKeepsThePipe() async {
    // `sleep 30 &` inherits stdout/stderr and outlives bash; the old reader waited for it.
    let started = Date()
    let outcome = await ShellRunner.run("echo before; sleep 30 >/dev/null 2>&1 & echo after", cwd: nil, timeoutSeconds: 20)
    XCTAssertEqual(outcome.exitStatus, 0)
    XCTAssertTrue(outcome.output.contains("before"))
    XCTAssertTrue(outcome.output.contains("after"))
    XCTAssertFalse(outcome.timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(started), 5, "did not wait for the background child")
  }

  func testBackgroundChildHoldingThePipeItselfDoesNotBlock() async {
    let started = Date()
    // No redirection: the sleeping child holds the very pipe we read from.
    let outcome = await ShellRunner.run("sleep 30 & echo done", cwd: nil, timeoutSeconds: 20)
    XCTAssertTrue(outcome.output.contains("done"))
    XCTAssertLessThan(Date().timeIntervalSince(started), 5)
  }

  func testTimeoutKillsTheCommand() async {
    let started = Date()
    let outcome = await ShellRunner.run("echo start; sleep 30; echo never", cwd: nil, timeoutSeconds: 1)
    XCTAssertTrue(outcome.timedOut)
    XCTAssertTrue(outcome.output.contains("start"))
    XCTAssertFalse(outcome.output.contains("never"))
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testCancellationKillsTheCommand() async {
    let started = Date()
    let task = Task { await ShellRunner.run("sleep 30; echo never", cwd: nil, timeoutSeconds: 60) }
    try? await Task.sleep(nanoseconds: 200_000_000)
    task.cancel()
    let outcome = await task.value
    XCTAssertTrue(outcome.cancelled)
    XCTAssertFalse(outcome.output.contains("never"))
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
  }

  func testStdinIsClosedSoReadsFailFast() async {
    let outcome = await ShellRunner.run("read -r line && echo got || echo eof", cwd: nil, timeoutSeconds: 5)
    XCTAssertTrue(outcome.output.contains("eof"))
  }

  /// The kill is a process-tree kill: a timed-out shell's children — the background `sleep`
  /// and the foreground one — die with it instead of surviving as orphans.
  func testTimeoutKillsGrandchildren() async throws {
    let pids = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-tree-\(UUID().uuidString).pids")
    defer { try? FileManager.default.removeItem(at: pids) }
    let command = "sleep 30 & echo $! > '\(pids.path)'; sleep 30 & echo $! >> '\(pids.path)'; wait"
    let started = Date()
    let outcome = await ShellRunner.run(command, cwd: nil, timeoutSeconds: 1)
    XCTAssertTrue(outcome.timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    let recorded = try String(contentsOf: pids, encoding: .utf8)
      .split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }
    XCTAssertEqual(recorded.count, 2, "both children wrote their pid")
    // SIGTERM delivery is asynchronous: give the children a moment to die, then they must be
    // gone (a zombie is reaped by nobody here, so `kill(pid, 0)` failing with ESRCH is the proof
    // — a live `sleep` would answer 0 for the whole 30 seconds).
    for pid in recorded {
      var alive = true
      for _ in 0..<40 where alive {
        alive = kill(pid, 0) == 0 && !Self.isZombie(pid)
        if alive { try? await Task.sleep(nanoseconds: 50_000_000) }
      }
      XCTAssertFalse(alive, "sleep \(pid) survived the timeout kill")
    }
  }

  /// `ps -o stat=` for the pid: a killed-but-unreaped child shows as `Z`; `kill(pid, 0)` alone
  /// can't tell it from a running one.
  static func isZombie(_ pid: pid_t) -> Bool {
    let outcome = ShellRunner.runBlocking("ps -o stat= -p \(pid)", cwd: nil, timeoutSeconds: 5)
    return outcome.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z")
  }

  /// `timeout_seconds` on a call overrides the tool's default, clamped to `1...maxTimeoutSeconds`;
  /// the tool's own default is clamped the same way.
  func testPerCallTimeoutIsClamped() async throws {
    XCTAssertEqual(BashTool.clampedTimeout(0), 1)
    XCTAssertEqual(BashTool.clampedTimeout(-5), 1)
    XCTAssertEqual(BashTool.clampedTimeout(45), 45)
    XCTAssertEqual(BashTool.clampedTimeout(10_000), BashTool.maxTimeoutSeconds)
    let tool = BashTool(timeoutSeconds: 60)
    XCTAssertEqual(tool.timeout(for: ["command": "ls"]), 60)
    XCTAssertEqual(tool.timeout(for: ["command": "ls", "timeout_seconds": 5]), 5)
    XCTAssertEqual(tool.timeout(for: ["command": "ls", "timeout_seconds": 0]), 1)
    XCTAssertEqual(tool.timeout(for: ["command": "ls", "timeout_seconds": 99_999]), BashTool.maxTimeoutSeconds)
    XCTAssertEqual(BashTool(timeoutSeconds: 5_000).timeout(for: ["command": "ls"]), BashTool.maxTimeoutSeconds)
    // And it is honored: a call asking for one second is killed after one second, naming it.
    let started = Date()
    let result = try await BashTool(timeoutSeconds: 60).execute(
      arguments: ["command": .string("sleep 20"), "timeout_seconds": 1])
    XCTAssertTrue(result.hasPrefix("error: command timed out after 1s"), result)
    XCTAssertTrue(result.contains("raise timeout_seconds (up to 600)"), result)
    XCTAssertFalse(result.contains("background: true"), "no registry — the background form is not offered: \(result)")
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    // With a registry the timeout error points at the background form.
    let registry = JobRegistry(logRoot: URL(fileURLWithPath: NSTemporaryDirectory()))
    let backed = try await BashTool(timeoutSeconds: 60, jobs: registry).execute(
      arguments: ["command": .string("sleep 20"), "timeout_seconds": 1])
    XCTAssertTrue(backed.contains("or run it with background: true"), backed)
    await registry.killAll()
  }

  func testBlockingVariantAndBashToolAgree() async throws {
    let blocking = ShellRunner.runBlocking("echo hi; exit 3", cwd: nil, timeoutSeconds: 5)
    XCTAssertEqual(blocking.exitStatus, 3)
    XCTAssertTrue(blocking.output.contains("hi"))

    let tool = BashTool(timeoutSeconds: 1)
    let result = try await tool.execute(arguments: ["command": .string("sleep 5")])
    XCTAssertTrue(result.hasPrefix("error: command timed out after 1s"))
    let quick = try await tool.execute(arguments: ["command": .string("echo ok")])
    XCTAssertEqual(quick, "exit 0\nok\n")
  }
}
