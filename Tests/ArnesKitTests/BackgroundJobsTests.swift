import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// T2 — bash v2: `timeout_seconds`, the process-tree kill, background jobs behind one
/// `JobRegistry`, the `job` tool, and `Session.shutdown()` killing what a session started.
final class BackgroundJobsTests: XCTestCase {
  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-jobs-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  private func tempStore() -> RunRecordStore {
    RunRecordStore(url: scratch.appendingPathComponent("runs-\(UUID().uuidString).jsonl"))
  }

  /// True once nothing answers to `pid` — or only a zombie does. Polls briefly: signal delivery
  /// is asynchronous.
  private func processGone(_ pid: Int32) async -> Bool {
    for _ in 0..<60 {
      if kill(pid, 0) != 0 { return true }
      let stat = ShellRunner.runBlocking("ps -o stat= -p \(pid)", cwd: nil, timeoutSeconds: 5)
      if stat.output.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("Z") { return true }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return false
  }

  /// Races a poll against a deadline and unwraps it — a hung wait fails the test, never the run.
  private func awaitPoll(
    seconds: Double = 20, _ body: @escaping @Sendable () async -> JobRegistry.Poll?)
    async throws -> JobRegistry.Poll
  {
    let result = try await withDeadline(seconds: seconds, body)
    return try XCTUnwrap(result ?? nil, "the poll timed out")
  }

  /// The pids a job's shell wrote to `file`, one per line.
  private func recordedPids(_ file: URL) throws -> [Int32] {
    try String(contentsOf: file, encoding: .utf8)
      .split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
  }

  // MARK: Registry

  func testJobWritesItsLogAndReportsItsExit() async throws {
    let registry = JobRegistry(logRoot: scratch, keepsLogs: true)
    let job = try await registry.start(command: "echo hi; sleep 0.2; echo bye", cwd: scratch)
    XCTAssertEqual(job.id, 1)
    XCTAssertTrue(job.isRunning)
    XCTAssertEqual(job.logURL.lastPathComponent, "job-1.log")
    XCTAssertTrue(job.logURL.path.hasPrefix(registry.logDirectory.path))
    // Owner-only, like every file the harness writes for the user.
    let mode = try FileManager.default.attributesOfItem(atPath: registry.logDirectory.path)[.posixPermissions] as? Int
    XCTAssertEqual(mode, 0o700)
    let poll = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    XCTAssertEqual(poll.job.exitStatus, 0)
    XCTAssertEqual(poll.job.stateLabel, "exited 0")
    XCTAssertFalse(poll.job.killed)
    XCTAssertNotNil(poll.job.exitedAt)
    XCTAssertEqual(poll.text, "hi\nbye\n")
    XCTAssertEqual(poll.newBytes, 7)
    XCTAssertEqual(try String(contentsOf: job.logURL, encoding: .utf8), "hi\nbye\n")
    await registry.killAll()
    // Kept: the logs stay for the user to read (`ARNES_KEEP_TMP`).
    XCTAssertTrue(FileManager.default.fileExists(atPath: job.logURL.path))
  }

  func testStatusReturnsOnlyTheBytesSinceTheLastPoll() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let marker = scratch.appendingPathComponent("go")
    // Two lines, then wait for a marker file, then two more: the polls straddle the pause.
    let command = "echo one; echo two; while [ ! -e '\(marker.path)' ]; do sleep 0.05; done; echo three; echo four"
    let job = try await registry.start(command: command, cwd: scratch)
    // The first two lines: poll once both are in the log (the shell startup is not instant, and
    // the two echoes are two writes).
    func logSize() -> Int {
      (try? FileManager.default.attributesOfItem(atPath: job.logURL.path)[.size] as? Int) ?? 0
    }
    for _ in 0..<400 where logSize() < 8 {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    let firstPolled = await registry.poll(id: 1)
    let firstPoll = try XCTUnwrap(firstPolled)
    XCTAssertTrue(firstPoll.job.isRunning)
    XCTAssertEqual(firstPoll.text, "one\ntwo\n")
    XCTAssertEqual(firstPoll.newBytes, 8)
    // Nothing new: the offset moved, the text is empty, the job still runs.
    let quietPolled = await registry.poll(id: 1)
    let quiet = try XCTUnwrap(quietPolled)
    XCTAssertEqual(quiet.newBytes, 0)
    XCTAssertEqual(quiet.text, "")
    XCTAssertEqual(JobTool.render(quiet).split(separator: "\n").first, "job 1 running · no new output since last poll")
    // Release the job; the next poll (after the exit) carries only the last two lines.
    try Data().write(to: marker)
    let last = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    XCTAssertEqual(last.job.exitStatus, 0)
    XCTAssertEqual(last.text, "three\nfour\n")
    XCTAssertEqual(last.newBytes, 11)
    let final = await registry.status(id: 1)
    XCTAssertEqual(final?.lastReadOffset, 19)
    await registry.killAll()
  }

  func testWaitReturnsAsSoonAsTheJobExits() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let marker = scratch.appendingPathComponent("release")
    _ = try await registry.start(
      command: "while [ ! -e '\(marker.path)' ]; do sleep 0.02; done; echo released", cwd: scratch)
    let waited = Latch()
    // A wait of 60 seconds… that must come back the moment the marker appears, not at 60.
    let waiter = Task { () -> JobRegistry.Poll? in
      let poll = await registry.wait(id: 1, seconds: 60)
      await waited.arrive()
      return poll
    }
    // Still waiting: the job is blocked on the marker.
    let arrivedEarly = await waited.count
    XCTAssertEqual(arrivedEarly, 0)
    let stillRunning = await registry.status(id: 1)
    XCTAssertEqual(stillRunning?.isRunning, true)
    try Data().write(to: marker)
    let poll = try await awaitPoll { await waiter.value }
    XCTAssertEqual(poll.job.exitStatus, 0)
    XCTAssertTrue(poll.text.contains("released"), poll.text)
    let arrived = await waited.count
    XCTAssertEqual(arrived, 1)
    // An exited job's wait returns at once; an unknown id is nil.
    let again = try await awaitPoll(seconds: 5) { await registry.wait(id: 1, seconds: 60) }
    XCTAssertEqual(again.job.exitStatus, 0)
    let unknown = await registry.wait(id: 42, seconds: 1)
    XCTAssertNil(unknown)
    await registry.killAll()
  }

