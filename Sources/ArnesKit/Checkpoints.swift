import Foundation
import OpenRouterSwift

// MARK: - FileMutatingTool

/// A tool that changes files on disk and can be snapshotted before it does — `write_file` and
/// `edit_file`. The tool names the paths a call will touch (`mutatedPaths`) and holds the
/// checkpoint store it snapshots into (`checkpoints`, nil = no checkpointing); the session
/// finds the store through this protocol the way it finds `BackgroundWorkSource`s — by
/// conformance over its toolset, never by a tool's name or a configuration field.
public protocol FileMutatingTool: AgentTool {
  /// The absolute, root-resolved paths this call would change; empty when the arguments
  /// don't name one (the tool's own `execute` then returns an error anyway).
  func mutatedPaths(arguments: [String: JSONValue]) -> [String]
  /// Where the tool records pre-images before it writes; nil when the run keeps none.
  var checkpoints: (any CheckpointStore)? { get }
}

// MARK: - Checkpoint

/// The pre-image of one file before the first write a turn made to it. The content lives in
/// the store as a blob named by its SHA-256; the checkpoint is the pointer plus what a rewind
/// needs to decide — whether the file existed at all (a file created in the turn is *deleted*
/// by the rewind) and whether the pre-image was saved (a file over `CheckpointPolicy.maxFileBytes`
/// is recorded, reported as skipped, never restored).
public struct Checkpoint: Sendable, Equatable, Codable {
  /// The path the tool wrote — absolute, resolved against the tool's root, as the tool spelled it.
  public let path: String
  /// `path` with symlinks resolved at snapshot time. A restore recomputes it and refuses when
  /// it moved: a link planted at the path (or a re-linked parent) since the snapshot would
  /// otherwise make the harness write the pre-image somewhere the run was never allowed to.
  public let physicalPath: String
  /// SHA-256 (hex) of the pre-image bytes; nil when the file didn't exist or was over the cap.
  public let blob: String?
  /// Whether the file existed before the write.
  public let existed: Bool
  /// The pre-image's size (0 for a file that didn't exist).
  public let bytes: Int
  /// The turn (`RunRecord.turnIndex`) whose first write to `path` this pre-image precedes.
  public let turn: Int

  public init(path: String, physicalPath: String, blob: String?, existed: Bool, bytes: Int, turn: Int) {
    self.path = path
    self.physicalPath = physicalPath
    self.blob = blob
    self.existed = existed
    self.bytes = bytes
    self.turn = turn
  }

  /// Whether a rewind can act on this checkpoint: delete a file that didn't exist, or write
  /// back a saved pre-image. False only for an over-the-cap file.
  public var restorable: Bool { !existed || blob != nil }
}

// MARK: - CheckpointPolicy

/// What the checkpoint store keeps: pre-images up to `maxFileBytes` each (larger files are
/// recorded as skipped), for the most recent `maxTurns` turns that changed files.
public struct CheckpointPolicy: Sendable, Equatable {
  public var maxFileBytes: Int
  public var maxTurns: Int

  public init(maxFileBytes: Int = 5_000_000, maxTurns: Int = 100) {
    self.maxFileBytes = maxFileBytes
    self.maxTurns = maxTurns
  }

  public static let `default` = CheckpointPolicy()
}

// MARK: - CheckpointRestore

/// What a store's `rewind(toTurn:)` did to disk.
public struct CheckpointRestore: Sendable, Equatable {
  /// Files written back to their pre-image (only those whose bytes actually changed).
  public var restored: [String]
  /// Files removed because they didn't exist before the rewound turns.
  public var deleted: [String]
  /// `path — reason` for every checkpoint the rewind could not act on: an over-the-cap file
  /// whose pre-image was never saved, a path that now resolves elsewhere, a missing blob.
  public var skipped: [String]

  public init(restored: [String] = [], deleted: [String] = [], skipped: [String] = []) {
    self.restored = restored
    self.deleted = deleted
    self.skipped = skipped
  }

  public static let nothing = CheckpointRestore()

  public mutating func merge(_ other: CheckpointRestore) {
    restored += other.restored
    deleted += other.deleted
    skipped += other.skipped
  }
}

