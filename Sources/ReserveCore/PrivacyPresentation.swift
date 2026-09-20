import Foundation

/// Presentation-only masking for values a provider marked personal.
///
/// Originals stay on the snapshot. Callers pass the current preference and
/// receive a copy; nothing here writes masked text back over stored details.
public enum PrivacyPresentation {
  public static let maskedValue = "Hidden"

  public static func details(_ details: [UsageDetail], hidingPersonal: Bool) -> [UsageDetail] {
    guard hidingPersonal else { return details }
    return details.map { detail in
      guard detail.isPersonal else { return detail }
      return UsageDetail(detail.label, Self.maskedValue, isPersonal: true)
    }
  }

  public static func planName(_ planName: String, isPersonal: Bool, hidingPersonal: Bool) -> String {
    guard hidingPersonal, isPersonal else { return planName }
    return Self.maskedValue
  }
}
