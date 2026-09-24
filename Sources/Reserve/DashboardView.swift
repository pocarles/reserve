import AppKit
import ReserveCore

@MainActor
struct DashboardActions {
  let refreshAll: () -> Void
  let connectProvider: (ProviderID) -> Void
  let selectMenuBarProvider: (ProviderID) -> Void
  let openSettings: () -> Void
  let openInsights: () -> Void
  let dismiss: () -> Void
  let toggleProviderDetail: (ProviderID) -> Void
  let quit: () -> Void
  /// Enabled API measurements. Empty unless a key has been saved, so the
  /// section stays out of the subscription view.
  let apiConsumptionReadings: () -> [APIConsumptionReading]
  /// Opens or closes one API row's details.
  var toggleAPIDetail: (APIConsumptionProvider) -> Void = { _ in }
  /// Opens the sanitized share preview for the selected provider.
  var shareUsage: () -> Void = {}
  /// Toggles presentation masking. Originals stay in the store.
  var toggleHidePersonalInfo: () -> Void = {}
  var hidesPersonalInfo: () -> Bool = { false }
}

@MainActor
extension APIConsumptionSnapshot {
  /// The whole breakdown spelled out, for a tooltip where width is not scarce.
  var breakdownSummary: String? {
    guard !self.breakdown.isEmpty else { return nil }
    return self.breakdown
      .map { "\($0.label) \(DashboardFormat.money($0.usedUSD))" }
      .joined(separator: " · ")
  }
}

struct APIConsumptionReading {
  let provider: APIConsumptionProvider
  let snapshot: APIConsumptionSnapshot?
  let error: String?
  let isRefreshing: Bool
  var isExpanded = false
  var hidesPersonalInfo = false
}

@MainActor
final class DashboardViewController: NSViewController {
  private let store: UsageStore
  private let actions: DashboardActions
  private let maximumHeight: () -> CGFloat
  private var lastSignature: String?
  private var lastMaximumHeight: CGFloat?
  /// Whole-tree replacements. Routine readings should not move this.
  private(set) var fullRebuildCount = 0
  /// In-place reading updates. Clock-only ticks are not counted.
  private(set) var contentUpdateCount = 0

  var regionRebuildCount: Int {
    (self.isViewLoaded ? self.view as? UsageDashboardView : nil)?.regionRebuildCount ?? 0
  }

  /// Drops the built tree after the popover closes. The next open builds it again.
  func releaseRenderedTree() {
    guard self.isViewLoaded else { return }
    self.view = NSView(frame: NSRect(origin: .zero, size: DashboardMetrics.size))
    self.lastSignature = nil
    self.lastMaximumHeight = nil
  }

  init(
    store: UsageStore,
    maximumHeight: @escaping () -> CGFloat = {
      DashboardMetrics.availableHeight(on: NSScreen.main)
    },
    actions: DashboardActions
  ) {
    self.store = store
    self.actions = actions
    self.maximumHeight = maximumHeight
    super.init(nibName: nil, bundle: nil)
    self.preferredContentSize = NSSize(
      width: DashboardMetrics.width, height: DashboardMetrics.minimumHeight)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() { self.update() }

  /// What the dashboard would currently render, as text.
  ///
  /// The whole view tree used to be rebuilt on every store change *and* every
  /// minute tick, even when only the clock had moved and nothing on screen
  /// differed. Comparing the rendered strings first is far cheaper than
  /// allocating several hundred AppKit views to discover they were identical.
  static func signature(
    summaries: [ProviderSummary],
    selectedMenuBarProvider: ProviderID?,
    expandedProvider: ProviderID?,
    isRefreshing: Bool,
    hidesPersonal: Bool = false,
    apiReadings: [APIConsumptionReading] = [],
    now: Date
  ) -> String {
    var parts: [String] = [
      // Appearance is part of what is rendered: a theme or light/dark change
      // alters every colour while leaving all the text identical.
      ReserveAppearance.current.rawValue,
      ReserveAppearance.resolvedAppearance.name.rawValue,
      selectedMenuBarProvider?.rawValue ?? "-",
      expandedProvider?.rawValue ?? "-",
      isRefreshing ? "busy" : "idle",
      hidesPersonal ? "hide-personal" : "show-personal",
      AllowanceBuilder.headline(for: summaries, now: now).primary,

    ]
    for summary in summaries {
      parts.append(summary.provider.rawValue)
      parts.append(summary.planName)
      parts.append(summary.paceState.label)
      parts.append(summary.observationTimeKnown ? "observed" : "observation-unknown")
      parts.append(summary.subscriptionCostLabel ?? "-")
      parts.append(String(reflecting: summary.lastUpdated))
      parts.append(String(reflecting: summary.checkedAt))
      parts.append(String(reflecting: summary.availableResetCount))
      parts.append(String(reflecting: summary.billingRenewsAt))
      parts.append(String(reflecting: summary.nextRenewal))
      parts.append(summary.localHistoryEnabled ? "local-history" : "-")
      parts.append(summary.historyPossible ? "history-possible" : "-")
      parts.append(String(reflecting: summary.localHistoryCheckedAt))
      parts.append(summary.localHistoryError ?? "-")
      parts.append(summary.error ?? "-")
      parts.append(summary.needsConnection ? "connect" : "-")
      parts.append(summary.requiresKeychainAccess ? "keychain" : "-")
      parts.append(summary.isConnecting ? "connecting" : "-")
      parts.append(summary.isRefreshing ? "refreshing" : "-")
      parts.append(summary.serviceStatus?.health.rawValue ?? "-")
      parts.append(summary.serviceStatus?.detail ?? "-")
      parts.append(summary.serviceStatus?.pageURL.absoluteString ?? "-")
      parts.append(
        summary.serviceStatus.map { String($0.fetchedAt.timeIntervalSinceReferenceDate) } ?? "-")
      parts.append(summary.quotaSource ?? "-")
      parts.append(summary.subscriptionCostUSD.map { String($0) } ?? "-")
      parts.append(String(reflecting: summary.includedSpend))
      parts.append(String(reflecting: summary.creditBalanceMinorUnits))
      parts.append(summary.detailedUsageUnavailable ? "usage-unavailable" : "-")
      parts.append(String(reflecting: summary.localUsage))
      for allowance in summary.allowances {
        parts.append(allowance.id)
        parts.append(String(allowance.usedPercent))
        parts.append(String(reflecting: allowance.resetsAt))
        parts.append(allowance.paceState.label)
        parts.append(allowance.isPrimary ? "primary" : "secondary")
      }
    }
    for reading in apiReadings {
      parts.append("api")
      parts.append(reading.provider.rawValue)
      parts.append(reading.error ?? "-")
      parts.append(reading.isRefreshing ? "measuring" : "-")
      parts.append(reading.snapshot.map { String($0.primary?.usedMinorUnits ?? 0) } ?? "-")
      parts.append(reading.snapshot?.breakdown.map(\.id).joined(separator: ",") ?? "-")
      parts.append(reading.snapshot?.note?.headline ?? "-")
      parts.append(reading.isExpanded ? "open" : "-")
      parts.append(reading.snapshot?.details.map { $0.label + "=" + $0.value }.joined(separator: ",") ?? "-")
    }
    return parts.joined(separator: "\u{1}")
  }

  func update() {
    let maximumHeight = self.maximumHeight()
    let now = Date()
    let visibleStates = self.store.orderedStates.filter { self.store.isEnabled($0.provider) }
    let refreshing = self.store.isRefreshingAll
    let signature = Self.signature(
      summaries: visibleStates.map { AllowanceBuilder.summary(for: $0, now: now) },
      selectedMenuBarProvider: self.store.menuBarProvider,
      expandedProvider: self.store.expandedProvider,
      isRefreshing: refreshing,
      hidesPersonal: self.store.hidesPersonalInfo,
      apiReadings: self.actions.apiConsumptionReadings(),
      now: now)
    if self.isViewLoaded, self.view is UsageDashboardView,
      signature == self.lastSignature, maximumHeight == self.lastMaximumHeight
    {
      for clock in Self.descendants(of: self.view).compactMap({ $0 as? any ReserveClockUpdating }) {
        clock.updateClock(now)
      }
      return
    }
    if self.isViewLoaded, let dashboard = self.view as? UsageDashboardView,
      dashboard.apply(
        states: visibleStates,
        selectedMenuBarProvider: self.store.menuBarProvider,
        expandedProvider: self.store.expandedProvider,
        isRefreshing: refreshing,
        refreshStartedAt: self.store.refreshStartedAt,
        now: now,
        maximumHeight: maximumHeight,
        actions: self.actions)
    {
      self.lastSignature = signature
      self.lastMaximumHeight = maximumHeight
      // The frame is still the popover's current size here; the new height is
      // what the dashboard was laid out for.
      self.preferredContentSize = NSSize(
        width: DashboardMetrics.width, height: dashboard.intendedHeight)
      self.contentUpdateCount += 1
      return
    }
    self.fullRebuildCount += 1
    self.lastSignature = signature
    self.lastMaximumHeight = maximumHeight
    let dashboard = UsageDashboardView(
      states: visibleStates,
      selectedMenuBarProvider: self.store.menuBarProvider,
      expandedProvider: self.store.expandedProvider,
      isRefreshing: self.store.isRefreshingAll,
      refreshStartedAt: self.store.refreshStartedAt,
      now: now,
      maximumHeight: maximumHeight,
      actions: self.actions)
    // The size has to be read before the view is installed. Assigning `view`
    // hands it to the popover, which immediately resizes it to the size the
    // popover still believes it is — so reading the frame afterwards reports the
    // previous height and the popover is then told to keep it.
    let intrinsicSize = dashboard.frame.size
    self.view = dashboard
    self.preferredContentSize = intrinsicSize
  }

  /// The first provider tile, so opening the popover puts the keyboard on the
  /// dashboard's primary navigation rather than nowhere.
  func firstKeyView() -> NSView? {
    self.view.window?.contentView.flatMap { _ in
      Self.descendants(of: self.view).compactMap { $0 as? ProviderOverviewTile }.first
    } ?? Self.descendants(of: self.view).compactMap { $0 as? ProviderOverviewTile }.first
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { Self.descendants(of: $0) }
  }

}

/// The glance view. It answers one question — which allowance needs attention,
/// how much is left, and when does it come back — and defers everything else.
@MainActor
final class UsageDashboardView: NSView {
  private let dismiss: () -> Void
  /// The height this dashboard was laid out for. The popover has to display it
  /// at this height; showing it at any other height means rows are off screen.
  private(set) var intendedHeight: CGFloat = DashboardMetrics.minimumHeight
  /// Replacements of one provider tile, the detail card, or the API block.
  private(set) var regionRebuildCount = 0
  private var column: NSStackView?
  private var detailColumn: NSStackView?
  private var headerView: DashboardHeaderView?
  private var overviewGrid: ProviderOverviewGrid?
  private var detailCard: ProviderDashboardCard?
  private var emptyState: NSView?
  private var apiSection: APIConsumptionSection?
  private var footerView: DashboardFooterView?
  private var appliedAppearance = ""
  private var showsEmpty = false
  private var providerIDs: [ProviderID] = []
  private var isScrollable = false
  private var scrollsDetailsOnly = false
  private var scrollDocument: FlippedView?
  private var scrollHeightConstraint: NSLayoutConstraint?

