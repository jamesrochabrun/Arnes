import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// A service whose non-streaming request parks until the task is cancelled — the window an
/// interrupt can land in while the structured side request is out. Streaming steps and the
/// manifest go to the wrapped mock.
private final class ParkingSideRequestService: OpenRouterService, @unchecked Sendable {
  let inner: MockOpenRouterService
  let parked = Latch()

  init(inner: MockOpenRouterService) {
    self.inner = inner
  }

  func chatCompletionStream(_ request: ChatCompletionRequest) async throws -> AsyncThrowingStream<ChatCompletionChunk, Error> {
    try await inner.chatCompletionStream(request)
  }

  func models(filter: ModelsFilter?) async throws -> [OpenRouterModel] {
    try await inner.models(filter: filter)
  }

  func chatCompletion(_ request: ChatCompletionRequest) async throws -> ChatCompletionResponse {
    await parked.arrive()
    try await Task.sleep(nanoseconds: 60_000_000_000) // throws CancellationError on the interrupt
    throw MockError.scriptExhausted
  }
}

/// X2 — structured output: `JSONSchemaLite`, `OutputSchema.load`, `StructuredCompletion`'s
/// reply parsing and retries, and the Session block that runs the side request after a finished
/// turn (manifest-gated `response_format`, the prompt fallback, cost and tokens booked, history
/// untouched, `structured_output_failed` on a model that never validates).
final class StructuredOutputTests: XCTestCase {
  // MARK: Fixtures

  private static let schema: JSONValue = [
    "type": "object",
    "properties": [
      "answer": ["type": "string"],
      "count": ["type": "integer"],
    ],
    "required": ["answer"],
    "additionalProperties": false,
  ]

  private static func manifestModel(id: String, parameters: [String]) -> String {
    let list = parameters.map { "\"\($0)\"" }.joined(separator: ",")
    return """
      {"id":"\(id)","context_length":8000,"supported_parameters":[\(list)],"pricing":{"prompt":"0.000001","completion":"0.000002"}}
      """
  }

  /// A non-streaming reply with an explicit finish reason.
  private static func reply(_ text: String, finishReason: String = "stop", cost: Double = 0) -> ChatCompletionResponse {
    let encoded = String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    return Fixtures.response("""
      {"id":"gen-s","model":"test/model","choices":[{"index":0,"message":{"role":"assistant","content":\(encoded)},"finish_reason":"\(finishReason)"}],"usage":{"prompt_tokens":40,"completion_tokens":8,"cost":\(cost)}}
      """)
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-structured-\(UUID().uuidString).jsonl"))
  }
  private func structuredEvent(in events: [AgentEvent]) -> (json: JSONValue?, valid: Bool, errors: [String])? {
    for event in events {
      if case .structuredOutput(let json, let valid, let errors) = event { return (json, valid, errors) }
    }
    return nil
  }

  private func profile(structured: Bool) -> ModelProfile {
    ModelProfile(
      id: "test/model", contextLength: 8000, supportsTools: true, supportsReasoning: false,
      supportsStructuredOutputs: structured, promptPricePerToken: nil, completionPricePerToken: nil)
  }

  // MARK: JSONSchemaLite

  func testRequiredPropertyMissingIsReportedAtTheObjectPath() {
    let errors = JSONSchemaLite.validate(["count": 1], against: Self.schema)
    XCTAssertEqual(errors, ["$: missing required property 'answer'"])
    XCTAssertEqual(JSONSchemaLite.validate(["answer": "x"], against: Self.schema), [])
  }

  func testIntegerAcceptsWholeDoublesAndRejectsFractions() {
    XCTAssertEqual(JSONSchemaLite.validate(["answer": "a", "count": .double(1.0)], against: Self.schema), [])
    XCTAssertEqual(JSONSchemaLite.validate(["answer": "a", "count": 3], against: Self.schema), [])
    XCTAssertEqual(
      JSONSchemaLite.validate(["answer": "a", "count": .double(1.5)], against: Self.schema),
      ["$.count: expected integer, got number"])
    XCTAssertEqual(
      JSONSchemaLite.validate(["answer": "a", "count": "3"], against: Self.schema),
      ["$.count: expected integer, got string"])
    // `number` takes both.
    XCTAssertEqual(JSONSchemaLite.validate(.double(1.5), against: ["type": "number"]), [])
    XCTAssertEqual(JSONSchemaLite.validate(2, against: ["type": "number"]), [])
  }

  func testAdditionalPropertiesFalseNamesTheStray() {
    XCTAssertEqual(
      JSONSchemaLite.validate(["answer": "a", "extra": true], against: Self.schema),
      ["$: unexpected property 'extra'"])
    // A schema for the extras validates them instead.
    let open: JSONValue = ["type": "object", "additionalProperties": ["type": "integer"]]
    XCTAssertEqual(JSONSchemaLite.validate(["a": 1], against: open), [])
    XCTAssertEqual(JSONSchemaLite.validate(["a": "x"], against: open), ["$.a: expected integer, got string"])
  }

