import AppKit
import ReserveCore

/// Preview of the sanitized usage card. Copy and Save both use the same model.
/// The panel never screenshots the dashboard and never uploads anything.
@MainActor
final class UsageSharePreviewController: NSWindowController, NSWindowDelegate {
  private let model: UsageShareModel
  private let pasteboard: NSPasteboard
  private let savePanelFactory: () -> NSSavePanel
  private let statusLabel = NSTextField(labelWithString: "")

  init(
    model: UsageShareModel,
    pasteboard: NSPasteboard = .general,
    savePanelFactory: @escaping () -> NSSavePanel = { NSSavePanel() }
  ) {
    self.model = model
    self.pasteboard = pasteboard
    self.savePanelFactory = savePanelFactory
    let height = UsageShareCardView.measuredHeight(for: model) + 124
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 704, height: max(480, height)),
      styleMask: [.titled, .closable],
      backing: .buffered,
      defer: false)
    window.title = "Share usage"
    window.isReleasedWhenClosed = false
    super.init(window: window)
    window.delegate = self
    window.contentView = self.makeContent()
    if let content = window.contentView {
      content.layoutSubtreeIfNeeded()
      let fitted = content.fittingSize
      let width = max(704, ceil(fitted.width))
      let contentHeight = max(height, ceil(fitted.height))
      window.setContentSize(NSSize(width: width, height: contentHeight))
    }
  }

  required init?(coder: NSCoder) { nil }

  func show() {
    self.window?.center()
    self.window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }

  /// Copies onto the injected pasteboard. Automation passes a private board
  /// so the system clipboard is left alone.
  func copyForTesting() -> Bool {
    self.copyText()
    return self.pasteboard.string(forType: .string) == self.model.plainText()
  }

  /// Writes the card PNG without opening a save panel.
  func pngDataForTesting() throws -> Data {
    try UsageShareCardView.pngData(for: self.model, appearance: self.window?.effectiveAppearance)
  }

  func renderOpaque(to url: URL, appearance: NSAppearance) throws {
    guard let view = self.window?.contentView else { throw CocoaError(.fileWriteUnknown) }
    self.window?.appearance = appearance
    view.appearance = appearance
    view.layoutSubtreeIfNeeded()
    let bounds = view.bounds
    guard bounds.width > 1, bounds.height > 1 else { throw CocoaError(.fileWriteUnknown) }
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(bounds.width),
      pixelsHigh: Int(bounds.height),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
    else { throw CocoaError(.fileWriteUnknown) }
    rep.size = bounds.size
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current = context
    NSColor.windowBackgroundColor.setFill()
    bounds.fill()
    view.displayIgnoringOpacity(bounds, in: context ?? NSGraphicsContext.current!)
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
  }

  private func makeContent() -> NSView {
    let card = UsageShareCardView(model: self.model)
    card.identifier = NSUserInterfaceItemIdentifier("share-card")
    let copy = NSButton(title: "Copy text", target: self, action: #selector(self.copyText))
    copy.identifier = NSUserInterfaceItemIdentifier("share-copy")
    copy.bezelStyle = .rounded
    copy.controlSize = .large
    copy.setAccessibilityLabel("Copy usage card text")
    let save = NSButton(title: "Save image", target: self, action: #selector(self.saveImage))
    save.identifier = NSUserInterfaceItemIdentifier("share-save")
    save.bezelStyle = .rounded
    save.controlSize = .large
    save.keyEquivalent = "\r"
    save.setAccessibilityLabel("Save usage card image")
    self.statusLabel.font = .systemFont(ofSize: 11)
    self.statusLabel.textColor = .secondaryLabelColor
    self.statusLabel.identifier = NSUserInterfaceItemIdentifier("share-status")
    self.statusLabel.stringValue = "Private by default. Account and organization details are excluded."
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let buttons = NSStackView(views: [copy, spacer, save])
    buttons.orientation = .horizontal
    buttons.spacing = 10
    buttons.widthAnchor.constraint(equalToConstant: UsageShareCardView.cardWidth).isActive = true
    let stack = NSStackView(views: [card, buttons, self.statusLabel])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 14
    stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 20, right: 32)
    stack.translatesAutoresizingMaskIntoConstraints = false
    let root = NSView()
    root.identifier = NSUserInterfaceItemIdentifier("share-preview")
    root.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      stack.topAnchor.constraint(equalTo: root.topAnchor),
      stack.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    return root
  }

  @objc private func copyText() {
    let text = self.model.plainText()
    self.pasteboard.clearContents()
    let wrote = self.pasteboard.setString(text, forType: .string)
    self.statusLabel.stringValue = wrote ? "Copied." : "Could not copy text."
    self.statusLabel.setAccessibilityLabel(self.statusLabel.stringValue)
  }

  @objc private func saveImage() {
    let panel = self.savePanelFactory()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "Reserve usage.png"
    panel.canCreateDirectories = true
    panel.begin { [weak self] response in
      guard let self else { return }
      guard response == .OK, let url = panel.url else {
        self.statusLabel.stringValue = "Save cancelled."
        return
      }
      do {
        try UsageShareCardView.pngData(
          for: self.model,
          appearance: self.window?.effectiveAppearance
        ).write(to: url, options: .atomic)
        self.statusLabel.stringValue = "Saved."
      } catch {
        self.statusLabel.stringValue = "Could not save image."
      }
    }
  }
}

