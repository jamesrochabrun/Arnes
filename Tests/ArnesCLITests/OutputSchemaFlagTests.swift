import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// X2 — `arnes do --output-schema`: parse-time loading (inline JSON, a file, a relative path
/// against `-C`), the usage errors (a non-object schema, `--panel`), and the emitter's lines
/// for the `structured_output` event — with the golden text test left exactly as it was.
final class OutputSchemaFlagTests: XCTestCase {
  private func tempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-schema-flag-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func assertValidationError(_ arguments: [String], contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try Do.parse(arguments), arguments.joined(separator: " "), file: file, line: line) { error in
      let message = Do.message(for: error)
      XCTAssertTrue(message.contains(needle), "\(arguments.joined(separator: " ")): \(message)", file: file, line: line)
    }
  }

  // MARK: Parsing

  func testDoParsesAnInlineSchemaAndAFilePath() throws {
    let inline = try Do.parse(["answer", "--output-schema", #"{"type":"object","properties":{"a":{"type":"string"}}}"#])
    XCTAssertEqual(inline.outputSchema, #"{"type":"object","properties":{"a":{"type":"string"}}}"#)
    let loaded = try XCTUnwrap(try Do.loadOutputSchema(inline.outputSchema))
    XCTAssertEqual(loaded.name, "output")
    XCTAssertEqual(loaded.schema["properties"]?["a"]?["type"], "string")

    let dir = try tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("answer.json")
    try #"{"title":"Answer","type":"object","required":["a"],"properties":{"a":{"type":"integer"}}}"#
      .write(to: file, atomically: true, encoding: .utf8)
    let fromFile = try Do.parse(["answer", "--output-schema", file.path])
    let loadedFile = try XCTUnwrap(try Do.loadOutputSchema(fromFile.outputSchema))
    XCTAssertEqual(loadedFile.name, "Answer")
    XCTAssertEqual(loadedFile.schema["required"], ["a"])

    // A relative path resolves against -C at parse time (the way run() reads it after chdir).
    let relative = try Do.parse(["answer", "-C", dir.path, "--output-schema", "answer.json"])
    XCTAssertEqual(relative.outputSchema, "answer.json")
    XCTAssertEqual(try Do.loadOutputSchema(relative.outputSchema, relativeTo: dir.path), loadedFile)

    XCTAssertNil(try Do.loadOutputSchema(nil), "no flag → no schema")
  }

  func testBadSchemasAreUsageErrorsBeforeAnythingConnects() throws {
    assertValidationError(
      ["answer", "--output-schema", #"{"type":"array","items":{"type":"string"}}"#],
      contains: "--output-schema: the schema must describe a JSON object")
    assertValidationError(
      ["answer", "--output-schema", #"{"type": object"#],
      contains: "--output-schema: the schema is not valid JSON")
    assertValidationError(
      ["answer", "--output-schema", "/nonexistent/arnes-\(UUID().uuidString).json"],
      contains: "--output-schema: cannot read the schema file")
    assertValidationError(
      ["answer", "--panel", "2", "--yes", "--output-schema", #"{"type":"object"}"#],
      contains: "--panel and --output-schema don't combine")
    // With a relative path and no -C, the file is looked up in the process cwd.
    assertValidationError(
      ["answer", "--output-schema", "arnes-no-such-schema-\(UUID().uuidString).json"],
      contains: "cannot read the schema file")
  }

  // MARK: Emitter

  func testTextModePrintsTheStatusLineAndTheObjectOnlyWhenValid() {
    let capture = LineCapture()
    let emitter = HeadlessEmitter(format: .text, stdout: { capture.out($0) }, stderr: { capture.err($0) })
    emitter.emit(.assistantText("The answer is 42."))
    emitter.emit(.structuredOutput(json: ["answer": 42, "unit": "n/a"], valid: true, errors: []))
    emitter.emit(.verifier(passed: true, verdict: "PASS: fine"))
    XCTAssertEqual(capture.stdout, [
      "The answer is 42.",
      "✓ structured output valid",
      #"{"answer":42,"unit":"n/a"}"#,
      "✔ PASS: fine",
    ])

    let failed = LineCapture()
    let failing = HeadlessEmitter(format: .text, stdout: { failed.out($0) }, stderr: { failed.err($0) })
    failing.emit(.structuredOutput(json: nil, valid: false, errors: ["$: missing required property 'answer'", "$.x: y"]))
    XCTAssertEqual(failed.stdout, ["✗ structured output invalid: $: missing required property 'answer'"], "first error only, no object")
    XCTAssertEqual(
      HeadlessEmitter.textLine(for: .structuredOutput(json: nil, valid: false, errors: [])),
      "✗ structured output invalid: no valid reply")
  }

  func testJSONModesCarryTheEventAndTheEnvelopeField() throws {
    let capture = LineCapture()
    let emitter = HeadlessEmitter(format: .streamJson, stdout: { capture.out($0) }, stderr: { capture.err($0) })
    emitter.emitInit(InitInfo(
      sessionId: "S-1", version: "t", model: "m", dialect: "auto", provider: "openrouter", cwd: "/w",
      tools: [], mcpServers: [], skills: [], agents: [], hooks: 0, sandbox: nil, effort: nil))
    emitter.emit(.structuredOutput(json: ["answer": 42], valid: true, errors: []))
    XCTAssertEqual(
      capture.stdout.last,
      #"{"errors":[],"json":{"answer":42},"session_id":"S-1","type":"structured_output","valid":true}"#)

    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.finished = true
    record.stopReason = .completed
    record.structuredOutputValid = true
    let result = RunResult(
      result: AgentResult(text: "prose", record: record, sessionId: "S-1", durationMs: 1, structuredOutput: ["answer": 42]),
      costEstimated: false)
    emitter.finish(result)
    let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(capture.stdout.last!.utf8)) as? [String: Any])
    XCTAssertEqual((envelope["structured_output"] as? [String: Any])?["answer"] as? Int, 42)
    XCTAssertEqual(envelope["result"] as? String, "prose")

    // The verbose mirror of a JSON format prints the status line, never the object twice.
    let verbose = LineCapture()
    let mirrored = HeadlessEmitter(format: .json, verbose: true, stdout: { verbose.out($0) }, stderr: { verbose.err($0) })
    mirrored.emit(.structuredOutput(json: ["answer": 42], valid: true, errors: []))
    XCTAssertEqual(verbose.stdout, [])
    XCTAssertEqual(verbose.stderr, ["✓ structured output valid"])
  }

  func testStructuredOutputFailedExitsThree() {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.finished = true
    record.stopReason = .structuredOutputFailed
    let result = RunResult(result: AgentResult(text: "prose", record: record, sessionId: "S"), costEstimated: false)
    XCTAssertEqual(result.stopReason, .structuredOutputFailed)
    XCTAssertNil(result.structuredOutput)
    XCTAssertEqual(ArnesExit.code(for: result, failOnDenied: false, signal: nil), 3)
  }
}

/// Captures both sinks, in order.
private final class LineCapture: @unchecked Sendable {
  private let lock = NSLock()
  private(set) var stdout: [String] = []
  private(set) var stderr: [String] = []

  func out(_ line: String) { lock.withLock { stdout.append(line) } }
  func err(_ line: String) { lock.withLock { stderr.append(line) } }
}
