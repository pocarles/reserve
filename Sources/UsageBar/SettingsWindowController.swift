import AppKit
import ServiceManagement
import UsageBarCore

@MainActor
final class SettingsWindowController: NSWindowController {
  private let store: UsageStore

  init(store: UsageStore) {
    self.store = store
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 520),
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
      && popups.first?.itemTitles == expectedIntervals
      && stackFits
    let details =
      "settings has \(checkboxes.count) checkboxes, \(popups.count) interval picker, and fitting content"
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
        "If Claude is signed out or expired, run `claude auth login` in Terminal, then Refresh All."
      ))

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
        "The cache contains normalized usage, reset dates, and provider, plan, and account labels. OAuth tokens, cookies, authorization headers, and raw responses are never cached."
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
