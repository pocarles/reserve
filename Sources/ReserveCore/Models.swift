import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
  case openAI
  case anthropic
  case grok

  public var id: String { self.rawValue }

  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .grok: "Grok"
    }
  }

}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
  public static let maximumIdentifierCharacters = 512
  public static let maximumLabelCharacters = 96
  public static let maximumWindowMinutes = 366 * 24 * 60
  public static let maximumResetDistance: TimeInterval = 10 * 366 * 24 * 60 * 60
  public let id: String
  public let label: String
  public let usedPercent: Double
  public let windowMinutes: Int?
  public let resetsAt: Date?

  /// Component shares describe part of a larger allowance rather than an
  /// independently renewable quota, so they must not raise their own alerts.
  public var isComponentShare: Bool {
    self.label.localizedCaseInsensitiveContains("share")
  }

  public init(
    id: String,
    label: String,
    usedPercent: Double,
    windowMinutes: Int? = nil,
    resetsAt: Date? = nil
  ) {
    self.id = String(id.prefix(Self.maximumIdentifierCharacters))
    self.label = String(label.prefix(Self.maximumLabelCharacters))
    self.usedPercent = usedPercent.isFinite ? min(100, max(0, usedPercent)) : 0
    self.windowMinutes = windowMinutes.flatMap {
      (1...Self.maximumWindowMinutes).contains($0) ? $0 : nil
    }
    self.resetsAt = resetsAt.flatMap { value in
      let interval = value.timeIntervalSinceNow
      return value.timeIntervalSinceReferenceDate.isFinite && interval.isFinite
        && abs(interval) <= Self.maximumResetDistance ? value : nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case id, label, usedPercent, windowMinutes, resetsAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      label: try container.decode(String.self, forKey: .label),
      usedPercent: try container.decode(Double.self, forKey: .usedPercent),
      windowMinutes: try container.decodeIfPresent(Int.self, forKey: .windowMinutes),
      resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: .id)
    try container.encode(self.label, forKey: .label)
    try container.encode(self.usedPercent, forKey: .usedPercent)
    try container.encodeIfPresent(self.windowMinutes, forKey: .windowMinutes)
    try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
  }
}

public struct UsagePaceProjection: Equatable, Sendable {
  /// A small neutral band prevents normal sampling noise from flipping a plan
  /// between reserve and deficit. This is the sole pace boundary used by the
  /// popover, menu bar, notifications, and tests.
  public static let onPaceTolerancePercent = 2.0

  public enum Position: Equatable, Sendable {
    case reserve
    case deficit
    case onPace
  }

  public let position: Position
  public let variancePercent: Double
  public let projectedExhaustionAt: Date?
  public let projectedRemainingPercent: Double?
  /// How far through the allowance window the clock has travelled. Exposed so
  /// the interface can mark the on-pace position without re-deriving it.
  public let elapsedPercent: Double

  public static func calculate(for window: UsageWindow, now: Date = Date())
    -> UsagePaceProjection?
  {
    guard let minutes = window.windowMinutes, minutes > 0,
      let reset = window.resetsAt, reset > now
    else { return nil }
    let duration = TimeInterval(minutes) * 60
    let start = reset.addingTimeInterval(-duration)
    let elapsed = now.timeIntervalSince(start)
    guard elapsed > 0 else { return nil }
    let elapsedFraction = min(1, elapsed / duration)
    // Very early projections swing wildly after a single request. Wait until at
    // least 1% of the allowance window has elapsed before presenting a pace.
    guard elapsedFraction >= 0.01 else { return nil }

    let usedFraction = min(1, max(0, window.usedPercent / 100))
    let signedVariance = (elapsedFraction - usedFraction) * 100
    let tolerance = Self.onPaceTolerancePercent
    let position: Position =
      if signedVariance > tolerance {
        .reserve
      } else if signedVariance < -tolerance {
        .deficit
      } else {
        .onPace
      }

    let projectedUsage = usedFraction == 0 ? 0 : usedFraction / elapsedFraction
    let projectedRemaining = max(0, min(100, (1 - projectedUsage) * 100))
    let projectedExhaustion: Date?
    if usedFraction > 0 {
      let exhaustion = start.addingTimeInterval(elapsed / usedFraction)
      projectedExhaustion = exhaustion < reset ? max(exhaustion, now) : nil
    } else {
      projectedExhaustion = nil
    }

    return UsagePaceProjection(
      position: position,
      variancePercent: abs(signedVariance),
      projectedExhaustionAt: projectedExhaustion,
      projectedRemainingPercent: projectedRemaining,
      elapsedPercent: elapsedFraction * 100)
  }
}

/// Reserve's factual interpretation of a limit. Capacity remaining is kept on
/// `UsageWindow`; this type describes pace, freshness, and availability only.
public enum UsagePaceState: Equatable, Sendable {
  case reserve(percent: Double)
  case onPace
  case deficit(percent: Double)
  case exhausted
  case stale
  case unknown

  /// How old a snapshot may be before its numbers stop counting as current.
  /// Cards, headlines, and stale-data notifications all use this one value.
  public static let stalenessLimit: TimeInterval = 30 * 60

