import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// A read-only tool whose only job is to be called once so a turn has two steps.
private final class PingTool: AgentTool, @unchecked Sendable {
  let name = "ping"
  let description = "Ping."
  let permission = ToolPermission.readOnly
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  func execute(arguments: [String: JSONValue]) async throws -> String { "pong" }
}

/// R3 — how a chat-completions request spells the reasoning dial is the provider's
/// (`ProviderTraits.reasoningShape`): OpenRouter's `reasoning: {effort}` object, OpenAI's
/// top-level `reasoning_effort` string (LiteLLM, OpenAI-compatible), or neither. The manifest
/// gate (`supportsReasoning`) and the dial itself are unchanged; the native dialects never read it.
final class ReasoningShapeTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-shape-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDialectStore() -> DialectVerdictStore {
    DialectVerdictStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-shape-verdicts-\(UUID().uuidString).jsonl"))
  }

  /// A LiteLLM-shaped gateway whose only varying trait is the reasoning shape.
  private func gateway(shape: ReasoningShape, nativeDialects: Bool = false) -> ProviderTraits {
    ProviderTraits(
      name: "gateway", defaultModel: "test/model", fallbackStyle: .litellmFallbacks,
      requestsStreamUsage: true, estimatesCost: true, nativeDialects: nativeDialects,
      supportsCacheControl: true, reasoningShape: shape)
  }

  private func reasoningManifest(supportsReasoning: Bool) -> String {
    let params = supportsReasoning ? "\"tools\",\"reasoning\"" : "\"tools\""
    return #"[{"id":"test/model","context_length":8000,"supported_parameters":[\#(params)],"pricing":{"prompt":"0","completion":"0"}}]"#
  }

  /// One chat turn on a gateway of the given shape; the request it sent.
  private func chatRequest(
    effort: Reasoning.Effort?, shape: ReasoningShape, supportsReasoning: Bool = true) async throws -> ChatCompletionRequest
  {
    let mock = MockOpenRouterService()
    mock.manifestJSON = reasoningManifest(supportsReasoning: supportsReasoning)
    mock.chunkScripts = [[Fixtures.textChunk("hi"), Fixtures.usageChunk(cost: 0)]]
    let session = Session(
      service: mock, tools: [], store: tempRecordStore(),
      configuration: .init(model: "test/model", reasoningEffort: effort, provider: gateway(shape: shape)))
    for try await _ in await session.send("go") { }
    return try XCTUnwrap(mock.requests.first)
  }

  private func sortedBytes<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    return try encoder.encode(value)
  }

  // MARK: Traits

  func testEachKindHasItsSpellingAndTheConfigOverrides() {
    XCTAssertEqual(ReasoningShape.forKind(.openrouter), .openrouter)
    XCTAssertEqual(ReasoningShape.forKind(.litellm), .openai)
    XCTAssertEqual(ReasoningShape.forKind(.openaiCompatible), .openai)
    XCTAssertEqual(ProviderTraits.openrouter.reasoningShape, .openrouter)
    for kind in ProviderKind.allCases {
      let traits = ProviderTraits.forKind(kind, name: "p", defaultModel: "m", nativeDialects: true)
      XCTAssertEqual(traits.reasoningShape, ReasoningShape.forKind(kind), "\(kind)")
      XCTAssertEqual(
        // Spelled out: against the optional parameter a bare `.none` is `Optional.none` — no override.
        ProviderTraits.forKind(kind, name: "p", defaultModel: "m", nativeDialects: true, reasoningShape: ReasoningShape.none).reasoningShape,
        .none, "\(kind): the entry's override wins")
    }
    // The memberwise default is OpenRouter's: a traits value built before the field existed
    // sends the request it always sent.
    let legacy = ProviderTraits(
      name: "generic", defaultModel: "m", fallbackStyle: .unsupported,
      requestsStreamUsage: true, estimatesCost: true, nativeDialects: false)
    XCTAssertEqual(legacy.reasoningShape, .openrouter)
    XCTAssertEqual(ReasoningShape(rawValue: "openai"), .openai)
    XCTAssertEqual(ReasoningShape.none.rawValue, "none")
  }

  func testProviderConfigDecodesTheKeyAndAnOldConfigUnchanged() throws {
    let old = #"{"kind":"litellm","baseURL":"https://gateway.example.com/v1","apiKeyEnv":"GW_TOKEN","nativeDialects":false}"#
    let entry = try JSONDecoder().decode(ProviderConfig.self, from: Data(old.utf8))
    XCTAssertNil(entry.reasoningShape, "absent = the kind's default, nothing decoded")
    // Re-encoded, the old entry carries no new key: byte-identical as a JSON document.
    let reencoded = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(entry))
    XCTAssertEqual(reencoded, try JSONDecoder().decode(JSONValue.self, from: Data(old.utf8)))
    XCTAssertNil(reencoded["reasoningShape"])

    let credentials = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-shape-creds-\(UUID().uuidString)")
    let environment = ["GW_TOKEN": "k"]
    let resolvedOld = try ProviderResolver.resolve(name: "gw", entry: entry, environment: environment, credentialsURL: credentials)
    XCTAssertNil(resolvedOld.reasoningShape)
    XCTAssertEqual(resolvedOld.traits.reasoningShape, .openai, "LiteLLM speaks OpenAI's string by default")

    for (spelling, shape) in [("openrouter", ReasoningShape.openrouter), ("openai", .openai), ("none", .none)] {
      let json = #"{"kind":"litellm","baseURL":"https://gateway.example.com/v1","apiKeyEnv":"GW_TOKEN","reasoningShape":"\#(spelling)"}"#
      let decoded = try JSONDecoder().decode(ProviderConfig.self, from: Data(json.utf8))
      XCTAssertEqual(decoded.reasoningShape, shape)
      let resolved = try ProviderResolver.resolve(name: "gw", entry: decoded, environment: environment, credentialsURL: credentials)
      XCTAssertEqual(resolved.reasoningShape, shape)
      XCTAssertEqual(resolved.traits.reasoningShape, shape, "\(spelling): `traits` honors the override")
      // Every other trait is the kind's, untouched by the override.
      XCTAssertEqual(resolved.traits.fallbackStyle, .litellmFallbacks)
      XCTAssertTrue(resolved.traits.requestsStreamUsage)
    }
    // Through the whole config file too.
    let config = #"{"provider":"gw","providers":{"gw":{"kind":"openai-compatible","baseURL":"https://gateway.example.com/v1","reasoningShape":"none"}}}"#
    let decoded = try JSONDecoder().decode(ArnesConfig.self, from: Data(config.utf8))
    XCTAssertEqual(decoded.providers?["gw"]?.reasoningShape, ReasoningShape.none)
    XCTAssertEqual(ProviderConfig.openrouter.reasoningShape, nil)
    // The `Reasoning.Effort.none` pitfall, pinned: on the optional field a bare `.none` is nil (no
    // override), the case has to be spelled out.
    XCTAssertNil(ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com/v1", reasoningShape: .none).reasoningShape)
    XCTAssertEqual(
      ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com/v1", reasoningShape: ReasoningShape.none).reasoningShape,
      ReasoningShape.none)
  }

  // MARK: Chat requests

  func testOpenAIShapeSendsTheTopLevelReasoningEffortString() async throws {
    let request = try await chatRequest(effort: .medium, shape: .openai)
    XCTAssertEqual(request.reasoningEffort, .medium)
    XCTAssertNil(request.reasoning, "never both spellings")
    let json = Fixtures.jsonValue(request)
    XCTAssertEqual(json["reasoning_effort"]?.stringValue, "medium", "the level rides verbatim")
    XCTAssertNil(json["reasoning"])
    // Every level verbatim — no remapping; `none` included, which is the dial's own value.
    for level in [Reasoning.Effort.minimal, .low, .high, .xhigh, .max, .none] {
      let sent = try await chatRequest(effort: level, shape: .openai)
      XCTAssertEqual(Fixtures.jsonValue(sent)["reasoning_effort"]?.stringValue, level.rawValue)
    }
  }

  func testOpenRouterShapeSendsTheReasoningObjectAsBefore() async throws {
    let request = try await chatRequest(effort: .medium, shape: .openrouter)
    XCTAssertEqual(request.reasoning?.effort, .medium)
    XCTAssertNil(request.reasoningEffort)
    let json = Fixtures.jsonValue(request)
    XCTAssertEqual(json["reasoning"]?["effort"]?.stringValue, "medium")
    XCTAssertNil(json["reasoning_effort"])
    // The pre-R3 bytes: a session that names no provider is on `.openrouter` traits and sends
    // exactly this object — `ReasoningEffortTests` pins that path unchanged.
    let control = MockOpenRouterService()
    control.manifestJSON = reasoningManifest(supportsReasoning: true)
    control.chunkScripts = [[Fixtures.textChunk("hi"), Fixtures.usageChunk(cost: 0)]]
    let plain = Session(
      service: control, tools: [], store: tempRecordStore(),
      configuration: .init(model: "test/model", reasoningEffort: .medium))
    for try await _ in await plain.send("go") { }
    let controlJSON = Fixtures.jsonValue(try XCTUnwrap(control.requests.first))
    XCTAssertEqual(controlJSON["reasoning"], json["reasoning"])
    XCTAssertNil(controlJSON["reasoning_effort"])
  }

  func testNoneShapeSendsNeitherAndIsByteIdenticalToNoDial() async throws {
    let dialed = try await chatRequest(effort: .medium, shape: .none)
    XCTAssertNil(dialed.reasoning)
    XCTAssertNil(dialed.reasoningEffort)
    let json = Fixtures.jsonValue(dialed)
    XCTAssertNil(json["reasoning"])
    XCTAssertNil(json["reasoning_effort"])
    let undialed = try await chatRequest(effort: nil, shape: .none)
    XCTAssertEqual(try sortedBytes(dialed), try sortedBytes(undialed), "the dial applies to no chat request under `none`")
  }

  func testNoDialSendsNeitherKeyOnEveryShape() async throws {
    var bytes: [Data] = []
    for shape in [ReasoningShape.openrouter, .openai, .none] {
      let request = try await chatRequest(effort: nil, shape: shape)
      let json = Fixtures.jsonValue(request)
      XCTAssertNil(json["reasoning"], "\(shape)")
      XCTAssertNil(json["reasoning_effort"], "\(shape)")
      bytes.append(try sortedBytes(request))
    }
    XCTAssertEqual(bytes[0], bytes[1], "the shape changes nothing without a dial")
    XCTAssertEqual(bytes[1], bytes[2])
  }

  func testAModelWithoutReasoningGetsNeitherKeyOnEveryShape() async throws {
    for shape in [ReasoningShape.openrouter, .openai, .none] {
      let request = try await chatRequest(effort: .high, shape: shape, supportsReasoning: false)
      let json = Fixtures.jsonValue(request)
      XCTAssertNil(json["reasoning"], "\(shape): the manifest gate is unchanged (invariant 1)")
      XCTAssertNil(json["reasoning_effort"], "\(shape)")
    }
  }

  // MARK: Native dialects and inheritance

  func testMessagesRequestsIgnoreTheChatShape() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [[
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
      Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
    ]]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(
        model: "anthropic/claude-test", reasoningEffort: .medium,
        provider: gateway(shape: .openai, nativeDialects: true)))
    _ = try await Events.drain(await session.send("hi"))
    XCTAssertEqual(mock.messagesRequests.count, 1)
    XCTAssertEqual(mock.requests.count, 0, "the turn ran on /messages")
    let request = Fixtures.jsonValue(mock.messagesRequests[0])
    XCTAssertEqual(request["thinking"]?["type"]?.stringValue, "enabled", "the /messages shape is its own API's")
    XCTAssertEqual(request["thinking"]?["budget_tokens"]?.intValue, 8192)
    XCTAssertNil(request["reasoning_effort"])
    XCTAssertNil(request["reasoning"])
  }

  func testResponsesRequestsIgnoreTheChatShape() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "openai/gpt-test"))
    mock.responsesEventScripts = [[
      Fixtures.responsesEvent(#"{"type":"response.created","response":{"id":"r0","model":"openai/gpt-test","output":[]}}"#),
      Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"done"}"#),
      Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":10}}}"#),
    ]]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(
        model: "openai/gpt-test", reasoningEffort: .medium,
        provider: gateway(shape: .none, nativeDialects: true)))
    _ = try await Events.drain(await session.send("hi"))
    XCTAssertEqual(mock.responsesRequests.count, 1)
    XCTAssertEqual(mock.requests.count, 0, "the turn ran on /responses")
    XCTAssertEqual(mock.responsesRequests[0].include, ["reasoning.encrypted_content"])
    let request = Fixtures.jsonValue(mock.responsesRequests[0])
    XCTAssertEqual(request["reasoning"]?["effort"]?.stringValue, "medium", "the /responses object is its own API's — `none` is about chat")
    XCTAssertNil(request["reasoning_effort"])
  }

  func testForSubagentCarriesTheTraits() {
    let lead = Session.Configuration(model: "test/model", provider: gateway(shape: .openai))
    let nested = lead.forSubagent(named: "explore", model: "test/model", systemSuffix: "role")
    XCTAssertEqual(nested.provider.reasoningShape, .openai)
    XCTAssertEqual(nested.provider, lead.provider, "the wire is the same wire")
  }
}
