import Foundation
import OpenRouterSwift

// MARK: - PermissionMode

/// How freely tools run before any per-call rule or prompt — Claude Code's permission
/// modes / Codex's approval policy, as one dial.
public enum PermissionMode: String, Codable, Sendable, CaseIterable {
  /// Gated tools prompt (or follow the rules file). The out-of-the-box behavior.
  case `default`
  /// In-tree file edits (`write_file`/`edit_file` inside the working root) run without a
  /// prompt; everything else still gates. `.sensitive` calls always prompt.
  case acceptEdits
  /// Read-only: every gated tool is denied, so the agent can plan and read but change
  /// nothing. The propose-before-execute posture.
  case plan
  /// Approve every gated call without asking (headless `--yes`). `.sensitive` calls are
  /// still surfaced and the catastrophic floor still refuses, but nothing prompts.
  case bypass

  public var label: String { rawValue }
}

// MARK: - PermissionRule

/// One allow/ask/deny entry, in the Claude Code spelling: a bare tool name (`bash`,
/// `write_file`, `mcp__server__tool`), an `mcp__server__*` wildcard, or a parenthesized
/// matcher — `Bash(git commit:*)`, `Read(~/.ssh/**)`, `Edit(src/**)`, `Write(**)`.
public struct PermissionRule: Sendable, Equatable {
  public enum Matcher: Sendable, Equatable {
    /// Any call to this tool (bare name, exact).
    case tool(String)
    /// MCP tools of a server: `mcp__server__*`.
    case mcpServer(String)
    /// A `bash` command whose every segment starts with this prefix.
    case bashPrefix(String)
    /// A path-taking tool (`read_file`/`write_file`/`edit_file`/`grep`/`glob`) whose path
    /// argument matches this gitignore-style glob.
    case path(tools: Set<String>, glob: String)
  }

  public let raw: String
  public let matcher: Matcher

  public init?(_ raw: String) {
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    self.raw = trimmed
    // Parenthesized form: Name(argument).
    if let open = trimmed.firstIndex(of: "("), trimmed.hasSuffix(")") {
      let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
      let inner = String(trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)])
        .trimmingCharacters(in: .whitespaces)
      switch name.lowercased() {
      case "bash":
        // `Bash(git commit:*)` / `Bash(npm run *)` — trailing `:*` or `*` means prefix.
        var prefix = inner
        if prefix.hasSuffix(":*") { prefix.removeLast(2) }
        else if prefix.hasSuffix("*") { prefix.removeLast() }
        matcher = .bashPrefix(prefix.trimmingCharacters(in: .whitespaces))
      case "read": matcher = .path(tools: ["read_file", "grep", "glob", "view_image"], glob: inner)
      case "edit": matcher = .path(tools: ["edit_file", "write_file"], glob: inner)
      case "write": matcher = .path(tools: ["write_file"], glob: inner)
      case "grep": matcher = .path(tools: ["grep"], glob: inner)
      case "glob": matcher = .path(tools: ["glob"], glob: inner)
      default: return nil
      }
      return
    }
    // Bare tool name or an mcp wildcard.
    if trimmed.hasPrefix("mcp__"), trimmed.hasSuffix("__*") {
      matcher = .mcpServer(String(trimmed.dropFirst(5).dropLast(3)))
    } else {
      matcher = .tool(trimmed)
    }
  }

  /// Does this rule match a specific call? `bashSegments` is the split-and-stripped list
  /// of command segments (only used for `bashPrefix`). `matchAll` decides the bash
  /// semantics: an allow rule requires EVERY segment to start with the prefix (so
  /// `git diff; rm -rf /` isn't allowed by `Bash(git diff:*)`); a deny/ask rule fires on
  /// ANY segment.
  public func matches(
    tool: String,
    arguments: [String: JSONValue],
    root: URL?,
    bashSegments: [String],
    matchAll: Bool)
    -> Bool
  {
    switch matcher {
    case .tool(let name):
      return name == tool
    case .mcpServer(let server):
      return tool.hasPrefix("mcp__\(server)__")
    case .bashPrefix(let prefix):
      guard tool == "bash" else { return false }
      guard !bashSegments.isEmpty else { return false }
      let hit: (String) -> Bool = { $0 == prefix || $0.hasPrefix(prefix.isEmpty ? "" : prefix) }
      return matchAll ? bashSegments.allSatisfy(hit) : bashSegments.contains(where: hit)
    case .path(let tools, let glob):
      guard tools.contains(tool) else { return false }
      guard let path = (arguments["path"]?.stringValue) else { return false }
      return GlobMatch.matches(glob: glob, path: path, root: root)
    }
  }
}

