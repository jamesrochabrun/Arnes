import Foundation
import OpenRouterSwift

// MARK: - Session.Configuration

extension Session {
  /// Everything a session is built with. `Session` stores it whole (`session.configuration`)
  /// rather than copying fields out one by one, and nested sessions derive theirs from it
  /// (`forSubagent`) — so a setting added here reaches delegated work instead of being
  /// silently dropped on the way down.
  public struct Configuration: Sendable {
    public var model: String
    public var fallbackModels: [String]
    /// Model steps one turn may take before it ends with `stop_reason: max_steps`.
    /// `Int.max` (the default) is unlimited — the loop guard, the denied-loop breaker and
    /// `maxCostUSD` are the guardrails; set a value only when a hard step cap is wanted
    /// (`--max-steps`, an agent's `maxSteps:` frontmatter, eval `limits`).
    public var maxStepsPerTurn: Int
    /// Wire dialect selection; `.auto` follows the model's profile (native for
    /// Anthropic/OpenAI families, chat otherwise).
    public var dialect: DialectOverride
    /// Appended to the system prompt after the pack — a subagent's role + body.
    /// Harness plumbing, not prompt tuning: family behavior still lives in packs.
    public var systemSuffix: String?
    /// Project/global instruction files (AGENTS.md / CLAUDE.md) discovered by the CLI and
    /// injected into the system prompt as repo context — the "constitution" the agent reads
    /// each turn. Not prompt tuning: this is the user's own repo conventions, not family
    /// behavior. See `ProjectInstructions`.
    public var projectInstructions: String?
    /// Extra system-prompt sections supplied by the embedder, rendered after the project
    /// instructions and before the tool-contributed sections (skills, subagents). Harness
    /// context such as an environment block or a hook's session-start note — never family
    /// tuning, which stays in packs. Empty by default. The *seed*: the session copies it at
    /// init and `Session.setExtraSystemSections` replaces the live copy (a re-rendered
    /// `# Environment` block after `/model`); this value is never mutated.
    public var extraSystemSections: [String]
    /// Stop the loop once the session's cumulative cost reaches this many dollars — the
    /// budget stopping condition (nil = unlimited). Checked before each step, so the turn
    /// ends at the next boundary rather than exceeding it by much. Estimated cost on
    /// gateways that don't report it.
    public var maxCostUSD: Double?
    /// Lifecycle hooks (user-global `~/.arnes/hooks.json`): PreToolUse can block a tool,
    /// PostToolUse feeds output back, Stop runs at turn end. Empty = none. See `HookEngine`.
    public var hooks: [HookDefinition]
    /// The reasoning-effort dial (the compute-vs-cost knob). Applied per request, but only to
    /// models the manifest says support reasoning — never sent to one that doesn't. nil leaves
    /// every request exactly as before. Maps to `reasoning.effort` on chat/responses and a
    /// thinking budget on `/messages`.
    public var reasoningEffort: Reasoning.Effort?
    /// Subagent name recorded on this session's `RunRecord`s, so the scoreboard can
    /// tell delegated runs apart. Nil for top-level sessions.
    public var agent: String?
    /// The router behind `service`: how fallbacks are spelled, whether cost must be
    /// estimated, whether native dialects may be used, and the model for anything the
    /// caller doesn't name (compaction, `model` when nil). OpenRouter by default.
    public var provider: ProviderTraits
    /// Environment policy for hook subprocesses (bash carries its own via the tool). The
    /// provider token is withheld regardless. See `SubprocessEnvironment`.
    public var subprocessEnvironment: SubprocessEnvironment
    /// Working directory for tools and hooks, when the run is bound to one — recorded so a
    /// hook's payload carries `cwd`, and used as the root for path-glob permission rules.
    /// nil = the process CWD.
    public var workingDirectory: URL?
    /// How freely tools run before the rules file and the delegate: default / acceptEdits
    /// / plan / bypass. See `PermissionMode`.
    public var permissionMode: PermissionMode
    /// Persistent allow/ask/deny rules consulted before the delegate. Empty = none.
    public var permissionRules: PermissionRules
    /// When the model finishes its reply while background subagents (`task` with
    /// `background: true`) are still pending, wait for one, deliver its report and let the
    /// model take another step — so a turn never ends with delegated work unaccounted for.
    /// True by default and always true for a headless `Agent.run`. The REPL sets it from
    /// `subagents.joinAtTurnEnd`; when false the turn ends and the report is delivered at the
    /// first step of the *next* `send`, whose record carries its cost.
    public var joinBackgroundAtTurnEnd: Bool
    /// In-process hooks — the embedder's code at a lifecycle point, run ahead of `hooks` on
    /// the same payload/outcome contract and not clamped (see `HookHandler`). Empty = none.
    public var hookHandlers: [any HookHandler]
    /// Executes the `type: prompt` definitions in `hooks`; nil skips each with a notice. The
    /// CLI shares one runner with its command judge so both spend on the same books.
    public var hookPromptRunner: PromptHookRunner?
    /// Lineage, written to the session's transcript meta and to every `RunRecord` it appends:
    /// the session that delegated this one (nil for a lead), how deep it nests (0 for a lead,
    /// 1 for its subagents), how it was started (`interactive` / `do` / `subagent`; nil when
    /// the embedder didn't say) and whether a delegated run was spawned detached
    /// (`task` with `background: true`). Set by `forSubagent` and the task tool; a lead's
    /// caller sets `sessionOrigin` only.
    public var parentSessionId: String?
    public var depth: Int
    public var sessionOrigin: String?
    public var spawnedInBackground: Bool
    /// Characters of any one tool result the model gets to read (`ToolOutputLimiter`): head
    /// 60 % + tail 40 %, the rest to a spill file when `spillScope` is set. Applied once per
    /// result in the session, after the PostToolUse feedback, to every tool alike.
    public var toolResultMaxChars: Int
    /// Where capped results are spilled in full: the session writes 0600 files under
    /// `<scope.root>/<session id>/` (created on the first spill, removed at `end(reason:)`
    /// unless the scope keeps files — `ARNES_KEEP_TMP=1`), and the pointer in the result names
    /// them. The same `SpillScope` goes on the toolset's `PathScope.Rules`: the session opens
    /// its directory there when it first spills — the one place under the harness directory a
    /// model may read, exact to this session — and closes it at `end`. The CLI's root is
    /// `~/.arnes/tmp`. nil = truncate without spilling (evals, panels, nested subagent
    /// sessions, embedders).
    public var spillScope: SpillScope?
    /// When the session ends a turn that is going in circles. See `LoopGuardPolicy`.
    public var loopGuard: LoopGuardPolicy
    /// Ask for the turn's final answer as one JSON object matching this schema: after a
    /// finished turn, one side request over chat completions (`StructuredCompletion`) whose
    /// validated object lands on the record and the `.structuredOutput` event, never in
    /// history. nil = no structured request. Not carried to subagents (`forSubagent`): a
    /// subagent's report is prose the lead reads.
    public var outputSchema: OutputSchema?
    /// What happens to every tool result on its way into history — secret redaction, the
    /// injection scanner, the `<tool_result>` frame, and the taint that escalates network and
    /// `.sensitive` calls after untrusted content. `.default` in the Kit (no frame); the CLI
    /// runs `.cli`. Carried to subagents (`forSubagent`): a nested session frames, scans and
    /// redacts exactly like the lead. See `ToolResultGuardPolicy`.
    public var toolResultGuard: ToolResultGuardPolicy
    /// How the session's model requests survive a flaky wire: jittered retries of a request
    /// refused or a stream broken **before any output token** (429/5xx, an overloaded provider,
    /// a lost connection, a mid-stream error event), the stream idle timeout, and the waits'
    /// cap. `.default` = 4 request retries, 5 stream retries, 5 minutes idle, 60 s of waiting;
    /// the CLI reads `policies.transport`. Carried to subagents (`forSubagent`): a nested
    /// session's wire is the same wire. See `TransportPolicy`.
    public var transport: TransportPolicy
    /// Model-adaptive `think` omission (T5): when true, a model whose manifest says it reasons
    /// natively **and** whose session has the reasoning dial on (`reasoningEffort` set and not
    /// `.none`) is not offered the `think` scratchpad — its own reasoning is the scratchpad, and
    /// the tool would be a redundant step. Read at the per-model tool gate
    /// (`CapabilityGatedTool` on `ThinkTool`, in `Session.availableTools(for:)`) against the live
    /// dial, so `/effort off` brings the tool back. **On by default** since the batch-13 A/B (haiku,
    /// effort medium, 24 trials per arm: 100 % pass in every arm, the tool never called, 6 % fewer
    /// steps and 10 % less spend without it — `evals/ab/README.md`); `policies.adaptiveThink: false`
    /// keeps the tool for every model (invariant 6: the flip is the A/B's, not code's).
    /// Carried to subagents (`forSubagent`): the rule is about the model, not the session.
    public var adaptiveThink: Bool
    /// Prompt-cache discipline: whether an Anthropic-family request marks its stable prefix
    /// (system text, tools, the last message) with `cache_control` breakpoints — only where the
    /// provider supports the field (`ProviderTraits.supportsCacheControl`) — and the entries'
    /// TTL. `.default` = breakpoints on; the CLI reads `policies.promptCache`. Carried to
    /// subagents (`forSubagent`): a nested session re-sends its own prefix every step too.
    /// See `CachePolicy`.
    public var cachePolicy: CachePolicy
    /// How the session keeps a long conversation inside the context window (C2): the threshold
    /// the summarizer runs at, how many recent tool results the request view keeps verbatim
    /// (older large ones are stubbed — `Microcompaction`), the size under which a result is never
    /// cleared, and how many emergency summaries a turn may take. The CLI reads the top-level
    /// `compaction` block; carried to subagents (`forSubagent`): a nested session's window is the
    /// same kind of window. See `CompactionPolicy`.
    public var compaction: CompactionPolicy
    /// Extra instructions for the compaction summarizer — a project's `## Compact instructions`
    /// section (`ProjectInstructions.Discovered.compactInstructions`), appended to the fixed
    /// rubric on every compaction. nil = none. Carried to subagents (`forSubagent`) with the
    /// project instructions they inherit.
    public var compactionInstructions: String?
    /// The run's "always this session" grants — a *reference*, fresh per configuration by
    /// default and carried by `forSubagent`, so a grant the human makes on a nested prompt
    /// covers the lead and the sibling subagents too (one `a` per directory, not one per
    /// agent). Session-scoped: nothing here persists past the run. See `SessionGrants`.
    public var grants: SessionGrants
    /// The path rules the run's tools were built with (`ToolContext.pathRules`: `paths.*` globs,
    /// `--add-dir` roots, the memory/spill/paste carve-outs) — what the turn's verifier hands
    /// `Verifier.Context.rules` so its untracked-file paste refuses exactly what `read_file`
    /// refuses (S7). Not a permission: a rule only narrows. Carried by `forSubagent`.
    public var pathRules: PathScope.Rules
    /// Inject a pack directory for isolated evaluations/embedders. nil uses ARNES_PACKS_DIR
    /// or the user's normal directory. Inherited by nested sessions.
    public var packsDirectory: URL?
    /// Opt-in extracted compiler/test diagnostics appended to bash results, under the
    /// same redaction, scanning and output cap. Does not execute an additional command.
    public var commandDiagnostics: Bool

