import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class ResponseTokenLimitTests: XCTestCase {
  private func session(_ mock: MockOpenRouterService, model: String = "test/model",
    limit: Int? = nil, dialect: DialectOverride = .chat, tools: [any AgentTool] = []) -> Session
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-response-limit-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Session(service: mock, tools: tools,
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      dialectStore: DialectVerdictStore(url: root.appendingPathComponent("dialects.json")),
      configuration: .init(model: model, dialect: dialect, reasoningEffort: .high,
        transport: .off, maxResponseTokens: limit))
  }

  func testChatLimitUsesManifestCeilingAndIsAbsentByDefault() async throws {
    for limit in [nil, 8192, 32768] as [Int?] {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model", maxCompletionTokens: 16384))
      mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)]]
      _ = try await Events.drain(await session(mock, limit: limit).send("go"))
      let request = try XCTUnwrap(mock.requests.first)
      XCTAssertEqual(request.maxTokens, limit.map { min($0, 16384) })
      XCTAssertNil(request.maxCompletionTokens)
      XCTAssertEqual(request.reasoning?.effort, .high)
      XCTAssertFalse(request.messages.contains { $0.content?.plainText.contains("arnes time budget") == true })
    }
  }

  func testAdvertisedChatCompletionLimitReachesTheTypedRequest() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = #"[{"id":"test/model","supported_parameters":["tools","reasoning","max_completion_tokens"]}]"#
    mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)]]
    _ = try await Events.drain(await session(mock, limit: 8192).send("go"))
    let request = try XCTUnwrap(mock.requests.first)
    XCTAssertEqual(request.maxCompletionTokens, 8192)
    XCTAssertNil(request.maxTokens)
  }

  func testChatSpellingComesFromManifestOrSparseProviderDefault() throws {
    let modern = try JSONDecoder().decode(OpenRouterModel.self, from: Data(
      #"{"id":"test/model","supported_parameters":["max_completion_tokens","reasoning"]}"#.utf8))
    let profile = ModelProfile(model: modern)
    XCTAssertEqual(profile.supportsMaxCompletionTokens, true)
    XCTAssertEqual(ProviderTraits.openrouter.chatOutputLimit(20, profile: profile).completionTokens, 20)
    let sparse = ModelProfile(unknownModelId: "alias")
    for shape in [ReasoningShape.openai, .none] {
      let gateway = ProviderTraits.forKind(.openaiCompatible, name: "gateway", defaultModel: "alias",
        nativeDialects: false, reasoningShape: shape)
      XCTAssertEqual(gateway.chatOutputLimit(20, profile: sparse).completionTokens, 20)
    }
    XCTAssertEqual(ProviderTraits.openrouter.chatOutputLimit(20, profile: sparse).tokens, 20)
    // A pre-field cache row still decodes, and the provider resolves the unstated spelling.
    var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
    old.removeValue(forKey: "supportsMaxCompletionTokens")
    let restored = try JSONDecoder().decode(ModelProfile.self, from: JSONSerialization.data(withJSONObject: old))
    XCTAssertNil(restored.supportsMaxCompletionTokens)
  }

  func testNativeMessagesCapLeavesValidThinkingHeadroom() async throws {
    for limit in [nil, 8192, 512] as [Int?] {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "anthropic/claude-test"))
      mock.messagesEventScripts = [[
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0}}"#),
      ]]
      _ = try await Events.drain(await session(mock, model: "anthropic/claude-test", limit: limit, dialect: .messages).send("go"))
      let request = try XCTUnwrap(mock.messagesRequests.first)
      XCTAssertEqual(request.maxTokens, limit ?? (Session.thinkingBudget(for: .high) + MessagesTranslator.maxOutputTokens))
      if let limit, limit < MessagesTranslator.minimumThinkingBudget {
        XCTAssertNil(request.thinking)
      } else if case .enabled(let budget, _) = request.thinking {
        XCTAssertLessThan(budget, try XCTUnwrap(request.maxTokens))
      } else { XCTFail("Expected thinking with room under the cap") }
      XCTAssertTrue(mock.requests.isEmpty, "no fallback should mask a malformed shape")
    }
  }

  func testNativeResponsesUsesTypedMaxOutputTokens() async throws {
    for limit in [nil, 8192, 32768] as [Int?] {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "openai/gpt-test", maxCompletionTokens: 16384))
      mock.responsesEventScripts = [[
        Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"done"}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r1","model":"openai/gpt-test","output":[],"usage":{"cost":0,"input_tokens":10}}}"#),
      ]]
      _ = try await Events.drain(await session(mock, model: "openai/gpt-test", limit: limit, dialect: .responses).send("go"))
      XCTAssertEqual(mock.responsesRequests.first?.maxOutputTokens, limit.map { min($0, 16384) })
      XCTAssertEqual(mock.responsesRequests.count, 1)
      XCTAssertTrue(mock.requests.isEmpty)
    }
  }

  func testReasoningOnlyCutoffHasOneBoundedContinuationUnderSameCap() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model"))
    mock.chunkScripts = (0..<2).map { _ in [
      Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","text":"thinking","index":0}]"#),
      Fixtures.finishChunk("length"),
    ] }
    let subject = session(mock, limit: 8192)
    _ = try await Events.drain(await subject.send("go"))
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertTrue(mock.requests.allSatisfy { $0.maxTokens == 8192 })
    let record = await subject.lastRecord
    XCTAssertEqual(record?.stopReason, .truncated)
    XCTAssertTrue(mock.requests[1].messages.contains { $0.role == .user && $0.content?.plainText.contains("cut off at the output limit") == true })
  }

  private final class Spy: AgentTool, @unchecked Sendable {
    let name = "spy"
    let description = "Record execution"
    let parameters: JSONValue = ["type": "object", "properties": [:]]
    var permission: ToolPermission { .readOnly }
    private let lock = NSLock()
    private var calls = 0
    var executions: Int { lock.withLock { calls } }
    func execute(arguments: [String: JSONValue]) async throws -> String {
      lock.withLock { calls += 1 }
      return "done"
    }
  }

  func testCapNeverDispatchesPartialToolArguments() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "cut", name: "spy", arguments: #"{"path":"unfinished"#), Fixtures.finishChunk("length")],
      [Fixtures.toolCallChunk(id: "whole", name: "spy", arguments: "{}"), Fixtures.finishChunk("tool_calls")],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let spy = Spy()
    _ = try await Events.drain(await session(mock, limit: 8192, tools: [spy]).send("go"))
    XCTAssertEqual(spy.executions, 1)
    XCTAssertEqual(mock.requests.count, 3)
    XCTAssertTrue(mock.requests.allSatisfy { $0.maxTokens == 8192 })
  }
}
