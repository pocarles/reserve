import CryptoKit
import Foundation

#if canImport(Security)
  import LocalAuthentication
  import Security
#endif

public struct CursorProvider: UsageProvider {
  public static let serviceHost = "api2.cursor.sh"
  public static let maximumResponseBytes = 1_048_576
  public static let maximumEventCount = 5_000
  public static let maximumPaginationCount = 20
  public static let eventPageSize = 250

  public let id: ProviderID = .cursor
  private let environment: [String: String]
  private let allowKeychainRead: Bool
  private let allowKeychainInteraction: Bool
  private let keychainItemExists: @Sendable () -> Bool
  private let agentLocator: @Sendable ([String: String]) -> String?
  private let statusRunner: @Sendable (String, [String], [String: String]) async throws -> String
  private let credentialLoader: @Sendable (Bool) async throws -> CursorCredential
  private let requestHandler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

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
    self.keychainItemExists = {
      #if canImport(Security)
        CursorCredentialLoader.keychainItemExistsWithoutPrompt()
      #else
        false
      #endif
    }
    self.agentLocator = { BinaryLocator.find("cursor-agent", environment: $0) }
    self.statusRunner = { executable, arguments, environment in
      try await ProcessRunner.output(
        executable: executable, arguments: arguments, environment: environment,
        timeout: .seconds(6))
    }
    self.credentialLoader = { allowInteraction in
      try await CursorCredentialLoader.load(allowInteraction: allowInteraction)
    }
    self.requestHandler = {
      try await ProviderHTTPSession.boundedData(
        for: $0, using: session, maximumBytes: Self.maximumResponseBytes)
    }
  }

  init(
    environment: [String: String],
    allowKeychainRead: Bool,
    allowKeychainInteraction: Bool = false,
    keychainItemExists: @escaping @Sendable () -> Bool = { false },
    agentLocator: @escaping @Sendable ([String: String]) -> String? = { _ in "/usr/bin/true" },
    statusRunner: @escaping @Sendable (String, [String], [String: String]) async throws -> String,
    credentialLoader: @escaping @Sendable (Bool) async throws -> CursorCredential,
    requestHandler: @escaping @Sendable (URLRequest) async throws -> (Data, URLResponse)
  ) {
    self.environment = environment
    self.allowKeychainRead = allowKeychainRead
    self.allowKeychainInteraction = allowKeychainInteraction
    self.keychainItemExists = keychainItemExists
    self.agentLocator = agentLocator
    self.statusRunner = statusRunner
    self.credentialLoader = credentialLoader
    self.requestHandler = requestHandler
  }

  public func fetch() async throws -> UsageSnapshot {
    guard self.allowKeychainRead else {
      if self.keychainItemExists() { throw UsageProviderError.keychainConsentRequired(.cursor) }
      throw UsageProviderError.credentialsNotFound(
        "Cursor is not connected to Reserve. Use Sign in or Allow access.")
    }
    guard let executable = self.agentLocator(self.environment) else {
      throw UsageProviderError.executableNotFound("Cursor Agent")
    }

    let status = try await self.statusRunner(
      executable, ["status", "--format", "json"],
      BinaryLocator.childEnvironment(self.environment))
    try Self.validateStatusOutput(status)

    let credential = try await self.credentialLoader(self.allowKeychainInteraction)
    let client = CursorRPCClient(accessToken: credential.accessToken, handler: self.requestHandler)
    let current = try await client.call(
      .currentPeriodUsage, body: Data(#"{"includePooledUsage":false}"#.utf8),
      as: CursorCurrentPeriodUsageResponse.self)
    let plan = try await client.call(
      .planInfo, body: Data("{}".utf8), as: CursorPlanInfoResponse.self)
    let hardLimit = try? await client.call(
      .hardLimit, body: Data("{}".utf8), as: CursorHardLimitResponse.self)

    let billingStart = try Self.date(milliseconds: current.billingCycleStart)
    let billingEnd = try Self.date(
      milliseconds: plan.planInfo?.billingCycleEnd ?? current.billingCycleEnd)
    let windowMinutes = Self.windowMinutes(start: billingStart, end: billingEnd)
    let windows = try Self.windows(
      usage: current.planUsage, resetsAt: billingEnd, windowMinutes: windowMinutes)
    guard !windows.isEmpty else {
      throw UsageProviderError.unavailable("Cursor did not return individual plan usage pools.")
    }

    let accountUsage: LocalUsageSummary?
    let detailedUsageUnavailable: Bool
    do {
      accountUsage = try await Self.fetchAccountUsage(
        client: client, billingStart: billingStart, now: Date())
      detailedUsageUnavailable = accountUsage == nil
    } catch let error as CursorDetailedUsageUnavailable {
      _ = error
      accountUsage = nil
      detailedUsageUnavailable = true
    } catch let error as UsageProviderError {
      switch error {
      case .unauthorized, .rateLimited, .timedOut, .unavailable, .invalidResponse:
        accountUsage = nil
        detailedUsageUnavailable = true
      default:
        throw error
      }
    }

    let monthlyPrice = Self.monthlyPriceMinorUnits(plan.planInfo?.price)
    return UsageSnapshot(
      provider: .cursor,
      planName: CursorPlanFormatter.plan(
        from: plan.planInfo?.planName, monthlyPriceMinorUnits: monthlyPrice),
      windows: windows,
      source: "Cursor DashboardService",
      includedSpend: Self.includedSpend(current: current, hardLimit: hardLimit),
      billingRenewsAt: billingEnd,
      monthlyPriceMinorUnits: monthlyPrice,
      accountUsage: accountUsage,
      detailedUsageUnavailable: detailedUsageUnavailable)
  }

  public static func keychainCredentialIsAvailableWithoutPrompt() -> Bool {
    #if canImport(Security)
      CursorCredentialLoader.keychainItemExistsWithoutPrompt()
    #else
      false
    #endif
  }

  static func validateStatusOutput(_ output: String) throws {
    guard let data = output.data(using: .utf8), !data.isEmpty,
      data.count <= 65_536,
      let object = try? JSONSerialization.jsonObject(with: data),
      let dictionary = object as? [String: Any]
    else {
      throw UsageProviderError.invalidResponse("cursor-agent status did not return one JSON object")
    }
    let authenticated = dictionary["isAuthenticated"] as? Bool
      ?? dictionary["authenticated"] as? Bool
      ?? dictionary["loggedIn"] as? Bool
    let hasAccessToken = dictionary["hasAccessToken"] as? Bool ?? authenticated
    guard authenticated == true, hasAccessToken == true else {
      throw UsageProviderError.unauthorized(
        "Cursor authentication expired. Use Sign in to authenticate again.")
    }
  }

  static func windows(
    usage: CursorPlanUsage?,
    resetsAt: Date?,
    windowMinutes: Int?
  ) throws -> [UsageWindow] {
    guard let usage else { return [] }
    let cursorModels = try Self.percent(
      reported: usage.autoPercentUsed, spend: usage.autoSpend, limit: usage.autoLimit,
      field: "Cursor Models")
    let otherModels = try Self.percent(
      reported: usage.apiPercentUsed, spend: usage.apiSpend, limit: usage.apiLimit,
      field: "Other Models")
    return [
      cursorModels.map {
        UsageWindow(
          id: "cursor-models", label: "Cursor Models", usedPercent: $0,
          windowMinutes: windowMinutes, resetsAt: resetsAt)
      },
      otherModels.map {
        UsageWindow(
          id: "other-models", label: "Other Models", usedPercent: $0,
          windowMinutes: windowMinutes, resetsAt: resetsAt)
      },
    ].compactMap { $0 }
  }

  private static func percent(
    reported: Double?, spend: Int?, limit: Int?, field: String
  ) throws -> Double? {
    if let reported {
      guard reported.isFinite, reported >= 0 else {
        throw UsageProviderError.invalidResponse("Cursor returned malformed \(field) usage")
      }
      return min(100, reported)
    }
    guard let spend, let limit else { return nil }
    guard spend >= 0, limit > 0 else {
      if spend == 0, limit == 0 { return nil }
      throw UsageProviderError.invalidResponse("Cursor returned malformed \(field) allowance")
    }
    return min(100, Double(spend) / Double(limit) * 100)
  }

  static func includedSpend(
    current: CursorCurrentPeriodUsageResponse,
    hardLimit: CursorHardLimitResponse?
  ) -> IncludedSpend? {
    let usage = current.spendLimitUsage
    let used = max(0, usage?.individualUsed ?? usage?.totalSpend ?? 0)
    let disabled = hardLimit?.noUsageBasedAllowed == true
      || hardLimit?.onDemandSpendDisabledByOrganization == true
      || usage?.limitType.localizedCaseInsensitiveContains("disabled") == true
      || usage?.individualLimit == 0
    if disabled {
      return IncludedSpend(
        label: "On-demand spending", usedMinorUnits: used, limitMinorUnits: 0,
        limitState: .disabled)
    }
    if usage?.limitType.localizedCaseInsensitiveContains("unlimited") == true
      || hardLimit?.hardLimit == Int(Int32.max)
    {
      return IncludedSpend(
        label: "On-demand spending", usedMinorUnits: used, limitMinorUnits: 0,
        limitState: .unlimited)
    }
    let reportedLimit = usage?.individualLimit
    let fallbackLimit: Int? = hardLimit.flatMap {
      guard $0.hardLimit > 0 else { return nil }
      let result = $0.hardLimit.multipliedReportingOverflow(by: 100)
      return result.overflow ? nil : result.partialValue
    }
    if let limit = reportedLimit ?? fallbackLimit, limit > 0 {
      return IncludedSpend(
        label: "On-demand spending", usedMinorUnits: used, limitMinorUnits: limit)
    }
    if let hardLimit, hardLimit.hardLimit <= 0 {
      return IncludedSpend(
        label: "On-demand spending", usedMinorUnits: used, limitMinorUnits: 0,
        limitState: .disabled)
    }
    return nil
  }

  static func monthlyPriceMinorUnits(_ value: String?) -> Int? {
    guard let value,
      let range = value.range(of: #"[0-9]+(?:\.[0-9]{1,2})?"#, options: .regularExpression)
    else { return nil }
    let number = NSDecimalNumber(string: String(value[range]))
    guard number != .notANumber else { return nil }
    let cents = number.multiplying(by: 100).rounding(
      accordingToBehavior: NSDecimalNumberHandler(
        roundingMode: .plain, scale: 0, raiseOnExactness: false,
        raiseOnOverflow: false, raiseOnUnderflow: false, raiseOnDivideByZero: false))
    guard cents.compare(NSDecimalNumber.zero) != .orderedAscending,
      cents.compare(NSDecimalNumber(value: Int.max)) != .orderedDescending
    else { return nil }
    return cents.intValue
  }

  private static func date(milliseconds: Int64?) throws -> Date? {
    guard let milliseconds else { return nil }
    guard milliseconds >= 0 else {
      throw UsageProviderError.invalidResponse("Cursor returned a malformed billing date")
    }
    let seconds = Double(milliseconds) / 1_000
    guard seconds.isFinite else {
      throw UsageProviderError.invalidResponse("Cursor returned a malformed billing date")
    }
    let value = Date(timeIntervalSince1970: seconds)
    guard abs(value.timeIntervalSinceNow) <= UsageWindow.maximumResetDistance else { return nil }
    return value
  }

  private static func windowMinutes(start: Date?, end: Date?) -> Int? {
    guard let start, let end, end > start else { return nil }
    let minutes = end.timeIntervalSince(start) / 60
    guard minutes.isFinite, minutes >= 1,
      minutes <= Double(UsageWindow.maximumWindowMinutes)
    else { return nil }
    return Int(minutes)
  }

  private static func fetchAccountUsage(
    client: CursorRPCClient,
    billingStart: Date?,
    now: Date
  ) async throws -> LocalUsageSummary? {
    let me = try await client.call(.me, body: Data("{}".utf8), as: CursorMeResponse.self)
    guard me.userID > 0 else {
      throw CursorDetailedUsageUnavailable()
    }
    let teamID: Int
    if let reportedTeamID = me.teamID, reportedTeamID > 0 {
      teamID = reportedTeamID
    } else {
      let teams = try await client.call(
        .teams, body: Data(#"{"activeOnly":true}"#.utf8), as: CursorTeamsResponse.self)
      guard let individualTeamID = teams.individualTeamID else {
        throw CursorDetailedUsageUnavailable()
      }
      teamID = individualTeamID
    }
    let calendar = Calendar.current
    let start30 = calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)) ?? now
    let startToday = calendar.startOfDay(for: now)
    let cycleStart = billingStart ?? start30
    let end = now.addingTimeInterval(1)

    async let thirty = Self.aggregate(
      client: client, teamID: teamID, userID: me.userID, start: start30, end: end)
    async let cycle = Self.aggregate(
      client: client, teamID: teamID, userID: me.userID, start: cycleStart, end: end)
    async let today = Self.aggregate(
      client: client, teamID: teamID, userID: me.userID, start: startToday, end: end)
    async let events = Self.events(
      client: client, teamID: teamID, userID: me.userID, start: start30, end: end)

    let (thirtyValue, cycleValue, todayValue, eventValues) = try await (
      thirty, cycle, today, events)
    let daily = CursorUsageAggregator.dailySeries(events: eventValues, start: start30, now: now)
    return LocalUsageSummary(
      provider: .cursor,
      periodDays: 30,
      inputTokens: thirtyValue.totalInputTokens,
      cachedInputTokens: thirtyValue.totalCacheReadTokens,
      cacheWriteInputTokens: thirtyValue.totalCacheWriteTokens,
      outputTokens: thirtyValue.totalOutputTokens,
      apiEquivalentCostUSD: thirtyValue.totalCostCents / 100,
      isCostEstimate: false,
      todayTokens: todayValue.totalTokens,
      cycleTokens: cycleValue.totalTokens,
      cycleAPIEquivalentCostUSD: cycleValue.totalCostCents / 100,
      cycleStartedAt: cycleStart,
      isCycleCostEstimate: false,
      fetchedAt: now,
      source: "Cursor account usage",
      origin: .providerAccount,
      modelCosts: thirtyValue.aggregations.map(\.modelUsageCost).sorted {
        $0.costUSD > $1.costUSD
      },
      dailyTokens: daily)
  }

  private static func aggregate(
    client: CursorRPCClient,
    teamID: Int,
    userID: Int,
    start: Date,
    end: Date
  ) async throws -> CursorAggregatedUsageResponse {
    let body = try JSONSerialization.data(withJSONObject: [
      "teamId": teamID,
      "userId": userID,
      "startDate": String(Int64(start.timeIntervalSince1970 * 1_000)),
      "endDate": String(Int64(end.timeIntervalSince1970 * 1_000)),
    ])
    return try await client.call(.aggregatedUsageEvents, body: body)
  }

  static func events(
    client: CursorRPCClient,
    teamID: Int,
    userID: Int,
    start: Date,
    end: Date
  ) async throws -> [CursorUsageEvent] {
    var result: [CursorUsageEvent] = []
    var seen: Set<String> = []
    var rawCount = 0
    var expectedCount: Int?
    for page in 1...Self.maximumPaginationCount {
      let body = try JSONSerialization.data(withJSONObject: [
        "teamId": teamID,
        "userId": userID,
        "startDate": String(Int64(start.timeIntervalSince1970 * 1_000)),
        "endDate": String(Int64(end.timeIntervalSince1970 * 1_000)),
        "page": page,
        "pageSize": Self.eventPageSize,
      ])
      let response: CursorFilteredUsageResponse = try await client.call(
        .filteredUsageEvents, body: body)
      guard let reportedCount = response.totalUsageEventsCount,
        reportedCount >= 0, reportedCount <= Self.maximumEventCount,
        expectedCount == nil || expectedCount == reportedCount
      else {
        throw CursorDetailedUsageUnavailable()
      }
      expectedCount = reportedCount
      rawCount += response.usageEventsDisplay.count
      guard rawCount <= Self.maximumEventCount else {
        throw CursorDetailedUsageUnavailable()
      }
      for event in response.usageEventsDisplay where seen.insert(event.fingerprint).inserted {
        result.append(event)
      }
      if response.usageEventsDisplay.isEmpty || rawCount >= (expectedCount ?? 0) { break }
      if page == Self.maximumPaginationCount {
        throw CursorDetailedUsageUnavailable()
      }
    }
    if let expectedCount, rawCount != expectedCount {
      throw CursorDetailedUsageUnavailable()
    }
    return result
  }
}

struct CursorDetailedUsageUnavailable: Error {}

struct CursorCredential: Sendable {
  let accessToken: String
}

enum CursorCredentialLoader {
  static let account = "cursor-user"
  static let accessTokenService = "cursor-access-token"

  static func load(allowInteraction: Bool) async throws -> CursorCredential {
    #if canImport(Security)
      let context = LAContext()
      context.interactionNotAllowed = !allowInteraction
      if allowInteraction {
        context.localizedReason = "Show your Cursor plan limits in Reserve."
      }
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: Self.account,
        kSecAttrService as String: Self.accessTokenService,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnData as String: true,
        kSecUseAuthenticationContext as String: context,
      ]
      var result: CFTypeRef?
      let status = SecItemCopyMatching(query as CFDictionary, &result)
      if status == errSecInteractionNotAllowed || status == errSecUserCanceled
        || status == errSecAuthFailed
      {
        throw UsageProviderError.keychainConsentRequired(.cursor)
      }
      if status == errSecItemNotFound {
        throw UsageProviderError.credentialsNotFound(
          "Cursor Agent is not signed in. Use Sign in to authenticate.")
      }
      guard status == errSecSuccess, let data = result as? Data,
        data.count <= 65_536,
        let token = String(data: data, encoding: .utf8)?
          .trimmingCharacters(in: .whitespacesAndNewlines),
        !token.isEmpty
      else {
        throw UsageProviderError.credentialsNotFound(
          "Reserve could not read a usable Cursor access token from Keychain.")
      }
      return CursorCredential(accessToken: token)
    #else
      throw UsageProviderError.unavailable("Cursor Keychain access requires macOS.")
    #endif
  }

  static func keychainItemExistsWithoutPrompt() -> Bool {
    #if canImport(Security)
      let context = LAContext()
      context.interactionNotAllowed = true
      let query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrAccount as String: Self.account,
        kSecAttrService as String: Self.accessTokenService,
        kSecMatchLimit as String: kSecMatchLimitOne,
        kSecReturnAttributes as String: true,
        kSecUseAuthenticationContext as String: context,
      ]
      var result: CFTypeRef?
      return SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess
    #else
      false
    #endif
  }
}

