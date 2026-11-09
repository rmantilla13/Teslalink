import Foundation

// Linking Tesla accounts: what the app reads from Tesla's tokens, which region an account
// belongs to, the one-tap setup link for a developer app, and which account polls which car.

/// The claims TeslaLink reads from Tesla's tokens (JWTs): who the account is, which region it
/// lives in and, when a token carries them, an email and name. The signature isn't checked:
/// these only label accounts and pick a region, never decide trust. Tesla doesn't document
/// the claims, so every one is optional and a token that isn't a JWT simply has none.
public struct TokenClaims: Equatable, Sendable {
    public var subject: String?
    /// Tesla's region code in access tokens (`ou_code`): "NA", "EU" or "CN".
    public var regionCode: String?
    public var email: String?
    public var name: String?

    public init(subject: String? = nil, regionCode: String? = nil, email: String? = nil, name: String? = nil) {
        self.subject = subject
        self.regionCode = regionCode
        self.email = email
        self.name = name
    }

    /// nil when `jwt` isn't a token with a readable JSON payload.
    public init?(jwt: String) {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let data = Self.base64URLDecode(String(parts[1])),
              let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func text(_ key: String) -> String? {
            guard let value = (payload[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        self.init(subject: text("sub"), regionCode: text("ou_code"), email: text("email"), name: text("name"))
    }

    /// The access token's claims, with the ID token's filling any gaps (it may carry the email).
    public static func combined(accessToken: String, idToken: String?) -> TokenClaims? {
        let access = TokenClaims(jwt: accessToken)
        let id = idToken.flatMap(TokenClaims.init(jwt:))
        guard access != nil || id != nil else { return nil }
        return TokenClaims(subject: access?.subject ?? id?.subject,
                           regionCode: access?.regionCode ?? id?.regionCode,
                           email: access?.email ?? id?.email,
                           name: access?.name ?? id?.name)
    }

    public var region: FleetRegion? { regionCode.flatMap(FleetRegion.init(teslaCode:)) }

    static func base64URLDecode(_ s: String) -> Data? {
        var b64 = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}

extension FleetRegion {
    /// From Tesla's region code ("NA", "EU", "CN"; any case).
    public init?(teslaCode: String) {
        switch teslaCode.trimmingCharacters(in: .whitespaces).lowercased() {
        case "na": self = .northAmericaAsiaPacific
        case "eu": self = .europeMiddleEastAfrica
        case "cn": self = .china
        default: return nil
        }
    }

    /// The region a phone set to this country most likely signs in to. Tesla keeps accounts in
    /// three regions: North America with Asia-Pacific, Europe with the Middle East and Africa,
    /// and China. It takes codes, so it needs no locale data: `country` is ISO 3166 ("DE");
    /// `continent` and `subregion` are UN M49 ("150" Europe, "002" Africa, "145" Western
    /// Asia), as `Locale.Region` reports them.
    public static func suggested(country: String?, continent: String?, subregion: String?) -> FleetRegion {
        if country?.uppercased() == "CN" { return .china }
        if continent == "150" || continent == "002" || subregion == "145" { return .europeMiddleEastAfrica }
        return .northAmericaAsiaPacific
    }
}

/// `teslalink://setup?client_id=…&client_secret=…&redirect_uri=…&region=…`: a developer app's
/// details in one link, printed by scripts/register-partner.sh, so setting up the phone is a
/// tap (or a QR scan) instead of typing. It carries the client secret, and any app or web
/// page can open a `teslalink://` link, so the app always shows what it would change and asks.
public struct FleetSetupLink: Equatable, Sendable {
    public static let scheme = "teslalink"
    /// The redirect registered in Info.plist: Tesla's sign-in comes straight back to the app.
    public static let appRedirectURI = "teslalink://auth/callback"

    public var clientID: String
    public var clientSecret: String?
    public var redirectURI: String
    public var region: FleetRegion?

    public init(clientID: String, clientSecret: String?, redirectURI: String = FleetSetupLink.appRedirectURI, region: FleetRegion? = nil) {
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.region = region
    }

    /// nil unless it's a well-formed setup link with a client ID and a usable redirect.
    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == Self.scheme, parts.host?.lowercased() == "setup" else { return nil }
        let items = parts.queryItems ?? []
        func value(_ name: String) -> String? {
            guard let v = items.first(where: { $0.name == name })?.value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty, v.count <= 512,
                  !v.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == " " }) else { return nil }
            return v
        }
        guard let id = value("client_id") else { return nil }
        let redirect = value("redirect_uri") ?? Self.appRedirectURI
        guard Self.isUsableRedirect(redirect) else { return nil }
        self.init(clientID: id, clientSecret: value("client_secret"), redirectURI: redirect,
                  region: value("region").flatMap(FleetRegion.init(teslaCode:)))
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "setup"
        var items = [URLQueryItem(name: "client_id", value: clientID)]
        if let clientSecret { items.append(URLQueryItem(name: "client_secret", value: clientSecret)) }
        items.append(URLQueryItem(name: "redirect_uri", value: redirectURI))
        if let region { items.append(URLQueryItem(name: "region", value: region.rawValue)) }
        // Encode what URLComponents leaves alone in queries, so secrets survive any reader.
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        parts.percentEncodedQueryItems = items.map {
            URLQueryItem(name: $0.name, value: $0.value?.addingPercentEncoding(withAllowedCharacters: allowed))
        }
        return parts.url!
    }

    /// True when Tesla's sign-in comes back to this app. Any other address receives the
    /// authorization code, so the app warns before accepting it.
    public var returnsToApp: Bool { Self.scheme(of: redirectURI) == Self.scheme }

    /// `teslalink://…` or an `https://` universal link (see docs/FLEET_API_SETUP.md).
    public static func isUsableRedirect(_ uri: String) -> Bool {
        guard let scheme = scheme(of: uri), let parts = URLComponents(string: uri), parts.host?.isEmpty == false else { return false }
        return scheme == Self.scheme || scheme == "https"
    }

    static func scheme(of uri: String) -> String? { URLComponents(string: uri)?.scheme?.lowercased() }
}

/// Which linked account polls each car.
public enum AccountRouting {
    /// In link order: a car shared between accounts (a second driver's) is polled once, by the
    /// account linked first.
    public static func owners(_ accounts: [(id: String, vins: [String])]) -> [String: String] {
        var owner: [String: String] = [:]
        for account in accounts {
            for vin in account.vins where owner[vin] == nil { owner[vin] = account.id }
        }
        return owner
    }

    /// An account already linked with exactly these cars: the same Tesla user signing in again,
    /// for tokens without a subject to tell accounts apart.
    public static func match(vins: [String], in accounts: [(id: String, vins: [String])]) -> String? {
        let cars = Set(vins)
        guard !cars.isEmpty else { return nil }
        return accounts.first { Set($0.vins) == cars }?.id
    }
}
