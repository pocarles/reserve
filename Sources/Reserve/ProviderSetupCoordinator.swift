import AppKit
import ReserveCore

/// One window owns a connection until fresh usage arrives or the user leaves.
@MainActor
final class ProviderSetupCoordinator {
  enum Phase: Equatable {
    case checking, needsInstall, needsUpdate, installing, updating
    case needsSignIn, signingIn, needsAccess, grantingAccess, accessNotGranted, signInNotSaved
    case connected, unavailable, accessDenied, failed
  }

  private let store: UsageStore
  private let installer: ProviderHelperInstaller
  private(set) var activeProvider: ProviderID?
  private(set) var phase: Phase = .checking
  private(set) var panel: ProviderConnectionPanel?
  private var observer: UsageStore.ObserverToken?
  private var generation = 0
  private var loginCompleted = false
  private var loginAttempted = false
  private var wasEnabled = false

  init(store: UsageStore, installer: ProviderHelperInstaller = ProviderHelperInstaller()) {
    self.store = store
    self.installer = installer
  }

  func start(_ provider: ProviderID) {
    if self.activeProvider != nil {
      self.panel?.show()
      return
    }
    self.activeProvider = provider
    self.generation += 1
    self.loginCompleted = false
    self.loginAttempted = false
    self.wasEnabled = self.store.isEnabled(provider)
    self.store.setEnabled(provider, enabled: true, refreshImmediately: false)
    let panel = ProviderConnectionPanel(provider: provider)
    panel.onPrimary = { [weak self] in self?.continueConnection() }
    panel.onClose = { [weak self] in self?.close() }
    self.panel = panel
    self.observer = self.store.observe { [weak self] in self?.storeChanged() }
    self.check()
    panel.show()
  }

  private func storeChanged() {
    guard let provider = self.activeProvider else { return }
    if !self.store.isEnabled(provider) {
      self.close()
    } else if self.phase == .signingIn {
      self.present(.signingIn)
    } else if self.phase == .grantingAccess && !self.store.keychainReadAllowed(for: provider) {
      self.present(.accessNotGranted)
    }
  }

  private func check() {
    guard let provider = self.activeProvider else { return }
    self.present(.checking)
    let generation = self.generation
    self.store.refresh(provider, queueIfBusy: true) { [weak self] in
      guard let self, self.generation == generation else { return }
      self.didCheck()
    }
  }

  private func didCheck() {
    guard let provider = self.activeProvider, let state = self.store.states[provider] else { return }
    if self.loginAttempted, self.store.loginFailedToSave(provider) {
      self.present(.signInNotSaved)
      return
    }
    if [.grantingAccess, .accessNotGranted].contains(self.phase), state.requiresKeychainAccess {
      self.present(.accessNotGranted)
      return
    }
    self.present(Self.phase(after: state))
    // Connect already expresses the user's intent to sign in. Open the
    // browser when needed, but never automatically repeat a failed login.
    if self.phase == .needsSignIn && !self.loginAttempted { self.continueConnection() }
  }

  static func phase(after state: ProviderViewState) -> Phase {
    if state.requiresKeychainAccess { return .needsAccess }
    if state.requiresInstallation { return .needsInstall }
    if state.requiresUpdate { return .needsUpdate }
    if state.requiresConnection { return .needsSignIn }
    if state.usageAccessDenied { return .accessDenied }
    guard state.error == nil, let snapshot = state.snapshot,
      !snapshot.windows.isEmpty || snapshot.accountUsage != nil || snapshot.includedSpend != nil
    else { return .unavailable }
    return .connected
  }