    public init(
      model: String? = nil,
      fallbackModels: [String] = [],
      maxStepsPerTurn: Int = .max,
      dialect: DialectOverride = .auto,
      systemSuffix: String? = nil,
      projectInstructions: String? = nil,
      extraSystemSections: [String] = [],
      maxCostUSD: Double? = nil,
      hooks: [HookDefinition] = [],
      reasoningEffort: Reasoning.Effort? = nil,
      agent: String? = nil,
      provider: ProviderTraits = .openrouter,
      subprocessEnvironment: SubprocessEnvironment = .default,
      workingDirectory: URL? = nil,
      permissionMode: PermissionMode = .default,
      permissionRules: PermissionRules = .empty,
      joinBackgroundAtTurnEnd: Bool = true,
      hookHandlers: [any HookHandler] = [],
      hookPromptRunner: PromptHookRunner? = nil,
      parentSessionId: String? = nil,
      depth: Int = 0,
      sessionOrigin: String? = nil,
      spawnedInBackground: Bool = false,
      toolResultMaxChars: Int = ToolOutputLimiter.defaultMaxChars,
      spillScope: SpillScope? = nil,
      loopGuard: LoopGuardPolicy = .default,
      outputSchema: OutputSchema? = nil,
      toolResultGuard: ToolResultGuardPolicy = .default,
      transport: TransportPolicy = .default,
      adaptiveThink: Bool = true,
      cachePolicy: CachePolicy = .default,
      compaction: CompactionPolicy = .default,
      compactionInstructions: String? = nil,
      grants: SessionGrants = SessionGrants(),
      pathRules: PathScope.Rules = .default,
      packsDirectory: URL? = nil,
      commandDiagnostics: Bool = false)
    {
      self.model = model ?? provider.defaultModel
      self.fallbackModels = fallbackModels
      self.maxStepsPerTurn = maxStepsPerTurn
      self.dialect = dialect
      self.systemSuffix = systemSuffix
      self.projectInstructions = projectInstructions
      self.extraSystemSections = extraSystemSections
      self.maxCostUSD = maxCostUSD
      self.hooks = hooks
      self.reasoningEffort = reasoningEffort
      self.agent = agent
      self.provider = provider
      self.subprocessEnvironment = subprocessEnvironment
      self.workingDirectory = workingDirectory
      self.permissionMode = permissionMode
      self.permissionRules = permissionRules
      self.joinBackgroundAtTurnEnd = joinBackgroundAtTurnEnd
      self.hookHandlers = hookHandlers
      self.hookPromptRunner = hookPromptRunner
      self.parentSessionId = parentSessionId
      self.depth = depth
      self.sessionOrigin = sessionOrigin
      self.spawnedInBackground = spawnedInBackground
      self.toolResultMaxChars = toolResultMaxChars
      self.spillScope = spillScope
      self.loopGuard = loopGuard
      self.outputSchema = outputSchema
      self.toolResultGuard = toolResultGuard
      self.transport = transport
      self.adaptiveThink = adaptiveThink
      self.cachePolicy = cachePolicy
      self.compaction = compaction
      self.compactionInstructions = compactionInstructions
      self.grants = grants
      self.pathRules = pathRules
      self.packsDirectory = packsDirectory
      self.commandDiagnostics = commandDiagnostics
    }

