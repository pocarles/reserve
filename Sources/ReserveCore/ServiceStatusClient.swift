import Foundation

public enum ServiceHealth: String, Codable, Sendable {
  case operational
  case degraded
  case outage
  case unknown

  public var displayName: String {
    switch self {
    case .operational: "Operational"
    case .degraded: "Degraded"
    case .outage: "Outage"
    case .unknown: "Status unknown"
    }
  }
}

public struct ProviderServiceStatus: Codable, Equatable, Sendable {
  public let provider: ProviderID
  public let health: ServiceHealth
  public let detail: String
  public let pageURL: URL
  public let fetchedAt: Date
  /// Open incidents, affected components and upcoming maintenance, one line
  /// each, for the expanded details. Optional so older caches still decode.
  public let notices: [String]?

  public init(
    provider: ProviderID,
    health: ServiceHealth,
    detail: String,
    pageURL: URL,
    fetchedAt: Date = Date(),
    notices: [String] = []
  ) {
    self.provider = provider
    self.health = health
    self.detail = String(detail.prefix(256))
    self.pageURL = pageURL
    self.fetchedAt = fetchedAt
    self.notices = notices.isEmpty ? nil : notices.prefix(4).map { String($0.prefix(160)) }
  }
}

public actor ServiceStatusClient {
  private let session: URLSession
  private var cache: [ProviderID: ProviderServiceStatus] = [:]
  private let cacheLifetime: TimeInterval = 10 * 60

  public init(session: URLSession? = nil) {
    if let session {
      self.session = session
    } else {
      self.session = ProviderHTTPSession.make(requestTimeout: 8, resourceTimeout: 12)
    }
  }

  public func fetch(_ provider: ProviderID, now: Date = Date()) async -> ProviderServiceStatus {
    if let cached = self.cache[provider],
      now.timeIntervalSince(cached.fetchedAt) < self.cacheLifetime
    {
      return cached
    }
    let result: ProviderServiceStatus
    do {
      result = try await self.fetchFresh(provider, now: now)
    } catch {
      result =
        self.cache[provider]
        ?? ProviderServiceStatus(
          provider: provider,
          health: .unknown,
          detail: "Official status unavailable",
          pageURL: Self.pageURL(provider),
          fetchedAt: now)
    }
    self.cache[provider] = result
    return result
  }

  private func fetchFresh(_ provider: ProviderID, now: Date) async throws -> ProviderServiceStatus {
    let endpoint = ProviderDescriptor.forProvider(provider).statusFeedURL
    var request = URLRequest(url: endpoint)
    request.setValue("Reserve/1.0", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await ProviderHTTPSession.boundedData(
      for: request, using: self.session, maximumBytes: 512_000)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 512_000
    else { throw StatusError.invalidResponse }
    switch provider {
    case .openAI, .anthropic, .cursor, .copilot:
      return try Self.decodeStatuspage(data, provider: provider, now: now)
    case .grok:
      return Self.decodeXAI(data, now: now)
    }
  }

  static func decodeStatuspage(
    _ data: Data,
    provider: ProviderID,
    now: Date = Date()
  ) throws -> ProviderServiceStatus {
    let summary = try JSONDecoder().decode(StatuspageSummary.self, from: data)
    let indicator = summary.status?.indicator?.lowercased() ?? ""
    let health: ServiceHealth =
      switch indicator {
      case "none": .operational
      case "minor": .degraded
      case "major", "critical": .outage
      default: .unknown
      }
    return ProviderServiceStatus(
      provider: provider,
      health: health,
      detail: summary.status?.description ?? health.displayName,
      pageURL: Self.pageURL(provider),
      fetchedAt: now,
      notices: summary.notices(now: now))
  }

  static func decodeXAI(_ data: Data, now: Date = Date()) -> ProviderServiceStatus {
    let xml = String(decoding: data, as: UTF8.self)
    let items = xml.components(separatedBy: "<item>").dropFirst()
    let ongoing = items.first { item in
      let relevant =
        item.localizedCaseInsensitiveContains("[Grok")
        || item.localizedCaseInsensitiveContains("[API")
      return relevant && !item.localizedCaseInsensitiveContains("Status: RESOLVED")
    }
    let title = ongoing.flatMap { item -> String? in
      guard let start = item.range(of: "<title>"),
        let end = item.range(of: "</title>", range: start.upperBound..<item.endIndex)
      else { return nil }
      return String(item[start.upperBound..<end.lowerBound])
    }
    let isOutage = ongoing?.localizedCaseInsensitiveContains("Severity: unavailable") == true
    return ProviderServiceStatus(
      provider: .grok,
      health: ongoing == nil ? .operational : (isOutage ? .outage : .degraded),
      detail: title ?? "All systems operational",
      pageURL: Self.pageURL(.grok),
      fetchedAt: now,
      notices: title.map { [$0] } ?? [])
  }

  private static func pageURL(_ provider: ProviderID) -> URL {
    ProviderDescriptor.forProvider(provider).statusURL
  }
}

private struct StatuspageSummary: Decodable {
  struct Status: Decodable {
    let indicator: String?
    let description: String?
  }

  struct Component: Decodable {
    let name: String?
    let status: String?
    let group: Bool?
  }

  struct Incident: Decodable {
    let name: String?
    let status: String?
  }

  struct Maintenance: Decodable {
    let name: String?
    let status: String?
    let scheduledFor: String?

    enum CodingKeys: String, CodingKey {
      case name, status
      case scheduledFor = "scheduled_for"
    }
  }

  let status: Status?
  let components: [Component]?
  let incidents: [Incident]?
  let scheduledMaintenances: [Maintenance]?

  enum CodingKeys: String, CodingKey {
    case status, components, incidents
    case scheduledMaintenances = "scheduled_maintenances"
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.status = try container.decodeIfPresent(Status.self, forKey: .status)
    // The overall indicator is what matters; the lists are best effort.
    self.components = try? container.decodeIfPresent([Component].self, forKey: .components)
    self.incidents = try? container.decodeIfPresent([Incident].self, forKey: .incidents)
    self.scheduledMaintenances = try? container.decodeIfPresent(
      [Maintenance].self, forKey: .scheduledMaintenances)
  }

  func notices(now: Date) -> [String] {
    var notices: [String] = []
    for incident in (self.incidents ?? []).prefix(8)
    where incident.status != "resolved" && incident.status != "postmortem" {
      if let name = incident.name, !name.isEmpty { notices.append(name) }
    }
    for component in (self.components ?? []).prefix(64)
    where component.group != true && component.status.map({ $0 != "operational" }) == true {
      guard let name = component.name, let status = component.status else { continue }
      notices.append("\(name): \(status.replacingOccurrences(of: "_", with: " "))")
    }
    for maintenance in (self.scheduledMaintenances ?? []).prefix(8)
    where maintenance.status != "completed" {
      guard let name = maintenance.name, !name.isEmpty else { continue }
      let when = UsageDateParser.iso8601(maintenance.scheduledFor).map {
        " · \($0.formatted(date: .abbreviated, time: .shortened))"
      } ?? ""
      notices.append("Maintenance: \(name)\(when)")
    }
    return notices
  }
}

private enum StatusError: Error {
  case invalidResponse
}
