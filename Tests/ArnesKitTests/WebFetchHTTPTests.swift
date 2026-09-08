import XCTest
@testable import ArnesKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Real loopback responses exercise the platform URLSession implementation. The fixture
/// lives in a temporary tree and its process is owned and stopped by JobRegistry.
final class WebFetchHTTPTests: XCTestCase {
  private func fixture() async throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("arnes-web-http-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let jobs = JobRegistry(logRoot: root)
    addTeardownBlock {
      await jobs.killAll()
      try? FileManager.default.removeItem(at: root)
    }
    let script = root.appendingPathComponent("server.py")
    try Self.server.write(to: script, atomically: true, encoding: .utf8)
    let job = try await jobs.start(command: "python3 \(WorkspaceSnapshot.shellQuote(script.path))", cwd: root)
    let portFile = root.appendingPathComponent("port")
    for _ in 0..<500 {
      if let port = try? String(contentsOf: portFile, encoding: .utf8), Int(port) != nil {
        return URL(string: "http://127.0.0.1:\(port)")!
      }
      let status = await jobs.status(id: job.id)
      if status?.isRunning == false { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let log = await jobs.poll(id: job.id)
    XCTFail("HTTP fixture failed to listen: \(log?.text ?? "no output")")
    throw URLError(.cannotConnectToHost)
  }

  func testOversizedStreamingBodyStopsAtTheCapWithoutWaitingForEOF() async throws {
    let url = try await fixture().appendingPathComponent("oversized")
    let started = Date()
    let result = try await URLSessionWebFetchPerformer().fetch(url, maxBytes: 8, timeout: 3)
    XCTAssertEqual(result.statusCode, 200)
    XCTAssertEqual(result.body, Data("abcdefgh".utf8))
    XCTAssertTrue(result.truncated)
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  func testTruncationDistinguishesExactEmptyAndOverflowBodies() async throws {
    let root = try await fixture()
    for (path, cap, expected, truncated) in [
      ("exact", 8, "abcdefgh", false), ("empty", 0, "", false),
      ("exact", 7, "abcdefg", true), ("exact", 0, "", true),
    ] {
      let result = try await URLSessionWebFetchPerformer().fetch(
        root.appendingPathComponent(path), maxBytes: cap, timeout: 3)
      XCTAssertEqual(result.body, Data(expected.utf8))
      XCTAssertEqual(result.truncated, truncated)
    }
  }

  func testWebAndMCPPerformersSurfaceRedirectsWithoutFollowingThem() async throws {
    let url = try await fixture().appendingPathComponent("redirect")
    let web = try await URLSessionWebFetchPerformer().fetch(url, maxBytes: 8, timeout: 3)
    XCTAssertEqual(web.statusCode, 302)
    XCTAssertEqual(web.header("Location"), "/exact")
    let mcp = try await URLSessionMCPPerformer(timeout: 3).perform(.init(url: url, method: "GET"))
    XCTAssertEqual(mcp.statusCode, 302)
    XCTAssertEqual(mcp.header("Location"), "/exact")
  }

  func testCancellationStopsAResponseThatHasNotSentItsBody() async throws {
    let root = try await fixture()
    let task = Task {
      try await URLSessionWebFetchPerformer().fetch(root.appendingPathComponent("hold"), maxBytes: 8, timeout: 30)
    }
    defer { task.cancel() }
    // The fixture's ready endpoint confirms the held request actually reached the server.
    for _ in 0..<100 {
      let ready = try await URLSessionMCPPerformer(timeout: 3).perform(
        .init(url: root.appendingPathComponent("ready"), method: "GET"))
      if ready.statusCode == 200 { break }
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    let ready = try await URLSessionMCPPerformer(timeout: 3).perform(
      .init(url: root.appendingPathComponent("ready"), method: "GET"))
    XCTAssertEqual(ready.statusCode, 200)
    let started = Date()
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("cancelled fetch returned success")
    } catch {
      XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
    }
    XCTAssertLessThan(Date().timeIntervalSince(started), 3)
  }

  func testCancellationBeforeStartingCannotCreateARequest() async throws {
    let transfer = BoundedWebFetch(maxBytes: 8)
    transfer.cancel()
    do {
      let _: WebFetchResponse = try await withCheckedThrowingContinuation { continuation in
        transfer.start(URLRequest(url: URL(string: "http://127.0.0.1:1")!),
          configuration: .ephemeral, continuation: continuation)
      }
      XCTFail("cancelled transfer started")
    } catch {
      XCTAssertTrue(error is CancellationError)
    }
  }

  private static let server = #"""
  import http.server
  import pathlib
  import threading
  held = threading.Event()
  class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
      pass
    def do_GET(self):
      if self.path == '/redirect':
        self.send_response(302)
        self.send_header('Location', '/exact')
        body = b''
      elif self.path == '/ready':
        self.send_response(200 if held.is_set() else 503)
        body = b''
      else:
        self.send_response(200)
        body = b'' if self.path == '/empty' else b'abcdefgh'
      streaming = self.path in ['/oversized', '/hold']
      self.send_header('Content-Type', 'text/plain')
      self.send_header('Content-Length', str(1000000000 if streaming else len(body)))
      self.end_headers()
      if self.path == '/hold':
        self.wfile.flush()
        held.set()
      else:
        self.wfile.write(body + (b'i' * 65536 if self.path == '/oversized' else b''))
        self.wfile.flush()
      if streaming:
        self.connection.settimeout(10)
        try:
          self.rfile.read(1)
        except (TimeoutError, ConnectionResetError):
          pass
  server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
  pathlib.Path('port').write_text(str(server.server_port))
  server.serve_forever()
  """#
}
