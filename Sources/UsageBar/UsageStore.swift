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
  private(set) var lastRefreshCompletedAt: Date?
  var onChange: (() -> Void)?

  private let cache = SnapshotCache()
  private let defaults = UserDefaults.standard
  private var schedulerTask: Task<Void, Never>?
  private var startupTask: Task<Void, Never>?

  init() {
    self.states = Dictionary(
      uniqueKeysWithValues: ProviderID.allCases.map {
        ($0, ProviderViewState(provider: $0))
      })
    self.registerDefaults()
    self.startupTask = Task { [weak self] in
      await self?.loadCacheAndStart()
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
    let values = self.states.values.compactMap { $0.snapshot?.highestUsedPercent }
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
    Task { await self.performRefreshAll() }
  }

  func refresh(_ provider: ProviderID) {
    guard self.states[provider]?.isRefreshing != true else { return }
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
    self.isRefreshingAll = true
    self.changed()
    defer {
      self.isRefreshingAll = false
      self.lastRefreshCompletedAt = Date()
      self.changed()
    }
    for provider in ProviderID.allCases where self.isEnabled(provider) {
      await self.performRefresh(provider)
    }
  }

  private func performRefresh(_ provider: ProviderID) async {
    self.states[provider]?.isRefreshing = true
    self.changed()
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
      self.states[provider]?.error = error.localizedDescription
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
