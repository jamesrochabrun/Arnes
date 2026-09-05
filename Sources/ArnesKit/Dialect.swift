import Foundation

/// The wire format Arnes speaks to a model. The core Arnes principle is
/// **dialect-native transport**: talk to every model in its home format so
/// nothing is lost in translation.
///
/// The agent loop executes all three: `.chat` is the universal default, and
/// `.messages`/`.responses` are the native paths for the Anthropic and OpenAI
/// families. History stays chat-shaped internally and is translated per request,
/// which is what keeps mid-session `/model` swaps working across dialects.
public enum Dialect: String, Codable, Sendable {
  /// OpenAI chat-completions shape — the universal default.
  case chat
  /// Anthropic Messages shape — native for `anthropic/*` models.
  case messages
  /// OpenResponses shape — native for `openai/*` models.
  case responses
}

/// How a session picks the wire dialect for each turn. `.auto` follows the model's
/// `ModelProfile.dialect` (native for known families, chat otherwise); the forced
/// modes exist for A/B evals and debugging.
public enum DialectOverride: String, Sendable, CaseIterable {
  case auto
  case chat
  case messages
  case responses

  /// The dialect to execute for `profile`, honoring the override.
  public func effective(for profile: ModelProfile) -> Dialect {
    switch self {
    case .auto: return profile.dialect
    case .chat: return .chat
    case .messages: return .messages
    case .responses: return .responses
    }
  }
}

/// A model family, inferred from the OpenRouter slug's author prefix.
/// Prompt packs and dialects key off this.
public enum ModelFamily: String, Codable, Sendable {
  case anthropic
  case openai
  case google
  case xai
  case meta
  case deepseek
  case mistral
  case qwen
  case other

  public init(modelId: String) {
    let author = modelId.split(separator: "/").first.map(String.init)?.lowercased() ?? ""
    switch author {
    case "anthropic": self = .anthropic
    case "openai": self = .openai
    case "google": self = .google
    case "x-ai": self = .xai
    case "meta-llama": self = .meta
    case "deepseek": self = .deepseek
    case "mistralai": self = .mistral
    case "qwen": self = .qwen
    default: self = .other
    }
  }

  /// Family for routers whose model names carry no author prefix — LiteLLM aliases
  /// like `sonnet`, deployments like `bedrock/anthropic.claude-3-7-sonnet` or
  /// `azure/gpt-4o-prod`. Well-known name stems win (a Bedrock or Vertex deployment
  /// can host any family), then the router's provider tag, then the author-prefix rule.
  /// Still a name→family mapping, not a capability: those keep coming from the manifest.
  public init(inferringFrom name: String, provider: String? = nil) {
    let tokens = name.lowercased()
      .split(whereSeparator: { "/-_.:@ ".contains($0) })
      .map(String.init)
    if let fromName = tokens.lazy.compactMap(Self.family(forToken:)).first {
      self = fromName
      return
    }
    switch provider?.lowercased() {
    case "anthropic": self = .anthropic
    case "openai", "azure", "azure_ai": self = .openai
    case "gemini", "google", "vertex_ai", "google_ai_studio": self = .google
    case "xai": self = .xai
    case "meta", "meta_llama": self = .meta
    case "deepseek": self = .deepseek
    case "mistral": self = .mistral
    case "qwen": self = .qwen
    default: self = ModelFamily(modelId: name)
    }
  }

  private static func family(forToken token: String) -> ModelFamily? {
    if token.hasPrefix("claude") { return .anthropic }
    if token.hasPrefix("gpt") || ["o1", "o3", "o4", "o5", "chatgpt", "codex"].contains(token) { return .openai }
    if token.hasPrefix("gemini") || token.hasPrefix("gemma") { return .google }
    if token.hasPrefix("grok") { return .xai }
    if token.hasPrefix("llama") { return .meta }
    if token.hasPrefix("deepseek") { return .deepseek }
    if ["mistral", "mixtral", "codestral", "ministral", "magistral", "pixtral"].contains(where: token.hasPrefix) { return .mistral }
    if token.hasPrefix("qwen") || token.hasPrefix("qwq") { return .qwen }
    return nil
  }

  /// The dialect this family speaks natively.
  public var preferredDialect: Dialect {
    switch self {
    case .anthropic: return .messages
    case .openai: return .responses
    default: return .chat
    }
  }
}
