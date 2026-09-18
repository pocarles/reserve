import Foundation

public struct OpenAIProvider: UsageProvider {
  public let id: ProviderID = .openAI
  static let appServerArguments = ["-s", "read-only", "-a", "never", "app-server"]
  private let environment: [String: String]
  private let includeAccountActivity: Bool

  public init(environment: [String: String] = ProcessInfo.processInfo.environment,
    includeAccountActivity: Bool = false) {
    self.environment = environment
    self.includeAccountActivity = includeAccountActivity
  }

  public func fetch() async throws -> UsageSnapshot {
    guard let executable = BinaryLocator.find("codex", environment: self.environment) else {
      throw UsageProviderError.executableNotFound("Codex CLI")
    }

    let rpc = try JSONRPCProcess(
      executable: executable,
      arguments: Self.appServerArguments,
      environment: BinaryLocator.childEnvironment(self.environment))
    defer { rpc.shutdown() }

    _ = try await rpc.request(
      method: "initialize",
      params: ["clientInfo": ["name": "reserve", "version": "1.0.0"]],
      timeout: .seconds(8))
    try rpc.notify(method: "initialized")

    let limitMessage = try await rpc.request(
      method: "account/rateLimits/read",
      timeout: .seconds(5))
    let response = try rpc.decodeResult(OpenAIRateLimitsResponse.self, from: limitMessage)
    let selected = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits

    // The account read is local to the helper and only adds the plan when the
    // limit response omits it, plus the signed-in email for the details view.
    var planName = OpenAIPlanFormatter.plan(from: selected.planType)
    var account: OpenAIAccountResponse.Account?
    if let message = try? await rpc.request(
      method: "account/read",
      params: ["refreshToken": false],
      timeout: .seconds(3))
    {
      account = (try? rpc.decodeResult(OpenAIAccountResponse.self, from: message))?.account
    }
    if planName == nil { planName = OpenAIPlanFormatter.plan(from: account?.planType) }

    let windows = response.usageWindows
    guard !windows.isEmpty else {
      throw UsageProviderError.unavailable("OpenAI did not return subscription usage windows.")
    }

    // Optional and capability-tolerant. An older CLI or an account without this
    // endpoint must still return its allowance successfully. Never starts a turn.
    var activity: OpenAIAccountActivity?
    if self.includeAccountActivity,
      let message = try? await rpc.request(method: "account/usage/read", timeout: .seconds(5))
    {
      activity = try? rpc.decodeResult(OpenAIAccountActivity.self, from: message)
    }
    try Task.checkCancellation()
    return UsageSnapshot(
      provider: .openAI,
      planName: planName,
      windows: windows,
      source: "Codex app-server",
      availableResetCount: response.rateLimitResetCredits?.availableCount,
      accountTokenActivity: activity,
      details: OpenAIDetails.details(limits: selected, account: account, activity: activity))
  }
}

/// Facts the Codex helper reports beyond the limit windows.
enum OpenAIDetails {
  static func details(
    limits: OpenAIRateLimitSnapshot,
    account: OpenAIAccountResponse.Account?,
    activity: OpenAIAccountActivity?
  ) -> [UsageDetail] {
    var details: [UsageDetail] = []
    if let email = account?.email, !email.isEmpty { details.append(UsageDetail("Account", email)) }
    if let reached = self.blockedReason(limits) { details.append(UsageDetail("Status", reached)) }
    if let credits = limits.credits {
      if credits.unlimited == true {
        details.append(UsageDetail("Credits", "Unlimited"))
      } else if credits.hasCredits == true, let balance = credits.balance,
        let value = Double(balance), value.isFinite
      {
        details.append(UsageDetail("Credits", "\(UsageDetailFormat.number(value)) left"))
      }
    }
    if let limit = limits.individualLimit {
      var text = "\(limit.used) of \(limit.limit) used"
      if let remaining = limit.remainingPercent { text += " · \(remaining)% left" }
      if let reset = limit.resetsAt {
        text += " · resets \(UsageDetailFormat.date(Date(timeIntervalSince1970: TimeInterval(reset))))"
      }
      details.append(UsageDetail("Spend cap", text))
    }
    if let activity {
      if let lifetime = activity.lifetimeTokens {
        details.append(UsageDetail("Lifetime tokens", UsageDetailFormat.tokens(lifetime)))
      }
      if let peak = activity.peakDailyTokens {
        details.append(UsageDetail("Busiest day", "\(UsageDetailFormat.tokens(peak)) tokens"))
      }
      if let current = activity.currentStreakDays, let longest = activity.longestStreakDays {
        details.append(UsageDetail("Streak", "\(current) days · longest \(longest) days"))
      }
    }
    return details
  }

