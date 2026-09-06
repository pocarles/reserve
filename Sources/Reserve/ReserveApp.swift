import AppKit
import Darwin
import ServiceManagement
import ReserveCore

@main
enum ReserveApp {
  static func main() {
    _ = signal(SIGPIPE, SIG_IGN)
    // Unlike the RESERVE_DEV_AUTOMATION self tests, this runs in release
    // builds, so packaging can catch a resource that stops resolving.
    if CommandLine.arguments.contains("--verify-claude-login-resources") {
      Self.verifyClaudeLoginResources()
      return
    }
    let instanceLock: SingleInstanceLock
    do {
      guard let acquired = try SingleInstanceLock.acquire(at: self.instanceLockURL())
      else {
        self.activateExistingInstance()
        return
      }
      instanceLock = acquired
    } catch {
      fputs("Reserve could not acquire its single-instance lock: \(error)\n", stderr)
      return
    }
    let application = NSApplication.shared
    let delegate = AppDelegate()
    application.delegate = delegate
    withExtendedLifetime((delegate, instanceLock)) {
      application.run()
    }
  }

  /// Looks up the same resource `ClaudeLoginBrowserPipe.init` needs.
  /// Checking the bundle's files exist on disk (as verify_package.sh does)
  /// isn't enough, because SwiftPM's generated `Bundle.module` accessor can
  /// fail to find them anyway.
  private static func verifyClaudeLoginResources() {
    guard
      PackagedResourceBundle.resolved.url(
        forResource: "ClaudeLoginBrowser", withExtension: "sh") != nil
    else {
      FileHandle.standardError.write(
        Data("FAIL: ClaudeLoginBrowser.sh did not resolve inside the packaged app\n".utf8))
      exit(1)
    }
    FileHandle.standardOutput.write(Data("PASS: packaged Claude login resource resolved\n".utf8))
    exit(0)
  }

  private static func instanceLockURL() throws -> URL {
    if CommandLine.arguments.contains("--package-smoke-test") {
      return FileManager.default.temporaryDirectory.appendingPathComponent(
        "Reserve.package-smoke-\(ProcessInfo.processInfo.processIdentifier).lock")
    }
    #if RESERVE_DEV_AUTOMATION
      let automatedArguments = [
        "--self-test-ui", "--self-test-lifecycle", "--self-test-connections", "--stress-ui",
        "--render-dashboard", "--render-settings", "--render-appearance",
        "--render-about", "--render-alerts", "--render-insights",
        "--render-providers", "--render-menu-bar", "--render-provider-setup",
        "--capture-lifecycle",
        "--verify-notifications", "--show-claude-prompt", "--show-cursor-prompt",
      ]
      if CommandLine.arguments.contains(where: automatedArguments.contains) {
        return FileManager.default.temporaryDirectory.appendingPathComponent(
          "Reserve.dev-automation-\(ProcessInfo.processInfo.processIdentifier).lock")
      }
    #endif
    return try SingleInstanceLock.reserveLockURL()
  }

  private static func activateExistingInstance() {
    let currentProcess = ProcessInfo.processInfo.processIdentifier
    let existing = NSWorkspace.shared.runningApplications.first { application in
      guard application.processIdentifier != currentProcess else { return false }
      return application.bundleIdentifier == "com.pocarles.reserve"
        || application.executableURL?.lastPathComponent == "Reserve"
    }
    existing?.activate()
  }

