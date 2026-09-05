import ArnesKit
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Minimal raw-mode line editor: arrow-key history, left/right cursor movement,
/// backspace, Esc clears the line, Ctrl-C (clear line; twice on empty = exit),
/// Ctrl-D on empty = exit.
/// Falls back to `Swift.readLine()` when stdin isn't a TTY so piped input works.
/// Zero dependencies on purpose.
final class LineReader {
  /// Ctrl-O at the prompt (verbosity toggle). The handler prints its own notice
  /// line; the reader redraws the prompt underneath it.
  var onCtrlO: (() -> Void)?
  /// Ctrl-T at the prompt (the reasoning-display toggle), the same way.
  var onCtrlT: (() -> Void)?

  /// When set (and active), editing state is drawn in the screen's pinned bottom box
  /// instead of inline, and notices go through the screen so the box stays below them.
  var screen: Screen?

  /// Where a collapsed paste's full text is kept (`[Pasted text #1 +58 lines]` in the box,
  /// the 58 lines here). nil inserts every paste literally, newlines as spaces.
  var pastes: PasteStore?

  /// Slash-command autocomplete candidates (built-ins + skills + MCP prompts). While the
  /// buffer is a lone `/token`, matches show in a popup under the box: ↑/↓ move the
  /// highlight, Tab inserts the highlighted command (ready for arguments), Enter runs it,
  /// Esc dismisses until the text changes. nil (or no Screen) leaves every key as it was.
  var completions: (() -> [SlashCompletion.Item])?

  /// A DSR cursor-position report arrived while this reader owned stdin (the screen
  /// requests one after a resize) — forwards the 1-based row.
  var onCursorReport: ((Int) -> Void)?

  /// Row from CSI params ("row;col").
  static func reportRow(_ params: [UInt8]) -> Int? {
    let text = String(decoding: params, as: UTF8.self)
    return Int(text.prefix(while: { $0.isNumber }))
  }

  private var usesScreen: Bool { screen?.isActive == true }

  private let historyURL: URL?
  private var history: [String] = []
  private let isTTY = isatty(0) != 0
  private static let maxHistory = 500

  init(historyURL: URL?) {
    self.historyURL = historyURL
    if let historyURL, let text = try? String(contentsOf: historyURL, encoding: .utf8) {
      history = text.split(separator: "\n").map(String.init).suffix(Self.maxHistory)
    }
  }

  /// Reads one line, optionally pre-filled (an unfinished type-ahead fragment from
  /// the last turn). Returns nil to exit (Ctrl-D on empty line, double Ctrl-C, or EOF).
  func readLine(prompt: String, initial: String = "") -> String? {
    guard isTTY else {
      print(prompt, terminator: "")
      return Swift.readLine()
    }
    guard let line = readRaw(prompt: prompt, initial: initial) else { return nil }
    if !line.isEmpty, line != history.last {
      history.append(line)
      if history.count > Self.maxHistory {
        history.removeFirst(history.count - Self.maxHistory)
      }
      saveHistory()
    }
    return line
  }

  // MARK: Raw mode

