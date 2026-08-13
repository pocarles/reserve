import Darwin
import Foundation
import UsageBarCore

@main
struct UsageBarProbe {
  static func main() async {
    let appDefaults = UserDefaults(suiteName: "com.pocarles.usagebar")
    let allowClaudeKeychainRead =
      appDefaults?.bool(forKey: "anthropic.keychainReadAllowed") ?? false
    let argument = CommandLine.arguments.dropFirst().first
    if argument?.lowercased() == "local" {
      await self.printLocalUsage()
      return
    }
    let selected: [ProviderID]
    switch argument?.lowercased() {
    case "openai": selected = [.openAI]
    case "anthropic", "claude": selected = [.anthropic]
    case "grok": selected = [.grok]
    case nil, "all": selected = ProviderID.allCases
    default:
      FileHandle.standardError.write(
        Data("Usage: usagebar-probe [openai|anthropic|grok|local|all]\n".utf8))
      exit(64)
    }

    var snapshots: [UsageSnapshot] = []
    var failures: [String: String] = [:]
    for provider in selected {
      let fetcher: any UsageProvider =
        switch provider {
        case .openAI: OpenAIProvider()
        case .anthropic: AnthropicProvider(allowKeychainRead: allowClaudeKeychainRead)
        case .grok: GrokProvider()
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
