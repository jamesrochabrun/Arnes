import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - ReplDials

/// What the REPL's introspection and dial commands (`/status`, `/context`, `/btw`, `/effort`,
/// `/thinking`, `/budget`) need beyond the live session: the renderer (the reasoning display
/// toggle), the environment-block re-render, the store (a session's name and fork parent for
/// `/status`), and the start-up facts the banner showed.
struct ReplDials {
  let renderer: Renderer
  let refreshEnvironment: @Sendable (Session) async -> Void
  let sessionStore: SessionStore
  /// The provider's name (`openrouter`, a configured gateway's).
  let provider: String
  /// The banner's sandbox fact (`sandbox` / `sandbox no-net`), nil when unconfined.
  let sandbox: String?
  /// The banner's hooks fact (`hooks: 3 (+1 prompt)`), nil when none are loaded.
  let hooks: String?
  /// `--safe` or a read-only `--agent`: the delegate refuses every mutation whatever the mode says.
  let readOnly: Bool
  /// The provider's model manifest — what `/models` lists.
  let catalog: ModelCatalog
  /// The `--agent` the session runs as, for `/status`; nil for a plain session.
  let agent: String?
}

// MARK: - Dial arguments

/// The `/effort` argument: a level, `off` (no dial), or nil to show the current one.
enum EffortArgument: Equatable {
  case show
  case off
  case level(Reasoning.Effort)

  static let usage = "usage: /effort <minimal|low|medium|high|xhigh|max|none|off> — off removes the dial (requests unchanged); none asks the model for no reasoning"

  /// nil when the argument is not a level: the caller prints `usage`.
  static func parse(_ argument: String?) -> EffortArgument? {
    guard let raw = argument?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
      return .show
    }
    if raw == "off" || raw == "unset" { return .off }
    return Reasoning.Effort(rawValue: raw).map { .level($0) }
  }
}

/// The `/budget` argument: an amount in USD (a leading `$` tolerated), `off` (no ceiling), or
/// nil to show the current one.
enum BudgetArgument: Equatable {
  case show
  case off
  case usd(Double)

  static let usage = "usage: /budget <usd> — a positive amount this session may still spend (e.g. /budget 0.50); /budget off lifts the ceiling"

  /// nil when the argument is neither an amount nor `off`: the caller prints `usage`.
  static func parse(_ argument: String?) -> BudgetArgument? {
    guard var raw = argument?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
      return .show
    }
    if raw == "off" || raw == "none" || raw == "unlimited" { return .off }
    if raw.hasPrefix("$") { raw.removeFirst() }
    guard let usd = Double(raw), usd.isFinite, usd > 0 else { return nil }
    return .usd(usd)
  }
}

/// The `/schema` argument: a schema to set (a file path — `~` and cwd-relative — or an inline
/// JSON object, `Do.loadOutputSchema`'s rule), `off` (a finished turn is asked for no JSON
/// answer), or nil/`show` to print the one in force. H1.
enum SchemaArgument: Equatable {
  case show
  case off
  case value(String)

  static let usage = "usage: /schema <file|json> — ask every finished turn for its answer as one JSON object matching the schema (a path, or an inline {…}); /schema off stops asking; /schema alone shows the one in force"

  /// nil when the argument asks for help (`help`, `?`): the caller prints `usage`. Anything
  /// else is a schema to load — a bad one is refused by the loader with its own reason.
  static func parse(_ argument: String?) -> SchemaArgument? {
    guard let raw = argument?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
      return .show
    }
    switch raw.lowercased() {
    case "show": return .show
    case "off", "none", "clear": return .off
    case "help", "?", "usage": return nil
    default: return .value(raw)
    }
  }
}

/// How `/schema` describes a schema: its name and encoded size — the facts a user checks
/// before a turn spends a side request on it.
enum SchemaFormat {
  static func bytes(of schema: OutputSchema) -> Int {
    HeadlessJSON.line(schema.schema).utf8.count
  }

  static func describe(_ schema: OutputSchema) -> String {
    "\(schema.name) · \(bytes(of: schema)) bytes"
  }
}

// MARK: - Formatting

