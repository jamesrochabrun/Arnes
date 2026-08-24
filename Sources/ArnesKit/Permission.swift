import Foundation

// MARK: - ToolPermission

/// How dangerous a tool is. `.readOnly` tools run freely; `.mutating` tools go through
/// the session's `PermissionDelegate` before executing.
public enum ToolPermission: Sendable {
  case readOnly
  case mutating
}

// MARK: - PermissionDecision

/// The answer to "may this tool run?".
public enum PermissionDecision: Sendable {
  case allow
  /// Allow, and stop asking for this tool for the rest of the session.
  case allowAlwaysThisSession
  /// Refuse; the reason is reported to the model as the tool result so it can adapt.
  case deny(reason: String?)
}

// MARK: - PermissionDelegate

/// Decides whether a `.mutating` tool call may execute. The CLI implements this with an
/// interactive y/n/a prompt; headless callers use `AutoApprovePermissions` (today's
/// behavior) or `DenyMutationsPermissions` (`--safe`).
///
/// This is deliberately separate from `AgentEvent`: events are one-way notifications,
/// a permission check is a request that needs an answer.
public protocol PermissionDelegate: Sendable {
  func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision
}

/// Approves everything — the headless default, matching pre-v0.2 behavior.
public struct AutoApprovePermissions: PermissionDelegate {
  public init() { }

  public func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    .allow
  }
}

/// Denies every mutating tool — for `arnes do --safe`.
public struct DenyMutationsPermissions: PermissionDelegate {
  public init() { }

  public func decide(toolName: String, summary: String, argumentsJSON: String) async -> PermissionDecision {
    .deny(reason: "mutating tools are disabled (--safe mode)")
  }
}
