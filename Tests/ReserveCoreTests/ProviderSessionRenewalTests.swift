import Foundation
import Testing

@testable import ReserveCore

/// These tests never launch a provider CLI, read the Keychain, reach the
/// network, or touch a real credential store. Renewal runners, the Keychain
/// candidate loader, and the usage request are all injected, and every file
/// lives in a temporary directory. Token strings are fixtures.
private struct RenewalFixtureError: Error, CustomStringConvertible {
  let description: String
}

private actor RunnerProbe {
  private(set) var calls: [(executable: String, arguments: [String], timeout: Duration)] = []
  private(set) var environments: [[String: String]] = []
  private let failure: Bool
  private let onRun: (@Sendable () -> Void)?

  init(failure: Bool = false, onRun: (@Sendable () -> Void)? = nil) {
    self.failure = failure
    self.onRun = onRun
  }

  func run(
    executable: String, arguments: [String], environment: [String: String], timeout: Duration
  ) throws {
    self.calls.append((executable, arguments, timeout))
    self.environments.append(environment)
    self.onRun?()
    if self.failure { throw UsageProviderError.processFailed("fixture helper failed") }
  }

  var callCount: Int { self.calls.count }
}

private actor ClaudeRenewalProbe {
  private(set) var refreshTokens: [String] = []
  private(set) var scopes: [[String]?] = []
  private let succeeds: Bool

  init(succeeds: Bool) { self.succeeds = succeeds }

  func renew(refreshToken: String, scopes: [String]?) -> Bool {
    self.refreshTokens.append(refreshToken)
    self.scopes.append(scopes)
    return self.succeeds
  }

  var callCount: Int { self.refreshTokens.count }
}

private actor CallCounter {
  private(set) var count = 0
  func increment() { self.count += 1 }
}

private actor ClaudeUsageProbe {
  private(set) var tokens: [String] = []
  private let acceptedToken: String

  init(acceptedToken: String) { self.acceptedToken = acceptedToken }

  func statusCode(for token: String) -> Int {
    self.tokens.append(token)
    return token == self.acceptedToken ? 200 : 401
  }

  var callCount: Int { self.tokens.count }
}

private func temporaryDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("reserve-renewal-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

private func grokAuthFile(
  key: String, userID: String = "fixture-user", expiresAt: String, refreshToken: String?
) -> Data {
  var entry: [String: String] = [
    "key": key, "user_id": userID, "expires_at": expiresAt,
  ]
  if let refreshToken { entry["refresh_token"] = refreshToken }
  return try! JSONSerialization.data(
    withJSONObject: ["https://auth.x.ai::fixture": entry], options: [])
}

/// Answers Grok's billing and settings requests, and can rewrite the auth file
/// the way another client or the CLI would.
private actor GrokBillingProbe {
  enum Rejection: String { case anotherClientRenewedTheSameAccount, unchangedKey, differentAccount }
  private(set) var billingTokens: [String] = []
  private(set) var settingsTokens: [String] = []
  private let rejection: Rejection
  private let authFile: URL
  private let acceptedKey: String

  init(rejection: Rejection, authFile: URL, acceptedKey: String) {
    self.rejection = rejection
    self.authFile = authFile
    self.acceptedKey = acceptedKey
  }

  func statusCode(path: String, token: String) -> Int {
    if path == "settings" {
      self.settingsTokens.append(token)
      return 200
    }
    self.billingTokens.append(token)
    if token == self.acceptedKey { return 200 }
    if self.billingTokens.count == 1 {
      switch self.rejection {
      case .anotherClientRenewedTheSameAccount:
        self.write(key: self.acceptedKey, userID: "fixture-user")
      case .differentAccount:
        self.write(key: "other-account-key", userID: "other-user")
      case .unchangedKey:
        break
      }
    }
    return 401
  }

  func write(key: String, userID: String) {
    try? grokAuthFile(
      key: key, userID: userID,
      expiresAt: ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 3_600)),
      refreshToken: "fixture-refresh"
    ).write(to: self.authFile)
  }
}

