import Foundation
import Testing
@testable import ReserveCore

@Suite
struct ResourceEfficiencyTests {
  @Test
  func cursorQuotaRefreshReusesPlanWithoutHelperOrHistory() async throws {
    let calls = ResourceCallCounts()
    let provider = self.cursor(calls: calls)
    let first = try await provider.fetch()
    let second = try await provider.fetch()
    #expect(first.windows == second.windows)
    #expect(first.planName == "Pro")
    #expect(first.accountUsage == nil)
    #expect(!first.detailedUsageUnavailable)
    #expect(await calls.count("credential") == 1)
    #expect(await calls.count("status") == 0)
    #expect(await calls.count("GetCurrentPeriodUsage") == 2)
    #expect(await calls.count("GetHardLimit") == 2)
    #expect(await calls.count("GetPlanInfo") == 1)
    #expect(await calls.count("GetMe") == 0)
  }

  @Test
  func cursorHistoryIsOptInAndRetainedDuringQuotaRefresh() async throws {
    let calls = ResourceCallCounts()
    let cache = CursorDataCache()
    let credentials = CursorCredentialSession()
    let detailed = self.cursor(
      calls: calls, includeAccountUsage: true, cache: cache, credentials: credentials)
    let first = try await detailed.fetch()
    #expect(first.accountUsage?.totalTokens == 120)
    let second = try await detailed.fetch()
    let quick = self.cursor(calls: calls, cache: cache, credentials: credentials)
    let third = try await quick.fetch()
    #expect(second.accountUsage == first.accountUsage)
    #expect(third.accountUsage == first.accountUsage)
    #expect(await calls.count("GetMe") == 1)
    #expect(await calls.count("GetAggregatedUsageEvents") == 3)
    #expect(await calls.count("GetFilteredUsageEvents") == 1)
  }

  @Test
  func cursorMetadataFailurePreservesFreshQuota() async throws {
    let calls = ResourceCallCounts()
    let provider = self.cursor(calls: calls, failPlan: true)
    let snapshot = try await provider.fetch()
    #expect(snapshot.windows.map(\.usedPercent) == [25, 40])
    #expect(snapshot.monthlyPriceMinorUnits == nil)
  }

  @Test
  func cursorMissingCredentialRecoversOnceWithoutInteractiveAccess() async throws {
    let calls = ResourceCallCounts()
    let provider = self.cursor(calls: calls, missingFirstCredential: true)
    _ = try await provider.fetch()
    #expect(await calls.count("credential") == 2)
    #expect(await calls.count("status") == 1)
  }

  @Test
  func cursorCacheSeparatesAccountsAndRetainsHistoryOnFailure() async {
    let cache = CursorDataCache()
    let now = Date()
    _ = await cache.value(for: "account-one", now: now)
    let usage = LocalUsageSummary(
      provider: .cursor, periodDays: 30, inputTokens: 10,
      outputTokens: 2, apiEquivalentCostUSD: 1, fetchedAt: now)
    await cache.storeUsage(usage, key: "account-one", now: now)
    await cache.noteUsageFailure(key: "account-one", now: now)
    let retained = await cache.value(for: "account-one", now: now)
    #expect(retained.usage == usage)
    #expect(retained.usageUnavailable)
    let other = await cache.value(for: "account-two", now: now)
    #expect(other.usage == nil)
    #expect(!other.usageUnavailable)
  }

  @Test
  func cursorBillingCycleChangeDropsPreviousCycleHistory() async {
    let cache = CursorDataCache()
    let now = Date()
    _ = await cache.value(for: "same-account", billingStart: 100, now: now)
    let usage = LocalUsageSummary(
      provider: .cursor, periodDays: 30, inputTokens: 10,
      outputTokens: 2, apiEquivalentCostUSD: 1, fetchedAt: now)
    await cache.storeUsage(usage, key: "same-account", now: now)
    let next = await cache.value(for: "same-account", billingStart: 200, now: now)
    #expect(next.usage == nil)
    #expect(next.usageExpiresAt < now)
  }

