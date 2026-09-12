import Foundation

/// Provider-reported total tokens. This endpoint does not supply a token-type
/// split or a price, so neither is inferred from its totals.
public struct OpenAIAccountActivity: Codable, Equatable, Sendable {
  public let lifetimeTokens: Int64?
  public let dailyUsageBuckets: [DailyUsage]?

  public init(lifetimeTokens: Int64?, dailyUsageBuckets: [DailyUsage]?) {
    self.lifetimeTokens = lifetimeTokens.flatMap { $0 >= 0 ? $0 : nil }
    self.dailyUsageBuckets = dailyUsageBuckets.map { Array($0.suffix(366)) }
  }

  private enum CodingKeys: String, CodingKey { case summary, lifetimeTokens, dailyUsageBuckets }
  private struct Summary: Decodable { let lifetimeTokens: Int64? }
  private struct Bucket: Decodable { let startDate: String; let tokens: Int64 }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
    let tokens = try container.decodeIfPresent(Int64.self, forKey: .lifetimeTokens)
    // Cache format uses DailyUsage; the provider uses startDate.
    let daily: [DailyUsage]?
    if let cached = try? container.decodeIfPresent([DailyUsage].self, forKey: .dailyUsageBuckets) {
      daily = cached
    } else if let buckets = try container.decodeIfPresent([Bucket].self, forKey: .dailyUsageBuckets) {
      var days: [String: Int64] = [:]
      for bucket in buckets.prefix(732) where bucket.tokens >= 0 {
        guard bucket.startDate.count == 10,
          let date = UsageDateParser.iso8601(bucket.startDate + "T00:00:00Z"),
          date.timeIntervalSince1970.isFinite
        else { continue }
        days[bucket.startDate] = bucket.tokens
      }
      daily = days.keys.sorted().suffix(366).map { DailyUsage(day: $0, tokens: days[$0]!) }
    } else { daily = nil }
    self.init(lifetimeTokens: summary?.lifetimeTokens ?? tokens, dailyUsageBuckets: daily)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(lifetimeTokens, forKey: .lifetimeTokens)
    try container.encodeIfPresent(dailyUsageBuckets, forKey: .dailyUsageBuckets)
  }
}
