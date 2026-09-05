import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Listens for control keys on the TTY while a turn is streaming: Ctrl-O toggles
/// verbose tool output, Esc or Ctrl-C cancels the turn (raw mode disables ISIG, so
/// the byte arrives here instead of as SIGINT). A bare Esc is told apart from the
/// ESC that opens an arrow-key sequence by a short poll — sequences arrive as one
/// burst, a lone press is followed by silence.
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
///
/// A model's question (`ask_user`) needs a whole *line* mid-turn: `readLine(afterQuietFor:)`
/// turns the input box into the answer field until Enter — see `LineCapture`.
final class KeyWatcher: @unchecked Sendable {
  var onCtrlO: (@Sendable () -> Void)?
  /// Ctrl-T mid-turn: the reasoning-display toggle (`/thinking`).
  var onCtrlT: (@Sendable () -> Void)?
  var onInterrupt: (@Sendable () -> Void)?
  /// Fires after every type-ahead change with the unfinished fragment (text after the
  /// last Enter) and how many completed lines are queued — lets the pinned input box
  /// show what's being typed mid-turn instead of buffering it blind.
  var onTypeahead: (@Sendable (String, Int) -> Void)?
  /// A DSR cursor-position report arrived mid-turn (the screen requests one after a
  /// resize) — forwards the 1-based row.
  var onCursorReport: (@Sendable (Int) -> Void)?

  private let lock = NSLock()
  private var active = false
  private var pendingKey: CheckedContinuation<String?, Never>?
  private var original = termios()
  private var finished: DispatchSemaphore?
  private let isTTY = isatty(STDIN_FILENO) != 0

  private var typeahead: [UInt8] = []
  /// When the last type-ahead text key was buffered — a permission prompt that opens
  /// while the user is mid-sentence must not take the next letter as its answer.
  private var lastTypeaheadAt: Date?
  /// How long typing has to pause before a keystroke counts as a prompt answer.
  static let answerQuietInterval: TimeInterval = 1.0
  private enum EscapeState { case none, sawEscape, inSequence }
  private var escapeState = EscapeState.none
  private var escapeParams: [UInt8] = []
  private var escapeIsCSI = false

  /// The answer line being assembled for `readLine`, while one is waiting; bytes are routed
  /// here instead of the type-ahead buffer so a pasted answer can't split between the two.
  private var lineCapture: LineCapture?
  private var pendingLine: CheckedContinuation<String?, Never>?
  private var lineQuiet: TimeInterval = 0
  private var lineDefer: (@Sendable () -> Void)?

  /// A bracketed paste in flight for the type-ahead buffer (`ESC[200~` seen, end marker not
  /// yet) — its bytes collect here so a multi-line paste never queues one message per line.
  private var typeaheadPaste: PasteCapture?
  /// An escape sequence being assembled for a pending `readKey`: nil = not assembling,
  /// `[]` = the ESC just arrived, then the opener (`[`/`O`) plus what follows. A prompt
  /// must receive an arrow key as one token — resolving on the bare ESC byte used to
  /// read every arrow press as an interrupt, and its `[A` tail landed in the input box.
  private var promptEscape: [UInt8]?
  /// Open `beginPrompt()`/`endPrompt()` brackets. While a prompt session is open, bytes
  /// keep flowing to the prompt even between two `readKey` registrations — the permission
  /// panel reads key after key, and a key landing in the microseconds between reads must
  /// not leak into the type-ahead buffer.
  private var promptSessions = 0
  /// Tokens resolved while a prompt session was open but no read was waiting, drained by
  /// the next `readKey()`. Bounded — a prompt is a question, not a text field.
  private var promptQueue: [String] = []
  private static let maxQueuedPromptKeys = 8
  /// Where a collapsed paste's full text is kept; nil buffers pastes literally (newlines
  /// as spaces, so they still never auto-submit).
  private let pastes: PasteStore?