  static func blockedReason(_ limits: OpenAIRateLimitSnapshot) -> String? {
    if limits.spendControlReached == true { return "Spend cap reached" }
    switch limits.rateLimitReachedType {
    case "rate_limit_reached": return "Usage limit reached"
    case "workspace_owner_credits_depleted", "workspace_member_credits_depleted":
      return "Workspace credits used up"
    case "workspace_owner_usage_limit_reached", "workspace_member_usage_limit_reached":
      return "Workspace usage limit reached"
    default: return nil
    }
  }
}

enum OpenAIPlanFormatter {
  static func plan(from value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let normalized = trimmed.lowercased()
      .replacingOccurrences(of: "_", with: "")
      .replacingOccurrences(of: "-", with: "")
      .replacingOccurrences(of: " ", with: "")
      .replacingOccurrences(of: "chatgpt", with: "")
    switch normalized {
    case "free": return "Free"
    case "plus": return "Plus"
    case "pro": return "Pro"
    case "team": return "Team"
    case "business": return "Business"
    case "enterprise": return "Enterprise"
    case "edu", "education": return "Edu"
    default: return trimmed == trimmed.lowercased() ? trimmed.capitalized : trimmed
    }
  }
}

struct OpenAIRateLimitsResponse: Decodable, Sendable {
  let rateLimits: OpenAIRateLimitSnapshot
  let rateLimitsByLimitId: [String: OpenAIRateLimitSnapshot]?
  let rateLimitResetCredits: OpenAIResetCredits?

  enum CodingKeys: String, CodingKey {
    case rateLimits
    case rateLimitsByLimitId
    case rateLimitsByLimitIdSnake = "rate_limits_by_limit_id"
    case rateLimitResetCredits
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.rateLimits = try container.decodeIfPresent(OpenAIRateLimitSnapshot.self, forKey: .rateLimits)
      ?? OpenAIRateLimitSnapshot()
    self.rateLimitsByLimitId =
      try container.decodeIfPresent(
        [String: OpenAIRateLimitSnapshot].self,
        forKey: .rateLimitsByLimitId)
      ?? container.decodeIfPresent(
        [String: OpenAIRateLimitSnapshot].self,
        forKey: .rateLimitsByLimitIdSnake)
    self.rateLimitResetCredits = try container.decodeIfPresent(OpenAIResetCredits.self, forKey: .rateLimitResetCredits)
  }

  var usageWindows: [UsageWindow] {
    var buckets: [(String, OpenAIRateLimitSnapshot)] = []
    buckets.append(("codex", rateLimitsByLimitId?["codex"] ?? rateLimits))
    for key in (rateLimitsByLimitId ?? [:]).keys.sorted() where key != "codex" {
      if let bucket = rateLimitsByLimitId?[key] { buckets.append((key, bucket)) }
    }
    var windows: [UsageWindow] = []
    for (id, bucket) in buckets.prefix(16) {
      let bucketName = bucket.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
      let label = bucketName?.isEmpty == false ? bucketName! : id.replacingOccurrences(of: "_", with: " ")
      var renderedBucket: [UsageWindow] = []
      for (fallback, window) in [("primary", bucket.primary), ("secondary", bucket.secondary)] {
        guard let window else { continue }
        let suffix = window.stableID(fallback: fallback)
        let rendered = window.usageWindow(id: id == "codex" ? suffix : "\(id)-\(suffix)",
          fallbackLabel: fallback == "primary" ? "Session" : "Weekly")
        renderedBucket.append(UsageWindow(id: rendered.id,
          label: id == "codex" ? rendered.label : "\(label) · \(rendered.label)",
          usedPercent: rendered.usedPercent, windowMinutes: rendered.windowMinutes,
          resetsAt: rendered.resetsAt))
      }
      if id != "codex" {
        // The API can return model-specific buckets that have never been used.
        // Showing two extra 100%-left rows makes the real account limits harder
        // to find. Keep additional buckets only once they carry actual usage,
        // and suppress an exact duplicate of a limit already shown.
        guard windows.isEmpty || renderedBucket.contains(where: { $0.usedPercent > 0.05 }) else {
          continue
        }
        renderedBucket.removeAll { candidate in
          windows.contains { existing in
            existing.windowMinutes == candidate.windowMinutes
              && abs(existing.usedPercent - candidate.usedPercent) < 0.05
              && Self.sameReset(existing.resetsAt, candidate.resetsAt)
          }
        }
      }
      windows.append(contentsOf: renderedBucket)
    }
    return Array(windows.prefix(UsageSnapshot.maximumWindows))
  }

