import Foundation

/// The fixed providers Reserve understands. Provider-specific authentication
/// stays in its adapter; shared setup and presentation facts live here.
public struct ProviderDescriptor: Sendable {
  public enum StatusFormat: Sendable { case statuspage, rss }
  /// `apiKey` providers are connected by pasting a key into Reserve. They have
  /// no helper, no CLI sign-in and nothing on disk for Reserve to scan.
  public enum AuthenticationStrategy: Sendable { case cliOAuth, protectedSession, apiKey }
  /// `none` means there is no helper at all: nothing to install, update or find.
  public enum InstallationStrategy: Sendable { case automaticHelper, manualHelper, none }
  public struct Capabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let liveAllowance = Self(rawValue: 1 << 0)
    public static let localHistory = Self(rawValue: 1 << 1)
    public static let accountHistory = Self(rawValue: 1 << 2)
    public static let extraSpending = Self(rawValue: 1 << 3)
    /// Every plan limit gets its own meter instead of a one-line summary.
    public static let limitMeters = Self(rawValue: 1 << 4)
  }

  /// How a person obtains and pastes the key for an `apiKey` provider.
  public struct APIKeyConnection: Sendable, Equatable {
    /// What the pasted key looks like, shown as the field placeholder.
    public let keyHint: String
    /// Where the key is created. Opened in the browser; never contacted by Reserve.
    public let keySettingsURL: URL
    /// The only host that ever receives the key.
    public let endpointHost: String
  }

  public let id: ProviderID
  public let displayName: String
  /// Nil for providers that have no helper to install, update or sign in with.
  public let helper: ProviderHelperDefinition?
  public let accountURL: URL
  /// Nil when the provider publishes no official status page; Reserve then
  /// skips status checks rather than guessing an address.
  public let statusURL: URL?
  public let statusFeedURL: URL?
  public let statusFormat: StatusFormat
  public let capabilities: Capabilities
  public let authenticationStrategy: AuthenticationStrategy
  public let installationStrategy: InstallationStrategy
  public let loginArguments: [String]
  public let loginDisplayName: String
  public let trustedLoginHosts: Set<String>
  public let apiKeyConnection: APIKeyConnection?
  public var supportsAutomaticHelperInstallation: Bool { self.installationStrategy == .automaticHelper }
  public var usesAPIKey: Bool { self.authenticationStrategy == .apiKey }

  public static func forProvider(_ id: ProviderID) -> Self {
    switch id {
    case .openAI:
      Self(id: id, displayName: "OpenAI", executable: "codex", helperName: "Codex helper",
        installer: "https://chatgpt.com/codex/install.sh", account: "https://chatgpt.com/codex/settings/usage",
        status: "https://status.openai.com", capabilities: [.liveAllowance, .localHistory, .accountHistory],
        loginArguments: ["login"], loginDisplayName: "Codex",
        trustedLoginHosts: ["auth.openai.com", "chatgpt.com", "platform.openai.com"])
    case .anthropic:
      Self(id: id, displayName: "Claude", executable: "claude", helperName: "Claude helper",
        installer: "https://claude.ai/install.sh", account: "https://claude.ai/settings/usage",
        status: "https://status.claude.com", capabilities: [.liveAllowance, .localHistory, .extraSpending, .limitMeters],
        authenticationStrategy: .protectedSession,
        loginArguments: ["auth", "login", "--claudeai"], loginDisplayName: "Claude Code",
        trustedLoginHosts: ["claude.com", "claude.ai", "platform.claude.com"])
    case .grok:
      Self(id: id, displayName: "Grok", executable: "grok", helperName: "Grok helper",
        installer: "https://x.ai/cli/install.sh", account: "https://grok.com",
        status: "https://status.x.ai", statusFormat: .rss, capabilities: [.liveAllowance, .localHistory],
        loginArguments: ["login", "--device-auth"], loginDisplayName: "Grok Build",
        trustedLoginHosts: ["auth.x.ai", "accounts.x.ai", "x.ai", "grok.com"])
    case .cursor:
      Self(id: id, displayName: "Cursor", executable: "cursor-agent", helperName: "Cursor helper",
        installer: "https://cursor.com/install", account: "https://cursor.com/dashboard",
        status: "https://status.cursor.com", capabilities: [.liveAllowance, .accountHistory, .extraSpending],
        authenticationStrategy: .protectedSession,
        loginArguments: ["login"], loginDisplayName: "Cursor Agent",
        trustedLoginHosts: ["cursor.com", "auth.cursor.com", "www.cursor.com"])
    case .copilot:
      Self(id: id, displayName: "Copilot", executable: "copilot", helperName: "Copilot CLI",
        installer: "https://docs.github.com/en/copilot/how-tos/set-up/install-copilot-cli",
        account: "https://github.com/settings/copilot", status: "https://www.githubstatus.com",
        capabilities: [.liveAllowance], installationStrategy: .manualHelper,
        loginArguments: CopilotProvider.loginArguments, loginDisplayName: "Copilot",
        trustedLoginHosts: ["github.com"])
    case .zai:
      // Z.ai publishes no status page (status.z.ai does not resolve), so none
      // is configured and status checks skip this provider.
      Self(apiKeyProvider: id, displayName: "Z.ai",
        account: "https://z.ai/manage-apikey/coding-plan/personal/my-plan", status: nil,
        connection: APIKeyConnection(
          keyHint: "id.secret",
          keySettingsURL: URL(string: "https://z.ai/manage-apikey/apikey-list")!,
          endpointHost: ZaiProvider.endpointHost))
    case .kimi:
      // Moonshot AI's official Statuspage covers the Kimi service.
      Self(apiKeyProvider: id, displayName: "Kimi",
        account: "https://www.kimi.com/code/console", status: "https://status.moonshot.cn",
        connection: APIKeyConnection(
          keyHint: "sk-kimi-…",
          keySettingsURL: URL(string: "https://www.kimi.com/code/console")!,
          endpointHost: KimiProvider.endpointHost))
    }
  }

  private init(
    id: ProviderID, displayName: String, executable: String, helperName: String,
    installer: String, account: String, status: String, statusFormat: StatusFormat = .statuspage,
    capabilities: Capabilities, authenticationStrategy: AuthenticationStrategy = .cliOAuth,
    installationStrategy: InstallationStrategy = .automaticHelper,
    loginArguments: [String], loginDisplayName: String, trustedLoginHosts: Set<String>
  ) {
    self.id = id
    self.displayName = displayName
    self.helper = ProviderHelperDefinition(
      provider: id, executable: executable, displayName: helperName,
      installerURL: URL(string: installer)!,
      updateArguments: installationStrategy == .automaticHelper ? ["update"] : [])
    self.accountURL = URL(string: account)!
    self.statusURL = URL(string: status)!
    self.statusFeedURL = URL(string: status + (statusFormat == .rss ? "/feed.xml" : "/api/v2/summary.json"))!
    self.statusFormat = statusFormat
    self.capabilities = capabilities
    self.authenticationStrategy = authenticationStrategy
    self.installationStrategy = installationStrategy
    self.loginArguments = loginArguments
    self.loginDisplayName = loginDisplayName
    self.trustedLoginHosts = trustedLoginHosts
    self.apiKeyConnection = nil
  }

  /// A plan read with a pasted key: live allowance only, with no helper, no
  /// sign-in command and no local history.
  private init(
    apiKeyProvider id: ProviderID, displayName: String, account: String, status: String?,
    connection: APIKeyConnection
  ) {
    self.id = id
    self.displayName = displayName
    self.helper = nil
    self.accountURL = URL(string: account)!
    self.statusURL = status.flatMap { URL(string: $0) }
    self.statusFeedURL = status.flatMap { URL(string: $0 + "/api/v2/summary.json") }
    self.statusFormat = .statuspage
    self.capabilities = [.liveAllowance]
    self.authenticationStrategy = .apiKey
    self.installationStrategy = .none
    self.loginArguments = []
    self.loginDisplayName = displayName
    self.trustedLoginHosts = []
    self.apiKeyConnection = connection
  }
}
