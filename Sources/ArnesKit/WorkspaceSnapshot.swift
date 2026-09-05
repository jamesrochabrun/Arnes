import Foundation

// MARK: - WorkspaceSnapshot

/// Disposable copies of a working tree and the operations around them: take one
/// (`snapshot`), see what a run did in it (`diff`), mirror a winner back (`sync` — the
/// panel's move), or fold changes into a tree that may have moved on meanwhile (`apply` —
/// the isolated subagent's move, conflicts skipped and listed). One home for the plumbing
/// `PanelRunner` grew, shared with the task tool's `isolation: worktree` agents and the
/// `arnes agents apply` command, so the three can't drift on what "changed" means.
public enum WorkspaceSnapshot {
  /// What `apply` did and didn't do, as tree-relative paths.
  public struct ApplyReport: Sendable, Equatable {
    /// Files created or overwritten to match the snapshot.
    public var applied: [String]
    /// Files removed because the snapshot deleted them.
    public var deleted: [String]
    /// Files the destination changed since the snapshot was taken — left exactly as the
    /// destination has them, never overwritten.
    public var conflicts: [String]

    public init(applied: [String] = [], deleted: [String] = [], conflicts: [String] = []) {
      self.applied = applied
      self.deleted = deleted
      self.conflicts = conflicts
    }

    public var isEmpty: Bool { applied.isEmpty && deleted.isEmpty && conflicts.isEmpty }
  }

  public enum Error: Swift.Error, Sendable, Equatable {
    /// `cp` failed; the message is the tail of its output.
    case copyFailed(String)
  }

  // MARK: Layout

  /// The temp-directory layout an isolated subagent run gets: one directory per lead
  /// session (`arnes-agent-<lead id8>`), one per run under it, and inside that the `work`
  /// tree the agent edits plus a pristine `base` copy the diff is taken against. Not under
  /// `~/.arnes/tmp`: that is harness state, where the write floor (`PathScope.isHarness`)
  /// would refuse every nested write before the sandbox had a say.
  public struct Layout: Sendable, Equatable {
    /// `<tmp>/arnes-agent-<lead id8>/<run id8>`, symlinks resolved the way the path classifier
    /// resolves them (`PathScope.physicalPath`), so the tools, the diff and `relativeFiles`
    /// agree on one spelling.
    public let directory: URL
    /// The copy the agent works in.
    public var work: URL { directory.appendingPathComponent(Self.workName) }
    /// The untouched reference copy.
    public var base: URL { directory.appendingPathComponent(Self.baseName) }

    public init(directory: URL) {
      self.directory = Self.resolvingExistingPrefix(directory)
    }

    /// `resolvingSymlinksInPath` for a path that may not exist yet: the deepest existing
    /// ancestor is resolved and the missing tail re-appended (Foundation leaves a missing path
    /// as it is, and a `/var` temp path would then never match the `/private/var` a shell sees).
    static func resolvingExistingPrefix(_ url: URL) -> URL {
      var missing: [String] = []
      var cursor = URL(fileURLWithPath: url.path)
      while !FileManager.default.fileExists(atPath: cursor.path), cursor.path != "/" {
        missing.append(cursor.lastPathComponent)
        cursor = cursor.deletingLastPathComponent()
      }
      var resolved = cursor.resolvingSymlinksInPath()
      for component in missing.reversed() { resolved.appendPathComponent(component) }
      return URL(fileURLWithPath: resolved.path)
    }

    public static func == (lhs: Layout, rhs: Layout) -> Bool {
      lhs.directory.path == rhs.directory.path
    }

    /// The layout for one run of one lead.
    public init(leadId: String, runId: String, temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
      let lead = String(leadId.prefix(8)).lowercased().nilIfEmpty ?? "lead"
      self.init(directory: temporaryDirectory
        .appendingPathComponent("\(Self.prefix)\(lead)")
        .appendingPathComponent(String(runId.prefix(8)).lowercased()))
    }

