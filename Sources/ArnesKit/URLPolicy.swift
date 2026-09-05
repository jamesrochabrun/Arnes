import Foundation

// MARK: - URLPolicy

/// The one place that decides whether Arnes may contact a URL.
///
/// Three rules, each about not handing a secret — or a request originating inside the
/// user's network — to somewhere it was never meant to go:
///
/// 1. **Scheme.** `https`, always. Plain `http` only to a loopback host (a gateway or an
///    MCP server on this machine) or when the config entry opts in with `insecure: true`
///    for a trusted network. Everything else (`file`, `ftp`, `data`, …) is refused.
/// 2. **Address.** Private, link-local, and cloud-metadata addresses are refused when
///    `refusePrivateAddresses` is on — the SSRF guard for URLs the *model* picked. The
///    configured-infrastructure callers (the provider gateway, a configured MCP server)
///    leave it off: the user named that host on purpose.
/// 3. **Redirects.** A redirect to another host is never followed. The credentials on the
///    request were minted for the host the user configured; a `302` must not move them.
///
/// The address check reads literals out of the URL — it does not resolve DNS, so a name
/// that resolves into a private range still passes. Callers that need that (a fetch tool
/// handed an arbitrary URL) resolve the host themselves and ask `isPrivateOrReserved`
/// about each address; this type is the shared vocabulary, not a resolver.
public struct URLPolicy: Sendable, Equatable {
  /// Allow plain `http` to any host, and (with `refusePrivateAddresses`) private
  /// addresses. The `insecure: true` escape hatch, spelled the same as `ProviderConfig`.
  public var insecure: Bool
  /// Refuse private, loopback, link-local, and metadata addresses. Off for configured
  /// infrastructure; on for URLs that arrive from a model or a web page.
  public var refusePrivateAddresses: Bool

  public init(insecure: Bool = false, refusePrivateAddresses: Bool = false) {
    self.insecure = insecure
    self.refusePrivateAddresses = refusePrivateAddresses
  }

  /// Configured infrastructure: https, or http to loopback.
  public static let `default` = URLPolicy()
  /// Model-chosen URLs: https only, and never into the private network.
  public static let strict = URLPolicy(refusePrivateAddresses: true)

  // MARK: Failure

  public enum Failure: Error, CustomStringConvertible, Sendable, Equatable {
    case invalidURL(String)
    case unsupportedScheme(url: String, scheme: String)
    /// `http://` to a non-loopback host without `insecure: true`.
    case insecureScheme(String)
    case privateAddress(url: String, host: String)
    case redirectedToAnotherHost(from: String, to: String)
    case tooManyRedirects(String)

    public var description: String {
      switch self {
      case .invalidURL(let raw):
        return "invalid URL '\(raw)' — expected e.g. https://host/path"
      case .unsupportedScheme(let url, let scheme):
        return "refusing to contact \(url) — the \(scheme) scheme is not supported (use https)"
      case .insecureScheme(let url):
        return "refusing to send credentials over plain http to \(url) — use https, or set \"insecure\": true for a trusted network"
      case .privateAddress(let url, let host):
        return "refusing to contact \(url) — \(host) is a private, loopback, or link-local address"
      case .redirectedToAnotherHost(let from, let to):
        return "refusing the redirect from \(from) to \(to) — credentials are not followed to another host"
      case .tooManyRedirects(let url):
        return "too many redirects from \(url)"
      }
    }
  }

  // MARK: Checks

  /// Throws unless `url` may be contacted under this policy.
  public func validate(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased(), let host = Self.host(of: url), !host.isEmpty else {
      throw Failure.invalidURL(url.absoluteString)
    }
    switch scheme {
    case "https":
      break
    case "http":
      guard insecure || Self.isLoopback(host) else {
        throw Failure.insecureScheme(url.absoluteString)
      }
    default:
      throw Failure.unsupportedScheme(url: url.absoluteString, scheme: scheme)
    }
    if refusePrivateAddresses, !insecure, Self.isPrivateOrReserved(host) {
      throw Failure.privateAddress(url: url.absoluteString, host: host)
    }
  }

