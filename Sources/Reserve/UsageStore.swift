import AppKit
import Foundation
import ReserveCore

struct ProviderViewState: Identifiable {
  var id: ProviderID { self.provider }
  let provider: ProviderID
  var snapshot: UsageSnapshot?
  var error: String?
  var isRefreshing = false
  var isConnecting = false
  var localUsage: LocalUsageSummary?
  var subscriptionCostUSD: Double?
  var renewalStart: Date?
  var nextRenewal: Date?
  var serviceStatus: ProviderServiceStatus?
  var requiresConnection = false
  var requiresKeychainAccess = false
  var requiresInstallation = false
  var requiresUpdate = false
  var usageAccessDenied = false
}

enum PreviewScenario: String, CaseIterable {
  case allReserve = "all-reserve"
  case mixed
  case deficit
  case multipleDeficit = "multiple-deficit"
  case exhausted
  case stale
  case unknown
  case keychainAccess = "keychain-access"
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

  private let cache: SnapshotCache
  private let fetchOverride: (@Sendable (ProviderID, Bool) async throws -> UsageSnapshot)?
  private let loginCommandOverride: ((ProviderID) -> (executable: String, arguments: [String]))?
  private let openLoginURL: (URL) -> Bool
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
  private var claudeBrowserPipe: ClaudeLoginBrowserPipe?
  private var loginStorageFailures: Set<ProviderID> = []
  private var loginOutputBuffers: [ProviderID: Data] = [:]
  private var loginOutputGates: [ProviderID: BoundedOutputGate] = [:]
  private var loginGenerations: [ProviderID: Int] = [:]
  private var openedLoginURLs: Set<ProviderID> = []
  private var loginURLs: [ProviderID: URL] = [:]
  private var failedBrowserOpens: Set<ProviderID> = []
  private var loginCompletions: [ProviderID: () -> Void] = [:]
  private var refreshCompletions: [ProviderID: [() -> Void]] = [:]
  private var cancellationGenerations: [ProviderID: Int] = [:]
  private var refreshTasks: [ProviderID: Task<Void, Never>] = [:]
  private var lastLocalUsageScanAt: Date?
  /// The newest refresh request per provider. Results from any older request are
  /// discarded rather than applied.
  private var refreshTokens: [ProviderID: Int] = [:]
  private var pendingRefreshes: Set<ProviderID> = []
  private var pendingKeychainInteractions: Set<ProviderID> = []
  private var keychainAccessCompletions: [ProviderID: [() -> Void]] = [:]
  private var lastRefreshCompletedAt: Date?
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
    notificationsActive: Bool? = nil,
    cache: SnapshotCache = SnapshotCache(),
    fetchOverride: (@Sendable (ProviderID, Bool) async throws -> UsageSnapshot)? = nil,
    loginCommandOverride: ((ProviderID) -> (executable: String, arguments: [String]))? = nil,
    openLoginURL: @escaping (URL) -> Bool = { LoginBrowser.open($0) }
  ) {
    self.cache = cache
    self.fetchOverride = fetchOverride
    self.loginCommandOverride = loginCommandOverride
    self.openLoginURL = openLoginURL
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
    for task in self.refreshTasks.values { task.cancel() }
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
    get { self.keychainReadAllowed(for: .anthropic) }
    set { self.setKeychainReadAllowed(newValue, for: .anthropic) }
  }

  var cursorKeychainReadAllowed: Bool {
    get { self.keychainReadAllowed(for: .cursor) }
    set { self.setKeychainReadAllowed(newValue, for: .cursor) }
  }

  func keychainReadAllowed(for provider: ProviderID) -> Bool {
    self.defaults.bool(forKey: "\(provider.rawValue).keychainReadAllowed")
  }

  func setKeychainReadAllowed(_ allowed: Bool, for provider: ProviderID) {
    guard provider == .anthropic || provider == .cursor else { return }
    self.defaults.set(allowed, forKey: "\(provider.rawValue).keychainReadAllowed")
    if !allowed {
      self.cancelConnection(provider)
      if provider == .cursor {
        Task { await CursorProvider.clearCachedCredential() }
      }
      self.pendingKeychainInteractions.remove(provider)
      self.refreshTokens[provider] = (self.refreshTokens[provider] ?? 0) + 1
      self.states[provider]?.isRefreshing = false
      self.states[provider]?.isConnecting = false
      if provider == .cursor {
        self.states[provider]?.requiresKeychainAccess = true
        self.states[provider]?.requiresConnection = true
        self.states[provider]?.error = "Cursor access is off. Choose Allow access to resume checks."
        self.states[provider]?.localUsage = nil
      } else {
        self.states[provider]?.requiresKeychainAccess = false
      }
    }
    self.changed()
    if allowed { self.refresh(provider) }
  }

  /// Called only from an explicit button or checkbox. This one refresh may ask
  /// macOS for Keychain approval; scheduled refreshes always stay silent.
  func allowClaudeKeychainAccess(onFinished: (() -> Void)? = nil) {
    self.allowKeychainAccess(for: .anthropic, onFinished: onFinished)
  }

  func allowKeychainAccess(for provider: ProviderID, onFinished: (() -> Void)? = nil) {
    guard provider == .anthropic || provider == .cursor else { return }
    self.defaults.set(true, forKey: "\(provider.rawValue).keychainReadAllowed")
    self.states[provider]?.requiresKeychainAccess = true
    self.pendingKeychainInteractions.insert(provider)
    if !self.refresh(provider, queueIfBusy: true, allowKeychainInteraction: true,
      onFinished: onFinished) { self.changed() }
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

  /// Exercises the exact successful-login branch while a provider refresh is
  /// already active. No subprocess or network request is started.
  func exerciseLoginCompletionDuringRefreshForSelfTest(
    _ provider: ProviderID = .grok
  ) -> Bool {
    guard let originalState = self.states[provider] else { return false }
    let originalGeneration = self.loginGenerations[provider]
    let originallyPending = self.pendingRefreshes.contains(provider)
    var notificationCount = 0
    let observer = self.observe { notificationCount += 1 }
    defer {
      self.removeObserver(observer)
      self.states[provider] = originalState
      self.loginGenerations[provider] = originalGeneration
      if originallyPending {
        self.pendingRefreshes.insert(provider)
      } else {
        self.pendingRefreshes.remove(provider)
      }
    }

    self.states[provider]?.isConnecting = true
    self.states[provider]?.isRefreshing = true
    let generation = (originalGeneration ?? 0) + 1
    self.loginGenerations[provider] = generation
    self.finishLogin(provider, status: 0, generation: generation)
    return self.states[provider]?.isConnecting == false
      && self.pendingRefreshes.contains(provider)
      && notificationCount > 0
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

  /// The former updater preference, retained only so existing users and source
  /// UI tests can carry their choice into Sparkle's native preference.
  var automaticUpdateChecks: Bool {
    get { self.defaults.bool(forKey: "updates.automatic") }
    set {
      self.defaults.set(newValue, forKey: "updates.automatic")
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
    Task {
      if manual { await AnthropicProvider.clearPersistedRateLimitBlock() }
      await self.performRefreshAll(scanLocalUsage: scanLocalUsage)
    }
  }

  /// Activation and wake are refresh triggers only when the cached provider
  /// data has actually aged past the configured interval.
  func shouldRefreshAfterResume(now: Date = Date()) -> Bool {
    guard self.automaticRefreshEnabled, !self.isRefreshingAll else { return false }
    return Self.resumeRefreshNeeded(
      states: self.orderedStates.filter { self.isEnabled($0.provider) },
      intervalMinutes: self.refreshIntervalMinutes,
      isRefreshingAll: self.isRefreshingAll,
      lastCompletedAt: self.lastRefreshCompletedAt,
      now: now)
  }

  static func resumeRefreshNeeded(
    states: [ProviderViewState],
    intervalMinutes: Int,
    isRefreshingAll: Bool,
    lastCompletedAt: Date? = nil,
    now: Date
  ) -> Bool {
    guard !isRefreshingAll else { return false }
    // An expired sign-in stays stale until the user connects it. Changing
    // windows must not repeatedly restart checks and rebuild the controls.
    if let lastCompletedAt {
      let elapsed = now.timeIntervalSince(lastCompletedAt)
      if elapsed >= 0 && elapsed < 60 { return false }
    }
    let staleAfter = TimeInterval(max(1, intervalMinutes) * 60)
    return states.contains { state in
      guard !state.isRefreshing else { return false }
      guard let snapshot = state.snapshot else { return true }
      return state.error != nil || now.timeIntervalSince(snapshot.fetchedAt) >= staleAfter
    }
  }

  /// The scheduled sweep. A recent manual refresh can skip the round only while
  /// every enabled provider remains healthy.
  private func refreshAllIfWorthwhile(now: Date = Date()) {
    guard
      Self.scheduledRefreshIsWorthwhile(
        states: ProviderID.allCases.compactMap { self.states[$0] }
          .filter { self.isEnabled($0.provider) },
        lastCompletedAt: self.lastRefreshCompletedAt,
        intervalMinutes: self.refreshIntervalMinutes,
        now: now)
    else { return }
    self.refreshAll(manual: false)
  }

  func refreshAfterResumeIfNeeded(now: Date = Date()) {
    if self.shouldRefreshAfterResume(now: now) { self.refreshAll(manual: false) }
  }

  @discardableResult
  func refresh(
    _ provider: ProviderID,
    queueIfBusy: Bool = false,
    allowKeychainInteraction: Bool = false,
    onFinished: (() -> Void)? = nil
  ) -> Bool {
    guard self.isEnabled(provider) else { return false }
    if let onFinished { self.refreshCompletions[provider, default: []].append(onFinished) }
    guard self.beginRefresh(provider) else {
      if queueIfBusy { self.pendingRefreshes.insert(provider) }
      return false
    }
    if allowKeychainInteraction {
      self.pendingKeychainInteractions.remove(provider)
      self.states[provider]?.isConnecting = true
      self.changed()
    }
    let cancellationGeneration = self.cancellationGenerations[provider] ?? 0
    self.refreshTasks[provider] = Task {
      if provider == .anthropic { await AnthropicProvider.clearPersistedRateLimitBlock() }
      guard (self.cancellationGenerations[provider] ?? 0) == cancellationGeneration else { return }
      await self.performRefresh(
        provider, allowKeychainInteraction: allowKeychainInteraction)
    }
    return true
  }

  func connect(_ provider: ProviderID, forceSignIn: Bool = false, onFinished: (() -> Void)? = nil) {
    if !forceSignIn, self.states[provider]?.requiresKeychainAccess == true
    {
      self.allowKeychainAccess(for: provider, onFinished: onFinished)
      return
    }
    guard self.loginProcesses[provider]?.isRunning != true else { return }
    self.loginStorageFailures.remove(provider)
    if forceSignIn {
      // A protected but unusable old item must not trap an explicit fresh login
      // in the permission path. Fresh credentials still need usage consent.
      self.states[provider]?.requiresKeychainAccess = false
    }
    self.loginCompletions[provider] = onFinished
    let configuration = Self.loginConfiguration(for: provider)
    let generation = (self.loginGenerations[provider] ?? 0) + 1
    self.loginGenerations[provider] = generation
    let commandOverride = self.loginCommandOverride?(provider)
    guard let executable = commandOverride?.executable ?? BinaryLocator.find(configuration.executable) else {
      self.states[provider]?.error =
        "\(ProviderHelperCatalog.definition(for: provider).displayName) needs setup."
      self.states[provider]?.requiresInstallation = true
      self.states[provider]?.requiresUpdate = false
      self.states[provider]?.requiresConnection = false
      self.changed()
      self.loginCompletions.removeValue(forKey: provider)?()
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = commandOverride?.arguments ?? configuration.arguments
    process.environment = BinaryLocator.childEnvironment()
    if provider == .cursor {
      // Cursor documents this switch so the host app owns the browser handoff.
      process.environment?["NO_OPEN_BROWSER"] = "1"
    }
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    process.terminationHandler = { [weak self] completed in
      Task { @MainActor [weak self] in
        self?.finishLogin(
          provider, status: completed.terminationStatus, generation: generation)
      }
    }

    do {
      if provider == .anthropic {
        let browserPipe = try ClaudeLoginBrowserPipe { [weak self] data in
          guard let self, self.loginGenerations[provider] == generation else { return }
          self.consumeLoginOutput(data, for: provider, fromBrowser: true)
        }
        self.claudeBrowserPipe = browserPipe
        process.environment?["BROWSER"] = browserPipe.browserExecutable
        process.environment?["RESERVE_LOGIN_PIPE"] = browserPipe.path
      }
      // Supply the optional welcome confirmation before launching. A delayed
      // write can otherwise reach a cancelled or already-exited login process.
      try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
      try process.run()
      self.loginProcesses[provider] = process
      self.loginInputs[provider] = input
      self.loginOutputs[provider] = output
      self.loginOutputBuffers[provider] = Data()
      let outputGate = BoundedOutputGate(maximumBytes: 65_536)
      self.loginOutputGates[provider] = outputGate
      self.openedLoginURLs.remove(provider)
      self.loginURLs.removeValue(forKey: provider)
      output.fileHandleForReading.readabilityHandler = { [weak self, weak process] handle in
        let data = handle.availableData
        guard !data.isEmpty else {
          handle.readabilityHandler = nil
          return
        }
        switch outputGate.append(data) {
        case .scheduleDrain:
          Task { @MainActor [weak self] in
            self?.drainLoginOutput(
              for: provider, generation: generation, gate: outputGate, handle: handle)
          }
        case .accepted:
          break
        case .overflow:
          handle.readabilityHandler = nil
          if let process { ProcessRunner.stop(process) }
          Task { @MainActor [weak self] in
            guard self?.loginGenerations[provider] == generation else { return }
            self?.states[provider]?.error =
              "\(configuration.displayName) sign-in output exceeded 64 KB. Use Sign in to retry."
            self?.states[provider]?.requiresConnection = true
            self?.states[provider]?.isConnecting = false
            self?.changed()
          }
        case .closed:
          handle.readabilityHandler = nil
        }
      }
      self.states[provider]?.isConnecting = true
      self.states[provider]?.error = nil
      self.states[provider]?.requiresInstallation = false
      self.states[provider]?.requiresUpdate = false
      self.states[provider]?.requiresConnection = false
      self.changed()
      self.loginTimeoutTasks[provider]?.cancel()
      self.loginTimeoutTasks[provider] = Task { [weak self, weak process] in
        try? await Task.sleep(for: .seconds(300))
        guard !Task.isCancelled, process?.isRunning == true else { return }
        if let process { ProcessRunner.stop(process) }
        await MainActor.run {
          guard self?.loginGenerations[provider] == generation else { return }
          self?.states[provider]?.error =
            "\(configuration.displayName) sign-in timed out. Use Sign in to try again."
          self?.states[provider]?.requiresConnection = true
          self?.states[provider]?.isConnecting = false
          self?.changed()
        }
      }
    } catch {
      if provider == .anthropic {
        self.claudeBrowserPipe?.close()
        self.claudeBrowserPipe = nil
      }
      self.states[provider]?.error =
        "Could not start \(configuration.displayName) sign-in: \(error.localizedDescription)"
      self.states[provider]?.requiresConnection = true
      self.states[provider]?.isConnecting = false
      self.changed()
      self.loginCompletions.removeValue(forKey: provider)?()
    }
  }

  func canReopenLoginBrowser(_ provider: ProviderID) -> Bool {
    self.loginURLs[provider] != nil && self.loginProcesses[provider]?.isRunning == true
  }

  func loginFailedToSave(_ provider: ProviderID) -> Bool {
    self.loginStorageFailures.contains(provider)
  }

  func loginBrowserFailedToOpen(_ provider: ProviderID) -> Bool {
    self.failedBrowserOpens.contains(provider)
  }

  @discardableResult
  func reopenLoginBrowser(_ provider: ProviderID) -> Bool {
    guard self.canReopenLoginBrowser(provider), let url = self.loginURLs[provider] else {
      return false
    }
    let opened = self.openLoginURL(url)
    if opened { self.failedBrowserOpens.remove(provider) }
    else { self.failedBrowserOpens.insert(provider) }
    self.changed()
    return opened
  }

  func cancelConnection(_ provider: ProviderID) {
    self.cancellationGenerations[provider] = (self.cancellationGenerations[provider] ?? 0) + 1
    self.loginGenerations[provider] = (self.loginGenerations[provider] ?? 0) + 1
    self.loginCompletions.removeValue(forKey: provider)
    self.refreshCompletions.removeValue(forKey: provider)
    self.refreshTasks.removeValue(forKey: provider)?.cancel()
    self.keychainAccessCompletions.removeValue(forKey: provider)
    self.pendingRefreshes.remove(provider)
    self.pendingKeychainInteractions.remove(provider)
    self.refreshTokens[provider] = (self.refreshTokens[provider] ?? 0) + 1
    let process = self.loginProcesses[provider]
    if let process { ProcessRunner.stop(process) }
    self.cleanUpLogin(provider)
    self.states[provider]?.isConnecting = false
    self.states[provider]?.isRefreshing = false
    self.changed()
  }

  func disconnect(_ provider: ProviderID) {
    self.defaults.set(false, forKey: "provider.\(provider.rawValue).enabled")
    self.defaults.set(false, forKey: "\(provider.rawValue).keychainReadAllowed")
    self.cancelConnection(provider)
    self.states[provider] = ProviderViewState(provider: provider)
    self.staleProviders.remove(provider)
    self.incidentProviders.remove(provider)
    self.notifications.clearStale(provider)
    self.notifications.clearIncident(provider)
    self.rebuildNotificationSchedules()
    Task {
      if provider == .cursor { await CursorProvider.clearCachedCredential() }
      await self.persistSnapshots()
    }
    self.changed()
  }

  func setEnabled(_ provider: ProviderID, enabled: Bool, refreshImmediately: Bool = true) {
    self.defaults.set(enabled, forKey: "provider.\(provider.rawValue).enabled")
    if !enabled {
      self.cancelConnection(provider)
    }
    self.changed()
    if enabled && refreshImmediately { self.refresh(provider) }
  }

  func isEnabled(_ provider: ProviderID) -> Bool {
    self.defaults.bool(forKey: "provider.\(provider.rawValue).enabled")
  }

  func monthlySubscriptionCost(for provider: ProviderID) -> Double? {
    let key = "subscription.monthlyCost.\(provider.rawValue)"
    if let number = self.defaults.object(forKey: key) as? NSNumber,
      number.doubleValue.isFinite
    {
      return max(0, number.doubleValue)
    }
    if let reported = self.states[provider]?.snapshot?.monthlyPriceMinorUnits {
      return Double(reported) / 100
    }
    guard provider == .cursor else { return nil }
    switch self.states[provider]?.snapshot?.planName?.lowercased() {
    case "hobby": return 0
    case "pro": return 20
    case "pro plus", "pro+": return 60
    case "ultra": return 200
    default: return nil
    }
  }

  func setMonthlySubscriptionCost(_ value: Double?, for provider: ProviderID) {
    let key = "subscription.monthlyCost.\(provider.rawValue)"
    if let value, value.isFinite {
      self.defaults.set(max(0, value), forKey: key)
    } else {
      self.defaults.removeObject(forKey: key)
    }
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

  /// Billing dates are pure arithmetic over (day, month) and are recomputed for
  /// every provider on every read of `orderedStates` — which happens several
  /// times per update cycle. `Calendar` date math is not cheap, so the answers
  /// are memoized; there are only a handful of distinct keys in play.
  private static var billingDateCache: [String: Date?] = [:]

  private static func billingDate(day: Int, inMonthContaining date: Date) -> Date? {
    let calendar = Calendar.current
    let month = calendar.dateComponents([.year, .month], from: date)
    let key = "\(day)-\(month.year ?? 0)-\(month.month ?? 0)"
    if let cached = Self.billingDateCache[key] { return cached }
    let computed = Self.computeBillingDate(day: day, inMonthContaining: date)
    if Self.billingDateCache.count > 256 { Self.billingDateCache.removeAll(keepingCapacity: true) }
    Self.billingDateCache[key] = computed
    return computed
  }

  private static func computeBillingDate(day: Int, inMonthContaining date: Date) -> Date? {
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
    for provider in ProviderID.allCases {
      self.defaults.set(true, forKey: "provider.\(provider.rawValue).enabled")
    }
    let usage: (openAI: Double, anthropic: Double, grok: Double, cursor: Double) =
      switch scenario {
      case .allReserve, .stale, .unknown, .keychainAccess: (24, 32, 43, 37)
      case .mixed: (24, 48, 43, 54)
      case .deficit: (61, 32, 43, 37)
      case .multipleDeficit: (61, 60, 70, 68)
      case .exhausted: (100, 32, 43, 37)
      }
    let openAIWindowMinutes: Int? = scenario == .unknown ? nil : 10_080
    let grokFetchedAt = now.addingTimeInterval(scenario == .stale ? -42 * 60 : -126)
    for (provider, day) in zip(ProviderID.allCases, [7, 12, 19, 24]) {
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
    if scenario == .keychainAccess {
      self.states[.anthropic]?.snapshot = nil
      self.states[.anthropic]?.error = UsageProviderError.keychainConsentRequired(.anthropic)
        .localizedDescription
      self.states[.anthropic]?.requiresKeychainAccess = true
    }
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
    self.states[.cursor] = ProviderViewState(
      provider: .cursor,
      snapshot: UsageSnapshot(
        provider: .cursor,
        planName: "Pro+",
        windows: [
          UsageWindow(
            id: "cursor-models", label: "Cursor Models", usedPercent: usage.cursor,
            windowMinutes: 43_200, resetsAt: now.addingTimeInterval(18 * 86_400)),
          UsageWindow(
            id: "other-models", label: "Other Models", usedPercent: 22,
            windowMinutes: 43_200, resetsAt: now.addingTimeInterval(18 * 86_400)),
        ],
        fetchedAt: now.addingTimeInterval(-64),
        source: "Cursor DashboardService",
        includedSpend: IncludedSpend(
          label: "On-demand spending", usedMinorUnits: 1_240, limitMinorUnits: 5_000),
        billingRenewsAt: now.addingTimeInterval(18 * 86_400),
        monthlyPriceMinorUnits: 6_000,
        accountUsage: LocalUsageSummary(
          provider: .cursor, periodDays: 30,
          inputTokens: 2_100_000_000, cachedInputTokens: 1_250_000_000,
          cacheWriteInputTokens: 210_000_000, outputTokens: 48_000_000,
          apiEquivalentCostUSD: 183.42,
          todayTokens: 96_000_000, cycleTokens: 1_820_000_000,
          cycleAPIEquivalentCostUSD: 154.11,
          source: "Cursor account usage", origin: .providerAccount,
          dailyTokens: Self.previewSeries(peak: 210_000_000, phase: 4.8, now: now))),
      localUsage: nil)
    let cursorPreviewUsage = self.states[.cursor]?.snapshot?.accountUsage
    self.states[.cursor]?.localUsage = cursorPreviewUsage
    self.states[.cursor]?.serviceStatus = ProviderServiceStatus(
      provider: .cursor, health: .operational, detail: "All systems operational",
      pageURL: URL(string: "https://status.cursor.com")!)
    self.changed()
  }

  private func registerDefaults() {
    self.defaults.register(defaults: [
      "provider.openAI.enabled": true,
      "provider.anthropic.enabled": true,
      "provider.grok.enabled": true,
      "provider.cursor.enabled": false,
      // Reading Claude Code's Keychain item is another application's OAuth
      // token, so it is opt-in and stays off until asked for.
      "anthropic.keychainReadAllowed": false,
      "cursor.keychainReadAllowed": false,
      // Weekly quotas move slowly, and every sweep spawns a provider CLI that
      // costs far more than Reserve itself. Half-hourly is plenty; the interval
      // remains configurable.
      "refresh.intervalMinutes": 30,
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
      "updates.automatic": true,
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

  private func finishLogin(_ provider: ProviderID, status: Int32, generation: Int) {
    guard self.loginGenerations[provider] == generation else { return }
    if let pending = self.loginOutputGates[provider]?.drain(), !pending.isEmpty {
      self.consumeLoginOutput(pending, for: provider)
    }
    self.loginGenerations[provider] = generation + 1
    let completion = self.loginCompletions.removeValue(forKey: provider)
    self.cleanUpLogin(provider)
    self.states[provider]?.isConnecting = false
    if self.loginStorageFailures.contains(provider) {
      self.states[provider]?.requiresConnection = true
      self.states[provider]?.error = "Cursor could not save its sign-in in macOS Keychain."
      self.changed()
      completion?()
    } else if status == 0 {
      self.states[provider]?.error = nil
      if !self.refresh(provider, queueIfBusy: true, onFinished: { [weak self] in
        // Cursor can exit successfully even when secure storage failed. A
        // fresh status check must confirm that a usable session survived.
        if provider == .cursor, self?.states[provider]?.requiresConnection == true {
          self?.loginStorageFailures.insert(provider)
        }
        completion?()
      }) { self.changed() }
    } else {
      self.states[provider]?.requiresConnection = true
      self.states[provider]?.requiresInstallation = false
      self.states[provider]?.requiresUpdate = false
      self.states[provider]?.usageAccessDenied = false
      if self.states[provider]?.error == nil {
        self.states[provider]?.error =
          "\(provider.displayName) sign-in was not completed. Try again when you are ready."
      }
      self.changed()
      completion?()
    }
  }

  private func cleanUpLogin(_ provider: ProviderID) {
    if provider == .anthropic {
      self.claudeBrowserPipe?.close()
      self.claudeBrowserPipe = nil
    }
    self.loginTimeoutTasks[provider]?.cancel()
    self.loginTimeoutTasks[provider] = nil
    self.loginProcesses[provider] = nil
    self.loginOutputs[provider]?.fileHandleForReading.readabilityHandler = nil
    try? self.loginInputs[provider]?.fileHandleForWriting.close()
    try? self.loginOutputs[provider]?.fileHandleForReading.close()
    self.loginInputs[provider] = nil
    self.loginOutputs[provider] = nil
    self.loginOutputBuffers[provider] = nil
    self.loginOutputGates[provider]?.close()
    self.loginOutputGates[provider] = nil
    self.openedLoginURLs.remove(provider)
    self.loginURLs.removeValue(forKey: provider)
    self.failedBrowserOpens.remove(provider)
  }

  private func drainLoginOutput(
    for provider: ProviderID,
    generation: Int,
    gate: BoundedOutputGate,
    handle: FileHandle
  ) {
    guard self.loginGenerations[provider] == generation else {
      gate.close()
      return
    }
    let data = gate.drain()
    guard !data.isEmpty else { return }
    self.consumeLoginOutput(data, for: provider)
    // Keep draining after the browser opens. A full pipe can prevent the
    // provider from exiting and make a completed sign-in look stuck.
  }

  private func consumeLoginOutput(_ data: Data, for provider: ProviderID, fromBrowser: Bool = false) {
    // Claude prints a manual-code fallback to stdout. Its BROWSER handoff has
    // the loopback callback that can actually finish sign-in inside this app.
    if provider == .anthropic, self.claudeBrowserPipe != nil, !fromBrowser { return }
    let current = self.loginOutputBuffers[provider] ?? Data()
    let remainingCapacity = max(0, 65_536 - current.count)
    self.loginOutputBuffers[provider, default: Data()].append(data.prefix(remainingCapacity))
    guard let buffer = self.loginOutputBuffers[provider],
      let output = String(data: buffer, encoding: .utf8) else { return }
    if provider == .cursor, output.contains("Failed to store authentication tokens") {
      self.loginStorageFailures.insert(provider)
    }
    guard !self.openedLoginURLs.contains(provider),
      let url = Self.authorizationURL(in: output, for: provider)
    else { return }
    self.openedLoginURLs.insert(provider)
    self.loginURLs[provider] = url
    if !self.openLoginURL(url) { self.failedBrowserOpens.insert(provider) }
    self.changed()
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
        // Device login prints a complete link without independently launching
        // Launch Services, which can choose an isolated Chrome instance.
        executable: "grok", arguments: ["login", "--device-auth"], displayName: "Grok Build",
        trustedHosts: ["auth.x.ai", "accounts.x.ai", "x.ai", "grok.com"])
    case .cursor:
      LoginConfiguration(
        executable: "cursor-agent", arguments: ["login"], displayName: "Cursor Agent",
        trustedHosts: ["cursor.com", "auth.cursor.com", "www.cursor.com"])
    }
  }

  private func loadCacheAndStart() async {
    let cached = await self.cache.load()
    for (provider, snapshot) in cached where self.isEnabled(provider) {
      self.states[provider]?.snapshot = snapshot
      if provider == .cursor {
        self.states[provider]?.localUsage = snapshot.accountUsage
      }
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

  /// Whether a scheduled sweep should start provider subprocesses.
  ///
  /// The configured interval is literal. A manual refresh may have completed
  /// shortly before a scheduled tick, so that tick can still be skipped.
  static func scheduledRefreshIsWorthwhile(
    states: [ProviderViewState],
    lastCompletedAt: Date?,
    intervalMinutes: Int,
    now: Date = Date()
  ) -> Bool {
    guard let lastCompletedAt else { return true }
    let interval = TimeInterval(max(1, intervalMinutes) * 60)
    if now.timeIntervalSince(lastCompletedAt) >= interval { return true }
    return states.contains { state in
      if state.error != nil { return true }
      guard let snapshot = state.snapshot else { return true }
      if now.timeIntervalSince(snapshot.fetchedAt) >= UsagePaceState.stalenessLimit { return true }
      return snapshot.windows.contains { window in
        if window.usedPercent >= 80 { return true }
        guard let reset = window.resetsAt else { return false }
        // Near a reset the numbers are about to move.
        return reset.timeIntervalSince(now) <= 3_600 && reset > now
      }
    }
  }

  private func startScheduler() {
    self.schedulerTask?.cancel()
    let minutes = self.refreshIntervalMinutes
    self.schedulerTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(minutes * 60))
        guard !Task.isCancelled else { break }
        await MainActor.run { self?.refreshAllIfWorthwhile() }
      }
    }
  }

  private func performRefreshAll(scanLocalUsage: Bool) async {
    for provider in ProviderID.allCases where self.isEnabled(provider) {
      // Keep each provider cancellable without interrupting the others.
      self.refreshTasks[provider]?.cancel()
      let task = Task { await self.performRefresh(provider, persist: false, notify: false) }
      self.refreshTasks[provider] = task
      await task.value
    }
    await self.persistSnapshots()
    if scanLocalUsage {
      await self.performLocalUsageScan(notify: false)
    }
    self.isRefreshingAll = false
    self.lastRefreshCompletedAt = Date()
    self.changed()
  }

  private func performLocalUsageScan(notify: Bool = true) async {
    let now = Date()
    let result = try? await self.localUsageScanner.scan(periodDays: 30, now: now)
    if let result {
      for provider in ProviderID.allCases {
        guard self.isEnabled(provider) else { continue }
        let snapshot = self.states[provider]?.snapshot
        self.states[provider]?.localUsage = Self.usageAfterLocalScan(
          provider: provider,
          snapshot: snapshot,
          scanned: result[provider])
      }
    }
    self.lastLocalUsageScanAt = now
    self.isScanningLocalUsage = false
    if notify { self.changed() }
  }

  /// Cursor usage comes from its account API, not this Mac's session logs.
  /// A local scan must not erase the account totals that the provider refresh
  /// just fetched and saved.
  static func usageAfterLocalScan(
    provider: ProviderID,
    snapshot: UsageSnapshot?,
    scanned: LocalUsageSummary?
  ) -> LocalUsageSummary? {
    provider == .cursor ? snapshot?.accountUsage : scanned
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
    notify: Bool = true,
    allowKeychainInteraction: Bool = false
  ) async {
    guard self.isEnabled(provider), !Task.isCancelled else { return }
    // A manual refresh and the scheduled sweep can be in flight for the same
    // provider at once. Without a token the slower request wins simply by
    // finishing last, overwriting newer numbers with older ones.
    let token = (self.refreshTokens[provider] ?? 0) + 1
    self.refreshTokens[provider] = token
    func isCurrent() -> Bool {
      self.refreshTokens[provider] == token && self.isEnabled(provider) && !Task.isCancelled
    }

    defer {
      if isCurrent() {
        self.refreshTasks.removeValue(forKey: provider)
        self.states[provider]?.isRefreshing = false
        if allowKeychainInteraction { self.states[provider]?.isConnecting = false }
        var startedFollowUpKeychainInteraction = false
        if self.pendingKeychainInteractions.contains(provider) {
          self.pendingRefreshes.remove(provider)
          startedFollowUpKeychainInteraction = self.refresh(
            provider, allowKeychainInteraction: true)
        } else if self.pendingRefreshes.remove(provider) != nil {
          self.refresh(provider)
        }
        if allowKeychainInteraction, !startedFollowUpKeychainInteraction {
          self.completeKeychainInteraction(for: provider)
        }
        if !self.states[provider, default: ProviderViewState(provider: provider)].isRefreshing {
          let completions = self.refreshCompletions.removeValue(forKey: provider) ?? []
          for completion in completions { completion() }
        }
        if notify { self.changed() }
      }
    }

    let fetcher: any UsageProvider =
      switch provider {
      case .openAI: OpenAIProvider()
      case .anthropic:
        AnthropicProvider(
          allowKeychainRead: self.claudeKeychainReadAllowed,
          allowKeychainInteraction: allowKeychainInteraction)
      case .grok: GrokProvider()
      case .cursor:
        CursorProvider(
          allowKeychainRead: self.cursorKeychainReadAllowed,
          allowKeychainInteraction: allowKeychainInteraction)
      }
    let previousHealth = self.states[provider]?.serviceStatus?.health
    if !allowKeychainInteraction, self.fetchOverride == nil {
      let status = await self.serviceStatusClient.fetch(provider)
      guard isCurrent() else { return }
      self.states[provider]?.serviceStatus = status
      self.reportServiceHealth(provider, previous: previousHealth)
    }
    var providerFetchSucceeded = false
    do {
      let previous = self.states[provider]?.snapshot
      let fetched: UsageSnapshot
      if let fetchOverride {
        fetched = try await fetchOverride(provider, allowKeychainInteraction)
      } else {
        fetched = try await fetcher.fetch()
      }
      guard isCurrent() else { return }
      let snapshot = fetched.withFallbackPlanName(previous?.planName)
      self.states[provider]?.snapshot = snapshot
      self.states[provider]?.error = nil
      self.states[provider]?.requiresConnection = false
      self.states[provider]?.requiresKeychainAccess = false
      self.states[provider]?.requiresInstallation = false
      self.states[provider]?.requiresUpdate = false
      self.states[provider]?.usageAccessDenied = false
      if provider == .cursor {
        self.states[provider]?.localUsage = snapshot.accountUsage
      }
      providerFetchSucceeded = true
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
      self.states[provider]?.requiresConnection =
        (error as? UsageProviderError)?.requiresConnection == true
      if case .executableNotFound = error as? UsageProviderError {
        self.states[provider]?.requiresInstallation = true
      } else {
        self.states[provider]?.requiresInstallation = false
      }
      if case .updateRequired = error as? UsageProviderError {
        self.states[provider]?.requiresUpdate = true
      } else {
        self.states[provider]?.requiresUpdate = false
      }
      let requiresKeychainAccess: Bool
      if case .accessDenied = error as? UsageProviderError {
        self.states[provider]?.usageAccessDenied = true
      } else {
        self.states[provider]?.usageAccessDenied = false
      }
      if case .keychainConsentRequired(let consentProvider) = error as? UsageProviderError {
        requiresKeychainAccess = consentProvider == provider
      } else {
        requiresKeychainAccess = false
      }
      self.states[provider]?.requiresKeychainAccess = requiresKeychainAccess
      if requiresKeychainAccess && !self.pendingKeychainInteractions.contains(provider) {
        self.defaults.set(false, forKey: "\(provider.rawValue).keychainReadAllowed")
      }
    }
    if allowKeychainInteraction, providerFetchSucceeded, self.fetchOverride == nil {
      let status = await self.serviceStatusClient.fetch(provider)
      guard isCurrent() else { return }
      self.states[provider]?.serviceStatus = status
      self.reportServiceHealth(provider, previous: previousHealth)
    }
    guard isCurrent() else { return }
    self.reportStaleness(provider)
  }

  private func completeKeychainInteraction(for provider: ProviderID) {
    let completions = self.keychainAccessCompletions.removeValue(forKey: provider) ?? []
    for completion in completions { completion() }
  }

  func exerciseClaudeAccessCompletionForSelfTest() -> Bool {
    var count = 0
    self.keychainAccessCompletions[.anthropic, default: []].append { count += 1 }
    self.completeKeychainInteraction(for: .anthropic)
    self.completeKeychainInteraction(for: .anthropic)
    return count == 1 && self.keychainAccessCompletions[.anthropic] == nil
  }

  func exerciseCursorAccessDisableForSelfTest() -> Bool {
    self.defaults.set(true, forKey: "cursor.keychainReadAllowed")
    self.states[.cursor]?.isRefreshing = true
    self.states[.cursor]?.isConnecting = true
    self.states[.cursor]?.localUsage = LocalUsageSummary(
      provider: .cursor, periodDays: 30, inputTokens: 1, outputTokens: 1,
      apiEquivalentCostUSD: 0, origin: .providerAccount)
    self.setKeychainReadAllowed(false, for: .cursor)
    return !self.cursorKeychainReadAllowed
      && self.states[.cursor]?.isRefreshing == false
      && self.states[.cursor]?.isConnecting == false
      && self.states[.cursor]?.localUsage == nil
      && self.states[.cursor]?.requiresKeychainAccess == true
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
