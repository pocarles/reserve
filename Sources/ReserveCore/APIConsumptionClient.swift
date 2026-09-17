import Foundation

#if canImport(Security)
  import Security
#endif

/// Which official consumption API a measurement reads. These are API accounts,
/// not the subscription sign-ins Reserve already watches.
public enum APIConsumptionProvider: String, Codable, CaseIterable, Sendable, Identifiable {
  case openAI
  case anthropic
  case openRouter
  case xAI
  case typeSafe

  public var id: String { self.rawValue }

  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .openRouter: "OpenRouter"
    case .xAI: "xAI"
    case .typeSafe: "TypeSafe"
    }
  }

  /// What the key is allowed to do. None of these keys can call a model.
  public var keyKind: String {
    switch self {
    case .openAI: "Admin key"
    case .anthropic: "Admin key"
    case .openRouter: "API key"
    case .xAI: "Management key"
    case .typeSafe: "API key"
    }
  }

  public var keyHint: String {
    switch self {
    case .openAI: "sk-admin-…"
    case .anthropic: "sk-ant-admin…"
    case .openRouter: "sk-or-…"
    case .xAI: "xai-…"
    case .typeSafe: "ts-…"
    }
  }

  /// Where a person creates the key. Opened by the settings control; never
  /// contacted by Reserve itself.
  public var keySettingsURL: URL {
    switch self {
    case .openAI: URL(string: "https://platform.openai.com/settings/organization/admin-keys")!
    case .anthropic: URL(string: "https://platform.claude.com/settings/admin-keys")!
    case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
    case .xAI: URL(string: "https://console.x.ai/team/default/settings")!
    case .typeSafe: URL(string: "https://console.typesafe.ai/settings/keys")!
    }
  }

  var endpointHost: String {
    switch self {
    case .openAI: "api.openai.com"
    case .anthropic: "api.anthropic.com"
    case .openRouter: "openrouter.ai"
    case .xAI: "management-api.x.ai"
    case .typeSafe: "api.typesafe.ai"
    }
  }
}

/// Spend reported by a provider's own billing API for one measurement window.
/// Amounts stay in minor currency units so a fractional dollar cannot drift.
public struct APIConsumptionWindow: Codable, Equatable, Sendable, Identifiable {
  public static let maximumIdentifierCharacters = 64
  public static let maximumLabelCharacters = 48
  public let id: String
  public let label: String
  public let usedMinorUnits: Int
  public let limitMinorUnits: Int?
  public let currencyCode: String
  /// Names, roles, or providers behind the count. Never a credential.
  public let detail: String?
  public let resetsAt: Date?

  public init(
    id: String,
    label: String,
    usedMinorUnits: Int,
    limitMinorUnits: Int? = nil,
    currencyCode: String = "USD",
    resetsAt: Date? = nil,
    detail: String? = nil
  ) {
    self.id = String(id.prefix(Self.maximumIdentifierCharacters))
    self.label = String(label.prefix(Self.maximumLabelCharacters))
    self.usedMinorUnits = min(Self.maximumMinorUnits, max(0, usedMinorUnits))
    self.limitMinorUnits = limitMinorUnits.map {
      min(Self.maximumMinorUnits, max(0, $0))
    }
    let code = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    self.currencyCode = code.count == 3 && code.allSatisfy(\.isLetter) ? code : "USD"
    let trimmedDetail = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.detail = trimmedDetail.isEmpty ? nil : String(trimmedDetail.prefix(180))
    self.resetsAt = resetsAt.flatMap { value in
      value.timeIntervalSinceReferenceDate.isFinite ? value : nil
    }
  }

  public var usedUSD: Double { Double(self.usedMinorUnits) / 100 }

  public var limitUSD: Double? {
    self.limitMinorUnits.map { Double($0) / 100 }
  }

  /// Share of a configured cap already consumed. Absent when the provider
  /// reported spend without a cap.
  public var usedPercent: Double? {
    guard let limitMinorUnits, limitMinorUnits > 0 else { return nil }
    return min(100, Double(self.usedMinorUnits) / Double(limitMinorUnits) * 100)
  }

