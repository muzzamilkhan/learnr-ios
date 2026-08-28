import Testing
import Foundation
import LearnrEngine
@testable import LearnrApp

/// The speed screen's own state machine.
///
/// The engine owns the rules and is verified against the TypeScript oracle;
/// what these check is the part that is this app's — the phases a run moves
/// through, what a keystroke does to the entry, and that the clock is obeyed at
/// its edges.
///
/// Every one of these drives `tick(at:)` and `type(_:at:)` with an explicit
/// instant, so a ninety-second run is tested in no time at all. That is what
/// the engine's purity is *for*: a session that read `Date()` itself would make
/// the expiry cases untestable, which are exactly the ones worth testing.
@MainActor
struct SpeedSessionTests {

    struct NoTokens: TokenStore {
        func read() -> String? { nil }
        func write(_ token: String?) {}
    }

    /// The instant every run in these tests begins.
    static let start = 1_700_000_000_000

    /// A run against a server that answers nothing.
    ///
    /// The unreachable server is deliberate and matches `PlaySessionTests`: a
    /// run that cannot be submitted still shows its score, and every one of
    /// these goes down that path.
    static func run(mode: Mode = .multiply(.single(7)), seed: String = "test-seed") -> SpeedSession {
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        return SpeedSession(mode: mode, api: api, seed: seed, now: { start })
    }

    /// The moment the run itself starts — after the run-up.
    static var runBegins: Int { start + SpeedRun.countdownMs }

    /// Drives a run to the given instant, having got it running first.
    static func running(_ mode: Mode = .multiply(.single(7))) -> SpeedSession {
        let run = self.run(mode: mode)
        run.start()
        run.tick(at: runBegins)
        return run
    }

    // MARK: Starting

    @Test("the first question is on screen during the run-up")
    func questionIsUpDuringCountdown() {
        let run = Self.run()
        run.start()

        // The whole point of a run-up: the clock starts on a question that has
        // already been read, so the score is not partly reaction time.
        #expect(run.phase == .countdown)
        #expect(run.state?.current != nil)
        #expect(run.state?.next != nil)
        #expect(run.countdownRemainingMs == SpeedRun.countdownMs)
        #expect(run.score == 0)
    }

    @Test("the run starts when the run-up ends, not before")
    func countdownEnds() {
        let run = Self.run()
        run.start()

        run.tick(at: Self.start + SpeedRun.countdownMs - 1)
        #expect(run.phase == .countdown)
        #expect(run.countdownRemainingMs == 1)

        run.tick(at: Self.runBegins)
        #expect(run.phase == .running)
        // The run clock is set on the same tick, so the first frame of the run
        // does not show a stale ninety-something.
        #expect(run.remainingMs == SpeedRun.runMs)
    }

    @Test("typing does nothing during the run-up")
    func typingIsInertDuringCountdown() {
        let run = Self.run()
        run.start()

        run.type("7", at: Self.start + 500)
        #expect(run.entry == "")
        #expect(run.score == 0)
    }

    // MARK: The clock

    @Test("the run is not over on its very last millisecond")
    func lastMillisecondIsStillPlayable() {
        let run = Self.running()

        run.tick(at: Self.runBegins + SpeedRun.runMs - 1)
        #expect(run.phase == .running)

        // Strictly greater: `now == startedAt + runMs` is not over yet, which is
        // the engine's rule and has to be this screen's too.
        run.tick(at: Self.runBegins + SpeedRun.runMs)
        #expect(run.phase == .running)
        #expect(run.remainingMs == 0)

        run.tick(at: Self.runBegins + SpeedRun.runMs + 1)
        #expect(run.phase == .over)
    }

    @Test("the clock never counts below zero")
    func clockClamps() {
        let run = Self.running()
        run.tick(at: Self.runBegins + SpeedRun.runMs + 10_000)
        #expect(run.remainingMs == 0)
        #expect(run.secondsLeft == 0)
    }

    @Test("seconds are rounded up, so an answerable run never reads zero")
    func secondsRoundUp() {
        let run = Self.running()

        // 1ms left is still a second on the face: a run reading "0" while still
        // answerable would be lying about the one number it exists to show.
        run.tick(at: Self.runBegins + SpeedRun.runMs - 1)
        #expect(run.secondsLeft == 1)

        run.tick(at: Self.runBegins + SpeedRun.runMs - 1_001)
        #expect(run.secondsLeft == 2)
    }

