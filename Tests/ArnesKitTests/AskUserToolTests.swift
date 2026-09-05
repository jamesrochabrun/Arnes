import XCTest
@testable import ArnesKit
import OpenRouterSwift

// MARK: - Test doubles

/// Answers questions from a script and records what it was asked, in order with the events the
/// tool emitted (so a test can prove the `.userQuestion` event fires before the delegate hears).
final class ScriptedUserInput: UserInputDelegate, @unchecked Sendable {
  private let lock = NSLock()
  private var answers: [UserAnswer]
  private var log: [String] = []
  private var options: [String] = []

  init(_ answers: [UserAnswer]) {
    self.answers = answers
  }

  /// Everything that happened, in order: `event:…` notes from the tool's event, `asked:<question>`
  /// from the delegate.
  var timeline: [String] { lock.withLock { log } }
  /// The questions the delegate was actually asked.
  var asked: [String] {
    lock.withLock { log.filter { $0.hasPrefix("asked:") }.map { String($0.dropFirst(6)) } }
  }
  /// The options that came with the last question.
  var lastOptions: [String] { lock.withLock { options } }

  func note(_ entry: String) { lock.withLock { log.append(entry) } }

  func answer(question: String, options: [String]) async -> UserAnswer {
    lock.withLock {
      log.append("asked:\(question)")
      self.options = options
      return answers.isEmpty ? .unavailable(reason: "script exhausted") : answers.removeFirst()
    }
  }
}

private final class EventLog: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: [AgentEvent] = []
  func append(_ event: AgentEvent) { lock.withLock { stored.append(event) } }
  var events: [AgentEvent] { lock.withLock { stored } }
}

private actor OverlapProbe {
  private var inside = 0
  private(set) var maxOverlap = 0
  func enter() {
    inside += 1
    maxOverlap = Swift.max(maxOverlap, inside)
  }
  func leave() { inside -= 1 }
}

/// A delegate whose answers and decisions take a moment, so overlapping callers are observable.
/// With a `latch`, every call waits for `arrivals` callers — only concurrent ones get through,
/// which is how the control test proves the probe can see overlap at all.
private struct ProbingDelegate: PermissionDelegate, UserInputDelegate {
  let probe: OverlapProbe
  var latch: Latch?
  var arrivals = 0

  private func linger() async {
    await probe.enter()
    if let latch {
      await latch.arrive()
      await latch.wait(for: arrivals)
    } else {
      try? await Task.sleep(nanoseconds: 2_000_000)
    }
    await probe.leave()
  }

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await linger()
    return .allow
  }

  func answer(question: String, options: [String]) async -> UserAnswer {
    await linger()
    return .text("ok")
  }
}

// MARK: - AskUserToolTests

