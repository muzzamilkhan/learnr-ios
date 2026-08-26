import Foundation

/// What a child has shown they can do, folded down from the questions they have
/// answered.
///
/// Ported from `src/lib/analytics/profile.ts`. One profile serves both halves of
/// the work: the parent's report reads it to say which topics need a hand, and
/// the reinforcement selector reads it to decide what to ask next. It is built
/// by folding attempts in order, so the same profile comes out of a season of
/// stored history or out of the six questions answered so far this sitting.
///
/// Pure: the caller passes `now`, never the clock.

/// The part of an attempt that says something about a skill.
public struct SkillObservation: Sendable, Equatable {
    public let topic: String
    public let level: String
    public let correct: Bool
    /// Which template asked it. Carried for the parent's report alone — nothing
    /// that folds a profile reads it, because `nextSkill` measures a topic and a
    /// topic is the grain a child learns at.
    public let templateId: String?
    public let timeTakenMs: Int
    public let answeredAt: Int
    /// Minutes east of UTC where the answer was given. Only "which day was
    /// this?" depends on it, and left out it is UTC. Carried per observation
    /// rather than per fold so a family that crosses daylight saving keeps
    /// honest days.
    public let offsetMinutes: Int

    public init(
        topic: String, level: String, correct: Bool, templateId: String? = nil,
        timeTakenMs: Int, answeredAt: Int, offsetMinutes: Int = 0
    ) {
        self.topic = topic
        self.level = level
        self.correct = correct
        self.templateId = templateId
        self.timeTakenMs = timeTakenMs
        self.answeredAt = answeredAt
        self.offsetMinutes = offsetMinutes
    }
}

/// One topic at one year level — the grain everything here is measured at.
public struct SkillRow: Sendable, Equatable {
    public let topic: String
    public let level: String
    public let attempts: Int
    public let correct: Int
    /// Recency-weighted accuracy in [0, 1]: what the child can do *now*.
    /// Lifetime accuracy would let a bad first week outvote a good month, and
    /// hide the opposite too — a topic that has quietly slipped.
    public let strength: Double
    /// Correct answers in a row. One right answer is luck; a run is the signal.
    public let streak: Int
    /// Distinct local days with at least one right answer. This is the count
    /// that says a topic is *known* rather than merely warm.
    public let correctDays: Int
    /// The last day counted, so the fold can tell a new day from the same one.
    public let lastCorrectDay: Int?
    public let totalTimeMs: Int
    public let lastAnsweredAt: Int

    public init(
        topic: String, level: String, attempts: Int, correct: Int, strength: Double,
        streak: Int, correctDays: Int, lastCorrectDay: Int?, totalTimeMs: Int,
        lastAnsweredAt: Int
    ) {
        self.topic = topic
        self.level = level
        self.attempts = attempts
        self.correct = correct
        self.strength = strength
        self.streak = streak
        self.correctDays = correctDays
        self.lastCorrectDay = lastCorrectDay
        self.totalTimeMs = totalTimeMs
        self.lastAnsweredAt = lastAnsweredAt
    }
}

/// A child's skills, in the order they were first seen.
///
/// An array rather than a dictionary keyed by topic, deliberately.
/// `applyObservation` appends a new skill at the end and replaces in place, so
/// the order is part of the value — and the selector iterates the *template*
/// pool rather than this, so nothing here depends on a lookup being fast. A
/// `Dictionary` would have made the order arbitrary and the vectors unstable.
public struct LearnerProfileState: Sendable, Equatable {
    public let skills: [SkillRow]

    public init(skills: [SkillRow] = []) { self.skills = skills }

    public static let empty = LearnerProfileState()
}

public enum Profile {

    /// Weight given to the newest answer when folding it into `strength`. High
    /// enough that a run of mistakes shows up inside one sitting, low enough
    /// that a single slip does not undo a fortnight of getting it right.
    public static let recency = 0.4

