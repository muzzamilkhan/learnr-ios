import Foundation
import Security
import LearnrEngine

/// The bearer token in the Keychain.
///
/// The token is a `Session` row on the server with a hundred-year life, so it
/// is a long-lived secret: it belongs here rather than in UserDefaults.
/// `kSecAttrAccessibleAfterFirstUnlock` so a background sync can still reach it
/// on a locked device.
struct KeychainTokenStore: TokenStore {
    let service: String

    init(service: String = "com.learnr.ios.session") {
        self.service = service
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "session-token"]
    }

    func read() -> String? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(lookup as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    func write(_ token: String?) {
        SecItemDelete(query as CFDictionary)
        guard let token, let data = token.data(using: .utf8) else { return }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(insert as CFDictionary, nil)
    }
}
