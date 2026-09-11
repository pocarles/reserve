import Foundation
import SQLite3
import Testing
@testable import ReserveCore

@Suite
struct WindsurfProviderTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private static func cache(_ overrides: [String: Any] = [:]) throws -> Data {
    var value: [String: Any] = [
      "planName": "Pro", "dailyRemainingPercent": 75.5, "weeklyRemainingPercent": 40,
      "dailyResetAtUnix": 1_800_043_200, "weeklyResetAtUnix": "1800259200",
      "startTimestamp": 1_799_136_000_000, "endTimestamp": "1801728000000",
      "overageBalanceMicros": "12500000", "hideDailyQuota": false,
    ]
    value.merge(overrides) { _, replacement in replacement }
    return try JSONSerialization.data(withJSONObject: value)
  }

  @Test func parsesQuotaBalanceRenewalAndConservativeAge() throws {
    let snapshot = try WindsurfProvider.decodeCache(Self.cache(), now: Self.now)
    #expect(snapshot.provider == .windsurf)
    #expect(snapshot.planName == "Pro")
    #expect(snapshot.windows.map(\.usedPercent) == [24.5, 60])
    #expect(snapshot.windows.map(\.windowMinutes) == [1_440, 10_080])
    #expect(snapshot.billingRenewsAt == Date(timeIntervalSince1970: 1_801_728_000))
    #expect(snapshot.creditBalanceMinorUnits == 1_250)
    #expect(snapshot.source == "Devin Desktop account cache")
    #expect(snapshot.fetchedAt == Self.now.addingTimeInterval(-43_200))
    #expect(UsagePaceState.calculate(for: snapshot.windows.first, fetchedAt: snapshot.fetchedAt, now: Self.now) == .stale)
    #expect(snapshot.accountUsage == nil)
    let data = try JSONEncoder().encode(snapshot)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: data) == snapshot)
    #expect(snapshot.withFallbackPlanName("Other").creditBalanceMinorUnits == 1_250)
  }

  @Test func excludesExpiredQuotaAndHonorsHiddenQuota() throws {
    let expiredDaily = try WindsurfProvider.decodeCache(
      Self.cache(["dailyResetAtUnix": 1_799_999_999]), now: Self.now)
    #expect(expiredDaily.windows.map(\.id) == ["weekly"])
    #expect(expiredDaily.fetchedAt == Self.now.addingTimeInterval(-345_600))
    let hidden = try WindsurfProvider.decodeCache(Self.cache(["hideDailyQuota": true]), now: Self.now)
    #expect(hidden.windows.map(\.id) == ["weekly"])
  }

  @Test func rejectsExpiredPeriodsAndInvalidNumbers() throws {
    for overrides: [String: Any] in [
      ["dailyResetAtUnix": 1_799_999_999, "weeklyResetAtUnix": 1_799_999_999],
      ["endTimestamp": 1_799_999_999_000], ["startTimestamp": 1_800_000_001_000],
      ["dailyRemainingPercent": -1], ["weeklyRemainingPercent": 100.01],
      ["dailyRemainingPercent": "NaN"], ["dailyRemainingPercent": true],
      ["dailyResetAtUnix": 1_800_100_000], ["weeklyResetAtUnix": "1e300"],
      ["overageBalanceMicros": -1], ["overageBalanceMicros": "1e30"],
      ["hideDailyQuota": "true"], ["planName": String(repeating: "x", count: 97)],
      ["endTimestamp": ["nanos": 0]], ["endTimestamp": ["seconds": 1_801_728_000, "nanos": -1]],
    ] {
      #expect(throws: UsageProviderError.self) {
        try WindsurfProvider.decodeCache(Self.cache(overrides), now: Self.now)
      }
    }
    for data in [Data(), Data("{}".utf8), Data("[]".utf8), Data(repeating: 32, count: WindsurfProvider.maximumCacheBytes + 1)] {
      #expect(throws: UsageProviderError.self) { try WindsurfProvider.decodeCache(data, now: Self.now) }
    }
  }

  @Test func acceptsExactAliasesAndProtobufTimestamps() throws {
    let data = Data(#"{"planName":"Free","dailyQuotaRemainingPercent":100,"dailyQuotaResetAtUnix":1800043200,"endTimestamp":{"seconds":"1801728000","nanos":0}}"#.utf8)
    let snapshot = try WindsurfProvider.decodeCache(data, now: Self.now)
    #expect(snapshot.windows.count == 1)
    #expect(snapshot.windows[0].usedPercent == 0)
    #expect(snapshot.creditBalanceMinorUnits == nil)
  }

  @Test func missingInstallationDoesNotReadAnyCache() async {
    let provider = WindsurfProvider(installation: { nil }, cacheReader: { _ in
      Issue.record("Cache read without an installed desktop app")
      return Data()
    })
    do {
      _ = try await provider.fetch()
      Issue.record("Missing installation was accepted")
    } catch let error as UsageProviderError {
      guard case .executableNotFound = error else { Issue.record("Wrong missing-install recovery"); return }
    } catch { Issue.record("Unexpected error") }
  }

  @Test func recognizesCurrentAndLegacyDesktopInstallations() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    for name in ["Windsurf", "Devin"] {
      let contents = directory.appendingPathComponent("\(name).app/Contents")
      try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
      let info = try PropertyListSerialization.data(
        fromPropertyList: ["CFBundleIdentifier": "com.exafunction.windsurf", "CFBundleName": name],
        format: .xml, options: 0)
      try info.write(to: contents.appendingPathComponent("Info.plist"))
      let found = WindsurfInstallation.detect(home: directory, applicationDirectories: [directory])
      #expect(found?.name == name)
      #expect(found?.databaseURL.path.hasSuffix("\(name)/User/globalStorage/state.vscdb") == true)
    }
  }

  @Test func readsOnlyPlanValueAndRejectsAmbiguousAccounts() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = directory.appendingPathComponent("state.vscdb")
    var connection: OpaquePointer?
    #expect(sqlite3_open(database.path, &connection) == SQLITE_OK)
    defer { sqlite3_close(connection) }
    #expect(sqlite3_exec(connection, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil) == SQLITE_OK)
    #expect(sqlite3_exec(connection, "INSERT INTO ItemTable VALUES ('unrelated-setting', 'not-plan-data')", nil, nil, nil) == SQLITE_OK)
    #expect(throws: UsageProviderError.self) { try WindsurfPlanCache.read(database: database) }
    let value = String(decoding: try Self.cache(), as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    #expect(sqlite3_exec(connection, "INSERT INTO ItemTable VALUES ('windsurf.reactSettings.cachedPlanInfoData:fixture-one', '\(value)')", nil, nil, nil) == SQLITE_OK)
    let before = try Data(contentsOf: database)
    let read = try WindsurfPlanCache.read(database: database)
    #expect(try WindsurfProvider.decodeCache(read, now: Self.now).planName == "Pro")
    #expect(try Data(contentsOf: database) == before)
    #expect(sqlite3_exec(connection, "INSERT INTO ItemTable VALUES ('windsurf.reactSettings.cachedPlanInfoData:fixture-two', '{}')", nil, nil, nil) == SQLITE_OK)
    #expect(throws: UsageProviderError.self) { try WindsurfPlanCache.read(database: database) }
  }

  @Test func officialStatusMapping() throws {
    let data = Data(#"{"status":{"indicator":"minor","description":"Degraded performance"}}"#.utf8)
    let status = try ServiceStatusClient.decodeStatuspage(data, provider: .windsurf)
    #expect(status.health == .degraded)
    #expect(status.pageURL.host == "status.windsurf.com")
    #expect(ProviderID.allCases.last == .windsurf)
    #expect(ProviderHelperCatalog.definition(for: .windsurf).updateArguments.isEmpty)
  }

  @Test func desktopProviderCannotRunShellInstallers() async {
    let installer = ProviderHelperInstaller()
    do { try await installer.install(.windsurf); Issue.record("Desktop installation ran") }
    catch is ProviderHelperInstallerError {} catch { Issue.record("Unexpected installation error") }
    do { try await installer.update(.windsurf); Issue.record("Desktop update ran") }
    catch is ProviderHelperInstallerError {} catch { Issue.record("Unexpected update error") }
  }
}
