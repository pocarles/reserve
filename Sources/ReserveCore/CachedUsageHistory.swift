import Foundation

/// One civil day of cached usage. `tokens == nil` means the day was not observed.
/// `tokens == 0` is a known quiet day and must stay distinct from a gap.
public struct CachedUsageDay: Codable, Equatable, Sendable {
  /// `yyyy-MM-dd` in the Gregorian calendar and the current time zone, matching
  /// `LocalUsageScanner` day keys so lexical order is chronological order.
  public let day: String
  public let tokens: Int64?
  public let costUSD: Double?
  public let fetchedAt: Date

  public init(day: String, tokens: Int64?, costUSD: Double?, fetchedAt: Date) {
    self.day = CachedUsageHistory.isValidDayKey(day) ? day : ""
    self.tokens = Self.sanitizedTokens(tokens)
    self.costUSD = Self.sanitizedCost(costUSD)
    self.fetchedAt = fetchedAt
  }

  private enum CodingKeys: String, CodingKey {
    case day, tokens, costUSD, fetchedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let day = try container.decode(String.self, forKey: .day)
    let tokens = try container.decodeIfPresent(Int64.self, forKey: .tokens)
    let costUSD = try container.decodeIfPresent(Double.self, forKey: .costUSD)
    let fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    self.init(day: day, tokens: tokens, costUSD: costUSD, fetchedAt: fetchedAt)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.day, forKey: .day)
    try container.encodeIfPresent(self.tokens, forKey: .tokens)
    try container.encodeIfPresent(self.costUSD, forKey: .costUSD)
    try container.encode(self.fetchedAt, forKey: .fetchedAt)
  }

  /// Negative counts are not usage. Non-finite JSON numbers fail `Int64` decode.
  static func sanitizedTokens(_ tokens: Int64?) -> Int64? {
    guard let tokens else { return nil }
    return tokens < 0 ? 0 : tokens
  }

  /// NaN and infinities are treated as unknown, not as a zero charge.
  static func sanitizedCost(_ costUSD: Double?) -> Double? {
    guard let costUSD, costUSD.isFinite else { return nil }
    return costUSD < 0 ? 0 : costUSD
  }
}

/// Per-provider daily cache. Days are stored oldest-first with unique keys.
public struct CachedUsageHistory: Codable, Equatable, Sendable {
  public static let retentionDays = 90

  public let provider: ProviderID
  public let days: [CachedUsageDay]

  public init(provider: ProviderID, days: [CachedUsageDay]) {
    self.provider = provider
    self.days = Self.normalized(days)
  }

