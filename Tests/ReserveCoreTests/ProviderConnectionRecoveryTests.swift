import Foundation
import Testing
@testable import ReserveCore

#if canImport(Security)
  import Security
#endif

private enum CursorFailure: Sendable {
  case unauthorizedFirst
  case unauthorizedAlways
  case permissionDenied
  case rateLimited
  case offline
}

private enum CursorRequestResult: Sendable {
  case response(statusCode: Int, payload: String, retryAfter: String?)
  case offline
}

private actor CursorRecoveryProbe {
  private let failure: CursorFailure?
  private let billingStart: Int64
  private let billingEnd: Int64
  private var statusRuns = 0
  private var credentialLoads = 0
  private var calls: [String] = []

  init(failure: CursorFailure?) {
    self.failure = failure
    let now = Date().timeIntervalSince1970
    self.billingStart = Int64((now - 3_600) * 1_000)
    self.billingEnd = Int64((now + 86_400) * 1_000)
  }

  func statusOutput() -> String {
    self.statusRuns += 1
    return #"{"isAuthenticated":true,"hasAccessToken":true}"#
  }

  func nextCredential() -> CursorCredential {
    self.credentialLoads += 1
    return CursorCredential(accessToken: "cursor-test-token-" + String(self.credentialLoads))
  }

  func request(path: String, token: String) -> CursorRequestResult {
    self.calls.append(path + ":" + token)
    if path == "GetCurrentPeriodUsage" {
      switch self.failure {
      case .unauthorizedFirst where token == "cursor-test-token-1":
        return .response(statusCode: 401, payload: #"{"code":"unauthenticated"}"#, retryAfter: nil)
      case .unauthorizedAlways:
        return .response(statusCode: 401, payload: #"{"code":"unauthenticated"}"#, retryAfter: nil)
      case .permissionDenied:
        return .response(statusCode: 403, payload: #"{"code":"permission_denied"}"#, retryAfter: nil)
      case .rateLimited:
        return .response(statusCode: 429, payload: "{}", retryAfter: "60")
      case .offline:
        return .offline
      case nil, .unauthorizedFirst:
        break
      }
    }
    return .response(statusCode: 200, payload: self.payload(for: path), retryAfter: nil)
  }

  func stats() -> (statusRuns: Int, credentialLoads: Int, calls: [String]) {
    (self.statusRuns, self.credentialLoads, self.calls)
  }

  private func payload(for path: String) -> String {
    switch path {
    case "GetCurrentPeriodUsage":
      return "{\"billingCycleStart\":\(self.billingStart),\"billingCycleEnd\":\(self.billingEnd),\"planUsage\":{\"autoPercentUsed\":10,\"apiPercentUsed\":20}}"
    case "GetPlanInfo":
      return "{\"planInfo\":{\"planName\":\"pro\",\"billingCycleEnd\":\(self.billingEnd)}}"
    case "GetMe":
      return #"{"userId":0}"#
    default:
      return "{}"
    }
  }
}

#if canImport(Security)
private actor ClaudeKeychainProbe {
    private(set) var calls = 0
    private(set) var timeouts: [Duration] = []

    func read(timeout: Duration) -> String {
      self.calls += 1
      self.timeouts.append(timeout)
      return #"{"claudeAiOauth":{"accessToken":"claude-test-token","expiresAt":4102444800000}}"#
    }
  }
#endif

@Suite
struct ProviderConnectionRecoveryTests {
  @Test
  func cursorRetriesOnceWithFreshCredentialAfterCachedTokenIsRejected() async throws {
    let probe = CursorRecoveryProbe(failure: .unauthorizedFirst)
    let session = CursorCredentialSession()
    let provider = Self.cursorProvider(probe: probe, session: session)

    let snapshot = try await provider.fetch()
    let stats = await probe.stats()
    #expect(snapshot.provider == .cursor)
    #expect(stats.statusRuns == 2)
    #expect(stats.credentialLoads == 2)
    #expect(stats.calls == [
      "GetCurrentPeriodUsage:cursor-test-token-1",
      "GetCurrentPeriodUsage:cursor-test-token-2",
      "GetPlanInfo:cursor-test-token-2",
      "GetHardLimit:cursor-test-token-2",
      "GetMe:cursor-test-token-2",
    ])
  }

  @Test
  func cursorFreshCredentialRejectionRemainsActionableWithoutLooping() async throws {
    let probe = CursorRecoveryProbe(failure: .unauthorizedAlways)
    let session = CursorCredentialSession()
    let provider = Self.cursorProvider(probe: probe, session: session)

    do {
      _ = try await provider.fetch()
      Issue.record("Cursor accepted a rejected credential")
    } catch let error as UsageProviderError {
      guard case .unauthorized = error else {
        Issue.record("Cursor returned the wrong recovery error: \(error)")
        return
      }
    }

    let stats = await probe.stats()
    #expect(stats.statusRuns == 2)
    #expect(stats.credentialLoads == 2)
    #expect(stats.calls == [
      "GetCurrentPeriodUsage:cursor-test-token-1",
      "GetCurrentPeriodUsage:cursor-test-token-2",
    ])

    let next = try await session.credential {
      CursorCredential(accessToken: "cursor-test-token-after-rejection")
    }
    #expect(next.accessToken == "cursor-test-token-after-rejection")
  }

  @Test
  func cursorPermissionRateLimitAndOfflineErrorsDoNotTriggerRecoveryLoop() async throws {
    for failure in [CursorFailure.permissionDenied, .rateLimited, .offline] {
      let probe = CursorRecoveryProbe(failure: failure)
      let provider = Self.cursorProvider(
        probe: probe, session: CursorCredentialSession())

      do {
        _ = try await provider.fetch()
        Issue.record("Cursor accepted a failed request")
      } catch let error as UsageProviderError {
        switch failure {
        case .permissionDenied:
          guard case .accessDenied(let message) = error else {
            Issue.record("Cursor permission denial was classified as \(error)")
            continue
          }
          #expect(message.localizedCaseInsensitiveContains("permission"))
          #expect(!error.requiresConnection)
        case .rateLimited:
          guard case .rateLimited = error else {
            Issue.record("Cursor rate limit was classified as \(error)")
            continue
          }
          #expect(!error.requiresConnection)
        case .offline:
          guard case .unavailable = error else {
            Issue.record("Cursor offline failure was classified as \(error)")
            continue
          }
          #expect(!error.requiresConnection)
        case .unauthorizedFirst, .unauthorizedAlways:
          Issue.record("unexpected recovery scenario")
        }
      }

      let stats = await probe.stats()
      #expect(stats.statusRuns == 1)
      #expect(stats.credentialLoads == 1)
      #expect(stats.calls.count == 1)
    }
  }

  #if canImport(Security)
    @Test
    func claudeKeychainReadFailuresSeparateTimeoutFromConsent() async throws {
      do {
        _ = try await ClaudeCredentialLoader.keychainCredentials(
          itemExists: { true },
          securityToolRunner: { _, _, _, _ in
            throw UsageProviderError.timedOut("security")
          })
        Issue.record("Claude Keychain timeout was accepted")
      } catch let error as UsageProviderError {
        guard case .unavailable(let message) = error else {
          Issue.record("Claude Keychain timeout was classified as \(error)")
          return
        }
        #expect(message.localizedCaseInsensitiveContains("timed out"))
      }

      do {
        _ = try await ClaudeCredentialLoader.keychainCredentials(
          itemExists: { true },
          securityToolRunner: { _, _, _, _ in
            throw UsageProviderError.processFailed("security access denied")
          })
        Issue.record("Claude Keychain permission failure was accepted")
      } catch let error as UsageProviderError {
        guard case .keychainConsentRequired(.anthropic) = error else {
          Issue.record("Claude Keychain permission failure was classified as \(error)")
          return
        }
      }
    }

    @Test
    func claudeLockedBackgroundReadSkipsRunnerButExplicitAccessUsesIt() async throws {
      let probe = ClaudeKeychainProbe()
      let background = try await ClaudeCredentialLoader.keychainCredentials(
        allowInteraction: false,
        itemExists: { false },
        securityToolRunner: { _, _, _, _ in
          Issue.record("background Claude Keychain read launched the trusted tool")
          return await probe.read(timeout: .seconds(3))
        })
      #expect(background == nil)
      #expect(await probe.calls == 0)

      let readableBackground = try await ClaudeCredentialLoader.keychainCredentials(
        allowInteraction: false,
        itemExists: { true },
        securityToolRunner: { _, _, _, timeout in await probe.read(timeout: timeout) })
      #expect(readableBackground?.accessToken == "claude-test-token")
      #expect(await probe.calls == 1)
      #expect(await probe.timeouts == [.seconds(3)])

      let explicit = try await ClaudeCredentialLoader.keychainCredentials(
        allowInteraction: true,
        itemExists: { true },
        securityToolRunner: { _, _, _, timeout in await probe.read(timeout: timeout) })
      #expect(explicit?.accessToken == "claude-test-token")
      #expect(await probe.calls == 2)
      #expect(await probe.timeouts == [.seconds(3), .seconds(120)])
    }

    @Test
    func cursorKeychainAccessFailuresRemainDistinctFromMissingCredentials() {
      #expect(
        CursorCredentialLoader.keychainReadError(for: errSecInteractionNotAllowed)
          == .keychainConsentRequired(.cursor))
      #expect(
        !CursorCredentialLoader.keychainReadError(for: errSecDecode).requiresConnection)
    }
  #endif

  private static func cursorProvider(
    probe: CursorRecoveryProbe,
    session: CursorCredentialSession
  ) -> CursorProvider {
    CursorProvider(
      environment: [:],
      allowKeychainRead: true,
      agentLocator: { _ in "/usr/bin/true" },
      statusRunner: { _, _, _ in await probe.statusOutput() },
      credentialLoader: { _ in await probe.nextCredential() },
      credentialSession: session,
      requestHandler: { request in
        let path = request.url?.lastPathComponent ?? ""
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
          .replacingOccurrences(of: "Bearer ", with: "")
        let result = await probe.request(path: path, token: token)
        switch result {
        case .offline:
          throw URLError(.notConnectedToInternet)
        case .response(let statusCode, let payload, let retryAfter):
          var headers = [String: String]()
          if let retryAfter { headers["Retry-After"] = retryAfter }
          return (
            Data(payload.utf8),
            HTTPURLResponse(
              url: request.url!, statusCode: statusCode, httpVersion: nil,
              headerFields: headers)!)
        }
      })
  }
}
