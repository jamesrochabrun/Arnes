import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Terminal styling, gated on stdout being a TTY so piped output stays clean.
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
  static func bold(_ text: String) -> String { wrap(text, "1") }
  static func cyan(_ text: String) -> String { wrap(text, "36") }
  static func green(_ text: String) -> String { wrap(text, "32") }
  static func red(_ text: String) -> String { wrap(text, "31") }
  static func yellow(_ text: String) -> String { wrap(text, "33") }

  private static func wrap(_ text: String, _ code: String) -> String {
    isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }
}
