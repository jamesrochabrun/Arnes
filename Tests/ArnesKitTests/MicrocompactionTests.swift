import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// C2 — the context budget: the microcompacted request view (`Session.requestHistory()` over
/// `Microcompaction`), clear-before-summarize at turn start, mid-turn relief with its emergency
/// summary and thrash guard, the compaction rubric's `[files touched]`/`[current plan]` sections,
/// `/compact` steering, the config block and the record field.
final class MicrocompactionTests: XCTestCase {
  // MARK: - Helpers

  private func store() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-microcompaction-runs-\(UUID().uuidString).jsonl"))
  }

  private func sessionStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-microcompaction-sessions-\(UUID().uuidString)"))
  }

  /// A tool result of `chars` characters, distinct per call so a stub can't be mistaken for a copy.
  private static func big(_ tag: String, chars: Int = 3000) -> String {
    let line = "result \(tag): " + String(repeating: "x", count: 40) + "\n"
    var text = ""
    while text.count < chars { text += line }
    return text
  }
  /// A chat history: `pairs` tool exchanges (assistant call + result), each result `chars` wide
  /// unless `smallAt` names it, under one user message.
  private static func history(pairs: Int, chars: Int = 3000, smallAt: Set<Int> = [], tool: String = "probe") -> [Message] {
    var messages: [Message] = [.user("do the thing")]
    for index in 1...pairs {
      messages.append(Message(
        role: .assistant, content: nil,
        toolCalls: [ToolCall(id: "c\(index)", function: .init(name: tool, arguments: #"{"n":\#(index)}"#))]))
      messages.append(.tool(smallAt.contains(index) ? "small \(index)" : big("\(index)", chars: chars), toolCallId: "c\(index)"))
    }
    messages.append(.assistant("done"))
    return messages
  }

  /// The tool-role messages of a request, in order.
  private func toolMessages(_ request: ChatCompletionRequest) -> [Message] {
    request.messages.filter { $0.role == .tool }
  }

  /// Whether a recorded request is the compaction summarizer's (its system message is the rubric).
  private func isSummarizerRequest(_ request: ChatCompletionRequest) -> Bool {
    request.messages.first?.content?.plainText.hasPrefix("You compress an agent conversation") ?? false
  }

  private func isStub(_ message: Message) -> Bool {
    (message.content?.plainText ?? "").contains("[arnes: cleared ")
  }

  /// Every assistant tool call in `messages` is answered by a `.tool` message with its id, and
  /// every `.tool` message answers a call — the pairing a request must keep.
  private func assertPairingIntact(_ messages: [Message], file: StaticString = #filePath, line: UInt = #line) {
    var calls: Set<String> = []
    for message in messages where message.role == .assistant {
      for call in message.toolCalls ?? [] { calls.insert(call.id ?? "") }
    }
    let answers = Set(messages.filter { $0.role == .tool }.compactMap(\.toolCallId))
    XCTAssertEqual(calls, answers, "every tool call answered, every answer called", file: file, line: line)
  }

  // MARK: - Microcompaction (pure)

  func testClearingCutoffKeepsTheLastNToolResults() {
    let history = Self.history(pairs: 10)
    // Result k sits at index 2k (user at 0, then call/result pairs); the 6th most recent is result 5.
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history, keepingRecent: 6), 10)
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history, keepingRecent: 1), 20)
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history, keepingRecent: 10), 2)
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history, keepingRecent: 11), 0, "fewer results than kept: nothing eligible")
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history, keepingRecent: 0), history.count, "keep none: everything eligible")
    XCTAssertEqual(Microcompaction.clearingCutoff(in: [], keepingRecent: 6), 0)
  }

  func testViewStubsOlderLargeResultsKeepsSmallAndRecentOnesAndDropsNothing() {
    let history = Self.history(pairs: 10, smallAt: [2])
    let policy = CompactionPolicy(keepRecentToolResults: 6)
    let cutoff = Microcompaction.clearingCutoff(in: history, keepingRecent: policy.keepRecentToolResults)
    let view = Microcompaction.view(of: history, clearedBelow: cutoff, policy: policy)

    XCTAssertEqual(view.count, history.count, "no message is ever dropped")
    XCTAssertEqual(view.map(\.role), history.map(\.role))
    XCTAssertEqual(view.map(\.toolCallId), history.map(\.toolCallId))
    assertPairingIntact(view)
    let results = view.filter { $0.role == .tool }
    // Results 1, 3, 4 are old and large → stubbed; 2 is old but small → kept; 5…10 are recent → kept.
    XCTAssertTrue(isStub(results[0]))
    XCTAssertEqual(results[0].content?.plainText, "[arnes: cleared probe result (\(Self.big("1").count) chars) to free context — call the tool again if you need it]")
    XCTAssertEqual(results[1].content?.plainText, "small 2")
    XCTAssertTrue(isStub(results[2]))
    XCTAssertTrue(isStub(results[3]))
    for recent in results[4...] {
      XCTAssertFalse(isStub(recent), "the last six results stay verbatim")
    }
    // The persisted history is what it was: the view is a copy.
    XCTAssertFalse(history.filter { $0.role == .tool }.contains(where: isStub))

    let clearance = Microcompaction.clearance(of: history, below: cutoff, policy: policy)
    XCTAssertEqual(clearance.count, 3)
    // Results 1, 3, 4 are the stubs at positions 0, 2, 3: freed = original − stub, summed.
    let expectedFreed = zip([1, 3, 4], [0, 2, 3]).reduce(0) { sum, pair in
      sum + Self.big("\(pair.0)").count - (results[pair.1].content?.plainText.count ?? 0)
    }
    XCTAssertEqual(clearance.freedChars, expectedFreed)
    XCTAssertGreaterThan(clearance.freedChars, 8000)
  }

  func testViewBelowZeroOrWithNoCutoffIsTheHistoryItself() {
    let history = Self.history(pairs: 3)
    let policy = CompactionPolicy.default
    XCTAssertEqual(Microcompaction.view(of: history, clearedBelow: 0, policy: policy).map { $0.content?.plainText }, history.map { $0.content?.plainText })
    XCTAssertEqual(Microcompaction.view(of: history, clearedBelow: -4, policy: policy).map { $0.content?.plainText }, history.map { $0.content?.plainText })
    // A cutoff past the end is clamped, never a crash.
    let all = Microcompaction.view(of: history, clearedBelow: 99, policy: policy)
    XCTAssertEqual(all.filter { $0.role == .tool }.filter(isStub).count, 3)
  }

  func testAnErrorResultKeepsItsFirstLine() {
    let text = "error: build failed\n" + Self.big("log")
    let cleared = Microcompaction.clearedContent(text, tool: "bash", minChars: 2000)
    let lines = cleared!.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 2)
    XCTAssertEqual(lines[0], "error: build failed")
    XCTAssertTrue(lines[1].hasPrefix("[arnes: cleared the rest of this bash result ("), "\(lines[1])")
    XCTAssertTrue(lines[1].hasSuffix("chars) to free context — re-run the command if you need its output again]"), lines[1])
    // A one-line error under the size floor is left alone.
    XCTAssertNil(Microcompaction.clearedContent("error: no such file", tool: "bash", minChars: 2000))
  }

  func testAFramedResultKeepsItsFrameAroundTheStub() {
    let framed = ToolResultFrame.wrap(Self.big("f"), source: "read_file", nonce: "abcd1234")
    let cleared = Microcompaction.clearedContent(framed, tool: "read_file", minChars: 2000)
    let lines = cleared!.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.count, 3)
    XCTAssertEqual(lines[0], "<tool_result source=read_file nonce=abcd1234>")
    XCTAssertEqual(lines[1], "[arnes: cleared read_file result (\(Self.big("f").count) chars) to free context — call the tool again if you need it]")
    XCTAssertEqual(lines[2], "</tool_result nonce=abcd1234>")
    // A framed error keeps the error line inside the frame.
    let framedError = ToolResultFrame.wrap("error: nope\n" + Self.big("e"), source: "bash", nonce: "abcd1234")
    let clearedError = Microcompaction.clearedContent(framedError, tool: "bash", minChars: 2000)!
    XCTAssertTrue(clearedError.hasPrefix("<tool_result source=bash nonce=abcd1234>\nerror: nope\n[arnes: cleared the rest of this bash result ("))
    XCTAssertTrue(clearedError.hasSuffix("\n</tool_result nonce=abcd1234>"))
    // The size floor applies to the body, not the frame.
    XCTAssertNil(Microcompaction.clearedContent(ToolResultFrame.wrap("tiny", source: "bash", nonce: "abcd1234"), tool: "bash", minChars: 2000))
  }

  func testATaskResultStubCarriesNoRecallHint() {
    // A subagent's report cannot be had again by calling `task` again — that runs another subagent.
    XCTAssertEqual(
      Microcompaction.stub(tool: "task", chars: 4000),
      "[arnes: cleared task result (4000 chars) to free context]")
    XCTAssertEqual(
      Microcompaction.stubAfterFirstLine(tool: "task", chars: 4000),
      "[arnes: cleared the rest of this task result (4000 chars) to free context]")
    XCTAssertTrue(Microcompaction.stub(tool: "read_file", chars: 4000).hasSuffix("— call the tool again if you need it]"))
    XCTAssertTrue(Microcompaction.stub(tool: "mcp__github__search", chars: 4000).hasSuffix("— call the tool again if you need it]"))
    // The hint is what the tool allows: an answer, a write and a poll's tail cannot be had again;
    // an edit's post-edit window is the file (re-applying the edit would fail); a command is re-run.
    for tool in ["ask_user", "write_file", "job"] {
      XCTAssertEqual(Microcompaction.stub(tool: tool, chars: 4000), "[arnes: cleared \(tool) result (4000 chars) to free context]")
    }
    XCTAssertEqual(
      Microcompaction.stub(tool: "edit_file", chars: 4000),
      "[arnes: cleared edit_file result (4000 chars) to free context — read_file the file if you need to see it again]")
    XCTAssertEqual(
      Microcompaction.stubAfterFirstLine(tool: "bash", chars: 4000),
      "[arnes: cleared the rest of this bash result (4000 chars) to free context — re-run the command if you need its output again]")
    // Through the view: a delivered background report (a `bg-` task exchange) is stubbed like any
    // result, with the tool name read off its synthetic call.
    let history: [Message] = [
      .user("go"),
      Message(role: .assistant, content: .text("waiting"), toolCalls: [
        ToolCall(id: "bg-abc", function: .init(name: "task", arguments: #"{"agent":"explore","task":"(background result)"}"#)),
      ]),
      .tool("[background subagent 'explore' (abc) finished]\n\n" + Self.big("report"), toolCallId: "bg-abc"),
      Message(role: .assistant, content: nil, toolCalls: [ToolCall(id: "c1", function: .init(name: "probe", arguments: "{}"))]),
      .tool("small", toolCallId: "c1"),
    ]
    let view = Microcompaction.view(of: history, clearedBelow: 3, policy: CompactionPolicy(keepRecentToolResults: 1))
    XCTAssertEqual(view[2].content?.plainText, Microcompaction.stub(tool: "task", chars: history[2].content!.plainText.count))
    XCTAssertEqual(view[4].content?.plainText, "small")
  }

  func testCompactionPolicyClampsNonsense() {
    let policy = CompactionPolicy(threshold: 1.5, keepRecentToolResults: -3, clearMinChars: -1, maxPerTurn: -9, keepRecentImages: -2)
    XCTAssertEqual(policy.threshold, CompactionPolicy.defaultThreshold)
    XCTAssertEqual(policy.keepRecentToolResults, 0)
    XCTAssertEqual(policy.clearMinChars, 0)
    XCTAssertEqual(policy.maxPerTurn, 0)
    XCTAssertEqual(policy.keepRecentImages, 0)
    XCTAssertEqual(CompactionPolicy(threshold: 0).threshold, CompactionPolicy.defaultThreshold)
    XCTAssertEqual(CompactionPolicy(threshold: 0.5).threshold, 0.5)
    XCTAssertEqual(CompactionPolicy.default, CompactionPolicy(threshold: 0.8, keepRecentToolResults: 6, clearMinChars: 2000, maxPerTurn: 2, keepRecentImages: 1))
    // The config block: absent = 1, a value is clamped like the rest.
    let configured = try? JSONDecoder().decode(CompactionConfig.self, from: Data(#"{"keepRecentImages": 0}"#.utf8))
    XCTAssertEqual(configured?.policy.keepRecentImages, 0)
    let absent = try? JSONDecoder().decode(CompactionConfig.self, from: Data("{}".utf8))
    XCTAssertEqual(absent?.policy.keepRecentImages, 1)
  }

  // MARK: - Image retention

  /// A `view_image` attachment: the caption naming the file, then the picture.
  private static func attachment(_ path: String) -> Message {
    Message(role: .user, content: .parts([
      .text("Image from view_image \(path):"),
      .imageURL(url: DataURL.make(mediaType: "image/png", base64: "QUJD")),
    ]))
  }

  /// `view_image` exchanges (call, sentinel result, attachment) for `paths`, then `probes` plain
  /// tool exchanges, under one user message — the shape a screenshot leaves behind.
  private static func imageHistory(paths: [String], probes: Int) -> [Message] {
    var messages: [Message] = [.user("look at these")]
    var index = 0
    for path in paths {
      index += 1
      messages.append(Message(
        role: .assistant, content: nil,
        toolCalls: [ToolCall(id: "c\(index)", function: .init(name: "view_image", arguments: #"{"path":"\#(path)"}"#))]))
      messages.append(.tool("[image attached: \(path) (8x8, 1 KB)]", toolCallId: "c\(index)"))
      messages.append(attachment(path))
    }
    for _ in 0..<probes {
      index += 1
      messages.append(Message(
        role: .assistant, content: nil,
        toolCalls: [ToolCall(id: "c\(index)", function: .init(name: "probe", arguments: "{}"))]))
      messages.append(.tool("small", toolCallId: "c\(index)"))
    }
    messages.append(.assistant("done"))
    return messages
  }

  private func isImageStub(_ message: Message) -> Bool {
    (message.content?.plainText ?? "").contains("[arnes: the image was removed")
  }

  func testViewStubsOlderImagesBelowTheCutoffAndKeepsTheMostRecentOne() {
    // Three screenshots, then six plain tool steps: every attachment sits below the cutoff (the
    // sixth most recent tool result is the first probe's).
    let history = Self.imageHistory(paths: ["a.png", "b.png", "c.png"], probes: 6)
    let cutoff = Microcompaction.clearingCutoff(in: history, keepingRecent: 6)
    let attachments = history.indices.filter { Microcompaction.isImageAttachment(history[$0]) }
    XCTAssertEqual(attachments.count, 3)
    XCTAssertTrue(attachments.allSatisfy { $0 < cutoff }, "every attachment is below the cutoff")

    let view = Microcompaction.view(of: history, clearedBelow: cutoff, policy: CompactionPolicy())
    XCTAssertEqual(view.count, history.count, "no message is dropped")
    XCTAssertTrue(isImageStub(view[attachments[0]]), "the oldest is stubbed")
    XCTAssertTrue(isImageStub(view[attachments[1]]))
    XCTAssertFalse(isImageStub(view[attachments[2]]), "the most recent stays (keepRecentImages 1)")
    XCTAssertTrue(Microcompaction.isImageAttachment(view[attachments[2]]), "with its picture")
    // The stub is the same content kind as the attachment, carries the caption and the hint, and
    // no image bytes.
    guard case .parts(let parts)? = view[attachments[0]].content, parts.count == 1,
          case .text(let text, _) = parts[0]
    else { return XCTFail("a one-part text stub") }
    XCTAssertEqual(text, Microcompaction.imageStub(caption: "Image from view_image a.png:"))
    XCTAssertTrue(text.hasPrefix("Image from view_image a.png:\n[arnes: the image was removed"))
    XCTAssertTrue(text.contains("call view_image again"))
    XCTAssertFalse(text.contains("QUJD"))
    // Everything else — the sentinel results (small), the calls, the user message — is untouched.
    for index in history.indices where !attachments.contains(index) {
      XCTAssertEqual(view[index].content?.plainText, history[index].content?.plainText)
    }
    assertPairingIntact(view)

    // The dry run counts the pictures apart from the text results and frees no chars for them.
    let clearance = Microcompaction.clearance(of: history, below: cutoff, policy: CompactionPolicy())
    XCTAssertEqual(clearance.images, 2)
    XCTAssertEqual(clearance.count, 0, "the sentinel results are small")
    XCTAssertEqual(clearance.freedChars, 0)

    // keepRecentImages 0 stubs every old picture; 3 keeps them all.
    let none = Microcompaction.view(of: history, clearedBelow: cutoff, policy: CompactionPolicy(keepRecentImages: 0))
    XCTAssertTrue(attachments.allSatisfy { isImageStub(none[$0]) })
    let all = Microcompaction.view(of: history, clearedBelow: cutoff, policy: CompactionPolicy(keepRecentImages: 3))
    XCTAssertTrue(attachments.allSatisfy { !isImageStub(all[$0]) })
  }

  func testRecentImagesAndTextOnlyPartsAreLeftAlone() {
    // One screenshot after five probes: the attachment sits above the cutoff — recent, kept.
    var history = Self.imageHistory(paths: [], probes: 5)
    history.removeLast() // "done"
    history.append(Message(
      role: .assistant, content: nil,
      toolCalls: [ToolCall(id: "v", function: .init(name: "view_image", arguments: #"{"path":"z.png"}"#))]))
    history.append(.tool("[image attached: z.png (8x8, 1 KB)]", toolCallId: "v"))
    history.append(Self.attachment("z.png"))
    // A text-only `.parts` user message is not an attachment, wherever it sits.
    history.insert(Message(role: .user, content: .parts([.text("a"), .text("b")])), at: 1)
    history.append(.assistant("done"))
    let cutoff = Microcompaction.clearingCutoff(in: history, keepingRecent: 6)
    let view = Microcompaction.view(of: history, clearedBelow: cutoff, policy: CompactionPolicy(keepRecentImages: 0))
    XCTAssertEqual(view.filter(isImageStub).count, 0, "nothing below the cutoff was an image")
    XCTAssertTrue(view.contains(where: Microcompaction.isImageAttachment), "the recent picture rides the request")
    XCTAssertEqual(view[1].content?.plainText, history[1].content?.plainText)
    XCTAssertFalse(Microcompaction.isImageAttachment(history[1]))
    // The whole history below the cutoff: every old picture goes under keepRecentImages 0.
    let everything = Microcompaction.view(of: history, clearedBelow: history.count, policy: CompactionPolicy(keepRecentImages: 0))
    XCTAssertEqual(everything.filter(isImageStub).count, 1)
    XCTAssertEqual(Microcompaction.imageStub(caption: "  "), "[arnes: the image was removed from the request to free context — call view_image again if you need to see it]")
  }

  // MARK: - The request view in a session

  /// Ten tool steps in one turn, then a second turn: the second turn's requests carry the four
  /// oldest large results as stubs and the last six verbatim; the session's own history holds
  /// every result in full; no request within the first turn was stubbed (the cutoff moves at
  /// the turn boundary, not on every step); the pairing holds everywhere.
  func testRequestViewStubsOlderResultsWhilePersistedHistoryKeepsThem() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    var scripts: [[ChatCompletionChunk]] = []
    for index in 1...10 {
      scripts.append([
        Fixtures.toolCallChunk(id: "c\(index)", name: "probe", arguments: #"{"n":\#(index)}"#),
        Fixtures.usageChunk(cost: 0.001),
      ])
    }
    scripts.append([Fixtures.textChunk("turn one done"), Fixtures.usageChunk(cost: 0.001)])
    scripts.append([Fixtures.textChunk("turn two done"), Fixtures.usageChunk(cost: 0.001)])
    mock.chunkScripts = scripts
    let probe = ScriptedTool(name: "probe", results: (1...10).map { Self.big("\($0)") })
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model"))

    let first = try await Events.drain(await session.send("turn one"))
    XCTAssertFalse(first.contains { if case .toolResultsCleared = $0 { return true }; return false },
                   "nothing to clear in a fresh session")
    // Within the turn every request carried every result verbatim — the view is stable per turn.
    for request in mock.requests {
      XCTAssertFalse(toolMessages(request).contains(where: isStub), "no mid-turn stubbing below the threshold")
      assertPairingIntact(request.messages)
    }
    XCTAssertEqual(toolMessages(mock.requests.last!).count, 10)

    let second = try await Events.drain(await session.send("turn two"))
    let cleared = second.compactMap { event -> (Int, Int)? in
      if case .toolResultsCleared(let count, let freed) = event { return (count, freed) }
      return nil
    }
    XCTAssertEqual(cleared.count, 1)
    XCTAssertEqual(cleared.first?.0, 4)
    XCTAssertGreaterThan(cleared.first?.1 ?? 0, 4 * 2500)

    let request = mock.requests.last!
    let results = toolMessages(request)
    XCTAssertEqual(results.count, 10)
    XCTAssertEqual(results.prefix(4).filter(isStub).count, 4, "the four oldest are stubs")
    XCTAssertEqual(results[0].content?.plainText, Microcompaction.stub(tool: "probe", chars: Self.big("1").count))
    XCTAssertTrue(results.dropFirst(4).allSatisfy { !isStub($0) }, "the last six are verbatim")
    XCTAssertEqual(results.map(\.toolCallId), (1...10).map { "c\($0)" })
    assertPairingIntact(request.messages)

    // The persisted history is untouched — a resumed session gets the real results back.
    let history = await session.history
    XCTAssertEqual(history.filter { $0.role == .tool }.count, 10)
    XCTAssertFalse(history.contains(where: isStub))
    XCTAssertEqual(history.first { $0.role == .tool }?.content?.plainText, Self.big("1"))
    // The record counts what this turn cleared.
    let secondRecord = await session.lastRecord
    XCTAssertEqual(secondRecord?.toolResultsCleared, 4)
  }

  func testAClearedHistoryStartsWithNoStubs() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    var scripts: [[ChatCompletionChunk]] = []
    for index in 1...8 {
      scripts.append([
        Fixtures.toolCallChunk(id: "c\(index)", name: "probe", arguments: #"{"n":\#(index)}"#),
        Fixtures.usageChunk(cost: 0.001),
      ])
    }
    scripts.append([Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.001)])
    scripts.append([Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.001)])
    // After /clear: two tool steps and a finish.
    scripts.append([Fixtures.toolCallChunk(id: "d1", name: "probe", arguments: #"{"n":11}"#), Fixtures.usageChunk(cost: 0.001)])
    scripts.append([Fixtures.toolCallChunk(id: "d2", name: "probe", arguments: #"{"n":12}"#), Fixtures.usageChunk(cost: 0.001)])
    scripts.append([Fixtures.textChunk("three"), Fixtures.usageChunk(cost: 0.001)])
    mock.chunkScripts = scripts
    let probe = ScriptedTool(name: "probe", results: (1...10).map { Self.big("\($0)") })
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(keepRecentToolResults: 2)))
    _ = try await Events.drain(await session.send("turn one"))
    let second = try await Events.drain(await session.send("turn two"))
    XCTAssertTrue(second.contains { if case .toolResultsCleared(6, _) = $0 { return true }; return false })

    await session.clearHistory()
    let third = try await Events.drain(await session.send("turn three"))
    XCTAssertFalse(third.contains { if case .toolResultsCleared = $0 { return true }; return false },
                   "a stale cutoff never stubs a fresh history's results")
    for request in mock.requests.suffix(3) {
      XCTAssertFalse(toolMessages(request).contains(where: isStub))
    }
  }

  // MARK: - Turn start: clear before summarizing

  /// The clear-before-summarize scenario: a text-only turn zero — so the standard cut has a turn
  /// to summarize (without it `performCompaction` returns early at the first user message and
  /// the summarizer would never be asked whatever the decision, which is what the first cut of
  /// this test measured) —, then four large tool results in turn one whose last request says
  /// 90 % of a 100-token window, then turn two, whose start decides.
  private func turnStartScenario(policy: CompactionPolicy) async throws
    -> (events: [AgentEvent], mock: MockOpenRouterService, session: Session)
  {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    var scripts: [[ChatCompletionChunk]] = [
      [Fixtures.textChunk("zero"), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
    ]
    for index in 1...4 {
      scripts.append([
        Fixtures.toolCallChunk(id: "c\(index)", name: "probe", arguments: #"{"n":\#(index)}"#),
        Fixtures.usageChunk(cost: 0.001, promptTokens: 10),
      ])
    }
    scripts.append([Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.001, promptTokens: 90)]) // 90 % full
    scripts.append([Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.001, promptTokens: 30)])
    mock.chunkScripts = scripts
    mock.chatResponses = [Fixtures.textResponse("SUMMARY", cost: 0.5)]
    let probe = ScriptedTool(name: "probe", results: (1...4).map { Self.big("\($0)") })
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: policy))
    _ = try await Events.drain(await session.send("turn zero"))
    _ = try await Events.drain(await session.send("turn one"))
    let events = try await Events.drain(await session.send("turn two"))
    return (events, mock, session)
  }

  /// Keeping one result clears three (≈ 2 200 tokens at 4 chars each): 90 − 2 200 is under the
  /// 80 % line, so the summarizer is never asked — although the standard cut had turn zero to
  /// summarize and would have asked (the negative control below proves the request happens
  /// when clearing does not suffice).
  func testTurnStartClearsBeforeSummarizing() async throws {
    let (events, mock, session) = try await turnStartScenario(policy: CompactionPolicy(keepRecentToolResults: 1))

    XCTAssertFalse(events.contains { if case .compacted = $0 { return true }; return false }, "clearing sufficed")
    XCTAssertTrue(events.contains { if case .toolResultsCleared(3, _) = $0 { return true }; return false })
    XCTAssertEqual(mock.chatResponses.count, 1, "the summarizer was never asked")
    XCTAssertFalse(mock.requests.contains(where: isSummarizerRequest))
    let noSummary = await session.compactionSummary
    XCTAssertNil(noSummary)
    let request = mock.requests.last!
    XCTAssertEqual(toolMessages(request).filter(isStub).count, 3)
    XCTAssertEqual(toolMessages(request).count, 4)
    let persisted = await session.history
    XCTAssertEqual(persisted.filter { $0.role == .tool }.count, 4, "history still whole")
    XCTAssertEqual(persisted.first?.content?.plainText, "turn zero", "nothing was summarized away")
  }

  /// The negative control: the same turns keeping four results — nothing is old enough to clear,
  /// so the standard cut runs and turn zero becomes the note. The summarizer is told the request
  /// its notes serve is the one about to run (`turn two`, not yet in the history), not the
  /// previous turn's.
  func testTurnStartSummarizesWhenTheKeptResultsCoverEveryLargeOne() async throws {
    let (events, mock, session) = try await turnStartScenario(policy: CompactionPolicy(keepRecentToolResults: 4))

    XCTAssertFalse(events.contains { if case .toolResultsCleared = $0 { return true }; return false })
    XCTAssertTrue(events.contains { if case .compacted(2, _) = $0 { return true }; return false }, "turn zero summarized")
    XCTAssertEqual(mock.chatResponses.count, 0, "the summarizer was asked")
    let summary = await session.compactionSummary
    XCTAssertEqual(summary, "SUMMARY")
    let summarizer = mock.requests.first(where: isSummarizerRequest)!
    let transcript = summarizer.messages[1].content?.plainText ?? ""
    XCTAssertTrue(transcript.contains("[current user request — kept verbatim in the conversation, do not restate it]\nturn two"), transcript)
    XCTAssertFalse(transcript.contains("do not restate it]\nturn one"), "the previous turn's request is not the current one")
    XCTAssertTrue(transcript.contains("user: turn zero"), transcript)
    let persisted = await session.history
    XCTAssertEqual(persisted.first?.content?.plainText, "turn one", "the previous turn is the kept tail")
  }

  /// Nothing large to clear (small results) and 90 % full → the summarizer runs as before.
  func testTurnStartSummarizesWhenNothingCanBeCleared() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    mock.chunkScripts = [
      [Fixtures.textChunk("zero"), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.001, promptTokens: 90)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.001, promptTokens: 30)],
    ]
    mock.chatResponses = [Fixtures.textResponse("SMALL SUMMARY", cost: 0.001)]
    let probe = ScriptedTool(name: "probe", results: ["small a", "small b"])
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(keepRecentToolResults: 1)))
    // The standard cut keeps the whole previous turn: a turn before it is what gets summarized.
    _ = try await Events.drain(await session.send("turn zero"))
    _ = try await Events.drain(await session.send("turn one"))
    let events = try await Events.drain(await session.send("turn two"))
    XCTAssertTrue(events.contains { if case .compacted = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .toolResultsCleared = $0 { return true }; return false })
    let smallSummary = await session.compactionSummary
    XCTAssertEqual(smallSummary, "SMALL SUMMARY")
    XCTAssertEqual(mock.chatResponses.count, 0)
  }

  /// Large results cleared but not enough: 85 000 of 100 000 tokens with one 3 000-char result
  /// freed (~750 tokens) stays over the 80 % line → summarize.
  func testTurnStartSummarizesWhenClearingIsNotEnough() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100_000))
    mock.chunkScripts = [
      [Fixtures.textChunk("zero"), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.001, promptTokens: 85_000)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.001, promptTokens: 30)],
    ]
    mock.chatResponses = [Fixtures.textResponse("BIG SUMMARY", cost: 0.001)]
    let probe = ScriptedTool(name: "probe", results: [Self.big("1"), Self.big("2")])
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(keepRecentToolResults: 1)))
    _ = try await Events.drain(await session.send("turn zero"))
    _ = try await Events.drain(await session.send("turn one"))
    let events = try await Events.drain(await session.send("turn two"))
    XCTAssertTrue(events.contains { if case .toolResultsCleared(1, _) = $0 { return true }; return false })
    XCTAssertTrue(events.contains { if case .compacted = $0 { return true }; return false }, "clearing alone did not get under")
    let bigSummary = await session.compactionSummary
    XCTAssertEqual(bigSummary, "BIG SUMMARY")
  }

  // MARK: - Mid-turn relief

  /// Step 8's request reports 85 % of a 100-token window while the turn goes on: the results
  /// older than the last two are cleared from the next request on — once, at that boundary —
  /// while every earlier request of the turn carried them whole.
  func testMidTurnReliefClearsOlderResultsWhenAStepReportsAFullWindow() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    var scripts: [[ChatCompletionChunk]] = []
    for index in 1...8 {
      scripts.append([
        Fixtures.toolCallChunk(id: "c\(index)", name: "probe", arguments: #"{"n":\#(index)}"#),
        Fixtures.usageChunk(cost: 0.001, promptTokens: index == 8 ? 85 : 10),
      ])
    }
    scripts.append([Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001, promptTokens: 20)])
    mock.chunkScripts = scripts
    let probe = ScriptedTool(name: "probe", results: (1...8).map { Self.big("\($0)") })
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(keepRecentToolResults: 2)))
    let events = try await Events.drain(await session.send("go"))

    let cleared = events.compactMap { event -> Int? in
      if case .toolResultsCleared(let count, _) = event { return count }
      return nil
    }
    // At step 8's boundary the history holds results 1…7; keeping the last two clears 1…5.
    XCTAssertEqual(cleared, [5])
    XCTAssertFalse(events.contains { if case .compacted = $0 { return true }; return false })
    XCTAssertFalse(events.contains { if case .contextWarning = $0 { return true }; return false })
    // Requests 1…8 carried every result verbatim; request 9 (the finish) carries the stubs.
    let requests = mock.requests
    XCTAssertEqual(requests.count, 9)
    for request in requests.prefix(8) {
      XCTAssertFalse(toolMessages(request).contains(where: isStub))
    }
    let relieved = toolMessages(requests[8])
    XCTAssertEqual(relieved.count, 8)
    XCTAssertEqual(relieved.prefix(5).filter(isStub).count, 5)
    XCTAssertTrue(relieved.dropFirst(5).allSatisfy { !isStub($0) })
    assertPairingIntact(requests[8].messages)
    let reliefRecord = await session.lastRecord
    XCTAssertEqual(reliefRecord?.toolResultsCleared, 5)
    let reliefHistory = await session.history
    XCTAssertEqual(reliefHistory.filter { $0.role == .tool }.filter(isStub).count, 0)
  }

  /// Nothing older is clearable and a step reports 96 %: everything but the turn's opening
  /// message is summarized into the note (once — `maxPerTurn: 1`); the next full step past the
  /// cap gets one `contextWarning`, and the one after that nothing new. The pairing holds in
  /// every request, and the transcript replays the same history.
  func testEmergencySummaryThenThrashGuard() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.toolCallChunk(id: "c3", name: "probe", arguments: #"{"n":3}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.toolCallChunk(id: "c4", name: "probe", arguments: #"{"n":4}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001, promptTokens: 20)],
    ]
    mock.chatResponses = [Fixtures.textResponse("EMERGENCY NOTES", cost: 0.002)]
    let probe = ScriptedTool(name: "probe", results: ["small 1", "small 2", "small 3", "small 4"])
    let transcripts = sessionStore()
    let session = Session(
      service: mock, tools: [probe], store: store(), sessionStore: transcripts,
      configuration: .init(model: "test/model", compaction: CompactionPolicy(maxPerTurn: 1)))
    let events = try await Events.drain(await session.send("do the task"))

    let compactions = events.filter { if case .compacted = $0 { return true }; return false }
    XCTAssertEqual(compactions.count, 1)
    if case .compacted(let summarized, let kept) = compactions.first! {
      // At step 2's boundary the history was [user, assistant(c1), tool(c1)]: two dropped, the user kept.
      XCTAssertEqual(summarized, 2)
      XCTAssertEqual(kept, 1)
    }
    let warnings = events.compactMap { event -> String? in
      if case .contextWarning(let message) = event { return message }
      return nil
    }
    XCTAssertEqual(warnings.count, 1, "said once per turn")
    XCTAssertTrue(warnings[0].contains("96%"), warnings[0])
    XCTAssertTrue(warnings[0].contains("1 emergency summary already taken"), warnings[0])
    XCTAssertFalse(events.contains { if case .toolResultsCleared = $0 { return true }; return false }, "nothing was clearable")
    let emergencySummary = await session.compactionSummary
    XCTAssertEqual(emergencySummary, "EMERGENCY NOTES")

    // The summarizer saw the dropped exchange and the kept request; the step after ran over
    // system(note) + [user, assistant(c2), tool(c2)].
    let summarizerRequest = mock.requests.first(where: isSummarizerRequest)!
    let transcript = summarizerRequest.messages[1].content?.plainText ?? ""
    XCTAssertTrue(transcript.contains("[current user request — kept verbatim in the conversation, do not restate it]\ndo the task"), transcript)
    XCTAssertTrue(transcript.contains(#"probe({"n":1})"#), transcript)
    XCTAssertTrue(transcript.contains("tool: small 1"), transcript)
    let stepRequests = mock.requests.filter { !isSummarizerRequest($0) }
    XCTAssertEqual(stepRequests.count, 5)
    let afterEmergency = stepRequests[2]
    XCTAssertTrue(afterEmergency.messages[0].content?.plainText.contains("EMERGENCY NOTES") == true)
    XCTAssertEqual(afterEmergency.messages.dropFirst().map(\.role), [.user, .assistant, .tool])
    XCTAssertEqual(afterEmergency.messages[1].content?.plainText, "do the task")
    XCTAssertEqual(afterEmergency.messages[3].toolCallId, "c2")
    for request in stepRequests { assertPairingIntact(request.messages) }

    // Live history and the replayed transcript agree: the note, then user + the exchanges after the cut.
    let history = await session.history
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool, .assistant, .tool, .assistant, .tool, .assistant])
    XCTAssertEqual(history[0].content?.plainText, "do the task")
    let loaded = try transcripts.load(id: session.id)
    XCTAssertEqual(loaded.compactionSummary, "EMERGENCY NOTES")
    XCTAssertEqual(loaded.messages.map(\.role), history.map(\.role))
    XCTAssertEqual(loaded.messages.compactMap(\.toolCallId), ["c2", "c3", "c4"])
    XCTAssertEqual(loaded.turnStarts.map(\.index), [0])
  }

  /// A finishing step (no tool calls) at 96 % asks for nothing: the turn ends, the next turn
  /// start decides. `maxPerTurn: 0` takes no emergency summary either — the warning stands in.
  func testAFinishingStepAndAZeroCapNeverSummarizeMidTurn() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001, promptTokens: 97)],
    ]
    mock.chatResponses = [Fixtures.textResponse("NEVER", cost: 0.5)]
    let probe = ScriptedTool(name: "probe", results: ["small 1", "small 2"])
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(maxPerTurn: 0)))
    let events = try await Events.drain(await session.send("go"))
    XCTAssertFalse(events.contains { if case .compacted = $0 { return true }; return false })
    let warnings = events.compactMap { event -> String? in
      if case .contextWarning(let message) = event { return message }
      return nil
    }
    XCTAssertEqual(warnings.count, 1)
    XCTAssertTrue(warnings[0].contains("no emergency summary allowed this turn (compaction.maxPerTurn 0)"), warnings[0])
    XCTAssertEqual(mock.chatResponses.count, 1, "no summarizer request")
    let finishedRecord = await session.lastRecord
    XCTAssertEqual(finishedRecord?.stopReason, .completed)
  }

  /// Clearing one result at 96 % of a 100 000-token window frees ~700 tokens — not enough by the
  /// estimate, so the emergency summary is taken at the same boundary: the gate is the estimated
  /// usage after clearing, not "nothing was cleared" (a turn adding one large result per step
  /// clears exactly one result per step and would otherwise never qualify while the kept results
  /// alone fill the window). The summarizer's spend lands on the turn's record and stats.
  func testEmergencySummaryWhenClearingIsNotEnoughMidTurn() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100_000))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c3", name: "probe", arguments: #"{"n":3}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96_000)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001, promptTokens: 20)],
    ]
    mock.chatResponses = [Fixtures.textResponse("EMERGENCY NOTES", cost: 0.002)]
    let probe = ScriptedTool(name: "probe", results: (1...3).map { Self.big("\($0)") })
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(keepRecentToolResults: 1)))
    let events = try await Events.drain(await session.send("go"))

    // At step 3's boundary the history is [user, assistant(c1), tool, assistant(c2), tool]:
    // keeping one result clears the first, then everything but the user message is summarized.
    XCTAssertTrue(events.contains { if case .toolResultsCleared(1, _) = $0 { return true }; return false })
    let compactions = events.filter { if case .compacted = $0 { return true }; return false }
    XCTAssertEqual(compactions.count, 1)
    if case .compacted(let summarized, let kept) = compactions.first! {
      XCTAssertEqual(summarized, 4)
      XCTAssertEqual(kept, 1)
    }
    XCTAssertFalse(events.contains { if case .contextWarning = $0 { return true }; return false })
    XCTAssertEqual(mock.chatResponses.count, 0, "the summarizer was asked once")
    // The summarizer's $0.002 is on the turn's books beside the four steps' $0.001 each, and
    // once on the session's.
    let record = await session.lastRecord
    XCTAssertEqual(record?.costUSD ?? 0, 0.006, accuracy: 1e-9)
    let stats = events.compactMap { event -> Session.TurnStats? in
      if case .turnFinished(let stats) = event { return stats }
      return nil
    }
    XCTAssertEqual(stats.count, 1)
    XCTAssertEqual(stats[0].turnCostUSD, 0.006, accuracy: 1e-9)
    XCTAssertEqual(stats[0].sessionCostUSD, 0.006, accuracy: 1e-9)
    let sessionCost = await session.costUSD
    XCTAssertEqual(sessionCost, 0.006, accuracy: 1e-9)
    // The kept tail is the opening message; the rest of the turn ran on after the note.
    let history = await session.history
    XCTAssertEqual(history.map(\.role), [.user, .assistant, .tool, .assistant])
    XCTAssertEqual(history.compactMap(\.toolCallId), ["c3"])
    let note = await session.compactionSummary
    XCTAssertEqual(note, "EMERGENCY NOTES")
    for request in mock.requests where !isSummarizerRequest(request) { assertPairingIntact(request.messages) }
  }

  /// A summarizer that returns nothing: the attempt is said (a `contextWarning` naming the
  /// failure) and still counts against the cap — the next full step past it gets the cap warning,
  /// not another paid attempt — and the failure leaves the history untouched.
  func testAFailedEmergencySummaryIsSaidAndCountsAgainstTheCap() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 10)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.toolCallChunk(id: "c3", name: "probe", arguments: #"{"n":3}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.toolCallChunk(id: "c4", name: "probe", arguments: #"{"n":4}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 96)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.001, promptTokens: 20)],
    ]
    mock.chatResponses = [Fixtures.textResponse("", cost: 0)] // an empty summary: `compactionFailed`
    let probe = ScriptedTool(name: "probe", results: ["small 1", "small 2", "small 3", "small 4"])
    let session = Session(
      service: mock, tools: [probe], store: store(),
      configuration: .init(model: "test/model", compaction: CompactionPolicy(maxPerTurn: 1)))
    let events = try await Events.drain(await session.send("do the task"))

    XCTAssertFalse(events.contains { if case .compacted = $0 { return true }; return false })
    let warnings = events.compactMap { event -> String? in
      if case .contextWarning(let message) = event { return message }
      return nil
    }
    XCTAssertEqual(warnings, [
      "emergency summary 1 of 1 failed (the summarizer returned no usable summary) — the turn continues, but the next request may not fit the model's context",
      "context at 96% of the window with nothing left to clear and 1 emergency summary already taken this turn — the turn continues, but the next request may not fit the model's context",
    ])
    XCTAssertEqual(mock.requests.filter(isSummarizerRequest).count, 1, "asked once, not on every step past the cap")
    let summary = await session.compactionSummary
    XCTAssertNil(summary)
    let history = await session.history
    XCTAssertEqual(history.filter { $0.role == .tool }.count, 4, "nothing was dropped by the failed attempt")
    XCTAssertEqual(history.first?.content?.plainText, "do the task")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
  }

  /// A manifest that says the window is 0 wide (a degenerate gateway row) asks for nothing — no
  /// summary, no warning, no division by it — at turn start and mid-turn alike.
  func testAZeroContextLengthNeverTriggersRelief() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 0))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "probe", arguments: #"{"n":1}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 50)],
      [Fixtures.toolCallChunk(id: "c2", name: "probe", arguments: #"{"n":2}"#), Fixtures.usageChunk(cost: 0.001, promptTokens: 50)],
      [Fixtures.textChunk("one"), Fixtures.usageChunk(cost: 0.001, promptTokens: 50)],
      [Fixtures.textChunk("two"), Fixtures.usageChunk(cost: 0.001, promptTokens: 50)],
    ]
    mock.chatResponses = [Fixtures.textResponse("NEVER", cost: 0.5)]
    let probe = ScriptedTool(name: "probe", results: [Self.big("1"), Self.big("2")])
    let session = Session(service: mock, tools: [probe], store: store(), configuration: .init(model: "test/model"))
    let first = try await Events.drain(await session.send("go"))
    let second = try await Events.drain(await session.send("again"))
    for events in [first, second] {
      XCTAssertFalse(events.contains { if case .compacted = $0 { return true }; return false })
      XCTAssertFalse(events.contains { if case .contextWarning = $0 { return true }; return false })
    }
    XCTAssertEqual(mock.chatResponses.count, 1, "no summarizer request")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
  }

  // MARK: - The rubric

  /// A manual compaction's summarizer is handed the files the dropped turns touched and the last
  /// plan checklist, verbatim, beside the transcript and the fixed rubric sentence.
  func testCompactionTranscriptCarriesTouchedPathsAndThePlan() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let plan = #"{"plan":[{"step":"read the code","status":"completed"},{"step":"fix the bug","status":"in_progress"},{"step":"run the tests","status":"pending"}]}"#
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "read_file", arguments: #"{"path":"src/a.swift"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c2", name: "edit_file", arguments: #"{"path":"src/a.swift","old":"x","new":"y"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c3", name: "write_file", arguments: #"{"path":"docs/notes.md","content":"n"}"#), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.toolCallChunk(id: "c4", name: "update_plan", arguments: plan), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("turn one done"), Fixtures.usageChunk(cost: 0.001)],
      [Fixtures.textChunk("turn two done"), Fixtures.usageChunk(cost: 0.001)],
    ]
    mock.chatResponses = [Fixtures.textResponse("NOTES", cost: 0.001)]
    let tools: [any AgentTool] = [
      ScriptedTool(name: "read_file", results: ["contents"]),
      ScriptedTool(name: "edit_file", results: ["edited"]),
      ScriptedTool(name: "write_file", results: ["created"]),
      ScriptedTool(name: "update_plan", results: ["ok"]),
    ]
    let session = Session(
      service: mock, tools: tools, store: store(),
      configuration: .init(model: "test/model", compactionInstructions: "Keep every failing test's name."))
    _ = try await Events.drain(await session.send("fix the bug in a.swift"))
    _ = try await Events.drain(await session.send("now the docs"))
    let planBefore = await session.lastPlanSteps
    XCTAssertNotNil(planBefore)

    let result = try await session.compact(instructions: "Mention the branch name.")
    XCTAssertEqual(result.summarizedMessages, 10)
    let request = mock.requests.last(where: isSummarizerRequest)!
    let rubric = request.messages[0].content?.plainText ?? ""
    XCTAssertTrue(rubric.contains("Preserve verbatim: the paths of files modified, the commands that verify the work, unresolved errors and what was tried, and the current plan checklist"), rubric)
    XCTAssertTrue(rubric.contains("Additional instructions from the project's instruction files:\nKeep every failing test's name."), rubric)
    XCTAssertTrue(rubric.contains("Additional instructions from the user for this summary:\nMention the branch name."), rubric)
    let transcript = request.messages[1].content?.plainText ?? ""
    XCTAssertTrue(transcript.contains("[files touched]\n- src/a.swift — read, edited\n- docs/notes.md — written"), transcript)
    XCTAssertTrue(transcript.contains("[current plan]\n[x] read the code\n[~] fix the bug\n[ ] run the tests"), transcript)
    XCTAssertTrue(transcript.contains("[current user request — kept verbatim in the conversation, do not restate it]\nnow the docs"), transcript)
    // The plan call went with the dropped turn; the note is what carries it now.
    let planAfter = await session.lastPlanSteps
    XCTAssertNil(planAfter)
    let notes = await session.compactionSummary
    XCTAssertEqual(notes, "NOTES")
  }

  func testRubricSectionsAreNilWithoutPathToolsOrAPlan() {
    let plain: [Message] = [.user("hi"), .assistant("hello")]
    XCTAssertNil(CompactionRubric.touchedPathsSection(in: plain))
    XCTAssertNil(CompactionRubric.planSection(in: plain))
    let rendered = Session.renderTranscript(plain, existingSummary: nil)
    XCTAssertEqual(rendered, "user: hi\n\nassistant: hello")
    // A malformed plan (no steps) contributes nothing; a bash call is not a touched path.
    let odd: [Message] = [
      Message(role: .assistant, content: nil, toolCalls: [
        ToolCall(id: "a", function: .init(name: "update_plan", arguments: #"{"plan":[]}"#)),
        ToolCall(id: "b", function: .init(name: "bash", arguments: #"{"command":"ls","path":"x"}"#)),
      ]),
    ]
    XCTAssertNil(CompactionRubric.planSection(in: odd))
    XCTAssertNil(CompactionRubric.touchedPathsSection(in: odd))
  }

  // MARK: - Config and record

  func testCompactionConfigDecodesAndFillsDefaults() throws {
    let json = #"{"compaction": {"threshold": 0.7, "keepRecentToolResults": 3}}"#
    let config = try JSONDecoder().decode(ArnesConfig.self, from: Data(json.utf8))
    let policy = try XCTUnwrap(config.compaction).policy
    XCTAssertEqual(policy.threshold, 0.7)
    XCTAssertEqual(policy.keepRecentToolResults, 3)
    XCTAssertEqual(policy.clearMinChars, 2000)
    XCTAssertEqual(policy.maxPerTurn, 2)
    // Absent block: nil, and the defaults apply.
    let absent = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"provider":"openrouter"}"#.utf8))
    XCTAssertNil(absent.compaction)
    XCTAssertEqual(CompactionConfig().policy, .default)
    XCTAssertEqual(CompactionConfig(threshold: 7).policy.threshold, CompactionPolicy.defaultThreshold, "nonsense clamps to the default")
  }

  func testConfigurationCarriesCompactionToSubagents() {
    let policy = CompactionPolicy(threshold: 0.6, keepRecentToolResults: 2, clearMinChars: 100, maxPerTurn: 1)
    let lead = Session.Configuration(model: "m", compaction: policy, compactionInstructions: "keep the ids")
    let nested = lead.forSubagent(named: "explore", model: "n", systemSuffix: "role")
    XCTAssertEqual(nested.compaction, policy)
    XCTAssertEqual(nested.compactionInstructions, "keep the ids")
    let readOnly = lead.forSubagent(named: "explore", model: "n", systemSuffix: "role", inheritsProjectInstructions: false)
    XCTAssertNil(readOnly.compactionInstructions, "goes with the project instructions it doesn't inherit")
    XCTAssertEqual(Session.Configuration().compaction, .default)
    XCTAssertNil(Session.Configuration().compactionInstructions)
  }

  func testOldRunRecordRowDecodesWithoutToolResultsCleared() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let legacy = """
      {"id":"r1","startedAt":"2025-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat",\
      "packFamily":"generic","steps":1,"toolCalls":0,"costUSD":0,"finished":true}
      """
    let old = try decoder.decode(RunRecord.self, from: Data(legacy.utf8))
    XCTAssertNil(old.toolResultsCleared)
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.toolResultsCleared = 4
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(record)
    XCTAssertEqual(try decoder.decode(RunRecord.self, from: data).toolResultsCleared, 4)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""toolResultsCleared":4"#))
    // A row that cleared nothing writes no key.
    let quiet = try encoder.encode(RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic"))
    XCTAssertFalse(String(decoding: quiet, as: UTF8.self).contains("toolResultsCleared"))
  }
}
