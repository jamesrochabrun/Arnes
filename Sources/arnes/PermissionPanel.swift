import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - PermissionPanel

/// The interactive permission prompt's option panel, terminal-free: which options a request
/// offers, what each key does, and how the rows render. `TerminalPermissions` draws the rows
/// on the screen's status lines and loops on `action(for:)` — a key that maps to `.ignore`
/// leaves the panel exactly as it was, so a stray keystroke can never answer the question.
enum PermissionPanel {
  /// One selectable row.
  struct Option: Equatable {
    let label: String
    let decision: Decision
  }

  enum Decision: Equatable {
    case allow
    case allowAlways
    case deny
  }

  /// What a key does to the panel.
  enum KeyAction: Equatable {
    /// ↑/↓ — move the highlight by ±1.
    case move(Int)
    /// Enter — confirm the highlighted option.
    case choose
    /// y/n/a — jump straight to the option with this decision (ignored when absent).
    case pick(Decision)
    /// 1–9 — confirm that row (ignored when out of range).
    case select(Int)
    /// Esc or Ctrl-C — cancel the whole turn, not just this call.
    case cancel
    /// Ctrl-O — print the full diff above the panel.
    case expand
    /// Anything else: the panel stays as it is. The old single-key prompt read every
    /// unrecognized key as a denial; a brushed key must not answer a question.
    case ignore
  }

  /// Yes / (Yes, always … this session) / No. The always row exists only where "always"
  /// would actually remember something: never after a taint and never on a `.sensitive`
  /// call (the session records no grant for either — answering it would only approve the
  /// one call, which "Yes" already does), except a scoped read, whose `grantScope` names
  /// the directory a grant covers.
  static func options(for request: PermissionRequest, root: URL? = nil) -> [Option] {
    var rows = [Option(label: "Yes", decision: .allow)]
    if let always = alwaysLabel(for: request, root: root) {
      rows.append(Option(label: always, decision: .allowAlways))
    }
    rows.append(Option(label: "No, and tell the model why", decision: .deny))
    return rows
  }

  /// The always row's label — nil when the row shouldn't exist. For `bash` it names the
  /// command patterns a grant would remember (`ShellCommand.sessionGrantPatterns`, computed
  /// against `root` — the label is best-effort display, the session computes the real grant
  /// when it records one); a command with nothing grantable (destructive, an interpreter,
  /// substitution) gets no row.
  static func alwaysLabel(for request: PermissionRequest, root: URL? = nil) -> String? {
    guard !request.tainted else { return nil }
    if let scope = request.grantScope {
      return "Yes, always for \(TerminalPermissions.abbreviateHome(scope)) this session"
    }
    guard request.tier != .sensitive else { return nil }
    if request.toolName == "bash" {
      guard let command = argument("command", in: request.argumentsJSON) else { return nil }
      let names = ShellCommand.sessionGrantPatterns(for: command, root: root).map(patternName)
      guard !names.isEmpty else { return nil }
      return "Yes, always allow \(names.joined(separator: ", ")) this session"
    }
    return "Yes, always allow \(request.toolName) this session"
  }

  /// Where the highlight starts: on "No" for a `.sensitive` or tainted call (a reflexive
  /// Enter must not approve an irreversible action), on "Yes" otherwise.
  static func initialSelection(for request: PermissionRequest, options: [Option]) -> Int {
    guard request.tier == .sensitive || request.tainted else { return 0 }
    return options.firstIndex { $0.decision == .deny } ?? 0
  }

  static func action(for key: String) -> KeyAction {
    switch key {
    case "\u{1B}[A", "\u{1B}OA": return .move(-1)
    case "\u{1B}[B", "\u{1B}OB": return .move(1)
    case "\r", "\n": return .choose
    case "\u{1B}", "\u{03}": return .cancel
    case "\u{0F}": return .expand
    case "y", "Y": return .pick(.allow)
    case "a", "A": return .pick(.allowAlways)
    case "n", "N": return .pick(.deny)
    default:
      if key.count == 1, let digit = Int(key), digit >= 1 { return .select(digit - 1) }
      return .ignore
    }
  }

