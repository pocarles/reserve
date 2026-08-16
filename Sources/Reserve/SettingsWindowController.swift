import AppKit
import ServiceManagement
import ReserveCore

/// Reserve's settings, built the way macOS builds settings: a toolbar of panes
/// above a resizable window that takes the system's own appearance. No page
/// titles, no introductory copy, no themed canvas — the toolbar already says
/// where you are.
@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate, NSToolbarDelegate {
  enum Pane: String, CaseIterable {
    case general
    case providers
    case notifications
    case appearance
    case insights
    case privacy
    case about

    var title: String {
      switch self {
      case .general: "General"
      case .providers: "Providers"
      case .notifications: "Notifications"
      case .appearance: "Appearance"
      case .insights: "Insights"
      case .privacy: "Privacy"
      case .about: "About"
      }
    }

    var symbol: String {
      switch self {
      case .general: "gearshape"
      case .providers: "person.2"
      case .notifications: "bell"
      case .appearance: "paintpalette"
      case .insights: "chart.bar"
      case .privacy: "hand.raised"
      case .about: "info.circle"
      }
    }

    var itemIdentifier: NSToolbarItem.Identifier {
      NSToolbarItem.Identifier("settings-pane-\(self.rawValue)")
    }
  }

  private let store: UsageStore
  private let updateChecker = UpdateChecker()
  private(set) var pane = Pane.general
  private weak var updateStatusLabel: NSTextField?
  private weak var updateButton: NSButton?
  private var renewalStatusLabels: [ProviderID: NSTextField] = [:]
  private var expandedProviders: Set<ProviderID> = []
  private var availableReleaseURL: URL?
  /// Held so the registration is explicit; the observer closure itself keeps
  /// only a weak reference to this controller, which lives for the app's run.
  private var storeObserver: UsageStore.ObserverToken?
  /// Guards against a pane rebuild re-entering through a store write made by one
  /// of the controls it is building.
  private var isApplyingPane = false

  init(store: UsageStore) {
    self.store = store
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: SettingsLayout.defaultSize),
      styleMask: [.titled, .closable, .resizable],
      backing: .buffered,
      defer: true)
    window.title = Pane.general.title
    window.isReleasedWhenClosed = false
    window.toolbarStyle = .preference
    window.level = .floating
    window.hidesOnDeactivate = false
    window.center()
    super.init(window: window)

    let toolbar = NSToolbar(identifier: "settings-toolbar")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = false
    toolbar.displayMode = .iconAndLabel
    toolbar.selectedItemIdentifier = self.pane.itemIdentifier
    window.toolbar = toolbar
    self.applyPane(animated: false)
    // Settings shows live provider state — connection, plan, freshness — so it
    // has to observe the same store the dashboard does. Without this it keeps
    // whatever was true when the pane was last built.
    self.storeObserver = store.observe { [weak self] in self?.storeChanged() }
  }

  /// Rebuilds the visible pane when the store changes.
  ///
  /// Rebuilding replaces every control, so it is deliberately skipped while a
  /// text field is being edited — otherwise a refresh landing mid-keystroke
  /// would take the field editor away and discard what was typed.
  private func storeChanged() {
    guard let window = self.window, window.isVisible else { return }
    guard !self.isApplyingPane else { return }
    if window.firstResponder is NSText { return }
    self.applyPane(animated: false)
  }

  required init?(coder: NSCoder) { nil }

  override func showWindow(_ sender: Any?) {
    // The current pane is already live. Rebuilding it on every reopen retained
    // a complete control tree until the next AppKit autorelease drain.
    if self.window?.contentView == nil { self.applyPane(animated: false) }
    super.showWindow(sender)
    self.window?.makeKeyAndOrderFront(nil)
    self.window?.orderFrontRegardless()
  }

  func show(_ pane: Pane) {
    let paneChanged = self.pane != pane
    self.pane = pane
    self.window?.toolbar?.selectedItemIdentifier = pane.itemIdentifier
    if paneChanged || self.window?.contentView == nil {
      self.applyPane(animated: self.window?.isVisible == true)
    }
    self.showWindow(nil)
  }

  /// The analytical surface, reached from the popover footer.
  func showInsights() { self.show(.insights) }

  // MARK: - Toolbar

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allCases.map(\.itemIdentifier)
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allCases.map(\.itemIdentifier)
  }

  func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    Pane.allCases.map(\.itemIdentifier)
  }

  func toolbar(
    _ toolbar: NSToolbar,
    itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    guard let pane = Pane.allCases.first(where: { $0.itemIdentifier == itemIdentifier }) else {
      return nil
    }
    let item = NSToolbarItem(itemIdentifier: itemIdentifier)
    item.label = pane.title
    item.paletteLabel = pane.title
    item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
    item.target = self
    item.action = #selector(self.toolbarItemSelected(_:))
    return item
  }

  @objc private func toolbarItemSelected(_ sender: NSToolbarItem) {
    guard let pane = Pane.allCases.first(where: { $0.itemIdentifier == sender.itemIdentifier })
    else { return }
    self.pane = pane
    self.applyPane(animated: true)
  }

  /// Swaps the pane and resizes to it, keeping the window's top-left corner
  /// anchored the way macOS settings windows do.
  private func applyPane(animated: Bool) {
    guard let window = self.window else { return }
    guard !self.isApplyingPane else { return }
    self.isApplyingPane = true
    defer { self.isApplyingPane = false }
    window.title = self.pane.title
    let content = self.makeContentView()
    content.layoutSubtreeIfNeeded()
    let size = NSSize(
      width: max(SettingsLayout.defaultSize.width, content.fittingSize.width),
      height: max(SettingsLayout.minimumHeight, content.frame.height))
    window.contentView = content
    let frame = window.frame
    let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
    let newFrame = NSRect(
      x: frame.minX,
      y: frame.maxY - target.height,
      width: target.width,
      height: target.height)
    window.setFrame(newFrame, display: true, animate: animated && !ReserveMotion.isReduced)
    window.contentMinSize = NSSize(width: size.width, height: SettingsLayout.minimumHeight)
  }

  private func makeContentView() -> NSView {
    switch self.pane {
    case .general: self.generalPane()
    case .providers: self.providersPane()
    case .notifications: self.notificationsPane()
    case .appearance: self.appearancePane()
    case .insights: self.insightsPane()
    case .privacy: self.privacyPane()
    case .about: self.aboutPane()
    }
  }

  // MARK: - Panes

  private func generalPane() -> NSView {
    self.pane(
      identifier: "pane-general",
      sections: [
        self.section(
          title: "Behavior",
          rows: [
            self.formRow("Refresh limits:", self.refreshIntervalControl()),
            self.formRow("Startup:", self.launchAtLoginCheckbox()),
          ]),
        self.section(
          title: "Menu bar",
          rows: [
            self.formRow("Display:", self.menuBarModeControl()),
            self.formRow("Details:", self.menuBarDetailControls()),
            self.formRow("Preview:", MenuBarPreview(store: self.store)),
          ]),
      ])
  }

  private func providersPane() -> NSView {
    var rows: [NSView] = []
    for provider in ProviderID.allCases {
      rows.append(self.providerRow(provider))
      if self.expandedProviders.contains(provider) {
        rows.append(self.providerDetail(provider))
      }
      if provider != ProviderID.allCases.last {
        rows.append(SettingsSeparator(width: SettingsLayout.contentWidth))
      }
    }
    return self.pane(
      identifier: "pane-providers",
      sections: [
        self.section(
          title: nil,
          footer: "Reserve detects the provider tools installed on this Mac and reuses their "
            + "existing sign-ins. Claude Keychain reuse stays off until you enable it. "
            + "Open a provider for its plan, sources and permissions.",
          rows: rows)
      ])
  }

  private func notificationsPane() -> NSView {
    let smart = [
      ("Notify when a forecast enters deficit", "deficit"),
      ("Limit exhausted", "exhausted"),
      ("Capacity available again", "weeklyRenewal"),
      ("Data stale or provider disconnected", "stale"),
      ("Provider service incident", "incident"),
    ].map { self.notificationCheckbox(title: $0.0, key: $0.1) }

    let advanced = [
      self.notificationCheckbox(title: "Notify at 50% left", key: "threshold50"),
      self.notificationCheckbox(title: "Notify at 10% left", key: "threshold90"),
      self.notificationCheckbox(title: "Notify before a plan renewal", key: "planRenewal"),
      self.notificationCheckbox(
        title: "Notify when a 5-hour window resets", key: "fiveHourRenewal"),
      self.notificationCheckbox(title: "Play a sound", key: "sound"),
    ]

    return self.pane(
      identifier: "pane-notifications",
      sections: [
        self.section(title: nil, rows: [self.notificationsEnabledCheckbox()]),
        self.section(
          title: "Smart alerts",
          footer: "Reserve reports factual state changes rather than treating normal usage "
            + "conditions as emergencies. These are on by default.",
          rows: smart),
        self.section(
          title: "Advanced",
          footer: "Fixed thresholds fire regardless of pace. They stay off unless you turn "
            + "them on.",
          rows: advanced),
      ])
  }

  private func appearancePane() -> NSView {
    self.pane(
      identifier: "pane-appearance",
      sections: [
        self.section(
          title: "Appearance",
          rows: [self.formRow("Theme:", self.appearanceModeControl())]),
        self.section(
          title: "Accent",
          footer: "Accent themes shape Reserve's surfaces and controls. Green, blue and orange "
            + "remain reserved for usage state.",
          rows: [self.accentRow()]),
        self.section(
          title: "Preview",
          rows: [ThemePreview(theme: self.store.appearanceTheme)]),
      ])
  }

  private func insightsPane() -> NSView {
    let rows = ProviderID.allCases.map(self.insightRow)
    let states = ProviderID.allCases.compactMap { self.store.states[$0] }
      .filter { self.store.isEnabled($0.provider) }
    let measured = states.filter { $0.localUsage != nil }
    let apiValue = measured.reduce(0.0) { $0 + ($1.localUsage?.apiEquivalentCostUSD ?? 0) }
    let plans = measured.reduce(0.0) { $0 + self.store.monthlySubscriptionCost(for: $1.provider) }
    let total = SettingsLabel(
      measured.isEmpty
        ? "No local usage has been measured yet"
        : "\(DashboardFormat.money(apiValue)) of API-equivalent usage against "
          + "\(DashboardFormat.money(plans)) of plans",
      size: 13, weight: .medium, color: .labelColor)
    total.identifier = NSUserInterfaceItemIdentifier("insights-total")

    let charts = ProviderID.allCases.compactMap { provider -> NSView? in
      guard let series = self.store.states[provider]?.localUsage?.dailyTokens,
        series.contains(where: { $0.tokens > 0 })
      else { return nil }
      return self.chartRow(provider: provider, series: series)
    }

    return self.pane(
      identifier: "pane-insights",
      sections: [
        self.section(
          title: "Activity",
          footer: "Measured from session logs on this Mac. Activity from other devices is not "
            + "included.",
          rows: rows),
        self.section(
          title: "Daily tokens",
          footer: charts.isEmpty
            ? "No local activity has been recorded yet."
            : "One bar per day, newest on the right. A compressed square-root scale keeps "
              + "ordinary days visible beside outliers. Each provider uses its own peak.",
          rows: charts.isEmpty ? [SettingsLabel("—", size: 12, color: .tertiaryLabelColor)] : charts),
        self.section(
          title: "Estimated plan value",
          footer: "Reserve cannot know whether these tokens would otherwise have been bought "
            + "through an API. Treat this as an estimate of comparable value, not money saved.",
          rows: [total]),
      ])
  }

  /// Identity, updates and links, in the order someone looks for them. This is
  /// the About surface: the standard AppKit panel opens at the normal window
  /// level, which is below this floating Settings window, so it was invisible
  /// whenever it was opened from here.
  private func aboutPane() -> NSView {
    self.pane(
      identifier: "pane-about",
      sections: [
        self.section(title: nil, rows: [AboutHeaderView()]),
        self.section(
          title: "Updates",
          footer: "Checks this project's official GitHub Releases. Reserve only notifies and links; it never installs an update.",
          rows: [
            self.automaticUpdateCheckbox(),
            self.updateControls(),
          ]),
        self.section(
          title: "Links",
          rows: [
            self.linkRow("GitHub", symbol: "chevron.left.forwardslash.chevron.right",
              url: ReserveLinks.repository),
            self.linkRow("@pocarles on X", symbol: "at", url: ReserveLinks.xProfile),
          ]),
        self.section(
          title: nil,
          rows: [
            SettingsLabel(
              "© 2026 Pierre-Olivier Carles. MIT License.",
              size: 11, color: .secondaryLabelColor),
            SettingsLabel(
              "Not affiliated with or endorsed by OpenAI, Anthropic, or xAI.",
              size: 11, color: .tertiaryLabelColor),
            SettingsLabel(
              "Made in Florida with love.", size: 11, color: .tertiaryLabelColor),
          ]),
      ])
  }

  private func automaticUpdateCheckbox() -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "Check for updates automatically", target: self,
      action: #selector(self.automaticUpdatesChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("updates-automatic")
    checkbox.state = self.store.automaticUpdateChecks ? .on : .off
    return checkbox
  }

  /// A row that opens a URL, with the standard outward arrow so it reads as
  /// leaving the app.
  private func linkRow(_ title: String, symbol: String, url: URL) -> NSView {
    let button = NSButton(title: "", target: self, action: #selector(self.openLink(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("link-\(url.absoluteString)")
    button.isBordered = false
    button.title = ""
    button.setAccessibilityLabel("\(title), opens in your browser")
    button.toolTip = url.absoluteString

    let icon = NSImageView(
      image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
    icon.contentTintColor = .secondaryLabelColor
    icon.setAccessibilityElement(false)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
    let label = SettingsLabel(title, size: 13, color: .labelColor)
    let arrow = NSImageView(
      image: NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil) ?? NSImage())
    arrow.contentTintColor = .tertiaryLabelColor
    arrow.setAccessibilityElement(false)
    arrow.translatesAutoresizingMaskIntoConstraints = false
    arrow.widthAnchor.constraint(equalToConstant: 12).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

    let row = NSStackView(views: [icon, label, spacer, arrow])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    row.translatesAutoresizingMaskIntoConstraints = false
    button.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: button.leadingAnchor),
      row.trailingAnchor.constraint(equalTo: button.trailingAnchor),
      row.centerYAnchor.constraint(equalTo: button.centerYAnchor),
      button.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth),
      button.heightAnchor.constraint(equalToConstant: 30),
    ])
    return button
  }

  @objc private func openLink(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(of: "link-", with: "")
    guard let url = URL(string: raw), url.scheme == "https" else { return }
    NSWorkspace.shared.open(url)
  }

  @objc private func automaticUpdatesChanged(_ sender: NSButton) {
    self.store.automaticUpdateChecks = sender.state == .on
  }

  private func privacyPane() -> NSView {
    self.pane(
      identifier: "pane-privacy",
      sections: [
        self.section(
          title: nil,
          rows: [
            SettingsLabel(
              "Reserve processes usage information on this Mac.",
              size: 13, weight: .medium, color: .labelColor)
          ]),
        self.section(
          title: "Reserve reads",
          footer: "Reserve reuses the sign-ins of the provider tools you already have. It never "
            + "asks for a password and never stores a token.",
          rows: [
            self.bullets([
              "Claude Code's Keychain item, off until you enable it in Providers",
              "~/.claude/.credentials.json and ~/.grok/auth.json",
              "Session logs under ~/.claude/projects, ~/.codex/sessions and ~/.grok/sessions, "
                + "for token counts only",
            ])
          ]),
        self.section(
          title: "Reserve stores",
          rows: [
            self.bullets([
              "Aggregate token totals",
              "Normalized quota values and reset times",
              "Your preferences",
            ])
          ]),
        self.section(
          title: "Reserve does not store",
          rows: [
            self.bullets([
              "Prompts or responses",
              "Raw provider payloads",
              "OAuth tokens, account identifiers or passwords",
            ])
          ]),
        self.section(
          title: "Reserve contacts",
          footer: "Nothing else. There is no analytics, no telemetry, and no Reserve server.",
          rows: [
            self.bullets([
              "Your providers, to read your limits",
              "Their official status pages",
              "GitHub, only to look for a Reserve update",
            ])
          ]),
        self.section(
          title: "Data",
          footer: "Caches live in Application Support and are removed when you delete Reserve.",
          rows: [self.formRow("Location:", self.dataFolderControls())]),
      ])
  }

  // MARK: - Rows

  private func refreshIntervalControl() -> NSView {
    let popup = NSPopUpButton()
    popup.identifier = NSUserInterfaceItemIdentifier("settings-refresh-interval")
    let intervals = [1, 5, 10, 15, 30]
    popup.addItems(withTitles: intervals.map { "Every \($0) minute\($0 == 1 ? "" : "s")" })
    popup.selectItem(at: intervals.firstIndex(of: self.store.refreshIntervalMinutes) ?? 2)
    popup.target = self
    popup.action = #selector(self.intervalChanged(_:))
    popup.widthAnchor.constraint(equalToConstant: 190).isActive = true
    return popup
  }

  private func launchAtLoginCheckbox() -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "Launch at login", target: self, action: #selector(self.loginChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("settings-launch-at-login")
    checkbox.state = SMAppService.mainApp.status == .enabled ? .on : .off
    return checkbox
  }

  private func menuBarModeControl() -> NSView {
    let popup = NSPopUpButton()
    popup.identifier = NSUserInterfaceItemIdentifier("menu-bar-provider")
    popup.addItems(
      withTitles: ["Automatic"] + ProviderID.allCases.map { "Pinned: \($0.displayName)" })
    let selection =
      self.store.menuBarProvider.flatMap { ProviderID.allCases.firstIndex(of: $0) }
      .map { $0 + 1 } ?? 0
    popup.selectItem(at: selection)
    popup.target = self
    popup.action = #selector(self.menuBarProviderChanged(_:))
    popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
    return popup
  }

  private func menuBarDetailControls() -> NSView {
    let remaining = NSButton(
      checkboxWithTitle: "Percentage left", target: self,
      action: #selector(self.menuBarDetailChanged(_:)))
    remaining.identifier = NSUserInterfaceItemIdentifier("menu-bar-remaining")
    remaining.state = self.store.menuBarShowsRemaining ? .on : .off
    let reset = NSButton(
      checkboxWithTitle: "Reset countdown", target: self,
      action: #selector(self.menuBarDetailChanged(_:)))
    reset.identifier = NSUserInterfaceItemIdentifier("menu-bar-reset")
    reset.state = self.store.menuBarShowsReset ? .on : .off
    let stack = NSStackView(views: [remaining, reset])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 6
    return stack
  }

  private func updateControls() -> NSView {
    // A release found by an earlier check is reported straight away, rather than
    // only while a check happens to be running.
    let found = self.store.availableUpdate
    if let found { self.availableReleaseURL = found.url }
    let statusText: String
    if let found {
      statusText = "Reserve \(found.version) is available"
    } else if let checked = self.store.lastUpdateCheck {
      let ago = DashboardFormat.updated(checked, now: Date())
        .replacingOccurrences(of: "Updated ", with: "")
      statusText = "Up to date · checked \(ago)"
    } else {
      statusText = "Not checked yet"
    }
    let status = SettingsLabel(
      statusText, size: 12,
      color: found == nil ? .secondaryLabelColor : .controlAccentColor)
    status.identifier = NSUserInterfaceItemIdentifier("about-update-status")
    self.updateStatusLabel = status
    let button = NSButton(
      title: found == nil ? "Check for Updates…" : "Open Release",
      target: self, action: #selector(self.checkForUpdates(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("about-check-updates")
    button.bezelStyle = .rounded
    self.updateButton = button
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [status, spacer, button])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    return row
  }

  private func dataFolderControls() -> NSView {
    let button = NSButton(
      title: "Show Data Folder", target: self, action: #selector(self.showDataFolder(_:)))
    button.identifier = NSUserInterfaceItemIdentifier("privacy-data-folder")
    button.bezelStyle = .rounded
    return button
  }

  private func bullets(_ items: [String]) -> NSView {
    let labels = items.map { item -> NSView in
      let dot = SettingsLabel("•", size: 12, color: .tertiaryLabelColor)
      let text = SettingsLabel(item, size: 12, color: .secondaryLabelColor)
      let row = NSStackView(views: [dot, text])
      row.orientation = .horizontal
      row.alignment = .firstBaseline
      row.spacing = 7
      return row
    }
    let stack = NSStackView(views: labels)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 5
    return stack
  }

  private func providerRow(_ provider: ProviderID) -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "", target: self, action: #selector(self.providerChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
    checkbox.state = self.store.isEnabled(provider) ? .on : .off
    checkbox.setAccessibilityLabel("Track \(provider.displayName)")

    let logo = SettingsProviderLogo(provider: provider)
    // The logo carries the brand; the name stays in the system label colour.
    let name = SettingsLabel(provider.displayName, size: 13, weight: .medium, color: .labelColor)
    name.widthAnchor.constraint(equalToConstant: 92).isActive = true
    let plan = SettingsLabel(
      Self.displayPlanName(self.store.states[provider]?.snapshot?.planName),
      size: 12, color: .secondaryLabelColor)
    plan.widthAnchor.constraint(equalToConstant: 118).isActive = true
    let state = self.providerStatus(provider)
    let status = SettingsLabel(state.text, size: 12, color: state.color)
    status.widthAnchor.constraint(equalToConstant: 128).isActive = true
    let updated = SettingsLabel(
      (self.store.states[provider]?.snapshot?.fetchedAt).map {
        DashboardFormat.updated($0, now: Date()).replacingOccurrences(of: "Updated ", with: "")
      } ?? "never",
      size: 12, color: .tertiaryLabelColor)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let disclose = NSButton(
      title: "", target: self, action: #selector(self.toggleProviderDetail(_:)))
    disclose.identifier = NSUserInterfaceItemIdentifier("provider-disclose-\(provider.rawValue)")
    disclose.bezelStyle = .disclosure
    disclose.setButtonType(.pushOnPushOff)
    disclose.state = self.expandedProviders.contains(provider) ? .on : .off
    disclose.setAccessibilityLabel("Show \(provider.displayName) details")

    let row = NSStackView(views: [checkbox, logo, name, plan, status, updated, spacer, disclose])
    row.identifier = NSUserInterfaceItemIdentifier("settings-provider-\(provider.rawValue)")
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    row.heightAnchor.constraint(equalToConstant: 28).isActive = true
    return row
  }

  /// Everything provider-specific lives behind its own row, including the
  /// Claude sign-in permission.
  private func providerDetail(_ provider: ProviderID) -> NSView {
    var rows: [NSView] = [
      self.formRow("Plan:", self.planControls(provider), labelWidth: 92),
      self.formRow("Sources:", self.sourceLabels(provider), labelWidth: 92),
    ]
    if provider == .anthropic {
      let checkbox = NSButton(
        checkboxWithTitle: "Read my Claude Code sign-in from the Keychain",
        target: self, action: #selector(self.keychainChanged(_:)))
      checkbox.identifier = NSUserInterfaceItemIdentifier("settings-automatic-claude")
      checkbox.state = self.store.claudeKeychainReadAllowed ? .on : .off
      checkbox.toolTip =
        "Off by default. Reads Claude Code's Keychain item through Security.framework."
      rows.append(self.formRow("Permissions:", checkbox, labelWidth: 92))
    }
    let refresh = NSButton(
      title: "Refresh Now", target: self, action: #selector(self.refreshProvider(_:)))
    refresh.identifier = NSUserInterfaceItemIdentifier("provider-refresh-\(provider.rawValue)")
    refresh.bezelStyle = .rounded
    rows.append(self.formRow("", refresh, labelWidth: 92))

    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 10
    stack.identifier = NSUserInterfaceItemIdentifier("provider-detail-\(provider.rawValue)")
    stack.edgeInsets = NSEdgeInsets(top: 4, left: 22, bottom: 10, right: 0)
    return stack
  }

  private func planControls(_ provider: ProviderID) -> NSView {
    let currency = SettingsLabel("$", size: 12, color: .secondaryLabelColor)
    let field = SettingsTextField(
      value: String(format: "%.0f", self.store.monthlySubscriptionCost(for: provider)))
    field.identifier = NSUserInterfaceItemIdentifier("subscription.\(provider.rawValue)")
    field.delegate = self
    field.target = self
    field.action = #selector(self.subscriptionCostChanged(_:))
    field.widthAnchor.constraint(equalToConstant: 68).isActive = true
    let suffix = SettingsLabel("per month", size: 12, color: .secondaryLabelColor)

    let reported = self.store.states[provider]?.snapshot?.billingRenewsAt
    let renewalLabel = SettingsLabel(
      self.renewalStatusText(for: provider), size: 12, color: .secondaryLabelColor)
    renewalLabel.identifier = NSUserInterfaceItemIdentifier("renewal-status.\(provider.rawValue)")
    self.renewalStatusLabels[provider] = renewalLabel
    let renewalField = SettingsTextField(
      value: self.store.renewalDay(for: provider).map(String.init) ?? "")
    renewalField.placeholderString = "1–31"
    renewalField.identifier = NSUserInterfaceItemIdentifier("renewal.\(provider.rawValue)")
    renewalField.delegate = self
    renewalField.target = self
    renewalField.action = #selector(self.renewalDayChanged(_:))
    renewalField.toolTip =
      reported == nil
      ? "This provider does not report its billing date. Enter the billing day once."
      : "Provider-reported renewal date"
    renewalField.isHidden = reported != nil
    renewalField.widthAnchor.constraint(equalToConstant: 58).isActive = true
    let dayLabel = SettingsLabel("Billing day", size: 12, color: .secondaryLabelColor)
    dayLabel.isHidden = reported != nil

    let price = NSStackView(views: [currency, field, suffix])
    price.orientation = .horizontal
    price.alignment = .centerY
    price.spacing = 5
    let billing = NSStackView(views: [dayLabel, renewalField, renewalLabel])
    billing.orientation = .horizontal
    billing.alignment = .centerY
    billing.spacing = 6
    let stack = NSStackView(views: [price, billing])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    return stack
  }

  /// Where each number came from, so estimates cannot masquerade as authority.
  private func sourceLabels(_ provider: ProviderID) -> NSView {
    let state = self.store.states[provider]
    let quotaSource = state?.snapshot?.source ?? "not connected"
    let quota = SettingsLabel(
      "Limits · provider reported · \(quotaSource)", size: 12, color: .secondaryLabelColor)
    let tokens = SettingsLabel(
      state?.localUsage == nil
        ? "Tokens · no local logs found"
        : "Tokens · from local logs on this Mac · value estimated",
      size: 12, color: .secondaryLabelColor)
    let freshness = SettingsLabel(
      (state?.snapshot?.fetchedAt).map { DashboardFormat.updated($0, now: Date()) }
        ?? "Never updated",
      size: 12, color: .tertiaryLabelColor)
    let stack = NSStackView(views: [quota, tokens, freshness])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    return stack
  }

  private func insightRow(_ provider: ProviderID) -> NSView {
    let logo = SettingsProviderLogo(provider: provider)
    let name = SettingsLabel(provider.displayName, size: 13, color: .labelColor)
    name.widthAnchor.constraint(equalToConstant: 92).isActive = true
    let usage = self.store.states[provider]?.localUsage
    let today = SettingsLabel(
      usage.map { "\(DashboardFormat.tokens($0.todayTokens)) today" } ?? "No local data",
      size: 12, color: .secondaryLabelColor)
    today.widthAnchor.constraint(equalToConstant: 130).isActive = true
    let rolling = SettingsLabel(
      usage.map { "\(DashboardFormat.tokens($0.totalTokens)) in 30 days" } ?? "—",
      size: 12, color: .secondaryLabelColor)
    rolling.widthAnchor.constraint(equalToConstant: 150).isActive = true
    let value = SettingsLabel(
      usage.map { DashboardFormat.money($0.apiEquivalentCostUSD) } ?? "—",
      size: 12, weight: .medium, color: .labelColor)
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [logo, name, today, rolling, spacer, value])
    row.identifier = NSUserInterfaceItemIdentifier("insight-\(provider.rawValue)")
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    return row
  }

  private func appearanceModeControl() -> NSView {
    let control = NSSegmentedControl(
      labels: AppearanceMode.allCases.map(\.displayName),
      trackingMode: .selectOne,
      target: self,
      action: #selector(self.appearanceModeChanged(_:)))
    control.identifier = NSUserInterfaceItemIdentifier("appearance-mode")
    control.selectedSegment =
      AppearanceMode.allCases.firstIndex(of: self.store.appearanceMode) ?? 0
    control.segmentDistribution = .fillEqually
    control.widthAnchor.constraint(equalToConstant: 220).isActive = true
    return control
  }

  private func chartRow(provider: ProviderID, series: [DailyUsage]) -> NSView {
    let name = SettingsLabel(provider.displayName, size: 12, color: .secondaryLabelColor)
    name.widthAnchor.constraint(equalToConstant: 92).isActive = true
    let chart = ReserveSparkline(series: series, color: ReserveColor.chartPrimary)
    chart.identifier = NSUserInterfaceItemIdentifier("insights-chart-\(provider.rawValue)")
    chart.translatesAutoresizingMaskIntoConstraints = false
    chart.heightAnchor.constraint(equalToConstant: 44).isActive = true
    chart.widthAnchor.constraint(
      equalToConstant: SettingsLayout.contentWidth - 100 - 90).isActive = true
    let peak = series.map(\.tokens).max() ?? 0
    let peakLabel = SettingsLabel(
      "peak \(DashboardFormat.tokens(peak))", size: 11, color: .tertiaryLabelColor)
    peakLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
    peakLabel.alignment = .right
    let row = NSStackView(views: [name, chart, peakLabel])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    return row
  }

  private func accentRow() -> NSView {
    let buttons = AppearanceTheme.allCases.map { theme -> NSView in
      let button = AccentChoiceButton(theme: theme, selected: theme == self.store.appearanceTheme)
      button.identifier = NSUserInterfaceItemIdentifier("appearance-\(theme.rawValue)")
      button.target = self
      button.action = #selector(self.appearanceChanged(_:))
      return button
    }
    let row = NSStackView(views: buttons)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 10
    return row
  }

  private func notificationsEnabledCheckbox() -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: "Enable Reserve notifications", target: self,
      action: #selector(self.notificationsChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("settings-notifications")
    checkbox.state = self.store.notificationsEnabled ? .on : .off
    checkbox.font = .systemFont(ofSize: 13, weight: .medium)
    return checkbox
  }

  private func notificationCheckbox(title: String, key: String) -> NSView {
    let checkbox = NSButton(
      checkboxWithTitle: title, target: self,
      action: #selector(self.notificationPreferenceChanged(_:)))
    checkbox.identifier = NSUserInterfaceItemIdentifier("notification.option.\(key)")
    checkbox.state = self.store.notificationPreference(key) ? .on : .off
    return checkbox
  }

  // MARK: - Layout helpers

  private func pane(identifier: String, sections: [NSView]) -> NSView {
    let root = NSView()
    let stack = NSStackView(views: sections)
    stack.identifier = NSUserInterfaceItemIdentifier(identifier)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 22
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: SettingsLayout.inset),
      stack.trailingAnchor.constraint(
        lessThanOrEqualTo: root.trailingAnchor, constant: -SettingsLayout.inset),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: SettingsLayout.inset),
      stack.bottomAnchor.constraint(
        lessThanOrEqualTo: root.bottomAnchor, constant: -SettingsLayout.inset),
    ])
    root.frame = NSRect(
      x: 0, y: 0, width: SettingsLayout.defaultSize.width, height: SettingsLayout.defaultSize.height)
    root.layoutSubtreeIfNeeded()
    let height = max(
      SettingsLayout.minimumHeight, ceil(stack.frame.height) + 2 * SettingsLayout.inset)
    root.frame = NSRect(
      x: 0, y: 0, width: SettingsLayout.defaultSize.width, height: height)
    root.layoutSubtreeIfNeeded()
    return root
  }

  private func section(title: String?, footer: String? = nil, rows: [NSView]) -> NSView {
    var views: [NSView] = []
    if let title {
      views.append(SettingsLabel(title, size: 11, weight: .semibold, color: .secondaryLabelColor))
    }
    views.append(contentsOf: rows)
    if let footer {
      let label = NSTextField(wrappingLabelWithString: footer)
      label.font = .systemFont(ofSize: 11)
      label.textColor = .tertiaryLabelColor
      label.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
      views.append(label)
    }
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 9
    if title != nil, let first = views.first { stack.setCustomSpacing(11, after: first) }
    if footer != nil, views.count >= 2 {
      stack.setCustomSpacing(11, after: views[views.count - 2])
    }
    return stack
  }

  /// A right-aligned label beside its control, the macOS settings idiom.
  private func formRow(_ label: String, _ control: NSView, labelWidth: CGFloat = 108) -> NSView {
    let caption = SettingsLabel(label, size: 13, color: .labelColor)
    caption.alignment = .right
    caption.widthAnchor.constraint(equalToConstant: labelWidth).isActive = true
    let row = NSStackView(views: [caption, control])
    row.orientation = .horizontal
    row.alignment = .firstBaseline
    row.spacing = 10
    return row
  }

  // MARK: - Actions

  @objc private func providerChanged(_ sender: NSButton) {
    guard let raw = sender.identifier?.rawValue, let provider = ProviderID(rawValue: raw) else {
      return
    }
    self.store.setEnabled(provider, enabled: sender.state == .on)
  }

  @objc private func toggleProviderDetail(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(
      of: "provider-disclose-", with: "")
    guard let provider = ProviderID(rawValue: raw) else { return }
    if self.expandedProviders.contains(provider) {
      self.expandedProviders.remove(provider)
    } else {
      self.expandedProviders.insert(provider)
    }
    self.applyPane(animated: true)
  }

  @objc private func refreshProvider(_ sender: NSButton) {
    let raw = (sender.identifier?.rawValue ?? "").replacingOccurrences(
      of: "provider-refresh-", with: "")
    guard let provider = ProviderID(rawValue: raw) else { return }
    self.store.refresh(provider)
  }

  @objc private func keychainChanged(_ sender: NSButton) {
    self.store.claudeKeychainReadAllowed = sender.state == .on
  }

  @objc private func intervalChanged(_ sender: NSPopUpButton) {
    self.store.refreshIntervalMinutes = [1, 5, 10, 15, 30][max(0, sender.indexOfSelectedItem)]
  }

  @objc private func checkForUpdates(_: NSButton) {
    if let availableReleaseURL, UpdateChecker.isReserveReleaseURL(availableReleaseURL) {
      NSWorkspace.shared.open(availableReleaseURL)
      return
    }
    self.updateStatusLabel?.stringValue = "Checking GitHub Releases…"
    self.updateButton?.isEnabled = false
    Task { [weak self] in
      guard let self else { return }
      let result = await self.updateChecker.check(currentVersion: Self.version)
      self.updateButton?.isEnabled = true
      switch result {
      case .current(let version):
        self.store.lastUpdateCheck = Date()
        self.store.availableUpdate = nil
        self.updateStatusLabel?.stringValue = "Reserve \(version) is up to date"
      case .available(let version, let url):
        self.store.lastUpdateCheck = Date()
        self.store.availableUpdate = (version, url)
        self.availableReleaseURL = url
        self.updateStatusLabel?.stringValue = "Reserve \(version) is available"
        self.updateButton?.title = "Open Release"
      case .unpublished:
        self.updateStatusLabel?.stringValue = "No public Reserve release is published yet"
      case .failed:
        self.updateStatusLabel?.stringValue = "Could not reach GitHub Releases"
      }
    }
  }

  @objc private func showDataFolder(_: NSButton) {
    guard
      let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        .first?.appendingPathComponent("Reserve", isDirectory: true)
    else { return }
    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folder.path)
  }

  @objc private func appearanceModeChanged(_ sender: NSSegmentedControl) {
    let index = max(0, sender.selectedSegment)
    guard AppearanceMode.allCases.indices.contains(index) else { return }
    self.store.appearanceMode = AppearanceMode.allCases[index]
    self.applyPane(animated: false)
  }

  @objc private func appearanceChanged(_ sender: NSButton) {
    guard let identifier = sender.identifier?.rawValue,
      let theme = AppearanceTheme(
        rawValue: identifier.replacingOccurrences(of: "appearance-", with: ""))
    else { return }
    self.store.appearanceTheme = theme
    self.applyPane(animated: false)
  }

  @objc private func menuBarProviderChanged(_ sender: NSPopUpButton) {
    let providerIndex = sender.indexOfSelectedItem - 1
    self.store.menuBarProvider =
      ProviderID.allCases.indices.contains(providerIndex)
      ? ProviderID.allCases[providerIndex] : nil
    self.applyPane(animated: false)
  }

  @objc private func menuBarDetailChanged(_ sender: NSButton) {
    switch sender.identifier?.rawValue {
    case "menu-bar-remaining": self.store.menuBarShowsRemaining = sender.state == .on
    case "menu-bar-reset": self.store.menuBarShowsReset = sender.state == .on
    default: break
    }
    self.applyPane(animated: false)
  }

  @objc private func notificationsChanged(_ sender: NSButton) {
    self.store.notificationsEnabled = sender.state == .on
  }

  @objc private func notificationPreferenceChanged(_ sender: NSButton) {
    guard let key = sender.identifier?.rawValue.split(separator: ".").last else { return }
    self.store.setNotificationPreference(sender.state == .on, name: String(key))
  }

  @objc private func subscriptionCostChanged(_ sender: NSTextField) {
    guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
      let provider = ProviderID(rawValue: String(raw))
    else { return }
    self.store.setMonthlySubscriptionCost(sender.doubleValue, for: provider)
  }

  @objc private func renewalDayChanged(_ sender: NSTextField) {
    guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
      let provider = ProviderID(rawValue: String(raw))
    else { return }
    let trimmed = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      self.store.setRenewalDay(nil, for: provider)
      self.renewalStatusLabels[provider]?.stringValue = self.renewalStatusText(for: provider)
      sender.toolTip = "Enter the billing day, from 1 to 31"
      return
    }
    guard let day = Int(trimmed), (1...31).contains(day) else {
      sender.stringValue = self.store.renewalDay(for: provider).map(String.init) ?? ""
      sender.toolTip = "Enter a day from 1 to 31"
      return
    }
    sender.stringValue = "\(day)"
    sender.toolTip = "Saved · the next billing date is calculated from day \(day)"
    self.store.setRenewalDay(day, for: provider)
    self.renewalStatusLabels[provider]?.stringValue = self.renewalStatusText(for: provider)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      let identifier = field.identifier?.rawValue
    else { return }
    if identifier.hasPrefix("subscription.") {
      self.subscriptionCostChanged(field)
    } else if identifier.hasPrefix("renewal.") {
      self.renewalDayChanged(field)
    }
  }

  func controlTextDidChange(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      let identifier = field.identifier?.rawValue,
      identifier.hasPrefix("renewal.")
    else { return }
    let value = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    field.toolTip = value.isEmpty || Int(value).map({ (1...31).contains($0) }) == true
      ? "Saved when editing ends"
      : "Enter a day from 1 to 31"
  }

  @objc private func loginChanged(_ sender: NSButton) {
    do {
      if sender.state == .on {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
      self.presentError(error)
    }
  }

  // MARK: - Helpers

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
  }

  private static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  }

  private static func displayPlanName(_ value: String?) -> String {
    let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "—" }
    return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
  }

  private static func shortDate(_ date: Date) -> String {
    date.formatted(.dateTime.month(.abbreviated).day())
  }

  private func renewalStatusText(for provider: ProviderID) -> String {
    self.store.nextRenewal(for: provider).map { "Next \(Self.shortDate($0))" } ?? "not set"
  }

  private func providerStatus(_ provider: ProviderID) -> (text: String, color: NSColor) {
    if let state = self.store.states[provider], state.snapshot != nil, state.error == nil {
      return ("Connected", .secondaryLabelColor)
    }
    let executable: String =
      switch provider {
      case .openAI: "codex"
      case .anthropic: "claude"
      case .grok: "grok"
      }
    if BinaryLocator.find(executable) != nil {
      return ("Detected, not signed in", .systemOrange)
    }
    return ("Tool not found", .systemRed)
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { Self.descendants(of: $0) }
  }

  // MARK: - Self test

  func validateForSelfTest() -> (success: Bool, details: String) {
    guard let window = self.window else { return (false, "settings window was not created") }

    func descendants() -> [NSView] {
      window.contentView.map { Self.descendants(of: $0) } ?? []
    }
    func identifiers() -> Set<String> {
      Set(descendants().compactMap { $0.identifier?.rawValue })
    }
    func fits(_ stackID: String) -> Bool {
      guard let content = window.contentView else { return false }
      content.layoutSubtreeIfNeeded()
      return descendants().first { $0.identifier?.rawValue == stackID }.map {
        $0.frame.minY >= -1 && $0.frame.maxY <= content.bounds.height + 1
      } ?? false
    }
    func typographyIsReadable() -> Bool {
      let fonts = descendants().compactMap { ($0 as? NSControl)?.font }
      return !fonts.isEmpty && fonts.allSatisfy { $0.pointSize >= 11 }
    }

    // The window is native: system appearance, resizable, toolbar navigation.
    let isNative =
      window.appearance == nil
      && window.styleMask.contains(.resizable)
      && window.toolbarStyle == .preference
      && window.toolbar?.items.count == Pane.allCases.count
      && window.toolbar?.identifier == "settings-toolbar"
    let staysAboveDashboard = window.level == .floating

    var paneResults: [String] = []
    var allPanesFit = true
    var allPanesReadable = true
    let originalPane = self.pane
    for pane in Pane.allCases {
      self.pane = pane
      self.applyPane(animated: false)
      let fitted = fits("pane-\(pane.rawValue)")
      let readable = typographyIsReadable()
      let noScroll = !descendants().contains { $0 is NSScrollView }
      allPanesFit = allPanesFit && fitted && noScroll
      allPanesReadable = allPanesReadable && readable
      paneResults.append("\(pane.rawValue)=\(fitted && readable && noScroll)")
    }

    // General
    self.pane = .general
    self.applyPane(animated: false)
    let generalIDs = identifiers()
    let intervalPopup = descendants().compactMap { $0 as? NSPopUpButton }.first {
      $0.identifier?.rawValue == "settings-refresh-interval"
    }
    let expectedIntervals = [
      "Every 1 minute", "Every 5 minutes", "Every 10 minutes", "Every 15 minutes",
      "Every 30 minutes",
    ]
    let originalInterval = self.store.refreshIntervalMinutes
    intervalPopup?.selectItem(at: 0)
    let oneMinuteRefreshWorks =
      intervalPopup.flatMap { popup -> Bool? in
        guard let action = popup.action else { return nil }
        return NSApp.sendAction(action, to: popup.target, from: popup)
          && self.store.refreshIntervalMinutes == 1
      } ?? false
    self.store.refreshIntervalMinutes = originalInterval
    let generalSuccess =
      intervalPopup?.itemTitles == expectedIntervals
      && oneMinuteRefreshWorks
      && generalIDs.contains("settings-launch-at-login")
      && generalIDs.contains("menu-bar-provider")
      && generalIDs.contains("menu-bar-remaining")
      && generalIDs.contains("menu-bar-reset")
      && generalIDs.contains("menu-bar-preview")
      // Opacity is gone; system materials adapt on their own.
      && !generalIDs.contains("appearance-window-opacity")

    // Providers, including the per-provider disclosure.
    self.pane = .providers
    self.applyPane(animated: false)
    let providerIDs = identifiers()
    let providerRowsPresent = ProviderID.allCases.allSatisfy {
      providerIDs.contains("settings-provider-\($0.rawValue)")
        && providerIDs.contains("provider-disclose-\($0.rawValue)")
    }
    let claudeIsHiddenUntilExpanded = !providerIDs.contains("settings-automatic-claude")
    self.expandedProviders = [.anthropic]
    self.applyPane(animated: false)
    let expandedIDs = identifiers()
    let renewalField = descendants().compactMap { $0 as? NSTextField }.filter(\.isEditable)
      .first { $0.identifier?.rawValue == "renewal.anthropic" }
    let originalRenewalDay = self.store.renewalDay(for: .anthropic)
    renewalField?.stringValue = "20"
    let renewalInputWorks: Bool
    if let renewalField {
      self.controlTextDidEndEditing(
        Notification(name: NSText.didEndEditingNotification, object: renewalField))
      renewalInputWorks =
        self.store.renewalDay(for: .anthropic) == 20
        && self.store.nextRenewal(for: .anthropic).map {
          Calendar.current.component(.day, from: $0) == 20
        } == true
        && self.renewalStatusLabels[.anthropic]?.stringValue.hasPrefix("Next ") == true
    } else {
      renewalInputWorks = false
    }
    self.store.setRenewalDay(originalRenewalDay, for: .anthropic)
    let providersSuccess =
      providerRowsPresent
      && claudeIsHiddenUntilExpanded
      && expandedIDs.contains("settings-automatic-claude")
      && expandedIDs.contains("subscription.anthropic")
      && expandedIDs.contains("renewal.anthropic")
      && expandedIDs.contains("provider-detail-anthropic")
      && renewalInputWorks
    self.expandedProviders = []

    // Notifications: smart alerts first, thresholds behind Advanced.
    self.pane = .notifications
    self.applyPane(animated: false)
    let notificationIDs = identifiers()
    let notificationLabels = descendants().compactMap { ($0 as? NSButton)?.title }
    let smartKeys = ["deficit", "exhausted", "weeklyRenewal", "stale", "incident"]
    let advancedKeys = ["threshold50", "threshold90", "planRenewal", "fiveHourRenewal", "sound"]
    let notificationsSuccess =
      notificationIDs.contains("settings-notifications")
      && (smartKeys + advancedKeys).allSatisfy {
        notificationIDs.contains("notification.option.\($0)")
      }
      && notificationLabels.contains("Notify at 50% left")
      && notificationLabels.contains("Notify at 10% left")
      && !notificationLabels.contains { $0.hasSuffix("% used") }

    // Appearance keeps the four identities as accents, and light/dark is the
    // system's business.
    self.pane = .appearance
    self.applyPane(animated: false)
    let appearanceIDs = identifiers()
    let originalMode = self.store.appearanceMode
    let modeControl = descendants().compactMap { $0 as? NSSegmentedControl }.first {
      $0.identifier?.rawValue == "appearance-mode"
    }
    modeControl?.selectedSegment = 2
    let appearanceModeWorks =
      modeControl.flatMap { control -> Bool? in
        guard let action = control.action else { return nil }
        return NSApp.sendAction(action, to: control.target, from: control)
          && self.store.appearanceMode == .dark
          && NSApplication.shared.appearance?.name == .darkAqua
      } ?? false
    self.store.appearanceMode = originalMode
    let originalTheme = self.store.appearanceTheme
    self.store.appearanceTheme = .matrix
    let matrixBase = ReserveAppearance.palette.windowBase.usingColorSpace(.sRGB)
    self.store.appearanceTheme = .ocean
    let oceanBase = ReserveAppearance.palette.windowBase.usingColorSpace(.sRGB)
    let accentTokensSwitch =
      self.store.appearanceTheme == .ocean
      && matrixBase?.isEqual(oceanBase) == false
      && ReserveColor.accent.usingColorSpace(.sRGB)?.isEqual(
        AppearanceTheme.ocean.palette.accent.usingColorSpace(.sRGB)) == true
    self.store.appearanceTheme = originalTheme
    let appearanceSuccess =
      AppearanceTheme.allCases.allSatisfy { appearanceIDs.contains("appearance-\($0.rawValue)") }
      && appearanceIDs.contains("theme-preview")
      && appearanceIDs.contains("appearance-mode")
      && !appearanceIDs.contains("menu-bar-provider")
      && !appearanceIDs.contains("menu-bar-remaining")
      && !appearanceIDs.contains("menu-bar-reset")
      && appearanceModeWorks
      && accentTokensSwitch

    // Insights carries the activity numbers the popover no longer shows.
    self.pane = .insights
    self.applyPane(animated: false)
    let insightIDs = identifiers()
    let insightLabels = descendants().compactMap { ($0 as? NSTextField)?.stringValue }
    let insightsSuccess =
      ProviderID.allCases.allSatisfy { insightIDs.contains("insight-\($0.rawValue)") }
      && insightIDs.contains("insights-total")
      && insightLabels.contains { $0.contains("compressed square-root scale") }

    self.pane = .privacy
    self.applyPane(animated: false)
    let privacySuccess = identifiers().contains("privacy-data-folder")

    // About: identity, the update controls, and the links — in one place, and
    // reachable, which the standard AppKit panel was not from a floating window.
    self.pane = .about
    self.applyPane(animated: false)
    let aboutIDs = identifiers()
    let originalAutomatic = self.store.automaticUpdateChecks
    let automaticBox = descendants().compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "updates-automatic"
    }
    automaticBox?.state = originalAutomatic ? .off : .on
    let automaticUpdatesToggle =
      automaticBox.flatMap { box -> Bool? in
        guard let action = box.action else { return nil }
        return NSApp.sendAction(action, to: box.target, from: box)
          && self.store.automaticUpdateChecks == !originalAutomatic
      } ?? false
    self.store.automaticUpdateChecks = originalAutomatic
    let aboutSuccess =
      aboutIDs.contains("about-header")
      && aboutIDs.contains("about-version")
      && aboutIDs.contains("about-check-updates")
      && aboutIDs.contains("updates-automatic")
      && aboutIDs.contains("link-\(ReserveLinks.repository.absoluteString)")
      && aboutIDs.contains("link-\(ReserveLinks.xProfile.absoluteString)")
      && automaticUpdatesToggle
      // The update controls must not also live in General.
      && !generalIDs.contains("about-check-updates")

    self.pane = originalPane
    self.applyPane(animated: false)

    let success =
      isNative && staysAboveDashboard && allPanesFit && allPanesReadable && generalSuccess
      && providersSuccess && notificationsSuccess && appearanceSuccess && insightsSuccess
      && privacySuccess && aboutSuccess
    let details =
      success
      ? "settings is a native toolbar window with \(Pane.allCases.count) resizable panes, one General menu-bar model, adaptive full-surface themes with fixed quota semantics, deficit transition alerts, provider detail behind disclosure, and an About pane carrying identity, updates and links"
      : "settings native=\(isNative), floating=\(staysAboveDashboard), panes=[\(paneResults.joined(separator: ","))], fit=\(allPanesFit), readable=\(allPanesReadable), general=\(generalSuccess), providers=\(providersSuccess), notifications=\(notificationsSuccess), appearance=\(appearanceSuccess), insights=\(insightsSuccess), privacy=\(privacySuccess), about=\(aboutSuccess)"
    return (success, details)
  }

  // MARK: - Rendering

  func render(to url: URL) throws { try self.renderPane(.general, to: url) }
  func renderAbout(to url: URL) throws { try self.renderPane(.about, to: url) }
  func renderAppearance(to url: URL) throws { try self.renderPane(.appearance, to: url) }
  func renderAlerts(to url: URL) throws { try self.renderPane(.notifications, to: url) }
  func renderInsights(to url: URL) throws { try self.renderPane(.insights, to: url) }
  func renderProviders(to url: URL) throws { try self.renderPane(.providers, to: url) }

  private func renderPane(_ pane: Pane, to url: URL) throws {
    self.pane = pane
    if pane == .providers { self.expandedProviders = [.anthropic] }
    self.applyPane(animated: false)
    guard let view = self.window?.contentView else { throw SettingsRenderError.viewUnavailable }
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw SettingsRenderError.bitmapUnavailable
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw SettingsRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }
}

