import Darwin
import Foundation
import ReserveCore

/// Claude Code hands its browser sign-in URL to `$BROWSER`. Reserve points that
/// at a two-line shell script which writes the URL into a private FIFO, so the
/// loopback callback that finishes sign-in inside this app reaches Reserve
/// without the URL ever being saved to disk.
@MainActor
final class ClaudeLoginBrowserPipe {
  /// The browser shim. It is written at runtime into the private directory
  /// below rather than shipped in the resource bundle: a running copy of
  /// Reserve whose app bundle was replaced or deleted must still be able to
  /// sign in, and a bundled file is exactly what disappears in that case.
  static let browserScript = """
    #!/bin/sh
    # Return the helper's automatic callback URL to Reserve through a private pipe.
    # The pipe carries bytes in memory; no authorization URL is saved to disk.
    test -n "$RESERVE_LOGIN_PIPE" && test -p "$RESERVE_LOGIN_PIPE" || exit 1
    printf '%s\\n' "$1" > "$RESERVE_LOGIN_PIPE"

    """

  enum SetupError: LocalizedError {
    case directoryUnavailable
    case scriptUnavailable
    case pipeUnavailable

    var errorDescription: String? {
      switch self {
      case .directoryUnavailable: "Reserve could not create its private sign-in folder."
      case .scriptUnavailable: "Reserve could not prepare its browser handoff."
      case .pipeUnavailable: "Reserve could not open its private sign-in channel."
      }
    }
  }

  let directory: URL
  let path: String
  let browserExecutable: String
  private let reader: FileHandle
  private let gate = BoundedOutputGate(maximumBytes: 65_536)

  init(
    parent: URL = FileManager.default.temporaryDirectory,
    onURLData: @escaping @MainActor @Sendable (Data) -> Void
  ) throws {
    self.directory = parent.appendingPathComponent(
      "reserve-browser-\(UUID().uuidString)", isDirectory: true)
    self.path = self.directory.appendingPathComponent("url.pipe").path
    self.browserExecutable = self.directory.appendingPathComponent("browser.sh").path
    let directory = self.directory
    func fail(_ error: SetupError) -> SetupError {
      try? FileManager.default.removeItem(at: directory)
      return error
    }
    guard Darwin.mkdir(self.directory.path, 0o700) == 0,
      Self.isPrivate(self.directory.path, type: S_IFDIR)
    else { throw fail(.directoryUnavailable) }
    guard Self.writeScript(to: self.browserExecutable),
      Self.isPrivate(self.browserExecutable, type: S_IFREG)
    else { throw fail(.scriptUnavailable) }
    guard mkfifo(self.path, 0o600) == 0 else { throw fail(.pipeUnavailable) }
    // Keep our own writer open so EOF does not race the helper's short write.
    let descriptor = Darwin.open(self.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
    guard descriptor >= 0 else { throw fail(.pipeUnavailable) }
    self.reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    let gate = self.gate
    self.reader.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else { return }
      switch gate.append(data) {
      case .scheduleDrain:
        Task { @MainActor in onURLData(gate.drain()) }
      case .overflow, .closed:
        handle.readabilityHandler = nil
      case .accepted:
        break
      }
    }
  }

  func close() {
    self.gate.close()
    self.reader.readabilityHandler = nil
    try? self.reader.close()
    try? FileManager.default.removeItem(at: self.directory)
  }

  /// Creates the script exclusively (never following or reusing an existing
  /// path) and sets its mode explicitly, so the umask cannot widen or narrow it.
  private static func writeScript(to path: String) -> Bool {
    let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o700)
    guard descriptor >= 0 else { return false }
    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    defer { try? handle.close() }
    guard fchmod(descriptor, 0o700) == 0 else { return false }
    do { try handle.write(contentsOf: Data(Self.browserScript.utf8)) } catch { return false }
    return true
  }

  /// The item must be what Reserve just made: the expected type, owned by this
  /// user, and readable, writable and runnable by nobody else.
  static func isPrivate(_ path: String, type: mode_t) -> Bool {
    var status = stat()
    guard lstat(path, &status) == 0 else { return false }
    return status.st_mode & S_IFMT == type
      && status.st_uid == getuid()
      && status.st_mode & 0o777 == 0o700
  }
}
