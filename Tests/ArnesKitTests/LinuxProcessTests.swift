#if os(Linux)
import Glibc
import XCTest
@testable import ArnesKit

final class LinuxProcessTests: XCTestCase {
  func testBlockingRunReturnsTheShellStatusWhileItsChildKeepsThePipe() throws {
    let start = Date()
    let outcome = ShellRunner.runBlocking("sleep 30 & echo $!; exit 23", cwd: nil, timeoutSeconds: 5)
    let child = try XCTUnwrap(Int32(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines)))
    defer { _ = kill(child, SIGKILL) }
    XCTAssertEqual(outcome.exitStatus, 23)
    XCTAssertFalse(outcome.timedOut)
    XCTAssertLessThan(Date().timeIntervalSince(start), 3)
  }

  func testConcurrentCommandsKeepTheirOwnOutputAndExitStatus() async {
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<32 {
        group.addTask {
          let outcome = await ShellRunner.run("printf 'child-\(index)'; exit \(index)",
            cwd: nil, timeoutSeconds: 5, shell: .sh)
          XCTAssertEqual(outcome.exitStatus, Int32(index))
          XCTAssertEqual(outcome.output, "child-\(index)")
          XCTAssertFalse(outcome.timedOut)
        }
      }
    }
  }

  func testExitNotificationMeansTheDirectChildWasReaped() async throws {
    let launch = try ShellRunner.Launch(command: "exit 7", cwd: nil, shell: .sh)
    await launch.exit.wait()
    XCTAssertEqual(launch.finish().exitStatus, 7)
    var status: Int32 = 0
    XCTAssertEqual(waitpid(launch.box.pid, &status, WNOHANG), -1)
    XCTAssertEqual(errno, ECHILD, "ShellRunner must reap its own child exactly once")
  }

  func testMissingWorkingDirectoryFailsToStartAndTheNextCommandStillRuns() async {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let failure = await ShellRunner.run("echo should-not-run", cwd: missing, timeoutSeconds: 5)
    XCTAssertTrue(failure.failedToStart)
    XCTAssertEqual(failure.exitStatus, 127)
    XCTAssertFalse(failure.timedOut)
    let next = await ShellRunner.run("printf recovered", cwd: nil, timeoutSeconds: 5, shell: .sh)
    XCTAssertEqual(next.output, "recovered")
    XCTAssertEqual(next.exitStatus, 0)
  }

  func testNulArgumentsAndMalformedEnvironmentFailBeforeExecution() async {
    let command = await ShellRunner.run("printf truncated\0ignored", cwd: nil,
      timeoutSeconds: 5, shell: .sh)
    XCTAssertTrue(command.failedToStart)
    for environment in [["BAD=KEY": "value"], ["VALID_KEY": "truncated\0ignored"]] {
      let outcome = await ShellRunner.run("printf should-not-run", cwd: nil,
        timeoutSeconds: 5, extraEnvironment: environment, shell: .sh)
      XCTAssertTrue(outcome.failedToStart)
      XCTAssertEqual(outcome.exitStatus, 127)
    }
  }

  func testUnrelatedDescriptorWithoutCloseOnExecIsNotInherited() async throws {
    let fd = open("/dev/null", O_RDONLY)
    XCTAssertGreaterThanOrEqual(fd, 0)
    guard fd >= 0 else { return }
    defer { _ = close(fd) }
    // A high descriptor avoids the standard descriptors and shell's script bookkeeping.
    let inherited = fcntl(fd, F_DUPFD, 200)
    XCTAssertGreaterThanOrEqual(inherited, 200)
    guard inherited >= 200 else { return }
    defer { _ = close(inherited) }
    XCTAssertEqual(fcntl(inherited, F_GETFD) & FD_CLOEXEC, 0)
    let outcome = await ShellRunner.run("test ! -e /proc/self/fd/\(inherited)",
      cwd: nil, timeoutSeconds: 5, shell: .sh)
    XCTAssertEqual(outcome.exitStatus, 0, "only the configured stdin/stdout/stderr may be inherited")
  }

  func testChildSignalsHaveDefaultDispositions() async {
    // Swift's runtime and the stdin writer can ignore signals in the parent. A tool
    // must still terminate normally on TERM/PIPE, without waiting for its watchdog.
    for signal in [SIGTERM, SIGPIPE] {
      let outcome = await ShellRunner.run("kill -\(signal) $$; echo survived",
        cwd: nil, timeoutSeconds: 3, shell: .sh)
      XCTAssertEqual(outcome.exitStatus, signal)
      XCTAssertEqual(outcome.output, "")
      XCTAssertFalse(outcome.timedOut)
    }
  }

  func testConcurrentWorkingDirectoriesDoNotChangeTheParentDirectory() async throws {
    let parent = FileManager.default.currentDirectoryPath
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<8 {
      try FileManager.default.createDirectory(at: root.appendingPathComponent("\(index)"),
        withIntermediateDirectories: true)
    }
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<8 {
        group.addTask {
          let cwd = root.appendingPathComponent("\(index)")
          let outcome = await ShellRunner.run("pwd", cwd: cwd, timeoutSeconds: 5, shell: .sh)
          XCTAssertEqual(outcome.output.trimmingCharacters(in: .whitespacesAndNewlines), cwd.path)
          XCTAssertEqual(outcome.exitStatus, 0)
        }
      }
    }
    XCTAssertEqual(FileManager.default.currentDirectoryPath, parent)
  }
}
#endif
