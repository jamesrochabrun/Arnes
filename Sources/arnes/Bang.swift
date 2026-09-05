import Foundation

/// The REPL's `!` shell escape (Claude Code's bang commands), terminal-free pieces: parsing,
/// the output cap, and the text the model is told. Running lives in `Interactive` (the loop
/// owns the session, the environment and the interrupt wiring); the runner is ArnesKit's
/// `UserShell` — the `bash` tool's runner outside every tool gate, because the user typed
/// the command into their own terminal.
enum Bang {
  /// `!command` → the command; nil when the line is a normal message (the loop trims outer
  /// whitespace before asking, so the `!` is the line's first character). A bare `!` is a
  /// bang line with an empty command — the caller prints `usage`.
  static func parse(_ line: String) -> String? {
    guard line.hasPrefix("!") else { return nil }
    return String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
  }

  /// Whether the input box is in shell mode — the buffer's first character is `!`.
  /// What `Screen` tints the box (and its mode tag) on.
  static func isShellBuffer(_ buffer: String) -> Bool { buffer.hasPrefix("!") }

  static let usage =
    "usage: ! <command> — runs in your shell; the agent then explains the result concisely (or how to recover from a failure)"

  /// The shell-mode tag shown in the box's bottom border while the buffer starts with `!`.
  static let modeTag = "! shell"

  /// Keeps the head 60% and tail 40% of an over-long output — `ToolOutputLimiter`'s shape,
  /// applied here because a bang command's output rides a user message, never the tool path.
  static func capped(_ output: String, maxChars: Int) -> String {
    guard maxChars > 16, output.count > maxChars else { return output }
    let head = maxChars * 6 / 10
    let tail = maxChars * 4 / 10
    let omitted = output.count - head - tail
    return output.prefix(head)
      + "\n[… \(omitted) chars omitted …]\n"
      + output.suffix(tail)
  }

  /// One line saying how the command ended — shown in the terminal and carried by `notice`.
  static func resultLine(
    exitStatus: Int32, timedOut: Bool, cancelled: Bool, failedToStart: Bool,
    timeoutSeconds: Int)
    -> String
  {
    if cancelled { return "interrupted before it finished" }
    if timedOut { return "timed out after \(timeoutSeconds)s — the process tree was killed" }
    if failedToStart { return "the shell could not start (exit \(exitStatus))" }
    return "exit \(exitStatus)"
  }

  /// What the model is told about the run. A *completed* command sends this inside
  /// `turnPrompt` as its own turn; an *interrupted* one queues it through `Session.notify`,
  /// riding the next `[arnes]` user message (the user stopped it — nothing to explain now).
  static func notice(
    command: String, output: String, exitStatus: Int32, timedOut: Bool, cancelled: Bool,
    failedToStart: Bool, timeoutSeconds: Int, maxChars: Int)
    -> String
  {
    let result = resultLine(
      exitStatus: exitStatus, timedOut: timedOut, cancelled: cancelled,
      failedToStart: failedToStart, timeoutSeconds: timeoutSeconds)
    let body = capped(output.trimmingCharacters(in: .whitespacesAndNewlines), maxChars: maxChars)
    return """
      the user ran this command in their own shell (not a tool call — you did not run it):
      $ \(command)
      \(result)
      \(body.isEmpty ? "(no output)" : body)
      """
  }

  /// How the model should answer the exchange `turnPrompt` sends — explain, don't
  /// interrogate. The failure mode this text exists for: shown a `git status`, the model
  /// asked "what do you want to do with it?" through ask_user instead of just reading it.
  static let responseGuidance = """
    Reply in a few sentences: explain concisely what this result shows — or, if the command \
    failed, the likely cause and exactly how to recover (name the command or edit). Do not \
    repeat the output back, do not ask what to do with it, and do not start new work: run a \
    tool only if a failure cannot be explained from the output alone.
    """

  /// The user message a completed bang command sends as its own turn, immediately — the
  /// exchange plus the response contract above. Harness-authored, so it carries the
  /// `[arnes]` prefix the notice route would have added.
  static func turnPrompt(
    command: String, output: String, exitStatus: Int32, timedOut: Bool,
    failedToStart: Bool, timeoutSeconds: Int, maxChars: Int)
    -> String
  {
    "[arnes] " + notice(
      command: command, output: output, exitStatus: exitStatus, timedOut: timedOut,
      cancelled: false, failedToStart: failedToStart, timeoutSeconds: timeoutSeconds,
      maxChars: maxChars)
      + "\n\n" + responseGuidance
  }
}
