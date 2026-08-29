import Foundation
import Observation
import LearnrEngine

/// One sitting, as the screen sees it.
///
/// The engine owns every rule — which question comes next, whether an answer is
/// right, what a profile becomes. This holds the parts a screen needs that a
/// pure reducer cannot: the entry being typed, which phase the question is in,
/// and the sitting's id in the sync queue.
///
/// **Each sitting gets its own session id.** Sharing one across sittings lets
/// the server re-chunk a paid round and quietly cost a child their stars, which
/// is why `PendingSitting` mints one per sitting and this holds exactly one.
@MainActor
@Observable
final class PlaySession {

    /// Where a question is between being asked and being left.
    ///
    /// `answered` carries the grade because the screen shows different things
    /// for each: a right answer moves on by itself after `correctMs`, and a
    /// wrong one waits, so the right answer stays on screen for as long as the
    /// child wants it.
    enum Phase: Equatable {
        case asking
        case answered(correct: Bool, expected: String)
    }

    enum Status: Equatable {
        case loading
        /// Nothing cached and nothing reachable — the one state in which a
        /// question genuinely cannot be dealt.
        case unavailable
        case playing
    }

    private(set) var status: Status = .loading

    /// What a finished sitting has to say for itself.
    ///
    /// Deliberately framed as effort rather than as a score. The count of
    /// questions *answered* leads, because that is the thing a child chose to
    /// do and the thing that is true regardless of how hard the sitting was;
    /// how many were right is secondary, and the rest are "to practise" rather
    /// than wrong. A child who got four out of thirty still sat down and
    /// answered thirty questions, and a screen that tells them they scored 13%
    /// is a screen that teaches them not to come back.
    ///
    /// It carries no stars and no streak on purpose: those are banked by
    /// `SyncQueue.flush` and a device that finished offline has not banked
    /// anything yet, so showing them here would mean either a number that is
    /// sometimes a lie or a spinner in front of a child who has finished
    /// playing.
    struct Summary: Equatable {
        let answered: Int
        let correct: Int

        /// The ones worth another go. Named for what happens next rather than
        /// for what went wrong.
        var toPractise: Int { answered - correct }
    }

    /// Set by `finish()`, and nil until then.
    ///
    /// Nil also for a sitting nobody answered: opening the app and closing it
    /// is not a sitting, it is not queued as one, and a summary reading "you
    /// answered 0 questions" would be a telling-off for having opened the app.
    private(set) var summary: Summary?

    /// The engine's state, which advances the instant an answer is submitted.
    ///
    /// It is deliberately *not* held back during feedback. An earlier version
    /// kept it on the answered question and moved it on when the child
    /// continued, which put two bugs in one decision: `askedCount` lagged by
    /// one, and the advance had to smuggle the next state through a second
    /// field that the right-answer path never set - so a session that advanced
    /// quickly stuck on its first question. The screen wants the answered
    /// question for a moment longer than the engine does, and `answered` below
    /// is where that belongs.
    private(set) var state: SessionState?

    private(set) var phase: Phase = .asking

    /// The question being shown, which is the one just answered while feedback
    /// is up and the engine's current one otherwise.
    var question: Question? {
        if case .answered = phase { return answered }
        return state?.current
    }

    /// The question the feedback is about. Held only for as long as it is on
    /// screen.
    private var answered: Question?

    /// What the child has typed so far. Empty for a tapped question.
    private(set) var entry = ""

    /// How long a correct answer is celebrated before the next question. A wrong
    /// one is never on a timer.
    static let correctMs = 700

    private let library: ContentLibrary
    /// Where answers go, or `nil` in demo mode.
    ///
    /// Optional for the same reason `SpeedSession`'s is: a demo sitting must be
    /// unable to reach the queue rather than filtered out of it (ledger `L26`).
    /// There is no object here to record onto, so there is nothing to seal.
    private let queue: SyncQueue?
    /// Where a profile is read from, or `nil` in demo mode.
    ///
    /// Optional for the same reason `queue` is: a demo sitting must be
    /// structurally unable to reach the server rather than filtered out of
    /// reaching it (ledger `L26`). With no client to call, `loadProfile()` has
    /// nothing to await and returns the empty profile straight away — the same
    /// thing an offline child sees when the call fails.
    private let api: ApiClient?
    private let level: YearLevel
    private let subject: String

    /// The sitting this session's answers belong to, minted once.
    private let sittingId = UUID().uuidString.lowercased()
    private var began = false
    private var advanceTask: Task<Void, Never>?

    init(
        library: ContentLibrary, queue: SyncQueue? = nil, api: ApiClient?,
        subject: String = "maths", level: YearLevel
    ) {
        self.library = library
        self.queue = queue
        self.api = api
        self.subject = subject
        self.level = level
    }

    var mode: AnswerMode {
        guard let question else { return .number }
        return Answers.answerMode(question.question)
    }

    var options: [AnswerOption] {
        guard let question else { return [] }
        return Answers.answerOptions(question.question)
    }

    /// Whether the Check key can be pressed. An empty entry is never checkable —
    /// `Number('')` is 0, so a blank submission would be marked correct on any
    /// question whose answer is zero if it ever reached grading.
    var canCheck: Bool { !entry.isEmpty && phase == .asking }

    var answeredCount: Int { state?.askedCount ?? 0 }

    // MARK: Starting

