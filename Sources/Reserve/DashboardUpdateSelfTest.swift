import AppKit
import ReserveCore

/// Focused regressions for the dashboard's retained-view update path.
/// Fixtures only: no preferences, credentials, network, or local history.
@MainActor
enum DashboardUpdateSelfTest {
  private final class FrameRecorder: NSObject {
    var heights: [CGFloat] = []

    @MainActor @objc func frameDidChange(_ notification: Notification) {
      if let view = notification.object as? NSView {
        self.heights.append(view.frame.height)
      }
    }
  }

  static func run(store: UsageStore) async -> [String] {
    var failures: [String] = []
    let now = Date()
    let reset = now.addingTimeInterval(3_600)

    func state(
      weeklyUsed: Double, shareUsed: Double, todayTokens: Int64 = 120,
      fetchedAt: Date? = nil, provider: ProviderID = .openAI
    ) -> ProviderViewState {
      var result = ProviderViewState(
        provider: provider,
        snapshot: UsageSnapshot(
          provider: provider,
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
        provider: provider, periodDays: 30, inputTokens: todayTokens * 10,
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

    // An in-place update must not expose the screen ceiling as a temporary
    // popover height while Auto Layout measures a shorter dashboard.
    dashboard.postsFrameChangedNotifications = true
    let frameRecorder = FrameRecorder()
    NotificationCenter.default.addObserver(
      frameRecorder, selector: #selector(FrameRecorder.frameDidChange(_:)),
      name: NSView.frameDidChangeNotification, object: dashboard)
    let beforePrivacyHeight = dashboard.frame.height
    readings[0].hidesPersonalInfo = true
    let privacyApplied = dashboard.apply(
      states: [initialState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, refreshStartedAt: nil,
      now: now, maximumHeight: 2_000, actions: actions)
    NotificationCenter.default.removeObserver(frameRecorder)
    if frameRecorder.heights.max() ?? 0 > max(beforePrivacyHeight, dashboard.frame.height) + 1 {
      failures.append("retained update exposed a temporary oversized popover frame")
    }
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

    // A tall card scrolls on a short display. Reading updates and a change in
    // available display height must not silently move the user's viewport.
    let shortDashboard = UsageDashboardView(
      states: [initialState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, now: now,
      maximumHeight: 420, actions: actions)
    shortDashboard.layoutSubtreeIfNeeded()
    if let scroll = descendants(shortDashboard).compactMap({ $0 as? NSScrollView }).first,
      let document = scroll.documentView
    {
      func offset() -> CGFloat { scroll.contentView.bounds.minY }
      let topApplied = shortDashboard.apply(
        states: [updatedState], selectedMenuBarProvider: .openAI,
        expandedProvider: .openAI, isRefreshing: false, refreshStartedAt: nil,
        now: now, maximumHeight: 380, actions: actions)
      if !topApplied || abs(offset()) > 1 {
        failures.append("short-screen update scrolled the dashboard away from its header")
      }
      let maximumOffset = max(0, document.frame.height - scroll.contentView.bounds.height)
      let targetOffset = min(80, maximumOffset / 2)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: targetOffset))
      scroll.reflectScrolledClipView(scroll.contentView)
      let before = offset()
      let scrolledApplied = shortDashboard.apply(
        states: [state(weeklyUsed: 26, shareUsed: 56, todayTokens: 223)],
        selectedMenuBarProvider: .openAI, expandedProvider: .openAI,
        isRefreshing: false, refreshStartedAt: nil,
        now: now, maximumHeight: 380, actions: actions)
      if !scrolledApplied || abs(offset() - before) > 1 {
        failures.append("retained reading update moved a scrolled dashboard")
      }
    } else {
      failures.append("short-screen dashboard had no scrollable content")
    }

    // Choosing another provider replaces the card in place. The new card has
    // to open at its top, not at the previous card's scroll offset.
    let claudeState = state(weeklyUsed: 30, shareUsed: 40, provider: .anthropic)
    let switchingDashboard = UsageDashboardView(
      states: [initialState, claudeState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, now: now,
      maximumHeight: 380, actions: actions)
    switchingDashboard.layoutSubtreeIfNeeded()
    if let scroll = descendants(switchingDashboard).compactMap({ $0 as? NSScrollView }).first,
      let document = scroll.documentView
    {
      let maximumOffset = max(0, document.frame.height - scroll.contentView.bounds.height)
      scroll.contentView.scroll(to: NSPoint(x: 0, y: min(80, maximumOffset)))
      scroll.reflectScrolledClipView(scroll.contentView)
      let scrolledBefore = scroll.contentView.bounds.minY
      let switched = switchingDashboard.apply(
        states: [initialState, claudeState], selectedMenuBarProvider: .openAI,
        expandedProvider: .anthropic, isRefreshing: false, refreshStartedAt: nil,
        now: now, maximumHeight: 380, actions: actions)
      let switchedScroll = descendants(switchingDashboard).compactMap { $0 as? NSScrollView }.first
      if scrolledBefore < 1 || !switched
        || abs(switchedScroll?.contentView.bounds.minY ?? 0) > 1
      {
        failures.append(
          "switching providers kept the previous card's scroll offset "
            + "(before=\(Int(scrolledBefore)), applied=\(switched), "
            + "after=\(Int(switchedScroll?.contentView.bounds.minY ?? -1)))")
      }
    } else {
      failures.append("short-screen provider switch had no scrollable content")
    }

    let pinnedDashboard = UsageDashboardView(
      states: [initialState], selectedMenuBarProvider: .openAI,
      expandedProvider: .openAI, isRefreshing: false, now: now,
      maximumHeight: 700, actions: actions)
    let pinnedViews = descendants(pinnedDashboard)
    let overview = pinnedViews.first { $0.identifier?.rawValue == "provider-overview" }
    let detail = pinnedViews.first { $0.identifier?.rawValue == "provider-card-openAI" }
    let settings = pinnedViews.first { $0.identifier?.rawValue == "open-settings" }
    if let scroll = pinnedViews.compactMap({ $0 as? NSScrollView }).first {
      let overviewPinned = overview != nil && overview?.enclosingScrollView == nil
      let detailScrolls = detail != nil && detail?.enclosingScrollView === scroll
      let footerPinned = settings != nil && settings?.enclosingScrollView == nil
      if !overviewPinned || !detailScrolls || !footerPinned {
        failures.append(
          "short-screen pinned layout overview=\(overviewPinned), "
            + "detailScrolls=\(detailScrolls), footer=\(footerPinned), "
            + "natural=\(Int(dashboard.frame.height)), viewport=\(Int(pinnedDashboard.frame.height))")
      }
    } else {
      failures.append("short-screen pinned layout did not scroll its detail")
    }

    let fourProviderDashboard = UsageDashboardView(
      states: [initialState, ProviderViewState(provider: .anthropic),
               ProviderViewState(provider: .grok), ProviderViewState(provider: .cursor)],
      selectedMenuBarProvider: .openAI, expandedProvider: .openAI,
      isRefreshing: false, now: now, maximumHeight: 900, actions: actions)
    let fourViews = descendants(fourProviderDashboard)
    let fourScroll = fourViews.compactMap { $0 as? NSScrollView }.first
    let fourOverview = fourViews.first { $0.identifier?.rawValue == "provider-overview" }
    let fourDetail = fourViews.first { $0.identifier?.rawValue == "provider-card-openAI" }
    let fourSettings = fourViews.first { $0.identifier?.rawValue == "open-settings" }
    if fourScroll == nil || fourOverview?.enclosingScrollView != nil
      || fourDetail?.enclosingScrollView !== fourScroll
      || fourSettings?.enclosingScrollView != nil
      || (fourScroll?.frame.height ?? 0) < DashboardMetrics.minimumDetailsViewport
    {
      failures.append(
        "four-provider short-screen layout scroll=\(fourScroll != nil), "
          + "overview=\(fourOverview?.enclosingScrollView == nil), "
          + "detail=\(fourDetail?.enclosingScrollView === fourScroll), "
          + "footer=\(fourSettings?.enclosingScrollView == nil), "
          + "viewport=\(Int(fourScroll?.frame.height ?? 0))")
    }

    var availableHeight: CGFloat = 1_200
    let sizingController = DashboardViewController(
      store: store, maximumHeight: { availableHeight }, actions: actions)
    sizingController.loadViewIfNeeded()
    let updatesBeforeResize = sizingController.fullRebuildCount
      + sizingController.contentUpdateCount
    availableHeight = 380
    sizingController.update()
    if sizingController.preferredContentSize.height > availableHeight + 1
      || sizingController.fullRebuildCount + sizingController.contentUpdateCount
        <= updatesBeforeResize
    {
      failures.append("dashboard ignored a display-height change with unchanged readings")
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
