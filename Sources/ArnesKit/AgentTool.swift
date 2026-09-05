import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - AgentTool

/// A tool the agent can call. Arnes keeps tools few and schemas dumb on purpose:
/// simple orthogonal tools are what make "any model" honest — every extra tool and
/// clever schema is a place where a non-frontier model face-plants.
public protocol AgentTool: Sendable {
  var name: String { get }
  var description: String { get }
  /// JSON Schema for the arguments object.
  var parameters: JSONValue { get }
  /// Whether this tool mutates state. `.mutating` tools go through the session's
  /// `PermissionDelegate` before executing; `.readOnly` tools run freely.
  var permission: ToolPermission { get }
  /// The gate for one specific call, when it depends on the arguments: the read tools
  /// are `.readOnly` inside the working directory and `.sensitive` outside it or on a
  /// credential location. Defaults to `permission`.
  func permission(for arguments: [String: JSONValue]) -> ToolPermission
  /// One-line description of a specific invocation, shown in permission prompts.
  func summary(arguments: [String: JSONValue]) -> String
  func execute(arguments: [String: JSONValue]) async throws -> String
}

/// A read-only tool whose only gate is the path (`PathScope.permission(forReading:)`):
/// `read_file`, `grep`, `glob`, `view_image`. Lets the session tell a *plain* out-of-tree
/// read — gated only by location — from a credential/`paths.denyRead` one, without holding
/// the path rules itself. For the former, "always this session" remembers a scoped
/// `Read(<dir>/**)` grant and `acceptEdits`/`bypass` auto-approve the call; the latter get
/// neither, because the answer here comes from the classifier and no grant pattern or mode
/// can reach past it. Deliberately not `bash` (its floor is the command classifiers) and
/// not `web_fetch` (its `.sensitive` is network egress, not a path).
public protocol PathGatedReadTool {
  /// The call's resolved physical path when the read is gated only by being outside the
  /// working tree — nil when it is inside (nothing gated) or on a credential /
  /// `paths.denyRead` location (never remembered, never mode-approved).
  func outsideReadPath(arguments: [String: JSONValue]) -> String?
}

/// A tool that contributes a section to the system prompt (skill and subagent
/// listings). Sections ride every request so the model knows what it can reach for.
public protocol PromptContributing {
  /// The section text; empty when there is nothing to list.
  var promptSection: String { get }
}

/// A tool whose execution spends money on nested model calls (the task tool). The
/// session drains the accrued amount after each call so subagent spend lands in the
/// parent turn's cost and `RunRecord`.
public protocol CostReportingTool {
  /// Returns the USD accrued since the last drain and resets the accumulator.
  func drainAccruedCost() -> Double
}

/// What a background subagent produced, handed to the lead at a step boundary instead of as
/// the tool call's own result (that result was `started background subagent …`).
///
/// `costUSD` is the run's whole spend and is added to the turn's books **at delivery** — a
/// background run never accrues into `CostReportingTool.drainAccruedCost`, so a dollar is
/// counted exactly once. The one exception is a run cancelled before delivery: its spend has
/// no outcome to ride and is accrued like a cancelled foreground delegation's (stranded cost).
public struct BackgroundOutcome: Sendable {
  /// The run id (the nested session id, shortened) every event and hook payload carried.
  public let id: String
  public let agent: String
  /// The resolved model slug the run executed on.
  public let model: String
  /// The full result text as the foreground path would have returned it: partial-run prefix,
  /// report body (or the "finished without a report" stand-in), `[hook]` feedback.
  public let report: String
  public let steps: Int
  public let toolCalls: Int
  public let costUSD: Double
  /// The run hit its step or dollar cap; `report` already says so in its prefix.
  public let partial: Bool

  public init(
    id: String, agent: String, model: String, report: String,
    steps: Int, toolCalls: Int, costUSD: Double, partial: Bool)
  {
    self.id = id
    self.agent = agent
    self.model = model
    self.report = report
    self.steps = steps
    self.toolCalls = toolCalls
    self.costUSD = costUSD
    self.partial = partial
  }
}

/// One background subagent as `/tasks` lists it: running, or finished and waiting for the
/// next step boundary to be delivered.
public struct BackgroundRun: Sendable, Equatable {
  public let id: String
  public let agent: String
  public let model: String
  public let startedAt: Date
  /// The run has finished; its report is queued for delivery.
  public let finished: Bool

  public init(id: String, agent: String, model: String, startedAt: Date, finished: Bool) {
    self.id = id
    self.agent = agent
    self.model = model
    self.startedAt = startedAt
    self.finished = finished
  }
}

/// A tool that can run work detached from the call that started it and hand the result back
/// later — the task tool with `background: true`. The session discovers these the way it
/// discovers `CostReportingTool`s (`tools.compactMap`), never by type name, and drives them at
/// three points of the loop: finished outcomes are **delivered** into history at every step
/// boundary, a turn that would otherwise end with work still pending **joins** one outcome and
/// takes another step (`Configuration.joinBackgroundAtTurnEnd`), and an interrupted turn
/// **cancels** everything still running.
///
/// `pending` means running *or* finished-but-undelivered: work the lead hasn't seen the end of.
public protocol BackgroundWorkSource: AnyObject, AgentTool {
  /// Runs in flight plus finished outcomes not yet drained.
  func pendingBackgroundCount() -> Int
  /// Finished outcomes, oldest first, removed from the queue.
  func drainFinishedBackground() -> [BackgroundOutcome]
  /// The next outcome: an already-finished one immediately, else the first run to finish.
  /// nil when nothing is pending — or when the awaiting task is cancelled while waiting.
  func awaitAnyBackground() async -> BackgroundOutcome?
  /// Cancels every running background run and drops every undelivered outcome; returns once
  /// the runs have wound down. Their spend is accrued for `CostReportingTool.drainAccruedCost`
  /// (the stranded-cost path), so the turn's books still see it.
  func cancelBackground() async
  /// Every pending run, for a UI listing (`/tasks`).
  func backgroundSnapshot() -> [BackgroundRun]
}

/// A tool that hosts background shell jobs (`bash … background: true` and the `job` tool, which
/// share one `JobRegistry`). The session finds these by conformance the way it finds
/// `BackgroundWorkSource`s — never by type name — and `Session.shutdown()` calls `shutdownJobs()`
/// on each when the session ends, so a job never outlives the session that started it. Both
/// tools over one registry conform, and `killAll` is idempotent, so a toolset that has `bash`
/// but not `job` (an agent's allowlist) still has its jobs killed.
public protocol JobHosting: AgentTool {
  /// Kills every job still running (`JobRegistry.killAll`). Idempotent.
  func shutdownJobs() async
}

