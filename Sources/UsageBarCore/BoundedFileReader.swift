import Foundation

enum BoundedFileReader {
  static func read(_ url: URL, maximumBytes: Int) -> Data? {
    guard maximumBytes >= 0,
      let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
      values.isRegularFile == true,
      let fileSize = values.fileSize,
      fileSize <= maximumBytes
    else { return nil }
    return try? Data(contentsOf: url, options: .mappedIfSafe)
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
      _ = try fileManager.replaceItemAt(url, withItemAt: temp)
    } catch {
      try? fileManager.removeItem(at: temp)
      throw error
    }
  }
}