  /// `FileHandle.write` cannot translate a broken pipe into `EPIPE` unless the
  /// process ignores SIGPIPE first. Provider subprocess failures then stay in
  /// the existing Swift error paths instead of terminating Reserve.
  static func brokenPipeWriteFailsSafely() -> Bool {
    let pipe = Pipe()
    try? pipe.fileHandleForReading.close()
    defer { try? pipe.fileHandleForWriting.close() }
    do {
      try pipe.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
      return false
    } catch {
      return true
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  static let claudeSetupTitle = "Show your Claude limits"
  static let claudeSetupMessage =
    "Reserve can use the Claude sign-in already on this Mac to check your plan limits."
  static let claudeSetupReassurance = "Your sign-in stays protected by macOS"
  static let claudeSetupPrivacy = "Reserve never sees your password or saves your sign-in."
  static let claudeSetupFootnote =
    "You can turn this access off at any time in Settings > Providers."

  static func confirmClaudeLimitAccess() -> Bool {
    self.confirmLimitAccess(for: .anthropic)
  }

  static func confirmLimitAccess(for provider: ProviderID) -> Bool {
    ProviderLimitAccessPrompt(provider: provider).ask()
  }

  private var store: UsageStore?
  private var statusController: StatusItemController?
  private var settingsController: SettingsWindowController?
  private var providerSetupCoordinator: ProviderSetupCoordinator?
  private var updater: ReserveUpdater?

  private static let uiSelfTestDefaultsSuite = "Reserve.UISelfTest"

  func applicationDidFinishLaunching(_: Notification) {
    NSApplication.shared.setActivationPolicy(.accessory)
#if RESERVE_DEV_AUTOMATION
    let isConnectionSelfTest = CommandLine.arguments.contains("--self-test-connections")
    let isUISelfTest = CommandLine.arguments.contains("--self-test-ui")
    let renderIndex = CommandLine.arguments.firstIndex(of: "--render-dashboard")
    let settingsRenderIndex = CommandLine.arguments.firstIndex(of: "--render-settings")
    let appearanceRenderIndex = CommandLine.arguments.firstIndex(of: "--render-appearance")
    let aboutRenderIndex = CommandLine.arguments.firstIndex(of: "--render-about")
    let alertsRenderIndex = CommandLine.arguments.firstIndex(of: "--render-alerts")
    let insightsRenderIndex = CommandLine.arguments.firstIndex(of: "--render-insights")
    let providersRenderIndex = CommandLine.arguments.firstIndex(of: "--render-providers")
    let menuBarRenderIndex = CommandLine.arguments.firstIndex(of: "--render-menu-bar")
    let providerSetupRenderIndex = CommandLine.arguments.firstIndex(
      of: "--render-provider-setup")
    let isUIStressTest = CommandLine.arguments.contains("--stress-ui")
    let isLifecycleSelfTest = CommandLine.arguments.contains("--self-test-lifecycle")
    let isClaudePromptPreview = CommandLine.arguments.contains("--show-claude-prompt")
    let isCursorPromptPreview = CommandLine.arguments.contains("--show-cursor-prompt")
    let lifecycleCaptureIndex = CommandLine.arguments.firstIndex(of: "--capture-lifecycle")
    let isNotificationVerification = CommandLine.arguments.contains("--verify-notifications")
    let isAutomatedRun = isConnectionSelfTest || isUISelfTest || renderIndex != nil || settingsRenderIndex != nil
      || appearanceRenderIndex != nil || aboutRenderIndex != nil || alertsRenderIndex != nil
      || insightsRenderIndex != nil || providersRenderIndex != nil || menuBarRenderIndex != nil
      || providerSetupRenderIndex != nil
      || isUIStressTest || isLifecycleSelfTest || lifecycleCaptureIndex != nil
      || isNotificationVerification || isClaudePromptPreview || isCursorPromptPreview
    let store: UsageStore
    if isAutomatedRun {
      Self.clearTestPreferences(suiteName: Self.uiSelfTestDefaultsSuite)
      let testDefaults = UserDefaults(suiteName: Self.uiSelfTestDefaultsSuite)!
      store = UsageStore(defaults: testDefaults, startAutomatically: false)
    } else {
      _ = LegacyStateMigrator.migrateLiveState()
      store = UsageStore()
    }
    if isAutomatedRun {
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
#else
    let isAutomatedRun = false
    _ = LegacyStateMigrator.migrateLiveState()
    let store = UsageStore()
#endif
    self.store = store
    self.providerSetupCoordinator = ProviderSetupCoordinator(store: store)
    if Bundle.main.bundleURL.pathExtension == "app", !isAutomatedRun {
      self.updater = ReserveUpdater()
    }
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
      setupProvider: { [weak self] provider in self?.setupProvider(provider) },
      isSettingsWindow: { [weak self] window in
        guard let window else { return false }
        return self?.settingsController?.window === window
      })
#if RESERVE_DEV_AUTOMATION
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
    } else if let providerSetupRenderIndex,
      CommandLine.arguments.indices.contains(providerSetupRenderIndex + 1)
    {
      self.renderProviderSetup(path: CommandLine.arguments[providerSetupRenderIndex + 1])
    } else if isNotificationVerification {
      self.verifyNotifications()
    } else if isUIStressTest {
      self.runUIStressTest()
    } else if let lifecycleCaptureIndex,
      CommandLine.arguments.indices.contains(lifecycleCaptureIndex + 1)
    {
      self.runLifecycleCapture(directory: CommandLine.arguments[lifecycleCaptureIndex + 1])
    } else if isLifecycleSelfTest {
      self.runLifecycleSelfTest()
    } else if isConnectionSelfTest {
      Task { @MainActor in
        let failures = await ConnectionFlowSelfTest.run()
        Self.finishUISelfTest(success: failures.isEmpty,
          details: failures.isEmpty
            ? "connection recovery, permission, cancellation, disconnect and native windows passed"
            : failures.joined(separator: " | "))
      }
    } else if isUISelfTest {
      self.runUISelfTest()
    } else if isClaudePromptPreview {
      DispatchQueue.main.async { _ = Self.confirmClaudeLimitAccess() }
    } else if isCursorPromptPreview {
      DispatchQueue.main.async { _ = Self.confirmLimitAccess(for: .cursor) }
    } else if CommandLine.arguments.contains("--show-settings") {
      self.showSettings()
    } else if CommandLine.arguments.contains("--show-menu") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
        self?.statusController?.showMenu()
      }
    } else {
      self.completeFirstLaunchIfNeeded()
    }
#else
    self.completeFirstLaunchIfNeeded()
#endif
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

