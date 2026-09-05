import ArgumentParser
import ArnesKit
import Foundation

struct Eval: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run an eval suite: models × tasks × trials, scored by each task's check script.",
    discussion: """
      A suite is a directory of .json task files (or one file). Each task:
        {"id": "create-file",
         "prompt": "Create hello.txt containing exactly: hello world",
         "setup": "optional bash run before the agent",
         "check": "test \\"$(cat hello.txt)\\" = 'hello world'"}
      Every trial runs in a fresh temp directory; check exit 0 = pass. Outcomes append
      to ~/.arnes/evals.jsonl and agent runs also feed the `arnes runs` scoreboard.
      Optional graders per task (the check stays the ground truth; a rubric refines a pass,
      never replaces the check):
        "rubric": {"criteria": ["…"], "threshold": 0.7, "model": "…", "gate": true}
        "limits": {"maxSteps": 6, "maxToolCalls": 8, "maxCostUSD": 0.05,
                   "forbiddenTools": ["bash"], "requiredTools": ["edit_file"], "gate": false}
        "verify": true          (with --verify <model>)
      Every trial's transcript is kept under ~/.arnes/eval-sessions/ (`arnes evals
      transcript <id>`) unless --no-transcripts.
      As a CI gate: --parallel N runs N trials at once, --min-pass 1.0 exits 2 when any
      model's pass rate is under it, --compare last|last:N|<N>d sets each task against its history
      in ~/.arnes/evals.jsonl (--fail-on-regression exits 2 on a regression), --json prints
      one document (progress goes to stderr). Exit 0 gate passed (or none set) · 2 gate
      failed · 1 the command itself failed · 64 usage.
      A/B arms: --label <name> tags every row of the run (read back with `arnes evals show
      --label <name>`), --adaptive-think is the policies.adaptiveThink arm, and
      ARNES_PACKS_DIR=<dir> runs the suite on a pack variant (a base.md there replaces the
      base prompt) — see evals/ab/README.md for the recipe.
      """)

  @Argument(help: "Path to a suite directory or task .json file.")
  var suite: String

  @Option(name: .shortAndLong, help: "Models to evaluate — ids or configured aliases, comma-separated or the flag repeated (-m a -m b is -m a,b); default: the provider's default model. A model named more than once (directly or through an alias) runs once — --trials repeats a model.")
  var models: [String] = []

  @Option(name: .shortAndLong, help: "Trials per model per task.")
  var trials = 1

  @Option(help: "Run only this task id.")
  var task: String?

  @Option(help: "Max agent steps per trial.")
  var maxSteps = 30

  @Option(help: "Wire dialect: auto (native per model family), chat, messages, or responses. Run the same suite twice with different forced dialects for an A/B.")
  var dialect = "auto"

  @Flag(help: "Run trials unconfined: skip the OS sandbox that otherwise wraps every trial on a platform that supports it.")
  var noSandbox = false

  @Flag(help: "Trust this directory (remembered), so its own .arnes/hooks.json — once approved with `arnes hooks trust` — runs for every trial alongside your hooks.")
  var trustProject = false

  @Flag(help: "Give every trial the task tool with the built-in and user-global subagents (the ones `arnes agents` lists outside a project; no project agents), so a suite like evals/subagents can score delegation. Your SubagentStart/SubagentStop hooks run for each delegation as in `arnes do`. Off by default: the toolset and prompt stay exactly what evals/basics measured.")
  var subagents = false

  @Option(help: "Model for tasks that declare a rubric (default: the provider's default model; a task's own rubric.model wins). Equal to the candidate = self-grading, warned.")
  var judge: String?

  @Option(help: "Run the loop-1 verifier after each trial of a task with `verify: true` (nothing without the flag; the flag does nothing for a task without `verify: true`).")
  var verify: String?

  @Flag(help: "Don't keep trial transcripts under ~/.arnes/eval-sessions/ (they are kept by default, for `arnes evals transcript <id>`).")
  var noTranscripts = false

  @Option(help: "Run this many trials at once (default 1: one after another). Each trial has its own workdir, tools and session, so N is a wall-clock knob; finished lines arrive in completion order.")
  var parallel = 1

  @Option(name: .customLong("min-pass"), help: "Exit 2 when any model's pass rate is under this fraction (0…1; 1.0 = every trial must pass).")
  var minPass: Double?

  @Option(help: "Set each task against its history in ~/.arnes/evals.jsonl: `last` (the newest 5 rows per task · model), `last:N` (the newest N) or `<N>d` (the rows from the N days before this run). Prints a regressions/fixes block; needed by --fail-on-regression.")
  var compare: String?

  @Flag(name: .customLong("fail-on-regression"), help: "Exit 2 when --compare finds a regression (a task at ≥ 80% before, under 50% now).")
  var failOnRegression = false

  @Flag(help: "Print one JSON document on stdout (models with pass@k/pass^k, regressions, fixes, every outcome, the gate, the exit code); progress lines go to stderr.")
  var json = false

  @Option(help: "Reasoning effort for every trial, on models whose manifest supports it: minimal, low, medium, high, xhigh, max, none.")
  var effort: String?

  @Option(help: "Stop a trial once its cost reaches this many USD (the tighter of this and the task's limits.maxCostUSD applies).")
  var budget: Double?

  @Flag(name: .customLong("adaptive-think"), help: "Omit the think tool for models whose manifest advertises reasoning when --effort is set (not none); the policies.adaptiveThink arm (on by default since the 2026-09-03 A/B; this flag forces it on for the run's trials and their subagents when the key says false).")
  var adaptiveThink = false

  @Option(help: "Tag every row of this run with an A/B arm name (1–40 of A-Z a-z 0-9 . _ -), so two arms of one suite × model read apart: `arnes evals show --label <name>`, the --json rows' `label`.")
  var label: String?

  @OptionGroup var providerOptions: ProviderOptions

  /// Refusals that cost no side effect: ArgumentParser runs this before `run()`.
  func validate() throws {
    if parallel < 1 {
      throw ValidationError("--parallel must be at least 1.")
    }
    if let minPass, !(0...1).contains(minPass) || minPass.isNaN {
      throw ValidationError("--min-pass must be a fraction between 0 and 1 (1.0 = every trial must pass).")
    }
    _ = try Self.parseCompare(compare)
    if failOnRegression, compare == nil {
      throw ValidationError("--fail-on-regression needs a baseline: pass --compare last or --compare <N>d.")
    }
    _ = try parseEffort(effort)
    if let budget, !(budget > 0) {
      throw ValidationError("--budget must be a positive number of USD.")
    }
    if let label, !Self.isValidLabel(label) {
      throw ValidationError("--label must be 1–40 characters of letters, digits, '.', '_' or '-' (an A/B arm name such as control or no-think).")
    }
    _ = try parseDialect(dialect)
  }

  /// The `--label` rule: a short word an A/B arm is read back by — `[A-Za-z0-9._-]{1,40}`.
  static let labelRule = "^[A-Za-z0-9._-]{1,40}$"

  static func isValidLabel(_ label: String) -> Bool {
    label.range(of: labelRule, options: .regularExpression) != nil
  }

  /// `--compare` → a baseline window: `last` (the newest 5 rows per key), `last:N` (the newest
  /// N, N ≥ 1 — H1), `<N>d` (N days before the run); unset → nil; anything else a usage error.
  static func parseCompare(_ raw: String?) throws -> EvalReport.Window? {
    guard let raw else { return nil }
    let spelling = raw.trimmingCharacters(in: .whitespaces).lowercased()
    if spelling == "last" {
      return .last(rows: EvalReport.Window.defaultLastRows)
    }
    if spelling.hasPrefix("last:") {
      guard let rows = Int(spelling.dropFirst("last:".count)), rows >= 1 else {
        throw ValidationError("unknown --compare '\(raw)' — `last:N` needs a row count of at least 1 (e.g. last:3)")
      }
      return .last(rows: rows)
    }
    if spelling.hasSuffix("d"), let days = Int(spelling.dropLast()), days >= 1 {
      return .days(days)
    }
    throw ValidationError("unknown --compare '\(raw)' — use `last` (the newest 5 rows per task), `last:N` (the newest N) or `<N>d` (e.g. 7d)")
  }

  /// The `-m` values as model entries: every flag split on commas, trimmed, blanks dropped —
  /// so `-m a -m b` and `-m a,b` name the same two models (an ArgumentParser array `@Option`
  /// accumulates repeats; the old `String?` kept the last flag silently). Not alias-resolved.
  static func modelEntries(_ flags: [String]) -> [String] {
    flags.flatMap { flag in
      flag.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
  }

  /// The alias-resolved model list with every repeat dropped — the first occurrence kept in
  /// place, order preserved — and `duplicates`: each name that came up again, once, in the order
  /// it first repeated. Applied *after* alias resolution, so `-m sonnet -m anthropic/…` collides
  /// too. `--trials` is the repeat knob: `-m a -m a` used to run `a` twice (and the self-grading
  /// warning named it twice).
  static func dedupedModels(_ resolved: [String]) -> (models: [String], duplicates: [String]) {
    var seen = Set<String>()
    var models: [String] = []
    var duplicates: [String] = []
    for model in resolved {
      if seen.insert(model).inserted {
        models.append(model)
      } else if !duplicates.contains(model) {
        duplicates.append(model)
      }
    }
    return (models, duplicates)
  }

  /// Where the run's lines go — the header, the `▶` starts, the ✓/✗ progress lines, the closing
  /// notes. Text mode prints to stdout and **flushes every line**: a redirected eval log
  /// (`arnes eval … > log 2>&1`) is fully buffered by stdio, and a process that dies mid-way (the
  /// batch-14 delegation A/B under the grep trap) left a log with no `▶`/`✓` line in it while
  /// `evals.jsonl` held every row. In `--json` mode stdout is the one document, so every line goes
  /// to stderr instead (an eval takes minutes; a line per trial is what tells a CI log it is
  /// alive). The output bytes are unchanged — only when they reach the pipe. The two writers are
  /// injectable so a test can count what each mode sends where; the defaults are `do`'s
  /// (`HeadlessEmitter`'s stdout sink — `Foundation.stdout`, since `stdout` is shadowed in some
  /// scopes).
  static func progressSink(
    json: Bool,
    stdout: @escaping @Sendable (String) -> Void = { print($0); fflush(Foundation.stdout) },
    stderr: @escaping @Sendable (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) })
    -> @Sendable (String) -> Void
  {
    json ? stderr : stdout
  }

  /// One trial's progress line: the ✓/✗ mark keys on the graded verdict (`isPass`), and the
  /// grader facts — `rubric 0.83 ✓` / `rubric ✗ (unknown)` / `limits ✗ steps 9 > 6` /
  /// `verify ✓` — appear only for a trial that had that grader, so an ungraded trial's line is
  /// byte-identical to what it always was.
  static func progressLine(_ outcome: EvalOutcome) -> String {
    let mark = outcome.isPass ? ANSI.green("✓") : ANSI.red("✗")
    var line = "\(mark) \(outcome.taskId) · \(outcome.model)"
      + (outcome.dialect.map { " · \($0)" } ?? "")
      + " · \(outcome.steps) steps · \(Renderer.usd(outcome.costUSD))"
      + String(format: " · %.1fs", outcome.durationSeconds)
    if outcome.rubricUnknown == true {
      line += " · rubric \(ANSI.red("✗")) (unknown)"
    } else if let score = outcome.rubricScore {
      let mark = outcome.rubricPassed == true ? ANSI.green("✓") : ANSI.red("✗")
      line += String(format: " · rubric %.2f ", score) + mark
    }
    if let limitsPassed = outcome.limitsPassed {
      if limitsPassed {
        line += " · limits \(ANSI.green("✓"))"
      } else {
        let violations = (outcome.limitsViolations ?? []).joined(separator: ", ")
        line += " · limits \(ANSI.red("✗"))" + (violations.isEmpty ? "" : " \(violations)")
      }
    }
    if let verifierPassed = outcome.verifierPassed {
      line += " · verify " + (verifierPassed ? ANSI.green("✓") : ANSI.red("✗"))
    }
    if let error = outcome.error {
      line += ANSI.yellow(" · \(String(error.prefix(80)))")
    }
    return line
  }

  /// Whether any task in the suite (after the `--task` filter) would call the rubric judge.
  private func suiteHasRubric(_ suite: EvalSuite) -> Bool {
    suite.tasks.contains { $0.rubric != nil }
  }

  func run() async throws {
    let dialectOverride = try parseDialect(dialect)
    let compareWindow = try Self.parseCompare(compare)
    let gate = EvalGate(minPass: minPass, failOnRegression: failOnRegression)
    // Text mode prints as it always did. In --json mode stdout is the one document, so every
    // line the run would have printed goes to stderr instead (the progress lines included — an
    // eval takes minutes, and a line per trial is what tells a CI log it is alive).
    let say = Self.progressSink(json: json)
    let runtime = try ArnesRuntime.make(providerOptions)
    var loaded = try EvalSuite.load(path: suite)
    if let task {
      let filtered = loaded.tasks.filter { $0.id == task }
      guard !filtered.isEmpty else {
        throw ValidationError("no task '\(task)' in suite \(loaded.name)")
      }
      loaded = EvalSuite(name: loaded.name, tasks: filtered)
    }
    // Resolve each comma-separated entry as an id or a configured alias (so
    // `-m deepseek,sonnet` works the same as `-m` does on `do`/`interactive`); the
    // provider default when the flag is omitted.
    let modelList: [String]
    // The repeated names `dedupedModels` collapsed (each once, encounter order) — said on
    // stderr and carried into the `--json` document as `collapsed_models` (`[]` when none).
    var collapsedModels: [String] = []
    if models.isEmpty {
      modelList = [try runtime.model(nil)]
    } else {
      // A model named more than once — directly, or through an alias that resolves to the same
      // id — runs once; each repeat is said on stderr, and `--trials` is the way to repeat one.
      let deduped = Self.dedupedModels(Self.modelEntries(models).map { runtime.provider.resolveAlias($0) })
      for duplicate in deduped.duplicates {
        FileHandle.standardError.write(Data((ANSI.yellow(
          "model \(duplicate) named more than once — running it once (use --trials N to repeat a model)") + "\n").utf8))
      }
      modelList = deduped.models
      collapsedModels = deduped.duplicates
    }
    guard !modelList.isEmpty else { throw ValidationError("no models to evaluate — pass -m <model or alias>[,<model>…]") }
    let totalTrials = modelList.count * loaded.tasks.count * trials
    say(ANSI.dim("suite \(loaded.name) · \(loaded.tasks.count) tasks · \(modelList.count) models · \(trials) trial(s) → \(totalTrials) runs"
      + (parallel > 1 ? " · \(parallel) at a time" : "") + "\n"))

    // A trial is an unattended run: its tools are confined by default wherever the platform
    // can enforce it, and the user's hooks apply the way they do to any other run.
    if noSandbox, runtime.shellSandbox(root: ArnesRuntime.workingDirectory, autonomous: true) != nil {
      FileHandle.standardError.write(Data((ANSI.red(ArnesRuntime.sandboxOptOutWarning) + "\n").utf8))
    }
    var makeSandbox: (@Sendable (URL) -> ShellSandbox?)?
    if !noSandbox {
      makeSandbox = { root in runtime.shellSandbox(root: root, autonomous: true) }
    }
    if let warning = runtime.hooksWarning {
      FileHandle.standardError.write(Data((TerminalText.sanitize(warning) + "\n").utf8))
    }
    // The project's own hooks (hash-trusted, narrow-only) reach the trials too, keyed on the
    // directory the eval was started from — the trust question is about this repository, not
    // the temp workdirs. Same gate as `do`; an eval loads no project skills, agents or
    // instructions, so only the hooks' own notices are printed (they say exactly what was
    // skipped and why), plus the gate's when `--trust-project` recorded something.
    let trust = ProjectTrustGate.evaluate(
      trustFlag: trustProject, interactive: false,
      instructionOptions: runtime.instructionOptions)
    if trustProject, let notice = trust.notice {
      FileHandle.standardError.write(Data((notice + "\n").utf8))
    }
    let hooks = runtime.hooks(cwd: ArnesRuntime.workingDirectory, trusted: trust.includeProject)
    for notice in hooks.notices {
      FileHandle.standardError.write(Data((TerminalText.sanitize(notice) + "\n").utf8))
    }
    // The rubric judge: --judge, else the provider's default model (a task's own rubric.model
    // outranks both in the runner); a provider without a default leaves the candidate to
    // grade itself, which the runner warns about. Aliases resolve like every other model.
    let judgeModel = judge.map { runtime.provider.resolveAlias($0) } ?? runtime.provider.defaultModel
    if judgeModel == "openrouter/auto", suiteHasRubric(loaded) {
      FileHandle.standardError.write(Data(
        "rubric judge is openrouter/auto (a different model per request): pass --judge <model> for reproducible verdicts\n".utf8))
    }
    let verifierModel = verify.map { runtime.provider.resolveAlias($0) }
    let evalStore = EvalStore()
    // The baseline is what the store held before this run — read once, here, so a row this run
    // appends (or another process appends meanwhile) can never be its own baseline.
    let runStart = Date()
    var history: [EvalOutcome] = []
    if compareWindow != nil {
      history = try evalStore.all().filter { $0.startedAt < runStart }
    }
    let runner = EvalRunner(
      service: runtime.service, store: evalStore, maxSteps: maxSteps, catalog: runtime.catalog,
      provider: runtime.traits,
      makeSandbox: makeSandbox,
      subprocessEnvironment: runtime.subprocessEnvironment,
      // The runner keeps the per-call and compaction hooks (`forNestedRun`); a trial's finish
      // is not the user's turn end.
      hooks: hooks.active,
      hookPromptRunner: runtime.promptHookRunner,
      // Trials get the same `# Environment` block a session does, so the eval measures the
      // prompt the user actually runs (`policies.environmentContext` switches both off).
      environmentContext: runtime.environmentContextEnabled,
      // `--subagents`: the agents a session started here would see minus the project's own
      // (a trial has no project), capped by the same `subagents` config block.
      subagents: subagents ? AgentLibrary.discover(includeProject: false) : [],
      subagentDefaults: runtime.subagentDefaults,
      // Trajectories are the point of reading an eval: kept by default, in a store of their
      // own so `arnes sessions` never lists a trial.
      transcriptStore: noTranscripts ? nil : EvalSessions.store(),
      judgeModel: judgeModel,
      verifierModel: verifierModel,
      reasoningEffort: try parseEffort(effort),
      budgetUSD: budget,
      // The same tool-result guard a CLI session runs (redact/scan/taint, framing per
      // `policies.toolResultFraming`), so a trial measures the framed prompt the user runs.
      toolResultGuard: runtime.toolResultGuard,
      // The P1 A/B arm: the flag for this run, or the configured key — both reach every trial.
      adaptiveThink: adaptiveThink || runtime.adaptiveThink,
      label: label)
    let outcomes = await runner.run(
      suite: loaded, models: modelList, trials: trials, dialect: dialectOverride, concurrency: parallel)
    { progress in
      switch progress {
      case .trialStarted(let taskId, let model, let trial):
        say(ANSI.dim("▶ \(taskId) · \(model) · trial \(trial)"))
      case .trialFinished(let outcome):
        say(TerminalText.sanitize(Self.progressLine(outcome)))
      case .warning(let text):
        FileHandle.standardError.write(Data((ANSI.yellow("⚠ " + TerminalText.sanitize(text)) + "\n").utf8))
      }
    }

    let summaries = EvalReport.summaries(outcomes)
    let comparison = compareWindow.map { EvalReport.compare(history: history, current: outcomes, window: $0) }
    let exitCode = gate.exitCode(summaries: summaries, regressions: comparison?.regressions ?? [])

    if json {
      try JSONOut.print(EvalReportDocument(
        suite: loaded.name,
        outcomes: outcomes,
        summaries: summaries,
        comparison: comparison,
        compare: compare.map { Self.compareSpelling($0) },
        gate: gate,
        exitCode: exitCode,
        collapsedModels: collapsedModels))
    } else {
      print("\n" + Self.renderStats(EvalStats.aggregate(outcomes), summaries: summaries, taskCount: loaded.tasks.count, trials: trials))
      let graderCost = outcomes.reduce(0.0) { $0 + ($1.graderCostUSD ?? 0) }
      if graderCost > 0 {
        print(String(format: "grader cost $%.4f (rubric)", graderCost))
      }
      if let comparison, let compareWindow {
        print("")
        for line in Self.compareLines(comparison, window: compareWindow) {
          print(TerminalText.sanitize(line))
        }
      }
      if gate.isSet {
        print("")
        print(Self.gateLine(gate, passed: exitCode == 0))
      }
      print(ANSI.dim("\noutcomes appended to ~/.arnes/evals.jsonl"))
      if !noTranscripts, outcomes.contains(where: { $0.sessionId != nil }) {
        print(ANSI.dim("transcripts under \(EvalSessions.displayPath) — `arnes evals transcript <id>` to read one"))
      }
    }
    // The closing block above goes through bare `print`: flush it like the progress lines, so a
    // redirected log holds the table before the exit code ends the process.
    fflush(Foundation.stdout)
    // The gate's verdict is the exit code — after every line, so a script reads the document
    // and then the code (2 = the gate failed; anything the command itself threw is 1).
    if exitCode != ArnesExit.ok.rawValue {
      throw ExitCode(exitCode)
    }
  }

  /// The per-model table, exactly as it has always been rendered (the golden test pins it).
  static func renderStats(_ stats: [EvalStats], taskCount: Int, trials: Int) -> String {
    var lines = [statsHeader, statsRule]
    for row in stats {
      lines.append(statsRow(row))
    }
    return lines.joined(separator: "\n")
  }

  /// The same table with, under a model's row, its `pass@k a/t · pass^k b/t` line — only when
  /// the run had more than one trial per task (`k > 1`); a single-trial run renders exactly as
  /// `renderStats(_:taskCount:trials:)` does. A model that ran under two dialects gets one
  /// line per dialect, tagged.
  static func renderStats(_ stats: [EvalStats], summaries: [EvalModelSummary], taskCount: Int, trials: Int) -> String {
    var lines = [statsHeader, statsRule]
    for row in stats {
      lines.append(statsRow(row))
      lines.append(contentsOf: passAtKLines(for: row.model, summaries: summaries))
    }
    return lines.joined(separator: "\n")
  }

  private static let statsHeader = "model                                     pass        cost      steps    time   errors"
  private static let statsRule = String(repeating: "─", count: 88)

  private static func statsRow(_ row: EvalStats) -> String {
    let model = row.model.padding(toLength: 40, withPad: " ", startingAt: 0)
    let pass = "\(row.passed)/\(row.trials) (\(Int(row.passRate * 100))%)"
      .padding(toLength: 12, withPad: " ", startingAt: 0)
    let cost = String(format: "$%.4f", row.totalCostUSD)
      .padding(toLength: 10, withPad: " ", startingAt: 0)
    let steps = String(format: "%.1f", row.averageSteps)
      .padding(toLength: 7, withPad: " ", startingAt: 0)
    let time = String(format: "%.1fs", row.averageDurationSeconds)
      .padding(toLength: 7, withPad: " ", startingAt: 0)
    return "\(model)  \(pass)\(cost)\(steps)\(time)\(row.errors)"
  }

  /// `  pass@3 7/8 · pass^3 5/8` for each of the model's summaries that has a k above 1;
  /// nothing for a single-trial run.
  static func passAtKLines(for model: String, summaries: [EvalModelSummary]) -> [String] {
    let mine = summaries.filter { $0.model == model }
    return mine.compactMap { summary in
      guard EvalReport.passAtK(summary) != nil else { return nil }
      let k = summary.trialsPerTask
      var line = "  pass@\(k) \(summary.tasksWithAnyPass)/\(summary.tasks) · pass^\(k) \(summary.tasksWithAllPass)/\(summary.tasks)"
      if mine.count > 1 {
        line += " · \(summary.dialect ?? "–")"
      }
      return line
    }
  }

  /// The compare block: what the baseline was, then `regressions:` and `fixes:` with one
  /// `  <task> · <model> [· <dialect>]: <prev>% → <now>%` line each (or `  (none)`), then the
  /// keys with nothing to compare against as `n/a → <now>%`.
  static func compareLines(_ comparison: EvalComparison, window: EvalReport.Window) -> [String] {
    func percent(_ rate: Double?) -> String {
      rate.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a"
    }
    func entry(_ row: EvalRegression) -> String {
      "  \(row.taskId) · \(row.model)" + (row.dialect.map { " · \($0)" } ?? "")
        + ": \(percent(row.previousPassRate)) → \(percent(row.currentPassRate))"
    }
    let baseline: String
    switch window {
    case .last(let rows): baseline = "the newest \(rows) row(s) per task"
    case .days(let days): baseline = "the \(days) day(s) before this run"
    }
    var lines = ["compare against \(baseline):"]
    lines.append("regressions:")
    lines.append(contentsOf: comparison.regressions.isEmpty ? ["  (none)"] : comparison.regressions.map(entry))
    lines.append("fixes:")
    lines.append(contentsOf: comparison.fixes.isEmpty ? ["  (none)"] : comparison.fixes.map(entry))
    if !comparison.withoutBaseline.isEmpty {
      lines.append("no baseline in the window:")
      lines.append(contentsOf: comparison.withoutBaseline.map(entry))
    }
    return lines
  }

  /// `gate passed (min pass 100%, no regression)` / `gate FAILED (…) — exit 2`.
  static func gateLine(_ gate: EvalGate, passed: Bool) -> String {
    var terms: [String] = []
    if let minPass = gate.minPass {
      terms.append("min pass \(Int((minPass * 100).rounded()))%")
    }
    if gate.failOnRegression {
      terms.append("no regression")
    }
    let what = terms.joined(separator: ", ")
    return passed
      ? ANSI.green("gate passed") + " (\(what))"
      : ANSI.red("gate FAILED") + " (\(what)) — exit \(EvalGate.failedExitCode)"
  }

  /// The `--compare` value as the document spells it: `last` or `<N>d`, trimmed and lowercased.
  static func compareSpelling(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespaces).lowercased()
  }
}

