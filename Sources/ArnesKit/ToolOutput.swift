import Foundation

// MARK: - ToolOutputLimiter

/// The one cap every tool result passes through before it enters history — bash, MCP, grep,
/// glob, skill, read_file, a subagent's report — applied once in `Session.afterToolExecuted`,
/// after the PostToolUse feedback is appended (so a chatty hook is capped too). Per-tool caps
/// (bash's bounded output collector, an MCP server's explicit `maxResultChars`) stay as inner
/// bounds on what reaches the session; this decides what reaches the *model*.
///
/// An oversized result keeps its head (60 %) and its tail (40 %) — the tail is where a failing
/// build's errors and a test runner's summary live — and, when a spill directory is set, the
/// whole text is written 0600 to `<spill>/<tool>-<callId>.txt` so the model can `read_file` the
/// middle with `offset`/`limit` instead of losing it. The pointer names the real path; without a
/// spill directory the omission is just counted.
public struct ToolOutputLimiter: Sendable, Equatable {
  /// Characters of a result that ride the context. Head and tail split 60/40 inside it; the
  /// pointer line is appended on top.
  public var maxChars: Int
  /// Where the full text of a capped result is parked (created lazily, 0700/0600). nil =
  /// truncate without spilling — what eval trials and panel candidates run with.
  public var spillDirectory: URL?

  /// The default cap: about 7–8 K tokens, enough for a long file window or a build log's
  /// ends without letting one call eat a quarter of a small model's context.
  public static let defaultMaxChars = 30_000

  /// Below this the cap is meaningless; a smaller configured value is raised to it.
  public static let minimumMaxChars = 1_000

  /// What `cap` produced.
  public struct Capped: Sendable, Equatable {
    /// The text that goes into history: unchanged, or head + pointer + tail.
    public let text: String
    /// Whether anything was cut.
    public let truncated: Bool
    /// Characters left out of `text` (0 when nothing was cut).
    public let omittedChars: Int
    /// The file holding the whole result, when one was written.
    public let spillURL: URL?
  }

  public init(maxChars: Int = ToolOutputLimiter.defaultMaxChars, spillDirectory: URL? = nil) {
    self.maxChars = max(Self.minimumMaxChars, maxChars)
    self.spillDirectory = spillDirectory
  }

  /// Caps `text` for the model. Deterministic: the same input yields the same output (the
  /// spill file for a given `tool`/`callId` is rewritten in place).
  public func cap(_ text: String, tool: String, callId: String) -> Capped {
    let total = text.count
    guard total > maxChars else {
      return Capped(text: text, truncated: false, omittedChars: 0, spillURL: nil)
    }
    let headChars = maxChars * 6 / 10
    let tailChars = maxChars - headChars
    let head = String(text.prefix(headChars))
    let tail = String(text.suffix(tailChars))
    let omitted = total - headChars - tailChars
    let spillURL = spill(text, tool: tool, callId: callId)
    let pointer: String
    if let spillURL {
      // "the tool's whole result", not "the command's whole output": bash's result is already
      // the runner's bounded head + tail, and its own `[… N bytes omitted …]` marker says so.
      pointer = "\n[… \(omitted) chars omitted; the tool's whole result is saved at \(spillURL.path) — "
        + "read_file it with offset/limit if you need the middle]\n"
    } else {
      pointer = "\n[… \(omitted) chars omitted]\n"
    }
    return Capped(text: head + pointer + tail, truncated: true, omittedChars: omitted, spillURL: spillURL)
  }

  /// Writes the whole result to the spill directory, or nil when there is none or the write
  /// failed (the caller then says "omitted" rather than pointing at a file that isn't there).
  private func spill(_ text: String, tool: String, callId: String) -> URL? {
    guard let spillDirectory else { return nil }
    let url = spillDirectory.appendingPathComponent(Self.filename(tool: tool, callId: callId))
    do {
      try SecureFiles.writePrivate(Data(text.utf8), to: url)
      return url
    } catch {
      return nil
    }
  }

