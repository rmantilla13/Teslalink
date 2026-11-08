import Foundation
import Security
import TeslaLinkCore

/// Tokens live in the Keychain, readable after first unlock so background refresh works
/// while the phone is locked in your pocket.
final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let service = "com.teslalink.fleet-token"
    private let account: String

    init(account: String = "default") { self.account = account }

    func load() -> OAuthToken? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(OAuthToken.self, from: data)
    }

    func save(_ token: OAuthToken?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let token, let data = try? JSONEncoder().encode(token) else { return }
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
