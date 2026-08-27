import Foundation
import OpenRouterSwift

// MARK: - AgentDefinition

/// A subagent: a markdown file with YAML frontmatter (`name`, `description`, optional
/// `model`, optional `tools`) followed by the agent's system prompt, in the same format
/// Claude Code uses for `.claude/agents/*.md` — agents written for other harnesses drop
/// in unchanged.
///
/// The user decides the model: `model:` in the frontmatter (a slug, a fuzzy query like
/// `sonnet`, or `inherit` for the parent's model), overridable per session from the CLI.
public struct AgentDefinition: Sendable, Equatable {
  public let name: String
  /// Drives delegation: the lead model sees only name + description and picks agents
  /// whose description matches the work (progressive disclosure, like skills).
  public let description: String
  /// The subagent's system-prompt body (markdown after the frontmatter).
  public let body: String
  /// Model for this agent: nil means inherit the parent session's model; anything else
  /// is resolved against the manifest at spawn time (never hardcoded).
  public let model: String?
  /// Tool allowlist (arnes names, after aliasing); nil means every parent tool.
  public let tools: [String]?
  /// The `.md` file this came from; nil for the built-in general agent.
  public let source: URL?

  public init(
    name: String,
    description: String,
    body: String,
    model: String? = nil,
    tools: [String]? = nil,
    source: URL? = nil)
  {
    self.name = name
    self.description = description
    self.body = body
    self.model = model
    self.tools = tools
    self.source = source
  }

  /// Always available so the lead model can offload context-heavy side work even
  /// with no agent files installed.
  public static let general = AgentDefinition(
    name: "general",
    description: "General-purpose agent for research, multi-step side tasks, and any "
      + "delegated work that may need the full toolset. Use it to keep large or noisy "
      + "work out of the main context.",
    body: "You are a capable general-purpose agent. Complete the task thoroughly with "
      + "the tools available, then report what you did and found.")

  /// Read-only searcher, mirroring the harness-standard "explore" worker: broad
  /// fan-out over many files where the lead only needs the conclusion.
  public static let explore = AgentDefinition(
    name: "explore",
    description: "Read-only search agent. Use whenever answering means sweeping many "
      + "files or directories (find where X is defined, how Y is used, what handles Z) "
      + "and you only need the conclusion — it keeps the file dumps out of your context. "
      + "It cannot modify anything.",
    body: "You are a read-only code explorer. Search and read exactly what the task "
      + "needs, then report your conclusion with the relevant file paths and line "
      + "references. Quote only the decisive snippets, never whole files.",
    tools: ["read_file", "grep", "glob"])

  /// Built-ins appended by discovery when no agent file shadows their name.
  public static let builtins: [AgentDefinition] = [.general, .explore]
}

// MARK: - AgentLibrary

/// Discovers subagents from disk. Search order (first occurrence of a name wins, so a
/// project can shadow a global agent — and any file can shadow the built-in `general`):
/// 1. `<workdir>/.arnes/agents/*.md`
/// 2. `<workdir>/.claude/agents/*.md`   (ecosystem compatibility — same file format)
/// 3. `~/.arnes/agents/*.md`
public enum AgentLibrary {
  public static func discover(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()))
    -> [AgentDefinition]
  {
    let roots = [
      workdir.appendingPathComponent(".arnes/agents"),
      workdir.appendingPathComponent(".claude/agents"),
      home.appendingPathComponent(".arnes/agents"),
    ]
    var agents: [AgentDefinition] = []
    var seen = Set<String>()
    for root in roots {
      guard let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { continue }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where entry.pathExtension == "md"
      {
        guard let agent = load(file: entry), !seen.contains(agent.name) else { continue }
        seen.insert(agent.name)
        agents.append(agent)
      }
    }
    for builtin in AgentDefinition.builtins where !seen.contains(builtin.name) {
      agents.append(builtin)
    }
    return agents
  }

  /// Parses one agent file. Returns nil when the file is missing or has no body.
  /// Frontmatter parsing is the same deliberate YAML subset skills use: single-line
  /// `key: value` pairs between `---` fences.
  public static func load(file: URL) -> AgentDefinition? {
    guard let raw = try? String(contentsOf: file, encoding: .utf8),
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    var name = file.deletingPathExtension().lastPathComponent
    var description = ""
    var model: String?
    var tools: [String]?
    var body = raw

    let lines = raw.components(separatedBy: "\n")
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
       let close = lines.dropFirst().firstIndex(where: {
         $0.trimmingCharacters(in: .whitespaces) == "---"
       })
    {
      for line in lines[1..<close] {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'"))
        {
          value = String(value.dropFirst().dropLast())
        }
        switch key {
        case "name": if !value.isEmpty { name = value }
        case "description": description = value
        case "model":
          // `inherit` (Claude Code's spelling for "same as the caller") is the default.
          if !value.isEmpty, value.lowercased() != "inherit" { model = value }
        case "tools":
          let names = value.split(separator: ",")
            .map { canonicalToolName(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.isEmpty }
          if !names.isEmpty { tools = names }
        default: break
        }
      }
      body = lines[(close + 1)...].joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !body.isEmpty else { return nil }
    return AgentDefinition(
      name: name, description: description, body: body, model: model, tools: tools,
      source: file)
  }

  /// Maps Claude Code tool names to arnes names so agent files drop in unchanged;
  /// unknown names pass through verbatim (MCP tools keep their full ids). `Task` maps
  /// to nothing — subagents never get the task tool, one level of nesting is the cap.
  static func canonicalToolName(_ raw: String) -> String {
    switch raw.lowercased() {
    case "read": return "read_file"
    case "write": return "write_file"
    case "edit": return "edit_file"
    case "bash": return "bash"
    case "grep": return "grep"
    case "glob": return "glob"
    case "task", "agent": return ""
    default: return raw
    }
  }
}

// MARK: - PrefixedPermissions

/// Wraps the parent's delegate so subagent permission prompts say who is asking.
struct PrefixedPermissions: PermissionDelegate {
  let base: any PermissionDelegate
  let prefix: String

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await base.decide(
      toolName: toolName,
      summary: "\(prefix) → \(summary)",
      argumentsJSON: argumentsJSON)
  }
}

