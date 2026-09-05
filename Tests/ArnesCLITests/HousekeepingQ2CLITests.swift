import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// Q2 (batch 15) — four housekeeping fixes, each pinned without a terminal or a network: the eval
/// progress sink routes text to stdout and `--json` to stderr through injectable writers (the
/// default text writer flushes per line — a redirected eval log used to lose every `▶`/`✓` line
/// when the process died; the flush itself is pinned by shape, not by redirecting fd 1 inside the
/// test process); `EvalReportDocument.collapsed_models` carries what `-m a -m a` collapsed;
/// `arnes status` prints R3's reasoning shape as its last settings row and `--json` as
/// `reasoning_shape`; `/btw` and `/compact` expand paste placeholders at the door like `/schema`.
final class HousekeepingQ2CLITests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func provider(_ entry: ProviderConfig? = nil) throws -> ResolvedProvider {
    try ProviderResolver.resolve(
      config: entry.map { ArnesConfig(provider: "gw", providers: ["gw": $0]) },
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
  }

  private func outcome(task: String = "t", passed: Bool = true) -> EvalOutcome {
    EvalOutcome(
      suite: "unit", taskId: task, model: "test/model", trial: 1, checkPassed: passed, agentFinished: true,
      steps: 3, toolCalls: 2, costUSD: 0.0123, durationSeconds: 4.26, startedAt: t0,
      routedModels: [], error: nil, dialect: "chat", sandboxed: true, sessionId: "S-\(task)-1",
      runId: "R-\(task)-1", stopReason: "completed")
  }

  // MARK: 1. the eval progress sink

  func testProgressSinkSendsTextModeToStdoutAndJSONModeToStderrOncePerLine() {
    final class Box: @unchecked Sendable {
      var out: [String] = []
      var err: [String] = []
    }
    let text = Box()
    let say = Eval.progressSink(json: false, stdout: { text.out.append($0) }, stderr: { text.err.append($0) })
    say("suite basics · 9 tasks")
    say("▶ create-file · test/model · trial 1")
    say("✓ create-file · test/model · trial 1")
    XCTAssertEqual(text.out, ["suite basics · 9 tasks", "▶ create-file · test/model · trial 1", "✓ create-file · test/model · trial 1"],
                   "text mode: every line to the stdout writer, once, bytes untouched")
    XCTAssertEqual(text.err, [], "text mode never writes stderr through the sink")

    let json = Box()
    let sayJSON = Eval.progressSink(json: true, stdout: { json.out.append($0) }, stderr: { json.err.append($0) })
    sayJSON("▶ create-file · test/model · trial 1")
    sayJSON("✓ create-file · test/model · trial 1")
    XCTAssertEqual(json.err, ["▶ create-file · test/model · trial 1", "✓ create-file · test/model · trial 1"],
                   "--json: stdout is the one document, so the progress goes to stderr")
    XCTAssertEqual(json.out, [], "--json mode never writes stdout through the sink")
  }

  // MARK: 2. collapsed_models

  func testEvalReportDocumentCarriesTheCollapsedModelsFirstInTheSortedDocument() throws {
    let outcomes = [outcome(task: "a")]
    let summaries = EvalReport.summaries(outcomes)
    let collapsed = EvalReportDocument(
      suite: "unit", outcomes: outcomes, summaries: summaries, comparison: nil, compare: nil,
      gate: EvalGate(), exitCode: 0, collapsedModels: ["deepseek/deepseek-chat"])
    let line = try JSONOut.line(collapsed)
    XCTAssertTrue(line.hasPrefix(#"{"collapsed_models":["deepseek/deepseek-chat"],"compare":null,"exit_code":0,"#), line)

    // The defaulted parameter: a run with no repeat carries an empty list — present, never null.
    let plain = EvalReportDocument(
      suite: "unit", outcomes: outcomes, summaries: summaries, comparison: nil, compare: nil,
      gate: EvalGate(), exitCode: 0)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONOut.line(plain).utf8)) as? [String: Any])
    XCTAssertEqual(object["collapsed_models"] as? [String], [])
    XCTAssertFalse(object["collapsed_models"] is NSNull)

