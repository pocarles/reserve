import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
  case openAI
  case anthropic
  case grok
  case cursor
  case copilot
  // Appended so the persisted raw values of earlier providers never shift.
  case zai
  case kimi

  public var id: String { self.rawValue }

  public var displayName: String {
    ProviderDescriptor.forProvider(self).displayName
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

  /// Model-scoped limits (Claude's "Fable weekly", Codex's "GPT-5 · Weekly")
  /// cap one model inside the plan's own allowance, so they never stand in for
  /// the plan itself.
  public var isModelScoped: Bool {
    self.label.lowercased().hasSuffix(" weekly") || self.label.contains(" · ")
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
    // least 10% of the allowance window has elapsed before presenting a pace.
    guard elapsedFraction >= 0.10 else { return nil }

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
    if let reset = window.resetsAt, reset <= now { return .stale }
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

/// One provider fact that only appears in a card's expanded details, such as
/// the signed-in account or a credit balance. Providers phrase the value;
/// the dashboard shows it as a plain label and value.
public struct UsageDetail: Codable, Equatable, Sendable {
  public static let maximumCount = 16
  public static let maximumLabelCharacters = 40
  public static let maximumValueCharacters = 120
  public let label: String
  public let value: String
  /// Identifies a person (email, organization). Shown, but never written to
  /// Reserve's snapshot cache; it returns with the next refresh.
  public let isPersonal: Bool

  public init(_ label: String, _ value: String, isPersonal: Bool = false) {
    self.isPersonal = isPersonal
    self.label = String(label.trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(Self.maximumLabelCharacters))
    self.value = String(value.trimmingCharacters(in: .whitespacesAndNewlines)
      .prefix(Self.maximumValueCharacters))
  }

  private enum CodingKeys: String, CodingKey { case label, value }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      try container.decode(String.self, forKey: .label),
      try container.decode(String.self, forKey: .value))
  }

  /// Drops empty entries and repeated labels, keeping the first of each.
  public static func sanitized(_ details: [UsageDetail]) -> [UsageDetail] {
    var seen: Set<String> = []
    return Array(
      details.filter { !$0.label.isEmpty && !$0.value.isEmpty && seen.insert($0.label).inserted }
        .prefix(Self.maximumCount))
  }
}

/// Shared phrasing for detail values, so every provider reads the same way.
public enum UsageDetailFormat {
  public static func number(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = value < 100 ? 2 : 0
    return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.0f", value)
  }

  /// 1.2K, 3.4M, 5.6B: token counts are read at a glance, not to the unit.
  public static func tokens(_ value: Int64) -> String {
    let amount = Double(value)
    for (threshold, suffix) in [(1e9, "B"), (1e6, "M"), (1e3, "K")] where amount >= threshold {
      let scaled = amount / threshold
      return (scaled >= 100 ? String(format: "%.0f", scaled) : String(format: "%.1f", scaled)) + suffix
    }
    return String(value)
  }

  public static func date(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .omitted)
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
  public let monthlyPriceMinorUnits: Int?
  public let accountUsage: LocalUsageSummary?
  public let detailedUsageUnavailable: Bool
  public let creditBalanceMinorUnits: Int?
  public let observationTimeKnown: Bool
  public let checkedAt: Date
  public let availableResetCount: Int?
  public let accountTokenActivity: OpenAIAccountActivity?
  public let details: [UsageDetail]

