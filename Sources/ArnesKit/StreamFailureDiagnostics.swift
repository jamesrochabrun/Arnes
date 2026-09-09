import Foundation
import OpenRouterSwift
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Request context for a failed decoder. No prompts, request headers or tool output.
public struct StreamFailureContext: Sendable {
  public let sessionID: String
  public let model: String
  public let dialect: String
  public let phase: String
  public let emittedOutput: Bool

  public init(sessionID: String, model: String, dialect: String, phase: String, emittedOutput: Bool) {
    self.sessionID = sessionID
    self.model = model
    self.dialect = dialect
    self.phase = phase
    self.emittedOutput = emittedOutput
  }
}

/// Optional private evidence sink. Implementations must never throw into recovery or print.
public protocol StreamFailureDiagnostics: Sendable {
  func record(_ error: any Error, context: StreamFailureContext) async
}

/// Saves only typed SDK decoding failures in an existing, owner-only directory.
/// Eight exclusive slots bound retention across sessions and processes; no eviction or reads.
/// Payloads over 16 KiB are omitted, never cut through a possible credential. Recognized
/// secrets are scrubbed before encoding. Other provider/user text remains private content.
public actor StreamFailureStore: StreamFailureDiagnostics {
  public static let maxFiles = 8
  public static let maxPayloadBytes = 16_384
  public static let maxArtifactBytes = 32_768
  private let directory: URL
  private let device: dev_t
  private let inode: ino_t
  private let knownSecrets: [String]

  public enum StoreError: Error { case unsafeDirectory }

  /// The directory must already exist, belong to this user, have mode 0700 and contain
  /// no symlink path components. A changed directory identity is refused on every write.
  public init(directory: URL, knownSecrets: [String] = []) throws {
    let descriptor = try Self.openDirectory(directory)
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { throw StoreError.unsafeDirectory }
    self.directory = directory
    device = info.st_dev
    inode = info.st_ino
    self.knownSecrets = knownSecrets.filter { $0.utf8.count >= 4 }
  }

  struct Artifact: Codable {
    let schema: Int
    let sessionID: String
    let model: String
    let dialect: String
    let phase: String
    let emittedOutput: Bool
    let payloadSource: String
    let wireFraming: String
    let originalBytes: Int
    let payloadBase64: String?
    let payloadOmitted: Bool
    let payloadChanged: Bool
    let description: String
    enum CodingKeys: String, CodingKey {
      case schema, model, dialect, phase, description
      case sessionID = "session_id"
      case emittedOutput = "emitted_output"
      case payloadSource = "payload_source"
      case wireFraming = "wire_framing"
      case originalBytes = "original_bytes"
      case payloadBase64 = "payload_base64"
      case payloadOmitted = "payload_omitted"
      case payloadChanged = "payload_changed"
    }
  }

  public func record(_ error: any Error, context: StreamFailureContext) async {
    guard case .decodingFailure(let description, let raw) = error as? OpenRouterError,
      let descriptor = try? Self.openDirectory(directory) else { return }
    defer { close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_dev == device, info.st_ino == inode else { return }

    let text = raw.count <= Self.maxPayloadBytes ? String(decoding: raw, as: UTF8.self) : nil
    let scrubbed = text.map(scrub)
    let bytes = scrubbed.map { Data($0.utf8) }
    let artifact = Artifact(schema: 1,
      sessionID: bounded(context.sessionID), model: bounded(context.model),
      dialect: bounded(context.dialect), phase: bounded(context.phase), emittedOutput: context.emittedOutput,
      payloadSource: "sdk_decoding_failure_raw",
      wireFraming: "unavailable: SDK supplies normalized decoder payload, not original SSE bytes",
      originalBytes: raw.count, payloadBase64: bytes?.base64EncodedString(),
      payloadOmitted: text == nil, payloadChanged: bytes.map { $0 != raw } ?? false,
      description: bounded(description))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(artifact), data.count <= Self.maxArtifactBytes else { return }
    for slot in 0..<Self.maxFiles {
      let name = "stream-failure-\(slot).json"
      let file = openat(descriptor, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
      if file < 0 {
        if errno == EEXIST { continue }
        return
      }
      defer { close(file) }
      // A restrictive umask is fine; ensure the promised mode even if the process changes it.
      guard fchmod(file, 0o600) == 0 else { return }
      _ = data.withUnsafeBytes { buffer in
        var written = 0
        while written < buffer.count {
          let count = write(file, buffer.baseAddress!.advanced(by: written), buffer.count - written)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { return false }
          written += count
        }
        return true
      }
      return
    }
  }

  private func scrub(_ text: String) -> String {
    var result = text
    for secret in knownSecrets { result = result.replacingOccurrences(of: secret, with: "[REDACTED]") }
    return SecretScrubber.scrub(result).text
  }

  private func bounded(_ text: String) -> String {
    // Oversized metadata is omitted before scanning; accepted strings are scrubbed in full
    // before the display cap, so a credential cannot leak across the retained boundary.
    guard text.utf8.count <= Self.maxPayloadBytes else { return "[omitted: oversized metadata]" }
    return String(scrub(text).prefix(1_024))
  }

  private static func openDirectory(_ url: URL) throws -> Int32 {
    guard url.isFileURL, url.path.hasPrefix("/") else { throw StoreError.unsafeDirectory }
    var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard descriptor >= 0 else { throw StoreError.unsafeDirectory }
    for component in url.path.split(separator: "/") {
      guard component != ".", component != ".." else {
        close(descriptor)
        throw StoreError.unsafeDirectory
      }
      let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      close(descriptor)
      guard next >= 0 else { throw StoreError.unsafeDirectory }
      descriptor = next
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == geteuid(), info.st_mode & 0o777 == 0o700 else {
      close(descriptor)
      throw StoreError.unsafeDirectory
    }
    return descriptor
  }
}
