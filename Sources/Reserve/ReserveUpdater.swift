import Foundation
import Sparkle

enum ReserveLinks {
  static let repository = URL(string: "https://github.com/pocarles/reserve")!
  static let xProfile = URL(string: "https://x.com/pocarles")!
}

/// Sparkle owns the update schedule, secure download, installation, and user
/// prompts. Reserve only keeps this small adapter so Settings does not need to
/// know about Sparkle's controller lifecycle.
@MainActor
final class ReserveUpdater: NSObject, SPUUpdaterDelegate {
  static let dailyInterval: TimeInterval = 24 * 3_600
  static let automaticChecksKey = "SUEnableAutomaticChecks"
  static let legacyAutomaticChecksKey = "updates.automatic"

  var onChange: (() -> Void)?

  private lazy var controller = SPUStandardUpdaterController(
    startingUpdater: true,
    updaterDelegate: self,
    userDriverDelegate: nil)

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
    self.controller.checkForUpdates(nil)
  }

  func updater(
    _: SPUUpdater,
    didFinishUpdateCycleFor _: SPUUpdateCheck,
    error _: (any Error)?
  ) {
    self.onChange?()
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
