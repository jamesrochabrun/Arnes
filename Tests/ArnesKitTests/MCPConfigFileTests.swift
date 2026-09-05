import OpenRouterSwift
import XCTest
@testable import ArnesKit

/// X9: editing an MCP config file as a JSON tree, the entry rules `arnes mcp add` enforces, and
/// the project `.mcp.json`'s place in `MCPConfig.resolve` — behind the trust gate, forced
/// untrusted, never `required`, never over a user entry.
final class MCPConfigFileTests: XCTestCase {
  private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-mcpfile-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func decoded(_ url: URL) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
  }

  private func mode(_ url: URL) throws -> Int {
    try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) & 0o777
  }

  private func stdio(_ command: String, env: [String: String] = [:]) -> JSONValue {
    var object: [String: JSONValue] = ["command": .string(command)]
    if !env.isEmpty { object["env"] = .object(env.mapValues { .string($0) }) }
    return .object(object)
  }

  private func http(_ url: String, headers: [String: String] = [:], insecure: Bool = false) -> JSONValue {
    var object: [String: JSONValue] = ["url": .string(url)]
    if !headers.isEmpty { object["headers"] = .object(headers.mapValues { .string($0) }) }
    if insecure { object["insecure"] = .bool(true) }
    return .object(object)
  }

  // MARK: The file

  func testUpsertAndRemoveKeepUnknownKeysAndOtherEntries() throws {
    let dir = try tempDir()
    let url = dir.appendingPathComponent(".arnes/mcp.json")
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try """
      {"_note": "hand-written", "mcpServers": {"kept": {"command": "kept-server", "type": "stdio", "future": {"x": 1}}}}
      """.write(to: url, atomically: true, encoding: .utf8)

    var file = try MCPConfigFile.load(url)
    XCTAssertFalse(file.upsert(name: "docs", entry: http("https://mcp.example.com/mcp")), "a new name is added, not replaced")
    try file.save(to: url)
    var tree = try decoded(url)
    XCTAssertEqual(tree["_note"], .string("hand-written"), "a key arnes doesn't model survives the edit")
    XCTAssertEqual(tree["mcpServers"]?["kept"]?["future"], .object(["x": .int(1)]), "another entry's unknown key survives too")
    XCTAssertEqual(tree["mcpServers"]?["kept"]?["type"], .string("stdio"))
    XCTAssertEqual(tree["mcpServers"]?["docs"]?["url"], .string("https://mcp.example.com/mcp"))

    var again = try MCPConfigFile.load(url)
    XCTAssertTrue(again.upsert(name: "docs", entry: http("https://other.example.com/mcp")), "an existing name is replaced")
    XCTAssertTrue(again.remove(name: "kept"))
    XCTAssertFalse(again.remove(name: "never"))
    try again.save(to: url)
    tree = try decoded(url)
    XCTAssertNil(tree["mcpServers"]?["kept"])
    XCTAssertEqual(tree["mcpServers"]?["docs"]?["url"], .string("https://other.example.com/mcp"))
    XCTAssertEqual(tree["_note"], .string("hand-written"))
    // The file itself is text: sorted keys, pretty-printed, a trailing newline.
    let text = try String(contentsOf: url, encoding: .utf8)
    XCTAssertTrue(text.hasSuffix("\n"))
    XCTAssertTrue(text.contains("\n  \"mcpServers\""), text)
  }

  func testSaveIsPrivateAndAnAbsentFileIsAnEmptyDocument() throws {
    let dir = try tempDir()
    let url = dir.appendingPathComponent("home/.arnes/mcp.json")
    var file = try MCPConfigFile.load(url)
    XCTAssertTrue(file.servers.isEmpty)
    file.upsert(name: "fs", entry: stdio("fs-server"))
    try file.save(to: url)
    XCTAssertEqual(try mode(url), 0o600)
    XCTAssertEqual(try mode(url.deletingLastPathComponent()), 0o700)
    XCTAssertEqual(try decoded(url)["mcpServers"]?["fs"]?["command"], .string("fs-server"))
  }

  func testAnUnparseableFileIsRefusedAndNeverRewritten() throws {
    let dir = try tempDir()
    let url = dir.appendingPathComponent("mcp.json")
    let broken = "{\"mcpServers\": {\"fs\": {\"command\": "
    try broken.write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try MCPConfigFile.load(url)) { error in
      guard case MCPSetupError.unreadableFile(let path, _) = error else { return XCTFail("\(error)") }
      XCTAssertEqual(path, url.path)
      XCTAssertTrue("\(error)".contains("left alone"), "\(error)")
    }
    XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), broken, "the broken file is untouched")
    // A top-level array or a non-object mcpServers is a refusal too.
    try "[1, 2]".write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try MCPConfigFile.load(url))
    try #"{"mcpServers": []}"#.write(to: url, atomically: true, encoding: .utf8)
    XCTAssertThrowsError(try MCPConfigFile.load(url))
  }

  // MARK: The entry rules

  func testNameRule() throws {
    for good in ["fs", "my-server", "a_b", "Docs2", String(repeating: "x", count: 64)] {
      XCTAssertTrue(MCPEntryValidation.isValidName(good), good)
    }
    for bad in ["", "a__b", "_lead", "-lead", "has space", "dot.name", "slash/name", String(repeating: "x", count: 65), "mcp__x"] {
      XCTAssertFalse(MCPEntryValidation.isValidName(bad), bad)
    }
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "a__b", entry: stdio("x"))) { error in
      guard case MCPSetupError.invalidName("a__b") = error else { return XCTFail("\(error)") }
      XCTAssertTrue("\(error)".contains("never contains `__`"), "the refusal quotes the rule: \(error)")
    }
  }

  func testExactlyOneTransport() throws {
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: .object(["command": .string("a"), "url": .string("https://h/")]))) {
      guard case MCPSetupError.transport(let detail) = $0 else { return XCTFail("\($0)") }
      XCTAssertTrue(detail.contains("not both"), detail)
    }
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: .object(["args": .array([.string("a")])]))) {
      guard case MCPSetupError.transport(let detail) = $0 else { return XCTFail("\($0)") }
      XCTAssertTrue(detail.contains("needs a command"), detail)
    }
    // A `type` that contradicts the field present is refused; one that agrees is fine.
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: .object(["type": .string("http"), "command": .string("a")])))
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: .object(["type": .string("stdio"), "url": .string("https://h/")])))
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "x", entry: .object(["type": .string("http"), "url": .string("https://mcp.example.com/mcp")])))
    // Not an object, or not an entry.
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: .string("nope"))) {
      guard case MCPSetupError.invalidEntry = $0 else { return XCTFail("\($0)") }
    }
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: .object(["command": .int(3)]))) {
      guard case MCPSetupError.invalidEntry = $0 else { return XCTFail("\($0)") }
    }
  }

  func testURLPolicyAppliesToTheEntry() throws {
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: http("http://mcp.example.com/mcp"))) {
      guard case MCPSetupError.url(let detail) = $0 else { return XCTFail("\($0)") }
      XCTAssertTrue(detail.contains("--insecure"), detail)
    }
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "x", entry: http("http://mcp.example.com/mcp", insecure: true)))
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "x", entry: http("http://127.0.0.1:8080/mcp")))
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "x", entry: http("not a url")))
  }

  func testACommandNotOnPathIsAWarningNeverARefusal() throws {
    let validated = try MCPEntryValidation.validate(name: "x", entry: stdio("npx"), commandResolves: { _ in false })
    XCTAssertEqual(validated.warnings.count, 1)
    XCTAssertTrue(validated.warnings[0].contains("`npx` is not on PATH"), validated.warnings[0])
    XCTAssertTrue(try MCPEntryValidation.validate(name: "x", entry: stdio("npx"), commandResolves: { _ in true }).warnings.isEmpty)
    XCTAssertTrue(try MCPEntryValidation.validate(name: "x", entry: stdio("npx")).warnings.isEmpty, "nil = don't check")
  }

  func testLiteralSecretsAreRefusedUnlessAllowed() throws {
    // A vendor-shaped token in an env value.
    let envToken = stdio("gw", env: ["GATEWAY_TOKEN": "sk-or-v1-0123456789abcdef0123456789abcdef"])
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "gw", entry: envToken)) {
      guard case MCPSetupError.literalSecret(let key, let suggested) = $0 else { return XCTFail("\($0)") }
      XCTAssertEqual(key, "GATEWAY_TOKEN")
      XCTAssertEqual(suggested, "${GATEWAY_TOKEN}")
      let text = "\($0)"
      XCTAssertTrue(text.contains("looks like a secret"), text)
      XCTAssertTrue(text.contains("--allow-literal"), text)
      XCTAssertFalse(text.contains("0123456789abcdef"), "the refusal never echoes the value: \(text)")
    }
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "gw", entry: envToken, allowLiteral: true))
    // A credential header with a literal value is refused by its name alone; a template passes.
    XCTAssertThrowsError(try MCPEntryValidation.validate(
      name: "docs", entry: http("https://mcp.example.com/mcp", headers: ["Authorization": "Bearer abc"]))) {
      guard case MCPSetupError.literalSecret(let key, let suggested) = $0 else { return XCTFail("\($0)") }
      XCTAssertEqual(key, "header Authorization")
      XCTAssertEqual(suggested, "${AUTHORIZATION}")
    }
    XCTAssertThrowsError(try MCPEntryValidation.validate(
      name: "docs", entry: http("https://mcp.example.com/mcp", headers: ["X-Api-Key": "plain-looking"])))
    XCTAssertNoThrow(try MCPEntryValidation.validate(
      name: "docs", entry: http("https://mcp.example.com/mcp", headers: ["Authorization": "Bearer ${DOCS_TOKEN}"])))
    XCTAssertNoThrow(try MCPEntryValidation.validate(
      name: "docs", entry: http("https://mcp.example.com/mcp", headers: ["Accept": "application/json"])),
      "a plain header is not a credential")
    // A `TOKEN=` env whose value is a real-looking literal is refused; a template or a path is not.
    XCTAssertThrowsError(try MCPEntryValidation.validate(name: "gw", entry: stdio("gw", env: ["API_TOKEN": "abcd1234efgh5678"])))
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "gw", entry: stdio("gw", env: ["API_TOKEN": "${API_TOKEN}"])))
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "gw", entry: stdio("gw", env: ["CONFIG_PATH": "/etc/gw/config.yaml"])))
    XCTAssertNoThrow(try MCPEntryValidation.validate(name: "gw", entry: stdio("gw", env: ["LOG_LEVEL": "debug"])))
  }

  func testTemplateAndSuggestionHelpers() {
    XCTAssertTrue(MCPEntryValidation.isTemplate("${X}"))
    XCTAssertTrue(MCPEntryValidation.isTemplate("Bearer ${TOKEN}"))
    XCTAssertFalse(MCPEntryValidation.isTemplate("${unterminated"))
    XCTAssertFalse(MCPEntryValidation.isTemplate("$X"))
    XCTAssertEqual(MCPEntryValidation.suggestedTemplate(for: "X-Api-Key"), "${X_API_KEY}")
    XCTAssertEqual(MCPEntryValidation.suggestedTemplate(for: "gateway token"), "${GATEWAY_TOKEN}")
    XCTAssertEqual(MCPEntryValidation.suggestedTemplate(for: "1st"), "${MCP_1ST}")
    XCTAssertTrue(MCPEntryValidation.isCredentialHeader("authorization"))
    XCTAssertTrue(MCPEntryValidation.isCredentialHeader("X-Auth-Token"))
    XCTAssertFalse(MCPEntryValidation.isCredentialHeader("Content-Type"))
  }

  // MARK: The project file in resolve

  private func repo(with project: String) throws -> URL {
    let root = try tempDir()
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
    try project.write(to: root.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
    return root
  }

  func testProjectEntriesAreForcedUntrustedNeverRequiredAndNeverOverTheUsers() throws {
    let dir = try tempDir()
    let home = dir.appendingPathComponent("home-mcp.json")
    try #"{"mcpServers": {"shared": {"command": "from-home"}, "mine": {"command": "mine-server"}}}"#
      .write(to: home, atomically: true, encoding: .utf8)
    let root = try repo(with: """
      {"mcpServers": {
        "shared": {"command": "from-repo"},
        "repo": {"command": "repo-server", "required": true, "trust": "trusted"},
        "quiet": {"url": "https://mcp.example.com/mcp", "trust": "untrusted"}
      }}
      """)
    let project = try XCTUnwrap(MCPConfig.projectURL(for: root))

    let resolution = try MCPConfig.resolved(environment: [:], homeURL: home, project: project)
    let servers = try XCTUnwrap(resolution.config?.mcpServers)
    XCTAssertEqual(servers.keys.sorted(), ["mine", "quiet", "repo", "shared"])
    XCTAssertEqual(servers["shared"]?.command, "from-home", "the user's entry wins")
    XCTAssertFalse(servers["shared"]?.isUntrusted ?? true, "the user's entry keeps its own posture")
    XCTAssertTrue(servers["repo"]?.isUntrusted ?? false, "trust: trusted in a project file is still untrusted")
    XCTAssertFalse(servers["repo"]?.isRequired ?? true, "a project entry is never required")
    XCTAssertTrue(servers["quiet"]?.isUntrusted ?? false)
    XCTAssertEqual(resolution.projectServers, ["repo", "quiet"], "the shadowed entry is not a project server any more")
    XCTAssertEqual(resolution.notices.count, 2, resolution.notices.description)
    XCTAssertTrue(resolution.notices.contains { $0.contains("mcp repo:") && $0.contains("required: true") && $0.contains("ignored") }, resolution.notices.description)
    XCTAssertTrue(resolution.notices.contains { $0.contains("mcp shared:") && $0.contains("shadowed by") }, resolution.notices.description)
    XCTAssertEqual(resolution.sources, [project.path, home.path], "lowest precedence first")
  }

  func testStrictIgnoresTheProjectFileAndTheFlagWinsOverBoth() throws {
    let dir = try tempDir()
    let home = dir.appendingPathComponent("home-mcp.json")
    try #"{"mcpServers": {"shared": {"command": "from-home"}}}"#.write(to: home, atomically: true, encoding: .utf8)
    let root = try repo(with: #"{"mcpServers": {"shared": {"command": "from-repo"}, "repo": {"command": "repo-server"}}}"#)
    let project = try XCTUnwrap(MCPConfig.projectURL(for: root))
    let named = dir.appendingPathComponent("named.json")
    try #"{"mcpServers": {"repo": {"command": "from-flag", "required": true}}}"#.write(to: named, atomically: true, encoding: .utf8)

    // --strict-mcp-config: only what the flag names, the project file included in the drop.
    let strict = try MCPConfig.resolved(explicit: named.path, strict: true, environment: [:], homeURL: home, project: project)
    XCTAssertEqual(strict.config?.mcpServers.keys.sorted(), ["repo"])
    XCTAssertEqual(strict.config?.mcpServers["repo"]?.command, "from-flag")
    XCTAssertTrue(strict.projectServers.isEmpty)
    XCTAssertNil(try MCPConfig.resolve(strict: true, environment: [:], homeURL: home, project: project))

    // --mcp-config over the ambient file over the project file: the flag's entry is the user's,
    // so it keeps `required` and is not untrusted; the project's copy is shadowed with a notice.
    let flagged = try MCPConfig.resolved(explicit: named.path, environment: [:], homeURL: home, project: project)
    XCTAssertEqual(flagged.config?.mcpServers.keys.sorted(), ["repo", "shared"])
    XCTAssertEqual(flagged.config?.mcpServers["repo"]?.command, "from-flag")
    XCTAssertTrue(flagged.config?.mcpServers["repo"]?.isRequired ?? false)
    XCTAssertFalse(flagged.config?.mcpServers["repo"]?.isUntrusted ?? true)
    XCTAssertTrue(flagged.projectServers.isEmpty)
    XCTAssertTrue(flagged.notices.contains { $0.contains("mcp repo:") && $0.contains("--mcp-config") }, flagged.notices.description)
    XCTAssertEqual(flagged.sources.last, named.path)
  }

  func testWithoutAProjectFileResolveIsThePreX9Resolution() throws {
    let dir = try tempDir()
    let home = dir.appendingPathComponent("home-mcp.json")
    try #"{"mcpServers": {"home": {"command": "home-server"}}}"#.write(to: home, atomically: true, encoding: .utf8)
    let plain = try MCPConfig.resolved(environment: [:], homeURL: home)
    XCTAssertEqual(plain.config?.mcpServers.keys.sorted(), ["home"])
    XCTAssertTrue(plain.notices.isEmpty)
    XCTAssertTrue(plain.projectServers.isEmpty)
    XCTAssertEqual(plain.sources, [home.path])
    // A project path that doesn't exist is the same as none.
    let absent = try MCPConfig.resolved(environment: [:], homeURL: home, project: dir.appendingPathComponent("nope/.mcp.json"))
    XCTAssertEqual(absent.config?.mcpServers.keys.sorted(), ["home"])
    XCTAssertTrue(absent.notices.isEmpty)
    // A project file that doesn't parse costs a notice, never the user's servers.
    let root = try repo(with: "{not json")
    let broken = try MCPConfig.resolved(environment: [:], homeURL: home, project: MCPConfig.projectFileURL(for: root))
    XCTAssertEqual(broken.config?.mcpServers.keys.sorted(), ["home"])
    XCTAssertEqual(broken.notices.count, 1)
    XCTAssertTrue(broken.notices[0].contains("is invalid"), broken.notices[0])
  }

  func testProjectFileIsFoundAtTheRepositoryRootAndSummariesCarryNoSecret() throws {
    let root = try repo(with: """
      {"mcpServers": {
        "docs": {"url": "https://mcp.example.com/v1/mcp?token=SECRET-QUERY", "headers": {"Authorization": "Bearer SECRET-HEADER"}},
        "fs": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"]}
      }}
      """)
    let sub = root.appendingPathComponent("src/deep")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    XCTAssertEqual(MCPConfig.projectFileURL(for: sub).path, root.appendingPathComponent(".mcp.json").path, "a subdirectory shares the root's file")
    XCTAssertEqual(MCPConfig.projectURL(for: sub)?.path, root.appendingPathComponent(".mcp.json").path)
    XCTAssertNil(MCPConfig.projectURL(for: try tempDir()), "no file, no URL")
    // A directory under no marker is its own project.
    let loose = try tempDir()
    XCTAssertEqual(MCPConfig.projectFileURL(for: loose).path, loose.appendingPathComponent(".mcp.json").path)

    let summaries = MCPConfig.projectServers(in: sub)
    XCTAssertEqual(summaries.map(\.name), ["docs", "fs"])
    XCTAssertEqual(summaries[0].transport, "http mcp.example.com")
    XCTAssertEqual(summaries[1].transport, "stdio npx -y @modelcontextprotocol/server-filesystem /tmp")
    for summary in summaries {
      XCTAssertFalse(summary.transport.contains("SECRET"), summary.transport)
      XCTAssertFalse(summary.transport.contains("/v1/mcp"), "never a URL path: \(summary.transport)")
    }
    // ProjectContent lists them and the phrase counts them; a repository with only a .mcp.json
    // is project content (the trust prompt fires for it).
    let content = ProjectContent.discover(workdir: sub, home: try tempDir())
    XCTAssertEqual(content.mcpServers.map(\.name), ["docs", "fs"])
    XCTAssertFalse(content.isEmpty)
    XCTAssertEqual(content.describe(), "2 MCP servers")
  }
}
