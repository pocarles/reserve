import Foundation

enum ReserveLinks {
  static let repository = URL(string: "https://github.com/pocarles/Reserve")!
  static let releasesAPI = URL(
    string: "https://api.github.com/repos/pocarles/Reserve/releases/latest")!
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
      let configuration = URLSessionConfiguration.ephemeral
      configuration.urlCache = nil
      let (data, response) = try await URLSession(configuration: configuration).data(for: request)
      guard let http = response as? HTTPURLResponse else { return .failed }
      if http.statusCode == 404 { return .unpublished }
      guard http.statusCode == 200, data.count <= 100_000,
        let release = try? JSONDecoder().decode(GitHubRelease.self, from: data),
        let url = URL(string: release.htmlURL)
      else { return .failed }
      let latest = release.tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
      return Self.isNewer(latest, than: currentVersion)
        ? .available(version: latest, url: url)
        : .current(version: currentVersion)
    } catch {
      return .failed
    }
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