  func testKillTerminatesTheProcessTree() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let pids = scratch.appendingPathComponent("pids")
    let command = "sleep 30 & echo $! > '\(pids.path)'; sleep 30 & echo $! >> '\(pids.path)'; wait"
    let job = try await registry.start(command: command, cwd: scratch)
    // Let the shell write both pids before the kill.
    for _ in 0..<200 where (try? recordedPids(pids))?.count != 2 {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    let children = try recordedPids(pids)
    XCTAssertEqual(children.count, 2)
    let started = Date()
    let killed = await registry.kill(id: job.id)
    let poll = try XCTUnwrap(killed)
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    XCTAssertTrue(poll.job.killed)
    // SIGTERM or the bounded SIGKILL escalation, shell-style — or 0 when bash reaped
    // both killed sleeps and left `wait` before its own signal landed.
    let status = try XCTUnwrap(poll.job.exitStatus)
    XCTAssertTrue([0, 137, 143].contains(status), "exit \(status)")
    XCTAssertEqual(poll.job.stateLabel, "exited \(status) (killed)")
    for pid in children {
      let gone = await processGone(pid)
      XCTAssertTrue(gone, "sleep \(pid) survived the tree kill")
    }
    let shell = await processGone(job.pid)
    XCTAssertTrue(shell)
    // Killing again is a no-op poll; the state stands.
    let repeated = await registry.kill(id: job.id)
    XCTAssertEqual(repeated?.job.exitStatus, status)
    await registry.killAll()
  }

  func testRegistryRefusesTheSeventeenthRunningJob() async throws {
    let registry = JobRegistry(logRoot: scratch)
    for _ in 0..<JobRegistry.maxJobs {
      _ = try await registry.start(command: "sleep 30", cwd: scratch)
    }
    let full = await registry.runningCount
    XCTAssertEqual(full, JobRegistry.maxJobs)
    do {
      _ = try await registry.start(command: "sleep 30", cwd: scratch)
      XCTFail("the 17th job must be refused")
    } catch let error as JobRegistry.JobError {
      XCTAssertEqual(error, .tooManyJobs(limit: JobRegistry.maxJobs))
      XCTAssertTrue("\(error)".contains("16 background jobs are already running"), "\(error)")
    }
    // The bash tool says the same, as a result the model can act on.
    let bash = BashTool(root: scratch, jobs: registry)
    let refused = try await bash.execute(arguments: ["command": .string("sleep 30"), "background": true])
    XCTAssertTrue(refused.hasPrefix("error: could not start background job: 16 background jobs"), refused)
    await registry.killAll()
    let afterKill = await registry.runningCount
    XCTAssertEqual(afterKill, 0)
    // A slot freed by the kill is a slot: the next start succeeds.
    let next = try await registry.start(command: "echo ok", cwd: scratch)
    XCTAssertEqual(next.id, JobRegistry.maxJobs + 1)
    await registry.killAll()
  }

