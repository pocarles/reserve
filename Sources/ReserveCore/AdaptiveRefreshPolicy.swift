import Foundation

/// Why the adaptive refresh interval is the length it is.
///
/// Stable so a caller can log or compare the reason without parsing minutes.
public enum AdaptiveRefreshReason: Equatable, Sendable {
  /// Low Power Mode or serious/critical thermal state. The caller decides
  /// that; this policy only receives the boolean.
  case constrained
  /// Dashboard was opened within the last five minutes, including a clock
  /// that moved into the future.
  case dashboardRecent
  /// Dashboard was opened more than five minutes ago and at most one hour ago.
  case dashboardWithinHour
  /// Dashboard was opened more than one hour ago and less than four hours ago.
  case dashboardWithinFourHours
  /// No dashboard open is recorded, or the last open is at least four hours old.
  case dashboardDormant
}

/// Chosen refresh delay, in whole minutes, plus the reason that selected it.
public struct AdaptiveRefreshDecision: Equatable, Sendable {
  public var minutes: Int
  public var reason: AdaptiveRefreshReason

  public init(minutes: Int, reason: AdaptiveRefreshReason) {
    self.minutes = minutes
    self.reason = reason
  }
}

/// Pure delay policy for adaptive dashboard refresh.
///
/// Callers pass `now`, the last dashboard-open time, and whether the machine
/// is constrained (Low Power Mode or serious/critical thermal). The policy
/// does not read clocks, process state, quotas, accounts, errors, or activity.
public enum AdaptiveRefreshPolicy: Sendable {
  public static let minimumMinutes = 2
  public static let maximumMinutes = 30

  /// Five minutes, inclusive: the dashboard still counts as just opened.
  public static let recentWindow: TimeInterval = 5 * 60
  /// One hour, inclusive upper bound of the five-minute cadence.
  public static let hourlyWindow: TimeInterval = 60 * 60
  /// Four hours. At or beyond this age the cadence returns to the dormant delay.
  public static let dormantWindow: TimeInterval = 4 * 60 * 60

  /// Minutes until the next refresh.
  ///
  /// Precedence:
  /// 1. Constrained machines always wait 30 minutes.
  /// 2. A dashboard open at most five minutes ago (or in the future) waits 2.
  /// 3. Older than five minutes and at most one hour waits 5.
  /// 4. Older than one hour and younger than four hours waits 15.
  /// 5. Missing or at least four hours old waits 30.
  public static func minutes(
    now: Date,
    lastDashboardOpenAt: Date?,
    constrained: Bool
  ) -> Int {
    decision(now: now, lastDashboardOpenAt: lastDashboardOpenAt, constrained: constrained).minutes
  }

  /// Minutes plus the stable reason that selected them.
  public static func decision(
    now: Date,
    lastDashboardOpenAt: Date?,
    constrained: Bool
  ) -> AdaptiveRefreshDecision {
    if constrained {
      return AdaptiveRefreshDecision(minutes: 30, reason: .constrained)
    }
    guard let lastDashboardOpenAt else {
      return AdaptiveRefreshDecision(minutes: 30, reason: .dashboardDormant)
    }
    let age = now.timeIntervalSince(lastDashboardOpenAt)
    // A future open (negative age) is treated as just opened, covering a
    // clock adjustment that landed `now` before the recorded open.
    if age <= recentWindow {
      return AdaptiveRefreshDecision(minutes: 2, reason: .dashboardRecent)
    }
    if age <= hourlyWindow {
      return AdaptiveRefreshDecision(minutes: 5, reason: .dashboardWithinHour)
    }
    if age < dormantWindow {
      return AdaptiveRefreshDecision(minutes: 15, reason: .dashboardWithinFourHours)
    }
    return AdaptiveRefreshDecision(minutes: 30, reason: .dashboardDormant)
  }
}
