import Foundation
import OpenRouterSwift

// MARK: - TranscriptEntry

/// One line of a persisted session transcript (`~/.arnes/sessions/<id>.jsonl`).
///
/// This local Codable type exists because OpenRouterSwift's `Message` is (correctly)
/// `Encodable`-only — request types don't decode. Text-plus-tool-calls covers everything
/// Arnes produces today; if multimodal fidelity is ever needed the upstream fix is adding
/// `Decodable` to `Message`/`ContentPart` in OpenRouterSwift (invariant 5), with
/// `TranscriptEntry` remaining the stable on-disk type either way.
public struct TranscriptEntry: Codable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case meta
    case message
    case modelChange = "model_change"
    case cost
    case clear
    /// Older history was summarized; `text` holds the summary. The kept messages are
    /// re-appended after this entry, so replay is: reset, carry the summary forward.
    case compaction
    /// The reasoning-effort dial changed; `text` holds the level. Replayed into
    /// `LoadedSession.reasoningEffort` so a resumed session keeps the compute knob.
    case effortChange = "effort_change"
    /// `Session.rewind`: the conversation was cut back to the start of turn `turn`, keeping the
    /// first `keepMessages` messages (nil for a code-only rewind — nothing to replay), and the
    /// files in `restoredPaths` were put back. Append-only like everything else: replay
    /// truncates to `keepMessages`, so a resumed session is what the user rewound to. The
    /// checkpoints themselves live beside the transcript (`checkpoints/<id>/`), never in it.
    case rewind
  }

  public var type: Kind
  // meta
  public var id: String?
  public var createdAt: Date?
  public var name: String?
  public var cwd: String?
  /// Set on a fork's own meta line: the transcript this one was copied from.
  public var forkedFrom: String?
  /// Lineage, on a nested (subagent) session's first meta line: the lead session that
  /// delegated (`parent`), the agent that ran (`agent`), how deep the delegation nests
  /// (`depth`, 1 for a subagent of the lead), and how the session came to be (`origin`:
  /// `interactive`, `do`, `subagent`). All nil on a lead session's meta and on files written
  /// before the fields existed.
  public var parent: String?
  public var agent: String?
  public var depth: Int?
  public var origin: String?
  // message
  public var role: String?
  public var text: String?
  public var toolCallId: String?
  public var toolCalls: [ToolCall]?
  /// An assistant message's replayable reasoning state (`Message.reasoningDetails`: signed
  /// thinking blocks, encrypted reasoning), carried so a resumed session's next request can
  /// replay it. nil on every other line and on transcripts written before the field.
  public var reasoningDetails: [JSONValue]?
  /// The turn (`RunRecord.turnIndex`) a message was written in, so a replayed session knows
  /// where each turn began (`LoadedSession.turnStarts`). nil on non-message lines and on
  /// transcripts written before the field. On a `rewind` line: the turn rewound to.
  public var turn: Int?
  // rewind
  /// How many messages the conversation kept (`rewind` lines only; nil = the files were
  /// restored but the conversation was left alone).
  public var keepMessages: Int?
  /// The files a rewind restored or removed (`rewind` lines only).
  public var restoredPaths: [String]?
  // meta + model_change
  public var model: String?
  // cost
  public var turnUSD: Double?
  public var sessionUSD: Double?

  enum CodingKeys: String, CodingKey {
    case type
    case id
    case createdAt
    case name
    case cwd
    case forkedFrom
    case parent
    case agent
    case depth
    case origin
    case role
    case text
    case toolCallId
    case toolCalls
    case reasoningDetails
    case turn
    case keepMessages
    case restoredPaths
    case model
    case turnUSD
    case sessionUSD
  }

  /// The first line of a transcript. The lineage fields are written by a nested session
  /// (`parent`, `agent`, `depth`) and by any session that knows how it was started
  /// (`origin`); every existing caller's meta line is unchanged.
  public static func meta(
    id: String, model: String, cwd: String?, name: String? = nil,
    parent: String? = nil, agent: String? = nil, depth: Int? = nil, origin: String? = nil)
    -> TranscriptEntry
  {
    var entry = TranscriptEntry(type: .meta)
    entry.id = id
    entry.createdAt = Date()
    entry.model = model
    entry.cwd = cwd
    entry.name = name
    entry.parent = parent
    entry.agent = agent
    entry.depth = depth
    entry.origin = origin
    return entry
  }

  public static func modelChange(_ model: String) -> TranscriptEntry {
    var entry = TranscriptEntry(type: .modelChange)
    entry.model = model
    return entry
  }

  public static func cost(turnUSD: Double, sessionUSD: Double) -> TranscriptEntry {
    var entry = TranscriptEntry(type: .cost)
    entry.turnUSD = turnUSD
    entry.sessionUSD = sessionUSD
    return entry
  }

  public static func clear() -> TranscriptEntry {
    TranscriptEntry(type: .clear)
  }

  public static func compaction(summary: String) -> TranscriptEntry {
    var entry = TranscriptEntry(type: .compaction)
    entry.text = summary
    return entry
  }

  /// The reasoning-effort dial as it stands after a change (`text` is the raw level, or
  /// `effortOffLevel` when the dial was switched off — `Session.setReasoningEffort(nil)` — so a
  /// resume knows "off" from "never set"; an older reader leaves the dial as it was on that line).
  /// The parameter is optional: a literal `.none` is `Optional.none` and writes `off`, not the
  /// `none` level — spell that one `Reasoning.Effort.none`.
  public static func effortChange(_ effort: Reasoning.Effort?) -> TranscriptEntry {
    var entry = TranscriptEntry(type: .effortChange)
    entry.text = effort?.rawValue ?? effortOffLevel
    return entry
  }

  /// The `effort_change` level that means "no dial": requests go out without a reasoning field.
  public static let effortOffLevel = "off"

  /// A rewind to the start of `turn`: `keepMessages` messages kept (nil when only files were
  /// restored), `restoredPaths` put back on disk.
  public static func rewind(toTurn turn: Int, keepMessages: Int?, restoredPaths: [String]) -> TranscriptEntry {
    var entry = TranscriptEntry(type: .rewind)
    entry.turn = turn
    entry.keepMessages = keepMessages
    entry.restoredPaths = restoredPaths.isEmpty ? nil : restoredPaths
    return entry
  }

  public init(type: Kind) {
    self.type = type
  }

  public init(message: Message, turn: Int? = nil) {
    type = .message
    role = message.role.rawValue
    text = message.content?.plainText
    toolCallId = message.toolCallId
    toolCalls = message.toolCalls
    reasoningDetails = message.reasoningDetails
    self.turn = turn
  }

  /// Rebuilds the wire message; nil for non-message entries.
  public func toMessage() -> Message? {
    guard type == .message, let role, let messageRole = Message.Role(rawValue: role) else {
      return nil
    }
    return Message(
      role: messageRole,
      content: text.map { .text($0) },
      toolCallId: toolCallId,
      toolCalls: toolCalls,
      reasoningDetails: reasoningDetails)
  }
}

