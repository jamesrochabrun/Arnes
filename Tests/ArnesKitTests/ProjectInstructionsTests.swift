import XCTest
@testable import ArnesKit

final class ProjectInstructionsTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-pi-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  /// A temp directory with a `.git` marker, so the directory chain treats it as a repo root.
  private func tempRepo() throws -> URL {
    let repo = try tempDir()
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    return repo
  }

  @discardableResult
  private func write(_ text: String, to url: URL) throws -> URL {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  // MARK: Precedence

  func testDiscoversRepoAndGlobalInPrecedenceOrder() throws {
    let home = try tempDir()
    try write("GLOBAL RULES", to: home.appendingPathComponent(".arnes/AGENTS.md"))
    let repo = try tempRepo()
    try write("REPO ROOT RULES", to: repo.appendingPathComponent("AGENTS.md"))
    let sub = repo.appendingPathComponent("pkg/app")
    try write("SUBDIR RULES", to: sub.appendingPathComponent("CLAUDE.md"))

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: sub, home: home, includeProject: true))
    XCTAssertTrue(block.contains("GLOBAL RULES"))
    XCTAssertTrue(block.contains("REPO ROOT RULES"))
    XCTAssertTrue(block.contains("SUBDIR RULES"))
    // Order: global → repo root → nearest subdir (specific wins by coming last).
    let g = try XCTUnwrap(block.range(of: "GLOBAL RULES"))
    let r = try XCTUnwrap(block.range(of: "REPO ROOT RULES"))
    let s = try XCTUnwrap(block.range(of: "SUBDIR RULES"))
    XCTAssertTrue(g.lowerBound < r.lowerBound && r.lowerBound < s.lowerBound)
  }

  func testAgentsMdPreferredOverClaudeMd() throws {
    let home = try tempDir()  // no global file
    let repo = try tempRepo()
    try write("FROM AGENTS", to: repo.appendingPathComponent("AGENTS.md"))
    try write("FROM CLAUDE", to: repo.appendingPathComponent("CLAUDE.md"))
    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home, includeProject: true))
    XCTAssertTrue(block.contains("FROM AGENTS"))
    XCTAssertFalse(block.contains("FROM CLAUDE"), "first fallback filename wins per directory")
  }

  func testOverrideBeatsAgentsMd() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("FROM OVERRIDE", to: repo.appendingPathComponent("AGENTS.override.md"))
    try write("FROM AGENTS", to: repo.appendingPathComponent("AGENTS.md"))
    try write("FROM CLAUDE", to: repo.appendingPathComponent("CLAUDE.md"))

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home, includeProject: true))
    XCTAssertTrue(block.contains("FROM OVERRIDE"))
    XCTAssertFalse(block.contains("FROM AGENTS"))
    XCTAssertFalse(block.contains("FROM CLAUDE"))
  }

  func testLocalFileIsAdditive() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("COMMITTED RULES", to: repo.appendingPathComponent("CLAUDE.md"))
    try write("MY OWN RULES", to: repo.appendingPathComponent("CLAUDE.local.md"))
    try write("ALSO MINE", to: repo.appendingPathComponent("AGENTS.local.md"))

    let sources = ProjectInstructions.sources(workdir: repo, home: home)
    XCTAssertEqual(
      sources.map { $0.path.lastPathComponent },
      ["CLAUDE.md", "AGENTS.local.md", "CLAUDE.local.md"],
      "the primary file, then every local file that exists")

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home))
    let committed = try XCTUnwrap(block.range(of: "COMMITTED RULES"))
    let mine = try XCTUnwrap(block.range(of: "MY OWN RULES"))
    XCTAssertTrue(committed.lowerBound < mine.lowerBound, "the local file renders after the primary")
    XCTAssertTrue(block.contains("ALSO MINE"))
  }

  func testProjectFilesSkippedWhenUntrusted() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("REPO RULES", to: repo.appendingPathComponent("AGENTS.md"))
    XCTAssertNil(ProjectInstructions.discover(workdir: repo, home: home, includeProject: false),
                 "untrusted project instructions must not load")
  }

  func testNothingFoundReturnsNil() throws {
    let home = try tempDir()
    let repo = try tempDir()  // no .git, no files
    XCTAssertNil(ProjectInstructions.discover(workdir: repo, home: home, includeProject: true))
  }

  func testTotalCapTruncates() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    let cap = ProjectInstructions.Options.default.maxBytes
    try write(String(repeating: "x", count: cap + 5000), to: repo.appendingPathComponent("AGENTS.md"))
    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home, includeProject: true))
    XCTAssertTrue(block.contains("[truncated]"))
    XCTAssertLessThan(block.utf8.count, cap + 500)
  }

  func testDiscoveredReportsTheBytesTheCapLeftOut() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    let cap = ProjectInstructions.Options.default.maxBytes
    try write(String(repeating: "x", count: cap + 5000), to: repo.appendingPathComponent("AGENTS.md"))
    let cut = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home, includeProject: true))
    XCTAssertEqual(cut.omittedBytes, 5000)
    let notice = try XCTUnwrap(cut.truncationNotice(maxBytes: cap))
    XCTAssertTrue(notice.hasPrefix("instruction files truncated: 4 KB over the 32 KB cap"), notice)
    XCTAssertTrue(notice.contains("instructions.maxBytes"), notice)

    // A second file skipped entirely once the budget is spent counts as omitted too.
    try write(String(repeating: "y", count: 300), to: repo.appendingPathComponent("AGENTS.local.md"))
    let two = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home, includeProject: true))
    XCTAssertEqual(two.omittedBytes, 5300)

    try write("short and sweet", to: repo.appendingPathComponent("AGENTS.md"))
    try FileManager.default.removeItem(at: repo.appendingPathComponent("AGENTS.local.md"))
    let whole = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home, includeProject: true))
    XCTAssertEqual(whole.omittedBytes, 0)
    XCTAssertNil(whole.truncationNotice(maxBytes: cap))
  }

  // MARK: Options

  func testOptionsFromConfigOverrideOnlyWhatTheyName() {
    let partial = ProjectInstructions.Options(config: InstructionsConfig(maxBytes: 100, imports: false))
    XCTAssertEqual(partial.maxBytes, 100)
    XCTAssertFalse(partial.imports)
    XCTAssertEqual(partial.fallbackFilenames, ProjectInstructions.Options.default.fallbackFilenames)
    XCTAssertEqual(partial.rootMarkers, [".git"])
    XCTAssertEqual(ProjectInstructions.Options(config: nil), .default)
  }

  func testConfiguredFilenamesAndRootMarkerAreHonored() throws {
    let home = try tempDir()
    let root = try tempDir()
    try write("marker", to: root.appendingPathComponent("WORKSPACE"))
    try write("HOUSE RULES", to: root.appendingPathComponent("RULES.md"))
    let sub = root.appendingPathComponent("svc")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)

    let options = ProjectInstructions.Options(
      config: InstructionsConfig(fallbackFilenames: ["RULES.md"], rootMarkers: ["WORKSPACE"]))
    let block = try XCTUnwrap(
      ProjectInstructions.discover(workdir: sub, home: home, options: options))
    XCTAssertTrue(block.contains("HOUSE RULES"), "the root marker walked up past svc/")
  }

  // MARK: HTML comments

  func testHtmlCommentsStripped() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("SECRET IMPORT BODY", to: repo.appendingPathComponent("secret.md"))
    try write(
      """
      # Rules
      <!-- internal note: do not ship this line -->
      Visible rule.
      <!--
      @secret.md
      -->
      """,
      to: repo.appendingPathComponent("AGENTS.md"))

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home))
    XCTAssertTrue(block.contains("Visible rule."))
    XCTAssertFalse(block.contains("internal note"))
    XCTAssertFalse(block.contains("SECRET IMPORT BODY"), "a commented-out import must not fire")
    XCTAssertFalse(block.contains("[import skipped"))
  }

  // MARK: Imports

  func testImportRelativeToContainingFile() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("STYLE RULES", to: repo.appendingPathComponent("docs/style.md"))
    try write("TESTING RULES", to: repo.appendingPathComponent("docs/deep/testing.md"))
    // The nested file's own import resolves against *its* directory, not the repo root.
    try write("@deep/testing.md", to: repo.appendingPathComponent("docs/index.md"))
    try write(
      """
      # Rules
      @docs/style.md
      @docs/index.md
      @someone thanks for the note
      """,
      to: repo.appendingPathComponent("AGENTS.md"))

    let found = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home))
    XCTAssertTrue(found.text.contains("STYLE RULES"))
    XCTAssertTrue(found.text.contains("TESTING RULES"))
    XCTAssertTrue(found.text.contains("@someone thanks for the note"),
                  "a non-path @token is prose, not an import")
    XCTAssertEqual(
      found.sources.first?.imports.map { $0.lastPathComponent },
      ["style.md", "index.md", "testing.md"])
  }

  func testImportTilde() throws {
    let home = try tempDir()
    try write("HOME NOTES", to: home.appendingPathComponent("notes/style.md"))
    try write("# Global\n@~/notes/style.md", to: home.appendingPathComponent(".arnes/AGENTS.md"))
    let repo = try tempDir()

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home))
    XCTAssertTrue(block.contains("HOME NOTES"), "a global file may import anywhere under home")
  }

  func testImportInsideFenceIgnored() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("FENCED BODY", to: repo.appendingPathComponent("fenced.md"))
    try write("INLINE BODY", to: repo.appendingPathComponent("inline.md"))
    try write("REAL BODY", to: repo.appendingPathComponent("real.md"))
    try write(
      """
      # Rules
      Example of the syntax:

      ```
      @fenced.md
      ```

      `@inline.md` is prose about an import, not one.
      @real.md
      """,
      to: repo.appendingPathComponent("AGENTS.md"))

    let found = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home))
    XCTAssertTrue(found.text.contains("REAL BODY"))
    XCTAssertFalse(found.text.contains("FENCED BODY"), "a line inside ``` is never an import")
    XCTAssertFalse(found.text.contains("INLINE BODY"), "an inline code span is never an import")
    XCTAssertTrue(found.text.contains("@fenced.md"), "the fenced line survives verbatim")
    XCTAssertTrue(found.text.contains("`@inline.md`"))
    XCTAssertEqual(found.sources.first?.imports.map { $0.lastPathComponent }, ["real.md"])
  }

  func testImportDepthAndCycleGuard() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    // AGENTS.md → l1 → l2 → l3 → l4 → l5: four levels ride along, the fifth is dropped.
    try write("@l1.md", to: repo.appendingPathComponent("AGENTS.md"))
    for level in 1...4 {
      try write("LEVEL \(level)\n@l\(level + 1).md", to: repo.appendingPathComponent("l\(level).md"))
    }
    try write("LEVEL 5", to: repo.appendingPathComponent("l5.md"))

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home))
    for level in 1...4 { XCTAssertTrue(block.contains("LEVEL \(level)"), "level \(level) should load") }
    XCTAssertFalse(block.contains("LEVEL 5"), "deeper than 4 levels is dropped")
    XCTAssertTrue(block.contains("[import skipped: @l5.md — more than 4 levels of imports]"))

    // a → b → a resolves once, with a note where the cycle closed.
    let cyclic = try tempRepo()
    try write("@a.md", to: cyclic.appendingPathComponent("AGENTS.md"))
    try write("BODY A\n@b.md", to: cyclic.appendingPathComponent("a.md"))
    try write("BODY B\n@a.md", to: cyclic.appendingPathComponent("b.md"))

    let expanded = try XCTUnwrap(ProjectInstructions.discover(workdir: cyclic, home: home))
    XCTAssertEqual(expanded.components(separatedBy: "BODY A").count - 1, 1, "a.md inlined exactly once")
    XCTAssertTrue(expanded.contains("BODY B"))
    XCTAssertTrue(expanded.contains("[import skipped: @a.md — already imported]"))
  }

  func testProjectImportOutsideRootSkippedWithNote() throws {
    let home = try tempDir()
    try write("PRIVATE KEY MATERIAL", to: home.appendingPathComponent(".ssh/config"))
    let outside = try tempDir()
    try write("OUTSIDE BODY", to: outside.appendingPathComponent("notes.md"))
    let repo = try tempRepo()
    try write(
      """
      # Rules
      @~/.ssh/config
      @\(outside.appendingPathComponent("notes.md").path)
      """,
      to: repo.appendingPathComponent("AGENTS.md"))

    let found = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home))
    XCTAssertFalse(found.text.contains("PRIVATE KEY MATERIAL"))
    XCTAssertFalse(found.text.contains("OUTSIDE BODY"))
    XCTAssertTrue(found.text.contains("[import skipped: @~/.ssh/config — credential path]"))
    XCTAssertTrue(found.text.contains("— outside the project]"))
    XCTAssertTrue(found.sources.first?.imports.isEmpty ?? false)
  }

  func testProjectMayImportFromArnesHome() throws {
    let home = try tempDir()
    try write("SHARED HOUSE STYLE", to: home.appendingPathComponent(".arnes/style.md"))
    let repo = try tempRepo()
    try write("# Rules\n@~/.arnes/style.md", to: repo.appendingPathComponent("AGENTS.md"))

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home))
    XCTAssertTrue(block.contains("SHARED HOUSE STYLE"))
  }

  func testImportsCountAgainstCap() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    let cap = ProjectInstructions.Options.default.maxBytes
    try write(String(repeating: "y", count: cap + 5000), to: repo.appendingPathComponent("big.md"))
    try write("# Rules\n@big.md", to: repo.appendingPathComponent("AGENTS.md"))

    let block = try XCTUnwrap(ProjectInstructions.discover(workdir: repo, home: home))
    XCTAssertTrue(block.contains("[truncated]"), "imported bytes count against maxBytes")
    XCTAssertLessThan(block.utf8.count, cap + 500)
  }

  func testImportsCanBeDisabled() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("STYLE RULES", to: repo.appendingPathComponent("style.md"))
    try write("# Rules\n@style.md", to: repo.appendingPathComponent("AGENTS.md"))

    let options = ProjectInstructions.Options(config: InstructionsConfig(imports: false))
    let block = try XCTUnwrap(
      ProjectInstructions.discover(workdir: repo, home: home, options: options))
    XCTAssertFalse(block.contains("STYLE RULES"))
    XCTAssertTrue(block.contains("@style.md"))
  }

  // MARK: Compact instructions

  func testCompactInstructionsSectionSplitOut() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write(
      """
      # Rules
      Do the thing.

      ## Compact Instructions
      Always keep the public API surface list.
      And the open TODOs.

      ## Other
      More rules.
      """,
      to: repo.appendingPathComponent("AGENTS.md"))

    let found = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home))
    XCTAssertTrue(found.text.contains("Do the thing."))
    XCTAssertTrue(found.text.contains("More rules."))
    XCTAssertFalse(found.text.contains("Always keep the public API surface list."),
                   "the compact section is lifted out of the system-prompt body")
    XCTAssertFalse(found.text.contains("Compact Instructions"))
    XCTAssertEqual(
      found.compactInstructions,
      "Always keep the public API surface list.\nAnd the open TODOs.")
    XCTAssertEqual(found.sources.first?.compactInstructions, found.compactInstructions)
  }

  func testCompactInstructionsHeadingIsCaseInsensitiveAndRunsToEndOfFile() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write(
      """
      Prose first.

      # compact instructions
      Keep the migration checklist.

      ## a subsection stays inside
      Also this.
      """,
      to: repo.appendingPathComponent("AGENTS.md"))

    let found = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home))
    XCTAssertEqual(found.text.contains("Prose first."), true)
    XCTAssertFalse(found.text.contains("Keep the migration checklist."))
    let compact = try XCTUnwrap(found.compactInstructions)
    XCTAssertTrue(compact.contains("Keep the migration checklist."))
    XCTAssertTrue(compact.contains("a subsection stays inside"), "deeper headings stay in the section")
    XCTAssertTrue(compact.contains("Also this."))
  }

  func testCompactInstructionsAbsentWhenNoSection() throws {
    let home = try tempDir()
    let repo = try tempRepo()
    try write("# Rules\nJust rules.", to: repo.appendingPathComponent("AGENTS.md"))
    let found = try XCTUnwrap(ProjectInstructions.discovered(workdir: repo, home: home))
    XCTAssertNil(found.compactInstructions)
  }
}
