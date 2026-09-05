import XCTest
@testable import ArnesKit

/// A9 — the shell-proof delegation probe, `evals/subagents/04-judgment-search-delegates.json`.
///
/// Batch 13 found that both models solved the wide- and noisy-search tasks alone, with one
/// grep pipeline, and failed only the "an `explore` run must exist" half of the check — so the
/// delegation text was unproven, not disproven: the tasks were the kind of search a regex
/// settles. This task is built so a regex cannot: exactly one of 240 support tickets asks to
/// stop a subscription, every ticket carries cancel-family vocabulary, the decoys use it in
/// eight other senses (negated, other-object, hypothetical, past, undo, third-party, the
/// opposite intent, incidental), some read positively with no negation word, and the positive
/// asks without the word `cancel`. Reading the files is the only way; reading 240 files is the
/// wide, noisy work the pack says to hand to `explore`. These pins make "shell-proof" a fact —
/// the suite's shape, the generator's own rule, a fixed list of plausible one-shot pipelines
/// none of which returns the positive alone, determinism, and the setup's wall time.
final class DelegationProbeTests: XCTestCase {
  private static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  static let suiteIDs = [
    "wide-search-delegates", "trivial-task-stays-direct", "noisy-search-delegates", "judgment-search-delegates",
    "context-search-delegates",
  ]
  static let taskID = "judgment-search-delegates"
  /// The id the check hardcodes — the file name without `.txt`, one of the two id shapes.
  static let positiveID = "TK-1966"
  static let positiveFile = "tickets/TK-1966.txt"
  static let fileCount = 240
  /// The cancel-family stems every ticket carries at least one of (case-insensitive).
  static let cancelFamily = ["cancel", "terminat", "unsubscrib", "close my account", "end my", "stop billing"]
  /// The generator's own rule for the positive: the one sentence that asks to stop the plan.
  static let positiveSentence = "Please end my plan at the end of this billing cycle and do not renew it"

  private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-a9-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func loadTask() throws -> EvalTask {
    let suite = try EvalSuite.load(path: Self.repoRoot.appendingPathComponent("evals/subagents").path)
    XCTAssertEqual(suite.tasks.map(\.id), Self.suiteIDs, "the suite is loaded sorted by file name; 05- sorts last")
    return try XCTUnwrap(suite.tasks.first { $0.id == Self.taskID })
  }

  /// Runs the task's setup the way a trial does (`/bin/sh -c`, cwd = the workdir) with `HOME`
  /// pointed at the workdir, so `.runs-before` never reads the real `~/.arnes`.
  private func runSetup(_ task: EvalTask, into dir: URL) throws -> (exit: Int32, output: String, seconds: TimeInterval) {
    let setup = try XCTUnwrap(task.setup)
    let start = Date()
    let result = EvalRunner.bash(setup, cwd: dir, timeoutSeconds: 120, environment: ["HOME": dir.path])
    return (result.exit, result.output, Date().timeIntervalSince(start))
  }

