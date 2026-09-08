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
  /// An LLM rubric graded after the check (X4). The check stays the ground truth: a rubric
  /// refines a pass (`gate`), it never turns a failed check into one. nil = no judge request.
  public var rubric: Rubric?
  /// Efficiency limits on the run (X4): `maxSteps`/`maxCostUSD` also cap the agent, the rest
  /// are graded from the record afterwards. nil = nothing measured, nothing capped.
  public var limits: Limits?
  /// Run the loop-1 verifier on this task's trials — with the runner's verifier model only
  /// (`arnes eval --verify <model>`); the flag alone grades nothing, and so does this alone.
  public var verify: Bool?

  /// What a judge model scores a trial against, from the evidence only (the task, the final
  /// report, the diff of the working directory, the check's verdict — never the transcript).
  public struct Rubric: Codable, Sendable, Equatable {
    /// One line each; the judge answers `met` per criterion.
    public var criteria: [String]
    /// The score (fraction of criteria met, 0…1) a trial must reach; default 0.7.
    public var threshold: Double?
    /// The judge model (id or alias); default the `--judge` flag, then the provider's default.
    public var model: String?
    /// Whether the rubric verdict decides `passed` (default true) or is recorded only.
    public var gate: Bool?

    public static let defaultThreshold = 0.7

    public init(criteria: [String], threshold: Double? = nil, model: String? = nil, gate: Bool? = nil) {
      self.criteria = criteria
      self.threshold = threshold
      self.model = model
      self.gate = gate
    }

    public var effectiveThreshold: Double { threshold ?? Self.defaultThreshold }
    public var gates: Bool { gate ?? true }
  }

  /// Bounds on how a trial got there. `maxSteps` and `maxCostUSD` are caps on the run itself
  /// (the agent is stopped there and the grader reads the `max_steps`/`budget` stop as the
  /// violation); the tool lists are checked against the record's per-tool counts.
  public struct Limits: Codable, Sendable, Equatable {
    public var maxSteps: Int?
    public var maxToolCalls: Int?
    public var maxCostUSD: Double?
    /// Tools the trial must not call at all (`bash` for a task meant for the file tools).
    public var forbiddenTools: [String]?
    /// Tools the trial must call at least once.
    public var requiredTools: [String]?
    /// Whether a violation decides `passed` (default false: limits are recorded, not gating).
    public var gate: Bool?

    public init(
      maxSteps: Int? = nil,
      maxToolCalls: Int? = nil,
      maxCostUSD: Double? = nil,
      forbiddenTools: [String]? = nil,
      requiredTools: [String]? = nil,
      gate: Bool? = nil)
    {
      self.maxSteps = maxSteps
      self.maxToolCalls = maxToolCalls
      self.maxCostUSD = maxCostUSD
      self.forbiddenTools = forbiddenTools
      self.requiredTools = requiredTools
      self.gate = gate
    }

    public var gates: Bool { gate ?? false }
  }

  public init(
    id: String,
    prompt: String,
    setup: String? = nil,
    check: String,
    timeoutSeconds: Int? = nil,
    rubric: Rubric? = nil,
    limits: Limits? = nil,
    verify: Bool? = nil)
  {
    self.id = id
    self.prompt = prompt
    self.setup = setup
    self.check = check
    self.timeoutSeconds = timeoutSeconds
    self.rubric = rubric
    self.limits = limits
    self.verify = verify
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
  /// The wire dialect the agent executed with (nil for pre-dialect rows).
  public var dialect: String?
  /// Whether the trial's tools ran OS-confined (`ShellSandbox`). nil for rows written before
  /// the sandbox reached the runners. Recorded because confinement changes what a task can
  /// do — a pass rate is only comparable against rows with the same value.
  public var sandboxed: Bool?

  // X4 graders — every field nil on a row that had no grader, so a row written before them
  // (and a trial of a task without `rubric`/`limits`/`verify`) reads exactly as before.

  /// The rubric judge's score (0…1) — the fraction of criteria it found met.
  public var rubricScore: Double?
  /// `pass` from the judge, at or above the threshold, and not `unknown`.
  public var rubricPassed: Bool?
  /// The judge could not settle the criteria from the evidence, replied invalidly, or the
  /// request itself failed (`rubricNotes` says which).
  public var rubricUnknown: Bool?
  /// The judge's notes, ≤ 500 chars.
  public var rubricNotes: String?
  /// Every declared limit held.
  public var limitsPassed: Bool?
  /// Which limits did not (`steps 9 > 6`, `forbidden tool bash called 2×`).
  public var limitsViolations: [String]?
  /// The loop-1 verifier's verdict, when the task said `verify: true` and a verifier model
  /// was given. Its spend is inside `costUSD` (the session books it with the turn).
  public var verifierPassed: Bool?
  /// The rubric judge's spend — kept apart from `costUSD` so model comparisons stay fair.
  public var graderCostUSD: Double?
  /// The trial's session id, when a transcript store kept its trajectory
  /// (`arnes evals transcript <id>`).
  public var sessionId: String?
  /// The trial's `RunRecord.id` in `runs.jsonl`.
  public var runId: String?
  public var promptTokens: Int?
  public var completionTokens: Int?
  /// The turn's `StopReason` raw value (`completed`, `max_steps`, `budget`…).
  public var stopReason: String?
  /// The graded verdict: `checkPassed` narrowed by every gating grader. nil on a row that had
  /// no grader — `isPass` is what a statistic counts.
  public var passed: Bool?
  /// The A/B arm this row belongs to (`arnes eval --label <name>`, P1): a short word stamped on
  /// every row of one run so two arms of the same suite × model can be read apart
  /// (`arnes evals show --label`). nil on a row written without one — encoded only when set, so
  /// an unlabelled row is byte-identical to what it always was.
  public var label: String?

  /// The verdict a scoreboard counts: the graded one when the trial had graders, else the
  /// check's — so a row without graders aggregates exactly as it always did.
  public var isPass: Bool { passed ?? checkPassed }

  enum CodingKeys: String, CodingKey {
    case suite, taskId, model, trial, checkPassed, agentFinished, steps, toolCalls, costUSD
    case durationSeconds, startedAt, routedModels, error, dialect, sandboxed
    case rubricScore, rubricPassed, rubricUnknown, rubricNotes, limitsPassed, limitsViolations
    case verifierPassed, graderCostUSD, sessionId, runId, promptTokens, completionTokens
    case stopReason, passed
    case label
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    suite = try container.decode(String.self, forKey: .suite)
    taskId = try container.decode(String.self, forKey: .taskId)
    model = try container.decode(String.self, forKey: .model)
    trial = try container.decode(Int.self, forKey: .trial)
    checkPassed = try container.decode(Bool.self, forKey: .checkPassed)
    agentFinished = try container.decode(Bool.self, forKey: .agentFinished)
    steps = try container.decode(Int.self, forKey: .steps)
    toolCalls = try container.decode(Int.self, forKey: .toolCalls)
    costUSD = try container.decode(Double.self, forKey: .costUSD)
    durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
    startedAt = try container.decode(Date.self, forKey: .startedAt)
    routedModels = try container.decode([String].self, forKey: .routedModels)
    error = try container.decodeIfPresent(String.self, forKey: .error)
    dialect = try container.decodeIfPresent(String.self, forKey: .dialect)
    sandboxed = try container.decodeIfPresent(Bool.self, forKey: .sandboxed)
    rubricScore = try container.decodeIfPresent(Double.self, forKey: .rubricScore)
    rubricPassed = try container.decodeIfPresent(Bool.self, forKey: .rubricPassed)
    rubricUnknown = try container.decodeIfPresent(Bool.self, forKey: .rubricUnknown)
    rubricNotes = try container.decodeIfPresent(String.self, forKey: .rubricNotes)
    limitsPassed = try container.decodeIfPresent(Bool.self, forKey: .limitsPassed)
    limitsViolations = try container.decodeIfPresent([String].self, forKey: .limitsViolations)
    verifierPassed = try container.decodeIfPresent(Bool.self, forKey: .verifierPassed)
    graderCostUSD = try container.decodeIfPresent(Double.self, forKey: .graderCostUSD)
    sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId)
    runId = try container.decodeIfPresent(String.self, forKey: .runId)
    promptTokens = try container.decodeIfPresent(Int.self, forKey: .promptTokens)
    completionTokens = try container.decodeIfPresent(Int.self, forKey: .completionTokens)
    stopReason = try container.decodeIfPresent(String.self, forKey: .stopReason)
    passed = try container.decodeIfPresent(Bool.self, forKey: .passed)
    label = try container.decodeIfPresent(String.self, forKey: .label)
  }

  public init(
    suite: String,
    taskId: String,
    model: String,
    trial: Int,
    checkPassed: Bool,
    agentFinished: Bool,
    steps: Int,
    toolCalls: Int,
    costUSD: Double,
    durationSeconds: Double,
    startedAt: Date,
    routedModels: [String],
    error: String? = nil,
    dialect: String? = nil,
    sandboxed: Bool? = nil,
    rubricScore: Double? = nil,
    rubricPassed: Bool? = nil,
    rubricUnknown: Bool? = nil,
    rubricNotes: String? = nil,
    limitsPassed: Bool? = nil,
    limitsViolations: [String]? = nil,
    verifierPassed: Bool? = nil,
    graderCostUSD: Double? = nil,
    sessionId: String? = nil,
    runId: String? = nil,
    promptTokens: Int? = nil,
    completionTokens: Int? = nil,
    stopReason: String? = nil,
    passed: Bool? = nil,
    label: String? = nil)
  {
    self.suite = suite
    self.taskId = taskId
    self.model = model
    self.trial = trial
    self.checkPassed = checkPassed
    self.agentFinished = agentFinished
    self.steps = steps
    self.toolCalls = toolCalls
    self.costUSD = costUSD
    self.durationSeconds = durationSeconds
    self.startedAt = startedAt
    self.routedModels = routedModels
    self.error = error
    self.dialect = dialect
    self.sandboxed = sandboxed
    self.rubricScore = rubricScore
    self.rubricPassed = rubricPassed
    self.rubricUnknown = rubricUnknown
    self.rubricNotes = rubricNotes
    self.limitsPassed = limitsPassed
    self.limitsViolations = limitsViolations
    self.verifierPassed = verifierPassed
    self.graderCostUSD = graderCostUSD
    self.sessionId = sessionId
    self.runId = runId
    self.promptTokens = promptTokens
    self.completionTokens = completionTokens
    self.stopReason = stopReason
    self.passed = passed
    self.label = label
  }

  /// The graded verdict for a trial whose task is known: the check, narrowed by the rubric
  /// when it gates (an unknown or missing rubric verdict fails a gated task — never a pass by
  /// default) and by the limits when they gate (a run with no record is not a violation).
  /// nil when the task declared neither (the verifier is recorded, never gating), so the row
  /// aggregates as before.
  public static func gradedVerdict(
    task: EvalTask,
    checkPassed: Bool,
    rubricPassed: Bool?,
    limitsPassed: Bool?)
    -> Bool?
  {
    guard task.rubric != nil || task.limits != nil else { return nil }
    var verdict = checkPassed
    if let rubric = task.rubric, rubric.gates {
      verdict = verdict && (rubricPassed ?? false)
    }
    if let limits = task.limits, limits.gates {
      verdict = verdict && (limitsPassed ?? true)
    }
    return verdict
  }
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
    try appendJSONLLine(line, to: url)
  }

  public func all() throws -> [EvalOutcome] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return String(decoding: data, as: UTF8.self)
      .split(separator: "\n")
      .compactMap { try? decoder.decode(EvalOutcome.self, from: Data($0.utf8)) }
  }

  /// Rewrites the history keeping only matching rows (`arnes evals prune`).
  /// Atomic: the file is replaced whole, never truncated mid-write. The removed rows come
  /// back so the caller can sweep what they own (their transcripts).
  public func rewrite(keeping shouldKeep: (EvalOutcome) -> Bool) throws
    -> (kept: Int, removed: Int, removedRows: [EvalOutcome])
  {
    let outcomes = try all()
    var kept: [EvalOutcome] = []
    var removed: [EvalOutcome] = []
    for outcome in outcomes {
      if shouldKeep(outcome) { kept.append(outcome) } else { removed.append(outcome) }
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    var data = Data()
    for outcome in kept {
      data.append(try encoder.encode(outcome))
      data.append(Data("\n".utf8))
    }
    try SecureFiles.writePrivate(data, to: url)
    return (kept.count, removed.count, removed)
  }
}

