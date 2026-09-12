import Foundation
import Testing
@testable import ReserveCore

private final class QuotaChangeCounter: @unchecked Sendable {
  private let condition = NSCondition()
  private var value = 0

  func increment() {
    condition.lock()
    value += 1
    condition.broadcast()
    condition.unlock()
  }

  func wait(for count: Int, timeout: TimeInterval) -> Bool {
    condition.lock()
    defer { condition.unlock() }
    let deadline = Date().addingTimeInterval(timeout)
    while value < count {
      if !condition.wait(until: deadline) { return value >= count }
    }
    return true
  }
}

@Suite("Quota file watcher")
struct QuotaFileWatcherTests {
  @Test func atomicReplacementNotifiesAndUnrelatedWritesAndStopDoNot() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("quota.json")
    let changes = QuotaChangeCounter()
    let watcher = try QuotaFileWatcher(cacheURL: cache) { changes.increment() }
    defer { watcher.stop() }
    try Data("first".utf8).write(to: cache, options: .atomic)
    #expect(changes.wait(for: 1, timeout: 3))
    try Data("unrelated".utf8).write(to: directory.appendingPathComponent("another.json"), options: .atomic)
    #expect(!changes.wait(for: 2, timeout: 0.4))
    // Replacing the target inode must still notify the directory watcher.
    try Data("second".utf8).write(to: cache, options: .atomic)
    #expect(changes.wait(for: 2, timeout: 3))
    watcher.stop()
    watcher.stop()
    try Data("third".utf8).write(to: cache, options: .atomic)
    #expect(!changes.wait(for: 3, timeout: 0.4))
  }

  @Test func burstIsDebouncedAndPendingCallbackCanBeStopped() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cache = directory.appendingPathComponent("quota.json")
    let changes = QuotaChangeCounter()
    let watcher = try QuotaFileWatcher(cacheURL: cache) { changes.increment() }
    defer { watcher.stop() }
    for index in 0..<8 { try Data("\(index)".utf8).write(to: cache, options: .atomic) }
    #expect(changes.wait(for: 1, timeout: 3))
    #expect(!changes.wait(for: 2, timeout: 0.4))
    try Data("stop before debounce".utf8).write(to: cache, options: .atomic)
    watcher.stop()
    #expect(!changes.wait(for: 2, timeout: 0.4))
  }
}