/// A compact live sample of the selected accent family. The three short status
/// marks deliberately retain their semantic colors across every theme.
@MainActor
private final class ThemePreview: NSView {
  private let theme: AppearanceTheme

  init(theme: AppearanceTheme) {
    self.theme = theme
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("theme-preview")
    self.setAccessibilityRole(.group)
    self.setAccessibilityLabel(
      "\(theme.displayName) theme preview with reserve, on pace, and deficit states")
    self.wantsLayer = true
    self.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth).isActive = true
    self.heightAnchor.constraint(equalToConstant: 96).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let palette = self.theme.palette
    let outer = NSBezierPath(roundedRect: self.bounds, xRadius: 12, yRadius: 12)
    palette.windowBase.setFill()
    outer.fill()
    palette.border.setStroke()
    outer.lineWidth = 1
    outer.stroke()

    let card = NSRect(x: 14, y: 14, width: self.bounds.width - 28, height: 68)
    let cardPath = NSBezierPath(roundedRect: card, xRadius: 10, yRadius: 10)
    palette.cardSurface.setFill()
    cardPath.fill()
    palette.border.setStroke()
    cardPath.stroke()

    let title = NSAttributedString(
      string: self.theme.displayName,
      attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
      ])
    title.draw(at: NSPoint(x: card.minX + 13, y: card.maxY - 25))

    palette.progressTrack.setFill()
    let track = NSRect(x: card.minX + 13, y: card.minY + 17, width: card.width - 300, height: 7)
    NSBezierPath(roundedRect: track, xRadius: 3.5, yRadius: 3.5).fill()
    palette.accent.setFill()
    NSBezierPath(
      roundedRect: NSRect(x: track.minX, y: track.minY, width: track.width * 0.62, height: 7),
      xRadius: 3.5, yRadius: 3.5
    ).fill()

    let labels: [(String, NSColor)] = [
      ("Reserve", .systemGreen), ("On pace", .systemBlue), ("Deficit", .systemOrange),
    ]
    var x = track.maxX + 20
    for (text, color) in labels {
      let value = NSAttributedString(
        string: text,
        attributes: [
          .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: color,
        ])
      value.draw(at: NSPoint(x: x, y: card.minY + 13))
      x += value.size().width + 12
    }
  }
}

