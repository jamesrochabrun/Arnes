import Foundation
import OpenRouterSwift

// MARK: - ProviderKind

/// The API behind a provider's base URL. Arnes speaks OpenAI-compatible wire formats
/// everywhere; the kind decides the few places routers differ — how the model manifest
/// is fetched, how fallbacks are spelled, and whether cost arrives on the response or
/// has to be estimated from tokens and manifest prices.
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
  /// openrouter.ai — the reference: `usage.cost` on every response, `models` fallback
  /// arrays, the `/models` manifest with `supported_parameters`.
  case openrouter
  /// A LiteLLM proxy, or a gateway fronting one: `/model/info` supplies capabilities
  /// and per-token prices, fallbacks ride the per-request `fallbacks` list, and cost is
  /// estimated from usage × prices.
  case litellm
  /// Any other OpenAI-compatible endpoint: `/models` lists ids only, so capabilities
  /// are assumed (tools on, chat dialect) and cost stays unknown.
  case openaiCompatible = "openai-compatible"

  /// Environment variable consulted for the bearer token when `apiKeyEnv` is unset.
  public var defaultAPIKeyEnv: String {
    switch self {
    case .openrouter: return "OPENROUTER_API_KEY"
    case .litellm: return "LITELLM_API_KEY"
    case .openaiCompatible: return "OPENAI_API_KEY"
    }
  }
}

// MARK: - ProviderConfig

/// One entry under `providers` in `~/.arnes/config.json`.
///
/// ```json
/// {
///   "provider": "gateway",
///   "providers": {
///     "gateway": {
///       "kind": "litellm",
///       "baseURL": "https://llm-gateway.example.com/v1",
///       "apiKeyEnv": "GATEWAY_TOKEN",
///       "headersEnv": "GATEWAY_HEADERS",
///       "defaultModel": "claude-sonnet-4-5"
///     }
///   }
/// }
/// ```
/// Opt-in OS confinement for the `bash` tool (`ShellSandbox`). Off unless `enabled`.
public struct SandboxConfig: Codable, Sendable, Equatable {
  /// Turn the sandbox on. When on but the platform can't enforce it, every command fails
  /// closed (macOS is supported via `sandbox-exec`; Linux isn't wired yet).
  public var enabled: Bool
  /// Let sandboxed commands use the network. Default true — false is the strongest
  /// containment but breaks anything that fetches (`git fetch`, `npm install`).
  public var network: Bool?
  /// Absolute paths (a leading `~` is expanded) writable in addition to the working tree and
  /// temp — e.g. a package cache the build needs (`~/.npm`, `~/.cache`).
  public var writable: [String]?
  /// Locations the sandboxed shell may not read at all, on top of the built-in credential
  /// paths under home (`PathScope.sensitiveHomePaths`). **Paths, not globs**: absolute or
  /// `~/`-anchored entries become kernel denies; a pattern like `**/*.pem` has no SBPL
  /// equivalent and is left to the path classifier (`paths.denyRead`), with the run warned.
  public var denyRead: [String]?
  /// Whether a sandbox this platform can't enforce refuses to run (the default, true) or
  /// warns and runs unconfined. `false` is an interactive convenience only — headless
  /// `--yes`, eval trials and panel candidates always fail closed, because nobody is
  /// watching them to notice the warning.
  public var failIfUnavailable: Bool?

  public init(
    enabled: Bool,
    network: Bool? = nil,
    writable: [String]? = nil,
    denyRead: [String]? = nil,
    failIfUnavailable: Bool? = nil)
  {
    self.enabled = enabled
    self.network = network
    self.writable = writable
    self.denyRead = denyRead
    self.failIfUnavailable = failIfUnavailable
  }
}

/// Defaults for delegated work (`"subagents"` in a provider entry). Every key is optional;
/// unset ones keep `TaskTool.Defaults()`.
///
/// ```json
/// "subagents": {
///   "defaultModel": "haiku", "maxSteps": 30, "budgetUSD": 0.5,
///   "maxConcurrent": 4, "maxDepth": 1,
///   "background": false, "joinAtTurnEnd": true, "persistTranscripts": true
/// }
/// ```
/// These are ceilings and fallbacks, never grants: an agent file may ask for less (a
/// tighter budget, fewer steps, `permissionMode: readOnly`) but nothing here — or there —
/// lets a subagent do more than the session that spawned it.
public struct SubagentsConfig: Codable, Sendable, Equatable {
  /// Model for agents whose frontmatter names none, before falling back to the parent's.
  /// An id or a configured alias.
  public var defaultModel: String?
  /// Step cap for a nested turn when the agent doesn't set `maxTurns`/`maxSteps`.
  public var maxSteps: Int?
  /// Dollar cap for a nested run when the agent doesn't set `budget`.
  public var budgetUSD: Double?
  /// How many subagents may run at once (the `SubagentLimiter` cap; the surplus waits for a slot).
  public var maxConcurrent: Int?
  /// How deep delegation may nest: 1 (the default) means a subagent never holds the task tool;
  /// below the cap a nested session gets a child task tool under its own narrowed posture.
  public var maxDepth: Int?
  /// Default for delegations whose call doesn't say (the `background` argument and an agent's frontmatter win).
  public var background: Bool?
  /// Whether a REPL turn waits for its detached runs before ending (a headless run always joins).
  public var joinAtTurnEnd: Bool?
  /// Whether nested sessions persist their own transcripts (carried).
  public var persistTranscripts: Bool?

  public init(
    defaultModel: String? = nil,
    maxSteps: Int? = nil,
    budgetUSD: Double? = nil,
    maxConcurrent: Int? = nil,
    maxDepth: Int? = nil,
    background: Bool? = nil,
    joinAtTurnEnd: Bool? = nil,
    persistTranscripts: Bool? = nil)
  {
    self.defaultModel = defaultModel
    self.maxSteps = maxSteps
    self.budgetUSD = budgetUSD
    self.maxConcurrent = maxConcurrent
    self.maxDepth = maxDepth
    self.background = background
    self.joinAtTurnEnd = joinAtTurnEnd
    self.persistTranscripts = persistTranscripts
  }
}

// MARK: - PathPolicy

/// The top-level `paths` block in `~/.arnes/config.json`: extra locations the built-in
/// path classification should treat as touchy. **Additive only** — every entry here can
/// tighten what the tools do, never loosen it, so a config typo can't hand the agent a
/// credential file. Widening is `--add-dir`, which the user types per run.
///
/// ```json
/// {
///   "paths": {
///     "protected":     ["deploy/**", "*.tfstate"],
///     "sensitiveWrite": ["~/Library/LaunchDaemons/**"],
///     "denyRead":      ["**/.env*", "**/*.pem"]
///   }
/// }
/// ```
/// Globs are the same gitignore-style patterns the permission rules use (`**` crosses
/// directory separators); a leading `~/` anchors to home, `//` to the filesystem root, and
/// anything else matches the working-root-relative path (and the basename).
public struct PathPolicy: Codable, Sendable, Equatable {
  /// In-tree paths whose *write* is `.sensitive` rather than routine, on top of the
  /// built-in `.git/hooks`, `.github/workflows`, `.arnes`, `.claude`, `.mcp.json`.
  public var protected: [String]
  /// Paths whose write is `.sensitive` wherever they land, in the tree or out — the
  /// user's own additions to the shell-startup list (`.zshrc`, LaunchAgents, …).
  public var sensitiveWrite: [String]
  /// Paths that are `.sensitive` to *read*: `read_file`, `grep` and `glob` prompt for them
  /// even inside the working tree. Where `.env` files and private keys go.
  public var denyRead: [String]

  public init(protected: [String] = [], sensitiveWrite: [String] = [], denyRead: [String] = []) {
    self.protected = protected
    self.sensitiveWrite = sensitiveWrite
    self.denyRead = denyRead
  }

  public static let empty = PathPolicy()
  public var isEmpty: Bool { protected.isEmpty && sensitiveWrite.isEmpty && denyRead.isEmpty }

  enum CodingKeys: String, CodingKey { case protected, sensitiveWrite, denyRead }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protected = try container.decodeIfPresent([String].self, forKey: .protected) ?? []
    sensitiveWrite = try container.decodeIfPresent([String].self, forKey: .sensitiveWrite) ?? []
    denyRead = try container.decodeIfPresent([String].self, forKey: .denyRead) ?? []
  }
}

