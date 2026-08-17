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
}

@MainActor
final class DashboardViewController: NSViewController {
  private let store: UsageStore
  private let actions: DashboardActions
  private var lastSignature: String?

  init(store: UsageStore, actions: DashboardActions) {
    self.store = store
    self.actions = actions
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
  private static func signature(
    summaries: [ProviderSummary],
    selectedMenuBarProvider: ProviderID?,
    expandedProvider: ProviderID?,
    isRefreshing: Bool,
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
      AllowanceBuilder.headline(for: summaries, now: now).primary,
      DashboardFormat.updated(
        summaries.compactMap(\.lastUpdated).max() ?? .distantPast, now: now),
    ]
    for summary in summaries {
      parts.append(summary.provider.rawValue)
      parts.append(summary.planName)
      parts.append(summary.error ?? "-")
      parts.append(summary.needsConnection ? "connect" : "-")
      parts.append(summary.requiresClaudeKeychainAccess ? "keychain" : "-")
      parts.append(summary.isConnecting ? "connecting" : "-")
      parts.append(summary.isRefreshing ? "refreshing" : "-")
      parts.append(summary.serviceStatus?.health.rawValue ?? "-")
      parts.append(summary.serviceStatus?.detail ?? "-")
      parts.append(summary.serviceStatus?.pageURL.absoluteString ?? "-")
      parts.append(
        summary.serviceStatus.map { String($0.fetchedAt.timeIntervalSinceReferenceDate) } ?? "-")
      parts.append(summary.quotaSource ?? "-")
      parts.append(summary.subscriptionCostUSD.map { String($0) } ?? "-")
      parts.append(String(reflecting: summary.localUsage))
      for allowance in summary.allowances {
        parts.append(allowance.id)
        parts.append(String(Int(allowance.remainingPercent.rounded())))
        parts.append(DashboardFormat.limitLine(allowance, now: now))
        parts.append(
          DashboardFormat.forecast(
            allowance, paceState: summary.paceState, lastUpdated: summary.lastUpdated, now: now))
        parts.append(DashboardFormat.secondaryDetail(allowance, now: now))
      }
    }
    return parts.joined(separator: "\u{1}")
  }

  func update() {
    // `self.view` would load the view and recurse back into this method, so the
    // screen is only consulted once there is a view to ask.
    let screen = (self.isViewLoaded ? self.view.window?.screen : nil) ?? NSScreen.main
    let now = Date()
    let visibleStates = self.store.orderedStates.filter { self.store.isEnabled($0.provider) }
    let signature = Self.signature(
      summaries: visibleStates.map { AllowanceBuilder.summary(for: $0, now: now) },
      selectedMenuBarProvider: self.store.menuBarProvider,
      expandedProvider: self.store.expandedProvider,
      isRefreshing: self.store.isRefreshingAll || self.store.isScanningLocalUsage,
      now: now)
    if self.isViewLoaded, signature == self.lastSignature { return }
    self.lastSignature = signature
    let dashboard = UsageDashboardView(
      states: visibleStates,
      selectedMenuBarProvider: self.store.menuBarProvider,
      expandedProvider: self.store.expandedProvider,
      isRefreshing: self.store.isRefreshingAll || self.store.isScanningLocalUsage,
      refreshStartedAt: self.store.refreshStartedAt,
      now: now,
      maximumHeight: DashboardMetrics.availableHeight(on: screen),
      actions: self.actions)
    // The size has to be read before the view is installed. Assigning `view`
    // hands it to the popover, which immediately resizes it to the size the
    // popover still believes it is — so reading the frame afterwards reports the
    // previous height and the popover is then told to keep it.
    let intrinsicSize = dashboard.frame.size
    self.view = dashboard
    self.preferredContentSize = intrinsicSize
  }

