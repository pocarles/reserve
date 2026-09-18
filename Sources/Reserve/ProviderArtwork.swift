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
    let image = provider == .copilot
      ? (NSImage(systemSymbolName: "chevron.left.forwardslash.chevron.right", accessibilityDescription: "Copilot") ?? self.fallbackImage(for: provider))
      : (self.bundledImage(for: provider) ?? self.fallbackImage(for: provider))
    image.accessibilityDescription = provider.displayName
    Self.cache[provider] = image
    return image.copy() as? NSImage ?? image
  }

  static func hasBundledMark(for provider: ProviderID) -> Bool {
    self.bundledImage(for: provider) != nil
  }

  /// API accounts reuse the subscription mark when the same company publishes
  /// both — Grok's bundled mark is xAI's. OpenRouter, TypeSafe, DeepSeek and
  /// Moonshot get the neutral initial rather than a mark invented for them here.
  static func image(for provider: APIConsumptionProvider) -> NSImage {
    let image =
      switch provider {
      case .openAI: self.image(for: ProviderID.openAI)
      case .anthropic: self.image(for: ProviderID.anthropic)
      case .xAI: self.image(for: ProviderID.grok)
      case .openRouter: self.initialImage("OR")
      case .typeSafe: self.initialImage("TS")
      case .deepSeek: self.initialImage("DS")
      case .moonshot: self.initialImage("MS")
      }
    image.accessibilityDescription = provider.displayName
    return image
  }

  /// True when the mark is the provider's own, false for a stand-in initial.
  static func hasBundledMark(for provider: APIConsumptionProvider) -> Bool {
    switch provider {
    case .openAI: self.hasBundledMark(for: ProviderID.openAI)
    case .anthropic: self.hasBundledMark(for: ProviderID.anthropic)
    case .xAI: self.hasBundledMark(for: ProviderID.grok)
    case .openRouter, .typeSafe, .deepSeek, .moonshot: false
    }
  }

  private static func bundledImage(for provider: ProviderID) -> NSImage? {
    guard
      let url = Bundle.reserveResources.url(
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

  private static func fallbackImage(for provider: ProviderID) -> NSImage {
    let letter: String =
      switch provider {
      case .openAI: "O"
      case .anthropic: "A"
      case .grok: "G"
      case .cursor: "C"
      case .copilot: "C"
      // No mark is bundled for these; the neutral initial is their icon.
      case .zai: "Z"
      case .kimi: "K"
      case .gemini: "G"
      }
    return self.initialImage(letter)
  }

  private static func initialImage(_ letters: String) -> NSImage {
    let size = NSSize(width: 18, height: 18)
    // Two letters have to fit the same box a single one does.
    let pointSize: CGFloat = letters.count > 1 ? 11 : 13
    let image = NSImage(size: size, flipped: false) { rect in
      let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: pointSize, weight: .semibold),
        .foregroundColor: NSColor.black,
      ]
      let string = NSAttributedString(string: letters, attributes: attributes)
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
