import OpenRouterSwift
import XCTest
@testable import ArnesKit

/// C6 — introspection and dials: `Session.contextReport()` sizes the system prompt by
/// contributor (the same sections `systemText` joins), the history by role and the tool
/// definitions; the estimates scale to the last request's real prompt tokens; the section names
/// follow the headings; `setExtraSystemSections` re-renders a block without rebuilding the
/// session; `setBudget` moves the ceiling the loop checks.
final class ContextReportTests: XCTestCase {
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-context-\(UUID().uuidString).jsonl"))
  }

  private struct ListingTool: AgentTool, PromptContributing {
    let name = "listing_probe"
    let description = "A tool that also lists things in the prompt."
    let parameters: JSONValue = ["type": "object", "properties": ["q": ["type": "string"]], "required": ["q"]]
    var permission: ToolPermission { .readOnly }
    var promptSection: String { "# Probe listing\n- one\n- two" }
    func execute(arguments: [String: JSONValue]) async throws -> String { "ok" }
  }
  // MARK: Sections

  func testPromptSectionsAreTheSystemPromptContributorsAndSumToItsBytes() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 100_000))
    let session = Session(
      service: mock,
      tools: [ListingTool()],
      store: tempStore(),
      configuration: .init(
        model: "test/model",
        systemSuffix: "# Role\n\nYou review pull requests.",
        projectInstructions: "# Project rules\nAlways do X.",
        extraSystemSections: ["# Environment\nWorking directory: /tmp/x", "no heading here"]))

    let report = try await session.contextReport()
    let prompt = report.sections.filter { $0.kind == .prompt }
    XCTAssertEqual(
      prompt.map(\.name),
      ["pack", "project instructions", "Environment", "extra section 2", "Probe listing", "Role"])
    // The sections are exactly what the request's system message is made of: their bytes plus
    // the "\n\n" joiners equal the rendered prompt.
    let rendered = try await session.renderedSystemPrompt()
    XCTAssertEqual(prompt.reduce(0) { $0 + $1.bytes } + 2 * (prompt.count - 1), rendered.utf8.count)
    for section in prompt {
      XCTAssertEqual(section.count, 0)
      XCTAssertEqual(section.estTokens, section.bytes / ContextReport.bytesPerToken, section.name)
    }
    // No request yet: unscaled, the window known from the manifest.
    XCTAssertNil(report.lastPromptTokens)
    XCTAssertFalse(report.scaledToLastRequest)
    XCTAssertEqual(report.contextLength, 100_000)
    XCTAssertEqual(report.compactionThreshold, 0.8, accuracy: 0.0001)
    // The tool definitions row counts the one tool and weighs its encoded definition.
    let tools = try XCTUnwrap(report.sections.first { $0.kind == .tools })
    XCTAssertEqual(tools.count, 1)
    XCTAssertGreaterThan(tools.bytes, 0)
    XCTAssertEqual(mock.requests.count, 0, "sizing sends nothing")
  }

  func testHistoryRowsCountMessagesByRoleAndScaleToTheLastPromptTokens() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model", contextLength: 8000))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "listing_probe", arguments: #"{"q":"x"}"#), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0, promptTokens: 1234)],
    ]
    let session = Session(
      service: mock, tools: [ListingTool()], store: tempStore(), configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("go"))

    let report = try await session.contextReport()
    let history = report.sections.filter { $0.kind == .history }
    XCTAssertEqual(history.map(\.name), ["user", "assistant", "tool"])
    XCTAssertEqual(history.map(\.count), [1, 2, 1], "one user turn, the tool-call step and the reply, one tool result")
    XCTAssertEqual(history[0].bytes, "go".utf8.count)
    XCTAssertGreaterThan(history[1].bytes, 0, "the tool call's name and arguments count as assistant bytes")
    // The last request reported 1234 prompt tokens: every estimate is a share of exactly that.
    XCTAssertEqual(report.lastPromptTokens, 1234)
    XCTAssertTrue(report.scaledToLastRequest)
    XCTAssertEqual(report.totalEstTokens, 1234)
    XCTAssertEqual(report.contextPercent, 1234 * 100 / 8000)
    let byBytes = report.sections.sorted { $0.bytes > $1.bytes }
    XCTAssertGreaterThanOrEqual(byBytes[0].estTokens, byBytes.last!.estTokens, "proportional to bytes")
  }

  func testScalingSumsExactlyAndFallsBackToBytesPerToken() {
    XCTAssertEqual(ContextReport.scaled([400, 40, 8], toTotal: nil), [100, 10, 2])
    XCTAssertEqual(ContextReport.scaled([1, 1, 1], toTotal: 100).reduce(0, +), 100)
    XCTAssertEqual(ContextReport.scaled([1, 1, 1], toTotal: 100), [34, 33, 33])
    XCTAssertEqual(ContextReport.scaled([300, 100], toTotal: 8), [6, 2])
    XCTAssertEqual(ContextReport.scaled([0, 0], toTotal: 50), [0, 0], "nothing to apportion")
    XCTAssertEqual(ContextReport.scaled([], toTotal: 50), [])
  }

  func testSectionNameReadsTheHeadingOrFallsBack() {
    XCTAssertEqual(Session.sectionName("# Environment\n- a", fallback: "x"), "Environment")
    XCTAssertEqual(Session.sectionName("## Skills", fallback: "x"), "Skills")
    XCTAssertEqual(Session.sectionName("#   \nbody", fallback: "x"), "x", "an empty heading is no name")
    XCTAssertEqual(Session.sectionName("plain text", fallback: "x"), "x")
    XCTAssertEqual(Session.sectionName("", fallback: "x"), "x")
  }

  // MARK: setExtraSystemSections

  func testSetExtraSystemSectionsReplacesTheBlockInTheNextRequest() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("a"), Fixtures.usageChunk(cost: 0)],
      [Fixtures.textChunk("b"), Fixtures.usageChunk(cost: 0)],
    ]
    let session = Session(
      service: mock, tools: [], store: tempStore(),
      configuration: .init(model: "test/model", extraSystemSections: ["# Environment\n- Model: old"]))
    _ = try await Events.drain(await session.send("one"))
    await session.setExtraSystemSections(["# Environment\n- Model: new", "# Memory\n- remember"])
    let sections = await session.currentExtraSystemSections
    XCTAssertEqual(sections.count, 2)
    _ = try await Events.drain(await session.send("two"))

    let first = mock.requests[0].messages.first { $0.role == .system }?.content?.plainText ?? ""
    let second = mock.requests[1].messages.first { $0.role == .system }?.content?.plainText ?? ""
    XCTAssertTrue(first.contains("- Model: old"))
    XCTAssertFalse(first.contains("# Memory"))
    XCTAssertTrue(second.contains("- Model: new"))
    XCTAssertFalse(second.contains("- Model: old"))
    XCTAssertTrue(second.contains("# Memory\n- remember"))
    // The report names the new sections too.
    let names = try await session.contextReport().sections.filter { $0.kind == .prompt }.map(\.name)
    XCTAssertEqual(names, ["pack", "Environment", "Memory"])
    // The configuration itself is untouched — it is the seed, not the live value.
    XCTAssertEqual(session.configuration.extraSystemSections, ["# Environment\n- Model: old"])
  }

  /// A refresh of the `# Environment` block (the REPL's after /model, /permissions, /effort) swaps
  /// only that section: a `# Memory` block or an embedder's section sharing the array survives.
  func testReplacingBlockKeepsEveryOtherSection() {
    let old = "# Environment\n- Model: old"
    let new = EnvironmentContext.heading + "\n- Model: new"
    let memory = "# Memory\n- remember this"
    let plain = "no heading here"
    XCTAssertEqual(
      EnvironmentContext.replacingBlock(in: [old, memory, plain], with: new), [new, memory, plain],
      "replaced in place, the rest untouched")
    XCTAssertEqual(
      EnvironmentContext.replacingBlock(in: [memory, old], with: new), [memory, new],
      "wherever the embedder put it")
    XCTAssertEqual(
      EnvironmentContext.replacingBlock(in: [memory], with: new), [new, memory],
      "absent: inserted first, the memory block kept")
    XCTAssertEqual(EnvironmentContext.replacingBlock(in: [], with: new), [new])
    XCTAssertEqual(EnvironmentContext.replacingBlock(in: [old], with: new), [new])
    // The block is recognized by its own heading line, nothing looser.
    XCTAssertTrue(EnvironmentContext.isBlock(old))
    XCTAssertTrue(EnvironmentContext.isBlock(EnvironmentContext.heading))
    XCTAssertFalse(EnvironmentContext.isBlock("# Environment notes\n- x"))
    XCTAssertFalse(EnvironmentContext.isBlock("## Environment\n- x"))
    XCTAssertFalse(EnvironmentContext.isBlock(memory))
    XCTAssertFalse(EnvironmentContext.isBlock(plain))
    // `render` opens with that heading, so a rendered block is what `replacingBlock` finds.
    let rendered = EnvironmentContext.render(
      cwd: URL(fileURLWithPath: "/tmp/x"), os: "macOS 15", date: "2026-01-01", git: nil,
      model: "test/model", permissionMode: .default, sandbox: nil, effort: nil)
    XCTAssertTrue(EnvironmentContext.isBlock(rendered))
    XCTAssertEqual(Session.sectionName(rendered, fallback: "x"), "Environment", "the /context name agrees")
  }

  // MARK: setBudget

  func testSetBudgetMovesTheCeilingTheLoopChecks() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.textChunk("a"), Fixtures.usageChunk(cost: 0.05)],
      [Fixtures.textChunk("b"), Fixtures.usageChunk(cost: 0.05)],
    ]
    let session = Session(
      service: mock, tools: [], store: tempStore(),
      configuration: .init(model: "test/model", maxCostUSD: 0.01))
    let seeded = await session.currentBudgetUSD
    XCTAssertEqual(seeded, 0.01)
    _ = try await Events.drain(await session.send("one")) // $0.05 spent: the next turn would stop at once
    let stopped = try await Events.drain(await session.send("two"))
    XCTAssertTrue(stopped.contains { if case .budgetReached = $0 { return true } else { return false } })
    XCTAssertEqual(mock.requests.count, 1, "the second turn was refused by the $0.01 ceiling")

    await session.setBudget(1.0) // lifted: the loop reads the live dial, not the configuration
    let lifted = await session.currentBudgetUSD
    XCTAssertEqual(lifted, 1.0)
    let ran = try await Events.drain(await session.send("three"))
    XCTAssertFalse(ran.contains { if case .budgetReached = $0 { return true } else { return false } })
    XCTAssertEqual(mock.requests.count, 2)
    XCTAssertEqual(session.configuration.maxCostUSD, 0.01, "the configuration stays the seed")
    await session.setBudget(nil)
    let cleared = await session.currentBudgetUSD
    XCTAssertNil(cleared)
  }

  // MARK: lastDialectUsed

  func testLastDialectUsedIsTheRecordsDialect() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("a"), Fixtures.usageChunk(cost: 0)]]
    let session = Session(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    let before = await session.lastDialectUsed
    XCTAssertNil(before)
    _ = try await Events.drain(await session.send("one"))
    let after = await session.lastDialectUsed
    XCTAssertEqual(after, "chat")
  }
}
