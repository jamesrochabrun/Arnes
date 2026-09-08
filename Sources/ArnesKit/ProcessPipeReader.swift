import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A nonblocking pipe drain shared by shell output and MCP. Corelibs FileHandle can
/// leave trailing bytes unread or omit the final EOF notification. Reads and
/// closure run on one queue, so cancellation never closes a descriptor still being read.
final class ProcessPipeReader: @unchecked Sendable {
  private let queue = DispatchQueue(label: "arnes.process.pipe")
  private let source: DispatchSourceRead
  private let fd: Int32
  private let onData: @Sendable (Data) -> Void
  private let onEOF: @Sendable () -> Void

  init(handle: FileHandle, onData: @escaping @Sendable (Data) -> Void,
       onEOF: @escaping @Sendable () -> Void = {}) throws
  {
    fd = handle.fileDescriptor
    self.onData = onData
    self.onEOF = onEOF
    let flags = fcntl(fd, F_GETFL)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
      let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      try? handle.close()
      throw error
    }
    source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler { [weak self] in self?.drain() }
    source.setCancelHandler { try? handle.close() }
    source.resume()
  }

  func stop() { source.cancel() }

  /// Collect already available trailing bytes before the shell runner takes its snapshot.
  /// The iteration bound yields even when a surviving descendant writes continuously.
  func finish() {
    queue.sync {
      if !source.isCancelled { drain() }
      source.cancel()
    }
  }

  private func drain() {
    var bytes = [UInt8](repeating: 0, count: 8192)
    for _ in 0..<64 {
      guard !source.isCancelled else { return }
      #if canImport(Darwin)
      let count = Darwin.read(fd, &bytes, bytes.count)
      #else
      let count = Glibc.read(fd, &bytes, bytes.count)
      #endif
      if count > 0 {
        onData(Data(bytes.prefix(count)))
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
        return
      } else {
        source.cancel()
        onEOF()
        return
      }
    }
  }
}
