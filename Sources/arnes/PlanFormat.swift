import ArnesKit
import Foundation

/// How the model's `update_plan` checklist (`AgentEvent.planUpdated`, `Session.lastPlanSteps`)
/// is spelled for the terminal: the headless one-liner, the REPL's checklist lines, the info
/// bar's `plan 2/5` and the `/status` block. Pure — the strings are the model's, so every
/// caller still runs the result through `TerminalText.sanitize`.
enum PlanFormat {
  /// `[x]` completed · `[~]` in progress · `[ ]` pending (an unknown status reads as pending,
  /// as the tool itself renders it).
  static func mark(_ status: String) -> String {
    switch status {
    case "completed": return "[x]"
    case "in_progress": return "[~]"
    default: return "[ ]"
    }
  }

  static func done(_ steps: [(text: String, status: String)]) -> Int {
    steps.filter { $0.status == "completed" }.count
  }

  /// The step in flight: the first `in_progress` one, else the first `pending` one, else nil
  /// (everything done).
  static func current(_ steps: [(text: String, status: String)]) -> String? {
    steps.first { $0.status == "in_progress" }?.text ?? steps.first { $0.status != "completed" }?.text
  }

  /// `☰ plan 2/5 · [~] run tests` — the headless text line and the info bar's segment.
  static func progressLine(_ steps: [(text: String, status: String)]) -> String {
    var line = "☰ plan \(done(steps))/\(steps.count)"
    if let current = current(steps) {
      line += " · \(mark(steps.first { $0.text == current }?.status ?? "pending")) \(current)"
    }
    return line
  }

  /// The short form for the info bar (`plan 2/5`).
  static func summary(_ steps: [(text: String, status: String)]) -> String {
    "plan \(done(steps))/\(steps.count)"
  }

  /// One line per step, the tool's own spelling (`[x] read the code`).
  static func checklistLines(_ steps: [(text: String, status: String)]) -> [String] {
    steps.map { "\(mark($0.status)) \($0.text)" }
  }
}
