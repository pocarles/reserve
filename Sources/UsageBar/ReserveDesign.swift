import AppKit
import UsageBarCore

/// The Reserve design system.
///
/// One vocabulary for both surfaces: a spacing scale, a type scale, restrained
/// radii, hairline separators, and a two-step surface hierarchy. Sections are
/// distinguished by fill and spacing rather than by borders, so the interface
/// reads as a calm document instead of a stack of boxes.
enum ReserveSpace {
  static let xs: CGFloat = 4
  static let sm: CGFloat = 8
  static let md: CGFloat = 12
  static let lg: CGFloat = 16
  static let xl: CGFloat = 22
  static let xxl: CGFloat = 30
}

enum ReserveRadius {
  static let chip: CGFloat = 7
  static let control: CGFloat = 10
  static let section: CGFloat = 16
  static let logo: CGFloat = 11
}

/// Absolute point sizes. The dashboard and Settings share one scale so the two
/// surfaces feel like one product; no size here is smaller than the size it
/// replaces.
enum ReserveType {
  static let wordmark: CGFloat = 21
  static let pageTitle: CGFloat = 20

  // Dashboard
  static let remaining: CGFloat = 21
  static let percent: CGFloat = 21
  static let summaryValue: CGFloat = 18
  static let providerName: CGFloat = 15
  static let cardValue: CGFloat = 14
  static let body: CGFloat = 13
  static let metadata: CGFloat = 12
  static let secondary: CGFloat = 12
  static let support: CGFloat = 11
  static let micro: CGFloat = 9.5

  // Settings (the 25% enlargement is baked into these values)
  static let pageSubtitle: CGFloat = 13.5
  static let sectionTitle: CGFloat = 15
  static let sectionSubtitle: CGFloat = 11.5
  static let rowTitle: CGFloat = 13.5
  static let rowDetail: CGFloat = 11.5
  static let control: CGFloat = 13.5
  static let settingsMicro: CGFloat = 11
  static let aboutName: CGFloat = 24
}

enum ReserveFont {
  static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .systemFont(ofSize: size, weight: weight)
  }

  static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    .monospacedDigitSystemFont(ofSize: size, weight: weight)
  }

  /// New York. Reserved for surface titles, which is where the editorial voice
  /// belongs; every number and control stays in the system sans.
  static func display(_ size: CGFloat, _ weight: NSFont.Weight = .semibold) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    guard let descriptor = base.fontDescriptor.withDesign(.serif) else { return base }
    return NSFont(descriptor: descriptor, size: size) ?? base
  }
}

/// Adaptive accent tokens shape the surfaces while semantic usage colours stay
/// fixed. This keeps theme personality independent from pace meaning.
@MainActor
enum ReserveColor {
  static var background: NSColor { ReserveAppearance.palette.windowBase }
  static var section: NSColor { ReserveAppearance.palette.cardSurface }
  static var elevated: NSColor { ReserveAppearance.palette.elevatedSurface }
  static var track: NSColor { ReserveAppearance.palette.progressTrack }
  static var text: NSColor { .labelColor }
  static var muted: NSColor { .secondaryLabelColor }
  static var subtle: NSColor { .tertiaryLabelColor }

  static var accent: NSColor { ReserveAppearance.accent }
  static var hover: NSColor { ReserveAppearance.palette.hoverFill }
  static var selected: NSColor { ReserveAppearance.palette.selectedFill }
  static var chartPrimary: NSColor { ReserveAppearance.palette.chartPrimary }
  static var chartSecondary: NSColor { ReserveAppearance.palette.chartSecondary }

  static var reserve: NSColor { .systemGreen }
  static var onPace: NSColor { .systemBlue }
  static var deficit: NSColor { .systemOrange }
  static var success: NSColor { self.reserve }
  static var warning: NSColor { .systemOrange }
  /// Red is reserved for a provider-reported service outage, never quota use.
  static var danger: NSColor { .systemRed }

  static var hairline: NSColor { ReserveAppearance.palette.border }
  static var strongHairline: NSColor { ReserveAppearance.palette.border }

