import Foundation

/// Reads the signed-in Copilot account through the same quota RPC as GitHub's
/// SDK. No conversation is created, resumed, or sent a prompt.
public struct CopilotProvider: UsageProvider {
  /// A Copilot CLI speaking a newer protocol than this Reserve. Only a Reserve
  /// update fixes it, so it is never reported as a Copilot update.
  public static let newerThanSupportedMessage =
    "This Copilot CLI version is newer than Reserve supports. Update Reserve."
  public let id: ProviderID = .copilot
  public static let loginArguments = ["login", "--web-flow"]
  static let runtimeArguments = ["--headless", "--no-auto-update", "--stdio"]
  static let maximumQuotaBytes = 65_536
  private let readQuota: @Sendable () async throws -> Data

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.readQuota = {
      guard let executable = BinaryLocator.find("copilot", environment: environment) else {
        throw UsageProviderError.executableNotFound("Copilot CLI")
      }
      let rpc = try CopilotQuotaProcess(
        executable: executable, arguments: Self.runtimeArguments,
        environment: Self.childEnvironment(environment))
      defer { rpc.shutdown() }
      return try await rpc.readQuota()
    }
  }

  init(readQuota: @escaping @Sendable () async throws -> Data) { self.readQuota = readQuota }

  public func fetch() async throws -> UsageSnapshot {
    try Self.decodeQuota(await self.readQuota())
  }

  /// Reserve follows the account selected in Copilot, rather than an unrelated
  /// CI token inherited from the shell that happened to launch Reserve.
  static func childEnvironment(_ environment: [String: String]) -> [String: String] {
    let allowed = Set(["HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "SHELL"])
    return environment.filter { allowed.contains($0.key) }
  }

  static func decodeQuota(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
    guard data.count <= Self.maximumQuotaBytes,
      let response = try? JSONDecoder().decode(CopilotQuotaResponse.self, from: data),
      response.quotaSnapshots.count <= UsageSnapshot.maximumWindows
    else { throw UsageProviderError.invalidResponse("Copilot quota data was not recognized.") }

    var windows: [UsageWindow] = []
    var details: [UsageDetail] = []
    let knownLabels = ["premium_interactions": "Premium requests", "chat": "Chat", "completions": "Completions"]
    for key in response.quotaSnapshots.keys.sorted() {
      guard let quota = response.quotaSnapshots[key] else { continue }
      guard key.count <= UsageWindow.maximumIdentifierCharacters,
        quota.entitlementRequests.isFinite, quota.entitlementRequests >= -1,
        quota.usedRequests.isFinite, quota.usedRequests >= 0,
        quota.remainingPercentage.isFinite, (0...100).contains(quota.remainingPercentage)
      else { throw UsageProviderError.invalidResponse("Copilot returned an invalid allowance.") }
      // Unlimited products are not a separate 100%-remaining allowance. Keep
      // unknown future quota kinds visible, without guessing their unit or plan.
      let label = knownLabels[key] ?? key.replacingOccurrences(of: "_", with: " ").capitalized
      if quota.isUnlimitedEntitlement || quota.entitlementRequests == -1 {
        details.append(UsageDetail(label, "Unlimited"))
        continue
      }
      if quota.entitlementRequests > 0 {
        details.append(UsageDetail(
          label,
          "\(UsageDetailFormat.number(quota.usedRequests)) of \(UsageDetailFormat.number(quota.entitlementRequests)) used"))
      }
      let reset: Date?
      if let raw = quota.resetDate {
        let date = UsageDateParser.iso8601(raw)
          ?? (raw.count == 10 ? UsageDateParser.iso8601(raw + "T00:00:00Z") : nil)
        guard let parsed = date, parsed > now,
          parsed.timeIntervalSince(now) <= 366 * 24 * 60 * 60
        else { continue }
        reset = parsed
      } else { reset = nil }
      windows.append(UsageWindow(
        id: key, label: label, usedPercent: 100 - quota.remainingPercentage,
        // The API supplies a reset date, not the period's start. Do not assume
        // a 30-day month and turn that assumption into a pace forecast.
        resetsAt: reset))
    }
    guard !windows.isEmpty else {
      throw UsageProviderError.unavailable("Copilot did not return a current, limited allowance.")
    }
    windows.sort { lhs, rhs in
      if lhs.id == "premium_interactions" { return true }
      if rhs.id == "premium_interactions" { return false }
      return lhs.id < rhs.id
    }
    return UsageSnapshot(provider: .copilot, windows: windows, fetchedAt: now,
      source: "Copilot account quota", detailedUsageUnavailable: true,
      details: details.sorted { lhs, rhs in
        // Premium requests lead, matching the meters.
        if lhs.label == "Premium requests" { return rhs.label != "Premium requests" }
        if rhs.label == "Premium requests" { return false }
        return lhs.label < rhs.label
      })
  }
}

private struct CopilotQuotaResponse: Decodable {
  let quotaSnapshots: [String: CopilotQuota]
}

private struct CopilotQuota: Decodable {
  let isUnlimitedEntitlement: Bool
  let entitlementRequests: Double
  let usedRequests: Double
  let remainingPercentage: Double
  let resetDate: String?
}

/// A short-lived, single-consumer Content-Length JSON-RPC connection. Copilot
/// uses this framing; the Codex process uses newline-delimited JSON instead.
final class CopilotQuotaProcess: @unchecked Sendable {
  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  private let errors = Pipe()
  private let continuation: AsyncStream<Data>.Continuation
  private var iterator: AsyncStream<Data>.Iterator
  private var nextID = 0

  init(executable: String, arguments: [String], environment: [String: String]) throws {
    let stream = AsyncStream.makeStream(of: Data.self, bufferingPolicy: .bufferingNewest(8))
    self.continuation = stream.continuation
    self.iterator = stream.stream.makeAsyncIterator()
    self.process.executableURL = URL(fileURLWithPath: executable)
    self.process.arguments = arguments
    self.process.environment = environment
    self.process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
    self.process.standardInput = self.input
    self.process.standardOutput = self.output
    self.process.standardError = self.errors
    try self.process.run()

    let frames = CopilotFrameBuffer()
    let continuation = self.continuation
    let process = self.process
    self.output.fileHandleForReading.readabilityHandler = { handle in
      let bytes = handle.availableData
      guard !bytes.isEmpty else {
        handle.readabilityHandler = nil
        continuation.finish()
        return
      }
      do {
        for frame in try frames.append(bytes) {
          guard case .enqueued = continuation.yield(frame) else {
            throw UsageProviderError.invalidResponse("Copilot produced too much output.")
          }
        }
      } catch {
        handle.readabilityHandler = nil
        ProcessRunner.stop(process)
        continuation.finish()
      }
    }
    self.errors.fileHandleForReading.readabilityHandler = { handle in
      if handle.availableData.isEmpty { handle.readabilityHandler = nil }
    }
  }

  deinit { self.shutdown() }

  func readQuota(timeout: Duration = .seconds(15)) async throws -> Data {
    defer { self.shutdown() }
    return try await withTaskCancellationHandler {
      try await withThrowingTaskGroup(of: Data.self) { group in
        group.addTask { [self] in
          let handshake: Data
          do {
            handshake = try await self.request("connect")
          } catch CopilotRPCError.methodNotFound {
            handshake = try await self.request("ping")
          }
          guard let object = try JSONSerialization.jsonObject(with: handshake) as? [String: Any],
            let version = object["protocolVersion"] as? NSNumber,
            CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 3
          else {
            throw Self.unsupportedProtocolError(
              (try? JSONSerialization.jsonObject(with: handshake) as? [String: Any])?["protocolVersion"])
          }
          let auth = try await self.request("auth.getStatus")
          let status = try JSONDecoder().decode(CopilotAuthStatus.self, from: auth)
          guard status.isAuthenticated else {
            throw UsageProviderError.credentialsNotFound("Sign in to Copilot to see your allowance.")
          }
          return try await self.request("account.getQuota")
        }
        group.addTask {
          try await Task.sleep(for: timeout)
          throw UsageProviderError.timedOut("Copilot usage check")
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
      }
    } onCancel: {
      self.shutdown()
    }
  }

  /// A protocol newer than Reserve speaks cannot be fixed by updating Copilot,
  /// so it is reported as unavailable with the one remedy that helps. An older
  /// or unreadable version still asks for a Copilot update.
  static func unsupportedProtocolError(_ reported: Any?) -> UsageProviderError {
    if let version = reported as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(),
      version.doubleValue > 3
    {
      return .unavailable(CopilotProvider.newerThanSupportedMessage)
    }
    return .updateRequired("This Copilot version is not supported by Reserve yet.")
  }

  private func request(_ method: String) async throws -> Data {
    try Task.checkCancellation()
    self.nextID += 1
    let id = self.nextID
    let payload = try JSONSerialization.data(withJSONObject: [
      "jsonrpc": "2.0", "id": id, "method": method, "params": [:],
    ])
    var framed = Data("Content-Length: \(payload.count)\r\n\r\n".utf8)
    framed.append(payload)
    try self.input.fileHandleForWriting.write(contentsOf: framed)
    while let data = await self.iterator.next() {
      try Task.checkCancellation()
      guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        response["id"] as? Int == id
      else { continue }
      if let error = response["error"] as? [String: Any] {
        let code = error["code"] as? Int
        if code == -32601 {
          if method == "connect" { throw CopilotRPCError.methodNotFound }
          throw UsageProviderError.updateRequired("Update Copilot CLI to read your allowance in Reserve.")
        }
        // Do not echo arbitrary provider messages, which can include account
        // data or request details. Authentication was checked separately.
        throw UsageProviderError.unavailable("Copilot could not read your allowance. Try again shortly.")
      }
      guard let result = response["result"] as? [String: Any] else {
        throw UsageProviderError.invalidResponse("Copilot returned no quota result.")
      }
      return try JSONSerialization.data(withJSONObject: result)
    }
    try Task.checkCancellation()
    throw UsageProviderError.processFailed("Copilot ended before the usage check completed.")
  }

  func shutdown() {
    self.output.fileHandleForReading.readabilityHandler = nil
    self.errors.fileHandleForReading.readabilityHandler = nil
    try? self.input.fileHandleForWriting.close()
    self.continuation.finish()
    ProcessRunner.stop(self.process)
  }
}

private enum CopilotRPCError: Error { case methodNotFound }
private struct CopilotAuthStatus: Decodable { let isAuthenticated: Bool }

final class CopilotFrameBuffer: @unchecked Sendable {
  static let maximumHeaderBytes = 1_024
  private let lock = NSLock()
  private var buffer = Data()
  private var expectedBytes: Int?

  func append(_ bytes: Data) throws -> [Data] {
    self.lock.lock()
    defer { self.lock.unlock() }
    guard bytes.count <= CopilotProvider.maximumQuotaBytes + Self.maximumHeaderBytes,
      self.buffer.count + bytes.count <= 2 * CopilotProvider.maximumQuotaBytes + Self.maximumHeaderBytes
    else { throw UsageProviderError.invalidResponse("Copilot output exceeded its size limit.") }
    self.buffer.append(bytes)
    var frames: [Data] = []
    while true {
      if self.expectedBytes == nil {
        guard let delimiter = self.buffer.range(of: Data("\r\n\r\n".utf8)) else {
          guard self.buffer.count <= Self.maximumHeaderBytes else {
            throw UsageProviderError.invalidResponse("Copilot sent an invalid message header.")
          }
          break
        }
        guard delimiter.lowerBound - self.buffer.startIndex <= Self.maximumHeaderBytes,
          let header = String(data: self.buffer[..<delimiter.lowerBound], encoding: .ascii)
        else { throw UsageProviderError.invalidResponse("Copilot sent an invalid message header.") }
        let lengths = header.components(separatedBy: "\r\n").compactMap { line -> String? in
          let parts = line.split(separator: ":", maxSplits: 1)
          guard parts.count == 2, parts[0].lowercased() == "content-length" else { return nil }
          return parts[1].trimmingCharacters(in: .whitespaces)
        }
        guard lengths.count == 1, let size = Int(lengths[0]),
          (1...CopilotProvider.maximumQuotaBytes).contains(size)
        else { throw UsageProviderError.invalidResponse("Copilot sent an invalid message length.") }
        self.expectedBytes = size
        self.buffer.removeSubrange(..<delimiter.upperBound)
      }
      guard let size = self.expectedBytes, self.buffer.count >= size else { break }
      frames.append(Data(self.buffer.prefix(size)))
      self.buffer.removeFirst(size)
      self.expectedBytes = nil
      guard frames.count <= 8 else {
        throw UsageProviderError.invalidResponse("Copilot produced too many messages.")
      }
    }
    return frames
  }
}
