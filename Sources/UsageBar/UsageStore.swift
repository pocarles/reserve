import AppKit
import Foundation
import UsageBarCore

struct ProviderViewState: Identifiable {
  var id: ProviderID { self.provider }
  let provider: ProviderID
  var snapshot: UsageSnapshot?
  var error: String?
  var isRefreshing = false
  var isConnecting = false
  var localUsage: LocalUsageSummary?
  var subscriptionCostUSD: Double = 0
  var renewalStart: Date?
  var nextRenewal: Date?
  var serviceStatus: ProviderServiceStatus?

  var isStale: Bool {
    guard let snapshot else { return false }
    return self.error != nil || Date().timeIntervalSince(snapshot.fetchedAt) > 30 * 60
  }
}

enum PreviewScenario: String, CaseIterable {
  case allReserve = "all-reserve"
  case mixed
  case deficit
  case multipleDeficit = "multiple-deficit"
  case exhausted
  case stale
  case unknown
}

@MainActor
final class UsageStore {
  private(set) var states: [ProviderID: ProviderViewState]
  private(set) var isRefreshingAll = false
  /// When the current refresh started, so the header's spinner keeps its phase
  /// across the rebuilds a refresh triggers.
  private(set) var refreshStartedAt: Date?
  private(set) var isScanningLocalUsage = false

  /// Identifies one registered observer. Surfaces come and go, so removal has to
  /// be precise rather than "clear the callback".
  struct ObserverToken: Hashable {
    fileprivate let id: Int
  }

  /// Every surface observes the same store. This used to be a single closure
  /// slot, which meant the second surface to register silently replaced the
  /// first and that surface then never saw another update.
  private var observers: [(token: ObserverToken, handler: () -> Void)] = []
  private var nextObserverID = 0
  private var isNotifying = false
  private var needsFollowUpNotification = false

  @discardableResult
  func observe(_ handler: @escaping () -> Void) -> ObserverToken {
    self.nextObserverID += 1
    let token = ObserverToken(id: self.nextObserverID)
    self.observers.append((token, handler))
    return token
  }

  func removeObserver(_ token: ObserverToken) {
    self.observers.removeAll { $0.token == token }
  }

  private let cache = SnapshotCache()
  private let localUsageScanner = LocalUsageScanner()
  private let serviceStatusClient = ServiceStatusClient()
  private let defaults: UserDefaults
  private let notifications: ReserveNotifications
  private let automaticRefreshEnabled: Bool
  private var schedulerTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var loginProcesses: [ProviderID: Process] = [:]
  private var loginTimeoutTasks: [ProviderID: Task<Void, Never>] = [:]
  private var loginInputs: [ProviderID: Pipe] = [:]
  private var loginOutputs: [ProviderID: Pipe] = [:]
  private var loginOutputBuffers: [ProviderID: Data] = [:]
  private var openedLoginURLs: Set<ProviderID> = []
  private var lastLocalUsageScanAt: Date?
  /// The newest refresh request per provider. Results from any older request are
  /// discarded rather than applied.
  private var refreshTokens: [ProviderID: Int] = [:]
  // Standing conditions notify on the way in and clear on the way out, so a
  // provider that stays stale or degraded does not notify on every refresh.
  /// Which provider row is open in the popover. Transient interface state, so
  /// it is deliberately not persisted.
  var expandedProvider: ProviderID?
  private var staleProviders: Set<ProviderID> = []
  private var incidentProviders: Set<ProviderID> = []
  private let localUsageScanInterval: TimeInterval = 30 * 60

