import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// Q1 (batch 14) — a panel candidate carries the run's reasoning dial: `do --panel N --effort
/// <level>` reaches every candidate's session, so the T5 think-omission gate (`adaptiveThink`)
/// is live in a panel; the judge's structured side request stays dial-less; and a runner built
/// without the dial sends exactly the requests it always did.
final class PanelDialTests: XCTestCase {
  private func tempDir(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-panel-dial-\(label)-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func tempStores() -> (EvalStore, RunRecordStore) {
    let base = FileManager.default.temporaryDirectory
    return (
      EvalStore(url: base.appendingPathComponent("arnes-panel-dial-evals-\(UUID().uuidString).jsonl")),
      RunRecordStore(url: base.appendingPathComponent("arnes-panel-dial-runs-\(UUID().uuidString).jsonl")))
  }

  /// Two candidates on thinking models (manifest: `tools` + `reasoning`), each writing a file
  /// then finishing; a judge that names attempt 2. Scripts are keyed by model — candidates run
  /// concurrently.
  private func reasoningPanelMock() -> MockOpenRouterService {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.reasoningManifestModel(id: "test/alpha"),
      Fixtures.reasoningManifestModel(id: "test/beta"),
      Fixtures.manifestModel(id: "test/judge"))
    func script(_ label: String, cost: Double) -> [[ChatCompletionChunk]] {
      [
        [
          Fixtures.toolCallChunk(
            id: "\(label)1", name: "write_file",
            arguments: #"{"path": "answer.txt", "content": "\#(label) attempt"}"#),
          Fixtures.usageChunk(cost: cost),
        ],
        [Fixtures.textChunk("\(label) done"), Fixtures.usageChunk(cost: cost)],
      ]
    }
    mock.chunkScriptsByModel = ["test/alpha": script("alpha", cost: 0.01), "test/beta": script("beta", cost: 0.02)]
    mock.chatResponses = [
      Fixtures.textResponse(#"{"winner": 2, "reasons": ["beta's change matches the task."]}"#, cost: 0.001),
    ]
    return mock
  }

  private func toolNames(_ request: ChatCompletionRequest) -> [String] {
    request.tools?.map(\.function.name) ?? []
  }

  private func candidateRequests(_ mock: MockOpenRouterService, model: String) -> [ChatCompletionRequest] {
    mock.requests.filter { $0.model == model }
  }

  func testCandidatesCarryTheDialAndDropThinkWhileTheJudgeStaysDialLess() async throws {
    let base = try tempDir("dial")
    defer { try? FileManager.default.removeItem(at: base) }
    let mock = reasoningPanelMock()
    let (evalStore, recordStore) = tempStores()
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60,
      adaptiveThink: true, reasoningEffort: .high)
    let result = try await runner.run(
      task: "write answer.txt", models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge", baseDirectory: base)
    XCTAssertEqual(result.winner.model, "test/beta")

    for model in ["test/alpha", "test/beta"] {
      let requests = candidateRequests(mock, model: model)
      XCTAssertEqual(requests.count, 2, "\(model): a tool step and a finish")
      let first = try XCTUnwrap(requests.first)
      // The dial rides the candidate's first request (the runner's default `.openrouter` traits
      // spell it as the `reasoning` object on chat) — and every later one.
      XCTAssertEqual(first.reasoning?.effort, .high, "\(model): the candidate's first request carries the dial")
      XCTAssertTrue(requests.allSatisfy { $0.reasoning?.effort == .high }, "\(model): every request carries it")
      // adaptiveThink is live: a natively reasoning candidate under the dial is not offered
      // `think`, while `update_plan` stays.
      let names = toolNames(first)
      XCTAssertFalse(names.contains("think"), "\(model): think omitted under the dial: \(names)")
      XCTAssertTrue(names.contains("update_plan"), "\(model): update_plan still offered: \(names)")
    }
    // The judge is a structured side request over the reports and diffs — no dial, no tools.
    let judge = try XCTUnwrap(mock.requests.first { $0.model == "test/judge" })
    XCTAssertNil(judge.reasoning, "the judge is not a candidate")
    XCTAssertNil(judge.tools)
    // Every candidate still lands its record and its labeled eval row.
    XCTAssertEqual(try recordStore.all().count, 2)
    XCTAssertEqual(try evalStore.all().count, 2)
  }

  func testARunnerWithoutTheDialSendsTheRequestsItAlwaysDid() async throws {
    let base = try tempDir("no-dial")
    defer { try? FileManager.default.removeItem(at: base) }
    let mock = reasoningPanelMock()
    let (evalStore, recordStore) = tempStores()
    // The pre-change construction: no dial, `adaptiveThink` at its default.
    let runner = PanelRunner(
      service: mock, recordStore: recordStore, evalStore: evalStore, timeoutSeconds: 60)
    let result = try await runner.run(
      task: "write answer.txt", models: ["test/alpha", "test/beta"],
      judgeModel: "test/judge", baseDirectory: base)
    XCTAssertEqual(result.winner.model, "test/beta")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    for model in ["test/alpha", "test/beta"] {
      let first = try XCTUnwrap(candidateRequests(mock, model: model).first)
      XCTAssertNil(first.reasoning, "\(model): no dial, no reasoning field")
      let names = toolNames(first)
      XCTAssertTrue(names.contains("think"), "\(model): think is offered without a dial: \(names)")
      XCTAssertTrue(names.contains("update_plan"))
      // Nothing about reasoning anywhere on the wire — the request is what a pre-change run sent.
      let wire = String(decoding: try encoder.encode(first), as: UTF8.self)
      XCTAssertFalse(wire.contains("\"reasoning\""), "\(model): \(wire.prefix(240))")
    }
    XCTAssertNil(try XCTUnwrap(mock.requests.first { $0.model == "test/judge" }).reasoning)
  }
}