extension Message.Content {
  /// The plain-text rendering of this content (text parts joined; non-text parts dropped).
  var plainText: String {
    switch self {
    case .text(let text):
      return text
    case .parts(let parts):
      return parts.compactMap { part in
        if case .text(let text, _) = part { return text }
        return nil
      }
      .joined(separator: "\n")
    }
  }
}

// MARK: - SessionMeta / LoadedSession

/// Summary row for `arnes sessions` and resume pickers.
public struct SessionMeta: Sendable, Equatable {
  public let id: String
  public let createdAt: Date?
  public let name: String?
  public let model: String?
  /// The session this one was forked from, when it was (`arnes resume --fork`, `/fork`).
  public let forkedFrom: String?
  /// The working directory the session was started in (its first meta line). Set by
  /// `load(id:)`; a `list()` row read from the index leaves it nil.
  public let cwd: String?
  public let updatedAt: Date
  public let messageCount: Int
  /// Lineage of a nested (subagent) session: the lead session that delegated, the agent
  /// that ran, the nesting depth (1 = a subagent of the lead) and how the session was
  /// started (`interactive` / `do` / `subagent`). nil on a lead session and on transcripts
  /// written before the fields existed.
  public let parent: String?
  public let agent: String?
  public let depth: Int?
  public let origin: String?

