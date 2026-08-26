import Foundation

public struct ProviderHelperDefinition: Sendable, Equatable {
  public let provider: ProviderID
  public let executable: String
  public let displayName: String
  public let installerURL: URL
  public let updateArguments: [String]

  public init(
    provider: ProviderID,
    executable: String,
    displayName: String,
    installerURL: URL,
    updateArguments: [String]
  ) {
    self.provider = provider
    self.executable = executable
    self.displayName = displayName
    self.installerURL = installerURL
    self.updateArguments = updateArguments
  }
}

public enum ProviderHelperCatalog {
  public static func definition(for provider: ProviderID) -> ProviderHelperDefinition {
    switch provider {
    case .openAI:
      ProviderHelperDefinition(
        provider: provider,
        executable: "codex",
        displayName: "Codex helper",
        installerURL: URL(string: "https://chatgpt.com/codex/install.sh")!,
        updateArguments: ["update"])
    case .anthropic:
      ProviderHelperDefinition(
        provider: provider,
        executable: "claude",
        displayName: "Claude helper",
        installerURL: URL(string: "https://claude.ai/install.sh")!,
        updateArguments: ["update"])
    case .grok:
      ProviderHelperDefinition(
        provider: provider,
        executable: "grok",
        displayName: "Grok helper",
        installerURL: URL(string: "https://x.ai/cli/install.sh")!,
        updateArguments: ["update"])
    case .cursor:
      ProviderHelperDefinition(
        provider: provider,
        executable: "cursor-agent",
        displayName: "Cursor helper",
        installerURL: URL(string: "https://cursor.com/install")!,
        updateArguments: ["update"])
    }
  }
}

public enum ProviderHelperInstallerError: LocalizedError, Sendable, Equatable {
  case invalidResponse(String)
  case installFailed(String)
  case helperNotFound(String)

  public var errorDescription: String? {
    switch self {
    case .invalidResponse(let message): message
    case .installFailed(let message): message
    case .helperNotFound(let name):
      "\(name) could not be found after setup finished."
    }
  }
}

/// Installs only the four fixed, official provider helpers that Reserve knows
/// how to use. The remote script is downloaded first, bounded and checked as a
/// shell script, then run from a private temporary directory. It never receives
/// the app's environment, which may contain unrelated API keys.
public final class ProviderHelperInstaller: @unchecked Sendable {
  static let maximumInstallerBytes = 1_048_576

  private let session: URLSession

  public init(session: URLSession? = nil) {
    self.session = session ?? ProviderHTTPSession.make(requestTimeout: 30, resourceTimeout: 60)
  }

  public func install(_ provider: ProviderID) async throws {
    let definition = ProviderHelperCatalog.definition(for: provider)
    var request = URLRequest(url: definition.installerURL)
    request.timeoutInterval = 30
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("text/plain, text/x-shellscript, */*", forHTTPHeaderField: "Accept")

    let (data, response) = try await ProviderHTTPSession.boundedData(
      for: request, using: self.session, maximumBytes: Self.maximumInstallerBytes)
    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
      let host = definition.installerURL.host ?? "the provider"
      throw ProviderHelperInstallerError.invalidResponse(
        "\(definition.displayName) could not be downloaded from \(host).")
    }
    guard response.url?.scheme?.lowercased() == "https",
      response.url?.host?.lowercased() == definition.installerURL.host?.lowercased()
    else {
      throw ProviderHelperInstallerError.invalidResponse(
        "\(definition.displayName) download left the provider's official address.")
    }
    try Self.validateInstallerFormat(data)

    let fileManager = FileManager.default
    let directory = fileManager.temporaryDirectory
      .appendingPathComponent("reserve-provider-setup-\(UUID().uuidString)", isDirectory: true)
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: NSNumber(value: 0o700)])
    defer { try? fileManager.removeItem(at: directory) }

    let script = directory.appendingPathComponent("install.sh")
    try data.write(to: script, options: [.atomic])
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: script.path)

    do {
      _ = try await ProcessRunner.output(
        executable: "/bin/bash",
        arguments: ["--noprofile", "--norc", script.path],
        environment: Self.installerEnvironment(),
        timeout: .seconds(180))
    } catch {
      throw ProviderHelperInstallerError.installFailed(
        "\(definition.displayName) setup did not finish. \(error.localizedDescription)")
    }
    guard BinaryLocator.find(definition.executable) != nil else {
      throw ProviderHelperInstallerError.helperNotFound(definition.displayName)
    }
  }

  public func update(_ provider: ProviderID) async throws {
    let definition = ProviderHelperCatalog.definition(for: provider)
    guard let executable = BinaryLocator.find(definition.executable) else {
      throw ProviderHelperInstallerError.helperNotFound(definition.displayName)
    }
    do {
      _ = try await ProcessRunner.output(
        executable: executable,
        arguments: definition.updateArguments,
        environment: Self.installerEnvironment(),
        timeout: .seconds(180))
    } catch {
      throw ProviderHelperInstallerError.installFailed(
        "\(definition.displayName) could not be updated. \(error.localizedDescription)")
    }
    guard BinaryLocator.find(definition.executable) != nil else {
      throw ProviderHelperInstallerError.helperNotFound(definition.displayName)
    }
  }

  /// This is a format guard, not a claim that arbitrary shell code is safe.
  /// Trust comes from the fixed HTTPS origin and same-host redirect policy.
  static func validateInstallerFormat(_ data: Data) throws {
    guard !data.isEmpty, data.count <= Self.maximumInstallerBytes,
      !data.contains(0),
      let text = String(data: data, encoding: .utf8),
      text.hasPrefix("#!"),
      text.prefix(160).localizedCaseInsensitiveContains("sh")
    else {
      throw ProviderHelperInstallerError.invalidResponse(
        "The provider did not return a valid installer.")
    }
  }

  private static func installerEnvironment() -> [String: String] {
    let source = ProcessInfo.processInfo.environment
    var environment: [String: String] = [
      "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin",
      "SHELL": "/bin/zsh",
      "NO_COLOR": "1",
    ]
    for key in ["USER", "LOGNAME", "LANG", "LC_ALL", "TMPDIR"] {
      if let value = source[key], !value.isEmpty { environment[key] = value }
    }
    return environment
  }
}
