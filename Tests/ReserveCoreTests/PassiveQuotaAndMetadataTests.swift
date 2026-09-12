import Foundation
import Testing
@testable import ReserveCore

private actor VersionLoads {
  var count = 0
  func load() -> String { count += 1; return "grok 1.2.3" }
}

@Suite("Passive quota and provider metadata")
struct PassiveQuotaAndMetadataTests {
  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  @Test func statuslinePersistsOnlyQuotaAndExpiresWindows() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("quota.json")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let input = Data("""
      {"session_id":"PRIVATE-SESSION","transcript_path":"PRIVATE-PATH",
       "rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1800000300},
       "seven_day":{"used_percentage":61,"resets_at":1800200000}}}
      """.utf8)
    #expect(try ClaudeStatuslineBridge.ingest(input, cacheURL: cache, now: now))
    let bytes = try Data(contentsOf: cache)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("PRIVATE"))
    let snapshot = try #require(ClaudeStatuslineBridge.read(cacheURL: cache, now: now))
    #expect(snapshot.windows.map(\.usedPercent) == [24, 61])
    #expect(snapshot.fetchedAt == now)
    #expect(ClaudeStatuslineBridge.read(cacheURL: cache, now: now.addingTimeInterval(301))?.windows.count == 1)
    #expect(ClaudeStatuslineBridge.read(cacheURL: cache, now: now.addingTimeInterval(200_001)) == nil)
    let permissions = try FileManager.default.attributesOfItem(atPath: cache.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
  }

  @Test func invalidFeedCannotInventAllowanceOrOverwriteGoodObservation() throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = root.appendingPathComponent("quota.json")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let invalid = ["{}", #"{"rate_limits":{"five_hour":{"used_percentage":-1,"resets_at":1800000300}}}"#,
      #"{"rate_limits":{"five_hour":{"used_percentage":101,"resets_at":1800000300}}}"#,
      #"{"rate_limits":{"five_hour":{"used_percentage":1,"resets_at":1809999999}}}"#]
    for text in invalid { #expect(try !ClaudeStatuslineBridge.ingest(Data(text.utf8), cacheURL: cache, now: now)) }
    #expect(try !ClaudeStatuslineBridge.ingest(Data(repeating: 32, count: 65_537), cacheURL: cache, now: now))
    #expect(ClaudeStatuslineBridge.read(cacheURL: cache, now: now) == nil)
  }

  @Test func statuslineConfigurationPreservesOriginalAndRestoresExactly() throws {
    let original = Data(#"{"theme":"dark","statusLine":{"type":"command","command":"printf 'existing'","padding":2}}"#.utf8)
    let configured = try ClaudeStatuslineBridge.configuredSettings(original,
      executableURL: URL(fileURLWithPath: "/Applications/Reserve's App.app/Reserve"),
      cacheURL: URL(fileURLWithPath: "/tmp/cache.json"), settingsURL: URL(fileURLWithPath: "/tmp/settings.json"))
    let object = try #require(JSONSerialization.jsonObject(with: configured) as? [String: Any])
    let statusLine = try #require(object["statusLine"] as? [String: Any])
    let command = try #require(statusLine["command"] as? String)
    #expect(command.contains("'\\''"))
    #expect(!command.contains("existing"))
    #expect(statusLine["padding"] as? Int == 2)
    let restored = try ClaudeStatuslineBridge.restoredSettings(configured)
    #expect(try NSDictionary(dictionary: JSONSerialization.jsonObject(with: restored) as! [String: Any])
      .isEqual(to: JSONSerialization.jsonObject(with: original) as! [String: Any]))
  }

  @Test func laterUserStatuslineEditWins() throws {
    let configured = try ClaudeStatuslineBridge.configuredSettings(Data("{}".utf8),
      executableURL: URL(fileURLWithPath: "/tmp/Reserve"), cacheURL: URL(fileURLWithPath: "/tmp/cache"))
    var object = try #require(JSONSerialization.jsonObject(with: configured) as? [String: Any])
    object["statusLine"] = ["type": "command", "command": "printf newer"]
    let edited = try JSONSerialization.data(withJSONObject: object)
    let restored = try ClaudeStatuslineBridge.restoredSettings(edited)
    let result = try #require(JSONSerialization.jsonObject(with: restored) as? [String: Any])
    #expect((result["statusLine"] as? [String: String])?["command"] == "printf newer")
    #expect(result["reserveStatusline"] == nil)
    #expect(throws: UsageProviderError.self) {
      try ClaudeStatuslineBridge.configuredSettings(edited,
        executableURL: URL(fileURLWithPath: "/tmp/Reserve"), cacheURL: URL(fileURLWithPath: "/tmp/cache"))
    }
  }

  @Test func originalStatuslineReceivesSameInputAndOutputIsBounded() {
    let input = Data(#"{"transcript_path":"private but transient","rate_limits":null}"#.utf8)
    #expect(ClaudeStatuslineBridge.forward(input: input, command: "/bin/cat") == input)
    #expect(ClaudeStatuslineBridge.forward(input: Data(), command: "printf 'my existing status'")
      == Data("my existing status".utf8))
    #expect(ClaudeStatuslineBridge.forward(input: Data(repeating: 32, count: 65_537), command: "/bin/cat") == nil)
    #expect(ClaudeStatuslineBridge.forward(input: Data(), command: "/usr/bin/yes", timeout: 0.1) == nil)
  }

  @Test func codexDecodesMultipleBucketsAndResetCountWithoutLegacy() throws {
    let data = Data(#"{"rateLimitsByLimitId":{"codex":{"primary":{"usedPercent":25,"windowDurationMins":300}},"review":{"limitName":"Reviews","primary":{"usedPercent":80,"windowDurationMins":10080}}},"rateLimitResetCredits":{"availableCount":2,"credits":null}}"#.utf8)
    let result = try JSONDecoder().decode(OpenAIRateLimitsResponse.self, from: data)
    #expect(result.usageWindows.map(\.id) == ["five-hour", "review-weekly"])
    #expect(result.usageWindows.last?.label == "Reviews · Weekly")
    #expect(result.rateLimitResetCredits?.availableCount == 2)
  }

  @Test func codexLegacyStillWorksAndWindowCountIsBounded() throws {
    let legacy = try JSONDecoder().decode(OpenAIRateLimitsResponse.self,
      from: Data(#"{"rateLimits":{"primary":{"used_percent":12,"window_duration_mins":300}}}"#.utf8))
    #expect(legacy.usageWindows.first?.usedPercent == 12)
    #expect(legacy.rateLimitResetCredits == nil)
    let buckets = Dictionary(uniqueKeysWithValues: (0..<100).map {
      ("bucket-\($0)", ["primary": ["usedPercent": 20], "secondary": ["usedPercent": 30]])
    })
    let many = try JSONDecoder().decode(OpenAIRateLimitsResponse.self,
      from: JSONSerialization.data(withJSONObject: ["rateLimitsByLimitId": buckets]))
    #expect(many.usageWindows.count <= 32)
    #expect(Set(many.usageWindows.map(\.id)).count == many.usageWindows.count)
  }

  @Test func accountActivityRetainsUnknownAndRejectsBadDays() throws {
    let data = Data(#"{"summary":{"lifetimeTokens":1234},"dailyUsageBuckets":[{"startDate":"2026-09-10","tokens":12},{"startDate":"bad","tokens":25},{"startDate":"2026-09-11","tokens":-1}]}"#.utf8)
    let activity = try JSONDecoder().decode(OpenAIAccountActivity.self, from: data)
    #expect(activity.lifetimeTokens == 1234)
    #expect(activity.dailyUsageBuckets == [DailyUsage(day: "2026-09-10", tokens: 12)])
    #expect(try JSONDecoder().decode(OpenAIAccountActivity.self, from: JSONEncoder().encode(activity)) == activity)
    let unavailable = try JSONDecoder().decode(OpenAIAccountActivity.self, from: Data(#"{"summary":null,"dailyUsageBuckets":null}"#.utf8))
    #expect(unavailable.lifetimeTokens == nil)
    #expect(unavailable.dailyUsageBuckets == nil)
  }

  @Test func grokVersionCacheReprobesReplacement() async throws {
    let root = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let binary = root.appendingPathComponent("grok")
    try Data("one".utf8).write(to: binary)
    let cache = GrokVersionCache()
    let probe = VersionLoads()
    let first = try await cache.version(executable: binary.path) { await probe.load() }
    let second = try await cache.version(executable: binary.path) { await probe.load() }
    #expect(first == second)
    #expect(await probe.count == 1)
    try Data("replacement".utf8).write(to: binary, options: .atomic)
    _ = try await cache.version(executable: binary.path) { await probe.load() }
    #expect(await probe.count == 2)
  }
}
