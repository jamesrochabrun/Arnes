import Foundation
import OpenRouterSwift

// MARK: - StructuredOutputError

public enum StructuredOutputError: Error, Sendable, Equatable, CustomStringConvertible {
  /// The schema decoded, but isn't an object schema (`"type": "object"`, or `properties` with
  /// no `type`). The structured answer is one JSON object; anything else has no place to land.
  case notAnObjectSchema(String)
  /// The schema text (inline or the file's contents) isn't valid JSON.
  case invalidJSON(String)
  /// The schema is over `OutputSchema.maxBytes` — refused, never silently cut.
  case schemaTooLarge(Int)
  /// The schema path couldn't be read.
  case unreadableFile(String)

  public var description: String {
    switch self {
    case .notAnObjectSchema(let why):
      return "the schema must describe a JSON object (\"type\": \"object\"): \(why)"
    case .invalidJSON(let why):
      return "the schema is not valid JSON: \(why)"
    case .schemaTooLarge(let bytes):
      return "the schema is \(bytes) bytes — over the \(OutputSchema.maxBytes / 1024) KB cap"
    case .unreadableFile(let path):
      return "cannot read the schema file \(path)"
    }
  }
}

// MARK: - OutputSchema

/// The JSON schema a run's final answer must match (`arnes do --output-schema`). Loaded once
/// at parse time so a bad schema is a usage error before anything connects.
public struct OutputSchema: Sendable, Equatable {
  /// The schema as given (unknown keywords kept: they ride `response_format` untouched).
  public let schema: JSONValue
  /// `response_format.json_schema.name` — the schema's `title` when it has one, else `output`.
  public let name: String

  /// The largest schema accepted, inline or from a file. Over it is an error, never a cut: a
  /// schema rides every structured request, and a truncated one validates nothing.
  public static let maxBytes = 64 * 1024

  /// The name a schema without a `title` gets.
  public static let defaultName = "output"

  /// - Throws: `StructuredOutputError.notAnObjectSchema` unless the schema is an object with
  ///   `"type": "object"` (or a type array containing it), or has `properties` and no `type`.
  public init(schema: JSONValue) throws {
    guard let object = schema.objectValue else {
      throw StructuredOutputError.notAnObjectSchema("the schema is not a JSON object")
    }
    switch object["type"] {
    case .string(let type)?:
      guard type == "object" else {
        throw StructuredOutputError.notAnObjectSchema("its type is \"\(type)\"")
      }
    case .array(let types)?:
      guard types.contains(.string("object")) else {
        throw StructuredOutputError.notAnObjectSchema("its type list has no \"object\"")
      }
    case nil:
      guard object["properties"]?.objectValue != nil else {
        throw StructuredOutputError.notAnObjectSchema("it has neither a type nor properties")
      }
    default:
      throw StructuredOutputError.notAnObjectSchema("its type is not a string")
    }
    self.schema = schema
    name = object["title"]?.stringValue.map { $0.trimmingCharacters(in: .whitespaces) }
      .flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultName
  }

  /// A string starting with `{` is the schema itself; anything else is a path (`~` expanded,
  /// a relative one resolved against `relativeTo`, else the process cwd).
  public static func load(_ pathOrInlineJSON: String, relativeTo directory: URL? = nil) throws -> OutputSchema {
    let trimmed = pathOrInlineJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data
    if trimmed.hasPrefix("{") {
      data = Data(trimmed.utf8)
    } else {
      var path = (trimmed as NSString).expandingTildeInPath
      if !path.hasPrefix("/"), let directory {
        path = directory.appendingPathComponent(path).path
      }
      guard let contents = FileManager.default.contents(atPath: path) else {
        throw StructuredOutputError.unreadableFile(trimmed)
      }
      data = contents
    }
    guard data.count <= maxBytes else {
      throw StructuredOutputError.schemaTooLarge(data.count)
    }
    let schema: JSONValue
    do {
      schema = try JSONDecoder().decode(JSONValue.self, from: data)
    } catch {
      throw StructuredOutputError.invalidJSON(Self.decodingSummary(error))
    }
    return try OutputSchema(schema: schema)
  }