  /// Brand colour for the provider mark, adapted so it stays legible in both
  /// appearances. It belongs on the logo, not on the data.
  static func providerAccent(_ provider: ProviderID) -> NSColor {
    switch provider {
    case .openAI:
      return Self.dynamic(light: 0x10_10_0F, dark: 0xED_ED_EA)
    case .anthropic:
      return Self.dynamic(light: 0xC2_5B_36, dark: 0xE8_70_45)
    case .grok:
      return Self.dynamic(light: 0x1F_63_92, dark: 0x6B_AE_EE)
    }
  }

  private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      let value = isDark ? dark : light
      return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
        green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255,
        alpha: 1)
    }
  }
}

extension NSView {
  /// Resolves an adaptive colour in *this view's* appearance.
  ///
  /// `NSColor.cgColor` resolves against the current drawing appearance, which
  /// during view construction is whatever the thread happens to be set to and
  /// inside `viewDidChangeEffectiveAppearance` is still the old one. Assigning
  /// `someDynamicColor.cgColor` to a layer therefore freezes the wrong variant,
  /// which is why layer-backed surfaces used to keep their previous appearance.
  @MainActor
  func resolvedCGColor(_ color: NSColor) -> CGColor {
    var resolved = color.cgColor
    self.effectiveAppearance.performAsCurrentDrawingAppearance {
      resolved = color.cgColor
    }
    return resolved
  }
}

/// A non-editable label with optional letter spacing.
@MainActor
final class ReserveLabel: NSTextField {
  init(
    _ text: String,
    font: NSFont,
    color: NSColor,
    tracking: CGFloat = 0,
    alignment: NSTextAlignment = .natural
  ) {
    super.init(frame: .zero)
    self.isEditable = false
    self.isSelectable = false
    self.isBezeled = false
    self.drawsBackground = false
    self.font = font
    self.textColor = color
    self.alignment = alignment
    self.lineBreakMode = .byTruncatingTail
    self.maximumNumberOfLines = 1
    self.stringValue = text
    self.cell?.usesSingleLineMode = true
    if tracking != 0 {
      let paragraph = NSMutableParagraphStyle()
      paragraph.alignment = alignment
      paragraph.lineBreakMode = .byTruncatingTail
      self.attributedStringValue = NSAttributedString(
        string: text,
        attributes: [
          .font: font, .foregroundColor: color, .kern: tracking, .paragraphStyle: paragraph,
        ])
    }
  }

  required init?(coder: NSCoder) { nil }

  /// A tracked micro-caps column heading. The tracking is what makes small
  /// uppercase text legible rather than merely small.
  static func micro(
    _ text: String,
    size: CGFloat = ReserveType.micro,
    color: NSColor = ReserveColor.subtle,
    alignment: NSTextAlignment = .natural
  ) -> ReserveLabel {
    ReserveLabel(
      text, font: ReserveFont.sans(size, .semibold), color: color, tracking: 0.7,
      alignment: alignment)
  }

  @discardableResult
  func width(_ value: CGFloat) -> Self {
    self.translatesAutoresizingMaskIntoConstraints = false
    self.widthAnchor.constraint(equalToConstant: value).isActive = true
    self.setContentCompressionResistancePriority(.required, for: .horizontal)
    self.setContentHuggingPriority(.required, for: .horizontal)
    return self
  }

  /// Marks this label as the one that should yield when a row runs short.
  @discardableResult
  func flexible() -> Self {
    self.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return self
  }

  @discardableResult
  func rigid() -> Self {
    self.setContentCompressionResistancePriority(.required, for: .horizontal)
    self.setContentHuggingPriority(.required, for: .horizontal)
    return self
  }

  /// Pins the label to the width the text actually draws at, measured from the
  /// attributed string. Both `intrinsicContentSize` and `sizeToFit()` ignore
  /// kerning, which silently clips the trailing characters of tracked text.
  @discardableResult
  func fitted(extra: CGFloat = 2) -> Self {
    self.width(ceil(self.attributedStringValue.size().width) + extra)
  }
}

/// A one-pixel rule.
@MainActor
final class ReserveHairline: NSView {
  private let color: NSColor

