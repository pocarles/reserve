import Foundation
import SQLite3

/// Reads only plan metadata saved by the official desktop app. No Keychain,
/// encrypted session, cookies, or local conversations are accessed.
public struct WindsurfProvider: UsageProvider {
  public static let maximumCacheBytes = 262_144
  public let id: ProviderID = .windsurf
  private let installation: @Sendable () -> WindsurfInstallation?
  private let cacheReader: @Sendable (URL) throws -> Data

  public init() {
    self.installation = { WindsurfInstallation.detect() }
    self.cacheReader = { try WindsurfPlanCache.read(database: $0) }
  }

  init(
    installation: @escaping @Sendable () -> WindsurfInstallation?,
    cacheReader: @escaping @Sendable (URL) throws -> Data
  ) {
    self.installation = installation
    self.cacheReader = cacheReader
  }

  public static func installedApplicationURL() -> URL? { WindsurfInstallation.detect()?.applicationURL }

  public func fetch() async throws -> UsageSnapshot {
    try Task.checkCancellation()
    guard let installation = self.installation() else {
      throw UsageProviderError.executableNotFound("Devin Desktop or Windsurf")
    }
    let data = try self.cacheReader(installation.databaseURL)
    try Task.checkCancellation()
    return try Self.decodeCache(data, source: "\(installation.name == "Devin" ? "Devin Desktop" : installation.name) account cache")
  }

  static func decodeCache(
    _ data: Data, now: Date = Date(), source: String = "Devin Desktop account cache"
  ) throws -> UsageSnapshot {
    guard !data.isEmpty, data.count <= Self.maximumCacheBytes,
      let status = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw Self.malformed() }
    let start = try Self.timestamp(status["startTimestamp"], now: now)
    let end = try Self.timestamp(status["endTimestamp"], now: now)
    if let start, start > now { throw Self.stale() }
    if let end, end <= now { throw Self.stale() }
    if let start, let end, end <= start { throw Self.malformed() }

    var windows: [UsageWindow] = []
    var observationLowerBounds: [Date] = []
    for (name, minutes) in [("daily", 1_440), ("weekly", 10_080)] {
      let hiddenKey = name == "daily" ? "hideDailyQuota" : "hideWeeklyQuota"
      if let hidden = status[hiddenKey] {
        guard let boolean = hidden as? NSNumber,
          CFGetTypeID(boolean) == CFBooleanGetTypeID() else { throw Self.malformed() }
        if boolean.boolValue { continue }
      }
      let remaining = try Self.number(status["\(name)RemainingPercent"] ?? status["\(name)QuotaRemainingPercent"])
      let reset = try Self.timestamp(status["\(name)ResetAtUnix"] ?? status["\(name)QuotaResetAtUnix"], now: now)
      if remaining == nil && reset == nil { continue }
      guard let remaining, (0...100).contains(remaining), let reset else { throw Self.malformed() }
      // Never present an old allowance after its authoritative reset passed.
      guard reset > now else { continue }
      guard reset.timeIntervalSince(now) <= Double(minutes * 60) else { throw Self.malformed() }
      windows.append(UsageWindow(
        id: name, label: name == "daily" ? "Daily" : "Weekly", usedPercent: 100 - remaining,
        windowMinutes: minutes, resetsAt: reset))
      observationLowerBounds.append(reset.addingTimeInterval(-Double(minutes * 60)))
    }
    guard !windows.isEmpty, let observedAfter = observationLowerBounds.max() else { throw Self.stale() }
    let name: String?
    if let value = status["planName"] {
      guard let value = value as? String, value.count <= UsageSnapshot.maximumPlanNameCharacters,
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
      else { throw Self.malformed() }
      name = value.trimmingCharacters(in: .whitespacesAndNewlines)
    } else { name = nil }
    let balance: Int?
    if let micros = try Self.number(status["overageBalanceMicros"]) {
      guard micros >= 0, micros.rounded(.towardZero) == micros,
        micros <= Double(Int64.max / 2) else { throw Self.malformed() }
      balance = Int(micros / 10_000)
    } else { balance = nil }
    return UsageSnapshot(
      provider: .windsurf, planName: name?.isEmpty == false ? name : nil,
      windows: windows,
      // This cache has no observation timestamp. The start of its newest quota
      // is a conservative lower bound, never the database's modification time.
      fetchedAt: observedAfter, source: source, billingRenewsAt: end,
      creditBalanceMinorUnits: balance, observationTimeKnown: false, checkedAt: now)
  }

  private static func number(_ value: Any?) throws -> Double? {
    guard let value else { return nil }
    if let number = value as? NSNumber {
      guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { throw Self.malformed() }
      return number.doubleValue
    }
    guard let string = value as? String, string.count <= 32,
      let number = Double(string), number.isFinite else { throw Self.malformed() }
    return number
  }

  private static func timestamp(_ value: Any?, now: Date) throws -> Date? {
    // Desktop protobuf timestamps use {seconds,nanos}; reset fields use Unix seconds.
    guard let value else { return nil }
    let raw: Any
    if let object = value as? [String: Any] {
      guard let seconds = object["seconds"] else { throw Self.malformed() }
      if let nanos = try Self.number(object["nanos"]) {
        guard nanos >= 0, nanos < 1_000_000_000, nanos.rounded(.towardZero) == nanos else { throw Self.malformed() }
      }
      raw = seconds
    } else { raw = value }
    guard let rawNumber = try Self.number(raw) else { return nil }
    let number = rawNumber >= 100_000_000_000 ? rawNumber / 1_000 : rawNumber
    guard number > 0, number.rounded(.towardZero) == number,
      abs(number - now.timeIntervalSince1970) <= UsageWindow.maximumResetDistance
    else { throw Self.malformed() }
    return Date(timeIntervalSince1970: number)
  }

  private static func malformed() -> UsageProviderError {
    .invalidResponse("Windsurf's saved plan usage is incomplete or malformed. Open Devin Desktop, then check again.")
  }

  private static func stale() -> UsageProviderError {
    // Devin Desktop rewrites this cache only while its Devin Settings panel is
    // open, so once every saved window has passed its reset there is nothing
    // current to show until the user opens that panel again.
    .unavailable("Windsurf's saved usage is older than its last reset. In Devin Desktop, open Devin Settings, then check again in Reserve.")
  }
}