/// A live preview of what the menu bar will show.
@MainActor
private final class MenuBarPreview: NSView {
  init(store: UsageStore) {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("menu-bar-preview")
    self.setAccessibilityRole(.group)
    self.setAccessibilityLabel(
      store.menuBarProvider.map { "Menu bar preview, \($0.displayName)" }
        ?? "Menu bar preview, Reserve icon")
    self.wantsLayer = true
    self.applyChrome()
    self.layer?.cornerRadius = 6
    self.layer?.borderWidth = 1

    let now = Date()
    let summaries = store.orderedStates.filter { store.isEnabled($0.provider) }
      .map { AllowanceBuilder.summary(for: $0, now: now) }
    let selection = AllowanceBuilder.menuBarSummary(
      from: summaries, pinnedProvider: store.menuBarProvider)
    let image = selection.isPinned
      ? selection.summary.map { ProviderArtwork.image(for: $0.provider) }
      : NSImage(systemSymbolName: "gauge.with.dots.needle.67percent", accessibilityDescription: "Reserve")
    var views: [NSView] = []
    if let image {
      image.size = NSSize(width: 14, height: 14)
      let logo = NSImageView(image: image)
      logo.contentTintColor = image.isTemplate ? .labelColor : nil
      logo.translatesAutoresizingMaskIntoConstraints = false
      logo.widthAnchor.constraint(equalToConstant: 14).isActive = true
      views.append(logo)
    }
    var parts: [String] = []
    if store.menuBarShowsRemaining {
      parts.append(selection.summary?.primary.map { "\(Int($0.remainingPercent.rounded()))%" } ?? "—%")
    }
    if store.menuBarShowsReset { parts.append("2d 4h") }
    if !parts.isEmpty {
      let label = NSTextField(labelWithString: parts.joined(separator: "  "))
      label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
      label.textColor = selection.summary?.paceState.color ?? .secondaryLabelColor
      views.append(label)
    }
    let row = NSStackView(views: views)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 5
    row.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(row)
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 9),
      row.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -9),
      row.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      self.heightAnchor.constraint(equalToConstant: 26),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private func applyChrome() {
    self.layer?.backgroundColor = self.resolvedCGColor(.controlBackgroundColor)
    self.layer?.borderColor = self.resolvedCGColor(.separatorColor)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.applyChrome()
  }
}

