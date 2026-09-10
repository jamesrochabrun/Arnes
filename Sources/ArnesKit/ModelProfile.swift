import Foundation
import OpenRouterSwift

/// What Arnes knows about a model before shaping a request for it.
/// Built from OpenRouter's live model manifest (`GET /models`) — never hardcoded. `Codable` so
/// the catalog can keep a fetched manifest between processes (`ManifestCache`); the JSON
/// listings still go through their own DTO (`ModelRow`), so a field added here reaches the
/// cache file and never the `--json` contract on its own.
public struct ModelProfile: Codable, Sendable {
  public let id: String
  public let family: ModelFamily
  public let dialect: Dialect
  public let contextLength: Int?
  public let supportsTools: Bool
  public let supportsReasoning: Bool
  public let supportsStructuredOutputs: Bool
  /// USD per prompt token, from the manifest's pricing strings.
  public let promptPricePerToken: Double?
  public let completionPricePerToken: Double?
  /// The most output tokens one response may carry (OpenRouter `top_provider.max_completion_tokens`;
  /// LiteLLM `max_tokens` beside `max_input_tokens`). nil when the manifest doesn't say — the
  /// `/messages` `max_tokens` then keeps its pre-manifest default.
  public let maxCompletionTokens: Int?
  /// Whether the manifest advertises the chat `max_completion_tokens` spelling. nil for
  /// sparse manifests and older cache rows, which use the provider's default spelling.
  public let supportsMaxCompletionTokens: Bool?
  /// Whether the model takes images as input (OpenRouter `architecture.input_modalities` contains
  /// `image` — or, for an older manifest, the `modality` string's input side does; LiteLLM
  /// `supports_vision`). What gates the `view_image` tool. **The one capability assumed off when
  /// the manifest is silent** (`unknownModelId`, a LiteLLM row without the key): every other bit
  /// is assumed on so a sparse gateway never disables the loop, but an image sent to a text-only
  /// model fails the *whole* request, so the safe assumption is "no images" — the tool is simply
  /// absent, and a run works exactly as it did before the tool existed.
  public let supportsVision: Bool

  public init(model: OpenRouterModel) {
    id = model.id
    family = ModelFamily(modelId: model.id)
    dialect = family.preferredDialect
    contextLength = model.contextLength
    let parameters = Set(model.supportedParameters ?? [])
    supportsTools = parameters.contains("tools")
    supportsReasoning = parameters.contains("reasoning") || parameters.contains("include_reasoning")
    supportsStructuredOutputs = parameters.contains("response_format")
      || parameters.contains("structured_outputs")
    promptPricePerToken = Self.price(model.pricing?.prompt)
    completionPricePerToken = Self.price(model.pricing?.completion)
    maxCompletionTokens = model.topProvider?.maxCompletionTokens
    supportsMaxCompletionTokens = model.supportedParameters.map { $0.contains("max_completion_tokens") }
    supportsVision = Self.acceptsImages(model.architecture)
  }

  /// A manifest price, or nil when the manifest isn't stating one. A router alias prices its
  /// tokens as `-1` (OpenRouter's "varies with the model it picks"), and a negative or
  /// non-finite price is not a price: left in, it makes an estimate *negative*, which walks the
  /// session's spend backwards and stops `--budget` from ever tripping. Cost still comes from
  /// the provider's `usage.cost` first (`Session.cost(of:model:)`); this only governs the
  /// fallback estimate, which now declines to guess instead of guessing a refund.
  static func price(_ raw: String?) -> Double? {
    raw.flatMap(Double.init).flatMap(usablePrice)
  }

  /// The numeric half of `price(_:)`, shared with the gateway manifest path.
  static func usablePrice(_ value: Double) -> Double? {
    value.isFinite && value >= 0 ? value : nil
  }

  /// `input_modalities` when the manifest has it; else the input side of the legacy `modality`
  /// string (`text+image->text`). Neither → false.
  static func acceptsImages(_ architecture: OpenRouterModel.Architecture?) -> Bool {
    if let modalities = architecture?.inputModalities {
      return modalities.contains { $0.lowercased() == "image" }
    }
    guard let modality = architecture?.modality?.lowercased() else { return false }
    let input = modality.components(separatedBy: "->").first ?? modality
    return input.split(separator: "+").contains { $0.trimmingCharacters(in: .whitespaces) == "image" }
  }

