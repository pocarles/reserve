import Foundation

/// Reads Kimi Code plan limits with a key created in the Kimi Code console.
///
/// The endpoint is unofficial and undocumented; it is the one the Kimi Code
/// CLI reads. Shapes follow CodexBar (checked September 2026):
/// `docs/kimi.md`, `Sources/CodexBarCore/Providers/Kimi/KimiModels.swift`,
/// `KimiUsageSnapshot.swift` and `Tests/CodexBarTests/KimiRatioPoolTests.swift`.
///
/// Two shapes exist and both are read:
/// - counts: a weekly `usage` object and a `limits[]` array of windowed
///   quotas, with `limit`/`used`/`remaining` that may be strings;
/// - ratio pools: `usages.limit_5h`, `limit_7d` and `limit_month_total`, each
///   with `used_ratio` (0–1) and `reset_time`. A ratio pool wins over the count
///   for the same window.
///
/// This is Kimi Code, not the Moonshot open platform: the key and host differ
/// from the Moonshot API account Reserve can also read.
public struct KimiProvider: UsageProvider {
  public let id: ProviderID = .kimi
  public static let endpointHost = "api.kimi.com"
  static let usagePath = "/coding/v1/usages"

  private let loadKey: @Sendable () throws -> String
  private let transport: APIKeyPlanTransport
  private let now: @Sendable () -> Date

  public init(session: URLSession? = nil) {
    self.loadKey = { try PlanKeyKeychain.load(for: .kimi) }
    self.transport = APIKeyPlanTransport(provider: .kimi, host: Self.endpointHost, session: session)
    self.now = Date.init
  }

  init(
    apiKey: String,
    requestHandler: @escaping APIKeyPlanTransport.RequestHandler,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.loadKey = { apiKey }
    self.transport = APIKeyPlanTransport(
      provider: .kimi, host: Self.endpointHost, requestHandler: requestHandler)
    self.now = now
  }

  public func fetch() async throws -> UsageSnapshot {
    let key = try PlanKeyKeychain.normalized(try self.loadKey(), for: .kimi)
    let data = try await self.transport.get(path: Self.usagePath, authorization: "Bearer \(key)")
    return try Self.decode(data, now: self.now())
  }

  // MARK: Decoding

  static let fiveHourMinutes = 5 * 60
  static let weeklyMinutes = 7 * 24 * 60

  static func decode(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
    guard data.count <= APIKeyPlanTransport.maximumResponseBytes,
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { throw UsageProviderError.invalidResponse("Kimi Code usage data was not recognized.") }

    var windows: [UsageWindow] = []
    var details: [UsageDetail] = []
    var covered: Set<Int> = []

    // Ratio pools. Some responses nest them under `usages`; accept the same
    // keys at the top level too, since both have been seen in the wild.
    let pools = (root["usages"] as? [String: Any]) ?? root
    for (key, minutes, label) in [
      ("limit_5h", Self.fiveHourMinutes, "5 hours"),
      ("limit_7d", Self.weeklyMinutes, "Weekly"),
    ] {
      guard let pool = pools[key] as? [String: Any],
        let ratio = APIKeyPlanTransport.number(pool["used_ratio"]), ratio >= 0
      else { continue }
      windows.append(UsageWindow(
        id: key, label: label, usedPercent: ratio * 100, windowMinutes: minutes,
        resetsAt: Self.future(Self.date(pool["reset_time"]), now: now)))
      covered.insert(minutes)
    }
    if let pool = pools["limit_month_total"] as? [String: Any],
      let ratio = APIKeyPlanTransport.number(pool["used_ratio"]), ratio >= 0
    {
      // The month is a subscription cycle, not a fixed length, so no pace is
      // derived from it.
      windows.append(UsageWindow(
        id: "limit_month_total", label: "Monthly total", usedPercent: ratio * 100,
        resetsAt: Self.future(Self.date(pool["reset_time"]), now: now)))
    }

    // Counts: the weekly request quota.
    if !covered.contains(Self.weeklyMinutes), let usage = root["usage"] as? [String: Any],
      let counts = Self.counts(usage)
    {
      windows.append(UsageWindow(
        id: "weekly", label: "Weekly", usedPercent: counts.used / counts.limit * 100,
        windowMinutes: Self.weeklyMinutes,
        resetsAt: Self.future(Self.date(Self.resetValue(usage)), now: now)))
      covered.insert(Self.weeklyMinutes)
      details.append(UsageDetail(
        "Weekly requests",
        "\(UsageDetailFormat.number(counts.used)) of \(UsageDetailFormat.number(counts.limit)) used"))
    }

    // Counts: windowed rate limits, usually 200 requests per 5 hours.
    for raw in ((root["limits"] as? [Any]) ?? []).prefix(8) {
      guard let limit = raw as? [String: Any],
        let window = limit["window"] as? [String: Any],
        let detail = limit["detail"] as? [String: Any],
        let minutes = Self.minutes(window), !covered.contains(minutes),
        let counts = Self.counts(detail)
      else { continue }
      windows.append(UsageWindow(
        id: "limit-\(minutes)", label: AllowanceLabel.window(minutes: minutes),
        usedPercent: counts.used / counts.limit * 100, windowMinutes: minutes,
        resetsAt: Self.future(Self.date(Self.resetValue(detail)), now: now)))
      covered.insert(minutes)
      details.append(UsageDetail(
        "\(AllowanceLabel.detail(minutes: minutes)) requests",
        "\(UsageDetailFormat.number(counts.used)) of \(UsageDetailFormat.number(counts.limit)) used"))
    }

    // Nothing recognizable is an error, never an empty 0% plan.
    guard !windows.isEmpty else {
      throw UsageProviderError.invalidResponse("Kimi Code usage data was not recognized.")
    }
    windows.sort { ($0.windowMinutes ?? .max) < ($1.windowMinutes ?? .max) }
    return UsageSnapshot(
      provider: .kimi, planName: Self.planName(root), windows: windows, fetchedAt: now,
      source: "Kimi Code usage API (unofficial)", detailedUsageUnavailable: true,
      details: details)
  }

