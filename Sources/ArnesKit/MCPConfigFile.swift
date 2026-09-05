import Foundation
import OpenRouterSwift

// MARK: - MCPSetupError

/// Why `arnes mcp add`/`add-json`/`remove` refused an edit (X9). Every case is phrased for the
/// terminal: what was wrong and what to write instead.
public enum MCPSetupError: Error, CustomStringConvertible, Sendable, Equatable {
  /// The server name is not `MCPEntryValidation.nameRule`.
  case invalidName(String)
  /// Not exactly one of `command` / `url`, or a `type` that contradicts the field present.
  case transport(String)
  /// The `url` failed the outbound URL policy (https, or http to loopback / `insecure`).
  case url(String)
  /// An `env`/`headers` value that looks like a literal secret. `key` names the variable or
  /// header, `suggested` the `${NAME}` template to write instead.
  case literalSecret(key: String, suggested: String)
  /// The entry does not decode as an MCP server config (a bad `add-json`).
  case invalidEntry(String)
  /// The file being edited does not parse — it is never rewritten.
  case unreadableFile(path: String, detail: String)

  public var description: String {
    switch self {
    case .invalidName(let name):
      return "invalid server name '\(name)' — \(MCPEntryValidation.nameRule)"
    case .transport(let detail):
      return detail
    case .url(let detail):
      return detail
    case .literalSecret(let key, let suggested):
      return "value for \(key) looks like a secret — write \"\(suggested)\" and export it instead "
        + "(arnes expands ${NAME} from the environment at connect time); --allow-literal writes it "
        + "anyway (0600, this machine only)"
    case .invalidEntry(let detail):
      return "not a valid MCP server entry: \(detail)"
    case .unreadableFile(let path, let detail):
      return "\(path) does not parse and was left alone: \(detail)"
    }
  }
}

// MARK: - MCPConfigFile

/// An MCP config file as a **JSON tree**, so an edit keeps every key arnes doesn't model (a
/// future `type`, a `_note`) — a decoded `MCPServerConfig` round-trip would drop them. Key
/// order is *not* preserved: `save` writes sorted keys, pretty-printed, 0600 in a 0700 directory.
public struct MCPConfigFile: Sendable, Equatable {
  public static let serversKey = "mcpServers"

  /// The whole document; always an object with an `mcpServers` object.
  public var root: [String: JSONValue]

  public init(root: [String: JSONValue] = [Self.serversKey: .object([:])]) {
    var root = root
    if root[Self.serversKey]?.objectValue == nil { root[Self.serversKey] = .object([:]) }
    self.root = root
  }

  /// The file at `url`, or an empty document when there is none. A file that does not parse as a
  /// JSON object throws `MCPSetupError.unreadableFile` — never clobber a broken file.
  public static func load(_ url: URL) throws -> MCPConfigFile {
    guard FileManager.default.fileExists(atPath: url.path) else { return MCPConfigFile() }
    let data = try Data(contentsOf: url)
    do {
      let value = try JSONDecoder().decode(JSONValue.self, from: data)
      guard let object = value.objectValue else {
        throw MCPSetupError.unreadableFile(path: url.path, detail: "the top level is not an object")
      }
      guard object[serversKey] == nil || object[serversKey]?.objectValue != nil else {
        throw MCPSetupError.unreadableFile(path: url.path, detail: "\"\(serversKey)\" is not an object")
      }
      return MCPConfigFile(root: object)
    } catch let error as MCPSetupError {
      throw error
    } catch {
      throw MCPSetupError.unreadableFile(path: url.path, detail: "\(error)")
    }
  }

  public var servers: [String: JSONValue] {
    root[Self.serversKey]?.objectValue ?? [:]
  }

  public func entry(named name: String) -> JSONValue? {
    servers[name]
  }

  /// Sets `name` to `entry`; true when an entry of that name was replaced.
  @discardableResult
  public mutating func upsert(name: String, entry: JSONValue) -> Bool {
    var servers = self.servers
    let replaced = servers[name] != nil
    servers[name] = entry
    root[Self.serversKey] = .object(servers)
    return replaced
  }

  /// Removes `name`; false when it was not there.
  @discardableResult
  public mutating func remove(name: String) -> Bool {
    var servers = self.servers
    guard servers.removeValue(forKey: name) != nil else { return false }
    root[Self.serversKey] = .object(servers)
    return true
  }

  /// The document as `save` writes it: sorted keys, pretty-printed, a trailing newline.
  public func encoded() throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    var data = try encoder.encode(JSONValue.object(root))
    data.append(0x0A)
    return data
  }

  /// Atomic, 0600, the directory 0700 (`SecureFiles.writePrivate`).
  public func save(to url: URL) throws {
    try SecureFiles.writePrivate(try encoded(), to: url)
  }
}

// MARK: - MCPEntryValidation

/// The rules an entry must pass before `arnes mcp add` writes it (X9): a name the tool-name
/// scheme can carry, exactly one transport, a URL the outbound policy accepts, and no literal
/// secret in `env`/`headers` unless the user said `--allow-literal`.
public enum MCPEntryValidation {
  /// The name rule, quoted by the refusal.
  public static let nameRule =
    "a name is 1–64 characters of letters, digits, `_` or `-`, starts with a letter or digit, and "
    + "never contains `__` (the separator in mcp__<server>__<tool>)"

