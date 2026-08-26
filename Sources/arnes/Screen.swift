import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Pins an input box (and a status line above it) to the bottom of the terminal while
/// the transcript scrolls top-to-bottom above it.
///
/// Strategy: redraw-below, not scroll regions or the alternate screen — the bar is
/// simply always the last thing drawn. Committed transcript lines are printed above it
/// permanently, so native scrollback keeps the whole conversation. Streamed partial
/// lines live *inside* the redrawn region (clamped to one row) and are committed to the
/// transcript when their newline arrives, which keeps the cursor math wrap-free.
///
/// Inactive (stdin or stdout not a TTY, or after `close()`) it degrades to plain
/// printing, so piped transcripts are unchanged. All methods are thread-safe: renderer
/// task, spinner task, and key-watcher thread all draw through here.
final class Screen: @unchecked Sendable {
  /// The bar needs raw input state (stdin) and cursor control (stdout).
  let isActive = isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0

  private let lock = NSLock()
  private var partial = ""      // unterminated streamed line, redrawn in the bar region
  private var status: String?   // spinner / permission-question line above the box
  private var showBox = false
  private var prompt = "› "
  private var buffer = ""
  private var cursor = 0
  private var queued = 0        // completed type-ahead lines waiting to run
  private var placeholder = Screen.idlePlaceholder
  private var regionRows = 0    // rows the bar region currently occupies on screen
  private var parkRow = 0       // row within the region where the cursor is parked
  private var closed = false

  static let idlePlaceholder = "message · /help for commands"
  static let busyPlaceholder = "type to queue · ctrl+c interrupts"

  // MARK: Transcript

  /// Commits full lines above the bar (splits on newlines; "" prints a blank line).
  func print(_ text: String) {
    guard isActive, !closed else {
      Swift.print(text)
      return
    }
    lock.lock()
    defer { lock.unlock() }
    repaint(commit: text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
  }

  /// Streamed styled text: completed lines commit to the transcript, the unterminated
  /// remainder is drawn live at the top of the bar region.
  func stream(_ styled: String) {
    guard isActive, !closed else {
      FileHandle.standardOutput.write(Data(styled.utf8))
      return
    }
    lock.lock()
    defer { lock.unlock() }
    partial += styled
    var commits: [String] = []
    while let newline = partial.firstIndex(of: "\n") {
      commits.append(String(partial[..<newline]))
      partial = String(partial[partial.index(after: newline)...])
    }
    repaint(commit: commits)
  }

  /// Ends an open streamed line, committing whatever is buffered.
  func finishStream() {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !partial.isEmpty else { return }
    let line = partial
    partial = ""
    repaint(commit: [line])
  }

  // MARK: Bar state

  func setStatus(_ line: String?) {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    status = line
    repaint()
  }

  /// The line editor's live state; showing it reveals the box.
  func setInput(prompt: String, buffer: String, cursor: Int) {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    showBox = true
    self.prompt = prompt
    self.buffer = buffer
    self.cursor = cursor
    queued = 0
    repaint()
  }

  /// Live type-ahead during a turn: the unfinished fragment plus how many completed
  /// lines are queued to run next.
  func setTypeahead(_ fragment: String, queued: Int) {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    showBox = true
    buffer = fragment
    cursor = fragment.count
    self.queued = queued
    repaint()
  }

  func setPlaceholder(_ text: String) {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    placeholder = text
    repaint()
  }

  /// Erases the bar and reverts to plain printing (end of the session).
  func close() {
    guard isActive else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !closed else { return }
    if regionRows > 0 {
      var out = ""
      if parkRow > 0 { out += "\u{1B}[\(parkRow)A" }
      out += "\r\u{1B}[J"
      write(out)
      regionRows = 0
      parkRow = 0
    }
    closed = true
  }

  // MARK: Drawing

  /// One write per update: erase the old region, print committed lines permanently,
  /// redraw the region below them, park the cursor at the input position.
  private func repaint(commit: [String] = []) {
    var out = ""
    if regionRows > 0 {
      if parkRow > 0 { out += "\u{1B}[\(parkRow)A" }
      out += "\r\u{1B}[J"
      regionRows = 0
      parkRow = 0
    }
    for line in commit {
      out += line + "\n"
    }

    let columns = max(20, Self.terminalColumns)
    var lines: [String] = []
    var inputRow: Int?
    var inputColumn = 0
    if !partial.isEmpty {
      lines.append(ANSIText.clampTail(partial, to: columns - 1) + "\u{1B}[0m")
    }
    if let status {
      lines.append(ANSIText.clampTail(status, to: columns - 1) + "\u{1B}[0m")
    }
    if showBox {
      let inner = columns - 4 // "│ " … " │"
      let label = queued > 0 ? " \(queued) queued " : ""
      lines.append(ANSI.accent("╭─") + ANSI.dim(label)
        + ANSI.accent(String(repeating: "─", count: max(0, columns - 3 - label.count)) + "╮"))
      let (view, column) = inputLine(inner: inner)
      inputColumn = column
      inputRow = lines.count
      lines.append(view)
      lines.append(ANSI.accent("╰" + String(repeating: "─", count: columns - 2) + "╯"))
    }

    if !lines.isEmpty {
      out += lines.joined(separator: "\n")
      let last = lines.count - 1
      if let inputRow {
        if last - inputRow > 0 { out += "\u{1B}[\(last - inputRow)A" }
        out += "\u{1B}[\(inputColumn + 1)G"
        parkRow = inputRow
      } else {
        parkRow = last
      }
      regionRows = lines.count
    }
    write(out)
  }

  /// The box's middle row and the 0-based screen column for the cursor. Long input
  /// slides a window so the cursor stays visible; the line never wraps.
  private func inputLine(inner: Int) -> (String, Int) {
    let promptWidth = prompt.count
    let available = max(1, inner - promptWidth)
    var shown: String
    var cursorOffset: Int
    if buffer.isEmpty {
      let hint = placeholder.count > available ? String(placeholder.prefix(available - 1)) + "…" : placeholder
      shown = ANSI.dim(hint)
      cursorOffset = 0
      let pad = available - hint.count
      let row = ANSI.accent("│") + " " + ANSI.accent(prompt) + shown
        + String(repeating: " ", count: max(0, pad)) + " " + ANSI.accent("│")
      return (row, 2 + promptWidth)
    }
    let characters = Array(buffer)
    var start = 0
    if characters.count > available {
      start = max(0, min(cursor, characters.count) - available + 1)
      start = min(start, characters.count - available)
    }
    let window = characters[start..<min(characters.count, start + available)]
    shown = String(window)
    if start > 0 {
      shown = "…" + String(shown.dropFirst())
    }
    cursorOffset = min(cursor, characters.count) - start
    let pad = available - window.count
    let row = ANSI.accent("│") + " " + ANSI.accent(prompt) + shown
      + String(repeating: " ", count: max(0, pad)) + " " + ANSI.accent("│")
    return (row, 2 + promptWidth + cursorOffset)
  }

  private func write(_ text: String) {
    guard !text.isEmpty else { return }
    FileHandle.standardOutput.write(Data(text.utf8))
  }

  static var terminalColumns: Int {
    var size = winsize()
    if ioctl(STDOUT_FILENO, numericCast(TIOCGWINSZ), &size) == 0, size.ws_col > 0 {
      return Int(size.ws_col)
    }
    if let env = ProcessInfo.processInfo.environment["COLUMNS"], let columns = Int(env) {
      return columns
    }
    return 80
  }
}

// MARK: - ANSIText

/// Width math over strings that contain ANSI escape sequences.
enum ANSIText {
  private enum Token {
    case character(Character)
    case escape(String)
  }

