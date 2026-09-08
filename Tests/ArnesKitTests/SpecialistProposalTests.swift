import XCTest
@testable import ArnesKit
import OpenRouterSwift

final class SpecialistProposalTests: XCTestCase {
  private actor Allowance {
    var value = 0.5
    func set(_ value: Double) { self.value = value }
  }

  func testQueuedSpecialistRechecksRemainingBudgetBeforeStarting() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let allowance = Allowance(), checked = Latch(), running = Latch(), release = Latch()
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("first report")], [Fixtures.textChunk("must not run")]]
    mock.streamGate = { _ in await running.arrive(); await release.wait(for: 1) }
    let task = TaskTool(agents: try roles(), service: mock,
      tools: [ReadFileTool(root: directory)],
      store: RunRecordStore(url: directory.appendingPathComponent("runs.jsonl")),
      defaults: .init(maxConcurrent: 1), configuration: .init(model: "test/model", packsDirectory: directory))
    task.parentModel = { "test/model" }
    task.parentBudgetRemaining = {
      let value = await allowance.value
      await checked.arrive()
      return value
    }
    let first = Task { try await task.execute(arguments: ["agent": "investigator", "task": "First."]) }
    await running.wait(for: 1)
    let second = Task { try await task.execute(arguments: ["agent": "investigator", "task": "Queued."]) }
    // First spawn + first slot recheck + queued spawn. It has captured the old allowance.
    await checked.wait(for: 3)
    await allowance.set(0)
    await release.arrive()
    _ = try await first.value
    let refused = try await second.value
    XCTAssertTrue(refused.contains("budget limit reached"), refused)
    XCTAssertEqual(mock.requests.count, 1)
  }

  func testCancelledSnapshotSpecialistKillsItsJobsAndPreservesParentRegistry() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let work = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try "parent".write(to: work.appendingPathComponent("marker"), atomically: true, encoding: .utf8)
    let jobs = JobRegistry(logRoot: directory)
    addTeardownBlock { await jobs.killAll() }
    let parentJob = try await jobs.start(command: "sleep 30", cwd: work)
    let entered = Latch()
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "job", name: "bash",
        arguments: #"{"command":"sleep 30","background":true}"#)],
      [Fixtures.textChunk("must be cancelled")],
    ]
    mock.streamGate = { request in
      if request.messages.contains(where: { $0.role == .tool }) {
        await entered.arrive()
        try? await Task.sleep(nanoseconds: 30_000_000_000)
      }
    }
    let store = RunRecordStore(url: directory.appendingPathComponent("runs.jsonl"))
    let context = ToolContext(root: work, jobs: jobs)
    let lead = "SNAPSHOT-CANCEL-\(UUID())"
    let task = TaskTool(agents: try roles(), service: mock, tools: HarnessAssembly.coreTools(context),
      store: store, toolContext: context, makeSandbox: { _ in nil },
      configuration: .init(model: "test/model", workingDirectory: work,
        toolResultGuard: .cli, packsDirectory: directory, commandDiagnostics: true))
    task.parentSessionId = lead
    task.parentModel = { "test/model" }
    let run = Task { try await task.execute(arguments: ["agent": "verifier", "task": "Start the check."]) }
    await entered.wait(for: 1)
    let output = try XCTUnwrap(mock.requests.last?.messages.first { $0.role == .tool }?.content?.plainText)
    let start = try XCTUnwrap(output.range(of: "(pid ")?.upperBound)
    let pid = try XCTUnwrap(Int32(output[start...].prefix { $0.isNumber }))
    run.cancel()
    _ = try await run.value
    let record = try XCTUnwrap(store.all().first)
    let layout = WorkspaceSnapshot.Layout(leadId: lead, runId: try XCTUnwrap(record.sessionId))
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.work.path), "unchanged cancelled snapshot is removed")
    XCTAssertEqual(record.stopReason, .interrupted)
    XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("marker"), encoding: .utf8), "parent")
    let parentStatus = await jobs.status(id: parentJob.id)
    XCTAssertEqual(parentStatus?.isRunning, true)
    let check = try await ShellRunner.run("kill -0 \(pid) 2>/dev/null", cwd: work, timeoutSeconds: 3)
    XCTAssertNotEqual(check.exitStatus, 0, "nested shell process must be gone before returning the report")
    await jobs.killAll()
  }

  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }
  private func roles() throws -> [AgentDefinition] {
    try AgentLibrary.parseInline(json: String(contentsOf:
      root.appendingPathComponent("evals/ab/agents-specialists/roles.json"), encoding: .utf8))
  }
  private func directory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-specialist-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func testRolesAreBoundedModelNeutralAndCannotAddParentTools() throws {
    let roles = try roles()
    XCTAssertEqual(roles.count, 2)
    let investigator = try XCTUnwrap(roles.first { $0.name == "investigator" })
    let verifier = try XCTUnwrap(roles.first { $0.name == "verifier" })
    XCTAssertEqual(investigator.permissionMode, .readOnly)
    XCTAssertEqual(verifier.isolation, "snapshot")
    let parent: [any AgentTool] = [ReadFileTool(root: root)]
    for role in roles {
      XCTAssertNil(role.model)
      XCTAssertNil(role.effort)
      XCTAssertTrue(role.warnings.isEmpty)
      XCTAssertLessThanOrEqual(try XCTUnwrap(role.maxSteps), 20)
      XCTAssertLessThanOrEqual(try XCTUnwrap(role.budgetUSD), 0.75)
      XCTAssertFalse(role.background)
      XCTAssertFalse(role.fork)
      XCTAssertNil(role.memory)
      XCTAssertEqual(AgentLibrary.toolset(for: role, from: parent).map(\.name), ["read_file"])
      XCTAssertFalse(role.tools?.contains("task") == true)
    }
  }

  func testInvestigatorCannotWriteEvenWhenTheParentCan() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "write_file", arguments: #"{"path":"forbidden.txt","content":"bad"}"#)],
      [Fixtures.textChunk("No write performed.")],
    ]
    let store = RunRecordStore(url: directory.appendingPathComponent("runs.jsonl"))
    let task = TaskTool(agents: try roles(), service: mock,
      tools: [ReadFileTool(root: directory), WriteFileTool(root: directory)], store: store,
      configuration: .init(model: "test/model"))
    _ = try await task.execute(arguments: ["agent": "investigator", "task": "Inspect only."])
    XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("forbidden.txt").path))
    XCTAssertEqual(mock.requests.first?.tools?.map(\.function.name), ["read_file"])
    XCTAssertEqual(try store.all().count, 1)
    XCTAssertEqual(try store.all().first?.agent, "investigator")
  }

  func testQualityChecksRejectUntouchedAndSmokeOnlyRepairsThenAcceptFullRepairs() async throws {
    let suite = try EvalSuite.load(path: root.appendingPathComponent("evals/agentic-work").path)
    XCTAssertEqual(suite.tasks.count, 2)
    for fixture in suite.tasks {
      let directory = try directory()
      defer { try? FileManager.default.removeItem(at: directory) }
      XCTAssertNil(fixture.limits?.requiredTools, "correctness must not require delegation")
      let setup = await ShellRunner.run(try XCTUnwrap(fixture.setup), cwd: directory, timeoutSeconds: 15)
      XCTAssertEqual(setup.exitStatus, 0, setup.output)
      let untouched = await ShellRunner.run(fixture.check, cwd: directory, timeoutSeconds: 15)
      XCTAssertNotEqual(untouched.exitStatus, 0)
      try "# Test file presence is not treated as coverage evidence.\n".write(
        to: directory.appendingPathComponent("test_regression.py"), atomically: true, encoding: .utf8)
      if fixture.id == "cross-module-pagination" {
        try """
          def bounds(size, offset, limit):
            if offset < 0 or limit <= 0:
              raise ValueError('invalid bounds')
            return offset, min(size, offset + limit)

          """.write(to: directory.appendingPathComponent("pager/bounds.py"), atomically: true, encoding: .utf8)
      } else {
        // This repair passes the visible smoke case but still accepts invalid input.
        try """
          def parse_config(text):
            return dict(tuple(part.strip() for part in line.split('=', 1)) for line in text.splitlines() if line.strip() and not line.strip().startswith('#'))

          """.write(to: directory.appendingPathComponent("config.py"), atomically: true, encoding: .utf8)
        let smoke = await ShellRunner.run("python3 -B check_config.py", cwd: directory, timeoutSeconds: 15)
        XCTAssertEqual(smoke.exitStatus, 0)
        let incomplete = await ShellRunner.run(fixture.check, cwd: directory, timeoutSeconds: 15)
        XCTAssertNotEqual(incomplete.exitStatus, 0, "the independent check must reject smoke-only fixes")
        try """
          def parse_config(text):
            result = {}
            for line in text.splitlines():
              line = line.strip()
              if not line or line.startswith('#'):
                continue
              key, value = (part.strip() for part in line.split('=', 1))
              if not key or key in result:
                raise ValueError('invalid key')
              result[key] = value
            return result

          """.write(to: directory.appendingPathComponent("config.py"), atomically: true, encoding: .utf8)
      }
      let repaired = await ShellRunner.run(fixture.check, cwd: directory, timeoutSeconds: 15)
      XCTAssertEqual(repaired.exitStatus, 0, repaired.output)
      let protected = fixture.id == "cross-module-pagination" ? "fixtures.txt" : "check_config.py"
      try "changed\n".write(to: directory.appendingPathComponent(protected), atomically: true, encoding: .utf8)
      let tampered = await ShellRunner.run(fixture.check, cwd: directory, timeoutSeconds: 15)
      XCTAssertNotEqual(tampered.exitStatus, 0, "tampering must not earn a pass")
    }
  }

  func testVerifierShellWritesRemainInTheSnapshotAndRecordTheInheritedModel() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let work = directory.appendingPathComponent("work")
    try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    try "original\n".write(to: work.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "bash", arguments: #"{"command":"printf changed > tracked.txt"}"#)],
      [Fixtures.textChunk("The snapshot was changed; this is not a verification pass.")],
    ]
    let store = RunRecordStore(url: directory.appendingPathComponent("runs.jsonl"))
    let lead = "SPECIALIST-\(UUID())"
    let context = ToolContext(root: work)
    let task = TaskTool(agents: try roles(), service: mock,
      tools: HarnessAssembly.coreTools(context), store: store, toolContext: context,
      makeSandbox: { _ in nil }, configuration: .init(model: "test/model", workingDirectory: work))
    task.parentSessionId = lead
    task.parentModel = { "test/model" }
    let report = try await task.execute(arguments: ["agent": "verifier", "task": "Verify in the snapshot."])
    let record = try XCTUnwrap(store.all().first)
    let layout = WorkspaceSnapshot.Layout(leadId: lead, runId: try XCTUnwrap(record.sessionId))
    defer { try? layout.remove() }
    XCTAssertEqual(record.model, "test/model")
    XCTAssertEqual(record.agent, "verifier")
    XCTAssertEqual(record.parentSessionId, lead)
    XCTAssertEqual(try String(contentsOf: work.appendingPathComponent("tracked.txt"), encoding: .utf8), "original\n")
    XCTAssertEqual(try String(contentsOf: layout.work.appendingPathComponent("tracked.txt"), encoding: .utf8), "changed")
    XCTAssertTrue(report.contains("changes in snapshot"))
    XCTAssertFalse(mock.requests.first?.tools?.contains { $0.function.name == "write_file" } == true)
    XCTAssertFalse(mock.requests.first?.tools?.contains { $0.function.name == "task" } == true)
  }

  func testEvalCanActuallySpawnTheSnapshotVerifier() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "lead1", name: "task", arguments: #"{"agent":"verifier","task":"Read marker.txt and report only."}"#)],
      [Fixtures.toolCallChunk(id: "child1", name: "read_file", arguments: #"{"path":"marker.txt"}"#)],
      [Fixtures.textChunk("marker.txt contains original.")],
      [Fixtures.textChunk("Verified the marker.")],
    ]
    let records = RunRecordStore(url: directory.appendingPathComponent("runs.jsonl"))
    let runner = EvalRunner(service: mock,
      store: EvalStore(url: directory.appendingPathComponent("evals.jsonl")), recordStore: records,
      makeSandbox: { _ in nil }, subagents: try roles())
    let outcomes = await runner.run(suite: EvalSuite(name: "unit", tasks: [
      EvalTask(id: "verify", prompt: "Inspect the marker.", setup: "echo original > marker.txt",
        check: "test \"$(cat marker.txt)\" = original"),
    ]), models: ["test/model"])
    XCTAssertEqual(outcomes.first?.checkPassed, true)
    let child = try XCTUnwrap(records.all().first { $0.agent == "verifier" })
    XCTAssertEqual(child.model, "test/model")
    XCTAssertNotNil(child.parentSessionId)
    let layout = WorkspaceSnapshot.Layout(leadId: try XCTUnwrap(child.parentSessionId),
      runId: try XCTUnwrap(child.sessionId))
    defer { layout.remove() }
    XCTAssertFalse(FileManager.default.fileExists(atPath: layout.directory.path), "unchanged verification snapshot is cleaned")
    XCTAssertTrue(mock.requests.contains { request in
      request.messages.contains { $0.content?.plainText.contains("disposable copy of the project") == true }
    })
  }

  func testEvalChildUsesTheRemainingBudgetNotTheOriginalCeiling() async throws {
    let directory = try directory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "lead1", name: "task", arguments: #"{"agent":"investigator","task":"Read marker.txt."}"#),
       Fixtures.usageChunk(cost: 0.45)],
      [Fixtures.toolCallChunk(id: "child1", name: "read_file", arguments: #"{"path":"marker.txt"}"#),
       Fixtures.usageChunk(cost: 0.10)],
      [Fixtures.textChunk("This extra request must not run.")],
    ]
    let records = RunRecordStore(url: directory.appendingPathComponent("runs.jsonl"))
    let runner = EvalRunner(service: mock,
      store: EvalStore(url: directory.appendingPathComponent("evals.jsonl")), recordStore: records,
      makeSandbox: { _ in nil }, subagents: try roles(), budgetUSD: 0.5)
    _ = await runner.run(suite: EvalSuite(name: "unit", tasks: [
      EvalTask(id: "budget", prompt: "Investigate.", setup: "echo original > marker.txt", check: "true"),
    ]), models: ["test/model"])
    let child = try XCTUnwrap(records.all().first { $0.agent == "investigator" })
    XCTAssertEqual(child.stopReason, .budget)
    XCTAssertEqual(mock.requests.count, 2, "once observed spend crosses the remaining cap, no extra request")
  }
}