/// Each choice previews the theme's surfaces as well as its control accent.
@MainActor
private final class AccentChoiceButton: NSButton {
  private let theme: AppearanceTheme
  private let selected: Bool

  init(theme: AppearanceTheme, selected: Bool) {
    self.theme = theme
    self.selected = selected
    super.init(frame: .zero)
    self.title = ""
    self.isBordered = false
    self.setAccessibilityRole(.radioButton)
    self.setAccessibilityLabel("\(theme.displayName) accent")
    self.setAccessibilityValue(selected ? 1 : 0)
    self.toolTip = "Use the \(theme.displayName) accent"
    self.widthAnchor.constraint(equalToConstant: 76).isActive = true
    self.heightAnchor.constraint(equalToConstant: 56).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  override func draw(_ dirtyRect: NSRect) {
    let palette = self.theme.palette
    let accent = palette.accent
    let swatch = NSRect(x: 0, y: self.bounds.height - 36, width: self.bounds.width, height: 36)
    let path = NSBezierPath(roundedRect: swatch, xRadius: 7, yRadius: 7)
    palette.windowBase.setFill()
    path.fill()
    NSGraphicsContext.saveGraphicsState()
    path.setClip()
    accent.setFill()
    NSRect(x: 9, y: swatch.minY + 9, width: swatch.width - 18, height: 6).fill()
    accent.withAlphaComponent(0.35).setFill()
    NSRect(x: 9, y: swatch.minY + 21, width: (swatch.width - 18) * 0.6, height: 6).fill()
    NSGraphicsContext.restoreGraphicsState()

    if self.selected {
      accent.setStroke()
      let ring = NSBezierPath(roundedRect: swatch.insetBy(dx: 1, dy: 1), xRadius: 6, yRadius: 6)
      ring.lineWidth = 2
      ring.stroke()
    } else {
      palette.border.setStroke()
      let ring = NSBezierPath(
        roundedRect: swatch.insetBy(dx: 0.5, dy: 0.5), xRadius: 6.5, yRadius: 6.5)
      ring.lineWidth = 1
      ring.stroke()
    }

    let name = NSAttributedString(
      string: self.theme.displayName,
      attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: self.selected ? .semibold : .regular),
        .foregroundColor: self.selected ? NSColor.labelColor : NSColor.secondaryLabelColor,
      ])
    name.draw(at: NSPoint(x: (self.bounds.width - name.size().width) / 2, y: 2))
  }
}

