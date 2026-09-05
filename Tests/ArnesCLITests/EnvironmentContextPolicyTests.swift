import ArnesKit
import XCTest
@testable import arnes

/// `policies.environmentContext` reaches the runners through one value: every CLI site passes
/// `runtime.environmentFacts(sandbox:)` straight through, so nil here is no block anywhere.
final class EnvironmentContextPolicyTests: XCTestCase {
  private func runtime(config: ArnesConfig?) throws -> ArnesRuntime {
    let provider = try ProviderResolver.resolve(
      config: config,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
    return ArnesRuntime(
      provider: provider,
      environmentContextEnabled: EnvironmentContext.isEnabled(in: config),
      skillListingMaxBytes: config?.policies?.skillListingBytes ?? SkillTool.defaultListingMaxBytes)
  }

  func testSkillListingCapComesFromPoliciesAndDefaultsOtherwise() throws {
    XCTAssertEqual(try runtime(config: nil).skillListingMaxBytes, SkillTool.defaultListingMaxBytes)
    XCTAssertEqual(
      try runtime(config: ArnesConfig(policies: PoliciesConfig(skillListingBytes: 1024))).skillListingMaxBytes, 1024)
    // The key decodes beside `environmentContext`, and an absent key leaves the default.
    let decoded = try JSONDecoder().decode(
      ArnesConfig.self, from: Data(#"{"policies": {"skillListingBytes": 0}}"#.utf8))
    XCTAssertEqual(decoded.policies?.skillListingBytes, 0)
    XCTAssertNil(decoded.policies?.environmentContext)
    let absent = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {}}"#.utf8))
    XCTAssertNil(absent.policies?.skillListingBytes)
  }

  func testOptOutMakesTheFactsNilAndAbsentConfigLeavesThemOn() throws {
    let off = try runtime(config: ArnesConfig(policies: PoliciesConfig(environmentContext: false)))
    XCTAssertFalse(off.environmentContextEnabled)
    XCTAssertNil(off.environmentFacts(sandbox: nil))
    XCTAssertNil(off.environmentFacts(sandbox: ShellSandbox(writableRoots: [URL(fileURLWithPath: "/work")])))

    let on = try runtime(config: nil)
    XCTAssertTrue(on.environmentContextEnabled)
    let sandbox = ShellSandbox(writableRoots: [URL(fileURLWithPath: "/work")], allowNetwork: false)
    let facts = try XCTUnwrap(on.environmentFacts(sandbox: sandbox))
    XCTAssertEqual(facts.sandbox, sandbox, "the run's sandbox is what the block (and its git probe) get")
    XCTAssertEqual(facts.os, EnvironmentContext.platform())
    XCTAssertEqual(facts.date, EnvironmentContext.today())
  }
}