/// A tool that remembers what the session has seen of a file — `read_file`, `write_file`
/// and `edit_file`, sharing one `FileVersions` tracker per toolset.
///
/// The session re-records after PostToolUse hooks run: a formatter hook that rewrites the
/// file just edited moves it out from under the model, and without a refresh the model's
/// next edit to its own change would be refused as stale. One call in
/// `Session.afterToolExecuted` — `recordCurrentVersion(ofPath:)` with the call's `path`
/// argument — covers every file tool. A no-op when the tool has no tracker.
public protocol FileVersionTracking: AgentTool {
  func recordCurrentVersion(ofPath path: String) async
}

/// A tool that is safe to run alongside the other calls of one assistant step. The session
/// dispatches these into a task group while the step's remaining calls execute in order, so
/// delegated work overlaps instead of queueing behind the lead's own reads.
///
/// Opt-in on purpose, and today only `TaskTool` opts in: a subagent already owns its own
/// session, tools and permission gate, so two of them overlapping is the same concurrency a
/// panel already runs. Every other tool stays sequential — the loop's determinism (history
/// order, `RunRecord`s, one prompt at a time) is worth more than the parallelism, and a tool
/// that touches shared process state would quietly break under it.
///
/// Conforming does not change ordering: results are still assembled in call order, and the
/// permission gate still runs sequentially before anything executes.
public protocol ConcurrentTool: AgentTool {}

/// A tool that produces progress events of its own while it runs (the task tool streams
/// its subagent's loop). For the duration of a turn the session points `onEvent` at the
/// turn's own event stream, so nested events ride the parent's sequence in order and every
/// consumer — REPL renderer, headless printer, embedder — sees them through the one stream
/// it already reads, with no side channel to wire (or forget) per caller.
public protocol EventEmittingTool: AnyObject, AgentTool {
  var onEvent: (@Sendable (AgentEvent) -> Void)? { get set }
}

/// Content a tool result must reach the model *as* — an image a tool read — rather than as
/// text. A tool result is a string on every wire; an image is not. So the tool's string result
/// stays what it is (the textual trace a transcript keeps, what a model that takes no images
/// reads) and the attachment rides a user message of content parts appended once the step's
/// tool results are all in history — after them, never between them, since a chat request
/// wants every result of an assistant's tool calls before anything else, and the one channel
/// every dialect carries an image on is a user turn.
public struct ToolAttachment: Sendable {
  /// The parts, in order: typically a text part naming the source, then the image part(s).
  public var parts: [ContentPart]

  public init(parts: [ContentPart]) {
    self.parts = parts
  }
}

/// A tool whose result may carry an attachment (`view_image`). The session asks once per
/// committed call, right after the call's text result entered history; the attachment is
/// appended after the step's results. nil = the call attached nothing (the usual answer).
public protocol AttachingTool: AgentTool {
  func takeAttachment(callId: String) async -> ToolAttachment?
}

/// A tool whose *presence* depends on the model being asked — read at the one per-model gate
/// (`Session.availableTools(for:)`), so the tool sections of the prompt and every request's tool
/// list agree: `view_image` only for a model whose manifest says it takes images, `think` omitted
/// for a model that reasons natively when the session asked for that (`Configuration.adaptiveThink`).
/// A tool that doesn't conform is always available — every existing tool, byte for byte.
///
/// Manifest-driven (invariant 1): the answer is a function of `ModelProfile` plus the session's
/// configuration as it stands (the live dials folded in — the effort a `/effort` set, not the
/// seed), never of the model's name. A call to a tool the current model was not offered — a
/// hallucinated name, or one remembered from before a `/model` swap — is answered by the loop
/// with a coaching error, never run.
public protocol CapabilityGatedTool: AgentTool {
  func isAvailable(for profile: ModelProfile, configuration: Session.Configuration) -> Bool
}

extension AgentTool {
  /// The OpenRouter chat tool definition for this tool.
  public var toolDefinition: Tool {
    .function(name: name, description: description, parameters: parameters)
  }

  /// Fail-safe default: a tool that doesn't declare itself is treated as mutating.
  public var permission: ToolPermission { .mutating }

  public func permission(for arguments: [String: JSONValue]) -> ToolPermission { permission }

  public func summary(arguments: [String: JSONValue]) -> String {
    let rendered = arguments
      .sorted { $0.key < $1.key }
      .compactMap { key, value in value.stringValue.map { "\(key): \($0)" } }
      .joined(separator: ", ")
    return "\(name) \(String(rendered.prefix(120)))"
  }
}

// MARK: - Tool root

/// Resolves a model-supplied path against a tool's root directory. Relative paths land
/// inside the root; absolute paths pass through (the root exists for isolation between
/// parallel candidates, not as a sandbox — `PathScope` is what decides whether a path
/// outside it needs the user's say-so).
func resolveToolPath(_ path: String, root: URL?) -> String {
  guard let root, !path.hasPrefix("/") else { return path }
  if path == "." || path.isEmpty { return root.path }
  return root.appendingPathComponent(path).path
}

// MARK: - PathScope

/// Where a model-supplied path points, relative to the run's working directory (the
/// tool root, or the process CWD). Reading inside it is the agent's job and runs freely;
/// anything outside — and a short list of places where credentials live — is shown to
/// the user first, the way Claude Code asks before reading outside the project.
public enum PathScope: Equatable, Sendable {
  case inside
  case outside
  /// A known credential location.
  case sensitive
  /// The harness's own state — `~/.arnes/**` and whatever `ARNES_CONFIG`,
  /// `ARNES_HOOKS_CONFIG`, `ARNES_MCP_CONFIG` or `ARNES_RULES_CONFIG` point at. A tool
  /// write here would let the agent rewrite the rules it is judged by (hooks, permission
  /// rules, MCP servers, trusted projects), so the write tools **refuse** it in `execute`
  /// rather than asking — see `harnessRefusal(forWriting:root:rules:)`.
  case harness

  /// Credential locations under the home directory, relative to it.
  public static let sensitiveHomePaths: [String] = [
    ".ssh", ".aws", ".gnupg", ".kube", ".docker/config.json", ".config/gh", ".config/gcloud",
    ".netrc", ".git-credentials", ".npmrc", ".pypirc",
    ".arnes/credentials", ".arnes/config.json", ".arnes/mcp.json",
  ]

  /// The physical path: `..` collapsed and symlinks resolved — including a symlinked
  /// *parent* of a file that doesn't exist yet. Foundation's `resolvingSymlinksInPath`
  /// gives up on a missing final component, which is exactly the write-side case
  /// (`link-to-outside/new.sh`), so the longest existing prefix is resolved and the rest
  /// re-appended.
  static func physicalPath(_ path: String) -> String {
    let standardized = URL(fileURLWithPath: path).standardizedFileURL
    if FileManager.default.fileExists(atPath: standardized.path) {
      return standardized.resolvingSymlinksInPath().path
    }
    var missing: [String] = []
    var url = standardized
    while !FileManager.default.fileExists(atPath: url.path), url.path != "/" {
      missing.insert(url.lastPathComponent, at: 0)
      url.deleteLastPathComponent()
    }
    var resolved = url.resolvingSymlinksInPath()
    for component in missing { resolved.appendPathComponent(component) }
    return resolved.path
  }

