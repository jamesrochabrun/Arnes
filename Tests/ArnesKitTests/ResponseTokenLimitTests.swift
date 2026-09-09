import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class ResponseTokenLimitTests: XCTestCase {
  private func session(_ mock: MockOpenRouterService, model: String = "test/model",
    limit: Int? = nil, dialect: DialectOverride = .chat, tools: [any AgentTool] = [],
    provider: ProviderTraits = .openrouter) -> Session
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-response-limit-\(UUID())")
    addTeardownBlock { try? FileManager.default.removeItem(at: root) }
    return Session(service: mock, tools: tools,
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      dialectStore: DialectVerdictStore(url: root.appendingPathComponent("dialects.json")),
      configuration: .init(model: model, dialect: dialect, reasoningEffort: .high,
        provider: provider, transport: .off, maxResponseTokens: limit))
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
    let replay = try XCTUnwrap(mock.requests[1].messages.first { $0.role == .assistant })
    XCTAssertEqual(replay.reasoningDetails?.first?["text"]?.stringValue, "thinking")
    XCTAssertEqual(record?.reasoningReplayed, 1)
    let history = await subject.history
    XCTAssertEqual(history.filter { $0.reasoningDetails?.isEmpty == false }.count, 2,
      "the last cutoff also survives for an explicit continuation")
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
      [Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","text":"Use the spy.","format":"unknown","index":0}]"#),
        Fixtures.toolCallChunk(id: "cut", name: "spy", arguments: #"{"path":"unfinished"#), Fixtures.finishChunk("length")],
      [Fixtures.toolCallChunk(id: "whole", name: "spy", arguments: "{}"), Fixtures.finishChunk("tool_calls")],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let spy = Spy()
    _ = try await Events.drain(await session(mock, limit: 8192, tools: [spy]).send("go"))
    XCTAssertEqual(spy.executions, 1)
    XCTAssertEqual(mock.requests.count, 3)
    XCTAssertTrue(mock.requests.allSatisfy { $0.maxTokens == 8192 })
    let replay = try XCTUnwrap(mock.requests[1].messages.first { $0.role == .assistant })
    XCTAssertEqual(replay.reasoningDetails?.first?["text"]?.stringValue, "Use the spy.")
    XCTAssertNil(replay.toolCalls, "the interrupted call must not survive with its reasoning")
    XCTAssertFalse(mock.requests.flatMap(\.messages).flatMap { $0.toolCalls ?? [] }.contains { $0.id == "cut" })
  }

  func testCutoffPreservesTextAndFullReasoningSequence() async throws {
    let mock = MockOpenRouterService()
    mock.chunkScripts = [
      [Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","text":"First ","format":"unknown","index":0}]"#),
        Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","text":"part.","index":0},{"type":"reasoning.text","text":"Second.","index":1}]"#),
        Fixtures.textChunk("Partial answer"), Fixtures.finishChunk("length")],
      [Fixtures.textChunk("done")],
    ]
    _ = try await Events.drain(await session(mock).send("go"))
    let replay = try XCTUnwrap(mock.requests[1].messages.first { $0.role == .assistant })
    XCTAssertEqual(replay.content?.plainText, "Partial answer")
    let expected = try JSONDecoder().decode([JSONValue].self, from: Data(
      #"[{"type":"reasoning.text","text":"First part.","format":"unknown","index":0},{"type":"reasoning.text","text":"Second.","index":1}]"#.utf8))
    XCTAssertEqual(replay.reasoningDetails, expected)
    XCTAssertTrue(mock.requests.allSatisfy { $0.maxTokens == nil }, "recovery does not introduce a cap")
  }

  func testCutoffDoesNotReplayUncertifiedReasoningOrPartOfAMixedSequence() async throws {
    let plain = #"{"type":"reasoning.text","text":"plain","format":"unknown","index":0}"#
    let unsupported = [
      #"{"type":"reasoning.text","text":"unsigned","format":"anthropic-claude-v1","index":1}"#,
      #"{"type":"reasoning.text","text":"signed","signature":"partial","index":1}"#,
      #"{"type":"reasoning.encrypted","data":"partial","index":1}"#,
      #"{"type":"reasoning.summary","summary":"partial","index":1}"#,
      #"{"type":"reasoning.text","text":"future","format":"future-v1","index":1}"#,
    ]
    for entry in unsupported {
      let mock = MockOpenRouterService()
      mock.chunkScripts = [
        [Fixtures.reasoningDetailsChunk("[\(plain),\(entry)]"),
          Fixtures.textChunk("Partial answer"), Fixtures.finishChunk("length")],
        [Fixtures.textChunk("done")],
      ]
      _ = try await Events.drain(await session(mock).send("go"))
      let replay = try XCTUnwrap(mock.requests[1].messages.first { $0.role == .assistant })
      XCTAssertEqual(replay.content?.plainText, "Partial answer")
      XCTAssertNil(replay.reasoningDetails)
    }
  }

  func testCutoffRespectsProvidersThatDoNotReplayReasoning() async throws {
    let mock = MockOpenRouterService()
    mock.chunkScripts = [
      [Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","text":"partial","index":0}]"#), Fixtures.finishChunk("length")],
      [Fixtures.textChunk("done")],
    ]
    let provider = ProviderTraits.forKind(.openaiCompatible, name: "gateway", defaultModel: "test/model", nativeDialects: false)
    _ = try await Events.drain(await session(mock, provider: provider).send("go"))
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertFalse(mock.requests[1].messages.contains { $0.role == .assistant },
      "do not send an empty assistant message after stripping unsupported reasoning")
  }

  func testModelSwapAfterCutoffKeepsHistoryPositionsAndOmitsEmptyAssistantRequests() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"), Fixtures.manifestModel(id: "test/other"))
    mock.chunkScripts = (0..<2).map { _ in [
      Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","text":"partial","index":0}]"#), Fixtures.finishChunk("length"),
    ] } + [[Fixtures.textChunk("done")]]
    let subject = session(mock)
    _ = try await Events.drain(await subject.send("go"))
    let before = await subject.history
    _ = try await subject.setModel("test/other")
    let after = await subject.history
    XCTAssertEqual(before.map(\.role), after.map(\.role))
    XCTAssertTrue(after.allSatisfy { $0.reasoningDetails == nil })
    _ = try await Events.drain(await subject.send("continue"))
    XCTAssertEqual(mock.requests.count, 3)
    XCTAssertFalse(mock.requests[2].messages.contains { $0.role == .assistant })
  }
}
