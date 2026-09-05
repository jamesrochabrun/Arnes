import Foundation
import OpenRouterSwift

// MARK: - LoopGuardPolicy

/// When the session stops a model that is going in circles — the thresholds behind
/// `Session`'s per-turn loop guard (`Session.Configuration.loopGuard`, `limits.loopGuard` in
/// `~/.arnes/config.json`). Every counter is per turn and every threshold `0` switches that
/// check off.
///
/// The denied loop (`Session.maxRefusalsPerTurn`) is a separate breaker and stays as it is:
/// refusals feed both.
public struct LoopGuardPolicy: Sendable, Equatable {
  /// Failed calls in a row — an `error:` result, a validation error, a refusal — that end the
  /// turn with `StopReason.stuck`. Reset by any call that succeeds.
  public var maxConsecutiveErrors: Int
  /// Times the same call (tool + canonical arguments) may *fail* in one turn before the turn
  /// ends. Identical calls that succeed never count here: a test rerun is not a loop.
  public var maxIdenticalCalls: Int
  /// `edit_file`/`write_file` calls against one path in one turn: this many *failed* ones end
  /// the turn (a model that can't land an edit on a file is thrashing, not editing), while this
  /// many edits of any outcome earn the model one nudge to re-read the file and consolidate —
  /// never a stop, since a long refactor legitimately edits one file many times.
  public var maxEditsPerFile: Int
  /// Consecutive errors, or repeats of one call (whatever its outcome), that earn the model
  /// one `[arnes]` nudge per turn before any hard threshold is reached.
  public var nudgeAt: Int

  public init(
    maxConsecutiveErrors: Int = 6,
    maxIdenticalCalls: Int = 6,
    maxEditsPerFile: Int = 8,
    nudgeAt: Int = 3)
  {
    self.maxConsecutiveErrors = maxConsecutiveErrors
    self.maxIdenticalCalls = maxIdenticalCalls
    self.maxEditsPerFile = maxEditsPerFile
    self.nudgeAt = nudgeAt
  }

  public static let `default` = LoopGuardPolicy()
}

// MARK: - LoopGuard

/// The per-turn counters behind the policy, fed one committed tool call at a time by the
/// session's commit path (never by a background report's synthetic exchange — those are not
/// model calls). Pure state: the session acts on the verdict.
struct LoopGuard {
  enum Verdict: Equatable {
    case none
    /// Send the model one nudge (once per turn): `reason` is the `.nudged` event's, `text` what
    /// the model reads (queued through `Session.notify`, so it rides an `[arnes]` user message).
    case nudge(reason: String, text: String)
    /// End the turn with `StopReason.stuck`; `reason` is for the user.
    case stuck(reason: String)
  }

  /// How a committed call went, as the guard sees it.
  enum Outcome {
    /// A result the model can use.
    case ok
    /// An `error:` result — the tool ran and failed, or the loop refused to run it over
    /// malformed or incomplete arguments.
    case error
    /// A refusal: permission, hook, or the execute-time floor. Counts toward the hard
    /// thresholds like an error, but never earns a nudge — the denial text is the model's
    /// feedback and the denied-loop breaker is its own stop, so a nudge here would only be
    /// queued for a turn that is already ending.
    case refused

    var failed: Bool { self != .ok }
  }

  let policy: LoopGuardPolicy
  private(set) var consecutiveErrors = 0
  private(set) var nudged = false
  private var callCounts: [String: Int] = [:]
  private var failureCounts: [String: Int] = [:]
  private var editCounts: [String: Int] = [:]
  private var editFailureCounts: [String: Int] = [:]

  init(policy: LoopGuardPolicy) {
    self.policy = policy
  }

