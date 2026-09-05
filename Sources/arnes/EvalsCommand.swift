import ArgumentParser
import ArnesKit
import Foundation

// MARK: - evals

struct Evals: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect, capture, and prune the eval history (~/.arnes/evals.jsonl).",
    subcommands: [EvalsShow.self, EvalsCapture.self, EvalsPrune.self, EvalsTranscript.self],
    defaultSubcommand: EvalsShow.self)
}

// MARK: - evals transcript

struct EvalsTranscript: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "transcript",
    abstract: "Print a trial's transcript (kept under ~/.arnes/eval-sessions by `arnes eval`) as markdown.",
    discussion: """
      Names a trial by its session id, an id prefix, or a run id prefix (the `sessionId` /
      `runId` fields of its row in ~/.arnes/evals.jsonl). With no id, lists the transcripts
      kept, newest first, with the suite · task · verdict of the row each one belongs to.
      """)

  @Argument(help: "Session id, id prefix, or run-id prefix of the trial (omit to list).")
  var id: String?

  @Flag(help: "Print one JSON document instead: with an id {type: eval_transcript, session_id, run_id, suite, task, model, dialect, passed, cost_usd, entries: [the transcript's lines as stored]} (the eval fields null when the row was pruned); without one {type: eval_transcripts, rows: [{session_id, updated_at, model, suite, task, passed}]}.")
  var json = false

  func run() throws {
    let store = EvalSessions.store()
    let sessions = try store.list()
    let outcomes = try EvalStore().all()
    guard let id else {
      if json {
        // The listing as data; an empty store is `rows: []`, never the text notice.
        try JSONOut.print(EvalTranscriptsDocument(rows: Self.listingRows(sessions: sessions, outcomes: outcomes)))
        return
      }
      guard !sessions.isEmpty else {
        print("no eval transcripts under \(EvalSessions.displayPath) — `arnes eval <suite>` keeps one per trial unless --no-transcripts")
        return
      }
      for line in Self.listingLines(sessions: sessions, outcomes: outcomes) {
        print(TerminalText.sanitize(line))
      }
      return
    }
    let resolved = try EvalSessions.resolve(id, sessions: sessions, outcomes: outcomes)
    if json {
      // The transcript's lines as stored, with the eval row they belong to (the newest row
      // naming the session, as the listing picks it).
      try JSONOut.print(EvalTranscriptDocument(
        sessionId: resolved,
        row: Self.rowsBySession(outcomes)[resolved],
        entries: try store.entries(id: resolved)))
      return
    }
    print(TerminalText.sanitize(try store.exportMarkdown(id: resolved)))
  }

  /// The eval row each transcript belongs to, by session id — the last row naming a session
  /// wins, the rule `listingLines` always applied.
  static func rowsBySession(_ outcomes: [EvalOutcome]) -> [String: EvalOutcome] {
    var rows: [String: EvalOutcome] = [:]
    for outcome in outcomes {
      if let sessionId = outcome.sessionId { rows[sessionId] = outcome }
    }
    return rows
  }

  /// The listing as rows (`--json`): one per transcript in the store's order, the row's suite,
  /// task and verdict when the history still has the row, null otherwise.
  static func listingRows(sessions: [SessionMeta], outcomes: [EvalOutcome]) -> [EvalTranscriptRow] {
    let rows = rowsBySession(outcomes)
    return sessions.map { meta in
      let row = rows[meta.id]
      return EvalTranscriptRow(
        sessionId: meta.id, updatedAt: meta.updatedAt, model: meta.model,
        suite: row?.suite, task: row?.taskId, passed: row?.isPass)
    }
  }

  /// One line per transcript: `id8 · when · model · suite/task ✓|✗` (the row's facts when the
  /// history still has the row, `(no eval row)` when it was pruned or written elsewhere).
  static func listingLines(sessions: [SessionMeta], outcomes: [EvalOutcome]) -> [String] {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    var rows: [String: EvalOutcome] = [:]
    for outcome in outcomes {
      if let sessionId = outcome.sessionId { rows[sessionId] = outcome }
    }
    return sessions.map { meta in
      var line = "\(String(meta.id.prefix(8))) · \(formatter.string(from: meta.updatedAt)) · \(meta.model ?? "?")"
      if let row = rows[meta.id] {
        line += " · \(row.suite)/\(row.taskId) \(row.isPass ? "✓" : "✗")"
      } else {
        line += " · (no eval row)"
      }
      return line
    }
  }
}

// MARK: - evals show

