import Foundation
import Testing
@testable import ReserveCore

private func XCTAssertEqual<T: Equatable>(_ lhs: T, _ rhs: T) {
  #expect(lhs == rhs)
}

private func XCTAssertTrue(_ value: Bool) { #expect(value) }
private func XCTAssertFalse(_ value: Bool) { #expect(!value) }
private func XCTAssertNil<T>(_ value: T?) { #expect(value == nil) }
private func XCTAssertGreaterThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T) {
  #expect(lhs >= rhs)
}
private func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: T, _ rhs: T) {
  #expect(lhs <= rhs)
}
private func XCTAssertLessThan<T: Comparable>(_ lhs: T, _ rhs: T) {
  #expect(lhs < rhs)
}
private struct TestFailure: Error, CustomStringConvertible {
  let description: String
}
private func XCTFail(_ message: String) { Issue.record(TestFailure(description: message)) }

private func cleanTestDefaults(_ defaults: UserDefaults, suiteName: String) {
  defaults.removePersistentDomain(forName: suiteName)
  let plist = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Preferences/\(suiteName).plist")
  try? FileManager.default.removeItem(at: plist)
}

private func freshTestDefaults(suiteName: String) -> UserDefaults {
  let defaults = UserDefaults(suiteName: suiteName)!
  cleanTestDefaults(defaults, suiteName: suiteName)
  return defaults
}

private func cleanTestDefaults(suiteName: String) {
  guard let defaults = UserDefaults(suiteName: suiteName) else { return }
  cleanTestDefaults(defaults, suiteName: suiteName)
}

@Suite
struct ReserveCoreTests {
  @Test
  func testProviderHelperCatalogUsesOnlyFixedOfficialHTTPSInstallers() throws {
    let definitions = ProviderID.allCases.map(ProviderHelperCatalog.definition)
    XCTAssertEqual(definitions.map(\.provider), ProviderID.allCases)
    XCTAssertEqual(
      Set(definitions.compactMap(\.installerURL.host)),
      Set(["chatgpt.com", "claude.ai", "x.ai", "cursor.com"]))
    XCTAssertTrue(definitions.allSatisfy { definition in
      definition.installerURL.scheme == "https"
        && !definition.executable.isEmpty
    })
    for provider in ProviderID.allCases {
      XCTAssertEqual(
        ProviderHelperCatalog.definition(for: provider).updateArguments,
        ["update"])
    }

    try ProviderHelperInstaller.validateInstallerFormat(
      Data("#!/bin/bash\nset -e\necho setup\n".utf8))
    for invalid in [
      Data(),
      Data("<html>not an installer</html>".utf8),
      Data([0x23, 0x21, 0x00, 0x62, 0x61, 0x73, 0x68]),
    ] {
      do {
        try ProviderHelperInstaller.validateInstallerFormat(invalid)
        XCTFail("an invalid provider installer was accepted")
      } catch is ProviderHelperInstallerError {
        // Expected.
      }
    }
  }

  @Test
  func testProviderUpdateFailureKeepsUpdateRecoveryDistinctFromSignIn() {
    let error = UsageProviderError.updateRequired("Grok needs an update.")
    XCTAssertEqual(error.localizedDescription, "Grok needs an update.")
    XCTAssertFalse(error.requiresConnection)
  }

  @Test
  func testOpenAIUsesApprovalFlagSupportedByCurrentCodexHelpers() {
    XCTAssertEqual(
      OpenAIProvider.appServerArguments,
      ["-s", "read-only", "-a", "never", "app-server"])
  }

  @Test
  func testCursorIsFourthProviderAndStartsWithDistinctPools() throws {
    XCTAssertEqual(ProviderID.allCases.count, 4)
    XCTAssertEqual(ProviderID.cursor.displayName, "Cursor")
    let data = Data(
      #"{"billingCycleStart":"1787616000000","billingCycleEnd":"1790294400000","planUsage":{"autoSpend":1800,"autoLimit":4000,"apiPercentUsed":72.5}}"#.utf8)
    let response = try JSONDecoder().decode(CursorCurrentPeriodUsageResponse.self, from: data)
    let reset = Date(timeIntervalSince1970: 1_790_294_400)
    let windows = try CursorProvider.windows(
      usage: response.planUsage, resetsAt: reset, windowMinutes: 44_640)

    XCTAssertEqual(windows.map(\.id), ["cursor-models", "other-models"])
    XCTAssertEqual(windows.map(\.label), ["Cursor Models", "Other Models"])
    XCTAssertEqual(windows[0].usedPercent, 45)
    XCTAssertEqual(windows[1].usedPercent, 72.5)
    XCTAssertEqual(windows[0].resetsAt, reset)
    XCTAssertEqual(windows[1].resetsAt, reset)
  }

  @Test
  func testCursorPlanNamesPricesAndMalformedValues() throws {
    XCTAssertEqual(CursorPlanFormatter.plan(from: "pro_plus"), "Pro Plus")
    XCTAssertEqual(CursorPlanFormatter.plan(from: "ultra"), "Ultra")
    XCTAssertEqual(CursorPlanFormatter.plan(from: "free"), "Hobby")
    XCTAssertEqual(
      CursorPlanFormatter.plan(from: "pro", monthlyPriceMinorUnits: 6_000), "Pro Plus")
    XCTAssertEqual(CursorProvider.monthlyPriceMinorUnits("$60 / month"), 6_000)
    XCTAssertEqual(CursorProvider.monthlyPriceMinorUnits("200.00"), 20_000)
    XCTAssertNil(CursorProvider.monthlyPriceMinorUnits("custom"))

    let malformed = Data(#"{"autoPercentUsed":"NaN"}"#.utf8)
    do {
      _ = try JSONDecoder().decode(CursorPlanUsage.self, from: malformed)
      XCTFail("malformed Cursor percentage was accepted")
    } catch {
      // Expected.
    }
  }

  @Test
  func testCursorOnDemandSpendPreservesCapDisabledAndUnlimited() throws {
    func current(_ json: String) throws -> CursorCurrentPeriodUsageResponse {
      try JSONDecoder().decode(CursorCurrentPeriodUsageResponse.self, from: Data(json.utf8))
    }
    func hard(_ json: String) throws -> CursorHardLimitResponse {
      try JSONDecoder().decode(CursorHardLimitResponse.self, from: Data(json.utf8))
    }

    let capped = CursorProvider.includedSpend(
      current: try current(
        #"{"spendLimitUsage":{"individualLimit":5000,"individualUsed":1250,"individualRemaining":3750,"limitType":"individual"}}"#),
      hardLimit: try hard(#"{"hardLimit":50}"#))
    XCTAssertEqual(capped?.limitState, .capped)
    XCTAssertEqual(capped?.usedMinorUnits, 1_250)
    XCTAssertEqual(capped?.limitMinorUnits, 5_000)
    XCTAssertEqual(capped?.remainingMinorUnits, 3_750)

    let disabled = CursorProvider.includedSpend(
      current: try current(#"{"spendLimitUsage":{"individualUsed":0}}"#),
      hardLimit: try hard(#"{"noUsageBasedAllowed":true}"#))
    XCTAssertEqual(disabled?.limitState, .disabled)
    XCTAssertEqual(disabled?.remainingMinorUnits, 0)

    let unlimited = CursorProvider.includedSpend(
      current: try current(
        #"{"spendLimitUsage":{"individualUsed":900,"limitType":"unlimited"}}"#),
      hardLimit: try hard(#"{"noUsageBasedAllowed":false}"#))
    XCTAssertEqual(unlimited?.limitState, .unlimited)
    XCTAssertNil(unlimited?.remainingMinorUnits)

    let sentinelUnlimited = CursorProvider.includedSpend(
      current: try current(#"{"spendLimitUsage":{"individualUsed":900}}"#),
      hardLimit: try hard(#"{"hardLimit":2147483647}"#))
    XCTAssertEqual(sentinelUnlimited?.limitState, .unlimited)

    let zeroLimit = CursorProvider.includedSpend(
      current: try current(#"{"spendLimitUsage":{"individualUsed":0}}"#),
      hardLimit: try hard(#"{"hardLimit":0}"#))
    XCTAssertEqual(zeroLimit?.limitState, .disabled)
  }

  @Test
  func testCursorStatusOutputIsStrictAndContainsNoCredential() throws {
    try CursorProvider.validateStatusOutput(
      #"{"status":"authenticated","isAuthenticated":true,"hasAccessToken":true,"hasRefreshToken":true,"userInfo":{}}"#)
    for invalid in ["", "signed in", "[]", "{}", #"{"isAuthenticated":false}"#,
      #"{"isAuthenticated":true,"hasAccessToken":false}"#]
    {
      do {
        try CursorProvider.validateStatusOutput(invalid)
        XCTFail("invalid cursor-agent status output was accepted")
      } catch {
        // Expected.
      }
    }
  }

  @Test
  func testCursorKeychainAccessIsOptInAndScheduledRefreshCannotPrompt() async throws {
    let denied = CursorProvider(
      environment: [:], allowKeychainRead: false,
      keychainItemExists: { true },
      statusRunner: { _, _, _ in throw TestFailure(description: "status ran before consent") },
      credentialLoader: { _ in throw TestFailure(description: "Keychain read before consent") },
      requestHandler: { _ in throw TestFailure(description: "network ran before consent") })
    do {
      _ = try await denied.fetch()
      XCTFail("Cursor Keychain access proceeded without consent")
    } catch UsageProviderError.keychainConsentRequired(let provider) {
      XCTAssertEqual(provider, .cursor)
    }

    let scheduled = CursorProvider(
      environment: [:], allowKeychainRead: true, allowKeychainInteraction: false,
      agentLocator: { _ in "/usr/bin/true" },
      statusRunner: { executable, arguments, _ in
        XCTAssertEqual(executable, "/usr/bin/true")
        XCTAssertEqual(arguments, ["status", "--format", "json"])
        return #"{"isAuthenticated":true,"hasAccessToken":true}"#
      },
      credentialLoader: { allowInteraction in
        XCTAssertFalse(allowInteraction)
        return CursorCredential(accessToken: "scheduled-test-token")
      },
      requestHandler: { request in
        XCTAssertEqual(
          request.value(forHTTPHeaderField: "Authorization"),
          "Bearer scheduled-test-token")
        let payload: String
        switch request.url?.lastPathComponent {
        case "GetCurrentPeriodUsage":
          payload = #"{"billingCycleStart":"1787616000000","billingCycleEnd":"1790294400000","planUsage":{"autoSpend":1800,"autoLimit":4000,"apiPercentUsed":72.5},"spendLimitUsage":{"individualLimit":5000,"individualUsed":1250,"limitType":"individual"},"enabled":true}"#
        case "GetPlanInfo":
          payload = #"{"planInfo":{"planName":"pro_plus","price":"$60 / month","billingCycleEnd":"1790294400000"}}"#
        case "GetHardLimit":
          payload = #"{"hardLimit":50}"#
        case "GetMe":
          payload = #"{"userId":7}"#
        case "GetTeams":
          payload = #"{"teams":[]}"#
        default:
          throw TestFailure(description: "unexpected Cursor RPC")
        }
        return (
          Data(payload.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
      })
    let snapshot = try await scheduled.fetch()
    XCTAssertEqual(snapshot.provider, .cursor)
    XCTAssertEqual(snapshot.planName, "Pro Plus")
    XCTAssertEqual(snapshot.monthlyPriceMinorUnits, 6_000)
    XCTAssertEqual(snapshot.windows.count, 2)
    XCTAssertTrue(snapshot.detailedUsageUnavailable)
  }

  @Test
  func testCursorCredentialIsReadOncePerProcessAndClearsOnDemand() async throws {
    let session = CursorCredentialSession()
    let statusRuns = AsyncCounter()
    let credentialReads = AsyncCounter()
    let provider = CursorProvider(
      environment: [:], allowKeychainRead: true,
      agentLocator: { _ in "/usr/bin/true" },
      statusRunner: { _, arguments, _ in
        XCTAssertEqual(arguments, ["status", "--format", "json"])
        await statusRuns.increment()
        return #"{"isAuthenticated":true,"hasAccessToken":true}"#
      },
      credentialLoader: { _ in
        await credentialReads.increment()
        return CursorCredential(accessToken: "memory-only-test-token")
      },
      credentialSession: session,
      requestHandler: { request in
        let payload: String
        switch request.url?.lastPathComponent {
        case "GetCurrentPeriodUsage":
          payload = #"{"billingCycleStart":"1787616000000","billingCycleEnd":"1790294400000","planUsage":{"autoPercentUsed":10,"apiPercentUsed":20}}"#
        case "GetPlanInfo":
          payload = #"{"planInfo":{"planName":"pro","billingCycleEnd":"1790294400000"}}"#
        case "GetHardLimit":
          payload = #"{"hardLimit":0,"noUsageBasedAllowed":true}"#
        case "GetMe":
          payload = #"{"userId":7}"#
        case "GetTeams":
          payload = #"{"teams":[]}"#
        default:
          throw TestFailure(description: "unexpected Cursor RPC")
        }
        return (
          Data(payload.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!)
      })

    _ = try await provider.fetch()
    _ = try await provider.fetch()
    XCTAssertEqual(await statusRuns.current(), 1)
    XCTAssertEqual(await credentialReads.current(), 1)

    await session.clear()
    _ = try await provider.fetch()
    XCTAssertEqual(await statusRuns.current(), 2)
    XCTAssertEqual(await credentialReads.current(), 2)
  }

  @Test
  func testCursorUnauthorizedResponseClearsMemoryCredential() async throws {
    let session = CursorCredentialSession()
    _ = try await session.credential {
      CursorCredential(accessToken: "expired-memory-token")
    }
    let provider = CursorProvider(
      environment: [:], allowKeychainRead: true,
      statusRunner: { _, _, _ in
        throw TestFailure(description: "status reran while a credential was cached")
      },
      credentialLoader: { _ in
        throw TestFailure(description: "Keychain was read while a credential was cached")
      },
      credentialSession: session,
      requestHandler: { request in
        (
          Data(#"{"code":"unauthenticated"}"#.utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: 401, httpVersion: nil,
            headerFields: nil)!)
      })

    do {
      _ = try await provider.fetch()
      XCTFail("Cursor accepted an expired cached credential")
    } catch UsageProviderError.unauthorized {
      // Expected. The next access must load a fresh credential.
    }

    let reloads = AsyncCounter()
    let refreshed = try await session.credential {
      await reloads.increment()
      return CursorCredential(accessToken: "refreshed-memory-token")
    }
    XCTAssertEqual(refreshed.accessToken, "refreshed-memory-token")
    XCTAssertEqual(await reloads.current(), 1)
  }

  @Test
  func testSingleInstanceLockRejectsConcurrentOwnerAndRecovers() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let lockURL = root.url.appendingPathComponent("Reserve.instance.lock")

    var first: SingleInstanceLock? = try SingleInstanceLock.acquire(at: lockURL)
    #expect(first != nil)
    let second = try SingleInstanceLock.acquire(at: lockURL)
    #expect(second == nil)

    first = nil
    let replacement = try SingleInstanceLock.acquire(at: lockURL)
    #expect(replacement != nil)
  }

  @Test
  func testCursorIndividualUsageSelectsOnlyOneBilledSingleSeatTeam() throws {
    let response = try JSONDecoder().decode(
      CursorTeamsResponse.self,
      from: Data(
        #"{"teams":[{"id":42,"seats":1,"purchasedSeats":1,"hasBilling":true,"isEnterprise":false,"isDirectMember":true,"subscriptionStatus":"active"},{"id":99,"seats":20,"hasBilling":true,"isEnterprise":false,"isDirectMember":true}]}"#.utf8))
    XCTAssertEqual(response.individualTeamID, 42)

    let ambiguous = try JSONDecoder().decode(
      CursorTeamsResponse.self,
      from: Data(
        #"{"teams":[{"id":1,"seats":1,"hasBilling":true},{"id":2,"seats":1,"hasBilling":true}]}"#.utf8))
    XCTAssertNil(ambiguous.individualTeamID)

    let enterprise = try JSONDecoder().decode(
      CursorTeamsResponse.self,
      from: Data(#"{"teams":[{"id":7,"seats":1,"isEnterprise":true}]}"#.utf8))
    XCTAssertNil(enterprise.individualTeamID)
  }

  @Test
  func testCursorMissingAllowanceFieldsUseLimitsOnlyFailure() async throws {
    let provider = CursorProvider(
      environment: [:], allowKeychainRead: true,
      statusRunner: { _, _, _ in #"{"isAuthenticated":true,"hasAccessToken":true}"# },
      credentialLoader: { _ in CursorCredential(accessToken: "test") },
      requestHandler: { request in
        let payload = request.url?.lastPathComponent == "GetPlanInfo" ? "{}" : "{}"
        return (
          Data(payload.utf8),
          HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
      })
    do {
      _ = try await provider.fetch()
      XCTFail("Cursor accepted a response without either usage pool")
    } catch UsageProviderError.unavailable {
      // Expected. Missing optional fields do not crash or invent an allowance.
    }
  }

  @Test
  func testCursorRPCIsHTTPSAllowlistedAndMapsAuthenticationFailures() async throws {
    let ok = CursorRPCClient(accessToken: "test-only-secret") { request in
      XCTAssertEqual(request.url?.scheme, "https")
      XCTAssertEqual(request.url?.host, CursorProvider.serviceHost)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-only-secret")
      return (
        Data(#"{"planInfo":{"planName":"pro","price":"$20"}}"#.utf8),
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil,
          headerFields: ["Content-Type": "application/json"])!)
    }
    let plan: CursorPlanInfoResponse = try await ok.call(
      .planInfo, body: Data("{}".utf8))
    XCTAssertEqual(plan.planInfo?.planName, "pro")

    let unauthorized = CursorRPCClient(accessToken: "expired") { request in
      (
        Data(#"{"code":"unauthenticated"}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!)
    }
    do {
      let _: CursorPlanInfoResponse = try await unauthorized.call(
        .planInfo, body: Data("{}".utf8))
      XCTFail("unauthorized Cursor response was accepted")
    } catch UsageProviderError.unauthorized {
      // Expected.
    }
  }

  @Test
  func testCursorRPCRejectsOversizedPayloadsAndRateLimits() async throws {
    let oversized = CursorRPCClient(accessToken: "test") { request in
      (
        Data(repeating: 0x20, count: CursorProvider.maximumResponseBytes + 1),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      let _: CursorPlanInfoResponse = try await oversized.call(
        .planInfo, body: Data("{}".utf8))
      XCTFail("oversized Cursor response was accepted")
    } catch UsageProviderError.invalidResponse {
      // Expected.
    }

    let limited = CursorRPCClient(accessToken: "test") { request in
      (
        Data(),
        HTTPURLResponse(
          url: request.url!, statusCode: 429, httpVersion: nil,
          headerFields: ["Retry-After": "60"])!)
    }
    do {
      let _: CursorPlanInfoResponse = try await limited.call(
        .planInfo, body: Data("{}".utf8))
      XCTFail("rate-limited Cursor response was accepted")
    } catch UsageProviderError.rateLimited(let retryAt) {
      XCTAssertTrue(retryAt != nil)
    }
  }

  @Test
  func testCursorUsageEventsDeduplicateAndBuildDailyTotals() async throws {
    let timestamp = Int64(Date().timeIntervalSince1970 * 1_000)
    let client = CursorRPCClient(accessToken: "test") { request in
      let event = #"{"timestamp":"\#(timestamp)","model":"claude-4","conversationId":"c1","tokenUsage":{"inputTokens":100,"outputTokens":20,"cacheWriteTokens":5,"cacheReadTokens":50,"totalCents":1.25}}"#
      return (
        Data(#"{"totalUsageEventsCount":2,"usageEventsDisplay":[\#(event)]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let events = try await CursorProvider.events(
      client: client, teamID: 1, userID: 2,
      start: Date().addingTimeInterval(-86_400), end: Date().addingTimeInterval(1))
    XCTAssertEqual(events.count, 1)
    let series = CursorUsageAggregator.dailySeries(
      events: events, start: Calendar.current.startOfDay(for: Date()), now: Date())
    XCTAssertEqual(series.last?.tokens, 175)
  }

  @Test
  func testCursorAggregatedUsagePreservesTokenCategoriesModelsAndCost() throws {
    let response = try JSONDecoder().decode(
      CursorAggregatedUsageResponse.self,
      from: Data(
        #"{"aggregations":[{"modelIntent":"claude-4","inputTokens":"100","outputTokens":"20","cacheWriteTokens":"5","cacheReadTokens":"50","totalCents":125.5}],"totalInputTokens":"100","totalOutputTokens":"20","totalCacheWriteTokens":"5","totalCacheReadTokens":"50","totalCostCents":125.5}"#.utf8))
    XCTAssertEqual(response.totalInputTokens, 100)
    XCTAssertEqual(response.totalOutputTokens, 20)
    XCTAssertEqual(response.totalCacheWriteTokens, 5)
    XCTAssertEqual(response.totalCacheReadTokens, 50)
    XCTAssertEqual(response.totalTokens, 175)
    XCTAssertEqual(response.totalCostCents, 125.5)
    XCTAssertEqual(response.aggregations.first?.modelUsageCost.model, "claude-4")
    XCTAssertEqual(response.aggregations.first?.modelUsageCost.costUSD, 1.255)
  }

  @Test
  func testCursorUsagePaginationIsBounded() async throws {
    let client = CursorRPCClient(accessToken: "test") { request in
      let body = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as! [String: Any]
      let page = body["page"] as! Int
      let event = #"{"timestamp":"\#(1_780_000_000_000 + page)","model":"m","conversationId":"c\#(page)","tokenUsage":{"inputTokens":1}}"#
      return (
        Data(#"{"totalUsageEventsCount":21,"usageEventsDisplay":[\#(event)]}"#.utf8),
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await CursorProvider.events(
        client: client, teamID: 1, userID: 2,
        start: Date(timeIntervalSince1970: 1_779_000_000),
        end: Date(timeIntervalSince1970: 1_781_000_000))
      XCTFail("Cursor pagination exceeded its page bound")
    } catch is CursorDetailedUsageUnavailable {
      // Expected after exactly the configured maximum number of pages.
    }
  }

  @Test
  func testCursorUsageEventsWithoutExactCountUseLimitsOnlyFallback() async throws {
    let client = CursorRPCClient(accessToken: "test") { request in
      (
        Data(#"{"usageEventsDisplay":[{"timestamp":"1780000000000","model":"m","tokenUsage":{"inputTokens":1}}]}"#.utf8),
        HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }

    do {
      _ = try await CursorProvider.events(
        client: client, teamID: 1, userID: 1,
        start: Date(timeIntervalSince1970: 1_779_999_000),
        end: Date(timeIntervalSince1970: 1_780_001_000))
      XCTFail("Cursor accepted an event page without an exact total count")
    } catch is CursorDetailedUsageUnavailable {
      // Expected: incomplete account data must not be presented as exact usage.
    }
  }

  @Test
  func testOnlyAuthenticationErrorsRequireConnection() {
    XCTAssertTrue(UsageProviderError.credentialsNotFound("missing").requiresConnection)
    XCTAssertTrue(UsageProviderError.keychainConsentRequired(.anthropic).requiresConnection)
    XCTAssertTrue(UsageProviderError.unauthorized("expired").requiresConnection)
    XCTAssertFalse(UsageProviderError.rateLimited(retryAt: nil).requiresConnection)
    XCTAssertFalse(UsageProviderError.unavailable("offline").requiresConnection)
  }

  @Test
  func testGrokUnifiedWeeklyResetIgnoresMonthlyIncludedSpend() throws {
    let data = Data(
      #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-15T22:03:41Z","end":"2026-08-22T22:03:41Z"},"monthlyLimit":{"val":99900},"used":{"val":12345},"isUnifiedBillingUser":true}}"#.utf8)
    let billing = try JSONDecoder().decode(GrokBillingEnvelope.self, from: data)

    XCTAssertEqual(billing.config?.usedPercent, 0)
    XCTAssertEqual(billing.config?.includedSpend?.usedMinorUnits, 12_345)
    XCTAssertEqual(billing.config?.includedSpend?.limitMinorUnits, 99_900)
  }

  @Test
  func testDeficitAlertRequiresAPreviousSnapshot() {
    let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let current = UsageSnapshot(
      provider: .openAI,
      windows: [
        UsageWindow(
          id: "weekly", label: "Weekly", usedPercent: 80,
          windowMinutes: 7 * 24 * 60, resetsAt: now.addingTimeInterval(2 * 24 * 60 * 60))
      ],
      source: "test")

    XCTAssertTrue(
      SmartAlertDetector.deficitAlerts(previous: nil, current: current, now: now).isEmpty)
  }

  @Test
  func testGrokCredentialSelectionBreaksPreferenceTiesByAccountKey() {
    let future = "2033-05-18T03:33:20Z"
    let credentials = GrokCredentialLoader.select(
      entries: [
        "zeta": GrokCredentialEntry(key: "zeta-key", userID: "zeta-user", expiresAt: future),
        "alpha": GrokCredentialEntry(
          key: "alpha-key", userID: "alpha-user", expiresAt: future),
      ],
      now: Date(timeIntervalSince1970: 1_800_000_000))

    XCTAssertEqual(credentials?.key, "alpha-key")
    XCTAssertEqual(credentials?.userID, "alpha-user")
  }

  @Test
  func testClaudeCredentialDecoderRejectsExpiredLegacyFile() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expired = Data(
      #"{"claudeAiOauth":{"accessToken":"old-token","expiresAt":1799999999000}}"#.utf8)

    do {
      _ = try ClaudeCredentialLoader.decode(data: expired, source: "legacy file", now: now)
      XCTFail("expired Claude credential was accepted")
    } catch UsageProviderError.credentialsNotFound {
      // Expected: Reserve can continue to Claude's current protected sign-in.
    }

    let current = Data(
      #"{"claudeAiOauth":{"accessToken":"current-token","expiresAt":1900000000000}}"#.utf8)
    let decoded = try ClaudeCredentialLoader.decode(
      data: current, source: "current file", now: now)
    XCTAssertEqual(decoded.source, "current file")
  }

  @Test
  func testLegacyMigrationCleanInstallStartsWithEmptyReserveState() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let newSuite = "ReserveCoreTests.Clean"
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer { cleanTestDefaults(newDefaults, suiteName: newSuite) }

    let report = LegacyStateMigrator.migrate(
      oldDefaults: nil,
      newDefaults: newDefaults,
      oldDirectory: root.url.appendingPathComponent("MissingUsageBar"),
      newDirectory: root.url.appendingPathComponent("Reserve"))

    XCTAssertEqual(report.migratedPreferenceCount, 0)
    XCTAssertTrue(report.migratedCacheFiles.isEmpty)
    XCTAssertFalse(report.cacheMigrationFailed)
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: root.url.appendingPathComponent("Reserve").path))
    XCTAssertTrue(newDefaults.bool(forKey: LegacyStateMigrator.completionKey))
  }

  @Test
  func testLegacyMigrationRejectsUnsupportedRefreshInterval() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let oldSuite = "ReserveCoreTests.UnsupportedInterval.Old"
    let newSuite = "ReserveCoreTests.UnsupportedInterval.New"
    let oldDefaults = freshTestDefaults(suiteName: oldSuite)
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer {
      cleanTestDefaults(oldDefaults, suiteName: oldSuite)
      cleanTestDefaults(newDefaults, suiteName: newSuite)
    }
    oldDefaults.set(45, forKey: "refresh.intervalMinutes")

    let report = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: root.url.appendingPathComponent("UsageBar"),
      newDirectory: root.url.appendingPathComponent("Reserve"))

    XCTAssertEqual(report.migratedPreferenceCount, 0)
    XCTAssertNil(newDefaults.object(forKey: "refresh.intervalMinutes"))
  }

  @Test
  func testTokenAggregationSaturatesInsteadOfTrapping() {
    let summary = LocalUsageSummary(
      provider: .anthropic, periodDays: 30,
      inputTokens: .max, cachedInputTokens: .max,
      cacheWriteInputTokens: .max, outputTokens: .max,
      apiEquivalentCostUSD: 0)
    XCTAssertEqual(summary.totalTokens, .max)

    let grok = LocalUsageScanner.parseGrokSignal(
      Data(#"{"totalTokensBeforeCompaction":9223372036854775807,"contextTokensUsed":9223372036854775807}"#.utf8))
    XCTAssertEqual(grok?.input, .max)
  }

  @Test
  func testUsageWindowBoundsProviderControlledTextAndCount() {
    let window = UsageWindow(
      id: String(repeating: "x", count: 5_000),
      label: String(repeating: "y", count: 5_000), usedPercent: .infinity,
      windowMinutes: .max, resetsAt: Date().addingTimeInterval(3_600))
    XCTAssertEqual(window.id.count, UsageWindow.maximumIdentifierCharacters)
    XCTAssertEqual(window.label.count, UsageWindow.maximumLabelCharacters)
    XCTAssertEqual(window.usedPercent, 0)
    XCTAssertNil(window.windowMinutes)
    XCTAssertNil(UsagePaceProjection.calculate(for: window))
    let extremeReset = UsageWindow(
      id: "extreme", label: "Extreme", usedPercent: 99,
      windowMinutes: 60,
      resetsAt: Date(timeIntervalSince1970: TimeInterval(Int.max)))
    XCTAssertNil(extremeReset.resetsAt)
    let snapshot = UsageSnapshot(
      provider: .openAI,
      windows: Array(repeating: window, count: 100), source: "test")
    XCTAssertEqual(snapshot.windows.count, UsageSnapshot.maximumWindows)
  }

  @Test
  func testBoundedLineBufferPreservesUnconsumedRecordsForNextScan() {
    let buffer = BoundedLineBuffer(maximumBytes: 64)
    let first = buffer.append(Data("one\ntwo\nthree\n".utf8), maximumLines: 2)
    XCTAssertEqual(first.lines.map { String(decoding: $0, as: UTF8.self) }, ["one", "two"])
    XCTAssertEqual(first.consumedBytes, 8)
    let second = buffer.append(Data(), maximumLines: 2)
    XCTAssertEqual(second.lines.map { String(decoding: $0, as: UTF8.self) }, ["three"])
    XCTAssertEqual(second.consumedBytes, 6)
  }

  @Test
  func testBoundedLineBufferSkipsOversizedRecordAndResumesAtNextLine() {
    let buffer = BoundedLineBuffer(maximumBytes: 8)
    let oversized = buffer.append(Data("123456789".utf8))
    let recovered = buffer.append(Data("tail\nok\n".utf8))

    XCTAssertTrue(oversized.exceeded)
    XCTAssertEqual(oversized.consumedBytes, 9)
    XCTAssertTrue(recovered.exceeded)
    XCTAssertEqual(recovered.lines.map { String(decoding: $0, as: UTF8.self) }, ["ok"])
    XCTAssertEqual(recovered.consumedBytes, 8)
  }

  @Test
  func testNotificationComponentsAreFixedLengthAndDeterministic() {
    let value = String(repeating: "provider-controlled/", count: 100_000)
    let first = StableIdentifier.notificationComponent(value)
    let second = StableIdentifier.notificationComponent(value)
    XCTAssertEqual(first, second)
    XCTAssertEqual(first.count, 32)
    XCTAssertTrue(first.allSatisfy(\.isHexDigit))
  }

  @Test
  func testBoundedOutputGateCoalescesAndRejectsOverflow() {
    let gate = BoundedOutputGate(maximumBytes: 8)
    XCTAssertEqual(gate.append(Data("abc".utf8)), .scheduleDrain)
    XCTAssertEqual(gate.append(Data("de".utf8)), .accepted)
    XCTAssertEqual(String(decoding: gate.drain(), as: UTF8.self), "abcde")
    XCTAssertEqual(gate.append(Data("fgh".utf8)), .scheduleDrain)
    XCTAssertEqual(gate.append(Data("i".utf8)), .overflow)
    XCTAssertEqual(gate.append(Data("j".utf8)), .closed)
  }

  @Test
  func testRetryAfterIsFiniteAndCapped() async {
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    for value in ["nan", "inf", "1e309", "999999999999999999999"] {
      let retry = AnthropicProvider.conservativeRetryDate(retryAfter: value, now: now)
      XCTAssertGreaterThanOrEqual(retry, now.addingTimeInterval(15 * 60))
      XCTAssertLessThanOrEqual(
        retry, now.addingTimeInterval(AnthropicProvider.maximumRetryDelay))
    }
    let farDate = "Sun, 01 Jan 2090 00:00:00 GMT"
    XCTAssertEqual(
      AnthropicProvider.conservativeRetryDate(retryAfter: farDate, now: now),
      now.addingTimeInterval(AnthropicProvider.maximumRetryDelay))

    let suite = "ReserveCoreTests.RateLimit"
    let defaults = freshTestDefaults(suiteName: suite)
    defaults.set(Date.distantFuture, forKey: "anthropic.rateLimitBlockedUntil")
    let gate = ClaudeRateLimitGate(defaults: defaults)
    XCTAssertNil(await gate.activeBlock(now: now))
    cleanTestDefaults(suiteName: suite)
  }

  @Test
  func testOversizedSessionLineIsSkippedWithoutLosingProviderUsage() async throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let codex = root.url.appendingPathComponent("codex")
    let claude = root.url.appendingPathComponent("claude")
    let grok = root.url.appendingPathComponent("grok")
    for directory in [codex, claude, grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    let codexLines =
      [
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":1020}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(codexLines.utf8).write(to: codex.appendingPathComponent("session.jsonl"))
    let claudeLine =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5}}}"#
    var claudeData = Data(repeating: 0x41, count: 1_048_577)
    claudeData.append(Data(("\n" + claudeLine + "\n").utf8))
    try claudeData.write(to: claude.appendingPathComponent("session.jsonl"))
    let scanner = LocalUsageScanner(
      roots: .init(codex: codex, claude: claude, grok: grok),
      cacheURL: root.url.appendingPathComponent("index.json"))
    let usage = try await scanner.scan(now: now)
    let repeatedUsage = try await scanner.scan(now: now)

    XCTAssertEqual(usage[.openAI]?.totalTokens, 1_020)
    XCTAssertEqual(usage[.anthropic]?.totalTokens, 135)
    XCTAssertEqual(repeatedUsage, usage)
  }

  @Test
  func testOversizedUnterminatedSessionLineIsSkippedWithinBudget() async throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let codex = root.url.appendingPathComponent("codex")
    let claude = root.url.appendingPathComponent("claude")
    let grok = root.url.appendingPathComponent("grok")
    for directory in [codex, claude, grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let session = claude.appendingPathComponent("session.jsonl")
    try Data(repeating: 0x41, count: 1_048_577).write(to: session)
    let scanner = LocalUsageScanner(
      roots: .init(codex: codex, claude: claude, grok: grok),
      cacheURL: root.url.appendingPathComponent("index.json"))

    let now = Date()
    let first = try await scanner.scan(now: now)
    let timestamp = ISO8601DateFormatter().string(from: now)
    let continuedOversizedRecord =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"discard-r","message":{"id":"discard-m","model":"claude-opus-5","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":1000}}}"#
    let healthyRecord =
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"keep-r","message":{"id":"keep-m","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":5}}}"#
    let handle = try FileHandle(forWritingTo: session)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((continuedOversizedRecord + "\n" + healthyRecord + "\n").utf8))
    try handle.close()
    let second = try await scanner.scan(now: now)

    XCTAssertEqual(first[.anthropic]?.totalTokens, 0)
    XCTAssertEqual(second[.anthropic]?.totalTokens, 135)
  }

  @Test
  func testSessionEnumerationDoesNotDiscardFilesLargerThanReadBudget() async throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let sessions = root.url.appendingPathComponent("sessions")
    try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
    let large = sessions.appendingPathComponent("large.jsonl")
    FileManager.default.createFile(atPath: large.path, contents: Data())
    let handle = try FileHandle(forWritingTo: large)
    try handle.truncate(atOffset: UInt64(65 * 1_024 * 1_024))
    try handle.close()
    let small = sessions.appendingPathComponent("small.jsonl")
    try Data("{}\n".utf8).write(to: small)
    try FileManager.default.setAttributes(
      [.modificationDate: Date().addingTimeInterval(-60)], ofItemAtPath: large.path)
    try FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: small.path)

    let scanner = LocalUsageScanner(
      roots: .init(codex: sessions, claude: sessions, grok: sessions),
      cacheURL: root.url.appendingPathComponent("index.json"))
    let files = try await scanner.recentFiles(
      root: sessions, named: nil, extension: "jsonl",
      cutoff: Date().addingTimeInterval(-3_600), deadline: Date().addingTimeInterval(2))

    XCTAssertEqual(files.count, 2)
    XCTAssertEqual(files.first?.lastPathComponent, "small.jsonl")
    XCTAssertTrue(files.map(\.lastPathComponent).contains("large.jsonl"))
  }

  @Test
  func testJSONRPCQueueOverflowTerminatesSession() async throws {
    let script = #"read line; i=0; while [ $i -lt 80 ]; do printf '{"id":999,"result":{}}\n'; i=$((i+1)); done"#
    let rpc = try JSONRPCProcess(
      executable: "/bin/sh", arguments: ["-c", script],
      environment: ProcessInfo.processInfo.environment)
    defer { rpc.shutdown() }
    do {
      _ = try await rpc.request(method: "test", timeout: .seconds(2))
      XCTFail("overflowing response queue should terminate")
    } catch {
      XCTAssertTrue(error is UsageProviderError)
    }
  }

  @Test
  func testProcessRunnerDeadlineIncludesInheritedPipeDrain() async {
    let start = ContinuousClock.now
    do {
      _ = try await ProcessRunner.output(
        executable: "/bin/sh",
        arguments: ["-c", "(sleep 5) & exit 0"],
        environment: ProcessInfo.processInfo.environment,
        timeout: .milliseconds(200))
      XCTFail("descendant-held pipe should hit the deadline")
    } catch let error as UsageProviderError {
      guard case .timedOut = error else { return XCTFail("unexpected error: \(error)") }
    } catch {
      XCTFail("unexpected error: \(error)")
    }
    XCTAssertLessThan(start.duration(to: .now), .seconds(2))
  }

  @Test
  func testBoundedHTTPReceptionRejectsOversizedBody() async throws {
    MockURLProtocol.body = Data(repeating: 0x41, count: 1_025)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [MockURLProtocol.self]
    let session = URLSession(configuration: configuration)
    do {
      _ = try await ProviderHTTPSession.boundedData(
        for: URLRequest(url: URL(string: "https://example.test/body")!),
        using: session, maximumBytes: 1_024)
      XCTFail("oversized body should be rejected during reception")
    } catch let error as UsageProviderError {
      guard case .invalidResponse = error else { return XCTFail("unexpected error: \(error)") }
    }
  }

  @Test
  func testLegacyMigrationIsAllowListedValidatedAndIdempotent() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let oldSuite = "ReserveCoreTests.AllowListedMigration.Old"
    let newSuite = "ReserveCoreTests.AllowListedMigration.New"
    let oldDefaults = freshTestDefaults(suiteName: oldSuite)
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer {
      cleanTestDefaults(oldDefaults, suiteName: oldSuite)
      cleanTestDefaults(newDefaults, suiteName: newSuite)
    }
    oldDefaults.set(false, forKey: "provider.grok.enabled")
    oldDefaults.set(15, forKey: "refresh.intervalMinutes")
    oldDefaults.set("do-not-copy", forKey: "credential.secret")
    let oldDirectory = root.url.appendingPathComponent("UsageBar")
    let newDirectory = root.url.appendingPathComponent("Reserve")
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    let snapshot = UsageSnapshot(
      provider: .openAI,
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)],
      source: "test")
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode([snapshot]).write(
      to: oldDirectory.appendingPathComponent("snapshots.json"))
    try Data(#"{"version":1,"records":{}}"#.utf8).write(
      to: oldDirectory.appendingPathComponent("local-usage-index.json"))
    try Data("secret".utf8).write(to: oldDirectory.appendingPathComponent("credentials.json"))

    let report = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertEqual(report.migratedPreferenceCount, 2)
    XCTAssertEqual(
      report.migratedCacheFiles, ["local-usage-index.json", "snapshots.json"])
    XCTAssertFalse(report.cacheMigrationFailed)
    XCTAssertFalse(newDefaults.bool(forKey: "provider.grok.enabled"))
    XCTAssertEqual(newDefaults.integer(forKey: "refresh.intervalMinutes"), 15)
    XCTAssertNil(newDefaults.object(forKey: "credential.secret"))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: newDirectory.appendingPathComponent("credentials.json").path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: oldDirectory.appendingPathComponent("snapshots.json").path))
    let attributes = try FileManager.default.attributesOfItem(atPath: newDirectory.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)

    let second = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertTrue(second.wasAlreadyCompleted)
    XCTAssertTrue(second.migratedCacheFiles.isEmpty)
  }

  @Test
  func testLegacyMigrationDoesNotPartiallyPublishInvalidCachesOrOverwriteNewData() throws {
    let root = try TemporaryRoot()
    defer { root.remove() }
    let oldSuite = "ReserveCoreTests.InvalidCacheMigration.Old"
    let newSuite = "ReserveCoreTests.InvalidCacheMigration.New"
    let oldDefaults = freshTestDefaults(suiteName: oldSuite)
    let newDefaults = freshTestDefaults(suiteName: newSuite)
    defer {
      cleanTestDefaults(oldDefaults, suiteName: oldSuite)
      cleanTestDefaults(newDefaults, suiteName: newSuite)
    }
    let oldDirectory = root.url.appendingPathComponent("UsageBar")
    let newDirectory = root.url.appendingPathComponent("Reserve")
    oldDefaults.set(false, forKey: "provider.grok.enabled")
    try FileManager.default.createDirectory(at: oldDirectory, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newDirectory, withIntermediateDirectories: true)
    try Data("[]".utf8).write(to: oldDirectory.appendingPathComponent("snapshots.json"))
    try Data("invalid".utf8).write(
      to: oldDirectory.appendingPathComponent("local-usage-index.json"))
    let existing = newDirectory.appendingPathComponent("snapshots.json")
    try Data("new-state".utf8).write(to: existing)

    let report = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertTrue(report.cacheMigrationFailed)
    XCTAssertEqual(report.migratedPreferenceCount, 0)
    XCTAssertTrue(report.migratedCacheFiles.isEmpty)
    XCTAssertNil(newDefaults.object(forKey: "provider.grok.enabled"))
    XCTAssertFalse(newDefaults.bool(forKey: LegacyStateMigrator.completionKey))
    XCTAssertEqual(try Data(contentsOf: existing), Data("new-state".utf8))
    XCTAssertFalse(
      FileManager.default.fileExists(
        atPath: newDirectory.appendingPathComponent("local-usage-index.json").path))

    try Data(#"{"version":1,"records":{}}"#.utf8).write(
      to: oldDirectory.appendingPathComponent("local-usage-index.json"))
    let recovered = LegacyStateMigrator.migrate(
      oldDefaults: oldDefaults, newDefaults: newDefaults,
      oldDirectory: oldDirectory, newDirectory: newDirectory)
    XCTAssertFalse(recovered.cacheMigrationFailed)
    XCTAssertEqual(recovered.migratedPreferenceCount, 1)
    XCTAssertTrue(newDefaults.bool(forKey: LegacyStateMigrator.completionKey))
  }
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
  nonisolated(unsafe) static var body = Data()

  override class func canInit(with _: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    let response = HTTPURLResponse(
      url: self.request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    self.client?.urlProtocol(self, didLoad: Self.body)
    self.client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class TemporaryRoot {
  let url: URL

  init() throws {
    self.url = FileManager.default.temporaryDirectory
      .appendingPathComponent("ReserveCoreTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: true)
  }

  func remove() {
    try? FileManager.default.removeItem(at: self.url)
  }
}

private actor AsyncCounter {
  private var value = 0

  func increment() { self.value += 1 }
  func current() -> Int { self.value }
}
