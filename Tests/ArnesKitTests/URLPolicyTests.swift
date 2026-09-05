import Foundation
import XCTest
@testable import ArnesKit

final class URLPolicyTests: XCTestCase {

  private func failure(_ policy: URLPolicy, _ raw: String) -> URLPolicy.Failure? {
    do {
      try policy.validate(string: raw)
      return nil
    } catch let error as URLPolicy.Failure {
      return error
    } catch {
      return nil
    }
  }

  // MARK: Scheme

  func testHTTPSAlwaysAllowedAndOtherSchemesRefused() {
    XCTAssertNil(failure(.default, "https://mcp.example.com/mcp"))
    XCTAssertNil(failure(.default, "https://mcp.example.com:8443/mcp?x=1"))
    XCTAssertEqual(
      failure(.default, "ftp://mcp.example.com/mcp"),
      .unsupportedScheme(url: "ftp://mcp.example.com/mcp", scheme: "ftp"))
    // No host at all, and a string that isn't a URL.
    XCTAssertEqual(failure(.default, "file:///etc/passwd"), .invalidURL("file:///etc/passwd"))
    XCTAssertEqual(failure(.default, "not a url"), .invalidURL("not a url"))
  }

  func testPlainHTTPOnlyToLoopbackUnlessInsecure() {
    for loopback in [
      "http://localhost:4000/v1",
      "http://dev.localhost/mcp",
      "http://127.0.0.1:9000/mcp",
      "http://127.1/mcp",
      "http://[::1]:9000/mcp",
    ] {
      XCTAssertNil(failure(.default, loopback), "\(loopback) is loopback")
    }
    XCTAssertEqual(
      failure(.default, "http://mcp.example.com/mcp"),
      .insecureScheme("http://mcp.example.com/mcp"))
    XCTAssertEqual(
      failure(.default, "http://10.0.0.7/mcp"),
      .insecureScheme("http://10.0.0.7/mcp"),
      "a private address is still an http host — the scheme rule fires first")
    // The documented escape hatch, spelled the same as ProviderConfig.insecure.
    XCTAssertNil(failure(URLPolicy(insecure: true), "http://mcp.example.com/mcp"))
  }

  // MARK: Addresses

  func testStrictPolicyRefusesPrivateLinkLocalAndMetadataAddresses() {
    for host in [
      "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.1.10", "169.254.169.254",
      "127.0.0.1", "0.0.0.0", "100.64.0.1", "192.0.0.1", "198.18.0.1", "224.0.0.1",
      "[::1]", "[fd00::1]", "[fe80::1]", "[::ffff:10.0.0.1]",
      "printer.local", "metadata.google.internal", "localhost",
    ] {
      XCTAssertNotNil(
        failure(.strict, "https://\(host)/thing"),
        "\(host) must be refused by the strict policy")
    }
    for host in ["mcp.example.com", "8.8.8.8", "172.32.0.1", "172.15.0.1", "100.128.0.1", "[2606:4700::1]"] {
      XCTAssertNil(failure(.strict, "https://\(host)/thing"), "\(host) is public")
    }
  }

  func testDefaultPolicyLeavesPrivateAddressesAloneForConfiguredInfrastructure() {
    // The provider gateway and configured MCP servers routinely live on a private
    // network; the user named the host, so only the scheme rule applies.
    XCTAssertNil(failure(.default, "https://10.1.2.3/v1"))
    XCTAssertNil(failure(.default, "https://192.168.1.10:4000/mcp"))
    // insecure also lifts the address rule for callers that opted into it.
    XCTAssertNil(failure(URLPolicy(insecure: true, refusePrivateAddresses: true), "https://10.1.2.3/v1"))
  }

  func testLoopbackAndPrivateClassifiers() {
    XCTAssertTrue(URLPolicy.isLoopback("LOCALHOST"))
    XCTAssertTrue(URLPolicy.isLoopback("127.255.0.1"))
    XCTAssertTrue(URLPolicy.isLoopback("[::1]"))
    XCTAssertFalse(URLPolicy.isLoopback("localhost.example.com"))
    XCTAssertFalse(URLPolicy.isLoopback("128.0.0.1"))
    XCTAssertTrue(URLPolicy.isPrivateOrReserved("169.254.169.254"), "the cloud metadata address")
    XCTAssertFalse(URLPolicy.isPrivateOrReserved("example.com"))
  }

  // MARK: Redirects

  func testRedirectStaysOnTheSameHost() throws {
    let policy = URLPolicy.default
    let origin = URL(string: "https://mcp.example.com/mcp")!
    XCTAssertEqual(
      try policy.redirect(from: origin, to: "/mcp/v2").absoluteString,
      "https://mcp.example.com/mcp/v2",
      "a relative Location resolves against the request it answered")
    XCTAssertEqual(
      try policy.redirect(from: origin, to: "https://mcp.example.com/other").absoluteString,
      "https://mcp.example.com/other")

    // The credentials on the request were minted for this host; a 302 must not move them.
    XCTAssertThrowsError(try policy.redirect(from: origin, to: "https://evil.example.net/mcp")) { error in
      XCTAssertEqual(
        error as? URLPolicy.Failure,
        .redirectedToAnotherHost(from: origin.absoluteString, to: "https://evil.example.net/mcp"))
    }
    // Same host, downgraded scheme: still refused.
    XCTAssertThrowsError(try policy.redirect(from: origin, to: "http://mcp.example.com/mcp")) { error in
      XCTAssertEqual(error as? URLPolicy.Failure, .insecureScheme("http://mcp.example.com/mcp"))
    }
  }

  // MARK: Provider parity

  func testProviderBaseURLRuleIsUnchangedByTheMigration() throws {
    XCTAssertNoThrow(try ProviderResolver.validateBaseURL("https://gw.example.com/v1/", insecure: false))
    XCTAssertEqual(
      try ProviderResolver.validateBaseURL("https://gw.example.com/v1/", insecure: false).absoluteString,
      "https://gw.example.com/v1",
      "the trailing slash is still dropped")
    XCTAssertNoThrow(try ProviderResolver.validateBaseURL("http://localhost:4000", insecure: false))
    XCTAssertThrowsError(try ProviderResolver.validateBaseURL("http://llm.example.com/v1", insecure: false)) {
      XCTAssertEqual($0 as? ProviderError, .insecureBaseURL("http://llm.example.com/v1"))
    }
    XCTAssertThrowsError(try ProviderResolver.validateBaseURL("ftp://llm.example.com/v1", insecure: false)) {
      XCTAssertEqual($0 as? ProviderError, .invalidBaseURL("ftp://llm.example.com/v1"))
    }
    // A private address is not a base-URL error: gateways live on private networks.
    XCTAssertNoThrow(try ProviderResolver.validateBaseURL("https://10.1.2.3/v1", insecure: false))
  }
}
