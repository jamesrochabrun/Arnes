import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// R3 — the CLI half of the chat-dialect reasoning shape: `arnes probe --dialect chat` runs
/// the floor and records nothing, and `arnes providers` says how each entry spells the dial.
final class ReasoningShapeCLITests: XCTestCase {
  func testProbeParsesChatAsAForcedDialect() throws {
    let command = try Probe.parse(["haiku", "--dialect", "chat", "--effort", "medium"])
    XCTAssertEqual(command.dialect, "chat")
    XCTAssertEqual(try parseEffort(command.effort), .medium)
    // The default is untouched: no dialect flag leaves the field nil, so a chat-preferring model
    // still gets the `prefers the chat dialect — nothing to probe` line.
    XCTAssertNil(try Probe.parse(["haiku"]).dialect)
    let help = Probe.helpMessage()
    XCTAssertTrue(help.contains("messages, responses or chat"), help)
    XCTAssertTrue(help.contains("records nothing"), help)
  }

  func testChatProbeLinesNameTheShapeAndRecordNothing() {
    XCTAssertEqual(Probe.chatFloorNote, "chat is the universal floor — nothing recorded")
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    XCTAssertEqual(Probe.chatReasoningNote(thinking: false, shape: .openai, record: record), "",
                   "without effort the line says nothing about the dial")
    XCTAssertEqual(Probe.chatReasoningNote(thinking: true, shape: .openai, record: record), " (dial sent as reasoning_effort)")
    XCTAssertEqual(Probe.chatReasoningNote(thinking: true, shape: .openrouter, record: record), " (dial sent as the reasoning object)")
    XCTAssertEqual(Probe.chatReasoningNote(thinking: true, shape: .none, record: record), " (dial not sent — reasoningShape none)")
    XCTAssertEqual(Probe.chatReasoningNote(thinking: true, shape: .openai, record: nil), " (dial sent as reasoning_effort)")
    // Only a provider that replays `reasoning_details` (OpenRouter) earns the replay note.
    record.reasoningReplayed = 1
    XCTAssertEqual(
      Probe.chatReasoningNote(thinking: true, shape: .openrouter, record: record),
      " (dial sent as the reasoning object, reasoning_details replayed)")
    // The native notes are untouched by the chat branch.
    XCTAssertEqual(Probe.reasoningNote(thinking: true, target: .messages, record: record), " (thinking replayed)")
    XCTAssertEqual(Probe.recordedLine(nil), "  recorded — auto dialect selection will use chat for this model")
  }

  func testProviderRowsCarryTheReasoningShape() throws {
    // A short token such as "k1" can occur in an ordinary temporary path. Check complete
    // fixture values while deliberately keeping that substring in the missing-file path.
    let credentials = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-shape-creds-k1-\(UUID().uuidString)")
    let gatewayKey = "fixture-gateway-credential-value"
    let localKey = "fixture-local-credential-value"
    let providers: [String: ProviderConfig] = [
      "openrouter": .openrouter,
      "gw": ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com/v1", apiKeyEnv: "GW_TOKEN", defaultModel: "sonnet"),
      "local": ProviderConfig(
        kind: .openaiCompatible, baseURL: "http://127.0.0.1:8080/v1", apiKeyEnv: "LOCAL_TOKEN", defaultModel: "m",
        reasoningShape: ReasoningShape.none),  // spelled out: a bare `.none` here is `Optional.none`
    ]
    let rows = Providers.rows(
      providers, active: "gw",
      environment: ["GW_TOKEN": gatewayKey, "LOCAL_TOKEN": localKey], credentialsURL: credentials)
    XCTAssertEqual(rows.map(\.name), ["gw", "local", "openrouter"])
    XCTAssertEqual(rows.map(\.reasoningShape), ["openai", "none", "openrouter"])
    XCTAssertEqual(rows[0].resolves, true)
    XCTAssertEqual(rows[2].resolves, false, "no openrouter key in this environment")
    XCTAssertEqual(rows[2].reasoningShape, "openrouter", "a row that doesn't resolve still says how it would speak")
    let line = try JSONOut.line(rows)
    XCTAssertTrue(line.contains(#""reasoning_shape":"openai""#), line)
    XCTAssertTrue(line.contains(#""reasoning_shape":"none""#), line)
    XCTAssertTrue(line.contains(#""reasoning_shape":"openrouter""#), line)
    XCTAssertFalse(line.contains(gatewayKey), "never a key")
    XCTAssertFalse(line.contains(localKey), "never a key")
    // The listing's tail appears only for an override of the kind's default.
    XCTAssertEqual(Providers.reasoningTag(providers["gw"]!), "")
    XCTAssertEqual(Providers.reasoningTag(providers["local"]!), " · reasoning none")
    XCTAssertEqual(
      Providers.reasoningTag(ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com/v1", reasoningShape: .openai)),
      "", "an override equal to the default is not an override")
    XCTAssertEqual(
      Providers.reasoningTag(ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com/v1", reasoningShape: .openrouter)),
      " · reasoning openrouter")
    XCTAssertEqual(Providers.reasoningShape(of: .openrouter), .openrouter)
    XCTAssertEqual(Providers.reasoningShape(of: providers["gw"]!), .openai)
  }
}
