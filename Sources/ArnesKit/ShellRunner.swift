import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Lifecycle operations shared by Foundation on Apple platforms and the Linux runner.
protocol ShellProcess: AnyObject {
  var processIdentifier: Int32 { get }
  var isRunning: Bool { get }
  var terminationStatus: Int32 { get }
  var terminationReason: Process.TerminationReason { get }
  func withRunningPID(_ body: (Int32) -> Void)
}

extension Process: ShellProcess {
  func withRunningPID(_ body: (Int32) -> Void) {
    if isRunning { body(processIdentifier) }
  }
}

/// Runs a shell command the way an agent tool needs it run.
///
/// - stdin is `/dev/null`: nothing a model launches can sit waiting on the terminal
///   (`git commit` without `-m`, a `read` builtin), and nothing competes with the REPL
///   for keystrokes.
/// - Output is collected while the command runs and the wait ends when **bash itself
///   exits**, not at pipe EOF. A background child that inherited the pipe — a telemetry
///   `curl` a git wrapper fires, git's fsmonitor daemon, a dev server left running — used
///   to keep `readDataToEndOfFile()` blocked indefinitely.
/// - A hard timeout terminates the command (SIGTERM, then SIGKILL), and cancelling the
///   surrounding task (Ctrl-C in the REPL) does the same immediately.
enum ShellRunner {
  enum SandboxError: Error, CustomStringConvertible {
    case unsupported
    var description: String {
      "a command sandbox was requested but this platform has no supported backend "
        + "(macOS needs /usr/bin/sandbox-exec; Linux is not wired yet) — refusing to run unconfined"
    }
  }

  struct Outcome {
    let exitStatus: Int32
    /// What the command printed (stdout + stderr interleaved), bounded: when it produced more
    /// than the collector keeps, this is the head, an `[… N bytes omitted …]` line, and the
    /// tail — so a failing build's last lines survive however much scrolled by.
    let output: String
    let timedOut: Bool
    let cancelled: Bool
    /// The shell itself could not be spawned (as opposed to the command exiting non-zero).
    var failedToStart = false
    /// Bytes the collector dropped between head and tail; 0 when `output` is everything.
    var truncatedBytes = 0
  }

  /// How much of a command's output the collector keeps in memory: the first `headBytes` and
  /// the last `tailBytes`; everything between is counted and dropped as it streams, so a
  /// `yes | head -c 20000000` costs the same memory as `echo`. Both bounds derive from the
  /// tool's character cap (2× each), so the session's own limiter — not this one — decides
  /// what the model reads and the spill file keeps more than the context shows.
  struct OutputBounds: Sendable, Equatable {
    let headBytes: Int
    let tailBytes: Int

    init(headBytes: Int, tailBytes: Int) {
      self.headBytes = max(1024, headBytes)
      self.tailBytes = max(1024, tailBytes)
    }

    /// Bounds for a tool that shows the model at most `capChars` characters.
    init(capChars: Int) {
      self.init(headBytes: capChars * 2, tailBytes: capChars * 2)
    }

    /// What hooks, probes and blocking callers get: generous enough that nothing they read is
    /// ever cut in practice (their own consumers cap far below it).
    static let `default` = OutputBounds(capChars: BashTool.defaultOutputChars)
  }

  /// Which shell runs the command. Tools get a login bash (the user's PATH and aliases);
  /// hooks get plain `sh -c` — a per-call guardrail shouldn't re-source rc files.
  enum Shell {
    case bashLogin
    case sh

    var executable: String {
      switch self {
      case .bashLogin: return "/bin/bash"
      case .sh: return "/bin/sh"
      }
    }

    func arguments(for command: String) -> [String] {
      switch self {
      case .bashLogin: return ["-lc", command]
      case .sh: return ["-c", command]
      }
    }
  }

  /// Grandchildren may still be writing when bash exits; give the pipe this long to
  /// deliver bash's own trailing output before the read stops.
  private static let drainSeconds: TimeInterval = 0.15

