import Foundation
import SwiftOpenAI

// MARK: - GatewayHTTPClient

/// Points OpenRouterSwift at another API root.
///
/// The client builds every URL as `https://openrouter.ai/api/v1/<endpoint>`; this wrapper
/// swaps scheme, host, port, and the `/api/v1` prefix for the provider's root
/// (`https://llm-gateway.example.com/v1`) and hands the request on unchanged otherwise.
/// It is the injectable `OpenRouterHTTPClient` seam doing exactly what it exists for —
/// bodies and responses are never touched. The proper home for a base-path option is
/// OpenRouterSwift's configuration; until it grows one, this is the whole bridge.
public final class GatewayHTTPClient: HTTPClient, @unchecked Sendable {
  private let root: URL
  private let base: any HTTPClient
  private let tokens: BearerTokenSource?

  /// - Parameters:
  ///   - root: the provider's API root, version segment included.
  ///   - base: the client that performs the rewritten requests (platform default when nil).
  ///   - tokens: when set, every request carries a freshly minted bearer token instead
  ///     of the static one the transport was built with.
  public init(root: URL, base: (any HTTPClient)? = nil, tokens: BearerTokenSource? = nil) {
    self.root = root
    self.base = base ?? HTTPClientFactory.createDefault()
    self.tokens = tokens
  }

  public func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    try await base.data(for: try await prepare(request))
  }

  public func bytes(for request: HTTPRequest) async throws -> (HTTPByteStream, HTTPResponse) {
    try await base.bytes(for: try await prepare(request))
  }

  func prepare(_ request: HTTPRequest) async throws -> HTTPRequest {
    var prepared = rewrite(request)
    if let tokens {
      prepared.headers["Authorization"] = "Bearer \(try await tokens.token())"
    }
    return prepared
  }

  func rewrite(_ request: HTTPRequest) -> HTTPRequest {
    var rewritten = request
    rewritten.url = Self.rewrite(url: request.url, root: root)
    return rewritten
  }

  private static let openRouterPrefix = "/api/v1"

  /// `https://openrouter.ai/api/v1/chat/completions?x=1` → `<root>/chat/completions?x=1`.
  /// Paths without the OpenRouter prefix are appended to the root as they are.
  static func rewrite(url: URL, root: URL) -> URL {
    guard
      var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
      let rootComponents = URLComponents(url: root, resolvingAgainstBaseURL: false)
    else {
      return url
    }
    var path = components.path
    if path.hasPrefix(openRouterPrefix) {
      path.removeFirst(openRouterPrefix.count)
    }
    var rootPath = rootComponents.path
    while rootPath.hasSuffix("/") { rootPath.removeLast() }
    components.scheme = rootComponents.scheme
    components.host = rootComponents.host
    components.port = rootComponents.port
    components.user = nil
    components.password = nil
    components.path = rootPath + (path.hasPrefix("/") ? path : "/" + path)
    return components.url ?? url
  }
}

// MARK: - BearerTokenSource

/// A bearer token that expires — a Google IAP identity token, an OIDC token from a
/// corporate gateway. `command` prints a fresh one; the source caches it and re-runs the
/// command a minute before a JWT's `exp` (or after `ttl` for opaque tokens). Requests ask
/// for `token()` every time, so a session that outlives the token keeps working.
public actor BearerTokenSource {
  private let command: String
  private let ttl: TimeInterval
  private let environment: [String: String]
  private var cached: (token: String, refreshAfter: Date)?

  public init(
    command: String,
    ttl: TimeInterval = 50 * 60,
    environment: [String: String] = ProcessInfo.processInfo.environment)
  {
    self.command = command
    self.ttl = ttl
    self.environment = environment
  }

  public func token() async throws -> String {
    if let cached, cached.refreshAfter > Date() {
      return cached.token
    }
    let token = try Self.run(command: command, environment: environment)
    let refreshAfter = Self.expiry(ofJWT: token)?.addingTimeInterval(-60)
      ?? Date().addingTimeInterval(ttl)
    cached = (token, refreshAfter)
    return token
  }

  /// The `exp` claim of a JWT; nil for anything that isn't one.
  public static func expiry(ofJWT token: String) -> Date? {
    let parts = token.split(separator: ".")
    guard parts.count == 3 else { return nil }
    var payload = String(parts[1])
      .replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    while payload.count % 4 != 0 { payload += "=" }
    guard
      let data = Data(base64Encoded: payload),
      let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let exp = claims["exp"] as? Double
    else {
      return nil
    }
    return Date(timeIntervalSince1970: exp)
  }

  /// Runs the command through `/bin/sh -c` with stdin closed (a token tool must not wait
  /// on the terminal — the REPL owns it) and returns its trimmed stdout.
  static func run(command: String, environment: [String: String], timeoutSeconds: Int = 120) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.environment = environment
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
      try process.run()
    } catch {
      throw ProviderError.tokenCommandFailed(command: command, detail: "\(error)")
    }
    let deadline = DispatchWorkItem { [weak process] in
      if process?.isRunning == true { process?.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: deadline)
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    let errors = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    let token = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard process.terminationStatus == 0, !token.isEmpty else {
      let detail = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
      throw ProviderError.tokenCommandFailed(
        command: command,
        detail: detail.isEmpty ? "exit \(process.terminationStatus)" : String(detail.prefix(300)))
    }
    return token
  }
}