    /// Under this many answers a topic is still being sized up, and is never
    /// called weak.
    public static let minObservations = 4

    /// Strength below this is a topic the child is finding hard.
    public static let strugglingBelow = 0.6

    /// Strength at or above this, with a run behind it, is a topic they have.
    public static let secureAt = 0.85
    public static let secureStreak = 3

    /// Mastery is not the same question as "are they struggling?", and it needs
    /// more than the bare minimum to answer. Calling a topic *known* is the
    /// expensive mistake: it steps the topic down to a fraction of the
    /// questions and puts it away for days.
    public static let secureObservations = 8

    /// And on more than one day. Four right in a row in one sitting is the same
    /// memory answering four times; the point of spaced practice is the answer
    /// that survives a night's sleep.
    public static let secureDays = 2

    /// How long a secure topic is left alone before it is worth asking again.
    /// The gap grows with the number of separate days it has been got right on.
    public static let reviewIntervalsMs: [Int] = [
        2 * Day.dayMs, 5 * Day.dayMs, 12 * Day.dayMs, 28 * Day.dayMs,
    ]

    public static func reviewIntervalMs(_ skill: SkillRow) -> Int {
        let step = min(max(skill.correctDays - secureDays, 0), reviewIntervalsMs.count - 1)
        return reviewIntervalsMs[step]
    }

    /// When a secure topic is worth confirming again.
    public static func reviewDueAt(_ skill: SkillRow) -> Int {
        skill.lastAnsweredAt + reviewIntervalMs(skill)
    }

    /// Enough evidence to call a topic known: a strong run, over enough
    /// answers, on more than one day.
    private static func isMastered(_ skill: SkillRow) -> Bool {
        skill.strength >= secureAt
            && skill.streak >= secureStreak
            && skill.attempts >= secureObservations
            && skill.correctDays >= secureDays
    }

    public static func skillStatus(_ skill: SkillRow?, _ now: Int) -> SkillStatus {
        guard let skill, skill.attempts >= minObservations else { return .new }
        if skill.strength < strugglingBelow { return .struggling }
        if isMastered(skill) { return now >= reviewDueAt(skill) ? .reviewDue : .secure }
        return .developing
    }

    public static func findSkill(
        _ profile: LearnerProfileState, _ topic: String, _ level: String
    ) -> SkillRow? {
        profile.skills.first { $0.topic == topic && $0.level == level }
    }

    /// One answer folded into one skill.
    ///
    /// Exported on its own because the server keeps a running skill row per
    /// child and needs exactly this step — the stored profile and the in-memory
    /// one are then the same arithmetic, not two guesses that drift.
    public static func nextSkill(_ previous: SkillRow?, _ observation: SkillObservation) -> SkillRow {
        let outcome = observation.correct ? 1 : 0
        let day = Day.localDay(observation.answeredAt, observation.offsetMinutes)

        guard let previous else {
            return SkillRow(
                topic: observation.topic,
                level: observation.level,
                attempts: 1,
                correct: outcome,
                strength: Double(outcome),
                streak: outcome,
                correctDays: outcome,
                lastCorrectDay: observation.correct ? day : nil,
                totalTimeMs: observation.timeTakenMs,
                lastAnsweredAt: observation.answeredAt)
        }

        // A day counts once, and only when something was got right on it. The
        // test is "later than the last day counted" rather than "different
        // from" so the count cannot be inflated by answers arriving out of
        // order — two writes landing at once, or a retry overtaking. A live
        // fold handed an older answer late will undercount, which delays
        // calling a topic known and never fakes it.
        let newDay = observation.correct
            && (previous.lastCorrectDay == nil || day > previous.lastCorrectDay!)

        return SkillRow(
            topic: previous.topic,
            level: previous.level,
            attempts: previous.attempts + 1,
            correct: previous.correct + outcome,
            strength: previous.strength + recency * (Double(outcome) - previous.strength),
            streak: observation.correct ? previous.streak + 1 : 0,
            correctDays: previous.correctDays + (newDay ? 1 : 0),
            lastCorrectDay: newDay ? day : previous.lastCorrectDay,
            totalTimeMs: previous.totalTimeMs + observation.timeTakenMs,
            lastAnsweredAt: max(previous.lastAnsweredAt, observation.answeredAt))
    }

