import Foundation

#if canImport(Security)
  import LocalAuthentication
  import Security
#endif

public struct AnthropicProvider: UsageProvider {
  public static let maximumRetryDelay: TimeInterval = 24 * 60 * 60
  public let id: ProviderID = .anthropic
  private let environment: [String: String]
  private let allowKeychainRead: Bool
  private let allowKeychainInteraction: Bool
  private let passiveStatusline: Bool
  private let requestHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let rateLimitGate: ClaudeRateLimitGate
  private let renewer: ClaudeSessionRenewalHook
  private let ineffectiveRenewal: ClaudeIneffectiveRenewalHook
  private let keychainCandidateLoader: ClaudeKeychainCandidateLoader?
  private let credentialFileURLs: [URL]?
  private let accountProfileURL: URL?

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    allowKeychainRead: Bool = false,
    allowKeychainInteraction: Bool = false,
    passiveStatusline: Bool = false,
    session: URLSession? = nil
  ) {
    let session = session ?? ProviderHTTPSession.shared
    self.environment = environment
    self.allowKeychainRead = allowKeychainRead
    self.allowKeychainInteraction = allowKeychainInteraction
    self.passiveStatusline = passiveStatusline
    self.requestHandler = {
      try await ProviderHTTPSession.boundedData(
        for: $0, using: session, maximumBytes: 1_048_576)
    }
    self.rateLimitGate = .shared
    self.renewer = ClaudeSessionRenewer.hook
    self.ineffectiveRenewal = ClaudeSessionRenewer.ineffectiveRenewalHook
    self.keychainCandidateLoader = nil
    self.credentialFileURLs = nil
    self.accountProfileURL = ClaudeAccountProfile.defaultURL(environment: environment)
  }

  /// The renewal and Keychain hooks exist so tests never launch Claude Code or
  /// touch the real Keychain.
  init(
    environment: [String: String],
    allowKeychainRead: Bool,
    allowKeychainInteraction: Bool = false,
    requestHandler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
    rateLimitGate: ClaudeRateLimitGate,
    renewer: ClaudeSessionRenewalHook? = nil,
    ineffectiveRenewal: ClaudeIneffectiveRenewalHook? = nil,
    keychainCandidateLoader: ClaudeKeychainCandidateLoader? = nil,
    credentialFileURLs: [URL]? = nil,
    accountProfileURL: URL? = nil
  ) {
    self.environment = environment
    self.allowKeychainRead = allowKeychainRead
    self.allowKeychainInteraction = allowKeychainInteraction
    self.passiveStatusline = false
    self.requestHandler = requestHandler
    self.rateLimitGate = rateLimitGate
    self.renewer = renewer ?? ClaudeSessionRenewer.hook
    self.ineffectiveRenewal = ineffectiveRenewal ?? ClaudeSessionRenewer.ineffectiveRenewalHook
    self.keychainCandidateLoader = keychainCandidateLoader
    self.credentialFileURLs = credentialFileURLs
    self.accountProfileURL = accountProfileURL
  }

  public func fetch() async throws -> UsageSnapshot {
    if self.passiveStatusline {
      guard let snapshot = ClaudeStatuslineBridge.read(
        cacheURL: ClaudeStatuslineBridge.cacheURL(environment: self.environment))
      else {
        throw UsageProviderError.unavailable(
          "Waiting for Claude Code. Your limits appear after its next response.")
      }
      return snapshot
    }
    if let retryAt = await self.rateLimitGate.activeBlock(), retryAt > Date() {
      throw UsageProviderError.rateLimited(retryAt: retryAt)
    }
    let credentials: ClaudeCredentials
    let response: ClaudeUsageResponse
    do {
      let stored = try await self.loadCredentials()
      do {
        response = try await self.fetchUsage(accessToken: stored.accessToken)
        credentials = stored
      } catch UsageProviderError.unauthorized {
        // The stored token can be rejected before its recorded expiry, for
        // example after Claude Code rotated it elsewhere. Let Claude Code renew
        // its own session once, then retry exactly once.
        let renewed = try await self.renewedCredentials(after: stored)
        response = try await self.fetchUsage(accessToken: renewed.accessToken)
        credentials = renewed
      }
    } catch UsageProviderError.unauthorized where !self.allowKeychainRead {
      #if canImport(Security)
        if ClaudeCredentialLoader.keychainItemExistsWithoutPrompt() {
          throw UsageProviderError.keychainConsentRequired(.anthropic)
        }
      #endif
      throw Self.signInExpired
    }

    var windows: [UsageWindow] = []
    if let fiveHour = response.fiveHour?.window(id: "five-hour", label: "5 hours") {
      windows.append(fiveHour)
    }
    if let sevenDay = response.sevenDay?.window(id: "weekly", label: "Weekly") {
      windows.append(sevenDay)
    }
    if let sonnet = response.sevenDaySonnet?.window(
      id: "sonnet-weekly", label: "Sonnet weekly")
    {
      windows.append(sonnet)
    }
    if let opus = response.sevenDayOpus?.window(id: "opus-weekly", label: "Opus weekly") {
      windows.append(opus)
    }
    if let limits = response.limits {
      for (index, limit) in limits.prefix(28).enumerated() where limit.isActive != false {
        guard let percent = limit.percent,
          let name = limit.scope?.model?.displayName,
          !name.isEmpty
        else { continue }
        // Most scoped limits are weekly; a five-hour one says so in its kind.
        let isFiveHour = limit.kind.map {
          $0.localizedCaseInsensitiveContains("five_hour")
            || $0.localizedCaseInsensitiveContains("5h")
            || $0.localizedCaseInsensitiveContains("session")
        } ?? false
        let modelID = limit.scope?.model?.id ?? "scoped-\(index)"
        let id = isFiveHour ? "\(modelID)-five-hour" : modelID
        if windows.contains(where: { $0.id == id }) { continue }
        windows.append(
          UsageWindow(
            id: id,
            label: isFiveHour ? "\(name) · 5 hours" : "\(name) weekly",
            usedPercent: percent,
            windowMinutes: isFiveHour ? 300 : 10080,
            resetsAt: UsageDateParser.iso8601(limit.resetsAt)))
      }
    }

    guard !windows.isEmpty else {
      throw UsageProviderError.unavailable("Anthropic did not return subscription usage windows.")
    }
    return UsageSnapshot(
      provider: .anthropic,
      planName: ClaudePlanFormatter.plan(from: credentials.subscriptionType)
        ?? ClaudePlanFormatter.plan(from: credentials.rateLimitTier),
      windows: windows,
      source: credentials.source,
      includedSpend: response.extraUsage?.includedSpend,
      details: (self.accountProfileURL.flatMap(ClaudeAccountProfile.load)?.details() ?? [])
        + (response.extraUsage?.isEnabled == false ? [UsageDetail("Extra usage", "Off")] : []))
  }

  static let signInExpired = UsageProviderError.unauthorized(
    "Claude sign-in expired. Use Sign in to reconnect.")

  /// The same explanation for the credential-loading path, which reports a
  /// missing usable session rather than a rejected request.
  static let signInExpiredCredentials = UsageProviderError.credentialsNotFound(
    "Claude sign-in expired. Use Sign in to reconnect.")

  private func loadCredentials() async throws -> ClaudeCredentials {
    try await ClaudeCredentialLoader.load(
      environment: self.environment, allowKeychainRead: self.allowKeychainRead,
      allowKeychainInteraction: self.allowKeychainInteraction,
      keychainCandidateLoader: self.keychainCandidateLoader,
      credentialFileURLs: self.credentialFileURLs,
      renewer: self.renewer,
      ineffectiveRenewal: self.ineffectiveRenewal)
  }

  /// Reserve never performs the refresh grant itself. Claude Code's documented
  /// non-interactive login does it and stores the rotated credential in its own
  /// store, which Reserve then re-reads.
  private func renewedCredentials(
    after credentials: ClaudeCredentials
  ) async throws -> ClaudeCredentials {
    guard let refreshToken = credentials.refreshToken, credentials.canRenew(),
      await self.renewer(refreshToken, credentials.scopes, self.environment)
    else { throw Self.signInExpired }
    guard let renewed = try? await self.loadCredentials(),
      renewed.accessToken != credentials.accessToken
    else {
      // Claude Code reported success without publishing a session Reserve can
      // use. Repeating that on the next refresh would only relaunch the helper.
      await self.ineffectiveRenewal()
      throw Self.signInExpired
    }
    return renewed
  }

  /// A deliberate user refresh is a recovery action: it clears a persisted
  /// backoff so one provider clock or corrupt defaults value cannot disable
  /// Claude checks indefinitely.
  public static func clearPersistedRateLimitBlock() async {
    await ClaudeRateLimitGate.shared.clear()
  }

  /// Detects the item without reading its secret or presenting a prompt.
  public static func keychainCredentialIsAvailableWithoutPrompt() -> Bool {
    #if canImport(Security)
      ClaudeCredentialLoader.keychainItemExistsWithoutPrompt()
    #else
      false
    #endif
  }

  private func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
      throw UsageProviderError.invalidResponse("invalid Anthropic endpoint")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await self.requestHandler(request)
    } catch {
      if let error = error as? URLError, error.code == .timedOut {
        throw UsageProviderError.timedOut("Anthropic usage request")
      }
      throw UsageProviderError.unavailable(
        "Anthropic usage request failed: \(error.localizedDescription)")
    }
    guard let http = response as? HTTPURLResponse else {
      throw UsageProviderError.invalidResponse("missing HTTP status")
    }
    switch http.statusCode {
    case 200:
      await self.rateLimitGate.clear()
    case 401:
      throw Self.signInExpired
    case 403:
      throw UsageProviderError.accessDenied(
        "Anthropic denied access to usage data. Check your Claude account permissions.")
    case 429:
      let retryAt = Self.conservativeRetryDate(
        retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
      await self.rateLimitGate.block(until: retryAt)
      throw UsageProviderError.rateLimited(retryAt: retryAt)
    default:
      throw UsageProviderError.unavailable(
        "Anthropic usage request returned HTTP \(http.statusCode).")
    }
    guard data.count <= 1_048_576 else {
      throw UsageProviderError.invalidResponse("Anthropic response exceeded 1 MB")
    }
    do {
      return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    } catch {
      throw UsageProviderError.invalidResponse(error.localizedDescription)
    }
  }

  static func conservativeRetryDate(retryAfter value: String?, now: Date = Date()) -> Date {
    let minimum = now.addingTimeInterval(15 * 60)
    let maximum = now.addingTimeInterval(Self.maximumRetryDelay)
    guard let value else { return minimum }
    if let seconds = TimeInterval(value), seconds.isFinite {
      return min(maximum, max(minimum, now.addingTimeInterval(max(0, seconds))))
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    guard let providerDate = formatter.date(from: value) else { return minimum }
    return min(maximum, max(minimum, providerDate))
  }
}

