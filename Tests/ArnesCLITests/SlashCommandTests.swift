import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// C6 — the REPL's dial and introspection commands: parsing (`/context`, `/btw`, `/effort`,
/// `/thinking`, `/budget`), their argument readers, the `/status` and `/context` layouts, and
/// the `interactive` flags that mirror `do`'s (`--budget`, `--max-steps`, `--dialect`).
final class SlashCommandTests: XCTestCase {
  // MARK: Parsing

  func testParseEffortThinkingBtwContextBudget() {
    guard case .context? = SlashCommand.parse("/context") else { return XCTFail("/context") }
    guard case .context? = SlashCommand.parse("/ctx") else { return XCTFail("/ctx alias") }
    guard case .btw(let question)? = SlashCommand.parse("/btw what did I ask first?") else { return XCTFail("/btw") }
    XCTAssertEqual(question, "what did I ask first?")
    guard case .btw(nil)? = SlashCommand.parse("/btw") else { return XCTFail("/btw with nothing") }
    guard case .btw("hm")? = SlashCommand.parse("/aside hm") else { return XCTFail("/aside alias") }
    guard case .effort("high")? = SlashCommand.parse("/effort high") else { return XCTFail("/effort high") }
    guard case .effort(nil)? = SlashCommand.parse("/effort") else { return XCTFail("/effort") }
    guard case .thinking("off")? = SlashCommand.parse("/thinking off") else { return XCTFail("/thinking off") }
    guard case .thinking(nil)? = SlashCommand.parse("/thinking") else { return XCTFail("/thinking") }
    guard case .budget("0.50")? = SlashCommand.parse("/budget 0.50") else { return XCTFail("/budget 0.50") }
    guard case .budget(nil)? = SlashCommand.parse("/budget") else { return XCTFail("/budget") }
    // Case-insensitive command, original-case argument.
    guard case .effort("XHIGH")? = SlashCommand.parse("/EFFORT XHIGH") else { return XCTFail("/EFFORT") }
    // The existing commands are untouched.
    guard case .status? = SlashCommand.parse("/status") else { return XCTFail("/status") }
    guard case .unknown("ctxx", nil)? = SlashCommand.parse("/ctxx") else { return XCTFail("unknown") }
  }

  func testParseMcp() {
    guard case .mcp(server: nil)? = SlashCommand.parse("/mcp") else { return XCTFail("/mcp") }
    guard case .mcp(server: "docs")? = SlashCommand.parse("/mcp docs") else { return XCTFail("/mcp docs") }
    guard case .mcp(server: "docs")? = SlashCommand.parse("  /MCP   docs  ") else { return XCTFail("case + spaces") }
  }

  func testHelpMentionsTheNewCommands() {
    for needle in ["/context", "/btw", "/effort", "/thinking", "/budget", "ctrl+t", "/mcp [server]"] {
      XCTAssertTrue(SlashCommand.helpText.contains(needle), needle)
    }
  }

  // MARK: Dial arguments

  func testEffortArgument() {
    XCTAssertEqual(EffortArgument.parse(nil), .show)
    XCTAssertEqual(EffortArgument.parse(""), .show)
    XCTAssertEqual(EffortArgument.parse("off"), .off)
    XCTAssertEqual(EffortArgument.parse("High"), .level(.high))
    XCTAssertEqual(EffortArgument.parse("none"), .level(.none), "`none` is a level the model is told; `off` removes the field")
    XCTAssertNil(EffortArgument.parse("ludicrous"))
  }

  func testBudgetArgument() {
    XCTAssertEqual(BudgetArgument.parse(nil), .show)
    XCTAssertEqual(BudgetArgument.parse("off"), .off)
    XCTAssertEqual(BudgetArgument.parse("0.5"), .usd(0.5))
    XCTAssertEqual(BudgetArgument.parse("$2"), .usd(2))
    XCTAssertNil(BudgetArgument.parse("0"))
    XCTAssertNil(BudgetArgument.parse("-1"))
    XCTAssertNil(BudgetArgument.parse("lots"))
  }

  func testLimitsFactAndThinkingNotice() {
    XCTAssertNil(Interactive.limitsFact(budget: nil, maxSteps: nil))
    XCTAssertEqual(Interactive.limitsFact(budget: 0.5, maxSteps: nil), "budget $0.5000")
    XCTAssertEqual(Interactive.limitsFact(budget: nil, maxSteps: 10), "max 10 steps")
    XCTAssertEqual(Interactive.limitsFact(budget: 1, maxSteps: 10), "budget $1.0000 · max 10 steps")
    XCTAssertTrue(Interactive.thinkingNotice(on: true).contains("shown"))
    XCTAssertTrue(Interactive.thinkingNotice(on: false).contains("hidden"))
  }

  // MARK: Interactive flags

