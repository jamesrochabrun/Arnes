import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// Owner-only files for `~/.arnes`.
///
/// Everything Arnes persists is private to the user: transcripts carry tool outputs
/// (that is, file contents), run records carry task text, and the config and
/// credentials carry tokens. So every directory Arnes creates is 0700 and every file
/// 0600. Files that already exist keep their mode — tightening a deliberate choice
/// silently would be rude — and `isReadableByOthers` lets the CLI warn instead.
public enum SecureFiles {
  /// Creates `url` (and any missing ancestors) as 0700 directories.
  public static func ensureDirectory(_ url: URL) throws {
    let directory = url.standardizedFileURL
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else {
        throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: directory.path])
      }
      return
    }
    let parent = directory.deletingLastPathComponent()
    if parent.path != directory.path {
      try ensureDirectory(parent)
    }
    do {
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    } catch CocoaError.fileWriteFileExists {
      // Lost a race with another writer (parallel panel candidates) — it exists now.
    }
  }

  /// Opens `url` for appending, creating it 0600 (and its directory 0700) when missing.
  /// `O_APPEND` keeps concurrent writers from clobbering each other.
  static func openForAppend(_ url: URL) throws -> Int32 {
    try ensureDirectory(url.deletingLastPathComponent())
    let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    guard descriptor >= 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return descriptor
  }

  /// Writes `data` atomically and leaves the file 0600.
  public static func writePrivate(_ data: Data, to url: URL) throws {
    try ensureDirectory(url.deletingLastPathComponent())
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  /// Whether group or world can read the file — the warning condition for the
  /// credentials and config files. False when the file doesn't exist.
  public static func isReadableByOthers(_ url: URL) -> Bool {
    mode(of: url).map { $0 & 0o044 != 0 } ?? false
  }

  /// Whether group or world can *write* the file — the warning condition for a file whose
  /// contents become commands (a project's `.arnes/hooks.json`). A repo checkout is
  /// world-readable by design, so reading isn't the question there; writing is, because
  /// whoever can write it chooses what runs. False when the file doesn't exist.
  public static func isWritableByOthers(_ url: URL) -> Bool {
    mode(of: url).map { $0 & 0o022 != 0 } ?? false
  }

  private static func mode(of url: URL) -> Int? {
    guard
      let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
      let permissions = attributes[.posixPermissions] as? Int
    else {
      return nil
    }
    return permissions
  }
}
