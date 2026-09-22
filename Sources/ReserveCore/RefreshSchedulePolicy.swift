import Foundation

/// Why a provider is or is not allowed to start another usage read.
public enum RefreshTrigger: Equatable, Sendable {
  /// Configured timer. Respects freshness, backoff, Retry-After, and
  /// discretionary suppression.
  case automatic
  /// App activation or wake. Same gates as the timer, with a shorter floor
  /// on keychain probes so an unlock can be noticed without a tight loop.
  case activation
  /// The person asked to refresh. Bypasses freshness and local backoff.
  /// Does not bypass a provider Retry-After.
  case manual
  /// Sign-in, keychain consent, or an API-key connect. Bypasses auth and
  /// other local cooldown, never a provider Retry-After.
  case connectionRecovery
  /// A locked or unavailable keychain became worth probing again.
  case keychainRecovery
}

public enum RefreshFailureClass: Equatable, Sendable {
  case transient
  case authentication
  case localConfiguration
  case rateLimited(until: Date?)
}

public enum RefreshAdmissionReason: Equatable, Sendable {
  case firstAttempt
  case due
  case retryAfter
  case localCooldown
  case fresh
  case suppressed
}

public struct RefreshAdmission: Equatable, Sendable {
  public var allowed: Bool
  public var reason: RefreshAdmissionReason
  public var nextEligibleAt: Date?

  public init(allowed: Bool, reason: RefreshAdmissionReason, nextEligibleAt: Date?) {
    self.allowed = allowed
    self.reason = reason
    self.nextEligibleAt = nextEligibleAt
  }
}

/// Per-provider memory for the shared refresh schedule. The user's fixed or
/// adaptive interval is not stored here; callers pass it in on each decision
/// so backoff cannot rewrite that choice.
public struct ProviderRefreshSchedule: Equatable, Sendable {
  public var lastSuccessAt: Date?
  public var lastAttemptAt: Date?
  public var consecutiveTransientFailures: Int
  public var consecutiveAuthenticationFailures: Int
  public var cooldownUntil: Date?
  public var retryAfterUntil: Date?
  public var failure: RefreshFailureClass?

  public init(
    lastSuccessAt: Date? = nil,
    lastAttemptAt: Date? = nil,
    consecutiveTransientFailures: Int = 0,
    consecutiveAuthenticationFailures: Int = 0,
    cooldownUntil: Date? = nil,
    retryAfterUntil: Date? = nil,
    failure: RefreshFailureClass? = nil
  ) {
    self.lastSuccessAt = lastSuccessAt
    self.lastAttemptAt = lastAttemptAt
    self.consecutiveTransientFailures = consecutiveTransientFailures
    self.consecutiveAuthenticationFailures = consecutiveAuthenticationFailures
    self.cooldownUntil = cooldownUntil
    self.retryAfterUntil = retryAfterUntil
    self.failure = failure
  }
}

/// Pure schedule shared by the timer, activation, manual refresh, and failures.
public enum RefreshSchedulePolicy {
  public static let transientBase: TimeInterval = 30
  public static let transientCap: TimeInterval = 15 * 60
  public static let authenticationBase: TimeInterval = 5 * 60
  public static let authenticationCap: TimeInterval = 30 * 60
  /// Floor between silent keychain probes, and the shortest automatic wake.
  public static let keychainProbeSpacing: TimeInterval = 15
  public static let keychainProbeCap: TimeInterval = 15 * 60
  public static let minimumAutomaticDelay: TimeInterval = 15
  /// 429 with no usable Retry-After still blocks every trigger, including manual.
  public static let rateLimitFallback: TimeInterval = 60
  public static let rateLimitFallbackCap: TimeInterval = 15 * 60

  public static func failureClass(for error: Error) -> RefreshFailureClass {
    guard let providerError = error as? UsageProviderError else { return .transient }
    switch providerError {
    case .rateLimited(let until):
      return .rateLimited(until: until)
    case .credentialsNotFound, .unauthorized, .keychainConsentRequired, .accessDenied:
      return .authentication
    case .executableNotFound, .updateRequired:
      return .localConfiguration
    case .timedOut, .unavailable, .processFailed, .invalidResponse:
      return .transient
    }
  }