// MARK: - CheckpointStore

/// The two verbs the harness needs of a checkpoint store: a write tool snapshots a path before
/// it writes, and a session rewinds every path changed from a turn on. The turn a snapshot is
/// filed under is the store's business (`FileCheckpointStore` is told by the session it is bound
/// to), so a tool never learns the session's turn index. Reference semantics on purpose: the
/// tools and the session share one store.
public protocol CheckpointStore: AnyObject, Sendable {
  /// Records the pre-image of `path` before a write. Best-effort — nil when nothing was
  /// recorded (no session bound, an unreadable file); a write never fails because of it.
  @discardableResult
  func snapshot(path: String) async -> Checkpoint?
  /// Restores every path changed in turns `>= turn` to its earliest pre-image in that span and
  /// forgets those turns' checkpoints.
  func rewind(toTurn turn: Int) async throws -> CheckpointRestore
}

// MARK: - CheckpointError

public enum CheckpointError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The pre-image was never saved (the file was over `maxFileBytes`).
  case notRestorable(String)
  /// The path no longer resolves where it did at snapshot time (a symlink planted since, a
  /// re-linked parent) — never written through.
  case pathMoved(String)
  /// The blob the checkpoint names is gone from the store.
  case blobMissing(String)
  /// The blob's bytes don't hash to its name.
  case blobCorrupt(String)

  public var description: String {
    switch self {
    case .notRestorable(let path):
      return "\(path): pre-image not saved (over the checkpoint size cap)"
    case .pathMoved(let path):
      return "\(path): now resolves elsewhere (a symlink or re-linked directory) — not written through"
    case .blobMissing(let sha):
      return "checkpoint blob \(sha.prefix(12))… is missing from the store"
    case .blobCorrupt(let sha):
      return "checkpoint blob \(sha.prefix(12))… does not match its hash"
    }
  }
}

// MARK: - FileCheckpointStore