// MARK: - EvalSessions

/// Where `arnes eval` keeps trial transcripts: `~/.arnes/eval-sessions/`, a `SessionStore` of
/// its own beside the user's `sessions/` so `arnes sessions`, `resume` and the retention sweep
/// never see a trial. Read by `evals transcript`, swept by `evals prune`, searched by
/// `evals capture --session`.
enum EvalSessions {
  static let directoryName = "eval-sessions"
  static let displayPath = "~/.arnes/\(directoryName)"

  static var directory: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/\(directoryName)")
  }

  static func store() -> SessionStore {
    SessionStore(directory: directory)
  }

  /// Resolves an `evals transcript` query: the one id/prefix/name rule over the store's
  /// transcripts first, then a `runId`/`sessionId` prefix over the eval rows (a run id is what
  /// `runs.jsonl` shows, a session id what the transcript is named after). Pure over its inputs.
  static func resolve(
    _ query: String,
    sessions: [SessionMeta],
    outcomes: [EvalOutcome])
    throws -> String
  {
    switch SessionStore.match(query, in: sessions) {
    case .found(let meta):
      return meta.id
    case .ambiguous(let candidates):
      let ids = candidates.map { String($0.id.prefix(8)) }.joined(separator: ", ")
      throw ValidationError("'\(query)' matches several eval transcripts: \(ids) — give more of the id")
    case .none:
      break
    }
    let lowered = query.lowercased()
    let matched = outcomes.filter { row in
      (row.runId?.lowercased().hasPrefix(lowered) ?? false)
        || (row.sessionId?.lowercased().hasPrefix(lowered) ?? false)
    }
    let sessionIds = Set(matched.compactMap(\.sessionId))
    if sessionIds.count == 1, let id = sessionIds.first, sessions.contains(where: { $0.id == id }) {
      return id
    }
    if sessionIds.count > 1 {
      let ids = sessionIds.sorted().map { String($0.prefix(8)) }.joined(separator: ", ")
      throw ValidationError("'\(query)' matches several eval rows: \(ids) — give more of the id")
    }
    throw ValidationError(
      "no eval transcript matching '\(query)' — ids are the sessionId/runId fields of the rows in "
        + "~/.arnes/evals.jsonl (`arnes evals` summarizes them; `arnes evals transcript` with no id "
        + "lists the transcripts kept under \(displayPath))")
  }
}
