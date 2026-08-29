import Testing
import Foundation
import LearnrEngine
@testable import LearnrApp

/// What the home screen knows about a child's stars and streak between
/// sittings.
///
/// The gap these close is the one the `L13` audit named: stars and streak
/// existed only in the moment they were earned - the sitting summary and the
/// speed-run result - and the screen a child actually lands on said nothing
/// about either. A child who played yesterday had no way to see what it came
/// to without playing again.
///
/// Two rules, and both are about a screen that must render with no network
/// (ledger `L17` keeps a child signed in through an outage, so the home screen
/// is reachable offline by design):
///
/// - **The last known figures survive a failed read.** They are cached beside
///   the account, the queue and the packs, and a launch that cannot reach the
///   server shows what it last saw rather than nothing.
/// - **Nothing is shown until something is known.** A child whose figures have
///   never been fetched sees no row at all - not two zeros, which would tell
///   them they have nothing when the truth is that we have not asked yet.
@MainActor
struct HomeStatsTests {

    // MARK: The doubles

    final class Tokens: TokenStore, @unchecked Sendable {
        private let lock = NSLock()
        private var token: String?
        init(_ token: String? = "a-token") { self.token = token }
        func read() -> String? { lock.lock(); defer { lock.unlock() }; return token }
        func write(_ new: String?) { lock.lock(); defer { lock.unlock() }; token = new }
    }

    struct NoSittings: SittingStore {
        func load() -> [PendingSitting] { [] }
        func save(_ sittings: [PendingSitting]) {}
    }

    struct NoPacks: PackStore {
        func load(subject: String, level: YearLevel) -> CachedPack? { nil }
        func save(_ cached: CachedPack) {}
    }

