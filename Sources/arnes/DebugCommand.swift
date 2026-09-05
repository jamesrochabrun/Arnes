import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - debug

/// `arnes debug` — introspection of what a run would send, without sending it.
struct Debug: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "debug",
    abstract: "Inspect what a run would send: `debug prompt` renders the exact system prompt and tool list.",
    subcommands: [DebugPrompt.self])
}

// MARK: - debug prompt

/// `arnes debug prompt` — assemble a session exactly as `arnes interactive` would for this
/// directory (runtime, trust gate, instruction files, `# Environment`, base tools, skills,
/// agents, MCP, an `--agent` lead's role), then print the system prompt the *next request
/// would carry* — `Session.renderedSystemPrompt()`, the same `systemText` the dialect steps
/// send, not a copy — with section markers and sizes, and the tool definitions. Nothing is
/// sent: the session is never `start`ed, so no hook fires and no record is written.
struct DebugPrompt: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "prompt",
    abstract: "Render the system prompt and tool list a session here would send, with per-section sizes (the bloat lint for packs and AGENTS.md).",
    discussion: """
      Builds the session the way `arnes interactive` does — the same runtime, trust gate,
      AGENTS.md/CLAUDE.md discovery, # Environment block, tools, skills, agents and MCP
      servers (connected, listed, shut down) — and prints what the first request would
      carry. No model request is made (the manifest is fetched, MCP servers start unless
      --no-mcp, the environment block runs its git probe), no hook fires, nothing is recorded. Token counts are
      chars/4, an estimate.

        arnes debug prompt
        arnes debug prompt -m deepseek/deepseek-chat --bare
        arnes debug prompt --agent reviewer --json
        arnes debug prompt --permission-mode acceptEdits --effort high --add-dir ../lib --disallowed-tools bash

      The run's own flags are mirrored (--add-dir, --effort, --permission-mode, --agents,
      --allowed-tools/--disallowed-tools, -C, --append-system-prompt[-file]), so the prompt
      here is the one that run would send. The tool table lists the set *offered* to the
      model — a `view_image` the manifest withholds from a text model is named, not silent.
      """)

  @Option(name: .shortAndLong, help: "Model slug or alias (default: the provider's default model).")
  var model: String?

  @Option(help: "Wire dialect to report (auto, chat, messages, responses). Informational — the prompt text is the same.")
  var dialect = "auto"

  @Option(help: "Render the prompt of a run led by this agent (its role suffix, toolset and posture), as `do --agent` would.")
  var agent: String?

  @Flag(name: .customLong("no-skills"), help: "Skip skills and the skill tool.")
  var noSkills = false

  @Flag(name: .customLong("no-agents"), help: "Skip subagents and the task tool.")
  var noAgents = false

  @Flag(name: .customLong("no-mcp"), help: "Skip MCP servers.")
  var noMcp = false

  @Flag(name: .customLong("no-memory"), help: "Skip the project's memory (the # Memory section).")
  var noMemory = false

  @Flag(help: "No MCP, skills, subagents, hooks, project instruction files or memory — the prompt of `do --bare`.")
  var bare = false

  @Flag(name: .customLong("trust-project"), help: "Load this directory's own skills, agents and instruction files (and remember the trust).")
  var trustProject = false

  @Flag(help: "Print one JSON object {model, dialect, provider, system_prompt, sections, tools, withheld_tools, approx_tokens_total} instead of text.")
  var json = false

  @Option(
    name: .customLong("add-dir"),
    help: ArgumentHelp(
      "Also treat this directory as inside the run (the REPL's --add-dir): the path rules and the sandbox the environment block describes widen to it. Repeatable.",
      valueName: "path"))
  var addDir: [String] = []

  @Option(help: "Reasoning effort the run would set (minimal, low, medium, high, xhigh, max, none); wins over an --agent's frontmatter, as on `do`. Folds into the think gate the offered tool set reflects.")
  var effort: String?

  @Option(name: .customLong("permission-mode"), help: "Permission mode the run would start under: default, acceptEdits, plan, or bypass — as the REPL would run it (a consenting human), so the # Environment block says the mode.")
  var permissionMode: String?

  @Option(
    help: ArgumentHelp(
      "Inline agent definitions (Claude Code's JSON, or @path to a file), merged with the discovered ones for --agent and the task tool; an inline agent shadows a discovered one of the same name.",
      valueName: "json|@path"))
  var agents: String?

  @Option(
    name: .customLong("allowed-tools"),
    help: ArgumentHelp(
      "Keep only these tools (exact names or prefix globs; Claude Code spellings accepted). Repeatable or comma-separated; \"\" means no tools.",
      valueName: "names"))
  var allowedTools: [String] = []

  @Option(
    name: .customLong("disallowed-tools"),
    help: ArgumentHelp(
      "Remove these tools (disallow wins where both name a tool). `--disallowed-tools task` removes delegation.",
      valueName: "names"))
  var disallowedTools: [String] = []

  @Option(
    name: [.customShort("C"), .customLong("cwd")],
    help: ArgumentHelp(
      "Render for this directory: instruction files, trust, memory, the sandbox root and the environment block all follow it.",
      valueName: "dir"))
  var workingDirectoryPath: String?

  @Option(
    name: .customLong("append-system-prompt"),
    help: ArgumentHelp("Append this text to the system prompt, where `do`/`interactive` place it (after the --agent role).", valueName: "text"))
  var appendSystemPrompt: String?

  @Option(
    name: .customLong("append-system-prompt-file"),
    help: ArgumentHelp("Append this file's contents to the system prompt (after --append-system-prompt; 64 KB cap).", valueName: "path"))
  var appendSystemPromptFile: String?

  @OptionGroup var providerOptions: ProviderOptions
  @OptionGroup var mcpOptions: MCPOptions

  /// What `do` refuses at parse time, refused here too: a bad dialect, effort or mode, malformed
  /// `--agents` JSON, a missing or oversized appendix file — before anything connects.
  func validate() throws {
    _ = try parseDialect(dialect)
    _ = try parseEffort(effort)
    _ = try parsePermissionMode(permissionMode)
    _ = try Do.parseInlineAgents(agents, relativeTo: workingDirectoryPath)
    _ = try Do.systemPromptAppendix(
      text: appendSystemPrompt, file: appendSystemPromptFile, relativeTo: workingDirectoryPath)
  }

  func run() async throws {
    if let workingDirectoryPath {
      try Do.changeDirectory(to: workingDirectoryPath)
    }
    let assembled = try await Self.assemble(
      model: model, dialect: try parseDialect(dialect), agent: agent,
      noSkills: noSkills || bare, noAgents: noAgents || bare, noMcp: noMcp || bare, bare: bare,
      trustProject: trustProject, providerOptions: providerOptions, mcpOptions: mcpOptions,
      noMemory: noMemory || bare,
      addDir: addDir,
      effort: try parseEffort(effort),
      permissionMode: try parsePermissionMode(permissionMode),
      inlineAgents: try Do.parseInlineAgents(agents),
      allowedTools: allowedTools,
      disallowedTools: disallowedTools,
      appendix: try Do.systemPromptAppendix(text: appendSystemPrompt, file: appendSystemPromptFile))
    let report = PromptReport(
      model: assembled.model, dialect: assembled.dialect, provider: assembled.provider,
      prompt: assembled.prompt, tools: assembled.tools, withheldTools: assembled.withheldTools)
    if json {
      try JSONOut.print(report)
    } else {
      for line in report.textLines() { print(line) }
    }
  }

  /// What `assemble` produced: the prompt as the next request would carry it, the tool
  /// definitions in send order, and the labels the report prints.
  struct Assembled {
    let model: String
    /// The dialect the run would actually execute on: the override, or `.auto`'s choice for the
    /// model narrowed by the provider's `nativeDialects` and the conformance store.
    let dialect: String
    let provider: String
    let prompt: String
    /// The definitions the first request would carry — the *offered* set for the model
    /// (`Session.availableToolDefinitions()`), not the whole toolset.
    let tools: [Tool]
    /// The toolset's tools the model is not offered (a `CapabilityGatedTool` its manifest
    /// rules out — `view_image` for a text model), by name.
    let withheldTools: [String]
  }

  /// The REPL's assembly, step for step (`Interactive.run`, in order) — a copy, not an edit
  /// of that function; the follow-up is to lift both into one helper. Steps mirrored:
  /// runtime · model · MCP connect · subprocess env + path rules + sandbox (interactive posture:
  /// opt-in) · base tools · trust gate (headless-style: no prompt) · permission rules ·
  /// instruction files · hooks · `--agent` lead (role, toolset, posture via the `Do` statics) ·
  /// `Session.Configuration` + `applyLimits` · `# Environment` block · skills + skill tool ·
  /// agents + task tool · `Session`. Never `start`ed, never sent.
  static func assemble(
    model modelFlag: String?,
    dialect: DialectOverride,
    agent agentName: String?,
    noSkills: Bool,
    noAgents: Bool,
    noMcp: Bool,
    bare: Bool,
    trustProject: Bool,
    providerOptions: ProviderOptions,
    mcpOptions: MCPOptions,
    noMemory: Bool = false,
    addDir: [String] = [],
    effort: Reasoning.Effort? = nil,
    permissionMode: PermissionMode = .default,
    inlineAgents: [AgentDefinition] = [],
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    appendix: String? = nil)
    async throws -> Assembled
  {
    let runtime = try ArnesRuntime.make(providerOptions)
    let cwd = ArnesRuntime.workingDirectory
    // Everything the assembly says goes to stderr: stdout is the prompt (or the one document).
    let say: (String) -> Void = { JSONOut.stderr($0) }
    // The repository's .mcp.json joins as the REPL loads it — in a trusted directory only, as
    // untrusted servers (X9). The gate itself runs below (its `--trust-project` side effect
    // must happen once), so the answer is read here without it: the flag, or remembered trust.
    let projectTrusted = !bare && (trustProject || ProjectTrustStore().isTrusted(cwd))
    let mcp = try await MCPSetup.connect(
      enabled: !noMcp, options: mcpOptions, quiet: true,
      redacting: runtime.redactedEnvironmentKeys,
      project: projectTrusted ? MCPConfig.projectURL(for: cwd, options: runtime.instructionOptions) : nil,
      output: say)
    // Connected servers are listed, then shut down — on the failure path too.
    do {
      let assembled = try await assemble(
        runtime: runtime, cwd: cwd, mcpTools: mcp.tools, say: say, model: modelFlag, dialect: dialect,
        agent: agentName, noSkills: noSkills, noAgents: noAgents, bare: bare, trustProject: trustProject,
        noMemory: noMemory, addDir: addDir, effort: effort, permissionMode: permissionMode,
        inlineAgents: inlineAgents, allowedTools: allowedTools, disallowedTools: disallowedTools,
        appendix: appendix)
      await mcp.provider.shutdown()
      return assembled
    } catch {
      await mcp.provider.shutdown()
      throw error
    }
  }

  private static func assemble(
    runtime: ArnesRuntime,
    cwd: URL,
    mcpTools: [any AgentTool],
    say: (String) -> Void,
    model modelFlag: String?,
    dialect: DialectOverride,
    agent agentName: String?,
    noSkills: Bool,
    noAgents: Bool,
    bare: Bool,
    trustProject: Bool,
    noMemory: Bool = false,
    addDir: [String] = [],
    effort: Reasoning.Effort? = nil,
    permissionMode: PermissionMode = .default,
    inlineAgents: [AgentDefinition] = [],
    allowedTools: [String] = [],
    disallowedTools: [String] = [],
    appendix: String? = nil)
    async throws -> Assembled
  {
    if let failure = await runtime.manifestWarning() { say(ANSI.yellow(TerminalText.sanitize(failure))) }
    if let warning = runtime.sandboxSupportWarning { say(ANSI.yellow(warning)) }
    if let warning = runtime.hooksWarning { say(ANSI.yellow(TerminalText.sanitize(warning))) }
    let subprocessEnvironment = runtime.subprocessEnvironment
    // Memory as the REPL has it: the carve-out on the rules and the sandbox, the section below.
    let memoryStore = noMemory ? nil : runtime.memoryStore(workdir: cwd)
    // `--add-dir` widens what counts as inside, as the REPL's does (after `-C` changed the cwd).
    let addedDirectories = try ArnesRuntime.parseAddedDirectories(addDir)
    let pathRules = runtime.pathRules(addedDirectories: addedDirectories, memoryRoot: memoryStore?.directory)
    let sandboxResolution = runtime.sandboxResolution(
      root: cwd, addedDirectories: addedDirectories, memoryRoot: memoryStore?.directory)
    let sandbox = sandboxResolution.sandbox
    if let warning = runtime.sandboxDenyReadWarning(sandboxResolution) { say(ANSI.yellow(TerminalText.sanitize(warning))) }
    // A job registry as the REPL has one, so the `job` tool shows in the report; nothing runs.
    let baseTools = HarnessAssembly.coreTools(ToolContext(
      sandbox: sandbox, environment: subprocessEnvironment, pathRules: pathRules,
      bashOutputChars: runtime.limits.effectiveBashOutputChars, jobs: runtime.jobRegistry(),
      bashTimeoutSeconds: runtime.limits.effectiveBashTimeoutSeconds, web: runtime.webPolicy))
    let trust = ProjectTrustGate.evaluate(
      trustFlag: trustProject, interactive: false, cwd: cwd,
      instructionOptions: runtime.instructionOptions, print: say)
    if let notice = trust.notice, !bare { say(ANSI.dim(notice)) }
    let includeProject = trust.includeProject && !bare
    if let warning = runtime.rulesWarning { say(ANSI.yellow(TerminalText.sanitize(warning))) }
    let permissionRules = runtime.permissionRules(includeProject: includeProject, workdir: cwd).rules
    let instructions = bare
      ? nil
      : ProjectInstructions.discovered(includeProject: includeProject, options: runtime.instructionOptions)
    let hooks = bare ? LoadedHooks() : runtime.hooks(cwd: cwd, trusted: includeProject)
    for notice in hooks.notices { say(ANSI.yellow(TerminalText.sanitize(notice))) }
    // `--agent`: the pool `do --agent` sees (built-ins + user-global + a trusted project's).
    // `--agents` definitions join the discovered pool (inline wins by name), for the lead and
    // the task tool alike — `do`'s merge.
    for inline in inlineAgents {
      for warning in inline.warnings { say(ANSI.yellow(TerminalText.sanitize("⚠ agent '\(inline.name)': \(warning)"))) }
    }
    let agents = noAgents
      ? []
      : AgentLibrary.merge(inline: inlineAgents, discovered: AgentLibrary.discover(includeProject: includeProject))
    let lead: AgentDefinition? = try agentName.map { name in
      let pool = AgentLibrary.merge(
        inline: inlineAgents,
        discovered: bare ? AgentDefinition.builtins : AgentLibrary.discover(includeProject: includeProject))
      return try Do.resolveLeadAgent(named: name, in: pool)
    }
    for warning in lead?.warnings ?? [] { say(ANSI.yellow(TerminalText.sanitize("⚠ agent \(lead?.name ?? ""): \(warning)"))) }
    let model = try await Do.resolveLeadModel(flag: modelFlag, resumed: nil, agent: lead, runtime: runtime)
    // The REPL is a consenting human, so its posture is `yes: true` under the requested mode
    // (`--permission-mode`, default by default); a read-only agent still narrows it (never
    // widen), and the # Environment block then says `read-only`.
    let posture = Do.leadPosture(agent: lead, mode: permissionMode, safe: false, yes: true)
    var configuration = Session.Configuration(
      model: model,
      dialect: dialect,
      systemSuffix: Do.composeSystemSuffix(agent: lead, appendix: appendix),
      projectInstructions: instructions?.text,
      hooks: hooks.active,
      // The flag wins over the agent's frontmatter, as on `do`.
      reasoningEffort: effort ?? lead?.effort,
      provider: runtime.traits,
      subprocessEnvironment: subprocessEnvironment,
      workingDirectory: cwd,
      permissionMode: posture.mode,
      permissionRules: permissionRules,
      hookPromptRunner: runtime.promptHookRunner)
    runtime.applyLimits(to: &configuration)
    configuration.pathRules = pathRules
    if let facts = runtime.environmentFacts(sandbox: sandbox) {
      configuration.extraSystemSections = [
        await EnvironmentContext.block(for: configuration, facts: facts, readOnly: posture.readOnly),
      ]
    }
    if let memoryStore {
      configuration.extraSystemSections.append(memoryStore.promptSection())
    }
    let skills = noSkills ? [] : SkillLibrary.discover(includeProject: includeProject)
    let skillTools: [any AgentTool] = skills.isEmpty ? [] : [SkillTool(skills: skills, listingMaxBytes: runtime.skillListingMaxBytes)]
    let scoped = try Do.scopedTools(
      baseTools + skillTools + mcpTools, allowed: allowedTools, disallowed: disallowedTools, agent: lead)
    let taskTool: TaskTool? = agents.isEmpty || !Do.taskToolPermitted(allowed: allowedTools, disallowed: disallowedTools, agent: lead)
      ? nil
      : TaskTool(
        agents: agents,
        service: runtime.service,
        tools: baseTools + skillTools + mcpTools,
        permissions: DenyMutationsPermissions(),
        catalog: runtime.catalog,
        defaults: runtime.subagentDefaults,
        environment: ProcessInfo.processInfo.environment,
        environmentContext: runtime.environmentFacts(sandbox: sandbox),
        skills: skills,
        memory: memoryStore,
        configuration: configuration)
    let tools = scoped + (taskTool.map { [$0] } ?? [])
    // A session that is never started: no SessionStart hook, no transcript, no record.
    let session = Session(
      service: runtime.service,
      tools: tools,
      permissions: DenyMutationsPermissions(),
      catalog: runtime.catalog,
      configuration: configuration)
    // The live-session bindings the REPL and `do` make once their session exists — the `fork`
    // built-in is listed only while `parentHistory` is bound, so without them the `# Subagents`
    // section here would not be the one a request carries.
    taskTool?.parentModel = { await session.model }
    taskTool?.parentSessionId = session.id
    taskTool?.parentHistory = { (await session.history, await session.compactionSummary) }
    let prompt: String
    do {
      prompt = try await session.renderedSystemPrompt()
    } catch {
      throw ValidationError("could not resolve \(model) against the manifest: \(error)")
    }
    // The offered set — what the request carries for this model — against the toolset, so a
    // withheld `view_image` is named (H1).
    let definitions: [Tool]
    do {
      definitions = try await session.availableToolDefinitions()
    } catch {
      throw ValidationError("could not resolve \(model) against the manifest: \(error)")
    }
    let offeredNames = Set(definitions.map(\.function.name))
    let withheldTools = await session.toolDefinitions.map(\.function.name).filter { !offeredNames.contains($0) }
    let profile = try await runtime.catalog.profile(for: model)
    var effective = dialect.effective(for: profile)
    if dialect == .auto, effective != .chat,
       !runtime.traits.nativeDialects || DialectVerdictStore().isKnownBad(model: model, dialect: effective)
    {
      effective = .chat
    }
    return Assembled(
      model: model, dialect: effective.rawValue, provider: runtime.provider.name,
      prompt: prompt, tools: definitions, withheldTools: withheldTools)
  }
}

