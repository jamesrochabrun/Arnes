import Foundation

/// Per-family system-prompt adapters — the tunable half of Arnes.
///
/// A pack is a markdown file describing how to talk to one model family: tool-calling
/// idioms, preferred edit style, verbosity. Packs resolve in order:
/// 1. `~/.arnes/packs/<family>.md` (user override — iterate without recompiling)
/// 2. the built-in default below
///
/// The core task framing lives in `basePrompt` and is family-independent.
public struct PromptPack: Sendable {
  public let family: ModelFamily
  public let text: String

  static let basePrompt = """
    You are Arnes, a coding agent. You complete the user's task using the tools provided.

    Rules:
    - Use tools to inspect before you modify. Never guess file contents.
    - Use grep and glob to locate code, and read_file before editing it.
    - Prefer edit_file for small, targeted changes; use write_file only to create \
    new files or fully rewrite one.
    - Make the smallest change that completes the task.
    - When the task is done, reply with a short summary of what changed and why.
    - If the task is impossible or unsafe, say so instead of improvising.
    """

  static let familyDefaults: [ModelFamily: String] = [
    .anthropic: """
      Work step by step. Think before each tool call. Prefer precise, minimal diffs.
      """,
    .openai: """
      Call tools with exact JSON arguments. Prefer rewriting whole functions over \
      fragile partial edits. Keep answers terse.
      """,
    .xai: """
      Call one tool at a time and wait for its result. Verify your edit by re-reading \
      the file before declaring the task done.
      """,
  ]

  public static func load(
    for family: ModelFamily,
    overridesDirectory: URL = URL(fileURLWithPath: NSHomeDirectory())
      .appendingPathComponent(".arnes/packs"))
    -> PromptPack
  {
    let overrideURL = overridesDirectory.appendingPathComponent("\(family.rawValue).md")
    if let override = try? String(contentsOf: overrideURL, encoding: .utf8) {
      return PromptPack(family: family, text: basePrompt + "\n\n" + override)
    }
    let familyText = familyDefaults[family] ?? ""
    let text = familyText.isEmpty ? basePrompt : basePrompt + "\n\n" + familyText
    return PromptPack(family: family, text: text)
  }
}