  private static let maximumMinorUnits = 100_000_000_000

  private enum CodingKeys: String, CodingKey {
    case id, label, usedMinorUnits, limitMinorUnits, currencyCode, detail, resetsAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      id: try container.decode(String.self, forKey: .id),
      label: try container.decode(String.self, forKey: .label),
      usedMinorUnits: try container.decode(Int.self, forKey: .usedMinorUnits),
      limitMinorUnits: try container.decodeIfPresent(Int.self, forKey: .limitMinorUnits),
      currencyCode: try container.decodeIfPresent(String.self, forKey: .currencyCode) ?? "USD",
      resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
      detail: try container.decodeIfPresent(String.self, forKey: .detail))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.id, forKey: .id)
    try container.encode(self.label, forKey: .label)
    try container.encode(self.usedMinorUnits, forKey: .usedMinorUnits)
    try container.encodeIfPresent(self.limitMinorUnits, forKey: .limitMinorUnits)
    try container.encode(self.currencyCode, forKey: .currencyCode)
    try container.encodeIfPresent(self.detail, forKey: .detail)
    try container.encodeIfPresent(self.resetsAt, forKey: .resetsAt)
  }
}

public struct APIConsumptionSnapshot: Codable, Equatable, Sendable, Identifiable {
  public static let maximumWindows = 8
  public static let maximumSourceCharacters = 96
  public var id: APIConsumptionProvider { self.provider }
  public let provider: APIConsumptionProvider
  public let windows: [APIConsumptionWindow]
  public let fetchedAt: Date
  public let source: String

  public init(
    provider: APIConsumptionProvider,
    windows: [APIConsumptionWindow],
    fetchedAt: Date = Date(),
    source: String
  ) {
    self.provider = provider
    self.windows = Array(windows.prefix(Self.maximumWindows))
    self.fetchedAt = fetchedAt
    self.source = String(source.prefix(Self.maximumSourceCharacters))
  }

  /// The window a glance should lead with: a capped window before an uncapped
  /// total, then the largest reported spend.
  public var primary: APIConsumptionWindow? {
    self.windows.max { lhs, rhs in
      let lhsCapped = lhs.limitMinorUnits != nil
      let rhsCapped = rhs.limitMinorUnits != nil
      if lhsCapped != rhsCapped { return !lhsCapped }
      return lhs.usedMinorUnits < rhs.usedMinorUnits
    }
  }
}

public enum APIConsumptionKeychain {
  public static let service = "com.pocarles.reserve.api-consumption"

  public static func account(for provider: APIConsumptionProvider) -> String {
    "api-consumption.\(provider.rawValue)"
  }

  #if canImport(Security)
    public static func hasKey(for provider: APIConsumptionProvider) -> Bool {
      SecItemCopyMatching(self.query(provider, returningData: false) as CFDictionary, nil)
        == errSecSuccess
    }

    /// Replaces any key already stored for this provider. The value never
    /// leaves this process except as an `Authorization` header on the fixed
    /// provider host.
    public static func save(_ key: String, for provider: APIConsumptionProvider) throws {
      let stored = try Self.normalized(key, for: provider)
      let payload = Data(stored.utf8)
      let match = self.query(provider, returningData: false) as CFDictionary
      let status: OSStatus
      if SecItemCopyMatching(match, nil) == errSecSuccess {
        status = SecItemUpdate(
          match, [kSecValueData as String: payload] as CFDictionary)
      } else {
        var attributes = self.query(provider, returningData: false)
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = "Reserve \(provider.displayName) consumption key"
        status = SecItemAdd(attributes as CFDictionary, nil)
      }
      guard status == errSecSuccess else {
        throw UsageProviderError.credentialsNotFound(
          "macOS refused to store the \(provider.displayName) key (\(status)).")
      }
    }

