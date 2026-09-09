import Foundation

/// Advisory time remaining for a run. The caller still enforces its deadline by interrupting
/// the agent. Shared with delegated sessions so starting a child never resets the clock.
public final class RunTimeBudget: @unchecked Sendable {
  public let seconds: Double
  private let now: @Sendable () -> Double
  private let lock = NSLock()
  private var startedAt: Double?

  public convenience init(seconds: Double) {
    self.init(seconds: seconds, now: { ProcessInfo.processInfo.systemUptime })
  }

  init(seconds: Double, now: @escaping @Sendable () -> Double) {
    precondition(seconds.isFinite && seconds > 0)
    self.seconds = seconds
    self.now = now
  }

  /// Start once, alongside the caller's deadline timer. Without an explicit start, the first
  /// notice starts the clock. Calling this again, including in a subagent, cannot extend it.
  public func start() {
    lock.withLock {
      if startedAt == nil { startedAt = now() }
    }
  }

  public var remainingSeconds: Double {
    lock.withLock {
      let current = now()
      let start = startedAt ?? current
      startedAt = start
      return max(0, seconds - max(0, current - start))
    }
  }
}

/// At most five notices per turn: initial, half, quarter, tenth and expired. If a response
/// crosses several thresholds, report only the current one. Facts ride user history, never
/// the cached system prefix; behavioral guidance belongs in an experimental prompt pack.
struct TimeBudgetNotices {
  private var lastStage: Int?

  mutating func next(for budget: RunTimeBudget) -> String? {
    let remaining = budget.remainingSeconds
    let fraction = remaining / budget.seconds
    let stage = remaining == 0 ? 4 : fraction <= 0.1 ? 3 : fraction <= 0.25 ? 2 : fraction <= 0.5 ? 1 : 0
    if let lastStage, stage <= lastStage { return nil }
    lastStage = stage
    return "[arnes time budget] Approximately \(String(format: "%.0f", ceil(remaining))) of \(String(format: "%.0f", ceil(budget.seconds))) seconds remain before the caller's deadline."
  }
}