/// Content-addressed pre-images under `<root>/<session id>/` — `index.json` (the checkpoints)
/// beside `blobs/<sha256>` (one file per distinct content, deduped) — created 0700/0600 through
/// `SecureFiles`: a checkpoint is a copy of the user's file, so it is as private as a
/// transcript. Harness-owned: for the CLI the root is `~/.arnes/checkpoints`, under the write
/// floor no tool can cross, and `SessionStore.delete`/`prune` sweep `<root>/<id>` with the session.
///
/// Built before the session exists (the tools take it through `ToolContext`), then **bound** to
/// a session — its id names the directory, a closure says which turn a snapshot is filed
/// under — and rebound when the REPL swaps sessions (`/resume`, `/fork`). Binding loads the
/// directory's index, so a resumed session's earlier checkpoints are there to rewind to; a
/// fork inherits its parent's directory the first time it is bound. Unbound, `snapshot`
/// records nothing.
///
/// One checkpoint per (turn, path): the turn's **first** write to a path records the pre-image
/// and later writes in the same turn are no-ops, because a rewind always spans whole turns from
/// some turn to the latest, and the earliest pre-image in that span is the one to restore.
public actor FileCheckpointStore: CheckpointStore {
  public static let indexFileName = "index.json"
  public static let blobsDirectoryName = "blobs"

  /// Where every session's checkpoints live; each session writes under its own id.
  public nonisolated let root: URL
  public nonisolated let policy: CheckpointPolicy

  private var directory: URL?
  private var currentTurn: (@Sendable () async -> Int)?
  /// Insertion order = snapshot order; a rewind sorts by turn.
  private var entries: [Checkpoint] = []

  public init(root: URL, policy: CheckpointPolicy = .default) {
    self.root = root
    self.policy = policy
  }

  // MARK: Binding

  /// The session directory currently bound (`<root>/<id>`), or nil.
  public var sessionDirectory: URL? { directory }

  /// Binds the store to a session: snapshots land under `<root>/<sessionId>` and are filed under
  /// whatever `currentTurn` returns when they are taken. Loads the directory's index when there
  /// is one (a resume); when there isn't and `parent` names a session with checkpoints (a fork),
  /// the parent's directory is copied first so the fork can rewind to turns made before the
  /// branch point.
  public func bind(
    sessionId: String,
    inheritingFrom parent: String? = nil,
    currentTurn: @escaping @Sendable () async -> Int)
  {
    let target = root.appendingPathComponent(Self.safe(sessionId))
    if let parent, Self.safe(parent) != Self.safe(sessionId),
       !FileManager.default.fileExists(atPath: target.appendingPathComponent(Self.indexFileName).path)
    {
      let source = root.appendingPathComponent(Self.safe(parent))
      if FileManager.default.fileExists(atPath: source.appendingPathComponent(Self.indexFileName).path) {
        try? SecureFiles.ensureDirectory(root)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.copyItem(at: source, to: target)
      }
    }
    directory = target
    self.currentTurn = currentTurn
    entries = Self.loadIndex(at: target.appendingPathComponent(Self.indexFileName))
  }

  // MARK: Listing

  /// Every checkpoint, oldest turn first.
  public var checkpoints: [Checkpoint] { entries.sorted { $0.turn < $1.turn } }

  /// The turns that changed files, ascending.
  public var turns: [Int] { Array(Set(entries.map(\.turn))).sorted() }

  public func checkpoints(forTurn turn: Int) -> [Checkpoint] {
    entries.filter { $0.turn == turn }
  }

  /// The earliest pre-image of every path the session changed — what "what changed since the
  /// session began" diffs against.
  public func earliestPerPath() -> [Checkpoint] {
    var seen = Set<String>()
    var earliest: [Checkpoint] = []
    for checkpoint in checkpoints where seen.insert(checkpoint.path).inserted {
      earliest.append(checkpoint)
    }
    return earliest.sorted { $0.path < $1.path }
  }

  // MARK: Snapshot

  /// The `CheckpointStore` entry: files the snapshot under the bound session's current turn.
  @discardableResult
  public func snapshot(path: String) async -> Checkpoint? {
    guard directory != nil, let currentTurn else { return nil }
    let turn = await currentTurn()
    return snapshot(path: path, turn: max(0, turn))
  }

  /// Snapshots `path` under `turn`: reads the file, writes its blob when new, records the
  /// checkpoint and saves the index. The turn's first snapshot of a path wins; a later call for
  /// the same (turn, path) returns the existing checkpoint untouched. A file over
  /// `policy.maxFileBytes` is recorded with `blob: nil` (reported by a rewind, never restored).
  /// Best-effort: an unreadable file or a failed blob write records nothing and returns nil.
  @discardableResult
  public func snapshot(path: String, turn: Int) -> Checkpoint? {
    guard let directory else { return nil }
    if let existing = entries.first(where: { $0.turn == turn && $0.path == path }) {
      return existing
    }
    let physical = PathScope.physicalPath(path)
    let checkpoint: Checkpoint
    if FileManager.default.fileExists(atPath: path) {
      guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
      if data.count > policy.maxFileBytes {
        checkpoint = Checkpoint(
          path: path, physicalPath: physical, blob: nil, existed: true, bytes: data.count, turn: turn)
      } else {
        let sha = HookHash.sha256Hex(data)
        let blobURL = directory.appendingPathComponent(Self.blobsDirectoryName).appendingPathComponent(sha)
        if !FileManager.default.fileExists(atPath: blobURL.path) {
          guard (try? SecureFiles.writePrivate(data, to: blobURL)) != nil else { return nil }
        }
        checkpoint = Checkpoint(
          path: path, physicalPath: physical, blob: sha, existed: true, bytes: data.count, turn: turn)
      }
    } else {
      checkpoint = Checkpoint(path: path, physicalPath: physical, blob: nil, existed: false, bytes: 0, turn: turn)
    }
    entries.append(checkpoint)
    enforceTurnCap()
    saveIndex()
    return checkpoint
  }

  // MARK: Restore

  /// Puts `checkpoint.path` back the way it was: the saved pre-image written (atomically), or
  /// the file removed when it didn't exist. Returns whether disk changed — false when the file
  /// already had the pre-image's bytes (or was already gone). Refuses, never guesses, when the
  /// pre-image wasn't saved, the path resolves somewhere else now, or the blob is missing or
  /// corrupt.
  @discardableResult
  public func restore(_ checkpoint: Checkpoint) throws -> Bool {
    guard checkpoint.restorable else { throw CheckpointError.notRestorable(checkpoint.path) }
    // The leaf is checked as a link on its own (`physicalPath` follows a link that points back
    // into the same directory just fine); the parent chain through the physical comparison.
    if Self.isSymlink(checkpoint.path) || PathScope.physicalPath(checkpoint.path) != checkpoint.physicalPath {
      throw CheckpointError.pathMoved(checkpoint.path)
    }
    let url = URL(fileURLWithPath: checkpoint.path)
    guard checkpoint.existed else {
      guard FileManager.default.fileExists(atPath: checkpoint.path) else { return false }
      try FileManager.default.removeItem(at: url)
      return true
    }
    guard let sha = checkpoint.blob else { throw CheckpointError.notRestorable(checkpoint.path) }
    guard let data = blobData(sha) else { throw CheckpointError.blobMissing(sha) }
    guard HookHash.sha256Hex(data) == sha else { throw CheckpointError.blobCorrupt(sha) }
    if let current = try? Data(contentsOf: url), current == data { return false }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    return true
  }

  /// The `CheckpointStore` entry: for turns `>= turn`, oldest first, the first checkpoint per
  /// path wins (two edits to one file across the span restore to before the first), each is
  /// restored or deleted, an un-restorable or failing one is listed under `skipped`; then those
  /// turns' checkpoints are dropped and blobs nothing references any more are removed. Nothing
  /// happens while unbound.
  public func rewind(toTurn turn: Int) throws -> CheckpointRestore {
    guard directory != nil else { return .nothing }
    var outcome = CheckpointRestore()
    var seen = Set<String>()
    for checkpoint in checkpoints where checkpoint.turn >= turn && seen.insert(checkpoint.path).inserted {
      do {
        guard try restore(checkpoint) else { continue }
        if checkpoint.existed {
          outcome.restored.append(checkpoint.path)
        } else {
          outcome.deleted.append(checkpoint.path)
        }
      } catch let error as CheckpointError {
        outcome.skipped.append(error.description)
      } catch {
        outcome.skipped.append("\(checkpoint.path): \(error.localizedDescription)")
      }
    }
    entries.removeAll { $0.turn >= turn }
    pruneOrphanBlobs()
    saveIndex()
    return outcome
  }

  /// The bytes of a saved pre-image, by its SHA-256 (hex); nil when unbound or absent.
  public func blobData(_ sha: String) -> Data? {
    guard let directory, Self.isHex(sha) else { return nil }
    return try? Data(contentsOf: directory
      .appendingPathComponent(Self.blobsDirectoryName).appendingPathComponent(sha))
  }

  // MARK: Housekeeping

  /// Keeps the checkpoints of the newest `policy.maxTurns` turns, dropping the oldest turns'
  /// (and their now-unreferenced blobs) as new turns arrive.
  private func enforceTurnCap() {
    let distinct = turns
    guard policy.maxTurns > 0, distinct.count > policy.maxTurns else { return }
    let dropped = Set(distinct.prefix(distinct.count - policy.maxTurns))
    entries.removeAll { dropped.contains($0.turn) }
    pruneOrphanBlobs()
  }

  private func pruneOrphanBlobs() {
    guard let directory else { return }
    let blobs = directory.appendingPathComponent(Self.blobsDirectoryName)
    guard let files = try? FileManager.default.contentsOfDirectory(atPath: blobs.path) else { return }
    let referenced = Set(entries.compactMap(\.blob))
    for file in files where !referenced.contains(file) {
      try? FileManager.default.removeItem(at: blobs.appendingPathComponent(file))
    }
  }

  private func saveIndex() {
    guard let directory else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(entries) else { return }
    try? SecureFiles.writePrivate(data, to: directory.appendingPathComponent(Self.indexFileName))
  }

  private static func loadIndex(at url: URL) -> [Checkpoint] {
    guard let data = try? Data(contentsOf: url),
          let entries = try? JSONDecoder().decode([Checkpoint].self, from: data)
    else {
      return []
    }
    return entries
  }

  private static func isSymlink(_ path: String) -> Bool {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.type] as? FileAttributeType) == .typeSymbolicLink
  }

  private static func isHex(_ text: String) -> Bool {
    !text.isEmpty && text.allSatisfy(\.isHexDigit)
  }

  /// Ids are UUIDs the harness generates; sanitized so a name can't escape the root.
  static func safe(_ id: String) -> String {
    id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
  }
}

