import Foundation

public struct GrokProvider: UsageProvider {
  public let id: ProviderID = .grok
  private let environment: [String: String]
  private let session: URLSession

  public init(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    session: URLSession? = nil
  ) {
    self.environment = environment
    self.session = session ?? ProviderHTTPSession.shared
  }

  public func fetch() async throws -> UsageSnapshot {
    guard let executable = BinaryLocator.find("grok", environment: self.environment) else {
      throw UsageProviderError.executableNotFound("Grok Build CLI")
    }
    let versionOutput = try await ProcessRunner.output(
      executable: executable,
      arguments: ["--version"],
      environment: self.environment)
    guard let version = SemanticVersion.first(in: versionOutput),
      version >= SemanticVersion(1, 0, 0)
    else {
      throw UsageProviderError.unavailable(
        "Grok Build 1.0.0 or newer is required for background billing access. Found: \(versionOutput)."
      )
    }

    let rpc = try JSONRPCProcess(
      executable: executable,
      arguments: ["agent", "--no-leader", "stdio"],
      environment: self.environment)
    defer { rpc.shutdown() }

    _ = try await rpc.request(
      method: "initialize",
      params: [
        "protocolVersion": "1",
        "clientCapabilities": [
          "fs": ["readTextFile": false, "writeTextFile": false],
          "terminal": false,
        ],
      ],
      timeout: .seconds(8),
      includeJSONRPCVersion: true,
      unescapeSlashes: true)

    let response: GrokBillingEnvelope
    var source = "Grok Build ACP"
    do {
      let message = try await rpc.request(
        method: "x.ai/billing",
        timeout: .seconds(15),
        includeJSONRPCVersion: true,
        unescapeSlashes: true)
      response = try rpc.decodeResult(GrokBillingEnvelope.self, from: message)
    } catch let error as UsageProviderError {
      if error.localizedDescription.localizedCaseInsensitiveContains("method not found") {
        response = try await self.fetchThroughOfficialCLIProxy(version: versionOutput)
        source = "Grok Build billing API"
      } else if error.localizedDescription.localizedCaseInsensitiveContains("authentication") {
        throw UsageProviderError.unauthorized(
          "Grok authentication is required. Run `grok login` and refresh.")
      } else {
        throw error
      }
    }

    guard let config = response.config ?? response.legacyConfig else {
      throw UsageProviderError.unavailable("Grok did not return personal subscription usage.")
    }
    guard let percent = config.usedPercent else {
      throw UsageProviderError.unavailable("Grok billing did not include a usage percentage.")
    }

    let period = config.currentPeriod
    let minutes: Int? = {
      guard let start = UsageDateParser.iso8601(period?.start ?? config.billingPeriodStart),
        let end = UsageDateParser.iso8601(period?.end ?? config.billingPeriodEnd), end > start
      else { return nil }
      return Int(end.timeIntervalSince(start) / 60)
    }()
    let label = Self.periodLabel(type: period?.type, minutes: minutes)

    return UsageSnapshot(
      provider: .grok,
      planName: response.subscriptionTier,
      windows: [
        UsageWindow(
          id: "usage-pool",
          label: label,
          usedPercent: percent,
          windowMinutes: minutes,
          resetsAt: UsageDateParser.iso8601(period?.end ?? config.billingPeriodEnd))
      ],
      source: source,
      includedSpend: config.includedSpend)
  }

