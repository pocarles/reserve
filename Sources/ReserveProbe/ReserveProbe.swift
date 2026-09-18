import Darwin
import Foundation
import ReserveCore

@main
struct ReserveProbe {
  static func main() async {
    let appDefaults = UserDefaults(suiteName: "com.pocarles.reserve")
    let allowClaudeKeychainRead =
      appDefaults?.bool(forKey: "anthropic.keychainReadAllowed") ?? false
    let allowCursorKeychainRead =
      appDefaults?.bool(forKey: "cursor.keychainReadAllowed") ?? false
    let arguments = Array(CommandLine.arguments.dropFirst())
    let includeInsights = arguments.contains("--insights")
    let argument = arguments.first(where: { !$0.hasPrefix("--") })
    if argument?.lowercased() == "local" {
      await self.printLocalUsage()
      return
    }
    let selected: [ProviderID]
    switch argument?.lowercased() {
    case "openai": selected = [.openAI]
    case "anthropic", "claude": selected = [.anthropic]
    case "grok": selected = [.grok]
    case "cursor": selected = [.cursor]
    case "copilot": selected = [.copilot]
    case "zai", "z.ai": selected = [.zai]
    case "kimi": selected = [.kimi]
    case nil, "all":
      // Key-connected plans are probed only when a key is saved, so "all"
      // does not report an unconfigured plan as a failure.
      selected = ProviderID.allCases.filter {
        !ProviderDescriptor.forProvider($0).usesAPIKey || PlanKeyKeychain.hasKey(for: $0)
      }
    default:
      FileHandle.standardError.write(
        Data("Usage: reserve-probe [openai|anthropic|grok|cursor|copilot|zai|kimi|local|all] [--insights]\n".utf8))
      exit(64)
    }

    var snapshots: [UsageSnapshot] = []
    var failures: [String: String] = [:]
    for provider in selected {
      let fetcher: any UsageProvider =
        switch provider {
        case .openAI: OpenAIProvider(includeAccountActivity: includeInsights)
        case .anthropic: AnthropicProvider(allowKeychainRead: allowClaudeKeychainRead)
        case .grok: GrokProvider()
        case .cursor: CursorProvider(allowKeychainRead: allowCursorKeychainRead, includeAccountUsage: includeInsights)
        case .copilot: CopilotProvider()
        case .zai: ZaiProvider()
        case .kimi: KimiProvider()
        }
      do {
        snapshots.append(try await fetcher.fetch())
      } catch {
        failures[provider.rawValue] = error.localizedDescription
      }
    }

    let output = ProbeOutput(snapshots: snapshots, failures: failures)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let data = (try? encoder.encode(output)) ?? Data("{}".utf8)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data([0x0A]))
    if !failures.isEmpty { exit(1) }
  }

  private static func printLocalUsage() async {
    do {
      let summaries = try await LocalUsageScanner().scan(periodDays: 30)
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      encoder.dateEncodingStrategy = .iso8601
      let values = ProviderID.allCases.compactMap { summaries[$0] }
      FileHandle.standardOutput.write(try encoder.encode(values))
      FileHandle.standardOutput.write(Data([0x0A]))
    } catch {
      FileHandle.standardError.write(Data("Local usage scan failed: \(error)\n".utf8))
      exit(1)
    }
  }
}

private struct ProbeOutput: Encodable {
  let snapshots: [UsageSnapshot]
  let failures: [String: String]
}
