import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class TerminalRecoveryTests: XCTestCase {
  private func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-terminal-recovery-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  func testForegroundTimeoutAllowsExplicitRecoveryWithoutAutomaticRetry() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "slow", name: "bash", arguments: #"{"command":"echo attempt >> attempts.txt; sleep 20","timeout_seconds":1}"#)],
      [Fixtures.toolCallChunk(id: "recover", name: "bash", arguments: #"{"command":"printf recovered > result.txt"}"#)],
      [Fixtures.textChunk("Recovered after the timed-out command.")],
    ]
    let session = Session(service: mock, tools: [BashTool(root: root)],
      store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
      configuration: .init(model: "test/model", commandDiagnostics: true))
    _ = try await Events.drain(await session.send("Run the check, then recover if needed."))
    let results = mock.requests.last?.messages.filter { $0.role == .tool }.compactMap { $0.content?.plainText } ?? []
    XCTAssertEqual(results.count, 2)
    XCTAssertTrue(results.first?.contains("command timed out") == true)
    XCTAssertTrue(results.first?.contains("timed_out") == true)
    XCTAssertTrue(results.last?.contains("command_succeeded") == true)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("attempts.txt"), encoding: .utf8), "attempt\n")
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("result.txt"), encoding: .utf8), "recovered")
    let record = await session.lastRecord
    XCTAssertEqual(record?.stopReason, .completed)
    await session.shutdown()
  }

  func testLargeFailingJobKeepsTailAndRegistryCanStartAgainAfterShutdown() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let jobs = JobRegistry(logRoot: root)
    let first = try await jobs.start(command: "yes progress | head -c 200000; printf '\nFAILED terminal_tail\n'; exit 7", cwd: root)
    let waited = await jobs.wait(id: first.id, seconds: 15)
    let poll = try XCTUnwrap(waited)
    XCTAssertEqual(poll.job.exitStatus, 7)
    XCTAssertGreaterThan(poll.newBytes, 200_000)
    XCTAssertLessThanOrEqual(poll.text.count, JobRegistry.tailChars)
    XCTAssertGreaterThan(poll.omittedChars, 0)
    XCTAssertTrue(poll.text.hasSuffix("FAILED terminal_tail\n"))
    let repeated = await jobs.poll(id: first.id)
    XCTAssertEqual(repeated?.newBytes, 0)
    await jobs.killAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: jobs.logDirectory.path))
    let second = try await jobs.start(command: "echo recovered", cwd: root)
    XCTAssertGreaterThan(second.id, first.id, "old job handles must not alias a restarted job")
    let recovered = await jobs.wait(id: second.id, seconds: 15)
    XCTAssertEqual(recovered?.text, "recovered\n")
    XCTAssertEqual(recovered?.job.exitStatus, 0)
    await jobs.killAll()
  }

  func testCancellingAWaitDoesNotKillTheJobOrLoseItsFinalStatus() async throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let jobs = JobRegistry(logRoot: root)
    let job = try await jobs.start(command: "while [ ! -e release ]; do sleep 0.02; done; echo finished; exit 9", cwd: root)
    let waiter = Task { await jobs.wait(id: job.id, seconds: 60) }
    waiter.cancel()
    let cancelled = try await withDeadline(seconds: 3) { await waiter.value }
    XCTAssertNotNil(cancelled ?? nil)
    let running = await jobs.status(id: job.id)
    XCTAssertEqual(running?.isRunning, true)
    XCTAssertEqual(running?.killed, false)
    try Data().write(to: root.appendingPathComponent("release"))
    let finished = await jobs.wait(id: job.id, seconds: 15)
    XCTAssertEqual(finished?.job.exitStatus, 9)
    XCTAssertEqual(finished?.text, "finished\n")
    await jobs.killAll()
  }
}
