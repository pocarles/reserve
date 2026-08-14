import AppKit
import Darwin
import ServiceManagement
import UsageBarCore

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
    let settingsRenderIndex = CommandLine.arguments.firstIndex(of: "--render-settings")
    let appearanceRenderIndex = CommandLine.arguments.firstIndex(of: "--render-appearance")
    let aboutRenderIndex = CommandLine.arguments.firstIndex(of: "--render-about")
    let alertsRenderIndex = CommandLine.arguments.firstIndex(of: "--render-alerts")
    let insightsRenderIndex = CommandLine.arguments.firstIndex(of: "--render-insights")
    let providersRenderIndex = CommandLine.arguments.firstIndex(of: "--render-providers")
    let menuBarRenderIndex = CommandLine.arguments.firstIndex(of: "--render-menu-bar")
    let isUIStressTest = CommandLine.arguments.contains("--stress-ui")
    let isDashboardRender = renderIndex != nil
    let isSettingsRender = settingsRenderIndex != nil
    let isAppearanceRender = appearanceRenderIndex != nil
    let isAboutRender = aboutRenderIndex != nil
    let store: UsageStore
    if isUISelfTest || isDashboardRender || isSettingsRender || isAppearanceRender
      || isAboutRender || alertsRenderIndex != nil || insightsRenderIndex != nil
      || providersRenderIndex != nil || menuBarRenderIndex != nil || isUIStressTest
    {
      let testDefaults = UserDefaults(
        suiteName: "UsageBar.UISelfTest.\(UUID().uuidString)")!
      store = UsageStore(defaults: testDefaults, startAutomatically: false)
    } else {
      store = UsageStore()
    }
    if isUISelfTest || isDashboardRender || isSettingsRender || isAppearanceRender || isAboutRender
      || alertsRenderIndex != nil || insightsRenderIndex != nil || providersRenderIndex != nil
      || menuBarRenderIndex != nil || isUIStressTest
    {
      let scenario = CommandLine.arguments.firstIndex(of: "--scenario").flatMap { index in
        CommandLine.arguments.indices.contains(index + 1)
          ? PreviewScenario(rawValue: CommandLine.arguments[index + 1]) : nil
      } ?? .deficit
      store.installPreviewSnapshots(scenario: scenario)
    }
    if let index = CommandLine.arguments.firstIndex(of: "--appearance"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      store.appearanceMode =
        AppearanceMode(rawValue: CommandLine.arguments[index + 1]) ?? .system
    }
    if let index = CommandLine.arguments.firstIndex(of: "--accent"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      store.appearanceTheme =
        AppearanceTheme(rawValue: CommandLine.arguments[index + 1]) ?? .matrix
    }
    if let raw = ProcessInfo.processInfo.environment["RESERVE_EXPAND"],
      let provider = ProviderID(rawValue: raw)
    {
      store.expandedProvider = provider
    }
    if let index = CommandLine.arguments.firstIndex(of: "--menu-provider"),
      CommandLine.arguments.indices.contains(index + 1)
    {
      let value = CommandLine.arguments[index + 1]
      store.menuBarProvider = value == "automatic" ? nil : ProviderID(rawValue: value)
      // Menu-bar QA captures exercise the complete icon + percentage + reset
      // configuration. Icon-only behavior remains covered by the UI self-test.
      store.menuBarShowsRemaining = true
      store.menuBarShowsReset = true
    }
    self.store = store
    NotificationCenter.default.addObserver(
      self, selector: #selector(self.applicationBecameActive),
      name: NSApplication.didBecomeActiveNotification, object: nil)
    NSWorkspace.shared.notificationCenter.addObserver(
      self, selector: #selector(self.computerDidWake),
      name: NSWorkspace.didWakeNotification, object: nil)
    self.statusController = StatusItemController(
      store: store,
      openSettings: { [weak self] in self?.showSettings() },
      openInsights: { [weak self] in self?.showInsights() },
      isSettingsWindow: { [weak self] window in
        guard let window else { return false }
        return self?.settingsController?.window === window
      })
    if let renderIndex,
      CommandLine.arguments.indices.contains(renderIndex + 1)
    {
      self.renderDashboard(path: CommandLine.arguments[renderIndex + 1])
    } else if let settingsRenderIndex,
      CommandLine.arguments.indices.contains(settingsRenderIndex + 1)
    {
      self.renderSettings(path: CommandLine.arguments[settingsRenderIndex + 1])
    } else if let appearanceRenderIndex,
      CommandLine.arguments.indices.contains(appearanceRenderIndex + 1)
    {
      self.renderAppearance(path: CommandLine.arguments[appearanceRenderIndex + 1])
    } else if let aboutRenderIndex,
      CommandLine.arguments.indices.contains(aboutRenderIndex + 1)
    {
      self.renderAbout(path: CommandLine.arguments[aboutRenderIndex + 1])
    } else if let alertsRenderIndex,
      CommandLine.arguments.indices.contains(alertsRenderIndex + 1)
    {
      self.renderAlerts(path: CommandLine.arguments[alertsRenderIndex + 1])
    } else if let insightsRenderIndex,
      CommandLine.arguments.indices.contains(insightsRenderIndex + 1)
    {
      self.renderInsights(path: CommandLine.arguments[insightsRenderIndex + 1])
    } else if let providersRenderIndex,
      CommandLine.arguments.indices.contains(providersRenderIndex + 1)
    {
      self.renderProviders(path: CommandLine.arguments[providersRenderIndex + 1])
    } else if let menuBarRenderIndex,
      CommandLine.arguments.indices.contains(menuBarRenderIndex + 1)
    {
      self.renderMenuBar(path: CommandLine.arguments[menuBarRenderIndex + 1])
    } else if CommandLine.arguments.contains("--verify-notifications") {
      self.verifyNotifications()
    } else if isUIStressTest {
      self.runUIStressTest()
    } else if isUISelfTest {
      self.runUISelfTest()
    } else if CommandLine.arguments.contains("--show-settings") {
      self.showSettings()
    } else if CommandLine.arguments.contains("--show-menu") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.statusController?.showMenu()
      }
    } else {
      self.completeFirstLaunchIfNeeded()
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

  private func renderMenuBar(path: String) {
    guard let statusController = self.statusController else {
      Self.finishUISelfTest(success: false, details: "status controller was not created")
      return
    }
    do {
      try statusController.renderMenuBar(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "menu bar rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "menu bar render failed: \(error)")
    }
  }

  private func renderSettings(path: String) {
    guard let settingsController = self.settingsControllerForUse() else {
      Self.finishUISelfTest(success: false, details: "settings controller was not created")
      return
    }
    do {
      try settingsController.render(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "settings rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "settings render failed: \(error)")
    }
  }

  private func renderAbout(path: String) {
    guard let settingsController = self.settingsControllerForUse() else {
      Self.finishUISelfTest(success: false, details: "settings controller was not created")
      return
    }
    do {
      try settingsController.renderAbout(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "about rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "about render failed: \(error)")
    }
  }

  /// Drives the real notification path with synthetic transitions and reports
  /// what macOS actually accepted. Delivered notices are withdrawn afterwards so
  /// the check leaves nothing behind.
  private func verifyNotifications() {
    // A single fixed suite, cleared on entry: cfprefsd rewrites the file on
    // exit, so a per-run name would leave a trail of plists behind.
    let suite = "UsageBar.NotificationCheck"
    let plist = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(suite).plist")
    try? FileManager.default.removeItem(at: plist)
    guard let defaults = UserDefaults(suiteName: suite) else {
      Self.finishUISelfTest(success: false, details: "could not create a defaults suite")
      return
    }
    for key in ["enabled", "deficit", "exhausted", "weeklyRenewal", "stale", "incident"] {
      defaults.set(true, forKey: "notifications.\(key)")
    }
    defaults.set(false, forKey: "notifications.sound")
    let notifications = ReserveNotifications(defaults: defaults, active: true)

    Task { @MainActor in
      let authorization = await notifications.authorizationSummary()
      let now = Date()
      let reset = now.addingTimeInterval(3 * 24 * 3_600)
      func weekly(_ used: Double) -> UsageSnapshot {
        UsageSnapshot(
          provider: .openAI,
          planName: "Pro",
          windows: [
            UsageWindow(
              id: "weekly", label: "Weekly", usedPercent: used,
              windowMinutes: 7 * 24 * 60, resetsAt: reset)
          ],
          fetchedAt: now,
          source: "notification check")
      }

      // The deficit alert has to come out of the real transition path.
      notifications.update(previous: weekly(2), current: weekly(85), nextPlanRenewal: nil, now: now)
      notifications.deliver(
        .dataStale(provider: .grok, lastUpdated: now.addingTimeInterval(-34 * 60)), now: now)
      notifications.deliver(
        .serviceIncident(
          provider: .anthropic, health: .degraded, detail: "Partial system degradation"))

      try? await Task.sleep(for: .seconds(3))
      let delivered = Set(await notifications.deliveredIdentifiers())
      let standing = await Self.verifyStandingConditions(defaults: defaults)
      let expected = [
        "deficit": "reserve.deficit.openAI.weekly.\(Int(reset.timeIntervalSince1970))",
        "stale": "reserve.stale.grok",
        "incident": "reserve.incident.anthropic",
      ]
      let results = expected.map { name, identifier in
        "\(name)=\(delivered.contains(identifier) ? "delivered" : "MISSING")"
      }.sorted()
      notifications.removeDelivered(Array(expected.values))
      try? await Task.sleep(for: .seconds(1))
      let remaining = Set(await notifications.deliveredIdentifiers())
        .intersection(expected.values)
      // removePersistentDomain alone leaves the plist on disk until the next
      // sync, and this process is about to exit.
      defaults.removePersistentDomain(forName: suite)
      defaults.synchronize()

      let success =
        expected.values.allSatisfy(delivered.contains) && remaining.isEmpty && standing.success
      Self.finishUISelfTest(
        success: success,
        details:
          "authorization \(authorization); \(results.joined(separator: ", ")); "
          + "withdrawn=\(remaining.isEmpty); \(standing.detail)")
    }
  }

  /// Exercises the standing-condition triggers themselves — the store methods a
  /// refresh calls — through enter, persist and recover.
  private static func verifyStandingConditions(
    defaults: UserDefaults
  ) async -> (success: Bool, detail: String) {
    let store = UsageStore(
      defaults: defaults, startAutomatically: false, notificationsActive: true)
    let notifications = ReserveNotifications(defaults: defaults, active: true)
    let now = Date()

    // Enter: both standing conditions should raise exactly one alert each.
    let ids = store.exerciseStandingConditions(.enter, now: now)
    try? await Task.sleep(for: .seconds(2))
    let afterEnter = Set(await notifications.deliveredIdentifiers())
    let entered = afterEnter.contains(ids.stale) && afterEnter.contains(ids.incident)

    // Persist: with the alerts cleared by hand, a still-bad condition must not
    // raise them again.
    notifications.removeDelivered([ids.stale, ids.incident])
    try? await Task.sleep(for: .seconds(1))
    store.exerciseStandingConditions(.persist, now: now)
    try? await Task.sleep(for: .seconds(2))
    let afterPersist = Set(await notifications.deliveredIdentifiers())
    let didNotRepeat =
      !afterPersist.contains(ids.stale) && !afterPersist.contains(ids.incident)

    // Recover: the conditions clear and stop being tracked.
    store.exerciseStandingConditions(.recover, now: now)
    try? await Task.sleep(for: .seconds(1))
    let afterRecover = Set(await notifications.deliveredIdentifiers())
    let cleared =
      !afterRecover.contains(ids.stale) && !afterRecover.contains(ids.incident)
      && !store.standingConditionsAreTracked

    notifications.removeDelivered([ids.stale, ids.incident])
    let success = entered && didNotRepeat && cleared
    return (
      success,
      "triggers: enter=\(entered), noRepeat=\(didNotRepeat), recover=\(cleared)"
    )
  }

  private func renderProviders(path: String) {
    guard let settingsController = self.settingsControllerForUse() else {
      Self.finishUISelfTest(success: false, details: "settings controller was not created")
      return
    }
    do {
      try settingsController.renderProviders(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "providers rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "providers render failed: \(error)")
    }
  }

  private func renderInsights(path: String) {
    guard let settingsController = self.settingsControllerForUse() else {
      Self.finishUISelfTest(success: false, details: "settings controller was not created")
      return
    }
    do {
      try settingsController.renderInsights(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "insights rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "insights render failed: \(error)")
    }
  }

  private func renderAlerts(path: String) {
    guard let settingsController = self.settingsControllerForUse() else {
      Self.finishUISelfTest(success: false, details: "settings controller was not created")
      return
    }
    do {
      try settingsController.renderAlerts(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "alerts rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "alerts render failed: \(error)")
    }
  }

  private func renderAppearance(path: String) {
    guard let settingsController = self.settingsControllerForUse() else {
      Self.finishUISelfTest(success: false, details: "settings controller was not created")
      return
    }
    do {
      try settingsController.renderAppearance(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(success: true, details: "appearance rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "appearance render failed: \(error)")
    }
  }

  private func completeFirstLaunchIfNeeded() {
    let defaults = UserDefaults.standard
    let key = "onboarding.firstLaunchCompleted"
    guard !defaults.bool(forKey: key) else { return }
    defaults.set(true, forKey: key)
    if Bundle.main.bundleURL.pathExtension == "app", SMAppService.mainApp.status == .notRegistered {
      try? SMAppService.mainApp.register()
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      self?.statusController?.showMenu()
    }
  }

  @objc private func applicationBecameActive() {
    self.store?.refreshAfterResumeIfNeeded()
  }

  @objc private func computerDidWake() {
    self.store?.refreshAfterResumeIfNeeded()
  }

  private func runUISelfTest() {
    guard let statusController = self.statusController,
      let settingsController = self.settingsControllerForUse()
    else {
      Self.finishUISelfTest(success: false, details: "controllers were not created")
      return
    }

    let statusResult = statusController.validateForSelfTest(settingsWindow: settingsController.window)
    let settingsResult = settingsController.validateForSelfTest()
    let success = statusResult.success && settingsResult.success
    let details = [statusResult.details, settingsResult.details].joined(separator: "; ")
    Self.finishUISelfTest(success: success, details: details)
  }

  /// Repeatedly realizes and dismisses both native UI surfaces. This is a
  /// developer-only release gate for lifecycle crashes and runaway view growth.
  private func runUIStressTest() {
    guard let statusController = self.statusController,
      let settingsController = self.settingsControllerForUse()
    else {
      Self.finishUISelfTest(success: false, details: "stress-test controllers were not created")
      return
    }
    Task { @MainActor in
      // Warm both lazily created surfaces first; the comparison is about
      // repeated-cycle growth, not AppKit's one-time window-server allocation.
      statusController.setStressTestAnimationsEnabled(false)
      statusController.showMenu()
      try? await Task.sleep(for: .milliseconds(100))
      statusController.closeMenuForStressTest()
      settingsController.showWindow(nil)
      settingsController.window?.orderOut(nil)
      try? await Task.sleep(for: .seconds(3))
      let footprintBefore = Self.physicalFootprintBytes()
      for _ in 0..<30 {
        statusController.showMenu()
        try? await Task.sleep(for: .milliseconds(100))
        statusController.closeMenuForStressTest()
        try? await Task.sleep(for: .milliseconds(100))
        settingsController.showWindow(nil)
        try? await Task.sleep(for: .milliseconds(50))
        settingsController.window?.orderOut(nil)
        try? await Task.sleep(for: .milliseconds(50))
      }
      try? await Task.sleep(for: .seconds(3))
      let footprintAfter = Self.physicalFootprintBytes()
      let beforeMB = footprintBefore.map { Double($0) / 1_048_576 }
      let afterMB = footprintAfter.map { Double($0) / 1_048_576 }
      let memoryDetails: String
      if let beforeMB, let afterMB {
        memoryDetails = String(
          format: ", physical footprint %.1f MB before / %.1f MB after (delta %+.1f MB)",
          beforeMB, afterMB, afterMB - beforeMB)
      } else {
        memoryDetails = ", physical footprint unavailable"
      }
      Self.finishUISelfTest(
        success: true, details: "30 popover/settings open-close cycles completed" + memoryDetails)
    }
  }

  private static func physicalFootprintBytes() -> UInt64? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
      MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : nil
  }

  private func showSettings() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    self.settingsControllerForUse()?.showWindow(nil)
  }

  private func showInsights() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    let controller = self.settingsControllerForUse()
    controller?.showInsights()
  }

  private func settingsControllerForUse() -> SettingsWindowController? {
    if let settingsController { return settingsController }
    guard let store else { return nil }
    let controller = SettingsWindowController(store: store)
    self.settingsController = controller
    return controller
  }

  private static func finishUISelfTest(success: Bool, details: String) {
    let prefix = success ? "PASS" : "FAIL"
    FileHandle.standardOutput.write(Data("\(prefix) AppKit UI: \(details)\n".utf8))
    fflush(stdout)
    exit(success ? 0 : 1)
  }
}
