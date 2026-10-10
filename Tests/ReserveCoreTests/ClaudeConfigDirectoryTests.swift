import Foundation
import Testing

@testable import ReserveCore

/// An added Claude account: one Claude Code configuration folder, its
/// own Keychain item, and nothing read from the default home.
@Suite struct ClaudeConfigDirectoryTests {
  private let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
  /// An added Claude account, beside the default one.
  static let team = ProviderID(kind: .anthropic, instance: "team")!

  @Test func pathsAreNormalisedWithoutChangingTheFolder() {
    #expect(ClaudeConfigDirectory(path: "/tmp/claude-team/")?.path == "/tmp/claude-team")
    #expect(ClaudeConfigDirectory(path: "  /tmp/./claude-team  ")?.path == "/tmp/claude-team")
    #expect(ClaudeConfigDirectory(path: "/tmp/a/../claude-team")?.path == "/tmp/claude-team")
    let expanded = ClaudeConfigDirectory(path: "~/.claude-team")?.path
    #expect(
      expanded
        == FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude-team").path)
    #expect(ClaudeConfigDirectory(path: "") == nil)
    #expect(ClaudeConfigDirectory(path: "   ") == nil)
    #expect(ClaudeConfigDirectory(path: "relative/dir") == nil)
    #expect(ClaudeConfigDirectory(path: "/") == nil)
    #expect(ClaudeConfigDirectory(path: String(repeating: "/a", count: 1_000)) == nil)
  }

  @Test func keychainServiceFollowsClaudeCodeNaming() throws {
    // Claude Code names the item after the exact CLAUDE_CONFIG_DIR string it
    // was launched with: the first eight hex characters of its SHA-256
    // appended, even when the string names the default home. The vectors come
    // from `shasum -a 256` and were checked against Claude Code 2.1.292.
    let team = try #require(ClaudeConfigDirectory(path: "/tmp/claude-team"))
    #expect(team.keychainService() == "Claude Code-credentials-a6dbaaea")
    #expect(team.identifier == "a6dbaaea")
    let dotFolder = try #require(ClaudeConfigDirectory(path: "/Users/example/.claude-team"))
    #expect(dotFolder.keychainService() == "Claude Code-credentials-73a7382e")
    let defaultHome = try #require(ClaudeConfigDirectory(path: "/Users/example/.claude/"))
    #expect(defaultHome.isDefaultHome(homeDirectory: self.home))
    #expect(defaultHome.keychainService() == "Claude Code-credentials-402b469b")
    #expect(!team.isDefaultHome(homeDirectory: self.home))
    // Without the variable, Claude Code's own home keeps the plain name.
    #expect(ClaudeConfigDirectory.defaultKeychainService == "Claude Code-credentials")
  }

