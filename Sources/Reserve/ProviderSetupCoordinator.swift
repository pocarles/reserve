import AppKit
import ReserveCore

@MainActor
final class ProviderSetupCoordinator {
  private let store: UsageStore
  private let installer: ProviderHelperInstaller
  private var progressPanel: ProviderSetupProgressPanel?
  private var setupGate = ProviderSetupGate()

  init(store: UsageStore, installer: ProviderHelperInstaller = ProviderHelperInstaller()) {
    self.store = store
    self.installer = installer
  }

  func start(_ provider: ProviderID) {
    guard let state = self.store.states[provider] else { return }
    let action = AllowanceBuilder.setupAction(for: state)
    switch action {
    case .allowAccess:
      guard AppDelegate.confirmLimitAccess(for: provider) else { return }
      self.enableIfNeeded(provider)
      self.store.allowKeychainAccess(for: provider)
    case .signIn:
      self.enableIfNeeded(provider)
      self.store.connect(provider)
    case .install, .update:
      guard let action else { return }
      guard self.setupGate.activeProvider == nil else {
        self.progressPanel?.show()
        return
      }
      let prompt = ProviderHelperSetupPrompt(provider: provider, action: action)
      guard prompt.ask() else { return }
      guard self.setupGate.begin(provider) else {
        self.progressPanel?.show()
        return
      }
      self.enableIfNeeded(provider)
      self.runHelperSetup(provider: provider, action: action)
    case nil:
      self.enableIfNeeded(provider)
      self.store.refresh(provider)
    }
  }

  private func enableIfNeeded(_ provider: ProviderID) {
    if !self.store.isEnabled(provider) {
      self.store.setEnabled(provider, enabled: true)
    }
  }

  private func runHelperSetup(provider: ProviderID, action: ProviderSetupAction) {
    let panel = ProviderSetupProgressPanel(provider: provider, action: action)
    self.progressPanel?.close()
    self.progressPanel = panel
    panel.show()

    Task { [weak self, weak panel] in
      guard let self, let panel else { return }
      defer { self.setupGate.finish(provider) }
      do {
        switch action {
        case .install:
          try await self.installer.install(provider)
        case .update:
          try await self.installer.update(provider)
        case .signIn, .allowAccess:
          return
        }
        guard !Task.isCancelled else { return }
        panel.showFinishing(action: action)
        if action == .install {
          self.store.connect(provider)
        } else {
          self.store.refresh(provider)
        }
        try? await Task.sleep(for: .milliseconds(700))
        panel.close()
        if self.progressPanel === panel { self.progressPanel = nil }
      } catch {
        guard !Task.isCancelled else { return }
        if let installerError = error as? ProviderHelperInstallerError,
          case .helperNotFound = installerError
        {
          self.store.refresh(provider)
          let name = ProviderHelperCatalog.definition(for: provider).displayName
          panel.showFailure(
            "\(name) is no longer installed. Close this message, then choose Set up.")
        } else {
          panel.showFailure(error.localizedDescription)
        }
      }
    }
  }
}

/// Confirms the one material change in provider setup: installing or updating
/// another company's helper. The normal sign-in and Keychain flows keep their
/// existing single-purpose actions.
@MainActor
final class ProviderHelperSetupPrompt: NSPanel {
  static let size = NSSize(width: 540, height: 292)

  private let provider: ProviderID
  private let action: ProviderSetupAction

  init(provider: ProviderID, action: ProviderSetupAction) {
    self.provider = provider
    self.action = action
    super.init(
      contentRect: NSRect(origin: .zero, size: Self.size),
      styleMask: [.titled, .fullSizeContentView],
      backing: .buffered,
      defer: false)
    self.identifier = NSUserInterfaceItemIdentifier("provider-helper-setup-prompt")
    self.title = "\(action == .install ? "Set up" : "Update") \(provider.displayName)"
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

  override func cancelOperation(_ sender: Any?) { self.finish(with: .cancel) }

  func validateForSelfTest() -> Bool {
    let identifiers = Set(
      Self.descendants(of: self.contentView).compactMap { $0.identifier?.rawValue })
    return identifiers.contains("provider-helper-setup-title")
      && identifiers.contains("provider-helper-setup-source")
      && identifiers.contains("provider-helper-setup-accept")
      && identifiers.contains("provider-helper-setup-cancel")
  }

  func render(to url: URL) throws {
    guard let view = self.contentView else { throw ProviderSetupRenderError.viewUnavailable }
    view.frame = NSRect(origin: .zero, size: Self.size)
    view.layoutSubtreeIfNeeded()
    guard let representation = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
      throw ProviderSetupRenderError.bitmapUnavailable
    }
    view.cacheDisplay(in: view.bounds, to: representation)
    guard let data = representation.representation(using: .png, properties: [:]) else {
      throw ProviderSetupRenderError.pngUnavailable
    }
    try data.write(to: url, options: .atomic)
  }

