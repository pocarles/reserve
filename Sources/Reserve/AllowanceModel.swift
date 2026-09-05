import AppKit
import ReserveCore

/// Every limit a provider exposes — weekly, five-hour, Build share, Chat share —
/// is normalized into this one shape so the interface renders them all with the
/// same component and the same vocabulary.
struct Allowance: Identifiable {
  let id: String
  /// Human title for the window itself: "Weekly limit", "5-hour window".
  let title: String
  let usedPercent: Double
  let resetsAt: Date?
  let projection: UsagePaceProjection?
  let isPrimary: Bool
  let paceState: UsagePaceState

  var remainingPercent: Double { max(0, min(100, 100 - self.usedPercent)) }

  /// Where usage is expected to be right now if consumption were even.
  var expectedPercent: Double? { self.projection?.elapsedPercent }

  /// Where usage is projected to land when the window resets.
  var projectedUsedAtResetPercent: Double? {
    self.projection?.projectedRemainingPercent.map { 100 - $0 }
  }

  var projectedRemainingAtResetPercent: Double? { self.projection?.projectedRemainingPercent }

  var runsOutAt: Date? { self.projection?.projectedExhaustionAt }
}

extension UsagePaceState {
  var label: String {
    switch self {
    case .reserve: "Under pace"
    case .onPace: "On pace"
    case .deficit: "May run out early"
    case .exhausted: "Exhausted"
    case .unknown: "Unknown"
    case .stale: "Stale"
    }
  }

  /// A shape as well as a colour, so state never depends on colour alone.
  var symbol: String {
    switch self {
    case .reserve: "checkmark.circle.fill"
    case .onPace: "equal.circle.fill"
    case .deficit: "minus.circle.fill"
    case .exhausted: "minus.circle.fill"
    case .unknown: "questionmark.circle"
    case .stale: "clock.badge.exclamationmark"
    }
  }

  @MainActor
  var color: NSColor {
    switch self {
    case .reserve: ReserveColor.reserve
    case .onPace: ReserveColor.onPace
    case .deficit, .exhausted: ReserveColor.deficit
    case .unknown, .stale: ReserveColor.subtle
    }
  }

  var deficitPercent: Double? {
    guard case .deficit(let percent) = self else { return nil }
    return percent
  }

  var reservePercent: Double? {
    guard case .reserve(let percent) = self else { return nil }
    return percent
  }
}

/// A provider reduced to what the glance view needs.
struct ProviderSummary {
  let provider: ProviderID
  let planName: String
  let allowances: [Allowance]
  let paceState: UsagePaceState
  let serviceStatus: ProviderServiceStatus?
  let isConnecting: Bool
  let isRefreshing: Bool
  let needsConnection: Bool
  let connectionToolAvailable: Bool
  let requiresKeychainAccess: Bool
  let setupAction: ProviderSetupAction?
  let error: String?
  let lastUpdated: Date?
  /// Detail-layer material, kept out of the glance view.
  let localUsage: LocalUsageSummary?
  let subscriptionCostUSD: Double?
  let quotaSource: String?
  let includedSpend: IncludedSpend?
  let detailedUsageUnavailable: Bool
  var usageAccessDenied = false

  var primary: Allowance? { self.allowances.first { $0.isPrimary } ?? self.allowances.first }
  var secondary: [Allowance] { self.allowances.filter { !$0.isPrimary } }

  /// Provider availability is only worth showing when it is not normal.
  var serviceIsExceptional: Bool {
    guard let health = self.serviceStatus?.health else { return false }
    return health != .operational
  }
}

enum ProviderSetupAction: String, Equatable {
  case install
  case update
  case signIn
  case allowAccess

  var buttonTitle: String {
    switch self {
    case .install: "Connect"
    case .update: "Connect"
    case .signIn: "Connect"
    case .allowAccess: "Connect"
    }
  }