  init(
    states: [ProviderViewState],
    selectedMenuBarProvider: ProviderID?,
    expandedProvider: ProviderID? = nil,
    isRefreshing: Bool,
    refreshStartedAt: Date? = nil,
    now: Date,
    maximumHeight: CGFloat = DashboardMetrics.maximumHeight,
    actions: DashboardActions
  ) {
    let ceiling = max(DashboardMetrics.minimumHeight, maximumHeight)
    self.dismiss = actions.dismiss
    super.init(frame: NSRect(origin: .zero, size: DashboardMetrics.size))
    self.identifier = NSUserInterfaceItemIdentifier("usage-dashboard")
    self.setAccessibilityLabel("Reserve dashboard")
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(ReserveColor.background)

    let summaries = states.map { AllowanceBuilder.summary(for: $0, now: now) }

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = DashboardMetrics.rowGap
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.column = stack
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: DashboardMetrics.inset),
      stack.trailingAnchor.constraint(
        equalTo: self.trailingAnchor, constant: -DashboardMetrics.inset),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: DashboardMetrics.inset),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: self.bottomAnchor, constant: -DashboardMetrics.inset),
    ])

    let header = DashboardHeaderView(
      summaries: summaries, isRefreshing: isRefreshing, refreshStartedAt: refreshStartedAt,
      now: now, actions: actions)
    self.headerView = header
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(DashboardMetrics.headerGap, after: header)

    let details = NSStackView.column([], spacing: DashboardMetrics.rowGap)
    details.translatesAutoresizingMaskIntoConstraints = false
    details.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth).isActive = true
    self.detailColumn = details
    let selectedSummary = expandedProvider.flatMap { selected in
      summaries.first(where: { $0.provider == selected })
    } ?? summaries.first
    if !summaries.isEmpty {
      let overview = ProviderOverviewGrid(
        summaries: summaries, selectedProvider: selectedSummary?.provider,
        menuBarProvider: selectedMenuBarProvider, now: now,
        selectProvider: actions.toggleProviderDetail)
      self.overviewGrid = overview
      self.providerIDs = summaries.map(\.provider)
      stack.addArrangedSubview(overview)

      if let summary = selectedSummary {
        let detail = ProviderDashboardCard(
          summary: summary, now: now,
          isSelectedForMenuBar: selectedMenuBarProvider == summary.provider,
          isExpanded: true, showsDisclosure: false,
          connectProvider: actions.connectProvider,
          selectMenuBarProvider: actions.selectMenuBarProvider,
          toggleDetail: actions.toggleProviderDetail)
        detail.identifier = NSUserInterfaceItemIdentifier(
          "provider-card-\(summary.provider.rawValue)")
        self.detailCard = detail
        details.addArrangedSubview(detail)
      }
    }
    self.showsEmpty = summaries.isEmpty
    if summaries.isEmpty {
      let empty = EmptyProvidersView(openSettings: actions.openSettings)
      self.emptyState = empty
      details.addArrangedSubview(empty)
    }
    if let consumption = APIConsumptionSection(
      readings: actions.apiConsumptionReadings(), now: now, toggle: actions.toggleAPIDetail)
    {
      self.apiSection = consumption
      details.addArrangedSubview(consumption)
    }

    stack.addArrangedSubview(details)
    let footer = DashboardFooterView(actions: actions)
    self.footerView = footer
    stack.addArrangedSubview(footer)
    stack.setCustomSpacing(DashboardMetrics.footerGap, after: details)

    // Content-sized, with a ceiling that keeps the popover clear of the menu bar
    // and inside the screen it opens on.
    self.layoutSubtreeIfNeeded()
    let content = ceil(stack.fittingSize.height) + 2 * DashboardMetrics.inset
    let height = min(ceiling, max(DashboardMetrics.minimumHeight, content))
    self.intendedHeight = height
    if Self.requiresScrolling(contentHeight: content, ceiling: ceiling) {
      let detailHeight = ceil(details.fittingSize.height)
      let fixedHeight = content - detailHeight
      if fixedHeight + DashboardMetrics.minimumDetailsViewport < ceiling {
        self.makeScrollable(
          stack: stack, details: details, contentHeight: detailHeight,
          viewportHeight: ceiling - fixedHeight)
      } else {
        // A large provider grid can leave too little room for a useful detail
        // viewport. Keep every tile reachable on unusually short screens.
        self.makeWholeDashboardScrollable(stack: stack, contentHeight: content)
      }
      self.isScrollable = true
    }
    self.frame = NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: height)
    self.appliedAppearance = Self.appearanceKey()
    self.layoutSubtreeIfNeeded()
  }

  /// Updates labels, meters, and the refresh spinner when the set of controls
  /// is unchanged. A provider list, theme, or scroll-mode change returns false
  /// so the caller can replace the affected tree.
  func apply(
    states: [ProviderViewState],
    selectedMenuBarProvider: ProviderID?,
    expandedProvider: ProviderID?,
    isRefreshing: Bool,
    refreshStartedAt: Date?,
    now: Date,
    maximumHeight: CGFloat,
    actions: DashboardActions
  ) -> Bool {
    if Self.appearanceKey() != self.appliedAppearance { return false }
    let summaries = states.map { AllowanceBuilder.summary(for: $0, now: now) }
    if summaries.isEmpty != self.showsEmpty { return false }
    guard let column = self.column, let details = self.detailColumn,
      let header = self.headerView else { return false }
    header.apply(
      summaries: summaries, isRefreshing: isRefreshing, refreshStartedAt: refreshStartedAt,
      now: now)
    let ids = summaries.map(\.provider)
    if !summaries.isEmpty {
      if let overview = self.overviewGrid, ids == self.providerIDs {
        let previousTileRebuilds = overview.tileRebuildCount
        overview.apply(
          summaries: summaries, selectedProvider: expandedProvider ?? summaries.first?.provider,
          menuBarProvider: selectedMenuBarProvider, now: now,
          selectProvider: actions.toggleProviderDetail)
        self.regionRebuildCount += overview.tileRebuildCount - previousTileRebuilds
      } else {
        self.replaceOverview(
          summaries: summaries, selectedProvider: expandedProvider ?? summaries.first?.provider,
          menuBarProvider: selectedMenuBarProvider, now: now, actions: actions, column: column)
      }
      self.providerIDs = ids
      let selected = expandedProvider.flatMap { id in summaries.first { $0.provider == id } }
        ?? summaries.first
      if let selected {
        var keptDetail = false
        if let detail = self.detailCard, detail.providerID == selected.provider {
          let previousRegionRebuilds = detail.regionRebuildCount
          keptDetail = detail.apply(
            summary: selected, now: now,
            isSelectedForMenuBar: selectedMenuBarProvider == selected.provider)
          self.regionRebuildCount += detail.regionRebuildCount - previousRegionRebuilds
        }
        if !keptDetail {
          self.replaceDetail(
            summary: selected, now: now, selectedMenuBarProvider: selectedMenuBarProvider,
            actions: actions, column: details)
        }
      }
    }
    let readings = actions.apiConsumptionReadings()
    if readings.isEmpty {
      if self.apiSection != nil { return false }
    } else if let section = self.apiSection {
      if !section.apply(readings: readings, now: now, toggle: actions.toggleAPIDetail) {
        self.replaceAPI(readings: readings, now: now, actions: actions, column: details)
      }
    } else {
      return false
    }
    guard self.relayout(maximumHeight: maximumHeight) else { return false }
    return true
  }

  private static func appearanceKey() -> String {
    "\(ReserveAppearance.current.rawValue)\u{1}\(ReserveAppearance.resolvedAppearance.name.rawValue)"
  }

  private func replaceOverview(
    summaries: [ProviderSummary],
    selectedProvider: ProviderID?,
    menuBarProvider: ProviderID?,
    now: Date,
    actions: DashboardActions,
    column: NSStackView
  ) {
    let overview = ProviderOverviewGrid(
      summaries: summaries, selectedProvider: selectedProvider,
      menuBarProvider: menuBarProvider, now: now,
      selectProvider: actions.toggleProviderDetail)
    if let existing = self.overviewGrid {
      column.replaceArrangedSubview(existing, with: overview)
    }
    self.overviewGrid = overview
    self.regionRebuildCount += 1
  }

  private func replaceDetail(
    summary: ProviderSummary,
    now: Date,
    selectedMenuBarProvider: ProviderID?,
    actions: DashboardActions,
    column: NSStackView
  ) {
    let detail = ProviderDashboardCard(
      summary: summary, now: now,
      isSelectedForMenuBar: selectedMenuBarProvider == summary.provider,
      isExpanded: true, showsDisclosure: false,
      connectProvider: actions.connectProvider,
      selectMenuBarProvider: actions.selectMenuBarProvider,
      toggleDetail: actions.toggleProviderDetail)
    detail.identifier = NSUserInterfaceItemIdentifier("provider-card-\(summary.provider.rawValue)")
    if let existing = self.detailCard {
      column.replaceArrangedSubview(existing, with: detail)
    }
    self.detailCard = detail
    self.regionRebuildCount += 1
  }

  private func replaceAPI(
    readings: [APIConsumptionReading],
    now: Date,
    actions: DashboardActions,
    column: NSStackView
  ) {
    guard let section = APIConsumptionSection(
      readings: readings, now: now, toggle: actions.toggleAPIDetail)
    else { return }
    if let existing = self.apiSection {
      column.replaceArrangedSubview(existing, with: section)
    }
    self.apiSection = section
    self.regionRebuildCount += 1
  }

  private func relayout(maximumHeight: CGFloat) -> Bool {
    let ceiling = max(DashboardMetrics.minimumHeight, maximumHeight)
    let scroll = self.scrollDocument?.enclosingScrollView
    let previousScrollOrigin = scroll?.contentView.bounds.origin
    self.layoutSubtreeIfNeeded()
    guard let column = self.column, let details = self.detailColumn else { return false }
    let detailHeight = ceil(details.fittingSize.height)
    // A detail-only scroll view has a fixed viewport. Replace that viewport
    // with the detail's natural height when deciding whether scrolling is
    // needed after a reading or display change.
    let viewportHeight = self.scrollHeightConstraint?.constant ?? 0
    let content = ceil(column.fittingSize.height) + 2 * DashboardMetrics.inset
      - viewportHeight + (self.scrollsDetailsOnly ? detailHeight : 0)
    let height = min(ceiling, max(DashboardMetrics.minimumHeight, content))
    let needsScroll = Self.requiresScrolling(contentHeight: content, ceiling: ceiling)
    if needsScroll != self.isScrollable { return false }
    let fixedHeight = content - detailHeight
    if needsScroll && self.scrollsDetailsOnly
      != (fixedHeight + DashboardMetrics.minimumDetailsViewport < ceiling)
    {
      return false
    }
    self.intendedHeight = height
    if self.scrollsDetailsOnly {
      self.scrollHeightConstraint?.constant = max(1, ceiling - fixedHeight)
    }
    // In the popover this view is the window's content view, and the window
    // owns its frame: it sits inside the popover border, not at the frame
    // view's origin. Setting it here dropped the dashboard 13pt down and left,
    // and made NSPopover resize around the moved view, leaving a gray band.
    // The controller publishes `intendedHeight` and the popover resizes to it.
    if self.window == nil {
      self.frame = NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: height)
    }
    if needsScroll, let document = self.scrollDocument {
      document.frame.size.height = self.scrollsDetailsOnly ? detailHeight : content
    }
    self.layoutSubtreeIfNeeded()
    if let scroll, let previousScrollOrigin, let document = self.scrollDocument {
      let maximumOffset = max(0, document.frame.height - scroll.contentView.bounds.height)
      scroll.contentView.scroll(to: NSPoint(
        x: previousScrollOrigin.x,
        y: min(max(0, previousScrollOrigin.y), maximumOffset)))
      scroll.reflectScrolledClipView(scroll.contentView)
    }
    return true
  }

  /// Construction and retained layout must make the same decision at the
  /// fractional-point boundary. AppKit can settle a newly attached stack a
  /// fraction of a point differently; that is not enough clipping to justify
  /// replacing the whole tree with a scroll view.
  private static func requiresScrolling(contentHeight: CGFloat, ceiling: CGFloat) -> Bool {
    contentHeight > ceiling + 0.5
  }

  /// Keep the glance and footer stable while a long provider card scrolls.
  private func makeScrollable(
    stack: NSStackView, details: NSStackView, contentHeight: CGFloat,
    viewportHeight: CGFloat
  ) {
    let document = FlippedView(frame: NSRect(
      x: 0, y: 0, width: DashboardMetrics.contentWidth, height: contentHeight))
    let scroll = NSScrollView(frame: NSRect(
      x: 0, y: 0, width: DashboardMetrics.contentWidth, height: viewportHeight))
    stack.replaceArrangedSubview(details, with: scroll)
    document.addSubview(details)
    NSLayoutConstraint.activate([
      details.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      details.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      details.topAnchor.constraint(equalTo: document.topAnchor),
      details.bottomAnchor.constraint(equalTo: document.bottomAnchor),
      scroll.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
    let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: viewportHeight)
    heightConstraint.isActive = true
    self.scrollHeightConstraint = heightConstraint
    self.scrollsDetailsOnly = true
    self.configureScroll(scroll, document: document)
  }

  /// If the provider grid itself is exceptionally tall, the whole dashboard
  /// remains scrollable so none of its tiles become unreachable.
  private func makeWholeDashboardScrollable(stack: NSStackView, contentHeight: CGFloat) {
    stack.removeFromSuperview()
    let document = FlippedView(
      frame: NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: contentHeight))
    stack.translatesAutoresizingMaskIntoConstraints = false
    document.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: document.leadingAnchor, constant: DashboardMetrics.inset),
      stack.trailingAnchor.constraint(
        equalTo: document.trailingAnchor, constant: -DashboardMetrics.inset),
      stack.topAnchor.constraint(equalTo: document.topAnchor, constant: DashboardMetrics.inset),
      stack.bottomAnchor.constraint(
        equalTo: document.bottomAnchor, constant: -DashboardMetrics.inset),
    ])
    let scroll = NSScrollView(frame: self.bounds)
    scroll.autoresizingMask = [.width, .height]
    self.addSubview(scroll)
    self.configureScroll(scroll, document: document)
  }

  private func configureScroll(_ scroll: NSScrollView, document: FlippedView) {
    self.scrollDocument = document
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    // A card that continues past the bottom edge has to announce itself. With
    // auto-hiding overlay scrollers the column simply stopped, and the provider
    // below the fold read as missing rather than as scrolled out of view.
    scroll.autohidesScrollers = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.contentView.scroll(to: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(ReserveColor.background)
    // Every child draws its own adaptive colours, so the whole tree redraws.
    self.needsDisplay = true
    for view in Self.allDescendants(of: self) { view.needsDisplay = true }
  }

  private static func allDescendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { self.allDescendants(of: $0) }
  }

  override var acceptsFirstResponder: Bool { true }

  /// Escape closes the dashboard, wherever focus happens to be.
  override func cancelOperation(_ sender: Any?) { self.dismiss() }
}

/// A top-anchored coordinate system for scrolled content.
private final class FlippedView: NSView {
  override var isFlipped: Bool { true }
}

/// Name, one conclusion, and the secondary controls.
@MainActor
private final class DashboardHeaderView: NSView {
  private var conclusionLabel: ReserveLabel?
  private var conclusionIcon: NSImageView?
  private var refreshButton: ReserveIconButton?

  init(
    summaries: [ProviderSummary],
    isRefreshing: Bool,
    refreshStartedAt: Date?,
    now: Date,
    actions: DashboardActions
  ) {
    super.init(frame: .zero)
    let wordmark = ReserveLabel(
      "Reserve", font: ReserveFont.sans(ReserveType.wordmark, .semibold),
      color: ReserveColor.text)

    let headline = AllowanceBuilder.headline(for: summaries, now: now)
    let conclusion = ReserveLabel(
      headline.primary,
      font: ReserveFont.sans(ReserveType.body, .medium),
      color: headline.state.color
    ).flexible()
    conclusion.toolTip = headline.primary
    self.conclusionLabel = conclusion
    let conclusionIcon = NSImageView(
      image: NSImage(systemSymbolName: headline.state.symbol, accessibilityDescription: nil)
        ?? NSImage())
    conclusionIcon.symbolConfiguration = NSImage.SymbolConfiguration(
      pointSize: 11, weight: .semibold)
    conclusionIcon.contentTintColor = headline.state.color
    conclusionIcon.setAccessibilityElement(false)
    conclusionIcon.setAccessibilityLabel("")
    conclusionIcon.translatesAutoresizingMaskIntoConstraints = false
    conclusionIcon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    self.conclusionIcon = conclusionIcon
    let conclusionRow = NSStackView.row([conclusionIcon, conclusion], spacing: 6)
    conclusionRow.identifier = NSUserInterfaceItemIdentifier("dashboard-headline")

    let refresh = ReserveIconButton(
      symbol: "arrow.clockwise", toolTip: "Refresh now", diameter: 26,
      spinningSince: isRefreshing ? now.timeIntervalSince(refreshStartedAt ?? now) : nil,
      action: actions.refreshAll)
    refresh.identifier = NSUserInterfaceItemIdentifier("refresh-all")
    self.refreshButton = refresh
    let more = DashboardMenuButton(actions: actions)
    more.identifier = NSUserInterfaceItemIdentifier("more-actions")
    let top = NSStackView.row(
      [wordmark, NSStackView.spacer(), refresh, more], spacing: 7)
    conclusion.clockText = { date in
      AllowanceBuilder.headline(for: summaries.map { $0.at(date) }, now: date).primary
    }
    let stack = NSStackView.column([top, conclusionRow], spacing: 5)
    stack.setCustomSpacing(10, after: top)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  func apply(
    summaries: [ProviderSummary],
    isRefreshing: Bool,
    refreshStartedAt: Date?,
    now: Date
  ) {
    let headline = AllowanceBuilder.headline(for: summaries, now: now)
    self.conclusionLabel?.setDisplayedText(headline.primary, color: headline.state.color)
    self.conclusionLabel?.toolTip = headline.primary
    self.conclusionLabel?.clockText = { date in
      AllowanceBuilder.headline(for: summaries.map { $0.at(date) }, now: date).primary
    }
    self.conclusionIcon?.image = NSImage(
      systemSymbolName: headline.state.symbol, accessibilityDescription: nil)
    self.conclusionIcon?.contentTintColor = headline.state.color
    let phase = isRefreshing ? now.timeIntervalSince(refreshStartedAt ?? now) : nil
    self.refreshButton?.setSpinning(since: phase)
  }

  required init?(coder: NSCoder) { nil }
}

/// Secondary actions live behind one control so the footer stays about usage.
@MainActor
final class DashboardMenuButton: NSButton {
  private let actions: DashboardActions