// MARK: - EvalHistoryRow

/// Aggregation over the eval history grouped by suite × model × dialect — the shape
/// `arnes evals` renders. Distinct from `EvalStats` (one invocation, grouped by model).
public struct EvalHistoryRow: Sendable {
  public let suite: String
  public let model: String
  public let dialect: String?
  public let trials: Int
  public let passed: Int
  public let totalCostUSD: Double
  public let lastRun: Date
  /// Over the rows the loop-1 verifier graded (`verifierPassed != nil`): how many of its
  /// verdicts agreed with the bash check (V1 — the verifier scored against the ground truth).
  public let verifierAgreements: Int
  /// How many rows carry a verifier verdict at all.
  public let verifierVerdicts: Int

  public var passRate: Double { trials == 0 ? 0 : Double(passed) / Double(trials) }

  /// `verifierAgreements / verifierVerdicts`; nil when no row was verified.
  public var verifierAgreement: Double? {
    verifierVerdicts == 0 ? nil : Double(verifierAgreements) / Double(verifierVerdicts)
  }

  public static func aggregate(_ outcomes: [EvalOutcome]) -> [EvalHistoryRow] {
    struct Key: Hashable {
      let suite: String
      let model: String
      let dialect: String?
    }
    let grouped = Dictionary(grouping: outcomes) {
      Key(suite: $0.suite, model: $0.model, dialect: $0.dialect)
    }
    return grouped.map { key, rows in
      let verified = rows.compactMap { row in row.verifierPassed.map { ($0, row.checkPassed) } }
      return EvalHistoryRow(
        suite: key.suite,
        model: key.model,
        dialect: key.dialect,
        trials: rows.count,
        passed: rows.filter(\.isPass).count,
        totalCostUSD: rows.reduce(0) { $0 + $1.costUSD },
        lastRun: rows.map(\.startedAt).max() ?? Date.distantPast,
        verifierAgreements: verified.filter { $0.0 == $0.1 }.count,
        verifierVerdicts: verified.count)
    }
    .sorted {
      if $0.suite != $1.suite { return $0.suite < $1.suite }
      if $0.passRate != $1.passRate { return $0.passRate > $1.passRate }
      return $0.model < $1.model
    }
  }
}

