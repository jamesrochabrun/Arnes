import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// Plan mode's propose → approve → execute cycle, minus the terminal: `/plan` parsing, the
/// one-key review, the controller that restores the mode, the headless `--permission-mode`
/// flag, and the banner's `mode` fact.
final class PlanModeTests: XCTestCase {

  // MARK: /plan

  func testSlashPlanCarriesTheTask() throws {
    guard case .plan(let task)? = SlashCommand.parse("/plan do x") else {
      return XCTFail("expected .plan")
    }
    XCTAssertEqual(task, "do x")
  }

  func testSlashPlanWithoutATaskIsTheUsageCase() throws {
    guard case .plan(let task)? = SlashCommand.parse("/plan") else {
      return XCTFail("expected .plan")
    }
    XCTAssertNil(task, "a bare /plan asks for the usage line, not a turn")
    guard case .plan(let padded)? = SlashCommand.parse("  /PLAN   ") else {
      return XCTFail("expected .plan (case-insensitive, whitespace tolerant)")
    }
    XCTAssertNil(padded)
  }

  func testHelpTextDocumentsPlan() {
    XCTAssertTrue(SlashCommand.helpText.contains("/plan <task>"))
    XCTAssertTrue(PlanModeController.usage.hasPrefix("usage: /plan <task>"))
  }

  // MARK: The one-key review

  func testReviewKeysParse() {
    XCTAssertEqual(PlanReview.parse(key: "a"), .approve)
    XCTAssertEqual(PlanReview.parse(key: "A"), .approve)
    XCTAssertEqual(PlanReview.parse(key: "r"), .revise)
    XCTAssertEqual(PlanReview.parse(key: "R"), .revise)
    XCTAssertEqual(PlanReview.parse(key: "c"), .cancel)
  }

  func testEscapeEOFAndStrayKeysCancel() {
    XCTAssertEqual(PlanReview.parse(key: "\u{1B}"), .cancel, "Esc cancels")
    XCTAssertEqual(PlanReview.parse(key: nil), .cancel, "EOF cancels")
    XCTAssertEqual(PlanReview.parse(key: "y"), .cancel, "an unlisted key never approves")
    XCTAssertEqual(PlanReview.parse(key: "\n"), .cancel)
    XCTAssertEqual(PlanReview.parse(key: ""), .cancel)
  }

  // MARK: Controller

  func testApproveRestoresThePreviousModeAndYieldsTheApprovalPrompt() {
    let controller = PlanModeController()
    controller.enter(from: .acceptEdits)
    XCTAssertEqual(controller.previousMode, .acceptEdits)
    XCTAssertEqual(
      controller.resolve(.approve),
      .execute(mode: .acceptEdits, prompt: PlanModeController.approvalPrompt))
    XCTAssertEqual(controller.previousMode, .default, "a finished cycle forgets its origin")
  }

  func testApprovalPromptIsOneHarnessAuthoredSentence() {
    let prompt = PlanModeController.approvalPrompt
    XCTAssertTrue(prompt.hasPrefix("[arnes] "), "harness-authored turns carry the [arnes] tag")
    XCTAssertEqual(prompt, "[arnes] Plan approved. Execute it, verifying each step.")
    XCTAssertFalse(prompt.contains("\n"))
  }

  func testCancelRestoresTheModeAndSendsNothing() {
    let controller = PlanModeController()
    controller.enter(from: .bypass)
    XCTAssertEqual(controller.resolve(.cancel), .cancelled(mode: .bypass))
    XCTAssertEqual(controller.previousMode, .default)
  }

  func testReviseStaysInPlanAndKeepsTheRememberedMode() {
    let controller = PlanModeController()
    controller.enter(from: .acceptEdits)
    XCTAssertEqual(controller.resolve(.revise), .revise)
    XCTAssertEqual(controller.previousMode, .acceptEdits, "revising is still the same cycle")
    // The revised plan is approved later — it still lands where the cycle started.
    XCTAssertEqual(
      controller.resolve(.approve),
      .execute(mode: .acceptEdits, prompt: PlanModeController.approvalPrompt))
  }

  func testPlanSetAtStartupRestoresDefault() {
    // `--permission-mode plan`: the session was never in another mode, so approving or
    // cancelling lands on `default`, and "entering" from plan itself changes nothing.
    let controller = PlanModeController()
    controller.enter(from: .plan)
    XCTAssertEqual(controller.previousMode, .default)
    XCTAssertEqual(controller.resolve(.cancel), .cancelled(mode: .default))
    controller.enter(from: .plan)
    XCTAssertEqual(
      controller.resolve(.approve),
      .execute(mode: .default, prompt: PlanModeController.approvalPrompt))
  }

