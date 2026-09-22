import AppKit
import ReserveCore

/// Focused regressions for the dashboard's retained-view update path.
/// Fixtures only: no preferences, credentials, network, or local history.
@MainActor
enum DashboardUpdateSelfTest {
  static func run() async -> [String] {
    var failures: [String] = []
    let now = Date()
    let reset = now.addingTimeInterval(3_600)

    func state(
      weeklyUsed: Double, shareUsed: Double, todayTokens: Int64 = 120,
      fetchedAt: Date? = nil
    ) -> ProviderViewState {
      var result = ProviderViewState(
        provider: .openAI,
        snapshot: UsageSnapshot(
          provider: .openAI,
          planName: "Test",
          windows: [
            UsageWindow(
              id: "weekly", label: "Weekly", usedPercent: weeklyUsed,
              windowMinutes: 10_080, resetsAt: reset),
            UsageWindow(
              id: "build-share", label: "Build share", usedPercent: shareUsed,
              windowMinutes: 10_080, resetsAt: reset),
          ],
          fetchedAt: fetchedAt ?? now.addingTimeInterval(-30), source: "Fixture",
          details: [UsageDetail("Account", "person@example.com", isPersonal: true)]))
      result.localUsage = LocalUsageSummary(
        provider: .openAI, periodDays: 30, inputTokens: todayTokens * 10,
        cachedInputTokens: todayTokens * 3, outputTokens: todayTokens,
        apiEquivalentCostUSD: Double(todayTokens) / 100, todayTokens: todayTokens,
        fetchedAt: fetchedAt ?? now.addingTimeInterval(-30),
        dailyTokens: [
          DailyUsage(day: "2026-09-21", tokens: todayTokens / 2),
          DailyUsage(day: "2026-09-22", tokens: todayTokens),
        ])
      return result
    }

    var readings = [
      APIConsumptionReading(
        provider: .openAI,
        snapshot: APIConsumptionSnapshot(
          provider: .openAI,
          windows: [
            APIConsumptionWindow(id: "month", label: "This month", usedMinorUnits: 1234)
          ],
          source: "Fixture",
          details: [UsageDetail("Account", "api-person@example.com", isPersonal: true)]),
        error: nil, isRefreshing: false, isExpanded: true, hidesPersonalInfo: false)
    ]
    let actions = DashboardActions(
      refreshAll: {}, connectProvider: { _ in }, selectMenuBarProvider: { _ in },
      openSettings: {}, openInsights: {}, dismiss: {}, toggleProviderDetail: { _ in },
      quit: {}, apiConsumptionReadings: { readings })
    let initialState = state(weeklyUsed: 20, shareUsed: 12)
    let dashboard = UsageDashboardView(
      states: [initialState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, now: now,
      maximumHeight: 2_000, actions: actions)
    dashboard.layoutSubtreeIfNeeded()

    func descendants(_ view: NSView) -> [NSView] {
      view.subviews + view.subviews.flatMap(descendants)
    }
    func view(_ id: String) -> NSView? {
      descendants(dashboard).first { $0.identifier?.rawValue == id }
    }
    func text() -> [String] {
      descendants(dashboard).compactMap { ($0 as? NSTextField)?.stringValue }
    }

    let gridBefore = view("usage-detail-openAI")
    let shareBefore = view("secondary-build-share")
    guard text().contains("api-person@example.com") else {
      failures.append("expanded API fixture did not render its personal detail")
      return failures
    }

    readings[0].hidesPersonalInfo = true
    let privacyApplied = dashboard.apply(
      states: [initialState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, refreshStartedAt: nil,
      now: now, maximumHeight: 2_000, actions: actions)
    if !privacyApplied || text().contains("api-person@example.com") {
      failures.append("privacy toggle left an expanded API personal value visible")
    }
    if view("usage-detail-openAI") !== gridBefore {
      failures.append("API privacy update replaced an unchanged provider detail grid")
    }

    let updatedState = state(
      weeklyUsed: 25, shareUsed: 55, todayTokens: 222,
      fetchedAt: now.addingTimeInterval(-5))
    let regionBeforeReading = dashboard.regionRebuildCount
    let readingApplied = dashboard.apply(
      states: [updatedState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, refreshStartedAt: nil,
      now: now, maximumHeight: 2_000, actions: actions)
    let shareAfter = view("secondary-build-share")
    let shareText = shareAfter.map(descendants)?.compactMap { ($0 as? NSTextField)?.stringValue } ?? []
    if !readingApplied || shareAfter !== shareBefore || !shareText.contains("55% of pool used") {
      failures.append("component-share reading did not update in its retained row")
    }
    if dashboard.regionRebuildCount != regionBeforeReading {
      failures.append("ordinary allowance changes replaced a dashboard region")
    }
    if view("usage-detail-openAI") !== gridBefore {
      failures.append("ordinary allowance changes replaced unchanged provider details")
    }
    if !text().contains(DashboardFormat.tokens(222)) {
      failures.append("retained provider details did not publish changed local totals")
    }

    var permissionState = ProviderViewState(provider: .openAI)
    permissionState.error = UsageProviderError.keychainConsentRequired(.openAI).localizedDescription
    permissionState.requiresConnection = true
    permissionState.requiresKeychainAccess = true
    let cardBefore = descendants(dashboard).compactMap { $0 as? ProviderDashboardCard }.first
    let regionsBeforePermission = dashboard.regionRebuildCount
    let permissionApplied = dashboard.apply(
      states: [permissionState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, refreshStartedAt: nil,
      now: now, maximumHeight: 2_000, actions: actions)
    let cardAfter = descendants(dashboard).compactMap { $0 as? ProviderDashboardCard }.first
    if !permissionApplied || cardAfter === cardBefore
      || dashboard.regionRebuildCount <= regionsBeforePermission
    {
      failures.append("connection-to-Keychain transition kept an incompatible provider card")
    }
    if !text().contains(where: { $0.localizedCaseInsensitiveContains("permission") }) {
      failures.append("Keychain transition did not render permission guidance")
    }

    weak var releasedDashboard: UsageDashboardView?
    autoreleasepool {
      var stale = state(weeklyUsed: 30, shareUsed: 10)
      stale.error = "Fixture unavailable"
      var candidate: UsageDashboardView? = UsageDashboardView(
        states: [stale], selectedMenuBarProvider: .openAI,
        expandedProvider: .openAI, isRefreshing: false, now: now,
        maximumHeight: 2_000, actions: actions)
      releasedDashboard = candidate
      let candidateCard = candidate.flatMap { root in
        descendants(root).compactMap { $0 as? ProviderDashboardCard }.first
      }
      let candidateRegions = candidate?.regionRebuildCount
      var refreshedStale = state(
        weeklyUsed: 31, shareUsed: 11, todayTokens: 333,
        fetchedAt: now.addingTimeInterval(-4_000))
      refreshedStale.error = "Fixture unavailable"
      let staleApplied = candidate?.apply(
        states: [refreshedStale], selectedMenuBarProvider: .openAI,
        expandedProvider: .openAI, isRefreshing: false, refreshStartedAt: nil,
        now: now, maximumHeight: 2_000, actions: actions)
      let refreshedCard = candidate.flatMap { root in
        descendants(root).compactMap { $0 as? ProviderDashboardCard }.first
      }
      if staleApplied != true || refreshedCard !== candidateCard
        || candidate?.regionRebuildCount != candidateRegions
      {
        failures.append("stale reading update did not retain its provider card")
      }
      candidate = nil
    }
    if releasedDashboard != nil {
      failures.append("dashboard clock closures retained a released view tree")
    }
    return failures
  }
}