// MARK: - EvalRunner

/// Runs a suite: every model × task × trial in a fresh temporary working directory,
/// scored by the task's check script. Each trial's tools are **root-bound** to that
/// directory (`HarnessAssembly.coreTools(ToolContext(root:))`) rather than the process CWD,
/// so nothing depends on a `chdir` the whole process shares. Agent runs also append
/// `RunRecord`s, so evals feed the same scoreboard as normal usage.
///
/// A trial is an unattended run under `AutoApprovePermissions`: the same reasons a headless
/// `--yes` run is confined apply here, so the caller passes `makeSandbox` (and its hooks,
/// which are guardrails the user configured and an eval must not slip).
public final class EvalRunner: @unchecked Sendable {
  public enum Progress: Sendable {
    case trialStarted(taskId: String, model: String, trial: Int)
    case trialFinished(EvalOutcome)
    /// A one-line caution about the run's setup (a judge grading its own model), said once.
    case warning(String)
  }

  private let service: OpenRouterService
  private let toolsOverride: [any AgentTool]?
  private let store: EvalStore
  private let recordStore: RunRecordStore
  private let maxSteps: Int
  private let catalog: ModelCatalog?
  private let provider: ProviderTraits
  /// Builds the OS sandbox for a trial's working directory, when one applies. nil = trials
  /// run unconfined (what an embedder gets by default; the CLI passes a real builder).
  private let makeSandbox: (@Sendable (URL) -> ShellSandbox?)?
  /// Environment policy for trial subprocesses — the provider token is withheld regardless.
  private let subprocessEnvironment: SubprocessEnvironment
  /// Lifecycle hooks the trial's session runs — the per-call and compaction ones
  /// (`forNestedRun`). A hook is a deterministic guardrail; an eval that dropped it would be
  /// measuring a harness the user doesn't run. A trial's finish is not the user's turn end
  /// and its session is not the user's session, though, so `Stop` and the session-level
  /// events stay with the command (the delegation pair reaches a `--subagents` trial's task
  /// tool through `delegationHooks`). Hooks run with the trial's temp directory as `cwd`.
  private let hooks: [HookDefinition]
  /// Executes the `type: prompt` definitions in `hooks` (nil skips each with a notice — and a
  /// `failClosed` one on a gate denies). The CLI passes its one shared runner.
  private let hookPromptRunner: PromptHookRunner?
  /// Whether each trial's system prompt opens with the `# Environment` block for its own
  /// working directory (`EnvironmentContext`), as a CLI session's does. Off by default for
  /// embedders; the CLI passes its policy so evals measure the prompt the user actually runs.
  private let environmentContext: Bool
  /// How each trial treats its tool results (`ToolResultGuardPolicy`: redact secrets, scan for
  /// injection, frame, taint). `.default` for embedders (scan/redact/taint on, no frame); the
  /// CLI passes its `.cli` policy so evals measure the framed prompt the user actually runs.
  private let toolResultGuard: ToolResultGuardPolicy
  /// Agents a trial may delegate to. Empty (the default) means no `task` tool — the toolset
  /// and system prompt are exactly what they were, so `evals/basics` stays byte-identical.
  /// Non-empty adds a `TaskTool` over the trial's own tools, permissions, record store and
  /// configuration (the way `arnes do` builds one), so a suite can measure whether a model
  /// delegates when it should and not when it shouldn't (`evals/subagents`). Nested runs land
  /// in the record store tagged with the agent's name like any delegation.
  private let subagents: [AgentDefinition]
  /// Caps and the fallback model for those subagents (the provider's `subagents` block).
  private let subagentDefaults: TaskTool.Defaults
  /// The user's `SubagentStart`/`SubagentStop` hooks, kept apart from `hooks` (which
  /// `forNestedRun` strips them from): a trial that delegates is the lead of its own
  /// delegations, so its `task` tool runs the guardrails about spawning exactly as `arnes do`
  /// does — otherwise `arnes eval --subagents` would measure a harness the user doesn't run.
  /// They reach the task tool's engine only, never the trial's session or the nested one.
  private let delegationHooks: [HookDefinition]
  /// Where each trial's transcript is written (X4) — a store of the caller's choosing, never
  /// the user's `~/.arnes/sessions` (the CLI uses `~/.arnes/eval-sessions`). nil = no
  /// trajectory kept, the embedder default. Written by the trial's `Session` *during* the
  /// run: the workdir is gone before `runTrial` returns, so nothing is harvested afterwards.
  private let transcriptStore: SessionStore?
  /// The rubric judge for tasks that declare a `rubric` without a `model` of their own; nil
  /// falls back to the candidate model itself (self-grading — warned once per run).
  private let judgeModel: String?
  /// The loop-1 verifier for tasks that say `verify: true`; nil = the flag grades nothing.
  private let verifierModel: String?
  /// The reasoning dial every trial's session runs with (X5, `arnes eval --effort`); nil leaves
  /// requests exactly as they are. Applied by the session only to models whose manifest says
  /// they support reasoning, like any other run's dial.
  private let reasoningEffort: Reasoning.Effort?
  /// A per-trial cost ceiling (`--budget`), combined with a task's own `limits.maxCostUSD` by
  /// taking the tighter of the two; nil = no ceiling beyond the task's.
  private let budgetUSD: Double?
  /// `Session.Configuration.adaptiveThink` for every trial (P1, `arnes eval --adaptive-think` or
  /// `policies.adaptiveThink`): a trial on a model whose manifest advertises reasoning, with
  /// `reasoningEffort` set (not `none`), is not offered the `think` tool. false = every trial is
  /// offered it, the shipped default — this is the switch the A/B flips.
  private let adaptiveThink: Bool
  private let commandDiagnostics: Bool
  private let compaction: CompactionPolicy
  /// The A/B arm name stamped on every row of the run (`EvalOutcome.label`); nil = unlabelled.
  private let label: String?

