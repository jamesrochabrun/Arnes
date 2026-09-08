import Foundation

/// Correlated, presentation-only progress for embedders. IDs identify invocations, not
/// model-provided call IDs (which may repeat across turns). No schema or authority changes.
public struct ToolActivity: Sendable {
  public enum Phase: Sendable {
    case pending, running, completed, failed
  }
  public let id: String
  public let name: String
  public let phase: Phase
  /// A bounded, scrubbed excerpt, never a replacement for the recorded tool result.
  public let preview: String?
}