    /// Holds a snapshot in memory and counts what was written, so a test can
    /// tell "kept the old value" apart from "wrote the old value back".
    final class Snapshots: PlayerSnapshotCache, @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: PlayerSnapshot?
        private(set) var writes: [PlayerSnapshot?] = []
        init(_ snapshot: PlayerSnapshot? = nil) { self.snapshot = snapshot }
        func read() -> PlayerSnapshot? { lock.lock(); defer { lock.unlock() }; return snapshot }
        func write(_ new: PlayerSnapshot?) {
            lock.lock(); defer { lock.unlock() }
            writes.append(new)
            snapshot = new
        }
    }

    /// Answers `GET /play/state` with a body, a status, or a transport failure.
    final class PlayStateProtocol: URLProtocol, @unchecked Sendable {
        /// nil means the request never arrives - a transport failure, which is
        /// a different thing from any reply a server could send.
        nonisolated(unsafe) static var replies: [String: (Int, String)?] = [:]
        static let lock = NSLock()
        static let keyHeader = "X-Play-Key"

        static func session(_ reply: (Int, String)?) -> URLSession {
            let key = UUID().uuidString
            lock.lock(); replies[key] = reply; lock.unlock()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [PlayStateProtocol.self]
            config.httpAdditionalHeaders = [keyHeader: key]
            return URLSession(configuration: config)
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: keyHeader) != nil
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
            Self.lock.lock(); let reply = Self.replies[key] ?? nil; Self.lock.unlock()

            guard let reply else {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    /// A `PlayState` body carrying the three fields the home screen reads.
    static func body(level: String, stars: Int, streak: Int) -> String {
        """
        {"player":{"selectedLevel":"\(level)","streak":{"days":\(streak),"lastDay":20000},
         "stars":\(stars),"target":null,"targetDay":null},
         "targetAnswers":[],
         "profile":{"skills":[]},
         "recentTopics":[]}
        """
    }

    static func session(answering reply: (Int, String)?, snapshots: Snapshots) -> Session {
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: Tokens(),
            session: PlayStateProtocol.session(reply))
        return Session(
            api: api,
            queue: SyncQueue(api: api, store: NoSittings()),
            library: ContentLibrary(api: api, store: NoPacks()),
            snapshots: snapshots)
    }

    // MARK: Nothing known yet

    @Test("a child whose figures have never been read has none to show")
    func nothingBeforeAnythingIsKnown() async {
        let session = Self.session(answering: nil, snapshots: Snapshots())

        await session.refreshPlayer()

        // Not zero. Zero is a claim about the child; nil is a claim about what
        // we have asked, which is the true one here.
        #expect(session.player == nil)
    }

    // MARK: A successful read

    @Test("a successful read shows the stars and streak it carried")
    func readShowsFigures() async {
        let session = Self.session(
            answering: (200, Self.body(level: "3", stars: 24, streak: 3)),
            snapshots: Snapshots())

        await session.refreshPlayer()

        #expect(session.player?.stars == 24)
        #expect(session.player?.streakDays == 3)
    }

    @Test("a successful read caches what it saw")
    func readCaches() async {
        let snapshots = Snapshots()
        let session = Self.session(
            answering: (200, Self.body(level: "3", stars: 24, streak: 3)),
            snapshots: snapshots)

        await session.refreshPlayer()

        #expect(snapshots.read()?.stars == 24)
        #expect(snapshots.read()?.streakDays == 3)
    }

    @Test("the level still arrives with the figures")
    func readKeepsReadingTheLevel() async {
        let session = Self.session(
            answering: (200, Self.body(level: "5", stars: 1, streak: 0)),
            snapshots: Snapshots())

        await session.refreshPlayer()

        // The one call this replaced did only this. It still has to.
        #expect(session.level == .five)
    }

    // MARK: The offline launch

    @Test("a launch that cannot reach the server shows the last known figures")
    func offlineShowsCached() async {
        let snapshots = Snapshots(PlayerSnapshot(stars: 24, streakDays: 3, level: "3"))
        let session = Self.session(answering: nil, snapshots: snapshots)

        session.restorePlayer()
        await session.refreshPlayer()

        #expect(session.player?.stars == 24)
        #expect(session.player?.streakDays == 3)
    }

    @Test("a failed read leaves the figures it already had standing")
    func failedReadKeepsFigures() async {
        let snapshots = Snapshots(PlayerSnapshot(stars: 24, streakDays: 3, level: "3"))
        let session = Self.session(answering: nil, snapshots: snapshots)
        session.restorePlayer()

        await session.refreshPlayer()

        // The cache is not cleared by a read that failed: what it holds is
        // still the best thing known about this child.
        #expect(snapshots.writes.isEmpty)
        #expect(session.player?.stars == 24)
    }

    @Test("a 503 leaves the figures standing, exactly as a dead connection does")
    func serverErrorKeepsFigures() async {
        let snapshots = Snapshots(PlayerSnapshot(stars: 24, streakDays: 3, level: "3"))
        let session = Self.session(
            answering: (503, #"{"error":"Could not read"}"#), snapshots: snapshots)
        session.restorePlayer()

        await session.refreshPlayer()

        #expect(session.player?.stars == 24)
        #expect(snapshots.writes.isEmpty)
    }

    @Test("a cached level is restored before the network is tried")
    func cachedLevelRestored() async {
        let snapshots = Snapshots(PlayerSnapshot(stars: 24, streakDays: 3, level: "6"))
        let session = Self.session(answering: nil, snapshots: snapshots)

        session.restorePlayer()

        // Otherwise an offline launch refreshes the content for the fallback
        // level rather than the one this child actually plays.
        #expect(session.level == .six)
    }

    // MARK: What a figure means when it is zero

    @Test("a streak of nought is not shown")
    func zeroStreakHidden() async {
        let session = Self.session(
            answering: (200, Self.body(level: "3", stars: 7, streak: 0)),
            snapshots: Snapshots())

        await session.refreshPlayer()

        // "0 days" is a scold. A child who has just broken a streak does not
        // need it named on the screen they land on.
        #expect(session.player?.showsStreak == false)
    }

    @Test("a star count of nought is still shown")
    func zeroStarsShown() async {
        let session = Self.session(
            answering: (200, Self.body(level: "3", stars: 0, streak: 2)),
            snapshots: Snapshots())

        await session.refreshPlayer()

        // A count that starts at nought is a scoreboard, not a judgement -
        // and hiding it would make the first star appear from nowhere.
        #expect(session.player?.showsStars == true)
    }

    @Test("a fresher read replaces what was cached")
    func fresherReadReplacesCache() async {
        let snapshots = Snapshots(PlayerSnapshot(stars: 24, streakDays: 3, level: "3"))
        let session = Self.session(
            answering: (200, Self.body(level: "3", stars: 31, streak: 4)),
            snapshots: snapshots)
        session.restorePlayer()

        await session.refreshPlayer()

        #expect(session.player?.stars == 31)
        #expect(snapshots.read()?.stars == 31)
    }
}
