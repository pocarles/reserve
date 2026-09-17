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

  fileprivate static let dominanceShare = 0.5

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

/// One named contributor to a measured window: a model, a billing line item, or
/// whatever grouping the provider returned. Spend only, never a credential.
public struct APIConsumptionItem: Codable, Equatable, Sendable, Identifiable {
  public static let maximumLabelCharacters = 56
  public var id: String { self.label }
  public let label: String
  public let usedMinorUnits: Int

  public init(label: String, usedMinorUnits: Int) {
    self.label = String(
      label.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(Self.maximumLabelCharacters))
    self.usedMinorUnits = max(0, usedMinorUnits)
  }

  public var usedUSD: Double { Double(self.usedMinorUnits) / 100 }
}

/// What a provider reports when it publishes no spend endpoint at all. Kept out
/// of `windows` so no display path can format a count or a balance as spend.
public struct APIConsumptionNote: Codable, Equatable, Sendable {
  public static let maximumHeadlineCharacters = 24
  public static let maximumDetailCharacters = 180
  public let headline: String
  public let detail: String?

  public init(headline: String, detail: String? = nil) {
    self.headline = String(
      headline.trimmingCharacters(in: .whitespacesAndNewlines)
        .prefix(Self.maximumHeadlineCharacters))
    let trimmed = detail?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    self.detail = trimmed.isEmpty ? nil : String(trimmed.prefix(Self.maximumDetailCharacters))
  }
}

public struct APIConsumptionSnapshot: Codable, Equatable, Sendable, Identifiable {
  public static let maximumWindows = 8
  public static let maximumBreakdownItems = 6
  public static let maximumSourceCharacters = 96
  public var id: APIConsumptionProvider { self.provider }
  public let provider: APIConsumptionProvider
  public let windows: [APIConsumptionWindow]
  /// What the spend went on, largest first. Empty when the provider offers no
  /// grouping, so a reader can tell "nothing to break down" from "not asked".
  public let breakdown: [APIConsumptionItem]
  /// Set instead of `windows` when there is no spend figure to be had.
  public let note: APIConsumptionNote?
  public let fetchedAt: Date
  public let source: String

  public init(
    provider: APIConsumptionProvider,
    windows: [APIConsumptionWindow],
    breakdown: [APIConsumptionItem] = [],
    note: APIConsumptionNote? = nil,
    fetchedAt: Date = Date(),
    source: String
  ) {
    self.provider = provider
    self.note = note
    self.windows = Array(windows.prefix(Self.maximumWindows))
    self.breakdown = Array(
      breakdown
        .filter { !$0.label.isEmpty && $0.usedMinorUnits > 0 }
        .sorted { $0.usedMinorUnits > $1.usedMinorUnits }
        .prefix(Self.maximumBreakdownItems))
    self.fetchedAt = fetchedAt
    self.source = String(source.prefix(Self.maximumSourceCharacters))
  }

