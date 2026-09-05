import Foundation
import OpenRouterSwift

// MARK: - ask_user

/// One dumb question to the human, mid-turn: a required `question` string and an optional list
/// of short `options`. The answer is text the model reads — never a permission grant, so the
/// tool is `.readOnly` and no gate is ever asked about it.
///
/// Who answers is the `UserInputDelegate` the toolset was built with (`ToolContext.userInput`):
/// the REPL binds a terminal prompt, every unattended runner keeps `NoUserInput`, whose
/// `.unavailable` reason comes back as an `error:` result. The `error:` prefix is deliberate —
/// it counts as a failure for the loop guard, so a model that keeps asking where nobody can
/// answer is stopped after `maxConsecutiveErrors`, and `PostToolUseFailure` hooks see it.
///
/// The question is emitted as `.userQuestion` **before** the delegate is consulted, so a UI
/// sees it in order with the tool call; the REPL's delegate prints the prompt itself. Not a
/// `ConcurrentTool`: a question must never interleave with another prompt.
public final class AskUserTool: EventEmittingTool, @unchecked Sendable {
  public static let toolName = "ask_user"

  public let name = AskUserTool.toolName
  public let description =
    "Ask the user one short question when the task is genuinely ambiguous and you cannot "
    + "resolve it from the code or the files. Offer 2–5 short options when there are natural "
    + "choices. Do not use it for permission — the harness asks that itself — or to confirm "
    + "routine steps. If it answers that no user is present, pick the most reasonable option, "
    + "state the assumption explicitly in your final summary, and continue."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "question": ["type": "string"],
      "options": ["type": "array", "items": ["type": "string"]],
    ],
    "required": ["question"],
  ]

  /// Longest question the tool relays; over it the call is refused with a coaching error.
  public static let maxQuestionChars = 500
  /// Options kept per call (the rest are dropped, not an error) and the longest one kept whole.
  public static let maxOptions = 5
  public static let maxOptionChars = 100

  private let userInput: any UserInputDelegate
  private let lock = NSLock()
  private var _onEvent: (@Sendable (AgentEvent) -> Void)?

  /// Bound per turn by the session (`bindEventEmitters`); lock-protected like `TaskTool`'s
  /// because the session writes it from another thread when the turn ends.
  public var onEvent: (@Sendable (AgentEvent) -> Void)? {
    get { lock.withLock { _onEvent } }
    set { lock.withLock { _onEvent = newValue } }
  }

  public init(userInput: any UserInputDelegate) {
    self.userInput = userInput
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    "ask_user: \((arguments["question"]?.stringValue ?? "").prefix(80))"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    let question = (arguments["question"]?.stringValue ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !question.isEmpty, question.count <= Self.maxQuestionChars else {
      return "error: ask_user needs a short non-empty question (≤ \(Self.maxQuestionChars) chars)"
    }
    let options = Self.cleanedOptions(arguments["options"])
    onEvent?(.userQuestion(question: question, options: options))
    switch await userInput.answer(question: question, options: options) {
    case .text(let answer):
      return "user answered: \(answer)"
    case .unavailable(let reason):
      return "error: cannot ask the user (\(reason)). Pick the most reasonable option, state "
        + "the assumption explicitly in your final summary, and continue."
    }
  }

  /// Options as the user will see them: trimmed, blanks dropped, duplicates dropped, clipped
  /// to `maxOptionChars`, at most `maxOptions` kept in the model's order. A non-array (or a
  /// non-string entry) is ignored rather than refused — the question still stands.
  static func cleanedOptions(_ value: JSONValue?) -> [String] {
    guard let items = value?.arrayValue else { return [] }
    var seen = Set<String>()
    var kept: [String] = []
    for item in items {
      guard let raw = item.stringValue else { continue }
      let trimmed = String(raw.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxOptionChars))
      guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { continue }
      kept.append(trimmed)
      if kept.count == Self.maxOptions { break }
    }
    return kept
  }
}
