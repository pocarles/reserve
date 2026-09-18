import Foundation

#if canImport(Security)
  import Security
#endif

/// One pasted key kept as a generic-password item in the login Keychain. Both
/// the API-account keys and the plan keys use this; they differ only in the
/// service and account names, so the two kinds of key can never collide.
///
/// The key is never written to preferences, logs, snapshots or error text.
/// Error messages name the provider, never the value.
struct KeychainKeyStore: Sendable {
  let service: String
  let account: String
  /// Names the provider in messages and in the Keychain Access label.
  let displayName: String
  /// "API key", "Admin key"…, used in the missing-key message.
  let keyKind: String
  let label: String

  /// Paste often includes wrapping newlines. Those are stripped.
  static func normalized(_ key: String, displayName: String) throws -> String {
    let stored = String(key.filter { $0.isASCII && !$0.isWhitespace && !$0.isNewline })
    guard (16...1_200).contains(stored.count) else {
      throw UsageProviderError.credentialsNotFound(
        "\(displayName) needs a single-line API key.")
    }
    return stored
  }

  #if canImport(Security)
    func hasKey() -> Bool {
      SecItemCopyMatching(self.query(returningData: false) as CFDictionary, nil) == errSecSuccess
    }

    /// Replaces any key already stored for this item.
    func save(_ key: String) throws {
      let stored = try Self.normalized(key, displayName: self.displayName)
      let payload = Data(stored.utf8)
      let match = self.query(returningData: false) as CFDictionary
      let status: OSStatus
      if SecItemCopyMatching(match, nil) == errSecSuccess {
        status = SecItemUpdate(match, [kSecValueData as String: payload] as CFDictionary)
      } else {
        var attributes = self.query(returningData: false)
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = self.label
        status = SecItemAdd(attributes as CFDictionary, nil)
      }
      guard status == errSecSuccess else {
        throw UsageProviderError.credentialsNotFound(
          "macOS refused to store the \(self.displayName) key (\(status)).")
      }
    }

    func load() throws -> String {
      var result: CFTypeRef?
      let status = SecItemCopyMatching(self.query(returningData: true) as CFDictionary, &result)
      guard status != errSecItemNotFound else {
        throw UsageProviderError.credentialsNotFound(
          "No \(self.displayName) \(self.keyKind.lowercased()) is saved.")
      }
      guard status == errSecSuccess, let data = result as? Data,
        data.count <= 1_200, let key = String(data: data, encoding: .utf8), !key.isEmpty
      else {
        throw UsageProviderError.credentialsNotFound(
          "The saved \(self.displayName) key could not be read.")
      }
      return key
    }

    func delete() {
      SecItemDelete(self.query(returningData: false) as CFDictionary)
    }

    private func query(returningData: Bool) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: self.service,
        kSecAttrAccount as String: self.account,
      ]
      if returningData {
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
      }
      return query
    }
  #endif
}

/// Keys for plans connected with a pasted API key (Z.ai, Kimi). A separate
/// service from `APIConsumptionKeychain`, so a plan key and an API-account key
/// for related vendors (Kimi here, Moonshot there) are always separate items.
public enum PlanKeyKeychain {
  public static let service = "com.pocarles.reserve.plan-keys"

  public static func account(for provider: ProviderID) -> String {
    "plan-key.\(provider.rawValue)"
  }

  static func store(for provider: ProviderID) -> KeychainKeyStore {
    KeychainKeyStore(
      service: Self.service, account: Self.account(for: provider),
      displayName: provider.displayName, keyKind: "API key",
      label: "Reserve \(provider.displayName) plan key")
  }

  static func normalized(_ key: String, for provider: ProviderID) throws -> String {
    try KeychainKeyStore.normalized(key, displayName: provider.displayName)
  }

  #if canImport(Security)
    public static func hasKey(for provider: ProviderID) -> Bool {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return false }
      return Self.store(for: provider).hasKey()
    }

    /// Only providers that connect with a key have an item; the value never
    /// leaves this process except as the `Authorization` header on that
    /// provider's fixed host.
    public static func save(_ key: String, for provider: ProviderID) throws {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else {
        throw UsageProviderError.credentialsNotFound(
          "\(provider.displayName) does not connect with an API key.")
      }
      try Self.store(for: provider).save(key)
    }

    public static func load(for provider: ProviderID) throws -> String {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else {
        throw UsageProviderError.credentialsNotFound(
          "\(provider.displayName) does not connect with an API key.")
      }
      return try Self.store(for: provider).load()
    }

    public static func delete(for provider: ProviderID) {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
      Self.store(for: provider).delete()
    }
  #endif
}