  init(width: CGFloat? = nil, color: NSColor? = nil) {
    self.color = color ?? ReserveColor.hairline
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(self.color)
    self.translatesAutoresizingMaskIntoConstraints = false
    self.heightAnchor.constraint(equalToConstant: 1).isActive = true
    if let width { self.widthAnchor.constraint(equalToConstant: width).isActive = true }
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(self.color)
  }
}

/// A soft surface used for grouped content. It carries fill and radius only —
/// no border — so grouping is felt rather than drawn.
@MainActor
class ReserveSurface: NSView {
  private let fill: NSColor?
  private let fillAlpha: CGFloat
  private let radius: CGFloat

  init(fill: NSColor?, fillAlpha: CGFloat = 1, radius: CGFloat = 0) {
    self.fill = fill
    self.fillAlpha = fillAlpha
    self.radius = radius
    super.init(frame: .zero)
    self.wantsLayer = true
    self.layer?.cornerRadius = radius
    self.layer?.cornerCurve = .continuous
    self.applyFill()
  }

  required init?(coder: NSCoder) { nil }

  private func applyFill() {
    self.layer?.backgroundColor = self.fill.map {
      self.resolvedCGColor($0.withAlphaComponent(self.fillAlpha))
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.applyFill()
  }
}

/// The allowance meter: a rounded track, a fill, and a pace marker showing how
/// far through the window the clock has travelled. Usage past the marker is
/// the deficit the pace projection describes.
@MainActor
final class ReserveMeter: NSView {
  private let value: Double
  private let pacePercent: Double?
  private let projectedPercent: Double?
  private let color: NSColor

  init(
    value: Double,
    pacePercent: Double?,
    projectedPercent: Double? = nil,
    label: String? = nil,
    color: NSColor
  ) {
    self.value = min(100, max(0, value))
    self.pacePercent = pacePercent.map { min(100, max(0, $0)) }
    self.projectedPercent = projectedPercent.map { min(100, max(0, $0)) }
    self.color = color
    super.init(frame: .zero)
    self.wantsLayer = true
    self.setAccessibilityRole(.progressIndicator)
    self.setAccessibilityLabel(label ?? "Allowance used")
    self.setAccessibilityValue(
      "\(Int(self.value.rounded())) percent used, "
        + "\(Int((100 - self.value).rounded())) percent left")
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let radius = self.bounds.height / 2
    ReserveColor.track.setFill()
    NSBezierPath(roundedRect: self.bounds, xRadius: radius, yRadius: radius).fill()

    // Ghost extension: where usage is projected to land by the reset.
    if let projectedPercent, projectedPercent > self.value {
      var ghost = self.bounds
      ghost.size.width = max(self.bounds.height, self.bounds.width * projectedPercent / 100)
      self.color.withAlphaComponent(0.28).setFill()
      NSBezierPath(roundedRect: ghost, xRadius: radius, yRadius: radius).fill()
    }

    if self.value > 0 {
      var fill = self.bounds
      fill.size.width = max(self.bounds.height, self.bounds.width * self.value / 100)
      self.color.setFill()
      NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
    }

    guard let pacePercent, pacePercent > 1, pacePercent < 99 else { return }
    let x = (self.bounds.width * pacePercent / 100).rounded()
    // Punch a gap around the marker so it stays visible on top of the fill.
    ReserveColor.background.setFill()
    NSRect(x: x - 1.5, y: self.bounds.minY - 1, width: 3, height: self.bounds.height + 2).fill()
    ReserveColor.text.withAlphaComponent(0.55).setFill()
    NSRect(x: x - 0.5, y: self.bounds.minY - 1, width: 1, height: self.bounds.height + 2).fill()
  }
}

/// Daily usage as bars: length encodes the value, which people read far more
/// accurately than area or colour. No axes, no gridlines — the label beside it
/// carries the magnitude.
@MainActor
final class ReserveSparkline: NSView {
  private let series: [DailyUsage]
  private let color: NSColor
  private let peak: Int64

