import Foundation
import Security
import TeslaLinkCore

/// One linked Tesla account. Its token is in the Keychain under `tokenKey`.
struct TeslaAccount: Codable, Identifiable, Equatable {
    /// The token's subject, or a generated ID when the token carries none.
    var id: String
    /// The Tesla user behind it (the token's `sub`), when the token says. Reconnect only
    /// accepts a sign-in by the same user.
    var subject: String?
    var region: FleetRegion
    var email: String?
    var name: String?
    /// The cars it listed at the last refresh, so the switcher is right before the next one.
    var vins: [String] = []
    var addedAt = Date()

    var tokenKey: String { "account.\(id)" }

    /// The email or name from Tesla's token, when it gave one.
    var title: String? { email ?? name }
}

/// Where linked accounts are saved: beside the settings, not in them. A settings change
/// reconfigures the app, and the account list changes with every vehicle refresh.
enum AccountStore {
    private static let key = "app.accounts.v1"

    static func load() -> [TeslaAccount] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let accounts = try? JSONDecoder().decode([TeslaAccount].self, from: data) else { return [] }
        return accounts
    }

    static func save(_ accounts: [TeslaAccount]) {
        if let data = try? JSONEncoder().encode(accounts) { UserDefaults.standard.set(data, forKey: key) }
    }
}

/// How a linked account is doing, for Settings.
enum AccountStatus: Equatable {
    case connected
    /// Tesla no longer accepts its sign-in.
    case needsReconnect
    case problem(String)
}

/// An account's auth and API client, made once per account and kept (see `AppModel.links`).
struct AccountLink {
    let auth: FleetAuth
    let client: FleetAPIClient
}

/// A sign-in in progress: Tesla's page is open, and its token goes to an in-memory store until
/// the app knows which account it belongs to.
struct PendingSignIn {
    let auth: FleetAuth
    let pkce: PKCE
    let region: FleetRegion
    /// Where Tesla's page sends the browser back to, for the web authentication session.
    let redirectURI: String
    /// The account being renewed (Reconnect), or nil to link a new one.
    let reconnecting: String?
    /// The second try, after Tesla put the account in another region. There's never a third.
    let isRegionRetry: Bool
}

/// The account sign-in returned, and whether it needs a second try in another region.
enum SignInOutcome: Equatable {
    case linked
    /// Tesla keeps the account in another region: sign in once more there.
    case wrongRegion(FleetRegion)
    case failed(String)
}

/// A setup link waiting for the user to accept it (see `SetupLinkReview`).
struct SetupLinkRequest: Identifiable {
    let id = UUID()
    let link: FleetSetupLink
}

/// The developer app's client secret from setup, kept with the client ID it belongs to: a
/// secret is only ever sent with that client ID (a Keychain item outlives a reinstall, and a
/// build can bring its own app).
struct DeveloperSecret: Codable, Equatable {
    var clientID: String
    var secret: String

    private static let store = KeychainValue(service: "com.teslalink.developer-app", account: "secret-for-client")

    static func load() -> DeveloperSecret? {
        store.load().flatMap { try? JSONDecoder().decode(DeveloperSecret.self, from: Data($0.utf8)) }
    }

    /// nil (or an empty secret) removes it.
    static func save(_ value: DeveloperSecret?) {
        guard let value, !value.secret.isEmpty, let data = try? JSONEncoder().encode(value) else {
            store.save(nil)
            return
        }
        store.save(String(decoding: data, as: UTF8.self))
    }
}

/// One string in the Keychain, readable after first unlock (background refresh needs it).
struct KeychainValue {
    let service: String
    let account: String

    func load() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil or empty removes it.
    func save(_ value: String?) {
        SecItemDelete(baseQuery as CFDictionary)
        guard let value, !value.isEmpty else { return }
        var item = baseQuery
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    private var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