  private func readRaw(prompt: String, initial: String) -> String? {
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    // IEXTEN too, or the tty driver eats Ctrl-O (VDISCARD on macOS) before it can toggle.
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    // Bracketed paste: the terminal wraps pasted text in ESC[200~ … ESC[201~ so a paste is
    // one event instead of keystrokes — its newlines must not submit the line.
    write("\u{1B}[?2004h")
    defer {
      write("\u{1B}[?2004l")
      var restore = original
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
    }

    var buffer: [Character] = Array(initial)
    var cursor = buffer.count
    var historyIndex = history.count
    var pendingLine: [Character] = []
    var interruptArmed = false

    // Autocomplete popup state. Items are computed once per read; matches follow the
    // buffer, the highlight follows the *item* (narrowing keeps it where it was).
    let completionItems = usesScreen ? completions?() : nil
    var menuItems: [SlashCompletion.Item] = []
    var menuSelected = 0
    var menuSuppressed = false
    var menuSnapshot = String(buffer)

    func refreshMenu() {
      guard let completionItems, let screen else { return }
      let text = String(buffer)
      if text != menuSnapshot { // an edit lifts an Esc dismissal
        menuSuppressed = false
        menuSnapshot = text
      }
      let matches = menuSuppressed ? [] : SlashCompletion.matches(for: text, in: completionItems)
      if menuItems.indices.contains(menuSelected),
         let kept = matches.firstIndex(of: menuItems[menuSelected])
      {
        menuSelected = kept
      } else if menuSelected >= matches.count {
        menuSelected = 0
      }
      menuItems = matches
      screen.setCompletions(SlashCompletion.lines(matches: matches, selected: menuSelected))
    }

    func redraw() {
      if usesScreen, let screen {
        refreshMenu()
        screen.setInput(prompt: prompt, buffer: String(buffer), cursor: cursor)
        return
      }
      var out = "\r\u{1B}[K" + prompt + String(buffer)
      let tail = buffer.count - cursor
      if tail > 0 {
        out += "\u{1B}[\(tail)D"
      }
      write(out)
    }

    func endInput() {
      if usesScreen, let screen {
        screen.setCompletions([])
        screen.setInput(prompt: prompt, buffer: "", cursor: 0)
      } else {
        write("\n")
      }
    }

    if usesScreen {
      redraw()
    } else {
      write(prompt + String(buffer))
    }

    while true {
      guard let byte = readByte() else {
        endInput()
        return buffer.isEmpty ? nil : String(buffer)
      }

      switch byte {
      case 0x0A, 0x0D: // enter — with the popup open, runs the highlighted command
        if menuItems.indices.contains(menuSelected) {
          let choice = menuItems[menuSelected]
          endInput()
          return choice.name
        }
        endInput()
        return String(buffer)

      case 0x09: // tab — insert the highlighted completion, ready for arguments
        if menuItems.indices.contains(menuSelected) {
          buffer = Array(SlashCompletion.accepted(menuItems[menuSelected]))
          cursor = buffer.count
          redraw()
        }

      case 0x03: // Ctrl-C
        if buffer.isEmpty {
          if interruptArmed {
            endInput()
            return nil
          }
          interruptArmed = true
          if usesScreen, let screen {
            screen.print(ANSI.dim("(^C again to exit)"))
          } else {
            write("\r\u{1B}[K" + ANSI.dim("(^C again to exit)") + "\n" + prompt)
          }
        } else {
          buffer.removeAll()
          cursor = 0
          redraw()
        }
        continue

      case 0x04: // Ctrl-D
        if buffer.isEmpty {
          endInput()
          return nil
        }

      case 0x7F, 0x08: // backspace
        if cursor > 0 {
          buffer.remove(at: cursor - 1)
          cursor -= 1
          redraw()
        }

      case 0x0F: // Ctrl-O — toggle tool-output verbosity
        onCtrlO?()
        redraw()

      case 0x14: // Ctrl-T — show/hide streamed reasoning
        onCtrlT?()
        redraw()

      case 0x15: // Ctrl-U — clear line
        buffer.removeAll()
        cursor = 0
        redraw()

      case 0x01: // Ctrl-A — start of line
        cursor = 0
        redraw()

      case 0x05: // Ctrl-E — end of line
        cursor = buffer.count
        redraw()

      case 0x1B: // bare Esc or an escape sequence
        // A sequence's remaining bytes arrive in the same burst; a lone Esc press is
        // followed by silence. Blocking here would swallow the *next* keystroke.
        guard byteAvailable(withinMs: 25) else {
          if !menuItems.isEmpty {
            menuSuppressed = true // bare Esc with the popup open — dismiss it, keep the text
            redraw()
          } else {
            buffer.removeAll() // bare Esc — clear the line
            cursor = 0
            redraw()
          }
          continue
        }
        guard let opener = readByte() else { continue }
        // "[" opens a CSI sequence, "O" an SS3 one (application-mode arrows);
        // anything else was an Alt+key pair, dropped. Parse until the final byte
        // (0x40–0x7E) so multi-byte sequences (delete, cursor-position reports)
        // never leak into the buffer as text.
        var params: [UInt8] = []
        var final: UInt8?
        if opener == UInt8(ascii: "O") {
          final = readByte()
        } else if opener == UInt8(ascii: "[") {
          while let next = readByte() {
            if (0x40...0x7E).contains(next) {
              final = next
              break
            }
            params.append(next)
          }
        } else {
          continue
        }
        switch final {
        case UInt8(ascii: "A"): // up — menu highlight when the popup is open, else history back
          if !menuItems.isEmpty {
            menuSelected = (menuSelected + menuItems.count - 1) % menuItems.count
            redraw()
          } else if historyIndex > 0 {
            if historyIndex == history.count { pendingLine = buffer }
            historyIndex -= 1
            buffer = Array(history[historyIndex])
            cursor = buffer.count
            // A recalled slash command must not open the popup — the next ↑ is more
            // history, not menu navigation. The next real edit lifts this.
            menuSuppressed = true
            menuSnapshot = String(buffer)
            redraw()
          }
        case UInt8(ascii: "B"): // down — menu highlight, else history forward
          if !menuItems.isEmpty {
            menuSelected = (menuSelected + 1) % menuItems.count
            redraw()
          } else if historyIndex < history.count {
            historyIndex += 1
            buffer = historyIndex == history.count ? pendingLine : Array(history[historyIndex])
            cursor = buffer.count
            menuSuppressed = true
            menuSnapshot = String(buffer)
            redraw()
          }
        case UInt8(ascii: "C"): // right
          if cursor < buffer.count {
            cursor += 1
            redraw()
          }
        case UInt8(ascii: "D"): // left
          if cursor > 0 {
            cursor -= 1
            redraw()
          }
        case UInt8(ascii: "~") where params == [UInt8(ascii: "3")]: // delete key
          if cursor < buffer.count {
            buffer.remove(at: cursor)
            redraw()
          }
        case UInt8(ascii: "~") where params == PasteCapture.startParams: // bracketed paste
          // The content arrives as one burst up to ESC[201~. Multi-line (or oversized)
          // pastes collapse to a placeholder so they don't submit a message per line;
          // small single-line ones insert literally.
          guard let pasted = readPastedText() else { continue }
          let text = PasteStore.normalize(pasted)
          guard !text.isEmpty else { continue }
          let inserted: String
          if let pastes, let image = PasteStore.imagePath(from: text) {
            // A dragged image arrives as its path — collapsed so the leading `/` can't
            // read as a slash command; expanded back to the clean path at submit. A
            // screenshot-thumbnail drag is copied out right now, before its OS grant dies.
            let stored = pastes.storeImage(image)
            inserted = stored.placeholder
            if let note = stored.note {
              let line = ANSI.yellow(TerminalText.sanitize(note))
              if usesScreen, let screen {
                screen.print(line)
              } else {
                write("\r\u{1B}[K" + line + "\n")
              }
            }
          } else if let pastes, PasteStore.shouldCollapse(text) {
            inserted = pastes.store(text)
          } else {
            inserted = PasteStore.inlineText(text)
          }
          buffer.insert(contentsOf: Array(inserted), at: cursor)
          cursor += inserted.count
          redraw()
        case UInt8(ascii: "R"): // cursor-position report (row;col) — for the screen
          if let row = Self.reportRow(params) {
            onCursorReport?(row)
          }
        default:
          continue
        }

      default:
        guard let character = readCharacter(firstByte: byte) else { continue }
        buffer.insert(character, at: cursor)
        cursor += 1
        redraw()
      }
      interruptArmed = false
    }
  }