  /// - Parameters:
  ///   - tools: an explicit toolset for every trial. Normally nil: the runner builds a
  ///     root-bound, sandboxed toolset per trial instead, which is what keeps trials isolated
  ///     from each other and from the process CWD.
  ///   - subagents: agents the trial's `task` tool offers; empty = no task tool (default).
  ///   - subagentDefaults: the `subagents` config block those runs are capped by.
  ///   - transcriptStore: keep every trial's transcript here (`arnes evals transcript`).
  ///   - judgeModel: the rubric judge when a task's `rubric` names none.
  ///   - verifierModel: the loop-1 verifier for tasks with `verify: true`.
  ///   - reasoningEffort: the reasoning dial for every trial (nil = requests unchanged).
  ///   - budgetUSD: a cost ceiling per trial, the tighter of it and the task's `limits.maxCostUSD`.
  ///   - adaptiveThink: omit the `think` tool for a natively reasoning model with the dial on.
  ///   - label: the A/B arm name every row of the run carries (`EvalOutcome.label`).
  public init(
    service: OpenRouterService,
    tools: [any AgentTool]? = nil,
    store: EvalStore = EvalStore(),
    recordStore: RunRecordStore = RunRecordStore(),
    maxSteps: Int = 30,
    catalog: ModelCatalog? = nil,
    provider: ProviderTraits = .openrouter,
    makeSandbox: (@Sendable (URL) -> ShellSandbox?)? = nil,
    subprocessEnvironment: SubprocessEnvironment = .default,
    hooks: [HookDefinition] = [],
    hookPromptRunner: PromptHookRunner? = nil,
    environmentContext: Bool = false,
    subagents: [AgentDefinition] = [],
    subagentDefaults: TaskTool.Defaults = TaskTool.Defaults(),
    transcriptStore: SessionStore? = nil,
    judgeModel: String? = nil,
    verifierModel: String? = nil,
    reasoningEffort: Reasoning.Effort? = nil,
    budgetUSD: Double? = nil,
    toolResultGuard: ToolResultGuardPolicy = .default,
    adaptiveThink: Bool = false,
    label: String? = nil,
    commandDiagnostics: Bool = false,
    compaction: CompactionPolicy = .default)
  {
    self.toolResultGuard = toolResultGuard
    self.adaptiveThink = adaptiveThink
    self.commandDiagnostics = commandDiagnostics
    self.compaction = compaction
    self.label = label
    self.transcriptStore = transcriptStore
    self.judgeModel = judgeModel
    self.verifierModel = verifierModel
    self.reasoningEffort = reasoningEffort
    self.budgetUSD = budgetUSD
    self.service = service
    self.toolsOverride = tools
    self.store = store
    self.recordStore = recordStore
    self.maxSteps = maxSteps
    self.catalog = catalog
    self.provider = provider
    self.makeSandbox = makeSandbox
    self.subprocessEnvironment = subprocessEnvironment
    self.hooks = hooks.forNestedRun
    self.hookPromptRunner = hookPromptRunner
    self.environmentContext = environmentContext
    self.subagents = subagents
    self.subagentDefaults = subagentDefaults
    self.delegationHooks = hooks.filter { $0.event == .subagentStart || $0.event == .subagentStop }
  }