    /// Resolves a path a user typed to a layout: the run directory itself, or its `work`
    /// (or `base`) subdirectory. nil when the path is not in the `arnes-agent-*` layout
    /// **under the temporary directory** — `apply` folds arnes snapshots into a tree, not
    /// arbitrary directories, and a repository shipping its own `arnes-agent-x/y/{work,base}`
    /// is not a snapshot arnes took.
    public static func resolve(
      _ path: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Layout?
    {
      let standardized = URL(fileURLWithPath: path.path).standardizedFileURL
      var directory = standardized
      if [workName, baseName].contains(directory.lastPathComponent) {
        directory = directory.deletingLastPathComponent()
      }
      guard directory.deletingLastPathComponent().lastPathComponent.hasPrefix(prefix) else { return nil }
      let layout = Layout(directory: directory)
      // Both sides symlink-resolved (`Layout.init` did the directory), so `/var/folders/…`
      // and `/private/var/folders/…` agree.
      let temp = resolvingExistingPrefix(temporaryDirectory).path
      let tempPrefix = temp.hasSuffix("/") ? temp : temp + "/"
      guard layout.directory.path.hasPrefix(tempPrefix) else { return nil }
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: layout.work.path, isDirectory: &isDirectory), isDirectory.boolValue,
            FileManager.default.fileExists(atPath: layout.base.path, isDirectory: &isDirectory), isDirectory.boolValue
      else { return nil }
      return layout
    }

    /// Creates the run directory and its `arnes-agent-<lead>` parent **0700** (any missing
    /// ancestor too, the way `~/.arnes` is made): a snapshot is a whole copy of the project —
    /// `.env`, tokens in the tree — and on a shared `/tmp` a default-mode directory would hand
    /// it to every local user. The `work`/`base` copies land under it.
    public func createDirectories() throws {
      try SecureFiles.ensureDirectory(directory)
    }

    /// Removes a layout nobody will apply — the run directory and, when that leaves it empty,
    /// its `arnes-agent-<lead>` parent, so a lead whose every isolated run ended in `[snapshot:
    /// no changes]` leaves no empty directory behind under the temp root. Best-effort: a
    /// removal that fails is left for the OS sweep, never an error.
    public func remove() {
      try? FileManager.default.removeItem(at: directory)
      let parent = directory.deletingLastPathComponent()
      guard parent.lastPathComponent.hasPrefix(Self.prefix),
        (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true
      else { return }
      try? FileManager.default.removeItem(at: parent)
    }

    public static let prefix = "arnes-agent-"
    static let workName = "work"
    static let baseName = "base"
  }

  // MARK: Copy / diff / sync

  /// Copies the base directory into `destination`. Uses `cp` so APFS clones make the
  /// copy near-instant on macOS; plain `cp -R` is the portable fallback (a full copy).
  public static func snapshot(of base: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let src = shellQuote(base.path)
    let dst = shellQuote(destination.path)
    let result = EvalRunner.bash(
      "cp -Rc \(src)/. \(dst)/ 2>/dev/null || cp -R \(src)/. \(dst)/",
      cwd: destination,
      timeoutSeconds: 300)
    guard result.exit == 0 else {
      throw Error.copyFailed(String(result.output.prefix(300)))
    }
  }

  /// Unified recursive diff of a candidate against the base, `.git` excluded, temp
  /// paths rewritten so a reader sees `base/…` and `candidate/…`. Empty when identical.
  ///
  /// `--no-dereference`: symlinks are compared as links, never read through. This diff runs
  /// in the harness process, outside any sandbox, and its output reaches a model and a hook
  /// payload — so a run that planted `ln -s ~/.ssh/id_rsa leak` in its copy must not have the
  /// harness paste the target's bytes into the report the kernel just refused to let it read.
  /// A link that only exists on one side is skipped (Apple diff notes it on stderr and exits
  /// 0 when nothing else differs), a retargeted link prints as one `Symbolic links … differ`
  /// line; `apply`/`relativeFiles` never followed out-of-tree links to begin with.
  public static func diff(base: URL, candidate: URL) -> String {
    let result = EvalRunner.bash(
      "diff --no-dereference -ruN -x .git \(shellQuote(base.path)) \(shellQuote(candidate.path))",
      cwd: candidate,
      timeoutSeconds: 60)
    guard result.exit != 0 else { return "" }
    return result.output
      .replacingOccurrences(of: candidate.path, with: "candidate")
      .replacingOccurrences(of: base.path, with: "base")
  }