  /// Classifies `path` (relative paths resolve against `root`, or the CWD when nil).
  /// Symlinks and `..` are resolved on both sides, so `../../etc` and a link out of the
  /// tree are seen for what they are. `rules` carries the directories `--add-dir` opened
  /// and the config's extra globs — additive: it can widen the roots or tighten the globs,
  /// never turn a credential or harness path into ordinary work.
  public static func classify(
    _ path: String,
    root: URL?,
    rules: Rules = .default,
    home: String = NSHomeDirectory())
    -> PathScope
  {
    let base = root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let resolvedBase = physicalPath(base.path)
    let resolved = physicalPath(resolveToolPath(path, root: root))
    let resolvedHome = physicalPath(home)
    for relative in sensitiveHomePaths {
      let location = resolvedHome + "/" + relative
      if resolved == location || resolved.hasPrefix(location + "/") {
        return .sensitive
      }
    }
    // `paths.denyRead` from the config: files the user never wants read freely.
    if matchesAnyGlob(rules.policy.denyRead, path: path, root: root) { return .sensitive }
    if isUnder(resolved, base: resolvedBase) { return .inside }
    // `--add-dir`: directories the run was explicitly pointed at count as inside too.
    for extra in rules.roots.readable where isUnder(resolved, base: physicalPath(extra.path)) {
      return .inside
    }
    // The spill scope: the one place under `~/.arnes` a model may read — *this* session's own
    // copies of its oversized tool output, parked there for `read_file` to page; open only once
    // it has spilled, and never a sibling session's directory. Reads only: the write classifier
    // never consults this branch (`isHarness` answers first), so a write there is still refused
    // by the floor.
    if let scope = rules.spillScope, scope.contains(resolvedPath: resolved) {
      return .inside
    }
    // The project's memory directory (C3): the model's own notes, read freely — on the resolved
    // path, exact to that directory. Reads only here too: the write classifier consults
    // `forWrites`, which drops the root, so a write there classifies `.outside` → `.sensitive`.
    if isUnderMemoryRoot(resolved, rules: rules) { return .inside }
    // The REPL's paste stash: copies arnes itself made of images the user dragged in — the
    // drag is the consent, so `view_image`/`read_file` there never prompt. Resolved path,
    // exact to that directory (a symlink planted inside resolves out and is judged where it
    // points). Reads only: `forWrites` drops it, so a write there stays `.outside`.
    if let stash = rules.pasteStash, isUnder(resolved, base: physicalPath(stash.path)) {
      return .inside
    }
    return .outside
  }

  /// Whether a resolved path sits in the memory carve-out (`Rules.memoryRoot`). Physical paths
  /// on both sides, so `memory-evil` never matches `memory` and a symlink planted inside the
  /// directory resolves to wherever it points.
  static func isUnderMemoryRoot(_ resolved: String, rules: Rules) -> Bool {
    guard let memoryRoot = rules.memoryRoot else { return false }
    return isUnder(resolved, base: physicalPath(memoryRoot.path))
  }

  /// Whether `resolved` is `base` or sits under it. Both sides are already physical paths.
  static func isUnder(_ resolved: String, base: String) -> Bool {
    base == "/" || resolved == base || resolved.hasPrefix(base + "/")
  }

  static func matchesAnyGlob(_ globs: [String], path: String, root: URL?) -> Bool {
    !globs.isEmpty && globs.contains { GlobMatch.matches(glob: $0, path: path, root: root) }
  }

  /// The gate a read of `path` needs.
  public static func permission(forReading path: String, root: URL?, rules: Rules = .default) -> ToolPermission {
    classify(path, root: root, rules: rules) == .inside ? .readOnly : .sensitive
  }

  /// The resolved physical path of a read gated *only* by location — a plain file outside the
  /// working tree — or nil when the read is inside (nothing gated) or on a credential /
  /// `paths.denyRead` location. The one question `PathGatedReadTool` answers: what "always
  /// this session" may remember for a read, and what `acceptEdits`/`bypass` auto-approve; a
  /// credential or denyRead path is neither, whatever any grant pattern says, because this
  /// check runs on the classifier and a glob never reaches it.
  public static func outsideReadPath(_ path: String, root: URL?, rules: Rules = .default) -> String? {
    guard classify(path, root: root, rules: rules) == .outside else { return nil }
    return physicalPath(resolveToolPath(path, root: root))
  }

