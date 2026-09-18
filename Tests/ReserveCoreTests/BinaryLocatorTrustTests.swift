import Darwin
import Foundation
import Testing
@testable import ReserveCore

/// Filesystem fixtures for `BinaryLocator.validateExecutable`.
///
/// Every fixture lives in a fresh directory under the user's temporary
/// directory, whose real ancestors (`/private/var/folders/..`) are owned by root
/// or the user and are not writable by others, so the checks run all the way
/// to `/` exactly as they do for a real install.
struct BinaryLocatorTrustTests {
  /// A private scratch directory, addressed by its canonical path.
  final class Sandbox {
    let root: String

    init() throws {
      let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("reserve-trust-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
      guard let canonical = realpath(url.path, nil) else { throw POSIXError(.ENOENT) }
      root = String(cString: canonical)
      free(canonical)
      #expect(chmod(root, 0o755) == 0)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    func path(_ relative: String) -> String { "\(root)/\(relative)" }

    @discardableResult
    func directory(_ relative: String, mode: mode_t = 0o755) throws -> String {
      let path = path(relative)
      try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
      #expect(chmod(path, mode) == 0)
      return path
    }

    @discardableResult
    func executable(_ relative: String, mode: mode_t = 0o755) throws -> String {
      let path = path(relative)
      try directory((relative as NSString).deletingLastPathComponent)
      #expect(FileManager.default.createFile(atPath: path, contents: Data("#!/bin/sh\n".utf8)))
      #expect(chmod(path, mode) == 0)
      return path
    }

    func link(_ relative: String, to target: String) throws {
      try directory((relative as NSString).deletingLastPathComponent)
      #expect(symlink(target, path(relative)) == 0)
    }
  }

  @Test func privateInstallIsTrusted() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("prefix/bin/codex")
    #expect(BinaryLocator.validateExecutable(at: binary) == .success(binary))
  }

