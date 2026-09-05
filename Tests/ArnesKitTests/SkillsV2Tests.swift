import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// A7 — skills v2: `skills:` frontmatter preloads bodies into a subagent's suffix (capped,
/// unknown names warned), `~/.claude/{skills,agents}` join discovery after `~/.arnes/*`, and
/// skill frontmatter `allowed-tools`/`model` parse into the skill without being applied.
final class SkillsV2Tests: XCTestCase {
  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-skills-v2-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeSkill(in root: URL, directory: String, frontmatter: String?, body: String) throws {
    let dir = root.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let content = frontmatter.map { "---\n\($0)\n---\n\n\(body)" } ?? body
    try content.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  }

  private func writeAgent(in root: URL, file: String, frontmatter: String, body: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "---\n\(frontmatter)\n---\n\n\(body)".write(
      to: root.appendingPathComponent(file), atomically: true, encoding: .utf8)
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-skills-v2-runs-\(UUID().uuidString).jsonl"))
  }

  private func skill(_ name: String, body: String, directory: URL? = nil) -> Skill {
    Skill(name: name, description: "\(name) desc", body: body, directory: directory)
  }

  // MARK: Preload section (pure)

  func testPreloadedSectionRendersNamedSkillsInOrderAndWarnsOnUnknownNames() throws {
    let dir = try tempDirectory()
    let library = [skill("a", body: "Body of A.", directory: dir), skill("b", body: "Body of B.")]
    let agent = AgentDefinition(name: "x", description: "", body: "role", skills: ["b", "nope", "a"])

    let section = AgentLibrary.preloadedSkillsSection(for: agent, from: library)
    XCTAssertTrue(section.text.hasPrefix("\n\n# Preloaded skills\n"), "leads with the separator from the role suffix")
    let bIndex = try XCTUnwrap(section.text.range(of: "## b\n\nBody of B."))
    let aIndex = try XCTUnwrap(section.text.range(of: "## a\n"))
    XCTAssertLessThan(bIndex.lowerBound, aIndex.lowerBound, "frontmatter order is kept")
    XCTAssertTrue(section.text.contains("Supporting files it mentions live in \(dir.path)"), "a file skill keeps its note")
    XCTAssertTrue(section.text.contains("Body of A."))
    XCTAssertFalse(section.text.contains("nope"), "an unknown name never reaches the prompt")
    XCTAssertFalse(section.text.hasSuffix("\n"))
    XCTAssertEqual(section.warnings, ["skills: no skill named 'nope' — not preloaded"])
  }

  func testAgentNamingNoSkillsGetsEmptySectionAndOnlyUnknownNamesGiveWarningsWithoutText() {
    let library = [skill("a", body: "A")]
    let none = AgentDefinition(name: "x", description: "", body: "role")
    XCTAssertEqual(AgentLibrary.preloadedSkillsSection(for: none, from: library).text, "")
    XCTAssertEqual(AgentLibrary.preloadedSkillsSection(for: none, from: library).warnings, [])
    XCTAssertEqual(TaskTool.systemSuffix(for: none) + AgentLibrary.preloadedSkillsSection(for: none, from: library).text,
                   TaskTool.systemSuffix(for: none), "byte-identical suffix when nothing is named")

    let allUnknown = AgentDefinition(name: "x", description: "", body: "role", skills: ["nope", "nada"])
    let section = AgentLibrary.preloadedSkillsSection(for: allUnknown, from: library)
    XCTAssertEqual(section.text, "", "no resolvable skill → no section, not an empty heading")
    XCTAssertEqual(section.warnings.count, 2)

    // An empty library with a `skills:` list is the same story.
    XCTAssertEqual(AgentLibrary.preloadedSkillsSection(for: allUnknown, from: []).text, "")
  }

