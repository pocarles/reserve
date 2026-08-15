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
    let events = AsyncStream.makeStream(
      of: ProcessEvent.self,
      bufferingPolicy: .bufferingNewest(4))
    process.terminationHandler = { terminatedProcess in
      events.continuation.yield(.terminated(terminatedProcess.terminationStatus))
    }
    try process.run()
    let processIdentifier = process.processIdentifier

    Task.detached {
      events.continuation.yield(
        .stdout(Self.capture(stdout.fileHandleForReading, maximumBytes: 65_536)))
    }
    Task.detached {
      events.continuation.yield(
        .stderr(Self.capture(stderr.fileHandleForReading, maximumBytes: 0)))
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
      guard deadline.beginTimeout() else { return }
      // Signal the captured PID directly. `Process.terminate()` can mark its
      // internal state as stopped before a SIGTERM-ignoring child has actually
      // exited, which can leave Foundation's synchronous waiter blocked on
      // macOS 15.
      kill(processIdentifier, SIGTERM)
      try? await Task.sleep(for: .milliseconds(250))
      // Escalate against the same captured PID regardless; an already-exited
      // process simply returns ESRCH.
      kill(processIdentifier, SIGKILL)
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      events.continuation.yield(.timedOut)
    }

    var status: Int32?
    var capturedStdout: CapturedOutput?
    var capturedStderr = false
    var timedOut = false
    eventLoop: for await event in events.stream {
      switch event {
      case .terminated(let terminationStatus):
        status = terminationStatus
      case .stdout(let output):
        capturedStdout = output
      case .stderr:
        capturedStderr = true
      case .timedOut:
        timedOut = true
        break eventLoop
      }
      if status != nil, capturedStdout != nil, capturedStderr, deadline.finish() {
        break eventLoop
      }
    }
    timeoutTask.cancel()
    events.continuation.finish()
    guard !timedOut else {
      throw UsageProviderError.timedOut(URL(fileURLWithPath: executable).lastPathComponent)
    }
    guard let status, let capturedStdout else {
      throw UsageProviderError.processFailed(
        "\(URL(fileURLWithPath: executable).lastPathComponent) ended without a complete result."
      )
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

private enum ProcessEvent: Sendable {
  case terminated(Int32)
  case stdout(CapturedOutput)
  case stderr(CapturedOutput)
  case timedOut
}

private final class ProcessDeadlineState: @unchecked Sendable {
  private let lock = NSLock()
  private enum State {
    case running
    case finished
    case timedOut
  }
  private var state = State.running

  func beginTimeout() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard self.state == .running else { return false }
    self.state = .timedOut
    return true
  }

  func finish() -> Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard self.state == .running else { return self.state == .finished }
    self.state = .finished
    return true
  }
}
