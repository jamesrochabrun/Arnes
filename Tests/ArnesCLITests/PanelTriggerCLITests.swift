import ArgumentParser
import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// P2 at the CLI: `arnes do --verify X --yes --panel-on-fail N` parses, every refusal is a usage
/// error before anything connects, `policies.panelOnVerifierFail` decodes (and an old config
/// without it round-trips byte for byte) and reaches `ArnesRuntime`, and the two pure rules — the
/// arming rule and the final-exit rule — plus the pre-run snapshot's layout. The end-to-end
/// escalation needs a live check (a `Do.run` needs a network).
final class PanelTriggerCLITests: XCTestCase {
  private func provider() throws -> ResolvedProvider {
    try ProviderResolver.resolve(
      config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
  }

  private func assertValidationError(_ arguments: [String], contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try Do.parse(arguments), arguments.joined(separator: " "), file: file, line: line) { error in
      let message = Do.message(for: error)
      XCTAssertTrue(message.contains(needle), "\(arguments.joined(separator: " ")): \(message)", file: file, line: line)
    }
  }

  // MARK: Parsing

  func testPanelOnFailParsesWithVerifyAndYes() throws {
    let command = try Do.parse(["fix it", "--verify", "haiku", "--yes", "--panel-on-fail", "2"])
    XCTAssertEqual(command.panelOnFail, 2)
    XCTAssertEqual(command.verify, "haiku")
    XCTAssertTrue(command.yes)
    XCTAssertNil(try Do.parse(["fix it", "--verify", "haiku", "--yes"]).panelOnFail, "absent = the config key decides")
    // `0` switches a configured default off and needs nothing else.
    XCTAssertEqual(try Do.parse(["fix it", "--panel-on-fail", "0"]).panelOnFail, 0)
    XCTAssertEqual(try Do.parse(["fix it", "--panel-on-fail", "0", "--safe"]).panelOnFail, 0)
    // `--session` stays allowed: the initial attempt is a real session, the candidates are not.
    XCTAssertEqual(try Do.parse(["fix it", "--verify", "haiku", "--yes", "--session", "--panel-on-fail", "3"]).panelOnFail, 3)
  }

  func testPanelOnFailRefusals() throws {
    let base = ["fix it", "--verify", "haiku", "--yes", "--panel-on-fail", "2"]
    assertValidationError(["fix it", "--yes", "--panel-on-fail", "2"], contains: "--panel-on-fail needs --verify")
    assertValidationError(["fix it", "--verify", "haiku", "--panel-on-fail", "2"], contains: "pass --yes")
    assertValidationError(base + ["--panel", "2"], contains: "--panel and --panel-on-fail don't combine")
    assertValidationError(["fix it", "--panel", "2", "--yes", "--panel-on-fail", "0"], contains: "--panel and --panel-on-fail don't combine")
    assertValidationError(base + ["--output-schema", #"{"type": "object"}"#], contains: "--panel-on-fail and --output-schema")
    assertValidationError(base + ["--resume", "abc"], contains: "--panel-on-fail and --resume/--continue/--fork")
    assertValidationError(base + ["--continue"], contains: "--panel-on-fail and --resume/--continue/--fork")
    assertValidationError(base + ["--session-id", "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"], contains: "--panel-on-fail and --session-id")
    assertValidationError(base + ["--permission-mode", "acceptEdits"], contains: "--panel-on-fail and --permission-mode")
    assertValidationError(base + ["--add-dir", "/tmp"], contains: "--panel-on-fail and --add-dir")
    assertValidationError(base + ["--safe"], contains: "--panel-on-fail and --safe")
    assertValidationError(base + ["--no-apply"], contains: "--panel-on-fail and --no-apply")
    assertValidationError(base + ["--agent", "explore"], contains: "--panel-on-fail and --agent/--agents")
    assertValidationError(base + ["--disallowed-tools", "bash"], contains: "--panel-on-fail and --agent/--agents")
    assertValidationError(base + ["--append-system-prompt", "x"], contains: "--panel-on-fail and --agent/--agents")
    assertValidationError(["fix it", "--verify", "haiku", "--yes", "--panel-on-fail", "1"], contains: "at least 2 candidates")
  }

  // MARK: The config key

  func testPoliciesConfigDecodesPanelOnVerifierFailAndAnOldConfigRoundTrips() throws {
    let set = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {"panelOnVerifierFail": 3}}"#.utf8))
    XCTAssertEqual(set.policies?.panelOnVerifierFail, 3)
    let old = #"{"adaptiveThink":false,"environmentContext":true}"#
    let decoded = try JSONDecoder().decode(PoliciesConfig.self, from: Data(old.utf8))
    XCTAssertNil(decoded.panelOnVerifierFail)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    XCTAssertEqual(String(decoding: try encoder.encode(decoded), as: UTF8.self), old, "an old config re-encodes without the key")
    XCTAssertEqual(PoliciesConfig(panelOnVerifierFail: 2), PoliciesConfig(panelOnVerifierFail: 2))
  }

  func testRuntimeCarriesThePanelOnVerifierFailKey() throws {
    XCTAssertNil(ArnesRuntime(provider: try provider()).panelOnVerifierFail, "off unless the key says so")
    XCTAssertEqual(ArnesRuntime(provider: try provider(), panelOnVerifierFail: 3).panelOnVerifierFail, 3)
    // What `make` reads: nil when the block is absent, the number when written.
    let none = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {}}"#.utf8))
    XCTAssertNil(none.policies?.panelOnVerifierFail)
  }

