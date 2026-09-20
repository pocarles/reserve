import Foundation

/// One quota line safe to put on a share card. The label is a fixed Reserve
/// phrase, never text copied from a provider payload.
public struct UsageShareWindow: Equatable, Sendable {
  public var label: String
  public var remainingPercent: Double?
  public var resetsAt: Date?

  public init(label: String, remainingPercent: Double?, resetsAt: Date?) {
    self.label = label
    self.remainingPercent = remainingPercent
    self.resetsAt = resetsAt
  }
}

/// The only model the share card may render.
///
/// Every string is chosen from a fixed list. Emails, organization names,
/// paths, raw errors, sources, and identifiers have no field to land in.
public struct UsageShareModel: Equatable, Sendable {
  public var providerName: String
  /// A known catalog plan, or nil when the reported name is not on that list.
  public var planName: String?
  public var windows: [UsageShareWindow]
  /// Tokens counted over the stated period. This is usage, not remaining quota.
  public var tokensUsed: Int64?
  public var tokenPeriodLabel: String
  /// When the token total was measured. Nil means the card must not imply a
  /// live or recent reading.
  public var tokensCheckedAt: Date?
  /// Estimated list-price equivalent. Never an invoice or a charge.
  public var estimatedAPIEquivalentUSD: Double?
  public var generatedAt: Date
  /// When the quota percentages were measured. Nil must not look like "just now".
  public var quotaCheckedAt: Date?

  public init(
    providerName: String,
    planName: String?,
    windows: [UsageShareWindow],
    tokensUsed: Int64?,
    tokenPeriodLabel: String,
    tokensCheckedAt: Date?,
    estimatedAPIEquivalentUSD: Double?,
    generatedAt: Date,
    quotaCheckedAt: Date? = nil
  ) {
    self.providerName = providerName
    self.planName = planName
    self.windows = windows
    self.tokensUsed = tokensUsed
    self.tokenPeriodLabel = tokenPeriodLabel
    self.tokensCheckedAt = tokensCheckedAt
    self.estimatedAPIEquivalentUSD = estimatedAPIEquivalentUSD
    self.generatedAt = generatedAt
    self.quotaCheckedAt = quotaCheckedAt
  }

  /// Text and PNG both start here. The wording states the estimate plainly.
  public func plainText(now: Date = Date()) -> String {
    var lines = ["Reserve usage", self.providerName]
    if let planName, !planName.isEmpty {
      lines.append("Plan: \(planName)")
    }
    if self.windows.isEmpty {
      lines.append("Quota: unavailable")
    } else {
      if let checked = self.quotaCheckedAt {
        lines.append("Quota as of \(DashboardShareFormat.moment(checked))")
      } else if !self.windows.isEmpty {
        lines.append("Quota freshness unknown")
      }
      for window in self.windows {
        var line = window.label
        if let remaining = window.remainingPercent, remaining.isFinite {
          line += ": \(Int(remaining.rounded()))% left"
        } else {
          line += ": remaining unavailable"
        }
        if let resetsAt = window.resetsAt {
          line += ", resets \(DashboardShareFormat.moment(resetsAt))"
        }
        lines.append(line)
      }
    }
    if let tokensUsed {
      var line = "Tokens used, \(self.tokenPeriodLabel): \(DashboardShareFormat.tokens(tokensUsed))"
      if let checked = self.tokensCheckedAt {
        line += " (as of \(DashboardShareFormat.moment(checked)))"
      } else {
        line += " (freshness unknown)"
      }
      lines.append(line)
    }
    if let estimated = self.estimatedAPIEquivalentUSD, estimated.isFinite {
      lines.append(
        "Estimated API equivalent: \(DashboardShareFormat.money(estimated)). Not an actual charge.")
    } else {
      lines.append("Estimated API equivalent: unavailable. Not an actual charge.")
    }
    return lines.joined(separator: "\n")
  }
}

