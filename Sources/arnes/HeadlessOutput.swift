import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - HeadlessOutputFormat

/// How `arnes do` reports: today's human-readable lines, one JSON envelope, or a JSON object
/// per line. The `text` bytes are a contract of their own (the Terminal-Bench adapter and the
/// agent skill read them), guarded by a golden test.
enum HeadlessOutputFormat: String, ExpressibleByArgument, CaseIterable {
  case text
  /// Nothing on stdout until the run ends, then one `RunResult` line.
  case json
  /// `{"type":"init",…}` first, one object per event, the `RunResult` last.
  case streamJson = "stream-json"
}

// MARK: - InitInfo

/// The first `stream-json` line: what this run was assembled from, so a consumer can tell a
/// bare run from one with MCP servers and hooks before the first event arrives.
struct InitInfo: Encodable, Sendable {
  struct MCPServer: Encodable, Sendable {
    let name: String
    let tools: Int
    let error: String?
  }

  var type = "init"
  /// Filled in when the session exists (`Agent.onSessionStart`) — the run's id.
  var sessionId: String
  var version: String
  var model: String
  /// The requested wire dialect (`auto` follows the model; the record says what executed).
  var dialect: String
  var provider: String
  var cwd: String
  var tools: [String]
  var mcpServers: [MCPServer]
  var skills: [String]
  var agents: [String]
  var hooks: Int
  /// `sandbox` / `sandbox no-net` when the run is confined, nil when not.
  var sandbox: String?
  var effort: String?
  /// The permission mode the run started under (`default`, `acceptEdits`, `plan`, `bypass`);
  /// `plan` is how a consumer tells a dry run from a real one before the result arrives.
  var permissionMode: String = "default"
  /// `--agent <name>`: the definition the lead runs as; omitted on a plain run.
  var agent: String?
  /// `true` when the task continued a saved session (`--resume`/`--continue`, fork included);
  /// omitted on a fresh one, so an older consumer sees the same keys it always did.
  var resumed: Bool?
  /// `--fork`: the id of the session this run's transcript was copied from.
  var forkedFrom: String?
  /// H1: the toolset's tools the model is *not* offered — every `CapabilityGatedTool` its
  /// manifest rules out (`view_image` for a text model), so `tools` is the offered set and a
  /// missing name is visible rather than silent. Empty when nothing was withheld.
  var withheldTools: [String] = []

  enum CodingKeys: String, CodingKey {
    case type
    case sessionId = "session_id"
    case version
    case model
    case dialect
    case provider
    case cwd
    case tools
    case mcpServers = "mcp_servers"
    case skills
    case agents
    case hooks
    case sandbox
    case effort
    case permissionMode = "permission_mode"
    case agent
    case resumed
    case forkedFrom = "forked_from"
    case withheldTools = "withheld_tools"
  }
}

// MARK: - HeadlessEmitter

/// Where `arnes do` puts its output, per format. One class owns all three so the event loop
/// in `Do.run` calls `emit` and never branches on the format itself.
///
/// - `text`: exactly the lines `Do.run` printed before this existed, plus the same footer.
/// - `json`: stdout stays silent until `finish`; `--verbose` mirrors the text lines to stderr.
/// - `stream-json`: `emitInit` first, one `EventJSON` line per event (deltas only with
///   `--include-partial`), the `RunResult` last; `--verbose` mirrors text lines to stderr.
///
/// The sinks are injectable so tests capture the exact bytes; the defaults are stdout/stderr.
/// Text lines are terminal-sanitized as before (a no-op when piped); JSON is escaped by the
/// encoder and never sanitized.
final class HeadlessEmitter: @unchecked Sendable {
  let format: HeadlessOutputFormat
  let includePartial: Bool
  let verbose: Bool
  private let out: (String) -> Void
  private let err: (String) -> Void
  private let lock = NSLock()
  private var sessionId = ""
  private var capturedVerdict: String?

