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

    let grok = try JSONDecoder().decode(GrokBillingEnvelope.self, from: grokData)
    guard grok.config?.usedPercent == 42.5,
      grok.config?.currentPeriod?.type == "USAGE_PERIOD_TYPE_WEEKLY",
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
      source: "test")
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
      loaded?.source == snapshot.source
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
