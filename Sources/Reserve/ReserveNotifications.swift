import Foundation
import ReserveCore
@preconcurrency import UserNotifications

@MainActor
final class ReserveNotifications {
  private let center: UNUserNotificationCenter?
  private let defaults: UserDefaults
  private let active: Bool

  init(defaults: UserDefaults, active: Bool) {
    self.defaults = defaults
    let canNotify = active && Bundle.main.bundleURL.pathExtension == "app"
    self.active = canNotify
    self.center = canNotify ? UNUserNotificationCenter.current() : nil
  }

  /// Verification hooks: they read the real notification centre rather than a
  /// stand-in, so a green result means macOS actually accepted the request.
  func authorizationSummary() async -> String {
    guard let center = self.center else { return "inactive (not running from the app bundle)" }
    let settings = await center.notificationSettings()
    let status =
      switch settings.authorizationStatus {
      case .authorized: "authorized"
      case .denied: "denied"
      case .notDetermined: "not determined"
      case .provisional: "provisional"
      case .ephemeral: "ephemeral"
      @unknown default: "unknown"
      }
    return "\(status), alerts=\(settings.alertSetting == .enabled)"
  }

  func deliveredIdentifiers() async -> [String] {
    guard let center = self.center else { return [] }
    return await center.deliveredNotifications().map(\.request.identifier)
  }

  func pendingIdentifiers() async -> [String] {
    guard let center = self.center else { return [] }
    return await center.pendingNotificationRequests().map(\.identifier)
  }

  func removeDelivered(_ identifiers: [String]) {
    self.center?.removeDeliveredNotifications(withIdentifiers: identifiers)
    self.center?.removePendingNotificationRequests(withIdentifiers: identifiers)
  }

  func requestAuthorizationIfNeeded() {
    guard self.active, self.isEnabled else { return }
    self.center?.requestAuthorization(options: [.alert, .sound]) { _, _ in }
  }

  var isEnabled: Bool {
    self.defaults.bool(forKey: "notifications.enabled")
  }

  func setEnabled(_ enabled: Bool) {
    self.defaults.set(enabled, forKey: "notifications.enabled")
    if enabled {
      self.requestAuthorizationIfNeeded()
    } else {
      self.removeReservePendingNotifications()
    }
  }

  func update(
    previous: UsageSnapshot?,
    current: UsageSnapshot,
    nextPlanRenewal: Date?,
    now: Date = Date()
  ) {
    guard self.active, self.isEnabled else { return }
    self.schedulePlanRenewal(provider: current.provider, at: nextPlanRenewal)
    self.scheduleWindowRenewals(current)
    self.deliverThresholdCrossings(previous: previous, current: current)
    for alert in SmartAlertDetector.deficitAlerts(previous: previous, current: current, now: now) {
      self.deliver(alert, now: now)
    }
  }

  /// Delivers a forecast-driven alert. The caller owns the transition, so this
  /// only formats and sends.
  func deliver(_ alert: SmartAlert, now: Date = Date()) {
    guard self.active, self.isEnabled, self.preference(alert.preferenceKey) else { return }
    switch alert {
    case .enteredDeficit(
      let provider, let windowID, let label, let deficitPercent, let runsOutAt, let resetsAt):
      let cycle = Self.cycleID(resetsAt)
      let deficit = Int(deficitPercent.rounded())
      let body: String
      if let runsOutAt {
        body = String(deficit) + "% in deficit. At the current pace, capacity is projected to be "
          + "exhausted " + Self.moment(runsOutAt, now: now) + ", "
          + Self.gap(from: runsOutAt, to: resetsAt) + " before reset."
      } else {
        body = String(deficit) + "% in deficit for the current " + label.lowercased() + " window."
      }
      self.deliver(
        identifier: "reserve.deficit.\(provider.rawValue).\(Self.safeID(windowID)).\(cycle)",
        title: "\(provider.displayName) forecast entered deficit",
        body: body)
    case .dataStale(let provider, let lastUpdated):
      self.deliver(
        identifier: "reserve.stale.\(provider.rawValue)",
        title: "\(provider.displayName) data is stale",
        body: "Reserve has not received an update for "
          + "\(Self.gap(from: lastUpdated, to: now)). The numbers shown are the last "
          + "successful reading.")
    case .serviceIncident(let provider, let health, let detail):
      self.deliver(
        identifier: "reserve.incident.\(provider.rawValue)",
        title: "\(provider.displayName) is reporting \(health.displayName.lowercased()) service",
        body: detail)
    }
  }

  /// Clears a standing alert once the condition has passed.
  func clear(_ identifier: String) {
    self.center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    self.center?.removeDeliveredNotifications(withIdentifiers: [identifier])
  }

  func clearStale(_ provider: ProviderID) {
    self.clear("reserve.stale.\(provider.rawValue)")
  }

  func clearIncident(_ provider: ProviderID) {
    self.clear("reserve.incident.\(provider.rawValue)")
  }

  func rebuildSchedules(
    snapshots: [UsageSnapshot],
    nextPlanRenewals: [ProviderID: Date]
  ) {
    guard self.active, self.isEnabled else { return }
    self.removeReservePendingNotifications()
    for snapshot in snapshots {
      self.schedulePlanRenewal(
        provider: snapshot.provider, at: nextPlanRenewals[snapshot.provider])
      self.scheduleWindowRenewals(snapshot)
    }
  }

