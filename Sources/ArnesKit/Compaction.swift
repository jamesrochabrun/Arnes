import Foundation
import OpenRouterSwift

// MARK: - CompactionPolicy

/// How a session keeps a long conversation inside the model's context window (C2): when the
/// summarizer runs, how many recent tool results the request-time view keeps verbatim, how small a
/// result must be to stay whatever its age, and how many emergency summaries one turn may take.
/// The CLI reads it from the top-level `compaction` block of `~/.arnes/config.json`
/// (`CompactionConfig`); panels and evals keep the defaults.
public struct CompactionPolicy: Sendable, Equatable {
  /// Fraction of the model's context window at which a turn start summarizes older turns (after
  /// clearing alone proved insufficient) and a step mid-turn clears older tool results.
  public var threshold: Double
  /// Tool results kept verbatim in the request view — the most recent ones, whatever their size.
  public var keepRecentToolResults: Int
  /// A tool result shorter than this many characters is never cleared: it is cheap to keep and
  /// often the fact the model came for.
  public var clearMinChars: Int
  /// Emergency summaries one turn may take when the window is estimated to stay nearly full after
  /// clearing (`emergencyThreshold`); a failed attempt counts; past the cap the turn runs on with
  /// one `contextWarning`.
  public var maxPerTurn: Int
  /// Image attachments (a `view_image` result's picture) kept in the request view among those
  /// below the clearing cutoff — the most recent ones; older ones become their caption plus a
  /// recall hint, so a screenshot viewed long ago stops riding every request. Attachments above
  /// the cutoff (recent) always stay. 0 = every image below the cutoff is stubbed.
  public var keepRecentImages: Int

  public static let defaultThreshold = 0.8
  public static let defaultKeepRecentToolResults = 6
  public static let defaultClearMinChars = 2000
  public static let defaultMaxPerTurn = 2
  public static let defaultKeepRecentImages = 1
  /// The fraction of the window a step's request must still be estimated at — after what its
  /// clearing freed, at `Microcompaction.charsPerToken` — for the turn's own exchanges to be
  /// summarized (the emergency path) — fixed: a dial here would only move the cliff.
  public static let emergencyThreshold = 0.95

  public init(
    threshold: Double = CompactionPolicy.defaultThreshold,
    keepRecentToolResults: Int = CompactionPolicy.defaultKeepRecentToolResults,
    clearMinChars: Int = CompactionPolicy.defaultClearMinChars,
    maxPerTurn: Int = CompactionPolicy.defaultMaxPerTurn,
    keepRecentImages: Int = CompactionPolicy.defaultKeepRecentImages)
  {
    // Clamped, never trusted: a threshold outside (0, 1] would summarize every turn or never, a
    // negative count is no count.
    self.threshold = threshold > 0 && threshold <= 1 ? threshold : Self.defaultThreshold
    self.keepRecentToolResults = max(0, keepRecentToolResults)
    self.clearMinChars = max(0, clearMinChars)
    self.maxPerTurn = max(0, maxPerTurn)
    self.keepRecentImages = max(0, keepRecentImages)
  }

  public static let `default` = CompactionPolicy()
}

// MARK: - Microcompaction

/// The request-time **view** of a history: older, large tool results replaced by a one-line stub,
/// the persisted `Session.history` untouched (a resumed session, the transcript on disk and
/// `arnes runs` see the real results — re-reading them on resume is correct, the model then has
/// them back). Pure functions over `[Message]`; the session decides the cutoff.
///
/// Stability is the contract a prompt cache relies on: a message is either stubbed or it isn't,
/// and the set of stubbed messages only grows — the cutoff advances at turn boundaries and at a
/// mid-turn relief point, never on every step and never backwards within a turn. Only the
/// *content* of a `.tool` message changes; no message is ever dropped, so every `tool_calls`
/// message keeps its results beside it.
public enum Microcompaction {
  /// The bytes-per-token estimate the dry run at turn start uses for what clearing freed.
  public static let charsPerToken = 4

  /// What clearing below a cutoff does: how many results were stubbed and how many characters of
  /// content the request no longer carries; `images` counts the attachments stubbed too — apart,
  /// because an image's base64 bytes are not text tokens (a provider bills a picture by its
  /// pixels), so they never enter `freedChars` and the turn-start estimate stays conservative.
  public struct Clearance: Sendable, Equatable {
    public var count: Int
    public var freedChars: Int
    public var images: Int

    public init(count: Int = 0, freedChars: Int = 0, images: Int = 0) {
      self.count = count
      self.freedChars = freedChars
      self.images = images
    }

    public static func - (lhs: Clearance, rhs: Clearance) -> Clearance {
      Clearance(count: lhs.count - rhs.count, freedChars: lhs.freedChars - rhs.freedChars, images: lhs.images - rhs.images)
    }
  }

