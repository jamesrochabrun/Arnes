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
  func execute(arguments: [String: JSONValue]) async throws -> String
}

extension AgentTool {
  /// The OpenRouter chat tool definition for this tool.
  public var toolDefinition: Tool {
    .function(name: name, description: description, parameters: parameters)
  }
}

// MARK: - Built-in tools

public struct ReadFileTool: AgentTool {
  public let name = "read_file"
  public let description = "Read a file and return its contents with line numbers."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": ["path": ["type": "string", "description": "File path"]],
    "required": ["path"],
  ]

  public init() { }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let path = arguments["path"]?.stringValue else {
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

  public init() { }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let path = arguments["path"]?.stringValue, let content = arguments["content"]?.stringValue else {
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

  public init() { }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let command = arguments["command"]?.stringValue else {
      return "error: missing 'command'"
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-lc", command]
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