  /// Capped exponential delay. Failure 1 waits `base`, then doubles.
  public static func backoff(failures: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
    let steps = max(0, min(failures - 1, 10))
    var delay = max(0, base)
    if steps > 0 { delay *= pow(2, Double(steps)) }
    return min(max(delay, base), cap)
  }

  public static func recordSuccess(
    _ state: inout ProviderRefreshSchedule,
    now: Date,
    interval: TimeInterval
  ) {
    state.lastSuccessAt = now
    state.lastAttemptAt = now
    state.consecutiveTransientFailures = 0
    state.consecutiveAuthenticationFailures = 0
    state.cooldownUntil = nil
    state.retryAfterUntil = nil
    state.failure = nil
    guard interval.isFinite else { return }
  }

  public static func recordFailure(
    _ state: inout ProviderRefreshSchedule,
    now: Date,
    failure: RefreshFailureClass
  ) {
    state.lastAttemptAt = now
    state.failure = failure
    switch failure {
    case .rateLimited(let until):
      state.consecutiveTransientFailures += 1
      state.consecutiveAuthenticationFailures = 0
      let fallback = Self.backoff(
        failures: state.consecutiveTransientFailures,
        base: Self.rateLimitFallback,
        cap: Self.rateLimitFallbackCap)
      let deadline = until.flatMap { $0 > now ? $0 : nil }
        ?? now.addingTimeInterval(fallback)
      state.retryAfterUntil = deadline
      state.cooldownUntil = nil
    case .transient:
      state.retryAfterUntil = nil
      state.consecutiveTransientFailures += 1
      state.consecutiveAuthenticationFailures = 0
      let delay = Self.backoff(
        failures: state.consecutiveTransientFailures,
        base: Self.transientBase,
        cap: Self.transientCap)
      state.cooldownUntil = now.addingTimeInterval(delay)
    case .authentication, .localConfiguration:
      state.retryAfterUntil = nil
      state.consecutiveAuthenticationFailures += 1
      state.consecutiveTransientFailures = 0
      let delay = Self.backoff(
        failures: state.consecutiveAuthenticationFailures,
        base: Self.authenticationBase,
        cap: Self.authenticationCap)
      state.cooldownUntil = now.addingTimeInterval(delay)
    }
  }

  public static func admit(
    state: ProviderRefreshSchedule,
    trigger: RefreshTrigger,
    now: Date,
    interval: TimeInterval,
    discretionarySuppressed: Bool
  ) -> RefreshAdmission {
    let spacing = max(1, interval)
    if let until = state.retryAfterUntil, until > now {
      return RefreshAdmission(allowed: false, reason: .retryAfter, nextEligibleAt: until)
    }
    let bypassesLocalCooldown = trigger == .manual || trigger == .connectionRecovery
      || trigger == .keychainRecovery
    if !bypassesLocalCooldown, let until = state.cooldownUntil, until > now {
      return RefreshAdmission(allowed: false, reason: .localCooldown, nextEligibleAt: until)
    }
    if discretionarySuppressed, trigger == .automatic || trigger == .activation {
      return RefreshAdmission(
        allowed: false, reason: .suppressed, nextEligibleAt: now.addingTimeInterval(spacing))
    }
    let bypassesFreshness = trigger == .manual || trigger == .connectionRecovery
    if !bypassesFreshness, state.failure == nil, let success = state.lastSuccessAt,
      now.timeIntervalSince(success) < spacing
    {
      return RefreshAdmission(
        allowed: false, reason: .fresh, nextEligibleAt: success.addingTimeInterval(spacing))
    }
    if state.lastAttemptAt == nil, state.lastSuccessAt == nil {
      return RefreshAdmission(allowed: true, reason: .firstAttempt, nextEligibleAt: now)
    }
    return RefreshAdmission(allowed: true, reason: .due, nextEligibleAt: now)
  }

  public static func nextEligibleAt(
    state: ProviderRefreshSchedule,
    now: Date,
    interval: TimeInterval
  ) -> Date {
    let decision = Self.admit(
      state: state, trigger: .automatic, now: now, interval: interval,
      discretionarySuppressed: false)
    if decision.allowed { return now }
    return decision.nextEligibleAt ?? now.addingTimeInterval(max(interval, Self.minimumAutomaticDelay))
  }
}