  /// A profile from another router's manifest (LiteLLM `/model/info`, …). The family
  /// defaults to what the id's author prefix says; pass one when the manifest knows
  /// better (a gateway alias like `sonnet` carries no prefix).
  public init(
    id: String,
    family: ModelFamily? = nil,
    contextLength: Int?,
    supportsTools: Bool,
    supportsReasoning: Bool,
    supportsStructuredOutputs: Bool,
    promptPricePerToken: Double?,
    completionPricePerToken: Double?,
    maxCompletionTokens: Int? = nil,
    supportsVision: Bool = false,
    supportsMaxCompletionTokens: Bool? = nil)
  {
    self.id = id
    let resolvedFamily = family ?? ModelFamily(modelId: id)
    self.family = resolvedFamily
    dialect = resolvedFamily.preferredDialect
    self.contextLength = contextLength
    self.supportsTools = supportsTools
    self.supportsReasoning = supportsReasoning
    self.supportsStructuredOutputs = supportsStructuredOutputs
    self.promptPricePerToken = promptPricePerToken
    self.completionPricePerToken = completionPricePerToken
    self.maxCompletionTokens = maxCompletionTokens
    self.supportsVision = supportsVision
    self.supportsMaxCompletionTokens = supportsMaxCompletionTokens
  }

  /// Minimal profile for a model the manifest doesn't know (`openrouter/auto`, a gateway
  /// alias, or any model when the manifest is unavailable): tool support assumed, the
  /// family inferred from the name (so `claude-…` still gets `/messages`), no pricing — and
  /// **no vision**: the documented exception to "assume on" (see `supportsVision`).
  public init(unknownModelId: String) {
    id = unknownModelId
    let inferred = ModelFamily(inferringFrom: unknownModelId)
    family = inferred
    dialect = inferred.preferredDialect
    contextLength = nil
    supportsTools = true
    supportsReasoning = false
    supportsStructuredOutputs = false
    promptPricePerToken = nil
    completionPricePerToken = nil
    maxCompletionTokens = nil
    supportsMaxCompletionTokens = nil
    supportsVision = false
  }
}

/// Where the profiles a catalog serves came from.
public enum ManifestSource: Sendable, Equatable {
  /// Fetched from the provider in this process (and saved to the cache, when there is one).
  case network
  /// Served from the cache without a fetch — the copy was within its TTL.
  case cache(fetchedAt: Date)
  /// The fetch failed and the cached copy, past its TTL or not, stands in for it
  /// (`manifestFailure` says why the fetch failed).
  case staleCache(fetchedAt: Date)
}

