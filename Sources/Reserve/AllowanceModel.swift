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
  var projection: UsagePaceProjection?
  let isPrimary: Bool
  var paceState: UsagePaceState
  var isComponentShare = false
  var windowMinutes: Int? = nil

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
  var allowances: [Allowance]
  var paceState: UsagePaceState
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
  var creditBalanceMinorUnits: Int? = nil
  var usageAccessDenied = false
  var observationTimeKnown = true
  var checkedAt: Date? = nil
  var availableResetCount: Int? = nil
  var billingRenewsAt: Date? = nil
  var subscriptionCostLabel: String? = nil
  /// The renewal Reserve works out from the billing day the person entered, used
  /// when the provider does not report one.
  var nextRenewal: Date? = nil
  var localHistoryEnabled = false
  /// Whether this provider can ever have activity history at all: local logs,
  /// account history, or both.
  var historyPossible = false
  /// Whether this provider's history comes from logs on this Mac.
  var localHistorySupported = false
  /// Provider facts for the expanded details only (account, credits, counts).
  var details: [UsageDetail] = []

  var primary: Allowance? { self.allowances.first { $0.isPrimary } ?? self.allowances.first }
  var secondary: [Allowance] { self.allowances.filter { !$0.isPrimary } }

  func at(_ now: Date) -> ProviderSummary {
    var result = self
    result.allowances = self.allowances.map { allowance in
      var value = allowance
      let window = UsageWindow(id: value.id, label: value.title, usedPercent: value.usedPercent,
        windowMinutes: value.windowMinutes, resetsAt: value.resetsAt)
      value.paceState = UsagePaceState.calculate(for: window, fetchedAt: self.lastUpdated,
        hasError: self.error != nil || !self.observationTimeKnown, now: now)
      value.projection = value.paceState == .stale ? nil : UsagePaceProjection.calculate(for: window, now: now)
      return value
    }
    result.paceState = result.primary?.paceState ?? self.paceState
    return result
  }

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
    case .install: "Set up"
    case .update: "Update"
    case .signIn: "Sign in"
    case .allowAccess: "Allow access"
    }
  }

  func message(for provider: ProviderID) -> String {
    switch self {
    case .install: "Set up \(provider.displayName) to show plan limits"
    case .update: "Update \(provider.displayName) to resume plan limits"
    case .signIn: "Sign in to \(provider.displayName) to show plan limits"
    case .allowAccess: "Waiting for permission to read usage"
    }
  }

  func toolTip(for provider: ProviderID) -> String {
    if !ProviderDescriptor.forProvider(provider).supportsAutomaticHelperInstallation {
      if self == .install { return "Open official installation instructions for \(provider.displayName)" }
      if self == .update { return "Open official update instructions for \(provider.displayName)" }
    }
    return switch self {
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
    let allPlanWindows = windows.filter { !$0.isComponentShare }
    // A model-scoped limit only leads when the provider reports nothing broader.
    let planWindows = allPlanWindows.filter { !$0.isModelScoped }.isEmpty
      ? allPlanWindows : allPlanWindows.filter { !$0.isModelScoped }
    let blockingWindow = planWindows.filter { $0.usedPercent >= 99.5 && ($0.resetsAt ?? .distantFuture) > now }
      .min { ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture) }
    let urgentWindow = planWindows.filter {
      100 - $0.usedPercent <= 20 && ($0.resetsAt ?? .distantFuture) > now
    }.min {
      if $0.usedPercent != $1.usedPercent {
        return $0.usedPercent > $1.usedPercent
      }
      return ($0.resetsAt ?? .distantFuture) < ($1.resetsAt ?? .distantFuture)
    }
    let primaryWindow = blockingWindow
      ?? urgentWindow
      ?? planWindows.first { $0.label.localizedCaseInsensitiveCompare("Weekly") == .orderedSame }
      ?? planWindows.max(by: { $0.usedPercent < $1.usedPercent })
      ?? windows.max(by: { $0.usedPercent < $1.usedPercent })

    let allowances = windows
      .sorted { lhs, rhs in
        let lhsPrimary = lhs.id == primaryWindow?.id
        let rhsPrimary = rhs.id == primaryWindow?.id
        if lhsPrimary != rhsPrimary { return lhsPrimary }
        if lhs.isModelScoped != rhs.isModelScoped { return rhs.isModelScoped }
        return (lhs.resetsAt ?? .distantFuture) < (rhs.resetsAt ?? .distantFuture)
      }
      .map { window in
        Allowance(
          id: window.id,
          title: Self.title(for: window),
          usedPercent: window.usedPercent,
          resetsAt: window.resetsAt,
          projection: state.snapshot?.observationTimeKnown == false || state.error != nil
            ? nil : UsagePaceProjection.calculate(for: window, now: now),
          isPrimary: window.id == primaryWindow?.id,
          paceState: UsagePaceState.calculate(
            for: window,
            fetchedAt: state.snapshot?.fetchedAt,
            hasError: state.error != nil || state.snapshot?.observationTimeKnown == false,
            now: now),
          isComponentShare: window.isComponentShare, windowMinutes: window.windowMinutes)
      }

    let planName = state.snapshot?.planName?.trimmingCharacters(in: .whitespacesAndNewlines)
    let isStale = SmartAlertDetector.isStale(
      lastUpdated: state.snapshot?.fetchedAt, now: now)

    let connectionToolAvailable = Self.connectionToolAvailable(for: state.provider)
    let capabilities = ProviderDescriptor.forProvider(state.provider).capabilities
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
      creditBalanceMinorUnits: state.snapshot?.creditBalanceMinorUnits,
      usageAccessDenied: state.usageAccessDenied,
      observationTimeKnown: state.snapshot?.observationTimeKnown ?? true,
      checkedAt: state.snapshot?.checkedAt,
      availableResetCount: state.snapshot?.availableResetCount,
      billingRenewsAt: state.snapshot?.billingRenewsAt,
      subscriptionCostLabel: state.subscriptionCostLabel,
      nextRenewal: state.nextRenewal,
      localHistoryEnabled: state.localHistoryEnabled,
      historyPossible: capabilities.contains(.localHistory)
        || capabilities.contains(.accountHistory),
      localHistorySupported: capabilities.contains(.localHistory),
      details: state.snapshot?.details ?? [])
  }

  private static func connectionToolAvailable(for provider: ProviderID) -> Bool {
    let executable = ProviderDescriptor.forProvider(provider).helper.executable
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
      return ("Connect a provider in Settings", "", .unknown)
    }
    let stale = summaries.filter { $0.paceState == .stale }
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
      let reset = first.primary?.resetsAt.flatMap { $0 > now ? DashboardFormat.countdown(to: $0, now: now) : nil }
      return (
        "\(first.provider.displayName) is out of allowance"
          + (reset.map { " · resets \($0)" } ?? ""),
        "",
        .exhausted)
    }
    if !deficits.isEmpty {
      // The plan whose capacity disappears first is the one to act on. A larger
      // percentage gap matters less than running out sooner.
      let soonest = deficits.min { lhs, rhs in
        let lhsRunsOut = lhs.primary?.runsOutAt ?? .distantFuture
        let rhsRunsOut = rhs.primary?.runsOutAt ?? .distantFuture
        if lhsRunsOut != rhsRunsOut { return lhsRunsOut < rhsRunsOut }
        return (lhs.paceState.deficitPercent ?? 0) > (rhs.paceState.deficitPercent ?? 0)
      }!
      let detail: String
      if let runsOut = soonest.primary?.runsOutAt, let reset = soonest.primary?.resetsAt,
        runsOut < reset
      {
        detail = "may run out \(DashboardFormat.gap(from: runsOut, to: reset)) before reset"
      } else if let reset = soonest.primary?.resetsAt, reset > now {
        detail = "resets \(DashboardFormat.countdown(to: reset, now: now))"
      } else {
        detail = "reset time unavailable"
      }
      let others = deficits.count - 1
      return (
        "\(soonest.provider.displayName) \(detail)"
          + (others > 0 ? " · \(others) more at risk" : ""),
        "",
        soonest.paceState)
    }
    if !stale.isEmpty {
      let names = stale.prefix(2).map { $0.provider.displayName }
      let subject = names.joined(separator: " and ")
        + (stale.count > 2 ? " and \(stale.count - 2) more" : "")
      return (
        "\(subject) need\(stale.count == 1 ? "s" : "") fresh data",
        "", .stale)
    }
    // A plan without a forecast never outranks a conclusion about the plans that
    // do have one. Provider names keep their own capitalisation.
    let nextReset = Self.nextReset(in: summaries, now: now).map {
      "\($0.provider.displayName) resets \(DashboardFormat.countdown(to: $0.date, now: now))"
    } ?? "next reset unavailable"
    // "All plans" is only claimed when every plan has a forecast; otherwise
    // say what is actually known, which is that none is at risk.
    let hasUnknown = summaries.contains { $0.paceState == .unknown }
    if !onPace.isEmpty {
      return (
        hasUnknown ? "No plan at risk · \(nextReset)" : "All plans on track · \(nextReset)",
        "", .onPace)
    }
    if !reserve.isEmpty {
      return (
        hasUnknown ? "No plan at risk · \(nextReset)" : "All plans have reserve · \(nextReset)",
        "", .reserve(percent: 0))
    }
    // Nothing is exhausted, behind, stale or healthy: every plan is unknown.
    return ("No pace forecast yet · \(nextReset)", "", .unknown)
  }

  private static func nextReset(in summaries: [ProviderSummary], now: Date) -> (
    provider: ProviderID, date: Date
  )? {
    summaries.compactMap { summary in
      summary.primary?.resetsAt.flatMap { $0 > now ? (summary.provider, $0) : nil }
    }.min { $0.1 < $1.1 }
  }
}