actor ClaudeRateLimitGate {
  static let shared = ClaudeRateLimitGate()
  private let defaults: UserDefaults?
  private let key = "anthropic.rateLimitBlockedUntil"
  private var memoryBlock: Date?

  init(defaults: UserDefaults? = UserDefaults(suiteName: "com.pocarles.reserve") ?? .standard) {
    self.defaults = defaults
  }

  func activeBlock(now: Date = Date()) -> Date? {
    let date = self.defaults?.object(forKey: self.key) as? Date ?? self.memoryBlock
    guard let date else { return nil }
    guard date > now, date.timeIntervalSince(now).isFinite,
      date <= now.addingTimeInterval(AnthropicProvider.maximumRetryDelay)
    else {
      self.defaults?.removeObject(forKey: self.key)
      self.memoryBlock = nil
      return nil
    }
    return date
  }

  func block(until date: Date) {
    let now = Date()
    let capped = min(
      max(now, date), now.addingTimeInterval(AnthropicProvider.maximumRetryDelay))
    self.memoryBlock = capped
    self.defaults?.set(capped, forKey: self.key)
  }

  func clear() {
    self.memoryBlock = nil
    self.defaults?.removeObject(forKey: self.key)
  }
}

struct ClaudeCredentials: Sendable {
  let accessToken: String
  let expiresAt: Date?
  let refreshToken: String?
  let refreshTokenExpiresAt: Date?
  let scopes: [String]?
  let subscriptionType: String?
  let rateLimitTier: String?
  let source: String

