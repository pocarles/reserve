import Foundation
import Testing
@testable import ReserveCore

/// Z.ai GLM Coding Plan and Kimi Code are plans connected with a pasted key.
/// Payloads are taken from the open-source clients the decoders follow
/// (CodexBar fixtures and docs); the endpoints themselves are unofficial.
@Suite("API-key plan providers")
struct APIKeyPlanProviderTests {
  private final class Sent: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URLRequest] = []
    func add(_ request: URLRequest) { self.lock.withLock { self.stored.append(request) } }
    var requests: [URLRequest] { self.lock.withLock { self.stored } }
  }

  private static func handler(
    status: Int = 200, _ body: String, recording sent: Sent = Sent(),
    headers: [String: String]? = nil, responseURL: URL? = nil
  ) -> APIKeyPlanTransport.RequestHandler {
    { request in
      sent.add(request)
      return (
        Data(body.utf8),
        HTTPURLResponse(
          url: responseURL ?? request.url!, statusCode: status, httpVersion: nil,
          headerFields: headers)!
      )
    }
  }

  // MARK: Z.ai

  /// 2026-08-03T11:33:20Z: 4.4 hours before the fixture's five-hour reset.
  private static let zaiNow = Date(timeIntervalSince1970: 1_785_800_000)
  private static let zaiKey = "0123456789abcdef0123456789abcdef.ZaiSecretPart42"

  /// CodexBar `ProviderPluginDetailsParityTests.zaiQuota`.
  private static let zaiTokenQuota = #"""
    {"code":200,"msg":"success","success":true,"data":{"planName":"Pro","limits":[
      {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25,"nextResetTime":1785816000000},
      {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":9,"nextResetTime":1786291200000},
      {"type":"TIME_LIMIT","unit":5,"number":1,"usage":1000,"currentValue":224,"remaining":776,
       "percentage":22,"usageDetails":[{"modelCode":"search-prime","usage":210},
       {"modelCode":"web-reader","usage":14}]}
    ]}}
    """#

  /// CodexBar `ProviderPluginDetailsParityTests.zaiCreditQuota`.
  private static let zaiCreditQuota = #"""
    {"code":200,"msg":"success","success":true,"data":{"level":"lite","limits":[
      {"type":"CREDIT_LIMIT","unit":3,"number":5,"usage":2000,"currentValue":100,"remaining":1900,
       "percentage":5,"nextResetTime":1785810000000},
      {"type":"CREDIT_LIMIT","unit":6,"number":1,"usage":10000,"currentValue":1000,"remaining":9000,
       "percentage":10,"nextResetTime":1786291200000}
    ]}}
    """#

  private func zai(
    status: Int = 200, _ body: String, recording sent: Sent = Sent(),
    responseURL: URL? = nil
  ) -> ZaiProvider {
    ZaiProvider(
      apiKey: Self.zaiKey,
      requestHandler: Self.handler(status: status, body, recording: sent, responseURL: responseURL),
      now: { Self.zaiNow })
  }

  @Test func zaiMapsTheFiveHourAndWeeklyTokenWindows() async throws {
    let snapshot = try await self.zai(Self.zaiTokenQuota).fetch()
    #expect(snapshot.provider == .zai)
    #expect(snapshot.planName == "GLM Coding Pro")
    #expect(snapshot.windows.map(\.label) == ["5 hours", "Weekly"])
    let fiveHour = try #require(snapshot.windows.first)
    #expect(fiveHour.usedPercent == 25)
    #expect(fiveHour.windowMinutes == 300)
    #expect(fiveHour.resetsAt == Date(timeIntervalSince1970: 1_785_816_000))
    let weekly = try #require(snapshot.windows.last)
    #expect(weekly.usedPercent == 9)
    #expect(weekly.windowMinutes == 10_080)
    #expect(weekly.resetsAt == Date(timeIntervalSince1970: 1_786_291_200))
    // The monthly tool quota is reported, not metered as a plan limit.
    #expect(snapshot.details.contains(UsageDetail("Tool calls", "\(UsageDetailFormat.number(224)) of \(UsageDetailFormat.number(1000)) this month")))
    #expect(snapshot.source.contains("unofficial"))
    // Pace is available because window length and reset are both known.
    #expect(UsagePaceProjection.calculate(for: weekly, now: Self.zaiNow.addingTimeInterval(86_400 * 2)) != nil)
  }

  @Test func zaiPrefersCountsOverTheRoundedPercentage() async throws {
    let snapshot = try await self.zai(Self.zaiCreditQuota).fetch()
    #expect(snapshot.planName == "GLM Coding Lite")
    #expect(snapshot.windows.map(\.usedPercent) == [5, 10])
    #expect(snapshot.details.contains(UsageDetail("5-hour credits", "\(UsageDetailFormat.number(100)) of \(UsageDetailFormat.number(2000)) used")))
    #expect(snapshot.details.contains(UsageDetail("Weekly credits", "\(UsageDetailFormat.number(1000)) of \(UsageDetailFormat.number(10000)) used")))
  }

  @Test func zaiDropsAnImpossibleFiveHourResetButKeepsTheReading() throws {
    let body = #"""
      {"code":200,"success":true,"data":{"limits":[
        {"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":40,"nextResetTime":1785850000000}]}}
      """#
    let snapshot = try ZaiProvider.decode(Data(body.utf8), now: Self.zaiNow)
    #expect(snapshot.windows.first?.usedPercent == 40)
    #expect(snapshot.windows.first?.resetsAt == nil)
  }

  @Test func zaiKeepsAReadingWithAnUnfamiliarPeriodButClaimsNoPace() throws {
    let body = #"""
      {"code":200,"success":true,"data":{"limits":[
        {"type":"TOKENS_LIMIT","unit":42,"number":5,"percentage":12}]}}
      """#
    let snapshot = try ZaiProvider.decode(Data(body.utf8), now: Self.zaiNow)
    #expect(snapshot.windows.first?.usedPercent == 12)
    #expect(snapshot.windows.first?.windowMinutes == nil)
    #expect(snapshot.windows.first?.label == "Coding limit")
  }

  @Test func zaiSendsTheRawKeyOnlyToItsOwnHost() async throws {
    let sent = Sent()
    _ = try await self.zai(Self.zaiTokenQuota, recording: sent).fetch()
    let request = try #require(sent.requests.first)
    #expect(sent.requests.count == 1)
    #expect(request.httpMethod == "GET")
    #expect(request.url?.absoluteString == "https://api.z.ai/api/monitor/usage/quota/limit")
    #expect(request.value(forHTTPHeaderField: "Authorization") == Self.zaiKey)
    #expect(request.url?.query == nil)
  }

  @Test func zaiRejectedKeysNeedReconnection() async throws {
    // Z.ai answers a bad key with HTTP 200 and an error code in the body
    // (observed live: code 401 and code 1001).
    for body in [
      #"{"code":401,"msg":"token expired or incorrect","success":false}"#,
      #"{"code":1001,"msg":"Authentication parameter not received in Header","success":false}"#,
    ] {
      let error = await #expect(throws: UsageProviderError.self) {
        try await self.zai(body).fetch()
      }
      #expect(error?.requiresConnection == true)
      if case .unauthorized = error {} else { Issue.record("expected unauthorized, got \(String(describing: error))") }
    }
    for status in [401, 403] {
      let error = await #expect(throws: UsageProviderError.self) {
        try await self.zai(status: status, "{}").fetch()
      }
      if case .unauthorized = error {} else { Issue.record("HTTP \(status) should be unauthorized") }
    }
    let limited = await #expect(throws: UsageProviderError.self) {
      try await self.zai(status: 429, "{}").fetch()
    }
    if case .rateLimited = limited {} else { Issue.record("HTTP 429 should be rate limited") }
  }

  @Test func zaiNeverTurnsAnUnknownShapeIntoZeroPercent() async throws {
    for body in [
      #"{"code":200,"success":true,"data":{}}"#,
      #"{"code":200,"success":true}"#,
      #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3}]}}"#,
      #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":"lots"}]}}"#,
      #"[]"#, "not json",
    ] {
      let error = await #expect(throws: UsageProviderError.self) {
        try await self.zai(body).fetch()
      }
      if case .invalidResponse = error {} else { Issue.record("\(body) should be invalidResponse, got \(String(describing: error))") }
    }
    // A valid account without a coding plan has nothing to meter; it is
    // reported as unavailable, not as an empty 0% plan.
    for body in [
      #"{"code":200,"success":true,"data":{"limits":[]}}"#,
      #"{"code":200,"success":true,"data":{"limits":[{"type":"TIME_LIMIT","unit":5,"number":1,"percentage":3}]}}"#,
    ] {
      let error = await #expect(throws: UsageProviderError.self) {
        try await self.zai(body).fetch()
      }
      if case .unavailable = error {} else { Issue.record("\(body) should be unavailable") }
    }
  }

  // MARK: Kimi

  /// 2026-01-06T12:00:00Z, before every reset in the CodexBar sample.
  private static let kimiNow = Date(timeIntervalSince1970: 1_767_700_800)
  private static let kimiKey = "sk-kimi-KimiSecretValue0123456789"

  /// CodexBar `docs/kimi.md`, Kimi Code API key response.
  private static let kimiCounts = #"""
    {
      "usage": {"limit": "2048", "used": "214", "remaining": "1834",
        "resetTime": "2026-01-09T15:23:13.716839300Z"},
      "limits": [{
        "window": {"duration": 300, "timeUnit": "TIME_UNIT_MINUTE"},
        "detail": {"limit": "200", "used": "139", "remaining": "61",
          "resetTime": "2026-01-06T13:33:02.717479433Z"}
      }],
      "user": {"membership": {"level": "LEVEL_BASIC"}}
    }
    """#

  /// CodexBar `KimiRatioPoolTests`, managed `usages` ratio pools.
  private static let kimiRatios = #"""
    {"usages": {
      "limit_5h": {"used_ratio": 0.625, "reset_time": "2026-01-06T15:00:00Z"},
      "limit_7d": {"used_ratio": 0.125, "reset_time": "2026-01-10T00:00:00Z"},
      "limit_month_total": {"used_ratio": 0.0056, "reset_time": "2026-02-01T00:00:00Z"}
    }}
    """#

  private func kimi(
    status: Int = 200, _ body: String, recording sent: Sent = Sent(),
    handler: APIKeyPlanTransport.RequestHandler? = nil
  ) -> KimiProvider {
    KimiProvider(
      apiKey: Self.kimiKey,
      requestHandler: handler ?? Self.handler(status: status, body, recording: sent),
      now: { Self.kimiNow })
  }

  @Test func kimiReadsTheCountShape() async throws {
    let snapshot = try await self.kimi(Self.kimiCounts).fetch()
    #expect(snapshot.provider == .kimi)
    #expect(snapshot.planName == "Moderato")
    #expect(snapshot.windows.map(\.label) == ["5 hours", "Weekly"])
    let fiveHour = try #require(snapshot.windows.first)
    #expect(fiveHour.usedPercent == 69.5)
    #expect(fiveHour.windowMinutes == 300)
    // Nanosecond fractions are read to the millisecond.
    let fiveHourReset = try #require(fiveHour.resetsAt)
    #expect(abs(fiveHourReset.timeIntervalSince(
      Date(timeIntervalSince1970: 1_767_706_382.717))) < 0.01)
    let weekly = try #require(snapshot.windows.last)
    #expect(abs(weekly.usedPercent - 214.0 / 2048.0 * 100) < 0.0001)
    #expect(weekly.windowMinutes == 10_080)
    #expect(weekly.resetsAt != nil)
    #expect(snapshot.details.contains(UsageDetail("Weekly requests", "\(UsageDetailFormat.number(214)) of \(UsageDetailFormat.number(2048)) used")))
    #expect(snapshot.details.contains(UsageDetail("5-hour requests", "\(UsageDetailFormat.number(139)) of \(UsageDetailFormat.number(200)) used")))
  }

  @Test func kimiReadsTheRatioPoolShape() async throws {
    let snapshot = try await self.kimi(Self.kimiRatios).fetch()
    #expect(snapshot.windows.map(\.label) == ["5 hours", "Weekly", "Monthly total"])
    #expect(zip(snapshot.windows.map(\.usedPercent), [62.5, 12.5, 0.56]).allSatisfy { abs($0 - $1) < 0.0001 })
    #expect(snapshot.windows.map(\.windowMinutes) == [300, 10_080, nil])
    #expect(snapshot.windows[1].resetsAt == UsageDateParser.iso8601("2026-01-10T00:00:00Z"))
  }

  @Test func kimiRatioPoolsWinOverCountsForTheSameWindow() throws {
    let body = #"""
      {"usages": {"limit_5h": {"used_ratio": 0.1}},
       "usage": {"limit": "100", "used": "50"},
       "limits": [{"window": {"duration": 5, "timeUnit": "TIME_UNIT_HOUR"},
                   "detail": {"limit": "200", "used": "190"}}]}
      """#
    let snapshot = try KimiProvider.decode(Data(body.utf8), now: Self.kimiNow)
    #expect(snapshot.windows.map(\.id) == ["limit_5h", "weekly"])
    #expect(snapshot.windows.map(\.usedPercent) == [10, 50])
  }

  @Test func kimiSendsABearerKeyOnlyToItsOwnHost() async throws {
    let sent = Sent()
    _ = try await self.kimi(Self.kimiCounts, recording: sent).fetch()
    let request = try #require(sent.requests.first)
    #expect(sent.requests.count == 1)
    #expect(request.url?.absoluteString == "https://api.kimi.com/coding/v1/usages")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Self.kimiKey)")
  }

  @Test func kimiHTTPFailuresMapToRecoveryActions() async throws {
    for status in [401, 403] {
      let error = await #expect(throws: UsageProviderError.self) {
        try await self.kimi(status: status, #"{"error":{"type":"invalid_authentication_error"}}"#).fetch()
      }
      #expect(error?.requiresConnection == true)
    }
    let limited = await #expect(throws: UsageProviderError.self) {
      try await self.kimi(status: 429, "{}").fetch()
    }
    if case .rateLimited = limited {} else { Issue.record("HTTP 429 should be rate limited") }
  }

  @Test func kimiNeverTurnsAnUnknownShapeIntoZeroPercent() async throws {
    for body in [
      "{}", #"{"usages":{}}"#, #"{"usages":{"limit_5h":{}}}"#,
      // A limit without used or remaining is not evidence of 0% used.
      #"{"usage":{"limit":"100"}}"#,
      #"{"usage":{"limit":"0","used":"0"}}"#,
      #"{"limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_FORTNIGHT"},"detail":{"limit":"10","used":"1"}}]}"#,
      "[]", "<html>",
    ] {
      let error = await #expect(throws: UsageProviderError.self) {
        try await self.kimi(body).fetch()
      }
      if case .invalidResponse = error {} else { Issue.record("\(body) should be invalidResponse") }
    }
  }

  // MARK: Beta providers

  @Test func exactlyTheUnverifiedPlanProvidersAreBeta() {
    let beta = Set(ProviderID.allCases.filter { ProviderDescriptor.forProvider($0).isBeta })
    #expect(beta == [.zai, .kimi, .gemini])
  }

  @Test func anUnrecognizedBetaResponseAsksForAReportWithoutLeakingAnything() async throws {
    let issues = "https://github.com/pocarles/reserve/issues"
    #expect(BetaProviderReport.issuesURL.absoluteString == issues)
    #expect(BetaProviderReport.unrecognizedMessage(for: .zai)
      == "Reserve didn’t recognize Z.ai’s usage format. Z.ai support is in beta. "
      + "Please report this at \(issues)")

    func check(_ error: Error, provider: ProviderID, secrets: [String]) {
      let text = error.localizedDescription
      #expect(error as? UsageProviderError == BetaProviderReport.unrecognizedResponse(provider))
      #expect(text == BetaProviderReport.unrecognizedMessage(for: provider))
      #expect(text.contains(issues))
      #expect(text.contains("beta"))
      #expect(!text.contains("Invalid provider response"))
      for secret in secrets { #expect(!text.contains(secret), "\(text) leaked \(secret)") }
    }

    for body in [
      #"{"code":200,"success":true,"data":{"echo":"\#(Self.zaiKey)","email":"person@example.com"}}"#,
      #"{"code":200,"success":true,"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":"\#(Self.zaiKey)"}]}}"#,
      "<html>person@example.com \(Self.zaiKey)</html>",
    ] {
      do {
        _ = try await self.zai(body).fetch()
        Issue.record("expected a failure for \(body)")
      } catch {
        check(error, provider: .zai, secrets: [Self.zaiKey, "ZaiSecret", "person@example.com", "echo", "html"])
      }
    }
    for body in [
      #"{"user":"person@example.com","token":"\#(Self.kimiKey)"}"#,
      "<html>\(Self.kimiKey)</html>",
    ] {
      do {
        _ = try await self.kimi(body).fetch()
        Issue.record("expected a failure for \(body)")
      } catch {
        check(error, provider: .kimi, secrets: [Self.kimiKey, "KimiSecret", "person@example.com", "html"])
      }
    }
    for json in [
      #"{"account":"person@example.com","groups":[1]}"#,
      #"{"groups":[{"name":"person@example.com","buckets":[{"window":"weekly","remaining_fraction":7}]}]}"#,
    ] {
      do {
        _ = try GeminiProvider.decode(Data(json.utf8))
        Issue.record("expected a failure for \(json)")
      } catch {
        check(error, provider: .gemini, secrets: ["person@example.com", "groups", "buckets"])
      }
    }
  }

  @Test func otherInvalidResponsesKeepTheirGenericPrefix() {
    #expect(UsageProviderError.invalidResponse("missing HTTP status").localizedDescription
      == "Invalid provider response: missing HTTP status")
  }

  // MARK: Shared safety

  @Test func theKeyNeverAppearsInAnErrorDescription() async throws {
    struct Leaky: LocalizedError {
      let key: String
      var errorDescription: String? { "request with Authorization: \(self.key) failed" }
    }
    let kimiFailures: [APIKeyPlanTransport.RequestHandler] = [
      { _ in throw Leaky(key: Self.kimiKey) },
      Self.handler(status: 500, "echo \(Self.kimiKey)"),
      Self.handler(status: 401, "bad key \(Self.kimiKey)"),
      Self.handler(status: 200, #"{"error":"\#(Self.kimiKey)"}"#),
    ]
    for handler in kimiFailures {
      do {
        _ = try await self.kimi("", handler: handler).fetch()
        Issue.record("expected a failure")
      } catch {
        #expect(!error.localizedDescription.contains(Self.kimiKey))
        #expect(!error.localizedDescription.contains("KimiSecret"))
      }
    }
    for (status, body) in [
      (500, "echo \(Self.zaiKey)"),
      (200, #"{"code":1002,"msg":"invalid \#(Self.zaiKey)","success":false}"#),
      (200, #"{"code":500,"msg":"\#(Self.zaiKey)","success":false}"#),
    ] {
      do {
        _ = try await self.zai(status: status, body).fetch()
        Issue.record("expected a failure")
      } catch {
        #expect(!error.localizedDescription.contains(Self.zaiKey))
        #expect(!error.localizedDescription.contains("ZaiSecret"))
      }
    }
  }

  @Test func aResponseFromAnotherHostIsRefused() async throws {
    let error = await #expect(throws: UsageProviderError.self) {
      try await self.zai(
        Self.zaiTokenQuota, responseURL: URL(string: "https://evil.example/api/monitor/usage/quota/limit")!
      ).fetch()
    }
    if case .invalidResponse = error {} else { Issue.record("a foreign response host must be refused") }
  }

  @Test func theTransportRefusesToSendTheKeyElsewhere() async throws {
    let sent = Sent()
    let transport = APIKeyPlanTransport(
      provider: .kimi, host: "api.kimi.com",
      requestHandler: Self.handler(Self.kimiCounts, recording: sent))
    // A path cannot change the host: URLComponents keeps it on api.kimi.com.
    _ = try await transport.get(path: "/coding/v1/usages", authorization: "Bearer x")
    #expect(sent.requests.allSatisfy { $0.url?.host == "api.kimi.com" && $0.url?.scheme == "https" })
  }

  @Test func pastedKeysAreNormalizedAndBounded() throws {
    #expect(try PlanKeyKeychain.normalized("  \(Self.kimiKey)\n", for: .kimi) == Self.kimiKey)
    #expect(throws: UsageProviderError.self) { try PlanKeyKeychain.normalized("short", for: .zai) }
    // Plan keys and API-account keys live under different Keychain services,
    // so Kimi's plan key can never overwrite the Moonshot API key.
    #expect(PlanKeyKeychain.service != APIConsumptionKeychain.service)
    #expect(PlanKeyKeychain.account(for: .kimi) != APIConsumptionKeychain.account(for: .moonshot))
  }

  // MARK: Descriptors and persistence

  @Test func apiKeyProvidersHaveNoHelperLoginOrLocalHistory() async throws {
    for provider in [ProviderID.zai, .kimi] {
      let descriptor = ProviderDescriptor.forProvider(provider)
      #expect(descriptor.usesAPIKey)
      #expect(descriptor.helper == nil)
      #expect(ProviderHelperCatalog.definition(for: provider) == nil)
      #expect(descriptor.installationStrategy == .none)
      #expect(!descriptor.supportsAutomaticHelperInstallation)
      #expect(descriptor.loginArguments.isEmpty)
      #expect(descriptor.trustedLoginHosts.isEmpty)
      #expect(descriptor.capabilities == [.liveAllowance])
      #expect(!descriptor.capabilities.contains(.localHistory))
      let connection = try #require(descriptor.apiKeyConnection)
      #expect(connection.keySettingsURL.scheme == "https")
      #expect(!connection.keyHint.isEmpty)
      // The installer refuses before any download or BinaryLocator lookup.
      await #expect(throws: ProviderHelperInstallerError.self) {
        try await ProviderHelperInstaller().install(provider)
      }
      await #expect(throws: ProviderHelperInstallerError.self) {
        try await ProviderHelperInstaller().update(provider)
      }
    }
    #expect(ProviderDescriptor.forProvider(.zai).apiKeyConnection?.endpointHost == "api.z.ai")
    #expect(ProviderDescriptor.forProvider(.kimi).apiKeyConnection?.endpointHost == "api.kimi.com")
    // Existing providers keep their helpers.
    for provider in [ProviderID.openAI, .anthropic, .grok, .cursor, .copilot, .gemini] {
      #expect(!ProviderDescriptor.forProvider(provider).usesAPIKey)
      #expect(ProviderDescriptor.forProvider(provider).helper != nil)
    }
    // New cases are appended, so earlier persisted raw values are unchanged.
    #expect(ProviderID.allCases.map(\.rawValue)
      == ["openAI", "anthropic", "grok", "cursor", "copilot", "zai", "kimi", "gemini"])
  }

  @Test func statusChecksSkipAProviderWithoutAnOfficialPage() async {
    #expect(ProviderDescriptor.forProvider(.zai).statusURL == nil)
    #expect(ProviderDescriptor.forProvider(.zai).statusFeedURL == nil)
    #expect(await ServiceStatusClient().fetch(.zai) == nil)
    #expect(ProviderDescriptor.forProvider(.kimi).statusFeedURL?.absoluteString
      == "https://status.moonshot.cn/api/v2/summary.json")
  }

  @Test func snapshotCachesRoundTripTheNewProvidersAndStillReadOldOnes() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-plan-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("snapshots.json")
    let cache = SnapshotCache(fileURL: file)
    let zai = try ZaiProvider.decode(Data(Self.zaiTokenQuota.utf8), now: Self.zaiNow)
    let kimi = try KimiProvider.decode(Data(Self.kimiCounts.utf8), now: Self.kimiNow)
    try await cache.save([.zai: zai, .kimi: kimi])
    let loaded = await cache.load()
    #expect(loaded[.zai]?.windows == zai.windows)
    // The cache stores whole-second dates; Kimi's resets carry milliseconds.
    let cachedKimi = try #require(loaded[.kimi])
    #expect(cachedKimi.windows.map(\.label) == kimi.windows.map(\.label))
    #expect(cachedKimi.windows.map(\.usedPercent) == kimi.windows.map(\.usedPercent))
    #expect(zip(cachedKimi.windows, kimi.windows).allSatisfy { cached, fresh in
      guard let lhs = cached.resetsAt, let rhs = fresh.resetsAt else { return false }
      return abs(lhs.timeIntervalSince(rhs)) < 1
    })
    #expect(loaded[.kimi]?.planName == "Moderato")
    // The key is never part of a cached snapshot.
    let text = try String(contentsOf: file, encoding: .utf8)
    #expect(!text.contains(Self.zaiKey) && !text.contains(Self.kimiKey))

    // A cache written before these providers existed still loads.
    let old = #"""
      [{"provider":"openAI","windows":[{"id":"weekly","label":"Weekly","usedPercent":10}],
        "fetchedAt":"2026-01-01T00:00:00Z","source":"Codex app server","observationTimeKnown":true,
        "checkedAt":"2026-01-01T00:00:00Z"}]
      """#
    try Data(old.utf8).write(to: file)
    let legacy = await cache.load()
    #expect(legacy.keys.sorted { $0.rawValue < $1.rawValue } == [.openAI])
  }
}