/// The `/context` table and the `/status` block, pure over their inputs so the layout is
/// testable without a terminal.
enum ContextFormat {
  /// The `/context` lines: a header (the model, the real prompt size when known against the
  /// window, the compaction threshold), then one row per contributor grouped by kind, then the
  /// total. Bars are proportional to the largest row. Every model string in a row name is the
  /// harness's own (section headings) — the caller still sanitizes the joined text.
  static func lines(_ report: ContextReport, model: String) -> [String] {
    var out: [String] = []
    var header = "context · \(model)"
    if let used = report.lastPromptTokens {
      header += " · last request \(formatted(used)) tokens"
      if let window = report.contextLength, window > 0 {
        header += " of \(formatted(window)) (\(used * 100 / window)%)"
      }
    } else if let window = report.contextLength {
      header += " · window \(formatted(window)) tokens"
    }
    header += " · compacts at \(Int(report.compactionThreshold * 100))%"
    out.append(header)
    let widest = report.sections.map(\.estTokens).max() ?? 0
    let nameWidth = min(28, max(12, report.sections.map { $0.name.count }.max() ?? 12))
    for kind in [ContextReport.Kind.prompt, .history, .tools] {
      let rows = report.sections.filter { $0.kind == kind }
      guard !rows.isEmpty else { continue }
      out.append("  " + groupTitle(kind))
      for row in rows {
        let name = row.name.count > nameWidth ? String(row.name.prefix(nameWidth - 1)) + "…" : row.name
        let count: String
        switch kind {
        case .prompt: count = ""
        case .history: count = String(format: "%3d msg", row.count)
        case .tools: count = String(format: "%3d def", row.count)
        }
        let line = "    \(name.padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
          + "\(count.padding(toLength: 8, withPad: " ", startingAt: 0))"
          + "\(kb(row.bytes).leftPadded(to: 9))  "
          + "~\(formatted(row.estTokens)) tok".leftPadded(to: 12)
          + "  " + bar(row.estTokens, of: widest)
        out.append(line)
      }
    }
    var total = "  total ~\(formatted(report.totalEstTokens)) tokens (\(kb(report.totalBytes)))"
    total += report.scaledToLastRequest
      ? " — estimates scaled to the last request's prompt tokens"
      : " — estimates at \(ContextReport.bytesPerToken) bytes/token; no request measured yet (a /clear, /rewind or compaction resets the measurement), so the real figure comes with the next turn"
    if let percent = report.contextPercent {
      total += " · ~\(percent)% of the window"
    }
    out.append(total)
    return out
  }

  static func groupTitle(_ kind: ContextReport.Kind) -> String {
    switch kind {
    case .prompt: return "system prompt"
    case .history: return "history"
    case .tools: return "tools"
    }
  }

  static func bar(_ value: Int, of widest: Int) -> String {
    guard widest > 0, value > 0 else { return "" }
    let width = max(1, value * 20 / widest)
    return String(repeating: "▇", count: width)
  }

  static func kb(_ bytes: Int) -> String {
    bytes < 1024 ? "\(bytes) B" : String(format: "%.1f KB", Double(bytes) / 1024)
  }

  static func formatted(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.groupingSeparator = ","
    formatter.usesGroupingSeparator = true
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
  }
}

/// The `/status` block: one `label   value` line per fact, aligned on the widest label. Facts
/// that don't apply (no name, no fork parent, not tainted, no plan) are left out, not printed
/// as `–`.
enum StatusFormat {
  struct Facts {
    var sessionId: String
    var name: String?
    var forkedFrom: String?
    var model: String
    /// The `--agent` the session runs as; nil for a plain session.
    var agent: String?
    var dialectFlag: String
    var lastDialect: String?
    var effort: Reasoning.Effort?
    var provider: String
    var mode: PermissionMode
    var readOnly: Bool
    var sandbox: String?
    var hooks: String?
    var messages: Int
    var turns: Int
    var costUSD: Double
    var budgetUSD: Double?
    var lastPromptTokens: Int?
    var contextLength: Int?
    var tainted: Bool
    var plan: [(text: String, status: String)]?
    /// The last turn's prompt tokens read from the provider's prompt cache and the turn's prompt
    /// tokens in total (`RunRecord.cachedTokens` / `promptTokens`) — the `cache` row; nil = no
    /// turn yet or nothing cached, and the row is left out.
    var cachedTokens: Int? = nil
    var cachePromptTokens: Int? = nil
    /// Whether an endpoint refused the session's `cache_control` markers, after which no request
    /// of this session carries a breakpoint (`Session.cacheControlRefused`).
    var cacheControlRefused: Bool = false
  }

