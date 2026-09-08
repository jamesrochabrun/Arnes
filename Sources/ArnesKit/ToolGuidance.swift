import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

/// Optional, trusted pack prose. Guidance augments the tool's contract; it cannot replace
/// a schema, offer a withheld tool, or alter execution and permission checks.
public struct ToolGuidance: Sendable {
  public let entries: [String: String]

  public init(entries: [String: String] = [:]) {
    self.entries = entries.filter { name, text in
      !name.isEmpty && name.count <= 128 && text.count <= 2_000
        && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }

  /// `<family>.tools.json` is a flat tool-name → guidance dictionary. An invalid or
  /// oversized file leaves defaults untouched. Unknown names never create tools.
  static func load(for family: ModelFamily, in directory: URL) -> ToolGuidance {
    let url = directory.appendingPathComponent("\(family.rawValue).tools.json")
    var before = stat()
    guard lstat(url.path, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return .init() }
    let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return .init() }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    var opened = stat()
    guard fstat(descriptor, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG,
      opened.st_dev == before.st_dev, opened.st_ino == before.st_ino
    else { return .init() }
    guard let data = try? handle.read(upToCount: 65_537), data.count <= 65_536,
      let entries = try? JSONDecoder().decode([String: String].self, from: data),
      entries.count <= 64
    else { return .init() }
    return .init(entries: entries)
  }

  public func description(for tool: any AgentTool) -> String {
    guard let guidance = entries[tool.name] else { return tool.description }
    return tool.description + "\n\nModel guidance:\n" + guidance
  }

  /// Definition-only view, constructed AFTER capability gating. Session executes the
  /// original tool, so its additional protocols and safety checks remain authoritative.
  func rendering(_ tool: any AgentTool) -> any AgentTool {
    GuidedTool(base: tool, description: description(for: tool))
  }
}

private struct GuidedTool: AgentTool {
  let base: any AgentTool
  let description: String
  var name: String { base.name }
  var parameters: JSONValue { base.parameters }
  var permission: ToolPermission { base.permission }
  func permission(for arguments: [String: JSONValue]) -> ToolPermission {
    base.permission(for: arguments)
  }
  func summary(arguments: [String: JSONValue]) -> String { base.summary(arguments: arguments) }
  func execute(arguments: [String: JSONValue]) async throws -> String {
    try await base.execute(arguments: arguments)
  }
}
