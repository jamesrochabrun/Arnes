import Foundation

// MARK: - PasteStore

/// Collapses a bracketed paste into a compact placeholder — `[Pasted text #1 +58 lines]` —
/// so a multi-line paste rides the single-line input box as one token instead of submitting
/// one message per line. The full text is kept here and substituted back when the line
/// becomes a turn (`expand`, called by the REPL right before the text is sent). The store
/// lives for the process: a placeholder recalled from history in a later run is dead text,
/// sent exactly as it reads — the same trade Claude Code makes.
final class PasteStore: @unchecked Sendable {
  private let lock = NSLock()
  private var contents: [String: String] = [:] // placeholder → full text
  private var counter = 0
  private var imageCounter = 0

  /// A single-line paste longer than this is collapsed too — it would not fit the box.
  static let inlineMaxChars = 800

  /// What a dragged/pasted image file's path may end with. Broader than `view_image`'s
  /// sniff on purpose — the placeholder is about not misreading the paste, not about
  /// whether the model can open it.
  static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "bmp", "tif", "tiff",
  ]

  /// Bracketed paste hands newlines through as the source sent them; terminals commonly
  /// deliver CR where the clipboard had LF. One vocabulary before anything is counted.
  static func normalize(_ raw: String) -> String {
    raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  }

  /// Whether a normalized paste is collapsed behind a placeholder: anything multi-line
  /// (one trailing newline forgiven — `foo\n` is still one line), or a single line too
  /// long for the input box.
  static func shouldCollapse(_ text: String) -> Bool {
    var body = text
    if body.hasSuffix("\n") { body.removeLast() }
    return body.contains("\n") || body.count > inlineMaxChars
  }

  /// A paste inserted literally: it lands in a single-line editor, so newlines and tabs
  /// become spaces and other control characters are dropped. One trailing newline is
  /// forgiven entirely — bracketed paste never auto-submits, so it must not linger as a
  /// stray space either.
  static func inlineText(_ text: String) -> String {
    var text = text
    if text.hasSuffix("\n") { text.removeLast() }
    return String(text.map { character -> Character in
      if character == "\n" || character == "\t" { return " " }
      return character
    }.filter { character in
      guard let scalar = character.unicodeScalars.first, character.unicodeScalars.count == 1 else { return true }
      return scalar.value >= 0x20 && scalar.value != 0x7F
    })
  }

  /// How many lines a paste spans, a lone trailing newline not counted as an extra line.
  static func lineCount(of text: String) -> Int {
    var body = text
    if body.hasSuffix("\n") { body.removeLast() }
    guard !body.isEmpty else { return 1 }
    return body.components(separatedBy: "\n").count
  }

  /// The cleaned image-file path when the paste *is* one — what dragging an image into the
  /// terminal produces: a single absolute path, often quoted or with backslash-escaped
  /// spaces, sometimes a `file://` URL, usually with a trailing space or newline. Returns
  /// nil for anything else (several lines, prose around the path, a non-image extension),
  /// so an ordinary paste is never mistaken for an image. The path's shape is judged, not
  /// the disk — a placeholder for a path that turns out not to exist still expands to it.
  static func imagePath(from text: String) -> String? {
    var candidate = normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !candidate.isEmpty, !candidate.contains("\n") else { return nil }
    // One pair of matching quotes (Finder's "Copy as Pathname" quotes paths with spaces).
    for quote in ["\"", "'"] where candidate.hasPrefix(quote) && candidate.hasSuffix(quote) && candidate.count > 1 {
      candidate = String(candidate.dropFirst().dropLast())
    }
    if candidate.lowercased().hasPrefix("file://") {
      candidate = String(candidate.dropFirst("file://".count))
      candidate = candidate.removingPercentEncoding ?? candidate
    }
    // Shell escaping (`My\ Photos`) → the literal path; a lone trailing backslash stays.
    var unescaped = ""
    var index = candidate.startIndex
    while index < candidate.endIndex {
      let character = candidate[index]
      if character == "\\", candidate.index(after: index) < candidate.endIndex {
        index = candidate.index(after: index)
        unescaped.append(candidate[index])
      } else {
        unescaped.append(character)
      }
      index = candidate.index(after: index)
    }
    if unescaped.hasPrefix("~") {
      unescaped = NSString(string: unescaped).expandingTildeInPath
    }
    guard unescaped.hasPrefix("/") else { return nil }
    let ext = (unescaped as NSString).pathExtension.lowercased()
    guard imageExtensions.contains(ext) else { return nil }
    return unescaped
  }

  /// Whether a path is a drag's *staging* location — macOS's floating screenshot thumbnail
  /// (and other file promises) land under `…/TemporaryItems/NSIRD_<app>_<id>/`, readable
  /// only while the drag's access grant lives and deleted when the thumbnail dismisses.
  /// A path here must be copied at paste time or it will be gone (or refused) by the time
  /// the model reads it.
  static func isEphemeral(_ path: String) -> Bool {
    (path as NSString).pathComponents.contains { $0 == "TemporaryItems" || $0.hasPrefix("NSIRD_") }
  }

  /// A stashed copy larger than this stays where it was — `view_image` caps at 5 MB anyway.
  static let maxStashBytes = 20_000_000

  /// Whether a dragged path must be copied into the stash: an ephemeral staging location
  /// (gone when the thumbnail dismisses), or a path with characters the model cannot retype
  /// into a tool call — macOS screenshot names carry a narrow no-break space (U+202F) before
  /// "AM/PM" that reads as a plain space in the turn text, so the model's `view_image` path
  /// comes back subtly different and ENOENTs. Plain ASCII (spaces included) is retypeable.
  static func needsStash(_ path: String) -> Bool {
    if isEphemeral(path) { return true }
    return path.unicodeScalars.contains { !$0.isASCII || $0.value < 0x20 }
  }

  /// A stash copy's filename: the original basename reduced to characters a model can retype
  /// exactly from the turn text — ASCII letters, digits, `.`, `_`, `-`; anything else
  /// (spaces, U+202F, emoji) becomes one `-`, runs collapsed, leading dashes trimmed.
  static func safeStashName(_ basename: String) -> String {
    var out = ""
    var pendingDash = false
    for character in basename {
      let scalar = character.unicodeScalars.first
      let safe = character.unicodeScalars.count == 1 && scalar?.isASCII == true
        && (character.isLetter || character.isNumber || character == "." || character == "_"
          || character == "-")
      if safe {
        if pendingDash, !out.isEmpty { out.append("-") }
        pendingDash = false
        out.append(character)
      } else {
        pendingDash = true
      }
    }
    return out.isEmpty ? "image" : out
  }

  /// Registers a pasted image path and returns its placeholder — `[Image #1 shot.png]`.
  /// `expand` puts the clean path back into the turn, where the model can `view_image` it;
  /// collapsing also keeps a path that starts with `/` from reading as a slash command.
  /// A path that `needsStash` (an ephemeral screenshot-thumbnail drag, or a name the model
  /// couldn't retype) is copied into the stash *now* — while a drag's OS access grant is
  /// still fresh — under a `safeStashName`, and the placeholder expands to the copy; when
  /// the copy fails, the original path is kept and `note` says what will probably go wrong.
  func storeImage(_ path: String) -> (placeholder: String, note: String?) {
    lock.lock()
    defer { lock.unlock() }
    imageCounter += 1
    var name = (path as NSString).lastPathComponent
    if name.count > 40 { name = "…" + name.suffix(39) }
    let placeholder = "[Image #\(imageCounter) \(name)]"
    var stored = path
    var note: String?
    if Self.needsStash(path) {
      if let copy = stash(path, index: imageCounter) {
        stored = copy
      } else if Self.isEphemeral(path) {
        note = "⚠ could not copy \((path as NSString).lastPathComponent) out of the screenshot "
          + "preview's folder — macOS keeps it private to the terminal. Save the screenshot first "
          + "(click the floating thumbnail, or wait for it to land on the Desktop) and drag that file in."
      } else {
        note = "⚠ could not copy \((path as NSString).lastPathComponent) into the session's stash — "
          + "its name has characters the model may not retype exactly; if reading it fails, "
          + "rename the file and drag it in again."
      }
    }
    contents[placeholder] = stored
    return (placeholder, note)
  }

  /// Where stashed drag copies live for this process — the path is fixed at init (so the
  /// REPL can carve it out of the read gate before any drag happens); the directory itself
  /// is created 0700 on first use.
  let stashDirectory: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("arnes-pastes-\(UUID().uuidString.prefix(8))", isDirectory: true)
  private var stashCreated = false

  /// Copies a dragged file into the stash under a model-retypeable name. Caller holds the
  /// lock. nil when the source can't be read (an ephemeral drag's OS grant already gone),
  /// is over `maxStashBytes`, or the copy fails for any other reason.
  private func stash(_ path: String, index: Int) -> String? {
    let manager = FileManager.default
    guard
      let size = try? manager.attributesOfItem(atPath: path)[.size] as? Int,
      size <= Self.maxStashBytes
    else { return nil }
    if !stashCreated {
      do {
        try manager.createDirectory(
          at: stashDirectory, withIntermediateDirectories: true,
          attributes: [.posixPermissions: 0o700])
      } catch { return nil }
      stashCreated = true
    }
    let destination = stashDirectory
      .appendingPathComponent("\(index)-\(Self.safeStashName((path as NSString).lastPathComponent))")
    do {
      try manager.copyItem(atPath: path, toPath: destination.path)
      try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
      return destination.path
    } catch { return nil }
  }

  /// Removes the stash directory — the REPL's exit path calls it so dragged screenshots
  /// don't accumulate under the OS temp directory.
  func cleanup() {
    lock.lock()
    defer { lock.unlock() }
    guard stashCreated else { return }
    try? FileManager.default.removeItem(at: stashDirectory)
    stashCreated = false
  }

  /// Registers a paste and returns the placeholder that stands in for it.
  func store(_ text: String) -> String {
    lock.lock()
    defer { lock.unlock() }
    counter += 1
    let lines = Self.lineCount(of: text)
    let placeholder = lines > 1
      ? "[Pasted text #\(counter) +\(lines) lines]"
      : "[Pasted text #\(counter) \(text.count) chars]"
    contents[placeholder] = text
    return placeholder
  }

  /// The line with every known placeholder replaced by its full text — what actually goes
  /// to the model. A placeholder the user edited no longer matches and goes as it reads.
  func expand(_ line: String) -> String {
    guard line.contains("[Pasted text #") || line.contains("[Image #") else { return line }
    lock.lock()
    defer { lock.unlock() }
    var expanded = line
    for (placeholder, text) in contents where expanded.contains(placeholder) {
      expanded = expanded.replacingOccurrences(of: placeholder, with: text)
    }
    return expanded
  }
}