  @Test func homebrewRelativeLinksResolveToTheCellar() throws {
    let sandbox = try Sandbox()
    let cellar = try sandbox.executable("homebrew/Cellar/codex/1.0/bin/codex")
    try sandbox.link("homebrew/bin/codex", to: "../Cellar/codex/1.0/bin/codex")
    let script = try sandbox.executable(
      "homebrew/lib/node_modules/@openai/codex/bin/codex.js", mode: 0o755)
    try sandbox.link(
      "homebrew/bin/codex-js", to: "../lib/node_modules/@openai/codex/bin/codex.js")

    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("homebrew/bin/codex")) == .success(cellar))
    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("homebrew/bin/codex-js"))
        == .success(script))
    // `find` keeps the path it was given, so argv[0] is what the installer chose.
    // A unique name keeps a real install in a preferred directory from winning.
    try sandbox.link("homebrew/bin/reserve-trust-codex", to: "../Cellar/codex/1.0/bin/codex")
    #expect(
      BinaryLocator.find(
        "reserve-trust-codex", environment: ["PATH": sandbox.path("homebrew/bin")])
        == sandbox.path("homebrew/bin/reserve-trust-codex"))
  }

  @Test func symlinkChainThroughADirectoryLinkIsFollowed() throws {
    // The shape of Codex's standalone installer and Claude's native installer:
    // `~/.local/bin/codex -> ~/.codex/packages/standalone/current/bin/codex`,
    // where `current` is itself a link to a versioned release directory.
    let sandbox = try Sandbox()
    let release = try sandbox.executable("codex/releases/0.146.0/bin/codex")
    try sandbox.link("codex/current", to: sandbox.path("codex/releases/0.146.0"))
    try sandbox.link("local/bin/codex", to: sandbox.path("codex/current/bin/codex"))
    try sandbox.link("local/bin/codex-alias", to: "codex")

    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("local/bin/codex-alias"))
        == .success(release))
  }

  @Test func symlinkLoopIsRejectedWithoutHanging() throws {
    let sandbox = try Sandbox()
    try sandbox.link("bin/a", to: "b")
    try sandbox.link("bin/b", to: "a")
    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("bin/a"))
        == .failure(.symlinkLoop(sandbox.path("bin/a"))))
  }

  @Test func danglingSymlinkIsMissing() throws {
    let sandbox = try Sandbox()
    try sandbox.link("bin/codex", to: "../gone/codex")
    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("bin/codex"))
        == .failure(.missing(sandbox.path("gone"))))
  }

  @Test func groupWritableAncestorIsRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("shared/bin/codex")
    let shared = try sandbox.directory("shared", mode: 0o775)
    var info = stat()
    #expect(lstat(shared, &info) == 0)
    // New items inherit the temporary directory's group, normally `staff`.
    guard info.st_gid != 0, info.st_gid != 80 else { return }
    #expect(BinaryLocator.validateExecutable(at: binary) == .failure(.groupWritable(shared)))
  }

  @Test func adminGroupWritableDirectoryIsTrusted() throws {
    // Homebrew's own layout: `/opt/homebrew/bin` is `user:admin 0775`.
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("homebrew/bin/codex")
    let bin = try sandbox.directory("homebrew/bin", mode: 0o775)
    // Only an administrator can hand a directory to `admin`; skip otherwise.
    guard chown(bin, uid_t.max, 80) == 0 else { return }
    #expect(BinaryLocator.validateExecutable(at: binary) == .success(binary))
  }

  @Test func worldWritableAncestorIsRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("open/deep/bin/codex")
    let open = try sandbox.directory("open", mode: 0o777)
    #expect(BinaryLocator.validateExecutable(at: binary) == .failure(.worldWritable(open)))
  }

  @Test func worldWritableBinaryIsRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("bin/codex", mode: 0o757)
    #expect(BinaryLocator.validateExecutable(at: binary) == .failure(.worldWritable(binary)))
  }

  @Test func writableDirectoryHoldingALinkIsRejected() throws {
    // The final file is private, but anyone could replace the link pointing at it.
    let sandbox = try Sandbox()
    try sandbox.executable("private/bin/codex")
    try sandbox.link("drop/codex", to: sandbox.path("private/bin/codex"))
    let drop = try sandbox.directory("drop", mode: 0o777)
    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("drop/codex"))
        == .failure(.worldWritable(drop)))
  }

  @Test func privateLinkIntoAWritableDirectoryIsRejected() throws {
    // The reverse: a trusted link cannot launder a target in a writable directory.
    let sandbox = try Sandbox()
    try sandbox.executable("drop/codex")
    let drop = try sandbox.directory("drop", mode: 0o777)
    try sandbox.link("bin/codex", to: "../drop/codex")
    #expect(
      BinaryLocator.validateExecutable(at: sandbox.path("bin/codex"))
        == .failure(.worldWritable(drop)))
  }

  @Test func fifoAndDirectoryAreNotBinaries() throws {
    let sandbox = try Sandbox()
    try sandbox.directory("bin")
    let fifo = sandbox.path("bin/fifo")
    #expect(mkfifo(fifo, 0o755) == 0)
    let folder = try sandbox.directory("bin/folder", mode: 0o755)
    #expect(BinaryLocator.validateExecutable(at: fifo) == .failure(.notRegularFile(fifo)))
    #expect(BinaryLocator.validateExecutable(at: folder) == .failure(.notRegularFile(folder)))
  }

  @Test func stickyParentIsRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("sticky/codex")
    let sticky = try sandbox.directory("sticky", mode: 0o1755)
    #expect(BinaryLocator.validateExecutable(at: binary) == .failure(.stickyParent(sticky)))
  }

  @Test func nonExecutableFileIsRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("bin/codex", mode: 0o644)
    #expect(BinaryLocator.validateExecutable(at: binary) == .failure(.notExecutable(binary)))
  }

  @Test func fileInsideAnotherUsersTreeIsRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("bin/codex")
    let stranger = getuid() &+ 1
    #expect(
      BinaryLocator.validateExecutable(at: binary, uid: stranger, trustedRoot: sandbox.root)
        == .failure(.untrustedOwner(sandbox.path("bin"), owner: getuid())))
  }

  @Test func relativeAndIntermediateFilePathsAreRejected() throws {
    let sandbox = try Sandbox()
    let binary = try sandbox.executable("bin/codex")
    #expect(BinaryLocator.validateExecutable(at: "bin/codex") == .failure(.relativePath("bin/codex")))
    #expect(
      BinaryLocator.validateExecutable(at: "\(binary)/codex")
        == .failure(.notADirectory(binary)))
  }

  @Test func rejectedCandidateFallsThroughToTheNextPathEntry() throws {
    let sandbox = try Sandbox()
    try sandbox.executable("open/reserve-trust-cli")
    let open = try sandbox.directory("open", mode: 0o777)
    let trusted = try sandbox.executable("closed/reserve-trust-cli")
    #expect(
      BinaryLocator.find(
        "reserve-trust-cli",
        environment: ["PATH": "\(open):relative:\(sandbox.path("closed"))"]) == trusted)
  }
}
