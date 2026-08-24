import ArnesKit
import Foundation

/// Renders `AgentEvent`s to the terminal: streamed text raw, tool activity dimmed,
/// routing in cyan, and a cost/route status line after each turn.
final class Renderer {
  /// Whether any text deltas were printed for the current step (so the duplicate
  /// `assistantText` can be skipped and we just terminate the line).
  private var printedDelta = false
  private var printedReasoning = false

  func beginTurn() {
    printedDelta = false
    printedReasoning = false
  }

  func render(_ event: AgentEvent) {
    switch event {
    case .textDelta(let delta):
      if printedReasoning {
        // Separate the answer from dimmed reasoning output.
        print()
        printedReasoning = false
      }
      printedDelta = true
      print(delta, terminator: "")
      fflush(stdout)

    case .reasoningDelta(let delta):
      printedReasoning = true
      print(ANSI.dim(delta), terminator: "")
      fflush(stdout)

    case .assistantText(let text):
      if printedDelta {
        print() // the streamed deltas already showed the text; end the line
      } else {
        print(text)
      }
      printedDelta = false

    case .toolCall(let name, let arguments):
      endStreamedLineIfNeeded()
      print(ANSI.dim("→ \(name) \(String(arguments.prefix(120)))"))

    case .toolResult(let name, let preview):
      let firstLine = preview.split(separator: "\n").first.map(String.init) ?? preview
      print(ANSI.dim("← \(name): \(String(firstLine.prefix(120)))"))

    case .toolDenied(let name, _):
      print(ANSI.yellow("⊘ \(name) denied"))

    case .routed(let model, let provider):
      endStreamedLineIfNeeded()
      print(ANSI.cyan("⇄ \(model)\(provider.map { " (\($0))" } ?? "")"))

    case .verifier(let passed, let verdict):
      print(passed ? ANSI.green("✔ \(verdict)") : ANSI.red("✘ \(verdict)"))

    case .interrupted:
      endStreamedLineIfNeeded()
      print(ANSI.yellow("⏹ interrupted"))

    case .turnFinished(let stats):
      endStreamedLineIfNeeded()
      let served = stats.routedModels.joined(separator: ", ")
      let route = served.isEmpty || served == stats.requestedModel
        ? stats.requestedModel
        : "\(stats.requestedModel) → \(served)"
      print(ANSI.dim(
        "─ \(route) · \(stats.steps) steps · \(stats.toolCalls) tools · "
          + "turn \(Self.usd(stats.turnCostUSD)) · session \(Self.usd(stats.sessionCostUSD))"))
    }
  }

  private func endStreamedLineIfNeeded() {
    if printedDelta || printedReasoning {
      print()
      printedDelta = false
      printedReasoning = false
    }
  }

  static func usd(_ value: Double) -> String {
    String(format: "$%.4f", value)
  }
}
