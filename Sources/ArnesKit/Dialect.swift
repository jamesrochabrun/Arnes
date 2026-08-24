import Foundation

/// The wire format Arnes speaks to a model. The core Arnes principle is
/// **dialect-native transport**: talk to every model in its home format so
/// nothing is lost in translation.
///
/// v0 executes all agent loops over `.chat` (OpenRouter normalizes it for every
/// model); `.messages` and `.responses` become the native paths for Anthropic
/// and OpenAI families as the loop matures. `preferredDialect` already reports
/// the target dialect so callers can route ahead of that switch.
public enum Dialect: String, Sendable {
  /// OpenAI chat-completions shape — the universal default.
  case chat
  /// Anthropic Messages shape — native for `anthropic/*` models.
  case messages
  /// OpenResponses shape — native for `openai/*` models.
  case responses
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
