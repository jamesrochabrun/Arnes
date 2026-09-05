import Foundation

// MARK: - Bash classifier v2: what a command writes, and where

/// `ShellCommand.swift` decides what a command does by looking at the *program* it runs.
/// That is only half the shell: an innocent program becomes a write when its output is
/// redirected (`echo x > ~/.zshrc`), teed (`… | tee ~/.arnes/hooks.json`), edited in place
/// (`sed -i`), or copied onto something that matters (`cp evil /etc/hosts`). This file
/// extracts those *targets* and runs each one through `PathScope.classify(forWriting:)` —
/// the same gate `write_file` and `edit_file` pass — so the write floor holds through the
/// shell too, plus the removal/interpreter rules that need the same tokenizer.
///
/// The tiers mirror the file tools deliberately:
/// - a target on **harness** state (`~/.arnes/**`, whatever `ARNES_*_CONFIG` points at) is
///   the **catastrophic floor**, because an agent that can rewrite `hooks.json`/`rules.json`
///   can delete every guardrail it runs under — the same reason `WriteFileTool` refuses it
///   inside `execute` rather than asking;
/// - a target **outside** the tree, on a credential path, a shell startup file, or an
///   in-tree protected path (`.git/hooks`, `.github/workflows`, `.claude`) is `.destructive`
///   — the louder prompt, never covered by "always allow this session";
/// - a plain in-tree target is `.ordinary`. `echo x > out.txt` prompts like any other
///   mutation and nothing more: a `.sensitive` prompt on every redirect would make `bash`
///   unusable, which is a worse outcome than the prompt it saves.
///
/// Everything here is heuristic — there is no real shell parser — so the two directions are
/// not symmetric: an unparseable target degrades to `.ordinary` (a prompt), never to
/// read-only and never silently to the floor.
extension ShellCommand {

  // MARK: Tokenizing

  /// A quote-aware tokenizer for one command segment. Quotes are consumed (the value is
  /// what the shell would pass), backslash escapes the next character, and redirection
  /// operators come back as their own tokens even when glued to their target — so
  /// `2>&1`, `>out.txt` and `&>/dev/null` all tokenize the way the shell reads them.
  static func shellTokens(_ segment: String) -> [String] {
    var tokens: [String] = []
    var current = ""
    var hasContent = false
    var quote: Character?
    let chars = Array(segment)
    var index = 0

    func flush() {
      if hasContent { tokens.append(current) }
      current = ""
      hasContent = false
    }

    while index < chars.count {
      let character = chars[index]
      if let open = quote {
        if character == open { quote = nil } else { current.append(character) }
        hasContent = true
        index += 1
        continue
      }
      switch character {
      case "\"", "'":
        quote = character
        hasContent = true
        index += 1
      case "\\" where index + 1 < chars.count:
        current.append(chars[index + 1])
        hasContent = true
        index += 2
      case let c where c.isWhitespace:
        flush()
        index += 1
      case ">", "<":
        // A single leading digit is the file descriptor, not part of the previous word.
        var op = ""
        if current.count == 1, let last = current.last, last.isNumber {
          op = String(last)
          current = ""
          hasContent = false
        }
        flush()
        op.append(character)
        index += 1
        if index < chars.count, chars[index] == ">" || chars[index] == "|" || chars[index] == "&" {
          op.append(chars[index])
          index += 1
        }
        tokens.append(op)
      case "&" where index + 1 < chars.count && chars[index + 1] == ">":
        flush()
        var op = "&>"
        index += 2
        if index < chars.count, chars[index] == ">" { op.append(">"); index += 1 }
        tokens.append(op)
      default:
        current.append(character)
        hasContent = true
        index += 1
      }
    }
    flush()
    return tokens
  }

  /// Whether every quote in the command is closed. An unbalanced quote means the rest of
  /// the string is data we can't reason about, so the read-only fast path declines it.
  static func hasBalancedQuotes(_ text: String) -> Bool {
    var quote: Character?
    let chars = Array(text)
    var index = 0
    while index < chars.count {
      let character = chars[index]
      if let open = quote {
        if character == "\\", open == "\"", index + 1 < chars.count { index += 2; continue }
        if character == open { quote = nil }
        index += 1
        continue
      }
      if character == "\\", index + 1 < chars.count { index += 2; continue }
      if character == "\"" || character == "'" { quote = character }
      index += 1
    }
    return quote == nil
  }

