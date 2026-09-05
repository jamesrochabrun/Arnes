import Foundation

/// Decides whether a shell command is *obviously* read-only, so the `bash` tool can run
/// it without a prompt the way `read_file` runs freely inside the working directory.
///
/// The bar is deliberately high — anything the classifier isn't sure about is not
/// read-only, and the prompt is the safe default:
/// - every pipeline segment (split on `|`, `;`, `&&`, `||`) starts with an allowlisted
///   program, or `git` with a read-only subcommand;
/// - no redirection other than the stderr idioms (`2>&1`, `2>/dev/null`, `>/dev/null`),
///   no substitution (`$`, backticks), no backgrounding, no newlines;
/// - every non-flag argument that names a path stays inside the working tree (relative,
///   no `..`, symlinks resolved — `PathScope`), and no flag writes a file (`-o`,
///   `--output`, `find -delete/-exec`).
///
/// `git status`, `git log --oneline -10`, `ls -la`, `cat README.md`, `grep -rn foo Sources`
/// pass. `git push`, `echo x > f`, `cat ~/.ssh/id_rsa`, `find . -delete`, `swift build`,
/// `env`, and anything with `$` in it ask.
public enum ShellCommand {
  /// Programs that only read, given the argument rules above.
  static let readOnlyPrograms: Set<String> = [
    "ls", "cat", "head", "tail", "wc", "grep", "rg", "ag", "fd", "find", "pwd", "echo", "printf",
    "which", "type", "file", "stat", "du", "df", "tree", "diff", "sort", "uniq", "cut", "tr",
    "jq", "true", "false", "date", "uname", "whoami", "id", "basename", "dirname", "realpath",
    "nl", "column", "xxd", "od", "strings", "shasum", "md5", "md5sum", "sha256sum", "test", "[",
  ]

  /// `git` subcommands that never change the repository or the working tree.
  static let readOnlyGitSubcommands: Set<String> = [
    "status", "log", "diff", "show", "blame", "rev-parse", "rev-list", "ls-files", "ls-tree",
    "describe", "shortlog", "grep", "cat-file", "name-rev", "reflog", "merge-base", "count-objects",
  ]

  /// Flags that make an otherwise read-only program write somewhere.
  static let writingFlags: Set<String> = [
    "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls",
  ]

  /// Flags that name an output file or hand a program to run, whatever the program is.
  /// `--compress-program` is `sort`'s: it runs an arbitrary binary on the sort's spill files.
  static let alwaysWritingFlagPrefixes: [String] = [
    "--output", "--out-file", "--outfile", "--log-file", "--compress-program",
    "--git-dir", "--work-tree", "--exec-path",
  ]

  /// Past this length a command is not something the allowlist can reason about — the
  /// interesting part is easily hidden in the middle. It prompts instead.
  static let readOnlyLengthCap = 10_000