  func canRenew(now: Date = Date()) -> Bool {
    guard let refreshToken, !refreshToken.isEmpty else { return false }
    guard let refreshTokenExpiresAt else { return true }
    return refreshTokenExpiresAt > now
  }
}

/// Everything one store holds, including a session that can no longer be used
/// as it stands. Renewal decisions need the unusable shape too.
struct ClaudeCredentialCandidate: Sendable {
  let accessToken: String?
  let refreshToken: String?
  let expiresAt: Date?
  let refreshTokenExpiresAt: Date?
  let scopes: [String]?
  let subscriptionType: String?
  let rateLimitTier: String?
  let source: String

  /// A token that expires within the next minute is treated as spent: the
  /// usage request would otherwise race its own expiry.
  func hasUsableAccessToken(now: Date = Date()) -> Bool {
    guard let accessToken, !accessToken.isEmpty else { return false }
    guard let expiresAt else { return true }
    return expiresAt > now.addingTimeInterval(60)
  }

  func canRenew(now: Date = Date()) -> Bool {
    guard let refreshToken, !refreshToken.isEmpty else { return false }
    guard let refreshTokenExpiresAt else { return true }
    return refreshTokenExpiresAt > now
  }

  var credentials: ClaudeCredentials? {
    guard let accessToken, !accessToken.isEmpty else { return nil }
    return ClaudeCredentials(
      accessToken: accessToken,
      expiresAt: self.expiresAt,
      refreshToken: self.refreshToken,
      refreshTokenExpiresAt: self.refreshTokenExpiresAt,
      scopes: self.scopes,
      subscriptionType: self.subscriptionType,
      rateLimitTier: self.rateLimitTier,
      source: self.source)
  }
}

