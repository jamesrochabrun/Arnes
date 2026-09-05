import ArnesKit
import XCTest
@testable import arnes

/// The permission prompt's option panel and change preview (the pure pieces
/// `TerminalPermissions` drives): which options a request offers, what each key does —
/// most importantly that an unrecognized key changes *nothing*, where the old single-key
/// prompt read it as a denial — and the diff snippet the file-writing tools show.
final class PermissionPanelTests: XCTestCase {
  private func request(
    tool: String = "bash",
    summary: String = "bash: git commit -m x",
    arguments: String = #"{"command": "git commit -m x"}"#,
    tier: ToolPermission = .mutating,
    tainted: Bool = false,
    grantScope: String? = nil) -> PermissionRequest
  {
    PermissionRequest(
      toolName: tool, summary: summary, argumentsJSON: arguments, tier: tier,
      tainted: tainted, grantScope: grantScope)
  }

  // MARK: Options

  func testOrdinaryBashOffersAlwaysNamingTheGrantPattern() {
    let options = PermissionPanel.options(for: request(), root: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(options.map(\.decision), [.allow, .allowAlways, .deny])
    XCTAssertTrue(options[1].label.contains("git commit"), options[1].label)
    XCTAssertTrue(options[1].label.contains("this session"))
  }

  func testSensitiveCallHasNoAlwaysRow() {
    // "Always" never covers `.sensitive` — the session records no grant — so the row
    // would be a lie; the shortcut `a` then picks nothing.
    let options = PermissionPanel.options(
      for: request(arguments: #"{"command": "git push"}"#, tier: .sensitive))
    XCTAssertEqual(options.map(\.decision), [.allow, .deny])
  }

  func testTaintedCallHasNoAlwaysRow() {
    let options = PermissionPanel.options(for: request(tainted: true))
    XCTAssertEqual(options.map(\.decision), [.allow, .deny])
  }

  func testGrantScopeNamesTheDirectoryEvenOnASensitiveRead() {
    let options = PermissionPanel.options(
      for: request(
        tool: "read_file", arguments: #"{"path": "/Users/x/other/a.txt"}"#,
        tier: .sensitive, grantScope: "/Users/x/other"))
    XCTAssertEqual(options.map(\.decision), [.allow, .allowAlways, .deny])
    XCTAssertTrue(options[1].label.contains("/Users/x/other"), options[1].label)
  }

  func testBashWithNothingGrantableHasNoAlwaysRow() {
    // An interpreter earns no grant pattern; offering "always" would remember nothing.
    let options = PermissionPanel.options(
      for: request(arguments: #"{"command": "python3 run.py"}"#))
    XCTAssertEqual(options.map(\.decision), [.allow, .deny])
  }

  func testFileToolAlwaysNamesTheTool() {
    let label = PermissionPanel.alwaysLabel(
      for: request(tool: "edit_file", arguments: #"{"path": "a.txt"}"#))
    XCTAssertEqual(label, "Yes, always allow edit_file this session")
  }

  func testInitialSelectionDefendsSensitiveCalls() {
    let ordinary = request()
    XCTAssertEqual(
      PermissionPanel.initialSelection(
        for: ordinary, options: PermissionPanel.options(for: ordinary)), 0)
    let sensitive = request(arguments: #"{"command": "git push"}"#, tier: .sensitive)
    let options = PermissionPanel.options(for: sensitive)
    XCTAssertEqual(
      PermissionPanel.initialSelection(for: sensitive, options: options),
      options.count - 1, "a reflexive Enter must not approve an irreversible call")
  }

  // MARK: Keys

  func testArrowsEnterDigitsAndShortcuts() {
    XCTAssertEqual(PermissionPanel.action(for: "\u{1B}[A"), .move(-1))
    XCTAssertEqual(PermissionPanel.action(for: "\u{1B}OA"), .move(-1))
    XCTAssertEqual(PermissionPanel.action(for: "\u{1B}[B"), .move(1))
    XCTAssertEqual(PermissionPanel.action(for: "\r"), .choose)
    XCTAssertEqual(PermissionPanel.action(for: "\n"), .choose)
    XCTAssertEqual(PermissionPanel.action(for: "y"), .pick(.allow))
    XCTAssertEqual(PermissionPanel.action(for: "A"), .pick(.allowAlways))
    XCTAssertEqual(PermissionPanel.action(for: "n"), .pick(.deny))
    XCTAssertEqual(PermissionPanel.action(for: "2"), .select(1))
    XCTAssertEqual(PermissionPanel.action(for: "\u{1B}"), .cancel)
    XCTAssertEqual(PermissionPanel.action(for: "\u{03}"), .cancel)
    XCTAssertEqual(PermissionPanel.action(for: "\u{0F}"), .expand)
  }

  func testUnrecognizedKeysAreIgnoredNotDenials() {
    // The reported bug: tapping any key answered the prompt as a denial.
    for key in ["q", "z", " ", "0", "?", "\t", "\u{1B}[C", "\u{1B}[5~", "é"] {
      XCTAssertEqual(PermissionPanel.action(for: key), .ignore, "key \(key.debugDescription)")
    }
  }

  // MARK: Rows

  func testLinesMarkTheSelectionAndScopeTheHint() {
    let options = PermissionPanel.options(for: request(), root: URL(fileURLWithPath: "/tmp"))
    let rows = PermissionPanel.lines(
      question: "allow bash?", options: options, selected: 1, showsDiffHint: false)
    XCTAssertEqual(rows.count, options.count + 1)
    XCTAssertTrue(rows[0].contains("allow bash?"))
    XCTAssertTrue(rows[0].contains("y/n/a"))
    XCTAssertFalse(rows[0].contains("ctrl-o"))
    XCTAssertTrue(rows[2].contains("❯"), "the selected row carries the marker")
    XCTAssertFalse(rows[1].contains("❯"))

    let sensitive = PermissionPanel.options(
      for: request(arguments: #"{"command": "git push"}"#, tier: .sensitive))
    let hint = PermissionPanel.lines(
      question: "allow bash?", options: sensitive, selected: 0, showsDiffHint: true)[0]
    XCTAssertTrue(hint.contains("y/n"))
    XCTAssertFalse(hint.contains("y/n/a"), "no always row, no a in the hint")
    XCTAssertTrue(hint.contains("ctrl-o"))
  }

  func testDeferredLinesSayToPauseTyping() {
    let options = PermissionPanel.options(for: request())
    let rows = PermissionPanel.lines(
      question: "allow bash?", options: options, selected: 0, showsDiffHint: false,
      deferred: true)
    XCTAssertTrue(rows[0].contains("pause typing"))
  }

  func testPatternName() {
    XCTAssertEqual(PermissionPanel.patternName("Bash(git commit *)"), "git commit")
    XCTAssertEqual(PermissionPanel.patternName("Bash(swift *)"), "swift")
    XCTAssertEqual(PermissionPanel.patternName("edit_file"), "edit_file")
  }

  // MARK: EditPreview

  func testEditPreviewBuildsAColoredSnippetWithoutFileHeaders() throws {
    let arguments = """
      {"path": "src/a.swift", "old_string": "let x = 1\\nlet y = 2", \
      "new_string": "let x = 1\\nlet y = 3"}
      """
    let preview = try XCTUnwrap(EditPreview.make(toolName: "edit_file", argumentsJSON: arguments))
    let text = preview.snippet.joined(separator: "\n")
    XCTAssertTrue(text.contains("-let y = 2"), text)
    XCTAssertTrue(text.contains("+let y = 3"), text)
    XCTAssertFalse(text.contains("--- a/"), "file headers dropped — the prompt header names the file")
    XCTAssertFalse(text.contains("@@"), "edit_file hunk numbers would be snippet-relative")
  }

  func testEditPreviewSnippetClipsAndNamesCtrlO() throws {
    let old = (1...30).map { "line \($0)" }.joined(separator: "\n")
    let new = (1...30).map { "line \($0) changed" }.joined(separator: "\n")
    let arguments = try encodeArguments(["path": "a.txt", "old_string": old, "new_string": new])
    let preview = try XCTUnwrap(EditPreview.make(toolName: "edit_file", argumentsJSON: arguments))
    XCTAssertEqual(preview.snippet.count, EditPreview.snippetLines + 1)
    XCTAssertTrue(preview.snippet.last!.contains("ctrl-o"), preview.snippet.last!)
    XCTAssertGreaterThan(preview.full.count, preview.snippet.count)
  }

  func testWritePreviewDiffsAgainstTheExistingFile() throws {
    let arguments = try encodeArguments(["path": "a.txt", "content": "one\ntwo changed\nthree\n"])
    let preview = try XCTUnwrap(EditPreview.make(
      toolName: "write_file", argumentsJSON: arguments,
      readExisting: { _ in "one\ntwo\nthree\n" }))
    let text = preview.bodyLines.joined(separator: "\n")
    XCTAssertTrue(text.contains("-two"), text)
    XCTAssertTrue(text.contains("+two changed"), text)
    XCTAssertTrue(text.contains("@@"), "write_file hunk numbers are real file lines")
    XCTAssertFalse(text.contains("+one"), "unchanged lines are context, not additions")
  }

  func testWritePreviewOfANewFileIsAllAdded() throws {
    let arguments = try encodeArguments(["path": "new.txt", "content": "alpha\nbeta\n"])
    let preview = try XCTUnwrap(EditPreview.make(
      toolName: "write_file", argumentsJSON: arguments, readExisting: { _ in nil }))
    let text = preview.bodyLines.joined(separator: "\n")
    XCTAssertTrue(text.contains("+alpha"))
    XCTAssertTrue(text.contains("+beta"))
  }

  func testMultiEditPreviewIsOneDiffOverTheDiskCopy() throws {
    let arguments = #"{"path": "a.txt", "edits": [{"old_string": "one", "new_string": "uno"}, {"old_string": "three", "new_string": "tres"}]}"#
    let preview = try XCTUnwrap(EditPreview.make(
      toolName: "edit_file", argumentsJSON: arguments,
      readExisting: { _ in "one\ntwo\nthree\nfour\n" }))
    let text = preview.bodyLines.joined(separator: "\n")
    for expected in ["-one", "+uno", "-three", "+tres"] {
      XCTAssertTrue(text.contains(expected), text)
    }
    XCTAssertTrue(text.contains("@@ -1,4 +1,4 @@"), "one hunk with real file line numbers: \(text)")
    XCTAssertFalse(text.contains("⋮"), text)
    XCTAssertTrue(text.contains(" two"), "unchanged lines are context")
    XCTAssertTrue(preview.absoluteLineNumbers)
  }

  func testMultiEditPreviewFallsBackToPerEditSnippetsWhenTheFileCannotBeRead() throws {
    let arguments = #"{"path": "a.txt", "edits": [{"old_string": "one", "new_string": "uno"}, {"old_string": "three", "new_string": "tres"}]}"#
    let unreadable = try XCTUnwrap(EditPreview.make(
      toolName: "edit_file", argumentsJSON: arguments, readExisting: { _ in nil }))
    let text = unreadable.bodyLines.joined(separator: "\n")
    XCTAssertEqual(unreadable.bodyLines, ["-one", "+uno", "  ⋮", "-three", "+tres"], text)
    XCTAssertFalse(text.contains("@@"), "snippet-relative hunk numbers are dropped")

    // An edit that won't apply to the disk copy takes the same fallback — execute says why.
    let stale = try XCTUnwrap(EditPreview.make(
      toolName: "edit_file", argumentsJSON: arguments, readExisting: { _ in "nothing here\n" }))
    XCTAssertEqual(stale.bodyLines, unreadable.bodyLines)
    XCTAssertFalse(stale.absoluteLineNumbers)

    XCTAssertNil(EditPreview.make(toolName: "edit_file", argumentsJSON: #"{"path": "a.txt", "edits": []}"#))
    XCTAssertNil(EditPreview.make(toolName: "edit_file", argumentsJSON: #"{"path": "a.txt", "edits": "x"}"#))
  }

  func testPreviewIsNilForOtherToolsBadJSONAndNoOpChanges() throws {
    XCTAssertNil(EditPreview.make(toolName: "bash", argumentsJSON: #"{"command": "ls"}"#))
    XCTAssertNil(EditPreview.make(toolName: "edit_file", argumentsJSON: "not json"))
    let noop = try encodeArguments(["path": "a.txt", "old_string": "same", "new_string": "same"])
    XCTAssertNil(EditPreview.make(toolName: "edit_file", argumentsJSON: noop))
  }

  // MARK: Summary block

  func testSummaryBlockReplacesMiniDiffRowsWithTheSnippet() throws {
    let arguments = try encodeArguments(
      ["path": "a.txt", "old_string": "old line", "new_string": "new line"])
    let preview = try XCTUnwrap(EditPreview.make(toolName: "edit_file", argumentsJSON: arguments))
    let summary = "edit_file a.txt (-1 +1 lines)\n  - old line\n  + new line"
    let block = TerminalPermissions.summaryBlock(summary: summary, preview: preview)
    let text = block.joined(separator: "\n")
    XCTAssertTrue(text.contains("edit_file a.txt (-1 +1 lines)"))
    XCTAssertFalse(text.contains("  - old line"), "the Kit's mini rows are replaced, not doubled")
    XCTAssertTrue(text.contains("-old line"), text)
    XCTAssertTrue(text.contains("+new line"), text)
  }

  func testSummaryBlockWithoutAPreviewIsTheOldSingleLine() {
    let block = TerminalPermissions.summaryBlock(summary: "bash: ls", preview: nil)
    XCTAssertEqual(block.count, 1)
    XCTAssertTrue(block[0].contains("⚠ bash: ls"))
  }

  // MARK: Enter deferral (the panel's quiet guard)

  func testEnterIsDeferredOnlyWhenAskedAndOnlyMidTyping() {
    let now = Date(timeIntervalSince1970: 1_000)
    let justTyped = now.addingTimeInterval(-0.2)
    XCTAssertTrue(KeyWatcher.shouldDefer(
      key: "\r", lastTypeaheadAt: justTyped, now: now, quiet: 1.0, deferringEnter: true))
    XCTAssertFalse(KeyWatcher.shouldDefer(
      key: "\r", lastTypeaheadAt: justTyped, now: now, quiet: 1.0),
      "without the panel's flag Enter answers as before")
    XCTAssertFalse(KeyWatcher.shouldDefer(
      key: "\r", lastTypeaheadAt: now.addingTimeInterval(-5), now: now, quiet: 1.0,
      deferringEnter: true), "a pause makes Enter the answer")
    XCTAssertFalse(KeyWatcher.shouldDefer(
      key: "\u{1B}", lastTypeaheadAt: justTyped, now: now, quiet: 1.0, deferringEnter: true),
      "Esc still cancels at once")
  }

  private func encodeArguments(_ arguments: [String: String]) throws -> String {
    String(decoding: try JSONEncoder().encode(arguments), as: UTF8.self)
  }
}
