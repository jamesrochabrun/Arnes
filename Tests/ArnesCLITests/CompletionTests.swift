import ArnesKit
import XCTest
@testable import arnes

/// Slash-command autocomplete (the pure pieces LineReader drives) and the `/models` command:
/// candidate list, activation, live filtering, the popup rows, and the model list's format.
final class CompletionTests: XCTestCase {
  // MARK: Candidates

  func testItemsAppendSkillsAndPromptsAfterBuiltins() {
    let items = SlashCompletion.items(skills: ["zeta", "init"], prompts: ["mcp__gh__review"])
    let names = items.map(\.name)
    XCTAssertEqual(names.prefix(SlashCompletion.builtins.count), SlashCompletion.builtins.map(\.name)[...])
    XCTAssertTrue(names.contains("/init"))
    XCTAssertTrue(names.contains("/zeta"))
    XCTAssertTrue(names.contains("/mcp__gh__review"))
    // Skills come sorted, after the built-ins.
    XCTAssertLessThan(names.firstIndex(of: "/init")!, names.firstIndex(of: "/zeta")!)
    XCTAssertGreaterThan(names.firstIndex(of: "/init")!, names.firstIndex(of: "/exit")!)
  }

  func testItemsDropSkillsShadowedByBuiltins() {
    // Dispatch runs the built-in for a colliding name, so the popup must not list it twice.
    let items = SlashCompletion.items(skills: ["model", "Status", "mine"], prompts: [])
    let names = items.map(\.name)
    XCTAssertEqual(names.filter { $0.lowercased() == "/model" }.count, 1)
    XCTAssertEqual(names.filter { $0.lowercased() == "/status" }.count, 1)
    XCTAssertTrue(names.contains("/mine"))
  }

  // MARK: Activation

  func testQueryActivatesOnlyForALoneSlashToken() {
    XCTAssertNil(SlashCompletion.query(for: "hello"))
    XCTAssertNil(SlashCompletion.query(for: ""))
    XCTAssertNil(SlashCompletion.query(for: "/model sonnet")) // arguments underway
    XCTAssertNil(SlashCompletion.query(for: "/a\tb"))
    XCTAssertEqual(SlashCompletion.query(for: "/"), "")
    XCTAssertEqual(SlashCompletion.query(for: "/mo"), "mo")
    XCTAssertEqual(SlashCompletion.query(for: "  /MoD"), "mod") // leading spaces, any case
  }

  // MARK: Filtering

  func testMatchesRankExactThenPrefixThenSubstring() {
    let items = [
      SlashCompletion.Item(name: "/memory", hint: ""),
      SlashCompletion.Item(name: "/model", hint: ""),
      SlashCompletion.Item(name: "/models", hint: ""),
    ]
    XCTAssertEqual(SlashCompletion.matches(for: "/model", in: items).map(\.name), ["/model", "/models"])
    XCTAssertEqual(SlashCompletion.matches(for: "/models", in: items).map(\.name), ["/models"])
    XCTAssertEqual(SlashCompletion.matches(for: "/m", in: items).map(\.name), ["/memory", "/model", "/models"])
    XCTAssertEqual(SlashCompletion.matches(for: "/em", in: items).map(\.name), ["/memory"]) // substring
    XCTAssertEqual(SlashCompletion.matches(for: "/", in: items).count, 3) // bare slash = everything
    XCTAssertTrue(SlashCompletion.matches(for: "/zzz", in: items).isEmpty)
    XCTAssertTrue(SlashCompletion.matches(for: "not a command", in: items).isEmpty)
  }

  func testAcceptedAppendsASpaceForArguments() {
    XCTAssertEqual(SlashCompletion.accepted(SlashCompletion.Item(name: "/model", hint: "")), "/model ")
  }

  // MARK: Popup rows

  func testLinesHighlightTheSelectionAndWindowLongLists() {
    let items = (0..<10).map { SlashCompletion.Item(name: "/cmd\($0)", hint: "hint \($0)") }
    let top = SlashCompletion.lines(matches: items, selected: 0)
    XCTAssertEqual(top.count, SlashCompletion.maxVisible + 1) // window + "… more" tail
    XCTAssertTrue(top[0].contains("❯"))
    XCTAssertTrue(top[0].contains("/cmd0"))
    XCTAssertTrue(top[1].hasPrefix("  "))
    XCTAssertTrue(top.last!.contains("more"))

    // A deep selection scrolls the window; both edges say what's beyond them.
    let deep = SlashCompletion.lines(matches: items, selected: 8)
    XCTAssertTrue(deep.contains { $0.contains("❯") && $0.contains("/cmd8") })
    XCTAssertTrue(deep.first!.contains("more"))
    XCTAssertTrue(deep.last!.contains("more"))

    XCTAssertTrue(SlashCompletion.lines(matches: [], selected: 0).isEmpty)
  }

  // MARK: /models

  func testParseModelsCommand() {
    guard case .models(nil)? = SlashCommand.parse("/models") else { return XCTFail("/models") }
    guard case .models("sonnet")? = SlashCommand.parse("/models sonnet") else { return XCTFail("/models sonnet") }
    guard case .model("sonnet")? = SlashCommand.parse("/model sonnet") else { return XCTFail("/model untouched") }
    XCTAssertTrue(SlashCommand.helpText.contains("/models"))
    XCTAssertTrue(SlashCommand.helpText.contains("tab"))
  }

  func testModelsLineMarksTheCurrentModel() {
    let profile = ModelProfile(unknownModelId: "test/model")
    let current = Interactive.modelsLine(profile, current: "test/model")
    XCTAssertTrue(current.contains("test/model"))
    XCTAssertTrue(current.contains("(current)"))
    let other = Interactive.modelsLine(profile, current: "other/model")
    XCTAssertTrue(other.hasPrefix("  "))
    XCTAssertFalse(other.contains("(current)"))
  }
}
