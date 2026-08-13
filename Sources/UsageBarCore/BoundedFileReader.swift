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
}