// MARK: - Rewind (Session API types)

/// Why `Session.rewind` refused.
public enum RewindError: Error, Sendable, Equatable, CustomStringConvertible {
  /// A turn is streaming; rewinding under it would cut the history it is appending to.
  case turnInFlight
  /// Background subagents are running or have reports waiting: their reports would land in a
  /// history that no longer holds the calls they answer.
  case backgroundWorkPending(count: Int)
  /// No turn with that index has started in this session.
  case noSuchTurn(Int)
  /// The turn happened, but its messages are no longer in the conversation — compacted away,
  /// or the transcript predates turn tracking — so only its file checkpoints can be rewound
  /// (`conversation: false`).
  case acrossCompaction(Int)

  public var description: String {
    switch self {
    case .turnInFlight:
      return "a turn is in flight — wait for it to finish (or Ctrl-C it) before rewinding"
    case .backgroundWorkPending(let count):
      return "\(count) background subagent(s) still pending — collect them first"
    case .noSuchTurn(let turn):
      return "no turn \(turn) in this session"
    case .acrossCompaction(let turn):
      return "turn \(turn) is no longer in the conversation (compacted away, or the transcript "
        + "predates turn tracking) — only its file checkpoints can be rewound: rewind code only"
    }
  }
}

/// What `Session.rewind` did.
public struct RewindResult: Sendable, Equatable {
  /// Files written back to their pre-image.
  public let restoredFiles: [String]
  /// Files removed (created in the rewound turns).
  public let deletedFiles: [String]
  /// `path — reason` for what could not be restored.
  public let skipped: [String]
  /// Messages dropped from the conversation (0 for a code-only rewind).
  public let removedMessages: Int