  /// Splits a command into pipelines, each a list of stages. Quote-aware, so a `|` inside
  /// a string is data; `||`/`&&`/`;`/newline/`&` end a pipeline, a bare `|` ends a stage,
  /// and the `&` of `2>&1` stays where it belongs.
  ///
  /// This is *not* `rawSegments` — that one is the grant/rule splitter and must keep its
  /// exact behavior. This one exists for pipeline-shaped questions ("does anything feed an
  /// interpreter?") where knowing the stage order matters.
  static func pipelines(_ command: String) -> [[String]] {
    var result: [[String]] = []
    var pipeline: [String] = []
    var current = ""
    var quote: Character?
    let chars = Array(command)
    var index = 0

    func endStage() {
      let trimmed = current.trimmingCharacters(in: .whitespaces)
      if !trimmed.isEmpty { pipeline.append(trimmed) }
      current = ""
    }
    func endPipeline() {
      endStage()
      if !pipeline.isEmpty { result.append(pipeline) }
      pipeline = []
    }

    while index < chars.count {
      let character = chars[index]
      if let open = quote {
        current.append(character)
        if character == open { quote = nil }
        index += 1
        continue
      }
      switch character {
      case "\"", "'":
        quote = character
        current.append(character)
        index += 1
      case "\\" where index + 1 < chars.count:
        current.append(character)
        current.append(chars[index + 1])
        index += 2
      case "|":
        if current.trimmingCharacters(in: .whitespaces).hasSuffix(">") {
          // `>|` is bash's clobber-anyway redirection, not a pipe.
          current.append(character)
          index += 1
        } else if index + 1 < chars.count, chars[index + 1] == "|" {
          endPipeline()
          index += 2
        } else {
          endStage()
          index += 1
        }
      case "&":
        // `2>&1` / `>&2`: the ampersand belongs to the redirection that just opened.
        if current.trimmingCharacters(in: .whitespaces).hasSuffix(">") {
          current.append(character)
          index += 1
        } else if index + 1 < chars.count, chars[index + 1] == "&" {
          endPipeline()
          index += 2
        } else if index + 1 < chars.count, chars[index + 1] == ">" {
          current.append(character)
          index += 1
        } else {
          endPipeline()
          index += 1
        }
      case ";", "\n", "\r":
        endPipeline()
        index += 1
      default:
        current.append(character)
        index += 1
      }
    }
    endPipeline()
    return result
  }

  // MARK: Write targets

  /// How much a single write target raises the risk of the command that writes it.
  enum WriteTargetRisk: Equatable {
    /// Not a file the user cares about (`/dev/null`) — or not resolvable enough to judge.
    case ignored
    /// An ordinary file inside the working tree: prompt like any other mutation.
    case ordinary
    /// Outside the tree, a credential/startup file, or an in-tree protected path.
    case destructive
    /// Harness state. Carries the floor's reason.
    case floor(String)
  }

  /// Programs where `-o`/`--output` names a file to write. Everywhere else `-o` means
  /// something harmless — `ls -o` (long format), `grep -o`/`rg -o` (only-matching),
  /// `find … -o …` (or) — and treating it as a write was a pure false positive.
  static let outputFlagPrograms: Set<String> = [
    "curl", "wget", "sort", "tree", "gcc", "g++", "cc", "clang", "clang++", "swiftc", "swift",
    "ffmpeg", "ld", "javac", "objcopy", "tar", "pandoc", "convert", "openssl", "dot", "as",
  ]

  /// Flags that name an output file for *any* program, in every spelling worth catching.
  static let outputFlagPrefixes: [String] = [
    "--output", "--out-file", "--outfile", "--write-out-file", "--log-file",
  ]

