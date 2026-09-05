import ArgumentParser
import ArnesKit
import XCTest
@testable import arnes

/// A8 at the CLI: `arnes agents apply`, the `fork` / `isolation` listing facts, and a
/// grandchild's lines in the headless text stream.
final class AgentsApplyTests: XCTestCase {
  private func tempDirectory(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-apply-\(label)-\(UUID().uuidString)")
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  // MARK: agents apply

  func testApplyParsesAndKeepsTheListingAsTheDefault() throws {
    let apply = try Agents.parseAsRoot(["apply", "/tmp/arnes-agent-x/y", "--into", "/tmp/dest", "--yes"])
    let command = try XCTUnwrap(apply as? AgentsApply)
    XCTAssertEqual(command.snapshot, "/tmp/arnes-agent-x/y")
    XCTAssertEqual(command.into, "/tmp/dest")
    XCTAssertTrue(command.yes)
    // No subcommand: the listing, exactly as before.
    XCTAssertTrue(try Agents.parseAsRoot([]) is Agents)
    // The snapshot path is required.
    XCTAssertThrowsError(try Agents.parseAsRoot(["apply"]))
  }

  func testApplyRefusesAPathOutsideTheSnapshotLayout() async throws {
    let other = try tempDirectory("other")
    try FileManager.default.createDirectory(at: other.appendingPathComponent("work"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: other.appendingPathComponent("base"), withIntermediateDirectories: true)
    var command = try XCTUnwrap(try Agents.parseAsRoot(["apply", other.path, "--yes"]) as? AgentsApply)
    do {
      try await command.run()
      XCTFail("an arbitrary directory is not an arnes snapshot")
    } catch let error as ValidationError {
      XCTAssertTrue(error.message.contains("is not an arnes agent snapshot"), error.message)
    }
  }

  func testApplyWithYesFoldsTheSnapshotIntoTheDestination() async throws {
    let tmp = try tempDirectory("tmp")
    let layout = WorkspaceSnapshot.Layout(leadId: "lead0000", runId: "run00000", temporaryDirectory: tmp)
    let destination = try tempDirectory("dest")
    try write("v1\n", to: layout.base.appendingPathComponent("a.txt"))
    try write("v2\n", to: layout.work.appendingPathComponent("a.txt"))
    try write("v1\n", to: destination.appendingPathComponent("a.txt"))
    try write("c1\n", to: layout.base.appendingPathComponent("c.txt"))
    try write("c-agent\n", to: layout.work.appendingPathComponent("c.txt"))
    try write("c-user\n", to: destination.appendingPathComponent("c.txt"))

    var command = try XCTUnwrap(
      try Agents.parseAsRoot(["apply", layout.work.path, "--into", destination.path, "--yes"]) as? AgentsApply)
    try await command.run()

    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("a.txt"), encoding: .utf8), "v2\n")
    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("c.txt"), encoding: .utf8), "c-user\n", "a conflict keeps the user's bytes")
  }

  func testApplyFormatLinesForPlanAndReport() {
    let destination = URL(fileURLWithPath: "/work/tree")
    let plan = WorkspaceSnapshot.ApplyReport(applied: ["a.txt", "sub/b.txt"], deleted: ["old.txt"], conflicts: ["c.txt"])
    XCTAssertEqual(AgentsApplyFormat.lines(plan, destination: destination, applied: false), [
      "would apply (2):",
      "  + a.txt",
      "  + sub/b.txt",
      "would delete (1):",
      "  - old.txt",
      "conflicts — changed in /work/tree since the snapshot, left as they are (1):",
      "  ! c.txt",
    ])
    XCTAssertEqual(AgentsApplyFormat.lines(plan, destination: destination, applied: true).last, "2 applied · 1 deleted · 1 conflict")
    XCTAssertEqual(
      AgentsApplyFormat.lines(WorkspaceSnapshot.ApplyReport(), destination: destination, applied: false),
      ["nothing to apply: the snapshot matches /work/tree"])
    XCTAssertEqual(
      AgentsApplyFormat.lines(WorkspaceSnapshot.ApplyReport(conflicts: ["c.txt"]), destination: destination, applied: false).last,
      "nothing to apply: every changed file conflicts")
  }

  // MARK: listing facts

  func testContextModeFacts() {
    XCTAssertEqual(AgentsFormat.contextModeFacts(for: .general), [])
    XCTAssertEqual(AgentsFormat.contextModeFacts(for: .fork), ["fork"])
    XCTAssertEqual(
      AgentsFormat.contextModeFacts(for: AgentDefinition(name: "a", description: "", body: "b", isolation: "worktree")),
      ["isolation worktree"])
    XCTAssertEqual(
      AgentsFormat.contextModeFacts(for: AgentDefinition(name: "a", description: "", body: "b", isolation: "vm")),
      ["isolation vm (not applied)"])
  }

  // MARK: nested lines

  func testHeadlessTextLinesForAGrandchild() {
    let started = AgentEvent.subagent(
      name: "helper", id: "aaaa1111",
      event: .subagentStarted(name: "leaf", id: "bbbb2222", model: "leaf/model", task: "do leaf"))
    XCTAssertEqual(HeadlessEmitter.textLine(for: started), "  ◇ [helper#aaaa1111] › leaf#bbbb2222 (leaf/model) do leaf")
    let finished = AgentEvent.subagent(
      name: "helper", id: "aaaa1111",
      event: .subagentFinished(name: "leaf", id: "bbbb2222", steps: 2, toolCalls: 1, costUSD: 0.01, resultPreview: "ok"))
    XCTAssertEqual(HeadlessEmitter.textLine(for: finished), "  ◆ [helper#aaaa1111] › leaf#bbbb2222 · 2 steps · 1 tools · $0.0100")
    let deep = AgentEvent.subagent(
      name: "helper", id: "aaaa1111",
      event: .subagent(name: "leaf", id: "bbbb2222", event: .toolCall(name: "read_file", arguments: "{}")))
    XCTAssertEqual(HeadlessEmitter.textLine(for: deep), "  ∙ [helper#aaaa1111 › leaf#bbbb2222] read_file {}")
    let blocked = AgentEvent.subagent(
      name: "helper", id: "aaaa1111",
      event: .subagentBlocked(name: "leaf", id: "bbbb2222", reason: "no leaves"))
    XCTAssertEqual(HeadlessEmitter.textLine(for: blocked), "  ⊘ [helper#aaaa1111] › leaf#bbbb2222 blocked by hook: no leaves")
  }
}