  /// The first provider row, so opening the popover puts the keyboard on the
  /// content rather than nowhere.
  func firstKeyView() -> NSView? {
    self.view.window?.contentView.flatMap { _ in
      Self.descendants(of: self.view).compactMap { $0 as? ProviderDashboardCard }.first
    } ?? Self.descendants(of: self.view).compactMap { $0 as? ProviderDashboardCard }.first
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
    stack.addArrangedSubview(header)
    stack.setCustomSpacing(DashboardMetrics.headerGap, after: header)

    var last: NSView = header
    for summary in summaries {
      let row = ProviderDashboardCard(
        summary: summary, now: now,
        isSelectedForMenuBar: selectedMenuBarProvider == summary.provider,
        isExpanded: expandedProvider == summary.provider,
        connectProvider: actions.connectProvider,
        selectMenuBarProvider: actions.selectMenuBarProvider,
        toggleDetail: actions.toggleProviderDetail)
      row.identifier = NSUserInterfaceItemIdentifier(
        "provider-card-\(summary.provider.rawValue)")
      stack.addArrangedSubview(row)
      last = row
    }
    if summaries.isEmpty {
      let empty = EmptyProvidersView(openSettings: actions.openSettings)
      stack.addArrangedSubview(empty)
      last = empty
    }

    let footer = DashboardFooterView(actions: actions)
    stack.addArrangedSubview(footer)
    stack.setCustomSpacing(DashboardMetrics.footerGap, after: last)

    // Content-sized, with a ceiling that keeps the popover clear of the menu bar
    // and inside the screen it opens on.
    self.frame = NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: ceiling)
    self.layoutSubtreeIfNeeded()
    let content = ceil(stack.frame.height) + 2 * DashboardMetrics.inset
    let height = min(ceiling, max(DashboardMetrics.minimumHeight, content))
    self.intendedHeight = height
    self.frame = NSRect(x: 0, y: 0, width: DashboardMetrics.width, height: height)
    if content > height {
      self.makeScrollable(stack: stack, contentHeight: content)
    }
    self.layoutSubtreeIfNeeded()
  }

  /// Opening a provider can push the column past the ceiling. Only then does the
  /// dashboard scroll; the everyday view never does.
  private func makeScrollable(stack: NSStackView, contentHeight: CGFloat) {
    stack.removeFromSuperview()
    // Flipped so the column starts at the top and the view opens there.
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
    scroll.documentView = document
    scroll.hasVerticalScroller = true
    scroll.scrollerStyle = .overlay
    scroll.drawsBackground = false
    // A card that continues past the bottom edge has to announce itself. With
    // auto-hiding overlay scrollers the column simply stopped, and the provider
    // below the fold read as missing rather than as scrolled out of view.
    scroll.autohidesScrollers = false
    scroll.automaticallyAdjustsContentInsets = false
    scroll.autoresizingMask = [.width, .height]
    self.addSubview(scroll)
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

/// Name, the one conclusion, freshness, and the secondary controls.
@MainActor
private final class DashboardHeaderView: NSView {
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
    let conclusionRow = NSStackView.row([conclusionIcon, conclusion], spacing: 6)
    conclusionRow.identifier = NSUserInterfaceItemIdentifier("dashboard-headline")

    let freshness = ReserveLabel(
      Self.freshness(summaries: summaries, isRefreshing: isRefreshing, now: now),
      font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.subtle
    ).fitted()
    freshness.toolTip = "Usage data is processed on this Mac."

    let refresh = ReserveIconButton(
      symbol: "arrow.clockwise", toolTip: "Refresh now", diameter: 26,
      spinningSince: isRefreshing ? now.timeIntervalSince(refreshStartedAt ?? now) : nil,
      action: actions.refreshAll)
    refresh.identifier = NSUserInterfaceItemIdentifier("refresh-all")
    let more = DashboardMenuButton(actions: actions)
    more.identifier = NSUserInterfaceItemIdentifier("more-actions")
    let top = NSStackView.row(
      [wordmark, NSStackView.spacer(), freshness, refresh, more], spacing: 7)
    let secondary = ReserveLabel(
      headline.secondary, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).flexible()
    secondary.toolTip = headline.secondary
    let stack = NSStackView.column([top, conclusionRow, secondary], spacing: 5)
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

  required init?(coder: NSCoder) { nil }

  private static func freshness(
    summaries: [ProviderSummary],
    isRefreshing: Bool,
    now: Date
  ) -> String {
    if isRefreshing { return "Updating…" }
    guard let latest = summaries.compactMap(\.lastUpdated).max() else {
      return "Waiting for the first update"
    }
    return DashboardFormat.updated(latest, now: now)
  }
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
    let insights = NSMenuItem(
      title: "Insights…", action: #selector(self.openInsights), keyEquivalent: "")
    insights.target = self
    let settings = NSMenuItem(
      title: "Settings…", action: #selector(self.openSettings), keyEquivalent: ",")
    settings.target = self
    let quit = NSMenuItem(title: "Quit Reserve", action: #selector(self.quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(insights)
    menu.addItem(settings)
    menu.addItem(.separator())
    menu.addItem(quit)
    return menu
  }

  @objc private func showMenu() {
    let menu = self.makeMenu()
    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.height + 4), in: self)
  }

  @objc private func openInsights() { self.actions.openInsights() }
  @objc private func openSettings() { self.actions.openSettings() }
  @objc private func quit() { self.actions.quit() }
}

/// One provider, rendered with the same anatomy regardless of how many limit
/// windows it exposes.
@MainActor
final class ProviderDashboardCard: NSView {
  private let provider: ProviderID
  private let selectMenuBarProvider: (ProviderID) -> Void
  private let toggleDetail: (ProviderID) -> Void
  private let isSelectedForMenuBar: Bool
  private let hasUnavailableLiveData: Bool
  private var isHovered = false
  private var hoverTrackingArea: NSTrackingArea?

  init(
    summary: ProviderSummary,
    now: Date,
    isSelectedForMenuBar: Bool,
    isExpanded: Bool = false,
    connectProvider: @escaping (ProviderID) -> Void,
    selectMenuBarProvider: @escaping (ProviderID) -> Void,
    toggleDetail: @escaping (ProviderID) -> Void = { _ in }
  ) {
    self.provider = summary.provider
    self.selectMenuBarProvider = selectMenuBarProvider
    self.toggleDetail = toggleDetail
    self.isSelectedForMenuBar = isSelectedForMenuBar
    self.hasUnavailableLiveData = summary.paceState == .stale
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
    self.setAccessibilityHelp(
      "Space shows this provider in the menu bar. Return shows its limits, usage and sources.")

    var rows: [NSView] = [
      Self.identityRow(
        summary: summary, isSelectedForMenuBar: isSelectedForMenuBar,
        isExpanded: isExpanded, connectProvider: connectProvider, toggleDetail: toggleDetail)
    ]
    if self.hasUnavailableLiveData {
      rows.append(ProviderFreshnessBanner(summary: summary, now: now))
    }
    if let primary = summary.primary {
      rows.append(
        AllowanceView(
          allowance: primary, paceState: summary.paceState,
          lastUpdated: summary.lastUpdated, now: now))
    } else {
      rows.append(Self.unavailableRow(summary: summary))
    }
    if summary.serviceIsExceptional, let service = summary.serviceStatus {
      rows.append(ServiceBanner(provider: summary.provider, status: service))
    }
    if isExpanded {
      // Layer 1: every remaining limit gets the same full component.
      for allowance in summary.secondary {
        rows.append(
          AllowanceView(
            allowance: allowance,
            paceState: AllowanceBuilder.paceState(
              primary: allowance, hasSnapshot: true, isStale: false, hasError: false),
            lastUpdated: summary.lastUpdated,
            now: now,
            isDetail: true))
      }
      rows.append(ReserveHairline(width: DashboardMetrics.cardContentWidth))
      // Layer 2: activity and estimated value.
      rows.append(UsageDetailGrid(summary: summary))
      rows.append(ReserveHairline(width: DashboardMetrics.cardContentWidth))
      // Layer 3: where every number came from, and how fresh it is.
      rows.append(SourceDetailList(summary: summary, now: now))
    } else if !summary.secondary.isEmpty {
      rows.append(SecondaryAllowanceRow(allowances: summary.secondary, now: now))
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
  }

  required init?(coder: NSCoder) { nil }

  override var isOpaque: Bool { false }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let path = NSBezierPath(
      roundedRect: self.bounds, xRadius: ReserveRadius.section, yRadius: ReserveRadius.section)
    (self.hasUnavailableLiveData
      ? ReserveColor.staleSurface
      : self.isSelectedForMenuBar
        ? ReserveColor.selected
        : self.isHovered ? ReserveColor.hover : ReserveColor.section
    ).setFill()
    path.fill()
    (self.hasUnavailableLiveData ? ReserveColor.staleBorder : ReserveColor.hairline).setStroke()
    path.lineWidth = 1
    path.stroke()
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
      return summary.error ?? "Not connected"
    }
    var parts = [
      "\(Int(primary.remainingPercent.rounded())) percent left",
      summary.paceState.label,
    ]
    if let reset = primary.resetsAt, reset > now {
      parts.append("\(primary.title) resets \(DashboardFormat.moment(reset, now: now))")
    }
    parts.append(
      DashboardFormat.forecast(
        primary, paceState: summary.paceState, lastUpdated: summary.lastUpdated, now: now))
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
    connectProvider: @escaping (ProviderID) -> Void,
    toggleDetail: @escaping (ProviderID) -> Void
  ) -> NSView {
    let logo = ProviderLogo(provider: summary.provider)
    let providerName = [summary.provider.displayName, summary.planName]
      .filter { !$0.isEmpty }.joined(separator: " ")
    let name = ReserveLabel(
      providerName,
      font: ReserveFont.sans(ReserveType.providerName, .semibold),
      color: ReserveColor.text
    ).flexible()
    name.toolTip = summary.planName.isEmpty
      ? summary.provider.displayName : "\(summary.provider.displayName) · \(summary.planName)"

    var identity: [NSView] = [logo, name]
    if isSelectedForMenuBar {
      // Configuration state is a quiet mark, never a full-card treatment.
      let pin = NSImageView(
        image: NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Shown in menu bar")
          ?? NSImage())
      pin.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
      pin.contentTintColor = ReserveColor.accent
      pin.toolTip = "Shown in menu bar"
      pin.setAccessibilityLabel("Shown in menu bar")
      pin.setAccessibilityElement(false)
      pin.setAccessibilityLabel("")
      pin.translatesAutoresizingMaskIntoConstraints = false
      pin.widthAnchor.constraint(equalToConstant: 12).isActive = true
      pin.identifier = NSUserInterfaceItemIdentifier(
        "menu-bar-pin-\(summary.provider.rawValue)")
      identity.append(pin)
    }

    let trailing: NSView
    if summary.needsConnection, !summary.isConnecting, !summary.isRefreshing {
      let actionTitle = summary.requiresClaudeKeychainAccess ? "Show limits" : "Sign in"
      let connect = ReserveTextButton(
        title: actionTitle, size: ReserveType.metadata, color: ReserveColor.warning, filled: true,
        minimumWidth: 64, height: 24,
        action: { connectProvider(summary.provider) })
      connect.identifier = NSUserInterfaceItemIdentifier("connect-\(summary.provider.rawValue)")
      connect.toolTip =
        summary.requiresClaudeKeychainAccess
        ? "Uses Claude's existing sign-in only to check limits. Reserve never stores it."
        : "Sign in with the official \(summary.provider.displayName) tool to read plan limits"
      trailing = connect
    } else if let primary = summary.primary {
      trailing = RemainingValueView(allowance: primary, paceState: summary.paceState)
    } else {
      trailing = HealthBadge(paceState: summary.paceState)
    }
    trailing.setContentHuggingPriority(.required, for: .horizontal)
    trailing.setContentCompressionResistancePriority(.required, for: .horizontal)

    let disclose = DetailDisclosureButton(
      provider: summary.provider, isExpanded: isExpanded, action: toggleDetail)
    let row = NSStackView.row(
      identity + [NSStackView.spacer(), trailing, disclose], spacing: 9)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }

  private static func unavailableRow(summary: ProviderSummary) -> NSView {
    let message =
      summary.isConnecting && summary.requiresClaudeKeychainAccess
      ? "One-time macOS approval…"
      : summary.isConnecting
      ? "Complete the sign-in in your browser"
      : summary.requiresClaudeKeychainAccess
        ? "Claude is ready · show your plan limits"
      : summary.needsConnection && summary.localUsage != nil
        ? "Plan limits unavailable · local activity available"
        : summary.error ?? "Sign in to read plan limits"
    let label = ReserveLabel(
      message, font: ReserveFont.sans(ReserveType.metadata),
      color: summary.needsConnection ? ReserveColor.warning : ReserveColor.muted
    ).flexible()
    label.toolTip = summary.error ?? message
    let row = NSStackView.row([label], spacing: 0)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }
}

