import ArnesKit
import Foundation

/// Renders `AgentEvent`s to the terminal: streamed text markdown-styled, tool activity
/// dimmed, routing in cyan, and a cost/route status line after each turn.
final class Renderer {
  /// Whether any text deltas were printed for the current step (so the duplicate
  /// `assistantText` can be skipped and we just terminate the line).
  private var printedDelta = false
  private var printedReasoning = false
  private var markdown = StreamingMarkdown()

  func beginTurn() {
    printedDelta = false
    printedReasoning = false
    markdown = StreamingMarkdown()
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
      print(markdown.feed(delta), terminator: "")
      fflush(stdout)

    case .reasoningDelta(let delta):
      printedReasoning = true
      print(ANSI.dim(delta), terminator: "")
      fflush(stdout)

    case .assistantText(let text):
      if printedDelta {
        // The streamed deltas already showed the text; emit what's still buffered
        // (a partial line, open styles) and end the line.
        print(markdown.flush())
      } else {
        print(markdown.feed(text) + markdown.flush())
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

    case .dialectFellBack(let dialect, let reason):
      endStreamedLineIfNeeded()
      print(ANSI.yellow("⤵ \(dialect) dialect failed (\(String(reason.prefix(80)))) — fell back to chat, recorded"))

    case .verifier(let passed, let verdict):
      print(passed ? ANSI.green("✔ \(verdict)") : ANSI.red("✘ \(verdict)"))

    case .interrupted:
      endStreamedLineIfNeeded()
      print(ANSI.yellow("⏹ interrupted"))

    case .compacted(let summarized, let kept):
      endStreamedLineIfNeeded()
      print(ANSI.dim("◈ context compacted: \(summarized) older messages summarized · \(kept) kept verbatim"))

    case .turnFinished(let stats):
      endStreamedLineIfNeeded()
      let served = stats.routedModels.joined(separator: ", ")
      let route = served.isEmpty || served == stats.requestedModel
        ? stats.requestedModel
        : "\(stats.requestedModel) → \(served)"
      var footer = "─ \(route) · \(stats.steps) steps · \(stats.toolCalls) tools · "
        + "turn \(Self.usd(stats.turnCostUSD)) · session \(Self.usd(stats.sessionCostUSD))"
      if let used = stats.promptTokens, let context = stats.contextLength, context > 0 {
        footer += " · ctx \(used * 100 / context)%"
      }
      print(ANSI.dim(footer))
    }
  }

  private func endStreamedLineIfNeeded() {
    if printedDelta || printedReasoning {
      print(markdown.flush())
      printedDelta = false
      printedReasoning = false
    }
  }

  static func usd(_ value: Double) -> String {
    String(format: "$%.4f", value)
  }
}
