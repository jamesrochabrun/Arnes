import Foundation

/// Discovers standing repo instructions — `AGENTS.md` / `CLAUDE.md`, their `.override`
/// and `.local` variants — and folds them into the system prompt as durable project
/// context. This is the cross-tool convention (Claude Code's `CLAUDE.md`, Codex's
/// `AGENTS.md`): a non-frontier run gets the repo's conventions and commands without the
/// user re-explaining them each session.
///
/// Precedence follows the ecosystem: global `~/.arnes` first, then each directory from the
/// repo root down to the working directory (nearer = more specific, placed later so it
/// carries the most weight). Within one directory the *first* `fallbackFilenames` entry
/// that exists is the primary file, and every `localFilenames` entry that exists is
/// appended after it — so `AGENTS.override.md` shadows the committed `AGENTS.md`, while an
/// untracked `AGENTS.local.md` adds to whichever won.
///
/// Project files are loaded only when the directory is trusted (`includeProject`), exactly
/// like project skills and agents — the text lands in the system prompt, so an untrusted
/// repo shouldn't get to write it silently.
public enum ProjectInstructions {
  /// How far up the tree to look for a repo root before giving up.
  static let maxDepth = 40

  // MARK: - Options

  /// What counts as an instruction file and how much of it may load. Defaults match the
  /// ecosystem; `~/.arnes/config.json`'s `instructions` block overrides them
  /// (`InstructionsConfig`).
  public struct Options: Sendable, Equatable {
    /// Checked per directory in order — the first that exists is that directory's primary
    /// file. `AGENTS.override.md` leads so a checkout can override the committed file
    /// without editing it.
    public var fallbackFilenames: [String]
    /// Checked per directory *in addition to* the primary file: every one that exists is
    /// rendered after it. The untracked personal layer (`AGENTS.local.md`).
    public var localFilenames: [String]
    /// Total budget for all instruction text combined, imported bytes included. Protects
    /// the context window from a runaway file; the tail is truncated with a marker.
    public var maxBytes: Int
    /// Expand `@path` imports (see `ImportResolver`).
    public var imports: Bool
    /// Names that mark a repository root when walking up from the working directory.
    public var rootMarkers: [String]

    public init(
      fallbackFilenames: [String] = ["AGENTS.override.md", "AGENTS.md", "CLAUDE.md"],
      localFilenames: [String] = ["AGENTS.local.md", "CLAUDE.local.md"],
      maxBytes: Int = 32_768,
      imports: Bool = true,
      rootMarkers: [String] = [".git"])
    {
      self.fallbackFilenames = fallbackFilenames
      self.localFilenames = localFilenames
      self.maxBytes = maxBytes
      self.imports = imports
      self.rootMarkers = rootMarkers
    }

    public static let `default` = Options()

    /// Options from the config file, each field falling back to the default when absent.
    public init(config: InstructionsConfig?) {
      let fallback = Options.default
      self.init(
        fallbackFilenames: config?.fallbackFilenames?.filter { !$0.isEmpty } ?? fallback.fallbackFilenames,
        localFilenames: config?.localFilenames?.filter { !$0.isEmpty } ?? fallback.localFilenames,
        maxBytes: config?.maxBytes.map { max(0, $0) } ?? fallback.maxBytes,
        imports: config?.imports ?? fallback.imports,
        rootMarkers: config?.rootMarkers?.filter { !$0.isEmpty } ?? fallback.rootMarkers)
    }
  }

  // MARK: - Source

  public struct Source: Equatable, Sendable {
    public let path: URL
    /// The file's text as it will ride the system prompt: HTML comments stripped,
    /// `@path` imports inlined, the compact-instructions section lifted out.
    public let text: String
    /// Files pulled in by `@path` imports, in the order they were inlined — so a banner or
    /// a trust prompt can name everything that actually reached the prompt.
    public let imports: [URL]
    /// This file's `## Compact instructions` section, removed from `text`.
    public let compactInstructions: String?

    public init(
      path: URL,
      text: String,
      imports: [URL] = [],
      compactInstructions: String? = nil)
    {
      self.path = path
      self.text = text
      self.imports = imports
      self.compactInstructions = compactInstructions
    }

