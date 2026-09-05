import ArgumentParser
import ArnesKit
import Foundation
import XCTest
@testable import arnes

/// H1 headless conveniences, CLI side: `do --session-id`, `evals transcript --json`,
/// `eval --compare last:N` and an accumulating `-m`, the `debug prompt` run flags and the
/// withheld-tools line, `arnes init`'s argv, `/schema` and `interactive --output-schema`.
/// Parse-time refusals go through `<Command>.parse` (ArgumentParser runs `validate()`); the pure
/// helpers are called directly. Nothing here connects or touches `~/.arnes`.
final class HeadlessConveniencesCLITests: XCTestCase {
  private static let upper = "6BA7B810-9DAD-11D1-80B4-00C04FD430C8"
  private static let lower = "6ba7b810-9dad-11d1-80b4-00c04fd430c8"
  private static let inlineSchema =
    #"{"type":"object","properties":{"answer":{"type":"string"}},"required":["answer"],"additionalProperties":false}"#

  private func tempSessionStore() -> SessionStore {
    SessionStore(directory: FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-h1-cli-sessions-\(UUID().uuidString)"))
  }

  private func tempFile(_ contents: String, name: String = "x.md") throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-h1-cli-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func assertDoRefuses(_ arguments: [String], contains needle: String, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertThrowsError(try Do.parse(arguments), arguments.joined(separator: " "), file: file, line: line) { error in
      let message = Do.message(for: error)
      XCTAssertTrue(message.contains(needle), "\(arguments.joined(separator: " ")): \(message)", file: file, line: line)
    }
  }

  private func plain(_ lines: [String]) -> [String] {
    lines.map { $0.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression) }
  }

  // MARK: --session-id

  func testSessionIdParsesCanonicalizesAndRefusesTheContinuations() throws {
    let command = try Do.parse(["say hi", "--session-id", Self.lower])
    XCTAssertEqual(command.sessionId, Self.lower, "parsed as typed; run() canonicalizes")
    let store = tempSessionStore()
    XCTAssertEqual(try Do.pinnedSessionId(Self.lower, store: store), Self.upper, "uppercase, like every stored id")
    XCTAssertEqual(try Do.pinnedSessionId(Self.upper, store: store), Self.upper)
    XCTAssertNil(try Do.pinnedSessionId(nil, store: store), "no flag → a random id, as always")
    // With or without --session: the records carry the id either way.
    XCTAssertTrue(try Do.parse(["say hi", "--session-id", Self.upper, "--session"]).session)
    XCTAssertFalse(try Do.parse(["say hi", "--session-id", Self.upper]).session)

    assertDoRefuses(["say hi", "--session-id", "not-a-uuid"], contains: "--session-id must be a UUID")
    assertDoRefuses(["say hi", "--session-id", Self.upper, "--resume", "abc"], contains: "--session-id and --resume/--continue/--fork don't combine")
    assertDoRefuses(["say hi", "--session-id", Self.upper, "--continue"], contains: "don't combine")
    assertDoRefuses(["say hi", "--session-id", Self.upper, "--continue", "--fork"], contains: "don't combine")
    assertDoRefuses(["say hi", "--session-id", Self.upper, "--panel", "2"], contains: "--panel and --session-id don't combine")
  }

  func testSessionIdIsRefusedWhenTheStoreAlreadyHoldsTheTranscript() throws {
    let store = tempSessionStore()
    try store.append(.meta(id: Self.upper, model: "test/model", cwd: "/work"), to: Self.upper)
    XCTAssertThrowsError(try Do.pinnedSessionId(Self.lower, store: store)) { error in
      let message = (error as? ValidationError)?.message ?? "\(error)"
      XCTAssertTrue(message.contains("already has this id"), message)
      XCTAssertTrue(message.contains("--resume \(Self.upper)"), message)
    }
    // Another id in the same store is fine.
    let other = UUID().uuidString
    XCTAssertEqual(try Do.pinnedSessionId(other, store: store), other)
  }