  public init(restoredFiles: [String], deletedFiles: [String], skipped: [String], removedMessages: Int) {
    self.restoredFiles = restoredFiles
    self.deletedFiles = deletedFiles
    self.skipped = skipped
    self.removedMessages = removedMessages
  }
}

// MARK: - UnifiedDiff

/// A small unified diff for the REPL's `/diff` outside a git repository: a checkpoint's
/// pre-image against the working file. Line-based, `context` lines around each change, common
/// prefix and suffix trimmed first and the middle diffed by LCS when it is small enough
/// (`dpLineLimit` lines a side); a larger middle is shown as one replacement — a valid diff,
/// not a minimal one. A display helper, not a patch tool.
public enum UnifiedDiff {
  /// Above this many changed lines a side, the middle is emitted as one delete/insert block
  /// instead of an O(n·m) alignment.
  public static let dpLineLimit = 1000

  /// The diff of `old` → `new` for `path`; `""` when they are equal. nil on either side means
  /// the file didn't exist there (`/dev/null` in the header).
  public static func diff(old: String?, new: String?, path: String, context: Int = 3) -> String {
    let ops = script(lines(old ?? ""), lines(new ?? ""))
    guard ops.contains(where: { $0.kind != .equal }) else { return "" }
    var out = [
      "--- " + (old == nil ? "/dev/null" : "a/\(path)"),
      "+++ " + (new == nil ? "/dev/null" : "b/\(path)"),
    ]
    out += hunks(ops, context: max(0, context))
    return out.joined(separator: "\n") + "\n"
  }

  // MARK: Pieces

  enum Kind { case equal, delete, insert }

  struct Op: Equatable {
    let kind: Kind
    let text: String
  }

  static func lines(_ text: String) -> [String] {
    var result = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if result.last == "" { result.removeLast() }
    return result
  }

