import Foundation

/// Bounded extraction of compiler, typechecker and test failures from observed bash output.
/// This runs no commands, reads no files and makes no independent correctness judgment.
/// The original exit line/output remain authoritative and remain in the tool result.
public struct CommandDiagnostics: Codable, Sendable, Equatable {
  public struct Finding: Codable, Sendable, Equatable {
    public let severity: String
    public let message: String
    public let path: String?
    public let line: Int?
    public let column: Int?
  }
  public let status: String
  public let exitCode: Int?
  public let findings: [Finding]
  public let scanTruncated: Bool
  public let findingsTruncated: Bool
  enum CodingKeys: String, CodingKey {
    case status, findings
    case exitCode = "exit_code"
    case scanTruncated = "scan_truncated"
    case findingsTruncated = "findings_truncated"
  }

  private static let location = try! NSRegularExpression(
    pattern: #"^(.+?):(\d+):(?:(\d+):)?\s*(fatal error|error|warning|note):\s*(.*)$"#)
  private static let typescript = try! NSRegularExpression(
    pattern: #"^(.+)\((\d+),(\d+)\):\s*(error|warning)\s+([^:]+):\s*(.*)$"#)
  private static let standalone = try! NSRegularExpression(
    pattern: #"^(error|warning)(?:\[[^\]]+\])?:\s*(.+)$"#)
  private static let lint = try! NSRegularExpression(
    pattern: #"^(.+?):(\d+):(\d+):\s*([A-Z]+\d+)\s+(.+)$"#)
  private static let ansi = try! NSRegularExpression(pattern: "\u{001B}\\[[0-?]*[ -/]*[@-~]")

  public static func parse(_ output: String) -> CommandDiagnostics? {
    let header = output.prefix(300).split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    let exitCode = header.hasPrefix("exit ") ? Int(header.dropFirst(5)) : nil
    let status: String
    if header.hasPrefix("error: command timed out") { status = "timed_out" }
    else if header == "[interrupted by user]" { status = "cancelled" }
    else if let exitCode { status = exitCode == 0 ? "command_succeeded" : exitCode == 127 ? "command_unavailable" : "command_failed" }
    else { return nil } // A refused/unstarted/background call is not a completed command.

    // Inspect both ends: many test runners print their actionable failures at the tail.
    var truncated = output.utf8.count > 96_000
    let scanned = truncated ? String(decoding: output.utf8.prefix(48_000), as: UTF8.self)
      + "\n" + String(decoding: output.utf8.suffix(48_000), as: UTF8.self) : output
    var findings: [Finding] = []
    var seen: Set<String> = []
    var findingsTruncated = false
    for raw in scanned.split(separator: "\n") {
      if raw.count > 2_000 { truncated = true }
      let text = String(raw.prefix(2_000))
      let clean = ansi.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
      func groups(_ expression: NSRegularExpression) -> [String]? {
        guard let match = expression.firstMatch(in: clean, range: NSRange(clean.startIndex..., in: clean)) else { return nil }
        return (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: clean).map { String(clean[$0]) } ?? "" }
      }
      let finding: Finding
      if let fields = groups(location) {
        finding = Finding(severity: fields[4], message: String(fields[5].prefix(240)),
          path: String(fields[1].prefix(300)), line: Int(fields[2]), column: Int(fields[3]))
      } else if let fields = groups(typescript) {
        finding = Finding(severity: fields[4], message: String((fields[5] + ": " + fields[6]).prefix(240)),
          path: String(fields[1].prefix(300)), line: Int(fields[2]), column: Int(fields[3]))
      } else if let fields = groups(lint) {
        finding = Finding(severity: "lint", message: String((fields[4] + ": " + fields[5]).prefix(240)),
          path: String(fields[1].prefix(300)), line: Int(fields[2]), column: Int(fields[3]))
      } else if clean.hasPrefix("FAILED ") || clean.hasPrefix("FAIL: ") {
        finding = Finding(severity: "test_failure", message: String(clean.prefix(240)), path: nil, line: nil, column: nil)
      } else if let fields = groups(standalone), !clean.hasPrefix("error: command timed out") {
        finding = Finding(severity: fields[1], message: String(fields[2].prefix(240)), path: nil, line: nil, column: nil)
      } else { continue }
      guard seen.insert(clean).inserted else { continue }
      if findings.count == 12 { findingsTruncated = true; break }
      findings.append(finding)
    }
    return CommandDiagnostics(status: status, exitCode: exitCode, findings: findings,
      scanTruncated: truncated, findingsTruncated: findingsTruncated)
  }

  public var section: String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(self) else { return "" }
    return "\n\n[command diagnostics — extracted output, not a task verdict]\n"
      + String(decoding: data, as: UTF8.self)
  }
}
