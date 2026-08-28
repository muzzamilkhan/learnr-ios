import Testing
import Foundation
@testable import LearnrEngine

/// A URLProtocol that answers from a script, so the queue can be driven
/// through failures without a server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Call: Sendable { let method: String; let path: String; let body: Data? }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    /// Per-session handlers, keyed by a header the session's configuration
    /// carries.
    ///
    /// The static `handler` above is global state, which is fine while one
    /// suite drives it and a trap the moment two do: `ContentTests` and
    /// `SyncQueueTests` are separate suites, and Swift Testing runs suites in
    /// parallel even when each is `.serialized` internally. That crossed the
    /// wires - each answering the other's requests - until this existed.
    ///
    /// A caller registers a handler under a key and puts that key in
    /// `httpAdditionalHeaders`, so every request from that session carries it
    /// and lands on the right handler however many sessions are live.
    nonisolated(unsafe) static var keyedHandlers:
        [String: @Sendable (URLRequest) -> (Int, Data, [String: String])] = [:]

    static let keyHeader = "X-Stub-Key"

    /// Registers a handler and returns a session whose every request carries
    /// its key.
    static func session(
        _ handler: @escaping @Sendable (URLRequest) -> (Int, Data, [String: String])
    ) -> URLSession {
        let key = UUID().uuidString
        lock.lock()
        keyedHandlers[key] = handler
        lock.unlock()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = [keyHeader: key]
        return URLSession(configuration: config)
    }

    static func handlerFor(_ request: URLRequest) -> (@Sendable (URLRequest) -> (Int, Data, [String: String]))? {
        guard let key = request.value(forHTTPHeaderField: keyHeader) else { return nil }
        lock.lock(); defer { lock.unlock() }
        return keyedHandlers[key]
    }
    nonisolated(unsafe) static var calls: [Call] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        calls = []
        handler = nil
        // `keyedHandlers` is deliberately not cleared: its entries belong to
        // whichever session registered them, and another suite's session may
        // still be using one. They are keyed by UUID, so they cannot collide.
    }

    static func record(_ call: Call) {
        lock.lock(); defer { lock.unlock() }
        calls.append(call)
    }

    static var recorded: [Call] {
        lock.lock(); defer { lock.unlock() }
        return calls
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // httpBody is nil for a URLSession upload task; the stream carries it.
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            let size = 4096
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
            while stream.hasBytesAvailable {
                let read = stream.read(buffer, maxLength: size)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            buffer.deallocate()
            stream.close()
            body = data
        }

        // Only the global handler's traffic is recorded. A keyed session has
        // its own handler to observe from, and appending its requests here
        // would put another suite's calls into `recorded` - which is what
        // SyncQueueTests asserts against.
        if Self.handlerFor(request) == nil {
            Self.record(.init(method: request.httpMethod ?? "?",
                              path: request.url?.path ?? "?",
                              body: body))
        }

        // A session-keyed handler wins; the global one is the older path that
        // SyncQueueTests still uses.
        let (status, data, headers) = Self.handlerFor(request)?(request)
            ?? Self.handler.map { h in { (r: URLRequest) -> (Int, Data, [String: String]) in
                let (s, d) = h(r); return (s, d, [:])
            } }?(request)
            ?? (200, Data("{}".utf8), [:])
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private var token: String?
    init(_ token: String? = nil) { self.token = token }
    func read() -> String? { token }
    func write(_ token: String?) { self.token = token }
}

final class MemorySittingStore: SittingStore, @unchecked Sendable {
    private var sittings: [PendingSitting] = []
    private var runs: [PendingRun] = []
    func load() -> [PendingSitting] { sittings }
    func save(_ sittings: [PendingSitting]) { self.sittings = sittings }
    func loadRuns() -> [PendingRun] { runs }
    func saveRuns(_ runs: [PendingRun]) { self.runs = runs }
}

private func makeClient(token: String? = "tok") -> ApiClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubProtocol.self]
    return ApiClient(baseURL: URL(string: "http://localhost:3001")!,
                     tokens: MemoryTokenStore(token),
                     session: URLSession(configuration: config))
}

