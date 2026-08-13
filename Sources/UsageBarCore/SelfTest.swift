import Foundation

public enum UsageBarSelfTests {
  public static func run(
    openAIData: Data,
    anthropicData: Data,
    grokData: Data
  ) async throws -> [String] {
    var passed: [String] = []

    guard UsageWindow(id: "low", label: "Low", usedPercent: -2).usedPercent == 0,
      UsageWindow(id: "high", label: "High", usedPercent: 103).usedPercent == 100
    else { throw Failure("usage percentage clamping") }
    passed.append("usage percentage clamping")

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
      anthropic.limits?.first?.scope?.model?.displayName == "Fable"
    else { throw Failure("Anthropic usage decoding") }
    passed.append("Anthropic usage decoding")

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
    guard data.count < 100_000,
      !text.localizedCaseInsensitiveContains("access_token"),
      !text.localizedCaseInsensitiveContains("authorization"),
      loaded?.provider == snapshot.provider,
      loaded?.planName == snapshot.planName,
      loaded?.windows == snapshot.windows,
      loaded?.source == snapshot.source
    else { throw Failure("normalized snapshot cache") }
    passed.append("normalized snapshot cache")

    return passed
  }

  private struct Failure: LocalizedError {
    let name: String
    init(_ name: String) { self.name = name }
    var errorDescription: String? { "Self-test failed: \(self.name)" }
  }
}
