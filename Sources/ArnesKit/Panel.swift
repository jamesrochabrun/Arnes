import Foundation
import OpenRouterSwift

// MARK: - PanelCandidate

/// One attempt in a panel run: an agent working in its own snapshot of the base
/// directory, plus everything the judge (and the eval log) needs about it.
public struct PanelCandidate: Sendable {
  /// Zero-based position in the panel.
  public let index: Int
  public let model: String
  /// The agent's final report ("" when it errored or timed out before reporting).
  public let report: String
  /// The turn's `RunRecord` (nil when the run errored before producing one).
  public let record: RunRecord?
  /// Unified diff of the candidate's snapshot against the base directory, with the
  /// temp paths rewritten to `base`/`candidate`. Empty when nothing changed.
  public let diff: String
  public let durationSeconds: Double
  /// Timeout or thrown error, when the candidate did not complete normally.
  public let error: String?

  /// A candidate the judge should consider: it ran to completion or at least left work.
  var judgeable: Bool { error == nil || !diff.isEmpty }
}

// MARK: - PanelVerdict / PanelResult

public struct PanelVerdict: Sendable {
  /// Zero-based index into `PanelResult.candidates`.
  public let winnerIndex: Int
  public let reason: String
  public let judgeModel: String
  public let judgeCostUSD: Double
}

public struct PanelResult: Sendable {
  public let candidates: [PanelCandidate]
  public let verdict: PanelVerdict
  /// Whether the winner's changes were synced back into the base directory.
  public let applied: Bool
  /// The winner's snapshot, kept on disk when the changes were not applied.
  public let winnerDirectory: URL?

  public var winner: PanelCandidate { candidates[verdict.winnerIndex] }
}

public enum PanelError: Error, Sendable {
  /// A panel needs at least two candidates — use plain `arnes do` for one.
  case needsTwoCandidates
  /// Every candidate errored before doing any work; there is nothing to judge.
  case allCandidatesFailed
  /// The judge's reply did not contain a usable `WINNER: <n>` verdict.
  case judgeFailed(String)
}

// MARK: - PanelRunner

/// Loop 2: fans one task to N models in isolated snapshots of the working directory,
/// runs them concurrently, has a judge model pick the winner from reports + diffs, and
/// syncs the winner's changes back. Every candidate becomes a labeled `EvalOutcome`
/// (suite "panel", label = judged winner), so real work grows the eval history for free.
public final class PanelRunner: @unchecked Sendable {
  public enum Progress: Sendable {
    case candidateStarted(index: Int, model: String)
    case candidateFinished(PanelCandidate)
    case judged(PanelVerdict)
  }

  private let service: OpenRouterService
  private let recordStore: RunRecordStore
  private let evalStore: EvalStore
  private let maxSteps: Int
  private let timeoutSeconds: Int

  public init(
    service: OpenRouterService,
    recordStore: RunRecordStore = RunRecordStore(),
    evalStore: EvalStore = EvalStore(),
    maxSteps: Int = 30,
    timeoutSeconds: Int = 600)
  {
    self.service = service
    self.recordStore = recordStore
    self.evalStore = evalStore
    self.maxSteps = maxSteps
    self.timeoutSeconds = timeoutSeconds
  }

  public func run(
    task: String,
    models: [String],
    judgeModel: String,
    baseDirectory: URL,
    apply: Bool = true,
    onProgress: @escaping @Sendable (Progress) -> Void = { _ in })
    async throws -> PanelResult
  {
    guard models.count >= 2 else { throw PanelError.needsTwoCandidates }
    let base = URL(fileURLWithPath: baseDirectory.path).resolvingSymlinksInPath()
    let panelDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-panel-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: panelDir, withIntermediateDirectories: true)

    var candidates = await runCandidates(
      task: task,
      models: models,
      base: base,
      panelDir: panelDir,
      onProgress: onProgress)
    candidates.sort { $0.index < $1.index }

    let verdict: PanelVerdict
    do {
      verdict = try await judge(task: task, candidates: candidates, judgeModel: judgeModel)
    } catch {
      try? FileManager.default.removeItem(at: panelDir)
      throw error
    }
    onProgress(.judged(verdict))

    for candidate in candidates {
      try? evalStore.append(outcome(
        task: task,
        candidate: candidate,
        isWinner: candidate.index == verdict.winnerIndex))
    }

    let winnerDir = panelDir.appendingPathComponent("candidate-\(verdict.winnerIndex)")
    var keptDirectory: URL?
    if apply {
      try Self.sync(from: winnerDir, into: base)
      try? FileManager.default.removeItem(at: panelDir)
    } else {
      // Keep only the winner's snapshot for inspection.
      for candidate in candidates where candidate.index != verdict.winnerIndex {
        try? FileManager.default.removeItem(
          at: panelDir.appendingPathComponent("candidate-\(candidate.index)"))
      }
      keptDirectory = winnerDir
    }