public struct ProviderConfig: Codable, Sendable, Equatable {
  public var kind: ProviderKind
  /// The API root *including the version segment*: `https://openrouter.ai/api/v1`,
  /// `https://llm-gateway.example.com/v1`. Every endpoint path is appended to it.
  public var baseURL: String
  /// Environment variable holding the bearer token (default: the kind's usual one).
  public var apiKeyEnv: String?
  /// A literal token. Prefer `apiKeyEnv` or `~/.arnes/credentials` — the config file
  /// is easy to paste into a bug report.
  public var apiKey: String?
  /// A command (run through `/bin/sh -c`, stdin closed) that prints the bearer token —
  /// `iap-auth`, `gcloud auth print-identity-token`, a vault CLI. Used when no static
  /// source yields a token. Arnes caches the result and re-runs the command a minute
  /// before a JWT's `exp` (or every 50 minutes for opaque tokens), so an hour-long
  /// session never sends a stale credential — the same idea as Claude Code's
  /// `apiKeyHelper`.
  public var apiKeyCommand: String?
  /// Static headers sent on every request (gateway tenancy, tracing, …). Values may use
  /// `${NAME}` for an environment variable and `${UUID}` for one fresh UUID per run.
  public var headers: [String: String]?
  /// Environment variable holding extra headers, one `Name: value` per line — the
  /// convention Claude Code uses for `ANTHROPIC_CUSTOM_HEADERS`, so one variable can
  /// feed both tools.
  public var headersEnv: String?
  /// Model used when none is given on the command line (OpenRouter: `openrouter/auto`).
  /// Optional so a fresh gateway entry can be explored with `arnes models` first; until
  /// it's set, commands that run a model need `-m`.
  public var defaultModel: String?
  /// Short names for this provider's model ids — `{"haiku": "claude-haiku-4-5-20251001"}`
  /// — honored by `-m`, `/model`, `/agents`, subagent `model:` frontmatter, and the task
  /// tool's model field. The user's own routing table: a gateway with no manifest can't
  /// fuzzy-match "haiku", and an alias beats a guessed slug every time.
  public var aliases: [String: String]?
  /// Optional cheap/fast model (id or alias) that gives a second opinion on shell commands
  /// already headed for a permission prompt — a `CommandJudge`. Escalate-only: it can flag a
  /// command (enriching the prompt, or vetoing a headless `--yes` run) but never approve one
  /// the deterministic layers blocked. Off unless set. A free/cheap model is the point.
  public var bashJudge: String?
  /// Which upstream providers may serve this model (OpenRouter only; other kinds ignore it).
  ///
  /// A model id names a *model*, not a machine: OpenRouter picks an upstream provider per
  /// request, and the same slug can be served by several with different latency, price and
  /// — observed on 2026-09-10 — different output quality, one of them returning content
  /// unrelated to the request. For a benchmark or any reproducible comparison that is an
  /// uncontrolled variable larger than most of the things being measured, so pin it.
  public var providerRouting: ProviderRouting?
  /// Opt-in OS confinement for the `bash` tool. Off unless set. See `SandboxConfig`.
  public var sandbox: SandboxConfig?
  /// Defaults for delegated work — the subagent model, step/dollar caps. See `SubagentsConfig`.
  public var subagents: SubagentsConfig?
  /// Whether `DialectOverride.auto` may pick `/messages` or `/responses` for models
  /// whose family prefers them. Default: on for OpenRouter and LiteLLM (both serve the
  /// native endpoints; the conformance store pins a model to chat if one misbehaves),
  /// off for plain OpenAI-compatible endpoints.
  public var nativeDialects: Bool?
  /// Allow `http://` to a non-loopback host. Off by default: the bearer token rides
  /// every request.
  public var insecure: Bool?
  /// How a chat-completions request spells the reasoning dial (`--effort`), overriding the
  /// kind's default (`ReasoningShape.forKind`): `"openrouter"` — OpenRouter's `reasoning:
  /// {effort}` object; `"openai"` — OpenAI's top-level `reasoning_effort` string, what LiteLLM
  /// and OpenAI-compatible servers accept; `"none"` — the endpoint takes neither, so no chat
  /// request carries the dial (the native dialects are unaffected). The escape hatch for a
  /// gateway that speaks the other spelling, or rejects both. Decoded with `decodeIfPresent`:
  /// an old config decodes unchanged.
  public var reasoningShape: ReasoningShape?

  public init(
    kind: ProviderKind,
    baseURL: String,
    apiKeyEnv: String? = nil,
    apiKey: String? = nil,
    apiKeyCommand: String? = nil,
    headers: [String: String]? = nil,
    headersEnv: String? = nil,
    defaultModel: String? = nil,
    aliases: [String: String]? = nil,
    bashJudge: String? = nil,
    sandbox: SandboxConfig? = nil,
    subagents: SubagentsConfig? = nil,
    nativeDialects: Bool? = nil,
    insecure: Bool? = nil,
    reasoningShape: ReasoningShape? = nil,
    providerRouting: ProviderRouting? = nil)
  {
    self.kind = kind
    self.baseURL = baseURL
    self.apiKeyEnv = apiKeyEnv
    self.apiKey = apiKey
    self.apiKeyCommand = apiKeyCommand
    self.headers = headers
    self.headersEnv = headersEnv
    self.defaultModel = defaultModel
    self.aliases = aliases
    self.bashJudge = bashJudge
    self.sandbox = sandbox
    self.subagents = subagents
    self.nativeDialects = nativeDialects
    self.insecure = insecure
    self.reasoningShape = reasoningShape
    self.providerRouting = providerRouting
  }

  /// The built-in default — what every arnes install talked to before providers existed.
  public static let openrouter = ProviderConfig(
    kind: .openrouter,
    baseURL: "https://openrouter.ai/api/v1",
    defaultModel: "openrouter/auto")
}

// MARK: - InstructionsConfig

/// Top-level `instructions` block in `~/.arnes/config.json`: which files count as project
/// instructions and how much of them may load.
///
/// ```json
/// {
///   "instructions": {
///     "fallbackFilenames": ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"],
///     "localFilenames": ["AGENTS.local.md", "CLAUDE.local.md"],
///     "maxBytes": 32768,
///     "imports": true,
///     "rootMarkers": [".git"]
///   }
/// }
/// ```
/// Every field is optional and falls back to the built-in default, so a partial block only
/// changes what it names. See `ProjectInstructions.Options`.
public struct InstructionsConfig: Codable, Sendable, Equatable {
  /// Per directory, in order — the first that exists is that directory's primary file.
  public var fallbackFilenames: [String]?
  /// Per directory, additive — every one that exists is rendered after the primary file.
  public var localFilenames: [String]?
  /// Total budget for all instruction text, imported bytes included.
  public var maxBytes: Int?
  /// Expand `@path` imports.
  public var imports: Bool?
  /// Names that mark a repository root when walking up from the working directory.
  public var rootMarkers: [String]?

  public init(
    fallbackFilenames: [String]? = nil,
    localFilenames: [String]? = nil,
    maxBytes: Int? = nil,
    imports: Bool? = nil,
    rootMarkers: [String]? = nil)
  {
    self.fallbackFilenames = fallbackFilenames
    self.localFilenames = localFilenames
    self.maxBytes = maxBytes
    self.imports = imports
    self.rootMarkers = rootMarkers
  }
}

// MARK: - ArnesConfig

