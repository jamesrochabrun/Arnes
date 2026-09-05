import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// One-shot keyboard reads for prompts outside a streaming turn (the trust question at
/// startup, eval-capture confirmation, the permission prompt when no `KeyWatcher` owns
/// stdin).
enum TerminalInput {
  /// stdin and stdout are both a terminal — prompting is possible.
  static var isInteractive: Bool {
    isatty(STDIN_FILENO) != 0 && isatty(STDOUT_FILENO) != 0
  }

  /// Single raw keypress on a TTY; first character of a line otherwise (piped input).
  static func readKey() -> String? {
    guard isatty(STDIN_FILENO) != 0 else {
      return readLine().map { String($0.prefix(1)) }
    }
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    defer {
      var restore = original
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
    }
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
    return String(UnicodeScalar(byte))
  }

  /// Prints `question` and reads one key; true for `y`/`Y`.
  static func confirm(_ question: String) -> Bool {
    print(question + " ", terminator: "")
    fflush(stdout)
    let key = readKey()
    print(key.map { $0 < " " ? "" : $0 } ?? "")
    return key?.lowercased() == "y"
  }
}
