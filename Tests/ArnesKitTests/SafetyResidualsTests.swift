import XCTest
@testable import ArnesKit
import OpenRouterSwift

/// S7 — three "narrow, never widen" residuals closed together: the verifier's untracked-file
/// paste honors the run's path rules (`paths.denyRead` and friends) instead of `.default`; the
/// background-jobs directory is identity-pinned like its log files; `web_fetch` taints per result
/// (a host outside the allowlist the human approved) rather than per tool.
final class SafetyResidualsTests: XCTestCase {
  // MARK: - Fixtures

  /// An empty XDG config home, so the developer's own git ignore rules can't hide an untracked
  /// file from `ls-files --exclude-standard`.
  private static let hermeticConfigHome: URL = {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-s7-xdg-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()
  private static let hermeticGit = [
    "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": hermeticConfigHome.path,
  ]
  private static let hermeticEnvironment = SubprocessEnvironment(
    policy: ShellEnvironmentPolicy(set: hermeticGit))

  /// A file `read_file` would refuse under the rule below — deliberately *not* a secret-shaped
  /// name (`*.pem`, `.env`…), which `ReviewDiff` skips by name whatever the rules say: the pin
  /// must show the *rules* doing the work, with the default rules as the control that pastes it.
  private static let deniedName = "internal-notes.txt"
  private static let deniedMarker = "S7DENIEDBYTESMARKER"
  private static let denyRules = PathScope.Rules(policy: PathPolicy(denyRead: ["internal-*.txt"]))

  private var scratch: URL!

  override func setUpWithError() throws {
    scratch = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("arnes-s7-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    scratch = scratch.resolvingSymlinksInPath()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: scratch)
  }

  @discardableResult
  private func git(_ arguments: [String], in root: URL) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.currentDirectoryURL = root
    process.environment = ProcessInfo.processInfo.environment.merging(Self.hermeticGit) { _, pinned in pinned }
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) failed")
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// A repository with one commit, an untracked `notes.txt` and an untracked `internal-notes.txt`
  /// carrying the marker the rules must keep out of every verifier request.
  private func makeRepositoryWithDeniedFile() throws -> URL {
    try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: "/usr/bin/git"), "no git")
    let root = scratch.appendingPathComponent("repo", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try git(["init", "-q"], in: root)
    try git(["symbolic-ref", "HEAD", "refs/heads/main"], in: root)
    try "hello\n".write(to: root.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: root)
    try git(["-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", "initial"], in: root)
    try "plain notes\n".write(to: root.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
    try "keep out: \(Self.deniedMarker)\n".write(
      to: root.appendingPathComponent(Self.deniedName), atomically: true, encoding: .utf8)
    return root
  }

  private func verdictReply() -> ChatCompletionResponse {
    let object: JSONValue = [
      "pass": .bool(true), "confidence": .string("high"),
      "reasons": .array([.string("notes added")]), "unmet": .array([]),
    ]
    return Fixtures.textResponse(HeadlessJSON.line(object), cost: 0.002)
  }

  private func tempRecordStore() -> RunRecordStore {
    RunRecordStore(url: scratch.appendingPathComponent("runs-\(UUID().uuidString).jsonl"))
  }

  private func lastUserText(of request: ChatCompletionRequest) -> String {
    request.messages.last?.content?.plainText ?? ""
  }

  // MARK: - 1. The verifier's paste honors the run's path rules

  func testVerifierPasteHonorsDenyReadAndNamesTheFileInstead() async throws {
    let repo = try makeRepositoryWithDeniedFile()

    let mock = MockOpenRouterService()
    mock.chatResponses = [verdictReply()]
    _ = try await Verifier.run(
      task: "add notes", outcome: "added notes.txt", model: "verifier/model", service: mock,
      context: Verifier.Context(
        workingDirectory: repo, environment: Self.hermeticEnvironment, rules: Self.denyRules))
    let text = lastUserText(of: mock.requests[0])
    XCTAssertTrue(text.contains("+plain notes"), text)
    XCTAssertFalse(text.contains(Self.deniedMarker), "the denied file's bytes reached the verifier: \(text)")
    XCTAssertTrue(
      text.contains("\(Self.deniedName) (denied by paths.denyRead, not read)"),
      "the skipped file is named, not pasted: \(text)")

    // The control — `.default` knows nothing of the user's globs and pastes the file: the hole.
    let control = MockOpenRouterService()
    control.chatResponses = [verdictReply()]
    _ = try await Verifier.run(
      task: "add notes", outcome: "added notes.txt", model: "verifier/model", service: control,
      context: Verifier.Context(workingDirectory: repo, environment: Self.hermeticEnvironment))
    let pasted = lastUserText(of: control.requests[0])
    XCTAssertTrue(pasted.contains(Self.deniedMarker), pasted)
    XCTAssertFalse(pasted.contains("not read"), pasted)
  }

  func testSessionVerifierRequestCarriesNoDeniedBytes() async throws {
    let repo = try makeRepositoryWithDeniedFile()
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [[Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)]]
    mock.chatResponses = [verdictReply()]
    let agent = Agent(
      service: mock, tools: [], store: tempRecordStore(),
      configuration: .init(model: "test/model", workingDirectory: repo, pathRules: Self.denyRules))

    let result = try await agent.run(task: "add notes", model: "test/model", verifierModel: "verifier/model")

    XCTAssertEqual(result.record.verifierPassed, true)
    let verifierRequest = try XCTUnwrap(
      mock.requests.first { lastUserText(of: $0).hasPrefix("Task:") },
      "the verifier's request is the one whose user message starts with the task")
    let text = lastUserText(of: verifierRequest)
    XCTAssertFalse(text.contains(Self.deniedMarker), text)
    XCTAssertTrue(text.contains("\(Self.deniedName) (denied by paths.denyRead, not read)"), text)
    XCTAssertTrue(text.contains("+plain notes"), text)
  }

