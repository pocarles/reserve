import Foundation

public struct GrokProvider: UsageProvider {
  public let id: ProviderID = .grok
  private let environment: [String: String]
  private let renewer: @Sendable (String, [String: String]) async -> Void
  private let locator: @Sendable ([String: String]) -> String?
  private let versionProbe: @Sendable (String) async throws -> SemanticVersion
  private let requestHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    session: URLSession? = nil
  ) {
    self.init(environment: environment, session: session, renewer: nil)
  }

  /// The renewal, lookup, version and request hooks exist so tests never launch
  /// the real CLI or reach the network.
  init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    session: URLSession? = nil,
    renewer: (@Sendable (String, [String: String]) async -> Void)?,
    executableLocator: (@Sendable ([String: String]) -> String?)? = nil,
    versionProbe: (@Sendable (String) async throws -> SemanticVersion)? = nil,
    requestHandler: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil
  ) {
    let session = session ?? ProviderHTTPSession.shared
    self.environment = environment
    self.renewer = renewer ?? { executable, environment in
      await GrokSessionRenewer.shared.renew(executable: executable, environment: environment)
    }
    self.locator = executableLocator ?? { BinaryLocator.find("grok", environment: $0) }
    self.versionProbe = versionProbe ?? { executable in
      try await GrokVersionCache.shared.version(executable: executable) {
        try await ProcessRunner.output(executable: executable, arguments: ["--version"],
          environment: BinaryLocator.childEnvironment(environment))
      }
    }
    self.requestHandler = requestHandler ?? {
      try await ProviderHTTPSession.boundedData(
        for: $0, using: session, maximumBytes: 1_048_576)
    }
  }

  public func fetch() async throws -> UsageSnapshot {
    guard let executable = self.locator(self.environment) else {
      throw UsageProviderError.executableNotFound("Grok Build CLI")
    }
    let version = try await self.versionProbe(executable)

    // A stored access token lives six hours and is renewed only when the CLI
    // itself runs. Ask the CLI to renew first, rather than reporting a working
    // sign-in as lost every few hours.
    let credentials = try await self.currentCredentials(executable: executable)
    async let remoteTier = self.fetchSubscriptionTier(
      version: version.headerValue, credentials: credentials)
    let response: GrokBillingEnvelope
    var billingCredentials = credentials
    do {
      response = try await self.fetchThroughOfficialCLIProxy(
        version: version.headerValue, credentials: credentials)
    } catch UsageProviderError.unauthorized {
      (response, billingCredentials) = try await self.fetchAfterRejectedToken(
        version: version.headerValue, credentials: credentials, executable: executable)
    }
    var fetchedTier = await remoteTier
    if billingCredentials.key != credentials.key {
      // The parallel lookup used a token the billing endpoint then rejected, so
      // its answer may describe nothing at all. Ask again with the credential
      // that actually produced these numbers.
      fetchedTier = await self.fetchSubscriptionTier(
        version: version.headerValue, credentials: billingCredentials)
    }

    guard let config = response.config ?? response.legacyConfig else {
      throw UsageProviderError.unavailable("Grok did not return personal subscription usage.")
    }
    guard let percent = config.usedPercent else {
      if config.isUnifiedBillingUser == true {
        throw UsageProviderError.unavailable(
          "Grok's billing service omitted the weekly usage percentage for this unified billing account."
        )
      }
      throw UsageProviderError.unavailable("Grok billing did not include a usage percentage.")
    }

    let period = config.currentPeriod
    let minutes: Int? = {
      guard let start = UsageDateParser.iso8601(period?.start ?? config.billingPeriodStart),
        let end = UsageDateParser.iso8601(period?.end ?? config.billingPeriodEnd), end > start
      else { return nil }
      let value = end.timeIntervalSince(start) / 60
      guard value.isFinite, value >= 1,
        value <= Double(UsageWindow.maximumWindowMinutes)
      else { return nil }
      return Int(value)
    }()
    let label = Self.periodLabel(type: period?.type, minutes: minutes)

    let reset = UsageDateParser.iso8601(period?.end ?? config.billingPeriodEnd)
    let isMonthlyBillingPeriod = Self.isMonthlyBillingPeriod(
      type: period?.type,
      minutes: minutes)
    var windows = [
      UsageWindow(
        id: "usage-pool",
        label: label,
        usedPercent: percent,
        windowMinutes: minutes,
        resetsAt: reset)
    ]
    for product in (config.productUsage ?? []).prefix(31) where product.usagePercent > 0 {
      windows.append(
        UsageWindow(
          id: "product-\(product.product.lowercased())",
          label: Self.productLabel(product.product),
          usedPercent: product.usagePercent,
          windowMinutes: minutes,
          resetsAt: reset))
    }

    return UsageSnapshot(
      provider: .grok,
      planName: GrokPlanFormatter.plan(from: fetchedTier ?? response.subscriptionTier),
      windows: windows,
      source: "Grok Build billing API",
      includedSpend: config.includedSpend,
      billingRenewsAt: isMonthlyBillingPeriod ? reset : nil)
  }

  private static func isMonthlyBillingPeriod(type: String?, minutes: Int?) -> Bool {
    if type?.localizedCaseInsensitiveContains("monthly") == true { return true }
    guard let minutes else { return false }
    return (27 * 24 * 60)...(32 * 24 * 60) ~= minutes
  }

  /// Reserve never performs the refresh-token exchange itself: the CLI rotates
  /// its refresh token, and a half-finished rotation started by another process
  /// orphans the saved session. `grok models` is a public, headless command that
  /// makes the CLI renew and rewrite its own auth.json.
  private func currentCredentials(
    executable: String,
    now: Date = Date()
  ) async throws -> GrokCredentials {
    let candidate = try GrokCredentialLoader.load(environment: self.environment, now: now)
    guard let expiresAt = candidate.expiresAt,
      expiresAt <= now.addingTimeInterval(GrokCredentialLoader.earlyRenewalWindow)
    else { return candidate.credentials }
    guard candidate.canRenew else { throw Self.signInExpired }
    await self.renewer(executable, self.environment)
    guard let renewed = try? GrokCredentialLoader.load(environment: self.environment, now: now),
      renewed.expiresAt.map({ $0 > now }) ?? true
    else { throw Self.signInExpired }
    return renewed.credentials
  }

  /// A rejected token is first explained by another Grok client having renewed
  /// the session already. Only when the stored token is unchanged does Reserve
  /// ask the CLI to renew, and it retries at most once either way. Every step
  /// stays inside the account whose token was rejected: if the stored session
  /// now belongs to somebody else, Reserve reports an expired sign-in instead of
  /// renewing and reading another account's usage.
  private func fetchAfterRejectedToken(
    version: String,
    credentials: GrokCredentials,
    executable: String,
    now: Date = Date()
  ) async throws -> (GrokBillingEnvelope, GrokCredentials) {
    guard let reread = try? GrokCredentialLoader.load(environment: self.environment, now: now),
      reread.credentials.userID == credentials.userID
    else { throw Self.signInExpired }
    if reread.credentials.key != credentials.key {
      // Another running Grok client renewed this same account while the request
      // was in flight. Adopt its token once without starting anything.
      return (
        try await self.fetchThroughOfficialCLIProxy(
          version: version, credentials: reread.credentials),
        reread.credentials
      )
    }
    guard reread.canRenew else { throw Self.signInExpired }
    await self.renewer(executable, self.environment)
    guard let renewed = try? GrokCredentialLoader.load(environment: self.environment, now: now),
      renewed.credentials.userID == credentials.userID,
      renewed.credentials.key != credentials.key
    else { throw Self.signInExpired }
    return (
      try await self.fetchThroughOfficialCLIProxy(
        version: version, credentials: renewed.credentials),
      renewed.credentials
    )
  }

  static let signInExpired = UsageProviderError.unauthorized(
    "Grok sign-in expired. Use Sign in to reconnect.")

  private func fetchThroughOfficialCLIProxy(
    version: String,
    credentials: GrokCredentials
  ) async throws -> GrokBillingEnvelope {
    // Grok Build 1.x does not expose x.ai/billing through its ACP agent. Calling
    // that method first starts a large, short-lived agent only to receive
    // "method not found". Use the authenticated billing request implemented by
    // the official CLI directly instead.
    guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits") else {
      throw UsageProviderError.invalidResponse("invalid Grok CLI proxy endpoint")
    }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(credentials.key)", forHTTPHeaderField: "Authorization")
    request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
    request.setValue(credentials.userID, forHTTPHeaderField: "x-userid")
    request.setValue(version, forHTTPHeaderField: "x-grok-client-version")
    request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, urlResponse): (Data, URLResponse)
    do {
      (data, urlResponse) = try await self.requestHandler(request)
    } catch {
      if let error = error as? URLError, error.code == .timedOut {
        throw UsageProviderError.timedOut("Grok billing request")
      }
      throw UsageProviderError.unavailable(
        "Grok billing request failed: \(error.localizedDescription)")
    }
    guard let http = urlResponse as? HTTPURLResponse else {
      throw UsageProviderError.invalidResponse("missing Grok HTTP status")
    }
    switch http.statusCode {
    case 200: break
    case 401:
      throw Self.signInExpired
    case 403:
      throw UsageProviderError.accessDenied(
        "Grok denied access to billing data. Check your Grok account permissions.")
    default:
      throw UsageProviderError.unavailable("Grok billing request returned HTTP \(http.statusCode).")
    }
    guard data.count <= 1_048_576 else {
      throw UsageProviderError.invalidResponse("Grok response exceeded 1 MB")
    }
    do {
      return try JSONDecoder().decode(GrokBillingEnvelope.self, from: data)
    } catch {
      throw UsageProviderError.invalidResponse(error.localizedDescription)
    }
  }

  /// The credits response does not carry the account tier. Grok's own billing
  /// extension enriches it from the authenticated `/settings` response, so the
  /// direct lightweight path performs the same optional lookup in parallel.
  private func fetchSubscriptionTier(
    version: String,
    credentials: GrokCredentials
  ) async -> String? {
    guard let url = URL(string: "https://cli-chat-proxy.grok.com/v1/settings") else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(credentials.key)", forHTTPHeaderField: "Authorization")
    request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
    request.setValue(credentials.userID, forHTTPHeaderField: "x-userid")
    request.setValue(version, forHTTPHeaderField: "x-grok-client-version")
    request.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
    request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    do {
      let (data, response) = try await self.requestHandler(request)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let settings = try? JSONDecoder().decode(GrokRemoteSettings.self, from: data)
      else { return nil }
      let tier = (settings.subscriptionTierDisplay ?? settings.subscriptionTier)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
      return tier?.isEmpty == false ? tier : nil
    } catch {
      return nil
    }
  }

  private static func periodLabel(type: String?, minutes: Int?) -> String {
    if type?.localizedCaseInsensitiveContains("weekly") == true { return "Weekly" }
    if type?.localizedCaseInsensitiveContains("monthly") == true { return "Monthly" }
    if let minutes, (6 * 24 * 60)...(8 * 24 * 60) ~= minutes { return "Weekly" }
    if let minutes, (27 * 24 * 60)...(32 * 24 * 60) ~= minutes { return "Monthly" }
    return "Usage pool"
  }

  private static func productLabel(_ product: String) -> String {
    switch product.lowercased() {
    case "grokbuild": return "Grok Build share"
    case "grokchat": return "Grok Chat share"
    default: return product + " share"
    }
  }
}

