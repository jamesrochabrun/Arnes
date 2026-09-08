import ArnesKit
import Foundation
import XCTest
@testable import arnes

final class CommandDiagnosticsCLITests: XCTestCase {
  func testRuntimeAppliesExplicitPoliciesWithoutChangingDefaults() throws {
    let provider = try ProviderResolver.resolve(config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID())"))
    var configuration = Session.Configuration(model: "test/model")
    ArnesRuntime(provider: provider).applyLimits(to: &configuration)
    XCTAssertFalse(configuration.commandDiagnostics)
    XCTAssertFalse(configuration.compaction.preserveCommandEvidence)
    ArnesRuntime(provider: provider,
      compaction: .init(keepRecentToolTokens: 2_000, preserveCommandEvidence: true),
      commandDiagnostics: true).applyLimits(to: &configuration)
    XCTAssertTrue(configuration.commandDiagnostics)
    XCTAssertTrue(configuration.compaction.preserveCommandEvidence)
    let child = configuration.forSubagent(named: "worker", model: "test/model", systemSuffix: "Work.")
    XCTAssertEqual(child.compaction, configuration.compaction)
    XCTAssertTrue(child.commandDiagnostics)
  }
}
