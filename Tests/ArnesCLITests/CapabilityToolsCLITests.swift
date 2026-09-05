import XCTest
@testable import ArnesKit
@testable import arnes

/// T5 at the CLI seam: the config's `web` block reaches the toolset through the runtime, and the
/// `models --json` rows say which models take images.
final class CapabilityToolsCLITests: XCTestCase {
  private func runtime(web: WebConfig?) throws -> ArnesRuntime {
    let provider = try ProviderResolver.resolve(
      config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
    return ArnesRuntime(provider: provider, web: web)
  }

  func testWebFetchRidesTheToolsetOnlyWhenTheConfigHasAWebBlock() throws {
    let without = try runtime(web: nil)
    XCTAssertNil(without.webPolicy)
    XCTAssertFalse(HarnessAssembly.coreTools(ToolContext(web: without.webPolicy)).contains { $0.name == "web_fetch" })

    let with = try runtime(web: WebConfig(allowedDomains: ["docs.swift.org"], maxBytes: 4096))
    let policy = try XCTUnwrap(with.webPolicy)
    XCTAssertEqual(policy.allowedDomains, ["docs.swift.org"])
    XCTAssertEqual(policy.maxBytes, 4096)
    let tools = HarnessAssembly.coreTools(ToolContext(jobs: with.jobRegistry(), web: with.webPolicy))
    XCTAssertEqual(
      tools.map(\.name),
      ["read_file", "write_file", "edit_file", "bash", "job", "grep", "glob", "view_image", "web_fetch", "update_plan", "think", "ask_user"])
    // The config decodes the block like every other top-level block; an absent one is nil.
    let decoded = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"web": {"deniedDomains": ["pastebin.com"]}}"#.utf8))
    XCTAssertEqual(decoded.web?.policy.deniedDomains, ["pastebin.com"])
    XCTAssertNil(try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"limits": {}}"#.utf8)).web)
  }

  func testModelRowCarriesSupportsVision() throws {
    let vision = ModelProfile(
      id: "acme/vision", contextLength: 128_000, supportsTools: true, supportsReasoning: false,
      supportsStructuredOutputs: false, promptPricePerToken: nil, completionPricePerToken: nil,
      supportsVision: true)
    XCTAssertEqual(
      try JSONOut.line([ModelRow(vision)]),
      #"[{"completion_price_per_token":null,"context_length":128000,"dialect":"chat","family":"other","id":"acme/vision","prompt_price_per_token":null,"supports_reasoning":false,"supports_structured_outputs":false,"supports_tools":true,"supports_vision":true}]"#)
  }
}
