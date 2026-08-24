import Foundation

/// Terminal styling, gated on stdout being a TTY so piped output stays clean.
enum ANSI {
  static let isTTY = isatty(1) != 0

  static func dim(_ text: String) -> String { wrap(text, "2") }
  static func bold(_ text: String) -> String { wrap(text, "1") }
  static func cyan(_ text: String) -> String { wrap(text, "36") }
  static func green(_ text: String) -> String { wrap(text, "32") }
  static func red(_ text: String) -> String { wrap(text, "31") }
  static func yellow(_ text: String) -> String { wrap(text, "33") }

  private static func wrap(_ text: String, _ code: String) -> String {
    isTTY ? "\u{1B}[\(code)m\(text)\u{1B}[0m" : text
  }
}
