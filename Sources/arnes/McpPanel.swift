import ArnesKit
import Foundation

// MARK: - McpPanel

/// `/mcp [server]` in the REPL (X9): what is connected, what failed and why, the tools and
/// prompts per server, the withheld tools, and how to add one. Pure and terminal-free — the
/// statuses are what `MCPSetup.connect` returned at session start, so the panel also says a
/// config change needs a new session (the toolset is fixed once the session runs). Every
/// server, tool and description string goes through `TerminalText.sanitize`; a transport line
/// is `ServerStatus.transport` (`stdio <cmd…>` / `http <host>`), never a header value or a URL path.
enum McpPanel {
  /// One MCP tool as the panel lists it (built from `MCPTool`; tests build it directly).
  struct Tool: Equatable {
    let server: String
    /// The namespaced name, `mcp__<server>__<tool>`.
    let name: String
    let description: String
    let permission: ToolPermission

    init(server: String, name: String, description: String, permission: ToolPermission = .mutating) {
      self.server = server
      self.name = name
      self.description = description
      self.permission = permission
    }

    init(_ tool: MCPTool) {
      self.init(server: tool.server, name: tool.name, description: tool.description, permission: tool.permission)
    }
  }

  /// One server prompt as the panel lists it (`/mcp__<server>__<prompt> <args>`).
  struct Prompt: Equatable {
    let server: String
    let slashName: String
    let arguments: [String]
    let description: String?

    init(server: String, slashName: String, arguments: [String] = [], description: String? = nil) {
      self.server = server
      self.slashName = slashName
      self.arguments = arguments
      self.description = description
    }

    init(_ prompt: MCPPrompt) {
      self.init(
        server: prompt.server, slashName: prompt.slashName,
        arguments: (prompt.info.arguments ?? []).map(\.name), description: prompt.info.description)
    }
  }

  /// What the REPL keeps from the connect for the panel: the statuses, the tools, the prompts
  /// and the config files that contributed entries.
  struct Snapshot {
    let statuses: [MCPToolProvider.ServerStatus]
    let tools: [Tool]
    let prompts: [Prompt]
    let configPaths: [String]

    init(statuses: [MCPToolProvider.ServerStatus], tools: [Tool], prompts: [Prompt], configPaths: [String]) {
      self.statuses = statuses
      self.tools = tools
      self.prompts = prompts
      self.configPaths = configPaths
    }

    static let empty = Snapshot(statuses: [], tools: [], prompts: [], configPaths: [])
  }

  static let errorClip = 120
  static let descriptionClip = 100
  static let withheldClip = 80

  /// The panel: no `server` = one row per server + the footer; a name = that server's tools
  /// and prompts; an unknown name lists the known ones.
  static func lines(
    statuses: [MCPToolProvider.ServerStatus],
    tools: [Tool],
    prompts: [Prompt],
    configPaths: [String],
    server: String? = nil,
    home: String = NSHomeDirectory())
    -> [String]
  {
    if let server = server?.trimmingCharacters(in: .whitespaces), !server.isEmpty {
      return detail(server, statuses: statuses, tools: tools, prompts: prompts)
    }
    return overview(statuses: statuses, tools: tools, prompts: prompts, configPaths: configPaths, home: home)
  }

  static func lines(_ snapshot: Snapshot, server: String? = nil, home: String = NSHomeDirectory()) -> [String] {
    lines(
      statuses: snapshot.statuses, tools: snapshot.tools, prompts: snapshot.prompts,
      configPaths: snapshot.configPaths, server: server, home: home)
  }

  // MARK: Overview

  static func overview(
    statuses: [MCPToolProvider.ServerStatus],
    tools: [Tool],
    prompts: [Prompt],
    configPaths: [String],
    home: String)
    -> [String]
  {
    var lines: [String] = []
    if statuses.isEmpty {
      lines.append(ANSI.dim("no MCP servers configured"))
    }
    for status in statuses.sorted(by: { $0.server < $1.server }) {
      lines.append(row(for: status))
    }
    lines += footer(configPaths: configPaths, home: home)
    return lines
  }