  static func decodingSummary(_ error: Error) -> String {
    if let decoding = error as? DecodingError, case .dataCorrupted(let context) = decoding {
      if let underlying = context.underlyingError {
        return (underlying as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
          ?? underlying.localizedDescription
      }
      return context.debugDescription
    }
    return "\(error)"
  }
}

// MARK: - JSONSchemaLite

/// The subset of JSON Schema a structured answer is checked against, in-process and
/// dependency-free: `type` (a name or a list), `required`, `properties`,
/// `additionalProperties` (`false`, or a schema for the extras), `enum`, `const`, `items`,
/// `minItems`/`maxItems`, `minLength`/`maxLength`, `minimum`/`maximum` (+ `exclusive…`),
/// `anyOf`/`oneOf` (first match wins), `allOf`, and `$ref` into `#/$defs` or `#/definitions`
/// (any `#/…` pointer; a `$ref → $ref` chain is hop-bounded, and a schema that reaches itself
/// through a combinator for the same value is reported, not recursed into). Everything else —
/// `format`, `pattern`, `description`, `default`… — is an annotation and ignored, as Claude
/// Code treats it.
///
/// Numbers: `integer` accepts `1` and `1.0`, not `1.5`; `number` accepts both.
public enum JSONSchemaLite {
  /// The `$ref` hops one resolution may take before it is reported instead of followed.
  static let maxRefHops = 32

  /// Every violation, as `<path>: <what>` — `$.items[2].id: expected integer, got string`.
  /// Empty means valid.
  public static func validate(_ value: JSONValue, against schema: JSONValue, path: String = "$") -> [String] {
    var errors: [String] = []
    check(value, schema, root: schema, path: path, active: [], errors: &errors)
    return errors
  }