  /// The status-line rows: the question with a key hint, then one row per option with the
  /// highlight marked the way the slash-autocomplete popup marks its selection.
  static func lines(
    question: String,
    options: [Option],
    selected: Int,
    showsDiffHint: Bool,
    deferred: Bool = false) -> [String]
  {
    var hint = "↑↓ · enter"
    hint += options.contains(where: { $0.decision == .allowAlways }) ? " · y/n/a" : " · y/n"
    if showsDiffHint { hint += " · ctrl-o full diff" }
    hint += " · esc interrupts"
    if deferred { hint = "pause typing, then answer" }
    var rows = [ANSI.bold(question) + "  " + ANSI.dim("(" + hint + ")")]
    let selected = max(0, min(selected, options.count - 1))
    for (index, option) in options.enumerated() {
      // A bash always-label quotes the model's command tokens — untrusted text on a terminal.
      let label = TerminalText.sanitize(option.label)
      rows.append(index == selected
        ? ANSI.accent("  ❯ ") + ANSI.accentBold(label)
        : "    " + label)
    }
    return rows
  }

  /// `Bash(git commit *)` → `git commit` — the human-readable core of a grant pattern.
  static func patternName(_ pattern: String) -> String {
    var name = pattern
    if name.hasPrefix("Bash("), name.hasSuffix(")") {
      name = String(name.dropFirst(5).dropLast(1))
    }
    if name.hasSuffix(" *") { name = String(name.dropLast(2)) }
    return name
  }

  /// One string argument out of a call's arguments JSON.
  static func argument(_ name: String, in argumentsJSON: String) -> String? {
    guard
      let value = try? JSONDecoder().decode([String: JSONValue].self, from: Data(argumentsJSON.utf8))
    else { return nil }
    return value[name]?.stringValue
  }
}

// MARK: - EditPreview

/// What an `edit_file`/`write_file` call is about to change, computed from the call's
/// arguments for the permission prompt: a colored snippet under the question, the whole
/// diff behind Ctrl-O. Display only — the tool re-resolves and re-checks everything when
/// it runs, so a file that moves between the prompt and the write is the tool's problem,
/// not this preview's.
struct EditPreview {
  let path: String
  /// Unified diff text, unstyled. For `write_file` over an existing readable text file the
  /// disk content is the old side — the prompt shows what the overwrite replaces; for a new
  /// file everything is `+`. For `edit_file` the two sides are the replaced strings, so the
  /// hunk line numbers would be relative to the snippet, not the file — they are dropped.
  let diff: String
  /// Whether hunk headers carry real file line numbers (`write_file` against the disk copy,
  /// a multi-edit `edit_file` against the disk copy too) or snippet-relative ones (a single
  /// `edit_file` — replaced by a plain separator).
  let absoluteLineNumbers: Bool

  static let snippetLines = 8
  static let fullDiffLines = 400
  /// Files past this size aren't read for the overwrite preview (the diff shows all-added).
  static let maxExistingBytes = 1 << 20

