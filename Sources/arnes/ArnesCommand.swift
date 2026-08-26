import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

/// Single source of truth for the CLI version — shown in the header and `--version`.
let arnesVersion = "0.5.0"

// MARK: - Shared setup

func parseDialect(_ raw: String) throws -> DialectOverride {
  guard let dialect = DialectOverride(rawValue: raw) else {
    throw ValidationError("unknown dialect '\(raw)' — use auto, chat, messages, or responses")
  }
  return dialect
}

/// `OPENROUTER_API_KEY` from the environment wins; otherwise fall back to
/// `~/.arnes/credentials` (first non-empty, non-`#` line, optional
/// `OPENROUTER_API_KEY=` prefix) so arnes works from shells that never source
/// the user's profile — editor task runners, launchers, non-interactive scripts.
func resolveAPIKey() -> String? {
  if let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty {
    return key
  }
  let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/credentials")
  guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
  for rawLine in contents.split(whereSeparator: \.isNewline) {
    var line = rawLine.trimmingCharacters(in: .whitespaces)
    guard !line.isEmpty, !line.hasPrefix("#") else { continue }
    if line.hasPrefix("OPENROUTER_API_KEY=") {
      line = String(line.dropFirst("OPENROUTER_API_KEY=".count))
        .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    }
    return line.isEmpty ? nil : line
  }
  return nil
}

func makeService() throws -> OpenRouterService {
  guard let key = resolveAPIKey() else {
    throw ValidationError(
      "Set OPENROUTER_API_KEY in your environment, or put the key in ~/.arnes/credentials.")
  }
  return OpenRouter.service(
    apiKey: key,
    configuration: OpenRouterConfiguration(
      appReferer: "https://github.com/jamesrochabrun/Arnes",
      appTitle: "Arnes"))
}

// MARK: - Root

@main
struct Arnes: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "arnes",
    abstract: "Arnes — a model-adaptive agent harness for OpenRouter.",
    version: arnesVersion,
    subcommands: [Interactive.self, Chat.self, Do.self, Resume.self, Models.self, Status.self, Runs.self, Sessions.self, Eval.self, Evals.self, Probe.self, Mcp.self],
    defaultSubcommand: Interactive.self)
}

// MARK: - chat

struct Chat: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Stream a one-shot chat reply.")

  @Argument(help: "The prompt.")
  var prompt: String

  @Option(name: .shortAndLong, help: "OpenRouter model slug (default: openrouter/auto).")
  var model = "openrouter/auto"

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  func run() async throws {
    let service = try makeService()
    let fallbacks = fallback.split(separator: ",").map(String.init)
    let stream = try await service.chatCompletionStream(
      ChatCompletionRequest(
        model: model,
        models: fallbacks.isEmpty ? nil : fallbacks,
        messages: [.user(prompt)]))
    var cost: Double?
    var routedModel: String?
    for try await chunk in stream {
      if let delta = chunk.choices?.first?.delta?.content {
        print(delta, terminator: "")
      }
      if let usage = chunk.usage { cost = usage.cost }
      if let model = chunk.model { routedModel = model }
    }
    print()
    if let routedModel, let cost {
      FileHandle.standardError.write(Data("[\(routedModel) · $\(String(format: "%.6f", cost))]\n".utf8))
    }
  }
}

// MARK: - do

