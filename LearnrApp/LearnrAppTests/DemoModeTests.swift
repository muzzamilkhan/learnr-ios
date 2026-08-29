import Testing
import Foundation
import LearnrEngine
@testable import LearnrApp

/// The demo child, and the one thing that must be true of it.
///
/// Ledger `L26` asks that a demo sitting be *unable* to reach the sync queue
/// rather than filtered out of it at flush. These check the absence directly:
/// the same play path, the same answers, and a queue that stays empty because
/// no queue was ever handed over.
@MainActor
struct DemoModeTests {

    static let packJSON = Data("""
    {
      "version": "test",
      "subject": "maths",
      "level": "3",
      "templates": [
        {
          "id": "num",
          "subject": "maths",
          "topic": "addition",
          "level": "3",
          "prompt": "What is {x} + {y}?",
          "vars": [
            { "name": "x", "kind": "int", "min": "2", "max": "2" },
            { "name": "y", "kind": "int", "min": "3", "max": "3" }
          ],
          "answer": "x + y"
        }
      ]
    }
    """.utf8)

    final class MemoryPackStore: PackStore, @unchecked Sendable {
        private let lock = NSLock()
        private var packs: [String: CachedPack] = [:]
        func load(subject: String, level: YearLevel) -> CachedPack? {
            lock.withLock { packs["\(subject)-\(level.rawValue)"] }
        }
        func save(_ cached: CachedPack) {
            lock.withLock { packs["\(cached.subject)-\(cached.level.rawValue)"] = cached }
        }
        func seed(_ cached: CachedPack) { save(cached) }
    }

    final class MemorySittingStore: SittingStore, @unchecked Sendable {
        private let lock = NSLock()
        private var sittings: [PendingSitting] = []
        private var runs: [PendingRun] = []
        func load() -> [PendingSitting] { lock.withLock { sittings } }
        func save(_ sittings: [PendingSitting]) { lock.withLock { self.sittings = sittings } }
        func loadRuns() -> [PendingRun] { lock.withLock { runs } }
        func saveRuns(_ runs: [PendingRun]) { lock.withLock { self.runs = runs } }
    }

    struct NoTokens: TokenStore {
        func read() -> String? { nil }
        func write(_ token: String?) {}
    }

    /// Counts every request it sees, and fails each one at the transport.
    ///
    /// Registered on every `URLSession` a demo test builds, so that "no
    /// `ApiClient` traffic" (the spec's own words for this task) is proved by
    /// counting requests rather than inferred from `api` being `nil` — the
    /// same idiom `SessionRestoreTests.MeProtocol` uses to answer `GET /me`.
    final class CountingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var counts: [String: Int] = [:]
        static let lock = NSLock()
        static let keyHeader = "X-Counting-Key"

        static func session() -> (URLSession, key: String) {
            let key = UUID().uuidString
            lock.lock(); counts[key] = 0; lock.unlock()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [CountingProtocol.self]
            config.httpAdditionalHeaders = [keyHeader: key]
            return (URLSession(configuration: config), key)
        }