  /// The files this segment would write, in the spelling the model used (unquoted, `~`
  /// still unexpanded — `writeTargetRisk` normalizes). Redirections plus the handful of
  /// programs whose *argument* is the destination.
  static func writeTargets(of segment: String) -> [String] {
    let tokens = shellTokens(segment)
    var targets = redirectTargets(in: tokens)

    // What's left once the redirections are removed is the command itself.
    var command: [String] = []
    var index = 0
    while index < tokens.count {
      if isWriteRedirect(tokens[index]) || isReadRedirect(tokens[index]) {
        index += 2
        continue
      }
      command.append(tokens[index])
      index += 1
    }
    command = shellTokens(stripWrappers(command.joined(separator: " ")))
    guard let program = command.first else { return targets }
    let arguments = Array(command.dropFirst())
    targets.append(contentsOf: programWriteTargets(program: program, arguments: arguments))
    return targets
  }

  /// `>`, `>>`, `>|`, `&>`, `&>>`, `1>`, `2>>` — but not the fd-duplicating `2>&1`/`>&2`.
  static func isWriteRedirect(_ token: String) -> Bool {
    guard token.contains(">") else { return false }
    let head = token.prefix { $0 != ">" }
    guard head.isEmpty || head == "&" || head.allSatisfy(\.isNumber) else { return false }
    return !token.hasSuffix("&")
  }

  static func isReadRedirect(_ token: String) -> Bool {
    token == "<" || token == "<<" || token == "<<<" || token == "<&"
  }

  private static func redirectTargets(in tokens: [String]) -> [String] {
    var targets: [String] = []
    var index = 0
    while index < tokens.count {
      guard isWriteRedirect(tokens[index]) else { index += 1; continue }
      if index + 1 < tokens.count {
        let target = tokens[index + 1]
        // `>&2` and friends: the "target" is a file descriptor, not a file.
        if !(tokens[index].hasSuffix("&") && target.allSatisfy(\.isNumber)) {
          targets.append(target)
        }
      }
      index += 2
    }
    return targets
  }

  /// The destination argument of the programs whose whole job is to put bytes somewhere.
  private static func programWriteTargets(program: String, arguments: [String]) -> [String] {
    var flagTargets: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      if outputFlagPrefixes.contains(where: { argument.hasPrefix($0) }) {
        if let value = argument.split(separator: "=", maxSplits: 1).dropFirst().first {
          flagTargets.append(String(value))
        } else if index + 1 < arguments.count {
          flagTargets.append(arguments[index + 1])
          index += 1
        }
      } else if outputFlagPrograms.contains(program), argument == "-o" || argument == "-O" {
        if index + 1 < arguments.count { flagTargets.append(arguments[index + 1]); index += 1 }
      } else if outputFlagPrograms.contains(program), argument.hasPrefix("-o"), argument.count > 2 {
        flagTargets.append(String(argument.dropFirst(2)))
      }
      index += 1
    }

