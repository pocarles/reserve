import AppKit
import CoreText
import UsageBarCore

/// Layout constants for the popover dashboard.
enum DashboardMetrics {
  static let width: CGFloat = 444
  static let horizontalInset: CGFloat = 22
  static let topInset: CGFloat = 20
  static let bottomInset: CGFloat = 16
  static let sectionSpacing: CGFloat = 12
  static let cardPadding: CGFloat = 16
  static let minimumHeight: CGFloat = 360
  static let maximumHeight: CGFloat = 880

  static var contentWidth: CGFloat { self.width - 2 * self.horizontalInset }
  static var cardContentWidth: CGFloat { self.contentWidth - 2 * self.cardPadding }
}

/// A warm, paper-like palette that follows the system appearance.
///
/// Light is an ivory sheet with white cards; dark is the same composition in
/// warm charcoal, so the dashboard keeps one identity in both appearances.
enum DashboardPalette {
  static let background = Self.dynamic(light: 0xF4_F2_EC, dark: 0x1C_1A_18)
  static let card = Self.dynamic(light: 0xFF_FE_FB, dark: 0x2C_28_25)
  static let surface = Self.dynamic(light: 0xEC_E9_E0, dark: 0x3A_35_30)
  static let border = Self.dynamic(light: 0xE2_DE_D2, dark: 0x3E_39_33)
  static let hairline = Self.dynamic(light: 0xEA_E6_DC, dark: 0x39_34_2F)
  static let track = Self.dynamic(light: 0xE6_E2_D6, dark: 0x40_3A_34)
  static let text = Self.dynamic(light: 0x1D_1B_18, dark: 0xF3_F1_EC)
  static let muted = Self.dynamic(light: 0x6C_67_5E, dark: 0xA5_9E_95)
  static let subtle = Self.dynamic(light: 0x97_91_86, dark: 0x77_71_69)
  static let success = Self.dynamic(light: 0x3C_74_58, dark: 0x74_BA_97)
  static let warning = Self.dynamic(light: 0xA5_5F_20, dark: 0xDE_96_57)
  static let onAccent = Self.dynamic(light: 0xFF_FF_FF, dark: 0x1A_18_16)

  static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark =
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return Self.color(isDark ? dark : light)
    }
  }

  private static func color(_ value: UInt32) -> NSColor {
    NSColor(
      srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1)
  }
}

enum DashboardFont {
  static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
  }

  static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .monospacedDigitSystemFont(ofSize: size, weight: weight)
  }

  /// New York, used for the display numbers that carry the dashboard.
  static func serif(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let serif = base.fontDescriptor.withDesign(.serif) else { return base }
    let tabular: [[NSFontDescriptor.FeatureKey: Any]] = [
      [
        .typeIdentifier: kNumberSpacingType,
        .selectorIdentifier: kMonospacedNumbersSelector,
      ]
    ]
    let descriptor = serif.addingAttributes([.featureSettings: tabular])
    return NSFont(descriptor: descriptor, size: size) ?? NSFont(descriptor: serif, size: size)
      ?? base
  }
}

/// A layer-backed rectangle that re-resolves its dynamic colors when the
/// system appearance changes.
@MainActor
class DashboardSurface: NSView {
  private let fill: NSColor?
  private let fillAlpha: CGFloat
  private let stroke: NSColor?
  private let radius: CGFloat

  init(fill: NSColor?, fillAlpha: CGFloat = 1, stroke: NSColor? = nil, radius: CGFloat = 0) {
    self.fill = fill
    self.fillAlpha = fillAlpha
    self.stroke = stroke
    self.radius = radius
    super.init(frame: .zero)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    self.layer?.cornerRadius = self.radius
    self.layer?.cornerCurve = .continuous
    self.layer?.borderWidth = self.stroke == nil ? 0 : 1
    self.effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = self.fill?.withAlphaComponent(self.fillAlpha).cgColor
      self.layer?.borderColor = self.stroke?.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.needsDisplay = true
  }
}

