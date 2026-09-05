import XCTest
@testable import arnes

final class KeyWatcherTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 1_000)

  func testKeysTypedRightAfterTypeaheadAreNotAnswers() {
    let justTyped = now.addingTimeInterval(-0.2)
    XCTAssertTrue(KeyWatcher.shouldDefer(key: "y", lastTypeaheadAt: justTyped, now: now, quiet: 1.0))
    XCTAssertTrue(KeyWatcher.shouldDefer(key: "a", lastTypeaheadAt: justTyped, now: now, quiet: 1.0))
    XCTAssertTrue(KeyWatcher.shouldDefer(key: " ", lastTypeaheadAt: justTyped, now: now, quiet: 1.0))
  }

  func testAPauseMakesTheNextKeyAnAnswer() {
    let paused = now.addingTimeInterval(-1.5)
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "y", lastTypeaheadAt: paused, now: now, quiet: 1.0))
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "y", lastTypeaheadAt: nil, now: now, quiet: 1.0), "never typed: answer immediately")
  }

  func testCancelAndControlKeysAreNeverDeferred() {
    let justTyped = now.addingTimeInterval(-0.1)
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "\u{1B}", lastTypeaheadAt: justTyped, now: now, quiet: 1.0))
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "\u{03}", lastTypeaheadAt: justTyped, now: now, quiet: 1.0))
    XCTAssertFalse(KeyWatcher.shouldDefer(key: "\u{7F}", lastTypeaheadAt: justTyped, now: now, quiet: 1.0))
  }
}
