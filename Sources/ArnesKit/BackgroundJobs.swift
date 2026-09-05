import Foundation
import OpenRouterSwift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

// MARK: - JobRegistry

/// Background shell jobs (T2): the commands `bash … background: true` launched detached, with
/// their output in a log file the `job` tool reads back. One registry per session, shared by the
/// `bash` tool that starts jobs and the `job` tool that polls, waits for and kills them — built
/// by the CLI (`ArnesRuntime.jobRegistry()`) and handed to both through `ToolContext.jobs`; a
/// nested session gets a fresh one so killing its jobs when its turn returns never touches the
/// lead's (`TaskTool`).
///
/// **Where the logs live**: under the OS temp directory (`<NSTemporaryDirectory()>/arnes-jobs-
/// <registry id>/job-<n>.log`, 0700 / 0600), not under `~/.arnes/tmp` — the OS sandbox denies
/// every write under `~/.arnes` (`ShellSandbox.defaultProtectedSubpaths`), so a sandboxed job
/// could not write there, and only the one open session directory under the spill root is
/// readable, so the model could not read it. The temp directory is on the sandbox's writable
/// list (`temporaryWritablePaths`); a `read_file` there classifies `.outside` (a `.sensitive`
/// read prompt), which is why the `job` tool returns the tail itself.
///
/// **Lifetime**: a job runs until it exits, is killed with `job(kill)`, or its registry is shut
/// down — `Session.shutdown()` (from `end(reason:)`, so the REPL's exit, `/resume`, `/fork`,
/// `/clear` and a headless run's end all kill their jobs) and the task tool when a nested turn
/// returns. Killing is a process-tree kill (`ShellRunner.ProcessTree`): SIGTERM to the
/// descendants leaf-first and the shell, SIGKILL two seconds later to whatever ignored it.
/// The log directory goes with the registry's jobs unless `ARNES_KEEP_TMP=1` (the spill rule).
///
/// **Cap**: `maxJobs` (16) running at once; the next `start` is refused with the reason, never
/// queued — a job that finished frees its slot.
///
/// **The log is read in the harness process, outside any sandbox**, and the job knows where it
/// is (the started line prints the path; the directory is writable to a sandboxed job by
/// design). So a job whose script is hostile could swap its own log for a symbolic link to
/// `~/.ssh/id_rsa`, a hard link, a FIFO or a re-linked directory and have the model's next
/// `job(id)` hand it the bytes the sandbox denied it — or block the actor forever. Every read
/// therefore refuses anything but the regular file the registry itself created: the log is
/// created `O_EXCL | O_NOFOLLOW` (a pre-planted path refuses the start), its identity (device +
/// inode) is taken from the descriptor, and a poll `lstat`s the path, opens it `O_NOFOLLOW |
/// O_NONBLOCK`, and `fstat`s what it got before reading a byte — a mismatch is a
/// `Poll.logRefusal`, never a read (the door A8's diff, C4's restore and X6's untracked paste
/// closed for their own unsandboxed reads).
public actor JobRegistry {
  /// One background job as the registry knows it.
  public struct Job: Sendable, Equatable {
    /// The number the model addresses it by (`job 1 started`), 1-based per registry.
    public let id: Int
    public let command: String
    /// The shell's pid (under a sandbox `sandbox-exec` execs the shell in place, same pid).
    public let pid: Int32
    /// Where stdout + stderr land, 0600 under the registry's 0700 log directory.
    public let logURL: URL
    public let startedAt: Date
    /// Shell-style: the exit code, or 128 + the signal for a job a signal ended (143 for the
    /// registry's SIGTERM). nil while running.
    public var exitStatus: Int32?
    public var exitedAt: Date?
    /// Bytes of the log the `job` tool has handed the model so far — a poll returns what came
    /// after this and moves it.
    public var lastReadOffset: Int
    /// The registry ended it (`kill(id:)` or `killAll`), not the command itself.
    public var killed: Bool
    /// Set by `killAll`: the exit is the session ending, so no event and no notice follow it.
    var shutdownKill = false
    /// The job ran under an OS sandbox; its log is annotated like a foreground result.
    var sandboxed = false
    /// Device + inode of the log file the registry created, read off the descriptor it opened.
    /// Every poll checks the file it opens against this before reading — a link, a FIFO or a
    /// swapped directory at the path is refused, never read.
    var logIdentity: FileIdentity?

    public init(
      id: Int, command: String, pid: Int32, logURL: URL, startedAt: Date = Date(),
      exitStatus: Int32? = nil, exitedAt: Date? = nil, lastReadOffset: Int = 0, killed: Bool = false)
    {
      self.id = id
      self.command = command
      self.pid = pid
      self.logURL = logURL
      self.startedAt = startedAt
      self.exitStatus = exitStatus
      self.exitedAt = exitedAt
      self.lastReadOffset = lastReadOffset
      self.killed = killed
    }

    public var isRunning: Bool { exitStatus == nil }

    /// `running` / `exited 0` / `exited 143 (killed)` — the state word the tool and the
    /// listings share.
    public var stateLabel: String {
      guard let exitStatus else { return "running" }
      return "exited \(exitStatus)" + (killed ? " (killed)" : "")
    }

    /// The `[arnes]` notice queued for the model when a job it started exits on its own
    /// (`Session.notify`): the fact, the log, and how to read it.
    public var exitNotice: String {
      "background job \(id) exited \(exitStatus ?? -1) — see \(logURL.path) "
        + "(job(id: \"\(id)\") shows the output written since your last poll)"
    }
  }

  /// What one poll of a job returns: its state, how much the log grew since the last poll and
  /// the (bounded) text of that growth.
  public struct Poll: Sendable, Equatable {
    public let job: Job
    /// Bytes appended to the log since the last poll.
    public let newBytes: Int
    /// The new output, at most `tailChars` characters of its tail.
    public let text: String
    /// Characters (approximately: bytes past the read window, then characters over the cap) of
    /// the new output the tail left out.
    public let omittedChars: Int
    /// Set when the log was **not** read: the path no longer leads to the regular file this
    /// registry created — it is gone, or the job (or anything else) put a symbolic link, a FIFO, a
    /// device, a directory or a different file there, or re-linked the log directory. The
    /// registry reads in the harness process, outside any sandbox, so a swapped path is refused
    /// rather than followed: `text` is empty, `newBytes` and `omittedChars` are 0, and the read
    /// offset did not move. The clause says what was found ("it is now a symbolic link, …").
    public let logRefusal: String?

    public init(job: Job, newBytes: Int, text: String, omittedChars: Int, logRefusal: String? = nil) {
      self.job = job
      self.newBytes = newBytes
      self.text = text
      self.omittedChars = omittedChars
      self.logRefusal = logRefusal
    }
  }

  public enum JobError: Error, CustomStringConvertible, Equatable {
    case tooManyJobs(limit: Int)
    case cannotStart(String)

    public var description: String {
      switch self {
      case .tooManyJobs(let limit):
        return "\(limit) background jobs are already running — wait for one (job wait) or kill one before starting another"
      case .cannotStart(let reason):
        return reason
      }
    }
  }

  /// Jobs running at once, per registry.
  public static let maxJobs = 16
  /// The most output one poll hands the model.
  public static let tailChars = 8_000
  /// How much of a log a poll reads to produce a tail (bytes): the rest is counted, not read.
  static let readWindowBytes = tailChars * 4

  /// Where this registry's logs live — created at init, exclusively and 0700, removed by
  /// `killAll` (S7: created *before* any job runs, so a link planted at the path can never be the
  /// directory the first job writes into).
  public nonisolated let logDirectory: URL
  private let keepsLogs: Bool
  private var jobs: [Int: Job] = [:]
  private var launches: [Int: ShellRunner.Launch] = [:]
  private var nextId = 1
  private var exitWaiters: [Int: [UUID: CheckedContinuation<Void, Never>]] = [:]
  /// The identity (device + inode) of the log directory as this registry created it (S7): every
  /// `start` and the `killAll` cleanup re-check that the path still leads to that directory — a
  /// link, a file or another directory put at the path is refused, never written into or removed
  /// through. nil when the directory could not be created (then `directoryUnavailable` says why)
  /// or when `killAll` removed it (then `directoryRemoved` says the next `start` makes it again).
  private var directoryIdentity: FileIdentity?
  /// Set when the directory was never created or was refused once: sticky for the registry's
  /// life, so every later `start` is refused with this reason (the path is not ours any more).
  private var directoryUnavailable: String?
  /// Set by `killAll` once it removed the directory (or unlinked what a job left at its path): a
  /// registry outlives a session's end — the REPL keeps one toolset across `/clear`, `/resume`
  /// and `/fork`, and `shutdown()` is idempotent — so the next `start` makes the directory again,
  /// exclusively, at the same path; anything that appeared there meanwhile is refused for good.
  private var directoryRemoved = false
  /// The turn's event stream, when a turn is in flight (`JobTool.onEvent` writes it).
  nonisolated let events = JobEventSink()
  /// Whoever wants to know a job exited on its own (the session's `notify`, the REPL's line).
  nonisolated let exitHandler = JobExitHandler()

  /// - Parameters:
  ///   - logRoot: the directory the registry's own log directory is created under; the OS temp
  ///     directory by default (see the type comment for why not `~/.arnes/tmp`).
  ///   - keepsLogs: leave the log directory behind at `killAll` (`ARNES_KEEP_TMP=1`).
  public init(
    logRoot: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true),
    keepsLogs: Bool = ToolOutputLimiter.keepsSpillFiles())
  {
    self.keepsLogs = keepsLogs
    // Eager and exclusive (S7): `mkdir(2)` fails on anything already at the path — a planted link
    // included — so a fresh suffix is tried instead, and the identity of what *this* call created
    // is what every later `start` and the `killAll` cleanup check the path against.
    let created = Self.createDirectory(under: logRoot)
    logDirectory = created.url
    directoryIdentity = created.identity
    directoryUnavailable = created.failure
  }

  /// The tests' init: the same registry over a directory whose candidate suffixes are given
  /// (`arnes-jobs-<suffix>`), so an occupied first candidate is a deterministic scenario.
  init(logRoot: URL, keepsLogs: Bool, directorySuffixes: [String]) {
    self.keepsLogs = keepsLogs
    let created = Self.createDirectory(under: logRoot, suffixes: directorySuffixes)
    logDirectory = created.url
    directoryIdentity = created.identity
    directoryUnavailable = created.failure
  }

  /// `<root>/arnes-jobs-<id8>/`, made with `mkdir` (never `ensureDirectory`, which accepts — and
  /// would follow — an entry already there), mode 0700; a new suffix on `EEXIST` (three tries), a
  /// missing root created once (it is the caller's, not ours to pin); any other failure is the
  /// reason every job will be refused with.
  static func createDirectory(
    under root: URL, suffixes: [String]? = nil)
    -> (url: URL, identity: FileIdentity?, failure: String?)
  {
    var url = root
    var lastFailure = "no attempt made"
    var rootCreated = false
    var attempts = 0
    let candidates = suffixes ?? (0..<3).map { _ in String(UUID().uuidString.lowercased().prefix(8)) }
    while attempts < min(3, candidates.count) {
      url = root.appendingPathComponent("arnes-jobs-\(candidates[attempts])", isDirectory: true)
      attempts += 1
      let made = Self.makeDirectory(at: url)
      if let identity = made.identity { return (url, identity, nil) }
      let code = made.code
      guard code != 0 else {
        return (url, nil, "the job log directory at \(url.path) is not the directory this session created (it could not be identified after it was made); background jobs are unavailable for the rest of the session")
      }
      lastFailure = String(cString: strerror(code))
      if code == ENOENT, !rootCreated {
        rootCreated = true
        try? SecureFiles.ensureDirectory(root)
        attempts -= 1
        continue
      }
      if code != EEXIST { break }
    }
    return (url, nil, "the job log directory at \(url.path) could not be created (\(lastFailure)); background jobs are unavailable for the rest of the session")
  }

  /// `mkdir(2)` at exactly `url`, mode 0700 — exclusive by construction: anything already at the
  /// path (a planted link, a file, a directory) is `EEXIST` and a link is never followed. On
  /// success the identity of what was just made; otherwise `errno` (0 with a nil identity = made
  /// but not identifiable, a `stat` failure right after a successful `mkdir`).
  static func makeDirectory(at url: URL) -> (identity: FileIdentity?, code: Int32) {
    guard mkdir(url.path, 0o700) == 0 else { return (nil, errno) }
    return (FileIdentity.of(url.path), 0)
  }

  /// nil when `url` is still the directory this registry created (S7): `lstat` first — a symbolic
  /// link at the path is refused before anything follows it, as is a file or a missing entry —
  /// then the directory's own device + inode must be the ones `mkdir` produced.
  static func directoryRefusal(_ url: URL, identity: FileIdentity) -> String? {
    var info = stat()
    guard lstat(url.path, &info) == 0 else {
      return "the job log directory at \(url.path) is not the directory this session created (nothing is at its path any more); background jobs are unavailable for the rest of the session"
    }
    let mode = info.st_mode & mode_t(S_IFMT)
    if mode == mode_t(S_IFLNK) {
      return "the job log directory at \(url.path) is not the directory this session created (a symbolic link stands at its path); background jobs are unavailable for the rest of the session"
    }
    let current = FileIdentity(device: Int64(clamping: info.st_dev), inode: UInt64(clamping: info.st_ino))
    guard mode == mode_t(S_IFDIR), current == identity else {
      return "the job log directory at \(url.path) is not the directory this session created; background jobs are unavailable for the rest of the session"
    }
    return nil
  }

  deinit {
    // A registry that never ran a job — or was never shut down — leaves no empty directory behind:
    // `rmdir` removes only an empty directory, never a link's target, never a populated one — and
    // only a directory this registry created (S7): a path it never owned is never touched.
    if !keepsLogs, directoryIdentity != nil { rmdir(logDirectory.path) }
    // A registry dropped with jobs still running (an embedder that never shut it down): the
    // shells get their SIGTERM at least, tree and all.
    for launch in launches.values where launch.box.isRunning {
      launch.box.kill()
    }
  }

  // MARK: Handlers

  /// Sets what happens when a job exits on its own (not killed by the registry): the CLI queues
  /// `job.exitNotice` on the live session with `Session.notify` and, between turns, prints a
  /// line; the task tool does the same for a nested session. One handler; the last set wins.
  public nonisolated func setExitHandler(_ handler: (@Sendable (Job) -> Void)?) {
    exitHandler.set(handler)
  }

  // MARK: Starting

  /// Launches `command` detached, its output to a fresh log, and returns the job at once.
  /// Refused over `maxJobs` running jobs. Emits `.jobStarted` into the turn's stream when one
  /// is bound.
  public func start(
    command: String,
    cwd: URL?,
    sandbox: ShellSandbox? = nil,
    environment: SubprocessEnvironment = .default)
    throws -> Job
  {
    let running = jobs.values.filter(\.isRunning).count
    guard running < Self.maxJobs else { throw JobError.tooManyJobs(limit: Self.maxJobs) }
    // The directory must still be ours (S7): refused once, refused for good.
    if let refusal = directoryUnavailable { throw JobError.cannotStart(refusal) }
    if directoryRemoved {
      // Our own `killAll` removed it: made again at the same path, exclusively — an entry that
      // appeared there since (a link, a file, somebody's directory) is `EEXIST`, never used.
      let made = Self.makeDirectory(at: logDirectory)
      guard let identity = made.identity else {
        let refusal = made.code == EEXIST
          ? "the job log directory at \(logDirectory.path) is not the directory this session created (something else occupies the path since this session's jobs were shut down); background jobs are unavailable for the rest of the session"
          : "the job log directory at \(logDirectory.path) could not be created again (\(made.code == 0 ? "it could not be identified after it was made" : String(cString: strerror(made.code)))); background jobs are unavailable for the rest of the session"
        directoryUnavailable = refusal
        throw JobError.cannotStart(refusal)
      }
      directoryIdentity = identity
      directoryRemoved = false
    }
    guard let identity = directoryIdentity else {
      let refusal = "the job log directory was not created; background jobs are unavailable for the rest of the session"
      directoryUnavailable = refusal
      throw JobError.cannotStart(refusal)
    }
    if let refusal = Self.directoryRefusal(logDirectory, identity: identity) {
      directoryUnavailable = refusal
      throw JobError.cannotStart(refusal)
    }
    let id = nextId
    let logURL = logDirectory.appendingPathComponent("job-\(id).log")
    let created = try Self.createLog(at: logURL)
    // Closed explicitly below (both paths), so the handle never double-closes on dealloc.
    let handle = FileHandle(fileDescriptor: created.descriptor, closeOnDealloc: false)
    let launch: ShellRunner.Launch
    do {
      launch = try ShellRunner.Launch(
        command: command, cwd: cwd, sandbox: sandbox, environment: environment, logHandle: handle)
    } catch {
      try? handle.close()
      try? FileManager.default.removeItem(at: logURL)
      throw JobError.cannotStart("\(error)")
    }
    // The child holds its own copy of the descriptor; ours is done once it has been spawned.
    try? handle.close()
    nextId += 1
    var job = Job(
      id: id, command: command, pid: launch.box.pid, logURL: logURL, startedAt: Date(),
      exitStatus: nil, exitedAt: nil, lastReadOffset: 0, killed: false)
    job.sandboxed = sandbox != nil
    job.logIdentity = created.identity
    jobs[id] = job
    launches[id] = launch
    let exit = launch.exit
    Task { [weak self] in
      await exit.wait()
      await self?.noteExit(id: id)
    }
    events.emit(.jobStarted(id: id, command: command))
    return job
  }

  /// The process exited: record how, wake every waiter, and — unless the registry ended it —
  /// tell the turn's stream and the exit handler.
  private func noteExit(id: Int) {
    guard var job = jobs[id], job.isRunning else { return }
    let status = launches[id]?.box.shellExitStatus ?? -1
    job.exitStatus = status
    job.exitedAt = Date()
    jobs[id] = job
    launches[id] = nil
    if let waiters = exitWaiters.removeValue(forKey: id) {
      for (_, continuation) in waiters { continuation.resume() }
    }
    if !job.shutdownKill {
      events.emit(.jobFinished(id: id, exitStatus: status))
    }
    if !job.killed {
      exitHandler.fire(job)
    }
  }

  // MARK: Reading

  /// The job, or nil for an id this registry never issued.
  public func status(id: Int) -> Job? { jobs[id] }

  /// Every job this registry has started, oldest first — running and exited alike.
  public func snapshot() -> [Job] {
    jobs.values.sorted { $0.id < $1.id }
  }

  /// Jobs still running.
  public var runningCount: Int { jobs.values.filter(\.isRunning).count }

  /// The job's state plus what its log gained since the last poll (the read offset moves) — or,
  /// when the path no longer leads to the file the registry created, the state alone with
  /// `logRefusal` set and the offset where it was.
  public func poll(id: Int) -> Poll? {
    guard var job = jobs[id] else { return nil }
    let read = Self.readNew(from: job.logURL, identity: job.logIdentity, after: job.lastReadOffset)
    if let refusal = read.refusal {
      return Poll(job: job, newBytes: 0, text: "", omittedChars: 0, logRefusal: refusal)
    }
    job.lastReadOffset = read.offset
    jobs[id] = job
    var text = read.text
    if job.sandboxed { text = BashTool.annotatingSandboxDenials(text) }
    return Poll(job: job, newBytes: read.newBytes, text: text, omittedChars: read.omitted)
  }

  /// Waits up to `seconds` for the job to exit, then polls it. Returns at once for an exited
  /// job; nil for an unknown id. Cancelling the waiting task ends the wait early.
  public func wait(id: Int, seconds: Double) async -> Poll? {
    guard jobs[id] != nil else { return nil }
    _ = await waitForExit(id: id, seconds: seconds)
    return poll(id: id)
  }

  /// Kills the job's process tree (SIGTERM, then SIGKILL for a survivor) and polls it once it
  /// has exited. A job that already exited is just polled; an unknown id is nil.
  public func kill(id: Int) async -> Poll? {
    guard var job = jobs[id] else { return nil }
    if job.isRunning, let launch = launches[id] {
      job.killed = true
      jobs[id] = job
      launch.box.kill()
      if await !waitForExit(id: id, seconds: 2) {
        launch.box.forceKill()
        _ = await waitForExit(id: id, seconds: 1)
      }
    }
    return poll(id: id)
  }

  /// Kills every running job — the session is ending — and removes the log directory (unless
  /// the logs are kept). Waits for the exits, escalating to SIGKILL after two seconds, so a
  /// process exiting after this returns is one that ignored both signals. Idempotent.
  public func killAll() async {
    let running = jobs.values.filter(\.isRunning).map(\.id).sorted()
    for id in running {
      jobs[id]?.killed = true
      jobs[id]?.shutdownKill = true
      launches[id]?.box.kill()
    }
    if !running.isEmpty {
      await withTaskGroup(of: Void.self) { group in
        for id in running {
          group.addTask { _ = await self.waitForExit(id: id, seconds: 2) }
        }
      }
      let survivors = running.filter { jobs[$0]?.isRunning == true }
      for id in survivors { launches[id]?.box.forceKill() }
      await withTaskGroup(of: Void.self) { group in
        for id in survivors {
          group.addTask { _ = await self.waitForExit(id: id, seconds: 1) }
        }
      }
    }
    // Only a directory this registry made is ever touched at the path (a registry that never
    // got one — every candidate occupied — owns nothing there); once removed, the next `start`
    // makes it again rather than writing into whatever it finds.
    if !keepsLogs, let identity = directoryIdentity {
      Self.removeLogDirectory(logDirectory, identity: identity)
      directoryIdentity = nil
      directoryRemoved = true
    }
  }

  /// Removes the registry's log directory — **the directory it created**, or unlinks whatever a
  /// job left at its path: a symbolic link is unlinked, never traversed into; a directory whose
  /// identity is not the one `mkdir` produced (another directory moved to the path) is somebody
  /// else's and is left alone (S7; the recursive removal runs only on our own directory, and
  /// `FileManager` itself never follows links inside one).
  private static func removeLogDirectory(_ url: URL, identity: FileIdentity) {
    var info = stat()
    guard lstat(url.path, &info) == 0 else { return }
    if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
      let current = FileIdentity(device: Int64(clamping: info.st_dev), inode: UInt64(clamping: info.st_ino))
      guard current == identity else { return }
      try? FileManager.default.removeItem(at: url)
    } else {
      unlink(url.path)
    }
  }

  // MARK: Waiting

  /// True once the job has exited, false when `seconds` passed first (or the task was cancelled).
  private func waitForExit(id: Int, seconds: Double) async -> Bool {
    guard let job = jobs[id] else { return false }
    if !job.isRunning { return true }
    let token = UUID()
    var deadline: Task<Void, Never>?
    await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // Checked again here, on the actor, so an exit landing between the guard above and
        // this registration resumes at once instead of waiting for the deadline.
        if jobs[id]?.isRunning == false {
          continuation.resume()
          return
        }
        exitWaiters[id, default: [:]][token] = continuation
        // Started after the registration, so the deadline can never fire into nothing.
        deadline = Task { [weak self] in
          try? await Task.sleep(nanoseconds: UInt64(max(0.01, seconds) * 1_000_000_000))
          await self?.resumeWaiter(id: id, token: token)
        }
      }
    } onCancel: {
      Task { [weak self] in await self?.resumeWaiter(id: id, token: token) }
    }
    deadline?.cancel()
    return jobs[id]?.isRunning == false
  }

  private func resumeWaiter(id: Int, token: UUID) {
    if let continuation = exitWaiters[id]?.removeValue(forKey: token) {
      continuation.resume()
    }
  }

  // MARK: Log files

  /// Creates a job's log — 0600 in the registry's 0700 directory — **exclusively**: `O_EXCL`
  /// refuses a path anything already occupies (the directory is fresh, so an existing
  /// `job-<next>.log` is itself the signal that something planted it) and `O_NOFOLLOW` refuses a
  /// symbolic link there even when `O_EXCL` would not. The file's identity is read off the
  /// descriptor, so every later read can check it still reads this file and no other.
  private static func createLog(at url: URL) throws -> (descriptor: Int32, identity: FileIdentity) {
    // The directory exists and was verified by `start` (S7) — nothing is created on the way.
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else {
      let code = errno
      let occupied = code == EEXIST || code == ELOOP
        ? " — something already occupies the path this job's log would take; it was not opened"
        : ""
      throw JobError.cannotStart(
        "could not create the job log at \(url.path): \(String(cString: strerror(code)))\(occupied)")
    }
    guard let opened = FileIdentity.of(descriptor: descriptor), opened.isRegular else {
      close(descriptor)
      throw JobError.cannotStart("could not create the job log at \(url.path): not a regular file")
    }
    return (descriptor, opened.identity)
  }

  /// One read of a job's log past the offset the model has already seen.
  struct LogRead: Equatable {
    /// The tail of the new output as text (at most `tailChars` characters).
    var text = ""
    /// Bytes the log gained since `offset`.
    var newBytes = 0
    /// Characters (approximately: bytes past the read window, then characters over the cap) of
    /// the new output the tail left out.
    var omitted = 0
    /// Where the next read starts: the log's end, or the old offset when nothing was read.
    var offset: Int
    /// Set when the path no longer leads to the file the registry created — nothing was read.
    var refusal: String?
  }

  /// The log's growth past `offset`, read from a bounded window so a huge log costs a bounded
  /// read — **only when the path still leads to the regular file the registry created**. The
  /// read happens in the harness process, outside any sandbox, and the job knows the path, so:
  /// `lstat` first (a link, a FIFO, a device or a directory is refused before anything is
  /// opened), then `open(O_RDONLY | O_NOFOLLOW | O_NONBLOCK)` (a link that appeared in between
  /// is refused by the kernel; a FIFO cannot block the actor), then `fstat` on what was actually
  /// opened: a regular file whose device + inode match `identity` — anything else, including a
  /// regular file reached through a re-linked directory or a hard link to another file, is a
  /// refusal. A missing log is a refusal too (it was deleted or moved), so the model is told
  /// rather than shown "no new output".
  static func readNew(from url: URL, identity: FileIdentity?, after offset: Int) -> LogRead {
    let path = url.path
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else {
      return LogRead(offset: offset, refusal: "it was deleted or moved after the job started")
    }
    let type = attributes[.type] as? FileAttributeType ?? .typeUnknown
    guard type == .typeRegular else {
      return LogRead(
        offset: offset, refusal: "it is now \(describe(type)), not the regular file this session created")
    }
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    guard descriptor >= 0 else {
      let code = errno
      if code == ELOOP {
        return LogRead(offset: offset, refusal: "it is now a symbolic link, not the regular file this session created")
      }
      return LogRead(offset: offset, refusal: "it could not be opened (\(String(cString: strerror(code))))")
    }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    guard let opened = FileIdentity.of(descriptor: descriptor), opened.isRegular else {
      return LogRead(offset: offset, refusal: "it is not a regular file")
    }
    if let identity, opened.identity != identity {
      return LogRead(
        offset: offset,
        refusal: "it is a different file from the one this session created (the log or its directory was replaced)")
    }
    let end = Int((try? handle.seekToEnd()) ?? UInt64(offset))
    guard end > offset else { return LogRead(offset: max(offset, end)) }
    let newBytes = end - offset
    let readFrom = max(offset, end - min(newBytes, readWindowBytes))
    try? handle.seek(toOffset: UInt64(readFrom))
    var data = (try? handle.readToEnd()) ?? Data()
    var omitted = readFrom - offset
    if readFrom > offset {
      data = ShellRunner.OutputCollector.trimmedHead(data)
    }
    var text = String(decoding: data, as: UTF8.self)
    if text.count > tailChars {
      omitted += text.count - tailChars
      text = String(text.suffix(tailChars))
    }
    return LogRead(text: text, newBytes: newBytes, omitted: omitted, offset: end)
  }

  /// What `lstat` found where the log should be, for the refusal.
  private static func describe(_ type: FileAttributeType) -> String {
    switch type {
    case .typeSymbolicLink: return "a symbolic link"
    case .typeDirectory: return "a directory"
    case .typeCharacterSpecial, .typeBlockSpecial: return "a device"
    case .typeSocket: return "a socket"
    default: return "a FIFO or another special file"
    }
  }
}

