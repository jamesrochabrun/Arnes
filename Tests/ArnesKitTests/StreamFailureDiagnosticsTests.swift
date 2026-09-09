import Foundation
import OpenRouterSwift
import XCTest
@testable import ArnesKit

final class StreamFailureDiagnosticsTests: XCTestCase {
  private let context = StreamFailureContext(sessionID: "session", model: "test/model",
    dialect: "chat", phase: "stream", emittedOutput: true)

  private func directory() throws -> URL {
    let canonical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
    defer { free(canonical) }
    let url = URL(fileURLWithPath: String(cString: canonical))
      .appendingPathComponent("arnes-stream-evidence-\(UUID())")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func artifacts(_ directory: URL) throws -> [StreamFailureStore.Artifact] {
    try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
      .map { try JSONDecoder().decode(StreamFailureStore.Artifact.self, from: Data(contentsOf: $0)) }
  }

  func testKeepsExactMalformedPayloadPrivatelyAndLabelsMissingFraming() async throws {
    let root = try directory()
    let store = try StreamFailureStore(directory: root)
    let raw = Data(#"{"choices":[{"delta":{"content":"unfinished"# .utf8)
    await store.record(OpenRouterError.decodingFailure(description: "invalid JSON", raw: raw), context: context)
    let artifact = try XCTUnwrap(artifacts(root).first)
    XCTAssertEqual(artifact.originalBytes, raw.count)
    XCTAssertEqual(artifact.payloadBase64.flatMap { Data(base64Encoded: $0) }, raw)
    XCTAssertFalse(artifact.payloadChanged)
    XCTAssertFalse(artifact.payloadOmitted)
    XCTAssertTrue(artifact.wireFraming.hasPrefix("unavailable"))
    XCTAssertEqual(artifact.model, "test/model")
    XCTAssertTrue(artifact.emittedOutput)
    let path = root.appendingPathComponent("stream-failure-0.json").path
    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testRedactsBeforeEncodingAndMetadataCap() async throws {
    let root = try directory()
    let secret = "fixture-private-bearer-123456789"
    let store = try StreamFailureStore(directory: root, knownSecrets: [secret])
    let key = "sk-or-v1-" + String(repeating: "a", count: 64)
    let raw = Data("{\"token\":\"\(secret)\",\"text\":\"\(key)\"".utf8)
    await store.record(OpenRouterError.decodingFailure(
      description: String(repeating: "x", count: 1_010) + secret, raw: raw), context: context)
    let artifact = try XCTUnwrap(artifacts(root).first)
    let payload = String(decoding: try XCTUnwrap(artifact.payloadBase64.flatMap { Data(base64Encoded: $0) }), as: UTF8.self)
    XCTAssertFalse(payload.contains(secret))
    XCTAssertFalse(payload.contains(key))
    XCTAssertTrue(payload.contains("REDACTED"))
    XCTAssertTrue(artifact.payloadChanged)
    XCTAssertFalse(artifact.description.contains("fixture-private"))
  }

  func testOversizedPayloadIsOmittedWithoutLeakingBoundary() async throws {
    let root = try directory()
    let store = try StreamFailureStore(directory: root)
    let raw = Data((String(repeating: "x", count: StreamFailureStore.maxPayloadBytes - 5)
      + "sk-or-v1-" + String(repeating: "a", count: 64)).utf8)
    await store.record(OpenRouterError.decodingFailure(description: "bad", raw: raw), context: context)
    let artifact = try XCTUnwrap(artifacts(root).first)
    XCTAssertNil(artifact.payloadBase64)
    XCTAssertTrue(artifact.payloadOmitted)
    XCTAssertEqual(artifact.originalBytes, raw.count)
  }

  func testInvalidUTF8IsMarkedAsChanged() async throws {
    let root = try directory()
    let store = try StreamFailureStore(directory: root)
    await store.record(OpenRouterError.decodingFailure(description: "bad", raw: Data([0xFF, 0x7B])), context: context)
    XCTAssertTrue(try XCTUnwrap(artifacts(root).first).payloadChanged)
  }

  func testRetentionBoundSharedAcrossStoresWithoutOverwrite() async throws {
    let root = try directory()
    let stores = try [StreamFailureStore(directory: root), StreamFailureStore(directory: root)]
    await withTaskGroup(of: Void.self) { group in
      for index in 0..<40 {
        group.addTask {
          await stores[index % 2].record(OpenRouterError.decodingFailure(description: "bad", raw: Data("\(index)".utf8)), context: self.context)
        }
      }
    }
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, StreamFailureStore.maxFiles)
    for file in files { XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, StreamFailureStore.maxArtifactBytes) }
    XCTAssertEqual(try artifacts(root).count, StreamFailureStore.maxFiles)
  }

  func testRefusesPublicDirectoryAndSymlinkAncestors() throws {
    let root = try directory()
    let unsafe = root.appendingPathComponent("public")
    try FileManager.default.createDirectory(at: unsafe, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
    XCTAssertThrowsError(try StreamFailureStore(directory: unsafe))
    let link = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: unsafe)
    XCTAssertThrowsError(try StreamFailureStore(directory: link))
    let child = unsafe.appendingPathComponent("child")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    XCTAssertThrowsError(try StreamFailureStore(directory: link.appendingPathComponent("child")))
  }

  func testChangedDirectoryIdentityIsRefused() async throws {
    let root = try directory()
    let target = root.appendingPathComponent("capture")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let store = try StreamFailureStore(directory: target)
    let moved = root.appendingPathComponent("moved")
    try FileManager.default.moveItem(at: target, to: moved)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    await store.record(OpenRouterError.decodingFailure(description: "bad", raw: Data()), context: context)
    XCTAssertTrue(try artifacts(target).isEmpty)
    XCTAssertTrue(try artifacts(moved).isEmpty)
    try FileManager.default.removeItem(at: target)
    try FileManager.default.createSymbolicLink(at: target, withDestinationURL: moved)
    await store.record(OpenRouterError.decodingFailure(description: "bad", raw: Data()), context: context)
    XCTAssertTrue(try artifacts(moved).isEmpty)
  }

  func testExistingSymlinkSlotIsNeverFollowed() async throws {
    let root = try directory()
    let victim = root.appendingPathComponent("victim")
    try Data("unchanged".utf8).write(to: victim)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("stream-failure-0.json"), withDestinationURL: victim)
    let store = try StreamFailureStore(directory: root)
    await store.record(OpenRouterError.decodingFailure(description: "bad", raw: Data()), context: context)
    XCTAssertEqual(try String(contentsOf: victim), "unchanged")
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("stream-failure-1.json").path))
  }

  func testOtherErrorsDoNotProduceArtifacts() async throws {
    let root = try directory()
    let store = try StreamFailureStore(directory: root)
    await store.record(CancellationError(), context: context)
    await store.record(URLError(.networkConnectionLost), context: context)
    await store.record(OpenRouterError.streamError(code: 502, message: "fixture", metadata: nil), context: context)
    XCTAssertTrue(try artifacts(root).isEmpty)
  }

  func testSessionCapturesBeforeAndAfterOutputWithoutRetryOrRecovery() async throws {
    for emitted in [false, true] {
      let root = try directory()
      let diagnostics = try StreamFailureStore(directory: root)
      let mock = MockOpenRouterService()
      mock.manifestJSON = Fixtures.manifest(Fixtures.manifestModel(id: "test/model"))
      mock.chunkScripts = [emitted ? [Fixtures.textChunk("partial")] : []]
      mock.chatStreamTrailingErrors = [OpenRouterError.decodingFailure(description: "fixture invalid JSON", raw: Data("{bad".utf8))]
      let configuration = Session.Configuration(model: "test/model", streamFailureDiagnostics: diagnostics)
      let session = Session(service: mock,
        store: RunRecordStore(url: root.appendingPathComponent("runs.jsonl")),
        configuration: configuration)
      do { for try await _ in await session.send("fixture") {} } catch { }
      let record = await session.lastRecord
      XCTAssertEqual(record?.stopReason, .error)
      XCTAssertEqual(mock.requests.count, 1)
      XCTAssertEqual(try XCTUnwrap(artifacts(root).first).emittedOutput, emitted)
      XCTAssertNotNil(configuration.forSubagent(named: "child", model: "test/model", systemSuffix: "fixture").streamFailureDiagnostics)
    }
    XCTAssertNil(Session.Configuration(model: "test/model").streamFailureDiagnostics)
  }
}