  func testPreloadIsCappedWithATruncationNoteNamingTheCutSkillAndListsTheOmitted() {
    let big = skill("big", body: String(repeating: "x", count: 40_000))
    let after = skill("after", body: "never reached")
    let agent = AgentDefinition(name: "x", description: "", body: "role", skills: ["big", "after"])

    let section = AgentLibrary.preloadedSkillsSection(for: agent, from: [big, after])
    let cap = AgentLibrary.preloadedSkillsMaxBytes
    XCTAssertEqual(cap, 32_768, "the project-instructions cap")
    XCTAssertTrue(section.text.contains("… [truncated: skill 'big' cut at the 32 KB preload cap]"), section.text.suffix(300).description)
    XCTAssertTrue(section.text.contains("… [not preloaded, cap reached: after — load them with the skill tool]"))
    XCTAssertFalse(section.text.contains("never reached"))
    // Header + notes aside, the bodies stay under the cap.
    XCTAssertLessThan(section.text.utf8.count, cap + 600)
    XCTAssertEqual(section.warnings, [
      "skills: 'big' truncated at the 32 KB preload cap",
      "skills: not preloaded past the 32 KB cap: after",
    ])

    // A smaller cap cuts on a byte boundary even through multi-byte text.
    let accented = skill("é", body: String(repeating: "é", count: 200))
    let small = AgentLibrary.preloadedSkillsSection(
      for: AgentDefinition(name: "x", description: "", body: "r", skills: ["é"]), from: [accented], maxBytes: 41)
    XCTAssertTrue(small.text.contains("truncated: skill 'é'"))
    XCTAssertFalse(small.text.contains("\u{FFFD}"))
  }

  // MARK: Preload through the task tool

  func testExecutePreloadsNamedSkillBodiesIntoTheNestedSystemPromptOnly() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done", model: "sub/model")]]

    let library = [skill("release", body: "Tag, build, publish."), skill("review", body: "Read the diff twice.")]
    let agent = AgentDefinition(
      name: "shipper", description: "ships", body: "Ship it.", model: "sub/model", skills: ["release", "nope"])
    let tool = TaskTool(
      agents: [agent], service: mock, tools: [ReadFileTool(), SkillTool(skills: library)], store: tempStore(),
      skills: library)
    tool.parentModel = { "lead/model" }

    _ = try await tool.execute(arguments: ["agent": .string("shipper"), "task": .string("ship")])

    let request = try XCTUnwrap(mock.requests.first)
    let system = try XCTUnwrap(request.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertTrue(system.contains("You are 'shipper'"))
    XCTAssertTrue(system.contains("# Preloaded skills"))
    XCTAssertTrue(system.contains("## release\n\nTag, build, publish."))
    XCTAssertFalse(system.contains("Read the diff twice."), "an unnamed skill stays behind the skill tool")
    XCTAssertFalse(system.contains("nope"))
    // The role suffix precedes the preload, and the skill tool's listing still names both.
    let role = try XCTUnwrap(system.range(of: "# Subagent role"))
    let preload = try XCTUnwrap(system.range(of: "# Preloaded skills"))
    XCTAssertLessThan(role.lowerBound, preload.lowerBound)
    XCTAssertTrue(system.contains("- review: review desc"))
    XCTAssertEqual(tool.skills.map(\.name), ["release", "review"])
  }

