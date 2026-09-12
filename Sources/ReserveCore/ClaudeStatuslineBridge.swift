import Foundation

/// Claude Code's documented status-line feed. Only quota fields cross into the
/// cache; paths, session identifiers, prompts, and token details are discarded.
public enum ClaudeStatuslineBridge {
  public static let maximumInputBytes = 65_536
  private static let marker = "reserveStatusline"

  public static func cacheURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Reserve/claude-statusline.json")
  }

  public static func settingsURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
    let root = environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : $0 }
      .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    return root.appendingPathComponent("settings.json")
  }

  @discardableResult
  public static func ingest(_ input: Data, cacheURL: URL, now: Date = Date()) throws -> Bool {
    guard input.count <= maximumInputBytes else { return false }
    let input = try JSONDecoder().decode(Input.self, from: input)
    let windows = input.rateLimits?.windows(now: now) ?? []
    guard !windows.isEmpty else { return false }
    let data = try JSONEncoder().encode(Record(observedAt: now, windows: windows))
    try writePrivate(data, to: cacheURL)
    return true
  }

  public static func read(cacheURL: URL, now: Date = Date()) -> UsageSnapshot? {
    guard let data = BoundedFileReader.read(cacheURL, maximumBytes: 8_192),
      let record = try? JSONDecoder().decode(Record.self, from: data),
      record.observedAt <= now.addingTimeInterval(60),
      now.timeIntervalSince(record.observedAt) <= 7 * 24 * 60 * 60
    else { return nil }
    let windows = record.windows.filter { ($0.resetsAt ?? .distantPast) > now }
    guard !windows.isEmpty else { return nil }
    return UsageSnapshot(provider: .anthropic, windows: windows, fetchedAt: record.observedAt,
      source: "Claude Code status line", checkedAt: now)
  }

  /// Pure transformation so installation can be reviewed and tested without
  /// touching a user's Claude settings. The exact original statusLine survives.
  public static func configuredSettings(_ data: Data, executableURL: URL, cacheURL: URL,
    settingsURL: URL = ClaudeStatuslineBridge.settingsURL()) throws -> Data {
    var settings = try dictionary(data)
    let existingMarker = settings[marker] as? [String: Any]
    if let existingMarker,
      let installed = existingMarker["installedCommand"] as? String,
      (settings["statusLine"] as? [String: Any])?["command"] as? String != installed
    {
      throw UsageProviderError.unavailable("The Claude status line changed. Remove the Reserve connection before connecting it again.")
    }
    let original = existingMarker?["original"] ?? settings["statusLine"] ?? NSNull()
    if !(original is NSNull) {
      guard let line = original as? [String: Any], line["type"] as? String == "command",
        line["command"] is String else {
        throw UsageProviderError.unavailable("This Claude status line cannot be shared with Reserve.")
      }
    }
    let forward = (original as? [String: Any])?["command"] as? String ?? ""
    guard forward.utf8.count <= 16_384 else {
      throw UsageProviderError.unavailable("The Claude status line command is too large to share.")
    }
    let command = [executableURL.path, "--claude-statusline", cacheURL.path,
      settingsURL.path].map(shellQuote).joined(separator: " ")
    settings[marker] = ["version": 1, "original": original, "installedCommand": command]
    var statusLine = original as? [String: Any] ?? [:]
    statusLine["type"] = "command"
    statusLine["command"] = command
    settings["statusLine"] = statusLine
    return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
  }

  public static func restoredSettings(_ data: Data) throws -> Data {
    var settings = try dictionary(data)
    guard let saved = settings[marker] as? [String: Any] else { return data }
    // A later user edit wins. Remove our metadata but never overwrite that edit.
    if let installed = saved["installedCommand"] as? String,
      (settings["statusLine"] as? [String: Any])?["command"] as? String == installed
    {
      if let original = saved["original"], !(original is NSNull) { settings["statusLine"] = original }
      else { settings.removeValue(forKey: "statusLine") }
    }
    settings.removeValue(forKey: marker)
    return try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
  }

  public static func configure(settingsURL: URL, executableURL: URL, cacheURL: URL) throws {
    let data = try settingsData(at: settingsURL)
    try writePrivate(configuredSettings(data, executableURL: executableURL, cacheURL: cacheURL,
      settingsURL: settingsURL), to: settingsURL)
  }

  public static func remove(settingsURL: URL) throws {
    let data = try settingsData(at: settingsURL)
    try writePrivate(restoredSettings(data), to: settingsURL)
  }

  /// Call before creating AppKit or acquiring the normal app instance lock.
  /// No raw status-line payload is stored, logged, or passed in arguments.
  public static func runReceiver(arguments: [String]) async -> Bool {
    guard arguments.count >= 2, arguments[1] == "--claude-statusline" else { return false }
    guard arguments.count == 4 else { return true }
    let cache = URL(fileURLWithPath: arguments[2])
    let settings = URL(fileURLWithPath: arguments[3])
    await Task.detached(priority: .utility) {
      self.receive(cacheURL: cache, settingsURL: settings)
    }.value
    return true
  }

  private static func receive(cacheURL: URL, settingsURL: URL) {
    let input = Capture()
    let readGroup = DispatchGroup()
    readGroup.enter()
    DispatchQueue.global().async {
      input.read(FileHandle.standardInput, maximumBytes: maximumInputBytes)
      readGroup.leave()
    }
    guard readGroup.wait(timeout: .now() + 2) == .success, let data = input.data else { return }
    _ = try? ingest(data, cacheURL: cacheURL)
    guard let settingsData = BoundedFileReader.read(settingsURL, maximumBytes: 1_048_576),
      let settings = try? dictionary(settingsData),
      let saved = settings[marker] as? [String: Any],
      let installed = saved["installedCommand"] as? String,
      (settings["statusLine"] as? [String: Any])?["command"] as? String == installed,
      let original = saved["original"] as? [String: Any],
      let command = original["command"] as? String,
      !command.isEmpty, command.utf8.count <= 16_384
    else { return }
    if let output = forward(input: data, command: command) {
      try? FileHandle.standardOutput.write(contentsOf: output)
    }
  }

  static func forward(input: Data, command: String, timeout: TimeInterval = 3) -> Data? {
    guard input.count <= maximumInputBytes, command.utf8.count <= 16_384 else { return nil }
    let process = Process()
    let stdin = Pipe()
    let stdout = Pipe()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    let completion = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in completion.signal() }
    guard (try? process.run()) != nil else { return nil }
    let output = Capture()
    let outputGroup = DispatchGroup()
    outputGroup.enter()
    DispatchQueue.global().async {
      output.read(stdout.fileHandleForReading, maximumBytes: maximumInputBytes)
      outputGroup.leave()
    }
    DispatchQueue.global().async {
      try? stdin.fileHandleForWriting.write(contentsOf: input)
      try? stdin.fileHandleForWriting.close()
    }
    guard completion.wait(timeout: .now() + timeout) == .success else {
      ProcessRunner.stop(process)
      try? stdin.fileHandleForWriting.close()
      try? stdout.fileHandleForReading.close()
      return nil
    }
    guard outputGroup.wait(timeout: .now() + 0.2) == .success, let result = output.data else {
      try? stdout.fileHandleForReading.close()
      return nil
    }
    return result
  }

  private final class Capture: @unchecked Sendable {
    private let lock = NSLock()
    private var captured: Data?
    var data: Data? { lock.lock(); defer { lock.unlock() }; return captured }
    func read(_ handle: FileHandle, maximumBytes: Int) {
      var result = Data()
      do {
        while let chunk = try handle.read(upToCount: min(8_192, maximumBytes + 1 - result.count)), !chunk.isEmpty {
          result.append(chunk)
          guard result.count <= maximumBytes else { return }
        }
        lock.lock(); captured = result; lock.unlock()
      } catch { return }
    }
  }

  private static func settingsData(at url: URL) throws -> Data {
    guard FileManager.default.fileExists(atPath: url.path) else { return Data("{}".utf8) }
    guard let data = BoundedFileReader.read(url, maximumBytes: 1_048_576) else {
      throw UsageProviderError.unavailable("Claude settings could not be read safely.")
    }
    return data
  }

  private static func dictionary(_ data: Data) throws -> [String: Any] {
    guard data.count <= 1_048_576,
      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw UsageProviderError.invalidResponse("Claude settings must be a JSON object.") }
    return result
  }

  private static func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private static func writePrivate(_ data: Data, to url: URL) throws {
    try BoundedFileReader.writeRestricted(data, to: url)
  }

  private struct Input: Decodable {
    let rateLimits: Limits?
    enum CodingKeys: String, CodingKey { case rateLimits = "rate_limits" }
  }
  private struct Limits: Decodable {
    let fiveHour: Window?
    let sevenDay: Window?
    enum CodingKeys: String, CodingKey { case fiveHour = "five_hour", sevenDay = "seven_day" }
    func windows(now: Date) -> [UsageWindow] {
      [fiveHour?.window(id: "five-hour", label: "5 hours", minutes: 300, now: now),
        sevenDay?.window(id: "weekly", label: "Weekly", minutes: 10080, now: now)].compactMap { $0 }
    }
  }
  private struct Window: Decodable {
    let usedPercentage: Double
    let resetsAt: Double
    enum CodingKeys: String, CodingKey { case usedPercentage = "used_percentage", resetsAt = "resets_at" }
    func window(id: String, label: String, minutes: Int, now: Date) -> UsageWindow? {
      let reset = Date(timeIntervalSince1970: resetsAt)
      guard usedPercentage.isFinite, (0...100).contains(usedPercentage), resetsAt.isFinite,
        reset > now, reset <= now.addingTimeInterval(Double(minutes * 60) + 300)
      else { return nil }
      return UsageWindow(id: id, label: label, usedPercent: usedPercentage,
        windowMinutes: minutes, resetsAt: reset)
    }
  }
  private struct Record: Codable {
    let observedAt: Date
    let windows: [UsageWindow]
  }
}
