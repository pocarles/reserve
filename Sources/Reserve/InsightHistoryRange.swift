import Foundation
import ReserveCore

/// One cached day Insights may chart. Missing days stay absent; a present day
/// with zero tokens is a real zero.
struct InsightHistoryDay: Equatable, Sendable {
  var day: String
  var tokens: Int64?
  var costUSD: Double?
}

struct InsightHistorySeries: Equatable, Sendable {
  var provider: ProviderID
  var days: [InsightHistoryDay]
  /// Days in the selected range that actually have a cached sample.
  var coveredDays: Int
  var requestedDays: Int
  /// False when this provider has no local daily cache. Cursor account history
  /// is not mixed in here.
  var available: Bool
}

enum InsightHistoryRange {
  /// Reads only `published`. Never opens session files and never scans.
  static func series(
    provider: ProviderID,
    days: Int,
    now: Date,
    published: [ProviderID: [InsightHistoryDay]]
  ) -> InsightHistorySeries {
    let supported = ProviderDescriptor.forProvider(provider).capabilities.contains(.localHistory)
    guard supported else {
      return InsightHistorySeries(
        provider: provider, days: [], coveredDays: 0, requestedDays: days, available: false)
    }
    let keys = Self.dayKeys(count: days, now: now)
    let byDay = Dictionary(uniqueKeysWithValues: (published[provider] ?? []).map { ($0.day, $0) })
    let rows = keys.map { key -> InsightHistoryDay in
      if let sample = byDay[key] {
        return InsightHistoryDay(day: key, tokens: sample.tokens, costUSD: sample.costUSD)
      }
      return InsightHistoryDay(day: key, tokens: nil, costUSD: nil)
    }
    let covered = rows.filter { $0.tokens != nil }.count
    return InsightHistorySeries(
      provider: provider, days: rows, coveredDays: covered, requestedDays: days, available: true)
  }

  /// Calendar dates, oldest first, ending today. Future dates are excluded.
  static func dayKeys(count: Int, now: Date, calendar: Calendar = .current) -> [String] {
    let count = min(90, max(1, count))
    let start = calendar.startOfDay(for: now)
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return (0..<count).reversed().compactMap { offset in
      calendar.date(byAdding: .day, value: -offset, to: start).map { formatter.string(from: $0) }
    }
  }
}
