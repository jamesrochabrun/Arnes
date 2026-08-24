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
      """)

  @Argument(help: "Path to a suite directory or task .json file.")
  var suite: String

  @Option(name: .shortAndLong, help: "Models to evaluate, comma-separated.")
  var models = "openrouter/auto"

  @Option(name: .shortAndLong, help: "Trials per model per task.")
  var trials = 1

  @Option(help: "Run only this task id.")
  var task: String?

  @Option(help: "Max agent steps per trial.")
  var maxSteps = 30

  func run() async throws {
    let service = try makeService()
    var loaded = try EvalSuite.load(path: suite)
    if let task {
      let filtered = loaded.tasks.filter { $0.id == task }
      guard !filtered.isEmpty else {
        throw ValidationError("no task '\(task)' in suite \(loaded.name)")
      }
      loaded = EvalSuite(name: loaded.name, tasks: filtered)
    }
    let modelList = models.split(separator: ",").map(String.init)
    let totalTrials = modelList.count * loaded.tasks.count * trials
    print(ANSI.dim("suite \(loaded.name) · \(loaded.tasks.count) tasks · \(modelList.count) models · \(trials) trial(s) → \(totalTrials) runs\n"))

    let runner = EvalRunner(service: service, maxSteps: maxSteps)
    let outcomes = await runner.run(suite: loaded, models: modelList, trials: trials) { progress in
      switch progress {
      case .trialStarted(let taskId, let model, let trial):
        print(ANSI.dim("▶ \(taskId) · \(model) · trial \(trial)"))
      case .trialFinished(let outcome):
        let mark = outcome.checkPassed ? ANSI.green("✓") : ANSI.red("✗")
        var line = "\(mark) \(outcome.taskId) · \(outcome.model)"
          + " · \(outcome.steps) steps · \(Renderer.usd(outcome.costUSD))"
          + String(format: " · %.1fs", outcome.durationSeconds)
        if let error = outcome.error {
          line += ANSI.yellow(" · \(String(error.prefix(80)))")
        }
        print(line)
      }
    }

    print("\n" + renderStats(EvalStats.aggregate(outcomes), taskCount: loaded.tasks.count, trials: trials))
    print(ANSI.dim("\noutcomes appended to ~/.arnes/evals.jsonl"))
  }

  private func renderStats(_ stats: [EvalStats], taskCount: Int, trials: Int) -> String {
    var lines = [
      "model                                     pass        cost      steps    time   errors",
      String(repeating: "─", count: 88),
    ]
    for row in stats {
      let model = row.model.padding(toLength: 40, withPad: " ", startingAt: 0)
      let pass = "\(row.passed)/\(row.trials) (\(Int(row.passRate * 100))%)"
        .padding(toLength: 12, withPad: " ", startingAt: 0)
      let cost = String(format: "$%.4f", row.totalCostUSD)
        .padding(toLength: 10, withPad: " ", startingAt: 0)
      let steps = String(format: "%.1f", row.averageSteps)
        .padding(toLength: 7, withPad: " ", startingAt: 0)
      let time = String(format: "%.1fs", row.averageDurationSeconds)
        .padding(toLength: 7, withPad: " ", startingAt: 0)
      lines.append("\(model)  \(pass)\(cost)\(steps)\(time)\(row.errors)")
    }
    return lines.joined(separator: "\n")
  }
}