/// Re-probe only when the executable changes. Nothing about the account is
/// cached here, and the cache remains bounded across helper replacements.
actor GrokVersionCache {
  static let shared = GrokVersionCache()
  private struct Stamp: Equatable {
    let inode: UInt64?
    let bytes: UInt64?
    let modified: Date?
  }
  private var entries: [String: (stamp: Stamp, version: SemanticVersion)] = [:]

  func version(executable: String, loader: @Sendable () async throws -> String) async throws -> SemanticVersion {
    let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath().path
    let attributes = try FileManager.default.attributesOfItem(atPath: resolved)
    let stamp = Stamp(inode: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value,
      bytes: (attributes[.size] as? NSNumber)?.uint64Value,
      modified: attributes[.modificationDate] as? Date)
    if let entry = entries[resolved], entry.stamp == stamp { return entry.version }
    let output = try await loader()
    guard let version = SemanticVersion.first(in: output), version >= SemanticVersion(1, 0, 0) else {
      throw UsageProviderError.updateRequired("Grok Build 1.0.0 or newer is required for background billing access.")
    }
    if entries.count >= 8 { entries.removeAll(keepingCapacity: true) }
    entries[resolved] = (stamp, version)
    return version
  }
}

enum GrokPlanFormatter {
  static func plan(from value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")
    if normalized.contains("heavy") { return "SuperGrok Heavy" }
    if normalized.contains("supergrok") { return "SuperGrok" }
    if normalized.contains("premiumplus") || normalized.contains("premium+") {
      return "X Premium+"
    }
    if normalized.contains("premium") { return "X Premium" }
    return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
  }
}

