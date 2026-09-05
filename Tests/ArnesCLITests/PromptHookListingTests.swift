import ArnesKit
import XCTest
@testable import arnes

/// H5: how a `type: prompt` hook reads in `arnes hooks` and in the trust prompt's listing —
/// the type per hook, the model it would run on, and a loud mark when none resolves.
final class PromptHookListingTests: XCTestCase {
  private func strip(_ rows: [String]) -> String {
    rows.joined(separator: "\n").replacingOccurrences(
      of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
  }

  func testHooksListNamesTheTypeAndTheModelAPromptHookRunsOn() {
    let command = LoadedHook(
      definition: HookDefinition(event: .preToolUse, matcher: "bash", command: "exit 0"), trust: .trusted)
    let ownModel = LoadedHook(
      definition: HookDefinition(event: .preToolUse, matcher: "bash", prompt: "Safe? $ARGUMENTS", model: "tiny"),
      trust: .trusted)
    let defaulted = LoadedHook(
      definition: HookDefinition(event: .stop, prompt: "Is the task done?", id: "done-check"), trust: .trusted)

    let commandRows = strip(HooksFormat.rows(for: command, defaultPromptModel: "judge/model"))
    XCTAssertTrue(commandRows.contains("bash · command · 30s · user"), commandRows)
    XCTAssertTrue(commandRows.hasSuffix("  exit 0"), commandRows)

    let ownRows = strip(HooksFormat.rows(for: ownModel, defaultPromptModel: "judge/model"))
    XCTAssertTrue(ownRows.contains("bash · prompt tiny · 30s · user"), ownRows)
    XCTAssertTrue(ownRows.hasSuffix("  Safe? $ARGUMENTS"), "the prompt is the body, there is no command: \(ownRows)")

    let defaultedRows = strip(HooksFormat.rows(for: defaulted, defaultPromptModel: "judge/model"))
    XCTAssertTrue(defaultedRows.contains("Stop done-check"), defaultedRows)
    XCTAssertTrue(defaultedRows.contains("always · prompt judge/model"), "no `model` → the provider's bashJudge: \(defaultedRows)")

    // Neither a `model` nor a `bashJudge`: the listing says the hook is unusable.
    let unusable = strip(HooksFormat.rows(for: defaulted, defaultPromptModel: nil))
    XCTAssertTrue(unusable.contains("prompt — no model: set \"model\" or the provider's bashJudge"), unusable)
  }

  func testTrustListingShowsAPromptHookAsAPromptNotACommand() {
    let content = ProjectContent(hooks: [
      HookDefinition(event: .preToolUse, matcher: "bash", command: "./scripts/guard.sh", source: .project),
      HookDefinition(event: .preToolUse, matcher: "bash", prompt: "Does this delete anything?", source: .project),
    ])
    let rows = strip(ProjectTrustGate.listing(content))
    XCTAssertTrue(rows.contains("hook   PreToolUse ./scripts/guard.sh  ./scripts/guard.sh — needs `arnes hooks trust` too"), rows)
    XCTAssertTrue(rows.contains("hook   PreToolUse Does this delete anything?  prompt: Does this delete anything? — needs"), rows)
  }
}
