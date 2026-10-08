import Foundation
import Testing
@testable import ReserveCore

@Suite("Cache savings coverage")
struct CacheSavingsCoverageTests {
  @Test func missingOrLaterModelContextNeverInventsAPrice() throws {
    let data = Data((Fixture.usage() + "\n" + Fixture.context("gpt-5.6-sol") + "\n").utf8)
    let parsed = try #require(LocalUsageScanner.parseCodexTailData(data))
    #expect(parsed.totals.input == 1_000_000)
    #expect(parsed.totals.cached == 1_000_000)
    #expect(parsed.totals.output == 10)
    #expect(parsed.totals.costUSD == 0 && parsed.totals.estimated)
    #expect(parsed.totals.pricedSavings == nil)
    #expect(parsed.totals.unpricedCacheReads == 1_000_000)
  }

  @Test func aLongTailRecoversACompleteModelContextAndRepricesAnOldIndex() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    // This model is outside the old 2 MB tail. A tool result mentions the
    // context record name but cannot supply its model or stop the search.
    let padding = "{\"type\":\"tool_result\",\"payload\":{\"tag\":\"turn_context\",\"text\":\""
      + String(repeating: "x", count: 64_000) + "\"}}\n"
    let data = Fixture.context("gpt-5.6-sol") + "\n" + Fixture.context("gpt-5.6-luna") + "\n"
      + String(repeating: padding, count: 48) + Fixture.usage() + "\n"
    try Data(data.utf8).write(to: fixture.codex.appendingPathComponent("long.jsonl"))
    let scanner = fixture.scanner()
    let first = try await scanner.scan(now: Fixture.now, providers: [.openAI])
    #expect(abs(try #require(first[.openAI]?.cacheSavingsUSD) - 0.9) < 0.000001)
    #expect(first[.openAI]?.cacheSavingsCoverage == 1)
    #expect(first[.openAI]?.totalTokens == 1_000_010)

