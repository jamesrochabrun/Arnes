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
  /// What kind of failure this was, when it is not the endpoint's — nil for an endpoint failure
  /// and for every row written before the field. Recorded and shown by `arnes probe` in every
  /// case; what `DialectVerdictStore.isKnownBad` does with it differs:
  /// - `thinking` — the request carried a thinking/reasoning shape the endpoint refused (a
  ///   missing or unsigned thinking block, a `budget_tokens` the model rejected). Never pins:
  ///   the endpoint is fine, the request was not.
  /// - `cache_control` — the endpoint refused the request's prompt-cache breakpoints (a gateway
  ///   that does not accept the field). Never pins; the session re-sends without them.
  /// - `transport` — the wire failed (a 429/5xx storm, a lost connection, an idle stream) and
  ///   the retries ran out. Says nothing about conformance, so it cools the route for
  ///   `DialectVerdictStore.transportCooldown` (minutes) instead of pinning it for the failure
  ///   TTL (a week) — one bad hour never costs a week of chat.
  public var category: String?
  public var at: Date

  /// The request's thinking shape was refused — never pins.
  public static let thinkingCategory = "thinking"
  /// The request's `cache_control` markers were refused — never pins.
  public static let cacheControlCategory = "cache_control"
  /// The wire failed and the retries ran out — a cooldown, never the week-long pin.
  public static let transportCategory = "transport"
  /// How a refused `cache_control` names itself in an error body (`messages.0.content.0.
  /// cache_control: Extra inputs are not permitted`, `cacheControl` from a camel-cased gateway).
  static let cacheControlMarkers = ["cache_control", "cache control", "cachecontrol"]

  public init(
    model: String, dialect: String, ok: Bool, reason: String? = nil, category: String? = nil,
    at: Date = Date())
  {
    self.model = model
    self.dialect = dialect
    self.ok = ok
    self.reason = reason
    self.category = category
    self.at = at
  }

  /// Classifies a native failure's text: a message naming `cache_control` is a refused
  /// prompt-cache breakpoint (`cacheControlCategory`, checked first — the block it sat on may be
  /// a thinking block); one about `thinking`, `redacted_thinking`, a `signature` or
  /// `budget_tokens` is a thinking-shape refusal (`thinkingCategory`); anything else is the
  /// endpoint's (nil). A transport failure is never classified from its text — the session and
  /// the probe know it from the error's type. The model's own id is taken out of the text
  /// first — an id may itself say `thinking` (`anthropic/claude-3.7-sonnet:thinking`) and an
  /// endpoint's error body names the model it couldn't serve, so "No endpoints found for
  /// …:thinking" is the endpoint's failure and must pin like one.
  public static func category(forFailure text: String, model: String? = nil) -> String? {
    var lowered = text.lowercased()
    if let model = model?.lowercased(), !model.isEmpty {
      lowered = lowered.replacingOccurrences(of: model, with: " ")
      // The bare name too (`claude-3.7-sonnet:thinking`): a body may spell it without the vendor.
      if let slash = model.lastIndex(of: "/"), model.index(after: slash) < model.endIndex {
        lowered = lowered.replacingOccurrences(of: String(model[model.index(after: slash)...]), with: " ")
      }
    }
    if cacheControlMarkers.contains(where: { lowered.contains($0) }) {
      return cacheControlCategory
    }
    let markers = ["thinking", "redacted_thinking", "signature", "budget_tokens"]
    return markers.contains { lowered.contains($0) } ? thinkingCategory : nil
  }
}

// MARK: - DialectVerdictStore

/// Append-only JSONL at `~/.arnes/dialects.jsonl`; the latest verdict per
/// model × dialect wins. `Session` consults it when `DialectOverride.auto` would pick
/// a native dialect: a fresh failed verdict pins the model to chat, so one broken
/// endpoint never breaks a second run. Failed verdicts expire (default 7 days) so a
/// fixed endpoint gets retried; ok verdicts stand until a failure replaces them. A `transport`
/// failure (the wire, not the endpoint) pins only for `transportCooldown` (default 15 minutes):
/// long enough not to hammer a route that just failed every retry, short enough that a
/// rate-limit storm never costs a week on chat.
public final class DialectVerdictStore: @unchecked Sendable {
  public let url: URL
  private let failureTTL: TimeInterval
  private let transportCooldown: TimeInterval
  private let lock = NSLock()
  private var cache: [String: DialectVerdict]?

  /// How long a `transport` verdict keeps `.auto` on chat.
  public static let defaultTransportCooldown: TimeInterval = 15 * 60

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/dialects.jsonl"),
    failureTTL: TimeInterval = 7 * 24 * 3600,
    transportCooldown: TimeInterval = DialectVerdictStore.defaultTransportCooldown)
  {
    self.url = url
    self.failureTTL = failureTTL
    self.transportCooldown = transportCooldown
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

  /// Whether `.auto` should avoid this native dialect for the model. A `thinking` or
  /// `cache_control` failure is the request's, not the endpoint's — recorded (and `arnes probe`
  /// shows it) but never pins; a `transport` failure pins only while its cooldown lasts; an
  /// endpoint failure (no category) pins for the failure TTL.
  public func isKnownBad(model: String, dialect: Dialect) -> Bool {
    guard let verdict = latest(model: model, dialect: dialect), !verdict.ok else { return false }
    switch verdict.category {
    case DialectVerdict.thinkingCategory, DialectVerdict.cacheControlCategory:
      return false
    case DialectVerdict.transportCategory:
      return Date().timeIntervalSince(verdict.at) <= transportCooldown
    default:
      return true
    }
  }

  /// Records a verdict; identical consecutive ok verdicts are skipped so routine
  /// successful runs don't grow the file.
  public func record(model: String, dialect: Dialect, ok: Bool, reason: String? = nil, category: String? = nil) {
    lock.lock()
    defer { lock.unlock() }
    let key = Self.key(model, dialect)
    if ok, loadedCache()[key]?.ok == true {
      return
    }
    let verdict = DialectVerdict(
      model: model, dialect: dialect.rawValue, ok: ok,
      reason: reason.map { String($0.prefix(300)) },
      category: ok ? nil : category)
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