  /// The directory "always this session" remembers for a plain out-of-tree read: the enclosing
  /// repository root when one exists (the first ancestor holding a `.git` entry — a grant
  /// earned by one file of a sibling checkout covers the checkout, the way project trust
  /// scopes), else the file's own directory (the path itself when it is a directory). Never
  /// the home directory, an ancestor of it, or `/` — a read directly under those is too broad
  /// to remember and grants nothing (approve-once, as ever). `resolved` is a physical path
  /// (`outsideReadPath`'s), so a symlinked spelling can't scope the grant somewhere else.
  public static func readGrantDirectory(
    forResolvedPath resolved: String,
    home: String = NSHomeDirectory())
    -> String?
  {
    let resolvedHome = physicalPath(home)
    func refused(_ dir: String) -> Bool {
      dir == "/" || dir == resolvedHome || resolvedHome.hasPrefix(dir + "/")
    }
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory)
    let start = exists && isDirectory.boolValue
      ? resolved
      : (resolved as NSString).deletingLastPathComponent
    var probe = start
    while !refused(probe) {
      if FileManager.default.fileExists(atPath: probe + "/.git") { return probe }
      probe = (probe as NSString).deletingLastPathComponent
    }
    return refused(start) ? nil : start
  }

  /// Suffix for a permission-prompt summary: why this read is being asked about.
  public static func note(for path: String, root: URL?, rules: Rules = .default) -> String {
    switch classify(path, root: root, rules: rules) {
    case .inside: return ""
    case .outside: return " (outside the working directory)"
    case .sensitive: return " (credential location)"
    case .harness: return " (harness file)"
    }
  }

  // MARK: Writes

  /// In-tree locations where a write changes what *runs* rather than what is built: git
  /// hooks and config (`core.hooksPath`, aliases), CI workflow definitions, and the
  /// harness's own trust-gated project directories (an agent or skill file written here
  /// becomes system-prompt text in every future session). Relative to the working root.
  public static let protectedRelativePaths: [String] = [
    ".git/hooks", ".git/config", ".github/workflows", ".arnes", ".claude", ".mcp.json",
  ]

  /// Home-relative files whose contents execute on the user's next shell or login —
  /// the classic persistence targets. Writing them is never routine agent work.
  public static let sensitiveWriteHomePaths: [String] = [
    ".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile",
    ".gitconfig", ".config/git", ".config/fish", "Library/LaunchAgents",
  ]

  /// Classifies `path` as a write target: everything `classify` flags, plus the harness's
  /// own files, the in-tree protected paths, the home persistence files above, and whatever
  /// the config's `paths` block adds. `.inside` means an ordinary edit inside the working
  /// tree (or a directory `--add-dir` opened).
  public static func classify(
    forWriting path: String,
    root: URL?,
    rules: Rules = .default,
    home: String = NSHomeDirectory())
    -> PathScope
  {
    // The harness's own state first: this is a refusal, not a prompt.
    if isHarness(path, root: root, rules: rules) { return .harness }
    let resolved = physicalPath(resolveToolPath(path, root: root))
    let resolvedHome = physicalPath(home)
    for relative in sensitiveWriteHomePaths {
      let location = resolvedHome + "/" + relative
      if resolved == location || resolved.hasPrefix(location + "/") {
        return .sensitive
      }
    }
    // `paths.sensitiveWrite` from the config: `.sensitive` wherever it matches.
    if matchesAnyGlob(rules.policy.sensitiveWrite, path: path, root: root) { return .sensitive }
    // Writes use the writable roots; reads and writes are widened separately so a future
    // caller can open a directory for reading without opening it for writing.
    let scope = classify(path, root: root, rules: rules.forWrites, home: home)
    guard scope == .inside else { return scope }
    let base = root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    // Protected paths are relative to whichever writable root the file landed in, so an
    // `--add-dir` directory's `.git/hooks` is protected the same way the working tree's is.
    for writableRoot in [physicalPath(base.path)] + rules.roots.writable.map({ physicalPath($0.path) }) {
      let prefix = writableRoot == "/" ? "/" : writableRoot + "/"
      guard resolved.hasPrefix(prefix) else { continue }
      let relative = String(resolved.dropFirst(prefix.count))
      for protected in protectedRelativePaths
        where relative == protected || relative.hasPrefix(protected + "/")
      {
        return .sensitive
      }
    }
    // `paths.protected` from the config: promotes an in-tree write to `.sensitive`.
    if matchesAnyGlob(rules.policy.protected, path: path, root: root) { return .sensitive }
    return .inside
  }

  /// The gate a write to `path` needs: an ordinary prompt inside the tree, the louder
  /// `.sensitive` one (never covered by "always allow", vetoed headless) anywhere else.
  /// `.harness` gates as `.sensitive` too, but the write tools refuse it outright.
  public static func permission(forWriting path: String, root: URL?, rules: Rules = .default) -> ToolPermission {
    classify(forWriting: path, root: root, rules: rules) == .inside ? .mutating : .sensitive
  }

  /// Suffix for a write's permission-prompt summary: why it is louder than usual.
  public static func writeNote(for path: String, root: URL?, rules: Rules = .default) -> String {
    switch classify(forWriting: path, root: root, rules: rules) {
    case .inside: return ""
    case .outside:
      return isUnderMemoryRoot(physicalPath(resolveToolPath(path, root: root)), rules: rules)
        ? " (memory directory — outside the working tree)"
        : " (outside the working directory)"
    case .harness: return " (harness file — not editable by tools)"
    case .sensitive:
      return classify(path, root: root, rules: rules) == .inside
        ? " (protected path)"
        : " (credential or startup location)"
    }
  }

  // MARK: The harness floor

  /// Environment variables that relocate a harness config file. Whatever they point at is
  /// harness state wherever it lives, so moving `hooks.json` out of `~/.arnes` doesn't make
  /// it tool-writable.
  public static let harnessConfigVariables = [
    "ARNES_CONFIG", "ARNES_HOOKS_CONFIG", "ARNES_MCP_CONFIG", "ARNES_RULES_CONFIG",
  ]

  /// The absolute locations the harness owns: `~/.arnes` plus every configured override.
  public static func harnessPaths(
    home: String = NSHomeDirectory(),
    environment: [String: String] = ProcessInfo.processInfo.environment)
    -> [String]
  {
    var paths = [physicalPath(home + "/.arnes")]
    for variable in harnessConfigVariables {
      let raw = (environment[variable] ?? "").trimmingCharacters(in: .whitespaces)
      guard !raw.isEmpty else { continue }
      paths.append(physicalPath((raw as NSString).expandingTildeInPath))
    }
    return paths
  }

  /// Computed once: a CLI process's home and `ARNES_*` variables don't move mid-run, and
  /// resolving them touches the filesystem.
  public static let defaultHarnessPaths: [String] = harnessPaths()

  /// Whether a write to `path` would land on harness state.
  ///
  /// The one carve-out is the project's memory directory (`Rules.memoryRoot`, C3): a path that
  /// *resolves* under it is not harness state — so the write tools, `ShellCommandTargets`' write
  /// targets and the critical-removal floor, which all ask here, let it through to the ordinary
  /// classification (`.sensitive`: a loud prompt, vetoed headless) and to a `.destructive`
  /// prompt for `rm -rf <memory dir>`. Everything else under `~/.arnes` — `rm -rf ~/.arnes`
  /// included — is exactly as refused as before.
  public static func isHarness(_ path: String, root: URL?, rules: Rules = .default) -> Bool {
    let resolved = physicalPath(resolveToolPath(path, root: root))
    if isUnderMemoryRoot(resolved, rules: rules) { return false }
    return rules.harnessPaths.contains { isUnder(resolved, base: $0) }
  }

  /// The refusal a write tool returns for a harness path, or nil when the path is fine.
  /// Enforced inside `execute`, before anything is created and independent of any permission
  /// decision — the write-side twin of `ShellCommand.isCatastrophic`, so `--yes`, an allow
  /// rule, `bypass` mode and "always this session" all stop at it.
  public static func harnessRefusal(forWriting path: String, root: URL?, rules: Rules = .default) -> String? {
    guard isHarness(path, root: root, rules: rules) else { return nil }
    return "error: refused — harness files are not editable by tools; edit them yourself"
  }
}

// MARK: - PathScope.Roots

extension PathScope {
  /// Directories a run was pointed at beyond its working root (`--add-dir`). Paths under
  /// them classify `.inside`, so reads and writes there are ordinary work instead of
  /// `.sensitive` escapes — the sanctioned way to widen a run rather than blanket-approving
  /// everything. Additive only: nothing here turns a credential, startup or harness path
  /// into ordinary work.
  public struct Roots: Sendable, Equatable {
    /// Extra directories that count as inside for reads.
    public var readable: [URL]
    /// Extra directories that count as inside for writes.
    public var writable: [URL]