struct Do: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Run the agent loop on a task (read/write/bash tools).")

  @Argument(help: "The task.")
  var task: String

  @Option(name: .shortAndLong, help: "Model slug (default: openrouter/auto). With --panel, a comma-separated list fans out to those models.")
  var model = "openrouter/auto"

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  @Option(help: "Verify the outcome with this (cheaper) model after the run.")
  var verify: String?

  @Flag(help: "Deny all mutating tools (read-only run).")
  var safe = false

  @Option(help: "Wire dialect: auto (native per model family), chat, messages, or responses.")
  var dialect = "auto"

  @Option(help: "Fan the task to N isolated candidates (models from -m, cycled to N) and keep the judged winner.")
  var panel: Int?

  @Option(help: "Judge model for --panel (default: openrouter/auto).")
  var judge = "openrouter/auto"

  @Flag(help: "With --panel: keep the winner in its snapshot instead of applying its changes here.")
  var noApply = false

  @Flag(help: "Skip connecting MCP servers from ~/.arnes/mcp.json.")
  var noMcp = false

  func run() async throws {
    let service = try makeService()
    if panel != nil {
      try await runPanel(service: service)
      return
    }
    // Panels stay MCP-free: candidates run in isolated snapshots, and shared server
    // processes would let them trample each other through side effects.
    let mcp = await MCPSetup.connect(enabled: !noMcp)
    let agent = Agent(
      service: service,
      tools: Session.defaultTools + mcp.tools,
      permissions: safe ? DenyMutationsPermissions() : AutoApprovePermissions())
    let result = try await agent.run(
      task: task,
      model: model,
      fallbackModels: fallback.split(separator: ",").map(String.init),
      verifierModel: verify,
      dialect: parseDialect(dialect),
      onEvent: { event in
        switch event {
        case .assistantText(let text):
          print(text)
        case .toolCall(let name, let arguments):
          print("→ \(name) \(arguments.prefix(120))")
        case .toolResult(let name, let preview):
          print("← \(name): \(preview)")
        case .toolDenied(let name, _):
          print("⊘ \(name) denied")
        case .verifier(let passed, let verdict):
          print(passed ? "✔ \(verdict)" : "✘ \(verdict)")
        case .routed(let model, let provider):
          print("⇄ routed to \(model)\(provider.map { " (\($0))" } ?? "")")
        case .dialectFellBack(let dialect, let reason):
          print("⤵ \(dialect) dialect failed (\(reason.prefix(80))) — fell back to chat")
        case .compacted(let summarized, _):
          print("◈ compacted \(summarized) older messages")
        case .nudged:
          print("↻ paused without finishing — nudged to continue")
        case .stepLimitReached(let maxSteps):
          print("⚠ step limit (\(maxSteps)) reached before the task finished")
        case .textDelta, .reasoningDelta, .interrupted, .turnFinished:
          break // headless output prints whole messages and its own footer
        }
      })
    // On a thrown run the process exits and the servers see stdin EOF, which is the
    // stdio-transport shutdown signal — only the success path needs an explicit close.
    await mcp.provider.shutdown()
    let record = result.record
    let routed = record.routedModels.joined(separator: ", ")
    print("\n[requested \(record.model) → served by \(routed.isEmpty ? "?" : routed) · dialect \(record.dialect) · \(record.steps) steps · \(record.toolCalls) tool calls · $\(String(format: "%.4f", record.costUSD))]")
  }

  private func runPanel(service: OpenRouterService) async throws {
    guard let size = panel, size >= 2 else {
      throw ValidationError("--panel needs at least 2 candidates — use plain `arnes do` for one.")
    }
    guard !safe else {
      throw ValidationError("--panel and --safe don't combine: candidates must be able to write in their snapshots.")
    }
    let roster = model.split(separator: ",").map(String.init)
    let candidateModels = (0..<size).map { roster[$0 % roster.count] }
    print("panel of \(size): \(candidateModels.joined(separator: ", ")) — judge: \(judge)")

    let runner = PanelRunner(service: service)
    let result = try await runner.run(
      task: task,
      models: candidateModels,
      judgeModel: judge,
      baseDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      apply: !noApply,
      dialect: parseDialect(dialect),
      onProgress: { progress in
        switch progress {
        case .candidateStarted(let index, let model):
          print("· candidate \(index + 1) (\(model)) started")
        case .candidateFinished(let candidate):
          if let error = candidate.error {
            print("✘ candidate \(candidate.index + 1) (\(candidate.model)) failed after \(Int(candidate.durationSeconds))s: \(error.prefix(120))")
          } else {
            let record = candidate.record
            print("✔ candidate \(candidate.index + 1) (\(candidate.model)) finished — \(record?.steps ?? 0) steps · $\(String(format: "%.4f", record?.costUSD ?? 0)) · \(Int(candidate.durationSeconds))s")
          }
        case .judged(let verdict):
          print("⚖ \(verdict.reason)")
        }
      })

    let winner = result.winner
    print("\nwinner: candidate \(winner.index + 1) (\(winner.model))")
    if !winner.report.isEmpty {
      print(winner.report)
    }
    if result.applied {
      print("\napplied the winner's changes to \(FileManager.default.currentDirectoryPath)")
    } else if let kept = result.winnerDirectory {
      print("\nwinner's snapshot kept at \(kept.path) (--no-apply)")
    }
    let totalCost = result.candidates.reduce(result.verdict.judgeCostUSD) { $0 + ($1.record?.costUSD ?? 0) }
    print("[panel cost $\(String(format: "%.4f", totalCost)) · outcomes labeled in ~/.arnes/evals.jsonl]")
  }
}