/// `~/.arnes/config.json` (or `ARNES_CONFIG`): the active provider name plus the
/// provider table. Absent file means "OpenRouter with `OPENROUTER_API_KEY`", exactly as
/// before.
public struct ArnesConfig: Codable, Sendable, Equatable {
  /// Name of the provider to use when `--provider`/`ARNES_PROVIDER` are unset.
  public var provider: String?
  public var providers: [String: ProviderConfig]?
  /// What subprocesses launched for the agent — `bash` commands and lifecycle hooks —
  /// inherit of the environment. The provider token is withheld no matter what. Router-
  /// agnostic, so it lives at the top level rather than per-provider. See
  /// `ShellEnvironmentPolicy`.
  public var shellEnvironment: ShellEnvironmentPolicy?
  /// Which files count as project instructions (`AGENTS.md` and friends) and how much of
  /// them loads. Router-agnostic, so it sits at the top level. See `InstructionsConfig`.
  public var instructions: InstructionsConfig?
  /// Extra protected / sensitive-write / deny-read globs merged with the built-in path
  /// classification. Additive only. Router-agnostic, so it sits at the top level. See
  /// `PathPolicy`.
  public var paths: PathPolicy?
  /// How long saved transcripts stick around. Router-agnostic, so it sits at the top
  /// level. See `SessionsConfig`.
  public var sessions: SessionsConfig?
  /// Harness-wide behavior switches that belong to no provider and no path rule. See
  /// `PoliciesConfig`.
  public var policies: PoliciesConfig?
  /// How much a tool result may say and when a circling model is stopped. Router-agnostic,
  /// so it sits at the top level. See `LimitsConfig`.
  public var limits: LimitsConfig?
  /// File checkpoints for the REPL's `/rewind`: on/off and how much is kept. Router-agnostic,
  /// so it sits at the top level. See `CheckpointsConfig`.
  public var checkpoints: CheckpointsConfig?
  /// Auto-memory (C3): the model's own notes per project, on/off, where they live and how much
  /// of the index rides the prompt. Router-agnostic, so it sits at the top level. See `MemoryConfig`.
  public var memory: MemoryConfig?
  /// The `web_fetch` tool's reach (T5): the block's presence turns the tool on; its domain lists
  /// and caps bound it. Router-agnostic, so it sits at the top level. See `WebConfig`.
  public var web: WebConfig?
  /// Context budget (C2): when the summarizer runs, how many recent tool results the request view
  /// keeps verbatim, how small a result must be to stay, how many emergency summaries a turn may
  /// take. Router-agnostic, so it sits at the top level. See `CompactionConfig`.
  public var compaction: CompactionConfig?

  public init(
    provider: String? = nil,
    providers: [String: ProviderConfig]? = nil,
    shellEnvironment: ShellEnvironmentPolicy? = nil,
    instructions: InstructionsConfig? = nil,
    paths: PathPolicy? = nil,
    sessions: SessionsConfig? = nil,
    policies: PoliciesConfig? = nil,
    limits: LimitsConfig? = nil,
    checkpoints: CheckpointsConfig? = nil,
    memory: MemoryConfig? = nil,
    web: WebConfig? = nil,
    compaction: CompactionConfig? = nil)
  {
    self.provider = provider
    self.providers = providers
    self.shellEnvironment = shellEnvironment
    self.instructions = instructions
    self.paths = paths
    self.sessions = sessions
    self.policies = policies
    self.limits = limits
    self.checkpoints = checkpoints
    self.memory = memory
    self.web = web
    self.compaction = compaction
  }

  public static var defaultURL: URL {
    if let override = ProcessInfo.processInfo.environment["ARNES_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/config.json")
  }

  /// Loads the config, or nil when the file doesn't exist.
  public static func load(from url: URL = defaultURL) throws -> ArnesConfig? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(ArnesConfig.self, from: Data(contentsOf: url))
  }

  /// Always available, shadowable by a config entry of the same name.
  public static let builtinProviders: [String: ProviderConfig] = ["openrouter": .openrouter]

  /// Config entries layered over the built-ins.
  public var allProviders: [String: ProviderConfig] {
    Self.builtinProviders.merging(providers ?? [:]) { _, configured in configured }
  }
}

// MARK: - SessionsConfig

/// Session retention (`sessions` in `~/.arnes/config.json`).
///
/// Off unless configured: transcripts are the user's history, and a harness that quietly
/// deletes them would be worse than one that keeps too many. When `retentionDays` is set,
/// the CLI sweeps once per process — unnamed sessions older than that are deleted, `/save`d
/// ones are kept, and anything actually removed is reported.
public struct SessionsConfig: Codable, Sendable, Equatable {
  /// Delete unnamed sessions untouched for this many days. Nil (the default) never prunes.
  public var retentionDays: Int?

  public init(retentionDays: Int? = nil) {
    self.retentionDays = retentionDays
  }
}

// MARK: - CheckpointsConfig

/// File checkpoints (`checkpoints` in `~/.arnes/config.json`): before every `write_file`/
/// `edit_file` the REPL keeps the file's pre-image under `~/.arnes/checkpoints/<session>/` so
/// `/rewind` and `/undo` can put the tree back to the start of a turn. On by default; every key
/// is optional and nil means the built-in default, so an absent block changes nothing.
/// Headless runs (`arnes do`, evals, panels) never checkpoint whatever this says.
///
/// ```json
/// { "checkpoints": { "enabled": true, "maxFileBytes": 5000000, "maxTurns": 100 } }
/// ```
public struct CheckpointsConfig: Codable, Sendable, Equatable {
  /// nil = on. `false` keeps no pre-images (`/rewind` then moves only the conversation).
  public var enabled: Bool?
  /// Files larger than this are recorded but not saved — a rewind names them as skipped.
  /// nil = `CheckpointPolicy.default.maxFileBytes` (5 MB).
  public var maxFileBytes: Int?
  /// How many turns' checkpoints are kept; the oldest go as new ones arrive. nil = 100.
  public var maxTurns: Int?

  public init(enabled: Bool? = nil, maxFileBytes: Int? = nil, maxTurns: Int? = nil) {
    self.enabled = enabled
    self.maxFileBytes = maxFileBytes
    self.maxTurns = maxTurns
  }

  public var isEnabled: Bool { enabled ?? true }

  /// The store policy this block configures (defaults filled in).
  public var policy: CheckpointPolicy {
    CheckpointPolicy(
      maxFileBytes: maxFileBytes ?? CheckpointPolicy.default.maxFileBytes,
      maxTurns: maxTurns ?? CheckpointPolicy.default.maxTurns)
  }
}

// MARK: - MemoryConfig

/// Auto-memory (`memory` in `~/.arnes/config.json`, C3): the model's own notes per project,
/// kept under `<directory>/<project key>/MEMORY.md` and loaded into the system prompt as one
/// `# Memory` section. On by default; every key is optional and nil means the built-in default,
/// so an absent block changes nothing. `--no-memory` on `interactive`/`do` (and `--bare`) switch
/// it off for one run; `ARNES_MEMORY_DIR` overrides `directory` for one process.
///
/// ```json
/// { "memory": { "enabled": true, "directory": "~/.arnes/memory", "maxLines": 200, "maxBytes": 25600 } }
/// ```
public struct MemoryConfig: Codable, Sendable, Equatable {
  /// nil = on. `false` loads no section and opens no carve-out — the directory is then harness
  /// state like the rest of `~/.arnes`.
  public var enabled: Bool?
  /// The memory root (`~` allowed); nil = `~/.arnes/memory`. Each project gets a directory
  /// under it, so the root itself is never the carve-out.
  public var directory: String?
  /// How many lines of `MEMORY.md` ride the prompt; nil = `MemoryStore.defaultMaxLines` (200).
  public var maxLines: Int?
  /// How many bytes of `MEMORY.md` ride the prompt; nil = `MemoryStore.defaultMaxBytes` (25 600).
  public var maxBytes: Int?

  public init(enabled: Bool? = nil, directory: String? = nil, maxLines: Int? = nil, maxBytes: Int? = nil) {
    self.enabled = enabled
    self.directory = directory
    self.maxLines = maxLines
    self.maxBytes = maxBytes
  }

  public var isEnabled: Bool { enabled ?? true }
  public var effectiveMaxLines: Int { maxLines ?? MemoryStore.defaultMaxLines }
  public var effectiveMaxBytes: Int { maxBytes ?? MemoryStore.defaultMaxBytes }
}

// MARK: - WebConfig

