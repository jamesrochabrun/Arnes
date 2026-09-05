import Foundation
import OpenRouterSwift

// MARK: - ContextReport

/// What a session's next request spends the context window on, by contributor — the REPL's
/// `/context`. Three kinds of row: the system prompt's sections (one per contributor, named as
/// `Session.contextSections` names them), the history by role (`user`, `assistant`, `tool`,
/// with the message count), and the tool definitions (one row, the definition count). Every row
/// carries its bytes and an estimated token count.
///
/// The estimate is bytes/4 — the usual English-prose ratio, wrong by a factor for code or CJK
/// text, and never the tokenizer's answer. When the session knows the **real** prompt size of its
/// last request (`lastPromptTokens`), the rows are scaled so their estimates sum to it: the
/// proportions stay bytes-based, the total is the number the provider billed. `lastPromptTokens`
/// is one whole-request figure reset by `/clear`, a rewind and every compaction, so a report
/// right after any of those is unscaled until the next turn — `scaledToLastRequest` says which.
public struct ContextReport: Sendable, Equatable {
  public enum Kind: String, Sendable {
    /// A system-prompt section.
    case prompt
    /// One role's messages in the history.
    case history
    /// The tool definitions the request carries.
    case tools
  }

  public struct Section: Sendable, Equatable {
    public let kind: Kind
    public let name: String
    public let bytes: Int
    /// bytes/4, or the share of `lastPromptTokens` this row's bytes account for when known.
    public let estTokens: Int
    /// Messages (a history row) or tool definitions (the tools row); 0 for a prompt section.
    public let count: Int

    public init(kind: Kind, name: String, bytes: Int, estTokens: Int, count: Int = 0) {
      self.kind = kind
      self.name = name
      self.bytes = bytes
      self.estTokens = estTokens
      self.count = count
    }
  }

  /// Every row, prompt sections first (in prompt order), then history by role, then tools.
  public let sections: [Section]
  /// Prompt tokens the most recent request reported; nil until a turn has run since the last
  /// clear/rewind/compaction.
  public let lastPromptTokens: Int?
  /// The model's context window from the manifest, when it states one.
  public let contextLength: Int?
  /// The fraction of `contextLength` at which the session auto-compacts before a turn.
  public let compactionThreshold: Double

  public init(
    sections: [Section],
    lastPromptTokens: Int?,
    contextLength: Int?,
    compactionThreshold: Double)
  {
    self.sections = sections
    self.lastPromptTokens = lastPromptTokens
    self.contextLength = contextLength
    self.compactionThreshold = compactionThreshold
  }

  /// Whether the estimates were scaled to the last request's real prompt tokens.
  public var scaledToLastRequest: Bool { lastPromptTokens != nil }
  public var totalBytes: Int { sections.reduce(0) { $0 + $1.bytes } }
  /// The estimates' sum — `lastPromptTokens` exactly when scaled.
  public var totalEstTokens: Int { sections.reduce(0) { $0 + $1.estTokens } }
  /// `totalEstTokens` as a percentage of the context window, when the window is known.
  public var contextPercent: Int? {
    guard let contextLength, contextLength > 0 else { return nil }
    return totalEstTokens * 100 / contextLength
  }

  public static let bytesPerToken = 4

  /// Builds the report from what a session holds: its prompt sections, its history, its tool
  /// definitions and the numbers around them. Pure — the session's `contextReport()` calls it,
  /// and a test can hand it any values.
  public static func build(
    promptSections: [(name: String, text: String)],
    history: [Message],
    tools: [Tool],
    lastPromptTokens: Int?,
    contextLength: Int?,
    compactionThreshold: Double)
    -> ContextReport
  {
    var rows: [(kind: Kind, name: String, bytes: Int, count: Int)] = promptSections.map {
      (kind: .prompt, name: $0.name, bytes: $0.text.utf8.count, count: 0)
    }
    // History by role, in the fixed order a transcript reads in; a role with no messages is
    // still a row, so the table's shape doesn't jump between turns.
    for role in [Message.Role.user, .assistant, .tool] {
      let messages = history.filter { $0.role == role }
      let bytes = messages.reduce(0) { $0 + messageBytes($1) }
      rows.append((kind: .history, name: roleName(role), bytes: bytes, count: messages.count))
    }
    let toolBytes = tools.reduce(0) { $0 + definitionBytes($1) }
    rows.append((kind: .tools, name: "tool definitions", bytes: toolBytes, count: tools.count))

    let estimates = scaled(rows.map(\.bytes), toTotal: lastPromptTokens)
    let sections = zip(rows, estimates).map { row, tokens in
      Section(kind: row.kind, name: row.name, bytes: row.bytes, estTokens: tokens, count: row.count)
    }
    return ContextReport(
      sections: sections, lastPromptTokens: lastPromptTokens, contextLength: contextLength,
      compactionThreshold: compactionThreshold)
  }

  /// Token estimates for `bytes`: bytes/4 each, or — when `total` is known — shares of `total`
  /// proportional to the bytes that sum to exactly `total` (largest-remainder rounding, so no
  /// row is off by more than one token from its exact share).
  static func scaled(_ bytes: [Int], toTotal total: Int?) -> [Int] {
    guard let total, total > 0 else { return bytes.map { $0 / bytesPerToken } }
    let sum = bytes.reduce(0, +)
    guard sum > 0 else { return bytes.map { _ in 0 } }
    let exact = bytes.map { Double($0) * Double(total) / Double(sum) }
    var rounded = exact.map { Int($0.rounded(.down)) }
    var remainder = total - rounded.reduce(0, +)
    // Hand the leftover tokens to the rows with the largest fractional parts.
    let order = exact.enumerated()
      .sorted { ($0.element - $0.element.rounded(.down)) > ($1.element - $1.element.rounded(.down)) }
      .map(\.offset)
    for index in order where remainder > 0 {
      rounded[index] += 1
      remainder -= 1
    }
    return rounded
  }

  /// A message's payload bytes: its text plus, for an assistant message, the tool calls it
  /// made (name + arguments); the role and framing are not counted.
  static func messageBytes(_ message: Message) -> Int {
    var bytes = message.content?.plainText.utf8.count ?? 0
    for call in message.toolCalls ?? [] {
      bytes += (call.function?.name ?? "").utf8.count + (call.function?.arguments ?? "").utf8.count
    }
    return bytes
  }

  /// A tool definition's bytes as the request encodes it (name, description, schema).
  static func definitionBytes(_ tool: Tool) -> Int {
    (try? JSONEncoder().encode(tool))?.count ?? 0
  }

  static func roleName(_ role: Message.Role) -> String {
    role.rawValue
  }
}
