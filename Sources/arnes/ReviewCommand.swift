import ArgumentParser
import ArnesKit
import Foundation

// MARK: - review

/// `arnes review` — a read-only diff review with structured findings (X6). The command type is
/// `ReviewCommand` because the Kit's `Review` enum owns the framing, task text, exit rule and
/// renderer; the subcommand is still spelled `review`.
struct ReviewCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "review",
    abstract: "Review a diff read-only and report structured findings (uncommitted changes by default).",
    discussion: """
      The reviewer gets read_file, grep, glob, think and bash — bash's read-only commands \
      (git log, git blame, cat) run, every mutation is refused — and nothing the repository \
      ships: no MCP servers, skills, subagents, hooks or instruction files, so a change under \
      review cannot inject into its own reviewer. --allow-run lets it execute (run tests, \
      builds) and needs the OS sandbox: it is refused where the platform cannot confine the \
      run. The review runs at the repository root whichever subdirectory it was started in.

      Exit codes: 0 no finding at or above --fail-on (or --fail-on unset) · 1 error · \
      2 a finding at or above --fail-on · 3 the run stopped short (max_steps, budget, or no \
      valid findings object came back) · 64 usage (not a repository, an unknown ref, an \
      empty diff, a bad flag) · 130 interrupted (SIGINT) · 143 terminated (SIGTERM).
      """)

  @Flag(help: "Review the working tree against HEAD — staged, unstaged and untracked files (the default).")
  var uncommitted = false

  @Option(help: ArgumentHelp("Review the commits since the merge-base with this ref (a pull request against it).", valueName: "ref"))
  var base: String?

  @Option(help: ArgumentHelp("Review one commit's own changes.", valueName: "sha"))
  var commit: String?

  @Option(name: .shortAndLong, help: "Model slug (default: the provider's default model). A 60 KB diff is ~15k tokens per step — pick a cheap one.")
  var model: String?

  @Option(help: ArgumentHelp("What to look at in particular; rides the task as a note from the requester.", valueName: "text"))
  var focus: String?

  @Flag(help: "Print one JSON document with the findings instead of the text rendering (progress stays off stdout; --verbose mirrors it to stderr).")
  var json = false

  @Option(name: .customLong("fail-on"), help: "Exit 2 when any finding is at or above this severity: low, medium or high. Unset: exit 0 whatever was found.")
  var failOn: String?

  @Flag(name: .customLong("allow-run"), help: "Let the reviewer run commands and write inside the tree (tests, builds). Needs the OS sandbox — refused where the platform cannot enforce one.")
  var allowRun = false

  @Option(name: .customLong("max-steps"), help: "Stop the review after this many model steps (default 20) — stop_reason max_steps, exit 3.")
  var maxSteps: Int?

  @Option(help: "Stop once the review's cost reaches this many USD.")
  var budget: Double?

  @Option(
    name: [.customShort("C"), .customLong("cwd")],
    help: ArgumentHelp("Review the repository containing this directory.", valueName: "dir"))
  var workingDirectoryPath: String?

  @Flag(help: "With --json: mirror the text progress lines to stderr.")
  var verbose = false

  @Flag(name: .customLong("no-sandbox"), help: "Run the read-only review unconfined (the git commands and bash included). Never with --allow-run.")
  var noSandbox = false

  @OptionGroup var providerOptions: ProviderOptions

  /// Refusals that cost no side effect: ArgumentParser runs this before `run()`.
  func validate() throws {
    if base != nil, commit != nil {
      throw ValidationError("--base and --commit don't combine: review a branch against its base, or one commit.")
    }
    if uncommitted, base != nil || commit != nil {
      throw ValidationError("--uncommitted and --base/--commit don't combine: pick one target.")
    }
    if let maxSteps, maxSteps < 1 {
      throw ValidationError("--max-steps must be at least 1.")
    }
    _ = try Self.parseFailOn(failOn)
    if allowRun, noSandbox {
      throw ValidationError("--allow-run needs the OS sandbox; --no-sandbox contradicts it. A reviewer that may run commands runs confined or not at all.")
    }
  }

  /// `--fail-on` → a severity; unset → nil; anything else a usage error.
  static func parseFailOn(_ raw: String?) throws -> ReviewFinding.Severity? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let severity = ReviewFinding.Severity(rawValue: raw.lowercased()) else {
      throw ValidationError("unknown --fail-on '\(raw)' — use low, medium or high")
    }
    return severity
  }

  /// The target the flags name; `--uncommitted` when none does.
  var target: ReviewTarget {
    if let base { return .base(base) }
    if let commit { return .commit(commit) }
    return .uncommitted
  }

  /// The reason the read-only delegate hands the model for every refused mutation.
  static let readOnlyReason = "review is read-only — report what you would change instead of changing it"

  /// Why `--allow-run` is refused: the platform has no sandbox backend, or the config switched
  /// the one it has off.
  static func allowRunRefusal(supported: Bool) -> String {
    "--allow-run needs the OS sandbox: "
      + (supported
        ? "the provider's `sandbox` block disables it (set \"enabled\": true, or drop the block)."
        : "this platform can't enforce one (macOS needs /usr/bin/sandbox-exec; Linux is not wired yet).")
  }

  /// Whether `root` is the home directory or one of its ancestors — the stray-`.git`-in-`$HOME`
  /// case, where `ls-files --others` lists the user's whole home. Symlinks resolved on both
  /// sides; `home` injectable for tests.
  static func isHomeOrAncestor(_ root: URL, home: String = NSHomeDirectory()) -> Bool {
    let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
    let resolvedHome = URL(fileURLWithPath: home).standardizedFileURL.resolvingSymlinksInPath().path
    return resolvedRoot == "/" || resolvedRoot == resolvedHome || resolvedHome.hasPrefix(resolvedRoot + "/")
  }

  func run() async throws {
    if let workingDirectoryPath {
      try Do.changeDirectory(to: workingDirectoryPath)
    }
    let stderr = FileHandle.standardError
    let failOnSeverity = try Self.parseFailOn(self.failOn)
    // `--allow-run` needs a sandbox the platform can enforce. Checked first: on a platform
    // without one, a configured `sandbox` block would make the git probe below fail closed
    // (`git failed: …`) before the message that names the real reason.
    if allowRun, !ShellSandbox.isSupported {
      throw ValidationError(Self.allowRunRefusal(supported: false))
    }
    let runtime = try ArnesRuntime.make(providerOptions)
    let cwd = ArnesRuntime.workingDirectory
    // Every git the review runs — the builder's and the model's own through bash — carries
    // the pins that keep the repository's configuration from running a command (diff.external,
    // core.fsmonitor, log.showSignature, core.pager).
    let environment = ReviewDiff.pinningGit(runtime.subprocessEnvironment)
    // The same path rules the tools get: an untracked file lands in the diff only where
    // read_file would read it freely (never a credential location or a paths.denyRead match).
    let pathRules = runtime.pathRules()
    // A review is unattended — nobody answers a prompt — so it is confined by default where
    // the platform can enforce it, like `do --yes`; `--no-sandbox` opts the read-only run out.
    // The git commands run under the same sandbox the tools will get.
    let probeSandbox = noSandbox ? nil : runtime.sandboxResolution(root: cwd, autonomous: true).sandbox
    let built: ReviewDiff.Built
    do {
      built = try await ReviewDiff.build(
        target: target, cwd: cwd, sandbox: probeSandbox, environment: environment, rules: pathRules)
    } catch let error as ReviewError {
      // Nothing has been spent: a usage error, before any model request.
      throw ValidationError(error.description)
    }
    // The review runs at the repository root: every path in the diff is relative to it, so
    // the tools, the sandbox and the environment block are rooted there too.
    let root = URL(fileURLWithPath: built.root)
    let resolution = runtime.sandboxResolution(root: root, autonomous: true)
    let sandbox = noSandbox ? nil : resolution.sandbox
    if allowRun, sandbox == nil {
      throw ValidationError(Self.allowRunRefusal(supported: true))
    }
    if Self.isHomeOrAncestor(root) {
      stderr.write(Data((ANSI.yellow(
        "⚠ the repository root is \(built.root) — your home directory or above it; every un-ignored "
          + "file under it is a candidate for the diff (credential locations and paths.denyRead "
          + "matches are skipped, the rest is not)") + "\n").utf8))
    }
    if noSandbox, resolution.sandbox != nil {
      stderr.write(Data((ANSI.red(ArnesRuntime.sandboxOptOutWarning) + "\n").utf8))
    }
    if let warning = runtime.sandboxDenyReadWarning(resolution), !noSandbox {
      stderr.write(Data((TerminalText.sanitize(warning) + "\n").utf8))
    }
    if let failure = await runtime.manifestWarning() {
      stderr.write(Data((TerminalText.sanitize(failure) + "\n").utf8))
    }
    let model = try runtime.model(self.model)
    // Posture: read-only unless --allow-run, in which case the judge (if configured) may still
    // veto a risky command — no human reads the prompt.
    let baseDelegate: any PermissionDelegate = allowRun
      ? runtime.judging(AutoApprovePermissions(), headlessVeto: true)
      : DenyMutationsPermissions(reason: Self.readOnlyReason)
    let permissions: any PermissionDelegate = SerializedPermissions(baseDelegate)
    // No job registry: a reviewer runs its tests in the foreground (`background: true` is
    // refused with the reason), so nothing outlives the review.
    let toolContext = ToolContext(
      root: root, sandbox: sandbox, environment: environment,
      pathRules: pathRules, bashOutputChars: runtime.limits.effectiveBashOutputChars,
      bashTimeoutSeconds: runtime.limits.effectiveBashTimeoutSeconds)
    let tools = try Review.tools(from: HarnessAssembly.coreTools(toolContext))
    // A review is `--bare` by construction: no hooks, instructions, skills, MCP or subagents.
    var configuration = Session.Configuration(
      model: model,
      maxStepsPerTurn: maxSteps ?? 20,
      systemSuffix: Review.systemSuffix,
      maxCostUSD: budget,
      agent: Review.agentName,
      provider: runtime.traits,
      subprocessEnvironment: environment,
      workingDirectory: root,
      permissionMode: .default,
      hookPromptRunner: runtime.promptHookRunner,
      outputSchema: try OutputSchema(schema: ReviewFindings.schema))
    configuration.sessionOrigin = Review.agentName
    runtime.applyLimits(to: &configuration)
    if let facts = runtime.environmentFacts(sandbox: sandbox) {
      configuration.extraSystemSections = [
        await EnvironmentContext.block(for: configuration, facts: facts, readOnly: !allowRun),
      ]
    }
    let agent = Agent(
      service: runtime.service,
      tools: tools,
      permissions: permissions,
      catalog: runtime.catalog,
      configuration: configuration)
    // Progress: the text lines in text mode, nothing on stdout in JSON mode (--verbose mirrors
    // them to stderr). The structured-output event is the review's own to render.
    let emitter = HeadlessEmitter(format: json ? .json : .text, verbose: verbose)
    let onEvent: @Sendable (AgentEvent) -> Void = { event in
      if case .structuredOutput = event { return }
      emitter.emit(event)
    }

    // SIGINT/SIGTERM interrupt the session (the record is appended, the report still prints);
    // a second signal ends the process outright.
    let signals = SignalState()
    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler {
      if signals.note(.sigint) { ArnesExit.terminateProcess(ArnesExit.Signal.sigint.exitCode) }
      agent.interrupt()
    }
    sigintSource.resume()
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    sigtermSource.setEventHandler {
      if signals.note(.sigterm) { ArnesExit.terminateProcess(ArnesExit.Signal.sigterm.exitCode) }
      agent.interrupt()
    }
    sigtermSource.resume()
    defer {
      sigintSource.cancel()
      sigtermSource.cancel()
    }

    let task = Review.task(target: target, built: built, focus: focus)
    let agentResult: AgentResult
    do {
      agentResult = try await agent.run(task: task, model: model, onEvent: onEvent)
    } catch {
      // Text mode: ArgumentParser prints the error, exit 1. JSON: the document says so.
      guard json else { throw error }
      let record = await agent.lastSession?.lastRecord
      try JSONOut.print(ReviewReport(
        target: target, built: built, findings: nil, model: model,
        costUSD: record?.costUSD ?? 0, steps: record?.steps ?? 0,
        stopReason: StopReason.error.rawValue, error: "\(error)"))
      throw ExitCode(ArnesExit.error.rawValue)
    }
    let runResult = RunResult(result: agentResult, costEstimated: runtime.traits.estimatesCost)
    let findings = try agentResult.structuredOutput.map { try ReviewFindings(from: $0) }
    if json {
      try JSONOut.print(ReviewReport(
        target: target, built: built, findings: findings, model: model,
        costUSD: runResult.costUSD, steps: runResult.steps,
        stopReason: runResult.stopReason?.rawValue, error: nil))
    } else {
      print(Self.textReport(findings: findings, prose: agentResult.text, result: runResult))
    }
    // The run's own code first (an error, a signal, a stop short of a findings object); the
    // review's `--fail-on` verdict only when the run itself was clean.
    var code = ArnesExit.code(for: runResult, failOnDenied: false, signal: signals.received)
    if code == ArnesExit.ok.rawValue, let findings {
      code = Review.exitCode(findings: findings, failOn: failOnSeverity)
    }
    if code != ArnesExit.ok.rawValue {
      throw ExitCode(code)
    }
  }

  /// The text mode's report: the rendered findings (or the prose under a notice when no
  /// findings object validated) and the footer.
  static func textReport(findings: ReviewFindings?, prose: String, result: RunResult) -> String {
    var text = ""
    if let findings {
      text += Review.render(findings, sanitize: TerminalText.sanitize)
    } else {
      text += "review did not produce structured findings — the reviewer's reply:\n\n"
      text += TerminalText.sanitize(prose)
    }
    text += "\n" + footer(findings: findings, result: result)
    return text
  }

  /// `[N findings (1 high, 2 medium) · $cost · M steps · model]`.
  static func footer(findings: ReviewFindings?, result: RunResult) -> String {
    let count: String
    if let findings {
      let n = findings.findings.count
      var parts: [String] = []
      for severity in ReviewFinding.Severity.allCases.reversed() {
        let k = findings.findings.filter { $0.severity == severity }.count
        if k > 0 { parts.append("\(k) \(severity.rawValue)") }
      }
      count = "\(n) finding\(n == 1 ? "" : "s")" + (parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))")
    } else {
      count = "no findings object (\(result.stopReason?.rawValue ?? "?"))"
    }
    return TerminalText.sanitize(
      "\n[\(count) · $\(String(format: "%.4f", result.costUSD)) · \(result.steps) steps · \(result.model)]")
  }
}