  init(
    format: HeadlessOutputFormat,
    includePartial: Bool = false,
    verbose: Bool = false,
    // Flushed per line: a piped stdout is fully buffered, and a consumer of `stream-json`
    // (or of the text progress) is reading live — a 60 s tool call must not hold back the
    // events before it.
    stdout: @escaping (String) -> Void = { print($0); fflush(Foundation.stdout) },
    stderr: @escaping (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
  {
    self.format = format
    self.includePartial = includePartial
    self.verbose = verbose
    out = stdout
    err = stderr
  }

  /// The verifier's text, once a `.verifier` event passed through — the `RunResult` carries it.
  var verdict: String? {
    lock.withLock { capturedVerdict }
  }

  /// Announces the run. Prints only in `stream-json`; every format remembers the session id
  /// so later objects carry it.
  func emitInit(_ info: InitInfo) {
    lock.withLock { sessionId = info.sessionId }
    if format == .streamJson {
      out(HeadlessJSON.line(info))
    }
  }

  func emit(_ event: AgentEvent) {
    if case .verifier(_, let verdict) = event {
      lock.withLock { capturedVerdict = verdict }
    }
    switch format {
    case .text:
      if let line = Self.textLine(for: event) {
        // A retry is progress chatter about the wire, not the run's output: stderr, so a
        // script reading text mode's stdout never sees it (and the golden bytes hold).
        if Self.isRetryChatter(event) {
          err(line)
        } else {
          out(line)
        }
      }
      // The structured answer itself, on its own line after the status: a script reading text
      // mode still gets the object (a run without a schema never fires this event, so the
      // golden bytes hold). Never sanitized — the encoder escaped it.
      if case .structuredOutput(let json?, true, _) = event {
        out(HeadlessJSON.line(json))
      }
    case .json:
      if verbose, let line = Self.textLine(for: event) {
        err(line)
      }
    case .streamJson:
      if verbose, let line = Self.textLine(for: event) {
        err(line)
      }
      switch event {
      case .textDelta, .reasoningDelta:
        guard includePartial else { return }
      default:
        break
      }
      let id = lock.withLock { sessionId }
      out(event.jsonLine(sessionId: id))
    }
  }

  /// The run's last word: the text footer, or the `RunResult` line.
  func finish(_ result: RunResult) {
    switch format {
    case .text:
      out(Self.footer(for: result))
    case .json, .streamJson:
      out(HeadlessJSON.line(result))
    }
  }

  // MARK: Text mode (byte-for-byte the pre-X1 `Do.run` output)

  /// One human-readable line per event, or nil for the events headless text never printed
  /// (deltas, the interrupt, the footer event, nested subagent prose). Sanitized the way the
  /// old `say` closure did — `TerminalText.sanitize` is TTY-gated, so piped bytes are exact.
  static func textLine(for event: AgentEvent) -> String? {
    let line: String
    switch event {
    case .assistantText(let text):
      line = text
    case .toolCall(let name, let arguments):
      line = "→ \(name) \(arguments.prefix(120))"
    case .toolResult(let name, let preview):
      line = "← \(name): \(preview)"
    case .toolDenied(let name, _):
      line = "⊘ \(name) denied"
    // The model asked; the tool-result line right after carries the headless answer ("cannot
    // ask the user"), so the pair reads as the exchange it was.
    case .userQuestion(let question, let options):
      line = "? \(question)" + (options.isEmpty ? "" : " [\(options.joined(separator: " | "))]")
    case .verifier(let passed, let verdict):
      line = passed ? "✔ \(verdict)" : "✘ \(verdict)"
    case .structuredOutput(_, let valid, let errors):
      line = valid
        ? "✓ structured output valid"
        : "✗ structured output invalid: \(errors.first.map { String($0.prefix(200)) } ?? "no valid reply")"
    case .routed(let model, let provider):
      line = "⇄ routed to \(model)\(provider.map { " (\($0))" } ?? "")"
    case .dialectFellBack(let dialect, let reason):
      line = "⤵ \(dialect) dialect failed (\(reason.prefix(80))) — fell back to chat"
    case .settingIgnored(let setting, let reason):
      line = "⚠ --\(setting) has no effect: \(reason)"
    case .compacted(let summarized, _):
      line = "◈ compacted \(summarized) older messages"
    // Microcompaction (C2): older tool results stubbed in the request view — the persisted history
    // is untouched — and the once-per-turn warning when nothing is left to clear.
    case .toolResultsCleared(let count, let freedChars):
      line = "◈ cleared \(count) older tool result\(count == 1 ? "" : "s") from the request (\(freedChars) chars)"
    case .contextWarning(let message):
      line = "⚠ context: \(message.prefix(200))"
    case .nudged:
      line = "↻ paused without finishing — nudged to continue"
    case .stepLimitReached(let maxSteps):
      line = "⚠ step limit (\(maxSteps)) reached before the task finished"
    case .budgetReached(let spent, let budget):
      line = "⚠ budget reached ($\(String(format: "%.4f", spent)) ≥ $\(String(format: "%.4f", budget))) — stopped before finishing"
    case .hookNotice(let event, let output):
      line = "⎔ \(event) hook: \(output)"
    case .hookBlocked(let tool, let reason):
      line = "⊘ \(tool) blocked by hook: \(reason.prefix(120))"
    case .hookStopped(let reason):
      line = "⏹ turn ended by hook\(reason.map { ": \($0)" } ?? "")"
    case .promptBlocked(let reason):
      line = "⊘ prompt blocked by hook: \(reason.prefix(200))"
    case .deniedLoop(let count):
      line = "⊘ stopped after \(count) consecutive denials"
    case .stuckDetected(let reason):
      line = "⚠ stuck: \(reason.prefix(120))"
    case .contentFlagged(let tool, let patterns):
      line = "⚠ flagged: \(tool) result matched \(patterns.joined(separator: ", ")) — treated as data"
    // Background shell jobs: the start (the command, clipped) and the exit seen mid-turn.
    case .jobStarted(let id, let command):
      line = "⧗ job \(id) started: \(command.prefix(80))"
    case .jobFinished(let id, let exitStatus):
      line = "⧗ job \(id) finished (exit \(exitStatus))"
    case .retrying(let attempt, let reason):
      line = "↻ retrying (attempt \(attempt): \(reason.prefix(120)))"
    case .truncated:
      line = "✂ reply hit the output limit"
    // The model's checklist, one line: done/total and the step in flight (the first pending one
    // when none is marked in_progress).
    case .planUpdated(let steps):
      line = PlanFormat.progressLine(steps)
    // Subagent progress rides the same stream (the task tool emits into the turn), and a
    // step can delegate several times at once — so every line names the run (`agent#id`,
    // the nested session's id) rather than just the agent.
    case .subagentBlocked(let name, let id, let reason):
      line = "⊘ \(name)#\(id) blocked by hook: \(reason.prefix(120))"
    case .subagentStarted(let name, let id, let model, let task):
      line = "◇ \(name)#\(id) (\(model)) \(task.prefix(80))"
    // A subagent's hooks are the user's guardrails on delegated work: what they refused, what
    // they said, and a `continue: false` are printed like the lead's own hook lines, indented.
    case .subagent(let name, let id, .hookBlocked(let tool, let reason)):
      line = "  ⊘ [\(name)#\(id)] \(tool) blocked by hook: \(reason.prefix(120))"
    case .subagent(let name, let id, .hookNotice(let event, let output)):
      line = "  ⎔ [\(name)#\(id)] \(event) hook: \(output)"
    case .subagent(let name, let id, .hookStopped(let reason)):
      line = "  ⏹ [\(name)#\(id)] asked to stop by hook\(reason.map { ": \($0)" } ?? "")"
    case .subagent(let name, let id, .toolCall(let tool, let arguments)):
      line = "  ∙ [\(name)#\(id)] \(tool) \(arguments.prefix(100))"
    case .subagent(let name, let id, .stepLimitReached(let maxSteps)):
      line = "  ⚠ [\(name)#\(id)] hit its step limit (\(maxSteps))"
    case .subagent(let name, let id, .stuckDetected(let reason)):
      line = "  ⚠ [\(name)#\(id)] stuck: \(reason.prefix(120))"
    case .subagent(let name, let id, .contentFlagged(let tool, let patterns)):
      line = "  ⚠ [\(name)#\(id)] flagged: \(tool) result matched \(patterns.joined(separator: ", ")) — treated as data"
    case .subagent(let name, let id, .jobStarted(let jobId, let command)):
      line = "  ⧗ [\(name)#\(id)] job \(jobId) started: \(command.prefix(80))"
    case .subagent(let name, let id, .jobFinished(let jobId, let exitStatus)):
      line = "  ⧗ [\(name)#\(id)] job \(jobId) finished (exit \(exitStatus))"
    case .subagent(let name, let id, .retrying(let attempt, let reason)):
      line = "  ↻ [\(name)#\(id)] retrying (attempt \(attempt): \(reason.prefix(120)))"
    case .subagent(let name, let id, .truncated):
      line = "  ✂ [\(name)#\(id)] reply hit the output limit"
    // A subagent's own delegations (`subagents.maxDepth` > 1): its ◇/◆ lines under its name,
    // and a grandchild's events flattened as `a#id › b#id` — one line deeper, never lost.
    case .subagent(let name, let id, .subagentStarted(let inner, let innerId, let model, let task)):
      line = "  ◇ [\(name)#\(id)] › \(inner)#\(innerId) (\(model)) \(task.prefix(80))"
    case .subagent(let name, let id, .subagentBackgrounded(let inner, let innerId, let model)):
      line = "  ◇ [\(name)#\(id)] › \(inner)#\(innerId) (\(model)) … [background]"
    case .subagent(let name, let id, .subagentBlocked(let inner, let innerId, let reason)):
      line = "  ⊘ [\(name)#\(id)] › \(inner)#\(innerId) blocked by hook: \(reason.prefix(120))"
    case .subagent(let name, let id, .subagentFinished(let inner, let innerId, let steps, let toolCalls, let costUSD, _)):
      line = "  ◆ [\(name)#\(id)] › \(inner)#\(innerId) · \(steps) steps · \(toolCalls) tools · $\(String(format: "%.4f", costUSD))"
    case .subagent(let name, let id, .subagent(let inner, let innerId, let innerEvent)):
      return textLine(for: .subagent(name: "\(name)#\(id) › \(inner)", id: innerId, event: innerEvent))
    case .subagentFinished(let name, let id, let steps, let toolCalls, let costUSD, let preview):
      // A background run the turn's end cancelled (or whose report it dropped) says so — the
      // one case where the harness, not the model, wrote the preview.
      let why = preview == "cancelled" || preview == "report dropped" ? " · \(preview)" : ""
      line = "◆ \(name)#\(id) · \(steps) steps · \(toolCalls) tools · $\(String(format: "%.4f", costUSD))" + why
    case .subagentBackgrounded(let name, let id, let model):
      line = "◇ \(name)#\(id) (\(model)) … [background]"
    case .subagentJoining(let pending):
      line = "⧗ waiting for \(pending) background subagent\(pending == 1 ? "" : "s")"
    default:
      return nil // deltas, interrupt, footer and nested prose: headless prints whole messages and its own footer
    }
    return TerminalText.sanitize(line)
  }

  /// A `.retrying` event, the lead's or a subagent's at any depth — the one text line that goes
  /// to stderr instead of stdout.
  static func isRetryChatter(_ event: AgentEvent) -> Bool {
    switch event {
    case .retrying: return true
    case .subagent(_, _, let inner): return isRetryChatter(inner)
    default: return false
    }
  }

  /// The `[requested … → served by …]` footer, unchanged.
  static func footer(for result: RunResult) -> String {
    let routed = result.routedModels.joined(separator: ", ")
    return TerminalText.sanitize(
      "\n[requested \(result.model) → served by \(routed.isEmpty ? "?" : routed) · dialect \(result.dialect ?? "?") · \(result.steps) steps · \(result.toolCalls) tool calls · $\(String(format: "%.4f", result.costUSD))]")
  }
}
