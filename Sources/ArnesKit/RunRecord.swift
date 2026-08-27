import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Appends one line to a JSONL file with `O_APPEND` semantics, so concurrent writers
/// (parallel panel candidates) never clobber each other the way seek-then-write would.
func appendJSONLLine(_ line: Data, to url: URL) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(),
    withIntermediateDirectories: true)
  let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
  guard descriptor >= 0 else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
  defer { close(descriptor) }
  try handle.write(contentsOf: line)
}

/// One row of the evaluation substrate. Every agent execution appends a record;
/// the panel judge (loop 2) and routing scoreboard (loop 3) read them back.
public struct RunRecord: Codable, Sendable {
  public var id: String
  public var startedAt: Date
  public var task: String
  public var model: String
  public var dialect: String
  public var packFamily: String
  public var steps: Int
  public var toolCalls: Int
  /// The models that actually served steps (post-routing) — differs from `model`
  /// when using `openrouter/auto` or fallbacks.
  public var routedModels: [String]
  /// Total USD cost, summed from `usage.cost` across every request in the run.
  public var costUSD: Double
  public var finished: Bool
  /// Loop-1 verifier verdict, when a verifier ran.
  public var verifierPassed: Bool?
  public var summary: String?
  /// The interactive session this turn belongs to (nil for pre-v0.2 records).
  public var sessionId: String?
  /// Zero-based turn number within the session.
  public var turnIndex: Int?
  /// Subagent name when this run was delegated via the task tool; nil for lead runs.
  public var agent: String?

  public init(
    task: String,
    model: String,
    dialect: String,
    packFamily: String)
  {
    id = UUID().uuidString
    startedAt = Date()
    self.task = task
    self.model = model
    self.dialect = dialect
    self.packFamily = packFamily
    steps = 0
    toolCalls = 0
    routedModels = []
    costUSD = 0
    finished = false
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    task = try container.decode(String.self, forKey: .task)
    model = try container.decode(String.self, forKey: .model)
    dialect = try container.decode(String.self, forKey: .dialect)
    packFamily = try container.decode(String.self, forKey: .packFamily)
    steps = try container.decode(Int.self, forKey: .steps)
    toolCalls = try container.decode(Int.self, forKey: .toolCalls)
    routedModels = try container.decodeIfPresent([String].self, forKey: .routedModels) ?? []
    costUSD = try container.decode(Double.self, forKey: .costUSD)
    finished = try container.decode(Bool.self, forKey: .finished)
    verifierPassed = try container.decodeIfPresent(Bool.self, forKey: .verifierPassed)
    summary = try container.decodeIfPresent(String.self, forKey: .summary)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    turnIndex = try container.decodeIfPresent(Int.self, forKey: .turnIndex)
    agent = try container.decodeIfPresent(String.self, forKey: .agent)
  }
}

/// Append-only JSONL store at `~/.arnes/runs.jsonl`.
public struct RunRecordStore: Sendable {
  public let url: URL

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/runs.jsonl"))
  {
    self.url = url
  }

  public func append(_ record: RunRecord) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(record)
    line.append(Data("\n".utf8))
    try appendJSONLLine(line, to: url)
  }

  public func all() throws -> [RunRecord] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { try? decoder.decode(RunRecord.self, from: Data($0.utf8)) }
  }
}