@Suite
struct ProviderSessionRenewalTests {
  // MARK: - Grok

  @Test
  func grokCandidatePrefersUnexpiredEntryThenTheLatestRenewableExpiredEntry() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let current = GrokCredentialEntry(
      key: "current-key", userID: "current-user", expiresAt: "2033-05-18T03:33:20Z",
      refreshToken: "current-refresh")
    let stale = GrokCredentialEntry(
      key: "stale-key", userID: "stale-user", expiresAt: "2020-01-01T00:00:00Z",
      refreshToken: "stale-refresh")

    let preferred = GrokCredentialLoader.candidate(
      entries: ["https://auth.x.ai::a": current, "https://auth.x.ai::b": stale], now: now)
    #expect(preferred?.credentials.key == "current-key")
    #expect(preferred?.canRenew == true)
    #expect(preferred?.expiresAt == UsageDateParser.iso8601("2033-05-18T03:33:20Z"))

    let older = GrokCredentialEntry(
      key: "older-key", userID: "older-user", expiresAt: "2019-01-01T00:00:00Z",
      refreshToken: "older-refresh")
    let expired = GrokCredentialLoader.candidate(
      entries: ["https://auth.x.ai::a": older, "https://auth.x.ai::b": stale], now: now)
    #expect(expired?.credentials.key == "stale-key")
    #expect(expired?.canRenew == true)
    #expect(expired?.expiresAt == UsageDateParser.iso8601("2020-01-01T00:00:00Z"))

