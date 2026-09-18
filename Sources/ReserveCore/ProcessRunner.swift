import Darwin
import Foundation

public enum ProcessRunner {
  /// Stop this launch, including a provider that ignores SIGTERM. The audit
  /// token prevents the delayed signal from reaching a recycled process ID.
  public static func stop(_ process: Process) {
    guard process.isRunning else { return }
    let token = Self.auditToken(for: process.processIdentifier)
    guard process.isRunning else { return }
    guard let token else {
      process.terminate()
      return
    }
    Self.signal(token, SIGTERM)
    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(250)) {
      Self.signal(token, SIGKILL)
    }
  }

  static func output(
    executable: String,
    arguments: [String],
    environment: [String: String],
    standardInput: FileHandle? = nil,
    timeout: Duration = .seconds(3)
  ) async throws -> String {
    let result = try await Self.run(
      executable: executable, arguments: arguments, environment: environment,
      standardInput: standardInput, timeout: timeout)
    guard result.status == 0 else {
      throw UsageProviderError.processFailed(
        "\(URL(fileURLWithPath: executable).lastPathComponent) exited with status \(result.status)."
      )
    }
    guard !result.stdoutExceeded else {
      throw UsageProviderError.invalidResponse("process output exceeded 64 KB")
    }
    return String(data: result.stdout, encoding: .utf8)?
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
  }

  /// The completed launch, whatever its exit status. `output` treats a
  /// non-zero exit as a failure; a caller that has to tell a signed-out helper
  /// from a broken one reads the status and the bounded stderr itself.
  struct Result: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    let stdoutExceeded: Bool
  }

  static func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    standardInput: FileHandle? = nil,
    currentDirectory: URL? = nil,
    timeout: Duration = .seconds(3),
    maximumStdoutBytes: Int = 65_536,
    maximumStderrBytes: Int = 0
  ) async throws -> Result {
    try Task.checkCancellation()
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = environment
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    // A helper that prompts on stdin must not inherit Reserve's own input and
    // wait forever for a line that never arrives.
    if let standardInput { process.standardInput = standardInput }
    process.standardOutput = stdout
    process.standardError = stderr
    let deadline = ProcessDeadlineState()
    let events = AsyncStream.makeStream(
      of: ProcessEvent.self,
      bufferingPolicy: .bufferingNewest(4))
    process.terminationHandler = { terminatedProcess in
      deadline.noteProcessTerminated()
      events.continuation.yield(.terminated(terminatedProcess.terminationStatus))
    }
    try process.run()
    defer {
      // A cancelled refresh must not leave a provider or macOS permission
      // helper waiting after its connection window has been dismissed.
      if Task.isCancelled {
        Self.stop(process)
        try? stdout.fileHandleForReading.close()
        try? stderr.fileHandleForReading.close()
      }
    }
    let processIdentifier = process.processIdentifier
    // A very short-lived command can exit before its audit token is available.
    // That remains a normal completion path. Without an immutable token we
    // never fall back to signalling a bare, potentially recycled numeric PID.
    let auditTokenCandidate = Self.auditToken(for: processIdentifier)
    // Check Foundation's launch state *after* acquisition. If the original was
    // already reaped while the PID was recycled, discard the candidate rather
    // than retaining the replacement process's token.
    let processAuditToken = process.isRunning ? auditTokenCandidate : nil

    // Blocking pipe reads must not occupy Swift cooperative executor threads.
    // Cancellation and deadlines need those threads even on a small Mac.
    DispatchQueue.global().async {
      events.continuation.yield(
        .stdout(Self.capture(stdout.fileHandleForReading, maximumBytes: maximumStdoutBytes)))
    }
    DispatchQueue.global().async {
      events.continuation.yield(
        .stderr(Self.capture(stderr.fileHandleForReading, maximumBytes: maximumStderrBytes)))
    }

    // The deadline remains armed until both pipes drain. A child spawned by the
    // CLI can inherit stdout and keep it open after the parent exits; closing
    // our read ends at the deadline guarantees capture still terminates.
    let timeoutTask = Task.detached {
      do {
        try await Task.sleep(for: timeout)
      } catch {
        return
      }
      guard deadline.beginTimeout() else { return }
      // Signal the captured process identity directly. `Process.terminate()`
      // can mark its internal state as stopped before a SIGTERM-ignoring child
      // has actually exited on macOS 15.
      if let processAuditToken {
        if deadline.shouldSignalProcess {
          Self.signal(processAuditToken, SIGTERM)
        }
        try? await Task.sleep(for: .milliseconds(250))
        // The audit token remains bound to this launch even if macOS recycles
        // its numeric PID before the delayed escalation.
        if deadline.shouldSignalProcess {
          Self.signal(processAuditToken, SIGKILL)
        }
      }
      try? stdout.fileHandleForReading.close()
      try? stderr.fileHandleForReading.close()
      events.continuation.yield(.timedOut)
    }

    var status: Int32?
    var capturedStdout: CapturedOutput?
    var capturedStderr: CapturedOutput?
    var timedOut = false
    eventLoop: for await event in events.stream {
      switch event {
      case .terminated(let terminationStatus):
        status = terminationStatus
      case .stdout(let output):
        capturedStdout = output
      case .stderr(let output):
        capturedStderr = output
      case .timedOut:
        timedOut = true
        break eventLoop
      }
      if status != nil, capturedStdout != nil, capturedStderr != nil, deadline.finish() {
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
    return Result(
      status: status, stdout: capturedStdout.data, stderr: capturedStderr?.data ?? Data(),
      stdoutExceeded: capturedStdout.exceeded)
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

  /// Captures the kernel audit token, whose PID-version field remains unique
  /// even after the numeric PID is recycled.
  private static func auditToken(for processIdentifier: pid_t) -> audit_token_t? {
    var taskName = mach_port_name_t()
    guard task_name_for_pid(mach_task_self_, processIdentifier, &taskName) == KERN_SUCCESS else {
      return nil
    }
    defer { mach_port_deallocate(mach_task_self_, taskName) }
    var token = audit_token_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<audit_token_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &token) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(taskName, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? token : nil
  }

  private static func signal(_ auditToken: audit_token_t, _ signal: Int32) {
    var token = auditToken
    _ = proc_signal_with_audittoken(&token, signal)
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
  private var processTerminated = false

  var shouldSignalProcess: Bool {
    self.lock.lock()
    defer { self.lock.unlock() }
    return !self.processTerminated
  }

  func noteProcessTerminated() {
    self.lock.lock()
    self.processTerminated = true
    self.lock.unlock()
  }

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
