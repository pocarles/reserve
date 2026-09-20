import Foundation
import Testing
@testable import ReserveCore

@Suite("Shareable usage card")
struct UsageShareCardTests {
  @Test func dynamicPersonalTextNeverReachesTheModelOrText() {
    let poison = "ada@example.com / Acme Org / /Users/ada/.codex/sessions/secret.jsonl"
    let window = UsageWindow(
      id: poison, label: poison, usedPercent: 25, windowMinutes: 10_080,
      resetsAt: Date(timeIntervalSince1970: 1_800_000_000))
    let model = UsageShareCardBuilder.model(
      provider: .anthropic,
      planName: poison,
      windows: [window],
      tokensUsed: 1_200,
      tokenPeriodDays: 30,
      tokensCheckedAt: nil,
      estimatedAPIEquivalentUSD: 4.5,
      generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
      hidingPersonal: false)
    let text = model.plainText()
    #expect(model.providerName == "Claude")
    #expect(model.planName == nil)
    #expect(model.windows.isEmpty)
    #expect(!text.contains("ada@"))
    #expect(!text.contains("Acme"))
    #expect(!text.contains("/Users"))
    #expect(!text.contains("secret"))
    #expect(text.contains("Tokens used, last 30 days"))
    #expect(text.contains("freshness unknown"))
    #expect(text.contains("Not an actual charge"))
    #expect(!text.contains("Tokens available"))
  }

  @Test func knownPlanAndWindowStay() {
    let window = UsageWindow(
      id: "weekly", label: "Weekly", usedPercent: 20, windowMinutes: 10_080, resetsAt: nil)
    let checked = Date(timeIntervalSince1970: 1_700_000_100)
    let model = UsageShareCardBuilder.model(
      provider: .openAI,
      planName: "Plus",
      windows: [window],
      tokensUsed: 80,
      tokenPeriodDays: 30,
      tokensCheckedAt: checked,
      estimatedAPIEquivalentUSD: 1.25,
      generatedAt: checked,
      hidingPersonal: true)
    #expect(model.planName == "Plus")
    #expect(model.windows.first?.label == "Weekly limit")
    #expect(model.windows.first?.remainingPercent == 80)
    let text = model.plainText(now: checked)
    #expect(text.contains("Plan: Plus"))
    #expect(text.contains("80% left"))
    #expect(text.contains("Estimated API equivalent: $1.25"))
  }

  @Test func quotaFreshnessIsNotBorrowedFromTokenFreshness() {
    let quota = Date(timeIntervalSince1970: 1_700_000_000)
    let tokens = Date(timeIntervalSince1970: 1_700_000_000 + 6 * 3_600)
    let window = UsageWindow(
      id: "weekly", label: "Weekly", usedPercent: 40, windowMinutes: 10_080, resetsAt: nil)
    let model = UsageShareCardBuilder.model(
      provider: .anthropic,
      planName: "Pro",
      windows: [window],
      tokensUsed: 90,
      tokenPeriodDays: 30,
      tokensCheckedAt: tokens,
      estimatedAPIEquivalentUSD: 2,
      generatedAt: tokens,
      hidingPersonal: true,
      quotaCheckedAt: quota)
    #expect(model.quotaCheckedAt == quota)
    #expect(model.tokensCheckedAt == tokens)
    let text = model.plainText(now: tokens)
    #expect(text.contains("Quota as of"))
    #expect(text.contains("Tokens used, last 30 days"))
    let quotaLine = text.split(separator: "\n").first { $0.hasPrefix("Quota as of") } ?? ""
    let tokenLine = text.split(separator: "\n").first { $0.hasPrefix("Tokens used") } ?? ""
    #expect(quotaLine != tokenLine)
    #expect(!quotaLine.contains(DashboardShareFormat.moment(tokens)))
    #expect(quotaLine.contains(DashboardShareFormat.moment(quota)))
  }

  @Test func nonfiniteCostIsOmitted() {
    let model = UsageShareCardBuilder.model(
      provider: .grok,
      planName: "not-a-plan",
      windows: [],
      tokensUsed: nil,
      tokenPeriodDays: nil,
      tokensCheckedAt: nil,
      estimatedAPIEquivalentUSD: .infinity,
      generatedAt: Date(),
      hidingPersonal: true)
    #expect(model.estimatedAPIEquivalentUSD == nil)
    #expect(model.plainText().contains("Estimated API equivalent: unavailable"))
  }
}
