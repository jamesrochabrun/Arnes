import Foundation
import OpenRouterSwift

// MARK: - EvalTask

/// One eval task: a prompt the agent must complete and a bash check that decides
/// pass/fail programmatically (exit 0 = pass). Optional setup runs first.
/// Checks are the ground truth — the LLM verifier is a complement, not the scorer.
public struct EvalTask: Codable, Sendable {
  public var id: String
  public var prompt: String
  /// Bash to prepare the working directory before the agent runs.
  public var setup: String?
  /// Bash run in the working directory after the agent; exit 0 means the task passed.
  public var check: String
  /// Wall-clock budget for the agent (default 300s).
  public var timeoutSeconds: Int?

  public init(id: String, prompt: String, setup: String? = nil, check: String, timeoutSeconds: Int? = nil) {
    self.id = id
    self.prompt = prompt
    self.setup = setup
    self.check = check
    self.timeoutSeconds = timeoutSeconds
  }
}

// MARK: - EvalSuite

/// A named collection of tasks, loaded from a directory of `.json` files (each holding
/// a task or an array of tasks) or a single `.json` file.
public struct EvalSuite: Sendable {
  public let name: String
  public let tasks: [EvalTask]

  public init(name: String, tasks: [EvalTask]) {
    self.name = name
    self.tasks = tasks
  }

  public static func load(path: String) throws -> EvalSuite {
    let url = URL(fileURLWithPath: path)
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
      throw EvalError.suiteNotFound(path)
    }
    let files: [URL] = isDirectory.boolValue
      ? (try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil))
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
      : [url]
    let decoder = JSONDecoder()
    var tasks: [EvalTask] = []
    for file in files {
      let data = try Data(contentsOf: file)
      if let many = try? decoder.decode([EvalTask].self, from: data) {
        tasks.append(contentsOf: many)
      } else {
        tasks.append(try decoder.decode(EvalTask.self, from: data))
      }
    }
    guard !tasks.isEmpty else { throw EvalError.emptySuite(path) }
    return EvalSuite(name: url.deletingPathExtension().lastPathComponent, tasks: tasks)
  }
}

public enum EvalError: Error, Sendable {
  case suiteNotFound(String)
  case emptySuite(String)
}

// MARK: - EvalOutcome

/// One trial's result — the row every statistic aggregates from.
public struct EvalOutcome: Codable, Sendable {
  public var suite: String
  public var taskId: String
  public var model: String
  public var trial: Int
  /// The programmatic check's verdict — the ground truth.
  public var checkPassed: Bool
  /// Whether the agent loop reached a natural stop (vs. step cap / timeout / error).
  public var agentFinished: Bool
  public var steps: Int
  public var toolCalls: Int
  public var costUSD: Double
  public var durationSeconds: Double
  public var startedAt: Date
  public var routedModels: [String]
  /// Timeout or thrown error, when the trial did not complete normally.
  public var error: String?
}

/// Append-only JSONL store at `~/.arnes/evals.jsonl` — the growing eval history.
public struct EvalStore: Sendable {
  public let url: URL

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/evals.jsonl"))
  {
    self.url = url
  }

  public func append(_ outcome: EvalOutcome) throws {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var line = try encoder.encode(outcome)
    line.append(Data("\n".utf8))
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(),
      withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      try handle.seekToEnd()
      try handle.write(contentsOf: line)
    } else {
      try line.write(to: url)
    }
  }

  public func all() throws -> [EvalOutcome] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { try? decoder.decode(EvalOutcome.self, from: Data($0.utf8)) }
  }
}

// MARK: - EvalRunner

/// Runs a suite: every model × task × trial in a fresh temporary working directory,
/// scored by the task's check script. Trials run sequentially (the working directory
/// is the process CWD while the agent runs). Agent runs also append `RunRecord`s, so
/// evals feed the same scoreboard as normal usage.
public final class EvalRunner: @unchecked Sendable {
  public enum Progress: Sendable {
    case trialStarted(taskId: String, model: String, trial: Int)
    case trialFinished(EvalOutcome)
  }

  private let service: OpenRouterService
  private let tools: [any AgentTool]
  private let store: EvalStore
  private let recordStore: RunRecordStore
  private let maxSteps: Int

  public init(
    service: OpenRouterService,
    tools: [any AgentTool] = Session.defaultTools,
    store: EvalStore = EvalStore(),
    recordStore: RunRecordStore = RunRecordStore(),
    maxSteps: Int = 30)
  {
    self.service = service
    self.tools = tools
    self.store = store
    self.recordStore = recordStore
    self.maxSteps = maxSteps
  }

  public func run(
    suite: EvalSuite,
    models: [String],
    trials: Int = 1,
    onProgress: @escaping @Sendable (Progress) -> Void = { _ in })
    async -> [EvalOutcome]
  {
    var outcomes: [EvalOutcome] = []
    for model in models {
      for task in suite.tasks {
        for trial in 1...max(1, trials) {
          onProgress(.trialStarted(taskId: task.id, model: model, trial: trial))
          let outcome = await runTrial(suite: suite.name, task: task, model: model, trial: trial)
          try? store.append(outcome)
          outcomes.append(outcome)
          onProgress(.trialFinished(outcome))
        }
      }
    }
    return outcomes
  }

