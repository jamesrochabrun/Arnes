import Foundation

/// Which working directories may load their own `.arnes/` and `.claude/` skills and
/// agents.
///
/// Those files put text into the model's system prompt, define subagent system prompts,
/// and choose subagent models — so a freshly cloned repository controls all of that the
/// moment `arnes` runs inside it. Like Claude Code's folder trust, the decision is made
/// once per directory (the REPL asks; headless runs never guess) and remembered in
/// `~/.arnes/trusted.json`. Global definitions under `~/.arnes/` are the user's own and
/// never need trusting.
public struct ProjectTrustStore: Sendable {
  public let url: URL
  /// The user's home directory — the boundary the trust walk never crosses and the one
  /// directory (with its ancestors and `/`) that can never be trusted. Injected for tests.
  public let home: URL

  public init(
    url: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/trusted.json"),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()))
  {
    self.url = url
    self.home = home
  }

  /// Whether `directory` is trusted — itself, or through an ancestor (`trustingDirectory(for:)`).
  public func isTrusted(_ directory: URL) -> Bool {
    trustingDirectory(for: directory) != nil
  }

  /// The trusted directory `directory` is covered by: itself when listed, else the nearest
  /// listed ancestor **up to the repository root** — the first ancestor (the directory itself
  /// included) that contains a `.git` entry ends the walk after it is checked, so a trusted
  /// repository trusts its subdirectories and never its neighbors. `$HOME`, its ancestors and
  /// `/` end the walk too and are never a match even when listed: a trusted home would trust
  /// every project on the machine. nil when nothing covers it.
  public func trustingDirectory(for directory: URL) -> String? {
    let listed = Set(load().directories)
    guard !listed.isEmpty else { return nil }
    var current = Self.key(for: directory)
    while true {
      if isRoot(current) { return nil }
      if listed.contains(current) { return current }
      if FileManager.default.fileExists(atPath: (current as NSString).appendingPathComponent(".git")) {
        return nil
      }
      let parent = (current as NSString).deletingLastPathComponent
      guard !parent.isEmpty, parent != current else { return nil }
      current = parent
    }
  }

  /// Records `directory` as trusted. Refuses `$HOME`, any ancestor of it, and `/`
  /// (`ProjectTrustError.refusedRoot`): trust is per project, and those are every project.
  public func trust(_ directory: URL) throws {
    let key = Self.key(for: directory)
    if isRoot(key) { throw ProjectTrustError.refusedRoot(key) }
    var file = load()
    guard !file.directories.contains(key) else { return }
    file.directories.append(key)
    try save(file)
  }

  /// `/`, `$HOME`, or an ancestor of `$HOME` — never trusted, never a match.
  private func isRoot(_ key: String) -> Bool {
    let homeKey = Self.key(for: home)
    return key == "/" || key == homeKey || homeKey.hasPrefix(key.hasSuffix("/") ? key : key + "/")
  }

  public func forget(_ directory: URL) throws {
    var file = load()
    let key = Self.key(for: directory)
    file.directories.removeAll { $0 == key }
    // Forgetting a directory forgets what its hooks were allowed to be, too: re-trusting it
    // later must not silently re-arm commands approved in another life.
    file.hookHashes.removeValue(forKey: key)
    try save(file)
  }

  /// Every trusted directory, as stored (resolved absolute paths), sorted.
  public func all() -> [String] {
    load().directories.sorted()
  }

  // MARK: Hook fingerprints

  /// The hook fingerprints the user approved for `directory` (`arnes hooks trust`). A
  /// project hook whose fingerprint isn't here does not run — trusting a directory's
  /// *content* is a separate, coarser decision from trusting the *commands* it runs.
  public func trustedHookHashes(for directory: URL) -> Set<String> {
    Set(load().hookHashes[Self.key(for: directory)] ?? [])
  }

  /// Records exactly `hashes` as the approved hook set for `directory`, replacing whatever
  /// was there — a hook removed from the file stops being approved.
  public func trustHooks(_ hashes: [String], in directory: URL) throws {
    var file = load()
    let key = Self.key(for: directory)
    if hashes.isEmpty {
      file.hookHashes.removeValue(forKey: key)
    } else {
      file.hookHashes[key] = hashes.sorted()
    }
    try save(file)
  }

  // MARK: MCP tool pins

  /// The tool definitions recorded for an MCP server at first sight (`MCPToolPins`): remote
  /// tool name → `MCPToolInfo.fingerprint`. Empty for a server never connected with pins.
  public func pinnedMCPTools(for server: String) -> [String: String] {
    load().mcpToolHashes[server] ?? [:]
  }

  /// Records exactly `hashes` as the server's approved tool set, replacing what was there
  /// (`arnes mcp --approve`, and the provider's first-sight pin).
  public func pinMCPTools(_ hashes: [String: String], for server: String) throws {
    var file = load()
    if hashes.isEmpty {
      file.mcpToolHashes.removeValue(forKey: server)
    } else {
      file.mcpToolHashes[server] = hashes
    }
    try save(file)
  }

  /// Drops a server's pins — its tools are pinned afresh at the next connect.
  public func forgetMCPTools(for server: String) throws {
    var file = load()
    file.mcpToolHashes.removeValue(forKey: server)
    try save(file)
  }

  /// Every server with pins, sorted.
  public func pinnedMCPServers() -> [String] {
    load().mcpToolHashes.keys.sorted()
  }

  /// Directories are compared by resolved absolute path, so `.`, symlinks, and trailing
  /// slashes all name the same trust decision.
  static func key(for directory: URL) -> String {
    directory.standardizedFileURL.resolvingSymlinksInPath().path
  }

  /// `hookHashes` arrived after `directories` and `mcpToolHashes` after both, so each decodes
  /// if present — a `trusted.json` written by an older build must keep working.
  private struct File: Codable {
    var directories: [String] = []
    var hookHashes: [String: [String]] = [:]
    var mcpToolHashes: [String: [String: String]] = [:]

    init() {}

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      directories = try container.decodeIfPresent([String].self, forKey: .directories) ?? []
      hookHashes = try container.decodeIfPresent([String: [String]].self, forKey: .hookHashes) ?? [:]
      mcpToolHashes = try container.decodeIfPresent([String: [String: String]].self, forKey: .mcpToolHashes) ?? [:]
    }
  }

