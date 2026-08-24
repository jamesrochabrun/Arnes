import Foundation
import OpenRouterSwift

/// What Arnes knows about a model before shaping a request for it.
/// Built from OpenRouter's live model manifest (`GET /models`) — never hardcoded.
public struct ModelProfile: Sendable {
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
    promptPricePerToken = model.pricing?.prompt.flatMap(Double.init)
    completionPricePerToken = model.pricing?.completion.flatMap(Double.init)
  }

  /// Minimal profile for a model not found in the manifest (e.g. `openrouter/auto`):
  /// assume the universal dialect and tool support, let the router sort out the rest.
  public init(unknownModelId: String) {
    id = unknownModelId
    family = ModelFamily(modelId: unknownModelId)
    dialect = .chat
    contextLength = nil
    supportsTools = true
    supportsReasoning = false
    supportsStructuredOutputs = false
    promptPricePerToken = nil
    completionPricePerToken = nil
  }
}

/// Fetches and caches model profiles from the OpenRouter manifest.
public actor ModelCatalog {
  private let service: OpenRouterService
  private var profiles: [String: ModelProfile] = [:]
  private var loaded = false

  public init(service: OpenRouterService) {
    self.service = service
  }

  public func profile(for modelId: String) async throws -> ModelProfile {
    try await loadIfNeeded()
    return profiles[modelId] ?? ModelProfile(unknownModelId: modelId)
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
    let models = try await service.models()
    for model in models {
      profiles[model.id] = ModelProfile(model: model)
    }
    loaded = true
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
