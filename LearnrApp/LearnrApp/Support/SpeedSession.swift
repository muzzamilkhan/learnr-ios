import Foundation
import Observation
import LearnrEngine

/// One speed run, as the screen sees it.
///
/// The engine owns the rules — what is drawn, whether an entry is the answer,
/// whether the clock has run out. This holds what a pure reducer cannot: the
/// digits typed so far, which phase the run is in, and the ticking that turns
/// a wall clock into state the view can read.
///
/// **The clock is injected.** `now` is a closure rather than a call to `Date()`
/// so a ninety-second run can be driven through countdown, expiry and the
/// late-answer guard in a test that takes no time at all. The engine was
/// written pure for exactly this reason; a session that read the clock itself
/// would throw that away at the last step.
@MainActor
@Observable
final class SpeedSession {

    /// Where a run is between being started and being left.
    ///
    /// `countdown` is the run-up, and it matters that the first question is
    /// already on screen behind it: the clock starts on a question that has
    /// been read, so the score is not partly a measure of reaction time.
    enum Phase: Equatable {
        case countdown
        case running
        case over
    }

    /// What has become of the finished run's score.
    ///
    /// The tone is the server's to decide, because the best is the server's to
    /// keep: `SpeedOutcome` carries `previousBest`, and `SpeedRecords` turns it
    /// into one of three things to say. `unsent` is not a failure worth showing
    /// a child — the score stands, it is the celebration that is missing.
    enum Outcome: Equatable {
        case pending
        case settled(tone: ResultTone, best: Int)
        /// The run could not be submitted. The score is still on screen.
        case unsent
    }

    private(set) var phase: Phase = .countdown
    private(set) var state: RunState?
    private(set) var outcome: Outcome = .pending

    /// What the child has typed so far, cleared on each right answer.
    private(set) var entry = ""

    /// Milliseconds until the run starts, during the countdown.
    private(set) var countdownRemainingMs = SpeedRun.countdownMs

    /// Milliseconds left on the run itself. Never negative — the engine's
    /// `remainingMs` clamps, and the clock face never counts below zero.
    private(set) var remainingMs = SpeedRun.runMs

    let mode: Mode

    /// How the typed entry stands against the answer, graded keystroke by
    /// keystroke because there is nothing to submit with.
    var verdict: EntryVerdict {
        guard let state, phase == .running, !entry.isEmpty else { return .typing }
        return SpeedRun.judgeEntry(state, entry)
    }

    var pulse: Pulse { SpeedRun.pulseFor(remainingMs) }

    var score: Int { state?.correct ?? 0 }

    /// Whole seconds shown on the clock, rounded up: a run reading "0" while
    /// still answerable would be lying about the one number it exists to show.
    var secondsLeft: Int { Int((Double(remainingMs) / 1000).rounded(.up)) }

    /// Where a run is submitted, or `nil` in demo mode.
    ///
    /// Optional for the same reason `queue` is: a demo run must be
    /// structurally unable to reach the server rather than filtered out of
    /// reaching it (ledger `L26`). With no client to call, `submit(_:)` never
    /// attempts the request and settles straight on `.unsent` — the honest
    /// reading, since the run genuinely was not sent, and deliberately.
    private let api: ApiClient?
    /// Where a run goes when it cannot be sent now.
    ///
    /// Optional so a screen with nothing to sync into still runs; without one,
    /// a failed submit is simply lost, which is the old behaviour and is what
    /// the previews and the mode tests want.
    private let queue: SyncQueue?
    private let now: () -> Int
    private let seed: String

    /// When the countdown began. The run's own `startedAt` is set from this
    /// plus `countdownMs`, so the two clocks cannot drift apart.
    private var countdownStartedAt = 0

    private var ticker: Task<Void, Never>?

    /// How often the clock is re-read. Fast enough that the last seconds do not
    /// visibly stutter, slow enough not to redraw the screen needlessly.
    static let tickMs = 100

    init(
        mode: Mode,
        api: ApiClient?,
        queue: SyncQueue? = nil,
        seed: String = UUID().uuidString.lowercased(),
        now: @escaping () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.mode = mode
        self.api = api
        self.queue = queue
        self.seed = seed
        self.now = now
    }

    // No `deinit` cancelling the ticker: main-actor state cannot be touched
    // from a nonisolated deinit under Swift 6. It does not need one — the
    // ticker holds `self` weakly and returns the moment it is gone, so a
    // session dropped without `abandon()` stops within one tick rather than
    // spinning on forever.

    // MARK: Starting

    /// Draws the first two questions and starts the run-up.
    ///
    /// The questions are drawn before the countdown rather than when it ends,
    /// which is what puts the first one on screen to be read while the three
    /// counts down.
    func start() {
        countdownStartedAt = now()
        phase = .countdown
        outcome = .pending
        entry = ""
        countdownRemainingMs = SpeedRun.countdownMs
        remainingMs = SpeedRun.runMs

        // A mode with no specs is a build that shipped the engine without its
        // data — `specsFor` throws `unknownMode` and there is no question to
        // show. Ending the run immediately is the honest response; there is
        // nothing to play and nothing to submit.
        guard let started = try? SpeedRun.startRun(
            mode: mode, seed: seed, startedAt: countdownStartedAt + SpeedRun.countdownMs)
        else {
            phase = .over
            outcome = .unsent
            return
        }

        state = started
        startTicking()
    }

