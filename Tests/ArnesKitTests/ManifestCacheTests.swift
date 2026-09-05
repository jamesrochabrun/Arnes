import XCTest
@testable import ArnesKit

/// Cached model profiles: the catalog serves a fresh disk copy without a fetch, falls back to a
/// stale one when the fetch fails, refetches once for an id the copy doesn't know, and
/// `refresh()` forces the network. The cache file itself round-trips every profile field.
final class ManifestCacheTests: XCTestCase {
  /// Counts the fetches a catalog makes and answers with a fixed manifest (or a failure).
  private final class CountingLoader: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var profiles: [ModelProfile]
    var error: Error?

    init(_ profiles: [ModelProfile], error: Error? = nil) {
      self.profiles = profiles
      self.error = error
    }

    var calls: Int { lock.withLock { count } }

    func load() async throws -> [ModelProfile] {
      lock.withLock { count += 1 }
      if let error { throw error }
      return profiles
    }
  }

  private struct Unreachable: Error {}

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("arnes-manifest-cache-\(UUID().uuidString)")
  }

  private func profile(_ id: String, context: Int = 8000, vision: Bool = false) -> ModelProfile {
    ModelProfile(
      id: id, contextLength: context, supportsTools: true, supportsReasoning: id.contains("think"),
      supportsStructuredOutputs: true, promptPricePerToken: 0.000001, completionPricePerToken: 0.000002,
      maxCompletionTokens: 4096, supportsVision: vision)
  }

  private func catalog(_ loader: CountingLoader, cache: ManifestCache?, key: String = "gateway") -> ModelCatalog {
    ModelCatalog(loader: { try await loader.load() }, cache: cache, cacheKey: key)
  }

  // MARK: The file

  func testStoreAndLoadRoundTripEveryProfileFieldAtOwnerOnlyPermissions() throws {
    let directory = tempDirectory()
    let cache = ManifestCache(directory: directory)
    let profiles = [profile("anthropic/claude-test", vision: true), profile("deepseek/think-test", context: 64000)]
    let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    try cache.store(provider: "gateway", profiles: profiles, at: fetchedAt)

    let entry = try XCTUnwrap(cache.load(provider: "gateway"))
    XCTAssertEqual(entry.schema, CachedManifest.currentSchema)
    XCTAssertEqual(entry.provider, "gateway")
    XCTAssertEqual(entry.fetchedAt.timeIntervalSince1970, fetchedAt.timeIntervalSince1970, accuracy: 1)
    XCTAssertEqual(entry.profiles.map(\.id), profiles.map(\.id))
    let restored = try XCTUnwrap(entry.profiles.first)
    XCTAssertEqual(restored.family, .anthropic)
    XCTAssertEqual(restored.dialect, .messages)
    XCTAssertEqual(restored.contextLength, 8000)
    XCTAssertTrue(restored.supportsVision)
    XCTAssertEqual(restored.maxCompletionTokens, 4096)
    XCTAssertEqual(restored.promptPricePerToken, 0.000001)
    XCTAssertEqual(entry.profiles[1].supportsReasoning, true)
    let url = cache.url(for: "gateway")
    XCTAssertEqual(url.lastPathComponent, "gateway.json")
    let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    XCTAssertEqual(fileMode, 0o600)
    let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
    XCTAssertEqual(directoryMode, 0o700)
  }

  func testFileNamesAreSanitizedAndUnreadableOrForeignSchemaFilesAreMisses() throws {
    XCTAssertEqual(ManifestCache.fileName(for: "openrouter"), "openrouter.json")
    XCTAssertEqual(ManifestCache.fileName(for: "my gateway/v1"), "my-gateway-v1.json")
    XCTAssertEqual(ManifestCache.fileName(for: "../etc"), "..-etc.json")
    XCTAssertEqual(ManifestCache.fileName(for: ""), "manifest.json")

    let cache = ManifestCache(directory: tempDirectory())
    XCTAssertNil(cache.load(provider: "never-written"))
    try SecureFiles.writePrivate(Data("not json".utf8), to: cache.url(for: "corrupt"))
    XCTAssertNil(cache.load(provider: "corrupt"))
    let other = #"{"schema": 99, "provider": "x", "fetchedAt": "2026-01-01T00:00:00Z", "profiles": []}"#
    try SecureFiles.writePrivate(Data(other.utf8), to: cache.url(for: "future"))
    XCTAssertNil(cache.load(provider: "future"), "another schema is a miss, never an error")
  }

  func testFreshnessAndAgeText() throws {
    let cache = ManifestCache(directory: tempDirectory(), policy: ManifestCachePolicy(ttl: 3600))
    let now = Date()
    let fresh = CachedManifest(provider: "p", fetchedAt: now.addingTimeInterval(-1800), profiles: [])
    let stale = CachedManifest(provider: "p", fetchedAt: now.addingTimeInterval(-7200), profiles: [])
    XCTAssertTrue(cache.isFresh(fresh, now: now))
    XCTAssertFalse(cache.isFresh(stale, now: now))
    XCTAssertEqual(cache.age(of: stale, now: now), 7200, accuracy: 0.001)
    XCTAssertEqual(cache.age(of: CachedManifest(provider: "p", fetchedAt: now.addingTimeInterval(60), profiles: []), now: now), 0, "a clock that moved back reads as now")
    XCTAssertEqual(ManifestCache.describeAge(5), "just now")
    XCTAssertEqual(ManifestCache.describeAge(180), "3 min")
    XCTAssertEqual(ManifestCache.describeAge(7200), "2 h")
    XCTAssertEqual(ManifestCache.describeAge(5 * 86400), "5 d")
    XCTAssertEqual(ManifestCache.describeAgeAgo(5), "just now", "never `just now ago`")
    XCTAssertEqual(ManifestCache.describeAgeAgo(7200), "2 h ago")
    XCTAssertEqual(ManifestCachePolicy(ttl: -5).ttl, 0)
  }

  // MARK: The catalog

  func testAFreshCopyIsServedWithoutAFetchAndAFetchWritesTheCopy() async throws {
    let directory = tempDirectory()
    let cache = ManifestCache(directory: directory)
    let loader = CountingLoader([profile("anthropic/claude-test"), profile("openai/gpt-test")])

    // First process: nothing cached — the network answers and the copy is written.
    let first = catalog(loader, cache: cache)
    let all = try await first.all()
    XCTAssertEqual(all.map(\.id), ["anthropic/claude-test", "openai/gpt-test"])
    XCTAssertEqual(loader.calls, 1)
    let source = await first.manifestSource
    XCTAssertEqual(source, .network)
    XCTAssertNotNil(cache.load(provider: "gateway"))

    // Second process: the copy is fresh — served from disk, the loader never asked.
    let second = catalog(loader, cache: cache)
    let served = try await second.profile(for: "openai/gpt-test")
    XCTAssertEqual(served.id, "openai/gpt-test")
    XCTAssertEqual(served.family, .openai)
    XCTAssertEqual(loader.calls, 1, "no fetch for a fresh copy")
    guard case .cache? = await second.manifestSource else { return XCTFail("served from the cache") }
    let failure = await second.manifestFailure
    XCTAssertNil(failure)
    // Search and the listing read the same copy.
    let found = try await second.search("claude")
    XCTAssertEqual(found.map(\.id), ["anthropic/claude-test"])
    XCTAssertEqual(loader.calls, 1)
  }

  func testAnUnknownIdOnACachedCopyEarnsOneRefetchPerProcess() async throws {
    let cache = ManifestCache(directory: tempDirectory())
    try cache.store(provider: "gateway", profiles: [profile("anthropic/claude-test")])
    // The provider has since added a model the copy doesn't know.
    let loader = CountingLoader([profile("anthropic/claude-test"), profile("anthropic/claude-new")])
    let catalog = catalog(loader, cache: cache)

    let known = try await catalog.profile(for: "anthropic/claude-test")
    XCTAssertEqual(known.id, "anthropic/claude-test")
    XCTAssertEqual(loader.calls, 0, "a known id never fetches")

    let fresh = try await catalog.profile(for: "anthropic/claude-new")
    XCTAssertEqual(loader.calls, 1, "the miss fetched once")
    XCTAssertEqual(fresh.contextLength, 8000, "the refetched manifest knows it — not the assumed profile")
    let source = await catalog.manifestSource
    XCTAssertEqual(source, .network)
    XCTAssertEqual(cache.load(provider: "gateway")?.profiles.count, 2, "the copy was rewritten")

    let unknown = try await catalog.profile(for: "openrouter/auto")
    XCTAssertNil(unknown.contextLength, "still unknown after the refetch — the assumed profile")
    XCTAssertEqual(loader.calls, 1, "one refetch per process, not one per unknown id")
  }

  func testAStaleCopyStandsInForAFailedFetchAndAnExpiredCopyIsRefetched() async throws {
    let directory = tempDirectory()
    let cache = ManifestCache(directory: directory, policy: ManifestCachePolicy(ttl: 60))
    try cache.store(provider: "gateway", profiles: [profile("anthropic/claude-test")], at: Date().addingTimeInterval(-3600))

    // Expired and the network is up: refetched, the copy rewritten.
    let refreshed = catalog(CountingLoader([profile("anthropic/claude-test"), profile("x/y")]), cache: cache)
    let count = try await refreshed.all().count
    XCTAssertEqual(count, 2)
    XCTAssertTrue(cache.isFresh(try XCTUnwrap(cache.load(provider: "gateway"))))

    // Expired and the network is down: the old copy stands in, and the failure is still said.
    let old = ManifestCache(directory: tempDirectory(), policy: ManifestCachePolicy(ttl: 60))
    try old.store(provider: "gateway", profiles: [profile("anthropic/claude-test")], at: Date().addingTimeInterval(-3600))
    let loader = CountingLoader([], error: Unreachable())
    let fallback = catalog(loader, cache: old)
    let served = try await fallback.profile(for: "anthropic/claude-test")
    XCTAssertEqual(served.contextLength, 8000, "the cached profile, not the assumed one")
    XCTAssertEqual(loader.calls, 1)
    guard case .staleCache? = await fallback.manifestSource else { return XCTFail("the stale copy stood in") }
    let failure = await fallback.manifestFailure
    XCTAssertNotNil(failure, "the fetch failure is still reported")
    _ = try await fallback.profile(for: "never/heard")
    XCTAssertEqual(loader.calls, 1, "a miss on a stale copy does not refetch — the network just failed")

    // Nothing cached and the network is down: the pre-cache behavior, byte for byte.
    let bare = catalog(CountingLoader([], error: Unreachable()), cache: ManifestCache(directory: tempDirectory()))
    let assumed = try await bare.profile(for: "anthropic/claude-test")
    XCTAssertNil(assumed.contextLength)
    XCTAssertTrue(assumed.supportsTools)
    let bareSource = await bare.manifestSource
    XCTAssertNil(bareSource)
    let bareFailure = await bare.manifestFailure
    XCTAssertNotNil(bareFailure)
  }

  func testAnEmptyManifestIsNeverCachedAndRefreshForcesTheNetwork() async throws {
    let cache = ManifestCache(directory: tempDirectory())
    let empty = catalog(CountingLoader([]), cache: cache)
    _ = try await empty.all()
    XCTAssertNil(cache.load(provider: "gateway"), "a manifest that listed nothing is not kept")

    try cache.store(provider: "gateway", profiles: [profile("anthropic/claude-test")])
    let loader = CountingLoader([profile("anthropic/claude-test"), profile("anthropic/claude-new")])
    let catalog = catalog(loader, cache: cache)
    _ = try await catalog.all()
    XCTAssertEqual(loader.calls, 0)
    await catalog.refresh()
    XCTAssertEqual(loader.calls, 1, "refresh fetches whatever the copy's age")
    let count = try await catalog.all().count
    XCTAssertEqual(count, 2)
    XCTAssertEqual(cache.load(provider: "gateway")?.profiles.count, 2)
    let source = await catalog.manifestSource
    XCTAssertEqual(source, .network)
  }

  func testACatalogWithoutACacheIsExactlyThePreCacheCatalog() async throws {
    let loader = CountingLoader([profile("anthropic/claude-test")])
    let catalog = ModelCatalog(loader: { try await loader.load() })
    _ = try await catalog.profile(for: "anthropic/claude-test")
    _ = try await catalog.profile(for: "unknown/x")
    _ = try await catalog.all()
    XCTAssertEqual(loader.calls, 1, "one fetch per process, no refetch on a miss without a cache")
    let source = await catalog.manifestSource
    XCTAssertEqual(source, .network)
  }

  // MARK: Config

  func testManifestCacheConfigDecodesAndMapsToAPolicy() throws {
    let absent = try JSONDecoder().decode(PoliciesConfig.self, from: Data("{}".utf8))
    XCTAssertNil(absent.manifestCache)
    let off = try JSONDecoder().decode(PoliciesConfig.self, from: Data(#"{"manifestCache": {"enabled": false}}"#.utf8))
    XCTAssertNil(off.manifestCache?.policy)
    XCTAssertEqual(off.manifestCache?.isEnabled, false)
    let hour = try JSONDecoder().decode(PoliciesConfig.self, from: Data(#"{"manifestCache": {"ttlHours": 1}}"#.utf8))
    XCTAssertEqual(hour.manifestCache?.policy?.ttl, 3600)
    let defaults = try JSONDecoder().decode(PoliciesConfig.self, from: Data(#"{"manifestCache": {}}"#.utf8))
    XCTAssertEqual(defaults.manifestCache?.policy?.ttl, ManifestCachePolicy.defaultTTL)
  }
}
