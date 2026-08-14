import Foundation

public struct OpenAIProvider: UsageProvider {
  public let id: ProviderID = .openAI
  private let environment: [String: String]

  public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.environment = environment
  }

  public func fetch() async throws -> UsageSnapshot {
    guard let executable = BinaryLocator.find("codex", environment: self.environment) else {
      throw UsageProviderError.executableNotFound("Codex CLI")
    }

    let rpc = try JSONRPCProcess(
      executable: executable,
      arguments: ["-s", "read-only", "-a", "untrusted", "app-server"],
      environment: BinaryLocator.childEnvironment(self.environment))
    defer { rpc.shutdown() }

    _ = try await rpc.request(
      method: "initialize",
      params: ["clientInfo": ["name": "usagebar", "version": "0.1.0"]],
      timeout: .seconds(8))
    try rpc.notify(method: "initialized")

    let limitMessage = try await rpc.request(
      method: "account/rateLimits/read",
      timeout: .seconds(5))
    let response = try rpc.decodeResult(OpenAIRateLimitsResponse.self, from: limitMessage)
    let selected = response.rateLimitsByLimitId?["codex"] ?? response.rateLimits

    var planName = selected.planType
    if planName?.isEmpty ?? true,
      let message = try? await rpc.request(
        method: "account/read",
        params: ["refreshToken": false],
        timeout: .seconds(3)),
      let account = try? rpc.decodeResult(OpenAIAccountResponse.self, from: message)
    {
      planName = account.account?.planType
    }

    var windows: [UsageWindow] = []
    if let primary = selected.primary {
      windows.append(
        primary.usageWindow(id: primary.stableID(fallback: "primary"), fallbackLabel: "Session"))
    }
    if let secondary = selected.secondary {
      windows.append(
        secondary.usageWindow(
          id: secondary.stableID(fallback: "secondary"), fallbackLabel: "Weekly"))
    }
    guard !windows.isEmpty else {
      throw UsageProviderError.unavailable("OpenAI did not return subscription usage windows.")
    }

    return UsageSnapshot(
      provider: .openAI,
      planName: planName,
      windows: windows,
      source: "Codex app-server")
  }
}

struct OpenAIRateLimitsResponse: Decodable, Sendable {
  let rateLimits: OpenAIRateLimitSnapshot
  let rateLimitsByLimitId: [String: OpenAIRateLimitSnapshot]?

  enum CodingKeys: String, CodingKey {
    case rateLimits
    case rateLimitsByLimitId
    case rateLimitsByLimitIdSnake = "rate_limits_by_limit_id"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.rateLimits = try container.decode(OpenAIRateLimitSnapshot.self, forKey: .rateLimits)
    self.rateLimitsByLimitId =
      try container.decodeIfPresent(
        [String: OpenAIRateLimitSnapshot].self,
        forKey: .rateLimitsByLimitId)
      ?? container.decodeIfPresent(
        [String: OpenAIRateLimitSnapshot].self,
        forKey: .rateLimitsByLimitIdSnake)
  }
}

struct OpenAIRateLimitSnapshot: Decodable, Sendable {
  let primary: OpenAIRateLimitWindow?
  let secondary: OpenAIRateLimitWindow?
  let planType: String?

  enum CodingKeys: String, CodingKey {
    case primary
    case secondary
    case planType
    case planTypeSnake = "plan_type"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.primary = try container.decodeIfPresent(OpenAIRateLimitWindow.self, forKey: .primary)
    self.secondary = try container.decodeIfPresent(OpenAIRateLimitWindow.self, forKey: .secondary)
    self.planType =
      try container.decodeIfPresent(String.self, forKey: .planType)
      ?? container.decodeIfPresent(String.self, forKey: .planTypeSnake)
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
  }
}