// MARK: - PromptReport

/// The rendered prompt cut at its top-level `# ` headings, with sizes — pure over the
/// strings, so the splitter and the size table are tested without a session.
struct PromptReport: Encodable {
  struct Section: Encodable, Equatable {
    let title: String
    let chars: Int
    let approxTokens: Int
    /// The section's text, heading line included (omitted from the JSON — `system_prompt`
    /// carries the whole).
    let text: String

    enum CodingKeys: String, CodingKey {
      case title, chars
      case approxTokens = "approx_tokens"
    }
  }

  struct ToolEntry: Encodable, Equatable {
    let name: String
    let description: String
    let parameters: JSONValue?
    let required: [String]
    /// Every declared parameter name, in schema order where the schema keeps one (sorted here).
    let parameterNames: [String]

    enum CodingKeys: String, CodingKey {
      case name, description, parameters, required
      case parameterNames = "parameter_names"
    }
  }

  let model: String
  let dialect: String
  let provider: String
  let systemPrompt: String
  let sections: [Section]
  /// The tools *offered* to the model (the request's set).
  let tools: [ToolEntry]
  /// H1: the toolset's tools the model is not offered, by name (additive; `[]` when none).
  let withheldTools: [String]
  let approxTokensTotal: Int

  enum CodingKeys: String, CodingKey {
    case model, dialect, provider, sections, tools
    case systemPrompt = "system_prompt"
    case withheldTools = "withheld_tools"
    case approxTokensTotal = "approx_tokens_total"
  }