  public init(
    provider: ProviderID,
    planName: String? = nil,
    windows: [UsageWindow],
    fetchedAt: Date = Date(),
    source: String,
    includedSpend: IncludedSpend? = nil,
    billingRenewsAt: Date? = nil,
    monthlyPriceMinorUnits: Int? = nil,
    accountUsage: LocalUsageSummary? = nil,
    detailedUsageUnavailable: Bool = false,
    creditBalanceMinorUnits: Int? = nil,
    observationTimeKnown: Bool = true,
    checkedAt: Date? = nil,
    availableResetCount: Int? = nil,
    accountTokenActivity: OpenAIAccountActivity? = nil,
    details: [UsageDetail] = []
  ) {
    self.provider = provider
    self.planName = planName.map { String($0.prefix(Self.maximumPlanNameCharacters)) }
    self.windows = Array(windows.prefix(Self.maximumWindows))
    self.fetchedAt = fetchedAt
    self.source = String(source.prefix(Self.maximumSourceCharacters))
    self.includedSpend = includedSpend
    self.billingRenewsAt = billingRenewsAt
    self.monthlyPriceMinorUnits = monthlyPriceMinorUnits.map { max(0, $0) }
    self.accountUsage = accountUsage
    self.detailedUsageUnavailable = detailedUsageUnavailable
    self.creditBalanceMinorUnits = creditBalanceMinorUnits.map { max(0, $0) }
    self.observationTimeKnown = observationTimeKnown
    self.checkedAt = checkedAt ?? fetchedAt
    self.availableResetCount = availableResetCount.map { max(0, $0) }
    self.accountTokenActivity = accountTokenActivity
    self.details = UsageDetail.sanitized(details)
  }

  private enum CodingKeys: String, CodingKey {
    case provider, planName, windows, fetchedAt, source, includedSpend, billingRenewsAt
    case monthlyPriceMinorUnits, accountUsage, detailedUsageUnavailable
    case creditBalanceMinorUnits, observationTimeKnown, checkedAt, availableResetCount, accountTokenActivity
    case details
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
      billingRenewsAt: try container.decodeIfPresent(Date.self, forKey: .billingRenewsAt),
      monthlyPriceMinorUnits: try container.decodeIfPresent(
        Int.self, forKey: .monthlyPriceMinorUnits),
      accountUsage: try container.decodeIfPresent(LocalUsageSummary.self, forKey: .accountUsage),
      detailedUsageUnavailable: try container.decodeIfPresent(
        Bool.self, forKey: .detailedUsageUnavailable) ?? false,
      creditBalanceMinorUnits: try container.decodeIfPresent(Int.self, forKey: .creditBalanceMinorUnits),
      observationTimeKnown: try container.decodeIfPresent(Bool.self, forKey: .observationTimeKnown)
        ?? true,
      checkedAt: try container.decodeIfPresent(Date.self, forKey: .checkedAt),
      availableResetCount: try container.decodeIfPresent(Int.self, forKey: .availableResetCount),
      accountTokenActivity: try container.decodeIfPresent(OpenAIAccountActivity.self, forKey: .accountTokenActivity),
      details: try container.decodeIfPresent([UsageDetail].self, forKey: .details) ?? [])
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
    try container.encodeIfPresent(self.monthlyPriceMinorUnits, forKey: .monthlyPriceMinorUnits)
    try container.encodeIfPresent(self.accountUsage, forKey: .accountUsage)
    try container.encodeIfPresent(self.creditBalanceMinorUnits, forKey: .creditBalanceMinorUnits)
    try container.encode(self.observationTimeKnown, forKey: .observationTimeKnown)
    try container.encode(self.checkedAt, forKey: .checkedAt)
    try container.encodeIfPresent(self.availableResetCount, forKey: .availableResetCount)
    try container.encodeIfPresent(self.accountTokenActivity, forKey: .accountTokenActivity)
    let persistable = self.details.filter { !$0.isPersonal }
    if !persistable.isEmpty { try container.encode(persistable, forKey: .details) }
    if self.detailedUsageUnavailable {
      try container.encode(true, forKey: .detailedUsageUnavailable)
    }
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
      billingRenewsAt: self.billingRenewsAt,
      monthlyPriceMinorUnits: self.monthlyPriceMinorUnits,
      accountUsage: self.accountUsage,
      detailedUsageUnavailable: self.detailedUsageUnavailable,
      creditBalanceMinorUnits: self.creditBalanceMinorUnits,
      observationTimeKnown: self.observationTimeKnown, checkedAt: self.checkedAt,
      availableResetCount: self.availableResetCount, accountTokenActivity: self.accountTokenActivity,
      details: self.details)
  }
}

