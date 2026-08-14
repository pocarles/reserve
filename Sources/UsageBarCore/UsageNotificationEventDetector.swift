import Foundation

public struct UsageThresholdCrossing: Equatable, Sendable {
  public let provider: ProviderID
  public let windowID: String
  public let windowLabel: String
  public let threshold: Int

  public init(provider: ProviderID, windowID: String, windowLabel: String, threshold: Int) {
    self.provider = provider
    self.windowID = windowID
    self.windowLabel = windowLabel
    self.threshold = threshold
  }
}

public enum UsageNotificationEventDetector {
  public static func thresholdCrossings(
    previous: UsageSnapshot?,
    current: UsageSnapshot
  ) -> [UsageThresholdCrossing] {
    guard let previous else { return [] }
    return current.windows.flatMap { window -> [UsageThresholdCrossing] in
      guard let old = previous.windows.first(where: { $0.id == window.id }),
        old.resetsAt == window.resetsAt || old.resetsAt == nil || window.resetsAt == nil
      else { return [] }
      return [50, 90, 100].compactMap { threshold in
        guard old.usedPercent < Double(threshold), window.usedPercent >= Double(threshold) else {
          return nil
        }
        return UsageThresholdCrossing(
          provider: current.provider,
          windowID: window.id,
          windowLabel: window.label,
          threshold: threshold)
      }
    }
  }
}