    var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixture.cache)) as? [String: Any])
    var records = try #require(index["records"] as? [String: [String: Any]])
    let key = try #require(records.keys.first)
    records[key]?.removeValue(forKey: "codexPricingVersion")
    var days = try #require(records[key]?["days"] as? [String: [String: Any]])
    for day in days.keys { days[day]?["cacheSavingsUSD"] = 4.5 }
    records[key]?["days"] = days
    index["records"] = records
    try JSONSerialization.data(withJSONObject: index).write(to: fixture.cache)
    let migrated = fixture.scanner()
    let old = try await migrated.cachedUsage(now: Fixture.now, providers: [.openAI])
    #expect(old[.openAI]?.totalTokens == 1_000_010)
    #expect(old[.openAI]?.cacheSavingsUSD == nil)
    #expect(old[.openAI]?.cacheSavingsCoverage == 0)
    let corrected = try await migrated.scan(now: Fixture.now, providers: [.openAI])
    #expect(abs(try #require(corrected[.openAI]?.cacheSavingsUSD) - 0.9) < 0.000001)
    #expect(await migrated.scanMetrics.filesParsed == 1)
    _ = try await migrated.scan(now: Fixture.now, providers: [.openAI])
    #expect(await migrated.scanMetrics.filesParsed == 1)
  }

  @Test func mixedPricesKeepTheirSubtotalAndCoverageAfterReload() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    try fixture.write("priced", model: "gpt-5.6-luna")
    try fixture.write("unpriced", model: "codex-auto-review")
    let usage = try await fixture.scanner().scan(now: Fixture.now, providers: [.openAI])
    let summary = try #require(usage[.openAI])
    #expect(abs(try #require(summary.cacheSavingsUSD) - 0.9) < 0.000001)
    #expect(summary.cacheSavingsCoverage == 0.5)
    #expect(summary.unpricedCachedInputTokens == 1_000_000)
    #expect(summary.totalTokens == 2_000_020)
    let reread = try await fixture.scanner().cachedUsage(now: Fixture.now, providers: [.openAI])
    #expect(reread[.openAI] == summary)
    #expect(try JSONDecoder().decode(LocalUsageSummary.self, from: JSONEncoder().encode(summary)) == summary)
  }

  @Test func partialRowsRoundTripAndReplacementRestoresCoverage() throws {
    let known = UsageTotals(cached: 100, cacheSavingsUSD: 0.5, cacheSavingsKnown: true)
    let unknown = UsageTotals(cached: 100, cacheSavingsKnown: false)
    var mixed = UsageTotals()
    mixed.add(known)
    mixed.add(unknown)
    #expect(mixed.pricedSavings == 0.5 && mixed.unpricedCacheReads == 100)
    mixed = try JSONDecoder().decode(UsageTotals.self, from: JSONEncoder().encode(mixed))
    #expect(mixed.pricedSavings == 0.5 && mixed.unpricedCacheReads == 100)
    mixed.subtract(unknown)
    #expect(mixed.pricedSavings == 0.5 && mixed.unpricedCacheReads == 0)
    mixed.add(known)
    #expect(mixed.pricedSavings == 1 && mixed.cached == 200)
    mixed.subtract(known)
    mixed.add(unknown)
    mixed.subtract(known)
    #expect(mixed.pricedSavings == nil && mixed.unpricedCacheReads == 100)
  }

  @Test func legacyUnknownRowsNeverContributeAnAssumedPartialDiscount() throws {
    let data = Data(#"{"cached":100,"cacheSavingsKnown":false,"cacheSavingsUSD":42}"#.utf8)
    var totals = try JSONDecoder().decode(UsageTotals.self, from: data)
    #expect(totals.pricedSavings == nil)
    totals.add(UsageTotals(cached: 100, cacheSavingsUSD: 0.5, cacheSavingsKnown: true))
    #expect(totals.pricedSavings == 0.5 && totals.unpricedCacheReads == 100)
  }

  @Test func evenOneUnpricedReadKeepsAnOtherwiseHugeEstimatePartial() {
    let summary = LocalUsageSummary(
      provider: .openAI, periodDays: 30, inputTokens: .max, cachedInputTokens: .max,
      outputTokens: 0, apiEquivalentCostUSD: 0, cacheSavingsUSD: 1,
      unpricedCachedInputTokens: 1)
    #expect(summary.cacheSavingsUnpricedReads == 1)
  }

  @Test func anUnresolvedBoundedTailKeepsTokensWithoutAModelAssumption() async throws {
    let fixture = try Fixture()
    defer { fixture.remove() }
    let padding = String(repeating: "x", count: 64_000) + "\n"
    let data = Fixture.context("gpt-5.6-sol") + "\n"
      + String(repeating: padding, count: 140) + Fixture.usage() + "\n"
    try Data(data.utf8).write(to: fixture.codex.appendingPathComponent("too-long.jsonl"))
    let scanner = fixture.scanner()
    let usage = try await scanner.scan(now: Fixture.now, providers: [.openAI])
    #expect(usage[.openAI]?.totalTokens == 1_000_010)
    #expect(usage[.openAI]?.cacheSavingsUSD == nil)
    #expect(usage[.openAI]?.cacheSavingsCoverage == 0)
    #expect(await scanner.scanMetrics.bytesRead <= 8 * 1024 * 1024)
  }

  private struct Fixture {
    static let stamp = "2026-10-08T17:00:00Z"
    static let now = ISO8601DateFormatter().date(from: stamp)!
    let root: URL
    let codex: URL
    let cache: URL

    init() throws {
      root = FileManager.default.temporaryDirectory.appendingPathComponent("reserve-pricing-\(UUID().uuidString)")
      codex = root.appendingPathComponent("codex")
      cache = root.appendingPathComponent("index.json")
      try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func scanner() -> LocalUsageScanner {
      LocalUsageScanner(roots: .init(codex: codex, claude: root.appendingPathComponent("absent-claude"),
        grok: root.appendingPathComponent("absent-grok")), cacheURL: cache, timeZone: TimeZone(secondsFromGMT: 0))
    }
    func write(_ name: String, model: String) throws {
      try Data((Self.context(model) + "\n" + Self.usage() + "\n").utf8)
        .write(to: codex.appendingPathComponent("\(name).jsonl"))
    }
    static func context(_ model: String) -> String {
      #"{"timestamp":"\#(stamp)","type":"turn_context","payload":{"model":"\#(model)"}}"#
    }
    static func usage() -> String {
      #"{"timestamp":"\#(stamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000000,"cached_input_tokens":1000000,"output_tokens":10}}}}"#
    }
  }
}