/// Makes cached or missing provider data impossible to mistake for a live
/// reading. The detailed error remains available as a tooltip.
@MainActor
private final class ProviderFreshnessBanner: NSView {
  init(summary: ProviderSummary, now: Date) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("freshness-\(summary.provider.rawValue)")
    let state: String
    let fullState: String
    if summary.needsConnection {
      state = "Disconnected"
      fullState = state
    } else if summary.error != nil {
      state = "Unavailable"
      fullState = "Live data unavailable"
    } else {
      state = "Cached"
      fullState = "Cached data"
    }
    let age = summary.lastUpdated.map { Self.compactAge(since: $0, now: now) } ?? "never updated"
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
    label.identifier = NSUserInterfaceItemIdentifier(
      "freshness-label-\(summary.provider.rawValue)")
    self.toolTip = summary.error ?? fullMessage
    self.setAccessibilityLabel(fullMessage)

    let row = NSStackView.row([icon, label], spacing: 6)
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

  private static func compactAge(since date: Date, now: Date) -> String {
    let seconds = max(0, now.timeIntervalSince(date))
    if seconds < 60 { return "updated just now" }
    if seconds < 3_600 { return "updated \(Int(seconds / 60))m ago" }
    return "updated \(Int(seconds / 3_600))h ago"
  }
}

