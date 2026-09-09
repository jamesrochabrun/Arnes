import XCTest
@testable import ArnesKit

final class ManualBudgetClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Double = 0
  func read() -> Double { lock.withLock { value } }
  func advance(_ seconds: Double) { lock.withLock { value += seconds } }
}

final class RunTimeBudgetTests: XCTestCase {
  func testStartIsIdempotentAndSharedWithDelegatedWork() {
    let clock = ManualBudgetClock()
    let budget = RunTimeBudget(seconds: 100, now: { clock.read() })
    budget.start()
    clock.advance(60)
    let parent = Session.Configuration(maxResponseTokens: 8192, timeBudget: budget)
    let child = parent.forSubagent(named: "helper", model: "test/model", systemSuffix: "role")
    XCTAssertTrue(child.timeBudget === budget)
    XCTAssertEqual(child.maxResponseTokens, 8192)
    child.timeBudget?.start()
    XCTAssertEqual(child.timeBudget?.remainingSeconds, 40)
    clock.advance(50)
    XCTAssertEqual(budget.remainingSeconds, 0)
  }

  func testNoticesSkipCrossedThresholdsAndDoNotFloodRequests() {
    let clock = ManualBudgetClock()
    let budget = RunTimeBudget(seconds: 100, now: { clock.read() })
    var notices = TimeBudgetNotices()
    XCTAssertTrue(notices.next(for: budget)?.contains("100 of 100") == true)
    XCTAssertNil(notices.next(for: budget))
    clock.advance(80)
    XCTAssertTrue(notices.next(for: budget)?.contains("20 of 100") == true)
    XCTAssertNil(notices.next(for: budget))
    clock.advance(15)
    XCTAssertTrue(notices.next(for: budget)?.contains("5 of 100") == true)
    clock.advance(10)
    XCTAssertTrue(notices.next(for: budget)?.contains("0 of 100") == true)
    XCTAssertNil(notices.next(for: budget))
  }
}