  public static func isReadOnly(_ command: String, root: URL? = nil, rules: PathScope.Rules = .default) -> Bool {
    var text = command.trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty, text.count <= readOnlyLengthCap else { return false }
    // Anything that can hide a second command or a write: substitution, newlines, history.
    if text.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "`" || $0 == "$" || $0 == "!" }) {
      return false
    }
    // An unbalanced quote means the rest of the string is data we can't split correctly.
    guard hasBalancedQuotes(text) else { return false }
    // Chain operators become segment separators; the harmless stderr idioms vanish;
    // any other redirection or `&` (background, fd games) disqualifies.
    text = text.replacingOccurrences(of: "&&", with: " ; ").replacingOccurrences(of: "||", with: " ; ")
    for idiom in ["2>&1", "2>/dev/null", "&>/dev/null", ">/dev/null", "2> /dev/null", "> /dev/null"] {
      text = text.replacingOccurrences(of: idiom, with: " ")
    }
    if text.contains(where: { $0 == ">" || $0 == "<" || $0 == "&" }) {
      return false
    }
    let segments = text.split(whereSeparator: { $0 == "|" || $0 == ";" }).map(String.init)
    guard !segments.isEmpty else { return false }
    return segments.allSatisfy { isReadOnlySegment($0, root: root, rules: rules) }
  }

  private static func isReadOnlySegment(_ segment: String, root: URL?, rules: PathScope.Rules) -> Bool {
    let tokens = segment.split(whereSeparator: \.isWhitespace).map { String($0) }
    guard let program = tokens.first else { return false }
    let arguments = Array(tokens.dropFirst())
    if program == "git" {
      return isReadOnlyGit(arguments, root: root, rules: rules)
    }
    guard readOnlyPrograms.contains(program) else { return false }
    return argumentsAreReadOnly(arguments, program: program, root: root, rules: rules)
  }

  private static func isReadOnlyGit(_ arguments: [String], root: URL?, rules: PathScope.Rules) -> Bool {
    var rest = arguments[...]
    // Global options before the subcommand: only the pager switch is harmless — `-C`,
    // `--git-dir`, `--work-tree` point elsewhere and `-c` can set `core.pager` to a command.
    while let first = rest.first, first.hasPrefix("-") {
      guard first == "--no-pager" || first == "-P" else { return false }
      rest = rest.dropFirst()
    }
    guard let subcommand = rest.first else { return false } // bare `git` prints help; not worth a free pass
    let subArguments = Array(rest.dropFirst())
    if readOnlyGitSubcommands.contains(subcommand) {
      return argumentsAreReadOnly(subArguments, program: "git", root: root, rules: rules)
    }
    let positionals = subArguments.filter { !$0.hasPrefix("-") }
    switch subcommand {
    case "branch":
      // Listing forms only: a positional creates, and these flags delete/move/edit.
      let mutatingFlags: Set<String> = ["-d", "-D", "-m", "-M", "-c", "-C", "-f", "-u",
                                        "--delete", "--move", "--copy", "--force", "--edit-description",
                                        "--set-upstream-to", "--unset-upstream"]
      return positionals.isEmpty && !subArguments.contains(where: { mutatingFlags.contains($0) })
        && argumentsAreReadOnly(subArguments, program: "git", root: root, rules: rules)
    case "tag":
      // `git tag` / `git tag -l` list; a positional creates, `-a/-s/-m/-f/-d` write.
      let mutatingFlags: Set<String> = ["-a", "-s", "-m", "-f", "-d", "-e", "-u",
                                        "--annotate", "--sign", "--force", "--delete", "--local-user", "--message"]
      return positionals.isEmpty && !subArguments.contains(where: { mutatingFlags.contains($0) })
        && argumentsAreReadOnly(subArguments, program: "git", root: root, rules: rules)
    case "remote":
      return subArguments.isEmpty || subArguments == ["-v"] || subArguments == ["--verbose"]
        || subArguments.first == "show" || subArguments.first == "get-url"
    case "stash":
      return subArguments.first == "list"
    case "worktree":
      return subArguments.first == "list"
    case "config":
      return subArguments.first.map { $0 == "-l" || $0 == "--list" || $0.hasPrefix("--get") } ?? false
    default:
      return false
    }
  }

  /// Flags may not name an output file; path-like positionals must stay in the tree.
  ///
  /// `-o` is judged *per program*: it names an output file for `curl`, `sort`, `tree`,
  /// `swiftc`… (`outputFlagPrograms`) and something harmless everywhere else — `ls -o` is a
  /// long format, `grep -o`/`rg -o` is only-matching, `find … -o …` is a boolean or. Treating
  /// every `-o` as a write cost a prompt on three of the most common read commands there are.
  private static func argumentsAreReadOnly(
    _ arguments: [String],
    program: String,
    root: URL?,
    rules: PathScope.Rules)
    -> Bool
  {
    for argument in arguments {
      if argument.hasPrefix("-") {
        if writingFlags.contains(argument) { return false }
        if alwaysWritingFlagPrefixes.contains(where: { argument.hasPrefix($0) }) { return false }
        if argument.hasPrefix("-o") || argument.hasPrefix("-O"), outputFlagPrograms.contains(program) {
          return false
        }
        continue
      }
      if !pathStaysInside(argument, root: root, rules: rules) { return false }
    }
    return true
  }

  /// A positional that could be a path: absolute, home-relative, or parent-relative
  /// arguments are out; anything that exists on disk must classify as inside the tree
  /// (symlinks resolved). Tokens that exist nowhere (patterns, literals) are fine.
  ///
  /// The one exception is a run that named extra directories with `--add-dir` — or opened the
  /// project's memory directory (`rules.memoryRoot`, C3) or the REPL's paste stash
  /// (`rules.pasteStash`): an explicit escape then gets classified rather than rejected
  /// outright, so `cat /other/checkout/x` is as free as an in-tree read when
  /// `/other/checkout` is one of them, and `cat` on the memory index or `ls` on a dragged
  /// image's stash is as free as `read_file` there. With none — every run that has no such
  /// carve-out — the fast bail is exactly as before.
  private static func pathStaysInside(_ token: String, root: URL?, rules: PathScope.Rules) -> Bool {
    let unquoted = token.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    // `~` is the shell's to expand, not ours: never resolve it here.
    if unquoted.hasPrefix("~") { return false }
    let escapes = unquoted.hasPrefix("/") || unquoted == ".." || unquoted.hasPrefix("../")
      || unquoted.contains("/../") || unquoted.hasSuffix("/..")
    if escapes {
      guard !rules.roots.readable.isEmpty || rules.memoryRoot != nil || rules.pasteStash != nil
      else { return false }
      return PathScope.classify(unquoted, root: root, rules: rules) == .inside
    }
    let resolved = resolveToolPath(unquoted, root: root)
    guard FileManager.default.fileExists(atPath: resolved) else { return true }
    return PathScope.classify(unquoted, root: root, rules: rules) == .inside
  }
}

// MARK: - Danger classification

/// Where a command sits on the *reversibility* axis, orthogonal to `isReadOnly`'s
/// *skip-the-prompt* axis. Read-only is the fast path; everything else is at least a
/// prompt, destructive commands get the louder `.sensitive` prompt, and catastrophic
/// commands are refused outright by `BashTool` before they ever run.
public enum ShellRisk: Sendable, Equatable {
  case readOnly
  /// Mutating but ordinarily recoverable (`mkdir`, `touch`, `swift build`).
  case ordinary
  /// Irreversible and worth an extra beat (`rm`, `git push --force`, `sudo …`).
  case destructive
  /// Irrecoverable-catastrophic — never run, even under `--yes`. Carries the reason.
  case catastrophic(reason: String)
}