    func start() async {
        status = .loading

        // The profile first, so the very first question is already weighted for
        // a child who has played before. Best-effort: a child who cannot reach
        // the server starts on an empty profile rather than not at all, which
        // is what an empty profile already means to the selector.
        let profile = await loadProfile()

        let pack: ContentPack
        do {
            // Cache-first (ledger `L15`): the pack on disk starts the sitting,
            // and `Session.refreshContent()` keeps it current from the home
            // screen. Revalidating here put a conditional GET in front of the
            // child's first question, which a bad connection can hold open for
            // the full default timeout.
            pack = try await library.packForPlay(subject: subject, level: level)
        } catch {
            status = .unavailable
            return
        }

        do {
            let session = try Sessions.startSession(SessionConfig(
                templates: pack.templates,
                seed: sittingId,
                startedAt: Self.now(),
                subject: subject,
                level: level.rawValue,
                profile: profile.profile,
                recentTopics: profile.recentTopics))
            state = session
            phase = .asking
            entry = ""
            status = .playing
        } catch {
            // The pack decoded but held no templates: content, not a bug here.
            status = .unavailable
        }
    }

    /// The child's history, or an empty profile when it cannot be had.
    private func loadProfile() async -> (profile: LearnerProfileState, recentTopics: [String]) {
        // No client to call in demo mode — the empty profile is returned
        // immediately, exactly as it is when a real call fails, so a demo
        // child starts on the same footing as an offline one.
        guard let api, let play = try? await api.playState(subject: subject, level: level) else {
            return (.empty, [])
        }

        // `PlayState` carries skills as the server folded them, which is the
        // same arithmetic `nextSkill` does — the server keeps a running row per
        // child precisely so the two cannot drift.
        let skills = play.profile.skills.map { skill in
            SkillRow(
                topic: skill.topic, level: skill.level.rawValue, attempts: skill.attempts,
                correct: skill.correct, strength: skill.strength, streak: skill.streak,
                correctDays: skill.correctDays, lastCorrectDay: skill.lastCorrectDay,
                totalTimeMs: skill.totalTimeMs, lastAnsweredAt: skill.lastAnsweredAt)
        }
        return (LearnerProfileState(skills: skills), play.recentTopics)
    }

    // MARK: Typing

    func type(_ key: String) {
        guard phase == .asking else { return }

        switch mode {
        case .number:
            entry = Answers.appendNumeric(entry, key)
        case .text:
            // The letter pad's own cap. `appendNumeric` is for digits and would
            // refuse every letter.
            guard entry.count < 16 else { return }
            entry += key
        case .tap:
            break
        }
    }

    func backspace() {
        guard phase == .asking, !entry.isEmpty else { return }
        entry.removeLast()
    }

    // MARK: Answering

    /// Submits the typed entry. Tapped questions call `submit(_:)` directly.
    func check() {
        guard canCheck else { return }
        submit(entry)
    }

    func submit(_ response: String) {
        guard phase == .asking, let current = state else { return }

        let now = Self.now()
        let offsetMinutes = Self.offsetMinutes()

        guard let next = try? Sessions.submitAnswer(current, response, now, offsetMinutes) else {
            return
        }

        guard let attempt = next.attempts.last else { return }

        // The engine moves on now; the screen keeps the answered question for
        // as long as the feedback is up.
        answered = current.current
        state = next
        entry = attempt.response
        phase = .answered(
            correct: attempt.correct,
            expected: Answers.formatAnswer(current.current.question))

        record(attempt)

        // Right answers move on by themselves; wrong ones wait for Continue, so
        // the right answer stays on screen for as long as the child wants it.
        guard attempt.correct else { return }

        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Self.correctMs))
            guard !Task.isCancelled else { return }
            self?.advance()
        }
    }

    /// Leaves the feedback and shows the question already waiting.
    func advance() {
        guard case .answered = phase else { return }
        advanceTask?.cancel()
        advanceTask = nil
        answered = nil
        phase = .asking
        entry = ""
    }

    // MARK: Recording

    /// Queues the answer. Best-effort throughout: a failed write costs history,
    /// never the question in front of the child.
    private func record(_ attempt: Attempt) {
        let payload = AttemptPayload(
            // Minted here, one per answer, because the server dedupes on it:
            // a retried flush must write each answer once or the child's skill
            // row counts their answers twice. The hand-written model defaulted
            // this; the generated one does not, so it is spelled out.
            id: UUID().uuidString.lowercased(),
            templateId: attempt.templateId,
            subject: attempt.subject,
            topic: attempt.topic,
            level: (YearLevel(rawValue: attempt.level) ?? level).input,
            prompt: attempt.prompt,
            expected: attempt.expected,
            response: attempt.response,
            correct: attempt.correct,
            timeTakenMs: attempt.timeTakenMs,
            answeredAt: attempt.answeredAt,
            offsetMinutes: attempt.offsetMinutes)

        let sitting = PendingSitting(
            id: sittingId, subject: subject, level: level, seed: sittingId)
        let opening = !began
        began = true

        Task { [queue] in
            guard let queue else { return }
            if opening { await queue.begin(sitting) }
            await queue.record(payload, in: sitting.id)
        }
    }

    /// Closes the sitting so it can bank. Called when the child leaves.
    func finish() async {
        advanceTask?.cancel()

        // Read from the engine's own attempts rather than from a counter kept
        // beside them: `attempts` is what was actually graded, so the summary
        // cannot drift from the answers that were queued.
        if let attempts = state?.attempts, !attempts.isEmpty {
            summary = Summary(
                answered: attempts.count,
                correct: attempts.filter(\.correct).count)
        }

        guard began, let queue else { return }
        await queue.finish(sittingId)
        _ = await queue.flush()
    }

    // MARK: The clock

    static func now() -> Int { Int(Date().timeIntervalSince1970 * 1000) }

    /// Minutes east of UTC, so the day an answer counts towards is the child's.
    static func offsetMinutes() -> Int {
        TimeZone.current.secondsFromGMT() / 60
    }
}
