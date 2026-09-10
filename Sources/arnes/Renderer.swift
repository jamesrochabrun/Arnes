import ArnesKit
import Foundation

/// Renders `AgentEvent`s to the terminal: streamed text markdown-styled, tool activity
/// dimmed, routing in cyan, and a cost/route status line after each turn.
///
/// Tool activity is concise by default (one line per call, salient argument only);
/// Ctrl-O toggles the verbose form with raw arguments and result previews.
///
/// Every string that originates outside the harness — model text, tool arguments and
/// results, served-model names, subagent reports — passes through `TerminalText`
/// before it is drawn, so control characters can't rewrite the screen.
final class Renderer {
  /// Whether any text deltas were printed for the current step (so the duplicate
  /// `assistantText` can be skipped and we just terminate the line).
  private var printedDelta = false
  private var printedReasoning = false
  private var markdown = StreamingMarkdown()
  /// Ids of subagents whose runs are in flight. A step can delegate several times at once,
  /// and their progress lines interleave — while more than one is running, every nested line
  /// says which run it belongs to.
  private var activeSubagents: Set<String> = []

  /// When set, all output routes through the pinned-bar screen; nil keeps the plain
  /// top-to-bottom printing used by piped sessions.
  private let screen: Screen?
  /// A test seam: when set, committed lines go here instead of the screen or stdout.
  private let lineSink: ((String) -> Void)?
  /// A test seam: when set, streamed fragments (text and reasoning deltas, a line's closing
  /// tail) go here instead of the screen or stdout — what a `/thinking off` must leave empty.
  private let streamSink: ((String) -> Void)?

  init(
    screen: Screen? = nil,
    lineSink: ((String) -> Void)? = nil,
    streamSink: ((String) -> Void)? = nil)
  {
    self.screen = screen
    self.lineSink = lineSink
    self.streamSink = streamSink
  }

  /// A committed transcript line.
  private func line(_ text: String) {
    if let lineSink {
      lineSink(text)
    } else if let screen {
      screen.print(text)
    } else {
      Swift.print(text)
    }
  }

  /// Streamed styled text; the screen keeps the open line inside the bar region.
  private func streamOut(_ text: String) {
    if let streamSink {
      streamSink(text)
    } else if let screen {
      screen.stream(text)
    } else {
      Swift.print(text, terminator: "")
      fflush(stdout)
    }
  }

  /// Ends an open streamed line (plus a final styled tail).
  private func endLine(_ tail: String = "") {
    if let streamSink {
      streamSink(tail + "\n")
    } else if let screen {
      screen.stream(tail)
      screen.finishStream()
    } else {
      Swift.print(tail)
    }
  }

  /// Untrusted text, made terminal-safe (no-op when piped).
  private func clean(_ text: String) -> String {
    TerminalText.sanitize(text)
  }

  /// Toggled from the key-watcher thread while render() runs on the turn task.
  private let verboseLock = NSLock()
  private var verboseFlag = false

  var verbose: Bool {
    verboseLock.withLock { verboseFlag }
  }

  @discardableResult
  func toggleVerbose() -> Bool {
    verboseLock.withLock {
      verboseFlag.toggle()
      return verboseFlag
    }
  }

  /// Whether streamed reasoning (`.reasoningDelta`) is drawn. Off, the deltas still arrive —
  /// the model thinks and pays for it either way — they are just not printed. Toggled by
  /// `/thinking` and Ctrl-T (the key-watcher thread), hence the lock; per process, never
  /// persisted.
  private var showReasoningFlag = true

  var showReasoning: Bool {
    verboseLock.withLock { showReasoningFlag }
  }

  /// Sets the reasoning display and returns the new state.
  @discardableResult
  func setShowReasoning(_ on: Bool) -> Bool {
    verboseLock.withLock {
      showReasoningFlag = on
      return showReasoningFlag
    }
  }

  @discardableResult
  func toggleReasoning() -> Bool {
    verboseLock.withLock {
      showReasoningFlag.toggle()
      return showReasoningFlag
    }
  }

  func beginTurn() {
    printedDelta = false
    printedReasoning = false
    markdown = StreamingMarkdown()
    // An interrupted turn can leave a subagent's finish line unsent; nothing outlives a turn.
    activeSubagents.removeAll()
  }

