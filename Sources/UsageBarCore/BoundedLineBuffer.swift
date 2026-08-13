import Foundation

final class BoundedLineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private let maximumBytes: Int

  init(maximumBytes: Int = 1_048_576) {
    self.maximumBytes = maximumBytes
  }

  func append(_ data: Data) -> (lines: [Data], exceeded: Bool) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.buffer.append(data)
    guard self.buffer.count <= self.maximumBytes else {
      self.buffer.removeAll(keepingCapacity: false)
      return ([], true)
    }

    var lines: [Data] = []
    while let newline = self.buffer.firstIndex(of: 0x0A) {
      let line = self.buffer[..<newline]
      if !line.isEmpty { lines.append(Data(line)) }
      self.buffer.removeSubrange(...newline)
    }
    return (lines, false)
  }
}
