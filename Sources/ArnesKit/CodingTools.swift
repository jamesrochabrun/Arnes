import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - FileVersions

/// What this session has seen of each file on disk.
///
/// Two failure modes cost more than they look: a model editing from a stale buffer
/// silently reverts whatever changed underneath it (its own `bash` command, a formatter
/// hook, the user in another window), and a model calling `write_file` on a file it never
/// read destroys everything that was in it. One tracker per toolset records the version
/// `read_file` — or a write — last observed, so the write tools can refuse a never-read or
/// changed-underneath file with an error that names the fix instead of doing the damage.
/// `nil` on `ToolContext` disables the mechanism entirely.
public actor FileVersions {
  /// How a path stands relative to what the session last saw.
  public enum Status: Sendable, Equatable {
    /// Never read or written in this session.
    case unread
    /// On disk as it was last seen.
    case fresh
    /// Changed since — different size, different bytes, or a moved mtime on a file too
    /// big for the digest to cover.
    case stale
  }

  /// Bytes hashed from each end of a file. Anything up to twice this is covered
  /// completely, so a same-size rewrite is always caught; a bigger file costs two short
  /// reads instead of a full one.
  static let digestWindow = 4096

  /// A file's identity at a point in time: cheap to take, specific enough that a
  /// formatter's rewrite differs from what was read.
  struct Version: Sendable {
    var modified: Date?
    var size: Int
    var digest: UInt64
  }

  private var seen: [String: Version] = [:]

  public init() {}

  /// Records what is on disk at `path` right now — `read_file` calls it after a successful
  /// read, the write tools after they write. A path that can't be stat'ed is forgotten
  /// rather than remembered as empty.
  public func record(path: String) {
    let key = Self.key(path)
    guard let version = Self.version(of: path) else {
      seen[key] = nil
      return
    }
    seen[key] = version
  }

  /// Re-takes the version after something outside the tools touched the file — a
  /// PostToolUse formatter hook rewriting what was just edited. Without it the model's
  /// next edit to the file it just changed would look stale to it.
  public func refresh(path: String) { record(path: path) }

  /// Whether an edit to `path` would be working from what the session actually saw.
  public func check(path: String) -> Status {
    guard let recorded = seen[Self.key(path)] else { return .unread }
    guard let current = Self.version(of: path) else { return .stale }
    guard current.size == recorded.size, current.digest == recorded.digest else { return .stale }
    // Head and tail cover a small file completely, so equal bytes mean equal content and a
    // bare `touch` (new mtime, same content) is correctly ignored — the common case after a
    // formatter hook that decides there is nothing to reformat. Past that the middle is
    // unseen, so a moved mtime is treated as a change rather than assumed harmless.
    if current.size > 2 * Self.digestWindow, current.modified != recorded.modified { return .stale }
    return .fresh
  }

  /// Paths are keyed physically, so `./x.txt`, `x.txt` and the absolute spelling are one
  /// entry however the model spells them.
  static func key(_ path: String) -> String { PathScope.physicalPath(path) }

  static func version(of path: String) -> Version? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let size = (attributes[.size] as? NSNumber)?.intValue
    else {
      return nil
    }
    return Version(
      modified: attributes[.modificationDate] as? Date,
      size: size,
      digest: digest(path, size: size))
  }

  /// FNV-1a over the first and last `digestWindow` bytes.
  static func digest(_ path: String, size: Int) -> UInt64 {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    func mix(_ data: Data) {
      for byte in data { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3 }
    }
    guard let handle = FileHandle(forReadingAtPath: path) else { return hash }
    defer { try? handle.close() }
    if let head = (try? handle.read(upToCount: digestWindow)) ?? nil { mix(head) }
    if size > digestWindow {
      try? handle.seek(toOffset: UInt64(size - digestWindow))
      if let tail = (try? handle.read(upToCount: digestWindow)) ?? nil { mix(tail) }
    }
    return hash
  }
}

// MARK: - EditFileTool

