import Foundation

/// One sitting a child played, waiting to reach the server.
///
/// A sitting is the unit, not an answer, and that is the whole point. The
/// server chunks a session's answers into rounds of ten *positionally*, in
/// `answeredAt` order, and pays for the rounds past a counter. If an offline
/// sitting's answers landed in the same session as a later online one, the
/// re-chunking would shuffle a paid round into a different set of ten and the
/// child would silently lose the stars they earned. Giving each sitting its own
/// session id makes that impossible rather than handled.
public struct PendingSitting: Codable, Sendable, Equatable {
    public let id: String
    public let subject: String
    public let level: YearLevel
    public let seed: String
    public var attempts: [AttemptPayload]
    /// Set when the child finished. An unfinished sitting still syncs its
    /// answers, but does not bank, because more answers may still be coming.
    public var finished: Bool

    public init(
        id: String = UUID().uuidString.lowercased(),
        subject: String, level: YearLevel, seed: String,
        attempts: [AttemptPayload] = [], finished: Bool = false
    ) {
        self.id = id
        self.subject = subject
        self.level = level
        self.seed = seed
        self.attempts = attempts
        self.finished = finished
    }
}

/// Where pending sittings live between launches.
public protocol SittingStore: Sendable {
    func load() -> [PendingSitting]
    func save(_ sittings: [PendingSitting])
}

/// A file-backed store. Writes atomically so a crash mid-write cannot leave a
/// child's afternoon truncated.
public struct FileSittingStore: SittingStore {
    let url: URL

    public init(url: URL) { self.url = url }

    public func load() -> [PendingSitting] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingSitting].self, from: data)) ?? []
    }

    public func save(_ sittings: [PendingSitting]) {
        guard let data = try? JSONEncoder().encode(sittings) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Holds what a child has played until the network will take it.
///
/// Recording is best-effort and never blocks play: a failed flush costs
/// history, never the question in front of the child. What it must not do is
/// double-count, which is why every attempt carries a client-chosen id the
/// server dedupes on.
public actor SyncQueue {
    private let api: ApiClient
    private let store: any SittingStore
    private var sittings: [PendingSitting]
    private var flushing = false

    public init(api: ApiClient, store: any SittingStore) {
        self.api = api
        self.store = store
        self.sittings = store.load()
    }

    public var pendingCount: Int { sittings.count }

    public var pendingAttemptCount: Int {
        sittings.reduce(0) { $0 + $1.attempts.count }
    }

    public func begin(_ sitting: PendingSitting) {
        sittings.append(sitting)
        persist()
    }

    public func record(_ attempt: AttemptPayload, in sittingId: String) {
        guard let index = sittings.firstIndex(where: { $0.id == sittingId }) else { return }
        sittings[index].attempts.append(attempt)
        persist()
    }

    public func finish(_ sittingId: String) {
        guard let index = sittings.firstIndex(where: { $0.id == sittingId }) else { return }
        sittings[index].finished = true
        persist()
    }

    /// Send everything that will go, keeping whatever will not.
    ///
    /// A sitting is dropped from the queue only when the server has taken all
    /// of it. A retryable failure leaves it in place for next time; a permanent
    /// rejection drops it, because a poisoned sitting must not wedge the queue
    /// behind it forever.
    @discardableResult
    public func flush() async -> Int {
        guard !flushing, await api.isSignedIn else { return 0 }
        flushing = true
        defer { flushing = false }

        var kept: [PendingSitting] = []
        var sent = 0

        for sitting in sittings {
            do {
                try await send(sitting)
                sent += 1
            } catch let error as ApiError where error.isRetryable {
                kept.append(sitting)
            } catch {
                // Permanently refused. Losing this sitting's history is the
                // lesser harm; the child keeps playing either way.
            }
        }

        sittings = kept
        persist()
        return sent
    }

    private func send(_ sitting: PendingSitting) async throws {
        // Idempotent on the id, so a retry after a dropped connection does not
        // open a second sitting.
        try await api.createSession(CreateSessionRequest(
            id: sitting.id, subject: sitting.subject, level: sitting.level, seed: sitting.seed))

        // Batched, but in order: the server folds each answer into the child's
        // skill for its topic, and the fold is not commutative.
        if !sitting.attempts.isEmpty {
            for batch in sitting.attempts.chunked(into: 200) {
                try await api.recordAttempts(sessionId: sitting.id, batch)
            }
        }

        // Bank once, after every answer is in - never per round mid-flush.
        // Awards are the server's to decide; the device only says what
        // happened.
        guard sitting.finished else { return }

        try await api.awardRound(sessionId: sitting.id)

        if let last = sitting.attempts.last {
            try await api.awardTarget(sessionId: sitting.id, offsetMinutes: last.offsetMinutes)
        }

        try await api.endSession(sessionId: sitting.id)
    }

    private func persist() { store.save(sittings) }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