  func continueConnection() {
    guard let provider = self.activeProvider else { return }
    let generation = self.generation
    switch self.phase {
    case .needsInstall, .needsUpdate:
      let installing = self.phase == .needsInstall
      self.present(installing ? .installing : .updating)
      Task { [weak self] in
        guard let self else { return }
        do {
          if installing { try await self.installer.install(provider) }
          else { try await self.installer.update(provider) }
          guard self.generation == generation else { return }
          if !self.store.isEnabled(provider) {
            self.phase = .checking
            self.close()
            return
          }
          self.check()
        } catch {
          guard self.generation == generation else { return }
          self.present(.failed)
          if !self.store.isEnabled(provider) { self.close() }
        }
      }
    case .needsSignIn, .accessNotGranted:
      let forceSignIn = self.phase == .accessNotGranted
      self.loginAttempted = true
      self.present(.signingIn)
      self.store.connect(provider, forceSignIn: forceSignIn) { [weak self] in
        guard let self, self.generation == generation else { return }
        let state = self.store.states[provider]
        // A successful login is followed by a real usage check in UsageStore.
        self.loginCompleted = state?.requiresConnection == false
        self.didCheck()
      }
    case .signingIn:
      if !self.store.reopenLoginBrowser(provider) {
        self.panel?.showBrowserFailure()
      }
    case .needsAccess:
      // This button is the explicit consent. Keep the explanation in this
      // window rather than opening another Reserve permission dialog.
      self.present(.grantingAccess)
      self.store.allowKeychainAccess(for: provider) { [weak self] in
        guard let self, self.generation == generation else { return }
        self.didCheck()
      }
    case .failed, .unavailable, .accessDenied:
      self.check()
    case .connected:
      self.close()
    case .signInNotSaved:
      if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.keychainaccess"),
        NSWorkspace.shared.open(app) {
        self.close()
      }
    case .checking, .installing, .updating, .grantingAccess:
      break
    }
  }

  func close() {
    guard self.phase != .installing, self.phase != .updating else { return }
    let provider = self.activeProvider
    let cancelledSetup = !self.wasEnabled && [Phase.checking, .needsInstall, .needsUpdate,
      .needsSignIn, .signingIn, .needsAccess, .grantingAccess, .accessNotGranted].contains(self.phase)
    self.activeProvider = nil
    self.generation += 1
    if let observer { self.store.removeObserver(observer) }
    self.observer = nil
    self.panel?.close()
    self.panel = nil
    if let provider {
      self.store.cancelConnection(provider)
      if cancelledSetup { self.store.setEnabled(provider, enabled: false) }
    }
  }

  private func present(_ phase: Phase) {
    self.phase = phase
    guard let provider = self.activeProvider else { return }
    self.panel?.update(
      phase: phase, canReopenBrowser: self.store.canReopenLoginBrowser(provider),
      isReadingUsage: self.store.states[provider]?.isRefreshing == true
        && self.store.states[provider]?.isConnecting != true,
      loginCompleted: self.loginCompleted)
    if phase == .signingIn, self.store.loginBrowserFailedToOpen(provider) {
      self.panel?.showBrowserFailure()
    }
  }
}

private enum ProviderSetupRenderError: Error {
  case viewUnavailable
  case bitmapUnavailable
  case pngUnavailable
}

@MainActor
final class ProviderConnectionPanel: NSPanel {
  private let provider: ProviderID
  private let heading = NSTextField(wrappingLabelWithString: "")
  private let message = NSTextField(wrappingLabelWithString: "")
  private let privacy = NSTextField(wrappingLabelWithString: "")
  private let spinner = NSProgressIndicator()
  private let primary = NSButton(title: "", target: nil, action: nil)
  private let closeButton = NSButton(title: "Cancel", target: nil, action: nil)
  var onPrimary: (() -> Void)?
  var onClose: (() -> Void)?
  private var mayClose = true

  #if RESERVE_DEV_AUTOMATION
  func markAsSimulation() {
    self.heading.stringValue = "Simulation: \(self.heading.stringValue)"
    self.privacy.stringValue = "Test data only. No Claude account, subscription, or real sign-in is used."
  }
  #endif

