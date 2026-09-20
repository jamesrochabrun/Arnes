import Foundation
import OpenRouterSwift
import XCTest
@testable import arnes

final class DecideCommandTests: XCTestCase {
  /// A live jev-1.13 response captured 2026-09-19, verbatim.
  private static let fixture = """
    {"model": "typesafe/jev-1.13-20260917",
     "answers": {
       "is_urgent": {"type": "noul", "noul": 0.95},
       "department": {"type": "choice", "choice": "billing",
         "probabilities": {"technical": 0.13, "sales": 0, "billing": 0.87},
         "confidence": 0.81},
       "frustration": {"type": "score", "score": 1.03,
         "legend": {"0": "Calm", "1": "Frustrated", "2": "Very angry"},
         "probabilities": {"0": 0, "1": 0.97, "2": 0.03},
         "confidence": 0.95}},
     "usage": {"input_tokens": 427, "output_tokens": 73, "cost": 1.7934e-05},
     "id": "gen-dec-1789861418-EyPx7n1GoXKOwem2hN6m",
     "provider": "TypeSafe"}
    """

  private func decodedFixture() throws -> DecisionResponse {
    try JSONDecoder().decode(DecisionResponse.self, from: Data(Self.fixture.utf8))
  }

  // MARK: Questions parsing

  func testLoadQuestionsInlineJSON() throws {
    let questions = try Decide.loadQuestions(
      #"{"urgent": {"type": "noul", "instructions": "Urgent?"}, "anger": {"type": "score", "instructions": "How angry?", "criteria": ["Calm", "Angry"]}}"#,
      relativeTo: URL(fileURLWithPath: "/tmp"))
    XCTAssertEqual(questions.count, 2)
    XCTAssertEqual(questions["urgent"]?.type, .noul)
    XCTAssertEqual(questions["anger"]?.type, .score)
    if case .levels(let levels)? = questions["anger"]?.criteria {
      XCTAssertEqual(levels, ["Calm", "Angry"])
    } else {
      XCTFail("score criteria should parse as ordered levels")
    }
  }

