import ArnesKit
import XCTest

@testable import arnes

/// The bracketed-paste pieces: `PasteStore` (collapse rules, placeholders, expansion) and
/// `PasteCapture` (the byte-level end-marker scan), plus a paste landing in a `LineCapture`
/// answer. The watcher and reader themselves need a TTY; everything decision-shaped lives here.
final class PasteTests: XCTestCase {

  // MARK: PasteStore rules

  func testNormalizeFoldsCarriageReturns() {
    XCTAssertEqual(PasteStore.normalize("a\r\nb\rc\n"), "a\nb\nc\n")
  }

  func testShouldCollapseMultiLineAndOversizedOnly() {
    XCTAssertTrue(PasteStore.shouldCollapse("a\nb"))
    XCTAssertTrue(PasteStore.shouldCollapse("a\nb\n"))
    XCTAssertFalse(PasteStore.shouldCollapse("hello"))
    XCTAssertFalse(PasteStore.shouldCollapse("hello\n"), "one trailing newline is still one line")
    XCTAssertFalse(PasteStore.shouldCollapse(String(repeating: "x", count: PasteStore.inlineMaxChars)))
    XCTAssertTrue(PasteStore.shouldCollapse(String(repeating: "x", count: PasteStore.inlineMaxChars + 1)))
  }

  func testInlineTextFlattensForTheSingleLineBox() {
    XCTAssertEqual(PasteStore.inlineText("a\tb"), "a b")
    XCTAssertEqual(PasteStore.inlineText("a\nb\n"), "a b", "the trailing newline goes, inner ones become spaces")
    XCTAssertEqual(PasteStore.inlineText("café ✓"), "café ✓")
    XCTAssertEqual(PasteStore.inlineText("a\u{07}b"), "ab", "other control characters are dropped")
  }

  func testLineCountForgivesOneTrailingNewline() {
    XCTAssertEqual(PasteStore.lineCount(of: "a"), 1)
    XCTAssertEqual(PasteStore.lineCount(of: "a\n"), 1)
    XCTAssertEqual(PasteStore.lineCount(of: "a\nb\nc"), 3)
    XCTAssertEqual(PasteStore.lineCount(of: "a\nb\nc\n"), 3)
  }

  // MARK: PasteStore placeholders

  func testStoreNamesLinesForMultiLineAndCharsForOversized() {
    let store = PasteStore()
    XCTAssertEqual(store.store("a\nb\nc"), "[Pasted text #1 +3 lines]")
    let long = String(repeating: "x", count: 900)
    XCTAssertEqual(store.store(long), "[Pasted text #2 900 chars]")
  }

  func testExpandReplacesEveryKnownPlaceholder() {
    let store = PasteStore()
    let first = store.store("one\ntwo")
    let second = store.store("three\nfour")
    XCTAssertEqual(
      store.expand("compare \(first) with \(second) please"),
      "compare one\ntwo with three\nfour please")
    XCTAssertEqual(store.expand("no placeholders here"), "no placeholders here")
    XCTAssertEqual(
      store.expand("[Pasted text #9 +9 lines]"), "[Pasted text #9 +9 lines]",
      "an unknown or edited placeholder goes as it reads")
  }

  // MARK: Image-path pastes

  func testImagePathAcceptsTheDragDropShapes() {
    XCTAssertEqual(PasteStore.imagePath(from: "/Users/me/Desktop/shot.png"), "/Users/me/Desktop/shot.png")
    XCTAssertEqual(
      PasteStore.imagePath(from: "/Users/me/Desktop/shot.png \n"), "/Users/me/Desktop/shot.png",
      "drag-drop leaves a trailing space or newline")
    XCTAssertEqual(
      PasteStore.imagePath(from: "'/Users/me/My Photos/shot 1.jpeg'"), "/Users/me/My Photos/shot 1.jpeg")
    XCTAssertEqual(
      PasteStore.imagePath(from: "/Users/me/My\\ Photos/shot\\ 1.png"), "/Users/me/My Photos/shot 1.png")
    XCTAssertEqual(PasteStore.imagePath(from: "file:///Users/me/a%20b.webp"), "/Users/me/a b.webp")
    XCTAssertEqual(PasteStore.imagePath(from: "\"/tmp/x.HEIC\""), "/tmp/x.HEIC")
    XCTAssertEqual(PasteStore.imagePath(from: "~/shot.png"), NSHomeDirectory() + "/shot.png")
  }

