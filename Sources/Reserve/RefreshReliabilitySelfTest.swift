#if RESERVE_DEV_AUTOMATION
import AppKit
import Foundation
import ReserveCore

@MainActor
enum RefreshReliabilitySelfTest {
  static func run() async -> [String] {
    var failures: [String] = []
    func expect(_ condition: Bool, _ message: String) {
      if !condition { failures.append(message) }
    }

    await self.checkLockedKeyRecovery(expect: expect)
    await self.checkStaleAPIResponseAndSaveCancellation(expect: expect)
    await self.checkDeleteFailure(expect: expect)
    await self.checkPlanSaveCloseRace(expect: expect)
    await self.checkCanceledPlanProbeCanRestart(expect: expect)
    await self.checkPerProviderSchedulingAndRetryAfter(expect: expect)
    await self.checkOptionalWorkIsIndependent(expect: expect)
    await self.checkCanceledLimiterWaiter(expect: expect)
    return failures
  }

  private static func checkLockedKeyRecovery(expect: (Bool, String) -> Void) async {
    let fixture = Fixture("locked-key")
    let clock = LockedValue(Date(timeIntervalSince1970: 1_800_000_000))
    let availability = LockedValue(KeychainItemAvailability.unavailable)
    fixture.defaults.set(true, forKey: "apiConsumption.deepSeek.enabled")
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      apiKeys: APIConsumptionKeyAccess(
        availability: { _ in availability.value }, load: { _ in "fixture-key" },
        save: { _, _ in }, delete: { _ in }),
      apiConsumptionFetch: { provider, _ in self.apiSnapshot(provider, source: "recovered") },
      now: { clock.value })

    expect(store.refreshAPIConsumption(.deepSeek), "locked key fixture did not start")
    _ = await self.eventually { !store.apiConsumptionRefreshing.contains(.deepSeek) }
    expect(store.apiConsumptionKeyAvailability(.deepSeek) == .unavailable,
      "locked Keychain item was reported as missing")
    expect(store.apiConsumptionErrors[.deepSeek]?.contains("temporarily unavailable") == true,
      "locked Keychain item did not keep a recoverable error")

    availability.value = .present
    clock.value = clock.value.addingTimeInterval(20)
    store.refreshDueProvidersAfterActivation(now: clock.value)
    _ = await self.eventually { store.apiConsumption[.deepSeek]?.source == "recovered" }
    expect(store.apiConsumptionKeyAvailability(.deepSeek) == .present,
      "Keychain availability did not recover after unlock")
    expect(store.apiConsumptionErrors[.deepSeek] == nil,
      "successful recovery left the temporary Keychain error visible")

