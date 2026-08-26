import Foundation

/// A session has no end. Once a subject + level has templates, it draws from
/// them for as long as the child keeps going.
///
/// Ported from `src/lib/session/session.ts`. All state transitions are pure: the
/// caller supplies the clock, so the engine stays testable and a whole sitting
/// can be replayed.
///
/// Which template is drawn is the reinforcement selector's call, from the
/// profile the session carries — random until that profile says something, then
/// weighted towards what needs work. The profile is updated as the child
/// answers, so a topic that falls apart in the first ten questions is being
/// mixed in more heavily by the twentieth, without waiting for the next sitting.

/// One answered question, as it was answered.
public struct Attempt: Sendable, Equatable {
    public let templateId: String
    public let subject: String
    public let topic: String
    public let level: String
    public let prompt: String
    /// The expected answer, kept so a parent can review what was asked.
    public let expected: String
    public let response: String
    public let correct: Bool
    /// Present exactly when the question the child answered carried one — the
    /// resolved drawing, not the template's parameters, so a template edited
    /// next month cannot change what a parent is shown about an answer given
    /// today.
    public let figure: Figure?
    /// Capped at `maxTimeMs` — see there for why an uncapped one is not a
    /// measurement.
    public let timeTakenMs: Int
    public let answeredAt: Int
    /// Minutes east of UTC when it was answered, so the day it counts towards is
    /// the child's.
    public let offsetMinutes: Int

    /// The same attempt as something the profile can fold.
    public var observation: SkillObservation {
        SkillObservation(
            topic: topic, level: level, correct: correct, templateId: templateId,
            timeTakenMs: timeTakenMs, answeredAt: answeredAt, offsetMinutes: offsetMinutes)
    }
}

public struct SessionState: Sendable {
    public let subject: String
    public let level: String
    public let startedAt: Int
    /// When the current question was put on screen — the timer origin for this
    /// attempt.
    public let questionShownAt: Int
    public let current: Question
    public let attempts: [Attempt]
    public let askedCount: Int
    /// Serialised RNG position, so the next draw continues the sequence.
    public let draw: Int
    public let seed: String
    public let templates: [QuestionTemplate]
    /// What the child has shown so far, this sitting and every one before it.
    public let profile: LearnerProfileState
    /// Topics of the last few questions, newest first — what stops one topic
    /// clumping.
    public let recentTopics: [String]
}

public struct SessionConfig: Sendable {
    public let templates: [QuestionTemplate]
    public let seed: String
    public let startedAt: Int
    public let subject: String?
    public let level: String?
    /// History to start from. Left out — signed out, or a child's first sitting
    /// — the session simply draws at random, which is what an empty profile
    /// means.
    public let profile: LearnerProfileState?
    /// Topics from the end of the last sitting, so a session does not open on
    /// the one it closed on.
    public let recentTopics: [String]?

    public init(
        templates: [QuestionTemplate], seed: String, startedAt: Int,
        subject: String? = nil, level: String? = nil,
        profile: LearnerProfileState? = nil, recentTopics: [String]? = nil
    ) {
        self.templates = templates
        self.seed = seed
        self.startedAt = startedAt
        self.subject = subject
        self.level = level
        self.profile = profile
        self.recentTopics = recentTopics
    }
}

public enum SessionError: Error, Equatable {
    case noTemplates
}

public enum Sessions {

    /// The longest a question is credited with having taken. Past this the
    /// number has stopped being a measurement: the iPad was put down
    /// mid-question and picked up again after dinner, and the honest reading is
    /// "we don't know", not four hours.
    ///
    /// It matters because the time is kept as a running total per topic and
    /// never trimmed, so one abandoned question would otherwise sit in that
    /// topic's average for good — and that average is what a parent is shown.
    public static let maxTimeMs = 5 * 60 * 1000

    /// Each draw gets its own RNG seeded from (seed, draw index) so state stays
    /// serialisable. The seed alone no longer fixes the sequence — a replay
    /// needs the profile the session started from as well, which is the price of
    /// questions that respond to the child.
    static func drawQuestion(
        _ templates: [QuestionTemplate], _ seed: String, _ draw: Int, _ context: Select.Context
    ) throws -> Question {
        var rng = Rng(seed: "\(seed):\(draw)")
        let template = try Select.selectTemplate(templates, context, &rng)
        return try generateQuestion(template, &rng)
    }

    public static func startSession(_ config: SessionConfig) throws -> SessionState {
        guard !config.templates.isEmpty else { throw SessionError.noTemplates }

        let profile = config.profile ?? .empty
        let recentTopics = Array((config.recentTopics ?? []).prefix(Select.recentMemory))

        let first = try drawQuestion(
            config.templates, config.seed, 0,
            Select.Context(profile: profile, now: config.startedAt, recent: recentTopics))

        return SessionState(
            subject: config.subject ?? first.subject,
            level: config.level ?? first.level,
            startedAt: config.startedAt,
            questionShownAt: config.startedAt,
            current: first,
            attempts: [],
            askedCount: 0,
            draw: 0,
            seed: config.seed,
            templates: config.templates,
            profile: profile,
            recentTopics: recentTopics)
    }

    public static func submitAnswer(
        _ state: SessionState, _ response: String, _ now: Int, _ offsetMinutes: Int = 0
    ) throws -> SessionState {
        let graded = Grading.gradeAnswer(state.current.question, response)

        let attempt = Attempt(
            templateId: state.current.templateId,
            subject: state.current.subject,
            topic: state.current.topic,
            level: state.current.level,
            prompt: state.current.question.prompt,
            // `String(answer)`, so a whole number reaches a parent as "2".
            expected: state.current.question.answer.stringValue,
            response: graded.response,
            correct: graded.correct,
            figure: state.current.question.figure,
            timeTakenMs: min(max(0, now - state.questionShownAt), maxTimeMs),
            answeredAt: now,
            offsetMinutes: offsetMinutes)

        let draw = state.draw + 1
        // The answer counts towards what comes next: an Attempt is already
        // everything an observation is.
        let profile = Profile.applyObservation(state.profile, attempt.observation)
        let recentTopics = Array(([attempt.topic] + state.recentTopics).prefix(Select.recentMemory))

        let next = try drawQuestion(
            state.templates, state.seed, draw,
            Select.Context(profile: profile, now: now, recent: recentTopics))

        return SessionState(
            subject: state.subject,
            level: state.level,
            startedAt: state.startedAt,
            questionShownAt: now,
            current: next,
            attempts: state.attempts + [attempt],
            askedCount: state.askedCount + 1,
            draw: draw,
            seed: state.seed,
            templates: state.templates,
            profile: profile,
            recentTopics: recentTopics)
    }

    public static func elapsedMs(_ state: SessionState, _ now: Int) -> Int {
        max(0, now - state.startedAt)
    }

    /// m:ss, counting up with no cap — sessions are open ended.
    public static func formatDuration(_ ms: Int) -> String {
        // `Math.floor` on a division. Swift's integer division truncates towards
        // zero, which differs for a negative — and `elapsedMs` clamps at zero,
        // but this is public and takes any Int.
        let totalSeconds = Int(floor(Double(ms) / 1000))
        let minutes = Int(floor(Double(totalSeconds) / 60))
        // JS `%` takes the sign of the dividend, and so does Swift's.
        let seconds = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", seconds))"
    }
}
