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
  /// Whether the candidate's tools ran OS-confined. Recorded on the eval row it becomes,
  /// since confinement changes what a candidate could do.
  public var sandboxed = false

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
  /// The judge's reply named no attempt — neither as the structured `winner` nor as a
  /// `WINNER: <n>` line in its prose (the associated text is the reply).
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
  private let catalog: ModelCatalog?
  private let provider: ProviderTraits
  /// Builds the OS sandbox for a candidate's snapshot directory, when the provider opted
  /// in. Candidates run unattended under AutoApprove, so without this a candidate's bash
  /// could reach `$HOME` or the network exactly as a `--yes` run's could. nil = no sandbox.
  private let makeSandbox: (@Sendable (URL) -> ShellSandbox?)?
  /// Environment policy for candidate bash — the provider token is withheld regardless.
  private let subprocessEnvironment: SubprocessEnvironment
  /// Lifecycle hooks each candidate's session runs — the per-call and compaction ones
  /// (`forNestedRun`). The user's guardrails apply to unattended work too (a panel that
  /// dropped them would be the way around every hook), but a candidate's finish is not the
  /// user's turn end and its session is not the user's session, so `Stop`, the delegation
  /// pair and the session-level events stay with the command that runs the panel. Hooks run
  /// with the candidate's snapshot as `cwd`.
  private let hooks: [HookDefinition]
  /// Executes the `type: prompt` definitions in `hooks` (nil skips each with a notice — and a
  /// `failClosed` one on a gate denies). The CLI passes its one shared runner.
  private let hookPromptRunner: PromptHookRunner?
  /// Whether each candidate's system prompt opens with the `# Environment` block for its own
  /// snapshot (`EnvironmentContext`), as a CLI session's does. Off by default for embedders;
  /// the CLI passes its policy.
  private let environmentContext: Bool
  private let toolResultGuard: ToolResultGuardPolicy
  /// `Session.Configuration.adaptiveThink` for every candidate (`policies.adaptiveThink`, the
  /// P1 A/B switch): a candidate on a model whose manifest advertises reasoning, under a
  /// `reasoningEffort` dial, is not offered the `think` tool. Live in a panel since batch 14 —
  /// the gate reads `reasoningEffort` below; a panel without a dial keeps the tool.
  private let adaptiveThink: Bool
  /// The reasoning dial every candidate's session runs with (`do --panel N --effort <level>`);
  /// nil leaves requests exactly as they were. Applied by the session only to models whose
  /// manifest says they support reasoning, like any other run's dial. The judge's structured
  /// side request (`Verifier.judge`) never carries it — a judge is not a candidate.
  private let reasoningEffort: Reasoning.Effort?
  /// `Session.Configuration.agent` for every candidate — the Session-free way to mark a
  /// candidate's `RunRecord` (`arnes runs --by-agent` groups by it, `--agent <name>` filters):
  /// `arnes do --panel-on-fail` passes `panel-on-fail`, so its candidates are told apart from a
  /// plain `--panel`'s, which passes nothing and records `agent == nil` as it always did.
  private let candidateAgent: String?
  /// `EvalOutcome.label` on every row this panel writes (`verifier-fail` for the trigger, read
  /// back with `arnes evals show --suite panel --label <arm>`); nil writes an unlabelled row,
  /// byte-identical to what a panel always wrote.
  private let label: String?

  public init(
    service: OpenRouterService,
    recordStore: RunRecordStore = RunRecordStore(),
    evalStore: EvalStore = EvalStore(),
    maxSteps: Int = 30,
    timeoutSeconds: Int = 600,
    catalog: ModelCatalog? = nil,
    provider: ProviderTraits = .openrouter,
    makeSandbox: (@Sendable (URL) -> ShellSandbox?)? = nil,
    subprocessEnvironment: SubprocessEnvironment = .default,
    hooks: [HookDefinition] = [],
    hookPromptRunner: PromptHookRunner? = nil,
    environmentContext: Bool = false,
    toolResultGuard: ToolResultGuardPolicy = .default,
    adaptiveThink: Bool = false,
    reasoningEffort: Reasoning.Effort? = nil,
    candidateAgent: String? = nil,
    label: String? = nil)
  {
    self.service = service
    self.recordStore = recordStore
    self.evalStore = evalStore
    self.maxSteps = maxSteps
    self.timeoutSeconds = timeoutSeconds
    self.catalog = catalog
    self.provider = provider
    self.makeSandbox = makeSandbox
    self.subprocessEnvironment = subprocessEnvironment
    self.hooks = hooks.forNestedRun
    self.hookPromptRunner = hookPromptRunner
    self.environmentContext = environmentContext
    self.toolResultGuard = toolResultGuard
    self.adaptiveThink = adaptiveThink
    self.reasoningEffort = reasoningEffort
    self.candidateAgent = candidateAgent
    self.label = label
  }

  public func run(
    task: String,
    models: [String],
    judgeModel: String,
    baseDirectory: URL,
    apply: Bool = true,
    dialect: DialectOverride = .auto,
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
      dialect: dialect,
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
    dialect: DialectOverride,
    onProgress: @escaping @Sendable (Progress) -> Void)
    async -> [PanelCandidate]
  {
    await withTaskGroup(of: PanelCandidate.self, returning: [PanelCandidate].self) { group in
      for (index, model) in models.enumerated() {
        group.addTask {
          onProgress(.candidateStarted(index: index, model: model))
          let candidate = await self.runCandidate(
            task: task, model: model, index: index, base: base, panelDir: panelDir,
            dialect: dialect)
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
    panelDir: URL,
    dialect: DialectOverride)
    async -> PanelCandidate
  {
    let started = Date()
    let workdir = panelDir.appendingPathComponent("candidate-\(index)")
    // The candidate's whole world is its snapshot: tools bind there, bash runs there, the
    // sandbox (when on) confines writes to it.
    let sandbox = makeSandbox?(workdir)
    let sandboxed = sandbox != nil
    do {
      try Self.snapshot(of: base, to: workdir)
    } catch {
      return PanelCandidate(
        index: index, model: model, report: "", record: nil, diff: "",
        durationSeconds: Date().timeIntervalSince(started),
        error: "snapshot: \(error)", sandboxed: sandboxed)
    }

    let context = ToolContext(
      root: workdir, sandbox: sandbox, environment: subprocessEnvironment)
    var configuration = Session.Configuration(
      model: model,
      maxStepsPerTurn: maxSteps,
      hooks: hooks,
      reasoningEffort: reasoningEffort,
      provider: provider,
      subprocessEnvironment: subprocessEnvironment,
      workingDirectory: workdir,
      hookPromptRunner: hookPromptRunner,
      toolResultGuard: toolResultGuard)
    configuration.adaptiveThink = adaptiveThink
    configuration.agent = candidateAgent
    if environmentContext {
      // The candidate's own block: its snapshot as the root (a copy of the user's tree, git
      // state included), the candidate's sandbox.
      configuration.extraSystemSections = [
        await EnvironmentContext.block(
          for: configuration, facts: EnvironmentContext.Facts(sandbox: sandbox)),
      ]
    }
    let agent = Agent(
      service: service,
      tools: HarnessAssembly.coreTools(context),
      permissions: AutoApprovePermissions(),
      store: recordStore,
      catalog: catalog,
      configuration: configuration)
    let prompt = "Work in the current directory.\n\n\(task)"
    let timeout = TimeInterval(timeoutSeconds)

    let raced: Result<AgentResult, Error>? = await withTaskGroup(
      of: Result<AgentResult, Error>?.self)
    { group in
      group.addTask {
        do {
          return .success(try await agent.run(task: prompt, model: model, dialect: dialect))
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
        diff: diff, durationSeconds: Date().timeIntervalSince(started), error: nil,
        sandboxed: sandboxed)
    case .failure(let error):
      return PanelCandidate(
        index: index, model: model, report: "", record: nil,
        diff: diff, durationSeconds: Date().timeIntervalSince(started), error: "\(error)",
        sandboxed: sandboxed)
    case nil:
      return PanelCandidate(
        index: index, model: model, report: "", record: nil,
        diff: diff, durationSeconds: Date().timeIntervalSince(started),
        error: "timeout after \(timeoutSeconds)s", sandboxed: sandboxed)
    }
  }

  // MARK: Judge

  /// The judge is `Verifier.judge` (V1): one structured request over each judgeable attempt's
  /// report and diff, the `WINNER: <n>` prose read kept as the last resort. Priced the way a
  /// session prices its own steps — `usage.cost`, else the manifest estimate on a provider
  /// that needs one — so a gateway that reports no cost no longer books the judge at $0.
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

    let profile = await Verifier.profile(for: judgeModel, in: catalog)
    let attempts = judgeable.map { candidate in
      Verifier.Candidate(
        index: candidate.index,
        model: candidate.model,
        report: candidate.report.isEmpty ? "(no report — \(candidate.error ?? "empty"))" : candidate.report,
        changes: candidate.diff)
    }
    let verdict = try await Verifier.judge(
      task: task,
      candidates: attempts,
      model: judgeModel,
      service: service,
      context: Verifier.Context(
        catalog: catalog,
        costOf: Verifier.pricing(profile: profile, estimatesCost: provider.estimatesCost)))
    guard let winnerIndex = verdict.winnerIndex else {
      throw PanelError.judgeFailed(verdict.text)
    }
    return PanelVerdict(
      winnerIndex: winnerIndex,
      reason: verdict.text,
      judgeModel: judgeModel,
      judgeCostUSD: verdict.costUSD)
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
      error: candidate.error,
      dialect: candidate.record?.dialect,
      sandboxed: candidate.sandboxed,
      label: label)
  }

  // MARK: Re-verification pricing

  /// The pricing a Session-free caller hands `Verifier.Context.costOf` for a request on
  /// `model`: `usage.cost` when the router reports it, else the manifest estimate on a provider
  /// that needs one — the judge's own rule, so a re-verification on a gateway that reports no
  /// cost is never booked at $0. What `arnes do --panel-on-fail` re-verifies the winner with.
  public static func verifierPricing(
    for model: String, catalog: ModelCatalog?, provider: ProviderTraits)
    async -> @Sendable (Usage?) async -> Double?
  {
    let profile = await Verifier.profile(for: model, in: catalog)
    return Verifier.pricing(profile: profile, estimatesCost: provider.estimatesCost)
  }

  // MARK: Directory plumbing

  // The snapshot/diff/sync plumbing lives in `WorkspaceSnapshot` (shared with the task
  // tool's `isolation: worktree` agents and `arnes agents apply`); these forwarders keep the
  // panel's call sites and tests as they were.

  /// Copies the base directory into `destination` (`WorkspaceSnapshot.snapshot`).
  static func snapshot(of base: URL, to destination: URL) throws {
    try WorkspaceSnapshot.snapshot(of: base, to: destination)
  }

  /// Unified recursive diff of a candidate against the base (`WorkspaceSnapshot.diff`).
  static func diff(base: URL, candidate: URL) -> String {
    WorkspaceSnapshot.diff(base: base, candidate: candidate)
  }

  /// Makes `destination` mirror `source` (`WorkspaceSnapshot.sync`) — how the winner lands
  /// in the real working directory.
  static func sync(from source: URL, into destination: URL) throws {
    try WorkspaceSnapshot.sync(from: source, into: destination)
  }

  /// Relative paths of every regular file under `root` (`WorkspaceSnapshot.relativeFiles`).
  static func relativeFiles(under root: URL) -> Set<String> {
    WorkspaceSnapshot.relativeFiles(under: root)
  }

  static func shellQuote(_ path: String) -> String {
    WorkspaceSnapshot.shellQuote(path)
  }
}