// MARK: - TaskTool

/// The one tool subagents add to the loop. Schema stays dumb — `agent` + `task`, two
/// strings — so non-frontier models survive it; specialization lives in the agent files.
///
/// Each call spawns a nested `Session`: fresh context, the agent's own system prompt and
/// model, tools restricted to its allowlist (and never the task tool itself — one level
/// of nesting is the cap). Only the subagent's final report returns to the caller; its
/// progress streams through `onEvent` wrapped in `.subagent` so UIs can render it nested,
/// its spend drains into the parent turn via `CostReportingTool`, and its run lands in
/// `~/.arnes/runs.jsonl` tagged with the agent name (post-routing models included).
public final class TaskTool: AgentTool, PromptContributing, CostReportingTool, @unchecked Sendable {
  public let name = "task"
  public let description =
    "Delegate a task to a subagent that runs in its own fresh context and returns one "
    + "final report. Use it when a task matches an agent's description, or to keep "
    + "large exploration/side work out of your context. The subagent sees ONLY the "
    + "task text you pass — include all needed context, and say what the report must contain."
  public let permission = ToolPermission.readOnly // sub-tools gate themselves
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "agent": ["type": "string", "description": "Agent name from the subagents list"],
      "task": ["type": "string", "description": "Complete, self-contained task description"],
      "model": [
        "type": "string",
        "description": "ONLY when the user asked for a specific model for this subagent — pass their words (e.g. 'deepseek'); omit otherwise",
      ],
    ],
    "required": ["agent", "task"],
  ]

  public let agents: [AgentDefinition]

  private let service: OpenRouterService
  private let catalog: ModelCatalog
  private let subagentTools: [any AgentTool]
  private let permissions: any PermissionDelegate
  private let store: RunRecordStore
  private let maxSteps: Int

  private let lock = NSLock()
  private var accruedCostUSD = 0.0
  private var modelOverrides: [String: String]
  /// The parent session's current model, queried at spawn time so mid-session
  /// `/model` swaps carry into inherited subagents. Set after the session exists.
  public var parentModel: (@Sendable () async -> String)?
  /// Subagent progress events (`.subagentStarted`, `.subagent`, `.subagentFinished`),
  /// fired while the parent turn waits on the tool call. Set by the UI.
  public var onEvent: (@Sendable (AgentEvent) -> Void)?

  public init(
    agents: [AgentDefinition],
    service: OpenRouterService,
    tools: [any AgentTool],
    permissions: any PermissionDelegate = AutoApprovePermissions(),
    store: RunRecordStore = RunRecordStore(),
    maxSteps: Int = 30,
    modelOverrides: [String: String] = [:])
  {
    self.agents = agents
    self.service = service
    catalog = ModelCatalog(service: service)
    // Never hand a subagent the task tool: one level of delegation is the cap.
    subagentTools = tools.filter { !($0 is TaskTool) }
    self.permissions = permissions
    self.store = store
    self.maxSteps = maxSteps
    self.modelOverrides = modelOverrides
  }

  // MARK: Model control (the user's, not the model's)

  /// Session-scoped model override for one agent (`/agents <name> <model>`). Pass
  /// `inherit` to fall back to the parent's model, nil to restore the frontmatter.
  public func setModelOverride(agent: String, model: String?) {
    lock.withLock {
      if let model {
        modelOverrides[agent] = model
      } else {
        modelOverrides.removeValue(forKey: agent)
      }
    }
  }

  /// The model an agent would run on right now: override > frontmatter > "inherit".
  public func configuredModel(for agent: AgentDefinition) -> String {
    lock.withLock { modelOverrides[agent.name] } ?? agent.model ?? "inherit"
  }

  // MARK: PromptContributing

  public var promptSection: String {
    guard !agents.isEmpty else { return "" }
    let listing = agents
      .map { "- \($0.name)\($0.description.isEmpty ? "" : ": \($0.description)")" }
      .joined(separator: "\n")
    return """
      # Subagents

      Named agents you can delegate to with the task tool. Each runs in a fresh context \
      and returns one final report; it sees nothing except your task text, so write the \
      task complete and self-contained. Delegate when work matches an agent's \
      description, or to keep a large exploration out of your own context. Never choose \
      a subagent's model yourself: pass the tool's model field only when the user named \
      one, otherwise omit it and the configured model runs.

      \(listing)
      """
  }

  // MARK: CostReportingTool

  public func drainAccruedCost() -> Double {
    lock.withLock {
      let cost = accruedCostUSD
      accruedCostUSD = 0
      return cost
    }
  }

  // MARK: AgentTool

  public func summary(arguments: [String: JSONValue]) -> String {
    let agent = arguments["agent"]?.stringValue ?? "?"
    let task = arguments["task"]?.stringValue ?? ""
    let model = arguments["model"]?.stringValue.map { " (\($0))" } ?? ""
    return "task → \(agent)\(model): \(String(task.prefix(100)))"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let agentName = arguments["agent"]?.stringValue,
          let task = arguments["task"]?.stringValue, !task.isEmpty
    else {
      return "error: the task tool needs both 'agent' and 'task'"
    }
    guard let agent = agents.first(where: { $0.name == agentName }) else {
      let available = agents.map(\.name).joined(separator: ", ")
      return "error: no agent named '\(agentName)'. Available: \(available)"
    }

    let model = await resolveModel(for: agent, requested: arguments["model"]?.stringValue)
    let session = Session(
      service: service,
      tools: toolset(for: agent),
      permissions: PrefixedPermissions(base: permissions, prefix: agent.name),
      store: store,
      configuration: Session.Configuration(
        model: model,
        maxStepsPerTurn: maxSteps,
        systemSuffix: Self.systemSuffix(for: agent),
        agent: agent.name))

    onEvent?(.subagentStarted(name: agent.name, model: model, task: task))

    var report = ""
    var stats: Session.TurnStats?
    var hitStepLimit = false
    do {
      for try await event in await session.send(task) {
        switch event {
        case .assistantText(let text):
          report = text
        case .turnFinished(let turnStats):
          stats = turnStats
        case .stepLimitReached:
          hitStepLimit = true
        default:
          break
        }
        onEvent?(.subagent(name: agent.name, event: event))
      }
    } catch {
      accrue(await session.costUSD)
      onEvent?(.subagentFinished(
        name: agent.name, steps: 0, toolCalls: 0,
        costUSD: await session.costUSD, resultPreview: "failed"))
      return "error: subagent '\(agent.name)' failed: \(error)"
    }

    let sessionCost = await session.costUSD
    accrue(stats?.turnCostUSD ?? sessionCost)
    onEvent?(.subagentFinished(
      name: agent.name,
      steps: stats?.steps ?? 0,
      toolCalls: stats?.toolCalls ?? 0,
      costUSD: stats?.turnCostUSD ?? 0,
      resultPreview: String(report.prefix(120))))

    if report.isEmpty {
      return "subagent '\(agent.name)' finished without a report"
    }
    if hitStepLimit {
      return "[subagent hit its step limit — the work below may be incomplete]\n\n" + report
    }
    return report
  }

  // MARK: Internals

  private func accrue(_ cost: Double) {
    lock.withLock { accruedCostUSD += cost }
  }

  /// pin (CLI/`/agents`) > per-call request > frontmatter > parent. The per-call
  /// `model` argument exists so the lead can relay the user's in-prompt wish ("use
  /// deepseek for the subagents"); an explicit pin still beats it, and the resolved
  /// slug is always surfaced on `.subagentStarted`. Anything that isn't an exact
  /// manifest id is fuzzy-resolved against the live manifest, so `sonnet` tracks
  /// whatever the catalog currently calls sonnet — never hardcoded.
  private func resolveModel(for agent: AgentDefinition, requested: String?) async -> String {
    let pinned = lock.withLock { modelOverrides[agent.name] }
    let configured = pinned ?? requested ?? agent.model ?? "inherit"
    if configured == "inherit" {
      return await parentModel?() ?? "openrouter/auto"
    }
    guard let matches = try? await catalog.search(configured, limit: 1),
          let best = matches.first
    else {
      // Manifest unavailable or no match — send the query as-is and let the
      // request surface the real error instead of guessing here.
      return configured
    }
    return best.id
  }

  private func toolset(for agent: AgentDefinition) -> [any AgentTool] {
    guard let allowed = agent.tools else { return subagentTools }
    return subagentTools.filter { allowed.contains($0.name) }
  }

  static func systemSuffix(for agent: AgentDefinition) -> String {
    """
    # Subagent role

    You are '\(agent.name)', a subagent spawned by a lead agent for exactly one task. \
    Work autonomously — you cannot ask questions; make reasonable assumptions and state \
    them. Your final message is returned to the lead agent as a tool result (no user \
    sees it), so make it a complete, self-contained report of what you did and found.

    \(agent.body)
    """
  }
}