  /// Parses and validates in one step, so callers never hold an unchecked `URL`.
  @discardableResult
  public func validate(string raw: String) throws -> URL {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), url.scheme != nil else {
      throw Failure.invalidURL(raw)
    }
    try validate(url)
    return url
  }

  /// Resolves a `Location` header against the request it answered and validates the
  /// result. A different host — the DNS-rebinding / token-theft move — is refused.
  public func redirect(from origin: URL, to location: String) throws -> URL {
    guard let target = URL(string: location, relativeTo: origin)?.absoluteURL else {
      throw Failure.invalidURL(location)
    }
    let originHost = Self.host(of: origin) ?? ""
    let targetHost = Self.host(of: target) ?? ""
    guard originHost.caseInsensitiveCompare(targetHost) == .orderedSame else {
      throw Failure.redirectedToAnotherHost(from: origin.absoluteString, to: target.absoluteString)
    }
    try validate(target)
    return target
  }

  // MARK: Hosts

  /// The host without IPv6 brackets — `URL.host` already strips them on most paths, but
  /// a string-built URL can keep them.
  public static func host(of url: URL) -> String? {
    guard var host = url.host, !host.isEmpty else { return nil }
    if host.hasPrefix("["), host.hasSuffix("]") {
      host = String(host.dropFirst().dropLast())
    }
    return host
  }

  public static func isLoopback(_ host: String) -> Bool {
    let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if lowered == "localhost" || lowered.hasSuffix(".localhost") { return true }
    if lowered == "::1" { return true }
    if let v4 = ipv4(lowered) { return v4.0 == 127 }
    if let v4 = mappedIPv4(lowered) { return v4.0 == 127 }
    // Textual 127.* that isn't a well-formed dotted quad ("127.1") still means loopback.
    return lowered.hasPrefix("127.")
  }

  /// Private RFC 1918 space, loopback, link-local (including the 169.254.169.254 cloud
  /// metadata address), CGNAT, multicast/reserved, and the hostnames that name them.
  public static func isPrivateOrReserved(_ host: String) -> Bool {
    let lowered = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    if lowered.isEmpty { return true }
    if isLoopback(lowered) { return true }
    // Names that only ever resolve inside a machine or a cloud tenancy.
    if lowered.hasSuffix(".local") || lowered == "local" { return true }
    if lowered == "metadata.google.internal" || lowered.hasSuffix(".metadata.google.internal") {
      return true
    }
    if let (a, b, _, _) = ipv4(lowered) ?? mappedIPv4(lowered) {
      switch a {
      case 0, 10, 127: return true
      case 100: return (64...127).contains(b) // 100.64.0.0/10, carrier-grade NAT
      case 169: return b == 254 // link-local, and the metadata address
      case 172: return (16...31).contains(b)
      case 192: return b == 168 || b == 0 // 192.0.0.0/24 is IETF protocol assignments
      case 198: return b == 18 || b == 19 // benchmarking
      case 224...255: return true // multicast + reserved, 255.255.255.255 included
      default: return false
      }
    }
    if lowered.contains(":") {
      if lowered == "::" { return true }
      // fc00::/7 unique-local, fe80::/10 link-local.
      let prefix = lowered.prefix(4).lowercased()
      if prefix.hasPrefix("fc") || prefix.hasPrefix("fd") { return true }
      if prefix.hasPrefix("fe8") || prefix.hasPrefix("fe9") || prefix.hasPrefix("fea")
        || prefix.hasPrefix("feb")
      {
        return true
      }
    }
    return false
  }

  /// A dotted-quad literal, or nil for anything else (including hostnames).
  static func ipv4(_ host: String) -> (Int, Int, Int, Int)? {
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 4 else { return nil }
    let numbers = parts.compactMap { Int($0) }
    guard numbers.count == 4, numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
    return (numbers[0], numbers[1], numbers[2], numbers[3])
  }

  /// `::ffff:10.0.0.1` — an IPv4 address wearing an IPv6 coat.
  static func mappedIPv4(_ host: String) -> (Int, Int, Int, Int)? {
    guard host.contains(":"), let last = host.split(separator: ":").last else { return nil }
    return ipv4(String(last))
  }
}
