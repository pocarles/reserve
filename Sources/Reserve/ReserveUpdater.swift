import AppKit
import Foundation
@preconcurrency import Sparkle

enum ReserveLinks {
  static let repository = URL(string: "https://github.com/pocarles/reserve")!
  static let xProfile = URL(string: "https://x.com/pocarles")!
}

/// Sparkle owns the update schedule, secure download, installation, and user
/// prompts. Reserve only keeps this small adapter so Settings does not need to
/// know about Sparkle's controller lifecycle.
@MainActor
final class ReserveUpdater:
  NSObject, SPUUpdaterDelegate, @preconcurrency SPUStandardUserDriverDelegate
{
  static let dailyInterval: TimeInterval = 24 * 3_600
  static let automaticChecksKey = "SUEnableAutomaticChecks"
  static let legacyAutomaticChecksKey = "updates.automatic"

  var onChange: (() -> Void)?
  var onWillPresentUpdateUI: (() -> Void)?
  var onDidFinishUpdateUI: (() -> Void)?

  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: self,
    userDriverDelegate: self)

  override init() {
    super.init()
    Self.migrateLegacyAutomaticChecks()
    _ = self.controller
  }

  var automaticallyChecksForUpdates: Bool {
    self.controller.updater.automaticallyChecksForUpdates
  }

  var lastUpdateCheckDate: Date? {
    self.controller.updater.lastUpdateCheckDate
  }

  var canCheckForUpdates: Bool {
    self.controller.updater.canCheckForUpdates
  }

  func setAutomaticChecks(_ enabled: Bool) {
    self.controller.updater.automaticallyChecksForUpdates = enabled
    self.onChange?()
    guard enabled, !self.controller.updater.sessionInProgress else { return }
    // Enabling the promise should fulfill it now, not after the first day.
    self.controller.updater.checkForUpdatesInBackground()
  }

  func checkForUpdates() {
    // Sparkle shows its progress window straight away, before any delegate
    // callback, so Reserve's floating windows must step down first.
    self.lowerReserveWindows()
    NSApplication.shared.activate(ignoringOtherApps: true)
    self.controller.checkForUpdates(nil)
  }

  func updater(
    _: SPUUpdater,
    didFinishUpdateCycleFor _: SPUUpdateCheck,
    error _: (any Error)?
  ) {
    self.restoreReserveWindows()
    self.onDidFinishUpdateUI?()
    self.onChange?()
  }

  /// Reserve is a menu-bar app, so Sparkle cannot assume one of our windows
  /// will naturally bring its update alert forward. The standard driver still
  /// owns all update UI; these callbacks only clear our floating Settings
  /// window out of its way and activate Reserve as the alert appears.
  var supportsGentleScheduledUpdateReminders: Bool { true }

  func standardUserDriverWillShowModalAlert() {
    self.prepareForUpdateUI()
  }

  func standardUserDriverWillHandleShowingUpdate(
    _ handleShowingUpdate: Bool,
    forUpdate _: SUAppcastItem,
    state _: SPUUserUpdateState
  ) {
    guard handleShowingUpdate else { return }
    self.prepareForUpdateUI()
  }

  private func prepareForUpdateUI() {
    self.onWillPresentUpdateUI?()
    self.lowerReserveWindows()
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  /// Settings and the dashboard float above normal windows, and Sparkle's
  /// windows open at the normal level, so they landed behind Reserve. While an
  /// update session runs, Reserve's own windows drop to the normal level; the
  /// most recently shown window, Sparkle's, then stays in front.
  private var loweredWindowLevels: [ObjectIdentifier: (window: NSWindow, level: NSWindow.Level)] = [:]

  private func lowerReserveWindows() {
    for window in NSApplication.shared.windows
    where window.isVisible && window.level > .normal
      // The menu-bar icon lives in a status-bar window; it must stay put.
      && !window.className.contains("StatusBar")
      && self.loweredWindowLevels[ObjectIdentifier(window)] == nil
    {
      self.loweredWindowLevels[ObjectIdentifier(window)] = (window, window.level)
      window.level = .normal
    }
  }

  private func restoreReserveWindows() {
    for entry in self.loweredWindowLevels.values where entry.window.level == .normal {
      entry.window.level = entry.level
    }
    self.loweredWindowLevels.removeAll()
  }

  /// Carries the existing Reserve checkbox choice into Sparkle once. Sparkle
  /// then owns its preference directly, as required by its updater contract.
  @discardableResult
  static func migrateLegacyAutomaticChecks(
    defaults: UserDefaults = .standard,
    domainName: String = Bundle.main.bundleIdentifier ?? "com.pocarles.reserve"
  ) -> Bool {
    let persisted = defaults.persistentDomain(forName: domainName) ?? [:]
    guard persisted[self.automaticChecksKey] == nil,
      let legacy = persisted[self.legacyAutomaticChecksKey] as? Bool
    else { return false }
    defaults.set(legacy, forKey: self.automaticChecksKey)
    return true
  }
}
