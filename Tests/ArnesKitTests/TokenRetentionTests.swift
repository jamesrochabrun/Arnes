import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class TokenRetentionTests: XCTestCase {
  private func result(_ length: Int, id: String) -> Message {
    .tool(String(repeating: "x", count: length), toolCallId: id)
  }

  func testBudgetRetainsMoreSmallResultsAndFewerLargeResults() {
    let small = (0..<10).map { result(40, id: "\($0)") }
    let policy = CompactionPolicy(keepRecentToolTokens: 80)
    XCTAssertEqual(Microcompaction.clearingCutoff(in: small, policy: policy), 2)
    let large = (0..<10).map { result(160, id: "\($0)") }
    XCTAssertEqual(Microcompaction.clearingCutoff(in: large, policy: policy), 8)
  }

  func testLatestOversizedResultAndUserObjectiveSurvive() {
    let history: [Message] = [.user("Keep compatibility; verify the migration."),
      result(10_000, id: "old"), result(10_000, id: "latest")]
    let policy = CompactionPolicy(clearMinChars: 1, keepRecentToolTokens: 100)
    let cutoff = Microcompaction.clearingCutoff(in: history, policy: policy)
    XCTAssertEqual(cutoff, 2)
    let view = Microcompaction.view(of: history, clearedBelow: cutoff, policy: policy)
    XCTAssertEqual(view[0].content?.plainText, history[0].content?.plainText)
    XCTAssertEqual(view[2].content?.plainText, history[2].content?.plainText)
    XCTAssertTrue(view[1].content?.plainText.contains("cleared") == true)
    XCTAssertEqual(history[1].content?.plainText.count, 10_000)
  }

  func testOldConfigKeepsDefaultAndNewConfigRoundTrips() throws {
    let old = try JSONDecoder().decode(CompactionConfig.self, from: Data(#"{"threshold":0.8}"#.utf8))
    XCTAssertNil(old.keepRecentToolTokens)
    XCTAssertEqual(old.policy, .default)
    let config = CompactionConfig(keepRecentToolTokens: 12_000)
    XCTAssertEqual(try JSONDecoder().decode(CompactionConfig.self, from: JSONEncoder().encode(config)), config)
    XCTAssertEqual(config.policy.keepRecentToolTokens, 12_000)
    XCTAssertEqual(CompactionPolicy(keepRecentToolTokens: -1).keepRecentToolTokens, 0)
  }

  func testAbsentBudgetPreservesCountRuleAndZeroKeepsNone() {
    let history = (0..<10).map { result(40, id: "\($0)") }
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history, policy: .default), 4)
    XCTAssertEqual(Microcompaction.clearingCutoff(in: history,
      policy: .init(keepRecentToolTokens: 0)), history.count)
  }
}
