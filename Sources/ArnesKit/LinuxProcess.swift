#if os(Linux)
import CArnesProcess
import Foundation
import Glibc

/// A direct child owned by ShellRunner. Foundation's Linux Process waits for an
/// inherited supervision socket to close; a detached descendant can retain it.
/// Here only waitpid for this exact child determines completion. The shared queue
/// polls without blocking Swift's cooperative executor or installing a SIGCHLD handler.
final class LinuxProcess: ShellProcess, @unchecked Sendable {
  private static let queue = DispatchQueue(label: "arnes.process-exits")
  private let lock = NSLock()
  let processIdentifier: Int32
  private var running = true
  private var status: Int32 = -1
  private var reason = Process.TerminationReason.exit
  private var monitor: DispatchSourceTimer?

  var isRunning: Bool { lock.withLock { running } }
  var terminationStatus: Int32 { lock.withLock { status } }
  var terminationReason: Process.TerminationReason { lock.withLock { reason } }

  init(executable: String, arguments: [String], cwd: URL?, environment: [String: String],
    input: Int32, output: Int32, error: Int32, onExit: @escaping @Sendable () -> Void) throws
  {
    // Reject embedded NULs rather than executing a silently truncated invocation.
    let argv = [executable] + arguments
    let env = environment.map { "\($0.key)=\($0.value)" }
    guard !(argv + env + [cwd?.path ?? ""]).contains(where: { $0.utf8.contains(0) }),
          !environment.keys.contains(where: { $0.isEmpty || $0.contains("=") })
    else { throw POSIXError(.EINVAL) }
    let args = argv.map { strdup($0) } + [nil]
    let variables = env.map { strdup($0) } + [nil]
    defer {
      args.forEach { free($0) }
      variables.forEach { free($0) }
    }
    guard args.dropLast().allSatisfy({ $0 != nil }), variables.dropLast().allSatisfy({ $0 != nil })
    else { throw POSIXError(.ENOMEM) }
    var pid: pid_t = 0
    let result = args.withUnsafeBufferPointer { args in
      variables.withUnsafeBufferPointer { variables in
        arnes_spawn(&pid, executable, args.baseAddress, variables.baseAddress,
          cwd?.path, input, output, error)
      }
    }
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    processIdentifier = pid
    let timer = DispatchSource.makeTimerSource(queue: Self.queue)
    monitor = timer
    // Retain the owner until its child is reaped, even if the caller drops its handle.
    timer.setEventHandler { [self] in
      let finished = lock.withLock {
        var signaled: Int32 = 0
        let result = arnes_poll_exit(processIdentifier, &status, &signaled)
        guard result != 0 else { return false }
        if result < 0 { status = -1 }
        reason = signaled == 0 ? .exit : .uncaughtSignal
        running = false
        monitor?.setEventHandler {}
        monitor?.cancel()
        monitor = nil
        return true
      }
      if finished { onExit() }
    }
    timer.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
    timer.resume()
  }

  /// Serialize signaling with reaping. Until waitpid runs, this child's pid cannot
  /// be recycled, so cancellation cannot signal an unrelated replacement process.
  func withRunningPID(_ body: (Int32) -> Void) {
    lock.withLock {
      if running { body(processIdentifier) }
    }
  }
}
#endif