  func testImagePathRejectsWhatIsNotOne() {
    XCTAssertNil(PasteStore.imagePath(from: "see /docs/img.png for details"), "prose around a path")
    XCTAssertNil(PasteStore.imagePath(from: "/docs/img.png for details"), "a path followed by prose")
    XCTAssertNil(PasteStore.imagePath(from: "/notes/todo.txt"), "not an image extension")
    XCTAssertNil(PasteStore.imagePath(from: "/a.png\n/b.png"), "several lines")
    XCTAssertNil(PasteStore.imagePath(from: "relative/shot.png"), "not absolute")
    XCTAssertNil(PasteStore.imagePath(from: "/Users/me/shot.png.zip"))
  }

  func testStoreImagePlaceholderAndExpansion() {
    let store = PasteStore()
    let stored = store.storeImage("/Users/me/My Photos/shot 1.png")
    XCTAssertEqual(stored.placeholder, "[Image #1 shot 1.png]")
    XCTAssertNil(stored.note, "a stable path needs no copy and no warning")
    XCTAssertEqual(
      store.expand("what is in \(stored.placeholder)?"),
      "what is in /Users/me/My Photos/shot 1.png?")
    XCTAssertEqual(
      store.storeImage("/tmp/b.png").placeholder, "[Image #2 b.png]",
      "images count apart from text pastes")
  }

  func testStoreImageClipsALongName() {
    let store = PasteStore()
    let placeholder = store.storeImage("/Users/me/" + String(repeating: "a", count: 60) + ".png").placeholder
    XCTAssertTrue(placeholder.hasPrefix("[Image #1 …"), placeholder)
    XCTAssertLessThan(placeholder.count, 60)
  }

  // MARK: The screenshot-thumbnail stash

  func testIsEphemeralNamesTheDragStagingShapes() {
    XCTAssertTrue(PasteStore.isEphemeral(
      "/var/folders/kk/x/T/TemporaryItems/NSIRD_screencaptureui_f/Shot.png"))
    XCTAssertTrue(PasteStore.isEphemeral("/tmp/NSIRD_promise_a/x.png"))
    XCTAssertFalse(PasteStore.isEphemeral("/Users/me/Desktop/Shot.png"))
    XCTAssertFalse(PasteStore.isEphemeral("/Users/me/TemporaryItemsArchive/x.png"))
  }

  func testEphemeralDragIsCopiedOutAtPasteTime() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("paste-tests-\(UUID().uuidString)")
    let staging = base.appendingPathComponent("TemporaryItems/NSIRD_screencaptureui_abc")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let original = staging.appendingPathComponent("shot 1.png").path
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    try bytes.write(to: URL(fileURLWithPath: original))
    defer { try? FileManager.default.removeItem(at: base) }

