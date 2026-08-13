import Foundation

public enum UsageBarSelfTests {
  public static func run(
    openAIData: Data,
    anthropicData: Data,
    grokData: Data,
    helperExecutable: String? = nil
  ) async throws -> [String] {
    var passed: [String] = []

    guard UsageWindow(id: "low", label: "Low", usedPercent: -2).usedPercent == 0,
      UsageWindow(id: "high", label: "High", usedPercent: 103).usedPercent == 100
    else { throw Failure("usage percentage clamping") }
    passed.append("usage percentage clamping")

    let httpConfiguration = ProviderHTTPSession.shared.configuration
    guard httpConfiguration.urlCache == nil,
      httpConfiguration.httpCookieStorage == nil,
      httpConfiguration.httpShouldSetCookies == false,
      httpConfiguration.requestCachePolicy == .reloadIgnoringLocalCacheData
    else { throw Failure("ephemeral provider HTTP session") }
    passed.append("ephemeral provider HTTP session")

    let openAI = try JSONDecoder().decode(OpenAIRateLimitsResponse.self, from: openAIData)
    guard openAI.rateLimits.primary?.usedPercent == 25.5,
      openAI.rateLimits.secondary?.windowDurationMins == 10080,
      openAI.rateLimits.primary?.stableID(fallback: "primary") == "five-hour",
      openAI.rateLimits.secondary?.stableID(fallback: "secondary") == "weekly",
      openAI.rateLimits.planType == "pro"
    else { throw Failure("OpenAI rate-limit decoding") }
    passed.append("OpenAI rate-limit decoding")

    let anthropic = try JSONDecoder().decode(ClaudeUsageResponse.self, from: anthropicData)
    guard anthropic.fiveHour?.utilization == 14.2,
      anthropic.limits?.first?.scope?.model?.displayName == "Fable",
      anthropic.extraUsage?.includedSpend?.usedMinorUnits == 2845,
      anthropic.extraUsage?.includedSpend?.limitMinorUnits == 10000,
      ClaudeUsageWindow(utilization: nil, resetsAt: nil).window(
        id: "missing", label: "Missing") == nil
    else { throw Failure("Anthropic usage decoding") }
    passed.append("Anthropic usage decoding")

    let retryNow = Date(timeIntervalSince1970: 1_800_000_000)
    guard
      AnthropicProvider.conservativeRetryDate(retryAfter: "60", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "1800", now: retryNow)
        == retryNow.addingTimeInterval(30 * 60),
      AnthropicProvider.conservativeRetryDate(retryAfter: "invalid", now: retryNow)
        == retryNow.addingTimeInterval(15 * 60)
    else { throw Failure("Anthropic conservative backoff") }
    passed.append("Anthropic conservative backoff")

    let anthropicDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: anthropicDirectory) }
    try FileManager.default.createDirectory(
      at: anthropicDirectory, withIntermediateDirectories: true)
    let anthropicCredential = Data(
      #"{"claudeAiOauth":{"accessToken":"fixture-token","subscriptionType":"pro"}}"#.utf8)
    try anthropicCredential.write(
      to: anthropicDirectory.appendingPathComponent(".credentials.json"), options: .atomic)
    let anthropicGate = ClaudeRateLimitGate(defaults: nil)
    let anthropicProvider = AnthropicProvider(
      environment: ["CLAUDE_CONFIG_DIR": anthropicDirectory.path],
      allowKeychainRead: false,
      requestHandler: { request in
        guard request.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage",
          request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token",
          request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20",
          request.cachePolicy == .reloadIgnoringLocalCacheData,
          request.httpShouldHandleCookies == false
        else { throw Failure("Anthropic provider request") }
        let response = HTTPURLResponse(
          url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
        return (anthropicData, response)
      },
      rateLimitGate: anthropicGate)
    let anthropicSnapshot = try await anthropicProvider.fetch()
    guard anthropicSnapshot.provider == .anthropic,
      anthropicSnapshot.planName == "Pro",
      anthropicSnapshot.source == "Claude OAuth file",
      anthropicSnapshot.windows.first?.id == "five-hour"
    else { throw Failure("Anthropic provider request") }
    passed.append("Anthropic provider request")

    let rateLimitedGate = ClaudeRateLimitGate(defaults: nil)
    let rateLimitedProvider = AnthropicProvider(
      environment: ["CLAUDE_CONFIG_DIR": anthropicDirectory.path],
      allowKeychainRead: false,
      requestHandler: { request in
        let response = HTTPURLResponse(
          url: request.url!,
          statusCode: 429,
          httpVersion: "HTTP/1.1",
          headerFields: ["Retry-After": "60"])!
        return (Data(), response)
      },
      rateLimitGate: rateLimitedGate)
    let beforeBackoff = Date()
    do {
      _ = try await rateLimitedProvider.fetch()
      throw Failure("Anthropic provider backoff")
    } catch UsageProviderError.rateLimited {
      guard let blockedUntil = await rateLimitedGate.activeBlock(now: beforeBackoff),
        blockedUntil >= beforeBackoff.addingTimeInterval(15 * 60)
      else { throw Failure("Anthropic provider backoff") }
    }
    passed.append("Anthropic provider backoff")

    let grok = try JSONDecoder().decode(GrokBillingEnvelope.self, from: grokData)
    guard grok.config?.usedPercent == 42.5,
      grok.config?.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY",
      grok.config?.includedSpend?.usedMinorUnits == 12345,
      grok.config?.includedSpend?.limitMinorUnits == 99900,
      grok.subscriptionTier == "SuperGrok Heavy"
    else { throw Failure("Grok billing decoding") }
    passed.append("Grok billing decoding")

    guard SemanticVersion.first(in: "grok 1.0.3") == SemanticVersion(1, 0, 3),
      SemanticVersion(1, 0, 3) > SemanticVersion(0, 1, 210)
    else { throw Failure("semantic version parsing") }
    passed.append("semantic version parsing")

    let future = "2033-05-18T03:33:20Z"
    let credentialEntries = [
      "https://auth.x.ai::broken": GrokCredentialEntry(
        key: nil, userID: "broken", expiresAt: future),
      "fallback": GrokCredentialEntry(
        key: "valid-key", userID: "valid-user", expiresAt: future),
    ]
    let selectedCredentials = GrokCredentialLoader.select(
      entries: credentialEntries,
      now: Date(timeIntervalSince1970: 1_800_000_000))
    guard selectedCredentials?.key == "valid-key", selectedCredentials?.userID == "valid-user"
    else { throw Failure("Grok credential selection") }
    passed.append("Grok credential selection")

    let usageDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("usage-index-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: usageDirectory) }
    let codexRoot = usageDirectory.appendingPathComponent("codex", isDirectory: true)
    let claudeRoot = usageDirectory.appendingPathComponent("claude", isDirectory: true)
    let grokRoot = usageDirectory.appendingPathComponent("grok", isDirectory: true)
    for root in [codexRoot, claudeRoot, grokRoot] {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    let now = Date()
    let timestamp = ISO8601DateFormatter().string(from: now)
    let codexLines =
      [
        #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"model":"gpt-5.6-sol"}}"#,
        #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":600,"cache_write_input_tokens":0,"output_tokens":20,"total_tokens":1020}}}}"#,
      ].joined(separator: "\n") + "\n"
    try Data(codexLines.utf8).write(to: codexRoot.appendingPathComponent("session.jsonl"))

    func claudeLine(output: Int, message: String, request: String) -> String {
      #"{"timestamp":"\#(timestamp)","type":"assistant","requestId":"\#(request)","message":{"id":"\#(message)","model":"claude-opus-5","usage":{"input_tokens":10,"cache_read_input_tokens":100,"cache_creation_input_tokens":20,"output_tokens":\#(output)}}}"#
    }
    let claudeURL = claudeRoot.appendingPathComponent("session.jsonl")
    try Data(
      ([
        claudeLine(output: 5, message: "m1", request: "r1"),
        claudeLine(output: 7, message: "m1", request: "r1"),
      ].joined(separator: "\n") + "\n").utf8
    ).write(to: claudeURL)
    let grokSession = grokRoot.appendingPathComponent("session", isDirectory: true)
    try FileManager.default.createDirectory(at: grokSession, withIntermediateDirectories: true)
    try Data(
      #"{"contextTokensUsed":300,"totalTokensBeforeCompaction":200,"primaryModelId":"grok-4.6"}"#
        .utf8
    ).write(to: grokSession.appendingPathComponent("signals.json"))

    let usageCache = usageDirectory.appendingPathComponent("private-index.json")
    let scanner = LocalUsageScanner(
      roots: .init(codex: codexRoot, claude: claudeRoot, grok: grokRoot),
      cacheURL: usageCache)
    let firstUsage = try await scanner.scan(periodDays: 30, now: now)
    let secondUsage = try await scanner.scan(periodDays: 30, now: now)
    guard firstUsage[.openAI]?.totalTokens == 1020,
      firstUsage[.anthropic]?.totalTokens == 137,
      firstUsage[.grok]?.totalTokens == 500,
      firstUsage == secondUsage,
      (firstUsage[.openAI]?.apiEquivalentCostUSD ?? 0) > 0,
      (firstUsage[.anthropic]?.apiEquivalentCostUSD ?? 0) > 0,
      firstUsage[.grok]?.isCostEstimate == true,
      let usageCacheData = try? Data(contentsOf: usageCache),
      !String(decoding: usageCacheData, as: UTF8.self).contains(usageDirectory.path)
    else { throw Failure("incremental local usage accounting") }
    passed.append("incremental local usage accounting")

    if let helperExecutable {
      let start = ContinuousClock.now
      var timedOut = false
      do {
        _ = try await ProcessRunner.output(
          executable: helperExecutable,
          arguments: ["--timeout-helper"],
          environment: ProcessInfo.processInfo.environment,
          timeout: .milliseconds(100))
      } catch UsageProviderError.timedOut {
        timedOut = true
      } catch {
        throw Failure("subprocess timeout escalation")
      }
      guard timedOut, start.duration(to: .now) < .seconds(2) else {
        throw Failure("subprocess timeout escalation")
      }
      passed.append("subprocess timeout escalation")

      let oversizedStart = ContinuousClock.now
      var rejectedOversizedOutput = false
      do {
        _ = try await ProcessRunner.output(
          executable: helperExecutable,
          arguments: ["--oversized-output-helper"],
          environment: ProcessInfo.processInfo.environment,
          timeout: .seconds(2))
      } catch UsageProviderError.invalidResponse {
        rejectedOversizedOutput = true
      } catch {
        throw Failure("bounded subprocess output")
      }
      guard rejectedOversizedOutput, oversizedStart.duration(to: .now) < .seconds(2) else {
        throw Failure("bounded subprocess output")
      }
      passed.append("bounded subprocess output")
    }

    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("snapshots.json")
    let cache = SnapshotCache(fileURL: url)
    let snapshot = UsageSnapshot(
      provider: .openAI,
      planName: "Pro",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)],
      source: "test",
      includedSpend: IncludedSpend(
        label: "Included credits", usedMinorUnits: 1234, limitMinorUnits: 5000))
    try await cache.save([.openAI: snapshot])
    let data = try Data(contentsOf: url)
    let text = String(decoding: data, as: UTF8.self)
    let loaded = await cache.load()[.openAI]
    let fileMode =
      try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
      as? NSNumber
    let directoryMode =
      try FileManager.default.attributesOfItem(atPath: directory.path)[
        .posixPermissions] as? NSNumber
    guard data.count < 100_000,
      fileMode?.intValue == 0o600,
      directoryMode?.intValue == 0o700,
      !text.localizedCaseInsensitiveContains("access_token"),
      !text.localizedCaseInsensitiveContains("authorization"),
      loaded?.provider == snapshot.provider,
      loaded?.planName == snapshot.planName,
      loaded?.windows == snapshot.windows,
      loaded?.source == snapshot.source,
      loaded?.includedSpend == snapshot.includedSpend
    else { throw Failure("normalized snapshot cache") }
    passed.append("normalized snapshot cache")

    let older = UsageSnapshot(
      provider: .openAI,
      planName: "Old",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 90)],
      fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
      source: "duplicate-test")
    let newer = UsageSnapshot(
      provider: .openAI,
      planName: "New",
      windows: [UsageWindow(id: "weekly", label: "Weekly", usedPercent: 10)],
      fetchedAt: Date(timeIntervalSince1970: 1_800_000_100),
      source: "duplicate-test")
    let duplicateEncoder = JSONEncoder()
    duplicateEncoder.dateEncodingStrategy = .iso8601
    try duplicateEncoder.encode([newer, older]).write(to: url, options: .atomic)
    let duplicateLoaded = await cache.load()[.openAI]
    guard duplicateLoaded?.planName == "New", duplicateLoaded?.windows == newer.windows else {
      throw Failure("duplicate snapshot recovery")
    }
    passed.append("duplicate snapshot recovery")

    try Data(repeating: 0x41, count: 100 * 1024 + 1).write(to: url, options: .atomic)
    guard await cache.load().isEmpty else { throw Failure("oversized cache rejection") }
    passed.append("oversized cache rejection")

    return passed
  }

  private struct Failure: LocalizedError {
    let name: String
    init(_ name: String) { self.name = name }
    var errorDescription: String? { "Self-test failed: \(self.name)" }
  }
}
