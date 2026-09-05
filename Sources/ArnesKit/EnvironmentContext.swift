import Foundation
import OpenRouterSwift
#if canImport(Glibc)
import Glibc
#endif

// MARK: - EnvironmentContext

/// The `# Environment` section of the system prompt: what Claude Code and Codex both hand a
/// model before its first step, and what an Arnes model used to discover one tool call at a
/// time — the working directory, the platform, today's date, the git state of the tree, and
/// the run's own posture (model, permission mode, sandbox, reasoning effort). The cheapest
/// known lift for a non-frontier model's first steps: no `pwd`, `uname`, `date` or
/// `git status` round-trips before the real work starts.
///
/// `render` is a pure function with a **fixed line order**, byte-identical for identical
/// inputs. The block rides in the system prompt, which is the prompt-cache prefix, so nothing
/// finer than the date goes in and nothing is ordered by a dictionary. The inputs are captured
/// **once per session** (`Facts` for the process-wide ones, `GitSnapshot` for the tree) and
/// never refreshed per turn.
///
/// Harness plumbing, not prompt tuning: there is no model-family branching here (invariant 1);
/// family behavior stays in packs. Supplied to a session through
/// `Session.Configuration.extraSystemSections`, which `Session.systemText` renders after the
/// project instructions and before the tool-contributed sections. Opt out with
/// `policies.environmentContext: false` in `~/.arnes/config.json` (`PoliciesConfig`).
public enum EnvironmentContext {
  /// What holds for a whole session and is captured once at its start, so every block the
  /// session renders — the lead's and each subagent's — agrees on it: the platform, the date,
  /// and the OS sandbox the run's tools are under (nil = unconfined). Built with no arguments
  /// it captures the current process's platform and today's date.
  public struct Facts: Sendable, Equatable {
    public var os: String
    public var date: String
    public var sandbox: ShellSandbox?

    public init(
      os: String = EnvironmentContext.platform(),
      date: String = EnvironmentContext.today(),
      sandbox: ShellSandbox? = nil)
    {
      self.os = os
      self.date = date
      self.sandbox = sandbox
    }
  }

  /// Whether the block is on for this configuration: on unless `policies.environmentContext`
  /// says `false`. Absent config, absent block, absent key all mean on.
  public static func isEnabled(in config: ArnesConfig?) -> Bool {
    config?.policies?.environmentContext ?? true
  }

  // MARK: Rendering

  /// The most lines `render` can produce: the nine fixed lines, the effort line, the branch
  /// line, the status header + `GitSnapshot.statusLineCap` entries + the `(N more)` tail, and
  /// the commits header + `GitSnapshot.commitCap` subjects. The usual cases are far smaller —
  /// 9 lines outside a repository, 13 in a clean one — and only a dirty repository at both
  /// caps pays this many (~250 tokens).
  public static let maxLines = 9 + 1 + 1 + (1 + GitSnapshot.statusLineCap + 1) + (1 + GitSnapshot.commitCap)

  /// The block, in a fixed order. Every line is optional only by *absence of the fact*
  /// (no git → no git lines, no effort → no effort line), never by choice, so identical
  /// inputs always render identical bytes.
  ///
  /// - Parameters:
  ///   - readOnly: the run's delegate refuses every mutation regardless of `permissionMode`
  ///     (a read-only subagent). Rendered as `read-only` so the model doesn't plan writes the
  ///     gate will refuse.
  ///   - sandbox: the OS confinement in force, nil when unconfined.
  public static func render(
    cwd: URL,
    os: String,
    date: String,
    git: GitSnapshot?,
    model: String,
    permissionMode: PermissionMode,
    readOnly: Bool = false,
    sandbox: ShellSandbox?,
    effort: Reasoning.Effort?)
    -> String
  {
    var lines: [String] = [
      heading,
      "",
      "Facts about this session, captured once when it started. Rely on them instead of "
        + "probing (no pwd, uname, date or git status needed to learn them); re-check git only "
        + "after you change files or commit.",
      "- Working directory: \(cwd.path)",
      "- Platform: \(os)",
      "- Date: \(date)",
      "- Model: \(model)",
      "- Permission mode: \(readOnly ? "read-only" : permissionMode.label)",
      "- Sandbox: \(sandboxLine(sandbox))",
    ]
    if let effort {
      lines.append("- Reasoning effort: \(effort.rawValue)")
    }
    if let git {
      lines.append("- Git branch: \(clean(git.branch))")
      if git.statusCount == 0 {
        lines.append("- Git status: clean")
      } else {
        let noun = git.statusCount == 1 ? "entry" : "entries"
        lines.append("- Git status (\(git.statusCount) \(noun)):")
        for line in git.status {
          lines.append("  " + clean(line))
        }
        let more = git.statusCount - git.status.count
        if more > 0 {
          lines.append("  (\(more) more)")
        }
      }
      if !git.recentSubjects.isEmpty {
        lines.append("- Recent commits (newest first):")
        for subject in git.recentSubjects {
          lines.append("  " + clean(subject))
        }
      }
    }
    return lines.joined(separator: "\n")
  }