// MARK: - FileIdentity of a descriptor

extension FileIdentity {
  /// The identity of what an open descriptor refers to (`fstat`), and whether that is a regular
  /// file — the check a read makes on the file it actually opened, after `lstat` judged the path.
  static func of(descriptor: Int32) -> (identity: FileIdentity, isRegular: Bool)? {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return nil }
    let isRegular = (UInt32(info.st_mode) & UInt32(S_IFMT)) == UInt32(S_IFREG)
    let identity = FileIdentity(device: Int64(clamping: info.st_dev), inode: UInt64(clamping: info.st_ino))
    return (identity, isRegular)
  }
}

// MARK: - Sinks

/// The turn's event stream as the registry sees it: `JobTool.onEvent` (bound by the session for
/// the turn) writes it, the registry emits `.jobStarted`/`.jobFinished` through it. nil between
/// turns — a job finishing at the prompt reaches the model through `Session.notify` instead.
final class JobEventSink: @unchecked Sendable {
  private let lock = NSLock()
  private var sink: (@Sendable (AgentEvent) -> Void)?

  var current: (@Sendable (AgentEvent) -> Void)? {
    lock.withLock { sink }
  }

  func set(_ sink: (@Sendable (AgentEvent) -> Void)?) {
    lock.withLock { self.sink = sink }
  }

