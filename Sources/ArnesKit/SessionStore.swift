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
  }

  public var type: Kind
  // meta
  public var id: String?
  public var createdAt: Date?
  public var name: String?
  public var cwd: String?
  // message
  public var role: String?
  public var text: String?
  public var toolCallId: String?
  public var toolCalls: [ToolCall]?
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
    case role
    case text
    case toolCallId
    case toolCalls
    case model
    case turnUSD
    case sessionUSD
  }

  public static func meta(id: String, model: String, cwd: String?, name: String? = nil) -> TranscriptEntry {
    var entry = TranscriptEntry(type: .meta)
    entry.id = id
    entry.createdAt = Date()
    entry.model = model
    entry.cwd = cwd
    entry.name = name
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

  public init(type: Kind) {
    self.type = type
  }

  public init(message: Message) {
    type = .message
    role = message.role.rawValue
    text = message.content?.plainText
    toolCallId = message.toolCallId
    toolCalls = message.toolCalls
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
      toolCalls: toolCalls)
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
public struct SessionMeta: Sendable {
  public let id: String
  public let createdAt: Date?
  public let name: String?
  public let model: String?
  public let updatedAt: Date
  public let messageCount: Int

  public init(
    id: String,
    createdAt: Date? = nil,
    name: String? = nil,
    model: String? = nil,
    updatedAt: Date,
    messageCount: Int)
  {
    self.id = id
    self.createdAt = createdAt
    self.name = name
    self.model = model
    self.updatedAt = updatedAt
    self.messageCount = messageCount
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
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(entry)
    line.append(Data("\n".utf8))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = fileURL(for: id)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: url)
    }
  }

  public func load(id: String) throws -> LoadedSession {
    let url = fileURL(for: id)
    let data = try Data(contentsOf: url)
    let entries = Self.decodeEntries(data)

    var messages: [Message] = []
    var model: String?
    var createdAt: Date?
    var name: String?
    var costUSD = 0.0
    var turnCount = 0
    var compactionSummary: String?
    for entry in entries {
      switch entry.type {
      case .meta:
        if createdAt == nil { createdAt = entry.createdAt }
        if let metaModel = entry.model, model == nil { model = metaModel }
        if let metaName = entry.name { name = metaName }
      case .message:
        if let message = entry.toMessage() {
          if message.role == .user { turnCount += 1 }
          messages.append(message)
        }
      case .modelChange:
        if let changed = entry.model { model = changed }
      case .cost:
        if let session = entry.sessionUSD { costUSD = session }
      case .clear:
        messages.removeAll()
        compactionSummary = nil
      case .compaction:
        messages.removeAll()
        compactionSummary = entry.text
      }
    }

    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    let updatedAt = (attributes?[.modificationDate] as? Date) ?? createdAt ?? Date()
    let meta = SessionMeta(
      id: id,
      createdAt: createdAt,
      name: name,
      model: model,
      updatedAt: updatedAt,
      messageCount: messages.count)
    return LoadedSession(
      meta: meta,
      messages: messages,
      model: model ?? "openrouter/auto",
      costUSD: costUSD,
      turnCount: turnCount,
      compactionSummary: compactionSummary)
  }

  /// All stored sessions, most recently updated first.
  public func list() throws -> [SessionMeta] {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: directory,
      includingPropertiesForKeys: [.contentModificationDateKey])
    else {
      return []
    }
    return files
      .filter { $0.pathExtension == "jsonl" }
      .compactMap { url in
        let id = url.deletingPathExtension().lastPathComponent
        return try? load(id: id).meta
      }
      .sorted { $0.updatedAt > $1.updatedAt }
  }

  public func mostRecent() -> SessionMeta? {
    (try? list())?.first
  }

  /// `/save` — names a session by appending a meta line (append-only, no rewrites).
  public func rename(id: String, name: String) throws {
    var entry = TranscriptEntry(type: .meta)
    entry.id = id
    entry.name = name
    try append(entry, to: id)
  }

  private func fileURL(for id: String) -> URL {
    // Ids are UUIDs we generate; sanitize user-typed ids so they can't escape the directory.
    let safe = id.filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return directory.appendingPathComponent("\(safe).jsonl")
  }

  private static func decodeEntries(_ data: Data) -> [TranscriptEntry] {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { try? decoder.decode(TranscriptEntry.self, from: Data($0.utf8)) }
  }
}