  func testForSubagentCarriesThePathRulesAndTheDefaultIsDefault() {
    let lead = Session.Configuration(model: "m", pathRules: Self.denyRules)
    let nested = lead.forSubagent(named: "helper", model: "m", systemSuffix: "role")
    XCTAssertEqual(nested.pathRules, Self.denyRules)
    XCTAssertEqual(Session.Configuration(model: "m").pathRules, .default)
  }

  // MARK: - 2. The jobs directory is identity-pinned like its logs

  /// Polls until the job's output carries `expected` (an exit can land a beat before the log's
  /// last bytes are readable).
  private func awaitOutput(_ registry: JobRegistry, id: Int, containing expected: String) async -> JobRegistry.Poll? {
    var poll = await registry.wait(id: id, seconds: 15)
    var tries = 0
    while let current = poll, !current.text.contains(expected), current.logRefusal == nil, tries < 50 {
      try? await Task.sleep(nanoseconds: 100_000_000)
      poll = await registry.wait(id: id, seconds: 5)
      tries += 1
    }
    return poll
  }

  func testTheDirectoryIsCreatedEagerlyAndASecondStartIsRefusedOnceItBecameALink() async throws {
    let decoy = scratch.appendingPathComponent("decoy", isDirectory: true)
    try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
    let marker = decoy.appendingPathComponent("keep.txt")
    try "KEEP\n".write(to: marker, atomically: true, encoding: .utf8)

    let registry = JobRegistry(logRoot: scratch)
    let directory = registry.logDirectory
    // Eager, a real directory, 0700 — before any job exists.
    let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
    XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeDirectory)
    XCTAssertEqual(((attributes[.posixPermissions] as? Int) ?? 0) & 0o777, 0o700)

    // The job replaces the registry's directory with a link to the decoy.
    let command = "echo real; rm -rf '\(directory.path)'; ln -s '\(decoy.path)' '\(directory.path)'"
    _ = try await registry.start(command: command, cwd: scratch)
    _ = await registry.wait(id: 1, seconds: 15)

