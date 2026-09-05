import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// The `--mcp-config` / `--strict-mcp-config` contract: the flags exist on the commands
/// that connect servers, and they mean the same thing on each.
final class McpFlagsTests: XCTestCase {

  func testDoAcceptsAPathAndStrictMode() throws {
    let command = try Do.parse(["say hi", "--mcp-config", "/tmp/project-mcp.json", "--strict-mcp-config"])
    XCTAssertEqual(command.mcpOptions.mcpConfig, "/tmp/project-mcp.json")
    XCTAssertTrue(command.mcpOptions.strictMcpConfig)
  }

  func testInteractiveAcceptsInlineJSON() throws {
    let inline = #"{"mcpServers":{"docs":{"type":"http","url":"https://mcp.example.com/mcp"}}}"#
    let command = try Interactive.parse(["--mcp-config", inline])
    XCTAssertEqual(command.mcpOptions.mcpConfig, inline)
    XCTAssertFalse(command.mcpOptions.strictMcpConfig)
    // The value the flag carries is what MCPConfig.parse consumes.
    let parsed = try MCPConfig.parse(XCTUnwrap(command.mcpOptions.mcpConfig))
    XCTAssertEqual(parsed.mcpServers["docs"]?.transport, .http)
  }

  func testMcpListingTakesTheSameFlags() throws {
    let command = try XCTUnwrap(try Mcp.parseAsRoot(["--strict-mcp-config"]) as? McpStatus)
    XCTAssertNil(command.mcpOptions.mcpConfig)
    XCTAssertTrue(command.mcpOptions.strictMcpConfig)
  }

  func testDefaultsLeaveTodaysBehaviorAlone() throws {
    let command = try Do.parse(["say hi"])
    XCTAssertNil(command.mcpOptions.mcpConfig)
    XCTAssertFalse(command.mcpOptions.strictMcpConfig)
  }
}
