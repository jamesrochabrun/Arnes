import ArgumentParser
import ArnesKit
import Foundation

/// `arnes agents` — list the subagents the loop would load from the current directory:
/// name, model, description, and which file each one came from.
struct Agents: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List subagents loaded from .arnes/agents, .claude/agents, and ~/.arnes/agents.")

  func run() async throws {
    let agents = AgentLibrary.discover()
    let home = NSHomeDirectory()
    for agent in agents {
      print("\(ANSI.bold(agent.name))  \(ANSI.cyan(agent.model ?? "inherit"))")
      if !agent.description.isEmpty { print("  \(agent.description)") }
      if let tools = agent.tools { print(ANSI.dim("  tools: \(tools.joined(separator: ", "))")) }
      let origin = agent.source.map {
        $0.path.hasPrefix(home) ? "~" + $0.path.dropFirst(home.count) : $0.path
      } ?? "built-in"
      print(ANSI.dim("  \(origin)"))
    }
    print(ANSI.dim(
      "\n\(agents.count) agent\(agents.count == 1 ? "" : "s") — the model delegates with the "
        + "task tool; add <name>.md files (Claude Code agent format) under .arnes/agents, "
        + ".claude/agents, or ~/.arnes/agents"))
  }
}
