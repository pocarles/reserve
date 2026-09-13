import Foundation
import Testing
@testable import ReserveCore

struct AllowanceTrustTests {
  @Test func earlyBurstDoesNotProduceAForecastWarning() {
    let now = Date()
    let early = UsageWindow(id: "weekly", label: "Weekly", usedPercent: 30,
      windowMinutes: 10_080, resetsAt: now.addingTimeInterval(7 * 86_400 * 0.95))
    #expect(UsagePaceProjection.calculate(for: early, now: now) == nil)
    #expect(UsagePaceState.calculate(for: early, fetchedAt: now, now: now) == .unknown)
    let established = UsageWindow(id: "weekly", label: "Weekly", usedPercent: 30,
      windowMinutes: 10_080, resetsAt: now.addingTimeInterval(7 * 86_400 * 0.8))
    #expect(UsagePaceProjection.calculate(for: established, now: now)?.position == .deficit)
  }

  @Test func expiredWindowCannotLookCurrent() {
    let now = Date()
    let window = UsageWindow(id: "daily", label: "Daily", usedPercent: 100,
      windowMinutes: 1_440, resetsAt: now.addingTimeInterval(-1))
    #expect(UsagePaceState.calculate(for: window, fetchedAt: now, now: now) == .stale)
  }

  @Test func cachedObservationCannotTriggerUsageAlerts() {
    let now = Date()
    let reset = now.addingTimeInterval(3 * 86_400)
    let previous = UsageSnapshot(provider: .cursor, windows: [
      UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10, windowMinutes: 10_080, resetsAt: reset)],
      source: "fixture")
    let current = UsageSnapshot(provider: .cursor, windows: [
      UsageWindow(id: "weekly", label: "Weekly", usedPercent: 100, windowMinutes: 10_080, resetsAt: reset)],
      source: "fixture", observationTimeKnown: false)
    #expect(SmartAlertDetector.deficitAlerts(previous: previous, current: current, now: now).isEmpty)
    #expect(UsageNotificationEventDetector.thresholdCrossings(previous: previous, current: current).isEmpty)
  }

  @Test func metadataSurvivesCacheAndPlanFallback() throws {
    let now = Date()
    let snapshot = UsageSnapshot(provider: .openAI, windows: [], fetchedAt: now,
      source: "fixture", observationTimeKnown: false, checkedAt: now.addingTimeInterval(10),
      availableResetCount: 2)
    let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
      .withFallbackPlanName("Pro")
    #expect(restored.planName == "Pro")
    #expect(!restored.observationTimeKnown)
    #expect(restored.checkedAt == snapshot.checkedAt)
    #expect(restored.availableResetCount == 2)
  }

  @Test func snapshotWithoutAnObservationFlagCountsAsObserved() throws {
    let data = Data(#"{"provider":"openAI","windows":[],"fetchedAt":800000000,"source":"fixture"}"#.utf8)
    let snapshot = try JSONDecoder().decode(UsageSnapshot.self, from: data)
    #expect(snapshot.observationTimeKnown)
    #expect(snapshot.checkedAt == snapshot.fetchedAt)
  }

  /// A cache written by an older Reserve can still name a provider this build
  /// dropped. That entry is skipped; the supported ones must still load.
  @Test func cachedSnapshotsSurviveARetiredProviderEntry() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-cache-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("snapshots.json")
    try Data("""
      [
        {"provider":"windsurf","fetchedAt":"2026-09-01T00:00:00Z","source":"retired","windows":[]},
        {"provider":"openAI","fetchedAt":"2026-09-02T00:00:00Z","source":"kept","windows":[]}
      ]
      """.utf8).write(to: fileURL)
    let loaded = await SnapshotCache(fileURL: fileURL).load()
    #expect(Array(loaded.keys) == [.openAI])
    #expect(loaded[.openAI]?.source == "kept")
  }

  @Test func aMalformedCachedEntryStillFailsTheWholeFile() throws {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let data = Data(#"[{"provider":"openAI","source":"no windows or time"}]"#.utf8)
    #expect(throws: (any Error).self) {
      try UsageSnapshot.decodePersistedList(data, using: decoder)
    }
  }
}