  func updatePlanRenewal(provider: ProviderID, at date: Date?) {
    guard self.active, self.isEnabled else { return }
    self.schedulePlanRenewal(provider: provider, at: date)
  }

  private func schedulePlanRenewal(provider: ProviderID, at date: Date?) {
    let identifier = "reserve.plan-renewal.\(provider.rawValue)"
    self.center?.removePendingNotificationRequests(withIdentifiers: [identifier])
    guard self.preference("planRenewal"), let date, date.timeIntervalSinceNow > 1 else { return }
    self.schedule(
      identifier: identifier,
      title: "\(provider.displayName) plan renewed",
      body: "A new monthly plan cycle has started.",
      at: date)
  }

  private func scheduleWindowRenewals(_ snapshot: UsageSnapshot) {
    for window in snapshot.windows where self.isNotifiableWindow(window) {
      let identifier =
        "reserve.window-renewal.\(snapshot.provider.rawValue).\(Self.safeID(window.id))"
      self.center?.removePendingNotificationRequests(withIdentifiers: [identifier])
      guard let reset = window.resetsAt, reset.timeIntervalSinceNow > 1 else { continue }
      self.schedule(
        identifier: identifier,
        title: "\(snapshot.provider.displayName) \(window.label) renewed",
        body: "Your \(window.label.lowercased()) allowance is available again.",
        at: reset)
    }
  }

  private func deliverThresholdCrossings(previous: UsageSnapshot?, current: UsageSnapshot) {
    for crossing in UsageNotificationEventDetector.thresholdCrossings(
      previous: previous, current: current)
    {
      let preference =
        switch crossing.threshold {
        case 50: "threshold50"
        case 90: "threshold90"
        default: "exhausted"
        }
      guard self.preference(preference) else { continue }
      guard let window = current.windows.first(where: { $0.id == crossing.windowID }) else {
        continue
      }
      let cycle = window.resetsAt.map(Self.cycleID) ?? "current"
      let threshold = crossing.threshold
      let identifier =
        "reserve.threshold.\(current.provider.rawValue).\(Self.safeID(window.id)).\(cycle).\(threshold)"
      let title: String
      let body: String
      if threshold == 100 {
        title = "No \(current.provider.displayName) allowance left"
        body = "Your \(window.label.lowercased()) allowance has no capacity left."
      } else {
        let remaining = 100 - threshold
        title = "\(current.provider.displayName) allowance: \(remaining)% left"
        body = "Your \(window.label.lowercased()) allowance has \(remaining)% left."
      }
      self.deliver(identifier: identifier, title: title, body: body)
    }
  }

  private func schedule(identifier: String, title: String, body: String, at date: Date) {
    let content = self.content(title: title, body: body)
    let interval = max(1, date.timeIntervalSinceNow)
    let request = UNNotificationRequest(
      identifier: identifier,
      content: content,
      trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false))
    self.center?.add(request)
  }

  private func deliver(identifier: String, title: String, body: String) {
    let request = UNNotificationRequest(
      identifier: identifier,
      content: self.content(title: title, body: body),
      trigger: nil)
    self.center?.add(request)
  }

  private func removeReservePendingNotifications() {
    self.center?.removeAllPendingNotificationRequests()
  }

  private func content(title: String, body: String) -> UNMutableNotificationContent {
    let content = UNMutableNotificationContent()
    content.title = title
    content.body = body
    content.sound = self.preference("sound") ? .default : nil
    return content
  }

  private func isNotifiableWindow(_ window: UsageWindow) -> Bool {
    let label = window.label.lowercased()
    guard !label.contains("share") else { return false }
    let weekly = label.contains("weekly") || window.windowMinutes == 10_080
    let fiveHour = label.contains("5 hour") || window.windowMinutes == 300
    return (weekly && self.preference("weeklyRenewal"))
      || (fiveHour && self.preference("fiveHourRenewal"))
  }

  private func preference(_ name: String) -> Bool {
    self.defaults.bool(forKey: "notifications.\(name)")
  }

  /// "Tuesday at 11:04 PM", or a time alone when it is close.
  private static func moment(_ date: Date, now: Date) -> String {
    let formatter = DateFormatter()
    let interval = date.timeIntervalSince(now)
    if interval < 12 * 3_600 {
      formatter.dateFormat = "h:mm a"
      return "at \(formatter.string(from: date))"
    }
    formatter.dateFormat = interval < 6 * 86_400 ? "EEEE 'at' h:mm a" : "MMM d 'at' h:mm a"
    return formatter.string(from: date)
  }

  /// "1 day 16 hours", spelled out for a notification.
  private static func gap(from: Date, to: Date) -> String {
    let minutes = max(0, Int(to.timeIntervalSince(from) / 60))
    let days = minutes / 1_440
    let hours = (minutes % 1_440) / 60
    let remainder = minutes % 60
    func unit(_ value: Int, _ name: String) -> String {
      "\(value) \(name)\(value == 1 ? "" : "s")"
    }
    if days > 0 { return "\(unit(days, "day")) \(unit(hours, "hour"))" }
    if hours > 0 { return "\(unit(hours, "hour")) \(unit(remainder, "minute"))" }
    return unit(remainder, "minute")
  }

  private static func safeID(_ value: String) -> String {
    StableIdentifier.notificationComponent(value)
  }

  private static func cycleID(_ date: Date) -> String {
    let seconds = date.timeIntervalSince1970
    return Self.safeID(seconds.isFinite ? String(format: "%.0f", seconds) : "invalid")
  }
}
