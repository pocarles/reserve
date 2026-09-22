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
  /// When this Mac's session logs were last scanned successfully. Separate
  /// from the quota snapshot, which can be fresh while these totals are not.
  var localHistoryCheckedAt: Date?
  /// A failed scan leaves the previous totals in place and says so here.
  /// Cleared by the next successful scan. Never a path or log excerpt.
  var localHistoryError: String?
  var subscriptionCostUSD: Double?
  var subscriptionCostLabel: String? = nil
  var renewalStart: Date?
  var nextRenewal: Date?
  var serviceStatus: ProviderServiceStatus?
  var requiresConnection = false
  var requiresKeychainAccess = false
  var requiresInstallation = false
  var requiresUpdate = false
  var usageAccessDenied = false
  var localHistoryEnabled = false
  /// Presentation preference copied onto each state so the dashboard can mask
  /// personal details without reading preferences itself.
  var hidesPersonalInfo = false
  /// The sign-in helper, or what Reserve prepares for it, could not be
  /// launched at all. That is not a sign-in the person left unfinished, and
  /// launching the same thing again cannot fix it, so it has its own state.
  var signInCouldNotStart = false
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

/// Where plan keys (Z.ai, Kimi) are kept. The app's production store talks to
/// the Keychain on a background executor. Self-tests substitute these
/// main-actor closures so they never touch a real Keychain item.
@MainActor
struct PlanKeyStorage {
  var hasKey: (ProviderID) -> Bool
  var save: (String, ProviderID) throws -> Void
  var delete: (ProviderID) -> Void
  var availabilityAsync: ((ProviderID) async -> KeychainItemAvailability)?
  var saveAsync: ((String, ProviderID) async throws -> Void)?
  var deleteAsync: ((ProviderID) async throws -> Void)?
  /// When set, distinguishes a locked Keychain from a missing key. Fixtures
  /// that only know presence leave this nil.
  var availability: ((ProviderID) -> KeychainItemAvailability)?

  init(
    hasKey: @escaping (ProviderID) -> Bool,
    save: @escaping (String, ProviderID) throws -> Void,
    delete: @escaping (ProviderID) -> Void,
    availability: ((ProviderID) -> KeychainItemAvailability)? = nil,
    availabilityAsync: ((ProviderID) async -> KeychainItemAvailability)? = nil,
    saveAsync: ((String, ProviderID) async throws -> Void)? = nil,
    deleteAsync: ((ProviderID) async throws -> Void)? = nil
  ) {
    self.hasKey = hasKey
    self.save = save
    self.delete = delete
    self.availability = availability
    self.availabilityAsync = availabilityAsync
    self.saveAsync = saveAsync
    self.deleteAsync = deleteAsync
  }
}

/// Injected API-account keys. Production leaves this nil and uses the Keychain
/// executor. Tests pass closures and never touch the login Keychain or network.
@MainActor
struct APIConsumptionKeyAccess {
  var availability: (APIConsumptionProvider) -> KeychainItemAvailability
  var load: (APIConsumptionProvider) throws -> String
  var save: (String, APIConsumptionProvider) throws -> Void
  var delete: (APIConsumptionProvider) -> Void
  var saveAsync: ((String, APIConsumptionProvider) async throws -> Void)? = nil
  var deleteAsync: ((APIConsumptionProvider) async throws -> Void)? = nil
}

@MainActor
final class UsageStore {
  private(set) var states: [ProviderID: ProviderViewState]
  private(set) var isRefreshingAll = false
  /// When the current refresh started, so the header's spinner keeps its phase
  /// across the rebuilds a refresh triggers.
  private(set) var refreshStartedAt: Date?
  private(set) var isScanningLocalUsage = false
  private(set) var apiConsumption: [APIConsumptionProvider: APIConsumptionSnapshot] = [:]
  private(set) var apiConsumptionErrors: [APIConsumptionProvider: String] = [:]
  private(set) var apiConsumptionRefreshing: Set<APIConsumptionProvider> = []

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
  /// Production uses one scanner so its in-memory index survives between
  /// scans. Test and preview stores leave this nil so they never watch this
  /// Mac's session roots.
  private let localUsageScanner: LocalUsageScanner?
  private let localUsageScan: @Sendable (Set<ProviderID>, Date) async throws -> [ProviderID: LocalUsageSummary]
  /// Progress gates retries so a stalled checkpoint cannot create a busy loop.
  private let localUsageProgress: @Sendable () async -> (incomplete: Bool, checkpoints: Int)
  private let localScanContinuationDelay: Duration
  private var localScanNeedsContinuation = false
  /// Cache-only daily history; tests never open the production index.
  private let dailyHistoryLoad: @Sendable (Set<ProviderID>, Date) async -> [ProviderID: CachedUsageHistory]
  private let loginCommandOverride: ((ProviderID) -> (executable: String, arguments: [String]))?
  private let openLoginURL: (URL) -> Bool
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
  private var loginTimeoutMessages: [ProviderID: String] = [:]
  private var loginOutputBuffers: [ProviderID: Data] = [:]
  /// What Claude's `$BROWSER` handoff wrote, kept apart from its stdout, which
  /// carries a manual-code URL that must not win over the loopback callback.
  private var loginBrowserBuffers: [ProviderID: Data] = [:]
  private var loginHandoffTasks: [ProviderID: Task<Void, Never>] = [:]
  /// Sign-ins whose helper has not produced a sign-in page within
  /// `loginHandoffDeadline`. The Connect window comes back for these, so the
  /// person is never left waiting on nothing.
  private var loginHandoffOverdue: Set<ProviderID> = []
  private let loginHandoffDeadline: Duration
  private var loginOutputGates: [ProviderID: BoundedOutputGate] = [:]
  private var loginGenerations: [ProviderID: Int] = [:]
  private var openedLoginURLs: Set<ProviderID> = []
  private var loginURLs: [ProviderID: URL] = [:]
  private var failedBrowserOpens: Set<ProviderID> = []
  private var loginCompletions: [ProviderID: () -> Void] = [:]
  private var refreshCompletions: [ProviderID: [() -> Void]] = [:]
  private var cancellationGenerations: [ProviderID: Int] = [:]
  private var refreshTasks: [ProviderID: Task<Void, Never>] = [:]
  /// When a scan last finished successfully. A failure does not move this, so
  /// the 30-minute interval cannot hide a retry behind a scan that found nothing.
  private var lastLocalUsageScanAt: Date?
  /// Safe wording for the last failed scan. Nil after a successful scan.
  private var localHistoryScanError: String?
  private var claudeQuotaWatcher: QuotaFileWatcher?
  /// One throttle per provider, because detail data is now asked for one card at
  /// a time as well as all at once from the Insights pane.
  private var insightsRequestedAt: [ProviderID: Date] = [:]
  /// The local scan covers every provider at once, so its own throttle is
  /// separate from the per-provider account fetches.
  private var localInsightsRequestedAt: Date?
  var insightsVisible = false
  private var pendingInsightProviders: Set<ProviderID> = []
  #if RESERVE_DEV_AUTOMATION
  private var insightsRequestCounts: [ProviderID: Int] = [:]

  /// How many times a surface has asked for this provider's detail data.
  func insightsRequestCount(for provider: ProviderID) -> Int {
    self.insightsRequestCounts[provider] ?? 0
  }
  #endif

  var localHistoryEnabled: Bool {
    get { self.defaults.bool(forKey: "history.localEnabled") }
    set {
      self.defaults.set(newValue, forKey: "history.localEnabled")
      if !newValue {
        for provider in ProviderID.allCases where self.states[provider]?.localUsage?.origin != .providerAccount {
          self.states[provider]?.localUsage = nil
        }
        // A disabled history pane must not keep showing a failed or fresh scan,
        // and an in-flight scan must not publish after the switch.
        self.localScanGeneration += 1
        self.localScanTask?.cancel()
        self.localScanTask = nil
        self.isScanningLocalUsage = false
        self.localHistoryScanError = nil
        self.localScanNeedsContinuation = false
        self.lastLocalUsageScanAt = nil
        self.publishedDailyHistory = [:]
      }
      self.updateLocalUsageWatches()
      self.changed()
      if newValue {
        self.insightsRequestedAt.removeAll()
        self.localInsightsRequestedAt = nil
        self.requestInsights()
      }
    }
  }

  /// The Insights pane wants every provider's detail data at once.
  func requestInsights() {
    guard self.automaticRefreshEnabled || self.fetchOverride != nil else { return }
    if self.localHistoryEnabled, self.localScanThrottleAllows() { self.refreshLocalUsage() }
    for provider in ProviderID.allCases { self.requestAccountInsights(for: provider) }
  }

  /// Expanding a provider card asks for everything Reserve can know about that
  /// one provider: the activity scan of this Mac, and the account history of
  /// providers whose adapter reports it.
  func requestInsights(for provider: ProviderID) {
    #if RESERVE_DEV_AUTOMATION
    self.insightsRequestCounts[provider, default: 0] += 1
    #endif
    guard self.automaticRefreshEnabled || self.fetchOverride != nil else { return }
    // The scan is shared, so repeated expands reuse its interval rather than
    // rescanning every log directory again.
    if self.localHistoryEnabled { self.refreshLocalUsage(force: false) }
    self.requestAccountInsights(for: provider)
  }

  private func requestAccountInsights(for provider: ProviderID) {
    guard self.isEnabled(provider),
      ProviderDescriptor.forProvider(provider).capabilities.contains(.accountHistory)
    else { return }
    if let requested = self.insightsRequestedAt[provider],
      Date().timeIntervalSince(requested) < 60
    {
      return
    }
    self.insightsRequestedAt[provider] = Date()
    self.pendingInsightProviders.insert(provider)
    self.refresh(provider, queueIfBusy: true)
  }

  private func localScanThrottleAllows(now: Date = Date()) -> Bool {
    if let requested = self.localInsightsRequestedAt, now.timeIntervalSince(requested) < 60 {
      return false
    }
    self.localInsightsRequestedAt = now
    return true
  }

  /// The newest refresh request per provider. Results from any older request are
  /// discarded rather than applied.
  private var refreshTokens: [ProviderID: Int] = [:]
  private var pendingRefreshes: Set<ProviderID> = []
  private var pendingKeychainInteractions: Set<ProviderID> = []
  private var keychainAccessCompletions: [ProviderID: [() -> Void]] = [:]
  private var lastRefreshCompletedAt: Date?
  private var apiConsumptionTokens: [APIConsumptionProvider: Int] = [:]
  private var apiGenerations: [APIConsumptionProvider: Int] = [:]
  private var apiMutationGenerations: [APIConsumptionProvider: Int] = [:]
  private var planMutationGenerations: [ProviderID: Int] = [:]
  /// A setup window can close after its Keychain save has begun. Only that
  /// canceled generation may remove its just-written, unconfirmed key; a
  /// replacement save advances the generation again and is never deleted by
  /// the older completion.
  private var planMutationsNeedingCleanup: [ProviderID: Set<Int>] = [:]
  private var planSaveCleanupEligible: [ProviderID: Set<Int>] = [:]
  private var apiTasks: [APIConsumptionProvider: Task<Void, Never>] = [:]
  /// Presence only. The secret itself is never cached.
  private var apiKeyCache: [APIConsumptionProvider: SavedKeyAvailability] = [:]
  private var planKeyCache: [ProviderID: SavedKeyAvailability] = [:]
  private let injectedPlanKeys: PlanKeyStorage?
  private let injectedAPIKeys: APIConsumptionKeyAccess?
  private let apiConsumptionFetch:
    (@Sendable (APIConsumptionProvider, String) async throws -> APIConsumptionSnapshot)?
  private let serviceStatusFetch: (@Sendable (ProviderID) async -> ProviderServiceStatus?)?
  private let now: @Sendable () -> Date
  private let usesProductionKeychain: Bool
  private let honorsHostRefreshEnvironment: Bool
  private var lowPowerOverride: Bool?
  private var offlineOverride: Bool?
  private var subscriptionSchedules: [ProviderID: ProviderRefreshSchedule] = [:]
  private var apiSchedules: [APIConsumptionProvider: ProviderRefreshSchedule] = [:]
  private var statusGenerations: [ProviderID: Int] = [:]
  private var statusTasks: [ProviderID: Task<Void, Never>] = [:]
  private var localScanGeneration = 0
  private var localScanTask: Task<Void, Never>?
  private var localWatchTask: Task<Void, Never>?
  private var keychainProbeFailures: [String: Int] = [:]
  private var lastKeychainProbeAt: [String: Date] = [:]
  private var apiProbeTasks: [APIConsumptionProvider: Task<Void, Never>] = [:]
  private var planProbeTasks: [ProviderID: Task<Void, Never>] = [:]
  private let subscriptionLimiter = OperationLimiter(limit: 2)
  private let apiLimiter = OperationLimiter(limit: 2)
  // Standing conditions notify on the way in and clear on the way out, so a
  // provider that stays stale or degraded does not notify on every refresh.
  /// The provider whose detail panel is shown below the overview grid.
  ///
  /// Selection is a navigation choice rather than transient disclosure state:
  /// reopening Reserve should return to the provider the person was looking at.
  /// If that provider is no longer enabled, the first enabled provider is used
  /// without destroying the saved choice, so re-enabling it restores it.
  var expandedProvider: ProviderID? {
    get {
      if let raw = self.defaults.string(forKey: "dashboard.selectedProvider"),
        let provider = ProviderID(rawValue: raw), self.isEnabled(provider)
      {
        return provider
      }
      return ProviderID.allCases.first(where: self.isEnabled)
    }
    set {
      if let newValue {
        self.defaults.set(newValue.rawValue, forKey: "dashboard.selectedProvider")
      } else {
        self.defaults.removeObject(forKey: "dashboard.selectedProvider")
      }
      self.changed()
    }
  }
  /// The one API row whose details are open, if any.
  var expandedAPIProvider: APIConsumptionProvider?
  private var staleProviders: Set<ProviderID> = []
  private var incidentProviders: Set<ProviderID> = []
  private let localUsageScanInterval: TimeInterval = 30 * 60