/// Reads one candidate from Claude Code's protected store. `allowInteraction`
/// mirrors `keychainCredentials`.
typealias ClaudeKeychainCandidateLoader =
  @Sendable (Bool) async throws -> ClaudeCredentialCandidate?

/// Asks Claude Code to renew its own session with a refresh token and scopes.
/// Returns whether the helper reported success.
typealias ClaudeSessionRenewalHook =
  @Sendable (String, [String]?, [String: String]) async -> Bool

/// Reports back that a renewal the helper called successful did not produce a
/// session Reserve can use, so it must not be repeated on the next refresh.
typealias ClaudeIneffectiveRenewalHook = @Sendable () async -> Void

enum ClaudeCredentialLoader {
  static func load(
    environment: [String: String],
    allowKeychainRead: Bool,
    allowKeychainInteraction: Bool = false,
    now: Date = Date(),
    keychainCandidateLoader: ClaudeKeychainCandidateLoader? = nil,
    keychainItemExists: (@Sendable () -> Bool)? = nil,
    credentialFileURLs: [URL]? = nil,
    renewer: ClaudeSessionRenewalHook? = nil,
    ineffectiveRenewal: ClaudeIneffectiveRenewalHook? = nil
  ) async throws -> ClaudeCredentials {
    var collected = await self.candidates(
      environment: environment, allowKeychainRead: allowKeychainRead,
      allowKeychainInteraction: allowKeychainInteraction,
      keychainCandidateLoader: keychainCandidateLoader,
      credentialFileURLs: credentialFileURLs)
    // Claude Code writes a completed browser sign-in to its protected store.
    // That store keeps precedence over legacy credential files left behind by
    // an earlier sign-in, which is why collection order decides here.
    if let usable = collected.usableCredentials(now: now) { return usable }

    // The protected store holds the session Claude Code itself uses. When it is
    // present but this pass could not read it, the answer is the user's explicit
    // Allow access: a renewal would land in the same unreadable item, and a
    // browser sign-in would replace the session the CLI is still using.
    let consentIsPending = self.keychainConsentIsPending(
      allowKeychainRead: allowKeychainRead,
      keychainCandidateFound: collected.keychainCandidateFound,
      itemExists: keychainItemExists)

    if !consentIsPending, let renewable = Self.renewalCandidate(in: collected.all, now: now),
      let refreshToken = renewable.refreshToken,
      await (renewer ?? ClaudeSessionRenewer.hook)(
        refreshToken, renewable.scopes, environment)
    {
      collected = await self.candidates(
        environment: environment, allowKeychainRead: allowKeychainRead,
        allowKeychainInteraction: allowKeychainInteraction,
        keychainCandidateLoader: keychainCandidateLoader,
        credentialFileURLs: credentialFileURLs)
      if let usable = collected.usableCredentials(now: now) { return usable }
      // The helper exited successfully and still no usable session appeared.
      // Without this the ordinary cooldown would relaunch it every refresh.
      await (ineffectiveRenewal ?? ClaudeSessionRenewer.ineffectiveRenewalHook)()
    }

    #if canImport(Security)
      if let keychainError = collected.keychainError { throw keychainError }
      if consentIsPending { throw UsageProviderError.keychainConsentRequired(.anthropic) }
    #endif
    guard collected.all.isEmpty else { throw AnthropicProvider.signInExpiredCredentials }
    throw UsageProviderError.credentialsNotFound(
      "Claude OAuth credentials were not found. Use Sign in to authenticate.")
  }

