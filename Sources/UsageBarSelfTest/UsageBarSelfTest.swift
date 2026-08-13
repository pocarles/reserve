import Foundation
import UsageBarCore

@main
struct UsageBarSelfTest {
  static func main() async throws {
    let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    let passed = try await UsageBarSelfTests.run(
      openAIData: try Data(contentsOf: fixtures.appendingPathComponent("openai-rate-limits.json")),
      anthropicData: try Data(contentsOf: fixtures.appendingPathComponent("anthropic-usage.json")),
      grokData: try Data(contentsOf: fixtures.appendingPathComponent("grok-billing.json")))
    for name in passed {
      print("PASS \(name)")
    }
    print("\n\(passed.count) self-tests passed")
  }
}