  // MARK: The pure rules

  func testArmingRuleNeedsVerifyAndYesAndTheFlagOutranksTheKey() {
    XCTAssertEqual(Do.panelOnFailArmed(flag: 2, policy: nil, verify: "haiku", yes: true), 2)
    XCTAssertEqual(Do.panelOnFailArmed(flag: nil, policy: 3, verify: "haiku", yes: true), 3, "the config default arms a run that verifies and runs unattended")
    XCTAssertEqual(Do.panelOnFailArmed(flag: 4, policy: 3, verify: "haiku", yes: true), 4, "the flag outranks the key")
    XCTAssertNil(Do.panelOnFailArmed(flag: 0, policy: 3, verify: "haiku", yes: true), "0 on the command line switches the key off for this run")
    XCTAssertNil(Do.panelOnFailArmed(flag: nil, policy: 0, verify: "haiku", yes: true))
    XCTAssertNil(Do.panelOnFailArmed(flag: nil, policy: 1, verify: "haiku", yes: true), "a panel needs two candidates")
    XCTAssertNil(Do.panelOnFailArmed(flag: nil, policy: nil, verify: "haiku", yes: true))
    XCTAssertNil(Do.panelOnFailArmed(flag: 2, policy: nil, verify: nil, yes: true), "nothing to trigger on without a verifier")
    XCTAssertNil(Do.panelOnFailArmed(flag: 2, policy: nil, verify: "haiku", yes: false), "candidates run unattended — --yes is the consent")
    XCTAssertNil(Do.panelOnFailArmed(flag: nil, policy: 3, verify: nil, yes: false), "a run without both never escalates from the key")
  }

  func testFinalExitRuleIsTheReVerificationsVerdict() {
    XCTAssertEqual(Do.panelOnFailExit(reverified: true, panelError: false), ArnesExit.ok.rawValue, "re-verify PASS → 0 whatever the first run said")
    XCTAssertEqual(Do.panelOnFailExit(reverified: false, panelError: false), ArnesExit.verifierFailed.rawValue)
    XCTAssertEqual(Do.panelOnFailExit(reverified: nil, panelError: false), ArnesExit.verifierFailed.rawValue, "applied but unverified: the FAIL stands")
    XCTAssertEqual(Do.panelOnFailExit(reverified: nil, panelError: true), ArnesExit.verifierFailed.rawValue, "no winner: the original FAIL stands")
    XCTAssertEqual(Do.panelOnFailExit(reverified: true, panelError: true), ArnesExit.verifierFailed.rawValue, "a panel error is never rescued")
  }

  func testFirstRosterEntryIsTheInitialAttemptsModel() {
    XCTAssertEqual(Do.firstRosterEntry("deepseek,haiku"), "deepseek")
    XCTAssertEqual(Do.firstRosterEntry("haiku"), "haiku")
    // Each roster entry is alias-resolved on its own (the whole comma string is no alias).
    let aliases = ["deepseek": "vendor/deepseek-x", "haiku": "vendor/haiku-y"]
    let resolve: (String) -> String = { aliases[$0] ?? $0 }
    XCTAssertEqual(Do.rosterModels("deepseek,haiku", resolve: resolve), ["vendor/deepseek-x", "vendor/haiku-y"])
    XCTAssertEqual(Do.rosterModels(" deepseek , vendor/other ,", resolve: resolve), ["vendor/deepseek-x", "vendor/other"])
    XCTAssertEqual(Do.rosterModels("haiku", resolve: resolve), ["vendor/haiku-y"])
    XCTAssertEqual(Do.rosterModels("vendor/full-id", resolve: resolve), ["vendor/full-id"])
  }

  // MARK: The pre-run snapshot

