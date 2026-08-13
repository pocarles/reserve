import Foundation

public enum ProviderID: String, Codable, CaseIterable, Sendable, Identifiable {
  case openAI
  case anthropic
  case grok

  public var id: String { self.rawValue }

  public var displayName: String {
    switch self {
    case .openAI: "OpenAI"
    case .anthropic: "Anthropic"
    case .grok: "Grok"
    }
  }

}

public struct UsageWindow: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let label: String
  public let usedPercent: Double
  public let windowMinutes: Int?
  public let resetsAt: Date?

  public init(
    id: String,
    label: String,
    usedPercent: Double,
    windowMinutes: Int? = nil,
    resetsAt: Date? = nil
  ) {
    self.id = id
    self.label = label
    self.usedPercent = min(100, max(0, usedPercent))
    self.windowMinutes = windowMinutes
    self.resetsAt = resetsAt
  }
}

public struct UsageSnapshot: Codable, Equatable, Sendable, Identifiable {
  public var id: ProviderID { self.provider }
  public let provider: ProviderID
  public let planName: String?
  public let windows: [UsageWindow]
  public let fetchedAt: Date
  public let source: String
  public let includedSpend: IncludedSpend?

  public init(
    provider: ProviderID,
    planName: String? = nil,
    windows: [UsageWindow],
    fetchedAt: Date = Date(),
    source: String,
    includedSpend: IncludedSpend? = nil
  ) {
    self.provider = provider
    self.planName = planName
    self.windows = windows
    self.fetchedAt = fetchedAt
    self.source = source
    self.includedSpend = includedSpend
  }

  public var highestUsedPercent: Double? {
    self.windows.map(\.usedPercent).max()
  }
}

public struct IncludedSpend: Codable, Equatable, Sendable {
  public let label: String
  public let usedMinorUnits: Int
  public let limitMinorUnits: Int
  public let currencyCode: String

  public init(
    label: String,
    usedMinorUnits: Int,
    limitMinorUnits: Int,
    currencyCode: String = "USD"
  ) {
    self.label = label
    self.usedMinorUnits = max(0, usedMinorUnits)
    self.limitMinorUnits = max(0, limitMinorUnits)
    self.currencyCode = currencyCode
  }
}

public protocol UsageProvider: Sendable {
  var id: ProviderID { get }
  func fetch() async throws -> UsageSnapshot
}

public enum UsageProviderError: LocalizedError, Sendable, Equatable {
  case executableNotFound(String)
  case credentialsNotFound(String)
  case keychainConsentRequired
  case unauthorized(String)
  case rateLimited(retryAt: Date?)
  case timedOut(String)
  case invalidResponse(String)
  case unavailable(String)
  case processFailed(String)

  public var errorDescription: String? {
    switch self {
    case .executableNotFound(let name): "\(name) is not installed or could not be found."
    case .credentialsNotFound(let message): message
    case .keychainConsentRequired:
      "Claude credentials are in Keychain. Allow read-only Keychain access in Settings."
    case .unauthorized(let message): message
    case .rateLimited(let retryAt):
      if let retryAt {
        "Rate limited until \(retryAt.formatted(date: .omitted, time: .shortened))."
      } else {
        "The provider temporarily rate limited usage checks."
      }
    case .timedOut(let operation): "\(operation) timed out."
    case .invalidResponse(let message): "Invalid provider response: \(message)"
    case .unavailable(let message): message
    case .processFailed(let message): message
    }
  }
}