  func render(_ event: AgentEvent) {
    switch event {
    case .textDelta(let delta):
      if printedReasoning {
        // Separate the answer from dimmed reasoning output.
        endLine()
        printedReasoning = false
      }
      printedDelta = true
      streamOut(markdown.feed(clean(delta)))

    case .reasoningDelta(let delta):
      // Hidden by `/thinking off`: the delta is dropped from the display, never from the stream.
      guard showReasoning else { break }
      printedReasoning = true
      streamOut(ANSI.dim(clean(delta)))

    case .assistantText(let text):
      if printedDelta {
        // The streamed deltas already showed the text; emit what's still buffered
        // (a partial line, open styles) and end the line.
        endLine(markdown.flush())
      } else {
        line(markdown.feed(clean(text)) + markdown.flush())
      }
      printedDelta = false

    case .toolCall(let name, let arguments):
      endStreamedLineIfNeeded()
      if verbose {
        line(ANSI.dim(clean("→ \(name) \(String(arguments.prefix(120)))")))
      } else if name == "think" {
        // The thought is the model's scratchpad, not a line of the transcript: the concise
        // form says only that it paused to think (ctrl+o shows the text).
        line(ANSI.dim("• think"))
      } else {
        line(ANSI.dim(clean("• \(name) \(Self.conciseArguments(arguments))")))
      }

    // The model's checklist, pinned as it stands — in concise mode too: a long task's progress
    // is the one tool result worth reading. `.toolResult` for the same call stays quiet.
    case .planUpdated(let steps):
      endStreamedLineIfNeeded()
      for text in PlanFormat.checklistLines(steps) {
        line(ANSI.dim(clean("  \(text)")))
      }

    case .toolResult(let name, let preview):
      let firstLine = preview.split(separator: "\n").first.map(String.init) ?? preview
      if verbose {
        line(ANSI.dim(clean("← \(name): \(String(firstLine.prefix(120)))")))
      } else if firstLine.hasPrefix("error") || firstLine.hasPrefix("user denied") {
        // Concise mode stays quiet on success; failures still surface.
        line(ANSI.red(clean("✗ \(name): \(String(firstLine.prefix(120)))")))
      }

    case .toolDenied(let name, _):
      line(ANSI.yellow(clean("⊘ \(name) denied")))

    case .userQuestion:
      // No line: the REPL's `TerminalUserInput` prints the question itself, in order with its
      // own status line. A rendered copy here would duplicate it — and, coming through the
      // event stream from another task, could land after the prompt's `setStatus`. Only the
      // streamed line is closed so the prompt starts on a line of its own.
      endStreamedLineIfNeeded()

    case .routed(let model, let provider):
      endStreamedLineIfNeeded()
      line(ANSI.secondary(clean("⇄ \(model)\(provider.map { " (\($0))" } ?? "")")))

    case .dialectFellBack(let dialect, let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⤵ \(dialect) dialect failed (\(String(reason.prefix(80)))) — fell back to chat")))

    case .settingIgnored(let setting, let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⚠ --\(setting) has no effect: \(reason)")))

    case .verifier(let passed, let verdict):
      line(passed ? ANSI.green(clean("✔ \(verdict)")) : ANSI.red(clean("✘ \(verdict)")))

    case .structuredOutput(let json, let valid, let errors):
      endStreamedLineIfNeeded()
      if valid {
        line(ANSI.green("✓ structured output valid"))
        // The object itself on its own line, as headless text prints it (H1): the REPL used to
        // drop the payload a `/schema` turn was asked for.
        if let json { line(clean(HeadlessJSON.line(json))) }
      } else {
        let first = errors.first.map { String($0.prefix(200)) } ?? "no valid reply"
        line(ANSI.red(clean("✗ structured output invalid: \(first)")))
      }

    case .interrupted:
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⏹ interrupted"))

    case .nudged:
      endStreamedLineIfNeeded()
      line(ANSI.dim("↻ paused without finishing — nudged to continue"))

    case .stepLimitReached(let maxSteps):
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⚠ step limit (\(maxSteps)) reached — the task may be unfinished; say \"continue\" to keep going"))

    case .budgetReached(let spent, let budget):
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⚠ budget reached ($\(String(format: "%.4f", spent)) ≥ $\(String(format: "%.4f", budget))) — stopped; raise --budget to continue"))

    case .hookNotice(let event, let output):
      endStreamedLineIfNeeded()
      line(ANSI.dim(clean("⎔ \(event) hook: \(output)")))

    case .hookBlocked(let tool, let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⊘ \(tool) blocked by hook: \(String(reason.prefix(120)))")))

    case .hookStopped(let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⏹ turn ended by hook\(reason.map { ": \($0)" } ?? "")")))

    case .promptBlocked(let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⊘ prompt blocked by hook: \(String(reason.prefix(200)))"))
        + ANSI.dim(" — nothing was sent"))

    case .deniedLoop(let count):
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⊘ stopped after \(count) consecutive denials")
        + ANSI.dim(" — allow what it needs (/permissions), or ask for something else"))

    case .stuckDetected(let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⚠ stuck: \(String(reason.prefix(120)))"))
        + ANSI.dim(" — the turn was stopped; say what to try instead, or \"continue\""))

    // The scanner's word on a result the model is about to read: the pattern names are the
    // harness's, the tool name is the model's — sanitized like every other model string.
    case .contentFlagged(let tool, let patterns):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⚠ flagged: \(tool) result matched \(patterns.joined(separator: ", ")) — treated as data")))

    // Background shell jobs, dim like the other harness plumbing lines: the command is the
    // model's (clipped, sanitized), the exit status the kernel's.
    case .jobStarted(let id, let command):
      endStreamedLineIfNeeded()
      let preview = command.replacingOccurrences(of: "\n", with: " ")
      line(ANSI.dim(clean("⧗ job \(id) started: \(String(preview.prefix(80)))\(preview.count > 80 ? "…" : "")")))

    case .jobFinished(let id, let exitStatus):
      endStreamedLineIfNeeded()
      line(ANSI.dim("⧗ job \(id) finished (exit \(exitStatus))"))
    // The wire hiccupped before the model said anything; the step is being retried after a
    // backoff. Dim — a retry that succeeds is nothing the user has to act on.
    case .retrying(let attempt, let reason):
      endStreamedLineIfNeeded()
      line(ANSI.dim(clean("↻ retrying (attempt \(attempt): \(String(reason.prefix(120))))")))

    case .truncated:
      endStreamedLineIfNeeded()
      line(ANSI.yellow("✂ reply hit the output limit") + ANSI.dim(" — what streamed is partial"))

    case .compacted(let summarized, let kept):
      endStreamedLineIfNeeded()
      line(ANSI.dim("◈ context compacted: \(summarized) older messages summarized · \(kept) kept verbatim"))

    // Microcompaction (C2): dim — the persisted history still holds the real results, the
    // request just stops carrying the old ones. The warning is the user's to act on.
    case .toolResultsCleared(let count, let freedChars):
      endStreamedLineIfNeeded()
      line(ANSI.dim("◈ cleared \(count) older tool result\(count == 1 ? "" : "s") from the request (\(freedChars) chars) — history untouched"))

    case .contextWarning(let message):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⚠ context: \(String(message.prefix(200)))")) + ANSI.dim(" — /compact or /clear to make room"))

    case .subagentBlocked(let name, _, let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow(clean("⊘ \(name) blocked by hook: \(String(reason.prefix(120)))")))

    case .subagentStarted(let name, let id, let model, let task):
      endStreamedLineIfNeeded()
      activeSubagents.insert(id)
      let preview = task.replacingOccurrences(of: "\n", with: " ")
      line(ANSI.secondary(clean("◇ \(label(name, id)) ")) + ANSI.dim(clean("(\(model)) \(String(preview.prefix(80)))\(preview.count > 80 ? "…" : "")")))

    case .subagent(let name, let id, let event):
      renderNested(name, id, event)

    case .subagentBackgrounded(let name, let id, let model):
      endStreamedLineIfNeeded()
      activeSubagents.insert(id)
      line(ANSI.secondary(clean("◇ \(label(name, id)) ")) + ANSI.dim(clean("(\(model)) … [background]")))

    case .subagentJoining(let pending):
      endStreamedLineIfNeeded()
      line(ANSI.dim("⧗ waiting for \(pending) background subagent\(pending == 1 ? "" : "s")"))

    case .subagentFinished(let name, let id, let steps, let toolCalls, let costUSD, let preview):
      endStreamedLineIfNeeded()
      var footer = ANSI.secondary(clean("◆ \(label(name, id))"))
        + ANSI.dim(" · \(steps) steps · \(toolCalls) tools · \(Self.usd(costUSD))")
      activeSubagents.remove(id)
      if !verbose, !preview.isEmpty, preview != "failed" {
        let first = preview.split(separator: "\n").first.map(String.init) ?? preview
        footer += ANSI.dim(clean(" · \(String(first.prefix(60)))\(first.count > 60 ? "…" : "")"))
      }
      line(footer)

    case .turnFinished(let stats):
      endStreamedLineIfNeeded()
      let served = stats.routedModels.joined(separator: ", ")
      let route = served.isEmpty || served == stats.requestedModel
        ? stats.requestedModel
        : "\(stats.requestedModel) → \(served)"
      var footer = "─ \(clean(route)) · \(stats.steps) steps · \(stats.toolCalls) tools · "
        + "\(Self.seconds(stats.durationSeconds)) · "
        + "turn \(Self.usd(stats.turnCostUSD)) · session \(Self.usd(stats.sessionCostUSD))"
      if let used = stats.promptTokens, let context = stats.contextLength, context > 0 {
        footer += " · ctx \(used * 100 / context)%"
      }
      // The turn's prompt-cache hit rate, only when something was read from a cache — a run
      // without cached tokens prints exactly the footer it always did.
      if let segment = Self.cacheSegment(cached: stats.cachedPromptTokens, total: stats.totalPromptTokens) {
        footer += segment
      }
      line(ANSI.dim(footer))
    }
  }

  /// ` · cache N%` — the share of the turn's prompt tokens read from the provider's prompt cache
  /// (`cached / total`, clamped to 100); nil when nothing was cached or the total is unknown, so
  /// the footer stays byte-identical for every run that cached nothing.
  static func cacheSegment(cached: Int?, total: Int?) -> String? {
    guard let cached, cached > 0, let total, total > 0 else { return nil }
    return " · cache \(min(100, cached * 100 / total))%"
  }

  /// A subagent's own loop events, rendered indented under its ◇ start line. The
  /// subagent's streamed prose stays hidden — only its tool activity and hiccups
  /// show; the distilled report lands on the ◆ finish line and goes to the lead.
  ///
  /// With two or more subagents in flight their lines interleave, so each carries
  /// `[name#id]`; a lone subagent keeps the quieter form it always had.
  private func renderNested(_ name: String, _ id: String, _ event: AgentEvent) {
    let who = activeSubagents.count > 1 ? "[\(name)#\(id)] " : ""
    switch event {
    case .toolCall(let tool, let arguments):
      endStreamedLineIfNeeded()
      if verbose {
        line(ANSI.dim(clean("  → \(who)\(tool) \(String(arguments.prefix(110)))")))
      } else {
        line(ANSI.dim(clean("  ∙ \(who)\(tool) \(Self.conciseArguments(arguments))")))
      }

    case .toolResult(let tool, let preview):
      let firstLine = preview.split(separator: "\n").first.map(String.init) ?? preview
      if verbose {
        line(ANSI.dim(clean("  ← \(who)\(tool): \(String(firstLine.prefix(110)))")))
      } else if firstLine.hasPrefix("error") || firstLine.hasPrefix("user denied") {
        line(ANSI.red(clean("  ✗ \(who)\(tool): \(String(firstLine.prefix(110)))")))
      }

    case .toolDenied(let tool, _):
      line(ANSI.yellow(clean("  ⊘ \(who)\(tool) denied")))

    // Unreachable today — `ask_user` is stripped from every nested toolset — but a nested
    // question would be worth seeing, so the switch says what it would print rather than
    // dropping it into `default`.
    case .userQuestion(let question, let options):
      let choices = options.isEmpty ? "" : " [\(options.joined(separator: " | "))]"
      line(ANSI.dim(clean("  ? \(who)\(String(question.prefix(110)))\(choices)")))

    case .hookBlocked(let tool, _):
      line(ANSI.yellow(clean("  ⊘ \(who)\(tool) blocked by hook")))

    // A subagent's hooks are the user's guardrails on delegated work, so what they say
    // about it — a PostToolUseFailure/PermissionRequest hook's notice, a `continue: false`
    // from a SubagentStop or PostToolUse hook, a runner failure — shows here, dim and
    // indented like the rest of the nested lines, rather than vanishing into the report.
    case .hookNotice(let hookEvent, let output):
      line(ANSI.dim(clean("  ⎔ \(who)\(hookEvent) hook: \(String(output.prefix(110)))")))

    case .hookStopped(let reason):
      let subject = who.isEmpty ? "\(name) " : who
      line(ANSI.dim(clean("  ⏹ \(subject)asked to stop by hook\(reason.map { ": \(String($0.prefix(100)))" } ?? "")")))

    case .promptBlocked(let reason):
      let subject = who.isEmpty ? "\(name) " : who
      line(ANSI.yellow(clean("  ⊘ \(subject)prompt blocked by hook: \(String(reason.prefix(100)))")))

    case .routed(let model, let provider):
      if verbose {
        line(ANSI.dim(clean("  ⇄ \(model)\(provider.map { " (\($0))" } ?? "")")))
      }

    case .dialectFellBack(let dialect, _):
      line(ANSI.dim("  ⤵ \(dialect) fell back to chat"))

    case .settingIgnored(let setting, let reason):
      line(ANSI.dim(clean("  ⚠ --\(setting) has no effect: \(reason)")))

    case .nudged:
      if verbose {
        line(ANSI.dim(clean("  ↻ \(name) nudged to continue")))
      }

    case .stepLimitReached(let maxSteps):
      line(ANSI.yellow(clean("  ⚠ \(name) hit its step limit (\(maxSteps)) — report may be incomplete")))

    case .stuckDetected(let reason):
      line(ANSI.yellow(clean("  ⚠ \(name) stuck: \(String(reason.prefix(100))) — report may be incomplete")))

    case .contentFlagged(let tool, let patterns):
      line(ANSI.dim(clean("  ⚠ \(who)flagged: \(tool) result matched \(patterns.joined(separator: ", ")) — treated as data")))

    case .jobStarted(let jobId, let command):
      let preview = command.replacingOccurrences(of: "\n", with: " ")
      line(ANSI.dim(clean("  ⧗ \(who)job \(jobId) started: \(String(preview.prefix(80)))\(preview.count > 80 ? "…" : "")")))

    case .jobFinished(let jobId, let exitStatus):
      line(ANSI.dim(clean("  ⧗ \(who)job \(jobId) finished (exit \(exitStatus))")))
    case .retrying(let attempt, let reason):
      line(ANSI.dim(clean("  ↻ \(who)retrying (attempt \(attempt): \(String(reason.prefix(100))))")))

    case .truncated:
      // Always named (a cut-off reply changes what the report holds), `[name#id]` while several run.
      let subject = who.isEmpty ? "\(name) " : who
      line(ANSI.dim(clean("  ✂ \(subject)reply hit the output limit")))
    // A subagent's checklist: one progress line, not the whole list — its plan is its own
    // business, the lead's transcript only needs to see it is moving.
    case .planUpdated(let steps):
      line(ANSI.dim(clean("  \(who)\(PlanFormat.progressLine(steps))")))

    case .budgetReached(let spent, _):
      line(ANSI.yellow(clean("  ⚠ \(name) hit its budget ($\(String(format: "%.4f", spent))) — report may be incomplete")))

    case .compacted(let summarized, _):
      line(ANSI.dim(clean("  ◈ \(name) compacted \(summarized) messages")))

    // A subagent's request view cleared old results / ran out of room: dim, named like the
    // compaction line (its window is its own, but a warning changes what the report can hold).
    case .toolResultsCleared(let count, _):
      line(ANSI.dim(clean("  ◈ \(name) cleared \(count) older tool result\(count == 1 ? "" : "s") from its request")))

    case .contextWarning(let message):
      line(ANSI.yellow(clean("  ⚠ \(name) context: \(String(message.prefix(100))) — report may be incomplete")))

    // A subagent's own delegations (`subagents.maxDepth` > 1): its ◇/◆ lines indented under
    // its own, and the grandchild's events one level deeper still, flattened as `a › b`. The
    // delegating subagent is always named on these lines (`◇ helper › leaf#id`), whether or
    // not several subagents are in flight — a `›` with nothing before it names no one.
    case .subagentStarted(let inner, let innerId, let model, let task):
      let parent = who.isEmpty ? "\(name) " : who
      let preview = task.replacingOccurrences(of: "\n", with: " ")
      line(ANSI.secondary(clean("  ◇ \(parent)› \(inner)#\(innerId) ")) + ANSI.dim(clean("(\(model)) \(String(preview.prefix(80)))\(preview.count > 80 ? "…" : "")")))

    case .subagentBackgrounded(let inner, let innerId, let model):
      let parent = who.isEmpty ? "\(name) " : who
      line(ANSI.secondary(clean("  ◇ \(parent)› \(inner)#\(innerId) ")) + ANSI.dim(clean("(\(model)) … [background]")))

    case .subagentBlocked(let inner, _, let reason):
      let parent = who.isEmpty ? "\(name) " : who
      line(ANSI.yellow(clean("  ⊘ \(parent)› \(inner) blocked by hook: \(String(reason.prefix(120)))")))

    case .subagentFinished(let inner, let innerId, let steps, let toolCalls, let costUSD, _):
      let parent = who.isEmpty ? "\(name) " : who
      line(ANSI.secondary(clean("  ◆ \(parent)› \(inner)#\(innerId)"))
        + ANSI.dim(" · \(steps) steps · \(toolCalls) tools · \(Self.usd(costUSD))"))

    case .subagent(let inner, let innerId, let innerEvent):
      renderNested("\(name) › \(inner)", innerId, innerEvent)

    default:
      break // prose stays in the subagent's context; the finish line carries the summary
    }
  }

  /// A subagent's display name: `explore` alone, `explore#a1b2c3d4` while several runs are
  /// in flight and the name no longer identifies one.
  private func label(_ name: String, _ id: String) -> String {
    activeSubagents.count > 1 ? "\(name)#\(id)" : name
  }

  private func endStreamedLineIfNeeded() {
    if printedDelta || printedReasoning {
      endLine(markdown.flush())
      printedDelta = false
      printedReasoning = false
    }
  }

  /// What an Esc/Ctrl-C interrupt prints. Cancelling the turn cancels the event stream's
  /// *consumer*, so the session's own `.interrupted` event never arrives — the REPL calls
  /// this instead: closes any mid-stream line and prints the notice the event would have.
  func showInterrupted() {
    endStreamedLineIfNeeded()
    line(ANSI.yellow("⏹ interrupted"))
  }

  static func usd(_ value: Double) -> String {
    String(format: "$%.4f", value)
  }

  static func seconds(_ value: Double) -> String {
    value >= 60
      ? String(format: "%dm%02ds", Int(value) / 60, Int(value) % 60)
      : String(format: "%.1fs", value)
  }

  // MARK: Concise tool lines

  /// Keys worth showing on a one-line call summary, in preference order — the file
  /// being touched, the command being run, the pattern being searched.
  private static let salientKeys = ["path", "file_path", "command", "pattern", "query", "url", "name"]

  /// The single most useful argument value, cwd-relative and truncated, for the
  /// concise `• tool value` line. Falls back to the first string value so MCP tools
  /// with arbitrary schemas still show something.
  static func conciseArguments(_ argumentsJSON: String) -> String {
    guard
      let data = argumentsJSON.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return "" }
    var value = salientKeys.lazy
      .compactMap { object[$0] as? String }
      .first { !$0.isEmpty }
    if value == nil {
      value = object.sorted { $0.key < $1.key }
        .compactMap { $0.value as? String }
        .first { !$0.isEmpty }
    }
    guard var text = value else { return "" }
    text = text.replacingOccurrences(of: "\n", with: " ")
    let cwd = FileManager.default.currentDirectoryPath + "/"
    if text.hasPrefix(cwd) {
      text = String(text.dropFirst(cwd.count))
    }
    return text.count > 80 ? String(text.prefix(79)) + "…" : text
  }
}