/// Top-level `web` block in `~/.arnes/config.json` (T5): the `web_fetch` tool's reach. **The
/// block's presence is the opt-in** — without it no run has the tool; with it, every key is
/// optional and there is **no default allowlist**: a host in `allowedDomains` is fetched freely,
/// one in `deniedDomains` never, anything else is a `.sensitive` call (loud prompt, refused
/// unattended). Router-agnostic, so it sits at the top level. See `WebFetchPolicy`.
///
/// ```json
/// {
///   "web": {
///     "allowedDomains": ["docs.swift.org", "developer.apple.com"],
///     "deniedDomains": ["pastebin.com"],
///     "maxBytes": 200000,
///     "timeoutSeconds": 30
///   }
/// }
/// ```
public struct WebConfig: Codable, Sendable, Equatable {
  /// Hosts (or parent domains) fetched without a prompt.
  public var allowedDomains: [String]?
  /// Hosts (or parent domains) never fetched — a floor no approval lifts.
  public var deniedDomains: [String]?
  /// Bytes of a response read before the fetch stops; nil = `WebFetchPolicy.defaultMaxBytes` (200 000).
  public var maxBytes: Int?
  /// Per-request timeout; nil = `WebFetchPolicy.defaultTimeoutSeconds` (30).
  public var timeoutSeconds: Int?

  public init(
    allowedDomains: [String]? = nil,
    deniedDomains: [String]? = nil,
    maxBytes: Int? = nil,
    timeoutSeconds: Int? = nil)
  {
    self.allowedDomains = allowedDomains
    self.deniedDomains = deniedDomains
    self.maxBytes = maxBytes
    self.timeoutSeconds = timeoutSeconds
  }

  /// The policy the tool runs under: every absent key at its default.
  public var policy: WebFetchPolicy {
    WebFetchPolicy(
      allowedDomains: allowedDomains ?? [],
      deniedDomains: deniedDomains ?? [],
      maxBytes: maxBytes ?? WebFetchPolicy.defaultMaxBytes,
      timeoutSeconds: timeoutSeconds ?? WebFetchPolicy.defaultTimeoutSeconds)
  }
}

// MARK: - CompactionConfig

/// Context budget (`compaction` in `~/.arnes/config.json`, C2): the numbers of `CompactionPolicy`.
/// Every key is optional and nil means the built-in default, so an absent block changes nothing.
/// `keepRecentToolResults: 0` keeps no result verbatim — every large result in the history when
/// the cutoff last moved (a turn start, a mid-turn relief point) is cleared; results appended
/// after that point stay whole until the next move —, `clearMinChars: 0` clears results whatever
/// their size, `maxPerTurn: 0` takes no emergency summaries (the warning is said instead).
///
/// ```json
/// { "compaction": { "threshold": 0.8, "keepRecentToolResults": 6, "clearMinChars": 2000, "maxPerTurn": 2 } }
/// ```
public struct CompactionConfig: Codable, Sendable, Equatable {
  /// Optional estimated-token budget for recent tool results, replacing the fixed count.
  /// Synthesized optional Codable fields use decodeIfPresent for older configurations.
  public var keepRecentToolTokens: Int?
  /// Optional command-evidence appendix during compaction. nil = off.
  public var preserveCommandEvidence: Bool?
  /// Fraction of the context window at which a turn start summarizes (when clearing alone won't
  /// do) and a step clears mid-turn. nil = 0.8; a value outside (0, 1] reads as the default.
  public var threshold: Double?
  /// Tool results kept verbatim in the request view, the most recent ones. nil = 6.
  public var keepRecentToolResults: Int?
  /// A result shorter than this many characters is never cleared. nil = 2000.
  public var clearMinChars: Int?
  /// Emergency summaries one turn may take when the window is estimated to stay at 95 % after
  /// clearing (a failed attempt counts). nil = 2.
  public var maxPerTurn: Int?
  /// Image attachments kept in the request view among those older than the kept tool results
  /// (the most recent ones); older pictures become their caption plus a recall hint. nil = 1;
  /// 0 = every old image is stubbed.
  public var keepRecentImages: Int?

  public init(
    threshold: Double? = nil, keepRecentToolResults: Int? = nil, clearMinChars: Int? = nil,
    maxPerTurn: Int? = nil, keepRecentImages: Int? = nil, keepRecentToolTokens: Int? = nil,
    preserveCommandEvidence: Bool? = nil)
  {
    self.threshold = threshold
    self.keepRecentToolResults = keepRecentToolResults
    self.clearMinChars = clearMinChars
    self.maxPerTurn = maxPerTurn
    self.keepRecentImages = keepRecentImages
    self.keepRecentToolTokens = keepRecentToolTokens
    self.preserveCommandEvidence = preserveCommandEvidence
  }

  /// The configured values over the defaults (`CompactionPolicy.init` clamps them).
  public var policy: CompactionPolicy {
    CompactionPolicy(
      threshold: threshold ?? CompactionPolicy.defaultThreshold,
      keepRecentToolResults: keepRecentToolResults ?? CompactionPolicy.defaultKeepRecentToolResults,
      clearMinChars: clearMinChars ?? CompactionPolicy.defaultClearMinChars,
      maxPerTurn: maxPerTurn ?? CompactionPolicy.defaultMaxPerTurn,
      keepRecentImages: keepRecentImages ?? CompactionPolicy.defaultKeepRecentImages,
      keepRecentToolTokens: keepRecentToolTokens,
      preserveCommandEvidence: preserveCommandEvidence ?? false)
  }
}

// MARK: - PoliciesConfig

/// Harness-wide behavior switches (`policies` in `~/.arnes/config.json`): what the harness
/// does around the model that is neither a provider's business nor a path rule. Every key is
/// optional and nil means the built-in default, so an absent block changes nothing.
///
/// ```json
/// { "policies": { "environmentContext": false } }
/// ```
public struct PoliciesConfig: Codable, Sendable, Equatable {
  /// Append bounded extracted compiler/test diagnostics to bash results. nil = off.
  public var commandDiagnostics: Bool?
  /// Whether the `# Environment` section (working directory, platform, date, git snapshot,
  /// run posture) rides the system prompt. nil = on. See `EnvironmentContext`.
  public var environmentContext: Bool?
  /// How many bytes of skill descriptions the `# Skills` listing may carry before the rest
  /// are listed by name only. nil = `SkillTool.defaultListingMaxBytes`; 0 = names only.
  public var skillListingBytes: Int?
  /// Whether tool results enter history wrapped in `<tool_result source=… nonce=…>` tags
  /// (`ToolResultGuardPolicy.framing`). nil = on. The scanner, redaction and taint are not
  /// switches here — they are the harness's, on in every run.
  public var toolResultFraming: Bool?
  /// How model requests survive a flaky wire — retries and the stream idle timeout
  /// (`TransportPolicyConfig` → `TransportPolicy`). nil = the built-in numbers.
  public var transport: TransportPolicyConfig?
  /// Prompt-cache breakpoints on Anthropic-family requests and their TTL
  /// (`PromptCacheConfig` → `CachePolicy`). nil = breakpoints on, the provider's TTL.
  public var promptCache: PromptCacheConfig?
  /// Whether the fetched model manifest is kept between processes and for how long it is
  /// served without a fetch (`ManifestCacheConfig` → `ManifestCachePolicy`). nil = on, 24 hours.
  public var manifestCache: ManifestCacheConfig?
  /// Whether a model that reasons natively is offered the `think` scratchpad
  /// (`Session.Configuration.adaptiveThink`, T5): when true, a model whose manifest advertises
  /// reasoning **and** whose run has a reasoning dial set (`--effort`, not `none`) is not
  /// offered the tool — its own reasoning is one; `/effort off` brings it back on the next
  /// request. A text model, or a run without the dial, is offered it either way. nil = false =
  /// every model is offered the tool — **the default until the eval A/B says otherwise**
  /// (invariant 6; the recipe is `evals/ab/README.md`, the arm `arnes eval --adaptive-think`).
  public var adaptiveThink: Bool?
  /// The loop-2 trigger's default (P2): when a headless `arnes do --verify <model> --yes` run's
  /// verifier says FAIL, re-run the task as a panel of this many candidates over a snapshot of the
  /// working tree taken before the run, apply the judged winner and re-verify it — what
  /// `arnes do --panel-on-fail N` does per run. nil or 0 = off; a value under 2 is off too (a
  /// panel needs two candidates). The flag outranks the key, and `--panel-on-fail 0` switches a
  /// configured default off for one run. Never arms a run without both `--verify` and `--yes`,
  /// nor a `--output-format json|stream-json` run (its envelope has no room for an escalation).
  public var panelOnVerifierFail: Int?

