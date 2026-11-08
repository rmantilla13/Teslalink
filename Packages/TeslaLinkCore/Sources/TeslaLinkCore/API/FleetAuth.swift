import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct OAuthToken: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func isExpired(now: Date = Date(), leeway: TimeInterval = 300) -> Bool {
        expiresAt.timeIntervalSince(now) < leeway
    }
}

/// Persists tokens. The iOS app implements this with the Keychain.
public protocol TokenStore: Sendable {
    func load() -> OAuthToken?
    func save(_ token: OAuthToken?)
}

public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token: OAuthToken?
    public init(_ token: OAuthToken? = nil) { self.token = token }
    public func load() -> OAuthToken? { lock.lock(); defer { lock.unlock() }; return token }
    public func save(_ token: OAuthToken?) { lock.lock(); self.token = token; lock.unlock() }
}

/// Your app registration from developer.tesla.com.
public struct FleetAppConfig: Codable, Sendable, Equatable {
    public var clientID: String
    /// Tesla requires a client secret for the code exchange of third-party apps. Shipping it in an
    /// app binary is only acceptable for a personal, side-loaded build. See docs/FLEET_API_SETUP.md.
    public var clientSecret: String?
    public var redirectURI: String
    public var region: FleetRegion
    public var scopes: [String] = ["openid", "offline_access", "vehicle_device_data", "vehicle_location"]

    public init(clientID: String, clientSecret: String?, redirectURI: String, region: FleetRegion) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.region = region
    }
}

public struct PKCE: Sendable, Equatable {
    public var verifier: String
    public var challenge: String
    public var state: String

    public static func generate() -> PKCE {
        let verifier = randomURLSafe(bytes: 48)
        return PKCE(verifier: verifier, challenge: challenge(for: verifier), state: randomURLSafe(bytes: 16))
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(SHA256Digest.hash(Array(verifier.utf8)))
    }

    static func randomURLSafe(bytes n: Int) -> String {
        var g = SystemRandomNumberGenerator()
        return base64URL((0..<n).map { _ in UInt8.random(in: 0...255, using: &g) })
    }

