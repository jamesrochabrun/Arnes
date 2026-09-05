import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Terminal styling, gated on stdout being a TTY so piped output stays clean.
/// `TerminalText` below is the other half of the contract: anything untrusted that is
/// printed goes through it first.
enum ANSI {
  static let isTTY = isatty(1) != 0

  /// 256-color support, detected once — modern terminals advertise it via TERM/COLORTERM.
  static let supports256 = ProcessInfo.processInfo.environment["TERM"]?.contains("256color") == true
    || ProcessInfo.processInfo.environment["COLORTERM"] != nil

  /// Light terminal background — flips the palette to darker shades that keep contrast.
  /// Seeded from COLORFGBG; refined once at startup by an OSC 11 query (`Screen`).
  nonisolated(unsafe) static var lightBackground: Bool = {
    // COLORFGBG is "fg;bg" (sometimes "fg;default;bg"); bg 7/15 means a light theme.
    guard let raw = ProcessInfo.processInfo.environment["COLORFGBG"],
          let bg = raw.split(separator: ";").last.flatMap({ Int($0) })
    else { return false }
    return bg == 7 || bg == 15
  }()

  static func dim(_ text: String) -> String { wrap(text, "2") }
  /// Brand accent — chartreuse (~#D7FF5F) on dark, a darker olive-green on light so the
  /// box border stays readable; bold where 256-color is unavailable.
  static func accent(_ text: String) -> String {
    supports256 ? wrap(text, lightBackground ? "38;5;64" : "38;5;191") : bold(text)
  }
  static func accentBold(_ text: String) -> String {
    supports256 ? wrap(text, lightBackground ? "1;38;5;64" : "1;38;5;191") : bold(text)
  }
  /// Secondary accent — violet, chosen to contrast the chartreuse box: routing, subagent
  /// activity, and the info line's highlights. Falls back to cyan without 256-color.
  static func secondary(_ text: String) -> String {
    supports256 ? wrap(text, lightBackground ? "38;5;97" : "38;5;141") : cyan(text)
  }
  /// Shell-escape accent — orange: the input box while the buffer starts with `!` (the
  /// REPL's shell mode) and the result line its command prints. A darker orange keeps
  /// contrast on light backgrounds; falls back to yellow without 256-color.
  static func shell(_ text: String) -> String {
    supports256 ? wrap(text, lightBackground ? "38;5;166" : "38;5;208") : yellow(text)
  }
  static func bold(_ text: String) -> String { wrap(text, "1") }
  static func cyan(_ text: String) -> String { wrap(text, "36") }
  static func green(_ text: String) -> String { wrap(text, "32") }
  static func red(_ text: String) -> String { wrap(text, "31") }
  static func yellow(_ text: String) -> String { wrap(text, "33") }

  private static func wrap(_ text: String, _ code: String) -> String {
    isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }
}

// MARK: - TerminalText

/// Makes untrusted text safe to write to a terminal.
///
/// Model output, tool arguments and results, and server-supplied names or descriptions
/// all end up on the user's screen. Raw control characters in that text are not inert:
/// a carriage return or `ESC[2K` hidden inside a `bash` command redraws the permission
/// prompt so the user approves a different command than the one about to run, and
/// escape sequences can drive the terminal itself (OSC 52 clipboard writes, title
/// changes, cursor movement that overwrites earlier lines). Unicode bidi overrides do
/// the same trick visually by reversing the rendered order of a line.
///
/// Nothing is silently dropped — every such character is made *visible*: C0 controls
/// become their Control Pictures (`␛`, `␍`), DEL `␡`, and C1 controls plus bidi
/// controls render as `<U+XXXX>`. Newline and tab pass through. Piped output (no TTY)
/// is left untouched: there is no terminal interpreting it, and scripts want raw text.
enum TerminalText {
  /// `visibleControls(text)` when stdout is a TTY, `text` unchanged otherwise.
  static func sanitize(_ text: String) -> String {
    ANSI.isTTY ? visibleControls(text) : text
  }

  /// The pure transform (always applied), for callers and tests that don't want the
  /// TTY gate.
  static func visibleControls(_ text: String) -> String {
    guard text.unicodeScalars.contains(where: isHazard) else { return text }
    var out = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      guard isHazard(scalar) else {
        out.append(scalar)
        continue
      }
      switch scalar.value {
      case 0x00...0x1F:
        // U+2400 block: ␀ … ␟ — the control picture for each C0 code.
        out.append(Unicode.Scalar(0x2400 + scalar.value)!)
      case 0x7F:
        out.append(Unicode.Scalar(0x2421)!) // ␡
      default:
        out.append(contentsOf: String(format: "<U+%04X>", scalar.value).unicodeScalars)
      }
    }
    return String(out)
  }

  private static func isHazard(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar.value {
    case 0x09, 0x0A:
      return false // tab and newline are layout, not control
    case 0x00...0x1F, 0x7F, 0x80...0x9F:
      return true // C0, DEL, C1
    case 0x061C, 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069:
      return true // bidi controls: ALM, LRM/RLM, embeddings/overrides, isolates
    default:
      return false
    }
  }
}