  func testEnumAndConst() {
    let schema: JSONValue = ["type": "object", "properties": [
      "mode": ["enum": ["fast", "slow"]],
      "version": ["const": 2],
    ]]
    XCTAssertEqual(JSONSchemaLite.validate(["mode": "fast", "version": 2], against: schema), [])
    XCTAssertEqual(
      JSONSchemaLite.validate(["mode": "medium", "version": 3], against: schema),
      [#"$.mode: expected one of "fast", "slow", got "medium""#, "$.version: expected 2, got 3"])
  }

  func testNestedItemsReportTheIndexedPath() {
    let schema: JSONValue = ["type": "object", "properties": [
      "items": ["type": "array", "minItems": 1, "maxItems": 3, "items": [
        "type": "object", "required": ["id"], "properties": ["id": ["type": "integer"]],
      ]],
    ]]
    let value: JSONValue = ["items": [["id": 1], ["id": 2], ["id": "three"]]]
    XCTAssertEqual(JSONSchemaLite.validate(value, against: schema), ["$.items[2].id: expected integer, got string"])
    XCTAssertEqual(JSONSchemaLite.validate(["items": []], against: schema), ["$.items: expected at least 1 items, got 0"])
    XCTAssertEqual(
      JSONSchemaLite.validate(["items": [["id": 1], ["id": 1], ["id": 1], ["id": 1]]], against: schema),
      ["$.items: expected at most 3 items, got 4"])
    XCTAssertEqual(JSONSchemaLite.validate(["items": [[:]]], against: schema), ["$.items[0]: missing required property 'id'"])
  }

  func testRefIntoDefsAndDefinitionsResolvesAndACycleTerminates() {
    let schema: JSONValue = [
      "type": "object",
      "properties": [
        "node": ["$ref": "#/$defs/node"],
        "legacy": ["$ref": "#/definitions/legacy"],
      ],
      "$defs": ["node": ["type": "object", "required": ["name"], "properties": [
        "name": ["type": "string"],
        // Recursive: a tree of nodes.
        "children": ["type": "array", "items": ["$ref": "#/$defs/node"]],
      ]]],
      "definitions": ["legacy": ["type": "boolean"]],
    ]
    let tree: JSONValue = ["node": ["name": "root", "children": [["name": "leaf", "children": []]]], "legacy": true]
    XCTAssertEqual(JSONSchemaLite.validate(tree, against: schema), [])
    let broken: JSONValue = ["node": ["name": "root", "children": [["children": []]]], "legacy": "no"]
    XCTAssertEqual(
      JSONSchemaLite.validate(broken, against: schema),
      ["$.legacy: expected boolean, got string", "$.node.children[0]: missing required property 'name'"])

    // A $ref that only points at another $ref, forever: reported, never looped on.
    let loop: JSONValue = ["$ref": "#/$defs/a", "$defs": ["a": ["$ref": "#/$defs/b"], "b": ["$ref": "#/$defs/a"]]]
    XCTAssertEqual(JSONSchemaLite.validate(1, against: loop), ["$: $ref cycle at #/$defs/a"])
    XCTAssertEqual(
      JSONSchemaLite.validate(1, against: ["$ref": "#/$defs/missing"]), ["$: unresolvable $ref #/$defs/missing"])
  }

  func testASchemaReachingItselfThroughACombinatorIsReportedNotRecursedInto() {
    // `#` resolves to the root, which has no `$ref` of its own — so the chain guard never
    // fires — and the root's `allOf` re-enters the same schema for the same value: a validation
    // error, not a stack overflow.
    let selfAll: JSONValue = ["type": "object", "allOf": [["$ref": "#"]]]
    XCTAssertEqual(JSONSchemaLite.validate([:], against: selfAll), ["$: $ref cycle at #"])
    // Every alternative is tried once at this path; the second is what decides. (The
    // self-reference is entered once — the root again — before it is cut, so the failure
    // message nests one level.)
    let selfAny: JSONValue = ["anyOf": [["$ref": "#"], ["type": "string"]]]
    XCTAssertEqual(JSONSchemaLite.validate("s", against: selfAny), [])
    XCTAssertEqual(
      JSONSchemaLite.validate(1, against: selfAny),
      ["$: matches none of the 2 anyOf alternatives (first alternative: $: matches none of the 2 anyOf alternatives (first alternative: $: $ref cycle at #))"])
    // Two definitions reaching each other through combinators: terminates one hop later.
    let mutual: JSONValue = [
      "allOf": [["$ref": "#/$defs/a"]],
      "$defs": [
        "a": ["allOf": [["$ref": "#/$defs/b"]]],
        "b": ["allOf": [["$ref": "#/$defs/a"]]],
      ],
    ]
    XCTAssertEqual(JSONSchemaLite.validate(true, against: mutual), ["$: $ref cycle at #/$defs/a"])
    // Two self-references: each enters the root once and finds both parts cut — parts² work,
    // never 2^N.
    let fanOut: JSONValue = ["allOf": [["$ref": "#"], ["$ref": "#"]]]
    XCTAssertEqual(
      JSONSchemaLite.validate(0, against: fanOut), Array(repeating: "$: $ref cycle at #", count: 4))
    // A recursive schema that *descends* into the value is still fine: the path grows.
    let tree: JSONValue = ["type": "object", "properties": ["next": ["anyOf": [["type": "null"], ["$ref": "#"]]]]]
    XCTAssertEqual(JSONSchemaLite.validate(["next": ["next": ["next": .null]]], against: tree), [])
    XCTAssertEqual(
      JSONSchemaLite.validate(["next": ["next": 5]], against: tree),
      ["$.next: matches none of the 2 anyOf alternatives (first alternative: $.next: expected null, got object)"])
  }

  func testUnknownKeywordsAreAnnotationsAndTypeListsMatchAny() {
    let annotated: JSONValue = ["type": "string", "format": "email", "pattern": "^x", "description": "d", "default": 1]
    XCTAssertEqual(JSONSchemaLite.validate("not an email", against: annotated), [], "format/pattern are annotation only")
    let nullable: JSONValue = ["type": ["string", "null"]]
    XCTAssertEqual(JSONSchemaLite.validate(.null, against: nullable), [])
    XCTAssertEqual(JSONSchemaLite.validate("s", against: nullable), [])
    XCTAssertEqual(JSONSchemaLite.validate(1, against: nullable), ["$: expected string or null, got integer"])
  }

  func testAnyOfOneOfAllOfBoundsAndBooleanSchemas() {
    let either: JSONValue = ["anyOf": [["type": "integer", "minimum": 0], ["type": "string", "minLength": 2]]]
    XCTAssertEqual(JSONSchemaLite.validate(3, against: either), [])
    XCTAssertEqual(JSONSchemaLite.validate("ab", against: either), [])
    XCTAssertEqual(
      JSONSchemaLite.validate(-1, against: either),
      ["$: matches none of the 2 anyOf alternatives (first alternative: $: expected a value ≥ 0, got -1)"])
    XCTAssertEqual(JSONSchemaLite.validate(5, against: ["oneOf": [["type": "integer"]]]), [])
    XCTAssertEqual(
      JSONSchemaLite.validate(5, against: ["allOf": [["type": "integer"], ["maximum": 4]]]),
      ["$: expected a value ≤ 4, got 5"])
    XCTAssertEqual(JSONSchemaLite.validate("anything", against: .bool(true)), [])
    XCTAssertEqual(JSONSchemaLite.validate("anything", against: .bool(false)), ["$: schema forbids any value"])
    XCTAssertEqual(JSONSchemaLite.validate("abcd", against: ["maxLength": 3]), ["$: expected at most 3 characters, got 4"])
  }

  // MARK: OutputSchema.load

  func testLoadTakesInlineJSONAFilePathAndARelativePath() throws {
    let inline = try OutputSchema.load(#" {"type":"object","title":"Answer","properties":{"a":{"type":"string"}}} "#)
    XCTAssertEqual(inline.name, "Answer")
    XCTAssertEqual(inline.schema["type"], "object")

    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-schema-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("out.schema.json")
    try Data(#"{"properties":{"ok":{"type":"boolean"}}}"#.utf8).write(to: file)

    let absolute = try OutputSchema.load(file.path)
    XCTAssertEqual(absolute.name, "output", "no title → the default name")
    XCTAssertEqual(absolute.schema["properties"]?["ok"]?["type"], "boolean")
    let relative = try OutputSchema.load("out.schema.json", relativeTo: directory)
    XCTAssertEqual(relative, absolute)

    XCTAssertThrowsError(try OutputSchema.load("nowhere.json", relativeTo: directory)) { error in
      XCTAssertEqual(error as? StructuredOutputError, .unreadableFile("nowhere.json"))
    }
  }

  func testLoadRefusesNonObjectSchemasBadJSONAndOversizedSchemas() throws {
    XCTAssertThrowsError(try OutputSchema.load(#"{"type":"array","items":{"type":"string"}}"#)) { error in
      XCTAssertEqual(error as? StructuredOutputError, .notAnObjectSchema("its type is \"array\""))
    }
    XCTAssertThrowsError(try OutputSchema.load(#"{"title":"x"}"#)) { error in
      XCTAssertEqual(error as? StructuredOutputError, .notAnObjectSchema("it has neither a type nor properties"))
    }
    XCTAssertThrowsError(try OutputSchema.load(#"{"type": object"#)) { error in
      guard case .invalidJSON? = error as? StructuredOutputError else {
        return XCTFail("expected invalidJSON, got \(error)")
      }
    }
    // A type list containing object is an object schema.
    XCTAssertNoThrow(try OutputSchema.load(#"{"type":["object","null"]}"#))

    let padding = String(repeating: "x", count: OutputSchema.maxBytes)
    let big = #"{"type":"object","description":""# + padding + #""}"#
    XCTAssertThrowsError(try OutputSchema.load(big)) { error in
      XCTAssertEqual(error as? StructuredOutputError, .schemaTooLarge(big.utf8.count))
    }
  }

  // MARK: Reply parsing

  func testReplyParsingStripsFencesAndSurroundingProse() {
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "```json\n{\"answer\": \"x\"}\n```"),
      .object(["answer": "x"]))
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "Here is the JSON you asked for:\n{\"answer\": \"x\", \"count\": 2}\nHope this helps!"),
      .object(["answer": "x", "count": 2]))
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "```\n{\"a\":{\"b\":[1,2]}}\n```\ntrailing"),
      .object(["a": ["b": [1, 2]]]))
    XCTAssertEqual(StructuredCompletion.extractObject(from: "   \n"), .unparseable("empty reply"))
    XCTAssertEqual(StructuredCompletion.extractObject(from: "[1, 2]"), .unparseable("no JSON object found in the reply"))
    guard case .unparseable(let why) = StructuredCompletion.extractObject(from: "{\"a\": }") else {
      return XCTFail("expected an unparseable reply")
    }
    XCTAssertTrue(why.hasPrefix("the reply is not valid JSON"), why)
  }

  func testAFenceInsideAStringValueIsNotAWrapper() {
    // The strict-mode reply of any schema with a code/markdown field: the object *contains* a
    // fence. Read whole first, so what follows the fence (here `"note": "ok"\n}`, no `{`) is
    // never what gets parsed. Pretty-printed, as models write it — a real newline after the
    // fenced value is what made the old fence-first order cut the object in half.
    let code = "```swift\nlet x = 1\n```"
    let pretty = "{\n  \"patch\": \"```swift\\nlet x = 1\\n```\",\n  \"note\": \"ok\"\n}"
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: pretty),
      .object(["patch": .string(code), "note": "ok"]))
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "{\"patch\": \"```swift\\nlet x = 1\\n```\"}"),
      .object(["patch": .string(code)]))
    // Two fenced string values, and a fence inside prose around the object.
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "{\"a\": \"```\\nx\\n```\", \"b\": \"```\\ny\\n```\"}"),
      .object(["a": "```\nx\n```", "b": "```\ny\n```"]))
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "Here you go: {\"patch\": \"```\\nlet x = 1\\n```\"} — done."),
      .object(["patch": "```\nlet x = 1\n```"]))
    // A fenced *wrapper* whose body carries prose before the object still reads the object.
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "```json\nSure:\n{\"answer\": \"x\"}\n```"),
      .object(["answer": "x"]))
    // A fenced array is not an object; the outer braces rule then finds none.
    XCTAssertEqual(
      StructuredCompletion.extractObject(from: "```json\n[1, 2]\n```"),
      .unparseable("no JSON object found in the reply"))
  }

  // MARK: StructuredCompletion

  func testRequestSendsResponseFormatOnlyWhenTheManifestAdvertisesIt() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.reply(#"{"answer":"a"}"#), Self.reply(#"{"answer":"b"}"#)]

    let structured = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: [.system("s"), .user("q")], schema: schema, costOf: { _ in nil })
    XCTAssertEqual(structured.value, ["answer": "a"])
    XCTAssertEqual(structured.attempts, 1)
    let first = try XCTUnwrap(mock.requests.first)
    let format = Fixtures.jsonValue(first.responseFormat)
    XCTAssertEqual(format["type"], "json_schema")
    XCTAssertEqual(format["json_schema"]?["name"], "output")
    XCTAssertEqual(format["json_schema"]?["strict"], true)
    XCTAssertEqual(format["json_schema"]?["schema"], Self.schema)
    XCTAssertNil(first.tools, "the side request offers no tools")
    XCTAssertEqual(first.messages.last?.content?.plainText, "q", "no fallback text when response_format is sent")

    let fallback = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: false),
      messages: [.system("s"), .user("q")], schema: schema, costOf: { _ in nil })
    XCTAssertEqual(fallback.value, ["answer": "b"])
    let second = try XCTUnwrap(mock.requests.last)
    XCTAssertNil(second.responseFormat, "never a response_format the manifest didn't advertise")
    let lastText = second.messages.last?.content?.plainText ?? ""
    XCTAssertTrue(lastText.hasPrefix("q\n\nReply with only a JSON object matching this schema:\n"), lastText)
    XCTAssertTrue(lastText.contains(#""required":["answer"]"#), "the schema rides the instruction")
  }

  func testToolsRideTheSideRequestWithToolChoiceNoneOnlyWhenTheHistoryCalledOne() async throws {
    // Anthropic (and OpenRouter routing to it) rejects tool_use/tool_result blocks in a request
    // that defines no tools; `none` keeps the reply an answer. A history that never called a tool
    // sends none at all — the pre-hardening shape.
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.chatResponses = [Self.reply(#"{"answer":"a"}"#), Self.reply(#"{"answer":"b"}"#), Self.reply(#"{"answer":"c"}"#)]
    let tools = [Tool(function: .init(name: "read_file", parameters: ["type": "object"]))]
    let toolHistory: [Message] = [
      .system("s"), .user("q"),
      Message(role: .assistant, content: nil, toolCalls: [ToolCall(id: "c1", function: .init(name: "read_file", arguments: "{}"))]),
      .tool("contents", toolCallId: "c1"),
      .assistant("done"), .user("now json"),
    ]

    _ = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: toolHistory, schema: schema, tools: tools, costOf: { _ in nil })
    let withTools = try XCTUnwrap(mock.requests.last)
    XCTAssertEqual(withTools.tools?.map(\.function.name), ["read_file"])
    XCTAssertEqual(Fixtures.jsonValue(withTools.toolChoice), "none")
    XCTAssertEqual(Fixtures.jsonValue(withTools.responseFormat)["type"], "json_schema", "response_format still rides along")

    _ = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: [.system("s"), .user("q")], schema: schema, tools: tools, costOf: { _ in nil })
    let noCalls = try XCTUnwrap(mock.requests.last)
    XCTAssertNil(noCalls.tools, "a history without tool calls offers no tools")
    XCTAssertNil(noCalls.toolChoice)

    _ = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: toolHistory, schema: schema, tools: [], costOf: { _ in nil })
    let noneOffered = try XCTUnwrap(mock.requests.last)
    XCTAssertNil(noneOffered.tools, "an empty tool list is no tools, never `tools: []`")
    XCTAssertNil(noneOffered.toolChoice)
  }

  func testInvalidReplyIsFedBackAndRetriedThenGivenUp() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Self.reply(#"{"count": 1}"#, cost: 0.01),
      Self.reply(#"{"answer": "fixed", "count": 1}"#, cost: 0.02),
    ]
    let structured = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: [.user("q")], schema: schema, costOf: { $0?.cost })
    XCTAssertEqual(structured.value, ["answer": "fixed", "count": 1])
    XCTAssertEqual(structured.attempts, 2)
    XCTAssertEqual(structured.costUSD, 0.03, accuracy: 0.0001, "summed over every attempt")
    XCTAssertEqual(structured.promptTokens, 80)
    XCTAssertEqual(structured.completionTokens, 16)
    XCTAssertEqual(mock.requests.count, 2)
    let retry = mock.requests[1].messages
    XCTAssertEqual(retry.count, 3)
    XCTAssertEqual(retry[1].role, .assistant)
    XCTAssertEqual(retry[1].content?.plainText, #"{"count": 1}"#, "the failed reply rides back as the assistant's")
    XCTAssertEqual(
      retry[2].content?.plainText,
      "Invalid JSON for the required schema: $: missing required property 'answer'. Reply with only the corrected JSON object.")

    // Three misses (the first plus two corrections): a result with no value, spend included.
    let stubborn = MockOpenRouterService()
    stubborn.chatResponses = [
      Self.reply("nope", cost: 0.01), Self.reply("", cost: 0.01), Self.reply(#"{"answer": 3}"#, cost: 0.01),
    ]
    let missed = try await StructuredCompletion.request(
      service: stubborn, model: "test/model", profile: profile(structured: true),
      messages: [.user("q")], schema: schema, costOf: { $0?.cost })
    XCTAssertNil(missed.value)
    XCTAssertFalse(missed.isValid)
    XCTAssertEqual(missed.attempts, 3)
    XCTAssertEqual(missed.errors, ["$.answer: expected string, got integer"])
    XCTAssertEqual(missed.raw, #"{"answer": 3}"#)
    XCTAssertEqual(missed.costUSD, 0.03, accuracy: 0.0001)
    XCTAssertEqual(stubborn.requests.count, 3)
    XCTAssertEqual(
      stubborn.requests[2].messages[3].content?.plainText, "(empty reply)",
      "an empty reply is stood in for in the retry conversation")
  }

  func testTruncatedReplyCountsAsAFailedAttempt() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Self.reply(#"{"answer": "a"}"#, finishReason: "length"),
      Self.reply(#"{"answer": "a"}"#),
    ]
    let structured = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: [.user("q")], schema: schema, costOf: { _ in nil })
    XCTAssertEqual(structured.attempts, 2, "a complete-looking object cut by the token limit is still a miss")
    XCTAssertTrue(
      mock.requests[1].messages[2].content?.plainText.contains("reply truncated (finish_reason length)") ?? false)
  }

  func testValidationErrorsAreCappedInTheCorrectionPromptAndTheResult() async throws {
    // Thirty wrong elements: the model is told about the first twenty and how many more, so a
    // large miss is not a page-long paid retry — and the event/result carry the same list.
    let schema = try OutputSchema(schema: [
      "type": "object", "properties": ["list": ["type": "array", "items": ["type": "integer"]]],
    ])
    let wrong = "[" + Array(repeating: "\"x\"", count: 30).joined(separator: ",") + "]"
    let mock = MockOpenRouterService()
    mock.chatResponses = [
      Self.reply(#"{"list": \#(wrong)}"#), Self.reply(#"{"list": \#(wrong)}"#), Self.reply(#"{"list": \#(wrong)}"#),
    ]
    let missed = try await StructuredCompletion.request(
      service: mock, model: "test/model", profile: profile(structured: true),
      messages: [.user("q")], schema: schema, costOf: { _ in nil })
    XCTAssertNil(missed.value)
    XCTAssertEqual(missed.errors.count, StructuredCompletion.maxReportedErrors + 1)
    XCTAssertEqual(missed.errors.first, "$.list[0]: expected integer, got string")
    XCTAssertEqual(missed.errors[StructuredCompletion.maxReportedErrors - 1], "$.list[19]: expected integer, got string")
    XCTAssertEqual(missed.errors.last, "(10 more)")
    let correction = mock.requests[1].messages.last?.content?.plainText ?? ""
    XCTAssertTrue(correction.contains("$.list[19]: expected integer, got string; (10 more)."), correction)
    XCTAssertFalse(correction.contains("$.list[20]"), "the tail is a count, not the rest of the list")
    // Under the cap nothing is added.
    XCTAssertEqual(StructuredCompletion.capped(["a", "b"]), ["a", "b"])
    XCTAssertEqual(
      StructuredCompletion.capped(Array(repeating: "e", count: StructuredCompletion.maxReportedErrors)).count,
      StructuredCompletion.maxReportedErrors)
  }

  func testTransportErrorPropagatesUnretried() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService() // no scripted reply → the mock throws
    do {
      _ = try await StructuredCompletion.request(
        service: mock, model: "test/model", profile: profile(structured: true),
        messages: [.user("q")], schema: schema, costOf: { _ in nil })
      XCTFail("expected the transport error")
    } catch {
      XCTAssertTrue(error is MockError)
    }
    XCTAssertEqual(mock.requests.count, 1)
  }

  // MARK: Session

  private func session(
    mock: MockOpenRouterService, schema: OutputSchema?, maxSteps: Int = 30, tools: [any AgentTool] = [])
    -> Session
  {
    Session(
      service: mock,
      tools: tools,
      store: tempStore(),
      configuration: .init(model: "test/model", maxStepsPerTurn: maxSteps, outputSchema: schema))
  }

  func testValidStructuredOutputLandsOnTheRecordAndEventWithoutTouchingHistory() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let manifest = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))

    // The reference run: no schema.
    let plain = MockOpenRouterService()
    plain.manifestJSON = manifest
    plain.chunkScripts = [[Fixtures.textChunk("The answer is x."), Fixtures.usageChunk(cost: 0.01)]]
    let plainSession = session(mock: plain, schema: nil)
    let plainEvents = try await Events.drain(await plainSession.send("what is the answer?"))
    XCTAssertNil(structuredEvent(in: plainEvents), "no schema → no event")
    XCTAssertEqual(plain.requests.count, 1)
    let plainHistory = await plainSession.history.count

    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest
    mock.chunkScripts = [[Fixtures.textChunk("The answer is x."), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatResponses = [Self.reply(#"{"answer":"x","count":1}"#, cost: 0.005)]
    let structuredSession = session(mock: mock, schema: schema)
    let events = try await Events.drain(await structuredSession.send("what is the answer?"))

    let event = try XCTUnwrap(structuredEvent(in: events))
    XCTAssertTrue(event.valid)
    XCTAssertEqual(event.json, ["answer": "x", "count": 1])
    XCTAssertEqual(event.errors, [])
    let lastRecord = await structuredSession.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.structuredOutputValid, true)
    XCTAssertEqual(record.structuredOutput, ["answer": "x", "count": 1])
    XCTAssertEqual(record.stopReason, .completed)
    XCTAssertTrue(record.finished)
    XCTAssertEqual(record.costUSD, 0.015, accuracy: 0.0001, "the side request's usage.cost lands on the turn")
    XCTAssertEqual(record.promptTokens, 10 + 40)
    XCTAssertEqual(record.completionTokens, 5 + 8)
    let sessionCost = await structuredSession.costUSD
    XCTAssertEqual(sessionCost, 0.015, accuracy: 0.0001)
    XCTAssertEqual(record.summary, "The answer is x.", "the prose is still the turn's result")

    // Exactly one more request than the plain run, and the loop's own request is byte-identical.
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(Fixtures.jsonValue(mock.requests[0]), Fixtures.jsonValue(plain.requests[0]))
    let side = mock.requests[1]
    XCTAssertEqual(Fixtures.jsonValue(side.responseFormat)["type"], "json_schema")
    XCTAssertNil(side.tools)
    XCTAssertNil(side.stream)
    // system + user + assistant + the fixed final prompt.
    XCTAssertEqual(side.messages.count, 4)
    XCTAssertEqual(side.messages[0].role, .system)
    XCTAssertEqual(side.messages[2].content?.plainText, "The answer is x.")
    XCTAssertEqual(side.messages[3].content?.plainText, Session.structuredFinalPrompt)
    // The side request never entered history.
    let history = await structuredSession.history
    XCTAssertEqual(history.count, plainHistory)
    XCTAssertEqual(history.last?.content?.plainText, "The answer is x.")

    // The event comes after the final text and before the footer.
    let kinds = events.map(\.kind)
    let textIndex = try XCTUnwrap(kinds.lastIndex(of: .assistantText))
    let structuredIndex = try XCTUnwrap(kinds.firstIndex(of: .structuredOutput))
    XCTAssertLessThan(textIndex, structuredIndex)
    XCTAssertEqual(kinds.last, .turnFinished)
  }

  func testFallbackInstructionRidesTheLastUserMessageWhenTheManifestLacksResponseFormat() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools"]))
    mock.chunkScripts = [[Fixtures.textChunk("x"), Fixtures.usageChunk(cost: 0)]]
    mock.chatResponses = [Self.reply(#"{"answer":"x"}"#)]
    let events = try await Events.drain(await session(mock: mock, schema: schema).send("q"))
    XCTAssertEqual(structuredEvent(in: events)?.valid, true)
    let side = try XCTUnwrap(mock.requests.last)
    XCTAssertNil(side.responseFormat)
    let last = side.messages.last?.content?.plainText ?? ""
    XCTAssertTrue(last.hasPrefix(Session.structuredFinalPrompt + "\n\nReply with only a JSON object matching this schema:"), last)
  }

  func testInvalidThenValidRetriesOnceInsideTheSameTurn() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("x"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatResponses = [Self.reply("not json", cost: 0.01), Self.reply(#"{"answer":"x"}"#, cost: 0.01)]
    let structuredSession = session(mock: mock, schema: schema)
    let events = try await Events.drain(await structuredSession.send("q"))
    XCTAssertEqual(structuredEvent(in: events)?.valid, true)
    XCTAssertEqual(mock.requests.count, 3, "the loop's step, then two structured attempts")
    let retry = mock.requests[2].messages
    XCTAssertEqual(retry[retry.count - 2].role, .assistant)
    XCTAssertEqual(retry[retry.count - 2].content?.plainText, "not json")
    XCTAssertTrue(retry[retry.count - 1].content?.plainText.hasPrefix("Invalid JSON for the required schema:") ?? false)
    let lastRecord = await structuredSession.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.costUSD, 0.03, accuracy: 0.0001)
    XCTAssertEqual(record.stopReason, .completed)
  }

  func testNeverValidatingEndsAsStructuredOutputFailedWithoutThrowing() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("prose answer"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatResponses = [
      Self.reply(#"{"count":1}"#, cost: 0.01), Self.reply(#"{"count":2}"#, cost: 0.01), Self.reply(#"{"count":3}"#, cost: 0.01),
    ]
    let structuredSession = session(mock: mock, schema: schema)
    let events = try await Events.drain(await structuredSession.send("q"))
    let event = try XCTUnwrap(structuredEvent(in: events))
    XCTAssertFalse(event.valid)
    XCTAssertNil(event.json)
    XCTAssertEqual(event.errors, ["$: missing required property 'answer'"])
    XCTAssertEqual(mock.requests.count, 4, "one step + three attempts (the first and two corrections)")
    let lastRecord = await structuredSession.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.stopReason, .structuredOutputFailed)
    XCTAssertTrue(record.finished, "the prose turn did finish")
    XCTAssertEqual(record.structuredOutputValid, false)
    XCTAssertNil(record.structuredOutput)
    XCTAssertEqual(record.costUSD, 0.04, accuracy: 0.0001, "every attempt is booked")
    XCTAssertEqual(record.summary, "prose answer")
    XCTAssertEqual(events.last?.kind, .turnFinished, "no throw")
  }

  func testTruncatedStructuredReplyIsAFailedAttemptInTheSession() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("x"), Fixtures.usageChunk(cost: 0)]]
    mock.chatResponses = [Self.reply(#"{"answer":"x"}"#, finishReason: "length"), Self.reply(#"{"answer":"x"}"#)]
    let events = try await Events.drain(await session(mock: mock, schema: schema).send("q"))
    XCTAssertEqual(structuredEvent(in: events)?.valid, true)
    XCTAssertEqual(mock.requests.count, 3)
  }

  func testATurnThatDidNotFinishRunsNoStructuredRequest() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    // Step limit: one step, and the model keeps calling a tool.
    let limited = MockOpenRouterService()
    limited.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    limited.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0)]]
    limited.chatResponses = [Self.reply(#"{"answer":"never asked"}"#)]
    let spy = SpyTool(name: "spy", permission: .readOnly)
    let limitedSession = session(mock: limited, schema: schema, maxSteps: 1, tools: [spy])
    let events = try await Events.drain(await limitedSession.send("q"))
    XCTAssertNil(structuredEvent(in: events))
    XCTAssertEqual(limited.requests.count, 1, "no side request after a step limit")
    let limitedRecord = await limitedSession.lastRecord
    let record = try XCTUnwrap(limitedRecord)
    XCTAssertEqual(record.stopReason, .maxSteps)
    XCTAssertNil(record.structuredOutputValid)

    // A request error ends the turn as `error`; nothing to structure.
    let failing = MockOpenRouterService()
    failing.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    failing.chatResponses = [Self.reply(#"{"answer":"never asked"}"#)]
    let failingSession = session(mock: failing, schema: schema)
    do {
      _ = try await Events.drain(await failingSession.send("q"))
      XCTFail("the exhausted script should have thrown")
    } catch {}
    XCTAssertEqual(failing.requests.count, 1)
    let failingReason = await failingSession.lastRecord?.stopReason
    XCTAssertEqual(failingReason, .error)
  }

  func testAnInterruptDuringTheStructuredRequestEndsTheTurnAsInterruptedNotError() async throws {
    // Ctrl-C / a `--timeout` deadline while the side request is out: the same `interrupted`
    // end as during the loop — the run returns, the record says so, nothing is thrown as
    // `error` — and no structured verdict is claimed.
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("prose answer"), Fixtures.usageChunk(cost: 0.01)]]
    let parking = ParkingSideRequestService(inner: mock)
    let store = tempStore()
    let agent = Agent(
      service: parking, tools: [], store: store,
      configuration: .init(model: "test/model", outputSchema: schema))
    let interrupter = Task {
      await parking.parked.wait(for: 1)
      agent.interrupt()
    }
    let result = try await withDeadline(seconds: 10) {
      try await agent.run(task: "q", model: "test/model")
    }
    _ = await interrupter.value
    let run = try XCTUnwrap(result, "the interrupted run must return, not hang")
    XCTAssertEqual(run.stopReason, .interrupted)
    XCTAssertEqual(run.record.stopReason, .interrupted)
    XCTAssertFalse(run.record.finished, "an interrupted turn is not a finished one, whichever request it landed in")
    XCTAssertNil(run.record.structuredOutputValid, "no verdict was reached")
    XCTAssertNil(run.record.structuredOutput)
    XCTAssertNil(run.structuredOutput)
    XCTAssertEqual(run.text, "prose answer", "the prose the model gave stands")
    XCTAssertEqual(try store.all().count, 1)
    XCTAssertEqual(try store.all().first?.stopReason, .interrupted)
    XCTAssertEqual(mock.requests.count, 1, "the loop's one step; the parked side request never reached the mock")
  }

  func testVerifierStillRunsAfterAValidStructuredOutputAndItsCostLands() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("x"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatResponses = [
      Self.reply(#"{"answer":"x"}"#, cost: 0.02),
      Fixtures.textResponse(
        #"{"pass": true, "confidence": "high", "reasons": ["looks right"], "unmet": []}"#, cost: 0.04),
    ]
    let structuredSession = session(mock: mock, schema: schema)
    let events = try await Events.drain(await structuredSession.send("q", verifyWith: "verifier/model"))
    let kinds = events.map(\.kind)
    XCTAssertEqual(structuredEvent(in: events)?.valid, true)
    let structuredIndex = try XCTUnwrap(kinds.firstIndex(of: .structuredOutput))
    let verifierIndex = try XCTUnwrap(kinds.firstIndex(of: .verifier))
    XCTAssertLessThan(structuredIndex, verifierIndex, "structured output first, then the verifier")
    let lastRecord = await structuredSession.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.verifierPassed, true)
    XCTAssertEqual(record.costUSD, 0.07, accuracy: 0.0001)
    XCTAssertEqual(mock.requests.count, 3)
    XCTAssertEqual(mock.requests[2].model, "verifier/model")
  }

  func testOversizedStructuredOutputStaysOffTheRecordButOnTheEvent() async throws {
    let schema = try OutputSchema(schema: ["type": "object", "properties": ["blob": ["type": "string"]]])
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("x"), Fixtures.usageChunk(cost: 0)]]
    let blob = String(repeating: "b", count: RunRecord.maxStructuredOutputBytes)
    mock.chatResponses = [Self.reply(#"{"blob":""# + blob + #""}"#)]
    let structuredSession = session(mock: mock, schema: schema)
    let events = try await Events.drain(await structuredSession.send("q"))
    let event = try XCTUnwrap(structuredEvent(in: events))
    XCTAssertEqual(event.json?["blob"]?.stringValue?.count, blob.count)
    let lastRecord = await structuredSession.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.structuredOutputValid, true)
    XCTAssertNil(record.structuredOutput, "over the cap: valid, but not stored")
  }

  func testSubagentConfigurationDoesNotInheritTheSchema() throws {
    let schema = try OutputSchema(schema: Self.schema)
    let lead = Session.Configuration(model: "m", outputSchema: schema)
    XCTAssertEqual(lead.outputSchema, schema)
    let nested = lead.forSubagent(named: "explore", model: "m", systemSuffix: "role")
    XCTAssertNil(nested.outputSchema, "a subagent's report is prose the lead reads")
  }

  // MARK: Records and results

  func testRunRecordDecodesOldRowsAndRoundTripsTheStructuredFields() throws {
    let old = """
      {"id":"r1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic",
       "steps":1,"toolCalls":0,"routedModels":[],"costUSD":0,"finished":true}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(RunRecord.self, from: Data(old.utf8))
    XCTAssertNil(decoded.structuredOutputValid)
    XCTAssertNil(decoded.structuredOutput)

    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let without = String(decoding: try encoder.encode(record), as: UTF8.self)
    XCTAssertFalse(without.contains("structuredOutput"), "nil fields are absent, so a row without a schema is unchanged")

    record.structuredOutputValid = true
    record.structuredOutput = ["answer": "x", "n": [1, 2.5, true, .null]]
    let back = try decoder.decode(RunRecord.self, from: try encoder.encode(record))
    XCTAssertEqual(back.structuredOutputValid, true)
    XCTAssertEqual(back.structuredOutput, ["answer": "x", "n": [1, 2.5, true, .null]])
  }

  func testRunResultCarriesTheAgentResultsStructuredOutput() throws {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.finished = true
    record.stopReason = .completed
    let agentResult = AgentResult(
      text: "prose", record: record, sessionId: "S", durationMs: 1, structuredOutput: ["answer": "x"])
    let result = RunResult(result: agentResult, costEstimated: false)
    XCTAssertEqual(result.structuredOutput, ["answer": "x"])
    XCTAssertEqual(result.result, "prose")
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(HeadlessJSON.line(result).utf8)) as? [String: Any])
    XCTAssertEqual((object["structured_output"] as? [String: Any])?["answer"] as? String, "x")

    let failure = RunResult.failure(
      stopReason: .error, error: "x", sessionId: nil, model: "m", provider: nil, record: record,
      costEstimated: false, durationMs: 1)
    XCTAssertNil(failure.structuredOutput)
  }

  func testAgentRunSurfacesTheStructuredOutputOnItsResult() async throws {
    let schema = try OutputSchema(schema: Self.schema)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Self.manifestModel(id: "test/model", parameters: ["tools", "response_format"]))
    mock.chunkScripts = [[Fixtures.textChunk("prose"), Fixtures.usageChunk(cost: 0)]]
    mock.chatResponses = [Self.reply(#"{"answer":"from the event"}"#)]
    let agent = Agent(
      service: mock, tools: [], store: tempStore(),
      configuration: Session.Configuration(model: "test/model", outputSchema: schema))
    let result = try await agent.run(task: "q", model: "test/model")
    XCTAssertEqual(result.text, "prose")
    XCTAssertEqual(result.structuredOutput, ["answer": "from the event"])
    XCTAssertEqual(result.stopReason, .completed)
    XCTAssertEqual(RunResult(result: result, costEstimated: false).structuredOutput, ["answer": "from the event"])
  }
}
