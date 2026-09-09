import ArnesKit
import Foundation
import XCTest
@testable import arnes

final class StreamDiagnosticsCLITests: XCTestCase {
  func testOptInValidationAndRuntimePropagation() throws {
    let provider = try ProviderResolver.resolve(config: nil,
      environment: ["OPENROUTER_API_KEY": "fixture-key"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/fixture-\(UUID())"))
    XCTAssertNil(try ArnesRuntime.streamDiagnostics(environment: [:], provider: provider))
    for path in ["", "relative", "/nonexistent/fixture-\(UUID())"] {
      XCTAssertThrowsError(try ArnesRuntime.streamDiagnostics(
        environment: ["ARNES_STREAM_DIAGNOSTICS_DIR": path], provider: provider))
    }
    let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(canonical) }
    let root = URL(fileURLWithPath: String(cString: canonical))
      .appendingPathComponent("arnes-stream-cli-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: root) }
    let sink = try XCTUnwrap(ArnesRuntime.streamDiagnostics(
      environment: ["ARNES_STREAM_DIAGNOSTICS_DIR": root.path], provider: provider))
    var configuration = Session.Configuration(model: "test/model")
    ArnesRuntime(provider: provider).applyLimits(to: &configuration)
    XCTAssertNil(configuration.streamFailureDiagnostics)
    ArnesRuntime(provider: provider, streamFailureDiagnostics: sink).applyLimits(to: &configuration)
    XCTAssertNotNil(configuration.streamFailureDiagnostics)
    XCTAssertNil(configuration.maxResponseTokens)
    XCTAssertNil(configuration.timeBudget)
  }
}