/// Draws the share card from the safe model. The image has its own hierarchy
/// and never screenshots the dashboard or preview controls.
@MainActor
final class UsageShareCardView: NSView {
  private let model: UsageShareModel

  static let cardWidth: CGFloat = 640

  init(model: UsageShareModel) {
    self.model = model
    let height = Self.measuredHeight(for: model)
    super.init(frame: NSRect(x: 0, y: 0, width: Self.cardWidth, height: height))
    self.setAccessibilityElement(true)
    self.setAccessibilityLabel(model.plainText())
    self.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
    self.heightAnchor.constraint(equalToConstant: height).isActive = true
  }

  /// Every variable-height string is measured with the same fonts and widths
  /// used by the painter, including the six-window worst case.
  static func measuredHeight(for model: UsageShareModel) -> CGFloat {
    ShareCardLayout(model: model).height
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    ShareCardPainter.draw(self.model, in: self.bounds)
  }

  static func pngData(
    for model: UsageShareModel,
    appearance: NSAppearance? = nil
  ) throws -> Data {
    let bounds = NSRect(
      x: 0, y: 0,
      width: Self.cardWidth,
      height: Self.measuredHeight(for: model))
    let scale: CGFloat = 2
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: Int(ceil(bounds.width * scale)),
      pixelsHigh: Int(ceil(bounds.height * scale)),
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0)
    else {
      throw CocoaError(.fileWriteUnknown)
    }
    rep.size = bounds.size
    guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
      throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    if let appearance {
      appearance.performAsCurrentDrawingAppearance {
        ShareCardPainter.draw(model, in: bounds)
      }
    } else {
      ShareCardPainter.draw(model, in: bounds)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let data = rep.representation(using: .png, properties: [:]) else {
      throw CocoaError(.fileWriteUnknown)
    }
    return data
  }
}

@MainActor
private struct ShareCardLayout {
  static let inset = NSEdgeInsets(top: 28, left: 32, bottom: 24, right: 32)
  static let headerHeight: CGFloat = 38
  static let heroGap: CGFloat = 18
  static let secondaryGap: CGFloat = 10
  static let sectionGap: CGFloat = 20
  static let footerGap: CGFloat = 14
  static let heroMeterHeight: CGFloat = 12
  static let rowMeterHeight: CGFloat = 7

  let contentWidth: CGFloat
  let heroHeight: CGFloat
  let secondaryHeights: [CGFloat]
  let statsHeight: CGFloat
  let footerHeight: CGFloat
  let height: CGFloat

