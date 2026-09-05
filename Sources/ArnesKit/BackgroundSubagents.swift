import Foundation

// MARK: - BackgroundSubagents

/// The task tool's registry of detached runs: which are in flight, which have finished and are
/// waiting for the session to deliver their report, and who is waiting for the next one.
///
/// A lock rather than an actor because four of the five `BackgroundWorkSource` operations are
/// synchronous by design — the session reads the count and drains finished outcomes at a step
/// boundary without suspending — and the one that waits (`awaitAny`) parks a continuation
/// that `complete` resumes. Cancellation of the waiting task hands it nil, so a turn interrupted
/// while joining falls through to its interrupt path instead of hanging on a run that may
/// itself be about to be cancelled.
final class BackgroundSubagents: @unchecked Sendable {
  private struct Running {
    let agent: String
    let model: String
    let startedAt: Date
    /// Set by `attach` a moment after `register` — the task can't be created before its entry
    /// exists, or a run finishing instantly would complete an id nobody registered.
    var task: Task<Void, Never>?
  }

  private struct Finished {
    let outcome: BackgroundOutcome
    let startedAt: Date
  }

  private struct Waiter {
    let ticket: UUID
    let continuation: CheckedContinuation<BackgroundOutcome?, Never>
  }

  private let lock = NSLock()
  /// Insertion-ordered, so `/tasks` lists runs in the order they were started.
  private var running: [(id: String, entry: Running)] = []
  /// Finished outcomes in finish order, until the session drains or awaits them.
  private var finished: [Finished] = []
  private var waiters: [Waiter] = []
  /// Tickets whose task was cancelled before the waiter could be registered (the cancellation
  /// handler ran first) — `awaitAny` consults it so such a caller returns nil at once.
  private var cancelledTickets: Set<UUID> = []

  // MARK: Registration

  func register(id: String, agent: String, model: String) {
    lock.withLock {
      running.append((id, Running(agent: agent, model: model, startedAt: Date(), task: nil)))
    }
  }

  func attach(task: Task<Void, Never>, to id: String) {
    lock.withLock {
      guard let index = running.firstIndex(where: { $0.id == id }) else { return }
      running[index].entry.task = task
    }
  }

  /// A run finished: hand its outcome to a waiting caller, else queue it for the next drain.
  /// Returns false — and keeps nothing — when the run is no longer registered: `cancelAll`
  /// took it while it was finishing, so its report is the caller's to drop, not the session's
  /// to deliver after the turn that owned it has ended.
  @discardableResult
  func complete(id: String, outcome: BackgroundOutcome) -> Bool {
    let (registered, waiter): (Bool, Waiter?) = lock.withLock {
      guard let index = running.firstIndex(where: { $0.id == id }) else { return (false, nil) }
      let startedAt = running.remove(at: index).entry.startedAt
      if waiters.isEmpty {
        finished.append(Finished(outcome: outcome, startedAt: startedAt))
        return (true, nil)
      }
      return (true, waiters.removeFirst())
    }
    waiter?.continuation.resume(returning: outcome)
    return registered
  }

  // MARK: BackgroundWorkSource backing

  var pendingCount: Int {
    lock.withLock { running.count + finished.count }
  }

  func drainFinished() -> [BackgroundOutcome] {
    lock.withLock {
      let drained = finished.map(\.outcome)
      finished.removeAll()
      return drained
    }
  }

  func snapshot() -> [BackgroundRun] {
    lock.withLock {
      running.map {
        BackgroundRun(
          id: $0.id, agent: $0.entry.agent, model: $0.entry.model,
          startedAt: $0.entry.startedAt, finished: false)
      } + finished.map {
        BackgroundRun(
          id: $0.outcome.id, agent: $0.outcome.agent, model: $0.outcome.model,
          startedAt: $0.startedAt, finished: true)
      }
    }
  }

  /// The next outcome: a finished one immediately, else the first run to complete; nil when
  /// nothing is pending, or when the caller is cancelled while waiting.
  func awaitAny() async -> BackgroundOutcome? {
    let ticket = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<BackgroundOutcome?, Never>) in
        // Decided under the lock, resumed outside it: a finished outcome or an empty registry
        // answers now; otherwise the continuation parks until `complete` (or cancellation).
        let immediate: BackgroundOutcome?? = lock.withLock {
          if !finished.isEmpty { return .some(finished.removeFirst().outcome) }
          if running.isEmpty || cancelledTickets.remove(ticket) != nil { return .some(nil) }
          waiters.append(Waiter(ticket: ticket, continuation: continuation))
          return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
      }
    } onCancel: {
      let parked: Waiter? = lock.withLock {
        if let index = waiters.firstIndex(where: { $0.ticket == ticket }) {
          return waiters.remove(at: index)
        }
        cancelledTickets.insert(ticket)
        return nil
      }
      parked?.continuation.resume(returning: nil)
    }
  }

  /// Cancels every running task, releases anyone waiting with nil, drops every undelivered
  /// outcome, and waits for the cancelled runs to wind down. Returns the dropped outcomes, whose
  /// spend the caller accrues as stranded cost; a cancelled run accrues its own once it ends
  /// (see `TaskTool.execute` — `complete` refuses it, since it is no longer registered).
  func cancelAll() async -> [BackgroundOutcome] {
    let (tasks, parked, dropped): ([Task<Void, Never>], [Waiter], [BackgroundOutcome]) = lock.withLock {
      let tasks = running.compactMap(\.entry.task)
      running.removeAll()
      let parked = waiters
      waiters.removeAll()
      let dropped = finished.map(\.outcome)
      finished.removeAll()
      return (tasks, parked, dropped)
    }
    for waiter in parked { waiter.continuation.resume(returning: nil) }
    for task in tasks { task.cancel() }
    for task in tasks { await task.value }
    return dropped
  }
}
