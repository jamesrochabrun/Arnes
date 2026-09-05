import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class BudgetTests: XCTestCase {
  /// A throwaway record store so tests never append to the real ~/.arnes/runs.jsonl
  /// (NSHomeDirectory ignores $HOME).
  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-budget-runs-\(UUID().uuidString).jsonl"))
  }

  func testLoopStopsWhenBudgetReached() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    // Step 1 calls a (free, readOnly) tool and costs $0.01; the pre-step budget check on the
    // next iteration then sees cost ≥ budget and stops before spending more.
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "t1", name: "think", arguments: #"{"thought":"considering"}"#),
       Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [ThinkTool()],
      store: tempStore(),
      configuration: .init(model: "test/model", maxCostUSD: 0.005))

    var sawBudget = false
    for try await event in await session.send("go") {
      if case .budgetReached(let spent, let budget) = event {
        sawBudget = true
        XCTAssertEqual(spent, 0.01, accuracy: 0.0001)
        XCTAssertEqual(budget, 0.005, accuracy: 0.0001)
      }
    }
    XCTAssertTrue(sawBudget, "the budget stop should have fired")
    // Only the first step ran — the loop didn't request a second completion.
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testNoBudgetRunsNormally() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)]]
    let session = Session(service: mock, tools: [], store: tempStore(), configuration: .init(model: "test/model"))
    var sawBudget = false
    for try await event in await session.send("go") {
      if case .budgetReached = event { sawBudget = true }
    }
    XCTAssertFalse(sawBudget, "no budget configured → never fires")
  }
}
