import XCTest
import ArnesKit
@testable import arnes

final class ACPCommandTests: XCTestCase {
  func testIsolatedRuntimeUsesOnlyItsConfigCacheAndSpillRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-acp-runtime-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("config.json")
    let config = ArnesConfig(provider: "fixture", providers: ["fixture": .init(kind: .openaiCompatible,
      baseURL: "http://127.0.0.1:1/v1", apiKey: "offline-fixture", defaultModel: "test/model")],
      sessions: .init(retentionDays: 1), policies: .init(commandDiagnostics: true))
    try JSONEncoder().encode(config).write(to: file)
    let runtime = try ArnesRuntime.make(provider: "fixture", stateDirectory: root)
    XCTAssertEqual(runtime.provider.name, "fixture")
    XCTAssertEqual(runtime.manifestCache?.directory, root.appendingPathComponent("models"))
    XCTAssertEqual(runtime.spillScope.root, root.appendingPathComponent("tmp"))
    XCTAssertTrue(runtime.commandDiagnostics)
    var disabled = config
    disabled.policies = .init(manifestCache: .init(enabled: false))
    try JSONEncoder().encode(disabled).write(to: file)
    XCTAssertNil(try ArnesRuntime.make(provider: "fixture", stateDirectory: root).manifestCache)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["config.json"],
      "runtime construction does not create state or start retention sweeps")
  }

  func testFlagsAndDefaults() throws {
    let defaults = try ACPCommand.parse([])
    XCTAssertEqual(defaults.maxSteps, 100)
    XCTAssertEqual(defaults.budget, 5)
    let command = try ACPCommand.parse(["-m", "test/model", "--effort", "high",
      "--max-steps", "42", "--budget", "2.5", "--provider", "gateway", "--state-directory", "/tmp/acp-state"])
    XCTAssertEqual(command.model, "test/model")
    XCTAssertEqual(command.effort, "high")
    XCTAssertEqual(command.maxSteps, 42)
    XCTAssertEqual(command.budget, 2.5)
    XCTAssertEqual(command.providerOptions.provider, "gateway")
    XCTAssertEqual(command.stateDirectory, "/tmp/acp-state")
    XCTAssertNil(defaults.stateDirectory)
  }
  func testRefusesInvalidLimitsAndDoesNotOfferBypass() {
    for arguments in [["--max-steps", "0"], ["--budget", "-1"], ["--budget", "nan"],
                      ["--effort", "invalid"], ["--yes"], ["--permission-mode", "bypass"],
                      ["--state-directory", "relative"]] {
      XCTAssertThrowsError(try ACPCommand.parse(arguments), "\(arguments)")
    }
  }
}