enum CursorRPCMethod: String, Sendable {
  case currentPeriodUsage = "GetCurrentPeriodUsage"
  case planInfo = "GetPlanInfo"
  case hardLimit = "GetHardLimit"
  case me = "GetMe"
  case teams = "GetTeams"
  case filteredUsageEvents = "GetFilteredUsageEvents"
  case aggregatedUsageEvents = "GetAggregatedUsageEvents"
}

struct CursorRPCClient: Sendable {
  let accessToken: String
  let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)

  func call<T: Decodable>(
    _ method: CursorRPCMethod,
    body: Data,
    as type: T.Type = T.self
  ) async throws -> T {
    guard body.count <= 65_536,
      let url = URL(
        string: "https://\(CursorProvider.serviceHost)/aiserver.v1.DashboardService/\(method.rawValue)"),
      url.scheme == "https", url.host == CursorProvider.serviceHost
    else {
      throw UsageProviderError.invalidResponse("invalid Cursor RPC request")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = body
    request.timeoutInterval = 10
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("Bearer \(self.accessToken)", forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue("Reserve/1.0", forHTTPHeaderField: "User-Agent")

    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await self.handler(request)
    } catch let error as UsageProviderError {
      throw error
    } catch let error as URLError where error.code == .timedOut {
      throw UsageProviderError.timedOut("Cursor \(method.rawValue) request")
    } catch {
      throw UsageProviderError.unavailable(
        "Cursor usage request failed: \(error.localizedDescription)")
    }
    guard let http = response as? HTTPURLResponse else {
      throw UsageProviderError.invalidResponse("missing Cursor HTTP status")
    }
    switch http.statusCode {
    case 200: break
    case 401, 403:
      throw UsageProviderError.unauthorized(
        "Cursor authentication expired. Use Sign in to authenticate again.")
    case 429:
      throw UsageProviderError.rateLimited(
        retryAt: Self.retryDate(http.value(forHTTPHeaderField: "Retry-After")))
    default:
      throw UsageProviderError.unavailable(
        "Cursor usage request returned HTTP \(http.statusCode).")
    }
    guard data.count <= CursorProvider.maximumResponseBytes else {
      throw UsageProviderError.invalidResponse("Cursor response exceeded 1 MB")
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw UsageProviderError.invalidResponse("Cursor \(method.rawValue): \(error.localizedDescription)")
    }
  }

  private static func retryDate(_ value: String?, now: Date = Date()) -> Date? {
    guard let value, let seconds = TimeInterval(value), seconds.isFinite else { return nil }
    return now.addingTimeInterval(min(24 * 60 * 60, max(0, seconds)))
  }
}

