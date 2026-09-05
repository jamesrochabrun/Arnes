import Foundation

// MARK: - ShellSandbox

/// OS-level confinement for the one place the agent runs arbitrary code: the `bash` tool.
///
/// The deterministic classifiers (`ShellCommand`) and the `CommandJudge` are heuristics on
/// the *command string* — they reduce the odds of a bad command, but a novel encoding slips
/// past them. This is the layer that makes such a miss survivable: the spawned shell is
/// wrapped so **file writes are confined to the working tree (plus temp), the tree's own
/// executable corners stay read-only, credential locations can't be read at all, and the
/// network is off unless allowed**. A destructive command that gets through the string
/// layers still can't reach `~/.ssh`, `/etc`, or the disk outside the project.
///
/// Four lists make up the boundary:
/// - `writableRoots` — where writes are allowed (the working tree, `--add-dir` directories,
///   any configured extras), on top of the always-writable temp directories.
/// - `protectedSubpaths` — corners *inside* those roots that stay unwritable, because a
///   write there changes what runs rather than what is built (`.git/hooks`, `.github/workflows`,
///   `.arnes`, `.claude`) plus the harness's own `~/.arnes`.
/// - `denyRead` — locations the shell may not read at all (credential paths under home, plus
///   whatever the config's deny-read list names as a literal path).
/// - `allowNetwork` — sockets, all or nothing.
///
/// The same lists drive `permitsWrite`, the **in-process mirror** the file tools consult:
/// `write_file` and `edit_file` don't go through a shell, so the kernel never sees their
/// writes and the mirror *is* the enforcement for them. One boundary, two enforcers.
///
/// macOS uses `sandbox-exec` (an SBPL profile). Linux support (bwrap/landlock) is not wired
/// yet, so on Linux a requested sandbox is *unavailable* and the caller fails closed rather
/// than running unconfined. Unattended runs (`do --yes`, evals, panels) are confined by
/// default where the platform can enforce it; interactive sessions stay opt-in
/// (`ProviderConfig.sandbox`), because confinement breaks commands that legitimately write
/// outside the tree or need the network (`npm install`'s cache, `git fetch`).
public struct ShellSandbox: Sendable, Equatable {
  /// Absolute paths (symlinks resolved at profile time) under which writes are permitted, on
  /// top of the always-writable temp directories. Normally the working root plus `--add-dir`
  /// directories and anything the user added in config.
  public var writableRoots: [URL]
  /// When false, the shell can't open sockets — the strongest containment, but breaks
  /// anything that fetches. Default true.
  public var allowNetwork: Bool
  /// Locations inside the writable roots that stay unwritable anyway: a write there changes
  /// what *executes* (git hooks and config, CI workflows) or what the harness trusts
  /// (`.arnes`, `.claude`, `~/.arnes`). Denied after the roots are allowed, so the deny wins.
  public var protectedSubpaths: [URL]
  /// Locations the sandboxed shell may not read. Defaults to the credential paths under the
  /// home directory (`PathScope.sensitiveHomePaths`) — `cat ~/.ssh/id_rsa` fails with EPERM
  /// rather than relying on the model not to ask.
  public var denyRead: [URL]
  /// Corners *inside* a protected subpath that are writable after all — re-allowed after the
  /// protected deny, so the deny does not cover them: the project's memory directory under
  /// `~/.arnes` (C3), where a write the user approved has to land. Empty by default; nothing
  /// here is ever the whole of a protected subpath.
  public var writableCarveOuts: [URL]

  /// - Parameters:
  ///   - protectedSubpaths: nil derives the defaults for `writableRoots` (see
  ///     `defaultProtectedSubpaths`). Pass `[]` to opt out entirely.
  ///   - denyRead: nil derives the credential paths under `home`. Pass `[]` to opt out.
  ///   - writableCarveOuts: directories re-allowed for writing after the protected deny.
  ///   - home: injectable so tests don't depend on the real home directory.
  public init(
    writableRoots: [URL],
    allowNetwork: Bool = true,
    protectedSubpaths: [URL]? = nil,
    denyRead: [URL]? = nil,
    writableCarveOuts: [URL] = [],
    home: String = NSHomeDirectory())
  {
    self.writableRoots = writableRoots
    self.allowNetwork = allowNetwork
    self.protectedSubpaths = protectedSubpaths
      ?? Self.defaultProtectedSubpaths(under: writableRoots, home: home)
    self.denyRead = denyRead ?? Self.defaultDenyRead(home: home)
    self.writableCarveOuts = writableCarveOuts
  }

  /// Whether this platform can actually enforce a sandbox. When false and a sandbox is
  /// requested, `ShellRunner` refuses to run rather than run unconfined.
  public static var isSupported: Bool {
    #if os(macOS)
    return FileManager.default.isExecutableFile(atPath: sandboxExecPath)
    #else
    return false
    #endif
  }