    private func startTicking() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.tickMs))
                guard !Task.isCancelled, let self else { return }
                self.tick()
                if self.phase == .over { return }
            }
        }
    }

    /// Re-reads the clock and moves the phase on when it is time.
    ///
    /// Separate from the ticker so a test can drive it directly. Every
    /// transition a run has is here, which is why there is no second place for
    /// the clock and the answer path to disagree about whether time is up.
    func tick(at instant: Int? = nil) {
        let now = instant ?? self.now()
        guard let state else { return }

        switch phase {
        case .countdown:
            let untilStart = max(0, countdownStartedAt + SpeedRun.countdownMs - now)
            countdownRemainingMs = untilStart
            guard untilStart == 0 else { return }
            phase = .running
            // Fall through to set the run clock on the same tick, so the first
            // frame of the run does not show a stale ninety.
            remainingMs = SpeedRun.remainingMs(state, now)

        case .running:
            remainingMs = SpeedRun.remainingMs(state, now)
            guard SpeedRun.isOver(state, now) else { return }
            finish()

        case .over:
            return
        }
    }

    // MARK: Typing

    /// A digit, graded as it lands.
    ///
    /// A right answer submits itself — there is no Check key on a speed run,
    /// which is the whole reason `judgeEntry` grades a partial entry. A dead
    /// entry stays on screen: it is cleared by the child, because clearing it
    /// for them would erase the mistake before it was seen.
    func type(_ key: String, at instant: Int? = nil) {
        guard phase == .running, let state else { return }
        let now = instant ?? self.now()

        // Guarded here as well as in the engine: a keystroke landing in the
        // same moment the clock expires must not score. The engine's
        // `answerRun` refuses it too — this stops the entry changing at all.
        guard !SpeedRun.isOver(state, now) else {
            finish(at: now)
            return
        }

        let proposed = Answers.appendNumeric(entry, key)
        guard proposed != entry else { return }
        entry = proposed

        guard SpeedRun.judgeEntry(state, entry) == .correct else { return }

        guard let next = try? SpeedRun.answerRun(state, entry, now) else { return }
        self.state = next
        entry = ""
    }

    /// Clears the entry. The only way out of a dead one.
    func clear() {
        guard phase == .running else { return }
        entry = ""
    }

    func backspace() {
        guard phase == .running, !entry.isEmpty else { return }
        entry.removeLast()
    }

    // MARK: Ending

    /// Ends the run and submits it. Idempotent: a run ends once.
    func finish(at instant: Int? = nil) {
        guard phase != .over else { return }
        ticker?.cancel()
        ticker = nil
        phase = .over
        entry = ""
        remainingMs = 0

        guard let state else { return }
        let result = SpeedRun.runResult(state)

        // A score of nought is not a run. `SpeedRecords` reads a first run as
        // "no record yet", so banking a nought makes it the baseline the first
        // real run beats - which fires the child's record celebration and puts a
        // personal-best banner in front of the parent for a run nobody played.
        // Dropped here rather than at flush: a queued nought is a nought waiting
        // to be sent.
        // `.unsent` is the honest reading: the run was not sent, deliberately.
        // The screen says "Nice work" and nothing about a record, which is
        // exactly what a nought has earned.
        guard result.correct > 0 else {
            outcome = .unsent
            return
        }

        // The id is minted once, here, and belongs to the run from now on.
        // `POST /speed/runs` dedupes on it, so every flush of this run - now,
        // and after any number of relaunches - has to carry this same id. One
        // minted per request would dedupe nothing.
        // Stamped with when the run was *played* - `startedAt` from the
        // injected clock - not with when the queue drains (L14). An afternoon
        // of offline runs flushed at five o'clock would otherwise all be dated
        // five o'clock, and that stamp orders the cabinet, the report table and
        // the family board, and tie-breaks which of two equal runs is starred.
        let pending = PendingRun(
            mode: result.mode.key, correct: result.correct, playedAtMs: state.startedAt)

        Task { [weak self] in await self?.submit(pending, previousBest: result) }
    }

    /// Sends the run and turns the server's answer into what the screen says.
    ///
    /// Best-effort like the rest of the play path: a run that cannot be sent
    /// still shows its score, and the child is told nothing about the network.
    /// The tone comes from `SpeedRecords` rather than the server's `isRecord`
    /// so the three-way distinction — first run, record, short — is made in one
    /// place, and a first run is never celebrated as a record.
    private func submit(_ pending: PendingRun, previousBest result: RunResult) async {
        // No client to call in demo mode: the run was never meant to reach the
        // server, so `.unsent` is settled directly rather than attempted and
        // queued. Queuing it would give a sealed session an object to record
        // onto, which is exactly what it must not have (ledger `L26`).
        guard let api else {
            outcome = .unsent
            return
        }

        // Built from `pending` in full, stamp included. The stamp is not the
        // queue's alone: the flush that happens most is this one, the first,
        // which succeeds - and a run sent straight away is still dated by when
        // it was *played* rather than by when the server received it (L14).
        let request = SpeedRunRequest(
            id: pending.id, mode: pending.mode, correct: pending.correct,
            playedAtMs: pending.playedAtMs)

        guard let sent = try? await api.submitSpeedRun(request) else {
            // Queued under the id it was just sent with, so the retry is the
            // same run rather than a second one. The score stays on screen;
            // only the celebration is missing.
            await queue?.recordRun(pending)
            outcome = .unsent
            return
        }

        outcome = .settled(
            tone: SpeedRecords.resultTone(previousBest: sent.previousBest, score: result.correct),
            best: sent.best)
    }

    /// Called when the child leaves. Stops the clock without submitting a run
    /// that was abandoned part way through.
    func abandon() {
        ticker?.cancel()
        ticker = nil
        phase = .over
    }
}
