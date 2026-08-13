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

    let status = try await withThrowingTaskGroup(of: Int32.self) { group in
      group.addTask {
        process.waitUntilExit()
        return process.terminationStatus
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        if process.isRunning { process.terminate() }
        try? await Task.sleep(for: .milliseconds(250))
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        throw UsageProviderError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
      }
      guard let first = try await group.next() else {
        throw UsageProviderError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
      }
      group.cancelAll()
      return first
    }
    let capturedStdout = await stdoutTask.value
    _ = await stderrTask.value
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