  func message(for provider: ProviderID) -> String {
    switch self {
    case .install: "Connect \(provider.displayName) to show plan limits"
    case .update: "Update \(provider.displayName) to resume plan limits"
    case .signIn: "Sign in to \(provider.displayName) to show plan limits"
    case .allowAccess: "Waiting for permission to read usage"
    }
  }

  func toolTip(for provider: ProviderID) -> String {
    switch self {
    case .install:
      "Install \(ProviderHelperCatalog.definition(for: provider).displayName) without using Terminal"
    case .update:
      "Update \(ProviderHelperCatalog.definition(for: provider).displayName) and reconnect"
    case .signIn:
      "Sign in with \(provider.displayName) in your browser"
    case .allowAccess:
      "Uses \(provider.displayName)'s existing sign-in only to check usage. Reserve never stores it."
    }
  }
}

@MainActor
enum AllowanceBuilder {
  static func summary(for state: ProviderViewState, now: Date = Date()) -> ProviderSummary {
    let windows = state.snapshot?.windows ?? []
    let planWindows = windows.filter { !$0.isComponentShare }
    let primaryWindow =
      planWindows.first { $0.label.localizedCaseInsensitiveCompare("Weekly") == .orderedSame }
      ?? planWindows.max(by: { $0.usedPercent < $1.usedPercent })
      ?? windows.max(by: { $0.usedPercent < $1.usedPercent })

    let allowances = windows
      .sorted { lhs, rhs in
        let lhsPrimary = lhs.id == primaryWindow?.id
        let rhsPrimary = rhs.id == primaryWindow?.id
        if lhsPrimary != rhsPrimary { return lhsPrimary }
        return (lhs.resetsAt ?? .distantFuture) < (rhs.resetsAt ?? .distantFuture)
      }
      .map { window in
        Allowance(
          id: window.id,
          title: Self.title(for: window),
          usedPercent: window.usedPercent,
          resetsAt: window.resetsAt,
          projection: UsagePaceProjection.calculate(for: window, now: now),
          isPrimary: window.id == primaryWindow?.id,
          paceState: UsagePaceState.calculate(
            for: window,
            fetchedAt: state.snapshot?.fetchedAt,
            hasError: state.error != nil,
            now: now))
      }

    let planName = state.snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let isStale = SmartAlertDetector.isStale(
      lastUpdated: state.snapshot?.fetchedAt, now: now)

    let connectionToolAvailable = Self.connectionToolAvailable(for: state.provider)
    let setupAction = Self.setupAction(
      for: state, connectionToolAvailable: connectionToolAvailable)
    return ProviderSummary(
      provider: state.provider,
      planName: (planName?.isEmpty == false ? planName : nil) ?? "",
      allowances: allowances,
      paceState: allowances.first(where: { $0.isPrimary })?.paceState
        ?? allowances.first?.paceState
        ?? (isStale ? .stale : .unknown),
      serviceStatus: state.serviceStatus,
      isConnecting: state.isConnecting,
      isRefreshing: state.isRefreshing,
      needsConnection: setupAction != nil,
      connectionToolAvailable: connectionToolAvailable,
      requiresKeychainAccess: state.requiresKeychainAccess,
      setupAction: setupAction,
      error: state.error,
      lastUpdated: state.snapshot?.fetchedAt,
      localUsage: state.snapshot?.accountUsage ?? state.localUsage,
      subscriptionCostUSD: state.subscriptionCostUSD,
      quotaSource: state.snapshot?.source,
      includedSpend: state.snapshot?.includedSpend,
      detailedUsageUnavailable: state.snapshot?.detailedUsageUnavailable ?? false,
      usageAccessDenied: state.usageAccessDenied)
  }

  private static func connectionToolAvailable(for provider: ProviderID) -> Bool {
    let executable = switch provider {
    case .openAI: "codex"
    case .anthropic: "claude"
    case .grok: "grok"
    case .cursor: "cursor-agent"
    }
    return BinaryLocator.find(executable) != nil
  }