  public init(
    environmentContext: Bool? = nil,
    skillListingBytes: Int? = nil,
    toolResultFraming: Bool? = nil,
    transport: TransportPolicyConfig? = nil,
    promptCache: PromptCacheConfig? = nil,
    manifestCache: ManifestCacheConfig? = nil,
    adaptiveThink: Bool? = nil,
    panelOnVerifierFail: Int? = nil,
    commandDiagnostics: Bool? = nil)
  {
    self.environmentContext = environmentContext
    self.skillListingBytes = skillListingBytes
    self.toolResultFraming = toolResultFraming
    self.transport = transport
    self.promptCache = promptCache
    self.manifestCache = manifestCache
    self.adaptiveThink = adaptiveThink
    self.panelOnVerifierFail = panelOnVerifierFail
    self.commandDiagnostics = commandDiagnostics
  }
}

// MARK: - PromptCacheConfig

/// `policies.promptCache` in `~/.arnes/config.json`: the prompt-cache discipline of
/// `CachePolicy`. Every key is optional and nil means the built-in default, so an absent block
/// changes nothing.
///
/// ```json
/// { "policies": { "promptCache": { "anthropicBreakpoints": true, "ttl": "5m" } } }
/// ```
public struct PromptCacheConfig: Codable, Sendable, Equatable {
  /// Whether Anthropic-family requests mark their stable prefix with `cache_control`
  /// breakpoints (only where the provider supports the field). nil = on.
  public var anthropicBreakpoints: Bool?
  /// The cache entries' time to live (`"5m"`, `"1h"`) where the provider supports one. nil =
  /// the provider's default.
  public var ttl: String?

  public init(anthropicBreakpoints: Bool? = nil, ttl: String? = nil) {
    self.anthropicBreakpoints = anthropicBreakpoints
    self.ttl = ttl
  }

  /// The configured values over the defaults.
  public var policy: CachePolicy {
    CachePolicy(anthropicBreakpoints: anthropicBreakpoints ?? true, ttl: ttl)
  }
}

// MARK: - TransportPolicyConfig

/// `policies.transport` in `~/.arnes/config.json`: the retry and idle-timeout numbers of
/// `TransportPolicy`. Every key is optional and nil means the built-in default, so an absent
/// block changes nothing; `0` switches a retry budget or the idle timeout off.
///
/// ```json
/// { "policies": { "transport": { "maxRequestRetries": 4, "maxStreamRetries": 5, "streamIdleTimeoutMs": 300000 } } }
/// ```
public struct TransportPolicyConfig: Codable, Sendable, Equatable {
  /// Retries of a request refused before its stream opened (429/5xx, 524, 529, a connection
  /// failure). nil = 4.
  public var maxRequestRetries: Int?
  /// Retries of a stream that broke or went idle before any output token. nil = 5.
  public var maxStreamRetries: Int?
  /// Milliseconds of silence after which a stream is cancelled and retried. nil = 300000 (5 min).
  public var streamIdleTimeoutMs: Int?

  public init(maxRequestRetries: Int? = nil, maxStreamRetries: Int? = nil, streamIdleTimeoutMs: Int? = nil) {
    self.maxRequestRetries = maxRequestRetries
    self.maxStreamRetries = maxStreamRetries
    self.streamIdleTimeoutMs = streamIdleTimeoutMs
  }

  /// The configured values over the defaults (the wait cap, the sleeper and the jitter source
  /// are the policy's own).
  public var policy: TransportPolicy {
    TransportPolicy(
      maxRequestRetries: maxRequestRetries ?? TransportPolicy.defaultMaxRequestRetries,
      maxStreamRetries: maxStreamRetries ?? TransportPolicy.defaultMaxStreamRetries,
      streamIdleTimeoutMs: streamIdleTimeoutMs ?? TransportPolicy.defaultStreamIdleTimeoutMs)
  }
}

// MARK: - ManifestCacheConfig

/// `policies.manifestCache` in `~/.arnes/config.json`: whether the model manifest fetched from
/// the provider is kept under `~/.arnes/models/<provider>.json` and served from there without a
/// fetch while it is younger than `ttlHours`. Every key is optional: absent = on, 24 hours;
/// `enabled: false` fetches on every process exactly as before the cache existed. An id the
/// cached copy doesn't know still costs one fetch, and `arnes models --refresh` forces one.
public struct ManifestCacheConfig: Codable, Sendable, Equatable {
  /// nil = on.
  public var enabled: Bool?
  /// Hours a cached manifest is served without a fetch. nil = 24; 0 = always refetch (but keep
  /// the copy as the fallback for a failed fetch).
  public var ttlHours: Double?

  public init(enabled: Bool? = nil, ttlHours: Double? = nil) {
    self.enabled = enabled
    self.ttlHours = ttlHours
  }

  public var isEnabled: Bool { enabled ?? true }

  /// The policy this block configures; nil when the cache is switched off.
  public var policy: ManifestCachePolicy? {
    guard isEnabled else { return nil }
    let hours = ttlHours ?? ManifestCachePolicy.defaultTTL / 3600
    return ManifestCachePolicy(ttl: hours * 3600)
  }
}

// MARK: - LimitsConfig

/// Tool-loop hygiene knobs (`limits` in `~/.arnes/config.json`): how much of a tool result the
/// model reads, how much output `bash` keeps, how long a `bash` command may run, and when a
/// turn going in circles is stopped. Every key is optional and nil means the built-in default,
/// so an absent block changes nothing.
///
/// ```json
/// {
///   "limits": {
///     "toolResultChars": 30000,
///     "bashOutputChars": 20000,
///     "bashTimeoutSeconds": 300,
///     "loopGuard": { "maxConsecutiveErrors": 6, "maxIdenticalCalls": 6, "maxEditsPerFile": 8, "nudgeAt": 3 }
///   }
/// }
/// ```
public struct LimitsConfig: Codable, Sendable, Equatable {
  /// `LoopGuardPolicy` as configured: each threshold optional, `0` switches that check off.
  public struct LoopGuard: Codable, Sendable, Equatable {
    public var maxConsecutiveErrors: Int?
    public var maxIdenticalCalls: Int?
    public var maxEditsPerFile: Int?
    public var nudgeAt: Int?

    public init(
      maxConsecutiveErrors: Int? = nil,
      maxIdenticalCalls: Int? = nil,
      maxEditsPerFile: Int? = nil,
      nudgeAt: Int? = nil)
    {
      self.maxConsecutiveErrors = maxConsecutiveErrors
      self.maxIdenticalCalls = maxIdenticalCalls
      self.maxEditsPerFile = maxEditsPerFile
      self.nudgeAt = nudgeAt
    }

    /// The configured values over the defaults.
    public var policy: LoopGuardPolicy {
      let defaults = LoopGuardPolicy.default
      return LoopGuardPolicy(
        maxConsecutiveErrors: max(0, maxConsecutiveErrors ?? defaults.maxConsecutiveErrors),
        maxIdenticalCalls: max(0, maxIdenticalCalls ?? defaults.maxIdenticalCalls),
        maxEditsPerFile: max(0, maxEditsPerFile ?? defaults.maxEditsPerFile),
        nudgeAt: max(0, nudgeAt ?? defaults.nudgeAt))
    }
  }

  /// Characters of any one tool result the model reads (head + tail; the rest spilled to
  /// `~/.arnes/tmp/<session>/`). nil = 30000. See `ToolOutputLimiter`.
  public var toolResultChars: Int?
  /// The output size `bash` is built for; the runner keeps 2× this of head and of tail in
  /// memory. nil = 20000. See `BashTool.defaultOutputChars`.
  public var bashOutputChars: Int?
  public var loopGuard: LoopGuard?
  /// Seconds a `bash` command may run when the call names no `timeout_seconds`; nil = 300,
  /// clamped to `1...BashTool.maxTimeoutSeconds` (600) — longer work is a background job.
  public var bashTimeoutSeconds: Int?

  public init(
    toolResultChars: Int? = nil, bashOutputChars: Int? = nil, loopGuard: LoopGuard? = nil,
    bashTimeoutSeconds: Int? = nil)
  {
    self.toolResultChars = toolResultChars
    self.bashOutputChars = bashOutputChars
    self.loopGuard = loopGuard
    self.bashTimeoutSeconds = bashTimeoutSeconds
  }

