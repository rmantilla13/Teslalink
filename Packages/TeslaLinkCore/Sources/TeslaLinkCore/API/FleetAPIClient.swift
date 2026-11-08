import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum FleetRegion: String, Codable, Sendable, CaseIterable {
    case northAmericaAsiaPacific = "na", europeMiddleEastAfrica = "eu", china = "cn"

    public var apiBase: URL {
        switch self {
        case .northAmericaAsiaPacific: URL(string: "https://fleet-api.prd.na.vn.cloud.tesla.com")!
        case .europeMiddleEastAfrica: URL(string: "https://fleet-api.prd.eu.vn.cloud.tesla.com")!
        case .china: URL(string: "https://fleet-api.prd.cn.vn.cloud.tesla.cn")!
        }
    }

    public var displayName: String {
        switch self {
        case .northAmericaAsiaPacific: "North America / Asia-Pacific"
        case .europeMiddleEastAfrica: "Europe / Middle East / Africa"
        case .china: "China"
        }
    }
}

public enum FleetAPIError: Error, Equatable, Sendable {
    case unauthorized
    /// 408: the vehicle is asleep or offline and can't answer vehicle_data.
    case vehicleUnavailable
    case rateLimited(retryAfter: TimeInterval?)
    case http(status: Int, body: String)
    case decoding(String)
    case noResponse
}

/// Minimal transport so the client is testable without the network.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            session.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let http = response as? HTTPURLResponse else { cont.resume(throwing: FleetAPIError.noResponse); return }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }
}

/// Supplies a valid access token, refreshing when needed (implemented by `FleetAuth`).
public protocol AccessTokenProvider: Sendable {
    func validAccessToken() async throws -> String
    func forceRefresh() async throws -> String
}

/// Read-only Tesla Fleet API client. It never sends commands to the car.
public struct FleetAPIClient: Sendable {
    public var region: FleetRegion
    let tokens: AccessTokenProvider
    let transport: HTTPTransport

    /// Location requires the `location_data` endpoint on current firmware.
    public static let dataEndpoints = "charge_state;climate_state;drive_state;location_data;vehicle_config;vehicle_state"

    public init(region: FleetRegion, tokens: AccessTokenProvider, transport: HTTPTransport = URLSessionTransport()) {
        self.region = region
        self.tokens = tokens
        self.transport = transport
    }

    public func vehicles() async throws -> [FleetAPI.VehicleSummary] {
        try await get("/api/1/vehicles", as: [FleetAPI.VehicleSummary].self)
    }

    /// Connectivity only. Does **not** wake the car, so it's the right call while letting it sleep.
    public func status(vin: String) async throws -> OnlineState {
        let v = try await get("/api/1/vehicles/\(vin)", as: FleetAPI.VehicleSummary.self)
        return OnlineState(rawValue: v.state ?? "") ?? .offline
    }

    /// Full data. Keeps an awake car awake; fails with `.vehicleUnavailable` if it's asleep.
    public func vehicleData(vin: String, now: Date = Date()) async throws -> VehicleSnapshot {
        let raw = try await get("/api/1/vehicles/\(vin)/vehicle_data", query: [URLQueryItem(name: "endpoints", value: Self.dataEndpoints)],
                                as: FleetAPI.VehicleData.self)
        return VehicleSnapshot(raw, receivedAt: now)
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as: T.Type, retried: Bool = false) async throws -> T {
        var comps = URLComponents(url: region.apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 30
        let token = retried ? try await tokens.forceRefresh() : try await tokens.validAccessToken()
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, http) = try await transport.send(req)
        switch http.statusCode {
        case 200..<300:
            do {
                let env = try JSONDecoder().decode(FleetAPI.Envelope<T>.self, from: data)
                guard let r = env.response else { throw FleetAPIError.decoding(env.error ?? "empty response") }
                return r
            } catch let e as FleetAPIError {
                throw e
            } catch {
                throw FleetAPIError.decoding(String(describing: error))
            }
        case 401 where !retried:
            return try await get(path, query: query, as: T.self, retried: true)
        case 401: throw FleetAPIError.unauthorized
        case 408: throw FleetAPIError.vehicleUnavailable
        case 429:
            let after = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw FleetAPIError.rateLimited(retryAfter: after)
        default:
            throw FleetAPIError.http(status: http.statusCode, body: String(decoding: data.prefix(500), as: UTF8.self))
        }
    }
}