struct EvalsShow: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "show",
    abstract: "Visual summary of the eval history, grouped by suite × model × dialect.")

  @Option(help: "Only this suite (e.g. basics, panel).")
  var suite: String?

  @Option(name: .shortAndLong, help: "Only models containing this substring.")
  var model: String?

  @Option(help: "Only rows from the last N days.")
  var days: Int?

  @Option(help: "Only rows of this task id.")
  var task: String?

  @Option(help: "Only rows tagged with this A/B arm (`arnes eval --label <name>`; exact match).")
  var label: String?

  @Flag(help: "Print one JSON document ({type: evals, rows: [{suite, model, dialect, trials, passed, pass_rate, cost_usd, last_run}]}) instead of the table.")
  var json = false

  func run() throws {
    var outcomes = try EvalStore().all()
    if let suite {
      outcomes = outcomes.filter { $0.suite == suite }
    }
    if let model {
      outcomes = outcomes.filter { $0.model.localizedCaseInsensitiveContains(model) }
    }
    if let days {
      let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
      outcomes = outcomes.filter { $0.startedAt >= cutoff }
    }
    if let task {
      outcomes = outcomes.filter { $0.taskId == task }
    }
    if let label {
      // One A/B arm: the grouping stays suite × model × dialect, the view shows that arm alone.
      outcomes = outcomes.filter { $0.label == label }
    }
    if json {
      // The same filtered rows, grouped the way the table groups them; an empty history is an
      // empty `rows`, never the text notice — stdout is the one document.
      try JSONOut.print(EvalsDocument(rows: Self.jsonRows(outcomes)))
      return
    }
    let rows = EvalHistoryRow.aggregate(outcomes)
    guard !rows.isEmpty else {
      print("no matching eval history — run a suite with `arnes eval <suite> -m <model>`")
      return
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    print(ANSI.dim(Self.header))
    print(ANSI.dim(String(repeating: "─", count: 120)))
    var currentSuite = ""
    for row in rows {
      let suiteLabel = row.suite == currentSuite ? "" : row.suite
      currentSuite = row.suite
      print(Self.line(for: row, suiteLabel: suiteLabel, lastRun: formatter.string(from: row.lastRun)))
    }
    let totalTrials = rows.reduce(0) { $0 + $1.trials }
    let totalCost = rows.reduce(0.0) { $0 + $1.totalCostUSD }
    print(ANSI.dim("\n\(totalTrials) trials · total cost \(String(format: "$%.4f", totalCost)) · prune with `arnes evals prune`"))
  }

  /// The table header. The last column (V1) is the loop-1 verifier's agreement with the bash
  /// check over the rows it graded — `–` for a group no verifier ever saw.
  static let header =
    "suite        model                                 dialect    pass                       cost      last run    verifier"

  /// One table row: the pre-V1 columns byte for byte, then the verifier column.
  static func line(for row: EvalHistoryRow, suiteLabel: String, lastRun: String) -> String {
    let pass = "\(row.passed)/\(row.trials) (\(Int(row.passRate * 100))%)"
    return suiteLabel.padding(toLength: 13, withPad: " ", startingAt: 0)
      + row.model.padding(toLength: 38, withPad: " ", startingAt: 0)
      + (row.dialect ?? "–").padding(toLength: 11, withPad: " ", startingAt: 0)
      + bar(row.passRate) + " " + pass.padding(toLength: 13, withPad: " ", startingAt: 0)
      + String(format: "$%.4f", row.totalCostUSD).padding(toLength: 10, withPad: " ", startingAt: 0)
      + lastRun
      + "  " + verifierCell(row)
  }

  /// `7/8 agree` over the verified rows, or a dim `–` when none was.
  static func verifierCell(_ row: EvalHistoryRow) -> String {
    row.verifierVerdicts == 0
      ? ANSI.dim("–")
      : "\(row.verifierAgreements)/\(row.verifierVerdicts) agree"
  }

  static func bar(_ rate: Double, width: Int = 12) -> String {
    let filled = Int((rate * Double(width)).rounded())
    let color = rate >= 0.8 ? ANSI.green : rate >= 0.5 ? ANSI.yellow : ANSI.red
    return color(String(repeating: "█", count: filled))
      + ANSI.dim(String(repeating: "░", count: width - filled))
  }
}

// MARK: - evals capture

