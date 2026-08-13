import Darwin
import Foundation
import UsageBarCore

@main
struct UsageBarSelfTest {
  static func main() async throws {
    if CommandLine.arguments.contains("--oversized-output-helper") {
      FileHandle.standardOutput.write(Data(repeating: 0x41, count: 128 * 1024))
      return
    }
    if CommandLine.arguments.contains("--timeout-helper") {
      signal(SIGTERM, SIG_IGN)
      while true { pause() }
    }

    let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    let passed = try await UsageBarSelfTests.run(
      openAIData: try Data(contentsOf: fixtures.appendingPathComponent("openai-rate-limits.json")),
      anthropicData: try Data(contentsOf: fixtures.appendingPathComponent("anthropic-usage.json")),
      grokData: try Data(contentsOf: fixtures.appendingPathComponent("grok-billing.json")),
      helperExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path)
    for name in passed {
      print("PASS \(name)")
    }
    print("\n\(passed.count) self-tests passed")
  }
}