// MARK: - PasteCapture

/// Collects a bracketed paste's bytes until the end marker (`ESC [ 2 0 1 ~`), fed one byte
/// at a time, tolerating the marker split across reads. Bytes that begin a potential marker
/// are held back; a mismatch flushes them into the content — so pasted text may itself
/// contain escape bytes without ending the capture early.
struct PasteCapture: Equatable {
  /// What a terminal sends before pasted content once `ESC[?2004h` enabled bracketed paste;
  /// the CSI params a sequence parser sees for it.
  static let startParams: [UInt8] = Array("200".utf8)
  static let endMarker: [UInt8] = [
    0x1B, UInt8(ascii: "["), UInt8(ascii: "2"), UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "~"),
  ]

  private var content: [UInt8] = []
  private var held: [UInt8] = [] // the end marker's prefix seen so far

  enum Event: Equatable {
    /// The byte was consumed; the paste continues.
    case none
    /// The end marker completed: the paste's raw text (the marker excluded).
    case finished(String)
  }

  mutating func feed(_ byte: UInt8) -> Event {
    if byte == Self.endMarker[held.count] {
      held.append(byte)
      if held.count == Self.endMarker.count {
        return .finished(String(decoding: content, as: UTF8.self))
      }
      return .none
    }
    if !held.isEmpty {
      // What was held is content after all — and this byte may itself reopen the marker
      // (an ESC directly after a false start).
      content.append(contentsOf: held)
      held = []
      if byte == Self.endMarker[0] {
        held = [byte]
        return .none
      }
    }
    content.append(byte)
    return .none
  }
}
