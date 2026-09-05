import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// A5 at the CLI: `arnes runs --by-agent`, `arnes sessions --agents`, and `arnes resume`
/// refusing a subagent transcript with a pointer to `sessions export`.
final class SubagentLineageCLITests: XCTestCase {
  private func tempSessions() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-lineage-cli-\(UUID().uuidString)"))
  }

  private func record(
    model: String, agent: String?, cost: Double, steps: Int, stop: StopReason, provider: String? = nil)
    -> RunRecord
  {
    var record = RunRecord(task: "t", model: model, dialect: "chat", packFamily: "generic")
    record.agent = agent
    record.costUSD = cost
    record.steps = steps
    record.stopReason = stop
    record.provider = provider
    return record
  }

  // MARK: runs --by-agent

  func testByAgentLinesGroupByModelAndAgentWithAveragesAndThePartialRate() {
    let records = [
      record(model: "lead/model", agent: nil, cost: 0.10, steps: 4, stop: .completed),
      record(model: "lead/model", agent: nil, cost: 0.30, steps: 6, stop: .completed),
      record(model: "sub/model", agent: "explore", cost: 0.02, steps: 3, stop: .completed),
      record(model: "sub/model", agent: "explore", cost: 0.04, steps: 30, stop: .maxSteps),
      record(model: "sub/model", agent: "explore", cost: 0.06, steps: 5, stop: .budget),
      record(model: "sub/model", agent: "general", cost: 0.10, steps: 2, stop: .completed),
    ]
    let lines = Runs.byAgentLines(records)
    XCTAssertEqual(lines.count, 3)
    XCTAssertTrue(lines[0].hasPrefix("lead/model · lead"), lines[0])
    XCTAssertTrue(lines[0].contains("runs=2\tavg cost=$0.2000\tavg steps=5.0\tpartial=0/2"), lines[0])
    XCTAssertTrue(lines[1].hasPrefix("sub/model · explore"), lines[1])
    XCTAssertTrue(lines[1].contains("runs=3\tavg cost=$0.0400\tavg steps=12.7\tpartial=2/3"), lines[1])
    XCTAssertTrue(lines[2].hasPrefix("sub/model · general"), lines[2])
    XCTAssertTrue(lines[2].contains("runs=1\tavg cost=$0.1000\tavg steps=2.0\tpartial=0/1"), lines[2])
    // The provider joins the key only when the history spans more than one.
    XCTAssertFalse(lines[0].contains("openrouter"))
    let mixed = records + [record(model: "sub/model", agent: "explore", cost: 0, steps: 1, stop: .completed, provider: "litellm")]
    let keyed = Runs.byAgentLines(mixed)
    XCTAssertTrue(keyed.contains { $0.hasPrefix("litellm · sub/model · explore") }, "\(keyed)")
    XCTAssertTrue(keyed.contains { $0.hasPrefix("openrouter · lead/model · lead") }, "\(keyed)")
  }

  func testPlainScoreboardIsUnchangedByLineageFields() {
    var nested = record(model: "sub/model", agent: "explore", cost: 0.02, steps: 3, stop: .maxSteps)
    nested.parentSessionId = "LEAD"
    nested.depth = 1
    nested.background = true
    let lines = Runs.scoreboardLines([nested])
    XCTAssertEqual(lines.count, 1)
    XCTAssertEqual(lines[0], "sub/model".padding(toLength: 40, withPad: " ", startingAt: 0) + " runs=1\tcost=$0.0200\tverified=n/a")
  }

  // MARK: sessions --agents

  func testAgentLinesNameTheLeadAgentModelAndMessages() {
    let when = Date(timeIntervalSince1970: 0)
    let rows = [
      SessionMeta(
        id: "AAAA1111-0000-0000-0000-000000000001", model: "sub/model", updatedAt: when, messageCount: 4,
        parent: "LEAD-0000-1111", agent: "explore", depth: 1, origin: "subagent"),
    ]
    let lines = SessionsList.agentLines(rows)
    XCTAssertEqual(lines.count, 1)
    XCTAssertTrue(lines[0].hasPrefix("AAAA1111-0000-0000-0000-000000000001  "), lines[0])
    XCTAssertTrue(lines[0].contains("  lead LEAD-000  "), lines[0])
    XCTAssertTrue(lines[0].contains("explore"), lines[0])
    XCTAssertTrue(lines[0].hasSuffix(" sub/model  4 msgs"), lines[0])
    XCTAssertEqual(SessionsList.agentLines([]).count, 1, "an empty store says so")
    XCTAssertTrue(SessionsList.agentLines([])[0].hasPrefix("no subagent transcripts yet"))
  }

  // MARK: resume refuses a subagent transcript

  func testResumeRefusesASubagentTranscriptWithAnExportHint() throws {
    let store = tempSessions()
    try store.append(.meta(id: "LEAD-0000-1111-2222", model: "m", cwd: nil), to: "LEAD-0000-1111-2222")
    let nested = store.subagentStore
    try nested.append(
      .meta(id: "BBBB1111-0000-0000-0000-000000000001", model: "m", cwd: nil,
            parent: "LEAD-0000-1111-2222", agent: "explore", depth: 1, origin: "subagent"),
      to: "BBBB1111-0000-0000-0000-000000000001")
    let leads = try store.list()

    XCTAssertThrowsError(try Resume.resolve("bbbb1111", in: leads, refusingSubagentsOf: store)) { error in
      let message = "\(error)"
      XCTAssertTrue(message.contains("is a subagent run of LEAD-000"), message)
      XCTAssertTrue(message.contains("arnes sessions export bbbb1111"), message)
    }
    // Without the store, the plain "no session matches" stays.
    XCTAssertThrowsError(try Resume.resolve("bbbb1111", in: leads)) { error in
      XCTAssertTrue("\(error)".contains("no session matches"), "\(error)")
    }
    // A lead still resolves as before.
    XCTAssertEqual(try Resume.resolve("lead", in: leads, refusingSubagentsOf: store).id, "LEAD-0000-1111-2222")

    // `sessions export`/`delete` resolve the nested transcript, in its own store.
    let (meta, resolvedStore) = try Sessions.resolve("bbbb1111", in: store)
    XCTAssertEqual(meta.id, "BBBB1111-0000-0000-0000-000000000001")
    XCTAssertEqual(resolvedStore.directory.path, nested.directory.path)
    let (lead, leadStore) = try Sessions.resolve("lead", in: store)
    XCTAssertEqual(lead.id, "LEAD-0000-1111-2222")
    XCTAssertEqual(leadStore.directory.path, store.directory.path)
    XCTAssertTrue(try store.exportMarkdown(id: lead.id).contains("id: LEAD-0000-1111-2222"))
    XCTAssertTrue(try resolvedStore.exportMarkdown(id: meta.id).contains("- agent: explore"))
  }

  func testRunsAndSessionsParseTheNewFlags() throws {
    let runs = try Runs.parse(["--by-agent"])
    XCTAssertTrue(runs.byAgent)
    XCTAssertFalse(try Runs.parse([]).byAgent)
    let list = try SessionsList.parse(["--agents"])
    XCTAssertTrue(list.agents)
    // `arnes sessions --agents` reaches the default subcommand with the flag.
    let viaDefault = try Sessions.parseAsRoot(["--agents"])
    XCTAssertTrue((viaDefault as? SessionsList)?.agents == true, "\(viaDefault)")
  }
}