/// Targeted in-place edits — the tool that makes an agent good at code without rewriting
/// whole files. Schema stays dumb: path, exact old/new strings, and one boolean — or an
/// `edits` array of the same three, applied in order and written once (T7). The result
/// carries the edited region back, so the model verifies its own change in the same call
/// instead of paying for a second one.
///
/// A multi-edit call is **one** `edit_file` call on `path` to everything that counts calls:
/// one permission prompt, one checkpoint (the turn's first write wins anyway) and one
/// `LoopGuard` edit of the file — the guard is about repeated calls, not the size of one.
public struct EditFileTool: AgentTool, FileVersionTracking, FileMutatingTool {
  public let name = "edit_file"
  public let description =
    "Replace an exact string in a file. old_string must appear exactly once — include enough surrounding "
    + "context to make it unique — unless replace_all is true, which changes every occurrence. Read the file "
    + "first: an edit to a file this session has not read, or that changed on disk since, is refused. The "
    + "result shows the edited region with line numbers, so there is no need to read the file again after. "
    + "For several changes to one file, pass edits instead of calling this tool once per change."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "path": ["type": "string"],
      "old_string": ["type": "string"],
      "new_string": ["type": "string"],
      "replace_all": [
        "type": "boolean",
        "description": "Replace every occurrence instead of requiring a unique match (default false)",
      ],
      "edits": [
        "type": "array",
        "items": [
          "type": "object",
          "properties": [
            "old_string": ["type": "string"],
            "new_string": ["type": "string"],
            "replace_all": ["type": "boolean"],
          ],
          "required": ["old_string", "new_string"],
        ],
        "description": .string(
          "Several edits to this file in one call, applied in order — each old_string is matched against "
            + "the text as the previous edits left it; nothing is written unless every edit applies"),
      ],
    ],
    "required": ["path"],
  ]

  /// Lines of context shown above and below the changed region.
  static let windowContext = 3
  /// Hard cap on the post-edit window: enough to see the change in place, never enough to
  /// re-flood the context with the file `read_file` was paged for.
  static let maxWindowLines = 40
  /// Old/new lines shown in the permission prompt, and how far each is clipped.
  static let summaryDiffLines = 4
  static let summaryLineChars = 100
  /// Most entries an `edits` array may carry in one call.
  public static let maxEdits = 100
  /// The argument that carries the multi-edit form.
  public static let editsKey = "edits"

  // MARK: Edits

  /// One replacement — the pair the single form always took, as an `edits` element.
  public struct Edit: Sendable, Equatable {
    public var oldString: String
    public var newString: String
    public var replaceAll: Bool

    public init(oldString: String, newString: String, replaceAll: Bool = false) {
      self.oldString = oldString
      self.newString = newString
      self.replaceAll = replaceAll
    }
  }

  /// What applying a list of edits produced: the final text and, in **its** coordinates, the
  /// character ranges the new text occupies (what the post-edit window is drawn around).
  public struct Applied: Sendable, Equatable {
    public var updated: String
    public var spans: [Range<Int>]
    /// Occurrences replaced, summed over every edit.
    public var replaced: Int
    public var removedBytes: Int
    public var addedBytes: Int
  }

  /// Why an edit did not apply, with its 1-based position so the error can say "edit 3 of 5".
  public struct ApplyError: Error, Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
      case empty
      case notFound
      case ambiguous(count: Int)
    }

    public var index: Int
    public var edit: Edit
    public var reason: Reason
  }

  /// The edits a call carries, in either form; nil when the arguments are malformed. The CLI's
  /// permission preview reads the arguments through this, so it and `execute` never disagree.
  public static func edits(from arguments: [String: JSONValue]) -> [Edit]? {
    if case .edits(let edits, _) = parseEdits(arguments) { return edits }
    return nil
  }

  enum ParsedEdits {
    case edits([Edit], multi: Bool)
    case refused(String)
  }

  /// `edits` present → the array (every element `{old_string, new_string, replace_all?}`, at most
  /// `maxEdits`); absent → the top-level pair. Both or neither is a coaching error.
  static func parseEdits(_ arguments: [String: JSONValue]) -> ParsedEdits {
    func present(_ key: String) -> Bool {
      guard let value = arguments[key] else { return false }
      return value != .null
    }
    let topLevel = present("old_string") || present("new_string")
    if let raw = arguments[editsKey] {
      if topLevel { return .refused("error: pass either old_string/new_string or edits, not both") }
      guard let array = raw.arrayValue else {
        return .refused("error: edits must be an array of {old_string, new_string, replace_all?} objects")
      }
      guard !array.isEmpty else {
        return .refused("error: edits is empty — pass at least one {old_string, new_string} object, "
          + "or old_string/new_string at the top level")
      }
      guard array.count <= maxEdits else {
        return .refused("error: edits has \(array.count) entries — at most \(maxEdits) per call; "
          + "split the change across several calls")
      }
      var edits: [Edit] = []
      for (offset, element) in array.enumerated() {
        guard
          let object = element.objectValue,
          let old = object["old_string"]?.stringValue,
          let new = object["new_string"]?.stringValue
        else {
          return .refused("error: edit \(offset + 1) of \(array.count) is missing old_string or new_string "
            + "— each edit is {old_string, new_string, replace_all?}")
        }
        edits.append(Edit(oldString: old, newString: new, replaceAll: object["replace_all"]?.boolValue == true))
      }
      return .edits(edits, multi: true)
    }
    guard
      let old = arguments["old_string"]?.stringValue,
      let new = arguments["new_string"]?.stringValue
    else {
      return .refused("error: missing 'old_string' and 'new_string' (or an edits array)")
    }
    return .edits([Edit(oldString: old, newString: new, replaceAll: arguments["replace_all"]?.boolValue == true)],
                  multi: false)
  }

  private let root: URL?
  private let rules: PathScope.Rules
  private let versions: FileVersions?
  private let sandbox: ShellSandbox?
  /// Where the pre-image of a file about to be edited is kept for `/rewind`; nil = none kept.
  public let checkpoints: (any CheckpointStore)?

  /// - Parameters:
  ///   - versions: what the session has read (`FileVersions`). nil disables the
  ///     unread/stale checks — an unattended runner may opt out of the extra read step.
  ///   - sandbox: the run's OS confinement. An edit writes through Foundation, never through
  ///     a shell, so the kernel never applies the profile to it — `permitsWrite` is what
  ///     keeps `edit_file` inside the same boundary `bash` runs under.
  ///   - checkpoints: the store that records the file's pre-image before the edit (the REPL's
  ///     `/rewind`); nil — every unattended runner — keeps none.
  public init(
    root: URL? = nil,
    rules: PathScope.Rules = .default,
    versions: FileVersions? = nil,
    sandbox: ShellSandbox? = nil,
    checkpoints: (any CheckpointStore)? = nil)
  {
    self.root = root
    self.rules = rules
    self.versions = versions
    self.sandbox = sandbox
    self.checkpoints = checkpoints
  }

  /// Same gate as `write_file`: routine inside the tree, `.sensitive` outside it or on a
  /// protected/credential/startup path. See `PathScope.classify(forWriting:)`.
  public func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    guard let path = arguments["path"]?.stringValue else { return .mutating }
    return PathScope.permission(forWriting: path, root: root, rules: rules)
  }

  /// Line counts plus a few lines of the actual diff: enough for the user to catch an edit
  /// aimed at the wrong text, far short of a full patch. The CLI sanitizes it before display.
  /// The multi form shows the edit count, the summed line counts, the first edit's rows and
  /// how many edits follow (the CLI's `EditPreview` renders the whole change as one diff).
  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "?"
    if arguments[Self.editsKey] != nil {
      let note = PathScope.writeNote(for: path, root: root, rules: rules)
      guard let edits = Self.edits(from: arguments), let first = edits.first else {
        return "edit_file \(path) (edits)" + note
      }
      let removed = edits.reduce(0) { $0 + Self.lineCount($1.oldString) }
      let added = edits.reduce(0) { $0 + Self.lineCount($1.newString) }
      var rows = ["edit_file \(path) (\(edits.count) edit\(edits.count == 1 ? "" : "s"), -\(removed) +\(added) lines)" + note]
      let diff = Self.miniDiff(old: first.oldString, new: first.newString)
      if !diff.isEmpty { rows.append(diff) }
      if edits.count > 1 { rows.append("  … (\(edits.count - 1) more edit\(edits.count == 2 ? "" : "s"))") }
      return rows.joined(separator: "\n")
    }
    let oldString = arguments["old_string"]?.stringValue ?? ""
    let newString = arguments["new_string"]?.stringValue ?? ""
    let everywhere = arguments["replace_all"]?.boolValue == true
    let header = "edit_file \(path) (-\(Self.lineCount(oldString)) +\(Self.lineCount(newString)) lines"
      + (everywhere ? ", all occurrences" : "") + ")"
      + PathScope.writeNote(for: path, root: root, rules: rules)
    let diff = Self.miniDiff(old: oldString, new: newString)
    return diff.isEmpty ? header : header + "\n" + diff
  }

  public func recordCurrentVersion(ofPath path: String) async {
    await versions?.record(path: resolveToolPath(path, root: root))
  }

  public func mutatedPaths(arguments: [String: JSONValue]) -> [String] {
    arguments["path"]?.stringValue.map { [resolveToolPath($0, root: root)] } ?? []
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let requested = arguments["path"]?.stringValue else {
      return "error: missing 'path'"
    }
    let edits: [Edit]
    let multi: Bool
    switch Self.parseEdits(arguments) {
    case .edits(let parsed, let isMulti):
      edits = parsed
      multi = isMulti
    case .refused(let message):
      return message
    }
    // The write-side floor: harness files are refused here, whatever the permission answer.
    if let refusal = PathScope.harnessRefusal(forWriting: requested, root: root, rules: rules) {
      return refusal
    }
    let path = resolveToolPath(requested, root: root)
    // The sandbox's in-process mirror — the kernel never sees this write, so the same lists
    // that build the SBPL profile decide it here.
    if let refusal = sandbox?.writeRefusal(path) { return refusal }
    if let offset = edits.firstIndex(where: { $0.oldString.isEmpty }) {
      return Self.applyFailureMessage(
        ApplyError(index: offset + 1, edit: edits[offset], reason: .empty),
        count: edits.count, path: path, multi: multi)
    }
    // The directory this edit was checked against, by identity: re-checked below so a
    // parent swapped while the file was being read can't redirect the write.
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    let parentIdentity = FileIdentity.of(PathScope.physicalPath(parent.path))
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return "error: cannot read \(path)"
    }
    // Editing what the model hasn't seen is how work gets silently reverted; the errors
    // name the one step that fixes it.
    if let refusal = await FileGate.refusal(for: path, versions: versions) { return refusal }
    // Every edit is applied in memory before anything is written: a failure at any of them
    // writes nothing and names the edit. Error strings coach the model toward a fix.
    let applied: Applied
    switch Self.apply(edits, to: content) {
    case .success(let result): applied = result
    case .failure(let failure):
      return Self.applyFailureMessage(failure, count: edits.count, path: path, multi: multi)
    }
    guard FileIdentity.unchanged(parent.path, since: parentIdentity) else {
      return "error: refused — \(parent.path) is not the directory it was when this edit was "
        + "checked (it was replaced or re-linked); re-read the file and try again"
    }
    // The pre-image, for `/rewind`: after every gate, right before the write (a refused edit
    // leaves no checkpoint; a second edit in the same turn finds the turn's first already kept).
    if let checkpoints { await checkpoints.snapshot(path: path) }
    do {
      try applied.updated.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
      return "error: cannot write \(path): \(error)"
    }
    await versions?.record(path: path)
    let header: String
    if multi {
      header = "edited \(path): applied \(edits.count) edit\(edits.count == 1 ? "" : "s") "
        + "(replaced \(applied.removedBytes) bytes with \(applied.addedBytes) bytes)"
    } else if applied.replaced > 1 {
      header = "edited \(path): replaced \(applied.replaced) occurrences "
        + "(\(applied.removedBytes) bytes with \(applied.addedBytes) bytes)"
    } else {
      header = "edited \(path): replaced \(applied.removedBytes) bytes with \(applied.addedBytes) bytes"
    }
    // The window is the point: the model sees its change in place and moves on instead of
    // spending a second call re-reading the file.
    let report = Self.windowReport(of: applied.updated, around: applied.spans)
    var window = report.text
    if multi, report.regionsOutside > 0 {
      window += "\n[… the window is capped at \(Self.maxWindowLines) lines; \(report.regionsOutside) edited "
        + (report.regionsOutside == 1 ? "region is" : "regions are")
        + " outside it — read_file with offset to check them]"
    }
    return window.isEmpty ? header : header + "\n" + window
  }

  /// The single form keeps its pre-T7 wording byte for byte; the multi form names the edit,
  /// says nothing was written and which earlier edits would have applied.
  static func applyFailureMessage(_ failure: ApplyError, count: Int, path: String, multi: Bool) -> String {
    guard multi else {
      switch failure.reason {
      case .empty:
        return "error: old_string is empty — use write_file to create a new file"
      case .notFound:
        return "error: old_string not found in \(path) — re-read the file and copy the exact text"
      case .ambiguous(let occurrences):
        return "error: old_string appears \(occurrences) times in \(path) — include more surrounding "
          + "context to make it unique, or pass replace_all: true to change all of them"
      }
    }
    let position = "edit \(failure.index) of \(count)"
    let earlier: String
    switch failure.index {
    case ...1: earlier = ""
    case 2: earlier = " (edit 1 would have applied)"
    default: earlier = " (edits 1–\(failure.index - 1) would have applied)"
    }
    switch failure.reason {
    case .empty:
      return "error: \(position): old_string is empty — nothing was written; every edit replaces existing "
        + "text (use write_file to create a new file)"
    case .notFound:
      return "error: \(position): old_string not found in \(path) — nothing was written; re-read the file "
        + "and copy the exact text\(earlier)"
    case .ambiguous(let occurrences):
      return "error: \(position): old_string appears \(occurrences) times in \(path) — nothing was written; "
        + "include more surrounding context or set replace_all on that edit\(earlier)"
    }
  }

  // MARK: Replacement

  /// Applies `edits` in order to `content` — each matched against the text as the previous
  /// edits left it, each unique unless it says `replaceAll` — and returns the final text with
  /// every span in **final-text coordinates**; a failure at any edit is the whole result. The
  /// span rule: when an edit replaces `[s, e)` with text `delta` characters longer, an earlier
  /// span entirely after `e` moves by `delta`, one entirely before `s` stays where it is, and
  /// one overlapping the replaced range is merged into `[min(start, s), max(end, e) + delta)`.
  /// `apply([one edit])` is exactly `replacing(_:with:in:all:)`.
  public static func apply(_ edits: [Edit], to content: String) -> Result<Applied, ApplyError> {
    var current = content
    var spans: [Range<Int>] = []
    var replaced = 0, removedBytes = 0, addedBytes = 0
    for (offset, edit) in edits.enumerated() {
      let index = offset + 1
      guard !edit.oldString.isEmpty else {
        return .failure(ApplyError(index: index, edit: edit, reason: .empty))
      }
      let occurrences = current.components(separatedBy: edit.oldString).count - 1
      if occurrences == 0 {
        return .failure(ApplyError(index: index, edit: edit, reason: .notFound))
      }
      if occurrences > 1, !edit.replaceAll {
        return .failure(ApplyError(index: index, edit: edit, reason: .ambiguous(count: occurrences)))
      }
      let (updated, sites) = replacementSites(edit.oldString, with: edit.newString, in: current, all: edit.replaceAll)
      spans = merged(shifted(spans, through: sites) + sites.map(\.new))
      replaced += sites.count
      removedBytes += edit.oldString.utf8.count * sites.count
      addedBytes += edit.newString.utf8.count * sites.count
      current = updated
    }
    return .success(Applied(
      updated: current, spans: spans, replaced: replaced, removedBytes: removedBytes, addedBytes: addedBytes))
  }

  /// The updated text plus the character ranges the new text now occupies — what the
  /// post-edit window is drawn around.
  static func replacing(
    _ oldString: String,
    with newString: String,
    in content: String,
    all: Bool)
    -> (updated: String, spans: [Range<Int>])
  {
    let (updated, sites) = replacementSites(oldString, with: newString, in: content, all: all)
    return (updated, sites.map(\.new))
  }

  /// One replacement inside a single edit: where the old text sat (in the pre-edit text's
  /// coordinates) and where the new text sits (in the updated text's).
  struct Site: Equatable {
    var old: Range<Int>
    var new: Range<Int>
    var delta: Int { new.count - old.count }
  }

  static func replacementSites(
    _ oldString: String,
    with newString: String,
    in content: String,
    all: Bool)
    -> (updated: String, sites: [Site])
  {
    var updated = ""
    var sites: [Site] = []
    var cursor = 0 // characters written so far, so spans cost no re-counting
    var consumed = 0 // characters of `content` consumed so far
    var searchStart = content.startIndex
    while let found = content.range(of: oldString, range: searchStart..<content.endIndex) {
      let gap = content.distance(from: searchStart, to: found.lowerBound)
      updated += content[searchStart..<found.lowerBound]
      cursor += gap
      consumed += gap
      let oldStart = consumed
      consumed += content.distance(from: found.lowerBound, to: found.upperBound)
      let newStart = cursor
      updated += newString
      cursor += newString.count
      sites.append(Site(old: oldStart..<consumed, new: newStart..<cursor))
      searchStart = found.upperBound
      if !all { break }
    }
    updated += content[searchStart...]
    return (updated, sites)
  }

  /// Earlier spans carried through one edit's replacements: a position maps to itself plus
  /// the deltas of every site ending at or before it, and a span some site overlaps becomes
  /// the hull of the span and every site overlapping it before the mapping.
  static func shifted(_ spans: [Range<Int>], through sites: [Site]) -> [Range<Int>] {
    guard !sites.isEmpty else { return spans }
    func mapped(_ position: Int) -> Int {
      position + sites.reduce(0) { $0 + ($1.old.upperBound <= position ? $1.delta : 0) }
    }
    return spans.map { span in
      var start = span.lowerBound, end = span.upperBound
      for site in sites where site.old.lowerBound < span.upperBound && site.old.upperBound > span.lowerBound {
        start = min(start, site.old.lowerBound)
        end = max(end, site.old.upperBound)
      }
      return mapped(start)..<mapped(end)
    }
  }

  /// Sorted, with strictly overlapping spans folded into one (touching spans stay apart, so a
  /// single edit's spans come back exactly as `replacementSites` produced them).
  static func merged(_ spans: [Range<Int>]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    for span in spans.sorted(by: { ($0.lowerBound, $0.upperBound) < ($1.lowerBound, $1.upperBound) }) {
      if let last = result.last, span.lowerBound < last.upperBound {
        result[result.count - 1] = last.lowerBound..<max(last.upperBound, span.upperBound)
      } else {
        result.append(span)
      }
    }
    return result
  }

  // MARK: Post-edit window

  /// A line-numbered slice of `content` covering every changed range with `windowContext`
  /// lines around it, capped at `maxWindowLines`. Numbering matches `read_file`.
  static func window(of content: String, around spans: [Range<Int>]) -> String {
    windowReport(of: content, around: spans).text
  }

  /// `window(of:around:)` plus how many spans start past the cap — what the multi form tells
  /// the model it did not get to see.
  static func windowReport(of content: String, around spans: [Range<Int>]) -> (text: String, regionsOutside: Int) {
    guard let first = spans.first, let last = spans.last else { return ("", 0) }
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var lineStarts: [Int] = []
    lineStarts.reserveCapacity(lines.count)
    var offset = 0
    for line in lines {
      lineStarts.append(offset)
      offset += line.count + 1
    }
    func lineIndex(of characterOffset: Int) -> Int {
      var low = 0, high = lineStarts.count - 1, found = 0
      while low <= high {
        let mid = (low + high) / 2
        if lineStarts[mid] <= characterOffset {
          found = mid
          low = mid + 1
        } else {
          high = mid - 1
        }
      }
      return found
    }
    // A replacement ending exactly on a line break belongs to the line before it.
    let lastOffset = max(last.lowerBound, last.upperBound - 1)
    let start = max(0, lineIndex(of: first.lowerBound) - windowContext)
    var end = min(lines.count - 1, lineIndex(of: lastOffset) + windowContext)
    var clipped = false
    if end - start + 1 > maxWindowLines {
      end = start + maxWindowLines - 1
      clipped = true
    }
    var body = (start...end).map { "\($0 + 1)\t\(lines[$0])" }.joined(separator: "\n")
    if clipped {
      body += "\n… window clipped to \(maxWindowLines) lines "
        + "(read_file with offset \(end + 2) for the rest of the change)"
    }
    let outside = clipped ? spans.filter { lineIndex(of: $0.lowerBound) > end }.count : 0
    return (body, outside)
  }

  // MARK: Summary diff

  /// Lines in a replacement side; a single trailing newline isn't an extra line.
  static func lines(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    if lines.count > 1, lines.last == "" { lines.removeLast() }
    return lines
  }

  static func lineCount(_ text: String) -> Int { lines(text).count }

  /// Up to `summaryDiffLines` `- old` / `+ new` rows, two per side by default with the
  /// spare going to whichever side has more to show (so a pure deletion shows four).
  static func miniDiff(old: String, new: String) -> String {
    let oldLines = lines(old), newLines = lines(new)
    let even = summaryDiffLines / 2
    var oldBudget = min(oldLines.count, even)
    var newBudget = min(newLines.count, even)
    var spare = summaryDiffLines - oldBudget - newBudget
    if spare > 0 {
      let extra = min(spare, oldLines.count - oldBudget)
      oldBudget += extra
      spare -= extra
    }
    if spare > 0 { newBudget += min(spare, newLines.count - newBudget) }
    func rows(_ all: [String], budget: Int, marker: String) -> [String] {
      var rows = all.prefix(budget).map { line -> String in
        let clipped = line.count > summaryLineChars
          ? String(line.prefix(summaryLineChars)) + "…"
          : line
        return "  \(marker) \(clipped)"
      }
      if all.count > budget, !rows.isEmpty { rows[rows.count - 1] += " …" }
      return rows
    }
    return (rows(oldLines, budget: oldBudget, marker: "-")
      + rows(newLines, budget: newBudget, marker: "+")).joined(separator: "\n")
  }
}

