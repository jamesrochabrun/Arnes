import XCTest
@testable import ArnesKit
import SwiftOpenAI

// MARK: - StubHTTPClient

/// Canned responses by URL path; records every request it sees.
final class StubHTTPClient: HTTPClient, @unchecked Sendable {
  /// path → (status, body)
  var responses: [String: (Int, String)] = [:]
  private let lock = NSLock()
  private var recorded: [HTTPRequest] = []

  var requests: [HTTPRequest] {
    lock.withLock { recorded }
  }

  func data(for request: HTTPRequest) async throws -> (Data, HTTPResponse) {
    lock.withLock { recorded.append(request) }
    let (status, body) = responses[request.url.path] ?? (404, #"{"error":"not found"}"#)
    return (Data(body.utf8), HTTPResponse(statusCode: status, headers: [:]))
  }

  func bytes(for request: HTTPRequest) async throws -> (HTTPByteStream, HTTPResponse) {
    let (data, response) = try await self.data(for: request)
    let line = String(decoding: data, as: UTF8.self)
    return (.lines(AsyncThrowingStream { continuation in
      continuation.yield(line)
      continuation.finish()
    }), response)
  }
}

// MARK: - GatewayHTTPClientTests

final class GatewayHTTPClientTests: XCTestCase {
  func testRewritesOpenRouterURLsOntoTheProviderRoot() {
    let root = URL(string: "https://gw.example.com/litellm/v1")!
    XCTAssertEqual(
      GatewayHTTPClient.rewrite(
        url: URL(string: "https://openrouter.ai/api/v1/chat/completions?x=1")!, root: root).absoluteString,
      "https://gw.example.com/litellm/v1/chat/completions?x=1")
    XCTAssertEqual(
      GatewayHTTPClient.rewrite(
        url: URL(string: "https://openrouter.ai/api/v1/models")!, root: URL(string: "http://localhost:4000")!).absoluteString,
      "http://localhost:4000/models")
    XCTAssertEqual(
      GatewayHTTPClient.rewrite(
        url: URL(string: "https://openrouter.ai/api/v1/messages")!, root: URL(string: "https://gw.example.com/v1/")!).absoluteString,
      "https://gw.example.com/v1/messages")
    // Paths without the OpenRouter prefix are appended as they are.
    XCTAssertEqual(
      GatewayHTTPClient.rewrite(url: URL(string: "https://openrouter.ai/health")!, root: root).absoluteString,
      "https://gw.example.com/litellm/v1/health")
  }

  func testDelegatesTheRewrittenRequestWithHeadersAndBodyIntact() async throws {
    let stub = StubHTTPClient()
    stub.responses["/v1/chat/completions"] = (200, "{}")
    let client = GatewayHTTPClient(root: URL(string: "https://gw.example.com/v1")!, base: stub)
    let body = Data(#"{"model":"sonnet"}"#.utf8)
    let (_, response) = try await client.data(for: HTTPRequest(
      url: URL(string: "https://openrouter.ai/api/v1/chat/completions")!,
      method: .post,
      headers: ["Authorization": "Bearer k", "x-team": "ios"],
      body: body))
    XCTAssertEqual(response.statusCode, 200)
    let sent = try XCTUnwrap(stub.requests.first)
    XCTAssertEqual(sent.url.absoluteString, "https://gw.example.com/v1/chat/completions")
    XCTAssertEqual(sent.method, .post)
    XCTAssertEqual(sent.headers["Authorization"], "Bearer k")
    XCTAssertEqual(sent.headers["x-team"], "ios")
    XCTAssertEqual(sent.body, body)
  }
}

// MARK: - LiteLLMClientTests

final class LiteLLMClientTests: XCTestCase {
  private let modelInfoJSON = """
    {"data": [
      {"model_name": "sonnet", "litellm_params": {"model": "anthropic/claude-sonnet-4-5"},
       "model_info": {"max_input_tokens": 200000, "max_tokens": 8192, "input_cost_per_token": 3e-06, "output_cost_per_token": 1.5e-05,
                      "litellm_provider": "anthropic", "mode": "chat", "supports_function_calling": true, "supports_reasoning": true}},
      {"model_name": "sonnet", "litellm_params": {"model": "bedrock/anthropic.claude-sonnet-4-5"},
       "model_info": {"max_input_tokens": 100000, "mode": "chat", "litellm_provider": "bedrock"}},
      {"model_name": "gpt-prod", "litellm_params": {"model": "azure/my-deployment"},
       "model_info": {"max_tokens": 128000, "mode": "chat", "litellm_provider": "azure",
                      "supports_function_calling": false, "supports_response_schema": true}},
      {"model_name": "embed", "litellm_params": {"model": "openai/text-embedding-3-small"}, "model_info": {"mode": "embedding"}},
      {"model_name": "mystery", "litellm_params": {"model": "custom/whatever"}}
    ]}
    """