  func testKillAllEndsEveryJobAndRemovesTheLogsUnlessKept() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let a = try await registry.start(command: "sleep 30", cwd: scratch)
    let b = try await registry.start(command: "sleep 30", cwd: scratch)
    XCTAssertTrue(FileManager.default.fileExists(atPath: registry.logDirectory.path))
    let started = Date()
    await registry.killAll()
    XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    let running = await registry.runningCount
    XCTAssertEqual(running, 0)
    for job in await registry.snapshot() {
      XCTAssertTrue([137, 143].contains(job.exitStatus ?? -1), "job \(job.id)")
      XCTAssertTrue(job.killed)
    }
    let aGone = await processGone(a.pid)
    let bGone = await processGone(b.pid)
    XCTAssertTrue(aGone)
    XCTAssertTrue(bGone)
    XCTAssertFalse(FileManager.default.fileExists(atPath: registry.logDirectory.path), "the logs die with the jobs")
    // Idempotent.
    await registry.killAll()
    let remembered = await registry.snapshot().count
    XCTAssertEqual(remembered, 2)
  }

  func testAJobKilledAtShutdownFiresNoExitHandlerButAJobExitingOnItsOwnDoes() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let exits = Latch()
    let seen = ExitRecorder()
    registry.setExitHandler { job in
      seen.record(job)
      Task { await exits.arrive() }
    }
    _ = try await registry.start(command: "sleep 30", cwd: scratch)
    _ = try await registry.start(command: "exit 3", cwd: scratch)
    // The job that exits on its own reaches the handler with its status and notice text.
    let firstExit: Void? = try await withDeadline(seconds: 20) { await exits.wait(for: 1) }
    XCTAssertNotNil(firstExit, "the exit handler fired")
    let own = try XCTUnwrap(seen.jobs.first)
    XCTAssertEqual(own.id, 2)
    XCTAssertEqual(own.exitStatus, 3)
    XCTAssertTrue(own.exitNotice.hasPrefix("background job 2 exited 3 — see "), own.exitNotice)
    XCTAssertTrue(own.exitNotice.contains("job-2.log"))
    // The one killed by the shutdown is silent: the session is ending, nobody is told.
    await registry.killAll()
    XCTAssertEqual(seen.jobs.map(\.id), [2])
    // A job the model kills itself is silent on the handler too (the kill's result said it).
    let again = JobRegistry(logRoot: scratch)
    let killedSeen = ExitRecorder()
    again.setExitHandler { killedSeen.record($0) }
    let job = try await again.start(command: "sleep 30", cwd: scratch)
    _ = await again.kill(id: job.id)
    XCTAssertTrue(killedSeen.jobs.isEmpty)
    await again.killAll()
  }

  /// The log directory is under the OS temp directory precisely because the sandbox lets a
  /// confined job write there (`~/.arnes/tmp` is denied); the in-process mirror agrees.
  func testJobLogsAreWhereASandboxedJobCanWrite() throws {
    let registry = JobRegistry()
    let sandbox = ShellSandbox(writableRoots: [scratch])
    let log = registry.logDirectory.appendingPathComponent("job-1.log")
    XCTAssertTrue(sandbox.permitsWrite(log.path), log.path)
    XCTAssertTrue(registry.logDirectory.path.hasPrefix(NSTemporaryDirectory()), registry.logDirectory.path)
    let underArnes = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".arnes/tmp/x/job-1.log")
    XCTAssertFalse(sandbox.permitsWrite(underArnes.path), "the spill root would have been refused")
  }

  // MARK: BashTool

  func testBackgroundBashReturnsTheJobLineAndTheJobToolPollsIt() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let tools = HarnessAssembly.coreTools(ToolContext(root: scratch, jobs: registry))
    let bash = try XCTUnwrap(tools.first { $0.name == "bash" })
    let job = try XCTUnwrap(tools.first { $0.name == "job" })
    XCTAssertEqual(Array(tools.map(\.name)[3...4]), ["bash", "job"])
    let started = try await bash.execute(arguments: ["command": .string("echo out; echo err 1>&2; exit 7"), "background": true])
    XCTAssertTrue(started.hasPrefix("job 1 started (pid "), started)
    XCTAssertTrue(started.contains("job-1.log"), started)
    XCTAssertTrue(started.contains("killed when this session ends"), started)
    // The id as a string or a number, the action defaulting to status; wait blocks to the exit.
    let waitedResult = try await withDeadline(seconds: 20) {
      try await job.execute(arguments: ["id": 1, "action": "wait", "wait_seconds": 15])
    }
    let waited = try XCTUnwrap(waitedResult)
    let lines = waited.split(separator: "\n").map(String.init)
    XCTAssertEqual(lines.first, "job 1 exited 7 · 8 new bytes since last poll")
    XCTAssertEqual(Set(lines[1...2]), ["out", "err"], "stdout and stderr interleave in one log: \(lines)")
    XCTAssertTrue(lines.last?.hasPrefix("(full log: ") ?? false, waited)
    let status = try await job.execute(arguments: ["id": "1"])
    XCTAssertEqual(status.split(separator: "\n").first, "job 1 exited 7 · no new output since last poll")
    // Unknown ids and actions are coaching errors, never a spawn.
    let unknownId = try await job.execute(arguments: ["id": "9"])
    XCTAssertTrue(unknownId.hasPrefix("error: no such job '9'"), unknownId)
    let badId = try await job.execute(arguments: ["id": "abc"])
    XCTAssertTrue(badId.hasPrefix("error: job id"), badId)
    let badAction = try await job.execute(arguments: ["id": "1", "action": "restart"])
    XCTAssertTrue(badAction.hasPrefix("error: unknown action 'restart'"), badAction)
    XCTAssertEqual(JobTool.jobId(from: ["id": "job 3"]), 3)
    await registry.killAll()
  }

  func testBashWithoutARegistryRefusesBackgroundAndKeepsTheOldShape() async throws {
    let bash = BashTool(root: scratch)
    let refused = try await bash.execute(arguments: ["command": .string("sleep 30"), "background": true])
    XCTAssertTrue(refused.hasPrefix("error: background jobs are not available in this run"), refused)
    // The foreground form is exactly what it was.
    let quick = try await bash.execute(arguments: ["command": .string("echo ok")])
    XCTAssertEqual(quick, "exit 0\nok\n")
    XCTAssertFalse(HarnessAssembly.coreTools(ToolContext(root: scratch)).contains { $0.name == "job" })
    // …and the model is never coached into the refusal: no registry, no `background` in the
    // schema, and the description says jobs are unavailable instead of offering them.
    XCTAssertNil(bash.parameters.objectValue?["properties"]?.objectValue?["background"])
    XCTAssertFalse(bash.description.contains("background: true"), bash.description)
    XCTAssertTrue(bash.description.contains("Background jobs are not available in this run"), bash.description)
    let backed = BashTool(root: scratch, jobs: JobRegistry(logRoot: scratch))
    XCTAssertNotNil(backed.parameters.objectValue?["properties"]?.objectValue?["background"])
    XCTAssertTrue(backed.description.contains("pass background: true"), backed.description)
    XCTAssertEqual(
      backed.parameters.objectValue?["properties"]?.objectValue?["timeout_seconds"],
      bash.parameters.objectValue?["properties"]?.objectValue?["timeout_seconds"])
  }

  /// `background: "true"` (a string, what small models send) runs detached like the boolean; a
  /// value that is neither is a coaching error, never a command silently run in the foreground
  /// until the timeout kills it.
  func testBackgroundFlagAcceptsTheStringSpellingsAndRefusesNonsense() async throws {
    XCTAssertEqual(BashTool.backgroundFlag(from: ["command": "ls"]), false)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": true]), true)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": "true"]), true)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": " Yes "]), true)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": 1]), true)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": "false"]), false)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": "no"]), false)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": 0]), false)
    XCTAssertEqual(BashTool.backgroundFlag(from: ["background": .null]), false)
    XCTAssertNil(BashTool.backgroundFlag(from: ["background": "later"]))
    XCTAssertNil(BashTool.backgroundFlag(from: ["background": 7]))
    XCTAssertNil(BashTool.backgroundFlag(from: ["background": ["x"]]))
    let registry = JobRegistry(logRoot: scratch)
    let bash = BashTool(root: scratch, jobs: registry)
    let started = try await bash.execute(arguments: ["command": .string("sleep 30"), "background": "true"])
    XCTAssertTrue(started.hasPrefix("job 1 started (pid "), started)
    let nonsense = try await bash.execute(arguments: ["command": .string("echo x"), "background": "later"])
    XCTAssertTrue(nonsense.hasPrefix("error: background must be true or false (got \"later\")"), nonsense)
    let running = await registry.runningCount
    XCTAssertEqual(running, 1, "the nonsense value spawned nothing")
    await registry.killAll()
  }

  func testJobToolRendersATailWithTheOmittedCount() async throws {
    let registry = JobRegistry(logRoot: scratch)
    // Well over the tail: 20 000 bytes of `x` lines.
    _ = try await registry.start(command: "awk 'BEGIN { for (i=0; i<2000; i++) print \"xxxxxxxxx\" }'", cwd: scratch)
    let poll = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    XCTAssertEqual(poll.newBytes, 20_000)
    XCTAssertEqual(poll.text.count, JobRegistry.tailChars)
    XCTAssertEqual(poll.omittedChars, 20_000 - JobRegistry.tailChars)
    let rendered = JobTool.render(poll)
    // The hint says how to keep up (poll more often) and that a read_file of the log is a read
    // outside the tree — never a bare pointer into a refusal under `--yes`.
    XCTAssertTrue(
      rendered.contains("[… \(20_000 - JobRegistry.tailChars) chars omitted — only the last \(JobRegistry.tailChars) chars of new output are shown; poll more often to keep up, or read_file the log (outside the working tree, so it may need approval)]"),
      rendered)
    await registry.killAll()
  }

  // MARK: Log integrity

  /// The registry reads job logs in the harness process, outside any sandbox, and the job knows
  /// the path — so a job that swaps its own log for a symbolic link to a credential must get a
  /// refusal, never the bytes (the door A8's diff, C4's restore and X6's untracked paste closed).
  func testPollRefusesALogTheJobReplacedWithASymlinkToASecret() async throws {
    let secret = scratch.appendingPathComponent("id_rsa")
    try "PRIVATE-KEY-MATERIAL-9f8e7d\n".write(to: secret, atomically: true, encoding: .utf8)
    let registry = JobRegistry(logRoot: scratch, keepsLogs: true)
    let log = registry.logDirectory.appendingPathComponent("job-1.log")
    // The started line prints the log path; this job removes it and plants a link in its place.
    let command = "echo before; rm -f '\(log.path)'; ln -s '\(secret.path)' '\(log.path)'; echo after"
    let job = try await registry.start(command: command, cwd: scratch)
    XCTAssertEqual(job.logURL, log)
    let poll = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    XCTAssertEqual(poll.job.exitStatus, 0)
    let refusal = try XCTUnwrap(poll.logRefusal)
    XCTAssertTrue(refusal.contains("symbolic link"), refusal)
    XCTAssertEqual(poll.text, "")
    XCTAssertEqual(poll.newBytes, 0)
    XCTAssertEqual(poll.omittedChars, 0)
    let rendered = JobTool.render(poll)
    XCTAssertTrue(rendered.hasPrefix("job 1 exited 0 · log not read\n[arnes: job 1's log at \(log.path) is not readable: "), rendered)
    XCTAssertTrue(rendered.contains("do not read that path"), rendered)
    XCTAssertFalse(rendered.contains("PRIVATE-KEY"), "the secret must not reach the model")
    XCTAssertFalse(rendered.contains("(full log:"), "no pointer at a path that is now a link")
    // The offset never moved, and the next poll refuses the same way.
    let againPolled = await registry.poll(id: 1)
    let again = try XCTUnwrap(againPolled)
    XCTAssertNotNil(again.logRefusal)
    XCTAssertEqual(again.job.lastReadOffset, 0)
    // The secret itself is untouched (the log was opened for writing by the job, not by us).
    XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "PRIVATE-KEY-MATERIAL-9f8e7d\n")
    await registry.killAll()
  }

  /// A FIFO where the log was would block `open()` until a writer appeared — on the registry's
  /// executor, so every later `job` call, `killAll` and the session's end would hang with it.
  /// The poll must come back promptly with a refusal, and `killAll` must still clean up.
  func testPollRefusesAFIFOInPlaceOfTheLogWithoutHanging() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let log = registry.logDirectory.appendingPathComponent("job-1.log")
    _ = try await registry.start(command: "rm -f '\(log.path)'; mkfifo '\(log.path)'", cwd: scratch)
    let polled = expectation(description: "the poll returns")
    let box = PollBox()
    Task {
      box.set(await registry.wait(id: 1, seconds: 15))
      polled.fulfill()
    }
    await fulfillment(of: [polled], timeout: 20)
    let poll = try XCTUnwrap(box.value, "the poll hung on the FIFO")
    let refusal = try XCTUnwrap(poll.logRefusal)
    XCTAssertTrue(refusal.contains("FIFO") || refusal.contains("special"), refusal)
    XCTAssertEqual(poll.text, "")
    XCTAssertEqual(poll.job.exitStatus, 0)
    let killed = expectation(description: "killAll returns")
    Task {
      await registry.killAll()
      killed.fulfill()
    }
    await fulfillment(of: [killed], timeout: 20)
    XCTAssertFalse(FileManager.default.fileExists(atPath: registry.logDirectory.path), "the directory (FIFO inside) is removed")
  }

  /// `O_NOFOLLOW` judges the leaf only: a job that swaps the whole log directory for a link to
  /// a directory holding a `job-1.log` of its choosing is caught by the identity check (device +
  /// inode of the file the registry created), and the cleanup unlinks the link, never the target.
  func testPollRefusesALogReachedThroughAReLinkedDirectory() async throws {
    let decoy = scratch.appendingPathComponent("decoy", isDirectory: true)
    try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
    let planted = decoy.appendingPathComponent("job-1.log")
    try "NOT-THE-LOG\n".write(to: planted, atomically: true, encoding: .utf8)
    let registry = JobRegistry(logRoot: scratch)
    let directory = registry.logDirectory
    let command = "echo real; rm -rf '\(directory.path)'; ln -s '\(decoy.path)' '\(directory.path)'"
    _ = try await registry.start(command: command, cwd: scratch)
    let poll = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    let refusal = try XCTUnwrap(poll.logRefusal)
    XCTAssertTrue(refusal.contains("different file"), refusal)
    XCTAssertEqual(poll.text, "")
    XCTAssertFalse(JobTool.render(poll).contains("NOT-THE-LOG"))
    await registry.killAll()
    // The registry's directory was a link: the link is gone, the decoy and its file are intact.
    XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: directory.path), "the planted link is unlinked")
    XCTAssertEqual(try String(contentsOf: planted, encoding: .utf8), "NOT-THE-LOG\n")
  }

  /// The log is created `O_EXCL | O_NOFOLLOW`: a link (or any file) planted at the path the
  /// next job's log would take refuses the start — nothing is opened through it, the id is not
  /// burned, and the planted target is untouched.
  func testStartRefusesAPrePlantedLogPath() async throws {
    let secret = scratch.appendingPathComponent("token.txt")
    try "SECRET-TOKEN-1234\n".write(to: secret, atomically: true, encoding: .utf8)
    let registry = JobRegistry(logRoot: scratch, keepsLogs: true)
    try SecureFiles.ensureDirectory(registry.logDirectory)
    let planted = registry.logDirectory.appendingPathComponent("job-1.log")
    try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: secret)
    do {
      _ = try await registry.start(command: "echo hijacked", cwd: scratch)
      XCTFail("a pre-planted log path must refuse the start")
    } catch let error as JobRegistry.JobError {
      let text = "\(error)"
      XCTAssertTrue(text.hasPrefix("could not create the job log at \(planted.path):"), text)
      XCTAssertTrue(text.contains("something already occupies the path"), text)
    }
    XCTAssertEqual(try String(contentsOf: secret, encoding: .utf8), "SECRET-TOKEN-1234\n", "nothing was written through the link")
    let none = await registry.snapshot()
    XCTAssertTrue(none.isEmpty)
    // A plain file already there is refused too (`O_EXCL`), and left as it was.
    try FileManager.default.removeItem(at: planted)
    try Data("stale\n".utf8).write(to: planted)
    do {
      _ = try await registry.start(command: "echo x", cwd: scratch)
      XCTFail("an occupied log path must refuse the start")
    } catch {}
    XCTAssertEqual(try String(contentsOf: planted, encoding: .utf8), "stale\n")
    // With the path free again the same id starts normally and reads its own log.
    try FileManager.default.removeItem(at: planted)
    let job = try await registry.start(command: "echo fine", cwd: scratch)
    XCTAssertEqual(job.id, 1)
    let poll = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    XCTAssertNil(poll.logRefusal)
    XCTAssertEqual(poll.text, "fine\n")
    await registry.killAll()
  }

  /// The ordinary case is untouched by the checks: a job's own log, appended to while it runs,
  /// reads exactly as before, and a deleted log is reported rather than shown as "no output".
  func testAnIntactLogReadsNormallyAndAMissingOneIsReported() async throws {
    let registry = JobRegistry(logRoot: scratch, keepsLogs: true)
    let job = try await registry.start(command: "echo one; echo two", cwd: scratch)
    let poll = try await awaitPoll { await registry.wait(id: 1, seconds: 15) }
    XCTAssertNil(poll.logRefusal)
    XCTAssertEqual(poll.text, "one\ntwo\n")
    try FileManager.default.removeItem(at: job.logURL)
    let gonePolled = await registry.poll(id: 1)
    let gone = try XCTUnwrap(gonePolled)
    XCTAssertEqual(gone.logRefusal, "it was deleted or moved after the job started")
    XCTAssertEqual(gone.job.lastReadOffset, 8, "the offset stays where the last real read left it")
    await registry.killAll()
  }

  // MARK: Session.shutdown

  func testHeadlessCompletionGraceKeepsJobsUntilDeadlineCloseOrInterrupt() async throws {
    for end in ["default", "deadline", "close", "interrupt", "cancellation"] {
      let registry = JobRegistry(logRoot: scratch)
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
      mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0)]]
      let store = tempStore()
      let agent = Agent(service: mock,
        tools: HarnessAssembly.coreTools(ToolContext(root: scratch, jobs: registry)),
        store: store, configuration: .init(model: "test/model"))
      let job = try await registry.start(command: "sleep 30", cwd: scratch)
      let result = try await agent.run(task: "done", model: "test/model",
        keepAliveSeconds: end == "default" ? 0 : end == "deadline" ? 1 : 30)
      XCTAssertEqual(result.record.stopReason, .completed)
      let countAtReturn = await registry.runningCount
      XCTAssertEqual(countAtReturn, end == "default" ? 0 : 1, end)
      if end == "close" { _ = await agent.close() }
      if end == "interrupt" { agent.interrupt() }
      if end == "cancellation" {
        let waiter = Task { await agent.waitForClose() }
        waiter.cancel()
        _ = await waiter.value
      }
      _ = await agent.waitForClose()
      let gone = await processGone(job.pid)
      XCTAssertTrue(gone, end)
      let finalRecord = await agent.lastSession?.lastRecord
      XCTAssertEqual(finalRecord?.stopReason, .completed, "cleanup never rewrites the completed turn")
    }
  }

  func testStoppedHeadlessRunClosesImmediatelyEvenWithCompletionGrace() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.toolCallChunk(id: "c1", name: "bash",
      arguments: #"{"command":"echo hi"}"#), Fixtures.usageChunk(cost: 0)]]
    let agent = Agent(service: mock,
      tools: HarnessAssembly.coreTools(ToolContext(root: scratch, jobs: registry)),
      store: tempStore(), configuration: .init(model: "test/model", maxStepsPerTurn: 1))
    let job = try await registry.start(command: "sleep 30", cwd: scratch)
    let result = try await agent.run(task: "go", model: "test/model", keepAliveSeconds: 30)
    XCTAssertEqual(result.record.stopReason, .maxSteps)
    let gone = await processGone(job.pid)
    XCTAssertTrue(gone)
  }

  func testSessionShutdownAndEndKillTheToolsetsJobs() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let tools = HarnessAssembly.coreTools(ToolContext(root: scratch, jobs: registry))
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let session = Session(service: mock, tools: tools, store: tempStore(), configuration: .init(model: "test/model"))
    let bash = try XCTUnwrap(tools.first { $0.name == "bash" })
    _ = try await bash.execute(arguments: ["command": .string("sleep 30"), "background": true])
    let started = await registry.status(id: 1)
    let job = try XCTUnwrap(started)
    XCTAssertTrue(job.isRunning)
    // `shutdown` finds the registry by conformance over the toolset (bash and job both host it).
    await session.shutdown()
    let afterShutdown = await registry.runningCount
    XCTAssertEqual(afterShutdown, 0)
    let firstGone = await processGone(job.pid)
    XCTAssertTrue(firstGone)
    // …and `end` calls it, so an ended session never leaves a job behind.
    _ = try await bash.execute(arguments: ["command": .string("sleep 30"), "background": true])
    let secondStarted = await registry.status(id: 2)
    let second = try XCTUnwrap(secondStarted)
    _ = await session.end(reason: .exit)
    let afterEnd = await registry.runningCount
    XCTAssertEqual(afterEnd, 0)
    let secondGone = await processGone(second.pid)
    XCTAssertTrue(secondGone)
    // Idempotent: a second shutdown finds nothing to do.
    await session.shutdown()
  }

  /// A toolset with `bash` over a registry but no `job` tool (an agent allowlist) is still shut
  /// down: the bash tool hosts the registry too.
  func testShutdownReachesARegistryThroughBashAlone() async throws {
    let registry = JobRegistry(logRoot: scratch)
    let bash = BashTool(root: scratch, jobs: registry)
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    let session = Session(service: mock, tools: [bash], store: tempStore(), configuration: .init(model: "test/model"))
    _ = try await bash.execute(arguments: ["command": .string("sleep 30"), "background": true])
    let before = await registry.runningCount
    XCTAssertEqual(before, 1)
    await session.shutdown()
    let after = await registry.runningCount
    XCTAssertEqual(after, 0)
  }

  // MARK: Subagents

  /// A nested session gets a registry of its own — its jobs die when its turn returns, and the
  /// lead's registry never sees them (killing "the subagent's jobs" can't kill the lead's).
  func testSubagentJobsDieWhenItsTurnReturnsAndNeverLandInTheLeadsRegistry() async throws {
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(
      Fixtures.manifestModel(id: "lead/model"),
      Fixtures.manifestModel(id: "sub/model"))
    mock.chunkScriptsByModel = [
      "lead/model": [
        [Fixtures.toolCallChunk(id: "c1", name: "task", arguments: #"{"agent":"helper","task":"serve"}"#, model: "lead/model"),
         Fixtures.usageChunk(cost: 0, model: "lead/model")],
        [Fixtures.textChunk("done", model: "lead/model"), Fixtures.usageChunk(cost: 0, model: "lead/model")],
      ],
      "sub/model": [[
        Fixtures.toolCallChunk(id: "s1", name: "bash", arguments: #"{"command":"sleep 30","background":true}"#, model: "sub/model"),
        Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ], [
        Fixtures.textChunk("server is up", model: "sub/model"), Fixtures.usageChunk(cost: 0, model: "sub/model"),
      ]],
    ]
    let store = tempStore()
    let leadRegistry = JobRegistry(logRoot: scratch)
    let tools = HarnessAssembly.coreTools(ToolContext(root: scratch, jobs: leadRegistry))
    let helper = AgentDefinition(name: "helper", description: "", body: "b", model: "sub/model")
    let taskTool = TaskTool(agents: [helper], service: mock, tools: tools, store: store)
    let session = Session(
      service: mock, tools: tools + [taskTool], store: store, configuration: .init(model: "lead/model"))
    taskTool.parentModel = { await session.model }

    var nestedBashResult: String?
    var nestedJobEvents: [AgentEvent.Kind] = []
    for try await event in await session.send("go") {
      if case .subagent("helper", _, .toolResult("bash", let preview)) = event { nestedBashResult = preview }
      if case .subagent("helper", _, let inner) = event, [.jobStarted, .jobFinished].contains(inner.kind) {
        nestedJobEvents.append(inner.kind)
      }
    }
    let started = try XCTUnwrap(nestedBashResult)
    XCTAssertTrue(started.hasPrefix("job 1 started (pid "), started)
    let pidText = started.dropFirst("job 1 started (pid ".count).prefix { $0.isNumber }
    let pid = try XCTUnwrap(Int32(pidText))
    // The nested run's job started in *its* registry (numbered from 1 there) and was killed when
    // the turn returned — `perform` shut the nested session down.
    let gone = await processGone(pid)
    XCTAssertTrue(gone, "the subagent's job outlived its turn")
    let leadJobs = await leadRegistry.snapshot()
    XCTAssertTrue(leadJobs.isEmpty, "the lead's registry never saw the nested job")
    XCTAssertEqual(nestedJobEvents, [.jobStarted], "the exit was the shutdown's — no finished event for it")
    let pending = await session.backgroundWorkPending
    XCTAssertEqual(pending, 0)
    await session.shutdown()
  }

  func testFreshRegistryRebuildsOnlyTheJobTools() {
    let registry = JobRegistry(logRoot: scratch)
    let tools = HarnessAssembly.coreTools(ToolContext(root: scratch, jobs: registry))
    let fresh = TaskTool.withFreshJobRegistry(tools)
    XCTAssertNotNil(fresh.jobs)
    XCTAssertFalse(fresh.jobs === registry)
    XCTAssertEqual(fresh.tools.map(\.name), tools.map(\.name))
    let bash = fresh.tools.first { $0.name == "bash" } as? BashTool
    XCTAssertTrue(bash?.jobRegistry === fresh.jobs)
    XCTAssertTrue((fresh.tools.first { $0.name == "job" } as? JobTool)?.registry === fresh.jobs)
    // No jobs in → the same tools out.
    let plain = HarnessAssembly.coreTools(ToolContext(root: scratch))
    let same = TaskTool.withFreshJobRegistry(plain)
    XCTAssertNil(same.jobs)
    XCTAssertEqual(same.tools.map(\.name), plain.map(\.name))
  }

  // MARK: Names, config, records

  func testToolNamesAreKnownToTheFilterAndTheClaudeCodeSpellings() {
    XCTAssertTrue(ToolFilter.harnessToolNames.contains("job"))
    XCTAssertEqual(AgentLibrary.canonicalToolName("BashOutput"), "job")
    XCTAssertEqual(AgentLibrary.canonicalToolName("KillShell"), "job")
    XCTAssertEqual(AgentLibrary.canonicalToolName("KillBash"), "job")
  }

  func testLimitsConfigDecodesTheBashTimeoutAndClampsIt() throws {
    let old = try JSONDecoder().decode(LimitsConfig.self, from: Data(#"{"toolResultChars": 1000}"#.utf8))
    XCTAssertNil(old.bashTimeoutSeconds)
    XCTAssertEqual(old.effectiveBashTimeoutSeconds, BashTool.defaultTimeoutSeconds)
    XCTAssertEqual(LimitsConfig.default.effectiveBashTimeoutSeconds, 300)
    let set = try JSONDecoder().decode(LimitsConfig.self, from: Data(#"{"bashTimeoutSeconds": 45}"#.utf8))
    XCTAssertEqual(set.effectiveBashTimeoutSeconds, 45)
    let over = try JSONDecoder().decode(LimitsConfig.self, from: Data(#"{"bashTimeoutSeconds": 5000}"#.utf8))
    XCTAssertEqual(over.effectiveBashTimeoutSeconds, BashTool.maxTimeoutSeconds)
    let zero = try JSONDecoder().decode(LimitsConfig.self, from: Data(#"{"bashTimeoutSeconds": 0}"#.utf8))
    XCTAssertEqual(zero.effectiveBashTimeoutSeconds, 1)
    // The context threads it into the tool.
    let tools = HarnessAssembly.coreTools(ToolContext(root: scratch, bashTimeoutSeconds: 45))
    let bash = try XCTUnwrap(tools.first { $0.name == "bash" } as? BashTool)
    XCTAssertEqual(bash.timeout(for: ["command": "ls"]), 45)
  }

  func testRunRecordDecodesOldRowsWithoutBackgroundJobsAndRoundTripsWithIt() throws {
    let old = """
      {"id":"r1","startedAt":"2026-01-01T00:00:00Z","task":"t","model":"m","dialect":"chat","packFamily":"generic",
       "steps":1,"toolCalls":0,"routedModels":[],"costUSD":0,"finished":true}
      """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(RunRecord.self, from: Data(old.utf8))
    XCTAssertNil(decoded.backgroundJobs)
    var record = RunRecord(task: "t", model: "m", dialect: "chat", packFamily: "generic")
    record.backgroundJobs = 2
    let back = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
    XCTAssertEqual(back.backgroundJobs, 2)
  }

  // MARK: Process tree

  func testProcessTreeEnumeratesDescendantsDeepestFirst() async throws {
    let pids = scratch.appendingPathComponent("tree")
    try Data().write(to: pids)
    // bash → sh → sleep: three generations under the launched shell, each pid labeled.
    let launch = try ShellRunner.Launch(
      command: "sh -c 'sleep 30 & echo sleep $! >> \"\(pids.path)\"; wait' & echo sh $! >> '\(pids.path)'; wait",
      cwd: scratch)
    defer { launch.box.forceKill() }
    func labeled() -> [String: Int32] {
      let lines = (try? String(contentsOf: pids, encoding: .utf8))?.split(separator: "\n") ?? []
      var map: [String: Int32] = [:]
      for line in lines {
        let parts = line.split(separator: " ")
        if parts.count == 2, let pid = Int32(parts[1]) { map[String(parts[0])] = pid }
      }
      return map
    }
    for _ in 0..<200 where labeled().count != 2 {
      try await Task.sleep(nanoseconds: 25_000_000)
    }
    let recorded = labeled()
    let sleep = try XCTUnwrap(recorded["sleep"])
    let sh = try XCTUnwrap(recorded["sh"])
    let tree = ShellRunner.ProcessTree.descendants(of: launch.box.pid)
    let found = tree.map(\.pid)
    XCTAssertTrue(found.contains(sleep), "sleep \(sleep) missing from \(found)")
    XCTAssertTrue(found.contains(sh), "sh \(sh) missing from \(found)")
    // Deepest first: the sleep (a grandchild) comes before the sh that started it.
    let sleepIndex = try XCTUnwrap(found.firstIndex(of: sleep))
    let shIndex = try XCTUnwrap(found.firstIndex(of: sh))
    XCTAssertLessThan(sleepIndex, shIndex)
    XCTAssertTrue(tree.allSatisfy { $0.startTime != 0 }, "start times read for identity checks")
    // The tree kill reaches the grandchild; an entry whose process is gone is skipped on an
    // identity-checked pass.
    launch.box.kill()
    for pid in [sleep, sh] {
      let gone = await processGone(pid)
      XCTAssertTrue(gone, "\(pid) survived")
    }
    ShellRunner.ProcessTree.signal(tree, SIGKILL, verifyingIdentity: true) // nothing left to hit; must not crash
  }
}

/// Records the jobs an exit handler saw, from whatever thread fired it.
private final class ExitRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [JobRegistry.Job] = []

  func record(_ job: JobRegistry.Job) {
    lock.withLock { recorded.append(job) }
  }

  var jobs: [JobRegistry.Job] {
    lock.withLock { recorded }
  }
}

/// Holds a poll handed over from a task the test does not await (so a hung poll fails the test
/// through an expectation's timeout instead of hanging it).
private final class PollBox: @unchecked Sendable {
  private let lock = NSLock()
  private var poll: JobRegistry.Poll?

  func set(_ poll: JobRegistry.Poll?) {
    lock.withLock { self.poll = poll }
  }

  var value: JobRegistry.Poll? {
    lock.withLock { poll }
  }
}