extension ShellCommand {
  /// Composite classification used by `BashTool`: catastrophic wins, then read-only,
  /// then destructive, else ordinary-mutating.
  public static func risk(_ command: String, root: URL? = nil, rules: PathScope.Rules = .default) -> ShellRisk {
    if let reason = isCatastrophic(command, root: root, rules: rules) { return .catastrophic(reason: reason) }
    if isReadOnly(command, root: root, rules: rules) { return .readOnly }
    if isDestructive(command, root: root, rules: rules) { return .destructive }
    return .ordinary
  }

  // MARK: The floor

  /// System roots whose recursive deletion (or permission change, or move) is unrecoverable.
  static let protectedRoots: Set<String> = [
    "/", "/*", "/usr", "/etc", "/bin", "/sbin", "/lib", "/lib64", "/var", "/boot", "/dev",
    "/proc", "/sys", "/opt", "/root", "/home", "/Users", "/System", "/Library", "/Applications",
    "/private", "/Volumes",
  ]

  /// The user's home in the spellings a command might use.
  static let homeTargets: Set<String> = ["~", "~/*", "$HOME", "${HOME}", "$HOME/*", "${HOME}/*"]

  /// Raw block devices — writing to one wipes a disk. `/dev/null`, `/dev/stdout` etc. are fine.
  static let devicePrefixes = ["/dev/sd", "/dev/disk", "/dev/rdisk", "/dev/nvme", "/dev/hd",
                               "/dev/mmcblk", "/dev/vd", "/dev/xvd"]

  /// The hard denylist: commands that must never run, even under `--yes`/AutoApprove.
  /// Returns a short reason when the command is irrecoverable-catastrophic, nil otherwise.
  ///
  /// Deliberately **high precision** — a false positive here blocks legitimate work — so it
  /// flags only the unambiguous, famous footguns (wipe `/` or `$HOME`, format a disk, fork
  /// bomb, pipe the network into a shell). It is a floor, not containment: the OS sandbox is
  /// what makes a *miss* survivable. `BashTool.execute` refuses before spawning when this hits.
  public static func isCatastrophic(
    _ command: String,
    root: URL? = nil,
    rules: PathScope.Rules = .default)
    -> String?
  {
    isCatastrophic(command, root: root, rules: rules, depth: 0)
  }

  /// - Parameter depth: recursion guard for `sh -c "…"` / `eval …`, whose inner command is
  ///   classified with the same rules so `bash -c "rm -rf /"` is refused like `rm -rf /`.
  static func isCatastrophic(
    _ command: String,
    root: URL?,
    rules: PathScope.Rules,
    depth: Int)
    -> String?
  {
    let squished = String(command.filter { !$0.isWhitespace })
    // Fork bomb: :(){ :|:& };: and near variants.
    if squished.contains("(){:|:&") || (squished.contains(":(){") && squished.contains(":|:")) {
      return "fork bomb"
    }
    // Remote code execution: curl/wget … | sh/bash/python, or an interpreter running
    // downloaded code via process/command substitution (`bash <(curl …)`, `sh -c "$(curl …)"`).
    if pipesNetworkIntoShell(command) { return "pipes downloaded code straight into a shell" }
    if substitutesNetworkIntoShell(command) { return "runs downloaded code through a shell substitution" }
    // Redirection onto a raw disk device.
    let noSpaceRedir = command.replacingOccurrences(of: " ", with: "")
    for prefix in devicePrefixes where noSpaceRedir.contains(">" + prefix) {
      return "writes directly to a disk device"
    }
    // A write whose *target* is harness state: `echo … > ~/.arnes/hooks.json`,
    // `… | tee $ARNES_RULES_CONFIG`, `cp evil ~/.arnes/config.json`. The bash twin of the
    // refusal `write_file`/`edit_file` already make, and for the same reason.
    if case .floor(let reason) = writeTargetRisk(ofCommand: command, root: root, rules: rules) {
      return reason
    }
    // Per-segment program checks. This split is the original one, kept verbatim so the
    // existing floor rules see exactly what they always saw.
    let segments = command
      .replacingOccurrences(of: "&&", with: "\n").replacingOccurrences(of: "||", with: "\n")
      .split(whereSeparator: { $0 == ";" || $0 == "|" || $0 == "\n" }).map(String.init)
    for segment in segments {
      if let reason = catastrophicSegment(segment) { return reason }
    }
    // The v2 rules read quote-aware stages instead, so `python -c "a; b"` stays one command.
    for stage in pipelines(command).flatMap({ $0 }) {
      if let reason = criticalRemovalFloor(stage, root: root, rules: rules) { return reason }
      guard depth < 2 else { continue }
      for inner in innerShellCommands(of: stage) {
        if let reason = isCatastrophic(inner, root: root, rules: rules, depth: depth + 1) { return reason }
      }
    }
    // `echo 'rm -rf /' | sh` — the literal on the left is the command that runs.
    guard depth < 2 else { return nil }
    for pipe in pipedInterpreterSources(command) {
      guard let literal = literalPipeSource(pipe.source) else { continue }
      if let reason = isCatastrophic(literal, root: root, rules: rules, depth: depth + 1) { return reason }
    }
    return nil
  }