  /// The effective values: configured over built-in defaults.
  public var effectiveToolResultChars: Int {
    max(ToolOutputLimiter.minimumMaxChars, toolResultChars ?? ToolOutputLimiter.defaultMaxChars)
  }

  public var effectiveBashOutputChars: Int {
    max(1_000, bashOutputChars ?? BashTool.defaultOutputChars)
  }

  public var effectiveBashTimeoutSeconds: Int {
    BashTool.clampedTimeout(bashTimeoutSeconds ?? BashTool.defaultTimeoutSeconds)
  }

  public var effectiveLoopGuard: LoopGuardPolicy {
    loopGuard?.policy ?? .default
  }

  /// What an absent block means.
  public static let `default` = LimitsConfig()
}

// MARK: - ProviderTraits

/// How a chat-completions request spells the reasoning dial (`Session.reasoningEffort`,
/// `--effort`). The two routers disagree, and a gateway refuses the spelling it doesn't know:
/// a LiteLLM proxy (OpenAI-compatible chat completions in front of Bedrock/Anthropic) answers
/// OpenRouter's object with `400 reasoning: Extra inputs are not permitted`, while OpenRouter
/// documents the object. The `/messages` and `/responses` paths are their own APIs' shapes
/// (`thinking`, `reasoning`) and never consult this. The level rides verbatim in either
/// spelling (`Reasoning.Effort.rawValue`: `minimal|low|medium|high|xhigh|max|none`) — never
/// remapped; a level the gateway rejects is the gateway's message to the user, not ours to guess.
public enum ReasoningShape: String, Codable, Sendable {
  /// OpenRouter's `reasoning: {effort}` object (the one that also carries `summary`/`exclude`).
  case openrouter
  /// OpenAI's chat-completions `reasoning_effort: "<level>"` string — what LiteLLM (which
  /// translates it, for Anthropic into a `thinking` budget) and OpenAI-compatible servers accept.
  case openai
  /// The endpoint takes neither; the dial is applied to no chat request (native dialects
  /// unaffected). Spell it `ReasoningShape.none` wherever the context is an optional
  /// (`ProviderConfig.reasoningShape`, `ProviderTraits.forKind(reasoningShape:)`): a bare `.none`
  /// there is `Optional.none` — no override — not this case (the `Reasoning.Effort.none` pitfall).
  case none

  /// The spelling a provider kind speaks unless its config entry says otherwise
  /// (`ProviderConfig.reasoningShape`): OpenRouter its own object, LiteLLM and a plain
  /// OpenAI-compatible endpoint OpenAI's string.
  public static func forKind(_ kind: ProviderKind) -> ReasoningShape {
    switch kind {
    case .openrouter: return .openrouter
    case .litellm, .openaiCompatible: return .openai
    }
  }
}

/// What the agent loop needs to know about the provider it is talking to — the
/// request-shaping differences between routers, with the name and default model along
/// for the ride. `Session` reads these; the CLI builds them from a `ResolvedProvider`.
/// Upstream-provider pinning for OpenRouter (`provider` on the request body).
///
/// `only` is the strict form — serve from these or fail — and is what a reproducible run
/// wants. `order` prefers without excluding, `ignore` excludes. `allowFallbacks: false`
/// turns a preference into a requirement: without it OpenRouter may still fall back to a
/// provider outside the list, which silently reintroduces exactly the variable being pinned.
public struct ProviderRouting: Codable, Sendable, Equatable {
  /// Serve only from these upstream providers (`Together`, `Fireworks`, …), else fail.
  public var only: [String]?
  /// Preferred order; providers outside it may still serve unless `allowFallbacks` is false.
  public var order: [String]?
  /// Never serve from these.
  public var ignore: [String]?
  /// Whether OpenRouter may fall back outside `only`/`order`. Defaults to false here — a
  /// pin that silently unpins itself is worse than no pin, because the run still looks pinned.
  public var allowFallbacks: Bool?

  public init(
    only: [String]? = nil, order: [String]? = nil, ignore: [String]? = nil,
    allowFallbacks: Bool? = nil)
  {
    self.only = only
    self.order = order
    self.ignore = ignore
    self.allowFallbacks = allowFallbacks
  }

  /// Nothing to send when no field is set — an unpinned request stays byte-identical.
  public var isEmpty: Bool {
    (only?.isEmpty ?? true) && (order?.isEmpty ?? true) && (ignore?.isEmpty ?? true)
      && allowFallbacks == nil
  }

  /// The wire shape, or nil when nothing is pinned.
  public var preferences: ProviderPreferences? {
    guard !isEmpty else { return nil }
    var wire = ProviderPreferences()
    wire.only = only?.nilIfEmpty
    wire.order = order?.nilIfEmpty
    wire.ignore = ignore?.nilIfEmpty
    // A stated pin defaults to strict; an explicit `true` still opts back into fallbacks.
    wire.allowFallbacks = allowFallbacks ?? false
    return wire
  }
}

extension Array {
  fileprivate var nilIfEmpty: [Element]? { isEmpty ? nil : self }
}

public struct ProviderTraits: Sendable, Equatable {
  public enum FallbackStyle: Sendable, Equatable {
    /// OpenRouter's `models` array: tried in order when the primary fails.
    case models
    /// LiteLLM's per-request `fallbacks` list (same semantics, different key).
    case litellmFallbacks
    /// The endpoint has no request-level fallbacks; the list is dropped.
    case unsupported
  }

  public var name: String
  /// Model for anything the user didn't name: the session when `-m` is omitted,
  /// compaction summaries, verification, inherited subagents.
  public var defaultModel: String
  public var fallbackStyle: FallbackStyle
  /// Send `stream_options.include_usage` so the final chunk carries token counts
  /// (OpenRouter always includes usage; OpenAI-compatible servers need asking).
  public var requestsStreamUsage: Bool
  /// When a response carries no `usage.cost`, estimate it from token counts and the
  /// manifest's per-token prices (0 when the manifest has no prices).
  public var estimatesCost: Bool
  /// Whether `.auto` may choose `/messages` or `/responses`.
  public var nativeDialects: Bool
  /// Whether a chat-completions request may carry `reasoning_details` on its assistant
  /// messages. OpenRouter documents passing a response's entries back so a thinking model keeps
  /// its signed/encrypted reasoning across a tool loop; a generic gateway may reject the unknown
  /// message field, so every other kind sends history with the entries stripped (the session's
  /// own history keeps them).
  public var replaysReasoningDetails: Bool
  /// Whether a request may carry Anthropic-style `cache_control` breakpoints (on a system
  /// content part and the last message of a chat request, on the last tool definition and the
  /// last content block of a `/messages` request). OpenRouter documents the field and LiteLLM
  /// forwards it to Anthropic; a generic OpenAI-compatible endpoint may reject it, so the
  /// session marks nothing there whatever the model's family (`CachePolicy`).
  public var supportsCacheControl: Bool
  /// How a chat-completions request carries the reasoning dial: OpenRouter's `reasoning`
  /// object, OpenAI's top-level `reasoning_effort` string (LiteLLM, OpenAI-compatible), or
  /// neither. `Session.chatReasoning`/`chatReasoningEffort` read it; the native dialects never
  /// do. The memberwise default is OpenRouter's — every traits value built before the field
  /// existed sends the request it always sent.
  public var reasoningShape: ReasoningShape
  /// Default chat output-limit spelling when a manifest is silent. Independent of the
  /// reasoning dial: disabling reasoning must not change which request field is accepted.
  public var prefersMaxCompletionTokens: Bool
  /// Upstream providers this run may use (`ProviderConfig.providerRouting`). nil on every
  /// non-OpenRouter kind and on any run that pinned nothing, so an unpinned request body is
  /// byte-identical to before this existed. `preferences` is its wire shape.
  public var providerRouting: ProviderRouting?

  /// A manifest's explicit spelling wins. Sparse OpenAI-style endpoints use
  /// `max_completion_tokens`; OpenRouter and other chat requests use `max_tokens`.
  func chatOutputLimit(_ limit: Int?, profile: ModelProfile) -> (tokens: Int?, completionTokens: Int?) {
    let completion = profile.supportsMaxCompletionTokens ?? prefersMaxCompletionTokens
    return completion ? (nil, limit) : (limit, nil)
  }

