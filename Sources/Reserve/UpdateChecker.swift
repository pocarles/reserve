import Foundation
import ReserveCore

enum ReserveLinks {
  static let repository = URL(string: "https://github.com/pocarles/reserve")!
  static let releasesAPI = URL(
    string: "https://api.github.com/repos/pocarles/reserve/releases/latest")!
  static let xProfile = URL(string: "https://x.com/pocarles")!
}

enum UpdateCheckResult {
  case current(version: String)
  case available(version: String, url: URL)
  case unpublished
  case failed
}

actor UpdateChecker {
  func check(currentVersion: String) async -> UpdateCheckResult {
    var request = URLRequest(url: ReserveLinks.releasesAPI)
    request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    request.setValue("Reserve/\(currentVersion)", forHTTPHeaderField: "User-Agent")
    request.timeoutInterval = 10
    do {
      let session = ProviderHTTPSession.make(requestTimeout: 10, resourceTimeout: 15)
      let (data, response) = try await ProviderHTTPSession.boundedData(
        for: request, using: session, maximumBytes: 100_000)
      guard let http = response as? HTTPURLResponse else { return .failed }
      if http.statusCode == 404 { return .unpublished }
      guard http.statusCode == 200, data.count <= 100_000,
        let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
        let url = URL(string: release.htmlURL),
        // Only a release page of this repository is ever opened. An `https`
        // check alone would let an unexpected body point Reserve anywhere.
        Self.isReserveReleaseURL(url)
      else { return .failed }
      let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      return Self.isNewer(latest, than: currentVersion)
        ? .available(version: latest, url: url)
        : .current(version: currentVersion)
    } catch {
      return .failed
    }
  }

  static func isReserveReleaseURL(_ url: URL) -> Bool {
    guard url.scheme?.lowercased() == "https",
      url.host?.lowercased() == "github.com",
      url.user == nil, url.password == nil, url.port == nil,
      let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return false }
    let raw = components.percentEncodedPath
    // `URL.path` percent-decodes, so a prefix test accepts `..` and `%2f`.
    // The raw path must be a plain `/pocarles/reserve/releases/…` with no
    // escapes and no traversal.
    guard !raw.contains("%") else { return false }
    let parts = raw.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !parts.contains(".."), !parts.contains("."), parts.count >= 3 else { return false }
    return parts[0].lowercased() == "pocarles"
      && parts[1].lowercased() == "reserve"
      && parts[2].lowercased() == "releases"
  }

  private static func isNewer(_ candidate: String, than current: String) -> Bool {
    let candidateParts = candidate.split(separator: ".").map { Int($0) ?? 0 }
    let currentParts = current.split(separator: ".").map { Int($0) ?? 0 }
    for index in 0..<max(candidateParts.count, currentParts.count) {
      let lhs = index < candidateParts.count ? candidateParts[index] : 0
      let rhs = index < currentParts.count ? currentParts[index] : 0
      if lhs != rhs { return lhs > rhs }
    }
    return false
  }
}

private struct GitHubRelease: Decodable {
  let tagName: String
  let htmlURL: String

  enum CodingKeys: String, CodingKey {
    case tagName = "tag_name"
    case htmlURL = "html_url"
  }
}
