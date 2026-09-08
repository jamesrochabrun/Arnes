import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - ProviderOptions

/// The `--provider` flag shared by every command that talks to a router.
struct ProviderOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Provider from ~/.arnes/config.json (default: ARNES_PROVIDER, then the config's `provider`, then openrouter).")
  var provider: String?
}

// MARK: - ArnesRuntime

/// Everything a command needs to talk to the configured provider: the resolved entry,
/// an OpenRouterSwift service pointed at it, one shared model catalog (so the manifest
/// is fetched once per process), and the traits the loop shapes requests by.
struct ArnesRuntime {
  let provider: ResolvedProvider
  let service: OpenRouterService
  let catalog: ModelCatalog
  /// Top-level `shellEnvironment` from `~/.arnes/config.json`, or nil for the default
  /// (inherit everything but the provider token).
  let shellEnvironmentPolicy: ShellEnvironmentPolicy?
  /// Which files count as project instructions and how much of them loads — top-level
  /// `instructions` from `~/.arnes/config.json`, or the ecosystem defaults.
  let instructionOptions: ProjectInstructions.Options
  /// Top-level `paths` from `~/.arnes/config.json`: extra protected / sensitive-write /
  /// deny-read globs merged with the built-in classification. Additive only.
  let pathPolicy: PathPolicy
  /// Whether the `# Environment` block rides every session's system prompt — on unless
  /// top-level `policies.environmentContext` is `false`. See `EnvironmentContext`.
  let environmentContextEnabled: Bool
  /// `policies.skillListingBytes`: the `# Skills` listing cap handed to every `SkillTool`.
  let skillListingMaxBytes: Int
  /// Top-level `limits` from `~/.arnes/config.json`: the tool-result cap, bash's output size
  /// and the loop guard thresholds — or the built-in defaults. See `LimitsConfig`.
  let limits: LimitsConfig
  /// Top-level `checkpoints` from `~/.arnes/config.json`: whether the REPL keeps a pre-image
  /// before every `write_file`/`edit_file` for `/rewind`, and how much. nil = the defaults (on).
  let checkpoints: CheckpointsConfig?
  /// What every CLI session does to its tool results (`ToolResultGuardPolicy.cli`: redact,
  /// scan, frame, taint), with framing switched by `policies.toolResultFraming`.
  let toolResultGuard: ToolResultGuardPolicy
  /// Top-level `memory` from `~/.arnes/config.json`: the model's own notes per project (C3) —
  /// on/off, where they live, how much of the index rides the prompt. nil = the defaults (on).
  let memory: MemoryConfig?
  /// How every CLI session's model requests survive a flaky wire — `policies.transport` over the
  /// built-in retry and idle-timeout numbers. See `TransportPolicy`.
  let transport: TransportPolicy
  /// Top-level `web` from `~/.arnes/config.json` (T5): the `web_fetch` tool's domain lists and
  /// caps. nil = no block = no tool in any run of this process. See `WebConfig`.
  let web: WebConfig?
  /// Prompt-cache discipline for every CLI session — `policies.promptCache` over the built-in
  /// (breakpoints on for the Anthropic family where the provider accepts them). See `CachePolicy`.
  let cachePolicy: CachePolicy
  /// How every CLI session keeps a long conversation inside the window (C2) — the top-level
  /// `compaction` block over the built-in numbers. See `CompactionPolicy`.
  let compaction: CompactionPolicy
  /// Where the fetched model manifest is kept between processes (`~/.arnes/models`) and for how
  /// long it is served without a fetch — `policies.manifestCache`; nil = the cache is off and
  /// every process fetches. See `ManifestCache`.
  let manifestCache: ManifestCache?
  /// `policies.adaptiveThink` (P1): whether a natively reasoning model with the dial on is
  /// offered the `think` tool — `Session.Configuration.adaptiveThink` on every CLI session,
  /// trial and candidate. true unless the key says false (the batch-13 A/B flipped the default;
  /// `evals/ab/README.md` has the numbers).
  let adaptiveThink: Bool
  /// `policies.panelOnVerifierFail` (P2): the panel size `arnes do --verify … --yes` escalates to
  /// when the verifier says FAIL and the run passed no `--panel-on-fail`. nil/0/1 = off (the
  /// flag's `0` also switches this off for one run). Read by `Do.panelOnFailArmed`.
  let panelOnVerifierFail: Int?
  let commandDiagnostics: Bool