  /// Runs every model × task × trial and returns the outcomes in that order (model, then task,
  /// then trial — the order the loops have always enumerated), whatever order they finished in.
  ///
  /// - Parameter concurrency: how many trials run at once (X5, `arnes eval --parallel`). Trials
  ///   are isolated by construction — each has its own temp workdir, root-bound tools, sandbox
  ///   and session; the stores are append-only files — so a window of them is safe. At most
  ///   `max(1, concurrency)` are in flight: the next one starts when one finishes. `1` (the
  ///   default) is exactly the sequential run: `.trialStarted` and `.trialFinished` alternate
  ///   in enumeration order and the store receives the rows in that order. With a wider
  ///   window `.trialFinished` arrives in completion order — the store's rows and the progress
  ///   lines follow it — and only the returned array is sorted back.
  public func run(
    suite: EvalSuite,
    models: [String],
    trials: Int = 1,
    dialect: DialectOverride = .auto,
    concurrency: Int = 1,
    onProgress: @escaping @Sendable (Progress) -> Void = { _ in })
    async -> [EvalOutcome]
  {
    // Said once per run, before any trial: a judge that is the candidate model grades its own
    // work, which the user should know before reading the rubric column.
    let selfGraded = models.filter { model in
      suite.tasks.contains { task in
        task.rubric != nil && resolvedJudge(for: task, candidate: model) == resolvedAlias(model)
      }
    }
    if !selfGraded.isEmpty {
      onProgress(.warning(
        "self-grading: judge == candidate for \(selfGraded.joined(separator: ", ")) — pass --judge <model> for an independent rubric verdict"))
    }
    // The same triples in the same order as the three loops always produced, indexed so the
    // result can be put back in that order after the window has run them in whatever order.
    struct Planned: Sendable {
      let index: Int
      let task: EvalTask
      let model: String
      let trial: Int
    }
    var planned: [Planned] = []
    for model in models {
      for task in suite.tasks {
        for trial in 1...max(1, trials) {
          planned.append(Planned(index: planned.count, task: task, model: model, trial: trial))
        }
      }
    }
    let window = max(1, concurrency)
    let suiteName = suite.name
    let indexed: [(Int, EvalOutcome)] = await withTaskGroup(
      of: (Int, EvalOutcome).self, returning: [(Int, EvalOutcome)].self)
    { group in
      var results: [(Int, EvalOutcome)] = []
      var next = 0
      func start(_ item: Planned) {
        group.addTask {
          // Inside the child so a wider window reports each start as it happens, and the
          // sequential window reports started/finished alternating exactly as before.
          onProgress(.trialStarted(taskId: item.task.id, model: item.model, trial: item.trial))
          let outcome = await self.runTrial(
            suite: suiteName, task: item.task, model: item.model, trial: item.trial, dialect: dialect)
          return (item.index, outcome)
        }
      }
      while next < planned.count, next < window {
        start(planned[next])
        next += 1
      }
      // One finishes → its row is appended and reported, then the next trial takes its slot.
      for await (index, outcome) in group {
        try? store.append(outcome)
        results.append((index, outcome))
        onProgress(.trialFinished(outcome))
        if next < planned.count {
          start(planned[next])
          next += 1
        }
      }
      return results
    }
    return indexed.sorted { $0.0 < $1.0 }.map(\.1)
  }

