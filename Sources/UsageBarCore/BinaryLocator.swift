import Foundation

public enum BinaryLocator {
  public static func find(
    _ name: String, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let commonPaths = [
      "\(home)/.local/bin",
      "\(home)/.grok/bin",
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
    ]
    let pathEntries = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for directory in (pathEntries + commonPaths) {
      let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
      if FileManager.default.isExecutableFile(atPath: candidate) {
        return candidate
      }
    }
    return nil
  }
}