  /// The block for one session root: captures the tree's `GitSnapshot` (bounded — 2 s, capped
  /// lines) and renders it with the session-wide `facts`. The probe runs inside
  /// `facts.sandbox` — the same confinement the run's own `bash` gets, so "every shell an
  /// unattended run spawns is confined" stays true of the one spawn that happens before the
  /// model has said a word.
  public static func block(
    cwd: URL,
    facts: Facts,
    model: String,
    permissionMode: PermissionMode,
    readOnly: Bool = false,
    effort: Reasoning.Effort?)
    async -> String
  {
    let git = await GitSnapshot.capture(root: cwd, sandbox: facts.sandbox)
    return render(
      cwd: cwd, os: facts.os, date: facts.date, git: git, model: model,
      permissionMode: permissionMode, readOnly: readOnly, sandbox: facts.sandbox, effort: effort)
  }

  /// The block for a session built from `configuration`: its working directory (the process
  /// CWD when unbound), model, permission mode and effort. One call at every site that builds
  /// a `Session.Configuration` — REPL, `do`, a nested subagent, an eval trial, a panel
  /// candidate — so they can't drift apart.
  public static func block(
    for configuration: Session.Configuration,
    facts: Facts,
    readOnly: Bool = false)
    async -> String
  {
    let cwd = configuration.workingDirectory
      ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    return await block(
      cwd: cwd, facts: facts, model: configuration.model,
      permissionMode: configuration.permissionMode, readOnly: readOnly,
      effort: configuration.reasoningEffort)
  }

  /// The block's heading line — what `render` opens with, and what `replacingBlock` keys on.
  public static let heading = "# Environment"

  /// Whether `section` is this block: it opens with `heading` as its own first line (a
  /// `# Memory` block, a `# Role` suffix or an embedder's section is not).
  public static func isBlock(_ section: String) -> Bool {
    section.prefix { $0 != "\n" }.trimmingCharacters(in: .whitespaces) == heading
  }

  /// `sections` with the environment block swapped for `block` — in place when one is there,
  /// inserted first when none is — and **every other section kept**: a refresh of the block
  /// after `/model`, `/permissions` or `/effort` must not drop the `# Memory` section (or an
  /// embedder's) that shares `Session.Configuration.extraSystemSections` with it. What the REPL
  /// hands `Session.setExtraSystemSections`.
  public static func replacingBlock(in sections: [String], with block: String) -> [String] {
    var replaced = sections
    if let index = replaced.firstIndex(where: isBlock) {
      replaced[index] = block
    } else {
      replaced.insert(block, at: 0)
    }
    return replaced
  }

  /// The block's inputs for one session root, captured once — the session-wide `Facts` and the
  /// tree's `GitSnapshot` — so the block can be **re-rendered** when the run's posture changes
  /// (`/model`, `/permissions`, `/effort`, a `/resume`) without probing git again: the model,
  /// mode and effort lines follow the live session, the git lines stay as captured. That is the
  /// block's own contract ("captured once when it started; re-check git only after you change
  /// files"), and it keeps a dial change from costing a shell spawn.
  public struct Snapshot: Sendable, Equatable {
    public var cwd: URL
    public var facts: Facts
    public var git: GitSnapshot?

    public init(cwd: URL, facts: Facts, git: GitSnapshot?) {
      self.cwd = cwd
      self.facts = facts
      self.git = git
    }

    /// Captures the tree once (the same bounded probe `block` runs, inside `facts.sandbox`).
    public static func capture(cwd: URL, facts: Facts) async -> Snapshot {
      Snapshot(cwd: cwd, facts: facts, git: await GitSnapshot.capture(root: cwd, sandbox: facts.sandbox))
    }

    /// The block for the posture given — byte-identical to `block(cwd:facts:…)` over the same
    /// git state.
    public func render(
      model: String,
      permissionMode: PermissionMode,
      readOnly: Bool = false,
      effort: Reasoning.Effort?)
      -> String
    {
      EnvironmentContext.render(
        cwd: cwd, os: facts.os, date: facts.date, git: git, model: model,
        permissionMode: permissionMode, readOnly: readOnly, sandbox: facts.sandbox, effort: effort)
    }
  }

  // MARK: Facts

