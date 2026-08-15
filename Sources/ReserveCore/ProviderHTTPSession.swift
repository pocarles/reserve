import Foundation

/// Refuses to follow a redirect that leaves the host the request was aimed at.
///
/// Provider requests carry `Authorization: Bearer …` (and, for Grok, `x-userid`).
/// URLSession follows redirects by default and does not guarantee that custom
/// headers are stripped when the destination changes origin, so a redirect from
/// a compromised or misconfigured endpoint could hand the token to another host.
/// Same-host redirects are still allowed; anything else stops here.
private final class ProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let original = task.originalRequest?.url?.host?.lowercased()
    let destination = request.url?.host?.lowercased()
    guard let original, let destination, original == destination,
      request.url?.scheme?.lowercased() == "https"
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

public enum ProviderHTTPSession {
  private static let redirectPolicy = ProviderRedirectPolicy()

  public static let shared: URLSession = Self.make()

  public static func make(
    requestTimeout: TimeInterval = 15,
    resourceTimeout: TimeInterval = 20
  ) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    return URLSession(
      configuration: configuration, delegate: Self.redirectPolicy, delegateQueue: nil)
  }

  public static func boundedData(
    for request: URLRequest,
    using session: URLSession = Self.shared,
    maximumBytes: Int
  ) async throws -> (Data, URLResponse) {
    precondition(maximumBytes >= 0)
    let (bytes, response) = try await session.bytes(for: request)
    var data = Data()
    data.reserveCapacity(min(maximumBytes, 64 * 1_024))
    for try await byte in bytes {
      guard data.count < maximumBytes else {
        throw UsageProviderError.invalidResponse(
          "network response exceeded \(maximumBytes) bytes")
      }
      data.append(byte)
    }
    return (data, response)
  }
}
