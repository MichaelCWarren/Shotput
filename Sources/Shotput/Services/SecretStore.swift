import Foundation
import Security

/// Storage for the app's secrets, injectable so tests never reach the
/// developer's login keychain.
protocol SecretStore {
    func secret(for account: String) -> String?
    @discardableResult func setSecret(_ value: String, for account: String) -> Bool
    @discardableResult func removeSecret(for account: String) -> Bool
}

/// Generic-password items in the login keychain, one per account name.
struct KeychainSecretStore: SecretStore {
    let service: String

    init(service: String = "com.shotput.app") {
        self.service = service
    }

    func secret(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    func setSecret(_ value: String, for account: String) -> Bool {
        guard let data = value.data(using: .utf8) else { return false }

        let updated = SecItemUpdate(baseQuery(account) as CFDictionary, Self.updateAttributes(data) as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }

        var insert = baseQuery(account)
        insert.merge(Self.addAttributes(data)) { _, new in new }
        return SecItemAdd(insert as CFDictionary, nil) == errSecSuccess
    }

    /// An update replaces the secret and nothing else. Accessibility belongs
    /// to the item as created, and an update that restates it risks being
    /// rejected outright, which would fail every save after the first.
    static func updateAttributes(_ data: Data) -> [String: Any] {
        [kSecValueData as String: data]
    }

    /// The file-based login keychain ignores `kSecAttrAccessible`, so this
    /// buys nothing today. Keep it: it is what the item needs once the app
    /// is signed and moves to the data-protection keychain.
    static func addAttributes(_ data: Data) -> [String: Any] {
        [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }

    @discardableResult
    func removeSecret(for account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
