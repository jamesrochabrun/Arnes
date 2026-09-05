import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - TerminalPermissions

/// Interactive y/n/a gate for mutating tools. `allowAlwaysThisSession` is remembered by
/// the `Session` as a *pattern* (`Bash(git commit *)`, or the tool's name for the file
/// tools), so an `a` covers the kind of call that was approved and nothing wider.
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
  /// The `Notification` hooks (`permission_prompt`), run before the question is shown.
  let notifications: NotificationHooks?
  /// Whether a turn is running right now — the only time stdin is this prompt's to read. nil
  /// means the caller has no notion of turns and every request is asked (the piped/headless
  /// paths). Between turns the line editor owns stdin, so a request arriving then — a background
  /// subagent that outlived its turn — is refused instead of read: see `decide`.
  let turnInFlight: (@Sendable () -> Bool)?

  init(
    spinner: Spinner? = nil,
    keys: KeyWatcher? = nil,
    screen: Screen? = nil,
    onEscape: (@Sendable () -> Void)? = nil,
    notifications: NotificationHooks? = nil,
    turnInFlight: (@Sendable () -> Bool)? = nil)
  {
    self.spinner = spinner
    self.keys = keys
    self.screen = screen
    self.onEscape = onEscape
    self.notifications = notifications
    self.turnInFlight = turnInFlight
  }

  /// Why a request that arrives between turns is refused rather than asked.
  static let noTurnDenial = "no turn in flight — a background subagent cannot be asked for "
    + "permission at the prompt; rerun it in the foreground, or grant what it needs before starting it"

  /// A call the deterministic layer already approved is never a question: an allow rule, a
  /// session grant or `bypass` mode means the user has already answered. It only reaches a
  /// delegate at all so a wrapper (the safety judge) can escalate — and when it does, it
  /// clears `preApproved` first, so the human still sees the prompt below.
  func decide(_ request: PermissionRequest) async -> PermissionDecision {
    guard !request.preApproved else { return .allow }
    return await ask(request)
  }

  /// `~`-abbreviates a home-prefixed absolute path for the one-line prompt.
  static func abbreviateHome(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path == home { return "~" }
    if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
    return path
  }

  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    await ask(PermissionRequest(
      toolName: toolName, summary: summary, argumentsJSON: argumentsJSON, tier: .mutating))
  }

  private func ask(_ request: PermissionRequest) async -> PermissionDecision {
    // The summary carries model-chosen text (a bash command, a path). Control
    // characters in it would let the model redraw this very prompt — a `\r` that
    // overwrites `rm -rf` with `ls` — so they are made visible before display.
    let summary = TerminalText.sanitize(request.summary)
    let pinned = screen?.isActive == true
    // No turn is running: the line editor owns stdin, so a raw read here would race it for
    // the next byte the user types — and take the `y` of "yes, and also…" as an approval, an
    // `a` as a session grant. Only a background subagent that outlived its turn
    // (`joinAtTurnEnd: false`) can ask at this point; it is refused, visibly, never read.
    if let turnInFlight, !turnInFlight(), keys?.isActive != true {
      let line = ANSI.yellow("⚠ \(summary)") + ANSI.dim(" — denied: \(Self.noTurnDenial)")
      if pinned, let screen { screen.print(line) } else { print(line) }
      return .deny(reason: Self.noTurnDenial)
    }
    // A question is about to be asked: the Notification hooks hear about it first (a desktop
    // alert, a bell). Advisory — only a hook that couldn't run has anything to say here.
    if let notifications {
      for notice in await notifications.fire(type: "permission_prompt", message: summary) {
        let line = ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)"))
        if pinned, let screen { screen.print(line) } else { print(line) }
      }
    }
    // Hold, don't just stop: the renderer's per-event spinner restarts race this
    // prompt from another task, and one landing after `setStatus(question)` would
    // overwrite the question — the user then waits on an invisible prompt.
    spinner?.hold()
    // Interactive TTY with the pinned bar: the arrow-key option panel, with a colored
    // change preview for the file-writing tools. Everything else (piped stdin, no
    // watcher) keeps the single-key y/n/a prompt scripts depend on.
    if pinned, let screen, let keys, keys.isActive {
      return await panel(request, summary: summary, screen: screen, keys: keys)
    }
    return await legacyAsk(request, summary: summary, pinned: pinned)
  }

  // MARK: The option panel

  /// The pinned-bar prompt: summary (with a colored diff snippet for `edit_file`/
  /// `write_file`) committed above, the option rows live on the status lines. ↑/↓ move,
  /// Enter confirms, y/n/a and 1–9 jump, Ctrl-O prints the full diff, Esc (or Ctrl-C)
  /// cancels the turn — and any other key changes nothing, so a brushed key can never
  /// answer the question.
  private func panel(
    _ request: PermissionRequest,
    summary: String,
    screen: Screen,
    keys: KeyWatcher) async -> PermissionDecision
  {
    let preview = EditPreview.make(toolName: request.toolName, argumentsJSON: request.argumentsJSON)
    for line in Self.summaryBlock(summary: summary, preview: preview) {
      screen.print(line)
    }
    let options = PermissionPanel.options(
      for: request, root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    var selected = PermissionPanel.initialSelection(for: request, options: options)
    var expanded = false
    let question = "allow \(request.toolName)?"
    func render(deferred: Bool = false) {
      screen.setStatus(lines: PermissionPanel.lines(
        question: question, options: options, selected: selected,
        showsDiffHint: preview != nil && !expanded, deferred: deferred))
    }
    // The deferral notice re-renders with a snapshot: the closure crosses a @Sendable
    // boundary, so it must not capture the loop's mutable state.
    func deferralNotice(selected: Int, showsDiffHint: Bool) -> @Sendable () -> Void {
      { [question, options] in
        screen.setStatus(lines: PermissionPanel.lines(
          question: question, options: options, selected: selected,
          showsDiffHint: showsDiffHint, deferred: true))
      }
    }
    func conclude(_ option: PermissionPanel.Option) -> PermissionDecision {
      screen.setStatus(nil)
      screen.print(ANSI.dim("  \(question) → ") + TerminalText.sanitize(option.label))
      spinner?.release()
      switch option.decision {
      case .allow:
        spinner?.start("running \(request.toolName)")
        return .allow
      case .allowAlways:
        spinner?.start("running \(request.toolName)")
        return .allowAlwaysThisSession
      case .deny:
        return .deny(reason: "user declined")
      }
    }
    render()
    // The whole loop is one prompt session: a key landing between two reads still
    // belongs to the panel, never to the type-ahead buffer.
    keys.beginPrompt()
    defer { keys.endPrompt() }
    while true {
      // Keys typed mid-sentence must not answer the prompt: while type-ahead is live,
      // keystrokes (Enter included — it confirms the highlight) keep going to the input
      // box until the user pauses.
      guard
        let key = await keys.readKey(
          afterQuietFor: KeyWatcher.answerQuietInterval, deferringEnter: true,
          onDefer: deferralNotice(selected: selected, showsDiffHint: preview != nil && !expanded))
      else {
        // The watcher stopped underneath the question (turn cancelled, session ending).
        screen.setStatus(nil)
        spinner?.release()
        return .deny(reason: "user declined")
      }
      switch PermissionPanel.action(for: key) {
      case .move(let delta):
        selected = max(0, min(selected + delta, options.count - 1))
        render()
      case .choose:
        return conclude(options[selected])
      case .pick(let decision):
        if let option = options.first(where: { $0.decision == decision }) {
          return conclude(option)
        }
      case .select(let index):
        if options.indices.contains(index) {
          return conclude(options[index])
        }
      case .cancel:
        screen.setStatus(nil)
        screen.print(ANSI.dim("  \(question) → ") + "esc (turn interrupted)")
        spinner?.release()
        onEscape?()
        return .deny(reason: "user interrupted")
      case .expand:
        if let preview, !expanded {
          expanded = true
          for line in preview.full { screen.print(line) }
          render()
        }
      case .ignore:
        continue
      }
    }
  }

  /// The summary as committed transcript lines: the header yellow, and — when the call is a
  /// file write whose arguments parse — the Kit summary's own mini-diff rows replaced by the
  /// preview's larger colored snippet. Every other tool prints the summary exactly as before.
  static func summaryBlock(summary: String, preview: EditPreview?) -> [String] {
    guard let preview else { return [ANSI.yellow("⚠ \(summary)")] }
    let kept = summary.split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
      .filter { !$0.hasPrefix("  - ") && !$0.hasPrefix("  + ") }
    var out = kept.enumerated().map { index, line in
      ANSI.yellow(index == 0 ? "⚠ \(line)" : line)
    }
    out += preview.snippet
    return out
  }

  /// The pre-panel single-key prompt, kept byte-for-byte for piped stdin and for the rare
  /// TTY without the pinned bar: y approves, a grants, Esc interrupts, anything else denies —
  /// a script's `n` line (or any scripted key) must keep denying deterministically.
  private func legacyAsk(
    _ request: PermissionRequest,
    summary: String,
    pinned: Bool) async -> PermissionDecision
  {
    // A plain out-of-tree read says what `a` will remember — the whole directory, one
    // answer instead of a prompt per file. Model-independent text (the session computed the
    // scope from the resolved path), abbreviated but still sanitized like the summary.
    let question = request.grantScope.map {
      "allow? [y]es · [n]o · [a]lways for \(TerminalText.sanitize(Self.abbreviateHome($0))) this session"
    } ?? "allow? [y]es · [n]o · [a]lways this session"
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
      answer = await keys.readKey(afterQuietFor: KeyWatcher.answerQuietInterval) {
        if pinned, let screen {
          screen.setStatus(ANSI.bold(question) + ANSI.dim(" — pause typing, then answer") + " ")
        }
      }
    } else {
      answer = TerminalInput.readKey()
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
    spinner?.release()
    switch answer?.lowercased() {
    case "y":
      spinner?.start("running \(request.toolName)")
      return .allow
    case "a":
      spinner?.start("running \(request.toolName)")
      return .allowAlwaysThisSession
    case "\u{1B}":
      onEscape?()
      return .deny(reason: "user interrupted")
    default:
      return .deny(reason: "user declined")
    }
  }

}

// MARK: - TerminalUserInput

/// The REPL's answer to the model's `ask_user` question: the question printed above the pinned
/// box (yellow — the model wrote it, and a poisoned file could have phrased it, so it gets the
/// permission summary's untrusted-text posture; an answer is text the model reads, never a
/// grant), the options numbered under it, and one line read from the box as the answer. It
/// shares the permission prompt's collaborators and rules: sanitized text, refused when no turn
/// is in flight (the line editor owns stdin then), the spinner held while the question shows,
/// piped stdin answered by the next input line.
///
/// Capped at `maxQuestionsPerTurn` per turn (`resetTurn()` from `runTurn`), so a model that
/// keeps asking gets "no answer" — an `error:` result the loop guard counts — instead of holding
/// the user hostage. The prompt reads the key watcher's line (`KeyWatcher.readLine`), so the
/// text typed before the question stays a message and the box becomes the answer field.
final class TerminalUserInput: UserInputDelegate, @unchecked Sendable {
  let spinner: Spinner?
  let keys: KeyWatcher?
  let screen: Screen?
  let turnInFlight: (@Sendable () -> Bool)?
  /// The CLI's Notification hooks, told `user_question` before a question is shown — the same
  /// courtesy the permission prompt pays (`permission_prompt`), so an alerting hook fires for a
  /// run that is waiting on the human either way.
  let notifications: NotificationHooks?
  /// Questions answered per turn before the rest are refused.
  let maxQuestionsPerTurn: Int
  /// Seconds to wait for an answer before giving the model "no answer"; nil = wait. Not a
  /// config key yet (a `policies`/`limits` follow-up).
  let timeoutSeconds: Int?

  /// How a line is read when no key watcher owns stdin (piped input): the next input line.
  /// Injectable so tests can script answers without touching the process's stdin.
  let readPipedLine: @Sendable () -> String?

  private let lock = NSLock()
  private var askedThisTurn = 0

  init(
    spinner: Spinner? = nil,
    keys: KeyWatcher? = nil,
    screen: Screen? = nil,
    turnInFlight: (@Sendable () -> Bool)? = nil,
    notifications: NotificationHooks? = nil,
    maxQuestionsPerTurn: Int = 3,
    timeoutSeconds: Int? = nil,
    readPipedLine: @escaping @Sendable () -> String? = { Swift.readLine(strippingNewline: true) })
  {
    self.spinner = spinner
    self.keys = keys
    self.screen = screen
    self.turnInFlight = turnInFlight
    self.notifications = notifications
    self.maxQuestionsPerTurn = maxQuestionsPerTurn
    self.timeoutSeconds = timeoutSeconds
    self.readPipedLine = readPipedLine
  }

  /// Why a question that arrives between turns is refused rather than asked.
  static let noTurnReason = "no turn in flight — a question cannot be asked at the prompt; "
    + "the model is told to make a reasonable assumption"
  static let statusHint = "answer, then Enter · Esc to skip · a number picks an option"

  /// Zeroes the per-turn question count; `runTurn` calls it as the turn begins.
  func resetTurn() {
    lock.withLock { askedThisTurn = 0 }
  }

  func answer(question rawQuestion: String, options rawOptions: [String]) async -> UserAnswer {
    let question = TerminalText.sanitize(rawQuestion)
    let options = rawOptions.map(TerminalText.sanitize)
    let pinned = screen?.isActive == true
    func show(_ line: String) {
      if pinned, let screen { screen.print(line) } else { print(line) }
    }
    // Between turns the line editor owns stdin: a question then (a background run that outlived
    // its turn) is refused, visibly, never read — the permission prompt's rule.
    if let turnInFlight, !turnInFlight(), keys?.isActive != true {
      show(ANSI.yellow("⚠ ? \(question)") + ANSI.dim(" — not asked: \(Self.noTurnReason)"))
      return .unavailable(reason: Self.noTurnReason)
    }
    let over = lock.withLock {
      askedThisTurn += 1
      return askedThisTurn > maxQuestionsPerTurn
    }
    if over {
      let reason = "question limit for this turn reached (\(maxQuestionsPerTurn))"
      show(ANSI.yellow("⚠ ? \(question)") + ANSI.dim(" — not asked: \(reason)"))
      return .unavailable(reason: reason)
    }
    if let notifications {
      for notice in await notifications.fire(type: "user_question", message: question) {
        show(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
      }
    }
    spinner?.hold()
    defer { spinner?.release() }
    // Piped output: start on a fresh line, as the permission prompt does, so the question never
    // lands on the tail of a streamed assistant line.
    show((pinned ? "" : "\n") + ANSI.yellow("? model asks: \(question)"))
    for (index, option) in options.enumerated() {
      show(ANSI.yellow("  \(index + 1)) \(option)"))
    }
    if pinned, let screen {
      screen.setStatus(ANSI.bold(Self.statusHint) + " ")
    } else {
      print("  \(Self.statusHint): ", terminator: "")
      fflush(stdout)
    }
    let read = await readAnswerLine(pinned: pinned)
    let answer: UserAnswer
    switch read {
    case .line(let raw): answer = Self.resolve(raw, options: options)
    case .timedOut: answer = .unavailable(reason: "no answer within \(timeoutSeconds ?? 0)s")
    }
    let echo: String
    switch (answer, read) {
    case (.text(let text), _): echo = text
    case (.unavailable, .line("\u{1B}")): echo = "esc"
    case (.unavailable, _): echo = ""
    }
    if pinned, let screen {
      screen.setStatus(nil)
      screen.print(ANSI.dim("  › ") + ANSI.dim(echo))
    } else {
      print(echo)
    }
    return answer
  }

  private enum Read: Equatable {
    /// The typed line; nil when the input closed or the turn was cancelled under the question.
    case line(String?)
    case timedOut
  }

  /// The raw line: through the key watcher while it owns stdin (with the type-ahead guard and
  /// the optional deadline), else the next line of piped stdin.
  private func readAnswerLine(pinned: Bool) async -> Read {
    guard let keys, keys.isActive else {
      return .line(readPipedLine())
    }
    let read: @Sendable () async -> Read = { [screen] in
      .line(await keys.readLine(afterQuietFor: KeyWatcher.answerQuietInterval) {
        if pinned, let screen {
          screen.setStatus(ANSI.bold(Self.statusHint) + ANSI.dim(" — pause typing, then answer") + " ")
        }
      })
    }
    // A turn cancelled while the question waits (a signal, an embedder's deadline) must release
    // the line, or the session — which awaits this tool's answer — never sees the cancellation.
    return await withTaskCancellationHandler {
      guard let timeoutSeconds else { return await read() }
      return await withTaskGroup(of: Read.self) { group in
        group.addTask { await read() }
        group.addTask {
          try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
          // A sleep cut short by cancellation is not a timeout.
          return Task.isCancelled ? .line(nil) : .timedOut
        }
        let first = await group.next() ?? .line(nil)
        keys.cancelLine()
        group.cancelAll()
        return first
      }
    } onCancel: {
      keys.cancelLine()
    }
  }

  /// What the typed line means: a bare number 1…N picks that option, Esc declines, an empty line
  /// (or a closed input) is no answer, anything else is the answer verbatim.
  static func resolve(_ raw: String?, options: [String]) -> UserAnswer {
    guard let raw else { return .unavailable(reason: "user gave no answer") }
    if raw == "\u{1B}" { return .unavailable(reason: "user declined to answer") }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return .unavailable(reason: "user gave no answer") }
    if let index = Int(trimmed), index >= 1, index <= options.count {
      return .text(options[index - 1])
    }
    return .text(trimmed)
  }
}