  private func load() -> File {
    guard let data = try? Data(contentsOf: url),
          let file = try? JSONDecoder().decode(File.self, from: data)
    else { return File() }
    return file
  }

  private func save(_ file: File) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try SecureFiles.writePrivate(try encoder.encode(file), to: url)
  }
}

extension ProjectTrustStore: MCPToolPins {
  public func pinned(for server: String) -> [String: String] { pinnedMCPTools(for: server) }
  public func pin(_ hashes: [String: String], for server: String) throws { try pinMCPTools(hashes, for: server) }
}

// MARK: - ProjectTrustError

public enum ProjectTrustError: Error, Sendable, Equatable, CustomStringConvertible {
  /// `trust` was asked for `/`, the home directory or an ancestor of it.
  case refusedRoot(String)

  public var description: String {
    switch self {
    case .refusedRoot(let path):
      return "refusing to trust \(path): the home directory, its ancestors and / would trust every "
        + "project on this machine — run `arnes trust` inside the project instead"
    }
  }
}

// MARK: - ProjectContent

/// What a working directory contributes of its own — the files a trust decision is about.
///
/// Skills and agents put text in the system prompt and define subagents; an instruction
/// file (`AGENTS.md`, `CLAUDE.md`, and their variants) *is* system-prompt text; and a
/// `.arnes/hooks.json` runs shell commands around every tool call. So a repository that
/// ships nothing but a `CLAUDE.md` still needs the same yes/no, and one that ships hooks
/// needs it twice over — trusting the directory is only the first half, `arnes hooks trust`
/// is the second.
public struct ProjectContent: Sendable, Equatable {
  public let skills: [Skill]
  public let agents: [AgentDefinition]
  public let instructions: [ProjectInstructions.Source]
  public let hooks: [HookDefinition]
  /// The servers the repository's `.mcp.json` declares (X9) — names and transports only; loaded
  /// as `trust: untrusted` once the directory is trusted, never before.
  public let mcpServers: [MCPServerSummary]

  public init(
    skills: [Skill] = [],
    agents: [AgentDefinition] = [],
    instructions: [ProjectInstructions.Source] = [],
    hooks: [HookDefinition] = [],
    mcpServers: [MCPServerSummary] = [])
  {
    self.skills = skills
    self.agents = agents
    self.instructions = instructions
    self.hooks = hooks
    self.mcpServers = mcpServers
  }

  public var isEmpty: Bool {
    skills.isEmpty && agents.isEmpty && instructions.isEmpty && hooks.isEmpty && mcpServers.isEmpty
  }

  public static func discover(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    instructionOptions: ProjectInstructions.Options = .default)
    -> ProjectContent
  {
    ProjectContent(
      skills: SkillLibrary.projectSkills(workdir: workdir),
      agents: AgentLibrary.projectAgents(workdir: workdir),
      instructions: ProjectInstructions.projectSources(
        workdir: workdir, home: home, options: instructionOptions),
      hooks: HookConfig.projectHooks(in: workdir),
      mcpServers: MCPConfig.projectServers(in: workdir, options: instructionOptions))
  }

  /// "2 skills and 1 agent and 1 instruction file" — the phrase a trust prompt is built
  /// around. Plain text; the CLI does the styling.
  public func describe() -> String {
    var parts: [String] = []
    if !skills.isEmpty { parts.append("\(skills.count) skill\(skills.count == 1 ? "" : "s")") }
    if !agents.isEmpty { parts.append("\(agents.count) agent\(agents.count == 1 ? "" : "s")") }
    if !instructions.isEmpty {
      parts.append("\(instructions.count) instruction file\(instructions.count == 1 ? "" : "s")")
    }
    if !hooks.isEmpty { parts.append("\(hooks.count) hook\(hooks.count == 1 ? "" : "s")") }
    if !mcpServers.isEmpty { parts.append("\(mcpServers.count) MCP server\(mcpServers.count == 1 ? "" : "s")") }
    return parts.joined(separator: " and ")
  }
}
