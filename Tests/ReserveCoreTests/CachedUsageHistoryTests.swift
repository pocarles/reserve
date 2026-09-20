import Foundation
import Testing
@testable import ReserveCore

@Suite("Cached usage history")
struct CachedUsageHistoryTests {
  private let fetched = Date(timeIntervalSince1970: 1_700_000_000)

  private func day(
    _ key: String, tokens: Int64?, costUSD: Double? = nil, fetchedAt: Date? = nil
  ) -> CachedUsageDay {
    CachedUsageDay(day: key, tokens: tokens, costUSD: costUSD, fetchedAt: fetchedAt ?? fetched)
  }

  /// Fixed Gregorian zone so civil-day math does not follow the machine zone.
  private func calendar(timeZone identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private func date(_ text: String, timeZone identifier: String) -> Date {
    let calendar = self.calendar(timeZone: identifier)
    let parts = text.split(separator: "-").map { Int($0)! }
    return calendar.date(from: DateComponents(
      year: parts[0], month: parts[1], day: parts[2], hour: 15
    ))!
  }

  @Test func mergeReplacesOverlappingDaysAndKeepsTheRest() {
    let stored = CachedUsageHistory(provider: .anthropic, days: [
      day("2026-01-01", tokens: 10),
      day("2026-01-02", tokens: 20, costUSD: 1),
      day("2026-01-03", tokens: 30),
    ])
    let merged = stored.merge([
      day("2026-01-02", tokens: 0, costUSD: 4, fetchedAt: fetched.addingTimeInterval(60)),
      day("2026-01-04", tokens: 40),
    ])

    #expect(merged.provider == .anthropic)
    #expect(merged.days.map(\.day) == ["2026-01-01", "2026-01-02", "2026-01-03", "2026-01-04"])
    #expect(merged.days.map(\.tokens) == [10, 0, 30, 40])
    #expect(merged.days[1].costUSD == 4)
    #expect(merged.days[1].fetchedAt == fetched.addingTimeInterval(60))
    #expect(stored.days[1].tokens == 20)
  }

  @Test func invalidDayKeysNeverEnterStorage() {
    let history = CachedUsageHistory(provider: .openAI, days: [
      day("2026-03-01", tokens: 4),
      day("03/01/2026", tokens: 9),
      day("2026-02-31", tokens: 8),
      day("", tokens: 1),
    ])
    #expect(history.days.map(\.day) == ["2026-03-01"])
    let merged = history.merge([
      day("not-a-day", tokens: 3),
      day("2026-03-02", tokens: 6),
    ])
    #expect(merged.days.map(\.day) == ["2026-03-01", "2026-03-02"])
    #expect(day("2026-13-40", tokens: 1).day.isEmpty)
  }

  @Test func duplicateDayKeysReplaceInsteadOfCrashing() {
    let history = CachedUsageHistory(provider: .openAI, days: [
      day("2026-03-01", tokens: 1),
      day("2026-03-01", tokens: 9, costUSD: 2),
      day("2026-03-02", tokens: 3),
      day("2026-03-02", tokens: 0),
    ])
    #expect(history.days.map(\.day) == ["2026-03-01", "2026-03-02"])
    #expect(history.days.map(\.tokens) == [9, 0])
    #expect(history.days[0].costUSD == 2)

    let merged = history.merge([
      day("2026-03-02", tokens: 5),
      day("2026-03-02", tokens: 8),
    ])
    #expect(merged.days.map(\.tokens) == [9, 8])
  }

  @Test func negativeAndNonfiniteValuesAreSanitized() {
    let row = day("2026-04-01", tokens: -5, costUSD: -3)
    #expect(row.tokens == 0)
    #expect(row.costUSD == 0)

    let unknownCost = day("2026-04-02", tokens: 1, costUSD: .infinity)
    #expect(unknownCost.tokens == 1)
    #expect(unknownCost.costUSD == nil)
    #expect(day("2026-04-03", tokens: 2, costUSD: .nan).costUSD == nil)
    #expect(day("2026-04-04", tokens: nil, costUSD: nil).tokens == nil)
  }

  @Test func pruneDropsOlderThanNinetyCivilDaysAndFutureDates() {
    let zone = calendar(timeZone: "UTC")
    let now = date("2026-09-19", timeZone: "UTC")
    let history = CachedUsageHistory(provider: .grok, days: [
      day("2026-06-21", tokens: 1),
      day("2026-06-22", tokens: 2),
      day("2026-09-19", tokens: 3),
      day("2026-09-20", tokens: 4),
      day("not-a-day", tokens: 5),
    ])

    let pruned = history.prune(now: now, calendar: zone)
    #expect(pruned.days.map(\.day) == ["2026-06-22", "2026-09-19"])
    #expect(pruned.days.map(\.tokens) == [2, 3])
  }

  @Test func gapsStayNilAndKnownZeroStaysZero() {
    let zone = calendar(timeZone: "America/New_York")
    let now = date("2026-03-10", timeZone: "America/New_York")
    let history = CachedUsageHistory(provider: .kimi, days: [
      day("2026-03-04", tokens: 0, costUSD: 0),
      day("2026-03-06", tokens: 12),
      day("2026-03-10", tokens: nil, costUSD: 1.5),
    ])

    let slice = history.slice7(now: now, calendar: zone)
    #expect(slice.requestedDays == 7)
    #expect(slice.days.map(\.day) == [
      "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07",
      "2026-03-08", "2026-03-09", "2026-03-10",
    ])
    #expect(slice.days.map(\.tokens) == [0, nil, 12, nil, nil, nil, nil])
    #expect(slice.days[0].costUSD == 0)
    #expect(slice.days[6].tokens == nil)
    #expect(slice.days[6].costUSD == 1.5)
    #expect(slice.days[1].fetchedAt == .distantPast)
    #expect(slice.days[1].costUSD == nil)
    #expect(slice.coveredDayCount == 2)
  }

  @Test func slicesOfSevenThirtyAndNinetyEndOnNow() {
    let zone = calendar(timeZone: "Pacific/Auckland")
    let now = date("2026-09-19", timeZone: "Pacific/Auckland")
    var rows: [CachedUsageDay] = []
    var cursor = Calendar(identifier: .gregorian)
    cursor.timeZone = zone.timeZone
    let start = cursor.date(from: DateComponents(year: 2026, month: 6, day: 22))!
    for offset in 0..<90 {
      let key = CachedUsageHistory.dayKey(
        for: cursor.date(byAdding: .day, value: offset, to: start)!, calendar: zone)
      rows.append(day(key, tokens: Int64(offset)))
    }
    let history = CachedUsageHistory(provider: .gemini, days: rows)

    let week = history.slice7(now: now, calendar: zone)
    let month = history.slice30(now: now, calendar: zone)
    let quarter = history.slice90(now: now, calendar: zone)

    #expect(week.days.count == 7)
    #expect(month.days.count == 30)
    #expect(quarter.days.count == 90)
    #expect(week.days.last?.day == "2026-09-19")
    #expect(month.days.first?.day == "2026-08-21")
    #expect(quarter.days.first?.day == "2026-06-22")
    #expect(week.coveredDayCount == 7)
    #expect(month.coveredDayCount == 30)
    #expect(quarter.coveredDayCount == 90)
    #expect(history.slice(periodDays: 0, now: now, calendar: zone).requestedDays == 1)
    #expect(history.slice(periodDays: 365, now: now, calendar: zone).requestedDays == 90)
  }

  @Test func dstSpringForwardStillYieldsSevenDistinctDays() {
    let zone = calendar(timeZone: "America/New_York")
    // 2026-03-08 is the US spring-forward day. 15:00 exists on every day.
    let now = date("2026-03-10", timeZone: "America/New_York")
    let history = CachedUsageHistory(provider: .copilot, days: [
      day("2026-03-08", tokens: 8),
    ])
    let slice = history.slice7(now: now, calendar: zone)
    #expect(slice.days.map(\.day) == [
      "2026-03-04", "2026-03-05", "2026-03-06", "2026-03-07",
      "2026-03-08", "2026-03-09", "2026-03-10",
    ])
    #expect(Set(slice.days.map(\.day)).count == 7)
    #expect(slice.days[4].tokens == 8)
    #expect(slice.days[4].day == "2026-03-08")
    #expect(slice.coveredDayCount == 1)
  }

  @Test func dstFallBackStillYieldsThirtyDistinctDays() {
    let zone = calendar(timeZone: "America/Los_Angeles")
    // 2026-11-01 is the US fall-back day.
    let now = date("2026-11-03", timeZone: "America/Los_Angeles")
    let month = CachedUsageHistory(provider: .cursor, days: [])
      .slice30(now: now, calendar: zone)
    let keys = month.days.map(\.day)
    #expect(keys.count == 30)
    #expect(Set(keys).count == 30)
    #expect(keys.first == "2026-10-05")
    #expect(keys.last == "2026-11-03")
    #expect(keys.contains("2026-11-01"))
    #expect(month.coveredDayCount == 0)
  }

  @Test func codableRoundTripKeepsNilDistinctFromZero() throws {
    let history = CachedUsageHistory(provider: .zai, days: [
      day("2026-09-01", tokens: nil, costUSD: nil),
      day("2026-09-02", tokens: 0, costUSD: 0),
    ])
    let data = try JSONEncoder().encode(history)
    let decoded = try JSONDecoder().decode(CachedUsageHistory.self, from: data)
    #expect(decoded == history)
    #expect(decoded.days[0].tokens == nil)
    #expect(decoded.days[1].tokens == 0)
  }

  @Test func cacheOnlyReadSurvivesSourceRootRemoval() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let stamp = "2026-09-19T15:00:00Z"
    let line = #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":11,"output_tokens":2,"total_tokens":13}}}}"#
    try Data((line + "\n").utf8).write(to: fixture.codex.appendingPathComponent("session.jsonl"))
    let scanner = fixture.scanner()
    let summary = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    #expect(summary[.openAI]?.totalTokens == 13)
    try FileManager.default.removeItem(at: fixture.codex)

    let gone = LocalUsageScanner(
      roots: .init(
        codex: fixture.root.appendingPathComponent("missing-codex"),
        claude: fixture.root.appendingPathComponent("missing-claude"),
        grok: fixture.root.appendingPathComponent("missing-grok")),
      cacheURL: fixture.cache)
    let before = try Data(contentsOf: fixture.cache)
    let history = await gone.cachedHistory(periodDays: 90, now: now, providers: [.openAI])
    #expect(try Data(contentsOf: fixture.cache) == before)
    let row = try #require(history[.openAI]?.days.first { $0.day == "2026-09-19" })
    #expect(row.tokens == 13)
    #expect((history[.openAI]?.days.count ?? 0) < 30)
  }

  @Test func legacyIndexWithoutDailyHistoryStillDecodes() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"fixture":{"days":{"2026-09-01":{"cacheWrite":0,"cached":0,"costUSD":1.25,"estimated":false,"input":4,"output":1},"2026-09-02":{"cacheWrite":0,"cached":0,"costUSD":0,"estimated":false,"input":0,"output":0}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":0,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let history = await fixture.scanner().cachedHistory(now: now, providers: [.openAI])
    let days = try #require(history[.openAI]).days
    #expect(days.map(\.day) == ["2026-09-01", "2026-09-02"])
    #expect(days.map(\.tokens) == [5, 0])
    #expect(days[0].costUSD == 1.25)
    #expect(days[1].costUSD == 0)
    let week = history[.openAI]?.slice7(now: now)
    #expect(week?.days.count == 7)
    #expect(week?.days.map(\.day).contains("2026-09-01") == false)
    #expect(week?.coveredDayCount == 0)
  }

  @Test func cancelledScanLeavesSavedArchiveUntouched() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let line = #"{"timestamp":"2026-09-19T15:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":7,"output_tokens":1,"total_tokens":8}}}}"#
    try Data((line + "\n").utf8).write(to: fixture.codex.appendingPathComponent("session.jsonl"))
    let scanner = fixture.scanner()
    _ = try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    let saved = try Data(contentsOf: fixture.cache)
    try Data(Data(repeating: 0x41, count: 64 * 1024)).write(
      to: fixture.codex.appendingPathComponent("bulk.jsonl"))
    let task = Task {
      try await scanner.scan(periodDays: 30, now: now, providers: [.openAI])
    }
    task.cancel()
    do {
      _ = try await task.value
    } catch is CancellationError {
    } catch let error as UsageProviderError {
      guard case .timedOut = error else { throw error }
    }
    #expect(try Data(contentsOf: fixture.cache) == saved)
    let history = await scanner.cachedHistory(now: now, providers: [.openAI])
    #expect(history[.openAI]?.days.contains { $0.day == "2026-09-19" && $0.tokens == 8 } == true)
  }

  @Test func rescanReplacesOverlapAndKeepsOlderArchiveWithinNinetyDays() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let session = fixture.codex.appendingPathComponent("session.jsonl")
    let firstNow = date("2026-08-01", timeZone: TimeZone.current.identifier)
    let firstLine = #"{"timestamp":"2026-08-01T15:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":3,"output_tokens":1,"total_tokens":4}}}}"#
    try Data((firstLine + "\n").utf8).write(to: session)
    let scanner = fixture.scanner()
    _ = try await scanner.scan(periodDays: 30, now: firstNow, providers: [.openAI])

    let secondNow = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let secondLine = #"{"timestamp":"2026-09-19T15:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":9,"output_tokens":1,"total_tokens":10}}}}"#
    try Data((secondLine + "\n").utf8).write(to: session)
    _ = try await scanner.scan(periodDays: 30, now: secondNow, providers: [.openAI])
    let history = await scanner.cachedHistory(periodDays: 90, now: secondNow, providers: [.openAI])
    let days = try #require(history[.openAI]).days
    #expect(days.contains { $0.day == "2026-08-01" && $0.tokens == 4 })
    #expect(days.contains { $0.day == "2026-09-19" && $0.tokens == 10 })
    #expect(days.allSatisfy { $0.day >= "2026-06-22" && $0.day <= "2026-09-19" })

    let replaced = #"{"timestamp":"2026-09-19T16:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":20,"output_tokens":1,"total_tokens":21}}}}"#
    try Data((replaced + "\n").utf8).write(to: session)
    _ = try await scanner.scan(periodDays: 30, now: secondNow, providers: [.openAI])
    let again = await scanner.cachedHistory(now: secondNow, providers: [.openAI])
    let rows = try #require(again[.openAI]).days
    #expect(rows.filter { $0.day == "2026-09-19" }.map(\.tokens) == [21])
    #expect(rows.contains { $0.day == "2026-08-01" && $0.tokens == 4 })
  }

  @Test func twoLegacyFilesOnTheSameDayAreSummed() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"b":{"days":{"2026-09-02":{"cacheWrite":0,"cached":0,"costUSD":0.25,"estimated":false,"input":1,"output":1}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0},"a":{"days":{"2026-09-02":{"cacheWrite":0,"cached":0,"costUSD":1.5,"estimated":false,"input":10,"output":2}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":100,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let history = await fixture.scanner().cachedHistory(now: now, providers: [.openAI])
    let row = try #require(history[.openAI]?.days.first { $0.day == "2026-09-02" })
    #expect(row.tokens == 14)
    #expect(row.costUSD == 1.75)
    #expect(history[.openAI]?.days.filter { $0.day == "2026-09-02" }.count == 1)
  }

  @Test func cancelledEmptyRootLeavesCacheUnchanged() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"kept":{"days":{"2026-09-01":{"cacheWrite":0,"cached":0,"costUSD":1,"estimated":false,"input":3,"output":1}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":50,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let saved = try Data(contentsOf: fixture.cache)
    let empty = fixture.root.appendingPathComponent("no-such-root")
    let scanner = LocalUsageScanner(
      roots: .init(codex: empty, claude: empty, grok: empty), cacheURL: fixture.cache)
    let task = Task {
      try await scanner.scan(
        periodDays: 30, now: date("2026-09-19", timeZone: TimeZone.current.identifier),
        providers: [.openAI])
    }
    task.cancel()
    do {
      _ = try await task.value
    } catch is CancellationError {
    }
    #expect(try Data(contentsOf: fixture.cache) == saved)
  }

  @Test func unknownPricedTokensStayUnpriced() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"unknown":{"days":{"2026-09-03":{"cacheWrite":0,"cached":0,"costUSD":0,"estimated":true,"input":6,"output":1}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":100,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let row = try #require(
      await fixture.scanner().cachedHistory(now: now, providers: [.openAI])[.openAI]?
        .days.first { $0.day == "2026-09-03" })
    #expect(row.tokens == 7)
    #expect(row.costUSD == nil)
  }

  @Test func knownPlusUnknownSameDayDropsCostWithoutDroppingTokens() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"known":{"days":{"2026-09-04":{"cacheWrite":0,"cached":0,"costUSD":1.5,"estimated":false,"input":10,"output":2}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0},"unknown":{"days":{"2026-09-04":{"cacheWrite":0,"cached":0,"costUSD":0,"estimated":true,"input":4,"output":0}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":100,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let row = try #require(
      await fixture.scanner().cachedHistory(now: now, providers: [.openAI])[.openAI]?
        .days.first { $0.day == "2026-09-04" })
    #expect(row.tokens == 16)
    #expect(row.costUSD == nil)
  }

  @Test func positiveGrokEstimateStaysPriced() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"estimate":{"days":{"2026-09-05":{"cacheWrite":0,"cached":0,"costUSD":2.5,"estimated":true,"input":8,"output":0}},"modifiedAt":0,"offset":0,"provider":"grok","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":100,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let row = try #require(
      await fixture.scanner().cachedHistory(now: now, providers: [.grok])[.grok]?
        .days.first { $0.day == "2026-09-05" })
    #expect(row.tokens == 8)
    #expect(row.costUSD == 2.5)
  }

  @Test func knownQuietZeroStaysZero() async throws {
    let fixture = try HistoryFixture()
    defer { fixture.remove() }
    let legacy = """
    {"records":{"quiet":{"days":{"2026-09-06":{"cacheWrite":0,"cached":0,"costUSD":0,"estimated":false,"input":0,"output":0}},"modifiedAt":0,"offset":0,"provider":"openAI","recentOrder":[],"recentRows":{},"size":0}},"updatedAt":100,"version":1}
    """
    try Data(legacy.utf8).write(to: fixture.cache)
    let now = date("2026-09-19", timeZone: TimeZone.current.identifier)
    let row = try #require(
      await fixture.scanner().cachedHistory(now: now, providers: [.openAI])[.openAI]?
        .days.first { $0.day == "2026-09-06" })
    #expect(row.tokens == 0)
    #expect(row.costUSD == 0)
  }
}

private struct HistoryFixture {
  let root: URL
  let codex: URL
  let cache: URL

  init() throws {
    self.root = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-history-\(UUID().uuidString)", isDirectory: true)
    self.codex = root.appendingPathComponent("codex", isDirectory: true)
    self.cache = root.appendingPathComponent("index.json")
    let claude = root.appendingPathComponent("claude", isDirectory: true)
    let grok = root.appendingPathComponent("grok", isDirectory: true)
    for directory in [codex, claude, grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
  }

  func scanner() -> LocalUsageScanner {
    LocalUsageScanner(
      roots: .init(
        codex: codex,
        claude: root.appendingPathComponent("claude"),
        grok: root.appendingPathComponent("grok")),
      cacheURL: cache)
  }

  func remove() {
    try? FileManager.default.removeItem(at: root)
  }
}