  private static func sameReset(_ lhs: Date?, _ rhs: Date?) -> Bool {
    switch (lhs, rhs) {
    case (nil, nil): true
    case let (lhs?, rhs?): abs(lhs.timeIntervalSince(rhs)) < 60
    default: false
    }
  }
}

struct OpenAIResetCredits: Decodable, Sendable {
  let availableCount: Int?
}

struct OpenAIRateLimitSnapshot: Decodable, Sendable {
  let primary: OpenAIRateLimitWindow?
  let secondary: OpenAIRateLimitWindow?
  let planType: String?
  let limitName: String?
  var credits: Credits?
  var individualLimit: SpendLimit?
  var rateLimitReachedType: String?
  var spendControlReached: Bool?

  struct Credits: Decodable, Sendable {
    let hasCredits: Bool?
    let unlimited: Bool?
    let balance: String?
  }

  struct SpendLimit: Decodable, Sendable {
    let used: String
    let limit: String
    let remainingPercent: Int?
    let resetsAt: Int?
  }

  init() { primary = nil; secondary = nil; planType = nil; limitName = nil }

  enum CodingKeys: String, CodingKey {
    case primary
    case secondary
    case planType
    case planTypeSnake = "plan_type"
    case limitName
    case credits, individualLimit, rateLimitReachedType, spendControlReached
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.primary = try container.decodeIfPresent(OpenAIRateLimitWindow.self, forKey: .primary)
    self.secondary = try container.decodeIfPresent(OpenAIRateLimitWindow.self, forKey: .secondary)
    self.limitName = try container.decodeIfPresent(String.self, forKey: .limitName)
    self.planType =
      try container.decodeIfPresent(String.self, forKey: .planType)
      ?? container.decodeIfPresent(String.self, forKey: .planTypeSnake)
    // Optional extras: a shape Reserve does not recognise must never cost the limits.
    self.credits = try? container.decodeIfPresent(Credits.self, forKey: .credits)
    self.individualLimit = try? container.decodeIfPresent(SpendLimit.self, forKey: .individualLimit)
    self.rateLimitReachedType = try? container.decodeIfPresent(String.self, forKey: .rateLimitReachedType)
    self.spendControlReached = try? container.decodeIfPresent(Bool.self, forKey: .spendControlReached)
  }
}

struct OpenAIRateLimitWindow: Decodable, Sendable {
  let usedPercent: Double
  let windowDurationMins: Int?
  let resetsAt: Int?

  enum CodingKeys: String, CodingKey {
    case usedPercent
    case usedPercentSnake = "used_percent"
    case windowDurationMins
    case windowDurationMinsSnake = "window_duration_mins"
    case resetsAt
    case resetsAtSnake = "resets_at"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.usedPercent =
      try container.decodeIfPresent(Double.self, forKey: .usedPercent)
      ?? container.decode(Double.self, forKey: .usedPercentSnake)
    self.windowDurationMins =
      try container.decodeIfPresent(Int.self, forKey: .windowDurationMins)
      ?? container.decodeIfPresent(Int.self, forKey: .windowDurationMinsSnake)
    self.resetsAt =
      try container.decodeIfPresent(Int.self, forKey: .resetsAt)
      ?? container.decodeIfPresent(Int.self, forKey: .resetsAtSnake)
  }

  func usageWindow(id: String, fallbackLabel: String) -> UsageWindow {
    let label =
      switch self.windowDurationMins {
      case 300: "5 hours"
      case 10080: "Weekly"
      default: fallbackLabel
      }
    return UsageWindow(
      id: id,
      label: label,
      usedPercent: self.usedPercent,
      windowMinutes: self.windowDurationMins,
      resetsAt: self.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) })
  }

  func stableID(fallback: String) -> String {
    switch self.windowDurationMins {
    case 300: "five-hour"
    case 10080: "weekly"
    default: fallback
    }
  }
}

struct OpenAIAccountResponse: Decodable, Sendable {
  let account: Account?

  struct Account: Decodable, Sendable {
    let planType: String?
    let email: String?
  }
}