  func emit(_ event: AgentEvent) {
    let sink = lock.withLock { self.sink }
    sink?(event)
  }
}

/// The owner's exit callback (`JobRegistry.setExitHandler`), lock-protected so the registry can
/// fire it from its own isolation and the CLI can set it synchronously.
final class JobExitHandler: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (JobRegistry.Job) -> Void)?

  func set(_ handler: (@Sendable (JobRegistry.Job) -> Void)?) {
    lock.withLock { self.handler = handler }
  }

  func fire(_ job: JobRegistry.Job) {
    let handler = lock.withLock { self.handler }
    handler?(job)
  }
}

// MARK: - JobTool

/// `job`: the one dumb tool over a session's background jobs — `{id, action?: status|wait|kill,
/// wait_seconds?}`. Read-only and never gated: only pids the harness itself started are
/// addressable, and the answer is text the model reads. `status` (the default) reports the
/// job's state and the output written since the last poll (its last `tailChars`), `wait`
/// blocks until the job exits or `wait_seconds` (1–120, default 30) pass and then reports the
/// same, `kill` ends the job's process tree and reports. Appended to `coreTools` when the
/// context carries a registry; stripped from no nested toolset (a subagent gets its own
/// registry instead).
public final class JobTool: AgentTool, EventEmittingTool, JobHosting, @unchecked Sendable {
  public static let toolName = "job"
  public static let defaultWaitSeconds = 30
  public static let maxWaitSeconds = 120