  init(model: String, dialect: String, provider: String, prompt: String, tools: [Tool], withheldTools: [String] = []) {
    self.model = model
    self.dialect = dialect
    self.provider = provider
    systemPrompt = prompt
    sections = Self.split(prompt)
    self.tools = tools.map(Self.entry)
    self.withheldTools = withheldTools
    let toolChars = self.tools.reduce(0) { $0 + Self.chars(of: $1) }
    approxTokensTotal = Self.approxTokens(prompt.count + toolChars)
  }

  /// chars/4 — the usual rough estimate; the report says it is one.
  static func approxTokens(_ chars: Int) -> Int { (chars + 3) / 4 }

  /// Cuts at every line that starts a top-level markdown heading (`# `). Text before the
  /// first heading is the `(preamble)` section — the pack's base prompt has no heading of
  /// its own. Sizes count the section's characters including its heading line.
  static func split(_ prompt: String) -> [Section] {
    var sections: [Section] = []
    var title = "(preamble)"
    var current: [Substring] = []
    func flush() {
      let text = current.joined(separator: "\n")
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !sections.isEmpty || title != "(preamble)" {
        sections.append(Section(title: title, chars: text.count, approxTokens: approxTokens(text.count), text: text))
      }
    }
    for line in prompt.split(separator: "\n", omittingEmptySubsequences: false) {
      if line.hasPrefix("# ") {
        flush()
        title = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        current = [line]
      } else {
        current.append(line)
      }
    }
    flush()
    return sections.filter { !($0.title == "(preamble)" && $0.chars == 0) }
  }