    let disabledFixture = Fixture("disabled-key-recovery")
    let disabledAvailability = LockedValue(KeychainItemAvailability.unavailable)
    let disabledFetches = LockedValue(0)
    disabledFixture.defaults.set(true, forKey: "apiConsumption.deepSeek.enabled")
    let disabled = UsageStore(
      defaults: disabledFixture.defaults, startAutomatically: false, cache: disabledFixture.cache,
      apiKeys: APIConsumptionKeyAccess(
        availability: { _ in disabledAvailability.value }, load: { _ in "fixture-key" },
        save: { _, _ in }, delete: { _ in }),
      apiConsumptionFetch: { provider, _ in
        disabledFetches.value += 1
        return self.apiSnapshot(provider, source: "should-not-fetch")
      },
      now: { clock.value })
    expect(disabled.refreshAPIConsumption(.deepSeek), "disabled recovery fixture did not start")
    _ = await self.eventually { !disabled.apiConsumptionRefreshing.contains(.deepSeek) }
    disabled.setAPIConsumptionEnabled(.deepSeek, enabled: false)
    disabledAvailability.value = .present
    clock.value = clock.value.addingTimeInterval(20)
    disabled.refreshAfterResumeIfNeeded(now: clock.value)
    _ = await self.eventually {
      disabled.apiConsumptionKeyAvailability(.deepSeek) == .present
    }
    expect(disabledFetches.value == 0,
      "recovering a disabled Keychain row made a provider network request")
    expect(!disabled.isAPIConsumptionEnabled(.deepSeek),
      "recovering a disabled Keychain row enabled API measurement")
  }

  private static func checkStaleAPIResponseAndSaveCancellation(
    expect: (Bool, String) -> Void
  ) async {
    let fixture = Fixture("api-generation")
    fixture.defaults.set(true, forKey: "apiConsumption.deepSeek.enabled")
    let key = LockedValue("old-key")
    let fetch = StaleAPIFetchProbe()
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      apiKeys: APIConsumptionKeyAccess(
        availability: { _ in .present }, load: { _ in key.value },
        save: { value, _ in key.value = value }, delete: { _ in key.value = "" }),
      apiConsumptionFetch: { provider, apiKey in
        await fetch.fetch(provider: provider, key: apiKey)
      })

    expect(store.refreshAPIConsumption(.deepSeek), "first API generation did not start")
    await fetch.firstStarted.wait()
    do { try await store.saveAPIConsumptionKey("new-key", for: .deepSeek) }
    catch { expect(false, "replacement API key save failed: \(error.localizedDescription)") }
    _ = await self.eventually { store.apiConsumption[.deepSeek]?.source == "new-key" }
    await fetch.releaseFirst.signal()
    _ = await self.eventually { !store.apiConsumptionRefreshing.contains(.deepSeek) }
    expect(store.apiConsumption[.deepSeek]?.source == "new-key",
      "an uncancellable old API response replaced the new key's reading")

    let saveStarted = AsyncSignal()
    let releaseSave = AsyncSignal()
    let delayedFixture = Fixture("api-save-cancel")
    let delayed = UsageStore(
      defaults: delayedFixture.defaults, startAutomatically: false, cache: delayedFixture.cache,
      apiKeys: APIConsumptionKeyAccess(
        availability: { _ in .present }, load: { _ in "fixture-key" },
        save: { _, _ in }, delete: { _ in },
        saveAsync: { _, _ in
          await saveStarted.signal()
          await releaseSave.wait()
        }))
    let saving = Task { @MainActor in
      do {
        try await delayed.saveAPIConsumptionKey("delayed-key", for: .deepSeek)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    await saveStarted.wait()
    delayed.setAPIConsumptionEnabled(.deepSeek, enabled: false)
    await releaseSave.signal()
    let saveWasCancelled = await saving.value
    expect(saveWasCancelled, "a save superseded by disable did not cancel")
    expect(!delayed.isAPIConsumptionEnabled(.deepSeek),
      "a late key save re-enabled API measurement after disable")
  }

  private static func checkDeleteFailure(expect: (Bool, String) -> Void) async {
    let fixture = Fixture("delete-failure")
    fixture.defaults.set(true, forKey: "apiConsumption.deepSeek.enabled")
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      apiKeys: APIConsumptionKeyAccess(
        availability: { _ in .present }, load: { _ in "fixture-key" },
        save: { _, _ in }, delete: { _ in },
        deleteAsync: { _ in
          throw UsageProviderError.unavailable("fixture Keychain unavailable")
        }))
    var failed = false
    do { try await store.removeAPIConsumptionKeyAsync(.deepSeek) }
    catch { failed = true }
    expect(failed, "Keychain deletion failure was swallowed")
    expect(store.isAPIConsumptionEnabled(.deepSeek),
      "failed deletion incorrectly disabled API measurement")
    expect(store.apiConsumptionKeyAvailability(.deepSeek) == .present,
      "failed deletion incorrectly claimed the key was removed")
  }

  private static func checkPlanSaveCloseRace(expect: (Bool, String) -> Void) async {
    let fixture = Fixture("plan-save-cancel")
    let key = LockedValue<String?>(nil)
    let saveStarted = AsyncSignal()
    let releaseSave = AsyncSignal()
    let keys = PlanKeyStorage(
      hasKey: { _ in key.value != nil }, save: { value, _ in key.value = value },
      delete: { _ in key.value = nil }, availability: { _ in key.value == nil ? .missing : .present },
      saveAsync: { value, _ in
        await saveStarted.signal()
        await releaseSave.wait()
        key.value = value
      },
      deleteAsync: { _ in key.value = nil })
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      fetchOverride: { provider, _ in self.usageSnapshot(provider) }, planKeys: keys)
    let saving = Task { @MainActor in
      do {
        try await store.savePlanKey("0123456789abcdef", for: .zai)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    await saveStarted.wait()
    store.cancelConnection(.zai)
    await releaseSave.signal()
    let saveWasCancelled = await saving.value
    expect(saveWasCancelled, "closing setup did not cancel an awaiting plan-key save")
    expect(key.value == nil, "a canceled unconfirmed plan key stayed in storage")
    expect(!store.isEnabled(.zai), "a canceled plan-key save enabled the provider")

    let replacementFixture = Fixture("plan-replacement-cancel")
    let existingKey = LockedValue<String?>("existing-valid-key")
    let replacementStarted = AsyncSignal()
    let replacementRelease = AsyncSignal()
    let replacementDeletes = LockedValue(0)
    let replacementKeys = PlanKeyStorage(
      hasKey: { _ in existingKey.value != nil }, save: { value, _ in existingKey.value = value },
      delete: { _ in replacementDeletes.value += 1; existingKey.value = nil },
      availability: { _ in existingKey.value == nil ? .missing : .present },
      saveAsync: { value, _ in
        await replacementStarted.signal()
        await replacementRelease.wait()
        existingKey.value = value
      },
      deleteAsync: { _ in replacementDeletes.value += 1; existingKey.value = nil })
    let replacementStore = UsageStore(
      defaults: replacementFixture.defaults, startAutomatically: false,
      cache: replacementFixture.cache,
      fetchOverride: { provider, _ in self.usageSnapshot(provider) }, planKeys: replacementKeys)
    let replacing = Task { @MainActor in
      do {
        try await replacementStore.savePlanKey("replacement-key-123", for: .zai)
        return false
      } catch is CancellationError {
        return true
      } catch {
        return false
      }
    }
    await replacementStarted.wait()
    replacementStore.cancelConnection(.zai)
    await replacementRelease.signal()
    expect(await replacing.value, "canceling a replacement plan-key save did not cancel its flow")
    expect(existingKey.value != nil && replacementDeletes.value == 0,
      "canceling a replacement plan-key save deleted the previously valid item")
  }

  private static func checkCanceledPlanProbeCanRestart(expect: (Bool, String) -> Void) async {
    let fixture = Fixture("plan-probe-cancel")
    for provider in ProviderID.allCases {
      fixture.defaults.set(false, forKey: "provider.\(provider.rawValue).enabled")
    }
    fixture.defaults.set(true, forKey: "provider.zai.enabled")
    fixture.defaults.set(false, forKey: "history.localEnabled")
    let probe = PlanAvailabilityProbe()
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      fetchOverride: { provider, _ in self.usageSnapshot(provider) },
      planKeys: PlanKeyStorage(
        hasKey: { _ in false }, save: { _, _ in }, delete: { _ in },
        availability: { _ in .unavailable },
        availabilityAsync: { _ in await probe.availability() }))

    expect(store.refresh(.zai), "initial plan-key availability check did not start")
    _ = await self.eventually { store.states[.zai]?.isRefreshing == false }
    expect(store.planKeyAvailability(for: .zai) == .unavailable,
      "initial plan-key availability was not cached as unavailable")

    store.refreshAll(manual: true)
    await probe.blockedProbeStarted.wait()
    store.cancelConnection(.zai)
    await probe.releaseBlockedProbe.signal()
    store.refreshAll(manual: true)
    _ = await self.eventually { store.planKeyAvailability(for: .zai) == .present }
    expect(store.planKeyAvailability(for: .zai) == .present,
      "canceling a plan-key probe permanently occupied its recovery slot")
  }

  private static func checkPerProviderSchedulingAndRetryAfter(
    expect: (Bool, String) -> Void
  ) async {
    let fixture = Fixture("provider-schedule")
    fixture.defaults.set(true, forKey: "provider.openAI.enabled")
    fixture.defaults.set(true, forKey: "provider.anthropic.enabled")
    fixture.defaults.set(false, forKey: "history.localEnabled")
    let clock = LockedValue(Date(timeIntervalSince1970: 1_800_000_000))
    let calls = ProviderCallCounts()
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      fetchOverride: { provider, _ in
        await calls.record(provider)
        if provider == .openAI { throw UsageProviderError.unavailable("offline fixture") }
        return self.usageSnapshot(provider)
      },
      now: { clock.value })
    store.refreshAll(manual: true)
    _ = await self.eventually { !store.isRefreshingAll }
    clock.value = clock.value.addingTimeInterval(31)
    store.refreshDueProvidersAfterActivation(now: clock.value)
    _ = await self.eventually { await calls.count(.openAI) == 2 }
    expect(await calls.count(.anthropic) == 1,
      "one failed provider caused a fresh healthy provider to refresh")

    let retryFixture = Fixture("retry-after")
    retryFixture.defaults.set(true, forKey: "provider.openAI.enabled")
    let retryCalls = ProviderCallCounts()
    let deadline = clock.value.addingTimeInterval(600)
    let retryStore = UsageStore(
      defaults: retryFixture.defaults, startAutomatically: false, cache: retryFixture.cache,
      fetchOverride: { provider, _ in
        await retryCalls.record(provider)
        throw UsageProviderError.rateLimited(retryAt: deadline)
      },
      now: { clock.value })
    expect(retryStore.refresh(.openAI), "rate-limit fixture did not start")
    _ = await self.eventually { retryStore.states[.openAI]?.isRefreshing == false }
    expect(!retryStore.refresh(.openAI), "manual refresh bypassed active Retry-After")
    expect(await retryCalls.count(.openAI) == 1,
      "repeated manual refresh started another rate-limited request")

    let missingFixture = Fixture("missing-key-wake")
    for provider in ProviderID.allCases {
      missingFixture.defaults.set(false, forKey: "provider.\(provider.rawValue).enabled")
    }
    for provider in APIConsumptionProvider.allCases {
      missingFixture.defaults.set(false, forKey: "apiConsumption.\(provider.rawValue).enabled")
    }
    missingFixture.defaults.set(true, forKey: "apiConsumption.deepSeek.enabled")
    missingFixture.defaults.set(true, forKey: "provider.zai.enabled")
    let missingStore = UsageStore(
      defaults: missingFixture.defaults, startAutomatically: false, cache: missingFixture.cache,
      fetchOverride: { provider, _ in self.usageSnapshot(provider) },
      planKeys: PlanKeyStorage(
        hasKey: { _ in false }, save: { _, _ in }, delete: { _ in },
        availability: { _ in .missing }),
      apiKeys: APIConsumptionKeyAccess(
        availability: { _ in .missing }, load: { _ in "" }, save: { _, _ in },
        delete: { _ in }),
      now: { clock.value })
    expect(missingStore.automaticWakeDelayForTesting(now: clock.value) >= 600,
      "missing keys forced the scheduler into a 15-second wake loop")
  }

  private static func checkOptionalWorkIsIndependent(
    expect: (Bool, String) -> Void
  ) async {
    let fixture = Fixture("optional-work")
    fixture.defaults.set(true, forKey: "provider.openAI.enabled")
    fixture.defaults.set(true, forKey: "history.localEnabled")
    let statusRelease = AsyncSignal()
    let historyStarted = AsyncSignal()
    let historyRelease = AsyncSignal()
    let store = UsageStore(
      defaults: fixture.defaults, startAutomatically: false, cache: fixture.cache,
      fetchOverride: { provider, _ in self.usageSnapshot(provider) },
      localUsageScan: { _, _ in
        await historyStarted.signal()
        await historyRelease.wait()
        return [:]
      },
      serviceStatusFetch: { _ in
        await statusRelease.wait()
        return nil
      })
    store.refreshAll(manual: true)
    await historyStarted.wait()
    _ = await self.eventually { !store.isRefreshingAll }
    expect(store.states[.openAI]?.snapshot != nil,
      "slow service status held the quota refresh open")
    expect(store.isScanningLocalUsage,
      "local history did not remain independent while its scan was running")
    let dashboard = DashboardViewController(
      store: store,
      actions: DashboardActions(
        refreshAll: {}, connectProvider: { _ in }, selectMenuBarProvider: { _ in },
        openSettings: {}, openInsights: {}, dismiss: {}, toggleProviderDetail: { _ in },
        quit: {}, apiConsumptionReadings: { [] }))
    dashboard.loadViewIfNeeded()
    dashboard.view.layoutSubtreeIfNeeded()
    let refresh = LifecycleSelfTest.descendants(of: dashboard.view)
      .compactMap { $0 as? ReserveIconButton }
      .first { $0.identifier?.rawValue == "refresh-all" }
    expect(refresh != nil, "independent-work fixture did not render the refresh control")
    expect(refresh?.isSpinning == false,
      "local history kept the completed quota refresh control spinning")
    await statusRelease.signal()
    await historyRelease.signal()
    _ = await self.eventually { !store.isScanningLocalUsage }
  }

  private static func checkCanceledLimiterWaiter(expect: (Bool, String) -> Void) async {
    let limiter = OperationLimiter(limit: 1)
    expect(await limiter.acquire(), "limiter did not grant its first slot")
    let waiting = Task { await limiter.acquire() }
    _ = await self.eventually { limiter.waiterCountForTesting == 1 }
    waiting.cancel()
    let acquired = await waiting.value
    expect(!acquired, "a canceled limiter waiter was later admitted")
    expect(limiter.waiterCountForTesting == 0,
      "a canceled limiter waiter stayed retained behind a hung holder")
    limiter.release()
  }

  private static func eventually(
    _ condition: @escaping @MainActor () async -> Bool
  ) async -> Bool {
    for _ in 0..<20_000 {
      if await condition() { return true }
      await Task.yield()
    }
    return false
  }

  nonisolated private static func apiSnapshot(
    _ provider: APIConsumptionProvider, source: String
  ) -> APIConsumptionSnapshot {
    APIConsumptionSnapshot(
      provider: provider, windows: [], note: APIConsumptionNote(headline: source), source: source)
  }

  nonisolated private static func usageSnapshot(_ provider: ProviderID) -> UsageSnapshot {
    UsageSnapshot(
      provider: provider, planName: "Fixture", windows: [
        UsageWindow(id: "weekly", label: "Weekly", usedPercent: 20),
      ], source: "reliability fixture")
  }
}

