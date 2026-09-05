import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// C7 — prompt-cache discipline: `cache_control` breakpoints on the stable prefix of an
/// Anthropic-family request (and nowhere else), the cached-token metric on every dialect, and
/// the config/trait/record plumbing around them.
final class CacheBreakpointTests: XCTestCase {
  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-cache-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDialectStore() -> DialectVerdictStore {
    DialectVerdictStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-cache-verdicts-\(UUID().uuidString).jsonl"))
  }
  /// A read-only tool the scripts can call; the answer is fixed.
  private struct EchoTool: AgentTool {
    let name = "echo"
    let description = "Echoes."
    let parameters: JSONValue = ["type": "object", "properties": ["text": ["type": "string"]], "required": ["text"]]
    var permission: ToolPermission { .readOnly }
    func execute(arguments: [String: JSONValue]) async throws -> String {
      "echo: \(arguments["text"]?.stringValue ?? "")"
    }
  }

  /// Every `cache_control` value anywhere in an encoded request, depth-first.
  private func cacheControls(in value: JSONValue) -> [JSONValue] {
    switch value {
    case .object(let object):
      var found: [JSONValue] = []
      for (key, child) in object.sorted(by: { $0.key < $1.key }) {
        if key == "cache_control" {
          found.append(child)
        }
        found.append(contentsOf: cacheControls(in: child))
      }
      return found
    case .array(let items):
      return items.flatMap(cacheControls(in:))
    default:
      return []
    }
  }

  private func cacheControls<T: Encodable>(in request: T) -> [JSONValue] {
    cacheControls(in: Fixtures.jsonValue(request))
  }

  private static let ephemeral: JSONValue = ["type": "ephemeral"]