  /// Records one committed call and says what the loop should do about it. Hard thresholds
  /// win over the nudge; the nudge fires at most once per turn.
  mutating func observe(tool: String, argumentsJSON: String, outcome: Outcome) -> Verdict {
    let key = Self.key(tool: tool, argumentsJSON: argumentsJSON)
    let failed = outcome.failed
    consecutiveErrors = failed ? consecutiveErrors + 1 : 0
    callCounts[key, default: 0] += 1
    if failed { failureCounts[key, default: 0] += 1 }
    var editedPath: String?
    if tool == "edit_file" || tool == "write_file",
       let path = Self.decodedArguments(argumentsJSON)?["path"]?.stringValue
    {
      editCounts[path, default: 0] += 1
      if failed { editFailureCounts[path, default: 0] += 1 }
      editedPath = path
    }

    if let failures = failureCounts[key], Self.reached(policy.maxIdenticalCalls, failures) {
      return .stuck(reason: "the same \(tool) call failed \(failures) times")
    }
    if Self.reached(policy.maxConsecutiveErrors, consecutiveErrors) {
      return .stuck(reason: "\(consecutiveErrors) tool calls failed in a row")
    }
    if let editedPath, let failures = editFailureCounts[editedPath], Self.reached(policy.maxEditsPerFile, failures) {
      return .stuck(reason: "\(failures) failed edits to \((editedPath as NSString).lastPathComponent) in one turn")
    }
    guard !nudged, outcome != .refused else { return .none }
    // The repeat is the more specific diagnosis when both trip at once.
    if let repeats = callCounts[key], Self.reached(policy.nudgeAt, repeats) {
      nudged = true
      return .nudge(
        reason: "repeated call",
        text: Self.repeatNudge(tool: tool, count: repeats, everSucceededOnly: failureCounts[key] == nil))
    }
    if Self.reached(policy.nudgeAt, consecutiveErrors) {
      nudged = true
      return .nudge(reason: "repeated failures", text: Self.failuresNudge(count: consecutiveErrors))
    }
    // Many edits to one file, whatever their outcome: a nudge to consolidate, never a stop —
    // a symbol renamed occurrence by occurrence is work, not a loop.
    if let editedPath, let edits = editCounts[editedPath], Self.reached(policy.maxEditsPerFile, edits) {
      nudged = true
      return .nudge(
        reason: "repeated edits",
        text: Self.editsNudge(file: (editedPath as NSString).lastPathComponent, count: edits))
    }
    return .none
  }

  /// A threshold of 0 is off. `>=` rather than `==`: a refused call can carry the error streak
  /// past `nudgeAt` without earning the nudge, and the next error must still get it.
  private static func reached(_ threshold: Int, _ count: Int) -> Bool {
    threshold > 0 && count >= threshold
  }

  /// What the model reads after `nudgeAt` failures in a row: harness plumbing, family-neutral,
  /// three sentences (`Session.notify` adds the `[arnes]` prefix).
  static func failuresNudge(count: Int) -> String {
    "Your last \(count) tool calls failed. "
      + "Do not repeat them: re-read the file or check the path or command, then try a different approach. "
      + "If something is blocking you, say what it is instead of retrying."
  }

  /// What the model reads after `nudgeAt` identical calls. A call that keeps *succeeding* (a
  /// test rerun, the same `update_plan` list) gets advice about using the answer it has, not
  /// about fixing a path or command that is evidently fine.
  static func repeatNudge(tool: String, count: Int, everSucceededOnly: Bool) -> String {
    if everSucceededOnly {
      return "You have made the same \(tool) call \(count) times and it succeeded each time. "
        + "If it was a check, you already have its answer: use it and take the next step. "
        + "If you are waiting for something to change, say what it is instead of repeating the call."
    }
    return "You have made the same \(tool) call \(count) times. "
      + "Do not repeat it: re-read the file or check the path or command, then take a different step. "
      + "If something is blocking you, say what it is instead of retrying."
  }

  /// What the model reads after `maxEditsPerFile` edits to one file in a turn.
  static func editsNudge(file: String, count: Int) -> String {
    "You have edited \(file) \(count) times this turn. "
      + "Re-read the whole file and make one consolidated edit instead of another small one. "
      + "If it keeps needing changes, say what keeps changing before editing it again."
  }

  /// `tool + SHA-256(canonical arguments)` — the identity of a call. Arguments are re-encoded
  /// with sorted keys so `{"a":1,"b":2}` and `{"b":2,"a":1}` are one call; unparseable
  /// arguments hash as written.
  static func key(tool: String, argumentsJSON: String) -> String {
    tool + ":" + HookHash.sha256Hex(Data(canonicalize(argumentsJSON).utf8))
  }

  static func canonicalize(_ argumentsJSON: String) -> String {
    guard let object = decodedArguments(argumentsJSON) else {
      return argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(object) else { return argumentsJSON }
    return String(decoding: data, as: UTF8.self)
  }

  private static func decodedArguments(_ json: String) -> [String: JSONValue]? {
    try? JSONDecoder().decode([String: JSONValue].self, from: Data(json.utf8))
  }
}