  public init(
    name: String,
    defaultModel: String,
    fallbackStyle: FallbackStyle,
    requestsStreamUsage: Bool,
    estimatesCost: Bool,
    nativeDialects: Bool,
    replaysReasoningDetails: Bool = false,
    supportsCacheControl: Bool = false,
    reasoningShape: ReasoningShape = .openrouter,
    prefersMaxCompletionTokens: Bool = false)
  {
    self.name = name
    self.defaultModel = defaultModel
    self.fallbackStyle = fallbackStyle
    self.requestsStreamUsage = requestsStreamUsage
    self.estimatesCost = estimatesCost
    self.nativeDialects = nativeDialects
    self.replaysReasoningDetails = replaysReasoningDetails
    self.supportsCacheControl = supportsCacheControl
    self.reasoningShape = reasoningShape
    self.prefersMaxCompletionTokens = prefersMaxCompletionTokens
  }

  /// openrouter.ai as it has always been driven.
  public static let openrouter = ProviderTraits(
    name: "openrouter",
    defaultModel: "openrouter/auto",
    fallbackStyle: .models,
    requestsStreamUsage: false,
    estimatesCost: false,
    nativeDialects: true,
    replaysReasoningDetails: true,
    supportsCacheControl: true,
    reasoningShape: .openrouter)

  /// Traits for a kind, named and defaulted by the resolved provider. `reasoningShape` is the
  /// config entry's override; nil = the kind's own spelling (`ReasoningShape.forKind`).
  public static func forKind(
    _ kind: ProviderKind, name: String, defaultModel: String, nativeDialects: Bool,
    reasoningShape: ReasoningShape? = nil) -> ProviderTraits
  {
    let shape = reasoningShape ?? ReasoningShape.forKind(kind)
    switch kind {
    case .openrouter:
      return ProviderTraits(
        name: name, defaultModel: defaultModel, fallbackStyle: .models,
        requestsStreamUsage: false, estimatesCost: false, nativeDialects: nativeDialects,
        replaysReasoningDetails: true, supportsCacheControl: true, reasoningShape: shape)
    case .litellm:
      return ProviderTraits(
        name: name, defaultModel: defaultModel, fallbackStyle: .litellmFallbacks,
        requestsStreamUsage: true, estimatesCost: true, nativeDialects: nativeDialects,
        supportsCacheControl: true, reasoningShape: shape, prefersMaxCompletionTokens: true)
    case .openaiCompatible:
      return ProviderTraits(
        name: name, defaultModel: defaultModel, fallbackStyle: .unsupported,
        requestsStreamUsage: true, estimatesCost: true, nativeDialects: nativeDialects,
        reasoningShape: shape, prefersMaxCompletionTokens: true)
    }
  }
}

// MARK: - ResolvedProvider

/// A provider entry with every indirection resolved: the token found, headers merged,
/// the base URL validated. Everything the CLI needs to build a service and a catalog.
public struct ResolvedProvider: Sendable {
  public let name: String
  public let kind: ProviderKind
  /// API root, version segment included, no trailing slash.
  public let baseURL: URL
  /// The static token; empty when `apiKeyCommand` supplies it per request instead.
  public let apiKey: String
  /// The command that mints the token, when that is the source (see `ProviderConfig`).
  public let apiKeyCommand: String?
  /// The environment variable the token is (or would be) read from — withheld from MCP
  /// server processes so the token never leaks into third-party code.
  public let apiKeyEnv: String
  /// Where the token came from — `config`, `env NAME`, or the credentials file path —
  /// for `arnes providers`.
  public let apiKeySource: String
  /// Extra headers for every request (`Authorization` is added by the client).
  public let headers: [String: String]
  /// The model used when none is named. Nil for a non-OpenRouter entry that hasn't set
  /// one yet — `arnes providers`/`models`/`status` still work so the user can discover
  /// the gateway's aliases; commands that need a model ask for `-m`.
  /// Already alias-resolved.
  public let defaultModel: String?
  /// Alias → model id, as configured (matched case-insensitively).
  public let aliases: [String: String]
  /// The configured command-safety judge model (id or alias), already alias-resolved; nil
  /// when the provider doesn't opt in. See `ProviderConfig.bashJudge`.
  public let bashJudge: String?
  /// Opt-in `bash` sandbox policy, or nil when the provider doesn't enable it.
  public let sandbox: SandboxConfig?
  /// Defaults for delegated work, with `defaultModel` already alias-resolved; nil when the
  /// provider doesn't configure any.
  public let subagents: SubagentsConfig?
  public let nativeDialects: Bool
  /// The entry's `reasoningShape` override; nil = the kind's default. See `ReasoningShape`.
  public let reasoningShape: ReasoningShape?
  /// Upstream-provider pin, or nil when the entry pins nothing. See `ProviderRouting`.
  public let providerRouting: ProviderRouting?

  /// Traits for the loop. An entry without a default model gets an empty string, which
  /// `Session` reads as "use the session's own model" for compaction and verification.
  public var traits: ProviderTraits {
    var traits = ProviderTraits.forKind(
      kind, name: name, defaultModel: defaultModel ?? "", nativeDialects: nativeDialects,
      reasoningShape: reasoningShape)
    // Only OpenRouter takes a `provider` block; a gateway would reject the unknown key.
    if kind == .openrouter { traits.providerRouting = providerRouting }
    return traits
  }

  /// The model id behind `name` when it is a configured alias; `name` itself otherwise.
  public func resolveAlias(_ name: String) -> String {
    let lowered = name.lowercased()
    return aliases.first { $0.key.lowercased() == lowered }?.value ?? name
  }

  /// Whether requests can go out unchanged — openrouter.ai at its standard root.
  public var isStandardOpenRouter: Bool {
    kind == .openrouter && baseURL.absoluteString == ProviderConfig.openrouter.baseURL
  }

  /// `host[:port]/path`, for banners and listings.
  public var endpointDescription: String {
    var text = baseURL.host ?? baseURL.absoluteString
    if let port = baseURL.port { text += ":\(port)" }
    return text + baseURL.path
  }
}

// MARK: - ProviderError

public enum ProviderError: Error, CustomStringConvertible, Sendable, Equatable {
  case unknownProvider(String, available: [String])
  case invalidBaseURL(String)
  /// `http://` to a non-loopback host without `insecure: true`.
  case insecureBaseURL(String)
  case missingAPIKey(provider: String, env: String, credentialsPath: String)
  case missingDefaultModel(provider: String)
  case invalidHeaderLine(String)
  /// `apiKeyCommand` exited non-zero or printed nothing.
  case tokenCommandFailed(command: String, detail: String)

  public var description: String {
    switch self {
    case .unknownProvider(let name, let available):
      return "unknown provider '\(name)' — configured: \(available.sorted().joined(separator: ", "))"
    case .invalidBaseURL(let url):
      return "invalid baseURL '\(url)' — expected e.g. https://host/v1"
    case .insecureBaseURL(let url):
      return "refusing to send the API key over plain http to \(url) — use https, or set \"insecure\": true for a trusted network"
    case .missingAPIKey(let provider, let env, let path):
      return "no API key for provider '\(provider)' — set \(env) in the environment, add a line `\(env)=...` to \(path), or set \"apiKeyCommand\" to a command that prints one"
    case .tokenCommandFailed(let command, let detail):
      return "token command `\(command)` failed: \(detail.isEmpty ? "no output" : detail)"
    case .missingDefaultModel(let provider):
      return "provider '\(provider)' has no defaultModel — pass -m <model> (list them with `arnes models --provider \(provider)`) or add \"defaultModel\" to its config entry"
    case .invalidHeaderLine(let line):
      return "invalid header line '\(line)' — expected `Name: value`"
    }
  }
}

// MARK: - ProviderResolver

