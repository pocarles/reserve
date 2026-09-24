import AppKit
import ReserveCore

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let store: UsageStore
  private let openSettings: () -> Void
  private let openInsights: () -> Void
  private let setupProvider: (ProviderID) -> Void
  private let isSettingsWindow: (NSWindow?) -> Bool
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private var dashboardController: DashboardViewController?
  private var localMouseMonitor: Any?
  private var globalMouseMonitor: Any?
  /// One minute-level UI clock shared by the menu bar and open popover. Provider
  /// data still follows the store's independent configured refresh interval.
  private var minuteTimer: Timer?
  private let uiRefresh = UISurfaceRefresh()
  private var dashboardIsDirty = true
  private var lastDashboardMinute: Int?
  /// A popover is positioned relative to its status item. Its contents may
  /// update live, but its width stays fixed until the popover closes so the
  /// visible window keeps the same anchor.
  private var lockedStatusItemLength: CGFloat?
  private var renderedStatusProvider: ProviderID?
  /// Whether the popover animates. A resize switches this off for Reduce Motion
  /// and has to restore the configured value rather than assume it was on.
  private var animatesPopover = true

  init(
    store: UsageStore,
    openSettings: @escaping () -> Void,
    openInsights: @escaping () -> Void,
    setupProvider: @escaping (ProviderID) -> Void,
    isSettingsWindow: @escaping (NSWindow?) -> Bool
  ) {
    self.store = store
    self.openSettings = openSettings
    self.openInsights = openInsights
    self.setupProvider = setupProvider
    self.isSettingsWindow = isSettingsWindow
    super.init()
    self.statusItem.button?.toolTip = "Reserve"
    self.statusItem.button?.target = self
    self.statusItem.button?.action = #selector(self.toggleDashboard)
    self.statusItem.button?.sendAction(on: [.leftMouseUp])
    self.popover.behavior = .applicationDefined
    self.popover.animates = true
    self.popover.delegate = self
    self.store.observe { [weak self] in
      self?.uiRefresh.coalesce { [weak self] in
        self?.applyObservedStoreChange()
      }
    }
    // While Reserve follows the system, a system light/dark switch changes no
    // Reserve state, so nothing else would rebuild the open dashboard.
    DistributedNotificationCenter.default.addObserver(
      self, selector: #selector(self.systemAppearanceChanged),
      name: NSNotification.Name("AppleInterfaceThemeChangedNotification"), object: nil)
    self.applyAppearance()
    let now = Date()
    self.updateStatusIcon(now: now)
    self.updateMinuteTimer(now: now)
  }

  deinit {
    DistributedNotificationCenter.default.removeObserver(self)
  }

  private func applyObservedStoreChange() {
    let now = Date()
    self.dashboardIsDirty = true
    self.applyAppearance()
    self.updateStatusIcon(now: now)
    if self.popover.isShown {
      self.updateDashboardIfNeeded(force: true)
    }
    self.updateMinuteTimer(now: now)
  }

  @objc private func systemAppearanceChanged() {
    // The notification arrives fractionally before AppKit updates its own
    // effective appearance.
    Task { @MainActor [weak self] in
      guard let self, self.store.appearanceMode == .system else { return }
      self.applyAppearance()
      self.dashboardIsDirty = true
      if self.popover.isShown { self.updateDashboardIfNeeded(force: true) }
      self.updateStatusIcon()
    }
  }

  /// Pushes the chosen appearance onto the popover, which does not inherit it.
  private func applyAppearance() {
    let appearance = ReserveAppearance.resolvedAppearance
    self.popover.appearance = appearance
    self.popover.contentViewController?.view.window?.appearance = appearance
  }

  func showMenu() {
    self.showDashboard()
  }

  /// Hot key path. An already visible dashboard stays open and keeps its tile.
  func openDashboardFromHotKey() {
    if self.popover.isShown {
      self.bringDashboardToFront()
      return
    }
    self.showDashboard()
  }

  func closeMenuForStressTest() {
    self.popover.performClose(nil)
  }

  /// The window the popover is actually drawing, so lifecycle checks can inspect
  /// what a person can see rather than a controller's detached view.
  var dashboardWindowForTesting: NSWindow? {
    self.popover.contentViewController?.view.window
  }

  var isDashboardShownForTesting: Bool { self.popover.isShown }

  var dashboardHasContentForTesting: Bool {
    guard self.popover.isShown,
      let root = self.dashboardWindowForTesting?.contentView as? UsageDashboardView
    else { return false }
    return !root.subviews.isEmpty && root.frame.height > 0
  }

  var popoverContentSizeForTesting: NSSize { self.popover.contentSize }

  var statusItemLengthForTesting: CGFloat { self.statusItem.length }

  var statusItemScreenFrameForTesting: NSRect? {
    guard let button = self.statusItem.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  var statusItemLengthIsLockedForTesting: Bool { self.lockedStatusItemLength != nil }

  var statusItemProviderForTesting: ProviderID? { self.renderedStatusProvider }

  var dashboardControllerForTesting: DashboardViewController { self.dashboardControllerForUse() }

  var mouseMonitorCountForTesting: Int {
    (self.localMouseMonitor == nil ? 0 : 1) + (self.globalMouseMonitor == nil ? 0 : 1)
  }

  /// The same path a provider tile takes, so lifecycle checks exercise the real
  /// selection rather than writing the store directly.
  func toggleProviderDetailForTesting(_ provider: ProviderID) {
    guard self.store.expandedProvider != provider else { return }
    self.store.expandedProvider = provider
    self.store.requestInsights(for: provider)
    self.expandDashboard()
  }

  func setStressTestAnimationsEnabled(_ enabled: Bool) {
    self.animatesPopover = enabled
    self.popover.animates = enabled
  }

  func validateForSelfTest(settingsWindow: NSWindow?) -> (success: Bool, details: String) {
    guard let statusImage = self.statusItem.button?.image,
      statusImage.isTemplate,
      statusImage.size == ReserveStatusIcon.size
    else {
      return (false, "status item does not have the Reserve template gauge")
    }
    let previewSummaries = self.store.orderedStates
      .filter { self.store.isEnabled($0.provider) }
      .map { AllowanceBuilder.summary(for: $0) }
    let automatic = AllowanceBuilder.menuBarSummary(
      from: previewSummaries, pinnedProvider: nil)
    let automaticSourceWorks =
      automatic.isPinned == false
      && automatic.summary?.provider == .openAI
      && statusImage.accessibilityDescription?.hasPrefix("Reserve") == true
      && self.statusItem.button?.accessibilityLabel()?.contains("Automatic source: OpenAI") == true
    let pinnedSelectionWorks = AllowanceBuilder.menuBarSummary(
      from: previewSummaries, pinnedProvider: .grok)
    let pinnedModelWorks =
      pinnedSelectionWorks.isPinned && pinnedSelectionWorks.summary?.provider == .grok
    let singleSummary = AllowanceBuilder.headline(for: previewSummaries)
    func withState(_ summary: ProviderSummary, _ state: UsagePaceState) -> ProviderSummary {
      ProviderSummary(
        provider: summary.provider, planName: summary.planName, allowances: summary.allowances,
        paceState: state, serviceStatus: summary.serviceStatus,
        isConnecting: summary.isConnecting, isRefreshing: summary.isRefreshing,
        needsConnection: summary.needsConnection,
        connectionToolAvailable: summary.connectionToolAvailable,
        requiresKeychainAccess: summary.requiresKeychainAccess,
        setupAction: summary.setupAction,
        error: summary.error,
        lastUpdated: summary.lastUpdated, localUsage: summary.localUsage,
        subscriptionCostUSD: summary.subscriptionCostUSD, quotaSource: summary.quotaSource,
        includedSpend: summary.includedSpend,
        detailedUsageUnavailable: summary.detailedUsageUnavailable)
    }
    // Aggregate copy is checked against several providers. Indexing directly would
    // crash whenever a provider is disabled, which is an ordinary state.
    guard previewSummaries.count >= 4 else {
      return (false, "aggregate copy needs four enabled providers to check")
    }
    let pluralSummary = AllowanceBuilder.headline(
      for: [
        withState(previewSummaries[0], .deficit(percent: 8)),
        withState(previewSummaries[1], .deficit(percent: 4)),
        withState(previewSummaries[2], .reserve(percent: 12)),
      ])
    let staleSummary = AllowanceBuilder.headline(
      for: [
        withState(previewSummaries[0], .stale),
        withState(previewSummaries[1], .reserve(percent: 12)),
        withState(previewSummaries[2], .reserve(percent: 18)),
      ])
    let oneHealthyStale = AllowanceBuilder.headline(
      for: [
        withState(previewSummaries[0], .stale),
        withState(previewSummaries[1], .reserve(percent: 12)),
        withState(previewSummaries[2], .unknown),
      ])
    let mixedStale = AllowanceBuilder.headline(
      for: [
        withState(previewSummaries[0], .stale),
        withState(previewSummaries[1], .reserve(percent: 12)),
        withState(previewSummaries[2], .onPace),
      ])
    let mixedHealthy = AllowanceBuilder.headline(
      for: [
        withState(previewSummaries[0], .reserve(percent: 12)),
        withState(previewSummaries[1], .onPace),
        withState(previewSummaries[2], .onPace),
      ])
    let freshWithoutForecast = AllowanceBuilder.headline(
      for: [
        withState(previewSummaries[0], .unknown),
        withState(previewSummaries[1], .reserve(percent: 12)),
        withState(previewSummaries[2], .reserve(percent: 18)),
      ])
    let aggregateCopyWorks =
      singleSummary.primary.contains("may run out")
      && pluralSummary.primary.contains("may run out")
      && pluralSummary.secondary.isEmpty
      && staleSummary.primary.contains(previewSummaries[0].provider.displayName)
      && staleSummary.primary.hasSuffix("needs fresh data")
      && staleSummary.secondary.isEmpty
      && oneHealthyStale.primary.hasSuffix("needs fresh data")
      && mixedStale.primary.hasSuffix("needs fresh data")
      && mixedHealthy.primary.hasPrefix("All plans on track")
      // A plan without a forecast never takes the headline from plans that are fine.
      && freshWithoutForecast.primary.hasPrefix("No plan at risk")
      && !freshWithoutForecast.primary.contains("No pace forecast")
      && freshWithoutForecast.secondary.isEmpty
    let forecastNow = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let forecastReset = forecastNow.addingTimeInterval(4 * 86_400 + 2 * 3_600)
    let forecastWindow = UsageWindow(
      id: "forecast-copy", label: "Weekly limit", usedPercent: 75,
      windowMinutes: (7 * 24 + 2) * 60, resetsAt: forecastReset)
    let forecastProjection = UsagePaceProjection.calculate(for: forecastWindow, now: forecastNow)
    let deficitForecastUsesRenewalGap =
      DashboardFormat.forecast(
        Allowance(
          id: forecastWindow.id, title: forecastWindow.label,
          usedPercent: forecastWindow.usedPercent, resetsAt: forecastWindow.resetsAt,
          projection: forecastProjection, isPrimary: true, paceState: .deficit(percent: 25)),
        paceState: .deficit(percent: 25), lastUpdated: forecastNow, now: forecastNow
      ) == "At this pace · may run out 3d 2h before reset"
    let exhaustedWithoutPeriod = Allowance(id: "premium", title: "Premium requests", usedPercent: 100,
      resetsAt: forecastReset, projection: nil, isPrimary: true, paceState: .exhausted)
    let exhaustedEarlyWindow = Allowance(id: "early", title: "5-hour window", usedPercent: 100,
      resetsAt: forecastNow.addingTimeInterval(295 * 60), projection: nil,
      isPrimary: true, paceState: .exhausted, windowMinutes: 300)
    let withoutPeriod = Allowance(id: "premium", title: "Premium requests", usedPercent: 40,
      resetsAt: forecastReset, projection: nil, isPrimary: true, paceState: .unknown)
    let exhaustionAndMissingForecastAreTruthful =
      [exhaustedWithoutPeriod, exhaustedEarlyWindow].allSatisfy {
        DashboardFormat.forecast($0, paceState: .exhausted, lastUpdated: forecastNow, now: forecastNow)
          .hasPrefix("Limit exhausted · resets")
      }
      && DashboardFormat.forecast(withoutPeriod, paceState: .unknown,
        lastUpdated: forecastNow, now: forecastNow) == "Forecast unavailable"
    let nonSharePrimary = AllowanceBuilder.summary(
      for: ProviderViewState(
        provider: .grok,
        snapshot: UsageSnapshot(
          provider: .grok,
          windows: [
            UsageWindow(id: "usage-pool", label: "Usage pool", usedPercent: 20),
            UsageWindow(id: "build-share", label: "Grok Build share", usedPercent: 90),
          ],
          source: "self-test")))
    let primaryWindowIgnoresComponentShares =
      nonSharePrimary.allowances.first(where: \.isPrimary)?.id == "usage-pool"
      && AllowanceBuilder.summary(
        for: ProviderViewState(
          provider: .cursor,
          snapshot: UsageSnapshot(
            provider: .cursor,
            windows: [
              UsageWindow(id: "cursor-models", label: "Cursor Models", usedPercent: 42),
              UsageWindow(id: "other-models", label: "Other Models", usedPercent: 73),
            ],
            source: "self-test")))
        .allowances.first(where: \.isPrimary)?.id == "other-models"
    let urgentWindowBecomesPrimary =
      AllowanceBuilder.summary(
        for: ProviderViewState(
          provider: .openAI,
          snapshot: UsageSnapshot(
            provider: .openAI,
            windows: [
              UsageWindow(id: "five-hour", label: "5 hours", usedPercent: 94,
                windowMinutes: 300, resetsAt: Date().addingTimeInterval(2 * 3_600)),
              UsageWindow(id: "weekly", label: "Weekly", usedPercent: 35,
                windowMinutes: 10_080, resetsAt: Date().addingTimeInterval(5 * 86_400)),
            ],
            source: "self-test")))
        .primary?.id == "five-hour"
      // A nearly spent model limit stays secondary to the plan's weekly limit.
      && AllowanceBuilder.summary(
        for: ProviderViewState(
          provider: .anthropic,
          snapshot: UsageSnapshot(
            provider: .anthropic,
            windows: [
              UsageWindow(id: "five-hour", label: "5 hours", usedPercent: 5,
                windowMinutes: 300, resetsAt: Date().addingTimeInterval(2 * 3_600)),
              UsageWindow(id: "weekly", label: "Weekly", usedPercent: 69,
                windowMinutes: 10_080, resetsAt: Date().addingTimeInterval(3 * 86_400)),
              UsageWindow(id: "scoped-2", label: "Fable weekly", usedPercent: 97,
                windowMinutes: 10_080, resetsAt: Date().addingTimeInterval(3 * 86_400)),
            ],
            source: "self-test")))
        .allowances.map(\.id) == ["weekly", "five-hour", "scoped-2"]
    let compactMoneyKeepsCurrency =
      DashboardFormat.money(14_200) == "$14.2K"
      && DashboardFormat.money(1_420_000) == "$1.42M"
    let localeDate = Date(timeIntervalSince1970: 47_100)
    let usClock = DashboardFormat.localizedDateFormatter(
      template: "jm", locale: Locale(identifier: "en_US"))
    let gbClock = DashboardFormat.localizedDateFormatter(
      template: "jm", locale: Locale(identifier: "en_GB"))
    usClock.timeZone = TimeZone(secondsFromGMT: 0)
    gbClock.timeZone = TimeZone(secondsFromGMT: 0)
    let localizedTimeUsesRegionalClock =
      usClock.string(from: localeDate).contains("PM")
      && !gbClock.string(from: localeDate).contains("PM")
    let semanticColorsWork =
      UsagePaceState.reserve(percent: 10).color.isEqual(NSColor.systemGreen)
      && UsagePaceState.onPace.color.isEqual(NSColor.systemGreen)
      && UsagePaceState.deficit(percent: 5).color.isEqual(NSColor.systemOrange)
      && UsagePaceState.exhausted.color.isEqual(NSColor.systemOrange)
      && !UsagePaceState.reserve(percent: 10).color.isEqual(NSColor.systemRed)
      && !UsagePaceState.onPace.color.isEqual(NSColor.systemRed)
      && !UsagePaceState.deficit(percent: 5).color.isEqual(NSColor.systemRed)
      && !UsagePaceState.exhausted.color.isEqual(NSColor.systemRed)
    let minuteClockIsCoordinated = self.minuteTimer?.timeInterval == 60
    let newestFetch = previewSummaries.compactMap(\.lastUpdated).max() ?? Date()
    let oldestFetch = previewSummaries.compactMap(\.lastUpdated).min() ?? newestFetch
    let resumeRefreshDecisionsWork =
      !UsageStore.resumeRefreshNeeded(
        states: self.store.orderedStates, intervalMinutes: 10,
        isRefreshingAll: false, now: oldestFetch.addingTimeInterval(9 * 60))
      && UsageStore.resumeRefreshNeeded(
        states: self.store.orderedStates, intervalMinutes: 10,
        isRefreshingAll: false, now: newestFetch.addingTimeInterval(11 * 60))
      && !UsageStore.resumeRefreshNeeded(
        states: self.store.orderedStates, intervalMinutes: 10,
        isRefreshingAll: true, now: newestFetch.addingTimeInterval(11 * 60))
    let originalProvider = self.store.menuBarProvider
    let originalRemaining = self.store.menuBarShowsRemaining
    let originalReset = self.store.menuBarShowsReset
    self.store.menuBarProvider = .openAI
    self.store.menuBarShowsRemaining = true
    self.store.menuBarShowsReset = true
    self.uiRefresh.flush()
    let providerStatusWorks =
      self.statusItem.length == self.stableStatusItemLength()
      && self.statusItem.button?.image?.accessibilityDescription == ProviderID.openAI.displayName
      && self.statusItem.button?.title.contains("%") == true
      && self.statusItem.button?.accessibilityLabel()?.contains("Pinned provider: OpenAI") == true
    self.store.menuBarProvider = originalProvider
    self.store.menuBarShowsRemaining = originalRemaining
    self.store.menuBarShowsReset = originalReset
    let dashboardController = self.dashboardControllerForUse()
    dashboardController.loadViewIfNeeded()
    dashboardController.view.layoutSubtreeIfNeeded()
    let descendants = Self.descendants(of: dashboardController.view)
    let identifiers = Set(descendants.compactMap { $0.identifier?.rawValue })
    let labels = descendants.compactMap { ($0 as? NSTextField)?.stringValue }
    let dashboardTypographyIsReadable = descendants.compactMap { ($0 as? NSTextField)?.font }
      .allSatisfy { $0.pointSize >= 8 }
    let providerTiles = ProviderID.allCases.filter {
      identifiers.contains("provider-tile-\($0.rawValue)")
    }.count
    let providerCards = ProviderID.allCases.filter {
      identifiers.contains("provider-card-\($0.rawValue)")
    }.count
    let actionsPresent =
      identifiers.contains("refresh-all")
      && identifiers.contains("open-settings")
      && identifiers.contains("open-insights")
      && identifiers.contains("more-actions")
    // Quit moved out of the footer; it must still be reachable.
    let quitRemainsReachable =
      descendants.compactMap { $0 as? DashboardMenuButton }.first.map {
        $0.makeMenu().items.contains { $0.title == "Quit Reserve" }
      } ?? false
    let logosPresent = ProviderID.allCases.allSatisfy {
      identifiers.contains("provider-logo-\($0.rawValue)")
    }
    let bundledProviderArtworkPresent = ProviderID.allCases.allSatisfy {
      // Copilot uses a system symbol; Z.ai, Kimi and Gemini use a neutral initial.
      if [.copilot, .zai, .kimi, .gemini].contains($0) {
        let image = ProviderArtwork.image(for: $0)
        return image.isValid && image.size.width > 0 && image.size.height > 0
          && !image.representations.isEmpty
      }
      return ProviderArtwork.hasBundledMark(for: $0)
    }
    let dashboardButtons = descendants.compactMap { $0 as? NSButton }
    let footerButtons = dashboardButtons.filter {
      ["open-settings", "open-insights"].contains($0.identifier?.rawValue ?? "")
    }
    let footerButtonsArePadded =
      footerButtons.count == 2
      && footerButtons.allSatisfy { $0.fittingSize.height >= 30 && $0.fittingSize.width >= 72 }
    let providerButtons = dashboardButtons.filter {
      let identifier = $0.identifier?.rawValue ?? ""
      return identifier.hasPrefix("connect-") || identifier.hasPrefix("status-")
    }
    let providerButtonsArePadded = providerButtons.allSatisfy {
      $0.fittingSize.height >= 22 && $0.fittingSize.width >= 56
    }
    let refreshButtonIsPadded = dashboardButtons.first {
      $0.identifier?.rawValue == "refresh-all"
    }.map { $0.fittingSize.height >= 26 && $0.fittingSize.width >= 26 } ?? false
    let originalDirectProvider = self.store.menuBarProvider
    let directCard = descendants.compactMap { $0 as? ProviderDashboardCard }.first {
      $0.identifier?.rawValue == "provider-card-openAI"
    }
    self.store.menuBarProvider = .cursor
    dashboardController.update()
    dashboardController.view.layoutSubtreeIfNeeded()
    let explicitPinButton = Self.descendants(of: dashboardController.view)
      .compactMap { $0 as? NSButton }.first {
        $0.identifier?.rawValue == "pin-menu-bar-openAI"
    }
    explicitPinButton?.performClick(nil)
    let explicitMenuBarSelectionWorks = explicitPinButton != nil
      && self.store.menuBarProvider == .openAI
    directCard?.selectForMenuBar()
    let directProviderSelectionWorks = self.store.menuBarProvider == .openAI
    let fullCardSelectionHitTargetWorks = directCard.map {
      $0.hitTest(NSPoint(x: $0.frame.midX, y: $0.frame.midY)) === $0
    } ?? false
    let firstClickSelectionWorks =
      directCard?.acceptsFirstMouse(for: nil) == true
      && ReserveTextButton(title: "Test", action: {}).acceptsFirstMouse(for: nil)
    self.store.menuBarProvider = originalDirectProvider
    let hasScrollView = descendants.contains { $0 is NSScrollView }
    let size = dashboardController.preferredContentSize
    let contentFits =
      descendants.compactMap { $0 as? NSStackView }.first.map {
        let container = $0.enclosingScrollView?.documentView ?? dashboardController.view
        return $0.frame.minY >= 0 && $0.frame.maxY <= container.bounds.height
      } ?? false
    // A short screen is expected to add a scroll view, but only once the
    // dashboard has consumed all space that can safely fit below the menu bar.
    let scrollingMatchesAvailableSpace =
      !hasScrollView
      || abs(size.height - DashboardMetrics.availableHeight(on: NSScreen.main)) <= 1
    let dashboardFits =
      size.width == DashboardMetrics.width
      && size.height >= DashboardMetrics.minimumHeight
      && size.height <= DashboardMetrics.availableHeight(on: NSScreen.main)
    // Four rows of tiles plus the selected detail exceed a small display's
    // viewport. The viewport must fit and scrolling must reveal the fifth tile.
    let compactCeiling = DashboardMetrics.availableHeight(on: nil, visibleHeight: 700)
    let compactDashboard = UsageDashboardView(
      states: self.store.orderedStates, selectedMenuBarProvider: nil,
      isRefreshing: false, now: Date(), maximumHeight: compactCeiling,
      actions: DashboardActions(
        refreshAll: {}, connectProvider: { _ in }, selectMenuBarProvider: { _ in },
        openSettings: {}, openInsights: {}, dismiss: {}, toggleProviderDetail: { _ in },
        quit: {}, apiConsumptionReadings: { [] }))
    compactDashboard.layoutSubtreeIfNeeded()
    let compactViews = Self.descendants(of: compactDashboard)
    let fifthProviderReachable: Bool
    if let scroll = compactViews.compactMap({ $0 as? NSScrollView }).first,
      let document = scroll.documentView,
      let fifth = compactViews.first(where: { $0.identifier?.rawValue == "provider-tile-copilot" })
    {
      document.layoutSubtreeIfNeeded()
      let fifthRect = fifth.convert(fifth.bounds, to: document)
      document.scrollToVisible(fifthRect)
      fifthProviderReachable = compactDashboard.frame.height <= compactCeiling
        && scroll.frame.height <= compactCeiling
        && document.frame.height > scroll.contentView.bounds.height
        && scroll.documentVisibleRect.insetBy(dx: -1, dy: -1).contains(fifthRect)
    } else { fifthProviderReachable = false }
    // The glance view leads with one conclusion, not a strip of totals.
    let headlinePresent = identifiers.contains("dashboard-headline")
    let activityMetricsAreGone =
      !labels.contains("PROVIDERS")
      && !labels.contains("TOKENS TODAY")
      && !labels.contains("TOKENS LAST 30D")
      && !labels.contains("SAVED LAST 30D")
      && !labels.contains("API VALUE")
    // Every percentage states what it measures, in both tiles and detail.
    let percentagesAreLabelled =
      previewSummaries.allSatisfy { summary in
        guard summary.primary != nil else { return true }
        let suffix = summary.paceState == .stale ? "% last known" : "% left"
        return labels.contains { $0.hasSuffix(suffix) }
      }
      && !labels.contains { $0.hasSuffix("% used") }
      && DashboardFormat.remainingPercent(99.7525) == "99"
    let forecastCount = descendants.filter { $0.identifier?.rawValue == "forecast" }.count
    let allowanceCount = descendants.filter {
      ($0.identifier?.rawValue ?? "").hasPrefix("allowance-")
    }.count
    let selectedSummary = self.store.expandedProvider.flatMap { selected in
      previewSummaries.first(where: { $0.provider == selected })
    } ?? previewSummaries.first
    let expectedForecastCount = selectedSummary.flatMap { summary in
      summary.primary.map {
        DashboardFormat.showsForecast(
          $0, paceState: summary.paceState,
          observationTimeKnown: summary.observationTimeKnown) ? 1 : 0
      }
    } ?? 0
    let forecastsPresent =
      forecastCount == expectedForecastCount
      && allowanceCount >= 1
      && labels.contains {
        $0.hasPrefix("On track") || $0.hasPrefix("On pace")
          || $0.hasPrefix("At this pace") || $0.hasPrefix("Forecast unavailable")
          || $0 == "Too early to forecast" || $0 == "No usage yet"
      }
    // Provider availability is announced only when it is not normal.
    let serviceStatusIsExceptionOnly =
      !identifiers.contains("status-anthropic")
      && !identifiers.contains("status-openAI")
      && !identifiers.contains("status-grok")
      && !identifiers.contains("status-cursor")
    let expectedSecondaryWindows = selectedSummary?.secondary.count ?? 0
    let secondaryWindowsPresent =
      descendants.filter { ($0.identifier?.rawValue ?? "").hasPrefix("secondary-") }.count
      == expectedSecondaryWindows
    // Motion: the refresh control turns only while a refresh is in flight, and
    // nothing animates when the system asks for less motion.
    let idleSpinner = descendants.compactMap { $0 as? ReserveIconButton }.first {
      $0.identifier?.rawValue == "refresh-all"
    }
    let refreshingView = UsageDashboardView(
      states: self.store.orderedStates.filter { self.store.isEnabled($0.provider) },
      selectedMenuBarProvider: self.store.menuBarProvider,
      isRefreshing: true,
      refreshStartedAt: Date().addingTimeInterval(-0.4),
      now: Date(),
      actions: DashboardActions(
        refreshAll: {}, connectProvider: { _ in }, selectMenuBarProvider: { _ in },
        openSettings: {}, openInsights: {}, dismiss: {}, toggleProviderDetail: { _ in },
        quit: {}, apiConsumptionReadings: { [] }))
    refreshingView.layoutSubtreeIfNeeded()
    let busySpinner = Self.descendants(of: refreshingView).compactMap { $0 as? ReserveIconButton }
      .first { $0.identifier?.rawValue == "refresh-all" }
    let motionIsPurposeful =
      idleSpinner?.isSpinning == false
      && busySpinner?.isSpinning == !ReserveMotion.isReduced
      && ReserveMotion.duration(0.22) == (ReserveMotion.isReduced ? 0 : 0.22)

    let staleCard = ProviderDashboardCard(
      summary: withState(previewSummaries[0], .stale), now: Date(),
      isSelectedForMenuBar: false, connectProvider: { _ in },
      selectMenuBarProvider: { _ in })
    staleCard.layoutSubtreeIfNeeded()
    let staleDescendants = Self.descendants(of: staleCard)
    let staleFreshnessIsVisible =
      staleDescendants.contains {
        $0.identifier?.rawValue == "freshness-\(previewSummaries[0].provider.rawValue)"
      }
      && staleDescendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains {
        $0.contains("Cached") && $0.contains("last checked")
      }
    let unknownCard = ProviderDashboardCard(
      summary: withState(previewSummaries[0], .unknown), now: Date(),
      isSelectedForMenuBar: false, connectProvider: { _ in },
      selectMenuBarProvider: { _ in })
    unknownCard.layoutSubtreeIfNeeded()
    let unknownDescendants = Self.descendants(of: unknownCard)
    let freshWithoutForecastDoesNotLookStale =
      !unknownDescendants.contains {
        ($0.identifier?.rawValue ?? "").hasPrefix("freshness-")
      }
      && !unknownDescendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains {
        $0.contains("Cached")
      }

    // Keyboard: overview tiles take focus and both Space and Return navigate.
    let keyboardReachable =
      descendants.compactMap { $0 as? ProviderOverviewTile }.count == ProviderID.allCases.count
      && descendants.compactMap { $0 as? ProviderOverviewTile }.allSatisfy {
        $0.acceptsFirstResponder && $0.canBecomeKeyView
      }
      && dashboardController.view.acceptsFirstResponder
      && dashboardController.view.responds(to: #selector(NSResponder.cancelOperation(_:)))
      && dashboardController.firstKeyView() is ProviderOverviewTile
    func key(_ characters: String) -> NSEvent? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: 0)
    }
    let spaceSelectsProvider: Bool
    let returnOpensDetail: Bool
    if let tile = descendants.compactMap({ $0 as? ProviderOverviewTile }).first(where: {
      $0.identifier?.rawValue == "provider-tile-grok"
    }), let space = key(" "), let enter = key("\r") {
      let beforeExpansion = self.store.expandedProvider
      tile.keyDown(with: space)
      spaceSelectsProvider = self.store.expandedProvider == .grok
      tile.keyDown(with: enter)
      returnOpensDetail = self.store.expandedProvider == .grok
      self.store.expandedProvider = beforeExpansion
      dashboardController.update()
      dashboardController.view.layoutSubtreeIfNeeded()
    } else {
      spaceSelectsProvider = false
      returnOpensDetail = false
    }

    // VoiceOver: tiles speak their whole state, and decoration stays silent.
    let liveDescendants = Self.descendants(of: dashboardController.view)
    let spokenRows = liveDescendants.compactMap { $0 as? ProviderOverviewTile }
    let rowsAreSpoken =
      spokenRows.count == ProviderID.allCases.count
      && spokenRows.allSatisfy { row in
        let summary = previewSummaries.first {
          row.identifier?.rawValue == "provider-tile-\($0.provider.rawValue)"
        }
        let expected = summary?.paceState == .stale ? "percent last known" : "percent left"
        return row.accessibilityRole() == .button
          && (row.accessibilityLabel() ?? "").isEmpty == false
          && (row.accessibilityValue() as? String ?? "").contains(expected)
          && (row.accessibilityHelp() ?? "").isEmpty == false
      }
    // Decoration must not announce itself: the row already says which provider
    // it is, so no image may carry its own label.
    let decorationIsSilent = liveDescendants.compactMap { $0 as? NSImageView }
      .allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty }
    let renderedMeters = liveDescendants.compactMap { $0 as? ReserveMeter }
    // Every tile has its primary meter. The selected detail repeats that meter
    // at full width and may add provider-specific secondary limits.
    var meteredAllowances: [(allowance: Allowance, paceState: UsagePaceState)] =
      previewSummaries.compactMap { summary in
        summary.primary.map { ($0, summary.paceState) }
      }
    if let selectedSummary, let primary = selectedSummary.primary {
      meteredAllowances.append((primary, selectedSummary.paceState))
      if ProviderDescriptor.forProvider(selectedSummary.provider).capabilities.contains(.limitMeters) {
        meteredAllowances.append(contentsOf: selectedSummary.secondary.filter {
          !$0.isComponentShare
        }.map { ($0, $0.paceState) })
      }
    }
    let metersAreSpoken = zip(renderedMeters, meteredAllowances).allSatisfy { meter, entry in
        meter.accessibilityRole() == .progressIndicator
          && (meter.accessibilityLabel() ?? "").isEmpty == false
          && (meter.accessibilityValue() as? String ?? "").contains(entry.paceState == .stale ? "percent last known" : "percent left")
      }
    let meterSemanticsWork =
      renderedMeters.count == meteredAllowances.count
      && zip(renderedMeters, meteredAllowances.map(\.allowance)).allSatisfy { meter, allowance in
        let expectedPace = allowance.paceState == .stale ? nil : allowance.expectedPercent.map { 100 - $0 }
        let paceMatches: Bool =
          switch (meter.paceRemainingPercentForTesting, expectedPace) {
          case (nil, nil): true
          // Pace moves with the clock: on a five-hour window 0.001 points is
          // under a fifth of a second, less than a slow runner takes between
          // drawing the meter and checking it.
          case (.some(let rendered), .some(let expected)): abs(rendered - expected) < 0.05
          default: false
          }
        return abs(meter.remainingPercentForTesting - allowance.remainingPercent) < 0.001
          && paceMatches
      }
    let chartScaleWorks =
      ReserveSparkline.heightFraction(tokens: 0, peak: 10_000) == 0
      && ReserveSparkline.heightFraction(tokens: 10_000, peak: 10_000) == 1
      && abs(ReserveSparkline.heightFraction(tokens: 400, peak: 10_000) - 0.2) < 0.001
    let cursorAccountUsageSurvivesLocalScan =
      UsageStore.usageAfterLocalScan(
        provider: .cursor,
        snapshot: self.store.states[.cursor]?.snapshot,
        scanned: nil) == self.store.states[.cursor]?.snapshot?.accountUsage
      && UsageStore.usageAfterLocalScan(
        provider: .openAI,
        snapshot: self.store.states[.openAI]?.snapshot,
        scanned: self.store.states[.openAI]?.localUsage)
        == self.store.states[.openAI]?.localUsage

    // Overview navigation: every provider gets one tile, one detail panel is
    // present, and the old per-row accordion controls are gone.
    let overviewNavigationPresent =
      identifiers.contains("provider-overview")
      && providerTiles == ProviderID.allCases.count
      && providerCards == 1
      && !identifiers.contains { $0.hasPrefix("disclose-") }
    let originalExpansion = self.store.expandedProvider
    self.store.expandedProvider = .anthropic
    dashboardController.update()
    dashboardController.view.layoutSubtreeIfNeeded()
    let expanded = Self.descendants(of: dashboardController.view)
    let expandedIDs = Set(expanded.compactMap { $0.identifier?.rawValue })
    let expandedLabels = expanded.compactMap { ($0 as? NSTextField)?.stringValue }
    let expandedAnthropic = expanded.compactMap { $0 as? ProviderDashboardCard }.first {
      $0.identifier?.rawValue == "provider-card-anthropic"
    }
    let expandedAnthropicDescendants = expandedAnthropic.map { Self.descendants(of: $0) } ?? []
    let detailLayersPresent =
      // Secondary windows stay compact even when details are open.
      expandedAnthropicDescendants.filter {
        ($0.identifier?.rawValue ?? "").hasPrefix("secondary-")
      }.count == 2
      && expandedAnthropicDescendants.filter {
        ($0.identifier?.rawValue ?? "").hasPrefix("allowance-detail-")
      }.isEmpty
      && expandedLabels.contains { $0.hasSuffix("% left") }
      // Activity and estimated value.
      && expandedIDs.contains("usage-detail-anthropic")
      && expandedLabels.contains("Estimated API value")
      // The history chart lives with the activity numbers.
      && expandedIDs.contains("usage-chart-anthropic")
      && expandedLabels.contains { $0.contains("compressed scale") }
      // When the numbers were last checked; the transport name stays out of
      // the card because it means nothing to most people.
      && expandedIDs.contains("usage-checked-anthropic")
      && !expandedIDs.contains("usage-source-anthropic")
      && expandedLabels.contains("Last checked")
      && !expandedLabels.contains("Source")
      // The internal provenance block is intentionally absent from every provider.
      && !expandedIDs.contains { $0.hasPrefix("sources-") }
      // Only the selected provider owns the detail panel.
      && !expandedIDs.contains("usage-detail-openAI")
      && !expandedIDs.contains("usage-detail-grok")
      && !expandedIDs.contains("usage-detail-cursor")
    self.store.expandedProvider = originalExpansion
    dashboardController.update()
    dashboardController.view.layoutSubtreeIfNeeded()

    // Menu-bar selection is a quiet mark, not a card treatment.
    let selectionIsQuiet: Bool = {
      let original = self.store.menuBarProvider
      self.store.menuBarProvider = .anthropic
      dashboardController.update()
      dashboardController.view.layoutSubtreeIfNeeded()
      let tileMarks = Self.descendants(of: dashboardController.view)
        .compactMap { $0 as? ProviderOverviewTile }
        .flatMap { Self.descendants(of: $0) }
        .filter { ($0.identifier?.rawValue ?? "").hasPrefix("menu-bar-pin-") && !$0.isHidden }
      self.store.menuBarProvider = original
      dashboardController.update()
      dashboardController.view.layoutSubtreeIfNeeded()
      return tileMarks.count == 1
    }()
    let oauthURLParsingIsSafe =
      UsageStore.authorizationURL(
        in: "Authenticate at https://claude.com/cai/oauth/authorize?code=sample",
        for: .anthropic)?.host
      == "claude.com"
      && UsageStore.authorizationURL(
        in: "Continue at https://auth.openai.com/oauth/authorize?code=sample",
        for: .openAI)?.host
        == "auth.openai.com"
      && UsageStore.authorizationURL(
        in: "Continue at https://auth.x.ai/oauth/authorize?code=sample",
        for: .grok)?.host
        == "auth.x.ai"
      && UsageStore.authorizationURL(
        in: "Continue at https://auth.cursor.com/oauth/authorize?code=sample",
        for: .cursor)?.host
        == "auth.cursor.com"
      && UsageStore.authorizationURL(
        in: "https://example.com/oauth/authorize?code=not-trusted", for: .anthropic) == nil
    let updateMigrationWorks: Bool = {
      let domain = "Reserve.UpdaterMigration.SelfTest"
      guard let defaults = UserDefaults(suiteName: domain) else { return false }
      let plist = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Preferences/\(domain).plist")
      defaults.removePersistentDomain(forName: domain)
      try? FileManager.default.removeItem(at: plist)
      defer {
        defaults.removePersistentDomain(forName: domain)
        try? FileManager.default.removeItem(at: plist)
      }
      defaults.set(true, forKey: ReserveUpdater.legacyAutomaticChecksKey)
      let migrated = ReserveUpdater.migrateLegacyAutomaticChecks(
        defaults: defaults, domainName: domain)
      let carriedForward = defaults.bool(forKey: ReserveUpdater.automaticChecksKey)
      defaults.set(false, forKey: ReserveUpdater.automaticChecksKey)
      let preserved = !ReserveUpdater.migrateLegacyAutomaticChecks(
        defaults: defaults, domainName: domain)
        && !defaults.bool(forKey: ReserveUpdater.automaticChecksKey)
      return migrated && carriedForward && preserved
        && ReserveUpdater.dailyInterval == 24 * 3_600
    }()
    // Scheduled refreshes honor the configured interval. A recent manual
    // refresh still prevents an unnecessary provider subprocess.
    func state(_ used: Double, fetchedMinutesAgo: Double, resetsInHours: Double) -> ProviderViewState {
      var value = ProviderViewState(provider: .openAI)
      value.snapshot = UsageSnapshot(
        provider: .openAI,
        windows: [
          UsageWindow(
            id: "weekly", label: "Weekly", usedPercent: used, windowMinutes: 10_080,
            resetsAt: Date().addingTimeInterval(resetsInHours * 3_600))
        ],
        fetchedAt: Date().addingTimeInterval(-fetchedMinutesAgo * 60),
        source: "scheduling check")
      return value
    }
    let calm = state(20, fetchedMinutesAgo: 5, resetsInHours: 100)
    let scheduledRefreshWorks =
      // Calm and recently refreshed: skip.
      !UsageStore.scheduledRefreshIsWorthwhile(
        states: [calm], lastCompletedAt: Date().addingTimeInterval(-5 * 60), intervalMinutes: 30)
      // Refresh once the configured interval has elapsed.
      && UsageStore.scheduledRefreshIsWorthwhile(
        states: [calm], lastCompletedAt: Date().addingTimeInterval(-31 * 60), intervalMinutes: 30)
      // Nothing cached yet.
      && UsageStore.scheduledRefreshIsWorthwhile(
        states: [ProviderViewState(provider: .openAI)],
        lastCompletedAt: Date().addingTimeInterval(-60), intervalMinutes: 30)
      // Close to a limit.
      && UsageStore.scheduledRefreshIsWorthwhile(
        states: [state(85, fetchedMinutesAgo: 5, resetsInHours: 100)],
        lastCompletedAt: Date().addingTimeInterval(-5 * 60), intervalMinutes: 30)
      // Close to a reset.
      && UsageStore.scheduledRefreshIsWorthwhile(
        states: [state(20, fetchedMinutesAgo: 5, resetsInHours: 0.5)],
        lastCompletedAt: Date().addingTimeInterval(-5 * 60), intervalMinutes: 30)
      // Stale data.
      && UsageStore.scheduledRefreshIsWorthwhile(
        states: [state(20, fetchedMinutesAgo: 45, resetsInHours: 100)],
        lastCompletedAt: Date().addingTimeInterval(-5 * 60), intervalMinutes: 30)
    let unrelatedWindow = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
      styleMask: [.titled], backing: .buffered, defer: false)
    let outsideClickDismissalWorks =
      settingsWindow.map { !self.shouldDismissDashboard(forClickedWindow: $0) } == true
      && self.shouldDismissDashboard(forClickedWindow: unrelatedWindow)
    let clockAndDisclosureUpdatesWork = Self.dashboardClockAndDisclosureChecks()
    let expandRequestsDetails = self.expandingAProviderRequestsItsDetails()
    let dashboardSelectionPersists = Self.dashboardSelectionPersistenceWorks()
    let historyPlaceholdersAreHonest = Self.historyPlaceholderChecks()
    let apiDetailsOpen = Self.apiDetailChecks()
    let hotKeyOpensDashboard = self.hotKeyOpensExistingDashboard()
    let shareCardStaysPrivate = Self.shareCardOmitsPersonalText()
    let privacyToggleRestores = self.privacyToggleRestoresOriginals()
    let menuOffersShareAndPrivacy = descendants.compactMap { $0 as? DashboardMenuButton }.first.map {
      button in
      let items = button.makeMenu().items
      let titles = items.map(\.title)
      let actionableItemsHaveIcons = items.filter { !$0.isSeparatorItem }.allSatisfy {
        $0.image != nil
      }
      return titles.contains("Share usage…") && titles.contains("Hide personal info")
        && actionableItemsHaveIcons
    } ?? false
    guard providerTiles == ProviderID.allCases.count, providerCards == 1,
      actionsPresent, quitRemainsReachable,
      logosPresent, bundledProviderArtworkPresent, scrollingMatchesAvailableSpace, contentFits,
      dashboardFits, fifthProviderReachable, headlinePresent,
      activityMetricsAreGone, percentagesAreLabelled, forecastsPresent, overviewNavigationPresent,
      detailLayersPresent, keyboardReachable, spaceSelectsProvider, returnOpensDetail,
      rowsAreSpoken, decorationIsSilent, metersAreSpoken, meterSemanticsWork, motionIsPurposeful,
      chartScaleWorks,
      serviceStatusIsExceptionOnly, secondaryWindowsPresent, selectionIsQuiet,
      providerStatusWorks, directProviderSelectionWorks, fullCardSelectionHitTargetWorks,
      explicitMenuBarSelectionWorks,
      firstClickSelectionWorks, footerButtonsArePadded, providerButtonsArePadded,
      refreshButtonIsPadded, dashboardTypographyIsReadable, oauthURLParsingIsSafe,
      outsideClickDismissalWorks, updateMigrationWorks,
      scheduledRefreshWorks, cursorAccountUsageSurvivesLocalScan,
      staleFreshnessIsVisible, freshWithoutForecastDoesNotLookStale,
      automaticSourceWorks,
      pinnedModelWorks, aggregateCopyWorks, deficitForecastUsesRenewalGap,
      exhaustionAndMissingForecastAreTruthful, clockAndDisclosureUpdatesWork,
      primaryWindowIgnoresComponentShares, urgentWindowBecomesPrimary, compactMoneyKeepsCurrency,
      localizedTimeUsesRegionalClock,
      semanticColorsWork, minuteClockIsCoordinated, resumeRefreshDecisionsWork,
      expandRequestsDetails, dashboardSelectionPersists, historyPlaceholdersAreHonest,
      apiDetailsOpen, hotKeyOpensDashboard, shareCardStaysPrivate,
      privacyToggleRestores, menuOffersShareAndPrivacy
    else {
      return (
        false,
        "dashboard fifthProviderReachable=\(fifthProviderReachable), tiles=\(providerTiles)/\(ProviderID.allCases.count), detailCards=\(providerCards), actions=\(actionsPresent), quitReachable=\(quitRemainsReachable), logos=\(logosPresent), bundledArtwork=\(bundledProviderArtworkPresent), scroll=\(hasScrollView), adaptiveScroll=\(scrollingMatchesAvailableSpace), fits=\(contentFits), size=\(dashboardFits) (\(Int(size.width))×\(Int(size.height))), headline=\(headlinePresent), activityGone=\(activityMetricsAreGone), labelledPercentages=\(percentagesAreLabelled), forecasts=\(forecastsPresent) (\(forecastCount)/\(allowanceCount)), forecastRenewalGap=\(deficitForecastUsesRenewalGap), exhaustionTruth=\(exhaustionAndMissingForecastAreTruthful), clockDisclosure=\(clockAndDisclosureUpdatesWork), primaryNonShare=\(primaryWindowIgnoresComponentShares), urgentPrimary=\(urgentWindowBecomesPrimary), compactMoney=\(compactMoneyKeepsCurrency), localizedTime=\(localizedTimeUsesRegionalClock), overviewNavigation=\(overviewNavigationPresent), detailLayers=\(detailLayersPresent), keyboard=\(keyboardReachable), space=\(spaceSelectsProvider), return=\(returnOpensDetail), spokenRows=\(rowsAreSpoken), silentDecoration=\(decorationIsSilent), spokenMeters=\(metersAreSpoken), meterSemantics=\(meterSemanticsWork), chartScale=\(chartScaleWorks), motion=\(motionIsPurposeful), staleFreshness=\(staleFreshnessIsVisible), freshUnknown=\(freshWithoutForecastDoesNotLookStale), statusExceptionOnly=\(serviceStatusIsExceptionOnly), secondary=\(descendants.filter { ($0.identifier?.rawValue ?? "").hasPrefix("secondary-") }.count)/\(expectedSecondaryWindows), quietSelection=\(selectionIsQuiet), providerStatus=\(providerStatusWorks), explicitPin=\(explicitMenuBarSelectionWorks), directSelection=\(directProviderSelectionWorks), fullCardHitTarget=\(fullCardSelectionHitTargetWorks), firstClick=\(firstClickSelectionWorks), footerPadding=\(footerButtonsArePadded), providerPadding=\(providerButtonsArePadded), refreshPadding=\(refreshButtonIsPadded), readableType=\(dashboardTypographyIsReadable), oauthURL=\(oauthURLParsingIsSafe), outsideDismissal=\(outsideClickDismissalWorks), updateMigration=\(updateMigrationWorks), scheduledRefresh=\(scheduledRefreshWorks), automatic=\(automaticSourceWorks), pinned=\(pinnedModelWorks), aggregate=\(aggregateCopyWorks), semanticColors=\(semanticColorsWork), minuteClock=\(minuteClockIsCoordinated), resumeRefresh=\(resumeRefreshDecisionsWork), expandRequestsDetails=\(expandRequestsDetails), selectionPersists=\(dashboardSelectionPersists), historyPlaceholders=\(historyPlaceholdersAreHonest), apiDetails=\(apiDetailsOpen), hotKey=\(hotKeyOpensDashboard), sharePrivate=\(shareCardStaysPrivate), privacyToggle=\(privacyToggleRestores), menuShare=\(menuOffersShareAndPrivacy)"
      )
    }
    return (
      true,
      "dashboard leads with one factual conclusion, gives \(providerTiles) providers a glanceable tile, restores one selected detail panel, uses fixed semantic colors without red quota states, selects the automatic or pinned menu-bar source, shares one minute clock, refreshes stale data after resume, takes keyboard focus with Space and Return, and fits adaptively on the available screen"
    )
  }

  /// Captures the dashboard as the popover is actually showing it, in the
  /// popover window's own appearance. `renderDashboard` draws the controller's
  /// view offscreen, which cannot show a popover-only defect.
  func renderLiveDashboard(to url: URL) throws {
    guard let view = self.popover.contentViewController?.view,
      view.window != nil
    else { throw DashboardRenderError.statusButtonUnavailable }
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw DashboardRenderError.bitmapUnavailable
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw DashboardRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }

  func renderDashboard(to url: URL) throws {
    let dashboardController = self.dashboardControllerForUse()
    self.updateDashboardIfNeeded(force: true)
    let view = dashboardController.view
    view.frame = NSRect(origin: .zero, size: dashboardController.preferredContentSize)
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw DashboardRenderError.bitmapUnavailable
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw DashboardRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }

  /// Captures the current status-item model into a deterministic dark QA strip.
  /// This keeps automatic versus pinned icon/text behavior testable without
  /// relying on the host Mac's menu-bar layout, appearance, or wallpaper.
  func renderMenuBar(to url: URL) throws {
    guard let button = self.statusItem.button else {
      throw DashboardRenderError.statusButtonUnavailable
    }
    self.updateStatusIcon()
    let now = Date()
    let summaries = self.store.orderedStates
      .filter { self.store.isEnabled($0.provider) }
      .map { AllowanceBuilder.summary(for: $0, now: now) }
    let summary = AllowanceBuilder.menuBarSummary(
      from: summaries, pinnedProvider: self.store.menuBarProvider).summary
    let title = NSMutableAttributedString()
    if self.store.menuBarShowsRemaining {
      title.append(
        NSAttributedString(
          string: summary?.primary.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—%",
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: summary?.paceState.color ?? NSColor.white,
          ]))
    }
    if self.store.menuBarShowsReset {
      if title.length > 0 { title.append(NSAttributedString(string: "  ")) }
      let reset = summary?.primary?.resetsAt.flatMap { $0 > now ? $0 : nil }
      title.append(
        NSAttributedString(
          string: reset.map { Self.shortCountdown(to: $0, now: now) } ?? "—",
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.white,
          ]))
    }

    let label = NSTextField(labelWithAttributedString: title)
    label.drawsBackground = false
    label.sizeToFit()
    let titleWidth = title.length == 0 ? 0 : ceil(label.fittingSize.width)
    let canvasSize = NSSize(width: 18 + titleWidth + 28, height: 36)
    let canvas = NSView(frame: NSRect(origin: .zero, size: canvasSize))
    canvas.wantsLayer = true
    canvas.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
    canvas.layer?.cornerRadius = 12

    let icon = NSImageView(frame: NSRect(x: 11, y: 9, width: 18, height: 18))
    icon.image = button.image
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.contentTintColor = .white
    canvas.addSubview(icon)
    if title.length > 0 {
      label.frame = NSRect(x: 29, y: 8, width: titleWidth, height: 20)
      canvas.addSubview(label)
    }
    canvas.layoutSubtreeIfNeeded()
    guard let representation = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else {
      throw DashboardRenderError.bitmapUnavailable
    }
    canvas.cacheDisplay(in: canvas.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:])
    else {
      throw DashboardRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }

  @objc private func toggleDashboard() {
    if self.popover.isShown {
      self.popover.performClose(nil)
    } else {
      self.showDashboard()
    }
  }

  /// Rebuilds the dashboard at the same screen anchor. NSPopover's resize
  /// animation expands around its own frame and visibly slides a menu-bar
  /// popover sideways, so disclosure changes height without that animation.
  private func expandDashboard() {
    guard self.dashboardController != nil else { return }
    self.dashboardIsDirty = true
    let wasShown = self.popover.isShown
    if wasShown { self.popover.animates = false }
    self.updateDashboardIfNeeded(force: true)
    guard self.popover.isShown else {
      self.popover.animates = self.animatesPopover
      return
    }
    self.popover.animates = self.animatesPopover
  }

  private func showDashboard() {
    guard let button = self.statusItem.button else { return }
    let dashboardController = self.dashboardControllerForUse()
    if let selected = self.store.expandedProvider {
      self.store.requestInsights(for: selected)
    }
    // A reopened surface has to come back in the current appearance, so this is
    // applied before the content is built rather than after it is on screen.
    self.applyAppearance()
    self.updateDashboardIfNeeded()
    // The closed state already uses the stable width. Lock that exact width so
    // opening the popover cannot grow the item leftward under the pointer.
    self.lockedStatusItemLength = self.statusItem.length
    self.updateStatusIcon()
    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    self.store.noteDashboardOpened()
    self.applyAppearance()
    self.bringDashboardToFront()
    self.startMouseMonitors()
    self.updateMinuteTimer()
    // Keyboard and VoiceOver need a key window, and the popover only becomes
    // key while the app is active.
    NSApplication.shared.activate(ignoringOtherApps: true)
    if let window = self.popover.contentViewController?.view.window {
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
      window.initialFirstResponder = dashboardController.view
      window.makeFirstResponder(dashboardController.firstKeyView())
    }
  }

  func popoverDidClose(_ notification: Notification) {
    self.settingsWindow?.level = .floating
    self.stopMouseMonitors()
    self.lockedStatusItemLength = nil
    self.updateStatusIcon()
    self.updateMinuteTimer()
    // The closed popover does not need its control tree. The next open builds
    // the current reading instead of patching a hidden one.
    self.dashboardController?.releaseRenderedTree()
    self.dashboardIsDirty = true
  }

  func popoverDidShow(_ notification: Notification) {
    // NSPopover finishes its own ordering after `show(relativeTo:)` returns.
    // Reapply the active-window ordering once that animation has completed.
    self.bringDashboardToFront()
    self.traceDashboardLayout("didShow")
  }

  /// Diagnostic only: `RESERVE_LAYOUT_TRACE=<file>` appends the popover and
  /// dashboard geometry after each dashboard update, then again once AppKit
  /// has finished the run-loop turn.
  private static let layoutTracePath = ProcessInfo.processInfo.environment["RESERVE_LAYOUT_TRACE"]

  private func traceDashboardLayout(_ event: String) {
    guard let path = Self.layoutTracePath else { return }
    let write: (String) -> Void = { [weak self] suffix in
      guard let self else { return }
      let line = "\(Date().timeIntervalSince1970) \(event)\(suffix) " + self.dashboardGeometry() + "\n"
      if let handle = FileHandle(forWritingAtPath: path) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
      } else {
        FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
      }
    }
    write("")
    DispatchQueue.main.async { write("+async") }
  }

  private func dashboardGeometry() -> String {
    func r(_ rect: NSRect) -> String {
      "(\(Int(rect.minX)),\(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))"
    }
    guard let controller = self.dashboardController, controller.isViewLoaded else {
      return "no-dashboard"
    }
    let view = controller.view
    let intended = (view as? UsageDashboardView).map { Int($0.intendedHeight) } ?? -1
    var parts = [
      "shown=\(self.popover.isShown)",
      "popoverContent=\(Int(self.popover.contentSize.width))x\(Int(self.popover.contentSize.height))",
      "preferred=\(Int(controller.preferredContentSize.width))x\(Int(controller.preferredContentSize.height))",
      "view=\(r(view.frame)) intended=\(intended)",
      "rebuilds=\(controller.fullRebuildCount) updates=\(controller.contentUpdateCount)",
    ]
    if let window = view.window {
      let content = window.contentRect(forFrameRect: window.frame)
      let expected = NSRect(
        x: content.minX - window.frame.minX, y: content.minY - window.frame.minY,
        width: content.width, height: content.height)
      parts.append("window=\(r(window.frame)) expectedContent=\(r(expected))")
      parts.append("isContentView=\(window.contentView === view)")
      parts.append("superview=\(view.superview.map { String(describing: type(of: $0)) } ?? "nil")")
      parts.append("screenVisible=\(window.screen.map { r($0.visibleFrame) } ?? "nil")")
    } else {
      parts.append("window=nil")
    }
    return parts.joined(separator: " ")
  }

  func shouldDismissDashboard(forClickedWindow window: NSWindow?) -> Bool {
    if window === self.popover.contentViewController?.view.window { return false }
    if window === self.statusItem.button?.window { return false }
    if self.isSettingsWindow(window) { return false }
    return true
  }

  private func startMouseMonitors() {
    self.stopMouseMonitors()
    let mouseEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    self.localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mouseEvents) {
      [weak self] event in
      guard let self, self.popover.isShown else { return event }
      self.bringReserveWindowToFront(forClickedWindow: event.window)
      if self.shouldDismissDashboard(forClickedWindow: event.window) {
        self.popover.performClose(nil)
      }
      return event
    }
    self.globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseEvents) {
      [weak self] _ in
      Task { @MainActor in
        guard let self, self.popover.isShown else { return }
        self.popover.performClose(nil)
      }
    }
  }

  private func bringReserveWindowToFront(forClickedWindow window: NSWindow?) {
    guard let window else { return }
    if window === self.popover.contentViewController?.view.window {
      self.settingsWindow?.level = .floating
      window.level = .popUpMenu
      window.orderFrontRegardless()
    } else if self.isSettingsWindow(window) {
      self.popover.contentViewController?.view.window?.level = .floating
      window.level = .popUpMenu
      window.makeKeyAndOrderFront(nil)
      window.orderFrontRegardless()
    }
  }

  private var settingsWindow: NSWindow? {
    NSApp.windows.first(where: { self.isSettingsWindow($0) })
  }

  private func bringDashboardToFront() {
    self.bringReserveWindowToFront(
      forClickedWindow: self.popover.contentViewController?.view.window)
  }

  func bringDashboardToFrontForTesting() {
    self.bringDashboardToFront()
  }

  func bringSettingsToFrontForTesting() {
    self.bringReserveWindowToFront(forClickedWindow: self.settingsWindow)
  }

  private func stopMouseMonitors() {
    if let localMouseMonitor {
      NSEvent.removeMonitor(localMouseMonitor)
      self.localMouseMonitor = nil
    }
    if let globalMouseMonitor {
      NSEvent.removeMonitor(globalMouseMonitor)
      self.globalMouseMonitor = nil
    }
  }

  private func updateStatusIcon(now: Date = Date()) {
    guard let button = self.statusItem.button else { return }
    let selection = self.menuBarSelection(now: now)
    let summary = selection.summary
    self.renderedStatusProvider = summary?.provider
    let remaining = summary?.primary?.remainingPercent
    let image: NSImage
    if selection.isPinned, let provider = summary?.provider {
      image = ProviderArtwork.image(for: provider)
      image.size = NSSize(width: 16, height: 16)
    } else {
      image = ReserveStatusIcon.image(remainingPercent: remaining)
    }
    button.image = image
    button.imagePosition = .imageLeading
    button.imageHugsTitle = true
    button.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)

    let remainingText = self.store.menuBarShowsRemaining
      ? remaining.map { String(format: "%.0f%%", $0) } ?? "—%"
      : nil
    let reset = summary?.primary?.resetsAt.flatMap { $0 > now ? $0 : nil }
    let resetText = self.store.menuBarShowsReset
      ? reset.map { Self.shortCountdown(to: $0, now: now) } ?? "—"
      : nil
    let title = NSMutableAttributedString()
    if remainingText != nil || resetText != nil {
      title.append(NSAttributedString(string: "  "))
    }
    if let remainingText {
      title.append(
        NSAttributedString(
          string: remainingText,
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold),
            .foregroundColor: summary?.paceState.color ?? ReserveColor.subtle,
          ]))
    }
    if let resetText {
      if remainingText != nil { title.append(NSAttributedString(string: "  ")) }
      title.append(
        NSAttributedString(
          string: resetText,
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium),
            .foregroundColor: NSColor.labelColor,
          ]))
    }
    button.attributedTitle = title
    self.statusItem.length = self.lockedStatusItemLength ?? self.stableStatusItemLength()

    let providerName = summary?.provider.displayName ?? "No enabled provider"
    let source = selection.isPinned ? "Pinned provider" : "Automatic source"
    let state = summary?.paceState.label ?? "Unknown"
    let capacity = remaining.map { "\(Int($0.rounded())) percent left" } ?? "capacity unavailable"
    let resetDescription = resetText.map { ", resets in \($0)" } ?? ""
    let description = "\(source): \(providerName), \(capacity), \(state)\(resetDescription)"
    button.toolTip = description
    button.setAccessibilityLabel(description)
  }

  private static func shortCountdown(to date: Date, now: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    let days = minutes / 1_440
    let hours = (minutes % 1_440) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(minutes)m"
  }

  /// A deterministic width for the enabled menu-bar fields. Keeping it in both
  /// the closed and open states prevents the item from growing left when the
  /// popover opens; the open-state lock also survives Settings changes.
  private func stableStatusItemLength() -> CGFloat {
    guard self.store.menuBarShowsRemaining || self.store.menuBarShowsReset else {
      return NSStatusItem.squareLength
    }
    let sample = NSMutableAttributedString(string: "  ")
    if self.store.menuBarShowsRemaining {
      sample.append(
        NSAttributedString(
          string: "100%",
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
          ]))
    }
    if self.store.menuBarShowsReset {
      if self.store.menuBarShowsRemaining { sample.append(NSAttributedString(string: "  ")) }
      sample.append(
        NSAttributedString(
          string: "32d 23h",
          attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
          ]))
    }
    return max(NSStatusItem.squareLength, ceil(sample.size().width) + 28)
  }

  /// The menu-bar model, computed once per update rather than rebuilt by each
  /// caller that happens to need it.
  private var cachedSelection: (at: Date, selection: (summary: ProviderSummary?, isPinned: Bool))?

  private func menuBarSelection(now: Date) -> (summary: ProviderSummary?, isPinned: Bool) {
    if let cachedSelection, cachedSelection.at == now { return cachedSelection.selection }
    let summaries = self.store.orderedStates
      .filter { self.store.isEnabled($0.provider) }
      .map { AllowanceBuilder.summary(for: $0, now: now) }
    let selection = AllowanceBuilder.menuBarSummary(
      from: summaries, pinnedProvider: self.store.menuBarProvider)
    self.cachedSelection = (now, selection)
    return selection
  }

  private func needsMinuteUpdates(now: Date) -> Bool {
    if self.popover.isShown { return true }
    guard self.store.menuBarShowsReset else { return false }
    return self.menuBarSelection(now: now).summary?.primary?.resetsAt.map { $0 > now } == true
  }

  private func updateMinuteTimer(now: Date = Date()) {
    guard self.needsMinuteUpdates(now: now) else {
      self.minuteTimer?.invalidate()
      self.minuteTimer = nil
      return
    }
    guard self.minuteTimer == nil else { return }
    let now = Date()
    let nextMinute = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 60) * 60 + 60)
    let timer = Timer(fireAt: nextMinute, interval: 60, target: self,
                      selector: #selector(self.minuteTick), userInfo: nil, repeats: true)
    timer.tolerance = 3
    RunLoop.main.add(timer, forMode: .common)
    self.minuteTimer = timer
  }

  @objc private func minuteTick() {
    let now = Date()
    self.updateStatusIcon(now: now)
    if self.popover.isShown { self.updateDashboardIfNeeded(force: true) }
    self.updateMinuteTimer(now: now)
  }

  var dashboardFullRebuildsForTesting: Int {
    self.dashboardController?.fullRebuildCount ?? 0
  }

  var dashboardContentUpdatesForTesting: Int {
    self.dashboardController?.contentUpdateCount ?? 0
  }

  var dashboardRegionRebuildsForTesting: Int {
    self.dashboardController?.regionRebuildCount ?? 0
  }

  private func updateDashboardIfNeeded(force: Bool = false) {
    let minute = Int(Date().timeIntervalSince1970 / 60)
    guard force || self.dashboardIsDirty || self.lastDashboardMinute != minute else { return }
    let controller = self.dashboardControllerForUse()
    let before = controller.isViewLoaded ? controller.preferredContentSize : .zero
    if controller.isViewLoaded {
      controller.update()
    } else {
      controller.loadViewIfNeeded()
    }
    let after = controller.preferredContentSize
    // Compare with the popover itself, not the previous preference: a popover
    // left at a stale size must still be brought back to the dashboard's.
    if self.popover.isShown, self.popover.contentSize != after {
      let animates = self.popover.animates
      self.popover.animates = false
      self.popover.contentSize = after
      self.popover.animates = animates
    }
    self.dashboardIsDirty = false
    self.lastDashboardMinute = minute
    self.traceDashboardLayout("update(\(Int(before.height))->\(Int(after.height)))")
  }

  private func showSettings() {
    self.openSettings()
    self.bringReserveWindowToFront(forClickedWindow: self.settingsWindow)
  }

  /// Insights lives in the Settings window. Opened from the dashboard it must
  /// come in front of the popover exactly as Settings does, or it lands behind.
  private func apiConsumptionReadings() -> [APIConsumptionReading] {
    APIConsumptionProvider.allCases.compactMap { provider in
      // An unavailable Keychain does not hide the last known reading.
      guard self.store.isAPIConsumptionEnabled(provider) else { return nil }
      return APIConsumptionReading(
        provider: provider,
        snapshot: self.store.apiConsumption[provider],
        error: self.store.apiConsumptionErrors[provider],
        isRefreshing: self.store.apiConsumptionRefreshing.contains(provider),
        isExpanded: self.store.expandedAPIProvider == provider,
        hidesPersonalInfo: self.store.hidesPersonalInfo)
    }
  }

  private func showInsights() {
    self.openInsights()
    self.bringReserveWindowToFront(forClickedWindow: self.settingsWindow)
  }

  private var sharePreview: UsageSharePreviewController?

  /// Opens the sanitized card for the selected provider. The model never
  /// includes account, organization, email, path, or raw error text.
  private func shareSelectedUsage() {
    let provider = self.store.expandedProvider ?? ProviderID.allCases.first { self.store.isEnabled($0) }
    guard let provider, let state = self.store.states[provider] else { return }
    let usage = state.snapshot?.accountUsage ?? state.localUsage
    let model = UsageShareCardBuilder.model(
      provider: provider,
      planName: state.snapshot?.planName,
      windows: state.snapshot?.windows ?? [],
      tokensUsed: usage?.totalTokens,
      tokenPeriodDays: usage?.periodDays,
      tokensCheckedAt: usage?.fetchedAt,
      estimatedAPIEquivalentUSD: usage?.apiEquivalentCostUSD,
      generatedAt: Date(),
      hidingPersonal: true,
      quotaCheckedAt: state.snapshot?.fetchedAt)
    let preview = UsageSharePreviewController(model: model)
    self.sharePreview = preview
    preview.show()
  }

  private func connectProvider(_ provider: ProviderID) {
    self.popover.performClose(nil)
    DispatchQueue.main.async { [weak self] in self?.setupProvider(provider) }
  }

  private func dashboardControllerForUse() -> DashboardViewController {
    if let dashboardController { return dashboardController }
    let controller = DashboardViewController(
      store: self.store,
      maximumHeight: { [weak self] in
        DashboardMetrics.availableHeight(on: self?.dashboardScreen())
      },
      actions: DashboardActions(
        refreshAll: { [weak self] in self?.store.refreshAll() },
        connectProvider: { [weak self] provider in self?.connectProvider(provider) },
        selectMenuBarProvider: { [weak self] provider in
          self?.store.selectMenuBarProvider(provider)
        },
        openSettings: { [weak self] in self?.showSettings() },
        openInsights: { [weak self] in self?.showInsights() },
        dismiss: { [weak self] in self?.popover.performClose(nil) },
        toggleProviderDetail: { [weak self] provider in
          guard let self else { return }
          // The overview is navigation, not an accordion: one provider always
          // owns the detail panel and clicking it again keeps the page stable.
          guard self.store.expandedProvider != provider else { return }
          self.store.expandedProvider = provider
          self.store.requestInsights(for: provider)
          self.expandDashboard()
        },
        quit: { NSApplication.shared.terminate(nil) },
        apiConsumptionReadings: { [weak self] in self?.apiConsumptionReadings() ?? [] },
        toggleAPIDetail: { [weak self] provider in
          guard let self else { return }
          self.store.expandedAPIProvider =
            self.store.expandedAPIProvider == provider ? nil : provider
          self.expandDashboard()
        },
        shareUsage: { [weak self] in self?.shareSelectedUsage() },
        toggleHidePersonalInfo: { [weak self] in
          guard let self else { return }
          self.store.hidesPersonalInfo.toggle()
          self.expandDashboard()
        },
        hidesPersonalInfo: { [weak self] in self?.store.hidesPersonalInfo ?? false }))
    self.dashboardController = controller
    self.popover.contentViewController = controller
    return controller
  }

  private func dashboardScreen() -> NSScreen? {
    if let dashboardController, dashboardController.isViewLoaded,
      let screen = dashboardController.view.window?.screen
    {
      return screen
    }
    // The first layout runs before the popover has a window. Its menu-bar
    // anchor already knows the display, which need not be NSScreen.main.
    return self.statusItem.button?.window?.screen ?? NSScreen.main
  }

  /// The last detail destination survives a new store, falls back while that
  /// provider is disabled, and returns when it is enabled again.
  private static func dashboardSelectionPersistenceWorks() -> Bool {
    let domain = "Reserve.DashboardSelection.SelfTest"
    guard let defaults = UserDefaults(suiteName: domain) else { return false }
    defaults.removePersistentDomain(forName: domain)
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set(true, forKey: "provider.openAI.enabled")
    defaults.set(true, forKey: "provider.cursor.enabled")
    let planKeys = PlanKeyStorage(
      hasKey: { _ in false }, save: { _, _ in }, delete: { _ in })
    let first = UsageStore(
      defaults: defaults, startAutomatically: false, notificationsActive: false,
      planKeys: planKeys)
    first.expandedProvider = .cursor
    let restored = UsageStore(
      defaults: defaults, startAutomatically: false, notificationsActive: false,
      planKeys: planKeys)
    guard restored.expandedProvider == .cursor else { return false }
    defaults.set(false, forKey: "provider.cursor.enabled")
    guard restored.expandedProvider == .openAI else { return false }
    defaults.set(true, forKey: "provider.cursor.enabled")
    return restored.expandedProvider == .cursor
  }

  /// Hiding personal info changes the visible value and leaves the snapshot
  /// original in place. Turning it off shows the original again.
  private func privacyToggleRestoresOriginals() -> Bool {
    let original = self.store.hidesPersonalInfo
    let provider = self.store.expandedProvider ?? .openAI
    let snapshot = UsageSnapshot(
      provider: provider, planName: "Plus",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10, resetsAt: nil)],
      source: "privacy check",
      details: [UsageDetail("Account", "ada@example.com", isPersonal: true)])
    let saved = self.store.replaceSnapshotForSelfTest(provider, snapshot: snapshot)
    defer {
      _ = self.store.replaceSnapshotForSelfTest(provider, snapshot: saved)
      self.store.hidesPersonalInfo = original
    }
    self.store.hidesPersonalInfo = true
    let hidden = self.store.orderedStates.first { $0.provider == provider }?.snapshot?.details.first?.value
    let presented = AllowanceBuilder.summary(
      for: self.store.orderedStates.first { $0.provider == provider }!).details.first?.value
    self.store.hidesPersonalInfo = false
    let restored = AllowanceBuilder.summary(
      for: self.store.orderedStates.first { $0.provider == provider }!).details.first?.value
    return hidden == "ada@example.com" && presented == "Hidden" && restored == "ada@example.com"
  }

  /// The hot key handler uses the same open path as the status item, and does
  /// not close a dashboard that is already visible.
  private func hotKeyOpensExistingDashboard() -> Bool {
    let selected = self.store.expandedProvider
    let wasShown = self.isDashboardShownForTesting
    let buttonReady = self.waitUntilStatusButtonHasWindow()
    guard buttonReady else { return false }
    self.openDashboardFromHotKey()
    let opened = self.waitUntilDashboardShownForTesting()
    let keptSelection = self.store.expandedProvider == selected
    let stayedOpen = self.isDashboardShownForTesting
    if opened {
      self.openDashboardFromHotKey()
      let stillOpen = self.waitUntilDashboardShownForTesting()
      if !wasShown {
        self.popover.performClose(nil)
      }
      return stillOpen && keptSelection && stayedOpen
    }
    return false
  }

  /// AppKit may show the popover on the next turn. A synchronous read of
  /// `isShown` right after `show()` is not a truthful open check.
  private func waitUntilDashboardShownForTesting() -> Bool {
    if self.isDashboardShownForTesting { return true }
    let until = Date().addingTimeInterval(1.5)
    while Date() < until {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      if self.isDashboardShownForTesting { return true }
    }
    return self.isDashboardShownForTesting
  }

  /// The status item has no window until AppKit has turned the run loop.
  /// Showing a popover before that returns without opening anything.
  private func waitUntilStatusButtonHasWindow() -> Bool {
    if self.statusItem.button?.window != nil { return true }
    let until = Date().addingTimeInterval(2)
    while Date() < until {
      RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
      if self.statusItem.button?.window != nil { return true }
    }
    return self.statusItem.button?.window != nil
  }

  /// The share model drops freeform plan and window text. Rendering the card
  /// does not touch the system pasteboard or a save panel.
  private static func shareCardOmitsPersonalText() -> Bool {
    let poison = "ada@example.com Acme /Users/ada/secret.jsonl"
    let model = UsageShareCardBuilder.model(
      provider: .anthropic,
      planName: poison,
      windows: [UsageWindow(id: poison, label: poison, usedPercent: 10, resetsAt: nil)],
      tokensUsed: 10,
      tokenPeriodDays: 30,
      tokensCheckedAt: nil,
      estimatedAPIEquivalentUSD: 1,
      generatedAt: Date(),
      hidingPersonal: false)
    let text = model.plainText()
    guard !text.contains("ada@"), !text.contains("/Users"), !text.contains("Acme") else { return false }
    let card = UsageShareCardView(model: model)
    card.layoutSubtreeIfNeeded()
    let height = card.bounds.height
    let worst = Self.worstCaseShareModel()
    let worstHeight = UsageShareCardView.measuredHeight(for: worst)
    let worstCard = UsageShareCardView(model: worst)
    let disclaimerFits = worstCard.bounds.height + 1 >= worstHeight
      && worst.plainText().contains("Not an actual charge")
      && worst.plainText().contains("Quota as of")
    let board = NSPasteboard(name: NSPasteboard.Name("Reserve.ShareCard.SelfTest"))
    board.clearContents()
    let preview = UsageSharePreviewController(model: worst, pasteboard: board)
    let copied = preview.copyForTesting()
    let copiedText = board.string(forType: .string) ?? ""
    let decoded: Bool
    if let data = try? preview.pngDataForTesting(),
      let rep = NSBitmapImageRep(data: data)
    {
      decoded = rep.pixelsHigh >= Int(worstHeight) && rep.pixelsWide > 100
    } else {
      decoded = false
    }
    let windowFits = (preview.window?.contentRect(forFrameRect: preview.window?.frame ?? .zero).height ?? 0)
      >= worstHeight + 40
    return card.accessibilityLabel()?.contains("Estimated API equivalent") == true
      && !((card.accessibilityLabel() ?? "").contains("ada@"))
      && height > 40
      && disclaimerFits
      && copied
      && copiedText.contains("Not an actual charge")
      && !copiedText.contains("ada@")
      && decoded
      && windowFits
  }

  /// Six windows, the largest token count, and long reset dates. Used to prove
  /// the PNG height follows the text instead of a fixed 220pt crop.
  static func worstCaseShareModel() -> UsageShareModel {
    let resets = Date(timeIntervalSince1970: 1_900_000_000)
    let windows = (0..<6).map { index in
      UsageWindow(
        id: "weekly-\(index)", label: index == 0 ? "Weekly" : "5 hours",
        usedPercent: Double(index * 10), windowMinutes: 10_080, resetsAt: resets)
    }
    return UsageShareCardBuilder.model(
      provider: .anthropic,
      planName: "Max 20x",
      windows: windows,
      tokensUsed: Int64.max,
      tokenPeriodDays: 90,
      tokensCheckedAt: resets,
      estimatedAPIEquivalentUSD: 999_999.99,
      generatedAt: resets,
      hidingPersonal: true,
      quotaCheckedAt: resets)
  }

  /// Selecting a provider tile must ask the store for that provider's detail
  /// data once. Selecting the current tile again keeps the panel stable and
  /// does not start redundant work.
  private func expandingAProviderRequestsItsDetails() -> Bool {
    #if RESERVE_DEV_AUTOMATION
    let original = self.store.expandedProvider
    defer {
      self.store.expandedProvider = original
      self.dashboardControllerForUse().update()
    }
    let provider: ProviderID = original == .openAI ? .cursor : .openAI
    let other: ProviderID = provider == .cursor ? .openAI : .cursor
    let before = self.store.insightsRequestCount(for: provider)
    let otherBefore = self.store.insightsRequestCount(for: other)
    self.toggleProviderDetailForTesting(provider)
    let expandedProvider = self.store.expandedProvider
    let afterExpand = self.store.insightsRequestCount(for: provider)
    self.toggleProviderDetailForTesting(provider)
    return expandedProvider == provider
      && self.store.expandedProvider == provider
      && afterExpand == before + 1
      // Re-selecting the current tile asks for nothing.
      && self.store.insightsRequestCount(for: provider) == afterExpand
      && self.store.insightsRequestCount(for: other) == otherBefore
      // Activity from this Mac is not scanned during an automated run.
      && !self.store.isScanningLocalUsage
      // Only providers whose adapter reports account history are asked for it.
      && ProviderDescriptor.forProvider(.openAI).capabilities.contains(.accountHistory)
      && ProviderDescriptor.forProvider(.cursor).capabilities.contains(.accountHistory)
      && !ProviderDescriptor.forProvider(.anthropic).capabilities.contains(.accountHistory)
      && !ProviderDescriptor.forProvider(.grok).capabilities.contains(.accountHistory)
      && !ProviderDescriptor.forProvider(.copilot).capabilities.contains(.accountHistory)
    #else
    return true
    #endif
  }

  /// An expanded card with no activity yet says what it is waiting for, and a
  /// provider that can never have activity says nothing at all.
  /// An API row opens onto everything its key reported, shows the whole error
  /// when the key was refused, and stays closed otherwise.
  private static func apiDetailChecks() -> Bool {
    let now = Date()
    let openRouter = APIConsumptionSnapshot(
      provider: .openRouter,
      windows: [APIConsumptionWindow(id: "month", label: "This month", usedMinorUnits: 59)],
      fetchedAt: now, source: "self-test",
      details: [
        UsageDetail("Key", "laptop"), UsageDetail("All time", "$40.50"),
        UsageDetail("Credit limit", "$20.00 · resets monthly"),
      ])
    let typeSafe = APIConsumptionSnapshot(
      provider: .typeSafe, windows: [],
      note: APIConsumptionNote(headline: "2 models", detail: "jev-latest, jev-preview"),
      fetchedAt: now, source: "self-test",
      details: [UsageDetail("jev-latest", "Flagship System One model")])
    // Balance providers report what is left, so they arrive as a note.
    let deepSeek = APIConsumptionSnapshot(
      provider: .deepSeek, windows: [],
      note: APIConsumptionNote(headline: "¥110.00", detail: "¥10.00 granted · ¥100 topped up"),
      fetchedAt: now, source: "self-test",
      details: [
        UsageDetail("Balance", "¥110.00"), UsageDetail("Granted", "¥10.00"),
        UsageDetail("Topped up", "¥100"),
      ])
    let moonshot = APIConsumptionSnapshot(
      provider: .moonshot, windows: [],
      note: APIConsumptionNote(headline: "$49.59", detail: "$46.59 voucher · $3.00 cash"),
      fetchedAt: now, source: "self-test",
      details: [UsageDetail("Balance", "$49.59")])
    let readings = [
      APIConsumptionReading(
        provider: .openRouter, snapshot: openRouter, error: nil, isRefreshing: false,
        isExpanded: true),
      APIConsumptionReading(
        provider: .xAI, snapshot: nil,
        error: "xAI refused this management key. Check that it has billing read access.",
        isRefreshing: false, isExpanded: true),
      APIConsumptionReading(
        provider: .typeSafe, snapshot: typeSafe, error: nil, isRefreshing: false),
      APIConsumptionReading(
        provider: .deepSeek, snapshot: deepSeek, error: nil, isRefreshing: false,
        isExpanded: true),
      APIConsumptionReading(
        provider: .moonshot, snapshot: moonshot, error: nil, isRefreshing: false),
    ]
    let view = UsageDashboardView(
      states: [], selectedMenuBarProvider: nil, isRefreshing: false, now: now,
      actions: DashboardActions(
        refreshAll: {}, connectProvider: { _ in }, selectMenuBarProvider: { _ in },
        openSettings: {}, openInsights: {}, dismiss: {}, toggleProviderDetail: { _ in },
        quit: {}, apiConsumptionReadings: { readings }))
    view.layoutSubtreeIfNeeded()
    let identifiers = Self.descendants(of: view).compactMap { $0.identifier?.rawValue }
    return identifiers.filter { $0 == "api-detail-openRouter" }.count == 3
      && identifiers.filter { $0 == "api-detail-xAI" }.count == 1
      && !identifiers.contains("api-detail-typeSafe")
      && identifiers.filter { $0 == "api-detail-deepSeek" }.count == 3
      && !identifiers.contains("api-detail-moonshot")
      && ["openRouter", "xAI", "typeSafe", "deepSeek", "moonshot"].allSatisfy {
        identifiers.contains("disclose-api-\($0)")
      }
  }

  private static func historyPlaceholderChecks() -> Bool {
    let now = Date()
    func state(_ provider: ProviderID, localHistoryEnabled: Bool) -> ProviderViewState {
      var value = ProviderViewState(provider: provider)
      value.snapshot = UsageSnapshot(
        provider: provider,
        windows: [
          UsageWindow(
            id: "weekly", label: "Weekly", usedPercent: 30, windowMinutes: 10_080,
            resetsAt: now.addingTimeInterval(3 * 86_400))
        ],
        fetchedAt: now, source: "history fixture")
      value.localHistoryEnabled = localHistoryEnabled
      return value
    }
    func labels(_ state: ProviderViewState) -> (texts: [String], identifiers: Set<String>) {
      let card = ProviderDashboardCard(
        summary: AllowanceBuilder.summary(for: state, now: now), now: now,
        isSelectedForMenuBar: false, isExpanded: true, connectProvider: { _ in },
        selectMenuBarProvider: { _ in })
      card.layoutSubtreeIfNeeded()
      let views = Self.descendants(of: card)
      return (
        views.compactMap { ($0 as? NSTextField)?.stringValue },
        Set(views.compactMap { $0.identifier?.rawValue }))
    }
    let waiting = labels(state(.openAI, localHistoryEnabled: true))
    let off = labels(state(.openAI, localHistoryEnabled: false))
    let account = labels(state(.cursor, localHistoryEnabled: false))
    let never = labels(state(.copilot, localHistoryEnabled: true))
    return waiting.identifiers.contains("usage-history-note-openAI")
      && waiting.texts.contains("Gathering activity from this Mac…")
      && off.texts.contains("Activity from this Mac is off · turn it on in Settings")
      // Cursor's history is its account's, so the local switch does not describe it.
      && account.texts.contains("Gathering account activity…")
      // Copilot reports neither local nor account history.
      && !never.identifiers.contains { $0.hasPrefix("usage-history-note-") }
      // Freshness travels with every expanded card.
      && waiting.identifiers.contains("usage-checked-openAI")
      // The transport name is not shown on the card.
      && !waiting.texts.contains("history fixture")
  }

  private static func dashboardClockAndDisclosureChecks() -> Bool {
    let now = Date()
    let later = now.addingTimeInterval(120)
    let weekly = UsageWindow(id: "weekly", label: "Weekly", usedPercent: 40,
      windowMinutes: 10_080, resetsAt: now.addingTimeInterval(4 * 86_400))
    let daily = UsageWindow(id: "daily", label: "Daily", usedPercent: 20,
      windowMinutes: 1_440, resetsAt: now.addingTimeInterval(12 * 3_600 + 60))
    func summary(fetchedAt: Date) -> ProviderSummary {
      AllowanceBuilder.summary(for: ProviderViewState(provider: .openAI,
        snapshot: UsageSnapshot(provider: .openAI, windows: [weekly, daily],
          fetchedAt: fetchedAt, source: "UI clock fixture")), now: now)
    }
    func card(_ summary: ProviderSummary, expanded: Bool = false) -> ProviderDashboardCard {
      ProviderDashboardCard(summary: summary, now: now, isSelectedForMenuBar: false,
        isExpanded: expanded, connectProvider: { _ in }, selectMenuBarProvider: { _ in })
    }
    func tick(_ view: NSView, _ date: Date) {
      for clock in ([view] + Self.descendants(of: view)).compactMap({ $0 as? any ReserveClockUpdating }) {
        clock.updateClock(date)
      }
    }
    let stale = card(summary(fetchedAt: now.addingTimeInterval(-31 * 60)))
    let staleViews = Self.descendants(of: stale)
    guard let age = staleViews.compactMap({ $0 as? ReserveLabel }).first(where: {
      $0.identifier?.rawValue == "freshness-label-openAI"
    }), let staleMeter = staleViews.compactMap({ $0 as? ReserveMeter }).first else { return false }
    let beforeAge = age.stringValue
    let beforeSpoken = stale.accessibilityValue() as? String
    guard staleViews.compactMap({ $0 as? NSTextField }).contains(where: {
      $0.stringValue == "60%" && ($0.accessibilityLabel() ?? "").contains("percent last known")
    }) else { return false }
    tick(stale, later)
    guard age.stringValue != beforeAge, age.stringValue.contains("33m"),
      stale.accessibilityValue() as? String != beforeSpoken,
      (stale.accessibilityValue() as? String ?? "").contains("33 min ago"),
      (staleMeter.accessibilityValue() as? String ?? "").contains("percent last known"),
      staleMeter.paceRemainingPercentForTesting == nil else { return false }

    // The expanded detail's "Last checked" line follows the same minute clock.
    let detail = card(summary(fetchedAt: now.addingTimeInterval(-5 * 60)), expanded: true)
    let detailViews = Self.descendants(of: detail)
    guard let checkedRow = detailViews.first(where: {
      $0.identifier?.rawValue == "usage-checked-openAI"
    }),
      let checkedLabel = Self.descendants(of: checkedRow).compactMap({ $0 as? ReserveLabel })
        .first(where: { $0.clockText != nil }),
      checkedLabel.stringValue == "5 min ago"
    else { return false }
    tick(detail, later)
    let detailFreshnessFollowsClock = checkedLabel.stringValue == "7 min ago"
      && detailViews.contains { $0.identifier?.rawValue == "usage-checked-openAI" }

    let fresh = card(summary(fetchedAt: now))
    let freshViews = Self.descendants(of: fresh)
    guard let meter = freshViews.compactMap({ $0 as? ReserveMeter }).first,
      let beforeMarker = meter.paceRemainingPercentForTesting,
      let secondary = freshViews.first(where: { $0.identifier?.rawValue == "secondary-daily" }),
      let reset = Self.descendants(of: secondary).compactMap({ $0 as? ReserveLabel }).first(where: {
        $0.stringValue.hasPrefix("resets ")
      }) else { return false }
    let beforeReset = reset.stringValue
    tick(fresh, later)
    guard let afterMarker = meter.paceRemainingPercentForTesting,
      afterMarker < beforeMarker, reset.stringValue != beforeReset,
      // The daily window crossed the twelve-hour line, so its reset is now a
      // countdown rather than a clock time.
      reset.stringValue.hasPrefix("resets in ") else { return false }
    tick(fresh, now.addingTimeInterval(31 * 60))
    guard meter.paceRemainingPercentForTesting == nil,
      (meter.accessibilityValue() as? String ?? "").contains("last known") else { return false }

    var typical = summary(fetchedAt: now)
    typical.subscriptionCostLabel = "Typical monthly cost"
    var manual = typical
    manual.subscriptionCostLabel = "Your monthly cost"
    func signature(_ value: ProviderSummary) -> String {
      DashboardViewController.signature(summaries: [value], selectedMenuBarProvider: nil,
        expandedProvider: .openAI, isRefreshing: false, now: now)
    }
    guard signature(typical) != signature(manual) else { return false }
    manual = typical
    manual.observationTimeKnown = false
    guard signature(typical) != signature(manual) else { return false }

    let grok = AllowanceBuilder.summary(for: ProviderViewState(provider: .grok,
      snapshot: UsageSnapshot(provider: .grok, windows: [
        UsageWindow(id: "pool", label: "Weekly", usedPercent: 20),
        UsageWindow(id: "build-share", label: "Grok Build share", usedPercent: 90),
      ], source: "UI share fixture")), now: now)
    let collapsed = Self.descendants(of: card(grok))
    let expanded = Self.descendants(of: card(grok, expanded: true))
    let expandedLabels = expanded.compactMap { ($0 as? NSTextField)?.stringValue }
    func forecastLabels(_ view: NSView) -> [String] {
      Self.descendants(of: view).compactMap { node in
        guard node.identifier?.rawValue == "forecast" else { return nil }
        return (node as? NSTextField)?.stringValue
      }
    }
    // A snapshot whose observation time the provider did not report must not
    // be given a forecast, whichever provider supplied it.
    let savedSummary = AllowanceBuilder.summary(for: ProviderViewState(provider: .cursor,
      snapshot: UsageSnapshot(provider: .cursor, windows: [weekly], fetchedAt: now,
        source: "UI saved fixture", observationTimeKnown: false)), now: now)
    let saved = card(savedSummary)
    let noPeriodSummary = AllowanceBuilder.summary(for: ProviderViewState(provider: .copilot,
      snapshot: UsageSnapshot(provider: .copilot, windows: [
        UsageWindow(id: "premium", label: "Premium requests", usedPercent: 40,
          resetsAt: now.addingTimeInterval(20 * 86_400))], source: "UI quota fixture")), now: now)
    let exhaustedSummary = AllowanceBuilder.summary(for: ProviderViewState(provider: .copilot,
      snapshot: UsageSnapshot(provider: .copilot, windows: [
        UsageWindow(id: "premium", label: "Premium requests", usedPercent: 100,
          resetsAt: now.addingTimeInterval(20 * 86_400))], source: "UI exhausted fixture")), now: now)
    let earlySummary = AllowanceBuilder.summary(for: ProviderViewState(provider: .openAI,
      snapshot: UsageSnapshot(provider: .openAI, windows: [
        UsageWindow(id: "session", label: "5 hours", usedPercent: 5, windowMinutes: 300,
          resetsAt: now.addingTimeInterval(295 * 60))], source: "UI early fixture")), now: now)
    // A reset within half a day reads as a countdown; beyond it, as a weekday or
    // a date.
    let soon = Allowance(id: "soon", title: "Weekly limit", usedPercent: 50,
      resetsAt: now.addingTimeInterval(80 * 60), projection: nil, isPrimary: true,
      paceState: .onPace)
    let far = Allowance(id: "far", title: "Weekly limit", usedPercent: 50,
      resetsAt: now.addingTimeInterval(2 * 86_400), projection: nil, isPrimary: true,
      paceState: .onPace)
    let relativeResetsRead =
      DashboardFormat.limitLine(soon, now: now) == "Weekly limit · resets in 1h 20m"
      && DashboardFormat.resetLine(soon, now: now) == "Resets in 1h 20m"
      && DashboardFormat.secondaryDetail(soon, now: now) == "resets in 1h 20m"
      && !DashboardFormat.limitLine(far, now: now).contains("resets in ")
      && DashboardFormat.limitLine(far, now: now).hasPrefix("Weekly limit · resets ")
    // The pace marker is the one element whose meaning is not written beside it.
    let markedMeter = ReserveMeter(remainingPercent: 40, paceRemainingPercent: 58,
      label: "Weekly limit", color: ReserveColor.onPace)
    let unmarkedMeter = ReserveMeter(remainingPercent: 40, paceRemainingPercent: nil,
      label: "Weekly limit", color: ReserveColor.onPace)
    let markerIsExplained =
      markedMeter.toolTip
        == "Marker: capacity that should remain now at an even pace (58%)"
      && (markedMeter.accessibilityValue() as? String ?? "").contains("40 percent left")
      && (markedMeter.accessibilityValue() as? String ?? "").contains("even pace (58%)")
      && unmarkedMeter.toolTip == nil
      && unmarkedMeter.accessibilityValue() as? String == "40 percent left"
    return relativeResetsRead && markerIsExplained && detailFreshnessFollowsClock
      && Self.headlineChoiceChecks()
      && !collapsed.contains { $0.identifier?.rawValue == "secondary-build-share" }
      && expanded.contains { $0.identifier?.rawValue == "secondary-build-share" }
      && expandedLabels.contains("90% of pool used")
      && !expandedLabels.contains("10% left")
      && forecastLabels(saved).isEmpty
      && forecastLabels(card(noPeriodSummary)).isEmpty
      && forecastLabels(card(exhaustedSummary)).contains { $0.hasPrefix("Limit exhausted · resets") }
      && forecastLabels(card(earlySummary)) == ["Too early to forecast"]
      // The freshness banner, the tinted surface and the "last known" label are
      // the staleness signals; the forecast line is not a fourth one.
      && forecastLabels(stale).isEmpty
      && ProviderSetupAction.install.toolTip(for: .copilot) == "Open official installation instructions for Copilot"
      && ProviderSetupAction.update.toolTip(for: .copilot) == "Open official update instructions for Copilot"
  }

  /// The headline chooser, checked against the two cases that used to mislead:
  /// the loudest deficit outranking the soonest run-out, and a plan without a
  /// forecast outranking plans that are fine.
  private static func headlineChoiceChecks() -> Bool {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    func plan(
      _ provider: ProviderID, usedPercent: Double, resetsInDays: Double,
      windowMinutes: Int? = 10_080
    ) -> ProviderSummary {
      AllowanceBuilder.summary(
        for: ProviderViewState(
          provider: provider,
          snapshot: UsageSnapshot(
            provider: provider,
            windows: [
              UsageWindow(
                id: "weekly", label: "Weekly", usedPercent: usedPercent,
                windowMinutes: windowMinutes,
                resetsAt: now.addingTimeInterval(resetsInDays * 86_400))
            ],
            fetchedAt: now, source: "headline fixture")),
        now: now)
    }
    // Grok is 23 points behind pace and runs out tomorrow. OpenAI is 31 points
    // behind and runs out later, so the larger gap must not take the headline.
    let soonest = plan(.grok, usedPercent: 80, resetsInDays: 3)
    let loudest = plan(.openAI, usedPercent: 60, resetsInDays: 5)
    guard let soonestRunsOut = soonest.primary?.runsOutAt,
      let loudestRunsOut = loudest.primary?.runsOutAt,
      soonestRunsOut < loudestRunsOut,
      let soonestGap = soonest.paceState.deficitPercent,
      let loudestGap = loudest.paceState.deficitPercent,
      soonestGap < loudestGap
    else { return false }
    let reserve = plan(.anthropic, usedPercent: 20, resetsInDays: 2)
    let onPace = plan(.cursor, usedPercent: 57, resetsInDays: 3)
    let unknown = plan(.copilot, usedPercent: 40, resetsInDays: 6, windowMinutes: nil)
    guard reserve.paceState.reservePercent != nil, onPace.paceState == .onPace,
      unknown.paceState == .unknown
    else { return false }
    let twoDeficits = AllowanceBuilder.headline(for: [loudest, soonest], now: now)
    let oneDeficit = AllowanceBuilder.headline(for: [soonest], now: now)
    let unknownBesideHealthy = AllowanceBuilder.headline(for: [unknown, reserve], now: now)
    let mixedHealthy = AllowanceBuilder.headline(for: [reserve, onPace], now: now)
    let onlyUnknown = AllowanceBuilder.headline(for: [unknown], now: now)
    return twoDeficits.primary == "Grok may run out 2d 0h before reset · 1 more at risk"
      && twoDeficits.state == soonest.paceState
      && oneDeficit.primary == "Grok may run out 2d 0h before reset"
      // Provider names keep their own capitalisation in the reset phrase.
      && unknownBesideHealthy.primary == "No plan at risk · Claude resets in 2d 0h"
      && unknownBesideHealthy.state == .reserve(percent: 0)
      && mixedHealthy.primary == "All plans on track · Claude resets in 2d 0h"
      && mixedHealthy.state == .onPace
      && onlyUnknown.primary == "No pace forecast yet · Copilot resets in 6d 0h"
      && onlyUnknown.state == .unknown
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { self.descendants(of: $0) }
  }
}