  /// The history index below which tool results are eligible for clearing when the last
  /// `keepRecent` of them stay verbatim: the index of the `keepRecent`-th most recent `.tool`
  /// message (0 when there are fewer, `history.count` when none is kept). Everything at or after
  /// it — the recent results and whatever sits between them — is left alone.
  public static func clearingCutoff(in history: [Message], keepingRecent keepRecent: Int) -> Int {
    guard keepRecent > 0 else { return history.count }
    var seen = 0
    for index in history.indices.reversed() where history[index].role == .tool {
      seen += 1
      if seen == keepRecent { return index }
    }
    return 0
  }

  /// The request view: every `.tool` message below `cutoff` whose text content is at least
  /// `policy.clearMinChars` characters is replaced by its stub, and every image attachment below
  /// it but the last `policy.keepRecentImages` of them by its caption plus a recall hint;
  /// everything else is the history's own message. `cutoff` is clamped to the history.
  public static func view(of history: [Message], clearedBelow cutoff: Int, policy: CompactionPolicy) -> [Message] {
    let limit = min(max(cutoff, 0), history.count)
    guard limit > 0 else { return history }
    var view = history
    var names: [String: String] = [:]
    for index in 0..<limit {
      let message = history[index]
      switch message.role {
      case .assistant:
        for call in message.toolCalls ?? [] {
          if let id = call.id, let name = call.function?.name { names[id] = name }
        }
      case .tool:
        guard case .text(let text)? = message.content else { continue }
        let tool = message.toolCallId.flatMap { names[$0] } ?? "tool"
        if let cleared = clearedContent(text, tool: tool, minChars: policy.clearMinChars) {
          var stubbed = message
          stubbed.content = .text(cleared)
          view[index] = stubbed
        }
      default:
        continue
      }
    }
    for index in clearableImageIndices(in: history, below: limit, keeping: policy.keepRecentImages) {
      var stubbed = history[index]
      // The same content kind as the attachment (`.parts`), so every dialect's translator takes
      // the stub down the path it took the image — joined onto the tool results it follows.
      stubbed.content = .parts([.text(imageStub(caption: history[index].content?.plainText ?? ""))])
      view[index] = stubbed
    }
    return view
  }

  /// Whether `message` is an image attachment: a `.parts` user message carrying an image part
  /// (what `view_image` appends after a step's results).
  public static func isImageAttachment(_ message: Message) -> Bool {
    guard message.role == .user, case .parts(let parts)? = message.content else { return false }
    return parts.contains { if case .imageURL = $0 { return true } else { return false } }
  }

  /// The indices of the image attachments below `limit` that the view stubs: all of them but the
  /// last `keep` (the most recently viewed stay — "the screenshot" the user refers back to).
  static func clearableImageIndices(in history: [Message], below limit: Int, keeping keep: Int) -> [Int] {
    let images = history.indices.filter { $0 < limit && isImageAttachment(history[$0]) }
    return Array(images.dropLast(max(0, keep)))
  }

  /// The replacement for a cleared attachment: the caption the attachment carried (`Image from
  /// view_image <path>:`), then how to see the picture again.
  public static func imageStub(caption: String) -> String {
    let note = "[arnes: the image was removed from the request to free context — call view_image again if you need to see it]"
    let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? note : trimmed + "\n" + note
  }

  /// What `view(of:clearedBelow:policy:)` would clear below `cutoff` — the count and the freed
  /// characters — without building the view. The turn-start dry run compares two of these.
  public static func clearance(of history: [Message], below cutoff: Int, policy: CompactionPolicy) -> Clearance {
    let limit = min(max(cutoff, 0), history.count)
    var result = Clearance()
    guard limit > 0 else { return result }
    var names: [String: String] = [:]
    for index in 0..<limit {
      let message = history[index]
      switch message.role {
      case .assistant:
        for call in message.toolCalls ?? [] {
          if let id = call.id, let name = call.function?.name { names[id] = name }
        }
      case .tool:
        guard case .text(let text)? = message.content else { continue }
        let tool = message.toolCallId.flatMap { names[$0] } ?? "tool"
        if let cleared = clearedContent(text, tool: tool, minChars: policy.clearMinChars) {
          result.count += 1
          result.freedChars += text.count - cleared.count
        }
      default:
        continue
      }
    }
    result.images = clearableImageIndices(in: history, below: limit, keeping: policy.keepRecentImages).count
    return result
  }

  /// The hint a stub ends with — how the model can have the content again. Nothing for a result
  /// that cannot be had again by calling the tool again: a `task` result is a subagent's report
  /// (re-calling runs another subagent), an `ask_user` answer is the user's (re-asking is wrong), a
  /// `write_file` result names a write already done, a `job` poll's tail is gone (the next poll
  /// shows what came after). An `edit_file` result is the post-edit window — the file is the thing
  /// to read, re-applying the edit would fail on `old` text that is gone. A `bash` command is
  /// re-run, not "called" (the gate still applies to a mutation). Every other tool — `read_file`,
  /// `grep`, `glob`, `skill`, an MCP tool — is simply called again.
  static func recallHint(for tool: String) -> String {
    switch tool {
    case "task", "ask_user", "write_file", "job": return ""
    case "edit_file": return " — read_file the file if you need to see it again"
    case "bash": return " — re-run the command if you need its output again"
    default: return " — call the tool again if you need it"
    }
  }