    /// What this source contributes, for listings.
    public var byteCount: Int { text.utf8.count }
  }

  /// Everything discovery found: the rendered system-prompt block, the files behind it,
  /// and the standing "keep this across a compaction" note lifted out of them.
  public struct Discovered: Equatable, Sendable {
    public let text: String
    public let sources: [Source]
    /// Concatenated `## Compact instructions` sections — deliberately *not* part of `text`,
    /// so the compaction step can use them verbatim without them also being turn context.
    public let compactInstructions: String?
    /// Bytes of instruction text the `maxBytes` cap left out of `text` (0 = everything rode).
    /// A cut file is a silent failure — the model follows the half it got — so banners say so.
    public let omittedBytes: Int

    public init(text: String, sources: [Source], compactInstructions: String? = nil, omittedBytes: Int = 0) {
      self.text = text
      self.sources = sources
      self.compactInstructions = compactInstructions
      self.omittedBytes = omittedBytes
    }

    /// The user-facing note for a cut file, or nil when nothing was left out.
    public func truncationNotice(maxBytes: Int) -> String? {
      guard omittedBytes > 0 else { return nil }
      return "instruction files truncated: \(omittedBytes / 1024) KB over the \(maxBytes / 1024) KB cap "
        + "never reach the model — shorten the file (history belongs elsewhere) or raise "
        + "`instructions.maxBytes` in ~/.arnes/config.json"
    }
  }

  // MARK: - Discovery

  /// The full result: rendered block, sources, compact instructions. Nil when nothing was
  /// found.
  public static func discovered(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    includeProject: Bool = true,
    options: Options = .default)
    -> Discovered?
  {
    let found = sources(
      workdir: workdir, home: home, includeProject: includeProject, options: options)
    guard !found.isEmpty else { return nil }
    let compact = found.compactMap(\.compactInstructions).joined(separator: "\n\n")
    let rendered = rendered(found, maxBytes: options.maxBytes)
    return Discovered(
      text: rendered.text,
      sources: found,
      compactInstructions: compact.isEmpty ? nil : compact,
      omittedBytes: rendered.omittedBytes)
  }

  /// The combined instruction block for the system prompt, or nil when nothing was found.
  public static func discover(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    includeProject: Bool = true,
    options: Options = .default)
    -> String?
  {
    discovered(workdir: workdir, home: home, includeProject: includeProject, options: options)?.text
  }

  /// The sources that would load — for banners and listings.
  public static func sources(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    includeProject: Bool = true,
    options: Options = .default)
    -> [Source]
  {
    // A global file is the user's own, so it may import anything under their home.
    var found = load(
      directory: home.appendingPathComponent(".arnes"),
      options: options,
      allowedRoots: [home],
      home: home.path)
    if includeProject {
      found += projectSources(workdir: workdir, home: home, options: options)
    }
    var seen = Set<String>()
    return found.filter { seen.insert($0.path.standardizedFileURL.path).inserted }
  }

  /// Only the working directory's own instruction files — what a trust prompt is about
  /// (`ProjectContent`), mirroring `SkillLibrary.projectSkills`.
  public static func projectSources(
    workdir: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    options: Options = .default)
    -> [Source]
  {
    let chain = directoryChain(workdir: workdir, options: options)
    // A repo's file may only pull in the repo's own text (or the user's `~/.arnes`), so a
    // clone can't inline `~/.ssh/config` into the system prompt.
    let allowed = [chain.first ?? workdir.standardizedFileURL, home.appendingPathComponent(".arnes")]
    var found: [Source] = []
    for directory in chain {
      found += load(directory: directory, options: options, allowedRoots: allowed, home: home.path)
    }
    var seen = Set<String>()
    return found.filter { seen.insert($0.path.standardizedFileURL.path).inserted }
  }

  /// One directory's contribution: the first fallback name that exists, plus every local
  /// name that exists (additive, after it).
  static func load(
    directory: URL,
    options: Options,
    allowedRoots: [URL],
    home: String)
    -> [Source]
  {
    var found: [Source] = []
    for name in options.fallbackFilenames {
      if let source = read(
        directory.appendingPathComponent(name),
        options: options, allowedRoots: allowedRoots, home: home)
      {
        found.append(source)
        break
      }
    }
    for name in options.localFilenames {
      if let source = read(
        directory.appendingPathComponent(name),
        options: options, allowedRoots: allowedRoots, home: home)
      {
        found.append(source)
      }
    }
    return found
  }

