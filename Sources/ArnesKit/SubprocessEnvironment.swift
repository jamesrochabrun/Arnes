import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - ShellEnvironmentPolicy

/// What child processes launched on the agent's behalf — `bash` commands and lifecycle
/// hooks — may see of the parent's environment. `shellEnvironment` in
/// `~/.arnes/config.json`; the same shape Codex calls `shell_environment_policy`.
///
/// Whatever the policy says, Arnes's own provider tokens are withheld (see
/// `SubprocessEnvironment.providerTokenKeys`): the agent never legitimately needs the key
/// that pays for it, and under `--yes` a prompt-injected `echo $OPENROUTER_API_KEY` is
/// the shortest exfiltration there is.
public struct ShellEnvironmentPolicy: Codable, Sendable, Equatable {
  public enum Inherit: String, Codable, Sendable {
    /// The whole parent environment (default).
    case all
    /// Only the variables a shell needs to function: HOME, PATH, USER, SHELL, TERM,
    /// LANG/LC_*, TMPDIR, TZ, XDG_*.
    case core
    /// Nothing from the parent; only `set` values. (Spelled `empty` rather than `none`
    /// so it can't be confused with `Optional.none` at the call site; the JSON value
    /// stays `"none"`.)
    case empty = "none"
  }

  public var inherit: Inherit?
  /// Variable-name patterns to drop (shell glob, case-insensitive): `"AWS_*"`, `"*_TOKEN"`.
  public var exclude: [String]?
  /// Drop anything whose name looks like a secret — `*KEY*`, `*SECRET*`, `*TOKEN*`,
  /// `*PASSWORD*`, `*CREDENTIAL*` — the way Codex does by default. Off by default here
  /// because it also hides `GITHUB_TOKEN` from `gh` and `NPM_TOKEN` from `npm`; turn it
  /// on for unattended runs.
  public var excludeSecrets: Bool?
  /// When set, only variables matching one of these patterns survive (applied after the
  /// exclusions).
  public var includeOnly: [String]?
  /// Variables added last, verbatim. `${NAME}` expands from the parent environment — the
  /// one deliberate way to pass a redacted variable through.
  public var set: [String: String]?

  public init(
    inherit: Inherit? = nil,
    exclude: [String]? = nil,
    excludeSecrets: Bool? = nil,
    includeOnly: [String]? = nil,
    set: [String: String]? = nil)
  {
    self.inherit = inherit
    self.exclude = exclude
    self.excludeSecrets = excludeSecrets
    self.includeOnly = includeOnly
    self.set = set
  }

  static let corePatterns = [
    "HOME", "PATH", "USER", "LOGNAME", "SHELL", "TERM", "LANG", "LC_*", "TMPDIR", "TZ", "PWD", "XDG_*",
  ]

  static let secretPatterns = ["*KEY*", "*SECRET*", "*TOKEN*", "*PASSWORD*", "*PASSWD*", "*CREDENTIAL*"]

  static func matches(_ name: String, _ patterns: [String]) -> Bool {
    patterns.contains { fnmatch($0.uppercased(), name.uppercased(), 0) == 0 }
  }
}

// MARK: - SubprocessEnvironment

/// A policy plus the variables that are withheld no matter what. `Session.tools(...)`,
/// `BashTool`, and `HookEngine` take one; the CLI builds it from the config and the
/// active provider's `apiKeyEnv`.
public struct SubprocessEnvironment: Sendable, Equatable {
  /// The names Arnes's provider tokens travel under. Always redacted from bash, hooks,
  /// and MCP servers (a server config's `env` may pass one through via `${NAME}`).
  public static let providerTokenKeys: Set<String> = [
    "OPENROUTER_API_KEY", "ARNES_API_KEY", "LITELLM_API_KEY",
  ]

  public var policy: ShellEnvironmentPolicy
  public var redactedKeys: Set<String>

  public init(policy: ShellEnvironmentPolicy = ShellEnvironmentPolicy(), redactedKeys: Set<String> = providerTokenKeys) {
    self.policy = policy
    self.redactedKeys = redactedKeys.union(Self.providerTokenKeys)
  }

  /// Inherit everything except the provider tokens — what every run did implicitly for
  /// MCP servers, now for bash and hooks too.
  public static let `default` = SubprocessEnvironment()

  /// The child's environment.
  public func resolve(inheriting parent: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
    var environment: [String: String]
    switch policy.inherit ?? .all {
    case .all:
      environment = parent
    case .core:
      environment = parent.filter { ShellEnvironmentPolicy.matches($0.key, ShellEnvironmentPolicy.corePatterns) }
    case .empty:
      environment = [:]
    }
    for key in redactedKeys {
      environment.removeValue(forKey: key)
    }
    if let exclude = policy.exclude, !exclude.isEmpty {
      environment = environment.filter { !ShellEnvironmentPolicy.matches($0.key, exclude) }
    }
    if policy.excludeSecrets == true {
      environment = environment.filter { !ShellEnvironmentPolicy.matches($0.key, ShellEnvironmentPolicy.secretPatterns) }
    }
    if let includeOnly = policy.includeOnly, !includeOnly.isEmpty {
      environment = environment.filter { ShellEnvironmentPolicy.matches($0.key, includeOnly) }
    }
    for (key, value) in policy.set ?? [:] {
      environment[key] = VariableExpansion.expand(value, environment: parent)
    }
    return environment
  }

  /// What a `bash` command or hook actually inherits, in one line — `arnes status` prints
  /// it so "is my key really withheld?" has an answer that doesn't require running a
  /// command to find out.
  public var summary: String {
    var parts: [String] = []
    switch policy.inherit ?? .all {
    case .all: parts.append("inherits the environment")
    case .core: parts.append("inherits core variables only (HOME, PATH, SHELL, LANG, TMPDIR, …)")
    case .empty: parts.append("inherits nothing")
    }
    parts.append("withheld: " + redactedKeys.sorted().joined(separator: ", "))
    if let exclude = policy.exclude, !exclude.isEmpty {
      parts.append("excluded: " + exclude.joined(separator: ", "))
    }
    if policy.excludeSecrets == true {
      parts.append("secret-looking names dropped ("
        + ShellEnvironmentPolicy.secretPatterns.joined(separator: ", ") + ")")
    }
    if let includeOnly = policy.includeOnly, !includeOnly.isEmpty {
      parts.append("only: " + includeOnly.joined(separator: ", "))
    }
    if let set = policy.set, !set.isEmpty {
      parts.append("set: " + set.keys.sorted().joined(separator: ", "))
    }
    return parts.joined(separator: " · ")
  }
}
