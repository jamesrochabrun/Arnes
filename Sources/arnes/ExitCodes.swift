import ArnesKit
import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - ArnesExit

/// The exit-code contract of `arnes do` — a script's view of `RunResult.stopReason`.
///
/// | code | meaning |
/// |------|---------|
/// | 0 | `completed` or `plan_proposed` |
/// | 1 | `error` (transport/provider failure, or nothing ran) |
/// | 2 | the run completed but `--verify` said FAIL |
/// | 3 | stopped short: `max_steps`, `budget`, `timeout`, `structured_output_failed`, `stuck`, `denied_loop`, `truncated`, `hook_stopped` |
/// | 4 | `--fail-on-denied` and at least one tool call was refused |
/// | 64 | usage error (ArgumentParser's `EX_USAGE` — a bad flag, a missing task) |
/// | 130 | `interrupted` by SIGINT (Ctrl-C) or `Agent.interrupt` |
/// | 143 | `interrupted` by SIGTERM |
///
/// Precedence, when several apply: an error or an interrupt wins over everything (the run
/// did not get to decide); then `--fail-on-denied` (the most actionable signal — widen the
/// permissions — so it outranks a verifier FAIL or a step limit the denials caused); then a
/// verifier FAIL; then a stopped-short reason; then 0.
enum ArnesExit: Int32 {
  case ok = 0
  case error = 1
  case verifierFailed = 2
  case stopped = 3
  case denied = 4
  case usage = 64
  case interrupted = 130
  case terminated = 143

  /// Which signal ended a run, when one did — decides 130 vs 143.
  enum Signal: Sendable {
    case sigint
    case sigterm

    /// The exit code a run ended by this signal reports.
    var exitCode: Int32 {
      switch self {
      case .sigint: return ArnesExit.interrupted.rawValue
      case .sigterm: return ArnesExit.terminated.rawValue
      }
    }
  }

  /// Ends the process right now with `code` — for a repeated signal, when the graceful
  /// interrupt is evidently not coming back. Named so it can't be confused with
  /// ArgumentParser's `exit(withError:)` inside a command.
  static func terminateProcess(_ code: Int32) -> Never {
    #if canImport(Glibc)
    Glibc.exit(code)
    #else
    Darwin.exit(code)
    #endif
  }

  /// The exit code for a finished run. Table-driven over `StopReason`, exhaustively, so a
  /// new reason is a compile error here until it has a code.
  static func code(for result: RunResult, failOnDenied: Bool, signal: Signal? = nil) -> Int32 {
    guard let reason = result.stopReason, !result.isError else {
      return ArnesExit.error.rawValue
    }
    switch reason {
    case .error:
      return ArnesExit.error.rawValue
    case .interrupted:
      return (signal ?? .sigint).exitCode
    case .completed, .planProposed, .maxSteps, .budget, .timeout, .structuredOutputFailed,
         .stuck, .deniedLoop, .truncated, .hookStopped:
      break
    }
    if failOnDenied, result.deniedCalls > 0 {
      return ArnesExit.denied.rawValue
    }
    if result.verifierPassed == false {
      return ArnesExit.verifierFailed.rawValue
    }
    switch reason {
    case .completed, .planProposed:
      return ArnesExit.ok.rawValue
    case .maxSteps, .budget, .timeout, .structuredOutputFailed, .stuck, .deniedLoop, .truncated,
         .hookStopped:
      return ArnesExit.stopped.rawValue
    case .error, .interrupted:
      // Handled above; listed so the switch stays exhaustive without a default.
      return ArnesExit.error.rawValue
    }
  }
}

// MARK: - SignalState

/// Which signal a headless run received, if any — written from the signal sources' queue,
/// read on the main task after the run. The first signal interrupts; a second one is the
/// user insisting, and `note` says so.
final class SignalState: @unchecked Sendable {
  private let lock = NSLock()
  private var signal: ArnesExit.Signal?

  /// Records `received`; returns `true` when a signal had *already* been noted (the caller
  /// treats a repeat as "stop now").
  func note(_ received: ArnesExit.Signal) -> Bool {
    lock.withLock {
      let again = signal != nil
      if signal == nil { signal = received }
      return again
    }
  }

  var received: ArnesExit.Signal? {
    lock.withLock { signal }
  }
}

/// A set-once flag readable from another task (the deadline fired).
final class OnceFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() {
    lock.withLock { value = true }
  }

  var isSet: Bool {
    lock.withLock { value }
  }
}
