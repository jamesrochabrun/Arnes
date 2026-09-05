import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Helpers

private final class LineageEventCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AgentEvent] = []
  func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
  var events: [AgentEvent] { lock.withLock { stored } }
}

/// A5: a delegation leaves a transcript of its own (`<sessions>/subagents/<id>.jsonl`) with
/// lineage on its meta line and on its records, the report says how to come back to it, and
/// `resume: <id>` continues that session — scoped to the lead that spawned it.
final class SubagentLineageTests: XCTestCase {
  private let leadId = "LEAD-0000-1111-2222"

  private func tempRecords() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-lineage-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempSessions() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-lineage-sessions-\(UUID().uuidString)"))
  }

  private func manifest() -> String {
    Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
  }

  private let helper = AgentDefinition(
    name: "helper", description: "helps", body: "Help.", model: "sub/model")

  private func report(_ text: String, cost: Double = 0.01) -> [ChatCompletionChunk] {
    [Fixtures.textChunk(text, model: "sub/model"), Fixtures.usageChunk(cost: cost, model: "sub/model")]
  }

  private func tool(
    mock: MockOpenRouterService,
    sessions: SessionStore?,
    records: RunRecordStore? = nil,
    defaults: TaskTool.Defaults = TaskTool.Defaults(),
    agents: [AgentDefinition]? = nil,
    parent: String? = nil)
    -> TaskTool
  {
    let tool = TaskTool(
      agents: agents ?? [helper], service: mock, tools: [ReadFileTool()],
      store: records ?? tempRecords(), defaults: defaults, sessionStore: sessions,
      configuration: Session.Configuration(model: "lead/model"))
    tool.parentModel = { "lead/model" }
    tool.parentSessionId = parent ?? leadId
    return tool
  }

  /// The run id a report's trailer names.
  private func trailerId(in report: String) throws -> String {
    let marker = "[subagent id: "
    let range = try XCTUnwrap(report.range(of: marker), "no resume trailer in: \(report)")
    return String(report[range.upperBound...].prefix(8))
  }

  private func delegate(_ tool: TaskTool, _ task: String, extra: [String: JSONValue] = [:]) async throws -> String {
    var arguments: [String: JSONValue] = ["agent": .string("helper"), "task": .string(task)]
    for (key, value) in extra { arguments[key] = value }
    return try await tool.execute(arguments: arguments)
  }

  private func seedTranscript(
    in store: SessionStore, id: String, parent: String?, agent: String?, messages: [Message] = [])
    throws
  {
    try store.append(
      .meta(id: id, model: "sub/model", cwd: nil, parent: parent, agent: agent, depth: 1, origin: "subagent"),
      to: id)
    for message in messages {
      try store.append(TranscriptEntry(message: message), to: id)
    }
  }

  // MARK: Persistence

  func testDelegationLeavesANestedTranscriptWithLineageAndATrailer() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("dug through it")]
    let sessions = tempSessions()
    let records = tempRecords()
    let tool = tool(mock: mock, sessions: sessions, records: records)

    let result = try await delegate(tool, "dig through the thing")

    // The report body, then the trailer as its last line — and nothing else.
    let id = try trailerId(in: result)
    XCTAssertEqual(result, "dug through it" + TaskTool.resumeTrailer(id: id))
    // One nested transcript under subagents/, none in the lead's directory.
    let nested = try sessions.subagentStore.list()
    XCTAssertEqual(nested.count, 1)
    XCTAssertEqual(try sessions.list().count, 0, "the lead store holds no subagent transcript")
    let meta = try XCTUnwrap(nested.first)
    XCTAssertEqual(TaskTool.runId(of: meta.id), id, "the trailer names the transcript")
    XCTAssertEqual(meta.parent, leadId)
    XCTAssertEqual(meta.agent, "helper")
    XCTAssertEqual(meta.depth, 1)
    XCTAssertEqual(meta.origin, "subagent")
    XCTAssertEqual(meta.model, "sub/model")
    XCTAssertTrue(meta.isSubagent)
    // The history replays: the task and the report.
    let loaded = try sessions.subagentStore.load(id: meta.id)
    XCTAssertEqual(loaded.messages.map { $0.content?.plainText }, ["dig through the thing", "dug through it"])
    XCTAssertEqual(loaded.meta.parent, leadId)
    XCTAssertEqual(loaded.costUSD, 0.01, accuracy: 0.0001)
    // The nested record carries the lineage.
    let row = try XCTUnwrap(try records.all().first)
    XCTAssertEqual(row.agent, "helper")
    XCTAssertEqual(row.parentSessionId, leadId)
    XCTAssertEqual(row.depth, 1)
    XCTAssertEqual(row.background, false)
    XCTAssertEqual(row.sessionId, meta.id)
    XCTAssertFalse(row.partial)
  }

  func testPersistTranscriptsOffWritesNothingAndAddsNoTrailer() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("plain")]
    let sessions = tempSessions()
    let tool = tool(mock: mock, sessions: sessions, defaults: TaskTool.Defaults(persistTranscripts: false))

    let result = try await delegate(tool, "dig")

    XCTAssertEqual(result, "plain", "no transcript → no trailer")
    XCTAssertEqual(try sessions.subagentStore.list().count, 0)
    // And with no store at all, `resume` says why it can't.
    let resumed = try await tool.execute(arguments: ["task": .string("more"), "resume": .string("abcd1234")])
    XCTAssertTrue(resumed.hasPrefix("error: subagent transcripts are off"), resumed)
  }

  func testLeadTranscriptStaysCleanAndTheLeadRecordSaysDepthZero() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    // Lead step delegating → nested report → lead reply.
    mock.chunkScriptsByModel = [
      "lead/model": [
        [
          Fixtures.toolCallChunk(
            id: "c1", name: "task", arguments: #"{"agent":"helper","task":"dig"}"#, index: 0, model: "lead/model"),
          Fixtures.usageChunk(cost: 0.1, model: "lead/model"),
        ],
        [Fixtures.textChunk("done", model: "lead/model"), Fixtures.usageChunk(cost: 0.1, model: "lead/model")],
      ],
      "sub/model": [report("found it")],
    ]
    let sessions = tempSessions()
    let records = tempRecords()
    var configuration = Session.Configuration(model: "lead/model")
    configuration.sessionOrigin = "interactive"
    let taskTool = TaskTool(
      agents: [helper], service: mock, tools: [], store: records, sessionStore: sessions,
      configuration: configuration)
    let lead = Session(
      service: mock, tools: [taskTool], store: records, sessionStore: sessions, configuration: configuration)
    taskTool.parentModel = { await lead.model }
    taskTool.parentSessionId = lead.id

    for try await _ in await lead.send("go") { }

    // Two transcripts, in two directories: the lead's (with its origin) and the subagent's.
    let leads = try sessions.list()
    XCTAssertEqual(leads.map(\.id), [lead.id])
    XCTAssertNil(leads[0].parent)
    XCTAssertEqual(leads[0].origin, "interactive")
    XCTAssertEqual(leads[0].messageCount, 4, "user, assistant call, tool result, assistant reply")
    let nested = try sessions.subagentStore.list()
    XCTAssertEqual(nested.map(\.parent), [lead.id])
    XCTAssertEqual(nested[0].messageCount, 2)
    // Every record knows its depth; only the nested one has a parent.
    let rows = try records.all()
    XCTAssertEqual(rows.count, 2)
    let nestedRow = try XCTUnwrap(rows.first { $0.agent == "helper" })
    let leadRow = try XCTUnwrap(rows.first { $0.agent == nil })
    XCTAssertEqual(nestedRow.parentSessionId, lead.id)
    XCTAssertEqual(nestedRow.depth, 1)
    XCTAssertNil(leadRow.parentSessionId)
    XCTAssertEqual(leadRow.depth, 0)
    XCTAssertNil(leadRow.background, "a lead is never detached")
  }

  func testABackgroundRunRecordsBackgroundTrue() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("late")]
    let records = tempRecords()
    let tool = tool(mock: mock, sessions: tempSessions(), records: records)

    _ = try await delegate(tool, "long", extra: ["background": .bool(true)])
    let awaited = await tool.awaitAnyBackground()
    let outcome = try XCTUnwrap(awaited)

    XCTAssertTrue(outcome.report.contains("[subagent id: \(outcome.id)"), "a delivered report carries the trailer too")
    let row = try XCTUnwrap(try records.all().first)
    XCTAssertEqual(row.background, true)
    XCTAssertEqual(row.parentSessionId, leadId)
  }

  // MARK: Resume

  func testResumeContinuesTheRunWithHistoryIntactAndNoNewFile() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("first report"), report("second report")]
    let sessions = tempSessions()
    let tool = tool(mock: mock, sessions: sessions)
    let collector = LineageEventCollector()
    tool.onEvent = { collector.append($0) }

    let first = try await delegate(tool, "first task")
    let id = try trailerId(in: first)
    // The agent is recorded on the run, so the argument may be omitted.
    let second = try await tool.execute(arguments: [
      "task": .string("now the follow-up"), "resume": .string(id),
    ])

    XCTAssertEqual(second, "second report" + TaskTool.resumeTrailer(id: id), "same run, same trailer")
    // The second request carries the whole history: task, report, follow-up.
    let request = try XCTUnwrap(mock.requests.last)
    let texts = request.messages.filter { $0.role != .system }.map { $0.content?.plainText }
    XCTAssertEqual(texts, ["first task", "first report", "now the follow-up"])
    // One transcript file, now four messages long; no second file was started.
    let nested = try sessions.subagentStore.list()
    XCTAssertEqual(nested.count, 1)
    XCTAssertEqual(nested[0].messageCount, 4)
    XCTAssertEqual(TaskTool.runId(of: nested[0].id), id)
    // The ◇ line marks the continuation.
    let starts = collector.events.compactMap { event -> (String, String)? in
      if case .subagentStarted(_, let startedId, _, let task) = event { return (startedId, task) }
      return nil
    }
    XCTAssertEqual(starts.map(\.0), [id, id])
    XCTAssertEqual(starts.map(\.1), ["first task", "(resumed) now the follow-up"])
  }

  func testResumeReplaysTheTranscriptAmongOtherRunsAndFromAnotherToolInstance() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let runs = 3
    mock.chunkScripts = (1...runs).map { report("report \($0)") } + [report("resumed on disk"), report("resumed elsewhere")]
    let sessions = tempSessions()
    let tool = tool(mock: mock, sessions: sessions)

    var ids: [String] = []
    for index in 1...runs {
      ids.append(try trailerId(in: try await delegate(tool, "task \(index)")))
    }
    // The oldest run, with newer ones beside it in the store: its transcript is what the
    // resume replays.
    let fromDisk = try await tool.execute(arguments: ["task": .string("again"), "resume": .string(ids[0])])
    XCTAssertEqual(fromDisk, "resumed on disk" + TaskTool.resumeTrailer(id: ids[0]))
    var texts = mock.requests.last?.messages.filter { $0.role != .system }.map { $0.content?.plainText }
    XCTAssertEqual(texts, ["task 1", "report 1", "again"])

    // A new process: another tool over the same store and lead id finds it too.
    let other = self.tool(mock: mock, sessions: sessions)
    let elsewhere = try await other.execute(arguments: [
      "agent": .string("helper"), "task": .string("once more"), "resume": .string(ids[0]),
    ])
    XCTAssertEqual(elsewhere, "resumed elsewhere" + TaskTool.resumeTrailer(id: ids[0]))
    texts = mock.requests.last?.messages.filter { $0.role != .system }.map { $0.content?.plainText }
    XCTAssertEqual(texts, ["task 1", "report 1", "again", "resumed on disk", "once more"])
    XCTAssertEqual(try sessions.subagentStore.list().count, runs, "no resume started a new transcript")
  }

  func testResumeOfABudgetCappedRunGetsThisTurnsAllowanceOnTopOfItsSpend() async throws {
    // The run a resume exists to finish: one that hit its budget. The resumed session starts at
    // the transcript's cumulative spend, so a cap computed from zero would end it before its
    // first request — the cap must be the agent's allowance *plus* what was already spent.
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let capped = AgentDefinition(
      name: "helper", description: "helps", body: "Help.", model: "sub/model", budgetUSD: 0.02)
    mock.chunkScripts = [
      // Step 1 spends more than the whole budget and asks for more work; the pre-step check
      // stops step 2.
      [
        Fixtures.textChunk("partway", model: "sub/model"),
        Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"more"}"#, model: "sub/model"),
        Fixtures.usageChunk(cost: 0.03, model: "sub/model"),
      ],
      report("finished the work", cost: 0.01),
    ]
    let sessions = tempSessions()
    let tool = TaskTool(
      agents: [capped], service: mock, tools: [ThinkTool()], store: tempRecords(), sessionStore: sessions,
      configuration: Session.Configuration(model: "lead/model"))
    tool.parentModel = { "lead/model" }
    tool.parentSessionId = leadId

    let first = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("do the thing")])
    let id = try trailerId(in: first)
    XCTAssertTrue(first.hasPrefix("[subagent hit its budget ($0.0300 of $0.0200)"), first)
    XCTAssertEqual(mock.requests.count, 1)
    XCTAssertEqual(tool.drainAccruedCost(), 0.03, accuracy: 0.0001)

    let second = try await tool.execute(arguments: ["task": .string("finish it"), "resume": .string(id)])

    XCTAssertEqual(second, "finished the work" + TaskTool.resumeTrailer(id: id))
    XCTAssertEqual(mock.requests.count, 2, "the resumed turn made its request instead of stopping at the cap")
    let texts = mock.requests.last?.messages.filter { $0.role != .system }.map { $0.content?.plainText }
    XCTAssertEqual(texts?.first, "do the thing")
    XCTAssertEqual(texts?.last, "finish it")
    // Only this turn's spend reaches the parent; the earlier $0.03 was booked when it landed.
    XCTAssertEqual(tool.drainAccruedCost(), 0.01, accuracy: 0.0001)
    // And the transcript reads as one conversation: no user turn left without its reply.
    let loaded = try sessions.subagentStore.load(id: try XCTUnwrap(sessions.subagentStore.list().first?.id))
    XCTAssertEqual(loaded.messages.last?.content?.plainText, "finished the work")
    XCTAssertEqual(loaded.costUSD, 0.04, accuracy: 0.0001)
  }

  func testAFailedResumedTurnBooksOnlyItsOwnSpend() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("first", cost: 0.05)] // nothing scripted for the resume: it fails
    let tool = tool(mock: mock, sessions: tempSessions())

    let id = try trailerId(in: try await delegate(tool, "first"))
    XCTAssertEqual(tool.drainAccruedCost(), 0.05, accuracy: 0.0001)

    let failed = try await tool.execute(arguments: ["task": .string("again"), "resume": .string(id)])

    XCTAssertTrue(failed.hasPrefix("error: subagent 'helper' failed:"), failed)
    XCTAssertEqual(tool.drainAccruedCost(), 0, accuracy: 0.0001, "the run's past spend is not booked twice")
  }

  func testResumeTakesThePermissionModeFromTheCurrentParentNotTheOneThatSpawned() async throws {
    // Spawned under a parent that allows edits, resumed under one in plan mode: the resumed
    // turn runs with the current parent's mode, not the configuration the run started with.
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let sessions = tempSessions()
    let workdir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-lineage-work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    func tool(mode: PermissionMode) -> TaskTool {
      let tool = TaskTool(
        agents: [helper], service: mock, tools: [WriteFileTool(root: workdir)],
        store: tempRecords(), sessionStore: sessions,
        configuration: Session.Configuration(
          model: "lead/model", workingDirectory: workdir, permissionMode: mode))
      tool.parentModel = { "lead/model" }
      tool.parentSessionId = leadId
      return tool
    }
    mock.chunkScripts = [
      report("noted"),
      [
        Fixtures.toolCallChunk(
          id: "w1", name: "write_file",
          arguments: #"{"path":"\#(workdir.path)/x.txt","content":"hi"}"#, index: 0, model: "sub/model"),
        Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ],
      report("gave up"),
    ]
    let id = try trailerId(in: try await delegate(tool(mode: .acceptEdits), "look"))

    _ = try await tool(mode: .plan).execute(arguments: ["task": .string("write it"), "resume": .string(id)])

    XCTAssertFalse(FileManager.default.fileExists(atPath: workdir.appendingPathComponent("x.txt").path))
    let toolResult = mock.requests.last?.messages.first { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolResult.contains("plan mode"), toolResult)
  }

  func testAResumeStillInItsTurnIsNotResumableAgain() async throws {
    // Two sessions over one transcript would interleave their writes: while a resumed turn is
    // out, the same id is refused like a running background run.
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("first"), report("second")]
    let reached = Latch()
    let release = Latch()
    let tool = tool(mock: mock, sessions: tempSessions())
    let id = try trailerId(in: try await delegate(tool, "first"))

    mock.streamGate = { _ in
      await reached.arrive()
      await release.wait(for: 1)
    }
    let inFlight = Task { try await tool.execute(arguments: ["task": .string("again"), "resume": .string(id)]) }
    await reached.wait(for: 1)
    let refused = try await tool.execute(arguments: ["task": .string("and again"), "resume": .string(id)])
    XCTAssertEqual(refused, "error: subagent \(id) is still running — wait for its report")

    await release.arrive()
    let second = try await inFlight.value
    XCTAssertEqual(second, "second" + TaskTool.resumeTrailer(id: id))
    XCTAssertEqual(mock.requests.count, 2, "the refusal spent nothing")
  }

  func testNoParentSessionIdMeansNoTranscriptAndNoTrailer() async throws {
    // An embedder that hands over a store without binding the lead's id: a transcript with no
    // parent could never be resumed (the scope rule) nor swept with its lead, so none is written
    // and the report doesn't promise one.
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("orphan-free")]
    let sessions = tempSessions()
    let tool = TaskTool(
      agents: [helper], service: mock, tools: [ReadFileTool()], store: tempRecords(), sessionStore: sessions,
      configuration: Session.Configuration(model: "lead/model"))
    tool.parentModel = { "lead/model" }

    let result = try await delegate(tool, "go")

    XCTAssertEqual(result, "orphan-free")
    XCTAssertEqual(try sessions.subagentStore.list().count, 0)
  }

  func testResumeRebuildsPermissionsFromTheCurrentParentNotTheTranscript() async throws {
    // A read-only agent stays read-only on resume: the delegate is rebuilt from the agent
    // definition, so the nested session refuses a write however the transcript reads.
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let readOnly = AgentDefinition(
      name: "helper", description: "", body: "b", model: "sub/model", permissionMode: .readOnly)
    let sessions = tempSessions()
    let workdir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-lineage-work-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    let tool = TaskTool(
      agents: [readOnly], service: mock, tools: [WriteFileTool(root: workdir)],
      store: tempRecords(), sessionStore: sessions,
      configuration: Session.Configuration(model: "lead/model", workingDirectory: workdir))
    tool.parentModel = { "lead/model" }
    tool.parentSessionId = leadId
    mock.chunkScripts = [
      report("noted"),
      // The resumed turn tries to write; the read-only posture must refuse it.
      [
        Fixtures.toolCallChunk(
          id: "w1", name: "write_file",
          arguments: #"{"path":"\#(workdir.path)/x.txt","content":"hi"}"#, index: 0, model: "sub/model"),
        Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ],
      report("gave up"),
    ]
    let id = try trailerId(in: try await delegate(tool, "look"))

    // Evict from memory so the resume goes through the transcript.
    let fresh = TaskTool(
      agents: [readOnly], service: mock, tools: [WriteFileTool(root: workdir)],
      store: tempRecords(), sessionStore: sessions,
      configuration: Session.Configuration(model: "lead/model", workingDirectory: workdir))
    fresh.parentModel = { "lead/model" }
    fresh.parentSessionId = leadId
    _ = try await fresh.execute(arguments: ["task": .string("write it"), "resume": .string(id)])

    XCTAssertFalse(FileManager.default.fileExists(atPath: workdir.appendingPathComponent("x.txt").path))
    let toolResult = mock.requests.last?.messages.first { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolResult.contains("read-only"), toolResult)
  }

  // MARK: Refusals

  func testUnknownAndAmbiguousIdsAreRefusedWithCandidates() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("one")]
    let sessions = tempSessions()
    let tool = tool(mock: mock, sessions: sessions)
    let known = try trailerId(in: try await delegate(tool, "first"))

    let unknown = try await tool.execute(arguments: ["task": .string("x"), "resume": .string("zzzz9999")])
    XCTAssertTrue(unknown.hasPrefix("error: no subagent run matches 'zzzz9999'"), unknown)
    XCTAssertTrue(unknown.contains("Runs of this session: \(known)"), unknown)

    // Two transcripts sharing a prefix: the query names both, so neither is chosen. A third
    // under the same prefix belongs to another lead: it is neither listed nor counted.
    try seedTranscript(in: sessions.subagentStore, id: "AAAA1111-0000-0000-0000-000000000001", parent: leadId, agent: "helper")
    try seedTranscript(in: sessions.subagentStore, id: "AAAA2222-0000-0000-0000-000000000002", parent: leadId, agent: "helper")
    try seedTranscript(in: sessions.subagentStore, id: "AAAA3333-0000-0000-0000-000000000003", parent: "OTHER-LEAD", agent: "helper")
    let ambiguous = try await tool.execute(arguments: ["task": .string("x"), "resume": .string("aaaa")])
    XCTAssertTrue(ambiguous.hasPrefix("error: 'aaaa' matches several subagent runs: "), ambiguous)
    XCTAssertTrue(ambiguous.contains("AAAA1111-0000-0000-0000-000000000001"))
    XCTAssertTrue(ambiguous.contains("AAAA2222-0000-0000-0000-000000000002"))
    XCTAssertFalse(ambiguous.contains("AAAA3333"), "another lead's run is not this session's to be told about")
    // A prefix that is unique only because of another lead's run resolves to a refusal, not to
    // that run — and a prefix unique among this session's runs is not made ambiguous by it.
    let theirs = try await tool.execute(arguments: ["task": .string("x"), "resume": .string("aaaa3")])
    XCTAssertEqual(theirs, "error: aaaa3333 is not a subagent of this session")
    let ours = try await tool.execute(arguments: ["task": .string("x"), "resume": .string("aaaa1")])
    XCTAssertTrue(ours.hasPrefix("error: subagent 'helper' failed:"), "the seeded run resolves and runs (nothing scripted): \(ours)")
    XCTAssertEqual(mock.requests.count, 2, "only the resolved run spent a request")
  }

  func testAnotherSessionsSubagentIsNotResumable() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("one")]
    let sessions = tempSessions()
    // On disk, parented to someone else.
    try seedTranscript(
      in: sessions.subagentStore, id: "BBBB1111-0000-0000-0000-000000000001", parent: "OTHER-LEAD", agent: "helper",
      messages: [.user("their task"), .assistant("their report")])
    let tool = tool(mock: mock, sessions: sessions)

    let disk = try await tool.execute(arguments: ["task": .string("x"), "resume": .string("bbbb1111")])
    XCTAssertEqual(disk, "error: bbbb1111 is not a subagent of this session")

    // In memory, after the lead changed underneath the tool (the REPL's /resume rebinding).
    let id = try trailerId(in: try await delegate(tool, "mine"))
    tool.parentSessionId = "ANOTHER-LEAD"
    let live = try await tool.execute(arguments: ["task": .string("x"), "resume": .string(id)])
    XCTAssertEqual(live, "error: \(id) is not a subagent of this session")
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testAForkOfTheLeadMayResumeTheOriginalsSubagents() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("continued")]
    let sessions = tempSessions()
    // The lead store knows FORK was copied from ORIG; the subagent ran under ORIG.
    try sessions.append(.meta(id: "ORIG-0000", model: "lead/model", cwd: nil), to: "ORIG-0000")
    try sessions.append(.meta(id: "FORK-0000", model: "lead/model", cwd: nil), to: "FORK-0000")
    var forkMeta = TranscriptEntry(type: .meta)
    forkMeta.id = "FORK-0000"
    forkMeta.forkedFrom = "ORIG-0000"
    try sessions.append(forkMeta, to: "FORK-0000")
    try seedTranscript(
      in: sessions.subagentStore, id: "CCCC1111-0000-0000-0000-000000000001", parent: "ORIG-0000", agent: "helper",
      messages: [.user("old task"), .assistant("old report")])
    let tool = tool(mock: mock, sessions: sessions, parent: "FORK-0000")

    let result = try await tool.execute(arguments: ["task": .string("go on"), "resume": .string("cccc1111")])

    XCTAssertEqual(result, "continued" + TaskTool.resumeTrailer(id: "cccc1111"))
    let texts = mock.requests.last?.messages.filter { $0.role != .system }.map { $0.content?.plainText }
    XCTAssertEqual(texts, ["old task", "old report", "go on"])
  }

  func testAgentMismatchNamesTheRecordedAgent() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("one")]
    let other = AgentDefinition(name: "other", description: "", body: "b", model: "sub/model")
    let tool = tool(mock: mock, sessions: tempSessions(), agents: [helper, other])
    let id = try trailerId(in: try await delegate(tool, "mine"))

    let result = try await tool.execute(arguments: [
      "agent": .string("other"), "task": .string("x"), "resume": .string(id),
    ])
    XCTAssertEqual(
      result,
      "error: subagent \(id) was run by 'helper', not 'other' — pass agent: \"helper\" or omit it")
  }

  func testAStillRunningBackgroundRunIsNotResumable() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [report("late")]
    let release = Latch()
    mock.streamGate = { request in
      guard request.model == "sub/model" else { return }
      await release.wait(for: 1)
    }
    let tool = tool(mock: mock, sessions: tempSessions())

    let started = try await delegate(tool, "long", extra: ["background": .bool(true)])
    let id = try XCTUnwrap(tool.backgroundSnapshot().first?.id)
    XCTAssertTrue(started.contains(id))
    let result = try await tool.execute(arguments: ["task": .string("x"), "resume": .string(id)])
    XCTAssertEqual(result, "error: subagent \(id) is still running — wait for its report")

    await release.arrive()
    _ = await tool.awaitAnyBackground()
  }

  func testRunMatchesAcceptsTheShortIdOrTheFullOne() {
    XCTAssertTrue(TaskTool.runMatches("abcd1234", query: "abcd1234"))
    XCTAssertTrue(TaskTool.runMatches("abcd1234", query: "ABCD1234-0000-0000-0000-000000000000"))
    XCTAssertTrue(TaskTool.runMatches("abcd1234", query: "abcd"))
    XCTAssertFalse(TaskTool.runMatches("abcd1234", query: "abce"))
    XCTAssertFalse(TaskTool.runMatches("abcd1234", query: "abcd1235-0000"))
  }

  // MARK: Schema

  func testSchemaOffersResume() {
    let tool = tool(mock: MockOpenRouterService(), sessions: nil)
    guard case .object(let schema) = tool.parameters,
          case .object(let properties) = schema["properties"]
    else {
      return XCTFail("schema is not an object")
    }
    XCTAssertNotNil(properties["resume"])
    XCTAssertEqual(schema["required"], .array([.string("agent"), .string("task")]), "agent stays required in the schema")
    XCTAssertEqual(
      tool.summary(arguments: ["task": .string("more"), "resume": .string("abcd1234")]),
      "task → resume abcd1234: more")
  }

  // MARK: Records and meta decode

  func testOldRecordRowsAndMetaLinesWithoutLineageDecode() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let row = """
      {"id":"r1","startedAt":"2025-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat",\
      "packFamily":"generic","steps":1,"toolCalls":0,"routedModels":[],"costUSD":0,"finished":true}
      """
    let record = try decoder.decode(RunRecord.self, from: Data(row.utf8))
    XCTAssertNil(record.parentSessionId)
    XCTAssertNil(record.depth)
    XCTAssertNil(record.background)
    XCTAssertFalse(record.partial)

    let meta = try decoder.decode(
      TranscriptEntry.self,
      from: Data(#"{"type":"meta","id":"s1","model":"m","cwd":"/tmp"}"#.utf8))
    XCTAssertNil(meta.parent)
    XCTAssertNil(meta.agent)
    XCTAssertNil(meta.depth)
    XCTAssertNil(meta.origin)

    // A new meta line round-trips its lineage.
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let written = TranscriptEntry.meta(
      id: "n1", model: "m", cwd: nil, parent: "p1", agent: "helper", depth: 1, origin: "subagent")
    let read = try decoder.decode(TranscriptEntry.self, from: try encoder.encode(written))
    XCTAssertEqual(read.parent, "p1")
    XCTAssertEqual(read.agent, "helper")
    XCTAssertEqual(read.depth, 1)
    XCTAssertEqual(read.origin, "subagent")
  }

  func testPartialIsDerivedFromTheStopReason() {
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    XCTAssertFalse(record.partial)
    record.stopReason = .maxSteps
    XCTAssertTrue(record.partial)
    record.stopReason = .budget
    XCTAssertTrue(record.partial)
    record.stopReason = .completed
    XCTAssertFalse(record.partial)
  }

  // MARK: SessionStore

  func testMatchFindsExactIdUniquePrefixOrNameAndReportsAmbiguity() {
    let sessions = [
      SessionMeta(id: "abc123", name: "demo", updatedAt: Date(), messageCount: 1),
      SessionMeta(id: "abd456", updatedAt: Date(), messageCount: 1),
      SessionMeta(id: "xyz789", name: "Fix-Parser", updatedAt: Date(), messageCount: 1),
    ]
    XCTAssertEqual(SessionStore.match("abd456", in: sessions), .found(sessions[1]))
    XCTAssertEqual(SessionStore.match("xyz", in: sessions), .found(sessions[2]))
    XCTAssertEqual(SessionStore.match("fix-parser", in: sessions), .found(sessions[2]))
    XCTAssertEqual(SessionStore.match("nope", in: sessions), .none)
    XCTAssertEqual(SessionStore.match("ab", in: sessions), .ambiguous([sessions[0], sessions[1]]))
  }

  func testResolvePrefixOverTheStoreAndTheIndexCarriesLineage() throws {
    let sessions = tempSessions()
    let nested = sessions.subagentStore
    try seedTranscript(in: nested, id: "DDDD1111-0000-0000-0000-000000000001", parent: leadId, agent: "helper")
    try seedTranscript(in: nested, id: "DDDD2222-0000-0000-0000-000000000002", parent: leadId, agent: "scout")

    XCTAssertEqual(nested.resolve(prefix: "dddd1111"), "DDDD1111-0000-0000-0000-000000000001")
    XCTAssertNil(nested.resolve(prefix: "dddd"), "ambiguous → nil")
    XCTAssertNil(nested.resolve(prefix: "eeee"), "none → nil")
    XCTAssertNil(sessions.resolve(prefix: "dddd1111"), "the lead store doesn't see nested transcripts")
    // A second list() is served from the index and still knows the lineage.
    let again = try nested.list()
    XCTAssertEqual(Set(again.compactMap(\.agent)), ["helper", "scout"])
    XCTAssertEqual(Set(again.compactMap(\.parent)), [leadId])
  }

  func testDeletingALeadRemovesItsSubagentTranscriptsAndPruneSweepsBoth() throws {
    let sessions = tempSessions()
    try sessions.append(.meta(id: "LEAD-A", model: "m", cwd: nil), to: "LEAD-A")
    try sessions.append(.meta(id: "LEAD-B", model: "m", cwd: nil), to: "LEAD-B")
    let nested = sessions.subagentStore
    try seedTranscript(in: nested, id: "A1A1A1A1-0000-0000-0000-000000000001", parent: "LEAD-A", agent: "helper")
    try seedTranscript(in: nested, id: "B1B1B1B1-0000-0000-0000-000000000001", parent: "LEAD-B", agent: "helper")

    try sessions.delete(id: "LEAD-A")
    XCTAssertEqual(try sessions.list().map(\.id), ["LEAD-B"])
    XCTAssertEqual(try nested.list().map(\.id), ["B1B1B1B1-0000-0000-0000-000000000001"], "A's subagent went with it")

    // Everything is "old" against a zero-day cutoff... except prune(0) means today; age the files.
    let past = Date(timeIntervalSinceNow: -3 * 86_400)
    for url in [sessions.directory.appendingPathComponent("LEAD-B.jsonl"),
                nested.directory.appendingPathComponent("B1B1B1B1-0000-0000-0000-000000000001.jsonl")]
    {
      try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
    }
    XCTAssertEqual(try sessions.prune(olderThan: 1), 1, "the lead (its subagent going with it)")
    XCTAssertEqual(try sessions.list().count, 0)
    XCTAssertEqual(try nested.list().count, 0)

    // An orphaned nested transcript (its lead already gone) is swept by age too.
    try seedTranscript(in: nested, id: "C1C1C1C1-0000-0000-0000-000000000001", parent: "LEAD-GONE", agent: "helper")
    try FileManager.default.setAttributes(
      [.modificationDate: past],
      ofItemAtPath: nested.directory.appendingPathComponent("C1C1C1C1-0000-0000-0000-000000000001.jsonl").path)
    XCTAssertEqual(try sessions.prune(olderThan: 1), 1)
    XCTAssertEqual(try nested.list().count, 0)
  }

  func testExportNamesTheLineage() throws {
    let sessions = tempSessions()
    try seedTranscript(
      in: sessions.subagentStore, id: "E1E1E1E1-0000-0000-0000-000000000001", parent: leadId, agent: "helper",
      messages: [.user("task"), .assistant("report")])
    let markdown = try sessions.subagentStore.exportMarkdown(id: "E1E1E1E1-0000-0000-0000-000000000001")
    XCTAssertTrue(markdown.contains("- agent: helper"), markdown)
    XCTAssertTrue(markdown.contains("- subagent of: \(leadId)"), markdown)
  }

  func testForSubagentSetsLineage() {
    let lead = Session.Configuration(model: "lead/model", sessionOrigin: "do")
    let nested = lead.forSubagent(
      named: "helper", model: "sub/model", systemSuffix: "role", parentSessionId: "LEAD-1")
    XCTAssertEqual(nested.parentSessionId, "LEAD-1")
    XCTAssertEqual(nested.depth, 1)
    XCTAssertEqual(nested.sessionOrigin, "subagent")
    XCTAssertFalse(nested.spawnedInBackground)
    XCTAssertEqual(lead.depth, 0)
    XCTAssertNil(lead.parentSessionId)
  }
}
