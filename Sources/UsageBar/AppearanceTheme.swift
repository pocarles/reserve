import AppKit

enum AppearanceTheme: String, CaseIterable {
  case matrix
  case ember
  case ocean
  case graphite

  var displayName: String {
    switch self {
    case .matrix: "Matrix"
    case .ember: "Ember"
    case .ocean: "Ocean"
    case .graphite: "Graphite"
    }
  }

  /// Each identity supplies an adaptive family rather than a single accent.
  /// Large surfaces use restrained tints; controls and charts carry the
  /// stronger color. Pace semantics never come from this palette.
  var palette: AppearancePalette {
    switch self {
    case .matrix:
      AppearancePalette(
        windowBase: adaptive(light: 0xF7FAF7, dark: 0x101612),
        elevatedSurface: adaptive(light: 0xEFF6F0, dark: 0x18221B),
        cardSurface: adaptive(light: 0xFBFDFC, dark: 0x151D17),
        border: adaptive(light: 0xCDE0D1, dark: 0x314A38),
        progressTrack: adaptive(light: 0xDDE9DF, dark: 0x26372B),
        accent: adaptive(light: 0x278E49, dark: 0x55CF77),
        hoverFill: adaptive(light: 0xE6F3E8, dark: 0x213326),
        selectedFill: adaptive(light: 0xD9EEDD, dark: 0x28462F),
        chartPrimary: adaptive(light: 0x2E9B51, dark: 0x62D681),
        chartSecondary: adaptive(light: 0x84B993, dark: 0x4F8760))
    case .ember:
      AppearancePalette(
        windowBase: adaptive(light: 0xFCF8F3, dark: 0x1B1512),
        elevatedSurface: adaptive(light: 0xF7EEE5, dark: 0x281D18),
        cardSurface: adaptive(light: 0xFFFDFC, dark: 0x211916),
        border: adaptive(light: 0xE6D4C4, dark: 0x51382D),
        progressTrack: adaptive(light: 0xEDE0D4, dark: 0x3D2C25),
        accent: adaptive(light: 0xB75C35, dark: 0xEC8A5E),
        hoverFill: adaptive(light: 0xF7E7DA, dark: 0x38261F),
        selectedFill: adaptive(light: 0xF3DCCB, dark: 0x4A2F24),
        chartPrimary: adaptive(light: 0xBF633B, dark: 0xF09970),
        chartSecondary: adaptive(light: 0xC99A7D, dark: 0xA56A50))
    case .ocean:
      AppearancePalette(
        windowBase: adaptive(light: 0xF5F9FC, dark: 0x0E1820),
        elevatedSurface: adaptive(light: 0xEAF3F8, dark: 0x142632),
        cardSurface: adaptive(light: 0xFAFCFE, dark: 0x121F28),
        border: adaptive(light: 0xC7DCE8, dark: 0x31566C),
        progressTrack: adaptive(light: 0xD8E7EF, dark: 0x263E4C),
        accent: adaptive(light: 0x247FAF, dark: 0x54B8E8),
        hoverFill: adaptive(light: 0xE1EFF6, dark: 0x1C3442),
        selectedFill: adaptive(light: 0xD2E8F3, dark: 0x23475A),
        chartPrimary: adaptive(light: 0x2A88B8, dark: 0x60C1EE),
        chartSecondary: adaptive(light: 0x7CABBF, dark: 0x4B819A))
    case .graphite:
      AppearancePalette(
        windowBase: adaptive(light: 0xF7F8F9, dark: 0x151617),
        elevatedSurface: adaptive(light: 0xEEF0F2, dark: 0x222426),
        cardSurface: adaptive(light: 0xFCFCFD, dark: 0x1C1E20),
        border: adaptive(light: 0xD4D8DC, dark: 0x484C50),
        progressTrack: adaptive(light: 0xE0E3E6, dark: 0x34373A),
        accent: adaptive(light: 0x5E666E, dark: 0xC3C8CD),
        hoverFill: adaptive(light: 0xE9EBED, dark: 0x2C2F32),
        selectedFill: adaptive(light: 0xDDE0E3, dark: 0x3A3E42),
        chartPrimary: adaptive(light: 0x68717A, dark: 0xD0D4D8),
        chartSecondary: adaptive(light: 0x9DA3A9, dark: 0x858B91))
    }
  }
}

struct AppearancePalette {
  let windowBase: NSColor
  let elevatedSurface: NSColor
  let cardSurface: NSColor
  let border: NSColor
  let progressTrack: NSColor
  let accent: NSColor
  let hoverFill: NSColor
  let selectedFill: NSColor
  let chartPrimary: NSColor
  let chartSecondary: NSColor
}

enum AppearanceMode: String, CaseIterable {
  case system
  case light
  case dark

  var displayName: String {
    switch self {
    case .system: "System"
    case .light: "Light"
    case .dark: "Dark"
    }
  }

  var nsAppearance: NSAppearance? {
    switch self {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }
}

@MainActor
enum ReserveAppearance {
  static var current: AppearanceTheme = .matrix
  static var palette: AppearancePalette { self.current.palette }
  static var accent: NSColor { self.palette.accent }

  static var mode: AppearanceMode = .system {
    didSet { Self.apply() }
  }

  static func apply() {
    NSApplication.shared.appearance = Self.mode.nsAppearance
  }
}

private func adaptive(light: UInt32, dark: UInt32) -> NSColor {
  NSColor(name: nil) { appearance in
    let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    return NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1)
  }
}