  init(series: [DailyUsage], color: NSColor) {
    self.series = series
    self.color = color
    self.peak = series.map(\.tokens).max() ?? 0
    super.init(frame: .zero)
    self.wantsLayer = true
    self.setAccessibilityRole(.image)
    self.setAccessibilityLabel(Self.spoken(series: series))
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !self.series.isEmpty else { return }
    // A baseline so quiet days still read as days rather than as absence.
    ReserveColor.track.setFill()
    NSRect(x: 0, y: 0, width: self.bounds.width, height: 1).fill()
    guard self.peak > 0 else { return }

    let count = CGFloat(self.series.count)
    let gap: CGFloat = count > 40 ? 1 : 2
    let barWidth = max(1, (self.bounds.width - gap * (count - 1)) / count)
    let usable = max(1, self.bounds.height - 1)
    for (offset, day) in self.series.enumerated() {
      guard day.tokens > 0 else { continue }
      let fraction = CGFloat(Double(day.tokens) / Double(self.peak))
      let height = max(1.5, usable * fraction)
      let x = CGFloat(offset) * (barWidth + gap)
      // The most recent day is the one being asked about, so it stays solid.
      let isLatest = offset == self.series.count - 1
      self.color.withAlphaComponent(isLatest ? 1 : 0.55).setFill()
      NSBezierPath(
        roundedRect: NSRect(x: x, y: 1, width: barWidth, height: height),
        xRadius: min(1.5, barWidth / 2), yRadius: min(1.5, barWidth / 2)
      ).fill()
    }
  }

  private static func spoken(series: [DailyUsage]) -> String {
    guard let peak = series.max(by: { $0.tokens < $1.tokens }), peak.tokens > 0 else {
      return "Daily usage chart, no activity recorded"
    }
    let active = series.filter { $0.tokens > 0 }.count
    return
      "Daily usage for \(series.count) days, active on \(active), busiest day \(peak.day)"
  }
}

/// A borderless action with a comfortable hit target. Premium here means
/// generous padding and a quiet surface, not a heavy outline.
@MainActor
final class ReserveTextButton: NSButton {
  private let handler: () -> Void
  private var filledColor: NSColor?

  init(
    title: String,
    symbol: String? = nil,
    size: CGFloat = ReserveType.body,
    color: NSColor = ReserveColor.muted,
    filled: Bool = false,
    minimumWidth: CGFloat = 72,
    height: CGFloat = 32,
    action: @escaping () -> Void
  ) {
    self.handler = action
    super.init(frame: .zero)
    self.title = title
    self.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size - 1, weight: .medium)
    self.imagePosition = symbol == nil ? .noImage : .imageLeading
    self.imageHugsTitle = true
    self.font = ReserveFont.sans(size, .medium)
    self.contentTintColor = color
    self.isBordered = false
    self.wantsLayer = true
    self.layer?.cornerRadius = ReserveRadius.control
    self.layer?.cornerCurve = .continuous
    self.filledColor = filled ? color.withAlphaComponent(0.14) : nil
    if let filledColor = self.filledColor {
      self.layer?.backgroundColor = self.resolvedCGColor(filledColor)
    }
    self.target = self
    self.action = #selector(self.performAction)
    let titleWidth = (title as NSString).size(withAttributes: [.font: self.font as Any]).width
    let padding: CGFloat = symbol == nil ? 30 : 48
    self.widthAnchor.constraint(
      greaterThanOrEqualToConstant: max(minimumWidth, ceil(titleWidth + padding))
    ).isActive = true
    self.heightAnchor.constraint(equalToConstant: height).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    if let filledColor { self.layer?.backgroundColor = self.resolvedCGColor(filledColor) }
  }

  @objc private func performAction() { self.handler() }
}

/// Motion is opt-in, brief, and never decorative. Reduce Motion switches every
/// transition off rather than substituting a different effect.
@MainActor
enum ReserveMotion {
  static var isReduced: Bool {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
  }

  /// A duration that collapses to zero when the system asks for less motion.
  static func duration(_ value: TimeInterval) -> TimeInterval {
    self.isReduced ? 0 : value
  }

  static func run(_ value: TimeInterval, _ body: (NSAnimationContext) -> Void) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = self.duration(value)
      context.allowsImplicitAnimation = !self.isReduced
      context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
      body(context)
    }
  }
}