/// Reserve's identity: the app's own icon, its version, when this copy was
/// built, and one line on what it is for.
@MainActor
private final class AboutHeaderView: NSView {
  init() {
    super.init(frame: .zero)
    self.identifier = NSUserInterfaceItemIdentifier("about-header")
    self.setAccessibilityRole(.group)
    self.wantsLayer = true
    self.layer?.cornerRadius = 10
    self.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
    self.layer?.borderWidth = 1
    self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

    let icon = NSImageView(image: NSApplication.shared.applicationIconImage ?? NSImage())
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.setAccessibilityElement(false)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 72).isActive = true

    let name = SettingsLabel("Reserve", size: 20, weight: .semibold, color: .labelColor)
    name.alignment = .center
    let version = SettingsLabel(
      "Version \(Self.version) (\(Self.build))", size: 12, color: .secondaryLabelColor)
    version.identifier = NSUserInterfaceItemIdentifier("about-version")
    version.alignment = .center
    let built = SettingsLabel(Self.builtLine(), size: 11, color: .tertiaryLabelColor)
    built.alignment = .center
    let tagline = SettingsLabel(
      "Keep subscription limits, resets and local usage clearly in view.",
      size: 11, color: .tertiaryLabelColor)
    tagline.alignment = .center

    let stack = NSStackView(views: [icon, name, version, built, tagline])
    stack.orientation = .vertical
    stack.alignment = .centerX
    stack.spacing = 3
    stack.setCustomSpacing(10, after: icon)
    stack.setCustomSpacing(6, after: name)
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -20),
      self.widthAnchor.constraint(equalToConstant: SettingsLayout.contentWidth),
    ])
  }

  required init?(coder: NSCoder) { nil }

  private static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
  }

  private static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
  }

  /// Taken from the executable itself, so it describes this copy rather than a
  /// date baked in at some earlier point.
  private static func builtLine() -> String {
    guard let executable = Bundle.main.executableURL,
      let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
      let date = attributes[.modificationDate] as? Date
    else { return "" }
    let formatter = DateFormatter()
    formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
    return "Built \(formatter.string(from: date))"
  }
}