  init(model: UsageShareModel) {
    let contentWidth = UsageShareCardView.cardWidth - Self.inset.left - Self.inset.right
    self.contentWidth = contentWidth
    if let hero = model.windows.first {
      let valueHeight = Self.textHeight(
        ShareCardFormat.remaining(hero.remainingPercent),
        font: .systemFont(ofSize: 56, weight: .bold),
        width: contentWidth)
      let captionHeight = Self.textHeight(
        ShareCardFormat.heroCaption(hero),
        font: .systemFont(ofSize: 13, weight: .medium),
        width: contentWidth)
      self.heroHeight = valueHeight + 4 + captionHeight + 14 + Self.heroMeterHeight
    } else {
      self.heroHeight = 90
    }

    self.secondaryHeights = model.windows.dropFirst().map { window in
      let detailHeight = Self.textHeight(
        ShareCardFormat.reset(window.resetsAt) ?? "Reset unavailable",
        font: .systemFont(ofSize: 11),
        width: contentWidth - 92)
      return 18 + 2 + detailHeight + 8 + Self.rowMeterHeight
    }

    let columnWidth = (contentWidth - 14) / 2
    let tokenHeight = Self.statHeight(
      value: ShareCardFormat.tokens(model.tokensUsed),
      label: "Tokens · \(model.tokenPeriodLabel)",
      note: nil,
      width: columnWidth)
    let costHeight = Self.statHeight(
      value: ShareCardFormat.money(model.estimatedAPIEquivalentUSD),
      label: "Estimated API equivalent",
      note: "Not an actual charge",
      width: columnWidth)
    self.statsHeight = max(tokenHeight, costHeight)
    self.footerHeight = Self.textHeight(
      ShareCardFormat.footer(model),
      font: .systemFont(ofSize: 11),
      width: contentWidth)

    let secondaryTotal = self.secondaryHeights.reduce(0, +)
      + CGFloat(max(0, self.secondaryHeights.count - 1)) * Self.secondaryGap
    let secondaryLead: CGFloat = self.secondaryHeights.isEmpty ? 0 : 16
    let headerSection = Self.inset.top + Self.headerHeight + Self.heroGap
    let quotaSection = self.heroHeight + secondaryLead + secondaryTotal
    let statsSection = Self.sectionGap + self.statsHeight
    let footerSection = Self.footerGap + self.footerHeight + Self.inset.bottom
    self.height = ceil(headerSection + quotaSection + statsSection + footerSection)
  }

  static func textHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byWordWrapping
    let rect = (text as NSString).boundingRect(
      with: NSSize(width: max(40, width), height: 10_000),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [.font: font, .paragraphStyle: paragraph])
    return max(ceil(rect.height), ceil(font.ascender - font.descender + font.leading))
  }

  private static func statHeight(
    value: String,
    label: String,
    note: String?,
    width: CGFloat
  ) -> CGFloat {
    let innerWidth = width - 28
    var height: CGFloat = 14
    height += self.textHeight(
      value, font: .systemFont(ofSize: 24, weight: .semibold), width: innerWidth)
    height += 5
    height += self.textHeight(
      label, font: .systemFont(ofSize: 11, weight: .medium), width: innerWidth)
    if let note {
      height += 4
      height += self.textHeight(note, font: .systemFont(ofSize: 11), width: innerWidth)
    }
    return ceil(height + 14)
  }
}