  private static func catastrophicSegment(_ segment: String) -> String? {
    var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
    while tokens.first == "sudo" || tokens.first == "doas" { tokens.removeFirst()
      // skip sudo's own options (e.g. -u user) up to the real program
      while let f = tokens.first, f.hasPrefix("-") { tokens.removeFirst() }
    }
    guard let program = tokens.first else { return nil }
    let arguments = Array(tokens.dropFirst())
    let (recursive, _, positionals) = flagsAndPositionals(arguments)

    if program == "mkfs" || program.hasPrefix("mkfs.") { return "formats a filesystem" }
    switch program {
    case "rm":
      // A recursive delete whose target is a system root or the home directory itself.
      if recursive, positionals.contains(where: targetIsProtectedRoot) {
        return "recursively deletes a system or home root"
      }
      return nil
    case "dd":
      if arguments.contains(where: { arg in
        devicePrefixes.contains(where: { arg.hasPrefix("of=" + $0) })
      }) { return "overwrites a disk device with dd" }
      return nil
    case "chmod", "chown", "chgrp":
      if recursive, positionals.contains(where: targetIsProtectedRoot) {
        return "recursively changes permissions on a system or home root"
      }
      return nil
    case "mv":
      if let source = positionals.first, targetIsProtectedRoot(source) {
        return "moves a system or home root"
      }
      return nil
    case "find":
      // `find <system-or-home-root> … -delete` (or `-exec rm …`) walks the whole tree
      // deleting as it goes — the recursive-delete footgun in a different spelling.
      let deletes = arguments.contains("-delete")
        || zip(arguments, arguments.dropFirst()).contains {
          ($0.0 == "-exec" || $0.0 == "-execdir") && ($0.1 == "rm" || $0.1 == "unlink" || $0.1 == "shred")
        }
      if deletes, positionals.contains(where: targetIsProtectedRoot) {
        return "recursively deletes a system or home root via find"
      }
      return nil
    default:
      return nil
    }
  }

  /// True when a `curl`/`wget`-style fetch is piped into an interpreter — a shell, or
  /// `python`/`node`/`ruby`/`perl`, which run downloaded code just as completely.
  private static func pipesNetworkIntoShell(_ command: String) -> Bool {
    let fetchers: Set<String> = ["curl", "wget", "fetch", "lynx"]
    let segments = command.split(separator: "|").map(String.init)
    guard segments.count >= 2 else { return false }
    let fetchesEarly = segments.dropLast().contains { firstProgram(of: $0).map(fetchers.contains) ?? false }
    let shellLast = segments.dropFirst().contains { firstProgram(of: $0).map(interpreterSinks.contains) ?? false }
    return fetchesEarly && shellLast
  }

  private static func firstProgram(of segment: String) -> String? {
    var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
    while tokens.first == "sudo" || tokens.first == "doas" { tokens.removeFirst() }
    return tokens.first
  }

  /// True when downloaded code reaches a shell through a substitution rather than a pipe:
  /// `bash <(curl …)`, `sh -c "$(curl …)"`, `` sh -c "`wget …`" ``. High-precision: a
  /// fetcher must appear *inside* a `$(`/`` ` ``/`<(` substitution and a shell interpreter
  /// must be present as a program token.
  private static func substitutesNetworkIntoShell(_ command: String) -> Bool {
    let fetchers = ["curl", "wget", "fetch"]
    // A fetcher immediately inside a command/process substitution.
    let fetchInSubstitution = fetchers.contains { fetcher in
      ["$(\(fetcher)", "<(\(fetcher)", "`\(fetcher)", "$( \(fetcher)", "<( \(fetcher)"].contains {
        command.contains($0)
      }
    }
    guard fetchInSubstitution else { return false }
    let shells = interpreterSinks.union(["eval"])
    // Any program token (before a substitution opens) is an interpreter.
    let tokens = command
      .replacingOccurrences(of: "(", with: " ")
      .replacingOccurrences(of: "\"", with: " ")
      .split(whereSeparator: \.isWhitespace).map(String.init)
    return tokens.contains { shells.contains($0) }
  }

  /// The user's real home directory, resolved, plus a trailing-slash and `/*` spelling —
  /// so a literal `rm -rf /Users/me` is caught the way `rm -rf ~` already is.
  static let resolvedHomeTargets: Set<String> = {
    let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.resolvingSymlinksInPath().path
    guard home != "/", !home.isEmpty else { return [] }
    return [home, home + "/", home + "/*"]
  }()

  private static func targetIsProtectedRoot(_ positional: String) -> Bool {
    var target = positional.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    if target.count > 1, target.hasSuffix("/"), !target.hasSuffix("/*") { target.removeLast() }
    if protectedRoots.contains(target) || homeTargets.contains(target) { return true }
    if resolvedHomeTargets.contains(target) { return true }
    // The physical path of a literal home target (`/Users/me`, symlinked homes).
    let physical = PathScope.physicalPath(target)
    return resolvedHomeTargets.contains(physical) || resolvedHomeTargets.contains(physical + "/*")
  }

