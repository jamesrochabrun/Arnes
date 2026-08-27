import ArgumentParser
import ArnesKit
import Foundation

/// `arnes skills` — list the skills the agent loop would load from the current
/// directory: name, description, and which directory each one came from.
struct Skills: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List skills loaded from .arnes/skills, .claude/skills, and ~/.arnes/skills.")

  func run() async throws {
    let skills = SkillLibrary.discover()
    guard !skills.isEmpty else {
      print("no skills found — add <name>/SKILL.md under .arnes/skills, .claude/skills, or ~/.arnes/skills")
      return
    }
    let home = NSHomeDirectory()
    for skill in skills {
      let path = skill.directory.path
      let shown = path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
      print(ANSI.bold(skill.name))
      if !skill.description.isEmpty { print("  \(skill.description)") }
      print(ANSI.dim("  \(shown)"))
    }
    print(ANSI.dim("\n\(skills.count) skill\(skills.count == 1 ? "" : "s") — the model loads one with the skill tool; /skills lists them in the REPL"))
  }
}