private enum ShareCardFormat {
  static func remaining(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "Quota unavailable" }
    return "\(Int(min(100, max(0, value)).rounded()))% left"
  }

  static func heroCaption(_ window: UsageShareWindow) -> String {
    guard let reset = self.reset(window.resetsAt) else { return window.label }
    return "\(window.label) · \(reset)"
  }

  static func reset(_ date: Date?) -> String? {
    guard let date else { return nil }
    return "Resets \(self.moment(date))"
  }

  static func tokens(_ value: Int64?) -> String {
    guard let value else { return "Unavailable" }
    let number = Double(value)
    if value >= 1_000_000_000 { return self.compact(number / 1_000_000_000, suffix: "B") }
    if value >= 1_000_000 { return self.compact(number / 1_000_000, suffix: "M") }
    if value >= 1_000 { return self.compact(number / 1_000, suffix: "K") }
    return String(value)
  }

  static func money(_ value: Double?) -> String {
    guard let value, value.isFinite else { return "Unavailable" }
    return String(format: "$%.2f", max(0, value))
  }

  static func footer(_ model: UsageShareModel) -> String {
    var parts = ["Shared from Reserve"]
    if model.windows.isEmpty {
      parts.append("Quota unavailable")
    } else if let checked = model.quotaCheckedAt {
      parts.append("Quota as of \(self.moment(checked))")
    } else {
      parts.append("Quota freshness unknown")
    }
    if model.tokensUsed != nil {
      if let checked = model.tokensCheckedAt {
        parts.append("Tokens as of \(self.moment(checked))")
      } else {
        parts.append("Token freshness unknown")
      }
    }
    return parts.joined(separator: " · ")
  }

  static func moment(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func compact(_ value: Double, suffix: String) -> String {
    let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
    return String(format: "%.*f", digits, value) + suffix
  }
}

@MainActor
private enum ShareCardPainter {
  static func draw(_ model: UsageShareModel, in bounds: NSRect) {
    let layout = ShareCardLayout(model: model)
    let cardBounds = NSRect(
      x: bounds.minX, y: bounds.minY,
      width: UsageShareCardView.cardWidth,
      height: layout.height)
    self.drawChrome(in: cardBounds)

    let left = cardBounds.minX + ShareCardLayout.inset.left
    let width = layout.contentWidth
    var top = cardBounds.maxY - ShareCardLayout.inset.top
    self.drawHeader(model, top: top, left: left, width: width)
    top -= ShareCardLayout.headerHeight + ShareCardLayout.heroGap

    if let hero = model.windows.first {
      self.drawHero(hero, top: top, left: left, width: width, height: layout.heroHeight)
    } else {
      self.drawEmptyQuota(top: top, left: left, width: width, height: layout.heroHeight)
    }
    top -= layout.heroHeight

    if !layout.secondaryHeights.isEmpty {
      top -= 16
      for (index, window) in model.windows.dropFirst().enumerated() {
        let height = layout.secondaryHeights[index]
        self.drawSecondary(window, top: top, left: left, width: width, height: height)
        top -= height + ShareCardLayout.secondaryGap
      }
      top += ShareCardLayout.secondaryGap
    }

    top -= ShareCardLayout.sectionGap
    self.drawStats(model, top: top, left: left, width: width, height: layout.statsHeight)
    top -= layout.statsHeight + ShareCardLayout.footerGap
    self.drawText(
      ShareCardFormat.footer(model),
      in: self.rect(top: top, left: left, width: width, height: layout.footerHeight),
      font: .systemFont(ofSize: 11),
      color: self.quiet)
  }