// MARK: - NotificationHooks

/// The REPL's `Notification` hooks, bound late: the permission delegate is built before the
/// hooks (and the session id they report) are known, so it holds this box and the REPL fills
/// it in once the session exists — and again when `/resume` or `/fork` swaps the session.
final class NotificationHooks: @unchecked Sendable {
  private let lock = NSLock()
  private var engine: HookEngine?

  func bind(_ engine: HookEngine?) {
    lock.withLock { self.engine = engine }
  }

  /// Runs the hooks for a notification of `type` (`permission_prompt`) about to be shown.
  /// Advisory: output is ignored; only runner errors come back, for the caller to print.
  func fire(type: String, message: String) async -> [HookNotice] {
    guard let engine = lock.withLock({ engine }) else { return [] }
    return await engine.notification(type: type, message: message).notices(for: .notification)
  }
}

// MARK: - StatusInfo

/// Feeds the always-visible line above the input box: session usage (cost, ctx %) and
/// live subagent activity on the left, the active model right-aligned. Observed from
/// the turn's event stream, mutated from slash commands — hence the lock.
final class StatusInfo: @unchecked Sendable {
  private let lock = NSLock()
  private let screen: Screen
  private var model = ""
  private var routedModel: String?  // where the last request actually landed
  private var sessionCostUSD = 0.0
  private var contextPercent: Int?
  private var activeAgents: [String] = []
  /// The model's latest checklist (`.planUpdated`, or `Session.lastPlanSteps` between turns),
  /// shown as `plan 2/5` — the pinned form of the plan, with the checklist itself in the transcript.
  private var plan: [(text: String, status: String)]?

  init(screen: Screen) {
    self.screen = screen
  }

  /// Between turns: the plan the history holds (nil clears the segment — after /clear, a
  /// rewind, a compaction that summarized it away).
  func setPlan(_ steps: [(text: String, status: String)]?) {
    lock.lock()
    plan = steps
    lock.unlock()
    refresh()
  }

  func setModel(_ model: String) {
    lock.lock()
    if model != self.model {
      self.model = model
      routedModel = nil // a swap invalidates where the old model was routing
    }
    lock.unlock()
    refresh()
  }

  /// Seeds the cost display when resuming a saved session mid-flight.
  func setSessionCost(_ usd: Double) {
    lock.lock()
    sessionCostUSD = usd
    lock.unlock()
    refresh()
  }

  /// An interrupted turn can end without a `turnFinished` — drop stale activity.
  func turnEnded() {
    lock.lock()
    activeAgents.removeAll()
    lock.unlock()
    refresh()
  }

  func observe(_ event: AgentEvent) {
    lock.lock()
    switch event {
    case .routed(let model, _):
      routedModel = model
    case .subagentStarted(let name, _, _, _):
      activeAgents.append(name)
    case .subagentBackgrounded(let name, _, _):
      activeAgents.append(name)
    case .subagentFinished(let name, _, _, _, _, _):
      if let index = activeAgents.firstIndex(of: name) {
        activeAgents.remove(at: index)
      }
    case .planUpdated(let steps):
      plan = steps
    case .turnFinished(let stats):
      sessionCostUSD = stats.sessionCostUSD
      if let served = stats.routedModels.last, !served.isEmpty {
        routedModel = served
      }
      if let used = stats.promptTokens, let context = stats.contextLength, context > 0 {
        contextPercent = used * 100 / context
      }
      activeAgents.removeAll() // a finished turn has no agents in flight
    default:
      lock.unlock()
      return
    }
    lock.unlock()
    refresh()
  }

