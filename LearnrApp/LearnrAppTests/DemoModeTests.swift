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

    @Test("a demo sitting records nothing, because there is no queue to record to")
    func demoPlayNeverQueues() async throws {
        let packs = MemoryPackStore()
        packs.seed(CachedPack(
            data: Self.packJSON, subject: "maths", level: .three, etag: nil, storedAt: 0))
        let sittings = MemorySittingStore()
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let queue = SyncQueue(api: api, store: sittings)

        // Built exactly as `HomeView` builds it in demo: the real library, and
        // no queue.
        let play = PlaySession(
            library: ContentLibrary(api: api, store: packs),
            queue: nil,
            api: api,
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
    }

    @Test("a demo speed run is never queued")
    func demoSpeedRunNeverQueues() async throws {
        let sittings = MemorySittingStore()
        let api = ApiClient(
            baseURL: URL(string: "http://127.0.0.1:1")!,
            tokens: NoTokens(),
            session: URLSession(configuration: .ephemeral))
        let queue = SyncQueue(api: api, store: sittings)

        // `SpeedSession` already takes an optional queue; demo passes nil.
        // Driven exactly like `SpeedSessionTests.running(_:)` /
        // `unsentRunKeepsItsScore`: an injected clock, `start()` then
        // `tick(at:)`, an answer typed digit by digit, then `finish(at:)`.
        let start = 1_700_000_000_000
        let runBegins = start + SpeedRun.countdownMs
        let run = SpeedSession(
            mode: .multiply(.single(7)), api: api, queue: nil,
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

        try await Task.sleep(for: .milliseconds(200))

        #expect(sittings.loadRuns().isEmpty)
        #expect(await queue.pendingRunCount == 0)
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

        let first = PlaySession(library: library, queue: nil, api: api, level: .three)
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
        let second = PlaySession(library: library, queue: nil, api: api, level: .three)
        await second.start()

        #expect(second.summary == nil)
        #expect(second.answeredCount == 0)
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
            api: api,
            level: .three)

        await play.start()

        #expect(play.status == .playing)
        #expect(play.question != nil)
    }
}
