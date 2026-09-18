import Foundation

enum BoundedFileReader {
  /// The whole file, or `nil` unless it is a regular file owned by this user
  /// and no larger than `maximumBytes`. The path is opened once and everything
  /// after that — type, owner, size, the bytes themselves — comes from that one
  /// descriptor (see `DescriptorBoundFile`), so the path cannot be swapped for
  /// a link, FIFO or other file between the check and the read. A file that
  /// grows past the limit while being read is refused too.
  static func read(_ url: URL, maximumBytes: Int) -> Data? {
    guard maximumBytes >= 0,
      let file = DescriptorBoundFile.open(url, maximumBytes: maximumBytes)
    else { return nil }
    defer { file.close() }
    return file.readToEnd(maximumBytes: maximumBytes)
  }

  /// Writes `data` so the finished file is `0600` and the directory is `0700`.
  /// The bytes are created at those permissions, then renamed into place, so
  /// there is no world-readable window after an atomic replace.
  static func writeRestricted(
    _ data: Data,
    to url: URL,
    fileManager: FileManager = .default
  ) throws {
    let directory = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: directory.path)
    let temp = directory.appendingPathComponent(
      ".\(url.lastPathComponent).tmp-\(UUID().uuidString)")
    guard
      fileManager.createFile(
        atPath: temp.path,
        contents: data,
        attributes: [.posixPermissions: NSNumber(value: Int16(0o600))])
    else {
      throw UsageProviderError.invalidResponse("could not write \(url.lastPathComponent)")
    }
    do {
      // replaceItemAt keeps the original item's mode unless told otherwise, so
      // an existing 0644 cache would stay 0644 forever. Take the temp file's
      // 0600 metadata, then set the destination again in case this OS still
      // copies the old mode.
      if fileManager.fileExists(atPath: url.path) {
        _ = try fileManager.replaceItemAt(
          url, withItemAt: temp, backupItemName: nil, options: [.usingNewMetadataOnly])
      } else {
        try fileManager.moveItem(at: temp, to: url)
      }
      try fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o600))],
        ofItemAtPath: url.path)
    } catch {
      try? fileManager.removeItem(at: temp)
      throw error
    }
  }
}