struct GrokCredentials: Sendable {
  let key: String
  let userID: String
}

/// The stored entry Reserve would use, together with what it can still do
/// about an expiry. `canRenew` means the CLI kept a refresh token, so asking it
/// to renew is worthwhile.
struct GrokCredentialCandidate: Sendable {
  let credentials: GrokCredentials
  let expiresAt: Date?
  let canRenew: Bool
}

enum GrokCredentialLoader {
  /// The CLI's own `GROK_AUTH_EARLY_INVALIDATION_SECS` default: it treats a
  /// token inside this window as already expired and renews it.
  static let earlyRenewalWindow: TimeInterval = 300

  /// The CLI resolves its credential file from `GROK_AUTH_PATH` first, then
  /// `GROK_HOME`, then the home directory.
  static func authFileURL(environment: [String: String]) -> URL {
    if let configured = environment["GROK_AUTH_PATH"], !configured.isEmpty {
      return URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    }
    let root: URL
    if let configured = environment["GROK_HOME"], !configured.isEmpty {
      root = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    } else {
      root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }
    return root.appendingPathComponent("auth.json")
  }

  static func load(
    environment: [String: String],
    now: Date = Date()
  ) throws -> GrokCredentialCandidate {
    let url = self.authFileURL(environment: environment)
    guard let data = BoundedFileReader.read(url, maximumBytes: 1_048_576),
      let entries = try? JSONDecoder().decode([String: GrokCredentialEntry].self, from: data)
    else {
      throw UsageProviderError.credentialsNotFound(
        "Grok credentials were not found. Use Sign in to connect Grok.")
    }
    guard let candidate = self.candidate(entries: entries, now: now) else {
      throw GrokProvider.signInExpired
    }
    return candidate
  }