  init(actions: DashboardActions) {
    self.actions = actions
    super.init(frame: .zero)
    self.title = ""
    self.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "More actions")
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    self.contentTintColor = ReserveColor.muted
    self.toolTip = "More actions"
    self.setAccessibilityLabel("More actions")
    self.isBordered = false
    self.target = self
    self.action = #selector(self.showMenu)
    self.widthAnchor.constraint(equalToConstant: 26).isActive = true
    self.heightAnchor.constraint(equalToConstant: 26).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  /// Exposed so the self-test can confirm Quit remains reachable.
  func makeMenu() -> NSMenu {
    let menu = NSMenu()
    let insights = self.menuItem(
      title: "Insights…", action: #selector(self.openInsights), symbol: "chart.bar")
    let settings = self.menuItem(
      title: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",",
      symbol: "gearshape")
    let quit = self.menuItem(
      title: "Quit Reserve", action: #selector(self.quit), keyEquivalent: "q", symbol: "power")
    menu.addItem(insights)
    menu.addItem(settings)
    let share = self.menuItem(
      title: "Share usage…", action: #selector(self.shareUsage), symbol: "square.and.arrow.up")
    let hidesPersonalInfo = self.actions.hidesPersonalInfo()
    let privacy = self.menuItem(
      title: hidesPersonalInfo ? "Show personal info" : "Hide personal info",
      action: #selector(self.togglePrivacy),
      symbol: hidesPersonalInfo ? "eye" : "eye.slash")
    menu.addItem(share)
    menu.addItem(privacy)
    menu.addItem(.separator())
    menu.addItem(quit)
    return menu
  }

  private func menuItem(
    title: String,
    action: Selector,
    keyEquivalent: String = "",
    symbol: String
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
    item.target = self
    item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    item.image?.isTemplate = true
    return item
  }

  @objc private func showMenu() {
    let menu = self.makeMenu()
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.height + 4), in: self)
  }

  @objc private func openInsights() { self.actions.openInsights() }
  @objc private func openSettings() { self.actions.openSettings() }
  @objc private func shareUsage() { self.actions.shareUsage() }
  @objc private func togglePrivacy() { self.actions.toggleHidePersonalInfo() }
  @objc private func quit() { self.actions.quit() }
}

/// API spend, kept apart from subscription limits. Absent unless a key was saved.
@MainActor
private final class APIConsumptionSection: NSView {
  private var structure = ""

  init?(
    readings: [APIConsumptionReading], now: Date,
    toggle: @escaping (APIConsumptionProvider) -> Void = { _ in }
  ) {
    guard !readings.isEmpty else { return nil }
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("api-consumption")
    self.wantsLayer = true
    let title = ReserveLabel(
      "API consumption",
      font: ReserveFont.sans(ReserveType.metadata, .semibold),
      color: ReserveColor.muted)
    var rows: [NSView] = [title]
    for reading in readings {
      rows.append(Self.row(reading, now: now, toggle: toggle))
      if reading.isExpanded { rows.append(contentsOf: Self.details(reading)) }
    }
    let stack = NSStackView.column(rows, spacing: 7)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 12),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -12),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
    self.structure = Self.structureKey(readings)
  }

  func apply(
    readings: [APIConsumptionReading],
    now: Date,
    toggle: @escaping (APIConsumptionProvider) -> Void
  ) -> Bool {
    guard Self.structureKey(readings) == self.structure else { return false }
    _ = toggle
    for reading in readings {
      let presented = Self.presented(reading, now: now)
      (self.control(id: "api-amount-\(reading.provider.rawValue)") as? ReserveLabel)?
        .setDisplayedText(presented.value)
      let caption = self.control(id: "api-caption-\(reading.provider.rawValue)") as? ReserveLabel
      caption?.setDisplayedText(presented.detail)
      caption?.toolTip = presented.toolTip
    }
    return true
  }

  private func control(id: String) -> NSView? {
    Self.walk(self).first { $0.identifier?.rawValue == id }
  }

  private static func walk(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { walk($0) }
  }

  private static func structureKey(_ readings: [APIConsumptionReading]) -> String {
    readings.map { reading in
      let details = reading.isExpanded
        ? PrivacyPresentation.details(
          reading.snapshot?.details ?? [], hidingPersonal: reading.hidesPersonalInfo
        ).map { "\($0.label)=\($0.value)" }.joined(separator: "\u{1}")
        : ""
      let expandedError = reading.isExpanded ? (reading.error ?? "") : ""
      return [
        reading.provider.rawValue,
        reading.isExpanded ? "open" : "closed",
        reading.hidesPersonalInfo ? "private" : "plain",
        details,
        expandedError,
      ].joined(separator: "\u{2}")
    }.joined(separator: "|")
  }

  private static func presented(
    _ reading: APIConsumptionReading, now: Date
  ) -> (value: String, detail: String, toolTip: String) {
    let value: String
    let detail: String
    if reading.isRefreshing, reading.snapshot == nil {
      value = "Measuring"
      detail = reading.provider.keyKind
    } else if let note = reading.snapshot?.note {
      value = note.headline
      detail = note.detail ?? reading.snapshot?.source ?? ""
    } else if let primary = reading.snapshot?.primary {
      value = DashboardFormat.money(primary.usedUSD)
      var caption: String
      if let limit = primary.limitUSD {
        caption = "of \(DashboardFormat.money(limit)) · \(primary.label)"
      } else if let reset = primary.resetsAt, reset > now {
        caption = "\(primary.label) · resets \(DashboardFormat.moment(reset, now: now))"
      } else {
        caption = primary.label
      }
      if let leader = reading.snapshot?.dominantBreakdownItem {
        caption += " · mostly \(leader.label)"
      }
      detail = caption
    } else {
      value = "—"
      detail = reading.error ?? "Waiting for the first read"
    }
    let toolTip = reading.error ?? reading.snapshot?.breakdownSummary ?? detail
    return (value, detail, toolTip)
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    let path = NSBezierPath(
      roundedRect: self.bounds, xRadius: ReserveRadius.section, yRadius: ReserveRadius.section)
    ReserveColor.section.setFill()
    path.fill()
  }

  /// Everything the provider reported beyond the headline, plus the full error
  /// when there is one, since the row can only show its start.
  private static func details(_ reading: APIConsumptionReading) -> [NSView] {
    // Indented to the provider name, so the details read as belonging to it.
    let indent: CGFloat = 32
    let width = DashboardMetrics.contentWidth - 24 - indent
    var facts: [NSView] = reading.snapshot?.details.map {
      let shown = PrivacyPresentation.details(
        [$0], hidingPersonal: reading.hidesPersonalInfo)
      return DashboardFact.row(shown[0].label, shown[0].value, width: width)
    } ?? []
    // The row already shows a short error in full; only a long one is repeated.
    if let error = reading.error, error.count > 44 {
      let note = ReserveLabel(
        error, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted)
      note.usesSingleLineMode = false
      note.cell?.wraps = true
      note.cell?.isScrollable = false
      note.lineBreakMode = .byWordWrapping
      note.maximumNumberOfLines = 3
      note.preferredMaxLayoutWidth = width
      note.widthAnchor.constraint(equalToConstant: width).isActive = true
      facts.insert(note, at: 0)
    }
    if facts.isEmpty {
      facts.append(
        reading.error != nil
          ? DashboardFact.row("To fix", "Replace the key in Settings → API", width: width)
          : DashboardFact.row("Details", "Nothing more reported", width: width))
    }
    return facts.map { fact in
      let gutter = NSView()
      gutter.translatesAutoresizingMaskIntoConstraints = false
      gutter.widthAnchor.constraint(equalToConstant: indent).isActive = true
      let line = NSStackView.row([gutter, fact], spacing: 0)
      line.identifier = NSUserInterfaceItemIdentifier("api-detail-\(reading.provider.rawValue)")
      return line
    }
  }

  private static func row(
    _ reading: APIConsumptionReading, now: Date,
    toggle: @escaping (APIConsumptionProvider) -> Void
  ) -> NSView {
    let logo = ProviderLogo(api: reading.provider)
    let name = ReserveLabel(
      reading.provider.displayName,
      font: ReserveFont.sans(ReserveType.body, .medium),
      color: ReserveColor.text
    ).width(84)
    let presented = Self.presented(reading, now: now)
    let amount = ReserveLabel(
      presented.value, font: ReserveFont.digits(ReserveType.body, .semibold), color: ReserveColor.text
    ).fitted()
    amount.identifier = NSUserInterfaceItemIdentifier("api-amount-\(reading.provider.rawValue)")
    let caption = ReserveLabel(
      presented.detail, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).flexible()
    caption.identifier = NSUserInterfaceItemIdentifier("api-caption-\(reading.provider.rawValue)")
    caption.toolTip = presented.toolTip
    let disclosure = APIDetailDisclosureButton(
      provider: reading.provider, isExpanded: reading.isExpanded, action: toggle)
    // The spacer takes the spare width, so every row's chevron lines up on the right.
    let row = NSStackView.row(
      [logo, name, amount, caption, NSStackView.spacer(), disclosure], spacing: 8)
    row.identifier = NSUserInterfaceItemIdentifier(
      "api-consumption-\(reading.provider.rawValue)")
    row.widthAnchor.constraint(
      equalToConstant: DashboardMetrics.contentWidth - 24).isActive = true
    return row
  }

}

/// Provider navigation stays compact and comparable. More enabled providers
/// add rows rather than turning the dashboard into a long accordion.
@MainActor
final class ProviderOverviewGrid: ReserveSurface {
  private var tiles: [ProviderID: ProviderOverviewTile] = [:]
  private var countLabel: ReserveLabel?
  private var selectProvider: ((ProviderID) -> Void)?
  private(set) var tileRebuildCount = 0

  init(
    summaries: [ProviderSummary], selectedProvider: ProviderID?, menuBarProvider: ProviderID?,
    now: Date,
    selectProvider: @escaping (ProviderID) -> Void
  ) {
    super.init(fill: ReserveColor.section, radius: ReserveRadius.section)
    self.selectProvider = selectProvider
    self.identifier = NSUserInterfaceItemIdentifier("provider-overview")

    let title = ReserveLabel(
      "Providers at a glance",
      font: ReserveFont.sans(ReserveType.body, .semibold), color: ReserveColor.text
    ).flexible()
    let count = ReserveLabel(
      "\(summaries.count) \(summaries.count == 1 ? "provider" : "providers")",
      font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).fitted()
    self.countLabel = count
    let heading = NSStackView.row([title, NSStackView.spacer(), count], spacing: 8)
    heading.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewInnerWidth).isActive = true

    var rows: [NSView] = [heading]
    var index = 0
    while index < summaries.count {
      let first = summaries[index]
      let firstTile = ProviderOverviewTile(
        summary: first, now: now, isSelected: selectedProvider == first.provider,
        isPinnedForMenuBar: menuBarProvider == first.provider,
        selectProvider: selectProvider)
      self.tiles[first.provider] = firstTile
      var columns: [NSView] = [firstTile]
      if summaries.indices.contains(index + 1) {
        let second = summaries[index + 1]
        let secondTile = ProviderOverviewTile(
          summary: second, now: now, isSelected: selectedProvider == second.provider,
          isPinnedForMenuBar: menuBarProvider == second.provider,
          selectProvider: selectProvider)
        self.tiles[second.provider] = secondTile
        columns.append(secondTile)
      } else {
        let placeholder = NSView()
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewTileWidth)
          .isActive = true
        columns.append(placeholder)
      }
      let row = NSStackView.row(columns, spacing: DashboardMetrics.overviewGap)
      row.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewInnerWidth).isActive = true
      rows.append(row)
      index += 2
    }

    let stack = NSStackView.column(rows, spacing: DashboardMetrics.overviewGap)
    stack.setCustomSpacing(10, after: heading)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: DashboardMetrics.overviewPadding),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -DashboardMetrics.overviewPadding),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 12),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -12),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  func apply(
    summaries: [ProviderSummary],
    selectedProvider: ProviderID?,
    menuBarProvider: ProviderID?,
    now: Date,
    selectProvider: @escaping (ProviderID) -> Void
  ) {
    self.selectProvider = selectProvider
    let countText = "\(summaries.count) \(summaries.count == 1 ? "provider" : "providers")"
    self.countLabel?.setDisplayedText(countText)
    for summary in summaries {
      guard let tile = self.tiles[summary.provider] else { continue }
      let selected = selectedProvider == summary.provider
      let pinned = menuBarProvider == summary.provider
      if !tile.apply(
        summary: summary, now: now, isSelected: selected, isPinnedForMenuBar: pinned)
      {
        self.replaceTile(
          summary: summary, now: now, isSelected: selected, isPinned: pinned,
          selectProvider: selectProvider)
      }
    }
  }

  private func replaceTile(
    summary: ProviderSummary,
    now: Date,
    isSelected: Bool,
    isPinned: Bool,
    selectProvider: @escaping (ProviderID) -> Void
  ) {
    guard let existing = self.tiles[summary.provider],
      let row = existing.superview as? NSStackView
    else { return }
    let tile = ProviderOverviewTile(
      summary: summary, now: now, isSelected: isSelected, isPinnedForMenuBar: isPinned,
      selectProvider: selectProvider)
    row.replaceArrangedSubview(existing, with: tile)
    self.tiles[summary.provider] = tile
    self.tileRebuildCount += 1
  }

  required init?(coder: NSCoder) { nil }
}

/// One glanceable provider tile. It navigates the detail panel; menu-bar pinning
/// remains a separate choice inside the detail panel.
@MainActor
final class ProviderOverviewTile: NSView, ReserveClockUpdating {
  private let provider: ProviderID
  private var isSelected: Bool
  private let selectProvider: (ProviderID) -> Void
  private var isHovered = false
  private var hoverTrackingArea: NSTrackingArea?
  private var spokenClock: ((Date) -> String)?
  private var valueLabel: ReserveLabel?
  private var meter: ReserveMeter?
  private var stateIcon: NSImageView?
  private var stateLabel: ReserveLabel?
  private var selectedMark: NSImageView?
  private var pinMark: NSImageView?
  private var showsMeter = false

