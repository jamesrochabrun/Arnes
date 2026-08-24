import Foundation

/// A single-line braille spinner for waits (model latency, tool runs). TTY-only —
/// a no-op when stdout is piped, so scripted runs stay clean. Writes are guarded by
/// a lock so `stop()` can clear the line without a straggling frame redrawing it.
final class Spinner: @unchecked Sendable {
  private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
  private let lock = NSLock()
  private var task: Task<Void, Never>?
  private var active = false

  func start(_ label: String) {
    guard ANSI.isTTY else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !active else { return }
    active = true
    let startedAt = Date()
    task = Task { [weak self] in
      var frame = 0
      while !Task.isCancelled {
        self?.draw(label: label, frame: frame, startedAt: startedAt)
        frame += 1
        try? await Task.sleep(nanoseconds: 80_000_000)
      }
    }
  }

  func stop() {
    guard ANSI.isTTY else { return }
    lock.lock()
    defer { lock.unlock() }
    guard active else { return }
    active = false
    task?.cancel()
    task = nil
    write("\r\u{1B}[K")
  }

  private func draw(label: String, frame: Int, startedAt: Date) {
    lock.lock()
    defer { lock.unlock() }
    guard active else { return }
    let elapsed = Int(Date().timeIntervalSince(startedAt))
    let suffix = elapsed >= 2 ? " \(elapsed)s" : ""
    let glyph = Self.frames[frame % Self.frames.count]
    write("\r\u{1B}[K\u{1B}[2m\(glyph) \(label)\(suffix)\u{1B}[0m")
  }

  private func write(_ text: String) {
    FileHandle.standardOutput.write(Data(text.utf8))
  }
}