/// Turns config + environment + credentials file into a `ResolvedProvider`.
///
/// Which provider: `requested` (the `--provider` flag) > `ARNES_PROVIDER` > the
/// config's `provider` > `openrouter`. Then, for the chosen entry, the environment can
/// override the base URL (`ARNES_BASE_URL`), the token (`ARNES_API_KEY`), and the
/// default model (`ARNES_DEFAULT_MODEL`) — handy for one-off runs against a staging
/// gateway without editing the config.
///
/// The token: the entry's literal `apiKey` > the `apiKeyEnv` variable > a
/// `NAME=value` line for that variable in `~/.arnes/credentials`. For OpenRouter a bare
/// key on its own line in the credentials file still works, as documented since v0.1.
public enum ProviderResolver {
  public static var defaultCredentialsURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/credentials")
  }

  /// The name `resolve` would pick: `requested` > `ARNES_PROVIDER` > the config's
  /// `provider` > `openrouter`.
  public static func activeName(
    requested: String? = nil,
    config: ArnesConfig?,
    environment: [String: String] = ProcessInfo.processInfo.environment)
    -> String
  {
    [requested, environment["ARNES_PROVIDER"], config?.provider]
      .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? "openrouter"
  }

  public static func resolve(
    requested: String? = nil,
    config: ArnesConfig?,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    credentialsURL: URL = defaultCredentialsURL)
    throws -> ResolvedProvider
  {
    let providers = (config ?? ArnesConfig()).allProviders
    let name = activeName(requested: requested, config: config, environment: environment)
    guard let entry = providers[name] else {
      throw ProviderError.unknownProvider(name, available: providers.keys.sorted())
    }
    return try resolve(name: name, entry: entry, environment: environment, credentialsURL: credentialsURL)
  }

  /// Resolves one named entry (also what `arnes providers` calls per row).
  public static func resolve(
    name: String,
    entry: ProviderConfig,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    credentialsURL: URL = defaultCredentialsURL)
    throws -> ResolvedProvider
  {
    let rawBase = nonEmpty(environment["ARNES_BASE_URL"]) ?? entry.baseURL
    let baseURL = try validateBaseURL(rawBase, insecure: entry.insecure ?? false)

    let keyEnv = entry.apiKeyEnv ?? entry.kind.defaultAPIKeyEnv
    let apiKey: String
    let apiKeySource: String
    if let override = nonEmpty(environment["ARNES_API_KEY"]) {
      apiKey = override
      apiKeySource = "env ARNES_API_KEY"
    } else if let literal = nonEmpty(entry.apiKey) {
      apiKey = literal
      apiKeySource = "config"
    } else if let fromEnv = nonEmpty(environment[keyEnv]) {
      apiKey = fromEnv
      apiKeySource = "env \(keyEnv)"
    } else if let fromFile = credential(named: keyEnv, kind: entry.kind, at: credentialsURL) {
      apiKey = fromFile
      apiKeySource = credentialsURL.path
    } else if let command = nonEmpty(entry.apiKeyCommand) {
      // Minted lazily, per request, by `BearerTokenSource` — resolution stays free of
      // side effects (no browser pops during `arnes providers`).
      apiKey = ""
      apiKeySource = "command `\(command)`"
    } else {
      throw ProviderError.missingAPIKey(provider: name, env: keyEnv, credentialsPath: credentialsURL.path)
    }

    var headers = entry.headers ?? [:]
    if let headersEnv = entry.headersEnv, let raw = environment[headersEnv] {
      for (key, value) in try parseHeaderLines(raw) {
        headers[key] = value
      }
    }
    let runId = UUID().uuidString
    headers = headers.mapValues {
      VariableExpansion.expand($0, environment: environment, extra: ["UUID": runId])
    }

    let aliases = (entry.aliases ?? [:]).filter { !$0.key.isEmpty && !$0.value.isEmpty }
    let rawDefault = nonEmpty(environment["ARNES_DEFAULT_MODEL"]) ?? nonEmpty(entry.defaultModel)
    let resolveConfigured: (String) -> String = { raw in
      aliases.first { $0.key.lowercased() == raw.lowercased() }?.value ?? raw
    }
    let defaultModel = rawDefault.map(resolveConfigured)
    let bashJudge = nonEmpty(entry.bashJudge).map(resolveConfigured)
    // A subagent default model is named the same way as any other: an id or an alias.
    var subagents = entry.subagents
    if let configured = nonEmpty(subagents?.defaultModel) {
      subagents?.defaultModel = resolveConfigured(configured)
    }
    let nativeDialects = entry.nativeDialects ?? (entry.kind != .openaiCompatible)

    return ResolvedProvider(
      name: name,
      kind: entry.kind,
      baseURL: baseURL,
      apiKey: apiKey,
      apiKeyCommand: apiKey.isEmpty ? nonEmpty(entry.apiKeyCommand) : nil,
      apiKeyEnv: keyEnv,
      apiKeySource: apiKeySource,
      headers: headers,
      defaultModel: defaultModel,
      aliases: aliases,
      bashJudge: bashJudge,
      sandbox: entry.sandbox,
      subagents: subagents,
      nativeDialects: nativeDialects,
      reasoningShape: entry.reasoningShape,
      providerRouting: entry.providerRouting)
  }

  // MARK: Pieces

  /// https required; http only to loopback hosts unless the entry opts in — the rule
  /// itself lives in `URLPolicy` (shared with the MCP HTTP transport), this only maps its
  /// failures onto the provider's error vocabulary. A trailing slash is dropped so
  /// endpoint paths append cleanly.
  static func validateBaseURL(_ raw: String, insecure: Bool) throws -> URL {
    var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    while trimmed.hasSuffix("/") { trimmed.removeLast() }
    guard let url = URL(string: trimmed) else { throw ProviderError.invalidBaseURL(raw) }
    do {
      try URLPolicy(insecure: insecure).validate(url)
    } catch URLPolicy.Failure.insecureScheme {
      throw ProviderError.insecureBaseURL(trimmed)
    } catch {
      throw ProviderError.invalidBaseURL(raw)
    }
    return url
  }

  /// `Name: value` per line; blank lines skipped.
  static func parseHeaderLines(_ raw: String) throws -> [(String, String)] {
    var pairs: [(String, String)] = []
    for line in raw.split(whereSeparator: \.isNewline) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      guard let colon = trimmed.firstIndex(of: ":") else {
        throw ProviderError.invalidHeaderLine(trimmed)
      }
      let name = trimmed[..<colon].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, name.unicodeScalars.allSatisfy(isHeaderNameScalar) else {
        throw ProviderError.invalidHeaderLine(trimmed)
      }
      pairs.append((name, value))
    }
    return pairs
  }

  private static func isHeaderNameScalar(_ scalar: Unicode.Scalar) -> Bool {
    switch scalar {
    case "a"..."z", "A"..."Z", "0"..."9", "-", "_": return true
    default: return false
    }
  }

  /// The credentials file holds `NAME=value` lines (quotes around the value allowed)
  /// for any number of providers, plus — for OpenRouter only — the legacy bare key.
  static func credential(named env: String, kind: ProviderKind, at url: URL) -> String? {
    guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
    var bare: String?
    for rawLine in contents.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty, !line.hasPrefix("#") else { continue }
      if let equals = line.firstIndex(of: "=") {
        let key = line[..<equals].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: equals)...]
          .trimmingCharacters(in: .whitespaces)
          .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        if key == env, !value.isEmpty { return value }
      } else if bare == nil {
        bare = line
      }
    }
    return kind == .openrouter ? bare : nil
  }

  private static func nonEmpty(_ value: String?) -> String? {
    guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
    return value
  }
}

// MARK: - VariableExpansion

/// `${NAME}` templates in config values: the environment's value (empty when unset), or
/// one of the caller's extras (`${UUID}` for header values). Literal `$` and `${` without
/// a closing brace pass through.
enum VariableExpansion {
  static func expand(_ value: String, environment: [String: String], extra: [String: String] = [:]) -> String {
    var result = value
    var searchStart = result.startIndex
    while let open = result.range(of: "${", range: searchStart..<result.endIndex),
          let close = result.range(of: "}", range: open.upperBound..<result.endIndex)
    {
      let name = String(result[open.upperBound..<close.lowerBound])
      let replacement = extra[name] ?? environment[name] ?? ""
      result.replaceSubrange(open.lowerBound..<close.upperBound, with: replacement)
      searchStart = result.index(open.lowerBound, offsetBy: replacement.count)
    }
    return result
  }
}
