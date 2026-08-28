import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

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

  /// Commands may not finish on their own (waiting on stdin, hung network calls), and
  /// the user must always be able to Esc out — so the wait is async, observes task
  /// cancellation (SIGTERM, then SIGKILL for stubborn processes), and gives up after
  /// `timeoutSeconds` rather than wedging the turn.
  static let timeoutSeconds: TimeInterval = 120

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
    // No terminal: commands that would sit reading stdin fail fast instead of
    // hanging (and can't steal keystrokes from the REPL's raw-mode reader).
    process.standardInput = FileHandle.nullDevice
    try process.run()
    // Drain the pipe off-task — waiting for exit first would deadlock once a chatty
    // command fills the pipe's buffer.
    let reader = Task.detached { pipe.fileHandleForReading.readDataToEndOfFile() }
    let outcome = await Self.waitForExit(process)
    let output = String(decoding: await reader.value, as: UTF8.self)
    let truncated = output.count > 20000 ? String(output.prefix(20000)) + "\n[truncated]" : output
    switch outcome {
    case .exited:
      return "exit \(process.terminationStatus)\n\(truncated)"
    case .timedOut:
      return "error: killed after \(Int(Self.timeoutSeconds))s timeout\n\(truncated)"
    case .cancelled:
      return "error: interrupted by user — process killed\n\(truncated)"
    }
  }

  private enum ExitOutcome: Sendable { case exited, timedOut, cancelled }

  private static func waitForExit(_ process: Process) async -> ExitOutcome {
    let state = ExitState()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<ExitOutcome, Never>) in
        // The termination handler is the single resume point; the timeout and
        // cancellation paths only flag the reason and signal the process.
        process.terminationHandler = { _ in
          if state.claimResume() {
            continuation.resume(returning: state.takeOutcome())
          }
        }
        state.arm(process: process, timeout: timeoutSeconds)
        // The process may have exited before the handler was installed.
        if !process.isRunning, state.claimResume() {
          continuation.resume(returning: state.takeOutcome())
        }
      }
    } onCancel: {
      state.killProcess(process, as: .cancelled)
    }
  }

  /// Lock-guarded reason + single-resume bookkeeping shared between the termination
  /// handler, the timeout timer, and the cancellation handler.
  private final class ExitState: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: ExitOutcome = .exited
    private var resumed = false
    private var timer: DispatchWorkItem?

    func arm(process: Process, timeout: TimeInterval) {
      let work = DispatchWorkItem { [weak self] in
        self?.killProcess(process, as: .timedOut)
      }
      lock.lock()
      timer = work
      lock.unlock()
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
    }

    func killProcess(_ process: Process, as reason: ExitOutcome) {
      lock.lock()
      if outcome == .exited { outcome = reason }
      lock.unlock()
      process.terminate()
      // SIGTERM can be ignored; escalate so the turn is guaranteed to come back.
      let pid = process.processIdentifier
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
        if process.isRunning { _ = kill(pid, SIGKILL) }
      }
    }

    /// True exactly once — every resume path must claim before resuming.
    func claimResume() -> Bool {
      lock.lock()
      defer { lock.unlock() }
      guard !resumed else { return false }
      resumed = true
      return true
    }

    func takeOutcome() -> ExitOutcome {
      lock.lock()
      defer { lock.unlock() }
      timer?.cancel()
      timer = nil
      return outcome
    }
  }
}