  /// The one-line replacement for a cleared result's content.
  public static func stub(tool: String, chars: Int) -> String {
    "[arnes: cleared \(tool) result (\(chars) chars) to free context\(recallHint(for: tool))]"
  }

  /// The replacement for a cleared result whose first line is kept (an `error:` result).
  public static func stubAfterFirstLine(tool: String, chars: Int) -> String {
    "[arnes: cleared the rest of this \(tool) result (\(chars) chars) to free context\(recallHint(for: tool))]"
  }

  /// How many characters of a kept error line survive — enough for the message, not a dump.
  static let keptFirstLineChars = 500

  /// The cleared content for one tool result's text, or nil when it is too small to clear
  /// (`minChars` applies to the result's own body). Frame-aware: a result framed by the guard
  /// (`<tool_result source=… nonce=…>` … `</tool_result nonce=…>`, S6) keeps its two frame lines
  /// around the stub, so the frame's integrity never depends on what was cleared. A body whose
  /// first line is an `error:` keeps that line — failures stay in context — and stubs the rest.
  public static func clearedContent(_ text: String, tool: String, minChars: Int) -> String? {
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var opening: Substring?
    var closing: Substring?
    if lines.count >= 2,
       let first = lines.first, first.hasPrefix("<tool_result "),
       let last = lines.last, last.hasPrefix("</tool_result ")
    {
      opening = lines.removeFirst()
      closing = lines.removeLast()
    }
    let body = lines.joined(separator: "\n")
    guard body.count >= max(minChars, 1) else { return nil }
    let replacement: String
    if body.hasPrefix(Session.toolErrorPrefix), let firstLine = lines.first {
      let kept = firstLine.count > keptFirstLineChars
        ? String(firstLine.prefix(keptFirstLineChars)) + "…"
        : String(firstLine)
      replacement = kept + "\n" + stubAfterFirstLine(tool: tool, chars: body.count - firstLine.count)
    } else {
      replacement = stub(tool: tool, chars: body.count)
    }
    return [opening.map(String.init), replacement, closing.map(String.init)]
      .compactMap { $0 }
      .joined(separator: "\n")
  }
}

// MARK: - CompactionRubric

/// What a compaction's summarizer must be shown besides the transcript so the notes carry the
/// facts a continuing model cannot re-derive: the files the dropped turns touched (from the
/// `read_file`/`write_file`/`edit_file` calls) and the checklist the model posted last with
/// `update_plan` — `Session.lastPlanSteps` reads that call off `history`, so after a compaction
/// summarized it away the plan lives on only in the note.
public enum CompactionRubric {
  /// The tools whose `path` argument names a file the turn touched, with the verb the note uses.
  static let pathTools: [String: String] = [
    "read_file": "read",
    "write_file": "written",
    "edit_file": "edited",
  ]

  /// At most this many paths are listed; the rest are counted.
  static let maxPaths = 40

  /// `path → verbs` in first-seen order over the messages' tool calls (`a.swift — read, edited`).
  public static func touchedPaths(in messages: [Message]) -> [(path: String, verbs: [String])] {
    var order: [String] = []
    var verbs: [String: [String]] = [:]
    for message in messages where message.role == .assistant {
      for call in message.toolCalls ?? [] {
        guard let name = call.function?.name, let verb = pathTools[name],
              let arguments = Session.decodeArgumentObject(call.function?.arguments ?? ""),
              let path = arguments["path"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty
        else { continue }
        if verbs[path] == nil {
          order.append(path)
          verbs[path] = []
        }
        if verbs[path]?.contains(verb) == false { verbs[path]?.append(verb) }
      }
    }
    return order.map { (path: $0, verbs: verbs[$0] ?? []) }
  }

  /// The `[files touched]` section for the summarizer, or nil when no path tool was called.
  public static func touchedPathsSection(in messages: [Message]) -> String? {
    let touched = touchedPaths(in: messages)
    guard !touched.isEmpty else { return nil }
    var lines = touched.prefix(maxPaths).map { "- \($0.path) — \($0.verbs.joined(separator: ", "))" }
    if touched.count > maxPaths {
      lines.append("(\(touched.count - maxPaths) more)")
    }
    return "[files touched]\n" + lines.joined(separator: "\n")
  }

  /// The `[current plan]` section — the last `update_plan` call's checklist, one `[x]`/`[~]`/`[ ]`
  /// line per step — or nil when the messages hold no usable plan.
  public static func planSection(in messages: [Message]) -> String? {
    for message in messages.reversed() where message.role == .assistant {
      for call in (message.toolCalls ?? []).reversed() where call.function?.name == PlanTool.toolName {
        let steps = PlanTool.planSteps(fromArgumentsJSON: call.function?.arguments ?? "")
        guard !steps.isEmpty else { continue }
        let lines = steps.map { step -> String in
          let mark: String
          switch step.status {
          case "completed": mark = "[x]"
          case "in_progress": mark = "[~]"
          default: mark = "[ ]"
          }
          return "\(mark) \(step.text)"
        }
        return "[current plan]\n" + lines.joined(separator: "\n")
      }
    }
    return nil
  }
}
