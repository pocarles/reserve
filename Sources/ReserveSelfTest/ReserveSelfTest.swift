import Darwin
import Foundation
import ReserveCore

@main
struct ReserveSelfTest {
  static func main() async throws {
    if CommandLine.arguments.contains("--oversized-output-helper") {
      FileHandle.standardOutput.write(Data(repeating: 0x41, count: 128 * 1024))
      return
    }
    if CommandLine.arguments.contains("--timeout-helper") {
      signal(SIGTERM, SIG_IGN)
      while true { pause() }
    }
    if CommandLine.arguments.contains("--descendant-pipe-helper") {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: "/bin/sleep")
      child.arguments = ["5"]
      child.standardOutput = FileHandle.standardOutput
      child.standardError = FileHandle.standardError
      try child.run()
      return
    }

    let fixtures = Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    let passed = try await ReserveSelfTests.run(
      openAIData: try Data(contentsOf: fixtures.appendingPathComponent("openai-rate-limits.json")),
      anthropicData: try Data(contentsOf: fixtures.appendingPathComponent("anthropic-usage.json")),
      grokData: try Data(contentsOf: fixtures.appendingPathComponent("grok-billing.json")),
      cursorUsageData: try Data(contentsOf: fixtures.appendingPathComponent("cursor-usage.json")),
      cursorDisabledSpendData: try Data(
        contentsOf: fixtures.appendingPathComponent("cursor-spending-disabled.json")),
      cursorMissingFieldsData: try Data(
        contentsOf: fixtures.appendingPathComponent("cursor-missing-fields.json")),
      cursorMalformedData: try Data(
        contentsOf: fixtures.appendingPathComponent("cursor-malformed-values.json")),
      helperExecutable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path,
      progress: { name in
        print("PASS \(name)")
        fflush(stdout)
      })
    print("\n\(passed.count) self-tests passed")
  }
}