    public init(readable: [URL] = [], writable: [URL] = []) {
      self.readable = readable
      self.writable = writable
    }

    /// `--add-dir`: one list of directories widens reads and writes alike.
    public init(additional directories: [URL]) {
      self.init(readable: directories, writable: directories)
    }

    public static let none = Roots()
    public var isEmpty: Bool { readable.isEmpty && writable.isEmpty }
  }

  /// Everything a run adds to the built-in path classification: the `--add-dir` roots, the
  /// config's `paths` globs, and the harness locations the write floor refuses. One value,
  /// carried on `ToolContext` and every path-taking tool, so a widening or tightening lands
  /// in all of them at once.
  public struct Rules: Sendable, Equatable {
    public var roots: Roots
    public var policy: PathPolicy
    /// Absolute paths the harness owns. Defaults to `PathScope.defaultHarnessPaths`;
    /// injectable so tests don't have to touch the real `~/.arnes`.
    public var harnessPaths: [String]
    /// The live session's spill directory (`SpillScope`: `~/.arnes/tmp/<session id>` for the
    /// CLI, opened by the session when it first spills, closed at `end`). A **read-only**
    /// carve-out, exact to that one directory: paths under it classify `.inside` for reads so
    /// `read_file`/`grep`/`glob` can page a spilled result without a prompt, while a sibling
    /// session's directory stays `.outside` and writes there stay whatever the write classifier
    /// says — under `~/.arnes` that is the harness floor, refused before anything is written.
    /// nil = no carve-out (the default; a spill path is then gated like any outside path).
    public var spillScope: SpillScope?
    /// The project's memory directory (`MemoryStore.directory`, `~/.arnes/memory/<project key>/`
    /// for the CLI; C3): the one place under the harness root the model may **write**. Carved
    /// out of the write floor — `isHarness` answers false for a path that resolves under it — so
    /// `write_file`/`edit_file`/a bash redirect there reach the ordinary write classification,
    /// where an out-of-tree path is `.sensitive` (a loud prompt, never covered by "always", vetoed
    /// under a headless `--yes`); reads there classify `.inside` (free). Exact to that one
    /// directory on the resolved path: `memory-evil` never matches, a symlink planted inside it
    /// resolves out and stays refused, and `~/.arnes` itself stays the floor. nil = no carve-out
    /// (the default; `--no-memory`, evals, panels, embedders).
    public var memoryRoot: URL?
    /// The REPL's paste-stash directory (`PasteStore.stashDirectory`: arnes's own 0700 copies
    /// of images the user dragged into the terminal). A **read-only** carve-out like the spill
    /// scope: the user's drag is the consent, so a `view_image`/`read_file` of a stashed copy
    /// never prompts, while writes there stay `.outside` → gated (`forWrites` drops it) and a
    /// symlink planted inside resolves out and is judged where it points. nil = no carve-out
    /// (the default; headless runs, evals, panels, embedders).
    public var pasteStash: URL?

    public init(
      roots: Roots = .none,
      policy: PathPolicy = .empty,
      harnessPaths: [String]? = nil,
      spillScope: SpillScope? = nil,
      memoryRoot: URL? = nil,
      pasteStash: URL? = nil)
    {
      self.roots = roots
      self.policy = policy
      self.harnessPaths = harnessPaths ?? PathScope.defaultHarnessPaths
      self.spillScope = spillScope
      self.memoryRoot = memoryRoot
      self.pasteStash = pasteStash
    }

    public static let `default` = Rules()

    /// The same rules with the writable roots in the readable slot — what
    /// `classify(forWriting:)` consults, so a directory opened for writing is inside for
    /// the write classification without being inside for reads. The spill carve-out is
    /// dropped: it opens reads, never writes. The memory root is dropped too: it opens reads
    /// and lifts the floor, but a write there must classify `.outside` → `.sensitive` (the
    /// floor carve-out is read off the original rules by `isHarness`, before this copy is made).
    var forWrites: Rules {
      var copy = self
      copy.roots = Roots(readable: roots.writable, writable: roots.writable)
      copy.spillScope = nil
      copy.memoryRoot = nil
      copy.pasteStash = nil
      return copy
    }
  }
}

// MARK: - FileIdentity

/// Device + inode of a filesystem entry: the identity a path pointed at, at a point in
/// time. The write tools take the parent directory's identity when they classify a path and
/// re-check it immediately before writing, so a directory swapped in between (the classic
/// TOCTOU: approve `project/out.txt`, then flip `project` to a symlink at `/etc`) is caught
/// instead of followed.
struct FileIdentity: Equatable, Sendable {
  let device: Int64
  let inode: UInt64

  /// nil when the path doesn't exist or can't be stat'ed — nothing to compare against.
  /// Symlinks are followed, so this is the identity of whatever the path *reaches now*.
  static func of(_ path: String) -> FileIdentity? {
    var info = stat()
    guard stat(path, &info) == 0 else { return nil }
    return FileIdentity(device: Int64(clamping: info.st_dev), inode: UInt64(clamping: info.st_ino))
  }

  /// True when `path` still reaches the entry `identity` described. A nil `identity` means
  /// there was nothing there to begin with (a directory about to be created), which is fine.
  static func unchanged(_ path: String, since identity: FileIdentity?) -> Bool {
    guard let identity else { return true }
    return of(path) == identity
  }
}

// MARK: - Built-in tools