  init(pastes: PasteStore? = nil) {
    self.pastes = pastes
  }

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
    typeaheadPaste = nil
    promptEscape = nil
    promptQueue.removeAll()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    // IEXTEN too: with it set the tty driver eats Ctrl-O as VDISCARD ("flush output")
    // on macOS, so the verbose toggle's byte never reached the process at all.
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ISIG | IEXTEN)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    // Bracketed paste: a mid-turn paste arrives as one marked event, so its newlines land
    // in the buffer as content instead of queueing one message per line.
    FileHandle.standardOutput.write(Data("\u{1B}[?2004h".utf8))
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
    let waitingLine = pendingLine
    pendingLine = nil
    lineCapture = nil
    lineDefer = nil
    promptEscape = nil
    lock.unlock()
    waiting?.resume(returning: nil)
    waitingLine?.resume(returning: nil)
    done?.wait()
    FileHandle.standardOutput.write(Data("\u{1B}[?2004l".utf8))
    var restore = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
  }

  /// Opens a prompt session: until the matching `endPrompt()`, every byte belongs to the
  /// prompt (queued for the next `readKey` when none is waiting) instead of the type-ahead
  /// buffer. The permission panel brackets its whole key loop with this.
  func beginPrompt() {
    lock.withLock { promptSessions += 1 }
  }

  /// Closes a prompt session; undrained tokens die with it.
  func endPrompt() {
    lock.withLock {
      promptSessions = max(0, promptSessions - 1)
      if promptSessions == 0 {
        promptQueue.removeAll()
        promptEscape = nil
      }
    }
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
      if !promptQueue.isEmpty {
        let token = promptQueue.removeFirst()
        lock.unlock()
        continuation.resume(returning: token)
        return
      }
      pendingKey = continuation
      lock.unlock()
    }
  }

  /// A keypress meant as an *answer*: while the user was typing within `quiet`
  /// seconds, text keys keep flowing into the type-ahead buffer (so the sentence
  /// survives intact) and `onDefer` fires so the prompt can say "pause, then answer".
  /// Esc and control keys are never deferred — cancelling must always work — except
  /// Enter when `deferringEnter` is set: the permission panel's Enter confirms the
  /// highlighted option, so an Enter meant to finish a queued sentence must stay a
  /// queued line, not an approval.
  func readKey(
    afterQuietFor quiet: TimeInterval,
    deferringEnter: Bool = false,
    onDefer: @Sendable () -> Void = {}) async -> String?
  {
    while true {
      guard let key = await readKey() else { return nil }
      let lastTyped = lock.withLock { lastTypeaheadAt }
      guard
        Self.shouldDefer(
          key: key, lastTypeaheadAt: lastTyped, now: Date(), quiet: quiet,
          deferringEnter: deferringEnter)
      else {
        return key
      }
      requeueAsTypeahead(key)
      onDefer()
    }
  }

  /// Whether `key` arrived too soon after type-ahead text to be an answer.
  static func shouldDefer(
    key: String,
    lastTypeaheadAt: Date?,
    now: Date,
    quiet: TimeInterval,
    deferringEnter: Bool = false) -> Bool
  {
    guard let lastTypeaheadAt, let scalar = key.unicodeScalars.first else { return false }
    if scalar.value == 0x0A || scalar.value == 0x0D {
      // Enter completes the sentence being typed when the caller asked for it.
      return deferringEnter && now.timeIntervalSince(lastTypeaheadAt) < quiet
    }
    guard scalar.value >= 0x20, scalar.value != 0x7F else { return false } // Esc, Ctrl-*, backspace answer/cancel as usual
    return now.timeIntervalSince(lastTypeaheadAt) < quiet
  }

  /// Puts a key the prompt declined back where the user meant it: the input box.
  private func requeueAsTypeahead(_ key: String) {
    for scalar in key.unicodeScalars {
      // `watch()` hands the prompt single bytes (`UnicodeScalar(byte)`), so the
      // scalar's value is the original byte.
      if case .changed(let fragment, let queued) = bufferTypeahead(UInt8(truncatingIfNeeded: scalar.value)) {
        onTypeahead?(fragment, queued)
      }
    }
  }

  private func watch() {
    while isActive {
      var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
      guard poll(&fds, 1, 50) > 0, fds.revents & Int16(POLLIN) != 0 else { continue }
      var byte: UInt8 = 0
      guard read(STDIN_FILENO, &byte, 1) == 1 else { return }
      lock.lock()
      let prompting = pendingKey != nil || promptSessions > 0
      let capturing = lineCapture != nil
      let pasting = typeaheadPaste != nil || lineCapture?.isPasting == true
      lock.unlock()
      // A paste's content is data: a control byte inside it (the end marker's ESC included)
      // must not toggle anything or interrupt the turn — and a paste that began while a
      // permission prompt was open collects as type-ahead instead of answering it, so a
      // stray `y` in pasted text can never approve a call.
      if pasting {
        route(byte, capturing: capturing)
        continue
      }
      if prompting {
        feedPrompt(byte)
        continue
      }
      switch byte {
      case 0x0F: // Ctrl-O
        onCtrlO?()
      case 0x14: // Ctrl-T
        onCtrlT?()
      case 0x03: // Ctrl-C
        // The turn is being cancelled; a question waiting on it dies with it — resolved first,
        // or the session (which awaits the tool's answer) could never see the cancellation.
        if capturing { resolveLine(nil) }
        onInterrupt?()
      case 0x1B where !isMidEscape && !inputPending(withinMs: 25): // bare Esc
        if capturing { resolveLine("\u{1B}") } else { onInterrupt?() }
      default:
        route(byte, capturing: capturing)
      }
    }
  }

  /// A byte for the pending `readKey`: printable keys resolve at once; an ESC that opens a
  /// sequence is assembled so the prompt gets `"\u{1B}[A"` as one token (a bare Esc still
  /// resolves as `"\u{1B}"`). Two sequences are intercepted rather than handed over: a DSR
  /// cursor report goes to `onCursorReport` (it belongs to the screen, not the question),
  /// and a bracketed-paste opener starts a type-ahead paste — pasted bytes must never
  /// answer a permission prompt.
  private func feedPrompt(_ byte: UInt8) {
    lock.lock()
    guard pendingKey != nil else {
      lock.unlock()
      return // raced with stop(); the byte is dropped with the prompt
    }
    if var sequence = promptEscape {
      if sequence.isEmpty {
        guard byte == UInt8(ascii: "[") || byte == UInt8(ascii: "O") else {
          // A two-byte Alt+key pair; the prompt ignores unknown tokens.
          promptEscape = nil
          resolvePromptLocked("\u{1B}" + String(UnicodeScalar(byte)))
          return
        }
        sequence.append(byte)
        promptEscape = sequence
        lock.unlock()
        return
      }
      let isCSI = sequence.first == UInt8(ascii: "[")
      if isCSI, !(0x40...0x7E).contains(byte) {
        sequence.append(byte)
        promptEscape = sequence
        lock.unlock()
        return
      }
      // The sequence's final byte.
      promptEscape = nil
      let params = Array(sequence.dropFirst())
      if isCSI, byte == UInt8(ascii: "R"), let row = LineReader.reportRow(params) {
        lock.unlock()
        onCursorReport?(row)
        return
      }
      if isCSI, byte == UInt8(ascii: "~"), params == PasteCapture.startParams {
        typeaheadPaste = PasteCapture()
        lock.unlock()
        return
      }
      sequence.append(byte)
      resolvePromptLocked("\u{1B}" + String(decoding: sequence, as: UTF8.self))
      return
    }
    if byte == 0x1B {
      lock.unlock()
      if inputPending(withinMs: 25) {
        lock.withLock { promptEscape = [] }
        return
      }
      lock.lock()
      resolvePromptLocked("\u{1B}")
      return
    }
    resolvePromptLocked(String(UnicodeScalar(byte)))
  }

  /// Hands `token` to the pending `readKey`, or queues it for the next one while a prompt
  /// session is open. The caller holds the lock; this releases it.
  private func resolvePromptLocked(_ token: String) {
    if let continuation = pendingKey {
      pendingKey = nil
      lock.unlock()
      continuation.resume(returning: token)
      return
    }
    if promptSessions > 0, promptQueue.count < Self.maxQueuedPromptKeys {
      promptQueue.append(token)
    }
    lock.unlock()
  }

  /// Hands a byte to whoever assembles text right now: the answer line while a `readLine`
  /// waits, the type-ahead buffer otherwise.
  private func route(_ byte: UInt8, capturing: Bool) {
    if capturing {
      feedLine(byte)
    } else {
      switch bufferTypeahead(byte) {
      case .changed(let fragment, let queued):
        onTypeahead?(fragment, queued)
      case .cursorReport(let row):
        onCursorReport?(row)
      case .none:
        break
      }
    }
  }

  private var isMidEscape: Bool {
    lock.withLock { escapeState != .none || lineCapture?.isMidEscape == true }
  }

  /// Whether another byte is already behind this one — distinguishes an escape
  /// sequence's ESC (followed immediately by "[" etc.) from a lone Esc press.
  private func inputPending(withinMs timeout: Int32) -> Bool {
    var fds = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    return poll(&fds, 1, timeout) > 0 && fds.revents & Int16(POLLIN) != 0
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

  private enum TypeaheadEvent {
    case none
    case changed(fragment: String, queued: Int)
    case cursorReport(row: Int)
  }

  /// Returns what the byte amounted to — a type-ahead change, a captured DSR
  /// cursor-position report, or nothing — so the caller can notify outside the lock.
  private func bufferTypeahead(_ byte: UInt8) -> TypeaheadEvent {
    lock.lock()
    defer { lock.unlock() }
    // A paste in flight: everything up to the end marker is its content, then the whole
    // paste lands in the buffer at once — collapsed to a placeholder when it's multi-line.
    if var paste = typeaheadPaste {
      if case .finished(let raw) = paste.feed(byte) {
        typeaheadPaste = nil
        return appendPaste(raw)
      }
      typeaheadPaste = paste
      return .none
    }
    // Swallow escape sequences (arrows, etc.) — they'd land as garbage in the text.
    switch escapeState {
    case .sawEscape:
      // "[" (CSI) and "O" (SS3) open multi-byte sequences; anything else was a
      // two-byte Alt+key pair that ends here.
      escapeIsCSI = byte == UInt8(ascii: "[")
      escapeState = (escapeIsCSI || byte == UInt8(ascii: "O")) ? .inSequence : .none
      escapeParams = []
      return .none
    case .inSequence:
      if (0x40...0x7E).contains(byte) {
        escapeState = .none
        // ESC [ row ; col R — the terminal answering the screen's resize query.
        if escapeIsCSI, byte == UInt8(ascii: "R"), let row = LineReader.reportRow(escapeParams) {
          return .cursorReport(row: row)
        }
        // ESC [ 200 ~ — bracketed paste begins; content collects until ESC[201~.
        if escapeIsCSI, byte == UInt8(ascii: "~"), escapeParams == PasteCapture.startParams {
          typeaheadPaste = PasteCapture()
        }
      } else {
        escapeParams.append(byte)
      }
      return .none
    case .none:
      break
    }
    switch byte {
    case 0x1B:
      escapeState = .sawEscape
      return .none
    case 0x0A, 0x0D: // enter — completes a queued line
      typeahead.append(0x0A)
    case 0x7F, 0x08: // backspace — undo the last typed character
      while let last = typeahead.last, (0x80...0xBF).contains(last) {
        typeahead.removeLast()
      }
      if !typeahead.isEmpty {
        typeahead.removeLast()
      }
      lastTypeaheadAt = Date()
    case 0x00..<0x20:
      return .none // other control keys aren't text
    default:
      typeahead.append(byte)
      lastTypeaheadAt = Date()
    }
    return typeaheadChanged()
  }

  /// The `.changed` event for the buffer as it stands. Caller holds the lock.
  private func typeaheadChanged() -> TypeaheadEvent {
    let lastNewline = typeahead.lastIndex(of: 0x0A)
    let fragmentBytes = lastNewline.map { Array(typeahead[typeahead.index(after: $0)...]) } ?? typeahead
    let queued = typeahead.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    return .changed(fragment: String(decoding: fragmentBytes, as: UTF8.self), queued: queued)
  }

  /// A finished paste enters the type-ahead buffer as one piece: a placeholder when it's
  /// multi-line or oversized (the store keeps the full text for expansion at submit), the
  /// literal text otherwise — never a raw newline, so a paste can't queue messages.
  /// Caller holds the lock.
  private func appendPaste(_ raw: String) -> TypeaheadEvent {
    let text = PasteStore.normalize(raw)
    guard !text.isEmpty else { return .none }
    let inserted: String
    if let pastes, let image = PasteStore.imagePath(from: text) {
      // A dragged image arrives as its path — collapsed so the leading `/` can't read
      // as a slash command; expanded back to the clean path at submit. A screenshot-
      // thumbnail drag is copied out right now, before its OS grant dies; the note (a
      // failed copy) has no channel here — view_image's own error says it a step later.
      inserted = pastes.storeImage(image).placeholder
    } else if let pastes, PasteStore.shouldCollapse(text) {
      inserted = pastes.store(text)
    } else {
      inserted = PasteStore.inlineText(text)
    }
    typeahead.append(contentsOf: Array(inserted.utf8))
    lastTypeaheadAt = Date()
    return typeaheadChanged()
  }

  // MARK: Answer lines (`ask_user`)

  /// A whole line typed as the answer to the model's question, with the pinned input box as the
  /// answer field. The rule: lines the user had already **completed** during the turn stay
  /// queued as messages (they were typed before the question existed), the unfinished fragment
  /// visible in the box is the start of the answer, and keys arriving from now on extend it —
  /// backspace edits, escape sequences are swallowed as `bufferTypeahead` swallows them — until
  /// Enter returns the line. A bare Esc returns `"\u{1B}"` (the caller reads it as "declined");
  /// Ctrl-C cancels the turn and returns nil; `stop()` and `cancelLine()` return nil. nil at once
  /// when the watcher isn't running (the caller reads stdin itself) or another read is pending.
  ///
  /// The permission prompt's quiet-interval guard applies to the **first** byte while the answer
  /// is still empty: a text key within `quiet` of the last type-ahead keeps going to the box (the
  /// sentence the user was typing survives) and `onDefer` fires so the prompt can say "pause,
  /// then answer". Once a byte has landed in the answer, or the fragment gave it a start, every
  /// key is the answer's. `onTypeahead` is refreshed as the answer is edited so the box shows it,
  /// and once more with the remaining type-ahead when the line is done.
  func readLine(afterQuietFor quiet: TimeInterval, onDefer: @escaping @Sendable () -> Void = {}) async -> String? {
    await withCheckedContinuation { continuation in
      lock.lock()
      // A task cancelled before the line registers would otherwise wait for a key nobody
      // owes it: its `cancelLine` has already run and found nothing.
      guard active, !Task.isCancelled, pendingKey == nil, pendingLine == nil else {
        lock.unlock()
        continuation.resume(returning: nil)
        return
      }
      let (queued, fragment) = Self.splitAnswer(buffer: typeahead)
      typeahead = queued
      lineCapture = LineCapture(bytes: fragment)
      lineQuiet = quiet
      lineDefer = onDefer
      pendingLine = continuation
      lock.unlock()
    }
  }

  /// Ends a waiting `readLine` with nil — what a cancelled turn calls so the tool awaiting the
  /// answer can return and the session see the cancellation. A no-op when nothing is waiting.
  func cancelLine() {
    resolveLine(nil)
  }

  /// The type-ahead buffer split for `readLine`: everything up to and including the last Enter
  /// stays queued (completed lines, newline-terminated), what follows is the fragment the
  /// answer starts from. A buffer with no Enter is all fragment; an empty one is neither.
  static func splitAnswer(buffer: [UInt8]) -> (queued: [UInt8], fragment: [UInt8]) {
    guard let lastNewline = buffer.lastIndex(of: 0x0A) else { return ([], buffer) }
    return (Array(buffer[...lastNewline]), Array(buffer[buffer.index(after: lastNewline)...]))
  }

  /// `splitAnswer` over text, the way `drainTypeahead` hands the buffer out: completed lines
  /// (without their newlines) and the fragment.
  static func splitAnswer(buffer text: String) -> (queued: [String], fragment: String) {
    let (queued, fragment) = splitAnswer(buffer: Array(text.utf8))
    let lines = String(decoding: queued, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init).dropLast() // the trailing newline leaves one empty piece
    return (Array(lines), String(decoding: fragment, as: UTF8.self))
  }

  private func feedLine(_ byte: UInt8) {
    lock.lock()
    guard var capture = lineCapture else {
      lock.unlock()
      return
    }
    // The guard against a keystroke meant for the sentence in flight: a text key arriving
    // before the answer has a first byte and within the quiet interval of the last type-ahead
    // goes where the user meant it, the input box.
    // Never mid-sequence: an arrow key's `[A` is printable bytes that belong to the ESC the
    // capture already swallowed, not a sentence in flight. Never mid-paste either — the
    // content bytes belong to the paste, whatever the typing rhythm was.
    if !capture.started, !capture.isMidEscape, !capture.isPasting,
      Self.shouldDefer(key: String(UnicodeScalar(byte)), lastTypeaheadAt: lastTypeaheadAt, now: Date(), quiet: lineQuiet)
    {
      let onDefer = lineDefer
      lock.unlock()
      requeueAsTypeahead(String(UnicodeScalar(byte)))
      onDefer?()
      return
    }
    let queued = typeahead.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    switch capture.feed(byte) {
    case .none:
      lineCapture = capture
      lock.unlock()
    case .changed:
      lineCapture = capture
      lock.unlock()
      onTypeahead?(capture.text, queued)
    case .line(let text):
      lock.unlock()
      resolveLine(text)
    }
  }

  /// Hands `result` to the waiting `readLine` (if any) and puts the box back to showing the
  /// type-ahead that stays queued behind the answer.
  private func resolveLine(_ result: String?) {
    lock.lock()
    guard let continuation = pendingLine else {
      lock.unlock()
      return
    }
    pendingLine = nil
    lineCapture = nil
    lineDefer = nil
    let lastNewline = typeahead.lastIndex(of: 0x0A)
    let fragmentBytes = lastNewline.map { Array(typeahead[typeahead.index(after: $0)...]) } ?? typeahead
    let queued = typeahead.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
    lock.unlock()
    continuation.resume(returning: result)
    onTypeahead?(String(decoding: fragmentBytes, as: UTF8.self), queued)
  }

  /// The answer to a model's question, assembled byte by byte from a raw-mode TTY: printable
  /// and UTF-8 bytes append, backspace removes the last character (whole, not one byte of it),
  /// Enter completes the line, escape sequences (arrows, function keys, a cursor report) are
  /// swallowed the way the type-ahead buffer swallows them, other control bytes are ignored.
  /// A bare Esc is the caller's to detect — it needs the poll that tells a lone press from the
  /// ESC opening a sequence — so a 0x1B reaching `feed` is always a sequence's.
  struct LineCapture: Equatable {
    private(set) var bytes: [UInt8]
    /// Whether the answer has had a first byte — from the fragment it started with, or typed
    /// since. Only before that does the quiet-interval guard apply.
    private(set) var started: Bool
    private var escapeState = EscapeState.none
    private var escapeIsCSI = false
    private var escapeParams: [UInt8] = []
    /// A bracketed paste in flight for the answer — inserted whole when its end marker
    /// lands, newlines as spaces (an answer is one line), so it can't submit early.
    private var paste: PasteCapture?

    enum Event: Equatable {
      /// The byte was consumed without changing the visible answer (a sequence, a control key).
      case none
      /// The answer text changed.
      case changed
      /// Enter: the finished line.
      case line(String)
    }

    init(bytes: [UInt8] = []) {
      self.bytes = bytes
      started = !bytes.isEmpty
    }

    var text: String { String(decoding: bytes, as: UTF8.self) }
    var isEmpty: Bool { bytes.isEmpty }
    var isMidEscape: Bool { escapeState != .none }
    var isPasting: Bool { paste != nil }

    mutating func feed(_ byte: UInt8) -> Event {
      if var capture = paste {
        if case .finished(let raw) = capture.feed(byte) {
          paste = nil
          let inserted = PasteStore.inlineText(PasteStore.normalize(raw))
          guard !inserted.isEmpty else { return .none }
          bytes.append(contentsOf: Array(inserted.utf8))
          started = true
          return .changed
        }
        paste = capture
        return .none
      }
      switch escapeState {
      case .sawEscape:
        escapeIsCSI = byte == UInt8(ascii: "[")
        escapeState = (escapeIsCSI || byte == UInt8(ascii: "O")) ? .inSequence : .none
        escapeParams = []
        return .none
      case .inSequence:
        if (0x40...0x7E).contains(byte) {
          escapeState = .none
          if escapeIsCSI, byte == UInt8(ascii: "~"), escapeParams == PasteCapture.startParams {
            paste = PasteCapture()
          }
        } else {
          escapeParams.append(byte)
        }
        return .none
      case .none:
        break
      }
      switch byte {
      case 0x1B:
        escapeState = .sawEscape
        return .none
      case 0x0A, 0x0D:
        return .line(text)
      case 0x7F, 0x08:
        while let last = bytes.last, (0x80...0xBF).contains(last) {
          bytes.removeLast()
        }
        guard !bytes.isEmpty else { return .none }
        bytes.removeLast()
        return .changed
      case 0x00..<0x20:
        return .none
      default:
        bytes.append(byte)
        started = true
        return .changed
      }
    }
  }
}