private final class Fixture {
  let defaults: UserDefaults
  let cache: SnapshotCache
  private let suite: String
  private let directory: URL

  init(_ name: String) {
    self.suite = "Reserve.Reliability.\(name).\(UUID().uuidString)"
    self.defaults = UserDefaults(suiteName: self.suite)!
    self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "reserve-reliability-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    self.cache = SnapshotCache(fileURL: self.directory.appendingPathComponent("snapshots.json"))
  }

  deinit {
    self.defaults.removePersistentDomain(forName: self.suite)
    try? FileManager.default.removeItem(at: self.directory)
  }
}

private final class LockedValue<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var stored: Value
  init(_ value: Value) { self.stored = value }
  var value: Value {
    get { self.lock.withLock { self.stored } }
    set { self.lock.withLock { self.stored = newValue } }
  }
}

private actor AsyncSignal {
  private var signaled = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  func wait() async {
    if self.signaled { return }
    await withCheckedContinuation { self.waiters.append($0) }
  }

  func signal() {
    guard !self.signaled else { return }
    self.signaled = true
    let continuations = self.waiters
    self.waiters.removeAll()
    for continuation in continuations { continuation.resume() }
  }
}

private actor StaleAPIFetchProbe {
  let firstStarted = AsyncSignal()
  let releaseFirst = AsyncSignal()
  private var calls = 0

  func fetch(provider: APIConsumptionProvider, key: String) async -> APIConsumptionSnapshot {
    self.calls += 1
    if self.calls == 1 {
      await self.firstStarted.signal()
      await self.releaseFirst.wait()
    }
    return APIConsumptionSnapshot(
      provider: provider, windows: [], note: APIConsumptionNote(headline: key), source: key)
  }
}

private actor PlanAvailabilityProbe {
  let blockedProbeStarted = AsyncSignal()
  let releaseBlockedProbe = AsyncSignal()
  private var calls = 0

  func availability() async -> KeychainItemAvailability {
    self.calls += 1
    if self.calls == 1 { return .unavailable }
    if self.calls == 2 {
      await self.blockedProbeStarted.signal()
      await self.releaseBlockedProbe.wait()
    }
    return .present
  }
}

private actor ProviderCallCounts {
  private var calls: [ProviderID: Int] = [:]
  func record(_ provider: ProviderID) { self.calls[provider, default: 0] += 1 }
  func count(_ provider: ProviderID) -> Int { self.calls[provider, default: 0] }
}
#endif
