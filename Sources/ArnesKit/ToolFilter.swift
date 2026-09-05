import Foundation

// MARK: - ToolFilterError

public enum ToolFilterError: Error, Equatable, CustomStringConvertible, Sendable {
  /// A name (or `prefix*` glob) that matched nothing the run has — a typo, or an MCP server
  /// that didn't connect. Refused up front rather than silently scoping nothing.
  case unknownTool(name: String, available: [String])

  public var description: String {
    switch self {
    case .unknownTool(let name, let available):
      let listing = available.isEmpty ? "(none)" : available.joined(separator: ", ")
      return "unknown tool '\(name)' — available: \(listing)"
    }
  }
}

// MARK: - ToolFilter

/// Scopes a toolset by name — the `--allowed-tools` / `--disallowed-tools` ceiling on a
/// headless run. A pure list operation on top of `HarnessAssembly`, never a permission
/// decision: what survives here still goes through the gate, and rules about *arguments*
/// (`Bash(git status:*)`) stay in `~/.arnes/rules.json`.
///
/// Names are exact or `prefix*` globs (`mcp__github__*`); Claude Code spellings (`Read`,
/// `Edit`, `Bash`, `Task`…) are accepted through `AgentLibrary.canonicalToolName`. A name that
/// matches nothing throws — except the harness's own tool names, which may simply be absent
/// from this run (`--disallowed-tools skill` on a run with no skills is a no-op, not an error).
public enum ToolFilter {
  /// The harness's own tool vocabulary: always a valid thing to name, present or not.
  public static let harnessToolNames: Set<String> = [
    "read_file", "write_file", "edit_file", "bash", "grep", "glob", "update_plan", "think",
    "ask_user", "skill", "task", "job", ViewImageTool.toolName, WebFetchTool.toolName,
  ]

  /// `allowed` keeps only the named tools (`nil` = everything, `[]` = nothing — a pure-chat
  /// run); `disallowed` removes; disallow wins where both name a tool. Every entry is
  /// validated against `tools` (plus `harnessToolNames`) before anything is filtered, so a
  /// typo fails the run instead of quietly changing its shape.
  public static func apply(
    _ tools: [any AgentTool],
    allowed: [String]?,
    disallowed: [String])
    throws -> [any AgentTool]
  {
    let names = tools.map(\.name)
    let allowedPatterns = try allowed.map { try validated($0, against: names) }
    let disallowedPatterns = try validated(disallowed, against: names)
    return tools.filter { tool in
      permits(tool.name, allowed: allowedPatterns, disallowed: disallowedPatterns)
    }
  }

  /// Whether a tool named `name` survives the filter — for a tool the caller builds *after*
  /// filtering (the task tool, which needs the filtered list as its subagents' ceiling).
  /// `allowed`/`disallowed` are raw spellings; they are canonicalized here.
  public static func permits(_ name: String, allowed: [String]?, disallowed: [String]) -> Bool {
    let allowedPatterns = allowed.map { $0.map(canonical) }
    let disallowedPatterns = disallowed.map(canonical)
    return permitsCanonical(name, allowed: allowedPatterns, disallowed: disallowedPatterns)
  }

  /// A comma-separated / repeatable flag's values as one list of trimmed, non-empty names.
  public static func names(from values: [String]) -> [String] {
    values.flatMap { $0.split(separator: ",") }
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// The canonical (arnes) spelling of a tool name or glob. `Task`/`Agent` name the task
  /// tool here — the lead may scope its own delegation, unlike a subagent's allowlist where
  /// the same words map to nothing. An empty name stays empty (and so matches nothing).
  public static func canonical(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, !trimmed.hasSuffix("*") else { return trimmed }
    let mapped = AgentLibrary.canonicalToolName(trimmed)
    return mapped.isEmpty ? "task" : mapped
  }

  /// Exact name, or a `prefix*` glob (the only glob form: a `*` at the end).
  public static func matches(_ pattern: String, _ name: String) -> Bool {
    if pattern.hasSuffix("*") {
      return name.hasPrefix(String(pattern.dropLast()))
    }
    return pattern == name
  }

  // MARK: Internals

  /// Canonicalizes every pattern and refuses one that names nothing in `names` (unless it is
  /// one of the harness's own tool names, which may legitimately be absent).
  private static func validated(_ patterns: [String], against names: [String]) throws -> [String] {
    try patterns.map { raw in
      let pattern = canonical(raw)
      guard names.contains(where: { matches(pattern, $0) }) || harnessToolNames.contains(pattern) else {
        throw ToolFilterError.unknownTool(name: raw, available: names)
      }
      return pattern
    }
  }

  private static func permitsCanonical(_ name: String, allowed: [String]?, disallowed: [String]) -> Bool {
    if disallowed.contains(where: { matches($0, name) }) { return false }
    guard let allowed else { return true }
    return allowed.contains { matches($0, name) }
  }
}
