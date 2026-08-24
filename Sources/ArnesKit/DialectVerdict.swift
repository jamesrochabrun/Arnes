import Foundation

// MARK: - DialectVerdict

/// One conformance observation: whether a model behaved on a native dialect. Written
/// optimistically from real agent runs (no separate probe request on the happy path)
/// and by the explicit `arnes probe` command.
public struct DialectVerdict: Codable, Sendable {
  public var model: String
  public var dialect: String
  public var ok: Bool
  public var reason: String?
  public var at: Date

  public init(model: String, dialect: String, ok: Bool, reason: String? = nil, at: Date = Date()) {
    self.model = model
    self.dialect = dialect
    self.ok = ok
    self.reason = reason
    self.at = at
  }
}

// MARK: - DialectVerdictStore

/// Append-only JSONL at `~/.arnes/dialects.jsonl`; the latest verdict per
/// model × dialect wins. `Session` consults it when `DialectOverride.auto` would pick
/// a native dialect: a fresh failed verdict pins the model to chat, so one broken
/// endpoint never breaks a second run. Failed verdicts expire (default 7 days) so a
/// fixed endpoint gets retried; ok verdicts stand until a failure replaces them.
public final class DialectVerdictStore: @unchecked Sendable {
  public let url: URL
  private let failureTTL: TimeInterval
  private let lock = NSLock()
  private var cache: [String: DialectVerdict]?

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/dialects.jsonl"),
    failureTTL: TimeInterval = 7 * 24 * 3600)
  {
    self.url = url
    self.failureTTL = failureTTL
  }

  /// The latest verdict for this model × dialect, expired failures filtered out.
  public func latest(model: String, dialect: Dialect) -> DialectVerdict? {
    lock.lock()
    defer { lock.unlock() }
    guard let verdict = loadedCache()[Self.key(model, dialect)] else { return nil }
    if !verdict.ok, Date().timeIntervalSince(verdict.at) > failureTTL {
      return nil // stale failure — worth trying natively again
    }
    return verdict
  }

  /// Whether `.auto` should avoid this native dialect for the model.
  public func isKnownBad(model: String, dialect: Dialect) -> Bool {
    latest(model: model, dialect: dialect)?.ok == false
  }

  /// Records a verdict; identical consecutive ok verdicts are skipped so routine
  /// successful runs don't grow the file.
  public func record(model: String, dialect: Dialect, ok: Bool, reason: String? = nil) {
    lock.lock()
    defer { lock.unlock() }
    let key = Self.key(model, dialect)
    if ok, loadedCache()[key]?.ok == true {
      return
    }
    let verdict = DialectVerdict(
      model: model, dialect: dialect.rawValue, ok: ok,
      reason: reason.map { String($0.prefix(300)) })
    cache?[key] = verdict
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    if var line = try? encoder.encode(verdict) {
      line.append(Data("\n".utf8))
      try? appendJSONLLine(line, to: url)
    }
  }

  /// Every current verdict (latest per model × dialect), for `arnes dialects`-style
  /// listings and the probe command's reporting.
  public func all() -> [DialectVerdict] {
    lock.lock()
    defer { lock.unlock() }
    return loadedCache().values.sorted {
      ($0.model, $0.dialect) < ($1.model, $1.dialect)
    }
  }

  private func loadedCache() -> [String: DialectVerdict] {
    if let cache { return cache }
    var latest: [String: DialectVerdict] = [:]
    if let data = try? Data(contentsOf: url) {
      let decoder = JSONDecoder()
      decoder.dateDecodingStrategy = .iso8601
      for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard let verdict = try? decoder.decode(DialectVerdict.self, from: Data(line.utf8)) else {
          continue
        }
        latest[Self.key(verdict.model, Dialect(rawValue: verdict.dialect) ?? .chat)] = verdict
      }
    }
    cache = latest
    return latest
  }

  private static func key(_ model: String, _ dialect: Dialect) -> String {
    "\(model)#\(dialect.rawValue)"
  }
}
