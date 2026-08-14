import AppKit
import ServiceManagement
import UsageBarCore

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
  private let store: UsageStore

  init(store: UsageStore) {
    self.store = store
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 650),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.title = "Usage Bar Settings"
    window.isReleasedWhenClosed = false
    window.titlebarAppearsTransparent = true
    window.backgroundColor = DashboardPalette.background
    super.init(window: window)
    let content = self.makeContentView()
    // Assigning contentView resets the view's frame, so the fitted size has to
    // be captured before the hand-off.
    let fitted = content.frame.size
    window.contentView = content
    window.setContentSize(fitted)
    window.center()
  }

  required init?(coder: NSCoder) { nil }

  override func showWindow(_ sender: Any?) {
    super.showWindow(sender)
    self.window?.center()
  }

  func validateForSelfTest() -> (success: Bool, details: String) {
    guard let window = self.window, let contentView = window.contentView else {
      return (false, "settings window was not created")
    }
    let descendants = Self.descendants(of: contentView)
    contentView.layoutSubtreeIfNeeded()
    let stackFits =
      descendants.compactMap { $0 as? NSStackView }.first.map {
        $0.frame.minY >= 0 && $0.frame.maxY <= contentView.bounds.height
      } ?? false
    let checkboxes = descendants.compactMap { $0 as? NSButton }.filter {
      !($0 is NSPopUpButton)
    }
    let popups = descendants.compactMap { $0 as? NSPopUpButton }
    let subscriptionFields = descendants.compactMap { $0 as? NSTextField }.filter(\.isEditable)
    let checkboxTitles = Set(checkboxes.map(\.title))
    let expectedCheckboxTitles = Set(
      ProviderID.allCases.map(\.displayName)
        + [
          "Allow read-only access to Claude Code credentials in Keychain",
          "Launch at login",
        ])
    let expectedIntervals = ["Every 10 minutes", "Every 15 minutes", "Every 30 minutes"]
    let success =
      window.title == "Usage Bar Settings"
      && checkboxTitles == expectedCheckboxTitles
      && popups.count == 1
      && subscriptionFields.count == ProviderID.allCases.count
      && popups.first?.itemTitles == expectedIntervals
      && stackFits
    let details =
      success
      ? "settings has \(checkboxes.count) checkboxes, \(subscriptionFields.count) subscription fields, \(popups.count) interval picker, and fitting content"
      : "settings title=\(window.title == "Usage Bar Settings"), checkboxes=\(checkboxTitles == expectedCheckboxTitles), popup=\(popups.count), fields=\(subscriptionFields.count), intervals=\(popups.first?.itemTitles == expectedIntervals), fits=\(stackFits)"
    return (success, details)
  }

  /// Writes the settings content to a PNG, used for design verification.
  func render(to url: URL) throws {
    guard let content = self.window?.contentView else { throw SettingsRenderError.noContentView }
    content.layoutSubtreeIfNeeded()
    guard let representation = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
      throw SettingsRenderError.bitmapUnavailable
    }
    content.cacheDisplay(in: content.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw SettingsRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { Self.descendants(of: $0) }
  }

  private func makeContentView() -> NSView {
    let root = DashboardSurface(fill: DashboardPalette.background)
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 8
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Self.inset),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Self.inset),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
    ])

    let title = DashboardLabel(
      "Settings", font: DashboardFont.serif(24, .semibold), color: DashboardPalette.text)
    let subtitle = DashboardLabel(
      "What Usage Bar tracks, and how often it looks.",
      font: DashboardFont.sans(11),
      color: DashboardPalette.muted)
    stack.addArrangedSubview(title)
    stack.addArrangedSubview(subtitle)
    stack.setCustomSpacing(2, after: title)
    stack.setCustomSpacing(22, after: subtitle)

    self.section(stack, "Providers")
    for provider in ProviderID.allCases {
      let button = NSButton(
        checkboxWithTitle: provider.displayName, target: self,
        action: #selector(self.providerChanged(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
      button.state = self.store.isEnabled(provider) ? .on : .off
      button.font = DashboardFont.sans(12)
      stack.addArrangedSubview(button)
    }

    self.section(stack, "Anthropic")
    let keychain = NSButton(
      checkboxWithTitle: "Allow read-only access to Claude Code credentials in Keychain",
      target: self,
      action: #selector(self.keychainChanged(_:)))
    keychain.state = self.store.claudeKeychainReadAllowed ? .on : .off
    keychain.font = DashboardFont.sans(12)
    stack.addArrangedSubview(keychain)
    stack.addArrangedSubview(
      self.note(
        "Off by default. Background checks never show a Keychain authentication prompt. "
          + "If Claude is signed out or expired, click Connect in the dashboard to open Claude's "
          + "browser sign-in."))

    self.section(stack, "Monthly subscription costs")
    for provider in ProviderID.allCases {
      stack.addArrangedSubview(self.subscriptionCostRow(provider))
    }
    stack.addArrangedSubview(
      self.note("Used only to compare the rolling 30-day API equivalent with your actual plan."))

    self.section(stack, "Refresh")
    let popup = NSPopUpButton()
    popup.addItems(withTitles: ["Every 10 minutes", "Every 15 minutes", "Every 30 minutes"])
    popup.selectItem(at: [10, 15, 30].firstIndex(of: self.store.refreshIntervalMinutes) ?? 0)
    popup.target = self
    popup.action = #selector(self.intervalChanged(_:))
    popup.font = DashboardFont.sans(12)
    stack.addArrangedSubview(popup)
    stack.addArrangedSubview(
      self.note("Scheduled refreshes are skipped while Low Power Mode is active."))

    self.section(stack, "System")
    let login = NSButton(
      checkboxWithTitle: "Launch at login", target: self, action: #selector(self.loginChanged(_:)))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    login.font = DashboardFont.sans(12)
    stack.addArrangedSubview(login)

    self.section(stack, "Privacy")
    stack.addArrangedSubview(
      self.note(
        "The cache contains normalized limits and aggregate 30-day token totals. Local file paths are hashed. OAuth tokens, prompts, responses, account identifiers, and raw provider data are never cached."
      ))

    // Wrapping notes only settle once they are laid out at the real width, so
    // the window height is measured from an actual layout pass.
    root.frame = NSRect(x: 0, y: 0, width: Self.width, height: 2000)
    root.layoutSubtreeIfNeeded()
    let height = ceil(stack.frame.height) + 10 + Self.inset
    root.frame = NSRect(x: 0, y: 0, width: Self.width, height: height)
    root.layoutSubtreeIfNeeded()
    return root
  }

  /// Adds a rule and an all-caps heading, matching the dashboard's rhythm.
  private func section(_ stack: NSStackView, _ title: String) {
    if let last = stack.arrangedSubviews.last {
      let rule = DashboardRule(width: Self.width - 2 * Self.inset)
      stack.addArrangedSubview(rule)
      stack.setCustomSpacing(18, after: last)
      stack.setCustomSpacing(14, after: rule)
    }
    let heading = DashboardLabel.caption(title, color: DashboardPalette.subtle)
    stack.addArrangedSubview(heading)
    stack.setCustomSpacing(9, after: heading)
  }

  private func note(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = DashboardFont.sans(10.5)
    label.textColor = DashboardPalette.muted
    label.maximumNumberOfLines = 4
    label.widthAnchor.constraint(equalToConstant: Self.width - 2 * Self.inset).isActive = true
    return label
  }

  private func subscriptionCostRow(_ provider: ProviderID) -> NSView {
    let label = DashboardLabel(
      provider.displayName, font: DashboardFont.sans(12), color: DashboardPalette.text
    ).width(120)
    let currency = DashboardLabel(
      "$", font: DashboardFont.sans(11), color: DashboardPalette.subtle)
    let field = NSTextField(
      string: String(format: "%.0f", self.store.monthlySubscriptionCost(for: provider)))
    field.identifier = NSUserInterfaceItemIdentifier("subscription.\(provider.rawValue)")
    field.alignment = .right
    field.font = DashboardFont.digits(12)
    field.formatter = NumberFormatter()
    field.delegate = self
    field.target = self
    field.action = #selector(self.subscriptionCostChanged(_:))
    field.widthAnchor.constraint(equalToConstant: 70).isActive = true
    let suffix = DashboardLabel(
      "per month", font: DashboardFont.sans(10.5), color: DashboardPalette.muted)
    let row = NSStackView(views: [label, currency, field, suffix])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 6
    return row
  }

  private static let width: CGFloat = 480
  private static let inset: CGFloat = 26

  @objc private func providerChanged(_ sender: NSButton) {
    guard let raw = sender.identifier?.rawValue, let provider = ProviderID(rawValue: raw) else {
      return
    }
    self.store.setEnabled(provider, enabled: sender.state == .on)
  }

  @objc private func keychainChanged(_ sender: NSButton) {
    self.store.claudeKeychainReadAllowed = sender.state == .on
  }

  @objc private func intervalChanged(_ sender: NSPopUpButton) {
    self.store.refreshIntervalMinutes = [10, 15, 30][max(0, sender.indexOfSelectedItem)]
  }

  @objc private func subscriptionCostChanged(_ sender: NSTextField) {
    guard let raw = sender.identifier?.rawValue.split(separator: ".").last,
      let provider = ProviderID(rawValue: String(raw))
    else { return }
    self.store.setMonthlySubscriptionCost(sender.doubleValue, for: provider)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    guard let field = notification.object as? NSTextField,
      field.identifier?.rawValue.hasPrefix("subscription.") == true
    else { return }
    self.subscriptionCostChanged(field)
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
}

private enum SettingsRenderError: Error {
  case noContentView
  case bitmapUnavailable
  case pngUnavailable
}