  func testPreRunSnapshotClonesTheTreeIntoAnAgentsApplyLayoutAndRemoveLayoutSweepsIt() throws {
    let temp = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-panel-trigger-cli-\(UUID().uuidString)").resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let cwd = temp.appendingPathComponent("cwd")
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    try "original".write(to: cwd.appendingPathComponent("state.txt"), atomically: true, encoding: .utf8)

    guard case .success(let layout) = Do.preRunSnapshot(of: cwd, leadId: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8") else {
      return XCTFail("the snapshot should succeed")
    }
    defer { Do.removeLayout(layout) }
    XCTAssertTrue(layout.directory.deletingLastPathComponent().lastPathComponent.hasPrefix("arnes-agent-6ba7b810"),
                  "named after the run's session id: \(layout.directory.path)")
    XCTAssertEqual(try String(contentsOf: layout.base.appendingPathComponent("state.txt"), encoding: .utf8), "original")
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.work.path), "the failed attempt lands in `work` only when the verifier says FAIL")
    // 0700, the layout's own rule (a snapshot is a whole copy of the project).
    let mode = try FileManager.default.attributesOfItem(atPath: layout.directory.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode.map { $0 & 0o777 }, 0o700)
    // A run that never escalates removes the run directory — and the emptied parent with it.
    let parent = layout.directory.deletingLastPathComponent()
    Do.removeLayout(layout)
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.directory.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path), "an empty arnes-agent-<lead> directory goes with it")

    // A source that cannot be copied is a failure the caller warns about, and leaves nothing behind.
    guard case .failure = Do.preRunSnapshot(of: temp.appendingPathComponent("missing"), leadId: nil) else {
      return XCTFail("a missing tree cannot be snapshotted")
    }
  }

  // MARK: the status row (batch-16 housekeeping)

  func testStatusPanelOnFailRowReadsTheConfiguredDefault() throws {
    let home = "/Users/tester"
    // No key: the row says off, the JSON carries null — the trigger never arms from the config.
    let off = Status.Settings(ArnesRuntime(provider: try provider()), environment: [:], home: home, sandboxSupported: true)
    let offLines = Status.settingsLines(off)
    XCTAssertEqual(offLines.count, 15, "one row after Q2's reasoning shape")
    XCTAssertEqual(offLines[13], "reasoning shape: openrouter (provider.reasoningShape)", "the fourteen existing rows keep their place")
    XCTAssertEqual(offLines[14], "panel on fail: off (policies.panelOnVerifierFail)")
    XCTAssertNil(off.panelOnVerifierFail)

    // A configured default names the panel size `Do.panelOnFailArmed` would read.
    let armed = Status.Settings(
      ArnesRuntime(provider: try provider(), panelOnVerifierFail: 3), environment: [:], home: home, sandboxSupported: true)
    XCTAssertEqual(Status.settingsLines(armed).last, "panel on fail: 3 candidates (policies.panelOnVerifierFail)")
    XCTAssertEqual(armed.panelOnVerifierFail, 3)

    // The fact follows the arming rule: nil, 0 and 1 are off, 2 is the smallest panel.
    XCTAssertEqual(Status.panelOnFailFact(nil), "off")
    XCTAssertEqual(Status.panelOnFailFact(0), "off")
    XCTAssertEqual(Status.panelOnFailFact(1), "off")
    XCTAssertEqual(Status.panelOnFailFact(2), "2 candidates")

    // `--json` carries the value under `panel_on_verifier_fail`, always present.
    let report = StatusReport(
      provider: .init(name: "openrouter", kind: "openrouter", baseHost: "openrouter.ai", keySource: "env", defaultModel: nil),
      key: nil, credits: nil, keyError: nil,
      manifestModels: nil, manifestSource: nil, manifestFetchedAt: nil,
      subprocessEnv: StatusReport.subprocessEnv(.default),
      environmentContext: true,
      limits: StatusReport.limits(LimitsConfig()),
      paths: .init(protected: [], sensitiveWrite: [], denyRead: []),
      sandbox: StatusReport.sandbox(nil),
      judge: nil,
      toolResultFraming: armed.framing,
      adaptiveThink: armed.adaptiveThink,
      transport: StatusReport.transport(armed.transport),
      promptCache: StatusReport.promptCache(armed.cachePolicy),
      manifestCache: StatusReport.manifestCache(armed.manifestCache),
      compaction: StatusReport.compaction(armed.compaction),
      checkpoints: StatusReport.checkpoints(armed.checkpoints, root: armed.checkpointRoot),
      memory: StatusReport.memory(armed.memory, root: armed.memoryRoot),
      web: StatusReport.web(armed.web),
      subagents: StatusReport.subagents(armed.subagents),
      reasoningShape: armed.reasoningShape.rawValue,
      panelOnVerifierFail: armed.panelOnVerifierFail)
    let line = try JSONOut.line(report)
    XCTAssertTrue(line.contains(#""panel_on_verifier_fail":3"#), line)
  }
}