  // MARK: The .sensitive tier

  /// Programs whose every invocation is irreversible (deletes/overwrites/clobbers).
  static let destructivePrograms: Set<String> = [
    "rm", "rmdir", "unlink", "shred", "srm", "truncate", "mv", "dd",
    "kill", "killall", "pkill",
  ]

  /// Recognized-irreversible commands that get the louder `.sensitive` prompt and are never
  /// covered by "always allow this session". Unrecognized mutations stay `.ordinary` and still
  /// prompt, so a miss only means a *normal* prompt — never a free pass.
  public static func isDestructive(
    _ command: String,
    root: URL? = nil,
    rules: PathScope.Rules = .default)
    -> Bool
  {
    isDestructive(command, root: root, rules: rules, depth: 0)
  }

  static func isDestructive(_ command: String, root: URL?, rules: PathScope.Rules, depth: Int) -> Bool {
    // A write landing outside the tree, on a credential/startup file, or on an in-tree
    // protected path is irreversible whatever program produced it — `echo x > ~/.zshrc`
    // is the same act as `write_file ~/.zshrc`. In-tree redirects stay ordinary.
    if writeTargetRisk(ofCommand: command, root: root, rules: rules) == .destructive { return true }
    // Same segment split as isReadOnly (chain operators become separators).
    var text = command
      .replacingOccurrences(of: "&&", with: " ; ").replacingOccurrences(of: "||", with: " ; ")
    for idiom in ["2>&1", "2>/dev/null", "&>/dev/null", ">/dev/null", "2> /dev/null", "> /dev/null"] {
      text = text.replacingOccurrences(of: idiom, with: " ")
    }
    let segments = text.split(whereSeparator: { $0 == "|" || $0 == ";" }).map(String.init)
    if segments.contains(where: destructiveSegment) { return true }
    // The v2 rules read quote-aware stages, so a `;` inside `python -c "…"` doesn't split it.
    for stage in pipelines(command).flatMap({ $0 }) {
      if inlineScriptDeletes(stage) { return true }
      guard depth < 2 else { continue }
      // `xargs rm` is `rm`; `sh -c "rm -rf build"` is the rm it will run.
      if let payload = xargsPayload(stage), isDestructive(payload, root: root, rules: rules, depth: depth + 1) {
        return true
      }
      for inner in innerShellCommands(of: stage)
      where isDestructive(inner, root: root, rules: rules, depth: depth + 1) {
        return true
      }
    }
    // Bytes from anywhere but a literal reaching an interpreter's stdin: `cat payload | sh`,
    // `base64 -d | python3`. A network source is the floor's business (above); this is the
    // rest, and it is `.sensitive` because the model is choosing to execute opaque input.
    for pipe in pipedInterpreterSources(command) {
      guard let literal = literalPipeSource(pipe.source) else { return true }
      guard depth < 2 else { continue }
      if isDestructive(literal, root: root, rules: rules, depth: depth + 1) { return true }
    }
    return false
  }

  private static func destructiveSegment(_ segment: String) -> Bool {
    let tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
    // Elevated privileges are always worth the extra beat.
    if tokens.first == "sudo" || tokens.first == "doas" { return true }
    guard let program = tokens.first else { return false }
    let arguments = Array(tokens.dropFirst())
    if destructivePrograms.contains(program) { return true }
    if program == "find", arguments.contains(where: writingFlags.contains) { return true }
    let (recursive, force, _) = flagsAndPositionals(arguments)
    if (program == "chmod" || program == "chown" || program == "chgrp"), recursive { return true }
    if program == "git" { return isDestructiveGit(arguments) }
    // An in-place edit rewrites the file it is pointed at; `sed -n`/`sed 's/…/…/' f` doesn't.
    if ["sed", "gsed", "perl", "ruby"].contains(program), editsInPlace(arguments) { return true }
    // The one HTTP verb that removes server-side state. `PUT`/`PATCH` are deliberately left
    // out: an API iteration loop that can never be granted for the session is a worse tool
    // than one that prompts normally.
    if program == "curl" || program == "http" || program == "httpie" {
      if let slot = arguments.firstIndex(where: { $0 == "-X" || $0 == "--request" }),
         slot + 1 < arguments.count, arguments[slot + 1].uppercased() == "DELETE"
      {
        return true
      }
    }
    // Package/infra commands that publish or tear down.
    if let sub = arguments.first(where: { !$0.hasPrefix("-") }) {
      switch program {
      case "npm", "yarn", "pnpm", "bun":
        return sub == "publish" || sub == "unpublish"
      case "docker":
        return ["rmi", "rm"].contains(sub)
          || (["system", "volume", "image"].contains(sub) && arguments.contains("prune"))
      case "kubectl", "helm", "terraform":
        return ["delete", "destroy", "uninstall"].contains(sub)
      case "brew", "apt", "apt-get", "yum", "dnf", "pacman":
        return ["uninstall", "remove", "purge", "autoremove", "-R", "-Rs"].contains(sub)
      case "gh":
        // `gh repo delete`, `gh release delete`, `gh pr merge --delete-branch`.
        return arguments.contains("delete") || arguments.contains("--delete-branch")
          || arguments.contains("delete-asset")
      case "aws":
        return (sub == "s3" && arguments.contains(where: { $0 == "rm" || $0 == "rb" }))
          || arguments.contains(where: { $0.hasPrefix("delete-") || $0 == "delete" })
      case "gcloud", "az", "flyctl", "fly", "heroku", "vercel", "netlify", "supabase", "railway":
        return arguments.contains("delete") || arguments.contains("destroy")
      default: break
      }
    }
    if program == "dropdb" || program == "dropuser" { return true }
    _ = force
    return false
  }

