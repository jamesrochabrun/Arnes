import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Test doubles

/// A tool whose result is scripted per call — `error:`-prefixed entries are failures.
final class ScriptedTool: AgentTool, @unchecked Sendable {
  let name: String
  let description = "scripted"
  let parameters: JSONValue
  let permission: ToolPermission
  private let lock = NSLock()
  private var results: [String]
  private(set) var calls: [[String: JSONValue]] = []

  init(
    name: String = "scripted",
    results: [String],
    required: [String] = [],
    permission: ToolPermission = .readOnly)
  {
    self.name = name
    self.results = results
    self.permission = permission
    parameters = [
      "type": "object",
      "properties": ["path": ["type": "string"], "text": ["type": "string"]],
      "required": .array(required.map { .string($0) }),
    ]
  }

  var callCount: Int { lock.withLock { calls.count } }

  func execute(arguments: [String: JSONValue]) async throws -> String {
    lock.withLock {
      calls.append(arguments)
      return results.isEmpty ? "ok" : results.removeFirst()
    }
  }
}

/// An in-process hook that records what it was handed and answers with a fixed outcome.
final class RecordingHookHandler: HookHandler, @unchecked Sendable {
  let event: HookEvent
  let matcher: String? = nil
  private let outcome: HookOutcome
  private let lock = NSLock()
  private var recorded: [HookPayload] = []

  init(event: HookEvent, outcome: HookOutcome = HookOutcome()) {
    self.event = event
    self.outcome = outcome
  }

  var payloads: [HookPayload] { lock.withLock { recorded } }

  func handle(_ payload: HookPayload) async -> HookOutcome {
    lock.withLock { recorded.append(payload) }
    return outcome
  }
}

/// A `task`-shaped background source with finished outcomes queued for the next step
/// boundary — enough of A4's seam to see what the session does with a delivered report.
final class QueuedBackgroundSource: BackgroundWorkSource, @unchecked Sendable {
  let name = "task"
  let description = "test background source"
  let parameters: JSONValue = ["type": "object", "properties": [:]]
  let permission = ToolPermission.readOnly
  private let lock = NSLock()
  private var queued: [BackgroundOutcome]

  init(finished: [BackgroundOutcome]) { queued = finished }

  func execute(arguments: [String: JSONValue]) async throws -> String { "started" }
  func pendingBackgroundCount() -> Int { lock.withLock { queued.count } }
  func drainFinishedBackground() -> [BackgroundOutcome] {
    lock.withLock { defer { queued.removeAll() }; return queued }
  }
  func awaitAnyBackground() async -> BackgroundOutcome? {
    lock.withLock { queued.isEmpty ? nil : queued.removeFirst() }
  }
  func cancelBackground() async { lock.withLock { queued.removeAll() } }
  func backgroundSnapshot() -> [BackgroundRun] { [] }
}

// MARK: - ToolLoopHygieneTests