private enum DashboardRenderError: Error {
  case statusButtonUnavailable
  case bitmapUnavailable
  case pngUnavailable
}

@MainActor
private enum ReserveStatusIcon {
  static let size = NSSize(width: 18, height: 18)

  /// The gauge is redrawn only when the number it shows changes. It used to be
  /// re-rendered — arcs, needle and hub — on every store change and every
  /// minute tick, almost always producing an identical image.
  private static var cache: [Int: NSImage] = [:]

  static func image(remainingPercent: Double?) -> NSImage {
    let key = remainingPercent.map { Int($0.rounded()) } ?? -1
    if let cached = Self.cache[key] { return cached }
    let image = Self.render(remainingPercent: remainingPercent)
    // 0...100 plus the unknown state; small and bounded.
    Self.cache[key] = image
    return image
  }

  private static func render(remainingPercent: Double?) -> NSImage {
    let image = NSImage(size: self.size, flipped: false) { rect in
      NSColor.black.setStroke()
      NSColor.black.setFill()

      let center = NSPoint(x: rect.midX, y: 5.7)
      let radius: CGFloat = 6.7
      let segmentAngles: [(CGFloat, CGFloat)] = [
        (18, 40), (50, 72), (82, 104), (114, 136), (146, 168),
      ]
      for (start, end) in segmentAngles {
        let segment = NSBezierPath()
        segment.lineWidth = 2.15
        segment.lineCapStyle = .round
        segment.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end)
        segment.stroke()
      }

      let remaining = max(0, min(100, remainingPercent ?? 50))
      let angle = (168 - 150 * CGFloat(remaining / 100)) * .pi / 180
      let needleStart = NSPoint(
        x: center.x + cos(angle) * 1.25,
        y: center.y + sin(angle) * 1.25)
      let needleEnd = NSPoint(
        x: center.x + cos(angle) * 5.35,
        y: center.y + sin(angle) * 5.35)
      let needle = NSBezierPath()
      needle.lineWidth = 1.85
      needle.lineCapStyle = .round
      needle.move(to: needleStart)
      needle.line(to: needleEnd)
      needle.stroke()

      NSBezierPath(ovalIn: NSRect(x: center.x - 1.15, y: center.y - 1.15, width: 2.3, height: 2.3))
        .fill()
      return true
    }
    image.isTemplate = true
    image.accessibilityDescription =
      remainingPercent.map {
        "Reserve, \(Int($0.rounded())) percent remaining"
      } ?? "Reserve, waiting for usage"
    return image
  }
}