  private func makeContent() -> NSView {
    let definition = ProviderHelperCatalog.definition(for: self.provider)
    let messageText: String
    if self.action == .install {
      messageText =
        "Reserve will install \(definition.displayName), then open your browser so you can sign in."
    } else {
      messageText =
        "Reserve will ask \(definition.displayName) to update itself, then check your limits again."
    }
    let content = ReserveSurface(fill: ReserveColor.background)
    let logo = ReserveProviderLogo(provider: self.provider, size: 42, glyph: 22)
    let title = Self.label(
      "\(self.action == .install ? "Set up" : "Update") \(self.provider.displayName)",
      font: ReserveFont.sans(ReserveType.pageTitle, .semibold), color: ReserveColor.text)
    title.identifier = NSUserInterfaceItemIdentifier("provider-helper-setup-title")
    let message = Self.label(
      messageText,
      font: ReserveFont.sans(ReserveType.body), color: ReserveColor.muted)
    let heading = NSStackView.column([title, message], spacing: 5)
    let header = NSStackView.row([logo, heading], spacing: 14, alignment: .top)

    let source = ReserveSurface(fill: ReserveColor.elevated, radius: ReserveRadius.control)
    source.identifier = NSUserInterfaceItemIdentifier("provider-helper-setup-source")
    let shield = NSImageView(
      image: NSImage(systemSymbolName: "checkmark.shield.fill", accessibilityDescription: nil)
        ?? NSImage())
    shield.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
    shield.contentTintColor = ReserveColor.success
    shield.setAccessibilityElement(false)
    shield.translatesAutoresizingMaskIntoConstraints = false
    let sourceTitle = Self.label(
      "No Terminal needed",
      font: ReserveFont.sans(ReserveType.body, .medium), color: ReserveColor.text)
    let host = definition.installerURL.host ?? "the provider's website"
    let sourceDetail = Self.label(
      self.action == .install
        ? "Reserve downloads the official installer from \(host) and runs it only after you approve."
        : "Reserve uses the update command built into the helper already on this Mac.",
      font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.muted)
    let sourceText = NSStackView.column([sourceTitle, sourceDetail], spacing: 3)
    let sourceRow = NSStackView.row([shield, sourceText], spacing: 11, alignment: .top)
    sourceRow.translatesAutoresizingMaskIntoConstraints = false
    source.addSubview(sourceRow)
    NSLayoutConstraint.activate([
      shield.widthAnchor.constraint(equalToConstant: 20),
      shield.heightAnchor.constraint(equalToConstant: 20),
      sourceRow.leadingAnchor.constraint(equalTo: source.leadingAnchor, constant: 14),
      sourceRow.trailingAnchor.constraint(equalTo: source.trailingAnchor, constant: -14),
      sourceRow.topAnchor.constraint(equalTo: source.topAnchor, constant: 12),
      sourceRow.bottomAnchor.constraint(equalTo: source.bottomAnchor, constant: -12),
    ])

    let note = Self.label(
      "The helper is installed for your Mac user and can be removed using the provider's instructions.",
      font: ReserveFont.sans(ReserveType.metadata), color: ReserveColor.subtle)
    let cancel = ReserveTextButton(
      title: "Not now", color: ReserveColor.muted,
      action: { [weak self] in self?.finish(with: .cancel) })
    cancel.identifier = NSUserInterfaceItemIdentifier("provider-helper-setup-cancel")
    cancel.keyEquivalent = "\u{1b}"
    let accept = ReserveTextButton(
      title: self.action == .install ? "Install and connect" : "Update",
      color: ReserveColor.accent, filled: true,
      action: { [weak self] in self?.finish(with: .OK) })
    accept.identifier = NSUserInterfaceItemIdentifier("provider-helper-setup-accept")
    accept.keyEquivalent = "\r"
    let actions = NSStackView.row([NSStackView.spacer(), cancel, accept], spacing: 8)

    let stack = NSStackView.column([header, source, note, actions], spacing: 14)
    stack.setCustomSpacing(18, after: header)
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
      source.widthAnchor.constraint(equalTo: stack.widthAnchor),
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
    guard let frame = screen?.visibleFrame else { self.center(); return }
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

struct ProviderSetupGate {
  private(set) var activeProvider: ProviderID?

  mutating func begin(_ provider: ProviderID) -> Bool {
    guard self.activeProvider == nil else { return false }
    self.activeProvider = provider
    return true
  }

  mutating func finish(_ provider: ProviderID) {
    guard self.activeProvider == provider else { return }
    self.activeProvider = nil
  }
}

private enum ProviderSetupRenderError: Error {
  case viewUnavailable
  case bitmapUnavailable
  case pngUnavailable
}

@MainActor
private final class ProviderSetupProgressPanel: NSPanel {
  private let provider: ProviderID
  private let action: ProviderSetupAction
  private let spinner = NSProgressIndicator()
  private let status = NSTextField(wrappingLabelWithString: "")
  private lazy var closeAction = ReserveTextButton(
    title: "Close", color: ReserveColor.accent, filled: true,
    action: { [weak self] in self?.close() })

  init(provider: ProviderID, action: ProviderSetupAction) {
    self.provider = provider
    self.action = action
    super.init(
      contentRect: NSRect(origin: .zero, size: NSSize(width: 460, height: 210)),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.isReleasedWhenClosed = false
    self.level = .floating
    self.hidesOnDeactivate = false
    self.backgroundColor = ReserveColor.background
    self.standardWindowButton(.closeButton)?.isHidden = true
    self.standardWindowButton(.miniaturizeButton)?.isHidden = true
    self.standardWindowButton(.zoomButton)?.isHidden = true
    self.closeAction.isHidden = true
    self.contentView = self.makeContent()
  }

  func show() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    self.center()
    self.makeKeyAndOrderFront(nil)
    self.orderFrontRegardless()
    self.spinner.startAnimation(nil)
  }

  func showFinishing(action: ProviderSetupAction) {
    self.status.stringValue =
      action == .install ? "Opening secure sign-in…" : "Checking your limits again…"
  }

  func showFailure(_ message: String) {
    self.spinner.stopAnimation(nil)
    self.spinner.isHidden = true
    self.status.stringValue = message
    self.status.textColor = ReserveColor.warning
    self.closeAction.isHidden = false
  }

  private func makeContent() -> NSView {
    let content = ReserveSurface(fill: ReserveColor.background)
    let logo = ReserveProviderLogo(provider: self.provider, size: 38, glyph: 20)
    let title = NSTextField(labelWithString:
      "\(self.action == .install ? "Setting up" : "Updating") \(self.provider.displayName)")
    title.font = ReserveFont.sans(ReserveType.pageTitle, .semibold)
    title.textColor = ReserveColor.text
    self.status.stringValue =
      self.action == .install ? "Installing the official helper…" : "Installing the latest update…"
    self.status.font = ReserveFont.sans(ReserveType.body)
    self.status.textColor = ReserveColor.muted
    self.status.maximumNumberOfLines = 0
    self.spinner.style = .spinning
    self.spinner.controlSize = .regular
    let copy = NSStackView.column([title, self.status], spacing: 6)
    let header = NSStackView.row([logo, copy], spacing: 14, alignment: .top)
    let progress = NSStackView.row([self.spinner, header], spacing: 18, alignment: .centerY)
    let actions = NSStackView.row([NSStackView.spacer(), self.closeAction], spacing: 0)
    let stack = NSStackView.column([progress, actions], spacing: 22)
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 30),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -30),
      stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    return content
  }
}