private func anAttempt(_ index: Int, correct: Bool = true) -> AttemptPayload {
    AttemptPayload(
        templateId: "maths.3.addition.sum", subject: "maths", topic: "addition",
        level: .three, prompt: "What is 2 + 2?", expected: "4",
        response: correct ? "4" : "5", correct: correct,
        timeTakenMs: 1000, answeredAt: 1_756_197_600_000 + index * 1000,
        offsetMinutes: 600)
}

@Suite(.serialized)
struct StubbedServerTests {

@Suite(.serialized)
struct SyncQueueTests {

    @Test("a finished sitting syncs, banks once, and leaves the queue")
    func flushesAFinishedSitting() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attempts") {
                return (200, Data(#"{"streak":1,"streakAdvanced":false}"#.utf8))
            }
            if path.hasSuffix("/award-round") { return (200, Data(#"{"stars":3}"#.utf8)) }
            if path.hasSuffix("/award-target") { return (200, Data(#"{"awarded":false}"#.utf8)) }
            if path.hasSuffix("/end") { return (204, Data()) }
            return (201, Data(#"{"id":"s1"}"#.utf8))
        }

        let queue = SyncQueue(api: makeClient(), store: MemorySittingStore())
        var sitting = PendingSitting(subject: "maths", level: .three, seed: "seed")
        sitting.attempts = (0..<10).map { anAttempt($0) }
        sitting.finished = true
        await queue.begin(sitting)

        let sent = await queue.flush()

        #expect(sent == 1)
        #expect(await queue.pendingCount == 0)

        let paths = StubProtocol.recorded.map(\.path)
        #expect(paths.contains { $0 == "/sessions" })
        #expect(paths.contains { $0.hasSuffix("/attempts") })
        // Banked exactly once, and only after every answer was sent.
        #expect(paths.filter { $0.hasSuffix("/award-round") }.count == 1)
        let attemptsIndex = paths.firstIndex { $0.hasSuffix("/attempts") }!
        let awardIndex = paths.firstIndex { $0.hasSuffix("/award-round") }!
        #expect(attemptsIndex < awardIndex, "banked before the answers were in")
    }

    @Test("an unfinished sitting sends its answers but does not bank")
    func doesNotBankAnOpenSitting() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attempts") {
                return (200, Data(#"{"streak":1,"streakAdvanced":false}"#.utf8))
            }
            return (201, Data(#"{"id":"s1"}"#.utf8))
        }

        let queue = SyncQueue(api: makeClient(), store: MemorySittingStore())
        var sitting = PendingSitting(subject: "maths", level: .three, seed: "seed")
        sitting.attempts = (0..<4).map { anAttempt($0) }
        sitting.finished = false
        await queue.begin(sitting)

        _ = await queue.flush()

        let paths = StubProtocol.recorded.map(\.path)
        #expect(paths.contains { $0.hasSuffix("/attempts") })
        #expect(!paths.contains { $0.hasSuffix("/award-round") },
                "an open sitting must not bank - more answers may be coming")
    }

    @Test("a sitting the server could not read is kept for next time")
    func keepsRetryableFailures() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { _ in (503, Data(#"{"error":"Could not read"}"#.utf8)) }

        let queue = SyncQueue(api: makeClient(), store: MemorySittingStore())
        var sitting = PendingSitting(subject: "maths", level: .three, seed: "seed")
        sitting.attempts = [anAttempt(0)]
        sitting.finished = true
        await queue.begin(sitting)

        let sent = await queue.flush()

        #expect(sent == 0)
        #expect(await queue.pendingCount == 1, "a 503 must not lose the sitting")
    }

    @Test("a permanently refused sitting is dropped rather than wedging the queue")
    func dropsPermanentFailures() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { _ in (400, Data(#"{"error":"Bad request"}"#.utf8)) }

        let queue = SyncQueue(api: makeClient(), store: MemorySittingStore())
        var sitting = PendingSitting(subject: "maths", level: .three, seed: "seed")
        sitting.attempts = [anAttempt(0)]
        sitting.finished = true
        await queue.begin(sitting)

        _ = await queue.flush()

        #expect(await queue.pendingCount == 0,
                "a poisoned sitting must not block everything behind it")
    }

    @Test("two sittings each get their own session, so rounds cannot interleave")
    func sittingsStaySeparate() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/attempts") {
                return (200, Data(#"{"streak":1,"streakAdvanced":false}"#.utf8))
            }
            if path.hasSuffix("/award-round") { return (200, Data(#"{"stars":3}"#.utf8)) }
            if path.hasSuffix("/award-target") { return (200, Data(#"{"awarded":false}"#.utf8)) }
            if path.hasSuffix("/end") { return (204, Data()) }
            return (201, Data(#"{"id":"s"}"#.utf8))
        }

        let queue = SyncQueue(api: makeClient(), store: MemorySittingStore())
        for _ in 0..<2 {
            var sitting = PendingSitting(subject: "maths", level: .three, seed: "seed")
            sitting.attempts = (0..<10).map { anAttempt($0) }
            sitting.finished = true
            await queue.begin(sitting)
        }

        _ = await queue.flush()

        let sessionPosts = StubProtocol.recorded.filter { $0.path == "/sessions" }
        #expect(sessionPosts.count == 2)

        let ids = sessionPosts.compactMap { call -> String? in
            guard let body = call.body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            else { return nil }
            return json["id"] as? String
        }
        #expect(Set(ids).count == 2, "each sitting needs its own session id")
    }

    @Test("the queue survives a relaunch")
    func persistsAcrossLaunches() async throws {
        let store = MemorySittingStore()
        let first = SyncQueue(api: makeClient(), store: store)
        var sitting = PendingSitting(subject: "maths", level: .three, seed: "seed")
        sitting.attempts = [anAttempt(0)]
        await first.begin(sitting)

        let second = SyncQueue(api: makeClient(), store: store)
        #expect(await second.pendingCount == 1)
        #expect(await second.pendingAttemptCount == 1)
    }

    @Test("nothing is sent while signed out")
    func doesNotFlushSignedOut() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { _ in (200, Data("{}".utf8)) }

        let queue = SyncQueue(api: makeClient(token: nil), store: MemorySittingStore())
        await queue.begin(PendingSitting(subject: "maths", level: .three, seed: "s"))

        let sent = await queue.flush()

        #expect(sent == 0)
        #expect(StubProtocol.recorded.isEmpty)
        #expect(await queue.pendingCount == 1)
    }

    @Test("attempts carry distinct client ids, so a replay cannot double-count")
    func attemptsHaveDistinctIds() {
        let ids = (0..<50).map { anAttempt($0).id }
        #expect(Set(ids).count == 50)
    }
}
/// The speed-run half of the queue.
///
/// `POST /speed/runs` dedupes on the client's id (`feae8f4` in `learnr`), so
/// the id has to belong to the *run* and outlive every flush of it. An id
/// minted per request dedupes nothing, which is the defect L11 names.
/// A thread-safe call counter. The stub handler is `@Sendable` and is called
/// off the test's own task, so a captured `var` is a data race rather than a
/// convenience.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return count
    }
}

@Suite(.serialized)
struct SpeedRunQueueTests {

    /// The ids `POST /speed/runs` was called with, in order.
    ///
    /// Observed from this suite's own handler rather than `StubProtocol.recorded`:
    /// a keyed session is deliberately not recorded globally, so that two
    /// suites running in parallel cannot answer or observe each other's traffic.
    final class SeenRuns: @unchecked Sendable {
        private let lock = NSLock()
        private var ids: [String] = []
        private var stamps: [String?] = []

        func note(_ request: URLRequest) {
            guard request.url?.path == "/speed/runs" else { return }
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                var data = Data()
                let size = 4096
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
                while stream.hasBytesAvailable {
                    let read = stream.read(buffer, maxLength: size)
                    if read <= 0 { break }
                    data.append(buffer, count: read)
                }
                buffer.deallocate()
                stream.close()
                body = data
            }
            guard let body,
                  let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                  let id = json["id"] as? String
            else { return }
            lock.lock(); defer { lock.unlock() }
            ids.append(id)
            stamps.append(json["playedAt"] as? String)
        }

        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return ids
        }

        /// The `playedAt` each call carried, `nil` where it carried none.
        var playedAt: [String?] {
            lock.lock(); defer { lock.unlock() }
            return stamps
        }
    }

    private func stubRuns(_ status: Int = 200, seen: SeenRuns) -> URLSession {
        StubProtocol.session { request in
            seen.note(request)
            return (status, Data(#"{"previousBest":3,"best":5,"isRecord":true}"#.utf8), [:])
        }
    }

    private func client(_ session: URLSession, token: String? = "tok") -> ApiClient {
        ApiClient(baseURL: URL(string: "http://localhost:3001")!,
                  tokens: MemoryTokenStore(token), session: session)
    }

    @Test("a run retried after a failed flush carries the id it was minted with")
    func holdsOneIdAcrossFlushes() async throws {
        let seen = SeenRuns()
        // Fails first, then succeeds - the shape a school-run connection has.
        let attempts = Counter()
        let session = StubProtocol.session { request in
            seen.note(request)
            return attempts.next() == 1
                ? (503, Data(#"{"error":"Could not record"}"#.utf8), [:])
                : (200, Data(#"{"previousBest":3,"best":5,"isRecord":true}"#.utf8), [:])
        }

        let queue = SyncQueue(api: client(session), store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))

        _ = await queue.flush()
        #expect(await queue.pendingRunCount == 1, "a 503 must not lose the run")
        _ = await queue.flush()

        let ids = seen.all
        #expect(ids.count == 2, "the run was sent twice")
        #expect(ids.first == ids.last,
                "an id minted per request dedupes nothing - the server would store two runs")
        #expect(await queue.pendingRunCount == 0)
    }

    @Test("two runs that scored the same are still two runs")
    func distinctRunsGetDistinctIds() async throws {
        let seen = SeenRuns()
        let queue = SyncQueue(api: client(stubRuns(seen: seen)), store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))

        _ = await queue.flush()

        #expect(Set(seen.all).count == 2,
                "the server dedupes on id - equal scores must not collapse")
    }

    @Test("a run the server could not record is kept for next time")
    func keepsRetryableFailures() async throws {
        let queue = SyncQueue(api: client(stubRuns(503, seen: SeenRuns())),
                              store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))

        _ = await queue.flush()

        #expect(await queue.pendingRunCount == 1)
    }

    @Test("a run whose mode the server rejects is dropped rather than retried forever")
    func dropsPermanentFailures() async throws {
        // `parseMode` is the endpoint's whole validation and an unrecognised
        // key is a 400 - `multiply.10` is retired. Retrying it is a queue that
        // never drains.
        let queue = SyncQueue(api: client(stubRuns(400, seen: SeenRuns())),
                              store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "multiply.10", correct: 7))

        _ = await queue.flush()

        #expect(await queue.pendingRunCount == 0)
    }

    @Test("a run survives a relaunch under the same id")
    func persistsAcrossLaunches() async throws {
        let seen = SeenRuns()
        let store = MemorySittingStore()
        let run = PendingRun(mode: "add.easy", correct: 7)

        let first = SyncQueue(api: client(stubRuns(seen: SeenRuns())), store: store)
        await first.recordRun(run)

        let second = SyncQueue(api: client(stubRuns(seen: seen)), store: store)
        #expect(await second.pendingRunCount == 1)

        _ = await second.flush()

        #expect(seen.all == [run.id],
                "the id is the run's, so it has to survive the launch that minted it")
    }

    @Test("a run is sent even when the child has no sitting to sync")
    func runsFlushWithoutASitting() async throws {
        let seen = SeenRuns()
        let queue = SyncQueue(api: client(stubRuns(seen: seen)), store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))

        _ = await queue.flush()

        #expect(seen.all.count == 1)
    }

    @Test("nothing is sent while signed out")
    func doesNotFlushSignedOut() async throws {
        let seen = SeenRuns()
        let queue = SyncQueue(api: client(stubRuns(seen: seen), token: nil),
                              store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))

        _ = await queue.flush()

        #expect(seen.all.isEmpty)
        #expect(await queue.pendingRunCount == 1)
    }

    // MARK: The played-at stamp (L14)

    /// 2023-11-14T22:13:20.000Z, hand-derived rather than formatted by the code
    /// under test - an expectation the implementation computes proves nothing.
    static let playedAtMs = 1_700_000_000_000
    static let playedAtISO = "2023-11-14T22:13:20.000Z"

    @Test("a run is sent stamped with when it was played")
    func sendsThePlayedAtStamp() async throws {
        let seen = SeenRuns()
        let queue = SyncQueue(api: client(stubRuns(seen: seen)), store: MemorySittingStore())
        await queue.recordRun(
            PendingRun(mode: "add.easy", correct: 7, playedAtMs: Self.playedAtMs))

        _ = await queue.flush()

        #expect(seen.playedAt == [Self.playedAtISO])
    }

    @Test("a run retried later carries the stamp it was played at, not the retry's")
    func holdsOneStampAcrossFlushes() async throws {
        let seen = SeenRuns()
        let attempts = Counter()
        let session = StubProtocol.session { request in
            seen.note(request)
            return attempts.next() == 1
                ? (503, Data(#"{"error":"Could not record"}"#.utf8), [:])
                : (200, Data(#"{"previousBest":3,"best":5,"isRecord":true}"#.utf8), [:])
        }

        let queue = SyncQueue(api: client(session), store: MemorySittingStore())
        await queue.recordRun(
            PendingRun(mode: "add.easy", correct: 7, playedAtMs: Self.playedAtMs))

        _ = await queue.flush()
        _ = await queue.flush()

        #expect(seen.playedAt == [Self.playedAtISO, Self.playedAtISO],
                "an afternoon of offline runs must not be dated by whenever the queue drained")
    }

    @Test("a run stamped before a relaunch keeps that stamp after it")
    func stampSurvivesARelaunch() async throws {
        let seen = SeenRuns()
        let store = MemorySittingStore()

        let first = SyncQueue(api: client(stubRuns(seen: SeenRuns())), store: store)
        await first.recordRun(
            PendingRun(mode: "add.easy", correct: 7, playedAtMs: Self.playedAtMs))

        let second = SyncQueue(api: client(stubRuns(seen: seen)), store: store)
        _ = await second.flush()

        #expect(seen.playedAt == [Self.playedAtISO])
    }

    @Test("an unstamped run sends no playedAt, so the server stamps receipt")
    func omitsTheStampWhenThereIsNone() async throws {
        // Optional on the wire: omitting it is today's behaviour, and a run
        // queued by a build that predates the stamp must still send.
        let seen = SeenRuns()
        let queue = SyncQueue(api: client(stubRuns(seen: seen)), store: MemorySittingStore())
        await queue.recordRun(PendingRun(mode: "add.easy", correct: 7))

        _ = await queue.flush()

        #expect(seen.playedAt == [nil])
    }

    @Test("the boundary formats an instant the way the contract's date-time reads")
    func formatsISO8601() {
        // Derived independently of the formatter, in UTC, including a non-zero
        // millisecond - a `.SSS` that silently dropped its fraction would look
        // right at every round second.
        let cases: [(Int, String)] = [
            (1_700_000_000_000, "2023-11-14T22:13:20.000Z"),
            (1_700_000_003_000, "2023-11-14T22:13:23.000Z"),
            (1_756_197_600_123, "2025-08-26T08:40:00.123Z"),
            (0, "1970-01-01T00:00:00.000Z"),
        ]
        for (ms, expected) in cases {
            #expect(ISO8601.string(fromEpochMs: ms) == expected)
        }
    }

    @Test("a run queued before the stamp existed still decodes")
    func decodesARunWithoutAStamp() throws {
        // The persisted queue outlives the app version that wrote it. A run on
        // disk from the build before L14 has no `playedAtMs` key at all.
        let onDisk = Data(#"[{"id":"5b1f...","mode":"add.easy","correct":7}]"#
            .replacingOccurrences(of: "5b1f...", with: "5b1fdc1e-0000-4000-8000-000000000000")
            .utf8)

        let runs = try JSONDecoder().decode([PendingRun].self, from: onDisk)

        #expect(runs.count == 1)
        #expect(runs[0].playedAtMs == nil, "an older run has no stamp and must not invent one")
        #expect(runs[0].correct == 7)
    }
}

@Suite(.serialized)
struct PlayStateTests {

    /// A body shaped exactly as `apps/api/src/routes/play.ts` returns it. The
    /// contract says `schema: {}` for this endpoint (learnr#4), so this test is
    /// the only thing standing between a server-side rename and a silent
    /// decoding failure on a child's screen.
    private static let body = Data("""
    {
      "player": {
        "selectedLevel": "3",
        "streak": { "days": 4, "lastDay": 20325 },
        "stars": 27,
        "target": { "kind": "questions", "value": 20 },
        "targetDay": 20324
      },
      "profile": {
        "skills": [
          {
            "topic": "addition", "level": "3", "attempts": 12, "correct": 9,
            "strength": 0.78, "streak": 3, "correctDays": 2,
            "lastCorrectDay": 20325, "totalTimeMs": 18400,
            "lastAnsweredAt": 1756197600000
          }
        ]
      },
      "recentTopics": ["addition", "subtraction"],
      "targetAnswers": [
        { "answeredAt": 1756197600000, "timeTakenMs": 1500 }
      ]
    }
    """.utf8)

    @Test("a play-state body decodes into the hand-transcribed model")
    func decodesPlayState() throws {
        let state = try JSONDecoder().decode(PlayState.self, from: Self.body)

        #expect(state.player.selectedLevel == "3")
        #expect(state.player.streak.days == 4)
        #expect(state.player.stars == 27)
        #expect(state.player.target?.kind == "questions")
        #expect(state.player.target?.value == 20)
        #expect(state.profile.skills.count == 1)
        #expect(state.profile.skills[0].topic == "addition")
        #expect(state.profile.skills[0].level == .three)
        #expect(state.profile.skills[0].strength == 0.78)
        #expect(state.recentTopics == ["addition", "subtraction"])
        #expect(state.targetAnswers.count == 1)
    }

    @Test("a child with no target decodes, with the nulls the server sends")
    func decodesWithoutTarget() throws {
        let body = Data("""
        {
          "player": {
            "selectedLevel": null,
            "streak": { "days": 0, "lastDay": null },
            "stars": 0, "target": null, "targetDay": null
          },
          "profile": { "skills": [] },
          "recentTopics": [],
          "targetAnswers": []
        }
        """.utf8)

        let state = try JSONDecoder().decode(PlayState.self, from: body)

        #expect(state.player.selectedLevel == nil)
        #expect(state.player.target == nil)
        #expect(state.player.streak.lastDay == nil)
        #expect(state.profile.skills.isEmpty)
    }

    @Test("playState asks for the level it was given")
    func playStateSendsQuery() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { _ in (200, Self.body) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = ApiClient(baseURL: URL(string: "http://localhost:3001")!,
                            tokens: MemoryTokenStore("tok"),
                            session: URLSession(configuration: config))

        _ = try await api.playState(subject: "maths", level: .three)

        let call = StubProtocol.recorded.first
        #expect(call?.method == "GET")
        #expect(call?.path == "/play/state")
    }

    @Test("setLevel sends a PUT and tolerates the empty 204 body")
    func setLevelSends() async throws {
        StubProtocol.reset()
        StubProtocol.handler = { _ in (204, Data()) }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let api = ApiClient(baseURL: URL(string: "http://localhost:3001")!,
                            tokens: MemoryTokenStore("tok"),
                            session: URLSession(configuration: config))

        try await api.setLevel(.five)

        let call = StubProtocol.recorded.first
        #expect(call?.method == "PUT")
        #expect(call?.path == "/me/level")

        let json = try JSONSerialization.jsonObject(with: call!.body!) as? [String: Any]
        #expect(json?["level"] as? String == "5")
    }

    @Test("K is a level the contract accepts, spelled its way")
    func kIsAValidLevel() {
        #expect(YearLevel.k.rawValue == "K")
        #expect(YearLevel(rawValue: "K") == .k)
        // The contract's enum lists K last; the product sorts it first.
        #expect(YearLevel.schoolOrder.first == .k)
    }
}

}