    @Test("the pulse steps at thirty, fifteen and five seconds")
    func pulseSteps() {
        let run = Self.running()

        run.tick(at: Self.runBegins)
        #expect(run.pulse == .calm)

        run.tick(at: Self.runBegins + SpeedRun.runMs - 30_000)
        #expect(run.pulse == .slow)

        run.tick(at: Self.runBegins + SpeedRun.runMs - 15_000)
        #expect(run.pulse == .fast)

        run.tick(at: Self.runBegins + SpeedRun.runMs - 5_000)
        #expect(run.pulse == .urgent)
    }

    // MARK: Typing

    /// The answer to whatever question is currently up.
    static func answer(_ run: SpeedSession) -> String {
        run.state!.current.answer.stringValue
    }

    @Test("a right answer submits itself, with no key to press")
    func rightAnswerSubmitsItself() {
        let run = Self.running()
        let expected = Self.answer(run)
        let first = run.state!.current.prompt

        for digit in expected {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }

        #expect(run.score == 1)
        #expect(run.entry == "", "the entry clears for the next question")
        #expect(run.state!.current.prompt != first, "the run moved on")
    }

    @Test("the question after next is already drawn")
    func lookaheadAdvances() {
        let run = Self.running()
        let wasNext = run.state!.next.prompt

        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }

