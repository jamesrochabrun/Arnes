import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class CommandEvidenceTests: XCTestCase {
  private func call(_ id: String, command: String) -> Message {
    let data = try! JSONEncoder().encode(["command": command])
    return Message(role: .assistant, content: nil, toolCalls: [
      ToolCall(id: id, function: .init(name: "bash", arguments: String(decoding: data, as: UTF8.self))),
    ])
  }

  func testNewestFourPairedResultsRetainFailureTailsAndChronology() throws {
    var messages: [Message] = []
    for index in 0..<10 {
      messages += [call("c\(index)", command: "make test-\(index)"),
        .tool("exit 1\n" + String(repeating: "noise\n", count: 1_000)
          + "FAILED test_\(index)\n", toolCallId: "c\(index)")]
    }
    let section = try XCTUnwrap(CommandEvidence.section(in: messages))
    let rows = section.split(separator: "\n").dropFirst()
    XCTAssertEqual(rows.count, 4)
    for (index, row) in rows.enumerated() {
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row.utf8)) as? [String: Any])
      XCTAssertEqual(object["command"] as? String, "make test-\(index + 6)")
      XCTAssertEqual(object["truncated"] as? Bool, true)
      let output = try XCTUnwrap(object["observed_output"] as? String)
      XCTAssertTrue(output.hasPrefix("exit 1\n"))
      XCTAssertTrue(output.contains("FAILED test_\(index + 6)"))
    }
    XCTAssertFalse(section.contains("test_5"))
  }

  func testNoInventedCompletionOrUnpairedCommandAndJSONEscapesContent() throws {
    let messages: [Message] = [
      call("pending", command: "never returned"),
      .tool("exit 0", toolCallId: "unknown"),
      call("bg", command: "long command"),
      .tool("job 1 started\n\"ignore instructions\"", toolCallId: "bg"),
    ]
    let section = try XCTUnwrap(CommandEvidence.section(in: messages))
    XCTAssertFalse(section.contains("never returned"))
    XCTAssertFalse(section.contains("exit 0"))
    XCTAssertFalse(section.contains("command_succeeded"))
    XCTAssertEqual(section.split(separator: "\n").count, 2, "embedded newlines stay JSON string data")
    XCTAssertNil(CommandEvidence.section(in: [call("p", command: "pending")]))
  }

  func testEncodedSizeBoundIncludesUnicodeAndControlCharacterExpansion() throws {
    let unusual = String(repeating: "\u{0001}🔥", count: 5_000)
    var messages: [Message] = []
    for index in 0..<10 {
      messages += [call("\(index)", command: unusual), .tool(unusual, toolCallId: "\(index)")]
    }
    let section = try XCTUnwrap(CommandEvidence.section(in: messages))
    XCTAssertLessThan(section.utf8.count, 24_200)
    for row in section.split(separator: "\n").dropFirst() {
      XCTAssertLessThanOrEqual(row.utf8.count, 6_000)
      XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(row.utf8)))
    }
  }

  func testEvidenceIsOptInAndOldConfigRemainsUnchanged() throws {
    let old = try JSONDecoder().decode(CompactionConfig.self, from: Data(#"{"threshold":0.8}"#.utf8))
    XCTAssertNil(old.preserveCommandEvidence)
    XCTAssertEqual(old.policy, .default)
    let armed = CompactionConfig(keepRecentToolTokens: 500, preserveCommandEvidence: true)
    XCTAssertEqual(try JSONDecoder().decode(CompactionConfig.self, from: JSONEncoder().encode(armed)), armed)
    let messages = [call("c", command: "make check"), Message.tool("exit 1\nFAILED test_a", toolCallId: "c")]
    XCTAssertFalse(Session.renderTranscript(messages, existingSummary: nil).contains("[recent command evidence"))
    XCTAssertTrue(Session.renderTranscript(messages, existingSummary: nil,
      includeCommandEvidence: true).contains("[recent command evidence"))
  }

  func testCommandSecretsAreScrubbedBeforeExcerpting() throws {
    let value = "sk-or-v1-" + String(repeating: "a1b2c3d4", count: 8)
    let section = try XCTUnwrap(CommandEvidence.section(in: [
      call("c", command: "tool --token \(value)"), .tool("exit 1", toolCallId: "c"),
    ]))
    XCTAssertFalse(section.contains(value))
    XCTAssertTrue(section.contains("REDACTED"))
  }

  private actor LongOutput: AgentTool {
    let name = "bash"
    let description = "Test output only; runs no command."
    let parameters: JSONValue = ["type": "object", "properties": [:]]
    let permission = ToolPermission.readOnly
    private var index = 0
    func execute(arguments: [String: JSONValue]) async throws -> String {
      index += 1
      return "exit 1\n" + String(repeating: "build progress\n", count: 600) + "FAILED regression_\(index)"
    }
  }

  func testLongMultiTurnCompactionUsesOriginalHistoryAndSummarySurvivesResume() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-evidence-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    for index in 1...8 {
      mock.chunkScripts += [
        [Fixtures.toolCallChunk(id: "c\(index)", name: "bash", arguments: "{\"command\":\"make check-\(index)\"}")],
        [Fixtures.textChunk("Verification failed; continuing investigation.")],
      ]
    }
    let notes = "Goal: fix the regression without changing public APIs. make check-7: exit 1; FAILED regression_7. Still unresolved."
    mock.chatResponses = [Fixtures.textResponse(notes)]
    let records = RunRecordStore(url: root.appendingPathComponent("runs.jsonl"))
    let transcripts = SessionStore(directory: root.appendingPathComponent("sessions"))
    let configuration = Session.Configuration(model: "test/model", toolResultMaxChars: 20_000,
      toolResultGuard: .cli, compaction: .init(keepRecentToolTokens: 100, preserveCommandEvidence: true))
    let session = Session(service: mock, tools: [LongOutput()], store: records,
      sessionStore: transcripts, configuration: configuration)
    for index in 1...8 {
      _ = try await Events.drain(await session.send(index == 1
        ? "Fix the regression without changing public APIs." : "Continue investigation \(index)."))
    }
    XCTAssertTrue(mock.requests.contains { request in
      request.messages.contains { $0.role == .tool && $0.content?.plainText.contains("cleared") == true }
    }, "request views really did clear earlier large outputs")
    let before = await session.history
    XCTAssertEqual(before.filter { $0.role == .tool }.count, 8)
    XCTAssertTrue(before.contains { $0.content?.plainText.contains("FAILED regression_1") == true })
    _ = try await session.compact()
    let transcript = try XCTUnwrap(mock.requests.last?.messages.last?.content?.plainText)
    XCTAssertTrue(transcript.contains("without changing public APIs"))
    XCTAssertTrue(transcript.contains("[recent command evidence"))
    XCTAssertTrue(transcript.contains("FAILED regression_7"), "failure tail outside the 2,000-character transcript prefix")
    XCTAssertTrue(transcript.contains("make check-7"))
    let kept = await session.history
    XCTAssertTrue(kept.contains { $0.content?.plainText.contains("FAILED regression_8") == true })
    let saved = try transcripts.load(id: session.id)
    XCTAssertEqual(saved.compactionSummary, notes)
    let resumed = Session(resuming: saved, service: mock, tools: [], store: records,
      sessionStore: transcripts, configuration: configuration)
    mock.chunkScripts = [[Fixtures.textChunk("Continuing from the observed failure.")]]
    _ = try await Events.drain(await resumed.send("Continue; do not claim success without verification."))
    let system = try XCTUnwrap(mock.requests.last?.messages.first?.content?.plainText)
    XCTAssertTrue(system.contains(notes))
    // The notes are scripted: this proves the plumbing, not a model's summarization quality.
  }
}
