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

/// One speed run a child finished, waiting to reach the server.
///
/// **The id belongs to the run, not to the request.** `POST /speed/runs`
/// dedupes `SpeedAttempt` on it, so a flush retried after a dropped connection
/// writes the run once. An id minted per request dedupes nothing - it is a new
/// run every time, and the cabinet lists one afternoon twice. So it is minted
/// where the run ends and persisted with it, and every flush of that run sends
/// the same one.
///
/// Two runs that scored the same are still two runs; only a repeat of the same
/// id collapses.
public struct PendingRun: Codable, Sendable, Equatable {
    public let id: String
    /// The mode's key, as `Modes.parseMode` reads it. Parsed before queueing:
    /// an unrecognised key is a 400 the queue can only drop.
    public let mode: String
    public let correct: Int

    /// When the run was **played**, in epoch milliseconds.
    ///
    /// Held across every flush for the same reason the id is (L14): without it
    /// an afternoon of offline runs is dated by whenever the queue happened to
    /// drain, and that stamp orders the cabinet, the report table and the family
    /// board, and tie-breaks which of two equal runs gets starred.
    ///
    /// Milliseconds rather than a formatted string or a `Date`: it is the unit
    /// the engine's injected clock and `RunState.startedAt` already speak, so
    /// nothing is converted until the boundary formats it. Optional because the
    /// field is optional on the wire, and because a run queued by a build that
    /// predates it has none - omitting it means the server stamps receipt, which
    /// is exactly the old behaviour.
    public let playedAtMs: Int?

    public init(
        id: String = UUID().uuidString.lowercased(),
        mode: String, correct: Int, playedAtMs: Int? = nil
    ) {
        self.id = id
        self.mode = mode
        self.correct = correct
        self.playedAtMs = playedAtMs
    }
}

/// Where pending work lives between launches.
///
/// Sittings and runs share one store so a crash cannot leave the two halves
/// disagreeing about what has been sent.
public protocol SittingStore: Sendable {
    func load() -> [PendingSitting]
    func save(_ sittings: [PendingSitting])
    func loadRuns() -> [PendingRun]
    func saveRuns(_ runs: [PendingRun])
}

extension SittingStore {
    // Defaulted so a store written before speed runs were queued still
    // compiles; it simply has nowhere to keep them.
    public func loadRuns() -> [PendingRun] { [] }
    public func saveRuns(_ runs: [PendingRun]) {}
}

/// A file-backed store. Writes atomically so a crash mid-write cannot leave a
/// child's afternoon truncated.
///
/// Runs live beside the sittings in a second file rather than in the same one:
/// the two are written on different occasions - an answer and the end of a run -
/// and one atomic write per kind means neither can truncate the other.
public struct FileSittingStore: SittingStore {
    let url: URL
    let runsURL: URL

    public init(url: URL) {
        self.url = url
        self.runsURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.deletingPathExtension().lastPathComponent)-runs")
            .appendingPathExtension(url.pathExtension)
    }

    public func load() -> [PendingSitting] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([PendingSitting].self, from: data)) ?? []
    }

    public func save(_ sittings: [PendingSitting]) {
        guard let data = try? JSONEncoder().encode(sittings) else { return }
        try? data.write(to: url, options: .atomic)
    }

    public func loadRuns() -> [PendingRun] {
        guard let data = try? Data(contentsOf: runsURL) else { return [] }
        return (try? JSONDecoder().decode([PendingRun].self, from: data)) ?? []
    }

    public func saveRuns(_ runs: [PendingRun]) {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        try? data.write(to: runsURL, options: .atomic)
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
    private var runs: [PendingRun]
    private var flushing = false

    public init(api: ApiClient, store: any SittingStore) {
        self.api = api
        self.store = store
        self.sittings = store.load()
        self.runs = store.loadRuns()
    }

    public var pendingCount: Int { sittings.count }

    public var pendingRunCount: Int { runs.count }

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

    /// Queue a finished speed run under the id it was minted with.
    ///
    /// A score of nought never reaches here - `SpeedSession` drops it before
    /// queueing, because a queued nought is a nought waiting to be sent.
    public func recordRun(_ run: PendingRun) {
        runs.append(run)
        persistRuns()
    }

    /// Send everything that will go, keeping whatever will not.
    ///
    /// A sitting is dropped from the queue only when the server has taken all
    /// of it **and the child has finished it**. A retryable failure leaves it in
    /// place for next time; a permanent rejection drops it, because a poisoned
    /// sitting must not wedge the queue behind it forever; and a sitting that
    /// sent but is still open stays, because the child is still answering into
    /// it.
    ///
    /// Returns the number of sittings whose contents reached the server, which
    /// is not the number that left the queue - an open one is counted and kept.
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

                // A sitting that sent but has not finished stays. The child is
                // still playing it, and the queue is where their next answer
                // gets recorded: `record` and `finish` both find the sitting by
                // id and no-op if it has gone, so dropping an open sitting
                // discards the rest of the sitting in silence, and it never
                // banks or ends. The app flushes on every foreground, so this
                // is the ordinary case - answer two questions, background the
                // app, come back - not a rare one.
                //
                // Re-sending the attempts it already sent is safe and is what
                // the ids are for: `POST /sessions` is idempotent on the
                // sitting id and the server dedupes attempts on theirs.
                if !sitting.finished { kept.append(sitting) }
            } catch let error as ApiError where error.isRetryable {
                kept.append(sitting)
            } catch {
                // Permanently refused. Losing this sitting's history is the
                // lesser harm; the child keeps playing either way.
            }
        }

        sittings = kept
        persist()

        await flushRuns()
        return sent
    }

    /// Send the finished runs, keeping whatever will not go.
    ///
    /// Each is one request, so unlike a sitting there is no partial send to
    /// reason about: it either landed or it did not. A `503` is the database
    /// rather than the run and is kept; a `400` is a mode that is not a mode -
    /// `multiply.10` is retired - and retrying it forever is a queue that never
    /// drains.
    private func flushRuns() async {
        var kept: [PendingRun] = []

        for run in runs {
            do {
                try await api.submitSpeedRun(SpeedRunRequest(
                    id: run.id, mode: run.mode, correct: run.correct,
                    playedAtMs: run.playedAtMs))
            } catch let error as ApiError where error.isRetryable {
                kept.append(run)
            } catch {
                // Permanently refused. The score is already on the child's
                // screen; what is lost is the history, which is the lesser harm.
            }
        }

        runs = kept
        persistRuns()
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

    private func persistRuns() { store.saveRuns(runs) }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0, !isEmpty else { return isEmpty ? [] : [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
