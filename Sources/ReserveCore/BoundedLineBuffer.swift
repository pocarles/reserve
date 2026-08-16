import Foundation

final class BoundedLineBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var buffer = Data()
  private var discardingOversizedLine = false
  private let maximumBytes: Int

  init(
    maximumBytes: Int = 1_048_576,
    discardingOversizedLine: Bool = false
  ) {
    self.maximumBytes = maximumBytes
    self.discardingOversizedLine = discardingOversizedLine
  }

  func append(
    _ data: Data,
    maximumLines: Int = .max
  ) -> (
    lines: [Data], exceeded: Bool, consumedBytes: Int,
    discardingOversizedLine: Bool
  ) {
    self.lock.lock()
    defer { self.lock.unlock() }
    self.buffer.append(data)

    var lines: [Data] = []
    var consumedBytes = 0
    var exceeded = false
    while lines.count < maximumLines {
      if self.discardingOversizedLine {
        exceeded = true
        guard let newline = self.buffer.firstIndex(of: 0x0A) else {
          consumedBytes += self.buffer.count
          self.buffer.removeAll(keepingCapacity: false)
          break
        }
        consumedBytes += self.buffer.distance(from: self.buffer.startIndex, to: newline) + 1
        self.buffer.removeSubrange(...newline)
        self.discardingOversizedLine = false
        continue
      }

      guard let newline = self.buffer.firstIndex(of: 0x0A) else {
        if self.buffer.count > self.maximumBytes {
          exceeded = true
          self.discardingOversizedLine = true
          consumedBytes += self.buffer.count
          self.buffer.removeAll(keepingCapacity: false)
        }
        break
      }
      let lineLength = self.buffer.distance(from: self.buffer.startIndex, to: newline)
      if lineLength > self.maximumBytes {
        exceeded = true
        consumedBytes += lineLength + 1
        self.buffer.removeSubrange(...newline)
        continue
      }
      let line = self.buffer[..<newline]
      if !line.isEmpty { lines.append(Data(line)) }
      consumedBytes += lineLength + 1
      self.buffer.removeSubrange(...newline)
    }
    return (lines, exceeded, consumedBytes, self.discardingOversizedLine)
  }
}