struct EvalsCapture: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "capture",
    abstract: "Distill a session (or a task description) into a reusable eval task.",
    discussion: """
      Watched the agent fumble something? Capture it: a writer model reads the session
      transcript and writes an eval task (prompt + setup + check) that recreates the
      situation. The draft is validated before it's saved — setup must succeed and the
      check must FAIL on the fresh setup (a check that passes before any work tests
      nothing). Rerun the captured task forever with `arnes eval <output-dir> -m <model>`.
      """)

  @Option(help: "Session id to capture from (see `arnes sessions`; default: the most recent session).")
  var session: String?

  @Option(help: "Skip sessions: write the eval from this plain task description instead.")
  var task: String?

  @Flag(help: "Auto-slice the session into one eval task per user turn (skipping turns with nothing to test).")
  var split = false

  @Option(help: "Steer the writer, e.g. \"focus on the regex part it got wrong\".")
  var hint: String?

  @Option(name: .shortAndLong, help: "Writer model (default: the provider's default model).")
  var model: String?

  @Option(name: .shortAndLong, help: "Suite directory to write the task into.")
  var output = "evals/captured"

  @Flag(
    name: [.customShort("y"), .customLong("yes")],
    help: "Run the writer's setup/check scripts for validation without showing them first (they are model-written bash, run with your privileges).")
  var yes = false

  @OptionGroup var providerOptions: ProviderOptions

  func run() async throws {
    let runtime = try ArnesRuntime.make(providerOptions)
    let model = try runtime.model(self.model)
    // Validation runs the draft's bash. Interactive: show it and ask. Piped: only with --yes.
    guard yes || TerminalInput.isInteractive else {
      throw ValidationError(
        "evals capture validates each draft by running the writer's setup/check scripts; pass --yes to allow that in a non-interactive run")
    }
    let reviewer: EvalTaskDistiller.Reviewer? = yes ? nil : { task in
      print(ANSI.yellow("⚠ the writer proposes these scripts (validation runs them now, in a temp dir, as you):"))
      print(TerminalText.sanitize("  id:     \(task.id)\n  prompt: \(String(task.prompt.prefix(200)))"))
      if let setup = task.setup {
        print(TerminalText.sanitize("  setup:  \(setup)"))
      }
      print(TerminalText.sanitize("  check:  \(task.check)"))
      return TerminalInput.confirm("  run them? [y/N]")
    }
    let distiller = EvalTaskDistiller(service: runtime.service, reviewer: reviewer)

    if split {
      guard task == nil else {
        throw ValidationError("--split slices a session; it can't combine with --task")
      }
      let (meta, loaded) = try loadSession()
      let sources = EvalCapture.splitSources(loaded.messages)
      guard !sources.isEmpty else {
        throw ValidationError("session \(meta.id) has no user turns to slice")
      }
      print(ANSI.dim("splitting session \(meta.id) into \(sources.count) turn(s)"))
      var captured = 0
      var cost = 0.0
      for (index, source) in sources.enumerated() {
        do {
          guard let result = try await distiller.distillIfTask(from: source, hint: hint, model: model) else {
            print(ANSI.dim("· turn \(index + 1): skipped — nothing to test"))
            continue
          }
          cost += result.costUSD
          let file = try write(task: result.task)
          captured += 1
          print(TerminalText.sanitize("✔ turn \(index + 1): \(ANSI.bold(result.task.id)) → \(file.path)"))
        } catch EvalCaptureError.declined {
          print(ANSI.dim("· turn \(index + 1): declined — nothing written"))
        } catch {
          // One bad turn shouldn't sink the rest of the session.
          print(ANSI.yellow(TerminalText.sanitize("✘ turn \(index + 1): \(String("\(error)".prefix(120)))")))
        }
      }
      print("\ncaptured \(captured) task(s) from \(sources.count) turn(s) · writer cost \(String(format: "$%.4f", cost))")
      if captured > 0 {
        print("run them:  arnes eval \(output) -m deepseek/deepseek-v4-flash")
      }
      return
    }

    let source: String
    if let task {
      source = "Task description (no transcript):\n\(task)"
    } else {
      let (meta, loaded) = try loadSession()
      source = "Session transcript:\n\(EvalCapture.renderTranscript(loaded.messages))"
      print(ANSI.dim("capturing from session \(meta.id) (\(loaded.messages.count) messages)"))
    }

    let result: EvalTaskDistiller.Output
    do {
      result = try await distiller.distill(from: source, hint: hint, model: model)
    } catch EvalCaptureError.declined {
      print("declined — nothing written")
      return
    }
    let file = try write(task: result.task)
    print(TerminalText.sanitize("✔ captured \(ANSI.bold(result.task.id)) → \(file.path)  (validated: setup ok, check fails pre-work)"))
    print(ANSI.dim(TerminalText.sanitize("  prompt: \(String(result.task.prompt.prefix(100)))")))
    print(ANSI.dim("  writer cost \(String(format: "$%.4f", result.costUSD)) · \(result.attempts) attempt(s)"))
    print("run it:  arnes eval \(output) -m deepseek/deepseek-v4-flash")
  }

  private func loadSession() throws -> (SessionMeta, LoadedSession) {
    let store = SessionStore()
    if let session {
      return try Self.resolveSession(session, stores: [store, EvalSessions.store()])
    }
    guard let recent = store.mostRecent() else {
      throw ValidationError("no saved sessions — pass --task \"<description>\" instead")
    }
    return (recent, try store.load(id: recent.id))
  }

  /// The one id/prefix/name rule (`SessionStore.match`) over the user's sessions first, then
  /// the eval trials' transcripts — so a fumbled trial can be captured as a task like any
  /// session. A prefix that is ambiguous within a store is refused, never guessed.
  static func resolveSession(_ query: String, stores: [SessionStore]) throws -> (SessionMeta, LoadedSession) {
    for store in stores {
      switch SessionStore.match(query, in: try store.list()) {
      case .found(let meta):
        return (meta, try store.load(id: meta.id))
      case .ambiguous(let candidates):
        let ids = candidates.map { String($0.id.prefix(8)) }.joined(separator: ", ")
        throw ValidationError("'\(query)' matches several sessions: \(ids) — give more of the id")
      case .none:
        continue
      }
    }
    throw ValidationError("no session matching '\(query)' — see `arnes sessions` (or `arnes evals transcript` for eval trials)")
  }

  private func write(task: EvalTask) throws -> URL {
    // Validation already rejects unsafe ids and feeds the problem back to the writer;
    // this keeps a model-chosen id from ever becoming a path outside the suite dir.
    guard EvalCapture.isSafeTaskId(task.id) else {
      throw ValidationError("refusing to write task with unsafe id \"\(task.id.prefix(60))\"")
    }
    let directory = URL(fileURLWithPath: output)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var file = directory.appendingPathComponent("\(task.id).json")
    var suffix = 2
    while FileManager.default.fileExists(atPath: file.path) {
      file = directory.appendingPathComponent("\(task.id)-\(suffix).json")
      suffix += 1
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(task).write(to: file)
    return file
  }
}

