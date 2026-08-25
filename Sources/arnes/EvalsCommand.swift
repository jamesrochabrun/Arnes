import ArgumentParser
import ArnesKit
import Foundation

// MARK: - evals

struct Evals: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Inspect, capture, and prune the eval history (~/.arnes/evals.jsonl).",
    subcommands: [EvalsShow.self, EvalsCapture.self, EvalsPrune.self],
    defaultSubcommand: EvalsShow.self)
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
    let rows = EvalHistoryRow.aggregate(outcomes)
    guard !rows.isEmpty else {
      print("no matching eval history — run a suite with `arnes eval <suite> -m <model>`")
      return
    }

    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd HH:mm"
    print(ANSI.dim("suite        model                                 dialect    pass                       cost      last run"))
    print(ANSI.dim(String(repeating: "─", count: 110)))
    var currentSuite = ""
    for row in rows {
      let suiteLabel = row.suite == currentSuite ? "" : row.suite
      currentSuite = row.suite
      let bar = Self.bar(row.passRate)
      let pass = "\(row.passed)/\(row.trials) (\(Int(row.passRate * 100))%)"
      print(
        suiteLabel.padding(toLength: 13, withPad: " ", startingAt: 0)
        + row.model.padding(toLength: 38, withPad: " ", startingAt: 0)
        + (row.dialect ?? "–").padding(toLength: 11, withPad: " ", startingAt: 0)
        + bar + " " + pass.padding(toLength: 13, withPad: " ", startingAt: 0)
        + String(format: "$%.4f", row.totalCostUSD).padding(toLength: 10, withPad: " ", startingAt: 0)
        + formatter.string(from: row.lastRun))
    }
    let totalTrials = rows.reduce(0) { $0 + $1.trials }
    let totalCost = rows.reduce(0.0) { $0 + $1.totalCostUSD }
    print(ANSI.dim("\n\(totalTrials) trials · total cost \(String(format: "$%.4f", totalCost)) · prune with `arnes evals prune`"))
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

  @Option(name: .shortAndLong, help: "Writer model (default: openrouter/auto).")
  var model = "openrouter/auto"

  @Option(name: .shortAndLong, help: "Suite directory to write the task into.")
  var output = "evals/captured"

  func run() async throws {
    let service = try makeService()
    let distiller = EvalTaskDistiller(service: service)

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
          print("✔ turn \(index + 1): \(ANSI.bold(result.task.id)) → \(file.path)")
        } catch {
          // One bad turn shouldn't sink the rest of the session.
          print(ANSI.yellow("✘ turn \(index + 1): \(String("\(error)".prefix(120)))"))
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

    let result = try await distiller.distill(from: source, hint: hint, model: model)
    let file = try write(task: result.task)
    print("✔ captured \(ANSI.bold(result.task.id)) → \(file.path)  (validated: setup ok, check fails pre-work)")
    print(ANSI.dim("  prompt: \(String(result.task.prompt.prefix(100)))"))
    print(ANSI.dim("  writer cost \(String(format: "$%.4f", result.costUSD)) · \(result.attempts) attempt(s)"))
    print("run it:  arnes eval \(output) -m deepseek/deepseek-v4-flash")
  }

  private func loadSession() throws -> (SessionMeta, LoadedSession) {
    let store = SessionStore()
    let meta: SessionMeta
    if let session {
      guard let found = try store.list().first(where: { $0.id == session || $0.id.hasPrefix(session) }) else {
        throw ValidationError("no session matching '\(session)' — see `arnes sessions`")
      }
      meta = found
    } else {
      guard let recent = store.mostRecent() else {
        throw ValidationError("no saved sessions — pass --task \"<description>\" instead")
      }
      meta = recent
    }
    return (meta, try store.load(id: meta.id))
  }

  private func write(task: EvalTask) throws -> URL {
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
    abstract: "Delete rows from the eval history. Combines filters; requires at least one.")

  @Option(help: "Remove rows older than N days.")
  var olderThan: Int?

  @Option(help: "Remove rows of this suite (e.g. panel).")
  var suite: String?

  @Option(name: .shortAndLong, help: "Remove rows whose model contains this substring.")
  var model: String?

  @Flag(help: "Remove everything (the filters above are ignored).")
  var all = false

  func run() throws {
    guard all || olderThan != nil || suite != nil || model != nil else {
      throw ValidationError("pass a filter: --older-than <days>, --suite <name>, --model <substring>, or --all")
    }
    let cutoff = olderThan.map { Date().addingTimeInterval(-Double($0) * 86_400) }
    let (kept, removed) = try EvalStore().rewrite { outcome in
      if all { return false }
      // A row is removed only when it matches EVERY given filter.
      if let cutoff, outcome.startedAt >= cutoff { return true }
      if let suite, outcome.suite != suite { return true }
      if let model, !outcome.model.localizedCaseInsensitiveContains(model) { return true }
      return false
    }
    print("removed \(removed) row(s) · kept \(kept) · ~/.arnes/evals.jsonl")
  }
}
