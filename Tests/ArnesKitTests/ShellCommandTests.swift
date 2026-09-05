import XCTest
@testable import ArnesKit

final class ShellCommandTests: XCTestCase {
  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-shell-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "x".write(to: url.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    return url
  }

  func testInspectionCommandsRunFreely() throws {
    let root = try tempRoot()
    for command in [
      "git status",
      "git status --short 2>&1 | head -50; echo \"---LOG---\"; git log --oneline -10 2>&1; echo \"---DIFFSTAT---\"; git diff --stat 2>&1 | tail -20",
      "git log --oneline -5 && git diff --stat",
      "git --no-pager log -3",
      "git branch --show-current",
      "git branch -a",
      "git remote -v",
      "git stash list",
      "git config --get user.name",
      "git show HEAD --stat",
      "git rev-parse --abbrev-ref HEAD",
      "ls -la",
      "ls Sources/ArnesKit",
      "cat README.md",
      "head -20 README.md | wc -l",
      "grep -rn \"TODO\" Sources | head",
      "rg -n 'func run' Sources",
      "find . -name '*.swift' | wc -l",
      "pwd",
      "wc -l README.md",
      "diff README.md README.md",
      "test -f README.md && echo yes",
      "tree -L 2 2>/dev/null",
    ] {
      XCTAssertTrue(ShellCommand.isReadOnly(command, root: root), "expected read-only: \(command)")
    }
  }

  func testAnythingThatCouldWriteOrEscapeAsks() throws {
    let root = try tempRoot()
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
    for command in [
      "git push",
      "git commit -am x",
      "git checkout main",
      "git branch new-branch",
      "git branch -D old",
      "git tag v1",
      "git stash",
      "git stash pop",
      "git remote add origin x",
      "git config user.email x",
      "git -C /tmp log",
      "git -c core.pager=sh log",
      "git log --output=/tmp/x",
      "git --git-dir=/tmp/.git log",
      "echo hi > out.txt",
      "cat README.md >> other",
      "cat < README.md",
      "ls $HOME",
      "cat ~/.ssh/id_rsa",
      "cat /etc/passwd",
      "cat ../secret",
      "cat escape/passwd",
      "cat Sources/../../x",
      "ls `pwd`",
      "echo $(whoami)",
      "find . -name x -delete",
      #"find . -exec rm {} \;"#,
      "sort -o out.txt README.md",
      "tree -o out.txt",
      "env",
      "printenv OPENROUTER_API_KEY",
      "swift build",
      "rm -rf .build",
      "sed -i '' 's/a/b/' README.md",
      "python3 -c 'print(1)'",
      "ls & rm -rf .",
      "ls\nrm -rf .",
      "git",
      "",
      "cat README.md | tee copy",
      "xargs rm < list",
    ] {
      XCTAssertFalse(ShellCommand.isReadOnly(command, root: root), "expected a prompt: \(command)")
    }
  }

  func testBashToolUsesTheClassifier() throws {
    let root = try tempRoot()
    let bash = BashTool(root: root)
    XCTAssertEqual(bash.permission, .mutating)
    XCTAssertEqual(bash.permission(for: ["command": .string("git status")]), .readOnly)
    XCTAssertEqual(bash.permission(for: ["command": .string("cat README.md")]), .readOnly)
    // `rm` is irreversible → the louder `.sensitive` tier (see ShellCommandDangerTests).
    XCTAssertEqual(bash.permission(for: ["command": .string("rm README.md")]), .sensitive)
    XCTAssertEqual(bash.permission(for: ["command": .string("cat /etc/hosts")]), .mutating)
    XCTAssertEqual(bash.permission(for: [:]), .mutating)
  }
}
