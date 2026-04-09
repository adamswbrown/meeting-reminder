import Foundation
import Security

/// Simple Keychain wrapper for storing app secrets under the
/// `com.meetingreminder.app` service.
///
/// Uses the legacy file-based keychain with a permissive ACL
/// (`SecAccessCreate` with no trusted-app restrictions) so the item
/// is readable regardless of which code-signing identity built the
/// app. This matters because Debug (adhoc) and Release (Developer ID)
/// have different identities.
enum KeychainHelper {
    private static let service = "com.meetingreminder.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        delete(key: key)

        // Create an access object that allows any application to read.
        // Passing nil for trustedApplications means "any app" (no ACL).
        // Passing [] would mean "no apps trusted" — prompts every time.
        var access: SecAccess?
        SecAccessCreate("MeetingReminder" as CFString, nil, &access)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecAttrService as String: service,
            kSecValueData as String: data,
        ]
        if let access { query[kSecAttrAccess as String] = access }

        let status = SecItemAdd(query as CFDictionary, nil)
        if status != errSecSuccess {
            print("[KeychainHelper] save failed: \(status)")
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
