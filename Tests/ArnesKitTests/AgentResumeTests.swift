import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// Collects events from `onEvent`, which is `@Sendable` and so can't append to a plain var.
private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var events: [AgentEvent] = []

  func note(_ event: AgentEvent) {
    lock.withLock { events.append(event) }
  }

  var all: [AgentEvent] {
    lock.withLock { events }
  }
}

/// X3 — the headless parity pieces that live in ArnesKit: `Agent.run(… resuming:)` (what
/// `arnes do --resume/--continue/--fork` runs), the `systemSuffix` placement
/// (`--append-system-prompt`), and the lead-as-agent helpers (`--agent`).
final class AgentResumeTests: XCTestCase {
  private func tempSessionStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-agentresume-\(UUID().uuidString)"))
  }

  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-agentresume-\(UUID().uuidString).jsonl"))
  }

  private func mock(_ scripts: [[ChatCompletionChunk]], models: [String] = ["test/model"]) -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(models.map { Fixtures.manifestModel(id: $0) }.joined(separator: ","))
    mock.chunkScripts = scripts
    return mock
  }

  private func plainRuns(_ replies: String..., models: [String] = ["test/model"]) -> MockOpenRouterService {
    mock(replies.map { [Fixtures.textChunk($0), Fixtures.usageChunk(cost: 0.01)] }, models: models)
  }

  // MARK: Resume

  func testResumingRunsTheTaskInTheLoadedSession() async throws {
    let mock = plainRuns("first answer", "second answer")
    let sessions = tempSessionStore()
    let records = tempRecordStore()
    let agent = Agent(service: mock, tools: [], store: records, sessionStore: sessions, configuration: .init(model: "test/model"))

    let first = try await agent.run(task: "first task", model: "test/model")
    XCTAssertEqual(first.text, "first answer")
    let loaded = try sessions.load(id: first.sessionId)
    XCTAssertEqual(loaded.messages.count, 2)
    XCTAssertEqual(loaded.turnCount, 1)

    let second = try await agent.run(task: "second task", model: loaded.model, resuming: loaded)
    XCTAssertEqual(second.text, "second answer")
    // Same session, next turn: the id is kept and the record says turn 1, not 0.
    XCTAssertEqual(second.sessionId, first.sessionId)
    XCTAssertEqual(second.record.sessionId, first.sessionId)
    XCTAssertEqual(second.record.turnIndex, 1)
    XCTAssertEqual(first.record.turnIndex, 0)
    // The request carried the replayed history ahead of the new task.
    let request = try XCTUnwrap(mock.requests.last)
    let texts = request.messages.map { ($0.role, $0.content?.plainText ?? "") }
    XCTAssertEqual(texts.dropFirst().map(\.1), ["first task", "first answer", "second task"])
    XCTAssertEqual(texts.dropFirst().map(\.0), [.user, .assistant, .user])
    XCTAssertEqual(request.model, "test/model")
    // The continued transcript landed in the same store: four messages, two turns, summed cost.
    let after = try sessions.load(id: first.sessionId)
    XCTAssertEqual(after.messages.count, 4)
    XCTAssertEqual(after.turnCount, 2)
    XCTAssertEqual(after.costUSD, 0.02, accuracy: 0.0001)
    XCTAssertEqual(try records.all().count, 2)
  }

  func testResumingOnAnotherModelSwapsLikeSlashModelAndPersistsIt() async throws {
    let mock = plainRuns("one", "two", models: ["test/model", "other/model"])
    let sessions = tempSessionStore()
    let agent = Agent(service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions, configuration: .init(model: "test/model"))
    let first = try await agent.run(task: "a", model: "test/model")
    let loaded = try sessions.load(id: first.sessionId)
    XCTAssertEqual(loaded.model, "test/model")

    let second = try await agent.run(task: "b", model: "other/model", resuming: loaded)
    XCTAssertEqual(second.sessionId, first.sessionId)
    XCTAssertEqual(mock.requests.last?.model, "other/model")
    XCTAssertEqual(second.record.model, "other/model")
    // The swap is a `model_change` line, so a later resume replays the new model.
    XCTAssertEqual(try sessions.load(id: first.sessionId).model, "other/model")
  }

  func testResumingOnTheTranscriptsModelWritesNoModelChange() async throws {
    // The common case (`arnes do --resume` without `-m`): the caller passes `loaded.model`
    // back, and the transcript gains the turn but no `model_change` line.
    let mock = plainRuns("one", "two")
    let sessions = tempSessionStore()
    let agent = Agent(service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions, configuration: .init(model: "test/model"))
    let first = try await agent.run(task: "a", model: "test/model")
    let before = try Data(contentsOf: sessions.directory.appendingPathComponent("\(first.sessionId).jsonl"))
    let loaded = try sessions.load(id: first.sessionId)
    _ = try await agent.run(task: "b", model: loaded.model, resuming: loaded)
    let after = try Data(contentsOf: sessions.directory.appendingPathComponent("\(first.sessionId).jsonl"))
    XCTAssertTrue(after.starts(with: before), "append-only: the earlier lines are untouched")
    XCTAssertFalse(String(decoding: after, as: UTF8.self).contains("model_change"))
  }

  func testResumedBudgetIsMeasuredAgainstTheTranscriptsCumulativeSpend() async throws {
    // What `arnes do --resume --budget` builds on: `Session(resuming:)` seeds `costUSD` with
    // the transcript's spend and `maxCostUSD` is compared against that figure at the top of
    // the step loop — so a ceiling at or below the spend stops before the first request
    // (steps 0, `budget`, a user turn appended with no reply). The CLI lifts the ceiling by the
    // transcript's spend (`Do.budgetCeiling`); with that offset the run goes ahead.
    let mock = plainRuns("one", "two")
    let sessions = tempSessionStore()
    let records = tempRecordStore()
    let first = try await Agent(service: mock, tools: [], store: records, sessionStore: sessions, configuration: .init(model: "test/model"))
      .run(task: "a", model: "test/model")
    let loaded = try sessions.load(id: first.sessionId)
    XCTAssertEqual(loaded.costUSD, 0.01, accuracy: 1e-9)

    let capped = Agent(
      service: mock, tools: [], store: records, sessionStore: sessions,
      configuration: .init(model: "test/model", maxCostUSD: 0.005))
    let stopped = try await capped.run(task: "b", model: loaded.model, resuming: loaded)
    XCTAssertEqual(stopped.stopReason, .budget)
    XCTAssertEqual(stopped.record.steps, 0)
    XCTAssertEqual(mock.requests.count, 1, "no request was issued")
    XCTAssertEqual(try sessions.load(id: first.sessionId).messages.count, 3, "the dangling user turn the CLI avoids")

    // The CLI's ceiling: the run's allowance on top of what the transcript already cost.
    let offset = Agent(
      service: mock, tools: [], store: records, sessionStore: sessions,
      configuration: .init(model: "test/model", maxCostUSD: 0.005 + loaded.costUSD))
    let ran = try await offset.run(task: "c", model: loaded.model, resuming: try sessions.load(id: first.sessionId))
    XCTAssertEqual(ran.stopReason, .completed)
    XCTAssertEqual(ran.text, "two")
    XCTAssertEqual(mock.requests.count, 2)
  }

  func testResumingFiresSessionStartWithResume() async throws {
    let marker = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-agentresume-hook-\(UUID().uuidString).txt")
    defer { try? FileManager.default.removeItem(at: marker) }
    let hook = HookDefinition(
      event: .sessionStart, matcher: "resume",
      command: "printf 'resumed-context' && printf '%s' \"$ARNES_HOOK_EVENT\" > '\(marker.path)'")
    let mock = plainRuns("one", "two")
    let sessions = tempSessionStore()
    let agent = Agent(
      service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions,
      configuration: .init(model: "test/model", hooks: [hook]))
    let first = try await agent.run(task: "a", model: "test/model")
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "a fresh run is `startup`, not `resume`")
    let loaded = try sessions.load(id: first.sessionId)
    _ = try await agent.run(task: "b", model: loaded.model, resuming: loaded)
    XCTAssertEqual(try? String(contentsOf: marker, encoding: .utf8), "SessionStart")
    // The hook's stdout is SessionStart context: it rides the system prompt of the resumed turn.
    let system = try XCTUnwrap(mock.requests.last?.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertTrue(system.contains("resumed-context"))
  }

  // MARK: Fork

  func testForkedRunLeavesTheOriginalIntactAndCarriesForkedFrom() async throws {
    let mock = plainRuns("original answer", "fork answer")
    let sessions = tempSessionStore()
    let agent = Agent(service: mock, tools: [], store: tempRecordStore(), sessionStore: sessions, configuration: .init(model: "test/model"))
    let original = try await agent.run(task: "start", model: "test/model")

    let forkId = try sessions.fork(id: original.sessionId, name: "branch")
    XCTAssertNotEqual(forkId, original.sessionId)
    let fork = try sessions.load(id: forkId)
    XCTAssertEqual(fork.meta.forkedFrom, original.sessionId)
    XCTAssertEqual(fork.meta.name, "branch")
    XCTAssertEqual(fork.messages.count, 2, "the fork starts as a copy")

    let result = try await agent.run(task: "continue here", model: fork.model, resuming: fork)
    XCTAssertEqual(result.sessionId, forkId, "the run's id is the fork's")
    XCTAssertEqual(result.text, "fork answer")
    // Both transcripts exist; only the fork grew.
    let ids = try sessions.list().map(\.id)
    XCTAssertEqual(Set(ids), [original.sessionId, forkId])
    XCTAssertEqual(try sessions.load(id: original.sessionId).messages.count, 2)
    let grown = try sessions.load(id: forkId)
    XCTAssertEqual(grown.messages.count, 4)
    XCTAssertEqual(grown.meta.forkedFrom, original.sessionId, "the meta line survives the appended turn")
    XCTAssertEqual(mock.requests.last?.messages.dropFirst().map { $0.content?.plainText ?? "" },
      ["start", "original answer", "continue here"])
  }

  func testLoadSurfacesTheWorkingDirectoryTheSessionStartedIn() throws {
    // `arnes do --resume` warns when the run's cwd differs from the transcript's; the store
    // exposes it from the first meta line, and an old transcript without one reads nil.
    let sessions = tempSessionStore()
    let id = UUID().uuidString
    try sessions.append(.meta(id: id, model: "test/model", cwd: "/work/project"), to: id)
    try sessions.append(TranscriptEntry(message: .user("hi")), to: id)
    XCTAssertEqual(try sessions.load(id: id).meta.cwd, "/work/project")
    let bare = UUID().uuidString
    try sessions.append(.meta(id: bare, model: "test/model", cwd: nil), to: bare)
    try sessions.append(TranscriptEntry(message: .user("hi")), to: bare)
    XCTAssertNil(try sessions.load(id: bare).meta.cwd)
  }

  // MARK: System suffix (--append-system-prompt)

  func testSystemSuffixLandsAfterInstructionsEnvironmentAndToolSections() async throws {
    let mock = plainRuns("ok")
    let skill = SkillTool(skills: [Skill(name: "demo", description: "a demo skill", body: "steps", directory: nil)])
    let agent = Agent(
      service: mock, tools: [skill], store: tempRecordStore(),
      configuration: .init(
        model: "test/model",
        systemSuffix: "# Role\n\nAnswer in haiku.\n\nAlways sign off with -- bot",
        projectInstructions: "# Project rules\nUse tabs.",
        extraSystemSections: ["# Environment\nWorking directory: /work"]))
    _ = try await agent.run(task: "hi", model: "test/model")
    let system = try XCTUnwrap(mock.requests.first?.messages.first { $0.role == .system }?.content?.plainText)
    let instructions = try XCTUnwrap(system.range(of: "Use tabs."))
    let environment = try XCTUnwrap(system.range(of: "Working directory: /work"))
    let skills = try XCTUnwrap(system.range(of: "# Skills"))
    let role = try XCTUnwrap(system.range(of: "# Role"))
    XCTAssertLessThan(instructions.lowerBound, environment.lowerBound)
    XCTAssertLessThan(environment.lowerBound, skills.lowerBound)
    XCTAssertLessThan(skills.lowerBound, role.lowerBound)
    XCTAssertTrue(system.hasSuffix("Always sign off with -- bot"), "the appendix is the last thing in the prompt")
  }

  // MARK: Lead as agent (--agent)

  func testLeadSuffixIsTheRoleNotTheSubagentFraming() {
    let agent = AgentDefinition(name: "reviewer", description: "Reviews diffs.", body: "You review diffs for correctness.")
    XCTAssertEqual(AgentLibrary.leadSystemSuffix(for: agent), "# Role\n\nYou review diffs for correctness.")
    let nested = TaskTool.systemSuffix(for: agent)
    XCTAssertTrue(nested.contains("You are 'reviewer'"), "the subagent framing is untouched")
    XCTAssertTrue(nested.contains("You review diffs for correctness."))
    XCTAssertFalse(nested.hasPrefix("# Role"))
    XCTAssertFalse(AgentLibrary.leadSystemSuffix(for: agent).contains("You are 'reviewer'"))
  }

  func testLeadToolsetIsFilteredByTheAgentsToolsAndDisallowedTools() {
    let agent = AgentDefinition(
      name: "reader", description: "", body: "Read.",
      tools: ["read_file", "grep", "bash"], disallowedTools: ["bash"])
    let run: [any AgentTool] = [SpyTool(name: "read_file", permission: .readOnly), SpyTool(name: "bash"), SpyTool(name: "grep", permission: .readOnly), SpyTool(name: "write_file")]
    XCTAssertEqual(AgentLibrary.toolset(for: agent, from: run).map(\.name), ["read_file", "grep"])
  }

  func testReadOnlyLeadAgentHasItsMutationsDenied() async throws {
    // The library half of a read-only lead: given the `DenyMutationsPermissions` delegate the
    // CLI selects for `permissionMode: readOnly` (that selection — and that `--yes` can't
    // undo it — is `Do.leadPosture`, tested in DoFlagsTests), the mutation never runs, the
    // model is told why, the run records the refusal, and the role rides the system prompt.
    let agent = AgentDefinition(name: "auditor", description: "", body: "Audit.", permissionMode: .readOnly)
    XCTAssertEqual(agent.permissionMode, .readOnly)
    let mock = mock([
      [Fixtures.toolCallChunk(id: "c1", name: "spy", arguments: "{}", index: 0), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("reported instead"), Fixtures.usageChunk(cost: 0.01)],
    ])
    let spy = SpyTool()
    let log = EventLog()
    let lead = Agent(
      service: mock, tools: [spy],
      permissions: DenyMutationsPermissions(reason: "agent 'auditor' is read-only (permissionMode) — report what you would change instead"),
      store: tempRecordStore(),
      configuration: .init(model: "test/model", systemSuffix: AgentLibrary.leadSystemSuffix(for: agent)))
    let result = try await lead.run(task: "change things", model: "test/model", onEvent: { log.note($0) })
    XCTAssertEqual(result.text, "reported instead")
    XCTAssertTrue(spy.executions.isEmpty, "the mutation never ran")
    XCTAssertEqual(result.denials.map(\.tool), ["spy"])
    XCTAssertTrue(result.denials.first?.reason?.contains("auditor") ?? false)
    XCTAssertTrue(log.all.contains { if case .toolDenied(name: "spy", _) = $0 { return true } else { return false } })
    let system = try XCTUnwrap(mock.requests.first?.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertTrue(system.hasSuffix("# Role\n\nAudit."))
  }

  func testAnAgentFileWhoseToolsListMapsToNothingWarns() throws {
    // `tools: Task` in a file used to mean "every tool" silently; it still does (a subagent
    // never gets `task`, so there is nothing else it can mean), but the definition now says so.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-agentresume-file-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("delegator.md")
    try "---\ndescription: only delegates\ntools: Task\ndisallowedTools: Read, Agent\n---\nDelegate.".write(to: file, atomically: true, encoding: .utf8)
    let agent = try XCTUnwrap(AgentLibrary.load(file: file))
    XCTAssertNil(agent.tools)
    XCTAssertEqual(agent.disallowedTools, ["read_file"], "a list with one real name is fine")
    XCTAssertEqual(agent.warnings.count, 1, "\(agent.warnings)")
    XCTAssertTrue(agent.warnings[0].contains("tools") && agent.warnings[0].contains("Task") && agent.warnings[0].contains("every tool"), agent.warnings[0])
  }

  func testInlineAgentsShadowDiscoveredOnesByName() {
    let inline = [AgentDefinition(name: "explore", description: "mine", body: "Mine.")]
    let merged = AgentLibrary.merge(inline: inline, discovered: AgentDefinition.builtins)
    XCTAssertEqual(merged.map(\.name), ["explore", "general", "fork"])
    XCTAssertEqual(merged.first?.body, "Mine.")
  }
}
