import Foundation
import OpenRouterSwift

// MARK: - Skill

/// A skill: a directory holding a `SKILL.md` with YAML frontmatter (`name`, `description`)
/// followed by markdown instructions, in the same format the wider agent-skills ecosystem
/// uses — skills written for other harnesses drop in unchanged.
///
/// Progressive disclosure keeps this cheap for small models: only name + description ride
/// the system prompt; the body enters context when the model asks for it through the
/// `skill` tool, and supporting files in the skill's directory are read on demand.
public struct Skill: Sendable, Equatable {
  public let name: String
  public let description: String
  public let body: String
  /// The skill's directory — supporting files referenced by the body live here.
  public let directory: URL

  public init(name: String, description: String, body: String, directory: URL) {
    self.name = name
    self.description = description
    self.body = body
    self.directory = directory
  }

  /// The user-turn text for an explicit `/name args` invocation, following the
  /// convention Claude Code and Codex established: `$ARGUMENTS` is replaced by the whole
  /// argument string, `$1`–`$9` by whitespace-split positionals (empty when absent), and
  /// when the body has no placeholders the arguments are appended instead.
  public func invocationPrompt(arguments: String?) -> String {
    let args = (arguments ?? "").trimmingCharacters(in: .whitespaces)
    let positional = args.split(whereSeparator: \.isWhitespace).map(String.init)
    var usedPlaceholder = false
    var text = body.replacing(#/\$(ARGUMENTS|[1-9])(?![0-9])/#) { match in
      usedPlaceholder = true
      let token = String(match.output.1)
      guard let index = Int(token) else { return args }
      return index <= positional.count ? positional[index - 1] : ""
    }
    if !usedPlaceholder, !args.isEmpty {
      text += "\n\nArguments: \(args)"
    }
    return """
      The user invoked skill '\(name)'. Follow these instructions for this turn.
      Supporting files it mentions live in \(directory.path) — read them with read_file \
      if the instructions call for them.

      \(text)
      """
  }
}

// MARK: - SkillLibrary

/// Discovers skills from disk. Search order (first occurrence of a name wins, so a
/// project can shadow a global skill):
/// 1. `<workdir>/.arnes/skills/`
/// 2. `<workdir>/.claude/skills/`   (ecosystem compatibility — same SKILL.md format)
/// 3. `~/.arnes/skills/`
public enum SkillLibrary {
  public static func discover(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()))
    -> [Skill]
  {
    let roots = [
      workdir.appendingPathComponent(".arnes/skills"),
      workdir.appendingPathComponent(".claude/skills"),
      home.appendingPathComponent(".arnes/skills"),
    ]
    var skills: [Skill] = []
    var seen = Set<String>()
    for root in roots {
      guard let entries = try? FileManager.default.contentsOfDirectory(
        at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
      else { continue }
      for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        guard let skill = load(directory: entry), !seen.contains(skill.name) else { continue }
        seen.insert(skill.name)
        skills.append(skill)
      }
    }
    return skills
  }

  /// Parses `<directory>/SKILL.md`. Returns nil when the file is missing or empty.
  /// Frontmatter parsing is a deliberate subset of YAML: single-line `key: value` pairs
  /// between `---` fences — the only shape SKILL.md files use in practice.
  public static func load(directory: URL) -> Skill? {
    let url = directory.appendingPathComponent("SKILL.md")
    guard let raw = try? String(contentsOf: url, encoding: .utf8),
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    var name = directory.lastPathComponent
    var description = ""
    var body = raw

    let lines = raw.components(separatedBy: "\n")
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
       let close = lines.dropFirst().firstIndex(where: {
         $0.trimmingCharacters(in: .whitespaces) == "---"
       })
    {
      for line in lines[1..<close] {
        guard let colon = line.firstIndex(of: ":") else { continue }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
           (value.hasPrefix("'") && value.hasSuffix("'"))
        {
          value = String(value.dropFirst().dropLast())
        }
        switch key {
        case "name": if !value.isEmpty { name = value }
        case "description": description = value
        default: break
        }
      }
      body = lines[(close + 1)...].joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !body.isEmpty else { return nil }
    return Skill(name: name, description: description, body: body, directory: directory)
  }
}

// MARK: - SkillTool

/// The one tool skills add to the loop. Schema stays dumb — a single `name` string — so
/// non-frontier models survive it; everything task-specific lives in the skill text.
public struct SkillTool: AgentTool {
  public let name = "skill"
  public let description =
    "Load a skill: expert instructions for a specific kind of task. "
    + "Pass the skill name exactly as listed in the system prompt."
  public let permission = ToolPermission.readOnly
  public let parameters: JSONValue = [
    "type": "object",
    "properties": ["name": ["type": "string", "description": "Skill name from the list"]],
    "required": ["name"],
  ]

  public let skills: [Skill]

  public init(skills: [Skill]) { self.skills = skills }

  /// The system-prompt section listing available skills — names + descriptions only.
  /// Empty when no skills are installed so the base prompt stays untouched.
  public var promptSection: String {
    guard !skills.isEmpty else { return "" }
    let listing = skills
      .map { "- \($0.name)\($0.description.isEmpty ? "" : ": \($0.description)")" }
      .joined(separator: "\n")
    return """
      # Skills

      Skills are instructions for specific kinds of tasks. Before starting a task that \
      matches one, call the skill tool with its name and follow the instructions it returns.

      \(listing)
      """
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    "skill: \(arguments["name"]?.stringValue ?? "?")"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let requested = arguments["name"]?.stringValue else {
      return "error: missing 'name'"
    }
    guard let skill = skills.first(where: { $0.name == requested }) else {
      let available = skills.map(\.name).joined(separator: ", ")
      return "error: no skill named '\(requested)'. Available: \(available.isEmpty ? "none" : available)"
    }
    return """
      Skill '\(skill.name)' loaded. Follow these instructions for the current task.
      Supporting files it mentions live in \(skill.directory.path) — read them with \
      read_file if the instructions call for them.

      \(skill.body)
      """
  }
}
