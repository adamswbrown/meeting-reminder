import Foundation
import Security

/// Simple Keychain wrapper for storing app secrets under the
/// `com.meetingreminder.app` service.
enum KeychainHelper {
    private static let service = "com.meetingreminder.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Try update first; only add if the item doesn't exist yet.
        // Never delete-then-add: a failed add after a successful delete
        // permanently destroys the stored secret (e.g. Graph refresh token).
        let lookup: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]

        let updateStatus = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it.
            var addQuery = lookup
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[KeychainHelper] add failed for key '\(key)': \(addStatus)")
            }
        } else {
            print("[KeychainHelper] update failed for key '\(key)': \(updateStatus)")
        }
    }

    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
