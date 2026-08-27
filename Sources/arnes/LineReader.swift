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

  /// When set (and active), editing state is drawn in the screen's pinned bottom box
  /// instead of inline, and notices go through the screen so the box stays below them.
  var screen: Screen?

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
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    defer {
      var restore = original
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
    }

    var buffer: [Character] = Array(initial)
    var cursor = buffer.count
    var historyIndex = history.count
    var pendingLine: [Character] = []
    var interruptArmed = false

    func redraw() {
      if usesScreen, let screen {
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
      case 0x0A, 0x0D: // enter
        endInput()
        return String(buffer)

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
          buffer.removeAll() // bare Esc — clear the line
          cursor = 0
          redraw()
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
        case UInt8(ascii: "A"): // up — history back
          if historyIndex > 0 {
            if historyIndex == history.count { pendingLine = buffer }
            historyIndex -= 1
            buffer = Array(history[historyIndex])
            cursor = buffer.count
            redraw()
          }
        case UInt8(ascii: "B"): // down — history forward
          if historyIndex < history.count {
            historyIndex += 1
            buffer = historyIndex == history.count ? pendingLine : Array(history[historyIndex])
            cursor = buffer.count
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
    try? FileManager.default.createDirectory(
      at: historyURL.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try? history.joined(separator: "\n").write(to: historyURL, atomically: true, encoding: .utf8)
  }
}
