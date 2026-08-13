import Foundation

public actor SnapshotCache {
  private let fileURL: URL
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private let maximumBytes = 100 * 1024

  public init(fileURL: URL? = nil) {
    let applicationSupport = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0]
    self.fileURL =
      fileURL
      ?? applicationSupport
      .appendingPathComponent("UsageBar", isDirectory: true)
      .appendingPathComponent("snapshots.json")
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    self.encoder.dateEncodingStrategy = .iso8601
    self.decoder = JSONDecoder()
    self.decoder.dateDecodingStrategy = .iso8601
  }

  public func load() -> [ProviderID: UsageSnapshot] {
    let directory = self.fileURL.deletingLastPathComponent()
    try? FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: directory.path)
    try? FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: self.fileURL.path)
    guard let data = BoundedFileReader.read(self.fileURL, maximumBytes: self.maximumBytes),
      let snapshots = try? self.decoder.decode([UsageSnapshot].self, from: data)
    else { return [:] }
    var newestByProvider: [ProviderID: UsageSnapshot] = [:]
    for snapshot in snapshots {
      if let existing = newestByProvider[snapshot.provider],
        existing.fetchedAt >= snapshot.fetchedAt
      {
        continue
      }
      newestByProvider[snapshot.provider] = snapshot
    }
    return newestByProvider
  }

  public func save(_ snapshots: [ProviderID: UsageSnapshot]) throws {
    let values = ProviderID.allCases.compactMap { snapshots[$0] }
    let data = try self.encoder.encode(values)
    guard data.count <= self.maximumBytes else {
      throw UsageProviderError.invalidResponse("snapshot cache exceeded 100 KB")
    }
    let directory = self.fileURL.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: directory.path)
    try data.write(to: self.fileURL, options: [.atomic])
    try FileManager.default.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: self.fileURL.path)
  }
}
