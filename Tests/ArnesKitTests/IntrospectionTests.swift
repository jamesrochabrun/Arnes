import OpenRouterSwift
import XCTest
@testable import ArnesKit

/// X8's one Kit-level contract: what `Session.renderedSystemPrompt()` returns is the system
/// message the next request carries — the string `arnes debug prompt` prints can't drift
/// from the request, whatever the configuration contributes (instructions, extra sections,
/// a prompt-contributing tool, the suffix).
final class IntrospectionTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-introspection-\(UUID().uuidString).jsonl"))
  }

  private struct ListingTool: AgentTool, PromptContributing {
    let name = "listing_probe"
    let description = "A tool that also lists things in the prompt."
    let parameters: JSONValue = ["type": "object", "properties": ["q": ["type": "string"]], "required": ["q"]]
    var permission: ToolPermission { .readOnly }
    var promptSection: String { "# Probe listing\n- one\n- two" }
    func execute(arguments: [String: JSONValue]) async throws -> String { "ok" }
  }

  func testRenderedSystemPromptEqualsTheNextRequestsSystemMessage() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("ok"), Fixtures.usageChunk(cost: 0)]]
    let task = TaskTool(agents: [.general], service: mock, tools: [], store: tempStore())
    let session = Session(
      service: mock,
      tools: [ListingTool(), task],
      store: tempStore(),
      configuration: .init(
        model: "test/model",
        systemSuffix: "# Role\n\nYou review pull requests.",
        projectInstructions: "# Project rules\nAlways do X.",
        extraSystemSections: ["# Environment\nWorking directory: /tmp/x"]))

    // Rendered before any request — the introspection path never sends.
    let rendered = try await session.renderedSystemPrompt()
    XCTAssertEqual(mock.requests.count, 0)
    let definitions = await session.toolDefinitions
    XCTAssertEqual(definitions.map(\.function.name), ["listing_probe", "task"])

    for try await _ in await session.send("hi") {}
    let system = try XCTUnwrap(mock.requests.first?.messages.first { $0.role == .system }?.content?.plainText)
    XCTAssertEqual(rendered, system)
    // Every contributor is in there, so the equality above is not vacuous.
    for expected in ["# Project rules", "# Environment", "# Probe listing", "# Subagents", "# Delegation", "# Role"] {
      XCTAssertTrue(rendered.contains(expected), "missing \(expected)")
    }
    // And the definitions the request carried are the ones exposed.
    XCTAssertEqual(mock.requests.first?.tools?.map(\.function.name), definitions.map(\.function.name))
  }
}
