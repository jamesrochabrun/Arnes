import Foundation
import OpenRouterSwift

// MARK: - TransportPolicy

/// How a session's model requests survive a flaky wire (R2): a request refused with 429/5xx,
/// an overloaded or timed-out provider, a connection reset, a stream that broke or went silent
/// **before any output token** is retried with jittered exponential backoff — the same rule for
/// the chat, `/messages` and `/responses` steps, decided once in `Session.streamStep`. A failure
/// *after* the model started answering is never retried (a rerun would duplicate what the user
/// already saw); a 4xx, a decoding failure, an exhausted mock or a refusal is never a retry.
///
/// Two budgets, per step: `maxRequestRetries` for a request that failed at the HTTP level
/// (429, 5xx, 524, 529, a connection error), `maxStreamRetries` for a stream that started and
/// then broke (a mid-stream SSE error, `streamIdleTimeoutMs` without a chunk). The waits are
/// capped by `maxRetryWaitSeconds` in total, and a 429's `Retry-After` is honored over the
/// computed backoff — or ends the retries when it doesn't fit the cap.
///
/// `sleep` and `random` are seams: tests inject an instant sleep and a fixed jitter so a retry
/// is proven to *happen* without waiting for it. Configured from `policies.transport` in
/// `~/.arnes/config.json` (`TransportPolicyConfig`); `.default` everywhere else — panels and
/// evals run the built-in numbers.
public struct TransportPolicy: Sendable {
  /// Retries of a request that failed before its stream opened (HTTP 429/5xx, 524, 529, a
  /// connection error). 0 = never retry.
  public var maxRequestRetries: Int
  /// Retries of a stream that opened and then broke before any output token — a mid-stream
  /// error event, or `streamIdleTimeoutMs` of silence. 0 = never retry.
  public var maxStreamRetries: Int
  /// A stream that yields no chunk for this long is cancelled and counted as a stream retry
  /// (when nothing was output yet) or ends the step with an error (when something was).
  /// 0 = no idle timeout.
  public var streamIdleTimeoutMs: Int
  /// The most a step spends waiting between attempts, in total; a backoff (or a `Retry-After`)
  /// that would cross it ends the retries instead.
  public var maxRetryWaitSeconds: Double
  /// How the policy waits — `Task.sleep` by default; tests inject an instant one.
  public var sleep: @Sendable (_ nanoseconds: UInt64) async throws -> Void
  /// The jitter source, a value in `[0, 1)` — `Double.random` by default; tests inject a fixed one.
  public var random: @Sendable () -> Double

  public static let defaultMaxRequestRetries = 4
  public static let defaultMaxStreamRetries = 5
  public static let defaultStreamIdleTimeoutMs = 300_000
  public static let defaultMaxRetryWaitSeconds: Double = 60
  /// The first retry waits about this long; each further one doubles it (before jitter).
  public static let baseDelaySeconds: Double = 0.5
  /// No single wait grows past this (before jitter).
  public static let maxAttemptDelaySeconds: Double = 8