  private func fetchThroughOfficialCLIProxy(version: String) async throws -> GrokBillingEnvelope {
    let credentials = try GrokCredentialLoader.load(environment: self.environment)
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
    request.setValue("grok-shell", forHTTPHeaderField: "x-grok-client-identifier")
    request.setValue("headless", forHTTPHeaderField: "x-grok-client-mode")
    request.setValue("application/json", forHTTPHeaderField: "Accept")

    let (data, urlResponse): (Data, URLResponse)
    do {
      (data, urlResponse) = try await self.session.data(for: request)
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
    case 401, 403:
      throw UsageProviderError.unauthorized(
        "Grok authentication expired. Run `grok login` and refresh.")
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

  private static func periodLabel(type: String?, minutes: Int?) -> String {
    if type?.localizedCaseInsensitiveContains("weekly") == true { return "Weekly" }
    if type?.localizedCaseInsensitiveContains("monthly") == true { return "Monthly" }
    if let minutes, (6 * 24 * 60)...(8 * 24 * 60) ~= minutes { return "Weekly" }
    if let minutes, (27 * 24 * 60)...(32 * 24 * 60) ~= minutes { return "Monthly" }
    return "Usage pool"
  }
}

struct GrokCredentials: Sendable {
  let key: String
  let userID: String
}

enum GrokCredentialLoader {
  static func load(environment: [String: String]) throws -> GrokCredentials {
    let root: URL
    if let configured = environment["GROK_HOME"], !configured.isEmpty {
      root = URL(fileURLWithPath: (configured as NSString).expandingTildeInPath)
    } else {
      root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".grok")
    }
    let url = root.appendingPathComponent("auth.json")
    guard let data = BoundedFileReader.read(url, maximumBytes: 1_048_576),
      let entries = try? JSONDecoder().decode([String: GrokCredentialEntry].self, from: data)
    else {
      throw UsageProviderError.credentialsNotFound(
        "Grok credentials were not found. Run `grok login` first.")
    }
    guard let credentials = self.select(entries: entries, now: Date()) else {
      throw UsageProviderError.unauthorized(
        "Grok authentication expired. Run `grok login` and refresh.")
    }
    return credentials
  }

  static func select(entries: [String: GrokCredentialEntry], now: Date) -> GrokCredentials? {
    let ordered = entries.sorted { lhs, rhs in
      lhs.key.hasPrefix("https://auth.x.ai::") && !rhs.key.hasPrefix("https://auth.x.ai::")
    }
    for entry in ordered.map(\.value) {
      if let expiresAt = UsageDateParser.iso8601(entry.expiresAt), expiresAt <= now { continue }
      guard let key = entry.key?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty,
        let userID = entry.userID?.trimmingCharacters(in: .whitespacesAndNewlines), !userID.isEmpty
      else { continue }
      return GrokCredentials(key: key, userID: userID)
    }
    return nil
  }
}

struct GrokCredentialEntry: Decodable {
  let key: String?
  let userID: String?
  let expiresAt: String?

  enum CodingKeys: String, CodingKey {
    case key
    case userID = "user_id"
    case expiresAt = "expires_at"
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
          ?? cycle?.billingPeriodEnd)
    } else {
      self.legacyConfig = nil
    }
  }
}

struct GrokBillingConfig: Decodable, Sendable {
  let creditUsagePercent: Double?
  let currentPeriod: GrokUsagePeriod?
  let monthlyLimit: GrokCent?
  let used: GrokCent?
  let billingPeriodStart: String?
  let billingPeriodEnd: String?

  var usedPercent: Double? {
    if let creditUsagePercent { return creditUsagePercent }
    guard let limit = self.monthlyLimit?.val, limit > 0, let used = self.used?.val else {
      return nil
    }
    return Double(used) / Double(limit) * 100
  }

  var includedSpend: IncludedSpend? {
    guard let limit = self.monthlyLimit?.val, limit > 0, let used = self.used?.val else {
      return nil
    }
    return IncludedSpend(label: "Included credits", usedMinorUnits: used, limitMinorUnits: limit)
  }
}

struct GrokUsagePeriod: Decodable, Sendable {
  let type: String?
  let start: String?
  let end: String?
}

struct GrokCent: Decodable, Sendable {
  let val: Int
}

struct GrokLegacyUsage: Decodable, Sendable {
  let totalUsed: GrokCent?
}

struct GrokLegacyCycle: Decodable, Sendable {
  let billingPeriodStart: String?
  let billingPeriodEnd: String?
}