/// Non-editable text with optional letter spacing, kept in sync with the
/// current appearance.
@MainActor
final class DashboardLabel: NSTextField {
  private let color: NSColor
  private let tracking: CGFloat

  init(
    _ text: String,
    font: NSFont,
    color: NSColor,
    tracking: CGFloat = 0,
    alignment: NSTextAlignment = .natural
  ) {
    self.color = color
    self.tracking = tracking
    super.init(frame: .zero)
    self.isEditable = false
    self.isSelectable = false
    self.isBezeled = false
    self.drawsBackground = false
    self.font = font
    self.alignment = alignment
    self.lineBreakMode = .byTruncatingTail
    self.maximumNumberOfLines = 1
    self.stringValue = text
    self.textColor = color
    self.applyTracking()
  }

  /// Pins the label to an exact width so columns line up and text truncates
  /// predictably instead of squeezing its neighbours.
  @discardableResult
  func width(_ value: CGFloat) -> Self {
    self.translatesAutoresizingMaskIntoConstraints = false
    self.widthAnchor.constraint(equalToConstant: value).isActive = true
    self.setContentCompressionResistancePriority(.required, for: .horizontal)
    self.setContentHuggingPriority(.required, for: .horizontal)
    return self
  }

  /// Marks the label as the one that should truncate when a row runs short.
  @discardableResult
  func flexible() -> Self {
    self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return self
  }

  /// Marks the label as one that must never be clipped.
  @discardableResult
  func rigid() -> Self {
    self.setContentCompressionResistancePriority(.required, for: .horizontal)
    self.setContentHuggingPriority(.required, for: .horizontal)
    return self
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.applyTracking()
  }

  private func applyTracking() {
    guard self.tracking != 0, let font = self.font else { return }
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = self.alignment
    paragraph.lineBreakMode = .byTruncatingTail
    self.effectiveAppearance.performAsCurrentDrawingAppearance {
      self.attributedStringValue = NSAttributedString(
        string: self.stringValue,
        attributes: [
          .font: font,
          .foregroundColor: self.color,
          .kern: self.tracking,
          .paragraphStyle: paragraph,
        ])
    }
  }

  /// A small all-caps column heading.
  static func caption(
    _ text: String,
    color: NSColor = DashboardPalette.subtle,
    alignment: NSTextAlignment = .natural
  ) -> DashboardLabel {
    DashboardLabel(
      text.uppercased(),
      font: DashboardFont.sans(8, .semibold),
      color: color,
      tracking: 0.9,
      alignment: alignment)
  }
}

/// A rounded meter with a fixed track, drawn so it stays crisp at any width.
@MainActor
final class UsageMeter: NSView {
  private let value: Double
  private let color: NSColor

  init(value: Double, color: NSColor) {
    self.value = min(100, max(0, value))
    self.color = color
    super.init(frame: .zero)
    self.wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.needsDisplay = true
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let radius = self.bounds.height / 2
    DashboardPalette.track.setFill()
    NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius).fill()
    guard self.value > 0 else { return }
    var fill = self.bounds
    fill.size.width = max(self.bounds.height, self.bounds.width * self.value / 100)
    self.color.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
  }
}

/// A quiet square icon button, used for the header refresh control.
@MainActor
final class DashboardIconButton: NSButton {
  private let handler: () -> Void

  init(symbol: String, toolTip: String, action: @escaping () -> Void) {
    self.handler = action
    super.init(frame: .zero)
    self.title = ""
    self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
    self.contentTintColor = DashboardPalette.muted
    self.toolTip = toolTip
    self.isBordered = false
    self.wantsLayer = true
    self.target = self
    self.action = #selector(self.performAction)
    self.widthAnchor.constraint(equalToConstant: 30).isActive = true
    self.heightAnchor.constraint(equalToConstant: 30).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    self.layer?.cornerRadius = 10
    self.layer?.cornerCurve = .continuous
    self.layer?.borderWidth = 1
    self.effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = DashboardPalette.card.cgColor
      self.layer?.borderColor = DashboardPalette.border.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.needsDisplay = true
  }

