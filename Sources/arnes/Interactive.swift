import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - TerminalPermissions

/// Interactive y/n/a gate for mutating tools. `allowAlwaysThisSession` is remembered
/// by the `Session`, so each tool prompts at most once after an `a`.
struct TerminalPermissions: PermissionDelegate {
  /// Stopped before prompting so an animating wait line can't clobber the question.
  let spinner: Spinner?

  init(spinner: Spinner? = nil) {
    self.spinner = spinner
  }

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    spinner?.stop()
    print("\n" + ANSI.yellow("⚠ \(summary)"))
    print("  allow? [y]es · [n]o · [a]lways this session: ", terminator: "")
    fflush(stdout)
    let answer = Self.readKey()
    print(answer ?? "")
    switch answer?.lowercased() {
    case "y":
      return .allow
    case "a":
      return .allowAlwaysThisSession
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
    raw.c_lflag &= ~UInt(ICANON | ECHO)
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

  func run() async throws {
    let service = try makeService()
    let sessionStore = SessionStore()
    let spinner = Spinner()
    let permissions: any PermissionDelegate = safe
      ? DenyMutationsPermissions()
      : TerminalPermissions(spinner: spinner)
    let fallbacks = fallback.split(separator: ",").map(String.init)

    let session: Session
    if let loaded = try loadSessionIfRequested(store: sessionStore) {
      session = Session(
        resuming: loaded,
        service: service,
        permissions: permissions,
        sessionStore: sessionStore,
        configuration: Session.Configuration(model: loaded.model, fallbackModels: fallbacks))
      let label = loaded.meta.name ?? loaded.meta.id
      print(ANSI.dim("resumed \(label) · \(loaded.messages.count) messages · \(loaded.model) · session \(Renderer.usd(loaded.costUSD))"))
    } else {
      session = Session(
        service: service,
        permissions: permissions,
        sessionStore: sessionStore,
        configuration: Session.Configuration(model: model, fallbackModels: fallbacks))
      print(ANSI.dim("arnes · \(model) · /help for commands"))
    }

    // At the prompt, raw mode owns Ctrl-C as a byte; during a turn, this source
    // turns SIGINT into cancellation of the in-flight task.
    let interrupts = InterruptController()
    signal(SIGINT, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    sigintSource.setEventHandler { interrupts.interrupt() }
    sigintSource.resume()

    let reader = LineReader(
      historyURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/history"))
    let renderer = Renderer()

    if let prompt {
      print("› \(prompt)")
      await runTurn(prompt, session: session, renderer: renderer, interrupts: interrupts, spinner: spinner)
    }

    while true {
      guard let line = reader.readLine(prompt: "› ") else { break }
      let text = line.trimmingCharacters(in: .whitespaces)
      if text.isEmpty { continue }
      if let command = SlashCommand.parse(text) {
        if await handle(command, session: session, spinner: spinner) { break }
        continue
      }
      await runTurn(text, session: session, renderer: renderer, interrupts: interrupts, spinner: spinner)
    }
    print(ANSI.dim("session \(session.id.prefix(8))… · total \(Renderer.usd(await session.costUSD))"))
  }

  // MARK: Turns

  private func runTurn(
    _ text: String,
    session: Session,
    renderer: Renderer,
    interrupts: InterruptController,
    spinner: Spinner)
    async
  {
    renderer.beginTurn()
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
        print(ANSI.red("error: \(error)"))
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
  private func handle(_ command: SlashCommand, session: Session, spinner: Spinner) async -> Bool {
    switch command {
    case .model(let query):
      await handleModel(query, session: session, spinner: spinner)

    case .cost:
      print("session \(Renderer.usd(await session.costUSD))")

    case .verify(let verifier):
      spinner.start("verifying")
      defer { spinner.stop() }
      do {
        let (passed, verdict) = try await session.verifyLastTurn(model: verifier ?? "openrouter/auto")
        spinner.stop()
        print(passed ? ANSI.green("✔ \(verdict)") : ANSI.red("✘ \(verdict)"))
      } catch SessionError.nothingToVerify {
        spinner.stop()
        print(ANSI.dim("nothing to verify yet — send a message first"))
      } catch {
        spinner.stop()
        print(ANSI.red("verify failed: \(error)"))
      }

    case .compact(let summarizer):
      spinner.start("compacting")
      defer { spinner.stop() }
      do {
        let result = try await session.compact(with: summarizer)
        spinner.stop()
        if result.summarizedMessages == 0 {
          print(ANSI.dim("nothing to compact yet — only the current turn is in context"))
        } else {
          print(ANSI.dim(
            "◈ compacted \(result.summarizedMessages) messages into a summary · "
              + "\(result.keptMessages) kept · cost \(Renderer.usd(result.costUSD))"))
        }
      } catch {
        spinner.stop()
        print(ANSI.red("compact failed: \(error)"))
      }

    case .save(let name):
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyyMMdd-HHmm"
      let resolved = name ?? "session-\(formatter.string(from: Date()))"
      do {
        try await session.save(name: resolved)
        print("saved as \(ANSI.bold(resolved)) — resume with: arnes --resume \(session.id)")
      } catch {
        print(ANSI.red("save failed: \(error)"))
      }

    case .clear:
      await session.clearHistory()
      print(ANSI.dim("history cleared"))

    case .status:
      let id = session.id
      let model = await session.model
      let messages = await session.messageCount
      let cost = await session.costUSD
      print("session \(id)\nmodel   \(model)\nmessages \(messages)\ncost    \(Renderer.usd(cost))")

    case .help:
      print(SlashCommand.helpText)

    case .unknown(let name):
      print(ANSI.dim("unknown command /\(name)\n") + SlashCommand.helpText)

    case .exit:
      return true
    }
    return false
  }

  private func handleModel(_ query: String?, session: Session, spinner: Spinner) async {
    guard let query else {
      print("model \(ANSI.bold(await session.model))\n" + ANSI.dim("switch with /model <query>, e.g. /model sonnet"))
      return
    }
    spinner.start("searching models")
    defer { spinner.stop() }
    do {
      let results = try await session.searchModels(query, limit: 8)
      spinner.stop()
      guard let best = results.first else {
        print(ANSI.dim("no models match \"\(query)\" — try `arnes models \(query)`"))
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
        print(line)
        if !profile.supportsTools {
          print(ANSI.yellow("⚠ \(profile.id) does not support tools — the agent loop will be chat-only"))
        }
      } else {
        print(ANSI.dim("matches:"))
        for profile in results {
          let context = profile.contextLength.map { "\($0 / 1000)k" } ?? "?"
          print("  \(profile.id)  \(ANSI.dim("ctx \(context)"))")
        }
        print(ANSI.dim("narrow the query or use the full slug"))
      }
    } catch {
      spinner.stop()
      print(ANSI.red("model search failed: \(error)"))
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
