import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - TerminalPermissions

/// Interactive y/n/a gate for mutating tools. `allowAlwaysThisSession` is remembered
/// by the `Session`, so each tool prompts at most once after an `a`.
struct TerminalPermissions: PermissionDelegate {
  /// Stopped before prompting so an animating wait line can't clobber the question.
  let spinner: Spinner?
  /// While a turn streams, the key watcher owns stdin — the y/n/a keypress must
  /// come through it, or two blocking readers would steal each other's bytes.
  let keys: KeyWatcher?
  /// Routes the question above the pinned input box; nil prints inline (headless paths).
  let screen: Screen?
  /// Esc at the prompt doesn't just deny the one tool — it cancels the whole turn.
  let onEscape: (@Sendable () -> Void)?

  init(spinner: Spinner? = nil, keys: KeyWatcher? = nil, screen: Screen? = nil, onEscape: (@Sendable () -> Void)? = nil) {
    self.spinner = spinner
    self.keys = keys
    self.screen = screen
    self.onEscape = onEscape
  }

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    spinner?.stop()
    let question = "allow? [y]es · [n]o · [a]lways this session"
    let pinned = screen?.isActive == true
    if pinned, let screen {
      screen.print(ANSI.yellow("⚠ \(summary)"))
      screen.setStatus(ANSI.bold(question) + " ")
    } else {
      print("\n" + ANSI.yellow("⚠ \(summary)"))
      print("  \(question): ", terminator: "")
      fflush(stdout)
    }
    let answer: String?
    if let keys, keys.isActive {
      answer = await keys.readKey()
    } else {
      answer = Self.readKey()
    }
    let shown: String
    switch answer {
    case "\u{1B}": shown = "esc"
    case .some(let key): shown = key < " " ? "" : key // don't echo raw control bytes
    case nil: shown = ""
    }
    if pinned, let screen {
      screen.setStatus(nil)
      screen.print(ANSI.dim("  \(question): ") + shown)
    } else {
      print(shown)
    }
    switch answer?.lowercased() {
    case "y":
      spinner?.start("running \(toolName)")
      return .allow
    case "a":
      spinner?.start("running \(toolName)")
      return .allowAlwaysThisSession
    case "\u{1B}":
      onEscape?()
      return .deny(reason: "user interrupted")
    default:
      return .deny(reason: "user declined")
    }
  }

  /// Single raw keypress on a TTY; first character of a line otherwise (piped input).
  private static func readKey() -> String? {
    guard isatty(STDIN_FILENO) != 0 else {
      return readLine().map { String($0.prefix(1)) }
    }
    var original = termios()
    tcgetattr(STDIN_FILENO, &original)
    var raw = original
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    defer {
      var restore = original
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &restore)
    }
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) == 1 else { return nil }
    return String(UnicodeScalar(byte))
  }
}

// MARK: - InterruptController

/// Bridges SIGINT to cancellation of the in-flight turn's task.
final class InterruptController: @unchecked Sendable {
  private let lock = NSLock()
  private var task: Task<Void, Never>?

  func set(_ newTask: Task<Void, Never>?) {
    lock.lock()
    task = newTask
    lock.unlock()
  }

  func interrupt() {
    lock.lock()
    task?.cancel()
    lock.unlock()
  }
}

// MARK: - Interactive