// MARK: - PermissionRules

/// The allow/ask/deny lists — `~/.arnes/rules.json`, layered over a trusted project's
/// `<cwd>/.arnes/rules.json` (a project may tighten with `deny`/`ask`, but its `allow`
/// entries are ignored: a cloned repo must not be able to pre-approve its own commands).
public struct PermissionRules: Codable, Sendable, Equatable {
  public var deny: [String]
  public var ask: [String]
  public var allow: [String]

  public init(deny: [String] = [], ask: [String] = [], allow: [String] = []) {
    self.deny = deny
    self.ask = ask
    self.allow = allow
  }

  public static let empty = PermissionRules()
  public var isEmpty: Bool { deny.isEmpty && ask.isEmpty && allow.isEmpty }

  enum CodingKeys: String, CodingKey { case deny, ask, allow }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    deny = try c.decodeIfPresent([String].self, forKey: .deny) ?? []
    ask = try c.decodeIfPresent([String].self, forKey: .ask) ?? []
    allow = try c.decodeIfPresent([String].self, forKey: .allow) ?? []
  }

  public static var defaultURL: URL {
    if let override = ProcessInfo.processInfo.environment["ARNES_RULES_CONFIG"], !override.isEmpty {
      return URL(fileURLWithPath: override)
    }
    return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/rules.json")
  }

  /// Loads the user-global rules, or nil when the file doesn't exist. Throws on malformed
  /// JSON so a typo surfaces instead of silently dropping a guardrail.
  public static func load(from url: URL = defaultURL) throws -> PermissionRules? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    return try JSONDecoder().decode(PermissionRules.self, from: Data(contentsOf: url))
  }

  /// User-global rules, plus a trusted project's `deny`/`ask` (never its `allow`). Returns
  /// the merged rules and whether any project `allow` entries were dropped (so the CLI can
  /// warn). `projectRules` is nil in an untrusted directory.
  public static func merged(user: PermissionRules?, project: PermissionRules?)
    -> (rules: PermissionRules, droppedProjectAllows: Int)
  {
    var merged = user ?? .empty
    var dropped = 0
    if let project {
      merged.deny += project.deny
      merged.ask += project.ask
      dropped = project.allow.count
    }
    return (merged, dropped)
  }
}

// MARK: - PermissionRuleSet

/// Parsed, ready-to-consult rules. deny wins, then ask (forces a prompt / `.sensitive`),
/// then allow (skips the prompt). Unmatched calls fall through to the mode + delegate.
public struct PermissionRuleSet: Sendable {
  public enum Outcome: Sendable, Equatable { case deny, ask, allow, unset }

  let denyRules: [PermissionRule]
  let askRules: [PermissionRule]
  let allowRules: [PermissionRule]

  public init(_ rules: PermissionRules) {
    denyRules = rules.deny.compactMap(PermissionRule.init)
    askRules = rules.ask.compactMap(PermissionRule.init)
    allowRules = rules.allow.compactMap(PermissionRule.init)
  }

  public var isEmpty: Bool { denyRules.isEmpty && askRules.isEmpty && allowRules.isEmpty }

  /// The rule outcome for one call. deny (any segment) → ask (any segment) → allow (every
  /// segment must match) → unset.
  public func outcome(tool: String, arguments: [String: JSONValue], root: URL?) -> Outcome {
    let segments = tool == "bash"
      ? PermissionRuleSet.bashSegments(arguments["command"]?.stringValue ?? "")
      : []
    if denyRules.contains(where: { $0.matches(tool: tool, arguments: arguments, root: root, bashSegments: segments, matchAll: false) }) {
      return .deny
    }
    if askRules.contains(where: { $0.matches(tool: tool, arguments: arguments, root: root, bashSegments: segments, matchAll: false) }) {
      return .ask
    }
    if allowRules.contains(where: { $0.matches(tool: tool, arguments: arguments, root: root, bashSegments: segments, matchAll: true) }) {
      return .allow
    }
    return .unset
  }