  /// `● name  stdio cmd  12 tools · 2 prompts  [required] [untrusted] [3 withheld — arnes mcp --approve name]`,
  /// `○ name  http host  failed: <error>` or `– name  disabled`.
  static func row(for status: MCPToolProvider.ServerStatus) -> String {
    let name = TerminalText.sanitize(status.server)
    let transport = ANSI.dim(TerminalText.sanitize(status.transport))
    var tags: [String] = []
    if status.required { tags.append(ANSI.yellow("[required]")) }
    if status.untrusted { tags.append(ANSI.yellow("[untrusted]")) }
    if status.disabled {
      return "\(ANSI.dim("–")) \(ANSI.dim(name))  \(ANSI.dim("disabled"))" + (tags.isEmpty ? "" : "  " + tags.joined(separator: " "))
    }
    if let error = status.error {
      let text = TerminalText.sanitize(String(error.prefix(errorClip)))
      return "\(ANSI.red("○")) \(ANSI.red(name))  \(transport)  \(ANSI.red("failed: \(text)"))"
        + (tags.isEmpty ? "" : "  " + tags.joined(separator: " "))
    }
    if !status.withheldTools.isEmpty {
      tags.append(ANSI.yellow(TerminalText.sanitize(
        "[\(status.withheldTools.count) withheld — arnes mcp --approve \(status.server)]")))
    }
    let counts = "\(status.toolCount) tool\(status.toolCount == 1 ? "" : "s")"
      + (status.promptCount > 0 ? " · \(status.promptCount) prompt\(status.promptCount == 1 ? "" : "s")" : "")
    return "\(ANSI.green("●")) \(ANSI.bold(name))  \(transport)  \(ANSI.dim(counts))"
      + (tags.isEmpty ? "" : "  " + tags.joined(separator: " "))
  }

  /// The config file(s) in play, how to add a server, and that a change needs a new session.
  static func footer(configPaths: [String], home: String) -> [String] {
    var lines: [String] = []
    if !configPaths.isEmpty {
      let shown = configPaths.map { abbreviate($0, home: home) }.joined(separator: " · ")
      lines.append(ANSI.dim(TerminalText.sanitize("config: \(shown)")))
    }
    lines.append(ANSI.dim("add one: arnes mcp add <name> -- <command>  ·  arnes mcp add <name> --url https://…"))
    lines.append(ANSI.dim("changes take effect in a new session (the toolset is fixed when a session starts)"))
    return lines
  }

  // MARK: Detail

  static func detail(
    _ server: String,
    statuses: [MCPToolProvider.ServerStatus],
    tools: [Tool],
    prompts: [Prompt])
    -> [String]
  {
    guard let status = statuses.first(where: { $0.server == server }) else {
      let known = statuses.map(\.server).sorted()
      return [ANSI.yellow(TerminalText.sanitize(
        known.isEmpty
          ? "no MCP servers configured — /mcp lists how to add one"
          : "unknown server '\(server)' — known: \(known.joined(separator: ", "))"))]
    }
    var lines = [row(for: status)]
    if status.disabled { return lines }
    if let error = status.error {
      lines.append(ANSI.red(TerminalText.sanitize("  \(error)")))
      return lines
    }
    let own = tools.filter { $0.server == server }.sorted { $0.name < $1.name }
    for tool in own {
      let gate = tool.permission == .readOnly
        ? ANSI.dim("read-only")
        : (tool.permission == .sensitive ? ANSI.red("sensitive") : ANSI.yellow("mutating"))
      let brief = tool.description.split(separator: "\n").first.map(String.init) ?? ""
      lines.append(TerminalText.sanitize(
        "  \(tool.name)  [\(gate)]  \(ANSI.dim(String(brief.prefix(descriptionClip))))"))
    }
    for name in status.withheldTools {
      let brief = status.withheldDescriptions[name] ?? ""
      lines.append(ANSI.yellow(TerminalText.sanitize(
        "  \(name)  [withheld — changed since first seen; arnes mcp --approve \(server)]  "))
        + ANSI.dim(TerminalText.sanitize(String(brief.prefix(withheldClip)))))
    }
    let ownPrompts = prompts.filter { $0.server == server }.sorted { $0.slashName < $1.slashName }
    for prompt in ownPrompts {
      let arguments = prompt.arguments.map { "<\($0)>" }.joined(separator: " ")
      lines.append(TerminalText.sanitize(
        "  /\(prompt.slashName)\(arguments.isEmpty ? "" : " \(arguments)")  "
          + ANSI.dim(String((prompt.description ?? "").prefix(descriptionClip)))))
    }
    if own.isEmpty, status.withheldTools.isEmpty, ownPrompts.isEmpty {
      lines.append(ANSI.dim("  (no tools or prompts)"))
    }
    return lines
  }

  static func abbreviate(_ path: String, home: String) -> String {
    path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }
}
