import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// How a non-OpenRouter provider changes the loop: fallback spelling, stream usage,
/// cost estimation from manifest prices, dialect pinning, and the record's provider.
final class SessionProviderTests: XCTestCase {
  private let gateway = ProviderTraits(
    name: "gateway",
    defaultModel: "sonnet",
    fallbackStyle: .litellmFallbacks,
    requestsStreamUsage: true,
    estimatesCost: true,
    nativeDialects: false)

  private func catalog() -> ModelCatalog {
    ModelCatalog(loader: {
      [ModelProfile(
        id: "sonnet", family: .anthropic, contextLength: 200_000,
        supportsTools: true, supportsReasoning: false, supportsStructuredOutputs: false,
        promptPricePerToken: 3e-06, completionPricePerToken: 1.5e-05)]
    })
  }

  /// A final chunk with token counts but no `cost` — what a LiteLLM proxy streams.
  private func usageWithoutCost(prompt: Int, completion: Int, model: String = "claude-sonnet-4-5") -> ChatCompletionChunk {
    Fixtures.chunk("""
      {"model":"\(model)","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":\(prompt),"completion_tokens":\(completion)}}
      """)
  }

  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-provider-runs-\(UUID().uuidString).jsonl"))
  }

  func testGatewayTraitsShapeTheRequestAndEstimateCost() async throws {
    let mock = MockOpenRouterService()
    mock.chunkScripts = [[
      Fixtures.textChunk("done", model: "claude-sonnet-4-5"),
      usageWithoutCost(prompt: 1000, completion: 100),
    ]]
    let session = Session(
      service: mock, tools: [], store: store(), catalog: catalog(),
      configuration: .init(model: "sonnet", fallbackModels: ["haiku", "gpt-4o"], provider: gateway))

    var stats: Session.TurnStats?
    for try await event in await session.send("hi") {
      if case .turnFinished(let turnStats) = event { stats = turnStats }
    }

    let request = try XCTUnwrap(mock.requests.first)
    XCTAssertNil(request.models, "LiteLLM doesn't know OpenRouter's models array")
    XCTAssertEqual(request.extraBody?["fallbacks"], .array([.string("haiku"), .string("gpt-4o")]))
    XCTAssertEqual(request.streamOptions?.includeUsage, true)

    // 1000 × $3e-6 + 100 × $1.5e-5
    XCTAssertEqual(try XCTUnwrap(stats).turnCostUSD, 0.0045, accuracy: 1e-9)
    let sessionCost = await session.costUSD
    XCTAssertEqual(sessionCost, 0.0045, accuracy: 1e-9)
    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.provider, "gateway")
    XCTAssertEqual(record.costUSD, 0.0045, accuracy: 1e-9)
    XCTAssertEqual(record.routedModels, ["claude-sonnet-4-5"])
    XCTAssertEqual(record.dialect, "chat", "nativeDialects: false pins an anthropic-family model to chat")
  }

  func testDefaultModelComesFromTheProviderWhenNoneIsGiven() {
    XCTAssertEqual(Session.Configuration(provider: gateway).model, "sonnet")
    XCTAssertEqual(Session.Configuration().model, "openrouter/auto")
    XCTAssertEqual(Session.Configuration(model: "explicit", provider: gateway).model, "explicit")
  }

  func testOpenRouterTraitsAreUnchanged() async throws {
    let mock = MockOpenRouterService()
    mock.chunkScripts = [[Fixtures.textChunk("done"), usageWithoutCost(prompt: 1000, completion: 100, model: "test/model")]]
    let session = Session(
      service: mock, tools: [], store: store(), catalog: catalog(),
      configuration: .init(model: "sonnet", fallbackModels: ["haiku"], dialect: .chat))
    for try await _ in await session.send("hi") {}

    let request = try XCTUnwrap(mock.requests.first)
    XCTAssertEqual(request.models, ["haiku"])
    XCTAssertNil(request.extraBody)
    XCTAssertNil(request.streamOptions)
    // OpenRouter prices every response itself; a missing cost is not estimated.
    let sessionCost = await session.costUSD
    XCTAssertEqual(sessionCost, 0)
    let lastRecord = await session.lastRecord
    XCTAssertEqual(try XCTUnwrap(lastRecord).provider, "openrouter")
  }

  func testEstimateIsNilWithoutPricesOrTokens() {
    let priced = ModelProfile(
      id: "m", contextLength: nil, supportsTools: true, supportsReasoning: false,
      supportsStructuredOutputs: false, promptPricePerToken: 1e-6, completionPricePerToken: 2e-6)
    let unpriced = ModelProfile(unknownModelId: "m")
    XCTAssertEqual(try XCTUnwrap(Session.estimatedCost(promptTokens: 10, completionTokens: 5, profile: priced)), 2e-5, accuracy: 1e-12)
    XCTAssertNil(Session.estimatedCost(promptTokens: 10, completionTokens: 5, profile: unpriced))
    XCTAssertNil(Session.estimatedCost(promptTokens: nil, completionTokens: nil, profile: priced))
    XCTAssertNil(Session.estimatedCost(promptTokens: 10, completionTokens: 5, profile: nil))
  }
}