  /// Splits a bash command into segments and strips leading wrappers (`env VAR=x`,
  /// `sudo`, `timeout 5`, `nice`, `nohup`) so a prefix rule matches the real program.
  /// The splitter lives in `ShellCommand` — the same one that generates session grants,
  /// so a grant and the matcher that reads it always agree.
  static func bashSegments(_ command: String) -> [String] {
    ShellCommand.segments(command)
  }
}

// MARK: - SessionGrantSet

/// The standing grants a session accumulates when the user answers "always this session".
///
/// They are *patterns in the rules-file spelling*, not tool names: answering "always" to
/// `git commit -m x` grants `Bash(git commit *)`, not "every bash command forever". They
/// are matched with exactly the same matcher (and the same every-segment-must-match
/// semantics) as the `allow` list, and `/permissions save` appends them verbatim to
/// `~/.arnes/rules.json`.
public struct SessionGrantSet: Sendable {
  /// The raw patterns, in the order they were granted.
  public private(set) var patterns: [String] = []
  private var rules: [PermissionRule] = []

  public init(_ patterns: [String] = []) {
    for pattern in patterns { insert(pattern) }
  }

  public var isEmpty: Bool { patterns.isEmpty }

  /// Adds a pattern (ignoring duplicates and anything that doesn't parse).
  public mutating func insert(_ pattern: String) {
    guard !patterns.contains(pattern), let rule = PermissionRule(pattern) else { return }
    patterns.append(pattern)
    rules.append(rule)
  }

  /// Does a standing grant cover this call? `allow` semantics: for `bash`, *every* segment
  /// must match the pattern, so a grant earned by `npm test` never covers
  /// `npm test && rm -rf build`.
  public func allows(tool: String, arguments: [String: JSONValue], root: URL?) -> Bool {
    guard !rules.isEmpty else { return false }
    let segments = tool == "bash"
      ? ShellCommand.segments(arguments["command"]?.stringValue ?? "")
      : []
    return rules.contains {
      $0.matches(tool: tool, arguments: arguments, root: root, bashSegments: segments, matchAll: true)
    }
  }
}

// MARK: - SessionGrants

/// The one grant store a lead session and its subagents share: a `SessionGrantSet` behind a
/// lock, referenced (not copied) by `Session.Configuration.grants` and carried by
/// `forSubagent` — so "always this session" answered on a nested prompt covers the lead and
/// the sibling agents too, and `/permissions show`/`save` on the lead see every grant the
/// human made, wherever the question was asked. Session-scoped like the set it wraps: a new
/// run builds a new store, nothing here is persisted.
///
/// Sharing widens nothing: a grant is the human's own standing answer (like an allow rule),
/// the matcher and its every-segment semantics are `SessionGrantSet`'s, a read-only posture
/// (`DenyMutationsPermissions`) still refuses pre-approved calls, and `plan` mode is checked
/// before any grant is consulted.
public final class SessionGrants: @unchecked Sendable {
  private let lock = NSLock()
  private var set: SessionGrantSet

  public init(_ patterns: [String] = []) {
    set = SessionGrantSet(patterns)
  }

  /// Adds a pattern (ignoring duplicates and anything that doesn't parse).
  public func insert(_ pattern: String) {
    lock.withLock { set.insert(pattern) }
  }

  /// Does a standing grant cover this call? `SessionGrantSet.allows` semantics.
  public func allows(tool: String, arguments: [String: JSONValue], root: URL?) -> Bool {
    lock.withLock { set.allows(tool: tool, arguments: arguments, root: root) }
  }

  /// The raw patterns, in the order they were granted.
  public var patterns: [String] { lock.withLock { set.patterns } }

  public var isEmpty: Bool { lock.withLock { set.isEmpty } }
}

