import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Listens for control keys on the TTY while a turn is streaming: Ctrl-O toggles
/// verbose tool output, Ctrl-C cancels the turn (raw mode disables ISIG, so the
/// byte arrives here instead of as SIGINT).
///
/// Runs on a background thread with a polling read so `stop()` can wait for it to
/// let go of stdin before the prompt's `LineReader` takes over. While the watcher
/// owns stdin, permission prompts read their y/n/a keypress through `readKey()` —
/// two blocking readers on one fd would steal each other's bytes.
///
/// Everything else typed during a turn is type-ahead: printable characters buffer
/// (backspace honored, escape sequences dropped) and `drainTypeahead()` hands the
/// text back after the turn — completed lines run as the next inputs, an unfinished
/// fragment pre-fills the next prompt. A no-op when stdin isn't a TTY.
final class KeyWatcher: @unchecked Sendable {
  var onCtrlO: (@Sendable () -> Void)?
  var onInterrupt: (@Sendable () -> Void)?
  /// Fires after every type-ahead change with the unfinished fragment (text after the
  /// last Enter) and how many completed lines are queued — lets the pinned input box
  /// show what's being typed mid-turn instead of buffering it blind.
  var onTypeahead: (@Sendable (String, Int) -> Void)?

  private let lock = NSLock()
  private var active = false
  private var pendingKey: CheckedContinuation<String?, Never>?
  private var original = termios()
  private var finished: DispatchSemaphore?
  private let isTTY = isatty(STDIN_FILENO) != 0

  private var typeahead: [UInt8] = []
  private enum EscapeState { case none, sawEscape, inSequence }
  private var escapeState = EscapeState.none

  var isActive: Bool {
    lock.withLock { active }
  }

  func start() {
    guard isTTY else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !active else { return }
    active = true
    escapeState = .none
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    let done = DispatchSemaphore(value: 0)
    finished = done
    Thread.detachNewThread { [weak self] in
      self?.watch()
      done.signal()
    }
  }

  func stop() {
    guard isTTY else { return }
    lock.lock()
    guard active else {
      lock.unlock()
      return
    }
    active = false
    let done = finished
    finished = nil
    let waiting = pendingKey
    pendingKey = nil
    lock.unlock()
    waiting?.resume(returning: nil)
    done?.wait()
    var restore = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
  }

  /// The next keypress, for a permission prompt while the watcher owns stdin.
  /// Returns nil immediately when the watcher isn't running (caller reads stdin
  /// itself) or if the watcher stops while waiting.
  func readKey() async -> String? {
    await withCheckedContinuation { continuation in
      lock.lock()
      guard active, pendingKey == nil else {
        lock.unlock()
        continuation.resume(returning: nil)
        return
      }
      pendingKey = continuation
      lock.unlock()
    }
  }

  private func watch() {
    while isActive {
      var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      guard poll(&fds, 1, 50) > 0, fds.revents & Int16(POLLIN) != 0 else { continue }
      var byte: UInt8 = 0
      guard read(STDIN_FILENO, &byte, 1) == 1 else { return }
      lock.lock()
      if let continuation = pendingKey {
        pendingKey = nil
        lock.unlock()
        continuation.resume(returning: String(UnicodeScalar(byte)))
        continue
      }
      lock.unlock()
      switch byte {
      case 0x0F: // Ctrl-O
        onCtrlO?()
      case 0x03: // Ctrl-C
        onInterrupt?()
      default:
        if let state = bufferTypeahead(byte) {
          onTypeahead?(state.fragment, state.queued)
        }
      }
    }
  }

  // MARK: Type-ahead

  /// Text typed while the watcher owned stdin, in order; clears the buffer.
  /// Enter arrives as "\n" so callers can split completed lines from a fragment.
  func drainTypeahead() -> String {
    lock.withLock {
      defer { typeahead.removeAll() }
      return String(decoding: typeahead, as: UTF8.self)
    }
  }

  /// Returns the buffer's new (fragment, queued-line count) when it changed, so the
  /// caller can notify `onTypeahead` outside the lock.
  private func bufferTypeahead(_ byte: UInt8) -> (fragment: String, queued: Int)? {
    lock.lock()
    defer { lock.unlock() }
    // Swallow escape sequences (arrows, etc.) — they'd land as garbage in the text.
    switch escapeState {
    case .sawEscape:
      // "[" (CSI) and "O" (SS3) open multi-byte sequences; anything else was a
      // two-byte Alt+key pair that ends here.
      escapeState = (byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O")) ? .inSequence : .none
      return nil
    case .inSequence:
      if (0x40...0x7E).contains(byte) {
        escapeState = .none
      }
      return nil
    case .none:
      break
    }
    switch byte {
    case 0x1B:
      escapeState = .sawEscape
      return nil
    case 0x0A, 0x0D: // enter — completes a queued line
      typeahead.append(0x0A)
    case 0x7F, 0x08: // backspace — undo the last typed character
      while let last = typeahead.last, (0x80...0xBF).contains(last) {
        typeahead.removeLast()
      }
      if !typeahead.isEmpty {
        typeahead.removeLast()
      }
    case 0x00..<0x20:
      return nil // other control keys aren't text
    default:
      typeahead.append(byte)
    }
    let lastNewline = typeahead.lastIndex(of: 0x0A)
    let fragmentBytes = lastNewline.map { Array(typeahead[typeahead.index(after: $0)...]) } ?? typeahead
    let queued = typeahead.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    return (String(decoding: fragmentBytes, as: UTF8.self), queued)
  }
}
