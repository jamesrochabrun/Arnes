import Foundation
import OpenRouterSwift

// MARK: - EvalCaptureError

public enum EvalCaptureError: Error, Sendable {
  /// The writer model could not produce a valid task after retries; carries the
  /// last validation problem.
  case distillationFailed(String)
}

// MARK: - EvalCapture

/// Turns a lived session (or a plain task description) into a reusable `EvalTask` —
/// the "I watched the agent fumble this; make it a test" path. A writer model drafts
/// the task; validation then proves the draft is a *real* test before it is accepted.
public enum EvalCapture {

  /// Plain-text rendering of a session transcript for the writer model: roles, text,
  /// tool calls with argument previews, and (truncated) tool outputs — enough context
  /// to reconstruct what the task was and where it went wrong.
  public static func renderTranscript(_ messages: [Message]) -> String {
    var lines: [String] = []
    for message in messages {
      var text = message.content?.plainText ?? ""
      if let calls = message.toolCalls, !calls.isEmpty {
        let rendered = calls
          .map { "\($0.function?.name ?? "?")(\(String(($0.function?.arguments ?? "").prefix(300))))" }
          .joined(separator: ", ")
        text += (text.isEmpty ? "" : "\n") + "[tool calls: \(rendered)]"
      }
      let limit = message.role == .tool ? 400 : 2000
      lines.append("\(message.role.rawValue): \(String(text.prefix(limit)))")
    }
    return lines.joined(separator: "\n\n")
  }

  /// Slices a transcript into per-turn sources for `capture --split`: one source per
  /// user turn (the user message through everything before the next user message),
  /// prefixed with a brief summary of earlier turns so follow-ups like "now add
  /// persistence" stay self-contained.
  public static func splitSources(_ messages: [Message]) -> [String] {
    var sources: [String] = []
    var context: [String] = []
    for turn in turns(messages) {
      var source = ""
      if !context.isEmpty {
        source += "Earlier in the session (summary):\n" + context.joined(separator: "\n") + "\n\n"
      }
      source += "Current turn transcript:\n" + renderTranscript(turn)
      sources.append(source)
      // Summarize this turn for the ones after it: the request and the final reply.
      if let user = turn.first(where: { $0.role == .user })?.content?.plainText {
        context.append("user: \(String(user.prefix(300)))")
      }
      if let reply = turn.last(where: { $0.role == .assistant })?.content?.plainText, !reply.isEmpty {
        context.append("assistant: \(String(reply.prefix(300)))")
      }
    }
    return sources
  }

  /// Groups a chat-shaped history into user turns; anything before the first user
  /// message is dropped.
  static func turns(_ messages: [Message]) -> [[Message]] {
    var result: [[Message]] = []
    var current: [Message] = []
    for message in messages {
      if message.role == .user {
        if !current.isEmpty {
          result.append(current)
        }
        current = [message]
      } else if !current.isEmpty {
        current.append(message)
      }
    }
    if !current.isEmpty {
      result.append(current)
    }
    return result
  }

  /// Dry-runs the task's plumbing in a fresh temp directory. Returns nil when the
  /// task is a real test, or the reason it isn't:
  /// - the setup script must succeed, and
  /// - the check must FAIL before any agent work — a check that passes on the
  ///   freshly set-up directory tests nothing.
  public static func validate(_ task: EvalTask) -> String? {
    guard !task.id.isEmpty, !task.prompt.isEmpty, !task.check.isEmpty else {
      return "id, prompt, and check are all required"
    }
    let workdir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-capture-\(UUID().uuidString)")
    do {
      try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true)
    } catch {
      return "cannot create validation workdir: \(error)"
    }
    defer { try? FileManager.default.removeItem(at: workdir) }

    if let setup = task.setup {
      let result = EvalRunner.bash(setup, cwd: workdir, timeoutSeconds: 60)
      guard result.exit == 0 else {
        return "setup failed (exit \(result.exit)): \(String(result.output.prefix(200)))"
      }
    }
    let pre = EvalRunner.bash(task.check, cwd: workdir, timeoutSeconds: 60)
    if pre.exit == 0 {
      return "vacuous: the check passes before any work is done — it must fail on the fresh setup"
    }
    return nil
  }
}

// MARK: - EvalTaskDistiller