  init(
    summary: ProviderSummary, now: Date, isSelected: Bool, isPinnedForMenuBar: Bool,
    selectProvider: @escaping (ProviderID) -> Void
  ) {
    self.provider = summary.provider
    self.isSelected = isSelected
    self.selectProvider = selectProvider
    super.init(frame: .zero)
    self.wantsLayer = true
    self.identifier = NSUserInterfaceItemIdentifier("provider-tile-\(summary.provider.rawValue)")
    self.toolTip = "Show \(summary.provider.displayName) details"
    self.setAccessibilityRole(.button)
    self.setAccessibilityLabel(
      "\(summary.provider.displayName) provider"
        + (isPinnedForMenuBar ? ", shown in the menu bar" : ""))
    self.setAccessibilityValue(ProviderDashboardCard.spokenState(summary: summary, now: now))
    self.setAccessibilityHelp("Shows \(summary.provider.displayName) details below")
    self.spokenClock = { date in
      ProviderDashboardCard.spokenState(summary: summary.at(date), now: date)
    }

    let logo = ProviderLogo(provider: summary.provider, size: 24, markSize: 14)
    let name = ReserveLabel(
      summary.provider.displayName,
      font: ReserveFont.sans(ReserveType.providerName, .semibold), color: ReserveColor.text
    ).flexible()
    let selectedMark = NSImageView(
      image: NSImage(
        systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil) ?? NSImage())
    selectedMark.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .semibold)
    selectedMark.contentTintColor = ReserveColor.accent
    selectedMark.setAccessibilityElement(false)
    selectedMark.setAccessibilityLabel("")
    selectedMark.isHidden = !isSelected
    selectedMark.translatesAutoresizingMaskIntoConstraints = false
    selectedMark.widthAnchor.constraint(equalToConstant: 14).isActive = true
    self.selectedMark = selectedMark
    let pin = NSImageView(
      image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil) ?? NSImage())
    pin.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    pin.contentTintColor = ReserveColor.muted
    pin.setAccessibilityElement(false)
    pin.setAccessibilityLabel("")
    pin.translatesAutoresizingMaskIntoConstraints = false
    pin.widthAnchor.constraint(equalToConstant: 11).isActive = true
    pin.identifier = NSUserInterfaceItemIdentifier("menu-bar-pin-\(summary.provider.rawValue)")
    pin.isHidden = !isPinnedForMenuBar
    self.pinMark = pin
    let identityViews: [NSView] = [logo, name, NSStackView.spacer(), pin, selectedMark]
    let identity = NSStackView.row(identityViews, spacing: 6)
    identity.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewTileContentWidth)
      .isActive = true

    let valueText: String
    let valueColor: NSColor
    if let primary = summary.primary {
      valueText =
        "\(DashboardFormat.remainingPercent(primary.remainingPercent))% "
        + (summary.paceState == .stale ? "last known" : "left")
      valueColor = summary.paceState == .stale ? ReserveColor.muted : ReserveColor.text
    } else if let usage = summary.localUsage, usage.origin == .providerAccount {
      valueText = "\(DashboardFormat.tokens(usage.todayTokens)) today"
      valueColor = ReserveColor.text
    } else {
      valueText = "Plan unavailable"
      valueColor = ReserveColor.muted
    }
    let value = ReserveLabel(
      valueText, font: ReserveFont.digits(ReserveType.summaryValue, .semibold), color: valueColor
    ).flexible()
    value.identifier = NSUserInterfaceItemIdentifier("tile-value-\(summary.provider.rawValue)")
    self.valueLabel = value

    var content: [NSView] = [identity, value]
    if let primary = summary.primary {
      let meter = ReserveMeter(
        remainingPercent: primary.remainingPercent,
        paceRemainingPercent: summary.paceState == .stale
          ? nil : primary.expectedPercent.map { 100 - $0 },
        label: "\(summary.provider.displayName) allowance remaining",
        color: summary.paceState.color, isStale: summary.paceState == .stale)
      meter.heightAnchor.constraint(equalToConstant: 5).isActive = true
      meter.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewTileContentWidth)
        .isActive = true
      self.meter = meter
      self.showsMeter = true
      content.append(meter)
    }

    let stateColor: NSColor = summary.setupAction == nil ? summary.paceState.color : ReserveColor.muted
    let stateText = summary.setupAction == nil ? summary.paceState.label : "Setup needed"
    let stateIcon = NSImageView(
      image: NSImage(
        systemSymbolName: summary.setupAction == nil ? summary.paceState.symbol : "person.crop.circle.badge.plus",
        accessibilityDescription: nil) ?? NSImage())
    stateIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    stateIcon.contentTintColor = stateColor
    stateIcon.setAccessibilityElement(false)
    stateIcon.setAccessibilityLabel("")
    stateIcon.translatesAutoresizingMaskIntoConstraints = false
    stateIcon.widthAnchor.constraint(equalToConstant: 11).isActive = true
    self.stateIcon = stateIcon
    let state = ReserveLabel(
      stateText, font: ReserveFont.sans(ReserveType.support, .medium), color: stateColor
    ).flexible()
    self.stateLabel = state
    let stateRow = NSStackView.row([stateIcon, state], spacing: 4)
    stateRow.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewTileContentWidth)
      .isActive = true
    content.append(stateRow)

    let stack = NSStackView.column(content, spacing: 7)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -10),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 10),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -10),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.overviewTileWidth),
      self.heightAnchor.constraint(equalToConstant: 112),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// Returns false when the tile would have to gain or lose its meter.
  func apply(
    summary: ProviderSummary, now: Date, isSelected: Bool, isPinnedForMenuBar: Bool
  ) -> Bool {
    let wantsMeter = summary.primary != nil
    guard wantsMeter == self.showsMeter else { return false }
    self.isSelected = isSelected
    self.pinMark?.isHidden = !isPinnedForMenuBar
    self.selectedMark?.isHidden = !isSelected
    let valueText: String
    let valueColor: NSColor
    if let primary = summary.primary {
      valueText =
        "\(DashboardFormat.remainingPercent(primary.remainingPercent))% "
        + (summary.paceState == .stale ? "last known" : "left")
      valueColor = summary.paceState == .stale ? ReserveColor.muted : ReserveColor.text
      self.meter?.applyReading(
        remainingPercent: primary.remainingPercent,
        paceRemainingPercent: summary.paceState == .stale
          ? nil : primary.expectedPercent.map { 100 - $0 },
        color: summary.paceState.color,
        isStale: summary.paceState == .stale)
    } else if let usage = summary.localUsage, usage.origin == .providerAccount {
      valueText = "\(DashboardFormat.tokens(usage.todayTokens)) today"
      valueColor = ReserveColor.text
    } else {
      valueText = "Plan unavailable"
      valueColor = ReserveColor.muted
    }
    self.valueLabel?.setDisplayedText(valueText, color: valueColor)
    let stateColor: NSColor = summary.setupAction == nil ? summary.paceState.color : ReserveColor.muted
    let stateText = summary.setupAction == nil ? summary.paceState.label : "Setup needed"
    self.stateLabel?.setDisplayedText(stateText, color: stateColor)
    self.stateIcon?.contentTintColor = stateColor
    self.stateIcon?.image = NSImage(
      systemSymbolName: summary.setupAction == nil
        ? summary.paceState.symbol : "person.crop.circle.badge.plus",
      accessibilityDescription: nil)
    self.setAccessibilityLabel(
      "\(summary.provider.displayName) provider"
        + (isPinnedForMenuBar ? ", shown in the menu bar" : ""))
    self.setAccessibilityValue(ProviderDashboardCard.spokenState(summary: summary, now: now))
    self.spokenClock = { date in
      ProviderDashboardCard.spokenState(summary: summary.at(date), now: date)
    }
    self.needsDisplay = true
    return true
  }

  func updateClock(_ now: Date) {
    if let spoken = self.spokenClock?(now) { self.setAccessibilityValue(spoken) }
  }

  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
  override var focusRingMaskBounds: NSRect { self.bounds }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(
      roundedRect: self.bounds, xRadius: ReserveRadius.control, yRadius: ReserveRadius.control)
    (self.isSelected ? ReserveColor.selected : self.isHovered ? ReserveColor.hover : ReserveColor.elevated)
      .setFill()
    path.fill()
    if self.isSelected {
      ReserveColor.accent.withAlphaComponent(0.72).setStroke()
      path.lineWidth = 1.5
      path.stroke()
    }
  }

  override func drawFocusRingMask() {
    NSBezierPath(
      roundedRect: self.bounds, xRadius: ReserveRadius.control, yRadius: ReserveRadius.control
    ).fill()
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    super.hitTest(point) == nil ? nil : self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
    self.selectProvider(self.provider)
  }

  override func keyDown(with event: NSEvent) {
    switch event.charactersIgnoringModifiers {
    case " ", "\r", "\u{3}": self.selectProvider(self.provider)
    default: super.keyDown(with: event)
    }
  }

  override func updateTrackingAreas() {
    if let hoverTrackingArea { self.removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: self.bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
    self.addTrackingArea(area)
    self.hoverTrackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    self.isHovered = true
    self.needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    self.isHovered = false
    self.needsDisplay = true
  }

  override func resetCursorRects() { self.addCursorRect(self.bounds, cursor: .pointingHand) }
}

/// The selected provider, rendered with the same anatomy regardless of how many
/// limit windows it exposes.
@MainActor
final class ProviderDashboardCard: NSView, ReserveClockUpdating {
  private let provider: ProviderID
  var providerID: ProviderID { self.provider }
  private let selectMenuBarProvider: (ProviderID) -> Void
  private let toggleDetail: (ProviderID) -> Void
  private var isSelectedForMenuBar: Bool
  private var hasUnavailableLiveData: Bool
  private let isExpanded: Bool
  private let showsDisclosure: Bool
  private var renderedStructure = ""
  private var isHovered = false
  private var hoverTrackingArea: NSTrackingArea?
  private var spokenClock: ((Date) -> String)?
  private(set) var regionRebuildCount = 0