  public let name = JobTool.toolName
  public let description =
    "Check on, wait for, or kill a background job started with bash(background: true). "
    + "action status (the default) returns the job's state and the output written since your last "
    + "poll (up to \(JobRegistry.tailChars) chars of its tail); wait blocks until it exits or "
    + "wait_seconds pass (1–\(JobTool.maxWaitSeconds), default \(JobTool.defaultWaitSeconds)) and then "
    + "reports the same; kill stops it. Only jobs this session started can be addressed."
  public let parameters: JSONValue = [
    "type": "object",
    "properties": [
      "id": ["type": "string", "description": "the job number from the bash tool's \"job N started\" result"],
      "action": [
        "type": "string",
        "enum": ["status", "wait", "kill"],
        "description": "status (default): state + new output · wait: block until it exits or wait_seconds pass · kill: stop it",
      ],
      "wait_seconds": [
        "type": "integer",
        "description": .string("for wait: how long to block (1–\(JobTool.maxWaitSeconds); default \(JobTool.defaultWaitSeconds))"),
      ],
    ],
    "required": ["id"],
  ]
  public let permission: ToolPermission = .readOnly

  let registry: JobRegistry

  public init(registry: JobRegistry) {
    self.registry = registry
  }

  /// The turn's stream, held by the registry so `bash` can emit `.jobStarted` and the exit path
  /// `.jobFinished` through the same sink.
  public var onEvent: (@Sendable (AgentEvent) -> Void)? {
    get { registry.events.current }
    set { registry.events.set(newValue) }
  }