  private struct Page: Decodable {
    let data: [LiteLLMModelInfo]
  }

  private let base = URL(string: "https://gw.example.com/v1")!

  func testModelInfoBecomesProfilesDedupedAndChatOnly() throws {
    let rows = try JSONDecoder().decode(Page.self, from: Data(modelInfoJSON.utf8)).data
    let profiles = LiteLLMClient.profiles(from: rows)
    XCTAssertEqual(profiles.map(\.id), ["sonnet", "gpt-prod", "mystery"])

    let sonnet = profiles[0]
    XCTAssertEqual(sonnet.family, .anthropic)
    XCTAssertEqual(sonnet.dialect, .messages)
    XCTAssertEqual(sonnet.contextLength, 200_000)
    XCTAssertTrue(sonnet.supportsTools)
    XCTAssertTrue(sonnet.supportsReasoning)
    XCTAssertEqual(sonnet.promptPricePerToken, 3e-06)
    XCTAssertEqual(sonnet.completionPricePerToken, 1.5e-05)

    let gpt = profiles[1]
    XCTAssertEqual(gpt.family, .openai, "the azure provider tag decides when the deployment name says nothing")
    XCTAssertEqual(gpt.contextLength, 128_000, "max_tokens is the fallback for max_input_tokens")
    XCTAssertFalse(gpt.supportsTools)
    XCTAssertTrue(gpt.supportsStructuredOutputs)
    XCTAssertNil(gpt.promptPricePerToken)

    let mystery = profiles[2]
    XCTAssertEqual(mystery.family, .other)
    XCTAssertTrue(mystery.supportsTools, "unknown capabilities are assumed on, like unknownModelId")
    XCTAssertEqual(mystery.dialect, .chat)
  }

  func testProfilesPreferModelInfoAtTheProxyRoot() async throws {
    let stub = StubHTTPClient()
    stub.responses["/model/info"] = (200, modelInfoJSON)
    let client = LiteLLMClient(baseURL: base, apiKey: "k", headers: ["x-team": "ios"], http: stub)
    let profiles = try await client.profiles()
    XCTAssertEqual(profiles.count, 3)
    let request = try XCTUnwrap(stub.requests.first)
    XCTAssertEqual(request.url.absoluteString, "https://gw.example.com/model/info")
    XCTAssertEqual(request.headers["Authorization"], "Bearer k")
    XCTAssertEqual(request.headers["x-team"], "ios")
  }

