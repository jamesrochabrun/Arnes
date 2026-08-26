import Foundation
import Splash

/// Streams assistant markdown as ANSI-styled terminal output without waiting for the
/// full message. Prose flows through as it arrives (with `inline code` and **bold**
/// styled on the fly); each line's shape — heading, bullet, quote, code fence — is
/// decided from its first few characters; fenced code buffers one line at a time and
/// renders behind a dim gutter, with Swift highlighted via Splash.
///
/// When `styled` is false (piped output) every delta passes through untouched, so
/// non-TTY consumers keep the raw markdown.
final class StreamingMarkdown {
  private enum Mode {
    /// Collecting the first characters of a line until its shape is known.
    case lineStart(String)
    case prose
    case heading
    case quote
    /// Saw ``` at a line start — collecting the language until newline.
    case fenceHeader(String)
    /// Inside a fence, buffering the current line so it can be highlighted whole.
    case code(language: String, line: String)
  }

  private var mode: Mode = .lineStart("")
  private var bold = false
  private var inlineCode = false
  /// A trailing `*` held back until the next character decides `**` vs a literal star.
  private var pendingAsterisk = false
  private let styled: Bool
  #if os(Linux)
  // Splash's SwiftGrammar builds its delimiter set by mutating an inverted CharacterSet,
  // which aborts in corelibs-foundation — Swift code renders unhighlighted on Linux.
  private let highlighter: SyntaxHighlighter<ANSICodeFormat>? = nil
  #else
  private let highlighter: SyntaxHighlighter<ANSICodeFormat>? = SyntaxHighlighter(format: ANSICodeFormat())
  #endif

  init(styled: Bool = ANSI.isTTY) {
    self.styled = styled
  }

  func feed(_ delta: String) -> String {
    guard styled else { return delta }
    var out = ""
    for character in delta {
      out += consume(character)
    }
    return out
  }

  /// Emits anything still buffered, closes open styles, and resets for the next message.
  func flush() -> String {
    guard styled else { return "" }
    var out = ""
    if pendingAsterisk {
      pendingAsterisk = false
      out += "*"
    }
    switch mode {
    case .lineStart(let buffer):
      out += buffer
    case .code(_, let line):
      // A message often ends on the closing ``` with no trailing newline; close the
      // box instead of printing the fence as a code line. An interrupted block still
      // shows its partial line before closing.
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty, !trimmed.hasPrefix("```") {
        out += gutter() + line + "\n"
      }
      out += Self.dim + "╰─" + Self.reset
    case .fenceHeader, .prose, .heading, .quote:
      break
    }
    switch mode {
    case .heading, .quote:
      out += Self.reset
    default:
      if bold || inlineCode { out += Self.reset }
    }
    bold = false
    inlineCode = false
    mode = .lineStart("")
    return out
  }

  // MARK: State machine

