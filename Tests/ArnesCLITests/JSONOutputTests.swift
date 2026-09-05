import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift
import XCTest
@testable import arnes

/// X8's `--json` listings: the encoder's rules, each DTO's documented keys (a fixture string
/// per DTO — the compatibility surface scripts read), the `runs` filters, and the
/// `debug prompt` section splitter and size table.
final class JSONOutputTests: XCTestCase {
  private func record(
    model: String, agent: String? = nil, cost: Double = 0, steps: Int = 1, stop: StopReason = .completed,
    provider: String? = nil, dialect: String = "chat", startedAt: Date = Date(), verified: Bool? = nil)
    -> RunRecord
  {
    var record = RunRecord(task: "t", model: model, dialect: dialect, packFamily: "generic")
    record.agent = agent
    record.costUSD = cost
    record.steps = steps
    record.stopReason = stop
    record.provider = provider
    record.startedAt = startedAt
    record.verifierPassed = verified
    record.finished = stop == .completed
    return record
  }

  // MARK: JSONOut

  func testEncoderSortsKeysWritesISODatesAndTurnsNonFiniteIntoNull() throws {
    struct Probe: Encodable {
      let zebra: Int
      let alpha: Date
      let ratio: Double?
      let path: String
    }
    let line = try JSONOut.line(Probe(
      zebra: 1, alpha: Date(timeIntervalSince1970: 0), ratio: JSONOut.finite(.nan), path: "/a/b"))
    // A plain optional is dropped when nil (the synthesized default) …
    XCTAssertEqual(line, #"{"alpha":"1970-01-01T00:00:00Z","path":"/a/b","zebra":1}"#)
    XCTAssertNil(JSONOut.finite(.infinity))
    XCTAssertEqual(JSONOut.finite(1.5), 1.5)
    XCTAssertFalse(line.contains("\u{1B}"))
    // … which is why every listing DTO's optional is `@Nullable`: the key is always there.
    struct Row: Encodable {
      @Nullable var ratio: Double?
      @Nullable var label: String?
    }
    XCTAssertEqual(try JSONOut.line(Row(ratio: JSONOut.finite(.infinity), label: "x")), #"{"label":"x","ratio":null}"#)
  }

  // MARK: models

  func testModelRowKeys() throws {
    let profile = ModelProfile(
      id: "acme/one", family: .anthropic, contextLength: 200_000, supportsTools: true,
      supportsReasoning: false, supportsStructuredOutputs: true, promptPricePerToken: 0.000003,
      completionPricePerToken: nil)
    XCTAssertEqual(
      try JSONOut.line([ModelRow(profile)]),
      #"[{"completion_price_per_token":null,"context_length":200000,"dialect":"messages","family":"anthropic","id":"acme/one","prompt_price_per_token":3e-06,"supports_reasoning":false,"supports_structured_outputs":true,"supports_tools":true,"supports_vision":false}]"#)
  }

  // MARK: providers

  func testProviderRowsResolveOfflineWithoutPrintingTheKey() throws {
    let credentials = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-json-creds-\(UUID().uuidString)")
    let providers: [String: ProviderConfig] = [
      "openrouter": .openrouter,
      "gw": ProviderConfig(kind: .litellm, baseURL: "https://gateway.example.com:8443/v1", apiKeyEnv: "GW_TOKEN", defaultModel: "sonnet"),
    ]
    let rows = Providers.rows(
      providers, active: "gw",
      environment: ["GW_TOKEN": "sk-SECRET-VALUE"], credentialsURL: credentials)
    XCTAssertEqual(rows.map(\.name), ["gw", "openrouter"])
    XCTAssertEqual(rows[0].active, true)
    XCTAssertEqual(rows[0].resolves, true)
    XCTAssertEqual(rows[0].keySource, "env GW_TOKEN")
    XCTAssertEqual(rows[0].baseHost, "gateway.example.com:8443")
    XCTAssertEqual(rows[0].defaultModel, "sonnet")
    // No key for openrouter in this environment: the row says so instead of throwing.
    XCTAssertEqual(rows[1].resolves, false)
    XCTAssertNotNil(rows[1].error)
    let line = try JSONOut.line(rows)
    XCTAssertFalse(line.contains("sk-SECRET-VALUE"))
    XCTAssertTrue(line.contains(#""key_source":"env GW_TOKEN""#))
    XCTAssertTrue(line.contains(#""base_host":"gateway.example.com:8443""#))
    XCTAssertFalse(line.contains("/v1"), "the URL path never rides a listing")
  }

  // MARK: status helpers

  func testStatusReportHelpersEncodeTheDocumentedKeys() throws {
    let limits = try JSONOut.line(StatusReport.limits(.default))
    XCTAssertEqual(
      limits,
      #"{"bash_output_chars":20000,"bash_timeout_seconds":300,"loop_guard":{"max_consecutive_errors":6,"max_edits_per_file":8,"max_identical_calls":6,"nudge_at":3},"tool_result_chars":30000}"#)
    XCTAssertTrue(
      try JSONOut.line(StatusReport.limits(LimitsConfig(bashTimeoutSeconds: 42))).contains(#""bash_timeout_seconds":42"#))
    let sandbox = try JSONOut.line(StatusReport.sandbox(nil))
    XCTAssertTrue(sandbox.hasPrefix(#"{"configured":false,"enabled":false,"fail_if_unavailable":true,"network":true,"supported":"#), sandbox)
    let env = try JSONOut.line(StatusReport.subprocessEnv(.default))
    XCTAssertTrue(env.contains(#""inherit":"all""#), env)
    XCTAssertTrue(env.contains(#""exclude_secrets":false"#), env)
    XCTAssertTrue(env.contains(#""withheld":["#), env)
  }

  // MARK: runs

  func testScoreboardRowsMatchTheTextGroupingAndCarryTheSums() throws {
    let records = [
      record(model: "b/model", cost: 0.10, steps: 4, verified: true),
      record(model: "b/model", cost: 0.30, steps: 6, stop: .maxSteps, verified: false),
      record(model: "a/model", cost: 0.02, steps: 3),
    ]
    let rows = Runs.scoreboardRows(records)
    XCTAssertEqual(rows.map(\.model), ["a/model", "b/model"])
    XCTAssertEqual(rows[1].runs, 2)
    XCTAssertEqual(rows[1].finished, 1)
    XCTAssertEqual(rows[1].avgSteps, 5)
    XCTAssertEqual(rows[1].totalCostUSD!, 0.40, accuracy: 1e-9)
    XCTAssertEqual(rows[1].avgCostUSD!, 0.20, accuracy: 1e-9)
    XCTAssertEqual(rows[1].verified, 2)
    XCTAssertEqual(rows[1].verifierPassed, 1)
    XCTAssertEqual(rows[0].provider, "openrouter")
    let line = try JSONOut.line([rows[0]])
    XCTAssertEqual(
      line,
      #"[{"avg_cost_usd":0.02,"avg_steps":3,"cached_tokens":0,"finished":1,"hook_blocks":0,"hook_continuations":0,"model":"a/model","prompt_tokens":0,"provider":"openrouter","runs":1,"total_cost_usd":0.02,"verified":0,"verifier_high":0,"verifier_low":0,"verifier_medium":0,"verifier_passed":0}]"#)
    // Same groups as the text scoreboard, in the same order.
    XCTAssertEqual(Runs.scoreboardLines(records).count, rows.count)
  }

  func testAgentRowsAndDecisionRows() throws {
    var lead = record(model: "lead/model", cost: 0.10, steps: 4)
    lead.sessionId = "S1"
    lead.turnIndex = 2
    lead.decisions = [
      ToolDecision(tool: "bash", tier: .mutating, decision: .allow, source: .user, reason: nil),
      ToolDecision(tool: "write_file", tier: .sensitive, decision: .deny, source: .rule, reason: "deny rule"),
    ]
    let explorer = record(model: "sub/model", agent: "explore", cost: 0.04, steps: 30, stop: .maxSteps)
    let rows = Runs.agentRows([lead, explorer])
    XCTAssertEqual(rows.map(\.agent), ["lead", "explore"])
    XCTAssertEqual(rows[1].partial, 1)
    XCTAssertEqual(
      try JSONOut.line([rows[1]]),
      #"[{"agent":"explore","avg_cost_usd":0.04,"avg_steps":30,"model":"sub/model","partial":1,"provider":"openrouter","runs":1,"total_cost_usd":0.04}]"#)
    let decisions = Runs.decisionRows([lead, explorer], limit: 10)
    XCTAssertEqual(decisions.count, 2)
    XCTAssertEqual(decisions[1].tool, "write_file")
    XCTAssertEqual(decisions[1].decision, "deny")
    XCTAssertEqual(decisions[1].source, "rule")
    XCTAssertEqual(decisions[1].sessionId, "S1")
    XCTAssertEqual(decisions[1].turnIndex, 2)
    let line = try JSONOut.line([decisions[0]])
    for key in ["session_id", "turn_index", "started_at", "model", "tool", "tier", "decision", "source", "reason"] {
      XCTAssertTrue(line.contains("\"\(key)\":"), "missing \(key) in \(line)")
    }
    // --limit keeps the last N audited runs, as the text view does.
    var older = record(model: "lead/model")
    older.decisions = [ToolDecision(tool: "bash", tier: .mutating, decision: .allow, source: .yes)]
    XCTAssertEqual(Runs.decisionRows([older, lead], limit: 1).count, 2)
    XCTAssertEqual(Runs.decisionRows([older, lead], limit: 2).count, 3)
  }

  func testRunsFiltersApplyToDaysAgentDialectAndProviderAndLeaveUnfilteredOutputIdentical() {
    let now = Date()
    let records = [
      record(model: "m", agent: nil, provider: nil, dialect: "chat", startedAt: now.addingTimeInterval(-3 * 86_400)),
      record(model: "m", agent: "explore", provider: "litellm", dialect: "messages", startedAt: now.addingTimeInterval(-10 * 86_400)),
      record(model: "m", agent: "general", provider: "openrouter", dialect: "responses", startedAt: now),
    ]
    XCTAssertEqual(Runs.filter(records, days: nil, agent: nil, dialect: nil, provider: nil, now: now).map(\.id), records.map(\.id))
    XCTAssertEqual(Runs.filter(records, days: 5, agent: nil, dialect: nil, provider: nil, now: now).count, 2)
    XCTAssertEqual(Runs.filter(records, days: nil, agent: "lead", dialect: nil, provider: nil, now: now).count, 1)
    XCTAssertEqual(Runs.filter(records, days: nil, agent: "explore", dialect: nil, provider: nil, now: now).count, 1)
    XCTAssertEqual(Runs.filter(records, days: nil, agent: nil, dialect: "responses", provider: nil, now: now).count, 1)
    // Records without a provider are OpenRouter's, so `--provider openrouter` keeps both.
    XCTAssertEqual(Runs.filter(records, days: nil, agent: nil, dialect: nil, provider: "openrouter", now: now).count, 2)
    XCTAssertEqual(Runs.filter(records, days: nil, agent: nil, dialect: nil, provider: "litellm", now: now).count, 1)
    // Unfiltered text output is the pre-flag scoreboard, byte for byte.
    let unfiltered = Runs.filter(records, days: nil, agent: nil, dialect: nil, provider: nil, now: now)
    XCTAssertEqual(Runs.scoreboardLines(unfiltered), Runs.scoreboardLines(records))
    XCTAssertEqual(Runs.byAgentLines(unfiltered), Runs.byAgentLines(records))
  }

  // MARK: sessions

  func testSessionRowKeys() throws {
    let meta = SessionMeta(
      id: "ABC", createdAt: Date(timeIntervalSince1970: 0), name: "demo", model: "m", forkedFrom: "ORIG",
      cwd: "/work", updatedAt: Date(timeIntervalSince1970: 60), messageCount: 4,
      parent: "LEAD", agent: "explore", depth: 1, origin: "subagent")
    XCTAssertEqual(
      try JSONOut.line([SessionRow(meta)]),
      #"[{"agent":"explore","created_at":"1970-01-01T00:00:00Z","cwd":"/work","depth":1,"forked_from":"ORIG","id":"ABC","message_count":4,"model":"m","name":"demo","origin":"subagent","parent":"LEAD","updated_at":"1970-01-01T00:01:00Z"}]"#)
  }

  // MARK: skills / agents / hooks

  func testSkillAndAgentRowKeys() throws {
    let skill = Skill(
      name: "deploy", description: "Ship it", body: "…", directory: URL(fileURLWithPath: "/repo/.arnes/skills/deploy"),
      allowedTools: ["bash(git push:*)"], model: "haiku", warnings: ["allowed-tools: dropped Task"])
    XCTAssertEqual(
      try JSONOut.line([SkillRow(skill)]),
      #"[{"allowed_tools":["bash(git push:*)"],"builtin":false,"description":"Ship it","directory":"/repo/.arnes/skills/deploy","model":"haiku","name":"deploy","source":"/repo/.arnes/skills/deploy","warnings":["allowed-tools: dropped Task"]}]"#)
    let builtin = try JSONOut.line([SkillRow(BuiltinSkills.all[0])])
    XCTAssertTrue(builtin.contains(#""builtin":true"#))
    XCTAssertTrue(builtin.contains(#""source":"built-in""#))

    let explore = try JSONOut.line([AgentRow(.explore, extraWarnings: ["skills: no skill named 'x' — not preloaded"])])
    for key in ["name", "description", "model", "tools", "disallowed_tools", "permission_mode", "max_steps", "budget_usd",
                "effort", "skills", "background", "fork", "isolation", "warnings", "source", "builtin"] {
      XCTAssertTrue(explore.contains("\"\(key)\":"), "missing \(key) in \(explore)")
    }
    XCTAssertTrue(explore.contains(#""builtin":true"#))
    XCTAssertTrue(explore.contains(#""fork":false"#))
    XCTAssertTrue(explore.contains(#""warnings":["skills: no skill named 'x' — not preloaded"]"#))
    XCTAssertTrue(try JSONOut.line([AgentRow(.fork)]).contains(#""fork":true"#))
  }

  func testHookRowKeysAndTrust() throws {
    var definition = HookDefinition(event: .preToolUse, matcher: "bash", command: "my-guardrail.sh")
    definition.id = "no-force-push"
    definition.when = ["command": "^git push"]
    definition.source = .project
    let row = HookRow(LoadedHook(definition: definition, trust: .changed), defaultPromptModel: nil)
    XCTAssertEqual(
      try JSONOut.line([row]),
      #"[{"agent":null,"command_or_prompt":"my-guardrail.sh","description":null,"enabled":true,"event":"PreToolUse","fail_closed":false,"id":"no-force-push","matcher":"bash","model":null,"source":"project","timeout_seconds":30,"trust":"changed","trusted":false,"type":"command","when":{"command":"^git push"}}]"#)
    let prompt = HookDefinition(event: .stop, prompt: "Did it finish? $ARGUMENTS")
    let promptRow = HookRow(LoadedHook(definition: prompt, trust: .trusted), defaultPromptModel: "judge/model")
    XCTAssertEqual(promptRow.type, "prompt")
    XCTAssertEqual(promptRow.model, "judge/model")
    XCTAssertEqual(promptRow.commandOrPrompt, "Did it finish? $ARGUMENTS")
    XCTAssertTrue(promptRow.trusted)
  }

  // MARK: debug prompt

  private let fixturePrompt = """
    You are a coding agent. Gather, act, verify.

    # Project instructions
    Always run swift test.

    # Environment
    Working directory: /tmp/x
    Date: 2026-01-01

    # Skills
    - deploy: Ship it
    """

  private var fixtureTools: [Tool] {
    [
      .function(
        name: "read_file", description: "Read a file.\nSecond line.",
        parameters: ["type": "object", "properties": ["path": ["type": "string"], "offset": ["type": "integer"]], "required": ["path"]]),
      .function(name: "think", description: "Scratchpad.", parameters: ["type": "object", "properties": [:]]),
    ]
  }

  func testPromptReportSplitsAtTopLevelHeadingsAndSizesEachSection() {
    let sections = PromptReport.split(fixturePrompt)
    XCTAssertEqual(sections.map(\.title), ["(preamble)", "Project instructions", "Environment", "Skills"])
    XCTAssertEqual(sections[0].text, "You are a coding agent. Gather, act, verify.\n")
    XCTAssertEqual(sections[1].text, "# Project instructions\nAlways run swift test.\n")
    XCTAssertEqual(sections[3].text, "# Skills\n- deploy: Ship it")
    for section in sections {
      XCTAssertEqual(section.chars, section.text.count)
      XCTAssertEqual(section.approxTokens, (section.chars + 3) / 4)
    }
    // A prompt with no headings is one preamble; an empty prompt has no sections.
    XCTAssertEqual(PromptReport.split("just text").map(\.title), ["(preamble)"])
    XCTAssertEqual(PromptReport.split("").count, 0)
    // A `## ` subheading does not start a section.
    XCTAssertEqual(PromptReport.split("# A\n## B\ntext").map(\.title), ["A"])
  }

  func testPromptReportTextHasMarkersToolLinesAndASortedSizeTable() {
    let report = PromptReport(model: "m/x", dialect: "chat", provider: "openrouter", prompt: fixturePrompt, tools: fixtureTools)
    let lines = report.textLines()
    let plain = lines.map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
    XCTAssertTrue(plain[0].hasPrefix("system prompt for m/x · dialect chat · provider openrouter · ~"), plain[0])
    XCTAssertTrue(plain[0].hasSuffix("(chars/4, an estimate)"), plain[0])
    let environment = report.sections[2]
    XCTAssertTrue(plain.contains("──── Environment (\(environment.chars) chars, ~\(environment.approxTokens) tokens) ────"), "\(plain)")
    XCTAssertTrue(plain.contains("read_file — Read a file. — offset, path*"), "\(plain)")
    XCTAssertTrue(plain.contains("think — Scratchpad."), "\(plain)")
    let table = report.sizeTable()
    XCTAssertEqual(table.last?.title, "total")
    let sized = table.dropLast()
    XCTAssertEqual(sized.map(\.chars), sized.map(\.chars).sorted(by: >))
    XCTAssertTrue(sized.contains { $0.title == "tools (2)" })
    XCTAssertEqual(table.last?.chars, fixturePrompt.count + sized.first { $0.title == "tools (2)" }!.chars)
  }

  func testPromptReportJSONKeys() throws {
    let report = PromptReport(model: "m/x", dialect: "messages", provider: "gw", prompt: fixturePrompt, tools: fixtureTools)
    let line = try JSONOut.line(report)
    for key in ["model", "dialect", "provider", "system_prompt", "sections", "tools", "approx_tokens_total"] {
      XCTAssertTrue(line.contains("\"\(key)\":"), "missing \(key)")
    }
    XCTAssertTrue(line.contains(#"{"approx_tokens":"#), line)
    XCTAssertTrue(line.contains(#""title":"Environment""#), line)
    XCTAssertTrue(line.contains(#""required":["path"]"#), line)
    XCTAssertTrue(line.contains(#""parameter_names":["offset","path"]"#), line)
    XCTAssertTrue(line.contains(#""parameters":{"properties":{"#), line)
    // The section text rides `system_prompt` once, not per section.
    XCTAssertFalse(line.contains(#""text":"#), line)
    XCTAssertEqual(line.components(separatedBy: "Always run swift test.").count, 2)
  }
}
