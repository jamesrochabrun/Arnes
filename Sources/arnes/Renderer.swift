import ArnesKit
import Foundation

/// Renders `AgentEvent`s to the terminal: streamed text markdown-styled, tool activity
/// dimmed, routing in cyan, and a cost/route status line after each turn.
///
/// Tool activity is concise by default (one line per call, salient argument only);
/// Ctrl-O toggles the verbose form with raw arguments and result previews.
final class Renderer {
  /// Whether any text deltas were printed for the current step (so the duplicate
  /// `assistantText` can be skipped and we just terminate the line).
  private var printedDelta = false
  private var printedReasoning = false
  private var markdown = StreamingMarkdown()

  /// When set, all output routes through the pinned-bar screen; nil keeps the plain
  /// top-to-bottom printing used by piped sessions.
  private let screen: Screen?

  init(screen: Screen? = nil) {
    self.screen = screen
  }

  /// A committed transcript line.
  private func line(_ text: String) {
    if let screen {
      screen.print(text)
    } else {
      Swift.print(text)
    }
  }

  /// Streamed styled text; the screen keeps the open line inside the bar region.
  private func streamOut(_ text: String) {
    if let screen {
      screen.stream(text)
    } else {
      Swift.print(text, terminator: "")
      fflush(stdout)
    }
  }

  /// Ends an open streamed line (plus a final styled tail).
  private func endLine(_ tail: String = "") {
    if let screen {
      screen.stream(tail)
      screen.finishStream()
    } else {
      Swift.print(tail)
    }
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

  func beginTurn() {
    printedDelta = false
    printedReasoning = false
    markdown = StreamingMarkdown()
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
      streamOut(markdown.feed(delta))

    case .reasoningDelta(let delta):
      printedReasoning = true
      streamOut(ANSI.dim(delta))

    case .assistantText(let text):
      if printedDelta {
        // The streamed deltas already showed the text; emit what's still buffered
        // (a partial line, open styles) and end the line.
        endLine(markdown.flush())
      } else {
        line(markdown.feed(text) + markdown.flush())
      }
      printedDelta = false

    case .toolCall(let name, let arguments):
      endStreamedLineIfNeeded()
      if verbose {
        line(ANSI.dim("→ \(name) \(String(arguments.prefix(120)))"))
      } else {
        line(ANSI.dim("• \(name) \(Self.conciseArguments(arguments))"))
      }

    case .toolResult(let name, let preview):
      let firstLine = preview.split(separator: "\n").first.map(String.init) ?? preview
      if verbose {
        line(ANSI.dim("← \(name): \(String(firstLine.prefix(120)))"))
      } else if firstLine.hasPrefix("error") || firstLine.hasPrefix("user denied") {
        // Concise mode stays quiet on success; failures still surface.
        line(ANSI.red("✗ \(name): \(String(firstLine.prefix(120)))"))
      }

    case .toolDenied(let name, _):
      line(ANSI.yellow("⊘ \(name) denied"))

    case .routed(let model, let provider):
      endStreamedLineIfNeeded()
      line(ANSI.secondary("⇄ \(model)\(provider.map { " (\($0))" } ?? "")"))

    case .dialectFellBack(let dialect, let reason):
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⤵ \(dialect) dialect failed (\(String(reason.prefix(80)))) — fell back to chat, recorded"))

    case .verifier(let passed, let verdict):
      line(passed ? ANSI.green("✔ \(verdict)") : ANSI.red("✘ \(verdict)"))

    case .interrupted:
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⏹ interrupted"))

    case .nudged:
      endStreamedLineIfNeeded()
      line(ANSI.dim("↻ paused without finishing — nudged to continue"))

    case .stepLimitReached(let maxSteps):
      endStreamedLineIfNeeded()
      line(ANSI.yellow("⚠ step limit (\(maxSteps)) reached — the task may be unfinished; say \"continue\" to keep going"))

    case .compacted(let summarized, let kept):
      endStreamedLineIfNeeded()
      line(ANSI.dim("◈ context compacted: \(summarized) older messages summarized · \(kept) kept verbatim"))

    case .subagentStarted(let name, let model, let task):
      endStreamedLineIfNeeded()
      let preview = task.replacingOccurrences(of: "\n", with: " ")
      line(ANSI.secondary("◇ \(name) ") + ANSI.dim("(\(model)) \(String(preview.prefix(80)))\(preview.count > 80 ? "…" : "")"))

    case .subagent(let name, let event):
      renderNested(name, event)

    case .subagentFinished(let name, let steps, let toolCalls, let costUSD, let preview):
      endStreamedLineIfNeeded()
      var footer = ANSI.secondary("◆ \(name)")
        + ANSI.dim(" · \(steps) steps · \(toolCalls) tools · \(Self.usd(costUSD))")
      if !verbose, !preview.isEmpty, preview != "failed" {
        let first = preview.split(separator: "\n").first.map(String.init) ?? preview
        footer += ANSI.dim(" · \(String(first.prefix(60)))\(first.count > 60 ? "…" : "")")
      }
      line(footer)

    case .turnFinished(let stats):
      endStreamedLineIfNeeded()
      let served = stats.routedModels.joined(separator: ", ")
      let route = served.isEmpty || served == stats.requestedModel
        ? stats.requestedModel
        : "\(stats.requestedModel) → \(served)"
      var footer = "─ \(route) · \(stats.steps) steps · \(stats.toolCalls) tools · "
        + "turn \(Self.usd(stats.turnCostUSD)) · session \(Self.usd(stats.sessionCostUSD))"
      if let used = stats.promptTokens, let context = stats.contextLength, context > 0 {
        footer += " · ctx \(used * 100 / context)%"
      }
      line(ANSI.dim(footer))
    }
  }

