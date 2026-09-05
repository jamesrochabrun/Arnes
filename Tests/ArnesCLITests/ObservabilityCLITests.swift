import ArnesKit
import XCTest
@testable import arnes

/// O1 — the observability sweep's CLI surface. `arnes status` names every switch a run reads
/// (`Status.settingsLines` over a runtime a test builds and a home it injects — never the real
/// `~/.arnes`); the `--json` document carries the same facts under the documented snake_case
/// keys, null where nothing is configured; `arnes runs` grows a `confidence=` column only when a
/// shown run stated one (the byte pins in `PromptCacheCLITests` / `HooksEverywhereCLITests` /
/// `SubagentLineageCLITests` hold because their fixtures state none) and the `--json` row counts
/// the levels; the REPL's `/status` gets one `cache` row. The doctor's `checkpoints/` and
/// `memory/` parts are pinned in `DoctorTests`; the Kit-side fields in `ObservabilityTests`.
final class ObservabilityCLITests: XCTestCase {
  private let home = "/Users/tester"

  private func provider(_ entry: ProviderConfig? = nil) throws -> ResolvedProvider {
    try ProviderResolver.resolve(
      config: entry.map { ArnesConfig(provider: "gw", providers: ["gw": $0]) },
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
  }

  private func record(
    _ model: String, verified: Bool? = nil, confidence: String? = nil,
    promptTokens: Int? = nil, cachedTokens: Int? = nil, hookBlocks: Int? = nil) -> RunRecord
  {
    var record = RunRecord(task: "t", model: model, dialect: "chat", packFamily: "generic")
    record.costUSD = 0.01
    record.finished = true
    record.verifierPassed = verified
    record.verifierConfidence = confidence
    record.promptTokens = promptTokens
    record.cachedTokens = cachedTokens
    record.hookBlocks = hookBlocks
    return record
  }

  private func facts() -> StatusFormat.Facts {
    StatusFormat.Facts(
      sessionId: "S-1", name: nil, forkedFrom: nil, model: "test/model", dialectFlag: "auto",
      lastDialect: nil, effort: nil, provider: "openrouter", mode: .default, readOnly: false,
      sandbox: nil, hooks: nil, messages: 0, turns: 0, costUSD: 0, budgetUSD: nil,
      lastPromptTokens: nil, contextLength: nil, tainted: false, plan: nil)
  }

  // MARK: arnes status — text

  func testSettingsLinesNameEverySwitchInOrderOverTheDefaults() throws {
    let runtime = ArnesRuntime(provider: try provider())
    let settings = Status.Settings(runtime, environment: [:], home: home, sandboxSupported: true)
    XCTAssertEqual(Status.settingsLines(settings), [
      "sandbox: not configured — unattended runs (do --yes, eval, panel) are confined by default where the platform supports it; interactive opt-in (sandbox)",
      "tool-result framing: on (policies.toolResultFraming)",
      "adaptive think: on · no think tool for a natively reasoning model under --effort (policies.adaptiveThink)",
      "transport: 4 request retries · 5 stream retries · stream idle timeout 300 s (policies.transport)",
      "prompt cache: anthropic breakpoints on (policies.promptCache)",
      "manifest cache: off (policies.manifestCache)",
      "compaction: threshold 80% · keep 6 recent tool results · clear results ≥ 2000 chars · ≤ 2 emergency summaries/turn · keep 1 recent image (compaction)",
      "checkpoints: on · ~/.arnes/checkpoints · files ≤ 5 MB · 100 turns (checkpoints)",
      "memory: on · ~/.arnes/memory · 200 lines / 25600 bytes (memory)",
      "web: not configured — web_fetch is not registered (add a top-level web block)",
      "limits: tool result 30000 chars · bash output 20000 chars · bash timeout 300 s · loop guard errors 6 / identical 6 / edits per file 8 / nudge at 3 (limits)",
      "subagents: default model inherit · max concurrent 4 · max depth 1 · background off · join at turn end on · transcripts on (subagents)",
      "judge: none (bashJudge)",
      "reasoning shape: openrouter (provider.reasoningShape)",
      "panel on fail: off (policies.panelOnVerifierFail)",
    ])
  }

  func testSettingsLinesReflectEveryConfiguredValueAndAbbreviateHome() throws {
    let entry = ProviderConfig(
      kind: .openrouter, baseURL: "https://openrouter.ai/api/v1", apiKey: "sk-or-test",
      bashJudge: "judge/model",
      sandbox: SandboxConfig(enabled: true, network: false),
      subagents: SubagentsConfig(
        defaultModel: "sub/model", maxSteps: 12, budgetUSD: 0.5, maxConcurrent: 2, maxDepth: 2,
        background: true, joinAtTurnEnd: false, persistTranscripts: false))
    let runtime = ArnesRuntime(
      provider: try provider(entry),
      limits: LimitsConfig(
        toolResultChars: 40_000, bashOutputChars: 5_000,
        loopGuard: .init(maxConsecutiveErrors: 2, maxIdenticalCalls: 3, maxEditsPerFile: 4, nudgeAt: 1),
        bashTimeoutSeconds: 42),
      checkpoints: CheckpointsConfig(maxFileBytes: 256_000, maxTurns: 7),
      toolResultGuard: .cli(framing: false),
      memory: MemoryConfig(directory: "/srv/notes", maxLines: 50, maxBytes: 4096),
      transport: TransportPolicy(maxRequestRetries: 1, maxStreamRetries: 2, streamIdleTimeoutMs: 1500),
      web: WebConfig(allowedDomains: ["a.example", "b.example"], deniedDomains: ["c.example"], maxBytes: 4096, timeoutSeconds: 5),
      cachePolicy: CachePolicy(anthropicBreakpoints: false, ttl: "1h"),
      compaction: CompactionPolicy(threshold: 0.5, keepRecentToolResults: 1, clearMinChars: 100, maxPerTurn: 1, keepRecentImages: 0),
      manifestCache: ManifestCache(
        directory: URL(fileURLWithPath: "/nonexistent/arnes-models-\(UUID().uuidString)"),
        policy: ManifestCachePolicy(ttl: 12 * 3600)))
    // `ARNES_MEMORY_DIR` outranks `memory.directory`, and the row says which set the root.
    let settings = Status.Settings(
      runtime, environment: ["ARNES_MEMORY_DIR": "\(home)/elsewhere"], home: home, sandboxSupported: false)
    let lines = Status.settingsLines(settings)
    XCTAssertEqual(lines.count, 15)
    XCTAssertEqual(lines[0], "sandbox: on · network off · fail if unavailable — enabled but unsupported on this platform (sandbox)")
    XCTAssertEqual(lines[1], "tool-result framing: off (policies.toolResultFraming)")
    XCTAssertEqual(lines[2], "adaptive think: on · no think tool for a natively reasoning model under --effort (policies.adaptiveThink)")
    XCTAssertEqual(lines[3], "transport: 1 request retries · 2 stream retries · stream idle timeout 1.5 s (policies.transport)")
    XCTAssertEqual(lines[4], "prompt cache: anthropic breakpoints off · ttl 1h (policies.promptCache)")
    XCTAssertEqual(lines[5], "manifest cache: on · ttl 12 h (policies.manifestCache)")
    XCTAssertEqual(
      lines[6],
      "compaction: threshold 50% · keep 1 recent tool result · clear results ≥ 100 chars · ≤ 1 emergency summary/turn · keep 0 recent images (compaction)")
    XCTAssertEqual(lines[7], "checkpoints: on · ~/.arnes/checkpoints · files ≤ 256 KB · 7 turns (checkpoints)")
    XCTAssertEqual(lines[8], "memory: on · ~/elsewhere · ARNES_MEMORY_DIR · 50 lines / 4096 bytes (memory)")
    XCTAssertEqual(
      lines[9],
      "web: allowed: a.example, b.example · denied: c.example · ≤ 4096 bytes · 5 s · off under sandbox.network false (web)")
    XCTAssertEqual(
      lines[10],
      "limits: tool result 40000 chars · bash output 5000 chars · bash timeout 42 s · loop guard errors 2 / identical 3 / edits per file 4 / nudge at 1 (limits)")
    XCTAssertEqual(
      lines[11],
      "subagents: default model sub/model · max steps 12 · budget $0.50 · max concurrent 2 · max depth 2 · background on · join at turn end off · transcripts off (subagents)")
    XCTAssertEqual(lines[12], "judge: judge/model (bashJudge)")
    // The built-in openrouter entry sets no `reasoningShape`, so the row is the kind's default alone.
    XCTAssertEqual(lines[13], "reasoning shape: openrouter (provider.reasoningShape)")
    // A test-built runtime sets no `policies.panelOnVerifierFail`, so the trigger's row is off.
    XCTAssertEqual(lines[14], "panel on fail: off (policies.panelOnVerifierFail)")
    // The rows are the switches, never the secrets beside them.
    XCTAssertFalse(lines.joined().contains("sk-or-test"))
  }

  func testSandboxFactAndTheOffRowsCoverEveryBranch() throws {
    XCTAssertEqual(
      Status.sandboxFact(nil, supported: false),
      "not configured — this platform cannot enforce one, so every run is unconfined (sandbox)")
    XCTAssertEqual(
      Status.sandboxFact(SandboxConfig(enabled: false), supported: true),
      "off — every run is unconfined, unattended ones included (sandbox.enabled)")
    XCTAssertEqual(
      Status.sandboxFact(SandboxConfig(enabled: true), supported: true),
      "on · network on · fail if unavailable (sandbox)")
    XCTAssertEqual(
      Status.sandboxFact(SandboxConfig(enabled: true, network: false, failIfUnavailable: false), supported: true),
      "on · network off · run unconfined if unavailable (sandbox)")

    // Checkpoints and memory switched off, the idle timeout off, a web block with no lists.
    let runtime = ArnesRuntime(
      provider: try provider(),
      checkpoints: CheckpointsConfig(enabled: false),
      memory: MemoryConfig(enabled: false),
      transport: TransportPolicy(streamIdleTimeoutMs: 0),
      web: WebConfig())
    let lines = Status.settingsLines(Status.Settings(runtime, environment: [:], home: home, sandboxSupported: true))
    XCTAssertTrue(lines.contains("checkpoints: off (checkpoints.enabled)"), lines.joined(separator: "\n"))
    XCTAssertTrue(lines.contains("memory: off (memory.enabled)"))
    XCTAssertTrue(lines.contains("transport: 4 request retries · 5 stream retries · stream idle timeout off (policies.transport)"))
    XCTAssertTrue(lines.contains("web: allowed: none · denied: none · ≤ 200000 bytes · 30 s (web)"))

    XCTAssertEqual(Status.bytesLabel(5_000_000), "5 MB")
    XCTAssertEqual(Status.bytesLabel(256_000), "256 KB")
    XCTAssertEqual(Status.bytesLabel(1234), "1234 bytes")
    XCTAssertEqual(Status.seconds(milliseconds: 300_000), "300 s")
    XCTAssertEqual(Status.seconds(milliseconds: 1500), "1.5 s")
  }

  // MARK: arnes status --json

  func testStatusReportSettingsHelpersEncodeTheDocumentedKeys() throws {
    XCTAssertEqual(
      try JSONOut.line(StatusReport.transport(.default)),
      #"{"max_request_retries":4,"max_stream_retries":5,"stream_idle_timeout_ms":300000}"#)
    XCTAssertEqual(try JSONOut.line(StatusReport.promptCache(.default)), #"{"anthropic_breakpoints":true,"ttl":null}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.promptCache(CachePolicy(anthropicBreakpoints: false, ttl: "1h"))),
      #"{"anthropic_breakpoints":false,"ttl":"1h"}"#)
    XCTAssertEqual(try JSONOut.line(StatusReport.manifestCache(nil)), #"{"enabled":false,"ttl_hours":null}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.manifestCache(ManifestCachePolicy(ttl: 12 * 3600))),
      #"{"enabled":true,"ttl_hours":12}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.compaction(.default)),
      #"{"clear_min_chars":2000,"keep_recent_images":1,"keep_recent_tool_results":6,"max_per_turn":2,"threshold":0.8}"#)
    let root = URL(fileURLWithPath: "/Users/tester/.arnes")
    XCTAssertEqual(
      try JSONOut.line(StatusReport.checkpoints(nil, root: root.appendingPathComponent("checkpoints"))),
      #"{"enabled":true,"max_file_bytes":5000000,"max_turns":100,"root":"/Users/tester/.arnes/checkpoints"}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.checkpoints(CheckpointsConfig(enabled: false, maxFileBytes: 10, maxTurns: 1), root: root)),
      #"{"enabled":false,"max_file_bytes":10,"max_turns":1,"root":"/Users/tester/.arnes"}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.memory(nil, root: root.appendingPathComponent("memory"))),
      #"{"enabled":true,"max_bytes":25600,"max_lines":200,"root":"/Users/tester/.arnes/memory"}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.memory(MemoryConfig(enabled: false, maxLines: 5, maxBytes: 50), root: root)),
      #"{"enabled":false,"max_bytes":50,"max_lines":5,"root":"/Users/tester/.arnes"}"#)
    XCTAssertNil(StatusReport.web(nil), "no block, no tool — null on the document")
    XCTAssertEqual(
      try JSONOut.line(StatusReport.web(WebConfig(allowedDomains: ["a.example"], deniedDomains: [], maxBytes: 4096, timeoutSeconds: 5))),
      #"{"allowed_domains":["a.example"],"denied_domains":[],"max_bytes":4096,"timeout_seconds":5}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.subagents(TaskTool.Defaults())),
      #"{"background":false,"budget_usd":null,"default_model":null,"join_at_turn_end":true,"max_concurrent":4,"max_depth":1,"max_steps":null,"persist_transcripts":true}"#)
    XCTAssertEqual(
      try JSONOut.line(StatusReport.subagents(TaskTool.Defaults(maxSteps: 12, budgetUSD: 0.5, defaultModel: "sub/model"))),
      #"{"background":false,"budget_usd":0.5,"default_model":"sub/model","join_at_turn_end":true,"max_concurrent":4,"max_depth":1,"max_steps":12,"persist_transcripts":true}"#)
  }

  func testStatusReportDocumentCarriesTheSettingsKeysWithNullWhereNothingIsConfigured() throws {
    let runtime = ArnesRuntime(provider: try provider())
    let settings = Status.Settings(runtime, environment: [:], home: home, sandboxSupported: true)
    let report = StatusReport(
      provider: .init(name: "openrouter", kind: "openrouter", baseHost: "openrouter.ai", keySource: "env", defaultModel: nil),
      key: nil, credits: nil, keyError: nil,
      manifestModels: nil, manifestSource: nil, manifestFetchedAt: nil,
      subprocessEnv: StatusReport.subprocessEnv(.default),
      environmentContext: true,
      limits: StatusReport.limits(runtime.limits),
      paths: .init(protected: [], sensitiveWrite: [], denyRead: []),
      sandbox: StatusReport.sandbox(nil),
      judge: nil,
      toolResultFraming: settings.framing,
      adaptiveThink: settings.adaptiveThink,
      transport: StatusReport.transport(settings.transport),
      promptCache: StatusReport.promptCache(settings.cachePolicy),
      manifestCache: StatusReport.manifestCache(settings.manifestCache),
      compaction: StatusReport.compaction(settings.compaction),
      checkpoints: StatusReport.checkpoints(settings.checkpoints, root: settings.checkpointRoot),
      memory: StatusReport.memory(settings.memory, root: settings.memoryRoot),
      web: StatusReport.web(settings.web),
      subagents: StatusReport.subagents(settings.subagents),
      reasoningShape: settings.reasoningShape.rawValue,
      panelOnVerifierFail: settings.panelOnVerifierFail)
    let line = try JSONOut.line(report)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    // The X8 keys plus O1's, every one present.
    XCTAssertEqual(Set(object.keys), [
      "provider", "key", "credits", "key_error", "manifest_models", "manifest_source", "manifest_fetched_at",
      "subprocess_env", "environment_context", "limits", "paths", "sandbox", "judge",
      "tool_result_framing", "adaptive_think", "transport", "prompt_cache", "manifest_cache", "compaction", "checkpoints",
      "memory", "web", "subagents", "reasoning_shape", "panel_on_verifier_fail",
    ])
    XCTAssertTrue(object["web"] is NSNull, "no web block → null, never omitted")
    XCTAssertTrue(object["panel_on_verifier_fail"] is NSNull, "no `policies.panelOnVerifierFail` → null, never omitted (P2)")
    XCTAssertEqual(object["reasoning_shape"] as? String, "openrouter", "R3's shape, the kind's default for the built-in provider (Q2)")
    XCTAssertEqual(object["tool_result_framing"] as? Bool, true)
    XCTAssertEqual(object["adaptive_think"] as? Bool, true, "on by default since the batch-13 A/B")
    let limits = try XCTUnwrap(object["limits"] as? [String: Any])
    XCTAssertEqual(limits["bash_timeout_seconds"] as? Int, 300, "the fact the text view never had")
    let memory = try XCTUnwrap(object["memory"] as? [String: Any])
    XCTAssertEqual(memory["root"] as? String, "/Users/tester/.arnes/memory", "full paths in JSON — the X8 convention")
    let checkpoints = try XCTUnwrap(object["checkpoints"] as? [String: Any])
    XCTAssertEqual(checkpoints["root"] as? String, "/Users/tester/.arnes/checkpoints")
    let manifest = try XCTUnwrap(object["manifest_cache"] as? [String: Any])
    XCTAssertEqual(manifest["enabled"] as? Bool, false)
    XCTAssertTrue(manifest["ttl_hours"] is NSNull)
    let subagents = try XCTUnwrap(object["subagents"] as? [String: Any])
    XCTAssertTrue(subagents["default_model"] is NSNull, "inherit")
    XCTAssertTrue(subagents["max_steps"] is NSNull, "unlimited")
  }

  // MARK: arnes runs

  func testScoreboardGrowsTheConfidenceColumnOnlyWhenAShownRunStatedOne() {
    // No shown run stated a confidence: the lines every other pin expects, byte for byte.
    XCTAssertEqual(Runs.scoreboardLines([record("a/model", verified: true), record("b/model")]), [
      "a/model                                  runs=1\tcost=$0.0100\tverified=1/1",
      "b/model                                  runs=1\tcost=$0.0100\tverified=n/a",
    ])
    let records = [
      record("a/model", verified: true, confidence: "high"),
      record("a/model", verified: true, confidence: "high"),
      record("a/model", verified: false, confidence: "medium"),
      record("a/model", verified: true),  // a one-line PASS states none
      record("b/model", verified: true),
      record("c/model"),
    ]
    XCTAssertEqual(Runs.scoreboardLines(records), [
      "a/model                                  runs=4\tcost=$0.0400\tverified=3/4\tconfidence=high:2 medium:1",
      "b/model                                  runs=1\tcost=$0.0100\tverified=1/1\tconfidence=n/a",
      "c/model                                  runs=1\tcost=$0.0100\tverified=n/a\tconfidence=n/a",
    ])
    // With every conditional column showing, the order is verified · confidence · hooks · cache.
    XCTAssertEqual(
      Runs.scoreboardLines([
        record("a/model", verified: false, confidence: "low", promptTokens: 100, cachedTokens: 50, hookBlocks: 1),
      ]),
      ["a/model                                  runs=1\tcost=$0.0100\tverified=0/1\tconfidence=low:1\thooks: blocks=1 cont=0\tcache=50%"])
    XCTAssertEqual(Runs.confidenceColumn(Array(records.prefix(4))), "high:2 medium:1")
    XCTAssertEqual(Runs.confidenceColumn([record("m", verified: true)]), "n/a")
  }

  func testScoreboardRowsCountTheStatedConfidenceByLevel() throws {
    let rows = Runs.scoreboardRows([
      record("a/model", verified: true, confidence: "high"),
      record("a/model", verified: true, confidence: "high"),
      record("a/model", verified: false, confidence: "medium"),
      record("a/model", verified: true),
    ])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].verifierHigh, 2)
    XCTAssertEqual(rows[0].verifierMedium, 1)
    XCTAssertEqual(rows[0].verifierLow, 0)
    let line = try JSONOut.line(rows)
    XCTAssertTrue(line.contains(#""verifier_high":2,"verifier_low":0,"verifier_medium":1,"verifier_passed":3"#), line)
    // A group that stated none carries zeros — the keys are always present.
    let none = try JSONOut.line(Runs.scoreboardRows([record("m")]))
    XCTAssertTrue(none.contains(#""verifier_high":0,"verifier_low":0,"verifier_medium":0"#), none)
  }

  // MARK: /status

  func testStatusCacheRowShowsTheShareOrTheRefusalAndIsLeftOutOtherwise() throws {
    var facts = facts()
    XCTAssertFalse(StatusFormat.lines(facts).contains { $0.hasPrefix("cache") }, "no turn yet")
    facts.cachedTokens = 0
    facts.cachePromptTokens = 100
    XCTAssertFalse(StatusFormat.lines(facts).contains { $0.hasPrefix("cache") }, "nothing cached")
    facts.cachedTokens = 40
    facts.cachePromptTokens = nil
    XCTAssertFalse(StatusFormat.lines(facts).contains { $0.hasPrefix("cache") }, "no denominator")

    facts.cachedTokens = 19_098
    facts.cachePromptTokens = 25_746
    facts.lastPromptTokens = 25_746
    facts.contextLength = 200_000
    facts.tainted = true
    let lines = StatusFormat.lines(facts)
    XCTAssertTrue(
      lines.contains("cache     74% of the last turn's prompt tokens read from the cache (19,098 of 25,746)"),
      lines.joined(separator: "\n"))
    // After `context`, before `tainted`; the label fits the existing column, so nothing re-pads.
    let cache = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("cache") })
    XCTAssertTrue(lines[cache - 1].hasPrefix("context"), lines[cache - 1])
    XCTAssertTrue(lines[cache + 1].hasPrefix("tainted"), lines[cache + 1])
    XCTAssertEqual(lines.first, "session   S-1")

    // Clamped, like the footer's segment.
    facts.cachedTokens = 300
    facts.cachePromptTokens = 200
    XCTAssertTrue(
      StatusFormat.lines(facts).contains("cache     100% of the last turn's prompt tokens read from the cache (300 of 200)"))

    // A refusal wins over any figure.
    facts.cacheControlRefused = true
    XCTAssertTrue(
      StatusFormat.lines(facts).contains(
        "cache     cache_control refused by the endpoint — breakpoints are off for the rest of this session"))
  }
}