  public func shutdownJobs() async {
    await registry.killAll()
  }

  public func summary(arguments: [String: JSONValue]) -> String {
    let id = Self.jobId(from: arguments).map(String.init) ?? "?"
    let action = arguments["action"]?.stringValue ?? "status"
    return "job \(id) \(action)"
  }

  public func execute(arguments: [String: JSONValue]) async throws -> String {
    guard let id = Self.jobId(from: arguments) else {
      let raw = arguments["id"].map { "\($0)" } ?? "(missing)"
      return "error: job id \(raw) is not a job number — use the N from the bash tool's \"job N started\" result"
    }
    let action = arguments["action"]?.stringValue?.trimmingCharacters(in: .whitespaces).lowercased() ?? "status"
    let poll: JobRegistry.Poll?
    switch action {
    case "status", "":
      poll = await registry.poll(id: id)
    case "wait":
      let requested = arguments["wait_seconds"]?.intValue ?? Self.defaultWaitSeconds
      let seconds = min(max(1, requested), Self.maxWaitSeconds)
      poll = await registry.wait(id: id, seconds: Double(seconds))
    case "kill":
      poll = await registry.kill(id: id)
    default:
      return "error: unknown action '\(action)' — use status, wait or kill"
    }
    guard let poll else {
      return "error: no such job '\(id)' — jobs are numbered by the bash tool's \"job N started\" "
        + "result and die with the session that started them"
    }
    return Self.render(poll)
  }