  /// Used and limit from a count object. `used` is authoritative; `remaining`
  /// is only trusted when it describes a valid balance. Without either, the
  /// object is skipped rather than read as 0% used.
  static func counts(_ object: [String: Any]) -> (used: Double, limit: Double)? {
    guard let limit = APIKeyPlanTransport.number(object["limit"]), limit > 0 else { return nil }
    if let used = APIKeyPlanTransport.number(object["used"]), used >= 0 { return (used, limit) }
    if let remaining = APIKeyPlanTransport.number(object["remaining"]),
      (0...limit).contains(remaining)
    { return (limit - remaining, limit) }
    return nil
  }

  private static func resetValue(_ object: [String: Any]) -> Any? {
    object["resetTime"] ?? object["resetAt"] ?? object["reset_time"] ?? object["reset_at"]
  }

  static func minutes(_ window: [String: Any]) -> Int? {
    guard let duration = APIKeyPlanTransport.number(window["duration"]),
      duration > 0, duration <= Double(UsageWindow.maximumWindowMinutes)
    else { return nil }
    let perUnit: Int
    switch window["timeUnit"] as? String {
    case "TIME_UNIT_MINUTE": perUnit = 1
    case "TIME_UNIT_HOUR": perUnit = 60
    case "TIME_UNIT_DAY": perUnit = 24 * 60
    default: return nil
    }
    let (minutes, overflow) = Int(duration).multipliedReportingOverflow(by: perUnit)
    return overflow ? nil : minutes
  }

  /// Membership names from Kimi's V1 goods catalog; unknown levels are kept.
  static func planName(_ root: [String: Any]) -> String? {
    guard let user = root["user"] as? [String: Any],
      let membership = user["membership"] as? [String: Any],
      let level = (membership["level"] as? String)?.trimmingCharacters(in: .whitespaces),
      !level.isEmpty, level != "LEVEL_UNSPECIFIED"
    else { return nil }
    if let version = root["version"] as? String, version != "GOODS_VERSION_V1" { return level }
    return switch level {
    case "LEVEL_FREE": "Adagio"
    case "LEVEL_TRIAL": "Andante"
    case "LEVEL_BASIC": "Moderato"
    case "LEVEL_INTERMEDIATE": "Allegretto"
    case "LEVEL_ADVANCED": "Allegro"
    default: level
    }
  }

  /// Kimi sends nanosecond fractions ("…13.716839300Z"), which Foundation's
  /// ISO 8601 parser rejects, so the fraction is cut to milliseconds first.
  static func date(_ value: Any?) -> Date? {
    guard let raw = value as? String, !raw.isEmpty, raw.count <= 64 else { return nil }
    if let date = UsageDateParser.iso8601(raw) { return date }
    guard let dot = raw.firstIndex(of: ".") else { return nil }
    let fraction = raw[raw.index(after: dot)...]
    let digits = fraction.prefix { $0.isNumber }
    guard !digits.isEmpty else { return nil }
    let suffix = fraction.dropFirst(digits.count)
    return UsageDateParser.iso8601(String(raw[..<dot]) + "." + digits.prefix(3) + suffix)
  }

  private static func future(_ date: Date?, now: Date) -> Date? {
    date.flatMap { $0 > now ? $0 : nil }
  }
}