// MARK: - Persisting grants

extension PermissionRules {
  /// Appends `patterns` to the rules file's `allow` list (`/permissions save`), creating
  /// the file when it doesn't exist. Written atomically and owner-only via `SecureFiles`,
  /// and existing entries are preserved — this is an append, not a rewrite of the user's
  /// guardrails. Returns the patterns actually added (duplicates are skipped).
  @discardableResult
  public static func appendAllowRules(_ patterns: [String], to url: URL = defaultURL) throws -> [String] {
    // Malformed JSON throws rather than being replaced: a typo in the file must not cost
    // the user their deny list.
    var rules = try load(from: url) ?? .empty
    var added: [String] = []
    for pattern in patterns where !rules.allow.contains(pattern) && PermissionRule(pattern) != nil {
      rules.allow.append(pattern)
      added.append(pattern)
    }
    guard !added.isEmpty else { return [] }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    var data = try encoder.encode(rules)
    data.append(Data("\n".utf8))
    try SecureFiles.writePrivate(data, to: url)
    return added
  }
}

// MARK: - GlobMatch

/// gitignore-style path matching for the `Read/Edit/Write(glob)` rules. `**` crosses
/// directory separators, `*`/`?` don't; a leading `//` anchors to filesystem root, `~/`
/// to home, anything else is matched against both the working-root-relative path and the
/// resolved absolute path.
public enum GlobMatch {
  public static func matches(glob: String, path: String, root: URL?) -> Bool {
    let resolved = PathScope.physicalPath(resolveToolPath(path, root: root))
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path

    var pattern = glob
    if pattern.hasPrefix("~/") {
      pattern = home + "/" + String(pattern.dropFirst(2))
    } else if pattern.hasPrefix("//") {
      pattern = "/" + String(pattern.dropFirst(2))
    }

    // An absolute (or home/root-anchored) pattern matches the resolved absolute path.
    if pattern.hasPrefix("/") {
      return fnmatchGlob(pattern, resolved)
    }
    // A relative pattern matches the working-root-relative path (and the basename).
    let base = (root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
      .standardizedFileURL.resolvingSymlinksInPath().path
    let prefix = base == "/" ? "/" : base + "/"
    let relative = resolved.hasPrefix(prefix) ? String(resolved.dropFirst(prefix.count)) : resolved
    let basename = (relative as NSString).lastPathComponent
    return fnmatchGlob(pattern, relative) || fnmatchGlob(pattern, basename)
  }

  /// Matches a gitignore-style glob against a path by translating it to an anchored
  /// regex: `**` crosses `/`, `*` and `?` don't, everything else is a literal. A pattern
  /// with no slash also matches at any depth (gitignore semantics), which the caller
  /// already covers by trying the basename.
  static func fnmatchGlob(_ pattern: String, _ path: String) -> Bool {
    guard let regex = Self.regex(for: pattern) else { return false }
    let range = NSRange(path.startIndex..., in: path)
    return regex.firstMatch(in: path, range: range) != nil
  }

  private static let regexCacheLock = NSLock()
  private static var regexCache: [String: NSRegularExpression] = [:]

  static func regex(for pattern: String) -> NSRegularExpression? {
    regexCacheLock.lock(); defer { regexCacheLock.unlock() }
    if let cached = regexCache[pattern] { return cached }
    var out = "^"
    let scalars = Array(pattern)
    var i = 0
    while i < scalars.count {
      let c = scalars[i]
      switch c {
      case "*":
        if i + 1 < scalars.count, scalars[i + 1] == "*" {
          out += ".*" // ** crosses directory separators
          i += 2
          if i < scalars.count, scalars[i] == "/" { i += 1 } // absorb the slash after **/
          continue
        }
        out += "[^/]*"
      case "?":
        out += "[^/]"
      case ".", "(", ")", "+", "|", "^", "$", "{", "}", "[", "]", "\\":
        out += "\\\(c)"
      default:
        out.append(c)
      }
      i += 1
    }
    out += "$"
    let regex = try? NSRegularExpression(pattern: out)
    if let regex { regexCache[pattern] = regex }
    return regex
  }
}