private final class SettingsSeparator: NSView {
  init(width: CGFloat) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(.separatorColor)
    self.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.heightAnchor.constraint(equalToConstant: 1),
      self.widthAnchor.constraint(equalToConstant: width),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(.separatorColor)
  }
}

@MainActor
private final class SettingsProviderLogo: NSView {
  init(provider: ProviderID) {
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(.controlBackgroundColor)
    self.layer?.cornerRadius = 5
    self.setAccessibilityElement(false)
    let image = NSImageView(image: ProviderArtwork.image(for: provider))
    image.setAccessibilityElement(false)
    image.contentTintColor = provider != .anthropic ? .labelColor : nil
    image.imageScaling = .scaleProportionallyUpOrDown
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: 22),
      self.heightAnchor.constraint(equalToConstant: 22),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: 13),
      image.heightAnchor.constraint(equalToConstant: 13),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(.controlBackgroundColor)
  }
}

private final class SettingsTextField: NSTextField {
  convenience init(value: String) {
    self.init(frame: .zero)
    self.stringValue = value
    self.alignment = .right
    self.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
    self.isBezeled = true
    self.bezelStyle = .roundedBezel
    self.formatter = NumberFormatter()
  }
}

private final class SettingsLabel: NSTextField {
  init(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor) {
    super.init(frame: .zero)
    self.stringValue = text
    self.isEditable = false
    self.isSelectable = false
    self.isBezeled = false
    self.drawsBackground = false
    self.font = .systemFont(ofSize: size, weight: weight)
    self.textColor = color
    self.lineBreakMode = .byTruncatingTail
  }

  required init?(coder: NSCoder) { nil }
}

private enum SettingsLayout {
  static let defaultSize = NSSize(width: 680, height: 500)
  static let minimumHeight: CGFloat = 320
  static let inset: CGFloat = 22
  static var contentWidth: CGFloat { self.defaultSize.width - 2 * self.inset }
}

private enum SettingsRenderError: Error {
  case viewUnavailable
  case bitmapUnavailable
  case pngUnavailable
}
