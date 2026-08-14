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

enum ProviderHTTPSession {
  private static let redirectPolicy = ProviderRedirectPolicy()

  static let shared: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(
      configuration: configuration, delegate: Self.redirectPolicy, delegateQueue: nil)
  }()
}