  static func lines(_ facts: Facts) -> [String] {
    var rows: [(String, String)] = [("session", facts.sessionId)]
    if let name = facts.name { rows.append(("name", name)) }
    if let parent = facts.forkedFrom { rows.append(("forked from", parent)) }
    rows.append(("model", facts.model))
    if let agent = facts.agent { rows.append(("agent", agent)) }
    let dialect = facts.lastDialect.map { "\($0) (last turn; --dialect \(facts.dialectFlag))" }
      ?? "\(facts.dialectFlag) (no turn yet)"
    rows.append(("dialect", dialect))
    rows.append(("effort", facts.effort?.rawValue ?? "off"))
    rows.append(("provider", facts.provider))
    rows.append(("mode", facts.readOnly ? "\(facts.mode.label) (read-only: --safe)" : facts.mode.label))
    rows.append(("sandbox", facts.sandbox ?? "off"))
    rows.append(("hooks", facts.hooks ?? "none"))
    rows.append(("messages", "\(facts.messages) · \(facts.turns) turn\(facts.turns == 1 ? "" : "s")"))
    var cost = Renderer.usd(facts.costUSD)
    if let budget = facts.budgetUSD { cost += " of \(Renderer.usd(budget)) budget" }
    rows.append(("cost", cost))
    if let used = facts.lastPromptTokens {
      var context = "\(ContextFormat.formatted(used)) tokens"
      if let window = facts.contextLength, window > 0 {
        context += " of \(ContextFormat.formatted(window)) (\(used * 100 / window)%)"
      }
      rows.append(("context", context + " — /context for the breakdown"))
    } else {
      rows.append(("context", "not measured yet — /context estimates it"))
    }
    if facts.cacheControlRefused {
      rows.append(("cache", "cache_control refused by the endpoint — breakpoints are off for the rest of this session"))
    } else if let cached = facts.cachedTokens, cached > 0, let total = facts.cachePromptTokens, total > 0 {
      rows.append((
        "cache",
        "\(min(100, cached * 100 / total))% of the last turn's prompt tokens read from the cache"
          + " (\(ContextFormat.formatted(cached)) of \(ContextFormat.formatted(total)))"))
    }
    if facts.tainted { rows.append(("tainted", "yes — this session read untrusted content; network and out-of-tree actions prompt")) }
    if let plan = facts.plan, !plan.isEmpty {
      rows.append(("plan", "\(PlanFormat.done(plan))/\(plan.count) done"))
    }
    let width = rows.map { $0.0.count }.max() ?? 0
    var out = rows.map { "\($0.0.padding(toLength: width, withPad: " ", startingAt: 0))  \($0.1)" }
    if let plan = facts.plan, !plan.isEmpty {
      out += PlanFormat.checklistLines(plan).map { "  \($0)" }
    }
    return out
  }
}

extension Interactive {
  /// The banner's `limits` fact: the stop conditions `--budget`/`--max-steps` set, nil when
  /// neither did.
  static func limitsFact(budget: Double?, maxSteps: Int?) -> String? {
    var parts: [String] = []
    if let budget { parts.append("budget \(Renderer.usd(budget))") }
    if let maxSteps { parts.append("max \(maxSteps) steps") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// What `/thinking` and Ctrl-T print after flipping the reasoning display.
  static func thinkingNotice(on: Bool) -> String {
    on
      ? "◐ reasoning shown — /thinking off or ctrl+t to hide it"
      : "◑ reasoning hidden (the model still thinks; only the display is off) — /thinking on or ctrl+t"
  }
}

private extension String {
  func leftPadded(to width: Int) -> String {
    count >= width ? self : String(repeating: " ", count: width - count) + self
  }
}
