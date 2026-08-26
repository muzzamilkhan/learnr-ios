import Testing
import Foundation
@testable import LearnrEngine

/// A URLProtocol that answers from a script, so the queue can be driven
/// through failures without a server.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Call: Sendable { let method: String; let path: String; let body: Data? }

    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?
    nonisolated(unsafe) static var calls: [Call] = []
    static let lock = NSLock()

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        calls = []
        handler = nil
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

        Self.record(.init(method: request.httpMethod ?? "?",
                          path: request.url?.path ?? "?",
                          body: body))

        let (status, data) = Self.handler?(request) ?? (200, Data("{}".utf8))
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
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
    func load() -> [PendingSitting] { sittings }
    func save(_ sittings: [PendingSitting]) { self.sittings = sittings }
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
