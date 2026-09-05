import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// The hook decision contract: Claude Code's stdout JSON and exit-code semantics, parsed
/// and merged so a hook can narrow the deterministic layer but never widen it.
final class HookOutcomeTests: XCTestCase {

  // MARK: Exit codes

  func testExitTwoDeniesWithOutputAsReasonAndOtherFailuresAreErrorsNotDenials() {
    let deny = HookOutcome.parse(exit: 2, output: "no shell here\n", event: .preToolUse)
    XCTAssertEqual(deny.decision, .deny(reason: "no shell here"))
    let silent = HookOutcome.parse(exit: 2, output: "", event: .preToolUse)
    XCTAssertEqual(silent.decision, .deny(reason: "blocked by a PreToolUse hook"))

    let error = HookOutcome.parse(exit: 1, output: "linter crashed", event: .preToolUse)
    XCTAssertEqual(error.decision, .none)
    XCTAssertEqual(error.errors, ["exited 1: linter crashed"])
    let missing = HookOutcome.parse(exit: 127, output: "sh: my-guard: not found", event: .preToolUse)
    XCTAssertEqual(missing.decision, .none)
    XCTAssertEqual(missing.errors.count, 1)
  }

  func testExitZeroPlainTextIsFeedbackAfterTheFactAndNothingBefore() {
    let post = HookOutcome.parse(exit: 0, output: "formatted 3 files\n", event: .postToolUse)
    XCTAssertEqual(post.feedback, "formatted 3 files")
    XCTAssertEqual(post.decision, .none)
    let pre = HookOutcome.parse(exit: 0, output: "checked\n", event: .preToolUse)
    XCTAssertEqual(pre, .none)
  }

  func testExitTwoAfterTheFactFeedsBackInsteadOfBlocking() {
    let post = HookOutcome.parse(exit: 2, output: "tests failed: 3", event: .postToolUse)
    XCTAssertEqual(post.decision, .none)
    XCTAssertEqual(post.feedback, "tests failed: 3")
  }

