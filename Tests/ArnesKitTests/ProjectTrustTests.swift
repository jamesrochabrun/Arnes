import XCTest
@testable import ArnesKit

final class ProjectTrustTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-trust-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func writeSkill(_ name: String, under root: URL) throws {
    let dir = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: d\n---\nbody".write(
      to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  }

  private func writeAgent(_ name: String, under root: URL) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try "---\nname: \(name)\ndescription: d\nmodel: sonnet\n---\nbody".write(
      to: root.appendingPathComponent("\(name).md"), atomically: true, encoding: .utf8)
  }

  func testStoreRemembersResolvedDirectories() throws {
    let home = try tempDir()
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"))
    let project = try tempDir()
    XCTAssertFalse(store.isTrusted(project))
    try store.trust(project)
    XCTAssertTrue(store.isTrusted(project))
    // Same directory by another spelling.
    XCTAssertTrue(store.isTrusted(URL(fileURLWithPath: project.path + "/")))
    XCTAssertTrue(store.isTrusted(project.appendingPathComponent("sub").appendingPathComponent("..")))
    let link = try tempDir().appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: project)
    XCTAssertTrue(store.isTrusted(link))
    XCTAssertEqual(store.all().count, 1)
    try store.trust(project) // idempotent
    XCTAssertEqual(store.all().count, 1)
    try store.forget(project)
    XCTAssertFalse(store.isTrusted(project))
    XCTAssertFalse(SecureFiles.isReadableByOthers(store.url))
  }

  // MARK: Trust store v2 — the walk up

  func testATrustedRepositoryRootTrustsItsSubdirectoriesAndNeverItsNeighbors() throws {
    let home = try tempDir()
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"), home: home)
    let workspace = try tempDir()
    let repo = workspace.appendingPathComponent("repo")
    let src = repo.appendingPathComponent("src/deep")
    let other = workspace.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)

    try store.trust(repo)
    XCTAssertTrue(store.isTrusted(repo))
    XCTAssertTrue(store.isTrusted(src), "a subdirectory of a trusted repository is trusted")
    XCTAssertEqual(store.trustingDirectory(for: src), ProjectTrustStore.key(for: repo))
    XCTAssertFalse(store.isTrusted(other), "a neighbor is not")
    XCTAssertFalse(store.isTrusted(workspace), "nor the parent")

    // Trusting the workspace does not reach *into* the repository past its root: the walk from
    // `repo/src` stops at `repo` (it has a `.git`) and never sees `workspace`.
    try store.forget(repo)
    try store.trust(workspace)
    XCTAssertTrue(store.isTrusted(other), "a plain child of a trusted parent is trusted")
    XCTAssertFalse(store.isTrusted(src), "a repository inside it is its own trust decision")
    XCTAssertFalse(store.isTrusted(repo))
  }

  func testATrustedParentWithoutAGitDirectoryTrustsChildrenUpToButExcludingHome() throws {
    let home = try tempDir()
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"), home: home)
    let work = home.appendingPathComponent("work")
    let deep = work.appendingPathComponent("a/b")
    let sibling = home.appendingPathComponent("elsewhere")
    try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

    try store.trust(work)
    XCTAssertTrue(store.isTrusted(deep))
    XCTAssertEqual(store.trustingDirectory(for: deep), ProjectTrustStore.key(for: work))
    XCTAssertFalse(store.isTrusted(sibling), "the walk from a sibling reaches home and stops")
    XCTAssertFalse(store.isTrusted(home))

    // Home and its ancestors are never a match, however they got into the file.
    let file = home.appendingPathComponent(".arnes/trusted.json")
    let listedHome = """
      {"directories": ["\(ProjectTrustStore.key(for: home))", "/", "\(ProjectTrustStore.key(for: home.deletingLastPathComponent()))"]}
      """
    try SecureFiles.writePrivate(Data(listedHome.utf8), to: file)
    XCTAssertFalse(store.isTrusted(home))
    XCTAssertFalse(store.isTrusted(sibling))
    XCTAssertFalse(store.isTrusted(URL(fileURLWithPath: "/")))
  }

  func testTrustingHomeItsAncestorsOrTheRootIsRefused() throws {
    let home = try tempDir()
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"), home: home)
    for refused in [home, home.deletingLastPathComponent(), URL(fileURLWithPath: "/")] {
      XCTAssertThrowsError(try store.trust(refused), refused.path) { error in
        guard case ProjectTrustError.refusedRoot(let path)? = error as? ProjectTrustError else {
          return XCTFail("expected refusedRoot, got \(error)")
        }
        XCTAssertEqual(path, ProjectTrustStore.key(for: refused))
        XCTAssertTrue("\(error)".contains("every project on this machine"))
      }
    }
    XCTAssertTrue(store.all().isEmpty)
    let project = home.appendingPathComponent("proj")
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    try store.trust(project)
    XCTAssertEqual(store.all().count, 1)
  }

  func testOldTrustedJSONWithoutTheMCPMapDecodesAndForgetStillDropsHookHashes() throws {
    let home = try tempDir()
    let file = home.appendingPathComponent(".arnes/trusted.json")
    let project = try tempDir()
    let key = ProjectTrustStore.key(for: project)
    try SecureFiles.writePrivate(Data("""
      {"directories": ["\(key)"], "hookHashes": {"\(key)": ["abc"]}}
      """.utf8), to: file)
    let store = ProjectTrustStore(url: file, home: home)
    XCTAssertTrue(store.isTrusted(project))
    XCTAssertEqual(store.trustedHookHashes(for: project), ["abc"])
    XCTAssertTrue(store.pinnedMCPTools(for: "docs").isEmpty)
    XCTAssertTrue(store.pinnedMCPServers().isEmpty)

    try store.pinMCPTools(["search": "deadbeef"], for: "docs")
    XCTAssertEqual(store.pinnedMCPTools(for: "docs"), ["search": "deadbeef"])
    XCTAssertEqual(store.pinnedMCPServers(), ["docs"])
    XCTAssertEqual(store.pinned(for: "docs"), ["search": "deadbeef"], "the MCPToolPins conformance")
    try store.forget(project)
    XCTAssertFalse(store.isTrusted(project))
    XCTAssertTrue(store.trustedHookHashes(for: project).isEmpty, "forgetting a directory forgets its hook approvals")
    XCTAssertEqual(store.pinnedMCPTools(for: "docs"), ["search": "deadbeef"], "a server's pins are not a directory's")
    try store.pinMCPTools([:], for: "docs")
    XCTAssertTrue(store.pinnedMCPServers().isEmpty)
    // The older-shaped file still round-trips through a save.
    let data = try Data(contentsOf: file)
    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"directories\""))
  }

  func testUntrustedProjectDefinitionsCanBeLeftOut() throws {
    let workdir = try tempDir()
    let home = try tempDir()
    try writeSkill("repo-skill", under: workdir.appendingPathComponent(".claude/skills"))
    try writeSkill("my-skill", under: home.appendingPathComponent(".arnes/skills"))
    try writeAgent("repo-agent", under: workdir.appendingPathComponent(".arnes/agents"))
    try writeAgent("my-agent", under: home.appendingPathComponent(".arnes/agents"))

    XCTAssertEqual(
      SkillLibrary.discover(workdir: workdir, home: home).map(\.name),
      ["repo-skill", "my-skill", "init"])
    XCTAssertEqual(
      SkillLibrary.discover(workdir: workdir, home: home, includeProject: false).map(\.name),
      ["my-skill", "init"], "home skills and built-ins stay; the repo's are skipped")
    XCTAssertEqual(SkillLibrary.projectSkills(workdir: workdir).map(\.name), ["repo-skill"])
    XCTAssertTrue(SkillLibrary.projectSkills(workdir: try tempDir()).isEmpty)

    let all = AgentLibrary.discover(workdir: workdir, home: home).map(\.name)
    XCTAssertEqual(all, ["repo-agent", "my-agent", "general", "explore", "fork"])
    let trusted = AgentLibrary.discover(workdir: workdir, home: home, includeProject: false).map(\.name)
    XCTAssertEqual(trusted, ["my-agent", "general", "explore", "fork"], "home agents and built-ins stay; the repo's are skipped")
    XCTAssertEqual(AgentLibrary.projectAgents(workdir: workdir).map(\.name), ["repo-agent"])
    XCTAssertEqual(AgentLibrary.projectAgents(workdir: workdir).first?.model, "sonnet")
  }

  func testRepoWithOnlyClaudeMdRequiresTrust() throws {
    let home = try tempDir()
    let repo = try tempDir()
    try FileManager.default.createDirectory(
      at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try "REPO RULES".write(
      to: repo.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)

    // An instruction file *is* system-prompt text, so it counts as project content even
    // with no skills or agents in the repo — there is a trust question to ask.
    let content = ProjectContent.discover(workdir: repo, home: home)
    XCTAssertFalse(content.isEmpty)
    XCTAssertTrue(content.skills.isEmpty)
    XCTAssertTrue(content.agents.isEmpty)
    XCTAssertEqual(content.instructions.map { $0.path.lastPathComponent }, ["CLAUDE.md"],
                   "the listing names the file it would load")
    XCTAssertEqual(content.describe(), "1 instruction file")
    XCTAssertEqual(content.instructions.first?.byteCount, "REPO RULES".utf8.count)

    // Untrusted, the text stays out of the prompt; trusted, it loads.
    XCTAssertNil(ProjectInstructions.discover(workdir: repo, home: home, includeProject: false))
    let trusted = try XCTUnwrap(
      ProjectInstructions.discover(workdir: repo, home: home, includeProject: true))
    XCTAssertTrue(trusted.contains("REPO RULES"))

    // A directory that defines nothing still short-circuits — no prompt for an empty repo.
    XCTAssertTrue(ProjectContent.discover(workdir: try tempDir(), home: home).isEmpty)
  }

  func testProjectContentDescribesEveryKind() throws {
    let workdir = try tempDir()
    let home = try tempDir()
    try writeSkill("repo-skill", under: workdir.appendingPathComponent(".claude/skills"))
    try writeAgent("repo-agent", under: workdir.appendingPathComponent(".arnes/agents"))
    try writeAgent("other-agent", under: workdir.appendingPathComponent(".arnes/agents"))
    try "RULES".write(
      to: workdir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
    try writeProjectHooks(#"{"hooks":[{"event":"Stop","command":"echo hi"}]}"#, under: workdir)

    let content = ProjectContent.discover(workdir: workdir, home: home)
    XCTAssertEqual(content.describe(), "1 skill and 2 agents and 1 instruction file and 1 hook")
    XCTAssertTrue(content.mcpServers.isEmpty)

    // X9: a repository's .mcp.json is project content too — names and transports only.
    try #"{"mcpServers": {"repo": {"command": "repo-server"}}}"#
      .write(to: workdir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    let withMCP = ProjectContent.discover(workdir: workdir, home: home)
    XCTAssertEqual(withMCP.describe(), "1 skill and 2 agents and 1 instruction file and 1 hook and 1 MCP server")
    XCTAssertEqual(withMCP.mcpServers, [MCPServerSummary(name: "repo", transport: "stdio repo-server")])
  }

  func testUntrustedDirectoryDoesNotLoadItsHooks() throws {
    // The same gate as skills and agents, and then some: a repo's hooks run shell commands,
    // so an untrusted directory contributes none of them — even ones whose hashes are on
    // record from an earlier `arnes hooks trust`.
    let home = try tempDir()
    let workdir = try tempDir()
    let store = ProjectTrustStore(url: home.appendingPathComponent(".arnes/trusted.json"))
    let user = try tempDir().appendingPathComponent("hooks.json")
    try #"{"hooks":[{"event":"Stop","command":"mine.sh"}]}"#
      .write(to: user, atomically: true, encoding: .utf8)
    try writeProjectHooks(#"{"hooks":[{"event":"Stop","command":"theirs.sh"}]}"#, under: workdir)
    try store.trustHooks(HookConfig.projectHooks(in: workdir).map(\.fingerprint), in: workdir)

    var loaded = try HookConfig.load(user: user, project: workdir, trust: store)
    XCTAssertEqual(loaded.active.map(\.command), ["mine.sh"], "the user's hooks are unaffected")
    XCTAssertEqual(loaded.hooks.last?.trust, .untrustedDirectory)

    try store.trust(workdir)
    loaded = try HookConfig.load(user: user, project: workdir, trust: store)
    XCTAssertEqual(loaded.active.map(\.command), ["mine.sh", "theirs.sh"])
  }

  private func writeProjectHooks(_ json: String, under workdir: URL) throws {
    let url = HookConfig.projectURL(in: workdir)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try json.write(to: url, atomically: true, encoding: .utf8)
  }
}
