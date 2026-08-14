import AppKit
import UsageBarCore

enum ProviderArtwork {
  static func image(for provider: ProviderID) -> NSImage {
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