struct Interactive: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "interactive",
    abstract: "Start an interactive agent session (the default when no subcommand is given).")

  @Argument(help: "Optional first message to send.")
  var prompt: String?

  @Option(name: .shortAndLong, help: "OpenRouter model slug (default: openrouter/auto).")
  var model = "openrouter/auto"

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  @Option(help: "Resume a saved session by id (see `arnes sessions`).")
  var resume: String?

  @Flag(name: .customLong("continue"), help: "Resume the most recent session.")
  var continueMostRecent = false

  @Flag(help: "Deny all mutating tools instead of prompting.")
  var safe = false

  @Flag(help: "Skip connecting MCP servers from ~/.arnes/mcp.json.")
  var noMcp = false

  @Flag(help: "Skip loading skills from .arnes/skills, .claude/skills, and ~/.arnes/skills.")
  var noSkills = false

  func run() async throws {
    let service = try makeService()
    let sessionStore = SessionStore()
    let spinner = Spinner()
    let keys = KeyWatcher()
    // The pinned bottom bar: transcript scrolls above it, input/status stay below.
    // Inactive when either fd is piped, leaving output identical to plain printing.
    let screen = Screen()
    screen.measureOrigin()
    screen.startAtTop()
    if screen.isActive {
      spinner.sink = { screen.setStatus($0) }
    }
    let interrupts = InterruptController()
    let permissions: any PermissionDelegate = safe
      ? DenyMutationsPermissions()
      : TerminalPermissions(spinner: spinner, keys: keys, screen: screen, onEscape: { interrupts.interrupt() })
    let fallbacks = fallback.split(separator: ",").map(String.init)
    let requested = try loadSessionIfRequested(store: sessionStore)
    let mcp = await MCPSetup.connect(enabled: !noMcp, spinner: spinner, quiet: true)
    let skills = noSkills ? [] : SkillLibrary.discover()
    let skillTools: [any AgentTool] = skills.isEmpty ? [] : [SkillTool(skills: skills)]
    let tools = Session.defaultTools + skillTools + mcp.tools
    let mcpServers = Set(mcp.tools.compactMap { ($0 as? MCPTool)?.server }).count

    var session: Session
    if let loaded = requested {
      session = Session(
        resuming: loaded,
        service: service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        configuration: Session.Configuration(model: loaded.model, fallbackModels: fallbacks))
      let label = loaded.meta.name ?? loaded.meta.id
      screen.print(Header.banner(
        version: arnesVersion,
        model: loaded.model,
        dialect: "auto",
        mcpServers: mcpServers,
        mcpTools: mcp.tools.count,
        skills: skills.count,
        resumeLine: "resumed \(label) · \(loaded.messages.count) messages · \(Renderer.usd(loaded.costUSD))"))
    } else {
      session = Session(
        service: service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        configuration: Session.Configuration(model: model, fallbackModels: fallbacks))
      screen.print(Header.banner(
        version: arnesVersion,
        model: model,
        dialect: "auto",
        mcpServers: mcpServers,
        mcpTools: mcp.tools.count,
        skills: skills.count))
    }

    // At the prompt, raw mode owns Ctrl-C as a byte; during a turn, this source
    // turns SIGINT into cancellation of the in-flight task.
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler { interrupts.interrupt() }
    sigintSource.resume()

    // Window resizes redraw the bar at the new size and re-pin it to the bottom.
    signal(SIGWINCH, SIG_IGN)
    let sigwinchSource = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
    sigwinchSource.setEventHandler { screen.handleResize() }
    sigwinchSource.resume()
    defer { sigwinchSource.cancel() }

    let reader = LineReader(
      historyURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/history"))
    reader.screen = screen
    let renderer = Renderer(screen: screen.isActive ? screen : nil)

    // Ctrl-O toggles concise/verbose tool output — mid-turn via the key watcher,
    // at the prompt via the line reader.
    let toggleVerbosity: @Sendable () -> Void = {
      spinner.stop()
      let on = renderer.toggleVerbose()
      let notice = ANSI.dim(on
        ? "◐ verbose tool output — ctrl+o to condense"
        : "◑ concise tool output — ctrl+o for full arguments")
      if screen.isActive {
        screen.print(notice)
      } else {
        print("\r\u{1B}[K" + notice)
      }
    }
    keys.onCtrlO = toggleVerbosity
    keys.onInterrupt = { interrupts.interrupt() }
    keys.onTypeahead = { fragment, queued in screen.setTypeahead(fragment, queued: queued) }
    keys.onCursorReport = { row in screen.reportCursorRow(row) }
    reader.onCtrlO = toggleVerbosity
    reader.onCursorReport = { row in screen.reportCursorRow(row) }

    // Typing during a turn queues input: completed lines (Enter pressed) run as the
    // next messages in order, an unfinished fragment pre-fills the next prompt.
    var queued: [String] = []
    var prefill = ""
    func absorbTypeahead() {
      let typed = prefill + keys.drainTypeahead()
      prefill = ""
      guard !typed.isEmpty else { return }
      var lines = typed.components(separatedBy: "\n")
      prefill = lines.removeLast()
      queued.append(contentsOf: lines
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty })
    }

    if let prompt {
      // `arnes ghosty` when "ghosty" is a saved session is almost always a typo'd
      // resume, not a one-word first message — send it anyway, but say so.
      if requested == nil,
         let match = (try? sessionStore.list())?.first(where: { $0.name?.lowercased() == prompt.lowercased() }),
         let name = match.name
      {
        screen.print(ANSI.dim("hint: \"\(name)\" is a saved session — did you mean: arnes resume \(name)"))
      }
      screen.print("› \(prompt)")
      await runTurn(prompt, session: session, renderer: renderer, interrupts: interrupts, spinner: spinner, keys: keys, screen: screen)
      absorbTypeahead()
    }

    while true {
      let text: String
      var echoed = false
      if !queued.isEmpty {
        text = queued.removeFirst()
        screen.print("› \(text)") // echo the line typed during the previous turn
        echoed = true
      } else {
        guard let line = reader.readLine(prompt: "› ", initial: prefill) else { break }
        prefill = ""
        text = line.trimmingCharacters(in: .whitespaces)
      }
      if text.isEmpty { continue }
      if screen.isActive, !echoed {
        screen.print("› \(text)") // the box cleared on submit; keep the line in the transcript
      }
      if let command = SlashCommand.parse(text) {
        // /resume swaps the live session, so it's handled here where `session` is ours.
        if case .resume(let query) = command {
          if let switched = await resumeSession(
            query, currentId: session.id, service: service, tools: tools,
            permissions: permissions, sessionStore: sessionStore, fallbacks: fallbacks, screen: screen)
          {
            session = switched
          }
          continue
        }
        // /name [args] runs a skill of that name as a turn (built-ins take precedence).
        if case .unknown(let name, let argument) = command,
           let skill = skills.first(where: { $0.name == name })
        {
          await runTurn(
            skill.invocationPrompt(arguments: argument),
            session: session, renderer: renderer, interrupts: interrupts,
            spinner: spinner, keys: keys, screen: screen)
          absorbTypeahead()
          continue
        }
        if await handle(command, session: session, spinner: spinner, screen: screen, skills: skills) { break }
        continue
      }
      await runTurn(text, session: session, renderer: renderer, interrupts: interrupts, spinner: spinner, keys: keys, screen: screen)
      absorbTypeahead()
    }
    await mcp.provider.shutdown()
    screen.close()
    print(ANSI.dim("session \(session.id.prefix(8))… · total \(Renderer.usd(await session.costUSD))"))
  }

  // MARK: Turns

  private func runTurn(
    _ text: String,
    session: Session,
    renderer: Renderer,
    interrupts: InterruptController,
    spinner: Spinner,
    keys: KeyWatcher,
    screen: Screen)
    async
  {
    renderer.beginTurn()
    keys.start()
    screen.setPlaceholder(Screen.busyPlaceholder)
    defer {
      keys.stop()
      screen.setPlaceholder(Screen.idlePlaceholder)
    }
    let task = Task {
      spinner.start("waiting for model")
      do {
        for try await event in await session.send(text) {
          spinner.stop()
          renderer.render(event)
          if let label = Self.waitLabel(after: event) {
            spinner.start(label)
          }
        }
      } catch {
        spinner.stop()
        screen.print(ANSI.red("error: \(error)"))
      }
      spinner.stop()
    }
    interrupts.set(task)
    await task.value
    interrupts.set(nil)
    spinner.stop()
  }

  /// What to show while waiting for the next event — nil while text is streaming,
  /// since a spinner redraw would clobber the open line.
  private static func waitLabel(after event: AgentEvent) -> String? {
    switch event {
    case .textDelta, .reasoningDelta:
      return nil
    case .toolCall(let name, _):
      return "running \(name)"
    case .toolResult, .toolDenied:
      return "thinking"
    default:
      return "waiting for model"
    }
  }

  // MARK: Slash commands

  /// Returns true when the REPL should exit.
  private func handle(_ command: SlashCommand, session: Session, spinner: Spinner, screen: Screen, skills: [Skill]) async -> Bool {
    switch command {
    case .model(let query):
      await handleModel(query, session: session, spinner: spinner, screen: screen)

    case .cost:
      screen.print("session \(Renderer.usd(await session.costUSD))")

    case .verify(let verifier):
      spinner.start("verifying")
      defer { spinner.stop() }
      do {
        let (passed, verdict) = try await session.verifyLastTurn(model: verifier ?? "openrouter/auto")
        spinner.stop()
        screen.print(passed ? ANSI.green("✔ \(verdict)") : ANSI.red("✘ \(verdict)"))
      } catch SessionError.nothingToVerify {
        spinner.stop()
        screen.print(ANSI.dim("nothing to verify yet — send a message first"))
      } catch {
        spinner.stop()
        screen.print(ANSI.red("verify failed: \(error)"))
      }

    case .compact(let summarizer):
      spinner.start("compacting")
      defer { spinner.stop() }
      do {
        let result = try await session.compact(with: summarizer)
        spinner.stop()
        if result.summarizedMessages == 0 {
          screen.print(ANSI.dim("nothing to compact yet — only the current turn is in context"))
        } else {
          screen.print(ANSI.dim(
            "◈ compacted \(result.summarizedMessages) messages into a summary · "
              + "\(result.keptMessages) kept · cost \(Renderer.usd(result.costUSD))"))
        }
      } catch {
        spinner.stop()
        screen.print(ANSI.red("compact failed: \(error)"))
      }

    case .save(let name):
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMdd-HHmm"
      let resolved = name ?? "session-\(formatter.string(from: Date()))"
      do {
        try await session.save(name: resolved)
        screen.print("saved as \(ANSI.bold(resolved)) — resume with: arnes resume \(resolved)")
      } catch {
        screen.print(ANSI.red("save failed: \(error)"))
      }

    case .resume:
      break // handled in the REPL loop, which owns the session binding

    case .clear:
      await session.clearHistory()
      screen.print(ANSI.dim("history cleared"))

    case .status:
      let id = session.id
      let model = await session.model
      let messages = await session.messageCount
      let cost = await session.costUSD
      screen.print("session \(id)\nmodel   \(model)\nmessages \(messages)\ncost    \(Renderer.usd(cost))")

    case .skills:
      if skills.isEmpty {
        screen.print(ANSI.dim(
          "no skills loaded — add <name>/SKILL.md under .arnes/skills, .claude/skills, or ~/.arnes/skills"))
      } else {
        let rows = skills.map { skill in
          "\(ANSI.bold(skill.name))  \(ANSI.dim(skill.description.isEmpty ? skill.directory.path : skill.description))"
        }
        screen.print(rows.joined(separator: "\n"))
      }

    case .help:
      screen.print(SlashCommand.helpText)

    case .unknown(let name, _):
      screen.print(ANSI.dim("unknown command /\(name)\n") + SlashCommand.helpText)

    case .exit:
      return true
    }
    return false
  }

  private func handleModel(_ query: String?, session: Session, spinner: Spinner, screen: Screen) async {
    guard let query else {
      screen.print("model \(ANSI.bold(await session.model))\n" + ANSI.dim("switch with /model <query>, e.g. /model sonnet"))
      return
    }
    spinner.start("searching models")
    defer { spinner.stop() }
    do {
      let results = try await session.searchModels(query, limit: 8)
      spinner.stop()
      guard let best = results.first else {
        screen.print(ANSI.dim("no models match \"\(query)\" — try `arnes models \(query)`"))
        return
      }
      if results.count == 1 || best.id.lowercased() == query.lowercased() {
        let profile = try await session.setModel(best.id)
        var line = "model → \(ANSI.bold(profile.id))"
        if let context = profile.contextLength {
          line += ANSI.dim(" · ctx \(context / 1000)k")
        }
        if let price = profile.promptPricePerToken {
          line += ANSI.dim(String(format: " · in $%.2f/Mtok", price * 1_000_000))
        }
        screen.print(line)
        if !profile.supportsTools {
          screen.print(ANSI.yellow("⚠ \(profile.id) does not support tools — the agent loop will be chat-only"))
        }
      } else {
        screen.print(ANSI.dim("matches:"))
        for profile in results {
          let context = profile.contextLength.map { "\($0 / 1000)k" } ?? "?"
          screen.print("  \(profile.id)  \(ANSI.dim("ctx \(context)"))")
        }
        screen.print(ANSI.dim("narrow the query or use the full slug"))
      }
    } catch {
      spinner.stop()
      screen.print(ANSI.red("model search failed: \(error)"))
    }
  }

  /// `/resume [id|name]`: loads another saved session and returns it to swap into the
  /// REPL; prints why and returns nil when nothing (unambiguous) matches. Resolution
  /// mirrors `arnes resume`: exact id, unique id prefix, or saved name — most recent
  /// *other* session when the query is omitted (the current one is always excluded;
  /// it's already live and continuously persisted).
  private func resumeSession(
    _ query: String?,
    currentId: String,
    service: OpenRouterService,
    tools: [any AgentTool],
    permissions: any PermissionDelegate,
    sessionStore: SessionStore,
    fallbacks: [String],
    screen: Screen)
    async -> Session?
  {
    do {
      let others = try sessionStore.list().filter { $0.id != currentId }
      guard !others.isEmpty else {
        screen.print(ANSI.dim("no other sessions to resume — /save names this one for later"))
        return nil
      }
      let meta = try Resume.resolve(query, in: others)
      let loaded = try sessionStore.load(id: meta.id)
      let session = Session(
        resuming: loaded,
        service: service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        configuration: Session.Configuration(model: loaded.model, fallbackModels: fallbacks))
      let label = loaded.meta.name ?? String(loaded.meta.id.prefix(8))
      screen.print(ANSI.dim(
        "↩ resumed \(label) · \(loaded.messages.count) messages · "
          + "\(Renderer.usd(loaded.costUSD)) · model \(loaded.model)"))
      return session
    } catch let error as ValidationError {
      screen.print(ANSI.dim(error.message))
      return nil
    } catch {
      screen.print(ANSI.red("resume failed: \(error)"))
      return nil
    }
  }

  private func loadSessionIfRequested(store: SessionStore) throws -> LoadedSession? {
    if let resume {
      return try store.load(id: resume)
    }
    if continueMostRecent {
      guard let recent = store.mostRecent() else {
        throw ValidationError("no sessions to continue — start one first.")
      }
      return try store.load(id: recent.id)
    }
    return nil
  }
}