// MARK: - FileGate

/// The unread/stale refusals `edit_file` and `write_file` share, so both spell them the
/// same way and both name the one step that fixes it.
enum FileGate {
  /// nil when the file may be changed: no tracker, or the session has seen this version.
  static func refusal(
    for path: String,
    versions: FileVersions?,
    overwriting: Bool = false)
    async -> String?
  {
    guard let versions else { return nil }
    let hint = overwriting ? "; use edit_file for a targeted change" : ""
    switch await versions.check(path: path) {
    case .fresh:
      return nil
    case .unread:
      return "error: \(path) has not been read this session — read_file it (or the relevant "
        + "window) before editing\(hint)"
    case .stale:
      return "error: \(path) changed on disk since you read it — re-read the region you are "
        + "changing\(hint)"
    }
  }
}

// MARK: - GrepTool

// MARK: - FileWalker

/// The directory walk grep and glob share. Hidden files are *included* — `.github/workflows`,
/// `.gitignore` and `.env.example` are exactly what a coding agent needs to find — while
/// version-control internals, build products and dependency trees are skipped, along with
/// whatever the search root's `.gitignore` names (simple patterns only, negations ignored:
/// recall-first, so a search never silently misses a file over a pattern subtlety).
enum FileWalker {
  /// Directory names never descended into, wherever they appear.
  static let ignoredDirectoryNames: Set<String> = [
    ".git", ".hg", ".svn", ".build", "node_modules", ".swiftpm", "DerivedData", "target",
    "dist", "__pycache__", ".venv", "venv", ".tox", ".mypy_cache",
  ]
  /// Root-relative directories never descended into (scratch space the harness itself writes).
  static let ignoredRelativeDirectories: Set<String> = [".arnes/tmp"]
  /// Files visited at most; a monorepo search that hits this is told to narrow.
  static let maxFiles = 20_000