    /// Immutable, like the session state it travels with.
    public static func applyObservation(
        _ profile: LearnerProfileState, _ observation: SkillObservation
    ) -> LearnerProfileState {
        let existingIndex = profile.skills.firstIndex {
            $0.topic == observation.topic && $0.level == observation.level
        }

        guard let existingIndex else {
            return LearnerProfileState(
                skills: profile.skills + [nextSkill(nil, observation)])
        }

        var skills = profile.skills
        skills[existingIndex] = nextSkill(skills[existingIndex], observation)
        return LearnerProfileState(skills: skills)
    }

    /// Fold a history into a profile. Order matters, so the caller's order is
    /// not trusted.
    ///
    /// The sort must be *stable*: two answers sharing an `answeredAt` fold in
    /// the order they arrived, and JavaScript's `Array.prototype.sort` has been
    /// required to be stable since ES2019. Swift's `sorted(by:)` is not, so this
    /// sorts on (answeredAt, original index) to pin the same order.
    public static func buildProfile(_ observations: [SkillObservation]) -> LearnerProfileState {
        observations
            .enumerated()
            .sorted { left, right in
                left.element.answeredAt != right.element.answeredAt
                    ? left.element.answeredAt < right.element.answeredAt
                    : left.offset < right.offset
            }
            .map(\.element)
            .reduce(LearnerProfileState.empty, applyObservation)
    }

    /// Whether the answers say anything yet. Until one topic has been answered
    /// enough times to be judged, there is no pattern to act on and questions
    /// stay random — steering off two answers would be superstition, not
    /// teaching.
    public static func hasPattern(_ profile: LearnerProfileState) -> Bool {
        profile.skills.contains { $0.attempts >= minObservations }
    }

    /// The topics of the last few questions, newest first.
    public static func recentTopics(_ observations: [SkillObservation], _ count: Int) -> [String] {
        observations
            .enumerated()
            .sorted { left, right in
                left.element.answeredAt != right.element.answeredAt
                    ? left.element.answeredAt > right.element.answeredAt
                    : left.offset < right.offset
            }
            .prefix(count)
            .map(\.element.topic)
    }

    public static func accuracy(_ skill: SkillRow) -> Double {
        skill.attempts == 0 ? 0 : Double(skill.correct) / Double(skill.attempts)
    }

    public static func averageTimeMs(_ skill: SkillRow) -> Int {
        guard skill.attempts != 0 else { return 0 }
        // `Math.round`, not Swift's `rounded()`. The two agree on every
        // non-negative value and part only at a negative half — `round(-2.5)`
        // is `-2` in JS and `-3` in Swift.
        //
        // Here that difference is unreachable: `totalTimeMs` is a sum of values
        // already clamped to `[0, maxTimeMs]`, and `attempts` is positive, so
        // the quotient cannot be negative. Mutation testing confirms it —
        // swapping this for `rounded()` passes the whole corpus, because no
        // input can tell them apart. It stays `JSNumber.round` because this is a
        // port and the guarantee belongs at the call it is ported from, not in a
        // caller's arithmetic that a later change could quietly violate.
        return Int(JSNumber.round(Double(skill.totalTimeMs) / Double(skill.attempts)))
    }
}

/// `new` means "not enough answers to say" — the honest answer for most topics
/// most of the time, and the reason a child who has just started gets random
/// questions rather than a diagnosis built out of two data points.
public enum SkillStatus: String, Sendable, Equatable, CaseIterable {
    case new
    case struggling
    case developing
    case secure
    case reviewDue = "review-due"
}