  @Test
  func cursorLockedKeychainDoesNotRunRecoveryHelper() async throws {
    let provider = CursorProvider(
      environment: [:], allowKeychainRead: true,
      statusRunner: { _, _, _ in
        Issue.record("Locked Keychain launched helper")
        return "{}"
      },
      credentialLoader: { _ in throw UsageProviderError.keychainConsentRequired(.cursor) },
      requestHandler: { _ in
        Issue.record("Locked Keychain reached network")
        throw UsageProviderError.unavailable("unexpected fixture request")
      })
    do {
      _ = try await provider.fetch()
      Issue.record("Locked Keychain succeeded")
    } catch UsageProviderError.keychainConsentRequired(.cursor) { }
  }

  @Test
  func scannerRespectsSelectionAndDirtyRootsWithoutDeletingDisabledHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let codex = root.appendingPathComponent("codex")
    let claude = root.appendingPathComponent("claude")
    let grok = root.appendingPathComponent("grok")
    for directory in [codex, claude, grok] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    let session = codex.appendingPathComponent("session.jsonl")
    func writeCodex(_ tokens: Int) throws {
      let line = #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(tokens),"output_tokens":2}}}}"#
      try Data((line + "\n").utf8).write(to: session)
    }
    try writeCodex(10)
    let claudeLine = #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"r1","message":{"id":"m1","model":"claude-opus-5","usage":{"input_tokens":30,"output_tokens":5}}}"#
    try Data((claudeLine + "\n").utf8).write(to: claude.appendingPathComponent("session.jsonl"))
    let cache = root.appendingPathComponent("index.json")
    let scanner = LocalUsageScanner(
      roots: .init(codex: codex, claude: claude, grok: grok), cacheURL: cache)
    let initial = try await scanner.scan(now: now, providers: [.openAI, .anthropic])
    #expect(initial.count == 2)
    #expect(initial[.openAI]?.totalTokens == 12)
    #expect(initial[.anthropic]?.totalTokens == 35)
    try writeCodex(20)
    let cached = try await scanner.scan(
      now: now.addingTimeInterval(10), providers: [.openAI], dirtyProviders: [])
    #expect(cached.count == 1)
    #expect(cached[.openAI]?.totalTokens == 12)
    #expect(cached[.openAI]?.fetchedAt == now)
    let refreshed = try await scanner.scan(
      now: now.addingTimeInterval(10), providers: [.openAI], dirtyProviders: [.openAI])
    #expect(refreshed[.openAI]?.totalTokens == 22)
    let reenabled = try await scanner.scan(now: now, providers: [.anthropic], dirtyProviders: [])
    #expect(reenabled[.anthropic]?.totalTokens == 35)
    let bytes = try Data(contentsOf: cache)
    let empty = try await scanner.scan(now: now, providers: [])
    #expect(empty.isEmpty)
    #expect(try Data(contentsOf: cache) == bytes)
  }

  @Test
  func chunkedHTTPAcceptsExactBoundAndEmptyBody() async throws {
    let session = self.httpSession()
    defer { session.invalidateAndCancel() }
    let (body, _) = try await ProviderHTTPSession.boundedData(
      for: URLRequest(url: URL(string: "https://example.test/exact")!),
      using: session, maximumBytes: 1_024)
    #expect(body == Data(repeating: 0x41, count: 1_024))
    let (empty, _) = try await ProviderHTTPSession.boundedData(
      for: URLRequest(url: URL(string: "https://example.test/empty")!),
      using: session, maximumBytes: 0)
    #expect(empty.isEmpty)
  }

  @Test
  func chunkedHTTPRejectsOverflowWithoutContentLength() async throws {
    let session = self.httpSession()
    defer { session.invalidateAndCancel() }
    do {
      _ = try await ProviderHTTPSession.boundedData(
        for: URLRequest(url: URL(string: "https://example.test/overflow")!),
        using: session, maximumBytes: 1_024)
      Issue.record("Accepted oversized response")
    } catch UsageProviderError.invalidResponse { }
  }

  @Test
  func chunkedHTTPCancellationEndsAnUnfinishedResponse() async throws {
    let session = self.httpSession()
    defer { session.invalidateAndCancel() }
    let task = Task {
      try await ProviderHTTPSession.boundedData(
        for: URLRequest(url: URL(string: "https://example.test/pending")!),
        using: session, maximumBytes: 1_024)
    }
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    do {
      _ = try await task.value
      Issue.record("Cancelled response completed successfully")
    } catch is CancellationError { }
  }

  private func httpSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ChunkedResourceURLProtocol.self]
    return URLSession(configuration: configuration)
  }

  private func cursor(
    calls: ResourceCallCounts,
    includeAccountUsage: Bool = false,
    cache: CursorDataCache = CursorDataCache(),
    credentials: CursorCredentialSession = CursorCredentialSession(),
    failPlan: Bool = false,
    missingFirstCredential: Bool = false
  ) -> CursorProvider {
    CursorProvider(
      environment: [:], allowKeychainRead: true,
      includeAccountUsage: includeAccountUsage, dataCache: cache,
      agentLocator: { _ in "/usr/bin/true" },
      statusRunner: { _, arguments, _ in
        #expect(arguments == ["status", "--format", "json"])
        await calls.increment("status")
        return #"{"isAuthenticated":true,"hasAccessToken":true}"#
      },
      credentialLoader: { interactive in
        #expect(!interactive)
        await calls.increment("credential")
        if missingFirstCredential, await calls.count("credential") == 1 {
          throw UsageProviderError.credentialsNotFound("fixture has no initial token")
        }
        return CursorCredential(accessToken: "synthetic-resource-test")
      },
      credentialSession: credentials,
      requestHandler: { request in
        let method = request.url!.lastPathComponent
        await calls.increment(method)
        let payload: String
        switch method {
        case "GetCurrentPeriodUsage":
          payload = #"{"planUsage":{"autoPercentUsed":25,"apiPercentUsed":40}}"#
        case "GetPlanInfo":
          payload = #"{"planInfo":{"planName":"pro","price":"$20 / month"}}"#
        case "GetHardLimit": payload = #"{"hardLimit":0}"#
        case "GetMe": payload = #"{"userId":7,"teamId":8}"#
        case "GetTeams": payload = "{}"
        case "GetAggregatedUsageEvents":
          payload = #"{"aggregations":[],"totalInputTokens":100,"totalOutputTokens":20,"totalCostCents":600}"#
        case "GetFilteredUsageEvents":
          payload = #"{"totalUsageEventsCount":0,"usageEventsDisplay":[]}"#
        default: throw UsageProviderError.invalidResponse("Unexpected fixture RPC")
        }
        return (
          Data(payload.utf8),
          HTTPURLResponse(url: request.url!, statusCode: failPlan && method == "GetPlanInfo" ? 503 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
      })
  }
}

private actor ResourceCallCounts {
  private var values: [String: Int] = [:]
  func increment(_ key: String) { self.values[key, default: 0] += 1 }
  func count(_ key: String) -> Int { self.values[key, default: 0] }
}

private final class ChunkedResourceURLProtocol: URLProtocol, @unchecked Sendable {
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
      headerFields: ["Content-Type": "application/octet-stream"])!
    self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    guard self.request.url?.lastPathComponent != "pending" else { return }
    if self.request.url?.lastPathComponent != "empty" {
      for _ in 0..<4 { self.client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 256)) }
    }
    if self.request.url?.lastPathComponent == "overflow" {
      self.client?.urlProtocol(self, didLoad: Data([0x42]))
    }
    self.client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() { }
}
