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
      guard let self else { return }
      let now = Date()
      self.dashboardIsDirty = true
      self.applyAppearance()
      self.updateStatusIcon(now: now)
      if self.popover.isShown {
        self.updateDashboardIfNeeded(force: true)
      }
      self.updateMinuteTimer(now: now)
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

  func closeMenuForStressTest() {
    self.popover.performClose(nil)
  }

  /// The window the popover is actually drawing, so lifecycle checks can inspect
  /// what a person can see rather than a controller's detached view.
  var dashboardWindowForTesting: NSWindow? {
    self.popover.contentViewController?.view.window
  }

  var isDashboardShownForTesting: Bool { self.popover.isShown }

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

  /// The same path the disclosure control takes, so lifecycle checks exercise
  /// the real toggle rather than writing the store directly.
  func toggleProviderDetailForTesting(_ provider: ProviderID) {
    self.store.expandedProvider = self.store.expandedProvider == provider ? nil : provider
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
      singleSummary.primary == "1 plan in deficit"
      && pluralSummary.primary == "2 plans in deficit"
      && pluralSummary.secondary.contains("8% in deficit")
      && staleSummary.primary == "1 plan needs an update"
      && staleSummary.secondary.contains("2 other plans have reserve")
      && oneHealthyStale.secondary.contains("1 other plan has reserve")
      && !oneHealthyStale.secondary.contains("have reserve")
      && mixedStale.secondary.contains("1 other plan has reserve")
      && mixedStale.secondary.contains("1 is on pace")
      && !mixedStale.secondary.contains("remain on pace")
      && mixedHealthy.primary == "1 plan has reserve · 2 are on pace"
      && freshWithoutForecast.primary == "1 plan has no pace forecast"
      && freshWithoutForecast.secondary.contains("2 other plans have reserve")
      && !freshWithoutForecast.primary.contains("update")
      && !staleSummary.primary.contains("All plans")
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
      ) == "25% deficit · runs out 3d 2h early"
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
      ProviderArtwork.hasBundledMark(for: $0)
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
      && size.height <= DashboardMetrics.maximumHeight
      // A menu-bar popover has to clear the menu bar on the shortest current Mac.
      && size.height <= 900
    // The glance view leads with one conclusion, not a strip of totals.
    let headlinePresent = identifiers.contains("dashboard-headline")
    let activityMetricsAreGone =
      !labels.contains("PROVIDERS")
      && !labels.contains("TOKENS TODAY")
      && !labels.contains("TOKENS LAST 30D")
      && !labels.contains("SAVED LAST 30D")
      && !labels.contains("API VALUE")
    // Every percentage states what it measures.
    let percentagesAreLabelled =
      labels.filter { $0 == "left" }.count == ProviderID.allCases.count
      && labels.contains { $0.hasSuffix("% left") }
    let forecastCount = descendants.filter { $0.identifier?.rawValue == "forecast" }.count
    let allowanceCount = descendants.filter {
      ($0.identifier?.rawValue ?? "").hasPrefix("allowance-")
    }.count
    let forecastsPresent =
      forecastCount == ProviderID.allCases.count
      && allowanceCount == ProviderID.allCases.count
      && labels.contains {
        $0.contains("in reserve") || $0.hasPrefix("On pace") || $0.contains("in deficit")
          || $0.hasPrefix("Forecast unavailable")
      }
    // Provider availability is announced only when it is not normal.
    let serviceStatusIsExceptionOnly =
      !identifiers.contains("status-anthropic")
      && !identifiers.contains("status-openAI")
      && !identifiers.contains("status-grok")
      && !identifiers.contains("status-cursor")
    let expectedSecondaryWindows = self.store.orderedStates
      .filter { self.store.isEnabled($0.provider) }
      .reduce(0) { count, state in
        count + max(0, (state.snapshot?.windows.count ?? 0) - 1)
      }
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
        quit: {}))
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
        $0.contains("Cached") && $0.contains("updated")
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

    // Keyboard: rows take focus and answer Space and Return.
    let keyboardReachable =
      descendants.compactMap { $0 as? ProviderDashboardCard }.allSatisfy {
        $0.acceptsFirstResponder && $0.canBecomeKeyView
      }
      && dashboardController.view.acceptsFirstResponder
      && dashboardController.view.responds(to: #selector(NSResponder.cancelOperation(_:)))
      && dashboardController.firstKeyView() is ProviderDashboardCard
    func key(_ characters: String) -> NSEvent? {
      NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
        context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: 0)
    }
    let spaceSelectsProvider: Bool
    let returnOpensDetail: Bool
    if let card = descendants.compactMap({ $0 as? ProviderDashboardCard }).first(where: {
      $0.identifier?.rawValue == "provider-card-grok"
    }), let space = key(" "), let enter = key("\r") {
      let beforeProvider = self.store.menuBarProvider
      card.keyDown(with: space)
      spaceSelectsProvider = self.store.menuBarProvider == .grok
      self.store.menuBarProvider = beforeProvider
      let beforeExpansion = self.store.expandedProvider
      card.keyDown(with: enter)
      returnOpensDetail = self.store.expandedProvider == .grok
      self.store.expandedProvider = beforeExpansion
      dashboardController.update()
      dashboardController.view.layoutSubtreeIfNeeded()
    } else {
      spaceSelectsProvider = false
      returnOpensDetail = false
    }

    // VoiceOver: rows speak their whole state, and decoration stays silent.
    let liveDescendants = Self.descendants(of: dashboardController.view)
    let spokenRows = liveDescendants.compactMap { $0 as? ProviderDashboardCard }
    let rowsAreSpoken =
      spokenRows.count == ProviderID.allCases.count
      && spokenRows.allSatisfy {
        $0.accessibilityRole() == .button
          && ($0.accessibilityLabel() ?? "").isEmpty == false
          && ($0.accessibilityValue() as? String ?? "").contains("percent left")
          && ($0.accessibilityHelp() ?? "").isEmpty == false
      }
    // Decoration must not announce itself: the row already says which provider
    // it is, so no image may carry its own label.
    let decorationIsSilent = liveDescendants.compactMap { $0 as? NSImageView }
      .allSatisfy { ($0.accessibilityLabel() ?? "").isEmpty }
    let renderedMeters = liveDescendants.compactMap { $0 as? ReserveMeter }
    let metersAreSpoken = renderedMeters.allSatisfy {
        $0.accessibilityRole() == .progressIndicator
          && ($0.accessibilityLabel() ?? "").isEmpty == false
          && ($0.accessibilityValue() as? String ?? "").contains("percent left")
      }
    let primaryAllowances = previewSummaries.compactMap(\.primary)
    let meterSemanticsWork =
      renderedMeters.count == primaryAllowances.count
      && zip(renderedMeters, primaryAllowances).allSatisfy { meter, allowance in
        let expectedPace = allowance.expectedPercent.map { 100 - $0 }
        let paceMatches: Bool =
          switch (meter.paceRemainingPercentForTesting, expectedPace) {
          case (nil, nil): true
          case (.some(let rendered), .some(let expected)): abs(rendered - expected) < 0.001
          default: false
          }
        return abs(meter.remainingPercentForTesting - allowance.remainingPercent) < 0.001
          && paceMatches
      }
    let chartScaleWorks =
      ReserveSparkline.heightFraction(tokens: 0, peak: 10_000) == 0
      && ReserveSparkline.heightFraction(tokens: 10_000, peak: 10_000) == 1
      && abs(ReserveSparkline.heightFraction(tokens: 400, peak: 10_000) - 0.2) < 0.001

    // Progressive disclosure: one provider opens at a time and exposes limits and usage.
    let disclosuresPresent = ProviderID.allCases.allSatisfy {
      identifiers.contains("disclose-\($0.rawValue)")
    }
    let originalExpansion = self.store.expandedProvider
    self.store.expandedProvider = .anthropic
    dashboardController.update()
    dashboardController.view.layoutSubtreeIfNeeded()
    let expanded = Self.descendants(of: dashboardController.view)
    let expandedIDs = Set(expanded.compactMap { $0.identifier?.rawValue })
    let expandedLabels = expanded.compactMap { ($0 as? NSTextField)?.stringValue }
    let detailLayersPresent =
      // Layer 1: every remaining window as a full component.
      expanded.filter { ($0.identifier?.rawValue ?? "").hasPrefix("allowance-detail-") }.count == 2
      && expandedLabels.contains { $0.hasSuffix("% left") }
      && !expandedLabels.contains { $0.hasSuffix("% used") }
      // Activity and estimated value.
      && expandedIDs.contains("usage-detail-anthropic")
      && expandedLabels.contains("Estimated API value")
      // The history chart lives with the activity numbers.
      && expandedIDs.contains("usage-chart-anthropic")
      && expandedLabels.contains { $0.contains("compressed scale") }
      // The internal provenance block is intentionally absent from every provider.
      && !expandedIDs.contains { $0.hasPrefix("sources-") }
      // Only one row opens at a time.
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
      let marks = Self.descendants(of: dashboardController.view).filter {
        ($0.identifier?.rawValue ?? "").hasPrefix("menu-bar-pin-")
      }
      self.store.menuBarProvider = original
      dashboardController.update()
      dashboardController.view.layoutSubtreeIfNeeded()
      return marks.count == 1
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
    guard providerCards == ProviderID.allCases.count, actionsPresent, quitRemainsReachable,
      logosPresent, bundledProviderArtworkPresent, scrollingMatchesAvailableSpace, contentFits,
      dashboardFits, headlinePresent,
      activityMetricsAreGone, percentagesAreLabelled, forecastsPresent, disclosuresPresent,
      detailLayersPresent, keyboardReachable, spaceSelectsProvider, returnOpensDetail,
      rowsAreSpoken, decorationIsSilent, metersAreSpoken, meterSemanticsWork, motionIsPurposeful,
      chartScaleWorks,
      serviceStatusIsExceptionOnly, secondaryWindowsPresent, selectionIsQuiet,
      providerStatusWorks, directProviderSelectionWorks, fullCardSelectionHitTargetWorks,
      firstClickSelectionWorks, footerButtonsArePadded, providerButtonsArePadded,
      refreshButtonIsPadded, dashboardTypographyIsReadable, oauthURLParsingIsSafe,
      outsideClickDismissalWorks, updateMigrationWorks,
      scheduledRefreshWorks,
      staleFreshnessIsVisible, freshWithoutForecastDoesNotLookStale,
      automaticSourceWorks,
      pinnedModelWorks, aggregateCopyWorks, deficitForecastUsesRenewalGap,
      primaryWindowIgnoresComponentShares, compactMoneyKeepsCurrency,
      localizedTimeUsesRegionalClock,
      semanticColorsWork, minuteClockIsCoordinated, resumeRefreshDecisionsWork
    else {
      return (
        false,
        "dashboard providers=\(providerCards)/\(ProviderID.allCases.count), actions=\(actionsPresent), quitReachable=\(quitRemainsReachable), logos=\(logosPresent), bundledArtwork=\(bundledProviderArtworkPresent), scroll=\(hasScrollView), adaptiveScroll=\(scrollingMatchesAvailableSpace), fits=\(contentFits), size=\(dashboardFits) (\(Int(size.width))×\(Int(size.height))), headline=\(headlinePresent), activityGone=\(activityMetricsAreGone), labelledPercentages=\(percentagesAreLabelled), forecasts=\(forecastsPresent) (\(forecastCount)/\(allowanceCount)), forecastRenewalGap=\(deficitForecastUsesRenewalGap), primaryNonShare=\(primaryWindowIgnoresComponentShares), compactMoney=\(compactMoneyKeepsCurrency), localizedTime=\(localizedTimeUsesRegionalClock), disclosures=\(disclosuresPresent), detailLayers=\(detailLayersPresent), keyboard=\(keyboardReachable), space=\(spaceSelectsProvider), return=\(returnOpensDetail), spokenRows=\(rowsAreSpoken), silentDecoration=\(decorationIsSilent), spokenMeters=\(metersAreSpoken), meterSemantics=\(meterSemanticsWork), chartScale=\(chartScaleWorks), motion=\(motionIsPurposeful), staleFreshness=\(staleFreshnessIsVisible), freshUnknown=\(freshWithoutForecastDoesNotLookStale), statusExceptionOnly=\(serviceStatusIsExceptionOnly), secondary=\(secondaryWindowsPresent), quietSelection=\(selectionIsQuiet), providerStatus=\(providerStatusWorks), directSelection=\(directProviderSelectionWorks), fullCardHitTarget=\(fullCardSelectionHitTargetWorks), firstClick=\(firstClickSelectionWorks), footerPadding=\(footerButtonsArePadded), providerPadding=\(providerButtonsArePadded), refreshPadding=\(refreshButtonIsPadded), readableType=\(dashboardTypographyIsReadable), oauthURL=\(oauthURLParsingIsSafe), outsideDismissal=\(outsideClickDismissalWorks), updateMigration=\(updateMigrationWorks), scheduledRefresh=\(scheduledRefreshWorks), automatic=\(automaticSourceWorks), pinned=\(pinnedModelWorks), aggregate=\(aggregateCopyWorks), semanticColors=\(semanticColorsWork), minuteClock=\(minuteClockIsCoordinated), resumeRefresh=\(resumeRefreshDecisionsWork)"
      )
    }
    return (
      true,
      "dashboard leads with one factual conclusion, gives \(providerCards) providers the same reserve/on-pace/deficit anatomy, uses fixed semantic colors without red quota states, selects the automatic or pinned menu-bar source, opens one provider at a time onto limits and usage, shares one minute clock, refreshes stale data after resume, takes keyboard focus with Space and Return, and fits adaptively on the available screen"
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
    guard let controller = self.dashboardController else { return }
    self.dashboardIsDirty = true
    let wasShown = self.popover.isShown
    if wasShown { self.popover.animates = false }
    self.updateDashboardIfNeeded(force: true)
    guard self.popover.isShown else {
      self.popover.animates = self.animatesPopover
      return
    }
    self.popover.contentSize = controller.preferredContentSize
    self.popover.animates = self.animatesPopover
  }

  private func showDashboard() {
    guard let button = self.statusItem.button else { return }
    let dashboardController = self.dashboardControllerForUse()
    // A reopened surface has to come back in the current appearance, so this is
    // applied before the content is built rather than after it is on screen.
    self.applyAppearance()
    self.updateDashboardIfNeeded()
    // The closed state already uses the stable width. Lock that exact width so
    // opening the popover cannot grow the item leftward under the pointer.
    self.lockedStatusItemLength = self.statusItem.length
    self.updateStatusIcon()
    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
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
  }

  func popoverDidShow(_ notification: Notification) {
    // NSPopover finishes its own ordering after `show(relativeTo:)` returns.
    // Reapply the active-window ordering once that animation has completed.
    self.bringDashboardToFront()
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
    RunLoop.main.add(timer, forMode: .common)
    self.minuteTimer = timer
  }

  @objc private func minuteTick() {
    let now = Date()
    self.updateStatusIcon(now: now)
    if self.popover.isShown { self.updateDashboardIfNeeded(force: true) }
    self.updateMinuteTimer(now: now)
  }

  private func updateDashboardIfNeeded(force: Bool = false) {
    let minute = Int(Date().timeIntervalSince1970 / 60)
    guard force || self.dashboardIsDirty || self.lastDashboardMinute != minute else { return }
    let controller = self.dashboardControllerForUse()
    if controller.isViewLoaded {
      controller.update()
    } else {
      controller.loadViewIfNeeded()
    }
    self.dashboardIsDirty = false
    self.lastDashboardMinute = minute
  }

  private func showSettings() {
    self.openSettings()
    self.bringReserveWindowToFront(forClickedWindow: self.settingsWindow)
  }

  private func connectProvider(_ provider: ProviderID) {
    self.popover.performClose(nil)
    DispatchQueue.main.async { [weak self] in self?.setupProvider(provider) }
  }

  private func dashboardControllerForUse() -> DashboardViewController {
    if let dashboardController { return dashboardController }
    let controller = DashboardViewController(
      store: self.store,
      actions: DashboardActions(
        refreshAll: { [weak self] in self?.store.refreshAll() },
        connectProvider: { [weak self] provider in self?.connectProvider(provider) },
        selectMenuBarProvider: { [weak self] provider in
          self?.store.selectMenuBarProvider(provider)
        },
        openSettings: { [weak self] in self?.showSettings() },
        openInsights: { [weak self] in self?.openInsights() },
        dismiss: { [weak self] in self?.popover.performClose(nil) },
        toggleProviderDetail: { [weak self] provider in
          guard let self else { return }
          // One row at a time, so cross-provider comparison survives.
          self.store.expandedProvider = self.store.expandedProvider == provider ? nil : provider
          self.expandDashboard()
        },
        quit: { NSApplication.shared.terminate(nil) }))
    self.dashboardController = controller
    self.popover.contentViewController = controller
    return controller
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
