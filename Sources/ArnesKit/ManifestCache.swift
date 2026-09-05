import Foundation

// MARK: - CachedManifest

/// A model manifest the catalog saved between processes: which provider it came from, when it
/// was fetched, and the profiles it carried. Schema-versioned so a reader of another shape
/// treats the file as a miss (a refetch), never as an error — a cache is derived data.
public struct CachedManifest: Codable, Sendable {
  public static let currentSchema = 1

  public var schema: Int
  public var provider: String
  public var fetchedAt: Date
  public var profiles: [ModelProfile]

  public init(provider: String, fetchedAt: Date, profiles: [ModelProfile]) {
    schema = Self.currentSchema
    self.provider = provider
    self.fetchedAt = fetchedAt
    self.profiles = profiles
  }
}

// MARK: - ManifestCachePolicy

/// How long a cached manifest is served without a fetch.
public struct ManifestCachePolicy: Sendable, Equatable {
  public static let defaultTTL: TimeInterval = 24 * 3600
  public static let `default` = ManifestCachePolicy(ttl: defaultTTL)

  /// Seconds after `fetchedAt` during which the disk copy answers instead of the network.
  public var ttl: TimeInterval

  public init(ttl: TimeInterval) {
    self.ttl = max(0, ttl)
  }
}

// MARK: - ManifestCache

/// The catalog's on-disk manifest cache: one `<provider>.json` per provider under `directory`
/// (the CLI's `~/.arnes/models`), 0700/0600 like everything under `~/.arnes`. Pure file I/O —
/// the serving rules (fresh → no fetch, stale → the fallback for a failed fetch, an unknown id →
/// one refetch) are `ModelCatalog`'s. A manifest is public data, but the file lives next to
/// tokens, so it takes the directory's posture rather than a mode of its own.
public final class ManifestCache: Sendable {
  public let directory: URL
  public let policy: ManifestCachePolicy

  public init(directory: URL, policy: ManifestCachePolicy = .default) {
    self.directory = directory
    self.policy = policy
  }

  /// `<directory>/<fileName(for: provider)>`.
  public func url(for provider: String) -> URL {
    directory.appendingPathComponent(Self.fileName(for: provider))
  }

  /// `openrouter.json`. Anything outside ASCII letters, digits, `.`, `_` and `-` becomes `-`, so
  /// a provider name from the config can never name a path outside the directory; an empty name
  /// is `manifest`.
  public static func fileName(for provider: String) -> String {
    let safe = provider.unicodeScalars.map { scalar -> Character in
      switch scalar {
      case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": return Character(scalar)
      default: return "-"
      }
    }
    let name = String(safe)
    return (name.isEmpty ? "manifest" : name) + ".json"
  }

  /// The saved manifest for `provider`, or nil when there is none worth serving: no file, an
  /// unreadable or corrupt one, or one written under another schema. The file name is the key —
  /// the entry's own `provider` is informational (a sanitized name need not round-trip).
  public func load(provider: String) -> CachedManifest? {
    guard let data = try? Data(contentsOf: url(for: provider)) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard
      let entry = try? decoder.decode(CachedManifest.self, from: data),
      entry.schema == CachedManifest.currentSchema
    else { return nil }
    return entry
  }

  /// Saves `profiles` as the manifest fetched at `fetchedAt` — atomically, 0600, the directory
  /// 0700. Callers skip an empty manifest: a glitch that listed nothing must not stand in for a
  /// day.
  public func store(provider: String, profiles: [ModelProfile], at fetchedAt: Date = Date()) throws {
    let entry = CachedManifest(provider: provider, fetchedAt: fetchedAt, profiles: profiles)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
    try SecureFiles.writePrivate(try encoder.encode(entry), to: url(for: provider))
  }

  /// Seconds since the entry was fetched (never negative — a clock that moved back reads as 0).
  public func age(of entry: CachedManifest, now: Date = Date()) -> TimeInterval {
    max(0, now.timeIntervalSince(entry.fetchedAt))
  }

  /// Whether the entry is still served without a fetch.
  public func isFresh(_ entry: CachedManifest, now: Date = Date()) -> Bool {
    age(of: entry, now: now) <= policy.ttl
  }

  /// `just now` · `3 min` · `2 h` · `5 d` — how the CLI says how old a cached manifest is.
  public static func describeAge(_ interval: TimeInterval) -> String {
    let seconds = max(0, interval)
    switch seconds {
    case ..<60: return "just now"
    case ..<3600: return "\(Int(seconds / 60)) min"
    case ..<86400: return "\(Int(seconds / 3600)) h"
    default: return "\(Int(seconds / 86400)) d"
    }
  }

  /// The same age as a phrase: `just now` · `3 min ago` · `2 h ago` — what follows "cached" or
  /// "fetched" in a status line.
  public static func describeAgeAgo(_ interval: TimeInterval) -> String {
    let age = describeAge(interval)
    return age == "just now" ? age : "\(age) ago"
  }
}