  /// What one pass over the stores found, including whether the protected store
  /// actually answered. A pass that could not read it is not the same as a pass
  /// that read an unusable session out of it.
  private struct CollectedCandidates {
    var all: [ClaudeCredentialCandidate] = []
    var keychainCandidateFound = false
    var keychainError: Error?

    func usableCredentials(now: Date) -> ClaudeCredentials? {
      self.all.first(where: { $0.hasUsableAccessToken(now: now) })?.credentials
    }
  }

  /// Claude Code's own sign-in exists, but this pass holds nothing from it.
  private static func keychainConsentIsPending(
    allowKeychainRead: Bool,
    keychainCandidateFound: Bool,
    itemExists: (@Sendable () -> Bool)? = nil
  ) -> Bool {
    #if canImport(Security)
      guard !allowKeychainRead || !keychainCandidateFound else { return false }
      return itemExists?() ?? self.keychainItemExistsWithoutPrompt()
    #else
      return false
    #endif
  }

  /// Every store that holds something, protected store first.
  private static func candidates(
    environment: [String: String],
    allowKeychainRead: Bool,
    allowKeychainInteraction: Bool,
    keychainCandidateLoader: ClaudeKeychainCandidateLoader?,
    credentialFileURLs: [URL]?
  ) async -> CollectedCandidates {
    var collected = CollectedCandidates()
    let keychainLoader: ClaudeKeychainCandidateLoader?
    #if canImport(Security)
      keychainLoader = keychainCandidateLoader ?? { allowInteraction in
        try await self.keychainCredentials(allowInteraction: allowInteraction)
      }
    #else
      keychainLoader = keychainCandidateLoader
    #endif
    if allowKeychainRead, let keychainLoader {
      do {
        if let candidate = try await keychainLoader(allowKeychainInteraction) {
          collected.all.append(candidate)
          collected.keychainCandidateFound = true
        }
      } catch {
        // A valid file remains a safe fallback when macOS cannot reveal the
        // Keychain item without interaction during a background refresh.
        collected.keychainError = error
      }
    }
    for url in credentialFileURLs ?? self.credentialURLs(environment: environment) {
      if let data = BoundedFileReader.read(url, maximumBytes: 1_048_576),
        let candidate = try? self.decodeCandidate(data: data, source: "Claude OAuth file")
      {
        collected.all.append(candidate)
      }
    }
    return collected
  }

  /// The renewable session with the most recent access-token expiry; the
  /// protected store wins a tie because it is collected first.
  static func renewalCandidate(
    in candidates: [ClaudeCredentialCandidate],
    now: Date
  ) -> ClaudeCredentialCandidate? {
    var best: ClaudeCredentialCandidate?
    for candidate in candidates where candidate.canRenew(now: now) {
      guard let current = best else {
        best = candidate
        continue
      }
      if (candidate.expiresAt ?? .distantPast) > (current.expiresAt ?? .distantPast) {
        best = candidate
      }
    }
    return best
  }

  static func decode(data: Data, source: String, now: Date = Date()) throws -> ClaudeCredentials {
    let candidate = try self.decodeCandidate(data: data, source: source)
    guard let credentials = candidate.credentials else {
      throw UsageProviderError.credentialsNotFound(
        "Claude credentials do not contain a subscription OAuth token.")
    }
    guard candidate.hasUsableAccessToken(now: now) else {
      throw AnthropicProvider.signInExpiredCredentials
    }
    return credentials
  }

  /// Tolerant on purpose: a store can hold blank tokens, omit `scopes` or
  /// `refreshTokenExpiresAt`, and carry unrelated top-level keys such as
  /// `mcpOAuth`. Only unreadable JSON, or a record with neither token, fails.
  static func decodeCandidate(
    data: Data,
    source: String
  ) throws -> ClaudeCredentialCandidate {
    guard let root = try? JSONDecoder().decode(ClaudeCredentialRoot.self, from: data) else {
      throw UsageProviderError.credentialsNotFound(
        "Claude credentials could not be read.")
    }
    let oauth = root.claudeAiOauth ?? root.oauth
    func trimmed(_ value: String?) -> String? {
      let value = value?.trimmingCharacters(in: .whitespacesAndNewlines)
      return value?.isEmpty == false ? value : nil
    }
    func date(_ milliseconds: Double?) -> Date? {
      guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
      return Date(timeIntervalSince1970: milliseconds / 1_000)
    }
    let accessToken = trimmed(oauth?.accessToken)
    let refreshToken = trimmed(oauth?.refreshToken)
    guard accessToken != nil || refreshToken != nil else {
      throw UsageProviderError.credentialsNotFound(
        "Claude credentials do not contain a subscription OAuth token.")
    }
    let scopes = oauth?.scopes?.compactMap(trimmed)
    return ClaudeCredentialCandidate(
      accessToken: accessToken,
      refreshToken: refreshToken,
      expiresAt: date(oauth?.expiresAt),
      refreshTokenExpiresAt: date(oauth?.refreshTokenExpiresAt),
      scopes: scopes?.isEmpty == false ? scopes : nil,
      subscriptionType: oauth?.subscriptionType,
      rateLimitTier: oauth?.rateLimitTier,
      source: source)
  }

