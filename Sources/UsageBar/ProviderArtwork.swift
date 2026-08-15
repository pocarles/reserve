import AppKit
import UsageBarCore

@MainActor
enum ProviderArtwork {
  /// Parsed once. Callers get a copy, because the status item mutates `size`
  /// and `isTemplate` on what it is handed, and a shared instance would carry
  /// those edits into every provider logo on the dashboard.
  private static var cache: [ProviderID: NSImage] = [:]

  static func image(for provider: ProviderID) -> NSImage {
    if let cached = Self.cache[provider] {
      return cached.copy() as? NSImage ?? cached
    }
    let image = Self.load(provider)
    Self.cache[provider] = image
    return image.copy() as? NSImage ?? image
  }

  private static func load(_ provider: ProviderID) -> NSImage {
    let packagedBundle = Bundle.main.resourceURL.map {
      $0.appendingPathComponent("UsageBar_UsageBar.bundle")
    }.flatMap { Bundle(url: $0) }
    let resources = packagedBundle ?? Bundle.module
    let resourceName: String =
      switch provider {
      case .openAI: "openai"
      case .anthropic: "anthropic"
      case .grok: "grok"
      }
    let url =
      resources.url(
        forResource: resourceName, withExtension: "svg", subdirectory: "Resources")
      ?? resources.url(forResource: resourceName, withExtension: "svg")
    let image = url.flatMap(NSImage.init(contentsOf:)) ?? NSImage()
    image.isTemplate = true
    image.accessibilityDescription = provider.displayName
    return image
  }
}