  private static func isDestructiveGit(_ arguments: [String]) -> Bool {
    var rest = arguments[...]
    while let first = rest.first, first.hasPrefix("-") { rest = rest.dropFirst() }
    guard let sub = rest.first else { return false }
    let subArgs = Array(rest.dropFirst())
    switch sub {
    case "push", "reset", "rebase", "filter-branch", "gc", "restore":
      return true
    case "clean":
      return subArgs.contains { $0.hasPrefix("-") && ($0.contains("f") || $0.contains("d") || $0.contains("x")) }
    case "checkout":
      return subArgs.contains("--") || subArgs.contains(".") || subArgs.contains("-f") || subArgs.contains("--force")
    case "branch":
      // `-f` moves a branch ref to another commit, discarding what it pointed at.
      return subArgs.contains { ["-D", "-d", "-M", "-f", "--delete", "--move", "--force"].contains($0) }
    case "remote":
      // Repointing or dropping a remote redirects every later push.
      return subArgs.first.map { ["set-url", "add", "remove", "rm", "rename", "prune"].contains($0) } ?? false
    case "tag":
      return subArgs.contains { $0 == "-d" || $0 == "--delete" }
    case "stash":
      return subArgs.first.map { ["drop", "clear", "pop"].contains($0) } ?? false
    case "worktree":
      return subArgs.first == "remove"
    case "submodule":
      return subArgs.first == "deinit"
    case "update-ref":
      return subArgs.contains("-d")
    case "commit":
      return subArgs.contains("--amend")
    default:
      return false
    }
  }

  // MARK: Segments

  /// Splits a command into its segments and strips the leading wrappers (`sudo`, `env
  /// VAR=x`, `timeout 5`, `nice`, `nohup`, `FOO=bar prog`) so what's left starts with the
  /// real program.
  ///
  /// The one splitter: the permission rules match `Bash(prefix *)` against these segments
  /// and `sessionGrantPatterns` generates grants from them, so a rule and the grant it
  /// came from can never disagree about where one command ends and the next begins.
  public static func segments(_ command: String) -> [String] {
    rawSegments(command).map(stripWrappers).filter { !$0.isEmpty }
  }