  public init(
    id: String,
    createdAt: Date? = nil,
    name: String? = nil,
    model: String? = nil,
    forkedFrom: String? = nil,
    cwd: String? = nil,
    updatedAt: Date,
    messageCount: Int,
    parent: String? = nil,
    agent: String? = nil,
    depth: Int? = nil,
    origin: String? = nil)
  {
    self.id = id
    self.createdAt = createdAt
    self.name = name
    self.model = model
    self.forkedFrom = forkedFrom
    self.cwd = cwd
    self.updatedAt = updatedAt
    self.messageCount = messageCount
    self.parent = parent
    self.agent = agent
    self.depth = depth
    self.origin = origin
  }

  /// Whether this transcript is a subagent's (a `parent` on its meta line).
  public var isSubagent: Bool { parent != nil }
}

/// What a session query resolved to against a list of sessions: exactly one, none, or several
/// (an id prefix shared by more than one transcript). Pure — the CLI and the task tool turn
/// the cases into their own messages.
public enum SessionMatch: Sendable, Equatable {
  case found(SessionMeta)
  case none
  case ambiguous([SessionMeta])
}

/// Where a turn begins in a session's history: the turn's index (`RunRecord.turnIndex`) and
/// the position of the user message that opened it.
public struct TurnStart: Sendable, Equatable, Hashable {
  public let turn: Int
  public let index: Int

  public init(turn: Int, index: Int) {
    self.turn = turn
    self.index = index
  }
}

/// A fully replayed session, ready to hand to `Session(resuming:)`.
public struct LoadedSession: Sendable {
  public let meta: SessionMeta
  public let messages: [Message]
  /// The model in effect at the end of the transcript (meta model + model_change replay).
  public let model: String
  public let costUSD: Double
  public let turnCount: Int
  /// The latest compaction summary, when older history was compacted away.
  public let compactionSummary: String?
  /// The reasoning-effort dial in effect at the end of the transcript, when one was
  /// recorded. A resumed session prefers it unless the caller passed `--effort`.
  public let reasoningEffort: Reasoning.Effort?
  /// Where each turn begins in `messages`, from the message lines' `turn` tags — empty for a
  /// transcript written before the tags existed (its turns can't be told apart afterwards).
  public let turnStarts: [TurnStart]

  public init(
    meta: SessionMeta,
    messages: [Message],
    model: String,
    costUSD: Double,
    turnCount: Int,
    compactionSummary: String? = nil,
    reasoningEffort: Reasoning.Effort? = nil,
    turnStarts: [TurnStart] = [])
  {
    self.meta = meta
    self.messages = messages
    self.model = model
    self.costUSD = costUSD
    self.turnCount = turnCount
    self.compactionSummary = compactionSummary
    self.reasoningEffort = reasoningEffort
    self.turnStarts = turnStarts
  }
}

// MARK: - SessionStore

/// Append-only JSONL transcripts at `~/.arnes/sessions/<id>.jsonl`. Every turn is
/// persisted as it happens, so a crashed session is resumable up to its last line.
public struct SessionStore: Sendable {
  public let directory: URL

