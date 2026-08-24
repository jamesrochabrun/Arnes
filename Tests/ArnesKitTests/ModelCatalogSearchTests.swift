import XCTest
@testable import ArnesKit

final class ModelCatalogSearchTests: XCTestCase {
  private func catalog() -> ModelCatalog {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "anthropic/claude-sonnet-5"),
      Fixtures.manifestModel(id: "anthropic/claude-haiku-4.5"),
      Fixtures.manifestModel(id: "openai/gpt-5.2"),
      Fixtures.manifestModel(id: "openrouter/auto"))
    return ModelCatalog(service: mock)
  }

  func testExactIdRanksFirst() async throws {
    let results = try await catalog().search("openrouter/auto")
    XCTAssertEqual(results.first?.id, "openrouter/auto")
  }

  func testSubstringMatch() async throws {
    let results = try await catalog().search("sonnet")
    XCTAssertEqual(results.map(\.id), ["anthropic/claude-sonnet-5"])
  }

  func testSubsequenceMatch() async throws {
    let results = try await catalog().search("son5")
    XCTAssertEqual(results.first?.id, "anthropic/claude-sonnet-5")
  }

  func testNoMatchReturnsEmpty() async throws {
    let results = try await catalog().search("zzzzzz")
    XCTAssertTrue(results.isEmpty)
  }

  func testAllIsSortedById() async throws {
    let all = try await catalog().all()
    XCTAssertEqual(all.map(\.id), all.map(\.id).sorted())
    XCTAssertEqual(all.count, 4)
  }
}
