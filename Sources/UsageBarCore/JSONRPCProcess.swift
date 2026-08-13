import Foundation

final class JSONRPCProcess: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private let lineStream: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  private let writeLock = NSLock()
  private var nextID = 1

  init(executable: String, arguments: [String], environment: [String: String]) throws {
    var streamContinuation: AsyncStream<Data>.Continuation!
    self.lineStream = AsyncStream<Data> { streamContinuation = $0 }
    self.continuation = streamContinuation

    self.process.executableURL = URL(fileURLWithPath: executable)
    self.process.arguments = arguments
    self.process.environment = environment
    self.process.standardInput = self.input
    self.process.standardOutput = self.output
    self.process.standardError = self.errors

    do {
      try self.process.run()
    } catch {
      throw UsageProviderError.processFailed(
        "Could not start \(URL(fileURLWithPath: executable).lastPathComponent): \(error.localizedDescription)"
      )
    }

    let lineBuffer = BoundedLineBuffer()
    let process = self.process
    let continuation = self.continuation
    self.output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        continuation.finish()
        return
      }
      let result = lineBuffer.append(data)
      if result.exceeded {
        handle.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        continuation.finish()
        return
      }
      for line in result.lines {
        continuation.yield(line)
      }
    }

    self.errors.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      if data.isEmpty {
        handle.readabilityHandler = nil
        return
      }
    }
  }

  deinit {
    self.shutdown()
  }

  func request(
    method: String,
    params: [String: Any] = [:],
    timeout: Duration = .seconds(5),
    includeJSONRPCVersion: Bool = false,
    unescapeSlashes: Bool = false
  ) async throws -> [String: Any] {
    let id = self.reserveID()
    var payload: [String: Any] = ["id": id, "method": method, "params": params]
    if includeJSONRPCVersion { payload["jsonrpc"] = "2.0" }
    try self.send(payload, unescapeSlashes: unescapeSlashes)

    return try await withThrowingTaskGroup(of: SendableJSON.self) { group in
      group.addTask { [self] in
        while true {
          let message = try await self.readMessage()
          guard self.integerID(message["id"]) == id else { continue }
          if let error = message["error"] as? [String: Any] {
            let text =
              (error["message"] as? String)
              ?? (error["data"] as? String)
              ?? "unknown JSON-RPC error"
            throw UsageProviderError.processFailed(String(text.prefix(512)))
          }
          return SendableJSON(value: message)
        }
      }
      group.addTask { [weak self] in
        try await Task.sleep(for: timeout)
        self?.shutdown()
        throw UsageProviderError.timedOut(method)
      }
      guard let first = try await group.next() else {
        throw UsageProviderError.timedOut(method)
      }
      group.cancelAll()
      return first.value
    }
  }

  func notify(method: String, params: [String: Any] = [:]) throws {
    try self.send(["method": method, "params": params])
  }

  func decodeResult<T: Decodable>(_ type: T.Type, from message: [String: Any]) throws -> T {
    guard let result = message["result"] else {
      throw UsageProviderError.invalidResponse("missing JSON-RPC result")
    }
    let data = try JSONSerialization.data(withJSONObject: result)
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw UsageProviderError.invalidResponse(error.localizedDescription)
    }
  }

  func shutdown() {
    self.output.fileHandleForReading.readabilityHandler = nil
    self.errors.fileHandleForReading.readabilityHandler = nil
    try? self.input.fileHandleForWriting.close()
    if self.process.isRunning {
      self.process.terminate()
      let process = self.process
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
      }
    }
    self.continuation.finish()
  }

  private func reserveID() -> Int {
    self.writeLock.lock()
    defer { self.writeLock.unlock() }
    defer { self.nextID += 1 }
    return self.nextID
  }

  private func send(_ payload: [String: Any], unescapeSlashes: Bool = false) throws {
    var data = try JSONSerialization.data(withJSONObject: payload)
    if unescapeSlashes,
      let text = String(data: data, encoding: .utf8)?.replacingOccurrences(of: "\\/", with: "/"),
      let normalized = text.data(using: .utf8)
    {
      data = normalized
    }
    data.append(0x0A)
    self.writeLock.lock()
    defer { self.writeLock.unlock() }
    do {
      try self.input.fileHandleForWriting.write(contentsOf: data)
    } catch {
      throw UsageProviderError.processFailed(
        "Could not write to provider process: \(error.localizedDescription)")
    }
  }

  private func readMessage() async throws -> [String: Any] {
    for await line in self.lineStream {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
        continue
      }
      return object
    }
    throw UsageProviderError.processFailed("Provider process closed unexpectedly.")
  }

  private func integerID(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    if let value = value as? NSNumber { return value.intValue }
    return nil
  }
}

private struct SendableJSON: @unchecked Sendable {
  let value: [String: Any]
}