  init(
    summary: ProviderSummary,
    now: Date,
    isSelectedForMenuBar: Bool,
    isExpanded: Bool = false,
    showsDisclosure: Bool = true,
    connectProvider: @escaping (ProviderID) -> Void,
    selectMenuBarProvider: @escaping (ProviderID) -> Void,
    toggleDetail: @escaping (ProviderID) -> Void = { _ in }
  ) {
    self.provider = summary.provider
    self.selectMenuBarProvider = selectMenuBarProvider
    self.toggleDetail = toggleDetail
    self.isSelectedForMenuBar = isSelectedForMenuBar
    self.hasUnavailableLiveData = summary.paceState == .stale
    self.isExpanded = isExpanded
    self.showsDisclosure = showsDisclosure
    super.init(frame: .zero)
    self.wantsLayer = true
    self.toolTip =
      isSelectedForMenuBar
      ? "Shown in menu bar"
      : "Click to show \(summary.provider.displayName) in the menu bar"
    self.setAccessibilityRole(.button)
    let accessibleName = [summary.provider.displayName, summary.planName]
      .filter { !$0.isEmpty }.joined(separator: " ")
    self.setAccessibilityLabel(
      accessibleName + (isSelectedForMenuBar ? ", shown in the menu bar" : ""))
    self.setAccessibilityValue(Self.spokenState(summary: summary, now: now))
    self.spokenClock = { date in Self.spokenState(summary: summary.at(date), now: date) }
    self.setAccessibilityHelp(
      "Space shows this provider in the menu bar. Return shows its limits and usage.")

    var rows: [NSView] = [
      Self.identityRow(
        summary: summary, isSelectedForMenuBar: isSelectedForMenuBar,
        isExpanded: isExpanded, showsDisclosure: showsDisclosure,
        connectProvider: connectProvider, toggleDetail: toggleDetail)
    ]
    if isExpanded {
      rows.append(
        Self.menuBarProviderRow(
          summary: summary, isSelected: isSelectedForMenuBar,
          selectMenuBarProvider: selectMenuBarProvider))
    }
    if self.hasUnavailableLiveData {
      rows.append(ProviderFreshnessBanner(summary: summary, now: now))
    }
    if let primary = summary.primary {
      rows.append(
        AllowanceView(
          allowance: primary, paceState: summary.paceState,
          lastUpdated: summary.lastUpdated, now: now,
          showsForecast: DashboardFormat.showsForecast(primary, paceState: summary.paceState,
            observationTimeKnown: summary.observationTimeKnown)))
    } else {
      rows.append(Self.unavailableRow(summary: summary))
    }
    if summary.serviceIsExceptional, let service = summary.serviceStatus {
      rows.append(ServiceBanner(provider: summary.provider, status: service))
    }
    var secondary = summary.secondary.filter { isExpanded || !$0.isComponentShare }
    if ProviderDescriptor.forProvider(summary.provider).capabilities.contains(.limitMeters) {
      // Each plan limit gets its own meter; component shares stay compact.
      for allowance in secondary where !allowance.isComponentShare {
        let meter = AllowanceView(
          allowance: allowance, paceState: allowance.paceState,
          lastUpdated: summary.lastUpdated, now: now, isDetail: true, showsForecast: false)
        meter.identifier = NSUserInterfaceItemIdentifier("secondary-\(allowance.id)")
        rows.append(meter)
      }
      secondary.removeAll { !$0.isComponentShare }
    }
    if !secondary.isEmpty {
      rows.append(
        SecondaryAllowanceRow(
          allowances: secondary, primaryReset: summary.primary?.resetsAt, now: now))
    }
    if isExpanded {
      rows.append(ReserveHairline(width: DashboardMetrics.cardContentWidth))
      rows.append(UsageDetailGrid(summary: summary, now: now))
    }

    let stack = NSStackView.column(rows, spacing: DashboardMetrics.cardRowGap)
    stack.setCustomSpacing(DashboardMetrics.identityGap, after: rows[0])
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(
        equalTo: self.leadingAnchor, constant: DashboardMetrics.cardPadding),
      stack.trailingAnchor.constraint(
        equalTo: self.trailingAnchor, constant: -DashboardMetrics.cardPadding),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: DashboardMetrics.cardPadding),
      stack.bottomAnchor.constraint(
        equalTo: self.bottomAnchor, constant: -DashboardMetrics.cardPadding),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
    self.renderedStructure = Self.structureKey(
      summary: summary, isExpanded: isExpanded, showsDisclosure: showsDisclosure)
  }

  /// Keeps this card when the controls on it are the same. Percentages, pace
  /// copy, and the refresh clock update in place.
  func apply(summary: ProviderSummary, now: Date, isSelectedForMenuBar: Bool) -> Bool {
    let key = Self.structureKey(
      summary: summary, isExpanded: self.isExpanded, showsDisclosure: self.showsDisclosure)
    guard key == self.renderedStructure else { return false }
    self.isSelectedForMenuBar = isSelectedForMenuBar
    self.hasUnavailableLiveData = summary.paceState == .stale
    let accessibleName = [summary.provider.displayName, summary.planName]
      .filter { !$0.isEmpty }.joined(separator: " ")
    self.setAccessibilityLabel(
      accessibleName + (isSelectedForMenuBar ? ", shown in the menu bar" : ""))
    self.setAccessibilityValue(Self.spokenState(summary: summary, now: now))
    self.spokenClock = { date in Self.spokenState(summary: summary.at(date), now: date) }
    self.toolTip = isSelectedForMenuBar
      ? "Shown in menu bar"
      : "Click to show \(summary.provider.displayName) in the menu bar"
    let providerName = [summary.provider.displayName, summary.planName]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    (self.control(id: "provider-name-\(summary.provider.rawValue)") as? ReserveLabel)?
      .setDisplayedText(providerName)
    self.control(id: "menu-bar-pin-\(summary.provider.rawValue)")?.isHidden = !isSelectedForMenuBar
    if let primary = summary.primary {
      (self.control(id: "remaining-\(summary.provider.rawValue)") as? RemainingValueView)?
        .apply(allowance: primary, paceState: summary.paceState)
    }
    for allowance in summary.allowances {
      let meter = (self.control(id: "allowance-\(allowance.id)") as? AllowanceView)
        ?? (self.control(id: "allowance-detail-\(allowance.id)") as? AllowanceView)
        ?? (self.control(id: "secondary-\(allowance.id)") as? AllowanceView)
      meter?.apply(
        allowance: allowance, paceState: allowance.isPrimary ? summary.paceState : allowance.paceState,
        lastUpdated: summary.lastUpdated, now: now)
      (self.control(id: "secondary-\(allowance.id)") as? SecondaryAllowanceLine)?
        .apply(allowance: allowance, primaryReset: summary.primary?.resetsAt, now: now)
    }
    (self.control(id: "freshness-\(summary.provider.rawValue)") as? ProviderFreshnessBanner)?
      .apply(summary: summary, now: now)
    if let grid = self.control(id: "usage-detail-\(summary.provider.rawValue)") as? UsageDetailGrid,
      !grid.apply(summary: summary, now: now), let stack = grid.superview as? NSStackView
    {
      let replacement = UsageDetailGrid(summary: summary, now: now)
      stack.replaceArrangedSubview(grid, with: replacement)
      self.regionRebuildCount += 1
    }
    if let pinButton = self.control(id: "pin-menu-bar-\(summary.provider.rawValue)") as? NSButton {
      pinButton.title = isSelectedForMenuBar ? "Pinned" : "Pin \(summary.provider.displayName)"
      pinButton.toolTip = isSelectedForMenuBar
        ? "\(summary.provider.displayName) is shown in the menu bar"
        : "Show \(summary.provider.displayName) in the menu bar"
      pinButton.setAccessibilityLabel(pinButton.toolTip)
      pinButton.isEnabled = !isSelectedForMenuBar
    }
    self.needsDisplay = true
    return true
  }

  private func control(id: String) -> NSView? {
    Self.walk(self).first { $0.identifier?.rawValue == id }
  }

  private static func walk(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { walk($0) }
  }

  static func structureKey(
    summary: ProviderSummary, isExpanded: Bool, showsDisclosure: Bool
  ) -> String {
    let secondary = summary.secondary.filter { isExpanded || !$0.isComponentShare }
    let primaryReset = summary.primary?.resetsAt
    let secondaryStructure = secondary.map { allowance -> String in
      let sharesPrimaryReset: Bool
      if let reset = allowance.resetsAt, let primaryReset {
        sharesPrimaryReset = abs(primaryReset.timeIntervalSince(reset)) < 1
      } else {
        sharesPrimaryReset = false
      }
      return "\(allowance.id):\(allowance.isComponentShare):\(sharesPrimaryReset)"
    }.joined(separator: ",")
    var parts: [String] = []
    parts.append(summary.provider.rawValue)
    parts.append(isExpanded ? "open" : "closed")
    parts.append(showsDisclosure ? "disclose" : "flat")
    parts.append(summary.primary?.id ?? "-")
    parts.append(summary.allowances.map(\.id).joined(separator: ","))
    parts.append(summary.paceState == .stale ? "stale" : "live")
    if summary.serviceIsExceptional {
      let serviceParts: [String] = [
        summary.serviceStatus?.health.rawValue ?? "service",
        summary.serviceStatus?.detail ?? "",
        summary.serviceStatus?.pageURL.absoluteString ?? "",
        summary.serviceStatus?.notices?.joined(separator: "\u{2}") ?? "",
      ]
      parts.append(serviceParts.joined(separator: "\u{3}"))
    } else {
      parts.append("-")
    }
    parts.append(summary.setupAction?.buttonTitle ?? "-")
    parts.append(summary.needsConnection ? "needs-connection" : "connected")
    parts.append(summary.requiresKeychainAccess ? "keychain" : "no-keychain")
    parts.append(summary.usageAccessDenied ? "access-denied" : "access-ok")
    parts.append(summary.signInCouldNotStart ? "signin-failed" : "signin-ok")
    parts.append(summary.isConnecting ? "connecting" : "not-connecting")
    parts.append(summary.error ?? "-")
    let localUsageKind: String
    if let usage = summary.localUsage {
      localUsageKind = usage.origin == .providerAccount ? "account" : "local"
    } else {
      localUsageKind = "no-local"
    }
    parts.append(localUsageKind)
    parts.append(secondaryStructure)
    parts.append(summary.details.map(\.label).joined(separator: ","))
    if let primary = summary.primary {
      let forecast = DashboardFormat.showsForecast(
        primary, paceState: summary.paceState,
        observationTimeKnown: summary.observationTimeKnown)
      parts.append(forecast ? "forecast" : "no-forecast")
    }
    if isExpanded {
      parts.append(summary.subscriptionCostUSD == nil ? "-" : "cost")
      parts.append(summary.billingRenewsAt == nil ? "-" : "bill")
      parts.append(summary.includedSpend == nil ? "-" : "spend")
      parts.append(summary.localUsage?.dailyTokens.contains { $0.tokens > 0 } == true ? "chart" : "-")
      parts.append(summary.historyPossible ? "hist" : "-")
      parts.append(summary.localHistoryError == nil ? "-" : "hist-err")
    }
    return parts.joined(separator: "\u{1}")
  }

  required init?(coder: NSCoder) { nil }

  func updateClock(_ now: Date) {
    if let spoken = self.spokenClock?(now) { self.setAccessibilityValue(spoken) }
  }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(
      roundedRect: self.bounds, xRadius: ReserveRadius.section, yRadius: ReserveRadius.section)
    (self.hasUnavailableLiveData
      ? ReserveColor.staleSurface
      : self.isHovered ? ReserveColor.hover : ReserveColor.section
    ).setFill()
    path.fill()
    if self.hasUnavailableLiveData {
      ReserveColor.staleBorder.setStroke()
      path.lineWidth = 1
      path.stroke()
    }
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let hit = super.hitTest(point) else { return nil }
    var view: NSView? = hit
    while let current = view, current !== self {
      if current is NSButton { return hit }
      view = current.superview
    }
    return self
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

  override func updateTrackingAreas() {
    if let hoverTrackingArea { self.removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: self.bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: nil)
    self.addTrackingArea(area)
    self.hoverTrackingArea = area
    super.updateTrackingAreas()
  }

  override func mouseEntered(with event: NSEvent) {
    self.isHovered = true
    self.needsDisplay = true
  }

  override func mouseExited(with event: NSEvent) {
    self.isHovered = false
    self.needsDisplay = true
  }

  // MARK: Keyboard

  override var acceptsFirstResponder: Bool { true }
  override var canBecomeKeyView: Bool { true }
  override var focusRingMaskBounds: NSRect { self.bounds }

  override func drawFocusRingMask() {
    NSBezierPath(
      roundedRect: self.bounds, xRadius: ReserveRadius.section, yRadius: ReserveRadius.section
    ).fill()
  }

  override func becomeFirstResponder() -> Bool {
    self.needsDisplay = true
    return true
  }

  override func resignFirstResponder() -> Bool {
    self.needsDisplay = true
    return true
  }

  override func keyDown(with event: NSEvent) {
    switch event.charactersIgnoringModifiers {
    case " ":
      self.selectForMenuBar()
    case "\r", "\u{3}":
      self.toggleDetail(self.provider)
    default:
      super.keyDown(with: event)
    }
  }

  /// What VoiceOver reads for the row: capacity, health, reset and forecast in
  /// the order someone would ask for them.
  static func spokenState(summary: ProviderSummary, now: Date) -> String {
    guard let primary = summary.primary else {
      if let usage = summary.localUsage, usage.origin == .providerAccount {
        let today = DashboardFormat.tokens(usage.todayTokens)
        let cycle = DashboardFormat.tokens(usage.cycleTokens)
        return "\(today) account tokens today, \(cycle) this billing cycle, plan percentage unavailable"
      }
      return summary.error ?? "Not connected"
    }
    var parts = [
      "\(DashboardFormat.remainingPercent(primary.remainingPercent)) percent \(summary.paceState == .stale ? "last known" : "left")",
      summary.paceState.label,
    ]
    if summary.paceState == .stale, let updated = summary.lastUpdated {
      parts.append(DashboardFormat.updated(updated, now: now))
    }
    if let reset = primary.resetsAt, reset > now {
      parts.append("\(primary.title) resets \(DashboardFormat.moment(reset, now: now))")
    }
    if DashboardFormat.showsForecast(primary, paceState: summary.paceState,
      observationTimeKnown: summary.observationTimeKnown)
    {
      parts.append(DashboardFormat.forecast(
        primary, paceState: summary.paceState, lastUpdated: summary.lastUpdated, now: now))
    }
    if summary.serviceIsExceptional, let service = summary.serviceStatus {
      parts.append("\(summary.provider.displayName) is reporting \(service.health.displayName)")
    }
    return parts.joined(separator: ", ")
  }

  override func mouseDown(with event: NSEvent) {
    guard self.bounds.contains(self.convert(event.locationInWindow, from: nil)) else { return }
    self.selectForMenuBar()
  }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  func selectForMenuBar() {
    self.selectMenuBarProvider(self.provider)
  }

  private static func identityRow(
    summary: ProviderSummary,
    isSelectedForMenuBar: Bool,
    isExpanded: Bool,
    showsDisclosure: Bool,
    connectProvider: @escaping (ProviderID) -> Void,
    toggleDetail: @escaping (ProviderID) -> Void
  ) -> NSView {
    let logo = ProviderLogo(provider: summary.provider)
    let providerName = [summary.provider.displayName, summary.planName]
      .filter { !$0.isEmpty }.joined(separator: " · ")
    let name = ReserveLabel(
      providerName,
      font: ReserveFont.sans(ReserveType.providerName, .semibold),
      color: ReserveColor.text
    ).flexible()
    name.identifier = NSUserInterfaceItemIdentifier("provider-name-\(summary.provider.rawValue)")
    name.toolTip = summary.planName.isEmpty
      ? summary.provider.displayName : "\(summary.provider.displayName) · \(summary.planName)"

    // The pin stays in the row and hides when this provider is not the menu-bar
    // choice, so pinning does not rebuild the card.
    let pin = NSImageView(
      image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Shown in menu bar")
        ?? NSImage())
    pin.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    pin.contentTintColor = ReserveColor.accent
    pin.toolTip = "Shown in menu bar"
    pin.setAccessibilityElement(false)
    pin.setAccessibilityLabel("")
    pin.translatesAutoresizingMaskIntoConstraints = false
    pin.widthAnchor.constraint(equalToConstant: 12).isActive = true
    pin.identifier = NSUserInterfaceItemIdentifier("menu-bar-pin-\(summary.provider.rawValue)")
    pin.isHidden = !isSelectedForMenuBar
    let identity: [NSView] = [logo, name, pin]

    let trailing: NSView
    if let setupAction = summary.setupAction,
      !summary.isConnecting
    {
      // Setup is not capacity risk. Orange is reserved for an allowance that
      // may run out, so a setup action takes the ordinary accent.
      let connect = ReserveTextButton(
        title: setupAction.buttonTitle,
        size: ReserveType.metadata, color: ReserveColor.accent, filled: true,
        minimumWidth: 64, height: 24,
        action: { connectProvider(summary.provider) })
      connect.identifier = NSUserInterfaceItemIdentifier("connect-\(summary.provider.rawValue)")
      connect.toolTip = setupAction.toolTip(for: summary.provider)
      trailing = connect
    } else if let primary = summary.primary {
      let remaining = RemainingValueView(allowance: primary, paceState: summary.paceState)
      remaining.identifier = NSUserInterfaceItemIdentifier("remaining-\(summary.provider.rawValue)")
      trailing = remaining
    } else if let usage = summary.localUsage, usage.origin == .providerAccount {
      let today = DashboardFormat.tokens(usage.todayTokens)
      let value = ReserveLabel(
        "\(today) today",
        font: ReserveFont.sans(ReserveType.body, .semibold), color: ReserveColor.text
      ).fitted()
      value.toolTip = "Provider-reported account tokens today"
      value.setAccessibilityLabel("\(today) account tokens today")
      trailing = value
    } else {
      trailing = HealthBadge(paceState: summary.paceState)
    }
    trailing.setContentHuggingPriority(.required, for: .horizontal)
    trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

    var rowViews = identity + [NSStackView.spacer(), trailing]
    if showsDisclosure {
      rowViews.append(
        DetailDisclosureButton(
          provider: summary.provider, isExpanded: isExpanded, action: toggleDetail))
    }
    let row = NSStackView.row(rowViews, spacing: 9)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }

  private static func unavailableRow(summary: ProviderSummary) -> NSView {
    let message: String
    if summary.isConnecting && summary.requiresKeychainAccess {
      message = "Waiting for macOS permission…"
    } else if summary.isConnecting {
      message = "Complete the sign-in in your browser"
    } else if summary.signInCouldNotStart, summary.setupAction == .signIn {
      // The generic "Sign in to…" would invite the same failed launch. The
      // specific reason stays in the tooltip below.
      message = "Sign-in could not start. Reopen Reserve."
    } else if let setupAction = summary.setupAction {
      message = setupAction.message(for: summary.provider)
    } else if summary.needsConnection && summary.localUsage != nil {
      message = "Plan limits unavailable · local activity available"
    } else if let usage = summary.localUsage, usage.origin == .providerAccount {
      message = "\(DashboardFormat.tokens(usage.cycleTokens)) this billing cycle · percentage unavailable"
    } else {
      message = summary.error ?? "Sign in to read plan limits"
    }
    // Setup and permission guidance is neutral. Only an allowance that may run
    // out or is out earns the deficit colour, and this row never carries one.
    let label = ReserveLabel(
      message, font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.muted
    ).flexible()
    label.toolTip = summary.error ?? message
    let row = NSStackView.row([label], spacing: 0)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }

  private static func menuBarProviderRow(
    summary: ProviderSummary,
    isSelected: Bool,
    selectMenuBarProvider: @escaping (ProviderID) -> Void
  ) -> NSView {
    let label = ReserveLabel(
      "Menu bar provider",
      font: ReserveFont.sans(ReserveType.metadata, .medium), color: ReserveColor.muted
    ).flexible()
    let button = ReserveTextButton(
      title: isSelected ? "Pinned" : "Pin \(summary.provider.displayName)",
      symbol: isSelected ? "pin.fill" : "pin",
      size: ReserveType.metadata,
      color: isSelected ? ReserveColor.muted : ReserveColor.accent,
      filled: !isSelected,
      minimumWidth: 82,
      height: 24,
      action: { selectMenuBarProvider(summary.provider) })
    button.identifier = NSUserInterfaceItemIdentifier(
      "pin-menu-bar-\(summary.provider.rawValue)")
    button.toolTip = isSelected
      ? "\(summary.provider.displayName) is shown in the menu bar"
      : "Show \(summary.provider.displayName) in the menu bar"
    button.setAccessibilityLabel(button.toolTip)
    button.isEnabled = !isSelected
    let row = NSStackView.row([label, NSStackView.spacer(), button], spacing: 8)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }
}

/// Makes cached or missing provider data impossible to mistake for a live
/// reading. The detailed error remains available as a tooltip.
@MainActor
private final class ProviderFreshnessBanner: NSView, ReserveClockUpdating {
  private var spokenClock: ((Date) -> String)?
  private var messageLabel: ReserveLabel?

  init(summary: ProviderSummary, now: Date) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("freshness-\(summary.provider.rawValue)")
    let (state, fullState) = Self.stateWords(for: summary)
    let age = summary.lastUpdated.map {
      "last checked \(Self.compactAge(since: $0, now: now))"
    } ?? "not checked yet"
    let fullAge = summary.lastUpdated.map {
      DashboardFormat.updated($0, now: now).replacingOccurrences(
        of: "Updated", with: "last updated")
    } ?? "never updated"
    let message = "\(state) · \(age)"
    let fullMessage = "\(fullState) · \(fullAge)"