  /// `job <n> <running|exited K> · N new bytes since last poll\n<tail>\n(full log: <path>)` — or,
  /// for a log the registry refused to read, `job <n> <state> · log not read` and one `[arnes: …]`
  /// line saying why, with no pointer at the path (it no longer leads to the log).
  static func render(_ poll: JobRegistry.Poll) -> String {
    if let refusal = poll.logRefusal {
      return "job \(poll.job.id) \(poll.job.stateLabel) · log not read\n"
        + "[arnes: job \(poll.job.id)'s log at \(poll.job.logURL.path) is not readable: \(refusal); "
        + "nothing was read — treat the job's output as unavailable and do not read that path]"
    }
    var lines = ["job \(poll.job.id) \(poll.job.stateLabel) · "
      + (poll.newBytes == 0 ? "no new output since last poll" : "\(poll.newBytes) new bytes since last poll")]
    if poll.omittedChars > 0 {
      lines.append(
        "[… \(poll.omittedChars) chars omitted — only the last \(JobRegistry.tailChars) chars of new output "
          + "are shown; poll more often to keep up, or read_file the log (outside the working tree, so "
          + "it may need approval)]")
    }
    if !poll.text.isEmpty {
      lines.append(poll.text.hasSuffix("\n") ? String(poll.text.dropLast()) : poll.text)
    }
    lines.append("(full log: \(poll.job.logURL.path))")
    return lines.joined(separator: "\n")
  }

  /// The job number, whether the model sent `"1"` or `1`.
  static func jobId(from arguments: [String: JSONValue]) -> Int? {
    if let number = arguments["id"]?.intValue { return number }
    guard let text = arguments["id"]?.stringValue?.trimmingCharacters(in: .whitespaces) else { return nil }
    return Int(text.hasPrefix("job ") ? String(text.dropFirst(4)) : text)
  }
}
