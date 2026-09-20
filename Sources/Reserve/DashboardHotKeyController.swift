import Carbon.HIToolbox
import Foundation
import ReserveCore

/// Registers one Carbon hot key that opens the dashboard.
///
/// All mutable Carbon state stays on the main actor. `apply` returns
/// immediately when the choice has not changed, so quota updates do not
/// unregister a working shortcut.
@MainActor
final class DashboardHotKeyController {
  /// Carbon pointers are not Sendable. They are written only on the main
  /// actor and read from deinit, which Swift 6 does not isolate.
  nonisolated(unsafe) private var hotKeyRef: EventHotKeyRef?
  nonisolated(unsafe) private var handlerRef: EventHandlerRef?
  private let openDashboard: () -> Void
  private(set) var registration: DashboardHotKeyRegistration = .inactive
  private var applied: DashboardHotKeyChoice?
  /// How many times RegisterEventHotKey was actually called.
  private(set) var registrationAttempts = 0
  var onRegistration: ((DashboardHotKeyRegistration) -> Void)?

  init(openDashboard: @escaping () -> Void) {
    self.openDashboard = openDashboard
    self.installHandler()
  }

  deinit {
    Self.release(hotKey: self.hotKeyRef, handler: self.handlerRef)
  }

  func apply(_ choice: DashboardHotKeyChoice) {
    if self.applied == choice, self.handlerRef != nil {
      return
    }
    self.applied = choice
    self.unregisterHotKey()
    guard let arguments = DashboardHotKeyMapping.carbonArguments(for: choice) else {
      self.registration = .inactive
      self.onRegistration?(.inactive)
      return
    }
    if self.handlerRef == nil {
      self.installHandler()
    }
    guard self.handlerRef != nil else {
      if case .failed = self.registration {} else {
        self.registration = .failed(Int32(eventInternalErr))
      }
      self.onRegistration?(self.registration)
      return
    }
    let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
    var ref: EventHotKeyRef?
    self.registrationAttempts += 1
    let status = RegisterEventHotKey(
      arguments.keyCode,
      arguments.modifiers,
      hotKeyID,
      GetApplicationEventTarget(),
      0,
      &ref)
    self.registration = DashboardHotKeyRegistration.from(status: status)
    if status == noErr {
      self.hotKeyRef = ref
    }
    self.onRegistration?(self.registration)
  }

  func unregister() {
    self.unregisterHotKey()
    self.applied = .off
    if self.handlerRef != nil {
      self.registration = .inactive
    }
  }

  private func unregisterHotKey() {
    if let hotKeyRef {
      UnregisterEventHotKey(hotKeyRef)
      self.hotKeyRef = nil
    }
  }

  fileprivate func handlePressed() {
    self.openDashboard()
  }

  /// Test hook. Production only reaches this from the Carbon callback.
  func simulatePressForTesting() {
    self.handlePressed()
  }

  private static let signature: OSType = 0x52737665 // 'Rsve'

  /// Installs the Carbon handler once. A failed install stays `.failed` so a
  /// later Off to On change does not report Off.
  private func installHandler() {
    guard self.handlerRef == nil else { return }
    var spec = EventTypeSpec(
      eventClass: OSType(kEventClassKeyboard),
      eventKind: UInt32(kEventHotKeyPressed))
    let context = Unmanaged.passUnretained(self).toOpaque()
    var installed: EventHandlerRef?
    let status = InstallEventHandler(
      GetApplicationEventTarget(),
      Self.hotKeyHandler,
      1,
      &spec,
      context,
      &installed)
    if status == noErr {
      self.handlerRef = installed
    } else {
      self.registration = .failed(status)
    }
  }

  /// Nonisolated so deinit can release Carbon handles without touching
  /// main-actor state. The pointers are copied before this is called.
  nonisolated private static func release(hotKey: EventHotKeyRef?, handler: EventHandlerRef?) {
    if let hotKey {
      UnregisterEventHotKey(hotKey)
    }
    if let handler {
      RemoveEventHandler(handler)
    }
  }

  private static let hotKeyHandler: EventHandlerUPP = { _, event, userData in
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
      event,
      EventParamName(kEventParamDirectObject),
      EventParamType(typeEventHotKeyID),
      nil,
      MemoryLayout<EventHotKeyID>.size,
      nil,
      &hotKeyID)
    guard status == noErr, hotKeyID.signature == DashboardHotKeyController.signature else {
      return OSStatus(eventNotHandledErr)
    }
    let controller = Unmanaged<DashboardHotKeyController>.fromOpaque(userData).takeUnretainedValue()
    DispatchQueue.main.async {
      MainActor.assumeIsolated {
        controller.handlePressed()
      }
    }
    return noErr
  }
}
