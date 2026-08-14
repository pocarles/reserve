import Foundation

public enum BinaryLocator {
  /// Where a provider CLI is allowed to come from, most trusted first.
  ///
  /// `PATH` used to be searched *before* these, which meant an early entry — or
  /// anything dropped into a directory on it — became Reserve's login helper and,
  /// for OpenAI, its JSON-RPC peer. Known install prefixes now win, and `PATH` is
  /// only a fallback.
  private static func preferredDirectories(home: String) -> [String] {
    [
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/usr/bin",
      "/bin",
      "\(home)/.local/bin",
      "\(home)/.grok/bin",
    ]
  }

  public static func find(
    _ name: String, environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> String? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let pathEntries = (environment["PATH"] ?? "")
      .split(separator: ":")
      .map(String.init)
    for directory in Self.preferredDirectories(home: home) + pathEntries {
      if let candidate = Self.executable(name, in: directory) { return candidate }
    }
    return nil
  }

  private static func executable(_ name: String, in directory: String) -> String? {
    let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
    guard FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
    // A world-writable directory or binary means anyone on the machine can
    // choose what Reserve executes.
    guard !Self.isWorldWritable(directory), !Self.isWorldWritable(candidate) else { return nil }
    return candidate
  }

  private static func isWorldWritable(_ path: String) -> Bool {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let permissions = attributes[.posixPermissions] as? NSNumber
    else {
      // Unreadable metadata is treated as untrustworthy rather than assumed safe.
      return true
    }
    return permissions.uint16Value & 0o002 != 0
  }

  /// The environment a provider CLI is launched with: the user's, minus the
  /// dynamic-linker controls.
  ///
  /// Children inherited the full environment, so `DYLD_INSERT_LIBRARIES` and
  /// friends survived into a process Reserve started and trusted the output of.
  public static func childEnvironment(
    _ environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> [String: String] {
    environment.filter { key, _ in
      !key.hasPrefix("DYLD_") && !key.hasPrefix("LD_") && key != "LD_PRELOAD"
    }
  }
}
