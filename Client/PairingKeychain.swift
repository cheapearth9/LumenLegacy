import Foundation
import Security

/// Long-term pairing secrets (32 bytes) stored per host in the iOS Keychain.
enum PairingKeychain {
    private static let service = "dev.lumen.client.pairing"

    private static func base(_ host: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: host]
    }

    static func load(host: String) -> Data? {
        var q = base(host)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data, data.count == 32 else { return nil }
        return data
    }

    static func save(_ key: Data, host: String) {
        let update: [String: Any] = [kSecValueData as String: key]
        let status = SecItemUpdate(base(host) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = base(host)
            add[kSecValueData as String] = key
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(host: String) {
        SecItemDelete(base(host) as CFDictionary)
    }
}
