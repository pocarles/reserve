import Foundation
import UsageBarCore

struct ProviderViewState: Identifiable {
  var id: ProviderID { self.provider }
  let provider: ProviderID
  var snapshot: UsageSnapshot?
  var error: String?
  var isRefreshing = false

  var isStale: Bool {
    guard let snapshot else { return false }
    return self.error != nil || Date().timeIntervalSince(snapshot.fetchedAt) > 30 * 60
  }
}

@MainActor
final class UsageStore {
  private(set) var states: [ProviderID: ProviderViewState]
  private(set) var isRefreshingAll = false
  var onChange: (() -> Void)?

  private let cache = SnapshotCache()
  private let defaults: UserDefaults
  private var schedulerTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?

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
  }

  var orderedStates: [ProviderViewState] {
    ProviderID.allCases.compactMap { self.states[$0] }
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
    self.changed()
    Task { await self.performRefreshAll() }
  }

  func refresh(_ provider: ProviderID) {
    guard self.beginRefresh(provider) else { return }
    Task { await self.performRefresh(provider) }
  }

  func setEnabled(_ provider: ProviderID, enabled: Bool) {
    self.defaults.set(enabled, forKey: "provider.\(provider.rawValue).enabled")
    self.changed()
    if enabled { self.refresh(provider) }
  }

  func isEnabled(_ provider: ProviderID) -> Bool {
    self.defaults.bool(forKey: "provider.\(provider.rawValue).enabled")
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
        source: "Codex app-server"))
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
          label: "Extra usage", usedMinorUnits: 2_845, limitMinorUnits: 10_000)))
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
          label: "Included credits", usedMinorUnits: 12_345, limitMinorUnits: 99_900)))
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

  private func loadCacheAndStart() async {
    let cached = await self.cache.load()
    for (provider, snapshot) in cached {
      self.states[provider]?.snapshot = snapshot
    }
    self.changed()
    self.startScheduler()
    self.refreshAll(manual: false)
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