    let icon = NSImageView(
      image: NSImage(
        systemSymbolName: "clock.badge.exclamationmark", accessibilityDescription: nil)
        ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    icon.contentTintColor = ReserveColor.muted
    icon.setAccessibilityElement(false)
    let label = ReserveLabel(
      message, font: ReserveFont.sans(ReserveType.metadata, .medium), color: ReserveColor.muted
    ).flexible()
    label.clockText = { date in
      let age = summary.lastUpdated.map {
        "last checked \(Self.compactAge(since: $0, now: date))"
      } ?? "not checked yet"
      return "\(state) · \(age)"
    }
    self.spokenClock = { date in
      let age = summary.lastUpdated.map {
        DashboardFormat.updated($0, now: date).replacingOccurrences(of: "Updated", with: "last updated")
      } ?? "never updated"
      return "\(fullState) · \(age)"
    }
    label.identifier = NSUserInterfaceItemIdentifier(
      "freshness-label-\(summary.provider.rawValue)")
    self.messageLabel = label
    self.toolTip = summary.error ?? fullMessage
    self.setAccessibilityLabel(fullMessage)

    let row = NSStackView.row([icon, label], spacing: 6)
    icon.widthAnchor.constraint(equalToConstant: 12).isActive = true
    label.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth - 18).isActive = true
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: self.topAnchor),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  func apply(summary: ProviderSummary, now: Date) {
    let (stateWord, fullStateWord) = Self.stateWords(for: summary)
    let age = summary.lastUpdated.map {
      "last checked \(Self.compactAge(since: $0, now: now))"
    } ?? "not checked yet"
    let fullAge = summary.lastUpdated.map {
      DashboardFormat.updated($0, now: now).replacingOccurrences(of: "Updated", with: "last updated")
    } ?? "never updated"
    self.messageLabel?.setDisplayedText("\(stateWord) · \(age)")
    let lastUpdated = summary.lastUpdated
    self.messageLabel?.clockText = { date in
      let age = lastUpdated.map {
        "last checked \(Self.compactAge(since: $0, now: date))"
      } ?? "not checked yet"
      return "\(stateWord) · \(age)"
    }
    self.spokenClock = { date in
      let age = lastUpdated.map {
        DashboardFormat.updated($0, now: date).replacingOccurrences(
          of: "Updated", with: "last updated")
      } ?? "never updated"
      return "\(fullStateWord) · \(age)"
    }
    let fullMessage = "\(fullStateWord) · \(fullAge)"
    self.toolTip = summary.error ?? fullMessage
    self.setAccessibilityLabel(fullMessage)
  }

  func updateClock(_ now: Date) {
    if let spoken = self.spokenClock?(now) { self.setAccessibilityLabel(spoken) }
  }

  private static func compactAge(since date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "just now" }
    if seconds < 3_600 { return "\(Int(seconds / 60))m ago" }
    return "\(Int(seconds / 3_600))h ago"
  }

  private static func stateWords(for summary: ProviderSummary) -> (String, String) {
    if summary.setupAction == .install { return ("Setup needed", "Setup needed") }
    if summary.setupAction == .update { return ("Update needed", "Update needed") }
    if summary.usageAccessDenied { return ("Usage access denied", "Usage access denied") }
    if summary.requiresKeychainAccess { return ("Waiting for permission", "Waiting for permission") }
    if summary.setupAction == .addKey { return ("API key needed", "API key needed") }
    if summary.signInCouldNotStart { return ("Sign-in could not start", "Sign-in could not start") }
    if summary.needsConnection { return ("Sign-in needed", "Sign-in needed") }
    if summary.error != nil { return ("Usage unavailable", "Usage temporarily unavailable") }
    return ("Cached", "Cached data")
  }
}

/// "80% left" — every percentage states what it measures.
@MainActor
private final class RemainingValueView: NSView {
  private var valueLabel: ReserveLabel?
  private var unitLabel: ReserveLabel?

  init(allowance: Allowance, paceState: UsagePaceState) {
    super.init(frame: .zero)
    let percentage = DashboardFormat.remainingPercent(allowance.remainingPercent)
    let value = ReserveLabel(
      "\(percentage)%",
      font: ReserveFont.digits(ReserveType.remaining, .semibold),
      color: paceState == .stale ? ReserveColor.muted : ReserveColor.text
    ).fitted()
    let unit = ReserveLabel(
      paceState == .stale ? "last known" : "left",
      font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).fitted()
    value.setAccessibilityLabel(
      "\(percentage) percent \(paceState == .stale ? "last known" : "left"), \(paceState.label)")
    self.valueLabel = value
    self.unitLabel = unit
    let row = NSStackView.row([value, unit], spacing: 5)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: self.topAnchor),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
    ])
  }

  func apply(allowance: Allowance, paceState: UsagePaceState) {
    let percentage = DashboardFormat.remainingPercent(allowance.remainingPercent)
    let stale = paceState == .stale
    self.valueLabel?.setDisplayedText(
      "\(percentage)%", color: stale ? ReserveColor.muted : ReserveColor.text)
    self.valueLabel?.setAccessibilityLabel(
      "\(percentage) percent \(stale ? "last known" : "left"), \(paceState.label)")
    self.unitLabel?.setDisplayedText(stale ? "last known" : "left")
  }

  required init?(coder: NSCoder) { nil }
}

/// Exceptions get a badge; healthy states stay silent.
@MainActor
private final class HealthBadge: ReserveSurface {
  init(paceState: UsagePaceState) {
    super.init(fill: paceState.color, fillAlpha: 0.16, radius: ReserveRadius.chip)
    let icon = NSImageView(
      image: NSImage(systemSymbolName: paceState.symbol, accessibilityDescription: nil) ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    icon.contentTintColor = paceState.color
    icon.setAccessibilityElement(false)
    icon.setAccessibilityLabel("")
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 11).isActive = true
    let label = ReserveLabel(
      paceState.label, font: ReserveFont.sans(ReserveType.metadata, .medium), color: paceState.color
    ).fitted()
    let row = NSStackView.row([icon, label], spacing: 4)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.setAccessibilityLabel(paceState.label)
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 7),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.heightAnchor.constraint(equalToConstant: 19),
    ])
    self.setContentHuggingPriority(.required, for: .horizontal)
  }

  required init?(coder: NSCoder) { nil }
}

/// Provider availability, shown only when it is not normal.
@MainActor
private final class ServiceBanner: ReserveSurface {
  init(provider: ProviderID, status: ProviderServiceStatus) {
    let color: NSColor =
      switch status.health {
      case .outage: ReserveColor.danger
      case .degraded: ReserveColor.warning
      default: ReserveColor.muted
      }
    super.init(fill: color, fillAlpha: 0.13, radius: ReserveRadius.chip)
    let icon = NSImageView(
      image: NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: nil)
        ?? NSImage())
    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    icon.contentTintColor = color
    icon.setAccessibilityElement(false)
    icon.setAccessibilityLabel("")
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 14).isActive = true
    let text =
      "\(provider.displayName) is reporting \(status.health.displayName.lowercased()) service"
    let label = ReserveLabel(
      text, font: ReserveFont.sans(ReserveType.metadata, .medium), color: color
    ).flexible()
    label.toolTip = status.detail
    let open = ReserveTextButton(
      title: "Details", size: ReserveType.metadata, color: color, minimumWidth: 56, height: 22,
      action: { NSWorkspace.shared.open(status.pageURL) })
    open.identifier = NSUserInterfaceItemIdentifier("status-\(provider.rawValue)")
    open.toolTip = "Open the official \(provider.displayName) status page"
    let row = NSStackView.row([icon, label, NSStackView.spacer(), open], spacing: 7)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 9),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -8),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.heightAnchor.constraint(equalToConstant: 30),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

/// The limit window component: title, reset, bar, and one plain-English forecast.
@MainActor
private final class AllowanceView: NSView {
  private var captionLabel: ReserveLabel?
  private var meterView: ReserveMeter?
  private var forecastLabel: ReserveLabel?
  private var detailValueLabel: ReserveLabel?
  private var isDetail = false

