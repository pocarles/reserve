import Foundation

/// The fixed providers Reserve understands. Provider-specific authentication
/// stays in its adapter; shared setup and presentation facts live here.
public struct ProviderDescriptor: Sendable {
  public enum StatusFormat: Sendable { case statuspage, rss }
  public enum AuthenticationStrategy: Sendable { case cliOAuth, protectedSession }
  public enum InstallationStrategy: Sendable { case automaticHelper, manualHelper }
  public struct Capabilities: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let liveAllowance = Self(rawValue: 1 << 0)
    public static let localHistory = Self(rawValue: 1 << 1)
    public static let accountHistory = Self(rawValue: 1 << 2)
    public static let extraSpending = Self(rawValue: 1 << 3)
  }

  public let id: ProviderID
  public let displayName: String
  public let helper: ProviderHelperDefinition
  public let accountURL: URL
  public let statusURL: URL
  public let statusFeedURL: URL
  public let statusFormat: StatusFormat
  public let capabilities: Capabilities
  public let authenticationStrategy: AuthenticationStrategy
  public let installationStrategy: InstallationStrategy
  public let loginArguments: [String]
  public let loginDisplayName: String
  public let trustedLoginHosts: Set<String>
  public var supportsAutomaticHelperInstallation: Bool { self.installationStrategy == .automaticHelper }

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
        status: "https://status.claude.com", capabilities: [.liveAllowance, .localHistory, .extraSpending],
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
  }
}
