import Foundation

/// A counting latch for concurrency tests: callers `arrive()` and `wait(for:)` suspends
/// until that many have arrived. Two mock streams that each wait for the other's arrival
/// can only complete if they run concurrently — a serial runner deadlocks (so tests that
/// use it must also race a timeout), which is exactly the proof concurrency needs, with
/// no sleeps.
actor Latch {
  private var arrivals = 0
  private var waiters: [(threshold: Int, continuation: CheckedContinuation<Void, Never>)] = []

  func arrive() {
    arrivals += 1
    let ready = waiters.filter { $0.threshold <= arrivals }
    waiters.removeAll { $0.threshold <= arrivals }
    for waiter in ready { waiter.continuation.resume() }
  }

  func wait(for threshold: Int) async {
    if arrivals >= threshold { return }
    await withCheckedContinuation { continuation in
      waiters.append((threshold, continuation))
    }
  }

  var count: Int { arrivals }
}

/// Races `operation` against a deadline; nil when the deadline wins. For tests whose
/// failure mode is a hang (a serialized run of something that must overlap).
func withDeadline<T: Sendable>(
  seconds: Double,
  _ operation: @escaping @Sendable () async throws -> T)
  async throws -> T?
{
  try await withThrowingTaskGroup(of: T?.self) { group in
    group.addTask { try await operation() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      return nil
    }
    let first = try await group.next() ?? nil
    group.cancelAll()
    return first
  }
}
