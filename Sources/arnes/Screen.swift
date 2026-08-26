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
  /// Visible width of each region line as last drawn — erasing recomputes how many
  /// physical rows each occupies at the *current* width, so a resize that rewrapped
  /// them (terminal reflow) is healed instead of corrupting the cursor math.
  private var drawnWidths: [Int] = []
  private var parkIndex = 0     // region line the cursor is parked on
  private var parkColumn = 0    // 0-based column of the parked cursor
  private var pendingReports = 0 // outstanding DSR queries; every reply applies, last wins
  private var closed = false
  /// 1-based screen row where the next transcript line lands (the region's top).
  /// Measured once via DSR at startup, then tracked from what we write; <= 0 means
  /// unknown, which disables bottom-pinning and leaves the bar under the content.
  private var transcriptRow = 0

  static let idlePlaceholder = "message · /help for commands"
  static let busyPlaceholder = "type to queue · ctrl+c interrupts"

  /// Asks the terminal where the cursor is (DSR `ESC[6n`) so the first bar draw can
  /// pad down to the window's bottom rows. Call once at startup, before any output
  /// and before the raw-mode readers own stdin — the reply arrives on stdin.
  func measureOrigin() {
    guard isActive else { return }
    lock.lock()
    defer { lock.unlock() }
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    defer {
      var restore = original
      tcsetattr(STDIN_FILENO, TCSANOW, &restore)
    }
    write("\u{1B}[6n")
    var response: [UInt8] = []
    var attempts = 0
    while attempts < 50, response.last != UInt8(ascii: "R") {
      var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      guard poll(&fds, 1, 10) > 0, fds.revents & Int16(POLLIN) != 0 else {
        attempts += 1
        continue
      }
      var byte: UInt8 = 0
      guard read(STDIN_FILENO, &byte, 1) == 1 else { break }
      response.append(byte)
    }
    // Reply is ESC [ row ; col R — parse defensively, stray bytes just fail the parse.
    let text = String(decoding: response, as: UTF8.self)
    guard
      text.hasSuffix("R"),
      let bracket = text.lastIndex(of: "["),
      let row = Int(text[text.index(after: bracket)...].prefix(while: { $0.isNumber })),
      row > 0
    else { return }
    transcriptRow = row
  }

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
    write(eraseRegion(columns: max(20, Self.terminalColumns)))
    closed = true
  }

  /// The window changed size: redraw at the new dimensions (the wrap-aware erase
  /// heals reflowed lines), then ask the terminal where the cursor landed so the
  /// bar can re-pin to the new bottom. The DSR reply arrives on stdin and is fed
  /// back through `reportCursorRow` by whichever key reader is active.
  func handleResize() {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    transcriptRow = 0 // unknown until the terminal answers
    repaint()
    guard !drawnWidths.isEmpty else { return }
    pendingReports += 1
    write("\u{1B}[6n")
  }

  /// A cursor-position report reached one of the input readers.
  func reportCursorRow(_ row: Int) {
    guard isActive, !closed else { return }
    lock.lock()
    defer { lock.unlock() }
    guard pendingReports > 0, row > 0 else { return }
    pendingReports -= 1
    // The cursor is parked `parkIndex` freshly-drawn (single-row) lines below the
    // region top, which is where the next transcript line lands.
    transcriptRow = max(1, row - parkIndex)
    if !drawnWidths.isEmpty {
      repaint() // apply bottom-pinning padding at the new size
    }
  }

  // MARK: Drawing

  /// One write per update: erase the old region, print committed lines permanently,
  /// redraw the region below them, park the cursor at the input position.
  private func repaint(commit: [String] = []) {
    let columns = max(20, Self.terminalColumns)
    let screenRows = Self.terminalRows
    var out = eraseRegion(columns: columns)
    for line in commit {
      out += line + "\n"
      if transcriptRow > 0 {
        // Wrap-aware: a long committed line occupies several physical rows.
        let physical = max(1, (ANSIText.visibleCount(line) + columns - 1) / columns)
        transcriptRow = min(screenRows, transcriptRow + physical)
      }
    }

    var lines: [String] = []
    var widths: [Int] = []
    var inputRow: Int?
    var inputColumn = 0
    if !partial.isEmpty {
      let clamped = ANSIText.clampTail(partial, to: columns - 1) + "\u{1B}[0m"
      lines.append(clamped)
      widths.append(ANSIText.visibleCount(clamped))
    }
    if let status {
      let clamped = ANSIText.clampTail(status, to: columns - 1) + "\u{1B}[0m"
      lines.append(clamped)
      widths.append(ANSIText.visibleCount(clamped))
    }
    if showBox {
      // One column narrower than the terminal on purpose: a completely filled row is
      // indistinguishable from a soft-wrapped one, so resize reflow would join it
      // with the next line and break the erase math.
      let boxWidth = columns - 1
      let inner = boxWidth - 4 // "│ " … " │"
      let label = queued > 0 ? " \(queued) queued " : ""
      lines.append(ANSI.accent("╭─") + ANSI.dim(label)
        + ANSI.accent(String(repeating: "─", count: max(0, boxWidth - 3 - label.count)) + "╮"))
      let (view, column) = inputLine(inner: inner)
      inputColumn = column
      inputRow = lines.count
      lines.append(view)
      lines.append(ANSI.accent("╰" + String(repeating: "─", count: boxWidth - 2) + "╯"))
      widths.append(contentsOf: [boxWidth, boxWidth, boxWidth])
    }

    if !lines.isEmpty {
      // Pin the bar to the window's bottom rows: pad blank lines down so the region's
      // last row is the last screen row. Once the screen is full the padding is zero
      // and natural scrolling keeps it there.
      if transcriptRow > 0 {
        let padding = screenRows - lines.count + 1 - transcriptRow
        if padding > 0 {
          out += String(repeating: "\n", count: padding)
          transcriptRow += padding
        }
        let overflow = transcriptRow + lines.count - 1 - screenRows
        if overflow > 0 {
          transcriptRow -= overflow // drawing past the bottom scrolls the screen
        }
      }
      out += lines.joined(separator: "\n")
      let last = lines.count - 1
      if let inputRow {
        if last - inputRow > 0 { out += "\u{1B}[\(last - inputRow)A" }
        out += "\u{1B}[\(inputColumn + 1)G"
        parkIndex = inputRow
        parkColumn = inputColumn
      } else {
        parkIndex = last
        parkColumn = widths[last]
      }
      drawnWidths = widths
    }
    write(out)
  }

  /// Moves from the parked cursor to the region's top row and clears everything below.
  /// Row counts are recomputed from each drawn line's width at the current terminal
  /// width, so lines the terminal rewrapped after a resize are still fully erased.
  private func eraseRegion(columns: Int) -> String {
    guard !drawnWidths.isEmpty else { return "" }
    var up = parkColumn / columns // wrapped segments of the park line above the cursor
    for index in 0..<parkIndex {
      up += max(1, (drawnWidths[index] + columns - 1) / columns)
    }
    var out = up > 0 ? "\u{1B}[\(up)A" : ""
    out += "\r\u{1B}[J"
    drawnWidths = []
    parkIndex = 0
    parkColumn = 0
    return out
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

  static var terminalRows: Int {
    var size = winsize()
    if ioctl(STDOUT_FILENO, numericCast(TIOCGWINSZ), &size) == 0, size.ws_row > 0 {
      return Int(size.ws_row)
    }
    if let env = ProcessInfo.processInfo.environment["LINES"], let rows = Int(env) {
      return rows
    }
    return 24
  }
}

// MARK: - ANSIText

/// Width math over strings that contain ANSI escape sequences.
enum ANSIText {
  private enum Token {
    case character(Character)
    case escape(String)
  }

  /// Visible characters, ignoring escape sequences (physical-row math for wrapping).
  static func visibleCount(_ styled: String) -> Int {
    tokenize(styled).reduce(0) { count, token in
      if case .character = token { return count + 1 }
      return count
    }
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