/// A persisted snapshot list can name a provider this build no longer supports.
/// Those entries are skipped so one retired provider cannot discard a whole
/// cache file. Any other malformed entry still fails the file.
private struct PersistedSnapshotEntry: Decodable {
  let snapshot: UsageSnapshot?

  private enum CodingKeys: String, CodingKey { case provider }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try container.decode(String.self, forKey: .provider)
    guard ProviderID(rawValue: raw) != nil else {
      self.snapshot = nil
      return
    }
    self.snapshot = try UsageSnapshot(from: decoder)
  }
}

extension UsageSnapshot {
  /// Reads a persisted snapshot list, keeping every entry whose provider this
  /// build still supports.
  public static func decodePersistedList(_ data: Data, using decoder: JSONDecoder) throws
    -> [UsageSnapshot]
  {
    try decoder.decode([PersistedSnapshotEntry].self, from: data).compactMap(\.snapshot)
  }
}

public enum IncludedSpendLimitState: String, Codable, Equatable, Sendable {
  case capped
  case disabled
  case unlimited
}

public struct IncludedSpend: Codable, Equatable, Sendable {
  public let label: String
  public let usedMinorUnits: Int
  public let limitMinorUnits: Int
  public let currencyCode: String
  public let limitState: IncludedSpendLimitState

  public init(
    label: String,
    usedMinorUnits: Int,
    limitMinorUnits: Int,
    currencyCode: String = "USD",
    limitState: IncludedSpendLimitState = .capped
  ) {
    self.label = label
    self.usedMinorUnits = max(0, usedMinorUnits)
    self.limitMinorUnits = max(0, limitMinorUnits)
    self.currencyCode = currencyCode
    self.limitState = limitState
  }

  public var remainingMinorUnits: Int? {
    switch self.limitState {
    case .capped: max(0, self.limitMinorUnits - self.usedMinorUnits)
    case .disabled: 0
    case .unlimited: nil
    }
  }

  private enum CodingKeys: String, CodingKey {
    case label, usedMinorUnits, limitMinorUnits, currencyCode, limitState
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      label: try container.decode(String.self, forKey: .label),
      usedMinorUnits: try container.decode(Int.self, forKey: .usedMinorUnits),
      limitMinorUnits: try container.decode(Int.self, forKey: .limitMinorUnits),
      currencyCode: try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD",
      limitState: try container.decodeIfPresent(IncludedSpendLimitState.self, forKey: .limitState)
        ?? .capped)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.label, forKey: .label)
    try container.encode(self.usedMinorUnits, forKey: .usedMinorUnits)
    try container.encode(self.limitMinorUnits, forKey: .limitMinorUnits)
    try container.encode(self.currencyCode, forKey: .currencyCode)
    try container.encode(self.limitState, forKey: .limitState)
  }
}

public protocol UsageProvider: Sendable {
  var id: ProviderID { get }
  func fetch() async throws -> UsageSnapshot
}

public enum UsageProviderError: LocalizedError, Sendable, Equatable {
  case executableNotFound(String)
  case credentialsNotFound(String)
  case keychainConsentRequired(ProviderID)
  case unauthorized(String)
  case accessDenied(String)
  case updateRequired(String)
  case rateLimited(retryAt: Date?)
  case timedOut(String)
  case invalidResponse(String)
  case unavailable(String)
  case processFailed(String)

  /// Authentication failures need a recovery action in the main provider
  /// card even when an older cached snapshot is still available.
  public var requiresConnection: Bool {
    switch self {
    case .credentialsNotFound, .keychainConsentRequired, .unauthorized:
      true
    default:
      false
    }
  }

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let name): "\(name) is not installed or could not be found."
    case .credentialsNotFound(let message): message
    case .keychainConsentRequired(let provider):
      "\(provider.displayName) is ready. Choose Allow access to add your plan limits."
    case .unauthorized(let message): message
    case .accessDenied(let message): message
    case .updateRequired(let message): message
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
