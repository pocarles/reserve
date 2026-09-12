import Darwin
import Foundation

/// Watches the containing directory so atomic replacements keep working. Only
/// metadata for the requested file is inspected; unrelated writes do not
/// trigger a callback. There is no polling timer or directory enumeration.
public final class QuotaFileWatcher: @unchecked Sendable {
  private let cacheURL: URL
  private let onChange: @Sendable () -> Void
  private let queue = DispatchQueue(label: "com.pocarles.reserve.quota-file", qos: .utility)
  private let queueKey = DispatchSpecificKey<Bool>()
  private let source: DispatchSourceFileSystemObject
  private var lastStamp: Stamp?
  private var pending: DispatchWorkItem?
  private var pendingStamp: Stamp?
  private var stopped = false

  public init(cacheURL: URL, onChange: @escaping @Sendable () -> Void) throws {
    self.cacheURL = cacheURL
    self.onChange = onChange
    let directory = cacheURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    let descriptor = open(directory.path, O_EVTONLY | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    var metadata = stat()
    guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
      close(descriptor)
      throw POSIXError(.ENOTDIR)
    }
    self.lastStamp = Self.stamp(cacheURL)
    self.source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
      eventMask: [.write, .extend, .attrib, .rename, .delete], queue: self.queue)
    self.queue.setSpecific(key: self.queueKey, value: true)
    self.source.setEventHandler { [weak self] in self?.changed() }
    self.source.setCancelHandler { close(descriptor) }
    self.source.resume()
  }

  /// Once this returns, no further callbacks run. Safe from inside a callback.
  public func stop() {
    if DispatchQueue.getSpecific(key: self.queueKey) == true { self.stopOnQueue() }
    else { self.queue.sync { self.stopOnQueue() } }
  }

  deinit { self.stop() }

  private func stopOnQueue() {
    guard !self.stopped else { return }
    self.stopped = true
    self.pending?.cancel()
    self.pending = nil
    self.pendingStamp = nil
    self.source.cancel()
  }

  private func changed() {
    let stamp = Self.stamp(self.cacheURL)
    guard !self.stopped, stamp != self.lastStamp,
      self.pending == nil || stamp != self.pendingStamp else { return }
    self.pending?.cancel()
    self.pendingStamp = stamp
    let work = DispatchWorkItem { [weak self] in
      guard let self, !self.stopped else { return }
      self.pending = nil
      self.pendingStamp = nil
      let stamp = Self.stamp(self.cacheURL)
      guard stamp != self.lastStamp else { return }
      self.lastStamp = stamp
      self.onChange()
    }
    self.pending = work
    self.queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: work)
  }

  private struct Stamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let bytes: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
  }

  private static func stamp(_ url: URL) -> Stamp? {
    var value = stat()
    guard lstat(url.path, &value) == 0, value.st_mode & S_IFMT == S_IFREG else { return nil }
    return Stamp(device: value.st_dev, inode: value.st_ino, bytes: value.st_size,
      modifiedSeconds: value.st_mtimespec.tv_sec, modifiedNanoseconds: value.st_mtimespec.tv_nsec,
      changedSeconds: value.st_ctimespec.tv_sec, changedNanoseconds: value.st_ctimespec.tv_nsec)
  }
}
