import Foundation

public enum ApiError: Error, Equatable {
    /// The code was wrong, or the session behind the token has gone.
    case unauthorised
    /// The server could not read. Distinct from "nothing recorded" on purpose:
    /// the API answers 503 for a failed read and 200 [] for an empty one, and
    /// collapsing the two would show a database hiccup as "never practised".
    case couldNotRead(String)
    case notFound
    case badRequest(String)
    case transport(String)
    case decoding(String)
    case unexpectedStatus(Int)

    /// Whether retrying the same request later might work. The sync queue keeps
    /// anything retryable and drops the rest, so a permanently rejected attempt
    /// cannot wedge the queue behind it forever.
    public var isRetryable: Bool {
        switch self {
        case .transport, .couldNotRead: return true
        case .unauthorised, .notFound, .badRequest, .decoding, .unexpectedStatus: return false
        }
    }
}

/// Where the app keeps its bearer token.
///
/// A protocol so tests can hold one in memory; the app implements it over the
/// Keychain. The token is a `Session` row on the server with a hundred-year
/// life, so this is a long-lived secret and belongs nowhere else.
public protocol TokenStore: Sendable {
    func read() -> String?
    func write(_ token: String?)
}

public actor ApiClient {
    private let baseURL: URL
    private let session: URLSession
    private let tokens: any TokenStore

    public init(baseURL: URL, tokens: any TokenStore, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.session = session
    }

    public var isSignedIn: Bool { tokens.read() != nil }

    // MARK: Auth

    /// Trade a four-character code for a token. The whole of signing in.
    public func redeem(code: String) async throws -> RedeemResponse {
        let response: RedeemResponse = try await send(
            "POST", "/auth/redeem", body: RedeemRequest(code: code), authorised: false)
        tokens.write(response.token)
        return response
    }

    public func signOut() { tokens.write(nil) }

    public func me() async throws -> Account {
        try await send("GET", "/me")
    }

    // MARK: Play

    @discardableResult
    public func createSession(_ request: CreateSessionRequest) async throws -> SessionResponse {
        try await send("POST", "/sessions", body: request)
    }

    @discardableResult
    public func recordAttempts(sessionId: String, _ attempts: [AttemptPayload]) async throws -> AttemptResult {
        try await send("POST", "/sessions/\(sessionId)/attempts",
                       body: AttemptsRequest(attempts: attempts))
    }

    @discardableResult
    public func awardRound(sessionId: String) async throws -> AwardRoundResponse {
        try await send("POST", "/sessions/\(sessionId)/award-round", body: Empty())
    }

    @discardableResult
    public func awardTarget(sessionId: String, offsetMinutes: Int) async throws -> AwardTargetResponse {
        try await send("POST", "/sessions/\(sessionId)/award-target",
                       body: AwardTargetRequest(offsetMinutes: offsetMinutes))
    }

    public func endSession(sessionId: String) async throws {
        try await sendNoContent("POST", "/sessions/\(sessionId)/end")
    }

    // MARK: Speed

    @discardableResult
    public func submitSpeedRun(_ request: SpeedRunRequest) async throws -> SpeedOutcome {
        try await send("POST", "/speed/runs", body: request)
    }

    // MARK: Transport

    private struct Empty: Codable {}

    private func request(_ method: String, _ path: String, authorised: Bool) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw ApiError.transport("Bad path: \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if authorised, let token = tokens.read() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ApiError.transport("Not an HTTP response")
            }
            return (data, http)
        } catch let error as ApiError {
            throw error
        } catch {
            throw ApiError.transport(error.localizedDescription)
        }
    }

    private func check(_ data: Data, _ http: HTTPURLResponse) throws {
        switch http.statusCode {
        case 200...299: return
        case 401: throw ApiError.unauthorised
        case 404: throw ApiError.notFound
        case 400: throw ApiError.badRequest(message(from: data) ?? "Bad request")
        case 503: throw ApiError.couldNotRead(message(from: data) ?? "Could not read")
        default: throw ApiError.unexpectedStatus(http.statusCode)
        }
    }

    private func message(from data: Data) -> String? {
        (try? JSONDecoder().decode(ApiErrorBody.self, from: data))?.error
    }

    private func send<Response: Decodable>(
        _ method: String, _ path: String, authorised: Bool = true
    ) async throws -> Response {
        let (data, http) = try await perform(try request(method, path, authorised: authorised))
        try check(data, http)
        return try decode(data)
    }

    private func send<Body: Encodable, Response: Decodable>(
        _ method: String, _ path: String, body: Body, authorised: Bool = true
    ) async throws -> Response {
        var request = try request(method, path, authorised: authorised)
        request.httpBody = try JSONEncoder().encode(body)
        let (data, http) = try await perform(request)
        try check(data, http)
        return try decode(data)
    }

    private func sendNoContent(_ method: String, _ path: String) async throws {
        let (data, http) = try await perform(try request(method, path, authorised: true))
        try check(data, http)
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ApiError.decoding("\(T.self): \(error)")
        }
    }
}