  /// Keeps the last `max` visible characters, preserving the SGR styles that were
  /// active at the cut (a clipped line must not restyle mid-word) and prefixing a
  /// dim ellipsis when anything was dropped.
  static func clampTail(_ styled: String, to max: Int) -> String {
    let tokens = tokenize(styled)
    let visible = tokens.reduce(0) { count, token in
      if case .character = token { return count + 1 }
      return count
    }
    guard visible > max, max > 1 else { return styled }
    var remaining = visible - (max - 1) // room for the ellipsis
    var index = 0
    var activeStyles = ""
    while index < tokens.count, remaining > 0 {
      switch tokens[index] {
      case .character:
        remaining -= 1
      case .escape(let sequence):
        if sequence.hasSuffix("m") {
          activeStyles = sequence == "\u{1B}[0m" ? "" : activeStyles + sequence
        }
      }
      index += 1
    }
    var tail = ""
    for token in tokens[index...] {
      switch token {
      case .character(let character): tail.append(character)
      case .escape(let sequence): tail += sequence
      }
    }
    return ANSI.dim("…") + activeStyles + tail
  }

  private static func tokenize(_ text: String) -> [Token] {
    var tokens: [Token] = []
    var iterator = text.makeIterator()
    while let character = iterator.next() {
      guard character == "\u{1B}" else {
        tokens.append(.character(character))
        continue
      }
      var sequence = String(character)
      guard let next = iterator.next() else { break }
      sequence.append(next)
      if next == "[" {
        while let byte = iterator.next() {
          sequence.append(byte)
          if let scalar = byte.unicodeScalars.first, (0x40...0x7E).contains(scalar.value) {
            break
          }
        }
      }
      tokens.append(.escape(sequence))
    }
    return tokens
  }
}
