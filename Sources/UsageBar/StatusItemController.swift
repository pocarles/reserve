import AppKit
import UsageBarCore

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
  private let store: UsageStore
  private let openSettings: () -> Void
  private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
  private let popover = NSPopover()
  private lazy var dashboardController = DashboardViewController(
    store: self.store,
    actions: DashboardActions(
      refreshAll: { [weak self] in self?.store.refreshAll() },
      connectAnthropic: { [weak self] in self?.store.connectAnthropic() },
      openSettings: { [weak self] in self?.showSettings() },
      quit: { NSApplication.shared.terminate(nil) }))

  init(store: UsageStore, openSettings: @escaping () -> Void) {
    self.store = store
    self.openSettings = openSettings
    super.init()
    self.statusItem.button?.toolTip = "Usage Bar"
    self.statusItem.button?.target = self
    self.statusItem.button?.action = #selector(self.toggleDashboard)
    self.statusItem.button?.sendAction(on: [.leftMouseUp])
    self.popover.behavior = .transient
    self.popover.animates = true
    self.popover.delegate = self
    self.popover.contentViewController = self.dashboardController
    self.store.onChange = { [weak self] in
      self?.updateStatusIcon()
      self?.dashboardController.update()
    }
    self.updateStatusIcon()
  }

  func showMenu() {
    self.showDashboard()
  }

  func validateForSelfTest() -> (success: Bool, details: String) {
    guard self.statusItem.button?.image != nil else {
      return (false, "status item has no image")
    }
    self.dashboardController.loadViewIfNeeded()
    self.dashboardController.view.layoutSubtreeIfNeeded()
    let descendants = Self.descendants(of: self.dashboardController.view)
    let identifiers = Set(descendants.compactMap { $0.identifier?.rawValue })
    let providerCards = ProviderID.allCases.filter {
      identifiers.contains("provider-card-\($0.rawValue)")
    }.count
    let actionsPresent =
      identifiers.contains("refresh-all")
      && identifiers.contains("connect-anthropic")
      && identifiers.contains("open-settings")
      && identifiers.contains("quit-app")
    let logosPresent = ProviderID.allCases.allSatisfy {
      identifiers.contains("provider-logo-\($0.rawValue)")
    }
    let hasScrollView = descendants.contains { $0 is NSScrollView }
    let contentFits =
      descendants.compactMap { $0 as? NSStackView }.first.map {
        $0.frame.minY >= 0 && $0.frame.maxY <= self.dashboardController.view.bounds.height
      } ?? false
    let dashboardFits =
      self.dashboardController.preferredContentSize.width == 444
      && self.dashboardController.preferredContentSize.height == 748
    let oauthURLParsingIsSafe =
      UsageStore.claudeAuthorizationURL(
        in: "Authenticate at https://claude.com/cai/oauth/authorize?code=sample")?.host
      == "claude.com"
      && UsageStore.claudeAuthorizationURL(
        in: "https://example.com/oauth/authorize?code=not-trusted") == nil
    guard providerCards == ProviderID.allCases.count, actionsPresent, logosPresent,
      !hasScrollView, contentFits, dashboardFits, oauthURLParsingIsSafe
    else {
      return (
        false,
        "dashboard providers=\(providerCards)/\(ProviderID.allCases.count), actions=\(actionsPresent), logos=\(logosPresent), scroll=\(hasScrollView), fits=\(contentFits), size=\(dashboardFits), oauthURL=\(oauthURLParsingIsSafe)"
      )
    }
    return (
      true,
      "dashboard has \(providerCards) provider cards with logos, quota-first layout, reset details, economics, safe Claude OAuth action, and no scrolling"
    )
  }

  func renderDashboard(to url: URL) throws {
    self.dashboardController.loadViewIfNeeded()
    let view = self.dashboardController.view
    view.frame = NSRect(origin: .zero, size: self.dashboardController.preferredContentSize)
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

  @objc private func toggleDashboard() {
    if self.popover.isShown {
      self.popover.performClose(nil)
    } else {
      self.showDashboard()
    }
  }

  private func showDashboard() {
    guard let button = self.statusItem.button else { return }
    self.dashboardController.update()
    self.popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    self.dashboardController.startClock()
  }

  func popoverDidClose(_ notification: Notification) {
    self.dashboardController.stopClock()
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

  private func showSettings() {
    self.popover.performClose(nil)
    self.openSettings()
  }

  private static func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap { self.descendants(of: $0) }
  }
}

private enum DashboardRenderError: Error {
  case bitmapUnavailable
  case pngUnavailable
}