  private func consume(_ character: Character) -> String {
    switch mode {
    case .lineStart(let buffer):
      return consumeAtLineStart(buffer, character)

    case .prose:
      return consumeInline(character)

    case .heading, .quote:
      if character == "\n" {
        mode = .lineStart("")
        return Self.reset + "\n"
      }
      return String(character)

    case .fenceHeader(let info):
      if character == "\n" {
        let language = info.trimmingCharacters(in: .whitespaces)
        mode = .code(language: language, line: "")
        return Self.dim + "╭─ " + (language.isEmpty ? "code" : language) + Self.reset + "\n"
      }
      mode = .fenceHeader(info + String(character))
      return ""

    case .code(let language, let line):
      if character == "\n" {
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
          mode = .lineStart("")
          return Self.dim + "╰─" + Self.reset + "\n"
        }
        mode = .code(language: language, line: "")
        return gutter() + highlight(line, language: language) + "\n"
      }
      mode = .code(language: language, line: line + String(character))
      return ""
    }
  }

  private func consumeAtLineStart(_ buffer: String, _ character: Character) -> String {
    if character == "\n" {
      // The line ended while its shape was still ambiguous ("-", "###", "12") —
      // it was plain text all along.
      mode = .lineStart("")
      return buffer + "\n"
    }
    let extended = buffer + String(character)
    if extended == "```" {
      mode = .fenceHeader("")
      return ""
    }
    if let rendered = renderStructuralPrefix(extended) {
      return rendered
    }
    if Self.couldBecomeStructural(extended) {
      mode = .lineStart(extended)
      return ""
    }
    // Plain prose — replay the withheld characters through inline styling.
    mode = .prose
    return extended.reduce(into: "") { $0 += consumeInline($1) }
  }

  /// When `line` completes a structural prefix, switches mode and returns its styled
  /// replacement; nil means "not structural (yet)".
  private func renderStructuralPrefix(_ line: String) -> String? {
    let indentCount = line.prefix(while: { $0 == " " }).count
    guard indentCount <= 6 else { return nil }
    let indent = String(repeating: " ", count: indentCount)
    let rest = line.dropFirst(indentCount)

    let hashes = rest.prefix(while: { $0 == "#" })
    if !hashes.isEmpty, hashes.count <= 6, rest.dropFirst(hashes.count) == " " {
      mode = .heading
      return indent + Self.bold + Self.cyan
    }
    if rest == "- " || rest == "* " {
      mode = .prose
      return indent + Self.cyan + "•" + Self.reset + " "
    }
    if rest == "> " {
      mode = .quote
      return indent + Self.dim + "│ "
    }
    let digits = rest.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count <= 3, rest.dropFirst(digits.count) == ". " {
      mode = .prose
      return indent + String(rest)
    }
    return nil
  }

  /// Whether `line` is still a prefix of some structural marker and should stay buffered.
  private static func couldBecomeStructural(_ line: String) -> Bool {
    let indent = line.prefix(while: { $0 == " " })
    guard indent.count <= 6 else { return false }
    let rest = line.dropFirst(indent.count)
    if rest.isEmpty { return true }
    if rest.allSatisfy({ $0 == "#" }), rest.count <= 6 { return true }
    if rest.allSatisfy({ $0 == "`" }), rest.count <= 2 { return true }
    if rest == "-" || rest == "*" || rest == ">" { return true }
    let digits = rest.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count <= 3 {
      let tail = rest.dropFirst(digits.count)
      if tail.isEmpty || tail == "." { return true }
    }
    return false
  }

  private func consumeInline(_ character: Character) -> String {
    if pendingAsterisk {
      pendingAsterisk = false
      if character == "*" {
        bold.toggle()
        return bold ? Self.bold : Self.boldOff
      }
      return "*" + consumeInline(character)
    }
    switch character {
    case "*":
      pendingAsterisk = true
      return ""
    case "`":
      inlineCode.toggle()
      return inlineCode ? Self.cyan : Self.fgReset
    case "\n":
      mode = .lineStart("")
      return "\n"
    default:
      return String(character)
    }
  }

  // MARK: Styling

  private func gutter() -> String {
    Self.dim + "│ " + Self.reset
  }

  private func highlight(_ line: String, language: String) -> String {
    guard let highlighter, language.lowercased() == "swift" else { return line }
    return highlighter.highlight(line)
  }

  private static let bold = "\u{1B}[1m"
  private static let boldOff = "\u{1B}[22m"
  private static let cyan = "\u{1B}[36m"
  private static let fgReset = "\u{1B}[39m"
  private static let dim = "\u{1B}[2m"
  private static let reset = "\u{1B}[0m"
}

// MARK: - ANSICodeFormat

/// Splash output format that emits ANSI-colored tokens for the terminal.
struct ANSICodeFormat: OutputFormat {
  struct Builder: OutputBuilder {
    private var output = ""

    mutating func addToken(_ token: String, ofType type: TokenType) {
      output += ANSICodeFormat.color(for: type) + token + "\u{1B}[0m"
    }

    mutating func addPlainText(_ text: String) {
      output += text
    }

    mutating func addWhitespace(_ whitespace: String) {
      output += whitespace
    }

    func build() -> String {
      output
    }
  }

  func makeBuilder() -> Builder {
    Builder()
  }

  static func color(for type: TokenType) -> String {
    switch type {
    case .keyword: return "\u{1B}[35m"
    case .string: return "\u{1B}[32m"
    case .type: return "\u{1B}[33m"
    case .call: return "\u{1B}[36m"
    case .number: return "\u{1B}[35m"
    case .comment: return "\u{1B}[2m"
    case .property, .dotAccess: return "\u{1B}[36m"
    case .preprocessing: return "\u{1B}[33m"
    case .custom: return ""
    }
  }
}
