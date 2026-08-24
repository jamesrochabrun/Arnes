import Foundation

/// The wire format Arnes speaks to a model. The core Arnes principle is
/// **dialect-native transport**: talk to every model in its home format so
/// nothing is lost in translation.
///
/// The agent loop executes all three: `.chat` is the universal default, and
/// `.messages`/`.responses` are the native paths for the Anthropic and OpenAI
/// families. History stays chat-shaped internally and is translated per request,
/// which is what keeps mid-session `/model` swaps working across dialects.
public enum Dialect: String, Sendable {
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
public enum ModelFamily: String, Sendable {
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

  /// The dialect this family speaks natively.
  public var preferredDialect: Dialect {
    switch self {
    case .anthropic: return .messages
    case .openai: return .responses
    default: return .chat
    }
  }
}
