import Foundation
import Testing
@testable import ReserveCore

@Suite
struct ProviderProcessCancellationTests {
  @Test
  func cancellingProviderReadStopsItsProcess() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("should-not-exist")
    let ready = directory.appendingPathComponent("ready")
    let task = Task {
      try await ProcessRunner.output(
        executable: "/bin/sh",
        arguments: ["-c", "trap '' TERM; touch \"$1\"; sleep 1; touch \"$2\"", "test", ready.path, marker.path],
        environment: [:], timeout: .seconds(10))
    }
    for _ in 0..<100 {
      if FileManager.default.fileExists(atPath: ready.path) { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    #expect(FileManager.default.fileExists(atPath: ready.path))
    task.cancel()
    _ = try? await task.value
    try await Task.sleep(for: .milliseconds(1100))
    #expect(!FileManager.default.fileExists(atPath: marker.path))
  }
}