  public init(
    directory: URL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".arnes/sessions"))
  {
    self.directory = directory
  }

  public func append(_ entry: TranscriptEntry, to id: String) throws {
    // What goes to disk is redacted — every role, and a compaction summary too: a user who
    // pastes a key into the REPL should not find it in a 0600 file forever, and a tool result
    // that carried one was redacted before it reached history anyway. The live history is
    // untouched; this is the file's copy.
    var entry = entry
    if entry.type == .message || entry.type == .compaction, let text = entry.text {
      entry.text = SecretScrubber.scrub(text).text
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(entry)
    line.append(Data("\n".utf8))
    // Transcripts hold tool outputs — file contents — so they are created owner-only.
    try appendJSONLLine(line, to: fileURL(for: id))
  }

  public func load(id: String) throws -> LoadedSession {
    let url = fileURL(for: id)
    let data = try Data(contentsOf: url)
    let entries = Self.decodeEntries(data)

    var messages: [Message] = []
    var model: String?
    var createdAt: Date?
    var name: String?
    var forkedFrom: String?
    var cwd: String?
    var parent: String?
    var agent: String?
    var depth: Int?
    var origin: String?
    var costUSD = 0.0
    var turnCount = 0
    var compactionSummary: String?
    var reasoningEffort: Reasoning.Effort?
    var turnStarts: [TurnStart] = []
    for entry in entries {
      switch entry.type {
      case .meta:
        if createdAt == nil { createdAt = entry.createdAt }
        if let metaModel = entry.model, model == nil { model = metaModel }
        if let metaName = entry.name { name = metaName }
        if let forkParent = entry.forkedFrom { forkedFrom = forkParent }
        if let metaCwd = entry.cwd, cwd == nil { cwd = metaCwd }
        // Lineage is set once, by the first meta line; a later meta (rename, fork) never
        // re-parents a transcript.
        if let lead = entry.parent, parent == nil { parent = lead }
        if let ran = entry.agent, agent == nil { agent = ran }
        if let nested = entry.depth, depth == nil { depth = nested }
        if let started = entry.origin, origin == nil { origin = started }
      case .message:
        if let message = entry.toMessage() {
          if message.role == .user { turnCount += 1 }
          // The first message tagged with a turn opens it — exactly what the live session
          // recorded when that turn's user message entered history.
          if let turn = entry.turn, turnStarts.last?.turn != turn {
            turnStarts.append(TurnStart(turn: turn, index: messages.count))
          }
          messages.append(message)
        }
      case .modelChange:
        if let changed = entry.model {
          // The same strip `Session.setModel` applied live: a signed reasoning block is bound
          // to the model that produced it, so the replayed history equals what the session had.
          if changed != model {
            messages = ReasoningDetails.stripped(messages)
          }
          model = changed
        }
      case .cost:
        if let session = entry.sessionUSD { costUSD = session }
      case .clear:
        messages.removeAll()
        turnStarts.removeAll()
        compactionSummary = nil
      case .compaction:
        // The kept tail is re-appended after this line, tags included, so the starts rebuild
        // themselves exactly as the live session cut them.
        messages.removeAll()
        turnStarts.removeAll()
        compactionSummary = entry.text
      case .effortChange:
        // `off` switches the dial off (`/effort off`); an unknown level (a newer arnes wrote
        // it) leaves the dial as it was.
        if entry.text == TranscriptEntry.effortOffLevel {
          reasoningEffort = nil
        } else if let level = entry.text, let effort = Reasoning.Effort(rawValue: level) {
          reasoningEffort = effort
        }
      case .rewind:
        // The cut the live session made: messages past `keepMessages` go, and with them every
        // turn that began there. A code-only rewind (nil) changed no message. `turnCount` is
        // not rewound — turns are monotonic, and the live session's `turnIndex` isn't either.
        if let keep = entry.keepMessages, keep >= 0, keep < messages.count {
          messages.removeSubrange(keep...)
          turnStarts.removeAll { $0.index >= keep }
        }
      }
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let updatedAt = (attributes?[.modificationDate] as? Date) ?? createdAt ?? Date()
    let meta = SessionMeta(
      id: id,
      createdAt: createdAt,
      name: name,
      model: model,
      forkedFrom: forkedFrom,
      cwd: cwd,
      updatedAt: updatedAt,
      messageCount: messages.count,
      parent: parent,
      agent: agent,
      depth: depth,
      origin: origin)
    return LoadedSession(
      meta: meta,
      messages: messages,
      model: model ?? "openrouter/auto",
      costUSD: costUSD,
      turnCount: turnCount,
      compactionSummary: compactionSummary,
      reasoningEffort: reasoningEffort,
      turnStarts: turnStarts)
  }

  /// All stored sessions, most recently updated first.
  ///
  /// Backed by a `(mtime, size)`-keyed index beside the transcripts, so listing a long
  /// history doesn't re-decode every line of every session — an appended-to (or brand new)
  /// transcript is replayed, everything else comes from the cache. The index is a
  /// derivable cache: an unreadable or unwritable one costs speed, never correctness.
  public func list() throws -> [SessionMeta] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
    else {
      return []
    }
    let cached = Self.loadIndex(at: indexURL)
    var fresh = SessionIndex()
    var metas: [SessionMeta] = []
    for url in files where url.pathExtension == "jsonl" {
      let id = url.deletingPathExtension().lastPathComponent
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
      let modifiedAt = attributes?[.modificationDate] as? Date
      let size = (attributes?[.size] as? Int) ?? -1
      if let row = cached.rows[id], let modifiedAt,
         row.modifiedAt == modifiedAt.timeIntervalSince1970, row.size == size
      {
        fresh.rows[id] = row
        metas.append(row.meta(id: id, updatedAt: modifiedAt))
        continue
      }
      guard let meta = try? load(id: id).meta else { continue }
      metas.append(meta)
      if let modifiedAt, size >= 0 {
        fresh.rows[id] = SessionIndex.Row(meta: meta, modifiedAt: modifiedAt, size: size)
      }
    }
    if fresh.rows != cached.rows {
      Self.saveIndex(fresh, to: indexURL)
    }
    return metas.sorted { $0.updatedAt > $1.updatedAt }
  }

  public func mostRecent() -> SessionMeta? {
    (try? list())?.first
  }

  // MARK: Lookup

  /// Resolves a query the way `arnes resume` does: an exact id wins; otherwise a unique
  /// case-insensitive id prefix or saved name. `sessions` is whatever list the caller wants to
  /// resolve against (usually `list()`, most-recent-first). Pure, so the CLI and the task tool
  /// share one rule and word the outcome each their own way.
  public static func match(_ query: String, in sessions: [SessionMeta]) -> SessionMatch {
    if let exact = sessions.first(where: { $0.id == query }) { return .found(exact) }
    let lowered = query.lowercased()
    let matches = sessions.filter {
      $0.id.lowercased().hasPrefix(lowered) || $0.name?.lowercased() == lowered
    }
    switch matches.count {
    case 1: return .found(matches[0])
    case 0: return .none
    default: return .ambiguous(matches)
    }
  }

  /// The one stored session `prefix` names (exact id or unique id/name prefix), or nil when
  /// none or several do. Over `list()`, so it costs an index read.
  public func resolve(prefix: String) -> String? {
    guard let sessions = try? list(), case .found(let meta) = Self.match(prefix, in: sessions) else {
      return nil
    }
    return meta.id
  }

  // MARK: Subagent transcripts

  /// The directory name nested (subagent) transcripts live under, beside the lead's.
  public static let subagentDirectoryName = "subagents"

  /// The store for subagent transcripts: `<directory>/subagents/<id>.jsonl`. A separate
  /// directory rather than a flag on the row, so `arnes sessions` keeps listing the user's own
  /// sessions and nothing a subagent did can be mistaken for one of them. Just another
  /// `SessionStore`: `load`, `list`, `exportMarkdown` and `delete` work on it unchanged.
  public var subagentStore: SessionStore {
    SessionStore(directory: directory.appendingPathComponent(Self.subagentDirectoryName))
  }

  /// Whether this store is itself a subagent store (the nested directory of a lead store).
  var isSubagentStore: Bool {
    directory.lastPathComponent == Self.subagentDirectoryName
  }

  /// `/save` — names a session by appending a meta line (append-only, no rewrites).
  public func rename(id: String, name: String) throws {
    var entry = TranscriptEntry(type: .meta)
    entry.id = id
    entry.name = name
    try append(entry, to: id)
  }

  // MARK: Lifecycle

  /// Copies a transcript into a new session and records the parent. The copy is a plain
  /// file copy plus one appended meta line — the original is never rewritten, so forking a
  /// session that is currently open is safe: the fork just holds a valid prefix of it.
  ///
  /// - Returns: the new session's id.
  @discardableResult
  public func fork(id: String, name: String? = nil) throws -> String {
    let data = try Data(contentsOf: fileURL(for: id))
    let newId = UUID().uuidString
    // Transcripts hold tool outputs; the copy is owner-only like the original.
    try SecureFiles.writePrivate(data, to: fileURL(for: newId))
    var entry = TranscriptEntry(type: .meta)
    entry.id = newId
    entry.name = name
    entry.forkedFrom = id
    try append(entry, to: newId)
    return newId
  }

  /// Removes a session: its transcript, any per-session scratch beside it
  /// (`checkpoints/<id>`, `tmp/<id>` under the arnes directory) and, for a lead session, the
  /// transcripts of the subagents it delegated to (`subagents/`, `parent == id` — scratch kept
  /// for that session, unresumable once it is gone). Missing pieces are fine — deleting an
  /// already-deleted session is not an error.
  public func delete(id: String) throws {
    let transcript = fileURL(for: id)
    if FileManager.default.fileExists(atPath: transcript.path) {
      try FileManager.default.removeItem(at: transcript)
    }
    for directory in sidecarDirectories(for: id)
      where FileManager.default.fileExists(atPath: directory.path)
    {
      try? FileManager.default.removeItem(at: directory)
    }
    if !isSubagentStore {
      let nested = subagentStore
      for child in (try? nested.list()) ?? [] where child.parent == id {
        try? nested.delete(id: child.id)
      }
    }
  }

  /// Deletes sessions untouched for `days`. Named sessions are kept unless `keepNamed` is
  /// false — a `/save`d name is the user saying "this one matters". Subagent transcripts
  /// (`subagents/`) are swept by the same age rule; they are never named.
  ///
  /// - Returns: how many sessions were deleted, nested ones included.
  @discardableResult
  public func prune(olderThan days: Int, keepNamed: Bool = true) throws -> Int {
    guard days >= 0 else { return 0 }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    var deleted = 0
    for meta in try list() where meta.updatedAt < cutoff {
      if keepNamed, meta.name != nil { continue }
      try delete(id: meta.id)
      deleted += 1
    }
    if !isSubagentStore {
      deleted += try subagentStore.prune(olderThan: days, keepNamed: keepNamed)
    }
    return deleted
  }

  /// A transcript's lines as stored, in file order — every `TranscriptEntry` the JSONL holds
  /// (`meta`, `message`, `model_change`, `cost`, `clear`, `compaction`, `effort_change`,
  /// `rewind`), nothing replayed and nothing dropped but a line that doesn't decode. The
  /// on-disk shape *is* the contract, so `arnes evals transcript --json` re-encodes these
  /// rather than inventing a second one. Throws when the transcript is absent or unreadable.
  public func entries(id: String) throws -> [TranscriptEntry] {
    Self.decodeEntries(try Data(contentsOf: fileURL(for: id)))
  }

  /// A session as readable markdown: prose for user/assistant turns, one blockquote line
  /// per tool call and per (first-line-only) tool result, compaction summaries quoted.
  /// Chronological — a `clear` or `compaction` is shown where it happened rather than
  /// erasing what came before, since an export is a record of the session, not its context.
  public func exportMarkdown(id: String) throws -> String {
    let entries = Self.decodeEntries(try Data(contentsOf: fileURL(for: id)))
    var header: [String] = []
    var body: [String] = []
    var toolNames: [String: String] = [:] // tool_call_id → tool name
    var name: String?
    var model: String?
    var createdAt: Date?
    var forkedFrom: String?
    var parent: String?
    var agent: String?

    for entry in entries {
      switch entry.type {
      case .meta:
        if createdAt == nil { createdAt = entry.createdAt }
        if model == nil { model = entry.model }
        if let metaName = entry.name { name = metaName }
        if let forkParent = entry.forkedFrom { forkedFrom = forkParent }
        if parent == nil { parent = entry.parent }
        if agent == nil { agent = entry.agent }
      case .message:
        guard let role = entry.role else { break }
        let text = (entry.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch role {
        case "tool":
          let label = entry.toolCallId.flatMap { toolNames[$0] }
          body.append("> ← " + (label.map { "\($0): " } ?? "") + Self.firstLine(text))
        case "user", "assistant":
          if !text.isEmpty {
            body.append("## \(role)\n\n\(text)")
          }
          for call in entry.toolCalls ?? [] {
            let toolName = call.function?.name ?? "?"
            if let callId = call.id { toolNames[callId] = toolName }
            let arguments = Self.clamp(call.function?.arguments ?? "", to: 200)
            body.append("> tool \(toolName)(\(arguments))")
          }
        default:
          break // system messages are rebuilt per request, never persisted
        }
      case .modelChange:
        if let changed = entry.model { body.append("> model → \(changed)") }
      case .effortChange:
        if let level = entry.text { body.append("> effort → \(level)") }
      case .compaction:
        body.append(Self.blockquote("compacted older turns: " + (entry.text ?? "")))
      case .clear:
        body.append("> history cleared")
      case .rewind:
        let turn = entry.turn.map(String.init) ?? "?"
        var line = entry.keepMessages.map { "> rewound to turn \(turn) (kept \($0) messages)" }
          ?? "> rewound files to turn \(turn) (conversation kept)"
        if let restored = entry.restoredPaths, !restored.isEmpty {
          line += " · restored " + restored.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        }
        body.append(line)
      case .cost:
        break // the running total lands in the footer below
      }
    }

    header.append("# \(name ?? id)")
    var facts = ["id: \(id)"]
    if let model { facts.append("model: \(model)") }
    if let createdAt {
      facts.append("created: \(ISO8601DateFormatter().string(from: createdAt))")
    }
    if let forkedFrom { facts.append("forked from: \(forkedFrom)") }
    if let agent { facts.append("agent: \(agent)") }
    if let parent { facts.append("subagent of: \(parent)") }
    if let total = entries.compactMap(\.sessionUSD).last {
      facts.append("cost: $\(String(format: "%.4f", total))")
    }
    header.append(facts.map { "- \($0)" }.joined(separator: "\n"))
    return (header + body).joined(separator: "\n\n") + "\n"
  }

  private static func firstLine(_ text: String) -> String {
    clamp(text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "", to: 200)
  }

  private static func clamp(_ text: String, to limit: Int) -> String {
    text.count > limit ? String(text.prefix(limit)) + "…" : text
  }

  private static func blockquote(_ text: String) -> String {
    text.split(separator: "\n", omittingEmptySubsequences: false)
      .map { "> \($0)" }
      .joined(separator: "\n")
  }

  // MARK: Paths

  private func fileURL(for id: String) -> URL {
    directory.appendingPathComponent("\(Self.safe(id)).jsonl")
  }

  /// Per-session scratch that dies with the session, resolved from the store's own
  /// directory (so a test store under a temp root touches only that root); a subagent store
  /// shares its lead store's root.
  private func sidecarDirectories(for id: String) -> [URL] {
    var root = directory.deletingLastPathComponent()
    if isSubagentStore { root = root.deletingLastPathComponent() }
    return ["checkpoints", "tmp"].map {
      root.appendingPathComponent($0).appendingPathComponent(Self.safe(id))
    }
  }

  /// Ids are UUIDs we generate; sanitize user-typed ones so they can't escape the directory.
  private static func safe(_ id: String) -> String {
    id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
  }

  private static func decodeEntries(_ data: Data) -> [TranscriptEntry] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { try? decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
  }

  // MARK: Index

  /// The `list()` cache. Not a `.jsonl` file, so it is never mistaken for a transcript.
  var indexURL: URL { directory.appendingPathComponent(".index.json") }

  private static func loadIndex(at url: URL) -> SessionIndex {
    guard let data = try? Data(contentsOf: url),
          let index = try? JSONDecoder().decode(SessionIndex.self, from: data)
    else {
      return SessionIndex()
    }
    return index
  }

  private static func saveIndex(_ index: SessionIndex, to url: URL) {
    guard let data = try? JSONEncoder().encode(index) else { return }
    // A cache miss is cheap; a failed write (read-only home, a race) must not fail `list()`.
    try? SecureFiles.writePrivate(data, to: url)
  }
}

// MARK: - SessionIndex

/// Cached `list()` rows keyed by session id, invalidated by the transcript's modification
/// time and size. Purely derived: throwing it away only costs one full replay.
struct SessionIndex: Codable, Equatable {
  struct Row: Codable, Equatable {
    /// `timeIntervalSince1970` of the transcript when this row was computed.
    var modifiedAt: Double
    var size: Int
    var createdAt: Date?
    var name: String?
    var model: String?
    var forkedFrom: String?
    var messageCount: Int
    /// Lineage (nested transcripts). Optional, so an index written before the fields existed
    /// still decodes — its rows describe lead sessions, which carry none.
    var parent: String?
    var agent: String?
    var depth: Int?
    var origin: String?

    init(meta: SessionMeta, modifiedAt: Date, size: Int) {
      self.modifiedAt = modifiedAt.timeIntervalSince1970
      self.size = size
      createdAt = meta.createdAt
      name = meta.name
      model = meta.model
      forkedFrom = meta.forkedFrom
      messageCount = meta.messageCount
      parent = meta.parent
      agent = meta.agent
      depth = meta.depth
      origin = meta.origin
    }

    func meta(id: String, updatedAt: Date) -> SessionMeta {
      SessionMeta(
        id: id, createdAt: createdAt, name: name, model: model, forkedFrom: forkedFrom,
        updatedAt: updatedAt, messageCount: messageCount,
        parent: parent, agent: agent, depth: depth, origin: origin)
    }
  }

  var rows: [String: Row] = [:]
}
