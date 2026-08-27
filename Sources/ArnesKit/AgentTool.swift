import Foundation
import OpenRouterSwift

// MARK: - AgentTool

/// A tool the agent can call. Arnes keeps tools few and schemas dumb on purpose:
/// simple orthogonal tools are what make "any model" honest — every extra tool and
/// clever schema is a place where a non-frontier model face-plants.
public protocol AgentTool: Sendable {
  var name: String { get }
  var description: String { get }
  /// JSON Schema for the arguments object.
  var parameters: JSONValue { get }
  /// Whether this tool mutates state. `.mutating` tools go through the session's
  /// `PermissionDelegate` before executing; `.readOnly` tools run freely.
  var permission: ToolPermission { get }
  /// One-line description of a specific invocation, shown in permission prompts.
  func summary(arguments: [String: JSONValue]) -> String
  func execute(arguments: [String: JSONValue]) async throws -> String
}

/// A tool that contributes a section to the system prompt (skill and subagent
/// listings). Sections ride every request so the model knows what it can reach for.
public protocol PromptContributing {
  /// The section text; empty when there is nothing to list.
  var promptSection: String { get }
}

/// A tool whose execution spends money on nested model calls (the task tool). The
/// session drains the accrued amount after each call so subagent spend lands in the
/// parent turn's cost and `RunRecord`.
public protocol CostReportingTool {
  /// Returns the USD accrued since the last drain and resets the accumulator.
  func drainAccruedCost() -> Double
}

extension AgentTool {
  /// The OpenRouter chat tool definition for this tool.
  public var toolDefinition: Tool {
    .function(name: name, description: description, parameters: parameters)
  }

  /// Fail-safe default: a tool that doesn't declare itself is treated as mutating.
  public var permission: ToolPermission { .mutating }

  public func summary(arguments: [String: JSONValue]) -> String {
    let rendered = arguments
      .sorted { $0.key < $1.key }
      .compactMap { key, value in value.stringValue.map { "\(key): \($0)" } }
      .joined(separator: ", ")
    return "\(name) \(String(rendered.prefix(120)))"
  }
}

// MARK: - Tool root

/// Resolves a model-supplied path against a tool's root directory. Relative paths land
/// inside the root; absolute paths pass through (the model is trusted within the run —
/// the root exists for isolation between parallel candidates, not as a sandbox).
func resolveToolPath(_ path: String, root: URL?) -> String {
  guard let root, !path.hasPrefix("/") else { return path }
  if path == "." || path.isEmpty { return root.path }
  return root.appendingPathComponent(path).path
}

// MARK: - Built-in tools

public struct ReadFileTool: AgentTool {
  public let name = "read_file"
  public let description = "Read a file and return its contents with line numbers."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": ["path": ["type": "string", "description": "File path"]],
    "required": ["path"],
  ]

  private let root: URL?

  public init(root: URL? = nil) { self.root = root }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let path = arguments["path"]?.stringValue.map({ resolveToolPath($0, root: root) }) else {
      return "error: missing 'path'"
    }
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return "error: cannot read \(path)"
    }
    return content.split(separator: "\n", omittingEmptySubsequences: false)
      .enumerated()
      .map { "\($0.offset + 1)\t\($0.element)" }
      .joined(separator: "\n")
  }
}

public struct WriteFileTool: AgentTool {
  public let name = "write_file"
  public let description = "Write content to a file, replacing it if it exists."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "path": ["type": "string"],
      "content": ["type": "string"],
    ],
    "required": ["path", "content"],
  ]

  private let root: URL?

  public init(root: URL? = nil) { self.root = root }

  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "?"
    let bytes = arguments["content"]?.stringValue?.utf8.count ?? 0
    return "write_file \(path) (\(bytes) bytes)"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard
      let path = arguments["path"]?.stringValue.map({ resolveToolPath($0, root: root) }),
      let content = arguments["content"]?.stringValue
    else {
      return "error: missing 'path' or 'content'"
    }
    try FileManager.default.createDirectory(
      at: URL(fileURLWithPath: path).deletingLastPathComponent(),
      withIntermediateDirectories: true)
    try content.write(toFile: path, atomically: true, encoding: .utf8)
    return "wrote \(content.utf8.count) bytes to \(path)"
  }
}

public struct BashTool: AgentTool {
  public let name = "bash"
  public let description = "Run a shell command and return stdout+stderr (truncated to 20000 chars)."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": ["command": ["type": "string"]],
    "required": ["command"],
  ]

  private let root: URL?

  public init(root: URL? = nil) { self.root = root }

  public func summary(arguments: [String: JSONValue]) -> String {
    // The command is shown verbatim — that's the whole point of the permission prompt.
    "bash: \(arguments["command"]?.stringValue ?? "?")"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let command = arguments["command"]?.stringValue else {
      return "error: missing 'command'"
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
    if let root { process.currentDirectoryURL = root }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    let truncated = output.count > 20000 ? String(output.prefix(20000)) + "\n[truncated]" : output
    return "exit \(process.terminationStatus)\n\(truncated)"
  }
}