  /// Prefers a usable entry with today's ordering, and otherwise reports the
  /// most recent expired entry so the caller can decide whether to renew.
  static func candidate(
    entries: [String: GrokCredentialEntry],
    now: Date
  ) -> GrokCredentialCandidate? {
    let ordered = entries.sorted { lhs, rhs in
      let lhsIsPreferred = lhs.key.hasPrefix("https://auth.x.ai::")
      let rhsIsPreferred = rhs.key.hasPrefix("https://auth.x.ai::")
      if lhsIsPreferred != rhsIsPreferred { return lhsIsPreferred }
      return lhs.key < rhs.key
    }
    var expired: GrokCredentialCandidate?
    for entry in ordered.map(\.value) {
      guard let key = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
        let userID = entry.userID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty
      else { continue }
      let expiresAt = UsageDateParser.iso8601(entry.expiresAt)
      let refreshToken = entry.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines)
      let candidate = GrokCredentialCandidate(
        credentials: GrokCredentials(key: key, userID: userID),
        expiresAt: expiresAt,
        canRenew: refreshToken?.isEmpty == false)
      guard let expiresAt, expiresAt <= now else { return candidate }
      if let current = expired?.expiresAt, current >= expiresAt { continue }
      expired = candidate
    }
    return expired
  }

  /// Retained for the callers and checks that only accept a currently valid
  /// token; renewal decisions use `candidate` instead.
  static func select(entries: [String: GrokCredentialEntry], now: Date) -> GrokCredentials? {
    guard let candidate = self.candidate(entries: entries, now: now) else { return nil }
    if let expiresAt = candidate.expiresAt, expiresAt <= now { return nil }
    return candidate.credentials
  }
}

