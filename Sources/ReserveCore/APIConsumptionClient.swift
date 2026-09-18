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
  case deepSeek
  case moonshot

  public var id: String { self.rawValue }

  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .openRouter: "OpenRouter"
    case .xAI: "xAI"
    case .typeSafe: "TypeSafe"
    case .deepSeek: "DeepSeek"
    case .moonshot: "Moonshot"
    }
  }

  /// What kind of key the provider issues. OpenAI and Anthropic admin keys and
  /// xAI management keys read billing and cannot call a model. OpenRouter,
  /// TypeSafe, DeepSeek and Moonshot issue ordinary API keys: the key that reads
  /// the account can also call models, so a dedicated key is the one to paste.
  public var keyKind: String {
    switch self {
    case .openAI: "Admin key"
    case .anthropic: "Admin key"
    case .openRouter: "API key"
    case .xAI: "Management key"
    case .typeSafe: "API key"
    case .deepSeek: "API key"
    case .moonshot: "API key"
    }
  }

  public var keyHint: String {
    switch self {
    case .openAI: "sk-admin-…"
    case .anthropic: "sk-ant-admin…"
    case .openRouter: "sk-or-…"
    case .xAI: "xai-…"
    case .typeSafe: "ts-…"
    case .deepSeek: "sk-…"
    case .moonshot: "sk-…"
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
    case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
    case .moonshot: URL(string: "https://platform.kimi.ai/console/api-keys")!
    }
  }

  var endpointHost: String {
    switch self {
    case .openAI: "api.openai.com"
    case .anthropic: "api.anthropic.com"
    case .openRouter: "openrouter.ai"
    case .xAI: "management-api.x.ai"
    case .typeSafe: "api.typesafe.ai"
    case .deepSeek: "api.deepseek.com"
    // The international platform only, which reports USD. api.moonshot.cn
    // serves China-issued keys in CNY; those keys are not accepted here.
    case .moonshot: "api.moonshot.ai"
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
  /// Everything else the provider reported, shown only when the row is opened.
  public let details: [UsageDetail]

  public init(
    provider: APIConsumptionProvider,
    windows: [APIConsumptionWindow],
    breakdown: [APIConsumptionItem] = [],
    note: APIConsumptionNote? = nil,
    fetchedAt: Date = Date(),
    source: String,
    details: [UsageDetail] = []
  ) {
    self.provider = provider
    self.details = UsageDetail.sanitized(details)
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
    case provider, windows, breakdown, note, fetchedAt, source, details
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(self.provider, forKey: .provider)
    try container.encode(self.windows, forKey: .windows)
    try container.encode(self.breakdown, forKey: .breakdown)
    try container.encodeIfPresent(self.note, forKey: .note)
    try container.encode(self.fetchedAt, forKey: .fetchedAt)
    try container.encode(self.source, forKey: .source)
    let persistable = self.details.filter { !$0.isPersonal }
    if !persistable.isEmpty { try container.encode(persistable, forKey: .details) }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      provider: try container.decode(APIConsumptionProvider.self, forKey: .provider),
      windows: try container.decode([APIConsumptionWindow].self, forKey: .windows),
      breakdown: try container.decodeIfPresent([APIConsumptionItem].self, forKey: .breakdown) ?? [],
      note: try container.decodeIfPresent(APIConsumptionNote.self, forKey: .note),
      fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
      source: try container.decode(String.self, forKey: .source),
      details: (try? container.decodeIfPresent([UsageDetail].self, forKey: .details)) ?? [])
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

  static func store(for provider: APIConsumptionProvider) -> KeychainKeyStore {
    KeychainKeyStore(
      service: Self.service, account: Self.account(for: provider),
      displayName: provider.displayName, keyKind: provider.keyKind,
      label: "Reserve \(provider.displayName) consumption key")
  }

  #if canImport(Security)
    public static func hasKey(for provider: APIConsumptionProvider) -> Bool {
      Self.store(for: provider).hasKey()
    }

    /// Replaces any key already stored for this provider. The value never
    /// leaves this process except as an `Authorization` header on the fixed
    /// provider host.
    public static func save(_ key: String, for provider: APIConsumptionProvider) throws {
      try Self.store(for: provider).save(key)
    }

    public static func load(for provider: APIConsumptionProvider) throws -> String {
      try Self.store(for: provider).load()
    }

    public static func delete(for provider: APIConsumptionProvider) {
      Self.store(for: provider).delete()
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
  #endif

  /// Paste often includes wrapping newlines. Those are stripped.
  static func normalized(
    _ key: String,
    for provider: APIConsumptionProvider
  ) throws -> String {
    try KeychainKeyStore.normalized(key, displayName: provider.displayName)
  }
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
    case .deepSeek: return try await self.fetchDeepSeek(key)
    case .moonshot: return try await self.fetchMoonshot(key)
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
    var byDay: [Date: Int] = [:]
    for page in pages.pages {
      for bucket in page.data ?? [] {
        let day = bucket.startTime.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        for result in bucket.results ?? [] {
          let amount = Self.minorUnits(from: result.amount?.value)
          minorUnits += amount
          if let day { byDay[day, default: 0] += amount }
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
      source: pages.grouped ? "OpenAI Costs API" : "OpenAI Costs API (ungrouped)",
      details: Self.dailyDetails(byDay, now: now)
        + Self.breakdownDetails(byLineItem))
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
    var byDay: [Date: Int] = [:]
    for page in pages.pages {
      for bucket in page.data ?? [] {
        let day = UsageDateParser.iso8601(bucket.startingAt)
        for result in bucket.results ?? [] {
          let amount = Self.minorUnits(fromDecimalCents: result.amount)
          minorUnits += amount
          if let day { byDay[day, default: 0] += amount }
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
      source: pages.grouped ? "Anthropic Cost API" : "Anthropic Cost API (ungrouped)",
      details: Self.dailyDetails(byDay, now: now)
        + Self.breakdownDetails(byModel))
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
      source: "OpenRouter key API",
      details: Self.openRouterDetails(usage))
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
        source: "xAI Management API",
        details: [
          UsageDetail("Balance", Self.money(remaining)),
          UsageDetail("Credits bought", Self.money(purchased)),
          UsageDetail("Spent from credits", Self.money(purchased - remaining)),
        ])
    }
    // Without a trustworthy cap, report the balance as the balance rather than
    // inventing a spend figure to sit in a spend field.
    return APIConsumptionSnapshot(
      provider: .xAI,
      windows: [],
      note: APIConsumptionNote(
        headline: Self.money(remaining), detail: "prepaid credits left"),
      fetchedAt: now,
      source: "xAI Management API",
      details: [UsageDetail("Balance", Self.money(remaining))]
        + (purchased > 0 ? [UsageDetail("Credits bought", Self.money(purchased))] : []))
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
    let named = page.models.filter {
      !($0.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
    }
    let names = named.compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
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
      source: "TypeSafe Models API",
      details: [UsageDetail("Price", "$0.042 per million input tokens · output free")]
        + named.prefix(UsageDetail.maximumCount - 1).map { model in
          let name = model.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          let released = UsageDateParser.iso8601(model.releaseDate)
            ?? model.releaseDate.flatMap { $0.count == 10 ? UsageDateParser.iso8601($0 + "T00:00:00Z") : nil }
          let parts = [
            model.description?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty,
            released.map { "released \(UsageDetailFormat.date($0))" },
          ].compactMap { $0 }
          return UsageDetail(name, parts.isEmpty ? "Available" : parts.joined(separator: " · "))
        })
  }

  // MARK: DeepSeek

  /// DeepSeek reports what is left of prepaid credit, not spend, so the balance
  /// is a note rather than a window, as xAI's is when it cannot derive a cap.
  /// Amounts are decimal strings and are parsed as decimals, so no binary
  /// rounding creeps in. An account can hold a balance in both CNY and USD; USD
  /// leads when present and the other is named alongside it.
  private func fetchDeepSeek(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    guard let url = URL(string: "https://api.deepseek.com/user/balance") else {
      throw UsageProviderError.invalidResponse("DeepSeek balance URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data = try await self.data(for: request, provider: .deepSeek)
    let decoded = try Self.decode(DeepSeekBalance.self, from: data, provider: .deepSeek)
    let infos = (decoded.balanceInfos ?? []).filter { !$0.currencyCode.isEmpty }
    guard let lead = infos.first(where: { $0.currencyCode == "USD" }) ?? infos.first else {
      throw UsageProviderError.invalidResponse("DeepSeek did not return a balance.")
    }
    let currency = lead.currencyCode
    let total = Self.minorUnits(fromDecimalAmount: lead.totalBalance)
    let granted = Self.minorUnits(fromDecimalAmount: lead.grantedBalance)
    let toppedUp = Self.minorUnits(fromDecimalAmount: lead.toppedUpBalance)
    let others = infos.filter { $0.currencyCode != currency }.map {
      Self.money(Self.minorUnits(fromDecimalAmount: $0.totalBalance), currency: $0.currencyCode)
    }

    var parts: [String] = []
    if decoded.isAvailable == false { parts.append("balance too low to make calls") }
    parts.append("\(Self.money(granted, currency: currency)) granted")
    parts.append("\(Self.money(toppedUp, currency: currency)) topped up")
    parts += others.map { "also \($0)" }

    var details = [
      UsageDetail("Balance", Self.money(total, currency: currency)),
      UsageDetail("Granted", Self.money(granted, currency: currency)),
      UsageDetail("Topped up", Self.money(toppedUp, currency: currency)),
    ]
    if !others.isEmpty {
      details.append(UsageDetail("Other balance", others.joined(separator: " · ")))
    }
    if let available = decoded.isAvailable {
      details.append(UsageDetail("Can make calls", available ? "Yes" : "No, balance too low"))
    }
    return APIConsumptionSnapshot(
      provider: .deepSeek,
      windows: [],
      note: APIConsumptionNote(
        headline: Self.money(total, currency: currency),
        detail: parts.joined(separator: " · ")),
      fetchedAt: now,
      source: "DeepSeek Balance API",
      details: details)
  }

  // MARK: Moonshot

  /// Moonshot's international platform reports the account's remaining credit
  /// in USD: vouchers plus cash, where cash can go negative. Like DeepSeek's it
  /// is a balance, so it is a note rather than a spend window.
  private func fetchMoonshot(_ key: String) async throws -> APIConsumptionSnapshot {
    let now = self.now()
    guard let url = URL(string: "https://api.moonshot.ai/v1/users/me/balance") else {
      throw UsageProviderError.invalidResponse("Moonshot balance URL could not be formed.")
    }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    let data = try await self.data(for: request, provider: .moonshot)
    let decoded = try Self.decode(MoonshotBalanceEnvelope.self, from: data, provider: .moonshot)
    guard decoded.status != false, decoded.code == nil || decoded.code == 0,
      let balance = decoded.data, let reported = balance.availableBalance
    else {
      throw UsageProviderError.invalidResponse("Moonshot did not return a balance.")
    }
    let available = Self.signedMinorUnits(from: reported)
    let voucher = Self.signedMinorUnits(from: balance.voucherBalance)
    let cash = Self.signedMinorUnits(from: balance.cashBalance)

    var parts: [String] = []
    // Moonshot refuses calls once the available balance reaches zero.
    if available <= 0 { parts.append("balance too low to make calls") }
    parts.append("\(Self.money(voucher, currency: "USD")) voucher")
    parts.append("\(Self.money(cash, currency: "USD")) cash")
    return APIConsumptionSnapshot(
      provider: .moonshot,
      windows: [],
      note: APIConsumptionNote(
        headline: Self.money(available, currency: "USD"),
        detail: parts.joined(separator: " · ")),
      fetchedAt: now,
      source: "Moonshot Balance API",
      details: [
        UsageDetail("Balance", Self.money(available, currency: "USD")),
        UsageDetail("Vouchers", Self.money(voucher, currency: "USD")),
        UsageDetail("Cash", Self.money(cash, currency: "USD")),
        UsageDetail("Can make calls", available > 0 ? "Yes" : "No, balance too low"),
      ])
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

  /// Today, the last seven days and the busiest day, from daily cost buckets.
  static func dailyDetails(_ byDay: [Date: Int], now: Date) -> [UsageDetail] {
    guard !byDay.isEmpty else { return [] }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    let today = calendar.startOfDay(for: now)
    let weekStart = today.addingTimeInterval(-6 * 86_400)
    var details = [
      UsageDetail("Today", Self.money(byDay.filter { $0.key >= today }.values.reduce(0, +)))
    ]
    // The buckets start on the 1st, so a full week only exists from the 7th.
    if calendar.component(.day, from: today) >= 7 {
      details.append(UsageDetail(
        "Last 7 days", Self.money(byDay.filter { $0.key >= weekStart }.values.reduce(0, +))))
    }
    if let busiest = byDay.max(by: { $0.value < $1.value }), busiest.value > 0 {
      details.append(UsageDetail(
        "Busiest day",
        "\(Self.money(busiest.value)) on \(busiest.key.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone)))"))
    }
    let days = max(1, calendar.dateComponents([.day], from: byDay.keys.min() ?? today, to: today).day.map { $0 + 1 } ?? 1)
    details.append(UsageDetail(
      "Daily average", Self.money(byDay.values.reduce(0, +) / days)))
    return details
  }

  /// Every contributor to this month's spend, largest first.
  static func breakdownDetails(_ items: [String: Int]) -> [UsageDetail] {
    items.filter { $0.value > 0 }
      .sorted { $0.value > $1.value }
      .prefix(8)
      .map { UsageDetail($0.key, Self.money($0.value)) }
  }

  fileprivate static func openRouterDetails(_ key: OpenRouterKeyEnvelope.Key) -> [UsageDetail] {
    var details: [UsageDetail] = []
    if let label = key.label?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty {
      details.append(UsageDetail("Key", label))
    }
    details.append(UsageDetail("All time", Self.money(Self.minorUnits(from: key.usage))))
    if let cap = key.limit, cap > 0 {
      var text = "\(Self.money(Self.minorUnits(from: cap)))"
      if let reset = key.limitReset?.nonEmpty { text += " · resets \(reset)" }
      if key.includeBYOKInLimit == true { text += " · includes your own keys" }
      details.append(UsageDetail("Credit limit", text))
    } else {
      details.append(UsageDetail("Credit limit", "None"))
    }
    let byok = Self.minorUnits(from: key.byokUsage)
    if byok > 0 {
      details.append(UsageDetail(
        "Your own provider keys",
        "\(Self.money(Self.minorUnits(from: key.byokUsageMonthly))) this month · \(Self.money(byok)) all time"))
    }
    if let free = key.freeModelDailyRequests, let limit = free.limit, limit > 0 {
      details.append(UsageDetail("Free-model requests today", "\(free.used ?? 0) of \(limit)"))
    }
    if key.isFreeTier == true { details.append(UsageDetail("Tier", "Free")) }
    if let expires = UsageDateParser.iso8601(key.expiresAt) {
      details.append(UsageDetail("Key expires", UsageDetailFormat.date(expires)))
    }
    return details
  }

  static func money(_ minorUnits: Int) -> String {
    let amount = Double(minorUnits) / 100
    return amount >= 100
      ? String(format: "$%.0f", amount)
      : String(format: "$%.2f", amount)
  }

  /// A balance in its own currency. Dollars keep the `money` format, yuan take
  /// the same shape with their own sign, and anything else leads with its code.
  /// A negative balance keeps its sign in front of the symbol.
  static func money(_ minorUnits: Int, currency: String) -> String {
    let sign = minorUnits < 0 ? "-" : ""
    let magnitude = Self.money(minorUnits == Int.min ? Int.max : abs(minorUnits))
    let amount = magnitude.dropFirst()
    switch currency.uppercased() {
    case "USD": return sign + magnitude
    case "CNY": return sign + "¥" + amount
    default: return sign + currency.uppercased() + " " + amount
    }
  }

  /// A signed amount in major units, for balances that can legitimately go
  /// negative (Moonshot's cash balance), into minor units.
  static func signedMinorUnits(from amount: Double?) -> Int {
    guard let amount, amount.isFinite else { return 0 }
    let scaled = (amount * 100).rounded()
    if scaled >= Double(Int.max) { return Int.max }
    if scaled <= -Double(Int.max) { return -Int.max }
    return Int(scaled)
  }

  /// A decimal string in major units, as DeepSeek reports "110.00", into minor
  /// units without passing through a binary floating-point value. Signed, so
  /// an account in arrears is never shown as holding money.
  static func minorUnits(fromDecimalAmount text: String?) -> Int {
    guard let text else { return 0 }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")),
      !value.isNaN
    else { return 0 }
    let cents = NSDecimalNumber(decimal: value * 100).rounding(
      accordingToBehavior: Self.centRounding)
    if cents.compare(NSDecimalNumber(value: Int.max)) != .orderedAscending { return Int.max }
    if cents.compare(NSDecimalNumber(value: -Int.max)) != .orderedDescending { return -Int.max }
    return cents.intValue
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
    let startTime: Int?

    enum CodingKeys: String, CodingKey {
      case results
      case startTime = "start_time"
    }
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
    let startingAt: String?

    enum CodingKeys: String, CodingKey {
      case results
      case startingAt = "starting_at"
    }
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
    var limitReset: String? = nil
    var includeBYOKInLimit: Bool? = nil
    var byokUsage: Double? = nil
    var byokUsageMonthly: Double? = nil
    var expiresAt: String? = nil

    enum CodingKeys: String, CodingKey {
      case limitReset = "limit_reset"
      case includeBYOKInLimit = "include_byok_in_limit"
      case byokUsage = "byok_usage"
      case byokUsageMonthly = "byok_usage_monthly"
      case expiresAt = "expires_at"
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

private struct DeepSeekBalance: Decodable {
  struct Info: Decodable {
    let currency: String?
    let totalBalance: String?
    let grantedBalance: String?
    let toppedUpBalance: String?

    var currencyCode: String {
      (self.currency ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    enum CodingKeys: String, CodingKey {
      case currency
      case totalBalance = "total_balance"
      case grantedBalance = "granted_balance"
      case toppedUpBalance = "topped_up_balance"
    }
  }
  let isAvailable: Bool?
  let balanceInfos: [Info]?

  enum CodingKeys: String, CodingKey {
    case isAvailable = "is_available"
    case balanceInfos = "balance_infos"
  }
}

private struct MoonshotBalanceEnvelope: Decodable {
  struct Balance: Decodable {
    let availableBalance: Double?
    let voucherBalance: Double?
    let cashBalance: Double?

    enum CodingKeys: String, CodingKey {
      case availableBalance = "available_balance"
      case voucherBalance = "voucher_balance"
      case cashBalance = "cash_balance"
    }
  }
  let code: Int?
  let data: Balance?
  let status: Bool?
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
