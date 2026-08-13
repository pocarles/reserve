import AppKit
import UsageBarCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
  private let store: UsageStore
  private let openSettings: () -> Void
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

  init(store: UsageStore, openSettings: @escaping () -> Void) {
    self.store = store
    self.openSettings = openSettings
    super.init()
    self.statusItem.button?.toolTip = "Usage Bar"
    let menu = NSMenu()
    menu.delegate = self
    self.statusItem.menu = menu
    self.store.onChange = { [weak self] in self?.updateStatusIcon() }
    self.updateStatusIcon()
  }

  func menuWillOpen(_ menu: NSMenu) {
    self.rebuild(menu)
  }

  func showMenu() {
    self.statusItem.button?.performClick(nil)
  }

  func validateForSelfTest() -> (success: Bool, details: String) {
    guard self.statusItem.button?.image != nil else {
      return (false, "status item has no image")
    }
    let menu = NSMenu()
    self.rebuild(menu)
    let providerViews = menu.items.filter { $0.view is ProviderMenuView }.count
    let titles = Set(menu.items.map(\.title))
    let expectedProviders = ProviderID.allCases.count
    let actionsPresent =
      titles.contains("Refresh All")
      && titles.contains("Settings…")
      && titles.contains("Quit Usage Bar")
    let resetView = UsageWindowView(
      window: UsageWindow(
        id: "self-test",
        label: "Weekly",
        usedPercent: 42,
        resetsAt: Date().addingTimeInterval(3600)))
    let resetDeadlinePresent = resetView.subviews.compactMap { $0 as? NSTextField }
      .contains { $0.stringValue.hasPrefix("Resets ") }
    guard providerViews == expectedProviders, actionsPresent, resetDeadlinePresent else {
      return (
        false,
        "menu providers=\(providerViews)/\(expectedProviders), actions=\(actionsPresent), resets=\(resetDeadlinePresent)"
      )
    }
    return (
      true,
      "status menu has \(providerViews) provider cards, reset deadlines, and all actions"
    )
  }

  private func updateStatusIcon() {
    let image =
      NSImage(
        systemSymbolName: self.store.statusSymbol,
        accessibilityDescription: "AI subscription usage")
      ?? NSImage(named: NSImage.statusAvailableName)
    image?.isTemplate = true
    self.statusItem.button?.image = image
  }

  private func rebuild(_ menu: NSMenu) {
    menu.removeAllItems()
    let title = NSMenuItem(title: "Usage Bar", action: nil, keyEquivalent: "")
    title.isEnabled = false
    title.attributedTitle = NSAttributedString(
      string: "Usage Bar",
      attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)])
    menu.addItem(title)
    menu.addItem(.separator())

    for state in self.store.orderedStates where self.store.isEnabled(state.provider) {
      let item = NSMenuItem()
      item.view = ProviderMenuView(state: state)
      menu.addItem(item)
    }

    menu.addItem(.separator())
    let refresh = NSMenuItem(
      title: self.store.isRefreshingAll ? "Refreshing…" : "Refresh All",
      action: #selector(self.refreshAll),
      keyEquivalent: "r")
    refresh.target = self
    refresh.isEnabled = !self.store.isRefreshingAll
    menu.addItem(refresh)

    let settings = NSMenuItem(
      title: "Settings…", action: #selector(self.showSettings), keyEquivalent: ",")
    settings.target = self
    menu.addItem(settings)

    let quit = NSMenuItem(title: "Quit Usage Bar", action: #selector(self.quit), keyEquivalent: "q")
    quit.target = self
    menu.addItem(quit)
  }

  @objc private func refreshAll() { self.store.refreshAll() }
  @objc private func showSettings() { self.openSettings() }
  @objc private func quit() { NSApplication.shared.terminate(nil) }
}

