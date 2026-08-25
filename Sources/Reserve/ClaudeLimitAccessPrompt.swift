import AppKit
import ReserveCore

/// A calm, wide confirmation shown before macOS asks for a provider's protected
/// sign-in. The system alert made this short explanation look like an error by
/// squeezing it into a tall warning-shaped column.
@MainActor
final class ProviderLimitAccessPrompt: NSPanel {
  static let size = NSSize(width: 520, height: 270)
  private let provider: ProviderID

  init(provider: ProviderID) {
    self.provider = provider
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    self.identifier = NSUserInterfaceItemIdentifier("provider-limit-access-prompt")
    self.title = "Allow \(provider.displayName) usage access"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.isMovableByWindowBackground = true
    self.isReleasedWhenClosed = false
    self.level = .floating
    self.hidesOnDeactivate = false
    self.backgroundColor = ReserveColor.background
    self.standardWindowButton(.closeButton)?.isHidden = true
    self.standardWindowButton(.miniaturizeButton)?.isHidden = true
    self.standardWindowButton(.zoomButton)?.isHidden = true
    self.contentView = self.makeContent()
  }

  func ask() -> Bool {
    NSApplication.shared.activate(ignoringOtherApps: true)
    NSRunningApplication.current.activate(options: [.activateAllWindows])
    self.centerOnPointerScreen()
    self.makeKeyAndOrderFront(nil)
    self.orderFrontRegardless()
    let response = NSApplication.shared.runModal(for: self)
    self.orderOut(nil)
    return response == .OK
  }

  override func cancelOperation(_ sender: Any?) {
    self.finish(with: .cancel)
  }

  func validateForSelfTest() -> Bool {
    let identifiers = Set(
      Self.descendants(of: self.contentView).compactMap { $0.identifier?.rawValue })
    return self.frame.width / self.frame.height > 1.7
      && identifiers.contains("provider-access-title")
      && identifiers.contains("provider-access-reassurance")
      && identifiers.contains("provider-access-continue")
      && identifiers.contains("provider-access-cancel")
  }

  private func makeContent() -> NSView {
    let content = ReserveSurface(fill: ReserveColor.background)

    let logo = ReserveProviderLogo(provider: self.provider, size: 42, glyph: 22)
    let title = Self.label(
      "Allow \(self.provider.displayName) usage access",
      font: ReserveFont.sans(ReserveType.pageTitle, .semibold),
      color: ReserveColor.text)
    title.identifier = NSUserInterfaceItemIdentifier("provider-access-title")
    let message = Self.label(
      "Reserve can use the \(self.provider.displayName) sign-in already on this Mac to check your plan usage.",
      font: ReserveFont.sans(ReserveType.body),
      color: ReserveColor.muted)
    let heading = NSStackView.column([title, message], spacing: 5)
    let header = NSStackView.row([logo, heading], spacing: 14, alignment: .top)

    let reassurance = ReserveSurface(fill: ReserveColor.elevated, radius: ReserveRadius.control)
    reassurance.identifier = NSUserInterfaceItemIdentifier("provider-access-reassurance")
    let shield = NSImageView(
      image: NSImage(
        systemSymbolName: "lock.shield.fill", accessibilityDescription: nil) ?? NSImage())
    shield.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    shield.contentTintColor = ReserveColor.success
    shield.setAccessibilityElement(false)
    shield.translatesAutoresizingMaskIntoConstraints = false
    let reassuranceTitle = Self.label(
      AppDelegate.claudeSetupReassurance,
      font: ReserveFont.sans(ReserveType.body, .medium),
      color: ReserveColor.text)
    let reassuranceDetail = Self.label(
      AppDelegate.claudeSetupPrivacy,
      font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.muted)
    let reassuranceText = NSStackView.column(
      [reassuranceTitle, reassuranceDetail], spacing: 3)
    let reassuranceRow = NSStackView.row(
      [shield, reassuranceText], spacing: 11, alignment: .top)
    reassuranceRow.translatesAutoresizingMaskIntoConstraints = false
    reassurance.addSubview(reassuranceRow)
    NSLayoutConstraint.activate([
      shield.widthAnchor.constraint(equalToConstant: 20),
      shield.heightAnchor.constraint(equalToConstant: 20),
      reassuranceRow.leadingAnchor.constraint(equalTo: reassurance.leadingAnchor, constant: 14),
      reassuranceRow.trailingAnchor.constraint(equalTo: reassurance.trailingAnchor, constant: -14),
      reassuranceRow.topAnchor.constraint(equalTo: reassurance.topAnchor, constant: 12),
      reassuranceRow.bottomAnchor.constraint(equalTo: reassurance.bottomAnchor, constant: -12),
    ])

    let note = Self.label(
      AppDelegate.claudeSetupFootnote,
      font: ReserveFont.sans(ReserveType.metadata),
      color: ReserveColor.subtle)

    let cancel = ReserveTextButton(
      title: "Not now", color: ReserveColor.muted,
      action: { [weak self] in self?.finish(with: .cancel) })
    cancel.identifier = NSUserInterfaceItemIdentifier("provider-access-cancel")
    cancel.keyEquivalent = "\u{1b}"
    let accept = ReserveTextButton(
      title: "Continue", color: ReserveColor.accent, filled: true,
      action: { [weak self] in self?.finish(with: .OK) })
    accept.identifier = NSUserInterfaceItemIdentifier("provider-access-continue")
    accept.keyEquivalent = "\r"
    let actions = NSStackView.row([NSStackView.spacer(), cancel, accept], spacing: 8)

    let stack = NSStackView.column([header, reassurance, note, actions], spacing: 14)
    stack.setCustomSpacing(18, after: header)
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
      reassurance.widthAnchor.constraint(equalTo: stack.widthAnchor),
      actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    return content
  }

  private func finish(with response: NSApplication.ModalResponse) {
    NSApplication.shared.stopModal(withCode: response)
  }

  private func centerOnPointerScreen() {
    let pointer = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(pointer, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else {
      self.center()
      return
    }
    self.setFrameOrigin(
      NSPoint(x: frame.midX - self.frame.width / 2, y: frame.midY - self.frame.height / 2))
  }

  private static func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let label = NSTextField(wrappingLabelWithString: text)
    label.font = font
    label.textColor = color
    label.maximumNumberOfLines = 0
    label.lineBreakMode = .byWordWrapping
    return label
  }

  private static func descendants(of view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return view.subviews + view.subviews.flatMap { self.descendants(of: $0) }
  }
}
