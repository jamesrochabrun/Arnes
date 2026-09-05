import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - RewindSupport

/// What the REPL's `/rewind`, `/undo` and `/diff` work with: the checkpoint store the write
/// tools snapshot into (nil when `checkpoints.enabled` is false) and the run's working directory,
/// sandbox, subprocess environment and path rules — what `/diff` hands `ReviewDiff.build`, so
/// its `git diff` runs exactly as `arnes review`'s would here.
struct RewindSupport {
  let checkpoints: FileCheckpointStore?
  let cwd: URL
  let sandbox: ShellSandbox?
  let environment: SubprocessEnvironment
  let pathRules: PathScope.Rules
}

// MARK: - RewindRequest

/// What `/rewind <n> [code|conversation|both]` asked for. Parsing only; `Interactive` runs it.
struct RewindRequest: Equatable {
  enum Scope: String, Equatable {
    case code
    case conversation
    case both

    var restoresCode: Bool { self != .conversation }
    var restoresConversation: Bool { self != .code }

    /// The words the confirmation question uses.
    var described: String {
      switch self {
      case .code: return "the files changed"
      case .conversation: return "the conversation"
      case .both: return "files and conversation"
      }
    }
  }

  let turn: Int
  let scope: Scope

  /// `"3"` → turn 3, both; `"3 code"` / `"3 conversation"` / `"3 both"`; anything else nil.
  static func parse(_ argument: String) -> RewindRequest? {
    let parts = argument.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    guard let first = parts.first, let turn = Int(first.hasPrefix("#") ? String(first.dropFirst()) : first),
          turn >= 0, parts.count <= 2
    else {
      return nil
    }
    guard parts.count == 2 else { return RewindRequest(turn: turn, scope: .both) }
    guard let scope = Scope(rawValue: parts[1].lowercased()) else { return nil }
    return RewindRequest(turn: turn, scope: scope)
  }

  static let usage = "usage: /rewind [<turn> [code|conversation|both]] — /rewind alone lists the turns"
}

// MARK: - RewindListing

/// The `/rewind` listing: one row per turn still in the conversation — its index, the start of
/// the message that opened it, the files its tools changed — oldest first, then a hint. Pure.
enum RewindListing {
  struct Turn: Equatable {
    let turn: Int
    /// The user message that opened the turn.
    let prompt: String
    /// Paths checkpointed in the turn, as they should be shown (relative to the cwd when under it).
    let files: [String]
  }

  /// How much of the opening message a row shows.
  static let promptChars = 60

  static let empty = "no turns to rewind to yet — send a message first"

  /// - Parameter checkpointOnlyTurns: turns that changed files but are no longer in the
  ///   conversation (compacted away); named so a code-only rewind to them is discoverable.
  static func lines(_ turns: [Turn], checkpointOnlyTurns: [Int] = []) -> [String] {
    guard !turns.isEmpty || !checkpointOnlyTurns.isEmpty else { return [empty] }
    var rows: [String] = []
    let width = max(2, turns.map { String($0.turn).count }.max() ?? 1)
    for entry in turns {
      let label = "#" + String(entry.turn).padding(toLength: width, withPad: " ", startingAt: 0)
      let prompt = firstLine(entry.prompt).padding(toLength: promptChars, withPad: " ", startingAt: 0)
      let files = entry.files.isEmpty ? "" : "  files: " + entry.files.joined(separator: ", ")
      rows.append(TerminalText.sanitize(label + "  " + prompt + files))
    }
    if !checkpointOnlyTurns.isEmpty {
      let named = checkpointOnlyTurns.map { "#\($0)" }.joined(separator: ", ")
      rows.append(ANSI.dim("checkpoints only (no longer in the conversation): \(named) — /rewind <n> code"))
    }
    rows.append(ANSI.dim(
      "/rewind <n> restores files and conversation to the start of turn n (add code or conversation "
        + "for one of them) · /undo puts back the last turn's files · bash edits and commits are not checkpointed"))
    return rows
  }

  /// The first line of a message, clipped to `promptChars` (with an ellipsis when cut).
  static func firstLine(_ text: String) -> String {
    let line = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
      .first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    guard line.count > promptChars else { return line }
    return String(line.prefix(promptChars - 1)) + "…"
  }

  /// `path` relative to `cwd` when it lies under it, else as given.
  static func relativePath(_ path: String, to cwd: URL) -> String {
    let base = cwd.standardizedFileURL.path
    guard path.hasPrefix(base + "/") else { return path }
    return String(path.dropFirst(base.count + 1))
  }

  /// The text of a history message (text parts joined; anything else dropped).
  static func text(of message: Message) -> String {
    switch message.content {
    case .text(let text)?:
      return text
    case .parts(let parts)?:
      return parts.compactMap { part -> String? in
        if case .text(let text, _) = part { return text }
        return nil
      }.joined(separator: "\n")
    case nil:
      return ""
    }
  }

  /// One line for what a rewind did.
  static func summary(_ result: RewindResult) -> String {
    var parts: [String] = []
    parts.append("restored \(result.restoredFiles.count) file\(result.restoredFiles.count == 1 ? "" : "s")")
    if !result.deletedFiles.isEmpty { parts.append("deleted \(result.deletedFiles.count)") }
    parts.append("removed \(result.removedMessages) message\(result.removedMessages == 1 ? "" : "s")")
    return "↶ " + parts.joined(separator: ", ")
  }
}

// MARK: - DiffColoring

/// Terminal coloring for a unified diff: added lines green, removed red, hunk headers and file
/// headers dim. Every line is sanitized first — a diff is file content, and file content is
/// untrusted text on a terminal.
enum DiffColoring {
  enum Kind: Equatable {
    case header, hunk, added, removed, context
  }

  static func kind(of line: String) -> Kind {
    if line.hasPrefix("+++ ") || line.hasPrefix("--- ") || line.hasPrefix("diff ")
      || line.hasPrefix("index ") || line.hasPrefix("new file mode") || line.hasPrefix("deleted file mode")
      || line.hasPrefix("Binary files") || line.hasPrefix("rename ") || line.hasPrefix("similarity ")
    {
      return .header
    }
    if line.hasPrefix("@@") { return .hunk }
    if line.hasPrefix("+") { return .added }
    if line.hasPrefix("-") { return .removed }
    return .context
  }

  static func colored(_ diff: String) -> String {
    diff.split(separator: "\n", omittingEmptySubsequences: false).map { raw -> String in
      let line = TerminalText.sanitize(String(raw))
      switch kind(of: line) {
      case .header: return ANSI.bold(line)
      case .hunk: return ANSI.secondary(line)
      case .added: return ANSI.green(line)
      case .removed: return ANSI.red(line)
      case .context: return line
      }
    }.joined(separator: "\n")
  }
}