struct WindsurfInstallation: Sendable {
  let name: String
  let applicationURL: URL
  let databaseURL: URL

  static func detect(
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    applicationDirectories: [URL]? = nil
  ) -> Self? {
    for name in ["Devin", "Windsurf"] {
      for directory in applicationDirectories ?? [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
        let application = directory.appendingPathComponent("\(name).app")
        guard Bundle(url: application)?.bundleIdentifier == "com.exafunction.windsurf" else { continue }
        return Self(
          name: name, applicationURL: application,
          databaseURL: home.appendingPathComponent("Library/Application Support/\(name)/User/globalStorage/state.vscdb"))
      }
    }
    return nil
  }
}

enum WindsurfPlanCache {
  static func read(database: URL) throws -> Data {
    var connection: OpaquePointer?
    guard sqlite3_open_v2(database.path, &connection, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
      if let connection { sqlite3_close(connection) }
      throw Self.missing()
    }
    defer { sqlite3_close(connection) }
    sqlite3_busy_timeout(connection, 500)
    sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(WindsurfProvider.maximumCacheBytes))
    var statement: OpaquePointer?
    // Select values only. Account identifiers and secret:// rows never leave SQLite.
    let sql = "SELECT value FROM ItemTable WHERE key GLOB 'windsurf.reactSettings.cachedPlanInfoData:*' LIMIT 2"
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK else { throw Self.missing() }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW,
      sqlite3_column_bytes(statement, 0) > 0,
      sqlite3_column_bytes(statement, 0) <= WindsurfProvider.maximumCacheBytes,
      let bytes = sqlite3_column_blob(statement, 0) else { throw Self.missing() }
    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 0)))
    // Do not guess which account is active when several cached accounts exist.
    guard sqlite3_step(statement) == SQLITE_DONE else {
      throw UsageProviderError.unavailable("Windsurf has multiple saved accounts or its cache is unavailable. Open Devin Desktop to check your active account.")
    }
    return data
  }

  private static func missing() -> UsageProviderError {
    .credentialsNotFound("In Devin Desktop or Windsurf, sign in and open Devin Settings, then choose Check again in Reserve.")
  }
}