  public init(
    maxRequestRetries: Int = TransportPolicy.defaultMaxRequestRetries,
    maxStreamRetries: Int = TransportPolicy.defaultMaxStreamRetries,
    streamIdleTimeoutMs: Int = TransportPolicy.defaultStreamIdleTimeoutMs,
    maxRetryWaitSeconds: Double = TransportPolicy.defaultMaxRetryWaitSeconds,
    sleep: @escaping @Sendable (_ nanoseconds: UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
    random: @escaping @Sendable () -> Double = { Double.random(in: 0..<1) })
  {
    self.maxRequestRetries = max(0, maxRequestRetries)
    self.maxStreamRetries = max(0, maxStreamRetries)
    self.streamIdleTimeoutMs = max(0, streamIdleTimeoutMs)
    self.maxRetryWaitSeconds = max(0, maxRetryWaitSeconds)
    self.sleep = sleep
    self.random = random
  }

  /// The built-in numbers: 4 request retries, 5 stream retries, a 5-minute idle timeout, 60 s of
  /// waiting at most.
  public static let `default` = TransportPolicy()

  /// No retries and no idle timeout, for A/Bs and tests. Not byte-for-byte the pre-R2 wire: a
  /// first retryable failure is still classified and thrown as
  /// `TransportError.retriesExhausted(retries: 0)` wrapping it — on chat where the raw error
  /// used to propagate, and on a native dialect where it used to fall back to chat and pin the
  /// model there. Only the waiting and the re-sending are off.
  public static let off = TransportPolicy(maxRequestRetries: 0, maxStreamRetries: 0, streamIdleTimeoutMs: 0)

  // MARK: Backoff

  /// How long retry number `attempt` (1-based, counting every retry of the step so far) waits:
  /// a server-stated `Retry-After` verbatim when given, else `baseDelaySeconds × 2^(attempt−1)`
  /// capped at `maxAttemptDelaySeconds` and jittered by `[0.5, 1.5)` — so a fleet of retrying
  /// clients spreads out instead of hammering the router in lockstep. `random` is in `[0, 1)`.
  public static func delay(forAttempt attempt: Int, retryAfter: TimeInterval?, random: Double) -> TimeInterval {
    if let retryAfter, retryAfter > 0 {
      return retryAfter
    }
    let exponential = min(maxAttemptDelaySeconds, baseDelaySeconds * pow(2, Double(max(0, attempt - 1))))
    let jitter = 0.5 + min(max(random, 0), 0.999_999)
    return exponential * jitter
  }

  /// `delay(forAttempt:retryAfter:random:)` with this policy's jitter source.
  public func delay(forAttempt attempt: Int, retryAfter: TimeInterval?) -> TimeInterval {
    Self.delay(forAttempt: attempt, retryAfter: retryAfter, random: random())
  }

  // MARK: Classification

  /// Why a failed attempt may be retried, and the wait the server asked for, if any.
  public struct RetryReason: Sendable, Equatable {
    /// Short and fixed — what the `.retrying` event and the exhausted error say.
    public let text: String
    /// A 429's `Retry-After`, honored over the computed backoff.
    public let retryAfter: TimeInterval?

    public init(text: String, retryAfter: TimeInterval? = nil) {
      self.text = text
      self.retryAfter = retryAfter
    }
  }

  /// The one classification of a failed attempt, deliberately narrow: `OpenRouterError`'s
  /// `.rateLimited` (429, `Retry-After` kept), `.serviceOverloaded` (529), `.providerTimeout`
  /// (524), `.api` with a 5xx status, a connection-level `URLError` (`networkConnectionLost`,
  /// `timedOut`, `cannotConnectToHost`, `notConnectedToInternet`) — wrapped in `.transport` by
  /// the request phase, or thrown bare by a byte stream that died mid-way —, `.streamError`
  /// (an SSE error event under HTTP 200) **only with a transient code** — none, 408, 429 or a
  /// 5xx — and this file's `streamIdle`. Everything else — a 4xx, on the HTTP layer or relayed
  /// as a 4xx-coded error event, `insufficientCredits`, `guardrailViolation`,
  /// `decodingFailure`, `invalidResponse`, a cancellation, a DNS miss, a mock's exhausted
  /// script, a native refusal — is nil: not a retry.
  public static func retryReason(for error: any Error) -> RetryReason? {
    if let transport = error as? TransportError {
      if case .streamIdle(let seconds) = transport {
        return RetryReason(text: "stream idle for \(Self.seconds(seconds))")
      }
      return nil
    }
    // A connection lost *inside* the stream arrives bare: OpenRouterSwift wraps only the request
    // phase's failure in `.transport`; its producer task rethrows the byte stream's `URLError`
    // as it is (`for try await line in lines`).
    if let urlError = error as? URLError {
      return connectionReason(urlError)
    }
    guard let routerError = error as? OpenRouterError else { return nil }
    switch routerError {
    case .rateLimited(_, let retryAfter):
      return RetryReason(text: "rate limited (429)", retryAfter: retryAfter)
    case .serviceOverloaded:
      return RetryReason(text: "provider overloaded (529)")
    case .providerTimeout:
      return RetryReason(text: "provider timeout (524)")
    case .api(let statusCode, _, _) where (500...599).contains(statusCode):
      return RetryReason(text: "HTTP \(statusCode)")
    case .transport(let inner):
      guard let urlError = inner as? URLError else { return nil }
      return connectionReason(urlError)
    case .streamError(let code, let message, _):
      // An error event under HTTP 200 carries the *upstream* status: the router relays a
      // provider's failure after the response started. Its code is gated exactly like an HTTP
      // status — a 400 (request shape), 402 (credits), 403 (moderation) or 404 (no endpoints)
      // arriving one line later than usual is the same deterministic refusal, and re-sending it
      // five times would only delay the answer; a bare event (Anthropic's `overloaded_error`
      // carries no code), 408, 429 and 5xx are transient.
      guard isTransientStreamErrorCode(code) else { return nil }
      let codeText = code.map { " (\($0))" } ?? ""
      return RetryReason(text: "stream error\(codeText): \(clip(message, 80))")
    case .api, .insufficientCredits, .guardrailViolation, .decodingFailure, .invalidResponse:
      return nil
    }
  }

  /// Whether an SSE error event's upstream code names a transient failure: none (a bare
  /// event), 408, 429 or a 5xx. Any other code is a refusal the retry layer never re-sends.
  static func isTransientStreamErrorCode(_ code: Int?) -> Bool {
    guard let code else { return true }
    return code == 408 || code == 429 || (500...599).contains(code)
  }

  /// The connection-level failures a retry can cure — the peer or the network went away, not
  /// the request. A DNS miss, a TLS failure or a cancelled task are not among them.
  static let retryableConnectionFailures: [URLError.Code: String] = [
    .networkConnectionLost: "lost",
    .timedOut: "timed out",
    .cannotConnectToHost: "refused",
    .notConnectedToInternet: "offline",
  ]

  static func connectionReason(_ urlError: URLError) -> RetryReason? {
    guard let text = retryableConnectionFailures[urlError.code] else { return nil }
    return RetryReason(text: "connection \(text)")
  }

  /// Why a retry that was still in budget was not made: the wait it needed would have taken
  /// the step's total past `maxRetryWaitSeconds`. Appended to the exhausted error's reason, so a
  /// `Retry-After: 120` reads as the cap it hit and not as a bare 429.
  static func waitCapNote(delay: TimeInterval, retryAfter: TimeInterval?, cap: TimeInterval) -> String {
    let wait = (retryAfter ?? 0) > 0 ? "Retry-After \(seconds(delay))" : "a \(seconds(delay)) backoff"
    return " (\(wait) would take the wait past the \(seconds(cap)) cap)"
  }

  // MARK: Idle timeout

  /// `stream` under this policy's idle timeout: a stream that yields nothing for
  /// `streamIdleTimeoutMs` is cancelled (its network task with it) and ends with
  /// `TransportError.streamIdle`, which the step's caller retries when no output token had
  /// arrived. With the timeout at 0 the stream is returned as it is.
  func idleGuarded<Element: Sendable>(_ stream: AsyncThrowingStream<Element, Error>) -> AsyncThrowingStream<Element, Error> {
    guard streamIdleTimeoutMs > 0 else { return stream }
    return Self.guarded(stream, idleMilliseconds: streamIdleTimeoutMs)
  }

  /// One consumer task forwards the source's elements and touches an activity clock; one
  /// watchdog sleeps until the earliest moment the stream could be idle for the whole window,
  /// re-checks, and on real silence cancels the consumer (the source's `onTermination` cancels
  /// the network task) and fails the guarded stream. Terminating the guarded stream cancels both.
  static func guarded<Element: Sendable>(
    _ source: AsyncThrowingStream<Element, Error>,
    idleMilliseconds: Int)
    -> AsyncThrowingStream<Element, Error>
  {
    let idle = Duration.milliseconds(idleMilliseconds)
    let idleSeconds = Double(idleMilliseconds) / 1000
    return AsyncThrowingStream { continuation in
      let activity = ActivityClock()
      let tasks = GuardTasks()
      // Registered before either task exists. A termination handler set after the stream has
      // finished is never invoked, and a pre-filled source is drained — and this stream finished
      // by the consumer — before this closure necessarily returns, which would have left the
      // watchdog asleep for the whole idle window. A task registered after termination is
      // cancelled on the spot instead.
      continuation.onTermination = { _ in tasks.cancelAll() }
      let consumer = Task {
        do {
          for try await element in source {
            activity.touch()
            continuation.yield(element)
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      tasks.register(consumer)
      let watchdog = Task {
        while !Task.isCancelled {
          let remaining = idle - activity.elapsed()
          if remaining <= .zero {
            // Fail first, then cancel: a cancelled consumer ends its loop with a clean `finish()`,
            // which must find the stream already terminated with the idle error, not win the race.
            continuation.finish(throwing: TransportError.streamIdle(seconds: idleSeconds))
            consumer.cancel()
            return
          }
          do {
            try await Task.sleep(for: remaining)
          } catch {
            return
          }
        }
      }
      tasks.register(watchdog)
    }
  }

  /// The guarded stream's two tasks, cancelled together when the stream terminates — whichever
  /// comes first, the registration or the termination.
  final class GuardTasks: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []
    private var terminated = false

    func register(_ task: Task<Void, Never>) {
      let alreadyTerminated: Bool = lock.withLock {
        if terminated { return true }
        tasks.append(task)
        return false
      }
      if alreadyTerminated { task.cancel() }
    }

    func cancelAll() {
      let pending: [Task<Void, Never>] = lock.withLock {
        terminated = true
        let registered = tasks
        tasks.removeAll()
        return registered
      }
      for task in pending { task.cancel() }
    }
  }

  /// When the guarded stream last produced an element. Touched from the consumer task, read
  /// from the watchdog — a lock, not an actor, so a chunk costs no hop.
  final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ContinuousClock.now

    func touch() {
      lock.withLock { last = ContinuousClock.now }
    }

    func elapsed() -> Duration {
      lock.withLock { ContinuousClock.now - last }
    }
  }

  // MARK: Rendering helpers

  static func seconds(_ value: Double) -> String {
    value == value.rounded() ? "\(Int(value))s" : String(format: "%.1fs", value)
  }

  static func clip(_ text: String, _ limit: Int) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count <= limit ? flat : String(flat.prefix(limit)) + "…"
  }
}

// MARK: - TransportError

/// What the retry layer itself reports: a stream that went silent, and a step that gave up.
/// `"\(error)"` — what the CLI prints for a thrown run — reads as the description, so the
/// wrapped failure and the retry count show instead of the enum's shape.
public enum TransportError: Error, LocalizedError, CustomStringConvertible {
  /// The stream yielded nothing for the policy's idle window and was cancelled.
  case streamIdle(seconds: Double)
  /// The step retried `retries` times and the last attempt still failed with `underlying`;
  /// `reason` is the classification of that last failure (plus, when the retries ended on the
  /// wait cap rather than the count, the wait that would have crossed it).
  case retriesExhausted(reason: String, retries: Int, underlying: any Error)

