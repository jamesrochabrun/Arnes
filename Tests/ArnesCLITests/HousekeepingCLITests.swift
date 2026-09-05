import ArgumentParser
import ArnesKit
import OpenRouterSwift
import XCTest
@testable import arnes

/// Q1 (batch 14) — the CLI halves of the housekeeping item: `arnes eval -m a -m a` runs `a` once
/// (`Eval.dedupedModels`, applied after alias resolution), and `do --panel … --effort <level>`
/// parses while a bad level is a usage error before anything connects, panel or not.
final class HousekeepingCLITests: XCTestCase {
  func testDedupedModelsKeepsTheFirstOccurrenceAndNamesEachRepeatOnce() {
    let twice = Eval.dedupedModels(["a", "a"])
    XCTAssertEqual(twice.models, ["a"])
    XCTAssertEqual(twice.duplicates, ["a"])

    let mixed = Eval.dedupedModels(["a", "b", "a", "c", "b"])
    XCTAssertEqual(mixed.models, ["a", "b", "c"], "first occurrence kept, order preserved")
    XCTAssertEqual(mixed.duplicates, ["a", "b"], "the repeated names in encounter order")

    let empty = Eval.dedupedModels([])
    XCTAssertEqual(empty.models, [])
    XCTAssertEqual(empty.duplicates, [])

    let distinct = Eval.dedupedModels(["a", "b"])
    XCTAssertEqual(distinct.models, ["a", "b"])
    XCTAssertEqual(distinct.duplicates, [], "nothing to say for a list without repeats")

    // Three of a kind is one stderr line, not two.
    XCTAssertEqual(Eval.dedupedModels(["a", "a", "a"]).duplicates, ["a"])
    // `modelEntries` itself is untouched — the split keeps repeats; the dedupe runs after
    // alias resolution, where `-m sonnet -m anthropic/…` can collide too.
    XCTAssertEqual(Eval.modelEntries(["a", "a"]), ["a", "a"])
    XCTAssertEqual(Eval.modelEntries(["a,a"]), ["a", "a"])
  }

  func testPanelParsesTheEffortDialAndABadLevelIsAUsageErrorAtParseTime() throws {
    let command = try Do.parse(["task", "--panel", "2", "--effort", "high", "--yes"])
    XCTAssertEqual(command.panel, 2)
    XCTAssertEqual(command.effort, "high")
    XCTAssertEqual(try parseEffort(command.effort), .high, "what runPanel hands PanelRunner(reasoningEffort:)")

    XCTAssertThrowsError(try Do.parse(["task", "--panel", "2", "--effort", "bogus", "--yes"])) { error in
      XCTAssertTrue(Do.message(for: error).contains("unknown effort 'bogus'"), Do.message(for: error))
    }
    // Panel or not: validate() parses the level, so the non-panel path refuses it before the
    // runtime is built too (it used to parse in run(), after connecting).
    XCTAssertThrowsError(try Do.parse(["task", "--effort", "bogus"])) { error in
      XCTAssertTrue(Do.message(for: error).contains("unknown effort 'bogus'"), Do.message(for: error))
    }
    // The valid levels still parse without --panel.
    XCTAssertEqual(try Do.parse(["task", "--effort", "none"]).effort, "none")
  }
}
