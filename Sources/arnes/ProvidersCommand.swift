import ArgumentParser
import ArnesKit
import Foundation

/// `arnes providers` — the provider table from ~/.arnes/config.json (plus the built-in
/// openrouter entry), which one is active, and whether each resolves: key found, base
/// URL valid, default model set. No network.
struct Providers: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    abstract: "List configured providers and which one is active (no network).",
    discussion: """
      Providers live in ~/.arnes/config.json (ARNES_CONFIG overrides the path):

        {
          "provider": "gateway",
          "providers": {
            "gateway": {
              "kind": "litellm",
              "baseURL": "https://llm-gateway.example.com/v1",
              "apiKeyEnv": "GATEWAY_TOKEN",
              "headersEnv": "GATEWAY_HEADERS",
              "defaultModel": "claude-sonnet-4-5"
            }
          }
        }

      kind is openrouter, litellm, or openai-compatible. Pick one per run with
      --provider <name> or ARNES_PROVIDER; ARNES_BASE_URL / ARNES_API_KEY /
      ARNES_DEFAULT_MODEL override the active entry for one run.
      """)

  @Flag(help: "Print one JSON array of {name, kind, active, resolves, key_source, base_host, default_model, error, reasoning_shape} rows instead of text.")
  var json = false

  func run() throws {
    let configURL = ArnesConfig.defaultURL
    let config: ArnesConfig?
    do {
      config = try ArnesConfig.load(from: configURL)
    } catch {
      throw ValidationError("\(configURL.path) is invalid: \(error)")
    }
    let active = ProviderResolver.activeName(config: config)
    let providers = (config ?? ArnesConfig()).allProviders
    if json {
      try JSONOut.print(Self.rows(providers, active: active))
      return
    }
    for (name, entry) in providers.sorted(by: { $0.key < $1.key }) {
      let mark = name == active ? ANSI.green("●") : ANSI.dim("○")
      let title = "\(mark) \(ANSI.bold(name))  \(ANSI.dim(entry.kind.rawValue))"
      do {
        let resolved = try ProviderResolver.resolve(name: name, entry: entry)
        print(TerminalText.sanitize(
          "\(title)  \(resolved.endpointDescription)  "
            + ANSI.dim("default \(resolved.defaultModel ?? "— (pass -m, or set defaultModel)") · key from \(resolved.apiKeySource)\(Self.reasoningTag(entry))")))
      } catch {
        print(TerminalText.sanitize("\(title)  \(entry.baseURL)  " + ANSI.yellow("⚠ \(error)")))
      }
    }
    let source = config == nil ? "no config file (built-in openrouter only)" : configURL.path
    print(ANSI.dim("\nactive: \(active) · \(source) · switch with --provider <name> or ARNES_PROVIDER"))
  }

  /// `arnes providers --json`: one row per entry, sorted by name, resolved the way the text
  /// view resolves each — offline. `environment`/`credentialsURL` are injectable for tests.
  static func rows(
    _ providers: [String: ProviderConfig],
    active: String,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    credentialsURL: URL = ProviderResolver.defaultCredentialsURL)
    -> [ProviderRow]
  {
    providers.sorted(by: { $0.key < $1.key }).map { name, entry in
      do {
        let resolved = try ProviderResolver.resolve(
          name: name, entry: entry, environment: environment, credentialsURL: credentialsURL)
        var host = resolved.baseURL.host ?? ""
        if let port = resolved.baseURL.port { host += ":\(port)" }
        return ProviderRow(
          name: name, kind: entry.kind.rawValue, active: name == active, resolves: true,
          keySource: resolved.apiKeySource, baseHost: host, defaultModel: resolved.defaultModel,
          error: nil, reasoningShape: resolved.traits.reasoningShape.rawValue)
      } catch {
        return ProviderRow(
          name: name, kind: entry.kind.rawValue, active: name == active, resolves: false,
          keySource: nil, baseHost: URL(string: entry.baseURL)?.host, defaultModel: entry.defaultModel,
          error: "\(error)", reasoningShape: Self.reasoningShape(of: entry).rawValue)
      }
    }
  }

  /// The reasoning-dial spelling an entry's chat requests use: its `reasoningShape` override,
  /// else the kind's default — the same rule `ResolvedProvider.traits` applies, answered
  /// without resolving (a row whose key is missing still says how it would speak).
  static func reasoningShape(of entry: ProviderConfig) -> ReasoningShape {
    entry.reasoningShape ?? ReasoningShape.forKind(entry.kind)
  }

  /// The text listing's ` · reasoning <shape>` tail — only when the entry overrides its kind's
  /// default spelling, so a listing without overrides prints exactly what it always did.
  static func reasoningTag(_ entry: ProviderConfig) -> String {
    guard let shape = entry.reasoningShape, shape != ReasoningShape.forKind(entry.kind) else { return "" }
    return " · reasoning \(shape.rawValue)"
  }
}