// MARK: - resume

struct Resume: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Resume a saved session by id, unique id prefix, or name (most recent when omitted).")

  @Argument(help: "Session id, unique id prefix, or saved name (see `arnes sessions`).")
  var session: String?

  func run() async throws {
    let sessions = try SessionStore().list()
    guard !sessions.isEmpty else {
      throw ValidationError("no sessions yet — start one with `arnes`.")
    }
    let resolved = try Self.resolve(session, in: sessions)
    let interactive = try Interactive.parse(["--resume", resolved.id])
    try await interactive.run()
  }

  /// Exact id wins; otherwise a unique id prefix or saved name (case-insensitive).
  /// `sessions` is most-recent-first, so a nil query resumes the latest.
  static func resolve(_ query: String?, in sessions: [SessionMeta]) throws -> SessionMeta {
    guard let query else { return sessions[0] }
    if let exact = sessions.first(where: { $0.id == query }) { return exact }
    let lowered = query.lowercased()
    let matches = sessions.filter {
      $0.id.lowercased().hasPrefix(lowered) || $0.name?.lowercased() == lowered
    }
    switch matches.count {
    case 1:
      return matches[0]
    case 0:
      throw ValidationError("no session matches \"\(query)\" — see `arnes sessions`.")
    default:
      let listing = matches.map { "  \($0.id)  \($0.name ?? "(unnamed)")" }.joined(separator: "\n")
      throw ValidationError("\"\(query)\" matches several sessions:\n\(listing)")
    }
  }
}

// MARK: - models

struct Models: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Search OpenRouter models.")

  @Argument(help: "Free-text query.")
  var query: String?

  @Option(help: "Only models supporting these parameters (comma-separated), e.g. tools,reasoning.")
  var supports = ""

  @Option(help: "Max results.")
  var limit = 20

  func run() async throws {
    let service = try makeService()
    let supported = supports.split(separator: ",").map(String.init)
    let models = try await service.models(
      filter: ModelsFilter(
        supportedParameters: supported.isEmpty ? nil : supported,
        q: query,
        limit: limit))
    for model in models {
      let context = model.contextLength.map { "\($0 / 1000)k" } ?? "?"
      let price = model.pricing?.prompt ?? "?"
      print("\(model.id.padding(toLength: 45, withPad: " ", startingAt: 0)) ctx=\(context)\tin=$\(price)/tok")
    }
  }
}

// MARK: - status

struct Status: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show key limits and credit balance.")

  func run() async throws {
    let service = try makeService()
    let key = try await service.keyInfo()
    let credits = try await service.credits()
    print("key: \(key.label ?? "?")\(key.isFreeTier == true ? " (free tier)" : "")")
    if let limit = key.limit {
      print("limit: \(limit)  remaining: \(key.limitRemaining ?? 0)")
    }
    print("credits: \(String(format: "%.4f", credits.remaining)) remaining of \(credits.totalCredits)")
  }
}

// MARK: - sessions

struct Sessions: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List saved interactive sessions (resume with `arnes resume <id>`).")

  func run() throws {
    let sessions = try SessionStore().list()
    guard !sessions.isEmpty else {
      print("no sessions yet — start one with `arnes`")
      return
    }
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    for meta in sessions {
      let name = meta.name ?? "(unnamed)"
      let model = meta.model ?? "?"
      print("\(meta.id)  \(formatter.string(from: meta.updatedAt))  \(name.padding(toLength: 24, withPad: " ", startingAt: 0)) \(model)  \(meta.messageCount) msgs")
    }
  }
}

// MARK: - runs

struct Runs: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Show the local run scoreboard (per-model cost and verifier pass rate).")

  func run() throws {
    let records = try RunRecordStore().all()
    guard !records.isEmpty else {
      print("no runs recorded yet — try `arnes do \"...\"`")
      return
    }
    let byModel = Dictionary(grouping: records, by: \.model)
    for (model, runs) in byModel.sorted(by: { $0.key < $1.key }) {
      let cost = runs.reduce(0) { $0 + $1.costUSD }
      let verified = runs.filter { $0.verifierPassed != nil }
      let passed = verified.filter { $0.verifierPassed == true }.count
      let passRate = verified.isEmpty ? "n/a" : "\(passed)/\(verified.count)"
      print("\(model.padding(toLength: 40, withPad: " ", startingAt: 0)) runs=\(runs.count)\tcost=$\(String(format: "%.4f", cost))\tverified=\(passRate)")
    }
  }
}