    return PanelResult(
      candidates: candidates,
      verdict: verdict,
      applied: apply,
      winnerDirectory: keptDirectory)
  }

  // MARK: Candidates

  private func runCandidates(
    task: String,
    models: [String],
    base: URL,
    panelDir: URL,
    onProgress: @escaping @Sendable (Progress) -> Void)
    async -> [PanelCandidate]
  {
    await withTaskGroup(of: PanelCandidate.self, returning: [PanelCandidate].self) { group in
      for (index, model) in models.enumerated() {
        group.addTask {
          onProgress(.candidateStarted(index: index, model: model))
          let candidate = await self.runCandidate(
            task: task, model: model, index: index, base: base, panelDir: panelDir)
          onProgress(.candidateFinished(candidate))
          return candidate
        }
      }
      var results: [PanelCandidate] = []
      for await candidate in group {
        results.append(candidate)
      }
      return results
    }
  }

  private func runCandidate(
    task: String,
    model: String,
    index: Int,
    base: URL,
    panelDir: URL)
    async -> PanelCandidate
  {
    let started = Date()
    let workdir = panelDir.appendingPathComponent("candidate-\(index)")
    do {
      try Self.snapshot(of: base, to: workdir)
    } catch {
      return PanelCandidate(
        index: index, model: model, report: "", record: nil, diff: "",
        durationSeconds: Date().timeIntervalSince(started),
        error: "snapshot: \(error)")
    }

    let agent = Agent(
      service: service,
      tools: Session.tools(root: workdir),
      permissions: AutoApprovePermissions(),
      store: recordStore,
      maxSteps: maxSteps)
    let prompt = "Work in the current directory.\n\n\(task)"
    let timeout = TimeInterval(timeoutSeconds)

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

    // Diff regardless of how the run ended — a timed-out candidate may still have work
    // worth judging.
    let diff = Self.diff(base: base, candidate: workdir)
    switch raced {
    case .success(let result):
      return PanelCandidate(
        index: index, model: model, report: result.text, record: result.record,
        diff: diff, durationSeconds: Date().timeIntervalSince(started), error: nil)
    case .failure(let error):
      return PanelCandidate(
        index: index, model: model, report: "", record: nil,
        diff: diff, durationSeconds: Date().timeIntervalSince(started), error: "\(error)")
    case nil:
      return PanelCandidate(
        index: index, model: model, report: "", record: nil,
        diff: diff, durationSeconds: Date().timeIntervalSince(started),
        error: "timeout after \(timeoutSeconds)s")
    }
  }

  // MARK: Judge

  private static let maxDiffCharsForJudge = 12_000
  private static let maxReportCharsForJudge = 4_000

  private func judge(
    task: String,
    candidates: [PanelCandidate],
    judgeModel: String)
    async throws -> PanelVerdict
  {
    let judgeable = candidates.filter(\.judgeable)
    guard !judgeable.isEmpty else { throw PanelError.allCandidatesFailed }
    if judgeable.count == 1 {
      return PanelVerdict(
        winnerIndex: judgeable[0].index,
        reason: "only surviving candidate",
        judgeModel: judgeModel,
        judgeCostUSD: 0)
    }

    var sections: [String] = ["Task:\n\(task)"]
    for candidate in judgeable {
      let report = candidate.report.isEmpty
        ? "(no report — \(candidate.error ?? "empty"))"
        : String(candidate.report.prefix(Self.maxReportCharsForJudge))
      let changes = candidate.diff.isEmpty
        ? "(no file changes)"
        : String(candidate.diff.prefix(Self.maxDiffCharsForJudge))
      sections.append("""
        ## Attempt \(candidate.index + 1) (\(candidate.model))
        Report:
        \(report)
        File changes:
        \(changes)
        """)
    }

    let response = try await service.chatCompletion(
      ChatCompletionRequest(
        model: judgeModel,
        messages: [
          .system("""
            You judge several agents' attempts at the same task. Pick the attempt whose \
            file changes best complete the task: working and complete beats partial, \
            minimal beats sprawling, and a report is only as good as the changes backing \
            it. Reply with exactly one line 'WINNER: <attempt number>' followed by a \
            one-sentence reason.
            """),
          .user(sections.joined(separator: "\n\n")),
        ]))
    let text = response.choices.first?.message.content ?? ""
    guard
      let number = Self.parseWinner(text),
      let winner = judgeable.first(where: { $0.index + 1 == number })
    else {
      throw PanelError.judgeFailed(text)
    }
    return PanelVerdict(
      winnerIndex: winner.index,
      reason: text.trimmingCharacters(in: .whitespacesAndNewlines),
      judgeModel: judgeModel,
      judgeCostUSD: response.usage?.cost ?? 0)
  }

  /// Extracts `<n>` from the first `WINNER: <n>` line in the judge's reply.
  static func parseWinner(_ text: String) -> Int? {
    for line in text.split(separator: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.uppercased().hasPrefix("WINNER") else { continue }
      let digits = trimmed.drop { !$0.isNumber }.prefix { $0.isNumber }
      return Int(digits)
    }
    return nil
  }

  // MARK: Eval rows

  private func outcome(task: String, candidate: PanelCandidate, isWinner: Bool) -> EvalOutcome {
    EvalOutcome(
      suite: "panel",
      taskId: String(task.prefix(60)),
      model: candidate.model,
      trial: candidate.index + 1,
      checkPassed: isWinner,
      agentFinished: candidate.record?.finished ?? false,
      steps: candidate.record?.steps ?? 0,
      toolCalls: candidate.record?.toolCalls ?? 0,
      costUSD: candidate.record?.costUSD ?? 0,
      durationSeconds: candidate.durationSeconds,
      startedAt: candidate.record?.startedAt ?? Date(),
      routedModels: candidate.record?.routedModels ?? [],
      error: candidate.error)
  }

  // MARK: Directory plumbing

  /// Copies the base directory into `destination`. Uses `cp` so APFS clones make the
  /// copy near-instant on macOS; plain `cp -R` is the portable fallback.
  static func snapshot(of base: URL, to destination: URL) throws {
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let src = shellQuote(base.path)
    let dst = shellQuote(destination.path)
    let result = EvalRunner.bash(
      "cp -Rc \(src)/. \(dst)/ 2>/dev/null || cp -R \(src)/. \(dst)/",
      cwd: destination,
      timeoutSeconds: 300)
    guard result.exit == 0 else {
      throw PanelPlumbingError.copyFailed(String(result.output.prefix(300)))
    }
  }

  /// Unified recursive diff of a candidate against the base, `.git` excluded, temp
  /// paths rewritten so the judge reads `base/…` and `candidate/…`.
  static func diff(base: URL, candidate: URL) -> String {
    let result = EvalRunner.bash(
      "diff -ruN -x .git \(shellQuote(base.path)) \(shellQuote(candidate.path))",
      cwd: candidate,
      timeoutSeconds: 60)
    guard result.exit != 0 else { return "" }
    return result.output
      .replacingOccurrences(of: candidate.path, with: "candidate")
      .replacingOccurrences(of: base.path, with: "base")
  }

  /// Makes `destination` mirror `source` (contents compared file by file), leaving
  /// `.git` in the destination untouched. This is how the winner lands in the real
  /// working directory.
  static func sync(from source: URL, into destination: URL) throws {
    let sourceFiles = relativeFiles(under: source)
    let destinationFiles = relativeFiles(under: destination)
    let fileManager = FileManager.default

    for relative in sourceFiles {
      let from = source.appendingPathComponent(relative)
      let to = destination.appendingPathComponent(relative)
      if fileManager.fileExists(atPath: to.path) {
        guard !fileManager.contentsEqual(atPath: from.path, andPath: to.path) else { continue }
        try fileManager.removeItem(at: to)
      } else {
        try fileManager.createDirectory(
          at: to.deletingLastPathComponent(),
          withIntermediateDirectories: true)
      }
      try fileManager.copyItem(at: from, to: to)
    }
    for relative in destinationFiles.subtracting(sourceFiles) {
      try? fileManager.removeItem(at: destination.appendingPathComponent(relative))
    }
  }

  /// Relative paths of every regular file under `root` (hidden files included), with
  /// everything inside `.git` skipped.
  static func relativeFiles(under root: URL) -> Set<String> {
    guard let enumerator = FileManager.default.enumerator(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey])
    else {
      return []
    }
    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
    var files: Set<String> = []
    for case let url as URL in enumerator {
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(prefix) else { continue }
      let relative = String(path.dropFirst(prefix.count))
      if relative == ".git" || relative.hasPrefix(".git/") {
        enumerator.skipDescendants()
        continue
      }
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      files.insert(relative)
    }
    return files
  }

  static func shellQuote(_ path: String) -> String {
    "'\(path.replacingOccurrences(of: "'", with: "'\\''"))'"
  }
}

enum PanelPlumbingError: Error, Sendable {
  case copyFailed(String)
}