/// "80% left" — every percentage states what it measures.
@MainActor
private final class RemainingValueView: NSView {
  init(allowance: Allowance, paceState: UsagePaceState) {
    super.init(frame: .zero)
    let value = ReserveLabel(
      String(format: "%.0f%%", allowance.remainingPercent),
      font: ReserveFont.digits(ReserveType.remaining, .semibold),
      color: paceState == .stale ? ReserveColor.muted : ReserveColor.text
    ).fitted()
    let unit = ReserveLabel(
      "left", font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).fitted()
    value.setAccessibilityLabel(
      "\(Int(allowance.remainingPercent.rounded())) percent left, \(paceState.label)")
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
  init(
    allowance: Allowance,
    paceState: UsagePaceState,
    lastUpdated: Date?,
    now: Date,
    isDetail: Bool = false
  ) {
    super.init(frame: .zero)
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
        "\(Int(allowance.remainingPercent.rounded()))% left",
        font: ReserveFont.digits(ReserveType.body, .semibold), color: ReserveColor.text
      ).fitted()
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

    let meter = ReserveMeter(
      remainingPercent: allowance.remainingPercent,
      paceRemainingPercent: allowance.expectedPercent.map { 100 - $0 },
      label: allowance.title,
      color: paceState.color)
    meter.heightAnchor.constraint(equalToConstant: DashboardMetrics.meterHeight).isActive = true
    meter.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true

    let forecast = ReserveLabel(
      DashboardFormat.forecast(
        allowance, paceState: paceState, lastUpdated: lastUpdated, now: now),
      font: ReserveFont.sans(ReserveType.body),
      color: paceState.color
    ).flexible()
    forecast.identifier = NSUserInterfaceItemIdentifier("forecast")
    forecast.toolTip = DashboardFormat.forecast(
      allowance, paceState: paceState, lastUpdated: lastUpdated, now: now)

    let stack = NSStackView.column(header + [caption, meter, forecast], spacing: 8)
    stack.setCustomSpacing(9, after: meter)
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

  required init?(coder: NSCoder) { nil }
}

/// Additional windows, compacted to one line each.
@MainActor
private final class SecondaryAllowanceRow: NSView {
  init(allowances: [Allowance], now: Date) {
    super.init(frame: .zero)
    let lines = allowances.map { allowance -> NSView in
      let title = ReserveLabel(
        allowance.title, font: ReserveFont.sans(ReserveType.metadata, .medium),
        color: ReserveColor.muted)
      let value = ReserveLabel(
        "\(Int(allowance.remainingPercent.rounded()))% left",
        font: ReserveFont.digits(ReserveType.metadata, .medium),
        color: ReserveColor.text
      ).fitted()
      let detail = ReserveLabel(
        DashboardFormat.secondaryDetail(allowance, now: now),
        font: ReserveFont.sans(ReserveType.metadata),
        color: ReserveColor.subtle
      ).fitted()
      title.flexible()
      let information = NSStackView.row([title, value, detail], spacing: 7)
      information.setContentHuggingPriority(.required, for: .horizontal)
      let row = NSStackView.row(
        [information, NSStackView.spacer()], spacing: 0)
      row.identifier = NSUserInterfaceItemIdentifier("secondary-\(allowance.id)")
      row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
      return row
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

/// The disclosure that opens a provider's three detail layers. It is a button,
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
    self.contentTintColor = ReserveColor.subtle
    self.isBordered = false
    self.toolTip = isExpanded ? "Hide details" : "Show limits, usage and sources"
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

/// Layer 2: activity and estimated value, the numbers the glance view no longer
/// carries.
@MainActor
private final class UsageDetailGrid: NSView {
  init(summary: ProviderSummary) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("usage-detail-\(summary.provider.rawValue)")
    let usage = summary.localUsage
    let cells: [NSView] = [
      Self.cell(
        "Local tokens today", usage.map { DashboardFormat.tokens($0.todayTokens) } ?? "—"),
      Self.cell(
        "Local · last 30 days", usage.map { DashboardFormat.tokens($0.totalTokens) } ?? "—"),
      Self.cell(
        "Estimated API value",
        usage.map { DashboardFormat.money($0.apiEquivalentCostUSD) } ?? "—"),
      Self.cell(
        "Monthly cost",
        summary.subscriptionCostUSD.map { "\(DashboardFormat.money($0))/mo" } ?? "Not set"),
    ]
    let top = NSStackView.row([cells[0], NSStackView.spacer(), cells[1]], spacing: 8)
    let bottom = NSStackView.row([cells[2], NSStackView.spacer(), cells[3]], spacing: 8)
    for row in [top, bottom] {
      row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    }
    var rows: [NSView] = [top, bottom]
    if let series = usage?.dailyTokens, series.contains(where: { $0.tokens > 0 }) {
      let chart = ReserveSparkline(series: series, color: ReserveColor.chartPrimary)
      chart.identifier = NSUserInterfaceItemIdentifier(
        "usage-chart-\(summary.provider.rawValue)")
      chart.translatesAutoresizingMaskIntoConstraints = false
      chart.heightAnchor.constraint(equalToConstant: 26).isActive = true
      chart.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive =
        true
      let caption = ReserveLabel(
        "Daily tokens · last \(series.count) days · compressed scale",
        font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.subtle
      ).flexible()
      caption.toolTip = ReserveSparkline.scaleExplanation
      rows.append(contentsOf: [chart, caption])
    }
    let stack = NSStackView.column(rows, spacing: 8)
    if rows.count > 2 { stack.setCustomSpacing(11, after: bottom) }
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

  private static func cell(_ label: String, _ value: String) -> NSView {
    let caption = ReserveLabel(
      label, font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted
    ).fitted()
    let value = ReserveLabel(
      value, font: ReserveFont.digits(ReserveType.metadata, .semibold), color: ReserveColor.text
    ).fitted()
    return NSStackView.row([caption, value], spacing: 7)
  }
}

/// Layer 3: where each number came from, whether it is authoritative, and when
/// it last arrived.
@MainActor
private final class SourceDetailList: NSView {
  init(summary: ProviderSummary, now: Date) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("sources-\(summary.provider.rawValue)")
    var lines: [NSView] = [
      Self.line(
        "Limits",
        summary.quotaSource.map { "Provider reported · \($0)" } ?? "Not connected",
        isEstimate: false),
      Self.line(
        "Tokens",
        summary.localUsage == nil
          ? "No local logs found"
          : "From local logs on this Mac · this device only",
        isEstimate: false),
    ]
    if summary.localUsage != nil {
      lines.append(Self.line("Value", "Estimated from published API prices", isEstimate: true))
    }
    let freshness =
      summary.lastUpdated.map { DashboardFormat.updated($0, now: now) } ?? "Never updated"
    lines.append(
      Self.line(
        "Updated",
        summary.paceState == .stale ? "\(freshness) · forecast may be outdated" : freshness,
        isEstimate: false))
    if summary.primary?.projection == nil {
      lines.append(Self.line("Forecast", "Insufficient data for a forecast", isEstimate: true))
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

  private static func line(_ label: String, _ value: String, isEstimate: Bool) -> NSView {
    let caption = ReserveLabel(
      label, font: ReserveFont.sans(ReserveType.metadata, .medium), color: ReserveColor.muted
    ).width(64)
    let text = ReserveLabel(
      value, font: ReserveFont.sans(ReserveType.metadata),
      color: isEstimate ? ReserveColor.subtle : ReserveColor.muted
    ).flexible()
    text.toolTip = value
    let row = NSStackView.row([caption, text], spacing: 8)
    row.widthAnchor.constraint(equalToConstant: DashboardMetrics.cardContentWidth).isActive = true
    return row
  }
}

@MainActor
private final class ProviderLogo: ReserveSurface {
  init(provider: ProviderID) {
    super.init(fill: ReserveColor.elevated, fillAlpha: 0.8, radius: 8)
    self.identifier = NSUserInterfaceItemIdentifier("provider-logo-\(provider.rawValue)")
    self.setAccessibilityElement(false)
    let image = NSImageView(image: ProviderArtwork.image(for: provider))
    // The mark repeats the row's own label, so it stays silent.
    image.setAccessibilityElement(false)
    image.setAccessibilityLabel("")
    image.contentTintColor = provider != .anthropic ? ReserveColor.text : nil
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: 26),
      self.heightAnchor.constraint(equalToConstant: 26),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 15),
      image.heightAnchor.constraint(equalToConstant: 15),
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
  static let width: CGFloat = 490
  static let minimumHeight: CGFloat = 320
  /// The fallback ceiling, used only when no screen is known — offscreen
  /// rendering and tests. On a real screen `availableHeight` governs.
  static let maximumHeight: CGFloat = 860
  static let inset: CGFloat = 16
  static var contentWidth: CGFloat { self.width - 2 * self.inset }
  static let cardPadding: CGFloat = 14
  static var cardContentWidth: CGFloat { self.contentWidth - 2 * self.cardPadding }
  static var size: NSSize { NSSize(width: self.width, height: self.minimumHeight) }

  /// The popover's own frame and arrow, on top of the content.
  static let popoverChrome: CGFloat = 26

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

  static let rowGap: CGFloat = 12
  static let headerGap: CGFloat = 16
  static let footerGap: CGFloat = 14
  static let cardRowGap: CGFloat = 10
  static let identityGap: CGFloat = 12
  static let meterHeight: CGFloat = 6
}

@MainActor
enum DashboardFormat {
  static func localizedDateFormatter(
    template: String,
    locale: Locale = .autoupdatingCurrent
  ) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter
  }

  private static let clockFormatter: DateFormatter = {
    Self.localizedDateFormatter(template: "jm")
  }()
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
    guard let reset = allowance.resetsAt, reset > now else {
      return "\(allowance.title) · next reset unknown"
    }
    return "\(allowance.title) · resets \(self.moment(reset, now: now))"
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
  static func forecast(
    _ allowance: Allowance,
    paceState: UsagePaceState,
    lastUpdated: Date?,
    now: Date
  ) -> String {
    let projected = allowance.projectedRemainingAtResetPercent.map {
      "\(Int($0.rounded()))% projected left at reset"
    }
    switch paceState {
    case .exhausted:
      guard let reset = allowance.resetsAt, reset > now else { return "Limit exhausted" }
      return "Limit exhausted · resets \(self.countdown(to: reset, now: now))"
    case .stale:
      return "Forecast unavailable while live data is unavailable"
    case .unknown:
      return "Forecast unavailable"
    case .reserve(let percent):
      let pace = "\(Int(percent.rounded()))% in reserve"
      return projected.map { "\(pace) · \($0)" } ?? pace
    case .onPace:
      return projected.map { "On pace · \($0)" } ?? "On pace"
    case .deficit(let percent):
      let pace = "\(Int(percent.rounded()))% deficit"
      if let runsOut = allowance.runsOutAt,
        let renewal = allowance.resetsAt,
        runsOut < renewal
      {
        let timeBeforeRenewal = self.gap(from: runsOut, to: renewal)
        return "\(pace) · runs out \(timeBeforeRenewal) early"
      }
      return projected.map { "\(pace) · \($0)" } ?? pace
    }
  }

  /// Compact right-hand detail for a secondary window.
  @MainActor
  static func secondaryDetail(_ allowance: Allowance, now: Date) -> String {
    if allowance.usedPercent <= 0.5 { return "ready" }
    guard let reset = allowance.resetsAt, reset > now else { return "reset unknown" }
    return "resets \(self.moment(reset, now: now))"
  }

  /// A localized weekday and time inside a week, or date and time beyond it.
  static func moment(_ date: Date, now: Date) -> String {
    let interval = date.timeIntervalSince(now)
    if interval < 12 * 3600 {
      return "at \(self.clockFormatter.string(from: date))"
    }
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