/// Fetches and caches model profiles from a manifest — OpenRouter's `GET /models` by
/// default, or whatever the provider's loader returns (a LiteLLM `/model/info` page).
/// The loop never asks anything else about a model. With a `ManifestCache` the manifest is
/// also kept **between processes**: a copy within its TTL is served without a fetch (the
/// startup round trip every command used to pay), a copy past it is the fallback when the
/// fetch fails, and an id the cached copy doesn't know earns one refetch per process (a model
/// newer than the copy). `refresh()` forces the network (`arnes models --refresh`).
public actor ModelCatalog {
  public typealias Loader = @Sendable () async throws -> [ModelProfile]

  private let loader: Loader
  /// User-defined short names → model ids (see `ProviderConfig.aliases`). Resolved
  /// before any manifest lookup, so they work even when the manifest is unavailable.
  public let aliases: [String: String]
  private let cache: ManifestCache?
  /// The cache entry this catalog reads and writes — the provider's name in the CLI.
  private let cacheKey: String
  private var profiles: [String: ModelProfile] = [:]
  private var loaded = false
  private var failure: Error?
  /// Set once the cached copy has been checked against the network for an unknown id.
  private var refetchedForMiss = false

  /// Where the served profiles came from; nil until the first lookup, and after a fetch that
  /// failed with nothing cached to fall back on.
  public private(set) var manifestSource: ManifestSource?

  /// Why the manifest couldn't be fetched, when it couldn't. The loop keeps running on
  /// assumed capabilities — or on the cached copy (`manifestSource == .staleCache`) — and the
  /// CLI surfaces this once so a wrong base URL or key is visible instead of silently
  /// degrading every model to "unknown".
  public var manifestFailure: String? {
    failure.map { "\($0)" }
  }

  /// The OpenRouter manifest.
  public init(
    service: OpenRouterService, aliases: [String: String] = [:],
    cache: ManifestCache? = nil, cacheKey: String = "openrouter")
  {
    loader = { try await service.models().map { ModelProfile(model: $0) } }
    self.aliases = aliases
    self.cache = cache
    self.cacheKey = cacheKey
  }

  /// Any other manifest source (fetched once, on first use).
  public init(
    loader: @escaping Loader, aliases: [String: String] = [:],
    cache: ManifestCache? = nil, cacheKey: String = "manifest")
  {
    self.loader = loader
    self.aliases = aliases
    self.cache = cache
    self.cacheKey = cacheKey
  }

  /// The model id behind a configured alias (case-insensitive); `name` itself otherwise.
  public nonisolated func resolve(_ name: String) -> String {
    let lowered = name.lowercased()
    return aliases.first { $0.key.lowercased() == lowered }?.value ?? name
  }

  /// The profile for a model id or alias. Unknown ids get an assumed profile; the
  /// returned profile's `id` is always the id to send on the wire. An id the **cached** copy
  /// doesn't know may be newer than the copy, so it earns one fetch per process before the
  /// assumed profile stands (`openrouter/auto` and a gateway alias cost that one fetch and are
  /// then unknown as before); a copy fetched this process, or one standing in for a failed
  /// fetch, is not asked again.
  public func profile(for modelId: String) async throws -> ModelProfile {
    try await loadIfNeeded()
    let id = resolve(modelId)
    if profiles[id] == nil, !refetchedForMiss, case .cache? = manifestSource {
      refetchedForMiss = true
      await refresh()
    }
    return profiles[id] ?? ModelProfile(unknownModelId: id)
  }

  /// Fetches the manifest now, whatever the cache says (`arnes models --refresh`), and saves
  /// it. A failure is remembered in `manifestFailure` like a first load's; the profiles already
  /// served stay, and with nothing served yet the cached copy — however old — stands in.
  public func refresh() async {
    loaded = true
    refetchedForMiss = true
    do {
      let fetched = try await loader()
      profiles = Dictionary(fetched.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      failure = nil
      manifestSource = .network
      // Never cache an empty manifest: a glitch that listed nothing must not stand in for a day.
      if !fetched.isEmpty {
        try? cache?.store(provider: cacheKey, profiles: fetched)
      }
    } catch {
      // Unavailable manifest ≠ unusable provider: every model falls back to
      // `ModelProfile(unknownModelId:)` — or to the cached copy. Remembered, not retried per request.
      failure = error
      if profiles.isEmpty, let entry = cache?.load(provider: cacheKey) {
        profiles = Dictionary(entry.profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        manifestSource = .staleCache(fetchedAt: entry.fetchedAt)
      }
    }
  }

  /// Every profile in the manifest, sorted by id.
  public func all() async throws -> [ModelProfile] {
    try await loadIfNeeded()
    return profiles.values.sorted { $0.id < $1.id }
  }

  /// Fuzzy model lookup for `/model`. Ranks exact id > id prefix > substring >
  /// character subsequence (`son5` matches `anthropic/claude-sonnet-5`); ties break
  /// toward shorter ids. Manifest-driven only — never hardcoded.
  public func search(_ query: String, limit: Int = 10) async throws -> [ModelProfile] {
    try await loadIfNeeded()
    let normalized = query.lowercased()
    guard !normalized.isEmpty else { return [] }
    // A configured alias is the user's explicit answer — it outranks every manifest match
    // and is the only thing that can resolve a short name when the manifest is missing.
    if aliases.keys.contains(where: { $0.lowercased() == normalized }) {
      let target = resolve(query)
      let resolved = profiles[target] ?? ModelProfile(unknownModelId: target)
      return [resolved]
    }
    let ranked: [(score: Int, profile: ModelProfile)] = profiles.values.compactMap { profile in
      let id = profile.id.lowercased()
      if id == normalized { return (0, profile) }
      if id.hasPrefix(normalized) { return (1, profile) }
      if id.contains(normalized) { return (2, profile) }
      if isSubsequence(normalized, of: id) { return (3, profile) }
      return nil
    }
    return ranked
      .sorted {
        ($0.score, $0.profile.id.count, $0.profile.id)
          < ($1.score, $1.profile.id.count, $1.profile.id)
      }
      .prefix(limit)
      .map(\.profile)
  }

  private func loadIfNeeded() async throws {
    guard !loaded else { return }
    loaded = true
    if let cache, let entry = cache.load(provider: cacheKey), cache.isFresh(entry) {
      profiles = Dictionary(entry.profiles.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
      manifestSource = .cache(fetchedAt: entry.fetchedAt)
      return
    }
    await refresh()
  }

  private func isSubsequence(_ needle: String, of haystack: String) -> Bool {
    var iterator = needle.makeIterator()
    var current = iterator.next()
    for character in haystack {
      if character == current {
        current = iterator.next()
        if current == nil { return true }
      }
    }
    return current == nil
  }
}