  func testInteractiveParsesTheStopConditionFlags() throws {
    let command = try Interactive.parse(["--budget", "0.25", "--max-steps", "12", "--dialect", "messages"])
    XCTAssertEqual(command.budget, 0.25)
    XCTAssertEqual(command.maxSteps, 12)
    XCTAssertEqual(command.dialect, "messages")
    let plain = try Interactive.parse([])
    XCTAssertNil(plain.budget)
    XCTAssertNil(plain.maxSteps)
    XCTAssertEqual(plain.dialect, "auto")
  }

  func testInteractiveRefusesTheFlagsDoRefuses() {
    for (arguments, needle) in [
      (["--max-steps", "0"], "--max-steps"),
      (["--budget", "0"], "--budget"),
      (["--budget", "-2"], "--budget"),
      (["--dialect", "carrier-pigeon"], "dialect"),
    ] {
      XCTAssertThrowsError(try Interactive.parse(arguments), arguments.joined(separator: " ")) { error in
        XCTAssertTrue(Interactive.message(for: error).contains(needle), Interactive.message(for: error))
      }
    }
  }

  // MARK: Resume / fork budget

  /// The review's blocking finding: an in-REPL `/resume` (or `/fork`) under `--budget` carried
  /// the *startup* ceiling into a session that had already spent more, so every turn stopped at
  /// its first step. The resumed configuration's ceiling is this run's remaining allowance on
  /// top of the swapped-in transcript's spend — `Do.budgetCeiling`'s rule — or no ceiling at all.
  func testResumedConfigurationCarriesTheRunsRemainingAllowance() throws {
    var base = Session.Configuration(model: "startup/model", maxCostUSD: 0.2, reasoningEffort: .low)
    base.permissionMode = .acceptEdits
    let loaded = LoadedSession(
      meta: SessionMeta(id: "S-other", updatedAt: Date(), messageCount: 4),
      messages: [], model: "other/model", costUSD: 0.6, turnCount: 2, reasoningEffort: .high)

    // `--budget 0.20`, nothing spent yet in this run → the other session may spend $0.20 more.
    let resumed = Interactive.resumedConfiguration(
      base: base, loaded: loaded, explicitEffort: nil, remainingBudgetUSD: 0.2)
    XCTAssertEqual(try XCTUnwrap(resumed.maxCostUSD), 0.8, accuracy: 1e-9)
    XCTAssertEqual(resumed.model, "other/model", "the model always comes from the transcript")
    XCTAssertEqual(resumed.reasoningEffort, .high, "so does the dial, without --effort")
    XCTAssertEqual(resumed.permissionMode, .acceptEdits, "the REPL's own posture stays")

    // Part of the allowance already spent here, or `/budget` moved it: the remainder travels.
    let partly = Interactive.resumedConfiguration(
      base: base, loaded: loaded, explicitEffort: .low, remainingBudgetUSD: 0.05)
    XCTAssertEqual(try XCTUnwrap(partly.maxCostUSD), 0.65, accuracy: 1e-9)
    XCTAssertEqual(partly.reasoningEffort, .low, "an explicit --effort (already in the base) outranks the transcript's dial")

    // No ceiling on the live session (no flag, or `/budget off`) → none on the resumed one,
    // whatever the startup configuration carried.
    let unbounded = Interactive.resumedConfiguration(
      base: base, loaded: loaded, explicitEffort: nil, remainingBudgetUSD: nil)
    XCTAssertNil(unbounded.maxCostUSD)

    // The allowance rule the call sites (and the task tool's parentBudgetRemaining) share.
    XCTAssertNil(Interactive.remainingBudget(ceiling: nil, spent: 0.3))
    XCTAssertEqual(try XCTUnwrap(Interactive.remainingBudget(ceiling: 0.5, spent: 0.1)), 0.4, accuracy: 1e-9)
    XCTAssertEqual(try XCTUnwrap(Interactive.remainingBudget(ceiling: 0.2, spent: 0.3)), 0, "a crossed ceiling leaves nothing, never a negative allowance")
    // A fork has spent exactly what the live session has, so it lands on the same ceiling.
    let live = (ceiling: 0.75, spent: 0.6)
    let forkCeiling = Do.budgetCeiling(
      Interactive.remainingBudget(ceiling: live.ceiling, spent: live.spent), resumedCostUSD: live.spent)
    XCTAssertEqual(try XCTUnwrap(forkCeiling), live.ceiling, accuracy: 1e-9)
  }

  // MARK: Layouts

  private static let plan: [(text: String, status: String)] = [
    (text: "read", status: "completed"), (text: "edit", status: "in_progress"),
  ]