  /// - Parameter active: the `$ref` pointers being followed for *this* value path, up the
  ///   stack. A recursive schema is fine while it descends into the value (`children: items:
  ///   $ref node` — the path grows, the value is finite); re-entering the same pointer at the
  ///   same path — `allOf: [{"$ref": "#"}]`, `anyOf: [{"$ref": "#"}, …]` — is a schema that
  ///   refers to itself with nothing consumed, reported once rather than recursed into until
  ///   the stack goes.
  private static func check(
    _ value: JSONValue, _ schema: JSONValue, root: JSONValue, path: String, active: Set<String>,
    errors: inout [String])
  {
    // Boolean schemas: `true` accepts anything, `false` nothing.
    if case .bool(let accepts) = schema {
      if !accepts { errors.append("\(path): schema forbids any value") }
      return
    }
    guard var object = schema.objectValue else { return }
    var active = active
    // `$ref` replaces the schema it sits in (sibling keywords are ignored, as in draft 7).
    if let pointer = object["$ref"]?.stringValue {
      let key = "\(pointer)@\(path)"
      if active.contains(key) {
        errors.append("\(path): $ref cycle at \(pointer)")
        return
      }
      active.insert(key)
      switch resolve(object, root: root) {
      case .resolved(let resolved):
        guard let resolvedObject = resolved.objectValue else {
          check(value, resolved, root: root, path: path, active: active, errors: &errors)
          return
        }
        object = resolvedObject
      case .unresolvable(let why):
        errors.append("\(path): \(why)")
        return
      }
    }

    if let type = object["type"] {
      let names: [String]
      switch type {
      case .string(let name): names = [name]
      case .array(let list): names = list.compactMap(\.stringValue)
      default: names = []
      }
      let known = names.filter(typeNames.contains)
      if !known.isEmpty, !known.contains(where: { matches(value, type: $0) }) {
        errors.append("\(path): expected \(known.joined(separator: " or ")), got \(typeName(of: value))")
        return
      }
    }
    if let allowed = object["enum"]?.arrayValue, !allowed.contains(value) {
      errors.append("\(path): expected one of \(allowed.map(render).joined(separator: ", ")), got \(render(value))")
    }
    if let constant = object["const"], constant != value {
      errors.append("\(path): expected \(render(constant)), got \(render(value))")
    }

    switch value {
    case .object(let members):
      let properties = object["properties"]?.objectValue ?? [:]
      if let required = object["required"]?.arrayValue {
        for key in required.compactMap(\.stringValue).sorted() where members[key] == nil {
          errors.append("\(path): missing required property '\(key)'")
        }
      }
      for (key, member) in members.sorted(by: { $0.key < $1.key }) {
        let memberPath = "\(path).\(key)"
        if let propertySchema = properties[key] {
          check(member, propertySchema, root: root, path: memberPath, active: active, errors: &errors)
        } else if let additional = object["additionalProperties"] {
          if additional == .bool(false) {
            errors.append("\(path): unexpected property '\(key)'")
          } else {
            check(member, additional, root: root, path: memberPath, active: active, errors: &errors)
          }
        }
      }
    case .array(let elements):
      if let minItems = object["minItems"]?.intValue, elements.count < minItems {
        errors.append("\(path): expected at least \(minItems) items, got \(elements.count)")
      }
      if let maxItems = object["maxItems"]?.intValue, elements.count > maxItems {
        errors.append("\(path): expected at most \(maxItems) items, got \(elements.count)")
      }
      if let items = object["items"], items.objectValue != nil || items.boolValue != nil {
        for (index, element) in elements.enumerated() {
          check(element, items, root: root, path: "\(path)[\(index)]", active: active, errors: &errors)
        }
      }
    case .string(let text):
      if let minLength = object["minLength"]?.intValue, text.count < minLength {
        errors.append("\(path): expected at least \(minLength) characters, got \(text.count)")
      }
      if let maxLength = object["maxLength"]?.intValue, text.count > maxLength {
        errors.append("\(path): expected at most \(maxLength) characters, got \(text.count)")
      }
    case .int, .double:
      let number = value.doubleValue ?? 0
      if let minimum = object["minimum"]?.doubleValue, number < minimum {
        errors.append("\(path): expected a value ≥ \(render(object["minimum"]!)), got \(render(value))")
      }
      if let maximum = object["maximum"]?.doubleValue, number > maximum {
        errors.append("\(path): expected a value ≤ \(render(object["maximum"]!)), got \(render(value))")
      }
      if let minimum = object["exclusiveMinimum"]?.doubleValue, number <= minimum {
        errors.append("\(path): expected a value > \(render(object["exclusiveMinimum"]!)), got \(render(value))")
      }
      if let maximum = object["exclusiveMaximum"]?.doubleValue, number >= maximum {
        errors.append("\(path): expected a value < \(render(object["exclusiveMaximum"]!)), got \(render(value))")
      }
    default:
      break
    }

    for keyword in ["anyOf", "oneOf"] {
      guard let alternatives = object[keyword]?.arrayValue, !alternatives.isEmpty else { continue }
      var firstFailure: String?
      var matched = false
      for alternative in alternatives {
        var alternativeErrors: [String] = []
        check(value, alternative, root: root, path: path, active: active, errors: &alternativeErrors)
        if alternativeErrors.isEmpty {
          matched = true
          break
        }
        if firstFailure == nil { firstFailure = alternativeErrors.first }
      }
      if !matched {
        let detail = firstFailure.map { " (first alternative: \($0))" } ?? ""
        errors.append("\(path): matches none of the \(alternatives.count) \(keyword) alternatives\(detail)")
      }
    }
    if let all = object["allOf"]?.arrayValue {
      for part in all {
        check(value, part, root: root, path: path, active: active, errors: &errors)
      }
    }
  }

  // MARK: $ref

  /// Follows `$ref` chains (`#/$defs/x`, `#/definitions/x`, any `#/…` pointer, `#` = root)
  /// until a schema without one — at most `maxRefHops` hops, and never twice through the same
  /// pointer, so a self-referencing definition is reported rather than looped on.
  private enum Resolution {
    case resolved(JSONValue)
    case unresolvable(String)
  }