  func testExecuteWithoutNamedSkillsSendsTheSameSystemPromptWhetherOrNotALibraryIsPassed() async throws {
    let library = [skill("release", body: "Tag, build, publish.")]
    let agent = AgentDefinition(name: "plain", description: "p", body: "Plain role.", model: "sub/model")

    func systemPrompt(skills: [Skill]) async throws -> String {
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "sub/model"))
      mock.chunkScripts = [[Fixtures.textChunk("ok", model: "sub/model")]]
      let tool = TaskTool(agents: [agent], service: mock, tools: [ReadFileTool()], store: tempStore(), skills: skills)
      tool.parentModel = { "lead/model" }
      _ = try await tool.execute(arguments: ["agent": .string("plain"), "task": .string("t")])
      return try XCTUnwrap(mock.requests.first?.messages.first { $0.role == .system }?.content?.plainText)
    }

    let with = try await systemPrompt(skills: library)
    let without = try await systemPrompt(skills: [])
    XCTAssertEqual(with, without)
    XCTAssertFalse(with.contains("# Preloaded skills"))
  }

  // MARK: Discovery roots

  func testSkillDiscoveryFindsClaudeHomeSkillsAfterArnesHomeAndShadowsBuiltins() throws {
    let workdir = try tempDirectory()
    let home = try tempDirectory()
    try writeSkill(
      in: home.appendingPathComponent(".claude/skills"), directory: "release",
      frontmatter: "name: release\ndescription: from claude home", body: "claude home body")
    try writeSkill(
      in: home.appendingPathComponent(".arnes/skills"), directory: "release",
      frontmatter: "name: release\ndescription: from arnes home", body: "arnes home body")
    try writeSkill(
      in: home.appendingPathComponent(".claude/skills"), directory: "only-claude",
      frontmatter: nil, body: "only here")
    try writeSkill(
      in: home.appendingPathComponent(".claude/skills"), directory: "init",
      frontmatter: "name: init\ndescription: my init", body: "custom init")

    // Roots in order, entries alphabetical within a root; the drop-in `init` shadows the
    // built-in, so no built-in is appended.
    let skills = SkillLibrary.discover(workdir: workdir, home: home)
    XCTAssertEqual(skills.map(\.name), ["release", "init", "only-claude"])
    XCTAssertEqual(skills[0].description, "from arnes home", "~/.arnes shadows ~/.claude")
    XCTAssertTrue(skills[2].sourceDescription.hasSuffix("/.claude/skills/only-claude"), skills[2].sourceDescription)
    XCTAssertEqual(skills[1].body, "custom init", "a ~/.claude skill shadows the built-in")
    XCTAssertNotNil(skills[1].directory)

    // The project roots still come first, and the user roots load without the project gate.
    try writeSkill(
      in: workdir.appendingPathComponent(".claude/skills"), directory: "release",
      frontmatter: "name: release\ndescription: project", body: "project body")
    XCTAssertEqual(SkillLibrary.discover(workdir: workdir, home: home).first?.description, "project")
    XCTAssertEqual(
      SkillLibrary.discover(workdir: workdir, home: home, includeProject: false).map(\.name),
      ["release", "init", "only-claude"])
    XCTAssertEqual(
      SkillLibrary.userRoots(home: home),
      [home.appendingPathComponent(".arnes/skills"), home.appendingPathComponent(".claude/skills")])
  }

  func testAgentDiscoveryFindsClaudeHomeAgentsAfterArnesHomeAndShadowsBuiltins() throws {
    let workdir = try tempDirectory()
    let home = try tempDirectory()
    try writeAgent(
      in: home.appendingPathComponent(".claude/agents"), file: "scout.md",
      frontmatter: "name: scout\ndescription: from claude home", body: "claude scout")
    try writeAgent(
      in: home.appendingPathComponent(".arnes/agents"), file: "scout.md",
      frontmatter: "name: scout\ndescription: from arnes home", body: "arnes scout")
    try writeAgent(
      in: home.appendingPathComponent(".claude/agents"), file: "only-claude.md",
      frontmatter: "name: only-claude\ndescription: drop-in", body: "only here")
    try writeAgent(
      in: home.appendingPathComponent(".claude/agents"), file: "explore.md",
      frontmatter: "name: explore\ndescription: my explore\ntools: Read", body: "custom explore")

    // Roots in order, files alphabetical within a root; the drop-in `explore` shadows the
    // built-in, `general` is still appended.
    let agents = AgentLibrary.discover(workdir: workdir, home: home)
    XCTAssertEqual(agents.map(\.name), ["scout", "explore", "only-claude", "general", "fork"])
    XCTAssertEqual(agents[0].description, "from arnes home", "~/.arnes shadows ~/.claude")
    XCTAssertTrue(agents[2].source?.path.hasSuffix("/.claude/agents/only-claude.md") == true, "\(String(describing: agents[2].source))")
    XCTAssertEqual(agents[1].body, "custom explore", "a ~/.claude agent shadows the built-in")
    XCTAssertEqual(agents[1].tools, ["read_file"])
    XCTAssertNil(agents[3].source)
    XCTAssertEqual(
      AgentLibrary.discover(workdir: workdir, home: home, includeProject: false).map(\.name),
      ["scout", "explore", "only-claude", "general", "fork"], "user roots are not behind the project gate")
    XCTAssertEqual(
      AgentLibrary.userRoots(home: home),
      [home.appendingPathComponent(".arnes/agents"), home.appendingPathComponent(".claude/agents")])
  }

  // MARK: Skill frontmatter

  func testLoadParsesAllowedToolsAndModelCanonicalizedWithWarningsButKeepsTheSkill() throws {
    let root = try tempDirectory()
    try writeSkill(
      in: root, directory: "git-flow",
      frontmatter: """
        name: git-flow
        description: git helper
        allowed-tools: Read, Bash(git add:*), Bash(git status:*), Task, Broken(, mcp__gh__pr_list, Edit
        model: haiku
        """,
      body: "Use git carefully.")

    let skill = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("git-flow")))
    XCTAssertEqual(skill.name, "git-flow")
    XCTAssertEqual(skill.body, "Use git carefully.")
    XCTAssertEqual(
      skill.allowedTools,
      ["read_file", "bash(git add:*)", "bash(git status:*)", "mcp__gh__pr_list", "edit_file"])
    XCTAssertEqual(skill.model, "haiku")
    XCTAssertEqual(skill.warnings.count, 2, skill.warnings.joined(separator: " | "))
    XCTAssertTrue(skill.warnings[0].contains("'Task'"), skill.warnings[0])
    XCTAssertTrue(skill.warnings[0].contains("dropped"))
    XCTAssertTrue(skill.warnings[1].contains("'Broken('"), skill.warnings[1])
    XCTAssertTrue(skill.warnings[1].contains("malformed"))
    XCTAssertEqual(skill.listingFacts, [
      "allowed-tools: read_file, bash(git add:*), bash(git status:*), mcp__gh__pr_list, edit_file (parsed, not applied)",
      "model: haiku (applied to /git-flow turns in the REPL)",
    ])
  }

  func testLoadTreatsInheritModelAndAbsentKeysAsUnsetAndKeysCaseInsensitively() throws {
    let root = try tempDirectory()
    try writeSkill(
      in: root, directory: "plain", frontmatter: "Name: plain\nModel: inherit\nAllowedTools: Grep",
      body: "Plain.")
    let plain = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("plain")))
    XCTAssertEqual(plain.name, "plain")
    XCTAssertNil(plain.model)
    XCTAssertEqual(plain.allowedTools, ["grep"])
    XCTAssertEqual(plain.warnings, [])

    try writeSkill(in: root, directory: "bare", frontmatter: "name: bare", body: "Bare.")
    let bare = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("bare")))
    XCTAssertNil(bare.allowedTools)
    XCTAssertNil(bare.model)
    XCTAssertEqual(bare.listingFacts, [])

    // Every entry unusable → no list, the warnings say why, the skill is still loaded.
    try writeSkill(in: root, directory: "odd", frontmatter: "name: odd\nallowed-tools: Task, (x)", body: "Odd.")
    let odd = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("odd")))
    XCTAssertNil(odd.allowedTools)
    XCTAssertEqual(odd.warnings.count, 2)
    XCTAssertEqual(BuiltinSkills.initInstructions.listingFacts, [])

    // A comma inside a balanced specifier stays with its entry.
    let commas = SkillLibrary.parseAllowedTools("Bash(git commit -m a,b:*), Glob")
    XCTAssertEqual(commas.tools, ["bash(git commit -m a,b:*)", "glob"])
    XCTAssertEqual(commas.warnings, [])
  }

  func testLoadFoldsBlockScalarsIntoOneLineAndNeverReadsAnIndentedLineAsAKey() throws {
    let root = try tempDirectory()
    // A folded description (Claude Code libraries use `>` often) with a sentence shaped like
    // a key inside it; the real `model:` follows at column 0.
    try writeSkill(
      in: root, directory: "folded",
      frontmatter: """
        name: folded
        description: >
          Guides engineers through a migration.
          Model: pick the cheapest that works.

          Use when asked.
        model: inherit
        """,
      body: "Migrate.")
    let folded = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("folded")))
    XCTAssertEqual(
      folded.description,
      "Guides engineers through a migration. Model: pick the cheapest that works. Use when asked.")
    XCTAssertNil(folded.model, "the `Model:` sentence inside the block is text, `model: inherit` is unset")
    XCTAssertTrue(
      SkillTool(skills: [folded]).promptSection.contains("- folded: Guides engineers through a migration. Model: pick"),
      "the listing stays one line per skill")

    // Literal style with strip chomping, and a plain scalar continued on indented lines.
    try writeSkill(
      in: root, directory: "literal",
      frontmatter: "name: literal\ndescription: |-\n  Line one.\n  Line two.\nmodel: haiku",
      body: "L.")
    let literal = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("literal")))
    XCTAssertEqual(literal.description, "Line one. Line two.")
    XCTAssertEqual(literal.model, "haiku")

    try writeSkill(
      in: root, directory: "plain",
      frontmatter: "name: plain\ndescription: This is long\n  and continues here\nmodel: sonnet",
      body: "P.")
    let plain = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("plain")))
    XCTAssertEqual(plain.description, "This is long and continues here")
    XCTAssertEqual(plain.model, "sonnet")

    // A nested map under an unknown key is consumed whole: its `model:` is not the skill's.
    try writeSkill(
      in: root, directory: "nested",
      frontmatter: "name: nested\nmetadata:\n  model: nope\n  author: me\nmodel: real",
      body: "N.")
    let nested = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("nested")))
    XCTAssertEqual(nested.model, "real")
    XCTAssertEqual(
      SkillLibrary.frontmatterEntries(["metadata:", "  model: nope", "model: real"]),
      [
        SkillLibrary.FrontmatterEntry(key: "metadata", value: "", items: nil),
        SkillLibrary.FrontmatterEntry(key: "model", value: "real", items: nil),
      ])
  }

  func testLoadReadsAllowedToolsAsAYAMLSequenceAndFlagsStrayParentheses() throws {
    let root = try tempDirectory()
    try writeSkill(
      in: root, directory: "seq",
      frontmatter: """
        name: seq
        allowed-tools:
          - Read
          - Bash(git status:*)
          - Read)
          - "Edit"
        model: haiku
        """,
      body: "S.")
    let seq = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("seq")))
    XCTAssertEqual(seq.allowedTools, ["read_file", "bash(git status:*)", "edit_file"])
    XCTAssertEqual(seq.warnings, ["allowed-tools entry 'Read)' is malformed; dropped"])
    XCTAssertEqual(seq.model, "haiku", "the key after the sequence is still read")

    // The sequence may also sit at its parent's indentation.
    try writeSkill(
      in: root, directory: "flush", frontmatter: "name: flush\nallowed-tools:\n- Grep\n- Glob\ndescription: d", body: "F.")
    let flush = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("flush")))
    XCTAssertEqual(flush.allowedTools, ["grep", "glob"])
    XCTAssertEqual(flush.description, "d")

    // Inline: a closing paren without an opener, or a group closing early, is malformed —
    // never a tool named `Read)`.
    let stray = SkillLibrary.parseAllowedTools("Read), Edit")
    XCTAssertEqual(stray.tools, ["edit_file"])
    XCTAssertEqual(stray.warnings, ["allowed-tools entry 'Read)' is malformed; dropped"])
    let early = SkillLibrary.parseAllowedTools("Bash(a)b(c), Bash((nested)), Bash(x))")
    XCTAssertEqual(early.tools, ["bash((nested))"])
    XCTAssertEqual(early.warnings.count, 2, early.warnings.joined(separator: " | "))
  }

  func testSkillToolStillServesEveryDiscoveredSkillWhateverItsFrontmatter() async throws {
    let tool = SkillTool(skills: [
      Skill(name: "x", description: "", body: "X body", directory: nil, allowedTools: ["bash(git:*)"], model: "haiku"),
    ])
    let result = try await tool.execute(arguments: ["name": .string("x")])
    XCTAssertTrue(result.contains("X body"))
    XCTAssertFalse(result.contains("haiku"), "parsed frontmatter is not applied — nor shown to the model")
  }
}