/// T6: the `ask_user` tool over the `UserInputDelegate` seam — a `.readOnly` question whose
/// answer is text; `NoUserInput` (every unattended runner) turns it into an `error:` result the
/// loop guard counts; the `.userQuestion` event fires before the delegate is asked; the tool is
/// stripped from every nested toolset; the REPL's prompt queue serializes it with permissions.
final class AskUserToolTests: XCTestCase {
  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-askuser-runs-\(UUID().uuidString).jsonl"))
  }

  private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-askuser-\(label)-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func manifest() -> String {
    Fixtures.manifest(
      Fixtures.manifestModel(id: "test/model"),
      Fixtures.manifestModel(id: "sub/model"),
      Fixtures.manifestModel(id: "leaf/model"))
  }
  private func toolNames(_ request: ChatCompletionRequest?) -> Set<String> {
    Set((request?.tools ?? []).map(\.function.name))
  }

  private func askCall(id: String, question: String = "Which one?", options: [String]? = ["a", "b"]) -> ChatCompletionChunk {
    var arguments: [String: JSONValue] = ["question": .string(question)]
    if let options { arguments["options"] = .array(options.map { .string($0) }) }
    let data = try! JSONEncoder().encode(JSONValue.object(arguments))
    return Fixtures.toolCallChunk(id: id, name: "ask_user", arguments: String(decoding: data, as: UTF8.self))
  }

  // MARK: The tool

  func testAnsweredQuestionReturnsTheUsersText() async throws {
    let input = ScriptedUserInput([.text("postgres")])
    let tool = AskUserTool(userInput: input)
    let result = try await tool.execute(arguments: [
      "question": .string("  Which database?  "), "options": .array([.string("sqlite"), .string("postgres")]),
    ])
    XCTAssertEqual(result, "user answered: postgres")
    XCTAssertEqual(input.asked, ["Which database?"], "trimmed before it is asked")
    XCTAssertEqual(input.lastOptions, ["sqlite", "postgres"])
    XCTAssertEqual(tool.permission, .readOnly, "an answer is text, never a grant — no prompt")
    XCTAssertEqual(tool.permission(for: ["question": .string("x")]), .readOnly)
    XCTAssertEqual(tool.name, "ask_user")
    XCTAssertFalse(tool is ConcurrentTool, "a question must never interleave with another prompt")
  }

  func testNoUserInputIsAnErrorResultThatTellsTheModelToAssume() async throws {
    let tool = AskUserTool(userInput: NoUserInput())
    let result = try await tool.execute(arguments: ["question": .string("Which one?")])
    XCTAssertEqual(
      result,
      "error: cannot ask the user (no user is present in this headless run). Pick the most reasonable "
        + "option, state the assumption explicitly in your final summary, and continue.")
    let custom = try await AskUserTool(userInput: NoUserInput(reason: "question limit reached"))
      .execute(arguments: ["question": .string("q")])
    XCTAssertTrue(custom.hasPrefix("error: cannot ask the user (question limit reached)."), custom)
  }

  func testEmptyOrOverlongQuestionIsRefusedBeforeAnyoneIsAsked() async throws {
    let input = ScriptedUserInput([.text("never")])
    let tool = AskUserTool(userInput: input)
    let expected = "error: ask_user needs a short non-empty question (≤ 500 chars)"
    let empty = try await tool.execute(arguments: ["question": .string("   \n")])
    XCTAssertEqual(empty, expected)
    let missing = try await tool.execute(arguments: [:])
    XCTAssertEqual(missing, expected)
    let long = try await tool.execute(arguments: ["question": .string(String(repeating: "q", count: 501))])
    XCTAssertEqual(long, expected)
    let atCap = try await tool.execute(arguments: ["question": .string(String(repeating: "q", count: 500))])
    XCTAssertEqual(atCap, "user answered: never")
    XCTAssertEqual(input.asked.count, 1, "only the valid question reached the delegate")
  }

  func testOptionsAreTrimmedDedupedCappedAtFiveAndNeverAnError() async throws {
    let input = ScriptedUserInput([.text("x"), .text("y"), .text("z")])
    let tool = AskUserTool(userInput: input)
    _ = try await tool.execute(arguments: [
      "question": .string("q"),
      "options": .array([
        .string(" one "), .string(""), .string("two"), .string("one"), .string("   "),
        .string("three"), .string("four"), .string("five"), .string("six"), .string("seven"),
      ]),
    ])
    XCTAssertEqual(input.lastOptions, ["one", "two", "three", "four", "five"])
    // A non-array or a non-string entry is ignored, not refused — the question still stands.
    _ = try await tool.execute(arguments: ["question": .string("q"), "options": .string("not a list")])
    XCTAssertEqual(input.lastOptions, [])
    _ = try await tool.execute(arguments: ["question": .string("q"), "options": .array([.int(1), .string("ok")])])
    XCTAssertEqual(input.lastOptions, ["ok"])
    // Each option is clipped, not dropped.
    let clipped = AskUserTool.cleanedOptions(.array([.string(String(repeating: "o", count: 150))]))
    XCTAssertEqual(clipped, [String(repeating: "o", count: 100)])
    XCTAssertEqual(tool.summary(arguments: ["question": .string("Which port should the server bind to by default?")]),
      "ask_user: Which port should the server bind to by default?")
  }

  func testTheQuestionEventFiresBeforeTheDelegateIsConsulted() async throws {
    let input = ScriptedUserInput([.text("a")])
    let tool = AskUserTool(userInput: input)
    tool.onEvent = { event in
      if case .userQuestion(let question, let options) = event {
        input.note("event:\(question):\(options.joined(separator: ","))")
      }
    }
    _ = try await tool.execute(arguments: ["question": .string("Pick"), "options": .array([.string("a"), .string(" b ")])])
    XCTAssertEqual(input.timeline, ["event:Pick:a,b", "asked:Pick"])
    // No event for a refused call — nothing was asked.
    _ = try await tool.execute(arguments: ["question": .string("")])
    XCTAssertEqual(input.timeline.count, 2)
  }

  // MARK: In a session

  func testQuestionRidesTheStreamBeforeItsResultAndTheAnswerReachesTheModel() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [
      [askCall(id: "q1", question: "Which database?", options: ["sqlite", "postgres"]), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("Using postgres."), Fixtures.usageChunk(cost: 0.001)],
    ]
    let input = ScriptedUserInput([.text("postgres")])
    // Ungated: the read-only posture refuses every gated call, and this one never asks the gate.
    let session = Session(
      service: mock, tools: [AskUserTool(userInput: input)], permissions: DenyMutationsPermissions(),
      store: store(), configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("set up the db"))

    let questionIndex = events.firstIndex { if case .userQuestion("Which database?", ["sqlite", "postgres"]) = $0 { return true } else { return false } }
    let resultIndex = events.firstIndex { if case .toolResult("ask_user", _) = $0 { return true } else { return false } }
    XCTAssertNotNil(questionIndex)
    XCTAssertNotNil(resultIndex)
    XCTAssertLessThan(questionIndex ?? 0, resultIndex ?? 0, "the question precedes its answer")
    XCTAssertFalse(events.contains { if case .toolDenied = $0 { return true } else { return false } }, "never gated")
    XCTAssertEqual(mock.requests.count, 2)
    let toolMessage = mock.requests[1].messages.last { $0.role == .tool }
    XCTAssertEqual(toolMessage?.toolCallId, "q1")
    XCTAssertEqual(toolMessage?.content?.plainText, "user answered: postgres")
    let record = await session.lastRecord
    XCTAssertEqual(record?.toolStats?["ask_user"], ToolStat(calls: 1, errors: 0))
    XCTAssertEqual(record?.decisions?.isEmpty ?? true, true, "a free call is not an audit row")
  }

  func testHeadlessAgentOverCoreToolsGetsTheNoUserAnswer() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [
      [askCall(id: "q1"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("Assuming a; done."), Fixtures.usageChunk(cost: 0.001)],
    ]
    let root = try tempDirectory("root")
    let agent = Agent(
      service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      permissions: DenyMutationsPermissions(), store: store(), configuration: .init(model: "test/model"))
    let log = EventLog()
    let result = try await agent.run(task: "do it", model: "test/model") { log.append($0) }

    XCTAssertEqual(result.text, "Assuming a; done.")
    XCTAssertEqual(result.stopReason, .completed)
    let toolMessage = mock.requests[1].messages.last { $0.role == .tool }?.content?.plainText ?? ""
    XCTAssertTrue(toolMessage.hasPrefix("error: cannot ask the user (no user is present in this headless run)."), toolMessage)
    XCTAssertEqual(result.record.toolStats?["ask_user"], ToolStat(calls: 1, errors: 1), "an error the loop guard counts")
    XCTAssertTrue(log.events.contains { if case .userQuestion("Which one?", ["a", "b"]) = $0 { return true } else { return false } })
    XCTAssertTrue(toolNames(mock.requests.first).contains("ask_user"), "the lead has the tool; headless just answers no")
  }

  func testSixUnansweredQuestionsInARowEndTheTurnStuck() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    var scripts = (1...8).map { index in
      [askCall(id: "q\(index)", question: "Question \(index)?", options: nil), Fixtures.usageChunk(cost: 0.001)]
    }
    scripts.append([Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001)])
    mock.chunkScripts = scripts
    let session = Session(
      service: mock, tools: [AskUserTool(userInput: NoUserInput())], store: store(),
      configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("ask away"))

    let stuck = events.compactMap { if case .stuckDetected(let reason) = $0 { return reason } else { return nil } }
    XCTAssertEqual(stuck, ["6 tool calls failed in a row"])
    XCTAssertEqual(mock.requests.count, 6, "the seventh question was never asked")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .stuck)
    XCTAssertEqual(record?.toolStats?["ask_user"], ToolStat(calls: 6, errors: 6))
  }

  // MARK: Stripped from every nested run

  func testSubagentsNeverGetTheTool() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [[Fixtures.textChunk("looked", model: "sub/model"), Fixtures.usageChunk(cost: 0.01, model: "sub/model")]]
    let root = try tempDirectory("root")
    let tool = TaskTool(
      agents: [.general], service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      store: store(), configuration: .init(model: "test/model", workingDirectory: root))
    tool.parentModel = { "sub/model" }
    _ = try await tool.execute(arguments: ["agent": .string("general"), "task": .string("look")])
    let names = toolNames(mock.requests.first)
    XCTAssertFalse(names.contains("ask_user"), "\(names)")
    XCTAssertTrue(names.contains("read_file") && names.contains("think"), "\(names)")
    XCTAssertTrue(
      (mock.requests.first?.messages.first { $0.role == .system }?.content?.plainText ?? "")
        .contains("you cannot ask questions"), "the role suffix still tells the truth")
  }

  func testIsolatedRunRebuildsItsToolsWithoutIt() async throws {
    let root = try tempDirectory("root")
    try "x".write(to: root.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    mock.chunkScripts = [[Fixtures.textChunk("nothing to do", model: "sub/model"), Fixtures.usageChunk(cost: 0.01, model: "sub/model")]]
    let isolated = AgentDefinition(
      name: "iso", description: "works in a copy", body: "Work in the copy.", model: "sub/model",
      isolation: "worktree")
    let tool = TaskTool(
      agents: [isolated], service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      store: store(), toolContext: ToolContext(root: root),
      configuration: .init(model: "test/model", workingDirectory: root))
    tool.parentSessionId = "LEAD-ASK-1111-2222"
    _ = try await tool.execute(arguments: ["agent": .string("iso"), "task": .string("look")])
    let names = toolNames(mock.requests.first)
    XCTAssertFalse(names.contains("ask_user"), "\(names)")
    XCTAssertTrue(names.contains("bash") && names.contains("think"), "\(names)")
  }

  func testGrandchildAtDepthTwoHasNoneEither() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = manifest()
    let helper = AgentDefinition(name: "helper", description: "helps", body: "Help.", model: "sub/model")
    let leaf = AgentDefinition(name: "leaf", description: "leafs", body: "Leaf.", model: "leaf/model")
    mock.chunkScriptsByModel = [
      "sub/model": [
        [Fixtures.toolCallChunk(id: "g1", name: "task", arguments: #"{"agent":"leaf","task":"do leaf"}"#, model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model")],
        [Fixtures.textChunk("helper done", model: "sub/model"), Fixtures.usageChunk(cost: 0.01, model: "sub/model")],
      ],
      "leaf/model": [[Fixtures.textChunk("leaf done", model: "leaf/model"), Fixtures.usageChunk(cost: 0.01, model: "leaf/model")]],
    ]
    let root = try tempDirectory("root")
    let tool = TaskTool(
      agents: [helper, leaf], service: mock, tools: HarnessAssembly.coreTools(ToolContext(root: root)),
      store: store(), defaults: TaskTool.Defaults(maxDepth: 2),
      configuration: .init(model: "test/model", workingDirectory: root))
    tool.parentModel = { "test/model" }
    _ = try await tool.execute(arguments: ["agent": .string("helper"), "task": .string("go")])
    let subRequest = try XCTUnwrap(mock.requests.first { $0.model == "sub/model" })
    let leafRequest = try XCTUnwrap(mock.requests.first { $0.model == "leaf/model" })
    XCTAssertFalse(toolNames(subRequest).contains("ask_user"))
    XCTAssertTrue(toolNames(subRequest).contains("task"))
    XCTAssertFalse(toolNames(leafRequest).contains("ask_user"))
  }

  func testALeadRunAsAnAgentKeepsIt() {
    let tools = HarnessAssembly.coreTools()
    let lead = AgentDefinition(name: "lead", description: "d", body: "b")
    XCTAssertTrue(AgentLibrary.toolset(for: lead, from: tools).map(\.name).contains("ask_user"))
    let narrowed = AgentDefinition(name: "n", description: "d", body: "b", tools: ["read_file", "ask_user"])
    XCTAssertEqual(AgentLibrary.toolset(for: narrowed, from: tools).map(\.name), ["read_file", "ask_user"])
    // Claude Code's spelling maps to ours in agent files and `--allowed-tools`.
    XCTAssertEqual(AgentLibrary.canonicalToolName("AskUserQuestion"), "ask_user")
  }

  func testToolFilterKnowsTheName() throws {
    let tools = HarnessAssembly.coreTools()
    let without = try ToolFilter.apply(tools, allowed: nil, disallowed: ["ask_user"]).map(\.name)
    XCTAssertFalse(without.contains("ask_user"))
    XCTAssertEqual(without.count, tools.count - 1)
    // Absent from a run is not unknown.
    XCTAssertEqual(try ToolFilter.apply([ThinkTool()], allowed: nil, disallowed: ["ask_user"]).map(\.name), ["think"])
    XCTAssertEqual(try ToolFilter.apply(tools, allowed: ["AskUserQuestion"], disallowed: []).map(\.name), ["ask_user"])
  }

  // MARK: One prompt queue

  func testSerializedPermissionsServesAnswersAndDecisionsOneAtATime() async throws {
    let probe = OverlapProbe()
    let delegate = ProbingDelegate(probe: probe)
    let serialized = SerializedPermissions(delegate, userInput: delegate)
    let finished = try await withDeadline(seconds: 10) { () -> Bool in
      await withTaskGroup(of: Void.self) { group in
        for index in 0..<6 {
          group.addTask { _ = await serialized.answer(question: "q\(index)", options: []) }
          group.addTask {
            _ = await serialized.decide(PermissionRequest(
              toolName: "bash", summary: "call \(index)", argumentsJSON: "{}", tier: .mutating))
          }
        }
      }
      return true
    }
    XCTAssertEqual(finished, true)
    let overlap = await probe.maxOverlap
    XCTAssertEqual(overlap, 1, "a question never opens while a y/n prompt is waiting, and vice versa")
    // Without a user-input delegate the wrapper answers as the headless default.
    let bare = SerializedPermissions(AutoApprovePermissions())
    let answer = await bare.answer(question: "q", options: [])
    XCTAssertEqual(answer, .unavailable(reason: NoUserInput().reason))
  }

  func testUnwrappedAnswerAndDecisionDoOverlap() async throws {
    // The control the assertion above needs: the bare delegate lets a question and a decision
    // overlap (each waits for the other's arrival), so the wrapper is what serializes them.
    let probe = OverlapProbe()
    let delegate = ProbingDelegate(probe: probe, latch: Latch(), arrivals: 2)
    let finished = try await withDeadline(seconds: 5) { () -> Bool in
      await withTaskGroup(of: Void.self) { group in
        group.addTask { _ = await delegate.answer(question: "q", options: []) }
        group.addTask { _ = await delegate.decide(toolName: "bash", summary: "s", argumentsJSON: "{}") }
      }
      return true
    }
    XCTAssertEqual(finished, true)
    let overlap = await probe.maxOverlap
    XCTAssertEqual(overlap, 2)
  }
}
