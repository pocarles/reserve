import AppKit
import Darwin

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
    let isUISelfTest = CommandLine.arguments.contains("--self-test-ui")
    let renderIndex = CommandLine.arguments.firstIndex(of: "--render-dashboard")
    let isDashboardRender = renderIndex != nil
    let store: UsageStore
    if isUISelfTest || isDashboardRender {
      let testDefaults = UserDefaults(
        suiteName: "UsageBar.UISelfTest.\(UUID().uuidString)")!
      store = UsageStore(defaults: testDefaults, startAutomatically: false)
    } else {
      store = UsageStore()
    }
    if isDashboardRender { store.installPreviewSnapshots() }
    self.store = store
    self.settingsController = SettingsWindowController(store: store)
    self.statusController = StatusItemController(store: store) { [weak self] in
      self?.settingsController?.showWindow(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
    if let renderIndex,
      CommandLine.arguments.indices.contains(renderIndex + 1)
    {
      self.renderDashboard(path: CommandLine.arguments[renderIndex + 1])
    } else if isUISelfTest {
      self.runUISelfTest()
    } else if CommandLine.arguments.contains("--show-settings") {
      self.settingsController?.showWindow(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    } else if CommandLine.arguments.contains("--show-menu") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.statusController?.showMenu()
      }
    }
  }

  private func renderDashboard(path: String) {
    guard let statusController = self.statusController else {
      Self.finishUISelfTest(success: false, details: "dashboard controller was not created")
      return
    }
    do {
      try statusController.renderDashboard(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "dashboard rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "dashboard render failed: \(error)")
    }
  }

  private func runUISelfTest() {
    guard let statusController = self.statusController,
      let settingsController = self.settingsController
    else {
      Self.finishUISelfTest(success: false, details: "controllers were not created")
      return
    }

    let statusResult = statusController.validateForSelfTest()
    let settingsResult = settingsController.validateForSelfTest()
    let success = statusResult.success && settingsResult.success
    let details = [statusResult.details, settingsResult.details].joined(separator: "; ")
    Self.finishUISelfTest(success: success, details: details)
  }

  private static func finishUISelfTest(success: Bool, details: String) {
    let prefix = success ? "PASS" : "FAIL"
    FileHandle.standardOutput.write(Data("\(prefix) AppKit UI: \(details)\n".utf8))
    fflush(stdout)
    exit(success ? 0 : 1)
  }
}