    // What the feed point hands the document is `dedupedModels`' duplicates — each once, encounter order.
    XCTAssertEqual(Eval.dedupedModels(["a", "b", "a", "c", "b", "a"]).duplicates, ["a", "b"])
  }

  // MARK: 3. the reasoning shape row

  func testStatusReasoningShapeRowFollowsTheKindAndNamesAnOverride() throws {
    let home = "/Users/tester"
    // A LiteLLM gateway speaks OpenAI's `reasoning_effort` string unless its entry says otherwise.
    let litellm = ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com/v1", apiKey: "sk-test", defaultModel: "haiku")
    let gateway = Status.Settings(ArnesRuntime(provider: try provider(litellm)), environment: [:], home: home, sandboxSupported: true)
    let gatewayLines = Status.settingsLines(gateway)
    XCTAssertEqual(gatewayLines.count, 15)
    XCTAssertEqual(gatewayLines[12], "judge: none (bashJudge)", "the thirteen existing rows keep their place")
    XCTAssertEqual(gatewayLines[13], "reasoning shape: openai (provider.reasoningShape)")
    XCTAssertEqual(gateway.reasoningShape, .openai)
    XCTAssertFalse(gateway.reasoningShapeOverridden)

    // An entry that overrides its kind's default says which default it overrides.
    let overridden = ProviderConfig(
      kind: .openaiCompatible, baseURL: "https://api.example.com/v1", apiKey: "sk-test", defaultModel: "m",
      reasoningShape: ReasoningShape.none)
    let custom = Status.Settings(ArnesRuntime(provider: try provider(overridden)), environment: [:], home: home, sandboxSupported: true)
    let kind = ProviderKind.openaiCompatible.rawValue
    XCTAssertEqual(
      Status.settingsLines(custom)[13],
      "reasoning shape: none · overrides the \(kind) default openai (provider.reasoningShape)")
    XCTAssertTrue(custom.reasoningShapeOverridden)

    // The JSON document carries the same value under `reasoning_shape`, always present.
    let report = StatusReport(
      provider: .init(name: "gw", kind: "litellm", baseHost: "gateway.example.com", keySource: "config", defaultModel: "haiku"),
      key: nil, credits: nil, keyError: nil,
      manifestModels: nil, manifestSource: nil, manifestFetchedAt: nil,
      subprocessEnv: StatusReport.subprocessEnv(.default),
      environmentContext: true,
      limits: StatusReport.limits(LimitsConfig()),
      paths: .init(protected: [], sensitiveWrite: [], denyRead: []),
      sandbox: StatusReport.sandbox(nil),
      judge: nil,
      toolResultFraming: gateway.framing,
      adaptiveThink: gateway.adaptiveThink,
      transport: StatusReport.transport(gateway.transport),
      promptCache: StatusReport.promptCache(gateway.cachePolicy),
      manifestCache: StatusReport.manifestCache(gateway.manifestCache),
      compaction: StatusReport.compaction(gateway.compaction),
      checkpoints: StatusReport.checkpoints(gateway.checkpoints, root: gateway.checkpointRoot),
      memory: StatusReport.memory(gateway.memory, root: gateway.memoryRoot),
      web: StatusReport.web(gateway.web),
      subagents: StatusReport.subagents(gateway.subagents),
      reasoningShape: gateway.reasoningShape.rawValue,
      panelOnVerifierFail: gateway.panelOnVerifierFail)
    let line = try JSONOut.line(report)
    XCTAssertTrue(line.contains(#""reasoning_shape":"openai""#), line)
    XCTAssertFalse(line.contains("sk-test"), "never a key in the document")
  }

  // MARK: 4. /btw and /compact expand pastes

  func testExpandingPastesReachesBtwCompactAndSchemaAndLeavesEveryOtherCommandAlone() {
    let pastes = PasteStore()
    let placeholder = pastes.store("line one\nline two")
    XCTAssertEqual(placeholder, "[Pasted text #1 +2 lines]")

    // /btw: the question the model is asked is the pasted text, not the placeholder.
    XCTAssertEqual(
      SlashCommand.expandingPastes(.btw(question: "\(placeholder) what is this?"), with: pastes.expand),
      .btw(question: "line one\nline two what is this?"))

    // /compact: expanded *before* the model/instructions split, so the paste is read as
    // instructions whole (a placeholder carries no `/` and is not an alias, so it would have
    // landed in the instructions branch literally).
    let compact = SlashCommand.expandingPastes(.compact(argument: placeholder), with: pastes.expand)
    XCTAssertEqual(compact, .compact(argument: "line one\nline two"))
    if case .compact(let argument) = compact {
      let (model, instructions) = SlashCommand.compactArguments(argument, aliases: ["haiku": "anthropic/claude-haiku"])
      XCTAssertNil(model)
      XCTAssertEqual(instructions, "line one\nline two")
    } else {
      XCTFail("still a /compact")
    }
    // A model word ahead of the paste still steers the summarizer, the paste is the steering text.
    if case .compact(let argument) = SlashCommand.expandingPastes(.compact(argument: "haiku \(placeholder)"), with: pastes.expand) {
      let (model, instructions) = SlashCommand.compactArguments(argument, aliases: ["haiku": "anthropic/claude-haiku"])
      XCTAssertEqual(model, "anthropic/claude-haiku")
      XCTAssertEqual(instructions, "line one\nline two")
    } else {
      XCTFail("still a /compact")
    }

    // /schema keeps H1's behavior through the same helper.
    XCTAssertEqual(
      SlashCommand.expandingPastes(.schema(argument: placeholder), with: pastes.expand),
      .schema(argument: "line one\nline two"))

    // No argument, nothing to expand; every other command passes through untouched.
    XCTAssertEqual(SlashCommand.expandingPastes(.btw(question: nil), with: pastes.expand), .btw(question: nil))
    XCTAssertEqual(SlashCommand.expandingPastes(.compact(argument: nil), with: pastes.expand), .compact(argument: nil))
    XCTAssertEqual(SlashCommand.expandingPastes(.status, with: pastes.expand), .status)
    XCTAssertEqual(
      SlashCommand.expandingPastes(.model(query: placeholder), with: pastes.expand),
      .model(query: placeholder), "a model query is a search string, never pasted text for the model")
    XCTAssertEqual(
      SlashCommand.expandingPastes(.unknown(name: "x", argument: placeholder), with: pastes.expand),
      .unknown(name: "x", argument: placeholder))
    // A line without a placeholder is byte-identical.
    XCTAssertEqual(
      SlashCommand.expandingPastes(.btw(question: "plain question"), with: pastes.expand),
      .btw(question: "plain question"))
  }
}