  static func entry(_ tool: Tool) -> ToolEntry {
    let schema = tool.function.parameters
    let properties = schema?.objectValue?["properties"]?.objectValue ?? [:]
    let required = schema?.objectValue?["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
    return ToolEntry(
      name: tool.function.name,
      description: tool.function.description ?? "",
      parameters: schema,
      required: required,
      parameterNames: properties.keys.sorted())
  }

  /// What a tool definition costs on the wire, roughly: its serialized JSON.
  static func chars(of entry: ToolEntry) -> Int {
    (try? JSONOut.line(entry))?.count ?? (entry.name.count + entry.description.count)
  }

  /// The text view: a rule before each section naming it and its size, the section, the
  /// tool list (name — first line of the description — parameters, required starred), then
  /// the size table sorted largest first. Prompt text is what the model reads; it is
  /// terminal-sanitized before it reaches the terminal.
  func textLines() -> [String] {
    var lines: [String] = []
    lines.append(ANSI.dim("system prompt for \(model) · dialect \(dialect) · provider \(provider) · ~\(approxTokensTotal) tokens (chars/4, an estimate)"))
    for section in sections {
      lines.append(ANSI.secondary("──── \(TerminalText.sanitize(section.title)) (\(section.chars) chars, ~\(section.approxTokens) tokens) ────"))
      lines.append(TerminalText.sanitize(section.text))
    }
    let toolChars = tools.reduce(0) { $0 + Self.chars(of: $1) }
    lines.append(ANSI.secondary("──── tools (\(tools.count), \(toolChars) chars, ~\(Self.approxTokens(toolChars)) tokens) ────"))
    lines.append(ANSI.dim(TerminalText.sanitize(offeredLine)))
    for tool in tools {
      let brief = tool.description.split(separator: "\n").first.map(String.init) ?? ""
      let parameters = tool.parameterNames.map { tool.required.contains($0) ? "\($0)*" : $0 }.joined(separator: ", ")
      lines.append(TerminalText.sanitize("\(tool.name) — \(brief)" + (parameters.isEmpty ? "" : " — \(parameters)")))
    }
    lines.append(ANSI.secondary("──── sizes ────"))
    for row in sizeTable() {
      lines.append(TerminalText.sanitize("\(row.title.padding(toLength: 32, withPad: " ", startingAt: 0)) \(String(row.chars).leftPadded(8)) chars  ~\(String(row.approxTokens).leftPadded(6)) tokens"))
    }
    return lines
  }

  /// `tools: N offered to <model> (M in the toolset; withheld: view_image)` — the request's set
  /// against the toolset, so a text model's missing tool is visible rather than silent.
  var offeredLine: String {
    let withheld = withheldTools.isEmpty ? "none withheld" : "withheld: \(withheldTools.joined(separator: ", "))"
    return "tools: \(tools.count) offered to \(model) (\(tools.count + withheldTools.count) in the toolset; \(withheld))"
  }

  struct SizeRow: Equatable {
    let title: String
    let chars: Int
    let approxTokens: Int
  }

  /// Per section + `tools` + `total`, sections largest first (ties by title), total last.
  func sizeTable() -> [SizeRow] {
    var rows = sections.map { SizeRow(title: $0.title, chars: $0.chars, approxTokens: $0.approxTokens) }
    let toolChars = tools.reduce(0) { $0 + Self.chars(of: $1) }
    rows.append(SizeRow(title: "tools (\(tools.count))", chars: toolChars, approxTokens: Self.approxTokens(toolChars)))
    rows.sort { $0.chars != $1.chars ? $0.chars > $1.chars : $0.title < $1.title }
    let total = systemPrompt.count + toolChars
    rows.append(SizeRow(title: "total", chars: total, approxTokens: Self.approxTokens(total)))
    return rows
  }
}

extension String {
  fileprivate func leftPadded(_ width: Int) -> String {
    count >= width ? self : String(repeating: " ", count: width - count) + self
  }
}