  init(
    allowance: Allowance,
    paceState: UsagePaceState,
    lastUpdated: Date?,
    now: Date,
    isDetail: Bool = false,
    showsForecast: Bool = true
  ) {
    super.init(frame: .zero)
    self.isDetail = isDetail
    self.identifier = NSUserInterfaceItemIdentifier(
      isDetail ? "allowance-detail-\(allowance.id)" : "allowance-\(allowance.id)")

    var header: [NSView] = []
    if isDetail {
      // Quota surfaces always speak in remaining capacity. Providers may
      // report usage internally, but Reserve presents what is left.
      let title = ReserveLabel(
        allowance.title, font: ReserveFont.sans(ReserveType.body, .medium),
        color: ReserveColor.text
      ).flexible()
      let left = ReserveLabel(
        "\(DashboardFormat.remainingPercent(allowance.remainingPercent))% left",
        font: ReserveFont.digits(ReserveType.body, .semibold), color: ReserveColor.text
      ).fitted()
      self.detailValueLabel = left
      header = [NSStackView.row([title, NSStackView.spacer(), left], spacing: 8)]
    }

    let captionText =
      isDetail
      ? DashboardFormat.resetLine(allowance, now: now)
      : DashboardFormat.limitLine(allowance, now: now)
    let caption = ReserveLabel(
      captionText,
      font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.muted
    ).flexible()
    caption.toolTip = captionText
    self.captionLabel = caption
    caption.clockText = { date in isDetail ? DashboardFormat.resetLine(allowance, now: date) : DashboardFormat.limitLine(allowance, now: date) }

    let meter = ReserveMeter(
      remainingPercent: allowance.remainingPercent,
      paceRemainingPercent: paceState == .stale ? nil : allowance.expectedPercent.map { 100 - $0 },
      label: allowance.title,
      color: paceState.color, isStale: paceState == .stale)
    meter.clockPresentation = { date in
      let window = UsageWindow(id: allowance.id, label: allowance.title,
        usedPercent: allowance.usedPercent, windowMinutes: allowance.windowMinutes, resetsAt: allowance.resetsAt)
      let state = UsagePaceState.calculate(for: window, fetchedAt: lastUpdated,
        hasError: paceState == .stale, now: date)
      let projection = state == .stale ? nil : UsagePaceProjection.calculate(for: window, now: date)
      return (projection.map { 100 - $0.elapsedPercent }, state == .stale)
    }
    meter.heightAnchor.constraint(equalToConstant: DashboardMetrics.meterHeight).isActive = true
    meter.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    self.meterView = meter

    let forecast = ReserveLabel(
      DashboardFormat.forecast(
        allowance, paceState: paceState, lastUpdated: lastUpdated, now: now),
      font: ReserveFont.sans(ReserveType.body),
      color: paceState == .exhausted || paceState.deficitPercent != nil
        ? paceState.color : ReserveColor.muted
    ).flexible()
    forecast.clockText = { date in
      let window = UsageWindow(id: allowance.id, label: allowance.title,
        usedPercent: allowance.usedPercent, windowMinutes: allowance.windowMinutes, resetsAt: allowance.resetsAt)
      var current = allowance
      current.projection = paceState == .stale ? nil : UsagePaceProjection.calculate(for: window, now: date)
      let state = UsagePaceState.calculate(for: window, fetchedAt: lastUpdated, hasError: paceState == .stale, now: date)
      return DashboardFormat.forecast(current, paceState: state, lastUpdated: lastUpdated, now: date)
    }
    forecast.identifier = NSUserInterfaceItemIdentifier("forecast")
    self.forecastLabel = forecast
    forecast.toolTip = DashboardFormat.forecast(
      allowance, paceState: paceState, lastUpdated: lastUpdated, now: now)

    let stack = NSStackView.column(header + [caption, meter] + (showsForecast ? [forecast] : []), spacing: 8)
    if showsForecast { stack.setCustomSpacing(9, after: meter) }
    if let first = header.first { stack.setCustomSpacing(6, after: first) }
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  func apply(allowance: Allowance, paceState: UsagePaceState, lastUpdated: Date?, now: Date) {
    let captionText = self.isDetail
      ? DashboardFormat.resetLine(allowance, now: now)
      : DashboardFormat.limitLine(allowance, now: now)
    self.captionLabel?.setDisplayedText(captionText)
    let isDetail = self.isDetail
    self.captionLabel?.clockText = { date in
      isDetail
        ? DashboardFormat.resetLine(allowance, now: date)
        : DashboardFormat.limitLine(allowance, now: date)
    }
    self.detailValueLabel?.setDisplayedText(
      "\(DashboardFormat.remainingPercent(allowance.remainingPercent))% left")
    self.meterView?.applyReading(
      remainingPercent: allowance.remainingPercent,
      paceRemainingPercent: paceState == .stale ? nil : allowance.expectedPercent.map { 100 - $0 },
      color: paceState.color,
      isStale: paceState == .stale)
    self.meterView?.clockPresentation = { date in
      let window = UsageWindow(
        id: allowance.id, label: allowance.title, usedPercent: allowance.usedPercent,
        windowMinutes: allowance.windowMinutes, resetsAt: allowance.resetsAt)
      let state = UsagePaceState.calculate(
        for: window, fetchedAt: lastUpdated, hasError: paceState == .stale, now: date)
      let projection = state == .stale ? nil : UsagePaceProjection.calculate(for: window, now: date)
      return (projection.map { 100 - $0.elapsedPercent }, state == .stale)
    }
    let forecastText = DashboardFormat.forecast(
      allowance, paceState: paceState, lastUpdated: lastUpdated, now: now)
    let forecastColor = paceState == .exhausted || paceState.deficitPercent != nil
      ? paceState.color : ReserveColor.muted
    self.forecastLabel?.setDisplayedText(forecastText, color: forecastColor)
    self.forecastLabel?.clockText = { date in
      let window = UsageWindow(
        id: allowance.id, label: allowance.title, usedPercent: allowance.usedPercent,
        windowMinutes: allowance.windowMinutes, resetsAt: allowance.resetsAt)
      var current = allowance
      current.projection = paceState == .stale
        ? nil : UsagePaceProjection.calculate(for: window, now: date)
      let state = UsagePaceState.calculate(
        for: window, fetchedAt: lastUpdated, hasError: paceState == .stale, now: date)
      return DashboardFormat.forecast(current, paceState: state, lastUpdated: lastUpdated, now: date)
    }
  }

  required init?(coder: NSCoder) { nil }
}

/// Additional windows, compacted to one line each.
@MainActor
private final class SecondaryAllowanceRow: NSView {
  init(allowances: [Allowance], primaryReset: Date?, now: Date) {
    super.init(frame: .zero)
    let lines = allowances.map {
      SecondaryAllowanceLine(allowance: $0, primaryReset: primaryReset, now: now)
    }
    let stack = NSStackView.column(lines, spacing: 5)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class SecondaryAllowanceLine: NSView {
  private let titleLabel: ReserveLabel
  private let valueLabel: ReserveLabel
  private var detailLabel: ReserveLabel?

  init(allowance: Allowance, primaryReset: Date?, now: Date) {
    self.titleLabel = ReserveLabel(
      allowance.title, font: ReserveFont.sans(ReserveType.metadata, .medium),
      color: ReserveColor.muted).flexible()
    self.valueLabel = ReserveLabel(
      "", font: ReserveFont.digits(ReserveType.metadata, .medium), color: ReserveColor.text
    ).fitted()
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("secondary-\(allowance.id)")
    var informationViews: [NSView] = [self.titleLabel, self.valueLabel]
    if !Self.sharesPrimaryReset(allowance, primaryReset: primaryReset) {
      let detail = ReserveLabel(
        "", font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
      ).fitted()
      self.detailLabel = detail
      informationViews.append(detail)
    }
    let information = NSStackView.row(informationViews, spacing: 7)
    information.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView.row([information, NSStackView.spacer()], spacing: 0)
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      row.topAnchor.constraint(equalTo: self.topAnchor),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
    self.apply(allowance: allowance, primaryReset: primaryReset, now: now)
  }

  required init?(coder: NSCoder) { nil }

  func apply(allowance: Allowance, primaryReset: Date?, now: Date) {
    self.titleLabel.setDisplayedText(allowance.title)
    let value = allowance.isComponentShare
      ? "\(DashboardFormat.remainingPercent(allowance.usedPercent))% of pool used"
      : "\(DashboardFormat.remainingPercent(allowance.remainingPercent))% \(allowance.paceState == .stale ? "last known" : "left")"
    self.valueLabel.setDisplayedText(value)
    let detailText = DashboardFormat.secondaryDetail(allowance, now: now)
    self.detailLabel?.setDisplayedText(detailText)
    let capturedAllowance = allowance
    self.detailLabel?.clockText = { date in
      DashboardFormat.secondaryDetail(capturedAllowance, now: date)
    }
  }

  private static func sharesPrimaryReset(_ allowance: Allowance, primaryReset: Date?) -> Bool {
    allowance.resetsAt.flatMap { reset in
      primaryReset.map { abs($0.timeIntervalSince(reset)) < 1 }
    } ?? false
  }
}

/// The disclosure that opens a provider's additional limits and usage. It is a button,
/// so the surrounding card keeps its own click for menu-bar selection.
@MainActor
final class DetailDisclosureButton: NSButton {
  private let provider: ProviderID
  private let handler: (ProviderID) -> Void

  init(provider: ProviderID, isExpanded: Bool, action: @escaping (ProviderID) -> Void) {
    self.provider = provider
    self.handler = action
    super.init(frame: .zero)
    self.title = ""
    self.image = NSImage(
      systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
      accessibilityDescription: isExpanded ? "Hide details" : "Show details")
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
    self.contentTintColor = ReserveColor.muted
    self.isBordered = false
    self.toolTip = isExpanded ? "Hide details" : "Show limits and usage"
    self.setAccessibilityLabel(
      "\(isExpanded ? "Hide" : "Show") \(provider.displayName) details")
    self.identifier = NSUserInterfaceItemIdentifier("disclose-\(provider.rawValue)")
    self.target = self
    self.action = #selector(self.performAction)
    self.widthAnchor.constraint(equalToConstant: 22).isActive = true
    self.heightAnchor.constraint(equalToConstant: 22).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  @objc private func performAction() { self.handler(self.provider) }
}

/// The same chevron for an API row. A separate type because the row belongs to
/// an API account, not to a subscription provider.
@MainActor
final class APIDetailDisclosureButton: NSButton {
  private let provider: APIConsumptionProvider
  private let handler: (APIConsumptionProvider) -> Void

  init(
    provider: APIConsumptionProvider, isExpanded: Bool,
    action: @escaping (APIConsumptionProvider) -> Void
  ) {
    self.provider = provider
    self.handler = action
    super.init(frame: .zero)
    self.title = ""
    self.image = NSImage(
      systemSymbolName: isExpanded ? "chevron.up" : "chevron.down",
      accessibilityDescription: isExpanded ? "Hide details" : "Show details")
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    self.contentTintColor = ReserveColor.muted
    self.isBordered = false
    self.toolTip = isExpanded ? "Hide details" : "Show everything this key reports"
    self.setAccessibilityLabel(
      "\(isExpanded ? "Hide" : "Show") \(provider.displayName) API details")
    self.identifier = NSUserInterfaceItemIdentifier("disclose-api-\(provider.rawValue)")
    self.target = self
    self.action = #selector(self.performAction)
    self.widthAnchor.constraint(equalToConstant: 18).isActive = true
    self.heightAnchor.constraint(equalToConstant: 18).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  @objc private func performAction() { self.handler(self.provider) }
}

/// Layer 2: activity and provider value, the numbers the glance view no longer
/// carries.
@MainActor
private final class UsageDetailGrid: NSView {
  private enum ClockValue {
    case none
    case age(Date)
    case moment(Date)
  }

  private struct RowSpec {
    enum Kind: String { case fact, cell, note, chart }
    let kind: Kind
    let id: String
    let label: String
    let value: String
    var clock: ClockValue = .none
    var alternateValues: [String] = []
    var series: [DailyUsage] = []

    var structureKey: String { "\(self.kind.rawValue)\u{1}\(self.id)\u{1}\(self.label)" }
  }

  private enum RowBinding {
    enum WidthPolicy { case fitted, capped(CGFloat), fixed(CGFloat) }
    case value(label: ReserveLabel, width: WidthPolicy)
    case note(ReserveLabel)
    case chart(ReserveSparkline)
  }

  private var renderedStructure: [String] = []
  private var bindings: [RowBinding] = []

  init(summary: ProviderSummary, now: Date = Date()) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("usage-detail-\(summary.provider.rawValue)")
    let specs = Self.specs(summary: summary, now: now)
    self.renderedStructure = specs.map(\.structureKey)
    var rows: [NSView] = []
    for spec in specs {
      let (view, binding) = Self.makeRow(spec)
      rows.append(view)
      self.bindings.append(binding)
    }
    let stack = NSStackView.column(rows, spacing: 8)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// Values and clocks change far more often than the set of rows. Keep every
  /// existing control when the row anatomy is stable; a caller replaces this
  /// region only when a row appears, disappears, or changes kind.
  func apply(summary: ProviderSummary, now: Date) -> Bool {
    let specs = Self.specs(summary: summary, now: now)
    guard specs.map(\.structureKey) == self.renderedStructure,
      specs.count == self.bindings.count
    else { return false }
    for (binding, spec) in zip(self.bindings, specs) {
      switch binding {
      case .value(let label, let width):
        label.setDisplayedText(spec.value)
        label.clockText = Self.clockText(spec.clock)
        Self.resize(label, policy: width)
      case .note(let label):
        label.setDisplayedText(spec.value)
        label.toolTip = spec.id.hasPrefix("chart-caption")
          ? ReserveSparkline.scaleExplanation : spec.value
      case .chart(let chart):
        chart.apply(series: spec.series)
      }
    }
    return true
  }

  private static func specs(summary: ProviderSummary, now: Date) -> [RowSpec] {
    let provider = summary.provider.rawValue
    let usage = summary.localUsage
    let accountData = usage?.origin == .providerAccount
    var rows = summary.details.enumerated().map { index, detail in
      RowSpec(kind: .fact, id: "detail-\(index)", label: detail.label, value: detail.value)
    }
    if let usage {
      rows.append(RowSpec(
        kind: .cell, id: "tokens-today",
        label: accountData ? "Tokens today" : "Local tokens today",
        value: DashboardFormat.tokens(usage.todayTokens)))
      rows.append(RowSpec(
        kind: .cell, id: "tokens-period",
        label: accountData ? "Tokens, last 30 days" : "Local tokens, last 30 days",
        value: DashboardFormat.tokens(usage.totalTokens)))
      rows.append(RowSpec(
        kind: .cell, id: "usage-value",
        label: accountData ? "Usage value" : "Estimated API value",
        value: "≈ \(DashboardFormat.money(usage.apiEquivalentCostUSD))"))
      if usage.inputTokens > 0 || usage.outputTokens > 0 {
        rows.append(RowSpec(
          kind: .fact, id: "input-output", label: "Input / output, 30 days",
          value: "\(DashboardFormat.tokens(usage.inputTokens)) / \(DashboardFormat.tokens(usage.outputTokens))"))
      }
      if usage.cachedInputTokens > 0 {
        rows.append(RowSpec(
          kind: .fact, id: "cached-tokens", label: "Cached tokens, 30 days",
          value: DashboardFormat.tokens(usage.cachedInputTokens)))
      }
      if !usage.modelCosts.isEmpty {
        let value = usage.modelCosts.prefix(3).map {
          "\($0.model) \(DashboardFormat.money($0.costUSD))"
        }.joined(separator: " · ")
        rows.append(RowSpec(kind: .cell, id: "models", label: "Models", value: value))
      }
      if usage.dailyTokens.contains(where: { $0.tokens > 0 }) {
        rows.append(RowSpec(
          kind: .chart, id: "usage-chart-\(provider)", label: "", value: "",
          series: usage.dailyTokens))
        rows.append(RowSpec(
          kind: .note, id: "chart-caption-\(provider)", label: "", value:
            "Daily tokens · last \(usage.dailyTokens.count) days · compressed scale"))
      }
    }
    if let cost = summary.subscriptionCostUSD {
      rows.append(RowSpec(
        kind: .cell, id: "subscription-cost",
        label: summary.subscriptionCostLabel ?? "Monthly cost",
        value: DashboardFormat.money(cost)))
    }
    if let renewal = summary.billingRenewsAt, renewal > now {
      rows.append(RowSpec(
        kind: .cell, id: "billing-renewal", label: "Renews",
        value: DashboardFormat.moment(renewal, now: now), clock: .moment(renewal)))
    }
    if let count = summary.availableResetCount, count > 0 {
      rows.append(RowSpec(
        kind: .cell, id: "available-resets", label: "Resets available", value: String(count)))
    }
    if let balance = summary.creditBalanceMinorUnits, balance > 0 {
      rows.append(RowSpec(
        kind: .cell, id: "extra-balance", label: "Extra usage balance",
        value: DashboardFormat.money(Double(balance) / 100)))
    }
    if let spend = summary.includedSpend {
      let value: String = switch spend.limitState {
      case .disabled: "Off"
      case .unlimited:
        "\(DashboardFormat.money(Double(spend.usedMinorUnits) / 100)) used · unlimited"
      case .capped:
        "\(DashboardFormat.money(Double(spend.usedMinorUnits) / 100)) of \(DashboardFormat.money(Double(spend.limitMinorUnits) / 100)) · \(DashboardFormat.money(Double(spend.remainingMinorUnits ?? 0) / 100)) left"
      }
      rows.append(RowSpec(kind: .cell, id: "included-spend", label: spend.label, value: value))
    }
    if summary.billingRenewsAt == nil, let renewal = summary.nextRenewal, renewal > now {
      rows.append(RowSpec(
        kind: .cell, id: "usage-renews-\(provider)", label: "Plan renews",
        value: DashboardFormat.moment(renewal, now: now), clock: .moment(renewal)))
    }
    for (index, notice) in (summary.serviceStatus?.notices ?? []).enumerated() {
      rows.append(RowSpec(kind: .fact, id: "service-\(index)", label: "Service", value: notice))
    }
    if let checked = summary.checkedAt ?? summary.lastUpdated {
      rows.append(RowSpec(
        kind: .cell, id: "usage-checked-\(provider)", label: "Last checked",
        value: Self.age(checked, now: now), clock: .age(checked),
        alternateValues: ["just now", "59 min ago", "999h ago"]))
    }
    if summary.localHistorySupported, summary.localHistoryEnabled,
      let failure = summary.localHistoryError
    {
      rows.append(RowSpec(
        kind: .note, id: "usage-local-history-error-\(provider)", label: "", value: failure))
    }
    if usage == nil, summary.historyPossible {
      let message = !summary.localHistorySupported
        ? "Gathering account activity…"
        : summary.localHistoryEnabled
          ? "Gathering activity from this Mac…"
          : "Activity from this Mac is off · turn it on in Settings"
      rows.append(RowSpec(
        kind: .note, id: "usage-history-note-\(provider)", label: "", value: message))
    }
    return rows
  }

  private static func makeRow(_ spec: RowSpec) -> (NSView, RowBinding) {
    switch spec.kind {
    case .fact:
      let caption = ReserveLabel(
        spec.label, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
      ).fitted()
      caption.setContentCompressionResistancePriority(.required, for: .horizontal)
      let value = ReserveLabel(
        spec.value, font: ReserveFont.digits(ReserveType.metadata, .semibold),
        color: ReserveColor.text)
      value.lineBreakMode = .byTruncatingMiddle
      value.toolTip = spec.value
      let spacing: CGFloat = 12
      let maximum = max(
        40, DashboardMetrics.cardContentWidth
          - ceil(caption.attributedStringValue.size().width) - 2 - spacing)
      value.width(min(ceil(value.attributedStringValue.size().width) + 2, maximum))
      let row = NSStackView.row([caption, NSStackView.spacer(), value], spacing: spacing)
      row.identifier = NSUserInterfaceItemIdentifier("usage-fact")
      row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
      return (row, .value(label: value, width: .capped(maximum)))
    case .cell:
      let caption = ReserveLabel(
        spec.label, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
      ).fitted()
      let value = ReserveLabel(
        spec.value, font: ReserveFont.digits(ReserveType.metadata, .semibold),
        color: ReserveColor.text)
      let width: RowBinding.WidthPolicy
      if spec.alternateValues.isEmpty {
        value.fitted()
        width = .fitted
      } else {
        let candidates = spec.alternateValues + [spec.value]
        let widest = candidates.map { candidate -> CGFloat in
          value.setDisplayedText(candidate)
          return ceil(value.attributedStringValue.size().width)
        }.max() ?? 0
        value.setDisplayedText(spec.value)
        value.width(widest + 2)
        width = .fixed(widest + 2)
      }
      value.clockText = Self.clockText(spec.clock)
      let row = NSStackView.row([caption, NSStackView.spacer(), value], spacing: 7)
      row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
      row.identifier = NSUserInterfaceItemIdentifier(spec.id)
      return (row, .value(label: value, width: width))
    case .note:
      let color = spec.id.hasPrefix("chart-caption") ? ReserveColor.subtle : ReserveColor.muted
      let label = ReserveLabel(
        spec.value, font: ReserveFont.sans(ReserveType.metadata), color: color
      ).flexible()
      label.identifier = NSUserInterfaceItemIdentifier(spec.id)
      label.toolTip = spec.id.hasPrefix("chart-caption")
        ? ReserveSparkline.scaleExplanation : spec.value
      return (label, .note(label))
    case .chart:
      let chart = ReserveSparkline(series: spec.series, color: ReserveColor.chartPrimary)
      chart.identifier = NSUserInterfaceItemIdentifier(spec.id)
      chart.translatesAutoresizingMaskIntoConstraints = false
      chart.heightAnchor.constraint(equalToConstant: 26).isActive = true
      chart.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
      return (chart, .chart(chart))
    }
  }

  private static func clockText(_ clock: ClockValue) -> ((Date) -> String)? {
    switch clock {
    case .none: nil
    case .age(let date): { now in Self.age(date, now: now) }
    case .moment(let date): { now in DashboardFormat.moment(date, now: now) }
    }
  }

  private static func resize(_ label: ReserveLabel, policy: RowBinding.WidthPolicy) {
    let desired: CGFloat
    switch policy {
    case .fitted:
      // `setDisplayedText` updates labels created with `fitted()`.
      return
    case .capped(let maximum):
      desired = min(ceil(label.attributedStringValue.size().width) + 2, maximum)
    case .fixed(let width):
      desired = width
    }
    guard let constraint = label.constraints.first(where: {
      $0.firstAttribute == .width && $0.relation == .equal && $0.secondItem == nil && $0.isActive
    }) else { return }
    constraint.constant = desired
  }

  /// "just now", "12 min ago", "3h ago" — the freshness phrase without the
  /// sentence the banner wraps it in.
  private static func age(_ date: Date, now: Date) -> String {
    DashboardFormat.updated(date, now: now).replacingOccurrences(of: "Updated ", with: "")
  }

}

/// A label and a value that may be long, such as an email address or a model
/// description. The value is measured, but never wider than the room the
/// caption leaves, so it truncates in the middle instead of pushing it aside.
@MainActor
enum DashboardFact {
  static func row(_ label: String, _ value: String, width: CGFloat) -> NSView {
    let caption = ReserveLabel(
      label, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).fitted()
    caption.setContentCompressionResistancePriority(.required, for: .horizontal)
    let valueLabel = ReserveLabel(
      value, font: ReserveFont.digits(ReserveType.metadata, .semibold), color: ReserveColor.text)
    valueLabel.lineBreakMode = .byTruncatingMiddle
    valueLabel.toolTip = value
    // Measured like the other detail values, but never wider than the room the
    // caption leaves, so a long value truncates instead of pushing it aside.
    let spacing: CGFloat = 12
    let room = width - ceil(caption.attributedStringValue.size().width) - 2 - spacing
    valueLabel.width(min(ceil(valueLabel.attributedStringValue.size().width) + 2, max(40, room)))
    let row = NSStackView.row([caption, NSStackView.spacer(), valueLabel], spacing: spacing)
    row.identifier = NSUserInterfaceItemIdentifier("usage-fact")
    row.widthAnchor.constraint(equalToConstant: width).isActive = true
    return row
  }
}

@MainActor
private final class ProviderLogo: ReserveSurface {
  /// The API rows sit in a denser list than the provider cards, so the mark is
  /// drawn smaller there but keeps the same shape and tinting rules.
  convenience init(api provider: APIConsumptionProvider) {
    self.init(
      image: ProviderArtwork.image(for: provider),
      identifier: "api-logo-\(provider.rawValue)",
      tinted: provider != .anthropic,
      size: 20,
      markSize: 12)
  }

  convenience init(provider: ProviderID) {
    self.init(provider: provider, size: 26, markSize: 15)
  }

  convenience init(provider: ProviderID, size: CGFloat, markSize: CGFloat) {
    self.init(
      image: ProviderArtwork.image(for: provider),
      identifier: "provider-logo-\(provider.rawValue)",
      tinted: provider != .anthropic,
      size: size,
      markSize: markSize)
  }

  private init(
    image source: NSImage,
    identifier: String,
    tinted: Bool,
    size: CGFloat,
    markSize: CGFloat
  ) {
    super.init(fill: ReserveColor.elevated, fillAlpha: 0.8, radius: 8)
    self.identifier = NSUserInterfaceItemIdentifier(identifier)
    self.setAccessibilityElement(false)
    let image = NSImageView(image: source)
    // The mark repeats the row's own label, so it stays silent.
    image.setAccessibilityElement(false)
    image.setAccessibilityLabel("")
    image.contentTintColor = tinted ? ReserveColor.text : nil
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: size),
      self.heightAnchor.constraint(equalToConstant: size),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: markSize),
      image.heightAnchor.constraint(equalToConstant: markSize),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class EmptyProvidersView: ReserveSurface {
  init(openSettings: @escaping () -> Void) {
    super.init(fill: ReserveColor.section, radius: ReserveRadius.section)
    let title = ReserveLabel(
      "No providers are being tracked",
      font: ReserveFont.sans(ReserveType.providerName, .semibold),
      color: ReserveColor.text)
    let subtitle = ReserveLabel(
      "Choose the subscriptions Reserve should watch.",
      font: ReserveFont.sans(ReserveType.body),
      color: ReserveColor.muted)
    let button = ReserveTextButton(
      title: "Open Settings", color: ReserveColor.accent, filled: true, action: openSettings)
    let stack = NSStackView.column([title, subtitle, button], spacing: 5, alignment: .centerX)
    stack.setCustomSpacing(14, after: subtitle)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
      self.heightAnchor.constraint(equalToConstant: 132),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class DashboardFooterView: NSView {
  init(actions: DashboardActions) {
    super.init(frame: .zero)
    let rule = ReserveHairline(width: DashboardMetrics.contentWidth)
    let insights = ReserveTextButton(
      title: "Insights", symbol: "chart.bar", size: ReserveType.body, action: actions.openInsights)
    insights.identifier = NSUserInterfaceItemIdentifier("open-insights")
    let settings = ReserveTextButton(
      title: "Settings", symbol: "gearshape", size: ReserveType.body, action: actions.openSettings)
    settings.identifier = NSUserInterfaceItemIdentifier("open-settings")
    let row = NSStackView.row([insights, NSStackView.spacer(), settings], spacing: 0)
    for view in [rule, row] {
      view.translatesAutoresizingMaskIntoConstraints = false
      self.addSubview(view)
    }
    NSLayoutConstraint.activate([
      rule.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      rule.topAnchor.constraint(equalTo: self.topAnchor),
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: -9),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: 9),
      row.topAnchor.constraint(equalTo: rule.bottomAnchor, constant: 9),
      row.bottomAnchor.constraint(equalTo: self.bottomAnchor),
      self.widthAnchor.constraint(equalToConstant: DashboardMetrics.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

enum DashboardMetrics {
  static let width: CGFloat = 440
  static let minimumHeight: CGFloat = 320
  /// The fallback ceiling, used only when no screen is known — offscreen
  /// rendering and tests. On a real screen `availableHeight` governs.
  static let maximumHeight: CGFloat = 860
  static let inset: CGFloat = 16
  static var contentWidth: CGFloat { self.width - 2 * self.inset }
  static let cardPadding: CGFloat = 14
  static var cardContentWidth: CGFloat { self.contentWidth - 2 * self.cardPadding }
  static let overviewPadding: CGFloat = 12
  static let overviewGap: CGFloat = 8
  static var overviewInnerWidth: CGFloat { self.contentWidth - 2 * self.overviewPadding }
  static var overviewTileWidth: CGFloat { (self.overviewInnerWidth - self.overviewGap) / 2 }
  static var overviewTileContentWidth: CGFloat { self.overviewTileWidth - 20 }
  static var size: NSSize { NSSize(width: self.width, height: self.minimumHeight) }

  /// The popover's own frame and arrow, on top of the content.
  static let popoverChrome: CGFloat = 26
  /// Below this, a pinned overview leaves too little detail to read at once.
  static let minimumDetailsViewport: CGFloat = 360

  /// The ceiling the dashboard may actually use on a given screen.
  ///
  /// The screen is the only real constraint. A fixed 860pt ceiling cut both
  /// ways: on a 1280×800 display it was taller than the screen, and on a large
  /// display it forced an expanded provider (around 960pt) to scroll for no
  /// reason, pushing the last card past the bottom edge.
  ///
  /// This only *clamps* — the dashboard is still content-sized, so a roomier
  /// screen does not produce a taller popover, it just stops truncating one.
  static func availableHeight(on screen: NSScreen?, visibleHeight: CGFloat? = nil) -> CGFloat {
    guard let visible = visibleHeight ?? screen?.visibleFrame.height else {
      return self.maximumHeight
    }
    let usable = visible - self.popoverChrome - 8
    return max(self.minimumHeight, usable)
  }

  static let rowGap: CGFloat = 10
  static let headerGap: CGFloat = 14
  static let footerGap: CGFloat = 12
  static let cardRowGap: CGFloat = 8
  static let identityGap: CGFloat = 10
  static let meterHeight: CGFloat = 6
}

@MainActor
enum DashboardFormat {
  /// Quotas use whole percentages. A partially used allowance never claims to
  /// be completely full just because ordinary rounding would produce 100.
  static func remainingPercent(_ value: Double) -> String {
    let bounded = min(100, max(0, value))
    if bounded < 100, bounded > 99 { return "99" }
    return String(Int(bounded.rounded()))
  }

  static func localizedDateFormatter(
    template: String,
    locale: Locale = .autoupdatingCurrent
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  private static let weekdayFormatter: DateFormatter = {
    Self.localizedDateFormatter(template: "EEEjm")
  }()
  private static let fullMomentFormatter: DateFormatter = {
    Self.localizedDateFormatter(template: "MMMdjm")
  }()
  private static let shortDateFormatter: DateFormatter = {
    Self.localizedDateFormatter(template: "MMMdjm")
  }()
  private static let renewalFormatter: DateFormatter = {
    Self.localizedDateFormatter(template: "MMMd")
  }()
  private static let currencyDetailedFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 2
    return formatter
  }()
  private static let currencyWholeFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.maximumFractionDigits = 0
    return formatter
  }()

  /// "Weekly limit · resets Wed at 1:02 AM"
  @MainActor
  static func limitLine(_ allowance: Allowance, now: Date) -> String {
    let prefix = allowance.title
    guard let reset = allowance.resetsAt, reset > now else {
      return "\(prefix) · next reset unknown"
    }
    return "\(prefix) · resets \(self.moment(reset, now: now))"
  }

  /// "Resets Wednesday at 1:02 AM" — the reset alone, for detail rows whose
  /// header already names the window.
  @MainActor
  static func resetLine(_ allowance: Allowance, now: Date) -> String {
    guard let reset = allowance.resetsAt, reset > now else { return "Next reset unknown" }
    return "Resets \(self.moment(reset, now: now))"
  }

  /// Pace first, modeled forecast second. Current capacity remains the large
  /// number in the card header and is never replaced by this modeled value.
  static func showsForecast(
    _ allowance: Allowance, paceState: UsagePaceState, observationTimeKnown: Bool
  ) -> Bool {
    // A stale card already says so three times: the freshness banner, the tinted
    // surface, and the "last known" capacity label. A fourth line adds nothing.
    guard paceState != .stale else { return false }
    return observationTimeKnown
      && (paceState == .exhausted || allowance.windowMinutes != nil || allowance.projection != nil)
  }

  static func forecast(
    _ allowance: Allowance,
    paceState: UsagePaceState,
    lastUpdated: Date?,
    now: Date
  ) -> String {
    if paceState == .stale { return "Update needed for a forecast" }
    if paceState == .exhausted {
      guard let reset = allowance.resetsAt, reset > now else { return "Limit exhausted" }
      return "Limit exhausted · resets \(self.countdown(to: reset, now: now))"
    }
    if allowance.usedPercent == 0 { return "No usage yet" }
    if allowance.windowMinutes == nil && allowance.projection == nil { return "Forecast unavailable" }
    if allowance.usedPercent < 1 || (allowance.expectedPercent ?? 0) < 10 {
      return "Too early to forecast"
    }
    let projected = allowance.projectedRemainingAtResetPercent.map {
      "about \(Int($0.rounded()))% left at reset"
    }
    switch paceState {
    case .exhausted:
      guard let reset = allowance.resetsAt, reset > now else { return "Limit exhausted" }
      return "Limit exhausted · resets \(self.countdown(to: reset, now: now))"
    case .stale:
      return "Update needed for a forecast"
    case .unknown:
      return "Forecast unavailable"
    case .reserve(let percent):
      _ = percent
      let pace = "On track"
      return projected.map { "\(pace) · \($0)" } ?? pace
    case .onPace:
      return projected.map { "On pace · \($0)" } ?? "On pace"
    case .deficit(let percent):
      _ = percent
      let pace = "At this pace"
      if let runsOut = allowance.runsOutAt,
        let renewal = allowance.resetsAt,
        runsOut < renewal
      {
        let timeBeforeRenewal = self.gap(from: runsOut, to: renewal)
        return "\(pace) · may run out \(timeBeforeRenewal) before reset"
      }
      return projected.map { "\(pace) · \($0)" } ?? pace
    }
  }

  /// Compact right-hand detail for a secondary window.
  @MainActor
  static func secondaryDetail(_ allowance: Allowance, now: Date) -> String {
    if allowance.usedPercent == 0 { return "no usage yet" }
    guard let reset = allowance.resetsAt, reset > now else { return "reset unknown" }
    return "resets \(self.moment(reset, now: now))"
  }

  /// A countdown within half a day, then a localized weekday and time inside a
  /// week, then date and time beyond it. Close to a reset, "in 1h 20m" answers
  /// the question a clock time makes the reader compute.
  static func moment(_ date: Date, now: Date) -> String {
    let interval = date.timeIntervalSince(now)
    if interval < 12 * 3600 { return self.countdown(to: date, now: now) }
    return interval < 6 * 86400
      ? self.weekdayFormatter.string(from: date)
      : self.fullMomentFormatter.string(from: date)
  }

  /// "1d 16h" between two dates.
  static func gap(from: Date, to: Date) -> String {
    let minutes = max(0, Int(to.timeIntervalSince(from) / 60))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    if days > 0 { return "\(days)d \(hours)h" }
    if hours > 0 { return "\(hours)h \(minutes % 60)m" }
    return "\(minutes)m"
  }

  static func tokens(_ value: Int64) -> String {
    let number = Double(value)
    if value >= 1_000_000_000 { return Self.compact(number / 1_000_000_000, suffix: "B") }
    if value >= 1_000_000 { return Self.compact(number / 1_000_000, suffix: "M") }
    if value >= 1_000 { return Self.compact(number / 1_000, suffix: "K") }
    return "\(value)"
  }

  static func money(_ value: Double) -> String {
    if value >= 1_000_000 {
      return Self.compact(value / 1_000_000, prefix: "$", suffix: "M")
    }
    if value >= 10_000 { return Self.compact(value / 1_000, prefix: "$", suffix: "K") }
    let formatter = value < 100 ? self.currencyDetailedFormatter : self.currencyWholeFormatter
    return (formatter.string(from: NSNumber(value: value)) ?? "$—")
  }

  static func savings(_ value: Double) -> String {
    (value < 0 ? "−" : "") + Self.money(abs(value))
  }

  static func updated(_ date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "Updated just now" }
    if seconds < 3600 { return "Updated \(Int(seconds / 60)) min ago" }
    return "Updated \(Int(seconds / 3600))h ago"
  }

  static func countdown(to date: Date, now: Date) -> String {
    let minutes = max(0, Int(date.timeIntervalSince(now) / 60))
    let days = minutes / 1440
    let hours = (minutes % 1440) / 60
    let remainder = minutes % 60
    if days > 0 { return "in \(days)d \(hours)h" }
    if hours > 0 { return "in \(hours)h \(remainder)m" }
    return "in \(remainder)m"
  }

  static func shortDate(_ date: Date) -> String {
    self.shortDateFormatter.string(from: date)
  }

  static func renewalDate(_ date: Date) -> String {
    self.renewalFormatter.string(from: date)
  }

  private static func compact(
    _ value: Double,
    prefix: String = "",
    suffix: String
  ) -> String {
    let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
    return prefix + String(format: "%.*f", digits, value) + suffix
  }
}