  /// nil for any other tool, unparseable arguments, or a no-op change.
  static func make(
    toolName: String,
    argumentsJSON: String,
    readExisting: (String) -> String? = EditPreview.diskContents) -> EditPreview?
  {
    guard
      let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: Data(argumentsJSON.utf8)),
      let path = arguments["path"]?.stringValue
    else { return nil }
    switch toolName {
    case "edit_file":
      if arguments[EditFileTool.editsKey] != nil {
        // The multi form (T7): the disk copy run through the tool's own `apply`, so the prompt
        // shows the whole change as one diff with real hunk numbers — the same arithmetic
        // `execute` will do. When the file can't be read or an edit won't apply (execute will
        // say which), one old→new diff per edit, `⋮` between them.
        guard let edits = EditFileTool.edits(from: arguments), !edits.isEmpty else { return nil }
        if let existing = readExisting(path), case .success(let applied) = EditFileTool.apply(edits, to: existing) {
          let diff = UnifiedDiff.diff(old: existing, new: applied.updated, path: path)
          guard !diff.isEmpty else { return nil }
          return EditPreview(path: path, diff: diff, absoluteLineNumbers: true)
        }
        let diffs = edits
          .map { UnifiedDiff.diff(old: $0.oldString, new: $0.newString, path: path) }
          .filter { !$0.isEmpty }
          .map { $0.hasSuffix("\n") ? String($0.dropLast()) : $0 }
        guard !diffs.isEmpty else { return nil }
        return EditPreview(path: path, diff: diffs.joined(separator: "\n"), absoluteLineNumbers: false)
      }
      guard
        let old = arguments["old_string"]?.stringValue,
        let new = arguments["new_string"]?.stringValue
      else { return nil }
      let diff = UnifiedDiff.diff(old: old, new: new, path: path)
      guard !diff.isEmpty else { return nil }
      return EditPreview(path: path, diff: diff, absoluteLineNumbers: false)
    case "write_file":
      guard let content = arguments["content"]?.stringValue else { return nil }
      let old = readExisting(path)
      let diff = UnifiedDiff.diff(old: old, new: content, path: path)
      guard !diff.isEmpty else { return nil }
      return EditPreview(path: path, diff: diff, absoluteLineNumbers: true)
    default:
      return nil
    }
  }

  /// The current file at `path` (relative paths against the process cwd), for the overwrite
  /// preview; nil when it doesn't exist, isn't UTF-8 text, or is too large to diff inline.
  static func diskContents(_ path: String) -> String? {
    let resolved = (path as NSString).isAbsolutePath
      ? path
      : FileManager.default.currentDirectoryPath + "/" + path
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: resolved),
      let size = attributes[.size] as? Int, size <= maxExistingBytes
    else { return nil }
    return try? String(contentsOfFile: resolved, encoding: .utf8)
  }

  /// The first `snippetLines` body lines of the diff, colored, plus a dim trailer naming
  /// what Ctrl-O shows when anything was clipped.
  var snippet: [String] {
    let body = bodyLines
    var rows = body.prefix(Self.snippetLines).map(Self.colored)
    if body.count > Self.snippetLines {
      rows.append(ANSI.dim("  … \(body.count - Self.snippetLines) more diff lines — ctrl-o shows the full diff"))
    }
    return rows
  }

  /// The whole diff, colored, capped at `fullDiffLines`.
  var full: [String] {
    let body = bodyLines
    var rows = body.prefix(Self.fullDiffLines).map(Self.colored)
    if body.count > Self.fullDiffLines {
      rows.append(ANSI.dim("  … diff truncated at \(Self.fullDiffLines) lines (\(body.count - Self.fullDiffLines) more)"))
    }
    return rows
  }

  /// The diff without its `---`/`+++` header (the prompt's own header already names the
  /// file); `edit_file` hunk headers become a plain separator — their numbers would be
  /// relative to the replaced text, and a wrong line number is worse than none.
  var bodyLines: [String] {
    var rows: [String] = []
    for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(raw)
      if line.hasPrefix("--- ") || line.hasPrefix("+++ ") { continue }
      if line.hasPrefix("@@"), !absoluteLineNumbers {
        if !rows.isEmpty { rows.append("  ⋮") }
        continue
      }
      rows.append(line)
    }
    if rows.last == "" { rows.removeLast() }
    return rows
  }

  /// `DiffColoring`'s palette over one preview line (sanitized there — diff content is
  /// untrusted text on a terminal), indented to sit under the prompt's header.
  static func colored(_ line: String) -> String {
    if line == "  ⋮" { return ANSI.dim(line) }
    return "  " + DiffColoring.colored(line)
  }
}