  /// The edit script from `a` to `b`.
  static func script(_ a: [String], _ b: [String]) -> [Op] {
    var start = 0
    while start < a.count, start < b.count, a[start] == b[start] { start += 1 }
    var endA = a.count
    var endB = b.count
    while endA > start, endB > start, a[endA - 1] == b[endB - 1] {
      endA -= 1
      endB -= 1
    }
    var ops: [Op] = a[..<start].map { Op(kind: .equal, text: $0) }
    let midA = Array(a[start..<endA])
    let midB = Array(b[start..<endB])
    if midA.count <= dpLineLimit, midB.count <= dpLineLimit {
      ops += align(midA, midB)
    } else {
      ops += midA.map { Op(kind: .delete, text: $0) } + midB.map { Op(kind: .insert, text: $0) }
    }
    ops += a[endA...].map { Op(kind: .equal, text: $0) }
    return ops
  }

  /// LCS alignment of two small line arrays.
  private static func align(_ a: [String], _ b: [String]) -> [Op] {
    let n = a.count
    let m = b.count
    if n == 0 { return b.map { Op(kind: .insert, text: $0) } }
    if m == 0 { return a.map { Op(kind: .delete, text: $0) } }
    // table[i][j] = LCS length of a[i...] and b[j...], flat and row-major.
    var table = [Int32](repeating: 0, count: (n + 1) * (m + 1))
    for i in stride(from: n - 1, through: 0, by: -1) {
      for j in stride(from: m - 1, through: 0, by: -1) {
        let index = i * (m + 1) + j
        if a[i] == b[j] {
          table[index] = table[index + (m + 1) + 1] + 1
        } else {
          table[index] = max(table[index + (m + 1)], table[index + 1])
        }
      }
    }
    var ops: [Op] = []
    var i = 0
    var j = 0
    while i < n, j < m {
      if a[i] == b[j] {
        ops.append(Op(kind: .equal, text: a[i]))
        i += 1
        j += 1
      } else if table[(i + 1) * (m + 1) + j] >= table[i * (m + 1) + j + 1] {
        ops.append(Op(kind: .delete, text: a[i]))
        i += 1
      } else {
        ops.append(Op(kind: .insert, text: b[j]))
        j += 1
      }
    }
    while i < n {
      ops.append(Op(kind: .delete, text: a[i]))
      i += 1
    }
    while j < m {
      ops.append(Op(kind: .insert, text: b[j]))
      j += 1
    }
    return ops
  }

  /// Groups changes closer than `2 * context` equal lines into hunks and renders them.
  static func hunks(_ ops: [Op], context: Int) -> [String] {
    let changed = ops.indices.filter { ops[$0].kind != .equal }
    guard !changed.isEmpty else { return [] }
    // Hunk boundaries over op indices.
    var ranges: [ClosedRange<Int>] = []
    var lower = changed[0]
    var upper = changed[0]
    for index in changed.dropFirst() {
      if index - upper - 1 > 2 * context {
        ranges.append(lower...upper)
        lower = index
      }
      upper = index
    }
    ranges.append(lower...upper)

    // Old/new line numbers at the start of each op.
    var oldLine = [Int](repeating: 0, count: ops.count + 1)
    var newLine = [Int](repeating: 0, count: ops.count + 1)
    var o = 1
    var nw = 1
    for (index, op) in ops.enumerated() {
      oldLine[index] = o
      newLine[index] = nw
      if op.kind != .insert { o += 1 }
      if op.kind != .delete { nw += 1 }
    }
    oldLine[ops.count] = o
    newLine[ops.count] = nw

    var rendered: [String] = []
    for range in ranges {
      let first = max(0, range.lowerBound - context)
      let last = min(ops.count - 1, range.upperBound + context)
      let slice = ops[first...last]
      let oldCount = slice.filter { $0.kind != .insert }.count
      let newCount = slice.filter { $0.kind != .delete }.count
      let oldStart = oldCount == 0 ? oldLine[first] - 1 : oldLine[first]
      let newStart = newCount == 0 ? newLine[first] - 1 : newLine[first]
      rendered.append("@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@")
      for op in slice {
        switch op.kind {
        case .equal: rendered.append(" " + op.text)
        case .delete: rendered.append("-" + op.text)
        case .insert: rendered.append("+" + op.text)
        }
      }
    }
    return rendered
  }
}
