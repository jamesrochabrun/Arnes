import ArgumentParser
import XCTest
@testable import arnes

/// A6 — `arnes eval --subagents`: opt-in, so a suite that never asked for the task tool is
/// measured with exactly the toolset and prompt it always had.
final class EvalSubagentsFlagTests: XCTestCase {
  func testSubagentsFlagIsOffByDefaultAndParses() throws {
    let plain = try Eval.parse(["evals/basics"])
    XCTAssertFalse(plain.subagents)
    let on = try Eval.parse(["evals/subagents", "--subagents", "-m", "test/model"])
    XCTAssertTrue(on.subagents)
    XCTAssertEqual(on.models, ["test/model"])
    // Combines with the other trial knobs; none of them refuses it.
    let combined = try Eval.parse(["evals/subagents", "--subagents", "--no-sandbox", "--dialect", "chat", "--trust-project"])
    XCTAssertTrue(combined.subagents)
    XCTAssertTrue(combined.noSandbox)
    XCTAssertTrue(combined.trustProject)
  }
}