  /// Cancellation-aware run for the `bash` tool (and, with `stdin`/`shell`, for hooks).
  static func run(
    _ command: String,
    cwd: URL?,
    timeoutSeconds: Int,
    sandbox: ShellSandbox? = nil,
    environment: SubprocessEnvironment = .default,
    extraEnvironment: [String: String] = [:],
    stdin: Data? = nil,
    shell: Shell = .bashLogin,
    outputBounds: OutputBounds = .default)
    async -> Outcome
  {
    let launch: Launch
    do {
      launch = try Launch(
        command: command, cwd: cwd, sandbox: sandbox, environment: environment,
        extraEnvironment: extraEnvironment, stdin: stdin, shell: shell, outputBounds: outputBounds)
    } catch {
      return Outcome(
        exitStatus: 127, output: "cannot run \(shell.executable): \(error)", timedOut: false,
        cancelled: false, failedToStart: true)
    }
    let box = launch.box
    let watchdog = Task {
      try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
      box.timedOut = true
      box.kill()
    }
    await withTaskCancellationHandler {
      await launch.exit.wait()
    } onCancel: {
      box.cancelled = true
      box.kill()
    }
    watchdog.cancel()
    try? await Task.sleep(nanoseconds: UInt64(drainSeconds * 1_000_000_000))
    return launch.finish()
  }

  /// Blocking variant for synchronous callers (eval setup/check scripts, panel plumbing).
  /// `extraEnvironment` adds variables on top of the policy's resolution (an eval check's
  /// `ARNES_SESSION_ID`/`ARNES_RUN_ID`), the way the async `run` takes them.
  static func runBlocking(
    _ command: String,
    cwd: URL?,
    timeoutSeconds: Int,
    sandbox: ShellSandbox? = nil,
    environment: SubprocessEnvironment = .default,
    extraEnvironment: [String: String] = [:])
    -> Outcome
  {
    let launch: Launch
    do {
      launch = try Launch(
        command: command, cwd: cwd, sandbox: sandbox, environment: environment,
        extraEnvironment: extraEnvironment)
    } catch {
      return Outcome(
        exitStatus: 127, output: "cannot run bash: \(error)", timedOut: false, cancelled: false,
        failedToStart: true)
    }
    if !launch.exit.wait(seconds: TimeInterval(timeoutSeconds)) {
      launch.box.timedOut = true
      launch.box.kill()
      _ = launch.exit.wait(seconds: 5)
    }
    Thread.sleep(forTimeInterval: drainSeconds)
    return launch.finish()
  }

  // MARK: Plumbing

  /// The running process plus flags the watchdog and cancellation set. `Process` isn't
  /// Sendable; every access goes through the lock.
  final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private let process: any ShellProcess
    private var _timedOut = false
    private var _cancelled = false

    init(process: any ShellProcess) { self.process = process }

    var timedOut: Bool {
      get { lock.withLock { _timedOut } }
      set { lock.withLock { _timedOut = newValue } }
    }

    var cancelled: Bool {
      get { lock.withLock { _cancelled } }
      set { lock.withLock { _cancelled = newValue } }
    }

    /// The direct child's pid — `sandbox-exec` under a sandbox, which `exec`s the shell in
    /// place, so the same pid is the shell either way.
    var pid: Int32 {
      lock.withLock { process.processIdentifier }
    }

    var isRunning: Bool {
      lock.withLock { process.isRunning }
    }

    var terminationStatus: Int32 {
      lock.withLock { process.isRunning ? -1 : process.terminationStatus }
    }

    /// The exit status the way a shell reports it: the exit code, or 128 + the signal number
    /// for a process a signal ended (`143` for SIGTERM) — what `$?` would have said. -1 while
    /// the process is still running.
    var shellExitStatus: Int32 {
      lock.withLock {
        guard !process.isRunning else { return -1 }
        return process.terminationReason == .uncaughtSignal
          ? 128 + process.terminationStatus
          : process.terminationStatus
      }
    }