  private func renderProviderSetup(path: String) {
    let provider = CommandLine.arguments.firstIndex(of: "--provider").flatMap { index in
      CommandLine.arguments.indices.contains(index + 1)
        ? ProviderID(rawValue: CommandLine.arguments[index + 1]) : nil
    } ?? .cursor
    let action: ProviderSetupAction =
      CommandLine.arguments.firstIndex(of: "--setup-action").flatMap { index in
        CommandLine.arguments.indices.contains(index + 1)
          ? CommandLine.arguments[index + 1] : nil
      } == "update" ? .update : .install
    do {
      let prompt = ProviderConnectionPanel(provider: provider)
      prompt.update(phase: action == .install ? .needsInstall : .needsUpdate)
      try prompt.render(to: URL(fileURLWithPath: path))
      Self.finishUISelfTest(
        success: true, details: "provider setup rendered to \(path)")
    } catch {
      Self.finishUISelfTest(success: false, details: "provider setup render failed: \(error)")
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
    let suite = "Reserve.NotificationCheck"
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
      let windowID = StableIdentifier.notificationComponent("weekly")
      let cycleID = StableIdentifier.notificationComponent(
        String(format: "%.0f", reset.timeIntervalSince1970))
      let expected = [
        "deficit": "reserve.deficit.openAI.\(windowID).\(cycleID)",
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
      try? FileManager.default.removeItem(at: plist)

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
    // Launching at login is persistence, so it waits for the checkbox in
    // Settings rather than being arranged on the user's behalf.
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
      guard let self else { return }
      // First launch should feel like opening an app, not granting a security
      // permission. Protected access is explained only after Allow access is chosen.
      self.statusController?.showMenu()
    }
  }

  @objc private func applicationBecameActive() {
    self.store?.refreshAfterResumeIfNeeded()
  }

  func applicationShouldHandleReopen(_: NSApplication, hasVisibleWindows: Bool) -> Bool {
    if !hasVisibleWindows { self.statusController?.showMenu() }
    return true
  }

  @objc private func computerDidWake() {
    self.store?.refreshAfterResumeIfNeeded()
  }

  /// Drives real state transitions through the live surfaces: appearance changes
  /// while both are open, and provider disclosure with the popover on screen.
  private func runLifecycleSelfTest() {
    guard let store = self.store,
      let statusController = self.statusController,
      let settingsController = self.settingsControllerForUse()
    else {
      Self.finishUISelfTest(success: false, details: "lifecycle controllers were not created")
      return
    }
    Task { @MainActor in
      settingsController.showWindow(nil)
      statusController.setStressTestAnimationsEnabled(false)
      // The status item needs a run-loop turn before its button has a window,
      // and a popover cannot be shown from a view that is not in one yet.
      try? await Task.sleep(for: .milliseconds(600))
      let statusItemFrameBeforeOpen = statusController.statusItemScreenFrameForTesting
      statusController.showMenu()
      try? await Task.sleep(for: .milliseconds(400))
      guard statusController.isDashboardShownForTesting else {
        Self.finishUISelfTest(
          success: false,
          details: "the dashboard popover could not be shown; lifecycle checks need a real "
            + "status item, so run this from Reserve.app in a logged-in session")
        return
      }

      if CommandLine.arguments.contains("--diagnose-refresh") {
        print("=== refresh control, inside the real popover ===")
        let window = statusController.dashboardWindowForTesting
        let root = window?.contentView
        let spinners = root.map { LifecycleSelfTest.descendants(of: $0) }?
          .compactMap { $0 as? ReserveIconButton } ?? []
        for button in spinners where button.identifier?.rawValue == "refresh-all" {
          if let layer = button.layer {
            print("  idle: anchor=\(layer.anchorPoint) spinning=\(button.isSpinning)")
            print("        bounds=\(button.bounds)")
            if let spin = layer.animation(forKey: "reserve.refresh.spin") as? CAKeyframeAnimation,
              let values = spin.values as? [CATransform3D], values.count > 4 {
              let c = CGPoint(x: button.bounds.midX, y: button.bounds.midY)
              var worst = 0.0
              for m in values {
                let p = CGPoint(
                  x: m.m11 * c.x + m.m21 * c.y + m.m41,
                  y: m.m12 * c.x + m.m22 * c.y + m.m42)
                worst = max(worst, hypot(p.x - c.x, p.y - c.y))
              }
              print("        centre drift over a full turn = \(String(format: "%.3f", worst))pt")
            }
          }
        }

        print("=== does the control drive a real refresh? ===")
        let before = ProviderID.allCases.reduce(into: [ProviderID: Date?]()) {
          $0[$1] = store.states[$1]?.snapshot?.fetchedAt
        }
        print("  isRefreshingAll before = \(store.isRefreshingAll)")
        let clicked = (root.map { LifecycleSelfTest.descendants(of: $0) } ?? [])
          .compactMap { $0 as? NSButton }
          .first { $0.identifier?.rawValue == "refresh-all" }
        clicked?.performClick(nil)
        try? await Task.sleep(for: .milliseconds(150))
        print("  clicked=\(clicked != nil) isRefreshingAll after click = \(store.isRefreshingAll)")
        print("  refreshStartedAt = \(store.refreshStartedAt.map { "\($0)" } ?? "nil")")
        // The control turns only while a refresh is in flight.
        let busy = (statusController.dashboardWindowForTesting?.contentView)
          .map { LifecycleSelfTest.descendants(of: $0) }?
          .compactMap { $0 as? ReserveIconButton }
          .first { $0.identifier?.rawValue == "refresh-all" }
        if let busy, let layer = busy.layer {
          print("  busy: spinning=\(busy.isSpinning) anchor=\(layer.anchorPoint)")
          if let spin = layer.animation(forKey: "reserve.refresh.spin") as? CAKeyframeAnimation,
            let values = spin.values as? [CATransform3D] {
            let c = CGPoint(x: busy.bounds.midX, y: busy.bounds.midY)
            var worst = 0.0
            for m in values {
              let p = CGPoint(
                x: m.m11 * c.x + m.m21 * c.y + m.m41,
                y: m.m12 * c.x + m.m22 * c.y + m.m42)
              worst = max(worst, hypot(p.x - c.x, p.y - c.y))
            }
            print("        centre drift over a full turn = \(String(format: "%.3f", worst))pt")
          } else {
            print("        NOT centre-relative: rotation is anchor-based")
          }
        }
        for _ in 0..<40 {
          if !store.isRefreshingAll { break }
          try? await Task.sleep(for: .milliseconds(500))
        }
        print("  isRefreshingAll settled = \(store.isRefreshingAll)")
        for provider in ProviderID.allCases where store.isEnabled(provider) {
          let now = store.states[provider]?.snapshot?.fetchedAt
          let moved = (before[provider] ?? nil) != now
          let err = store.states[provider]?.error
          print("    \(provider.rawValue): fetchedAt moved=\(moved) error=\(err ?? "none")")
        }
        exit(0)
      }

      if CommandLine.arguments.contains("--diagnose") {
        print("=== disclosure geometry ===")
        LifecycleSelfTest.dumpGeometry("collapsed  ", store: store, controller: statusController)
        for provider in ProviderID.allCases where store.isEnabled(provider) {
          statusController.toggleProviderDetailForTesting(provider)
          try? await Task.sleep(for: .milliseconds(250))
          LifecycleSelfTest.dumpGeometry(
            "expand \(provider.rawValue)", store: store, controller: statusController)
          statusController.toggleProviderDetailForTesting(provider)
          try? await Task.sleep(for: .milliseconds(250))
          LifecycleSelfTest.dumpGeometry(
            "collapse \(provider.rawValue)", store: store, controller: statusController)
        }
        print("=== appearance ===")
        for mode in AppearanceMode.allCases {
          store.appearanceMode = mode
          try? await Task.sleep(for: .milliseconds(250))
          let window = statusController.dashboardWindowForTesting
          let root = window?.contentView
          print(
            "  mode=\(mode.rawValue)"
              + " app=\(NSApp.effectiveAppearance.name.rawValue)"
              + " popoverWindow=\(window?.effectiveAppearance.name.rawValue ?? "nil")"
              + " dashboardView=\(root?.effectiveAppearance.name.rawValue ?? "nil")"
              + " settingsWindow=\(settingsController.window?.effectiveAppearance.name.rawValue ?? "nil")"
              + " layerBG=\(root.flatMap { LifecycleSelfTest.resolvedBackground($0) }.map { String(format: "%.3f", $0.redComponent) } ?? "nil")")
        }
        exit(0)
      }

      var failures: [String] = []
      if !settingsController.exerciseUpdatePresentationForSelfTest() {
        failures.append("Settings did not move aside and return around the update prompt")
      }
      if let before = statusItemFrameBeforeOpen,
        let after = statusController.statusItemScreenFrameForTesting
      {
        let movement = abs(after.minX - before.minX)
        if movement >= 0.5 {
          failures.append("opening the popover moved the status item left by \(movement)pt")
        }
      } else {
        failures.append("the status-item frame was unavailable for the opening anchor check")
      }
      let observation = LifecycleSelfTest.checkObservation(store: store)
      failures.append(contentsOf: observation.failures)
      failures.append(contentsOf: LifecycleSelfTest.checkGeometry().failures)
      failures.append(contentsOf: LifecycleSelfTest.checkSpinnerGeometry().failures)
      failures.append(contentsOf: LifecycleSelfTest.checkLocalActivityWithoutPlanLimits().failures)

      let providerAnchor = LifecycleSelfTest.checkProviderSelectionAnchor(
        store: store, controller: statusController)
      failures.append(contentsOf: providerAnchor.failures)

      statusController.setStressTestAnimationsEnabled(true)
      let animatedDisclosureAnchor = LifecycleSelfTest.checkAnimatedDisclosureAnchor(
        store: store, controller: statusController,
        toggle: { statusController.toggleProviderDetailForTesting($0) })
      failures.append(contentsOf: animatedDisclosureAnchor.failures)
      statusController.setStressTestAnimationsEnabled(false)

      let disclosure = LifecycleSelfTest.checkDisclosure(
        store: store, controller: statusController,
        toggle: { statusController.toggleProviderDetailForTesting($0) })
      failures.append(contentsOf: disclosure.failures)

      let enablement = LifecycleSelfTest.checkEnablement(
        store: store, controller: statusController)
      failures.append(contentsOf: enablement.failures)

      let appearance = LifecycleSelfTest.checkAppearance(
        store: store, controller: statusController, settings: settingsController)
      failures.append(contentsOf: appearance.failures)

      settingsController.window?.orderOut(nil)
      statusController.closeMenuForStressTest()
      try? await Task.sleep(for: .milliseconds(400))
      if statusController.mouseMonitorCountForTesting != 0 {
        failures.append("mouse monitors survived the popover closing")
      }
      if statusController.statusItemLengthIsLockedForTesting {
        failures.append("the status-item width remained locked after the popover closed")
      }

      Self.finishUISelfTest(
        success: failures.isEmpty,
        details: failures.isEmpty
          ? "appearance reaches every open surface across \(AppearanceMode.allCases.count) modes "
            + "and \(AppearanceTheme.allCases.count) themes, provider selection keeps the popover "
            + "anchored, opening keeps the status item fixed, provider disclosure stays anchored "
            + "and never costs a card, enabling a provider moves only that provider, and the "
            + "store notifies every observer; local activity stays distinct from plan limits"
          : "\(failures.count) lifecycle failures: " + failures.prefix(12).joined(separator: " | "))
    }
  }

  /// Captures the two reported failures from the live popover: an appearance
  /// change with Settings and the dashboard both open, and provider disclosure.
  private func runLifecycleCapture(directory: String) {
    guard let store = self.store,
      let statusController = self.statusController,
      let settingsController = self.settingsControllerForUse()
    else {
      Self.finishUISelfTest(success: false, details: "capture controllers were not created")
      return
    }
    let folder = URL(fileURLWithPath: directory, isDirectory: true)
    Task { @MainActor in
      try? FileManager.default.createDirectory(
        at: folder, withIntermediateDirectories: true)
      settingsController.showWindow(nil)
      statusController.setStressTestAnimationsEnabled(false)
      try? await Task.sleep(for: .milliseconds(600))
      statusController.showMenu()
      try? await Task.sleep(for: .milliseconds(400))
      guard statusController.isDashboardShownForTesting else {
        Self.finishUISelfTest(success: false, details: "the popover could not be shown")
        return
      }

      var written: [String] = []
      @MainActor func capture(_ name: String) async {
        try? await Task.sleep(for: .milliseconds(220))
        do {
          try statusController.renderLiveDashboard(
            to: folder.appendingPathComponent("\(name).png"))
          written.append(name)
        } catch {
          written.append("\(name)=FAILED")
        }
      }

      // Appearance: the popover is left open across every change.
      for (mode, theme) in [
        (AppearanceMode.light, AppearanceTheme.matrix),
        (AppearanceMode.dark, AppearanceTheme.matrix),
        (AppearanceMode.light, AppearanceTheme.ember),
        (AppearanceMode.dark, AppearanceTheme.ocean),
        (AppearanceMode.light, AppearanceTheme.graphite),
        (AppearanceMode.dark, AppearanceTheme.graphite),
      ] {
        store.appearanceMode = mode
        store.appearanceTheme = theme
        await capture("appearance-\(mode.rawValue)-\(theme.rawValue)")
      }

      // Disclosure: collapsed, each provider open, and collapsed again.
      store.appearanceMode = .dark
      store.appearanceTheme = .ocean
      await capture("disclosure-collapsed")
      for provider in ProviderID.allCases where store.isEnabled(provider) {
        statusController.toggleProviderDetailForTesting(provider)
        await capture("disclosure-open-\(provider.rawValue)")
        statusController.toggleProviderDetailForTesting(provider)
        await capture("disclosure-collapsed-after-\(provider.rawValue)")
      }
      Self.finishUISelfTest(
        success: !written.contains { $0.hasSuffix("FAILED") },
        details: "captured \(written.count) frames to \(folder.path)")
    }
  }

  private func runUISelfTest() {
    guard let store = self.store,
      let statusController = self.statusController,
      let settingsController = self.settingsControllerForUse()
    else {
      Self.finishUISelfTest(success: false, details: "controllers were not created")
      return
    }

    let statusResult = statusController.validateForSelfTest(settingsWindow: settingsController.window)
    let settingsResult = settingsController.validateForSelfTest()
    let claudePromptIsCalmAndWide = ProviderLimitAccessPrompt(provider: .anthropic)
      .validateForSelfTest()
    let cursorPromptIsCalmAndWide = ProviderLimitAccessPrompt(provider: .cursor)
      .validateForSelfTest()
    let brokenPipeIsSafe = ReserveApp.brokenPipeWriteFailsSafely()
    let loginCompletionQueuesRefresh = store.exerciseLoginCompletionDuringRefreshForSelfTest()
    let claudeAccessRevealsOnce = store.exerciseClaudeAccessCompletionForSelfTest()
    let success = statusResult.success && settingsResult.success && claudePromptIsCalmAndWide
      && cursorPromptIsCalmAndWide
      && brokenPipeIsSafe
      && loginCompletionQueuesRefresh && claudeAccessRevealsOnce
    let details = [
      statusResult.details,
      settingsResult.details,
      "provider access prompts=\(claudePromptIsCalmAndWide && cursorPromptIsCalmAndWide)",
      "broken pipe handling=\(brokenPipeIsSafe)",
      "post-login refresh queue=\(loginCompletionQueuesRefresh)",
      "post-Keychain reveal=\(claudeAccessRevealsOnce)",
    ].joined(separator: "; ")
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
      // The status item needs a run-loop turn before its button has a window;
      // without it the popover silently never opens and the cycles below would
      // only exercise Settings.
      try? await Task.sleep(for: .milliseconds(600))
      statusController.showMenu()
      try? await Task.sleep(for: .milliseconds(200))
      guard statusController.isDashboardShownForTesting else {
        Self.finishUISelfTest(
          success: false, details: "the popover never opened, so no cycle was exercised")
        return
      }
      statusController.closeMenuForStressTest()
      settingsController.showWindow(nil)
      settingsController.window?.close()
      try? await Task.sleep(for: .seconds(3))
      let footprintBefore = Self.physicalFootprintBytes()
      for _ in 0..<30 {
        statusController.showMenu()
        try? await Task.sleep(for: .milliseconds(100))
        statusController.closeMenuForStressTest()
        try? await Task.sleep(for: .milliseconds(100))
        settingsController.showWindow(nil)
        try? await Task.sleep(for: .milliseconds(50))
        settingsController.window?.close()
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

  private func setupProvider(_ provider: ProviderID) {
    self.providerSetupCoordinator?.start(provider)
  }

  private func settingsControllerForUse() -> SettingsWindowController? {
    if let settingsController { return settingsController }
    guard let store else { return nil }
    let controller = SettingsWindowController(
      store: store,
      updater: self.updater,
      setupProvider: { [weak self] provider in self?.setupProvider(provider) })
    self.settingsController = controller
    return controller
  }

  private static func clearTestPreferences(suiteName: String) {
    let defaults = UserDefaults(suiteName: suiteName)
    defaults?.removePersistentDomain(forName: suiteName)
    let plist = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Preferences/\(suiteName).plist")
    try? FileManager.default.removeItem(at: plist)
  }

  private static func finishUISelfTest(success: Bool, details: String) {
    Self.clearTestPreferences(suiteName: Self.uiSelfTestDefaultsSuite)
    let prefix = success ? "PASS" : "FAIL"
    FileHandle.standardOutput.write(Data("\(prefix) AppKit UI: \(details)\n".utf8))
    fflush(stdout)
    exit(success ? 0 : 1)
  }
}