  var traits: ProviderTraits { provider.traits }

  /// Where the CLI keeps fetched manifests: `~/.arnes/models/<provider>.json`.
  static var manifestCacheRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/models")
  }

  /// The manifest cache the config asks for: the default (on, 24 h) with no block, the block's
  /// policy otherwise, nil when it says `enabled: false`.
  static func manifestCache(configured: ManifestCacheConfig?) -> ManifestCache? {
    let policy: ManifestCachePolicy?
    if let configured {
      policy = configured.policy
    } else {
      policy = .default
    }
    return policy.map { ManifestCache(directory: manifestCacheRoot, policy: $0) }
  }

  /// The `web_fetch` policy for a run's `ToolContext`, or nil when the config has no `web` block
  /// (the block's presence is the opt-in). `coreTools` still leaves the tool out under a sandbox
  /// that denies the network.
  var webPolicy: WebFetchPolicy? { web?.policy }

  /// Where memory lives: `ARNES_MEMORY_DIR`, else `memory.directory`, else `~/.arnes/memory`.
  var memoryRoot: URL {
    MemoryStore.root(configured: memory?.directory)
  }

  /// The memory store for the project `workdir` belongs to (`<memoryRoot>/<project key>/`), or
  /// nil when `memory.enabled` is false. Built before the tools: its directory is the one
  /// carve-out `pathRules`/`sandboxResolution` open (`--no-memory` passes nil for both), and its
  /// `promptSection()` is the `# Memory` section the REPL and `do` append after the environment
  /// block. Headless runs read memory too; their writes stay `.sensitive` (vetoed under `--yes`
  /// unless `--add-dir` names the directory).
  func memoryStore(workdir: URL) -> MemoryStore? {
    let config = memory ?? MemoryConfig()
    guard config.isEnabled else { return nil }
    return MemoryStore.forProject(
      workdir: workdir, memoryRoot: memoryRoot, options: instructionOptions,
      maxLines: config.effectiveMaxLines, maxBytes: config.effectiveMaxBytes)
  }

  /// Banner tag for the run's memory: `memory 42 lines`, `memory none yet`; nil when off.
  static func bannerMemory(_ store: MemoryStore?) -> String? {
    guard let store else { return nil }
    guard let loaded = store.load() else { return "memory none yet" }
    return "memory \(loaded.lineCount) line\(loaded.lineCount == 1 ? "" : "s")"
  }

  /// Where the REPL keeps file checkpoints: `~/.arnes/checkpoints/<session id>/` — the sidecar
  /// `SessionStore.delete`/`prune` sweep with the session, under the write floor no tool crosses.
  static var checkpointRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/checkpoints")
  }

  /// A checkpoint store for the REPL's tools, or nil when `checkpoints.enabled` is false. Built
  /// before the session (the tools take it through `ToolContext`), bound to the session once it
  /// exists — `bind(sessionId:inheritingFrom:currentTurn:)` — and rebound on `/resume` and
  /// `/fork`. Headless runs never build one: a one-shot has no `/rewind`.
  func checkpointStore() -> FileCheckpointStore? {
    let config = checkpoints ?? CheckpointsConfig()
    guard config.isEnabled else { return nil }
    return FileCheckpointStore(root: Self.checkpointRoot, policy: config.policy)
  }

  /// The background-job registry for a run's tools (`bash … background: true` + the `job` tool),
  /// one per REPL or `do` run, handed to both through `ToolContext.jobs`. Its logs live under
  /// the OS temp directory (writable inside the sandbox, unlike `~/.arnes/tmp`), and its jobs
  /// die with the session (`Session.shutdown()`, called by `end`). Panels, evals and the probe
  /// build contexts without one.
  func jobRegistry() -> JobRegistry {
    JobRegistry()
  }

  /// Where the CLI's sessions spill capped tool results: `~/.arnes/tmp` (one `<session id>`
  /// subdirectory each, removed when the session ends).
  static var spillRoot: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/tmp")
  }

  /// The one spill carve-out this process's tools and sessions share (`SpillScope`): the live
  /// session opens `~/.arnes/tmp/<its id>` for reads when it first spills and closes it at
  /// `end`, so a model reads its own spilled output freely and nothing else under `~/.arnes` —
  /// not another session's directory, not a crashed run's leftovers. One per runtime, because
  /// the tools (built first, `pathRules`) and the session (`applyLimits`) must hold the same
  /// reference; the REPL's `/resume` and `/fork` sessions inherit it through the toolset.
  let spillScope: SpillScope

  /// Applies the configured `limits` to a session configuration: the output cap, the spill
  /// scope, the loop guard, the result guard, the transport policy, the cache policy and the
  /// compaction policy. Panels and evals never call this — their trials truncate without spilling,
  /// so nothing of a trial lands under the user's `~/.arnes` (and they keep the built-in transport
  /// numbers and the default cache discipline). Their constructors receive the configured
  /// compaction policy and command-diagnostics switch separately.
  func applyLimits(to configuration: inout Session.Configuration) {
    configuration.toolResultMaxChars = limits.effectiveToolResultChars
    configuration.spillScope = spillScope
    configuration.loopGuard = limits.effectiveLoopGuard
    configuration.toolResultGuard = toolResultGuard
    configuration.transport = transport
    configuration.cachePolicy = cachePolicy
    configuration.compaction = compaction
    configuration.adaptiveThink = adaptiveThink
    configuration.commandDiagnostics = commandDiagnostics
  }

  /// The session-wide facts for an environment block: platform and date captured now, plus
  /// the sandbox the run's tools are under. nil when the block is switched off, so a call
  /// site passes the result straight through (`environmentContext: runtime.environmentFacts(...)`).
  func environmentFacts(sandbox: ShellSandbox?) -> EnvironmentContext.Facts? {
    environmentContextEnabled ? EnvironmentContext.Facts(sandbox: sandbox) : nil
  }

  /// What `bash` and hook subprocesses inherit: the configured policy, with the active
  /// provider's key variable always withheld on top of the built-in token names.
  var subprocessEnvironment: SubprocessEnvironment {
    SubprocessEnvironment(
      policy: shellEnvironmentPolicy ?? ShellEnvironmentPolicy(),
      redactedKeys: SubprocessEnvironment.providerTokenKeys.union([provider.apiKeyEnv]))
  }

  /// How paths classify for this run: the config's extra globs, widened by whatever
  /// `--add-dir` named, plus the spill scope — the live session's own spill directory, opened
  /// for reads so a model can page a capped result back — and the project's memory directory
  /// (`memoryRoot`: reads free, writes `.sensitive`, the floor lifted there; nil = no memory).
  /// Everything a toolset needs beyond its root.
  func pathRules(
    addedDirectories: [URL] = [], memoryRoot: URL? = nil, pasteStash: URL? = nil)
    -> PathScope.Rules
  {
    PathScope.Rules(
      roots: .init(additional: addedDirectories), policy: pathPolicy, spillScope: spillScope,
      memoryRoot: memoryRoot, pasteStash: pasteStash)
  }

  /// `--add-dir` values → absolute, standardized directories. A path that isn't a directory
  /// is rejected here rather than silently widening nothing.
  static func parseAddedDirectories(_ values: [String]) throws -> [URL] {
    try values.compactMap { raw -> URL? in
      let trimmed = raw.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { return nil }
      let expanded = (trimmed as NSString).expandingTildeInPath
      let url = expanded.hasPrefix("/")
        ? URL(fileURLWithPath: expanded)
        : URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(expanded)
      var isDirectory: ObjCBool = false
      guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
      else {
        throw ValidationError("--add-dir \(raw): not a directory")
      }
      return url.standardizedFileURL
    }
  }

  /// Banner tag when the environment policy drops secret-looking variable names.
  var bannerEnvironment: String? {
    shellEnvironmentPolicy?.excludeSecrets == true ? "env scrub" : nil
  }

  /// The one request path for every cheap-model question this process asks — `type: prompt`
  /// hooks and the command judge — so their spend lands on one ledger, drained into the turn's
  /// record by the session. Hooks that name no `model` run on the provider's `bashJudge`.
  /// Put it on every `Session.Configuration` this runtime assembles (`hookPromptRunner`).
  let promptHookRunner: PromptHookRunner

  /// The configured command-safety judge, or nil when the provider didn't opt in
  /// (`ProviderConfig.bashJudge`). Wrap a permission delegate with it via `judging(_:headlessVeto:)`.
  /// Shares `promptHookRunner`, so its requests are booked with the prompt hooks'.
  var commandJudge: CommandJudge? {
    provider.bashJudge.map { CommandJudge(runner: promptHookRunner, model: $0) }
  }

  /// Layers the command judge over `inner` when one is configured; returns `inner` unchanged
  /// otherwise. `headlessVeto` denies risky commands outright (no human to read the prompt);
  /// interactive callers pass false so the warning just rides the prompt.
  func judging(_ inner: any PermissionDelegate, headlessVeto: Bool) -> any PermissionDelegate {
    guard let judge = commandJudge else { return inner }
    return JudgingPermissions(inner: inner, judge: judge, headlessVeto: headlessVeto)
  }

  /// What the provider's `sandbox` block means for one working root. Writes are confined to
  /// `root` + `--add-dir` directories + temp + any configured extra paths, the tree's
  /// protected corners and the credential paths are denied, network per policy.
  ///
  /// - Parameters:
  ///   - autonomous: an unattended run (`do --yes`, an eval trial, a panel candidate). Those
  ///     are confined **by default** when the config says nothing about the sandbox and the
  ///     platform can enforce it; interactive sessions stay opt-in.
  ///   - memoryRoot: the run's memory directory, re-allowed for writes inside the `~/.arnes`
  ///     deny so a write the user approved there lands (the permission layer still gates it as
  ///     `.sensitive`); nil = no carve-out.
  func sandboxResolution(
    root: URL,
    addedDirectories: [URL] = [],
    autonomous: Bool = false,
    memoryRoot: URL? = nil)
    -> ShellSandbox.Resolution
  {
    ShellSandbox.resolve(
      config: provider.sandbox,
      root: root,
      addedDirectories: addedDirectories,
      denyReadPatterns: pathPolicy.denyRead,
      autonomous: autonomous,
      writableCarveOuts: memoryRoot.map { [$0] } ?? [])
  }

  /// The `bash`/file-tool sandbox for a working root, or nil when this run is unconfined.
  func shellSandbox(
    root: URL,
    addedDirectories: [URL] = [],
    autonomous: Bool = false,
    memoryRoot: URL? = nil)
    -> ShellSandbox?
  {
    sandboxResolution(
      root: root, addedDirectories: addedDirectories, autonomous: autonomous, memoryRoot: memoryRoot)
      .sandbox
  }

  /// The sandbox for the process's current directory (what the CLI uses).
  var shellSandbox: ShellSandbox? {
    shellSandbox(root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
  }

  /// The process's current directory as a URL — every command's working root.
  static var workingDirectory: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
  }

  /// Warning for deny-read entries the kernel can't enforce: SBPL matches paths, not globs,
  /// so `**/*.pem` is gated by the path classifier for `read_file`/`grep`/`glob` but a
  /// sandboxed `cat` still reaches it. Silence there would read as full coverage.
  func sandboxDenyReadWarning(_ resolution: ShellSandbox.Resolution) -> String? {
    guard resolution.sandbox != nil, !resolution.skippedDenyReadPatterns.isEmpty else { return nil }
    let listed = resolution.skippedDenyReadPatterns.prefix(4).joined(separator: ", ")
    return "⚠ sandbox can't enforce deny-read glob(s) \(listed) at the kernel level "
      + "(paths only) — read_file/grep/glob still gate them; use an absolute path in "
      + "sandbox.denyRead for a hard block"
  }

  /// Caps and the fallback model for delegated work (`subagents` in the provider entry),
  /// or the built-in defaults when the provider configures none.
  var subagentDefaults: TaskTool.Defaults {
    TaskTool.Defaults(provider.subagents)
  }

  /// Lifecycle hooks for a run: the user's `~/.arnes/hooks.json`, plus `<cwd>/.arnes/hooks.json`
  /// when the directory is trusted *and* the definitions' fingerprints were recorded with
  /// `arnes hooks trust`. Project hooks are narrow-only (deny/ask/feedback; never allow or
  /// `updatedInput`) — enforced in `HookEngine`, not here.
  ///
  /// `cwd` is the caller's, deliberately: a panel candidate runs in a snapshot of the
  /// working tree, and the trust question is about the *original* directory, not the temp
  /// copy. `trusted` is the run's trust-gate decision; the store is consulted on top.
  /// Empty when absent; a malformed user file yields nothing here and a warning via
  /// `hooksWarning` (a typo shouldn't silently disable guardrails without a word).
  func hooks(cwd: URL, trusted: Bool) -> LoadedHooks {
    (try? HookConfig.load(project: cwd, directoryTrusted: trusted)) ?? LoadedHooks()
  }

  var hooksWarning: String? {
    do { _ = try HookConfig.load(); return nil }
    catch { return "⚠ \(HookConfig.defaultURL.path) is invalid: \(error) — hooks disabled" }
  }

  /// User-global permission rules (`~/.arnes/rules.json`), merged with a trusted project's
  /// `deny`/`ask` (never its `allow`). `includeProject` mirrors the skills/agents trust
  /// gate; `workdir` is the directory whose `.arnes/rules.json` may apply.
  func permissionRules(includeProject: Bool, workdir: URL) -> (rules: PermissionRules, droppedProjectAllows: Int) {
    let user = (try? PermissionRules.load()) ?? nil
    let project: PermissionRules? = includeProject
      ? (try? PermissionRules.load(from: workdir.appendingPathComponent(".arnes/rules.json"))) ?? nil
      : nil
    return PermissionRules.merged(user: user, project: project)
  }

  var rulesWarning: String? {
    do { _ = try PermissionRules.load(); return nil }
    catch { return "⚠ \(PermissionRules.defaultURL.path) is invalid: \(error) — rules disabled" }
  }

  /// Banner tag when hooks are configured, naming how many of them a project contributed.
  /// With prompt hooks among them the tag adds their count (`hooks: 3 (1 project, +1 prompt)`).
  func bannerHooks(_ loaded: LoadedHooks) -> String? {
    let active = loaded.active
    guard !active.isEmpty else { return nil }
    let project = active.filter { $0.source == .project }.count
    let prompt = active.filter { $0.type == .prompt }.count
    if prompt > 0 {
      return project > 0
        ? "hooks: \(active.count) (\(project) project, +\(prompt) prompt)"
        : "hooks: \(active.count) (+\(prompt) prompt)"
    }
    return project > 0 ? "hooks: \(active.count) (\(project) project)" : "hooks: \(active.count)"
  }

  /// A short banner tag for a resolved sandbox (`sandbox` / `sandbox no-net`), else nil.
  /// Takes the sandbox the run actually built rather than the config, so the banner can't
  /// claim confinement a run doesn't have.
  static func bannerSandbox(_ sandbox: ShellSandbox?) -> String? {
    guard let sandbox else { return nil }
    return sandbox.allowNetwork ? "sandbox" : "sandbox no-net"
  }

  /// A startup warning when the sandbox was asked for but this platform can't enforce it:
  /// either every command fails closed (the default) or, with `failIfUnavailable: false`,
  /// the run continues unconfined — both worth saying out loud.
  var sandboxSupportWarning: String? {
    guard let config = provider.sandbox, config.enabled, !ShellSandbox.isSupported else { return nil }
    if config.failIfUnavailable == false {
      return "⚠ sandbox is enabled but unsupported on this platform (macOS needs "
        + "/usr/bin/sandbox-exec) — running UNCONFINED because failIfUnavailable is false"
    }
    return "⚠ sandbox is enabled but unsupported on this platform (macOS needs /usr/bin/sandbox-exec) — "
      + "bash commands will fail closed; disable it in config to run unconfined"
  }

  /// The red warning `--no-sandbox` earns on an unattended run: it turns off the confinement
  /// that would otherwise have applied, and the whole point of unattended work is that nobody
  /// is checking what the model does with the shell.
  static let sandboxOptOutWarning =
    "⚠ --no-sandbox: this unattended run is NOT confined — bash and the file tools can write "
    + "anywhere the user can"

  static func make(_ options: ProviderOptions, stateDirectory: URL? = nil) throws -> ArnesRuntime {
    try make(provider: options.provider, stateDirectory: stateDirectory)
  }

  static func make(provider requested: String?, stateDirectory: URL? = nil) throws -> ArnesRuntime {
    let configURL = stateDirectory?.appendingPathComponent("config.json") ?? ArnesConfig.defaultURL
    let credentialsURL = stateDirectory?.appendingPathComponent("credentials") ?? ProviderResolver.defaultCredentialsURL
    let config: ArnesConfig?
    do {
      config = try ArnesConfig.load(from: configURL)
    } catch {
      throw ValidationError("\(configURL.path) is invalid: \(error)")
    }
    let resolved: ResolvedProvider
    do {
      resolved = try ProviderResolver.resolve(requested: requested, config: config, credentialsURL: credentialsURL)
    } catch let error as ProviderError {
      throw ValidationError(error.description)
    }
    // Both files hold tokens; Arnes creates its own as 0600, but the user may have
    // written them by hand.
    for file in [credentialsURL, configURL, stateDirectory?.appendingPathComponent("hooks.json") ?? HookConfig.defaultURL]
      where SecureFiles.isReadableByOthers(file)
    {
      FileHandle.standardError.write(Data(
        ANSI.yellow("⚠ \(file.path) is readable by other users — chmod 600 it\n").utf8))
    }
    // Retention, when the user asked for it: one sweep per process, named sessions kept.
    if stateDirectory == nil, let days = config?.sessions?.retentionDays, days > 0, !didSweepSessions {
      didSweepSessions = true
      if let pruned = try? SessionStore().prune(olderThan: days), pruned > 0 {
        FileHandle.standardError.write(Data(
          ANSI.dim("pruned \(pruned) session\(pruned == 1 ? "" : "s") older than \(days) days\n").utf8))
      }
    }
    return ArnesRuntime(
      provider: resolved,
      shellEnvironmentPolicy: config?.shellEnvironment,
      instructionOptions: ProjectInstructions.Options(config: config?.instructions),
      pathPolicy: config?.paths ?? .empty,
      environmentContextEnabled: EnvironmentContext.isEnabled(in: config),
      skillListingMaxBytes: config?.policies?.skillListingBytes ?? SkillTool.defaultListingMaxBytes,
      limits: config?.limits ?? .default,
      checkpoints: config?.checkpoints,
      toolResultGuard: .cli(framing: config?.policies?.toolResultFraming ?? true),
      memory: config?.memory,
      transport: config?.policies?.transport?.policy ?? .default,
      web: config?.web,
      cachePolicy: config?.policies?.promptCache?.policy ?? .default,
      compaction: config?.compaction?.policy ?? .default,
      manifestCache: stateDirectory.map { directory in
        (config?.policies?.manifestCache ?? ManifestCacheConfig()).policy.map {
          ManifestCache(directory: directory.appendingPathComponent("models"), policy: $0)
        }
      } ?? manifestCache(configured: config?.policies?.manifestCache),
      adaptiveThink: config?.policies?.adaptiveThink ?? true,
      panelOnVerifierFail: config?.policies?.panelOnVerifierFail,
      commandDiagnostics: config?.policies?.commandDiagnostics ?? false,
      spillRoot: stateDirectory?.appendingPathComponent("tmp"))
  }

  /// The retention sweep runs at most once per process, however many runtimes a command
  /// makes (`resume` re-dispatches into `interactive`, panels build several).
  private static var didSweepSessions = false

  /// Environment variables MCP server processes must not inherit: Arnes's usual token
  /// variables plus whichever one this provider actually reads.
  var redactedEnvironmentKeys: Set<String> {
    ProcessMCPTransport.defaultRedactedEnvironmentKeys.union([provider.apiKeyEnv])
  }

  init(
    provider: ResolvedProvider,
    shellEnvironmentPolicy: ShellEnvironmentPolicy? = nil,
    instructionOptions: ProjectInstructions.Options = .default,
    pathPolicy: PathPolicy = .empty,
    environmentContextEnabled: Bool = true,
    skillListingMaxBytes: Int = SkillTool.defaultListingMaxBytes,
    limits: LimitsConfig = .default,
    checkpoints: CheckpointsConfig? = nil,
    toolResultGuard: ToolResultGuardPolicy = .cli,
    memory: MemoryConfig? = nil,
    transport: TransportPolicy = .default,
    web: WebConfig? = nil,
    cachePolicy: CachePolicy = .default,
    compaction: CompactionPolicy = .default,
    manifestCache: ManifestCache? = nil,
    adaptiveThink: Bool = true,
    panelOnVerifierFail: Int? = nil,
    commandDiagnostics: Bool = false,
    spillRoot: URL? = nil)
  {
    self.provider = provider
    self.manifestCache = manifestCache
    self.adaptiveThink = adaptiveThink
    self.panelOnVerifierFail = panelOnVerifierFail
    self.commandDiagnostics = commandDiagnostics
    self.shellEnvironmentPolicy = shellEnvironmentPolicy
    self.instructionOptions = instructionOptions
    self.pathPolicy = pathPolicy
    self.environmentContextEnabled = environmentContextEnabled
    self.skillListingMaxBytes = skillListingMaxBytes
    self.limits = limits
    self.checkpoints = checkpoints
    self.toolResultGuard = toolResultGuard
    self.memory = memory
    self.transport = transport
    self.web = web
    self.cachePolicy = cachePolicy
    self.compaction = compaction
    spillScope = SpillScope(root: spillRoot ?? Self.spillRoot)
    // A token-minting command means the bearer must be refreshed per request, which the
    // gateway client does even when the root is openrouter.ai itself.
    let tokens = provider.apiKeyCommand.map { BearerTokenSource(command: $0) }
    // OpenRouterSwift builds `https://openrouter.ai/api/v1/…` URLs; any other root is
    // reached by rewriting them on the way out. Bodies and responses are untouched.
    let httpClient: OpenRouterHTTPClient? = provider.isStandardOpenRouter && tokens == nil
      ? nil
      : GatewayHTTPClient(root: provider.baseURL, tokens: tokens)
    let service = OpenRouter.service(
      apiKey: provider.apiKey,
      configuration: OpenRouterConfiguration(
        appReferer: "https://github.com/jamesrochabrun/Arnes",
        appTitle: "Arnes",
        extraHeaders: provider.headers),
      httpClient: httpClient)
    self.service = service
    switch provider.kind {
    // One cache entry per provider name, whatever kind answers there.
    case .openrouter:
      catalog = ModelCatalog(
        service: service, aliases: provider.aliases, cache: manifestCache, cacheKey: provider.name)
    case .litellm:
      let client = LiteLLMClient(
        baseURL: provider.baseURL, apiKey: provider.apiKey, headers: provider.headers, tokens: tokens)
      catalog = ModelCatalog(
        loader: { try await client.profiles() }, aliases: provider.aliases,
        cache: manifestCache, cacheKey: provider.name)
    case .openaiCompatible:
      // `/models` lists ids only: capabilities are assumed, like any unknown model.
      catalog = ModelCatalog(
        loader: { try await service.models().map { ModelProfile(unknownModelId: $0.id) } },
        aliases: provider.aliases, cache: manifestCache, cacheKey: provider.name)
    }
    // One ledger for the judge and the prompt hooks; `bashJudge` is already alias-resolved.
    promptHookRunner = PromptHookRunner(service: service, catalog: catalog, defaultModel: provider.bashJudge)
  }

  /// The model to run: the flag (an id or a configured alias) when given, else the
  /// provider's default. A provider without one is fine for discovery commands, not
  /// for running.
  func model(_ flag: String?) throws -> String {
    if let flag { return provider.resolveAlias(flag) }
    guard let fallback = provider.defaultModel else {
      throw ValidationError(ProviderError.missingDefaultModel(provider: provider.name).description)
    }
    return fallback
  }

  /// Loads the manifest now (it's needed on the first turn anyway — from the cache when the
  /// copy is fresh, else the network) and returns a warning when it couldn't be fetched: the
  /// run continues on the cached copy when there is one, else on assumed capabilities, and the
  /// user should see that the base URL or key may be off.
  func manifestWarning() async -> String? {
    _ = try? await catalog.all()
    guard let failure = await catalog.manifestFailure else { return nil }
    if case .staleCache(let fetchedAt)? = await catalog.manifestSource {
      let count = (try? await catalog.all().count) ?? 0
      return "⚠ model manifest fetch failed from \(provider.endpointDescription): \(failure.prefix(160)) — "
        + "using the copy cached \(ManifestCache.describeAgeAgo(Date().timeIntervalSince(fetchedAt))) "
        + "(\(count) models); `arnes models --refresh` retries"
    }
    return "⚠ model manifest unavailable from \(provider.endpointDescription): \(failure.prefix(160)) — "
      + "capabilities assumed (tools on, no pricing); check baseURL/key with `arnes providers`"
  }

  /// How the catalog got its manifest, for a status line: `cached 2 h ago` when the disk copy
  /// answered without a fetch, `fetch failed — using the copy cached 2 h ago` when it stood in
  /// for one, nil when it was fetched this process (or never loaded).
  func manifestSourceNote() async -> String? {
    switch await catalog.manifestSource {
    case .cache(let fetchedAt)?:
      return "cached \(ManifestCache.describeAgeAgo(Date().timeIntervalSince(fetchedAt)))"
    case .staleCache(let fetchedAt)?:
      return "fetch failed — using the copy cached \(ManifestCache.describeAgeAgo(Date().timeIntervalSince(fetchedAt)))"
    case .network?, nil:
      return nil
    }
  }

  /// Banner line naming the provider and what kind of router answers there — nil for
  /// plain OpenRouter, where it is implied.
  var bannerProvider: String? {
    provider.isStandardOpenRouter
      ? nil
      : "provider \(provider.name) · \(provider.kind.rawValue) · \(provider.endpointDescription)"
  }
}