  private static func credentialURLs(environment: [String: String]) -> [URL] {
    let fileManager = FileManager.default
    var roots: [URL] = []
    if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
      roots.append(URL(fileURLWithPath: (configured as NSString).expandingTildeInPath))
    }
    roots.append(fileManager.homeDirectoryForCurrentUser.appendingPathComponent(".claude"))
    return roots.map { $0.appendingPathComponent(".credentials.json") }
  }

  #if canImport(Security)
    static func keychainItemExistsWithoutPrompt() -> Bool {
      switch self.keychainProbeStatus() {
      case errSecSuccess, errSecInteractionNotAllowed, errSecInteractionRequired,
        errSecUserCanceled, errSecAuthFailed, errSecNoAccessForItem,
        errSecMissingEntitlement, errSecRestrictedAPI:
        // A protected item can reject this no-prompt probe even though it is
        // present. Treat that as a consent path instead of asking the user to
        // sign in again.
        return true
      default:
        return false
      }
    }

    /// The trusted-tool path is only safe to launch after the metadata probe
    /// itself succeeded without interaction. A locked item still counts as
    /// present for the consent UI but must not start `security -w` in a
    /// background refresh.
    private static func keychainItemIsReadableWithoutPrompt() -> Bool {
      self.keychainProbeStatus() == errSecSuccess
    }

    private static func keychainProbeStatus() -> OSStatus {
      let context = LAContext()
      context.interactionNotAllowed = true
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
        kSecUseAuthenticationContext as String: context,
      ]
      var result: CFTypeRef?
      return SecItemCopyMatching(query as CFDictionary, &result)
    }

    /// Claude Code resets this item's access list to Apple's command-line tools
    /// after each browser sign-in. Reading it directly would therefore ask the
    /// user for the same Keychain approval after every login. The system
    /// `security` executable remains on that access list. Reserve launches it
    /// without a shell and captures its bounded output through a private pipe.
    static func keychainCredentials(
      allowInteraction: Bool = false,
      itemExists: (@Sendable () -> Bool)? = nil,
      securityToolRunner: @escaping @Sendable (
        String, [String], [String: String], Duration
      ) async throws -> String = { executable, arguments, environment, timeout in
        try await ProcessRunner.output(
          executable: executable, arguments: arguments, environment: environment,
          timeout: timeout)
      }
    ) async throws -> ClaudeCredentialCandidate? {
      let itemIsPresent = itemExists?()
        ?? (allowInteraction
          ? self.keychainItemExistsWithoutPrompt()
          : self.keychainItemIsReadableWithoutPrompt())
      guard itemIsPresent else { return nil }
      let output: String
      do {
        let timeout: Duration = allowInteraction ? .seconds(120) : .seconds(3)
        output = try await securityToolRunner(
          "/usr/bin/security",
          ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
          [:], timeout)
      } catch let error as UsageProviderError {
        if case .timedOut = error {
          throw UsageProviderError.unavailable(
            "Reserve could not read the Claude sign-in from Keychain before the request timed out.")
        }
        throw UsageProviderError.keychainConsentRequired(.anthropic)
      } catch {
        throw UsageProviderError.keychainConsentRequired(.anthropic)
      }
      guard let data = output.data(using: .utf8), !data.isEmpty, data.count <= 65_536 else {
        throw UsageProviderError.credentialsNotFound(
          "The Claude Keychain item is larger than Reserve can safely read.")
      }
      do {
        return try self.decodeCandidate(data: data, source: "Claude Keychain")
      } catch {
        throw UsageProviderError.credentialsNotFound(
          "The Claude Keychain item does not contain a usable subscription sign-in.")
      }
    }
  #endif
}