        static func count(_ key: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return counts[key] ?? 0
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: keyHeader) != nil
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            let key = request.value(forHTTPHeaderField: Self.keyHeader) ?? ""
            Self.lock.lock(); Self.counts[key, default: 0] += 1; Self.lock.unlock()
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        }

        override func stopLoading() {}
    }

    @Test("a demo sitting records nothing, because there is no queue to record to")
    func demoPlayNeverQueues() async throws {
        let packs = MemoryPackStore()
        packs.seed(CachedPack(
            data: Self.packJSON, subject: "maths", level: .three, etag: nil, storedAt: 0))
        let sittings = MemorySittingStore()
        let (urlSession, key) = CountingProtocol.session()
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: NoTokens(),
            session: urlSession)
        let queue = SyncQueue(api: api, store: sittings)

        // Built exactly as `HomeView` builds it in demo: the real library
        // (with a stubbed client it never needs, the pack being cached), no
        // queue, and — the fix this test proves — no client either.
        let play = PlaySession(
            library: ContentLibrary(api: api, store: packs),
            queue: nil,
            api: nil,
            level: .three)

        await play.start()
        #expect(play.status == .playing)

        for _ in 0..<3 {
            play.type("5")
            play.check()
            play.advance()
            // The queue write is a detached Task in the real path - give it the
            // same turn to land, so this cannot pass merely by being too quick.
            try await Task.sleep(for: .milliseconds(50))
        }
        await play.finish()

        // The child played: three answers were graded.
        #expect(play.summary?.answered == 3)

        // And none of it went anywhere. This is the L26 requirement.
        #expect(sittings.load().isEmpty)
        #expect(await queue.pendingAttemptCount == 0)
        #expect(await queue.pendingCount == 0)

        // Nor did a single request leave the device: with `api: nil`,
        // `loadProfile()` has no client to call `GET /play/state` on, which is
        // the whole point of the seal being structural rather than filtered.
        #expect(CountingProtocol.count(key) == 0)
    }

    @Test("a demo speed run is never queued, and never calls the server at all")
    func demoSpeedRunNeverQueues() async throws {
        let sittings = MemorySittingStore()
        let (urlSession, key) = CountingProtocol.session()
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: NoTokens(),
            session: urlSession)
        let queue = SyncQueue(api: api, store: sittings)

        // `SpeedSession` already takes an optional queue; demo passes nil for
        // both it and the client — the fix this test proves. Driven exactly
        // like `SpeedSessionTests.running(_:)` / `unsentRunKeepsItsScore`: an
        // injected clock, `start()` then `tick(at:)`, an answer typed digit by
        // digit, then `finish(at:)`.
        let start = 1_700_000_000_000
        let runBegins = start + SpeedRun.countdownMs
        let run = SpeedSession(
            mode: .multiply(.single(7)), api: nil, queue: nil,
            seed: "test-seed", now: { start })

        run.start()
        run.tick(at: runBegins)
        for digit in run.state!.current.answer.stringValue {
            run.type(String(digit), at: runBegins + 1_000)
        }
        run.finish(at: runBegins + SpeedRun.runMs + 1)

        // The run actually completed, with a real answer graded - otherwise
        // the queue assertion below would pass vacuously.
        #expect(run.phase == .over)
        #expect(run.score == 1)

        // `finish()` hands `submit(_:previousBest:)` to an unstructured Task,
        // exactly as the real path does - give it the same turn to land
        // before reading what it settled.
        try await Task.sleep(for: .milliseconds(200))

        // Settled honestly rather than left `.pending`: the run was never
        // meant to reach the server, so there is nothing to wait on.
        #expect(run.outcome == .unsent)

        #expect(sittings.loadRuns().isEmpty)
        #expect(await queue.pendingRunCount == 0)

        // Nor did a single request leave the device: with `api: nil`,
        // `submit(_:previousBest:)` has no client to call `POST /speed/runs`
        // on, which is the whole point of the seal being structural.
        #expect(CountingProtocol.count(key) == 0)
    }

    /// The seal this task closes: `PlaySession` and `SpeedSession` used to
    /// hold `ApiClient` directly, so `loadProfile()` and `submit(_:)` reached
    /// the network for a demo child even though nothing was ever queued.
    /// Both are `authorised: true` and a demo device holds no token, so the
    /// calls failed harmlessly - but the spec is explicit that a demo session
    /// has no `ApiClient` traffic at all, and a failing call is still traffic.
    /// These two prove `api: nil` closes that off structurally, the same way
    /// `queue: nil` already closes off recording.
    @Test("a demo sitting with no client starts, deals a question, and grades an answer")
    func demoPlayWithNoClientStillPlays() async throws {
        let packs = MemoryPackStore()
        packs.seed(CachedPack(
            data: Self.packJSON, subject: "maths", level: .three, etag: nil, storedAt: 0))

        // `ContentLibrary` itself still takes a non-optional `ApiClient` -
        // out of scope for this task, and never called here since the pack is
        // already cached. What this test is about is `PlaySession`'s own
        // `api`, which is the one actually passed as `nil`.
        let (urlSession, key) = CountingProtocol.session()
        let libraryApi = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: NoTokens(),
            session: urlSession)
        let play = PlaySession(
            library: ContentLibrary(api: libraryApi, store: packs),
            queue: nil,
            api: nil,
            level: .three)

        await play.start()
        #expect(play.status == .playing)
        #expect(play.question != nil)

        play.type("5")
        play.check()

        #expect(play.phase == .answered(correct: true, expected: "5"))
        #expect(play.answeredCount == 1)

        // And no request left the device via `PlaySession`'s own client -
        // `loadProfile()` had none to call.
        #expect(CountingProtocol.count(key) == 0)
    }

    @Test("a demo speed run with no client completes without queuing or crashing")
    func demoSpeedRunWithNoClientCompletes() async throws {
        let start = 1_700_000_000_000
        let runBegins = start + SpeedRun.countdownMs
        let run = SpeedSession(
            mode: .multiply(.single(7)), api: nil, queue: nil,
            seed: "test-seed", now: { start })

        run.start()
        run.tick(at: runBegins)
        for digit in run.state!.current.answer.stringValue {
            run.type(String(digit), at: runBegins + 1_000)
        }
        run.finish(at: runBegins + SpeedRun.runMs + 1)

        #expect(run.phase == .over)
        #expect(run.score == 1)

        // `finish()` hands off to `submit(_:previousBest:)` on an unstructured
        // Task even with no client - give it the same turn to land, so this
        // cannot pass merely by being too quick to have crashed yet.
        try await Task.sleep(for: .milliseconds(200))

        // Honest rather than misleading: `.unsent` says the score stands and
        // says nothing about a record, which is true here for the same reason
        // it is true of a real failed submit - the run was not sent - so no
        // new outcome is needed for the demo case.
        #expect(run.outcome == .unsent)
    }

    @Test("a second look around starts with no history from the first")
    func demoDiscardsBetweenVisits() async throws {
        // The discard, proved rather than asserted. A demo child who played
        // three questions, left, and came back must start empty - if anything
        // survived, it survived somewhere it should not have.
        let packs = MemoryPackStore()
        packs.seed(CachedPack(
            data: Self.packJSON, subject: "maths", level: .three, etag: nil, storedAt: 0))
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let library = ContentLibrary(api: api, store: packs)

        let first = PlaySession(library: library, queue: nil, api: nil, level: .three)
        await first.start()
        for _ in 0..<3 {
            first.type("5")
            first.check()
            first.advance()
            try await Task.sleep(for: .milliseconds(50))
        }
        await first.finish()
        #expect(first.summary?.answered == 3)

        // Leaving releases the session; coming back builds a new one, exactly
        // as `HomeView` does.
        let second = PlaySession(library: library, queue: nil, api: nil, level: .three)
        await second.start()

        #expect(second.summary == nil)
        #expect(second.answeredCount == 0)
    }

    /// A demo child must never show a stranded child's pending count.
    ///
    /// `signOut()` deliberately leaves the queue's contents alone so unsynced
    /// work survives a sign out, so a demo child entered afterwards sits on top
    /// of whatever the previous child left behind. This leaked twice while the
    /// sealing lived at the call sites - through `refreshPendingCount()`, and
    /// then again through `sync()`, which runs on every foreground.
    ///
    /// What stops it now is that `enterDemo()` swaps `Session.queue` for one
    /// over `NoSittingStore`, so there is no stranded work to find. The guards
    /// in both methods are kept as belt and braces; this test drives both
    /// paths and would fail if either the seal or a guard regressed.
    @Test("a demo session does not pick up another child's pending count")
    func demoNeverShowsAnotherChildsPendingCount() async throws {
        let sittings = MemorySittingStore()
        // A pending sitting left behind by a real, signed-out child - exactly
        // what `signOut()` leaves in place on purpose - with a real attempt in
        // it, so `pendingAttemptCount` (what `Session.pendingAttempts` and the
        // "N answers waiting to sync" label actually read) is nonzero.
        let attempt = AttemptPayload(
            id: UUID().uuidString.lowercased(),
            templateId: "maths.3.addition.sum", subject: "maths", topic: "addition",
            level: ._3, prompt: "What is 2 + 2?", expected: "4",
            response: "4", correct: true,
            timeTakenMs: 1000, answeredAt: 1_756_197_600_000, offsetMinutes: 600)
        sittings.save([PendingSitting(
            subject: "maths", level: .three, seed: "left-behind", attempts: [attempt])])
        let (urlSession, _) = CountingProtocol.session()
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: NoTokens(),
            session: urlSession)
        let queue = SyncQueue(api: api, store: sittings)
        let session = Session(
            api: api,
            queue: queue,
            library: ContentLibrary(api: api, store: MemoryPackStore()))

        // Sanity: the queue really does have work in it, so the assertion
        // below cannot pass vacuously.
        #expect(await queue.pendingAttemptCount == 1)

        session.enterDemo()
        #expect(session.pendingAttempts == 0)

        await session.refreshPendingCount()

        // The defect this proves fixed: before the guard in
        // `refreshPendingCount()`, this read straight through to the real
        // queue and picked up the left-behind child's pending attempt.
        #expect(session.pendingAttempts == 0)

        // The same defect through the other door. `sync()` writes the same
        // property and runs on EVERY foreground, so a demo child who
        // backgrounds the app and comes back would have seen the count
        // reappear. `flush()` returning early without a token is not enough to
        // save it: the count assignment after the flush runs regardless.
        await session.sync()

        #expect(session.pendingAttempts == 0)
    }

    @Test("entering the demo seals the queue, and leaving gives the real one back")
    func demoSwapsInASealedQueue() async throws {
        // The mechanism, rather than its symptom. A demo child's inability to
        // record is now a property of `Session` - it hands out a queue with no
        // store behind it - instead of something every construction site has to
        // remember to ask about.
        let sittings = MemorySittingStore()
        let attempt = AttemptPayload(
            id: UUID().uuidString.lowercased(),
            templateId: "maths.3.addition.sum", subject: "maths", topic: "addition",
            level: ._3, prompt: "What is 2 + 2?", expected: "4",
            response: "4", correct: true,
            timeTakenMs: 1000, answeredAt: 1_756_197_600_000, offsetMinutes: 600)
        sittings.save([PendingSitting(
            subject: "maths", level: .three, seed: "left-behind", attempts: [attempt])])
        let (urlSession, _) = CountingProtocol.session()
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: NoTokens(),
            session: urlSession)
        let real = SyncQueue(api: api, store: sittings)
        let session = Session(
            api: api,
            queue: real,
            library: ContentLibrary(api: api, store: MemoryPackStore()))

        #expect(await session.queue.pendingAttemptCount == 1)
        #expect(session.playApi != nil)

        session.enterDemo()

        // The queue a view would now be handed is not the real one, and it is
        // empty - no guard involved, nothing to remember at the call site.
        #expect(await session.queue.pendingAttemptCount == 0)
        // And the play path is handed no client at all.
        #expect(session.playApi == nil)

        // Recording into the sealed queue reaches no store.
        await session.queue.begin(PendingSitting(
            id: "demo-sitting", subject: "maths", level: .three, seed: "demo"))
        await session.queue.record(attempt, in: "demo-sitting")
        #expect(await session.queue.pendingAttemptCount == 1, "the sealed queue holds it in memory")
        #expect(sittings.load().count == 1, "but nothing reached the store - still just the stranded sitting")

        session.leaveDemo()

        // The real queue comes back with its work intact. `signOut()` keeps a
        // child's unsynced answers on purpose, and a wander through the demo
        // must not be what finally loses them.
        #expect(await session.queue.pendingAttemptCount == 1)
        #expect(session.playApi != nil)
        #expect(sittings.load().first?.seed == "left-behind")
    }

    @Test("demo plays from the bundle with no cache and no network")
    func demoPlaysOffline() async {
        // The reviewer's device: nothing fetched, nothing cached, no network.
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let play = PlaySession(
            library: ContentLibrary(api: api, store: MemoryPackStore()),
            queue: nil,
            api: nil,
            level: .three)

        await play.start()

        #expect(play.status == .playing)
        #expect(play.question != nil)
    }
}