  func testReEnteringFromPlanKeepsTheRememberedMode() {
    // acceptEdits → /plan → revise → /plan again: the second entry happens *from* plan
    // mode and must not overwrite acceptEdits with plan.
    let controller = PlanModeController()
    controller.enter(from: .acceptEdits)
    XCTAssertEqual(controller.resolve(.revise), .revise)
    controller.enter(from: .plan)
    XCTAssertEqual(controller.previousMode, .acceptEdits)
  }

  func testResetForgetsTheRememberedMode() {
    // `/permissions default` (or `/resume`) while a cycle is open leaves plan mode without a
    // review: the mode it came from must not resurface in a later, unrelated plan.
    let controller = PlanModeController()
    controller.enter(from: .acceptEdits)
    controller.reset()
    XCTAssertEqual(controller.previousMode, .default)
    controller.enter(from: .plan) // a later `--permission-mode plan`-style entry has no "before"
    XCTAssertEqual(controller.resolve(.approve), .execute(mode: .default, prompt: PlanModeController.approvalPrompt))
  }

  // MARK: The review's keys go through the type-ahead guard

  func testReviewAnswerIsDeferredWhileTyping() {
    // The review reads its key through `KeyWatcher.readKey(afterQuietFor:)`, the permission
    // prompt's guard: a review letter typed within the quiet interval of type-ahead is text
    // for the input box, not an answer — so the `a` of "add tests too" can't approve a plan.
    let now = Date()
    let justTyped = now.addingTimeInterval(-0.2)
    for key in ["a", "r", "c"] {
      XCTAssertTrue(
        KeyWatcher.shouldDefer(key: key, lastTypeaheadAt: justTyped, now: now, quiet: KeyWatcher.answerQuietInterval),
        "\(key) typed mid-sentence is not an answer")
    }
    let paused = now.addingTimeInterval(-KeyWatcher.answerQuietInterval - 0.1)
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "a", lastTypeaheadAt: paused, now: now, quiet: KeyWatcher.answerQuietInterval))
    // Cancelling must always work: Esc is never deferred, and it parses as cancel.
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "\u{1B}", lastTypeaheadAt: justTyped, now: now, quiet: KeyWatcher.answerQuietInterval))
    XCTAssertEqual(PlanReview.parse(key: "\u{1B}"), .cancel)
  }

  func testOnlyAFinishedTurnIsReviewable() {
    XCTAssertTrue(PlanModeController.isReviewable(.completed), "completed under plan mode is a plan")
    XCTAssertTrue(PlanModeController.isReviewable(.planProposed))
    for other in StopReason.allCases where other != .completed && other != .planProposed {
      XCTAssertFalse(PlanModeController.isReviewable(other), "\(other) has no finished plan to approve")
    }
    XCTAssertFalse(PlanModeController.isReviewable(nil), "a turn that threw before a record is not a plan")
  }

  func testQuestionNamesTheThreeKeys() {
    let question = PlanModeController.question
    XCTAssertTrue(question.contains("[a]pprove"))
    XCTAssertTrue(question.contains("[r]evise"))
    XCTAssertTrue(question.contains("[c]ancel"))
  }

  // MARK: Headless --permission-mode

  func testDoParsesPermissionMode() throws {
    let command = try Do.parse(["plan the refactor", "--permission-mode", "plan"])
    XCTAssertEqual(command.permissionMode, "plan")
    XCTAssertEqual(try parsePermissionMode(command.permissionMode), .plan)
  }

  func testDoWithoutTheFlagIsDefaultMode() throws {
    let command = try Do.parse(["say hi"])
    XCTAssertNil(command.permissionMode)
    XCTAssertEqual(try parsePermissionMode(command.permissionMode), .default)
  }

  func testDoRejectsAnUnknownModeAtParseTime() throws {
    // `Do.validate()` runs as part of parsing, so a typo fails before `run()` — before a
    // provider is resolved, an MCP server started or a notice printed.
    XCTAssertThrowsError(try Do.parse(["say hi", "--permission-mode", "yolo"])) { error in
      XCTAssertTrue(Do.message(for: error).contains("yolo"), "the error names the bad value: \(Do.message(for: error))")
    }
    XCTAssertThrowsError(try parsePermissionMode("yolo"))
  }

  // MARK: --yes stays the one consent switch

  func testDoRefusesAWideningModeWithoutYes() throws {
    // `acceptEdits`/`bypass` pre-approve mutations before the delegate is consulted, so
    // without `--yes` they would run them past the read-only delegate, unsandboxed and
    // under a stderr line claiming the run is read-only. Refused up front instead.
    for mode in ["acceptEdits", "bypass"] {
      XCTAssertThrowsError(try Do.parse(["tidy the repo", "--permission-mode", mode]), mode) { error in
        let message = Do.message(for: error)
        XCTAssertTrue(message.contains("--yes"), "\(mode): the error names the missing consent: \(message)")
        XCTAssertTrue(message.contains(mode), "\(mode): the error names the mode: \(message)")
      }
    }
  }

  func testDoAcceptsAWideningModeWithYes() throws {
    let accepted = try Do.parse(["tidy the repo", "--permission-mode", "acceptEdits", "--yes"])
    XCTAssertEqual(try parsePermissionMode(accepted.permissionMode), .acceptEdits)
    XCTAssertTrue(accepted.yes)
    let bypass = try Do.parse(["tidy the repo", "-y", "--permission-mode", "bypass"])
    XCTAssertEqual(try parsePermissionMode(bypass.permissionMode), .bypass)
  }

  func testDoPlanNeedsNoYes() throws {
    // A dry run is deliberate: plan denies before the delegate, so --yes would change nothing.
    let dryRun = try Do.parse(["plan the refactor", "--permission-mode", "plan"])
    XCTAssertEqual(try parsePermissionMode(dryRun.permissionMode), .plan)
    XCTAssertFalse(dryRun.yes)
    XCTAssertNoThrow(try Do.parse(["plan the refactor", "--permission-mode", "plan", "--safe"]),
      "--safe and plan are both read-only — nothing to contradict")
    XCTAssertNoThrow(try Do.parse(["x", "--permission-mode", "default"]))
  }

  func testDoRefusesSafeWithAWideningMode() throws {
    // `--safe` promises a read-only run; a mode that pre-approves mutations would run them
    // past its delegate exactly as it would past the no-`--yes` one.
    for mode in ["acceptEdits", "bypass"] {
      XCTAssertThrowsError(try Do.parse(["x", "--safe", "--yes", "--permission-mode", mode]), mode) { error in
        XCTAssertTrue(Do.message(for: error).contains("--safe"), "\(mode): \(Do.message(for: error))")
      }
    }
  }

  func testInteractiveRefusesSafeWithAWideningModeToo() throws {
    for mode in ["acceptEdits", "bypass"] {
      XCTAssertThrowsError(try Interactive.parse(["--safe", "--permission-mode", mode]), mode) { error in
        XCTAssertTrue(Do.message(for: error).contains("--safe"), "\(mode): \(Do.message(for: error))")
      }
    }
    XCTAssertNoThrow(try Interactive.parse(["--safe", "--permission-mode", "plan"]))
    XCTAssertNoThrow(try Interactive.parse(["--permission-mode", "bypass"]))
  }

  func testDoRejectsNonPositiveLimitsAtParseTime() throws {
    XCTAssertThrowsError(try Do.parse(["x", "--max-steps", "0"]))
    XCTAssertThrowsError(try Do.parse(["x", "--max-steps", "-1"]))
    XCTAssertThrowsError(try Do.parse(["x", "--timeout", "0"]))
    XCTAssertNoThrow(try Do.parse(["x", "--max-steps", "1", "--timeout", "0.5"]))
  }

  func testDoRefusesPanelWithAPermissionMode() throws {
    // A panel never builds the configuration the flag feeds: candidates run unattended in
    // their snapshots, so `--permission-mode plan --panel 2` would be a "dry run" that
    // applies the winner's diff. Refused for every mode, including `default` spelled out.
    for mode in ["plan", "default", "acceptEdits", "bypass"] {
      XCTAssertThrowsError(try Do.parse(["x", "--yes", "--panel", "2", "--permission-mode", mode]), mode) { error in
        XCTAssertTrue(Do.message(for: error).contains("--panel"), "\(mode): \(Do.message(for: error))")
      }
    }
    XCTAssertNoThrow(try Do.parse(["x", "--yes", "--panel", "2"]), "a panel without the flag parses as before")
  }

  func testDoAndInteractiveShareTheModeSpelling() throws {
    // The same parser serves both, so `acceptEdits` (camelCase raw value) works on each
    // (headless with the `--yes` a widening mode needs).
    let headless = try Do.parse(["x", "--permission-mode", "acceptEdits", "--yes"])
    let repl = try Interactive.parse(["--permission-mode", "acceptEdits"])
    XCTAssertEqual(try parsePermissionMode(headless.permissionMode), .acceptEdits)
    XCTAssertEqual(try parsePermissionMode(repl.permissionMode), .acceptEdits)
  }

  // MARK: Banner

  func testBannerShowsANonDefaultMode() {
    let banner = Header.banner(version: "0.0", model: "test/model", dialect: "auto", mode: "plan")
    XCTAssertTrue(banner.contains("mode plan"), "\(banner)")
  }

  func testBannerOmitsTheDefaultMode() {
    let banner = Header.banner(version: "0.0", model: "test/model", dialect: "auto")
    XCTAssertFalse(banner.contains("· mode "), "\(banner)")
    XCTAssertTrue(banner.contains("test/model"))
  }
}
