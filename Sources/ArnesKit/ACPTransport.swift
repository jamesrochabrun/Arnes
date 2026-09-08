import Foundation
import OpenRouterSwift
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Newline-delimited JSON-RPC framing. A bounded partial line prevents a peer without
/// newlines from growing memory indefinitely. UTF-8 is decoded only after a complete line.
public struct ACPLineFramer: Sendable {
  private var pending = Data()
  public init() {}

  public mutating func append(_ data: Data) throws -> [Data] {
    var lines: [Data] = []
    for byte in data {
      if byte == 10 {
        if pending.last == 13 { pending.removeLast() }
        if !pending.isEmpty { lines.append(pending) }
        pending = Data()
      } else {
        guard pending.count < ACPConnection.maximumMessageBytes else {
          throw ACPError(code: -32600, message: "ACP input line exceeds 1 MiB")
        }
        pending.append(byte)
      }
    }
    return lines
  }

  public mutating func finish() throws {
    guard pending.isEmpty else { throw ACPError(code: -32700, message: "Incomplete ACP message at EOF") }
  }
}

/// Serializes writes so two sessions cannot interleave bytes on the JSON-RPC stream.
public actor ACPOutputWriter {
  private let handle: FileHandle
  private let descriptor: Int32
  private let identity: FileIdentity?
  private let queue = DispatchQueue(label: "arnes.acp.output")
  private let writeTimeoutMilliseconds: Int
  public private(set) var failed = false
  public init(handle: FileHandle, writeTimeoutMilliseconds: Int = 5_000) {
    self.handle = handle
    descriptor = handle.fileDescriptor
    var info = stat()
    identity = fstat(descriptor, &info) == 0
      ? FileIdentity(device: Int64(clamping: info.st_dev), inode: UInt64(clamping: info.st_ino)) : nil
    self.writeTimeoutMilliseconds = min(60_000, max(1, writeTimeoutMilliseconds))
  }
  public func write(_ message: JSONValue) async throws {
    guard !failed else { throw ACPError(code: -32603, message: "ACP output is closed") }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
      var data = try encoder.encode(message)
      data.append(10)
      // Pipes can fill when an editor stops reading. Bound the write on a serial IO queue:
      // neither a cooperative executor nor session cleanup may wait on that peer forever.
      let descriptor = descriptor, identity = identity, timeout = writeTimeoutMilliseconds
      let bytes = data
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        queue.async {
          do {
            try Self.write(bytes, to: descriptor, identity: identity, timeout: timeout)
            continuation.resume()
          } catch { continuation.resume(throwing: error) }
        }
      }
    } catch { failed = true; throw error }
  }

  private nonisolated static func write(_ data: Data, to fd: Int32, identity: FileIdentity?, timeout: Int) throws {
    var info = stat()
    guard let identity, fstat(fd, &info) == 0,
      identity == FileIdentity(device: Int64(clamping: info.st_dev), inode: UInt64(clamping: info.st_ino)) else {
      throw ACPError(code: -32603, message: "ACP output is closed or replaced")
    }
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw ACPError(code: -32603, message: "ACP output is closed")
    }
    defer { _ = fcntl(fd, F_SETFL, flags) }
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout) * 1_000_000
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        guard DispatchTime.now().uptimeNanoseconds < deadline else {
          throw ACPError(code: -32603, message: "ACP output write timed out")
        }
        #if canImport(Darwin)
        let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        #else
        let count = Glibc.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        #endif
        if count > 0 { offset += count; continue }
        if count < 0, errno == EINTR { continue }
        guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
          throw ACPError(code: -32603, message: "ACP output write failed")
        }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        _ = poll(&descriptor, 1, 10)
      }
    }
  }
}

/// Readiness-driven input, not FileHandle.AsyncBytes (which can serialize blocking pipe
/// reads onto one IO actor). Overflow closes the connection instead of dropping messages.
public final class ACPInputReader: Sendable {
  public let stream: AsyncThrowingStream<Data, Error>
  private let continuation: AsyncThrowingStream<Data, Error>.Continuation
  public init(handle: FileHandle) {
    var captured: AsyncThrowingStream<Data, Error>.Continuation!
    stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(64)) { captured = $0 }
    continuation = captured
    let continuation = continuation
    handle.readabilityHandler = { readable in
      let data = readable.availableData
      if data.isEmpty {
        readable.readabilityHandler = nil
        continuation.finish()
      } else if case .dropped = continuation.yield(data) {
        readable.readabilityHandler = nil
        continuation.finish(throwing: ACPError(code: -32600, message: "ACP input queue overflow"))
      }
    }
    continuation.onTermination = { _ in handle.readabilityHandler = nil }
  }

  /// Also wakes an idle stdin consumer when the peer disconnects its output pipe first.
  public func stop() { continuation.finish() }

  public static func chunks(from handle: FileHandle) -> AsyncThrowingStream<Data, Error> {
    ACPInputReader(handle: handle).stream
  }
}