  init(provider: ProviderID) {
    self.provider = provider
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 300),
      styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
    self.identifier = NSUserInterfaceItemIdentifier("provider-connection-window")
    self.title = "Connect \(provider.displayName)"
    self.titleVisibility = .hidden
    self.titlebarAppearsTransparent = true
    self.isMovableByWindowBackground = true
    self.isReleasedWhenClosed = false
    self.hidesOnDeactivate = false
    self.backgroundColor = ReserveColor.background
    self.standardWindowButton(.closeButton)?.isHidden = true
    self.standardWindowButton(.miniaturizeButton)?.isHidden = true
    self.standardWindowButton(.zoomButton)?.isHidden = true
    self.contentView = self.makeContent()
  }

  func show() {
    NSApplication.shared.activate(ignoringOtherApps: true)
    if !self.isVisible { self.center() }
    self.makeKeyAndOrderFront(nil)
  }

  override func cancelOperation(_ sender: Any?) {
    if self.mayClose { self.onClose?() }
  }

  @objc private func primaryClicked() { self.onPrimary?() }
  @objc private func closeClicked() { if self.mayClose { self.onClose?() } }

  func update(
    phase: ProviderSetupCoordinator.Phase,
    canReopenBrowser: Bool = false,
    isReadingUsage: Bool = false,
    loginCompleted: Bool = false
  ) {
    let name = self.provider.displayName
    let helper = ProviderHelperCatalog.definition(for: self.provider)
    var busy = false
    var action: String?
    self.mayClose = phase != .installing && phase != .updating
    self.privacy.stringValue = "Your password stays with \(name). You can disconnect in Reserve's settings."
    self.closeButton.title = "Cancel"
    switch phase {
    case .checking:
      self.heading.stringValue = "Checking \(name)"
      self.message.stringValue = "Looking for an existing sign-in and checking your usage."
      busy = true
    case .needsInstall:
      self.heading.stringValue = "Connect \(name)"
      self.message.stringValue = "Reserve needs the official \(helper.displayName). Install it for your Mac user, then continue here. No Terminal needed."
      self.privacy.stringValue = "Downloaded from \(helper.installerURL.host ?? name). Installation starts only when you choose Install and continue."
      action = "Install and continue"
    case .needsUpdate:
      self.heading.stringValue = "Update to connect \(name)"
      self.message.stringValue = "The \(helper.displayName) needs an update before Reserve can check your usage."
      self.privacy.stringValue = "This updates the provider's software on this Mac using its own updater."
      action = "Update and continue"
    case .installing, .updating:
      self.heading.stringValue = phase == .installing ? "Setting up \(name)" : "Updating \(name)"
      self.message.stringValue = "Installing the provider's software. This can take a few minutes."
      self.privacy.stringValue = "Keep Reserve open until installation finishes."
      busy = true
    case .needsSignIn:
      self.heading.stringValue = "Sign in to \(name)"
      self.message.stringValue = "Reserve could not verify your sign-in. Continue on \(name)'s website to try again. Your usage will be checked when you finish."
      action = "Continue in browser"
    case .signingIn:
      self.heading.stringValue = isReadingUsage ? "Checking your usage" : "Sign in to \(name)"
      self.message.stringValue = isReadingUsage
        ? "Finishing the connection by reading your latest usage."
        : canReopenBrowser
          ? "Complete sign-in in your browser. This window will update when you finish."
          : "Opening the provider's sign-in page."
      busy = true
      if canReopenBrowser { action = "Open browser again" }
    case .needsAccess:
      self.heading.stringValue = "Allow \(name) usage access"
      self.message.stringValue = "Reserve needs permission to use the sign-in protected by macOS to read your plan limits. macOS may ask you to approve access."
      self.privacy.stringValue = "Reserve uses this access only to check usage. It never saves your sign-in. You can turn access off in Settings > Providers."
      action = "Allow usage access"
    case .grantingAccess:
      self.heading.stringValue = "Waiting for permission"
      self.message.stringValue = "Approve access if macOS asks. Reserve will then check your usage."
      busy = true
    case .accessNotGranted:
      self.heading.stringValue = "Sign in to \(name) again"
      self.message.stringValue = "Your saved sign-in could not be used. Sign in again in your browser to reconnect."
      self.privacy.stringValue = "Your password stays with \(name). Reserve will check your usage after sign-in. macOS may still ask you to approve access."
      action = "Sign in again"
    case .connected:
      self.heading.stringValue = "\(name) is connected"
      self.message.stringValue = "Your latest usage is ready. Reserve will keep it updated automatically."
      action = "Done"
      self.closeButton.title = "Close"
    case .signInNotSaved:
      self.heading.stringValue = "Your Mac could not save the sign-in"
      self.message.stringValue = "Cursor finished browser sign-in, but its saved session is unavailable. Check your login keychain in Keychain Access before connecting again."
      self.privacy.stringValue = "Your Cursor account is not connected to Reserve. This needs attention on your Mac; repeating browser sign-in will not fix it."
      action = "Open Keychain Access"
      self.closeButton.title = "Close"
    case .unavailable:
      self.heading.stringValue = "Usage temporarily unavailable"
      self.message.stringValue = loginCompleted
        ? "Sign-in finished, but \(name)'s usage could not be loaded. Reserve will try again automatically."
        : "Reserve could not read \(name)'s usage right now. It will try again automatically."
      action = "Try again"
      self.closeButton.title = "Close"
    case .accessDenied:
      self.heading.stringValue = "Usage access denied"
      self.message.stringValue = "\(name) is not allowing Reserve to read this account's usage. Check your account permissions with \(name), then try again."
      action = "Try again"
      self.closeButton.title = "Close"
    case .failed:
      self.heading.stringValue = "Setup did not finish"
      self.message.stringValue = "Reserve could not finish setting up \(name). Check your connection, then try again."
      action = "Try again"
      self.closeButton.title = "Close"
    }
    self.spinner.isHidden = !busy
    if busy { self.spinner.startAnimation(nil) } else { self.spinner.stopAnimation(nil) }
    self.primary.title = action ?? ""
    self.primary.isHidden = action == nil
    self.primary.isEnabled = action != nil
    self.closeButton.isHidden = !self.mayClose || phase == .connected
    self.contentView?.layoutSubtreeIfNeeded()
  }

  func showBrowserFailure() {
    self.message.stringValue = "The browser could not open. Check your default browser, then choose Open browser again."
  }

  func render(to url: URL) throws {
    guard let view = self.contentView else { throw ProviderSetupRenderError.viewUnavailable }
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
    let content = ReserveSurface(fill: ReserveColor.background)
    let logo = ReserveProviderLogo(provider: self.provider, size: 42, glyph: 22)
    self.heading.font = ReserveFont.sans(ReserveType.pageTitle, .semibold)
    self.heading.textColor = ReserveColor.text
    self.heading.identifier = NSUserInterfaceItemIdentifier("connection-heading")
    self.message.font = ReserveFont.sans(ReserveType.body)
    self.message.textColor = ReserveColor.muted
    self.message.identifier = NSUserInterfaceItemIdentifier("connection-message")
    self.privacy.font = ReserveFont.sans(ReserveType.metadata)
    self.privacy.textColor = ReserveColor.subtle
    self.privacy.identifier = NSUserInterfaceItemIdentifier("connection-privacy")
    for label in [self.heading, self.message, self.privacy] {
      label.maximumNumberOfLines = 0
      label.lineBreakMode = .byWordWrapping
    }
    self.spinner.style = .spinning
    self.spinner.controlSize = .small
    self.primary.bezelStyle = .rounded
    self.primary.keyEquivalent = "\r"
    self.primary.target = self
    self.primary.action = #selector(self.primaryClicked)
    self.primary.identifier = NSUserInterfaceItemIdentifier("connection-primary")
    self.closeButton.bezelStyle = .rounded
    self.closeButton.keyEquivalent = "\u{1b}"
    self.closeButton.target = self
    self.closeButton.action = #selector(self.closeClicked)
    self.closeButton.identifier = NSUserInterfaceItemIdentifier("connection-close")
    let header = NSStackView.row([logo, self.heading], spacing: 14, alignment: .centerY)
    let actions = NSStackView.row(
      [self.spinner, NSStackView.spacer(), self.closeButton, self.primary], spacing: 10)
    let stack = NSStackView.column([header, self.message, self.privacy, actions], spacing: 18)
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 28),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 30),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -22),
      header.widthAnchor.constraint(equalTo: stack.widthAnchor),
      self.message.widthAnchor.constraint(equalTo: stack.widthAnchor),
      self.privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
      actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
    ])
    return content
  }
}
