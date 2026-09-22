import Foundation

#if canImport(Security)
  import LocalAuthentication
  import Security
#endif

/// Whether a generic-password item can be used, is absent, or cannot be
/// inspected right now. Locked and interaction-blocked items stay unavailable
/// so a caller does not cache them as missing.
public enum KeychainItemAvailability: Equatable, Sendable {
  case present
  case missing
  case unavailable
}

/// Store-facing presence, including "not probed yet".
public enum SavedKeyAvailability: Equatable, Sendable {
  case unknown
  case present
  case missing
  case unavailable

  public init(_ availability: KeychainItemAvailability) {
    switch availability {
    case .present: self = .present
    case .missing: self = .missing
    case .unavailable: self = .unavailable
    }
  }
}

/// Maps Security status codes without calling SecItem. `errSecSuccess` is the
/// only present result; item-not-found is the only missing result.
public enum KeychainAccessClassification {
  public static func availability(for status: OSStatus) -> KeychainItemAvailability {
    switch status {
    case errSecSuccess:
      return .present
    case errSecItemNotFound:
      return .missing
    default:
      return .unavailable
    }
  }

  public static func temporaryMessage(displayName: String) -> String {
    "\(displayName) Keychain is temporarily unavailable. Reserve will try again."
  }

  public static func missingMessage(displayName: String, keyKind: String) -> String {
    "No \(displayName) \(keyKind.lowercased()) is saved."
  }
}

/// Serial background queue for every production SecItem call. Concurrency is
/// one. Closures must not retain or log the secret after they return.
enum KeychainAccessExecutor {
  private final class Queue: @unchecked Sendable {
    static let shared = Queue()
    let marker: DispatchSpecificKey<UInt8>
    let queue: DispatchQueue

    private init() {
      let marker = DispatchSpecificKey<UInt8>()
      let queue = DispatchQueue(label: "com.pocarles.reserve.keychain", qos: .utility)
      queue.setSpecific(key: marker, value: 1)
      self.marker = marker
      self.queue = queue
    }
  }

  static func sync<T>(_ body: () throws -> T) rethrows -> T {
    let queue = Queue.shared
    if DispatchQueue.getSpecific(key: queue.marker) != nil { return try body() }
    return try queue.queue.sync(execute: body)
  }