  /// A chat mock for an Anthropic-family model: one tool step, then a text finish, then a
  /// second turn's text finish.
  private func anthropicChatMock() -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "echo", arguments: #"{"text":"hi"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("again"), Fixtures.usageChunk(cost: 0.01)],
    ]
    return mock
  }

  // MARK: A refused cache_control

  func testARefusedCacheControlIsResentOnceWithoutBreakpointsWhichStayOffForTheSession() async throws {
    // A gateway that rejects the field would otherwise 400 every chat turn (chat has no fallback
    // to fall to): the step is re-sent once without breakpoints, said as a `.retrying`, and the
    // session stops marking — the second turn carries none either. No dialect verdict anywhere.
    let mock = anthropicChatMock()
    mock.chatStreamErrors = [OpenRouterError.api(
      statusCode: 400, message: "messages.0.content.0.cache_control: Extra inputs are not permitted", metadata: nil)]
    let verdicts = tempDialectStore()
    let session = Session(
      service: mock, tools: [EchoTool()], store: tempRecordStore(), dialectStore: verdicts,
      configuration: .init(model: "anthropic/claude-test", dialect: .chat))

    let events = try await Events.drain(await session.send("first"))
    let firstRecord = await session.lastRecord
    _ = try await Events.drain(await session.send("second"))

    XCTAssertEqual(mock.requests.count, 4, "refused + re-sent, the tool step's finish, the second turn")
    XCTAssertFalse(cacheControls(in: mock.requests[0]).isEmpty, "the refused request carried the markers")
    for (index, request) in mock.requests.enumerated().dropFirst() {
      XCTAssertTrue(cacheControls(in: request).isEmpty, "request \(index) carries no cache_control")
    }
    let retries = events.compactMap { event -> (Int, String)? in
      if case .retrying(let attempt, let reason) = event { return (attempt, reason) } else { return nil }
    }
    XCTAssertEqual(retries.count, 1)
    XCTAssertEqual(retries.first?.0, 1)
    XCTAssertEqual(retries.first?.1, PromptCache.refusalRetryReason)
    XCTAssertEqual(firstRecord?.retries, 1, "the re-send is counted like a transport retry")
    XCTAssertEqual(firstRecord?.finished, true)
    XCTAssertEqual(firstRecord?.dialect, "chat")
    XCTAssertTrue(verdicts.all().isEmpty, "a refused cache_control is not a dialect verdict")
    let refused = await session.cacheControlRefused
    XCTAssertTrue(refused)
    let lastText = await session.history.last?.content?.plainText
    XCTAssertEqual(lastText, "again")
  }

  func testARefusedCacheControlOnMessagesIsResentWithoutBreakpointsNeitherAFallbackNorAPin() async throws {
    // On a native dialect the same 400 used to be a `failure` for the fallback block: a chat rerun
    // and a verdict pinning the model to chat for 7 days, against an endpoint that is fine.
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesStreamErrors = [MockError.nativeRefusal("messages.0.content.0.cache_control: Extra inputs are not permitted")]
    mock.messagesEventScripts = [[
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
      Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
    ]]
    mock.chunkScripts = [[Fixtures.textChunk("never — no fallback"), Fixtures.usageChunk(cost: 0.01)]]
    let verdicts = tempDialectStore()
    let session = Session(
      service: mock, tools: [], store: tempRecordStore(), dialectStore: verdicts,
      configuration: .init(model: "anthropic/claude-test", dialect: .auto))

    let events = try await Events.drain(await session.send("hi"))

    XCTAssertEqual(mock.messagesRequests.count, 2, "refused, then re-sent on the same dialect")
    XCTAssertEqual(mock.requests.count, 0, "no chat fallback")
    XCTAssertFalse(cacheControls(in: mock.messagesRequests[0]).isEmpty)
    XCTAssertTrue(cacheControls(in: mock.messagesRequests[1]).isEmpty)
    XCTAssertFalse(events.contains { if case .dialectFellBack = $0 { return true } else { return false } })
    XCTAssertEqual(events.filter { if case .retrying = $0 { return true } else { return false } }.count, 1)
    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.dialect, "messages")
    XCTAssertEqual(record.retries, 1)
    let verdict = verdicts.latest(model: "anthropic/claude-test", dialect: .messages)
    XCTAssertEqual(verdict?.ok, true, "the clean native step after the re-send is the usual free ok verdict")
    XCTAssertFalse(verdicts.isKnownBad(model: "anthropic/claude-test", dialect: .messages))
  }

  // MARK: Chat breakpoints

  func testAnthropicChatRequestMarksTheSystemPartAndTheLastMessageAndTheMarkMoves() async throws {
    let mock = anthropicChatMock()
    let session = Session(
      service: mock, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", dialect: .chat))
    _ = try await Events.drain(await session.send("first"))
    _ = try await Events.drain(await session.send("second"))
    XCTAssertEqual(mock.requests.count, 3)

    for (index, request) in mock.requests.enumerated() {
      let encoded = Fixtures.jsonValue(request)
      let messages = encoded["messages"]?.arrayValue ?? []
      // The system text is one content part carrying the breakpoint — the shape OpenRouter
      // documents; its text is the system prompt, byte for byte.
      let systemParts = messages[0]["content"]?.arrayValue ?? []
      XCTAssertEqual(messages[0]["role"]?.stringValue, "system")
      XCTAssertEqual(systemParts.count, 1, "request \(index)")
      XCTAssertEqual(systemParts.first?["type"]?.stringValue, "text")
      XCTAssertEqual(systemParts.first?["cache_control"], Self.ephemeral, "request \(index)")
      XCTAssertEqual(systemParts.first?["text"]?.stringValue, request.messages[0].content?.plainText)
      // The last message carries the moving breakpoint; no earlier history message does.
      let last = messages.last
      XCTAssertEqual(last?["cache_control"], Self.ephemeral, "request \(index)")
      for message in messages.dropFirst().dropLast() {
        XCTAssertNil(message["cache_control"], "request \(index): only the last message is marked")
      }
      // Exactly two breakpoints per request — the system part and the last message.
      XCTAssertEqual(cacheControls(in: request).count, 2, "request \(index)")
    }
    // Step 2 of turn 1 ends on the tool result: a `.tool` message is a valid breakpoint.
    XCTAssertEqual(mock.requests[1].messages.last?.role, .tool)
    XCTAssertEqual(mock.requests[1].messages.last?.cacheControl, CacheControl(type: "ephemeral"))
    // Turn 2's request marks the new user message and the earlier one no longer carries it.
    XCTAssertEqual(mock.requests[2].messages.last?.role, .user)
    XCTAssertEqual(mock.requests[2].messages.last?.content?.plainText, "second")
    XCTAssertNil(mock.requests[2].messages[1].cacheControl)
    // The session's own history is never marked — the breakpoint is a request-time view.
    let history = await session.history
    XCTAssertTrue(history.allSatisfy { $0.cacheControl == nil })
  }

  func testNonAnthropicRequestsCarryNoCacheControlAnywhere() async throws {
    for id in ["openai/gpt-test", "deepseek/deepseek-chat", "test/model"] {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: id))
      mock.chunkScripts = [
        [Fixtures.toolCallChunk(id: "c1", name: "echo", arguments: #"{"text":"hi"}"#), Fixtures.usageChunk(cost: 0.01)],
        [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
      ]
      let session = Session(
        service: mock, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
        configuration: .init(model: id, dialect: .chat))
      _ = try await Events.drain(await session.send("go"))
      XCTAssertEqual(mock.requests.count, 2, id)
      for request in mock.requests {
        XCTAssertEqual(cacheControls(in: request), [], "\(id): no cache_control anywhere")
        // The pre-C7 shape: the system message is a plain string.
        let system = Fixtures.jsonValue(request)["messages"]?.arrayValue?.first
        XCTAssertNotNil(system?["content"]?.stringValue, "\(id): the system message is a plain string")
      }
    }
  }

  func testAProviderWithoutCacheControlSupportMarksNothingEvenForAnthropic() async throws {
    let generic = ProviderTraits(
      name: "generic", defaultModel: "anthropic/claude-test", fallbackStyle: .unsupported,
      requestsStreamUsage: true, estimatesCost: true, nativeDialects: false)
    XCTAssertFalse(generic.supportsCacheControl, "the memberwise default is off")
    let mock = anthropicChatMock()
    let session = Session(
      service: mock, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", dialect: .chat, provider: generic))
    _ = try await Events.drain(await session.send("first"))
    for request in mock.requests {
      XCTAssertEqual(cacheControls(in: request), [])
    }
  }

  func testOptingOutIsByteIdenticalToTheUnmarkedRequest() async throws {
    let marked = anthropicChatMock()
    let markedSession = Session(
      service: marked, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", dialect: .chat))
    _ = try await Events.drain(await markedSession.send("first"))

    let off = anthropicChatMock()
    let offSession = Session(
      service: off, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", dialect: .chat, cachePolicy: .off))
    _ = try await Events.drain(await offSession.send("first"))

    XCTAssertEqual(off.requests.count, 2)
    for request in off.requests {
      XCTAssertEqual(cacheControls(in: request), [])
    }
    // Same requests apart from the two breakpoints: strip them from the marked encoding (the
    // system part folds back into a string) and the bytes match.
    for (markedRequest, offRequest) in zip(marked.requests, off.requests) {
      XCTAssertEqual(unmarked(Fixtures.jsonValue(markedRequest)), Fixtures.jsonValue(offRequest))
    }
  }

  /// The encoded request with its breakpoints removed and a single-part system message folded
  /// back into the string form — what the same request looks like without a cache policy.
  private func unmarked(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(var object):
      object["cache_control"] = nil
      if object["role"] == .string("system"),
         let parts = object["content"]?.arrayValue, parts.count == 1,
         let text = parts[0]["text"]?.stringValue
      {
        object["content"] = .string(text)
      }
      return .object(object.mapValues(unmarked))
    case .array(let items):
      return .array(items.map(unmarked))
    default:
      return value
    }
  }

  func testTheTTLRidesTheBreakpoint() async throws {
    let mock = anthropicChatMock()
    let session = Session(
      service: mock, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", dialect: .chat, cachePolicy: CachePolicy(ttl: "1h")))
    _ = try await Events.drain(await session.send("first"))
    let controls = cacheControls(in: mock.requests[0])
    XCTAssertEqual(controls.count, 2)
    for control in controls {
      XCTAssertEqual(control, ["type": "ephemeral", "ttl": "1h"])
    }
  }

  func testChatMessagesWithoutABreakpointAreExactlySystemPlusHistory() throws {
    let history: [Message] = [.user("hi"), .assistant("hello"), .user("more")]
    let plain = PromptCache.chatMessages(system: "SYS", history: history, breakpoint: nil)
    XCTAssertEqual(Fixtures.jsonValue(plain), Fixtures.jsonValue([Message.system("SYS")] + history))
    // Empty history: the system part alone, nothing to mark.
    let empty = PromptCache.chatMessages(system: "SYS", history: [], breakpoint: .ephemeral)
    XCTAssertEqual(empty.count, 1)
    XCTAssertEqual(PromptCache.markingLast([], with: .ephemeral).count, 0)
    // The input array is untouched.
    let marked = PromptCache.markingLast(history, with: .ephemeral)
    XCTAssertEqual(marked.last?.cacheControl, .ephemeral)
    XCTAssertTrue(history.allSatisfy { $0.cacheControl == nil })
  }

  // MARK: /messages breakpoints

  func testMessagesDialectMarksTheLastToolAndTheLastBlockOfTheLastMessage() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [
      [
        Fixtures.messagesEvent(#"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":10}}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"tu_1","name":"echo"}}"#),
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"text\":\"hi\"}"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"cost":0.01}}"#),
      ],
      [
        Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
        Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
      ],
    ]
    let second = EchoTool()
    let session = Session(
      service: mock, tools: [ScriptedTool(name: "spy", results: ["ok"]), second],
      store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test"))
    _ = try await Events.drain(await session.send("go"))
    XCTAssertEqual(mock.messagesRequests.count, 2)

    // Request 1: the last tool definition carries the breakpoint, the first does not; the one
    // user message's text block carries the other. Two breakpoints, nowhere else.
    let first = Fixtures.jsonValue(mock.messagesRequests[0])
    let tools = first["tools"]?.arrayValue ?? []
    XCTAssertEqual(tools.count, 2)
    XCTAssertNil(tools[0]["cache_control"])
    XCTAssertEqual(tools[1]["name"]?.stringValue, "echo")
    XCTAssertEqual(tools[1]["cache_control"], Self.ephemeral)
    let firstMessages = first["messages"]?.arrayValue ?? []
    XCTAssertEqual(firstMessages.count, 1)
    let userBlocks = firstMessages[0]["content"]?.arrayValue ?? []
    XCTAssertEqual(userBlocks.count, 1)
    XCTAssertEqual(userBlocks[0]["type"]?.stringValue, "text")
    XCTAssertEqual(userBlocks[0]["text"]?.stringValue, "go")
    XCTAssertEqual(userBlocks[0]["cache_control"], Self.ephemeral)
    XCTAssertEqual(cacheControls(in: first).count, 2)
    // The system text stays the request's plain `system` string — no block form in the client.
    XCTAssertNotNil(first["system"]?.stringValue)

    // Request 2: the last message is the tool-result turn; its block is re-rendered with the
    // same keys plus the breakpoint, and the earlier user text block no longer carries one.
    let secondRequest = Fixtures.jsonValue(mock.messagesRequests[1])
    let messages = secondRequest["messages"]?.arrayValue ?? []
    XCTAssertEqual(messages.count, 3)
    XCTAssertNil(messages[0]["content"]?.arrayValue?.first?["cache_control"])
    let toolResult = messages[2]["content"]?.arrayValue?.last
    XCTAssertEqual(toolResult?["type"]?.stringValue, "tool_result")
    XCTAssertEqual(toolResult?["tool_use_id"]?.stringValue, "tu_1")
    XCTAssertEqual(toolResult?["content"]?.stringValue, "echo: hi")
    XCTAssertEqual(toolResult?["cache_control"], Self.ephemeral)
    XCTAssertEqual(cacheControls(in: secondRequest).count, 2)
  }

  func testMessagesDialectWithoutThePolicyMarksNothing() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "anthropic/claude-test"))
    mock.messagesEventScripts = [[
      Fixtures.messagesEvent(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"done"}}"#),
      Fixtures.messagesEvent(#"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"cost":0.01}}"#),
    ]]
    let session = Session(
      service: mock, tools: [EchoTool()], store: tempRecordStore(), dialectStore: tempDialectStore(),
      configuration: .init(model: "anthropic/claude-test", cachePolicy: .off))
    _ = try await Events.drain(await session.send("go"))
    XCTAssertEqual(mock.messagesRequests.count, 1)
    XCTAssertEqual(cacheControls(in: mock.messagesRequests[0]), [])
    // The pre-C7 shape: a plain-text user message, not a block.
    let messages = Fixtures.jsonValue(mock.messagesRequests[0])["messages"]?.arrayValue ?? []
    XCTAssertEqual(messages.first?["content"]?.stringValue, "go")
  }

  func testWithBreakpointOnLastHandlesEveryLastBlockKind() throws {
    let control = CacheControl.ephemeral
    // A plain-text message becomes one marked text block.
    let text = MessagesTranslator.withBreakpointOnLast([.user("hi"), .user("there")], control)
    let encodedText = Fixtures.jsonValue(text).arrayValue ?? []
    XCTAssertEqual(encodedText[0]["content"]?.stringValue, "hi", "only the last message changes")
    XCTAssertEqual(encodedText[1]["content"]?.arrayValue?.first?["cache_control"], Self.ephemeral)
    XCTAssertEqual(encodedText[1]["content"]?.arrayValue?.first?["text"]?.stringValue, "there")
    // A tool_use last block cannot take one: left as it is.
    let toolUse = [AnthropicMessage(role: .assistant, content: .blocks([.toolUse(id: "t", name: "n", input: .object([:]))]))]
    XCTAssertEqual(Fixtures.jsonValue(MessagesTranslator.withBreakpointOnLast(toolUse, control)), Fixtures.jsonValue(toolUse))
    // Nor a thinking block, nor an opaque `.other`.
    let thinking = [AnthropicMessage(role: .assistant, content: .blocks([.thinking("t", signature: "s")]))]
    XCTAssertEqual(Fixtures.jsonValue(MessagesTranslator.withBreakpointOnLast(thinking, control)), Fixtures.jsonValue(thinking))
    XCTAssertNil(MessagesTranslator.marking(.other(["type": "x"]), with: control))
    // A tool_result with is_error keeps the flag through the re-rendering.
    let failed = MessagesTranslator.marking(.toolResult(toolUseId: "id", content: "boom", isError: true), with: CacheControl(ttl: "1h"))
    let encodedFailed = Fixtures.jsonValue(try XCTUnwrap(failed))
    XCTAssertEqual(encodedFailed["type"]?.stringValue, "tool_result")
    XCTAssertEqual(encodedFailed["is_error"]?.boolValue, true)
    XCTAssertEqual(encodedFailed["cache_control"], ["type": "ephemeral", "ttl": "1h"])
    // Empty in, empty out; an empty tool list marks nothing.
    XCTAssertTrue(MessagesTranslator.withBreakpointOnLast([], control).isEmpty)
    XCTAssertTrue(MessagesTranslator.tools([], breakpointOnLast: control).isEmpty)
    // Tools without a breakpoint are exactly `map(tool)`.
    let tools: [any AgentTool] = [EchoTool(), ScriptedTool(name: "spy", results: [])]
    XCTAssertEqual(
      Fixtures.jsonValue(MessagesTranslator.tools(tools, breakpointOnLast: nil)),
      Fixtures.jsonValue(tools.map(MessagesTranslator.tool)))
  }

  // MARK: Accumulators

  func testChatAccumulatorReadsCachedTokensFromPromptTokensDetails() {
    var accumulator = StreamAccumulator()
    _ = accumulator.ingest(Fixtures.textChunk("hi"))
    XCTAssertNil(accumulator.cachedPromptTokens)
    _ = accumulator.ingest(Fixtures.cachedUsageChunk(cost: 0.01, promptTokens: 1000, cachedTokens: 700))
    XCTAssertEqual(accumulator.usage?.promptTokens, 1000)
    XCTAssertEqual(accumulator.cachedPromptTokens, 700)
    // The plain usage chunk carries no details: nil, as before.
    var plain = StreamAccumulator()
    _ = plain.ingest(Fixtures.usageChunk(cost: 0.01))
    XCTAssertNil(plain.cachedPromptTokens)
  }

  func testMessagesAccumulatorFoldsCacheFiguresIntoPromptTokens() {
    var accumulator = MessagesAccumulator()
    _ = accumulator.ingest(Fixtures.messagesEvent(
      #"{"type":"message_start","message":{"model":"anthropic/claude-test","usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":100}}}"#))
    // Anthropic's `input_tokens` excludes the cache figures: the whole input is the sum.
    XCTAssertEqual(accumulator.promptTokens, 1010)
    XCTAssertEqual(accumulator.cachedPromptTokens, 900)
    XCTAssertEqual(accumulator.cacheCreationTokens, 100)
    // A message_delta that repeats only the output count clears nothing.
    _ = accumulator.ingest(Fixtures.messagesEvent(
      #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":7,"cost":0.01}}"#))
    XCTAssertEqual(accumulator.promptTokens, 1010)
    XCTAssertEqual(accumulator.cachedPromptTokens, 900)
    XCTAssertEqual(accumulator.completionTokens, 7)
    // One that repeats every figure (cumulative usage) recomputes the same total.
    _ = accumulator.ingest(Fixtures.messagesEvent(
      #"{"type":"message_delta","delta":{},"usage":{"input_tokens":10,"cache_read_input_tokens":900,"cache_creation_input_tokens":100,"output_tokens":9}}"#))
    XCTAssertEqual(accumulator.promptTokens, 1010)
    XCTAssertEqual(accumulator.completionTokens, 9)

    // No cache figure at all: exactly `input_tokens`, the pre-C7 number, and no cached count.
    var plain = MessagesAccumulator()
    _ = plain.ingest(Fixtures.messagesEvent(#"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#))
    XCTAssertEqual(plain.promptTokens, 10)
    XCTAssertNil(plain.cachedPromptTokens)
    XCTAssertNil(plain.cacheCreationTokens)
  }

  func testResponsesAccumulatorReadsCachedTokensFromInputTokensDetails() {
    var accumulator = ResponsesAccumulator()
    _ = accumulator.ingest(Fixtures.responsesEvent(
      #"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":500,"input_tokens_details":{"cached_tokens":300}}}}"#))
    XCTAssertEqual(accumulator.promptTokens, 500)
    XCTAssertEqual(accumulator.cachedPromptTokens, 300)
    var plain = ResponsesAccumulator()
    _ = plain.ingest(Fixtures.responsesEvent(
      #"{"type":"response.completed","response":{"id":"r0","model":"openai/gpt-test","output":[],"usage":{"cost":0.01,"input_tokens":500}}}"#))
    XCTAssertNil(plain.cachedPromptTokens)
  }

  // MARK: The metric on the record and the footer

  func testCachedTokensLandOnTheRecordAndTheTurnStats() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "echo", arguments: #"{"text":"hi"}"#),
       Fixtures.cachedUsageChunk(cost: 0.01, promptTokens: 1000, cachedTokens: 700)],
      [Fixtures.textChunk("done"), Fixtures.cachedUsageChunk(cost: 0.01, promptTokens: 1200, cachedTokens: 1000)],
    ]
    let session = Session(
      service: mock, tools: [EchoTool()], store: tempRecordStore(), configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("go"))
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.promptTokens, 2200)
    XCTAssertEqual(record.cachedTokens, 1700)
    let stats = try XCTUnwrap(events.compactMap { event -> Session.TurnStats? in
      if case .turnFinished(let stats) = event { return stats } else { return nil }
    }.first)
    XCTAssertEqual(stats.cachedPromptTokens, 1700)
    XCTAssertEqual(stats.totalPromptTokens, 2200)
    // The live context footprint is still the last request's, as before.
    XCTAssertEqual(stats.promptTokens, 1200)
  }

  func testATurnThatCachedNothingWritesNoKeyAndReportsNil() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)]]
    let store = tempRecordStore()
    let session = Session(service: mock, tools: [], store: store, configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("go"))
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertNil(record.cachedTokens)
    let stats = try XCTUnwrap(events.compactMap { event -> Session.TurnStats? in
      if case .turnFinished(let stats) = event { return stats } else { return nil }
    }.first)
    XCTAssertNil(stats.cachedPromptTokens)
    XCTAssertEqual(stats.totalPromptTokens, 10)
    let row = try String(contentsOf: store.url, encoding: .utf8)
    XCTAssertFalse(row.contains("cachedTokens"), "a no-cache row is byte-identical")
  }

  func testRunRecordCachedTokensIsOptionalAndOldRowsDecode() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = """
      {"id":"1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0,"finished":true}
      """
    XCTAssertNil(try decoder.decode(RunRecord.self, from: Data(legacy.utf8)).cachedTokens)
    let cached = legacy.dropLast() + #","cachedTokens":700}"#
    XCTAssertEqual(try decoder.decode(RunRecord.self, from: Data(cached.utf8)).cachedTokens, 700)

    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    XCTAssertFalse(String(decoding: try encoder.encode(record), as: UTF8.self).contains("cachedTokens"))
    record.cachedTokens = 42
    XCTAssertTrue(String(decoding: try encoder.encode(record), as: UTF8.self).contains(#""cachedTokens":42"#))
    XCTAssertEqual(try decoder.decode(RunRecord.self, from: try encoder.encode(record)).cachedTokens, 42)
  }

  // MARK: Config, traits, configuration

  func testPromptCacheConfigDecodesUnderPoliciesAndResolvesOverDefaults() throws {
    let decoder = JSONDecoder()
    let absent = try decoder.decode(ArnesConfig.self, from: Data(#"{"policies":{"environmentContext":false}}"#.utf8))
    XCTAssertNil(absent.policies?.promptCache)
    XCTAssertEqual(absent.policies?.promptCache?.policy ?? .default, .default)
    XCTAssertTrue(CachePolicy.default.anthropicBreakpoints)
    XCTAssertNil(CachePolicy.default.ttl)

    let configured = try decoder.decode(ArnesConfig.self, from: Data(
      #"{"policies":{"promptCache":{"anthropicBreakpoints":false,"ttl":"1h"}}}"#.utf8))
    let policy = try XCTUnwrap(configured.policies?.promptCache?.policy)
    XCTAssertFalse(policy.anthropicBreakpoints)
    XCTAssertEqual(policy.ttl, "1h")
    XCTAssertEqual(policy.cacheControl, CacheControl(type: "ephemeral", ttl: "1h"))
    // A block with only a TTL keeps the breakpoints on.
    let ttlOnly = try decoder.decode(ArnesConfig.self, from: Data(#"{"policies":{"promptCache":{"ttl":"5m"}}}"#.utf8))
    XCTAssertEqual(ttlOnly.policies?.promptCache?.policy, CachePolicy(anthropicBreakpoints: true, ttl: "5m"))
    // Every other policies key still decodes beside it.
    let both = try decoder.decode(ArnesConfig.self, from: Data(
      #"{"policies":{"transport":{"maxRequestRetries":1},"promptCache":{"anthropicBreakpoints":true}}}"#.utf8))
    XCTAssertEqual(both.policies?.transport?.maxRequestRetries, 1)
    XCTAssertEqual(both.policies?.promptCache?.anthropicBreakpoints, true)
  }

  func testSupportsCacheControlTraitPerProviderKind() {
    XCTAssertTrue(ProviderTraits.openrouter.supportsCacheControl)
    XCTAssertTrue(ProviderTraits.forKind(.openrouter, name: "or", defaultModel: "m", nativeDialects: true).supportsCacheControl)
    XCTAssertTrue(ProviderTraits.forKind(.litellm, name: "gw", defaultModel: "m", nativeDialects: false).supportsCacheControl)
    XCTAssertFalse(ProviderTraits.forKind(.openaiCompatible, name: "oai", defaultModel: "m", nativeDialects: false).supportsCacheControl)
  }

  func testForSubagentCarriesTheCachePolicy() {
    let lead = Session.Configuration(model: "m", cachePolicy: CachePolicy(anthropicBreakpoints: false, ttl: "1h"))
    let nested = lead.forSubagent(named: "helper", model: "m", systemSuffix: "role")
    XCTAssertEqual(nested.cachePolicy, lead.cachePolicy)
    XCTAssertEqual(Session.Configuration(model: "m").cachePolicy, .default)
  }
}
