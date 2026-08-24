import Foundation

/// REPL slash commands. Parsing only — behavior lives in `Interactive`.
enum SlashCommand {
  case model(query: String?)
  case cost
  case verify(model: String?)
  case compact(model: String?)
  case save(name: String?)
  case clear
  case status
  case help
  case exit
  case unknown(String)

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
    case "clear": return .clear
    case "status": return .status
    case "help": return .help
    case "exit", "quit", "q": return .exit
    default: return .unknown(command)
    }
  }

  static let helpText = """
    /model [query]   show the current model, or switch — fuzzy search, e.g. /model sonnet
    /cost            running session cost
    /verify [model]  verify the last turn with a second model (default: openrouter/auto)
    /compact [model] summarize older turns to free context (also automatic at ~80% full)
    /save [name]     name this session for later --resume
    /clear           clear the conversation history
    /status          session id, model, messages, cost
    /help            this help
    /exit            leave (also Ctrl-D, or Ctrl-C twice on an empty line)
    """
}