  private static func drawChrome(in bounds: NSRect) {
    self.background.setFill()
    let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 22, yRadius: 22)
    path.fill()
    self.border.setStroke()
    path.lineWidth = 1
    path.stroke()
  }

  private static func drawHeader(
    _ model: UsageShareModel,
    top: CGFloat,
    left: CGFloat,
    width: CGFloat
  ) {
    let mark = self.rect(top: top, left: left, width: 30, height: 30)
    self.accent.setFill()
    NSBezierPath(roundedRect: mark, xRadius: 9, yRadius: 9).fill()
    self.drawText(
      "R", in: mark.insetBy(dx: 0, dy: 5),
      font: .systemFont(ofSize: 14, weight: .bold),
      color: .white,
      alignment: .center)
    self.drawText(
      "Reserve",
      in: self.rect(top: top - 2, left: left + 40, width: 100, height: 20),
      font: .systemFont(ofSize: 14, weight: .semibold),
      color: self.primary)

    let provider = [model.providerName, model.planName].compactMap { $0 }.joined(separator: " · ")
    self.drawText(
      provider,
      in: self.rect(top: top - 1, left: left + 150, width: width - 150, height: 24),
      font: .systemFont(ofSize: 15, weight: .semibold),
      color: self.secondary,
      alignment: .right,
      lineBreak: .byTruncatingTail)
  }

  private static func drawHero(
    _ window: UsageShareWindow,
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) {
    let value = ShareCardFormat.remaining(window.remainingPercent)
    let valueFont = NSFont.systemFont(ofSize: 56, weight: .bold)
    let valueHeight = ShareCardLayout.textHeight(value, font: valueFont, width: width)
    self.drawText(
      value,
      in: self.rect(top: top, left: left, width: width, height: valueHeight),
      font: valueFont,
      color: self.primary)

    let caption = ShareCardFormat.heroCaption(window)
    let captionFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    let captionHeight = ShareCardLayout.textHeight(caption, font: captionFont, width: width)
    let captionTop = top - valueHeight - 4
    self.drawText(
      caption,
      in: self.rect(top: captionTop, left: left, width: width, height: captionHeight),
      font: captionFont,
      color: self.secondary)

    let meterTop = top - height + ShareCardLayout.heroMeterHeight
    self.drawMeter(
      window.remainingPercent,
      in: self.rect(
        top: meterTop,
        left: left,
        width: width,
        height: ShareCardLayout.heroMeterHeight))
  }

  private static func drawEmptyQuota(
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) {
    let box = self.rect(top: top, left: left, width: width, height: height)
    self.well.setFill()
    NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
    self.drawText(
      "Quota unavailable",
      in: box.insetBy(dx: 18, dy: 31),
      font: .systemFont(ofSize: 22, weight: .semibold),
      color: self.primary)
  }

  private static func drawSecondary(
    _ window: UsageShareWindow,
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) {
    self.drawText(
      window.label,
      in: self.rect(top: top, left: left, width: width - 112, height: 18),
      font: .systemFont(ofSize: 13, weight: .semibold),
      color: self.primary,
      lineBreak: .byTruncatingTail)
    self.drawText(
      ShareCardFormat.remaining(window.remainingPercent),
      in: self.rect(top: top, left: left + width - 106, width: 106, height: 18),
      font: .systemFont(ofSize: 13, weight: .semibold),
      color: self.primary,
      alignment: .right)

    let detail = ShareCardFormat.reset(window.resetsAt) ?? "Reset unavailable"
    let detailFont = NSFont.systemFont(ofSize: 11)
    let detailHeight = ShareCardLayout.textHeight(detail, font: detailFont, width: width - 92)
    self.drawText(
      detail,
      in: self.rect(top: top - 20, left: left, width: width - 92, height: detailHeight),
      font: detailFont,
      color: self.secondary)

    let meterTop = top - height + ShareCardLayout.rowMeterHeight
    self.drawMeter(
      window.remainingPercent,
      in: self.rect(
        top: meterTop,
        left: left,
        width: width,
        height: ShareCardLayout.rowMeterHeight))
  }

  private static func drawStats(
    _ model: UsageShareModel,
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) {
    let gap: CGFloat = 14
    let column = (width - gap) / 2
    self.drawStat(
      value: ShareCardFormat.tokens(model.tokensUsed),
      label: "Tokens · \(model.tokenPeriodLabel)",
      note: nil,
      top: top, left: left, width: column, height: height)
    self.drawStat(
      value: ShareCardFormat.money(model.estimatedAPIEquivalentUSD),
      label: "Estimated API equivalent",
      note: "Not an actual charge",
      top: top, left: left + column + gap, width: column, height: height)
  }

  private static func drawStat(
    value: String,
    label: String,
    note: String?,
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) {
    let box = self.rect(top: top, left: left, width: width, height: height)
    self.well.setFill()
    NSBezierPath(roundedRect: box, xRadius: 14, yRadius: 14).fill()
    let innerLeft = box.minX + 14
    let innerWidth = box.width - 28
    var cursor = box.maxY - 14
    let valueFont = NSFont.systemFont(ofSize: 24, weight: .semibold)
    let valueHeight = ShareCardLayout.textHeight(value, font: valueFont, width: innerWidth)
    self.drawText(
      value,
      in: self.rect(top: cursor, left: innerLeft, width: innerWidth, height: valueHeight),
      font: valueFont,
      color: self.primary)
    cursor -= valueHeight + 5

    let labelFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    let labelHeight = ShareCardLayout.textHeight(label, font: labelFont, width: innerWidth)
    self.drawText(
      label,
      in: self.rect(top: cursor, left: innerLeft, width: innerWidth, height: labelHeight),
      font: labelFont,
      color: self.secondary)
    cursor -= labelHeight + 4

    if let note {
      let noteFont = NSFont.systemFont(ofSize: 11)
      let noteHeight = ShareCardLayout.textHeight(note, font: noteFont, width: innerWidth)
      self.drawText(
        note,
        in: self.rect(top: cursor, left: innerLeft, width: innerWidth, height: noteHeight),
        font: noteFont,
        color: self.quiet)
    }
  }

  private static func drawMeter(_ remaining: Double?, in rect: NSRect) {
    let radius = rect.height / 2
    self.track.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    guard let remaining, remaining.isFinite else { return }
    let fraction = CGFloat(min(100, max(0, remaining)) / 100)
    guard fraction > 0 else { return }
    var fill = rect
    fill.size.width = max(rect.height, rect.width * fraction)
    self.accent.setFill()
    NSBezierPath(roundedRect: fill, xRadius: radius, yRadius: radius).fill()
  }

  private static func drawText(
    _ text: String,
    in rect: NSRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left,
    lineBreak: NSLineBreakMode = .byWordWrapping
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = lineBreak
    (text as NSString).draw(
      in: rect,
      withAttributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
  }

  private static func rect(
    top: CGFloat,
    left: CGFloat,
    width: CGFloat,
    height: CGFloat
  ) -> NSRect {
    NSRect(x: left, y: top - height, width: width, height: height)
  }

  private static var isDark: Bool {
    NSAppearance.currentDrawing().bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
  }

  private static var background: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.105, green: 0.102, blue: 0.098, alpha: 1)
      : NSColor(srgbRed: 0.975, green: 0.962, blue: 0.941, alpha: 1)
  }

  private static var primary: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.96, green: 0.95, blue: 0.92, alpha: 1)
      : NSColor(srgbRed: 0.12, green: 0.105, blue: 0.09, alpha: 1)
  }

  private static var secondary: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.72, green: 0.70, blue: 0.66, alpha: 1)
      : NSColor(srgbRed: 0.37, green: 0.34, blue: 0.30, alpha: 1)
  }

  private static var quiet: NSColor {
    self.isDark
      ? NSColor(srgbRed: 0.56, green: 0.54, blue: 0.50, alpha: 1)
      : NSColor(srgbRed: 0.49, green: 0.45, blue: 0.40, alpha: 1)
  }

  private static var accent: NSColor {
    self.isDark
      ? NSColor(srgbRed: 1.0, green: 0.46, blue: 0.22, alpha: 1)
      : NSColor(srgbRed: 0.94, green: 0.35, blue: 0.10, alpha: 1)
  }

  private static var track: NSColor {
    self.isDark
      ? NSColor.white.withAlphaComponent(0.10)
      : NSColor.black.withAlphaComponent(0.09)
  }

  private static var well: NSColor {
    self.isDark
      ? NSColor.white.withAlphaComponent(0.055)
      : NSColor.white.withAlphaComponent(0.72)
  }

  private static var border: NSColor {
    self.isDark
      ? NSColor.white.withAlphaComponent(0.12)
      : NSColor.black.withAlphaComponent(0.10)
  }
}
