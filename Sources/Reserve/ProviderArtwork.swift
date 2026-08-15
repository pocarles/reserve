import AppKit
import ReserveCore

/// Neutral provider identity used when Reserve cannot ship an exact, licensed
/// provider mark. These glyphs are generated locally and contain no third-party
/// artwork.
@MainActor
enum ProviderArtwork {
  private static var cache: [ProviderID: NSImage] = [:]

  static func image(for provider: ProviderID) -> NSImage {
    if let cached = Self.cache[provider] {
      return cached.copy() as? NSImage ?? cached
    }
    let letter: String =
      switch provider {
      case .openAI: "O"
      case .anthropic: "A"
      case .grok: "G"
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
    image.accessibilityDescription = provider.displayName
    Self.cache[provider] = image
    return image.copy() as? NSImage ?? image
  }
}
