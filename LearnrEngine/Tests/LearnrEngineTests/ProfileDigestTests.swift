import Testing
import Foundation
@testable import LearnrEngine

/// The profile set: seeded observation sequences folded to a skill row,
/// mirroring `scripts/fixtures/profile.ts`.
///
/// **Two traps are the point of this set.** `strength` is a recency-weighted
/// float folded one answer at a time, so a few hundred observations is where
/// two languages' accumulation would part company if it were going to. And
/// `correctDays` is the child's day, not the server's — each observation
/// carries the offset it was given at, and the fold only ever counts a day
/// later than the last counted, so answers arriving out of order undercount.
/// Mastery is delayed, never faked, and that asymmetry is exactly what a port
/// implements backwards.
///
/// The scenarios are transcribed by hand, as they are hand-authored on the
/// oracle's side. The digest is what catches a transcription slip.
struct ProfileDigestTests {
    /// A fixed moment to count days from, so nothing here reads the clock:
    /// midnight UTC on 1 January 2026. `now` is injected everywhere in the
    /// engine, which is what makes this set possible at all.
    /// `Date.UTC(2026, 0, 1)` in milliseconds, written as the literal it is —
    /// nothing here should be able to read a clock or a locale by accident.
    static let epoch = 1_767_225_600_000
    static let hour = 60 * 60 * 1000
    static let day = 24 * hour

    /// Sydney in winter, which is where the day boundary actually falls for
    /// this family.
    static let sydney = 600

    static func answer(
        correct: Bool = true,
        answeredAt: Int = epoch,
        offsetMinutes: Int = sydney
    ) -> SkillObservation {
        SkillObservation(
            topic: "subtraction",
            level: "1",
            correct: correct,
            timeTakenMs: 4000,
            answeredAt: answeredAt,
            offsetMinutes: offsetMinutes
        )
    }

    /// `n` answers, one an hour apart from `startAt`.
    static func run(
        _ n: Int,
        _ correct: (Int) -> Bool,
        startAt: Int = epoch,
        offsetMinutes: Int = sydney
    ) -> [SkillObservation] {
        (0..<n).map {
            answer(correct: correct($0), answeredAt: startAt + $0 * hour, offsetMinutes: offsetMinutes)
        }
    }

    struct Scenario {
        let name: String
        let observations: [SkillObservation]
    }

    /// Sequences built to reach each threshold, not sampled at random. Order is
    /// contract — the scenarios are hashed per group, keyed by name, but each
    /// group's cases are hashed in sequence.
    static var scenarios: [Scenario] {
        var all: [Scenario] = [
            Scenario(name: "empty", observations: []),
            Scenario(name: "below-min-observations", observations: run(3) { _ in true }),
            Scenario(name: "struggling", observations: run(12) { $0 % 5 == 0 }),
            Scenario(name: "developing", observations: run(12) { $0 % 3 != 0 }),
            Scenario(name: "secure", observations:
                run(6, { _ in true }, startAt: epoch)
                + run(6, { _ in true }, startAt: epoch + day)
                + run(6, { _ in true }, startAt: epoch + 2 * day)
            ),
            Scenario(name: "long-run-strength", observations: run(300) { $0 % 4 != 0 }),
            // **These instants are chosen so the offset actually decides the
            // day.** At 15h UTC, Sydney is already on the next day while UTC and
            // California are not. At 44h a missing offset lands a day earlier
            // than Sydney's, so the default is provably UTC rather than the last
            // offset seen.
            Scenario(name: "days-across-offsets", observations: [
                answer(answeredAt: epoch + 15 * hour, offsetMinutes: sydney),
                answer(answeredAt: epoch + 15 * hour, offsetMinutes: 0),
                answer(answeredAt: epoch + 15 * hour, offsetMinutes: -480),
                answer(answeredAt: epoch + 44 * hour, offsetMinutes: sydney),
                // `offsetMinutes: undefined` on the oracle's side, which is UTC.
                answer(answeredAt: epoch + 44 * hour, offsetMinutes: 0),
            ]),
            // Day 3, then day 1. The second must not count — the undercount.
            Scenario(name: "out-of-order-days", observations: [
                answer(answeredAt: epoch + 2 * day),
                answer(answeredAt: epoch),
                answer(answeredAt: epoch + 3 * day),
            ]),
            Scenario(name: "all-wrong", observations: run(10) { _ in false }),
            Scenario(name: "wrong-then-right", observations: run(20) { $0 >= 10 }),
            Scenario(name: "right-then-wrong", observations: run(20) { $0 < 10 }),
        ]

        for (i, interval) in Profile.reviewIntervalsMs.enumerated() {
            all.append(Scenario(
                name: "review-interval-\(i)",
                observations: (0...i).map { answer(answeredAt: epoch + $0 * day) }
                    + [answer(answeredAt: epoch + (i + 1) * day + interval)]
            ))
        }

        return all
    }