  /// `uname`-style platform line: the marketing version where the OS has one, then the kernel
  /// name, release and machine — `macOS 15.5 (Darwin 24.5.0, arm64)`, `Linux 6.8.0 (x86_64)`.
  public static func platform() -> String {
    var system = utsname()
    uname(&system)
    let sysname = string(system.sysname)
    let release = string(system.release)
    let machine = string(system.machine)
    #if os(macOS)
    let version = ProcessInfo.processInfo.operatingSystemVersion
    var marketing = "macOS \(version.majorVersion).\(version.minorVersion)"
    if version.patchVersion > 0 { marketing += ".\(version.patchVersion)" }
    return "\(marketing) (\(sysname) \(release), \(machine))"
    #else
    return "\(sysname) \(release) (\(machine))"
    #endif
  }

  /// `YYYY-MM-DD` in the given zone — the coarsest timestamp that is still useful, and the
  /// finest the block may carry (anything finer would break the cache prefix every minute).
  public static func today(_ date: Date = Date(), timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  // MARK: Helpers

  /// `off`, or `on (…)` naming what the confinement actually is: the working tree alone, or
  /// the working tree plus however many directories `--add-dir` / `sandbox.writable` opened
  /// (`ShellSandbox.writableRoots` lists the working tree first).
  private static func sandboxLine(_ sandbox: ShellSandbox?) -> String {
    guard let sandbox else { return "off" }
    let extra = max(sandbox.writableRoots.count - 1, 0)
    var scope = "writes confined to the working tree"
    if extra > 0 {
      scope += " + \(extra) other director\(extra == 1 ? "y" : "ies")"
    }
    return sandbox.allowNetwork ? "on (\(scope))" : "on (\(scope); network off)"
  }

  /// Git output is repository data, not the harness's: control characters can't reach the
  /// prompt and a line can't run past `GitSnapshot.lineWidthCap`.
  static func clean(_ line: String) -> String {
    var text = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f })
    if text.count > GitSnapshot.lineWidthCap {
      text = String(text.prefix(GitSnapshot.lineWidthCap - 1)) + "…"
    }
    return text
  }

  /// A fixed-size `utsname` field → String, stopping at the first NUL.
  private static func string<T>(_ field: T) -> String {
    withUnsafeBytes(of: field) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }
}

// MARK: - GitSnapshot

/// The git state of a working directory as the environment block reports it: the branch, up
/// to `statusLineCap` lines of `git status --short` with the true total, and the last
/// `commitCap` commit subjects. Bounded in every direction — one shell, a 2 s budget for the
/// whole probe, capped line counts and widths — because it runs at session start, before the
/// model has said a word, and a slow or enormous repository must cost nothing but the block's
/// git lines. Never throws: not a repository, no `git` on the path, a timeout, all yield nil.
public struct GitSnapshot: Sendable, Equatable {
  /// How many `git status --short` lines the block shows before `(N more)`.
  public static let statusLineCap = 20
  /// How many recent commit subjects the block shows.
  public static let commitCap = 5
  /// Widest a reported line may be; longer paths and subjects are clipped with `…`.
  public static let lineWidthCap = 200
  /// The whole probe's budget. A repository that can't answer in this long doesn't get to
  /// slow every session start; the block simply has no git lines.
  public static let timeoutSeconds = 2

  /// The checked-out branch, or `HEAD (detached at <short sha>)`.
  public var branch: String
  /// The first `statusLineCap` lines of `git status --short`, verbatim.
  public var status: [String]
  /// How many lines `git status --short` printed in all; more than `status.count` means the
  /// list was cut, and the block says by how much.
  public var statusCount: Int
  /// Subjects of the most recent commits, newest first (empty in an unborn repository).
  public var recentSubjects: [String]

  public init(
    branch: String,
    status: [String] = [],
    statusCount: Int? = nil,
    recentSubjects: [String] = [])
  {
    self.branch = branch
    self.status = Array(status.prefix(Self.statusLineCap))
    self.statusCount = max(statusCount ?? status.count, self.status.count)
    self.recentSubjects = Array(recentSubjects.prefix(Self.commitCap))
  }

  /// Probes `root` with one `sh` invocation through `ShellRunner` (stdin closed, hard
  /// timeout, provider token withheld) and parses the tagged output. nil when `root` isn't
  /// inside a work tree, `git` is missing, the probe times out, or the output is unusable.
  ///
  /// This is a shell spawned in a directory the harness hasn't been told to trust, before the
  /// first request and without a prompt, so it is treated like any other shell the run
  /// starts, twice over:
  /// - `sandbox`: the run's OS confinement wraps the probe exactly as it wraps `bash`
  ///   (writes only under the roots, credentials unreadable, network per policy). A sandbox
  ///   the platform can't enforce fails the probe closed — nil, no git lines — rather than
  ///   running it unconfined. The probe needs no write (`GIT_OPTIONAL_LOCKS=0`), so it works
  ///   confined.
  /// - `probeEnvironment`: the two git configuration keys that make `status`/`log` *execute a
  ///   command* — `core.fsmonitor` (a hook path, run by every `git status`) and
  ///   `log.showSignature` (runs `gpg.program`) — are pinned off through git's environment
  ///   config, which outranks the repository's own `.git/config`. So a tarball delivered with
  ///   a tampered `.git/config` can't run a script at session start even when no sandbox is
  ///   on (interactive, `--no-sandbox`). The user's global config is still honored.
  /// Residual: a repository can still ship `.gitattributes` `filter=<x>` plus
  /// `filter.<x>.clean` in `.git/config`, which `git status` runs when a tracked file's stat
  /// info is stale but its size unchanged — the OS sandbox is the boundary for that one.
  public static func capture(
    root: URL,
    sandbox: ShellSandbox? = nil,
    timeoutSeconds: Int = timeoutSeconds)
    async -> GitSnapshot?
  {
    await capture(root: root, sandbox: sandbox, timeoutSeconds: timeoutSeconds, extraEnvironment: [:])
  }