  /// A limit window titled the way a person would describe it.
  static func title(for window: UsageWindow) -> String {
    let label = window.label
    if label.localizedCaseInsensitiveCompare("Weekly") == .orderedSame { return "Weekly limit" }
    if label.localizedCaseInsensitiveCompare("5 hours") == .orderedSame { return "5-hour window" }
    if label.localizedCaseInsensitiveCompare("Grok Build share") == .orderedSame {
      return "Build share"
    }
    if label.localizedCaseInsensitiveCompare("Grok Chat share") == .orderedSame {
      return "Chat share"
    }
    if label.localizedCaseInsensitiveContains("share") { return label }
    if label.localizedCaseInsensitiveContains("weekly") { return "\(label) limit" }
    return label
  }

  static func paceState(
    primary: Allowance?,
    hasSnapshot: Bool,
    isStale: Bool,
    hasError: Bool
  ) -> UsagePaceState {
    guard hasSnapshot, let primary else { return .unknown }
    if isStale || hasError { return .stale }
    return primary.paceState
  }

  static func needsConnection(_ state: ProviderViewState) -> Bool {
    let available = Self.connectionToolAvailable(for: state.provider)
    return Self.setupAction(for: state, connectionToolAvailable: available) != nil
  }

  static func setupAction(
    for state: ProviderViewState,
    connectionToolAvailable: Bool? = nil
  ) -> ProviderSetupAction? {
    if state.requiresKeychainAccess { return .allowAccess }
    if state.requiresUpdate { return .update }
    if state.requiresInstallation { return .install }
    if state.requiresConnection { return .signIn }
    guard state.snapshot == nil, state.error == nil else { return nil }
    let available = connectionToolAvailable ?? Self.connectionToolAvailable(for: state.provider)
    return available ? .signIn : .install
  }

  /// Automatic menu-bar mode keeps the Reserve identity while choosing the
  /// enabled primary limit that is most useful to see. A pinned provider wins
  /// only while it remains enabled and available in the supplied summaries.
  static func menuBarSummary(
    from summaries: [ProviderSummary],
    pinnedProvider: ProviderID?
  ) -> (summary: ProviderSummary?, isPinned: Bool) {
    if let pinnedProvider,
      let pinned = summaries.first(where: { $0.provider == pinnedProvider })
    {
      return (pinned, true)
    }
    let automatic = summaries.max { lhs, rhs in
      Self.menuBarPriority(lhs) < Self.menuBarPriority(rhs)
    }
    return (automatic, false)
  }

  private static func menuBarPriority(_ summary: ProviderSummary) -> Double {
    let remaining = summary.primary?.remainingPercent ?? 100
    switch summary.paceState {
    case .exhausted: return 600
    case .deficit(let percent): return 500 + percent
    case .onPace: return 400 + (100 - remaining) / 100
    case .reserve(let percent): return 300 + (100 - percent) / 100
    case .stale: return 200 + (100 - remaining) / 100
    case .unknown: return 100 + (100 - remaining) / 100
    }
  }