  // MARK: evals transcript --json

  private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

  private static func outcome(session: String, task: String = "hello", passed: Bool = true) -> EvalOutcome {
    EvalOutcome(
      suite: "basics", taskId: task, model: "test/model", trial: 1, checkPassed: passed, agentFinished: true,
      steps: 3, toolCalls: 2, costUSD: 0.0123, durationSeconds: 4.2, startedAt: t0,
      routedModels: [], error: nil, dialect: "chat", sandboxed: true, sessionId: session,
      runId: "R-\(session)", stopReason: "completed")
  }

  func testEvalsTranscriptJSONListsRowsAndOneTranscriptAsStored() throws {
    XCTAssertTrue(try EvalsTranscript.parse(["--json"]).json)
    XCTAssertFalse(try EvalsTranscript.parse([]).json)
    XCTAssertEqual(try EvalsTranscript.parse(["abc", "--json"]).id, "abc")

    let matched = SessionMeta(id: "S-1", model: "test/model", updatedAt: Self.t0, messageCount: 4)
    let pruned = SessionMeta(id: "S-2", model: "other/model", updatedAt: Self.t0, messageCount: 2)
    let rows = EvalsTranscript.listingRows(sessions: [matched, pruned], outcomes: [Self.outcome(session: "S-1")])
    XCTAssertEqual(rows.map(\.sessionId), ["S-1", "S-2"], "the store's order, one row per transcript")
    XCTAssertEqual(rows[0].suite, "basics")
    XCTAssertEqual(rows[0].task, "hello")
    XCTAssertEqual(rows[0].passed, true)
    XCTAssertEqual(rows[0].model, "test/model")
    XCTAssertNil(rows[1].suite, "pruned row → null facts, never a dropped transcript")
    XCTAssertNil(rows[1].task)
    XCTAssertNil(rows[1].passed)
    XCTAssertEqual(rows[1].model, "other/model")
    let listing = try JSONOut.line(EvalTranscriptsDocument(rows: rows))
    XCTAssertTrue(
      listing.hasPrefix(#"{"rows":[{"model":"test/model","passed":true,"session_id":"S-1","suite":"basics","task":"hello","updated_at":"#),
      listing)
    XCTAssertTrue(listing.contains(#""model":"other/model","passed":null,"session_id":"S-2","suite":null,"task":null"#), listing)
    XCTAssertTrue(listing.hasSuffix(#"],"type":"eval_transcripts"}"#), listing)
    XCTAssertEqual(try JSONOut.line(EvalTranscriptsDocument(rows: [])), #"{"rows":[],"type":"eval_transcripts"}"#)

    // The newest row naming a session wins, as the text listing always picked it.
    let bySession = EvalsTranscript.rowsBySession([
      Self.outcome(session: "S-1", task: "old", passed: false), Self.outcome(session: "S-1", task: "new"),
    ])
    XCTAssertEqual(bySession["S-1"]?.taskId, "new")

    // One transcript: the eval row's facts plus the lines as stored (sorted keys).
    let entries = [
      TranscriptEntry.meta(id: "S-1", model: "test/model", cwd: "/work"),
      TranscriptEntry(message: .user("hi"), turn: 0),
    ]
    let document = try JSONOut.line(EvalTranscriptDocument(sessionId: "S-1", row: Self.outcome(session: "S-1"), entries: entries))
    for key in ["type", "session_id", "run_id", "suite", "task", "model", "dialect", "passed", "cost_usd", "entries"] {
      XCTAssertTrue(document.contains("\"\(key)\":"), "missing \(key): \(document)")
    }
    XCTAssertTrue(document.hasPrefix(#"{"cost_usd":0.0123,"dialect":"chat","entries":[{"#), document)
    XCTAssertTrue(document.contains(#""type":"meta""#), document)
    XCTAssertTrue(document.contains(#""role":"user","text":"hi","turn":0,"type":"message""#), document)
    XCTAssertTrue(document.contains(#""model":"test/model","passed":true,"run_id":"R-S-1","session_id":"S-1","suite":"basics","task":"hello","type":"eval_transcript"}"#), document)
    // A pruned row: every documented key still present, null.
    let orphan = try JSONOut.line(EvalTranscriptDocument(sessionId: "S-2", row: nil, entries: []))
    XCTAssertEqual(
      orphan,
      #"{"cost_usd":null,"dialect":null,"entries":[],"model":null,"passed":null,"run_id":null,"session_id":"S-2","suite":null,"task":null,"type":"eval_transcript"}"#)
  }

  // MARK: --compare last:N and -m

  func testCompareLastNParsesSpellsBackAndRefusesBadCounts() throws {
    XCTAssertEqual(try Eval.parseCompare("last:3"), .last(rows: 3))
    XCTAssertEqual(try Eval.parseCompare(" LAST:10 "), .last(rows: 10))
    XCTAssertEqual(try Eval.parseCompare("last"), .last(rows: 5), "bare `last` keeps its default")
    XCTAssertEqual(try Eval.parseCompare("7d"), .days(7))
    for bad in ["last:0", "last:x", "last:", "last:-2", "last:1.5"] {
      XCTAssertThrowsError(try Eval.parseCompare(bad), bad) { error in
        XCTAssertTrue(((error as? ValidationError)?.message ?? "").contains("last:N"), "\(bad): \(error)")
      }
    }
    XCTAssertEqual(Eval.compareSpelling(" LAST:3 "), "last:3", "the document spells back what was passed")
    XCTAssertEqual(try Eval.parse(["evals/basics", "--compare", "last:3"]).compare, "last:3")
    XCTAssertThrowsError(try Eval.parse(["evals/basics", "--compare", "last:0"]), "validate() refuses at parse time")
  }

  func testRepeatedModelFlagsAccumulateInsteadOfKeepingTheLast() throws {
    XCTAssertEqual(try Eval.parse(["evals/basics"]).models, [], "empty → the provider's default")
    XCTAssertEqual(try Eval.parse(["evals/basics", "-m", "a", "-m", "b"]).models, ["a", "b"])
    XCTAssertEqual(try Eval.parse(["evals/basics", "--models", "a,b"]).models, ["a,b"])
    XCTAssertEqual(Eval.modelEntries(["a", "b"]), Eval.modelEntries(["a,b"]), "-m a -m b ≡ -m a,b")
    XCTAssertEqual(Eval.modelEntries(["a, b", "", "c,"]), ["a", "b", "c"])
    XCTAssertEqual(Eval.modelEntries([]), [])
    // `evals show --model` stays a single substring filter.
    XCTAssertEqual(try EvalsShow.parse(["--model", "deep"]).model, "deep")
  }

  // MARK: debug prompt

  func testDebugPromptParsesTheRunsFlagsAndRefusesWhatDoRefuses() throws {
    let appendix = try tempFile("From the file.")
    let command = try DebugPrompt.parse([
      "--add-dir", "/tmp", "--add-dir", "/var", "--effort", "high", "--permission-mode", "acceptEdits",
      "--agents", "{}", "--allowed-tools", "Read,Bash", "--allowed-tools", "grep", "--disallowed-tools", "bash",
      "--append-system-prompt", "Be terse.", "--append-system-prompt-file", appendix.path,
    ])
    XCTAssertEqual(command.addDir, ["/tmp", "/var"])
    XCTAssertEqual(command.effort, "high")
    XCTAssertEqual(command.permissionMode, "acceptEdits")
    XCTAssertEqual(command.agents, "{}")
    XCTAssertEqual(command.allowedTools, ["Read,Bash", "grep"])
    XCTAssertEqual(command.disallowedTools, ["bash"])
    XCTAssertEqual(command.appendSystemPrompt, "Be terse.")
    XCTAssertEqual(command.appendSystemPromptFile, appendix.path)
    XCTAssertEqual(try Do.systemPromptAppendix(text: command.appendSystemPrompt, file: command.appendSystemPromptFile), "Be terse.\n\nFrom the file.")
    let bare = try DebugPrompt.parse([])
    XCTAssertEqual(bare.addDir, [])
    XCTAssertNil(bare.effort)
    XCTAssertNil(bare.permissionMode)
    XCTAssertEqual(bare.allowedTools, [])
    XCTAssertNil(bare.workingDirectoryPath)
    XCTAssertEqual(try DebugPrompt.parse(["-C", "/tmp"]).workingDirectoryPath, "/tmp")
    XCTAssertEqual(try DebugPrompt.parse(["--cwd", "/tmp"]).workingDirectoryPath, "/tmp")

    for (arguments, needle) in [
      (["--effort", "bogus"], "unknown effort 'bogus'"),
      (["--permission-mode", "bogus"], "unknown permission mode 'bogus'"),
      (["--agents", "{not json"], "agents"),
      (["--append-system-prompt-file", "/nonexistent/arnes-h1/x.md"], "append-system-prompt-file"),
      (["--dialect", "bogus"], "dialect"),
    ] {
      XCTAssertThrowsError(try DebugPrompt.parse(arguments), arguments.joined(separator: " ")) { error in
        let message = DebugPrompt.message(for: error)
        XCTAssertTrue(message.contains(needle), "\(arguments.joined(separator: " ")): \(message)")
      }
    }
  }

  func testPromptReportNamesTheWithheldToolsInTextAndJSON() throws {
    let offered = Array(Session.defaultTools.map(\.toolDefinition).prefix(2))
    let report = PromptReport(
      model: "acme/text", dialect: "chat", provider: "openrouter",
      prompt: "You are a coding agent.\n# Environment\ncwd /work", tools: offered, withheldTools: ["view_image"])
    XCTAssertEqual(report.offeredLine, "tools: 2 offered to acme/text (3 in the toolset; withheld: view_image)")
    let lines = plain(report.textLines())
    let header = try XCTUnwrap(lines.firstIndex { $0.hasPrefix("──── tools (2, ") }, "\(lines)")
    XCTAssertEqual(lines[header + 1], report.offeredLine, "right under the tools header")
    let line = try JSONOut.line(report)
    XCTAssertTrue(line.contains(#""withheld_tools":["view_image"]"#), line)
    for key in ["model", "dialect", "provider", "system_prompt", "sections", "tools", "withheld_tools", "approx_tokens_total"] {
      XCTAssertTrue(line.contains("\"\(key)\":"), "missing \(key)")
    }
    // Nothing withheld: the key is still there (additive forever), the line says so.
    let none = PromptReport(model: "acme/vision", dialect: "chat", provider: "openrouter", prompt: "p", tools: offered)
    XCTAssertEqual(none.offeredLine, "tools: 2 offered to acme/vision (2 in the toolset; none withheld)")
    XCTAssertTrue(try JSONOut.line(none).contains(#""withheld_tools":[]"#))
  }

  // MARK: arnes init

  func testInitBuildsADoArgvWithTheHeadlessEditingPosture() throws {
    XCTAssertTrue(Arnes.configuration.subcommands.contains { $0 == InitCommand.self }, "a root subcommand")
    XCTAssertEqual(InitCommand.skillName, BuiltinSkills.initInstructions.name)
    let prompt = BuiltinSkills.initInstructions.invocationPrompt(arguments: nil)
    XCTAssertTrue(prompt.contains("The user invoked skill 'init'"), prompt)
    XCTAssertTrue(prompt.contains("AGENTS.md"), prompt)

    let argv = InitCommand.doArguments(
      prompt: prompt, model: "haiku", effort: "high", budget: 0.2, maxSteps: 40, trustProject: true,
      outputFormat: .json, verbose: true, dialect: "auto", noSandbox: false,
      provider: nil, mcpConfig: nil, strictMcpConfig: false)
    XCTAssertEqual(
      Array(argv.prefix(7)),
      [prompt, "--yes", "--permission-mode", "acceptEdits", "--no-mcp", "--no-agents", "--no-memory"],
      "the task, then the posture: in-tree writes auto-approved, nothing delegated, no server, no memory")
    XCTAssertFalse(argv.contains("--bare"), "instruction files must load so an existing AGENTS.md is read first")
    XCTAssertFalse(argv.contains("--no-skills"))
    let command = try Do.parse(argv)
    XCTAssertEqual(command.task, prompt)
    XCTAssertTrue(command.yes)
    XCTAssertEqual(command.permissionMode, "acceptEdits")
    XCTAssertTrue(command.noMcp)
    XCTAssertTrue(command.noAgents)
    XCTAssertTrue(command.noMemory)
    XCTAssertFalse(command.bare)
    XCTAssertEqual(command.maxSteps, 40)
    XCTAssertEqual(command.model, "haiku")
    XCTAssertEqual(command.effort, "high")
    XCTAssertEqual(command.budget, 0.2)
    XCTAssertTrue(command.trustProject)
    XCTAssertEqual(command.outputFormat, .json)
    XCTAssertTrue(command.verbose)
    XCTAssertFalse(command.noSandbox)
    XCTAssertNil(command.sessionId)

    // Pass-through flags ride only when set.
    let minimal = InitCommand.doArguments(
      prompt: "p", model: nil, effort: nil, budget: nil, maxSteps: 12, trustProject: false,
      outputFormat: .text, verbose: false, dialect: "chat", noSandbox: true,
      provider: "gw", mcpConfig: "/tmp/mcp.json", strictMcpConfig: true)
    for absent in ["-m", "--effort", "--budget", "--trust-project", "--verbose"] {
      XCTAssertFalse(minimal.contains(absent), absent)
    }
    XCTAssertTrue(minimal.contains("--no-sandbox"))
    XCTAssertTrue(minimal.contains("--strict-mcp-config"))
    XCTAssertEqual(minimal.firstIndex(of: "--provider").map { minimal[$0 + 1] }, "gw")
    XCTAssertEqual(minimal.firstIndex(of: "--mcp-config").map { minimal[$0 + 1] }, "/tmp/mcp.json")
    let parsedMinimal = try Do.parse(minimal)
    XCTAssertNil(parsedMinimal.model)
    XCTAssertEqual(parsedMinimal.maxSteps, 12)
    XCTAssertEqual(parsedMinimal.dialect, "chat")
    XCTAssertTrue(parsedMinimal.noSandbox)
    XCTAssertEqual(parsedMinimal.providerOptions.provider, "gw")
  }

  func testInitParsesItsOwnFlagsAndRefusesBadOnes() throws {
    let command = try InitCommand.parse([
      "-m", "haiku", "--budget", "0.2", "--max-steps", "12", "--trust-project", "--output-format", "stream-json",
      "-C", "/tmp", "--effort", "low", "--verbose", "--no-sandbox",
    ])
    XCTAssertEqual(command.model, "haiku")
    XCTAssertEqual(command.budget, 0.2)
    XCTAssertEqual(command.maxSteps, 12)
    XCTAssertTrue(command.trustProject)
    XCTAssertEqual(command.outputFormat, .streamJson)
    XCTAssertEqual(command.workingDirectoryPath, "/tmp")
    XCTAssertEqual(command.effort, "low")
    XCTAssertTrue(command.verbose)
    XCTAssertTrue(command.noSandbox)
    let defaults = try InitCommand.parse([])
    XCTAssertEqual(defaults.maxSteps, 40)
    XCTAssertNil(defaults.model)
    XCTAssertEqual(defaults.outputFormat, .text)
    XCTAssertFalse(defaults.trustProject)
    XCTAssertThrowsError(try InitCommand.parse(["--max-steps", "0"]))
    XCTAssertThrowsError(try InitCommand.parse(["--budget", "0"]))
    XCTAssertThrowsError(try InitCommand.parse(["--effort", "bogus"]))
    XCTAssertThrowsError(try InitCommand.parse(["--dialect", "bogus"]))
    XCTAssertThrowsError(try InitCommand.parse(["a task"]), "no positional: the skill is the task")
  }

  // MARK: /schema and interactive --output-schema

  func testSchemaSlashCommandParsesCompletesAndIsInHelp() throws {
    guard case .schema(argument: nil)? = SlashCommand.parse("/schema") else { return XCTFail("/schema") }
    guard case .schema(argument: "off")? = SlashCommand.parse("/schema off") else { return XCTFail("/schema off") }
    guard case .schema(argument: "./answer.json")? = SlashCommand.parse("/SCHEMA ./answer.json") else { return XCTFail("case-insensitive command") }
    guard case .schema(argument: Self.inlineSchema)? = SlashCommand.parse("/schema \(Self.inlineSchema)") else { return XCTFail("inline object") }
    XCTAssertTrue(SlashCommand.helpText.contains("/schema [file|json]"))
    XCTAssertTrue(SlashCommand.helpText.contains("/schema off"))
    XCTAssertTrue(SlashCompletion.builtins.contains { $0.name == "/schema" })

    XCTAssertEqual(SchemaArgument.parse(nil), .show)
    XCTAssertEqual(SchemaArgument.parse("  "), .show)
    XCTAssertEqual(SchemaArgument.parse("SHOW"), .show)
    XCTAssertEqual(SchemaArgument.parse("off"), .off)
    XCTAssertEqual(SchemaArgument.parse("none"), .off)
    XCTAssertNil(SchemaArgument.parse("help"))
    XCTAssertNil(SchemaArgument.parse("?"))
    XCTAssertEqual(SchemaArgument.parse("~/s.json"), .value("~/s.json"))
    XCTAssertEqual(SchemaArgument.parse(Self.inlineSchema), .value(Self.inlineSchema))
    XCTAssertTrue(SchemaArgument.usage.hasPrefix("usage: /schema <file|json>"))

    let schema = try XCTUnwrap(try Do.loadOutputSchema(Self.inlineSchema))
    XCTAssertEqual(SchemaFormat.bytes(of: schema), HeadlessJSON.line(schema.schema).utf8.count)
    XCTAssertGreaterThan(SchemaFormat.bytes(of: schema), 0)
    XCTAssertEqual(SchemaFormat.describe(schema), "\(schema.name) · \(SchemaFormat.bytes(of: schema)) bytes")
  }

  func testInteractiveOutputSchemaFlagLoadsAtParseTimeLikeDo() throws {
    let command = try Interactive.parse(["--output-schema", Self.inlineSchema])
    XCTAssertEqual(command.outputSchema, Self.inlineSchema)
    XCTAssertEqual(
      try Do.loadOutputSchema(command.outputSchema),
      try Do.loadOutputSchema(try Do.parse(["q", "--output-schema", Self.inlineSchema]).outputSchema),
      "the same loader, the same schema, as on do")
    XCTAssertNil(try Interactive.parse([]).outputSchema)
    XCTAssertThrowsError(try Interactive.parse(["--output-schema", "{not json"])) { error in
      let message = Interactive.message(for: error)
      XCTAssertTrue(message.contains("--output-schema"), message)
    }
    XCTAssertThrowsError(try Interactive.parse(["--output-schema", #"{"type":"array"}"#]), "an object schema only, as on do")
  }
}