  /// A subagent's own loop events, rendered indented under its ◇ start line. The
  /// subagent's streamed prose stays hidden — only its tool activity and hiccups
  /// show; the distilled report lands on the ◆ finish line and goes to the lead.
  private func renderNested(_ name: String, _ event: AgentEvent) {
    switch event {
    case .toolCall(let tool, let arguments):
      endStreamedLineIfNeeded()
      if verbose {
        line(ANSI.dim("  → \(tool) \(String(arguments.prefix(110)))"))
      } else {
        line(ANSI.dim("  ∙ \(tool) \(Self.conciseArguments(arguments))"))
      }

    case .toolResult(let tool, let preview):
      let firstLine = preview.split(separator: "\n").first.map(String.init) ?? preview
      if verbose {
        line(ANSI.dim("  ← \(tool): \(String(firstLine.prefix(110)))"))
      } else if firstLine.hasPrefix("error") || firstLine.hasPrefix("user denied") {
        line(ANSI.red("  ✗ \(tool): \(String(firstLine.prefix(110)))"))
      }

    case .toolDenied(let tool, _):
      line(ANSI.yellow("  ⊘ \(tool) denied"))

    case .routed(let model, let provider):
      if verbose {
        line(ANSI.dim("  ⇄ \(model)\(provider.map { " (\($0))" } ?? "")"))
      }

    case .dialectFellBack(let dialect, _):
      line(ANSI.dim("  ⤵ \(dialect) fell back to chat"))

    case .nudged:
      if verbose {
        line(ANSI.dim("  ↻ \(name) nudged to continue"))
      }

    case .stepLimitReached(let maxSteps):
      line(ANSI.yellow("  ⚠ \(name) hit its step limit (\(maxSteps)) — report may be incomplete"))

    case .compacted(let summarized, _):
      line(ANSI.dim("  ◈ \(name) compacted \(summarized) messages"))

    case .textDelta, .reasoningDelta, .assistantText, .verifier, .interrupted,
         .turnFinished, .subagentStarted, .subagent, .subagentFinished:
      break // prose stays in the subagent's context; the finish line carries the summary
    }
  }

  private func endStreamedLineIfNeeded() {
    if printedDelta || printedReasoning {
      endLine(markdown.flush())
      printedDelta = false
      printedReasoning = false
    }
  }

  static func usd(_ value: Double) -> String {
    String(format: "$%.4f", value)
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
