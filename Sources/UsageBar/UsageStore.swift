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

  var isStale: Bool {
    guard let snapshot else { return false }
    return self.error != nil || Date().timeIntervalSince(snapshot.fetchedAt) > 30 * 60
  }
}

@MainActor
final class UsageStore {
  private(set) var states: [ProviderID: ProviderViewState]
  private(set) var isRefreshingAll = false
  private(set) var isScanningLocalUsage = false
  var onChange: (() -> Void)?

  private let cache = SnapshotCache()
  private let localUsageScanner = LocalUsageScanner()
  private let defaults: UserDefaults
  private var schedulerTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?
  private var claudeLoginProcess: Process?
  private var claudeLoginTimeoutTask: Task<Void, Never>?
  private var claudeLoginInput: Pipe?
  private var claudeLoginOutput: Pipe?
  private var claudeLoginOutputBuffer = Data()
  private var openedClaudeLoginURL = false

  init(defaults: UserDefaults = .standard, startAutomatically: Bool = true) {
    self.defaults = defaults
    self.states = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map {
        ($0, ProviderViewState(provider: $0))
      })
    self.registerDefaults()
    if startAutomatically {
      self.startupTask = Task { [weak self] in
        await self?.loadCacheAndStart()
      }
    }
  }

  deinit {
    self.schedulerTask?.cancel()
    self.startupTask?.cancel()
    self.claudeLoginTimeoutTask?.cancel()
    if self.claudeLoginProcess?.isRunning == true { self.claudeLoginProcess?.terminate() }
  }

  var orderedStates: [ProviderViewState] {
    ProviderID.allCases.compactMap { provider in
      guard var state = self.states[provider] else { return nil }
      state.subscriptionCostUSD = self.monthlySubscriptionCost(for: provider)
      return state
    }
  }

  var statusSymbol: String {
    let values = self.orderedStates
      .filter { self.isEnabled($0.provider) }
      .compactMap { $0.snapshot?.highestUsedPercent }
    guard let highest = values.max() else { return "gauge.with.dots.needle.0percent" }
    switch highest {
    case 90...: return "gauge.with.dots.needle.100percent"
    case 65...: return "gauge.with.dots.needle.67percent"
    case 30...: return "gauge.with.dots.needle.50percent"
    default: return "gauge.with.dots.needle.33percent"
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
    get { max(10, self.defaults.integer(forKey: "refresh.intervalMinutes")) }
    set {
      self.defaults.set(max(10, newValue), forKey: "refresh.intervalMinutes")
      self.startScheduler()
    }
  }

  func refreshAll(manual: Bool = true) {
    guard !self.isRefreshingAll else { return }
    if !manual, ProcessInfo.processInfo.isLowPowerModeEnabled { return }
    self.isRefreshingAll = true
    self.refreshLocalUsage()
    self.changed()
    Task { await self.performRefreshAll() }
  }

  func refresh(_ provider: ProviderID) {
    guard self.beginRefresh(provider) else { return }
    Task { await self.performRefresh(provider) }
  }

  func connectAnthropic() {
    guard self.claudeLoginProcess?.isRunning != true else { return }
    guard let executable = BinaryLocator.find("claude") else {
      self.states[.anthropic]?.error = "Claude Code is not installed."
      self.changed()
      return
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["auth", "login", "--claudeai"]
    process.environment = ProcessInfo.processInfo.environment
    process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = output
    process.terminationHandler = { [weak self] completed in
      Task { @MainActor [weak self] in
        self?.finishAnthropicLogin(status: completed.terminationStatus)
      }
    }

    do {
      try process.run()
      self.claudeLoginProcess = process
      self.claudeLoginInput = input
      self.claudeLoginOutput = output
      self.claudeLoginOutputBuffer = Data()
      self.openedClaudeLoginURL = false
      output.fileHandleForReading.readabilityHandler = { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        Task { @MainActor [weak self] in self?.consumeClaudeLoginOutput(data) }
      }
      self.states[.anthropic]?.isConnecting = true
      self.states[.anthropic]?.error = nil
      self.changed()
      self.claudeLoginTimeoutTask?.cancel()
      self.claudeLoginTimeoutTask = Task { [weak self, weak process] in
        try? await Task.sleep(for: .seconds(300))
        guard !Task.isCancelled, process?.isRunning == true else { return }
        process?.terminate()
        await MainActor.run {
          self?.states[.anthropic]?.error = "Claude sign-in timed out. Click Connect to try again."
          self?.states[.anthropic]?.isConnecting = false
          self?.changed()
        }
      }
      Task { [weak input] in
        try? await Task.sleep(for: .milliseconds(300))
        try? input?.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
      }
    } catch {
      self.states[.anthropic]?.error =
        "Could not start Claude sign-in: \(error.localizedDescription)"
      self.states[.anthropic]?.isConnecting = false
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

  func installPreviewSnapshots(now: Date = Date()) {
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
            id: "weekly", label: "Weekly", usedPercent: 61,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(4.2 * 86400)),
        ],
        fetchedAt: now.addingTimeInterval(-48),
        source: "Codex app-server"),
      localUsage: LocalUsageSummary(
        provider: .openAI, periodDays: 30, inputTokens: 18_620_000_000,
        cachedInputTokens: 15_900_000_000, cacheWriteInputTokens: 48_000_000,
        outputTokens: 92_000_000, apiEquivalentCostUSD: 9_995.11))
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
            id: "weekly", label: "Weekly", usedPercent: 52,
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
        provider: .anthropic, periodDays: 30, inputTokens: 3_750_000_000,
        cachedInputTokens: 3_100_000_000, cacheWriteInputTokens: 330_000_000,
        outputTokens: 62_200_000, apiEquivalentCostUSD: 4_173.96))
    self.states[.grok] = ProviderViewState(
      provider: .grok,
      snapshot: UsageSnapshot(
        provider: .grok,
        planName: "SuperGrok Heavy",
        windows: [
          UsageWindow(
            id: "usage-pool", label: "Weekly", usedPercent: 43,
            windowMinutes: 10080, resetsAt: now.addingTimeInterval(2.8 * 86400))
        ],
        fetchedAt: now.addingTimeInterval(-126),
        source: "Grok Build billing API",
        includedSpend: IncludedSpend(
          label: "Included credits", usedMinorUnits: 12_345, limitMinorUnits: 99_900)),
      localUsage: LocalUsageSummary(
        provider: .grok, periodDays: 30, inputTokens: 820_000_000,
        outputTokens: 0, apiEquivalentCostUSD: 1_640, isCostEstimate: true))
    self.changed()
  }

  private func registerDefaults() {
    self.defaults.register(defaults: [
      "provider.openAI.enabled": true,
      "provider.anthropic.enabled": true,
      "provider.grok.enabled": true,
      "anthropic.keychainReadAllowed": false,
      "refresh.intervalMinutes": 10,
    ])
  }

  private func changed() {
    self.onChange?()
  }

  private func finishAnthropicLogin(status: Int32) {
    self.claudeLoginTimeoutTask?.cancel()
    self.claudeLoginTimeoutTask = nil
    self.claudeLoginProcess = nil
    self.claudeLoginOutput?.fileHandleForReading.readabilityHandler = nil
    try? self.claudeLoginInput?.fileHandleForWriting.close()
    try? self.claudeLoginOutput?.fileHandleForReading.close()
    self.claudeLoginInput = nil
    self.claudeLoginOutput = nil
    self.claudeLoginOutputBuffer = Data()
    self.openedClaudeLoginURL = false
    self.states[.anthropic]?.isConnecting = false
    if status == 0 {
      self.claudeKeychainReadAllowed = true
      self.states[.anthropic]?.error = nil
      self.refresh(.anthropic)
    } else if self.states[.anthropic]?.error == nil {
      self.states[.anthropic]?.error = "Claude sign-in was not completed. Click Connect to retry."
      self.changed()
    }
  }

  private func consumeClaudeLoginOutput(_ data: Data) {
    guard !self.openedClaudeLoginURL else { return }
    let remainingCapacity = max(0, 65_536 - self.claudeLoginOutputBuffer.count)
    self.claudeLoginOutputBuffer.append(data.prefix(remainingCapacity))
    guard let output = String(data: self.claudeLoginOutputBuffer, encoding: .utf8),
      let url = Self.claudeAuthorizationURL(in: output)
    else { return }
    self.openedClaudeLoginURL = true
    NSWorkspace.shared.open(url)
  }

  static func claudeAuthorizationURL(in output: String) -> URL? {
    let pattern = #"https://[^\s\u001B<>\"]+"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(output.startIndex..., in: output)
    for match in regex.matches(in: output, range: range) {
      guard let swiftRange = Range(match.range, in: output) else { continue }
      let text = String(output[swiftRange]).trimmingCharacters(
        in: CharacterSet(charactersIn: "'(),.;"))
      guard let url = URL(string: text),
        ["claude.com", "claude.ai", "platform.claude.com"].contains(url.host?.lowercased()),
        url.path.contains("oauth")
      else { continue }
      return url
    }
    return nil
  }

  private func loadCacheAndStart() async {
    let cached = await self.cache.load()
    for (provider, snapshot) in cached {
      self.states[provider]?.snapshot = snapshot
    }
    self.changed()
    self.startScheduler()
    self.refreshLocalUsage()
    self.refreshAll(manual: false)
  }

  private func refreshLocalUsage() {
    guard !self.isScanningLocalUsage else { return }
    self.isScanningLocalUsage = true
    self.changed()
    Task { [weak self] in
      guard let self else { return }
      let result = try? await self.localUsageScanner.scan(periodDays: 30)
      await MainActor.run {
        if let result {
          for provider in ProviderID.allCases {
            self.states[provider]?.localUsage = result[provider]
          }
        }
        self.isScanningLocalUsage = false
        self.changed()
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
        await MainActor.run { self?.refreshAll(manual: false) }
      }
    }
  }

  private func performRefreshAll() async {
    defer {
      self.isRefreshingAll = false
      self.changed()
    }
    for provider in ProviderID.allCases where self.isEnabled(provider) {
      guard self.beginRefresh(provider) else { continue }
      await self.performRefresh(provider)
    }
  }

  private func beginRefresh(_ provider: ProviderID) -> Bool {
    guard self.states[provider]?.isRefreshing != true else { return false }
    self.states[provider]?.isRefreshing = true
    self.changed()
    return true
  }

  private func performRefresh(_ provider: ProviderID) async {
    defer {
      self.states[provider]?.isRefreshing = false
      self.changed()
    }

    let fetcher: any UsageProvider =
      switch provider {
      case .openAI: OpenAIProvider()
      case .anthropic: AnthropicProvider(allowKeychainRead: self.claudeKeychainReadAllowed)
      case .grok: GrokProvider()
      }
    do {
      let snapshot = try await fetcher.fetch()
      self.states[provider]?.snapshot = snapshot
      self.states[provider]?.error = nil
      await self.persistSnapshots()
    } catch {
      self.states[provider]?.error = String(error.localizedDescription.prefix(500))
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
