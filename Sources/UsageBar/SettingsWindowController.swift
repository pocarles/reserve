import AppKit
import ServiceManagement
import UsageBarCore

@MainActor
final class SettingsWindowController: NSWindowController, NSTextFieldDelegate {
  private let store: UsageStore

  init(store: UsageStore) {
    self.store = store
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 650),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: true)
    window.title = "Usage Bar Settings"
    window.isReleasedWhenClosed = false
    window.center()
    super.init(window: window)
    window.contentView = self.makeContentView()
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
      "settings has \(checkboxes.count) checkboxes, \(subscriptionFields.count) subscription fields, \(popups.count) interval picker, and fitting content"
    return (success, details)
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { Self.descendants(of: $0) }
  }

  private func makeContentView() -> NSView {
    let root = NSView()
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
      stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24),
    ])

    stack.addArrangedSubview(self.heading("Providers"))
    for provider in ProviderID.allCases {
      let button = NSButton(
        checkboxWithTitle: provider.displayName, target: self,
        action: #selector(self.providerChanged(_:)))
      button.identifier = NSUserInterfaceItemIdentifier(provider.rawValue)
      button.state = self.store.isEnabled(provider) ? .on : .off
      stack.addArrangedSubview(button)
    }

    stack.addArrangedSubview(self.heading("Anthropic"))
    let keychain = NSButton(
      checkboxWithTitle: "Allow read-only access to Claude Code credentials in Keychain",
      target: self,
      action: #selector(self.keychainChanged(_:)))
    keychain.state = self.store.claudeKeychainReadAllowed ? .on : .off
    stack.addArrangedSubview(keychain)
    stack.addArrangedSubview(
      self.note("Off by default. Background checks never show a Keychain authentication prompt."))
    stack.addArrangedSubview(
      self.note(
        "If Claude is signed out or expired, click Connect in the dashboard to open Claude's browser sign-in."
      ))

    stack.addArrangedSubview(self.heading("Monthly subscription costs"))
    for provider in ProviderID.allCases {
      stack.addArrangedSubview(self.subscriptionCostRow(provider))
    }
    stack.addArrangedSubview(
      self.note("Used only to compare the rolling 30-day API equivalent with your actual plan."))

    stack.addArrangedSubview(self.heading("Refresh"))
    let popup = NSPopUpButton()
    popup.addItems(withTitles: ["Every 10 minutes", "Every 15 minutes", "Every 30 minutes"])
    popup.selectItem(at: [10, 15, 30].firstIndex(of: self.store.refreshIntervalMinutes) ?? 0)
    popup.target = self
    popup.action = #selector(self.intervalChanged(_:))
    stack.addArrangedSubview(popup)
    stack.addArrangedSubview(
      self.note("Scheduled refreshes are skipped while Low Power Mode is active."))

    stack.addArrangedSubview(self.heading("System"))
    let login = NSButton(
      checkboxWithTitle: "Launch at login", target: self, action: #selector(self.loginChanged(_:)))
    login.state = SMAppService.mainApp.status == .enabled ? .on : .off
    stack.addArrangedSubview(login)

    stack.addArrangedSubview(self.heading("Privacy"))
    stack.addArrangedSubview(
      self.note(
        "The cache contains normalized limits and aggregate 30-day token totals. Local file paths are hashed. OAuth tokens, prompts, responses, account identifiers, and raw provider data are never cached."
      ))
    return root
  }

  private func heading(_ text: String) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = .systemFont(ofSize: 13, weight: .semibold)
    return label
  }

  private func note(_ text: String) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = .systemFont(ofSize: 10)
    label.textColor = .secondaryLabelColor
    label.maximumNumberOfLines = 3
    label.widthAnchor.constraint(equalToConstant: 450).isActive = true
    return label
  }

  private func subscriptionCostRow(_ provider: ProviderID) -> NSView {
    let label = NSTextField(labelWithString: provider.displayName)
    label.font = .systemFont(ofSize: 11)
    label.widthAnchor.constraint(equalToConstant: 105).isActive = true
    let currency = NSTextField(labelWithString: "$")
    currency.textColor = .secondaryLabelColor
    let field = NSTextField(
      string: String(format: "%.0f", self.store.monthlySubscriptionCost(for: provider)))
    field.identifier = NSUserInterfaceItemIdentifier("subscription.\(provider.rawValue)")
    field.alignment = .right
    field.formatter = NumberFormatter()
    field.delegate = self
    field.target = self
    field.action = #selector(self.subscriptionCostChanged(_:))
    field.widthAnchor.constraint(equalToConstant: 70).isActive = true
    let suffix = NSTextField(labelWithString: "/ month")
    suffix.font = .systemFont(ofSize: 10)
    suffix.textColor = .secondaryLabelColor
    let row = NSStackView(views: [label, currency, field, suffix])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 5
    return row
  }

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
