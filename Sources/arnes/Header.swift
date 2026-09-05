import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Session-start banner — a rounded box with the name and version in the top border:
///
///     ╭─ arnes ─ v0.2.0 ────────────────────────────────╮
///     │  openrouter/auto · dialect auto · /help         │
///     │  ~/Developer/Arnes · 2 MCP servers (9 tools)    │
///     ╰─────────────────────────────────────────────────╯
///
/// TTY-gated: piped output gets one plain line so transcripts stay grep-able. The box
/// sizes to its longest line and shrinks (content truncated with …) on narrow terminals.
enum Header {
  /// - Parameters:
  ///   - provider: a `provider <name> · host/path` line for non-OpenRouter providers, so it
  ///     is always visible where requests (and the key) are going.
  ///   - mode: the permission mode when it isn't `default` (`plan`, `acceptEdits`,
  ///     `bypass`) — a session that can't write, or won't ask, should say so up front.
  ///   - memory: the run's memory tag (`memory 42 lines`, `memory none yet`); nil when off.
  ///   - limits: the stop conditions the session was started with (`budget $0.50 · max 10
  ///     steps`), when any is set — the knobs `--budget`/`--max-steps` turn.
  static func banner(
    version: String,
    model: String,
    dialect: String,
    provider: String? = nil,
    directory: String = FileManager.default.currentDirectoryPath,
    mcpServers: Int = 0,
    mcpTools: Int = 0,
    skills: Int = 0,
    agents: Int = 0,
    judge: String? = nil,
    sandbox: String? = nil,
    hooks: String? = nil,
    effort: String? = nil,
    environment: String? = nil,
    addedDirectories: Int = 0,
    mode: String? = nil,
    memory: String? = nil,
    agent: String? = nil,
    limits: String? = nil,
    resumeLine: String? = nil)
    -> String
  {
    guard ANSI.isTTY else {
      var line = "arnes v\(version) · \(model)"
      if let provider { line += " · \(provider)" }
      if let agent { line += " · agent \(agent)" }
      if let mode { line += " · mode \(mode)" }
      if let resumeLine { line += " · \(resumeLine)" }
      return line + " · /help for commands"
    }

    // (plain, styled) pairs: padding math needs the visible width, free of ANSI codes.
    var lines: [(plain: String, styled: String)] = []
    let modelSuffix = " · dialect \(dialect) · /help"
    lines.append((model + modelSuffix, model + ANSI.dim(modelSuffix)))
    if let provider { lines.append((provider, ANSI.cyan(provider))) }
    var info = abbreviatingHome(directory)
    if mcpServers > 0 {
      let servers = "\(mcpServers) MCP server\(mcpServers == 1 ? "" : "s")"
      let tools = "\(mcpTools) tool\(mcpTools == 1 ? "" : "s")"
      info += " · \(servers) (\(tools))"
    }
    if skills > 0 {
      info += " · \(skills) skill\(skills == 1 ? "" : "s")"
    }
    if agents > 0 {
      info += " · \(agents) agent\(agents == 1 ? "" : "s")"
    }
    if let judge { info += " · judge \(judge)" }
    if let sandbox { info += " · \(sandbox)" }
    if let hooks { info += " · \(hooks)" }
    if let effort { info += " · effort \(effort)" }
    if let agent { info += " · agent \(agent)" }
    if let mode { info += " · mode \(mode)" }
    if let limits { info += " · \(limits)" }
    if let environment { info += " · \(environment)" }
    if addedDirectories > 0 {
      info += " · +\(addedDirectories) dir\(addedDirectories == 1 ? "" : "s")"
    }
    if let memory { info += " · \(memory)" }
    lines.append((info, ANSI.dim(info)))
    if let resumeLine { lines.append((resumeLine, ANSI.dim(resumeLine))) }

    let titlePlain = "╭─ arnes ─ v\(version) "
    var inner = max((lines.map(\.plain.count).max() ?? 0) + 4, titlePlain.count)
    let maxInner = max(terminalColumns - 2, titlePlain.count)
    if inner > maxInner {
      inner = maxInner
      lines = lines.map { line in
        guard line.plain.count > inner - 4 else { return line }
        let cut = String(line.plain.prefix(inner - 5)) + "…"
        return (cut, ANSI.dim(cut))
      }
    }

    let top = ANSI.accent("╭─ ") + ANSI.accentBold("arnes") + ANSI.accent(" ─ ")
      + ANSI.dim("v\(version)")
      + ANSI.accent(" " + String(repeating: "─", count: inner + 1 - titlePlain.count) + "╮")
    let rows = lines.map { line in
      ANSI.accent("│") + "  " + line.styled
        + String(repeating: " ", count: inner - 4 - line.plain.count)
        + "  " + ANSI.accent("│")
    }
    let bottom = ANSI.accent("╰" + String(repeating: "─", count: inner) + "╯")
    return ([top] + rows + [bottom]).joined(separator: "\n")
  }

  private static func abbreviatingHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
  }

  private static var terminalColumns: Int {
    var size = winsize()
    if ioctl(1, numericCast(TIOCGWINSZ), &size) == 0, size.ws_col > 0 {
      return Int(size.ws_col)
    }
    if let env = ProcessInfo.processInfo.environment["COLUMNS"], let columns = Int(env) {
      return columns
    }
    return 80
  }
}
