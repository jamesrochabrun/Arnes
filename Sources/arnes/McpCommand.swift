import ArgumentParser
import ArnesKit
import Foundation

// MARK: - MCPSetup

/// Shared CLI-side MCP bootstrap: loads `~/.arnes/mcp.json`, connects the servers, and
/// prints one status line per server (`quiet` skips the ok lines for callers that
/// summarize servers themselves; warnings always print). Callers own the returned
/// provider and must `shutdown()` it so the server processes die with the CLI.
enum MCPSetup {
  static func connect(enabled: Bool, spinner: Spinner? = nil, quiet: Bool = false) async -> (provider: MCPToolProvider, tools: [any AgentTool]) {
    let provider = MCPToolProvider()
    guard enabled else { return (provider, []) }
    let config: MCPConfig
    do {
      guard let loaded = try MCPConfig.load(), !loaded.mcpServers.isEmpty else {
        return (provider, [])
      }
      config = loaded
    } catch {
      print(ANSI.yellow("⚠ \(MCPConfig.defaultURL.path) is invalid: \(error) — continuing without MCP"))
      return (provider, [])
    }
    spinner?.start("connecting mcp servers")
    let (tools, statuses) = await provider.connect(config: config)
    spinner?.stop()
    for status in statuses {
      if let error = status.error {
        print(ANSI.yellow("⚠ mcp \(status.server): \(error)"))
      } else if !quiet {
        print(ANSI.dim("mcp \(status.server) · \(status.toolCount) tools"))
      }
    }
    return (provider, tools)
  }
}

// MARK: - mcp

struct Mcp: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "mcp",
    abstract: "Connect the MCP servers in ~/.arnes/mcp.json and list the tools they expose.")

  func run() async throws {
    guard let config = try MCPConfig.load(), !config.mcpServers.isEmpty else {
      print("""
        no MCP servers configured — create \(MCPConfig.defaultURL.path), e.g.:

        {
          "mcpServers": {
            "filesystem": {
              "command": "npx",
              "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]
            }
          }
        }
        """)
      return
    }
    let provider = MCPToolProvider()
    let (tools, statuses) = await provider.connect(config: config)
    for status in statuses {
      if let error = status.error {
        print(ANSI.red("✘ \(status.server): \(error)"))
        continue
      }
      print(ANSI.bold(status.server) + ANSI.dim(" · \(status.toolCount) tools"))
      for tool in tools.compactMap({ $0 as? MCPTool }) where tool.server == status.server {
        let gate = tool.permission == .readOnly ? ANSI.dim("read-only") : ANSI.yellow("mutating")
        let brief = tool.description.split(separator: "\n").first.map(String.init) ?? ""
        print("  \(tool.name)  [\(gate)]  \(ANSI.dim(String(brief.prefix(100))))")
      }
    }
    await provider.shutdown()
  }
}