  private func runTrial(suite: String, task: EvalTask, model: String, trial: Int) async -> EvalOutcome {
    let startedAt = Date()
    var outcome = EvalOutcome(
      suite: suite,
      taskId: task.id,
      model: model,
      trial: trial,
      checkPassed: false,
      agentFinished: false,
      steps: 0,
      toolCalls: 0,
      costUSD: 0,
      durationSeconds: 0,
      startedAt: startedAt,
      routedModels: [],
      error: nil)

    let workdir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-eval-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    } catch {
      outcome.error = "workdir: \(error)"
      return outcome
    }
    defer { try? FileManager.default.removeItem(at: workdir) }

    if let setup = task.setup {
      let result = Self.bash(setup, cwd: workdir, timeoutSeconds: 60)
      guard result.exit == 0 else {
        outcome.error = "setup failed (exit \(result.exit)): \(String(result.output.prefix(300)))"
        outcome.durationSeconds = Date().timeIntervalSince(startedAt)
        return outcome
      }
    }

    // The agent works in the trial directory; tools resolve relative paths there.
    let previousCWD = FileManager.default.currentDirectoryPath
    FileManager.default.changeCurrentDirectoryPath(workdir.path)
    defer { FileManager.default.changeCurrentDirectoryPath(previousCWD) }

    let agent = Agent(
      service: service,
      tools: tools,
      permissions: AutoApprovePermissions(),
      store: recordStore,
      maxSteps: maxSteps)
    let prompt = "Work in the current directory.\n\n\(task.prompt)"
    let timeout = TimeInterval(task.timeoutSeconds ?? 300)

    let raced: Result<AgentResult, Error>? = await withTaskGroup(
      of: Result<AgentResult, Error>?.self)
    { group in
      group.addTask {
        do {
          return .success(try await agent.run(task: prompt, model: model))
        } catch {
          return .failure(error)
        }
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }

    switch raced {
    case .success(let result):
      outcome.agentFinished = result.record.finished
      outcome.steps = result.record.steps
      outcome.toolCalls = result.record.toolCalls
      outcome.costUSD = result.record.costUSD
      outcome.routedModels = result.record.routedModels
    case .failure(let error):
      outcome.error = "\(error)"
    case nil:
      outcome.error = "timeout after \(Int(timeout))s"
    }

    // Score regardless — a timed-out agent may still have completed the work.
    let check = Self.bash(task.check, cwd: workdir, timeoutSeconds: 60)
    outcome.checkPassed = check.exit == 0
    outcome.durationSeconds = Date().timeIntervalSince(startedAt)
    return outcome
  }

  /// Runs bash in a directory with a hard timeout (the process is terminated).
  static func bash(_ command: String, cwd: URL, timeoutSeconds: Int) -> (exit: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    process.currentDirectoryURL = cwd
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do {
      try process.run()
    } catch {
      return (127, "cannot run bash: \(error)")
    }
    let deadline = DispatchWorkItem { [weak process] in
      if process?.isRunning == true { process?.terminate() }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSeconds), execute: deadline)
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    deadline.cancel()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
  }
}

// MARK: - EvalStats

/// Per-model aggregation over outcomes — the scoreboard row.
public struct EvalStats: Sendable {
  public let model: String
  public let trials: Int
  public let passed: Int
  public let totalCostUSD: Double
  public let averageSteps: Double
  public let averageDurationSeconds: Double
  public let errors: Int

  public var passRate: Double { trials == 0 ? 0 : Double(passed) / Double(trials) }

  public static func aggregate(_ outcomes: [EvalOutcome]) -> [EvalStats] {
    let byModel = Dictionary(grouping: outcomes, by: \.model)
    var stats: [EvalStats] = []
    for (model, rows) in byModel {
      let count = Double(rows.count)
      var totalCost = 0.0
      var totalSteps = 0
      var totalDuration = 0.0
      var passed = 0
      var errors = 0
      for row in rows {
        totalCost += row.costUSD
        totalSteps += row.steps
        totalDuration += row.durationSeconds
        if row.checkPassed { passed += 1 }
        if row.error != nil { errors += 1 }
      }
      stats.append(EvalStats(
        model: model,
        trials: rows.count,
        passed: passed,
        totalCostUSD: totalCost,
        averageSteps: count == 0 ? 0 : Double(totalSteps) / count,
        averageDurationSeconds: count == 0 ? 0 : totalDuration / count,
        errors: errors))
    }
    return stats.sorted {
      if $0.passRate != $1.passRate { return $0.passRate > $1.passRate }
      return $0.totalCostUSD < $1.totalCostUSD
    }
  }
}