    public static func load(for provider: APIConsumptionProvider) throws -> String {
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        self.query(provider, returningData: true) as CFDictionary, &result)
      guard status != errSecItemNotFound else {
        throw UsageProviderError.credentialsNotFound(
          "No \(provider.displayName) \(provider.keyKind.lowercased()) is saved.")
      }
      guard status == errSecSuccess, let data = result as? Data,
        data.count <= 1_200, let key = String(data: data, encoding: .utf8), !key.isEmpty
      else {
        throw UsageProviderError.credentialsNotFound(
          "The saved \(provider.displayName) key could not be read.")
      }
      return key
    }

    public static func delete(for provider: APIConsumptionProvider) {
      SecItemDelete(self.query(provider, returningData: false) as CFDictionary)
    }

    /// Removes the Typeface item from an earlier mistaken provider name.
    public static func deleteLegacyTypefaceAccount() {
      SecItemDelete(
        [
          kSecClass as String: kSecClassGenericPassword,
          kSecAttrService as String: Self.service,
          kSecAttrAccount as String: "api-consumption.typeface",
        ] as CFDictionary)
    }

    /// Paste often includes wrapping newlines. Those are stripped.
    static func normalized(
      _ key: String,
      for provider: APIConsumptionProvider
    ) throws -> String {
      let stored = String(key.filter { $0.isASCII && !$0.isWhitespace && !$0.isNewline })
      guard (16...1_200).contains(stored.count) else {
        throw UsageProviderError.credentialsNotFound(
          "\(provider.displayName) needs a single-line API key.")
      }
      return stored
    }

    private static func query(
      _ provider: APIConsumptionProvider,
      returningData: Bool
    ) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: Self.service,
        kSecAttrAccount as String: self.account(for: provider),
      ]
      if returningData {
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
      }
      return query
    }
  #endif
}

/// Reads consumption from the official billing or account APIs. The key is supplied
/// by the caller and is not retained after the request returns.
public struct APIConsumptionClient: Sendable {
  private let requestHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
  private let now: @Sendable () -> Date

  public init(
    session: URLSession? = nil,
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    let session = session ?? ProviderHTTPSession.shared
    self.requestHandler = {
      try await ProviderHTTPSession.boundedData(
        for: $0, using: session, maximumBytes: 1_048_576)
    }
    self.now = now
  }

