import Darwin
import Foundation

/// A process-wide advisory lock shared by signed, debug, and command-line launches.
/// The descriptor stays open for the lifetime of this object and closes on exec,
/// so provider subprocesses cannot accidentally keep Reserve alive.
public final class SingleInstanceLock: @unchecked Sendable {
  private let descriptor: Int32

  private init(descriptor: Int32) {
    self.descriptor = descriptor
  }

  deinit {
    _ = flock(self.descriptor, LOCK_UN)
    _ = close(self.descriptor)
  }

  public static func reserveLockURL() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask,
      appropriateFor: nil, create: true)
    let directory = base.appendingPathComponent("Reserve", isDirectory: true)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    return directory.appendingPathComponent("Reserve.instance.lock", isDirectory: false)
  }

  /// Returns `nil` only when another process owns the lock.
  public static func acquire(at url: URL) throws -> SingleInstanceLock? {
    let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      let lockError = errno
      _ = close(descriptor)
      if lockError == EWOULDBLOCK || lockError == EAGAIN { return nil }
      throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
    }
    return SingleInstanceLock(descriptor: descriptor)
  }
}
