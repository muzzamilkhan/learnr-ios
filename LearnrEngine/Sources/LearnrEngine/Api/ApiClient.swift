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

    /// Everything the play screen needs before its first question.
    ///
    /// One call rather than five, which matters more on a phone than it did in
    /// the browser. Best-effort like the rest of the play path: a caller that
    /// cannot reach this should start the child on an empty profile rather than
    /// refuse to deal a question.
    public func playState(
        subject: String = "maths", level: YearLevel, recentTopics: Int = 5
    ) async throws -> PlayState {
        var components = URLComponents()
        components.path = "/play/state"
        components.queryItems = [
            URLQueryItem(name: "subject", value: subject),
            URLQueryItem(name: "level", value: level.rawValue),
            URLQueryItem(name: "recentTopics", value: String(recentTopics)),
        ]
        return try await send("GET", components.string ?? "/play/state")
    }

    /// The level this child last chose. A managed child's is their parent's to
    /// set, so this only ever confirms what the parent already decided.
    public func setLevel(_ level: YearLevel) async throws {
        try await sendNoContent("PUT", "/me/level", body: SetLevelRequest(level: level))
    }

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

    // MARK: Content

    /// The catalogue of what can be played, and the ETag of each level's pack.
    ///
    /// Small enough to fetch on every launch, which is the point: it is how a
    /// device finds out that a pack it has cached is stale without downloading
    /// every pack to check.
    public func contentManifest(ifNoneMatch etag: String? = nil) async throws -> Fetched<ContentManifest> {
        try await conditionalGet("/content/manifest", ifNoneMatch: etag)
    }

    /// One subject at one year level: the templates a session draws from.
    ///
    /// Authorised like everything else, but a pack is not personal - two
    /// children at the same level get the same bytes, which is what makes the
    /// ETag worth honouring.
    ///
    /// Returns the raw bytes as well as the decoded pack, because the cache
    /// stores what arrived rather than a re-encoding of it - see `CachedPack`.
    public func contentPack(
        subject: String, level: YearLevel, ifNoneMatch etag: String? = nil
    ) async throws -> Fetched<ContentPack> {
        try await conditionalGet("/content/\(subject)/\(level.rawValue)", ifNoneMatch: etag)
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
        request.httpBody = try ApiCoding.encoder().encode(body)
        let (data, http) = try await perform(request)
        try check(data, http)
        return try decode(data)
    }

    private func sendNoContent(_ method: String, _ path: String) async throws {
        let (data, http) = try await perform(try request(method, path, authorised: true))
        try check(data, http)
    }

    private func sendNoContent<Body: Encodable>(
        _ method: String, _ path: String, body: Body
    ) async throws {
        var request = try request(method, path, authorised: true)
        request.httpBody = try ApiCoding.encoder().encode(body)
        let (data, http) = try await perform(request)
        try check(data, http)
    }

    /// A GET that honours an ETag.
    ///
    /// Kept apart from `send` because 304 is not a failure here and `check`
    /// would treat it as one: a Not Modified says the caller's cached copy is
    /// current, which is the best possible answer and the whole reason the
    /// header was sent. The ETag comes back alongside the body so the caller
    /// can store it with what it cached.
    private func conditionalGet<Response: Decodable>(
        _ path: String, ifNoneMatch etag: String?
    ) async throws -> Fetched<Response> {
        var request = try request("GET", path, authorised: true)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        let (data, http) = try await perform(request)
        if http.statusCode == 304 { return .notModified }

        try check(data, http)
        // Header lookup is case-insensitive on iOS 13+, so "ETag" and "etag"
        // both land - the server sends the latter.
        let tag = http.value(forHTTPHeaderField: "ETag")
        return .fetched(try decode(data), etag: tag, data: data)
    }

    /// Every response body decodes here, which is what makes one date strategy
    /// enough. Ten contract fields carry `format: date-time`, and a bare
    /// `JSONDecoder()` reads none of them - see `ApiCoding`.
    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do {
            return try ApiCoding.decoder().decode(T.self, from: data)
        } catch {
            throw ApiError.decoding("\(T.self): \(error)")
        }
    }
}
