import ArgumentParser
import ArnesKit
import Foundation
import OpenRouterSwift

// MARK: - decide

struct Decide: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "Ask a decision model typed questions about a state (Decisions API).",
    discussion: """
      System One models (typesafe/jev-1.13) generate no text: they answer typed
      questions about a state with calibrated probabilities — a yes/no probability
      (noul), a pick from options you define (choice), or a position on an ordered
      rubric (score). The caller owns the workflow and acts on the numbers, so this
      is for routing, ranking and verification scripts, not chat.

      Questions are JSON, inline or a file path:
        {"is_urgent": {"type": "noul", "instructions": "Is this urgent?"},
         "team": {"type": "choice", "instructions": "Who owns this?",
                  "criteria": {"billing": "Payments", "technical": "Bugs"}},
         "anger": {"type": "score", "instructions": "How angry?",
                   "criteria": ["Calm", "Frustrated", "Very angry"]}}

      The state rides the argument (stdin when omitted or `-`); --state-json parses
      it as JSON (object or array) instead of a plain string. The call is
      POST /api/alpha/decisions — an OpenRouter alpha endpoint; a LiteLLM or other
      OpenAI-compatible gateway will refuse it. Every call appends a RunRecord
      (dialect `decisions`), so `arnes runs` scores decision spend too.
      """)

  @Argument(help: "The state the questions are about. Omitted or '-' reads stdin.")
  var state: String?

  @Option(name: .shortAndLong, help: "Decision model slug or alias (default: typesafe/jev-1.13).")
  var model = "typesafe/jev-1.13"

  @Option(help: "Questions as inline JSON (starts with '{') or a path to a JSON file.")
  var questions: String

  @Flag(help: "Parse the state as JSON (object or array) instead of a plain string.")
  var stateJson = false

  @Flag(help: "Print the decision as one JSON line instead of text.")
  var json = false

  @OptionGroup var providerOptions: ProviderOptions

  func run() async throws {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let parsed = try Self.loadQuestions(questions, relativeTo: cwd)
    let stateText = try readState()
    let stateValue = try Self.parseState(stateText, asJSON: stateJson)

    let runtime = try ArnesRuntime.make(providerOptions)
    let model = runtime.provider.resolveAlias(model)

    var record = RunRecord(
      task: String(stateText.prefix(200)),
      model: model,
      dialect: "decisions",
      packFamily: ModelFamily(modelId: model).rawValue)
    record.provider = runtime.traits.name
    record.steps = 1

    let response: DecisionResponse
    do {
      response = try await runtime.service.decide(
        DecisionRequest(model: model, state: stateValue, questions: parsed))
    } catch {
      record.summary = String("\(error)".prefix(200))
      try? RunRecordStore().append(record)
      throw error
    }

    record.finished = true
    record.routedModels = response.model.map { [$0] } ?? []
    record.costUSD = response.usage?.cost ?? 0
    record.promptTokens = response.usage?.inputTokens
    record.completionTokens = response.usage?.outputTokens
    record.summary = Self.summary(of: response)
    try? RunRecordStore().append(record)

    if json {
      try JSONOut.print(DecisionDocument(requested: model, response: response))
    } else {
      for line in Self.lines(for: response, requested: model) {
        print(TerminalText.sanitize(line))
      }
    }
  }

  private func readState() throws -> String {
    if let state, state != "-" { return state }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      throw ValidationError("no state — pass it as the argument or on stdin")
    }
    return text
  }

  // MARK: Pure pieces

  /// Questions from the flag: inline JSON when the trimmed value starts with `{`,
  /// else a file path resolved against the working directory.
  static func loadQuestions(_ raw: String, relativeTo cwd: URL) throws -> [String: DecisionQuestion] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let data: Data
    if trimmed.hasPrefix("{") {
      data = Data(trimmed.utf8)
    } else {
      let url = trimmed.hasPrefix("/")
        ? URL(fileURLWithPath: trimmed)
        : cwd.appendingPathComponent(trimmed)
      guard let read = try? Data(contentsOf: url) else {
        throw ValidationError("cannot read questions file at \(trimmed)")
      }
      data = read
    }
    let parsed: [String: DecisionQuestion]
    do {
      parsed = try JSONDecoder().decode([String: DecisionQuestion].self, from: data)
    } catch {
      throw ValidationError("questions must be JSON of {name: {type, instructions, criteria}}: \(error)")
    }
    guard !parsed.isEmpty else {
      throw ValidationError("questions object is empty — ask at least one")
    }
    return parsed
  }

  /// The state as the wire value: a plain string, or parsed JSON under --state-json.
  static func parseState(_ text: String, asJSON: Bool) throws -> JSONValue {
    guard asJSON else { return .string(text) }
    do {
      return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    } catch {
      throw ValidationError("--state-json given but the state is not valid JSON: \(error)")
    }
  }

  /// The text view: one line per answer, sorted by question name, then the cost line.
  static func lines(for response: DecisionResponse, requested: String) -> [String] {
    var out = [String]()
    let served = response.model ?? requested
    let via = response.provider.map { " (\($0))" } ?? ""
    out.append("decision from \(served)\(via):")

    let width = response.answers.keys.map(\.count).max() ?? 0
    for (name, answer) in response.answers.sorted(by: { $0.key < $1.key }) {
      let padded = name.padding(toLength: max(width, name.count), withPad: " ", startingAt: 0)
      out.append("  \(padded)  \(answerText(answer))")
    }

    if let usage = response.usage {
      var facts = [String]()
      if let cost = usage.cost { facts.append(String(format: "$%.6f", cost)) }
      if let input = usage.inputTokens, let output = usage.outputTokens {
        facts.append("\(input) in / \(output) out")
      }
      if !facts.isEmpty { out.append("[\(facts.joined(separator: " · "))]") }
    }
    return out
  }

  /// One answer, spelled by its type.
  static func answerText(_ answer: DecisionAnswer) -> String {
    if let noul = answer.noul {
      return String(format: "noul   → P(yes) = %.2f", noul)
    }
    if let choice = answer.choice {
      let picked = answer.probabilities?[choice].map { String(format: " (p=%.2f", $0) + confidenceTail(answer) + ")" }
        ?? confidenceOnly(answer)
      return "choice → \(choice)\(picked)\(distribution(answer.probabilities ?? [:], byProbability: true))"
    }
    if let score = answer.score {
      let label = answer.scoreLabel.map { " ≈ \($0)" } ?? ""
      return String(format: "score  → %.2f", score) + label + confidenceOnly(answer)
        + scoreDistribution(answer)
    }
    return "unrecognized answer shape"
  }

  private static func confidenceTail(_ answer: DecisionAnswer) -> String {
    answer.confidence.map { String(format: ", confidence %.2f", $0) } ?? ""
  }

  private static func confidenceOnly(_ answer: DecisionAnswer) -> String {
    answer.confidence.map { String(format: " (confidence %.2f)", $0) } ?? ""
  }

  /// Choice options, highest probability first (ties by name, for a stable line).
  private static func distribution(_ probabilities: [String: Double], byProbability: Bool) -> String {
    guard probabilities.count > 1 else { return "" }
    let entries = probabilities.sorted {
      byProbability && $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
    }
    return "  [" + entries.map { String(format: "%@=%.2f", $0.key, $0.value) }.joined(separator: " · ") + "]"
  }

  /// Score levels in rubric order, labeled through the legend when present.
  private static func scoreDistribution(_ answer: DecisionAnswer) -> String {
    let dense = answer.scoreDistribution
    guard !dense.isEmpty else { return "" }
    let parts = dense.enumerated().map { index, probability in
      let label = answer.legend?[String(index)] ?? String(index)
      return String(format: "%@=%.2f", label, probability)
    }
    return "  [" + parts.joined(separator: " · ") + "]"
  }

  /// The RunRecord summary: `name: answer` pairs, capped.
  static func summary(of response: DecisionResponse) -> String {
    let parts = response.answers.sorted(by: { $0.key < $1.key }).map { name, answer -> String in
      if let noul = answer.noul { return String(format: "%@=%.2f", name, noul) }
      if let choice = answer.choice { return "\(name)=\(choice)" }
      if let score = answer.score { return String(format: "%@=%.2f", name, score) }
      return name
    }
    return String(parts.joined(separator: " · ").prefix(200))
  }
}