  /// Makes `destination` mirror `source` (contents compared file by file), leaving
  /// `.git` in the destination untouched. This is how a panel winner lands in the real
  /// working directory — it deletes whatever `source` lacks, so it is for a tree nobody
  /// else touched meanwhile; `apply` is the careful variant.
  public static func sync(from source: URL, into destination: URL) throws {
    let sourceFiles = relativeFiles(under: source)
    let destinationFiles = relativeFiles(under: destination)
    let fileManager = FileManager.default

    for relative in sourceFiles {
      let from = source.appendingPathComponent(relative)
      let to = destination.appendingPathComponent(relative)
      if fileManager.fileExists(atPath: to.path) {
        guard !fileManager.contentsEqual(atPath: from.path, andPath: to.path) else { continue }
        try fileManager.removeItem(at: to)
      } else {
        try fileManager.createDirectory(
          at: to.deletingLastPathComponent(),
          withIntermediateDirectories: true)
      }
      try fileManager.copyItem(at: from, to: to)
    }
    for relative in destinationFiles.subtracting(sourceFiles) {
      try? fileManager.removeItem(at: destination.appendingPathComponent(relative))
    }
  }

  // MARK: Apply

  /// Folds what changed between `base` and `work` into `destination` — the tree the snapshot
  /// was taken from, which may have moved on since. For every file that differs between the
  /// two copies: when the destination still has `base`'s bytes (or lacks the file where `base`
  /// lacked it), it is copied or deleted to match `work`; otherwise the destination changed
  /// underneath and the file is a **conflict** — skipped and listed, never overwritten. `.git`
  /// is never read or written on any side. Deterministic: paths are handled in sorted order.
  ///
  /// - Parameter dryRun: classify only — the report says what *would* be applied, deleted and
  ///   skipped, and nothing is written (the `arnes agents apply` preview).
  public static func apply(
    from work: URL, base: URL, into destination: URL, dryRun: Bool = false) throws -> ApplyReport
  {
    let fileManager = FileManager.default
    let workFiles = relativeFiles(under: work)
    let baseFiles = relativeFiles(under: base)
    var report = ApplyReport()

    for relative in workFiles.union(baseFiles).sorted() {
      let inWork = work.appendingPathComponent(relative)
      let inBase = base.appendingPathComponent(relative)
      let target = destination.appendingPathComponent(relative)
      let workHas = workFiles.contains(relative)
      let baseHas = baseFiles.contains(relative)
      // Unchanged by the run: nothing to fold in, whatever the destination did to it.
      if workHas, baseHas, fileManager.contentsEqual(atPath: inWork.path, andPath: inBase.path) { continue }

      let targetExists = fileManager.fileExists(atPath: target.path)
      // The destination still matches what the snapshot started from?
      let untouched: Bool
      if baseHas {
        untouched = targetExists && fileManager.contentsEqual(atPath: inBase.path, andPath: target.path)
      } else {
        untouched = !targetExists
      }
      guard untouched else {
        // The one exception: the destination already has exactly what the run produced
        // (the user made the same change, or applied once already) — not a conflict.
        if workHas, targetExists, fileManager.contentsEqual(atPath: inWork.path, andPath: target.path) { continue }
        if !workHas, !targetExists { continue }
        report.conflicts.append(relative)
        continue
      }

      if workHas {
        if !dryRun {
          if targetExists { try fileManager.removeItem(at: target) }
          try fileManager.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
          try fileManager.copyItem(at: inWork, to: target)
        }
        report.applied.append(relative)
      } else {
        if !dryRun { try fileManager.removeItem(at: target) }
        report.deleted.append(relative)
      }
    }
    return report
  }

  // MARK: Helpers

  /// Relative paths of every regular file under `root` (hidden files included), with
  /// everything inside `.git` skipped.
  public static func relativeFiles(under root: URL) -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey])
    else {
      return []
    }
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    var files: Set<String> = []
    for case let url as URL in enumerator {
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(prefix) else { continue }
      let relative = String(path.dropFirst(prefix.count))
      if relative == ".git" || relative.hasPrefix(".git/") {
        enumerator.skipDescendants()
        continue
      }
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      files.insert(relative)
    }
    return files
  }

  public static func shellQuote(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }

  /// A diff clipped for a tool result: the first `maxChars` and a tail saying how much is
  /// left and where the whole snapshot is.
  static func clippedDiff(_ diff: String, maxChars: Int) -> String {
    guard diff.count > maxChars else { return diff }
    let omitted = diff.count - maxChars
    return String(diff.prefix(maxChars)) + "\n… [diff truncated, \(omitted) more chars; see the snapshot]"
  }
}