struct GrokCredentialEntry: Decodable {
  let key: String?
  let userID: String?
  let expiresAt: String?
  let refreshToken: String?

  init(key: String?, userID: String?, expiresAt: String?, refreshToken: String? = nil) {
    self.key = key
    self.userID = userID
    self.expiresAt = expiresAt
    self.refreshToken = refreshToken
  }

  enum CodingKeys: String, CodingKey {
    case key
    case userID = "user_id"
    case expiresAt = "expires_at"
    case refreshToken = "refresh_token"
  }
}

/// Runs the CLI's own headless renewal. Attempts are serialised and rate
/// limited: killing a rotation halfway through can orphan the saved session,
/// and the CLI is the only component allowed to rotate its refresh token.
actor GrokSessionRenewer {
  static let shared = GrokSessionRenewer()
  static let timeout: Duration = .seconds(45)
  static let cooldown: TimeInterval = 60
  private var lastAttemptAt: Date?

  func renew(
    executable: String,
    environment: [String: String],
    now: Date = Date(),
    runner: @Sendable (String, [String], [String: String], Duration) async throws -> Void = {
      executable, arguments, environment, timeout in
      _ = try await ProcessRunner.output(
        executable: executable, arguments: arguments, environment: environment,
        standardInput: FileHandle.nullDevice, timeout: timeout)
    }
  ) async {
    if let lastAttemptAt, now.timeIntervalSince(lastAttemptAt) < Self.cooldown,
      now >= lastAttemptAt
    {
      return
    }
    self.lastAttemptAt = now
    // `grok models` is public, prints a short model list, and exits quickly.
    // Its output is never read: the renewed session is read back from
    // auth.json, and the exit status says nothing about renewal. The helper
    // sees only an allowlisted environment plus the CLI's own auth overrides.
    try? await runner(
      executable, ["models"],
      BinaryLocator.minimalChildEnvironment(
        from: environment, keeping: ["GROK_HOME", "GROK_AUTH_PATH"]),
      Self.timeout)
  }
}

struct SemanticVersion: Comparable, Sendable {
  let major: Int
  let minor: Int
  let patch: Int

