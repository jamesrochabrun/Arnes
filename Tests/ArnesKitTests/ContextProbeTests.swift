import XCTest
@testable import ArnesKit

/// A10 — the delegation probe beyond one context window,
/// `evals/subagents/05-context-search-delegates.json`.
///
/// Batch 14's judgment probe (task 04, 240 tickets ≈ 92 KB) defeated every one-shot pipeline
/// but not patience: both models grep'd down to ~40 candidates and read them into their own
/// context in 9–23 steps, and delegated once in 32 trials. This task keeps the family (support
/// tickets, exactly one asking to stop a subscription, every decoy using cancel-family words in
/// another sense, the positive without the word `cancel`) and adds what 04 lacked: **volume** —
/// two thousand tickets, ~1.5 MB, fifty times the 30 000-char tool-result cap — and **shared
/// vocabulary**: every distinctive phrase of the positive's request sentence (`end my plan`,
/// `do not renew`, `no further charges`, `billing cycle`, `done with`, `decided to leave`)
/// appears, in other senses, in over a third of the files, and the two most distinctive still
/// co-occur in a quarter of them (≈ 420 KB). So a lead that greps the positive's own words gets a
/// candidate set larger than any spilled result and, read serially, larger than a small model's
/// context budget — while four `explore` fan-outs each read a quarter. These pins make that a
/// fact: the suite's shape, the tree the one-process `awk` generator promises, the sharing
/// numbers, a fixed list of plausible one-shot pipelines none of which returns the positive
/// alone, determinism, and the setup's wall time.
final class ContextProbeTests: XCTestCase {
  private static var repoRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  }

  static let suiteIDs = [
    "wide-search-delegates", "trivial-task-stays-direct", "noisy-search-delegates", "judgment-search-delegates",
    "context-search-delegates",
  ]
  static let taskID = "context-search-delegates"
  /// The id the check hardcodes — the file name without `.txt`; the generator derives it from
  /// the index (`i == 1046 → TK-(1000 + 4·1046)`), the setup never spells it.
  static let positiveID = "TK-5184"
  static let positiveFile = "tickets/TK-5184.txt"
  static let fileCount = 2000
  /// The cancel-family stems every ticket carries at least one of (case-insensitive).
  static let cancelFamily = ["cancel", "terminat", "unsubscrib", "close my account", "end my", "stop billing"]
  /// The generator's own rule for the positive: the one sentence that asks to stop the plan.
  static let positiveSentence = "Please end my plan at the end of this billing cycle and do not renew it"
  /// The positive's distinctive phrases — each must appear (in other senses) in ≥ 600 of the
  /// 2 000 files, so grepping the positive's own words never narrows the search to a readable set.
  static let sharedPhrases = ["end my plan", "do not renew", "no further charges", "billing cycle", "done with", "decided to leave"]
  /// The two most distinctive of them; their intersection is the best candidate set a
  /// vocabulary grep yields, and it must still be more than one spilled result.
  static let twoMostDistinctive = ("do not renew", "no further charges")
  /// The universal tool-result cap the tree must dwarf (`ToolOutputLimiter.defaultMaxChars`).
  static let toolResultCap = 30_000

  private func tempDirectory(_ label: String) throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-a10-\(label)-\(UUID().uuidString)")
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

  /// The `tickets/…` paths a pipeline printed, one per line.
  private func listed(by pipeline: String, in dir: URL) -> [String] {
    EvalRunner.bash(pipeline, cwd: dir, timeoutSeconds: 120).output
      .split(separator: "\n")
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("tickets/") }
  }

  private func bytes(of files: [String], in dir: URL) throws -> Int {
    try files.reduce(0) { $0 + (try Data(contentsOf: dir.appendingPathComponent($1))).count }
  }

  // MARK: 1. the suite's shape

  func testSuiteHasFiveTasksAndTheProbeCheckHasBothHalves() throws {
    let task = try loadTask()
    XCTAssertEqual(task.id, Self.taskID)
    XCTAssertEqual(task.timeoutSeconds, 900, "the agent's budget — a lead that reads 2 000 tickets alone needs the rope to prove the point; setup and check are capped at 60 s by the runner")
    // The answer half and the explore half, in task 04's shape: the ARNES_SESSION_ID strict path
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
    XCTAssertTrue(setup.contains("awk '"), "one awk process writes every file — 2 000 sh iterations with a subshell each would approach the 60 s cap on a loaded machine")
    // The prompt states the directory, the count, what exactly one ticket does and where the
    // answer goes — and never hints at delegation (that is the pack's job).
    XCTAssertTrue(task.prompt.contains("tickets/"))
    XCTAssertTrue(task.prompt.contains("two thousand"))
    XCTAssertTrue(task.prompt.contains("Exactly one"))
    XCTAssertTrue(task.prompt.contains("answer.txt"))
    for hint in ["delegat", "subagent", "explore", "parallel"] {
      XCTAssertFalse(task.prompt.lowercased().contains(hint), "the prompt must not hint at delegation: \(hint)")
    }
  }

  // MARK: 2. the tree the generator promises (+ 5. the wall time)

  func testSetupMakesTheTreeTheGeneratorPromises() throws {
    let task = try loadTask()
    let dir = try tempDirectory("tree")
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try runSetup(task, into: dir)
    XCTAssertEqual(run.exit, 0, run.output)
    XCTAssertLessThan(run.seconds, 30, "the runner caps a setup at 60 s; this one must stay far under it (one awk process: well under 5 s here)")

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
      XCTAssertGreaterThan(data.count, 300, "\(file) is not an ordinary-looking ticket")
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
    // Volume: on disk, and as the one thing a lead might try first.
    XCTAssertGreaterThanOrEqual(totalBytes, 1_000_000, "the tree must be more than a few spilled results can carry")
    XCTAssertLessThanOrEqual(totalBytes, 2_000_000, "and stay a fan-out of explorers' worth of reading")
    let catBytes = Int(EvalRunner.bash("cat tickets/*.txt | wc -c", cwd: dir, timeoutSeconds: 60).output.trimmingCharacters(in: .whitespacesAndNewlines))
    XCTAssertGreaterThanOrEqual(
      try XCTUnwrap(catBytes), 10 * Self.toolResultCap,
      "`cat tickets/*` must be at least ten times the 30 000-char tool-result cap (evals spill nothing — the middle is lost)")

    // The check's literal id is the positive's file stem — the two cannot drift apart.
    let idRule = try NSRegularExpression(pattern: #"= ([A-Za-z]+-[0-9]+) &&"#)
    let check = task.check as NSString
    let match = try XCTUnwrap(idRule.firstMatch(in: task.check, range: NSRange(location: 0, length: check.length)))
    XCTAssertEqual(check.substring(with: match.range(at: 1)), Self.positiveID)

    // Nothing but the tickets and the fallback snapshot: no truth table in the workdir.
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted(), [".runs-before", "tickets"])
    XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".runs-before"), encoding: .utf8), "0\n")
  }

  // MARK: 3. vocabulary sharing — what makes solo reading uneconomic

  /// Every distinctive phrase of the positive's request sentence is shared by at least a third of
  /// the tickets, and the two most distinctive still co-occur in a candidate set larger than one
  /// spilled result — so the best grep a lead can write leaves it hundreds of files to read.
  func testThePositivesVocabularyIsSharedByAThirdOfTheTickets() throws {
    let task = try loadTask()
    let dir = try tempDirectory("vocab")
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try runSetup(task, into: dir)
    XCTAssertEqual(run.exit, 0, run.output)

    let positive = try String(contentsOf: dir.appendingPathComponent(Self.positiveFile), encoding: .utf8).lowercased()
    XCTAssertGreaterThanOrEqual(Self.sharedPhrases.count, 4)
    for phrase in Self.sharedPhrases {
      XCTAssertTrue(positive.contains(phrase), "\(phrase) is a phrase of the positive")
      let hits = listed(by: "grep -il '\(phrase)' tickets/*.txt", in: dir)
      XCTAssertGreaterThanOrEqual(hits.count, 600, "'\(phrase)' must be shared by at least a third of the 2 000 tickets; got \(hits.count)")
      XCTAssertTrue(hits.contains(Self.positiveFile))
    }
    let (a, b) = Self.twoMostDistinctive
    let candidates = listed(by: "grep -il '\(a)' tickets/*.txt | xargs grep -il '\(b)'", in: dir)
    XCTAssertGreaterThanOrEqual(candidates.count, 200, "the two most distinctive phrases together still leave ≥ 200 candidates; got \(candidates.count)")
    XCTAssertTrue(candidates.contains(Self.positiveFile))
    let candidateBytes = try bytes(of: candidates, in: dir)
    XCTAssertGreaterThanOrEqual(
      candidateBytes, 200_000,
      "the candidate set (\(candidateBytes) bytes) must exceed what one spilled result carries — several `read_file`s for a lead, a quarter each for four explorers")
  }

  // MARK: 4. shell-proofness — the item's contract

  /// Task 04's fourteen one-shot pipelines (the family list adjusted; the two per-file counts in
  /// their one-`grep` form, since a `for f in tickets/*.txt` loop spawns 2 000 greps) plus the
  /// pipelines that target the positive's own vocabulary — the words a lead learns from the
  /// prompt or from reading a few tickets. None may return exactly the positive file alone: each
  /// returns no file, several files, or one file that is not the answer. If the pools ever fail
  /// this, fix the pools — never the list.
  func testNoOneShotPipelineIsolatesThePositive() throws {
    let task = try loadTask()
    let dir = try tempDirectory("pipes")
    defer { try? FileManager.default.removeItem(at: dir) }
    let run = try runSetup(task, into: dir)
    XCTAssertEqual(run.exit, 0, run.output)

    let family = "cancel|terminat|unsubscrib|close my account|end my|stop billing"
    let perFileCount = "grep -ioE '\(family)' tickets/*.txt | cut -d: -f1 | sort | uniq -c"
    let otherObjects = "refund|reactivate|restore|undo|keep|fine|stay|move|switch|policy|button|webhook|quote|flight|order|invoice|key|newsletter|card|trial|sandbox"
    let pipelines: [String] = [
      // — task 04's fourteen —
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
      "grep -ilE 'subscription|plan' tickets/*.txt | xargs grep -iLE '\(otherObjects)'",
      // — the positive's own vocabulary, which this task shares out —
      // one distinctive phrase
      "grep -il 'do not renew' tickets/*.txt",
      // the two most distinctive, intersected
      "grep -il 'do not renew' tickets/*.txt | xargs grep -il 'no further charges'",
      // three phrases
      "grep -il 'do not renew' tickets/*.txt | xargs grep -il 'no further charges' | xargs grep -il 'end my plan'",
      // four phrases
      "grep -il 'do not renew' tickets/*.txt | xargs grep -il 'no further charges' | xargs grep -il 'end my plan' | xargs grep -il 'done with'",
      // every distinctive phrase of the request sentence at once
      "grep -il 'do not renew' tickets/*.txt | xargs grep -il 'no further charges' | xargs grep -il 'end my plan' | xargs grep -il 'done with' | xargs grep -il 'decided to leave'",
      // the positive's phrases minus every other-object noun the decoys attach them to
      "grep -ilE 'end my plan|do not renew|no further charges' tickets/*.txt | xargs grep -iLE '\(otherObjects)|domain|certificate|seat|add-on|budget|upgrade|cost centre|toggle|article|paused|export|beta|pilot|archive'",
      // the opener
      "grep -il 'decided to leave' tickets/*.txt",
      // the positive's own wording, sentence by sentence
      "grep -il 'I have decided to leave' tickets/*.txt",
      "grep -il 'done with the service' tickets/*.txt",
      "grep -il 'do not renew it' tickets/*.txt",
      "grep -ilE 'no further charges (after|from)' tickets/*.txt",
      // `end my plan` minus the words the decoys use it beside
      "grep -ilE 'end my plan' tickets/*.txt | xargs grep -iLE 'toggle|article|never asked|trial|add-on|question|planning'",
    ]
    XCTAssertGreaterThanOrEqual(pipelines.count, 18)

    var includedThePositive = 0
    for pipeline in pipelines {
      let listed = listed(by: pipeline, in: dir)
      XCTAssertNotEqual(
        listed, [Self.positiveFile],
        "this pipeline isolates the answer — fix the pools, not the list:\n  \(pipeline)")
      if listed.contains(Self.positiveFile) { includedThePositive += 1 }
    }
    XCTAssertGreaterThan(includedThePositive, 0, "the pipelines read the real tree: some list the positive among others")
  }

  // MARK: 5. determinism

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
