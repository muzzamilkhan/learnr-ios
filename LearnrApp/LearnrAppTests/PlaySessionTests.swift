import Testing
import Foundation
import LearnrEngine
@testable import LearnrApp

/// The play screen's own state machine.
///
/// The engine owns every rule and is verified against the TypeScript oracle;
/// what these check is the part that is this app's — which phase a question is
/// in, what the entry does, and that an answered question reaches the queue
/// exactly once.
@MainActor
struct PlaySessionTests {

    /// A pack with one template of each answer mode, so a test can drive a
    /// session into any of the three pads.
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
        func load() -> [PendingSitting] { lock.withLock { sittings } }
        func save(_ sittings: [PendingSitting]) { lock.withLock { self.sittings = sittings } }
    }

    struct NoTokens: TokenStore {
        func read() -> String? { nil }
        func write(_ token: String?) {}
    }

    /// A session over a cached pack and a server that answers nothing.
    ///
    /// The unreachable server is deliberate: it is the offline path, and every
    /// one of these runs down it, which is what proves a child can play without
    /// the network.
    static func session() -> (PlaySession, MemorySittingStore) {
        let packs = MemoryPackStore()
        packs.seed(CachedPack(
            data: packJSON, subject: "maths", level: .three, etag: nil, storedAt: 0))

        let sittings = MemorySittingStore()
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))

        return (
            PlaySession(
                library: ContentLibrary(api: api, store: packs),
                queue: SyncQueue(api: api, store: sittings),
                api: api,
                level: .three),
            sittings
        )
    }

    @Test("a cached pack is enough to start playing offline")
    func startsOffline() async {
        let (play, _) = Self.session()
        await play.start()

        #expect(play.status == .playing)
        #expect(play.question?.templateId == "num")
        #expect(play.question?.question.prompt == "What is 2 + 3?")
        #expect(play.mode == .number)
        #expect(play.phase == .asking)
        #expect(play.entry == "")
    }

    @Test("a first launch with no cache and no network still deals a question")
    func playsFromTheBundleOffline() async {
        // This used to assert `.unavailable`, and that was the defect rather
        // than the specification: a freshly installed app on a device with no
        // network had nothing to play from at all. The port design asks for a
        // bundled copy precisely so this case deals a question, and the app now
        // ships one for every level.
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let play = PlaySession(
            library: ContentLibrary(api: api, store: MemoryPackStore()),
            queue: SyncQueue(api: api, store: MemorySittingStore()),
            api: api,
            level: .three)

        await play.start()
        #expect(play.status == .playing)
        #expect(play.question != nil)
    }

    @Test("a level the app does not ship, with no network, is unplayable")
    func unplayableWithoutABundledPack() async {
        // The unavailable state still exists and still has to be handled - it
        // is now reached only by asking for content that was never bundled and
        // cannot be fetched, rather than by every first launch.
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let play = PlaySession(
            library: ContentLibrary(
                api: api, store: MemoryPackStore(), bundled: nil),
            queue: SyncQueue(api: api, store: MemorySittingStore()),
            api: api,
            level: .three)

        await play.start()
        #expect(play.status == .unavailable)
        #expect(play.question == nil)
    }

    @Test("typing builds an entry under the engine's rules")
    func typing() async {
        let (play, _) = Self.session()
        await play.start()

        play.type("1")
        play.type("2")
        #expect(play.entry == "12")

        // The keypad rules are the engine's: a second point is refused, and a
        // minus after a digit is too.
        play.type(".")
        play.type(".")
        #expect(play.entry == "12.")
        play.type("-")
        #expect(play.entry == "12.")

        play.backspace()
        #expect(play.entry == "12")
    }

    @Test("an empty entry is never checkable")
    func emptyIsNotCheckable() async {
        let (play, _) = Self.session()
        await play.start()

        // `Number('')` is 0, so a blank submission would be marked correct on
        // any zero-answer question if it ever reached grading. The engine
        // guards that too; this stops it being offered at all.
        #expect(play.canCheck == false)
        play.check()
        #expect(play.phase == .asking, "checking an empty entry does nothing")

        play.type("5")
        #expect(play.canCheck)
    }

    @Test("a right answer is celebrated, then moves on by itself")
    func rightAnswerAdvances() async throws {
        let (play, _) = Self.session()
        await play.start()

        play.type("5")
        play.check()

        #expect(play.phase == .answered(correct: true, expected: "5"))
        #expect(play.answeredCount == 1)

        // It advances on its own after `correctMs`, with no Continue to press.
        try await Task.sleep(for: .milliseconds(PlaySession.correctMs + 250))
        #expect(play.phase == .asking)
        #expect(play.entry == "")
    }

    @Test("a wrong answer waits for Continue")
    func wrongAnswerWaits() async throws {
        let (play, _) = Self.session()
        await play.start()

        play.type("9")
        play.check()

        #expect(play.phase == .answered(correct: false, expected: "5"))

        // A wrong answer is never on a timer: the right answer stays on screen
        // for as long as the child wants it.
        try await Task.sleep(for: .milliseconds(PlaySession.correctMs + 250))
        #expect(play.phase == .answered(correct: false, expected: "5"),
                "a wrong answer must not advance on its own")

        play.advance()
        #expect(play.phase == .asking)
        #expect(play.entry == "")
    }

    @Test("an answered question cannot be answered twice")
    func noDoubleAnswer() async {
        let (play, _) = Self.session()
        await play.start()

        play.type("5")
        play.check()
        #expect(play.answeredCount == 1)

        // Typing and checking again during feedback must not record a second
        // attempt for the same question.
        play.type("7")
        play.check()
        play.submit("5")
        #expect(play.answeredCount == 1)
    }

    @Test("every answer reaches the queue, under one sitting id")
    func answersAreQueued() async throws {
        let (play, sittings) = Self.session()
        await play.start()

        for _ in 0..<3 {
            play.type("5")
            play.check()
            play.advance()
            // The advance task is cancelled by `advance()`, but the queue write
            // is a detached Task - give it a turn to land.
            try await Task.sleep(for: .milliseconds(50))
        }

        let pending = sittings.load()
        #expect(pending.count == 1, "one sitting, not one per answer")
        #expect(pending.first?.attempts.count == 3)

        // Each attempt carries its own id, which is what the server dedupes on:
        // a retried flush must not double-count.
        let ids = Set(pending.first?.attempts.map(\.id) ?? [])
        #expect(ids.count == 3)

        // And the sitting's id is the session seed, so a replay of this sitting
        // deals the same questions.
        #expect(pending.first?.seed == pending.first?.id)
    }

    @Test("finishing marks the sitting so it can bank")
    func finishMarksSitting() async throws {
        let (play, sittings) = Self.session()
        await play.start()

        play.type("5")
        play.check()
        try await Task.sleep(for: .milliseconds(50))

        #expect(sittings.load().first?.finished == false)
        await play.finish()
        #expect(sittings.load().first?.finished == true)
    }

    // MARK: The summary

    @Test("a finished sitting reports what was answered")
    func summaryCountsTheSitting() async throws {
        let (play, _) = Self.session()
        await play.start()

        // Three right, two wrong. The pack's one template always expects "5",
        // so the answers are deterministic.
        for _ in 0..<3 {
            play.type("5")
            play.check()
            try await Task.sleep(for: .milliseconds(PlaySession.correctMs + 250))
        }
        for _ in 0..<2 {
            play.type("9")
            play.check()
            play.advance()
        }

        await play.finish()

        let summary = try #require(play.summary)
        #expect(summary.answered == 5)
        #expect(summary.correct == 3)
        // What is left to practise, said as a count rather than as a failure.
        #expect(summary.toPractise == 2)
    }

    @Test("a sitting with nothing answered has no summary")
    func nothingAnsweredHasNoSummary() async {
        let (play, _) = Self.session()
        await play.start()
        await play.finish()

        // Opened and abandoned is not a sitting, and it is not queued either.
        // A summary saying "you answered 0 questions" would be a telling-off
        // for having opened the app.
        #expect(play.summary == nil)
    }

    @Test("a sitting answered entirely wrong still reports the effort")
    func allWrongStillCounts() async throws {
        let (play, _) = Self.session()
        await play.start()

        for _ in 0..<4 {
            play.type("9")
            play.check()
            play.advance()
        }

        await play.finish()

        let summary = try #require(play.summary)
        // The count leads and it is the effort: four questions answered is four
        // questions answered. A child who found it hard is not shown a nought.
        #expect(summary.answered == 4)
        #expect(summary.correct == 0)
        #expect(summary.toPractise == 4)
    }

    @Test("leaving without answering queues nothing")
    func nothingAnsweredQueuesNothing() async {
        let (play, sittings) = Self.session()
        await play.start()
        await play.finish()

        // An opened-and-abandoned session is not a sitting. Queueing one would
        // have the server open a session row for a child who answered nothing.
        #expect(sittings.load().isEmpty)
    }
}
