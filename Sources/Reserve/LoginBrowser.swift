import AppKit

enum LoginBrowser {
  static func chromeArguments(for url: URL, home: URL) -> [String] {
    // Chrome routes this invocation to the process owning its normal data
    // directory, even when automation has launched other Chrome instances.
    ["--user-data-dir=\(home.appendingPathComponent("Library/Application Support/Google/Chrome").path)",
     url.absoluteString]
  }

  @MainActor
  static func open(_ url: URL) -> Bool {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let applications = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
    guard let executable = applications.map({
      $0.appendingPathComponent("Google Chrome.app/Contents/MacOS/Google Chrome")
    }).first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
      return NSWorkspace.shared.open(url)
    }
    let process = Process()
    process.executableURL = executable
    process.arguments = chromeArguments(for: url, home: home)
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      return true
    } catch {
      return false
    }
  }
}