// MARK: - review --json

/// The one document `arnes review --json` prints. Keys are additive forever, snake_case, every
/// documented key present (`findings`/`summary` are `null` when no findings object validated).
struct ReviewReport: Encodable, Equatable {
  struct Target: Encodable, Equatable {
    let kind: String
    @Nullable var ref: String?

    init(_ target: ReviewTarget) {
      switch target {
      case .uncommitted:
        kind = "uncommitted"
        ref = nil
      case .base(let ref):
        kind = "base"
        self.ref = ref
      case .commit(let sha):
        kind = "commit"
        ref = sha
      }
    }
  }

  var type = "review"
  let target: Target
  let root: String
  let files: [String]
  let untrackedIncluded: [String]
  let skipped: [String]
  let truncatedDiff: Bool
  @Nullable var summary: String?
  @Nullable var findings: [ReviewFinding]?
  let model: String
  let costUSD: Double
  let steps: Int
  @Nullable var stopReason: String?
  @Nullable var error: String?

  init(
    target: ReviewTarget,
    built: ReviewDiff.Built,
    findings: ReviewFindings?,
    model: String,
    costUSD: Double,
    steps: Int,
    stopReason: String?,
    error: String?)
  {
    self.target = Target(target)
    root = built.root
    files = built.files
    untrackedIncluded = built.untrackedIncluded
    skipped = built.skipped
    truncatedDiff = built.truncated
    summary = findings?.summary
    self.findings = findings?.findings
    self.model = model
    self.costUSD = JSONOut.finite(costUSD) ?? 0
    self.steps = steps
    self.stopReason = stopReason
    self.error = error
  }

  enum CodingKeys: String, CodingKey {
    case type, target, root, files
    case untrackedIncluded = "untracked_included"
    case skipped
    case truncatedDiff = "truncated_diff"
    case summary, findings, model
    case costUSD = "cost_usd"
    case steps
    case stopReason = "stop_reason"
    case error
  }
}
