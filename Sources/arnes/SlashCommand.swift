import Foundation

/// REPL slash commands. Parsing only — behavior lives in `Interactive`.
enum SlashCommand {
  case model(query: String?)
  case cost
  case verify(model: String?)
  case compact(model: String?)
  case save(name: String?)
  case resume(query: String?)
  case clear
  case status
  case skills
  case help
  case exit
  /// Not a built-in — the REPL tries skill names before reporting it (original case kept).
  case unknown(name: String, argument: String?)

  /// nil when the line is a normal message, not a slash command.
  static func parse(_ line: String) -> SlashCommand? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("/") else { return nil }
    let parts = trimmed.dropFirst().split(separator: " ", maxSplits: 1)
    let command = parts.first.map(String.init)?.lowercased() ?? ""
    let argument = parts.count > 1
      ? String(parts[1]).trimmingCharacters(in: .whitespaces)
      : nil

    switch command {
    case "model": return .model(query: argument)
    case "cost": return .cost
    case "verify": return .verify(model: argument)
    case "compact": return .compact(model: argument)
    case "save": return .save(name: argument)
    case "resume": return .resume(query: argument)
    case "clear": return .clear
    case "status": return .status
    case "skills": return .skills
    case "help": return .help
    case "exit", "quit", "q": return .exit
    default: return .unknown(name: parts.first.map(String.init) ?? command, argument: argument)
    }
  }

  static let helpText = """
    /model [query]   show the current model, or switch — fuzzy search, e.g. /model sonnet
    /cost            running session cost
    /verify [model]  verify the last turn with a second model (default: openrouter/auto)
    /compact [model] summarize older turns to free context (also automatic at ~80% full)
    /save [name]     name this session for later /resume
    /resume [id|name] switch to another saved session (most recent other one when omitted)
    /clear           clear the conversation history
    /status          session id, model, messages, cost
    /skills          list loaded skills (the model invokes them via the skill tool)
    /<skill> [args]  run a skill by name — args fill $ARGUMENTS and $1–$9 in its body
    /help            this help
    /exit            leave (also Ctrl-D, or Ctrl-C twice on an empty line)
    ctrl+o           toggle concise/verbose tool output (works mid-turn too)
    """
}