    do {
      _ = try await registry.start(command: "echo hijacked > hijacked.txt", cwd: scratch)
      XCTFail("a link at the directory's path must refuse the start")
    } catch let error as JobRegistry.JobError {
      XCTAssertTrue("\(error)".contains("is not the directory this session created"), "\(error)")
      XCTAssertTrue("\(error)".contains("symbolic link"), "\(error)")
    }
    XCTAssertEqual(
      Set(try FileManager.default.contentsOfDirectory(atPath: decoy.path)), ["keep.txt"],
      "nothing was created through the link")

    // `killAll` unlinks the link and removes nothing through it.
    await registry.killAll()
    XCTAssertNil(try? FileManager.default.attributesOfItem(atPath: directory.path), "the planted link is unlinked")
    XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "KEEP\n")

    // Sticky: a real directory put back at the path is not the one this session created.
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    do {
      _ = try await registry.start(command: "echo again", cwd: scratch)
      XCTFail("a refused directory stays refused")
    } catch let error as JobRegistry.JobError {
      XCTAssertTrue("\(error)".contains("is not the directory this session created"), "\(error)")
    }
    let none = await registry.snapshot().filter { $0.id > 1 }
    XCTAssertTrue(none.isEmpty)
  }

  func testInitSkipsAnOccupiedCandidateAndRefusesWhenEveryCandidateIsTaken() async throws {
    let decoy = scratch.appendingPathComponent("decoy2", isDirectory: true)
    try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
    // A link planted exactly where the first candidate would go: `mkdir` refuses it (`EEXIST`),
    // nothing is created through it, and the next candidate is taken instead.
    let planted = scratch.appendingPathComponent("arnes-jobs-aaaaaaaa")
    try FileManager.default.createSymbolicLink(at: planted, withDestinationURL: decoy)

    let registry = JobRegistry(logRoot: scratch, keepsLogs: false, directorySuffixes: ["aaaaaaaa", "bbbbbbbb", "cccccccc"])
    XCTAssertEqual(registry.logDirectory.lastPathComponent, "arnes-jobs-bbbbbbbb")
    let job = try await registry.start(command: "echo fine", cwd: scratch)
    let maybePoll = await awaitOutput(registry, id: job.id, containing: "fine")
    let poll = try XCTUnwrap(maybePoll)
    XCTAssertNil(poll.logRefusal)
    XCTAssertEqual(poll.text, "fine\n")
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: decoy.path).isEmpty,
      "nothing was created through the planted link")
    await registry.killAll()
    XCTAssertFalse(FileManager.default.fileExists(atPath: registry.logDirectory.path))
    XCTAssertNotNil(try? FileManager.default.attributesOfItem(atPath: planted.path), "the planted link is not ours to remove")

    // Every candidate occupied: the registry starts unavailable and the first `start` says why.
    for suffix in ["dddddddd", "eeeeeeee", "ffffffff"] {
      try FileManager.default.createDirectory(
        at: scratch.appendingPathComponent("arnes-jobs-\(suffix)"), withIntermediateDirectories: false)
    }
    let stuck = JobRegistry(logRoot: scratch, keepsLogs: false, directorySuffixes: ["dddddddd", "eeeeeeee", "ffffffff"])
    do {
      _ = try await stuck.start(command: "echo x", cwd: scratch)
      XCTFail("no directory, no jobs")
    } catch let error as JobRegistry.JobError {
      XCTAssertTrue("\(error)".contains("could not be created"), "\(error)")
      XCTAssertTrue("\(error)".contains("background jobs are unavailable"), "\(error)")
    }
    let none = await stuck.snapshot()
    XCTAssertTrue(none.isEmpty)
  }

  func testDirectoryRefusalDistinguishesALinkAFileAndAnotherDirectory() throws {
    let ours = scratch.appendingPathComponent("ours", isDirectory: true)
    try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: false)
    let identity = try XCTUnwrap(FileIdentity.of(ours.path))
    XCTAssertNil(JobRegistry.directoryRefusal(ours, identity: identity))

    let other = scratch.appendingPathComponent("other", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
    XCTAssertNotNil(JobRegistry.directoryRefusal(other, identity: identity), "another directory is not ours")

    let link = scratch.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ours)
    let linkRefusal = try XCTUnwrap(JobRegistry.directoryRefusal(link, identity: identity))
    XCTAssertTrue(linkRefusal.contains("symbolic link"), "a link to our own directory is still refused: \(linkRefusal)")

    let file = scratch.appendingPathComponent("file")
    try "x".write(to: file, atomically: true, encoding: .utf8)
    XCTAssertNotNil(JobRegistry.directoryRefusal(file, identity: identity))
    XCTAssertNotNil(JobRegistry.directoryRefusal(scratch.appendingPathComponent("missing"), identity: identity))
  }

  // MARK: - 3. `web_fetch` taints per result

  private static func resolver() -> HostResolver {
    { _ in ["93.184.216.34"] }
  }

  private func webTool(policy: WebFetchPolicy, stub: StubWebFetchPerformer) -> WebFetchTool {
    WebFetchTool(policy: policy, performer: stub, resolver: Self.resolver())
  }

  private func html(_ body: String) -> WebFetchResponse {
    WebFetchResponse(statusCode: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(body.utf8))
  }

  private func flagged(_ events: [AgentEvent]) -> Bool {
    events.contains { event in
      if case .contentFlagged = event { return true }
      return false
    }
  }

  func testTheToolAnswersPerCall() {
    let tool = webTool(
      policy: WebFetchPolicy(allowedDomains: ["docs.example.com"], deniedDomains: ["evil.example.org"]),
      stub: StubWebFetchPerformer())
    XCTAssertFalse(tool.taintsResults, "the per-tool bit stays off: an allowlisted page is the user's declared trust")
    XCTAssertFalse(tool.taintsResult(arguments: ["url": .string("https://docs.example.com/guide")]))
    XCTAssertTrue(tool.taintsResult(arguments: ["url": .string("https://other.example.net/a?b=c")]))
    XCTAssertTrue(tool.taintsResult(arguments: ["url": .string("https://93.184.216.34/")]))
    XCTAssertFalse(tool.taintsResult(arguments: ["url": .string("https://evil.example.org/")]), "the floor fetched nothing")
    XCTAssertFalse(tool.taintsResult(arguments: ["url": .string("not a url")]), "the coaching error fetched nothing")
    XCTAssertFalse(tool.taintsResult(arguments: [:]))
    // The source names the host only — never the path or the query, which may carry what the
    // page was asked to exfiltrate.
    XCTAssertEqual(tool.taintSource(arguments: ["url": .string("https://other.example.net/a/b?k=SECRET")]), "web:other.example.net")
    XCTAssertEqual(tool.taintSource(arguments: [:]), "web")
    XCTAssertEqual(tool.taintReason(arguments: ["url": .string("https://other.example.net/")]), "fetched a host outside web.allowedDomains")
  }

  func testAnApprovedUnlistedFetchTaintsAndClosesLaterAllowlistedFetches() async throws {
    let stub = StubWebFetchPerformer()
    stub.responses["https://other.example.net/"] = html("<p>Elsewhere.</p>")
    stub.responses["https://docs.example.com/two"] = html("<p>Step two.</p>")
    let permissions = RequestRecordingPermissions(decisions: [.allow, .allow])
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "web_fetch", arguments: #"{"url":"https://other.example.net/"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c2", name: "web_fetch", arguments: #"{"url":"https://docs.example.com/two"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [webTool(policy: WebFetchPolicy(allowedDomains: ["docs.example.com"]), stub: stub)],
      permissions: permissions,
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("read elsewhere, then the guide"))

    // Both pages were fetched: the human approved the unlisted host, and again the allowlisted
    // one — which was free before the taint and the loud prompt after it.
    XCTAssertEqual(stub.fetched.map(\.url.absoluteString), ["https://other.example.net/", "https://docs.example.com/two"])
    XCTAssertFalse(flagged(events), "no scanner flag: the taint is by policy, not by content")
    let isTainted = await session.isTainted
    XCTAssertTrue(isTainted)
    XCTAssertEqual(permissions.requests.count, 2, "\(permissions.requests.map(\.summary))")
    let first = permissions.requests[0]
    XCTAssertEqual(first.tier, .sensitive)
    XCTAssertFalse(first.tainted, "the first fetch happens before any taint")
    let second = permissions.requests[1]
    XCTAssertEqual(second.toolName, "web_fetch")
    XCTAssertEqual(second.tier, .sensitive)
    XCTAssertTrue(second.tainted)
    XCTAssertTrue(
      second.summary.hasPrefix("[after untrusted content from web:other.example.net: fetched a host outside web.allowedDomains] "),
      second.summary)
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertEqual(record.tainted, true)
    XCTAssertEqual(record.decisions?.map(\.tool), ["web_fetch", "web_fetch"])
    XCTAssertEqual(record.decisions?.map(\.tier), [.sensitive, .sensitive])
    XCTAssertEqual(record.decisions?.map(\.decision), [.allow, .allow])
    // The audit row says why the second, allowlisted fetch was gated at all.
    XCTAssertEqual(record.decisions?.map(\.reason), [nil, "tainted web fetch"])
  }

  func testAnApprovedLiteralAddressFetchTaintsWithTheAddressAsItsSource() async throws {
    let stub = StubWebFetchPerformer()
    stub.responses["https://93.184.216.34/"] = html("<p>Bare.</p>")
    stub.responses["https://docs.example.com/two"] = html("<p>Step two.</p>")
    let permissions = RequestRecordingPermissions(decisions: [.allow, .allow])
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "web_fetch", arguments: #"{"url":"https://93.184.216.34/"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c2", name: "web_fetch", arguments: #"{"url":"https://docs.example.com/two"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [webTool(policy: WebFetchPolicy(allowedDomains: ["docs.example.com"]), stub: stub)],
      permissions: permissions,
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))
    _ = try await Events.drain(await session.send("read the bare address, then the guide"))

    XCTAssertEqual(stub.fetched.map(\.url.absoluteString), ["https://93.184.216.34/", "https://docs.example.com/two"])
    let isTainted = await session.isTainted
    XCTAssertTrue(isTainted)
    XCTAssertEqual(permissions.requests.count, 2)
    XCTAssertTrue(
      permissions.requests[1].summary.hasPrefix("[after untrusted content from web:93.184.216.34: fetched a host outside web.allowedDomains] "),
      permissions.requests[1].summary)
  }

  func testADeniedHostRefusedAtTheFloorTaintsNothing() async throws {
    let stub = StubWebFetchPerformer()
    stub.responses["https://evil.example.org/x"] = html("<p>Never seen.</p>")
    stub.responses["https://docs.example.com/two"] = html("<p>Step two.</p>")
    // The human says yes to the denied host; the execute-time floor still refuses it, so nothing
    // was fetched and nothing taints — the next allowlisted fetch is as free as ever.
    let permissions = RequestRecordingPermissions(decisions: [.allow])
    let mock = MockOpenRouterService()
    mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
    mock.chunkScripts = [
      [Fixtures.toolCallChunk(id: "c1", name: "web_fetch", arguments: #"{"url":"https://evil.example.org/x"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.toolCallChunk(id: "c2", name: "web_fetch", arguments: #"{"url":"https://docs.example.com/two"}"#), Fixtures.usageChunk(cost: 0.01)],
      [Fixtures.textChunk("done"), Fixtures.usageChunk(cost: 0.01)],
    ]
    let session = Session(
      service: mock,
      tools: [webTool(
        policy: WebFetchPolicy(allowedDomains: ["docs.example.com"], deniedDomains: ["evil.example.org"]), stub: stub)],
      permissions: permissions,
      store: tempRecordStore(),
      configuration: .init(model: "test/model"))
    let events = try await Events.drain(await session.send("read evil, then the guide"))

    XCTAssertEqual(stub.fetched.map(\.url.absoluteString), ["https://docs.example.com/two"])
    XCTAssertFalse(flagged(events))
    let isTainted = await session.isTainted
    XCTAssertFalse(isTainted, "a fetch the floor refused is not untrusted content — nothing was read")
    XCTAssertEqual(permissions.requests.count, 1, "the allowlisted fetch stayed free: \(permissions.requests.map(\.summary))")
    let maybeRecord = await session.lastRecord
    let record = try XCTUnwrap(maybeRecord)
    XCTAssertNil(record.tainted)
  }
}
