import Foundation

/// Slash-command autocomplete: the pure pieces — the candidate list, the live filter as the
/// user types, and the popup rows the Screen draws under the input box. `LineReader` drives
/// it (Tab inserts the highlighted command, ↑/↓ move the highlight, Esc dismisses); nothing
/// here touches the terminal, so all of it is testable.
enum SlashCompletion {
  struct Item: Equatable {
    /// Includes the leading `/` (`/model`).
    let name: String
    /// One short clause shown dim beside the name.
    let hint: String
  }

  /// Rows visible at once; the window scrolls to keep the highlight in view.
  static let maxVisible = 6

  /// The built-ins, in the help panel's order. Hints are clauses, not sentences —
  /// the popup is one line per command.
  static let builtins: [Item] = [
    Item(name: "/model", hint: "show or switch the model — fuzzy search"),
    Item(name: "/models", hint: "list the provider's models"),
    Item(name: "/cost", hint: "running session cost"),
    Item(name: "/context", hint: "what the next request spends the window on"),
    Item(name: "/btw", hint: "side question — answered, never remembered"),
    Item(name: "/effort", hint: "reasoning-effort dial"),
    Item(name: "/thinking", hint: "show/hide streamed reasoning"),
    Item(name: "/budget", hint: "session cost ceiling"),
    Item(name: "/schema", hint: "JSON schema for each turn's answer"),
    Item(name: "/verify", hint: "verify the last turn with a second model"),
    Item(name: "/compact", hint: "summarize older turns to free context"),
    Item(name: "/save", hint: "name this session for later resume"),
    Item(name: "/resume", hint: "switch to another saved session"),
    Item(name: "/fork", hint: "branch this session into a copy"),
    Item(name: "/clear", hint: "clear the conversation history"),
    Item(name: "/status", hint: "session, model, dialect, mode, ctx %"),
    Item(name: "/permissions", hint: "show or switch the permission mode"),
    Item(name: "/plan", hint: "propose read-only, then approve/revise/cancel"),
    Item(name: "/skills", hint: "list loaded skills"),
    Item(name: "/agents", hint: "list subagents; pin one to a model"),
    Item(name: "/tasks", hint: "background subagents and shell jobs"),
    Item(name: "/memory", hint: "the project's memory index"),
    Item(name: "/rewind", hint: "restore files/conversation to a turn"),
    Item(name: "/undo", hint: "put back the last turn's files"),
    Item(name: "/diff", hint: "uncommitted changes"),
    Item(name: "/mcp", hint: "connected MCP servers, tools, prompts"),
    Item(name: "/help", hint: "all commands"),
    Item(name: "/exit", hint: "leave"),
  ]

  /// The full candidate list: built-ins, then skills (`/init` is a built-in skill and
  /// arrives here), then MCP server prompts — a skill or prompt shadowed by a built-in
  /// name is dropped, matching dispatch precedence.
  static func items(skills: [String], prompts: [String]) -> [Item] {
    var seen = Set(builtins.map { $0.name.lowercased() })
    var all = builtins
    for name in skills.sorted() {
      let slash = "/" + name
      guard seen.insert(slash.lowercased()).inserted else { continue }
      all.append(Item(name: slash, hint: "skill"))
    }
    for name in prompts.sorted() {
      let slash = "/" + name
      guard seen.insert(slash.lowercased()).inserted else { continue }
      all.append(Item(name: slash, hint: "MCP prompt"))
    }
    return all
  }

  /// The command token being typed, or nil when the popup has no business showing:
  /// the buffer must start with `/` (leading whitespace tolerated) and contain no
  /// whitespace yet — once a space follows the command, arguments are being typed.
  static func query(for buffer: String) -> String? {
    let trimmed = buffer.drop(while: { $0 == " " })
    guard trimmed.first == "/" else { return nil }
    let token = trimmed.dropFirst()
    guard !token.contains(where: { $0 == " " || $0 == "\t" }) else { return nil }
    return token.lowercased()
  }

  /// Live filter: exact name first, then prefix matches, then substring matches —
  /// each group in the candidate list's own order. An empty query (a bare `/`)
  /// shows everything.
  static func matches(for buffer: String, in items: [Item]) -> [Item] {
    guard let query = query(for: buffer) else { return [] }
    guard !query.isEmpty else { return items }
    let needle = "/" + query
    var exact: [Item] = []
    var prefixes: [Item] = []
    var substrings: [Item] = []
    for item in items {
      let name = item.name.lowercased()
      if name == needle {
        exact.append(item)
      } else if name.hasPrefix(needle) {
        prefixes.append(item)
      } else if name.dropFirst().contains(query) {
        substrings.append(item)
      }
    }
    return exact + prefixes + substrings
  }

  /// What Tab inserts: the command plus a space, ready for arguments.
  static func accepted(_ item: Item) -> String { item.name + " " }

  /// The popup rows, styled — a window of `maxVisible` around the highlight, with dim
  /// `… N more` markers when the list continues past either edge. Empty when nothing
  /// matches. The Screen clamps each row to the terminal width.
  static func lines(matches: [Item], selected: Int) -> [String] {
    guard !matches.isEmpty else { return [] }
    let selected = max(0, min(selected, matches.count - 1))
    var start = 0
    if matches.count > maxVisible {
      start = max(0, min(selected - maxVisible + 1, matches.count - maxVisible))
    }
    let end = min(matches.count, start + maxVisible)
    var rows: [String] = []
    if start > 0 {
      rows.append("  " + ANSI.dim("… \(start) more"))
    }
    let nameWidth = matches[start..<end].map { $0.name.count }.max() ?? 0
    for index in start..<end {
      let item = matches[index]
      let name = TerminalText.sanitize(item.name)
      let pad = String(repeating: " ", count: nameWidth - item.name.count + 2)
      let hint = ANSI.dim(TerminalText.sanitize(item.hint))
      rows.append(index == selected
        ? ANSI.accent("❯ ") + ANSI.accentBold(name) + pad + hint
        : "  " + name + pad + hint)
    }
    if end < matches.count {
      rows.append("  " + ANSI.dim("… \(matches.count - end) more — keep typing"))
    }
    return rows
  }
}
