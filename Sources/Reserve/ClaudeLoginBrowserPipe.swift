import Darwin
import Foundation
import ReserveCore

@MainActor
final class ClaudeLoginBrowserPipe {
  let directory: URL
  let path: String
  let browserExecutable: String
  private let reader: FileHandle
  private let gate = BoundedOutputGate(maximumBytes: 65_536)

  init(onURLData: @escaping @MainActor @Sendable (Data) -> Void) throws {
    guard
      let script = PackagedResourceBundle.resolved.url(
        forResource: "ClaudeLoginBrowser", withExtension: "sh"),
      FileManager.default.isExecutableFile(atPath: script.path)
    else { throw CocoaError(.fileNoSuchFile) }
    self.browserExecutable = script.path
    self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-browser-\(UUID().uuidString)", isDirectory: true)
    self.path = self.directory.appendingPathComponent("url.pipe").path
    try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    guard mkfifo(self.path, 0o600) == 0 else {
      try? FileManager.default.removeItem(at: self.directory)
      throw CocoaError(.fileWriteUnknown)
    }
    // Keep our own writer open so EOF does not race the helper's short write.
    let descriptor = Darwin.open(self.path, O_RDWR | O_CLOEXEC)
    guard descriptor >= 0 else {
      try? FileManager.default.removeItem(at: self.directory)
      throw CocoaError(.fileReadUnknown)
    }
    self.reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let gate = self.gate
    self.reader.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      switch gate.append(data) {
      case .scheduleDrain:
        Task { @MainActor in onURLData(gate.drain()) }
      case .overflow, .closed:
        handle.readabilityHandler = nil
      case .accepted:
        break
      }
    }
  }

  func close() {
    self.gate.close()
    self.reader.readabilityHandler = nil
    try? self.reader.close()
    try? FileManager.default.removeItem(at: self.directory)
  }
}
