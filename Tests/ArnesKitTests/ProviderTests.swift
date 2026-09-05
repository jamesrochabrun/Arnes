import XCTest
@testable import ArnesKit

final class ProviderTests: XCTestCase {
  private let missingCredentials = URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)")

  private func gatewayConfig(
    defaultModel: String? = "claude-sonnet-4-5",
    headers: [String: String]? = ["x-team": "ios"],
    headersEnv: String? = "GATEWAY_HEADERS")
    -> ArnesConfig
  {
    ArnesConfig(
      provider: "gateway",
      providers: [
        "gateway": ProviderConfig(
          kind: .litellm,
          baseURL: "https://llm.example.com/v1/",
          apiKeyEnv: "GATEWAY_TOKEN",
          headers: headers,
          headersEnv: headersEnv,
          defaultModel: defaultModel),
      ])
  }

  func testDefaultsToOpenRouterFromTheEnvironment() throws {
    let resolved = try ProviderResolver.resolve(
      config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: missingCredentials)
    XCTAssertEqual(resolved.name, "openrouter")
    XCTAssertEqual(resolved.kind, .openrouter)
    XCTAssertEqual(resolved.baseURL.absoluteString, "https://openrouter.ai/api/v1")
    XCTAssertEqual(resolved.apiKey, "sk-or-test")
    XCTAssertEqual(resolved.apiKeySource, "env OPENROUTER_API_KEY")
    XCTAssertEqual(resolved.defaultModel, "openrouter/auto")
    XCTAssertTrue(resolved.isStandardOpenRouter)
    XCTAssertEqual(resolved.traits, .openrouter)
  }

  func testConfiguredGatewayWithEnvTokenAndHeaders() throws {
    let resolved = try ProviderResolver.resolve(
      config: gatewayConfig(),
      environment: [
        "GATEWAY_TOKEN": "jwt-token",
        "GATEWAY_HEADERS": "x-trace: abc\n\n X-Client : arnes ",
      ],
      credentialsURL: missingCredentials)
    XCTAssertEqual(resolved.name, "gateway")
    XCTAssertEqual(resolved.kind, .litellm)
    XCTAssertEqual(resolved.baseURL.absoluteString, "https://llm.example.com/v1", "trailing slash trimmed")
    XCTAssertEqual(resolved.endpointDescription, "llm.example.com/v1")
    XCTAssertEqual(resolved.apiKey, "jwt-token")
    XCTAssertEqual(resolved.apiKeySource, "env GATEWAY_TOKEN")
    XCTAssertEqual(resolved.headers, ["x-team": "ios", "x-trace": "abc", "X-Client": "arnes"])
    XCTAssertEqual(resolved.defaultModel, "claude-sonnet-4-5")
    XCTAssertFalse(resolved.isStandardOpenRouter)
    XCTAssertEqual(resolved.traits.name, "gateway")
    XCTAssertEqual(resolved.traits.defaultModel, "claude-sonnet-4-5")
    XCTAssertEqual(resolved.traits.fallbackStyle, .litellmFallbacks)
    XCTAssertTrue(resolved.traits.estimatesCost)
    XCTAssertTrue(resolved.traits.requestsStreamUsage)
    XCTAssertTrue(resolved.traits.nativeDialects)
  }

  func testProviderSelectionPrecedence() throws {
    var config = gatewayConfig()
    config.providers?["staging"] = ProviderConfig(
      kind: .openaiCompatible, baseURL: "https://staging.example.com/v1", defaultModel: "m")
    let env = ["ARNES_PROVIDER": "staging", "GATEWAY_TOKEN": "t", "OPENAI_API_KEY": "o", "OPENROUTER_API_KEY": "r"]
    // The config says gateway, the environment says staging, the flag says openrouter.
    XCTAssertEqual(ProviderResolver.activeName(config: config, environment: [:]), "gateway")
    XCTAssertEqual(ProviderResolver.activeName(config: config, environment: env), "staging")
    XCTAssertEqual(ProviderResolver.activeName(requested: "openrouter", config: config, environment: env), "openrouter")
    XCTAssertEqual(ProviderResolver.activeName(config: nil, environment: [:]), "openrouter")

    let staging = try ProviderResolver.resolve(config: config, environment: env, credentialsURL: missingCredentials)
    XCTAssertEqual(staging.kind, .openaiCompatible)
    XCTAssertEqual(staging.apiKeySource, "env OPENAI_API_KEY")
    XCTAssertFalse(staging.traits.nativeDialects, "plain OpenAI-compatible endpoints default to chat only")
    XCTAssertEqual(staging.traits.fallbackStyle, .unsupported)
  }

  func testEnvironmentOverridesForTheActiveProvider() throws {
    let resolved = try ProviderResolver.resolve(
      config: gatewayConfig(),
      environment: [
        "GATEWAY_TOKEN": "ignored",
        "ARNES_API_KEY": "override",
        "ARNES_BASE_URL": "https://staging.example.com/litellm/v1",
        "ARNES_DEFAULT_MODEL": "haiku",
      ],
      credentialsURL: missingCredentials)
    XCTAssertEqual(resolved.apiKey, "override")
    XCTAssertEqual(resolved.apiKeySource, "env ARNES_API_KEY")
    XCTAssertEqual(resolved.baseURL.absoluteString, "https://staging.example.com/litellm/v1")
    XCTAssertEqual(resolved.endpointDescription, "staging.example.com/litellm/v1")
    XCTAssertEqual(resolved.defaultModel, "haiku")
  }

  func testCredentialsFileHoldsSeveralKeysPlusTheLegacyBareLine() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-credentials-\(UUID().uuidString)")
    try """
      # openrouter, the old way
      sk-or-bare
      GATEWAY_TOKEN="jwt-from-file"
      """.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let openrouter = try ProviderResolver.resolve(config: nil, environment: [:], credentialsURL: url)
    XCTAssertEqual(openrouter.apiKey, "sk-or-bare")
    XCTAssertEqual(openrouter.apiKeySource, url.path)

    let gateway = try ProviderResolver.resolve(config: gatewayConfig(), environment: [:], credentialsURL: url)
    XCTAssertEqual(gateway.apiKey, "jwt-from-file")

    // A gateway never inherits the bare OpenRouter line.
    var config = gatewayConfig()
    config.providers?["gateway"]?.apiKeyEnv = "OTHER_TOKEN"
    XCTAssertThrowsError(try ProviderResolver.resolve(config: config, environment: [:], credentialsURL: url)) { error in
      XCTAssertEqual(
        error as? ProviderError,
        .missingAPIKey(provider: "gateway", env: "OTHER_TOKEN", credentialsPath: url.path))
    }
  }

  func testPlainHTTPOnlyToLoopbackUnlessOptedIn() throws {
    func config(_ baseURL: String, insecure: Bool? = nil) -> ArnesConfig {
      ArnesConfig(
        provider: "local",
        providers: ["local": ProviderConfig(kind: .openaiCompatible, baseURL: baseURL, defaultModel: "m", insecure: insecure)])
    }
    let env = ["OPENAI_API_KEY": "k"]
    XCTAssertNoThrow(try ProviderResolver.resolve(
      config: config("http://localhost:4000/v1"), environment: env, credentialsURL: missingCredentials))
    XCTAssertNoThrow(try ProviderResolver.resolve(
      config: config("http://127.0.0.1:4000"), environment: env, credentialsURL: missingCredentials))
    XCTAssertThrowsError(try ProviderResolver.resolve(
      config: config("http://llm.internal/v1"), environment: env, credentialsURL: missingCredentials))
    { error in
      XCTAssertEqual(error as? ProviderError, .insecureBaseURL("http://llm.internal/v1"))
    }
    XCTAssertNoThrow(try ProviderResolver.resolve(
      config: config("http://llm.internal/v1", insecure: true), environment: env, credentialsURL: missingCredentials))
    XCTAssertThrowsError(try ProviderResolver.resolve(
      config: config("ftp://llm.internal/v1"), environment: env, credentialsURL: missingCredentials))
    XCTAssertThrowsError(try ProviderResolver.resolve(
      config: config("not a url"), environment: env, credentialsURL: missingCredentials))
  }

  func testUnknownProviderMissingDefaultModelAndBadHeaderLine() {
    XCTAssertThrowsError(try ProviderResolver.resolve(
      requested: "nope", config: gatewayConfig(), environment: [:], credentialsURL: missingCredentials))
    { error in
      XCTAssertEqual(error as? ProviderError, .unknownProvider("nope", available: ["gateway", "openrouter"]))
    }
    // No default model is allowed — discovery commands still work; traits carry "" and
    // the Session falls back to its own model for utility calls.
    let undecided = try? ProviderResolver.resolve(
      config: gatewayConfig(defaultModel: nil), environment: ["GATEWAY_TOKEN": "t"], credentialsURL: missingCredentials)
    XCTAssertNil(undecided?.defaultModel)
    XCTAssertEqual(undecided?.traits.defaultModel, "")
    XCTAssertThrowsError(try ProviderResolver.resolve(
      config: gatewayConfig(),
      environment: ["GATEWAY_TOKEN": "t", "GATEWAY_HEADERS": "no colon here"],
      credentialsURL: missingCredentials))
    { error in
      XCTAssertEqual(error as? ProviderError, .invalidHeaderLine("no colon here"))
    }
  }

  func testTokenCommandAndHeaderTemplates() throws {
    let config = ArnesConfig(
      provider: "gw",
      providers: ["gw": ProviderConfig(
        kind: .litellm,
        baseURL: "https://llm.example.com/v1",
        apiKeyCommand: "iap-auth",
        headers: ["x-client-id": "${UUID}", "x-user": "${GW_USER}", "x-static": "$notatemplate ${"],
        defaultModel: "sonnet")])
    let resolved = try ProviderResolver.resolve(
      config: config, environment: ["GW_USER": "james"], credentialsURL: missingCredentials)
    XCTAssertEqual(resolved.apiKey, "", "minted per request, not at resolution")
    XCTAssertEqual(resolved.apiKeyCommand, "iap-auth")
    XCTAssertEqual(resolved.apiKeySource, "command `iap-auth`")
    XCTAssertEqual(resolved.headers["x-user"], "james")
    XCTAssertEqual(resolved.headers["x-static"], "$notatemplate ${")
    XCTAssertNotNil(UUID(uuidString: resolved.headers["x-client-id"] ?? ""), "one fresh UUID per run")

    // A static token still wins over the command when one is present.
    let withEnv = try ProviderResolver.resolve(
      config: config, environment: ["LITELLM_API_KEY": "static"], credentialsURL: missingCredentials)
    XCTAssertEqual(withEnv.apiKey, "static")
    XCTAssertNil(withEnv.apiKeyCommand)
  }

  func testAliasesResolveTheDefaultModelAndFlags() throws {
    let config = ArnesConfig(
      provider: "gw",
      providers: ["gw": ProviderConfig(
        kind: .litellm, baseURL: "https://llm.example.com/v1", apiKeyEnv: "T",
        defaultModel: "Sonnet", aliases: ["sonnet": "claude-sonnet-5", "haiku": "claude-haiku-4-5-20251001", "": "dropped"])])
    let resolved = try ProviderResolver.resolve(config: config, environment: ["T": "t"], credentialsURL: missingCredentials)
    XCTAssertEqual(resolved.defaultModel, "claude-sonnet-5", "the default is stored alias-resolved")
    XCTAssertEqual(resolved.resolveAlias("HAIKU"), "claude-haiku-4-5-20251001")
    XCTAssertEqual(resolved.resolveAlias("claude-opus-5"), "claude-opus-5")
    XCTAssertEqual(resolved.aliases.count, 2, "empty keys are ignored")
  }

  func testConfigFileRoundTrip() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-config-\(UUID().uuidString).json")
    try """
      {"provider": "gateway",
       "providers": {"gateway": {"kind": "litellm", "baseURL": "https://llm.example.com/v1",
                                 "apiKeyEnv": "GATEWAY_TOKEN", "defaultModel": "sonnet", "nativeDialects": false}}}
      """.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }
    let config = try XCTUnwrap(ArnesConfig.load(from: url))
    XCTAssertEqual(config.provider, "gateway")
    XCTAssertEqual(config.providers?["gateway"]?.kind, .litellm)
    XCTAssertEqual(config.providers?["gateway"]?.nativeDialects, false)
    XCTAssertEqual(config.allProviders.count, 2, "config entries plus the built-in openrouter")
    XCTAssertNil(try ArnesConfig.load(from: missingCredentials))

    let resolved = try ProviderResolver.resolve(
      config: config, environment: ["GATEWAY_TOKEN": "t"], credentialsURL: missingCredentials)
    XCTAssertFalse(resolved.traits.nativeDialects)
  }

  func testSubagentsConfigDecodesAndDefaults() throws {
    let json = """
      {"provider": "gateway",
       "providers": {"gateway": {"kind": "litellm", "baseURL": "https://llm.example.com/v1",
                                 "apiKeyEnv": "GATEWAY_TOKEN",
                                 "aliases": {"haiku": "claude-haiku-4-5"},
                                 "subagents": {"defaultModel": "haiku", "maxSteps": 12,
                                               "budgetUSD": 0.5, "maxConcurrent": 2, "maxDepth": 1,
                                               "background": true, "joinAtTurnEnd": false,
                                               "persistTranscripts": false}}}}
      """
    let config = try JSONDecoder().decode(ArnesConfig.self, from: Data(json.utf8))
    XCTAssertEqual(config.providers?["gateway"]?.subagents?.defaultModel, "haiku")

    let resolved = try ProviderResolver.resolve(
      config: config, environment: ["GATEWAY_TOKEN": "t"], credentialsURL: missingCredentials)
    // The subagent default model is named like any other: an id or a configured alias.
    XCTAssertEqual(resolved.subagents?.defaultModel, "claude-haiku-4-5")

    let defaults = TaskTool.Defaults(resolved.subagents)
    XCTAssertEqual(defaults.defaultModel, "claude-haiku-4-5")
    XCTAssertEqual(defaults.maxSteps, 12)
    XCTAssertEqual(defaults.budgetUSD, 0.5)
    XCTAssertEqual(defaults.maxConcurrent, 2)
    XCTAssertEqual(defaults.maxDepth, 1)
    XCTAssertTrue(defaults.background)
    XCTAssertFalse(defaults.joinAtTurnEnd)
    XCTAssertFalse(defaults.persistTranscripts)

    // No block at all — every provider that predates it keeps the built-in behavior.
    XCTAssertEqual(TaskTool.Defaults(nil), TaskTool.Defaults())
    XCTAssertEqual(TaskTool.Defaults(nil).maxSteps, .max, "no step cap by default — the loop guard and budget are the guardrails")
    XCTAssertNil(TaskTool.Defaults(nil).defaultModel)
    XCTAssertNil(TaskTool.Defaults(nil).budgetUSD)
    let openrouter = try ProviderResolver.resolve(
      config: nil, environment: ["OPENROUTER_API_KEY": "k"], credentialsURL: missingCredentials)
    XCTAssertNil(openrouter.subagents)
  }
}