  /// The same split with the wrappers left on — what the danger classifiers must see, since
  /// `sudo` *is* the danger in `sudo npm install`.
  static func rawSegments(_ command: String) -> [String] {
    var text = command
    for op in ["&&", "||"] { text = text.replacingOccurrences(of: op, with: "\n") }
    return text
      .split(whereSeparator: { $0 == ";" || $0 == "|" || $0 == "&" || $0 == "\n" })
      .map { String($0).trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  static let wrapperPrograms: Set<String> = [
    "sudo", "doas", "nohup", "nice", "ionice", "time", "command", "builtin", "exec",
  ]

  static func stripWrappers(_ segment: String) -> String {
    var tokens = segment.split(whereSeparator: \.isWhitespace).map(String.init)
    while let first = tokens.first {
      if wrapperPrograms.contains(first) { tokens.removeFirst(); continue }
      if first == "timeout", tokens.count > 1 { tokens.removeFirst(2); continue }
      if first == "env" {
        tokens.removeFirst()
        while let f = tokens.first, f.contains("="), !f.hasPrefix("-") { tokens.removeFirst() }
        continue
      }
      if first.contains("="), !first.hasPrefix("-") { tokens.removeFirst(); continue } // FOO=bar prog
      break
    }
    return tokens.joined(separator: " ")
  }

  // MARK: Network

  /// Programs whose ordinary use reaches the network whatever their arguments: fetchers,
  /// remote shells and copies, relays, name and host probes (a DNS or ICMP query carries bytes
  /// out too), mail, package managers with no local mode, cloud and cluster CLIs.
  static let networkPrograms: Set<String> = [
    "curl", "wget", "fetch", "lynx", "http", "https", "httpie", "nc", "ncat", "netcat", "socat",
    "ssh", "scp", "sftp", "ftp", "tftp", "rsync", "telnet", "dig", "nslookup", "host", "whois",
    "ping", "ping6", "traceroute", "nmap", "sendmail", "mail", "gh", "apt", "apt-get", "dnf",
    "yum", "pacman", "aws", "gcloud", "az", "kubectl", "helm", "terraform",
  ]

  /// Substitutions that hide a second command inside a stage — `$(…)`, a backtick, `<(…)`,
  /// `>(…)`. What runs inside cannot be read here, so after a taint the stage is treated as
  /// reaching the network: the consequence of the doubt is a prompt (or an unattended
  /// refusal), never a pass.
  static let commandSubstitutionMarkers = ["$(", "`", "<(", ">("]

  /// bash's own sockets: `exec 3<>/dev/tcp/host/80` opens a connection with no program named.
  static let shellSocketPaths = ["/dev/tcp/", "/dev/udp/"]

  /// Programs that reach the network only under some subcommands — any token after the
  /// program equal to one of these counts (`git -C dir push origin` is a push).
  static let networkSubcommands: [String: Set<String>] = [
    "git": ["push", "fetch", "pull", "clone", "remote", "ls-remote", "submodule"],
    "pip": ["install", "download"], "pip3": ["install", "download"], "uv": ["install", "download", "sync", "add"],
    "npm": ["install", "i", "add", "publish", "ci", "update"],
    "yarn": ["install", "add", "publish", "ci"],
    "pnpm": ["install", "i", "add", "publish", "ci"],
    "bun": ["install", "i", "add", "publish", "ci"],
    "brew": ["install", "upgrade"],
    "cargo": ["install", "fetch", "publish", "update"],
    "go": ["get", "install", "download"],
    "docker": ["pull", "push", "login"], "podman": ["pull", "push", "login"],
    "openssl": ["s_client"],
  ]

  /// Whether `command` can reach the network — the taint escalation's question
  /// (`Session.permissionDenial`: after untrusted content such a call is `.sensitive`, so an
  /// unattended run refuses it). Per quote-aware pipeline stage (`pipelines`, wrappers
  /// stripped), true when:
  /// - the program is one of `networkPrograms`, or one of `networkSubcommands` under a
  ///   network subcommand (any token after the program — `git -C dir push origin` is a push;
  ///   a quoted word is data, so `git commit -m "push"` is not);
  /// - the program is an **interpreter** (`interpreterPrograms`, the session-grant rule: an
  ///   interpreter is everything it can run) — `bash -c "curl …"`, `python3 -c "urllib…"`,
  ///   `… | xargs curl`, `cat payload | sh`, `node -e "fetch(…)"` and `python3 fetch.py` alike,
  ///   because the classifier cannot read what the script does and an injected instruction
  ///   chooses the wrapper;
  /// - the program is itself an expansion (`$CMD https://…` — whatever a variable holds), the
  ///   command carries a substitution (`echo $(curl …)`, a backtick, `<(…)`) or opens one of
  ///   bash's `/dev/tcp` sockets.
  /// Anything else — an unknown program, a script file (`./deploy.sh`), a plain `$VAR`
  /// argument, an in-tree redirect — is `false`: a miss costs a prompt that wasn't escalated,
  /// never a floor, and escalating every mutation after a taint would make `bash` unusable.
  public static func reachesNetwork(_ command: String) -> Bool {
    if shellSocketPaths.contains(where: command.contains) { return true }
    if commandSubstitutionMarkers.contains(where: command.contains) { return true }
    for stage in pipelines(command).flatMap({ $0 }) {
      // Whitespace tokens, quotes left on: a quoted argument can never spell a subcommand
      // (`git commit -m "push"`), and only the program name is read past its quotes.
      let raw = stripWrappers(stage).split(whereSeparator: \.isWhitespace).map(String.init)
      // Peel shell grouping and keyword prefixes so a wrapped fetch can't hide behind them:
      // `( curl … )`, `{ curl …; }`, `if …; then curl …`, `for … do curl …`, `! curl …`.
      let tokens = peelGroupingAndKeywords(raw)
      guard let first = tokens.first else { continue }
      // Escalate an unresolvable program past a taint (the safe direction here — this is only
      // consulted after untrusted content, so an injected wrapper or an obfuscated program
      // name must not slip through): a variable (`$CMD`, `"$CMD"`), a bare grouping char left
      // stuck to the program (`(curl`, `{curl`), or an empty resolution.
      if first.hasPrefix("$") { return true }
      if let lead = first.first, lead == "(" || lead == "{" || lead == "`" { return true }
      // Resolve past quotes and backslashes: `\curl`, `cu''rl`, `cur"l"`, `/usr/bin/env` → the
      // bare name. `env <prog>` that `stripWrappers` did not strip (an absolute `/usr/bin/env`)
      // hides the real program from this classifier, so it escalates.
      let program = resolvedProgram(first)
      if program.isEmpty || program.hasPrefix("$") || program == "env" { return true }
      if networkPrograms.contains(program) { return true }
      if interpreterPrograms.contains(program) { return true }
      if let subcommands = networkSubcommands[program],
         tokens.dropFirst().contains(where: { subcommands.contains($0) })
      {
        return true
      }
    }
    return false
  }

  /// Shell grouping tokens and compound-command keywords that can precede the real program in
  /// a stage `pipelines` did not split (a `;`-free `if`/`for`/`{`/subshell body): dropped from
  /// the front so the program after them is read. A leftover `(`/`{` stuck to the program (no
  /// space) is caught by `reachesNetwork`'s lead-char check instead.
  static let groupingLeadTokens: Set<String> = [
    "(", ")", "{", "}", "!", "if", "then", "elif", "else", "fi", "do", "done",
    "while", "until", "for", "in", "case", "esac", "time", "[", "[[", "((",
  ]

  private static func peelGroupingAndKeywords(_ tokens: [String]) -> [String] {
    var rest = tokens[...]
    while let first = rest.first, groupingLeadTokens.contains(first) { rest = rest.dropFirst() }
    return Array(rest)
  }

  /// A program name resolved past shell quoting and backslashes and down to its basename, so
  /// `\curl`, `cu''rl`, `cur"l"` and `/usr/bin/curl` all read as `curl`.
  private static func resolvedProgram(_ token: String) -> String {
    let unquoted = token.filter { $0 != "\"" && $0 != "'" && $0 != "\\" }
    return (unquoted as NSString).lastPathComponent
  }

  // MARK: Session grants

  /// Programs that run whatever they are handed. A grant on one of these is a grant on
  /// everything (`Bash(python *)` would cover `python -c "shutil.rmtree('/')"`), so
  /// approving one call never becomes a standing pattern.
  static let interpreterPrograms: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "eval", "exec", "source", ".",
    "python", "python2", "python3", "ruby", "perl", "php", "node", "nodejs", "deno", "bun",
    "bunx", "npx", "pnpx", "osascript", "Rscript", "java", "xargs", "ssh", "screen", "tmux",
  ]

  /// Characters that can hide a second command inside what looks like one segment. A
  /// segment carrying any of them is approved for this call only — an unparseable command
  /// is a non-match, which is the safe direction.
  private static let opaqueCharacters: Set<Character> = ["$", "`", ">", "<", "(", ")", "\n", "\r"]

  /// The standing grants to create when the user answers "always this session" to a `bash`
  /// call: one `Bash(<program> <subcommand> *)` pattern per segment that is worth one.
  ///
  /// Deliberately narrow — a grant is written in the rules-file spelling and matched by the
  /// same matcher as an `allow` rule, so it must be as specific as a rule a human would
  /// write. Per segment:
  /// - read-only segments get nothing (they never prompt anyway);
  /// - a **destructive** segment gets nothing (`rm`, `git push`, `sudo …` stay one-shot —
  ///   answering "always" to `npm test && git push` grants `Bash(npm test *)` and never the
  ///   push, and because an allow pattern must match *every* segment, a later command that
  ///   still contains the push prompts again);
  /// - an **interpreter** gets nothing, and neither does a segment with substitution or
  ///   redirection in it;
  /// - anything else yields its first two tokens. Never `Bash(*)`.
  public static func sessionGrantPatterns(
    for command: String,
    root: URL? = nil,
    rules: PathScope.Rules = .default)
    -> [String]
  {
    // A command the floor refuses can't be approved at all, let alone remembered.
    guard isCatastrophic(command, root: root, rules: rules) == nil else { return [] }
    var patterns: [String] = []
    for segment in rawSegments(command) {
      guard let pattern = grantPattern(for: segment, root: root, rules: rules) else { continue }
      if !patterns.contains(pattern) { patterns.append(pattern) }
    }
    return patterns
  }

  /// - Parameter segment: the *raw* segment. The danger checks run against it with its
  ///   wrappers on (`sudo npm install` is destructive, and stripping `sudo` first would
  ///   launder it into a grant); only the pattern itself is built from the stripped form,
  ///   matching what the rule matcher will compare against later.
  private static func grantPattern(for segment: String, root: URL?, rules: PathScope.Rules) -> String? {
    if isReadOnly(segment, root: root, rules: rules) { return nil }
    if isDestructive(segment, root: root, rules: rules) { return nil }
    if segment.contains(where: { opaqueCharacters.contains($0) }) { return nil }
    let tokens = stripWrappers(segment).split(whereSeparator: \.isWhitespace).map(String.init)
    guard let program = tokens.first, !program.isEmpty else { return nil }
    guard !interpreterPrograms.contains(program) else { return nil }
    // A wildcard or a path-ish program name would generalize past what was approved.
    guard !program.contains("*"), !program.contains("?") else { return nil }
    let prefix = tokens.count > 1 && !tokens[1].contains("*")
      ? "\(program) \(tokens[1])"
      : program
    return "Bash(\(prefix) *)"
  }

  /// Splits args into (any-recursive-flag, any-force-flag, path-like positionals).
  static func flagsAndPositionals(_ arguments: [String]) -> (recursive: Bool, force: Bool, positionals: [String]) {
    var recursive = false, force = false
    var positionals: [String] = []
    for arg in arguments {
      if arg == "--recursive" || arg == "-R" { recursive = true; continue }
      if arg == "--force" { force = true; continue }
      if arg.hasPrefix("-"), !arg.hasPrefix("--") {
        let letters = arg.dropFirst()
        if letters.contains("r") || letters.contains("R") { recursive = true }
        if letters.contains("f") { force = true }
        continue
      }
      if arg.hasPrefix("--") { continue }
      positionals.append(arg)
    }
    return (recursive, force, positionals)
  }
}