  static func run<T: Sendable>(_ body: @Sendable @escaping () throws -> T) async throws -> T {
    let queue = Queue.shared.queue
    return try await withCheckedThrowingContinuation { continuation in
      queue.async {
        do { continuation.resume(returning: try body()) }
        catch { continuation.resume(throwing: error) }
      }
    }
  }
}

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
      KeychainAccessExecutor.sync { self.probeOnExecutor() == .present }
    }

    func availability() -> KeychainItemAvailability {
      KeychainAccessExecutor.sync { self.probeOnExecutor() }
    }

    func availability() async -> KeychainItemAvailability {
      let store = self
      return (try? await KeychainAccessExecutor.run { store.probeOnExecutor() }) ?? .unavailable
    }

    /// Replaces any key already stored for this item.
    func save(_ key: String) throws {
      let store = self
      try KeychainAccessExecutor.sync { try store.saveOnExecutor(key) }
    }

    func save(_ key: String) async throws {
      let store = self
      try await KeychainAccessExecutor.run { try store.saveOnExecutor(key) }
    }

    func load() throws -> String {
      let store = self
      return try KeychainAccessExecutor.sync { try store.loadOnExecutor() }
    }

    func load() async throws -> String {
      let store = self
      return try await KeychainAccessExecutor.run { try store.loadOnExecutor() }
    }

    func delete() throws {
      let store = self
      try KeychainAccessExecutor.sync { try store.deleteOnExecutor() }
    }

    func delete() async throws {
      let store = self
      try await KeychainAccessExecutor.run { try store.deleteOnExecutor() }
    }

    /// Query used for silent probes. Background reads pass `allowInteraction`
    /// false so macOS returns immediately instead of prompting or hanging.
    func silentQuery(returningData: Bool) -> [String: Any] {
      self.query(returningData: returningData, allowInteraction: false)
    }

    func probeOnExecutor() -> KeychainItemAvailability {
      let status = SecItemCopyMatching(
        self.query(returningData: false, allowInteraction: false) as CFDictionary, nil)
      return KeychainAccessClassification.availability(for: status)
    }

    func saveOnExecutor(_ key: String) throws {
      let stored = try Self.normalized(key, displayName: self.displayName)
      let payload = Data(stored.utf8)
      let match = self.query(returningData: false, allowInteraction: false) as CFDictionary
      let existing = SecItemCopyMatching(match, nil)
      if KeychainAccessClassification.availability(for: existing) == .unavailable {
        throw UsageProviderError.unavailable(
          KeychainAccessClassification.temporaryMessage(displayName: self.displayName))
      }
      let status: OSStatus
      if existing == errSecSuccess {
        status = SecItemUpdate(match, [kSecValueData as String: payload] as CFDictionary)
      } else {
        var attributes = self.query(returningData: false, allowInteraction: false)
        attributes[kSecValueData as String] = payload
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrLabel as String] = self.label
        status = SecItemAdd(attributes as CFDictionary, nil)
      }
      if status == errSecSuccess { return }
      if KeychainAccessClassification.availability(for: status) == .unavailable {
        throw UsageProviderError.unavailable(
          KeychainAccessClassification.temporaryMessage(displayName: self.displayName))
      }
      throw UsageProviderError.credentialsNotFound(
        "macOS refused to store the \(self.displayName) key (\(status)).")
    }

    func loadOnExecutor() throws -> String {
      var result: CFTypeRef?
      let status = SecItemCopyMatching(
        self.query(returningData: true, allowInteraction: false) as CFDictionary, &result)
      switch KeychainAccessClassification.availability(for: status) {
      case .missing:
        throw UsageProviderError.credentialsNotFound(
          KeychainAccessClassification.missingMessage(
            displayName: self.displayName, keyKind: self.keyKind))
      case .unavailable:
        throw UsageProviderError.unavailable(
          KeychainAccessClassification.temporaryMessage(displayName: self.displayName))
      case .present:
        guard let data = result as? Data, data.count <= 1_200,
          let key = String(data: data, encoding: .utf8), !key.isEmpty
        else {
          throw UsageProviderError.credentialsNotFound(
            "The saved \(self.displayName) key could not be read.")
        }
        return key
      }
    }

    func deleteOnExecutor() throws {
      let status = SecItemDelete(
        self.query(returningData: false, allowInteraction: false) as CFDictionary)
      guard status == errSecSuccess || status == errSecItemNotFound else {
        throw UsageProviderError.unavailable(
          KeychainAccessClassification.temporaryMessage(displayName: self.displayName))
      }
    }

    private func query(returningData: Bool, allowInteraction: Bool) -> [String: Any] {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: self.service,
        kSecAttrAccount as String: self.account,
      ]
      if returningData {
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
      }
      if !allowInteraction {
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
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

  public static func normalized(_ key: String, for provider: ProviderID) throws -> String {
    try KeychainKeyStore.normalized(key, displayName: provider.displayName)
  }

  #if canImport(Security)
    public static func hasKey(for provider: ProviderID) -> Bool {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return false }
      return Self.store(for: provider).hasKey()
    }

    public static func availability(for provider: ProviderID) -> KeychainItemAvailability {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return .missing }
      return Self.store(for: provider).availability()
    }

    public static func availability(for provider: ProviderID) async -> KeychainItemAvailability {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return .missing }
      return await Self.store(for: provider).availability()
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

    public static func save(_ key: String, for provider: ProviderID) async throws {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else {
        throw UsageProviderError.credentialsNotFound(
          "\(provider.displayName) does not connect with an API key.")
      }
      try await Self.store(for: provider).save(key)
    }

    public static func load(for provider: ProviderID) throws -> String {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else {
        throw UsageProviderError.credentialsNotFound(
          "\(provider.displayName) does not connect with an API key.")
      }
      return try Self.store(for: provider).load()
    }

    public static func load(for provider: ProviderID) async throws -> String {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else {
        throw UsageProviderError.credentialsNotFound(
          "\(provider.displayName) does not connect with an API key.")
      }
      return try await Self.store(for: provider).load()
    }

    public static func delete(for provider: ProviderID) throws {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
      try Self.store(for: provider).delete()
    }

    public static func delete(for provider: ProviderID) async throws {
      guard ProviderDescriptor.forProvider(provider).usesAPIKey else { return }
      try await Self.store(for: provider).delete()
    }
  #endif
}