enum CursorPlanFormatter {
  static func plan(from value: String?, monthlyPriceMinorUnits: Int? = nil) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")
    if normalized.contains("proplus") { return "Pro Plus" }
    if normalized.contains("ultra") { return "Ultra" }
    if normalized.contains("hobby") || normalized.contains("free") { return "Hobby" }
    if normalized.contains("pro") {
      switch monthlyPriceMinorUnits {
      case 6_000: return "Pro Plus"
      case 20_000: return "Ultra"
      default: return "Pro"
      }
    }
    return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
  }
}

struct CursorMeResponse: Decodable, Sendable {
  let userID: Int
  let teamID: Int?

  enum CodingKeys: String, CodingKey { case userID = "userId"; case teamID = "teamId" }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.userID = try container.decodeFlexibleIntIfPresent(forKey: .userID) ?? 0
    self.teamID = try container.decodeFlexibleIntIfPresent(forKey: .teamID)
  }
}

struct CursorTeamsResponse: Decodable, Sendable {
  let teams: [CursorTeam]

  var individualTeamID: Int? {
    let eligible = self.teams.filter(\.isIndividualCandidate)
    let billed = eligible.filter { $0.hasBilling == true || $0.subscriptionIsActive }
    if billed.count == 1 { return billed[0].id }
    return eligible.count == 1 ? eligible[0].id : nil
  }
}

