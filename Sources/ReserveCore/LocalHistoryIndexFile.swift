import Darwin
import Foundation

/// Identity of a cache file from one validated descriptor.
///
/// Device, inode, size and change time together catch replacement, rewrite and
/// deletion. Values come from `fstat` on the descriptor `DescriptorBoundFile`
/// already accepted, so the identity belongs to the same file as any bytes read.
struct LocalHistoryFileAnchor: Codable, Equatable, Sendable {
  var device: UInt64
  var inode: UInt64
  var size: Int64
  var modifiedAt: TimeInterval
  var changedAt: TimeInterval

  init(_ info: stat) {
    self.device = UInt64(truncatingIfNeeded: info.st_dev)
    self.inode = UInt64(info.st_ino)
    self.size = Int64(info.st_size)
    self.modifiedAt =
      TimeInterval(info.st_mtimespec.tv_sec)
      + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
    self.changedAt =
      TimeInterval(info.st_ctimespec.tv_sec)
      + TimeInterval(info.st_ctimespec.tv_nsec) / 1_000_000_000
  }
}

enum LocalHistoryIndexFile {
  /// `fstat` only. Does not read file bytes.
  static func anchor(url: URL, maximumBytes: Int) -> LocalHistoryFileAnchor? {
    guard let file = DescriptorBoundFile.open(url, maximumBytes: maximumBytes) else { return nil }
    defer { file.close() }
    var info = stat()
    guard fstat(file.handle.fileDescriptor, &info) == 0 else { return nil }
    return LocalHistoryFileAnchor(info)
  }

  /// Identity and bytes from the same descriptor. Missing, foreign, special
  /// and over-cap files return nil, including a file that grows past the cap
  /// while it is being read.
  static func contents(
    url: URL, maximumBytes: Int
  ) -> (anchor: LocalHistoryFileAnchor, data: Data)? {
    guard let file = DescriptorBoundFile.open(url, maximumBytes: maximumBytes) else { return nil }
    defer { file.close() }
    var info = stat()
    guard fstat(file.handle.fileDescriptor, &info) == 0 else { return nil }
    guard let data = file.readToEnd(maximumBytes: maximumBytes) else { return nil }
    return (LocalHistoryFileAnchor(info), data)
  }
}

/// Parsed progress from a pass that ran out of time or bytes.
///
/// Record keys are the same path hashes the published index uses. This file
/// stores no paths and no transcript text. `needsFinalize` means enumeration
/// finished; `retainedKeys` is empty until then so a resume cannot delete
/// files it has not seen.
struct LocalHistoryCheckpoint: Codable, Equatable, Sendable {
  var version: Int
  var anchor: LocalHistoryFileAnchor?
  var removedKeys: [String]
  var needsFinalize: Bool
  var retainedKeys: [String]
  var dirtyProviders: [String]
  var pruneProviders: [String]
  /// Provider raw value to the watcher generation observed when the pass began.
  var tokens: [String: Int]
  /// JSON object of parsed file records, produced by the scanner.
  var recordsJSON: Data

  static func url(for cacheURL: URL) -> URL {
    cacheURL.deletingLastPathComponent().appendingPathComponent(
      cacheURL.lastPathComponent + ".partial")
  }
}

enum LocalHistoryCheckpointStore {
  static func load(cacheURL: URL, maximumBytes: Int) -> LocalHistoryCheckpoint? {
    let url = LocalHistoryCheckpoint.url(for: cacheURL)
    guard let read = LocalHistoryIndexFile.contents(url: url, maximumBytes: maximumBytes) else {
      return nil
    }
    guard let checkpoint = try? JSONDecoder().decode(LocalHistoryCheckpoint.self, from: read.data),
      checkpoint.version == 1,
      checkpoint.recordsJSON.count <= maximumBytes,
      checkpoint.retainedKeys.count <= 5_000,
      checkpoint.removedKeys.count <= 5_000,
      checkpoint.dirtyProviders.count <= 8,
      checkpoint.pruneProviders.count <= 8,
      checkpoint.tokens.count <= 8
    else {
      try? FileManager.default.removeItem(at: url)
      return nil
    }
    return checkpoint
  }

  /// Returns false when the encoded checkpoint exceeds the published index cap.
  /// The previous partial file is left in place in that case.
  static func save(
    _ checkpoint: LocalHistoryCheckpoint,
    cacheURL: URL,
    maximumBytes: Int,
    fileManager: FileManager
  ) throws -> Bool {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(checkpoint)
    guard data.count <= maximumBytes else { return false }
    try BoundedFileReader.writeRestricted(
      data, to: LocalHistoryCheckpoint.url(for: cacheURL), fileManager: fileManager)
    return true
  }

  static func discard(cacheURL: URL) {
    try? FileManager.default.removeItem(at: LocalHistoryCheckpoint.url(for: cacheURL))
  }
}