/// A square icon action, sized for a comfortable pointer target.
@MainActor
final class ReserveIconButton: NSButton {
  private let handler: () -> Void

  init(
    symbol: String,
    toolTip: String,
    diameter: CGFloat = 38,
    spinningSince phase: TimeInterval? = nil,
    action: @escaping () -> Void
  ) {
    self.handler = action
    super.init(frame: .zero)
    self.title = ""
    self.image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
    self.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
    // A key action carries the accent; secondary actions stay neutral.
    self.contentTintColor = ReserveColor.accent
    self.toolTip = toolTip
    self.setAccessibilityLabel(toolTip)
    self.isBordered = false
    self.wantsLayer = true
    self.layer?.backgroundColor = self.resolvedCGColor(
      ReserveColor.elevated.withAlphaComponent(0.7))
    self.layer?.cornerRadius = ReserveRadius.control + 2
    self.layer?.cornerCurve = .continuous
    self.target = self
    self.action = #selector(self.performAction)
    self.widthAnchor.constraint(equalToConstant: diameter).isActive = true
    self.heightAnchor.constraint(equalToConstant: diameter).isActive = true
    if let phase { self.spin(phase: phase) }
  }

  /// Turns while a refresh is in flight. The phase is passed in so the rotation
  /// stays continuous even though the dashboard rebuilds during a refresh.
  private func spin(phase: TimeInterval) {
    guard !ReserveMotion.isReduced else { return }
    let duration: TimeInterval = 1.1
    let rotation = CABasicAnimation(keyPath: "transform.rotation.z")
    rotation.fromValue = 0
    rotation.toValue = -Double.pi * 2
    rotation.duration = duration
    rotation.repeatCount = .greatestFiniteMagnitude
    rotation.isRemovedOnCompletion = false
    rotation.timeOffset = phase.truncatingRemainder(dividingBy: duration)
    self.wantsLayer = true
    // Rotate about the middle rather than the corner.
    self.layer?.anchorPoint = NSPoint(x: 0.5, y: 0.5)
    self.layer?.frame = self.layer?.frame ?? .zero
    self.layer?.add(rotation, forKey: "reserve.refresh.spin")
  }

  var isSpinning: Bool { self.layer?.animation(forKey: "reserve.refresh.spin") != nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    self.layer?.backgroundColor = self.resolvedCGColor(
      ReserveColor.elevated.withAlphaComponent(0.7))
    self.contentTintColor = ReserveColor.accent
  }

  required init?(coder: NSCoder) { nil }

  override func resetCursorRects() {
    self.addCursorRect(self.bounds, cursor: .pointingHand)
  }

  @objc private func performAction() { self.handler() }
}

/// The provider mark on a tinted plate.
@MainActor
final class ReserveProviderLogo: ReserveSurface {
  init(provider: ProviderID, size: CGFloat = 34, glyph: CGFloat = 18) {
    let accent = ReserveColor.providerAccent(provider)
    super.init(fill: accent, fillAlpha: 0.14, radius: size <= 26 ? 8 : ReserveRadius.logo)
    let image = NSImageView(image: ProviderArtwork.image(for: provider))
    image.contentTintColor = accent
    image.imageScaling = .scaleProportionallyUpOrDown
    // The mark repeats the row's own label, so it stays silent.
    image.setAccessibilityElement(false)
    image.setAccessibilityLabel("")
    self.setAccessibilityElement(false)
    image.translatesAutoresizingMaskIntoConstraints = false
    self.addSubview(image)
    NSLayoutConstraint.activate([
      self.widthAnchor.constraint(equalToConstant: size),
      self.heightAnchor.constraint(equalToConstant: size),
      image.centerXAnchor.constraint(equalTo: self.centerXAnchor),
      image.centerYAnchor.constraint(equalTo: self.centerYAnchor),
      image.widthAnchor.constraint(equalToConstant: glyph),
      image.heightAnchor.constraint(equalToConstant: glyph),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

extension NSStackView {
  @MainActor
  static func column(
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

  @MainActor
  static func row(
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

  @MainActor
  static func spacer() -> NSView {
    let view = NSView()
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }
}
