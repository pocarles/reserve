import AppKit
import ReserveCore

/// First-party provider marks bundled without geometric or colour changes.
/// A neutral initial remains as a packaging-failure fallback so a missing
/// resource cannot leave an invisible control behind.
@MainActor
enum ProviderArtwork {
  private static var cache: [ProviderID: NSImage] = [:]

  static func image(for provider: ProviderID) -> NSImage {
    if let cached = Self.cache[provider] {
      return cached.copy() as? NSImage ?? cached
    }
    let image = self.bundledImage(for: provider) ?? self.fallbackImage(for: provider)
    image.accessibilityDescription = provider.displayName
    Self.cache[provider] = image
    return image.copy() as? NSImage ?? image
  }

  static func hasBundledMark(for provider: ProviderID) -> Bool {
    self.bundledImage(for: provider) != nil
  }

  private static func bundledImage(for provider: ProviderID) -> NSImage? {
    let bundle = self.packagedResourceBundle ?? Bundle.module
    guard
      let url = bundle.url(
        forResource: provider.rawValue,
        withExtension: "svg",
        subdirectory: "ProviderLogos"),
      let image = NSImage(contentsOf: url), image.isValid
    else { return nil }
    // OpenAI and xAI publish monochrome marks. Template rendering supplies the
    // surrounding label colour without changing their first-party geometry.
    image.isTemplate = provider != .anthropic
    return image
  }

  private static var packagedResourceBundle: Bundle? {
    guard
      Bundle.main.bundleURL.pathExtension == "app",
      let url = Bundle.main.url(forResource: "Reserve_Reserve", withExtension: "bundle")
    else { return nil }
    return Bundle(url: url)
  }

  private static func fallbackImage(for provider: ProviderID) -> NSImage {
    let letter: String =
      switch provider {
      case .openAI: "O"
      case .anthropic: "A"
      case .grok: "G"
      case .cursor: "C"
      }
    let size = NSSize(width: 18, height: 18)
    let image = NSImage(size: size, flipped: false) { rect in
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: NSColor.black,
      ]
      let string = NSAttributedString(string: letter, attributes: attributes)
      let measured = string.size()
      string.draw(
        at: NSPoint(
          x: rect.midX - measured.width / 2,
          y: rect.midY - measured.height / 2))
      return true
    }
    image.isTemplate = true
    return image
  }
}
