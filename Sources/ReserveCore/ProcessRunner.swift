import Darwin
import Foundation

enum ProcessRunner {
  static func output(
    executable: String,
    arguments: [String],
    environment: [String: String],
    timeout: Duration = .seconds(3)
  ) async throws -> String {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    process.standardOutput = stdout
    process.standardError = stderr
    try process.run()

    let stdoutTask = Task.detached {
      Self.capture(stdout.fileHandleForReading, maximumBytes: 65_536)
    }
    let stderrTask = Task.detached {
      Self.capture(stderr.fileHandleForReading, maximumBytes: 0)
    }

    // The deadline remains armed until both pipes drain. A child spawned by the
    // CLI can inherit stdout and keep it open after the parent exits; closing
    // our read ends at the deadline guarantees capture still terminates.
    let deadline = ProcessDeadlineState()
    let timeoutTask = Task.detached {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      deadline.trigger()
      if process.isRunning { process.terminate() }
      try? await Task.sleep(for: .milliseconds(250))
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
    }
    let status = await Task.detached {
      process.waitUntilExit()
      return process.terminationStatus
    }.value
    let capturedStdout = await stdoutTask.value
    _ = await stderrTask.value
    timeoutTask.cancel()
    guard !deadline.wasTriggered else {
      throw UsageProviderError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
    }
    guard status == 0 else {
      throw UsageProviderError.processFailed(
        "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(status)."
      )
    }
    guard !capturedStdout.exceeded else {
      throw UsageProviderError.invalidResponse("process output exceeded 64 KB")
    }
    return String(data: capturedStdout.data, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  private static func capture(_ handle: FileHandle, maximumBytes: Int) -> CapturedOutput {
    var data = Data()
    var exceeded = false
    while true {
      guard let chunk = try? handle.read(upToCount: 8192), !chunk.isEmpty else { break }
      if data.count + chunk.count <= maximumBytes {
        data.append(chunk)
      } else {
        exceeded = true
      }
    }
    return CapturedOutput(data: data, exceeded: exceeded)
  }
}

private struct CapturedOutput: Sendable {
  let data: Data
  let exceeded: Bool
}

private final class ProcessDeadlineState: @unchecked Sendable {
  private let lock = NSLock()
  private var triggered = false

  var wasTriggered: Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return self.triggered
  }

  func trigger() {
    self.lock.lock()
    self.triggered = true
    self.lock.unlock()
  }
}