  /// Reads one instruction file and prepares it for the prompt: HTML comments out,
  /// `@imports` in, compact-instructions section lifted. Nil when missing or blank.
  static func read(
    _ url: URL,
    options: Options,
    allowedRoots: [URL],
    home: String)
    -> Source?
  {
    guard let raw = try? String(contentsOf: url, encoding: .utf8),
          !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { return nil }

    var text = stripHTMLComments(raw)
    var imports: [URL] = []
    if options.imports {
      let expansion = ImportResolver.expand(
        text, base: url, allowedRoots: allowedRoots, maxBytes: options.maxBytes, home: home)
      text = expansion.text
      imports = expansion.imports
    }
    let split = splitCompactInstructions(text)
    guard !split.body.isEmpty || split.compact != nil else { return nil }
    return Source(
      path: url, text: split.body, imports: imports, compactInstructions: split.compact)
  }

  /// Directories from the repo root (nearest ancestor holding a root marker) down to
  /// `workdir`, inclusive. When there's no repo, just `workdir` itself.
  static func directoryChain(workdir: URL, options: Options = .default) -> [URL] {
    let start = workdir.standardizedFileURL
    var ancestors: [URL] = []
    var dir = start
    var repoRoot: URL?
    for _ in 0..<maxDepth {
      ancestors.append(dir)
      let marked = options.rootMarkers.contains {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent($0).path)
      }
      if marked {
        repoRoot = dir
        break
      }
      let parent = dir.deletingLastPathComponent()
      if parent.path == dir.path { break }
      dir = parent
    }
    guard repoRoot != nil else { return [start] }
    return ancestors.reversed()  // root … workdir
  }

  // MARK: - Rendering

  static func render(_ sources: [Source], maxBytes: Int = Options.default.maxBytes) -> String {
    rendered(sources, maxBytes: maxBytes).text
  }

  /// The block plus how many bytes of source text the cap left out — files skipped entirely
  /// once the budget is spent count too.
  static func rendered(_ sources: [Source], maxBytes: Int = Options.default.maxBytes)
    -> (text: String, omittedBytes: Int)
  {
    var body = "# Project instructions\n"
      + "Standing instructions for this repository (from AGENTS.md / CLAUDE.md and their "
      + "overrides). Follow them alongside the rules above; a more specific file lower in "
      + "the tree wins.\n"
    var used = 0
    var omitted = 0
    for source in sources {
      guard used < maxBytes else {
        omitted += source.text.utf8.count
        continue
      }
      var chunk = source.text
      if used + chunk.utf8.count > maxBytes {
        let kept = max(0, maxBytes - used)
        chunk = String(chunk.prefix(kept)) + "\n… [truncated]"
        omitted += source.text.utf8.count - kept
      }
      body += "\n## From \(abbreviate(source.path))\n" + chunk + "\n"
      used += chunk.utf8.count
    }
    return (body, omitted)
  }

  public static func abbreviate(_ url: URL) -> String {
    let home = NSHomeDirectory()
    return url.path.hasPrefix(home) ? "~" + url.path.dropFirst(home.count) : url.path
  }

  // MARK: - Text preparation

  /// Drops `<!-- … -->` spans, including multi-line ones. Instruction files use them to
  /// park notes for humans (and to comment out a stale rule); none of that should reach
  /// the model, and a commented-out `@import` must not fire. An unterminated comment eats
  /// the rest of the file, as a browser would.
  static func stripHTMLComments(_ text: String) -> String {
    guard text.contains("<!--") else { return text }
    var result = ""
    var rest = Substring(text)
    while let open = rest.range(of: "<!--") {
      result += rest[rest.startIndex..<open.lowerBound]
      guard let close = rest.range(of: "-->", range: open.upperBound..<rest.endIndex) else {
        return result
      }
      rest = rest[close.upperBound...]
    }
    result += rest
    return result
  }

  /// Splits out a `## Compact instructions` section (any heading level, case-insensitive):
  /// standing guidance about what to preserve across a context compaction, which is not
  /// turn-by-turn instruction and shouldn't sit in the system prompt. The section runs
  /// until the next heading at the same or a higher level.
  static func splitCompactInstructions(_ text: String) -> (body: String, compact: String?) {
    let split = splitSection(titled: "compact instructions", from: text)
    // An empty section is no compact guidance (the heading line is lifted out either way).
    return (split.body, split.section.flatMap { $0.isEmpty ? nil : $0 })
  }

  /// Lifts the section under a heading titled `title` (any level, case-insensitive, a
  /// trailing colon tolerated) out of a markdown text: the section runs until the next
  /// heading at the same or a higher level, fenced blocks are never headings. Returns the
  /// rest of the text and the section body, both trimmed; `section` is nil when the heading
  /// is absent and `""` when it is present with nothing under it — the heading line itself is
  /// never part of `body`, so a caller can tell "no such section" from "an empty one". Shared
  /// by the `## Compact instructions` split above and the prompt pack's `## Delegation`
  /// override (`PromptPack.load`).
  static func splitSection(titled title: String, from text: String) -> (body: String, section: String?) {
    var body: [String] = []
    var section: [String] = []
    var sectionLevel = 0  // 0 = outside the section
    var found = false
    var inFence = false
    for line in text.components(separatedBy: "\n") {
      if isFenceDelimiter(line) {
        inFence.toggle()
      } else if !inFence, let level = headingLevel(line) {
        if sectionLevel > 0, level <= sectionLevel { sectionLevel = 0 }
        if sectionLevel == 0, isHeading(line, titled: title) {
          sectionLevel = level
          found = true
          continue
        }
      }
      if sectionLevel > 0 { section.append(line) } else { body.append(line) }
    }
    let sectionText = section.joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return (
      body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines),
      found ? sectionText : nil)
  }

  /// ATX heading level (`## x` → 2), or nil when the line isn't a heading.
  static func headingLevel(_ line: String) -> Int? {
    let trimmed = line.drop { $0 == " " }
    guard line.prefix(while: { $0 == " " }).count <= 3, trimmed.hasPrefix("#") else { return nil }
    let hashes = trimmed.prefix { $0 == "#" }.count
    guard hashes <= 6 else { return nil }
    let rest = trimmed.dropFirst(hashes)
    guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
    return hashes
  }

  static func isCompactHeading(_ line: String) -> Bool {
    isHeading(line, titled: "compact instructions")
  }

  /// Whether `line` is an ATX heading whose title is `title`, case-insensitive; a trailing
  /// colon on the heading is tolerated.
  static func isHeading(_ line: String, titled title: String) -> Bool {
    let found = line
      .trimmingCharacters(in: .whitespaces)
      .drop { $0 == "#" }
      .trimmingCharacters(in: CharacterSet(charactersIn: " \t:"))
      .lowercased()
    return found == title.lowercased()
  }

  static func isFenceDelimiter(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
  }
}