struct ClaudeCredentialRoot: Decodable {
  let claudeAiOauth: ClaudeOAuthCredential?
  let oauth: ClaudeOAuthCredential?
}

struct ClaudeOAuthCredential: Decodable {
  let accessToken: String?
  let expiresAt: Double?
  let rateLimitTier: String?
  let subscriptionType: String?
  let refreshToken: String?
  let refreshTokenExpiresAt: Double?
  let scopes: [String]?
}

/// Runs Claude Code's documented non-interactive refresh-token login. Claude
/// Code owns the grant and the rotated credential; Reserve only starts it.
/// Attempts are serialised, rate limited, and backed off after a failure so a
/// revoked session cannot turn every refresh into a helper launch.
actor ClaudeSessionRenewer {
  static let shared = ClaudeSessionRenewer()
  static let defaultScopes = [
    "user:file_upload", "user:inference", "user:mcp_servers", "user:profile",
    "user:sessions:claude_code",
  ]
  static let timeout: Duration = .seconds(60)
  static let cooldown: TimeInterval = 120
  static let failureBackoff: TimeInterval = 600
  private var lastAttemptAt: Date?
  private var lastFailureAt: Date?

  /// The hooks the providers use by default.
  static let hook: ClaudeSessionRenewalHook = { refreshToken, scopes, environment in
    await ClaudeSessionRenewer.shared.renew(
      refreshToken: refreshToken, scopes: scopes, environment: environment)
  }

  static let ineffectiveRenewalHook: ClaudeIneffectiveRenewalHook = {
    await ClaudeSessionRenewer.shared.noteIneffectiveRenewal()
  }

  /// Claude Code exiting zero is not proof that a usable session was stored.
  /// An attempt the caller could not observe counts as a failure, so it takes
  /// the ten-minute back-off instead of the ordinary cooldown.
  func noteIneffectiveRenewal(now: Date = Date()) {
    self.lastFailureAt = now
  }

  func renew(
    refreshToken: String,
    scopes: [String]?,
    environment: [String: String],
    now: Date = Date(),
    locator: @Sendable ([String: String]) -> String? = {
      BinaryLocator.find("claude", environment: $0)
    },
    runner: @Sendable (String, [String], [String: String], Duration) async throws -> Void = {
      executable, arguments, environment, timeout in
      _ = try await ProcessRunner.output(
        executable: executable, arguments: arguments, environment: environment,
        standardInput: FileHandle.nullDevice, timeout: timeout)
    }
  ) async -> Bool {
    if Self.isWithin(Self.failureBackoff, of: self.lastFailureAt, now: now) { return false }
    if Self.isWithin(Self.cooldown, of: self.lastAttemptAt, now: now) { return false }
    guard let executable = locator(environment) else { return false }
    self.lastAttemptAt = now
    // This login must stay non-interactive, and it is Reserve's own initiative
    // rather than a command the user typed. The allowlisted environment leaves
    // out unrelated API keys along with any browser handoff or Reserve login
    // pipe, no stdin is inherited, and the output is never read.
    var childEnvironment = BinaryLocator.minimalChildEnvironment(
      from: environment, keeping: ["CLAUDE_CONFIG_DIR"])
    childEnvironment["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"] = refreshToken
    childEnvironment["CLAUDE_CODE_OAUTH_SCOPES"] =
      (scopes?.isEmpty == false ? scopes! : Self.defaultScopes).joined(separator: " ")
    do {
      try await runner(
        executable, ["auth", "login", "--claudeai"], childEnvironment, Self.timeout)
      self.lastFailureAt = nil
      return true
    } catch {
      self.lastFailureAt = now
      return false
    }
  }

  private static func isWithin(_ interval: TimeInterval, of date: Date?, now: Date) -> Bool {
    guard let date else { return false }
    let elapsed = now.timeIntervalSince(date)
    return elapsed >= 0 && elapsed < interval
  }
}

enum ClaudePlanFormatter {
  static func plan(from tier: String?) -> String? {
    guard let tier else { return nil }
    let trimmed = tier.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.lowercased()
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: " ", with: "_")
    if normalized.contains("max_20") || normalized.contains("max20") { return "Max 20x" }
    if normalized.contains("max_5") || normalized.contains("max5") { return "Max 5x" }
    if normalized.contains("max") { return "Max" }
    if normalized.contains("enterprise") { return "Enterprise" }
    if normalized.contains("team") { return "Team" }
    if normalized.contains("pro") { return "Pro" }
    if normalized.contains("free") { return "Free" }
    return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
  }
}

