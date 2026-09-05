import ArgumentParser
import ArnesKit
import Foundation

// MARK: - init

/// `arnes init` — the REPL's `/init` as a one-shot: run the `init` skill (the built-in, or a
/// project/user `SKILL.md` of that name shadowing it) through `arnes do` so it writes this
/// repository's `AGENTS.md`. The command exists to write one in-tree file, so it runs with
/// `--yes --permission-mode acceptEdits` — in-tree writes auto-approved, everything else the
/// headless gate refuses, the sandbox on where the platform enforces one — and with no MCP
/// servers, subagents or memory (an init turn delegates to nobody and touches no server);
/// instruction files DO load, so an existing `AGENTS.md`/`CLAUDE.md` is read before it is
/// improved in place. The turn itself is `Do` — parsed from an argv, so its validate() and
/// its exit codes are the run's.
struct InitCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "init",
    abstract: "Write this repository's AGENTS.md with the `init` skill — a one-shot `arnes do` that edits the file without asking.",
    discussion: """
      Runs the same skill `/init` runs in the REPL (a project or user SKILL.md named `init`
      shadows the built-in) as one headless turn: the model inspects the repo — README,
      manifests, CI, any instructions already there — and writes or improves `AGENTS.md`
      (≤ 100 lines: verified build/test commands, a layout map, conventions, doc pointers).
      It writes without asking (--yes, in-tree edits auto-approved; reads and writes outside
      the tree stay refused) and loads no MCP servers, subagents or memory. Exit codes are
      `arnes do`'s: 0 done · 1 error · 3 stopped short (--max-steps, --budget) · 64 usage.

        arnes init                      # this directory, the provider's default model
        arnes init -m haiku --budget 0.20
        arnes init -C ../other-repo --trust-project
      """)

  @Option(name: .shortAndLong, help: "Model slug or alias (default: the provider's default model).")
  var model: String?

  @Option(help: "Reasoning effort for models that support it: minimal, low, medium, high, xhigh, max, none.")
  var effort: String?

  @Option(help: "Stop once the run's cost reaches this many USD.")
  var budget: Double?

  @Option(name: .customLong("max-steps"), help: "Stop the turn after this many model steps (default 40 — an init reads a dozen files and writes one).")
  var maxSteps = 40

  @Option(
    name: [.customShort("C"), .customLong("cwd")],
    help: ArgumentHelp("Write the AGENTS.md of this directory (tools, trust and instruction files follow it).", valueName: "dir"))
  var workingDirectoryPath: String?

  @Flag(help: "Load this directory's own .arnes/.claude skills (a project `init` skill shadows the built-in) and instruction files, and remember it as trusted.")
  var trustProject = false

  @Option(name: .customLong("output-format"), help: "text (default) · json (one result object) · stream-json (init, every event, the result) — `arnes do`'s formats.")
  var outputFormat: HeadlessOutputFormat = .text

  @Flag(help: "With a JSON output format: mirror the text progress lines to stderr.")
  var verbose = false

  @Option(help: "Wire dialect: auto (native per model family), chat, messages, or responses.")
  var dialect = "auto"

  @Flag(help: "Run unconfined: skip the OS sandbox that otherwise wraps this unattended run.")
  var noSandbox = false

  @OptionGroup var providerOptions: ProviderOptions
  @OptionGroup var mcpOptions: MCPOptions

  /// The name of the skill this command runs — the REPL's `/init`.
  static let skillName = "init"

  func validate() throws {
    _ = try parseEffort(effort)
    _ = try parseDialect(dialect)
    if maxSteps < 1 {
      throw ValidationError("--max-steps must be at least 1.")
    }
    if let budget, !(budget > 0) {
      throw ValidationError("--budget must be a positive number of USD.")
    }
  }

  func run() async throws {
    if let workingDirectoryPath {
      try Do.changeDirectory(to: workingDirectoryPath)
    }
    let runtime = try ArnesRuntime.make(providerOptions)
    let cwd = ArnesRuntime.workingDirectory
    // The skill the REPL's `/init` would run: a trusted project's or the user's `init`
    // SKILL.md shadows the built-in. The trust *decision* is read here without the gate's side
    // effect — `do --trust-project` below runs the gate itself (recording the trust, printing
    // the headless skip notice), so it is asked once.
    let includeProject = trustProject || ProjectTrustStore().isTrusted(cwd)
    let skills = SkillLibrary.discover(includeProject: includeProject)
    guard let skill = skills.first(where: { $0.name == Self.skillName }) else {
      throw ValidationError("no `\(Self.skillName)` skill found — the built-in should always be there")
    }
    let resolvedModel = try runtime.model(model)
    FileHandle.standardError.write(Data((TerminalText.sanitize(
      "arnes init: writing AGENTS.md for \(cwd.path) with \(resolvedModel) (the \(Self.skillName) skill; edit the result)") + "\n").utf8))
    // The turn is `arnes do`'s, parsed from an argv so validate() and the option groups are
    // wired as for a typed command (never a hand-built `Do()`).
    let command = try Do.parse(Self.doArguments(
      prompt: skill.invocationPrompt(arguments: nil),
      model: resolvedModel,
      effort: effort,
      budget: budget,
      maxSteps: maxSteps,
      trustProject: trustProject,
      outputFormat: outputFormat,
      verbose: verbose,
      dialect: dialect,
      noSandbox: noSandbox,
      provider: providerOptions.provider,
      mcpConfig: mcpOptions.mcpConfig,
      strictMcpConfig: mcpOptions.strictMcpConfig))
    try await command.run()
  }

  /// The `arnes do` argv an init turn runs as — pure, so a test can parse it back: the skill's
  /// invocation prompt as the task, then `--yes --permission-mode acceptEdits` (in-tree writes
  /// auto-approved, the sandbox on), `--no-mcp --no-agents --no-memory` (never `--bare`:
  /// instruction files must load so an existing AGENTS.md is read first), the step cap, the
  /// dialect and output format, and every pass-through flag that was set.
  static func doArguments(
    prompt: String,
    model: String?,
    effort: String?,
    budget: Double?,
    maxSteps: Int,
    trustProject: Bool,
    outputFormat: HeadlessOutputFormat,
    verbose: Bool,
    dialect: String,
    noSandbox: Bool,
    provider: String?,
    mcpConfig: String?,
    strictMcpConfig: Bool)
    -> [String]
  {
    var argv = [
      prompt,
      "--yes", "--permission-mode", "acceptEdits",
      "--no-mcp", "--no-agents", "--no-memory",
      "--max-steps", String(maxSteps),
      "--dialect", dialect,
      "--output-format", outputFormat.rawValue,
    ]
    if let model { argv += ["-m", model] }
    if let effort { argv += ["--effort", effort] }
    if let budget { argv += ["--budget", String(budget)] }
    if trustProject { argv.append("--trust-project") }
    if verbose { argv.append("--verbose") }
    if noSandbox { argv.append("--no-sandbox") }
    if let provider { argv += ["--provider", provider] }
    if let mcpConfig { argv += ["--mcp-config", mcpConfig] }
    if strictMcpConfig { argv.append("--strict-mcp-config") }
    return argv
  }
}