    /// `lastCorrectDay` stringifies as `"null"` where it is unset, and that is
    /// intended — a null day and day 0 are different things.
    static func canonicalSkill(_ skill: SkillRow) throws -> String {
        try Canonical.canonicalise([
            (name: "topic", value: skill.topic),
            (name: "level", value: skill.level),
            (name: "attempts", value: String(skill.attempts)),
            (name: "correct", value: String(skill.correct)),
            (name: "strength", value: JSNumber.toString(skill.strength)),
            (name: "streak", value: String(skill.streak)),
            (name: "correctDays", value: String(skill.correctDays)),
            (name: "lastCorrectDay", value: skill.lastCorrectDay.map(String.init) ?? "null"),
            (name: "totalTimeMs", value: String(skill.totalTimeMs)),
            (name: "lastAnsweredAt", value: String(skill.lastAnsweredAt)),
        ])
    }

    /// The derived reads. The stored row does not contain them and a port must
    /// reproduce them anyway: `skillStatus` is what the selector keys off
    /// entirely, and `reviewIntervalMs` decides when a mastered topic comes
    /// back.
    ///
    /// Taken at two instants, because status is a function of `now` as well as
    /// of the row. Without the second, **`review-due` is unreachable** — every
    /// scenario stops at `secure` and one of the five statuses goes uncovered
    /// however many scenarios are added.
    /// **`at` is the label, not the instant.** The TypeScript builds
    /// `[['end', lastAnsweredAt], ['due', lastAnsweredAt + interval]]` and
    /// destructures it as `([at, now])`, so `at` binds `"end"` or `"due"` and
    /// the timestamp binds `now`, which the case never writes. Hashing the
    /// label loses nothing: `lastAnsweredAt` and `reviewIntervalMs` are both
    /// hashed elsewhere, so the two instants stay pinned.
    static func canonicalStatus(_ skill: SkillRow) throws -> [String] {
        let interval = Profile.reviewIntervalMs(skill)
        return try [
            (label: "end", now: skill.lastAnsweredAt),
            (label: "due", now: skill.lastAnsweredAt + interval),
        ].map { instant in
            try Canonical.canonicalise([
                (name: "at", value: instant.label),
                (name: "reviewIntervalMs", value: String(interval)),
                (name: "status", value: Profile.skillStatus(skill, instant.now).rawValue),
            ])
        }
    }

    /// Each scenario folded twice: once through `nextSkill` a step at a time —
    /// so an intermediate state that diverges names the observation it diverged
    /// on — and once through `buildProfile`, which is the same arithmetic the
    /// stored row goes through.
    ///
    /// **Both matter.** `buildProfile` *sorts* by `answeredAt` before folding,
    /// so the out-of-order undercount `nextSkill` produces can only ever show up
    /// on the step-at-a-time path — folding only through `buildProfile` would
    /// make `out-of-order-days` pin nothing.
    @Test("profile folding reproduces the oracle's digest, scenario for scenario")
    func profileDigestsMatch() throws {
        let oracle = Fixtures.digest(set: "profile")
        var checked = 0

        for scenario in Self.scenarios {
            var cases: [String] = []
            var skill: SkillRow?

            for observation in scenario.observations {
                let next = Profile.nextSkill(skill, observation)
                skill = next
                cases.append(try Self.canonicalSkill(next))
            }

            for built in Profile.buildProfile(scenario.observations).skills {
                cases.append(try Self.canonicalSkill(built))
            }

            if let skill {
                cases.append(contentsOf: try Self.canonicalStatus(skill))
            }

            #expect(
                Canonical.digest(cases) == oracle.groups[scenario.name],
                "\(scenario.name) folds differently from the oracle"
            )
            checked += 1
        }

        #expect(
            checked == oracle.groups.count,
            "hashed \(checked) scenarios, the oracle has \(oracle.groups.count)"
        )
    }
}