  private static func resolve(_ schema: [String: JSONValue], root: JSONValue) -> Resolution {
    var current = schema
    var seen: Set<String> = []
    var hops = 0
    while let pointer = current["$ref"]?.stringValue {
      hops += 1
      if hops > maxRefHops {
        return .unresolvable("$ref chain deeper than \(maxRefHops)")
      }
      if seen.contains(pointer) {
        return .unresolvable("$ref cycle at \(pointer)")
      }
      seen.insert(pointer)
      guard let target = lookup(pointer, in: root) else {
        return .unresolvable("unresolvable $ref \(pointer)")
      }
      guard let object = target.objectValue else { return .resolved(target) }
      current = object
    }
    return .resolved(.object(current))
  }

  private static func lookup(_ pointer: String, in root: JSONValue) -> JSONValue? {
    guard pointer.hasPrefix("#") else { return nil }
    let body = pointer.dropFirst()
    if body.isEmpty { return root }
    guard body.hasPrefix("/") else { return nil }
    var node = root
    for rawSegment in body.dropFirst().split(separator: "/", omittingEmptySubsequences: false) {
      let segment = rawSegment
        .replacingOccurrences(of: "~1", with: "/")
        .replacingOccurrences(of: "~0", with: "~")
      switch node {
      case .object(let members):
        guard let next = members[segment] else { return nil }
        node = next
      case .array(let elements):
        guard let index = Int(segment), elements.indices.contains(index) else { return nil }
        node = elements[index]
      default:
        return nil
      }
    }
    return node
  }

  // MARK: Types

  static let typeNames: Set<String> = ["string", "number", "integer", "boolean", "object", "array", "null"]

  private static func matches(_ value: JSONValue, type: String) -> Bool {
    switch (type, value) {
    case ("string", .string), ("boolean", .bool), ("object", .object), ("array", .array), ("null", .null):
      return true
    case ("number", .int), ("number", .double), ("integer", .int):
      return true
    case ("integer", .double(let number)):
      return number.isFinite && number == number.rounded()
    default:
      return false
    }
  }

  /// The JSON Schema type name a value reports as (`1.0` is an integer, `1.5` a number).
  static func typeName(of value: JSONValue) -> String {
    switch value {
    case .null: return "null"
    case .bool: return "boolean"
    case .int: return "integer"
    case .double(let number): return number.isFinite && number == number.rounded() ? "integer" : "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    }
  }

  /// A compact rendering for error text: JSON, keys sorted, clipped so a large value can't
  /// turn one error into a page.
  static func render(_ value: JSONValue) -> String {
    let text = HeadlessJSON.line(value)
    return text.count > 80 ? String(text.prefix(77)) + "…" : text
  }
}

// MARK: - StructuredCompletion

/// The one non-streaming side request that turns a finished turn into a validated JSON
/// object (the verifier's shape). Runs over chat completions whatever dialect the turn spoke:
/// `response_format` is a chat-completions field, and `/messages` has no equivalent.
///
/// The manifest decides the wire (invariant 1): `response_format: json_schema` is sent only
/// to a model whose profile advertises structured outputs; for any other model the schema is
/// appended to the last user message as an instruction (the *prompt fallback*). Either way
/// the reply is parsed leniently (fences and surrounding prose stripped), validated with
/// `JSONSchemaLite`, and an invalid reply is fed back once per retry with the errors.
public enum StructuredCompletion {
  /// What the attempts came to. Always returned, valid or not, so the spend of a model that
  /// never validated is booked like any other — only a transport error throws.
  public struct Result: Sendable, Equatable {
    /// The validated object; nil when every attempt came back invalid.
    public let value: JSONValue?
    /// The last attempt's violations (`JSONSchemaLite` paths, or the parse/truncation error);
    /// empty when `value` is set.
    public let errors: [String]
    /// The last reply, as the model sent it.
    public let raw: String
    /// Requests made: 1 when the first reply validated, `maxRetries + 1` after a full miss.
    public let attempts: Int
    /// Summed over every attempt (`costOf` per response).
    public let costUSD: Double
    public let promptTokens: Int?
    public let completionTokens: Int?

    public var isValid: Bool { value != nil }
  }