    let positionals = arguments.filter { !$0.hasPrefix("-") }
    switch program {
    case "tee":
      return flagTargets + positionals
    case "dd":
      return flagTargets + arguments.compactMap { $0.hasPrefix("of=") ? String($0.dropFirst(3)) : nil }
    case "cp", "mv", "install", "rsync", "ln":
      // The destination is the last positional (or `-t`'s value).
      if let slot = arguments.firstIndex(where: { $0 == "-t" || $0 == "--target-directory" }),
         slot + 1 < arguments.count
      {
        return flagTargets + [arguments[slot + 1]]
      }
      guard positionals.count >= 2, let destination = positionals.last else { return flagTargets }
      return flagTargets + [destination]
    case "sed", "gsed", "perl", "ruby":
      // In-place editing rewrites the files it is pointed at. The first positional is the
      // script (`s/a/b/`); it resolves in-tree and classifies harmless, so leaving it in
      // costs nothing and dropping it would be wrong for BSD `sed -i '' …`.
      guard editsInPlace(arguments) else { return flagTargets }
      return flagTargets + positionals.dropFirst()
    case "truncate":
      var files: [String] = []
      var slot = 0
      while slot < arguments.count {
        let argument = arguments[slot]
        if argument == "-s" || argument == "--size" { slot += 2; continue }
        if !argument.hasPrefix("-") { files.append(argument) }
        slot += 1
      }
      return flagTargets + files
    default:
      return flagTargets
    }
  }

  /// The in-place switch of `sed`/`perl`/`ruby`, in the spellings that actually appear:
  /// `-i`, `-i.bak`, `--in-place`, and the clustered `perl -pi -e`. A short flag cluster is
  /// capped at four characters so `ruby -Ilib` isn't read as one.
  static func editsInPlace(_ arguments: [String]) -> Bool {
    arguments.contains { argument in
      if argument == "--in-place" || argument.hasPrefix("--in-place=") { return true }
      guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { return false }
      if argument.hasPrefix("-i") { return true }
      return argument.count <= 4 && argument.dropFirst().contains("i")
    }
  }

  /// Where a write target sits, in the same classification `write_file` uses.
  static func writeTargetRisk(_ raw: String, root: URL?, rules: PathScope.Rules) -> WriteTargetRisk {
    var target = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
    guard !target.isEmpty else { return .ignored }
    // `$HOME` is the one variable worth expanding: it is unambiguous and it is where the
    // startup files live. Everything else with a `$` in it stays a prompt.
    let home = NSHomeDirectory()
    for spelling in ["${HOME}", "$HOME"] where target.hasPrefix(spelling) {
      target = home + String(target.dropFirst(spelling.count))
      break
    }
    if target.hasPrefix("~/") { target = home + String(target.dropFirst(1)) }
    else if target == "~" { target = home }
    // Character devices and the shell's own streams are not files anybody loses.
    if target == "/dev/null" || target.hasPrefix("/dev/std") || target.hasPrefix("/dev/fd/")
      || target == "/dev/tty" || target == "/dev/zero"
    {
      return .ignored
    }
    // Unresolvable: substitution, a remaining variable, or a glob. A prompt, never a floor.
    if target.contains(where: { $0 == "$" || $0 == "`" || $0 == "*" || $0 == "?" }) { return .ordinary }

    switch PathScope.classify(forWriting: target, root: root, rules: rules) {
    case .harness: return .floor("writes a harness or hook file")
    case .sensitive, .outside: return .destructive
    case .inside: return .ordinary
    }
  }

  /// The worst write-target verdict across the whole command.
  static func writeTargetRisk(ofCommand command: String, root: URL?, rules: PathScope.Rules) -> WriteTargetRisk {
    var worst = WriteTargetRisk.ignored
    for stage in pipelines(command).flatMap({ $0 }) {
      for target in writeTargets(of: stage) {
        switch writeTargetRisk(target, root: root, rules: rules) {
        case .floor(let reason): return .floor(reason)
        case .destructive: worst = .destructive
        case .ordinary where worst == .ignored: worst = .ordinary
        default: break
        }
      }
    }
    return worst
  }

  // MARK: Critical-path removal

  /// Directories under which a run is scratch: the risk note's exemption, so `rm -rf .`
  /// inside a panel snapshot or an eval workdir stays an ordinary destructive prompt
  /// instead of hitting a floor it can never get past.
  static let temporaryRoots: [String] = {
    var roots = [
      "/tmp", "/private/tmp", "/var/tmp", "/private/var/tmp",
      "/var/folders", "/private/var/folders", "/dev/shm",
    ]
    roots.append(PathScope.physicalPath(NSTemporaryDirectory()))
    return roots.map { path in
      path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
  }()

  static func isTemporaryLocation(_ resolved: String) -> Bool {
    temporaryRoots.contains { PathScope.isUnder(resolved, base: $0) }
  }

  /// Programs that remove what they are pointed at.
  static let removalPrograms: Set<String> = ["rm", "rmdir", "unlink", "shred", "srm"]

  /// The floor for a removal whose *target* is unrecoverable in a way `protectedRoots`
  /// doesn't already name: the working tree itself (or an ancestor of it), a repository's
  /// entire `.git`, or harness state. Everything else stays `.destructive` — `rm` always
  /// prompts loudly, so a miss here costs a prompt, not data.
  ///
  /// `find` is deliberately not here. Its root argument is a *starting point*, not a target
  /// — `find . -name '*.tmp' -delete` deletes matching files, not the tree — and reading it
  /// as one refused a common cleanup. `find <system-or-home-root> … -delete` is still the
  /// floor; that rule lives in `catastrophicSegment` and is unchanged.
  static func criticalRemovalFloor(_ segment: String, root: URL?, rules: PathScope.Rules) -> String? {
    var tokens = shellTokens(stripWrappers(segment))
    guard let program = tokens.first else { return nil }
    tokens.removeFirst()
    let moves = program == "mv"
    guard removalPrograms.contains(program) || moves else { return nil }

    let (_, _, positionals) = flagsAndPositionals(tokens)
    // `mv`'s destination is a write, not a removal; only its sources vanish.
    let targets = moves ? Array(positionals.dropLast()) : positionals
    let base = PathScope.physicalPath((root ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)).path)

    for raw in targets {
      var target = raw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
      guard !target.isEmpty else { continue }
      let home = NSHomeDirectory()
      for spelling in ["${HOME}", "$HOME"] where target.hasPrefix(spelling) {
        target = home + String(target.dropFirst(spelling.count))
        break
      }
      if target.hasPrefix("~/") { target = home + String(target.dropFirst(1)) }
      if target.contains(where: { $0 == "$" || $0 == "`" }) { continue }
      // Harness state: the same refusal `write_file` makes, for the same reason — an agent
      // that can delete `~/.arnes` deletes the rules and hooks it is judged by.
      if !target.contains("*"), PathScope.isHarness(target, root: root, rules: rules) {
        return "deletes the harness's own state"
      }
      guard !target.contains(where: { $0 == "*" || $0 == "?" }) else { continue }
      let resolved = PathScope.physicalPath(resolveToolPath(target, root: root))
      // The whole working tree, or something it lives under.
      if PathScope.isUnder(base, base: resolved), !isTemporaryLocation(base) {
        return resolved == base
          ? "deletes the entire working directory"
          : "deletes a directory the working tree lives under"
      }
      // A repository's whole history. `.git/hooks/x` is a file; `.git` is everything.
      if URL(fileURLWithPath: resolved).lastPathComponent == ".git", isDirectory(resolved) {
        return "deletes a git repository's entire history"
      }
    }
    return nil
  }

  private static func isDirectory(_ path: String) -> Bool {
    var isDirectory: ObjCBool = false
    return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
  }

  // MARK: Interpreters

  /// Programs that execute whatever reaches them — on stdin, or as a `-c`/`-e` string.
  static let interpreterSinks: Set<String> = [
    "sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh",
    "python", "python2", "python3", "ruby", "perl", "php", "node", "nodejs", "deno", "bun",
    "osascript", "Rscript",
  ]

  static let shellInterpreters: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh", "eval"]

  /// The inner command of `sh -c "…"` / `eval …` — a shell string we can classify with the
  /// same rules, so `bash -c "rm -rf /"` is exactly as refused as `rm -rf /`.
  ///
  /// Only a *plain literal* comes back — one with no command substitution in it, since a
  /// `$(…)` or a backtick is a second command we can't see. A plain `$VAR` is kept: the
  /// classifiers already know what `rm -rf $HOME` means and treat every other variable
  /// conservatively. Recursion is escalate-only, so an inner command we can't read lands on
  /// `.ordinary` — a prompt — which is the safe end.
  static func innerShellCommands(of segment: String) -> [String] {
    let tokens = shellTokens(stripWrappers(segment))
    guard let program = tokens.first, shellInterpreters.contains(program) else { return [] }
    let arguments = Array(tokens.dropFirst())
    func usable(_ inner: String) -> [String] {
      inner.isEmpty || inner.contains("$(") || inner.contains("`") ? [] : [inner]
    }
    if program == "eval" { return usable(arguments.joined(separator: " ")) }
    guard let slot = arguments.firstIndex(where: { $0 == "-c" || $0 == "-lc" || $0 == "-ic" }),
          slot + 1 < arguments.count
    else { return [] }
    return usable(arguments[slot + 1])
  }

  /// Markers that a non-shell interpreter's inline script deletes things. Deliberately a
  /// short, literal list — the point is `python -c "shutil.rmtree('/')"`, not a Python
  /// parser; anything subtler is the `CommandJudge`'s long tail, not the classifier's.
  static let scriptDeletionMarkers: [String] = [
    "shutil.rmtree", "rmtree(", "os.remove", "os.unlink", "os.rmdir", "pathlib.Path.unlink",
    "fs.rm", "fs.unlink", "fs.rmdir", "rimraf", "File.delete", "FileUtils.rm", "unlink(",
    "rm -rf", "rm -fr",
  ]

  /// True when a non-shell interpreter is handed an inline script that deletes.
  static func inlineScriptDeletes(_ segment: String) -> Bool {
    let tokens = shellTokens(stripWrappers(segment))
    guard let program = tokens.first, interpreterSinks.contains(program), !shellInterpreters.contains(program)
    else { return false }
    let arguments = Array(tokens.dropFirst())
    guard let slot = arguments.firstIndex(where: { $0 == "-c" || $0 == "-e" || $0 == "--eval" }),
          slot + 1 < arguments.count
    else { return false }
    let script = arguments[slot + 1]
    return scriptDeletionMarkers.contains { script.contains($0) }
  }

  /// The stages of `command` that feed an interpreter through a pipe, paired with the stage
  /// that produced the bytes. `curl … | sh` is the famous one and is already the floor;
  /// this catches the rest (`cat payload | sh`, `base64 -d | python3`), which is
  /// `.destructive` — code from a file the model just wrote is still code it chose to run.
  static func pipedInterpreterSources(_ command: String) -> [(source: String, sink: String)] {
    var found: [(String, String)] = []
    for pipeline in pipelines(command) where pipeline.count >= 2 {
      for (index, stage) in pipeline.enumerated() where index > 0 {
        let tokens = shellTokens(stripWrappers(stage))
        guard let program = tokens.first, interpreterSinks.contains(program) else { continue }
        // `python script.py` reading a pipe is still just running `script.py`; only an
        // interpreter with no script argument executes what arrives on stdin.
        let positionals = tokens.dropFirst().filter { !$0.hasPrefix("-") }
        guard positionals.isEmpty else { continue }
        found.append((pipeline[index - 1], stage))
      }
    }
    return found
  }

  /// `echo 'literal' | sh` is knowable: the literal *is* the command, so classify it
  /// instead of guessing. Returns nil when the source isn't a plain literal echo.
  static func literalPipeSource(_ stage: String) -> String? {
    guard !stage.contains("$"), !stage.contains("`") else { return nil }
    let tokens = shellTokens(stripWrappers(stage))
    guard let program = tokens.first, program == "echo" || program == "printf" else { return nil }
    let words = tokens.dropFirst().filter { !$0.hasPrefix("-") }
    return words.isEmpty ? nil : words.joined(separator: " ")
  }

  /// Strips `xargs` and its option arguments, leaving the program it will actually run —
  /// so `… | xargs rm` is as destructive as `rm`, and `… | xargs -0 -n1 git push` as
  /// destructive as the push.
  static func xargsPayload(_ segment: String) -> String? {
    var tokens = shellTokens(stripWrappers(segment))
    guard tokens.first == "xargs" else { return nil }
    tokens.removeFirst()
    let valueFlags: Set<String> = ["-n", "-I", "-i", "-P", "-L", "-s", "-d", "-E", "-a", "--max-args",
                                   "--replace", "--max-procs", "--max-lines", "--delimiter", "--arg-file"]
    while let first = tokens.first, first.hasPrefix("-") {
      tokens.removeFirst()
      if valueFlags.contains(first), !tokens.isEmpty { tokens.removeFirst() }
    }
    return tokens.isEmpty ? nil : tokens.joined(separator: " ")
  }
}