  public static func calculate(
    for window: UsageWindow?,
    fetchedAt: Date?,
    hasError: Bool = false,
    now: Date = Date(),
    stalenessLimit: TimeInterval = UsagePaceState.stalenessLimit
  ) -> UsagePaceState {
    guard let window else { return .unknown }
    if hasError || fetchedAt.map({ now.timeIntervalSince($0) > stalenessLimit }) == true {
      return .stale
    }
    if window.usedPercent >= 99.5 { return .exhausted }
    guard let projection = UsagePaceProjection.calculate(for: window, now: now) else {
      return .unknown
    }
    switch projection.position {
    case .reserve: return .reserve(percent: projection.variancePercent)
    case .onPace: return .onPace
    case .deficit: return .deficit(percent: projection.variancePercent)
    }
  }
}

public struct UsageSnapshot: Codable, Equatable, Sendable, Identifiable {
  public static let maximumWindows = 32
  public static let maximumPlanNameCharacters = 96
  public static let maximumSourceCharacters = 160
  public var id: ProviderID { self.provider }
  public let provider: ProviderID
  public let planName: String?
  public let windows: [UsageWindow]
  public let fetchedAt: Date
  public let source: String
  public let includedSpend: IncludedSpend?
  public let billingRenewsAt: Date?

  public init(
    provider: ProviderID,
    planName: String? = nil,
    windows: [UsageWindow],
    fetchedAt: Date = Date(),
    source: String,
    includedSpend: IncludedSpend? = nil,
    billingRenewsAt: Date? = nil
  ) {
    self.provider = provider
    self.planName = planName.map { String($0.prefix(Self.maximumPlanNameCharacters)) }
    self.windows = Array(windows.prefix(Self.maximumWindows))
    self.fetchedAt = fetchedAt
    self.source = String(source.prefix(Self.maximumSourceCharacters))
    self.includedSpend = includedSpend
    self.billingRenewsAt = billingRenewsAt
  }

  private enum CodingKeys: String, CodingKey {
    case provider, planName, windows, fetchedAt, source, includedSpend, billingRenewsAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      provider: try container.decode(ProviderID.self, forKey: .provider),
      planName: try container.decodeIfPresent(String.self, forKey: .planName),
      windows: try container.decode([UsageWindow].self, forKey: .windows),
      fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
      source: try container.decode(String.self, forKey: .source),
      includedSpend: try container.decodeIfPresent(IncludedSpend.self, forKey: .includedSpend),
      billingRenewsAt: try container.decodeIfPresent(Date.self, forKey: .billingRenewsAt))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.provider, forKey: .provider)
    try container.encodeIfPresent(self.planName, forKey: .planName)
    try container.encode(self.windows, forKey: .windows)
    try container.encode(self.fetchedAt, forKey: .fetchedAt)
    try container.encode(self.source, forKey: .source)
    try container.encodeIfPresent(self.includedSpend, forKey: .includedSpend)
    try container.encodeIfPresent(self.billingRenewsAt, forKey: .billingRenewsAt)
  }

  public var highestUsedPercent: Double? {
    self.windows.map(\.usedPercent).max()
  }

  /// Some provider refresh endpoints omit stable account metadata even when
  /// their quota data is current. Keep the last reported plan label until the
  /// provider supplies a replacement; usage, resets and spend remain live.
  public func withFallbackPlanName(_ fallback: String?) -> UsageSnapshot {
    guard self.planName == nil, let fallback, !fallback.isEmpty else { return self }
    return UsageSnapshot(
      provider: self.provider,
      planName: fallback,
      windows: self.windows,
      fetchedAt: self.fetchedAt,
      source: self.source,
      includedSpend: self.includedSpend,
      billingRenewsAt: self.billingRenewsAt)
  }
}

public struct IncludedSpend: Codable, Equatable, Sendable {
  public let label: String
  public let usedMinorUnits: Int
  public let limitMinorUnits: Int
  public let currencyCode: String

  public init(
    label: String,
    usedMinorUnits: Int,
    limitMinorUnits: Int,
    currencyCode: String = "USD"
  ) {
    self.label = label
    self.usedMinorUnits = max(0, usedMinorUnits)
    self.limitMinorUnits = max(0, limitMinorUnits)
    self.currencyCode = currencyCode
  }
}

public protocol UsageProvider: Sendable {
  var id: ProviderID { get }
  func fetch() async throws -> UsageSnapshot
}

public enum UsageProviderError: LocalizedError, Sendable, Equatable {
  case executableNotFound(String)
  case credentialsNotFound(String)
  case keychainConsentRequired
  case unauthorized(String)
  case rateLimited(retryAt: Date?)
  case timedOut(String)
  case invalidResponse(String)
  case unavailable(String)
  case processFailed(String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let name): "\(name) is not installed or could not be found."
    case .credentialsNotFound(let message): message
    case .keychainConsentRequired:
      "Claude is ready. Choose Show limits to add your plan limits."
    case .unauthorized(let message): message
    case .rateLimited(let retryAt):
      if let retryAt {
        "Rate limited until \(retryAt.formatted(date: .omitted, time: .shortened))."
      } else {
        "The provider temporarily rate limited usage checks."
      }
    case .timedOut(let operation): "\(operation) timed out."
    case .invalidResponse(let message): "Invalid provider response: \(message)"
    case .unavailable(let message): message
    case .processFailed(let message): message
    }
  }
}
