import Testing
import Foundation
import LearnrEngine
@testable import LearnrApp

/// What a launch does with the token it already has.
///
/// The rule these pin comes from ledger `L17`, and it is one line: **only a 401
/// from a server that actually answered may sign a child out**. Everything else
/// - no network, a timeout, a 5xx, the 503 `GET /me` declares for a failed
/// account read - means *could not read*, and reading that as *not signed in*
/// strands a child at the code-entry screen asking for a four-character code
/// that only their parent can issue.
///
/// `Session.restore()` had the reasoning right in a comment and the code wrong
/// underneath it: the general `catch` set `.signedOut` regardless. Nothing
/// covered `restore()` at all, which is how the two disagreed in peace.
@MainActor
struct SessionRestoreTests {

    /// A token store that starts holding one, so `restore()` gets past its
    /// first guard and actually calls `GET /me`.
    final class Tokens: TokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ token: String? = "a-token") { self.token = token }
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return token }
        func write(_ new: String?) { lock.lock(); defer { lock.unlock() }; token = new }
    }

    /// The queue and the library are not what these tests are about; they only
    /// have to exist and keep nothing.
    struct NoSittings: SittingStore {
        func load() -> [PendingSitting] { [] }
        func save(_ sittings: [PendingSitting]) {}
    }

    struct NoPacks: PackStore {
        func load(subject: String, level: YearLevel) -> CachedPack? { nil }
        func save(_ cached: CachedPack) {}
    }

    final class Cache: AccountCache, @unchecked Sendable {
        private let lock = NSLock()
        private var account: Account?
        private(set) var cleared = false
        init(_ account: Account? = nil) { self.account = account }
        func read() -> Account? { lock.lock(); defer { lock.unlock() }; return account }
        func write(_ new: Account?) {
            lock.lock(); defer { lock.unlock() }
            if new == nil { cleared = true }
            account = new
        }
    }

    /// Answers `GET /me` with whatever the test needs, including nothing.
    final class MeProtocol: URLProtocol, @unchecked Sendable {
        /// nil status means "the request never arrives" - a transport failure,
        /// which is a different thing from any reply the server could send.
        nonisolated(unsafe) static var replies: [String: Int?] = [:]
        static let lock = NSLock()
        static let keyHeader = "X-Me-Key"

        static func session(_ status: Int?) -> (URLSession, String) {
            let key = UUID().uuidString
            lock.lock(); replies[key] = status; lock.unlock()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MeProtocol.self]
            config.httpAdditionalHeaders = [keyHeader: key]
            return (URLSession(configuration: config), key)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: keyHeader) != nil
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
            Self.lock.lock(); let status = Self.replies[key] ?? nil; Self.lock.unlock()

            guard let status else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }

            let body: Data
            switch status {
            case 200: body = Data(#"{"id":"c1","role":"child","parentId":"p1","name":"Ada","avatar":null,"image":null,"photo":null}"#.utf8)
            case 401: body = Data(#"{"error":"Not signed in"}"#.utf8)
            default:  body = Data(#"{"error":"Could not read the account"}"#.utf8)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// `role` reads through `value1`: it is an `allOf`-wrapped `$ref`, which is
    /// what lets the null the contract permits decode to nil (ledger `L24`).
    static let cached = Account(
        id: "c1", role: .init(value1: .child), parentId: "p1", name: "Ada",
        avatar: nil, image: nil, photo: nil)

    /// Builds a session whose `GET /me` answers with `status`, or fails at the
    /// transport when it is nil.
    static func session(
        answering status: Int?, cache: Cache, tokens: Tokens = Tokens()
    ) -> Session {
        let (urlSession, _) = MeProtocol.session(status)
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: tokens,
            session: urlSession)
        return Session(
            api: api,
            queue: SyncQueue(api: api, store: NoSittings()),
            library: ContentLibrary(api: api, store: NoPacks()),
            accounts: cache)
    }

    // MARK: The one case that signs out

    @Test("a 401 signs the child out and forgets them")
    func unauthorisedSignsOut() async {
        let cache = Cache(Self.cached)
        let tokens = Tokens()
        let session = Self.session(answering: 401, cache: cache, tokens: tokens)

        await session.restore()

        // The server answered, and it said this token is nobody's. That is the
        // one fact that justifies asking a child for a new code.
        #expect(session.state == .signedOut)
        #expect(tokens.read() == nil)
        // The name goes too: the next child to sign in on this device must not
        // be greeted as the last one.
        #expect(cache.cleared)
    }

    // MARK: The cases that must not

    @Test("an offline launch keeps the child signed in, under the cached account")
    func offlineKeepsTheChildSignedIn() async {
        let cache = Cache(Self.cached)
        let session = Self.session(answering: nil, cache: cache)

        await session.restore()

        // The whole point of L17: no network is not a sign-out.
        #expect(session.state == .signedIn(Self.cached))
        // And they are greeted by name, exactly as though nothing were wrong.
        if case .signedIn(let account) = session.state {
            #expect(account.name == "Ada")
        }
    }

    @Test("a 503 from GET /me keeps the child signed in")
    func couldNotReadKeepsTheChildSignedIn() async {
        let cache = Cache(Self.cached)
        let tokens = Tokens()
        let session = Self.session(answering: 503, cache: cache, tokens: tokens)

        await session.restore()

        // The route declares 503 for exactly this: the session resolved, the
        // account read failed. Signed in, unreadable - not signed out.
        #expect(session.state == .signedIn(Self.cached))
        #expect(tokens.read() == "a-token")
        #expect(cache.cleared == false)
    }

    @Test("an unexpected status keeps the child signed in")
    func unexpectedStatusKeepsTheChildSignedIn() async {
        let session = Self.session(answering: 500, cache: Cache(Self.cached))

        await session.restore()

        // 500 is not in the contract's response map at all. An answer nobody
        // planned for is still not the one answer that means "signed out".
        #expect(session.state == .signedIn(Self.cached))
    }

    @Test("an offline launch with nothing cached still keeps the child in")
    func offlineWithNoCacheStillSignedIn() async {
        let session = Self.session(answering: nil, cache: Cache())

        await session.restore()

        // Signed in and force-quit before `GET /me` ever returned. There is no
        // name to show, but the token is good and the child is in.
        #expect(session.state == .signedIn(.unread))
        if case .signedIn(let account) = session.state {
            #expect(account.name == nil)
            // Nothing confirmed this is a managed child, so nothing claims it.
            #expect(account.isManagedChild == false)
        }
    }

    // MARK: Reading the account fills the cache

    @Test("a launch that reaches the server caches what it read")
    func successfulReadPopulatesTheCache() async {
        let cache = Cache()
        let session = Self.session(answering: 200, cache: cache)

        await session.restore()

        #expect(session.state == .signedIn(Self.cached))
        // Written on the way through, so the next launch has it even offline.
        #expect(cache.read() == Self.cached)
    }

    @Test("signing out forgets the cached child")
    func signingOutClearsTheCache() async {
        let cache = Cache(Self.cached)
        let session = Self.session(answering: 200, cache: cache)

        await session.signOut()

        #expect(session.state == .signedOut)
        // Deliberate: the token and the name go together. A device handed to a
        // sibling must not greet them by the last child's name.
        #expect(cache.read() == nil)
    }

    @Test("no token is signed out, and never asks the server")
    func noTokenIsSignedOut() async {
        let session = Self.session(answering: 200, cache: Cache(), tokens: Tokens(nil))

        await session.restore()

        #expect(session.state == .signedOut)
    }

    @Test("entering demo needs no token and no network")
    func demoNeedsNothing() async {
        // The reviewer's device: never signed in, no code, no connection.
        let session = Self.session(answering: nil, cache: Cache())

        session.enterDemo()

        #expect(session.state == .demo)
        #expect(session.isDemo)
        // Year 3 and maths, reusing the existing fallback rather than a second
        // demo-only constant.
        #expect(session.level == .three)
    }

    @Test("leaving demo returns to the code screen and keeps nothing")
    func demoLeavesNothingBehind() async {
        let session = Self.session(answering: nil, cache: Cache())
        session.enterDemo()

        session.leaveDemo()

        #expect(session.state == .signedOut)
        #expect(!session.isDemo)
        #expect(session.player == nil)
    }
}
