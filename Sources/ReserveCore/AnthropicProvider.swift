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
  private let requestHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let rateLimitGate: ClaudeRateLimitGate

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    allowKeychainRead: Bool = false,
    allowKeychainInteraction: Bool = false,
    session: URLSession? = nil
  ) {
    let session = session ?? ProviderHTTPSession.shared
    self.environment = environment
    self.allowKeychainRead = allowKeychainRead
    self.allowKeychainInteraction = allowKeychainInteraction
    self.requestHandler = {
      try await ProviderHTTPSession.boundedData(
        for: $0, using: session, maximumBytes: 1_048_576)
    }
    self.rateLimitGate = .shared
  }

  init(
    environment: [String: String],
    allowKeychainRead: Bool,
    allowKeychainInteraction: Bool = false,
    requestHandler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
    rateLimitGate: ClaudeRateLimitGate
  ) {
    self.environment = environment
    self.allowKeychainRead = allowKeychainRead
    self.allowKeychainInteraction = allowKeychainInteraction
    self.requestHandler = requestHandler
    self.rateLimitGate = rateLimitGate
  }

  public func fetch() async throws -> UsageSnapshot {
    if let retryAt = await self.rateLimitGate.activeBlock(), retryAt > Date() {
      throw UsageProviderError.rateLimited(retryAt: retryAt)
    }
    let credentials = try await ClaudeCredentialLoader.load(
      environment: self.environment, allowKeychainRead: self.allowKeychainRead,
      allowKeychainInteraction: self.allowKeychainInteraction)
    let response: ClaudeUsageResponse
    do {
      response = try await self.fetchUsage(accessToken: credentials.accessToken)
    } catch UsageProviderError.unauthorized where !self.allowKeychainRead {
      #if canImport(Security)
        if ClaudeCredentialLoader.keychainItemExistsWithoutPrompt() {
          throw UsageProviderError.keychainConsentRequired
        }
      #endif
      throw UsageProviderError.unauthorized(
        "Claude authentication expired. Use Sign in to authenticate again.")
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
        let id = limit.scope?.model?.id ?? "scoped-\(index)"
        if windows.contains(where: { $0.id == id }) { continue }
        windows.append(
          UsageWindow(
            id: id,
            label: "\(name) weekly",
            usedPercent: percent,
            windowMinutes: 10080,
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
      includedSpend: response.extraUsage?.includedSpend)
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
      throw UsageProviderError.unauthorized(
        "Claude authentication expired. Use Sign in to authenticate again.")
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
  let subscriptionType: String?
  let rateLimitTier: String?
  let source: String
}

enum ClaudeCredentialLoader {
  static func load(
    environment: [String: String],
    allowKeychainRead: Bool,
    allowKeychainInteraction: Bool = false
  ) async throws -> ClaudeCredentials {
    for url in self.credentialURLs(environment: environment) {
      if let data = BoundedFileReader.read(url, maximumBytes: 1_048_576),
        let credentials = try? self.decode(data: data, source: "Claude OAuth file")
      {
        return credentials
      }
    }

    #if canImport(Security)
      if allowKeychainRead,
        let credentials = try await self.keychainCredentials(
          allowInteraction: allowKeychainInteraction)
      {
        return credentials
      }
      if self.keychainItemExistsWithoutPrompt() {
        throw UsageProviderError.keychainConsentRequired
      }
    #endif
    throw UsageProviderError.credentialsNotFound(
      "Claude OAuth credentials were not found. Use Sign in to authenticate.")
  }

  static func decode(data: Data, source: String) throws -> ClaudeCredentials {
    let root = try JSONDecoder().decode(ClaudeCredentialRoot.self, from: data)
    let oauth = root.claudeAiOauth ?? root.oauth
    guard let token = oauth?.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else {
      throw UsageProviderError.credentialsNotFound(
        "Claude credentials do not contain a subscription OAuth token.")
    }
    return ClaudeCredentials(
      accessToken: token,
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
      return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    }

    /// Reads the secret through Security.framework rather than by shelling out
    /// to `/usr/bin/security -w`.
    ///
    /// The old path spawned a child process that printed another application's
    /// OAuth token on its stdout on every refresh, and attributed the access to
    /// `security` rather than to Reserve. `SecItemCopyMatching` keeps the secret
    /// in this process's memory and lets macOS attribute the access honestly.
    private static func keychainCredentials(allowInteraction: Bool) async throws
      -> ClaudeCredentials?
    {
      let context = LAContext()
      context.interactionNotAllowed = !allowInteraction
      if allowInteraction {
        context.localizedReason =
          "Reserve needs read-only access to show your Claude plan limits."
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
        kSecUseAuthenticationContext as String: context,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecItemNotFound { return nil }
      if status == errSecInteractionNotAllowed || status == errSecUserCanceled
        || status == errSecAuthFailed
      {
        throw UsageProviderError.keychainConsentRequired
      }
      guard status == errSecSuccess, let data = result as? Data else {
        throw UsageProviderError.credentialsNotFound(
          "Reserve could not read the Claude sign-in from Keychain.")
      }
      guard data.count <= 1_048_576 else {
        throw UsageProviderError.credentialsNotFound(
          "The Claude Keychain item is larger than Reserve can safely read.")
      }
      do {
        return try self.decode(data: data, source: "Claude Keychain")
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
  let rateLimitTier: String?
  let subscriptionType: String?
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

  enum CodingKeys: String, CodingKey {
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
