import ArnesKit
import Foundation
import XCTest
@testable import arnes

final class SpecialistEvalCLITests: XCTestCase {
  func testExplicitAgentSetDoesNotDiscoverOrAddBuiltins() throws {
    let eval = try Eval.parse(["evals/basics", "--agents", #"{"only":{"prompt":"Read.","tools":["read_file"]}}"#])
    let agents = try eval.selectedAgents {
      XCTFail("an explicit set must not discover personal agents")
      return AgentDefinition.builtins
    }
    XCTAssertEqual(agents.map(\.name), ["only"])
    let control = try Eval.parse(["evals/basics", "--agents", "[]"])
    XCTAssertTrue(try control.selectedAgents { XCTFail("control discovered agents"); return [] }.isEmpty)
    let plain = try Eval.parse(["evals/basics"])
    XCTAssertTrue(try plain.selectedAgents { XCTFail("default discovered agents"); return [] }.isEmpty)
    let discovered = try Eval.parse(["evals/basics", "--subagents"])
    XCTAssertEqual(try discovered.selectedAgents { AgentDefinition.builtins }, AgentDefinition.builtins)
  }

  func testInvalidOrAmbiguousRoleSetsFailBeforeRunning() {
    for args in [
      ["--agents", "[]", "--subagents"],
      ["--agents", "not json"],
      ["--agents", #"{"a":{"prompt":"Read.","maxSteps":0}}"#],
      ["--agents", #"{"a":{"prompt":"Read.","permissionMode":"bypassPermissions"}}"#],
      ["--agents", #"[{"name":"a","prompt":"One."},{"name":"a","prompt":"Two."}]"#],
      ["--agents", #"{" ":{"prompt":"Read."}}"#],
      ["--agents", String(repeating: " ", count: 65_537)],
    ] {
      XCTAssertThrowsError(try Eval.parse(["evals/basics"] + args))
    }
  }

  func testCommittedRoleFileLoadsExactly() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
    let file = root.appendingPathComponent("evals/ab/agents-specialists/roles.json")
    let eval = try Eval.parse(["evals/basics", "--agents", "@" + file.path])
    XCTAssertEqual(try eval.selectedAgents().map(\.name), ["investigator", "verifier"])
  }

  func testAgentFilesRejectLinksFIFOsOversizeAndInvalidUTF8() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-eval-agent-file-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("roles.json")
    try "[]".write(to: target, atomically: true, encoding: .utf8)
    let link = root.appendingPathComponent("link.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    let fifo = root.appendingPathComponent("fifo.json")
    XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
    for file in [link, fifo] {
      XCTAssertThrowsError(try Eval.parse(["evals/basics", "--agents", "@" + file.path]))
    }
    try Data(repeating: 32, count: 65_537).write(to: target)
    XCTAssertThrowsError(try Eval.parse(["evals/basics", "--agents", "@" + target.path]))
    try Data([0xff, 0xfe]).write(to: target)
    XCTAssertThrowsError(try Eval.parse(["evals/basics", "--agents", "@" + target.path]))
  }
}