  private enum CodingKeys: String, CodingKey {
    case provider, days
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let provider = try container.decode(ProviderID.self, forKey: .provider)
    let days = try container.decode([CachedUsageDay].self, forKey: .days)
    self.init(provider: provider, days: days)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.provider, forKey: .provider)
    try container.encode(self.days, forKey: .days)
  }

  /// Incoming rows replace any stored row with the same civil-day key.
  /// Other days are kept. Invalid keys are dropped. Last write wins.
  /// The result is oldest-first and has one row per day.
  public func merge(_ incoming: [CachedUsageDay]) -> CachedUsageHistory {
    guard !incoming.isEmpty else { return self }
    var byDay = Self.indexed(self.days)
    for day in incoming where Self.isValidDayKey(day.day) {
      byDay[day.day] = day
    }
    return CachedUsageHistory(provider: self.provider, days: Array(byDay.values))
  }

  /// Drops days older than 90 civil days before `now`, and any day after today.
  /// Invalid day keys are dropped. `now`'s own civil day is retained.
  public func prune(now: Date, calendar: Calendar = .current) -> CachedUsageHistory {
    let calendar = Self.civilCalendar(calendar)
    let today = Self.dayKey(for: now, calendar: calendar)
    guard let oldest = Self.dayKey(daysBefore: Self.retentionDays - 1, from: now, calendar: calendar)
    else {
      return CachedUsageHistory(provider: self.provider, days: [])
    }
    let kept = self.days.filter { day in
      Self.isValidDayKey(day.day) && day.day >= oldest && day.day <= today
    }
    return CachedUsageHistory(provider: self.provider, days: kept)
  }

  /// The requested window ending on `now`'s civil day, oldest first.
  /// `periodDays` is clamped to 1...90. Every civil day is present. A gap is a
  /// `CachedUsageDay` with that day's key and nil tokens and cost (`fetchedAt`
  /// is `.distantPast`, not a fetch). A stored zero stays zero.
  /// `coveredDayCount` counts rows whose token count is known, including zero.
  public func slice(
    periodDays: Int, now: Date, calendar: Calendar = .current
  ) -> CachedUsageSlice {
    let calendar = Self.civilCalendar(calendar)
    let count = min(Self.retentionDays, max(1, periodDays))
    let keys = Self.dayKeys(count: count, ending: now, calendar: calendar)
    let byDay = Self.indexed(self.days)
    let rows = keys.map { key -> CachedUsageDay in
      if let sample = byDay[key] {
        return sample
      }
      return CachedUsageDay(day: key, tokens: nil, costUSD: nil, fetchedAt: .distantPast)
    }
    let covered = rows.reduce(into: 0) { count, day in
      if day.tokens != nil { count += 1 }
    }
    return CachedUsageSlice(days: rows, coveredDayCount: covered, requestedDays: count)
  }

  public func slice7(now: Date, calendar: Calendar = .current) -> CachedUsageSlice {
    self.slice(periodDays: 7, now: now, calendar: calendar)
  }

  public func slice30(now: Date, calendar: Calendar = .current) -> CachedUsageSlice {
    self.slice(periodDays: 30, now: now, calendar: calendar)
  }

  public func slice90(now: Date, calendar: Calendar = .current) -> CachedUsageSlice {
    self.slice(periodDays: 90, now: now, calendar: calendar)
  }

  /// Gregorian calendar in the supplied time zone (`.current` by default), so
  /// day keys stay aligned with `LocalUsageScanner.dayKey`.
  static func civilCalendar(_ calendar: Calendar) -> Calendar {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    gregorian.locale = Locale(identifier: "en_US_POSIX")
    return gregorian
  }

  static func dayKey(for date: Date, calendar: Calendar) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  static func dayKeys(count: Int, ending now: Date, calendar: Calendar) -> [String] {
    let start = calendar.startOfDay(for: now)
    return (0..<count).reversed().compactMap { offset in
      calendar.date(byAdding: .day, value: -offset, to: start).map {
        dayKey(for: $0, calendar: calendar)
      }
    }
  }

  static func dayKey(daysBefore offset: Int, from now: Date, calendar: Calendar) -> String? {
    let start = calendar.startOfDay(for: now)
    guard let date = calendar.date(byAdding: .day, value: -offset, to: start) else { return nil }
    return dayKey(for: date, calendar: calendar)
  }

  static func isValidDayKey(_ key: String) -> Bool {
    let bytes = Array(key.utf8)
    guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45 else { return false }
    func digits(_ range: Range<Int>) -> Int? {
      var value = 0
      for byte in bytes[range] {
        guard (48...57).contains(byte) else { return nil }
        value = value * 10 + Int(byte - 48)
      }
      return value
    }
    guard let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10),
      (1...12).contains(month)
    else { return false }
    let lengths = [0, 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
    let length = month == 2 && leap ? 29 : lengths[month]
    return (1...length).contains(day)
  }

  /// Last valid key wins. Invalid keys never enter storage, so later unique-key
  /// lookups cannot trap on a blank or repeated day.
  private static func indexed(_ days: [CachedUsageDay]) -> [String: CachedUsageDay] {
    var byDay: [String: CachedUsageDay] = [:]
    byDay.reserveCapacity(days.count)
    for day in days where isValidDayKey(day.day) {
      byDay[day.day] = day
    }
    return byDay
  }

  /// Last write wins for a repeated day key. Order becomes oldest-first.
  private static func normalized(_ days: [CachedUsageDay]) -> [CachedUsageDay] {
    indexed(days).values.sorted { $0.day < $1.day }
  }
}

public struct CachedUsageSlice: Equatable, Sendable {
  /// One entry per requested civil day, oldest first. `tokens == nil` is a gap.
  public let days: [CachedUsageDay]
  /// Days in `days` whose token count is known, including a known zero.
  public let coveredDayCount: Int
  public let requestedDays: Int
}