public struct ReadFileTool: AgentTool, FileVersionTracking, PathGatedReadTool {
  public let name = "read_file"
  public let description =
    "Read a file and return its contents with line numbers. For a large file, page through it "
    + "with offset (1-based line to start) and limit (max lines) instead of pulling it all into context."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "path": ["type": "string", "description": "File path"],
      "offset": ["type": "integer", "description": "1-based line number to start at (optional)"],
      "limit": ["type": "integer", "description": "Maximum number of lines to return (optional)"],
    ],
    "required": ["path"],
  ]

  /// Lines returned when the caller gives no `limit` — enough for most files, small enough
  /// that a huge one doesn't silently flood the context; the tail is summarized with a hint.
  static let defaultLineCap = 2000

  /// Characters of one line that ride the result; a minified bundle or a one-line JSON dump
  /// is clipped with a note instead of pasting a megabyte into the context.
  static let lineCharCap = 2000

  /// How much of a file is sniffed for a NUL byte before it is called binary.
  static let binarySniffBytes = 1024

  private let root: URL?
  private let rules: PathScope.Rules
  private let versions: FileVersions?

  /// - Parameter versions: the session's file tracker. A successful read records the
  ///   version here, which is what later lets `edit_file` know the model has actually
  ///   seen the file. nil disables it.
  public init(root: URL? = nil, rules: PathScope.Rules = .default, versions: FileVersions? = nil) {
    self.root = root
    self.rules = rules
    self.versions = versions
  }

  /// Free inside the working directory (and any `--add-dir` directory); asked about
  /// outside them, on a credential path, or on a configured `paths.denyRead` glob.
  public func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    guard let path = arguments["path"]?.stringValue else { return .readOnly }
    return PathScope.permission(forReading: path, root: root, rules: rules)
  }

  public func outsideReadPath(arguments: [String: JSONValue]) -> String? {
    guard let path = arguments["path"]?.stringValue else { return nil }
    return PathScope.outsideReadPath(path, root: root, rules: rules)
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "?"
    return "read_file \(path)\(PathScope.note(for: path, root: root, rules: rules))"
  }

  public func recordCurrentVersion(ofPath path: String) async {
    await versions?.record(path: resolveToolPath(path, root: root))
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let path = arguments["path"]?.stringValue.map({ resolveToolPath($0, root: root) }) else {
      return "error: missing 'path'"
    }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue,
          let data = try? Data(contentsOf: URL(fileURLWithPath: path))
    else {
      return "error: cannot read \(path)"
    }
    // A NUL in the first KB means bytes, not text: say what the file is (by its magic) instead
    // of numbering line noise. Sniffed, never executed or decoded.
    if let kind = Self.binaryKind(of: data) {
      return "error: \(path) is a binary file (\(data.count) bytes, looks like \(kind))"
    }
    // Lossy on invalid UTF-8 (a Latin-1 comment in an otherwise readable file) rather than
    // refusing the whole file.
    let content = String(decoding: data, as: UTF8.self)
    // The file has now been seen: the write tools gate on this record.
    await versions?.record(path: path)
    let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
    let start = max(1, arguments["offset"]?.intValue ?? 1)
    let startIndex = start - 1
    if startIndex >= lines.count {
      return lines.isEmpty
        ? ""
        : "error: offset \(start) is past end of file (\(lines.count) lines)"
    }
    let requested = arguments["limit"]?.intValue
    let capped = requested == nil // no explicit limit → apply the default cap
    let count = requested ?? Self.defaultLineCap
    let endIndex = min(lines.count, startIndex + max(0, count))
    var body = lines[startIndex..<endIndex]
      .enumerated()
      .map { "\(startIndex + $0.offset + 1)\t\(Self.clipped(String($0.element)))" }
      .joined(separator: "\n")
    let remaining = lines.count - endIndex
    if remaining > 0 {
      let why = capped ? "capped at \(Self.defaultLineCap) lines" : "limit reached"
      body += "\n… \(remaining) more line\(remaining == 1 ? "" : "s") (\(why); "
        + "read on with offset \(endIndex + 1))"
    }
    return body
  }

  /// One line, clipped at `lineCharCap` with a note naming what was left out.
  static func clipped(_ line: String) -> String {
    guard line.count > lineCharCap else { return line }
    return String(line.prefix(lineCharCap)) + "…[line truncated, \(line.count - lineCharCap) chars]"
  }

  /// nil for text; otherwise the format the leading bytes announce (`PNG`, `JPEG`, `GIF`,
  /// `PDF`, `zip`, `ELF`, `Mach-O`) or `unknown`. A file counts as binary when a NUL byte sits
  /// in its first `binarySniffBytes` — the same heuristic `grep` uses.
  static func binaryKind(of data: Data) -> String? {
    let head = [UInt8](data.prefix(binarySniffBytes))
    guard head.contains(0) else { return nil }
    func starts(with magic: [UInt8]) -> Bool { head.count >= magic.count && Array(head[0..<magic.count]) == magic }
    if starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "PNG" }
    if starts(with: [0xFF, 0xD8, 0xFF]) { return "JPEG" }
    if starts(with: [0x47, 0x49, 0x46, 0x38]) { return "GIF" }
    if starts(with: [0x25, 0x50, 0x44, 0x46]) { return "PDF" }
    if starts(with: [0x50, 0x4B, 0x03, 0x04]) || starts(with: [0x50, 0x4B, 0x05, 0x06])
      || starts(with: [0x50, 0x4B, 0x07, 0x08])
    {
      return "zip"
    }
    if starts(with: [0x7F, 0x45, 0x4C, 0x46]) { return "ELF" }
    for magic: [UInt8] in [
      [0xFE, 0xED, 0xFA, 0xCE], [0xFE, 0xED, 0xFA, 0xCF], [0xCE, 0xFA, 0xED, 0xFE],
      [0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE],
    ] where starts(with: magic) {
      return "Mach-O"
    }
    return "unknown"
  }
}