  public var errorDescription: String? { description }

  public var description: String {
    switch self {
    case .streamIdle(let seconds):
      return "stream idle for \(TransportPolicy.seconds(seconds)) — no data from the provider"
    case .retriesExhausted(let reason, let retries, let underlying):
      let cause = Self.describe(underlying)
      switch retries {
      case 0: return "\(reason): \(cause)"
      case 1: return "\(reason) after 1 retry: \(cause)"
      default: return "\(reason) after \(retries) retries: \(cause)"
      }
    }
  }

  /// The wrapped error as a sentence — its `LocalizedError` text (`Rate limited: …`) where it
  /// has one, never the enum dump `rateLimited(message: "…", retryAfter: nil)`.
  static func describe(_ error: any Error) -> String {
    (error as? LocalizedError)?.errorDescription ?? "\(error)"
  }
}

// MARK: - StepTransportError

/// How a dialect step hands a failure that happened **before any output token** to the retry
/// loop in `Session.streamStep`: which phase failed (the request itself, or the stream it
/// opened) and the error as thrown. Never thrown after output — a step that already streamed
/// text keeps its dialect's own failure shape (chat propagates, native records a failure).
struct StepTransportError: Error {
  enum Phase: Sendable {
    /// `service.*Stream(request)` threw: an HTTP-level refusal or a connection failure.
    case request
    /// The stream opened and then threw: a mid-stream error event, a lost connection, silence.
    case stream
  }