    /// The configuration for a nested session the task tool spawns: the agent's model, role
    /// suffix and caps over this configuration's plumbing — provider, working directory,
    /// environment policy, permission rules, wire dialect, repo instructions, and the hooks
    /// minus the user's turn-end `Stop` hooks (a subagent's turn end is not the user's —
    /// `SubagentStop` is its mapped equivalent), the delegation hooks themselves
    /// (`SubagentStart`/`SubagentStop` are run by the task tool *around* this session), and
    /// the session-level events (`SessionStart`/`SessionEnd`/`UserPromptSubmit`/
    /// `Notification` — a subagent's prompt is the lead's task, not the user's, and it is
    /// never started or ended the way the user's session is). The per-call and compaction
    /// hooks (`PreToolUse`/`PostToolUse`/`PostToolUseFailure`/`PermissionRequest`/
    /// `PreCompact`/`PostCompact`) follow the work.
    ///
    /// One derivation point for every inherited setting, and every rule here is
    /// **narrow-only** — a subagent may give up what the parent has, never gain more:
    /// - `dialect` and the per-tool hooks follow the work, so a guardrail can't be
    ///   delegated around and a gateway's pinned dialect keeps applying.
    /// - `reasoningEffort` is the agent's own dial when it declared one, else the parent's.
    /// - `projectInstructions` ride along unless the agent is a read-only explorer, which
    ///   can't act on repo conventions and shouldn't pay 32KB of context for them.
    /// - `maxCostUSD` is the cap the caller resolved (agent budget, configured default, and
    ///   what the parent has left — whichever is tightest).
    /// - `permissionMode` is inherited, except that a read-only agent never runs under a
    ///   mode that auto-approves (`bypass`/`acceptEdits`); `plan` stays, being narrower.
    /// - lineage: `parentSessionId` is the delegating session's id (the caller's, since a
    ///   configuration doesn't know the id of the session running it), `depth` is one deeper,
    ///   `sessionOrigin` is `subagent`. Written to the nested transcript's meta and its records.
    ///
    /// Deliberately *not* carried: `fallbackModels` — the parent's fallbacks are picked for
    /// the parent's model, and a subagent usually runs a different one; `extraSystemSections` —
    /// the task tool renders the nested session's own `# Environment` block (the lead's names
    /// the lead's model and mode); `joinBackgroundAtTurnEnd` — left at its default, a nested
    /// session never holds the task tool, so it has nothing to join; `spillScope` — a nested
    /// session is never `end`ed, so its spill files would outlive the run and its directory
    /// would stay open for reads (the lead caps and spills the report it gets); `outputSchema`
    /// — a subagent's report is prose the lead reads, the structured answer is the lead's.
    ///
    /// - Parameters:
    ///   - readOnly: the agent declared `permissionMode: readOnly`. The caller also wraps
    ///     the delegate; this narrows the mode so an auto-approving parent can't run past it.
    ///   - inheritsProjectInstructions: false for a read-only explorer.
    ///   - parentSessionId: the id of the session doing the delegating (`TaskTool.parentSessionId`).
    public func forSubagent(
      named agent: String,
      model: String,
      systemSuffix: String,
      maxStepsPerTurn: Int? = nil,
      maxCostUSD: Double? = nil,
      reasoningEffort: Reasoning.Effort? = nil,
      readOnly: Bool = false,
      inheritsProjectInstructions: Bool = true,
      parentSessionId: String? = nil)
      -> Configuration
    {
      Configuration(
        model: model,
        maxStepsPerTurn: maxStepsPerTurn ?? self.maxStepsPerTurn,
        dialect: dialect,
        systemSuffix: systemSuffix,
        projectInstructions: inheritsProjectInstructions ? projectInstructions : nil,
        maxCostUSD: maxCostUSD,
        // The per-tool hooks follow the work; the lifecycle ones are the caller's to run —
        // `Stop` belongs to the user's turn end, the task tool runs SubagentStart/Stop
        // around this session rather than inside it, and the session events are about the
        // user's session, which a nested one is not (`HookEvent.keptByTheLead` — the same
        // filter a panel candidate's and an eval trial's session get).
        hooks: hooks.forNestedRun,
        reasoningEffort: reasoningEffort ?? self.reasoningEffort,
        agent: agent,
        provider: provider,
        subprocessEnvironment: subprocessEnvironment,
        workingDirectory: workingDirectory,
        permissionMode: readOnly ? Self.readOnlyMode(narrowing: permissionMode) : permissionMode,
        permissionRules: permissionRules,
        // In-process handlers follow the work under the same event filter as the definitions;
        // the prompt runner rides along so a nested session's prompt hooks run (and are paid
        // for on the same books).
        hookHandlers: hookHandlers.forNestedRun,
        hookPromptRunner: hookPromptRunner,
        // Lineage: who delegated, how deep, and that this session is a subagent's.
        parentSessionId: parentSessionId,
        depth: depth + 1,
        sessionOrigin: Self.subagentOrigin,
        // The output cap and the loop guard follow the work: a subagent's results are capped
        // like the lead's and it is stopped from circling the same way. The spill scope is
        // deliberately *not* carried: a nested session is never `end`ed, so its spill directory
        // would outlive the run and stay open for reads — a subagent truncates without
        // spilling, and its report to the lead is capped (and spilled) by the lead's own session.
        toolResultMaxChars: toolResultMaxChars,
        loopGuard: loopGuard,
        // The guard follows the work: a subagent's results are redacted, scanned and framed
        // like the lead's, and it taints on the same content.
        toolResultGuard: toolResultGuard,
        // The wire is the same wire: a nested session retries, times out and backs off like the
        // lead (infrastructure, not a capability — nothing to narrow).
        transport: transport,
        // The `think` rule is about the model a session runs, not about which session: carried.
        adaptiveThink: adaptiveThink,
        // A nested session re-sends its own prefix every step too; the same discipline, on the
        // same wire (a cost switch, not a capability — nothing to narrow).
        cachePolicy: cachePolicy,
        // The window is the same kind of window: a subagent clears and summarizes like the lead,
        // and the project's compaction instructions follow the project instructions it inherits.
        compaction: compaction,
        compactionInstructions: inheritsProjectInstructions ? compactionInstructions : nil,
        // The *same* grant store, not a copy: "always this session" answered anywhere covers
        // the whole run. Widens nothing — a grant is the human's own standing answer, plan
        // mode is checked before grants, and a read-only posture refuses pre-approved calls.
        grants: grants,
        // The same path rules: a nested run's verifier gates its untracked-file paste by the
        // rules the lead's tools run under (S7) — a rule only ever narrows what is read.
        pathRules: pathRules,
        packsDirectory: packsDirectory,
        commandDiagnostics: commandDiagnostics)
    }

    /// The `sessionOrigin` of every nested session. The lead's is the caller's to name
    /// (`interactive`, `do`); an embedder that says nothing leaves it nil.
    public static let subagentOrigin = "subagent"

    /// The strictest of `mode` and "always ask": `plan` denies everything gated and stays,
    /// anything that auto-approves drops to `default` so the read-only delegate is reached.
    static func readOnlyMode(narrowing mode: PermissionMode) -> PermissionMode {
      mode == .plan ? .plan : .default
    }

    /// Hook events a nested session never runs itself: the user's turn end (`Stop`), the
    /// delegation pair the task tool runs around it, and the session-level events
    /// (`SessionStart`/`SessionEnd`/`UserPromptSubmit`/`Notification`). The one definition
    /// is `HookEvent.keptByTheLead` (shared with the panel and eval runners, and with the
    /// `forNestedRun` filters on definitions and handlers); this alias is kept for source
    /// compatibility and can never drift from them.
    static let hookEventsKeptByTheLead: Set<HookEvent> = HookEvent.keptByTheLead
  }
}