  struct Listing {
    /// Absolute paths of regular files, in a stable (sorted) order.
    var files: [String]
    /// The walk stopped at `maxFiles` — the listing is incomplete.
    var hitCap: Bool
  }

  /// Ignore patterns from one `.gitignore`: `fnmatch` against the root-relative path and the
  /// basename. `!` negations, `**` semantics beyond what fnmatch gives, and nested
  /// `.gitignore` files are deliberately not modeled.
  struct IgnoreRules {
    var patterns: [String] = []

    static func load(root: URL) -> IgnoreRules {
      guard let text = try? String(contentsOf: root.appendingPathComponent(".gitignore"), encoding: .utf8) else {
        return IgnoreRules()
      }
      var patterns: [String] = []
      for raw in text.split(separator: "\n") {
        var line = raw.trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix("!") else { continue }
        if line.hasSuffix("/") { line.removeLast() }
        if line.hasPrefix("/") { line.removeFirst() }
        if !line.isEmpty { patterns.append(line) }
      }
      return IgnoreRules(patterns: patterns)
    }

    func skips(relativePath: String, basename: String) -> Bool {
      patterns.contains { fnmatch($0, relativePath, 0) == 0 || fnmatch($0, basename, 0) == 0 }
    }
  }

  /// Regular files under `root` (or `root` itself when it is a file).
  static func files(under root: String) -> Listing {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
      return Listing(files: [], hitCap: false)
    }
    guard isDirectory.boolValue else {
      return Listing(files: [root], hitCap: false)
    }
    let ignore = IgnoreRules.load(root: URL(fileURLWithPath: root))
    // The path-based enumerator yields root-relative paths as given, so results are spelled
    // the way the caller spelled the root (no surprise `/private` prefixes from symlink
    // resolution) and the relative form costs nothing.
    guard let enumerator = FileManager.default.enumerator(atPath: root) else {
      return Listing(files: [], hitCap: false)
    }
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var files: [String] = []
    var hitCap = false
    while let entry = enumerator.nextObject() as? String {
      let basename = (entry as NSString).lastPathComponent
      let type = enumerator.fileAttributes?[.type] as? FileAttributeType
      if type == .typeDirectory {
        if ignoredDirectoryNames.contains(basename)
          || ignoredRelativeDirectories.contains(entry)
          || ignore.skips(relativePath: entry, basename: basename)
        {
          enumerator.skipDescendants()
        }
        continue
      }
      guard type == .typeRegular else { continue }
      if ignore.skips(relativePath: entry, basename: basename) { continue }
      files.append(prefix + entry)
      if files.count >= maxFiles {
        hitCap = true
        break
      }
    }
    return Listing(files: files.sorted(), hitCap: hitCap)
  }

  static func relativePath(_ file: String, under root: String) -> String {
    let prefix = root.hasSuffix("/") ? root : root + "/"
    return file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
  }

  /// Drops files the config's `paths.denyRead` names. Gating the *search root* isn't enough
  /// for a recursive tool: a grep over the project would otherwise print the contents of the
  /// `.env` the user asked never to be read freely.
  static func excludingDeniedReads(_ files: [String], rules: PathScope.Rules, root: URL?) -> [String] {
    guard !rules.policy.denyRead.isEmpty else { return files }
    return files.filter { !PathScope.matchesAnyGlob(rules.policy.denyRead, path: $0, root: root) }
  }
}