final class ToolLoopHygieneTests: XCTestCase {
  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hygiene-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-hygiene-runs-\(UUID().uuidString).jsonl"))
  }

  /// One step per entry: a tool call, or a final text reply.
  private func mock(steps: [(name: String, arguments: String)], finalText: String = "done") -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    var scripts: [[ChatCompletionChunk]] = []
    for (index, step) in steps.enumerated() {
      scripts.append([
        Fixtures.toolCallChunk(id: "c\(index + 1)", name: step.name, arguments: step.arguments),
        Fixtures.usageChunk(cost: 0.001),
      ])
    }
    scripts.append([Fixtures.textChunk(finalText), Fixtures.usageChunk(cost: 0.001)])
    mock.chunkScripts = scripts
    return mock
  }
  private func toolMessages(in request: ChatCompletionRequest) -> [String] {
    request.messages.filter { $0.role == .tool }.map { $0.content?.plainText ?? "" }
  }

  // MARK: ToolOutputLimiter

  func testLimiterLeavesAResultUnderTheCapAlone() {
    let limiter = ToolOutputLimiter(maxChars: 1_000)
    let capped = limiter.cap("short result", tool: "bash", callId: "c1")
    XCTAssertEqual(capped.text, "short result")
    XCTAssertFalse(capped.truncated)
    XCTAssertEqual(capped.omittedChars, 0)
    XCTAssertNil(capped.spillURL)
  }

  func testLimiterKeepsHeadAndTailAndSpillsTheWhole() throws {
    let spill = try tempDir("spill").appendingPathComponent("session-1")
    let limiter = ToolOutputLimiter(maxChars: 1_000, spillDirectory: spill)
    let text = "HEAD" + String(repeating: "m", count: 5_000) + "\nerror: the last line matters"
    let capped = limiter.cap(text, tool: "bash", callId: "call_1")

    XCTAssertTrue(capped.truncated)
    XCTAssertTrue(capped.text.hasPrefix("HEAD"))
    XCTAssertTrue(capped.text.hasSuffix("error: the last line matters"), "the tail survives")
    XCTAssertEqual(capped.omittedChars, text.count - 1_000)
    XCTAssertLessThanOrEqual(capped.text.count, 1_000 + 120 + spill.path.count + 40, "cap + the pointer line")
    let url = try XCTUnwrap(capped.spillURL)
    XCTAssertEqual(url.lastPathComponent, "bash-call_1.txt")
    XCTAssertTrue(capped.text.contains("the tool's whole result is saved at \(url.path)"), capped.text)
    XCTAssertTrue(capped.text.contains("read_file it with offset/limit"))
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text, "the file holds everything")
    let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    XCTAssertEqual(mode & 0o077, 0, "tool output can hold secrets — owner-only")
    let directoryMode = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: spill.path)[.posixPermissions] as? Int)
    XCTAssertEqual(directoryMode & 0o077, 0, "created lazily, 0700")

    // Deterministic: the same input yields the same text (and rewrites the same file).
    XCTAssertEqual(limiter.cap(text, tool: "bash", callId: "call_1"), capped)
  }

  func testLimiterWithoutASpillDirectoryStillTruncates() {
    let limiter = ToolOutputLimiter(maxChars: 1_000)
    let text = String(repeating: "a", count: 3_000)
    let capped = limiter.cap(text, tool: "grep", callId: "c1")
    XCTAssertTrue(capped.truncated)
    XCTAssertNil(capped.spillURL)
    XCTAssertTrue(capped.text.contains("[… 2000 chars omitted]"), capped.text)
    XCTAssertFalse(capped.text.contains("saved to"))
  }

  func testLimiterFilenamesAreSafeAndTheCapHasAFloor() {
    XCTAssertEqual(ToolOutputLimiter.filename(tool: "mcp__srv/x", callId: "call/../1"), "mcp__srv_x-call____1.txt")
    XCTAssertEqual(ToolOutputLimiter.filename(tool: "", callId: ""), "call-call.txt")
    XCTAssertEqual(ToolOutputLimiter(maxChars: 10).maxChars, ToolOutputLimiter.minimumMaxChars)
    XCTAssertTrue(ToolOutputLimiter.keepsSpillFiles(environment: ["ARNES_KEEP_TMP": "1"]))
    XCTAssertFalse(ToolOutputLimiter.keepsSpillFiles(environment: ["ARNES_KEEP_TMP": "0"]))
    XCTAssertFalse(ToolOutputLimiter.keepsSpillFiles(environment: [:]))
  }

  // MARK: Argument validation

  func testMalformedArgumentsAreAnErrorResultNotARefusalAndTheToolNeverRuns() async throws {
    let tool = ScriptedTool(name: "spy", results: ["ok"], required: ["path"], permission: .mutating)
    let mock = mock(steps: [("spy", "{not json")])
    let permissions = ScriptedPermissions([])
    let session = Session(
      service: mock, tools: [tool], permissions: permissions, store: store(),
      configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("go"))

    XCTAssertEqual(tool.callCount, 0)
    XCTAssertTrue(permissions.asks.isEmpty, "nothing to gate: nobody is asked about a call that won't run")
    XCTAssertFalse(events.contains { if case .toolDenied = $0 { return true } else { return false } })
    let result = toolMessages(in: mock.requests[1]).first ?? ""
    XCTAssertTrue(result.hasPrefix("error: arguments for spy were not a valid JSON object ({not json)."), result)
    XCTAssertTrue(result.contains("Send exactly {\"path\": …} per the tool schema."), result)
    let record = await session.lastRecord
    XCTAssertNil(record?.deniedCalls, "a result, not a denial")
    XCTAssertNil(record?.decisions)
    XCTAssertEqual(record?.toolStats?["spy"], ToolStat(calls: 1, errors: 1))
    XCTAssertEqual(record?.stopReason, .completed)
  }

  func testMissingRequiredKeyIsACoachingError() async throws {
    let tool = ScriptedTool(name: "needy", results: ["ok"], required: ["path", "text"])
    let mock = mock(steps: [("needy", #"{"text": "x", "extra": 1}"#)])
    let session = Session(
      service: mock, tools: [tool], store: store(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("go"))
    XCTAssertEqual(tool.callCount, 0)
    XCTAssertEqual(toolMessages(in: mock.requests[1]).first, "error: needy needs path. Got: extra, text.")
  }

  func testEmptyArgumentsReadAsAnEmptyObject() async throws {
    let tool = ScriptedTool(name: "spy", results: ["ok"])
    let mock = mock(steps: [("spy", "")])
    let session = Session(
      service: mock, tools: [tool], store: store(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("go"))
    XCTAssertEqual(tool.callCount, 1, "what several models send for a tool without arguments")
    XCTAssertEqual(toolMessages(in: mock.requests[1]).first, "ok")
  }

  func testUnknownToolNamesTheAvailableOnes() async throws {
    let mock = mock(steps: [("nope", "{}")])
    let session = Session(
      service: mock, tools: [ScriptedTool(name: "spy", results: []), ScriptedTool(name: "other", results: [])],
      store: store(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("go"))
    XCTAssertEqual(toolMessages(in: mock.requests[1]).first, "error: unknown tool nope. Available: spy, other")
  }

  func testNullForARequiredKeyIsNamedAsSuchUnlessTheSchemaAllowsIt() async throws {
    let strict = ScriptedTool(name: "strict", results: ["ok"], required: ["path"])
    let mock = mock(steps: [("strict", #"{"path": null}"#)])
    let session = Session(
      service: mock, tools: [strict], store: store(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("go"))
    XCTAssertEqual(strict.callCount, 0)
    XCTAssertEqual(toolMessages(in: mock.requests[1]).first, "error: strict needs path (sent as null). Got: path.")

    // An MCP-style schema that types the property `["string", "null"]` may legitimately be null.
    let nullable: JSONValue = [
      "type": "object",
      "properties": ["path": ["type": ["string", "null"]]],
      "required": ["path"],
    ]
    XCTAssertTrue(Session.allowsNull(parameters: nullable, key: "path"))
    XCTAssertFalse(Session.allowsNull(parameters: strict.parameters, key: "path"))
    XCTAssertTrue(Session.allowsNull(
      parameters: ["properties": ["p": ["type": "string", "nullable": true]]], key: "p"), "OpenAPI's spelling")
    XCTAssertFalse(Session.allowsNull(parameters: nullable, key: "other"), "no such property")
  }

  func testValidationErrorsRunThePostToolUseFailureHooksNotTheSuccessOnes() async throws {
    let failure = RecordingHookHandler(event: .postToolUseFailure)
    let success = RecordingHookHandler(event: .postToolUse)
    let tool = ScriptedTool(name: "needy", results: ["ok"], required: ["path"])
    let mock = mock(steps: [("needy", "{}")])
    let session = Session(
      service: mock, tools: [tool], store: store(),
      configuration: .init(model: "test/model", hookHandlers: [failure, success]))
    _ = try await Events.drain(await session.send("go"))

    XCTAssertEqual(tool.callCount, 0)
    XCTAssertEqual(failure.payloads.count, 1, "a validation error is a tool failure, as in Claude Code")
    XCTAssertEqual(failure.payloads.first?.toolName, "needy")
    XCTAssertEqual(failure.payloads.first?.error, "error: needy needs path. Got: no arguments.")
    XCTAssertTrue(success.payloads.isEmpty, "success and failure hooks are mutually exclusive")
  }

  // MARK: The universal cap in the session

  func testOversizedResultIsCappedSpilledAndReadableThroughAnExactCarveOut() async throws {
    let spillRoot = try tempDir("spillroot")
    // Another session's leftovers under the same root — never this session's to read.
    let sibling = spillRoot.appendingPathComponent("OTHER-SESSION").appendingPathComponent("read_file-c9.txt")
    try SecureFiles.writePrivate(Data("someone else's approved read".utf8), to: sibling)
    let scope = SpillScope(root: spillRoot, keepsFiles: false)
    // The toolset and its rules exist before the session does — the CLI's order.
    let workdir = try tempDir("work")
    let harness = [PathScope.physicalPath(spillRoot.path)]
    let rules = PathScope.Rules(harnessPaths: harness, spillScope: scope)
    let reader = ReadFileTool(root: workdir, rules: rules)

    let huge = String(repeating: "x", count: 200_000) + "\nTAIL-MARKER"
    let tool = ScriptedTool(name: "dump", results: [huge])
    let mock = mock(steps: [("dump", "{}")])
    let session = Session(
      service: mock, tools: [tool], store: store(),
      configuration: .init(model: "test/model", toolResultMaxChars: 30_000, spillScope: scope))
    let spillDirectory = spillRoot.appendingPathComponent(session.id)
    let spilled = spillDirectory.appendingPathComponent("dump-c1.txt")

    // Before anything spilled, nothing under the root is open — not even this session's own path.
    XCTAssertNil(scope.directory)
    XCTAssertEqual(PathScope.classify(spilled.path, root: workdir, rules: rules), .outside)
    XCTAssertEqual(reader.permission(for: ["path": .string(sibling.path)]), .sensitive)

    _ = try await Events.drain(await session.send("go"))

    let entry = toolMessages(in: mock.requests[1]).first ?? ""
    XCTAssertLessThanOrEqual(entry.count, 30_000 + 300, "cap + pointer")
    XCTAssertTrue(entry.hasSuffix("TAIL-MARKER"))
    let record = await session.lastRecord
    XCTAssertEqual(record?.truncatedResults, 1)
    XCTAssertTrue(entry.contains("the tool's whole result is saved at \(spilled.path)"), String(entry.suffix(400)))
    XCTAssertEqual(try String(contentsOf: spilled, encoding: .utf8), huge)

    // The spill opened exactly this session's directory: reading it is ordinary work …
    XCTAssertEqual(scope.directory?.path, spillDirectory.path)
    XCTAssertEqual(PathScope.classify(spilled.path, root: workdir, rules: rules), .inside)
    XCTAssertEqual(reader.permission(for: ["path": .string(spilled.path)]), .readOnly)
    let window = try await reader.execute(arguments: ["path": .string(spilled.path), "offset": 2, "limit": 1])
    XCTAssertEqual(window, "2\tTAIL-MARKER")
    // … while a sibling session's directory (a concurrent REPL, a crashed run, a kept spill — or a
    // gated read the user approved once *there*) is still gated like any path under `~/.arnes`.
    XCTAssertEqual(PathScope.classify(sibling.path, root: workdir, rules: rules), .outside)
    XCTAssertEqual(reader.permission(for: ["path": .string(sibling.path)]), .sensitive)
    XCTAssertEqual(
      PathScope.classify(spillRoot.appendingPathComponent("stray.txt").path, root: workdir, rules: rules), .outside,
      "the root itself is not open either")
    // Writing beside the spill is still the floor (the spill root stands in for `~/.arnes/tmp`,
    // so it is also a harness path).
    let writer = WriteFileTool(root: workdir, rules: rules)
    let refusal = try await writer.execute(
      arguments: ["path": .string(spillDirectory.appendingPathComponent("evil.txt").path), "content": "x"])
    XCTAssertTrue(refusal.hasPrefix(ToolDecision.floorRefusalPrefix), refusal)
    XCTAssertFalse(FileManager.default.fileExists(atPath: spillDirectory.appendingPathComponent("evil.txt").path))

    // Without the carve-out the same read is gated like any outside path.
    let plain = ReadFileTool(root: workdir, rules: PathScope.Rules(harnessPaths: harness))
    XCTAssertEqual(plain.permission(for: ["path": .string(spilled.path)]), .sensitive)

    // The carve-out closes and the spill dies with the session (`keepsFiles: false`, whatever
    // the process environment says).
    _ = await session.end(reason: .exit)
    XCTAssertNil(scope.directory)
    XCTAssertFalse(FileManager.default.fileExists(atPath: spillDirectory.path))
    XCTAssertEqual(reader.permission(for: ["path": .string(spilled.path)]), .sensitive)
    XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path), "another session's files are not ours to sweep")
  }

  func testSpillScopeKeepsFilesWhenAskedButStillClosesTheCarveOut() async throws {
    let spillRoot = try tempDir("keep")
    let scope = SpillScope(root: spillRoot, keepsFiles: true)
    let tool = ScriptedTool(name: "dump", results: [String(repeating: "k", count: 5_000)])
    let mock = mock(steps: [("dump", "{}")])
    let session = Session(
      service: mock, tools: [tool], store: store(),
      configuration: .init(model: "test/model", toolResultMaxChars: 1_000, spillScope: scope))
    _ = try await Events.drain(await session.send("go"))
    let spilled = spillRoot.appendingPathComponent(session.id).appendingPathComponent("dump-c1.txt")
    XCTAssertTrue(FileManager.default.fileExists(atPath: spilled.path))
    XCTAssertTrue(scope.contains(resolvedPath: PathScope.physicalPath(spilled.path)))

    _ = await session.end(reason: .exit)
    XCTAssertTrue(FileManager.default.fileExists(atPath: spilled.path), "ARNES_KEEP_TMP: the file is the user's to read")
    XCTAssertNil(scope.directory, "… but no longer the next session's model's")
    XCTAssertFalse(scope.contains(resolvedPath: PathScope.physicalPath(spilled.path)))
  }

  func testSpillScopeOpensOneDirectoryAndOnlyItsOwnerCloses() {
    let root = URL(fileURLWithPath: "/tmp/arnes-scope-unit")
    let scope = SpillScope(root: root, keepsFiles: false)
    let first = root.appendingPathComponent("A")
    let second = root.appendingPathComponent("B")
    XCTAssertFalse(scope.contains(resolvedPath: first.path))
    scope.open(first)
    XCTAssertTrue(scope.contains(resolvedPath: first.path))
    XCTAssertTrue(scope.contains(resolvedPath: first.appendingPathComponent("x.txt").path))
    XCTAssertFalse(scope.contains(resolvedPath: root.appendingPathComponent("AB/x.txt").path), "prefix, not substring")
    XCTAssertFalse(scope.contains(resolvedPath: second.path))
    // `/resume` builds the new session before the old one is ended: the old one leaving must
    // not close what the new one opened.
    scope.open(second)
    scope.close(first)
    XCTAssertEqual(scope.directory, second)
    scope.close(second)
    XCTAssertNil(scope.directory)
    XCTAssertEqual(scope, scope)
    XCTAssertNotEqual(scope, SpillScope(root: root), "identity, not root")
  }

  func testHookFeedbackIsCappedWithTheResult() async throws {
    let chatty = RecordingHookHandler(
      event: .postToolUse, outcome: HookOutcome(feedback: String(repeating: "lint ", count: 10_000)))
    let tool = ScriptedTool(name: "spy", results: ["fine"])
    let mock = mock(steps: [("spy", "{}")])
    let session = Session(
      service: mock, tools: [tool], store: store(),
      configuration: .init(model: "test/model", hookHandlers: [chatty], toolResultMaxChars: 2_000))
    _ = try await Events.drain(await session.send("go"))
    let entry = toolMessages(in: mock.requests[1]).first ?? ""
    XCTAssertTrue(entry.hasPrefix("fine\n\n[hook]\nlint "), String(entry.prefix(40)))
    XCTAssertLessThan(entry.count, 2_300, "the cap is applied after the hook feedback, so a chatty hook is capped too")
    XCTAssertTrue(entry.contains("chars omitted]"), String(entry.suffix(80)))
    let record = await session.lastRecord
    XCTAssertEqual(record?.truncatedResults, 1)
  }

  func testAFailedCallNeverMarksItsFileAsRead() async throws {
    // With any hook configured, `afterToolExecuted` refreshes the file's version after the
    // hooks — but only for a call that ran: a failed one must leave the unread gate in place.
    let workdir = try tempDir("versions")
    let file = workdir.appendingPathComponent("x.txt")
    try "original".write(to: file, atomically: true, encoding: .utf8)
    let versions = FileVersions()
    let tools: [any AgentTool] = [
      EditFileTool(root: workdir, versions: versions),
      WriteFileTool(root: workdir, versions: versions),
    ]
    let mock = mock(steps: [
      ("edit_file", #"{"path":"x.txt"}"#),  // the tool's own coaching error: no old_string/new_string, no edits (T7 made both optional in the schema)
      ("write_file", #"{"path":"x.txt","content":"clobbered"}"#),
    ])
    let session = Session(
      service: mock, tools: tools, store: store(),
      configuration: .init(model: "test/model", hookHandlers: [RecordingHookHandler(event: .postToolUse)]))
    _ = try await Events.drain(await session.send("go"))
    let results = toolMessages(in: mock.requests[2])
    XCTAssertEqual(results.count, 2)
    XCTAssertEqual(results[0], "error: missing 'old_string' and 'new_string' (or an edits array)")
    XCTAssertTrue(results[1].contains("has not been read this session"), results[1])
    XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "original")
  }

  func testCapWithoutASpillRootTruncatesAndCountsIt() async throws {
    let tool = ScriptedTool(name: "dump", results: [String(repeating: "y", count: 50_000)])
    let mock = mock(steps: [("dump", "{}")])
    let session = Session(
      service: mock, tools: [tool], store: store(),
      configuration: .init(model: "test/model", toolResultMaxChars: 10_000))
    _ = try await Events.drain(await session.send("go"))
    let entry = toolMessages(in: mock.requests[1]).first ?? ""
    XCTAssertTrue(entry.contains("[… 40000 chars omitted]"), String(entry.suffix(100)))
    let record = await session.lastRecord
    XCTAssertEqual(record?.truncatedResults, 1)
  }

  // MARK: Bounded ShellRunner

  func testChattyCommandIsBoundedWithTheTailKept() async throws {
    // ~110 KB of numbered lines through a 1000-char tool: head 2000 + tail 2000 bytes kept.
    let tool = BashTool(timeoutSeconds: 30, outputChars: 1_000)
    let result = try await tool.execute(arguments: ["command": "seq 1 20000; echo 'error: THE END' >&2"])
    XCTAssertTrue(result.hasPrefix("exit 0\n1\n2\n3\n"), String(result.prefix(40)))
    XCTAssertTrue(result.contains("bytes omitted …]"), "the gap is named")
    XCTAssertTrue(result.hasSuffix("error: THE END\n"), "a failing build's last lines survive: \(result.suffix(80))")
    XCTAssertLessThan(result.count, 4_500, "head + marker + tail, nothing more")
  }

  func testTwentyMegabytesStayBounded() async {
    let outcome = await ShellRunner.run(
      "yes | head -c 20000000", cwd: nil, timeoutSeconds: 60,
      outputBounds: ShellRunner.OutputBounds(capChars: 5_000))
    XCTAssertGreaterThan(outcome.truncatedBytes, 19_000_000)
    XCTAssertLessThan(outcome.output.utf8.count, 25_000, "never more than head + tail + marker in memory")
    XCTAssertTrue(outcome.output.hasPrefix("y\ny\n"))
    XCTAssertTrue(outcome.output.hasSuffix("y\n"))
  }

  func testSmallOutputIsUntouchedAndUTF8BoundariesAreRespected() async {
    let outcome = await ShellRunner.run("printf 'héllo wörld'", cwd: nil, timeoutSeconds: 5)
    XCTAssertEqual(outcome.output, "héllo wörld")
    XCTAssertEqual(outcome.truncatedBytes, 0)

    // A cut inside a multi-byte character never shows as a replacement character.
    let collector = ShellRunner.OutputCollector(bounds: .init(headBytes: 1024, tailBytes: 1024))
    collector.append(Data(String(repeating: "é", count: 3_000).utf8))
    XCTAssertFalse(collector.text.contains("\u{FFFD}"))
    XCTAssertGreaterThan(collector.truncatedBytes, 0)
  }

  // MARK: read_file hygiene

  func testReadFileClipsLongLines() async throws {
    let dir = try tempDir("lines")
    let file = dir.appendingPathComponent("min.js")
    try ("short\n" + String(repeating: "x", count: 5_000) + "\nend").write(to: file, atomically: true, encoding: .utf8)
    let output = try await ReadFileTool(root: dir).execute(arguments: ["path": "min.js"])
    let lines = output.split(separator: "\n")
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[1].hasSuffix("…[line truncated, 3000 chars]"), String(lines[1].suffix(60)))
    XCTAssertEqual(lines[1].count, "2\t".count + 2_000 + "…[line truncated, 3000 chars]".count)
    XCTAssertEqual(lines[2], "3\tend")
  }

  func testReadFileRefusesBinaryFilesNamingTheMagic() async throws {
    let dir = try tempDir("binary")
    var png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    png.append(Data(repeating: 0, count: 64))
    try png.write(to: dir.appendingPathComponent("pic.png"))
    let tool = ReadFileTool(root: dir)
    let image = try await tool.execute(arguments: ["path": "pic.png"])
    XCTAssertEqual(
      image, "error: \(dir.appendingPathComponent("pic.png").path) is a binary file (72 bytes, looks like PNG)")

    try Data([0x7F, 0x45, 0x4C, 0x46, 0x02, 0x01, 0x01, 0x00, 0x00]).write(to: dir.appendingPathComponent("a.out"))
    let elf = try await tool.execute(arguments: ["path": "a.out"])
    XCTAssertTrue(elf.hasSuffix("looks like ELF)"), elf)
    try Data([0x41, 0x42, 0x00, 0x43]).write(to: dir.appendingPathComponent("blob"))
    let blob = try await tool.execute(arguments: ["path": "blob"])
    XCTAssertTrue(blob.hasSuffix("looks like unknown)"), blob)
    try ("plain text, no NUL here\n").write(to: dir.appendingPathComponent("t.txt"), atomically: true, encoding: .utf8)
    let text = try await tool.execute(arguments: ["path": "t.txt"])
    XCTAssertEqual(text, "1\tplain text, no NUL here\n2\t")
  }

  // MARK: Loop guard (unit)

  func testLoopGuardNudgesOnceThenStopsOnIdenticalFailures() {
    var guardState = LoopGuard(policy: LoopGuardPolicy(maxConsecutiveErrors: 0, maxIdenticalCalls: 6, nudgeAt: 3))
    let args = #"{"path":"a.swift","old":"x","new":"y"}"#
    var verdicts: [LoopGuard.Verdict] = []
    for _ in 1...6 {
      verdicts.append(guardState.observe(tool: "edit_file", argumentsJSON: args, outcome: .error))
    }
    XCTAssertEqual(verdicts[0], .none)
    XCTAssertEqual(verdicts[1], .none)
    guard case .nudge(let reason, let text) = verdicts[2] else { return XCTFail("expected a nudge, got \(verdicts[2])") }
    XCTAssertEqual(reason, "repeated call")
    XCTAssertTrue(text.contains("same edit_file call 3 times"), text)
    XCTAssertEqual(verdicts[3], .none, "the nudge fires once per turn")
    XCTAssertEqual(verdicts[4], .none)
    XCTAssertEqual(verdicts[5], .stuck(reason: "the same edit_file call failed 6 times"))
  }

  func testLoopGuardIdenticalSuccessesNudgeButNeverStop() {
    var guardState = LoopGuard(policy: .default)
    var stuck = false
    var nudges: [String] = []
    for _ in 1...20 {
      switch guardState.observe(tool: "bash", argumentsJSON: #"{"command":"npm test"}"#, outcome: .ok) {
      case .stuck: stuck = true
      case .nudge(_, let text): nudges.append(text)
      case .none: break
      }
    }
    XCTAssertFalse(stuck, "a test rerun is not a loop")
    XCTAssertEqual(nudges.count, 1)
    // A call that keeps succeeding is not told to fix its path or command.
    XCTAssertTrue(nudges[0].hasPrefix("You have made the same bash call 3 times and it succeeded each time."), nudges[0])
    XCTAssertFalse(nudges[0].contains("check the path or command"))
    XCTAssertTrue(
      LoopGuard.repeatNudge(tool: "edit_file", count: 3, everSucceededOnly: false).contains("check the path or command"))
  }

  func testLoopGuardConsecutiveErrorsResetOnSuccessAndStopAtTheThreshold() {
    var guardState = LoopGuard(policy: LoopGuardPolicy(maxConsecutiveErrors: 4, maxIdenticalCalls: 0, nudgeAt: 3))
    func call(_ n: Int, _ outcome: LoopGuard.Outcome) -> LoopGuard.Verdict {
      guardState.observe(tool: "bash", argumentsJSON: "{\"command\":\"cmd \(n)\"}", outcome: outcome)
    }
    XCTAssertEqual(call(1, .error), .none)
    XCTAssertEqual(call(2, .error), .none)
    XCTAssertEqual(call(3, .ok), .none)
    XCTAssertEqual(guardState.consecutiveErrors, 0, "a success resets the streak")
    XCTAssertEqual(call(4, .error), .none)
    XCTAssertEqual(call(5, .refused), .none, "a refusal counts toward the streak but never nudges")
    guard case .nudge(let reason, _) = call(6, .error) else { return XCTFail("expected the failures nudge") }
    XCTAssertEqual(reason, "repeated failures")
    XCTAssertEqual(call(7, .error), .stuck(reason: "4 tool calls failed in a row"))
  }

  func testLoopGuardEditsPerFileNudgeWhenTheyLandAndStopWhenTheyKeepFailing() {
    // Successful edits to one file: a nudge to consolidate at the threshold, never a stop — a
    // symbol renamed occurrence by occurrence is work, not a loop.
    var guardState = LoopGuard(policy: LoopGuardPolicy(maxConsecutiveErrors: 0, maxIdenticalCalls: 0, maxEditsPerFile: 3, nudgeAt: 0))
    XCTAssertEqual(guardState.observe(tool: "edit_file", argumentsJSON: #"{"path":"x.swift","old":"1","new":"2"}"#, outcome: .ok), .none)
    XCTAssertEqual(guardState.observe(tool: "write_file", argumentsJSON: #"{"path":"x.swift","content":"3"}"#, outcome: .ok), .none)
    XCTAssertEqual(guardState.observe(tool: "edit_file", argumentsJSON: #"{"path":"other.swift","old":"1","new":"2"}"#, outcome: .ok), .none)
    XCTAssertEqual(
      guardState.observe(tool: "edit_file", argumentsJSON: #"{"path":"x.swift","old":"5","new":"6"}"#, outcome: .ok),
      .nudge(reason: "repeated edits", text: LoopGuard.editsNudge(file: "x.swift", count: 3)))
    XCTAssertTrue(LoopGuard.editsNudge(file: "x.swift", count: 3).hasPrefix("You have edited x.swift 3 times this turn."))
    for _ in 1...20 {
      XCTAssertEqual(
        guardState.observe(tool: "edit_file", argumentsJSON: "{\"path\":\"x.swift\",\"old\":\"\(UUID())\",\"new\":\"z\"}", outcome: .ok),
        .none, "one nudge per turn, and successful edits never stop the turn")
    }

    // Failed edits to one file — different ones, so neither the identical-call nor the
    // consecutive-error rule sees them — are the thrash the hard stop is for.
    var failing = LoopGuard(policy: LoopGuardPolicy(maxConsecutiveErrors: 0, maxIdenticalCalls: 0, maxEditsPerFile: 3, nudgeAt: 0))
    XCTAssertEqual(failing.observe(tool: "edit_file", argumentsJSON: #"{"path":"x.swift","old":"a","new":"b"}"#, outcome: .error), .none)
    XCTAssertEqual(failing.observe(tool: "edit_file", argumentsJSON: #"{"path":"x.swift","old":"c","new":"d"}"#, outcome: .ok), .none)
    XCTAssertEqual(
      failing.observe(tool: "edit_file", argumentsJSON: #"{"path":"x.swift","old":"e","new":"f"}"#, outcome: .error),
      .nudge(reason: "repeated edits", text: LoopGuard.editsNudge(file: "x.swift", count: 3)),
      "two failures, three edits: the count earns the nudge, the stop needs a third failure")
    XCTAssertEqual(
      failing.observe(tool: "edit_file", argumentsJSON: #"{"path":"x.swift","old":"g","new":"h"}"#, outcome: .error),
      .stuck(reason: "3 failed edits to x.swift in one turn"))

    XCTAssertEqual(
      LoopGuard.key(tool: "t", argumentsJSON: #"{"a":1,"b":2}"#),
      LoopGuard.key(tool: "t", argumentsJSON: #"{ "b": 2, "a": 1 }"#))
    XCTAssertNotEqual(LoopGuard.key(tool: "t", argumentsJSON: "{}"), LoopGuard.key(tool: "u", argumentsJSON: "{}"))
  }

  func testLoopGuardThresholdsOfZeroAreOff() {
    var guardState = LoopGuard(policy: LoopGuardPolicy(maxConsecutiveErrors: 0, maxIdenticalCalls: 0, maxEditsPerFile: 0, nudgeAt: 0))
    for _ in 1...50 {
      XCTAssertEqual(guardState.observe(tool: "edit_file", argumentsJSON: #"{"path":"x"}"#, outcome: .error), .none)
    }
  }

  // MARK: Loop guard (session)

  func testThreeConsecutiveFailuresNudgeOnceAndTheTurnContinues() async throws {
    let tool = ScriptedTool(name: "spy", results: ["error: a", "error: b", "error: c", "ok"])
    let mock = mock(steps: [("spy", #"{"text":"1"}"#), ("spy", #"{"text":"2"}"#), ("spy", #"{"text":"3"}"#), ("spy", #"{"text":"4"}"#)])
    let session = Session(
      service: mock, tools: [tool], store: store(), configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("go"))

    let nudges = events.compactMap { event -> String? in
      if case .nudged(let reason) = event { return reason } else { return nil }
    }
    XCTAssertEqual(nudges, ["repeated failures"])
    // The nudge rides the next request as an `[arnes]` user message, after the tool results.
    let fourth = mock.requests[3]
    let last = fourth.messages.last
    XCTAssertEqual(last?.role, .user)
    XCTAssertTrue(last?.content?.plainText.hasPrefix("[arnes] Your last 3 tool calls failed.") == true, last?.content?.plainText ?? "")
    XCTAssertEqual(mock.requests.count, 5, "the loop went on")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
    XCTAssertEqual(record?.nudges, 1)
    XCTAssertEqual(record?.toolStats?["spy"], ToolStat(calls: 4, errors: 3))
  }

  func testSixIdenticalFailingEditsEndTheTurnStuck() async throws {
    let args = #"{"path":"a.swift","text":"same"}"#
    let tool = ScriptedTool(name: "edit_file", results: Array(repeating: "error: old text not found", count: 8))
    let mock = mock(steps: Array(repeating: ("edit_file", args), count: 8))
    let session = Session(
      service: mock, tools: [tool], store: store(), configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("fix it"))

    let stuck = events.compactMap { event -> String? in
      if case .stuckDetected(let reason) = event { return reason } else { return nil }
    }
    XCTAssertEqual(stuck, ["the same edit_file call failed 6 times"])
    XCTAssertEqual(tool.callCount, 6, "the seventh call never happened")
    XCTAssertEqual(mock.requests.count, 6)
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .stuck)
    XCTAssertEqual(record?.finished, false)
    XCTAssertEqual(record?.nudges, 1, "the repeat nudge at 3 came first")
    // Every call in history is answered — the sixth's result is committed before the stop.
    let history = await session.history
    let calls = history.compactMap { $0.toolCalls }.flatMap { $0 }.count
    let answers = history.filter { $0.role == .tool }.count
    XCTAssertEqual(calls, answers)
    XCTAssertEqual(calls, 6)
  }

  func testEditsPerFileNudgeSuccessfulEditsAndStopFailingOnes() async throws {
    // Ten successful rewrites of one file: one nudge to consolidate, the turn runs to its end.
    let landing = ScriptedTool(name: "write_file", results: Array(repeating: "overwrote a.swift", count: 10))
    let steps = (1...10).map { ("write_file", "{\"path\":\"a.swift\",\"text\":\"v\($0)\"}") }
    let mock = mock(steps: steps)
    let session = Session(
      service: mock, tools: [landing], store: store(),
      configuration: .init(model: "test/model", loopGuard: LoopGuardPolicy(maxEditsPerFile: 4, nudgeAt: 0)))
    let events = try await Events.drain(await session.send("refactor"))
    XCTAssertFalse(events.contains { if case .stuckDetected = $0 { return true } else { return false } })
    XCTAssertEqual(
      events.compactMap { if case .nudged(let reason) = $0 { return reason } else { return nil } }, ["repeated edits"])
    XCTAssertEqual(landing.callCount, 10)
    let completed = await session.lastRecord
    XCTAssertEqual(completed?.stopReason, .completed)
    XCTAssertEqual(completed?.nudges, 1)
    XCTAssertTrue(
      mock.requests[4].messages.last?.content?.plainText.hasPrefix("[arnes] You have edited a.swift 4 times this turn.") == true)

    // Four *failed* edits to one file end the turn stuck.
    let failing = ScriptedTool(name: "write_file", results: Array(repeating: "error: sandbox denies write", count: 10))
    let failingMock = self.mock(steps: steps)
    let stuckSession = Session(
      service: failingMock, tools: [failing], store: store(),
      configuration: .init(model: "test/model", loopGuard: LoopGuardPolicy(maxConsecutiveErrors: 0, maxEditsPerFile: 4, nudgeAt: 0)))
    let stuckEvents = try await Events.drain(await stuckSession.send("thrash"))
    XCTAssertTrue(stuckEvents.contains { if case .stuckDetected(let reason) = $0 { return reason == "4 failed edits to a.swift in one turn" } else { return false } })
    XCTAssertEqual(failing.callCount, 4)
    let stopReason = await stuckSession.lastRecord?.stopReason
    XCTAssertEqual(stopReason, .stuck)
  }

  func testAGuardNudgeEarnedOnTheTurnsLastStepDiesWithTheTurn() async throws {
    // One step, three failing calls in it, and the turn ends on the step limit: the nudge was
    // earned but there is no next step — it must not land after the user's *next* message.
    let tool = ScriptedTool(name: "spy", results: ["error: a", "error: b", "error: c"])
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [
        Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: #"{"text":"1"}"#, index: 0),
        Fixtures.toolCallChunk(id: "c2", name: "spy", arguments: #"{"text":"2"}"#, index: 1),
        Fixtures.toolCallChunk(id: "c3", name: "spy", arguments: #"{"text":"3"}"#, index: 2),
        Fixtures.usageChunk(cost: 0.001),
      ],
      [Fixtures.textChunk("next turn"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("third turn"), Fixtures.usageChunk(cost: 0.001)],
    ]
    let session = Session(
      service: mock, tools: [tool], store: store(), configuration: .init(model: "test/model", maxStepsPerTurn: 1))
    let events = try await Events.drain(await session.send("first"))
    XCTAssertTrue(events.contains { if case .nudged(let reason) = $0 { return reason == "repeated failures" } else { return false } })
    XCTAssertTrue(events.contains { if case .stepLimitReached = $0 { return true } else { return false } })
    let first = await session.lastRecord
    XCTAssertEqual(first?.nudges, 1, "counted on the turn that earned it")

    _ = try await Events.drain(await session.send("second"))
    let messages = mock.requests[1].messages
    XCTAssertEqual(messages.last?.content?.plainText, "second")
    XCTAssertFalse(
      messages.contains { $0.content?.plainText.contains("[arnes] Your last 3 tool calls failed") == true },
      "the stale nudge is not delivered with the next turn")
    // A session notice queued the ordinary way still survives a turn boundary.
    await session.notify("background job finished")
    _ = try await Events.drain(await session.send("third"))
    XCTAssertTrue(mock.requests[2].messages.contains { $0.content?.plainText == "[arnes] background job finished" })
  }

  func testBackgroundExchangesAreNotCountedByTheGuardOrTheToolStats() async throws {
    // Six identical failing-looking background reports delivered at the step boundary: they are
    // not model calls, so the guard (identical calls, error streak) and `toolStats` ignore them.
    let outcomes = (1...6).map { n in
      BackgroundOutcome(
        id: "bg\(n)", agent: "helper", model: "sub/model", report: "error: the same failing report",
        steps: 1, toolCalls: 0, costUSD: 0.01, partial: false)
    }
    let source = QueuedBackgroundSource(finished: outcomes)
    let mock = mock(steps: [])
    let session = Session(
      service: mock, tools: [source], store: store(),
      configuration: .init(model: "test/model", loopGuard: LoopGuardPolicy(maxConsecutiveErrors: 2, maxIdenticalCalls: 2, nudgeAt: 2)))
    let events = try await Events.drain(await session.send("go"))
    XCTAssertFalse(events.contains { if case .nudged = $0 { return true } else { return false } })
    XCTAssertFalse(events.contains { if case .stuckDetected = $0 { return true } else { return false } })
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
    XCTAssertNil(record?.toolStats?["task"], "a delivered report is not a call the model made")
    XCTAssertEqual(record?.costUSD ?? 0, 0.06 + 0.001, accuracy: 0.0001, "its spend still lands on the turn")
    XCTAssertEqual(mock.requests[0].messages.filter { $0.role == .tool }.count, 6, "and the reports did reach history")
  }

  func testIdenticalSuccessfulCallsNeverHardStopTheTurn() async throws {
    let tool = ScriptedTool(name: "bash", results: [])
    let mock = mock(steps: Array(repeating: ("bash", #"{"command":"npm test"}"#), count: 8))
    let session = Session(
      service: mock, tools: [tool], store: store(), configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("rerun"))
    XCTAssertFalse(events.contains { if case .stuckDetected = $0 { return true } else { return false } })
    XCTAssertEqual(tool.callCount, 8)
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
    XCTAssertEqual(record?.nudges, 1, "one repeat nudge, then left alone")
  }

  func testDenialsStillEndTheTurnThroughTheDeniedLoopNotTheGuard() async throws {
    let tool = ScriptedTool(name: "spy", results: [], permission: .mutating)
    let mock = mock(steps: Array(repeating: ("spy", "{}"), count: 5))
    let session = Session(
      service: mock, tools: [tool],
      permissions: ScriptedPermissions(Array(repeating: .deny(reason: "no"), count: 5)),
      store: store(), configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("insist"))
    XCTAssertTrue(events.contains { if case .deniedLoop(let count) = $0 { return count == 3 } else { return false } })
    XCTAssertFalse(events.contains { if case .nudged = $0 { return true } else { return false } }, "refusals never earn a nudge")
    XCTAssertFalse(events.contains { if case .stuckDetected = $0 { return true } else { return false } })
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .deniedLoop)
    XCTAssertNil(record?.nudges)
    XCTAssertEqual(record?.toolStats?["spy"], ToolStat(calls: 3, errors: 0), "refused calls are counted, not as errors")
  }

  // MARK: Telemetry

  func testRunRecordDecodesOldRowsWithoutTheNewFieldsAndRoundTripsWithThem() throws {
    let old = """
      {"id":"r1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic",
       "steps":1,"toolCalls":1,"routedModels":[],"costUSD":0,"finished":true}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(RunRecord.self, from: Data(old.utf8))
    XCTAssertNil(decoded.truncatedResults)
    XCTAssertNil(decoded.toolStats)
    XCTAssertNil(decoded.nudges)

    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.truncatedResults = 2
    record.nudges = 1
    record.noteToolCall("bash", failed: false)
    record.noteToolCall("bash", failed: true)
    record.noteToolCall("grep", failed: false)
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let line = try encoder.encode(record)
    let back = try decoder.decode(RunRecord.self, from: line)
    XCTAssertEqual(back.truncatedResults, 2)
    XCTAssertEqual(back.nudges, 1)
    XCTAssertEqual(back.toolStats, ["bash": ToolStat(calls: 2, errors: 1), "grep": ToolStat(calls: 1, errors: 0)])
  }

  func testRunResultCarriesTruncatedResults() throws {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.truncatedResults = 3
    let result = RunResult(
      result: AgentResult(text: "done", record: record, sessionId: "S", durationMs: 1), costEstimated: false)
    XCTAssertEqual(result.truncatedResults, 3)
    let object = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(HeadlessJSON.line(result).utf8)) as? [String: Any])
    XCTAssertEqual(object["truncated_results"] as? Int, 3)
    let failure = RunResult.failure(
      stopReason: .error, error: "x", sessionId: nil, model: "m", provider: nil, record: record,
      costEstimated: false, durationMs: 1)
    XCTAssertEqual(failure.truncatedResults, 3)
  }

  // MARK: Config

  func testLimitsConfigDecodesWhenAbsentAndAppliesWhenPresent() throws {
    let absent = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"provider":"openrouter"}"#.utf8))
    XCTAssertNil(absent.limits)
    let effective = absent.limits ?? .default
    XCTAssertEqual(effective.effectiveToolResultChars, ToolOutputLimiter.defaultMaxChars)
    XCTAssertEqual(effective.effectiveBashOutputChars, BashTool.defaultOutputChars)
    XCTAssertEqual(effective.effectiveLoopGuard, .default)

    let present = try JSONDecoder().decode(ArnesConfig.self, from: Data("""
      {"limits": {"toolResultChars": 12000, "bashOutputChars": 8000,
                  "loopGuard": {"maxIdenticalCalls": 0, "nudgeAt": 2}}}
      """.utf8))
    let limits = try XCTUnwrap(present.limits)
    XCTAssertEqual(limits.effectiveToolResultChars, 12_000)
    XCTAssertEqual(limits.effectiveBashOutputChars, 8_000)
    XCTAssertEqual(
      limits.effectiveLoopGuard,
      LoopGuardPolicy(maxConsecutiveErrors: 6, maxIdenticalCalls: 0, maxEditsPerFile: 8, nudgeAt: 2),
      "unset thresholds keep their defaults, 0 switches one off")
    XCTAssertEqual(LimitsConfig(toolResultChars: 5).effectiveToolResultChars, ToolOutputLimiter.minimumMaxChars)
  }

  func testSubagentConfigurationInheritsTheCapAndGuardButNotTheSpillScope() {
    let scope = SpillScope(root: URL(fileURLWithPath: "/tmp/spill"), keepsFiles: false)
    let parent = Session.Configuration(
      model: "m", toolResultMaxChars: 12_000, spillScope: scope,
      loopGuard: LoopGuardPolicy(maxIdenticalCalls: 2))
    let nested = parent.forSubagent(named: "explore", model: "m2", systemSuffix: "")
    XCTAssertEqual(nested.toolResultMaxChars, 12_000)
    XCTAssertNil(nested.spillScope, "a nested session is never ended, so it never spills or opens the carve-out")
    XCTAssertEqual(nested.loopGuard, LoopGuardPolicy(maxIdenticalCalls: 2))
  }
}