  /// `<tool>-<callId>.txt`, both parts reduced to filename-safe characters and clipped — a
  /// tool name is the model's to spell (`mcp__server__tool`) and a call id the provider's.
  static func filename(tool: String, callId: String) -> String {
    func safe(_ raw: String, limit: Int) -> String {
      let mapped = raw.map { character -> Character in
        character.isLetter || character.isNumber || character == "-" || character == "_" ? character : "_"
      }
      let clipped = String(String(mapped).prefix(limit))
      return clipped.isEmpty ? "call" : clipped
    }
    return "\(safe(tool, limit: 60))-\(safe(callId, limit: 60)).txt"
  }

  /// Whether the run should leave its spill files behind (`ARNES_KEEP_TMP=1`) — for reading a
  /// tool's full output after the session, at the cost of cleaning `~/.arnes/tmp` yourself.
  public static func keepsSpillFiles(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    guard let raw = environment["ARNES_KEEP_TMP"]?.trimmingCharacters(in: .whitespaces).lowercased() else {
      return false
    }
    return ["1", "true", "yes", "on"].contains(raw)
  }
}

// MARK: - SpillScope

/// The one directory under the harness root a run's model may read: where **this** session
/// spilled its capped results — `<root>/<session id>` — and nothing beside it. The tools, and
/// the `PathScope.Rules` they classify paths with, are built before the session (and its id)
/// exist, so the carve-out is a reference shared between the two rather than a path fixed up
/// front: the session `open`s its directory here the first time it spills — never before, so
/// an empty carve-out is never open — and `close`s it at `end`. Everything else under the
/// root stays `.outside`, gated like any other path under `~/.arnes`: another session's
/// directory (a concurrent REPL in another project), a crashed run's leftovers, a `do`
/// without `--session`, files kept by `ARNES_KEEP_TMP=1` — and a read the user approved once
/// in one session can't be laundered into a free read for every other session on the machine.
///
/// Held by `Session.Configuration.spillScope` (the writer) and `PathScope.Rules.spillScope`
/// (the readers) — the CLI builds one per runtime; embedders that spill build one and hand it
/// to both. Equality is identity: two rules agree when they share the scope.
public final class SpillScope: @unchecked Sendable, Equatable {
  /// Where sessions spill (`~/.arnes/tmp` for the CLI); each writes under its own id.
  public let root: URL
  /// Whether a session's spill files outlive it (`ARNES_KEEP_TMP=1`). The carve-out closes at
  /// `end` either way — kept files are for the user to read, not for the next session's model.
  public let keepsFiles: Bool
  private let lock = NSLock()
  private var openDirectory: URL?

  public init(root: URL, keepsFiles: Bool = ToolOutputLimiter.keepsSpillFiles()) {
    self.root = root
    self.keepsFiles = keepsFiles
  }

  /// The directory currently open for reads — nil until a session has spilled something.
  public var directory: URL? {
    lock.withLock { openDirectory }
  }

  /// Opens `directory` for reads; it replaces whatever was open (one live session per scope).
  func open(_ directory: URL) {
    lock.withLock { openDirectory = directory }
  }

  /// Closes `directory` when it is the one open. A session leaving never closes a successor's
  /// (`/resume` builds the new session before the old one is ended).
  func close(_ directory: URL) {
    lock.withLock {
      if openDirectory?.standardizedFileURL.path == directory.standardizedFileURL.path {
        openDirectory = nil
      }
    }
  }

  /// Whether `resolvedPath` (already physical — see `PathScope.physicalPath`) is the open
  /// directory or lies under it. False while nothing is open.
  func contains(resolvedPath: String) -> Bool {
    guard let directory else { return false }
    let base = PathScope.physicalPath(directory.path)
    return resolvedPath == base || resolvedPath.hasPrefix(base + "/")
  }

  public static func == (lhs: SpillScope, rhs: SpillScope) -> Bool { lhs === rhs }
}