  init(_ major: Int, _ minor: Int, _ patch: Int) {
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  var headerValue: String { "\(self.major).\(self.minor).\(self.patch)" }

  static func first(in text: String) -> SemanticVersion? {
    guard let expression = try? NSRegularExpression(pattern: #"(\d+)\.(\d+)\.(\d+)"#),
      let match = expression.firstMatch(
        in: text,
        range: NSRange(text.startIndex..., in: text))
    else { return nil }
    let values = (1...3).compactMap { index -> Int? in
      guard let range = Range(match.range(at: index), in: text) else { return nil }
      return Int(text[range])
    }
    guard values.count == 3 else { return nil }
    return SemanticVersion(values[0], values[1], values[2])
  }

  static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

struct GrokBillingEnvelope: Decodable, Sendable {
  let config: GrokBillingConfig?
  let subscriptionTier: String?
  let legacyConfig: GrokBillingConfig?

  enum CodingKeys: String, CodingKey {
    case config
    case subscriptionTier
    case subscriptionTierSnake = "subscription_tier"
    case creditUsagePercent
    case currentPeriod
    case monthlyLimit
    case used
    case billingPeriodStart
    case billingPeriodEnd
    case billingCycle
    case usage
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.config = try container.decodeIfPresent(GrokBillingConfig.self, forKey: .config)
    self.subscriptionTier =
      try container.decodeIfPresent(String.self, forKey: .subscriptionTier)
      ?? container.decodeIfPresent(String.self, forKey: .subscriptionTierSnake)

    let directPercent = try container.decodeIfPresent(Double.self, forKey: .creditUsagePercent)
    let monthlyLimit = try container.decodeIfPresent(GrokCent.self, forKey: .monthlyLimit)
    let used = try container.decodeIfPresent(GrokCent.self, forKey: .used)
    let usage = try container.decodeIfPresent(GrokLegacyUsage.self, forKey: .usage)
    let cycle = try container.decodeIfPresent(GrokLegacyCycle.self, forKey: .billingCycle)
    if directPercent != nil || monthlyLimit != nil || used != nil || usage != nil || cycle != nil {
      self.legacyConfig = GrokBillingConfig(
        creditUsagePercent: directPercent,
        currentPeriod: try container.decodeIfPresent(GrokUsagePeriod.self, forKey: .currentPeriod),
        monthlyLimit: monthlyLimit,
        used: used ?? usage?.totalUsed,
        billingPeriodStart: try container.decodeIfPresent(String.self, forKey: .billingPeriodStart)
          ?? cycle?.billingPeriodStart,
        billingPeriodEnd: try container.decodeIfPresent(String.self, forKey: .billingPeriodEnd)
          ?? cycle?.billingPeriodEnd,
        productUsage: nil,
        onDemandCap: nil,
        onDemandUsed: nil,
        isUnifiedBillingUser: nil)
    } else {
      self.legacyConfig = nil
    }
  }
}

struct GrokRemoteSettings: Decodable, Sendable {
  let subscriptionTierDisplay: String?
  let subscriptionTier: String?

  enum CodingKeys: String, CodingKey {
    case subscriptionTierDisplay = "subscription_tier_display"
    case subscriptionTier = "subscription_tier"
  }
}

struct GrokBillingConfig: Decodable, Sendable {
  let creditUsagePercent: Double?
  let currentPeriod: GrokUsagePeriod?
  let monthlyLimit: GrokCent?
  let used: GrokCent?
  let billingPeriodStart: String?
  let billingPeriodEnd: String?
  let productUsage: [GrokProductUsage]?
  let onDemandCap: GrokCent?
  let onDemandUsed: GrokCent?
  let isUnifiedBillingUser: Bool?

  var usedPercent: Double? {
    if let creditUsagePercent { return creditUsagePercent }
    // The unified credits backend uses proto3 JSON, which omits a zero-valued
    // percentage immediately after a weekly reset. Grok's own pager maps that
    // valid-period shape to 0%; require real period bounds so an arbitrary
    // incomplete response does not become a fabricated allowance.
    if self.isUnifiedBillingUser == true,
      let start = UsageDateParser.iso8601(self.currentPeriod?.start),
      let end = UsageDateParser.iso8601(self.currentPeriod?.end),
      end > start
    {
      return 0
    }
    return nil
  }

  var includedSpend: IncludedSpend? {
    if let limit = self.monthlyLimit?.val, limit > 0, let used = self.used?.val {
      return IncludedSpend(label: "Included credits", usedMinorUnits: used, limitMinorUnits: limit)
    }
    guard let limit = self.onDemandCap?.val, limit > 0, let used = self.onDemandUsed?.val else {
      return nil
    }
    return IncludedSpend(label: "On-demand cap", usedMinorUnits: used, limitMinorUnits: limit)
  }
}

struct GrokProductUsage: Decodable, Sendable {
  let product: String
  let usagePercent: Double

  enum CodingKeys: String, CodingKey { case product, usagePercent }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.product = try container.decode(String.self, forKey: .product)
    self.usagePercent = try container.decodeIfPresent(Double.self, forKey: .usagePercent) ?? 0
  }
}

struct GrokUsagePeriod: Decodable, Sendable {
  let type: String?
  let start: String?
  let end: String?
}

struct GrokCent: Decodable, Sendable {
  let val: Int

  enum CodingKeys: String, CodingKey { case val }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.val = try container.decodeIfPresent(Int.self, forKey: .val) ?? 0
  }
}

struct GrokLegacyUsage: Decodable, Sendable {
  let totalUsed: GrokCent?
}

struct GrokLegacyCycle: Decodable, Sendable {
  let billingPeriodStart: String?
  let billingPeriodEnd: String?
}