  private func refresh() {
    lock.lock()
    var left = ANSI.dim(Renderer.usd(sessionCostUSD))
    if let contextPercent {
      left += ANSI.dim(" · ctx \(contextPercent)%")
    }
    if let plan, !plan.isEmpty {
      left += ANSI.dim(" · \(PlanFormat.summary(plan))")
    }
    if !activeAgents.isEmpty {
      // Duplicates collapse to a count so parallel same-agent tasks stay short.
      var seen: [String] = []
      for name in activeAgents where !seen.contains(name) {
        seen.append(name)
      }
      let names = seen.map { name in
        let count = activeAgents.filter { $0 == name }.count
        return count > 1 ? "\(name)×\(count)" : name
      }
      left += ANSI.dim(" · ") + ANSI.secondary("✳ \(names.joined(separator: " "))")
    }
    var right = ANSI.dim(model)
    if let routedModel, routedModel != model {
      right += ANSI.dim(" → ") + ANSI.secondary(routedModel)
    }
    lock.unlock()
    screen.setInfo(left: left, right: right)
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

  private var turnInFlight = false

  /// Brackets `runTurn`: raised before the turn's task exists and lowered after it has been
  /// awaited, so a permission request racing the task's very first step still sees a turn.
  func beginTurn() {
    lock.withLock { turnInFlight = true }
  }

  func endTurn() {
    lock.withLock { turnInFlight = false }
  }

  /// Whether a turn is running — true for the whole of `runTurn`. What a background subagent
  /// finishing at the prompt checks before printing its own line (during a turn the session
  /// delivers the report and the renderer prints it in sequence), and what the permission
  /// prompt checks before reading stdin (between turns the line editor owns it).
  var isTurnInFlight: Bool {
    lock.withLock { turnInFlight }
  }
}

// MARK: - Interactive

struct Interactive: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "interactive",
    abstract: "Start an interactive agent session (the default when no subcommand is given).")

  @Argument(help: "Optional first message to send.")
  var prompt: String?

  @Option(name: .shortAndLong, help: "Model slug (default: the provider's default model — openrouter/auto on OpenRouter).")
  var model: String?

  @Option(help: "Fallback models, comma-separated.")
  var fallback = ""

  @Option(help: "Resume a saved session by id (see `arnes sessions`).")
  var resume: String?

  @Flag(name: .customLong("continue"), help: "Resume the most recent session.")
  var continueMostRecent = false

  @Flag(help: "Deny all mutating tools instead of prompting.")
  var safe = false

  @Option(
    name: .customLong("add-dir"),
    help: ArgumentHelp(
      "Also treat this directory as inside the session: reads and writes there are ordinary work instead of gated escapes. Repeatable.",
      valueName: "path"))
  var addDir: [String] = []

  @Flag(help: "Skip connecting MCP servers from ~/.arnes/mcp.json.")
  var noMcp = false

  @Flag(help: "Skip loading skills from .arnes/skills, .claude/skills, ~/.arnes/skills and ~/.claude/skills.")
  var noSkills = false

  @Flag(help: "Disable subagents (the task tool and .arnes/.claude agents).")
  var noAgents = false

  @Flag(name: .customLong("no-memory"), help: "Skip the project's memory (~/.arnes/memory/<project>/MEMORY.md): no # Memory section, and the directory stays harness state the tools cannot touch.")
  var noMemory = false

  @Option(
    name: .customLong("agent-model"),
    help: ArgumentHelp(
      "Pin a subagent to a model: <agent>=<model>. Repeatable.",
      valueName: "agent=model"))
  var agentModel: [String] = []

  @Option(
    name: .customLong("agent"),
    help: ArgumentHelp(
      "Run the session as this agent (the `arnes do --agent` shape): its body becomes the lead's role, its tools/disallowedTools scope the toolset (an explicit tools list leaves delegation out too, unless --allowed-tools names task), and its model, effort, maxTurns and budget apply unless the flag names one; permissionMode readOnly makes the session read-only whatever the mode. Built-ins (general, explore), .arnes/.claude agents (trusted directories) and --agents definitions.",
      valueName: "name"))
  var agentName: String?

  @Option(
    name: .customLong("agents"),
    help: ArgumentHelp(
      "Inline agent definitions — Claude Code's JSON ({\"name\": {\"description\", \"prompt\", \"tools\", \"model\", …}}, or an array of such objects with a \"name\" key), or @path to a file holding it (64 KB cap). Available to --agent and as subagents; an inline agent shadows a discovered one of the same name.",
      valueName: "json|@path"))
  var inlineAgents: String?

  @Option(
    name: .customLong("allowed-tools"),
    help: ArgumentHelp(
      "Keep only these tools (exact names or prefix globs like mcp__github__*; Claude Code spellings such as Read/Edit/Bash/Task accepted). Repeatable or comma-separated; an empty value (\"\") means no tools. Applied before subagents are built, so they inherit the same ceiling. Argument rules (Bash(git status:*)) belong in ~/.arnes/rules.json, not here.",
      valueName: "names"))
  var allowedTools: [String] = []

  @Option(
    name: .customLong("disallowed-tools"),
    help: ArgumentHelp(
      "Remove these tools (same spellings as --allowed-tools; disallow wins where both name a tool). `--disallowed-tools task` removes delegation.",
      valueName: "names"))
  var disallowedTools: [String] = []

  @Option(
    name: .customLong("append-system-prompt"),
    help: ArgumentHelp(
      "Append this text to the system prompt — after the prompt pack, instruction files, environment block and tool sections (after the --agent role too). There is no replace: packs own the base prompt.",
      valueName: "text"))
  var appendSystemPrompt: String?

  @Option(
    name: .customLong("append-system-prompt-file"),
    help: ArgumentHelp(
      "Append this file's contents to the system prompt (after --append-system-prompt when both are given; 64 KB cap).",
      valueName: "path"))
  var appendSystemPromptFile: String?

  @Flag(help: "Load this directory's own .arnes/.claude skills and agents without asking, and remember it as trusted.")
  var trustProject = false

  @Option(help: "Reasoning effort for models that support it: minimal, low, medium, high, xhigh, max, none.")
  var effort: String?

  @Option(name: .customLong("permission-mode"), help: "Permission mode: default, acceptEdits (auto in-tree edits), plan (read-only: the model proposes and each turn ends with approve · revise · cancel), or bypass.")
  var permissionMode: String?

  @Option(help: "Stop a turn once the session's cost reaches this many USD (a budget stop; estimated on gateways that don't report cost). On a resumed session it is this run's allowance on top of what the session already spent — and what is left of it follows a /resume or /fork onto the session swapped in. /budget moves it mid-session.")
  var budget: Double?

  @Option(name: .customLong("max-steps"), help: "Stop a turn after this many model steps (default unlimited — the loop guard and --budget are the guardrails); the turn ends with a step-limit notice, say \"continue\" to keep going.")
  var maxSteps: Int?

  @Option(help: "Wire dialect: auto (native per model family, falling back to chat on a failed conformance verdict), chat, messages, or responses.")
  var dialect = "auto"

  @Option(
    name: .customLong("output-schema"),
    help: ArgumentHelp(
      "Ask every finished turn for its answer as JSON matching this schema (a file path or inline JSON object), printed under the reply; /schema changes or clears it mid-session. Sent as response_format only to models whose manifest advertises it, otherwise as an instruction.",
      valueName: "file|json"))
  var outputSchema: String?

  @OptionGroup var mcpOptions: MCPOptions

  @OptionGroup var providerOptions: ProviderOptions

  /// `--safe` promises a read-only session; `acceptEdits`/`bypass` pre-approve mutations
  /// before the delegate is consulted, so together they would run edits past the deny-all
  /// delegate. Refused at parse time, the same contradiction `arnes do` refuses — as are the
  /// stop-condition flags `do` refuses (a zero step cap, a non-positive budget, an unknown
  /// dialect), before anything connects.
  func validate() throws {
    let mode = try parsePermissionMode(permissionMode)
    if safe, mode == .acceptEdits || mode == .bypass {
      throw ValidationError("--safe and --permission-mode \(mode.label) contradict: --safe is a read-only session, and \(mode.label) pre-approves mutations.")
    }
    if let maxSteps, maxSteps < 1 {
      throw ValidationError("--max-steps must be at least 1.")
    }
    if let budget, budget <= 0 {
      throw ValidationError("--budget must be a positive number of USD.")
    }
    _ = try parseDialect(dialect)
    // A missing or oversized appendix file, or malformed --agents JSON, is a usage error before
    // anything connects (reading them here has no side effect), as on `arnes do`.
    _ = try Do.systemPromptAppendix(text: appendSystemPrompt, file: appendSystemPromptFile)
    _ = try Do.parseInlineAgents(inlineAgents)
    // `--output-schema` loads at parse time too, exactly as on `do` (same message).
    _ = try Do.loadOutputSchema(outputSchema)
  }

  func run() async throws {
    let runtime = try ArnesRuntime.make(providerOptions)
    let service = runtime.service
    let sessionStore = SessionStore()
    let spinner = Spinner()
    // Collapsed pastes' full text — a multi-line paste shows as `[Pasted text #1 +58 lines]`
    // in the input box (prompt and mid-turn alike) and is expanded back when the line runs.
    let pastes = PasteStore()
    let keys = KeyWatcher(pastes: pastes)
    // The pinned bottom bar: transcript scrolls above it, input/status stay below.
    // Inactive when either fd is piped, leaving output identical to plain printing.
    let screen = Screen()
    screen.detectBackground() // darkens the palette on light terminal themes
    screen.measureOrigin()
    screen.startAtTop()
    if screen.isActive {
      spinner.sink = { screen.setStatus($0) }
    }
    let interrupts = InterruptController()
    // Filled in once the hooks are loaded and the session exists (see `bindAgents`).
    let notifications = NotificationHooks()
    // Project-local skills, agents and instruction files are the repository's, not the
    // user's: ask once per directory (remembered) instead of loading them silently. Asked
    // first, because the `--agent` pool below includes a trusted project's agents, and the
    // lead agent decides the permission posture everything after it is built on.
    let trust = ProjectTrustGate.evaluate(
      trustFlag: trustProject, interactive: true,
      instructionOptions: runtime.instructionOptions) { screen.print($0) }
    if let notice = trust.notice { screen.print(ANSI.dim(notice)) }
    // `--agent`: the session runs *as* this definition — the `do --agent` shape, through the
    // same helpers. `--agents` definitions join the pool and shadow discovered ones by name.
    let inlineAgentDefinitions = try Do.parseInlineAgents(inlineAgents)
    let leadAgent = try agentName.map { name in
      try Do.resolveLeadAgent(
        named: name,
        in: AgentLibrary.merge(
          inline: inlineAgentDefinitions,
          discovered: AgentLibrary.discover(includeProject: trust.includeProject)))
    }
    for warning in leadAgent?.warnings ?? [] {
      screen.print(ANSI.yellow(TerminalText.sanitize("⚠ agent '\(leadAgent?.name ?? "")': \(warning)")))
    }
    // The permission posture, decided once (`Do.leadPosture`, pure): the REPL is a consenting
    // human (`yes: true`), so only `--safe` or a read-only agent narrows it — a
    // `permissionMode: readOnly` agent denies every mutation whatever the mode says (never
    // widen), and the mode drops out of an auto-approving one so nothing pre-approves past it.
    let posture = Do.leadPosture(
      agent: leadAgent, mode: try parsePermissionMode(permissionMode), safe: safe, yes: true)
    let mode = posture.mode
    // Whether the delegate refuses every mutation — what the mode tag, the `# Environment`
    // block and `/status` say instead of the mode label.
    let readOnly = posture.readOnly
    let basePermissions: any PermissionDelegate
    switch posture.gate {
    case .safe:
      basePermissions = DenyMutationsPermissions()
    case .agentReadOnly(let leadName):
      basePermissions = DenyMutationsPermissions(
        reason: "agent '\(leadName)' is read-only (permissionMode) — report what you would change instead")
    case .autoApprove, .denyWithoutConsent:
      // The human answers the prompts (`denyWithoutConsent` is unreachable with `yes: true`).
      basePermissions = TerminalPermissions(
        spinner: spinner, keys: keys, screen: screen, onEscape: { interrupts.interrupt() },
        notifications: notifications, turnInFlight: { interrupts.isTurnInFlight })
    }
    // A configured command judge adds its warning to the prompt the human answers (it informs,
    // never overrides — headlessVeto is false in interactive mode).
    //
    // Wrapped once, and the same instance goes to the session and the task tool: a step can
    // run several subagents at once, and two prompts racing for the status line is not a
    // question anyone can answer. `SerializedPermissions` makes them queue — the model's
    // `ask_user` questions included (`--safe` changes nothing there: asking is not a mutation),
    // so a question never opens while a nested y/n prompt is waiting for its key.
    let userInput = TerminalUserInput(
      spinner: spinner, keys: keys, screen: screen, turnInFlight: { interrupts.isTurnInFlight },
      notifications: notifications)
    let permissions = SerializedPermissions(
      runtime.judging(basePermissions, headlessVeto: false), userInput: userInput)
    let fallbacks = fallback.split(separator: ",").map(String.init)
    let requested = try loadSessionIfRequested(store: sessionStore)
    let mcp = try await MCPSetup.connect(
      enabled: !noMcp, options: mcpOptions, spinner: spinner, quiet: true,
      redacting: runtime.redactedEnvironmentKeys,
      // The repository's .mcp.json joins only in a trusted directory (the gate's answer above),
      // as untrusted servers — the same rule `do` and `debug prompt` apply (X9).
      project: trust.includeProject
        ? MCPConfig.projectURL(for: ArnesRuntime.workingDirectory, options: runtime.instructionOptions)
        : nil)
    // Server prompts become `/mcp__<server>__<prompt>` at the prompt (after skills).
    let mcpPrompts = await mcp.provider.prompts
    // What `/mcp` shows: the statuses, tools and prompts as connected at startup (X9).
    let mcpPanel = McpPanel.Snapshot(
      statuses: mcp.statuses,
      tools: mcp.tools.compactMap { $0 as? MCPTool }.map(McpPanel.Tool.init),
      prompts: mcpPrompts.map(McpPanel.Prompt.init),
      configPaths: mcp.configPaths)
    if let failure = await runtime.manifestWarning() {
      screen.print(ANSI.yellow(TerminalText.sanitize(failure)))
    }
    if let warning = runtime.sandboxSupportWarning { screen.print(ANSI.yellow(warning)) }
    if let warning = runtime.hooksWarning { screen.print(ANSI.yellow(TerminalText.sanitize(warning))) }
    let subprocessEnvironment = runtime.subprocessEnvironment
    // `--add-dir` widens what counts as inside; the config's `paths` globs tighten it.
    let addedDirectories = try ArnesRuntime.parseAddedDirectories(addDir)
    // Auto-memory (C3): the project's `~/.arnes/memory/<key>/` — the one place under `~/.arnes`
    // the model may write, through the ordinary file tools. Decided before the tools exist: its
    // directory is the carve-out the path rules and the sandbox open (reads free, writes a loud
    // `.sensitive` prompt), and its index is the `# Memory` section appended below.
    let memoryStore = noMemory
      ? nil
      : runtime.memoryStore(workdir: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    // The paste stash rides the rules too: a dragged image's arnes-made copy is read freely
    // (`view_image` on it never prompts — the drag was the consent).
    let pathRules = runtime.pathRules(
      addedDirectories: addedDirectories, memoryRoot: memoryStore?.directory,
      pasteStash: pastes.stashDirectory)
    // The sandbox (when the provider opts in): writes confined to the working tree plus
    // whatever `--add-dir` opened, so bash and the file tools agree on the same boundary.
    // Interactive sessions stay opt-in — a human is here to answer for what runs.
    let sandboxResolution = runtime.sandboxResolution(
      root: URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
      addedDirectories: addedDirectories, memoryRoot: memoryStore?.directory)
    let sandbox = sandboxResolution.sandbox
    if let warning = runtime.sandboxDenyReadWarning(sandboxResolution) {
      screen.print(ANSI.yellow(TerminalText.sanitize(warning)))
    }
    // File checkpoints for /rewind and /undo (`checkpoints` in the config; on by default): the
    // write tools snapshot each file's pre-image into this store, which is bound to the live
    // session below (`bindCheckpoints`) and rebound whenever /resume or /fork swaps it.
    let checkpoints = runtime.checkpointStore()
    // Background shell jobs (`bash … background: true`, the `job` tool): one registry for the
    // REPL's tools, its jobs killed when the live session ends (exit, /resume, /fork, /clear).
    let jobs = runtime.jobRegistry()
    // Kept: an `isolation: worktree` subagent rebuilds this context over its snapshot. The
    // model's questions go to the terminal through the one prompt queue (`permissions`).
    let toolContext = ToolContext(
      sandbox: sandbox, environment: subprocessEnvironment, pathRules: pathRules,
      bashOutputChars: runtime.limits.effectiveBashOutputChars, userInput: permissions,
      checkpoints: checkpoints, jobs: jobs,
      bashTimeoutSeconds: runtime.limits.effectiveBashTimeoutSeconds, web: runtime.webPolicy)
    let baseTools = HarnessAssembly.coreTools(toolContext)
    // Standing repo instructions (AGENTS.md/CLAUDE.md) → system prompt. Project files load
    // only in a trusted directory; global ~/.arnes always.
    // The dial is the user's: an explicit --effort wins, otherwise a resumed session keeps
    // whatever it was last set to, otherwise the `--agent`'s frontmatter (the "flag absent →
    // frontmatter" rule a subagent gets).
    let explicitEffort = try parseEffort(effort)
    let reasoningEffort = explicitEffort ?? requested?.reasoningEffort ?? leadAgent?.effort
    // The model ladder: a resumed transcript's (a resumed session keeps its model, whatever
    // -m says — /model swaps it) > -m > the agent's frontmatter (resolved against the manifest
    // like a subagent's) > the provider default.
    let model: String
    if let requested {
      model = requested.model
    } else {
      model = try await Do.resolveLeadModel(flag: self.model, resumed: nil, agent: leadAgent, runtime: runtime)
    }
    // Caps: the flag, else the agent's frontmatter (`maxTurns`, `budget`).
    let effectiveMaxSteps = maxSteps ?? leadAgent?.maxSteps
    let effectiveBudget = budget ?? leadAgent?.budgetUSD
    // Persistent allow/ask/deny rules: user-global always, a trusted project's deny/ask too.
    if let warning = runtime.rulesWarning { screen.print(ANSI.yellow(TerminalText.sanitize(warning))) }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let rulesResult = runtime.permissionRules(includeProject: trust.includeProject, workdir: cwd)
    let permissionRules = rulesResult.rules
    if rulesResult.droppedProjectAllows > 0 {
      screen.print(ANSI.dim("· ignored \(rulesResult.droppedProjectAllows) project allow-rule(s) — a repo may tighten, not widen, permissions"))
    }
    let instructions = ProjectInstructions.discovered(
      includeProject: trust.includeProject, options: runtime.instructionOptions)
    let projectInstructions = instructions?.text
    if let sources = instructions?.sources, !sources.isEmpty {
      // `@path` imports land in the same system prompt, so the line names them too.
      let listed = sources.map { source -> String in
        let imports = source.imports.isEmpty
          ? ""
          : " (+\(source.imports.map(\.lastPathComponent).joined(separator: ", ")))"
        return ProjectInstructions.abbreviate(source.path) + imports
      }
      screen.print(ANSI.dim(TerminalText.sanitize("· instructions: " + listed.joined(separator: ", "))))
      if let notice = instructions?.truncationNotice(maxBytes: runtime.instructionOptions.maxBytes) {
        screen.print(ANSI.yellow(TerminalText.sanitize("⚠ " + notice)))
      }
    }
    // A trusted repo's own hooks, hash-approved only; anything skipped is said out loud.
    let hooks = runtime.hooks(cwd: cwd, trusted: trust.includeProject)
    for notice in hooks.notices {
      screen.print(ANSI.yellow(TerminalText.sanitize(notice)))
    }
    // One configuration for the session and for every subagent it spawns: the task tool
    // derives nested sessions from the same value, so nothing is lost on delegation.
    // The stop conditions `do` has: `--budget` is this run's allowance, lifted by what a resumed
    // transcript already cost (`Do.budgetCeiling` — the session compares the ceiling against
    // its cumulative spend); `--max-steps` caps every turn; `--dialect` forces the wire shape.
    let dialectOverride = try parseDialect(dialect)
    var configuration = Session.Configuration(
      model: model,
      fallbackModels: fallbacks,
      maxStepsPerTurn: effectiveMaxSteps ?? .max,
      dialect: dialectOverride,
      // The lead's role and the user's appendix ride the system prompt after the pack,
      // instructions, environment and tool sections — role first, appendix after.
      systemSuffix: Do.composeSystemSuffix(
        agent: leadAgent,
        appendix: try Do.systemPromptAppendix(text: appendSystemPrompt, file: appendSystemPromptFile)),
      projectInstructions: projectInstructions,
      maxCostUSD: Do.budgetCeiling(effectiveBudget, resumedCostUSD: requested?.costUSD),
      hooks: hooks.active,
      reasoningEffort: reasoningEffort,
      provider: runtime.traits,
      subprocessEnvironment: subprocessEnvironment,
      workingDirectory: cwd,
      permissionMode: mode,
      permissionRules: permissionRules,
      hookPromptRunner: runtime.promptHookRunner,
      // `--output-schema` seeds the session's schema dial (`/schema` moves it; validate() checked it).
      outputSchema: try Do.loadOutputSchema(outputSchema))
    // `subagents.joinAtTurnEnd` (default true): a turn waits for its background subagents.
    // Off, the turn ends and a report is delivered at the start of the next message — the
    // REPL says when one is ready (`/tasks` lists them).
    configuration.joinBackgroundAtTurnEnd = runtime.subagentDefaults.joinAtTurnEnd
    // How this session was started, on its transcript's meta line (a resumed one keeps its own).
    configuration.sessionOrigin = "interactive"
    // `limits`: the tool-result cap (spilled under ~/.arnes/tmp/<session>), the loop guard.
    runtime.applyLimits(to: &configuration)
    // A project's `## Compact instructions` steer every compaction's summarizer (C2).
    configuration.compactionInstructions = instructions?.compactInstructions
    configuration.pathRules = pathRules
    // The `# Environment` block (cwd, platform, date, git snapshot, run posture): captured once
    // here, not per turn, so the system prompt stays a stable cache prefix. Subagents render
    // their own from the same facts; `--safe` reads `read-only`, since that delegate refuses
    // every mutation whatever the mode says. The git snapshot is kept so the block can be
    // re-rendered — same tree lines, live model/mode/effort — when /model, /permissions,
    // /effort, /resume or /fork change the posture it states (`refreshEnvironment` below).
    let environmentFacts = runtime.environmentFacts(sandbox: sandbox)
    let environmentSnapshot: EnvironmentContext.Snapshot? = if let environmentFacts {
      await EnvironmentContext.Snapshot.capture(cwd: cwd, facts: environmentFacts)
    } else {
      nil
    }
    if let environmentSnapshot {
      configuration.extraSystemSections = [
        environmentSnapshot.render(
          model: configuration.model, permissionMode: configuration.permissionMode,
          readOnly: readOnly, effort: configuration.reasoningEffort),
      ]
    }
    // The `# Memory` section, after the environment block: the project's MEMORY.md (capped,
    // scanned) or a header saying nothing is saved yet. Captured once, like the block above —
    // a refresh when the model edits the file mid-session needs the same Session seam.
    if let memoryStore {
      configuration.extraSystemSections.append(memoryStore.promptSection())
    }
    let skills = noSkills ? [] : SkillLibrary.discover(includeProject: trust.includeProject)
    let skillTools: [any AgentTool] = skills.isEmpty ? [] : [SkillTool(skills: skills, listingMaxBytes: runtime.skillListingMaxBytes)]
    // `--allowed-tools`/`--disallowed-tools` scope the toolset before subagents are built, so
    // delegated work inherits the same ceiling; the `--agent`'s own tools/disallowedTools
    // narrow it further. `task` is decided the same way (`Do.taskToolPermitted`): built after
    // the filter, and left out by an agent with an explicit tools list unless --allowed-tools
    // names it.
    let scopedTools = try Do.scopedTools(
      baseTools + skillTools + mcp.tools, allowed: allowedTools, disallowed: disallowedTools,
      agent: leadAgent)
    let taskToolPermitted = Do.taskToolPermitted(
      allowed: allowedTools, disallowed: disallowedTools, agent: leadAgent)
    let agents = noAgents || !taskToolPermitted
      ? []
      : AgentLibrary.merge(
        inline: inlineAgentDefinitions,
        discovered: AgentLibrary.discover(includeProject: trust.includeProject))
    let memoryRoot = memoryStore?.directory
    let taskTool: TaskTool? = agents.isEmpty ? nil : TaskTool(
      agents: agents,
      service: service,
      tools: scopedTools,
      permissions: permissions,
      modelOverrides: try Self.parseAgentModels(agentModel),
      catalog: runtime.catalog,
      defaults: runtime.subagentDefaults,
      environment: ProcessInfo.processInfo.environment,
      environmentContext: environmentFacts,
      sessionStore: sessionStore,
      skills: skills,
      toolContext: toolContext,
      makeSandbox: { root in runtime.shellSandbox(root: root, memoryRoot: memoryRoot) },
      memory: memoryStore,
      configuration: configuration)
    let tools = scopedTools + (taskTool.map { [$0] } ?? [])
    let mcpServers = Set(mcp.tools.compactMap { ($0 as? MCPTool)?.server }).count

    var session: Session
    if let loaded = requested {
      session = Session(
        resuming: loaded,
        service: service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        catalog: runtime.catalog,
        configuration: configuration)
      let label = loaded.meta.name ?? loaded.meta.id
      screen.print(Header.banner(
        version: arnesVersion,
        model: loaded.model,
        dialect: dialect,
        provider: runtime.bannerProvider,
        mcpServers: mcpServers,
        mcpTools: mcp.tools.count,
        skills: skills.count,
        agents: agents.count,
        judge: runtime.provider.bashJudge,
        sandbox: ArnesRuntime.bannerSandbox(sandbox),
        hooks: runtime.bannerHooks(hooks),
        effort: reasoningEffort?.rawValue,
        environment: runtime.bannerEnvironment,
        addedDirectories: addedDirectories.count,
        mode: mode == .default ? nil : mode.label,
        memory: ArnesRuntime.bannerMemory(memoryStore),
        agent: leadAgent?.name,
        limits: Self.limitsFact(budget: effectiveBudget, maxSteps: effectiveMaxSteps),
        resumeLine: "resumed \(label) · \(loaded.messages.count) messages · \(Renderer.usd(loaded.costUSD))"))
    } else {
      session = Session(
        service: service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        catalog: runtime.catalog,
        configuration: configuration)
      screen.print(Header.banner(
        version: arnesVersion,
        model: model,
        dialect: dialect,
        provider: runtime.bannerProvider,
        mcpServers: mcpServers,
        mcpTools: mcp.tools.count,
        skills: skills.count,
        agents: agents.count,
        judge: runtime.provider.bashJudge,
        sandbox: ArnesRuntime.bannerSandbox(sandbox),
        hooks: runtime.bannerHooks(hooks),
        effort: reasoningEffort?.rawValue,
        environment: runtime.bannerEnvironment,
        addedDirectories: addedDirectories.count,
        mode: mode == .default ? nil : mode.label,
        memory: ArnesRuntime.bannerMemory(memoryStore),
        agent: leadAgent?.name,
        limits: Self.limitsFact(budget: effectiveBudget, maxSteps: effectiveMaxSteps)))
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
    reader.pastes = pastes
    // Slash-command autocomplete: built-ins + skills (`/init` arrives as one) + MCP server
    // prompts, computed once — the reader filters per keystroke.
    let slashItems = SlashCompletion.items(
      skills: skills.map(\.name),
      prompts: mcpPrompts.map(\.slashName))
    reader.completions = { slashItems }
    let renderer = Renderer(screen: screen.isActive ? screen : nil)

    // The line above the input box: usage + subagent activity left, model right.
    let info = StatusInfo(screen: screen)
    if let loaded = requested {
      info.setSessionCost(loaded.costUSD)
    }
    info.setModel(await session.model)
    // The permission mode rides the input box's bottom border from the first prompt on;
    // `refreshEnvironment` keeps it current after /permissions, /plan and a session swap.
    let startupMode = await session.permissionMode
    screen.setMode(
      readOnly ? "read-only" : startupMode.label,
      highlighted: readOnly || startupMode != .default)


    // Subagent progress arrives through the session's own event stream (the task tool
    // emits into the turn), so the renderer sees it in order with everything else. The
    // live-session bindings (inherited model, remaining budget) are re-bound whenever the
    // session changes (/resume swaps it).
    let bindAgents: (Session) -> Void = { bound in
      taskTool?.parentModel = { await bound.model }
      taskTool?.parentSessionId = bound.id
      taskTool?.parentBudgetRemaining = {
        // The live ceiling — `/budget` moves it past what the configuration was built with.
        Self.remainingBudget(ceiling: await bound.currentBudgetUSD, spent: await bound.costUSD)
      }
      // A `fork: true` subagent starts from the live session's conversation.
      taskTool?.parentHistory = { (await bound.history, await bound.compactionSummary) }
      // `/effort` moves the dial after the configuration was sealed: a spawn runs with the live one.
      taskTool?.parentEffort = { await bound.currentReasoningEffort }
      // The permission prompt's Notification hooks report the live session's id.
      notifications.bind(HookEngine.make(
        hooks: hooks.active, promptRunner: runtime.promptHookRunner, cwd: cwd,
        environment: subprocessEnvironment, sessionId: bound.id))
      // A background subagent finishing while the user is at the prompt (joinAtTurnEnd off):
      // say so now — the report itself lands with the next message. During a turn the session
      // delivers it and the renderer prints the ◆ line in sequence, so nothing prints here.
      taskTool?.onBackgroundFinished = { outcome in
        guard !interrupts.isTurnInFlight else { return }
        screen.print(Self.backgroundFinishedLine(outcome))
      }
      // A background shell job exiting on its own: the live session hears of it at its next
      // step boundary (`notify` → one `[arnes]` line), and the user now when nobody is mid-turn
      // (during a turn the `.jobFinished` event prints in sequence, so nothing prints here).
      jobs.setExitHandler { job in
        Task { await bound.notify(job.exitNotice) }
        guard !interrupts.isTurnInFlight else { return }
        screen.print(Self.jobFinishedLine(job))
      }
    }
    bindAgents(session)
    // The checkpoint store follows the live session: its id names the directory under
    // ~/.arnes/checkpoints, and a snapshot is filed under the turn in flight (`turnIndex`
    // already counts it). A fork inherits its parent's checkpoints the first time it is bound.
    let bindCheckpoints: (Session, String?) async -> Void = { bound, forkedFrom in
      await checkpoints?.bind(sessionId: bound.id, inheritingFrom: forkedFrom) {
        max(0, (await bound.turnIndex) - 1)
      }
    }
    await bindCheckpoints(session, requested?.meta.forkedFrom)
    let rewindSupport = RewindSupport(
      checkpoints: checkpoints, cwd: cwd, sandbox: sandbox,
      environment: subprocessEnvironment, pathRules: pathRules)
    // SessionStart: the hooks learn a session began (or was picked up again) and may hand
    // the model standing context for it. Anything they say to the user prints here.
    for notice in await session.start(source: requested != nil ? .resume : .startup) {
      screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
    }

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
    // Ctrl-T shows/hides the streamed reasoning the same two ways (`/thinking` at the prompt).
    let toggleReasoning: @Sendable () -> Void = {
      spinner.stop()
      let notice = ANSI.dim(Self.thinkingNotice(on: renderer.toggleReasoning()))
      if screen.isActive {
        screen.print(notice)
      } else {
        print("\r\u{1B}[K" + notice)
      }
    }
    keys.onCtrlO = toggleVerbosity
    keys.onCtrlT = toggleReasoning
    keys.onInterrupt = { interrupts.interrupt() }
    keys.onTypeahead = { fragment, queued in screen.setTypeahead(fragment, queued: queued) }
    keys.onCursorReport = { row in screen.reportCursorRow(row) }
    reader.onCtrlO = toggleVerbosity
    reader.onCtrlT = toggleReasoning
    reader.onCursorReport = { row in screen.reportCursorRow(row) }

    // The `# Environment` block re-rendered for the live session's model, mode and effort —
    // after /model, /permissions (and the plan-mode cycle's mode switches), /effort, and for a
    // session /resume or /fork swapped in (whose transcript may have been written under another
    // model). Same tree lines as at startup; nothing when the block is off
    // (`policies.environmentContext: false`). Only the environment block is replaced: every
    // other extra section the session carries (a `# Memory` block, an embedder's) stays in place.
    let refreshEnvironment: @Sendable (Session) async -> Void = { bound in
      // The box border's mode tag follows every switch (and /resume, /fork) — set before
      // the environment-block guard, so it updates even with the block switched off.
      let liveMode = await bound.permissionMode
      screen.setMode(
        readOnly ? "read-only" : liveMode.label,
        highlighted: readOnly || liveMode != .default)
      // The `# Memory` section follows the file: re-rendered from the index here too (a session
      // /resume or /fork swapped in carries the startup render), byte-identical while the file
      // is unchanged, so the prefix moves only when a note was actually written.
      if let memoryStore {
        await bound.setExtraSystemSections(
          MemoryStore.replacingSection(in: await bound.currentExtraSystemSections, with: memoryStore.promptSection()))
      }
      guard let environmentSnapshot else { return }
      let block = environmentSnapshot.render(
        model: await bound.model, permissionMode: liveMode,
        readOnly: readOnly, effort: await bound.currentReasoningEffort)
      await bound.setExtraSystemSections(
        EnvironmentContext.replacingBlock(in: await bound.currentExtraSystemSections, with: block))
    }
    // What the dial and introspection commands (/status, /context, /btw, /effort, /thinking,
    // /budget) need from the REPL beyond the session.
    let dials = ReplDials(
      renderer: renderer,
      refreshEnvironment: refreshEnvironment,
      sessionStore: sessionStore,
      provider: runtime.traits.name,
      sandbox: ArnesRuntime.bannerSandbox(sandbox),
      hooks: runtime.bannerHooks(hooks),
      readOnly: readOnly,
      catalog: runtime.catalog,
      agent: leadAgent?.name)

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

    // Plan mode's propose → approve → execute cycle. Every turn runs through here: once one
    // has ended with the session in plan mode, one key decides what happens next. The
    // question is asked only after `runTurn` returned — the key watcher has released stdin
    // by then and the line reader hasn't taken it — and after type-ahead was absorbed, so an
    // approval runs before anything typed during the plan turn. The question restarts the
    // watcher for its one key (see `askPlanReview`), so letters it declined as too close to
    // type-ahead are absorbed again afterwards and land in the input box, not on the floor.
    let planMode = PlanModeController()
    var revisePending = false
    // The index file as it was when the `# Memory` section was last rendered (C3's follow-up: a
    // note the model saves mid-session used to show only in the next session).
    var renderedMemoryStamp = memoryStore?.indexStamp()
    func runReviewedTurn(_ text: String) async {
      // A note saved since the section was rendered reaches this turn: the index's stamp is
      // checked at every turn start — a stat, not a read — and the section re-rendered only when
      // it moved, so the cache prefix holds while the file does. Between turns only, never mid-turn.
      if let memoryStore {
        let stamp = memoryStore.indexStamp()
        if stamp != renderedMemoryStamp {
          renderedMemoryStamp = stamp
          await session.setExtraSystemSections(
            MemoryStore.replacingSection(in: await session.currentExtraSystemSections, with: memoryStore.promptSection()))
        }
      }
      // Placeholders become their pastes only now, at the door to the model — the echo, the
      // transcript line above and the input box all stay compact.
      let end = await runTurn(pastes.expand(text), session: session, renderer: renderer, info: info, interrupts: interrupts, userInput: userInput, spinner: spinner, keys: keys, screen: screen)
      absorbTypeahead()
      // Esc (or Ctrl-C) means stop *everything*: lines queued behind the cancelled turn —
      // typed during it, or a paste's — would each start a new turn the moment the loop
      // resumes, making the interrupt look ignored. Dropped, visibly; the unfinished
      // fragment stays in the box.
      if end.interrupted, !queued.isEmpty {
        screen.print(ANSI.dim("✕ dropped \(queued.count) queued message(s) — the interrupt stops them too"))
        queued.removeAll()
      }
      // Work the turn left running (joinAtTurnEnd off, or a turn that errored out): the user
      // should know before typing the next message, which is when a finished report lands.
      if let taskTool, let note = Self.backgroundPendingNote(taskTool.backgroundSnapshot()) {
        screen.print(ANSI.dim(note))
      }
      guard await session.permissionMode == .plan else { return }
      guard PlanModeController.isReviewable(end.stop) else {
        // Interrupted, errored, or cut off: there is no finished plan to approve, but the
        // session is still read-only and the user should know how to leave.
        screen.print(ANSI.dim("still in plan mode (read-only) — /plan <task> to propose again, /permissions <mode> to leave"))
        return
      }
      let review = await Self.askPlanReview(screen: screen, keys: keys)
      absorbTypeahead()
      switch planMode.resolve(review) {
      case .execute(let mode, let prompt):
        await session.setPermissionMode(mode)
        await refreshEnvironment(session) // the block's mode line must not say read-only while it executes
        screen.print(ANSI.dim("plan approved · permission mode → \(mode.label)"))
        queued.insert(prompt, at: 0) // the next turn, echoed and run by the loop like typed input
      case .revise:
        screen.print(ANSI.dim("revise: describe what to change — the plan stays read-only until approved"))
        screen.setPlaceholder(PlanModeController.revisePlaceholder)
        revisePending = true
      case .cancelled(let mode):
        await session.setPermissionMode(mode)
        await refreshEnvironment(session)
        screen.print(ANSI.dim("plan cancelled · permission mode → \(mode.label)"))
      }
    }

    // `! <command>` — the user's own shell (Claude Code's bang commands). Runs through the
    // bash tool's runner (`UserShell`: login bash, stdin closed, tree-killed on timeout)
    // but outside every tool gate and the OS sandbox: the user is the principal, typing
    // into their own terminal — the provider token is still withheld, since the output
    // reaches the model and the transcript. Esc/Ctrl-C interrupt it like a turn. The
    // output prints here and then a *completed* command sends its own turn at once
    // (`Bang.turnPrompt`: the exchange plus "explain concisely / how to recover — never
    // ask what to do with it"), so the agent's read arrives without another message from
    // the user; an *interrupted* command stays a quiet `Session.notify` notice for the
    // next message instead — the user stopped it, nothing to explain now.
    func runBangCommand(_ command: String) async {
      guard !command.isEmpty else {
        screen.print(ANSI.dim(Bang.usage))
        return
      }
      let expanded = pastes.expand(command) // a pasted path's placeholder becomes its path
      let timeout = runtime.limits.effectiveBashTimeoutSeconds
      let outputChars = runtime.limits.effectiveBashOutputChars
      keys.start() // Esc/Ctrl-C interrupt the command; typing queues like during a turn
      spinner.start("! " + TerminalText.sanitize(String(expanded.prefix(60))))
      // Written inside the task, read after `task.value` (that await is the ordering);
      // a box only because a `Task` body can't assign a captured local.
      final class Box: @unchecked Sendable { var outcome: UserShell.Outcome? }
      let box = Box()
      let environment = subprocessEnvironment
      let task = Task {
        box.outcome = await UserShell.run(
          expanded, cwd: cwd, timeoutSeconds: timeout,
          environment: environment, outputChars: outputChars)
      }
      interrupts.set(task) // SIGINT (and the watcher's Esc/Ctrl-C) cancel → tree kill
      await task.value
      interrupts.set(nil)
      spinner.stop()
      keys.stop()
      absorbTypeahead()
      guard let outcome = box.outcome else { return }
      let shown = Bang.capped(
        outcome.output.trimmingCharacters(in: .whitespacesAndNewlines), maxChars: outputChars)
      if !shown.isEmpty { screen.print(TerminalText.sanitize(shown)) }
      let result = Bang.resultLine(
        exitStatus: outcome.exitStatus, timedOut: outcome.timedOut,
        cancelled: outcome.cancelled, failedToStart: outcome.failedToStart,
        timeoutSeconds: timeout)
      if outcome.cancelled {
        // Esc means stop *everything*, exactly as for an interrupted turn: lines queued
        // behind the cancelled command are dropped, visibly, and no turn runs — the
        // exchange rides the next message as a notice instead.
        if !queued.isEmpty {
          screen.print(ANSI.dim("✕ dropped \(queued.count) queued message(s) — the interrupt stops them too"))
          queued.removeAll()
        }
        screen.print(ANSI.shell("! " + result)
          + ANSI.dim(" — the model sees this with your next message"))
        await session.notify(Bang.notice(
          command: expanded, output: outcome.output, exitStatus: outcome.exitStatus,
          timedOut: outcome.timedOut, cancelled: true,
          failedToStart: outcome.failedToStart, timeoutSeconds: timeout, maxChars: outputChars))
        return
      }
      screen.print(ANSI.shell("! " + result))
      // The exchange is the next turn, sent now: the agent reads the output and answers
      // with a concise explanation (or cause + recovery on a failure) instead of waiting
      // for the user's next message and asking what to do with it.
      await runReviewedTurn(Bang.turnPrompt(
        command: expanded, output: outcome.output, exitStatus: outcome.exitStatus,
        timedOut: outcome.timedOut, failedToStart: outcome.failedToStart,
        timeoutSeconds: timeout, maxChars: outputChars))
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
      await runReviewedTurn(prompt)
    }

    while true {
      // /model, /resume, /verify, /compact all move these between turns.
      info.setModel(await session.model)
      info.setSessionCost(await session.costUSD)
      // The plan segment follows the history: gone after /clear, a rewind or a compaction that
      // summarized it away, back after a /resume whose transcript carries one.
      info.setPlan(await session.lastPlanSteps)
      let text: String
      var echoed = false
      // A bang line echoes in the shell tint — the transcript shows it ran as a command.
      func echoLine(_ text: String) -> String {
        "› " + (Bang.isShellBuffer(text) ? ANSI.shell(text) : text)
      }
      if !queued.isEmpty {
        text = queued.removeFirst()
        screen.print(echoLine(text)) // echo the line typed during the previous turn
        echoed = true
      } else {
        guard let line = reader.readLine(prompt: "› ", initial: prefill) else { break }
        prefill = ""
        text = line.trimmingCharacters(in: .whitespaces)
      }
      if revisePending {
        // The hint asked for a revision; whatever came in answers it (a turn resets the
        // placeholder itself, a slash command wouldn't).
        revisePending = false
        screen.setPlaceholder(Screen.idlePlaceholder)
      }
      if text.isEmpty { continue }
      if screen.isActive, !echoed {
        screen.print(echoLine(text)) // the box cleared on submit; keep the line in the transcript
      }
      // `!command` runs in the user's shell — never a model turn, never a slash command.
      if let command = Bang.parse(text) {
        await runBangCommand(command)
        continue
      }
      if let command = SlashCommand.parse(text) {
        // Background subagents belong to this session's task tool and would deliver into the
        // wrong history after a swap or a clear — the user decides (wait, or Ctrl-C a turn).
        if let taskTool, Self.swapsHistory(command), taskTool.pendingBackgroundCount() > 0 {
          screen.print(ANSI.yellow(
            "\(taskTool.pendingBackgroundCount()) background subagent(s) still pending — "
              + "send a message to collect them first (/tasks lists them)"))
          continue
        }
        // Background shell jobs die with the session being left (`end` → `shutdown`): said
        // here, since a dev server vanishing on /clear should not be a surprise.
        if Self.swapsHistory(command) {
          let running = await jobs.runningCount
          if running > 0 {
            screen.print(ANSI.dim(
              "\(running) background job(s) still running — they die with the session you are leaving"))
          }
        }
        // /resume swaps the live session, so it's handled here where `session` is ours.
        if case .resume(let query) = command {
          if let switched = await resumeSession(
            query, current: session, runtime: runtime, tools: tools,
            permissions: permissions, sessionStore: sessionStore, configuration: configuration, screen: screen)
          {
            session = switched.session
            bindAgents(session)
            await bindCheckpoints(session, switched.loaded.meta.forkedFrom)
            await refreshEnvironment(session) // the block names the resumed model and effort
            planMode.reset() // another session's plan mode has nothing to do with this cycle
          }
          continue
        }
        // /fork branches the live session and continues in the copy — same swap as /resume.
        if case .fork(let name) = command {
          let original = session.id
          if let switched = await forkSession(
            name, from: session, runtime: runtime, tools: tools, permissions: permissions,
            sessionStore: sessionStore, configuration: configuration, screen: screen)
          {
            session = switched
            bindAgents(session)
            await bindCheckpoints(session, original)
            await refreshEnvironment(session)
          }
          continue
        }
        // /plan <task>: propose read-only, then approve · revise · cancel. Runs a turn, so it
        // lives here with the other loop-owned commands rather than in `handle`.
        if case .plan(let task) = command {
          guard let task, !task.isEmpty else {
            screen.print(ANSI.dim(PlanModeController.usage))
            continue
          }
          planMode.enter(from: await session.permissionMode)
          await session.setPermissionMode(.plan)
          await refreshEnvironment(session) // the block tells the model the turn is read-only
          screen.print(ANSI.dim("plan mode (read-only) — the model proposes; you approve, revise or cancel"))
          await runReviewedTurn(task)
          continue
        }
        // /name [args] runs a skill of that name as a turn (built-ins take precedence).
        if case .unknown(let name, let argument) = command,
           let skill = skills.first(where: { $0.name == name })
        {
          // A skill's `model:` frontmatter applies to its turn: the session swaps onto that
          // model for the turn and back after it (both swaps persisted as `model_change`, like
          // /model). A name the manifest can't resolve runs the turn on the current model.
          let previousModel = await switchModel(
            forSkill: skill, session: session, screen: screen, info: info,
            refreshEnvironment: refreshEnvironment)
          await runReviewedTurn(skill.invocationPrompt(arguments: argument))
          if let previousModel {
            await restoreModel(
              previousModel, afterSkill: skill, session: session, screen: screen, info: info,
              refreshEnvironment: refreshEnvironment)
          }
          continue
        }
        // Then an MCP server prompt: /mcp__<server>__<prompt> [args]. The server renders
        // the text; arnes just sends it as the turn.
        if case .unknown(let name, let argument) = command,
           let prompt = mcpPrompts.first(where: { $0.slashName == name })
        {
          do {
            let text = try await prompt.render(arguments: pastes.expand(argument ?? ""))
            guard !text.isEmpty else {
              screen.print(ANSI.yellow("prompt \(name) returned nothing"))
              continue
            }
            await runReviewedTurn(text)
          } catch {
            screen.print(ANSI.red(TerminalText.sanitize("prompt \(name) failed: \(error)")))
          }
          continue
        }
        // A pasted path that arrived without bracketed-paste markers (tmux, some terminals'
        // drag-drop) reads as `/Users/…` — an unknown command that names a real file is a
        // message, not a typo'd command deserving the help panel.
        if case .unknown = command, Self.isPastedPath(text) {
          await runReviewedTurn(text)
          continue
        }
        // `/schema`, `/btw` and `/compact` may carry pasted text: its placeholder becomes the
        // text only here, at the door — the echo and the transcript line above stay compact
        // (`SlashCommand.expandingPastes`; every other command passes through unchanged).
        let expandedCommand = SlashCommand.expandingPastes(command, with: pastes.expand)
        if await handle(
          expandedCommand, session: session, spinner: spinner, screen: screen, skills: skills,
          taskTool: taskTool, planMode: planMode, defaultModel: runtime.traits.defaultModel,
          rewind: rewindSupport,
          memory: memoryStore, jobs: jobs, dials: dials,
          modelAliases: runtime.provider.aliases, mcpPanel: mcpPanel)
        { break }
        continue
      }
      await runReviewedTurn(text)
    }
    // Background subagents don't outlive the REPL: cancelled here so their nested sessions
    // wind down and record `interrupted` instead of dying with the process.
    if let taskTool, taskTool.pendingBackgroundCount() > 0 {
      screen.print(ANSI.dim("cancelling \(taskTool.pendingBackgroundCount()) background subagent(s)"))
      await taskTool.cancelBackground()
    }
    // Background shell jobs die with the session too — `end` shuts them down (process tree and
    // all); said here so a killed dev server isn't a surprise.
    let runningJobs = await jobs.runningCount
    if runningJobs > 0 {
      screen.print(ANSI.dim("killing \(runningJobs) background job(s)"))
    }
    // SessionEnd: advisory, under a short budget — the user is leaving either way.
    for notice in await session.end(reason: .exit) {
      screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
    }
    await mcp.provider.shutdown()
    pastes.cleanup() // stashed drag copies don't outlive the session
    screen.close()
    print(ANSI.dim("session \(session.id.prefix(8))… · total \(Renderer.usd(await session.costUSD))"))
  }

  // MARK: Turns

  /// Runs one turn and returns how it ended — the stop reason of the record the turn
  /// appended, or nil when it threw before reaching its `.turnFinished` (so a stale record
  /// from an earlier turn is never mistaken for this one's) — and whether it was interrupted
  /// (Esc, Ctrl-C, SIGINT), which the caller reads to drop the queued messages behind it.
  private func runTurn(
    _ text: String,
    session: Session,
    renderer: Renderer,
    info: StatusInfo,
    interrupts: InterruptController,
    userInput: TerminalUserInput,
    spinner: Spinner,
    keys: KeyWatcher,
    screen: Screen)
    async -> (stop: StopReason?, interrupted: Bool)
  {
    renderer.beginTurn()
    keys.start()
    interrupts.beginTurn()
    userInput.resetTurn() // the per-turn question cap starts over with the turn
    screen.setPlaceholder(Screen.busyPlaceholder)
    defer {
      interrupts.endTurn()
      keys.stop()
      screen.setPlaceholder(Screen.idlePlaceholder)
    }
    // Whether the stream reached `.turnFinished` rather than throwing first. Written inside
    // the task and read after `task.value` (that await is the ordering); a box only because
    // a `Task` body can't assign a captured local.
    final class Finished: @unchecked Sendable { var value = false }
    let finished = Finished()
    let task = Task {
      spinner.start("waiting for model")
      do {
        for try await event in await session.send(text) {
          spinner.stop()
          renderer.render(event)
          info.observe(event)
          if case .turnFinished = event { finished.value = true }
          if let label = Self.waitLabel(after: event) {
            spinner.start(label)
          }
        }
      } catch {
        spinner.stop()
        screen.print(ANSI.red(TerminalText.sanitize("error: \(error)")))
      }
      spinner.stop()
    }
    interrupts.set(task)
    await task.value
    interrupts.set(nil)
    spinner.stop()
    info.turnEnded()
    // An interrupt cancels the *consuming* task, so the session's own `.interrupted` event
    // never reaches the renderer — without this line, Esc looks like nothing happened.
    let interrupted = task.isCancelled
    if interrupted, !finished.value {
      renderer.showInterrupted()
    }
    return (finished.value ? await session.lastRecord?.stopReason : nil, interrupted)
  }

  /// The plan-mode question, asked once a turn has returned: rides the status line when the
  /// bar is pinned (the way a permission prompt does), prints inline when piped.
  ///
  /// The key is read through the `KeyWatcher`, restarted for just this question, not with a
  /// raw one-byte read. Typing during a turn is how input is queued, and a turn ends at a
  /// moment the user doesn't pick — so the `a` of "add tests too" typed as the plan lands
  /// must not approve it. `readKey(afterQuietFor:)` is the permission prompt's guard: a text
  /// key within `answerQuietInterval` of the last type-ahead goes back to the input box and
  /// the status line says to pause; the watcher's timestamp survives its stop/start, so the
  /// pause is measured from the last thing typed during the turn. On a TTY that also gives
  /// the same Esc/arrow handling the permission prompt has. Off a TTY the watcher is a no-op
  /// and `TerminalInput` reads the first character of the next line, as before. Esc, EOF and
  /// unknown keys cancel.
  private static func askPlanReview(screen: Screen, keys: KeyWatcher) async -> PlanReview {
    let question = PlanModeController.question
    let pinned = screen.isActive
    if pinned {
      screen.setStatus(ANSI.bold(question) + " ")
    } else {
      print(question + ": ", terminator: "")
      fflush(stdout)
    }
    keys.start()
    let key: String?
    if keys.isActive {
      key = await keys.readKey(afterQuietFor: KeyWatcher.answerQuietInterval) {
        if pinned {
          screen.setStatus(ANSI.bold(question) + ANSI.dim(" — pause typing, then answer") + " ")
        }
      }
    } else {
      key = TerminalInput.readKey()
    }
    keys.stop()
    let review = PlanReview.parse(key: key)
    let shown: String
    switch key {
    case "\u{1B}": shown = "esc"
    case .some(let key): shown = key < " " ? "" : key // don't echo raw control bytes
    case nil: shown = ""
    }
    if pinned {
      screen.setStatus(nil)
      screen.print(ANSI.dim("  \(question): ") + shown)
    } else {
      print(shown)
    }
    return review
  }

  /// What to show while waiting for the next event — nil while text is streaming,
  /// since a spinner redraw would clobber the open line.
  private static func waitLabel(after event: AgentEvent) -> String? {
    switch event {
    case .textDelta, .reasoningDelta:
      return nil
    case .toolCall(let name, _):
      return "running \(name)"
    case .planUpdated:
      return "running \(PlanTool.toolName)" // fired mid-call, before its result
    case .toolResult, .toolDenied:
      return "thinking"
    default:
      return "waiting for model"
    }
  }

  // MARK: Slash commands

  /// Parses repeatable `--agent-model <agent>=<model>` pins.
  static func parseAgentModels(_ raw: [String]) throws -> [String: String] {
    var overrides: [String: String] = [:]
    for entry in raw {
      let parts = entry.split(separator: "=", maxSplits: 1).map(String.init)
      guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
        throw ValidationError("--agent-model expects <agent>=<model>, got \"\(entry)\"")
      }
      overrides[parts[0]] = parts[1]
    }
    return overrides
  }

  /// Whether an "unknown command" line is really a pasted file path — `/Users/…/shot.png`
  /// dragged into a terminal that didn't bracket the paste. Judged by the disk: the whole
  /// trimmed line (backslash-escapes undone) or its first token names an existing file, so
  /// `/hepl` still earns the help panel while a real path becomes an ordinary message.
  static func isPastedPath(
    _ text: String,
    exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool
  {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/") else { return false }
    var candidates = [trimmed]
    if let firstToken = trimmed.split(separator: " ").first, firstToken.count != trimmed.count {
      candidates.append(String(firstToken))
    }
    return candidates.contains { exists($0.replacingOccurrences(of: "\\ ", with: " ")) }
  }

  // MARK: Background subagents

  /// The commands that replace or empty the live history — refused while background
  /// subagents are pending, since their reports would land in the wrong conversation.
  /// `/model` is deliberately not here: a background run has its own model, and its report
  /// delivers into the same history whatever the lead switches to.
  static func swapsHistory(_ command: SlashCommand) -> Bool {
    switch command {
    case .resume, .fork, .clear: return true
    default: return false
    }
  }

  /// `/tasks`: one row per background run — name#id, model, elapsed, state.
  static func tasksListing(_ runs: [BackgroundRun], now: Date = Date()) -> String {
    guard !runs.isEmpty else {
      return ANSI.dim(
        "no background subagents — the model starts one with the task tool's background field; "
          + "Ctrl-C during a turn cancels them")
    }
    return runs.map { run in
      let state = run.finished ? "finished — delivered with your next message" : "running"
      let elapsed = Renderer.seconds(max(0, now.timeIntervalSince(run.startedAt)))
      return TerminalText.sanitize(
        "\(ANSI.bold("\(run.agent)#\(run.id)"))  \(ANSI.dim(run.model))  \(ANSI.dim(elapsed))  "
          + (run.finished ? ANSI.secondary(state) : ANSI.dim(state)))
    }.joined(separator: "\n")
  }

  /// `/tasks`, the jobs half: one row per background shell job — `job N`, its state, elapsed,
  /// the command (clipped) — oldest first. Only printed when the session started some.
  static func jobsListing(_ jobs: [JobRegistry.Job], now: Date = Date()) -> String {
    jobs.map { job in
      let until = job.exitedAt ?? now
      let elapsed = Renderer.seconds(max(0, until.timeIntervalSince(job.startedAt)))
      let command = job.command.replacingOccurrences(of: "\n", with: " ")
      let state = job.isRunning ? ANSI.dim(job.stateLabel) : ANSI.secondary(job.stateLabel)
      return TerminalText.sanitize(
        "\(ANSI.bold("job \(job.id)"))  \(state)  \(ANSI.dim(elapsed))  "
          + ANSI.dim("\(String(command.prefix(60)))\(command.count > 60 ? "…" : "")"))
    }.joined(separator: "\n")
  }

  /// The line for a background job that exited while the user was at the prompt: the exit and
  /// where its output is; the model hears of it with the next message.
  static func jobFinishedLine(_ job: JobRegistry.Job) -> String {
    ANSI.dim(TerminalText.sanitize(
      "⧗ job \(job.id) \(job.stateLabel) · \(job.logURL.path) — the model is told with your next message"))
  }

  /// The ◆ line for a background run that finished while the user was at the prompt, plus
  /// where the report went.
  static func backgroundFinishedLine(_ outcome: BackgroundOutcome) -> String {
    ANSI.secondary(TerminalText.sanitize("◆ \(outcome.agent)#\(outcome.id)"))
      + ANSI.dim(" · \(outcome.steps) steps · \(outcome.toolCalls) tools · \(Renderer.usd(outcome.costUSD))")
      + ANSI.dim(" · background result ready — delivered with your next message")
  }

  /// After a turn: what is still out, or nil when nothing is.
  static func backgroundPendingNote(_ runs: [BackgroundRun]) -> String? {
    guard !runs.isEmpty else { return nil }
    let running = runs.filter { !$0.finished }.count
    let ready = runs.count - running
    var parts: [String] = []
    if running > 0 { parts.append("\(running) background subagent\(running == 1 ? "" : "s") still running") }
    if ready > 0 { parts.append("\(ready) background result\(ready == 1 ? "" : "s") ready") }
    return parts.joined(separator: " · ") + " — delivered with your next message (/tasks lists them)"
  }

  /// Returns true when the REPL should exit. `defaultModel` is the provider's default,
  /// used when `/verify` names no model; `planMode` learns of a `/permissions plan` so the
  /// review after the next turn knows which mode to restore; `rewind` is what `/rewind`,
  /// `/undo` and `/diff` work with (the checkpoint store and the run's git/diff context);
  /// `dials` is what the introspection and dial commands need from the REPL.
  private func handle(
    _ command: SlashCommand,
    session: Session,
    spinner: Spinner,
    screen: Screen,
    skills: [Skill],
    taskTool: TaskTool?,
    planMode: PlanModeController,
    defaultModel: String,
    rewind: RewindSupport,
    memory: MemoryStore? = nil,
    jobs: JobRegistry? = nil,
    dials: ReplDials,
    modelAliases: [String: String] = [:],
    mcpPanel: McpPanel.Snapshot? = nil)
    async -> Bool
  {
    switch command {
    case .model(let query):
      await handleModel(query, session: session, spinner: spinner, screen: screen)
      if query != nil { await dials.refreshEnvironment(session) } // the block's model line follows the swap

    case .models(let query):
      await handleModels(
        query, session: session, spinner: spinner, screen: screen,
        catalog: dials.catalog, aliases: modelAliases)

    case .cost:
      var line = "session \(Renderer.usd(await session.costUSD))"
      if let budget = await session.currentBudgetUSD {
        line += ANSI.dim(" · budget \(Renderer.usd(budget))")
      }
      screen.print(line)

    case .context:
      await handleContext(session: session, spinner: spinner, screen: screen)

    case .btw(let question):
      await handleAside(question, session: session, spinner: spinner, screen: screen)

    case .effort(let level):
      await handleEffort(level, session: session, screen: screen, dials: dials)

    case .thinking(let mode):
      let on: Bool
      switch mode?.lowercased() {
      case nil, "": on = dials.renderer.toggleReasoning()
      case "on", "show": on = dials.renderer.setShowReasoning(true)
      case "off", "hide": on = dials.renderer.setShowReasoning(false)
      case .some(let other):
        screen.print(ANSI.dim("unknown /thinking argument '\(TerminalText.sanitize(other))' — use on or off (or nothing to toggle)"))
        return false
      }
      screen.print(ANSI.dim(Self.thinkingNotice(on: on)))

    case .budget(let argument):
      await handleBudget(argument, session: session, screen: screen)

    case .schema(let argument):
      await handleSchema(argument, session: session, screen: screen)

    case .verify(let verifier):
      spinner.start("verifying")
      defer { spinner.stop() }
      do {
        let fallback = defaultModel.isEmpty ? await session.model : defaultModel
        // `/verify haiku`: a configured alias resolves like `/model`'s and `do --verify`'s word.
        let resolved = verifier.map { word in modelAliases.first { $0.key.lowercased() == word.lowercased() }?.value ?? word }
        let (passed, verdict) = try await session.verifyLastTurn(model: resolved ?? fallback)
        spinner.stop()
        screen.print(passed ? ANSI.green("✔ \(verdict)") : ANSI.red("✘ \(verdict)"))
      } catch SessionError.nothingToVerify {
        spinner.stop()
        screen.print(ANSI.dim("nothing to verify yet — send a message first"))
      } catch {
        spinner.stop()
        screen.print(ANSI.red(TerminalText.sanitize("verify failed: \(error)")))
      }

    case .compact(let argument):
      // `/compact [model] [instructions]`: a slug or a configured alias steers the summarizer
      // model, the rest of the line the summary itself (C2).
      let (summarizer, instructions) = SlashCommand.compactArguments(argument, aliases: modelAliases)
      spinner.start("compacting")
      defer { spinner.stop() }
      do {
        let result = try await session.compact(with: summarizer, instructions: instructions)
        spinner.stop()
        for notice in result.hookNotices {
          screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
        }
        if result.summarizedMessages == 0 {
          screen.print(ANSI.dim("nothing to compact yet — only the current turn is in context"))
        } else {
          var line = "◈ compacted \(result.summarizedMessages) messages into a summary · "
            + "\(result.keptMessages) kept · cost \(Renderer.usd(result.costUSD))"
          if result.clearedToolResults > 0 {
            line += " · \(result.clearedToolResults) older tool result\(result.clearedToolResults == 1 ? "" : "s") cleared from requests"
          }
          screen.print(ANSI.dim(line))
        }
      } catch SessionError.compactionCancelled(let reason) {
        spinner.stop()
        screen.print(ANSI.yellow(TerminalText.sanitize("⊘ compaction cancelled by a PreCompact hook: \(reason)")))
      } catch SessionError.backgroundWorkPending(let count) {
        spinner.stop()
        screen.print(ANSI.yellow(
          "\(count) background subagent(s) still pending — send a message to collect them first (/tasks lists them)"))
      } catch {
        spinner.stop()
        screen.print(ANSI.red(TerminalText.sanitize("compact failed: \(error)")))
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

    case .resume, .fork:
      break // handled in the REPL loop, which owns the session binding

    case .plan:
      break // handled in the REPL loop, which owns the turn runner

    case .clear:
      for notice in await session.clearHistory() {
        screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
      }
      screen.print(ANSI.dim("history cleared"))

    case .status:
      screen.print(await Self.statusLines(session: session, dials: dials).joined(separator: "\n"))

    case .permissions(let requested):
      await handlePermissions(requested, session: session, planMode: planMode, screen: screen)
      await dials.refreshEnvironment(session) // the block's mode line follows a switch

    case .skills:
      if skills.isEmpty {
        screen.print(ANSI.dim(
          "no skills loaded — add <name>/SKILL.md under .arnes/skills, .claude/skills, ~/.arnes/skills, or ~/.claude/skills"))
      } else {
        // Frontmatter facts (`allowed-tools`, `model`) are shown as parsed-not-applied, and a
        // malformed value is a warning — the same rule `arnes skills` follows.
        let rows = skills.flatMap { skill in
          [TerminalText.sanitize(
            "\(ANSI.bold(skill.name))  \(ANSI.dim(skill.description.isEmpty ? skill.sourceDescription : skill.description))")]
            + skill.listingFacts.map { ANSI.dim(TerminalText.sanitize("  \($0)")) }
            + skill.warnings.map { ANSI.yellow(TerminalText.sanitize("  ⚠ \($0)")) }
        }
        screen.print(rows.joined(separator: "\n"))
      }

    case .agents(let argument):
      await handleAgents(argument, taskTool: taskTool, session: session, spinner: spinner, screen: screen)

    case .tasks:
      screen.print(Self.tasksListing(taskTool?.backgroundSnapshot() ?? []))
      // Background shell jobs under the subagents: only when there are any (a session that
      // started none keeps the one-line listing it always had).
      if let jobs {
        let started = await jobs.snapshot()
        if !started.isEmpty { screen.print(Self.jobsListing(started)) }
      }

    case .memory:
      // The project's memory as the model sees it: where it lives, how much is loaded, the index.
      screen.print(MemoryFormat.replLines(for: memory, home: NSHomeDirectory()).joined(separator: "\n"))

    case .rewind(let argument):
      await handleRewind(argument, session: session, support: rewind, screen: screen)

    case .undo:
      await handleUndo(session: session, support: rewind, screen: screen)

    case .diff:
      await handleDiff(support: rewind, spinner: spinner, screen: screen)

    case .mcp(let server):
      // Information only: the statuses are the connect's at startup, and the toolset is fixed
      // for the session — the panel says a config change needs a new one.
      screen.print(McpPanel.lines(mcpPanel ?? .empty, server: server).joined(separator: "\n"))

    case .help:
      screen.print(SlashCommand.helpText)

    case .unknown(let name, _):
      screen.print(ANSI.dim("unknown command /\(name)\n") + SlashCommand.helpText)

    case .exit:
      return true
    }
    return false
  }

  /// `/permissions` — the mode, the rules, and this session's standing grants.
  ///
  /// `/permissions <mode>` switches; `/permissions show` prints everything that gates a
  /// call; `/permissions save` promotes the grants earned this session ("always this
  /// session" answers) into `~/.arnes/rules.json` so tomorrow's session starts with them.
  /// Saving is the user's act, never the model's — the rules file is a harness file the
  /// tools themselves are refused.
  ///
  /// `/permissions plan` enters the same propose → approve cycle as `/plan`: the mode it
  /// was switched from is remembered so approving or cancelling the next plan restores it.
  private func handlePermissions(
    _ argument: String?,
    session: Session,
    planMode: PlanModeController,
    screen: Screen)
    async
  {
    let mode = await session.permissionMode
    switch argument?.lowercased() {
    case nil, "":
      screen.print("permission mode: \(ANSI.bold(mode.label))\n"
        + ANSI.dim("switch with /permissions <default|acceptEdits|plan|bypass>"
          + " · /permissions show · /permissions save"))

    case "show":
      let grants = await session.sessionGrants
      let rules = session.configuration.permissionRules
      screen.print("permission mode: \(ANSI.bold(mode.label))")
      if rules.isEmpty {
        screen.print(ANSI.dim("no rules — \(PermissionRules.defaultURL.path) is empty or absent"))
      } else {
        for (label, entries) in [("deny", rules.deny), ("ask", rules.ask), ("allow", rules.allow)]
          where !entries.isEmpty
        {
          screen.print(ANSI.dim("\(label): ") + TerminalText.sanitize(entries.joined(separator: ", ")))
        }
      }
      if grants.isEmpty {
        screen.print(ANSI.dim("no session grants yet — answering [a] at a prompt adds one"))
      } else {
        screen.print("session grants: " + TerminalText.sanitize(grants.joined(separator: ", ")))
        screen.print(ANSI.dim("/permissions save writes them to \(PermissionRules.defaultURL.path)"))
      }

    case "save":
      let grants = await session.sessionGrants
      guard !grants.isEmpty else {
        screen.print(ANSI.dim("nothing to save — no session grants yet"))
        return
      }
      do {
        let added = try PermissionRules.appendAllowRules(grants)
        screen.print(added.isEmpty
          ? ANSI.dim("already saved — every session grant is in the rules file")
          : "saved \(added.count) rule\(added.count == 1 ? "" : "s") to allow: "
            + TerminalText.sanitize(added.joined(separator: ", ")))
      } catch {
        screen.print(ANSI.red(TerminalText.sanitize("save failed: \(error)")))
      }

    case .some:
      // Mode names are case-sensitive raw values (`acceptEdits`), so the original text —
      // not the lowercased switch subject — is what gets parsed.
      let requested = argument ?? ""
      guard let target = PermissionMode(rawValue: requested) else {
        screen.print(ANSI.dim("unknown mode '\(TerminalText.sanitize(requested))'"
          + " — use default, acceptEdits, plan, bypass, show, or save"))
        return
      }
      // Switching by hand to anything else leaves the cycle without a review, so the mode
      // it remembered is forgotten rather than restored into some later, unrelated plan.
      if target == .plan { planMode.enter(from: mode) } else { planMode.reset() }
      await session.setPermissionMode(target)
      screen.print("permission mode → \(ANSI.bold(target.label))"
        + (target == .plan ? ANSI.dim(" (read-only: gated tools are denied; after each turn — approve, revise or cancel)") : "")
        + (target == .bypass ? ANSI.dim(" (ordinary mutations run without asking)") : ""))
    }
  }

  /// `/agents` — list subagents and their models; `/agents <name> <model>` pins one
  /// (fuzzy-resolved, with feedback); `/agents <name> inherit` follows the session
  /// model again. The user controls subagent models — the lead model never does.
  private func handleAgents(
    _ argument: String?,
    taskTool: TaskTool?,
    session: Session,
    spinner: Spinner,
    screen: Screen)
    async
  {
    guard let taskTool else {
      screen.print(ANSI.dim("subagents are disabled — restart without --no-agents"))
      return
    }
    let home = NSHomeDirectory()
    guard let argument, !argument.isEmpty else {
      for agent in taskTool.agents {
        let model = taskTool.configuredModel(for: agent)
        screen.print(TerminalText.sanitize("\(ANSI.bold(agent.name))  \(ANSI.secondary(model))"))
        if !agent.description.isEmpty {
          screen.print(ANSI.dim(TerminalText.sanitize("  \(agent.description)")))
        }
        // What the file narrows, and anything in it that didn't take (`arnes agents` prints
        // the full field set) — a guardrail that was ignored must never look applied.
        var facts: [String] = []
        if agent.permissionMode == .readOnly { facts.append("read-only") }
        if let steps = agent.maxSteps { facts.append("max \(steps) steps") }
        if let budget = agent.budgetUSD { facts.append("budget $\(String(format: "%.2f", budget))") }
        if let effort = agent.effort { facts.append("effort \(effort.rawValue)") }
        if !facts.isEmpty { screen.print(ANSI.dim(TerminalText.sanitize("  \(facts.joined(separator: " · "))"))) }
        for warning in agent.warnings {
          screen.print(ANSI.yellow(TerminalText.sanitize("  ⚠ \(warning)")))
        }
        let origin = agent.source.map {
          $0.path.hasPrefix(home) ? "~" + $0.path.dropFirst(home.count) : $0.path
        } ?? "built-in"
        screen.print(ANSI.dim("  \(origin)"))
      }
      screen.print(ANSI.dim(
        "the model delegates via the task tool · pin a model with /agents <name> <model>"))
      return
    }
    let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
    let name = parts[0]
    guard let agent = taskTool.agents.first(where: { $0.name == name }) else {
      screen.print(ANSI.dim("no agent named '\(name)' — /agents lists them"))
      return
    }
    guard parts.count == 2 else {
      screen.print(TerminalText.sanitize("\(ANSI.bold(agent.name)) runs on \(ANSI.secondary(taskTool.configuredModel(for: agent)))"))
      return
    }
    let query = parts[1]
    if query.lowercased() == "inherit" {
      taskTool.setModelOverride(agent: name, model: "inherit")
      screen.print("\(ANSI.bold(name)) → inherits the session model")
      return
    }
    spinner.start("searching models")
    defer { spinner.stop() }
    do {
      let results = try await session.searchModels(query, limit: 1)
      spinner.stop()
      guard let best = results.first else {
        screen.print(ANSI.dim("no models match \"\(query)\" — try `arnes models \(query)`"))
        return
      }
      taskTool.setModelOverride(agent: name, model: best.id)
      screen.print(TerminalText.sanitize("\(ANSI.bold(name)) → \(ANSI.secondary(best.id))\(best.id == query ? "" : ANSI.dim(" (matched \"\(query)\")"))"))
    } catch {
      spinner.stop()
      screen.print(ANSI.red(TerminalText.sanitize("model search failed: \(error)")))
    }
  }

  /// Swaps the session onto a skill's `model:` for its `/name` turn. Returns the model to
  /// restore afterwards, nil when nothing was swapped: no `model:`, the same model already, a
  /// name the manifest can't resolve (said in yellow; the turn runs on the current model), or a
  /// swap that failed (said in red).
  private func switchModel(
    forSkill skill: Skill, session: Session, screen: Screen, info: StatusInfo,
    refreshEnvironment: @Sendable (Session) async -> Void) async -> String?
  {
    guard let wanted = skill.model else { return nil }
    let current = await session.model
    let resolved = (try? await session.searchModels(wanted, limit: 1))?.first?.id
    guard let target = Self.skillModelSwitch(resolved: resolved, current: current) else {
      if resolved == nil {
        screen.print(ANSI.yellow(TerminalText.sanitize(
          "⚠ skill \(skill.name): model '\(wanted)' is not in the manifest — running on \(current)")))
      }
      return nil
    }
    do {
      _ = try await session.setModel(target)
    } catch {
      screen.print(ANSI.red(TerminalText.sanitize(
        "skill \(skill.name): could not switch to \(target): \(error) — running on \(current)")))
      return nil
    }
    info.setModel(target)
    await refreshEnvironment(session)
    screen.print(ANSI.dim(TerminalText.sanitize(Self.skillModelLine(skill: skill.name, model: target, previous: current))))
    return current
  }

  /// The way back after a skill turn ran on its own model.
  private func restoreModel(
    _ previous: String, afterSkill skill: Skill, session: Session, screen: Screen, info: StatusInfo,
    refreshEnvironment: @Sendable (Session) async -> Void) async
  {
    do {
      _ = try await session.setModel(previous)
    } catch {
      screen.print(ANSI.red(TerminalText.sanitize(
        "skill \(skill.name): could not switch back to \(previous): \(error) — the session stays on \(await session.model)")))
      return
    }
    info.setModel(previous)
    await refreshEnvironment(session)
  }

  /// The model a skill turn switches to: the manifest's answer for the frontmatter name when it
  /// differs from the current model; nil when there is nothing to switch to (no match, or the
  /// session is on that model already).
  static func skillModelSwitch(resolved: String?, current: String) -> String? {
    guard let resolved, resolved != current else { return nil }
    return resolved
  }

  /// The dim line printed before a skill turn that runs on its own model.
  static func skillModelLine(skill: String, model: String, previous: String) -> String {
    "↳ /\(skill) runs on \(model) (skill frontmatter) — back to \(previous) after this turn"
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
          screen.print(TerminalText.sanitize("  \(profile.id)  \(ANSI.dim("ctx \(context)"))"))
        }
        screen.print(ANSI.dim("narrow the query or use the full slug"))
      }
    } catch {
      spinner.stop()
      screen.print(ANSI.red(TerminalText.sanitize("model search failed: \(error)")))
    }
  }

  /// `/models [query]`: the provider's manifest as a list — every model when the query is
  /// empty, `/model`'s fuzzy ranking otherwise; the session's current model is marked and
  /// configured aliases are shown so `/model haiku` is discoverable.
  private func handleModels(
    _ query: String?, session: Session, spinner: Spinner, screen: Screen,
    catalog: ModelCatalog, aliases: [String: String]) async
  {
    spinner.start("loading models")
    defer { spinner.stop() }
    do {
      let profiles: [ModelProfile]
      if let query, !query.isEmpty {
        profiles = try await catalog.search(query, limit: Self.modelsListCap)
      } else {
        profiles = try await catalog.all()
      }
      spinner.stop()
      let aliasLine = aliases.isEmpty
        ? nil
        : ANSI.dim(TerminalText.sanitize("aliases: " + aliases.sorted { $0.key < $1.key }
            .map { "\($0.key) → \($0.value)" }.joined(separator: " · ")))
      if profiles.isEmpty {
        if let failure = await catalog.manifestFailure {
          screen.print(ANSI.yellow(TerminalText.sanitize(
            "no model manifest on this provider (\(failure)) — runs still work with /model <id or alias>")))
        } else if let query, !query.isEmpty {
          screen.print(ANSI.dim("no models match \"\(TerminalText.sanitize(query))\" — try a shorter query"))
        } else {
          screen.print(ANSI.dim("the manifest lists no models"))
        }
        if let aliasLine { screen.print(aliasLine) }
        return
      }
      let current = await session.model
      if query == nil || query?.isEmpty == true, let aliasLine {
        screen.print(aliasLine)
      }
      for profile in profiles.prefix(Self.modelsListCap) {
        screen.print(Self.modelsLine(profile, current: current))
      }
      if profiles.count > Self.modelsListCap {
        screen.print(ANSI.dim("(\(profiles.count - Self.modelsListCap) more — narrow with /models <query>, or arnes models)"))
      }
      screen.print(ANSI.dim("switch with /model <query>"))
    } catch {
      spinner.stop()
      screen.print(ANSI.red(TerminalText.sanitize("models failed: \(error)")))
    }
  }

  /// Rows shown before `/models` points at narrowing.
  static let modelsListCap = 30

  /// One `/models` row — id, context window, prompt price — the session's current model
  /// marked. Pure for tests.
  static func modelsLine(_ profile: ModelProfile, current: String) -> String {
    var facts: [String] = []
    if let context = profile.contextLength { facts.append("ctx \(context / 1000)k") }
    if let price = profile.promptPricePerToken {
      facts.append(String(format: "in $%.2f/Mtok", price * 1_000_000))
    }
    if !profile.supportsTools { facts.append("no tools") }
    let name = TerminalText.sanitize(profile.id)
    let tail = facts.isEmpty ? "" : "  " + ANSI.dim(facts.joined(separator: " · "))
    return profile.id == current
      ? ANSI.accent("● ") + ANSI.bold(name) + tail + ANSI.dim("  (current)")
      : "  " + name + tail
  }

  // MARK: Dials and introspection

  /// `/status`: the session and the dials as they stand — id, name, fork parent, model, the
  /// dialect the last turn actually executed, effort, provider, mode, sandbox, hooks, messages,
  /// cost against the budget, the measured context, taint, and the model's latest plan.
  static func statusLines(session: Session, dials: ReplDials) async -> [String] {
    let meta = (try? dials.sessionStore.list())?.first { $0.id == session.id }
    let contextLength = (try? await session.contextReport())?.contextLength
    let facts = StatusFormat.Facts(
      sessionId: session.id,
      name: meta?.name,
      forkedFrom: meta?.forkedFrom,
      model: await session.model,
      agent: dials.agent,
      dialectFlag: session.configuration.dialect.rawValue,
      lastDialect: await session.lastDialectUsed,
      effort: await session.currentReasoningEffort,
      provider: dials.provider,
      mode: await session.permissionMode,
      readOnly: dials.readOnly,
      sandbox: dials.sandbox,
      hooks: dials.hooks,
      messages: await session.messageCount,
      turns: await session.turnIndex,
      costUSD: await session.costUSD,
      budgetUSD: await session.currentBudgetUSD,
      lastPromptTokens: await session.lastPromptTokens,
      contextLength: contextLength,
      tainted: await session.isTainted,
      plan: await session.lastPlanSteps,
      cachedTokens: await session.lastRecord?.cachedTokens,
      cachePromptTokens: await session.lastRecord?.promptTokens,
      cacheControlRefused: await session.cacheControlRefused)
    return StatusFormat.lines(facts).map { TerminalText.sanitize($0) }
  }

  /// `/context`: what the next request spends the window on, by contributor.
  private func handleContext(session: Session, spinner: Spinner, screen: Screen) async {
    spinner.start("sizing context")
    defer { spinner.stop() }
    do {
      let report = try await session.contextReport()
      spinner.stop()
      let lines = ContextFormat.lines(report, model: await session.model)
      screen.print(lines.map { TerminalText.sanitize($0) }.joined(separator: "\n"))
    } catch {
      spinner.stop()
      screen.print(ANSI.red(TerminalText.sanitize("context report failed: \(error)")))
    }
  }

  /// `/btw <question>`: a side question over the conversation, answered inline with a `(btw)`
  /// prefix and never appended to history — the model's next turn won't know it was asked.
  private func handleAside(_ question: String?, session: Session, spinner: Spinner, screen: Screen) async {
    guard let question, !question.isEmpty else {
      screen.print(ANSI.dim("usage: /btw <question> — asked over the conversation so far, answered here, never remembered by the model"))
      return
    }
    spinner.start("asking on the side")
    defer { spinner.stop() }
    do {
      let (reply, cost) = try await session.aside(question)
      spinner.stop()
      let text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
      screen.print(ANSI.secondary("(btw) ") + TerminalText.sanitize(text.isEmpty ? "(no reply)" : text))
      screen.print(ANSI.dim("(btw) \(Renderer.usd(cost)) · not added to the conversation"))
    } catch SessionError.turnInFlight {
      spinner.stop()
      screen.print(ANSI.dim("a turn is running — ask again when it finishes"))
    } catch {
      spinner.stop()
      screen.print(ANSI.red(TerminalText.sanitize("btw failed: \(error)")))
    }
  }

  /// `/effort [level|off]`: show or move the reasoning-effort dial. A change is persisted with
  /// the session and re-renders the `# Environment` block's effort line.
  private func handleEffort(_ argument: String?, session: Session, screen: Screen, dials: ReplDials) async {
    guard let parsed = EffortArgument.parse(argument) else {
      screen.print(ANSI.dim(EffortArgument.usage))
      return
    }
    switch parsed {
    case .show:
      let current = await session.currentReasoningEffort
      screen.print("effort \(ANSI.bold(current?.rawValue ?? "off"))\n"
        + ANSI.dim("set with /effort <minimal|low|medium|high|xhigh|max|none>, remove with /effort off — applied only to models whose manifest supports reasoning"))
    case .off:
      await session.setReasoningEffort(nil)
      await dials.refreshEnvironment(session)
      screen.print("effort → \(ANSI.bold("off"))" + ANSI.dim(" (requests carry no reasoning field)"))
    case .level(let level):
      await session.setReasoningEffort(level)
      await dials.refreshEnvironment(session)
      screen.print("effort → \(ANSI.bold(level.rawValue))" + ANSI.dim(" · from the next request; persists with the session; subagents spawned from now on run with it"))
    }
  }

  /// `/budget [usd|off]`: show or move this session's cost ceiling. The amount is what the
  /// session may *still* spend — added to what it already spent, since the ceiling the loop
  /// checks is session-cumulative — so `/budget 0.50` never stops the next turn on its first step.
  private func handleBudget(_ argument: String?, session: Session, screen: Screen) async {
    guard let parsed = BudgetArgument.parse(argument) else {
      screen.print(ANSI.dim(BudgetArgument.usage))
      return
    }
    let spent = await session.costUSD
    switch parsed {
    case .show:
      if let ceiling = await session.currentBudgetUSD {
        screen.print("budget \(ANSI.bold(Renderer.usd(ceiling)))"
          + ANSI.dim(" · spent \(Renderer.usd(spent)) · \(Renderer.usd(max(0, ceiling - spent))) left — /budget <usd> to allow more, /budget off to lift it"))
      } else {
        screen.print("budget \(ANSI.bold("off"))" + ANSI.dim(" · spent \(Renderer.usd(spent)) — /budget <usd> caps what this session may still spend"))
      }
    case .off:
      await session.setBudget(nil)
      screen.print("budget → \(ANSI.bold("off"))")
    case .usd(let allowance):
      let ceiling = spent + allowance
      await session.setBudget(ceiling)
      screen.print("budget → \(ANSI.bold(Renderer.usd(ceiling)))"
        + ANSI.dim(" (\(Renderer.usd(allowance)) more on top of the \(Renderer.usd(spent)) spent; a turn stops at the step that crosses it)"))
    }
  }

  /// `/schema`: show the structured-output schema in force, set one (`Do.loadOutputSchema`'s
  /// rule — a path, `~` and cwd-relative, or an inline object; a bad one is said in yellow and
  /// changes nothing), or clear it. The dial is the session's (`Session.setOutputSchema`) and
  /// not persisted, like the budget: a resumed session passes its own `--output-schema`.
  private func handleSchema(_ argument: String?, session: Session, screen: Screen) async {
    guard let parsed = SchemaArgument.parse(argument) else {
      screen.print(ANSI.dim(SchemaArgument.usage))
      return
    }
    switch parsed {
    case .show:
      if let schema = await session.currentOutputSchema {
        screen.print("schema \(ANSI.bold(TerminalText.sanitize(SchemaFormat.describe(schema))))"
          + ANSI.dim(" — each finished turn answers as one JSON object; /schema off stops asking"))
      } else {
        screen.print("schema \(ANSI.bold("none"))"
          + ANSI.dim(" — /schema <file|json> asks each finished turn for its answer as one JSON object"))
      }
    case .off:
      await session.setOutputSchema(nil)
      screen.print("schema → \(ANSI.bold("off"))")
    case .value(let raw):
      do {
        let schema = try OutputSchema.load(raw, relativeTo: nil)
        await session.setOutputSchema(schema)
        screen.print("schema → \(ANSI.bold(TerminalText.sanitize(SchemaFormat.describe(schema))))"
          + ANSI.dim(" (from the next turn on, the reply is followed by one validated JSON object)"))
      } catch let error as StructuredOutputError {
        screen.print(ANSI.yellow(TerminalText.sanitize("/schema: \(error.description)")))
      } catch {
        screen.print(ANSI.yellow(TerminalText.sanitize("/schema: \(error)")))
      }
    }
  }

  // MARK: Rewind

  /// `/rewind` alone lists the turns; `/rewind <n> [code|conversation|both]` asks y/N, then
  /// restores. The turn is checked before the question so a typo is answered with the reason,
  /// not with a prompt.
  private func handleRewind(
    _ argument: String?, session: Session, support: RewindSupport, screen: Screen) async
  {
    guard let argument, !argument.isEmpty else {
      screen.print(await Self.rewindListing(session: session, support: support))
      return
    }
    guard let request = RewindRequest.parse(argument) else {
      screen.print(ANSI.dim(RewindRequest.usage))
      return
    }
    if let refusal = await Self.rewindRefusal(
      turn: request.turn, conversation: request.scope.restoresConversation, session: session)
    {
      screen.print(ANSI.yellow(TerminalText.sanitize(refusal)))
      return
    }
    guard Self.confirm(
      "rewind \(request.scope.described) to the start of turn \(request.turn)? [y/N]", screen: screen)
    else {
      screen.print(ANSI.dim("rewind cancelled"))
      return
    }
    await performRewind(
      session: session, turn: request.turn,
      code: request.scope.restoresCode, conversation: request.scope.restoresConversation, screen: screen)
  }

  /// `/undo`: the files the last turn changed go back to how they were before it; the
  /// conversation is left alone (the model is told nothing — re-read before editing is its rule).
  private func handleUndo(session: Session, support: RewindSupport, screen: Screen) async {
    let turnIndex = await session.turnIndex
    guard turnIndex > 0 else {
      screen.print(ANSI.dim("nothing to undo — no turn has run yet"))
      return
    }
    let last = turnIndex - 1
    if let refusal = await Self.rewindRefusal(turn: last, conversation: false, session: session) {
      screen.print(ANSI.yellow(TerminalText.sanitize(refusal)))
      return
    }
    let changed = await support.checkpoints?.checkpoints(forTurn: last) ?? []
    guard !changed.isEmpty else {
      screen.print(ANSI.dim(support.checkpoints == nil
        ? "checkpoints are off (`checkpoints.enabled: false` in ~/.arnes/config.json) — nothing to undo"
        : "the last turn (#\(last)) changed no files through write_file/edit_file — nothing to undo"))
      return
    }
    let names = changed.map { RewindListing.relativePath($0.path, to: support.cwd) }.joined(separator: ", ")
    guard Self.confirm(
      TerminalText.sanitize("put back \(names) as before turn \(last)? (the conversation stays) [y/N]"),
      screen: screen)
    else {
      screen.print(ANSI.dim("undo cancelled"))
      return
    }
    await performRewind(session: session, turn: last, code: true, conversation: false, screen: screen)
  }

  private func performRewind(
    session: Session, turn: Int, code: Bool, conversation: Bool, screen: Screen) async
  {
    do {
      let result = try await session.rewind(toTurn: turn, code: code, conversation: conversation)
      screen.print(ANSI.secondary(RewindListing.summary(result)))
      for skipped in result.skipped {
        screen.print(ANSI.yellow(TerminalText.sanitize("  ⚠ skipped: \(skipped)")))
      }
      if conversation {
        screen.print(ANSI.dim("the model will continue from the start of turn \(turn); files changed by bash or committed are untouched"))
      }
    } catch let error as RewindError {
      screen.print(ANSI.yellow(TerminalText.sanitize("⊘ \(error.description)")))
    } catch {
      screen.print(ANSI.red(TerminalText.sanitize("rewind failed: \(error)")))
    }
  }

  /// Why `session.rewind(toTurn:)` would refuse `turn`, worded for the user — or nil. Asked
  /// before the y/N, so nobody confirms a rewind that is then refused.
  static func rewindRefusal(turn: Int, conversation: Bool, session: Session) async -> String? {
    let pending = await session.backgroundWorkPending
    if pending > 0 {
      return RewindError.backgroundWorkPending(count: pending).description
        + " — send a message to collect them (/tasks lists them)"
    }
    let turnIndex = await session.turnIndex
    guard turn < turnIndex else {
      return turnIndex == 0
        ? RewindError.noSuchTurn(turn).description + " — no turn has run yet"
        : RewindError.noSuchTurn(turn).description + " (turns so far: 0…\(turnIndex - 1))"
    }
    if conversation, await !session.turnStarts.contains(where: { $0.turn == turn }) {
      return RewindError.acrossCompaction(turn).description
    }
    return nil
  }

  /// The `/rewind` listing over the live session and its checkpoint store.
  static func rewindListing(session: Session, support: RewindSupport) async -> String {
    let starts = await session.turnStarts
    let history = await session.history
    let checkpoints = await support.checkpoints?.checkpoints ?? []
    var filesByTurn: [Int: [String]] = [:]
    for checkpoint in checkpoints {
      filesByTurn[checkpoint.turn, default: []].append(RewindListing.relativePath(checkpoint.path, to: support.cwd))
    }
    let turns = starts.map { start in
      RewindListing.Turn(
        turn: start.turn,
        prompt: start.index < history.count ? RewindListing.text(of: history[start.index]) : "",
        files: filesByTurn[start.turn] ?? [])
    }
    let listed = Set(starts.map(\.turn))
    let checkpointOnly = filesByTurn.keys.filter { !listed.contains($0) }.sorted()
    return RewindListing.lines(turns, checkpointOnlyTurns: checkpointOnly).joined(separator: "\n")
  }

  /// `/diff`: the repository's uncommitted changes when the working directory is in one (the
  /// same `git diff` `arnes review` builds — pinned config, no external diff, untracked files
  /// pasted only where `read_file` could read them), else what changed since the session began,
  /// each checkpointed file's earliest pre-image against the working file.
  private func handleDiff(support: RewindSupport, spinner: Spinner, screen: Screen) async {
    spinner.start("diffing")
    defer { spinner.stop() }
    do {
      let built = try await ReviewDiff.build(
        target: .uncommitted, cwd: support.cwd, sandbox: support.sandbox,
        environment: ReviewDiff.pinningGit(support.environment), rules: support.pathRules)
      spinner.stop()
      screen.print(ANSI.dim("uncommitted changes in \(built.root) (\(built.files.count) file\(built.files.count == 1 ? "" : "s"))"))
      screen.print(DiffColoring.colored(built.diff))
      if built.truncated {
        screen.print(ANSI.dim("… diff truncated (\(built.omittedChars) more chars)"))
      }
      for skipped in built.skipped {
        screen.print(ANSI.dim(TerminalText.sanitize("  skipped: \(skipped)")))
      }
    } catch ReviewError.nothingToReview {
      spinner.stop()
      screen.print(ANSI.dim("no uncommitted changes in the repository"))
    } catch ReviewError.notAGitRepo {
      spinner.stop()
      screen.print(await Self.checkpointDiff(support: support))
    } catch {
      spinner.stop()
      screen.print(ANSI.red(TerminalText.sanitize("diff failed: \(error)")))
    }
  }

  /// Outside a repository: every checkpointed path's earliest pre-image this session against the
  /// file as it is now.
  static func checkpointDiff(support: RewindSupport) async -> String {
    guard let store = support.checkpoints else {
      return ANSI.dim("not a git repository, and checkpoints are off — nothing to diff")
    }
    let earliest = await store.earliestPerPath()
    guard !earliest.isEmpty else {
      return ANSI.dim("not a git repository, and no file was changed through write_file/edit_file this session")
    }
    var out = [ANSI.dim("not a git repository — changes since the session began (from checkpoints):")]
    for checkpoint in earliest {
      let shown = RewindListing.relativePath(checkpoint.path, to: support.cwd)
      guard checkpoint.restorable else {
        out.append(ANSI.dim(TerminalText.sanitize("\(shown): pre-image not saved (over the checkpoint size cap)")))
        continue
      }
      let old: String? = checkpoint.existed
        ? (await store.blobData(checkpoint.blob ?? "")).map { String(decoding: $0, as: UTF8.self) }
        : nil
      let new = (try? Data(contentsOf: URL(fileURLWithPath: checkpoint.path))).map { String(decoding: $0, as: UTF8.self) }
      let diff = UnifiedDiff.diff(old: old, new: new, path: shown)
      if diff.isEmpty {
        out.append(ANSI.dim(TerminalText.sanitize("\(shown): unchanged since the session began")))
      } else {
        out.append(DiffColoring.colored(diff))
      }
    }
    return out.joined(separator: "\n")
  }

  /// A y/N question outside a turn: on the status line when the bar is pinned (the permission
  /// prompt's place), inline when piped — where the first character of the next line answers,
  /// as `TerminalInput.confirm` reads it. Only `y`/`Y` is a yes.
  static func confirm(_ question: String, screen: Screen) -> Bool {
    guard screen.isActive else { return TerminalInput.confirm(question) }
    screen.setStatus(ANSI.bold(question) + " ")
    let key = TerminalInput.readKey()
    screen.setStatus(nil)
    let shown = key.map { $0 < " " ? "" : $0 } ?? ""
    screen.print(ANSI.dim("  \(question) ") + shown)
    return key?.lowercased() == "y"
  }

  /// `/resume [id|name]`: loads another saved session and returns it (with the transcript it
  /// was built from, whose meta names a fork's parent) to swap into the REPL; prints why and
  /// returns nil when nothing (unambiguous) matches. Resolution
  /// mirrors `arnes resume`: exact id, unique id prefix, or saved name — most recent
  /// *other* session when the query is omitted (the current one is always excluded;
  /// it's already live and continuously persisted). The resumed session keeps this
  /// REPL's configuration (instructions, hooks, mode, rules) — the model comes from the
  /// transcript, and so does the effort dial unless `--effort` named one
  /// (`resumedConfiguration`). The session being left gets its `SessionEnd` (`other`) once
  /// the target is known to load, before the new one's `SessionStart` (`resume`).
  private func resumeSession(
    _ query: String?,
    current: Session,
    runtime: ArnesRuntime,
    tools: [any AgentTool],
    permissions: any PermissionDelegate,
    sessionStore: SessionStore,
    configuration: Session.Configuration,
    screen: Screen)
    async -> (session: Session, loaded: LoadedSession)?
  {
    do {
      let others = try sessionStore.list().filter { $0.id != current.id }
      guard !others.isEmpty else {
        screen.print(ANSI.dim("no other sessions to resume — /save names this one for later"))
        return nil
      }
      let meta = try Resume.resolve(query, in: others, refusingSubagentsOf: sessionStore)
      let loaded = try sessionStore.load(id: meta.id)
      // This run's allowance travels with the user: what the live session may still spend
      // (the flag less its spend, or the last `/budget`) becomes the swapped-in session's on top
      // of what that transcript already cost (`resumedConfiguration`).
      let remaining = Self.remainingBudget(
        ceiling: await current.currentBudgetUSD, spent: await current.costUSD)
      // Nothing below can fail, so the old session is ended only when the swap is certain —
      // a session that stays live must not have seen its end.
      for notice in await current.end(reason: .other) {
        screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
      }
      let session = Session(
        resuming: loaded,
        service: runtime.service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        catalog: runtime.catalog,
        configuration: Self.resumedConfiguration(
          base: configuration, loaded: loaded, explicitEffort: try? parseEffort(effort),
          remainingBudgetUSD: remaining))
      let label = loaded.meta.name ?? String(loaded.meta.id.prefix(8))
      screen.print(ANSI.dim(
        "↩ resumed \(label) · \(loaded.messages.count) messages · "
          + "\(Renderer.usd(loaded.costUSD)) · model \(loaded.model)"))
      for notice in await session.start(source: .resume) {
        screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
      }
      return (session, loaded)
    } catch let error as ValidationError {
      screen.print(ANSI.dim(error.message))
      return nil
    } catch {
      screen.print(ANSI.red("resume failed: \(error)"))
      return nil
    }
  }

  /// The configuration a resumed (or forked) session runs with: this REPL's live one —
  /// instructions, hooks, permission mode, rules, provider, working directory — with only
  /// the transcript's own state layered on. The model always comes from the transcript;
  /// the effort dial does too, unless the user named one with `--effort`.
  ///
  /// The budget is **this run's allowance carried over**, never the startup ceiling as-is:
  /// `Session(resuming:)` seeds `costUSD` with the transcript's cumulative spend and the loop
  /// compares the ceiling against it, so the ceiling the startup built (`--budget` + the
  /// *startup* transcript's spend, or the bare flag) would stop every turn of a `/resume`d
  /// session that had already spent more at its first step. `remainingBudgetUSD` is what the
  /// live session may still spend (`remainingBudget(ceiling:spent:)` — the flag less this run's
  /// spend, or whatever `/budget` last allowed; nil = no ceiling) and `Do.budgetCeiling` lifts
  /// it by the swapped-in transcript's spend, the rule a startup `--continue --budget` follows.
  /// A `/fork` carries the same figure and lands on the ceiling the live session had.
  static func resumedConfiguration(
    base: Session.Configuration,
    loaded: LoadedSession,
    explicitEffort: Reasoning.Effort?,
    remainingBudgetUSD: Double?)
    -> Session.Configuration
  {
    var resumed = base
    resumed.model = loaded.model
    if explicitEffort == nil, let replayed = loaded.reasoningEffort {
      resumed.reasoningEffort = replayed
    }
    resumed.maxCostUSD = Do.budgetCeiling(remainingBudgetUSD, resumedCostUSD: loaded.costUSD)
    return resumed
  }

  /// What a session may still spend under its ceiling: `ceiling − spent`, floored at zero
  /// (a turn stops at the step that *crosses* the ceiling, so `spent` may exceed it); nil when
  /// there is no ceiling. The one rule behind the task tool's `parentBudgetRemaining` and the
  /// allowance a `/resume` or `/fork` carries over.
  static func remainingBudget(ceiling: Double?, spent: Double) -> Double? {
    guard let ceiling else { return nil }
    return max(0, ceiling - spent)
  }

  /// `/fork [name]`: copies the live session's transcript into a new one and returns it to
  /// swap into the REPL. The original is left exactly as it was — a branch point to come
  /// back to with `/resume`, not a rewind.
  private func forkSession(
    _ name: String?,
    from session: Session,
    runtime: ArnesRuntime,
    tools: [any AgentTool],
    permissions: any PermissionDelegate,
    sessionStore: SessionStore,
    configuration: Session.Configuration,
    screen: Screen)
    async -> Session?
  {
    // Nothing is persisted until the first turn, so there is no file to copy yet.
    guard await session.messageCount > 0 else {
      screen.print(ANSI.dim("nothing to fork yet — send a message first"))
      return nil
    }
    do {
      let newId = try sessionStore.fork(id: session.id, name: name)
      let loaded = try sessionStore.load(id: newId)
      // The fork has spent exactly what the original has, so carrying the remaining allowance
      // lands it on the ceiling the live session had — a `/budget` set before the fork included.
      let remaining = Self.remainingBudget(
        ceiling: await session.currentBudgetUSD, spent: await session.costUSD)
      // The copy is on disk and loads; the REPL is leaving the original, so it gets its
      // `SessionEnd` (`other`) before the fork's `SessionStart` (`resume`).
      for notice in await session.end(reason: .other) {
        screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
      }
      let forked = Session(
        resuming: loaded,
        service: runtime.service,
        tools: tools,
        permissions: permissions,
        sessionStore: sessionStore,
        catalog: runtime.catalog,
        configuration: Self.resumedConfiguration(
          base: configuration, loaded: loaded, explicitEffort: try? parseEffort(effort),
          remainingBudgetUSD: remaining))
      screen.print(ANSI.dim(
        "⑂ forked to \(newId)\(name.map { " (\(TerminalText.sanitize($0)))" } ?? "") · "
          + "\(loaded.messages.count) messages · the original is untouched"))
      for notice in await forked.start(source: .resume) {
        screen.print(ANSI.dim(TerminalText.sanitize("⎔ \(notice.event) hook: \(notice.output)")))
      }
      return forked
    } catch {
      screen.print(ANSI.red(TerminalText.sanitize("fork failed: \(error)")))
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
