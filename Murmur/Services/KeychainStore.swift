import Foundation
import Security

/// Minimal generic-password wrapper around the login Keychain. The service
/// name is injectable so tests can use a throwaway service and never touch
/// the app's real items.
struct KeychainStore: Sendable {
    let service: String

    func read(account: String) -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Stores `value`, replacing any existing item. An empty value deletes
    /// the item. Returns false when the Keychain refused the operation.
    @discardableResult
    func write(_ value: String, account: String) -> Bool {
        guard !value.isEmpty else { return delete(account: account) }
        let data = Data(value.utf8)
        let query = baseQuery(account: account)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return true }
        guard status == errSecItemNotFound else { return false }
        var attributes = query
        attributes[kSecValueData as String] = data
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    /// Returns true when the item is gone afterwards (deleted or never there).
    @discardableResult
    func delete(account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Where the LLM corrector's API key lives. It used to be a plain
/// `UserDefaults` string (`localLLMAPIKey`), readable by anything that can
/// read the app's preferences plist; it now lives in the Keychain.
enum LLMAPIKeyStore {
    /// The old `UserDefaults` key; also the Keychain account name.
    static let legacyDefaultsKey = "localLLMAPIKey"
    static let keychain = KeychainStore(service: "com.murmur.app")

    /// The stored key, or nil when none is set. Moves a key left in
    /// `UserDefaults` by an earlier version into the Keychain first.
    static func current(
        keychain: KeychainStore = LLMAPIKeyStore.keychain,
        defaults: UserDefaults = .standard
    ) -> String? {
        migrateLegacyValue(keychain: keychain, defaults: defaults)
        guard let key = keychain.read(account: legacyDefaultsKey), !key.isEmpty else { return nil }
        return key
    }

    /// Stores `key`; an empty string removes the stored key.
    @discardableResult
    static func save(_ key: String, keychain: KeychainStore = LLMAPIKeyStore.keychain) -> Bool {
        keychain.write(key, account: legacyDefaultsKey)
    }

    /// One-time move of the plaintext value into the Keychain. The plaintext
    /// copy is removed only once the Keychain holds a key, so a refused
    /// Keychain write never loses the user's key.
    static func migrateLegacyValue(
        keychain: KeychainStore = LLMAPIKeyStore.keychain,
        defaults: UserDefaults = .standard
    ) {
        guard let legacy = defaults.string(forKey: legacyDefaultsKey) else { return }
        if !legacy.isEmpty, keychain.read(account: legacyDefaultsKey) == nil {
            guard keychain.write(legacy, account: legacyDefaultsKey) else { return }
        }
        defaults.removeObject(forKey: legacyDefaultsKey)
    }
}