        // The lookahead is state, not a render trick — what was dimmed above is
        // now the question being asked.
        #expect(run.state!.current.prompt == wasNext)
        #expect(run.state!.next.prompt != wasNext)
    }

    @Test("a wrong entry goes dead and stays until it is cleared")
    func deadEntryWaits() {
        let run = Self.running()
        let expected = Self.answer(run)

        // A digit the answer does not begin with is dead the instant it lands.
        let wrong = expected.hasPrefix("1") ? "9" : "1"
        run.type(wrong, at: Self.runBegins + 1_000)

        #expect(run.verdict == .dead)
        #expect(run.score == 0, "a wrong entry never scores")
        #expect(run.entry == wrong, "and is not cleared for the child")

        run.clear()
        #expect(run.entry == "")
        #expect(run.verdict == .typing)
    }

    @Test("backspace takes back one key")
    func backspace() {
        let run = Self.running()

        // Stated rather than assumed: if the answer were "12" the entry would
        // submit itself and clear, and this would assert on an empty string
        // while appearing to pass. The seed fixes the question, so the premise
        // is checkable — and this fails loudly if a seed change moves it.
        #expect(Self.answer(run) != "12", "this test needs an entry that stays put")

        run.type("1", at: Self.runBegins + 500)
        run.type("2", at: Self.runBegins + 600)
        #expect(run.entry == "12")

        run.backspace()
        #expect(run.entry == "1")
    }

    @Test("an answer landing after time is up does not score")
    func lateAnswerIsRefused() {
        let run = Self.running()

        // Score one honestly first, so the assertion is about the late answer
        // and not about an empty run.
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }
        #expect(run.score == 1)

        let expected = Self.answer(run)
        let after = Self.runBegins + SpeedRun.runMs + 1

        for digit in expected {
            run.type(String(digit), at: after)
        }

        #expect(run.score == 1, "the late answer did not count")
        #expect(run.phase == .over, "and typing after time ends the run")
    }

    @Test("an answer on the last millisecond does count")
    func lastMillisecondAnswerCounts() {
        let run = Self.running()
        let expected = Self.answer(run)

        // The boundary the other way round. `now == startedAt + runMs` is not
        // over, so this must score — the edge that makes the guard strict.
        for digit in expected {
            run.type(String(digit), at: Self.runBegins + SpeedRun.runMs)
        }

        #expect(run.score == 1)
    }

    // MARK: Ending

    @Test("a run ends once")
    func finishIsIdempotent() {
        let run = Self.running()
        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)
        #expect(run.phase == .over)

        let score = run.score
        run.finish(at: Self.runBegins + SpeedRun.runMs + 2)
        run.tick(at: Self.runBegins + SpeedRun.runMs + 3)
        #expect(run.phase == .over)
        #expect(run.score == score)
    }

    @Test("a run that cannot be sent still shows its score")
    func unsentRunKeepsItsScore() async throws {
        let run = Self.running()
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }

        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)
        #expect(run.score == 1)

        // The submit is a detached task against an unreachable server. Best
        // effort throughout: the child is told nothing about the network.
        try await Task.sleep(for: .milliseconds(400))
        #expect(run.outcome == .unsent)
        #expect(run.score == 1)
    }

    @Test("leaving stops the clock without submitting")
    func abandonStopsTheClock() {
        let run = Self.running()
        run.abandon()
        #expect(run.phase == .over)
        #expect(run.outcome == .pending, "an abandoned run is not a result")
    }

    // MARK: Queueing (L11)

    /// A store that keeps what it is given, so a queued run can be read back.
    final class MemoryStore: SittingStore, @unchecked Sendable {
        private let lock = NSLock()
        private var sittings: [PendingSitting] = []
        private var runs: [PendingRun] = []
        func load() -> [PendingSitting] { lock.lock(); defer { lock.unlock() }; return sittings }
        func save(_ s: [PendingSitting]) { lock.lock(); defer { lock.unlock() }; sittings = s }
        func loadRuns() -> [PendingRun] { lock.lock(); defer { lock.unlock() }; return runs }
        func saveRuns(_ r: [PendingRun]) { lock.lock(); defer { lock.unlock() }; runs = r }
    }

    /// A run wired to a queue, against the same unreachable server. The submit
    /// always fails, which is the case the queue exists for.
    static func queued(mode: Mode = .multiply(.single(7))) -> (SpeedSession, SyncQueue, MemoryStore) {
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let store = MemoryStore()
        let queue = SyncQueue(api: api, store: store)
        let run = SpeedSession(mode: mode, api: api, queue: queue, seed: "test-seed", now: { start })
        return (run, queue, store)
    }

    @Test("a run that could not be sent is queued, not lost")
    func unsentRunIsQueued() async throws {
        let (run, queue, _) = Self.queued()
        run.start()
        run.tick(at: Self.runBegins)
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }
        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)

        try await Task.sleep(for: .milliseconds(400))

        #expect(await queue.pendingRunCount == 1,
                "an unreachable server must cost the history, not the run")
    }

    @Test("a queued run carries the score and mode that were played")
    func queuedRunCarriesTheResult() async throws {
        let (run, _, store) = Self.queued(mode: .multiply(.single(7)))
        run.start()
        run.tick(at: Self.runBegins)
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }
        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)

        try await Task.sleep(for: .milliseconds(400))

        let queued = store.loadRuns()
        #expect(queued.count == 1)
        #expect(queued.first?.correct == 1)
        #expect(queued.first?.mode == "multiply.7")
    }

    @Test("a score of nought is never queued")
    func noughtIsNotQueued() async throws {
        // A queued nought is a nought waiting to be sent. Banked, it becomes a
        // baseline the first real run beats, which fires the record celebration
        // for a run that never happened.
        let (run, queue, _) = Self.queued()
        run.start()
        run.tick(at: Self.runBegins)
        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)

        try await Task.sleep(for: .milliseconds(400))

        #expect(run.score == 0)
        #expect(await queue.pendingRunCount == 0)
    }

    @Test("a queued run is stamped with when it was played, not when it was queued")
    func queuedRunCarriesThePlayedAtStamp() async throws {
        // `runBegins` is `start + countdownMs` - the instant the run itself
        // began, from the injected clock. The queue drains much later in real
        // life, and the stamp must not move with it.
        let (run, _, store) = Self.queued()
        run.start()
        run.tick(at: Self.runBegins)
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }
        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)

        try await Task.sleep(for: .milliseconds(400))

        #expect(store.loadRuns().first?.playedAtMs == Self.runBegins)
    }

    /// A URLProtocol that records what was sent and answers 200, so the
    /// *online* submit can be inspected. The rest of this suite points at an
    /// unreachable port, which only ever exercises the queued path.
    final class RecordingProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var bodies: [String: Data] = [:]
        static let lock = NSLock()
        static let keyHeader = "X-Record-Key"

        static func session() -> (URLSession, String) {
            let key = UUID().uuidString
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RecordingProtocol.self]
            config.httpAdditionalHeaders = [keyHeader: key]
            return (URLSession(configuration: config), key)
        }

        static func body(for key: String) -> Data? {
            lock.lock(); defer { lock.unlock() }
            return bodies[key]
        }

        override class func canInit(with request: URLRequest) -> Bool {
            request.value(forHTTPHeaderField: keyHeader) != nil
        }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            // httpBody is nil for an upload task; the stream carries it.
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
            if let key = request.value(forHTTPHeaderField: Self.keyHeader), let body {
                Self.lock.lock(); Self.bodies[key] = body; Self.lock.unlock()
            }

            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(
                self, didLoad: Data(#"{"previousBest":3,"best":5,"isRecord":true,"standing":null}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    @Test("a run submitted straight away carries the played-at stamp too")
    func submittedRunCarriesThePlayedAtStamp() async throws {
        // The mirror of the queued case above. L14 asks that a run be stamped
        // when it was *played* and that the stamp hold across every flush —
        // and the flush that happens most is the first one, which succeeds.
        let (session, key) = RecordingProtocol.session()
        let api = ApiClient(
            baseURL: URL(string: "https://stub.invalid")!,
            tokens: NoTokens(),
            session: session)
        let run = SpeedSession(
            mode: .multiply(.single(7)), api: api, seed: "test-seed", now: { Self.start })

        run.start()
        run.tick(at: Self.runBegins)
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }
        run.finish(at: Self.runBegins + SpeedRun.runMs + 1)

        try await Task.sleep(for: .milliseconds(400))

        let body = try #require(RecordingProtocol.body(for: key))
        let sent = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(sent["playedAt"] as? String == ISO8601.string(fromEpochMs: Self.runBegins))
    }

    @Test("an abandoned run is not queued")
    func abandonedRunIsNotQueued() async throws {
        let (run, queue, _) = Self.queued()
        run.start()
        run.tick(at: Self.runBegins)
        for digit in Self.answer(run) {
            run.type(String(digit), at: Self.runBegins + 1_000)
        }
        run.abandon()

        try await Task.sleep(for: .milliseconds(400))

        #expect(await queue.pendingRunCount == 0,
                "a run the child walked away from is not a result to bank")
    }

    // MARK: The modes

    @Test("every one of the twenty-six modes can be run")
    func everyModeRuns() {
        // The picker only ever shows what `Modes.all` enumerates, so this is
        // the whole of what a child can reach. A mode whose specs are missing
        // would end its run instantly, which is worth catching here rather than
        // in a child's hands.
        #expect(Modes.all.count == 26)

        for mode in Modes.all {
            let run = Self.run(mode: mode)
            run.start()
            #expect(run.phase == .countdown, "\(mode.key) did not start")
            #expect(run.state?.current != nil, "\(mode.key) drew no question")

            run.tick(at: Self.runBegins)
            let answer = run.state!.current.answer.stringValue
            for digit in answer {
                run.type(String(digit), at: Self.runBegins + 1_000)
            }
            #expect(run.score == 1, "\(mode.key) could not be answered")
            run.abandon()
        }
    }

    @Test("a mode's questions are answerable with digits alone")
    func answersAreWholeNumbers() {
        // The pad has no decimal point and no minus, so an answer needing one
        // would be unenterable. Every one of the twenty-six is arithmetic over
        // whole numbers; this is what holds that true.
        for mode in Modes.all {
            let run = Self.run(mode: mode)
            run.start()
            run.tick(at: Self.runBegins)

            for _ in 0..<12 {
                let answer = run.state!.current.answer.stringValue
                // Bound outside the macro: `allSatisfy` reads as throwing
                // inside an `#expect` expansion.
                let typeable = answer.allSatisfy { $0.isNumber }
                #expect(
                    typeable,
                    "\(mode.key) asked for \"\(answer)\", which this pad cannot type")

                for digit in answer {
                    run.type(String(digit), at: Self.runBegins + 1_000)
                }
            }
            run.abandon()
        }
    }
}
