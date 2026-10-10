import CryptoKit
import Foundation

/// One Claude Code configuration directory and the sign-in Claude Code keys to
/// it. Claude Code reads `CLAUDE_CONFIG_DIR` as its configuration home, keeps
/// that account's `.claude.json` and `settings.json` inside it, and names the
/// Keychain item after the directory: without the variable it uses the plain
/// service name; with it, even when it names the default home, it appends the
/// first eight hex characters of the SHA-256 of the exact string (checked
/// against Claude Code 2.1.292). Reserve always sets the variable for this
/// slot, so the suffixed name is the one it reads. A second directory is
/// therefore a second, independent sign-in, which is how one Mac tracks a
/// personal and a team account that share the same email address.
public struct ClaudeConfigDirectory: Sendable, Equatable, Hashable {
  public static let environmentKey = "CLAUDE_CONFIG_DIR"
  public static let defaultKeychainService = "Claude Code-credentials"
  public static let maximumPathCharacters = 1_024

  /// The exact string Claude Code receives as `CLAUDE_CONFIG_DIR`. The Keychain
  /// suffix hashes this string byte for byte, so it is stored as chosen and
  /// never rewritten afterwards.
  public let path: String

  /// Fails for an empty, relative, or oversized path. A tilde is expanded, `.`
  /// and `..` are collapsed, and a trailing slash is dropped so the same
  /// directory always hashes to the same Keychain item.
  public init?(path input: String) {
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= Self.maximumPathCharacters else { return nil }
    let expanded = (trimmed as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return nil }
    var standardized = (expanded as NSString).standardizingPath
    while standardized.count > 1, standardized.hasSuffix("/") {
      standardized.removeLast()
    }
    guard standardized != "/" else { return nil }
    self.path = standardized
  }

  public var url: URL { URL(fileURLWithPath: self.path, isDirectory: true) }

  /// Claude Code's own default home, which the first slot reads without
  /// setting `CLAUDE_CONFIG_DIR`. The second slot refuses it: pointed there,
  /// Claude Code would keep a second sign-in beside the first one's.
  public static func defaultHome(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> ClaudeConfigDirectory? {
    ClaudeConfigDirectory(path: homeDirectory.appendingPathComponent(".claude").path)
  }

  public func isDefaultHome(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> Bool {
    self == Self.defaultHome(homeDirectory: homeDirectory)
  }

  /// The Keychain service Claude Code stores this directory's sign-in under
  /// when launched with `CLAUDE_CONFIG_DIR` set to `path`.
  public func keychainService() -> String {
    Self.defaultKeychainService + "-" + Self.keychainSuffix(for: self.path)
  }

  /// The first eight hex characters of the SHA-256 of the directory string.
  static func keychainSuffix(for path: String) -> String {
    let digest = SHA256.hash(data: Data(path.utf8))
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  /// A short, stable name for places that must never show the full path, such
  /// as log lines, cache file names, and the status-line receiver argument.
  public var identifier: String { Self.keychainSuffix(for: self.path) }

  /// Where Claude Code keeps a legacy file credential for this directory.
  public var credentialFileURL: URL { self.url.appendingPathComponent(".credentials.json") }
  /// The account profile Claude Code writes after sign-in (email, organization).
  public var accountProfileURL: URL { self.url.appendingPathComponent(".claude.json") }
  /// The settings file the Claude Code status line is configured in.
  public var settingsURL: URL { self.url.appendingPathComponent("settings.json") }
  /// The session transcripts Reserve scans for activity from this Mac.
  public var projectsURL: URL { self.url.appendingPathComponent("projects") }

  /// The environment a Claude Code launch for this directory receives: the
  /// caller's environment with `CLAUDE_CONFIG_DIR` pointing here.
  public func environment(from base: [String: String]) -> [String: String] {
    var environment = base
    environment[Self.environmentKey] = self.path
    return environment
  }

  /// The directory the environment names, or Claude Code's default home. Only
  /// the directory: whether the Keychain item is suffixed depends on the
  /// variable being set, which `keychainService()` assumes.
  public static func resolve(
    environment: [String: String],
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> ClaudeConfigDirectory? {
    if let configured = environment[Self.environmentKey],
      let directory = ClaudeConfigDirectory(path: configured)
    {
      return directory
    }
    return Self.defaultHome(homeDirectory: homeDirectory)
  }
}
