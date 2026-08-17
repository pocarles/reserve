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
    for directory in Self.preferredDirectories(home: home) {
      if let candidate = Self.executable(name, in: directory) { return candidate }
    }
    // The desktop apps ship their own native helpers outside PATH. Prefer these
    // known locations over arbitrary PATH entries so a desktop user does not
    // need a second installation just for Reserve.
    if name == "codex", let bundled = Self.bundledCodexExecutable(home: home) {
      return bundled
    }
    if name == "claude", let bundled = Self.bundledClaudeExecutable(home: home) {
      return bundled
    }
    for directory in pathEntries {
      if let candidate = Self.executable(name, in: directory) { return candidate }
    }
    return nil
  }

  static func bundledCodexExecutable(
    home: String, applicationDirectories: [URL]? = nil
  ) -> String? {
    let roots = applicationDirectories ?? [
      URL(fileURLWithPath: "/Applications", isDirectory: true),
      URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent("Applications", isDirectory: true),
    ]
    for root in roots {
      let candidate = root
        .appendingPathComponent("ChatGPT.app/Contents/Resources/codex").path
      if let executable = Self.executable(at: candidate) { return executable }
    }
    return nil
  }

  static func bundledClaudeExecutable(
    home: String, fileManager: FileManager = .default
  ) -> String? {
    let root = URL(fileURLWithPath: home, isDirectory: true)
      .appendingPathComponent("Library/Application Support/Claude/claude-code", isDirectory: true)
    guard
      let versions = try? fileManager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return nil }
    for version in versions.sorted(by: {
      $0.lastPathComponent.compare(
        $1.lastPathComponent, options: [.numeric, .caseInsensitive]) == .orderedDescending
    }) {
      let candidate = version
        .appendingPathComponent("claude.app/Contents/MacOS/claude").path
      if let executable = Self.executable(at: candidate) { return executable }
    }
    return nil
  }

  private static func executable(_ name: String, in directory: String) -> String? {
    let candidate = URL(fileURLWithPath: directory).appendingPathComponent(name).path
    return Self.executable(at: candidate)
  }

  private static func executable(at candidate: String) -> String? {
    guard FileManager.default.isExecutableFile(atPath: candidate) else { return nil }
    // A world-writable directory or binary means anyone on the machine can
    // choose what Reserve executes.
    let directory = URL(fileURLWithPath: candidate).deletingLastPathComponent().path
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
