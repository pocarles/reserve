import Foundation

/// An alert worth interrupting someone for, derived from Reserve's forecast
/// rather than from a fixed usage mark.
public enum SmartAlert: Equatable, Sendable {
  /// The window has crossed from reserve/on-pace into a factual pace deficit.
  case enteredDeficit(
    provider: ProviderID,
    windowID: String,
    windowLabel: String,
    deficitPercent: Double,
    runsOutAt: Date?,
    resetsAt: Date)
  /// Reserve has stopped receiving fresh numbers for a provider.
  case dataStale(provider: ProviderID, lastUpdated: Date)
  /// The provider itself is reporting trouble.
  case serviceIncident(provider: ProviderID, health: ServiceHealth, detail: String)

  public var preferenceKey: String {
    switch self {
    case .enteredDeficit: "deficit"
    case .dataStale: "stale"
    case .serviceIncident: "incident"
    }
  }
}

public enum SmartAlertDetector {
  /// How long a provider may go without a successful update before its numbers
  /// stop counting as current. Same value the pace state uses.
  public static let stalenessLimit: TimeInterval = UsagePaceState.stalenessLimit

  /// Windows that crossed into a pace deficit since the previous snapshot.
  /// Only the transition is reported, so a persistent deficit stays quiet.
  public static func deficitAlerts(
    previous: UsageSnapshot?,
    current: UsageSnapshot,
    now: Date = Date()
  ) -> [SmartAlert] {
    guard let previous else { return [] }
    return current.windows.compactMap { window in
      guard Self.isNotifiable(window) else { return nil }
      guard let resetsAt = window.resetsAt, resetsAt > now else { return nil }
      guard let projection = UsagePaceProjection.calculate(for: window, now: now),
        projection.position == .deficit
      else { return nil }

      // Same window, same cycle: was it already in deficit a moment ago?
      let before = previous.windows.first { $0.id == window.id && $0.resetsAt == window.resetsAt }
      if let before,
        UsagePaceProjection.calculate(for: before, now: now)?.position == .deficit
      {
        return nil
      }
      return .enteredDeficit(
        provider: current.provider,
        windowID: window.id,
        windowLabel: window.label,
        deficitPercent: projection.variancePercent,
        runsOutAt: projection.projectedExhaustionAt,
        resetsAt: resetsAt)
    }
  }

  /// Whether a provider's most recent successful update is too old to trust.
  public static func isStale(
    lastUpdated: Date?,
    now: Date = Date(),
    limit: TimeInterval = SmartAlertDetector.stalenessLimit
  ) -> Bool {
    guard let lastUpdated else { return false }
    return now.timeIntervalSince(lastUpdated) > limit
  }

  /// Provider-reported trouble, as opposed to a healthy provider.
  public static func isIncident(_ health: ServiceHealth?) -> Bool {
    switch health {
    case .degraded, .outage: true
    case .operational, .unknown, .none: false
    }
  }

  /// Component shares of a larger allowance are not separate quotas, so they
  /// never raise their own alert.
  private static func isNotifiable(_ window: UsageWindow) -> Bool {
    !window.isComponentShare
  }
}