struct CursorTeam: Decodable, Sendable {
  let id: Int
  let seats: Int
  let purchasedSeats: Int?
  let hasBilling: Bool?
  let isEnterprise: Bool
  let isDirectMember: Bool?
  let subscriptionStatus: String?

  enum CodingKeys: String, CodingKey {
    case id, seats, purchasedSeats, hasBilling, isEnterprise, isDirectMember, subscriptionStatus
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.id = try container.decodeFlexibleIntIfPresent(forKey: .id) ?? 0
    self.seats = try container.decodeFlexibleIntIfPresent(forKey: .seats) ?? 0
    self.purchasedSeats = try container.decodeFlexibleIntIfPresent(forKey: .purchasedSeats)
    self.hasBilling = try container.decodeIfPresent(Bool.self, forKey: .hasBilling)
    self.isEnterprise = try container.decodeIfPresent(Bool.self, forKey: .isEnterprise) ?? false
    self.isDirectMember = try container.decodeIfPresent(Bool.self, forKey: .isDirectMember)
    self.subscriptionStatus = try container.decodeIfPresent(String.self, forKey: .subscriptionStatus)
  }

  fileprivate var subscriptionIsActive: Bool {
    guard let subscriptionStatus else { return false }
    return ["active", "trialing"].contains(subscriptionStatus.lowercased())
  }

