import Foundation

/// Strict parser for the two Retry-After forms defined by HTTP. Future
/// deadlines are preserved exactly: turning a long server deadline into a
/// short local fallback would cause Reserve to retry too early.
enum HTTPRetryAfter {
  static func deadline(from header: String?, now: Date) -> Date? {
    guard let raw = header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    if let seconds = TimeInterval(raw), seconds.isFinite, seconds > 0 {
      let deadline = now.addingTimeInterval(seconds)
      return deadline.timeIntervalSinceReferenceDate.isFinite ? deadline : nil
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    guard let date = formatter.date(from: raw), date > now,
      date.timeIntervalSinceReferenceDate.isFinite
    else { return nil }
    return date
  }
}