// MARK: - LiteLLMError

public enum LiteLLMError: Error, CustomStringConvertible, Sendable {
  case http(status: Int, url: String, body: String)
  case manifestUnavailable(String)

  public var description: String {
    switch self {
    case .http(let status, let url, let body):
      return "HTTP \(status) from \(url): \(body.prefix(200))"
    case .manifestUnavailable(let reason):
      return "could not load the model manifest: \(reason)"
    }
  }
}

// MARK: - LiteLLMModelInfo

/// One row of LiteLLM's `GET /model/info` — the gateway's manifest. `model_name` is
/// what callers send as `model`; `litellm_params.model` names the upstream deployment
/// (`anthropic/claude-…`, `bedrock/anthropic.claude-…`), which is what the family is
/// inferred from; `model_info` carries the capability and pricing bits.
public struct LiteLLMModelInfo: Decodable, Sendable {
  public struct Params: Decodable, Sendable {
    public let model: String?
  }

  public struct Info: Decodable, Sendable {
    public let maxInputTokens: Int?
    public let maxTokens: Int?
    public let inputCostPerToken: Double?
    public let outputCostPerToken: Double?
    public let litellmProvider: String?
    /// `chat`, `embedding`, `image_generation`, … — only chat models become profiles.
    public let mode: String?
    public let supportsFunctionCalling: Bool?
    public let supportsReasoning: Bool?
    public let supportsResponseSchema: Bool?
    /// LiteLLM's image-input bit; absent = no vision (the one capability assumed off, see
    /// `ModelProfile.supportsVision`).
    public let supportsVision: Bool?

    enum CodingKeys: String, CodingKey {
      case maxInputTokens = "max_input_tokens"
      case maxTokens = "max_tokens"
      case inputCostPerToken = "input_cost_per_token"
      case outputCostPerToken = "output_cost_per_token"
      case litellmProvider = "litellm_provider"
      case mode
      case supportsFunctionCalling = "supports_function_calling"
      case supportsReasoning = "supports_reasoning"
      case supportsResponseSchema = "supports_response_schema"
      case supportsVision = "supports_vision"
    }
  }

  public let modelName: String
  public let litellmParams: Params?
  public let modelInfo: Info?

  enum CodingKeys: String, CodingKey {
    case modelName = "model_name"
    case litellmParams = "litellm_params"
    case modelInfo = "model_info"
  }

  /// The `ModelProfile` for this row. Capabilities the row doesn't state are assumed
  /// the way `ModelProfile(unknownModelId:)` assumes them — tools on — so a sparse
  /// manifest never silently disables the agent loop.
  public var profile: ModelProfile {
    let info = modelInfo
    let family = ModelFamily(
      inferringFrom: litellmParams?.model ?? modelName,
      provider: info?.litellmProvider)
    return ModelProfile(
      id: modelName,
      family: family,
      contextLength: info?.maxInputTokens ?? info?.maxTokens,
      supportsTools: info?.supportsFunctionCalling ?? true,
      supportsReasoning: info?.supportsReasoning ?? false,
      supportsStructuredOutputs: info?.supportsResponseSchema ?? false,
      // Same rule as the OpenRouter manifest: a negative or non-finite price is not a price.
      promptPricePerToken: info?.inputCostPerToken.flatMap(ModelProfile.usablePrice),
      completionPricePerToken: info?.outputCostPerToken.flatMap(ModelProfile.usablePrice),
      // `max_tokens` is the output cap only when `max_input_tokens` is there to be the context
      // length; alone it stands in for the context length above and caps nothing.
      maxCompletionTokens: info?.maxInputTokens != nil ? info?.maxTokens : nil,
      // Vision is the one bit assumed *off* when unstated (an image to a text model fails the
      // whole request); `supports_vision: true` turns `view_image` on for this row.
      supportsVision: info?.supportsVision ?? false)
  }
}

// MARK: - LiteLLMKeyInfo

/// `GET /key/info` for the calling key — spend against budget, for `arnes status`.
public struct LiteLLMKeyInfo: Decodable, Sendable {
  public let keyAlias: String?
  public let spend: Double?
  public let maxBudget: Double?
  public let models: [String]?
  public let expires: String?

