import Foundation

/// REPL slash commands. Parsing only — behavior lives in `Interactive`.
enum SlashCommand: Equatable {
  case model(query: String?)
  /// `/models [query]` — list the provider's models (the manifest, filtered like `/model`'s
  /// fuzzy search when a query is given); read-only, `/model <query>` switches.
  case models(query: String?)
  case cost
  case verify(model: String?)
  /// `/compact [model] [instructions]` — the raw argument; `compactArguments` splits it into the
  /// summarizer model (a token with a `/`, or a configured alias) and the steering text.
  case compact(argument: String?)
  case save(name: String?)
  case resume(query: String?)
  /// `/fork [name]` — branch this session into a copy and continue in it.
  case fork(name: String?)
  case clear
  case status
  /// `/permissions` shows the mode; `/permissions <mode>` switches it;
  /// `/permissions show` lists mode + rules + session grants; `/permissions save`
  /// writes this session's grants to the rules file.
  case permissions(mode: String?)
  /// `/plan <task>` — propose in read-only plan mode, then approve · revise · cancel;
  /// nil task = usage line.
  case plan(task: String?)
  case skills
  /// `/agents` lists subagents; `/agents <name> <model>` pins one to a model.
  case agents(argument: String?)
  /// `/tasks` — background subagents: running, and finished but not yet delivered — and the
  /// session's background shell jobs (`bash … background: true`).
  case tasks
  /// `/memory` — the project's memory: where it lives, how much of it is loaded, the index.
  case memory
  /// `/rewind` lists the turns; `/rewind <n> [code|conversation|both]` restores files and/or
  /// the conversation to the start of turn n (both by default), after a y/N.
  case rewind(argument: String?)
  /// `/undo` — put back the files the last turn changed; the conversation stays.
  case undo
  /// `/diff` — uncommitted changes (git), or what changed since the session began (checkpoints).
  case diff
  /// `/context` — what the next request spends the context window on, by contributor.
  case context
  /// `/btw <question>` — a side question over the conversation, never appended to it.
  case btw(question: String?)
  /// `/effort [level|off]` — show or move the reasoning-effort dial (nil = show).
  case effort(level: String?)
  /// `/thinking [on|off]` — show, hide, or (nil) toggle the streamed reasoning display.
  case thinking(mode: String?)
  /// `/budget [usd|off]` — show or set this session's cost ceiling (nil = show).
  case budget(argument: String?)
  /// `/schema [file|json|off]` — show, set or clear the structured-output schema a finished
  /// turn's answer is asked for (nil = show; not persisted, like the budget).
  case schema(argument: String?)
  /// `/mcp [server]` — the connected MCP servers (status, tools, prompts); a name lists that
  /// server's tools and prompts. Information only: the toolset is fixed at session start.
  case mcp(server: String?)
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
    case "models": return .models(query: argument)
    case "cost": return .cost
    case "verify": return .verify(model: argument)
    case "compact": return .compact(argument: argument)
    case "save", "rename": return .save(name: argument)
    case "resume": return .resume(query: argument)
    case "fork": return .fork(name: argument)
    case "clear": return .clear
    case "status": return .status
    case "permissions", "mode": return .permissions(mode: argument)
    case "plan": return .plan(task: argument)
    case "skills": return .skills
    case "agents": return .agents(argument: argument)
    case "tasks": return .tasks
    case "memory": return .memory
    case "rewind": return .rewind(argument: argument)
    case "undo": return .undo
    case "diff": return .diff
    case "context", "ctx": return .context
    case "btw", "aside": return .btw(question: argument)
    case "effort": return .effort(level: argument)
    case "thinking": return .thinking(mode: argument)
    case "budget": return .budget(argument: argument)
    case "schema": return .schema(argument: argument)
    case "mcp": return .mcp(server: argument)
    case "help": return .help
    case "exit", "quit", "q": return .exit
    default: return .unknown(name: parts.first.map(String.init) ?? command, argument: argument)
    }
  }

  /// `/compact [model] [instructions]`: the first token is the summarizer model only when it
  /// names one — it contains a `/` (a slug) or is one of the provider's configured `aliases`
  /// (case-insensitive, resolved to its target) — and everything else is steering text for
  /// this one summary. `/compact focus on the failing test` is all instructions;
  /// `/compact haiku` is a model alone; nil/blank is neither.
  static func compactArguments(_ argument: String?, aliases: [String: String] = [:])
    -> (model: String?, instructions: String?)
  {
    guard let trimmed = argument?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else {
      return (nil, nil)
    }
    let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
    let first = String(parts[0])
    let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
    let alias = aliases.first { $0.key.lowercased() == first.lowercased() }?.value
    if first.contains("/") {
      return (first, rest.flatMap { $0.isEmpty ? nil : $0 })
    }
    if let alias, !alias.isEmpty {
      return (alias, rest.flatMap { $0.isEmpty ? nil : $0 })
    }
    return (nil, trimmed)
  }

  /// The commands whose text reaches the model and may carry a paste placeholder
  /// (`[Pasted text #1 +30 lines]`, `[Image #1 shot.png]`): `/schema` (H1), `/btw` and `/compact`
  /// (Q2) — their argument goes through `expand` (the REPL's `PasteStore.expand`), every other
  /// command comes back unchanged. Applied once, at the door, *after* the echo and the transcript
  /// line (which stay compact) and *before* `compactArguments` splits `/compact`'s text: the
  /// placeholder starts with `[` and carries no `/`, so unexpanded it would land whole in the
  /// instructions branch and the model would read the placeholder literally.
  static func expandingPastes(_ command: SlashCommand, with expand: (String) -> String) -> SlashCommand {
    switch command {
    case .schema(let argument): return .schema(argument: argument.map(expand))
    case .btw(let question): return .btw(question: question.map(expand))
    case .compact(let argument): return .compact(argument: argument.map(expand))
    default: return command
    }
  }

  static let helpText = """
    /model [query]   show the current model, or switch — fuzzy search, e.g. /model sonnet
    /models [query]  list the provider's models (fuzzy-filtered by the query); /model switches
    /cost            running session cost
    /context         what the next request spends the context window on, by contributor
    /btw <question>  ask a side question over the conversation — answered, never remembered
    /effort [level]  show or set the reasoning-effort dial: minimal · low · medium · high ·
                     xhigh · max · none · off (off = no dial; persists with the session)
    /thinking [on|off] show or hide streamed reasoning (also ctrl+t; the model still thinks)
    /budget [usd]    show or set this session's cost ceiling (/budget off lifts it)
    /schema [file|json] ask each finished turn for its answer as one JSON object matching the
                     schema (a path or inline {…}), printed under the reply; /schema off stops,
                     /schema alone shows the one in force (not persisted — pass --output-schema)
    /verify [model]  verify the last turn with a second model (default: openrouter/auto)
    /compact [model] [instructions] summarize older turns to free context (also automatic at
                     ~80% full, after older tool results are cleared from requests); the first
                     word is a model only if it has a / or is a configured alias — the rest
                     steers the summary, e.g. /compact keep every failing test name
    /save [name]     name this session for later /resume (/rename does the same)
    /resume [id|name] switch to another saved session (most recent other one when omitted)
    /fork [name]     branch this session into a copy and continue there (original untouched)
    /clear           clear the conversation history
    /status          session, model, dialect used, effort, provider, sandbox, hooks, ctx %, plan
    /permissions [m] show the permission mode, or switch: default · acceptEdits · plan · bypass
                     /permissions show lists rules + this session's grants; save writes
                     those grants to ~/.arnes/rules.json
    /plan <task>     propose in read-only plan mode, then [a]pprove (execute) · [r]evise · [c]ancel
    /skills          list loaded skills (the model invokes them via the skill tool)
    /agents          list subagents; /agents <name> <model> pins one to a model this session
                     (/agents <name> inherit follows the session model again)
    /tasks           background subagents: running, or finished and waiting for your next message; plus background shell jobs
    /memory          the project's memory (~/.arnes/memory/<project>/MEMORY.md): path, lines, the index
    /rewind [n [what]] list the turns (and the files each changed); /rewind <n> restores files
                     and conversation to the start of turn n — add code / conversation / both
                     (default both); asks y/N. bash edits and commits are not checkpointed
    /undo            put back the files the last turn changed (the conversation stays)
    /diff            uncommitted changes (git), or what changed since the session began
    /mcp [server]    connected MCP servers — status, tools, prompts; /mcp <server> lists its tools;
                     add one with arnes mcp add (a config change shows in the next session)
    /init            write this repo's AGENTS.md (built-in skill; shadow it with your own)
    /<skill> [args]  run a skill by name — args fill $ARGUMENTS and $1–$9 in its body
    ! <command>      run a shell command yourself (the box turns orange); the agent then
                     explains the result concisely — or how to recover from a failure
    /help            this help
    /exit            leave (also Ctrl-D, or Ctrl-C twice on an empty line)
    ctrl+o           toggle concise/verbose tool output (works mid-turn too)
    ctrl+t           show/hide streamed reasoning (works mid-turn too)
    tab              typing / opens command autocomplete: ↑/↓ move, tab inserts the
                     highlighted command, enter runs it, esc dismisses the popup
    """
}