  fileprivate var isIndividualCandidate: Bool {
    let seatCount = max(self.seats, self.purchasedSeats ?? 0)
    return self.id > 0 && !self.isEnterprise && self.isDirectMember != false && seatCount <= 1
  }
}

struct CursorPlanInfoResponse: Decodable, Sendable {
  let planInfo: CursorPlanInfo?
}

struct CursorPlanInfo: Decodable, Sendable {
  let planName: String?
  let includedAmountCents: Int?
  let price: String?
  let billingCycleEnd: Int64?

  enum CodingKeys: String, CodingKey {
    case planName, includedAmountCents, price, billingCycleEnd
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.planName = try container.decodeIfPresent(String.self, forKey: .planName)
    self.includedAmountCents = try container.decodeFlexibleIntIfPresent(
      forKey: .includedAmountCents)
    self.price = try container.decodeIfPresent(String.self, forKey: .price)
    self.billingCycleEnd = try container.decodeFlexibleInt64IfPresent(forKey: .billingCycleEnd)
  }
}

struct CursorCurrentPeriodUsageResponse: Decodable, Sendable {
  let billingCycleStart: Int64?
  let billingCycleEnd: Int64?
  let planUsage: CursorPlanUsage?
  let spendLimitUsage: CursorSpendLimitUsage?
  let enabled: Bool?