public struct WriteFileTool: AgentTool, FileVersionTracking, FileMutatingTool {
  public let name = "write_file"
  public let description =
    "Write content to a file. Use it to create a new file or to rewrite one whole; prefer edit_file for a "
    + "targeted change. Overwriting an existing file that this session has not read, or that changed on "
    + "disk since it was read, is refused — read_file it first."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "path": ["type": "string"],
      "content": ["type": "string"],
    ],
    "required": ["path", "content"],
  ]

  private let root: URL?
  private let rules: PathScope.Rules
  private let versions: FileVersions?
  private let sandbox: ShellSandbox?
  /// Where the pre-image of a file about to be written is kept for `/rewind`; nil = none kept.
  public let checkpoints: (any CheckpointStore)?

  /// - Parameters:
  ///   - versions: what the session has read (`FileVersions`); an overwrite of a
  ///     file missing from it is refused. nil disables the check — creating new files is
  ///     never gated by it either way.
  ///   - sandbox: the run's OS confinement. This tool writes through Foundation, so the
  ///     kernel never applies the sandbox profile to it; consulting `permitsWrite` here is
  ///     what makes "sandbox on" mean the same boundary for `write_file` as for `bash`.
  ///   - checkpoints: the store that records each file's pre-image before the write (the REPL's
  ///     `/rewind`); nil — every unattended runner — keeps none.
  public init(
    root: URL? = nil,
    rules: PathScope.Rules = .default,
    versions: FileVersions? = nil,
    sandbox: ShellSandbox? = nil,
    checkpoints: (any CheckpointStore)? = nil)
  {
    self.root = root
    self.rules = rules
    self.versions = versions
    self.sandbox = sandbox
    self.checkpoints = checkpoints
  }

  /// An ordinary prompt inside the working tree (or an `--add-dir` directory); `.sensitive`
  /// (never covered by "always allow", vetoed headless) outside them, on a credential path,
  /// on a shell startup file, or on a protected path like `.git/hooks` or `.github/workflows`.
  public func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    guard let path = arguments["path"]?.stringValue else { return .mutating }
    return PathScope.permission(forWriting: path, root: root, rules: rules)
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "?"
    let bytes = arguments["content"]?.stringValue?.utf8.count ?? 0
    return "write_file \(path) (\(bytes) bytes)\(PathScope.writeNote(for: path, root: root, rules: rules))"
  }

  public func recordCurrentVersion(ofPath path: String) async {
    await versions?.record(path: resolveToolPath(path, root: root))
  }

  public func mutatedPaths(arguments: [String: JSONValue]) -> [String] {
    arguments["path"]?.stringValue.map { [resolveToolPath($0, root: root)] } ?? []
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard
      let requested = arguments["path"]?.stringValue,
      let content = arguments["content"]?.stringValue
    else {
      return "error: missing 'path' or 'content'"
    }
    // The write-side floor, before anything is created and independent of any permission
    // decision: the harness's own files are never tool-writable.
    if let refusal = PathScope.harnessRefusal(forWriting: requested, root: root, rules: rules) {
      return refusal
    }
    let path = resolveToolPath(requested, root: root)
    // The sandbox's in-process mirror: this write never reaches a shell, so the kernel can't
    // stop it — the same lists that build the SBPL profile decide here instead.
    if let refusal = sandbox?.writeRefusal(path) { return refusal }
    // Creating a file is free; blowing away one the model never looked at is not. The
    // refusal points at `edit_file`, which is usually what was meant anyway.
    let previousBytes = (try? FileManager.default.attributesOfItem(atPath: path))
      .flatMap { ($0[.size] as? NSNumber)?.intValue }
    if previousBytes != nil,
      let refusal = await FileGate.refusal(for: path, versions: versions, overwriting: true)
    {
      return refusal
    }
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    // The directory the safety check blessed, by identity rather than by name.
    let parentIdentity = FileIdentity.of(PathScope.physicalPath(parent.path))
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    guard FileIdentity.unchanged(parent.path, since: parentIdentity) else {
      return "error: refused — \(parent.path) is not the directory it was when this write was "
        + "checked (it was replaced or re-linked); re-read the path and try again"
    }
    // The pre-image, for `/rewind`: taken once every gate has passed and right before the write,
    // so a refused call leaves no checkpoint and a file created here is recorded as "didn't exist".
    if let checkpoints { await checkpoints.snapshot(path: path) }
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    await versions?.record(path: path)
    guard let previousBytes else {
      return "created \(path) (\(content.utf8.count) bytes)"
    }
    return "overwrote \(path) (\(content.utf8.count) bytes, was \(previousBytes))"
  }
}

public struct BashTool: AgentTool, JobHosting {
  public let name = "bash"
  /// Names the tool's own default timeout (the configured one), so the model is never told a
  /// number the run doesn't use — and offers `background: true` only where a registry backs it:
  /// a run without one (evals, panels, review, `--disallowed-tools job`) is told long work must
  /// fit the timeout instead of being coached into a call that can only be refused.
  public var description: String {
    let base = "Run a shell command and return stdout+stderr. Long output is capped head+tail (the middle is "
      + "omitted; the last lines survive), so narrow noisy commands with grep/tail. stdin is closed; "
      + "commands are killed after timeout_seconds (default \(timeoutSeconds), max "
      + "\(Self.maxTimeoutSeconds)), so don't start anything that waits for input or runs forever. "
    guard jobs != nil else {
      return base + "Background jobs are not available in this run: keep every command finishing "
        + "within timeout_seconds (start no server or watcher)."
    }
    return base + "For a server, a watcher or a long build, pass background: true — the command runs "
      + "detached and this returns at once with a job id; poll it with the job tool. A background "
      + "job is killed when the session that started it ends (a subagent's when its turn returns)."
  }
  public var parameters: JSONValue {
    var properties: [String: JSONValue] = [
      "command": ["type": "string"],
      "timeout_seconds": [
        "type": "integer",
        "description": .string(
          "seconds before the command is killed (1–\(Self.maxTimeoutSeconds); default \(timeoutSeconds))"),
      ],
    ]
    if jobs != nil {
      properties["background"] = [
        "type": "boolean",
        "description": "run detached and return a job id at once; output goes to a log the job tool reads",
      ]
    }
    return [
      "type": "object",
      "properties": .object(properties),
      "required": ["command"],
    ]
  }

  /// Characters of output the tool is sized for (`limits.bashOutputChars`). The runner keeps
  /// 2× this of head and of tail in memory (`ShellRunner.OutputBounds`); what the model reads
  /// is then bounded by the session's `toolResultMaxChars`, and the spill file holds the rest.
  public static let defaultOutputChars = 20_000
  /// The per-command timeout when neither the call nor `limits.bashTimeoutSeconds` says.
  public static let defaultTimeoutSeconds = 300
  /// The most a call may ask for with `timeout_seconds` (and the most the config default may
  /// be): ten minutes. Longer work belongs in a background job.
  public static let maxTimeoutSeconds = 600

  private let root: URL?
  private let rules: PathScope.Rules
  private let timeoutSeconds: Int
  private let sandbox: ShellSandbox?
  private let environment: SubprocessEnvironment
  private let outputBounds: ShellRunner.OutputBounds
  private var jobs: JobRegistry?

  /// - Parameters:
  ///   - rules: the directories `--add-dir` opened, so a read-only command over one of them
  ///     skips the prompt like an in-tree one. See `PathScope.Rules`.
  ///   - timeoutSeconds: hard cap per command (default 5 minutes) — a hung build or server
  ///     must not hang the turn. The call's own `timeout_seconds` overrides it, within
  ///     `1...maxTimeoutSeconds`.
  ///   - sandbox: when set, the command runs OS-confined (writes limited to the working tree
  ///     + temp, network per policy). Requested-but-unsupported fails closed. See `ShellSandbox`.
  ///   - environment: what the command inherits of the parent environment; the provider
  ///     token is always withheld. Default: everything else. See `SubprocessEnvironment`.
  ///   - outputChars: the output size the tool is built for; the runner keeps 2× of head and
  ///     of tail (`defaultOutputChars`).
  ///   - jobs: where `background: true` commands run (`JobRegistry`, shared with the `job`
  ///     tool). nil = background jobs are not available in this run.
  public init(
    root: URL? = nil,
    rules: PathScope.Rules = .default,
    timeoutSeconds: Int = BashTool.defaultTimeoutSeconds,
    sandbox: ShellSandbox? = nil,
    environment: SubprocessEnvironment = .default,
    outputChars: Int = BashTool.defaultOutputChars,
    jobs: JobRegistry? = nil)
  {
    self.root = root
    self.rules = rules
    self.timeoutSeconds = Self.clampedTimeout(timeoutSeconds)
    self.sandbox = sandbox
    self.environment = environment
    self.jobs = jobs
    outputBounds = ShellRunner.OutputBounds(capChars: max(1_000, outputChars))
  }