  /// What a validated entry carries back: the decoded config and the non-refusing findings.
  public struct Validated: Sendable {
    public let config: MCPServerConfig
    /// Non-fatal: a stdio command that doesn't resolve on PATH right now (`npx`-style commands
    /// resolve at run time), a `type` that repeats what the fields already say.
    public let warnings: [String]
  }

  public static func isValidName(_ name: String) -> Bool {
    guard (1...64).contains(name.count), !name.contains("__") else { return false }
    guard let first = name.unicodeScalars.first, isAlphanumeric(first) else { return false }
    return name.unicodeScalars.allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "-" }
  }

  private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
    (scalar >= "a" && scalar <= "z") || (scalar >= "A" && scalar <= "Z") || (scalar >= "0" && scalar <= "9")
  }

  /// `${NAME}` anywhere in the value — a template arnes expands from the environment at connect
  /// time. `Bearer ${TOKEN}` counts; a literal never does.
  public static func isTemplate(_ value: String) -> Bool {
    guard let open = value.range(of: "${") else { return false }
    return value[open.upperBound...].contains("}")
  }

  /// Header names whose value is a credential by convention: `Authorization`, `*-Key`, `*-Token`,
  /// `*-Secret`, `Cookie`. Case-insensitive.
  public static func isCredentialHeader(_ name: String) -> Bool {
    let lower = name.lowercased()
    return lower == "authorization" || lower == "proxy-authorization" || lower == "cookie"
      || lower.hasSuffix("-key") || lower.hasSuffix("-token") || lower.hasSuffix("-secret")
      || lower.hasSuffix("_key") || lower.hasSuffix("_token") || lower.hasSuffix("_secret")
  }

  /// Whether `value` for `key` reads as a literal secret: not a template, and either the header
  /// name is a credential carrier or the `key=value` pair matches a `SecretScrubber` shape (a
  /// vendor-prefixed token, a PEM block, a JWT, a `TOKEN=…` assignment with a real value).
  public static func looksLikeSecret(key: String, value: String, header: Bool) -> Bool {
    guard !isTemplate(value), !value.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    if header, isCredentialHeader(key) { return true }
    let probe = header ? "\(key): \(value)" : "\(key)=\(value)"
    return !SecretScrubber.scrub(probe).redactions.isEmpty
  }

  /// The `${NAME}` a refusal suggests for `key`: uppercased, `-`/spaces → `_`, other characters dropped.
  public static func suggestedTemplate(for key: String) -> String {
    var name = ""
    for scalar in key.uppercased().unicodeScalars {
      if isAlphanumeric(scalar) || scalar == "_" { name.unicodeScalars.append(scalar) }
      else if scalar == "-" || scalar == " " || scalar == "." { name.append("_") }
    }
    if name.isEmpty || (name.unicodeScalars.first.map { $0 >= "0" && $0 <= "9" } ?? false) {
      name = "MCP_" + name
    }
    return "${\(name)}"
  }

  /// Validates `entry` for `name`. Throws `MCPSetupError` on a refusal; `commandResolves` (nil =
  /// don't check) turns an unresolvable stdio command into a warning, never a refusal.
  public static func validate(
    name: String,
    entry: JSONValue,
    allowLiteral: Bool = false,
    commandResolves: ((String) -> Bool)? = nil)
    throws -> Validated
  {
    guard isValidName(name) else { throw MCPSetupError.invalidName(name) }
    guard entry.objectValue != nil else { throw MCPSetupError.invalidEntry("the entry must be a JSON object") }
    let config: MCPServerConfig
    do {
      config = try JSONDecoder().decode(MCPServerConfig.self, from: JSONEncoder().encode(entry))
    } catch {
      throw MCPSetupError.invalidEntry("\(error)")
    }
    var warnings: [String] = []
    let hasCommand = !(config.command ?? "").isEmpty
    let hasURL = !(config.url ?? "").isEmpty
    switch (hasCommand, hasURL) {
    case (true, true):
      throw MCPSetupError.transport("an entry is either stdio (command) or http (url), not both")
    case (false, false):
      throw MCPSetupError.transport("an entry needs a command (stdio) or a url (http)")
    case (true, false):
      if config.transport == .http {
        throw MCPSetupError.transport("type \"\(config.type ?? "")\" is http but the entry has a command and no url")
      }
      if let resolves = commandResolves, let command = config.command, !resolves(command) {
        warnings.append(
          "`\(command)` is not on PATH right now — fine if it is installed later or resolves at run time")
      }
    case (false, true):
      if config.transport == .stdio, let type = config.type, !type.isEmpty {
        throw MCPSetupError.transport("type \"\(type)\" is stdio but the entry has a url and no command")
      }
      do {
        _ = try URLPolicy(insecure: config.insecure ?? false).validate(string: config.url ?? "")
      } catch {
        throw MCPSetupError.url("\(error) — use https, or --insecure for a trusted plain-http host")
      }
    }
    if !allowLiteral {
      for (key, value) in (config.env ?? [:]).sorted(by: { $0.key < $1.key })
      where looksLikeSecret(key: key, value: value, header: false) {
        throw MCPSetupError.literalSecret(key: key, suggested: suggestedTemplate(for: key))
      }
      for (key, value) in (config.headers ?? [:]).sorted(by: { $0.key < $1.key })
      where looksLikeSecret(key: key, value: value, header: true) {
        throw MCPSetupError.literalSecret(key: "header \(key)", suggested: suggestedTemplate(for: key))
      }
    }
    return Validated(config: config, warnings: warnings)
  }
}