  @objc private func performAction() { self.handler() }
}

/// A borderless label-weight button for footer and inline actions.
@MainActor
final class DashboardTextButton: NSButton {
  private let handler: () -> Void

  init(
    title: String,
    symbol: String? = nil,
    color: NSColor = DashboardPalette.muted,
    action: @escaping () -> Void
  ) {
    self.handler = action
    super.init(frame: .zero)
    self.title = title
    self.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
    self.imagePosition = symbol == nil ? .noImage : .imageLeading
    self.imageHugsTitle = true
    self.font = DashboardFont.sans(10.5, .medium)
    self.contentTintColor = color
    self.isBordered = false
    self.target = self
    self.action = #selector(self.performAction)
  }

  required init?(coder: NSCoder) { nil }
  @objc private func performAction() { self.handler() }
}

/// A filled capsule button used for the single primary action on a card.
@MainActor
final class DashboardPillButton: NSButton {
  private let handler: () -> Void
  private let accent: NSColor

  init(title: String, accent: NSColor, action: @escaping () -> Void) {
    self.handler = action
    self.accent = accent
    super.init(frame: .zero)
    self.title = title
    self.isBordered = false
    self.wantsLayer = true
    self.font = DashboardFont.sans(10, .semibold)
    self.contentTintColor = DashboardPalette.onAccent
    self.target = self
    self.action = #selector(self.performAction)
    self.heightAnchor.constraint(equalToConstant: 24).isActive = true
    self.widthAnchor.constraint(
      equalToConstant: ceil(title.size(withAttributes: [.font: self.font as Any]).width) + 24
    ).isActive = true
    self.applyTitleColor()
  }

  required init?(coder: NSCoder) { nil }

  override var wantsUpdateLayer: Bool { true }

  override func updateLayer() {
    self.layer?.cornerRadius = 12
    self.layer?.cornerCurve = .continuous
    self.effectiveAppearance.performAsCurrentDrawingAppearance {
      self.layer?.backgroundColor = self.accent.cgColor
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.needsDisplay = true
    self.applyTitleColor()
  }

  private func applyTitleColor() {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    self.effectiveAppearance.performAsCurrentDrawingAppearance {
      self.attributedTitle = NSAttributedString(
        string: self.title,
        attributes: [
          .font: self.font as Any,
          .foregroundColor: DashboardPalette.onAccent,
          .paragraphStyle: paragraph,
        ])
    }
  }

  @objc private func performAction() { self.handler() }
}

/// A one-pixel rule that follows the appearance.
@MainActor
final class DashboardRule: DashboardSurface {
  init(width: CGFloat) {
    super.init(fill: DashboardPalette.hairline, radius: 0)
    self.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: width),
      self.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

extension NSStackView {
  static func vertical(
    _ views: [NSView],
    spacing: CGFloat,
    alignment: NSLayoutConstraint.Attribute = .leading
  ) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = alignment
    stack.spacing = spacing
    return stack
  }

  static func horizontal(
    _ views: [NSView],
    spacing: CGFloat,
    alignment: NSLayoutConstraint.Attribute = .centerY
  ) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .horizontal
    stack.alignment = alignment
    stack.spacing = spacing
    return stack
  }
}

extension ProviderID {
  /// Brand accent, darkened in light appearance so it stays legible on ivory.
  var accent: NSColor {
    switch self {
    case .openAI: DashboardPalette.dynamic(light: 0x33_2F_2B, dark: 0xEC_EA_E5)
    case .anthropic: DashboardPalette.dynamic(light: 0xC2_5B_36, dark: 0xD9_77_57)
    case .grok: DashboardPalette.dynamic(light: 0x2C_6B_99, dark: 0x6F_A8_DC)
    }
  }

  var resourceName: String {
    switch self {
    case .openAI: "openai"
    case .anthropic: "anthropic"
    case .grok: "grok"
    }
  }
}
