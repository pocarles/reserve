import Foundation

/// The single GET that an API-key plan provider makes. Shared by Z.ai and Kimi
/// so both refuse the same things: any host but the provider's own, plain HTTP,
/// oversized bodies, and error text that could carry the key.
struct APIKeyPlanTransport: Sendable {
  typealias RequestHandler = @Sendable (URLRequest) async throws -> (Data, URLResponse)

  static let maximumResponseBytes = 262_144

  let provider: ProviderID
  let host: String
  private let requestHandler: RequestHandler

  init(provider: ProviderID, host: String, session: URLSession? = nil) {
    let session = session ?? ProviderHTTPSession.shared
    self.init(provider: provider, host: host) {
      try await ProviderHTTPSession.boundedData(
        for: $0, using: session, maximumBytes: Self.maximumResponseBytes)
    }
  }

  init(provider: ProviderID, host: String, requestHandler: @escaping RequestHandler) {
    self.provider = provider
    self.host = host
    self.requestHandler = requestHandler
  }

  /// Returns the body of a 200 response. HTTP 401/403 become `.unauthorized`
  /// so the card offers to replace the key; 429 becomes `.rateLimited`.
  func get(path: String, authorization: String) async throws -> Data {
    var components = URLComponents()
    components.scheme = "https"
    components.host = self.host
    components.path = path
    guard let url = components.url else {
      throw UsageProviderError.invalidResponse("\(self.name) usage address is invalid.")
    }
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue(authorization, forHTTPHeaderField: "Authorization")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("Reserve/1.0", forHTTPHeaderField: "User-Agent")
    return try await self.data(for: request)
  }

  private var name: String { self.provider.displayName }

  private func data(for request: URLRequest) async throws -> Data {
    guard request.url?.scheme?.lowercased() == "https",
      request.url?.host?.lowercased() == self.host
    else {
      throw UsageProviderError.invalidResponse("\(self.name) request left its official host.")
    }
    let data: Data
    let response: URLResponse
    do {
      (data, response) = try await self.requestHandler(request)
    } catch let error as UsageProviderError {
      throw error
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as URLError where error.code == .timedOut {
      throw UsageProviderError.timedOut("\(self.name) usage check")
    } catch let error as URLError where error.code == .cancelled {
      throw CancellationError()
    } catch {
      // The underlying description can echo the request; only its kind is kept.
      throw UsageProviderError.unavailable("\(self.name) could not be reached. Try again shortly.")
    }
    // The redirect policy already refuses to leave the host; this also covers
    // an injected transport or a future policy change.
    if let final = response.url, final.host?.lowercased() != self.host
      || final.scheme?.lowercased() != "https"
    {
      throw UsageProviderError.invalidResponse("\(self.name) response came from another host.")
    }
    guard let http = response as? HTTPURLResponse else {
      throw UsageProviderError.invalidResponse("\(self.name) did not return an HTTP response.")
    }
    switch http.statusCode {
    case 200: return data
    case 401, 403:
      throw UsageProviderError.unauthorized(
        "\(self.name) did not accept this API key. Replace it in Settings > Providers.")
    case 429:
      throw UsageProviderError.rateLimited(retryAt: Self.retryAfter(http))
    case 400, 404, 422:
      throw UsageProviderError.invalidResponse(
        "\(self.name) rejected the usage request (HTTP \(http.statusCode)).")
    default:
      throw UsageProviderError.unavailable(
        "\(self.name) usage check returned HTTP \(http.statusCode).")
    }
  }

  private static func retryAfter(_ response: HTTPURLResponse, now: Date = Date()) -> Date? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After"),
      let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)),
      seconds.isFinite, seconds > 0, seconds <= 24 * 60 * 60
    else { return nil }
    return now.addingTimeInterval(seconds)
  }

  /// A whole number within a sane range. `Int(Double)` traps outside `Int`'s
  /// range, so a hostile or corrupt value is rejected here instead.
  static func integer(_ value: Any?) -> Int? {
    guard let double = Self.number(value), double.rounded() == double,
      abs(double) <= 1_000_000_000_000
    else { return nil }
    return Int(double)
  }

  /// Reads a JSON number that a provider may send as a number or a string.
  static func number(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber:
      // JSONSerialization represents booleans as NSNumber too.
      guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
      let double = number.doubleValue
      return double.isFinite ? double : nil
    case let string as String:
      guard let double = Double(string.trimmingCharacters(in: .whitespaces)), double.isFinite
      else { return nil }
      return double
    default:
      return nil
    }
  }
}
