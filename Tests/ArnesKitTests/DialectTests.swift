import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class NativeDialectTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-dialect-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-dialect-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func drain(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream {
      events.append(event)
    }
    return events
  }

  // MARK: Translators

  func testMessagesTranslatorShapesToolUseAndMergesToolResults() throws {
    let history: [Message] = [
      .user("do it"),
      Message(role: .assistant, content: .text("working"), toolCalls: [
        ToolCall(id: "tu_1", type: "function", index: 0,
                 function: .init(name: "write_file", arguments: #"{"path":"a.txt"}"#)),
        ToolCall(id: "tu_2", type: "function", index: 1,
                 function: .init(name: "bash", arguments: #"{"command":"ls"}"#)),
      ]),
      .tool("wrote it", toolCallId: "tu_1"),
      .tool("a.txt", toolCallId: "tu_2"),
    ]

    let translated = Fixtures.jsonValue(MessagesTranslator.history(history)).arrayValue ?? []
    XCTAssertEqual(translated.count, 3)
    XCTAssertEqual(translated[0]["role"]?.stringValue, "user")

    let assistantBlocks = translated[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(assistantBlocks.count, 3)
    XCTAssertEqual(assistantBlocks[0]["type"]?.stringValue, "text")
    XCTAssertEqual(assistantBlocks[1]["type"]?.stringValue, "tool_use")
    XCTAssertEqual(assistantBlocks[1]["id"]?.stringValue, "tu_1")
    // Arguments arrive as a JSON string in chat shape and must become an object.
    XCTAssertEqual(assistantBlocks[1]["input"]?["path"]?.stringValue, "a.txt")
    XCTAssertEqual(assistantBlocks[2]["id"]?.stringValue, "tu_2")

    // Both chat `.tool` messages merge into ONE user message of tool_result blocks.
    XCTAssertEqual(translated[2]["role"]?.stringValue, "user")
    let resultBlocks = translated[2]["content"]?.arrayValue ?? []
    XCTAssertEqual(resultBlocks.count, 2)
    XCTAssertEqual(resultBlocks[0]["type"]?.stringValue, "tool_result")
    XCTAssertEqual(resultBlocks[0]["tool_use_id"]?.stringValue, "tu_1")
    XCTAssertEqual(resultBlocks[1]["tool_use_id"]?.stringValue, "tu_2")
  }

  func testResponsesTranslatorShapesFunctionCallsAndOutputs() throws {
    let history: [Message] = [
      .user("do it"),
      Message(role: .assistant, content: nil, toolCalls: [
        ToolCall(id: "call_1", type: "function", index: 0,
                 function: .init(name: "write_file", arguments: #"{"path":"a.txt"}"#)),
      ]),
      .tool("wrote it", toolCallId: "call_1"),
    ]

    let items = Fixtures.jsonValue(ResponsesTranslator.history(history)).arrayValue ?? []
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items[0]["type"]?.stringValue, "message")
    XCTAssertEqual(items[1]["type"]?.stringValue, "function_call")
    XCTAssertEqual(items[1]["call_id"]?.stringValue, "call_1")
    XCTAssertEqual(items[1]["arguments"]?.stringValue, #"{"path":"a.txt"}"#)
    XCTAssertEqual(items[2]["type"]?.stringValue, "function_call_output")
    XCTAssertEqual(items[2]["call_id"]?.stringValue, "call_1")
    XCTAssertEqual(items[2]["output"]?.stringValue, "wrote it")
  }

  // MARK: Accumulators

  func testMessagesAccumulatorFoldsToolUseStream() {
    var accumulator = MessagesAccumulator()
    let events = [
      #"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":12}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"text"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"on it"}}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"write_file"}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"a.txt\"}"}}"#,
      #"{"type":"content_block_stop","index":1}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9,"cost":0.003}}"#,
      #"{"type":"message_stop"}"#,
    ]
    for json in events {
      _ = accumulator.ingest(Fixtures.messagesEvent(json))
    }

    XCTAssertEqual(accumulator.text, "on it")
    XCTAssertEqual(accumulator.routedModel, "anthropic/claude-test")
    XCTAssertEqual(accumulator.promptTokens, 12)
    XCTAssertEqual(accumulator.cost, 0.003)
    XCTAssertEqual(accumulator.stopReason, "tool_use")
    let calls = accumulator.toolCalls
    XCTAssertEqual(calls.count, 1)
    XCTAssertEqual(calls[0].id, "tu_1")
    XCTAssertEqual(calls[0].function?.name, "write_file")
    XCTAssertEqual(calls[0].function?.arguments, #"{"path":"a.txt"}"#)
  }

  func testResponsesAccumulatorFoldsFunctionCallStream() {
    var accumulator = ResponsesAccumulator()
    let events = [
      #"{"type":"response.created","response":{"id":"r0","model":"openai/gpt-test","output":[]}}"#,
      #"{"type":"response.output_text.delta","delta":"on it"}"#,
      #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"write_file","arguments":"","id":"item_1"}}"#,
      #"{"type":"response.function_call_arguments.delta","item_id":"item_1","delta":"{\"path\":"}"#,
      #"{"type":"response.function_call_arguments.delta","item_id":"item_1","delta":"\"a.txt\"}"}"#,
      #"{"type":"response.function_call_arguments.done","item_id":"item_1","arguments":"{\"path\":\"a.txt\"}"}"#,
      #"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[],"usage":{"input_tokens":9,"cost":0.002}}}"#,
    ]
    for json in events {
      _ = accumulator.ingest(Fixtures.responsesEvent(json))
    }

    XCTAssertEqual(accumulator.text, "on it")
    XCTAssertEqual(accumulator.routedModel, "openai/gpt-test")
    XCTAssertEqual(accumulator.promptTokens, 9)
    XCTAssertEqual(accumulator.cost, 0.002)
    XCTAssertNil(accumulator.failure)
    let calls = accumulator.toolCalls
    XCTAssertEqual(calls.count, 1)
    // call_id (not the item id) is what must round-trip into function_call_output.
    XCTAssertEqual(calls[0].id, "call_1")
    XCTAssertEqual(calls[0].function?.name, "write_file")
    XCTAssertEqual(calls[0].function?.arguments, #"{"path":"a.txt"}"#)
  }

  // MARK: End-to-end turns

  func testSessionRunsAnthropicModelNativelyOnMessages() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":10}}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"write_file"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"out.txt\",\"content\":\"hola\"}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = Session(
      service: mock,
      tools: [WriteFileTool(root: root)],
      store: tempRecordStore(),
      configuration: .init(model: "anthropic/claude-test"))

    _ = try await drain(await session.send("write out.txt"))

    // The real tool executed from the natively streamed call.
    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8),
      "hola")
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "messages")
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.routedModels, ["anthropic/claude-test"])
    XCTAssertEqual(record.costUSD, 0.02, accuracy: 0.0001)

    // The second request carries the tool round-trip in Anthropic shape.
    XCTAssertEqual(mock.messagesRequests.count, 2)
    let second = Fixtures.jsonValue(mock.messagesRequests[1].messages).arrayValue ?? []
    XCTAssertEqual(second.count, 3)
    let toolUse = second[1]["content"]?.arrayValue?.first
    XCTAssertEqual(toolUse?["type"]?.stringValue, "tool_use")
    XCTAssertEqual(toolUse?["input"]?["path"]?.stringValue, "out.txt")
    let toolResult = second[2]["content"]?.arrayValue?.first
    XCTAssertEqual(toolResult?["type"]?.stringValue, "tool_result")
    XCTAssertEqual(toolResult?["tool_use_id"]?.stringValue, "tu_1")
    // Tool definitions travel in Anthropic's flat shape with input_schema.
    let tools = Fixtures.jsonValue(mock.messagesRequests[0].tools).arrayValue ?? []
    XCTAssertEqual(tools.first?["name"]?.stringValue, "write_file")
    XCTAssertNotNil(tools.first?["input_schema"])
  }

  func testSessionRunsOpenAIModelNativelyOnResponses() async throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "openai/gpt-test"))
    mock.responsesEventScripts = [
      [
        Fixtures.responsesEvent(#"{"type":"response.created","response":{"id":"r0","model":"openai/gpt-test","output":[]}}"#),
        Fixtures.responsesEvent(#"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"write_file","arguments":"","id":"item_1"}}"#),
        Fixtures.responsesEvent(#"{"type":"response.function_call_arguments.done","item_id":"item_1","arguments":"{\"path\":\"out.txt\",\"content\":\"hola\"}"}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":10}}}"#),
      ],
      [
        Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"done"}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r1","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":12}}}"#),
      ],
    ]
    let session = Session(
      service: mock,
      tools: [WriteFileTool(root: root)],
      store: tempRecordStore(),
      configuration: .init(model: "openai/gpt-test"))

    _ = try await drain(await session.send("write out.txt"))

    XCTAssertEqual(
      try String(contentsOf: root.appendingPathComponent("out.txt"), encoding: .utf8),
      "hola")
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "responses")
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.costUSD, 0.02, accuracy: 0.0001)

    // The second request replays the call and its output with the same call_id.
    XCTAssertEqual(mock.responsesRequests.count, 2)
    let items = Fixtures.jsonValue(mock.responsesRequests[1].input).arrayValue ?? []
    XCTAssertEqual(items.count, 3)
    XCTAssertEqual(items[1]["type"]?.stringValue, "function_call")
    XCTAssertEqual(items[1]["call_id"]?.stringValue, "call_1")
    XCTAssertEqual(items[2]["type"]?.stringValue, "function_call_output")
    XCTAssertEqual(items[2]["call_id"]?.stringValue, "call_1")
    XCTAssertEqual(items[2]["output"]?.stringValue.map { $0.contains("wrote") }, true)
  }

  func testForcedChatDialectOverridesNativeFamily() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.chunkScripts = [
      [Fixtures.textChunk("hi"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [],
      store: tempRecordStore(),
      configuration: .init(model: "anthropic/claude-test", dialect: .chat))

    _ = try await drain(await session.send("say hi"))

    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertTrue(mock.messagesRequests.isEmpty)
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.dialect, "chat")
  }
}