    static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public enum AuthError: Error, Equatable, Sendable {
    case notSignedIn
    case stateMismatch
    case missingCode
    case tokenEndpoint(status: Int, body: String)
}

/// OAuth 2 (authorization code + PKCE) against Tesla's auth servers, with automatic refresh.
public actor FleetAuth: AccessTokenProvider {
    public static let authorizeURL = URL(string: "https://auth.tesla.com/oauth2/v3/authorize")!
    public static let tokenURL = URL(string: "https://fleet-auth.prd.vn.cloud.tesla.com/oauth2/v3/token")!

    public let config: FleetAppConfig
    private let store: TokenStore
    private let transport: HTTPTransport
    private var refreshTask: Task<OAuthToken, Error>?

    public init(config: FleetAppConfig, store: TokenStore, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.store = store
        self.transport = transport
    }

    public nonisolated var isSignedIn: Bool { store.load() != nil }

    public nonisolated func authorizationURL(pkce: PKCE) -> URL {
        var c = URLComponents(url: Self.authorizeURL, resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientID),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "scope", value: config.scopes.joined(separator: " ")),
            .init(name: "state", value: pkce.state),
            .init(name: "code_challenge", value: pkce.challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "prompt_missing_scopes", value: "true"),
        ]
        return c.url!
    }

    /// Call with the redirect URL Tesla sends back to the app.
    public func completeSignIn(callbackURL: URL, pkce: PKCE, now: Date = Date()) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard items.first(where: { $0.name == "state" })?.value == pkce.state else { throw AuthError.stateMismatch }
        guard let code = items.first(where: { $0.name == "code" })?.value else { throw AuthError.missingCode }
        var form = [
            "grant_type": "authorization_code",
            "client_id": config.clientID,
            "code": code,
            "code_verifier": pkce.verifier,
            "redirect_uri": config.redirectURI,
            "audience": config.region.apiBase.absoluteString,
        ]
        if let s = config.clientSecret, !s.isEmpty { form["client_secret"] = s }
        let token = try await requestToken(form, previousRefresh: nil, now: now)
        store.save(token)
    }

    public func signOut() { store.save(nil) }

    public func validAccessToken() async throws -> String {
        guard let t = store.load() else { throw AuthError.notSignedIn }
        if !t.isExpired() { return t.accessToken }
        return try await refresh().accessToken
    }

    public func forceRefresh() async throws -> String {
        try await refresh().accessToken
    }

    /// Coalesces concurrent refreshes; Tesla refresh tokens are single-use.
    private func refresh() async throws -> OAuthToken {
        if let refreshTask { return try await refreshTask.value }
        guard let t = store.load() else { throw AuthError.notSignedIn }
        let form = ["grant_type": "refresh_token", "client_id": config.clientID, "refresh_token": t.refreshToken]
        let task = Task { try await self.requestToken(form, previousRefresh: t.refreshToken, now: Date()) }
        refreshTask = task
        defer { refreshTask = nil }
        do {
            let new = try await task.value
            store.save(new)
            return new
        } catch AuthError.tokenEndpoint(let status, _) where status == 400 || status == 401 {
            store.save(nil)
            throw AuthError.notSignedIn
        }
    }

    private func requestToken(_ form: [String: String], previousRefresh: String?, now: Date) async throws -> OAuthToken {
        var req = URLRequest(url: Self.tokenURL)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&").utf8)
        let (data, http) = try await transport.send(req)
        guard (200..<300).contains(http.statusCode) else {
            throw AuthError.tokenEndpoint(status: http.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
        let r = try JSONDecoder().decode(FleetAPI.TokenResponse.self, from: data)
        guard let refresh = r.refresh_token ?? previousRefresh else { throw AuthError.tokenEndpoint(status: http.statusCode, body: "no refresh_token") }
        return OAuthToken(accessToken: r.access_token, refreshToken: refresh, expiresAt: now.addingTimeInterval(r.expires_in))
    }

    static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

/// SHA-256 for PKCE. Uses CryptoKit on Apple platforms, a small portable version elsewhere.
enum SHA256Digest {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        #if canImport(CryptoKit)
        return Array(SHA256.hash(data: message))
        #else
        return portable(message)
        #endif
    }

    static func portable(_ message: [UInt8]) -> [UInt8] {
        let k: [UInt32] = [
            0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
            0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
            0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
            0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
            0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
            0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
            0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
            0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
        ]
        var h: [UInt32] = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19]
        var msg = message
        let bitLen = UInt64(message.count) * 8
        msg.append(0x80)
        while msg.count % 64 != 56 { msg.append(0) }
        for i in (0..<8).reversed() { msg.append(UInt8((bitLen >> (UInt64(i) * 8)) & 0xff)) }

        func rotr(_ x: UInt32, _ n: UInt32) -> UInt32 { (x >> n) | (x << (32 - n)) }
        for chunk in stride(from: 0, to: msg.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let b = chunk + i * 4
                w[i] = UInt32(msg[b]) << 24 | UInt32(msg[b + 1]) << 16 | UInt32(msg[b + 2]) << 8 | UInt32(msg[b + 3])
            }
            for i in 16..<64 {
                let s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >> 3)
                let s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >> 10)
                w[i] = w[i - 16] &+ s0 &+ w[i - 7] &+ s1
            }
            var (a, b, c, d, e, f, g, hh) = (h[0], h[1], h[2], h[3], h[4], h[5], h[6], h[7])
            for i in 0..<64 {
                let s1 = rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)
                let ch = (e & f) ^ (~e & g)
                let t1 = hh &+ s1 &+ ch &+ k[i] &+ w[i]
                let s0 = rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let t2 = s0 &+ maj
                (hh, g, f, e, d, c, b, a) = (g, f, e, d &+ t1, c, b, a, t1 &+ t2)
            }
            h[0] &+= a; h[1] &+= b; h[2] &+= c; h[3] &+= d; h[4] &+= e; h[5] &+= f; h[6] &+= g; h[7] &+= hh
        }
        return h.flatMap { v in (0..<4).reversed().map { UInt8((v >> (UInt32($0) * 8)) & 0xff) } }
    }
}