  static let sandboxExecPath = "/usr/bin/sandbox-exec"

  // MARK: Default lists

  /// Each writable root's executable corners (`PathScope.protectedRelativePaths`: `.git/hooks`,
  /// `.git/config`, `.github/workflows`, `.arnes`, `.claude`, `.mcp.json`) plus the harness's
  /// own `~/.arnes`. The same list the write-side path classifier calls `.sensitive` — here it
  /// is the kernel saying no, not a prompt.
  ///
  /// `gitOnlyRelativePaths` are protected **only in a directory that is already a repository**:
  /// `git init` creates `.git/hooks` (with its sample files) and `.git/config`, so a blanket
  /// deny would stop an agent from creating a repo in an empty directory — where there is no
  /// existing configuration to subvert. Once `.git` is there the deny applies, and it costs
  /// nothing: `git add`/`commit`/`branch`/`merge` never write either path.
  public static func defaultProtectedSubpaths(
    under roots: [URL],
    home: String = NSHomeDirectory())
    -> [URL]
  {
    var paths: [URL] = []
    for root in roots {
      let isRepository = FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".git").path)
      for relative in PathScope.protectedRelativePaths
        where isRepository || !gitOnlyRelativePaths.contains(relative)
      {
        paths.append(root.appendingPathComponent(relative))
      }
    }
    paths.append(URL(fileURLWithPath: home).appendingPathComponent(".arnes"))
    return paths
  }

  /// Protected corners that only exist — and only matter — once the root is a git repository.
  static let gitOnlyRelativePaths: Set<String> = [".git/hooks", ".git/config"]

  /// Credential locations under the home directory. Deliberately *not* all of `~/.arnes`:
  /// the agent may legitimately run `arnes` itself, read a skill, or look at its own
  /// scoreboards — only the credential/config files in `PathScope.sensitiveHomePaths` are
  /// unreadable.
  public static func defaultDenyRead(home: String = NSHomeDirectory()) -> [URL] {
    let base = URL(fileURLWithPath: home)
    return PathScope.sensitiveHomePaths.map { base.appendingPathComponent($0) }
  }

  /// Temp locations every shell needs to write to for ordinary work. Both `/var` and
  /// `/private/var` spellings are emitted by `spellings(of:)` at profile time, since the
  /// kernel canonicalizes to the `/private` form while paths often arrive as `/var`.
  static var temporaryWritablePaths: [String] {
    var paths = ["/tmp", "/var/tmp", "/var/folders"]
    let tmp = NSTemporaryDirectory()
    if !tmp.isEmpty { paths.append(tmp) }
    return paths
  }

  /// The `/private`-prefixed and unprefixed spellings of a macOS path. `sandbox-exec` matches
  /// the physical path (`/private/var/…`), but paths reach us as `/var/…` or `/tmp/…`; without
  /// both, a write to the working temp dir is wrongly denied.
  static func spellings(of path: String) -> [String] {
    if path.hasPrefix("/private/") {
      return [path, String(path.dropFirst("/private".count))]
    }
    if path == "/tmp" || path.hasPrefix("/tmp/") || path == "/var" || path.hasPrefix("/var/") {
      return [path, "/private" + path]
    }
    return [path]
  }

  /// Every spelling `sandbox-exec` might see for one location: the path as given *and* its
  /// physical form with symlinks resolved (a project reached through a symlinked directory is
  /// matched by the path the kernel reports, not the one the user typed), each with and
  /// without the `/private` prefix.
  static func sandboxSpellings(of url: URL) -> [String] {
    let given = url.standardizedFileURL.path
    return spellings(of: given) + spellings(of: PathScope.physicalPath(given))
  }

  /// /dev nodes a shell opens by path (redirects to /dev/null, tty checks).
  static let writableDeviceNodes = ["/dev/null", "/dev/zero", "/dev/dtracehelper", "/dev/tty",
                                    "/dev/stdout", "/dev/stderr", "/dev/random", "/dev/urandom"]

  /// The wrapped invocation for what would otherwise be `bash bashArguments...`. Returns nil
  /// when the platform can't sandbox (caller fails closed). On macOS:
  /// `sandbox-exec -p <profile> /bin/bash -lc <command>`.
  func wrappedInvocation(bash: String, bashArguments: [String]) -> (executable: String, arguments: [String])? {
    #if os(macOS)
    guard Self.isSupported else { return nil }
    return (Self.sandboxExecPath, ["-p", profile()] + [bash] + bashArguments)
    #else
    return nil
    #endif
  }

  // MARK: The profile

  /// The SBPL profile. Last matching rule wins, so the order *is* the policy:
  ///
  /// 1. `(allow default)` — this is a write/read boundary, not a capability jail.
  /// 2. `(deny file-write*)` — nothing is writable…
  /// 3. `(allow file-write* …)` — …except the roots, temp and a few `/dev` nodes.
  /// 4. `(deny file-write* …)` — except *those* roots' protected corners.
  /// 4b. `(allow file-write* …)` — except, inside those, the carve-outs (`writableCarveOuts`:
  ///    the project's memory directory under `~/.arnes`), which must come *after* the deny to
  ///    win over it. Omitted when there are none, so the profile is otherwise unchanged.
  /// 5. `(deny file-write-unlink (literal <root>))` — and the boundary itself can't be
  ///    swapped: a root directory that could be unlinked and re-created as a symlink would
  ///    let the next write land anywhere.
  /// 6. `(deny file-read* …)` — credential locations aren't readable at all.
  /// 7. `(deny network*)` when the policy says so.
  public func profile() -> String {
    var lines = [
      "(version 1)",
      "(allow default)",
      "(deny file-write*)",
    ]
    let rootPaths = dedupe(writableRoots.flatMap(Self.sandboxSpellings))
    var allowWrite = ["(allow file-write*"]
    for path in dedupe(rootPaths + Self.temporaryWritablePaths.flatMap(Self.spellings)) {
      allowWrite.append("  (subpath \(quote(path)))")
    }
    for node in Self.writableDeviceNodes {
      allowWrite.append("  (literal \(quote(node)))")
    }
    allowWrite.append("  (regex #\"^/dev/fd/\"))")
    lines.append(allowWrite.joined(separator: "\n"))

    let protectedPaths = dedupe(protectedSubpaths.flatMap(Self.sandboxSpellings))
    if !protectedPaths.isEmpty {
      lines.append((["(deny file-write*"]
        + protectedPaths.map { "  (subpath \(quote($0)))" }).joined(separator: "\n") + ")")
    }
    // After the protected deny, so it wins over it (last match wins).
    let carveOutPaths = dedupe(writableCarveOuts.flatMap(Self.sandboxSpellings))
    if !carveOutPaths.isEmpty {
      lines.append((["(allow file-write*"]
        + carveOutPaths.map { "  (subpath \(quote($0)))" }).joined(separator: "\n") + ")")
    }
    if !rootPaths.isEmpty {
      lines.append((["(deny file-write-unlink"]
        + rootPaths.map { "  (literal \(quote($0)))" }).joined(separator: "\n") + ")")
    }
    let readPaths = dedupe(denyRead.flatMap(Self.sandboxSpellings))
    if !readPaths.isEmpty {
      lines.append((["(deny file-read*"]
        + readPaths.map { "  (subpath \(quote($0)))" }).joined(separator: "\n") + ")")
    }
    if !allowNetwork {
      lines.append("(deny network*)")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: In-process mirror

  /// Whether this sandbox would permit a write to `path` — the same decision the SBPL
  /// profile makes, computed in-process.
  ///
  /// `write_file` and `edit_file` write through Foundation, not through a shell, so the
  /// kernel never applies the profile to them. Without this mirror, "sandbox on" would mean
  /// two different boundaries depending on which tool the model reached for. Pure function
  /// over the same lists, in the profile's order: a protected subpath loses even inside a
  /// writable root.
  public func permitsWrite(_ path: String) -> Bool {
    let resolved = PathScope.physicalPath(path)
    if Self.writableDeviceNodes.contains(resolved) { return true }
    // The carve-outs are the profile's last write rule, so they beat the protected deny.
    for carveOut in writableCarveOuts.map({ PathScope.physicalPath($0.path) })
      where PathScope.isUnder(resolved, base: carveOut)
    {
      return true
    }
    for denied in protectedSubpaths.map({ PathScope.physicalPath($0.path) })
      where PathScope.isUnder(resolved, base: denied)
    {
      return false
    }
    let allowed = writableRoots.map { PathScope.physicalPath($0.path) }
      + Self.temporaryWritablePaths.map { PathScope.physicalPath($0) }
    return allowed.contains { PathScope.isUnder(resolved, base: $0) }
  }

  /// The refusal a file tool returns for a path the sandbox denies, or nil when it is fine.
  /// Phrased so the model stops retrying and says what it needs instead.
  public func writeRefusal(_ path: String) -> String? {
    guard !permitsWrite(path) else { return nil }
    return "error: sandbox denies write to \(path) — writes are confined to the working tree; "
      + "ask the user to widen sandbox.writable (or use --add-dir) if this was intended"
  }

  private func dedupe(_ paths: [String]) -> [String] {
    var seen = Set<String>()
    return paths.filter { seen.insert($0).inserted }
  }

  /// SBPL string literal: escape backslashes and double quotes.
  private func quote(_ path: String) -> String {
    "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
  }
}

// MARK: - Resolving a configuration

extension ShellSandbox {
  /// What a provider's `sandbox` block means for one working root.
  public struct Resolution: Sendable, Equatable {
    /// The sandbox to run under, or nil when this run is unconfined.
    public var sandbox: ShellSandbox?
    /// Deny-read entries that are glob patterns rather than paths. SBPL has no glob matcher,
    /// so these are enforced by the path classifier (`read_file`/`grep`/`glob` gate them) but
    /// not by the kernel — worth saying out loud rather than implying full coverage.
    public var skippedDenyReadPatterns: [String]
    /// A sandbox was configured, this platform can't enforce it, and `failIfUnavailable:
    /// false` let the run proceed unconfined. The caller warns.
    public var degraded: Bool

    public init(
      sandbox: ShellSandbox? = nil,
      skippedDenyReadPatterns: [String] = [],
      degraded: Bool = false)
    {
      self.sandbox = sandbox
      self.skippedDenyReadPatterns = skippedDenyReadPatterns
      self.degraded = degraded
    }
  }

  /// Turns configuration into a sandbox for `root`.
  ///
  /// - Parameters:
  ///   - config: the provider's `sandbox` block, or nil when it says nothing at all.
  ///   - addedDirectories: `--add-dir` roots — a run widened for the file tools must be
  ///     widened for `bash` too, or the two tools disagree about the same directory.
  ///   - denyReadPatterns: the config's `paths.denyRead`; literal and `~/`-anchored entries
  ///     become kernel denies, globs are reported in `skippedDenyReadPatterns`.
  ///   - autonomous: an unattended run (headless `--yes`, an eval trial, a panel candidate).
  ///     With no `sandbox` block at all these are confined **by default** wherever the
  ///     platform can enforce it — nobody is watching, so the boundary should not be opt-in.
  ///     An explicit `enabled: false` is still honored, and `failIfUnavailable: false` does
  ///     not apply: an unattended run fails closed.
  ///   - writableCarveOuts: directories inside a protected subpath that stay writable (the
  ///     project's memory directory under `~/.arnes`); empty for a run without memory.
  public static func resolve(
    config: SandboxConfig?,
    root: URL,
    addedDirectories: [URL] = [],
    denyReadPatterns: [String] = [],
    autonomous: Bool = false,
    home: String = NSHomeDirectory(),
    writableCarveOuts: [URL] = [])
    -> Resolution
  {
    let enabled = config?.enabled ?? (autonomous && isSupported)
    guard enabled else { return Resolution() }
    // The interactive escape hatch: a user who asked for a sandbox on a platform that can't
    // enforce it may choose a warning over a broken shell. Never for unattended runs.
    if !isSupported, !autonomous, config?.failIfUnavailable == false {
      return Resolution(degraded: true)
    }
    let extraWritable = (config?.writable ?? []).map {
      URL(fileURLWithPath: expandingTilde($0, home: home))
    }
    let (literalDenyRead, skipped) = literalDenyReadPaths(
      denyReadPatterns + (config?.denyRead ?? []), home: home)
    return Resolution(
      sandbox: ShellSandbox(
        writableRoots: [root] + addedDirectories + extraWritable,
        allowNetwork: config?.network ?? true,
        denyRead: defaultDenyRead(home: home) + literalDenyRead,
        writableCarveOuts: writableCarveOuts,
        home: home),
      skippedDenyReadPatterns: skipped)
  }

  /// Splits deny-read entries into paths SBPL can express and patterns it can't. Only
  /// absolute and `~/`-anchored entries are paths; anything with a glob metacharacter, or a
  /// bare relative pattern (which `GlobMatch` matches against basenames anywhere), has no
  /// SBPL equivalent.
  static func literalDenyReadPaths(
    _ patterns: [String],
    home: String = NSHomeDirectory())
    -> (paths: [URL], skipped: [String])
  {
    var paths: [URL] = []
    var skipped: [String] = []
    for raw in patterns {
      let pattern = raw.trimmingCharacters(in: .whitespaces)
      guard !pattern.isEmpty else { continue }
      let expanded = expandingTilde(pattern, home: home)
      guard expanded.hasPrefix("/"), !expanded.contains(where: { "*?[".contains($0) }) else {
        skipped.append(pattern)
        continue
      }
      paths.append(URL(fileURLWithPath: expanded))
    }
    return (paths, skipped)
  }

  /// `~` / `~/x` against an injectable home (`NSString.expandingTildeInPath` reads the real one).
  static func expandingTilde(_ path: String, home: String) -> String {
    if path == "~" { return home }
    if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
    return path
  }
}
