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

  static func dim(_ text: String) -> String { wrap(text, "2") }
  /// Brand accent (terracotta) — bold where 256-color is unavailable.
  static func accent(_ text: String) -> String { supports256 ? wrap(text, "38;5;173") : bold(text) }
  static func accentBold(_ text: String) -> String { supports256 ? wrap(text, "1;38;5;173") : bold(text) }
  static func bold(_ text: String) -> String { wrap(text, "1") }
  static func cyan(_ text: String) -> String { wrap(text, "36") }
  static func green(_ text: String) -> String { wrap(text, "32") }
  static func red(_ text: String) -> String { wrap(text, "31") }
  static func yellow(_ text: String) -> String { wrap(text, "33") }

  private static func wrap(_ text: String, _ code: String) -> String {
    isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }
}
