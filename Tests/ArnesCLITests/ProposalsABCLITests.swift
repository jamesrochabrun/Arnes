import ArgumentParser
import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// P1 at the CLI: `arnes eval --adaptive-think` / `--label` (parsed, the label validated),
/// `evals show`/`evals prune --label`, `policies.adaptiveThink` reaching every session through
/// `ArnesRuntime.applyLimits`, and the `label` key on the `--json` outcome rows.
final class ProposalsABCLITests: XCTestCase {
  private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private func provider() throws -> ResolvedProvider {
    try ProviderResolver.resolve(
      config: nil,
      environment: ["OPENROUTER_API_KEY": "sk-or-test"],
      credentialsURL: URL(fileURLWithPath: "/nonexistent/arnes-credentials-\(UUID().uuidString)"))
  }

  // MARK: arnes eval flags

  func testEvalFlagsParseAndTheLabelIsValidated() throws {
    let plain = try Eval.parse(["evals/basics"])
    XCTAssertFalse(plain.adaptiveThink)
    XCTAssertNil(plain.label)
    let armed = try Eval.parse([
      "evals/basics", "-m", "test/model", "-t", "2", "--effort", "medium", "--adaptive-think", "--label", "think-B",
    ])
    XCTAssertTrue(armed.adaptiveThink)
    XCTAssertEqual(armed.label, "think-B")
    XCTAssertEqual(armed.effort, "medium")
    XCTAssertEqual(armed.trials, 2)
    // A label is a short word: letters, digits, `.`, `_`, `-`; 1–40 characters. Refused at parse time.
    for good in ["a", "control", "no-think.v2", "s6_out", String(repeating: "x", count: 40)] {
      XCTAssertNoThrow(try Eval.parse(["evals/basics", "--label", good]), good)
      XCTAssertTrue(Eval.isValidLabel(good), good)
    }
    for bad in ["", "with space", "a/b", String(repeating: "x", count: 41), "arm!", "think:A", "über"] {
      XCTAssertThrowsError(try Eval.parse(["evals/basics", "--label", bad]), "'\(bad)' must be refused") { error in
        XCTAssertTrue("\(error)".contains("--label"), "\(error)")
      }
      XCTAssertFalse(Eval.isValidLabel(bad), bad)
    }
    // The other refusals still come first-class beside it.
    XCTAssertThrowsError(try Eval.parse(["evals/basics", "--label", "ok", "--parallel", "0"]))
  }

  func testEvalsShowAndPruneTakeALabelFilter() throws {
    let show = try EvalsShow.parse(["--suite", "basics", "--label", "think-A", "--json"])
    XCTAssertEqual(show.label, "think-A")
    XCTAssertEqual(show.suite, "basics")
    XCTAssertTrue(show.json)
    XCTAssertNil(try EvalsShow.parse([]).label)
    let prune = try EvalsPrune.parse(["--label", "think-C"])
    XCTAssertEqual(prune.label, "think-C")
    XCTAssertFalse(prune.all)
    XCTAssertNil(try EvalsPrune.parse(["--suite", "panel"]).label)
  }

  // MARK: policies.adaptiveThink → every CLI session

  func testRuntimeCarriesAdaptiveThinkIntoEverySessionConfiguration() throws {
    let plain = ArnesRuntime(provider: try provider())
    XCTAssertTrue(plain.adaptiveThink, "on unless the key says false (the batch-13 A/B)")
    var configuration = Session.Configuration(model: "test/model")
    XCTAssertTrue(configuration.adaptiveThink, "the Kit default moved with it")
    plain.applyLimits(to: &configuration)
    XCTAssertTrue(configuration.adaptiveThink, "what `do` and the REPL hand their session")
    // A subagent inherits it through the one derivation point.
    XCTAssertTrue(configuration.forSubagent(named: "explore", model: "test/model", systemSuffix: "role").adaptiveThink)

    let off = ArnesRuntime(provider: try provider(), adaptiveThink: false)
    XCTAssertFalse(off.adaptiveThink)
    off.applyLimits(to: &configuration)
    XCTAssertFalse(configuration.adaptiveThink, "`policies.adaptiveThink: false` keeps the tool for every model")
    XCTAssertFalse(configuration.forSubagent(named: "explore", model: "test/model", systemSuffix: "role").adaptiveThink)

    // The key `make` reads, decoded: nil = the default (on), false = off.
    let none = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {}}"#.utf8))
    XCTAssertEqual(none.policies?.adaptiveThink ?? true, true)
    let set = try JSONDecoder().decode(ArnesConfig.self, from: Data(#"{"policies": {"adaptiveThink": false}}"#.utf8))
    XCTAssertEqual(set.policies?.adaptiveThink ?? true, false)
  }

  // MARK: --json outcome rows

  func testOutcomeRowCarriesTheLabelKeyOnEveryRow() throws {
    func outcome(label: String?) -> EvalOutcome {
      EvalOutcome(
        suite: "basics", taskId: "t", model: "test/model", trial: 1, checkPassed: true, agentFinished: true,
        steps: 3, toolCalls: 2, costUSD: 0.01, durationSeconds: 1.5, startedAt: t0, routedModels: [],
        dialect: "chat", sandboxed: true, sessionId: "S", runId: "R", stopReason: "completed", label: label)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    let labelled = String(decoding: try encoder.encode(EvalOutcomeRow(outcome(label: "think-B"))), as: UTF8.self)
    XCTAssertTrue(labelled.contains(#""label":"think-B""#))
    let unlabelled = String(decoding: try encoder.encode(EvalOutcomeRow(outcome(label: nil))), as: UTF8.self)
    XCTAssertTrue(unlabelled.contains(#""label":null"#), "the key is always present — @Nullable")
    XCTAssertEqual(unlabelled.replacingOccurrences(of: #""label":null"#, with: #""label":"think-B""#), labelled)
  }
}