  private struct Envelope: Decodable {
    let info: Payload
  }

  private struct Payload: Decodable {
    let keyAlias: String?
    let spend: Double?
    let maxBudget: Double?
    let models: [String]?
    let expires: String?

    enum CodingKeys: String, CodingKey {
      case keyAlias = "key_alias"
      case spend
      case maxBudget = "max_budget"
      case models
      case expires
    }
  }

  public init(from decoder: Decoder) throws {
    let payload = try Envelope(from: decoder).info
    keyAlias = payload.keyAlias
    spend = payload.spend
    maxBudget = payload.maxBudget
    models = payload.models
    expires = payload.expires
  }
}

// MARK: - LiteLLMClient

/// The LiteLLM-specific endpoints Arnes reads: the manifest (`/model/info`) and the
/// key's budget (`/key/info`). Both live at the proxy root — one level above the
/// OpenAI-compatible `/v1` — so the client tries the root derived from the base URL
/// first and the versioned path second (newer proxies serve both). Everything else
/// goes through OpenRouterSwift over the rewriting client.
public final class LiteLLMClient: @unchecked Sendable {
  public let baseURL: URL
  private let headers: [String: String]
  private let http: any HTTPClient
  private let tokens: BearerTokenSource?

  public init(
    baseURL: URL,
    apiKey: String,
    headers: [String: String] = [:],
    http: (any HTTPClient)? = nil,
    tokens: BearerTokenSource? = nil)
  {
    self.baseURL = baseURL
    var merged = headers
    merged["Authorization"] = "Bearer \(apiKey)"
    self.headers = merged
    self.http = http ?? HTTPClientFactory.createDefault()
    self.tokens = tokens
  }

  /// Profiles for every chat model the gateway lists. `/model/info` first (capabilities
  /// and prices); if the gateway hides it, the OpenAI-shaped `/models` list (ids only,
  /// capabilities assumed).
  public func profiles() async throws -> [ModelProfile] {
    var failures: [String] = []
    for url in candidates(for: "model/info") {
      do {
        let data = try await get(url)
        let page = try JSONDecoder().decode(ModelInfoResponse.self, from: data)
        return Self.profiles(from: page.data)
      } catch {
        failures.append("\(error)")
      }
    }
    do {
      let data = try await get(baseURL.appendingPathComponent("models"))
      let list = try JSONDecoder().decode(ModelList.self, from: data)
      return list.data.map { ModelProfile(unknownModelId: $0.id) }
    } catch {
      failures.append("\(error)")
      throw LiteLLMError.manifestUnavailable(failures.joined(separator: "; "))
    }
  }

  public func keyInfo() async throws -> LiteLLMKeyInfo {
    var lastError: Error = LiteLLMError.manifestUnavailable("no candidate URLs")
    for url in candidates(for: "key/info") {
      do {
        return try JSONDecoder().decode(LiteLLMKeyInfo.self, from: try await get(url))
      } catch {
        lastError = error
      }
    }
    throw lastError
  }

  /// Dedupes by `model_name` (one row per deployment otherwise) and drops non-chat
  /// modes so `/model` search never offers an embedding model.
  static func profiles(from rows: [LiteLLMModelInfo]) -> [ModelProfile] {
    var seen = Set<String>()
    var profiles: [ModelProfile] = []
    for row in rows {
      let mode = row.modelInfo?.mode
      guard mode == nil || mode == "chat", !seen.contains(row.modelName) else { continue }
      seen.insert(row.modelName)
      profiles.append(row.profile)
    }
    return profiles
  }

  /// The proxy root (base minus a trailing `/v1`) and the base itself.
  func candidates(for endpoint: String) -> [URL] {
    var urls: [URL] = []
    if baseURL.lastPathComponent.lowercased() == "v1" {
      urls.append(baseURL.deletingLastPathComponent().appendingPathComponent(endpoint))
    }
    urls.append(baseURL.appendingPathComponent(endpoint))
    return urls
  }

  private func get(_ url: URL) async throws -> Data {
    var headers = headers
    if let tokens {
      headers["Authorization"] = "Bearer \(try await tokens.token())"
    }
    let (data, response) = try await http.data(for: HTTPRequest(url: url, method: .get, headers: headers))
    guard (200..<300).contains(response.statusCode) else {
      throw LiteLLMError.http(
        status: response.statusCode,
        url: url.absoluteString,
        body: String(decoding: data.prefix(400), as: UTF8.self))
    }
    return data
  }

  private struct ModelInfoResponse: Decodable {
    let data: [LiteLLMModelInfo]
  }

  private struct ModelList: Decodable {
    struct Entry: Decodable {
      let id: String
    }

    let data: [Entry]
  }
}