// MARK: - evals prune

struct EvalsPrune: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prune",
    abstract: "Delete rows from the eval history (and the removed trials' transcripts). Combines filters; requires at least one.")

  @Option(help: "Remove rows older than N days.")
  var olderThan: Int?

  @Option(help: "Remove rows of this suite (e.g. panel).")
  var suite: String?

  @Option(name: .shortAndLong, help: "Remove rows whose model contains this substring.")
  var model: String?

  @Option(help: "Remove rows tagged with this A/B arm (`arnes eval --label <name>`; exact match).")
  var label: String?

  @Flag(help: "Remove everything (the filters above are ignored).")
  var all = false

  func run() throws {
    guard all || olderThan != nil || suite != nil || model != nil || label != nil else {
      throw ValidationError("pass a filter: --older-than <days>, --suite <name>, --model <substring>, --label <name>, or --all")
    }
    let cutoff = olderThan.map { Date().addingTimeInterval(-Double($0) * 86_400) }
    let (kept, removed, removedRows) = try EvalStore().rewrite { outcome in
      if all { return false }
      // A row is removed only when it matches EVERY given filter.
      if let cutoff, outcome.startedAt >= cutoff { return true }
      if let suite, outcome.suite != suite { return true }
      if let model, !outcome.model.localizedCaseInsensitiveContains(model) { return true }
      if let label, outcome.label != label { return true }
      return false
    }
    // A removed row's transcript goes with it: the row is the only thing that names it.
    let transcripts = Self.deleteTranscripts(of: removedRows, in: EvalSessions.store())
    print("removed \(removed) row(s) · kept \(kept) · ~/.arnes/evals.jsonl"
      + (transcripts > 0 ? " · deleted \(transcripts) transcript(s) under \(EvalSessions.displayPath)" : ""))
  }

  /// Deletes the transcripts the removed rows name (each once, only those the store has).
  /// - Returns: how many were deleted.
  static func deleteTranscripts(of rows: [EvalOutcome], in store: SessionStore) -> Int {
    let present = Set((try? store.list())?.map(\.id) ?? [])
    var deleted = 0
    for id in Set(rows.compactMap(\.sessionId)) where present.contains(id) {
      if (try? store.delete(id: id)) != nil { deleted += 1 }
    }
    return deleted
  }
}
