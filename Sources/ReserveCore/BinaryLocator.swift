import Darwin
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

  /// The candidate path itself, when it passes `validateExecutable`.
  ///
  /// The original path is returned rather than the resolved one so `argv[0]`
  /// stays what the provider's installer chose: a native Claude Code binary is
  /// literally named after its version (`versions/2.1.245`), and some CLIs
  /// inspect how they were invoked to decide how they were installed. What
  /// matters is that validation covers what actually executes, and it does:
  /// every symlink and directory between this path and the final file is checked.
  private static func executable(at candidate: String) -> String? {
    switch Self.validateExecutable(at: candidate) {
    case .success: return candidate
    case .failure: return nil
    }
  }

  /// Why a candidate path was not trusted to supply a provider CLI.
  ///
  /// Each case names the exact path that failed, which may be an ancestor
  /// directory or a symlink rather than the candidate itself.
  public enum RejectionReason: Error, Equatable, CustomStringConvertible, Sendable {
    /// PATH entries such as `.` or `bin` depend on Reserve's working directory.
    case relativePath(String)
    case missing(String)
    /// Metadata that cannot be read is treated as untrustworthy, not assumed safe.
    case unreadableMetadata(String)
    case symlinkLoop(String)
    case notADirectory(String)
    case untrustedOwner(String, owner: UInt32)
    case groupWritable(String)
    case worldWritable(String)
    /// A sticky directory is a shared drop box, never a place a binary lives.
    case stickyParent(String)
    case notRegularFile(String)
    case notExecutable(String)

    public var description: String {
      switch self {
      case .relativePath(let path): "\(path) is not an absolute path"
      case .missing(let path): "\(path) does not exist"
      case .unreadableMetadata(let path): "\(path) could not be inspected"
      case .symlinkLoop(let path): "\(path) has too many symbolic links"
      case .notADirectory(let path): "\(path) is not a directory"
      case .untrustedOwner(let path, let owner):
        "\(path) is owned by another user (uid \(owner))"
      case .groupWritable(let path): "\(path) is writable by its group"
      case .worldWritable(let path): "\(path) is writable by everyone"
      case .stickyParent(let path): "\(path) is a shared (sticky) directory"
      case .notRegularFile(let path): "\(path) is not a regular file"
      case .notExecutable(let path): "\(path) is not executable"
      }
    }
  }

  /// Symbolic links followed before a path is treated as a loop, as `MAXSYMLINKS`.
  private static let maximumSymlinkExpansions = 32

  /// Groups whose write access to a directory or binary is tolerated.
  ///
  /// Anyone other than the user or root who can write somewhere on the way to a
  /// binary can choose what Reserve executes, so group-writable is untrusted in
  /// general. `admin` (80) and `wheel` (0) are the exception: their members can
  /// already become root, so their write access grants nothing root ownership
  /// would not. The exception is load-bearing, not a convenience: Homebrew on
  /// Apple Silicon creates `/opt/homebrew/bin` as `user:admin 0775`, and
  /// `/Applications` is `root:admin 0775`, so refusing them would hide every
  /// standard install. The owner must still be root or the user.
  private static let trustedWriterGroups: Set<gid_t> = [0, 80]

  /// Whether `path` is a binary nobody but the user, root, or an administrator
  /// could have chosen.
  ///
  /// The path is resolved one component at a time with `lstat`, so every
  /// directory the kernel would traverse to reach the final file — including
  /// the directory holding each symlink in the chain — must be owned by root or
  /// `uid` and must not be writable by anyone else. Each symlink must be owned by
  /// root or `uid`. The final file must be a regular, executable file owned by
  /// root or `uid`, in a directory without the sticky bit. Homebrew's relative
  /// links (`bin/codex -> ../Cellar/...`) and Claude's
  /// `~/.local/bin/claude -> ~/.local/share/claude/versions/X` resolve normally.
  ///
  /// There is a window between this check and `exec`, but another account cannot
  /// use it: nothing on the path is writable by anyone else, so only the user or
  /// an administrator could swap the file in between.
  ///
  /// Extended ACLs are not inspected; a directory whose mode looks private but
  /// whose ACL grants another account write access would still pass.
  ///
  /// - Parameters:
  ///   - uid: the account whose files are trusted besides root's.
  ///   - trustedRoot: a canonical directory whose own ownership and mode, and
  ///     those of its ancestors, are not checked. Only tests set it, to exercise
  ///     a foreign `uid` against fixtures without failing first at the temporary
  ///     directory that contains them.
  /// - Returns: the canonical path of the file that would execute, or why not.
  public static func validateExecutable(
    at path: String, uid: uid_t = getuid(), trustedRoot: String? = nil
  ) -> Result<String, RejectionReason> {
    guard path.hasPrefix("/") else { return .failure(.relativePath(path)) }
    var pending = Self.components(of: path)
    var resolved: [String] = []
    var expansions = 0
    var checkedDirectories = Set<String>()

    while !pending.isEmpty {
      let component = pending.removeFirst()
      if component == "." { continue }
      if component == ".." {
        // `resolved` never contains a symlink, so this is the real parent.
        _ = resolved.popLast()
        continue
      }
      let directory = Self.joined(resolved)
      if !checkedDirectories.contains(directory) {
        if let reason = Self.directoryRejection(directory, uid: uid, trustedRoot: trustedRoot) {
          return .failure(reason)
        }
        checkedDirectories.insert(directory)
      }
      let next = Self.joined(resolved + [component])
      var info = stat()
      guard lstat(next, &info) == 0 else { return .failure(Self.lstatFailure(next)) }
      guard info.st_mode & S_IFMT == S_IFLNK else {
        resolved.append(component)
        continue
      }
      expansions += 1
      guard expansions <= Self.maximumSymlinkExpansions else {
        return .failure(.symlinkLoop(path))
      }
      guard info.st_uid == 0 || info.st_uid == uid else {
        return .failure(.untrustedOwner(next, owner: info.st_uid))
      }
      guard let target = Self.readSymlink(next) else {
        return .failure(.unreadableMetadata(next))
      }
      // A relative target continues from the symlink's own directory, which
      // `resolved` still names; an absolute one starts over from `/`.
      if target.hasPrefix("/") { resolved = [] }
      pending = Self.components(of: target) + pending
    }

    let final = Self.joined(resolved)
    var info = stat()
    guard lstat(final, &info) == 0 else { return .failure(Self.lstatFailure(final)) }
    guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.notRegularFile(final)) }
    if let reason = Self.writerRejection(final, info: info, uid: uid) { return .failure(reason) }

    let parent = Self.joined(resolved.dropLast())
    var parentInfo = stat()
    guard lstat(parent, &parentInfo) == 0 else { return .failure(.unreadableMetadata(parent)) }
    guard parentInfo.st_mode & S_ISVTX == 0 else { return .failure(.stickyParent(parent)) }

    guard access(final, X_OK) == 0 else { return .failure(.notExecutable(final)) }
    return .success(final)
  }

  private static func joined<C: Collection<String>>(_ components: C) -> String {
    "/" + components.joined(separator: "/")
  }

  private static func components(of path: String) -> [String] {
    path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
  }

  private static func lstatFailure(_ path: String) -> RejectionReason {
    errno == ENOENT || errno == ENOTDIR ? .missing(path) : .unreadableMetadata(path)
  }

  private static func readSymlink(_ path: String) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX))
    let length = buffer.withUnsafeMutableBufferPointer { pointer in
      pointer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: pointer.count) {
        readlink(path, $0, pointer.count)
      }
    }
    guard length > 0 else { return nil }
    return String(decoding: buffer[0..<length], as: UTF8.self)
  }

  private static func directoryRejection(
    _ directory: String, uid: uid_t, trustedRoot: String?
  ) -> RejectionReason? {
    if let trustedRoot,
      directory == "/" || directory == trustedRoot || trustedRoot.hasPrefix(directory + "/")
    {
      return nil
    }
    var info = stat()
    guard lstat(directory, &info) == 0 else { return Self.lstatFailure(directory) }
    guard info.st_mode & S_IFMT == S_IFDIR else { return .notADirectory(directory) }
    return Self.writerRejection(directory, info: info, uid: uid)
  }

  /// Rejects an item that someone other than `uid`, root, or an administrator
  /// could replace or modify.
  private static func writerRejection(
    _ path: String, info: stat, uid: uid_t
  ) -> RejectionReason? {
    guard info.st_uid == 0 || info.st_uid == uid else {
      return .untrustedOwner(path, owner: info.st_uid)
    }
    guard info.st_mode & S_IWOTH == 0 else { return .worldWritable(path) }
    if info.st_mode & S_IWGRP != 0, !Self.trustedWriterGroups.contains(info.st_gid) {
      return .groupWritable(path)
    }
    return nil
  }

  /// The keys a helper Reserve starts on its own initiative is allowed to see.
  /// `LC_*` is matched by prefix in addition to these.
  private static let minimalEnvironmentKeys = [
    "HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "SHELL", "LANG", "TERM",
  ]

  /// The environment for a helper Reserve starts by itself, such as a session
  /// renewal: an allowlist rather than a filter.
  ///
  /// `childEnvironment` only removes the dynamic-linker controls, so every
  /// unrelated API key in Reserve's own environment reached the helper. A
  /// renewal is not a user-initiated command, so it gets only what a CLI needs
  /// to find the user's own configuration, plus the keys the caller names.
  public static func minimalChildEnvironment(
    from environment: [String: String] = ProcessInfo.processInfo.environment,
    keeping additionalKeys: [String] = []
  ) -> [String: String] {
    var result: [String: String] = [:]
    for key in Self.minimalEnvironmentKeys + additionalKeys {
      if let value = environment[key], !value.isEmpty { result[key] = value }
    }
    for (key, value) in environment where key.hasPrefix("LC_") && !value.isEmpty {
      result[key] = value
    }
    // A helper that cannot find the home directory would look signed out.
    if result["HOME"] == nil {
      result["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
    }
    if result["PATH"] == nil {
      result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
    }
    return result
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
