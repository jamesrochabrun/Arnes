import Foundation
import OpenRouterSwift

// MARK: - ToolEventSink

/// The event stream of the turn a tool is executing in, for a tool that wants to surface
/// something typed while it runs (`PlanTool` emits `.planUpdated` through it). The session sets
/// it around every tool execution (`Session.execute`), so it is per *execution*, not per tool
/// instance — the difference that matters for a tool shared between sessions: a nested subagent
/// session runs the lead's tool instances, and a sink stored on the instance (`EventEmittingTool`)
/// would be overwritten by whichever session bound it last and cleared when that session's turn
/// ended, while two subagents running at once would race for it. A task-local is scoped to the
/// execution that set it and inherited by any child task it spawns, so a plan a subagent posts
/// reaches the subagent's stream (and the lead as a nested event), never the lead's own.
/// nil outside a session's tool path (a tool called directly): nothing is emitted.
public enum ToolEventSink {
  @TaskLocal public static var current: (@Sendable (AgentEvent) -> Void)?
}

// MARK: - update_plan

/// A dumb task-tracking tool — the harness primitive both Claude Code (`TodoWrite`) and Codex
/// (`update_plan`) ship. The model publishes a checklist and refreshes it as work proceeds; the
/// list surfaces in the transcript so a long, multi-step task stays visible and on-track.
///
/// It is deliberately stateless and side-effect-free: each call carries the COMPLETE plan
/// (finished steps marked `completed`), the tool just validates and renders it. That contract
/// is what keeps a non-frontier model honest — there's no hidden state to get out of sync with.
///
/// A valid call is also surfaced to the caller as `AgentEvent.planUpdated` (through
/// `ToolEventSink`), so a UI can pin the latest checklist instead of parsing the result text;
/// `Session.lastPlanSteps` reads the latest plan back out of the history.
public struct PlanTool: AgentTool {
  public static let toolName = "update_plan"

  public let name = PlanTool.toolName
  public let description =
    "Record or update your task plan as a checklist. Pass the COMPLETE list every time, with "
    + "each step's status (pending, in_progress, completed) — mark exactly one step in_progress "
    + "while you work it. Use it for any multi-step task to track progress. It has no side effects."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = PlanTool.schema

  // Built in pieces: a single deeply-nested JSONValue literal overwhelms the type-checker.
  private static let stepSchema: JSONValue = {
    let status: JSONValue = ["type": "string", "enum": ["pending", "in_progress", "completed"]]
    let properties: JSONValue = ["step": ["type": "string"], "status": status]
    return ["type": "object", "properties": properties, "required": ["step", "status"]]
  }()

  private static let schema: JSONValue = {
    let plan: JSONValue = [
      "type": "array", "description": "The full ordered checklist.", "items": stepSchema,
    ]
    let explanation: JSONValue = ["type": "string", "description": "Optional one-line note on the update."]
    let properties: JSONValue = ["plan": plan, "explanation": explanation]
    return ["type": "object", "properties": properties, "required": ["plan"]]
  }()

  public init() { }

  public func summary(arguments: [String: JSONValue]) -> String {
    let steps = Self.steps(from: arguments)
    let done = steps.filter { $0.status == .completed }.count
    return "update_plan (\(done)/\(steps.count) done)"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    let steps = Self.steps(from: arguments)
    guard !steps.isEmpty else { return "error: 'plan' must be a non-empty array of {step, status}" }
    ToolEventSink.current?(.planUpdated(steps: steps.map { (text: $0.text, status: $0.status.rawValue) }))
    var out = ""
    if let explanation = arguments["explanation"]?.stringValue, !explanation.isEmpty {
      out += explanation + "\n"
    }
    out += steps.map { $0.line }.joined(separator: "\n")
    // The contract is one step in flight at a time; a plan that marks several is told so in
    // the result (a fixed, family-neutral note — the description already states the rule).
    let inProgress = steps.filter { $0.status == .inProgress }.count
    if inProgress > 1 {
      out += "\n[arnes: \(inProgress) steps are in_progress — keep exactly one]"
    }
    return out
  }

  enum Status: String { case pending, inProgress = "in_progress", completed }

  struct Step {
    let text: String
    let status: Status
    var line: String {
      let mark: String
      switch status {
      case .completed: mark = "[x]"
      case .inProgress: mark = "[~]"
      case .pending: mark = "[ ]"
      }
      return "\(mark) \(text)"
    }
  }

  static func steps(from arguments: [String: JSONValue]) -> [Step] {
    guard let raw = arguments["plan"]?.arrayValue else { return [] }
    return raw.compactMap { item in
      guard let object = item.objectValue, let text = object["step"]?.stringValue else { return nil }
      let status = object["status"]?.stringValue.flatMap(Status.init(rawValue:)) ?? .pending
      return Step(text: text, status: status)
    }
  }

  /// The plan an `update_plan` call's arguments carry, as `(text, status)` pairs with the
  /// status spelled as the schema does (`pending` · `in_progress` · `completed`; an unknown
  /// value reads as `pending`). Empty when the arguments hold no usable plan. What
  /// `Session.lastPlanSteps` reads off the history's last `update_plan` call, and what the
  /// `.planUpdated` event carries.
  public static func planSteps(fromArgumentsJSON json: String) -> [(text: String, status: String)] {
    guard
      let data = json.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      let arguments = value.objectValue
    else { return [] }
    return steps(from: arguments).map { (text: $0.text, status: $0.status.rawValue) }
  }
}

// MARK: - think

/// A no-op scratchpad — Anthropic's "think" tool. It does nothing but record a thought, giving
/// the model a place to reason over tool results mid-chain before it acts, without that
/// reasoning having to become user-facing prose or a real (mutating) action. Measured to help
/// on complex tool-use trajectories; the heavy guidance belongs in the system prompt, so the
/// description stays minimal.
///
/// Model-adaptive omission (T5, `CapabilityGatedTool`): a model that reasons natively — the
/// manifest says so *and* the session's reasoning dial is on — has a scratchpad already, so under
/// `Configuration.adaptiveThink` the tool is left out of that model's prompt and requests. Off by
/// default; every model keeps the tool until an eval A/B says otherwise.
public struct ThinkTool: AgentTool, CapabilityGatedTool {
  public static let toolName = "think"
  public let name = ThinkTool.toolName
  public let description =
    "Think: jot a reasoning step or short plan before acting. No side effects — nothing runs, "
    + "nothing is read or written. Use it to reason over results in a long tool chain."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": ["thought": ["type": "string"]],
    "required": ["thought"],
  ]

  public init() { }

  /// Present unless the session opted into adaptive omission for a model that reasons natively
  /// with the dial on. `.none` is the dial's "off" spelling, so it keeps the tool like nil does.
  public func isAvailable(for profile: ModelProfile, configuration: Session.Configuration) -> Bool {
    !Self.omitted(for: profile, configuration: configuration)
  }

  /// The one rule, readable by name: adaptive omission on, the manifest advertises reasoning, and
  /// the session actually asked for it.
  static func omitted(for profile: ModelProfile, configuration: Session.Configuration) -> Bool {
    guard configuration.adaptiveThink, profile.supportsReasoning else { return false }
    guard let effort = configuration.reasoningEffort else { return false }
    return effort != .none
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    "think: \((arguments["thought"]?.stringValue ?? "").prefix(80))"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    // The value is that the model produced the thought; nothing to return.
    arguments["thought"]?.stringValue == nil ? "error: missing 'thought'" : ""
  }
}
