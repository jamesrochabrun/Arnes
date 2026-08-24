import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - Shared setup

func makeService() throws -> OpenRouterService {
  guard let key = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"], !key.isEmpty else {
    throw ValidationError("Set OPENROUTER_API_KEY in your environment.")
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
    subcommands: [Interactive.self, Chat.self, Do.self, Models.self, Status.self, Runs.self, Sessions.self, Eval.self],
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

  @Option(name: .shortAndLong, help: "Model slug (default: openrouter/auto).")
  var model = "openrouter/auto"

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  @Option(help: "Verify the outcome with this (cheaper) model after the run.")
  var verify: String?

  @Flag(help: "Deny all mutating tools (read-only run).")
  var safe = false

  func run() async throws {
    let service = try makeService()
    let agent = Agent(
      service: service,
      permissions: safe ? DenyMutationsPermissions() : AutoApprovePermissions())
    let result = try await agent.run(
      task: task,
      model: model,
      fallbackModels: fallback.split(separator: ",").map(String.init),
      verifierModel: verify,
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
        case .compacted(let summarized, _):
          print("◈ compacted \(summarized) older messages")
        case .textDelta, .reasoningDelta, .interrupted, .turnFinished:
          break // headless output prints whole messages and its own footer
        }
      })
    let record = result.record
    let routed = record.routedModels.joined(separator: ", ")
    print("\n[requested \(record.model) → served by \(routed.isEmpty ? "?" : routed) · \(record.steps) steps · \(record.toolCalls) tool calls · $\(String(format: "%.4f", record.costUSD))]")
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
    abstract: "List saved interactive sessions (resume with `arnes --resume <id>`).")

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