  init(
    defaults: UserDefaults = .standard,
    startAutomatically: Bool = true,
    notificationsActive: Bool? = nil,
    cache: SnapshotCache = SnapshotCache(),
    fetchOverride: (@Sendable (ProviderID, Bool) async throws -> UsageSnapshot)? = nil,
    localUsageScan: (@Sendable (Set<ProviderID>, Date) async throws -> [ProviderID: LocalUsageSummary])? = nil,
    localUsageProgress: (@Sendable () async -> (incomplete: Bool, checkpoints: Int))? = nil,
    localScanContinuationDelay: Duration = .seconds(5),
    dailyHistoryLoad: (@Sendable (Set<ProviderID>, Date) async -> [ProviderID: CachedUsageHistory])? = nil,
    loginCommandOverride: ((ProviderID) -> (executable: String, arguments: [String]))? = nil,
    openLoginURL: @escaping (URL) -> Bool = { LoginBrowser.open($0) },
    planKeys: PlanKeyStorage? = nil,
    loginHandoffDeadline: Duration = .seconds(15),
    apiKeys: APIConsumptionKeyAccess? = nil,
    apiConsumptionFetch: (@Sendable (APIConsumptionProvider, String) async throws -> APIConsumptionSnapshot)? = nil,
    serviceStatusFetch: (@Sendable (ProviderID) async -> ProviderServiceStatus?)? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.injectedPlanKeys = planKeys
    self.injectedAPIKeys = apiKeys
    self.apiConsumptionFetch = apiConsumptionFetch
    self.serviceStatusFetch = serviceStatusFetch
    self.now = now
    let productionStore = planKeys == nil && apiKeys == nil && fetchOverride == nil
      && localUsageScan == nil && localUsageProgress == nil && startAutomatically
    self.usesProductionKeychain = productionStore
    self.honorsHostRefreshEnvironment = productionStore
    self.loginHandoffDeadline = loginHandoffDeadline
    self.cache = cache
    self.fetchOverride = fetchOverride
    self.localUsageScanner = productionStore ? Self.makeProductionLocalUsageScanner() : nil
    if let localUsageScan {
      self.localUsageScan = localUsageScan
    } else if let scanner = self.localUsageScanner {
      self.localUsageScan = { providers, now in
        try await scanner.scan(periodDays: 30, now: now, providers: providers)
      }
    } else {
      // A store built for tests or previews must not read this Mac's logs
      // or the production usage index, even when a refresh asks for history.
      self.localUsageScan = { _, _ in [:] }
    }
    self.localScanContinuationDelay = localScanContinuationDelay
    if let localUsageProgress {
      self.localUsageProgress = localUsageProgress
    } else if let scanner = self.localUsageScanner {
      self.localUsageProgress = {
        (await scanner.scanIncomplete, await scanner.scanMetrics.checkpoints)
      }
    } else {
      self.localUsageProgress = { (false, 0) }
    }
    if let dailyHistoryLoad {
      self.dailyHistoryLoad = dailyHistoryLoad
    } else if let scanner = self.localUsageScanner {
      self.dailyHistoryLoad = { providers, now in
        await scanner.cachedHistory(periodDays: 90, now: now, providers: providers)
      }
    } else {
      self.dailyHistoryLoad = { _, _ in [:] }
    }
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
      if self.claudePassiveUpdatesEnabled {
        self.claudeQuotaWatcher = try? self.makeClaudeQuotaWatcher()
      }
      self.startupTask = Task { [weak self] in
        await self?.loadCacheAndStart()
      }
    }
    if productionStore {
      Task { await APIConsumptionKeychain.deleteLegacyTypefaceAccount() }
    }
  }

  /// Production watches session roots. The history scanner's `watchChanges`
  /// parameter defaults to false; this is the only call site that opts in
  /// once that parameter exists. Every other store leaves the scanner nil.
  private static func makeProductionLocalUsageScanner() -> LocalUsageScanner {
    LocalUsageScanner(watchChanges: true)
  }

  deinit {
    self.schedulerTask?.cancel()
    self.startupTask?.cancel()
    self.localScanTask?.cancel()
    self.localWatchTask?.cancel()
    for task in self.refreshTasks.values { task.cancel() }
    for task in self.apiTasks.values { task.cancel() }
    for task in self.statusTasks.values { task.cancel() }
    for task in self.apiProbeTasks.values { task.cancel() }
    for task in self.planProbeTasks.values { task.cancel() }
    for task in self.loginTimeoutTasks.values { task.cancel() }
    for task in self.loginHandoffTasks.values { task.cancel() }
    for process in self.loginProcesses.values where process.isRunning { process.terminate() }
  }

  var orderedStates: [ProviderViewState] {
    ProviderID.allCases.compactMap { provider in
      guard var state = self.states[provider] else { return nil }
      state.subscriptionCostUSD = self.monthlySubscriptionCost(for: provider)
      state.subscriptionCostLabel = self.defaults.object(forKey: "subscription.monthlyCost.\(provider.rawValue)") != nil
        ? "Your monthly cost" : state.snapshot?.monthlyPriceMinorUnits != nil
          ? "Reported monthly cost" : "Typical monthly cost"
      state.renewalStart = self.renewalStart(for: provider)
      state.nextRenewal = self.nextRenewal(for: provider)
      state.localHistoryEnabled = self.localHistoryEnabled
      state.localHistoryCheckedAt = self.localHistoryEnabled ? self.lastLocalUsageScanAt : nil
      state.localHistoryError = self.localHistoryEnabled ? self.localHistoryScanError : nil
      state.hidesPersonalInfo = self.hidesPersonalInfo
      return state
    }
  }

  var claudePassiveUpdatesEnabled: Bool {
    self.defaults.bool(forKey: "anthropic.passiveStatusline")
  }

  /// Only called after an explicit choice in Claude's provider details.
  func setClaudePassiveUpdatesEnabled(_ enabled: Bool) throws {
    var watcher: QuotaFileWatcher?
    if enabled {
      watcher = try self.makeClaudeQuotaWatcher()
      guard let executable = Bundle.main.executableURL else {
        throw UsageProviderError.unavailable("Reserve could not locate its app. Reopen it and try again.")
      }
      try ClaudeStatuslineBridge.configure(settingsURL: ClaudeStatuslineBridge.settingsURL(),
        executableURL: executable, cacheURL: ClaudeStatuslineBridge.cacheURL())
    } else {
      try ClaudeStatuslineBridge.remove(settingsURL: ClaudeStatuslineBridge.settingsURL())
    }
    self.cancelConnection(.anthropic)
    self.claudeQuotaWatcher?.stop()
    self.claudeQuotaWatcher = watcher
    self.defaults.set(enabled, forKey: "anthropic.passiveStatusline")
    self.states[.anthropic]?.requiresKeychainAccess = false
    self.states[.anthropic]?.requiresConnection = false
    self.changed()
    self.refresh(.anthropic, queueIfBusy: true)
  }

  private func makeClaudeQuotaWatcher() throws -> QuotaFileWatcher {
    try QuotaFileWatcher(cacheURL: ClaudeStatuslineBridge.cacheURL()) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.claudePassiveUpdatesEnabled, self.isEnabled(.anthropic) else { return }
        self.refresh(.anthropic, queueIfBusy: true)
      }
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
    // Every early return completes, so a window waiting on it cannot hang.
    guard provider == .anthropic || provider == .cursor else { onFinished?(); return }
    self.defaults.set(true, forKey: "\(provider.rawValue).keychainReadAllowed")
    self.states[provider]?.requiresKeychainAccess = true
    self.pendingKeychainInteractions.insert(provider)
    if !self.refresh(provider, queueIfBusy: true, allowKeychainInteraction: true,
      onFinished: onFinished) { self.changed() }
  }

  /// Zero means adaptive. Any other saved value is a fixed interval, including
  /// the historical default of 30, so existing users keep the choice they made.
  static let adaptiveRefreshSentinel = 0

  var refreshIntervalMinutes: Int {
    get {
      let stored = self.defaults.integer(forKey: "refresh.intervalMinutes")
      if stored == Self.adaptiveRefreshSentinel, self.refreshModeIsAdaptive { return 0 }
      return max(1, stored)
    }
    set {
      if newValue == Self.adaptiveRefreshSentinel {
        self.defaults.set(Self.adaptiveRefreshSentinel, forKey: "refresh.intervalMinutes")
        self.defaults.set(true, forKey: "refresh.adaptive")
      } else {
        self.defaults.set(max(1, newValue), forKey: "refresh.intervalMinutes")
        self.defaults.set(false, forKey: "refresh.adaptive")
      }
      if self.automaticRefreshEnabled { self.startScheduler() }
    }
  }

  private var refreshModeIsAdaptive: Bool {
    self.defaults.bool(forKey: "refresh.adaptive")
  }

  /// Fixed intervals report themselves. Adaptive asks the pure policy using
  /// the last dashboard open and the machine state gathered here.
  func effectiveRefreshIntervalMinutes(now: Date = Date(), constrained: Bool? = nil) -> Int {
    let stored = self.refreshIntervalMinutes
    guard stored == Self.adaptiveRefreshSentinel else { return max(1, stored) }
    let machineConstrained = constrained ?? Self.machineIsRefreshConstrained()
    return AdaptiveRefreshPolicy.minutes(
      now: now,
      lastDashboardOpenAt: self.lastDashboardOpenAt,
      constrained: machineConstrained)
  }

  static func machineIsRefreshConstrained(
    lowPowerMode: Bool = ProcessInfo.processInfo.isLowPowerModeEnabled,
    thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
  ) -> Bool {
    if lowPowerMode { return true }
    switch thermal {
    case .serious, .critical: return true
    default: return false
    }
  }

  /// Recorded when the dashboard is shown. Adaptive refresh may move the next
  /// tick forward; it never postpones one that was already sooner.
  private(set) var lastDashboardOpenAt: Date?

  func noteDashboardOpened(at date: Date = Date()) {
    self.lastDashboardOpenAt = date
    guard self.refreshIntervalMinutes == Self.adaptiveRefreshSentinel else { return }
    self.bringAdaptiveTickForward(now: date)
  }

  var hidesPersonalInfo: Bool {
    get { self.defaults.bool(forKey: "privacy.hidePersonalInfo") }
    set {
      self.defaults.set(newValue, forKey: "privacy.hidePersonalInfo")
      self.changed()
    }
  }

  var dashboardHotKey: DashboardHotKeyChoice {
    get { DashboardHotKeyChoice.persisted(self.defaults.string(forKey: "hotkey.dashboard")) }
    set {
      self.defaults.set(newValue.rawValue, forKey: "hotkey.dashboard")
      self.changed()
    }
  }

  /// Last registration outcome. Settings reads this; quota updates do not
  /// change it, so the hot key is not registered again.
  private(set) var dashboardHotKeyStatus: DashboardHotKeyRegistration = .inactive

  func setDashboardHotKeyStatus(_ status: DashboardHotKeyRegistration) {
    guard self.dashboardHotKeyStatus != status else { return }
    self.dashboardHotKeyStatus = status
    self.changed()
  }

  /// Days of cached daily history Insights may chart. Switching this never
  /// scans session logs; it only changes which cached range is presented.
  var insightHistoryDays: Int {
    get {
      let stored = self.defaults.integer(forKey: "insights.historyDays")
      return [7, 30, 90].contains(stored) ? stored : 30
    }
    set {
      let days = [7, 30, 90].contains(newValue) ? newValue : 30
      self.defaults.set(days, forKey: "insights.historyDays")
      self.changed()
    }
  }

  /// Published daily aggregates. Empty until a successful scan records them.
  /// Range changes read this dictionary and do not scan.
  private(set) var publishedDailyHistory: [ProviderID: [InsightHistoryDay]] = [:]
  private var dailyHistoryLoads = 0

  var dailyHistoryLoadCountForTesting: Int { self.dailyHistoryLoads }

  func insightSeries(for provider: ProviderID, now: Date = Date()) -> InsightHistorySeries {
    return InsightHistoryRange.series(
      provider: provider,
      days: self.insightHistoryDays,
      now: now,
      published: self.publishedDailyHistory)
  }

  /// Test-only publication. Production scans will call the same replacement
  /// once the cache reader exists. Overlapping days replace; they do not add.
  func publishDailyHistoryForTesting(_ days: [InsightHistoryDay], provider: ProviderID) {
    var merged: [String: InsightHistoryDay] = [:]
    for day in self.publishedDailyHistory[provider] ?? [] {
      merged[day.day] = day
    }
    for day in days {
      merged[day.day] = day
    }
    self.publishedDailyHistory[provider] = merged.values.sorted { $0.day < $1.day }
    self.changed()
  }

  /// Replaces published days from a cache-only read. Does not scan session
  /// roots. Disabled history and disabled providers are dropped.
  func publishCachedHistory(_ histories: [ProviderID: CachedUsageHistory]) {
    guard self.localHistoryEnabled else {
      self.publishedDailyHistory = [:]
      return
    }
    var next: [ProviderID: [InsightHistoryDay]] = [:]
    for (provider, history) in histories {
      guard self.isEnabled(provider),
        ProviderDescriptor.forProvider(provider).capabilities.contains(.localHistory)
      else { continue }
      next[provider] = history.days.map {
        InsightHistoryDay(day: $0.day, tokens: $0.tokens, costUSD: $0.costUSD)
      }.sorted { $0.day < $1.day }
    }
    self.publishedDailyHistory = next
    self.dailyHistoryLoads += 1
  }

  /// Cache-only load. Counts as a history load, never as a session scan.
  func loadPublishedDailyHistory(now: Date = Date()) async {
    guard self.localHistoryEnabled else {
      self.publishedDailyHistory = [:]
      self.dailyHistoryLoads += 1
      return
    }
    let enabled = Set(ProviderID.allCases.filter { self.isEnabled($0) })
    let loaded = await self.dailyHistoryLoad(enabled, now)
    self.publishCachedHistory(loaded)
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
      // A pin saved for a provider this build no longer supports falls back to
      // the automatic choice rather than pinning nothing at all.
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
    self.beginRefreshWave(trigger: manual ? .manual : .automatic)
  }

  /// Manual refresh still reads every eligible provider. Automatic and
  /// activation waves only include providers whose own schedule is due, so
  /// one failure does not pull fresh providers along. History starts here
  /// and is not awaited by the quota wave.
  private func beginRefreshWave(trigger: RefreshTrigger) {
    guard !self.isRefreshingAll else { return }
    let now = self.now()
    if trigger != .manual, self.discretionaryRefreshIsSuppressed(now: now) { return }
    let manual = trigger == .manual
    if (manual || self.insightsVisible || self.localScanNeedsContinuation)
      && self.beginLocalUsageRefresh(force: manual || self.localScanNeedsContinuation) {
      self.startDetachedLocalUsageScan()
    }
    self.retryLockedKeychainReads(trigger: trigger, now: now)
    self.refreshDueAPIConsumption(trigger: trigger, now: now)
    let providers = self.dueSubscriptionProviders(trigger: trigger, now: now)
    guard !providers.isEmpty else { return }
    self.isRefreshingAll = true
    self.refreshStartedAt = now
    for provider in providers {
      self.states[provider]?.isRefreshing = true
    }
    self.changed()
    Task { await self.performRefreshAll(providers: providers) }
  }

  /// Activation and wake are refresh triggers only when the cached provider
  /// data has actually aged past the configured interval.
  func shouldRefreshAfterResume(now: Date = Date()) -> Bool {
    guard !self.isRefreshingAll else { return false }
    guard !self.discretionaryRefreshIsSuppressed(now: now) else { return false }
    if self.localScanNeedsContinuation && !self.isScanningLocalUsage { return true }
    if self.hasDueKeychainProbe(trigger: .activation, now: now) { return true }
    guard self.automaticRefreshEnabled else { return false }
    if !self.dueSubscriptionProviders(trigger: .activation, now: now).isEmpty { return true }
    if !self.dueAPIProviders(trigger: .activation, now: now).isEmpty { return true }
    return false
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
    let now = now
    guard !self.discretionaryRefreshIsSuppressed(now: now) else { return }
    let due = !self.dueSubscriptionProviders(trigger: .automatic, now: now).isEmpty
      || !self.dueAPIProviders(trigger: .automatic, now: now).isEmpty
      || self.hasDueKeychainProbe(trigger: .automatic, now: now)
    guard due else { return }
    self.beginRefreshWave(trigger: .automatic)
  }

  func refreshAfterResumeIfNeeded(now: Date = Date()) {
    guard !self.discretionaryRefreshIsSuppressed(now: now) else { return }
    if self.automaticRefreshEnabled {
      self.refreshDueProvidersAfterActivation(now: now)
    } else {
      self.retryLockedKeychainReads(trigger: .activation, now: now)
    }
  }

  /// Activation/wake entry. Discretionary suppression and per-provider
  /// backoff still apply. A locked keychain is probed again without a fetch
  /// of providers that are still fresh.
  func refreshDueProvidersAfterActivation(now: Date = Date()) {
    guard !self.discretionaryRefreshIsSuppressed(now: now) else { return }
    self.beginRefreshWave(trigger: .activation)
  }

  /// Low Power Mode and offline are discretionary. The app reports them here;
  /// until it does, offline stays false and Low Power Mode is read only for
  /// the production store. Clearing a suppression resumes due work once.
  func noteRefreshEnvironment(lowPowerMode: Bool? = nil, offline: Bool? = nil) {
    let wasSuppressed = self.discretionaryRefreshIsSuppressed()
    if let lowPowerMode { self.lowPowerOverride = lowPowerMode }
    if let offline { self.offlineOverride = offline }
    if wasSuppressed, !self.discretionaryRefreshIsSuppressed() {
      if self.localScanNeedsContinuation && self.beginLocalUsageRefresh(force: true) {
        self.startDetachedLocalUsageScan()
      }
      self.refreshDueProvidersAfterActivation()
    }
    if self.automaticRefreshEnabled { self.startScheduler() }
  }

  @discardableResult
  func refresh(
    _ provider: ProviderID,
    queueIfBusy: Bool = false,
    allowKeychainInteraction: Bool = false,
    trigger: RefreshTrigger = .manual,
    onFinished: (() -> Void)? = nil
  ) -> Bool {
    // A disabled provider has nothing to check; the caller still hears back.
    guard self.isEnabled(provider) else { onFinished?(); return false }
    let effective: RefreshTrigger = allowKeychainInteraction && trigger == .manual
      ? .connectionRecovery : trigger
    let decision = self.admission(for: provider, trigger: effective, now: self.now())
    guard decision.allowed else { onFinished?(); return false }
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
      guard (self.cancellationGenerations[provider] ?? 0) == cancellationGeneration else { return }
      await self.performRefresh(
        provider, allowKeychainInteraction: allowKeychainInteraction)
    }
    return true
  }

  /// Every path calls `onFinished` exactly once: at once when nothing can be
  /// started, or when the sign-in (or the one already running) ends.
  func connect(_ provider: ProviderID, onFinished: (() -> Void)? = nil) {
    // A protected sign-in that only needs permission is never replaced by a
    // fresh login from here: that would sign the person out of the CLI too.
    if self.states[provider]?.requiresKeychainAccess == true {
      self.allowKeychainAccess(for: provider, onFinished: onFinished)
      return
    }
    // A key-connected plan is connected by saving its key, never by a CLI.
    // Callers route those to the key field; this only re-reads usage.
    if ProviderDescriptor.forProvider(provider).usesAPIKey {
      if !self.isEnabled(provider) { onFinished?(); return }
      self.refresh(provider, queueIfBusy: true, trigger: .connectionRecovery) { onFinished?() }
      return
    }
    // A helper that signs in only inside its own terminal session (the
    // Antigravity CLI) is never started here: without a terminal it would
    // either fail or wait on a prompt. The person signs in there; this only
    // checks whether that has happened.
    if ProviderDescriptor.forProvider(provider).signsInFromTerminal {
      if !self.isEnabled(provider) { onFinished?(); return }
      self.refresh(provider, queueIfBusy: true, trigger: .connectionRecovery) { onFinished?() }
      return
    }
    guard let configuration = Self.loginConfiguration(for: provider) else {
      onFinished?()
      return
    }
    if self.loginProcesses[provider]?.isRunning == true {
      // One sign-in at a time. The caller hears back when the running one
      // ends, alongside whoever started it.
      let running = self.loginCompletions[provider]
      self.loginCompletions[provider] = {
        running?()
        onFinished?()
      }
      return
    }
    self.loginStorageFailures.remove(provider)
    self.loginCompletions[provider] = onFinished
    let generation = (self.loginGenerations[provider] ?? 0) + 1
    self.loginGenerations[provider] = generation
    let commandOverride = self.loginCommandOverride?(provider)
    guard let executable = commandOverride?.executable ?? BinaryLocator.find(configuration.executable) else {
      self.markHelperMissing(provider)
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
      // Claude Code reads its stdin as a pasted authorization code and answers
      // an empty line with "Invalid code", so it is left alone.
      if provider != .anthropic {
        try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
      }
      #if RESERVE_DEV_AUTOMATION
      self.loginLaunchCounts[provider, default: 0] += 1
      #endif
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
      self.states[provider]?.signInCouldNotStart = false
      self.states[provider]?.requiresInstallation = false
      self.states[provider]?.requiresUpdate = false
      self.states[provider]?.requiresConnection = false
      self.changed()
      self.loginTimeoutTasks[provider]?.cancel()
      self.loginTimeoutMessages.removeValue(forKey: provider)
      self.loginTimeoutTasks[provider] = Task { [weak self, weak process] in
        try? await Task.sleep(for: .seconds(300))
        guard !Task.isCancelled, process?.isRunning == true else { return }
        await MainActor.run {
          guard self?.loginGenerations[provider] == generation else { return }
          // Stopping the helper ends in finishLogin, which checks usage before
          // calling the sign-in lost. The timeout only supplies the wording.
          self?.loginTimeoutMessages[provider] =
            "\(configuration.displayName) sign-in timed out. Use Sign in to try again."
        }
        if let process { ProcessRunner.stop(process) }
      }
      self.scheduleLoginHandoffDeadline(for: provider, generation: generation)
    } catch {
      if provider == .anthropic {
        self.claudeBrowserPipe?.close()
        self.claudeBrowserPipe = nil
      }
      self.loginGenerations[provider] = generation + 1
      self.states[provider]?.error =
        "Could not start \(configuration.displayName) sign-in: \(error.localizedDescription)"
      self.states[provider]?.requiresConnection = true
      self.states[provider]?.signInCouldNotStart = true
      self.states[provider]?.isConnecting = false
      self.changed()
      self.loginCompletions.removeValue(forKey: provider)?()
    }
  }

  #if RESERVE_DEV_AUTOMATION
  private var loginLaunchCounts: [ProviderID: Int] = [:]

  /// How many times a sign-in helper launch was attempted, for the self-tests.
  func loginLaunchCount(for provider: ProviderID) -> Int {
    self.loginLaunchCounts[provider] ?? 0
  }
  #endif

  private func markHelperMissing(_ provider: ProviderID) {
    self.states[provider]?.error =
      "\(ProviderHelperCatalog.definition(for: provider)?.displayName ?? provider.displayName) needs setup."
    self.states[provider]?.requiresInstallation = true
    self.states[provider]?.requiresUpdate = false
    self.states[provider]?.requiresConnection = false
    self.states[provider]?.signInCouldNotStart = false
    self.changed()
  }

  /// A helper that has not produced a sign-in page by the deadline is shown
  /// as waiting rather than left invisible. For Claude, whose `$BROWSER`
  /// handoff is preferred, a trusted URL printed on stdout becomes usable
  /// from this point on.
  private func scheduleLoginHandoffDeadline(for provider: ProviderID, generation: Int) {
    self.loginHandoffTasks[provider]?.cancel()
    self.loginHandoffOverdue.remove(provider)
    let deadline = self.loginHandoffDeadline
    self.loginHandoffTasks[provider] = Task { [weak self] in
      try? await Task.sleep(for: deadline)
      guard !Task.isCancelled, let self, self.loginGenerations[provider] == generation,
        self.loginProcesses[provider]?.isRunning == true, self.loginURLs[provider] == nil
      else { return }
      self.loginHandoffOverdue.insert(provider)
      if let buffer = self.loginOutputBuffers[provider],
        let output = String(data: buffer, encoding: .utf8)
      {
        self.openLoginURLIfFound(in: output, for: provider)
      }
      self.changed()
    }
  }

  /// True once the helper has missed the handoff deadline, until the sign-in
  /// ends. A URL that arrives later keeps it set, so the window that came
  /// back stays with its Open browser again action.
  func loginHandoffIsOverdue(_ provider: ProviderID) -> Bool {
    self.loginHandoffOverdue.contains(provider)
  }

  /// "Try again" after a sign-in could not start. It re-checks what a launch
  /// needs (the helper, and Claude's private browser handoff) without starting
  /// a sign-in, so a broken installation is reported instead of repeated.
  func recheckSignInStart(_ provider: ProviderID) {
    guard let configuration = Self.loginConfiguration(for: provider) else { return }
    guard let executable = self.loginCommandOverride?(provider).executable
      ?? BinaryLocator.find(configuration.executable)
    else {
      self.markHelperMissing(provider)
      return
    }
    var problem: String?
    if !FileManager.default.isExecutableFile(atPath: executable) {
      problem = "\(configuration.displayName) could not be opened."
    } else if provider == .anthropic {
      do { try ClaudeLoginBrowserPipe { _ in }.close() }
      catch { problem = error.localizedDescription }
    }
    if let problem {
      self.states[provider]?.error = "Could not start \(configuration.displayName) sign-in: \(problem)"
      self.states[provider]?.signInCouldNotStart = true
    } else {
      self.states[provider]?.error = nil
      self.states[provider]?.signInCouldNotStart = false
    }
    self.states[provider]?.requiresConnection = true
    self.changed()
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
    if let mutation = self.planMutationGenerations[provider],
      self.planSaveCleanupEligible[provider]?.contains(mutation) == true
    {
      self.planMutationsNeedingCleanup[provider, default: []].insert(mutation)
    }
    self.planMutationGenerations[provider] = (self.planMutationGenerations[provider] ?? 0) + 1
    self.cancellationGenerations[provider] = (self.cancellationGenerations[provider] ?? 0) + 1
    self.loginGenerations[provider] = (self.loginGenerations[provider] ?? 0) + 1
    self.loginCompletions.removeValue(forKey: provider)
    self.refreshCompletions.removeValue(forKey: provider)
    self.refreshTasks.removeValue(forKey: provider)?.cancel()
    self.planProbeTasks.removeValue(forKey: provider)?.cancel()
    self.statusGenerations[provider] = (self.statusGenerations[provider] ?? 0) + 1
    self.statusTasks.removeValue(forKey: provider)?.cancel()
    if self.usesProductionKeychain {
      Task { await self.serviceStatusClient.invalidate(provider) }
    }
    self.keychainAccessCompletions.removeValue(forKey: provider)
    self.pendingRefreshes.remove(provider)
    self.pendingInsightProviders.remove(provider)
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
    if provider == .anthropic, self.claudePassiveUpdatesEnabled {
      do { try self.setClaudePassiveUpdatesEnabled(false) }
      catch {
        self.states[provider]?.error = "Claude’s shared updates could not be removed. \(error.localizedDescription)"
        self.changed()
        return
      }
    }
    self.defaults.set(false, forKey: "provider.\(provider.rawValue).enabled")
    self.defaults.set(false, forKey: "\(provider.rawValue).keychainReadAllowed")
    self.cancelConnection(provider)
    self.states[provider] = ProviderViewState(provider: provider)
    self.staleProviders.remove(provider)
    self.incidentProviders.remove(provider)
    self.notifications.clearStale(provider)
    self.notifications.clearIncident(provider)
    self.rebuildNotificationSchedules()
    self.updateLocalUsageWatches()
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
    self.updateLocalUsageWatches()
    self.changed()
    if enabled && refreshImmediately { self.refresh(provider, trigger: .connectionRecovery) }
  }

  func isEnabled(_ provider: ProviderID) -> Bool {
    self.defaults.bool(forKey: "provider.\(provider.rawValue).enabled")
  }

  func isAPIConsumptionEnabled(_ provider: APIConsumptionProvider) -> Bool {
    self.defaults.bool(forKey: "apiConsumption.\(provider.rawValue).enabled")
  }

  func setAPIConsumptionEnabled(_ provider: APIConsumptionProvider, enabled: Bool) {
    self.defaults.set(enabled, forKey: "apiConsumption.\(provider.rawValue).enabled")
    if !enabled {
      self.apiMutationGenerations[provider] = (self.apiMutationGenerations[provider] ?? 0) + 1
      self.invalidateAPIWork(provider)
    }
    self.changed()
    if enabled { self.refreshAPIConsumption(provider) }
  }

  func apiConsumptionKeyAvailability(
    _ provider: APIConsumptionProvider
  ) -> SavedKeyAvailability {
    if let known = self.apiKeyCache[provider] { return known }
    if let injected = self.injectedAPIKeys {
      return SavedKeyAvailability(injected.availability(provider))
    }
    if self.usesProductionKeychain { self.scheduleProductionAPIProbe(provider) }
    return self.usesProductionKeychain ? .unknown : .missing
  }

  func hasAPIConsumptionKey(_ provider: APIConsumptionProvider) -> Bool {
    self.apiConsumptionKeyAvailability(provider) == .present
  }

  /// Stores a pasted key and turns measurement on. The key is written to
  /// Keychain only; preferences record that the option is enabled.
  /// Validation errors throw before any in-flight read is cancelled.
  func saveAPIConsumptionKey(_ key: String, for provider: APIConsumptionProvider) throws {
    guard let injected = self.injectedAPIKeys else {
      throw UsageProviderError.unavailable("API key storage requires the async save path.")
    }
    try injected.save(key, provider)
    self.adoptSavedAPIKey(provider)
  }

  func saveAPIConsumptionKey(_ key: String, for provider: APIConsumptionProvider) async throws {
    if self.injectedAPIKeys == nil, !self.usesProductionKeychain {
      throw UsageProviderError.unavailable("API key storage is not configured.")
    }
    if self.usesProductionKeychain {
      _ = try APIConsumptionKeychain.normalized(key, for: provider)
    }
    let mutation = self.beginAPIKeyMutation(provider)
    do {
      if let injected = self.injectedAPIKeys {
        if let saveAsync = injected.saveAsync { try await saveAsync(key, provider) }
        else { try injected.save(key, provider) }
      } else {
        try await APIConsumptionKeychain.save(key, for: provider)
      }
    } catch {
      guard self.apiMutationGenerations[provider] == mutation else { throw CancellationError() }
      self.reportAPIKeyMutationFailure(error, provider: provider)
      throw error
    }
    guard self.apiMutationGenerations[provider] == mutation else { throw CancellationError() }
    self.adoptSavedAPIKey(provider)
  }

  func removeAPIConsumptionKey(_ provider: APIConsumptionProvider) {
    guard let injected = self.injectedAPIKeys else {
      self.apiConsumptionErrors[provider] = "Removing this key requires the async Keychain path."
      self.changed()
      return
    }
    _ = self.beginAPIKeyMutation(provider)
    injected.delete(provider)
    self.finishAPIKeyRemoval(provider)
  }

  func removeAPIConsumptionKeyAsync(_ provider: APIConsumptionProvider) async throws {
    let mutation = self.beginAPIKeyMutation(provider)
    do {
      if let injected = self.injectedAPIKeys {
        if let deleteAsync = injected.deleteAsync { try await deleteAsync(provider) }
        else { injected.delete(provider) }
      } else if self.usesProductionKeychain {
        try await APIConsumptionKeychain.delete(for: provider)
      } else {
        throw UsageProviderError.unavailable("API key storage is not configured.")
      }
    } catch {
      guard self.apiMutationGenerations[provider] == mutation else { throw CancellationError() }
      self.reportAPIKeyMutationFailure(error, provider: provider)
      throw error
    }
    guard self.apiMutationGenerations[provider] == mutation else { throw CancellationError() }
    self.finishAPIKeyRemoval(provider)
  }

  // MARK: Plan keys

  func planKeyAvailability(for provider: ProviderID) -> SavedKeyAvailability {
    guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return .missing }
    if let known = self.planKeyCache[provider] { return known }
    if let injected = self.injectedPlanKeys {
      if let availability = injected.availability {
        return SavedKeyAvailability(availability(provider))
      }
      return injected.hasKey(provider) ? .present : .missing
    }
    if self.usesProductionKeychain { self.scheduleProductionPlanProbe(provider) }
    return self.usesProductionKeychain ? .unknown : .missing
  }

  /// Whether an API-key plan (Z.ai, Kimi) has a key. Reads the cached
  /// tri-state; a locked Keychain is not reported as present or as a saved miss.
  func hasPlanKey(_ provider: ProviderID) -> Bool {
    self.planKeyAvailability(for: provider) == .present
  }

  /// Stores a pasted plan key and connects the provider. The key itself never
  /// reaches preferences, logs or the snapshot cache. An in-flight read is
  /// invalidated only after the new key is accepted, then a new read starts.
  func savePlanKey(
    _ key: String, for provider: ProviderID, onFinished: (() -> Void)? = nil
  ) throws {
    guard let injected = self.injectedPlanKeys else {
      throw UsageProviderError.unavailable("Plan key storage requires the async save path.")
    }
    try injected.save(key, provider)
    self.adoptSavedPlanKey(provider, onFinished: onFinished)
  }

  func savePlanKey(
    _ key: String, for provider: ProviderID, onFinished: (() -> Void)? = nil
  ) async throws {
    if self.injectedPlanKeys == nil, !self.usesProductionKeychain {
      throw UsageProviderError.unavailable("Plan key storage is not configured.")
    }
    if self.usesProductionKeychain { _ = try PlanKeyKeychain.normalized(key, for: provider) }
    let cleanupIfCanceled = self.planKeyAvailability(for: provider) == .missing
    let mutation = self.beginPlanKeyMutation(provider)
    if cleanupIfCanceled {
      self.planSaveCleanupEligible[provider, default: []].insert(mutation)
    }
    defer { self.finishPlanSaveMutation(provider, generation: mutation) }
    do {
      if let injected = self.injectedPlanKeys {
        if let saveAsync = injected.saveAsync { try await saveAsync(key, provider) }
        else { try injected.save(key, provider) }
      } else {
        try await PlanKeyKeychain.save(key, for: provider)
      }
    } catch {
      guard self.planMutationGenerations[provider] == mutation else {
        throw CancellationError()
      }
      self.reportPlanKeyMutationFailure(error, provider: provider)
      throw error
    }
    guard self.planMutationGenerations[provider] == mutation else {
      await self.cleanUpCanceledPlanSave(provider, generation: mutation)
      throw CancellationError()
    }
    self.adoptSavedPlanKey(provider, onFinished: onFinished)
  }

  /// Removes a key that was just saved, rejected, and then abandoned, so a key
  /// that never worked does not stay in Keychain. The provider stays in the
  /// state the rejection left it in; closing the window decides the rest.
  func discardRejectedPlanKey(_ provider: ProviderID) {
    guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
    self.deletePlanKeyValue(provider)
    self.planKeyCache[provider] = .missing
    self.invalidateSubscriptionRead(provider)
    self.states[provider]?.requiresConnection = true
    self.changed()
  }

  func discardRejectedPlanKeyAsync(_ provider: ProviderID) async throws {
    guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
    let mutation = self.beginPlanKeyMutation(provider)
    do { try await self.deletePlanKeyValue(provider) }
    catch {
      guard self.planMutationGenerations[provider] == mutation else { throw CancellationError() }
      self.reportPlanKeyMutationFailure(error, provider: provider)
      throw error
    }
    guard self.planMutationGenerations[provider] == mutation else { throw CancellationError() }
    self.planKeyCache[provider] = .missing
    self.invalidateSubscriptionRead(provider)
    self.states[provider]?.requiresConnection = true
    self.changed()
  }

  /// Deletes the key, stops checks and clears the cached snapshot.
  func removePlanKey(_ provider: ProviderID) {
    guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
    self.deletePlanKeyValue(provider)
    self.planKeyCache[provider] = .missing
    self.subscriptionSchedules[provider] = nil
    self.disconnect(provider)
  }

  func removePlanKeyAsync(_ provider: ProviderID) async throws {
    guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
    let mutation = self.beginPlanKeyMutation(provider)
    do { try await self.deletePlanKeyValue(provider) }
    catch {
      guard self.planMutationGenerations[provider] == mutation else { throw CancellationError() }
      self.reportPlanKeyMutationFailure(error, provider: provider)
      throw error
    }
    guard self.planMutationGenerations[provider] == mutation else { throw CancellationError() }
    self.planKeyCache[provider] = .missing
    self.subscriptionSchedules[provider] = nil
    self.disconnect(provider)
  }

  @discardableResult
  func refreshAPIConsumption(
    _ provider: APIConsumptionProvider,
    trigger: RefreshTrigger = .manual
  ) -> Bool {
    self.startAPIRefresh(provider, trigger: trigger, respectingSchedule: true)
  }

  func refreshEnabledAPIConsumption(trigger: RefreshTrigger = .manual) {
    self.refreshDueAPIConsumption(trigger: trigger, now: self.now())
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
    for (provider, day) in zip(ProviderID.allCases, [7, 12, 19, 24, 27, 3, 15, 21]) {
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
        source: "Codex app-server",
        details: [
          UsageDetail("Account", "preview@example.com"),
          UsageDetail("Credits", "1,250 left"),
          UsageDetail("Lifetime tokens", "5.4B"),
        ]),
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
          label: "Extra usage", usedMinorUnits: 2_845, limitMinorUnits: 10_000),
        details: [
          UsageDetail("Account", "preview@example.com"),
          UsageDetail("Subscribed since", UsageDetailFormat.date(now.addingTimeInterval(-240 * 86_400))),
        ]),
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
    self.states[.copilot] = ProviderViewState(provider: .copilot,
      snapshot: UsageSnapshot(provider: .copilot, planName: "Pro", windows: [
        UsageWindow(id: "premium_interactions", label: "Premium usage", usedPercent: 18,
          resetsAt: now.addingTimeInterval(18 * 86_400))], fetchedAt: now,
        source: "Copilot account quota",
        details: [UsageDetail("Premium requests", "54 of 300 used"), UsageDetail("Chat", "Unlimited")]))
    self.states[.zai] = ProviderViewState(provider: .zai,
      snapshot: UsageSnapshot(provider: .zai, planName: "GLM Coding Pro", windows: [
        UsageWindow(id: "tokens_limit-300", label: "5 hours", usedPercent: 22,
          windowMinutes: 300, resetsAt: now.addingTimeInterval(3.1 * 3600)),
        UsageWindow(id: "tokens_limit-10080", label: "Weekly", usedPercent: 35,
          windowMinutes: 10_080, resetsAt: now.addingTimeInterval(5.2 * 86_400)),
      ], fetchedAt: now.addingTimeInterval(-37),
        source: "Z.ai quota API (unofficial)", detailedUsageUnavailable: true,
        details: [UsageDetail("Tool calls", "224 of 1,000 this month")]))
    self.states[.kimi] = ProviderViewState(provider: .kimi,
      snapshot: UsageSnapshot(provider: .kimi, planName: "Moderato", windows: [
        UsageWindow(id: "limit-300", label: "5 hours", usedPercent: 40,
          windowMinutes: 300, resetsAt: now.addingTimeInterval(2 * 3600)),
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: 18,
          windowMinutes: 10_080, resetsAt: now.addingTimeInterval(4.5 * 86_400)),
      ], fetchedAt: now.addingTimeInterval(-52),
        source: "Kimi Code usage API (unofficial)", detailedUsageUnavailable: true,
        details: [UsageDetail("Weekly requests", "369 of 2,048 used")]))
    self.states[.kimi]?.serviceStatus = ProviderServiceStatus(
      provider: .kimi, health: .operational, detail: "All systems operational",
      pageURL: URL(string: "https://status.moonshot.cn")!)
    self.states[.gemini] = ProviderViewState(provider: .gemini,
      snapshot: UsageSnapshot(provider: .gemini, windows: [
        UsageWindow(id: "gemini-weekly", label: "Weekly", usedPercent: 29,
          windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3.4 * 86_400)),
        UsageWindow(id: "gemini-5h", label: "5 hours", usedPercent: 12,
          windowMinutes: 300, resetsAt: now.addingTimeInterval(2.6 * 3600)),
        UsageWindow(id: "3p-weekly", label: "Claude and GPT weekly", usedPercent: 8,
          windowMinutes: 10_080, resetsAt: now.addingTimeInterval(5.1 * 86_400)),
      ], fetchedAt: now.addingTimeInterval(-44),
        source: "Antigravity CLI usage report", detailedUsageUnavailable: true,
        details: [UsageDetail("Gemini Models", "Gemini Flash, Gemini Pro"),
          UsageDetail("Claude and GPT models", "Claude Opus, Claude Sonnet, GPT-OSS")]))
    self.changed()
  }

  private func registerDefaults() {
    self.defaults.register(defaults: [
      // Insights used local history before 1.3.0. Keep it available after an
      // update unless the person explicitly turned it off. Scans still only
      // run while Insights is visible, or when Refresh is used, so this does
      // not add background work.
      "history.localEnabled": true,
      "provider.openAI.enabled": BinaryLocator.find("codex") != nil,
      "provider.anthropic.enabled": BinaryLocator.find("claude") != nil,
      "provider.grok.enabled": BinaryLocator.find("grok") != nil,
      "provider.cursor.enabled": false,
      "provider.copilot.enabled": false,
      // Key-connected plans stay off until a key is saved.
      "provider.zai.enabled": false,
      "provider.kimi.enabled": false,
      // Gemini runs the Antigravity CLI, which signs in separately, so it is
      // opt-in like Cursor and Copilot even when agy is installed.
      "provider.gemini.enabled": false,
      // Reading Claude Code's Keychain item is another application's OAuth
      // token, so it is opt-in and stays off until asked for.
      "anthropic.keychainReadAllowed": false,
      "cursor.keychainReadAllowed": false,
      // Weekly quotas move slowly, and every sweep spawns a provider CLI that
      // costs far more than Reserve itself. Half-hourly is plenty; the interval
      // remains configurable.
      "refresh.intervalMinutes": 30,
      "refresh.adaptive": false,
      "privacy.hidePersonalInfo": false,
      "hotkey.dashboard": DashboardHotKeyChoice.off.rawValue,
      "insights.historyDays": 30,
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
      "apiConsumption.openAI.enabled": false,
      "apiConsumption.anthropic.enabled": false,
      "apiConsumption.openRouter.enabled": false,
      "apiConsumption.xAI.enabled": false,
      "apiConsumption.typeSafe.enabled": false,
      "apiConsumption.deepSeek.enabled": false,
      "apiConsumption.moonshot.enabled": false,
      "appearance.mode": AppearanceMode.system.rawValue,
      "updates.automatic": true,
      "menuBar.provider": "reserve",
      "menuBar.showsRemaining": true,
      "menuBar.showsReset": true,
    ])
    self.defaults.removeObject(forKey: "apiConsumption.typeface.enabled")
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
    } else if self.isEnabled(provider) {
      // A helper can exit with an error after the account was already
      // connected in the browser, and Grok's own log shows exactly that.
      // The usage check decides, not the exit status.
      if !self.refresh(provider, queueIfBusy: true, onFinished: { [weak self] in
        guard let self else {
          completion?()
          return
        }
        if self.states[provider]?.requiresConnection == true {
          self.markLoginNotCompleted(provider)
        }
        completion?()
      }) { self.changed() }
    } else {
      self.markLoginNotCompleted(provider)
      completion?()
    }
  }

  /// The verified failure state: the helper ended badly and no usable session
  /// was found afterwards.
  private func markLoginNotCompleted(_ provider: ProviderID) {
    let timeoutMessage = self.loginTimeoutMessages.removeValue(forKey: provider)
    self.states[provider]?.requiresConnection = true
    self.states[provider]?.requiresInstallation = false
    self.states[provider]?.requiresUpdate = false
    self.states[provider]?.usageAccessDenied = false
    // A protected sign-in that only needs permission keeps its own explanation
    // and its Allow access action.
    if self.states[provider]?.requiresKeychainAccess != true {
      self.states[provider]?.error = timeoutMessage
        ?? "\(provider.displayName) sign-in was not completed. Try again when you are ready."
    }
    self.changed()
  }

  private func cleanUpLogin(_ provider: ProviderID) {
    if provider == .anthropic {
      self.claudeBrowserPipe?.close()
      self.claudeBrowserPipe = nil
    }
    self.loginTimeoutTasks[provider]?.cancel()
    self.loginTimeoutTasks[provider] = nil
    self.loginHandoffTasks[provider]?.cancel()
    self.loginHandoffTasks[provider] = nil
    self.loginHandoffOverdue.remove(provider)
    self.loginBrowserBuffers[provider] = nil
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
    var buffer = (fromBrowser ? self.loginBrowserBuffers[provider] : self.loginOutputBuffers[provider]) ?? Data()
    buffer.append(data.prefix(max(0, 65_536 - buffer.count)))
    if fromBrowser { self.loginBrowserBuffers[provider] = buffer }
    else { self.loginOutputBuffers[provider] = buffer }
    guard let output = String(data: buffer, encoding: .utf8) else { return }
    if provider == .cursor, output.contains("Failed to store authentication tokens") {
      self.loginStorageFailures.insert(provider)
    }
    // Claude prints a manual-code fallback to stdout. Its BROWSER handoff has
    // the loopback callback that can actually finish sign-in inside this app,
    // so stdout is used only once that handoff has missed its deadline.
    if provider == .anthropic, self.claudeBrowserPipe != nil, !fromBrowser,
      !self.loginHandoffOverdue.contains(provider)
    { return }
    self.openLoginURLIfFound(in: output, for: provider)
  }

  /// Opens the first trusted sign-in URL in the helper's output, once.
  private func openLoginURLIfFound(in output: String, for provider: ProviderID) {
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
        Self.loginConfiguration(for: provider)?.trustedHosts.contains(url.host?.lowercased() ?? "") == true
      else { continue }
      return url
    }
    return nil
  }

  /// Nil for API-key providers and terminal sign-ins: they have no sign-in
  /// command to run.
  private static func loginConfiguration(for provider: ProviderID) -> LoginConfiguration? {
    let descriptor = ProviderDescriptor.forProvider(provider)
    guard !descriptor.usesAPIKey, !descriptor.signsInFromTerminal, let helper = descriptor.helper
    else { return nil }
    return LoginConfiguration(executable: helper.executable,
      arguments: descriptor.loginArguments, displayName: descriptor.loginDisplayName,
      trustedHosts: descriptor.trustedLoginHosts)
  }

  private func loadCacheAndStart() async {
    let cached = await self.cache.load()
    for (provider, snapshot) in cached where self.isEnabled(provider) {
      self.states[provider]?.snapshot = snapshot
      if let accountUsage = snapshot.accountUsage {
        self.states[provider]?.localUsage = accountUsage
      }
    }
    self.changed()
    await self.loadPublishedDailyHistory()
    self.startScheduler()
    self.refreshAll(manual: false)
    self.refreshEnabledAPIConsumption()
  }

  /// `force` waives the scan interval. Whether a surface should scan at all is
  /// the caller's decision, so that the Insights pane and an expanded provider
  /// card can both ask without one gating the other.
  private func beginLocalUsageRefresh(force: Bool) -> Bool {
    guard self.localHistoryEnabled, !self.isScanningLocalUsage else { return false }
    // A failed scan stays eligible even when the previous success is still
    // inside the quiet period. Success freshness is left in place so the
    // dashboard does not pretend the last good totals just disappeared.
    if !force, self.localHistoryScanError == nil, let lastLocalUsageScanAt,
      Date().timeIntervalSince(lastLocalUsageScanAt) < self.localUsageScanInterval
    {
      return false
    }
    self.isScanningLocalUsage = true
    return true
  }

  private func refreshLocalUsage(force: Bool = true) {
    guard self.beginLocalUsageRefresh(force: force) else { return }
    self.changed()
    self.startDetachedLocalUsageScan()
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

  /// When the current sleeper expects to fire. Compared, never extended, when
  /// adaptive policy shortens the next wait.
  private var schedulerFireAt: Date?

  private func startScheduler(now: Date = Date()) {
    self.schedulerTask?.cancel()
    guard self.automaticRefreshEnabled else {
      self.schedulerFireAt = nil
      return
    }
    let delay = self.automaticWakeDelay(now: now)
    let fireAt = now.addingTimeInterval(delay)
    self.schedulerFireAt = fireAt
    self.schedulerTask = Task { [weak self] in
      if delay > 0 {
        try? await Task.sleep(for: .seconds(delay))
      }
      guard !Task.isCancelled else { return }
      await MainActor.run {
        guard let self, !Task.isCancelled else { return }
        self.refreshAllIfWorthwhile()
        self.startScheduler()
      }
    }
  }

  /// Restarts the sleeper only when the new policy delay fires sooner than the
  /// one already waiting. Opening the dashboard never postpones a tick.
  private func bringAdaptiveTickForward(now: Date) {
    let minutes = max(1, self.effectiveRefreshIntervalMinutes(now: now))
    let candidate = now.addingTimeInterval(TimeInterval(minutes * 60))
    if let scheduled = self.schedulerFireAt, candidate >= scheduled { return }
    self.startScheduler(now: now)
  }

  private func refreshInSweep(_ provider: ProviderID) async {
    guard self.isEnabled(provider) else { return }
    // A scheduled sweep must not interrupt an explicit permission check.
    if let running = self.refreshTasks[provider] {
      await running.value
      return
    }
    let task = Task { await self.performRefresh(provider, persist: false, notify: true) }
    self.refreshTasks[provider] = task
    await task.value
  }

  private func performRefreshAll(providers: [ProviderID]) async {
    // Two checks at a time bounds process pressure while one slow provider
    // cannot hold every other row behind it. Service status and local history
    // are not part of this group.
    await withTaskGroup(of: Void.self) { group in
      var iterator = providers.makeIterator()
      for _ in 0..<2 {
        if let provider = iterator.next() {
          group.addTask { await self.refreshInSweep(provider) }
        }
      }
      while await group.next() != nil {
        if let provider = iterator.next() {
          group.addTask { await self.refreshInSweep(provider) }
        }
      }
    }
    await self.persistSnapshots()
    self.isRefreshingAll = false
    self.lastRefreshCompletedAt = self.now()
    self.changed()
  }

  private func startDetachedLocalUsageScan() {
    let generation = self.localScanGeneration
    self.localScanTask = Task(priority: .utility) {
      await self.performLocalUsageScan(generation: generation)
    }
  }

  private func updateLocalUsageWatches() {
    guard let scanner = self.localUsageScanner else { return }
    let enabled: Set<ProviderID> = self.localHistoryEnabled
      ? Set(ProviderID.allCases.filter { self.isEnabled($0) })
      : []
    self.localWatchTask?.cancel()
    self.localWatchTask = Task {
      guard !Task.isCancelled else { return }
      if enabled.isEmpty { await scanner.stopWatching() }
      else { await scanner.updateWatchedProviders(enabled) }
    }
  }

  private func performLocalUsageScan(generation: Int, notify: Bool = true) async {
    defer {
      if self.localScanGeneration == generation {
        self.isScanningLocalUsage = false
        if notify { self.changed() }
      }
    }
    var continuing = false
    while !Task.isCancelled {
      guard self.localHistoryEnabled, self.localScanGeneration == generation else { return }
      if continuing, self.discretionaryRefreshIsSuppressed() { return }
      let now = self.now()
      let enabled = Set(ProviderID.allCases.filter { self.isEnabled($0) })
      let before = await self.localUsageProgress()
      do {
        try Task.checkCancellation()
        let result = try await self.localUsageScan(enabled, now)
        try Task.checkCancellation()
        guard self.localHistoryEnabled, self.localScanGeneration == generation else { return }
        for provider in ProviderID.allCases {
          guard self.isEnabled(provider) else { continue }
          let snapshot = self.states[provider]?.snapshot
          self.states[provider]?.localUsage = Self.usageAfterLocalScan(
            provider: provider,
            snapshot: snapshot,
            scanned: result[provider])
        }
        self.lastLocalUsageScanAt = now
        self.localHistoryScanError = nil
        self.localScanNeedsContinuation = false
        await self.loadPublishedDailyHistory(now: now)
        return
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, self.localHistoryEnabled,
          self.localScanGeneration == generation else { return }
        let after = await self.localUsageProgress()
        guard !Task.isCancelled, self.localHistoryEnabled,
          self.localScanGeneration == generation else { return }
        if case UsageProviderError.timedOut = error,
          after.incomplete, after.checkpoints > before.checkpoints {
          // A bounded pass with a useful checkpoint is normal progress. Keep
          // finalized totals visible and yield before resuming the same work.
          self.localScanNeedsContinuation = true
          continuing = true
          self.localHistoryScanError = nil
          if notify { self.changed() }
          do { try await Task.sleep(for: self.localScanContinuationDelay) }
          catch { return }
          continue
        }
        // An unchanged checkpoint cannot justify an endless retry loop.
        self.localScanNeedsContinuation = false
        self.localHistoryScanError = Self.localHistoryFailureMessage(error)
        return
      }
    }
  }

  /// What the dashboard may say about a failed local scan. Paths, file names
  /// and raw scanner text stay out of the interface.
  static func localHistoryFailureMessage(_ error: Error) -> String {
    guard let providerError = error as? UsageProviderError else {
      return "Local history could not be read. Totals are from the last successful scan."
    }
    switch providerError {
    case .timedOut:
      return "Local history scan timed out. Totals are from the last successful scan."
    default:
      return "Local history could not be read. Totals are from the last successful scan."
    }
  }

  /// Cursor usage comes from its account API, not this Mac's session logs.
  /// A local scan must not erase the account totals that the provider refresh
  /// just fetched and saved.
  static func usageAfterLocalScan(
    provider: ProviderID,
    snapshot: UsageSnapshot?,
    scanned: LocalUsageSummary?
  ) -> LocalUsageSummary? {
    snapshot?.accountUsage ?? scanned
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
    guard self.isEnabled(provider), !Task.isCancelled else {
      self.states[provider]?.isRefreshing = false
      return
    }
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

    guard isCurrent() else { return }
    // Status has its own task. A slow or failed status page must not hold a
    // quota slot or the connection completion below.
    self.refreshServiceStatus(provider)
    if ProviderDescriptor.forProvider(provider).usesAPIKey {
      let availability = await self.resolvePlanKeyAvailability(provider)
      guard isCurrent() else { return }
      self.planKeyCache[provider] = SavedKeyAvailability(availability)
      if availability == .unavailable {
        let probeID = self.planProbeID(provider)
        self.lastKeychainProbeAt[probeID] = self.now()
        self.keychainProbeFailures[probeID, default: 0] += 1
        self.states[provider]?.error = KeychainAccessClassification.temporaryMessage(
          displayName: provider.displayName)
        self.states[provider]?.requiresConnection = false
        return
      }
    }

    guard await self.subscriptionLimiter.acquire() else { return }
    defer { self.subscriptionLimiter.release() }
    guard isCurrent() else { return }

    let includeInsights = self.pendingInsightProviders.remove(provider) != nil || self.insightsVisible
    let fetcher: any UsageProvider =
      switch provider {
      case .openAI: OpenAIProvider(includeAccountActivity: includeInsights)
      case .anthropic:
        AnthropicProvider(
          allowKeychainRead: self.claudeKeychainReadAllowed,
          allowKeychainInteraction: allowKeychainInteraction,
          passiveStatusline: self.claudePassiveUpdatesEnabled)
      case .grok: GrokProvider()
      case .cursor:
        CursorProvider(
          allowKeychainRead: self.cursorKeychainReadAllowed,
          allowKeychainInteraction: allowKeychainInteraction,
          includeAccountUsage: includeInsights)
      case .copilot: CopilotProvider()
      case .zai: ZaiProvider()
      case .kimi: KimiProvider()
      case .gemini: GeminiProvider()
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
      self.states[provider]?.signInCouldNotStart = false
      self.states[provider]?.requiresConnection = false
      self.states[provider]?.requiresKeychainAccess = false
      self.states[provider]?.requiresInstallation = false
      self.states[provider]?.requiresUpdate = false
      self.states[provider]?.usageAccessDenied = false
      if let accountUsage = snapshot.accountUsage {
        self.states[provider]?.localUsage = accountUsage
      } else if self.states[provider]?.localUsage?.origin == .providerAccount {
        self.states[provider]?.localUsage = nil
      }
      providerFetchSucceeded = true
      self.notifications.update(
        previous: previous,
        current: snapshot,
        nextPlanRenewal: self.nextRenewal(for: provider))
      if persist { await self.persistSnapshots() }
      guard isCurrent() else { return }
      self.recordSubscriptionSuccess(provider)
    } catch {
      guard isCurrent() else { return }
      self.recordSubscriptionFailure(provider, error)
      // The cached snapshot is deliberately kept: a failed refresh should leave
      // the last known numbers on screen with an error beside them.
      if var state = self.states[provider] {
        Self.applyFailure(error, to: &state)
        self.states[provider] = state
      }
      // A temporary macOS access failure does not revoke the user's consent.
    }
    if providerFetchSucceeded { self.changed() }
    guard isCurrent() else { return }
    self.reportStaleness(provider)
  }

  /// How a failed check reads on a provider's state. The snapshot is left
  /// alone. Shared with the self-test, which pins the window each error opens.
  static func applyFailure(_ error: Error, to state: inout ProviderViewState) {
    let providerError = error as? UsageProviderError
    state.error = String(error.localizedDescription.prefix(500))
    // A fresh answer replaces the launch failure; the next sign-in tries again.
    state.signInCouldNotStart = false
    state.requiresConnection = providerError?.requiresConnection == true
    if case .executableNotFound = providerError {
      state.requiresInstallation = true
    } else {
      state.requiresInstallation = false
    }
    if case .updateRequired = providerError {
      state.requiresUpdate = true
    } else {
      state.requiresUpdate = false
    }
    if case .accessDenied = providerError {
      state.usageAccessDenied = true
    } else {
      state.usageAccessDenied = false
    }
    if case .keychainConsentRequired(let consentProvider) = providerError {
      state.requiresKeychainAccess = consentProvider == state.provider
    } else {
      state.requiresKeychainAccess = false
    }
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

  /// Places synthetic local totals without scanning this Mac. Used only by the
  /// refresh self-test, which cannot write `states` from outside the store.
  func seedLocalUsageForSelfTest(_ usage: LocalUsageSummary?) {
    self.states[.openAI]?.localUsage = usage
  }

  /// Replaces one snapshot for a presentation check, then the caller restores it.
  func replaceSnapshotForSelfTest(_ provider: ProviderID, snapshot: UsageSnapshot?) -> UsageSnapshot? {
    let previous = self.states[provider]?.snapshot
    self.states[provider]?.snapshot = snapshot
    return previous
  }

  /// Fires once when a provider's numbers go stale, and clears when they
  /// recover, so the alert tracks the condition rather than the refresh loop.
  private func reportStaleness(_ provider: ProviderID, now: Date = Date()) {
    guard self.states[provider]?.snapshot?.observationTimeKnown != false else { return }
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

  private func performAPIConsumptionRefresh(
    _ provider: APIConsumptionProvider,
    generation: Int
  ) async {
    defer {
      if self.apiGenerations[provider] == generation {
        self.apiTasks[provider] = nil
        self.apiConsumptionRefreshing.remove(provider)
        self.changed()
      }
    }
    guard self.apiGenerations[provider] == generation, self.isAPIConsumptionEnabled(provider)
    else { return }
    let availability = await self.resolveAPIKeyAvailability(provider)
    guard self.apiGenerations[provider] == generation else { return }
    self.apiKeyCache[provider] = SavedKeyAvailability(availability)
    let probeID = self.apiProbeID(provider)
    switch availability {
    case .missing:
      self.keychainProbeFailures[probeID] = 0
      self.apiConsumptionErrors[provider] = KeychainAccessClassification.missingMessage(
        displayName: provider.displayName, keyKind: provider.keyKind)
      return
    case .unavailable:
      self.lastKeychainProbeAt[probeID] = self.now()
      self.keychainProbeFailures[probeID, default: 0] += 1
      self.apiConsumptionErrors[provider] = KeychainAccessClassification.temporaryMessage(
        displayName: provider.displayName)
      return
    case .present:
      self.keychainProbeFailures[probeID] = 0
    }
    let key: String
    do {
      key = try await self.loadAPIKey(provider)
    } catch {
      guard self.apiGenerations[provider] == generation else { return }
      if self.isTemporaryKeychainFailure(error) {
        self.apiKeyCache[provider] = .unavailable
        self.lastKeychainProbeAt[probeID] = self.now()
        self.keychainProbeFailures[probeID, default: 0] += 1
        self.apiConsumptionErrors[provider] = KeychainAccessClassification.temporaryMessage(
          displayName: provider.displayName)
      } else {
        self.apiKeyCache[provider] = .missing
        self.apiConsumptionErrors[provider] = String(error.localizedDescription.prefix(240))
      }
      return
    }
    guard self.apiGenerations[provider] == generation else { return }
    guard await self.apiLimiter.acquire() else { return }
    defer { self.apiLimiter.release() }
    guard self.apiGenerations[provider] == generation, self.isAPIConsumptionEnabled(provider)
    else { return }
    do {
      let snapshot = try await self.fetchAPIConsumption(provider, apiKey: key)
      guard self.apiGenerations[provider] == generation, self.isAPIConsumptionEnabled(provider)
      else { return }
      self.apiConsumption[provider] = snapshot
      self.apiConsumptionErrors[provider] = nil
      self.recordAPISuccess(provider)
    } catch {
      guard self.apiGenerations[provider] == generation, self.isAPIConsumptionEnabled(provider)
      else { return }
      self.recordAPIFailure(provider, error)
      self.apiConsumptionErrors[provider] = String(error.localizedDescription.prefix(240))
    }
  }

  private func discretionaryRefreshIsSuppressed(now: Date = Date()) -> Bool {
    if self.offlineOverride == true { return true }
    if let lowPowerOverride { return lowPowerOverride }
    if self.honorsHostRefreshEnvironment, ProcessInfo.processInfo.isLowPowerModeEnabled {
      return true
    }
    _ = now
    return false
  }

  private func refreshInterval(now: Date) -> TimeInterval {
    TimeInterval(max(1, self.effectiveRefreshIntervalMinutes(now: now)) * 60)
  }

  private func admission(
    for provider: ProviderID, trigger: RefreshTrigger, now: Date
  ) -> RefreshAdmission {
    RefreshSchedulePolicy.admit(
      state: self.subscriptionSchedules[provider] ?? ProviderRefreshSchedule(),
      trigger: trigger, now: now, interval: self.refreshInterval(now: now),
      discretionarySuppressed: self.discretionaryRefreshIsSuppressed(now: now))
  }

  private func apiAdmission(
    _ provider: APIConsumptionProvider, trigger: RefreshTrigger, now: Date
  ) -> RefreshAdmission {
    RefreshSchedulePolicy.admit(
      state: self.apiSchedules[provider] ?? ProviderRefreshSchedule(),
      trigger: trigger, now: now, interval: self.refreshInterval(now: now),
      discretionarySuppressed: self.discretionaryRefreshIsSuppressed(now: now))
  }

  private func dueSubscriptionProviders(trigger: RefreshTrigger, now: Date) -> [ProviderID] {
    ProviderID.allCases.filter { provider in
      guard self.isEnabled(provider), self.states[provider]?.isRefreshing != true,
        self.refreshTasks[provider] == nil
      else { return false }
      if ProviderDescriptor.forProvider(provider).usesAPIKey {
        switch self.planKeyAvailability(for: provider) {
        case .missing, .unavailable: return false
        case .unknown, .present: break
        }
      }
      return self.admission(for: provider, trigger: trigger, now: now).allowed
    }
  }

  private func dueAPIProviders(
    trigger: RefreshTrigger, now: Date
  ) -> [APIConsumptionProvider] {
    APIConsumptionProvider.allCases.filter { provider in
      guard self.isAPIConsumptionEnabled(provider), self.apiTasks[provider] == nil else { return false }
      switch self.apiConsumptionKeyAvailability(provider) {
      case .missing, .unavailable: return false
      case .unknown, .present: break
      }
      return self.apiAdmission(provider, trigger: trigger, now: now).allowed
    }
  }

  private func refreshDueAPIConsumption(trigger: RefreshTrigger, now: Date) {
    for provider in self.dueAPIProviders(trigger: trigger, now: now) {
      self.startAPIRefresh(provider, trigger: trigger, respectingSchedule: true)
    }
  }

  private func hasDueKeychainProbe(trigger: RefreshTrigger, now: Date) -> Bool {
    for provider in APIConsumptionProvider.allCases {
      if self.apiKeyCache[provider] == .unavailable,
        self.keychainProbeIsDue(id: self.apiProbeID(provider), trigger: trigger, now: now)
      {
        return true
      }
    }
    for provider in ProviderID.allCases where ProviderDescriptor.forProvider(provider).usesAPIKey {
      if self.planKeyCache[provider] == .unavailable,
        self.keychainProbeIsDue(id: self.planProbeID(provider), trigger: trigger, now: now)
      {
        return true
      }
    }
    return false
  }

  private func keychainProbeIsDue(id: String, trigger: RefreshTrigger, now: Date) -> Bool {
    switch trigger {
    case .manual, .connectionRecovery:
      return true
    case .automatic, .activation, .keychainRecovery:
      let last = self.lastKeychainProbeAt[id] ?? .distantPast
      let elapsed = now.timeIntervalSince(last)
      if elapsed < RefreshSchedulePolicy.keychainProbeSpacing { return false }
      if trigger == .automatic {
        let failures = self.keychainProbeFailures[id] ?? 0
        if failures > 0 {
          let delay = RefreshSchedulePolicy.backoff(
            failures: failures, base: RefreshSchedulePolicy.keychainProbeSpacing,
            cap: RefreshSchedulePolicy.keychainProbeCap)
          if elapsed < delay { return false }
        }
      }
      return true
    }
  }

  private func nextKeychainProbeAt(id: String, now: Date) -> Date? {
    guard self.lastKeychainProbeAt[id] != nil || (self.keychainProbeFailures[id] ?? 0) > 0 else {
      return now
    }
    let failures = self.keychainProbeFailures[id] ?? 0
    let delay = failures == 0
      ? RefreshSchedulePolicy.keychainProbeSpacing
      : RefreshSchedulePolicy.backoff(
        failures: max(1, failures), base: RefreshSchedulePolicy.keychainProbeSpacing,
        cap: RefreshSchedulePolicy.keychainProbeCap)
    let last = self.lastKeychainProbeAt[id] ?? now
    return last.addingTimeInterval(delay)
  }

  private func automaticWakeDelay(now: Date) -> TimeInterval {
    let interval = self.refreshInterval(now: now)
    if self.discretionaryRefreshIsSuppressed(now: now) {
      return min(6 * 60 * 60, max(RefreshSchedulePolicy.minimumAutomaticDelay, interval))
    }
    var earliest = now.addingTimeInterval(interval)
    for provider in ProviderID.allCases where self.isEnabled(provider) {
      if ProviderDescriptor.forProvider(provider).usesAPIKey {
        let availability = self.planKeyAvailability(for: provider)
        if availability == .missing || availability == .unavailable { continue }
      }
      let next = RefreshSchedulePolicy.nextEligibleAt(
        state: self.subscriptionSchedules[provider] ?? ProviderRefreshSchedule(),
        now: now, interval: interval)
      if next < earliest { earliest = next }
    }
    for provider in APIConsumptionProvider.allCases where self.isAPIConsumptionEnabled(provider) {
      let availability = self.apiConsumptionKeyAvailability(provider)
      if availability == .missing || availability == .unavailable { continue }
      let next = RefreshSchedulePolicy.nextEligibleAt(
        state: self.apiSchedules[provider] ?? ProviderRefreshSchedule(),
        now: now, interval: interval)
      if next < earliest { earliest = next }
    }
    for provider in APIConsumptionProvider.allCases where self.apiKeyCache[provider] == .unavailable {
      if let next = self.nextKeychainProbeAt(id: self.apiProbeID(provider), now: now), next < earliest {
        earliest = next
      }
    }
    for provider in ProviderID.allCases where ProviderDescriptor.forProvider(provider).usesAPIKey
      && self.planKeyCache[provider] == .unavailable {
      if let next = self.nextKeychainProbeAt(id: self.planProbeID(provider), now: now), next < earliest {
        earliest = next
      }
    }
    return min(6 * 60 * 60, max(RefreshSchedulePolicy.minimumAutomaticDelay, earliest.timeIntervalSince(now)))
  }

  #if RESERVE_DEV_AUTOMATION
  func automaticWakeDelayForTesting(now: Date) -> TimeInterval {
    self.automaticWakeDelay(now: now)
  }
  #endif

  private func retryLockedKeychainReads(trigger: RefreshTrigger, now: Date) {
    for provider in APIConsumptionProvider.allCases {
      guard self.apiKeyCache[provider] == .unavailable,
        self.keychainProbeIsDue(id: self.apiProbeID(provider), trigger: trigger, now: now)
      else { continue }
      self.startAPIKeyRecoveryProbe(provider, trigger: trigger, now: now)
    }
    for provider in ProviderID.allCases where ProviderDescriptor.forProvider(provider).usesAPIKey {
      guard self.planKeyCache[provider] == .unavailable,
        self.keychainProbeIsDue(id: self.planProbeID(provider), trigger: trigger, now: now)
      else { continue }
      self.startPlanKeyRecoveryProbe(provider, trigger: trigger, now: now)
    }
  }

  private func startAPIKeyRecoveryProbe(
    _ provider: APIConsumptionProvider, trigger: RefreshTrigger, now: Date
  ) {
    guard self.apiProbeTasks[provider] == nil else { return }
    let mutation = self.apiMutationGenerations[provider] ?? 0
    let probeID = self.apiProbeID(provider)
    self.lastKeychainProbeAt[probeID] = now
    self.apiProbeTasks[provider] = Task { [weak self] in
      guard let self else { return }
      let availability = await self.resolveAPIKeyAvailability(provider)
      guard !Task.isCancelled, (self.apiMutationGenerations[provider] ?? 0) == mutation else {
        return
      }
      self.apiKeyCache[provider] = SavedKeyAvailability(availability)
      switch availability {
      case .unavailable:
        self.keychainProbeFailures[probeID, default: 0] += 1
        self.apiConsumptionErrors[provider] = KeychainAccessClassification.temporaryMessage(
          displayName: provider.displayName)
      case .missing:
        self.keychainProbeFailures[probeID] = 0
        self.apiConsumptionErrors[provider] = self.isAPIConsumptionEnabled(provider)
          ? KeychainAccessClassification.missingMessage(
            displayName: provider.displayName, keyKind: provider.keyKind)
          : nil
      case .present:
        self.keychainProbeFailures[probeID] = 0
        if self.apiConsumptionErrors[provider]
          == KeychainAccessClassification.temporaryMessage(displayName: provider.displayName)
        {
          self.apiConsumptionErrors[provider] = nil
        }
      }
      self.apiProbeTasks[provider] = nil
      self.changed()
      guard availability == .present, self.isAPIConsumptionEnabled(provider) else { return }
      let fetchTrigger: RefreshTrigger = trigger == .manual ? .manual : .keychainRecovery
      self.startAPIRefresh(provider, trigger: fetchTrigger, respectingSchedule: true)
    }
  }

  private func startPlanKeyRecoveryProbe(
    _ provider: ProviderID, trigger: RefreshTrigger, now: Date
  ) {
    guard self.planProbeTasks[provider] == nil else { return }
    let mutation = self.planMutationGenerations[provider] ?? 0
    let probeID = self.planProbeID(provider)
    self.lastKeychainProbeAt[probeID] = now
    self.planProbeTasks[provider] = Task { [weak self] in
      guard let self else { return }
      let availability = await self.resolvePlanKeyAvailability(provider)
      guard !Task.isCancelled, (self.planMutationGenerations[provider] ?? 0) == mutation else {
        return
      }
      self.planKeyCache[provider] = SavedKeyAvailability(availability)
      switch availability {
      case .unavailable:
        self.keychainProbeFailures[probeID, default: 0] += 1
        self.states[provider]?.error = KeychainAccessClassification.temporaryMessage(
          displayName: provider.displayName)
        self.states[provider]?.requiresConnection = false
      case .missing:
        self.keychainProbeFailures[probeID] = 0
        if self.isEnabled(provider) {
          self.states[provider]?.error = KeychainAccessClassification.missingMessage(
            displayName: provider.displayName, keyKind: "API key")
          self.states[provider]?.requiresConnection = true
        }
      case .present:
        self.keychainProbeFailures[probeID] = 0
        if self.states[provider]?.error
          == KeychainAccessClassification.temporaryMessage(displayName: provider.displayName)
        {
          self.states[provider]?.error = nil
        }
      }
      self.planProbeTasks[provider] = nil
      self.changed()
      guard availability == .present, self.isEnabled(provider) else { return }
      let fetchTrigger: RefreshTrigger = trigger == .manual ? .manual : .keychainRecovery
      self.refresh(provider, trigger: fetchTrigger)
    }
  }

  private func recordSubscriptionSuccess(_ provider: ProviderID) {
    var state = self.subscriptionSchedules[provider] ?? ProviderRefreshSchedule()
    let now = self.now()
    RefreshSchedulePolicy.recordSuccess(&state, now: now, interval: self.refreshInterval(now: now))
    self.subscriptionSchedules[provider] = state
  }

  private func recordSubscriptionFailure(_ provider: ProviderID, _ error: Error) {
    var state = self.subscriptionSchedules[provider] ?? ProviderRefreshSchedule()
    RefreshSchedulePolicy.recordFailure(
      &state, now: self.now(), failure: RefreshSchedulePolicy.failureClass(for: error))
    self.subscriptionSchedules[provider] = state
  }

  private func recordAPISuccess(_ provider: APIConsumptionProvider) {
    var state = self.apiSchedules[provider] ?? ProviderRefreshSchedule()
    let now = self.now()
    RefreshSchedulePolicy.recordSuccess(&state, now: now, interval: self.refreshInterval(now: now))
    self.apiSchedules[provider] = state
  }

  private func recordAPIFailure(_ provider: APIConsumptionProvider, _ error: Error) {
    var state = self.apiSchedules[provider] ?? ProviderRefreshSchedule()
    RefreshSchedulePolicy.recordFailure(
      &state, now: self.now(), failure: RefreshSchedulePolicy.failureClass(for: error))
    self.apiSchedules[provider] = state
  }

  private func apiProbeID(_ provider: APIConsumptionProvider) -> String {
    "api.\(provider.rawValue)"
  }

  private func planProbeID(_ provider: ProviderID) -> String {
    "plan.\(provider.rawValue)"
  }

  private func invalidateAPIWork(_ provider: APIConsumptionProvider) {
    self.apiGenerations[provider] = (self.apiGenerations[provider] ?? 0) + 1
    self.apiTasks[provider]?.cancel()
    self.apiTasks[provider] = nil
    self.apiProbeTasks.removeValue(forKey: provider)?.cancel()
    self.apiConsumptionRefreshing.remove(provider)
  }

  private func invalidateSubscriptionRead(_ provider: ProviderID) {
    self.refreshTokens[provider] = (self.refreshTokens[provider] ?? 0) + 1
    self.cancellationGenerations[provider] = (self.cancellationGenerations[provider] ?? 0) + 1
    self.refreshTasks[provider]?.cancel()
    self.refreshTasks[provider] = nil
    self.planProbeTasks.removeValue(forKey: provider)?.cancel()
    self.statusGenerations[provider] = (self.statusGenerations[provider] ?? 0) + 1
    self.statusTasks[provider]?.cancel()
    self.statusTasks[provider] = nil
    self.states[provider]?.isRefreshing = false
    self.states[provider]?.isConnecting = false
  }

  @discardableResult
  private func startAPIRefresh(
    _ provider: APIConsumptionProvider,
    trigger: RefreshTrigger,
    respectingSchedule: Bool
  ) -> Bool {
    guard self.isAPIConsumptionEnabled(provider) else { return false }
    if self.apiConsumptionKeyAvailability(provider) == .missing { return false }
    if respectingSchedule,
      !self.apiAdmission(provider, trigger: trigger, now: self.now()).allowed
    {
      return false
    }
    if self.apiTasks[provider] != nil { return false }
    let generation = (self.apiGenerations[provider] ?? 0) + 1
    self.apiGenerations[provider] = generation
    self.apiConsumptionRefreshing.insert(provider)
    self.apiTasks[provider] = Task {
      await self.performAPIConsumptionRefresh(provider, generation: generation)
    }
    self.changed()
    return true
  }

  private func adoptSavedAPIKey(_ provider: APIConsumptionProvider) {
    self.invalidateAPIWork(provider)
    self.apiKeyCache[provider] = .present
    self.apiSchedules[provider] = nil
    self.keychainProbeFailures[self.apiProbeID(provider)] = 0
    self.defaults.set(true, forKey: "apiConsumption.\(provider.rawValue).enabled")
    self.apiConsumptionErrors[provider] = nil
    self.changed()
    self.startAPIRefresh(provider, trigger: .manual, respectingSchedule: false)
  }

  private func finishAPIKeyRemoval(_ provider: APIConsumptionProvider) {
    self.apiKeyCache[provider] = .missing
    self.apiSchedules[provider] = nil
    self.keychainProbeFailures[self.apiProbeID(provider)] = 0
    self.defaults.set(false, forKey: "apiConsumption.\(provider.rawValue).enabled")
    self.apiConsumption[provider] = nil
    self.apiConsumptionErrors[provider] = nil
    self.changed()
  }

  private func adoptSavedPlanKey(_ provider: ProviderID, onFinished: (() -> Void)?) {
    self.invalidateSubscriptionRead(provider)
    self.planKeyCache[provider] = .present
    self.subscriptionSchedules[provider] = nil
    self.keychainProbeFailures[self.planProbeID(provider)] = 0
    self.states[provider]?.error = nil
    self.states[provider]?.requiresConnection = false
    self.setEnabled(provider, enabled: true, refreshImmediately: false)
    self.refresh(provider, queueIfBusy: false, trigger: .connectionRecovery) { onFinished?() }
  }

  private func deletePlanKeyValue(_ provider: ProviderID) {
    if let injected = self.injectedPlanKeys {
      injected.delete(provider)
    } else {
      self.states[provider]?.error = "Removing this key requires the async Keychain path."
    }
  }

  private func deletePlanKeyValue(_ provider: ProviderID) async throws {
    if let injected = self.injectedPlanKeys {
      if let deleteAsync = injected.deleteAsync { try await deleteAsync(provider) }
      else { injected.delete(provider) }
    } else if self.usesProductionKeychain {
      try await PlanKeyKeychain.delete(for: provider)
    } else {
      throw UsageProviderError.unavailable("Plan key storage is not configured.")
    }
  }

  private func beginAPIKeyMutation(_ provider: APIConsumptionProvider) -> Int {
    let generation = (self.apiMutationGenerations[provider] ?? 0) + 1
    self.apiMutationGenerations[provider] = generation
    self.invalidateAPIWork(provider)
    return generation
  }

  private func beginPlanKeyMutation(_ provider: ProviderID) -> Int {
    let generation = (self.planMutationGenerations[provider] ?? 0) + 1
    self.planMutationGenerations[provider] = generation
    self.invalidateSubscriptionRead(provider)
    return generation
  }

  private func cleanUpCanceledPlanSave(_ provider: ProviderID, generation: Int) async {
    guard self.planMutationGenerations[provider] == generation + 1,
      self.planMutationsNeedingCleanup[provider]?.remove(generation) != nil
    else { return }
    self.planSaveCleanupEligible[provider]?.remove(generation)
    do {
      try await self.deletePlanKeyValue(provider)
      self.planKeyCache[provider] = .missing
    } catch {
      // Do not claim removal when macOS could not perform it. The next probe
      // will reconcile the actual Keychain state without prompting.
      self.planKeyCache[provider] = .unavailable
      self.states[provider]?.error = String(error.localizedDescription.prefix(240))
    }
  }

  private func finishPlanSaveMutation(_ provider: ProviderID, generation: Int) {
    self.planSaveCleanupEligible[provider]?.remove(generation)
    self.planMutationsNeedingCleanup[provider]?.remove(generation)
    if self.planSaveCleanupEligible[provider]?.isEmpty == true {
      self.planSaveCleanupEligible[provider] = nil
    }
    if self.planMutationsNeedingCleanup[provider]?.isEmpty == true {
      self.planMutationsNeedingCleanup[provider] = nil
    }
  }

  private func reportAPIKeyMutationFailure(
    _ error: Error, provider: APIConsumptionProvider
  ) {
    let availability = self.injectedAPIKeys.map { SavedKeyAvailability($0.availability(provider)) }
      ?? .unavailable
    self.apiKeyCache[provider] = availability
    self.apiConsumptionErrors[provider] = String(error.localizedDescription.prefix(240))
    self.changed()
  }

  private func reportPlanKeyMutationFailure(_ error: Error, provider: ProviderID) {
    let availability: SavedKeyAvailability
    if let injected = self.injectedPlanKeys {
      if let probe = injected.availability { availability = SavedKeyAvailability(probe(provider)) }
      else { availability = injected.hasKey(provider) ? .present : .missing }
    } else {
      availability = .unavailable
    }
    self.planKeyCache[provider] = availability
    self.states[provider]?.error = String(error.localizedDescription.prefix(240))
    self.changed()
  }

  private func resolveAPIKeyAvailability(
    _ provider: APIConsumptionProvider
  ) async -> KeychainItemAvailability {
    if let injected = self.injectedAPIKeys { return injected.availability(provider) }
    guard self.usesProductionKeychain else { return .missing }
    return await APIConsumptionKeychain.availability(for: provider)
  }

  private func loadAPIKey(_ provider: APIConsumptionProvider) async throws -> String {
    if let injected = self.injectedAPIKeys { return try injected.load(provider) }
    return try await APIConsumptionKeychain.load(for: provider)
  }

  private func fetchAPIConsumption(
    _ provider: APIConsumptionProvider, apiKey: String
  ) async throws -> APIConsumptionSnapshot {
    if let apiConsumptionFetch {
      return try await apiConsumptionFetch(provider, apiKey)
    }
    guard self.usesProductionKeychain else {
      throw UsageProviderError.unavailable("API consumption fixture is not configured.")
    }
    return try await APIConsumptionClient().fetch(provider, apiKey: apiKey)
  }

  private func resolvePlanKeyAvailability(_ provider: ProviderID) async -> KeychainItemAvailability {
    if let injected = self.injectedPlanKeys {
      if let availabilityAsync = injected.availabilityAsync {
        return await availabilityAsync(provider)
      }
      if let availability = injected.availability { return availability(provider) }
      return injected.hasKey(provider) ? .present : .missing
    }
    guard self.usesProductionKeychain else { return .missing }
    return await PlanKeyKeychain.availability(for: provider)
  }

  private func isTemporaryKeychainFailure(_ error: Error) -> Bool {
    guard let providerError = error as? UsageProviderError else { return false }
    if case .unavailable = providerError { return true }
    return false
  }

  private func scheduleProductionAPIProbe(_ provider: APIConsumptionProvider) {
    guard self.apiProbeTasks[provider] == nil else { return }
    let mutation = self.apiMutationGenerations[provider] ?? 0
    self.apiProbeTasks[provider] = Task { [weak self] in
      guard let self else { return }
      let availability = await APIConsumptionKeychain.availability(for: provider)
      guard !Task.isCancelled, (self.apiMutationGenerations[provider] ?? 0) == mutation,
        self.apiKeyCache[provider] == nil
      else {
        if (self.apiMutationGenerations[provider] ?? 0) == mutation {
          self.apiProbeTasks[provider] = nil
        }
        return
      }
      self.apiKeyCache[provider] = SavedKeyAvailability(availability)
      self.apiProbeTasks[provider] = nil
      self.changed()
    }
  }

  private func scheduleProductionPlanProbe(_ provider: ProviderID) {
    guard self.planProbeTasks[provider] == nil else { return }
    let mutation = self.planMutationGenerations[provider] ?? 0
    self.planProbeTasks[provider] = Task { [weak self] in
      guard let self else { return }
      let availability = await PlanKeyKeychain.availability(for: provider)
      guard !Task.isCancelled, (self.planMutationGenerations[provider] ?? 0) == mutation,
        self.planKeyCache[provider] == nil
      else {
        if (self.planMutationGenerations[provider] ?? 0) == mutation {
          self.planProbeTasks[provider] = nil
        }
        return
      }
      self.planKeyCache[provider] = SavedKeyAvailability(availability)
      self.planProbeTasks[provider] = nil
      self.changed()
    }
  }

  private func refreshServiceStatus(_ provider: ProviderID) {
    guard self.serviceStatusFetch != nil || self.fetchOverride == nil else { return }
    let generation = (self.statusGenerations[provider] ?? 0) + 1
    self.statusGenerations[provider] = generation
    self.statusTasks[provider]?.cancel()
    let previous = self.states[provider]?.serviceStatus?.health
    self.statusTasks[provider] = Task { [weak self] in
      guard let self else { return }
      defer {
        if self.statusGenerations[provider] == generation {
          self.statusTasks[provider] = nil
        }
      }
      let status: ProviderServiceStatus?
      if let serviceStatusFetch = self.serviceStatusFetch {
        status = await serviceStatusFetch(provider)
      } else {
        status = await self.serviceStatusClient.fetch(provider)
      }
      guard self.statusGenerations[provider] == generation, self.isEnabled(provider) else { return }
      guard !Task.isCancelled else { return }
      self.states[provider]?.serviceStatus = status
      self.reportServiceHealth(provider, previous: previous)
      self.changed()
    }
  }

  func subscriptionRefreshSchedule(for provider: ProviderID) -> ProviderRefreshSchedule {
    self.subscriptionSchedules[provider] ?? ProviderRefreshSchedule()
  }

  func apiRefreshSchedule(for provider: APIConsumptionProvider) -> ProviderRefreshSchedule {
    self.apiSchedules[provider] ?? ProviderRefreshSchedule()
  }

  private func persistSnapshots() async {
    let snapshots = Dictionary(
      uniqueKeysWithValues: self.states.compactMap { provider, state in
        state.snapshot.map { (provider, $0) }
      })
    try? await self.cache.save(snapshots)
  }
}

final class OperationLimiter: @unchecked Sendable {
  private struct Waiter {
    let id: UUID
    let continuation: CheckedContinuation<Bool, Never>
  }

  private let limit: Int
  private let lock = NSLock()
  private var inFlight = 0
  private var waiters: [Waiter] = []

  init(limit: Int) {
    self.limit = max(1, limit)
  }

  func acquire() async -> Bool {
    if Task.isCancelled { return false }
    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        self.lock.lock()
        if Task.isCancelled {
          self.lock.unlock()
          continuation.resume(returning: false)
        } else if self.inFlight < self.limit {
          self.inFlight += 1
          self.lock.unlock()
          continuation.resume(returning: true)
        } else {
          self.waiters.append(Waiter(id: id, continuation: continuation))
          self.lock.unlock()
        }
      }
    } onCancel: {
      self.cancelWaiter(id)
    }
  }

  func release() {
    self.lock.lock()
    if self.waiters.isEmpty {
      self.inFlight = max(0, self.inFlight - 1)
      self.lock.unlock()
      return
    }
    let next = self.waiters.removeFirst().continuation
    self.lock.unlock()
    next.resume(returning: true)
  }

  private func cancelWaiter(_ id: UUID) {
    self.lock.lock()
    guard let index = self.waiters.firstIndex(where: { $0.id == id }) else {
      self.lock.unlock()
      return
    }
    let continuation = self.waiters.remove(at: index).continuation
    self.lock.unlock()
    continuation.resume(returning: false)
  }

  #if RESERVE_DEV_AUTOMATION
  var waiterCountForTesting: Int {
    self.lock.withLock { self.waiters.count }
  }
  #endif
}

private struct LoginConfiguration {
  let executable: String
  let arguments: [String]
  let displayName: String
  let trustedHosts: Set<String>
}