  func testStatusLinesAlignAndLeaveOutWhatDoesNotApply() {
    var facts = StatusFormat.Facts(
      sessionId: "S-1", name: nil, forkedFrom: nil, model: "test/model", dialectFlag: "auto",
      lastDialect: nil, effort: nil, provider: "openrouter", mode: .default, readOnly: false,
      sandbox: nil, hooks: nil, messages: 0, turns: 0, costUSD: 0, budgetUSD: nil,
      lastPromptTokens: nil, contextLength: nil, tainted: false, plan: nil)
    let bare = StatusFormat.lines(facts)
    XCTAssertEqual(bare.first, "session   S-1")
    XCTAssertTrue(bare.contains("dialect   auto (no turn yet)"))
    XCTAssertTrue(bare.contains("effort    off"))
    XCTAssertTrue(bare.contains("sandbox   off"))
    XCTAssertTrue(bare.contains("hooks     none"))
    XCTAssertTrue(bare.contains("messages  0 · 0 turns"))
    XCTAssertTrue(bare.contains("context   not measured yet — /context estimates it"))
    XCTAssertFalse(bare.contains { $0.hasPrefix("name") || $0.hasPrefix("forked") || $0.hasPrefix("tainted") || $0.hasPrefix("plan") })

    facts.name = "demo"
    facts.forkedFrom = "P-9"
    facts.lastDialect = "messages"
    facts.effort = .high
    facts.mode = .plan
    facts.readOnly = true
    facts.sandbox = "sandbox no-net"
    facts.hooks = "hooks: 2"
    facts.messages = 7
    facts.turns = 3
    facts.costUSD = 0.1234
    facts.budgetUSD = 0.5
    facts.lastPromptTokens = 4000
    facts.contextLength = 8000
    facts.tainted = true
    facts.plan = Self.plan
    let full = StatusFormat.lines(facts)
    // The widest label (`forked from`) sets the column.
    XCTAssertEqual(full[0], "session      S-1")
    XCTAssertEqual(full[1], "name         demo")
    XCTAssertEqual(full[2], "forked from  P-9")
    XCTAssertTrue(full.contains("dialect      messages (last turn; --dialect auto)"))
    XCTAssertTrue(full.contains("effort       high"))
    XCTAssertTrue(full.contains("mode         plan (read-only: --safe)"))
    XCTAssertTrue(full.contains("cost         $0.1234 of $0.5000 budget"))
    XCTAssertTrue(full.contains("context      4,000 tokens of 8,000 (50%) — /context for the breakdown"))
    XCTAssertTrue(full.contains { $0.hasPrefix("tainted      yes") })
    XCTAssertTrue(full.contains("plan         1/2 done"))
    XCTAssertEqual(full.suffix(2).map { $0 }, ["  [x] read", "  [~] edit"])
  }

  func testContextLinesGroupRowsAndSayWhenUnscaled() {
    let unscaled = ContextReport(
      sections: [
        .init(kind: .prompt, name: "pack", bytes: 4000, estTokens: 1000),
        .init(kind: .prompt, name: "Environment", bytes: 400, estTokens: 100),
        .init(kind: .history, name: "user", bytes: 40, estTokens: 10, count: 1),
        .init(kind: .history, name: "assistant", bytes: 0, estTokens: 0, count: 0),
        .init(kind: .history, name: "tool", bytes: 0, estTokens: 0, count: 0),
        .init(kind: .tools, name: "tool definitions", bytes: 2000, estTokens: 500, count: 9),
      ],
      lastPromptTokens: nil, contextLength: 8000, compactionThreshold: 0.8)
    let lines = ContextFormat.lines(unscaled, model: "test/model")
    XCTAssertEqual(lines.first, "context · test/model · window 8,000 tokens · compacts at 80%")
    XCTAssertEqual(lines.filter { $0.hasPrefix("  ") && !$0.hasPrefix("    ") }.map { $0.trimmingCharacters(in: .whitespaces) },
                   ["system prompt", "history", "tools", "total ~1,610 tokens (6.3 KB) — estimates at 4 bytes/token; no request measured yet (a /clear, /rewind or compaction resets the measurement), so the real figure comes with the next turn · ~20% of the window"])
    let pack = try! XCTUnwrap(lines.first { $0.contains("pack") })
    XCTAssertTrue(pack.contains("3.9 KB"), pack)
    XCTAssertTrue(pack.contains("~1,000 tok"), pack)
    XCTAssertTrue(pack.hasSuffix(String(repeating: "▇", count: 20)), "the largest row fills the bar: \(pack)")
    let user = try! XCTUnwrap(lines.first { $0.contains("user") })
    XCTAssertTrue(user.contains("1 msg"), user)
    let tools = try! XCTUnwrap(lines.first { $0.contains("tool definitions") })
    XCTAssertTrue(tools.contains("9 def"), tools)

    let scaled = ContextReport(
      sections: unscaled.sections, lastPromptTokens: 1610, contextLength: 8000, compactionThreshold: 0.8)
    let scaledLines = ContextFormat.lines(scaled, model: "test/model")
    XCTAssertEqual(scaledLines.first, "context · test/model · last request 1,610 tokens of 8,000 (20%) · compacts at 80%")
    XCTAssertTrue(scaledLines.last!.contains("scaled to the last request's prompt tokens"), scaledLines.last!)
  }
}