    /// SIGTERM to the whole process tree now, SIGKILL two seconds later to whatever is still
    /// around. The descendants are enumerated *before* the shell is signaled — once it dies
    /// they are reparented and unreachable by a parent walk — and signaled leaf-first, so a
    /// timed-out build doesn't leave its compilers running. Best-effort, like Claude Code's:
    /// a process that forks between the scan and the signal is missed (`ProcessTree`).
    func kill() {
      var tree: [ProcessTree.Entry] = []
      let signaled = lock.withLock {
        var signaled = false
        process.withRunningPID { pid in
          tree = ProcessTree.descendants(of: pid)
          ProcessTree.signal(tree, SIGTERM, verifyingIdentity: false)
          Foundation.kill(pid, SIGTERM)
          signaled = true
        }
        return signaled
      }
      guard signaled else { return }
      let snapshot = tree
      DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [self] in
        forceKill(snapshot: snapshot)
      }
    }

    /// SIGKILL to the process and its tree at once: the descendants enumerated now plus the
    /// ones `snapshot` saw earlier (only while each is still the process it was — pid and start
    /// time — so a recycled pid is never signaled). The registry's escalation for a job that
    /// ignored its SIGTERM, and `kill()`'s own two-second follow-up.
    func forceKill(snapshot: [ProcessTree.Entry] = []) {
      ProcessTree.signal(snapshot, SIGKILL, verifyingIdentity: true)
      lock.withLock {
        process.withRunningPID { pid in
          ProcessTree.signal(ProcessTree.descendants(of: pid), SIGKILL, verifyingIdentity: true)
          Foundation.kill(pid, SIGKILL)
        }
      }
    }
  }

  /// A best-effort walk of a process's descendants, for killing what a timed-out or cancelled
  /// command started, including descendants that changed process groups. Descendants are
  /// enumerated from the shell's pid — Darwin's
  /// `proc_listpids(PROC_PPID_ONLY)` (libproc), Linux's `/proc/*/stat` parent ids — and
  /// signaled leaf-first.
  /// Each entry carries the process's start time so a *later* signal (the SIGKILL escalation two
  /// seconds on) can tell the process it saw from an unrelated one that got its pid meanwhile.
  /// Documented limits: a child that forks between the scan and the signal survives, and a
  /// descendant already reparented (its parent died first) is out of reach of a parent walk.
  enum ProcessTree {
    struct Entry: Hashable, Sendable {
      let pid: pid_t
      /// The process's start time in an OS-specific unit, or 0 when it couldn't be read (such
      /// an entry is signaled immediately but never on a delayed pass).
      let startTime: UInt64
    }

    /// Every descendant of `root` (not `root` itself), deepest first — so a signal loop hits
    /// the leaves before the parents that might otherwise respawn or reap them.
    static func descendants(of root: pid_t) -> [Entry] {
      let table = processTable()
      var seen: Set<pid_t> = [root]
      var order: [Entry] = []
      var frontier = [root]
      while !frontier.isEmpty {
        var next: [pid_t] = []
        for parent in frontier {
          for child in children(of: parent, table: table) where !seen.contains(child) {
            seen.insert(child)
            order.append(Entry(pid: child, startTime: startTime(of: child, table: table)))
            next.append(child)
          }
        }
        frontier = next
      }
      return order.reversed()
    }

    /// Sends `signal` to every entry — all of them when `verifyingIdentity` is false (the
    /// entries were just enumerated), else only those still running as the same process
    /// (pid *and* start time; an entry whose start time was unreadable is skipped).
    static func signal(_ entries: [Entry], _ signal: Int32, verifyingIdentity: Bool) {
      var done: Set<pid_t> = []
      for entry in entries where !done.contains(entry.pid) {
        done.insert(entry.pid)
        if verifyingIdentity {
          guard entry.startTime != 0, startTime(of: entry.pid, table: nil) == entry.startTime else { continue }
        }
        Foundation.kill(entry.pid, signal)
      }
    }

    // MARK: Platform enumeration

    /// A parent → children map plus start times, built once per walk where the platform needs
    /// a table scan (Linux); nil on Darwin, whose libproc answers per pid.
    struct Table {
      var children: [pid_t: [pid_t]] = [:]
      var startTimes: [pid_t: UInt64] = [:]
    }

    static func processTable() -> Table? {
      #if canImport(Darwin)
      return nil
      #else
      var table = Table()
      guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { return table }
      for entry in entries {
        guard let pid = pid_t(entry), let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8) else {
          continue
        }
        // `pid (comm) state ppid …` — the command name may contain spaces and parentheses, so
        // the fields are read after its closing parenthesis: state, ppid, …, starttime (22nd).
        guard let close = stat.lastIndex(of: ")") else { continue }
        let fields = stat[stat.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count > 19, let ppid = pid_t(fields[1]) else { continue }
        table.children[ppid, default: []].append(pid)
        table.startTimes[pid] = UInt64(fields[19]) ?? 0
      }
      return table
      #endif
    }

    static func children(of pid: pid_t, table: Table?) -> [pid_t] {
      #if canImport(Darwin)
      // libproc's "every process whose parent is `pid`" listing; the return value is the bytes
      // filled, so a full buffer means there may be more.
      var capacity = 256
      while true {
        var buffer = [pid_t](repeating: 0, count: capacity)
        let bytes = proc_listpids(
          UInt32(PROC_PPID_ONLY), UInt32(pid), &buffer, Int32(capacity * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        let count = Int(bytes) / MemoryLayout<pid_t>.size
        if count < capacity || capacity >= 1 << 16 {
          return Array(buffer.prefix(count)).filter { $0 > 0 }
        }
        capacity *= 4
      }
      #else
      return table?.children[pid] ?? []
      #endif
    }

    static func startTime(of pid: pid_t, table: Table?) -> UInt64 {
      #if canImport(Darwin)
      var info = proc_bsdinfo()
      let size = Int32(MemoryLayout<proc_bsdinfo>.size)
      guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return 0 }
      return UInt64(info.pbi_start_tvsec) &* 1_000_000 &+ UInt64(info.pbi_start_tvusec)
      #else
      if let table { return table.startTimes[pid] ?? 0 }
      guard let stat = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
            let close = stat.lastIndex(of: ")")
      else { return 0 }
      let fields = stat[stat.index(after: close)...].split(separator: " ", omittingEmptySubsequences: true)
      guard fields.count > 19 else { return 0 }
      return UInt64(fields[19]) ?? 0
      #endif
    }
  }

  /// Fires once when the process exits; waitable from async and blocking contexts.
  final class ExitSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var continuation: CheckedContinuation<Void, Never>?
    private let semaphore = DispatchSemaphore(value: 0)

    func fire() {
      let pending: CheckedContinuation<Void, Never>? = lock.withLock {
        guard !fired else { return nil }
        fired = true
        defer { continuation = nil }
        return continuation
      }
      semaphore.signal()
      pending?.resume()
    }

    func wait() async {
      await withCheckedContinuation { next in
        let done: Bool = lock.withLock {
          if fired { return true }
          continuation = next
          return false
        }
        if done { next.resume() }
      }
    }

    func wait(seconds: TimeInterval) -> Bool {
      semaphore.wait(timeout: .now() + seconds) == .success
    }
  }

  /// Accumulates pipe output on the handle's queue, bounded: the first `headBytes` are kept as
  /// they arrive, everything after that feeds a ring of the last `tailBytes`, and the bytes
  /// that fall out of the ring are only counted. Append-only under one lock — the reader
  /// never blocks on anything but the lock, and memory stays at head + tail however long the
  /// command runs.
  final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let bounds: OutputBounds
    private var head = Data()
    private var tail = Data()
    /// Bytes that went past the head, whether the ring still holds them or not.
    private var overflow = 0

    init(bounds: OutputBounds = .default) {
      self.bounds = bounds
    }

    func append(_ chunk: Data) {
      lock.withLock {
        var chunk = chunk
        let room = bounds.headBytes - head.count
        if room > 0 {
          let take = min(room, chunk.count)
          head.append(chunk.prefix(take))
          chunk = chunk.dropFirst(take)
        }
        guard !chunk.isEmpty else { return }
        overflow += chunk.count
        if chunk.count >= bounds.tailBytes {
          tail = Data(chunk.suffix(bounds.tailBytes))
        } else {
          tail.append(chunk)
          let excess = tail.count - bounds.tailBytes
          if excess > 0 { tail.removeFirst(excess) }
        }
      }
    }

    /// Bytes dropped between head and tail.
    var truncatedBytes: Int { lock.withLock { max(0, overflow - tail.count) } }

    /// The collected output as text: the whole thing when nothing was dropped, else head, a
    /// marker naming the gap, and the tail — each piece trimmed to a UTF-8 boundary so the
    /// cut never shows as a stray replacement character.
    var text: String {
      lock.withLock {
        let dropped = max(0, overflow - tail.count)
        guard dropped > 0 else {
          var whole = head
          whole.append(tail)
          return String(decoding: whole, as: UTF8.self)
        }
        return String(decoding: Self.trimmedTail(head), as: UTF8.self)
          + "\n[… \(dropped) bytes omitted …]\n"
          + String(decoding: Self.trimmedHead(tail), as: UTF8.self)
      }
    }

    /// Drops an incomplete multi-byte sequence at the end of `data`.
    static func trimmedTail(_ data: Data) -> Data {
      let last = [UInt8](data.suffix(4))
      var continuation = 0
      var index = last.count - 1
      while index >= 0, last[index] & 0xC0 == 0x80 {
        continuation += 1
        index -= 1
      }
      guard index >= 0 else { return data }
      let lead = last[index]
      let expected = lead >= 0xF0 ? 4 : lead >= 0xE0 ? 3 : lead >= 0xC0 ? 2 : 1
      if expected == 1 {
        // ASCII followed by stray continuation bytes (an already-broken stream): drop them.
        return continuation == 0 ? data : Data(data.prefix(data.count - continuation))
      }
      if continuation + 1 == expected { return data }
      return Data(data.prefix(data.count - continuation - 1))
    }

    /// Drops continuation bytes at the start of `data` (the ring may begin mid-character).
    static func trimmedHead(_ data: Data) -> Data {
      let first = [UInt8](data.prefix(4))
      var start = 0
      while start < first.count, first[start] & 0xC0 == 0x80 {
        start += 1
      }
      return Data(data.dropFirst(start))
    }
  }

  struct Launch {
    let box: ProcessBox
    let exit: ExitSignal
    let collector: OutputCollector
    /// The output pipe, or nil when the command writes to a log file instead (a background job).
    let pipe: Pipe?
    private let reader: ProcessPipeReader?

    /// - Parameters:
    ///   - extraEnvironment: variables set on top of the resolved policy (a hook's
    ///     `ARNES_*` context). Applied after the policy, so they are never scrubbed.
    ///   - stdin: bytes piped to the command; nil closes stdin (`/dev/null`). Written from
    ///     a background queue after the spawn, so a large payload the command never reads
    ///     can't deadlock the caller — the writer simply fails with EPIPE once the command
    ///     exits (SIGPIPE is suppressed on the write end).
    ///   - shell: login bash for tools, plain `sh -c` for hooks.
    ///   - outputBounds: how much output is kept (head + tail ring); see `OutputBounds`.
    ///   - logHandle: when set, stdout and stderr go to this file instead of a pipe — a
    ///     background job, whose output nobody reads while it runs. The handle is the
    ///     caller's to close once the process has been spawned (the child holds its own copy).
    init(
      command: String,
      cwd: URL?,
      sandbox: ShellSandbox? = nil,
      environment policy: SubprocessEnvironment = .default,
      extraEnvironment: [String: String] = [:],
      stdin: Data? = nil,
      shell: Shell = .bashLogin,
      outputBounds: OutputBounds = .default,
      logHandle: FileHandle? = nil)
      throws
    {
      let executable: String
      let arguments: [String]
      let shellArguments = shell.arguments(for: command)
      if let sandbox {
        // Fail closed: a requested sandbox that the platform can't enforce must not run
        // unconfined — that would silently give the command the very reach it was meant to lose.
        guard let wrapped = sandbox.wrappedInvocation(bash: shell.executable, bashArguments: shellArguments) else {
          throw SandboxError.unsupported
        }
        executable = wrapped.executable
        arguments = wrapped.arguments
      } else {
        executable = shell.executable
        arguments = shellArguments
      }
      let stdinPipe: Pipe? = stdin.map { _ in Pipe() }
      // The provider token (and anything the policy drops) is withheld here so a command
      // can't `echo $OPENROUTER_API_KEY` it back out; the git/pager pins are re-added.
      var environment = policy.resolve()
      environment["GIT_TERMINAL_PROMPT"] = "0" // never hang on a credential prompt
      environment["GIT_PAGER"] = "cat"
      environment["PAGER"] = "cat"
      for (key, value) in extraEnvironment { environment[key] = value }

      let collector = OutputCollector(bounds: outputBounds)
      let pipe: Pipe?
      let reader: ProcessPipeReader?
      let output: FileHandle
      if let logHandle {
        output = logHandle
        pipe = nil
        reader = nil
      } else {
        let outputPipe = Pipe()
        output = outputPipe.fileHandleForWriting
        reader = try ProcessPipeReader(handle: outputPipe.fileHandleForReading,
          onData: { collector.append($0) })
        pipe = outputPipe
      }
      let exit = ExitSignal()
      let process: any ShellProcess
      do {
      #if os(Linux)
        let nullInput = open("/dev/null", O_RDONLY | O_CLOEXEC)
        guard nullInput >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { _ = close(nullInput) }
        process = try LinuxProcess(executable: executable, arguments: arguments, cwd: cwd,
          environment: environment, input: stdinPipe?.fileHandleForReading.fileDescriptor ?? nullInput,
          output: output.fileDescriptor, error: output.fileDescriptor, onExit: { exit.fire() })
        try? stdinPipe?.fileHandleForReading.close()
        try? pipe?.fileHandleForWriting.close()
      #else
        let child = Process()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = arguments
        child.currentDirectoryURL = cwd
        child.environment = environment
        child.standardInput = stdinPipe ?? FileHandle.nullDevice
        child.standardOutput = pipe ?? output
        child.standardError = pipe ?? output
        child.terminationHandler = { _ in exit.fire() }
        try child.run()
        process = child
      #endif
      } catch {
        reader?.stop()
        throw error
      }
      if let stdinPipe, let stdin {
        Self.feed(stdin, into: stdinPipe)
      }
      box = ProcessBox(process: process)
      self.exit = exit
      self.collector = collector
      self.pipe = pipe
      self.reader = reader
    }

    /// Writes `data` to the pipe off the caller's thread and closes the write end. A
    /// reader that exits early turns the write into EPIPE, not a signal.
    private static func feed(_ data: Data, into pipe: Pipe) {
      let writer = pipe.fileHandleForWriting
      #if canImport(Darwin)
      _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
      #else
      _ = signal(SIGPIPE, SIG_IGN)
      #endif
      DispatchQueue.global().async {
        try? writer.write(contentsOf: data)
        try? writer.close()
      }
    }

    /// Stops reading (a grandchild holding the pipe open is its own business) and
    /// renders the outcome.
    func finish() -> Outcome {
      reader?.finish()
      return Outcome(
        exitStatus: box.terminationStatus,
        output: collector.text,
        timedOut: box.timedOut,
        cancelled: box.cancelled,
        truncatedBytes: collector.truncatedBytes)
    }
  }
}

