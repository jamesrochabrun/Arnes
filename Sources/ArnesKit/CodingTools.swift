import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - EditFileTool

/// Targeted in-place edits — the tool that makes an agent good at code without
/// rewriting whole files. Schema stays dumb: path + exact old/new strings.
public struct EditFileTool: AgentTool {
  public let name = "edit_file"
  public let description =
    "Replace an exact string in a file. old_string must appear exactly once; include enough surrounding context to make it unique."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "path": ["type": "string"],
      "old_string": ["type": "string"],
      "new_string": ["type": "string"],
    ],
    "required": ["path", "old_string", "new_string"],
  ]

  public init() { }

  public func summary(arguments: [String: JSONValue]) -> String {
    let path = arguments["path"]?.stringValue ?? "?"
    let oldCount = arguments["old_string"]?.stringValue?.count ?? 0
    let newCount = arguments["new_string"]?.stringValue?.count ?? 0
    return "edit_file \(path) (replace \(oldCount) chars with \(newCount) chars)"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard
      let path = arguments["path"]?.stringValue,
      let oldString = arguments["old_string"]?.stringValue,
      let newString = arguments["new_string"]?.stringValue
    else {
      return "error: missing 'path', 'old_string', or 'new_string'"
    }
    guard !oldString.isEmpty else {
      return "error: old_string is empty — use write_file to create a new file"
    }
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
      return "error: cannot read \(path)"
    }
    // Error strings coach the model toward a fix, not just report failure.
    let occurrences = content.components(separatedBy: oldString).count - 1
    if occurrences == 0 {
      return "error: old_string not found in \(path) — re-read the file and copy the exact text"
    }
    if occurrences > 1 {
      return "error: old_string appears \(occurrences) times in \(path) — include more surrounding context to make it unique"
    }
    guard let range = content.range(of: oldString) else {
      return "error: old_string not found in \(path) — re-read the file and copy the exact text"
    }
    let updated = content.replacingCharacters(in: range, with: newString)
    do {
      try updated.write(toFile: path, atomically: true, encoding: .utf8)
    } catch {
      return "error: cannot write \(path): \(error)"
    }
    return "edited \(path): replaced \(oldString.utf8.count) bytes with \(newString.utf8.count) bytes"
  }
}

// MARK: - GrepTool

/// Recursive regex search. Pure Swift (no shelling out) is what lets this be honestly
/// `.readOnly` and run without a permission prompt.
public struct GrepTool: AgentTool {
  public let name = "grep"
  public let description =
    "Search files recursively for a regex pattern. Returns path:line:text matches. Optional path defaults to the current directory."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "pattern": ["type": "string", "description": "Regular expression"],
      "path": ["type": "string", "description": "File or directory to search (default: .)"],
    ],
    "required": ["pattern"],
  ]

  private static let maxMatches = 200
  private static let maxOutputChars = 10_000
  private static let maxFileBytes = 2_000_000

  public init() { }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let pattern = arguments["pattern"]?.stringValue else {
      return "error: missing 'pattern'"
    }
    let root = arguments["path"]?.stringValue ?? "."
    let regex: NSRegularExpression
    do {
      regex = try NSRegularExpression(pattern: pattern)
    } catch {
      return "error: invalid regex: \(error.localizedDescription)"
    }

    var matches: [String] = []
    var truncated = false
    for file in Self.files(under: root) {
      guard
        let data = FileManager.default.contents(atPath: file),
        data.count <= Self.maxFileBytes,
        !data.prefix(1024).contains(0),
        let content = String(data: data, encoding: .utf8)
      else {
        continue
      }
      for (number, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
        let text = String(line)
        let range = NSRange(text.startIndex..., in: text)
        guard regex.firstMatch(in: text, range: range) != nil else { continue }
        matches.append("\(file):\(number + 1):\(String(text.prefix(200)))")
        if matches.count >= Self.maxMatches {
          truncated = true
          break
        }
      }
      if truncated { break }
    }

    guard !matches.isEmpty else {
      return "no matches for /\(pattern)/ under \(root)"
    }
    var output = matches.joined(separator: "\n")
    if output.count > Self.maxOutputChars {
      output = String(output.prefix(Self.maxOutputChars))
      truncated = true
    }
    return truncated ? output + "\n[truncated]" : output
  }

  /// Regular files under `root` (or `root` itself when it is a file), skipping
  /// hidden entries like `.git`.
  static func files(under root: String) -> [String] {
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root, isDirectory: &isDirectory) else {
      return []
    }
    guard isDirectory.boolValue else {
      return [root]
    }
    let rootURL = URL(fileURLWithPath: root)
    guard let enumerator = FileManager.default.enumerator(
      at: rootURL,
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles])
    else {
      return []
    }
    var files: [String] = []
    for case let url as URL in enumerator {
      guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
        continue
      }
      files.append(url.path)
      if files.count >= 20_000 { break }
    }
    return files.sorted()
  }
}

// MARK: - GlobTool

/// File discovery by pattern. Matches the relative path (where `*` crosses directory
/// separators, so `*.swift` finds nested files) and the basename.
public struct GlobTool: AgentTool {
  public let name = "glob"
  public let description =
    "List files matching a glob pattern like *.swift or Sources/*/main.swift. Optional path defaults to the current directory."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "pattern": ["type": "string", "description": "Glob pattern"],
      "path": ["type": "string", "description": "Directory to search (default: .)"],
    ],
    "required": ["pattern"],
  ]

  private static let maxResults = 500

  public init() { }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let pattern = arguments["pattern"]?.stringValue else {
      return "error: missing 'pattern'"
    }
    let root = arguments["path"]?.stringValue ?? "."
    let prefix = root.hasSuffix("/") ? root : root + "/"
    var results: [String] = []
    for file in GrepTool.files(under: root) {
      let relative = file.hasPrefix(prefix) ? String(file.dropFirst(prefix.count)) : file
      let basename = (relative as NSString).lastPathComponent
      if fnmatch(pattern, relative, 0) == 0 || fnmatch(pattern, basename, 0) == 0 {
        results.append(relative)
        if results.count >= Self.maxResults { break }
      }
    }
    guard !results.isEmpty else {
      return "no files matching \(pattern) under \(root)"
    }
    let truncated = results.count >= Self.maxResults
    return results.joined(separator: "\n") + (truncated ? "\n[truncated]" : "")
  }
}