// MARK: - ImportResolver

/// `@path` imports inside an instruction file — the ecosystem convention for splitting a
/// long AGENTS.md across files without pasting them together.
///
/// A line whose first non-space token is `@<path>` is *replaced* by that file's contents.
/// The rules are deliberately narrow, because whatever it pulls in lands in the system
/// prompt:
/// * only path-shaped tokens (containing `/` or ending in `.md`) count, so an `@handle` at
///   the start of a line stays prose;
/// * lines inside fenced code blocks are never imports, and the anchored match means an
///   inline code span (`` `@notes.md` ``) isn't one either;
/// * a project file may import only under the repo root or `~/.arnes`, a global file only
///   under the home directory, and *no* file may import a credential path (`PathScope`);
/// * cycles and nesting past `maxDepth` are dropped with a visible `[import skipped: …]`
///   note rather than silently;
/// * imported bytes count against the caller's budget, so imports can't outflank the cap.
public enum ImportResolver {
  /// Deepest chain of imports followed before the rest is dropped.
  public static let maxDepth = 4

  public struct Expansion: Sendable, Equatable {
    /// The text with every accepted import inlined.
    public var text: String
    /// Files inlined, in order.
    public var imports: [URL]
    /// Why an import was refused; the same reasons appear inline in `text`.
    public var notes: [String]
  }

