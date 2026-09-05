import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// X6 — `arnes review`'s Kit half: `ReviewDiff.build` over real temp repositories (targets, the
/// untracked-file rules, the clip, the git pins), the findings schema in the strict subset, a
/// review run over the mock (posture, record tag, structured output), the exit-code rule and the
/// text renderer.
final class ReviewTests: XCTestCase {
  // MARK: Helpers

  /// An empty XDG config home, so the developer's own `~/.config/git/ignore` (which may well
  /// list `.netrc` or `*.pem`) can't hide an untracked file from `ls-files --exclude-standard`.
  private static let hermeticConfigHome: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-review-xdg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()

  private static let hermeticGit = [
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": hermeticConfigHome.path,
  ]

  /// The subprocess environment the build runs with in tests: the host's git config out of
  /// the way, so a user's `diff.noprefix` or `diff.external` can't shape a result.
  private static let hermeticEnvironment = SubprocessEnvironment(
    policy: ShellEnvironmentPolicy(set: hermeticGit))

  private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-review-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.resolvingSymlinksInPath()
  }

  @discardableResult
  private func git(_ arguments: [String], in root: URL, expectSuccess: Bool = true) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.environment = ProcessInfo.processInfo.environment.merging(Self.hermeticGit) { _, pinned in pinned }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    if expectSuccess {
      XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    }
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func commit(_ message: String, in root: URL) throws {
    try git(["add", "-A"], in: root)
    try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message], in: root)
  }

  /// A repository on `main` with one commit of `README.md` and `src/a.txt`.
  private func makeRepository(_ label: String) throws -> URL {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = try tempDirectory(label)
    try git(["init", "-q"], in: root)
    try git(["symbolic-ref", "HEAD", "refs/heads/main"], in: root)
    try "hello\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    try "one\ntwo\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try commit("initial", in: root)
    return root
  }

  private func build(_ target: ReviewTarget, cwd: URL) async throws -> ReviewDiff.Built {
    try await ReviewDiff.build(target: target, cwd: cwd, environment: Self.hermeticEnvironment)
  }

  private func writeScript(_ body: String, to url: URL) throws {
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  // MARK: ReviewDiff — targets

  func testUncommittedIncludesStagedUnstagedAndUntrackedFiles() async throws {
    let root = try makeRepository("uncommitted")
    defer { try? FileManager.default.removeItem(at: root) }
    // Staged: README; unstaged: src/a.txt; untracked: new.txt.
    try "hello world\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "README.md"], in: root)
    try "one\ntwo\nthree\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try "fresh\nfile\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

    let built = try await build(.uncommitted, cwd: root)
    XCTAssertEqual(built.root, try git(["rev-parse", "--show-toplevel"], in: root))
    XCTAssertEqual(built.files, ["README.md", "src/a.txt", "new.txt"])
    XCTAssertEqual(built.untrackedIncluded, ["new.txt"])
    XCTAssertEqual(built.skipped, [])
    XCTAssertEqual(built.omittedChars, 0)
    XCTAssertFalse(built.truncated)
    XCTAssertTrue(built.diff.contains("diff --git a/README.md b/README.md"), built.diff)
    XCTAssertTrue(built.diff.contains("+hello world"))
    XCTAssertTrue(built.diff.contains("+three"))
    // The untracked file rides as a new-file hunk the reviewer can cite line numbers from.
    XCTAssertTrue(built.diff.contains("diff --git a/new.txt b/new.txt\nnew file mode 100644\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1,2 @@\n+fresh\n+file\n"), built.diff)
  }

  func testUncommittedSkipsSymlinksBinariesAndOversizedUntrackedFiles() async throws {
    let root = try makeRepository("skips")
    defer { try? FileManager.default.removeItem(at: root) }
    // A secret outside the tree, linked from inside: never read through.
    let secretDirectory = try tempDirectory("secret")
    defer { try? FileManager.default.removeItem(at: secretDirectory) }
    let secret = secretDirectory.appendingPathComponent("id_rsa")
    try "PRIVATE KEY BYTES\n".write(to: secret, atomically: true, encoding: .utf8)
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("leak"), withDestinationURL: secret)
    try Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0x01, 0x02]).write(to: root.appendingPathComponent("img.png"))
    try Data(repeating: 0x61, count: ReviewDiff.maxUntrackedBytes + 1).write(to: root.appendingPathComponent("big.txt"))
    try "ok\n".write(to: root.appendingPathComponent("small.txt"), atomically: true, encoding: .utf8)

    let built = try await build(.uncommitted, cwd: root)
    XCTAssertEqual(built.untrackedIncluded, ["small.txt"])
    XCTAssertEqual(built.files, ["small.txt"])
    XCTAssertEqual(built.skipped.count, 3, "\(built.skipped)")
    XCTAssertTrue(built.skipped.contains("leak (symlink, not followed)"), "\(built.skipped)")
    XCTAssertTrue(built.skipped.contains("img.png (binary, looks like PNG)"), "\(built.skipped)")
    XCTAssertTrue(built.skipped.contains { $0.hasPrefix("big.txt (") && $0.contains("over the 256 KB cap") }, "\(built.skipped)")
    XCTAssertFalse(built.diff.contains("PRIVATE KEY"), "a symlink's target never reaches the diff")
    XCTAssertFalse(built.diff.contains("leak"))
  }

  func testUntrackedFilesOnCredentialDenyReadOrHarnessPathsAreNamedNeverRead() async throws {
    // The stray `git init ~` case: the repository root *is* the home directory, and
    // `ls-files --others` lists everything un-ignored under it — the credential files first.
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let home = try tempDirectory("home")
    defer { try? FileManager.default.removeItem(at: home) }
    try git(["init", "-q"], in: home)
    func plant(_ relative: String, _ contents: String) throws {
      let url = home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try contents.write(to: url, atomically: true, encoding: .utf8)
    }
    try plant(".ssh/id_rsa", "SSH PRIVATE KEY BYTES\n")
    try plant(".aws/credentials", "aws_secret_access_key = AWSSECRET\n")
    try plant(".netrc", "machine example.com password NETRCSECRET\n")
    try plant(".arnes/credentials", "openrouter=PROVIDERKEY\n")
    try plant(".arnes/hooks.json", "{\"hooks\": \"HARNESSSTATE\"}\n")
    try plant("server.pem", "-----BEGIN PEMSECRET-----\n")
    try plant("notes.txt", "plain notes\n")

    let rules = PathScope.Rules(
      policy: PathPolicy(denyRead: ["*.pem"]),
      harnessPaths: [home.appendingPathComponent(".arnes").path])
    let built = try await ReviewDiff.build(
      target: .uncommitted, cwd: home, sandbox: nil, environment: Self.hermeticEnvironment,
      rules: rules, home: home.path)

    XCTAssertEqual(built.untrackedIncluded, ["notes.txt"])
    XCTAssertEqual(built.files, ["notes.txt"])
    XCTAssertTrue(built.diff.contains("+plain notes"))
    XCTAssertEqual(Set(built.skipped), [
      ".ssh/id_rsa (credential location, not read)",
      ".aws/credentials (credential location, not read)",
      ".netrc (credential location, not read)",
      ".arnes/credentials (credential location, not read)",
      ".arnes/hooks.json (harness file, not read)",
      "server.pem (denied by paths.denyRead, not read)",
    ], "\(built.skipped)")
    for secret in ["SSH PRIVATE", "AWSSECRET", "NETRCSECRET", "PROVIDERKEY", "HARNESSSTATE", "PEMSECRET"] {
      XCTAssertFalse(built.diff.contains(secret), "\(secret) reached the diff")
    }
    // The same rule, unit-level: the classification runs before any byte is read.
    XCTAssertEqual(
      ReviewDiff.untrackedHunk(for: "server.pem", under: home, rules: rules, home: home.path),
      .skipped("denied by paths.denyRead, not read"))
    XCTAssertEqual(
      ReviewDiff.untrackedHunk(for: ".ssh/id_rsa", under: home, rules: .default, home: home.path),
      .skipped("credential location, not read"))
    XCTAssertNil(ReviewDiff.readRefusal(for: "notes.txt", under: home, rules: rules, home: home.path))
  }

  func testUntrackedFilesPastTheDiffCapAreNamedNotRead() async throws {
    let root = try makeRepository("cap")
    defer { try? FileManager.default.removeItem(at: root) }
    // Five untracked files of 30 000 characters: the first two fill the 60 000-char diff,
    // the rest are listed and never opened (u1 < u2 < … is git's own order).
    let body = String(repeating: "x", count: 30_000) + "\n"
    for index in 1...5 {
      try body.write(to: root.appendingPathComponent("u\(index).txt"), atomically: true, encoding: .utf8)
    }
    let built = try await build(.uncommitted, cwd: root)
    XCTAssertEqual(built.untrackedIncluded, ["u1.txt", "u2.txt"])
    XCTAssertEqual(built.files, ["u1.txt", "u2.txt"])
    XCTAssertEqual(built.skipped, [
      "u3.txt (past the \(ReviewDiff.maxChars)-char diff cap)",
      "u4.txt (past the \(ReviewDiff.maxChars)-char diff cap)",
      "u5.txt (past the \(ReviewDiff.maxChars)-char diff cap)",
    ])
    XCTAssertTrue(built.diff.contains("+++ b/u1.txt"))
    XCTAssertFalse(built.diff.contains("+++ b/u3.txt"))
    XCTAssertTrue(built.truncated, "two 30 KB hunks overrun the cap by their headers; the clip trims the rest")
    XCTAssertLessThanOrEqual(built.diff.count, ReviewDiff.maxChars + 120)

    // A tracked diff that already fills the cap leaves no room: every untracked file is named.
    let full = try makeRepository("full")
    defer { try? FileManager.default.removeItem(at: full) }
    try (String(repeating: "y", count: ReviewDiff.maxChars) + "\n").write(
      to: full.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try "small\n".write(to: full.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
    let fullBuilt = try await build(.uncommitted, cwd: full)
    XCTAssertEqual(fullBuilt.untrackedIncluded, [])
    XCTAssertEqual(fullBuilt.skipped, ["new.txt (past the \(ReviewDiff.maxChars)-char diff cap)"])
    XCTAssertEqual(fullBuilt.files, ["src/a.txt"])
  }

  func testTheSkippedListIsCappedWithOneSummaryLine() async throws {
    let root = try makeRepository("many")
    defer { try? FileManager.default.removeItem(at: root) }
    // `a.txt` alone fills the diff; the 55 `z*.txt` after it are past the cap — 50 named, then
    // one line with the count, so a tree of ten thousand un-ignored files can't flood the header.
    try (String(repeating: "x", count: 100_000) + "\n").write(
      to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    for index in 0..<(ReviewDiff.skippedListCap + 5) {
      try "z\n".write(
        to: root.appendingPathComponent(String(format: "z%02d.txt", index)), atomically: true, encoding: .utf8)
    }
    let built = try await build(.uncommitted, cwd: root)
    XCTAssertEqual(built.untrackedIncluded, ["a.txt"])
    XCTAssertEqual(built.skipped.count, ReviewDiff.skippedListCap + 1)
    XCTAssertEqual(built.skipped.first, "z00.txt (past the \(ReviewDiff.maxChars)-char diff cap)")
    XCTAssertEqual(built.skipped.last, "(5 more untracked files not shown — glob them if they matter)")
    XCTAssertFalse(built.diff.contains("z54.txt"))
  }

  func testListCommandsUseNULSeparatorsAndTheHeaderStripsControlCharacters() async throws {
    let root = try makeRepository("names")
    defer { try? FileManager.default.removeItem(at: root) }
    // A tracked non-ASCII path: without `-z` and under LC_ALL=C git would spell it "src/\303\251.txt".
    let accented = root.appendingPathComponent("src/é.txt")
    try "e\n".write(to: accented, atomically: true, encoding: .utf8)
    try commit("accent", in: root)
    try "e2\n".write(to: accented, atomically: true, encoding: .utf8)
    // An untracked name with a newline in it: raw from `ls-files -z`, control-stripped in the header.
    try "n\n".write(to: root.appendingPathComponent("new\nline.txt"), atomically: true, encoding: .utf8)

    let built = try await build(.uncommitted, cwd: root)
    XCTAssertEqual(built.files, ["src/é.txt", "new\nline.txt"])
    XCTAssertEqual(built.untrackedIncluded, ["new\nline.txt"])
    let task = Review.task(target: .uncommitted, built: built)
    XCTAssertTrue(task.contains("- src/é.txt\n- newline.txt\n"), task)
    XCTAssertTrue(task.contains("Untracked files (not staged, not committed), shown below as new-file hunks: newline.txt\n"))
    XCTAssertFalse(task.contains("- new\nline.txt"), "a newline in a name never breaks the header")

    // The commit target lists its paths the same way (git's own order: bytewise).
    try commit("accent2", in: root)
    let shown = try await build(.commit("HEAD"), cwd: root)
    XCTAssertEqual(shown.files, ["new\nline.txt", "src/é.txt"])
  }

  func testAnOverflowingPathListIsRefusedNotReadAroundTheGap() {
    let cut = ReviewDiff.Git.Result(ok: true, output: "a\0b\0", truncatedBytes: 12, detail: "")
    XCTAssertThrowsError(try ReviewDiff.paths(from: cut, command: "ls-files")) { error in
      guard case .gitFailed(let detail)? = error as? ReviewError else { return XCTFail("\(error)") }
      XCTAssertTrue(detail.contains("too many paths to list"), detail)
      XCTAssertTrue(detail.contains("ls-files"))
    }
    let whole = ReviewDiff.Git.Result(ok: true, output: "a\0b c\0", truncatedBytes: 0, detail: "")
    XCTAssertEqual(try ReviewDiff.paths(from: whole, command: "x"), ["a", "b c"])
    XCTAssertGreaterThanOrEqual(ReviewDiff.listBounds.headBytes, 4 * 1024 * 1024)
  }

  func testUncommittedInARepositoryWithoutCommitsDiffsAgainstTheEmptyTree() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = try tempDirectory("unborn")
    defer { try? FileManager.default.removeItem(at: root) }
    try git(["init", "-q"], in: root)
    try "first\n".write(to: root.appendingPathComponent("staged.txt"), atomically: true, encoding: .utf8)
    try git(["add", "staged.txt"], in: root)
    try "loose\n".write(to: root.appendingPathComponent("loose.txt"), atomically: true, encoding: .utf8)

    let built = try await build(.uncommitted, cwd: root)
    XCTAssertEqual(built.files, ["staged.txt", "loose.txt"])
    XCTAssertTrue(built.diff.contains("+first"))
    XCTAssertTrue(built.diff.contains("+loose"))
    XCTAssertEqual(built.untrackedIncluded, ["loose.txt"])
  }

  func testBaseDiffsFromTheMergeBaseSoLaterCommitsOnTheBaseAreNotReviewed() async throws {
    let root = try makeRepository("base")
    defer { try? FileManager.default.removeItem(at: root) }
    try git(["checkout", "-q", "-b", "feature"], in: root)
    try "one\ntwo\nfeature\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try commit("feature work", in: root)
    // main moves on after the branch point: not part of the branch's diff.
    try git(["checkout", "-q", "main"], in: root)
    try "hello\nmain moved\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try commit("main moves", in: root)
    try git(["checkout", "-q", "feature"], in: root)
    // Uncommitted work is not part of a --base review either.
    try "scratch\n".write(to: root.appendingPathComponent("scratch.txt"), atomically: true, encoding: .utf8)

    let built = try await build(.base("main"), cwd: root)
    XCTAssertEqual(built.files, ["src/a.txt"])
    XCTAssertTrue(built.diff.contains("+feature"))
    XCTAssertFalse(built.diff.contains("main moved"))
    XCTAssertFalse(built.diff.contains("scratch"))
    XCTAssertEqual(built.untrackedIncluded, [])

    do {
      _ = try await build(.base("no-such-branch"), cwd: root)
      XCTFail("a bad ref is refused")
    } catch let error as ReviewError {
      XCTAssertEqual(error, .badRef("no-such-branch"))
      XCTAssertTrue(error.description.contains("no-such-branch"))
    }
  }

  func testCommitShowsOnlyThatCommit() async throws {
    let root = try makeRepository("commit")
    defer { try? FileManager.default.removeItem(at: root) }
    try "hello\nsecond\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try commit("second", in: root)
    let second = try git(["rev-parse", "HEAD"], in: root)
    try "one\ntwo\nthird\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try commit("third", in: root)

    let built = try await build(.commit(String(second.prefix(10))), cwd: root)
    XCTAssertEqual(built.files, ["README.md"])
    XCTAssertTrue(built.diff.contains("+second"))
    XCTAssertFalse(built.diff.contains("third"))
    XCTAssertFalse(built.diff.hasPrefix("commit "), "--format= drops the header: \(built.diff.prefix(40))")

    do {
      _ = try await build(.commit("deadbeef"), cwd: root)
      XCTFail("an unknown sha is refused")
    } catch let error as ReviewError {
      XCTAssertEqual(error, .badRef("deadbeef"))
    }
  }

  func testNotARepositoryAndACleanTreeAreRefusedBeforeAnyRequest() async throws {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let plain = try tempDirectory("plain")
    defer { try? FileManager.default.removeItem(at: plain) }
    do {
      _ = try await build(.uncommitted, cwd: plain)
      XCTFail("not a repository")
    } catch let error as ReviewError {
      XCTAssertEqual(error, .notAGitRepo(plain.path))
      XCTAssertTrue(error.description.contains("not inside a git repository"))
    }

    let clean = try makeRepository("clean")
    defer { try? FileManager.default.removeItem(at: clean) }
    do {
      _ = try await build(.uncommitted, cwd: clean)
      XCTFail("nothing to review")
    } catch let error as ReviewError {
      XCTAssertEqual(error, .nothingToReview)
    }
  }

  func testBuildFromASubdirectoryReportsTheRootAndRootRelativePaths() async throws {
    let root = try makeRepository("subdir")
    defer { try? FileManager.default.removeItem(at: root) }
    try "one\ntwo\nx\n".write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    try "new\n".write(to: root.appendingPathComponent("src/b.txt"), atomically: true, encoding: .utf8)
    let built = try await build(.uncommitted, cwd: root.appendingPathComponent("src"))
    XCTAssertEqual(built.root, try git(["rev-parse", "--show-toplevel"], in: root))
    XCTAssertEqual(built.files, ["src/a.txt", "src/b.txt"], "paths are repository-relative whichever directory the review started in")
    XCTAssertTrue(built.diff.contains("+++ b/src/b.txt"))
  }

  // MARK: ReviewDiff — clip and pins

  func testAnOversizedDiffIsClippedWithTheTrailerAndCounted() async throws {
    let root = try makeRepository("big")
    defer { try? FileManager.default.removeItem(at: root) }
    let lines = (0..<3000).map { "line \($0) " + String(repeating: "x", count: 30) }
    try lines.joined(separator: "\n").write(to: root.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
    let built = try await build(.uncommitted, cwd: root)
    XCTAssertGreaterThan(built.omittedChars, 0)
    XCTAssertTrue(built.truncated)
    XCTAssertTrue(built.diff.hasSuffix("more chars; read_file the files listed above for the rest]"), String(built.diff.suffix(120)))
    XCTAssertTrue(built.diff.contains("… [diff truncated, \(built.omittedChars) more chars;"))
    XCTAssertLessThanOrEqual(built.diff.count, ReviewDiff.maxChars + 120)
    XCTAssertEqual(built.files, ["src/a.txt"], "the file list stays whole")
  }

  func testClipIsPureAndLeavesAShortDiffAlone() {
    XCTAssertEqual(ReviewDiff.clip("short").text, "short")
    XCTAssertEqual(ReviewDiff.clip("short").omitted, 0)
    let long = String(repeating: "a", count: ReviewDiff.maxChars + 5)
    let clipped = ReviewDiff.clip(long, extraOmitted: 10)
    XCTAssertEqual(clipped.omitted, 15)
    XCTAssertTrue(clipped.text.hasPrefix(String(repeating: "a", count: ReviewDiff.maxChars) + "\n… [diff truncated, 15 more chars;"))
  }

  func testTheRepositorysDiffExternalNeverRuns() async throws {
    let root = try makeRepository("extdiff")
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("MARKER")
    let script = root.appendingPathComponent("ext.sh")
    try writeScript("touch '\(marker.path)'", to: script)
    try git(["config", "diff.external", script.path], in: root)
    try "hello\nchanged\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    // Control: a plain `git diff` on this host does honor the repository's diff.external —
    // otherwise the assertion below would prove nothing.
    _ = try git(["diff", "HEAD"], in: root)
    try XCTSkipUnless(FileManager.default.fileExists(atPath: marker.path), "this git doesn't run diff.external")
    try FileManager.default.removeItem(at: marker)

    let built = try await build(.uncommitted, cwd: root)
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the repository's diff.external must not run")
    XCTAssertTrue(built.diff.contains("+changed"), "and the diff is git's own")
    // The untracked script and the marker-free tree are what the diff describes.
    XCTAssertEqual(built.untrackedIncluded, ["ext.sh"])

    // Belt and braces: the environment pins name the command-running keys too, inherited by
    // any git the diff's git spawns.
    let env = ReviewDiff.environment
    XCTAssertEqual(env["GIT_OPTIONAL_LOCKS"], "0")
    XCTAssertEqual(env["LC_ALL"], "C")
    let pinned = Dictionary(uniqueKeysWithValues: (0..<Int(env["GIT_CONFIG_COUNT"]!)!).map {
      (env["GIT_CONFIG_KEY_\($0)"]!, env["GIT_CONFIG_VALUE_\($0)"]!)
    })
    XCTAssertEqual(pinned["core.fsmonitor"], "false")
    XCTAssertEqual(pinned["log.showSignature"], "false")
    XCTAssertEqual(pinned["diff.external"], "")
    XCTAssertEqual(pinned["core.pager"], "cat")
    XCTAssertTrue(ReviewDiff.diffFlags.contains("--no-ext-diff"))
    XCTAssertTrue(ReviewDiff.diffFlags.contains("--no-textconv"))
  }

  func testPinningGitCarriesThePinsIntoTheReviewersOwnBash() {
    // The reviewer types `git diff HEAD~1` through bash: the same repository config that the
    // builder pinned off must not run there either. `set` is applied after every exclusion.
    let strict = SubprocessEnvironment(
      policy: ShellEnvironmentPolicy(inherit: .core, excludeSecrets: true, includeOnly: ["PATH", "HOME"], set: ["FOO": "bar"]),
      redactedKeys: ["MY_PROVIDER_KEY"])
    let pinned = ReviewDiff.pinningGit(strict)
    let child = pinned.resolve(inheriting: ["PATH": "/usr/bin", "HOME": "/h", "MY_PROVIDER_KEY": "k", "GIT_CONFIG_COUNT": "9"])
    XCTAssertEqual(child["GIT_CONFIG_COUNT"], "4")
    XCTAssertEqual(child["GIT_CONFIG_KEY_2"], "diff.external")
    XCTAssertEqual(child["GIT_CONFIG_VALUE_2"], "")
    XCTAssertEqual(child["GIT_CONFIG_KEY_0"], "core.fsmonitor")
    XCTAssertEqual(child["GIT_OPTIONAL_LOCKS"], "0")
    XCTAssertEqual(child["FOO"], "bar", "the policy's own `set` survives")
    XCTAssertNil(child["MY_PROVIDER_KEY"], "redaction is untouched")
    XCTAssertNil(child["LC_ALL"], "the locale pin is the builder's alone")
    XCTAssertEqual(pinned.redactedKeys, strict.redactedKeys)
    // The builder's environment is the pins plus LC_ALL=C.
    XCTAssertEqual(ReviewDiff.environment, ReviewDiff.gitPins.merging(["LC_ALL": "C"]) { _, new in new })
    XCTAssertEqual(ReviewDiff.pinningGit(.default).policy.set, ReviewDiff.gitPins)
  }

  func testUntrackedHunkRules() throws {
    let root = try tempDirectory("hunk")
    defer { try? FileManager.default.removeItem(at: root) }
    try "a\nb".write(to: root.appendingPathComponent("noeol.txt"), atomically: true, encoding: .utf8)
    XCTAssertEqual(
      ReviewDiff.untrackedHunk(for: "noeol.txt", under: root),
      .included("diff --git a/noeol.txt b/noeol.txt\nnew file mode 100644\n--- /dev/null\n+++ b/noeol.txt\n@@ -0,0 +1,2 @@\n+a\n+b\n"))
    XCTAssertEqual(ReviewDiff.untrackedHunk(for: "missing.txt", under: root), .skipped("unreadable"))
    try FileManager.default.createDirectory(at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
    XCTAssertEqual(ReviewDiff.untrackedHunk(for: "dir", under: root), .skipped("not a regular file"))
    // A secret carrier by name is named, never pasted — the model may still read_file it.
    try "SECRET=abc".write(to: root.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    XCTAssertEqual(ReviewDiff.untrackedHunk(for: ".env", under: root), .skipped("looks like a secret by name, not pasted"))
  }

  func testSecretLikeNamesAreRecognizedByBasename() {
    for path in [".env", ".env.local", "config/.env.production", "server.pem", "deploy/id_rsa", "id_ed25519.pub",
                 "keys/app.key", "store.p12", "store.jks", "prod.tfvars", ".netrc", ".npmrc", "credentials.json", "aws/credentials"] {
      XCTAssertTrue(ReviewDiff.hasSecretLikeName(path), path)
    }
    for path in ["environment.swift", "env.md", "keyboard.swift", "Package.swift", "src/keys.swift", "notes/credentials-policy.md", "pemdas.py"] {
      XCTAssertFalse(ReviewDiff.hasSecretLikeName(path), path)
    }
  }

  // MARK: Schema

  private static let golden: JSONValue = [
    "summary": "Adds a cache; one off-by-one.",
    "findings": [
      [
        "file": "src/a.swift", "line": 42, "severity": "high", "category": "correctness",
        "summary": "the loop skips the last element", "failure_scenario": "an array of one item → nothing is processed",
        "confidence": "confirmed",
      ],
      [
        "file": "src/b.swift", "line": .null, "severity": "low", "category": "error-handling",
        "summary": "the error is swallowed", "failure_scenario": "a failed write is reported as success",
        "confidence": "plausible",
      ],
    ],
  ]

  func testGoldenFindingsValidateAndBadOnesDoNot() throws {
    let schema = ReviewFindings.schema
    XCTAssertEqual(JSONSchemaLite.validate(Self.golden, against: schema), [])
    XCTAssertEqual(JSONSchemaLite.validate(["summary": "clean", "findings": []], against: schema), [])

    /// The golden object with its first finding changed by `edit`.
    func withFirstFinding(_ edit: (inout [String: JSONValue]) -> Void) -> JSONValue {
      var object = Self.golden.objectValue!
      var finding = object["findings"]!.arrayValue![0].objectValue!
      edit(&finding)
      object["findings"] = .array([.object(finding)])
      return .object(object)
    }
    let badSeverity = withFirstFinding { $0["severity"] = "critical" }
    XCTAssertFalse(JSONSchemaLite.validate(badSeverity, against: schema).isEmpty)
    let missing = withFirstFinding { $0.removeValue(forKey: "failure_scenario") }
    XCTAssertFalse(JSONSchemaLite.validate(missing, against: schema).isEmpty)
    let badLine = withFirstFinding { $0["line"] = "42" }
    XCTAssertFalse(JSONSchemaLite.validate(badLine, against: schema).isEmpty)

    var extra = Self.golden.objectValue!
    extra["verdict"] = "ship it"
    XCTAssertFalse(JSONSchemaLite.validate(.object(extra), against: schema).isEmpty)

    // The strict subset: every object closes its properties and requires all of them.
    let items = try XCTUnwrap(schema["properties"]?["findings"]?["items"])
    XCTAssertEqual(items["additionalProperties"], false)
    XCTAssertEqual(items["required"]?.arrayValue?.count, items["properties"]?.objectValue?.count)
    XCTAssertEqual(schema["additionalProperties"], false)
    XCTAssertEqual(schema["required"], ["summary", "findings"])
    XCTAssertEqual(items["properties"]?["line"]?["type"], ["integer", "null"])
  }

  func testOutputSchemaAcceptsTheFindingsSchemaAndTheObjectRoundTrips() throws {
    let output = try OutputSchema(schema: ReviewFindings.schema)
    XCTAssertEqual(output.name, "review_findings")
    let findings = try ReviewFindings(from: Self.golden)
    XCTAssertEqual(findings.summary, "Adds a cache; one off-by-one.")
    XCTAssertEqual(findings.findings.count, 2)
    XCTAssertEqual(findings.findings[0].line, 42)
    XCTAssertEqual(findings.findings[0].severity, .high)
    XCTAssertEqual(findings.findings[0].failureScenario, "an array of one item → nothing is processed")
    XCTAssertNil(findings.findings[1].line)
    XCTAssertEqual(findings.findings[1].confidence, .plausible)
    XCTAssertEqual(findings.findings[1].location, "src/b.swift")
    XCTAssertEqual(findings.findings[0].location, "src/a.swift:42")
    // Encoding spells the wire key the schema does.
    let encoded = String(decoding: try JSONEncoder().encode(findings.findings[0]), as: UTF8.self)
    XCTAssertTrue(encoded.contains("\"failure_scenario\""))
    XCTAssertFalse(encoded.contains("failureScenario"))
    XCTAssertEqual(try ReviewFindings(from: Fixtures.jsonValue(findings)), findings)
    XCTAssertThrowsError(try ReviewFindings(from: ["summary": 1]))
  }

  // MARK: The run

  private static func manifestModel(id: String, parameters: [String]) -> String {
    let list = parameters.map { "\"\($0)\"" }.joined(separator: ",")
    return """
      {"id":"\(id)","context_length":8000,"supported_parameters":[\(list)],"pricing":{"prompt":"0.000001","completion":"0.000002"}}
      """
  }

  private static func reply(_ text: String) -> ChatCompletionResponse {
    let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    return Fixtures.response("""
      {"id":"gen-r","model":"test/model","choices":[{"index":0,"message":{"role":"assistant","content":\(encoded)},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":8,"cost":0.001}}
      """)
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-review-\(UUID().uuidString).jsonl"))
  }

  private func reviewConfiguration(root: URL) throws -> Session.Configuration {
    var configuration = Session.Configuration(
      model: "test/model",
      maxStepsPerTurn: 20,
      systemSuffix: Review.systemSuffix,
      agent: Review.agentName,
      workingDirectory: root,
      outputSchema: try OutputSchema(schema: ReviewFindings.schema))
    configuration.sessionOrigin = Review.agentName
    return configuration
  }

  func testAReviewRunIsReadOnlyTaggedAndYieldsFindings() async throws {
    let root = try makeRepository("run")
    defer { try? FileManager.default.removeItem(at: root) }
    try "hello\nchanged\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    let built = try await build(.uncommitted, cwd: root)

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path":"planted.txt","content":"x"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "c2", name: "bash", arguments: #"{"command":"echo x > planted2.txt"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.toolCallChunk(id: "c3", name: "bash", arguments: #"{"command":"git log -1 --format=%s"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("One off-by-one, otherwise fine."), Fixtures.usageChunk(cost: 0.002)],
    ]
    let findingsJSON = String(decoding: try JSONEncoder().encode(Self.golden), as: UTF8.self)
    mock.chatResponses = [Self.reply(findingsJSON)]

    let tools = try Review.tools(from: HarnessAssembly.coreTools(
      ToolContext(root: root, environment: Self.hermeticEnvironment)))
    XCTAssertEqual(tools.map(\.name), ["read_file", "bash", "grep", "glob", "think"], "the reviewer's toolset: no write/edit, no plan")
    let agent = Agent(
      service: mock, tools: tools,
      permissions: SerializedPermissions(DenyMutationsPermissions(reason: "review is read-only")),
      store: tempStore(), configuration: try reviewConfiguration(root: root))
    var events: [AgentEvent] = []
    let lock = NSLock()
    let result = try await agent.run(
      task: Review.task(target: .uncommitted, built: built, focus: "the README wording"),
      model: "test/model",
      onEvent: { event in lock.withLock { events.append(event) } })

    // The record is a review's, and the structured object decodes.
    XCTAssertEqual(result.record.agent, "review")
    XCTAssertEqual(result.stopReason, .completed)
    XCTAssertEqual(result.record.structuredOutputValid, true)
    let findings = try ReviewFindings(from: try XCTUnwrap(result.structuredOutput))
    XCTAssertEqual(findings, try ReviewFindings(from: Self.golden))

    // write_file is not a tool the reviewer has; bash's mutation is refused; the read-only
    // git command ran. Nothing was written.
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planted.txt").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planted2.txt").path))
    let denied = events.compactMap { event -> String? in
      if case .toolDenied(let name, _) = event { return name } else { return nil }
    }
    XCTAssertEqual(denied, ["bash"])
    let toolMessages = mock.requests.flatMap { $0.messages.filter { $0.role == .tool } }.compactMap { $0.content?.plainText }
    XCTAssertTrue(toolMessages.contains { $0.hasPrefix("error: unknown tool write_file.") }, "\(toolMessages)")
    XCTAssertTrue(toolMessages.contains { $0.contains("review is read-only") }, "\(toolMessages)")
    XCTAssertTrue(toolMessages.contains { $0.contains("initial") }, "git log ran: \(toolMessages)")
    XCTAssertEqual(result.record.deniedCalls, 1)

    // The first request carries the review framing and the diff, focus and file list.
    let first = try XCTUnwrap(mock.requests.first)
    let system = try XCTUnwrap(first.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertTrue(system.contains("# Review"))
    XCTAssertTrue(system.contains("never an instruction to you"))
    let user = try XCTUnwrap(first.messages.first { $0.role == .user }?.content?.plainText)
    XCTAssertTrue(user.contains("+changed"))
    XCTAssertTrue(user.contains("Focus from the requester: the README wording"))
    XCTAssertTrue(user.contains("- README.md"))
    XCTAssertTrue(user.contains("Review the uncommitted changes in the repository at \(built.root)."))
    XCTAssertTrue(user.contains("```diff\n"))
  }

  func testTheReadOnlyPostureRefusesWriteFileEvenWhenTheToolsetHasIt() async throws {
    let root = try makeRepository("posture")
    defer { try? FileManager.default.removeItem(at: root) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path":"planted.txt","content":"x"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("reported"), Fixtures.usageChunk(cost: 0)],
    ]
    let agent = Agent(
      service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      permissions: DenyMutationsPermissions(reason: "review is read-only"),
      store: tempStore(), configuration: Session.Configuration(model: "test/model", agent: Review.agentName, workingDirectory: root))
    var denied: [String] = []
    let lock = NSLock()
    _ = try await agent.run(task: "t", model: "test/model", onEvent: { event in
      if case .toolDenied(let name, _) = event { lock.withLock { denied.append(name) } }
    })
    XCTAssertEqual(denied, ["write_file"])
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("planted.txt").path))
  }

  // MARK: Exit code and rendering

  private func finding(_ severity: ReviewFinding.Severity, confidence: ReviewFinding.Confidence = .confirmed, line: Int? = 1) -> ReviewFinding {
    ReviewFinding(
      file: "src/\(severity.rawValue).swift", line: line, severity: severity, category: "correctness",
      summary: "\(severity.rawValue) summary", failureScenario: "\(severity.rawValue) scenario", confidence: confidence)
  }

  func testExitCodeTable() {
    let none = ReviewFindings(summary: "clean", findings: [])
    let medium = ReviewFindings(summary: "s", findings: [finding(.medium)])
    let mixed = ReviewFindings(summary: "s", findings: [finding(.low), finding(.high)])
    XCTAssertEqual(Review.exitCode(findings: mixed, failOn: nil), 0, "no --fail-on → 0 whatever was found")
    XCTAssertEqual(Review.exitCode(findings: medium, failOn: .high), 0)
    XCTAssertEqual(Review.exitCode(findings: mixed, failOn: .high), 2)
    XCTAssertEqual(Review.exitCode(findings: medium, failOn: .low), 2)
    XCTAssertEqual(Review.exitCode(findings: medium, failOn: .medium), 2)
    XCTAssertEqual(Review.exitCode(findings: none, failOn: .low), 0)
    XCTAssertTrue(ReviewFinding.Severity.low < ReviewFinding.Severity.medium)
    XCTAssertTrue(ReviewFinding.Severity.medium < ReviewFinding.Severity.high)
    XCTAssertEqual(mixed.count(atLeast: .medium), 1)
  }

  func testRenderGroupsBySeverityAndTagsPlausibleFindings() {
    let findings = ReviewFindings(
      summary: "Two problems.",
      findings: [finding(.low), finding(.high, confidence: .plausible), finding(.medium, line: nil)])
    let text = Review.render(findings)
    XCTAssertEqual(text, """
      Two problems.

      ✘ high src/high.swift:1 — high summary (plausible) [correctness]
          scenario: high scenario
      ▲ medium src/medium.swift — medium summary [correctness]
          scenario: medium scenario
      · low src/low.swift:1 — low summary [correctness]
          scenario: low scenario
      """)
    XCTAssertEqual(Review.render(ReviewFindings(summary: "Nothing wrong.", findings: [])), "Nothing wrong.\n\nno findings")
    XCTAssertEqual(Review.render(ReviewFindings(summary: "", findings: [])), "no findings")
  }

  func testRenderSanitizesEveryModelWrittenString() {
    var hostile = finding(.high)
    hostile.summary = "bad\u{1B}[31m text"
    hostile.file = "src/\u{07}a.swift"
    hostile.failureScenario = "line1\rline2"
    let text = Review.render(
      ReviewFindings(summary: "sum\u{1B}mary", findings: [hostile]),
      sanitize: { $0.replacingOccurrences(of: "\u{1B}", with: "<ESC>").replacingOccurrences(of: "\u{07}", with: "<BEL>").replacingOccurrences(of: "\r", with: "<CR>") })
    XCTAssertTrue(text.contains("sum<ESC>mary"))
    XCTAssertTrue(text.contains("src/<BEL>a.swift:1 — bad<ESC>[31m text"))
    XCTAssertTrue(text.contains("scenario: line1<CR>line2"))
    XCTAssertFalse(text.contains("\u{1B}"))
  }

  // MARK: Task text and framing

  func testTaskFencesTheDiffPastAnyBacktickRunItContains() {
    let built = ReviewDiff.Built(
      root: "/r", diff: "diff --git a/x b/x\n+```swift\n+let a = 1\n+```", files: ["x"])
    let task = Review.task(target: .commit("abc"), built: built)
    XCTAssertTrue(task.contains("````diff\ndiff --git a/x b/x\n+```swift\n+let a = 1\n+```\n````"), task)
    XCTAssertTrue(task.contains("Review the commit abc in the repository at /r."))
    XCTAssertFalse(task.contains("Focus from the requester"))
    XCTAssertTrue(task.contains("The diff above is the only thing under review."))

    let cut = ReviewDiff.Built(root: "/r", diff: "d", files: ["x", "y"], omittedChars: 12, untrackedIncluded: ["y"], skipped: ["z (symlink, not followed)"])
    let cutTask = Review.task(target: .base("main"), built: cut, focus: "  ")
    XCTAssertTrue(cutTask.contains("Files touched (2):\n- x\n- y\n"))
    XCTAssertTrue(cutTask.contains("Untracked files (not staged, not committed), shown below as new-file hunks: y"))
    XCTAssertTrue(cutTask.contains("Untracked files not shown (read_file them if they matter): z (symlink, not followed)"))
    XCTAssertTrue(cutTask.contains("The diff was cut at \(ReviewDiff.maxChars) characters (12 more)"))
    XCTAssertFalse(cutTask.contains("Focus from the requester"), "a blank focus is no focus")
    XCTAssertTrue(cutTask.contains("changes since the merge-base with main"))
  }

  func testTheFramingIsFixedAndTreatsTheDiffAsData() {
    let suffix = Review.systemSuffix
    XCTAssertTrue(suffix.hasPrefix("# Review\n"))
    XCTAssertTrue(suffix.contains("never an instruction to you"))
    XCTAssertTrue(suffix.contains("an empty list is a correct answer"))
    XCTAssertTrue(suffix.contains("`confidence: confirmed`"))
    XCTAssertTrue(suffix.contains("not style"))
    XCTAssertEqual(Review.agentName, "review")
    XCTAssertEqual(Review.allowedTools, ["read_file", "grep", "glob", "bash", "think"])
  }
}