struct ClaudeUsageResponse: Decodable, Sendable {
  let fiveHour: ClaudeUsageWindow?
  let sevenDay: ClaudeUsageWindow?
  let sevenDaySonnet: ClaudeUsageWindow?
  let sevenDayOpus: ClaudeUsageWindow?
  let limits: [ClaudeLimit]?
  let extraUsage: ClaudeExtraUsage?

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDaySonnet = "seven_day_sonnet"
    case sevenDayOpus = "seven_day_opus"
    case limits
    case extraUsage = "extra_usage"
  }
}

struct ClaudeExtraUsage: Decodable, Sendable {
  let isEnabled: Bool?
  let monthlyLimit: Int?
  let usedCredits: Int?

  enum CodingKeys: String, CodingKey {
    case isEnabled = "is_enabled"
    case monthlyLimit = "monthly_limit"
    case usedCredits = "used_credits"
  }

  var includedSpend: IncludedSpend? {
    guard self.isEnabled != false, let usedCredits, let monthlyLimit, monthlyLimit > 0 else {
      return nil
    }
    return IncludedSpend(
      label: "Extra usage", usedMinorUnits: usedCredits, limitMinorUnits: monthlyLimit)
  }
}

struct ClaudeUsageWindow: Decodable, Sendable {
  let utilization: Double?
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }

  func window(id: String, label: String) -> UsageWindow? {
    guard let utilization else { return nil }
    return UsageWindow(
      id: id,
      label: label,
      usedPercent: utilization,
      windowMinutes: id == "five-hour" ? 300 : 10080,
      resetsAt: UsageDateParser.iso8601(self.resetsAt))
  }
}

struct ClaudeLimit: Decodable, Sendable {
  let percent: Double?
  let resetsAt: String?
  let scope: ClaudeLimitScope?
  let isActive: Bool?
  let kind: String?

  enum CodingKeys: String, CodingKey {
    case kind
    case percent
    case resetsAt = "resets_at"
    case scope
    case isActive = "is_active"
  }
}

struct ClaudeLimitScope: Decodable, Sendable {
  let model: ClaudeLimitModel?
}

struct ClaudeLimitModel: Decodable, Sendable {
  let id: String?
  let displayName: String?

  enum CodingKeys: String, CodingKey {
    case id
    case displayName = "display_name"
  }
}

/// The account Claude Code signed in with, from its own settings file. Only
/// these few display fields are read; tokens never live in this file.
struct ClaudeAccountProfile: Decodable, Sendable {
  let emailAddress: String?
  let organizationName: String?
  let organizationType: String?
  let organizationRole: String?
  let subscriptionCreatedAt: String?
  let claudeCodeTrialEndsAt: String?

  private struct Settings: Decodable { let oauthAccount: ClaudeAccountProfile? }

  static func defaultURL(environment: [String: String]) -> URL {
    if let configured = environment["CLAUDE_CONFIG_DIR"], !configured.isEmpty {
      return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
        .appendingPathComponent(".claude.json")
    }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
  }

  static func load(from url: URL) -> ClaudeAccountProfile? {
    guard let data = BoundedFileReader.read(url, maximumBytes: 16 * 1_048_576) else { return nil }
    return (try? JSONDecoder().decode(Settings.self, from: data))?.oauthAccount
  }

  func details(now: Date = Date()) -> [UsageDetail] {
    var details: [UsageDetail] = []
    if let email = self.emailAddress { details.append(UsageDetail("Account", email)) }
    // A personal account's organization is just the person's own name again.
    if let name = self.organizationName, !name.isEmpty,
      // Consumer plans (claude_pro, claude_max) sit in an automatic
      // one-person organization named after the account.
      !(self.organizationType?.lowercased().hasPrefix("claude_") ?? false),
      !name.localizedCaseInsensitiveContains("'s Organization")
    {
      let role = self.organizationRole.map { " · \($0.replacingOccurrences(of: "_", with: " ").capitalized)" } ?? ""
      details.append(UsageDetail("Organization", name + role))
    }
    if let created = UsageDateParser.iso8601(self.subscriptionCreatedAt) {
      details.append(UsageDetail("Subscribed since", UsageDetailFormat.date(created)))
    }
    if let trialEnd = UsageDateParser.iso8601(self.claudeCodeTrialEndsAt), trialEnd > now {
      details.append(UsageDetail("Trial ends", UsageDetailFormat.date(trialEnd)))
    }
    return details
  }
}