  init(
    requestHandler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse),
    now: @escaping @Sendable () -> Date = Date.init
  ) {
    self.requestHandler = requestHandler
    self.now = now
  }

  public func fetch(
    _ provider: APIConsumptionProvider,
    apiKey: String
  ) async throws -> APIConsumptionSnapshot {
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !key.isEmpty else {
      throw UsageProviderError.credentialsNotFound(
        "No \(provider.displayName) \(provider.keyKind.lowercased()) is saved.")
    }
    switch provider {
    case .openAI: return try await self.fetchOpenAI(key)
    case .anthropic: return try await self.fetchAnthropic(key)
    case .openRouter: return try await self.fetchOpenRouter(key)
    case .xAI: return try await self.fetchXAI(key)
    case .typeSafe: return try await self.fetchTypeSafe(key)
    }
  }

  // MARK: OpenAI

  /// Organization Costs API. Daily buckets are the only width the endpoint
  /// offers, so a month is the widest range that stays inside one page.
  private func fetchOpenAI(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    let start = Calendar(identifier: .gregorian).dateInterval(of: .month, for: now)?.start ?? now
    var components = URLComponents()
    components.scheme = "https"
    components.host = APIConsumptionProvider.openAI.endpointHost
    components.path = "/v1/organization/costs"
    components.queryItems = [
      URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
      URLQueryItem(name: "bucket_width", value: "1d"),
      URLQueryItem(name: "limit", value: "31"),
    ]
    guard let url = components.url else {
      throw UsageProviderError.invalidResponse("OpenAI cost URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let data = try await self.data(for: request, provider: .openAI)
    let decoded = try Self.decode(OpenAICostsPage.self, from: data, provider: .openAI)
    var minorUnits = 0
    var currency = "USD"
    for bucket in decoded.data ?? [] {
      for result in bucket.results ?? [] {
        minorUnits += Self.minorUnits(from: result.amount?.value)
        if let code = result.amount?.currency, !code.isEmpty { currency = code }
      }
    }
    return APIConsumptionSnapshot(
      provider: .openAI,
      windows: [
        APIConsumptionWindow(
          id: "month", label: "This month", usedMinorUnits: minorUnits,
          currencyCode: currency, resetsAt: Self.nextMonth(after: now))
      ],
      fetchedAt: now,
      source: "OpenAI Costs API")
  }

  // MARK: Anthropic

  /// Cost Report API. Costs arrive as decimal strings of cents, daily, and a
  /// single request covers at most 31 buckets.
  private func fetchAnthropic(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    let start = Calendar(identifier: .gregorian).dateInterval(of: .month, for: now)?.start ?? now
    let ending = min(now, start.addingTimeInterval(31 * 24 * 60 * 60))
    var components = URLComponents()
    components.scheme = "https"
    components.host = APIConsumptionProvider.anthropic.endpointHost
    components.path = "/v1/organizations/cost_report"
    components.queryItems = [
      URLQueryItem(name: "starting_at", value: Self.rfc3339(start)),
      URLQueryItem(name: "ending_at", value: Self.rfc3339(ending)),
      URLQueryItem(name: "bucket_width", value: "1d"),
    ]
    guard let url = components.url else {
      throw UsageProviderError.invalidResponse("Anthropic cost URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue(key, forHTTPHeaderField: "x-api-key")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    let data = try await self.data(for: request, provider: .anthropic)
    let decoded = try Self.decode(AnthropicCostPage.self, from: data, provider: .anthropic)
    var minorUnits = 0
    for bucket in decoded.data ?? [] {
      for result in bucket.results ?? [] {
        minorUnits += Self.minorUnits(fromDecimalCents: result.amount)
      }
    }
    return APIConsumptionSnapshot(
      provider: .anthropic,
      windows: [
        APIConsumptionWindow(
          id: "month", label: "This month", usedMinorUnits: minorUnits,
          resetsAt: Self.nextMonth(after: now))
      ],
      fetchedAt: now,
      source: "Anthropic Cost API")
  }

  // MARK: OpenRouter

  /// The key endpoint reports this key's own credit consumption. A management
  /// key is deliberately not required.
  private func fetchOpenRouter(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    guard let url = URL(string: "https://openrouter.ai/api/v1/key") else {
      throw UsageProviderError.invalidResponse("OpenRouter key URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let data = try await self.data(for: request, provider: .openRouter)
    let decoded = try Self.decode(OpenRouterKeyEnvelope.self, from: data, provider: .openRouter)
    guard let usage = decoded.data else {
      throw UsageProviderError.invalidResponse("OpenRouter did not return key usage.")
    }
    let limit = usage.limit.flatMap { value -> Int? in
      let minor = Self.minorUnits(from: value)
      return minor > 0 ? minor : nil
    }
    return APIConsumptionSnapshot(
      provider: .openRouter,
      windows: [
        APIConsumptionWindow(
          id: "month", label: "This month",
          usedMinorUnits: Self.minorUnits(from: usage.usageMonthly),
          limitMinorUnits: limit,
          resetsAt: Self.nextMonth(after: now)),
        APIConsumptionWindow(
          id: "all-time", label: "All time",
          usedMinorUnits: Self.minorUnits(from: usage.usage)),
      ],
      fetchedAt: now,
      source: "OpenRouter key API")
  }

  // MARK: xAI

  /// Prepaid balance is the account's remaining credit. The validation call
  /// only exists to learn which team the management key belongs to.
  private func fetchXAI(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    let validation = try await self.xAI(
      path: "/auth/management-keys/validation", key: key, as: XAValidation.self)
    let team = validation.scopeId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
      ?? validation.teamId?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
    guard let team, Self.isTeamIdentifier(team) else {
      throw UsageProviderError.invalidResponse(
        "xAI did not return a team for this management key.")
    }
    let balance = try await self.xAI(
      path: "/v1/billing/teams/\(team)/prepaid/balance", key: key, as: XAIBalance.self)
    let remaining = Self.minorUnits(fromCentString: balance.total?.val)
    var purchased = 0
    var spent = 0
    for change in balance.changes ?? [] {
      let amount = Self.minorUnits(fromCentString: change.amount?.val)
      switch change.changeOrigin {
      case "PURCHASE", "AUTO_PURCHASE", "REFUND":
        purchased += amount
      case "SPEND":
        spent += amount
      default:
        break
      }
    }
    let total = purchased > 0 ? purchased : remaining + spent
    return APIConsumptionSnapshot(
      provider: .xAI,
      windows: [
        APIConsumptionWindow(
          id: "prepaid", label: "Prepaid credits",
          usedMinorUnits: min(spent, total),
          limitMinorUnits: total > 0 ? total : nil)
      ],
      fetchedAt: now,
      source: "xAI Management API")
  }

  private func xAI<Response: Decodable>(
    path: String,
    key: String,
    as responseType: Response.Type
  ) async throws -> Response {
    guard let url = URL(string: "https://management-api.x.ai\(path)") else {
      throw UsageProviderError.invalidResponse("xAI URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    let data = try await self.data(for: request, provider: .xAI)
    return try Self.decode(responseType, from: data, provider: .xAI)
  }

  // MARK: TypeSafe

  /// TypeSafe publishes no spend endpoint. `GET /v1/models` is the documented
  /// account call: it proves the key and lists the models that key can send.
  /// Per-request token counts exist only on evaluation responses, which would
  /// consume the account, so Reserve does not call System One to measure it.
  private func fetchTypeSafe(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    guard let url = URL(string: "https://api.typesafe.ai/v1/models") else {
      throw UsageProviderError.invalidResponse("TypeSafe models URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data = try await self.data(for: request, provider: .typeSafe)
    let page = try Self.decode(TypeSafeModelsPage.self, from: data, provider: .typeSafe)
    let names = page.models.compactMap { model -> String? in
      let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return name.isEmpty ? nil : name
    }
    guard !names.isEmpty else {
      throw UsageProviderError.unavailable("TypeSafe did not return any models for this key.")
    }
    return APIConsumptionSnapshot(
      provider: .typeSafe,
      windows: [
        APIConsumptionWindow(
          id: "models",
          label: "Models",
          usedMinorUnits: names.count,
          detail: names.prefix(8).joined(separator: ", ")),
        APIConsumptionWindow(
          id: "price",
          label: "Input price",
          usedMinorUnits: 0,
          detail: "$0.042 per million tokens · output free"),
      ],
      fetchedAt: now,
      source: "TypeSafe Models API")
  }

  // MARK: Transport

  private func data(
    for request: URLRequest,
    provider: APIConsumptionProvider
  ) async throws -> Data {
    guard request.url?.scheme?.lowercased() == "https",
      request.url?.host?.lowercased() == provider.endpointHost
    else {
      throw UsageProviderError.invalidResponse(
        "\(provider.displayName) request left its official host.")
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await self.requestHandler(request)
    } catch let error as UsageProviderError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw UsageProviderError.timedOut("\(provider.displayName) consumption request")
    } catch {
      throw UsageProviderError.unavailable(
        "\(provider.displayName) consumption request failed: \(error.localizedDescription)")
    }
    guard let http = response as? HTTPURLResponse else {
      throw UsageProviderError.invalidResponse(
        "\(provider.displayName) did not return an HTTP response.")
    }
    switch http.statusCode {
    case 200: return data
    case 401, 403:
      throw UsageProviderError.unauthorized(
        "\(provider.displayName) refused this \(provider.keyKind.lowercased()).")
    case 429:
      throw UsageProviderError.rateLimited(retryAt: nil)
    default:
      throw UsageProviderError.unavailable(
        "\(provider.displayName) consumption request returned HTTP \(http.statusCode).")
    }
  }

  private static func decode<Response: Decodable>(
    _ type: Response.Type,
    from data: Data,
    provider: APIConsumptionProvider
  ) throws -> Response {
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw UsageProviderError.invalidResponse(
        "\(provider.displayName) returned a consumption response Reserve could not read.")
    }
  }

  /// Dollars, as OpenAI and OpenRouter report them, into cents.
  static func minorUnits(from dollars: Double?) -> Int {
    guard let dollars, dollars.isFinite, dollars > 0 else { return 0 }
    let scaled = (dollars * 100).rounded()
    guard scaled.isFinite, scaled <= Double(Int.max) else { return Int.max }
    return Int(scaled)
  }

  /// Anthropic reports cents as a decimal string, so "123.45" is $1.2345.
  static func minorUnits(fromDecimalCents text: String?) -> Int {
    guard let text else { return 0 }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Decimal(string: trimmed), value > 0 else { return 0 }
    let cents = NSDecimalNumber(decimal: value).rounding(
      accordingToBehavior: Self.centRounding)
    guard cents.compare(NSDecimalNumber(value: Int.max)) == .orderedAscending else {
      return Int.max
    }
    return cents.intValue
  }

  /// xAI reports integer cents as a string. Purchases arrive negative.
  static func minorUnits(fromCentString text: String?) -> Int {
    guard let text else { return 0 }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Int(trimmed) else { return 0 }
    return abs(value)
  }

  static func isTeamIdentifier(_ value: String) -> Bool {
    let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF-")
    return (8...64).contains(value.count)
      && value.unicodeScalars.allSatisfy { allowed.contains($0) }
  }

  static func nextMonth(after date: Date) -> Date? {
    Calendar(identifier: .gregorian).dateInterval(of: .month, for: date)?.end
  }

  private static func rfc3339(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.string(from: date)
  }

  private static let centRounding: NSDecimalNumberHandler = {
    NSDecimalNumberHandler(
      roundingMode: .plain, scale: 0, raiseOnExactness: false, raiseOnOverflow: false,
      raiseOnUnderflow: false, raiseOnDivideByZero: false)
  }()
}

private extension String {
  var nonEmpty: String? { self.isEmpty ? nil : self }
}

private struct OpenAICostsPage: Decodable {
  struct Amount: Decodable {
    let value: Double?
    let currency: String?
  }
  struct Result: Decodable {
    let amount: Amount?
  }
  struct Bucket: Decodable {
    let results: [Result]?
  }
  let data: [Bucket]?
}

private struct AnthropicCostPage: Decodable {
  struct Result: Decodable {
    let amount: String?
  }
  struct Bucket: Decodable {
    let results: [Result]?
  }
  let data: [Bucket]?
}

private struct OpenRouterKeyEnvelope: Decodable {
  struct Key: Decodable {
    let usage: Double?
    let usageMonthly: Double?
    let limit: Double?

    enum CodingKeys: String, CodingKey {
      case usage
      case usageMonthly = "usage_monthly"
      case limit
    }
  }
  let data: Key?
}

private struct XAValidation: Decodable {
  let teamId: String?
  let scopeId: String?

  enum CodingKeys: String, CodingKey {
    case teamId
    case scopeId
  }
}

private struct TypeSafeModelsPage: Decodable {
  let models: [TypeSafeModel]

  init(from decoder: Decoder) throws {
    if let array = try? decoder.singleValueContainer().decode([TypeSafeModel].self) {
      self.models = array
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.models = try container.decodeIfPresent([TypeSafeModel].self, forKey: .models) ?? []
  }

  enum CodingKeys: String, CodingKey { case models }
}

private struct TypeSafeModel: Decodable {
  let name: String?
  let description: String?
  let releaseDate: String?

  enum CodingKeys: String, CodingKey {
    case name, description
    case releaseDate = "release_date"
  }
}

private struct XAIBalance: Decodable {
  struct Amount: Decodable { let val: String? }
  struct Change: Decodable {
    let changeOrigin: String?
    let amount: Amount?
  }
  let total: Amount?
  let changes: [Change]?
}