    let withoutRefreshToken = GrokCredentialLoader.candidate(
      entries: [
        "https://auth.x.ai::a": GrokCredentialEntry(
          key: "stale-key", userID: "stale-user", expiresAt: "2020-01-01T00:00:00Z")
      ],
      now: now)
    #expect(withoutRefreshToken?.canRenew == false)
    // The unexpired-only accessor still refuses an expired entry.
    #expect(
      GrokCredentialLoader.select(
        entries: ["https://auth.x.ai::a": stale], now: now) == nil)
  }

  @Test
  func grokAuthFilePathPrefersExplicitFileThenHomeThenDefault() {
    #expect(
      GrokCredentialLoader.authFileURL(
        environment: ["GROK_AUTH_PATH": "/tmp/fixture/auth.json", "GROK_HOME": "/tmp/home"]
      ).path == "/tmp/fixture/auth.json")
    #expect(
      GrokCredentialLoader.authFileURL(environment: ["GROK_HOME": "/tmp/home"]).path
        == "/tmp/home/auth.json")
    #expect(
      GrokCredentialLoader.authFileURL(environment: ["GROK_AUTH_PATH": ""]).path
        == FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".grok/auth.json").path)
  }

  @Test
  func grokRenewalRunsTheHeadlessCommandOncePerCooldownAndAdoptsTheRewrittenFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authFile = directory.appendingPathComponent("auth.json")
    try grokAuthFile(
      key: "expired-key", expiresAt: "2020-01-01T00:00:00Z", refreshToken: "fixture-refresh")
      .write(to: authFile)
    let environment = [
      "GROK_AUTH_PATH": authFile.path, "OPENAI_API_KEY": "unrelated-fixture-secret",
    ]
    let now = Date()
    let candidate = try GrokCredentialLoader.load(environment: environment, now: now)
    #expect(candidate.canRenew)
    #expect(candidate.expiresAt.map { $0 <= now } == true)

    // The stub stands in for the CLI rewriting its own auth.json.
    let renewed = ISO8601DateFormatter().string(from: now.addingTimeInterval(6 * 3_600))
    let probe = RunnerProbe {
      try? grokAuthFile(
        key: "renewed-key", expiresAt: renewed, refreshToken: "rotated-refresh")
        .write(to: authFile)
    }
    let renewer = GrokSessionRenewer()
    await renewer.renew(
      executable: "/usr/bin/true", environment: environment, now: now,
      runner: { executable, arguments, environment, timeout in
        try await probe.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(await probe.callCount == 1)
    let call = await probe.calls[0]
    #expect(call.arguments == ["models"])
    #expect(call.timeout == .seconds(45))
    let renewalEnvironment = await probe.environments[0]
    #expect(renewalEnvironment["GROK_AUTH_PATH"] == authFile.path)
    #expect(renewalEnvironment["HOME"]?.isEmpty == false)
    #expect(renewalEnvironment["OPENAI_API_KEY"] == nil)
    #expect(renewalEnvironment["DYLD_INSERT_LIBRARIES"] == nil)

    let adopted = try GrokCredentialLoader.load(environment: environment, now: now)
    #expect(adopted.credentials.key == "renewed-key")
    #expect(adopted.expiresAt.map { $0 > now } == true)

    // A second attempt inside the cooldown must not start the CLI again.
    await renewer.renew(
      executable: "/usr/bin/true", environment: environment,
      now: now.addingTimeInterval(30),
      runner: { executable, arguments, environment, timeout in
        try await probe.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(await probe.callCount == 1)
    await renewer.renew(
      executable: "/usr/bin/true", environment: environment,
      now: now.addingTimeInterval(61),
      runner: { executable, arguments, environment, timeout in
        try await probe.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(await probe.callCount == 2)
  }

  @Test
  func grokExpiredSessionWithoutRefreshTokenAsksForSignIn() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let authFile = directory.appendingPathComponent("auth.json")
    try grokAuthFile(key: "expired-key", expiresAt: "2020-01-01T00:00:00Z", refreshToken: nil)
      .write(to: authFile)
    let candidate = try GrokCredentialLoader.load(
      environment: ["GROK_AUTH_PATH": authFile.path], now: Date())
    #expect(!candidate.canRenew)
    guard case .unauthorized(let message) = GrokProvider.signInExpired else {
      Issue.record("Grok expiry is not reported as an authentication failure")
      return
    }
    #expect(message == "Grok sign-in expired. Use Sign in to reconnect.")
    #expect(GrokProvider.signInExpired.requiresConnection)
  }

  // MARK: - Claude

  @Test
  func claudeCandidateDecodingToleratesBlankTokensMissingScopesAndUnknownKeys() throws {
    let blank = try ClaudeCredentialLoader.decodeCandidate(
      data: Data(
        #"{"claudeAiOauth":{"accessToken":"","refreshToken":"fixture-refresh","expiresAt":1799999999000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:profile","user:inference"]},"mcpOAuth":{"unrelated":true},"trustedDeviceToken":"ignored"}"#
          .utf8),
      source: "fixture")
    #expect(blank.accessToken == nil)
    #expect(blank.scopes == ["user:profile", "user:inference"])
    #expect(!blank.hasUsableAccessToken(now: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(blank.canRenew(now: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(blank.credentials == nil)

    let legacy = try ClaudeCredentialLoader.decodeCandidate(
      data: Data(
        #"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":1900000000000}}"#
          .utf8),
      source: "fixture")
    #expect(legacy.scopes == nil)
    #expect(legacy.refreshTokenExpiresAt == nil)
    #expect(legacy.canRenew(now: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(legacy.hasUsableAccessToken(now: Date(timeIntervalSince1970: 1_800_000_000)))
    #expect(legacy.credentials?.accessToken == "fixture-access")

    do {
      _ = try ClaudeCredentialLoader.decodeCandidate(
        data: Data("not json".utf8), source: "fixture")
      Issue.record("invalid Claude credential JSON was accepted")
    } catch UsageProviderError.credentialsNotFound {
      // Expected.
    }

    do {
      _ = try ClaudeCredentialLoader.decodeCandidate(
        data: Data(#"{"claudeAiOauth":{"accessToken":"   ","refreshToken":""}}"#.utf8),
        source: "fixture")
      Issue.record("a credential without either token was accepted")
    } catch UsageProviderError.credentialsNotFound {
      // Expected.
    }
  }

  @Test
  func claudeLoadPrefersAUsableKeychainTokenOverAnExpiredFile() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(".credentials.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"file-access","refreshToken":"file-refresh","expiresAt":1799999999000}}"#
        .utf8
    ).write(to: file)
    let probe = ClaudeRenewalProbe(succeeds: false)

    let credentials = try await ClaudeCredentialLoader.load(
      environment: [:], allowKeychainRead: true, now: Date(timeIntervalSince1970: 1_800_000_000),
      keychainCandidateLoader: { _ in
        try ClaudeCredentialLoader.decodeCandidate(
          data: Data(
            #"{"claudeAiOauth":{"accessToken":"keychain-access","refreshToken":"keychain-refresh","expiresAt":1900000000000,"subscriptionType":"max"}}"#
              .utf8),
          source: "Claude Keychain")
      },
      credentialFileURLs: [file],
      renewer: { token, scopes, _ in await probe.renew(refreshToken: token, scopes: scopes) })

    #expect(credentials.source == "Claude Keychain")
    #expect(credentials.accessToken == "keychain-access")
    #expect(credentials.subscriptionType == "max")
    #expect(await probe.callCount == 0)
  }

  @Test
  func claudeExpiredStoresRenewThroughClaudeCodeAndThenRereadTheStores() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(".credentials.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"","refreshToken":"file-refresh","expiresAt":1799999999000,"scopes":["user:profile","user:inference"]}}"#
        .utf8
    ).write(to: file)
    let probe = ClaudeRenewalProbe(succeeds: true)
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let renewedKeychainItem = Data(
      #"{"claudeAiOauth":{"accessToken":"renewed-access","refreshToken":"rotated-refresh","expiresAt":1900000000000}}"#
        .utf8)

    let credentials = try await ClaudeCredentialLoader.load(
      environment: [:], allowKeychainRead: true, now: now,
      keychainCandidateLoader: { _ in
        // Claude Code stores the rotated credential itself; the second read
        // is what Reserve is allowed to see.
        let renewed = await probe.callCount > 0
        return try ClaudeCredentialLoader.decodeCandidate(
          data: renewed
            ? renewedKeychainItem
            : Data(
              #"{"claudeAiOauth":{"accessToken":"stale-access","expiresAt":1700000000000}}"#.utf8),
          source: "Claude Keychain")
      },
      credentialFileURLs: [file],
      renewer: { token, scopes, _ in await probe.renew(refreshToken: token, scopes: scopes) })

    #expect(credentials.accessToken == "renewed-access")
    #expect(credentials.source == "Claude Keychain")
    #expect(await probe.callCount == 1)
    #expect(await probe.refreshTokens == ["file-refresh"])
    #expect(await probe.scopes == [["user:profile", "user:inference"]])
  }

  @Test
  func claudeRenewalFailureAsksForSignInAndAnExpiredRefreshTokenIsNotUsed() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let expiredAccess = directory.appendingPathComponent("expired.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"file-refresh","expiresAt":1799999999000,"refreshTokenExpiresAt":1900000000000}}"#
        .utf8
    ).write(to: expiredAccess)
    let failing = ClaudeRenewalProbe(succeeds: false)

    do {
      _ = try await ClaudeCredentialLoader.load(
        environment: [:], allowKeychainRead: true, now: now,
        keychainCandidateLoader: { _ in nil },
        keychainItemExists: { false },
        credentialFileURLs: [expiredAccess],
        renewer: { token, scopes, _ in
          await failing.renew(refreshToken: token, scopes: scopes)
        })
      Issue.record("a failed renewal was reported as a connected account")
    } catch let error as UsageProviderError {
      guard case .credentialsNotFound(let message) = error else {
        Issue.record("a failed renewal was classified as \(error)")
        return
      }
      #expect(message == "Claude sign-in expired. Use Sign in to reconnect.")
      #expect(error.requiresConnection)
    }
    #expect(await failing.callCount == 1)

    let expiredRefresh = directory.appendingPathComponent("expired-refresh.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"file-refresh","expiresAt":1799999999000,"refreshTokenExpiresAt":1799999999000}}"#
        .utf8
    ).write(to: expiredRefresh)
    let untouched = ClaudeRenewalProbe(succeeds: true)
    do {
      _ = try await ClaudeCredentialLoader.load(
        environment: [:], allowKeychainRead: true, now: now,
        keychainCandidateLoader: { _ in nil },
        keychainItemExists: { false },
        credentialFileURLs: [expiredRefresh],
        renewer: { token, scopes, _ in
          await untouched.renew(refreshToken: token, scopes: scopes)
        })
      Issue.record("an expired refresh token was accepted")
    } catch UsageProviderError.credentialsNotFound {
      // Expected.
    }
    #expect(await untouched.callCount == 0)
  }

  @Test
  func claudeRenewerUsesTheDocumentedNonInteractiveLoginAndBacksOffAfterFailure() async throws {
    let probe = RunnerProbe()
    let renewer = ClaudeSessionRenewer()
    let now = Date()
    let succeeded = await renewer.renew(
      refreshToken: "fixture-refresh", scopes: nil,
      environment: [
        "BROWSER": "/bin/echo", "OPENAI_API_KEY": "unrelated-fixture-secret",
        "RESERVE_LOGIN_PIPE": "/tmp/fixture-pipe", "CLAUDE_CONFIG_DIR": "/tmp/fixture-config",
        "LANG": "en_US.UTF-8", "DYLD_INSERT_LIBRARIES": "/tmp/fixture.dylib",
      ],
      now: now, locator: { _ in "/usr/bin/true" },
      runner: { executable, arguments, environment, timeout in
        try await probe.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(succeeded)
    let call = await probe.calls[0]
    #expect(call.executable == "/usr/bin/true")
    #expect(call.arguments == ["auth", "login", "--claudeai"])
    #expect(call.timeout == .seconds(60))
    let environment = await probe.environments[0]
    #expect(environment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] == "fixture-refresh")
    #expect(
      environment["CLAUDE_CODE_OAUTH_SCOPES"]
        == ClaudeSessionRenewer.defaultScopes.joined(separator: " "))
    #expect(environment["BROWSER"] == nil)
    #expect(environment["RESERVE_LOGIN_PIPE"] == nil)
    // Unrelated secrets in Reserve's own environment must not reach a helper
    // Reserve starts by itself; what the CLI needs does reach it.
    #expect(environment["OPENAI_API_KEY"] == nil)
    #expect(environment["DYLD_INSERT_LIBRARIES"] == nil)
    #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/fixture-config")
    #expect(environment["LANG"] == "en_US.UTF-8")
    #expect(environment["HOME"]?.isEmpty == false)

    // Inside the cooldown nothing is started, and stored scopes are forwarded.
    let cooledDown = await renewer.renew(
      refreshToken: "fixture-refresh", scopes: ["user:profile"], environment: [:],
      now: now.addingTimeInterval(60), locator: { _ in "/usr/bin/true" },
      runner: { executable, arguments, environment, timeout in
        try await probe.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(!cooledDown)
    #expect(await probe.callCount == 1)

    let failing = RunnerProbe(failure: true)
    let failingRenewer = ClaudeSessionRenewer()
    let failed = await failingRenewer.renew(
      refreshToken: "fixture-refresh", scopes: ["user:profile"], environment: [:],
      now: now, locator: { _ in "/usr/bin/true" },
      runner: { executable, arguments, environment, timeout in
        try await failing.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(!failed)
    #expect(await failing.environments[0]["CLAUDE_CODE_OAUTH_SCOPES"] == "user:profile")
    // A failure holds off further attempts for ten minutes, well past the
    // ordinary cooldown.
    let backedOff = await failingRenewer.renew(
      refreshToken: "fixture-refresh", scopes: nil, environment: [:],
      now: now.addingTimeInterval(300), locator: { _ in "/usr/bin/true" },
      runner: { executable, arguments, environment, timeout in
        try await failing.run(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      })
    #expect(!backedOff)
    #expect(await failing.callCount == 1)

    // A missing helper is not a failed attempt, just an unavailable one.
    let withoutHelper = await ClaudeSessionRenewer().renew(
      refreshToken: "fixture-refresh", scopes: nil, environment: [:], now: now,
      locator: { _ in nil },
      runner: { _, _, _, _ in
        throw RenewalFixtureError(description: "renewal ran without a helper")
      })
    #expect(!withoutHelper)
  }

  @Test
  func grokRejectedBillingTokenStaysInsideTheSameAccount() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for rejection in [
      GrokBillingProbe.Rejection.anotherClientRenewedTheSameAccount, .unchangedKey,
      .differentAccount,
    ] {
    let authFile = directory.appendingPathComponent("auth-\(rejection.rawValue).json")
    let future = ISO8601DateFormatter().string(from: Date().addingTimeInterval(6 * 3_600))
    try grokAuthFile(key: "first-key", expiresAt: future, refreshToken: "fixture-refresh")
      .write(to: authFile)
    let probe = GrokBillingProbe(
      rejection: rejection, authFile: authFile, acceptedKey: "second-key")
    let renewals = RunnerProbe()
    let billing = Data(
      #"{"config":{"creditUsagePercent":5,"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-09-06T22:03:41Z","end":"2026-09-13T22:03:41Z"}}}"#
        .utf8)
    let settings = Data(#"{"subscription_tier_display":"SuperGrok"}"#.utf8)
    let provider = GrokProvider(
      environment: ["GROK_AUTH_PATH": authFile.path],
      renewer: { executable, environment in
        // Stands in for the CLI renewing and rewriting its own auth file.
        try? await renewals.run(
          executable: executable, arguments: ["models"], environment: environment,
          timeout: .seconds(45))
        await probe.write(key: "second-key", userID: "fixture-user")
      },
      executableLocator: { _ in "/usr/bin/true" },
      versionProbe: { _ in SemanticVersion(1, 0, 24) },
      requestHandler: { request in
        let path = request.url?.lastPathComponent ?? ""
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
          .replacingOccurrences(of: "Bearer ", with: "")
        let status = await probe.statusCode(path: path, token: token)
        return (
          status == 200 ? (path == "settings" ? settings : billing) : Data("{}".utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        )
      })

    switch rejection {
    case .anotherClientRenewedTheSameAccount:
      let snapshot = try await provider.fetch()
      #expect(snapshot.windows.first?.usedPercent == 5)
      #expect(await probe.billingTokens == ["first-key", "second-key"])
      // Nothing needed starting: the session was already renewed elsewhere.
      #expect(await renewals.callCount == 0)
      // The plan lookup must describe the credential that produced the numbers.
      #expect(await probe.settingsTokens.last == "second-key")
    case .unchangedKey:
      let snapshot = try await provider.fetch()
      #expect(snapshot.planName == "SuperGrok")
      #expect(await probe.billingTokens == ["first-key", "second-key"])
      #expect(await renewals.callCount == 1)
      #expect(await renewals.calls[0].arguments == ["models"])
      #expect(await probe.settingsTokens.last == "second-key")
    case .differentAccount:
      do {
        _ = try await provider.fetch()
        Issue.record("Grok read usage for an account whose token was not rejected")
      } catch let error as UsageProviderError {
        guard case .unauthorized(let message) = error else {
          Issue.record("a foreign Grok session was classified as \(error)")
          return
        }
        #expect(message == "Grok sign-in expired. Use Sign in to reconnect.")
      }
      // Neither a renewal nor a retry may happen for somebody else's session.
      #expect(await renewals.callCount == 0)
      #expect(await probe.billingTokens == ["first-key"])
    }
    }
  }

  @Test
  func claudeLockedKeychainAsksForAccessInsteadOfRenewingOrSigningInAgain() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(".credentials.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"file-refresh","expiresAt":1799999999000}}"#
        .utf8
    ).write(to: file)
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    // A background pass cannot read a locked item, so it collects nothing from
    // it. Renewing would land in that same unreadable item, and a browser
    // sign-in would replace the session Claude Code is still using.
    for lockedLoader in [
      { @Sendable (_: Bool) async throws -> ClaudeCredentialCandidate? in nil },
      { @Sendable (_: Bool) async throws -> ClaudeCredentialCandidate? in
        throw UsageProviderError.keychainConsentRequired(.anthropic)
      },
    ] {
      let untouched = ClaudeRenewalProbe(succeeds: true)
      do {
        _ = try await ClaudeCredentialLoader.load(
          environment: [:], allowKeychainRead: true, now: now,
          keychainCandidateLoader: lockedLoader,
          keychainItemExists: { true },
          credentialFileURLs: [file],
          renewer: { token, scopes, _ in
            await untouched.renew(refreshToken: token, scopes: scopes)
          })
        Issue.record("a locked Claude Keychain item was reported as a lost sign-in")
      } catch let error as UsageProviderError {
        guard case .keychainConsentRequired(.anthropic) = error else {
          Issue.record("a locked Claude Keychain item was classified as \(error)")
          continue
        }
      }
      #expect(await untouched.callCount == 0)
    }

    // Reading the item and finding it unusable is a different situation: there
    // is something to renew, and the result can be observed.
    let renewal = ClaudeRenewalProbe(succeeds: true)
    let renewed = Data(
      #"{"claudeAiOauth":{"accessToken":"renewed-access","refreshToken":"rotated-refresh","expiresAt":1900000000000}}"#
        .utf8)
    let credentials = try await ClaudeCredentialLoader.load(
      environment: [:], allowKeychainRead: true, now: now,
      keychainCandidateLoader: { _ in
        let item =
          await renewal.callCount > 0
          ? renewed
          : Data(
            #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"keychain-refresh","expiresAt":1799999999000}}"#
              .utf8)
        return try ClaudeCredentialLoader.decodeCandidate(
          data: item, source: "Claude Keychain")
      },
      keychainItemExists: { true },
      credentialFileURLs: [],
      renewer: { token, scopes, _ in await renewal.renew(refreshToken: token, scopes: scopes) })
    #expect(credentials.accessToken == "renewed-access")
    #expect(await renewal.refreshTokens == ["keychain-refresh"])
  }

  @Test
  func claudeRenewalThatChangesNothingTakesTheFailureBackOff() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent(".credentials.json")
    try Data(
      #"{"claudeAiOauth":{"accessToken":"stale-access","refreshToken":"file-refresh","expiresAt":1799999999000}}"#
        .utf8
    ).write(to: file)
    let renewal = ClaudeRenewalProbe(succeeds: true)
    let ineffective = CallCounter()

    do {
      _ = try await ClaudeCredentialLoader.load(
        environment: [:], allowKeychainRead: true,
        now: Date(timeIntervalSince1970: 1_800_000_000),
        keychainCandidateLoader: { _ in nil },
        keychainItemExists: { false },
        credentialFileURLs: [file],
        renewer: { token, scopes, _ in await renewal.renew(refreshToken: token, scopes: scopes) },
        ineffectiveRenewal: { await ineffective.increment() })
      Issue.record("an unchanged store was reported as a renewed session")
    } catch UsageProviderError.credentialsNotFound {
      // Expected: nothing usable appeared.
    }
    #expect(await renewal.callCount == 1)
    #expect(await ineffective.count == 1)

    // The helper exited zero, so only the reported ineffectiveness keeps it from
    // being relaunched after the ordinary 120-second cooldown.
    let probe = RunnerProbe()
    let renewer = ClaudeSessionRenewer()
    let now = Date()
    let runner: @Sendable (String, [String], [String: String], Duration) async throws -> Void = {
      executable, arguments, environment, timeout in
      try await probe.run(
        executable: executable, arguments: arguments, environment: environment, timeout: timeout)
    }
    #expect(
      await renewer.renew(
        refreshToken: "fixture-refresh", scopes: nil, environment: [:], now: now,
        locator: { _ in "/usr/bin/true" }, runner: runner))
    await renewer.noteIneffectiveRenewal(now: now)
    #expect(
      !(await renewer.renew(
        refreshToken: "fixture-refresh", scopes: nil, environment: [:],
        now: now.addingTimeInterval(121), locator: { _ in "/usr/bin/true" }, runner: runner)))
    #expect(await probe.callCount == 1)
    #expect(
      await renewer.renew(
        refreshToken: "fixture-refresh", scopes: nil, environment: [:],
        now: now.addingTimeInterval(601), locator: { _ in "/usr/bin/true" }, runner: runner))
    #expect(await probe.callCount == 2)
  }

  @Test
  func claudeRejectedTokenTriggersOneRenewalAndOneRetry() async throws {
    let renewal = ClaudeRenewalProbe(succeeds: true)
    let usage = ClaudeUsageProbe(acceptedToken: "renewed-access")
    let payload = Data(
      #"{"five_hour":{"utilization":20,"resets_at":"2033-05-18T03:33:20Z"}}"#.utf8)
    let provider = AnthropicProvider(
      environment: [:],
      allowKeychainRead: true,
      requestHandler: { request in
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
          .replacingOccurrences(of: "Bearer ", with: "")
        let status = await usage.statusCode(for: token)
        return (
          status == 200 ? payload : Data("{}".utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        )
      },
      rateLimitGate: ClaudeRateLimitGate(defaults: nil),
      renewer: { token, scopes, _ in await renewal.renew(refreshToken: token, scopes: scopes) },
      keychainCandidateLoader: { _ in
        let renewed = await renewal.callCount > 0
        let item =
          renewed
          ? #"{"claudeAiOauth":{"accessToken":"renewed-access","refreshToken":"rotated-refresh","expiresAt":4102444800000}}"#
          : #"{"claudeAiOauth":{"accessToken":"rejected-access","refreshToken":"stored-refresh","expiresAt":4102444800000}}"#
        return try ClaudeCredentialLoader.decodeCandidate(
          data: Data(item.utf8), source: "Claude Keychain")
      })

    let snapshot = try await provider.fetch()
    #expect(snapshot.provider == .anthropic)
    #expect(snapshot.windows.first?.usedPercent == 20)
    #expect(await usage.tokens == ["rejected-access", "renewed-access"])
    #expect(await renewal.refreshTokens == ["stored-refresh"])

    // A token that stays rejected does not renew twice or retry twice.
    let stubborn = ClaudeRenewalProbe(succeeds: true)
    let rejected = ClaudeUsageProbe(acceptedToken: "never-accepted")
    let stuckProvider = AnthropicProvider(
      environment: [:],
      allowKeychainRead: true,
      requestHandler: { request in
        let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
          .replacingOccurrences(of: "Bearer ", with: "")
        let status = await rejected.statusCode(for: token)
        return (
          Data("{}".utf8),
          HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        )
      },
      rateLimitGate: ClaudeRateLimitGate(defaults: nil),
      renewer: { token, scopes, _ in await stubborn.renew(refreshToken: token, scopes: scopes) },
      keychainCandidateLoader: { _ in
        let renewed = await stubborn.callCount > 0
        let item =
          renewed
          ? #"{"claudeAiOauth":{"accessToken":"second-access","refreshToken":"rotated-refresh","expiresAt":4102444800000}}"#
          : #"{"claudeAiOauth":{"accessToken":"first-access","refreshToken":"stored-refresh","expiresAt":4102444800000}}"#
        return try ClaudeCredentialLoader.decodeCandidate(
          data: Data(item.utf8), source: "Claude Keychain")
      })
    do {
      _ = try await stuckProvider.fetch()
      Issue.record("a rejected Claude session was reported as connected")
    } catch let error as UsageProviderError {
      guard case .unauthorized(let message) = error else {
        Issue.record("a rejected Claude session was classified as \(error)")
        return
      }
      #expect(message == "Claude sign-in expired. Use Sign in to reconnect.")
    }
    #expect(await rejected.callCount == 2)
    #expect(await stubborn.callCount == 1)
  }
}