  private enum CodingKeys: String, CodingKey {
    case provider, windows, breakdown, note, fetchedAt, source
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      provider: try container.decode(APIConsumptionProvider.self, forKey: .provider),
      windows: try container.decode([APIConsumptionWindow].self, forKey: .windows),
      breakdown: try container.decodeIfPresent([APIConsumptionItem].self, forKey: .breakdown) ?? [],
      note: try container.decodeIfPresent(APIConsumptionNote.self, forKey: .note),
      fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
      source: try container.decode(String.self, forKey: .source))
  }

  /// The one contributor worth naming at a glance: present only when a single
  /// item is most of the spend, so a narrow row never implies a split is lopsided
  /// when it is not.
  public var dominantBreakdownItem: APIConsumptionItem? {
    let total = self.breakdown.reduce(0) { $0 + $1.usedMinorUnits }
    guard total > 0, let leader = self.breakdown.first else { return nil }
    return Double(leader.usedMinorUnits) / Double(total) >= APIConsumptionWindow.dominanceShare
      ? leader : nil
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
  /// offers, so a month needs 31 of them, and the cursor is followed in case
  /// grouping splits the range across pages.
  private func fetchOpenAI(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    let start = Calendar(identifier: .gregorian).dateInterval(of: .month, for: now)?.start ?? now
    func request(page: String?, grouped: Bool) throws -> URLRequest {
      var components = URLComponents()
      components.scheme = "https"
      components.host = APIConsumptionProvider.openAI.endpointHost
      components.path = "/v1/organization/costs"
      var items = [
        URLQueryItem(name: "start_time", value: String(Int(start.timeIntervalSince1970))),
        URLQueryItem(name: "bucket_width", value: "1d"),
        URLQueryItem(name: "limit", value: "31"),
      ]
      // Ungrouped, every per-model field comes back null, so the breakdown is
      // only available once a grouping is asked for.
      if grouped { items.append(URLQueryItem(name: "group_by", value: "line_item")) }
      if let page { items.append(URLQueryItem(name: "page", value: page)) }
      components.queryItems = items
      guard let url = components.url else {
        throw UsageProviderError.invalidResponse("OpenAI cost URL could not be formed.")
      }
      var request = URLRequest(url: url)
      request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
      return request
    }

    let pages = try await self.groupedPages(
      OpenAICostsPage.self,
      provider: .openAI,
      request: request,
      cursor: { ($0.hasMore ?? false, $0.nextPage) })

    var minorUnits = 0
    var currency = "USD"
    var byLineItem: [String: Int] = [:]
    for page in pages.pages {
      for bucket in page.data ?? [] {
        for result in bucket.results ?? [] {
          let amount = Self.minorUnits(from: result.amount?.value)
          minorUnits += amount
          if let code = result.amount?.currency, !code.isEmpty { currency = code.uppercased() }
          if let name = result.lineItem?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
            byLineItem[name, default: 0] += amount
          }
        }
      }
    }
    return APIConsumptionSnapshot(
      provider: .openAI,
      windows: [
        APIConsumptionWindow(
          id: "month", label: "This month", usedMinorUnits: minorUnits,
          currencyCode: currency, resetsAt: Self.nextMonth(after: now))
      ],
      breakdown: byLineItem.map { APIConsumptionItem(label: $0.key, usedMinorUnits: $0.value) },
      fetchedAt: now,
      source: pages.grouped ? "OpenAI Costs API" : "OpenAI Costs API (ungrouped)")
  }

  // MARK: Anthropic

  /// Cost Report API. Costs arrive as decimal strings of cents, daily. `limit`
  /// defaults to 7 buckets, so a month has to ask for 31 and then follow the
  /// cursor, or the reading silently stops a week into the month.
  private func fetchAnthropic(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    let start = Calendar(identifier: .gregorian).dateInterval(of: .month, for: now)?.start ?? now
    let ending = min(now, start.addingTimeInterval(31 * 24 * 60 * 60))
    func request(page: String?, grouped: Bool) throws -> URLRequest {
      var components = URLComponents()
      components.scheme = "https"
      components.host = APIConsumptionProvider.anthropic.endpointHost
      components.path = "/v1/organizations/cost_report"
      var items = [
        URLQueryItem(name: "starting_at", value: Self.rfc3339(start)),
        URLQueryItem(name: "ending_at", value: Self.rfc3339(ending)),
        URLQueryItem(name: "bucket_width", value: "1d"),
        URLQueryItem(name: "limit", value: "31"),
      ]
      if grouped { items.append(URLQueryItem(name: "group_by[]", value: "description")) }
      if let page { items.append(URLQueryItem(name: "page", value: page)) }
      components.queryItems = items
      guard let url = components.url else {
        throw UsageProviderError.invalidResponse("Anthropic cost URL could not be formed.")
      }
      var request = URLRequest(url: url)
      request.setValue(key, forHTTPHeaderField: "x-api-key")
      request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
      return request
    }

    let pages = try await self.groupedPages(
      AnthropicCostPage.self,
      provider: .anthropic,
      request: request,
      cursor: { ($0.hasMore ?? false, $0.nextPage) })

    var minorUnits = 0
    var byModel: [String: Int] = [:]
    for page in pages.pages {
      for bucket in page.data ?? [] {
        for result in bucket.results ?? [] {
          let amount = Self.minorUnits(fromDecimalCents: result.amount)
          minorUnits += amount
          let name =
            result.model?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            ?? result.description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
          if let name { byModel[name, default: 0] += amount }
        }
      }
    }
    return APIConsumptionSnapshot(
      provider: .anthropic,
      windows: [
        APIConsumptionWindow(
          id: "month", label: "This month", usedMinorUnits: minorUnits,
          resetsAt: Self.nextMonth(after: now))
      ],
      breakdown: byModel.map { APIConsumptionItem(label: $0.key, usedMinorUnits: $0.value) },
      fetchedAt: now,
      source: pages.grouped ? "Anthropic Cost API" : "Anthropic Cost API (ungrouped)")
  }

  // MARK: OpenRouter

  /// The key endpoint reports this key's own credit consumption. A management
  /// key is deliberately not required. `limit` caps the key's credits outright
  /// rather than any calendar window, so it is paired with lifetime usage.
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

    var monthDetail = "\(Self.money(Self.minorUnits(from: usage.usage))) all time"
    if usage.isFreeTier == true { monthDetail += " · free tier" }
    var windows = [
      APIConsumptionWindow(
        id: "today", label: "Today",
        usedMinorUnits: Self.minorUnits(from: usage.usageDaily),
        detail: usage.freeModelDailyRequests.map {
          "free models: \($0.used ?? 0) of \($0.limit ?? 0) today"
        }),
      APIConsumptionWindow(
        id: "week", label: "This week",
        usedMinorUnits: Self.minorUnits(from: usage.usageWeekly)),
      APIConsumptionWindow(
        id: "month", label: "This month",
        usedMinorUnits: Self.minorUnits(from: usage.usageMonthly),
        resetsAt: Self.nextMonth(after: now),
        detail: monthDetail),
    ]
    // Only a real cap is worth showing as one; an uncapped key reports null.
    if let cap = usage.limit.map(Self.minorUnits(from:)), cap > 0 {
      let remaining = usage.limitRemaining.map(Self.minorUnits(from:))
      windows.append(
        APIConsumptionWindow(
          id: "credits", label: "Key credits",
          usedMinorUnits: remaining.map { max(0, cap - $0) }
            ?? Self.minorUnits(from: usage.usage),
          limitMinorUnits: cap,
          detail: remaining.map { "\(Self.money($0)) left" }
            ?? usage.label?.nonEmpty))
    }
    return APIConsumptionSnapshot(
      provider: .openRouter,
      windows: windows,
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

    // `total` is the balance xAI itself reports and is the one number here that
    // does not depend on reading a ledger correctly. The cap is only derived
    // when the ledger fully explains that balance: an unrecognised entry means
    // the sum is incomplete, and an incomplete sum must not become a cap.
    let remaining = Self.minorUnits(fromCentString: balance.total?.val)
    var purchased = 0
    var understoodEveryEntry = true
    for change in balance.changes ?? [] {
      let amount = Self.minorUnits(fromCentString: change.amount?.val)
      switch change.changeOrigin {
      case "PURCHASE", "AUTO_PURCHASE":
        purchased += amount
      case "SPEND", "REFUND", "EXPIRY", "EXPIRE", "ADJUSTMENT":
        // Not credit added, so not part of what was bought.
        break
      default:
        understoodEveryEntry = false
      }
    }

    if understoodEveryEntry, purchased > 0, purchased >= remaining {
      return APIConsumptionSnapshot(
        provider: .xAI,
        windows: [
          APIConsumptionWindow(
            id: "prepaid", label: "Prepaid credits",
            usedMinorUnits: purchased - remaining,
            limitMinorUnits: purchased,
            detail: "\(Self.money(remaining)) left")
        ],
        fetchedAt: now,
        source: "xAI Management API")
    }
    // Without a trustworthy cap, report the balance as the balance rather than
    // inventing a spend figure to sit in a spend field.
    return APIConsumptionSnapshot(
      provider: .xAI,
      windows: [],
      note: APIConsumptionNote(
        headline: Self.money(remaining), detail: "prepaid credits left"),
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
    // No windows: a model count is not spend, and putting it in a spend field is
    // how a count ends up rendered as a dollar amount.
    return APIConsumptionSnapshot(
      provider: .typeSafe,
      windows: [],
      note: APIConsumptionNote(
        headline: names.count == 1 ? "1 model" : "\(names.count) models",
        detail: names.prefix(4).joined(separator: ", ")
          + " · $0.042 per million tokens in, output free"),
      fetchedAt: now,
      source: "TypeSafe Models API")
  }

  // MARK: Paging

  /// Walks a billing endpoint's cursor, bounded so a cursor that never settles
  /// cannot keep the app fetching. Grouping is requested first because it is
  /// what carries the per-model detail; if the provider rejects the grouping
  /// parameter the same range is read without it rather than failing outright.
  private func groupedPages<Page: Decodable>(
    _ type: Page.Type,
    provider: APIConsumptionProvider,
    maximumPages: Int = 6,
    request: (String?, Bool) throws -> URLRequest,
    cursor: (Page) -> (hasMore: Bool, next: String?)
  ) async throws -> (pages: [Page], grouped: Bool) {
    do {
      return (
        try await self.pages(
          type, provider: provider, maximumPages: maximumPages,
          request: { try request($0, true) }, cursor: cursor),
        true
      )
    } catch UsageProviderError.invalidResponse {
      // The provider would not accept the grouped request. A refused key or a
      // rate limit says nothing about grouping, so only this case falls back.
      return (
        try await self.pages(
          type, provider: provider, maximumPages: maximumPages,
          request: { try request($0, false) }, cursor: cursor),
        false
      )
    }
  }

  private func pages<Page: Decodable>(
    _ type: Page.Type,
    provider: APIConsumptionProvider,
    maximumPages: Int,
    request: (String?) throws -> URLRequest,
    cursor: (Page) -> (hasMore: Bool, next: String?)
  ) async throws -> [Page] {
    var collected: [Page] = []
    var token: String?
    var seen: Set<String> = []
    for _ in 0..<maximumPages {
      let data = try await self.data(for: try request(token), provider: provider)
      let page = try Self.decode(type, from: data, provider: provider)
      collected.append(page)
      let (hasMore, next) = cursor(page)
      // A repeated cursor means the endpoint is looping; stop with what is read.
      guard hasMore, let next, !next.isEmpty, seen.insert(next).inserted else { break }
      token = next
    }
    return collected
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
    case 400, 404, 422:
      throw UsageProviderError.invalidResponse(
        "\(provider.displayName) rejected this consumption request (HTTP \(http.statusCode)).")
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

  static func money(_ minorUnits: Int) -> String {
    let amount = Double(minorUnits) / 100
    return amount >= 100
      ? String(format: "$%.0f", amount)
      : String(format: "$%.2f", amount)
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
    /// Present only when the request grouped by line item, e.g. "gpt-5, input".
    let lineItem: String?

    enum CodingKeys: String, CodingKey {
      case amount
      case lineItem = "line_item"
    }
  }
  struct Bucket: Decodable {
    let results: [Result]?
  }
  let data: [Bucket]?
  let hasMore: Bool?
  let nextPage: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case nextPage = "next_page"
  }
}