  /// The single conclusion that belongs at the top of the popover.
  static func headline(for summaries: [ProviderSummary], now: Date = Date()) -> (
    primary: String, secondary: String, state: UsagePaceState
  ) {
    guard !summaries.isEmpty else {
      return ("No providers are being tracked", "Choose providers in Settings", .unknown)
    }
    let stale = summaries.filter { $0.paceState == .stale }
    let unknown = summaries.filter { $0.paceState == .unknown }
    let exhausted = summaries.filter { $0.paceState == .exhausted }
    let deficits = summaries.filter {
      if case .deficit = $0.paceState { return true }
      return false
    }
    let onPace = summaries.filter { $0.paceState == .onPace }
    let reserve = summaries.filter {
      if case .reserve = $0.paceState { return true }
      return false
    }
    if let first = exhausted.first {
      return (
        exhausted.count == 1 ? "1 plan exhausted" : "\(exhausted.count) plans exhausted",
        "\(first.provider.displayName) · limit exhausted"
          + (stale.isEmpty ? "" : " · \(stale.count) also need fresh data"),
        .exhausted)
    }
    if !deficits.isEmpty {
      let worst = deficits.max {
        ($0.paceState.deficitPercent ?? 0) < ($1.paceState.deficitPercent ?? 0)
      }!
      let amount = Int((worst.paceState.deficitPercent ?? 0).rounded())
      return (
        deficits.count == 1 ? "1 plan may run out early" : "\(deficits.count) plans may run out early",
        "\(worst.provider.displayName) · \(amount) points over pace"
          + (stale.isEmpty ? "" : " · \(stale.count) also need fresh data"),
        worst.paceState)
    }
    let reset = Self.nextReset(in: summaries, now: now)
    let nextReset = reset.map {
      "Next reset: \($0.provider.displayName) \(DashboardFormat.countdown(to: $0.date, now: now))"
    } ?? "Next reset unavailable"
    if !stale.isEmpty {
      let knownSummary = Self.healthySummary(
        reserve: reserve.count, onPace: onPace.count, other: true)
      let context = [
        knownSummary,
        unknown.isEmpty ? nil : Self.paceUnavailable(unknown.count, other: true),
        nextReset,
      ].compactMap { $0 }
      return (
        Self.plans(stale.count, singular: "needs fresh data", plural: "need fresh data"),
        context.joined(separator: " · "), .stale)
    }
    if !unknown.isEmpty {
      let knownSummary = Self.healthySummary(
        reserve: reserve.count, onPace: onPace.count, other: true)
      let context = [knownSummary, nextReset].compactMap { $0 }
      return (
        Self.paceUnavailable(unknown.count),
        context.joined(separator: " · "), .unknown)
    }
    if !onPace.isEmpty {
      let primary = reserve.isEmpty
        ? "All plans are on pace"
        : (Self.healthySummary(
          reserve: reserve.count, onPace: onPace.count, other: false) ?? "All plans are on pace")
      return (primary, nextReset, .onPace)
    }
    if !reserve.isEmpty {
      return ("All plans have reserve", nextReset, .reserve(percent: 0))
    }
    return (
      Self.paceUnavailable(summaries.count),
      "Current pace is unavailable", .unknown)
  }

  /// "1 plan has reserve" / "2 other plans remain on pace".
  private static func plans(_ count: Int, singular: String, plural: String, other: Bool = false)
    -> String
  {
    "\(count)\(other ? " other" : "") plan\(count == 1 ? "" : "s") \(count == 1 ? singular : plural)"
  }

  private static func healthySummary(reserve: Int, onPace: Int, other: Bool) -> String? {
    if reserve == 0, onPace == 0 { return nil }
    if reserve == 0 {
      return Self.plans(onPace, singular: "remains on pace", plural: "remain on pace", other: other)
    }
    if onPace == 0 {
      return Self.plans(reserve, singular: "has reserve", plural: "have reserve", other: other)
    }
    return Self.plans(reserve, singular: "has reserve", plural: "have reserve", other: other)
      + " · \(onPace) \(onPace == 1 ? "is" : "are") on pace"
  }

  private static func paceUnavailable(_ count: Int, other: Bool = false) -> String {
    Self.plans(
      count, singular: "has no pace forecast", plural: "have no pace forecast", other: other)
  }

  private static func nextReset(in summaries: [ProviderSummary], now: Date) -> (
    provider: ProviderID, date: Date
  )? {
    summaries.compactMap { summary in
      summary.primary?.resetsAt.flatMap { $0 > now ? (summary.provider, $0) : nil }
    }.min { $0.1 < $1.1 }
  }
}