  @Test func anAliasOfTheDefaultHomeCountsAsTheDefaultHome() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-claude2-alias-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
    let alias = root.appendingPathComponent("team-link")
    try FileManager.default.createSymbolicLink(
      at: alias, withDestinationURL: home.appendingPathComponent(".claude"))
    let linked = try #require(ClaudeConfigDirectory(path: alias.path))
    // The chosen string stays what it is: the name and the launches use it.
    #expect(linked.path == alias.path)
    #expect(linked.keychainService() != ClaudeConfigDirectory.defaultKeychainService)
    // But it is still the first account's folder underneath.
    #expect(linked.isDefaultHome(homeDirectory: home))
    let other = try #require(ClaudeConfigDirectory(path: root.appendingPathComponent("other").path))
    #expect(!other.isDefaultHome(homeDirectory: home))
    #expect(ClaudeConfigDirectory.sameFile(
      alias.appendingPathComponent("settings.json"),
      home.appendingPathComponent(".claude/settings.json")))
    #expect(!ClaudeConfigDirectory.sameFile(
      alias.appendingPathComponent("settings.json"),
      root.appendingPathComponent("other/settings.json")))
  }

  @Test func environmentAndFilesStayInsideTheFolder() throws {
    let dir = try #require(ClaudeConfigDirectory(path: "/tmp/claude-team"))
    let environment = dir.environment(from: ["PATH": "/usr/bin", "CLAUDE_CONFIG_DIR": "/elsewhere"])
    #expect(environment["CLAUDE_CONFIG_DIR"] == "/tmp/claude-team")
    #expect(environment["PATH"] == "/usr/bin")
    #expect(dir.credentialFileURL.path == "/tmp/claude-team/.credentials.json")
    #expect(dir.accountProfileURL.path == "/tmp/claude-team/.claude.json")
    #expect(dir.settingsURL.path == "/tmp/claude-team/settings.json")
    #expect(dir.projectsURL.path == "/tmp/claude-team/projects")
    #expect(
      ClaudeConfigDirectory.resolve(environment: [:], homeDirectory: self.home)?.path
        == "/Users/example/.claude")
    #expect(
      ClaudeConfigDirectory.resolve(
        environment: ["CLAUDE_CONFIG_DIR": "/tmp/x/"], homeDirectory: self.home)?.path == "/tmp/x")
  }

  @Test func secondSlotReadsOnlyItsOwnFolderAndStampsItsOwnProvider() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-claude2-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // "other" stands in for the default home, where the first slot's
    // credentials live. The added account must never pick them up.
    let other = root.appendingPathComponent("other", isDirectory: true)
    let team = root.appendingPathComponent("team", isDirectory: true)
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: team, withIntermediateDirectories: true)
    let credentials = Data(
      #"{"claudeAiOauth":{"accessToken":"team-access","refreshToken":"team-refresh","expiresAt":4102444800000,"subscriptionType":"team"}}"#
        .utf8)
    try credentials.write(to: other.appendingPathComponent(".credentials.json"))
    try Data(
      #"{"oauthAccount":{"emailAddress":"same@example.com","organizationName":"Example Co","organizationType":"team","organizationRole":"admin"}}"#
        .utf8
    ).write(to: team.appendingPathComponent(".claude.json"))
    let teamDirectory = try #require(ClaudeConfigDirectory(path: team.path))
    let payload = Data(#"{"five_hour":{"utilization":12,"resets_at":"2033-05-18T03:33:20Z"}}"#.utf8)
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
      let token = (request.value(forHTTPHeaderField: "Authorization") ?? "")
        .replacingOccurrences(of: "Bearer ", with: "")
      return (
        token == "team-access" ? payload : Data("{}".utf8),
        HTTPURLResponse(
          url: request.url!, statusCode: token == "team-access" ? 200 : 401,
          httpVersion: "HTTP/1.1", headerFields: [:])!
      )
    }
    func makeProvider() -> AnthropicProvider {
      AnthropicProvider(
        environment: ["CLAUDE_CONFIG_DIR": other.path],
        allowKeychainRead: true,
        requestHandler: handler,
        rateLimitGate: ClaudeRateLimitGate(defaults: nil),
        renewer: { _, _, _ in false },
        keychainCandidateLoader: { _ in nil },
        id: Self.team,
        configDirectory: teamDirectory,
        keychainItemExists: { false })
    }

    // Nothing inside the team folder yet: the credentials next door, named by
    // the environment, must not be used.
    await #expect(throws: UsageProviderError.self) { try await makeProvider().fetch() }

    try credentials.write(to: team.appendingPathComponent(".credentials.json"))
    let snapshot = try await makeProvider().fetch()
    #expect(snapshot.provider == Self.team)
    #expect(snapshot.planName == "Team")
    #expect(snapshot.windows.map(\.usedPercent) == [12])
    #expect(snapshot.source == "Claude OAuth file")
    // The account profile comes from the folder too, so a team account that
    // shares the first slot's email still shows its own organization.
    #expect(snapshot.details.contains(UsageDetail("Account", "same@example.com", isPersonal: true)))
    #expect(snapshot.details.contains(UsageDetail("Organization", "Example Co · Admin", isPersonal: true)))
  }

  @Test func secondSlotWithoutAFolderAsksForOneInsteadOfReadingTheFirstSlot() async {
    let provider = AnthropicProvider(
      environment: [:],
      allowKeychainRead: true,
      requestHandler: { _ in throw URLError(.badURL) },
      rateLimitGate: ClaudeRateLimitGate(defaults: nil),
      renewer: { _, _, _ in false },
      keychainCandidateLoader: { _ in
        try ClaudeCredentialLoader.decodeCandidate(
          data: Data(#"{"claudeAiOauth":{"accessToken":"first-slot","expiresAt":4102444800000}}"#.utf8),
          source: "Claude Keychain")
      },
      id: Self.team,
      configDirectory: nil)
    await #expect(throws: AnthropicProvider.configDirectoryMissing) { try await provider.fetch() }
  }

  @Test func renewalRunsClaudeCodeInsideTheChosenFolder() async throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-claude2-renew-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let directory = try #require(ClaudeConfigDirectory(path: root.path))
    // An expired access token with a refresh token: the loader asks Claude
    // Code to renew, and that launch must carry this folder's CLAUDE_CONFIG_DIR.
    try Data(
      #"{"claudeAiOauth":{"accessToken":"stale","refreshToken":"stale-refresh","expiresAt":1000}}"#.utf8
    ).write(to: directory.credentialFileURL)
    let seen = RenewalEnvironmentRecorder()
    let provider = AnthropicProvider(
      environment: ["CLAUDE_CONFIG_DIR": "/somewhere/else", "PATH": "/usr/bin"],
      allowKeychainRead: true,
      requestHandler: { _ in throw URLError(.badURL) },
      rateLimitGate: ClaudeRateLimitGate(defaults: nil),
      renewer: { _, _, environment in
        await seen.record(environment)
        return false
      },
      keychainCandidateLoader: { _ in nil },
      id: Self.team,
      configDirectory: directory,
      keychainItemExists: { false })
    await #expect(throws: UsageProviderError.self) { try await provider.fetch() }
    #expect(await seen.environments.map { $0["CLAUDE_CONFIG_DIR"] } == [directory.path])
  }

  @Test func eachAccountHasItsOwnRateLimitGateAndRenewer() async throws {
    let other = try #require(ProviderID(kind: .anthropic, instance: "other"))
    #expect(ClaudeRateLimitGate.gate(for: .anthropic) === ClaudeRateLimitGate.shared)
    #expect(ClaudeRateLimitGate.gate(for: Self.team) === ClaudeRateLimitGate.gate(for: Self.team))
    #expect(ClaudeRateLimitGate.gate(for: Self.team) !== ClaudeRateLimitGate.shared)
    #expect(ClaudeRateLimitGate.gate(for: Self.team) !== ClaudeRateLimitGate.gate(for: other))
    #expect(ClaudeSessionRenewer.instance(for: .anthropic) === ClaudeSessionRenewer.shared)
    #expect(ClaudeSessionRenewer.instance(for: Self.team) === ClaudeSessionRenewer.instance(for: Self.team))
    #expect(ClaudeSessionRenewer.instance(for: Self.team) !== ClaudeSessionRenewer.shared)
    #expect(ClaudeSessionRenewer.instance(for: Self.team) !== ClaudeSessionRenewer.instance(for: other))
    // A block on one slot's key never shows up on the other's.
    let suite = "reserve.tests.claude-gates.\(UUID().uuidString)"
    defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
    // Each actor gets its own handle on the same suite, so nothing is shared
    // across isolation boundaries.
    let first = ClaudeRateLimitGate(defaults: UserDefaults(suiteName: suite))
    let second = ClaudeRateLimitGate(
      defaults: UserDefaults(suiteName: suite), key: "anthropic@team.rateLimitBlockedUntil")
    await second.block(until: Date().addingTimeInterval(20 * 60))
    #expect(await first.activeBlock() == nil)
    #expect(await second.activeBlock() != nil)
  }

  @Test func statuslineBridgeKeepsOneCachePerAccount() throws {
    #expect(ClaudeStatuslineBridge.cacheURL(provider: .anthropic).lastPathComponent == "claude-statusline.json")
    #expect(
      ClaudeStatuslineBridge.cacheURL(provider: Self.team).lastPathComponent
        == "claude-statusline-anthropic-team.json")
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("reserve-claude2-statusline-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = root.appendingPathComponent("quota.json")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let input = Data(
      #"{"rate_limits":{"five_hour":{"used_percentage":24,"resets_at":1800000300}}}"#.utf8)
    #expect(try ClaudeStatuslineBridge.ingest(input, cacheURL: cache, now: now))
    let snapshot = try #require(
      ClaudeStatuslineBridge.read(cacheURL: cache, provider: Self.team, now: now))
    #expect(snapshot.provider == Self.team)
    #expect(ClaudeStatuslineBridge.read(cacheURL: cache, now: now)?.provider == .anthropic)
  }

  @Test func anAddedAccountSharesItsKindAndKeepsItsOwnIdentity() throws {
    // Same descriptor, helper, sign-in and logo as the kind's default account.
    let descriptor = ProviderDescriptor.forProvider(Self.team)
    #expect(descriptor.id == .anthropic)
    #expect(descriptor.displayName == "Claude")
    #expect(descriptor.helper?.executable == "claude")
    #expect(Self.team.isAnthropic && Self.team.isAdded && !Self.team.isDefault)
    #expect(ProviderID.anthropic.isDefault && !ProviderID.cursor.isAnthropic)
    #expect(ProviderKind.anthropic.supportsAddedAccounts && !ProviderKind.cursor.supportsAddedAccounts)
    // Raw values: the default account keeps the bare kind, so every setting
    // and cache written before accounts existed still names the same thing.
    #expect(ProviderID.anthropic.rawValue == "anthropic")
    #expect(Self.team.rawValue == "anthropic@team")
    #expect(ProviderID(rawValue: "anthropic@team") == Self.team)
    #expect(ProviderID(rawValue: "anthropic") == .anthropic)
    #expect(ProviderID(rawValue: "anthropic@") == nil)
    #expect(ProviderID(rawValue: "anthropic@bad name") == nil)
    #expect(ProviderID(rawValue: "nope@team") == nil)
    #expect(ProviderID(kind: .anthropic, instance: String(repeating: "a", count: 33)) == nil)
    #expect(ProviderID.defaults.map(\.rawValue)
      == ["openAI", "anthropic", "grok", "cursor", "copilot", "zai", "kimi", "gemini"])
    // Order: provider order, then the default account before added ones.
    let other = try #require(ProviderID(kind: .anthropic, instance: "aaa"))
    #expect([Self.team, .grok, other, .anthropic, .openAI].sorted() == [.openAI, .anthropic, other, Self.team, .grok])
    // Codable through the raw value, like the enum it replaces.
    let encoded = try JSONEncoder().encode([Self.team, .anthropic])
    #expect(String(decoding: encoded, as: UTF8.self) == #"["anthropic@team","anthropic"]"#)
    #expect(try JSONDecoder().decode([ProviderID].self, from: encoded) == [Self.team, .anthropic])
    // Dictionaries keyed by account keep the shape the history index is stored in.
    let keyed = try JSONEncoder().encode([ProviderID.anthropic: 1])
    #expect(String(decoding: keyed, as: UTF8.self) == #"["anthropic",1]"#)
    // The display name carries the account's label once it is known.
    ProviderAccountLabels.set("Nimbus", for: Self.team)
    defer { ProviderAccountLabels.set(nil, for: Self.team) }
    #expect(Self.team.displayName == "Claude · Nimbus")
    #expect(ProviderID.anthropic.displayName == "Claude")
  }
}

private actor RenewalEnvironmentRecorder {
  private(set) var environments: [[String: String]] = []
  func record(_ environment: [String: String]) { self.environments.append(environment) }
}
