import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// X6 — `arnes review`: the flags and their parse-time refusals, the `--json` document's keys,
/// and the text report's rendering and footer. No runtime, no model.
final class ReviewCommandTests: XCTestCase {
  private func assertValidationError(_ arguments: [String], contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try ReviewCommand.parse(arguments), arguments.joined(separator: " "), file: file, line: line) { error in
      let message = ReviewCommand.message(for: error)
      XCTAssertTrue(message.contains(needle), "\(arguments.joined(separator: " ")): \(message)", file: file, line: line)
    }
  }

  // MARK: Flags

  func testReviewIsARootSubcommandNamedReview() {
    XCTAssertTrue(Arnes.configuration.subcommands.contains { $0 == ReviewCommand.self })
    XCTAssertEqual(ReviewCommand.configuration.commandName, "review")
  }

  func testDefaultsToUncommittedWithTwentySteps() throws {
    let command = try ReviewCommand.parse([])
    XCTAssertEqual(command.target, .uncommitted)
    XCTAssertNil(command.maxSteps, "run() applies the default of 20")
    XCTAssertFalse(command.json)
    XCTAssertFalse(command.allowRun)
    XCTAssertFalse(command.noSandbox)
    XCTAssertNil(try ReviewCommand.parseFailOn(command.failOn))

    XCTAssertEqual(try ReviewCommand.parse(["--uncommitted"]).target, .uncommitted)
    XCTAssertEqual(try ReviewCommand.parse(["--base", "origin/main"]).target, .base("origin/main"))
    XCTAssertEqual(try ReviewCommand.parse(["--commit", "abc123"]).target, .commit("abc123"))
    let full = try ReviewCommand.parse([
      "--base", "main", "--json", "--fail-on", "High", "--focus", "the cache", "-m", "cheap/model",
      "--max-steps", "5", "--budget", "0.05", "--verbose", "-C", "/tmp",
    ])
    XCTAssertEqual(full.target, .base("main"))
    XCTAssertTrue(full.json)
    XCTAssertEqual(try ReviewCommand.parseFailOn(full.failOn), .high, "case-insensitive")
    XCTAssertEqual(full.focus, "the cache")
    XCTAssertEqual(full.model, "cheap/model")
    XCTAssertEqual(full.maxSteps, 5)
    XCTAssertEqual(full.budget, 0.05)
    XCTAssertTrue(full.verbose)
    XCTAssertEqual(full.workingDirectoryPath, "/tmp")
  }

  func testMutuallyExclusiveTargetsAndBadValuesAreUsageErrors() {
    assertValidationError(["--base", "main", "--commit", "abc"], contains: "--base and --commit don't combine")
    assertValidationError(["--uncommitted", "--base", "main"], contains: "--uncommitted and --base/--commit don't combine")
    assertValidationError(["--fail-on", "bogus"], contains: "unknown --fail-on 'bogus'")
    assertValidationError(["--max-steps", "0"], contains: "--max-steps must be at least 1")
  }

  func testAllowRunRefusesNoSandboxAtParseTime() {
    assertValidationError(["--allow-run", "--no-sandbox"], contains: "--allow-run needs the OS sandbox")
    // Each alone parses: the sandbox requirement for --allow-run is checked in run(), against
    // the platform and the provider's configuration.
    XCTAssertTrue(try ReviewCommand.parse(["--allow-run"]).allowRun)
    XCTAssertTrue(try ReviewCommand.parse(["--no-sandbox"]).noSandbox)
    // run()'s two refusals name the actual reason: no backend on this platform (checked before
    // the git probe, which a configured sandbox would otherwise fail closed), or a config that
    // switched the backend off.
    XCTAssertTrue(ReviewCommand.allowRunRefusal(supported: false).contains("this platform can't enforce one"))
    XCTAssertTrue(ReviewCommand.allowRunRefusal(supported: true).contains("`sandbox` block disables it"))
    XCTAssertTrue(ReviewCommand.allowRunRefusal(supported: true).hasPrefix("--allow-run needs the OS sandbox"))
  }

  func testAHomeOrAncestorRootIsRecognized() {
    let home = "/Users/me"
    XCTAssertTrue(ReviewCommand.isHomeOrAncestor(URL(fileURLWithPath: "/Users/me"), home: home))
    XCTAssertTrue(ReviewCommand.isHomeOrAncestor(URL(fileURLWithPath: "/Users"), home: home))
    XCTAssertTrue(ReviewCommand.isHomeOrAncestor(URL(fileURLWithPath: "/"), home: home))
    XCTAssertFalse(ReviewCommand.isHomeOrAncestor(URL(fileURLWithPath: "/Users/me/project"), home: home))
    XCTAssertFalse(ReviewCommand.isHomeOrAncestor(URL(fileURLWithPath: "/Users/meat"), home: home), "a prefix is not an ancestor")
    XCTAssertFalse(ReviewCommand.isHomeOrAncestor(URL(fileURLWithPath: "/tmp/x"), home: home))
  }

  // MARK: --json

  private static let findings = ReviewFindings(
    summary: "One real problem.",
    findings: [
      ReviewFinding(
        file: "src/a.swift", line: 42, severity: .high, category: "correctness",
        summary: "off by one", failureScenario: "one item → nothing processed", confidence: .confirmed),
      ReviewFinding(
        file: "src/b.swift", line: nil, severity: .low, category: "error-handling",
        summary: "error swallowed", failureScenario: "a failed write reads as success", confidence: .plausible),
    ])

  private static let built = ReviewDiff.Built(
    root: "/repo", diff: "diff --git a/src/a.swift b/src/a.swift\n+x", files: ["src/a.swift", "new.txt"],
    omittedChars: 0, untrackedIncluded: ["new.txt"], skipped: ["big.bin (binary, looks like unknown)"])

  func testJSONReportHasTheDocumentedSnakeCaseKeys() throws {
    let report = ReviewReport(
      target: .base("origin/main"), built: Self.built, findings: Self.findings, model: "cheap/model",
      costUSD: 0.0123, steps: 4, stopReason: "completed", error: nil)
    let line = try JSONOut.line(report)
    XCTAssertEqual(line, """
      {"cost_usd":0.0123,"error":null,"files":["src/a.swift","new.txt"],"findings":[{"category":"correctness","confidence":"confirmed","failure_scenario":"one item → nothing processed","file":"src/a.swift","line":42,"severity":"high","summary":"off by one"},{"category":"error-handling","confidence":"plausible","failure_scenario":"a failed write reads as success","file":"src/b.swift","line":null,"severity":"low","summary":"error swallowed"}],"model":"cheap/model","root":"/repo","skipped":["big.bin (binary, looks like unknown)"],"steps":4,"stop_reason":"completed","summary":"One real problem.","target":{"kind":"base","ref":"origin/main"},"truncated_diff":false,"type":"review","untracked_included":["new.txt"]}
      """)

    // No findings object (the model never produced a valid one): the keys are still present.
    let none = ReviewReport(
      target: .uncommitted, built: Self.built, findings: nil, model: "m", costUSD: 0.5, steps: 20,
      stopReason: "structured_output_failed", error: nil)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try JSONOut.line(none).utf8)) as? [String: Any])
    XCTAssertTrue(object["findings"] is NSNull)
    XCTAssertTrue(object["summary"] is NSNull)
    XCTAssertEqual((object["target"] as? [String: Any])?["kind"] as? String, "uncommitted")
    XCTAssertTrue((object["target"] as? [String: Any])?["ref"] is NSNull)
    XCTAssertEqual(object["stop_reason"] as? String, "structured_output_failed")
    XCTAssertEqual(
      Set(object.keys),
      ["type", "target", "root", "files", "untracked_included", "skipped", "truncated_diff", "summary", "findings",
       "model", "cost_usd", "steps", "stop_reason", "error"])

    let failed = ReviewReport(
      target: .commit("abc"), built: Self.built, findings: nil, model: "m", costUSD: 0, steps: 0,
      stopReason: "error", error: "boom")
    XCTAssertTrue(try JSONOut.line(failed).contains("\"error\":\"boom\""))
  }

  // MARK: Text

  private static func runResult(stopReason: StopReason = .completed, structured: Bool = true) -> RunResult {
    var record = RunRecord(task: "t", model: "cheap/model", dialect: "chat", packFamily: "generic")
    record.sessionId = "S-1"
    record.steps = 4
    record.toolCalls = 2
    record.costUSD = 0.0123
    record.finished = true
    record.stopReason = stopReason
    return RunResult(result: AgentResult(text: "prose reply", record: record, sessionId: "S-1", durationMs: 7), costEstimated: false)
  }

  func testTextReportRendersFindingsAndTheFooter() {
    let text = ReviewCommand.textReport(findings: Self.findings, prose: "prose reply", result: Self.runResult())
    XCTAssertEqual(text, """
      One real problem.

      ✘ high src/a.swift:42 — off by one [correctness]
          scenario: one item → nothing processed
      · low src/b.swift — error swallowed (plausible) [error-handling]
          scenario: a failed write reads as success

      [2 findings (1 high, 1 low) · $0.0123 · 4 steps · cheap/model]
      """)
    let clean = ReviewCommand.textReport(
      findings: ReviewFindings(summary: "Looks right.", findings: []), prose: "p", result: Self.runResult())
    XCTAssertTrue(clean.hasSuffix("no findings\n\n[0 findings · $0.0123 · 4 steps · cheap/model]"), clean)
    let one = ReviewCommand.footer(
      findings: ReviewFindings(summary: "", findings: [Self.findings.findings[0]]), result: Self.runResult())
    XCTAssertEqual(one, "\n[1 finding (1 high) · $0.0123 · 4 steps · cheap/model]")
  }

  func testTextReportWithoutAFindingsObjectShowsTheProseUnderANotice() {
    let text = ReviewCommand.textReport(
      findings: nil, prose: "I think the loop is off by one.", result: Self.runResult(stopReason: .structuredOutputFailed))
    XCTAssertEqual(text, """
      review did not produce structured findings — the reviewer's reply:

      I think the loop is off by one.

      [no findings object (structured_output_failed) · $0.0123 · 4 steps · cheap/model]
      """)
  }

  // MARK: Exit codes, end to end over the table

  func testExitCodeOrderRunFirstThenFailOn() {
    // A clean run with a high finding and --fail-on high → 2; without --fail-on → 0.
    let clean = Self.runResult()
    XCTAssertEqual(ArnesExit.code(for: clean, failOnDenied: false), 0)
    XCTAssertEqual(Review.exitCode(findings: Self.findings, failOn: .high), 2)
    XCTAssertEqual(Review.exitCode(findings: Self.findings, failOn: nil), 0)
    // A run that stopped short exits 3 whatever it found — the review's verdict is not consulted.
    XCTAssertEqual(ArnesExit.code(for: Self.runResult(stopReason: .structuredOutputFailed), failOnDenied: false), 3)
    XCTAssertEqual(ArnesExit.code(for: Self.runResult(stopReason: .maxSteps), failOnDenied: false), 3)
    XCTAssertEqual(ArnesExit.code(for: Self.runResult(stopReason: .error), failOnDenied: false), 1)
    XCTAssertEqual(ArnesExit.code(for: Self.runResult(stopReason: .interrupted), failOnDenied: false, signal: .sigterm), 143)
  }
}