  let phase: Phase
  let underlying: any Error
}

// MARK: - OutputTruncation

/// The output-limit cutoff, dialect-neutrally: the finish words each wire uses for "the reply
/// hit `max_tokens`", and the one rule for a tool call the cutoff landed inside of.
public enum OutputTruncation {
  /// Chat completions say `length`, `/messages` says `max_tokens`, `/responses` reports
  /// `incomplete_details.reason: max_output_tokens`.
  public static let finishReasons: Set<String> = ["length", "max_tokens", "max_output_tokens"]

  public static func isTruncation(_ finishReason: String?) -> Bool {
    finishReason.map { finishReasons.contains($0) } ?? false
  }

  /// How many times per turn a cut-off reply earns a nudge to continue; a cutoff past the budget
  /// ends the turn as `truncated`.
  public static let maxNudgesPerTurn = 1

  /// What the model is told after a cutoff (family-neutral harness plumbing, fixed): continue
  /// from where it stopped, shorter — and, when a call was cut mid-arguments, that the call was
  /// dropped and must be re-issued whole. Rides history as a user message (`[arnes] ` prefixed by
  /// the caller, the way every harness notice is), so it survives dialect translation and resume.
  public static let nudge = "Your reply was cut off at the output limit; continue from where you stopped, shorter."

  public static func nudge(droppedToolCall: String?) -> String {
    guard let name = droppedToolCall, !name.isEmpty else { return nudge }
    return nudge + " The incomplete \(String(name.prefix(60))) call was dropped — re-issue it in full."
  }

  /// Whether a call's arguments are a whole JSON object — what a call the cutoff landed inside
  /// of never has. The accumulators substitute `{}` for a call whose arguments never started, so
  /// a no-argument call reads as complete; the model's coaching error covers that corner.
  public static func hasCompleteArguments(_ call: ToolCall) -> Bool {
    guard let arguments = call.function?.arguments else { return false }
    let trimmed = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}"),
          let object = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))
    else { return false }
    return object is [String: Any]
  }

  /// The calls a truncated step may execute: every call but a last one whose arguments were cut
  /// mid-JSON (only the last can be — a stream emits calls in order). A step that was not cut,
  /// or whose last call is whole, keeps every call.
  public static func droppingPartialToolCall(from calls: [ToolCall], truncated: Bool) -> (kept: [ToolCall], dropped: ToolCall?) {
    guard truncated, let last = calls.last, !hasCompleteArguments(last) else {
      return (calls, nil)
    }
    return (Array(calls.dropLast()), last)
  }
}