  private func runTrial(
    suite: String,
    task: EvalTask,
    model: String,
    trial: Int,
    dialect: DialectOverride)
    async -> EvalOutcome
  {
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
      error: nil,
      dialect: nil,
      sandboxed: nil,
      label: label)

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

    // A rubric judge — and the loop-1 verifier (V1) — read what the run changed: the post-setup
    // tree is cloned beside the workdir (an APFS clone, free) and diffed against it after the
    // check. Only when the task has a rubric or is verified — an ungraded trial copies nothing
    // and stays byte-identical.
    var baseDirectory: URL?
    if task.rubric != nil || (task.verify == true && verifierModel != nil) {
      // A sibling whose path is not prefixed by the workdir's: `WorkspaceSnapshot.diff` rewrites
      // the candidate path first, so `<workdir>-base/x` would read `candidate-base/x` to the judge.
      let base = workdir.deletingLastPathComponent()
        .appendingPathComponent("base-" + workdir.lastPathComponent)
      do {
        try WorkspaceSnapshot.snapshot(of: workdir, to: base)
        baseDirectory = base
      } catch {
        try? FileManager.default.removeItem(at: base)
        outcome.error = "snapshot: \(error)"
        outcome.durationSeconds = Date().timeIntervalSince(startedAt)
        return outcome
      }
    }
    defer { if let baseDirectory { try? FileManager.default.removeItem(at: baseDirectory) } }

    // The trial's whole world is its temp directory: tools resolve relative paths there and
    // bash runs there, without touching the process CWD (which parallel trials, and any
    // embedder on another thread, would fight over).
    var sandbox = makeSandbox?(workdir)
    if let baseDirectory {
      // The base is the diff's reference and sits under the temp directory the profile keeps
      // writable: unwritable for the trial's bash and file tools, as A8 does for a snapshot.
      sandbox?.protectedSubpaths.append(baseDirectory)
    }
    outcome.sandboxed = sandbox != nil
    let context = ToolContext(
      root: workdir, sandbox: sandbox, environment: subprocessEnvironment)
    // The task's limits cap the run itself, not just the grade: a task that says "under 6
    // steps" stops the agent at 6 and the grader reads the `max_steps` stop as the miss.
    let stepCap = task.limits?.maxSteps.map { min(maxSteps, max(1, $0)) } ?? maxSteps
    // The tighter of the task's own cost cap and the run's `--budget`; nil when neither is set.
    let costCap = [task.limits?.maxCostUSD, budgetUSD].compactMap { $0 }.min()
    var configuration = Session.Configuration(
      model: model,
      maxStepsPerTurn: stepCap,
      maxCostUSD: costCap,
      hooks: hooks,
      reasoningEffort: reasoningEffort,
      provider: provider,
      subprocessEnvironment: subprocessEnvironment,
      workingDirectory: workdir,
      hookPromptRunner: hookPromptRunner,
      sessionOrigin: "eval",
      toolResultGuard: toolResultGuard)
    // The P1 A/B switch: the trial's session (and, through `forSubagent`, its subagents) omits
    // `think` for a natively reasoning model under a dial only when the runner says so.
    configuration.adaptiveThink = adaptiveThink
    configuration.commandDiagnostics = commandDiagnostics
    configuration.compaction = compaction
    // Captured once per trial: the lead's block and any subagent's block share the same facts.
    let facts = environmentContext ? EnvironmentContext.Facts(sandbox: sandbox) : nil
    if let facts {
      // The trial's own block: its temp root (rarely a repository), the trial's sandbox.
      configuration.extraSystemSections = [
        await EnvironmentContext.block(for: configuration, facts: facts),
      ]
    }
    let permissions = AutoApprovePermissions()
    // One manifest per trial: the lead and its task tool share it when the embedder passed
    // none (each would otherwise fetch its own).
    let catalog = self.catalog ?? ModelCatalog(service: service)
    let coreTools = toolsOverride ?? HarnessAssembly.coreTools(context)
    var tools = coreTools
    var taskTool: TaskTool?
    if !subagents.isEmpty {
      // Mirrors `arnes do`: the subagents run over the trial's tools (never the task tool
      // itself — one level of nesting), its gate, its record store and its configuration, so
      // a nested run is confined to the trial's workdir like the lead. The trial's model is
      // what `inherit` resolves to. The tool's copy of the configuration carries the user's
      // SubagentStart/SubagentStop hooks too: the tool's engine is where those fire, and its
      // `forSubagent` strips them again before the nested session sees them (so each still
      // runs exactly once, at the delegation boundary); the trial's own session never has them.
      var taskConfiguration = configuration
      taskConfiguration.hooks += delegationHooks
      let tool = TaskTool(
        agents: subagents,
        service: service,
        tools: coreTools,
        permissions: permissions,
        store: recordStore,
        catalog: catalog,
        defaults: subagentDefaults,
        environmentContext: facts,
        toolContext: context,
        makeSandbox: { [makeSandbox] snapshotRoot in
          guard var isolated = makeSandbox?(snapshotRoot) else { return nil }
          // The parent trial and any rubric reference are under the otherwise writable
          // temp tree. Isolation may read them but must not write outside its own copy.
          isolated.protectedSubpaths += [workdir] + (context.sandbox?.protectedSubpaths ?? [])
          return isolated
        },
        configuration: taskConfiguration)
      tool.parentModel = { model }
      taskTool = tool
      tools.append(tool)
    }
    // A tool named in the limits must be one this trial could call (or a harness name that may
    // simply be absent): a typo must grade as a task error, never as "never used".
    if let limits = task.limits {
      let available = Set(tools.map(\.name)).union(ToolFilter.harnessToolNames)
      let unknown = LimitsGrader.unknownTools(in: limits, available: available)
      if let first = unknown.first {
        outcome.error = "limits: unknown tool '\(first)'"
        outcome.durationSeconds = Date().timeIntervalSince(startedAt)
        return outcome
      }
    }
    // A rubric with nothing to judge, or a threshold no score can meet or miss, is a task error
    // too — it would otherwise cost a judge request per trial and decide `passed` vacuously.
    if let rubric = task.rubric, let problem = Self.rubricProblem(rubric) {
      outcome.error = "rubric: \(problem)"
      outcome.durationSeconds = Date().timeIntervalSince(startedAt)
      return outcome
    }
    let agent = Agent(
      service: service,
      tools: tools,
      permissions: permissions,
      store: recordStore,
      sessionStore: transcriptStore,
      catalog: catalog,
      configuration: configuration)
    if let taskTool {
      // The delegation hooks' payload and the nested records name the session that spawned
      // the agent.
      agent.onSessionStart = { session in
        taskTool.parentSessionId = session.id
        taskTool.parentModel = { await session.model }
        taskTool.parentBudgetRemaining = {
          guard let costCap else { return nil }
          return max(0, costCap - (await session.costUSD))
        }
        taskTool.parentEffort = { await session.currentReasoningEffort }
        taskTool.parentHistory = { (await session.history, await session.compactionSummary) }
      }
    }
    // "The current directory" is the trial directory: bash runs with that cwd and every
    // path-taking tool resolves against it.
    let prompt = "Work in the current directory.\n\n\(task.prompt)"
    let timeout = TimeInterval(task.timeoutSeconds ?? 300)
    // The verifier is per task and per run: `verify: true` with a verifier model given. It is
    // graded below, over the snapshot diff — never by the trial's session, whose diff of a
    // temp workdir would have nothing to show (not a repository).
    let verifier = task.verify == true ? verifierModel : nil