// MARK: - UserShell

/// A shell command the *user* typed themselves (the REPL's `!` escape): the same runner the
/// `bash` tool uses — login bash, stdin closed, hard timeout with a process-tree kill,
/// head+tail bounded output, the provider token withheld — but outside every tool gate and
/// outside the OS sandbox, because the user is the principal and this is their own terminal
/// (the same command in another tab would run unconfined). Cancellation kills the tree, so a
/// caller can wire Esc/Ctrl-C to it. What (if anything) the model is told about the run is
/// the caller's decision.
public enum UserShell {
  public struct Outcome: Sendable {
    public let exitStatus: Int32
    /// stdout + stderr interleaved; when the command produced more than the bounds keep,
    /// the head, an `[… N bytes omitted …]` line, and the tail.
    public let output: String
    public let timedOut: Bool
    public let cancelled: Bool
    /// The shell itself could not be spawned (as opposed to the command exiting non-zero).
    public let failedToStart: Bool
  }

  public static func run(
    _ command: String,
    cwd: URL?,
    timeoutSeconds: Int,
    environment: SubprocessEnvironment = .default,
    outputChars: Int = BashTool.defaultOutputChars)
    async -> Outcome
  {
    let outcome = await ShellRunner.run(
      command, cwd: cwd, timeoutSeconds: max(1, timeoutSeconds),
      environment: environment,
      outputBounds: ShellRunner.OutputBounds(capChars: outputChars))
    return Outcome(
      exitStatus: outcome.exitStatus, output: outcome.output,
      timedOut: outcome.timedOut, cancelled: outcome.cancelled,
      failedToStart: outcome.failedToStart)
  }
}
