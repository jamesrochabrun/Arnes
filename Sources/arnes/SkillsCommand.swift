import ArgumentParser
import ArnesKit
import Foundation

/// `arnes skills` — list the skills the agent loop would load from the current
/// directory: name, description, the frontmatter it parsed but does not apply
/// (`allowed-tools`, `model`), any warning, and which directory each one came from.
struct Skills: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List skills loaded from .arnes/skills, .claude/skills, ~/.arnes/skills, and ~/.claude/skills.")

  @Flag(help: "Print one JSON array of {name, description, source, directory, allowed_tools, model, warnings, builtin} rows instead of text.")
  var json = false

  func run() async throws {
    let skills = SkillLibrary.discover()
    if json {
      try JSONOut.print(skills.map(SkillRow.init))
      return
    }
    guard !skills.isEmpty else {
      print("no skills found — add <name>/SKILL.md under .arnes/skills, .claude/skills, ~/.arnes/skills, or ~/.claude/skills")
      return
    }
    let home = NSHomeDirectory()
    for skill in skills {
      for line in SkillsFormat.rows(for: skill, home: home) { print(line) }
    }
    print(ANSI.dim("\n\(skills.count) skill\(skills.count == 1 ? "" : "s") — the model loads one with the skill tool; /skills lists them in the REPL"))
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if !SkillLibrary.projectSkills(workdir: cwd).isEmpty, !ProjectTrustStore().isTrusted(cwd) {
      print(ANSI.yellow("this directory's own skills load only once it is trusted — `arnes trust` here, or --trust-project"))
    }
  }
}

/// How one skill reads in `arnes skills`. Skill files are project content — every string
/// is terminal-sanitized.
enum SkillsFormat {
  /// Name · description · one dim line per parsed-not-applied fact · one yellow line per
  /// warning · the source directory (`~`-abbreviated, or `built-in`).
  static func rows(for skill: Skill, home: String) -> [String] {
    var rows = [ANSI.bold(TerminalText.sanitize(skill.name))]
    if !skill.description.isEmpty { rows.append(TerminalText.sanitize("  \(skill.description)")) }
    for fact in skill.listingFacts { rows.append(ANSI.dim(TerminalText.sanitize("  \(fact)"))) }
    for warning in skill.warnings { rows.append(ANSI.yellow(TerminalText.sanitize("  ⚠ \(warning)"))) }
    let path = skill.sourceDescription
    let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    rows.append(ANSI.dim("  \(shown)"))
    return rows
  }
}