  func testProfilesFallBackToTheModelsListWhenModelInfoIsHidden() async throws {
    let hidden = StubHTTPClient()
    hidden.responses["/v1/models"] = (200, #"{"object":"list","data":[{"id":"alias-a","object":"model"},{"id":"alias-b","object":"model"}]}"#)
    let client = LiteLLMClient(baseURL: base, apiKey: "k", http: hidden)
    let assumed = try await client.profiles()
    XCTAssertEqual(assumed.map(\.id), ["alias-a", "alias-b"])
    XCTAssertTrue(assumed.allSatisfy(\.supportsTools))
    XCTAssertEqual(hidden.requests.map(\.url.path), ["/model/info", "/v1/model/info", "/v1/models"])

    let dead = LiteLLMClient(baseURL: base, apiKey: "k", http: StubHTTPClient())
    do {
      _ = try await dead.profiles()
      XCTFail("expected manifestUnavailable")
    } catch let error as LiteLLMError {
      guard case .manifestUnavailable = error else { return XCTFail("unexpected \(error)") }
    }
  }

  func testKeyInfoDecodesTheEnvelope() async throws {
    let stub = StubHTTPClient()
    stub.responses["/key/info"] = (200, #"{"key":"sk-...","info":{"key_alias":"dev-key","spend":1.25,"max_budget":50,"models":["sonnet"],"expires":null}}"#)
    let client = LiteLLMClient(baseURL: base, apiKey: "k", http: stub)
    let info = try await client.keyInfo()
    XCTAssertEqual(info.keyAlias, "dev-key")
    XCTAssertEqual(info.spend, 1.25)
    XCTAssertEqual(info.maxBudget, 50)
    XCTAssertEqual(info.models, ["sonnet"])
    XCTAssertNil(info.expires)
  }
}

// MARK: - ModelFamilyInferenceTests

final class ModelFamilyInferenceTests: XCTestCase {
  func testNameStemsWinThenProviderThenAuthorPrefix() {
    XCTAssertEqual(ModelFamily(inferringFrom: "bedrock/anthropic.claude-sonnet-4-5", provider: "bedrock"), .anthropic)
    XCTAssertEqual(ModelFamily(inferringFrom: "vertex_ai/gemini-2.5-pro", provider: "vertex_ai"), .google)
    XCTAssertEqual(ModelFamily(inferringFrom: "azure/gpt-4o-prod", provider: "azure"), .openai)
    XCTAssertEqual(ModelFamily(inferringFrom: "o3-mini"), .openai)
    XCTAssertEqual(ModelFamily(inferringFrom: "azure/my-deployment", provider: "azure"), .openai)
    XCTAssertEqual(ModelFamily(inferringFrom: "groq/llama-3.3-70b", provider: "groq"), .meta)
    XCTAssertEqual(ModelFamily(inferringFrom: "deepseek-chat", provider: "deepseek"), .deepseek)
    XCTAssertEqual(ModelFamily(inferringFrom: "mistralai/mixtral-8x7b"), .mistral)
    XCTAssertEqual(ModelFamily(inferringFrom: "qwen3-coder"), .qwen)
    XCTAssertEqual(ModelFamily(inferringFrom: "grok-4", provider: "xai"), .xai)
    XCTAssertEqual(ModelFamily(inferringFrom: "anthropic/claude-haiku-4.5"), .anthropic, "author prefixes still work")
    XCTAssertEqual(ModelFamily(inferringFrom: "custom/whatever", provider: "custom"), .other)
  }
}

// MARK: - ManifestFallbackTests

final class ManifestFallbackTests: XCTestCase {
  func testUnavailableManifestDegradesToAssumedProfiles() async throws {
    struct Down: Error {}
    let catalog = ModelCatalog(loader: { throw Down() })
    let profile = try await catalog.profile(for: "claude-sonnet-4-5")
    XCTAssertTrue(profile.supportsTools)
    XCTAssertEqual(profile.family, .anthropic, "the family still comes from the name")
    XCTAssertEqual(profile.dialect, .messages)
    XCTAssertNil(profile.promptPricePerToken)
    let all = try await catalog.all()
    XCTAssertTrue(all.isEmpty)
    let failure = await catalog.manifestFailure
    XCTAssertNotNil(failure)
  }

  func testUnknownModelKeepsTheUniversalDialectWhenNothingIsKnown() {
    XCTAssertEqual(ModelProfile(unknownModelId: "openrouter/auto").dialect, .chat)
    XCTAssertEqual(ModelProfile(unknownModelId: "openrouter/auto").family, .other)
    XCTAssertEqual(ModelProfile(unknownModelId: "gpt-4o").dialect, .responses)
    XCTAssertTrue(ModelProfile(unknownModelId: "whatever").supportsTools)
  }
}

// MARK: - BearerTokenSourceTests

final class BearerTokenSourceTests: XCTestCase {
  /// `{"exp": <value>}` as a three-part JWT whose signature carries `tag` so tokens differ.
  private func jwt(exp: Int, tag: String) -> String {
    let payload = Data(#"{"exp": \#(exp)}"#.utf8).base64EncodedString()
      .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    return "e30.\(payload).\(tag)"
  }

  /// A command that prints a different token on every run via a counter file.
  private func countingCommand(printing template: String) throws -> String {
    let counter = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-token-\(UUID().uuidString)")
    try "1".write(to: counter, atomically: true, encoding: .utf8)
    return "n=$(cat '\(counter.path)'); echo \"\(template)\"; echo $((n+1)) > '\(counter.path)'"
  }

  func testDecodesExpiryFromJWTOnly() {
    XCTAssertEqual(BearerTokenSource.expiry(ofJWT: jwt(exp: 1_700_000_000, tag: "s"))?.timeIntervalSince1970, 1_700_000_000)
    XCTAssertNil(BearerTokenSource.expiry(ofJWT: "opaque-token"))
    XCTAssertNil(BearerTokenSource.expiry(ofJWT: "a.b"))
  }

  func testOpaqueTokensAreCachedForTheTTL() async throws {
    let source = BearerTokenSource(command: try countingCommand(printing: "tok$n"), ttl: 3600)
    let first = try await source.token()
    let second = try await source.token()
    XCTAssertEqual(first, "tok1")
    XCTAssertEqual(second, "tok1", "still fresh — the command did not run again")
  }

  func testExpiredJWTIsMintedAgain() async throws {
    // exp = 1 (1970): always inside the refresh margin, so every call re-runs the command.
    let template = jwt(exp: 1, tag: "sig$n")
    let source = BearerTokenSource(command: try countingCommand(printing: template), ttl: 3600)
    let first = try await source.token()
    let second = try await source.token()
    XCTAssertTrue(first.hasSuffix(".sig1"))
    XCTAssertTrue(second.hasSuffix(".sig2"))
  }

  func testFailingCommandIsReportedWithItsStderr() async {
    let source = BearerTokenSource(command: "echo 'login required' >&2; exit 3")
    do {
      _ = try await source.token()
      XCTFail("expected failure")
    } catch let error as ProviderError {
      XCTAssertEqual(error, .tokenCommandFailed(command: "echo 'login required' >&2; exit 3", detail: "login required"))
    } catch {
      XCTFail("unexpected \(error)")
    }
  }

  func testGatewayClientStampsAFreshBearerOnEveryRequest() async throws {
    let stub = StubHTTPClient()
    stub.responses["/v1/models"] = (200, "{}")
    let client = GatewayHTTPClient(
      root: URL(string: "https://gw.example.com/v1")!,
      base: stub,
      tokens: BearerTokenSource(command: "echo minted"))
    _ = try await client.data(for: HTTPRequest(
      url: URL(string: "https://openrouter.ai/api/v1/models")!,
      method: .get,
      headers: ["Authorization": "Bearer stale-static", "x-team": "ios"]))
    let sent = try XCTUnwrap(stub.requests.first)
    XCTAssertEqual(sent.headers["Authorization"], "Bearer minted")
    XCTAssertEqual(sent.headers["x-team"], "ios")
  }
}

// MARK: - ModelAliasTests

final class ModelAliasTests: XCTestCase {
  func testAliasesResolveBeforeAndWithoutTheManifest() async throws {
    struct Down: Error {}
    let catalog = ModelCatalog(loader: { throw Down() }, aliases: ["haiku": "claude-haiku-4-5-20251001", "Sonnet": "claude-sonnet-5"])
    XCTAssertEqual(catalog.resolve("haiku"), "claude-haiku-4-5-20251001")
    XCTAssertEqual(catalog.resolve("HAIKU"), "claude-haiku-4-5-20251001")
    XCTAssertEqual(catalog.resolve("sonnet"), "claude-sonnet-5")
    XCTAssertEqual(catalog.resolve("claude-opus-5"), "claude-opus-5", "non-aliases pass through")

    let viaSearch = try await catalog.search("haiku", limit: 3)
    XCTAssertEqual(viaSearch.map(\.id), ["claude-haiku-4-5-20251001"])
    XCTAssertEqual(viaSearch.first?.family, .anthropic)
    let viaProfile = try await catalog.profile(for: "sonnet")
    XCTAssertEqual(viaProfile.id, "claude-sonnet-5", "the wire id, never the alias")
    let unresolved = try await catalog.search("flash", limit: 3)
    XCTAssertTrue(unresolved.isEmpty)
  }

  func testAliasOutranksManifestMatches() async throws {
    let catalog = ModelCatalog(
      loader: {
        [ModelProfile(unknownModelId: "anthropic/claude-haiku-4.5"), ModelProfile(unknownModelId: "haiku-ish/other")]
      },
      aliases: ["haiku": "anthropic/claude-haiku-4.5"])
    let aliased = try await catalog.search("haiku", limit: 5).map(\.id)
    XCTAssertEqual(aliased, ["anthropic/claude-haiku-4.5"])
    // Fuzzy search without an alias still ranks the manifest.
    let fuzzy = try await catalog.search("other", limit: 5).map(\.id)
    XCTAssertEqual(fuzzy, ["haiku-ish/other"])
  }
}