  /// `capture` with extra variables layered over `probeEnvironment` — for tests that need to
  /// pin the host's git config out of the way, or shadow `git` on `PATH`.
  static func capture(
    root: URL,
    sandbox: ShellSandbox?,
    timeoutSeconds: Int,
    extraEnvironment: [String: String])
    async -> GitSnapshot?
  {
    let outcome = await ShellRunner.run(
      probeCommand, cwd: root, timeoutSeconds: timeoutSeconds, sandbox: sandbox,
      extraEnvironment: probeEnvironment.merging(extraEnvironment) { _, override in override },
      shell: .sh)
    guard outcome.exitStatus == 0, !outcome.timedOut, !outcome.cancelled, !outcome.failedToStart
    else { return nil }
    return parse(outcome.output)
  }

  /// The probe's environment: untranslated output, never a lock held on the index just to
  /// look at it, and git's environment-config (`GIT_CONFIG_COUNT`, git ≥ 2.31 — it overrides
  /// every config file, including the repository's) pinning off the keys under which
  /// `git status` / `git log` would run a command the repository chose. Inherited by any git
  /// the probe's git spawns itself (a submodule's `status`), which a `-c` flag wouldn't be.
  static let probeEnvironment: [String: String] = [
    "LC_ALL": "C",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_CONFIG_COUNT": "2",
    "GIT_CONFIG_KEY_0": "core.fsmonitor",
    "GIT_CONFIG_VALUE_0": "false",
    "GIT_CONFIG_KEY_1": "log.showSignature",
    "GIT_CONFIG_VALUE_1": "false",
  ]

  /// One shell script, each line of output tagged so parsing can't be fooled by a commit
  /// subject or a path that looks like another section. The `unset` first: a process started
  /// from a git hook inherits `GIT_DIR`/`GIT_WORK_TREE`/`GIT_INDEX_FILE`, which would point
  /// every command at *that* repository instead of `cwd` (the environment can be added to,
  /// not subtracted from, so it happens in the script). `awk` caps the status list while
  /// still counting every line; `--no-branch` keeps a `status.branch=true` config from adding
  /// a `##` header to the count (paths stay cwd-relative, which is what the model needs);
  /// `exit 3` marks "not a repository" (also what a missing `git` produces, via `||`), and the
  /// trailing `exit 0` keeps an unborn repository's failing `git log` from failing the probe.
  static let probeCommand = """
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
    [ "$(git rev-parse --is-inside-work-tree 2>/dev/null)" = true ] || exit 3
    b=$(git symbolic-ref --short -q HEAD 2>/dev/null) \
      || b="HEAD (detached at $(git rev-parse --short HEAD 2>/dev/null || echo '?'))"
    printf 'branch %s\\n' "$b"
    git status --short --no-branch 2>/dev/null \
      | awk 'NR<=\(statusLineCap) {print "status " $0} END {print "count " NR}'
    git log -\(commitCap) --format='commit %s' 2>/dev/null
    exit 0
    """

  /// Parses the probe's tagged lines. nil without a `branch` line (nothing usable came back).
  static func parse(_ output: String) -> GitSnapshot? {
    var branch: String?
    var status: [String] = []
    var count: Int?
    var subjects: [String] = []
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(rawLine)
      if line.hasPrefix("branch ") {
        branch = String(line.dropFirst("branch ".count))
      } else if line.hasPrefix("status ") {
        status.append(String(line.dropFirst("status ".count)))
      } else if line.hasPrefix("count ") {
        count = Int(line.dropFirst("count ".count).trimmingCharacters(in: .whitespaces))
      } else if line.hasPrefix("commit ") {
        subjects.append(String(line.dropFirst("commit ".count)))
      }
    }
    guard let branch, !branch.isEmpty else { return nil }
    return GitSnapshot(branch: branch, status: status, statusCount: count, recentSubjects: subjects)
  }
}