  /// The registry `background: true` commands land in, if any.
  var jobRegistry: JobRegistry? { jobs }

  /// The same tool over another registry — how a nested session gets jobs of its own (killed
  /// when its turn returns) without a copy of the lead's registry.
  func withJobs(_ registry: JobRegistry?) -> BashTool {
    var copy = self
    copy.jobs = registry
    return copy
  }

  /// `1...maxTimeoutSeconds`: a call asking for 0 or 10 000 seconds gets the nearest bound.
  static func clampedTimeout(_ seconds: Int) -> Int {
    min(max(1, seconds), maxTimeoutSeconds)
  }

  /// The timeout this call runs under: its own `timeout_seconds` (clamped), else the tool's.
  func timeout(for arguments: [String: JSONValue]) -> Int {
    arguments["timeout_seconds"]?.intValue.map(Self.clampedTimeout) ?? timeoutSeconds
  }

  /// The `background` flag as the model sent it — a boolean, or the spellings small models use
  /// for one (`"true"`, `"yes"`, `1`); absent = false. nil = a value that is neither, which
  /// `execute` refuses with a coaching error instead of silently running the command in the
  /// foreground (a dev server meant to be detached would then block the turn until the timeout).
  static func backgroundFlag(from arguments: [String: JSONValue]) -> Bool? {
    guard let value = arguments["background"] else { return false }
    switch value {
    case .null: return false
    case .bool(let flag): return flag
    case .int(let number): return number == 0 ? false : number == 1 ? true : nil
    case .double(let number): return number == 0 ? false : number == 1 ? true : nil
    case .string(let text):
      switch text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "true", "yes", "1": return true
      case "false", "no", "0", "": return false
      default: return nil
      }
    case .array, .object: return nil
    }
  }

  public func shutdownJobs() async {
    await jobs?.killAll()
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    // The command is shown verbatim — that's the whole point of the permission prompt.
    "bash: \(arguments["command"]?.stringValue ?? "?")"
  }

  /// Obviously read-only commands inside the tree (`git status`, `ls`, `cat README.md`)
  /// run without a prompt, like `read_file`; recognized-irreversible commands (`rm`,
  /// `git push`, `sudo …`) get the louder `.sensitive` prompt; everything else asks.
  /// Catastrophic commands classify `.sensitive` too but never actually run — `execute`
  /// refuses them below regardless of the permission answer. See `ShellCommand`.
  public func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    guard let command = arguments["command"]?.stringValue else { return .mutating }
    switch ShellCommand.risk(command, root: root, rules: rules) {
    case .readOnly: return .readOnly
    case .ordinary: return .mutating
    case .destructive, .catastrophic: return .sensitive
    }
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let command = arguments["command"]?.stringValue else {
      return "error: missing 'command'"
    }
    // The hard floor: irrecoverable-catastrophic commands are refused here, before spawning,
    // independent of any permission decision — so `--yes`, evals, panels, and "always allow
    // this session" can never run them. This is defense-in-depth, not containment.
    if let reason = ShellCommand.isCatastrophic(command, root: root, rules: rules) {
      return "error: refused — this command \(reason), which Arnes blocks as irrecoverable. "
        + "If you truly intend it, run it yourself in a shell."
    }
    // `background: true`: the same command, gated and floored exactly like the foreground form
    // (the permission tier never looks at the flag), launched detached with its output in a log
    // the `job` tool reads. The answer is the job id; the exit arrives as a notice later.
    guard let background = Self.backgroundFlag(from: arguments) else {
      let raw = arguments["background"]
        .flatMap { try? JSONEncoder().encode($0) }
        .flatMap { String(data: $0, encoding: .utf8) }
        .map { String($0.prefix(80)) } ?? "?"
      return "error: background must be true or false (got \(raw)) — send background: true to run "
        + "the command detached, or leave it out"
    }
    if background {
      guard let jobs else {
        return "error: background jobs are not available in this run — run the command in the "
          + "foreground (drop background), narrowing it so it finishes within timeout_seconds"
      }
      do {
        let job = try await jobs.start(command: command, cwd: root, sandbox: sandbox, environment: environment)
        return Self.startedLine(for: job)
      } catch {
        return "error: could not start background job: \(error)"
      }
    }
    let timeout = timeout(for: arguments)
    let outcome = await ShellRunner.run(
      command, cwd: root, timeoutSeconds: timeout, sandbox: sandbox, environment: environment,
      outputBounds: outputBounds)
    // Under a sandbox, `Operation not permitted` means the confinement stopped the command —
    // not something a retry fixes. Saying so turns a blind retry loop into a request.
    // The output is already head + `[… N bytes omitted …]` + tail when the command printed
    // more than the runner keeps (`ShellRunner.OutputBounds`); the session's limiter caps what
    // the model reads and spills the rest, so nothing is cut again here.
    let output = sandbox == nil ? outcome.output : Self.annotatingSandboxDenials(outcome.output)
    if outcome.cancelled {
      return "[interrupted by user]\n\(output)"
    }
    if outcome.timedOut {
      let alternative = jobs == nil ? "" : " or run it with background: true"
      return "error: command timed out after \(timeout)s and was killed (its process tree too)"
        + " — raise timeout_seconds (up to \(Self.maxTimeoutSeconds))\(alternative)\n\(output)"
    }
    return "exit \(outcome.exitStatus)\n\(output)"
  }

  /// The `bash` result for a job that just started: the id the `job` tool takes, the pid, the
  /// log path, and what to do next.
  static func startedLine(for job: JobRegistry.Job) -> String {
    "job \(job.id) started (pid \(job.pid)); output → \(job.logURL.path). "
      + "Poll with job(id: \"\(job.id)\") for its status and new output, job(id, action: wait) to "
      + "block until it exits (up to wait_seconds), job(id, action: kill) to stop it. "
      + "It is killed when this session ends."
  }

  /// What the kernel says when the sandbox refuses an operation. Terse and identical to an
  /// ordinary permission error, which is why it needs a translation.
  static let sandboxDenialMarker = "Operation not permitted"

  /// Rewrites every `Operation not permitted` line into an explicit sandbox denial with the
  /// one thing that would fix it. Other lines pass through untouched.
  static func annotatingSandboxDenials(_ output: String) -> String {
    guard output.contains(sandboxDenialMarker) else { return output }
    return output
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { line -> String in
        guard line.contains(sandboxDenialMarker) else { return String(line) }
        return "[arnes sandbox] denied: \(line.trimmingCharacters(in: .whitespaces)) — ask the "
          + "user to widen sandbox.writable / denyRead if this was intended"
      }
      .joined(separator: "\n")
  }
}