/// Formatting that does not depend on the AppKit dashboard.
enum DashboardShareFormat {
  static func tokens(_ value: Int64) -> String {
    let number = Double(value)
    if value >= 1_000_000_000 { return compact(number / 1_000_000_000, suffix: "B") }
    if value >= 1_000_000 { return compact(number / 1_000_000, suffix: "M") }
    if value >= 1_000 { return compact(number / 1_000, suffix: "K") }
    return String(value)
  }

  static func money(_ value: Double) -> String {
    guard value.isFinite else { return "unavailable" }
    return String(format: "$%.2f", max(0, value))
  }

  static func moment(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  private static func compact(_ value: Double, suffix: String) -> String {
    let digits = value >= 100 ? 0 : value >= 10 ? 1 : 2
    return String(format: "%.*f", digits, value) + suffix
  }
}

public enum UsageShareCardBuilder {
  /// Catalog names Reserve itself assigns. Anything else, including an email
  /// or organization stuffed into a plan field, is omitted.
  public static let allowedPlans: Set<String> = [
    "Free", "Plus", "Pro", "Pro+", "Team", "Business", "Enterprise", "Edu",
    "Max", "Max 5x", "Max 20x",
    "SuperGrok", "SuperGrok Heavy", "X Premium", "X Premium+",
    "Hobby", "Ultra",
    "Adagio", "Andante", "Moderato", "Allegretto", "Allegro",
    "GLM Coding Lite", "GLM Coding Pro", "GLM Coding Max",
  ]

  /// Fixed window titles. Provider text that does not match is dropped rather
  /// than copied, so a label cannot carry an email, org, or path.
  public static let allowedWindowLabels: Set<String> = [
    "Weekly", "Weekly limit", "5 hours", "5-hour window", "Session",
    "Daily", "Monthly", "Primary", "Build share",
  ]

  /// Always private. Dynamic strings are matched to fixed lists; unmatched
  /// text is omitted. `hidingPersonal` does not relax that.
  public static func model(
    provider: ProviderID,
    planName: String?,
    windows: [UsageWindow],
    tokensUsed: Int64?,
    tokenPeriodDays: Int?,
    tokensCheckedAt: Date?,
    estimatedAPIEquivalentUSD: Double?,
    generatedAt: Date,
    hidingPersonal: Bool,
    quotaCheckedAt: Date? = nil
  ) -> UsageShareModel {
    _ = hidingPersonal
    let safePlan = planName.flatMap { allowedPlans.contains($0) ? $0 : nil }
    let shareWindows = windows.prefix(6).compactMap { window -> UsageShareWindow? in
      guard let label = Self.normalizedWindowLabel(window.label) else { return nil }
      let remaining = 100 - window.usedPercent
      return UsageShareWindow(
        label: label,
        remainingPercent: remaining.isFinite ? min(100, max(0, remaining)) : nil,
        resetsAt: window.resetsAt)
    }
    let tokens = tokensUsed.flatMap { $0 >= 0 ? $0 : nil }
    let period = tokenPeriodDays.flatMap { $0 > 0 ? "last \($0) days" : nil } ?? "recorded period"
    let estimate = estimatedAPIEquivalentUSD.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    return UsageShareModel(
      providerName: provider.displayName,
      planName: safePlan,
      windows: shareWindows,
      tokensUsed: tokens,
      tokenPeriodLabel: period,
      tokensCheckedAt: tokens == nil ? nil : tokensCheckedAt,
      estimatedAPIEquivalentUSD: estimate,
      generatedAt: generatedAt,
      quotaCheckedAt: shareWindows.isEmpty ? nil : quotaCheckedAt)
  }

  static func normalizedWindowLabel(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if Self.allowedWindowLabels.contains(trimmed) {
      return trimmed == "Weekly" ? "Weekly limit" : trimmed == "5 hours" ? "5-hour window" : trimmed
    }
    let folded = trimmed.lowercased()
    if folded == "weekly" || folded == "weekly limit" { return "Weekly limit" }
    if folded == "5 hours" || folded == "5-hour window" || folded == "session" { return "5-hour window" }
    if folded == "daily" { return "Daily" }
    if folded == "monthly" { return "Monthly" }
    if folded == "primary" { return "Primary" }
    if folded == "build share" || folded == "grok build share" { return "Build share" }
    return nil
  }
}
