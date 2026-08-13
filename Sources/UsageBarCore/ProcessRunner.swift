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

    return try await withThrowingTaskGroup(of: ProcessOutput.self) { group in
      group.addTask {
        process.waitUntilExit()
        let out = stdout.fileHandleForReading.readDataToEndOfFile()
        let err = stderr.fileHandleForReading.readDataToEndOfFile()
        return ProcessOutput(status: process.terminationStatus, stdout: out, stderr: err)
      }
      group.addTask {
        try await Task.sleep(for: timeout)
        if process.isRunning { process.terminate() }
        throw UsageProviderError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
      }
      guard let first = try await group.next() else {
        throw UsageProviderError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
      }
      group.cancelAll()
      guard first.status == 0 else {
        let message = String(data: first.stderr, encoding: .utf8) ?? "exit \(first.status)"
        throw UsageProviderError.processFailed(
          message.trimmingCharacters(in: .whitespacesAndNewlines))
      }
      guard first.stdout.count <= 65_536 else {
        throw UsageProviderError.invalidResponse("process output exceeded 64 KB")
      }
      return String(data: first.stdout, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
  }
}

private struct ProcessOutput: @unchecked Sendable {
  let status: Int32
  let stdout: Data
  let stderr: Data
}