    let raced: Result<AgentResult, Error>? = await withTaskGroup(
      of: Result<AgentResult, Error>?.self)
    { group in
      group.addTask {
        do {
          return .success(
            try await agent.run(task: prompt, model: model, dialect: dialect))
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

    var report = ""
    var record: RunRecord?
    switch raced {
    case .success(let result):
      record = result.record
      report = result.text
      outcome.agentFinished = result.record.finished
      outcome.steps = result.record.steps
      outcome.toolCalls = result.record.toolCalls
      outcome.costUSD = result.record.costUSD
      outcome.routedModels = result.record.routedModels
      outcome.dialect = result.record.dialect
      // The session id joins the row to `runs.jsonl` whether or not a transcript was kept.
      outcome.sessionId = result.sessionId
      outcome.runId = result.record.id
      outcome.promptTokens = result.record.promptTokens
      outcome.completionTokens = result.record.completionTokens
      outcome.stopReason = result.record.stopReason?.rawValue
    case .failure(let error):
      outcome.error = "\(error)"
      // The session may have written a transcript before the run threw or timed out; naming it
      // keeps the row and the file joined, so `evals prune` can still sweep it.
      outcome.sessionId = agent.lastSession?.id
    case nil:
      outcome.error = "timeout after \(Int(timeout))s"
      outcome.sessionId = agent.lastSession?.id
    }

    // Score regardless — a timed-out agent may still have completed the work. The check learns
    // the trial's ids (the setup ran before the session existed, so it never can): a delegation
    // suite's check greps `"parentSessionId":"$ARNES_SESSION_ID"` in runs.jsonl instead of a
    // line delta another arnes process could skew. Unset when the run never produced them.
    let checkEnvironment = Self.checkEnvironment(sessionId: outcome.sessionId, runId: outcome.runId)
    let check = Self.bash(task.check, cwd: workdir, timeoutSeconds: 60, environment: checkEnvironment)
    outcome.checkPassed = check.exit == 0

    // Graders. Limits read the record (none → not graded, `limitsPassed` stays nil); the
    // rubric and the verifier read the evidence — the diff is taken here, once, while both
    // directories still exist.
    if let limits = task.limits, let record {
      let verdict = LimitsGrader.evaluate(record: record, limits: limits)
      outcome.limitsPassed = verdict.passed
      outcome.limitsViolations = verdict.violations
    }
    let snapshotDiff = baseDirectory.map { WorkspaceSnapshot.diff(base: $0, candidate: workdir) }
    let reportOrWhy = report.isEmpty
      ? "(no report — \(outcome.error ?? "the agent gave no final reply"))"
      : report
    if task.rubric != nil, let diff = snapshotDiff {
      let judge = resolvedJudge(for: task, candidate: model)
      let evidence = RubricJudge.Evidence(
        report: reportOrWhy,
        diff: diff,
        checkPassed: outcome.checkPassed,
        checkOutput: check.output)
      let graded = await grade(task: task, evidence: evidence, judge: judge, catalog: catalog)
      outcome.rubricScore = graded.score
      outcome.rubricPassed = graded.passed
      outcome.rubricUnknown = graded.unknown
      outcome.rubricNotes = String(graded.notes.prefix(RubricJudge.maxNotesChars))
      outcome.graderCostUSD = graded.costUSD
    }
    // The loop-1 verifier (V1), over the same diff: its verdict lands on the row, its spend on
    // `graderCostUSD` beside the judge's — apart from `costUSD`, so model comparisons stay
    // fair. A verifier that is down leaves the row without a verdict (nil), never a thrown
    // trial; the check still scored it.
    if let verifier, let diff = snapshotDiff {
      if let verdict = await verify(task: task, report: reportOrWhy, diff: diff, verifier: verifier, catalog: catalog) {
        outcome.verifierPassed = verdict.passed
        outcome.graderCostUSD = (outcome.graderCostUSD ?? 0) + (verdict.costUSD ?? 0)
      }
    }
    outcome.passed = EvalOutcome.gradedVerdict(
      task: task,
      checkPassed: outcome.checkPassed,
      rubricPassed: outcome.rubricPassed,
      limitsPassed: outcome.limitsPassed)
    outcome.durationSeconds = Date().timeIntervalSince(startedAt)
    return outcome
  }

  /// The judge model a rubric task is graded on: the task's own `model`, else the runner's
  /// `judgeModel`, else the candidate itself — every step alias-resolved through the catalog
  /// like any other model name.
  func resolvedJudge(for task: EvalTask, candidate: String) -> String {
    resolvedAlias(task.rubric?.model ?? judgeModel ?? candidate)
  }

  private func resolvedAlias(_ name: String) -> String {
    catalog?.resolve(name) ?? name
  }

  /// Runs the rubric judge and turns a failed request into an `unknown` verdict: a judge that
  /// is down never throws a trial — the check still scored it.
  private func grade(
    task: EvalTask,
    evidence: RubricJudge.Evidence,
    judge: String,
    catalog: ModelCatalog)
    async -> RubricResult
  {
    let profile = (try? await catalog.profile(for: judge)) ?? ModelProfile(unknownModelId: judge)
    let traits = provider
    // Priced the way the session prices its own steps: `usage.cost` when the router reports
    // it, else the manifest estimate on a provider that needs one.
    let costOf: @Sendable (Usage?) async -> Double? = { usage in
      if let cost = usage?.cost { return cost }
      guard traits.estimatesCost, let usage else { return nil }
      return Session.estimatedCost(
        promptTokens: usage.promptTokens, completionTokens: usage.completionTokens, profile: profile)
    }
    do {
      return try await RubricJudge.grade(
        task: task, evidence: evidence, model: profile.id, profile: profile, service: service,
        costOf: costOf)
    } catch {
      return RubricResult.unknown(notes: "judge error: \(String("\(error)".prefix(300)))")
    }
  }

  /// Runs the loop-1 verifier over the trial's snapshot diff (V1). The verifier model is
  /// alias-resolved like the judge; nil when its request failed — no verdict, never a thrown
  /// trial.
  private func verify(
    task: EvalTask,
    report: String,
    diff: String,
    verifier: String,
    catalog: ModelCatalog)
    async -> Verifier.Verdict?
  {
    let profile = await Verifier.profile(for: verifier, in: catalog)
    do {
      return try await Verifier.run(
        task: task.prompt,
        outcome: report,
        model: profile.id,
        service: service,
        context: Verifier.Context(
          catalog: catalog,
          costOf: Verifier.pricing(profile: profile, estimatesCost: provider.estimatesCost)),
        diff: diff)
    } catch {
      return nil
    }
  }

  /// Runs bash in a directory with a hard timeout (the process is terminated). Shares
  /// `ShellRunner` with the bash tool: stdin closed, the wait ends when bash exits.
  /// Why a task's rubric cannot be judged: no non-blank criterion, or a threshold outside 0…1.
  static func rubricProblem(_ rubric: EvalTask.Rubric) -> String? {
    if rubric.criteria.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
      return "no criteria"
    }
    let threshold = rubric.effectiveThreshold
    if !(0...1).contains(threshold) || threshold.isNaN {
      return "threshold \(threshold) is not between 0 and 1"
    }
    return nil
  }

  /// The variables a check script sees beyond the runner's environment: `ARNES_SESSION_ID` (the
  /// trial's lead session — the `parentSessionId` of every nested record it spawned) and
  /// `ARNES_RUN_ID` (its `RunRecord.id`), each only when the trial produced one. Pure.
  static func checkEnvironment(sessionId: String?, runId: String?) -> [String: String] {
    var environment: [String: String] = [:]
    if let sessionId { environment["ARNES_SESSION_ID"] = sessionId }
    if let runId { environment["ARNES_RUN_ID"] = runId }
    return environment
  }

  static func bash(
    _ command: String, cwd: URL, timeoutSeconds: Int, environment: [String: String] = [:])
    -> (exit: Int32, output: String)
  {
    let outcome = ShellRunner.runBlocking(
      command, cwd: cwd, timeoutSeconds: timeoutSeconds, extraEnvironment: environment)
    if outcome.timedOut {
      return (outcome.exitStatus == 0 ? 124 : outcome.exitStatus, outcome.output + "\n[timed out after \(timeoutSeconds)s]")
    }
    return (outcome.exitStatus, outcome.output)
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
        if row.isPass { passed += 1 }
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
