import Foundation
import Testing
@testable import ReserveCore

@Suite("Provider details for the expanded card")
struct ProviderDetailsTests {
  private static let now = Date(timeIntervalSince1970: 1_800_000_000)

  private func temporaryFile(_ contents: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-details-\(UUID().uuidString).json")
    try Data(contents.utf8).write(to: url)
    return url
  }

  @Test func detailsAreBoundedDeduplicatedAndSurviveTheCache() throws {
    let many = (0..<40).map { UsageDetail("Fact \($0 % 20)", "value") }
      + [UsageDetail("", "no label"), UsageDetail("No value", "  ")]
    let snapshot = UsageSnapshot(
      provider: .grok, windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 1)],
      source: "test", details: many + [UsageDetail(String(repeating: "L", count: 99), "v")])
    #expect(snapshot.details.count == UsageDetail.maximumCount)
    #expect(Set(snapshot.details.map(\.label)).count == snapshot.details.count)
    #expect(!snapshot.details.contains { $0.label.isEmpty || $0.value.isEmpty })
    let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
    #expect(decoded == snapshot)
    #expect(decoded.withFallbackPlanName("Plan").details == snapshot.details)

    // Caches written before details existed still load, with none.
    let legacy = Data(
      #"{"provider":"grok","windows":[],"fetchedAt":0,"source":"old","observationTimeKnown":true,"checkedAt":0}"#
        .utf8)
    #expect(try JSONDecoder().decode(UsageSnapshot.self, from: legacy).details.isEmpty)
  }

  @Test func codexExplainsCreditsSpendCapAndBlockedState() throws {
    let data = Data(
      #"""
      {"rateLimitsByLimitId":{"codex":{
        "primary":{"usedPercent":100,"windowDurationMins":300},
        "credits":{"hasCredits":true,"unlimited":false,"balance":"1250.5"},
        "individualLimit":{"used":"40","limit":"50","remainingPercent":20,"resetsAt":1800000000},
        "rateLimitReachedType":"workspace_member_credits_depleted"}}}
      """#.utf8)
    let response = try JSONDecoder().decode(OpenAIRateLimitsResponse.self, from: data)
    let selected = try #require(response.rateLimitsByLimitId?["codex"])
    let activity = OpenAIAccountActivity(
      lifetimeTokens: 5_400_000_000, dailyUsageBuckets: nil,
      peakDailyTokens: 72_000_000, currentStreakDays: 4, longestStreakDays: 19)
    let details = OpenAIDetails.details(
      limits: selected,
      account: try JSONDecoder().decode(
        OpenAIAccountResponse.self,
        from: Data(#"{"account":{"type":"chatgpt","email":"a@example.com","planType":"pro"}}"#.utf8)
      ).account,
      activity: activity)
    let byLabel = Dictionary(uniqueKeysWithValues: details.map { ($0.label, $0.value) })
    #expect(byLabel["Account"] == "a@example.com")
    #expect(byLabel["Status"] == "Workspace credits used up")
    #expect(byLabel["Credits"]?.hasSuffix("left") == true)
    #expect(byLabel["Spend cap"]?.hasPrefix("40 of 50 used · 20% left · resets") == true)
    #expect(byLabel["Lifetime tokens"] == "5.4B")
    #expect(byLabel["Busiest day"] == "72.0M tokens")
    #expect(byLabel["Streak"] == "4 days · longest 19 days")

    // A malformed extra never costs the limit windows.
    let odd = try JSONDecoder().decode(
      OpenAIRateLimitsResponse.self,
      from: Data(
        #"{"rateLimits":{"primary":{"usedPercent":5,"windowDurationMins":300},"credits":"weird","individualLimit":7}}"#
          .utf8))
    #expect(odd.usageWindows.count == 1)
    #expect(OpenAIDetails.details(limits: odd.rateLimits, account: nil, activity: nil).isEmpty)
  }

  @Test func claudeFiveHourScopedLimitKeepsItsRealPeriod() throws {
    let data = Data(
      #"""
      {"seven_day":{"utilization":40,"resets_at":"2033-05-18T03:33:20Z"},
       "limits":[
        {"kind":"weekly_scoped","percent":97,"resets_at":"2033-05-18T03:33:20Z","scope":{"model":{"id":"fable","display_name":"Fable"}}},
        {"kind":"five_hour_scoped","percent":30,"resets_at":"2033-05-18T03:33:20Z","scope":{"model":{"id":"fable","display_name":"Fable"}}}]}
      """#.utf8)
    let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    #expect(response.limits?.map(\.kind) == ["weekly_scoped", "five_hour_scoped"])
  }

  @Test func claudeAccountProfileShowsOnlyMeaningfulFields() throws {
    let personal = try temporaryFile(
      #"""
      {"projects":{"/x":{}},"oauthAccount":{"emailAddress":"me@example.com",
       "organizationName":"me@example.com's Organization","organizationType":"claude_max",
       "organizationRole":"admin","subscriptionCreatedAt":"2025-01-02T00:00:00Z",
       "claudeCodeTrialEndsAt":null}}
      """#)
    defer { try? FileManager.default.removeItem(at: personal) }
    let labels = try #require(ClaudeAccountProfile.load(from: personal))
      .details(now: Self.now).map(\.label)
    #expect(labels == ["Account", "Subscribed since"])

    let team = try temporaryFile(
      #"{"oauthAccount":{"emailAddress":"w@corp.com","organizationName":"Corp","organizationType":"team","organizationRole":"billing_admin"}}"#)
    defer { try? FileManager.default.removeItem(at: team) }
    let details = try #require(ClaudeAccountProfile.load(from: team)).details(now: Self.now)
    #expect(details.first { $0.label == "Organization" }?.value == "Corp · Billing Admin")

    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    #expect(ClaudeAccountProfile.load(from: missing) == nil)
  }

  @Test func copilotShowsRequestCountsAndUnlimitedProducts() throws {
    let data = try JSONSerialization.data(withJSONObject: [
      "quotaSnapshots": [
        "premium_interactions": [
          "isUnlimitedEntitlement": false, "entitlementRequests": 300, "usedRequests": 212,
          "remainingPercentage": 29.3, "resetDate": "2027-02-01T00:00:00Z",
        ],
        "chat": [
          "isUnlimitedEntitlement": true, "entitlementRequests": -1, "usedRequests": 0,
          "remainingPercentage": 100,
        ],
      ]
    ])
    let snapshot = try CopilotProvider.decodeQuota(data, now: Self.now)
    #expect(snapshot.details.map(\.label) == ["Premium requests", "Chat"])
    #expect(snapshot.details.first?.value == "212 of 300 used")
    #expect(snapshot.details.last?.value == "Unlimited")
  }

  @Test func cursorShowsIncludedUsageAndTeamPool() throws {
    let current = try JSONDecoder().decode(
      CursorCurrentPeriodUsageResponse.self,
      from: Data(
        #"{"planUsage":{"totalSpend":1500,"limit":2000,"totalPercentUsed":75},"spendLimitUsage":{"overallLimit":50000,"overallUsed":12000,"limitType":"team"}}"#
          .utf8))
    let details = CursorProvider.details(current: current, includedCents: nil)
    #expect(details.map(\.label) == ["Included usage", "Team pool"])
    #expect(details[0].value == "$15.00 of $20.00 · 75% used")
    #expect(details[1].value == "$120 of $500 used")
  }

  @Test func statusPageListsOpenIncidentsComponentsAndMaintenance() throws {
    let data = Data(
      #"""
      {"status":{"indicator":"minor","description":"Minor Service Outage"},
       "components":[{"name":"Claude Code","status":"degraded_performance"},
                     {"name":"claude.ai","status":"operational"},
                     {"name":"Group","status":"major_outage","group":true}],
       "incidents":[{"name":"Elevated errors on Claude Code","status":"investigating"},
                    {"name":"Old","status":"resolved"}],
       "scheduled_maintenances":[{"name":"Database upgrade","status":"scheduled","scheduled_for":"2033-05-18T03:33:20Z"}]}
      """#.utf8)
    let status = try ServiceStatusClient.decodeStatuspage(data, provider: .anthropic, now: Self.now)
    #expect(status.health == .degraded)
    let notices = try #require(status.notices)
    #expect(notices.count == 3)
    #expect(notices[0] == "Elevated errors on Claude Code")
    #expect(notices[1] == "Claude Code: degraded performance")
    #expect(notices[2].hasPrefix("Maintenance: Database upgrade · "))

    // A status page without the lists still reports health.
    let bare = try ServiceStatusClient.decodeStatuspage(
      Data(#"{"status":{"indicator":"none","description":"All good"},"components":"x"}"#.utf8),
      provider: .openAI, now: Self.now)
    #expect(bare.health == .operational)
    #expect(bare.notices == nil)
  }
}