  /// Corrections after the first attempt. Two: a model that missed twice with the errors in
  /// hand is not going to get it on the fourth try, and every attempt is a paid request.
  public static let defaultMaxRetries = 2

  /// The instruction appended to the last user message when the model's manifest doesn't
  /// advertise `response_format`. Family-neutral and fixed: harness plumbing, not a pack line.
  public static func fallbackInstruction(for schema: OutputSchema) -> String {
    "Reply with only a JSON object matching this schema:\n" + HeadlessJSON.line(schema.schema)
  }

  /// What an invalid attempt is answered with before the retry.
  public static func correctionPrompt(errors: [String]) -> String {
    "Invalid JSON for the required schema: \(errors.joined(separator: "; ")). Reply with only the corrected JSON object."
  }

  /// How many violations one attempt reports — in the correction prompt, the `Result`, the
  /// event. A large array where every element misses would otherwise turn one paid retry into
  /// pages of paths; the first few say what is wrong, the tail says how much of it.
  public static let maxReportedErrors = 20

  /// `errors` cut to `maxReportedErrors`, with `(N more)` for what was dropped.
  static func capped(_ errors: [String]) -> [String] {
    guard errors.count > maxReportedErrors else { return errors }
    return Array(errors.prefix(maxReportedErrors)) + ["(\(errors.count - maxReportedErrors) more)"]
  }

  /// The error a reply cut off by the output-token limit is charged with. Truncation is an
  /// attempt that failed, never silently accepted: half an object is not an object.
  public static let truncatedReplyError = "reply truncated (finish_reason length)"

  /// - Parameters:
  ///   - messages: the conversation to answer — the caller's system prompt, history and its
  ///     final ask. Nothing here is appended to any history; this is a side request.
  ///   - tools: the tool definitions the conversation's tool calls refer to. Sent with
  ///     `tool_choice: none` only when the history carries a tool call — Anthropic (and so
  ///     OpenRouter routing to it) rejects `tool_use`/`tool_result` blocks in a request that
  ///     defines no tools, while `none` keeps the reply an answer rather than another call. A
  ///     history without tool calls sends no tools, exactly as before.
  ///   - costOf: prices one response's usage the way the caller prices its own steps
  ///     (`usage.cost` when reported, else the manifest estimate).
  /// - Returns: the validated object with its spend, or — after `maxRetries` corrections that
  ///   still missed — a result with `value == nil` and the last errors, spend included.
  /// - Throws: only a transport error, untouched and never retried (a router down is not a
  ///   model that missed the schema).
  public static func request(
    service: OpenRouterService,
    model: String,
    profile: ModelProfile,
    messages: [Message],
    schema: OutputSchema,
    tools: [Tool]? = nil,
    maxRetries: Int = defaultMaxRetries,
    costOf: @Sendable (Usage?) async -> Double?)
    async throws -> Result
  {
    let useResponseFormat = profile.supportsStructuredOutputs
    let historyCallsTools = messages.contains { !($0.toolCalls ?? []).isEmpty }
    let requestTools: [Tool]? = historyCallsTools ? tools.flatMap { $0.isEmpty ? nil : $0 } : nil
    var conversation = messages
    if !useResponseFormat {
      conversation = withFallbackInstruction(conversation, schema: schema)
    }
    let responseFormat: ResponseFormat? = useResponseFormat
      ? .jsonSchema(name: schema.name, schema: schema.schema, strict: true)
      : nil

    var attempts = 0
    var costUSD = 0.0
    var promptTokens: Int?
    var completionTokens: Int?
    while true {
      attempts += 1
      let response = try await service.chatCompletion(
        ChatCompletionRequest(
          model: model,
          messages: conversation,
          responseFormat: responseFormat,
          tools: requestTools,
          // `ToolChoice.none` spelled out: a bare `.none` here is `Optional.none`, i.e. no field.
          toolChoice: requestTools == nil ? nil : ToolChoice.none))
      if let cost = await costOf(response.usage) {
        costUSD += cost
      }
      if let tokens = response.usage?.promptTokens {
        promptTokens = (promptTokens ?? 0) + tokens
      }
      if let tokens = response.usage?.completionTokens {
        completionTokens = (completionTokens ?? 0) + tokens
      }
      let choice = response.choices.first
      let raw = choice?.message.content ?? ""
      let errors: [String]
      var value: JSONValue?
      if choice?.finishReason == "length" {
        errors = [truncatedReplyError]
      } else {
        switch extractObject(from: raw) {
        case .object(let parsed):
          value = parsed
          errors = capped(JSONSchemaLite.validate(parsed, against: schema.schema))
        case .unparseable(let why):
          errors = [why]
        }
      }
      if errors.isEmpty, let value {
        return Result(
          value: value, errors: [], raw: raw, attempts: attempts, costUSD: costUSD,
          promptTokens: promptTokens, completionTokens: completionTokens)
      }
      if attempts > maxRetries {
        return Result(
          value: nil, errors: errors, raw: raw, attempts: attempts, costUSD: costUSD,
          promptTokens: promptTokens, completionTokens: completionTokens)
      }
      // The failed reply and what was wrong with it, then another go. An empty reply is
      // stood in for: several providers refuse an assistant message with no content.
      conversation.append(.assistant(raw.isEmpty ? "(empty reply)" : raw))
      conversation.append(.user(correctionPrompt(errors: errors)))
    }
  }

