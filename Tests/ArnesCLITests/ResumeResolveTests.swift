import ArnesKit
import XCTest
@testable import arnes

final class ResumeResolveTests: XCTestCase {
  private let sessions = [
    SessionMeta(id: "abc123", name: "demo", updatedAt: Date(timeIntervalSince1970: 300), messageCount: 4),
    SessionMeta(id: "abd456", name: nil, updatedAt: Date(timeIntervalSince1970: 200), messageCount: 2),
    SessionMeta(id: "xyz789", name: "Fix-Parser", updatedAt: Date(timeIntervalSince1970: 100), messageCount: 6),
  ]

  func testNilQueryPicksMostRecent() throws {
    XCTAssertEqual(try Resume.resolve(nil, in: sessions).id, "abc123")
  }

  func testExactIdWins() throws {
    XCTAssertEqual(try Resume.resolve("abd456", in: sessions).id, "abd456")
  }

  func testUniquePrefixMatches() throws {
    XCTAssertEqual(try Resume.resolve("xyz", in: sessions).id, "xyz789")
  }

  func testNameMatchesCaseInsensitively() throws {
    XCTAssertEqual(try Resume.resolve("fix-parser", in: sessions).id, "xyz789")
  }

  func testAmbiguousPrefixThrows() {
    XCTAssertThrowsError(try Resume.resolve("ab", in: sessions))
  }

  func testNoMatchThrows() {
    XCTAssertThrowsError(try Resume.resolve("nope", in: sessions))
  }
}
