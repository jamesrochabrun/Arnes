import XCTest
@testable import ArnesKit

final class DialectTests: XCTestCase {
  func testFamilyFromModelId() {
    XCTAssertEqual(ModelFamily(modelId: "anthropic/claude-fable-5"), .anthropic)
    XCTAssertEqual(ModelFamily(modelId: "openai/gpt-5.6-luna"), .openai)
    XCTAssertEqual(ModelFamily(modelId: "x-ai/grok-4.6"), .xai)
    XCTAssertEqual(ModelFamily(modelId: "meta-llama/llama-3-70b"), .meta)
    XCTAssertEqual(ModelFamily(modelId: "openrouter/auto"), .other)
  }

  func testPreferredDialects() {
    XCTAssertEqual(ModelFamily.anthropic.preferredDialect, .messages)
    XCTAssertEqual(ModelFamily.openai.preferredDialect, .responses)
    XCTAssertEqual(ModelFamily.xai.preferredDialect, .chat)
    XCTAssertEqual(ModelFamily.other.preferredDialect, .chat)
  }
}

final class PromptPackTests: XCTestCase {
  func testFamilyDefaultsAreAppendedToBase() {
    let pack = PromptPack.load(
      for: .anthropic,
      overridesDirectory: URL(fileURLWithPath: "/nonexistent"))
    XCTAssertTrue(pack.text.contains("You are Arnes"))
    XCTAssertTrue(pack.text.contains("step by step"))
  }

  func testUserOverrideWins() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-packs-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try "CUSTOM RULES".write(
      to: dir.appendingPathComponent("openai.md"),
      atomically: true,
      encoding: .utf8)
    let pack = PromptPack.load(for: .openai, overridesDirectory: dir)
    XCTAssertTrue(pack.text.contains("CUSTOM RULES"))
    XCTAssertTrue(pack.text.contains("You are Arnes"))
  }
}

final class RunRecordStoreTests: XCTestCase {
  func testAppendAndReadBack() throws {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-runs-\(UUID().uuidString).jsonl")
    let store = RunRecordStore(url: url)

    var record = RunRecord(task: "fix tests", model: "openai/gpt-5.6-luna", dialect: "chat", packFamily: "openai")
    record.steps = 3
    record.costUSD = 0.012
    record.finished = true
    record.verifierPassed = true
    try store.append(record)

    var second = RunRecord(task: "add docs", model: "anthropic/claude-sonnet-5", dialect: "chat", packFamily: "anthropic")
    second.costUSD = 0.004
    try store.append(second)

    let all = try store.all()
    XCTAssertEqual(all.count, 2)
    XCTAssertEqual(all[0].task, "fix tests")
    XCTAssertEqual(all[0].verifierPassed, true)
    XCTAssertEqual(all[1].model, "anthropic/claude-sonnet-5")
  }
}

final class ToolTests: XCTestCase {
  func testReadAndWriteFileTools() async throws {
    let path = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-tool-\(UUID().uuidString).txt").path

    let write = WriteFileTool()
    let writeResult = try await write.execute(arguments: [
      "path": .string(path),
      "content": .string("hello\nworld"),
    ])
    XCTAssertTrue(writeResult.contains("wrote"))

    let read = ReadFileTool()
    let readResult = try await read.execute(arguments: ["path": .string(path)])
    XCTAssertTrue(readResult.contains("1\thello"))
    XCTAssertTrue(readResult.contains("2\tworld"))
  }

  func testBashTool() async throws {
    let bash = BashTool()
    let result = try await bash.execute(arguments: ["command": .string("echo arnes")])
    XCTAssertTrue(result.contains("exit 0"))
    XCTAssertTrue(result.contains("arnes"))
  }

  func testMissingArgumentsAreReportedNotThrown() async throws {
    let read = ReadFileTool()
    let result = try await read.execute(arguments: [:])
    XCTAssertTrue(result.contains("error"))
  }
}
