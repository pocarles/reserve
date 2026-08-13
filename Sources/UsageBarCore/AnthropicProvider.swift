import Foundation

#if canImport(Security)
  import LocalAuthentication
  import Security
#endif

public struct AnthropicProvider: UsageProvider {
  public let id: ProviderID = .anthropic
  private let environment: [String: String]
  private let allowKeychainRead: Bool
  private let session: URLSession

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    allowKeychainRead: Bool = false,
    session: URLSession = .shared
  ) {
    self.environment = environment
    self.allowKeychainRead = allowKeychainRead
    self.session = session
  }

  public func fetch() async throws -> UsageSnapshot {
    let credentials = try ClaudeCredentialLoader.load(
      environment: self.environment,
      allowKeychainRead: self.allowKeychainRead)
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
        "Claude authentication expired. Run `claude login` and refresh.")
    }

    var windows: [UsageWindow] = []
    if let fiveHour = response.fiveHour {
      windows.append(fiveHour.window(id: "five-hour", label: "5 hours"))
    }
    if let sevenDay = response.sevenDay {
      windows.append(sevenDay.window(id: "weekly", label: "Weekly"))
    }
    if let sonnet = response.sevenDaySonnet {
      windows.append(sonnet.window(id: "sonnet-weekly", label: "Sonnet weekly"))
    }
    if let opus = response.sevenDayOpus {
      windows.append(opus.window(id: "opus-weekly", label: "Opus weekly"))
    }
    if let limits = response.limits {
      for (index, limit) in limits.enumerated() where limit.isActive != false {
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
      planName: credentials.subscriptionType
        ?? ClaudePlanFormatter.plan(from: credentials.rateLimitTier),
      accountLabel: nil,
      windows: windows,
      source: credentials.source)
  }

  private func fetchUsage(accessToken: String) async throws -> ClaudeUsageResponse {
    if let retryAt = await ClaudeRateLimitGate.shared.blockedUntil, retryAt > Date() {
      throw UsageProviderError.rateLimited(retryAt: retryAt)
    }
    guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else {
      throw UsageProviderError.invalidResponse("invalid Anthropic endpoint")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

    let (data, response): (Data, URLResponse)
    do {
      (data, response) = try await self.session.data(for: request)
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
      await ClaudeRateLimitGate.shared.clear()
    case 401:
      throw UsageProviderError.unauthorized(
        "Claude authentication expired. Run `claude login` and refresh.")
    case 429:
      let retryAt = Self.retryDate(from: http) ?? Date().addingTimeInterval(15 * 60)
      await ClaudeRateLimitGate.shared.block(until: retryAt)
      throw UsageProviderError.rateLimited(retryAt: retryAt)
    default:
      throw UsageProviderError.unavailable(
        "Anthropic usage request returned HTTP \(http.statusCode).")
    }
    do {
      return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
    } catch {
      throw UsageProviderError.invalidResponse(error.localizedDescription)
    }
  }

  private static func retryDate(from response: HTTPURLResponse) -> Date? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    if let seconds = TimeInterval(value) { return Date().addingTimeInterval(max(0, seconds)) }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
    return formatter.date(from: value)
  }
}

actor ClaudeRateLimitGate {
  static let shared = ClaudeRateLimitGate()
  private(set) var blockedUntil: Date?

  func block(until date: Date) { self.blockedUntil = date }
  func clear() { self.blockedUntil = nil }
}

struct ClaudeCredentials: Sendable {
  let accessToken: String
  let subscriptionType: String?
  let rateLimitTier: String?
  let source: String
}

enum ClaudeCredentialLoader {
  static func load(environment: [String: String], allowKeychainRead: Bool) throws
    -> ClaudeCredentials
  {
    #if canImport(Security)
      if allowKeychainRead,
        let data = try self.keychainDataWithoutPrompt(),
        let credentials = try? self.decode(data: data, source: "Claude Keychain")
      {
        return credentials
      }
    #endif

    for url in self.credentialURLs(environment: environment) {
      if let data = try? Data(contentsOf: url),
        let credentials = try? self.decode(data: data, source: "Claude OAuth file")
      {
        return credentials
      }
    }

    #if canImport(Security)
      if !allowKeychainRead && self.keychainItemExistsWithoutPrompt() {
        throw UsageProviderError.keychainConsentRequired
      }
    #endif
    throw UsageProviderError.credentialsNotFound(
      "Claude OAuth credentials were not found. Run `claude login` first.")
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

    private static func keychainDataWithoutPrompt() throws -> Data? {
      let context = LAContext()
      context.interactionNotAllowed = true
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "Claude Code-credentials",
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
        kSecUseAuthenticationContext as String: context,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      switch status {
      case errSecSuccess: return result as? Data
      case errSecItemNotFound, errSecInteractionNotAllowed: return nil
      default:
        throw UsageProviderError.unavailable("Claude Keychain read failed with status \(status).")
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
    if tier.localizedCaseInsensitiveContains("max_20") { return "Max 20x" }
    if tier.localizedCaseInsensitiveContains("max_5") { return "Max 5x" }
    if tier.localizedCaseInsensitiveContains("max") { return "Max" }
    if tier.localizedCaseInsensitiveContains("pro") { return "Pro" }
    if tier.localizedCaseInsensitiveContains("team") { return "Team" }
    return tier
  }
}

struct ClaudeUsageResponse: Decodable, Sendable {
  let fiveHour: ClaudeUsageWindow?
  let sevenDay: ClaudeUsageWindow?
  let sevenDaySonnet: ClaudeUsageWindow?
  let sevenDayOpus: ClaudeUsageWindow?
  let limits: [ClaudeLimit]?

  enum CodingKeys: String, CodingKey {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
    case sevenDaySonnet = "seven_day_sonnet"
    case sevenDayOpus = "seven_day_opus"
    case limits
  }
}

struct ClaudeUsageWindow: Decodable, Sendable {
  let utilization: Double?
  let resetsAt: String?

  enum CodingKeys: String, CodingKey {
    case utilization
    case resetsAt = "resets_at"
  }

  func window(id: String, label: String) -> UsageWindow {
    UsageWindow(
      id: id,
      label: label,
      usedPercent: self.utilization ?? 0,
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