// MARK: - GrepTool

/// Recursive regex search. Pure Swift (no shelling out) is what lets this be honestly
/// `.readOnly` and run without a permission prompt.
public struct GrepTool: AgentTool, PathGatedReadTool {
  public let name = "grep"
  public let description =
    "Search files recursively for a regex pattern. Returns path:line:text matches (hidden files included; "
    + ".git, build and dependency directories skipped). Optional path defaults to the current directory; "
    + "glob narrows to matching file names; context adds surrounding lines; files_only lists matching files with counts."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "pattern": ["type": "string", "description": "Regular expression"],
      "path": ["type": "string", "description": "File or directory to search (default: .)"],
      "glob": ["type": "string", "description": "Only search files whose name matches, e.g. *.swift"],
      "case_insensitive": ["type": "boolean", "description": "Ignore case (default false)"],
      "context": ["type": "integer", "description": "Lines of context before and after each match (0-5)"],
      "files_only": ["type": "boolean", "description": "List matching files with match counts instead of lines"],
    ],
    "required": ["pattern"],
  ]

  static let maxMatches = 200
  static let maxContext = 5
  static let maxLineChars = 300
  /// Room for `maxMatches` lines with real-world path lengths before the character bound kicks in.
  private static let maxOutputChars = 24_000
  private static let maxFileBytes = 2_000_000

  private let toolRoot: URL?
  private let rules: PathScope.Rules

  public init(root: URL? = nil, rules: PathScope.Rules = .default) {
    toolRoot = root
    self.rules = rules
  }

  /// Free inside the working directory; asked about when the search root is outside it.
  public func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    PathScope.permission(forReading: arguments["path"]?.stringValue ?? ".", root: toolRoot, rules: rules)
  }

  public func outsideReadPath(arguments: [String: JSONValue]) -> String? {
    PathScope.outsideReadPath(arguments["path"]?.stringValue ?? ".", root: toolRoot, rules: rules)
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "."
    return "grep /\(arguments["pattern"]?.stringValue ?? "?")/ in \(path)\(PathScope.note(for: path, root: toolRoot, rules: rules))"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let pattern = arguments["pattern"]?.stringValue else {
      return "error: missing 'pattern'"
    }
    let root = resolveToolPath(arguments["path"]?.stringValue ?? ".", root: toolRoot)
    let caseInsensitive = arguments["case_insensitive"]?.boolValue ?? false
    let filesOnly = arguments["files_only"]?.boolValue ?? false
    let nameGlob = arguments["glob"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    let context = min(max(arguments["context"]?.intValue ?? 0, 0), Self.maxContext)
    let regex: NSRegularExpression
    do {
      regex = try NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : [])
    } catch {
      return "error: invalid regex: \(error.localizedDescription)"
    }

    let listing = FileWalker.files(under: root)
    let files = FileWalker.excludingDeniedReads(listing.files, rules: rules, root: toolRoot)
    var lines: [String] = []
    var fileCounts: [(file: String, count: Int)] = []
    var matchCount = 0
    var truncated = false

    scan: for file in files {
      if let nameGlob {
        let relative = FileWalker.relativePath(file, under: root)
        let basename = (file as NSString).lastPathComponent
        guard fnmatch(nameGlob, basename, 0) == 0 || fnmatch(nameGlob, relative, 0) == 0 else { continue }
      }
      guard
        let data = FileManager.default.contents(atPath: file),
        data.count <= Self.maxFileBytes,
        !data.prefix(1024).contains(0),
        let content = String(data: data, encoding: .utf8)
      else {
        continue
      }
      let fileLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
      var hits: [Int] = []
      for (index, text) in fileLines.enumerated() {
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else { continue }
        hits.append(index)
        matchCount += 1
        if matchCount >= Self.maxMatches {
          truncated = true
          break
        }
      }
      guard !hits.isEmpty else {
        if truncated { break scan }
        continue
      }
      if filesOnly {
        fileCounts.append((file, hits.count))
      } else {
        lines.append(contentsOf: Self.render(file: file, lines: fileLines, hits: hits, context: context))
      }
      if truncated { break scan }
    }

    if filesOnly {
      guard !fileCounts.isEmpty else { return "no matches for /\(pattern)/ under \(root)" }
      lines = fileCounts.map { "\($0.file) (\($0.count))" }
    }
    guard !lines.isEmpty else {
      return "no matches for /\(pattern)/ under \(root)" + (listing.hitCap ? Self.capNote : "")
    }
    var output = lines.joined(separator: "\n")
    if output.count > Self.maxOutputChars {
      output = String(output.prefix(Self.maxOutputChars))
      truncated = true
    }
    if truncated {
      output += "\n[\(Self.maxMatches) matches shown — refine the pattern, add glob, or narrow path]"
    }
    if listing.hitCap { output += Self.capNote }
    return output
  }

  static let capNote = "\n[stopped after \(FileWalker.maxFiles) files — narrow with path]"

  /// ripgrep-style rendering: `path:line:text` for matches, `path-line-text` for context,
  /// `--` between non-contiguous groups.
  static func render(file: String, lines: [String], hits: [Int], context: Int) -> [String] {
    func clip(_ text: String) -> String {
      text.count > maxLineChars ? String(text.prefix(maxLineChars)) + "…" : text
    }
    guard context > 0 else {
      return hits.map { "\(file):\($0 + 1):\(clip(lines[$0]))" }
    }
    let hitSet = Set(hits)
    var output: [String] = []
    var lastPrinted = -1
    for hit in hits {
      let start = max(hit - context, 0)
      let end = min(hit + context, lines.count - 1)
      if lastPrinted >= 0, start > lastPrinted + 1 { output.append("--") }
      // Two hits within `context` lines of the end of the file share one window: the first
      // hit's window already reached the last line, so for the second `first` is past `end`
      // — a `first...end` range over it traps (batch 14: a model's `context: 3` grep killed
      // a whole eval run this way), so the empty window is skipped rather than formed.
      let first = max(start, lastPrinted + 1)
      if first <= end {
        for index in first...end {
          let separator = hitSet.contains(index) ? ":" : "-"
          output.append("\(file)\(separator)\(index + 1)\(separator)\(clip(lines[index]))")
        }
      }
      lastPrinted = max(lastPrinted, end)
    }
    return output
  }
}