@MainActor
private final class ProviderMenuView: NSView {
  init(state: ProviderViewState) {
    let width: CGFloat = 318
    let windowCount = max(1, state.snapshot?.windows.count ?? 0)
    let errorHeight: CGFloat = state.error == nil ? 0 : 34
    let height: CGFloat = 54 + CGFloat(windowCount * 52) + errorHeight
    super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))

    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 7
    stack.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 14),
      stack.trailingAnchor.constraint(equalTo: self.trailingAnchor, constant: -14),
      stack.topAnchor.constraint(equalTo: self.topAnchor, constant: 9),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: self.bottomAnchor, constant: -9),
    ])

    let header = NSTextField(labelWithString: self.headerText(state))
    header.font = .systemFont(ofSize: 12, weight: .semibold)
    if state.isStale { header.textColor = .systemOrange }
    stack.addArrangedSubview(header)

    if let snapshot = state.snapshot {
      for window in snapshot.windows {
        stack.addArrangedSubview(UsageWindowView(window: window))
      }
      let source = NSTextField(labelWithString: snapshot.source)
      source.font = .systemFont(ofSize: 9)
      source.textColor = .tertiaryLabelColor
      stack.addArrangedSubview(source)
    } else if state.isRefreshing {
      let label = NSTextField(labelWithString: "Checking usage…")
      label.textColor = .secondaryLabelColor
      label.font = .systemFont(ofSize: 11)
      stack.addArrangedSubview(label)
    }

    if let error = state.error {
      let label = NSTextField(wrappingLabelWithString: error)
      label.font = .systemFont(ofSize: 10)
      label.textColor = state.snapshot == nil ? .systemRed : .secondaryLabelColor
      label.maximumNumberOfLines = 2
      stack.addArrangedSubview(label)
      label.widthAnchor.constraint(equalToConstant: width - 28).isActive = true
    }
  }

  required init?(coder: NSCoder) { nil }

  private func headerText(_ state: ProviderViewState) -> String {
    var parts = [state.provider.displayName]
    if let plan = state.snapshot?.planName, !plan.isEmpty { parts.append(plan) }
    if state.isRefreshing { parts.append("· refreshing") }
    return parts.joined(separator: "  ")
  }
}

@MainActor
private final class UsageWindowView: NSView {
  init(window: UsageWindow) {
    super.init(frame: NSRect(x: 0, y: 0, width: 290, height: 45))
    let label = NSTextField(labelWithString: window.label)
    label.font = .systemFont(ofSize: 10)
    label.textColor = .secondaryLabelColor
    label.translatesAutoresizingMaskIntoConstraints = false

    let value = NSTextField(labelWithString: String(format: "%.0f%%", window.usedPercent))
    value.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
    value.alignment = .right
    value.translatesAutoresizingMaskIntoConstraints = false

    let bar = NSProgressIndicator()
    bar.style = .bar
    bar.minValue = 0
    bar.maxValue = 100
    bar.doubleValue = window.usedPercent
    bar.isIndeterminate = false
    bar.translatesAutoresizingMaskIntoConstraints = false

    let reset = NSTextField(
      labelWithString: window.resetsAt.map {
        "Resets \($0.formatted(date: .abbreviated, time: .shortened))"
      } ?? "Reset time unavailable")
    reset.font = .systemFont(ofSize: 9)
    reset.textColor = .tertiaryLabelColor
    reset.translatesAutoresizingMaskIntoConstraints = false

    self.addSubview(label)
    self.addSubview(value)
    self.addSubview(bar)
    self.addSubview(reset)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      label.topAnchor.constraint(equalTo: self.topAnchor),
      value.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      value.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
      bar.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      bar.trailingAnchor.constraint(equalTo: self.trailingAnchor),
      bar.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 4),
      bar.heightAnchor.constraint(equalToConstant: 5),
      reset.leadingAnchor.constraint(equalTo: self.leadingAnchor),
      reset.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 3),
      self.widthAnchor.constraint(equalToConstant: 290),
      self.heightAnchor.constraint(equalToConstant: 45),
    ])
  }

  required init?(coder: NSCoder) { nil }
}