  enum CodingKeys: String, CodingKey {
    case billingCycleStart, billingCycleEnd, planUsage, spendLimitUsage, enabled
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.billingCycleStart = try container.decodeFlexibleInt64IfPresent(
      forKey: .billingCycleStart)
    self.billingCycleEnd = try container.decodeFlexibleInt64IfPresent(forKey: .billingCycleEnd)
    self.planUsage = try container.decodeIfPresent(CursorPlanUsage.self, forKey: .planUsage)
    self.spendLimitUsage = try container.decodeIfPresent(
      CursorSpendLimitUsage.self, forKey: .spendLimitUsage)
    self.enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled)
  }
}

struct CursorPlanUsage: Decodable, Sendable {
  let totalSpend: Int?
  let includedSpend: Int?
  let remaining: Int?
  let limit: Int?
  let autoSpend: Int?
  let apiSpend: Int?
  let autoLimit: Int?
  let apiLimit: Int?
  let autoPercentUsed: Double?
  let apiPercentUsed: Double?
  let totalPercentUsed: Double?

  enum CodingKeys: String, CodingKey {
    case totalSpend, includedSpend, remaining, limit, autoSpend, apiSpend, autoLimit, apiLimit
    case autoPercentUsed, apiPercentUsed, totalPercentUsed
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.totalSpend = try container.decodeFlexibleIntIfPresent(forKey: .totalSpend)
    self.includedSpend = try container.decodeFlexibleIntIfPresent(forKey: .includedSpend)
    self.remaining = try container.decodeFlexibleIntIfPresent(forKey: .remaining)
    self.limit = try container.decodeFlexibleIntIfPresent(forKey: .limit)
    self.autoSpend = try container.decodeFlexibleIntIfPresent(forKey: .autoSpend)
    self.apiSpend = try container.decodeFlexibleIntIfPresent(forKey: .apiSpend)
    self.autoLimit = try container.decodeFlexibleIntIfPresent(forKey: .autoLimit)
    self.apiLimit = try container.decodeFlexibleIntIfPresent(forKey: .apiLimit)
    self.autoPercentUsed = try container.decodeFiniteDoubleIfPresent(forKey: .autoPercentUsed)
    self.apiPercentUsed = try container.decodeFiniteDoubleIfPresent(forKey: .apiPercentUsed)
    self.totalPercentUsed = try container.decodeFiniteDoubleIfPresent(forKey: .totalPercentUsed)
  }
}

struct CursorSpendLimitUsage: Decodable, Sendable {
  let totalSpend: Int?
  let individualLimit: Int?
  let individualUsed: Int?
  let individualRemaining: Int?
  let limitType: String
  let overallLimit: Int?
  let overallUsed: Int?
  let overallRemaining: Int?

  enum CodingKeys: String, CodingKey {
    case totalSpend, individualLimit, individualUsed, individualRemaining, limitType
    case overallLimit, overallUsed, overallRemaining
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.totalSpend = try container.decodeFlexibleIntIfPresent(forKey: .totalSpend)
    self.individualLimit = try container.decodeFlexibleIntIfPresent(forKey: .individualLimit)
    self.individualUsed = try container.decodeFlexibleIntIfPresent(forKey: .individualUsed)
    self.individualRemaining = try container.decodeFlexibleIntIfPresent(forKey: .individualRemaining)
    self.limitType = try container.decodeIfPresent(String.self, forKey: .limitType) ?? ""
    self.overallLimit = try container.decodeFlexibleIntIfPresent(forKey: .overallLimit)
    self.overallUsed = try container.decodeFlexibleIntIfPresent(forKey: .overallUsed)
    self.overallRemaining = try container.decodeFlexibleIntIfPresent(forKey: .overallRemaining)
  }
}