// MARK: - GlobTool

/// File discovery by pattern. Matches the relative path (where `*` crosses directory
/// separators, so `*.swift` finds nested files) and the basename; newest files first, the
/// way a "what was I just working on" search wants them.
public struct GlobTool: AgentTool, PathGatedReadTool {
  public let name = "glob"
  public let description =
    "List files matching a glob pattern like *.swift or Sources/*/main.swift, newest first (hidden files "
    + "included; .git, build and dependency directories skipped). Optional path defaults to the current directory."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "pattern": ["type": "string", "description": "Glob pattern"],
      "path": ["type": "string", "description": "Directory to search (default: .)"],
    ],
    "required": ["pattern"],
  ]

  static let maxResults = 500

  private let toolRoot: URL?
  private let rules: PathScope.Rules

  public init(root: URL? = nil, rules: PathScope.Rules = .default) {
    toolRoot = root
    self.rules = rules
  }

  /// Free inside the working directory; asked about when the search root is outside it.
  public func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    PathScope.permission(forReading: arguments["path"]?.stringValue ?? ".", root: toolRoot, rules: rules)
  }

  public func outsideReadPath(arguments: [String: JSONValue]) -> String? {
    PathScope.outsideReadPath(arguments["path"]?.stringValue ?? ".", root: toolRoot, rules: rules)
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "."
    return "glob \(arguments["pattern"]?.stringValue ?? "?") in \(path)\(PathScope.note(for: path, root: toolRoot, rules: rules))"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let pattern = arguments["pattern"]?.stringValue else {
      return "error: missing 'pattern'"
    }
    let root = resolveToolPath(arguments["path"]?.stringValue ?? ".", root: toolRoot)
    let listing = FileWalker.files(under: root)
    var matched: [(relative: String, modified: Date)] = []
    for file in FileWalker.excludingDeniedReads(listing.files, rules: rules, root: toolRoot) {
      let relative = FileWalker.relativePath(file, under: root)
      let basename = (relative as NSString).lastPathComponent
      guard fnmatch(pattern, relative, 0) == 0 || fnmatch(pattern, basename, 0) == 0 else { continue }
      // Stat only what matched — the mtime sort shouldn't cost a stat per file in the tree.
      let modified = (try? FileManager.default.attributesOfItem(atPath: file)[.modificationDate] as? Date)
        ?? .distantPast
      matched.append((relative, modified))
    }
    guard !matched.isEmpty else {
      return "no files matching \(pattern) under \(root)" + (listing.hitCap ? GrepTool.capNote : "")
    }
    matched.sort {
      if $0.modified != $1.modified { return $0.modified > $1.modified }
      return $0.relative < $1.relative
    }
    var output = matched.prefix(Self.maxResults).map(\.relative).joined(separator: "\n")
    if matched.count > Self.maxResults {
      output += "\n[\(Self.maxResults) of \(matched.count) shown, newest first — narrow the pattern or path]"
    }
    if listing.hitCap { output += GrepTool.capNote }
    return output
  }
}
