import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - EchoTool

/// The probe's only tool: proves a native tool round-trip works end to end —
/// definition accepted, call streamed, arguments parsed, result fed back.
private final class EchoTool: AgentTool, @unchecked Sendable {
  let name = "echo"
  let description = "Echo the given text back. Call this exactly once."
  let permission = ToolPermission.readOnly
  let parameters: JSONValue = [
    "type": "object",
    "properties": ["text": ["type": "string", "description": "Text to echo"]],
    "required": ["text"],
  ]

  private let lock = NSLock()
  private(set) var echoed: [String] = []

  func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let text = arguments["text"]?.stringValue else {
      return "error: missing 'text'"
    }
    lock.withLock { echoed.append(text) }
    return text
  }
}

// MARK: - probe

struct Probe: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Check a model's native-dialect conformance with one tiny tool round-trip.",
    discussion: """
      Sends one cheap request on the model's native dialect and verifies the tool call
      arrives structurally intact (definition → call → parsed arguments → result). The
      verdict is recorded in ~/.arnes/dialects.jsonl, where auto dialect selection reads
      it. Agent runs also record verdicts optimistically, so probing is optional — this
      command exists to check a model before relying on it, or to retest after a failure.
      """)

  @Argument(help: "Model slug (e.g. anthropic/claude-haiku-4.5).")
  var model: String

  @Option(help: "Dialect to probe (messages or responses; default: the model family's native dialect).")
  var dialect: String?

  func run() async throws {
    let service = try makeService()
    let catalog = ModelCatalog(service: service)
    let profile = try await catalog.profile(for: model)
    let target: Dialect
    if let dialect {
      guard let forced = Dialect(rawValue: dialect), forced != .chat else {
        throw ValidationError("probe a native dialect: messages or responses (chat is the universal floor)")
      }
      target = forced
    } else {
      target = profile.dialect
    }
    guard target != .chat else {
      print("\(model) prefers the chat dialect — nothing to probe.")
      return
    }

    let echo = EchoTool()
    let store = DialectVerdictStore()
    let session = Session(
      service: service,
      tools: [echo],
      store: RunRecordStore(),
      dialectStore: store,
      configuration: .init(
        model: model,
        maxStepsPerTurn: 4,
        // Forced, so a broken endpoint fails loudly here instead of falling back.
        dialect: DialectOverride(rawValue: target.rawValue) ?? .auto))

    print("probing \(model) on /\(target.rawValue) …")
    var failure: String?
    do {
      for try await event in await session.send(
        "Call the echo tool exactly once with the text \"ping\", then reply with one word: done.")
      {
        if case .toolCall(let name, _) = event {
          print("→ \(name) call streamed")
        }
      }
    } catch {
      failure = "\(error)"
    }

    let record = await session.lastRecord
    let echoedPing = echo.echoed.contains { $0.contains("ping") }
    let conformant = failure == nil && record?.finished == true && echoedPing
    let reason = failure
      ?? (echoedPing ? "loop did not finish" : "tool call missing or arguments unparsed")
    store.record(model: model, dialect: target, ok: conformant, reason: conformant ? nil : reason)

    if conformant {
      let cost = record.map { String(format: "$%.4f", $0.costUSD) } ?? "?"
      print("✔ conformant — tool round-trip intact on /\(target.rawValue) (\(cost)); recorded ok")
    } else {
      print("✘ not conformant on /\(target.rawValue): \(String(reason.prefix(200)))")
      print("  recorded — auto dialect selection will use chat for this model")
      throw ExitCode.failure
    }
  }
}