  public static func expand(
    _ text: String,
    base: URL,
    allowedRoots: [URL],
    depth: Int = 0,
    maxBytes: Int = ProjectInstructions.Options.default.maxBytes,
    home: String = NSHomeDirectory())
    -> Expansion
  {
    var state = State(
      allowedRoots: allowedRoots.map { PathScope.physicalPath($0.path) },
      home: home,
      remaining: maxBytes)
    state.visited.insert(PathScope.physicalPath(base.path))
    let expanded = expand(text, base: base, depth: depth, state: &state)
    return Expansion(text: expanded, imports: state.imports, notes: state.notes)
  }

  struct State {
    let allowedRoots: [String]
    let home: String
    var remaining: Int
    var visited: Set<String> = []
    var imports: [URL] = []
    var notes: [String] = []
  }

  static func expand(_ text: String, base: URL, depth: Int, state: inout State) -> String {
    var out: [String] = []
    var inFence = false
    for line in text.components(separatedBy: "\n") {
      if ProjectInstructions.isFenceDelimiter(line) {
        inFence.toggle()
        out.append(line)
        continue
      }
      guard !inFence, let token = importToken(in: line) else {
        out.append(line)
        continue
      }
      out.append(resolve(token, base: base, depth: depth, state: &state))
    }
    return out.joined(separator: "\n")
  }

  /// The imported file's text (recursively expanded), or a skip note.
  static func resolve(_ token: String, base: URL, depth: Int, state: inout State) -> String {
    guard depth < maxDepth else {
      return note("@\(token) — more than \(maxDepth) levels of imports", state: &state)
    }
    let target = url(for: token, base: base, home: state.home)
    let physical = PathScope.physicalPath(target.path)
    guard !state.visited.contains(physical) else {
      return note("@\(token) — already imported", state: &state)
    }
    // Never, at any depth, from either side: a credential file must not become prompt text.
    guard PathScope.classify(physical, root: nil, home: state.home) != .sensitive else {
      return note("@\(token) — credential path", state: &state)
    }
    guard state.allowedRoots.contains(where: { physical == $0 || physical.hasPrefix($0 + "/") })
    else {
      return note("@\(token) — outside the project", state: &state)
    }
    guard let raw = try? String(contentsOf: URL(fileURLWithPath: physical), encoding: .utf8) else {
      return note("@\(token) — not readable", state: &state)
    }
    guard state.remaining > 0 else {
      return note("@\(token) — instruction budget exhausted", state: &state)
    }
    state.visited.insert(physical)
    state.imports.append(target)
    var body = ProjectInstructions.stripHTMLComments(raw)
    if body.utf8.count > state.remaining {
      body = String(body.prefix(state.remaining)) + "\n… [truncated]"
      state.remaining = 0
    } else {
      state.remaining -= body.utf8.count
    }
    return expand(body, base: URL(fileURLWithPath: physical), depth: depth + 1, state: &state)
  }

  static func url(for token: String, base: URL, home: String) -> URL {
    if token.hasPrefix("~/") {
      return URL(fileURLWithPath: home).appendingPathComponent(String(token.dropFirst(2)))
    }
    if token.hasPrefix("/") { return URL(fileURLWithPath: token) }
    return base.deletingLastPathComponent().appendingPathComponent(token)
  }

  /// The `@path` token on this line, when the line is an import.
  static func importToken(in line: String) -> String? {
    guard let match = line.firstMatch(of: #/^[ \t]*@(\S+)/#) else { return nil }
    let token = String(match.output.1)
    guard isPathLike(token) else { return nil }
    return token
  }

  /// Path-shaped enough to be an import: a slash somewhere, or a markdown extension. Keeps
  /// `@someone thanks for the note` from reading a file.
  static func isPathLike(_ token: String) -> Bool {
    token.contains("/") || token.lowercased().hasSuffix(".md")
  }

  static func note(_ reason: String, state: inout State) -> String {
    state.notes.append(reason)
    return "[import skipped: \(reason)]"
  }
}