  /// Decodes one UTF-8 character starting from an already-read first byte.
  private func readCharacter(firstByte: UInt8) -> Character? {
    var bytes = [firstByte]
    let continuationCount: Int
    switch firstByte {
    case 0x00..<0x20: return nil // other control chars
    case 0x20..<0x80: continuationCount = 0
    case 0xC0..<0xE0: continuationCount = 1
    case 0xE0..<0xF0: continuationCount = 2
    case 0xF0..<0xF8: continuationCount = 3
    default: return nil
    }
    for _ in 0..<continuationCount {
      guard let next = readByte() else { return nil }
      bytes.append(next)
    }
    return String(bytes: bytes, encoding: .utf8)?.first
  }

  private func readByte() -> UInt8? {
    var byte: UInt8 = 0
    let count = read(STDIN_FILENO, &byte, 1)
    return count == 1 ? byte : nil
  }

  /// Everything between the paste markers, blocking until `ESC[201~` (the content arrives
  /// in the same burst as the start marker). nil when stdin closes mid-paste.
  private func readPastedText() -> String? {
    var capture = PasteCapture()
    while let byte = readByte() {
      if case .finished(let text) = capture.feed(byte) { return text }
    }
    return nil
  }

  /// Whether another byte is already behind the one just read — distinguishes an
  /// escape sequence's ESC (followed immediately by "[" etc.) from a lone Esc press.
  private func byteAvailable(withinMs timeout: Int32) -> Bool {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    return poll(&fds, 1, timeout) > 0 && fds.revents & Int16(POLLIN) != 0
  }

  private func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }

  private func saveHistory() {
    guard let historyURL else { return }
    // Prompts are private too — owner-only like everything else under ~/.arnes.
    try? SecureFiles.writePrivate(Data(history.joined(separator: "\n").utf8), to: historyURL)
  }
}