struct CursorHardLimitResponse: Decodable, Sendable {
  let hardLimit: Int
  let noUsageBasedAllowed: Bool
  let onDemandSpendDisabledByOrganization: Bool

  enum CodingKeys: String, CodingKey {
    case hardLimit, noUsageBasedAllowed, onDemandSpendDisabledByOrganization
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.hardLimit = try container.decodeFlexibleIntIfPresent(forKey: .hardLimit) ?? 0
    self.noUsageBasedAllowed = try container.decodeIfPresent(
      Bool.self, forKey: .noUsageBasedAllowed) ?? false
    self.onDemandSpendDisabledByOrganization = try container.decodeIfPresent(
      Bool.self, forKey: .onDemandSpendDisabledByOrganization) ?? false
  }
}

struct CursorAggregatedUsageResponse: Decodable, Sendable {
  let aggregations: [CursorModelAggregation]
  let totalInputTokens: Int64
  let totalOutputTokens: Int64
  let totalCacheWriteTokens: Int64
  let totalCacheReadTokens: Int64
  let totalCostCents: Double

  enum CodingKeys: String, CodingKey {
    case aggregations, totalInputTokens, totalOutputTokens, totalCacheWriteTokens
    case totalCacheReadTokens, totalCostCents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.aggregations = try container.decodeIfPresent(
      [CursorModelAggregation].self, forKey: .aggregations) ?? []
    self.totalInputTokens = try container.decodeFlexibleInt64IfPresent(
      forKey: .totalInputTokens) ?? 0
    self.totalOutputTokens = try container.decodeFlexibleInt64IfPresent(
      forKey: .totalOutputTokens) ?? 0
    self.totalCacheWriteTokens = try container.decodeFlexibleInt64IfPresent(
      forKey: .totalCacheWriteTokens) ?? 0
    self.totalCacheReadTokens = try container.decodeFlexibleInt64IfPresent(
      forKey: .totalCacheReadTokens) ?? 0
    self.totalCostCents = try container.decodeFiniteDoubleIfPresent(forKey: .totalCostCents) ?? 0
  }

  var totalTokens: Int64 {
    saturatingNonnegativeSum(
      self.totalInputTokens, self.totalOutputTokens,
      self.totalCacheWriteTokens, self.totalCacheReadTokens)
  }
}

struct CursorModelAggregation: Decodable, Sendable {
  let modelIntent: String
  let inputTokens: Int64
  let outputTokens: Int64
  let cacheWriteTokens: Int64
  let cacheReadTokens: Int64
  let totalCents: Double

  enum CodingKeys: String, CodingKey {
    case modelIntent, inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, totalCents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.modelIntent = try container.decodeIfPresent(String.self, forKey: .modelIntent) ?? "Unknown"
    self.inputTokens = try container.decodeFlexibleInt64IfPresent(forKey: .inputTokens) ?? 0
    self.outputTokens = try container.decodeFlexibleInt64IfPresent(forKey: .outputTokens) ?? 0
    self.cacheWriteTokens = try container.decodeFlexibleInt64IfPresent(
      forKey: .cacheWriteTokens) ?? 0
    self.cacheReadTokens = try container.decodeFlexibleInt64IfPresent(forKey: .cacheReadTokens) ?? 0
    self.totalCents = try container.decodeFiniteDoubleIfPresent(forKey: .totalCents) ?? 0
  }

  var modelUsageCost: ModelUsageCost {
    ModelUsageCost(
      model: self.modelIntent,
      inputTokens: self.inputTokens,
      cachedInputTokens: self.cacheReadTokens,
      cacheWriteInputTokens: self.cacheWriteTokens,
      outputTokens: self.outputTokens,
      costUSD: self.totalCents / 100)
  }
}

struct CursorFilteredUsageResponse: Decodable, Sendable {
  let totalUsageEventsCount: Int?
  let usageEventsDisplay: [CursorUsageEvent]

  enum CodingKeys: String, CodingKey { case totalUsageEventsCount, usageEventsDisplay }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.totalUsageEventsCount = try container.decodeFlexibleIntIfPresent(
      forKey: .totalUsageEventsCount)
    self.usageEventsDisplay = try container.decodeIfPresent(
      [CursorUsageEvent].self, forKey: .usageEventsDisplay) ?? []
  }
}

struct CursorUsageEvent: Decodable, Sendable {
  let timestamp: Int64
  let model: String
  let tokenUsage: CursorTokenUsage?
  let conversationID: String?

