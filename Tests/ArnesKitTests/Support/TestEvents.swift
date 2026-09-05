import Foundation
import ArnesKit

/// Shared test helpers that a dozen `ArnesKitTests` files had each re-declared as
/// file-private copies: the event-stream collector and the temp-file store/dir factories.
///
/// Namespaced under enums (not free functions) on purpose — a free `drain`/`tempStore`
/// would redeclare against the file-private copies still living in individual test files
/// during the gradual migration, and against any a future test adds. `Events.drain(...)`
/// / `TestPaths.recordStore()` never collide, so call sites can move over one file at a
/// time without a flag day.
enum Events {
  /// Consumes an agent event stream to completion, returning everything it yielded.
  static func drain(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws -> [AgentEvent] {
    var events: [AgentEvent] = []
    for try await event in stream { events.append(event) }
    return events
  }

  /// Consumes an agent event stream to completion, discarding the events (for tests that
  /// only care that the turn ran and inspect the record/store afterwards).
  static func consume(_ stream: AsyncThrowingStream<AgentEvent, Error>) async throws {
    for try await _ in stream {}
  }
}

/// Unique temp locations for tests. Each call returns a fresh UUID-suffixed path under the
/// system temp directory, so parallel tests never share a file.
enum TestPaths {
  /// A `RunRecordStore` backed by a unique temp `.jsonl` file.
  static func recordStore(_ label: String = "runs") -> RunRecordStore {
    RunRecordStore(url: storeURL(label))
  }

  /// A unique temp `.jsonl` URL (for a store the caller builds itself, e.g. a dialect store).
  static func storeURL(_ label: String = "store") -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-\(label)-\(UUID().uuidString).jsonl")
  }

  /// A unique temp directory, created 0700, for a test that needs a working tree or root.
  static func directory(_ label: String = "root") throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("arnes-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }
}
