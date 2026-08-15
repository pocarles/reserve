import CoreFoundation
import Foundation

public struct LegacyMigrationReport: Equatable, Sendable {
  public let migratedPreferenceCount: Int
  public let migratedCacheFiles: [String]
  public let cacheMigrationFailed: Bool
  public let wasAlreadyCompleted: Bool
}

/// One-time, allow-list-only migration from the pre-v1 UsageBar identity.
/// Legacy files are copied, never moved or deleted, so a failed migration cannot
/// damage the old installation.
public enum LegacyStateMigrator {
  public static let oldDefaultsDomain = "com.pocarles.usagebar"
  public static let newDefaultsDomain = "com.pocarles.reserve"
  public static let completionKey = "reserve.migration.usagebar-v1.completed"

  private static let booleanKeys: Set<String> = [
    "anthropic.keychainReadAllowed", "updates.automatic",
    "menuBar.showsRemaining", "menuBar.showsReset",
    "provider.openAI.enabled", "provider.anthropic.enabled", "provider.grok.enabled",
    "notifications.enabled", "notifications.deficit", "notifications.exhausted",
    "notifications.weeklyRenewal", "notifications.stale", "notifications.incident",
    "notifications.planRenewal", "notifications.fiveHourRenewal",
    "notifications.threshold50", "notifications.threshold90", "notifications.sound",
  ]

  public static func migrateLiveState(
    fileManager: FileManager = .default,
    newDefaults: UserDefaults = .standard
  ) -> LegacyMigrationReport {
    let support =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? fileManager.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support", isDirectory: true)
    return self.migrate(
      oldDefaults: UserDefaults(suiteName: self.oldDefaultsDomain),
      newDefaults: newDefaults,
      oldDirectory: support.appendingPathComponent("UsageBar", isDirectory: true),
      newDirectory: support.appendingPathComponent("Reserve", isDirectory: true),
      fileManager: fileManager)
  }

  public static func migrate(
    oldDefaults: UserDefaults?,
    newDefaults: UserDefaults,
    oldDirectory: URL,
    newDirectory: URL,
    fileManager: FileManager = .default
  ) -> LegacyMigrationReport {
    if newDefaults.bool(forKey: self.completionKey) {
      return LegacyMigrationReport(
        migratedPreferenceCount: 0, migratedCacheFiles: [], cacheMigrationFailed: false,
        wasAlreadyCompleted: true)
    }

    // Stage preference mutations until every cache candidate has validated and
    // copied successfully. A bad legacy cache must not leave a half-migrated
    // defaults domain or mark the one-time operation complete.
    var pendingPreferences: [(key: String, value: Any)] = []
    if let oldDefaults {
      for key in self.booleanKeys where newDefaults.object(forKey: key) == nil {
        guard let value = oldDefaults.object(forKey: key) as? NSNumber,
          CFGetTypeID(value) == CFBooleanGetTypeID()
        else { continue }
        pendingPreferences.append((key, value.boolValue))
      }
      if newDefaults.object(forKey: "refresh.intervalMinutes") == nil,
        let value = oldDefaults.object(forKey: "refresh.intervalMinutes") as? NSNumber,
        [1, 5, 10, 15, 30].contains(value.intValue)
      {
        pendingPreferences.append(("refresh.intervalMinutes", value.intValue))
      }
      let allowedStrings: [String: Set<String>] = [
        "appearance.mode": ["system", "light", "dark"],
        "appearance.theme": ["matrix", "ember", "ocean", "graphite"],
        "menuBar.provider": ["reserve", "openAI", "anthropic", "grok"],
      ]
      for (key, allowed) in allowedStrings where newDefaults.object(forKey: key) == nil {
        guard let value = oldDefaults.string(forKey: key), allowed.contains(value) else { continue }
        pendingPreferences.append((key, value))
      }
      for provider in ProviderID.allCases {
        let costKey = "subscription.monthlyCost.\(provider.rawValue)"
        if newDefaults.object(forKey: costKey) == nil,
          let number = oldDefaults.object(forKey: costKey) as? NSNumber,
          number.doubleValue.isFinite, (0...1_000_000).contains(number.doubleValue)
        {
          pendingPreferences.append((costKey, number.doubleValue))
        }
        let dayKey = "subscription.renewalDay.\(provider.rawValue)"
        if newDefaults.object(forKey: dayKey) == nil,
          let number = oldDefaults.object(forKey: dayKey) as? NSNumber,
          (1...31).contains(number.intValue)
        {
          pendingPreferences.append((dayKey, number.intValue))
        }
      }
    }

    let candidates: [(String, Int, (Data) -> Bool)] = [
      ("snapshots.json", 100 * 1_024, self.validSnapshots),
      ("local-usage-index.json", 12 * 1_024 * 1_024, self.validLocalIndex),
    ]
    var validated: [(name: String, data: Data)] = []
    var failed = false
    for (name, maximumBytes, validator) in candidates {
      let source = oldDirectory.appendingPathComponent(name)
      guard fileManager.fileExists(atPath: source.path) else { continue }
      guard let data = BoundedFileReader.read(source, maximumBytes: maximumBytes), validator(data)
      else {
        failed = true
        break
      }
      validated.append((name, data))
    }

    var migratedFiles: [String] = []
    var createdURLs: [URL] = []
    if !failed {
      do {
        for item in validated {
          let destination = newDirectory.appendingPathComponent(item.name)
          guard !fileManager.fileExists(atPath: destination.path) else { continue }
          try BoundedFileReader.writeRestricted(
            item.data, to: destination, fileManager: fileManager)
          createdURLs.append(destination)
          migratedFiles.append(item.name)
        }
      } catch {
        for url in createdURLs { try? fileManager.removeItem(at: url) }
        migratedFiles.removeAll()
        failed = true
      }
    }
    if fileManager.fileExists(atPath: newDirectory.path) {
      try? fileManager.setAttributes(
        [.posixPermissions: NSNumber(value: Int16(0o700))],
        ofItemAtPath: newDirectory.path)
    }
    if !failed {
      for preference in pendingPreferences {
        newDefaults.set(preference.value, forKey: preference.key)
      }
      newDefaults.set(true, forKey: self.completionKey)
    }
    return LegacyMigrationReport(
      migratedPreferenceCount: failed ? 0 : pendingPreferences.count,
      migratedCacheFiles: migratedFiles.sorted(),
      cacheMigrationFailed: failed,
      wasAlreadyCompleted: false)
  }

  private static func validSnapshots(_ data: Data) -> Bool {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    guard let snapshots = try? decoder.decode([UsageSnapshot].self, from: data),
      snapshots.count <= 32
    else { return false }
    return snapshots.allSatisfy { $0.windows.count <= UsageSnapshot.maximumWindows }
  }

  private static func validLocalIndex(_ data: Data) -> Bool {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      (root["version"] as? NSNumber)?.intValue == 1,
      let records = root["records"] as? [String: Any], records.count <= 5_000
    else { return false }
    return records.values.allSatisfy { value in
      guard let record = value as? [String: Any],
        let days = record["days"] as? [String: Any], days.count <= 100,
        let recentRows = record["recentRows"] as? [String: Any], recentRows.count <= 128,
        let recentOrder = record["recentOrder"] as? [Any], recentOrder.count <= 128
      else { return false }
      return true
    }
  }
}