  func testDelegationEventsBlockBeforeTheSpawnAndFeedBackAfterIt() {
    // SubagentStart gates a delegation the way PreToolUse gates a call…
    let blocked = HookOutcome.parse(exit: 2, output: "no git push tasks\n", event: .subagentStart)
    XCTAssertEqual(blocked.decision, .deny(reason: "no git push tasks"))
    let silent = HookOutcome.parse(exit: 2, output: "", event: .subagentStart)
    XCTAssertEqual(silent.decision, .deny(reason: "blocked by a SubagentStart hook"))
    XCTAssertEqual(HookOutcome.parse(exit: 0, output: "checked\n", event: .subagentStart), .none)
    let denyJSON = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"SubagentStart","permissionDecision":"deny","permissionDecisionReason":"agent is disabled"}}
      """, event: .subagentStart)
    XCTAssertEqual(denyJSON.decision, .deny(reason: "agent is disabled"))
    let legacy = HookOutcome.parse(exit: 0, output: #"{"decision":"block","reason":"nope"}"#, event: .subagentStart)
    XCTAssertEqual(legacy.decision, .deny(reason: "nope"))

    // …while SubagentStop is after the fact: its output rides back with the report.
    let feedback = HookOutcome.parse(exit: 0, output: "REVIEWED\n", event: .subagentStop)
    XCTAssertEqual(feedback.feedback, "REVIEWED")
    XCTAssertEqual(feedback.decision, .none)
    let late = HookOutcome.parse(exit: 2, output: "report is thin", event: .subagentStop)
    XCTAssertEqual(late.decision, .none, "a subagent that already ran cannot be un-run")
    XCTAssertEqual(late.feedback, "report is thin")
    let stopJSON = HookOutcome.parse(exit: 0, output: """
      {"decision":"block","reason":"missing file list","continue":false,"stopReason":"ask again"}
      """, event: .subagentStop)
    XCTAssertEqual(stopJSON.feedback, "missing file list")
    XCTAssertFalse(stopJSON.continueRun)
    XCTAssertEqual(stopJSON.stopReason, "ask again")

    // Which events gate is the one switch the rest of the contract keys on.
    XCTAssertEqual(
      HookEvent.allCases.filter(\.isGate),
      [.preToolUse, .subagentStart, .userPromptSubmit, .preCompact, .permissionRequest])
    // Stop can block without being a gate: exit 2 means "don't stop yet", but a hook that
    // couldn't run must never force the model to keep working.
    XCTAssertEqual(
      Set(HookEvent.allCases.filter(\.canBlock)),
      [.stop, .preToolUse, .subagentStart, .userPromptSubmit, .preCompact, .permissionRequest])
    XCTAssertEqual(HookEvent.allCases.filter(\.matchesAgentName), [.subagentStart, .subagentStop])
  }

  // MARK: Claude Code JSON

  func testClaudeCodeSampleJSONParsesToDenyAskAndAllow() {
    let deny = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"protected file"}}
      """, event: .preToolUse)
    XCTAssertEqual(deny.decision, .deny(reason: "protected file"))

    let ask = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"touches CI"}}
      """, event: .preToolUse)
    XCTAssertEqual(ask.decision, .ask(reason: "touches CI"))

    let allow = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","updatedInput":{"command":"git status --short"},"additionalContext":"repo is clean"},"systemMessage":"auto-approved by policy"}
      """, event: .preToolUse)
    XCTAssertEqual(allow.decision, .allow)
    XCTAssertEqual(allow.updatedInput, ["command": .string("git status --short")])
    XCTAssertEqual(allow.additionalContext, ["repo is clean"])
    XCTAssertEqual(allow.systemMessages, ["auto-approved by policy"])

    // Legacy top-level spelling.
    let legacy = HookOutcome.parse(exit: 0, output: #"{"decision":"block","reason":"nope"}"#, event: .preToolUse)
    XCTAssertEqual(legacy.decision, .deny(reason: "nope"))
  }

  func testPostToolUseBlockReasonAndContinueFalse() {
    let outcome = HookOutcome.parse(exit: 0, output: """
      {"decision":"block","reason":"lint errors remain","continue":false,"stopReason":"fix lint first","hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"ran swiftlint"}}
      """, event: .postToolUse)
    XCTAssertEqual(outcome.feedback, "lint errors remain")
    XCTAssertEqual(outcome.additionalContext, ["ran swiftlint"])
    XCTAssertFalse(outcome.continueRun)
    XCTAssertEqual(outcome.stopReason, "fix lint first")
  }

  /// `hookSpecificOutput.decision` as a bare string — the shape a hand-written
  /// PermissionRequest hook ends up with — reads as the behavior; the object form is unchanged.
  func testStringFormDecisionOnPermissionRequestIsReadAsTheBehavior() {
    let deny = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"deny"},"reason":"not on Fridays"}
      """, event: .permissionRequest)
    XCTAssertEqual(deny.decision, .deny(reason: "not on Fridays"))
    let denySilent = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"deny"}}
      """, event: .permissionRequest)
    XCTAssertEqual(denySilent.decision, .deny(reason: "blocked by a PermissionRequest hook"))
    let allow = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"allow"}}
      """, event: .permissionRequest)
    XCTAssertEqual(allow.decision, .allow)
    XCTAssertNil(allow.updatedInput)
    let ask = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":"ask"}}
      """, event: .permissionRequest)
    XCTAssertEqual(ask.decision, .ask(reason: nil))
    // Case doesn't matter, and the string form is accepted where the PreToolUse spelling is.
    let upper = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"decision":"DENY"}}
      """, event: .preToolUse)
    XCTAssertEqual(upper.decision, .deny(reason: "blocked by a PreToolUse hook"))

    // The object form still carries the message and the rewrite.
    let object = HookOutcome.parse(exit: 0, output: """
      {"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow","message":"fine","updatedInput":{"command":"ls"}}}}
      """, event: .permissionRequest)
    XCTAssertEqual(object.decision, .allow)
    XCTAssertEqual(object.updatedInput, ["command": .string("ls")])
    // Anything else in that slot is malformed JSON — text, never a decision.
    let number = HookOutcome.parse(exit: 0, output: #"{"hookSpecificOutput":{"decision":42}}"#, event: .permissionRequest)
    XCTAssertEqual(number.decision, .none)
  }

  /// The top-level `decision: "deny"` spelling is read like `"block"` on every event that can
  /// block — so a script that says deny where Claude Code's docs say block still gates.
  func testTopLevelDenySpellingBlocksOnTheGatingEventsAndStop() {
    for event in HookEvent.allCases where event.canBlock {
      let outcome = HookOutcome.parse(exit: 0, output: #"{"decision":"deny","reason":"nope"}"#, event: event)
      XCTAssertEqual(outcome.decision, .deny(reason: "nope"), event.rawValue)
      let blocked = HookOutcome.parse(exit: 0, output: #"{"decision":"block","reason":"nope"}"#, event: event)
      XCTAssertEqual(blocked.decision, .deny(reason: "nope"), event.rawValue)
    }
    // After the fact there is nothing to gate: the reason is feedback, not a decision.
    let late = HookOutcome.parse(exit: 0, output: #"{"decision":"deny","reason":"nope"}"#, event: .postToolUse)
    XCTAssertEqual(late.decision, .none)
  }

  func testMalformedJSONOnExitZeroIsTreatedAsTextNeverAsAnAllow() {
    let outcome = HookOutcome.parse(exit: 0, output: #"{"hookSpecificOutput": {"permissionDecision": "allow""#, event: .preToolUse)
    XCTAssertEqual(outcome.decision, .none)
    XCTAssertNil(outcome.updatedInput)
  }

  // MARK: Merge

  func testMergeKeepsTheStrictestDecisionAndConcatenatesContext() {
    var merged = HookOutcome(decision: .allow, additionalContext: ["a"])
    merged.merge(HookOutcome(decision: .ask(reason: "why"), additionalContext: ["b"], feedback: "f1"))
    XCTAssertEqual(merged.decision, .ask(reason: "why"))
    merged.merge(HookOutcome(decision: .deny(reason: "no")))
    XCTAssertEqual(merged.decision, .deny(reason: "no"))
    merged.merge(HookOutcome(decision: .allow, feedback: "f2", errors: ["e"]))
    XCTAssertEqual(merged.decision, .deny(reason: "no"), "a later allow never lifts an earlier deny")
    XCTAssertEqual(merged.additionalContext, ["a", "b"])
    XCTAssertEqual(merged.feedback, "f1\nf2")
    XCTAssertEqual(merged.errors, ["e"])
    merged.merge(HookOutcome(continueRun: false, stopReason: "stop"))
    XCTAssertFalse(merged.continueRun)
    XCTAssertEqual(merged.stopReason, "stop")
  }

  // MARK: Engine

  func testEngineMergesSeveralMatchingHooksAndStopsAtTheFirstDeny() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, command: #"echo '{"hookSpecificOutput":{"permissionDecision":"allow"}}'"#),
      HookDefinition(event: .preToolUse, command: "echo denied here >&2; exit 2"),
      HookDefinition(event: .preToolUse, command: "echo SHOULD_NOT_RUN; exit 2"),
    ])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: "{}")
    XCTAssertEqual(outcome.decision, .deny(reason: "denied here"))
  }

  func testEngineExitOneWithFailClosedDenies() async {
    let engine = HookEngine(hooks: [
      HookDefinition(event: .preToolUse, command: "exit 1", failClosed: true),
    ])
    let outcome = await engine.preToolUse(tool: "bash", argumentsJSON: "{}")
    let reason = outcome.blockReason ?? ""
    XCTAssertTrue(reason.contains("exited 1"), reason)
    XCTAssertTrue(reason.contains("failClosed"), reason)
  }
}
