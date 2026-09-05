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
  /// The skill's directory — supporting files referenced by the body live here. Nil for a
  /// built-in, which has no files on disk (`BuiltinSkills`).
  public let directory: URL?
  /// Claude Code's `allowed-tools` frontmatter, canonicalized to arnes tool names with any
  /// specifier kept (`Read, Bash(git:*)` → `read_file`, `bash(git:*)`). **Parsed and shown,
  /// not applied**: a skill file is a repository's, and granting tools from it would widen
  /// permissions — narrow-never-widen forbids that without a design of its own.
  public let allowedTools: [String]?
  /// `model:` frontmatter — the model a `/name` turn runs on: the REPL swaps the session onto
  /// it for that turn and back afterwards (a name the manifest can't resolve leaves the turn on
  /// the current model). A `skill` tool call never changes the model. `inherit` reads as unset.
  public let model: String?
  /// Problems found while parsing the frontmatter — a malformed `allowed-tools` entry, a
  /// name a skill cannot grant. Surfaced by `arnes skills` instead of swallowed; a bad value
  /// never drops the skill.
  public let warnings: [String]

  public init(
    name: String,
    description: String,
    body: String,
    directory: URL?,
    allowedTools: [String]? = nil,
    model: String? = nil,
    warnings: [String] = [])
  {
    self.name = name
    self.description = description
    self.body = body
    self.directory = directory
    self.allowedTools = allowedTools
    self.model = model
    self.warnings = warnings
  }

  /// Where supporting files live, for a listing: the directory, or "built-in".
  public var sourceDescription: String { directory?.path ?? "built-in" }

  /// The frontmatter facts a listing shows beyond name and description, each saying whether
  /// it is applied — a user reading `allowed-tools: bash(git:*)` must not think the skill
  /// granted anything, while `model:` does steer a `/name` turn. Empty for a skill that
  /// declares neither.
  public var listingFacts: [String] {
    var facts: [String] = []
    if let allowedTools {
      facts.append("allowed-tools: \(allowedTools.joined(separator: ", ")) (parsed, not applied)")
    }
    if let model {
      facts.append("model: \(model) (applied to /\(name) turns in the REPL)")
    }
    return facts
  }

  /// One line pointing the model at the skill's supporting files, empty for a built-in.
  var supportingFilesNote: String {
    guard let directory else { return "" }
    return "\nSupporting files it mentions live in \(directory.path) — read them with "
      + "read_file if the instructions call for them.\n"
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
      \(supportingFilesNote)
      \(text)
      """
  }
}

// MARK: - BuiltinSkills

/// Skills that exist with no files installed, appended by discovery and shadowable by a
/// `SKILL.md` of the same name in any root — the same deal built-in subagents get.
public enum BuiltinSkills {
  /// `/init` — draft (or refresh) this repository's own `AGENTS.md`. Every harness ships
  /// this one because the instruction file is what makes every *later* session cheaper:
  /// the commands and conventions stop being re-derived from scratch each time.
  public static let initInstructions = Skill(
    name: "init",
    description:
      "Write or refresh this repository's AGENTS.md — build/test commands, layout map, "
      + "conventions. Run it once per repo so later sessions start informed.",
    body: """
      Write this repository's `AGENTS.md`: the standing instructions every future session \
      here will read.

      1. **Inspect before writing.** Use glob/grep/read_file on the README and `docs/`, the \
         build and package manifests (`Package.swift`, `package.json`, `Cargo.toml`, \
         `pyproject.toml`, `Makefile`, `justfile`), the CI workflows, and any instructions \
         that already exist (`AGENTS.md`, `CLAUDE.md`, `.cursor/rules/`, \
         `.github/copilot-instructions.md`, `CONTRIBUTING.md`). Trust what the repo *does* \
         over what it says — read the CI job to learn the real test command.
      2. **Then write `AGENTS.md` at the repo root, at most 100 lines**, covering only:
         - how to build, test, lint, and run a *single* test — exact commands, each one \
           taken from a manifest, script, or CI file rather than guessed;
         - a short map of the layout: the handful of directories that matter and what lives \
           in each;
         - conventions a newcomer would get wrong — formatting, naming, error handling, \
           architectural rules the code actually follows;
         - pointers, by path, to the docs worth reading.
      3. **Leave out** anything `ls` would tell you, generic advice ("write tests", "use \
         clear names"), and anything you did not verify in the repo.
      4. If an `AGENTS.md` or `CLAUDE.md` already exists, improve it in place instead of \
         replacing it: keep what is still true, fix what is stale, and say what you changed.

      Finish by reporting the path you wrote and the commands you verified.
      """,
    directory: nil)

  /// Appended by discovery when no skill file shadows their name.
  public static let all: [Skill] = [initInstructions]
}

// MARK: - SkillLibrary

/// Discovers skills from disk. Search order (first occurrence of a name wins, so a
/// project can shadow a global skill — and any file can shadow a built-in):
/// 1. `<workdir>/.arnes/skills/`
/// 2. `<workdir>/.claude/skills/`   (ecosystem compatibility — same SKILL.md format)
/// 3. `~/.arnes/skills/`
/// 4. `~/.claude/skills/`           (the user's Claude Code skills, drop-in; an Arnes one
///                                   of the same name shadows it)
/// 5. `BuiltinSkills.all` (appended last)
///
/// The user-global roots (3, 4) are the user's own and load without a trust prompt, as
/// `~/.arnes` always has; only the project roots are gated.
public enum SkillLibrary {
  /// - Parameter includeProject: load the working directory's own `.arnes/skills` and
  ///   `.claude/skills`. The CLI passes false until the directory is trusted
  ///   (`ProjectTrustStore`) — those files come from whoever wrote the repository.
  public static func discover(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    includeProject: Bool = true)
    -> [Skill]
  {
    let roots = (includeProject ? projectRoots(workdir: workdir) : []) + userRoots(home: home)
    var skills = discover(roots: roots)
    let seen = Set(skills.map(\.name))
    for builtin in BuiltinSkills.all where !seen.contains(builtin.name) {
      skills.append(builtin)
    }
    return skills
  }

  /// The project-local skill roots, in precedence order.
  public static func projectRoots(workdir: URL) -> [URL] {
    [workdir.appendingPathComponent(".arnes/skills"), workdir.appendingPathComponent(".claude/skills")]
  }

  /// The user-global skill roots, in precedence order: `~/.arnes/skills` first, then the
  /// Claude Code directory, so an Arnes-specific file shadows a same-named drop-in.
  public static func userRoots(home: URL) -> [URL] {
    [home.appendingPathComponent(".arnes/skills"), home.appendingPathComponent(".claude/skills")]
  }

  /// Only the working directory's own skills — what a trust prompt describes.
  public static func projectSkills(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    -> [Skill]
  {
    discover(roots: projectRoots(workdir: workdir))
  }

  static func discover(roots: [URL]) -> [Skill] {
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
  /// Frontmatter parsing is a deliberate subset of YAML — the shapes SKILL.md files use in
  /// practice, nothing more (`frontmatterEntries`): `key: value` pairs between `---` fences,
  /// keys at column 0 and matched case-insensitively; a block scalar (`description: >` or
  /// `|`, chomping `-`/`+` accepted) folded into one line from the indented lines under it,
  /// since every key here is a one-liner — a description is a listing entry, not a document;
  /// a sequence (`- item` lines) for `allowed-tools`. An indented line is never a key, so a
  /// `Model: …` sentence inside a folded description stays description text. `allowed-tools`
  /// and `model` are parsed into the skill (and shown by `arnes skills`) but not applied; a
  /// malformed value lands in `warnings`, never drops the skill.
  public static func load(directory: URL) -> Skill? {
    let url = directory.appendingPathComponent("SKILL.md")
    guard let raw = try? String(contentsOf: url, encoding: .utf8),
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    var name = directory.lastPathComponent
    var description = ""
    var allowedTools: [String]?
    var model: String?
    var warnings: [String] = []
    var body = raw

    let lines = raw.components(separatedBy: "\n")
    if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
       let close = lines.dropFirst().firstIndex(where: {
         $0.trimmingCharacters(in: .whitespaces) == "---"
       })
    {
      for entry in frontmatterEntries(Array(lines[1..<close])) {
        let value = entry.value
        switch entry.key.lowercased() {
        case "name": if !value.isEmpty { name = value }
        case "description": description = value
        case "allowed-tools", "allowedtools", "allowed_tools":
          let parsed = entry.items.map { parseAllowedTools(entries: $0) } ?? parseAllowedTools(value)
          if !parsed.tools.isEmpty { allowedTools = parsed.tools }
          warnings += parsed.warnings
        case "model":
          // `inherit` (Claude Code's spelling for "same as the session") is the default.
          if !value.isEmpty, value.lowercased() != "inherit" { model = value }
        default: break
        }
      }
      body = lines[(close + 1)...].joined(separator: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !body.isEmpty else { return nil }
    return Skill(
      name: name, description: description, body: body, directory: directory,
      allowedTools: allowedTools, model: model, warnings: warnings)
  }

  /// One resolved frontmatter entry: `value` is the scalar (quotes stripped, a block scalar
  /// or a multi-line plain scalar folded into one line), `items` the entries of a `- item`
  /// sequence when the key had one instead of a value.
  struct FrontmatterEntry: Equatable {
    let key: String
    let value: String
    let items: [String]?
  }

  /// The YAML subset SKILL.md frontmatter uses, resolved line by line. A key is a
  /// `key: value` line at column 0; the indented lines under it (and `- item` lines at
  /// column 0, where YAML lets a sequence sit at its parent's indentation) belong to it and
  /// are never read as keys themselves. A value of `>`/`|` (optional `-`/`+`/indent
  /// indicator) folds the lines below into one space-separated line; an empty value over
  /// `- item` lines is a sequence; a plain value continued on indented lines is folded the
  /// same way; anything else indented under a key (a nested map) is consumed and ignored.
  static func frontmatterEntries(_ lines: [String]) -> [FrontmatterEntry] {
    // A column-0 `- item` continues a key only when that key had no value of its own — a
    // sequence cannot follow a scalar.
    func isContinuation(_ line: String, bareItems: Bool) -> Bool {
      guard let first = line.first else { return true }
      return first.isWhitespace || (bareItems && (line.hasPrefix("- ") || line == "-"))
    }
    func sequenceItem(_ line: String) -> String? {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard trimmed.hasPrefix("-") else { return nil }
      let rest = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
      return rest.isEmpty ? nil : unquote(rest)
    }

    var entries: [FrontmatterEntry] = []
    var index = 0
    while index < lines.count {
      let line = lines[index]
      index += 1
      guard let first = line.first, !first.isWhitespace, let colon = line.firstIndex(of: ":") else { continue }
      let key = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)

      var continuation: [String] = []
      while index < lines.count, isContinuation(lines[index], bareItems: value.isEmpty) {
        continuation.append(lines[index])
        index += 1
      }
      while continuation.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
        continuation.removeLast()
      }
      let folded = continuation.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }

      if isBlockScalarIndicator(value) {
        entries.append(FrontmatterEntry(key: key, value: folded.joined(separator: " "), items: nil))
      } else if value.isEmpty, !continuation.isEmpty {
        let items = continuation.compactMap(sequenceItem)
        // `- a` lines make a sequence; indented lines that aren't items are a nested map
        // this parser has no key for — consumed so none of its lines can pose as a key.
        entries.append(FrontmatterEntry(key: key, value: "", items: items.isEmpty ? nil : items))
      } else {
        let joined = ([value] + folded).joined(separator: " ")
        entries.append(FrontmatterEntry(key: key, value: unquote(joined), items: nil))
      }
    }
    return entries
  }

  /// `>` / `|` with YAML's optional chomping (`-`, `+`) and indentation (`1`–`9`) indicators.
  private static func isBlockScalarIndicator(_ value: String) -> Bool {
    value.wholeMatch(of: #/[|>](?:[1-9][+-]?|[+-][1-9]?)?/#) != nil
  }

  private static func unquote(_ value: String) -> String {
    guard value.count >= 2,
          (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
    else { return value }
    return String(value.dropFirst().dropLast())
  }

  /// Claude Code's `allowed-tools` list: entries separated by commas outside parentheses,
  /// each `Name` or `Name(specifier)`. The name goes through `AgentLibrary.canonicalToolName`
  /// (the same aliasing agent files get — `Read` → `read_file`, MCP ids verbatim) and the
  /// specifier is kept as written. An entry that names delegation (`Task`, which maps to no
  /// tool a skill could grant), has unbalanced or stray parentheses or no name is dropped
  /// with a warning — the skill itself is kept.
  static func parseAllowedTools(_ value: String) -> (tools: [String], warnings: [String]) {
    parseAllowedTools(entries: splitOutsideParentheses(value))
  }

  /// The same over entries already split — a YAML sequence, one item per line.
  static func parseAllowedTools(entries: [String]) -> (tools: [String], warnings: [String]) {
    var tools: [String] = []
    var warnings: [String] = []
    for entry in entries {
      let trimmed = entry.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      guard let (name, specifier) = splitToolEntry(trimmed) else {
        warnings.append("allowed-tools entry '\(trimmed)' is malformed; dropped")
        continue
      }
      let canonical = AgentLibrary.canonicalToolName(name)
      guard !canonical.isEmpty else {
        warnings.append("allowed-tools names '\(name)', which a skill cannot grant (delegation is the session's); dropped")
        continue
      }
      tools.append(canonical + specifier)
    }
    return (tools, warnings)
  }

  /// `Name` or `Name(specifier)`: a non-empty name with no whitespace and no parenthesis,
  /// and — when present — one specifier group that opens right after the name and closes
  /// at the very end. So `Read)`, `Bash(a)b(c)`, `Broken(` and `(x)` are all malformed, not
  /// tool names.
  private static func splitToolEntry(_ entry: String) -> (name: String, specifier: String)? {
    guard let open = entry.firstIndex(of: "(") else {
      guard !entry.isEmpty, !entry.contains(")"), !entry.contains(where: \.isWhitespace) else { return nil }
      return (entry, "")
    }
    let name = entry[..<open].trimmingCharacters(in: .whitespaces)
    guard !name.isEmpty, !name.contains(")"), !name.contains(where: \.isWhitespace) else { return nil }
    let specifier = String(entry[open...])
    var depth = 0
    for (offset, character) in specifier.enumerated() {
      switch character {
      case "(": depth += 1
      case ")":
        depth -= 1
        // A group closing before the end (`Bash(a)b`) leaves text outside any specifier.
        if depth < 0 || (depth == 0 && offset != specifier.count - 1) { return nil }
      default: break
      }
    }
    guard depth == 0 else { return nil }
    return (name, specifier)
  }

  /// Splits on commas, keeping a comma inside a balanced specifier with its entry — so
  /// `Bash(git add:*), Bash(git status:*)` is two entries and `Bash(git commit -m a,b:*)` one.
  /// An entry whose parenthesis never closes is left alone as one (malformed) entry rather
  /// than swallowing everything after it: the rest of the list still parses.
  private static func splitOutsideParentheses(_ value: String) -> [String] {
    func imbalance(_ text: String) -> Int {
      text.filter { $0 == "(" }.count - text.filter { $0 == ")" }.count
    }
    let pieces = value.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    var entries: [String] = []
    var index = 0
    while index < pieces.count {
      var entry = pieces[index]
      var last = index
      if imbalance(entry) > 0 {
        var candidate = entry
        var probe = index + 1
        while probe < pieces.count, imbalance(candidate) > 0 {
          candidate += "," + pieces[probe]
          probe += 1
        }
        if imbalance(candidate) == 0 {
          entry = candidate
          last = probe - 1
        }
      }
      entries.append(entry)
      index = last + 1
    }
    return entries
  }
}

// MARK: - SkillTool

/// The one tool skills add to the loop. Schema stays dumb — a single `name` string — so
/// non-frontier models survive it; everything task-specific lives in the skill text.
public struct SkillTool: AgentTool, PromptContributing {
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
  /// How much of the system prompt the listing may take (bytes of the entry lines; the fixed
  /// framing is not counted). A user with Claude Code installed has `~/.claude/skills` on the
  /// discovery path — dozens of skills whose descriptions alone ran to ~4k tokens of every
  /// request — so past this the remaining skills are listed by name only (the model can still
  /// call them; `arnes skills` shows every description). 0 = names only for all.
  public let listingMaxBytes: Int

  /// ~1.5k tokens: room for a dozen fully described skills. Config: `policies.skillListingBytes`.
  public static let defaultListingMaxBytes = 6144
  /// A description longer than this is clipped in the listing (never in the `skill` result).
  public static let descriptionClipChars = 200

  public init(skills: [Skill], listingMaxBytes: Int = defaultListingMaxBytes) {
    self.skills = skills
    self.listingMaxBytes = max(0, listingMaxBytes)
  }

  /// The system-prompt section listing available skills — names + descriptions only.
  /// Empty when no skills are installed so the base prompt stays untouched. Discovery order
  /// is kept (project skills first, then the user's, then built-ins), so a project's own skills
  /// are the ones described in full when the cap cuts the list.
  public var promptSection: String {
    guard !skills.isEmpty else { return "" }
    let (described, namesOnly) = Self.split(skills, maxBytes: listingMaxBytes)
    var listing = described.map(Self.entry).joined(separator: "\n")
    if !namesOnly.isEmpty {
      let names = namesOnly.map(\.name).joined(separator: ", ")
      let tail = "Also available (descriptions omitted to save space; call the skill tool with "
        + "the exact name, or run `arnes skills`): \(names)"
      listing = listing.isEmpty ? tail : listing + "\n\n" + tail
    }
    return """
      # Skills

      Skills are instructions for specific kinds of tasks. Before starting a task that \
      matches one, call the skill tool with its name and follow the instructions it returns.

      \(listing)
      """
  }

  /// One listing line: `- name: description`, the description clipped to
  /// `descriptionClipChars` (a listing entry is a pointer, not the instructions).
  static func entry(_ skill: Skill) -> String {
    guard !skill.description.isEmpty else { return "- \(skill.name)" }
    let description = skill.description.count > descriptionClipChars
      ? String(skill.description.prefix(descriptionClipChars)) + "…"
      : skill.description
    return "- \(skill.name): \(description)"
  }

  /// The skills whose full entry fits under `maxBytes` (in order, stopping at the first that
  /// doesn't — a later short one is not pulled ahead, so the order stays what discovery said)
  /// and the rest, listed by name only.
  static func split(_ skills: [Skill], maxBytes: Int) -> (described: [Skill], namesOnly: [Skill]) {
    var used = 0
    var described: [Skill] = []
    for (index, skill) in skills.enumerated() {
      let bytes = entry(skill).utf8.count + (index == 0 ? 0 : 1)
      guard used + bytes <= maxBytes else {
        return (described, Array(skills[index...]))
      }
      used += bytes
      described.append(skill)
    }
    return (described, [])
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
      \(skill.supportingFilesNote)
      \(skill.body)
      """
  }
}