    let store = PasteStore()
    defer { store.cleanup() }
    let stored = store.storeImage(original)
    XCTAssertEqual(stored.placeholder, "[Image #1 shot 1.png]")
    XCTAssertNil(stored.note)
    let expanded = store.expand(stored.placeholder)
    XCTAssertNotEqual(expanded, original, "the placeholder must expand to the stable copy")
    // The thumbnail dismissing (the original deleted) must not matter any more.
    try FileManager.default.removeItem(atPath: original)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expanded)), bytes)
  }

  func testEphemeralDragThatCannotBeCopiedKeepsThePathAndSaysWhy() {
    let store = PasteStore()
    let gone = "/private/var/folders/xx/T/TemporaryItems/NSIRD_screencaptureui_zz/gone.png"
    let stored = store.storeImage(gone)
    XCTAssertNotNil(stored.note, "the user hears at paste time, not from a failed tool call later")
    XCTAssertEqual(store.expand(stored.placeholder), gone)
  }

  func testNeedsStashCoversEphemeralAndUntypeablePaths() {
    XCTAssertTrue(PasteStore.needsStash("/T/TemporaryItems/NSIRD_x/Shot.png"), "ephemeral staging")
    // macOS screenshot names carry U+202F (narrow no-break space) before "PM" — the model
    // reads it as a plain space and retypes a path that doesn't exist.
    XCTAssertTrue(PasteStore.needsStash("/Users/me/Desktop/Screenshot at 5.33.02\u{202F}PM.png"))
    XCTAssertTrue(PasteStore.needsStash("/Users/me/фото.png"), "non-ASCII anywhere")
    XCTAssertFalse(PasteStore.needsStash("/Users/me/My Photos/shot 1.png"), "plain ASCII is retypeable")
  }

  func testSafeStashNameIsModelRetypeable() {
    XCTAssertEqual(
      PasteStore.safeStashName("Screenshot 2026-09-01 at 5.33.02\u{202F}PM.png"),
      "Screenshot-2026-09-01-at-5.33.02-PM.png")
    XCTAssertEqual(PasteStore.safeStashName("a  b.png"), "a-b.png", "runs collapse")
    XCTAssertEqual(PasteStore.safeStashName("  x.png"), "x.png", "leading junk trimmed")
    XCTAssertEqual(PasteStore.safeStashName("plain_shot-1.png"), "plain_shot-1.png", "safe names untouched")
    XCTAssertEqual(PasteStore.safeStashName("📸🎉"), "image", "never an empty filename")
  }

  func testUntypeableDesktopNameIsStashedUnderARetypeableOne() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("paste-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    let original = base.appendingPathComponent("Screenshot at 5.33.02\u{202F}PM.png").path
    let bytes = Data([0x89, 0x50, 0x4E, 0x47])
    try bytes.write(to: URL(fileURLWithPath: original))
    defer { try? FileManager.default.removeItem(at: base) }

    let store = PasteStore()
    defer { store.cleanup() }
    let stored = store.storeImage(original)
    XCTAssertNil(stored.note)
    let expanded = store.expand(stored.placeholder)
    XCTAssertNotEqual(expanded, original, "an untypeable name must expand to the stash copy")
    XCTAssertTrue(expanded.hasPrefix(store.stashDirectory.path + "/"), "the copy lives in the stash")
    XCTAssertTrue(
      expanded.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 0x20 },
      "the copy's path is retypeable exactly: \(expanded)")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: expanded)), bytes)
  }

  func testStashDirectoryIsAFreeReadAndAGatedWrite() throws {
    let store = PasteStore()
    defer { store.cleanup() }
    // The stash rides the rules as a read-only carve-out — the drag was the consent.
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("paste-rules-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let rules = PathScope.Rules(pasteStash: store.stashDirectory)
    let stashed = store.stashDirectory.appendingPathComponent("1-shot.png").path
    XCTAssertEqual(PathScope.classify(stashed, root: root, rules: rules), .inside, "reads are free")
    XCTAssertEqual(
      PathScope.classify(forWriting: stashed, root: root, rules: rules), .outside,
      "writes there stay gated — the carve-out opens reads only")
    XCTAssertEqual(
      PathScope.classify(stashed, root: root, rules: .default), .outside,
      "no carve-out configured → gated as before")

    // A symlink planted inside the stash resolves out and is judged where it points.
    try FileManager.default.createDirectory(at: store.stashDirectory, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("secret.txt")
    try Data([1]).write(to: outside)
    let link = store.stashDirectory.appendingPathComponent("2-link.png")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    XCTAssertEqual(
      PathScope.classify(link.path, root: URL(fileURLWithPath: "/nonexistent-root"), rules: rules),
      .outside, "a planted symlink never rides the carve-out")
  }

  func testCleanupRemovesTheStash() throws {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("paste-tests-\(UUID().uuidString)")
    let staging = base.appendingPathComponent("TemporaryItems/NSIRD_x")
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    let original = staging.appendingPathComponent("a.png").path
    try Data([1]).write(to: URL(fileURLWithPath: original))
    defer { try? FileManager.default.removeItem(at: base) }

    let store = PasteStore()
    let copy = store.expand(store.storeImage(original).placeholder)
    XCTAssertTrue(FileManager.default.fileExists(atPath: copy))
    store.cleanup()
    XCTAssertFalse(FileManager.default.fileExists(atPath: copy))
  }

  // MARK: The unbracketed fallback (Interactive.isPastedPath)

  func testIsPastedPathJudgesByTheDisk() {
    let exists: (String) -> Bool = { $0 == "/tmp/shot 1.png" || $0 == "/tmp/dir" }
    XCTAssertTrue(Interactive.isPastedPath("/tmp/shot\\ 1.png", exists: exists))
    XCTAssertTrue(
      Interactive.isPastedPath("/tmp/dir what is this?", exists: exists),
      "the first token naming a real file makes the line a message")
    XCTAssertFalse(Interactive.isPastedPath("/hepl", exists: exists), "a typo'd command still gets help")
    XCTAssertFalse(Interactive.isPastedPath("not a path", exists: exists))
  }

  // MARK: PasteCapture

  private func feed(_ capture: inout PasteCapture, _ bytes: [UInt8]) -> String? {
    for byte in bytes {
      if case .finished(let text) = capture.feed(byte) { return text }
    }
    return nil
  }

  func testCaptureEndsAtTheMarkerAndReturnsTheContent() {
    var capture = PasteCapture()
    let finished = feed(&capture, Array("line one\nline two".utf8) + PasteCapture.endMarker)
    XCTAssertEqual(finished, "line one\nline two")
  }

  func testCaptureFlushesAFalseStartIntoTheContent() {
    var capture = PasteCapture()
    // ESC [ 2 0 1 X is content, not the marker — every held byte must survive.
    let bytes = [0x1B, UInt8(ascii: "["), UInt8(ascii: "2"), UInt8(ascii: "0"), UInt8(ascii: "1"), UInt8(ascii: "X")]
    let finished = feed(&capture, bytes + Array("done".utf8) + PasteCapture.endMarker)
    XCTAssertEqual(finished, "\u{1B}[201Xdone")
  }

  func testCaptureReopensTheMarkerAfterAFalseStart() {
    var capture = PasteCapture()
    // ESC ESC [ 2 0 1 ~ — the first ESC is content, the second opens the real marker.
    let finished = feed(&capture, [0x1B] + PasteCapture.endMarker)
    XCTAssertEqual(finished, "\u{1B}")
  }

  // MARK: LineCapture (an ask_user answer)

  func testPasteIntoAnAnswerNeverSubmitsAndFlattensNewlines() {
    var capture = KeyWatcher.LineCapture()
    let start: [UInt8] = [0x1B, UInt8(ascii: "["), UInt8(ascii: "2"), UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "~")]
    var events: [KeyWatcher.LineCapture.Event] = []
    for byte in start + Array("pick\nthe blue one\n".utf8) + PasteCapture.endMarker {
      events.append(capture.feed(byte))
    }
    XCTAssertFalse(
      events.contains(where: { if case .line = $0 { return true } else { return false } }),
      "a newline inside a paste must not complete the answer")
    XCTAssertEqual(events.last, .changed)
    XCTAssertEqual(capture.text, "pick the blue one")
    XCTAssertEqual(capture.feed(0x0A), .line("pick the blue one"))
  }

  func testPasteMarkersAreInvisibleToAnEmptyAnswer() {
    var capture = KeyWatcher.LineCapture()
    let start: [UInt8] = [0x1B, UInt8(ascii: "["), UInt8(ascii: "2"), UInt8(ascii: "0"), UInt8(ascii: "0"), UInt8(ascii: "~")]
    for byte in start + PasteCapture.endMarker {
      XCTAssertNotEqual(capture.feed(byte), .changed, "an empty paste changes nothing")
    }
    XCTAssertTrue(capture.isEmpty)
    XCTAssertFalse(capture.isPasting)
  }
}
