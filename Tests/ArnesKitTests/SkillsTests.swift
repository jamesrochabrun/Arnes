import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class SkillsTests: XCTestCase {
  private func tempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-skills-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeSkill(
    in root: URL, directory: String, frontmatter: String?, body: String) throws
  {
    let dir = root.appendingPathComponent(directory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let content = frontmatter.map { "---\n\($0)\n---\n\n\(body)" } ?? body
    try content.write(
      to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  }

  // MARK: Parsing

  func testLoadParsesFrontmatterAndBody() throws {
    let root = try tempDirectory()
    try writeSkill(
      in: root, directory: "release",
      frontmatter: "name: release\ndescription: \"Cut a release: tag, build, publish.\"",
      body: "# Releasing\n\nBump the version first.")

    let skill = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("release")))
    XCTAssertEqual(skill.name, "release")
    XCTAssertEqual(skill.description, "Cut a release: tag, build, publish.")
    XCTAssertEqual(skill.body, "# Releasing\n\nBump the version first.")
  }

  func testLoadFallsBackToDirectoryNameWithoutFrontmatter() throws {
    let root = try tempDirectory()
    try writeSkill(in: root, directory: "deploy", frontmatter: nil, body: "Just deploy.")

    let skill = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("deploy")))
    XCTAssertEqual(skill.name, "deploy")
    XCTAssertEqual(skill.description, "")
    XCTAssertEqual(skill.body, "Just deploy.")
  }

  func testLoadReturnsNilForMissingOrEmptySkillFile() throws {
    let root = try tempDirectory()
    XCTAssertNil(SkillLibrary.load(directory: root.appendingPathComponent("absent")))

    try writeSkill(in: root, directory: "empty", frontmatter: "name: empty", body: "")
    XCTAssertNil(SkillLibrary.load(directory: root.appendingPathComponent("empty")))
  }

  // MARK: Discovery

  func testDiscoverPrefersProjectOverGlobalAndMergesSources() throws {
    let workdir = try tempDirectory()
    let home = try tempDirectory()
    // Same name in all three roots — the project .arnes copy must win.
    try writeSkill(
      in: workdir.appendingPathComponent(".arnes/skills"), directory: "release",
      frontmatter: "name: release\ndescription: project", body: "project version")
    try writeSkill(
      in: workdir.appendingPathComponent(".claude/skills"), directory: "release",
      frontmatter: "name: release\ndescription: claude", body: "claude version")
    try writeSkill(
      in: home.appendingPathComponent(".arnes/skills"), directory: "release",
      frontmatter: "name: release\ndescription: global", body: "global version")
    // Unique names elsewhere still show up.
    try writeSkill(
      in: workdir.appendingPathComponent(".claude/skills"), directory: "review",
      frontmatter: "name: review\ndescription: from claude dir", body: "review body")
    try writeSkill(
      in: home.appendingPathComponent(".arnes/skills"), directory: "global-only",
      frontmatter: nil, body: "global body")

    let skills = SkillLibrary.discover(workdir: workdir, home: home)
    XCTAssertEqual(skills.map(\.name), ["release", "review", "global-only"])
    XCTAssertEqual(skills.first?.description, "project")
    XCTAssertEqual(skills.first?.body, "project version")
  }

  // MARK: Tool

  func testSkillToolReturnsBodyAndPointsAtSupportingFiles() async throws {
    let root = try tempDirectory()
    try writeSkill(
      in: root, directory: "release",
      frontmatter: "name: release\ndescription: cut releases", body: "Run the tag script.")
    let skill = try XCTUnwrap(SkillLibrary.load(directory: root.appendingPathComponent("release")))

    let tool = SkillTool(skills: [skill])
    let result = try await tool.execute(arguments: ["name": .string("release")])
    XCTAssertTrue(result.contains("Run the tag script."))
    XCTAssertTrue(result.contains(skill.directory.path))
    XCTAssertEqual(tool.permission, .readOnly)
  }

  func testSkillToolListsAvailableOnUnknownName() async throws {
    let tool = SkillTool(skills: [
      Skill(name: "release", description: "", body: "b", directory: URL(fileURLWithPath: "/tmp")),
    ])
    let result = try await tool.execute(arguments: ["name": .string("nope")])
    XCTAssertTrue(result.hasPrefix("error:"))
    XCTAssertTrue(result.contains("release"))
  }

  func testPromptSectionListsSkillsAndIsEmptyWithoutAny() {
    let tool = SkillTool(skills: [
      Skill(name: "release", description: "cut releases", body: "b", directory: URL(fileURLWithPath: "/tmp")),
      Skill(name: "review", description: "", body: "b", directory: URL(fileURLWithPath: "/tmp")),
    ])
    XCTAssertTrue(tool.promptSection.contains("- release: cut releases"))
    XCTAssertTrue(tool.promptSection.contains("- review"))
    XCTAssertEqual(SkillTool(skills: []).promptSection, "")
  }

  // MARK: User invocation

  func testInvocationSubstitutesArgumentsAndPositionals() {
    let skill = Skill(
      name: "pr", description: "", body: "Review $1 against $2. Notes: $ARGUMENTS",
      directory: URL(fileURLWithPath: "/tmp"))
    let prompt = skill.invocationPrompt(arguments: "main develop")
    XCTAssertTrue(prompt.contains("Review main against develop. Notes: main develop"))
    XCTAssertFalse(prompt.contains("Arguments:"))
  }

  func testInvocationMissingPositionalsBecomeEmptyAndDigitsAreNotMangled() {
    let skill = Skill(
      name: "pr", description: "", body: "a=$1 b=$2 price=$10",
      directory: URL(fileURLWithPath: "/tmp"))
    let prompt = skill.invocationPrompt(arguments: "one")
    // $1 fills, $2 empties, $10 is not a placeholder and survives verbatim.
    XCTAssertTrue(prompt.contains("a=one b= price=$10"))
  }

  func testInvocationAppendsArgumentsWithoutPlaceholders() {
    let skill = Skill(
      name: "deploy", description: "", body: "Ship it.",
      directory: URL(fileURLWithPath: "/tmp"))
    XCTAssertTrue(skill.invocationPrompt(arguments: "to staging").contains("Arguments: to staging"))
    XCTAssertFalse(skill.invocationPrompt(arguments: nil).contains("Arguments:"))
    XCTAssertTrue(skill.invocationPrompt(arguments: nil).contains("Ship it."))
  }

  // MARK: Session integration

  func testSkillListingRidesTheSystemPrompt() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0.01)]]
    let tool = SkillTool(skills: [
      Skill(name: "release", description: "cut releases", body: "b", directory: URL(fileURLWithPath: "/tmp")),
    ])
    let store = RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-skills-runs-\(UUID().uuidString).jsonl"))
    let session = Session(
      service: mock,
      tools: [tool],
      store: store,
      configuration: .init(model: "test/model"))

    for try await _ in await session.send("hi") {}

    let system = try XCTUnwrap(mock.requests.first?.messages.first { $0.role == .system })
    XCTAssertTrue(system.content?.plainText.contains("# Skills") == true)
    XCTAssertTrue(system.content?.plainText.contains("- release: cut releases") == true)
  }
}
