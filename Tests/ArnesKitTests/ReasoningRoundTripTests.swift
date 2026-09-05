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

/// R1 — the reasoning state a thinking model leaves behind (signed `thinking` blocks on
/// `/messages`, `encrypted_content` on `/responses`, `reasoning_details` on chat) is captured
/// per step, carried on the assistant message and its transcript line, and replayed in the
/// dialect's own shape on the next request — or deliberately not, when the request cannot
/// carry it (the thinking rule, a model swap, a gateway that may reject the field).
final class ReasoningRoundTripTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-reasoning-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDialectStore() -> DialectVerdictStore {
    DialectVerdictStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-reasoning-verdicts-\(UUID().uuidString).jsonl"))
  }

  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-reasoning-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  // The entries as the accumulators build them — one place for the shapes the tests read back.
  private let signedEntry = ReasoningDetails.text("let me think", signature: "sig-1", format: ReasoningDetails.Format.anthropic)
  private let redactedEntry = ReasoningDetails.encrypted(data: "redacted-1", id: nil, format: ReasoningDetails.Format.anthropic)
  private let openaiEntry = ReasoningDetails.encrypted(data: "enc-1", id: "rs_1", format: ReasoningDetails.Format.openaiResponses)

  private func toolCall(_ id: String = "tu_1") -> ToolCall {
    ToolCall(id: id, type: "function", index: 0, function: .init(name: "ping", arguments: "{}"))
  }

  // MARK: Accumulators

  func testMessagesAccumulatorCapturesSignedThinkingAndRedactedBlocksInOrder() {
    var accumulator = MessagesAccumulator()
    var streamed = ""
    let events = [
      #"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":12}}}"#,
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"let me "}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"think"}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-1"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"redacted_thinking","data":"redacted-1"}}"#,
      #"{"type":"content_block_stop","index":1}"#,
      #"{"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"tu_1","name":"ping"}}"#,
      #"{"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#,
      #"{"type":"content_block_stop","index":2}"#,
      #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#,
    ]
    for json in events {
      if let piece = accumulator.ingest(Fixtures.messagesEvent(json)).reasoning {
        streamed += piece
      }
    }

    XCTAssertEqual(streamed, "let me think", "thinking still streams as reasoning deltas")
    XCTAssertEqual(accumulator.reasoning, "let me think")
    XCTAssertEqual(accumulator.unsignedThinkingBlocks, 0)
    let details = accumulator.reasoningDetails
    XCTAssertEqual(details.count, 2)
    XCTAssertEqual(details[0]["type"]?.stringValue, ReasoningDetails.EntryType.text)
    XCTAssertEqual(details[0]["text"]?.stringValue, "let me think")
    XCTAssertEqual(details[0]["signature"]?.stringValue, "sig-1")
    XCTAssertEqual(details[0]["format"]?.stringValue, "anthropic-claude-v1")
    XCTAssertEqual(details[1]["type"]?.stringValue, ReasoningDetails.EntryType.encrypted)
    XCTAssertEqual(details[1]["data"]?.stringValue, "redacted-1")
    XCTAssertEqual(details[1]["format"]?.stringValue, "anthropic-claude-v1")
    XCTAssertEqual(accumulator.toolCalls.map(\.id), ["tu_1"], "the tool use is untouched by the thinking blocks")
  }

  func testMessagesAccumulatorDropsAndCountsAnUnsignedThinkingBlock() {
    var accumulator = MessagesAccumulator()
    let events = [
      #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
      #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}"#,
      #"{"type":"content_block_stop","index":0}"#,
      #"{"type":"content_block_start","index":1,"content_block":{"type":"text"}}"#,
      #"{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"done"}}"#,
    ]
    for json in events {
      _ = accumulator.ingest(Fixtures.messagesEvent(json))
    }
    XCTAssertEqual(accumulator.reasoning, "hmm", "the text is still shown")
    XCTAssertTrue(accumulator.reasoningDetails.isEmpty, "an unsigned block cannot be replayed, so it is not carried")
    XCTAssertEqual(accumulator.unsignedThinkingBlocks, 1)
    XCTAssertEqual(accumulator.text, "done")
  }

  func testResponsesAccumulatorKeepsEncryptedReasoningOncePerItem() {
    var accumulator = ResponsesAccumulator()
    let reasoning = #"{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc-1"}"#
    let plain = #"{"type":"reasoning","id":"rs_2","summary":[{"type":"summary_text","text":"thought"}]}"#
    let events = [
      #"{"type":"response.created","response":{"id":"r0","model":"openai/gpt-test","output":[]}}"#,
      #"{"type":"response.output_item.added","output_index":0,"item":\#(reasoning)}"#,
      #"{"type":"response.output_item.done","output_index":0,"item":\#(reasoning)}"#,
      #"{"type":"response.output_item.added","output_index":1,"item":\#(plain)}"#,
      #"{"type":"response.output_item.added","output_index":2,"item":{"type":"function_call","call_id":"call_1","name":"ping","arguments":"{}","id":"item_1"}}"#,
      #"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[\#(reasoning),\#(plain)],"usage":{"input_tokens":9}}}"#,
    ]
    for json in events {
      _ = accumulator.ingest(Fixtures.responsesEvent(json))
    }
    let details = accumulator.reasoningDetails
    XCTAssertEqual(details.count, 1, "added + done + the completed output are one item; a summary-only item leaves nothing to echo")
    XCTAssertEqual(details[0]["type"]?.stringValue, ReasoningDetails.EntryType.encrypted)
    XCTAssertEqual(details[0]["id"]?.stringValue, "rs_1")
    XCTAssertEqual(details[0]["data"]?.stringValue, "enc-1")
    XCTAssertEqual(details[0]["format"]?.stringValue, "openai-responses-v1")
    XCTAssertEqual(accumulator.toolCalls.map(\.id), ["call_1"])
  }

  func testChatAccumulatorMergesReasoningDetailFragmentsByIndex() {
    var accumulator = StreamAccumulator()
    let chunks = [
      Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","index":0,"text":"let me ","format":"anthropic-claude-v1"}]"#),
      Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","index":0,"text":"think","signature":"sig-1","format":"anthropic-claude-v1"}]"#),
      Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.encrypted","index":1,"data":"opaque","format":"anthropic-claude-v1"}]"#),
      Fixtures.toolCallChunk(id: "tu_1", name: "ping", arguments: "{}"),
    ]
    for chunk in chunks {
      _ = accumulator.ingest(chunk)
    }
    let details = accumulator.reasoningDetails
    XCTAssertEqual(details.count, 2)
    XCTAssertEqual(details[0]["text"]?.stringValue, "let me think", "text concatenates across fragments")
    XCTAssertEqual(details[0]["signature"]?.stringValue, "sig-1", "the signature lands on the last fragment")
    XCTAssertEqual(details[0]["index"]?.intValue, 0)
    XCTAssertEqual(details[1]["data"]?.stringValue, "opaque")
    XCTAssertEqual(accumulator.toolCalls.count, 1)

    var none = StreamAccumulator()
    _ = none.ingest(Fixtures.textChunk("hi"))
    XCTAssertTrue(none.reasoningDetails.isEmpty, "a router that sends none yields none")
  }

  // MARK: Translators

  func testMessagesTranslatorReplaysThinkingBlocksFirstAndOnlyWhenEnabled() throws {
    let history: [Message] = [
      .user("do it"),
      Message(role: .assistant, content: .text("on it"), toolCalls: [toolCall()],
              reasoningDetails: [signedEntry, redactedEntry, openaiEntry]),
      .tool("pong", toolCallId: "tu_1"),
    ]

    let enabled = Fixtures.jsonValue(MessagesTranslator.history(history, thinkingEnabled: true)).arrayValue ?? []
    let blocks = enabled[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.map { $0["type"]?.stringValue }, ["thinking", "redacted_thinking", "text", "tool_use"],
                   "thinking first, the other dialect's entry skipped")
    XCTAssertEqual(blocks[0]["thinking"]?.stringValue, "let me think")
    XCTAssertEqual(blocks[0]["signature"]?.stringValue, "sig-1")
    XCTAssertEqual(blocks[1]["data"]?.stringValue, "redacted-1")

    let disabled = Fixtures.jsonValue(MessagesTranslator.history(history, thinkingEnabled: false)).arrayValue ?? []
    XCTAssertEqual(disabled[1]["content"]?.arrayValue?.map { $0["type"]?.stringValue }, ["text", "tool_use"],
                   "a request without thinking carries no thinking block")
    XCTAssertEqual(
      Fixtures.jsonValue(MessagesTranslator.history(history)),
      Fixtures.jsonValue(disabled),
      "the default is the pre-R1 shape")
  }

  func testCanEnableThinkingFollowsTheLastAssistantToolTurn() {
    let noHistory: [Message] = []
    XCTAssertTrue(MessagesTranslator.canEnableThinking(history: noHistory))
    XCTAssertTrue(MessagesTranslator.canEnableThinking(history: [.user("hi"), .assistant("hello"), .user("more")]),
                  "a text-only assistant turn needs no block")
    XCTAssertFalse(MessagesTranslator.canEnableThinking(history: [
      .user("hi"), Message(role: .assistant, content: nil, toolCalls: [toolCall()]), .tool("pong", toolCallId: "tu_1"),
    ]), "a tool turn with no block would be refused")
    XCTAssertTrue(MessagesTranslator.canEnableThinking(history: [
      .user("hi"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall()], reasoningDetails: [redactedEntry]),
      .tool("pong", toolCallId: "tu_1"),
    ]), "a redacted block satisfies the rule")
    XCTAssertFalse(MessagesTranslator.canEnableThinking(history: [
      .user("hi"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall()], reasoningDetails: [openaiEntry]),
      .tool("pong", toolCallId: "tu_1"),
    ]), "another dialect's entry is not Anthropic's")
    XCTAssertTrue(MessagesTranslator.canEnableThinking(history: [
      .user("hi"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall("tu_0")]),
      .tool("pong", toolCallId: "tu_0"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall()], reasoningDetails: [signedEntry]),
      .tool("pong", toolCallId: "tu_1"),
    ]), "only the last assistant turn decides; Anthropic strips older turns' blocks itself")
    XCTAssertTrue(MessagesTranslator.canEnableThinking(history: [
      .user("hi"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall()]),
      .tool("pong", toolCallId: "tu_1"),
      .assistant("done"),
    ]), "a final text turn after the tool turn is fine")
  }

  func testResponsesTranslatorEchoesEncryptedReasoningBeforeTheFunctionCall() throws {
    let history: [Message] = [
      .user("do it"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall("call_1")],
              reasoningDetails: [openaiEntry, signedEntry]),
      .tool("pong", toolCallId: "call_1"),
    ]
    let items = Fixtures.jsonValue(ResponsesTranslator.history(history)).arrayValue ?? []
    XCTAssertEqual(items.map { $0["type"]?.stringValue }, ["message", "reasoning", "function_call", "function_call_output"],
                   "the reasoning item precedes the call it produced; the Anthropic entry is skipped")
    XCTAssertEqual(items[1]["id"]?.stringValue, "rs_1")
    XCTAssertEqual(items[1]["encrypted_content"]?.stringValue, "enc-1")
    XCTAssertEqual(items[1]["summary"]?.arrayValue?.count, 0)
  }

  func testOutputPlanHonorsTheManifestCeilingAndKeepsTodaysNumbersWithoutOne() {
    // No manifest value: exactly the pre-R1 numbers.
    XCTAssertEqual(MessagesTranslator.outputPlan(maxCompletionTokens: nil, thinkingBudget: nil).maxTokens, 8192)
    let medium = MessagesTranslator.outputPlan(maxCompletionTokens: nil, thinkingBudget: 8192)
    XCTAssertEqual(medium.maxTokens, 16384)
    XCTAssertEqual(medium.budget, 8192)
    // A generous ceiling is never a target.
    let roomy = MessagesTranslator.outputPlan(maxCompletionTokens: 64000, thinkingBudget: 8192)
    XCTAssertEqual(roomy.maxTokens, 16384)
    XCTAssertEqual(roomy.budget, 8192)
    // A tight ceiling caps max_tokens and clamps the budget under it.
    XCTAssertEqual(MessagesTranslator.outputPlan(maxCompletionTokens: 4096, thinkingBudget: nil).maxTokens, 4096)
    let tight = MessagesTranslator.outputPlan(maxCompletionTokens: 4096, thinkingBudget: 16384)
    XCTAssertEqual(tight.maxTokens, 4096)
    XCTAssertEqual(tight.budget, 3072)
    // Exactly the minimum budget plus its headroom still thinks.
    let minimal = MessagesTranslator.outputPlan(maxCompletionTokens: 2048, thinkingBudget: 8192)
    XCTAssertEqual(minimal.maxTokens, 2048)
    XCTAssertEqual(minimal.budget, 1024)
    // A ceiling with no room for the minimum budget plus headroom turns thinking off for the
    // model — never `budget_tokens ≥ max_tokens`, the request Anthropic refuses every turn.
    let cramped = MessagesTranslator.outputPlan(maxCompletionTokens: 1500, thinkingBudget: 8192)
    XCTAssertEqual(cramped.maxTokens, 1500)
    XCTAssertNil(cramped.budget)
    let tiny = MessagesTranslator.outputPlan(maxCompletionTokens: 1024, thinkingBudget: 8192)
    XCTAssertEqual(tiny.maxTokens, 1024)
    XCTAssertNil(tiny.budget)
    // The invariant the request relies on: a budget is always strictly under max_tokens.
    for ceiling in [1024, 1025, 2047, 2048, 2049, 4096, 9000, 64000] {
      for budget in [1024, 4096, 8192, 16384, 24576] {
        let plan = MessagesTranslator.outputPlan(maxCompletionTokens: ceiling, thinkingBudget: budget)
        XCTAssertLessThanOrEqual(plan.maxTokens, ceiling)
        if let planned = plan.budget {
          XCTAssertLessThan(planned, plan.maxTokens, "ceiling \(ceiling), budget \(budget)")
          XCTAssertGreaterThanOrEqual(planned, 1024)
        }
      }
    }
  }

  // MARK: Session — /messages

  func testMessagesSessionReplaysTheSignedThinkingBlockWithEffort() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.reasoningManifestModel(id: "anthropic/claude-test", maxCompletionTokens: 64000))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":10}}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"ping first"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig-abc"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_stop","index":0}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu_1","name":"ping"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", reasoningEffort: .medium))

    _ = try await Events.drain(await session.send("ping"))

    XCTAssertEqual(mock.messagesRequests.count, 2)
    let first = Fixtures.jsonValue(mock.messagesRequests[0])
    XCTAssertEqual(first["thinking"]?["type"]?.stringValue, "enabled")
    XCTAssertEqual(first["thinking"]?["budget_tokens"]?.intValue, 8192)
    XCTAssertEqual(first["max_tokens"]?.intValue, 16384, "budget + the default, under the 64000 ceiling")

    let second = Fixtures.jsonValue(mock.messagesRequests[1])
    XCTAssertEqual(second["thinking"]?["type"]?.stringValue, "enabled", "the history can carry thinking, so it stays on")
    let messages = second["messages"]?.arrayValue ?? []
    XCTAssertEqual(messages.count, 3)
    let blocks = messages[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.map { $0["type"]?.stringValue }, ["thinking", "tool_use"], "the signed block leads the tool use")
    XCTAssertEqual(blocks[0]["thinking"]?.stringValue, "ping first")
    XCTAssertEqual(blocks[0]["signature"]?.stringValue, "sig-abc")

    let history = await session.history
    XCTAssertEqual(history[1].reasoningDetails?.count, 1, "the assistant message carries the entry")
    XCTAssertNil(history[3].reasoningDetails, "the natural-finish text turn carries none")
    let record = await session.lastRecord
    XCTAssertEqual(record?.reasoningBlocks, 1)
    XCTAssertEqual(record?.reasoningReplayed, 1, "the second request put the signed block back — the round-trip happened")
    XCTAssertTrue(record?.finished == true)
  }

  func testMessagesSessionDisablesThinkingForAStepTheHistoryCannotCarry() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "anthropic/claude-test"))
    // Step 1 returns a tool use with no thinking block at all (nothing signed to replay).
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"ping"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", reasoningEffort: .medium))

    _ = try await Events.drain(await session.send("ping"))

    XCTAssertEqual(mock.messagesRequests.count, 2)
    let first = Fixtures.jsonValue(mock.messagesRequests[0])
    XCTAssertEqual(first["thinking"]?["type"]?.stringValue, "enabled", "a fresh history carries thinking")
    let second = Fixtures.jsonValue(mock.messagesRequests[1])
    XCTAssertNil(second["thinking"], "the thinking rule: no thinking field for a step the history can't carry")
    XCTAssertEqual(second["max_tokens"]?.intValue, 8192, "and the plain max_tokens with it")
    let blocks = second["messages"]?.arrayValue?[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.map { $0["type"]?.stringValue }, ["tool_use"])
    let record = await session.lastRecord
    XCTAssertTrue(record?.finished == true, "no 400 by construction; the turn finishes on /messages")
    XCTAssertEqual(record?.dialect, "messages")
    XCTAssertNil(record?.reasoningBlocks)
    XCTAssertNil(record?.reasoningReplayed, "a thinking-less step replays no block")
  }

  func testThinkingStaysOffForTheRestOfTheTurnsToolStepsAndReturnsNextTurn() async throws {
    // The rule's reach: a step that ran without thinking produces a tool-call turn with no
    // thinking block, so the following step is disabled by the same rule, and so on until the
    // turn ends with a text finish. The next user message starts with thinking on again.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "anthropic/claude-test"))
    let unsignedToolUse = [
      Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"ping"}}"#),
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#),
      Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
    ]
    let finish = [
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
      Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
    ]
    // Turn 1: three steps — two tool uses without a block, then the finish. Turn 2: a finish.
    mock.messagesEventScripts = [unsignedToolUse, unsignedToolUse, finish, finish]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", reasoningEffort: .medium))

    _ = try await Events.drain(await session.send("ping twice"))
    XCTAssertEqual(mock.messagesRequests.count, 3)
    let requests = mock.messagesRequests.map(Fixtures.jsonValue)
    XCTAssertEqual(requests[0]["thinking"]?["type"]?.stringValue, "enabled", "a fresh history carries thinking")
    XCTAssertNil(requests[1]["thinking"], "step 2: the last tool turn has no block")
    XCTAssertNil(requests[2]["thinking"], "step 3: the step that ran without thinking left none either — the rest of the turn runs without it")
    XCTAssertEqual(requests[2]["max_tokens"]?.intValue, 8192)
    let first = await session.lastRecord
    XCTAssertTrue(first?.finished == true)
    XCTAssertEqual(first?.dialect, "messages", "never a 400, never a fallback")

    _ = try await Events.drain(await session.send("and again"))
    XCTAssertEqual(mock.messagesRequests.count, 4)
    let next = Fixtures.jsonValue(mock.messagesRequests[3])
    XCTAssertEqual(next["thinking"]?["type"]?.stringValue, "enabled",
                   "the last assistant message is a text finish with no tool_use, so thinking is back")
  }

  func testEffortNoneStillSendsTheExplicitDisabledThinking() async throws {
    // `--effort none` is the one dial value that sends a `thinking` field with thinking off:
    // `{type: disabled}` and the plain max_tokens, exactly as before R1, on every step.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"ping"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    // Spelled out: a bare `.none` against the optional parameter is `Optional.none` (nil), the
    // pre-R1 trap this test would otherwise fall into.
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", reasoningEffort: Reasoning.Effort.none))

    _ = try await Events.drain(await session.send("ping"))

    XCTAssertEqual(mock.messagesRequests.count, 2)
    for request in mock.messagesRequests.map(Fixtures.jsonValue) {
      XCTAssertEqual(request["thinking"]?["type"]?.stringValue, "disabled")
      XCTAssertNil(request["thinking"]?["budget_tokens"])
      XCTAssertEqual(request["max_tokens"]?.intValue, 8192)
    }
    let blocks = Fixtures.jsonValue(mock.messagesRequests[1])["messages"]?.arrayValue?[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.map { $0["type"]?.stringValue }, ["tool_use"], "no thinking block on a request with thinking off")
  }

  func testMessagesSessionSendsNoThinkingUnderACeilingTooSmallForABudget() async throws {
    // A manifest ceiling with no room for the minimum budget plus its headroom: the dial is set
    // and the history could carry thinking, but the only budget that fits is one Anthropic
    // refuses — so no `thinking` field, the plain ceiling as max_tokens, and no block replayed.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.reasoningManifestModel(id: "anthropic/claude-test", maxCompletionTokens: 1024))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"ping"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", reasoningEffort: .high))

    _ = try await Events.drain(await session.send("ping"))

    XCTAssertEqual(mock.messagesRequests.count, 2)
    for request in mock.messagesRequests.map(Fixtures.jsonValue) {
      XCTAssertNil(request["thinking"], "no budget fits under a 1024 ceiling — thinking is off for this model")
      XCTAssertEqual(request["max_tokens"]?.intValue, 1024, "the ceiling itself, never above it")
    }
    let record = await session.lastRecord
    XCTAssertTrue(record?.finished == true)
    XCTAssertEqual(record?.dialect, "messages")
  }

  func testResumedSessionReplaysTheTranscriptsReasoningDetails() async throws {
    // A transcript written by a session that carried a signed block, read back through the
    // entry type — the round trip a `--resume` takes.
    let stored: [Message] = [
      .user("ping"),
      Message(role: .assistant, content: nil, toolCalls: [toolCall()], reasoningDetails: [signedEntry]),
      .tool("pong", toolCallId: "tu_1"),
    ].map { TranscriptEntry(message: $0).toMessage()! }
    XCTAssertEqual(stored[1].reasoningDetails?.count, 1)
    let loaded = LoadedSession(
      meta: SessionMeta(id: UUID().uuidString, model: "anthropic/claude-test", updatedAt: Date(), messageCount: 3),
      messages: stored, model: "anthropic/claude-test", costUSD: 0, turnCount: 1)

    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let session = Session(
      resuming: loaded, service: mock, tools: [PingTool()], store: tempRecordStore(),
      dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", reasoningEffort: .medium))

    _ = try await Events.drain(await session.send("and now finish"))

    let request = Fixtures.jsonValue(mock.messagesRequests[0])
    XCTAssertEqual(request["thinking"]?["type"]?.stringValue, "enabled")
    let blocks = request["messages"]?.arrayValue?[1]["content"]?.arrayValue ?? []
    XCTAssertEqual(blocks.map { $0["type"]?.stringValue }, ["thinking", "tool_use"])
    XCTAssertEqual(blocks[0]["signature"]?.stringValue, "sig-1")
  }

  // MARK: Session — /responses

  func testResponsesSessionAsksForAndEchoesEncryptedReasoningWithEffort() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "openai/gpt-test"))
    let reasoning = #"{"type":"reasoning","id":"rs_1","summary":[],"encrypted_content":"enc-xyz"}"#
    mock.responsesEventScripts = [
      [
        Fixtures.responsesEvent(#"{"type":"response.created","response":{"id":"r0","model":"openai/gpt-test","output":[]}}"#),
        Fixtures.responsesEvent(#"{"type":"response.output_item.added","output_index":0,"item":\#(reasoning)}"#),
        Fixtures.responsesEvent(#"{"type":"response.output_item.done","output_index":0,"item":\#(reasoning)}"#),
        Fixtures.responsesEvent(#"{"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"call_1","name":"ping","arguments":"{}","id":"item_1"}}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[\#(reasoning)],"usage":{"cost":0.01,"input_tokens":10}}}"#),
      ],
      [
        Fixtures.responsesEvent(#"{"type":"response.output_text.delta","delta":"done"}"#),
        Fixtures.responsesEvent(#"{"type":"response.completed","response":{"id":"r1","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":12}}}"#),
      ],
    ]
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "openai/gpt-test", reasoningEffort: .medium))

    _ = try await Events.drain(await session.send("ping"))

    XCTAssertEqual(mock.responsesRequests.count, 2)
    XCTAssertEqual(mock.responsesRequests[0].include, ["reasoning.encrypted_content"])
    XCTAssertEqual(mock.responsesRequests[1].include, ["reasoning.encrypted_content"])
    let items = Fixtures.jsonValue(mock.responsesRequests[1].input).arrayValue ?? []
    XCTAssertEqual(items.map { $0["type"]?.stringValue }, ["message", "reasoning", "function_call", "function_call_output"])
    XCTAssertEqual(items[1]["id"]?.stringValue, "rs_1")
    XCTAssertEqual(items[1]["encrypted_content"]?.stringValue, "enc-xyz")
    let record = await session.lastRecord
    XCTAssertEqual(record?.reasoningBlocks, 1)
    XCTAssertEqual(record?.reasoningReplayed, 1, "the second request echoed the reasoning item")
    XCTAssertTrue(record?.finished == true)
  }

  // MARK: Session — chat

  private func runChatTurn(traits: ProviderTraits, outputSchema: OutputSchema? = nil) async throws -> (MockOpenRouterService, Session) {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.reasoningManifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","index":0,"text":"ping first","format":"anthropic-claude-v1"}]"#),
        Fixtures.reasoningDetailsChunk(#"[{"type":"reasoning.text","index":0,"text":"","signature":"sig-chat","format":"anthropic-claude-v1"}]"#),
        Fixtures.toolCallChunk(id: "tu_1", name: "ping", arguments: "{}"),
        Fixtures.usageChunk(cost: 0.01),
      ],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    if outputSchema != nil {
      // The structured-output side request is non-streaming: one reply that validates.
      mock.chatResponses = [Fixtures.response(
        #"{"id":"gen-s","model":"test/model","choices":[{"index":0,"message":{"role":"assistant","content":"{\"answer\":\"done\"}"},"finish_reason":"stop"}],"usage":{"prompt_tokens":40,"completion_tokens":8,"cost":0.001}}"#)]
    }
    let session = Session(
      service: mock, tools: [PingTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "test/model", reasoningEffort: .medium, provider: traits, outputSchema: outputSchema))
    _ = try await Events.drain(await session.send("ping"))
    return (mock, session)
  }

  func testStructuredSideRequestFollowsTheChatReplayRule() async throws {
    // The structured-output side request is a chat request whatever dialect the turn spoke, so
    // it sends the history the way `chatStep` does: entries kept on a router that documents
    // replaying them, stripped on any other — never `reasoning_details` to a generic gateway.
    let schema = try OutputSchema(schema: [
      "type": "object", "properties": ["answer": ["type": "string"]],
      "required": ["answer"], "additionalProperties": false,
    ])
    let (openrouter, orSession) = try await runChatTurn(traits: .openrouter, outputSchema: schema)
    XCTAssertEqual(openrouter.requests.count, 3, "two loop steps and the side request")
    let orSide = Fixtures.jsonValue(openrouter.requests[2])["messages"]?.arrayValue ?? []
    XCTAssertEqual(orSide.last?["content"]?.stringValue?.hasPrefix("Now answer the task above"), true, "the side request")
    XCTAssertEqual(orSide[2]["role"]?.stringValue, "assistant")
    XCTAssertEqual(orSide[2]["reasoning_details"]?.arrayValue?.count, 1, "OpenRouter: the entries ride the side request too")
    let orRecord = await orSession.lastRecord
    XCTAssertEqual(orRecord?.structuredOutputValid, true)

    let gateway = ProviderTraits(
      name: "gw", defaultModel: "test/model", fallbackStyle: .litellmFallbacks,
      requestsStreamUsage: true, estimatesCost: true, nativeDialects: true)
    let (litellm, gwSession) = try await runChatTurn(traits: gateway, outputSchema: schema)
    XCTAssertEqual(litellm.requests.count, 3)
    let gwSide = Fixtures.jsonValue(litellm.requests[2])["messages"]?.arrayValue ?? []
    XCTAssertEqual(gwSide[2]["role"]?.stringValue, "assistant")
    XCTAssertNil(gwSide[2]["reasoning_details"], "a generic gateway never sees the field on the side request either")
    XCTAssertEqual(gwSide[2]["tool_calls"]?.arrayValue?.count, 1, "the rest of the message is intact")
    let gwRecord = await gwSession.lastRecord
    XCTAssertEqual(gwRecord?.structuredOutputValid, true, "the side request went through where a 400 would have made the turn an error")
    let history = await gwSession.history
    XCTAssertEqual(history[1].reasoningDetails?.count, 1, "the session's own history keeps the entries")
    XCTAssertEqual(history.count, 4, "nothing of the side request entered history")
  }

  func testChatSessionReplaysReasoningDetailsOnOpenRouterOnly() async throws {
    let (openrouter, orSession) = try await runChatTurn(traits: .openrouter)
    XCTAssertEqual(openrouter.requests.count, 2)
    let replayed = Fixtures.jsonValue(openrouter.requests[1])["messages"]?.arrayValue ?? []
    let assistant = replayed[2]
    XCTAssertEqual(assistant["role"]?.stringValue, "assistant")
    let details = assistant["reasoning_details"]?.arrayValue ?? []
    XCTAssertEqual(details.count, 1, "OpenRouter documents passing the entries back")
    XCTAssertEqual(details[0]["text"]?.stringValue, "ping first")
    XCTAssertEqual(details[0]["signature"]?.stringValue, "sig-chat")
    let orRecord = await orSession.lastRecord
    XCTAssertEqual(orRecord?.reasoningBlocks, 1)
    XCTAssertEqual(orRecord?.reasoningReplayed, 1, "the entries rode the second request")

    let gateway = ProviderTraits(
      name: "gw", defaultModel: "test/model", fallbackStyle: .litellmFallbacks,
      requestsStreamUsage: true, estimatesCost: true, nativeDialects: true)
    XCTAssertFalse(gateway.replaysReasoningDetails, "the default is off; only OpenRouter turns it on")
    let (litellm, gwSession) = try await runChatTurn(traits: gateway)
    let stripped = Fixtures.jsonValue(litellm.requests[1])["messages"]?.arrayValue ?? []
    XCTAssertNil(stripped[2]["reasoning_details"], "a generic gateway never sees the field")
    let history = await gwSession.history
    XCTAssertEqual(history[1].reasoningDetails?.count, 1, "the session's own history keeps the entries")
    let gwRecord = await gwSession.lastRecord
    XCTAssertEqual(gwRecord?.reasoningBlocks, 1, "produced all the same")
    XCTAssertNil(gwRecord?.reasoningReplayed, "but stripped before the wire — nothing was replayed")
  }

  // MARK: Model swap

  func testSetModelStripsReasoningDetailsOnlyWhenTheSlugChanges() async throws {
    let (_, session) = try await runChatTurn(traits: .openrouter)
    var history = await session.history
    XCTAssertEqual(history[1].reasoningDetails?.count, 1)

    _ = try await session.setModel("test/model")
    history = await session.history
    XCTAssertEqual(history[1].reasoningDetails?.count, 1, "the same slug is a no-op")

    _ = try await session.setModel("other/model")
    history = await session.history
    XCTAssertNil(history[1].reasoningDetails, "a signed block is bound to the model that produced it")
    XCTAssertEqual(history[1].toolCalls?.count, 1, "the rest of the message is untouched")
  }

  func testSessionStoreLoadAppliesTheSameStripAtAModelChange() throws {
    let root = try tempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SessionStore(directory: root.appendingPathComponent("sessions"))
    let id = UUID().uuidString
    let assistant = Message(role: .assistant, content: nil, toolCalls: [toolCall()], reasoningDetails: [signedEntry])

    try store.append(.meta(id: id, model: "a/one", cwd: nil), to: id)
    try store.append(TranscriptEntry(message: .user("ping")), to: id)
    try store.append(TranscriptEntry(message: assistant), to: id)
    try store.append(TranscriptEntry(message: .tool("pong", toolCallId: "tu_1")), to: id)
    try store.append(.modelChange("a/one"), to: id)
    XCTAssertEqual(try store.load(id: id).messages[1].reasoningDetails?.count, 1, "the same slug strips nothing")

    try store.append(.modelChange("b/two"), to: id)
    let loaded = try store.load(id: id)
    XCTAssertEqual(loaded.model, "b/two")
    XCTAssertNil(loaded.messages[1].reasoningDetails, "the replay strips exactly as setModel did live")
    XCTAssertEqual(loaded.messages[1].toolCalls?.count, 1)
  }

  // MARK: Persistence shapes

  func testTranscriptEntryRoundTripsReasoningDetailsAndOldLinesDecode() throws {
    let entry = TranscriptEntry(message: Message(
      role: .assistant, content: .text("on it"), toolCalls: [toolCall()], reasoningDetails: [signedEntry, redactedEntry]))
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(TranscriptEntry.self, from: data)
    XCTAssertEqual(decoded.reasoningDetails?.count, 2)
    XCTAssertEqual(decoded.toMessage()?.reasoningDetails?[0]["signature"]?.stringValue, "sig-1")

    let old = #"{"type":"message","role":"assistant","text":"hi","toolCalls":[{"id":"tu_1","type":"function","function":{"name":"ping","arguments":"{}"}}]}"#
    let legacy = try JSONDecoder().decode(TranscriptEntry.self, from: Data(old.utf8))
    XCTAssertNil(legacy.reasoningDetails)
    XCTAssertNil(legacy.toMessage()?.reasoningDetails)
    XCTAssertEqual(legacy.toMessage()?.toolCalls?.count, 1)

    let text = TranscriptEntry(message: .assistant("plain"))
    XCTAssertFalse(String(decoding: try JSONEncoder().encode(text), as: UTF8.self).contains("reasoningDetails"),
                   "a message without entries writes no key")
  }

  func testRunRecordOldRowDecodesWithoutReasoningBlocks() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = """
      {"id":"1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0,"finished":true}
      """
    XCTAssertNil(try decoder.decode(RunRecord.self, from: Data(legacy.utf8)).reasoningBlocks)
    XCTAssertNil(try decoder.decode(RunRecord.self, from: Data(legacy.utf8)).reasoningReplayed)

    var record = RunRecord(task: "t", model: "m", dialect: "messages", packFamily: "anthropic")
    record.reasoningBlocks = 3
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    XCTAssertFalse(String(decoding: try encoder.encode(record), as: UTF8.self).contains("reasoningReplayed"),
                   "a turn that replayed nothing writes no key")
    record.reasoningReplayed = 2
    let roundTripped = try decoder.decode(RunRecord.self, from: try encoder.encode(record))
    XCTAssertEqual(roundTripped.reasoningBlocks, 3)
    XCTAssertEqual(roundTripped.reasoningReplayed, 2)
  }

  func testDialectVerdictOldRowDecodesAndAThinkingVerdictNeverPins() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-reasoning-verdicts-\(UUID().uuidString).jsonl")
    let old = #"{"model":"anthropic/x","dialect":"messages","ok":false,"reason":"500","at":"2099-01-01T00:00:00Z"}"#
    try (old + "\n").write(to: url, atomically: true, encoding: .utf8)
    let store = DialectVerdictStore(url: url)
    XCTAssertNil(store.latest(model: "anthropic/x", dialect: .messages)?.category, "a pre-field row reads as an endpoint failure")
    XCTAssertTrue(store.isKnownBad(model: "anthropic/x", dialect: .messages))

    store.record(model: "anthropic/x", dialect: .messages, ok: false,
                 reason: "Expected `thinking` or `redacted_thinking`, but found `tool_use`",
                 category: DialectVerdict.thinkingCategory)
    XCTAssertEqual(store.latest(model: "anthropic/x", dialect: .messages)?.category, "thinking")
    XCTAssertFalse(store.isKnownBad(model: "anthropic/x", dialect: .messages), "recorded, shown, never pinned")
    let reread = DialectVerdictStore(url: url)
    XCTAssertEqual(reread.latest(model: "anthropic/x", dialect: .messages)?.category, "thinking")
    XCTAssertFalse(reread.isKnownBad(model: "anthropic/x", dialect: .messages))

    store.record(model: "anthropic/x", dialect: .messages, ok: true, category: DialectVerdict.thinkingCategory)
    XCTAssertNil(store.latest(model: "anthropic/x", dialect: .messages)?.category, "an ok verdict carries no category")
  }

  func testFailureCategoryClassifiesThinkingShapeRefusals() {
    XCTAssertEqual(DialectVerdict.category(forFailure: "messages.1.content.0: Expected `thinking` or `redacted_thinking`, but found `tool_use`."), "thinking")
    XCTAssertEqual(DialectVerdict.category(forFailure: "Invalid signature in thinking block"), "thinking")
    XCTAssertEqual(DialectVerdict.category(forFailure: "`max_tokens` must be greater than `thinking.budget_tokens`"), "thinking")
    XCTAssertNil(DialectVerdict.category(forFailure: "404 model not found"))
    XCTAssertNil(DialectVerdict.category(forFailure: "The server had an error"))

    // A model id that itself says `thinking`: an endpoint error naming the model is the
    // endpoint's failure and must pin like one — the slug is taken out before matching, with or
    // without its vendor prefix.
    let slug = "anthropic/claude-3.7-sonnet:thinking"
    XCTAssertNil(DialectVerdict.category(forFailure: "No endpoints found for \(slug)", model: slug))
    XCTAssertNil(DialectVerdict.category(forFailure: "404 model claude-3.7-sonnet:thinking not found", model: slug))
    XCTAssertNil(DialectVerdict.category(forFailure: "No endpoints found for Anthropic/Claude-3.7-Sonnet:Thinking", model: slug))
    XCTAssertEqual(
      DialectVerdict.category(forFailure: "\(slug): Expected `thinking` or `redacted_thinking`, but found `tool_use`.", model: slug),
      "thinking", "a real thinking refusal on such a model still classifies")
    XCTAssertEqual(DialectVerdict.category(forFailure: "No endpoints found for \(slug)"), "thinking",
                   "without the model the text alone is all there is (the callers always pass it)")
    XCTAssertEqual(DialectVerdict.category(forFailure: "No endpoints found for \(slug)", model: ""), "thinking",
                   "an empty model strips nothing")
  }

  // MARK: Manifest

  func testModelProfileReadsTheOutputCeilingFromEachManifest() throws {
    let openrouter = try JSONDecoder().decode(
      OpenRouterModel.self,
      from: Data(Fixtures.reasoningManifestModel(id: "anthropic/claude-test", maxCompletionTokens: 64000).utf8))
    XCTAssertEqual(ModelProfile(model: openrouter).maxCompletionTokens, 64000)
    let plain = try JSONDecoder().decode(
      OpenRouterModel.self, from: Data(Fixtures.manifestModel(id: "x/y").utf8))
    XCTAssertNil(ModelProfile(model: plain).maxCompletionTokens, "absent in the manifest stays nil")
    XCTAssertNil(ModelProfile(unknownModelId: "openrouter/auto").maxCompletionTokens)

    struct Page: Decodable { let data: [LiteLLMModelInfo] }
    let page = """
      {"data": [
        {"model_name": "capped", "litellm_params": {"model": "anthropic/claude-x"},
         "model_info": {"max_input_tokens": 200000, "max_tokens": 32000, "mode": "chat"}},
        {"model_name": "uncapped", "litellm_params": {"model": "azure/dep"},
         "model_info": {"max_tokens": 128000, "mode": "chat"}}
      ]}
      """
    let rows = try JSONDecoder().decode(Page.self, from: Data(page.utf8)).data
    XCTAssertEqual(rows[0].profile.maxCompletionTokens, 32000, "max_tokens beside max_input_tokens is the output cap")
    XCTAssertEqual(rows[0].profile.contextLength, 200000)
    XCTAssertNil(rows[1].profile.maxCompletionTokens, "max_tokens alone is the context-length fallback, exactly as before")
    XCTAssertEqual(rows[1].profile.contextLength, 128000)
  }
}