  /// The conversation with the schema instruction on its last user message (a new user
  /// message when the last one isn't a plain-text user turn).
  static func withFallbackInstruction(_ messages: [Message], schema: OutputSchema) -> [Message] {
    var conversation = messages
    let instruction = fallbackInstruction(for: schema)
    if let last = conversation.last, last.role == .user, case .text(let text)? = last.content {
      conversation[conversation.count - 1] = .user(text + "\n\n" + instruction)
    } else {
      conversation.append(.user(instruction))
    }
    return conversation
  }

  // MARK: Reply parsing

  /// The JSON object in a reply, tried in order: (1) the whole trimmed reply decodes as an
  /// object — the strict-mode case, and what a model that did as asked sends; checked first so
  /// a ```` ``` ```` fence *inside* a string value (a `patch` or `code` field) is never mistaken
  /// for a wrapper around the object; (2) a ```-fenced block (```json too) that decodes;
  /// (3) the text from the first `{` to the last `}` — so "Here is the JSON: {…} Hope this
  /// helps" reads as the object. Anything that doesn't decode is an error message for the
  /// retry, never a crash.
  enum Extraction: Equatable {
    case object(JSONValue)
    case unparseable(String)
  }

  static func extractObject(from reply: String) -> Extraction {
    let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
    if text.isEmpty {
      return .unparseable("empty reply")
    }
    if text.hasPrefix("{"), let whole = decodeObject(text) {
      return .object(whole)
    }
    if let fenced = fencedBlock(in: text), let inFence = decodeObject(fenced) {
      return .object(inFence)
    }
    guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}"), open < close else {
      return .unparseable("no JSON object found in the reply")
    }
    let candidate = String(text[open...close])
    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: Data(candidate.utf8))
      return .object(value)
    } catch {
      return .unparseable("the reply is not valid JSON: \(OutputSchema.decodingSummary(error))")
    }
  }

  /// `text` decoded as a JSON *object*; nil for anything else (invalid JSON, an array, a scalar).
  private static func decodeObject(_ text: String) -> JSONValue? {
    guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)),
          value.objectValue != nil
    else { return nil }
    return value
  }

  /// The body of the first ``` fence in `text`, its language tag dropped; nil without one.
  private static func fencedBlock(in text: String) -> String? {
    guard let open = text.range(of: "```") else { return nil }
    let afterOpen = text[open.upperBound...]
    // The language tag, if any, is the rest of the opening line.
    let bodyStart = afterOpen.firstIndex(of: "\n").map(afterOpen.index(after:)) ?? afterOpen.endIndex
    let body = text[bodyStart...]
    let end = body.range(of: "```")?.lowerBound ?? body.endIndex
    let block = body[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
    return block.isEmpty ? nil : block
  }
}
