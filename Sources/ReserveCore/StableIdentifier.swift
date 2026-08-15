import CryptoKit
import Foundation

public enum StableIdentifier {
  /// A fixed 32-character component suitable for notification identifiers.
  public static func notificationComponent(_ value: String) -> String {
    let bounded = String(value.prefix(UsageWindow.maximumIdentifierCharacters))
    return SHA256.hash(data: Data(bounded.utf8)).prefix(16)
      .map { String(format: "%02x", $0) }.joined()
  }
}