  enum CodingKeys: String, CodingKey { case timestamp, model, tokenUsage, conversationID = "conversationId" }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.timestamp = try container.decodeFlexibleInt64IfPresent(forKey: .timestamp) ?? 0
    self.model = try container.decodeIfPresent(String.self, forKey: .model) ?? "Unknown"
    self.tokenUsage = try container.decodeIfPresent(CursorTokenUsage.self, forKey: .tokenUsage)
    self.conversationID = try container.decodeIfPresent(String.self, forKey: .conversationID)
  }

  var fingerprint: String {
    let usage = self.tokenUsage
    let inputTokens = String(usage?.inputTokens ?? 0)
    let outputTokens = String(usage?.outputTokens ?? 0)
    let cacheWriteTokens = String(usage?.cacheWriteTokens ?? 0)
    let cacheReadTokens = String(usage?.cacheReadTokens ?? 0)
    let totalCents = String(usage?.totalCents ?? 0)
    let components: [String] = [
      String(self.timestamp), self.model, self.conversationID ?? "",
      inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, totalCents,
    ]
    let value = components.joined(separator: "|")
    return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
  }
}

struct CursorTokenUsage: Decodable, Sendable {
  let inputTokens: Int64
  let outputTokens: Int64
  let cacheWriteTokens: Int64
  let cacheReadTokens: Int64
  let totalCents: Double

  enum CodingKeys: String, CodingKey {
    case inputTokens, outputTokens, cacheWriteTokens, cacheReadTokens, totalCents
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.inputTokens = try container.decodeFlexibleInt64IfPresent(forKey: .inputTokens) ?? 0
    self.outputTokens = try container.decodeFlexibleInt64IfPresent(forKey: .outputTokens) ?? 0
    self.cacheWriteTokens = try container.decodeFlexibleInt64IfPresent(
      forKey: .cacheWriteTokens) ?? 0
    self.cacheReadTokens = try container.decodeFlexibleInt64IfPresent(forKey: .cacheReadTokens) ?? 0
    self.totalCents = try container.decodeFiniteDoubleIfPresent(forKey: .totalCents) ?? 0
  }

  var totalTokens: Int64 {
    saturatingNonnegativeSum(
      self.inputTokens, self.outputTokens, self.cacheWriteTokens, self.cacheReadTokens)
  }
}

enum CursorUsageAggregator {
  static func dailySeries(events: [CursorUsageEvent], start: Date, now: Date) -> [DailyUsage] {
    let calendar = Calendar.current
    let startDay = calendar.startOfDay(for: start)
    let days = max(1, min(30, (calendar.dateComponents([.day], from: startDay, to: now).day ?? 0) + 1))
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    var totals: [String: Int64] = [:]
    for event in events {
      guard let usage = event.tokenUsage else { continue }
      let date = Date(timeIntervalSince1970: Double(event.timestamp) / 1_000)
      guard date >= startDay, date <= now.addingTimeInterval(1) else { continue }
      let key = formatter.string(from: date)
      totals[key] = saturatingNonnegativeSum(totals[key] ?? 0, usage.totalTokens)
    }
    return (0..<days).map { offset in
      let date = calendar.date(byAdding: .day, value: offset, to: startDay) ?? startDay
      let key = formatter.string(from: date)
      return DailyUsage(day: key, tokens: totals[key] ?? 0)
    }
  }
}

private extension KeyedDecodingContainer {
  func decodeFlexibleIntIfPresent(forKey key: Key) throws -> Int? {
    guard self.contains(key), try !self.decodeNil(forKey: key) else { return nil }
    if let value = try? self.decode(Int.self, forKey: key) { return value }
    if let value = try? self.decode(String.self, forKey: key), let parsed = Int(value) {
      return parsed
    }
    throw DecodingError.dataCorruptedError(
      forKey: key, in: self, debugDescription: "expected a finite integer")
  }

  func decodeFlexibleInt64IfPresent(forKey key: Key) throws -> Int64? {
    guard self.contains(key), try !self.decodeNil(forKey: key) else { return nil }
    if let value = try? self.decode(Int64.self, forKey: key) { return value }
    if let value = try? self.decode(String.self, forKey: key), let parsed = Int64(value) {
      return parsed
    }
    throw DecodingError.dataCorruptedError(
      forKey: key, in: self, debugDescription: "expected a finite 64-bit integer")
  }

  func decodeFiniteDoubleIfPresent(forKey key: Key) throws -> Double? {
    guard self.contains(key), try !self.decodeNil(forKey: key) else { return nil }
    let value: Double?
    if let decoded = try? self.decode(Double.self, forKey: key) {
      value = decoded
    } else if let string = try? self.decode(String.self, forKey: key) {
      value = Double(string)
    } else {
      value = nil
    }
    guard let value, value.isFinite else {
      throw DecodingError.dataCorruptedError(
        forKey: key, in: self, debugDescription: "expected a finite number")
    }
    return value
  }
}
