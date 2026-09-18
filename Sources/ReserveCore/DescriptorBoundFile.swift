import Darwin
import Foundation

/// A regular file opened once and then validated and read only through that
/// one descriptor.
///
/// Checking a path (`resourceValues`, `stat`) and then opening the same path
/// leaves a window in which another process running as this user can swap the
/// path for a symlink, a FIFO (whose open blocks forever with no writer), a
/// device, or simply a different file. Here the path is resolved exactly once,
/// by `open(2)`; every later question — what kind of file, whose, how large,
/// when last modified — is answered by `fstat(2)` on the descriptor, and every
/// byte comes from that descriptor. Renaming something over the path after the
/// open changes nothing for this reader.
///
/// `O_NOFOLLOW` only refuses a symlink in the *last* path component; links in
/// parent directories are still followed. That is accepted here: the local
/// usage scanner already confines the directories it walks, and the other
/// callers read fixed files under the user's own home.
///
/// Hard links are deliberately not refused (`st_nlink` is not checked). A hard
/// link can only name a file on the same volume, and the owner check below
/// already rejects any file this user does not own, so a same-user hard link
/// gives an attacker nothing they could not read directly. Refusing them would
/// instead break setups that hard-link dotfiles such as `~/.claude.json`.
final class DescriptorBoundFile {
  /// Size and modification time taken from one `fstat`/`lstat`, converted the
  /// same way in both places so a stamp recorded at open compares equal to a
  /// later path-level check of the untouched file.
  struct Metadata: Equatable {
    var size: Int64
    var modifiedAt: TimeInterval

    var date: Date { Date(timeIntervalSince1970: self.modifiedAt) }

    init(size: Int64, modifiedAt: TimeInterval) {
      self.size = size
      self.modifiedAt = modifiedAt
    }

    init(_ info: stat) {
      self.size = Int64(info.st_size)
      self.modifiedAt =
        TimeInterval(info.st_mtimespec.tv_sec)
        + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    }
  }

  /// Metadata of the file as it was when it was opened and validated.
  let metadata: Metadata
  /// Owns the validated descriptor and closes it on deallocation.
  let handle: FileHandle

  private init(metadata: Metadata, handle: FileHandle) {
    self.metadata = metadata
    self.handle = handle
  }

  /// Opens `url` and returns it only if the descriptor names a regular file
  /// owned by `expectedOwner` and, when `maximumBytes` is given, no larger than
  /// that. Symlinks (last component), FIFOs, devices, sockets, directories,
  /// foreign-owned and oversized files all return `nil`, as does a path that
  /// no longer exists. Never blocks: `O_NONBLOCK` makes opening a FIFO with no
  /// writer return immediately so that `fstat` can reject it.
  ///
  /// `expectedOwner` exists so tests can exercise the owner check; production
  /// callers keep the default, the real user ID of this process.
  static func open(
    _ url: URL,
    maximumBytes: Int? = nil,
    expectedOwner: uid_t = getuid()
  ) -> DescriptorBoundFile? {
    guard url.isFileURL else { return nil }
    if let maximumBytes, maximumBytes < 0 { return nil }
    let descriptor = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else { return -1 }
      return Darwin.open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    }
    guard descriptor >= 0 else { return nil }
    var info = stat()
    guard fstat(descriptor, &info) == 0,
      info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == expectedOwner,
      info.st_size >= 0,
      maximumBytes.map({ Int64(info.st_size) <= Int64($0) }) ?? true
    else {
      Darwin.close(descriptor)
      return nil
    }
    // Regular files ignore O_NONBLOCK — reads never return EAGAIN for them —
    // so this is hygiene rather than a behavior change: the flag was only
    // there to keep the open itself from hanging on a FIFO.
    let flags = fcntl(descriptor, F_GETFL)
    if flags >= 0, flags & O_NONBLOCK != 0 {
      _ = fcntl(descriptor, F_SETFL, flags & ~O_NONBLOCK)
    }
    return DescriptorBoundFile(
      metadata: Metadata(info),
      handle: FileHandle(fileDescriptor: descriptor, closeOnDealloc: true))
  }

  /// Path-level metadata without opening or following a final symlink. Only
  /// good for cheap change detection; the authoritative check is `open`.
  static func linkMetadata(_ url: URL) throws -> Metadata {
    var info = stat()
    let result = url.withUnsafeFileSystemRepresentation { path -> Int32 in
      guard let path else {
        errno = EINVAL
        return -1
      }
      return lstat(path, &info)
    }
    guard result == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return Metadata(info)
  }

  /// Reads from the current offset to the end, or `nil` if that is more than
  /// `maximumBytes`. The file may have grown since `fstat`, so the limit is
  /// enforced on the bytes actually read: at most `maximumBytes + 1` are read,
  /// and seeing the extra byte means the file no longer fits.
  func readToEnd(maximumBytes: Int) -> Data? {
    guard maximumBytes >= 0 else { return nil }
    var data = Data()
    while data.count <= maximumBytes {
      let wanted = min(64 * 1_024, maximumBytes + 1 - data.count)
      let chunk: Data?
      do {
        chunk = try self.handle.read(upToCount: wanted)
      } catch {
        return nil
      }
      // FileHandle reports end of file as either nil or an empty chunk.
      guard let chunk, !chunk.isEmpty else { break }
      data.append(chunk)
    }
    return data.count <= maximumBytes ? data : nil
  }

  func close() {
    try? self.handle.close()
  }
}
