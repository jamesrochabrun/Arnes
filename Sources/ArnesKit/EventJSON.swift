import Foundation
import OpenRouterSwift

// MARK: - AgentEvent → JSON

extension AgentEvent {
  /// The event as one JSON object for the headless `stream-json` output.
  ///
  /// `type` is `kind.rawValue` (the stable snake_case tag every case already has), every
  /// object carries `session_id`, and the payload keys are snake_case and fixed here — a
  /// consumer that switches on `type` never sees a key renamed underneath it. The switch is
  /// exhaustive without a `default`, so a new `AgentEvent` case is a compile error until it
  /// has a wire shape.
  ///
  /// - Parameters:
  ///   - sessionId: the session whose stream this is — the lead's, also on nested objects.
  ///   - agent: names the subagent a nested event is about (`subagent.event` objects carry
  ///     it); nil on the lead's own events.
  public func jsonObject(sessionId: String, agent: String? = nil) -> JSONValue {
    var object: [String: JSONValue] = [
      "type": .string(kind.rawValue),
      "session_id": .string(sessionId),
    ]
    if let agent {
      object["agent"] = .string(agent)
    }
    switch self {
    case .textDelta(let text):
      object["text"] = .string(text)
    case .reasoningDelta(let text):
      object["text"] = .string(text)
    case .assistantText(let text):
      object["text"] = .string(text)
    case .toolCall(let name, let arguments):
      object["name"] = .string(name)
      object["arguments"] = Self.parsedArguments(arguments)
    case .toolResult(let name, let preview):
      object["name"] = .string(name)
      object["preview"] = .string(preview)
    case .toolDenied(let name, let reason):
      object["name"] = .string(name)
      object["reason"] = Self.optional(reason)
    case .userQuestion(let question, let options):
      object["question"] = .string(question)
      object["options"] = .array(options.map { .string($0) })
    case .verifier(let passed, let verdict):
      object["passed"] = .bool(passed)
      object["verdict"] = .string(verdict)
    case .structuredOutput(let json, let valid, let errors):
      object["json"] = json ?? .null
      object["valid"] = .bool(valid)
      object["errors"] = .array(errors.map { .string($0) })
    case .routed(let model, let provider):
      object["model"] = .string(model)
      object["provider"] = Self.optional(provider)
    case .dialectFellBack(let dialect, let reason):
      object["dialect"] = .string(dialect)
      object["reason"] = .string(reason)
    case .interrupted:
      break
    case .nudged(let reason):
      object["reason"] = .string(reason)
    case .stepLimitReached(let maxSteps):
      object["max_steps"] = .int(maxSteps)
    case .budgetReached(let spentUSD, let budgetUSD):
      object["spent_usd"] = .double(spentUSD)
      object["budget_usd"] = .double(budgetUSD)
    case .hookNotice(let event, let output):
      object["event"] = .string(event)
      object["output"] = .string(output)
    case .hookBlocked(let tool, let reason):
      object["tool"] = .string(tool)
      object["reason"] = .string(reason)
    case .hookStopped(let reason):
      object["reason"] = Self.optional(reason)
    case .promptBlocked(let reason):
      object["reason"] = .string(reason)
    case .deniedLoop(let count):
      object["count"] = .int(count)
    case .stuckDetected(let reason):
      object["reason"] = .string(reason)
    case .contentFlagged(let tool, let patterns):
      object["tool"] = .string(tool)
      object["patterns"] = .array(patterns.map { .string($0) })
    case .jobStarted(let id, let command):
      object["id"] = .int(id)
      object["command"] = .string(command)
    case .jobFinished(let id, let exitStatus):
      object["id"] = .int(id)
      object["exit_status"] = .int(Int(exitStatus))
    case .retrying(let attempt, let reason):
      object["attempt"] = .int(attempt)
      object["reason"] = .string(reason)
    case .truncated:
      break
    case .planUpdated(let steps):
      object["steps"] = .array(steps.map { .object(["step": .string($0.text), "status": .string($0.status)]) })
    case .compacted(let summarizedMessages, let keptMessages):
      object["summarized_messages"] = .int(summarizedMessages)
      object["kept_messages"] = .int(keptMessages)
    case .toolResultsCleared(let count, let freedChars):
      object["count"] = .int(count)
      object["freed_chars"] = .int(freedChars)
    case .contextWarning(let message):
      object["message"] = .string(message)
    case .subagentBlocked(let name, let id, let reason):
      object["name"] = .string(name)
      object["id"] = .string(id)
      object["reason"] = .string(reason)
    case .subagentStarted(let name, let id, let model, let task):
      object["name"] = .string(name)
      object["id"] = .string(id)
      object["model"] = .string(model)
      object["task"] = .string(task)
    case .subagent(let name, let id, let event):
      object["name"] = .string(name)
      object["id"] = .string(id)
      object["event"] = event.jsonObject(sessionId: sessionId, agent: name)
    case .subagentFinished(let name, let id, let steps, let toolCalls, let costUSD, let resultPreview):
      object["name"] = .string(name)
      object["id"] = .string(id)
      object["steps"] = .int(steps)
      object["tool_calls"] = .int(toolCalls)
      object["cost_usd"] = .double(costUSD)
      object["result_preview"] = .string(resultPreview)
    case .subagentBackgrounded(let name, let id, let model):
      object["name"] = .string(name)
      object["id"] = .string(id)
      object["model"] = .string(model)
    case .subagentJoining(let pending):
      object["pending"] = .int(pending)
    case .turnFinished(let stats):
      object["steps"] = .int(stats.steps)
      object["tool_calls"] = .int(stats.toolCalls)
      object["turn_cost_usd"] = .double(stats.turnCostUSD)
      object["session_cost_usd"] = .double(stats.sessionCostUSD)
      object["requested_model"] = .string(stats.requestedModel)
      object["routed_models"] = .array(stats.routedModels.map { .string($0) })
      object["prompt_tokens"] = stats.promptTokens.map { .int($0) } ?? .null
      object["context_length"] = stats.contextLength.map { .int($0) } ?? .null
      object["cached_prompt_tokens"] = stats.cachedPromptTokens.map { .int($0) } ?? .null
      object["duration_seconds"] = .double(stats.durationSeconds)
    }
    return .object(object)
  }

  /// `jsonObject` serialized as one line (sorted keys, no trailing newline).
  public func jsonLine(sessionId: String, agent: String? = nil) -> String {
    HeadlessJSON.line(jsonObject(sessionId: sessionId, agent: agent))
  }

  /// Tool arguments as the model sent them: parsed into JSON when they are valid JSON (the
  /// normal case, so a consumer reads `arguments.path` directly), else the raw string — a
  /// truncated or malformed argument blob is still worth seeing, never worth dropping.
  static func parsedArguments(_ raw: String) -> JSONValue {
    if let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(raw.utf8)) {
      return parsed
    }
    return .string(raw)
  }

  private static func optional(_ text: String?) -> JSONValue {
    text.map { .string($0) } ?? .null
  }
}
