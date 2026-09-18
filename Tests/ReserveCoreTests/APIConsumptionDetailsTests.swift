import Foundation
import Testing
@testable import ReserveCore

@Suite("API consumption details for an opened row")
struct APIConsumptionDetailsTests {
  /// 2025-09-17 00:00 UTC: the 17th, so a full seven-day window exists.
  private static let now = Date(timeIntervalSince1970: 1_758_067_200)

  private func client(_ body: String) -> APIConsumptionClient {
    APIConsumptionClient(
      requestHandler: { request in
        (
          Data(body.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        )
      },
      now: { Self.now })
  }

  private func byLabel(_ snapshot: APIConsumptionSnapshot) -> [String: String] {
    Dictionary(uniqueKeysWithValues: snapshot.details.map { ($0.label, $0.value) })
  }

  @Test func openRouterShowsKeyLimitOwnKeysAndFreeModels() async throws {
    let snapshot = try await self.client(
      #"""
      {"data":{"label":"laptop","usage":40.5,"usage_daily":1.5,"usage_weekly":6,
      "usage_monthly":12.34,"limit":50,"limit_remaining":9.5,"limit_reset":"monthly",
      "include_byok_in_limit":true,"byok_usage":3.2,"byok_usage_monthly":1.1,
      "is_free_tier":true,"expires_at":"2026-01-01T00:00:00Z",
      "free_model_daily_requests":{"used":12,"limit":50,"remaining":38}}}
      """#
    ).fetch(.openRouter, apiKey: "sk-or-test")
    let details = self.byLabel(snapshot)
    #expect(details["Key"] == "laptop")
    #expect(details["All time"] == "$40.50")
    #expect(details["Credit limit"] == "$50.00 · resets monthly · includes your own keys")
    #expect(details["Your own provider keys"] == "$1.10 this month · $3.20 all time")
    #expect(details["Free-model requests today"] == "12 of 50")
    #expect(details["Tier"] == "Free")
    #expect(details["Key expires"] != nil)
    // The windows the row already shows are unchanged.
    #expect(snapshot.windows.map(\.id) == ["today", "week", "month", "credits"])
  }

  @Test func openRouterWithoutACapSaysSo() async throws {
    let snapshot = try await self.client(
      #"{"data":{"usage":2,"usage_daily":0,"usage_weekly":0,"usage_monthly":2,"limit":null}}"#
    ).fetch(.openRouter, apiKey: "sk-or-test")
    #expect(self.byLabel(snapshot)["Credit limit"] == "None")
    #expect(self.byLabel(snapshot)["Your own provider keys"] == nil)
  }

  @Test func typeSafeListsEveryModelWithItsDescriptionAndDate() async throws {
    let snapshot = try await self.client(
      #"""
      {"models":[{"name":"jev-latest","description":"Flagship System One model","release_date":"2026-05-01"},
                 {"name":"jev-preview","description":null,"release_date":null},
                 {"name":"  "}]}
      """#
    ).fetch(.typeSafe, apiKey: "ts-test")
    let details = self.byLabel(snapshot)
    #expect(snapshot.details.first?.label == "Price")
    #expect(details["jev-latest"]?.hasPrefix("Flagship System One model · released ") == true)
    #expect(details["jev-preview"] == "Available")
    #expect(snapshot.details.count == 3)
    #expect(snapshot.note?.headline == "2 models")
  }

  @Test func adminCostsShowDailyFiguresAndEveryContributor() async throws {
    // Buckets on the 1st, the 12th and today (the 17th).
    let body = #"""
      {"data":[
        {"start_time":1756684800,"results":[{"amount":{"value":4,"currency":"usd"},"line_item":"gpt-5, input"}]},
        {"start_time":1757635200,"results":[{"amount":{"value":10,"currency":"usd"},"line_item":"gpt-5, output"}]},
        {"start_time":1758067200,"results":[{"amount":{"value":1.5,"currency":"usd"},"line_item":"gpt-5, input"}]}]}
      """#
    let snapshot = try await self.client(body).fetch(.openAI, apiKey: "sk-admin-test")
    let details = self.byLabel(snapshot)
    #expect(details["Today"] == "$1.50")
    #expect(details["Last 7 days"] == "$11.50")
    #expect(details["Busiest day"]?.hasPrefix("$10.00 on ") == true)
    #expect(details["Daily average"] == "$0.91")
    #expect(details["gpt-5, output"] == "$10.00")
    #expect(details["gpt-5, input"] == "$5.50")
  }

  @Test func anthropicDailyFiguresReadStartingAt() async throws {
    let body = #"""
      {"data":[{"starting_at":"2025-09-17T00:00:00Z","results":[{"amount":"250.00","model":"claude-opus-5"}]}]}
      """#
    let snapshot = try await self.client(body).fetch(.anthropic, apiKey: "sk-ant-admin-test")
    #expect(self.byLabel(snapshot)["Today"] == "$2.50")
    #expect(self.byLabel(snapshot)["claude-opus-5"] == "$2.50")
  }

  @Test func detailsSurviveTheCacheAndOldCachesStillLoad() throws {
    let snapshot = APIConsumptionSnapshot(
      provider: .openRouter, windows: [], source: "test",
      details: [UsageDetail("Key", "laptop")])
    let decoded = try JSONDecoder().decode(
      APIConsumptionSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    let legacy = Data(#"{"provider":"xAI","windows":[],"fetchedAt":0,"source":"old"}"#.utf8)
    #expect(try JSONDecoder().decode(APIConsumptionSnapshot.self, from: legacy).details.isEmpty)
  }
}
