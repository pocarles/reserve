import AppKit

@main
enum UsageBarApp {
  static func main() {
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime(delegate) {
      application.run()
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  private var store: UsageStore?
  private var statusController: StatusItemController?
  private var settingsController: SettingsWindowController?

  func applicationDidFinishLaunching(_: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
    let store = UsageStore()
    self.store = store
    self.settingsController = SettingsWindowController(store: store)
    self.statusController = StatusItemController(store: store) { [weak self] in
      self?.settingsController?.showWindow(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if CommandLine.arguments.contains("--show-settings") {
      self.settingsController?.showWindow(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    } else if CommandLine.arguments.contains("--show-menu") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.statusController?.showMenu()
      }
    }
  }
}
