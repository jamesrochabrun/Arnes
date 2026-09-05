import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The headless run contract's data side: the `RunRecord` fields the envelope reads
/// (`deniedCalls`, token sums), old rows still decoding, and `RunResult` itself — built from
/// an `AgentResult`, round-tripping through JSON with the wire keys a script depends on.
final class RunResultTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-runresult-\(UUID().uuidString).jsonl"))
  }

  private func tempRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-runresult-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
  // MARK: RunRecord fields

  func testDeniedCallsCountsEveryPermissionRefusal() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}", index: 0),
        Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: "{}", index: 1),
        Fixtures.usageChunk(cost: 0),
      ],
      [Fixtures.textChunk("giving up"), Fixtures.usageChunk(cost: 0)],
    ]
    let spy = SpyTool()
    let session = Session(
      service: mock, tools: [spy], permissions: DenyMutationsPermissions(), store: tempStore(),
      configuration: .init(model: "test/model"))
    try await Events.consume(await session.send("go"))

    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.deniedCalls, 2)
    XCTAssertEqual(spy.executions, [], "a denied call never ran")
    XCTAssertEqual(record.stopReason, .completed)
    // The audit rows agree with the counter — the envelope derives `permission_denials` from them.
    XCTAssertEqual(record.decisions?.filter { $0.decision == .deny }.count, 2)
  }

  func testDeniedCallsIsNilWhenNothingWasRefused() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let session = Session(
      service: mock, tools: [SpyTool()], permissions: AutoApprovePermissions(), store: tempStore(),
      configuration: .init(model: "test/model"))
    try await Events.consume(await session.send("go"))
    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertNil(record.deniedCalls, "a turn that refused nothing writes no counter, like hookBlocks")
  }

  func testHookBlockCountsAsADeniedCall() async throws {
    let root = try tempRoot()
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)],
    ]
    let session = Session(
      service: mock, tools: [SpyTool()], permissions: AutoApprovePermissions(), store: tempStore(),
      configuration: .init(
        model: "test/model",
        hooks: [HookDefinition(event: .preToolUse, matcher: "spy", command: "echo 'not today' >&2; exit 2")],
        workingDirectory: root))
    try await Events.consume(await session.send("go"))
    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.hookBlocks, 1)
    XCTAssertEqual(record.deniedCalls, 1, "a hook block is a refusal the envelope must count")
  }

  func testTokenCountsAreSummedAcrossTheTurnsSteps() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // Each usage chunk reports 5 completion tokens; prompt tokens are 10 then 30.
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}"), Fixtures.usageChunk(cost: 0, promptTokens: 10)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0, promptTokens: 30)],
    ]
    let session = Session(
      service: mock, tools: [SpyTool(permission: .readOnly)], store: tempStore(),
      configuration: .init(model: "test/model"))
    try await Events.consume(await session.send("go"))
    let lastRecord = await session.lastRecord
    let record = try XCTUnwrap(lastRecord)
    XCTAssertEqual(record.promptTokens, 40)
    XCTAssertEqual(record.completionTokens, 10)
    // The live context footprint is still the *last* request's, not the sum.
    let last = await session.lastPromptTokens
    XCTAssertEqual(last, 30)
  }

  func testOldRunRecordRowWithoutTheNewFieldsStillDecodes() throws {
    let row = """
      {"id":"r1","startedAt":"2025-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic",\
      "steps":2,"toolCalls":1,"routedModels":["m"],"costUSD":0.01,"finished":true,"stopReason":"completed"}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let record = try decoder.decode(RunRecord.self, from: Data(row.utf8))
    XCTAssertEqual(record.steps, 2)
    XCTAssertNil(record.deniedCalls)
    XCTAssertNil(record.promptTokens)
    XCTAssertNil(record.completionTokens)
    XCTAssertEqual(record.stopReason, .completed)
    // And a fresh record with nothing counted leaves the keys out, so older readers see the same row shape.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let fresh = String(decoding: try encoder.encode(RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "g")), as: UTF8.self)
    XCTAssertFalse(fresh.contains("deniedCalls"))
    XCTAssertFalse(fresh.contains("promptTokens"))
  }

  func testNewFieldsRoundTripThroughTheStore() throws {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "g")
    record.deniedCalls = 3
    record.promptTokens = 120
    record.completionTokens = 40
    let store = tempStore()
    try store.append(record)
    let back = try XCTUnwrap(store.all().first)
    XCTAssertEqual(back.deniedCalls, 3)
    XCTAssertEqual(back.promptTokens, 120)
    XCTAssertEqual(back.completionTokens, 40)
  }

  // MARK: RunResult

  private func sampleRecord() -> RunRecord {
    var record = RunRecord(task: "add a flag", model: "req/model", dialect: "messages", packFamily: "anthropic")
    record.sessionId = "S-1"
    record.steps = 3
    record.toolCalls = 2
    record.routedModels = ["served/model"]
    record.costUSD = 0.0125
    record.finished = true
    record.stopReason = .completed
    record.provider = "openrouter"
    record.verifierPassed = true
    record.deniedCalls = 1
    record.promptTokens = 900
    record.completionTokens = 120
    record.cachedTokens = 300
    record.note(ToolDecision(tool: "bash", tier: .sensitive, decision: .deny, source: .yes, reason: "sensitive"))
    record.note(ToolDecision(tool: "read_file", tier: .readOnly, decision: .allow, source: .rule))
    return record
  }

  func testRunResultIsBuiltFromTheAgentResult() {
    let agentResult = AgentResult(text: "done", record: sampleRecord(), sessionId: "S-1", durationMs: 1234)
    let result = RunResult(result: agentResult, costEstimated: true, verdict: "PASS: looks right")

    XCTAssertEqual(result.type, "result")
    XCTAssertEqual(result.sessionId, "S-1")
    XCTAssertEqual(result.runId, agentResult.record.id)
    XCTAssertEqual(result.stopReason, .completed)
    XCTAssertFalse(result.isError)
    XCTAssertNil(result.error)
    XCTAssertEqual(result.result, "done")
    XCTAssertNil(result.structuredOutput)
    XCTAssertEqual(result.model, "req/model")
    XCTAssertEqual(result.routedModels, ["served/model"])
    XCTAssertEqual(result.dialect, "messages")
    XCTAssertEqual(result.provider, "openrouter")
    XCTAssertEqual(result.steps, 3)
    XCTAssertEqual(result.toolCalls, 2)
    XCTAssertEqual(result.deniedCalls, 1)
    XCTAssertEqual(result.permissionDenials, [PermissionDenialInfo(tool: "bash", reason: "sensitive")])
    XCTAssertEqual(result.costUSD, 0.0125)
    XCTAssertTrue(result.costEstimated)
    XCTAssertEqual(result.promptTokens, 900)
    XCTAssertEqual(result.completionTokens, 120)
    XCTAssertEqual(result.durationMs, 1234)
    XCTAssertEqual(result.verifierPassed, true)
    XCTAssertEqual(result.verdict, "PASS: looks right")
  }

  func testStopReasonOverrideNamesTheCauseTheLoopCouldNotKnow() {
    var record = sampleRecord()
    record.stopReason = .interrupted
    record.finished = false
    let agentResult = AgentResult(text: "", record: record, sessionId: "S-1")
    XCTAssertEqual(agentResult.stopReason, .interrupted)
    let result = RunResult(result: agentResult, costEstimated: false, stopReason: .timeout)
    XCTAssertEqual(result.stopReason, .timeout, "a headless deadline interrupts the session and the envelope says why")
    XCTAssertFalse(result.isError)
  }

  func testErrorStopReasonSetsIsError() {
    var record = sampleRecord()
    record.stopReason = .error
    record.finished = false
    let result = RunResult(result: AgentResult(text: "", record: record, sessionId: "S-1"), costEstimated: false)
    XCTAssertTrue(result.isError)
    XCTAssertEqual(result.stopReason, .error)
  }

  func testFailureEnvelopeCarriesWhatIsKnown() {
    let withRecord = RunResult.failure(
      stopReason: .error, error: "boom", sessionId: "S-2", model: "req/model", provider: "gw",
      record: sampleRecord(), costEstimated: false, durationMs: 10)
    XCTAssertTrue(withRecord.isError)
    XCTAssertEqual(withRecord.error, "boom")
    XCTAssertEqual(withRecord.steps, 3, "the loop appended its record before rethrowing — keep it")
    XCTAssertEqual(withRecord.permissionDenials.count, 1)
    XCTAssertEqual(withRecord.sessionId, "S-2")

    let bare = RunResult.failure(
      stopReason: .timeout, error: nil, sessionId: nil, model: "req/model", provider: "gw",
      record: nil, costEstimated: true, durationMs: 5000)
    XCTAssertFalse(bare.isError)
    XCTAssertEqual(bare.stopReason, .timeout)
    XCTAssertEqual(bare.model, "req/model")
    XCTAssertEqual(bare.provider, "gw")
    XCTAssertNil(bare.runId)
    XCTAssertNil(bare.dialect)
    XCTAssertEqual(bare.steps, 0)
    XCTAssertEqual(bare.sessionId, "")
  }

  func testRunResultRoundTripsThroughJSONWithStableSnakeCaseKeys() throws {
    let agentResult = AgentResult(text: "done", record: sampleRecord(), sessionId: "S-1", durationMs: 42)
    let result = RunResult(result: agentResult, costEstimated: false, verdict: "PASS")
    let line = HeadlessJSON.line(result)
    XCTAssertFalse(line.contains("\n"), "one object per line")

    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    let expectedKeys: Set<String> = [
      "type", "session_id", "run_id", "stop_reason", "is_error", "result", "model", "routed_models",
      "dialect", "provider", "steps", "tool_calls", "denied_calls", "permission_denials", "cost_usd",
      "cost_estimated", "prompt_tokens", "completion_tokens", "duration_ms", "verifier_passed", "verdict",
      "truncated_results", "cached_tokens",
    ]
    XCTAssertEqual(Set(object.keys), expectedKeys, "nil fields (error, structured_output) are omitted; everything else is present")
    XCTAssertEqual(object["type"] as? String, "result")
    XCTAssertEqual(object["cached_tokens"] as? Int, 300, "the record's cached prompt tokens ride the envelope")
    XCTAssertEqual(object["truncated_results"] as? Int, 0, "present even when nothing was cut")
    XCTAssertEqual(object["stop_reason"] as? String, "completed")
    XCTAssertEqual(object["is_error"] as? Bool, false)
    XCTAssertEqual(object["denied_calls"] as? Int, 1)
    XCTAssertEqual((object["permission_denials"] as? [[String: Any]])?.first?["tool"] as? String, "bash")

    let decoded = try JSONDecoder().decode(RunResult.self, from: Data(line.utf8))
    XCTAssertEqual(decoded, result)
  }

  func testStructuredOutputRidesTheEnvelopeWhenPresent() throws {
    var result = RunResult(
      result: AgentResult(text: "", record: sampleRecord(), sessionId: "S-1"), costEstimated: false)
    result.structuredOutput = ["ok": true, "items": [1, 2]]
    let line = HeadlessJSON.line(result)
    XCTAssertTrue(line.contains(#""structured_output":{"items":[1,2],"ok":true}"#))
    let decoded = try JSONDecoder().decode(RunResult.self, from: Data(line.utf8))
    XCTAssertEqual(decoded.structuredOutput, ["ok": true, "items": [1, 2]])
  }

  func testHeadlessJSONSortsKeysAndKeepsSlashes() {
    let line = HeadlessJSON.line(["b": JSONValue.string("/a/b"), "a": .int(1)])
    XCTAssertEqual(line, #"{"a":1,"b":"/a/b"}"#)
  }
}
