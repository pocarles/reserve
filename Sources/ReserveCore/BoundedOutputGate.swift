import Foundation

/// Thread-safe byte budget and single-drain coalescing for callback-driven
/// subprocess output. The producer can never enqueue more than `maximumBytes`
/// or schedule more than one consumer drain at a time.
public final class BoundedOutputGate: @unchecked Sendable {
  public enum AppendResult: Equatable, Sendable {
    case scheduleDrain
    case accepted
    case overflow
    case closed
  }

  private let lock = NSLock()
  private let maximumBytes: Int
  private var acceptedBytes = 0
  private var buffer = Data()
  private var drainScheduled = false
  private var isClosed = false

  public init(maximumBytes: Int) {
    self.maximumBytes = max(0, maximumBytes)
  }

  public func append(_ data: Data) -> AppendResult {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard !self.isClosed else { return .closed }
    guard data.count <= self.maximumBytes - self.acceptedBytes else {
      self.isClosed = true
      self.buffer.removeAll(keepingCapacity: false)
      return .overflow
    }
    self.acceptedBytes += data.count
    self.buffer.append(data)
    guard !self.drainScheduled else { return .accepted }
    self.drainScheduled = true
    return .scheduleDrain
  }

  public func drain() -> Data {
    self.lock.lock()
    defer { self.lock.unlock() }
    let data = self.buffer
    self.buffer.removeAll(keepingCapacity: true)
    self.drainScheduled = false
    return data
  }

  public func close() {
    self.lock.lock()
    self.isClosed = true
    self.buffer.removeAll(keepingCapacity: false)
    self.lock.unlock()
  }
}