private struct AnthropicCostPage: Decodable {
  struct Result: Decodable {
    let amount: String?
    /// Both present only when the request grouped by description.
    let model: String?
    let description: String?
  }
  struct Bucket: Decodable {
    let results: [Result]?
  }
  let data: [Bucket]?
  let hasMore: Bool?
  let nextPage: String?

  enum CodingKeys: String, CodingKey {
    case data
    case hasMore = "has_more"
    case nextPage = "next_page"
  }
}

private struct OpenRouterKeyEnvelope: Decodable {
  struct FreeModelRequests: Decodable {
    let used: Int?
    let limit: Int?
    let remaining: Int?
  }
  struct Key: Decodable {
    let label: String?
    let usage: Double?
    let usageDaily: Double?
    let usageWeekly: Double?
    let usageMonthly: Double?
    let limit: Double?
    let limitRemaining: Double?
    let isFreeTier: Bool?
    let freeModelDailyRequests: FreeModelRequests?

    enum CodingKeys: String, CodingKey {
      case label, usage, limit
      case usageDaily = "usage_daily"
      case usageWeekly = "usage_weekly"
      case usageMonthly = "usage_monthly"
      case limitRemaining = "limit_remaining"
      case isFreeTier = "is_free_tier"
      case freeModelDailyRequests = "free_model_daily_requests"
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