  init(
    defaults: UserDefaults = .standard,
    startAutomatically: Bool = true,
    notificationsActive: Bool? = nil
  ) {
    self.defaults = defaults
    self.automaticRefreshEnabled = startAutomatically
    self.notifications = ReserveNotifications(
      defaults: defaults, active: notificationsActive ?? startAutomatically)
    self.states = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map {
        ($0, ProviderViewState(provider: $0))
      })
    self.registerDefaults()
    ReserveAppearance.current = self.appearanceTheme
    ReserveAppearance.mode = self.appearanceMode
    self.notifications.requestAuthorizationIfNeeded()
    if startAutomatically {
      self.startupTask = Task { [weak self] in
        await self?.loadCacheAndStart()
      }
    }
  }

  deinit {
    self.schedulerTask?.cancel()
    self.startupTask?.cancel()
    for task in self.loginTimeoutTasks.values { task.cancel() }
    for process in self.loginProcesses.values where process.isRunning { process.terminate() }
  }

  var orderedStates: [ProviderViewState] {
    ProviderID.allCases.compactMap { provider in
      guard var state = self.states[provider] else { return nil }
      state.subscriptionCostUSD = self.monthlySubscriptionCost(for: provider)
      state.renewalStart = self.renewalStart(for: provider)
      state.nextRenewal = self.nextRenewal(for: provider)
      return state
    }
  }

  var claudeKeychainReadAllowed: Bool {
    get { self.defaults.bool(forKey: "anthropic.keychainReadAllowed") }
    set {
      self.defaults.set(newValue, forKey: "anthropic.keychainReadAllowed")
      self.changed()
      if newValue { self.refresh(.anthropic) }
    }
  }

  var refreshIntervalMinutes: Int {
    get { max(1, self.defaults.integer(forKey: "refresh.intervalMinutes")) }
    set {
      self.defaults.set(max(1, newValue), forKey: "refresh.intervalMinutes")
      self.startScheduler()
    }
  }

  var notificationsEnabled: Bool {
    get { self.notifications.isEnabled }
    set {
      self.notifications.setEnabled(newValue)
      if newValue { self.rebuildNotificationSchedules() }
      self.changed()
    }
  }

  func notificationPreference(_ name: String) -> Bool {
    self.defaults.bool(forKey: "notifications.\(name)")
  }

  func setNotificationPreference(_ enabled: Bool, name: String) {
    self.defaults.set(enabled, forKey: "notifications.\(name)")
    self.rebuildNotificationSchedules()
    self.changed()
  }

  /// Which phase of a standing condition to exercise.
  enum StandingConditionPhase {
    /// The condition starts: both alerts should be delivered.
    case enter
    /// The condition persists: nothing new should be delivered.
    case persist
    /// The condition clears: the standing alerts should be withdrawn.
    case recover
  }

  /// Drives `reportStaleness` and `reportServiceHealth` — the real triggers —
  /// with seeded state, so their notifications can be observed end to end.
  @discardableResult
  func exerciseStandingConditions(
    _ phase: StandingConditionPhase,
    now: Date = Date()
  ) -> (stale: String, incident: String) {
    let staleProvider = ProviderID.grok
    let incidentProvider = ProviderID.anthropic
    let page = URL(string: "https://status.claude.com")!

    switch phase {
    case .enter, .persist:
      // A snapshot old enough to stop counting as current.
      self.states[staleProvider]?.snapshot = UsageSnapshot(
        provider: staleProvider, windows: [],
        fetchedAt: now.addingTimeInterval(-SmartAlertDetector.stalenessLimit - 300),
        source: "standing condition check")
      let previousHealth = self.states[incidentProvider]?.serviceStatus?.health
      self.states[incidentProvider]?.serviceStatus = ProviderServiceStatus(
        provider: incidentProvider, health: .degraded,
        detail: "Partial system degradation", pageURL: page, fetchedAt: now)
      self.reportStaleness(staleProvider, now: now)
      self.reportServiceHealth(incidentProvider, previous: previousHealth)
    case .recover:
      self.states[staleProvider]?.snapshot = UsageSnapshot(
        provider: staleProvider, windows: [], fetchedAt: now,
        source: "standing condition check")
      self.states[incidentProvider]?.serviceStatus = ProviderServiceStatus(
        provider: incidentProvider, health: .operational,
        detail: "All systems operational", pageURL: page, fetchedAt: now)
      self.reportStaleness(staleProvider, now: now)
      self.reportServiceHealth(incidentProvider, previous: .degraded)
    }
    return (
      "reserve.stale.\(staleProvider.rawValue)",
      "reserve.incident.\(incidentProvider.rawValue)"
    )
  }

  /// Whether either standing condition is currently being tracked.
  var standingConditionsAreTracked: Bool {
    !self.staleProviders.isEmpty || !self.incidentProviders.isEmpty
  }

  private func rebuildNotificationSchedules() {
    let snapshots = self.states.values.compactMap(\.snapshot)
    let renewals = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.compactMap { provider in
        self.nextRenewal(for: provider).map { (provider, $0) }
      })
    self.notifications.rebuildSchedules(snapshots: snapshots, nextPlanRenewals: renewals)
  }

  /// Light, dark, or whatever the system is doing.
  var appearanceMode: AppearanceMode {
    get {
      AppearanceMode(rawValue: self.defaults.string(forKey: "appearance.mode") ?? "")
        ?? .system
    }
    set {
      self.defaults.set(newValue.rawValue, forKey: "appearance.mode")
      ReserveAppearance.mode = newValue
      self.changed()
    }
  }

  var appearanceTheme: AppearanceTheme {
    get {
      self.defaults.string(forKey: "appearance.theme").flatMap(AppearanceTheme.init(rawValue:))
        ?? .matrix
    }
    set {
      self.defaults.set(newValue.rawValue, forKey: "appearance.theme")
      ReserveAppearance.current = newValue
      self.changed()
    }
  }

  /// Whether Reserve looks for a new release on its own. Off by default: this
  /// build is from source and there is no downloadable GitHub Release yet. The
  /// check contacts GitHub and sends nothing but the current version.
  var automaticUpdateChecks: Bool {
    get { self.defaults.bool(forKey: "updates.automatic") }
    set {
      self.defaults.set(newValue, forKey: "updates.automatic")
      self.changed()
    }
  }

  /// When the last automatic check ran, so launching Reserve repeatedly does not
  /// mean asking GitHub repeatedly.
  var lastUpdateCheck: Date? {
    get { self.defaults.object(forKey: "updates.lastCheckedAt") as? Date }
    set { self.defaults.set(newValue, forKey: "updates.lastCheckedAt") }
  }

  /// The newest release Reserve has seen, remembered so Settings can report it
  /// whenever it is next opened rather than only while a check is running.
  var availableUpdate: (version: String, url: URL)? {
    get {
      guard let version = self.defaults.string(forKey: "updates.availableVersion"),
        let raw = self.defaults.string(forKey: "updates.availableURL"),
        let url = URL(string: raw), url.scheme == "https"
      else { return nil }
      return (version, url)
    }
    set {
      self.defaults.set(newValue?.version, forKey: "updates.availableVersion")
      self.defaults.set(newValue?.url.absoluteString, forKey: "updates.availableURL")
      self.changed()
    }
  }

  var menuBarProvider: ProviderID? {
    get {
      guard let raw = self.defaults.string(forKey: "menuBar.provider"), raw != "reserve" else {
        return nil
      }
      return ProviderID(rawValue: raw)
    }
    set {
      self.defaults.set(newValue?.rawValue ?? "reserve", forKey: "menuBar.provider")
      self.changed()
    }
  }

  var menuBarShowsRemaining: Bool {
    get { self.defaults.bool(forKey: "menuBar.showsRemaining") }
    set {
      self.defaults.set(newValue, forKey: "menuBar.showsRemaining")
      self.changed()
    }
  }

  var menuBarShowsReset: Bool {
    get { self.defaults.bool(forKey: "menuBar.showsReset") }
    set {
      self.defaults.set(newValue, forKey: "menuBar.showsReset")
      self.changed()
    }
  }

  func selectMenuBarProvider(_ provider: ProviderID) {
    self.defaults.set(true, forKey: "menuBar.showsRemaining")
    self.defaults.set(provider.rawValue, forKey: "menuBar.provider")
    self.changed()
  }

  func refreshAll(manual: Bool = true) {
    guard !self.isRefreshingAll else { return }
    if !manual, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
    self.isRefreshingAll = true
    self.refreshStartedAt = Date()
    for provider in ProviderID.allCases where self.isEnabled(provider) {
      self.states[provider]?.isRefreshing = true
    }
    let scanLocalUsage = self.beginLocalUsageRefresh(force: manual)
    self.changed()
    Task { await self.performRefreshAll(scanLocalUsage: scanLocalUsage) }
  }

  /// Activation and wake are refresh triggers only when the cached provider
  /// data has actually aged past the configured interval.
  func shouldRefreshAfterResume(now: Date = Date()) -> Bool {
    guard self.automaticRefreshEnabled, !self.isRefreshingAll else { return false }
    return Self.resumeRefreshNeeded(
      states: self.orderedStates.filter { self.isEnabled($0.provider) },
      intervalMinutes: self.refreshIntervalMinutes,
      isRefreshingAll: self.isRefreshingAll,
      now: now)
  }

  static func resumeRefreshNeeded(
    states: [ProviderViewState],
    intervalMinutes: Int,
    isRefreshingAll: Bool,
    now: Date
  ) -> Bool {
    guard !isRefreshingAll else { return false }
    let staleAfter = TimeInterval(max(1, intervalMinutes) * 60)
    return states.contains { state in
      guard !state.isRefreshing else { return false }
      guard let snapshot = state.snapshot else { return true }
      return state.error != nil || now.timeIntervalSince(snapshot.fetchedAt) >= staleAfter
    }
  }

  func refreshAfterResumeIfNeeded(now: Date = Date()) {
    if self.shouldRefreshAfterResume(now: now) { self.refreshAll(manual: false) }
  }

  func refresh(_ provider: ProviderID) {
    guard self.beginRefresh(provider) else { return }
    Task { await self.performRefresh(provider) }
  }

  func connect(_ provider: ProviderID) {
    guard self.loginProcesses[provider]?.isRunning != true else { return }
    let configuration = Self.loginConfiguration(for: provider)
    guard let executable = BinaryLocator.find(configuration.executable) else {
      self.states[provider]?.error = "\(configuration.displayName) is not installed."
      self.changed()
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = configuration.arguments
    process.environment = BinaryLocator.childEnvironment()
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    process.terminationHandler = { [weak self] completed in
      Task { @MainActor [weak self] in
        self?.finishLogin(provider, status: completed.terminationStatus)
      }
    }

    do {
      try process.run()
      self.loginProcesses[provider] = process
      self.loginInputs[provider] = input
      self.loginOutputs[provider] = output
      self.loginOutputBuffers[provider] = Data()
      self.openedLoginURLs.remove(provider)
      output.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        Task { @MainActor [weak self] in self?.consumeLoginOutput(data, for: provider) }
      }
      self.states[provider]?.isConnecting = true
      self.states[provider]?.error = nil
      self.changed()
      self.loginTimeoutTasks[provider]?.cancel()
      self.loginTimeoutTasks[provider] = Task { [weak self, weak process] in
        try? await Task.sleep(for: .seconds(300))
        guard !Task.isCancelled, process?.isRunning == true else { return }
        process?.terminate()
        // A CLI that ignores SIGTERM must not outlive its own timeout.
        try? await Task.sleep(for: .seconds(2))
        if process?.isRunning == true, let identifier = process?.processIdentifier {
          kill(identifier, SIGKILL)
        }
        await MainActor.run {
          self?.states[provider]?.error =
            "\(configuration.displayName) sign-in timed out. Click Connect to try again."
          self?.states[provider]?.isConnecting = false
          self?.changed()
        }
      }
      Task { [weak input] in
        try? await Task.sleep(for: .milliseconds(300))
        try? input?.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
      }
    } catch {
      self.states[provider]?.error =
        "Could not start \(configuration.displayName) sign-in: \(error.localizedDescription)"
      self.states[provider]?.isConnecting = false
      self.changed()
    }
  }

  func setEnabled(_ provider: ProviderID, enabled: Bool) {
    self.defaults.set(enabled, forKey: "provider.\(provider.rawValue).enabled")
    self.changed()
    if enabled { self.refresh(provider) }
  }

  func isEnabled(_ provider: ProviderID) -> Bool {
    self.defaults.bool(forKey: "provider.\(provider.rawValue).enabled")
  }

  func monthlySubscriptionCost(for provider: ProviderID) -> Double {
    let key = "subscription.monthlyCost.\(provider.rawValue)"
    if self.defaults.object(forKey: key) != nil {
      return max(0, self.defaults.double(forKey: key))
    }
    let plan = self.states[provider]?.snapshot?.planName?.lowercased() ?? ""
    switch provider {
    case .openAI:
      if plan.contains("plus") { return 20 }
      if plan.contains("business") || plan.contains("team") { return 30 }
      return 200
    case .anthropic:
      if plan.contains("20") { return 200 }
      if plan.contains("5") || plan.contains("premium") { return 100 }
      if plan.contains("team") { return 25 }
      return 20
    case .grok:
      if plan.contains("heavy") { return 300 }
      return 30
    }
  }

  func setMonthlySubscriptionCost(_ value: Double, for provider: ProviderID) {
    self.defaults.set(max(0, value), forKey: "subscription.monthlyCost.\(provider.rawValue)")
    self.changed()
  }

  func renewalDay(for provider: ProviderID) -> Int? {
    let key = "subscription.renewalDay.\(provider.rawValue)"
    guard self.defaults.object(forKey: key) != nil else { return nil }
    return min(31, max(1, self.defaults.integer(forKey: key)))
  }

  func setRenewalDay(_ value: Int?, for provider: ProviderID) {
    let key = "subscription.renewalDay.\(provider.rawValue)"
    if let value {
      self.defaults.set(min(31, max(1, value)), forKey: key)
    } else {
      self.defaults.removeObject(forKey: key)
    }
    self.lastLocalUsageScanAt = nil
    self.notifications.updatePlanRenewal(provider: provider, at: self.nextRenewal(for: provider))
    self.changed()
    self.refreshLocalUsage()
  }

  func renewalStart(for provider: ProviderID, now: Date = Date()) -> Date? {
    guard let renewalDay = self.renewalDay(for: provider) else { return nil }
    let calendar = Calendar.current
    guard let thisMonth = Self.billingDate(day: renewalDay, inMonthContaining: now) else {
      return nil
    }
    if thisMonth <= now { return thisMonth }
    guard let priorMonth = calendar.date(byAdding: .month, value: -1, to: now) else { return nil }
    return Self.billingDate(day: renewalDay, inMonthContaining: priorMonth)
  }

  func nextRenewal(for provider: ProviderID, now: Date = Date()) -> Date? {
    if let reported = self.states[provider]?.snapshot?.billingRenewsAt, reported > now {
      return reported
    }
    guard let day = self.renewalDay(for: provider),
      let start = self.renewalStart(for: provider, now: now),
      let nextMonth = Calendar.current.date(byAdding: .month, value: 1, to: start)
    else { return nil }
    return Self.billingDate(day: day, inMonthContaining: nextMonth)
  }

  private static func billingDate(day: Int, inMonthContaining date: Date) -> Date? {
    let calendar = Calendar.current
    var components = calendar.dateComponents([.year, .month], from: date)
    components.day = 1
    guard let monthStart = calendar.date(from: components),
      let days = calendar.range(of: .day, in: .month, for: monthStart)
    else { return nil }
    components.day = min(day, days.count)
    return calendar.date(from: components).map(calendar.startOfDay(for:))
  }

  /// A plausible 30-day shape for previews and rendering.
  private static func previewSeries(peak: Int64, phase: Double, now: Date) -> [DailyUsage] {
    let calendar = Calendar.current
    return (0..<30).reversed().compactMap { offset in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
      let weekday = calendar.component(.weekday, from: date)
      let quiet = weekday == 1 || weekday == 7
      let wave = 0.5 + 0.42 * sin(Double(offset) / 3.1 + phase)
        + 0.12 * sin(Double(offset) / 1.7 + phase * 2)
      let scale = quiet ? 0.18 : wave
      return DailyUsage(day: Self.previewDayKey(date), tokens: Int64(Double(peak) * scale))
    }
  }

  private static func previewDayKey(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
  }

  func installPreviewSnapshots(now: Date = Date(), scenario: PreviewScenario = .deficit) {
    let usage: (openAI: Double, anthropic: Double, grok: Double) =
      switch scenario {
      case .allReserve, .stale, .unknown: (24, 32, 43)
      case .mixed: (24, 48, 43)
      case .deficit: (61, 32, 43)
      case .multipleDeficit: (61, 60, 70)
      case .exhausted: (100, 32, 43)
      }
    let openAIWindowMinutes: Int? = scenario == .unknown ? nil : 10_080
    let grokFetchedAt = now.addingTimeInterval(scenario == .stale ? -42 * 60 : -126)
    for (provider, day) in zip(ProviderID.allCases, [7, 12, 19]) {
      self.defaults.set(day, forKey: "subscription.renewalDay.\(provider.rawValue)")
    }
    self.states[.openAI] = ProviderViewState(
      provider: .openAI,
      snapshot: UsageSnapshot(
        provider: .openAI,
        planName: "Pro",
        windows: [
          UsageWindow(
            id: "five-hour", label: "5 hours", usedPercent: 28,
            windowMinutes: 300, resetsAt: now.addingTimeInterval(2.4 * 3600)),
          UsageWindow(
            id: "weekly", label: "Weekly", usedPercent: usage.openAI,
            windowMinutes: openAIWindowMinutes, resetsAt: now.addingTimeInterval(4.2 * 86400)),
        ],
        fetchedAt: now.addingTimeInterval(-48),
        source: "Codex app-server"),
      localUsage: LocalUsageSummary(
        provider: .openAI, periodDays: 30,
        inputTokens: 18_620_000_000,
        cachedInputTokens: 15_900_000_000, cacheWriteInputTokens: 48_000_000,
        outputTokens: 92_000_000, apiEquivalentCostUSD: 9_995.11,
        todayTokens: 743_000_000, cycleTokens: 13_800_000_000,
        cycleAPIEquivalentCostUSD: 7_430.22,
        dailyTokens: Self.previewSeries(peak: 1_400_000_000, phase: 0, now: now)))
    self.states[.openAI]?.serviceStatus = ProviderServiceStatus(
      provider: .openAI, health: .operational, detail: "All systems operational",
      pageURL: URL(string: "https://status.openai.com")!)
    self.states[.anthropic] = ProviderViewState(
      provider: .anthropic,
      snapshot: UsageSnapshot(
        provider: .anthropic,
        planName: "Max 20x",
        windows: [
          UsageWindow(
            id: "five-hour", label: "5 hours", usedPercent: 14,
            windowMinutes: 300, resetsAt: now.addingTimeInterval(1.1 * 3600)),
          UsageWindow(
            id: "weekly", label: "Weekly", usedPercent: usage.anthropic,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(3.6 * 86400)),
          UsageWindow(
            id: "sonnet-weekly", label: "Sonnet weekly", usedPercent: 31,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(3.6 * 86400)),
        ],
        fetchedAt: now.addingTimeInterval(-83),
        source: "Claude OAuth",
        includedSpend: IncludedSpend(
          label: "Extra usage", usedMinorUnits: 2_845, limitMinorUnits: 10_000)),
      localUsage: LocalUsageSummary(
        provider: .anthropic, periodDays: 30,
        inputTokens: 3_750_000_000,
        cachedInputTokens: 3_100_000_000, cacheWriteInputTokens: 330_000_000,
        outputTokens: 62_200_000, apiEquivalentCostUSD: 4_173.96,
        todayTokens: 128_000_000, cycleTokens: 2_900_000_000,
        cycleAPIEquivalentCostUSD: 3_205.14,
        dailyTokens: Self.previewSeries(peak: 520_000_000, phase: 1.9, now: now)))
    self.states[.anthropic]?.serviceStatus = ProviderServiceStatus(
      provider: .anthropic, health: .operational, detail: "All systems operational",
      pageURL: URL(string: "https://status.claude.com")!)
    self.states[.grok] = ProviderViewState(
      provider: .grok,
      snapshot: UsageSnapshot(
        provider: .grok,
        planName: "SuperGrok Heavy",
        windows: [
          UsageWindow(
            id: "usage-pool", label: "Weekly", usedPercent: usage.grok,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(2.8 * 86400)),
          UsageWindow(
            id: "product-grokbuild", label: "Grok Build share", usedPercent: 38,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(2.8 * 86400)),
          UsageWindow(
            id: "product-grokchat", label: "Grok Chat share", usedPercent: 5,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(2.8 * 86400)),
        ],
        fetchedAt: grokFetchedAt,
        source: "Grok Build billing API",
        includedSpend: IncludedSpend(
          label: "Included credits", usedMinorUnits: 12_345, limitMinorUnits: 99_900)),
      localUsage: LocalUsageSummary(
        provider: .grok, periodDays: 30,
        inputTokens: 820_000_000,
        outputTokens: 0, apiEquivalentCostUSD: 164, isCostEstimate: true,
        todayTokens: 31_000_000, cycleTokens: 610_000_000,
        cycleAPIEquivalentCostUSD: 122, isCycleCostEstimate: true,
        dailyTokens: Self.previewSeries(peak: 62_000_000, phase: 3.6, now: now)))
    self.states[.grok]?.serviceStatus = ProviderServiceStatus(
      provider: .grok, health: .operational, detail: "All systems operational",
      pageURL: URL(string: "https://status.x.ai")!)
    self.changed()
  }

  private func registerDefaults() {
    self.defaults.register(defaults: [
      "provider.openAI.enabled": true,
      "provider.anthropic.enabled": true,
      "provider.grok.enabled": true,
      // Reading Claude Code's Keychain item is another application's OAuth
      // token, so it is opt-in and stays off until asked for.
      "anthropic.keychainReadAllowed": false,
      "refresh.intervalMinutes": 10,
      "notifications.enabled": true,
      // Smart alerts are the default stream: they only fire when the forecast
      // changes what you should do.
      "notifications.deficit": true,
      "notifications.exhausted": true,
      "notifications.weeklyRenewal": true,
      "notifications.stale": true,
      "notifications.incident": true,
      // Fixed thresholds fire regardless of pace, so they stay off until asked
      // for. A quota warning is rarely worth a sound.
      "notifications.planRenewal": false,
      "notifications.fiveHourRenewal": false,
      "notifications.threshold50": false,
      "notifications.threshold90": false,
      "notifications.sound": false,
      "appearance.theme": AppearanceTheme.matrix.rawValue,
      "appearance.mode": AppearanceMode.system.rawValue,
      "updates.automatic": false,
      "menuBar.provider": "reserve",
      "menuBar.showsRemaining": true,
      "menuBar.showsReset": true,
    ])
  }

  /// Notifies every observer. A change made from inside an observer is coalesced
  /// into one follow-up pass rather than recursing, so observers always settle on
  /// the final state and a store update can never run away.
  private func changed() {
    guard !self.isNotifying else {
      self.needsFollowUpNotification = true
      return
    }
    self.isNotifying = true
    defer { self.isNotifying = false }
    repeat {
      self.needsFollowUpNotification = false
      for observer in self.observers { observer.handler() }
    } while self.needsFollowUpNotification
  }

  private func finishLogin(_ provider: ProviderID, status: Int32) {
    self.loginTimeoutTasks[provider]?.cancel()
    self.loginTimeoutTasks[provider] = nil
    self.loginProcesses[provider] = nil
    self.loginOutputs[provider]?.fileHandleForReading.readabilityHandler = nil
    try? self.loginInputs[provider]?.fileHandleForWriting.close()
    try? self.loginOutputs[provider]?.fileHandleForReading.close()
    self.loginInputs[provider] = nil
    self.loginOutputs[provider] = nil
    self.loginOutputBuffers[provider] = nil
    self.openedLoginURLs.remove(provider)
    self.states[provider]?.isConnecting = false
    if status == 0 {
      self.states[provider]?.error = nil
      self.refresh(provider)
    } else if self.states[provider]?.error == nil {
      self.states[provider]?.error =
        "\(provider.displayName) sign-in was not completed. Click Connect to retry."
      self.changed()
    }
  }

  private func consumeLoginOutput(_ data: Data, for provider: ProviderID) {
    guard !self.openedLoginURLs.contains(provider) else { return }
    let current = self.loginOutputBuffers[provider] ?? Data()
    let remainingCapacity = max(0, 65_536 - current.count)
    self.loginOutputBuffers[provider, default: Data()].append(data.prefix(remainingCapacity))
    guard let buffer = self.loginOutputBuffers[provider],
      let output = String(data: buffer, encoding: .utf8),
      let url = Self.authorizationURL(in: output, for: provider)
    else { return }
    self.openedLoginURLs.insert(provider)
    NSWorkspace.shared.open(url)
  }

  static func authorizationURL(in output: String, for provider: ProviderID) -> URL? {
    let pattern = #"https://[^\s\u001B<>\"]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(output.startIndex..., in: output)
    for match in regex.matches(in: output, range: range) {
      guard let swiftRange = Range(match.range, in: output) else { continue }
      let text = String(output[swiftRange]).trimmingCharacters(
        in: CharacterSet(charactersIn: "'(),.;"))
      guard let url = URL(string: text), url.scheme == "https",
        Self.loginConfiguration(for: provider).trustedHosts.contains(url.host?.lowercased() ?? "")
      else { continue }
      return url
    }
    return nil
  }

  private static func loginConfiguration(for provider: ProviderID) -> LoginConfiguration {
    switch provider {
    case .openAI:
      LoginConfiguration(
        executable: "codex", arguments: ["login"], displayName: "Codex",
        trustedHosts: ["auth.openai.com", "chatgpt.com", "platform.openai.com"])
    case .anthropic:
      LoginConfiguration(
        executable: "claude", arguments: ["auth", "login", "--claudeai"],
        displayName: "Claude Code",
        trustedHosts: ["claude.com", "claude.ai", "platform.claude.com"])
    case .grok:
      LoginConfiguration(
        executable: "grok", arguments: ["login", "--oauth"], displayName: "Grok Build",
        trustedHosts: ["auth.x.ai", "x.ai", "grok.com"])
    }
  }

  private func loadCacheAndStart() async {
    let cached = await self.cache.load()
    for (provider, snapshot) in cached {
      self.states[provider]?.snapshot = snapshot
    }
    self.changed()
    self.startScheduler()
    self.refreshAll(manual: false)
  }

  private func beginLocalUsageRefresh(force: Bool) -> Bool {
    guard !self.isScanningLocalUsage else { return false }
    if !force, let lastLocalUsageScanAt,
      Date().timeIntervalSince(lastLocalUsageScanAt) < self.localUsageScanInterval
    {
      return false
    }
    self.isScanningLocalUsage = true
    return true
  }

  private func refreshLocalUsage() {
    guard self.beginLocalUsageRefresh(force: true) else { return }
    self.changed()
    Task { await self.performLocalUsageScan() }
  }

  private func startScheduler() {
    self.schedulerTask?.cancel()
    let minutes = self.refreshIntervalMinutes
    self.schedulerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(minutes * 60))
        guard !Task.isCancelled else { break }
        await MainActor.run { self?.refreshAll(manual: false) }
      }
    }
  }

  private func performRefreshAll(scanLocalUsage: Bool) async {
    for provider in ProviderID.allCases where self.isEnabled(provider) {
      await self.performRefresh(provider, persist: false, notify: false)
    }
    await self.persistSnapshots()
    if scanLocalUsage {
      await self.performLocalUsageScan(notify: false)
    }
    self.isRefreshingAll = false
    self.changed()
  }

  private func performLocalUsageScan(notify: Bool = true) async {
    let now = Date()
    let result = try? await self.localUsageScanner.scan(periodDays: 30, now: now)
    if let result {
      for provider in ProviderID.allCases {
        self.states[provider]?.localUsage = result[provider]
      }
    }
    self.lastLocalUsageScanAt = now
    self.isScanningLocalUsage = false
    if notify { self.changed() }
  }

  private func beginRefresh(_ provider: ProviderID) -> Bool {
    guard self.states[provider]?.isRefreshing != true else { return false }
    self.states[provider]?.isRefreshing = true
    self.changed()
    return true
  }

  private func performRefresh(
    _ provider: ProviderID,
    persist: Bool = true,
    notify: Bool = true
  ) async {
    // A manual refresh and the scheduled sweep can be in flight for the same
    // provider at once. Without a token the slower request wins simply by
    // finishing last, overwriting newer numbers with older ones.
    let token = (self.refreshTokens[provider] ?? 0) + 1
    self.refreshTokens[provider] = token
    func isCurrent() -> Bool { self.refreshTokens[provider] == token }

    defer {
      if isCurrent() {
        self.states[provider]?.isRefreshing = false
        if notify { self.changed() }
      }
    }

    let fetcher: any UsageProvider =
      switch provider {
      case .openAI: OpenAIProvider()
      case .anthropic: AnthropicProvider(allowKeychainRead: self.claudeKeychainReadAllowed)
      case .grok: GrokProvider()
      }
    let previousHealth = self.states[provider]?.serviceStatus?.health
    let status = await self.serviceStatusClient.fetch(provider)
    guard isCurrent() else { return }
    self.states[provider]?.serviceStatus = status
    self.reportServiceHealth(provider, previous: previousHealth)
    do {
      let previous = self.states[provider]?.snapshot
      let snapshot = try await fetcher.fetch()
      guard isCurrent() else { return }
      self.states[provider]?.snapshot = snapshot
      self.states[provider]?.error = nil
      self.notifications.update(
        previous: previous,
        current: snapshot,
        nextPlanRenewal: self.nextRenewal(for: provider))
      if persist { await self.persistSnapshots() }
    } catch {
      guard isCurrent() else { return }
      // The cached snapshot is deliberately kept: a failed refresh should leave
      // the last known numbers on screen with an error beside them.
      self.states[provider]?.error = String(error.localizedDescription.prefix(500))
    }
    guard isCurrent() else { return }
    self.reportStaleness(provider)
  }

  /// Fires once when a provider's numbers go stale, and clears when they
  /// recover, so the alert tracks the condition rather than the refresh loop.
  private func reportStaleness(_ provider: ProviderID, now: Date = Date()) {
    let lastUpdated = self.states[provider]?.snapshot?.fetchedAt
    let isStale = SmartAlertDetector.isStale(lastUpdated: lastUpdated, now: now)
    if isStale, !self.staleProviders.contains(provider) {
      self.staleProviders.insert(provider)
      if let lastUpdated {
        self.notifications.deliver(
          .dataStale(provider: provider, lastUpdated: lastUpdated), now: now)
      }
    } else if !isStale, self.staleProviders.remove(provider) != nil {
      self.notifications.clearStale(provider)
    }
  }

  /// Fires once when the provider starts reporting trouble, and clears when it
  /// reports normal service again.
  private func reportServiceHealth(_ provider: ProviderID, previous: ServiceHealth?) {
    let status = self.states[provider]?.serviceStatus
    let isIncident = SmartAlertDetector.isIncident(status?.health)
    if isIncident, !self.incidentProviders.contains(provider) {
      self.incidentProviders.insert(provider)
      if let status {
        self.notifications.deliver(
          .serviceIncident(provider: provider, health: status.health, detail: status.detail))
      }
    } else if !isIncident, self.incidentProviders.remove(provider) != nil {
      self.notifications.clearIncident(provider)
    }
  }

  private func persistSnapshots() async {
    let snapshots = Dictionary(
      uniqueKeysWithValues: self.states.compactMap { provider, state in
        state.snapshot.map { (provider, $0) }
      })
    try? await self.cache.save(snapshots)
  }
}

private struct LoginConfiguration {
  let executable: String
  let arguments: [String]
  let displayName: String
  let trustedHosts: Set<String>
}