  func testLoadQuestionsFromFile() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("decide-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("questions.json")
    try Data(#"{"team": {"type": "choice", "criteria": {"a": "A things", "b": "B things"}}}"#.utf8)
      .write(to: file)

    let questions = try Decide.loadQuestions("questions.json", relativeTo: dir)
    XCTAssertEqual(questions["team"]?.type, .choice)
    if case .labeled(let options)? = questions["team"]?.criteria {
      XCTAssertEqual(options, ["a": "A things", "b": "B things"])
    } else {
      XCTFail("choice criteria should parse as labeled options")
    }
  }

  func testLoadQuestionsRefusesEmptyAndMissing() {
    XCTAssertThrowsError(try Decide.loadQuestions("{}", relativeTo: URL(fileURLWithPath: "/tmp")))
    XCTAssertThrowsError(try Decide.loadQuestions("no-such-file.json", relativeTo: URL(fileURLWithPath: "/tmp")))
  }

  // MARK: State parsing

  func testParseState() throws {
    XCTAssertEqual(try Decide.parseState("plain text", asJSON: false), .string("plain text"))
    XCTAssertEqual(
      try Decide.parseState(#"{"ticket": "prod down"}"#, asJSON: true),
      .object(["ticket": .string("prod down")]))
    XCTAssertThrowsError(try Decide.parseState("not json", asJSON: true))
  }

  // MARK: Text view

  func testLinesRenderEveryAnswerTypeSortedAndCapped() throws {
    let lines = Decide.lines(for: try decodedFixture(), requested: "typesafe/jev-1.13")
    XCTAssertEqual(lines.count, 5)
    XCTAssertEqual(lines[0], "decision from typesafe/jev-1.13-20260917 (TypeSafe):")
    // Answers sorted by question name; the choice distribution highest-probability first.
    XCTAssertEqual(lines[1], "  department   choice → billing (p=0.87, confidence 0.81)  [billing=0.87 · technical=0.13 · sales=0.00]")
    XCTAssertEqual(lines[2], "  frustration  score  → 1.03 ≈ Frustrated (confidence 0.95)  [Calm=0.00 · Frustrated=0.97 · Very angry=0.03]")
    XCTAssertEqual(lines[3], "  is_urgent    noul   → P(yes) = 0.95")
    XCTAssertEqual(lines[4], "[$0.000018 · 427 in / 73 out]")
  }

  func testSummaryIsCompactAndSorted() throws {
    XCTAssertEqual(
      Decide.summary(of: try decodedFixture()),
      "department=billing · frustration=1.03 · is_urgent=0.95")
  }

  // MARK: /decide argument split

  func testDecideArgumentsBraceMatchesInlineJSON() {
    // Nested braces and a brace inside a JSON string must not end the questions early.
    let split = SlashCommand.decideArguments(
      #"{"q": {"type": "noul", "instructions": "weird } brace"}} Payouts failing {for} 3 days"#)
    XCTAssertEqual(split?.questions, #"{"q": {"type": "noul", "instructions": "weird } brace"}}"#)
    XCTAssertEqual(split?.state, "Payouts failing {for} 3 days")
  }

  func testDecideArgumentsFilePathForm() {
    let split = SlashCommand.decideArguments("  questions.json   Payouts failing for 3 days ")
    XCTAssertEqual(split?.questions, "questions.json")
    XCTAssertEqual(split?.state, "Payouts failing for 3 days")

    let missingState = SlashCommand.decideArguments("questions.json")
    XCTAssertEqual(missingState?.questions, "questions.json")
    XCTAssertNil(missingState?.state)

    XCTAssertNil(SlashCommand.decideArguments(nil))
    XCTAssertNil(SlashCommand.decideArguments("   "))
  }

  func testDecideArgumentsUnbalancedJSONComesBackWhole() {
    // The questions parser owns the error message; the split must not guess.
    let split = SlashCommand.decideArguments(#"{"q": {"type": "noul" state text"#)
    XCTAssertEqual(split?.questions, #"{"q": {"type": "noul" state text"#)
    XCTAssertNil(split?.state)
  }

  func testDecideSlashCommandParsesAndExpandsPastes() {
    XCTAssertEqual(
      SlashCommand.parse("/decide q.json is this urgent"),
      .decide(argument: "q.json is this urgent"))
    let expanded = SlashCommand.expandingPastes(
      .decide(argument: "[Pasted text #1 +3 lines] state"),
      with: { $0.replacingOccurrences(of: "[Pasted text #1 +3 lines]", with: #"{"q": {"type": "noul"}}"#) })
    XCTAssertEqual(expanded, .decide(argument: #"{"q": {"type": "noul"}} state"#))
  }

  func testDecideIsListedInHelpAndCompletion() {
    XCTAssertTrue(SlashCommand.helpText.contains("/decide <questions> <state>"))
    XCTAssertTrue(SlashCompletion.builtins.contains { $0.name == "/decide" })
  }

  // MARK: The agent's notice

  func testNoticeCarriesStateAndTheFullRenderedAnswer() throws {
    let notice = Decide.notice(
      state: "Help! My payouts have been failing for 3 days.",
      response: try decodedFixture(),
      requested: "typesafe/jev-1.13")
    XCTAssertTrue(notice.contains("The user ran /decide"))
    XCTAssertTrue(notice.contains("state: Help! My payouts have been failing for 3 days."))
    // The same lines the UI printed, so agent and user read one answer.
    for line in Decide.lines(for: try decodedFixture(), requested: "typesafe/jev-1.13") {
      XCTAssertTrue(notice.contains(line), "notice should carry: \(line)")
    }
  }

  // MARK: --json document

  func testDecisionDocumentLineIsStable() throws {
    let document = DecisionDocument(requested: "typesafe/jev-1.13", response: try decodedFixture())
    let line = try JSONOut.line(document)
    XCTAssertTrue(line.hasPrefix(#"{"answers":"#))
    XCTAssertTrue(line.contains(#""type":"decision""#))
    XCTAssertTrue(line.contains(#""requested":"typesafe/jev-1.13""#))
    XCTAssertTrue(line.contains(#""model":"typesafe/jev-1.13-20260917""#))
    XCTAssertTrue(line.contains(#""noul":0.95"#))
    XCTAssertTrue(line.contains(#""choice":"billing""#))
    XCTAssertTrue(line.contains(#""legend":{"0":"Calm","1":"Frustrated","2":"Very angry"}"#))
    XCTAssertTrue(line.contains(#""input_tokens":427"#))
    // Absent per-answer fields stay absent (a noul has no probabilities key at all).
    XCTAssertFalse(line.contains(#""is_urgent":{"choice""#))
  }
}