  private func ticketFiles(in dir: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("tickets").path).sorted()
  }

  // MARK: 1. the suite's shape

  func testSuiteHasFourTasksAndTheProbeCheckHasBothHalves() throws {
    let task = try loadTask()
    XCTAssertEqual(task.id, Self.taskID)
    XCTAssertEqual(task.timeoutSeconds, 600, "the agent's budget, like task 03; setup and check are capped at 60 s by the runner")
    // The answer half and the explore half, in task 03's shape: the ARNES_SESSION_ID strict path
    // first, the .runs-before line-delta fallback second.
    for needle in ["ARNES_SESSION_ID", "parentSessionId", ".runs-before", #""agent":"explore""#, "= \(Self.positiveID)"] {
      XCTAssertTrue(task.check.contains(needle), "the check carries \(needle)")
    }
    let sessionPath = task.check.range(of: "ARNES_SESSION_ID")!.lowerBound
    let fallbackPath = task.check.range(of: ".runs-before")!.lowerBound
    XCTAssertLessThan(sessionPath, fallbackPath, "the race-free path comes first")
    let setup = try XCTUnwrap(task.setup)
    XCTAssertFalse(setup.contains("RANDOM"), "deterministic: no $RANDOM")
    XCTAssertFalse(setup.contains("shuf"), "deterministic: no shuf")
    XCTAssertFalse(setup.contains("$(date"), "deterministic: no clock")
    XCTAssertTrue(setup.hasSuffix("> .runs-before"), "the setup snapshots the fallback last")
    XCTAssertFalse(setup.contains(Self.positiveID), "the answer is derived by the generator, never spelled in the setup")
    // The prompt states the directory, the count, what exactly one ticket does and where the
    // answer goes — and never hints at delegation (that is the pack's job).
    XCTAssertTrue(task.prompt.contains("tickets/"))
    XCTAssertTrue(task.prompt.contains("two hundred and forty"))
    XCTAssertTrue(task.prompt.contains("Exactly one"))
    XCTAssertTrue(task.prompt.contains("answer.txt"))
    for hint in ["delegat", "subagent", "explore", "parallel"] {
      XCTAssertFalse(task.prompt.lowercased().contains(hint), "the prompt must not hint at delegation: \(hint)")
    }
  }

  // MARK: 2. the generator's own rule (+ 5. the wall time)

  func testSetupMakesTheTreeTheGeneratorPromises() throws {
    let task = try loadTask()
    let dir = try tempDirectory("tree")
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try runSetup(task, into: dir)
    XCTAssertEqual(run.exit, 0, run.output)
    XCTAssertLessThan(run.seconds, 20, "the runner caps a setup at 60 s; this one must stay far under it")

    let tickets = dir.appendingPathComponent("tickets")
    let files = try ticketFiles(in: dir)
    XCTAssertEqual(files.count, Self.fileCount)
    XCTAssertEqual(files.filter { $0.hasPrefix("TK-") }.count, Self.fileCount / 2, "two id shapes, half each")
    XCTAssertEqual(files.filter { $0.hasPrefix("cs-") }.count, Self.fileCount / 2)

    var positives: [String] = []
    var totalBytes = 0
    for file in files {
      XCTAssertTrue(file.hasSuffix(".txt"), file)
      let data = try Data(contentsOf: tickets.appendingPathComponent(file))
      XCTAssertGreaterThan(data.count, 200, "\(file) is not an ordinary-looking ticket")
      totalBytes += data.count
      let text = try XCTUnwrap(String(data: data, encoding: .utf8))
      let lower = text.lowercased()
      XCTAssertTrue(
        Self.cancelFamily.contains { lower.contains($0) },
        "\(file) carries no cancel-family term — presence must be uninformative, so every file has one")
      if text.contains(Self.positiveSentence) { positives.append(file) }
    }
    XCTAssertEqual(positives, ["\(Self.positiveID).txt"], "exactly one ticket asks to stop the subscription")
    let positive = try String(contentsOf: tickets.appendingPathComponent("\(Self.positiveID).txt"), encoding: .utf8)
    XCTAssertNil(positive.range(of: "cancel", options: .caseInsensitive), "the positive avoids the most obvious token")
    XCTAssertGreaterThan(totalBytes, 60_000, "cat tickets/* must overflow the 30 000-char tool-result cap")
    XCTAssertLessThan(totalBytes, 150_000, "and stay a few explore fan-outs' worth of reading")

    // The check's literal id is the positive's file stem — the two cannot drift apart.
    let idRule = try NSRegularExpression(pattern: #"= ([A-Za-z]+-[0-9]+) &&"#)
    let check = task.check as NSString
    let match = try XCTUnwrap(idRule.firstMatch(in: task.check, range: NSRange(location: 0, length: check.length)))
    XCTAssertEqual(check.substring(with: match.range(at: 1)), Self.positiveID)

    // Nothing but the tickets and the fallback snapshot: no truth table in the workdir.
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), [".runs-before", "tickets"])
    XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".runs-before"), encoding: .utf8), "0\n")
  }

  // MARK: 3. shell-proofness — the item's contract

  /// A fixed list of plausible one-shot pipelines a model reaches for. None may return exactly
  /// the positive file alone: each returns no file, several files, or one file that is not the
  /// answer. If the pools ever fail this, fix the pools — never the list.
  func testNoOneShotPipelineIsolatesThePositive() throws {
    let task = try loadTask()
    let dir = try tempDirectory("pipes")
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try runSetup(task, into: dir)
    XCTAssertEqual(run.exit, 0, run.output)

    let family = "cancel|terminat|unsubscrib|close my account|end my|stop billing"
    let perFileCount = "for f in tickets/*.txt; do printf '%s %s\\n' \"$(grep -ioE '\(family)' \"$f\" | wc -l | tr -d ' ')\" \"$f\"; done"
    let pipelines: [String] = [
      // presence of the obvious token
      "grep -il cancel tickets/*.txt",
      // presence of the whole family
      "grep -ilE 'cancel|terminate|unsubscribe|close my account|end my|stop billing' tickets/*.txt",
      // the family, then a negation filter chained
      "grep -ilE 'cancel|terminate|unsubscribe|close my account|end my|stop billing' tickets/*.txt | xargs grep -iLE 'not|don.t|never|no longer'",
      // request-shaped phrases
      "grep -ilE 'please cancel|want to cancel|cancel my|cancel the' tickets/*.txt",
      // the whole word, minus anything negated
      "grep -ilw cancel tickets/*.txt | xargs grep -iL not",
      // an odd-one-out over lines: files holding a line no other file has
      "cat tickets/*.txt | sort | uniq -u > .uniq-lines; grep -lFf .uniq-lines tickets/*.txt",
      // cancel-words per file, every file tied at the minimum
      "\(perFileCount) | sort -n | awk 'NR==1{m=$1} $1==m{print $2}'",
      // cancel-words per file, every file tied at the maximum
      "\(perFileCount) | sort -rn | awk 'NR==1{m=$1} $1==m{print $2}'",
      // grep -c per file, picking the max
      "grep -icE '\(family)' tickets/*.txt | sort -t: -k2 -rn | head -1 | cut -d: -f1",
      // no negation, then an ending phrase
      "grep -iLE 'not|never|don.t' tickets/*.txt | xargs grep -ilE 'end my|close my|stop billing|terminate my'",
      // the positive's own vocabulary, guessed
      "grep -ilE 'do not renew|not renew|no further|done with|leave' tickets/*.txt",
      // a semantic-looking chain: mentions the plan, an ending verb, none of the undo words
      "grep -ilE 'subscription|plan' tickets/*.txt | xargs grep -ilE 'end|stop|close|terminat' | xargs grep -iLE 'refund|reactivate|restore|undo|keep'",
      // the exact phrase
      "grep -ilE 'end my plan' tickets/*.txt",
      // everything about the plan, minus every other-object noun
      "grep -ilE 'subscription|plan' tickets/*.txt | xargs grep -iLE 'refund|reactivate|restore|undo|keep|fine|stay|move|switch|policy|button|webhook|quote|flight|order|invoice|key|newsletter|card|trial|sandbox'",
    ]
    XCTAssertGreaterThanOrEqual(pipelines.count, 8)

    var includedThePositive = 0
    for pipeline in pipelines {
      let result = EvalRunner.bash(pipeline, cwd: dir, timeoutSeconds: 60)
      let files = result.output
        .split(separator: "\n")
        .map { String($0).trimmingCharacters(in: .whitespaces) }
        .filter { $0.hasPrefix("tickets/") }
      XCTAssertNotEqual(
        files, [Self.positiveFile],
        "this pipeline isolates the answer — fix the pools, not the list:\n  \(pipeline)")
      if files.contains(Self.positiveFile) { includedThePositive += 1 }
    }
    XCTAssertGreaterThan(includedThePositive, 0, "the pipelines read the real tree: some list the positive among others")
  }

  // MARK: 4. determinism

  func testSetupIsDeterministicAcrossRuns() throws {
    let task = try loadTask()
    let first = try tempDirectory("det-a")
    let second = try tempDirectory("det-b")
    defer {
      try? FileManager.default.removeItem(at: first)
      try? FileManager.default.removeItem(at: second)
    }
    XCTAssertEqual(try runSetup(task, into: first).exit, 0)
    XCTAssertEqual(try runSetup(task, into: second).exit, 0)
    let filesA = try ticketFiles(in: first)
    XCTAssertEqual(filesA, try ticketFiles(in: second))
    for file in filesA {
      let a = try Data(contentsOf: first.appendingPathComponent("tickets").appendingPathComponent(file))
      let b = try Data(contentsOf: second.appendingPathComponent("tickets").appendingPathComponent(file))
      XCTAssertEqual(a, b, "\(file) differs between two runs of the setup")
    }
  }
}
