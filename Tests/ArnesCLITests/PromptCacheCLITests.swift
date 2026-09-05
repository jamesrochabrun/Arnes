import ArnesKit
import XCTest
@testable import arnes

/// C7 — the cached-token metric in the CLI: the REPL footer's ` · cache N%` segment (only when
/// something was cached), the `arnes runs` `cache=` column (only when some shown run cached
/// anything), the `--json` row's sums, and the runtime's `policies.promptCache` plumbing.
final class PromptCacheCLITests: XCTestCase {
  private final class Capture {
    var lines: [String] = []
  }

  private func renderer() -> (Renderer, Capture) {
    let capture = Capture()
    let renderer = Renderer(lineSink: { capture.lines.append($0) })
    return (renderer, capture)
  }

  private func stats(cached: Int?, total: Int?) -> Session.TurnStats {
    Session.TurnStats(
      steps: 2, toolCalls: 1, turnCostUSD: 0.01, sessionCostUSD: 0.02, requestedModel: "m",
      routedModels: [], promptTokens: 1200, contextLength: 8000, durationSeconds: 1.5,
      cachedPromptTokens: cached, totalPromptTokens: total)
  }

  private func record(model: String, cost: Double = 0.01, promptTokens: Int? = nil, cachedTokens: Int? = nil) -> RunRecord {
    var record = RunRecord(task: "t", model: model, dialect: "chat", packFamily: "generic")
    record.costUSD = cost
    record.finished = true
    record.promptTokens = promptTokens
    record.cachedTokens = cachedTokens
    return record
  }

  // MARK: Footer

  func testFooterAppendsTheCacheShareOnlyWhenSomethingWasCached() {
    let (renderer, capture) = renderer()
    renderer.render(.turnFinished(stats(cached: nil, total: 2200)))
    renderer.render(.turnFinished(stats(cached: 0, total: 2200)))
    renderer.render(.turnFinished(stats(cached: 1700, total: nil)))
    renderer.render(.turnFinished(stats(cached: 1700, total: 2200)))
    XCTAssertEqual(capture.lines.count, 4)
    let plain = "─ m · 2 steps · 1 tools · 1.5s · turn $0.0100 · session $0.0200 · ctx 15%"
    // Nothing cached, or no denominator: the footer it always printed, byte for byte.
    XCTAssertEqual(capture.lines[0], plain)
    XCTAssertEqual(capture.lines[1], plain)
    XCTAssertEqual(capture.lines[2], plain)
    XCTAssertEqual(capture.lines[3], plain + " · cache 77%")
  }

  func testCacheSegmentIsPureAndClamped() {
    XCTAssertNil(Renderer.cacheSegment(cached: nil, total: 100))
    XCTAssertNil(Renderer.cacheSegment(cached: 0, total: 100))
    XCTAssertNil(Renderer.cacheSegment(cached: 10, total: nil))
    XCTAssertNil(Renderer.cacheSegment(cached: 10, total: 0))
    XCTAssertEqual(Renderer.cacheSegment(cached: 50, total: 200), " · cache 25%")
    XCTAssertEqual(Renderer.cacheSegment(cached: 300, total: 200), " · cache 100%", "never over 100")
  }

  // MARK: arnes runs

  func testScoreboardIsByteIdenticalWhenNothingWasCached() {
    let records = [
      record(model: "a/model", promptTokens: 1000),
      record(model: "a/model", promptTokens: 1000, cachedTokens: 0),
      record(model: "b/model"),
    ]
    XCTAssertEqual(Runs.scoreboardLines(records), [
      "a/model                                  runs=2\tcost=$0.0200\tverified=n/a",
      "b/model                                  runs=1\tcost=$0.0100\tverified=n/a",
    ])
  }

  func testScoreboardGrowsTheCacheColumnWhenARunCachedSomething() {
    let records = [
      record(model: "a/model", promptTokens: 1000, cachedTokens: 700),
      record(model: "a/model", promptTokens: 1000),
      record(model: "b/model"),
    ]
    XCTAssertEqual(Runs.scoreboardLines(records), [
      "a/model                                  runs=2\tcost=$0.0200\tverified=n/a\tcache=35%",
      "b/model                                  runs=1\tcost=$0.0100\tverified=n/a\tcache=n/a",
    ])
    // The rate is over the runs that reported prompt tokens; an unreported run adds nothing.
    XCTAssertEqual(Runs.cacheRate([record(model: "m", promptTokens: 400, cachedTokens: 100), record(model: "m")]), "25%")
    XCTAssertEqual(Runs.cacheRate([record(model: "m")]), "n/a")
  }

  func testScoreboardRowsCarryTheTokenSums() throws {
    let rows = Runs.scoreboardRows([
      record(model: "a/model", promptTokens: 1000, cachedTokens: 700),
      record(model: "a/model", promptTokens: 200),
    ])
    XCTAssertEqual(rows.count, 1)
    XCTAssertEqual(rows[0].promptTokens, 1200)
    XCTAssertEqual(rows[0].cachedTokens, 700)
    let line = try JSONOut.line(rows)
    XCTAssertTrue(line.contains(#""cached_tokens":700"#), line)
    XCTAssertTrue(line.contains(#""prompt_tokens":1200"#), line)
  }

  // MARK: Runtime

  func testApplyLimitsSetsTheConfiguredCachePolicy() throws {
    let provider = try ProviderResolver.resolve(
      config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
    let runtime = ArnesRuntime(provider: provider, cachePolicy: CachePolicy(anthropicBreakpoints: false, ttl: "1h"))
    XCTAssertTrue(runtime.traits.supportsCacheControl, "OpenRouter takes the field")
    var configuration = Session.Configuration(model: "m")
    XCTAssertEqual(configuration.cachePolicy, .default)
    runtime.applyLimits(to: &configuration)
    XCTAssertEqual(configuration.cachePolicy, CachePolicy(anthropicBreakpoints: false, ttl: "1h"))
    // The default runtime leaves the built-in discipline: breakpoints on.
    var fresh = Session.Configuration(model: "m")
    ArnesRuntime(provider: provider).applyLimits(to: &fresh)
    XCTAssertEqual(fresh.cachePolicy, .default)
  }
}