/// Asks a writer model to distill a source (transcript or description) into an
/// `EvalTask`, validates the draft with `EvalCapture.validate`, and retries once
/// with the validation problem fed back.
public final class EvalTaskDistiller: @unchecked Sendable {
  public struct Output: Sendable {
    public let task: EvalTask
    public let costUSD: Double
    public let attempts: Int
  }

  private let service: OpenRouterService

  public init(service: OpenRouterService) {
    self.service = service
  }

  public func distill(
    from source: String,
    hint: String? = nil,
    model: String = "openrouter/auto")
    async throws -> Output
  {
    guard let output = try await run(source: source, hint: hint, model: model, allowSkip: false) else {
      throw EvalCaptureError.distillationFailed("writer skipped a non-skippable source")
    }
    return output
  }

  /// Split-mode distillation: returns nil when the writer judges the turn contains no
  /// distillable task (a question, chit-chat, a meta command).
  public func distillIfTask(
    from source: String,
    hint: String? = nil,
    model: String = "openrouter/auto")
    async throws -> Output?
  {
    try await run(source: source, hint: hint, model: model, allowSkip: true)
  }

  private func run(
    source: String,
    hint: String?,
    model: String,
    allowSkip: Bool)
    async throws -> Output?
  {
    var feedback: String?
    var cost = 0.0
    for attempt in 1...2 {
      let system = allowSkip ? Self.writerPrompt + " " + Self.skipInstruction : Self.writerPrompt
      let response = try await service.chatCompletion(
        ChatCompletionRequest(
          model: model,
          messages: [
            .system(system),
            .user(Self.userText(source: source, hint: hint, feedback: feedback)),
          ]))
      cost += response.usage?.cost ?? 0
      let reply = response.choices.first?.message.content ?? ""
      if allowSkip,
         reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().hasPrefix("SKIP")
      {
        return nil
      }
      guard var task = Self.parseTask(reply) else {
        feedback = "Your reply was not a single valid JSON object matching the schema. Reply with only the JSON."
        continue
      }
      // Writers underestimate agent wall-clock (network round-trips included); a tiny
      // timeout fails runs that did the work. Below the default's floor, drop it.
      if let timeout = task.timeoutSeconds, timeout < 120 {
        task.timeoutSeconds = nil
      }
      if let problem = EvalCapture.validate(task) {
        feedback = "The task failed validation: \(problem). Return the corrected JSON."
        continue
      }
      return Output(task: task, costUSD: cost, attempts: attempt)
    }
    throw EvalCaptureError.distillationFailed(feedback ?? "no usable reply")
  }

  /// Extracts the task JSON from a possibly fenced/chatty reply.
  static func parseTask(_ reply: String) -> EvalTask? {
    guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end else {
      return nil
    }
    return try? JSONDecoder().decode(EvalTask.self, from: Data(reply[start...end].utf8))
  }

  private static let writerPrompt = """
    You distill agent work into evaluation tasks. Given a transcript (or task \
    description), produce ONE eval task as a JSON object with exactly these fields:
    {"id": short-kebab-case-name, "prompt": the instruction an agent will receive, \
    "setup": bash that recreates the starting files (omit the field if none are needed), \
    "check": bash whose exit 0 means the task was completed correctly, \
    "timeoutSeconds": only if the task genuinely needs more than 300}
    Rules: everything runs in an empty temp directory with only what setup creates; \
    paths are relative; no network access. The check must be strict and programmatic — \
    verify actual outcomes (file contents, program output), not effort. Assert content, \
    not incidental formatting: never let a check hinge on a trailing newline, exact \
    whitespace, or ordering the prompt didn't demand (e.g. prefer `grep -c`/`grep -q` \
    over `wc -l` for line-content assertions). The check MUST \
    fail on the freshly set-up directory, before any work is done. The prompt must be \
    self-contained (an agent with no other context can act on it). If the transcript \
    shows a failure, capture the task that was fumbled — including the tricky part — \
    not the failure itself. Reply with only the JSON object.
    """

  private static let skipInstruction = """
    If the current turn contains no distillable agent task — a question, chit-chat, a \
    meta command, or discussion with no verifiable outcome — reply with exactly SKIP.
    """

  private static func userText(source: String, hint: String?, feedback: String?) -> String {
    var parts = ["Source:\n\(String(source.prefix(20_000)))"]
    if let hint {
      parts.append("Focus: \(hint)")
    }
    if let feedback {
      parts.append("Previous attempt rejected: \(feedback)")
    }
    return parts.joined(separator: "\n\n")
  }
}
