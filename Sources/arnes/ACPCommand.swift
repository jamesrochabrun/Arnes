import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Editor integration. stdout belongs exclusively to newline-delimited JSON-RPC.
struct ACPCommand: AsyncParsableCommand {
  static let configuration = CommandConfiguration(commandName: "acp",
    abstract: "Serve Agent Client Protocol v1 over stdio using ArnesKit sessions.")

  @Option(name: .shortAndLong, help: "Model slug (default: the configured provider's model).")
  var model: String?
  @Option(help: "Reasoning effort: minimal, low, medium, high, xhigh, max, or none.")
  var effort: String?
  @Option(help: "Maximum model steps per prompt turn.")
  var maxSteps: Int = 100
  @Option(help: "Per-session cost ceiling in USD.")
  var budget: Double = 5
  @Option(help: "Use an isolated directory for ACP configuration, credentials, packs and all persistent state.")
  var stateDirectory: String?
  @OptionGroup var providerOptions: ProviderOptions

  func validate() throws {
    _ = try parseEffort(effort)
    guard maxSteps > 0, budget.isFinite, budget > 0 else {
      throw ValidationError("--max-steps and --budget must be positive and finite")
    }
    if let stateDirectory, !stateDirectory.hasPrefix("/") || stateDirectory.contains("\0") {
      throw ValidationError("--state-directory must be an absolute path")
    }
  }

  func run() async throws {
    // EPIPE becomes an output error and triggers session cleanup, not a SIGPIPE exit.
    signal(SIGPIPE, SIG_IGN)
    let writer = ACPOutputWriter(handle: .standardOutput)
    let input = ACPInputReader(handle: .standardInput)
    let stateDirectory = stateDirectory.map { URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }
    let providerOptions = providerOptions
    let model = model, effort = try parseEffort(effort), maxSteps = maxSteps, budget = budget
    let connection = ACPConnection(version: arnesVersion, factory: { id, cwd, servers, permissions in
      // Resolve lazily: initialize/help works without a provider key. One runtime per session
      // keeps spill scopes isolated. No process-wide chdir: every tool receives this cwd.
      let runtime = try ArnesRuntime.make(providerOptions, stateDirectory: stateDirectory)
      let model = try runtime.model(model)
      let environment = runtime.subprocessEnvironment
      let mcp = MCPToolProvider(redactingEnvironment: environment.redactedKeys,
        transportFactory: { name, config in
          ProcessMCPTransport(name: name, config: config,
            redactingEnvironment: environment.redactedKeys, workingDirectory: cwd,
            expandEnvironmentVariables: false)
        })
      do {
        // Client-supplied executables are explicit configuration, but still get the human's
        // approval before startup. They never inherit the provider token implicitly.
        for server in servers {
          let decision = await permissions.decide(.init(toolName: "mcp_start",
            summary: "Start MCP server \(server.name): \(server.command) \(server.args.joined(separator: " "))"
              + "\nEnvironment keys: \(server.env.map(\.name).joined(separator: ", "))",
            argumentsJSON: "{}", tier: .sensitive))
          guard case .allow = decision else {
            throw ACPError(code: -32000, message: "MCP server startup was not approved")
          }
        }
        try Task.checkCancellation()
        let connected = await mcp.connect(config: MCPConfig(mcpServers:
          Dictionary(uniqueKeysWithValues: servers.map { ($0.name, $0.configuration) })))
        if let failed = connected.statuses.first(where: { $0.error != nil }) {
          throw ACPError(code: -32000, message: "MCP server \(failed.server) failed: \(failed.error ?? "unknown error")")
        }
        try Task.checkCancellation()
        var rules = runtime.pathRules()
        var sandbox = runtime.shellSandbox(root: cwd, autonomous: true)
        if let stateDirectory {
          rules.harnessPaths += PathScope.harnessPaths(environment: ["ARNES_CONFIG": stateDirectory.path])
          let credentials = ["config.json", "credentials", "hooks.json", "mcp.json", "rules.json"]
            .map { stateDirectory.appendingPathComponent($0) }
          rules.policy.denyRead += credentials.map(\.path)
          sandbox?.protectedSubpaths.append(stateDirectory)
          sandbox?.denyRead.append(contentsOf: credentials)
        }
        let jobs = runtime.jobRegistry()
        let tools = HarnessAssembly.coreTools(ToolContext(root: cwd, sandbox: sandbox,
          environment: environment, pathRules: rules,
          bashOutputChars: runtime.limits.effectiveBashOutputChars, jobs: jobs,
          bashTimeoutSeconds: runtime.limits.effectiveBashTimeoutSeconds,
          web: runtime.webPolicy)).filter { $0.name != "ask_user" } + connected.tools
        var configuration = Session.Configuration(model: model, maxStepsPerTurn: maxSteps,
          maxCostUSD: budget, reasoningEffort: effort, provider: runtime.traits,
          subprocessEnvironment: environment, workingDirectory: cwd,
          permissionMode: .default, sessionOrigin: "acp", pathRules: rules)
        runtime.applyLimits(to: &configuration)
        configuration.packsDirectory = stateDirectory?.appendingPathComponent("packs")
        let session = Session(service: runtime.service, tools: tools, permissions: permissions,
          store: stateDirectory.map { RunRecordStore(url: $0.appendingPathComponent("runs.jsonl")) } ?? RunRecordStore(),
          sessionStore: stateDirectory.map { SessionStore(directory: $0.appendingPathComponent("sessions")) } ?? SessionStore(),
          dialectStore: stateDirectory.map { DialectVerdictStore(url: $0.appendingPathComponent("dialects.jsonl")) } ?? DialectVerdictStore(),
          catalog: runtime.catalog,
          configuration: configuration, id: id)
        return ACPSession(session: session, cleanup: { await mcp.shutdown() })
      } catch {
        await mcp.shutdown()
        throw error
      }
    }, output: { message in
      do { try await writer.write(message) }
      catch { input.stop(); throw error }
    })
    let signalNumbers: [Int32] = [SIGINT, SIGTERM]
    let signals = signalNumbers.map { number -> DispatchSourceSignal in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler {
        Task {
          await connection.shutdown()
          Foundation.exit(number == SIGINT ? 130 : 143)
        }
      }
      source.resume()
      return source
    }
    defer { signals.forEach { $0.cancel() } }
    var framer = ACPLineFramer()
    do {
      for try await data in input.stream {
        for line in try framer.append(data) { await connection.receive(line: line) }
      }
      try framer.finish()
    } catch {
      FileHandle.standardError.write(Data(("ACP transport: \(error)\n").utf8))
    }
    await connection.shutdown()
  }
}
