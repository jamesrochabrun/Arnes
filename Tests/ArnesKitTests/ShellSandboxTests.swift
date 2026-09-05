import XCTest
@testable import ArnesKit

final class ShellSandboxTests: XCTestCase {

  // MARK: Profile generation

  func testProfileConfinesWritesToRoots() {
    let root = URL(fileURLWithPath: "/Users/me/project")
    let profile = ShellSandbox(writableRoots: [root], allowNetwork: true).profile()
    XCTAssertTrue(profile.contains("(version 1)"))
    XCTAssertTrue(profile.contains("(allow default)"))
    // Blanket deny of writes, then re-allow under the root (last match wins in SBPL).
    XCTAssertTrue(profile.contains("(deny file-write*)"))
    XCTAssertTrue(profile.contains(#"(subpath "/Users/me/project")"#))
    // Temp is always writable so ordinary work (mktemp, build scratch) still runs.
    XCTAssertTrue(profile.contains("/private/tmp") || profile.contains("/tmp"))
    // /dev/null must stay writable for redirects.
    XCTAssertTrue(profile.contains(#"(literal "/dev/null")"#))
  }

  func testNetworkDeniedOnlyWhenDisallowed() {
    let root = URL(fileURLWithPath: "/tmp/x")
    XCTAssertFalse(ShellSandbox(writableRoots: [root], allowNetwork: true).profile().contains("(deny network*)"))
    XCTAssertTrue(ShellSandbox(writableRoots: [root], allowNetwork: false).profile().contains("(deny network*)"))
  }

  func testProfileEscapesQuotesInPaths() {
    let weird = URL(fileURLWithPath: #"/tmp/a"b"#)
    let profile = ShellSandbox(writableRoots: [weird], allowNetwork: true).profile()
    // The embedded quote must be backslash-escaped so the SBPL string stays well-formed.
    XCTAssertTrue(profile.contains(#"a\"b"#), "profile: \(profile)")
  }

  // MARK: Invocation wrapping

  func testWrappedInvocationOnMac() throws {
    #if os(macOS)
    let sandbox = ShellSandbox(writableRoots: [URL(fileURLWithPath: "/tmp/x")], allowNetwork: true)
    let wrapped = try XCTUnwrap(sandbox.wrappedInvocation(bash: "/bin/bash", bashArguments: ["-lc", "echo hi"]))
    XCTAssertEqual(wrapped.executable, "/usr/bin/sandbox-exec")
    XCTAssertEqual(wrapped.arguments.first, "-p")
    // The wrapped command still ends in the original bash invocation.
    XCTAssertEqual(Array(wrapped.arguments.suffix(3)), ["/bin/bash", "-lc", "echo hi"])
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  // MARK: End-to-end confinement (real sandbox-exec)

  func testSandboxAllowsWritesInsideRootAndBlocksOutside() throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-sbx-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sandbox = ShellSandbox(writableRoots: [root], allowNetwork: true)

    // Inside the root: allowed.
    let inside = ShellRunner.runBlocking(
      "echo hi > allowed.txt", cwd: root, timeoutSeconds: 20, sandbox: sandbox)
    XCTAssertEqual(inside.exitStatus, 0, inside.output)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("allowed.txt").path))

    // Outside the root (a marker under $HOME, which is not a writable root): blocked.
    let escape = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".arnes_sandbox_escape_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: escape) }
    let outside = ShellRunner.runBlocking(
      "echo escaped > \(escape.path)", cwd: root, timeoutSeconds: 20, sandbox: sandbox)
    XCTAssertNotEqual(outside.exitStatus, 0, "write outside the root should fail under the sandbox")
    XCTAssertFalse(FileManager.default.fileExists(atPath: escape.path),
                   "the sandbox must have prevented the out-of-root write")
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  func testSandboxBlocksWritesToProtectedCornersOfTheRoot() throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-sbx-protected-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent(".git/hooks"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let sandbox = ShellSandbox(writableRoots: [root], allowNetwork: true)

    // Ordinary work in the tree: allowed.
    let allowed = ShellRunner.runBlocking(
      "echo hi > src/a.txt", cwd: root, timeoutSeconds: 20, sandbox: sandbox)
    XCTAssertEqual(allowed.exitStatus, 0, allowed.output)

    // A git hook is code the user's next commit runs — inside the tree, still denied.
    let hook = root.appendingPathComponent(".git/hooks/pre-commit")
    let denied = ShellRunner.runBlocking(
      "echo 'curl x | sh' > .git/hooks/pre-commit", cwd: root, timeoutSeconds: 20, sandbox: sandbox)
    XCTAssertNotEqual(denied.exitStatus, 0, denied.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: hook.path), denied.output)
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  /// The protected corners must not cost the agent ordinary git work. `git init` creates
  /// `.git/hooks` and `.git/config`, so those are protected only once a repo exists — this is
  /// the case `evals/basics/07-git-commit` exercises, and it runs sandboxed by default.
  func testSandboxStillAllowsGitInitAndCommitInAFreshDirectory() throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-sbx-git-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // Built while the directory is still empty, which is what a fresh eval trial looks like.
    let sandbox = ShellSandbox(writableRoots: [root], allowNetwork: true)

    let outcome = ShellRunner.runBlocking(
      "git init -q && echo '# Demo' > README.md && git add README.md && "
        + "git -c user.name=t -c user.email=t@example.com commit -q -m 'initial commit' && "
        + "git log --format=%s",
      cwd: root, timeoutSeconds: 60, sandbox: sandbox)
    XCTAssertEqual(outcome.exitStatus, 0, outcome.output)
    XCTAssertTrue(outcome.output.contains("initial commit"), outcome.output)
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  func testSandboxBlocksReadsOfDenyReadPaths() throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    // A stand-in for ~/.ssh: a directory the sandbox is told not to read, outside the root.
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-sbx-read-\(UUID().uuidString)")
    let root = base.appendingPathComponent("project")
    let secrets = base.appendingPathComponent("secrets")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }
    let key = secrets.appendingPathComponent("id_rsa")
    try "PRIVATE KEY".write(to: key, atomically: true, encoding: .utf8)
    let sandbox = ShellSandbox(
      writableRoots: [root], allowNetwork: true, denyRead: [secrets])

    let outcome = ShellRunner.runBlocking(
      "cat \(key.path)", cwd: root, timeoutSeconds: 20, sandbox: sandbox)
    XCTAssertNotEqual(outcome.exitStatus, 0, outcome.output)
    XCTAssertFalse(outcome.output.contains("PRIVATE KEY"), outcome.output)
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  func testSymlinkedRootIsWritableThroughItsPhysicalPath() throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-sbx-link-\(UUID().uuidString)")
    let real = base.appendingPathComponent("real")
    let link = base.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
    defer { try? FileManager.default.removeItem(at: base) }

    // A project reached through a symlink: the kernel enforces on the physical path, so the
    // profile has to name it or every write in the tree is denied.
    let profile = ShellSandbox(writableRoots: [link], allowNetwork: true).profile()
    XCTAssertTrue(profile.contains(real.resolvingSymlinksInPath().path), profile)

    let outcome = ShellRunner.runBlocking(
      "echo hi > \(link.path)/a.txt", cwd: link, timeoutSeconds: 20,
      sandbox: ShellSandbox(writableRoots: [link], allowNetwork: true))
    XCTAssertEqual(outcome.exitStatus, 0, outcome.output)
    XCTAssertTrue(FileManager.default.fileExists(atPath: real.appendingPathComponent("a.txt").path))
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  func testSandboxKeepsTheRootItselfFromBeingSwapped() throws {
    #if os(macOS)
    try XCTSkipUnless(ShellSandbox.isSupported, "no sandbox-exec on this host")
    let base = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-sbx-unlink-\(UUID().uuidString)")
    let root = base.appendingPathComponent("project")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: base) }

    // Deleting the boundary and re-creating it as a symlink would point every later write
    // somewhere else, so the root directory itself is not unlinkable.
    let outcome = ShellRunner.runBlocking(
      "rm -rf \(root.path)", cwd: base, timeoutSeconds: 20,
      sandbox: ShellSandbox(writableRoots: [root], allowNetwork: true))
    XCTAssertNotEqual(outcome.exitStatus, 0, outcome.output)
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path), outcome.output)
    #else
    throw XCTSkip("sandbox-exec is macOS-only")
    #endif
  }

  func testFailsClosedWhenSandboxUnsupported() {
    #if !os(macOS)
    // On a platform with no backend, a requested sandbox refuses rather than running free.
    let sandbox = ShellSandbox(writableRoots: [URL(fileURLWithPath: "/tmp")], allowNetwork: true)
    let outcome = ShellRunner.runBlocking("echo hi", cwd: nil, timeoutSeconds: 20, sandbox: sandbox)
    XCTAssertEqual(outcome.exitStatus, 127)
    XCTAssertTrue(outcome.output.contains("sandbox"))
    #endif
  }
}
