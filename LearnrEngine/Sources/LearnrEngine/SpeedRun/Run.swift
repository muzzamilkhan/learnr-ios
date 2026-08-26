import Foundation

/// A speed run: ninety seconds, one mode, and how many were right.
///
/// Ported from `src/lib/speedrun/run.ts`. Pure like the rest of the engine —
/// `now` is passed in, and every transition returns a new state. That is what
/// lets the whole run be tested without a clock, and it is why the guard against
/// an answer landing after time is up lives here rather than in a race between
/// two effects on the screen.

public struct RunState: Sendable {
    public let mode: Mode
    public let seed: String
    public let startedAt: Int
    public let draw: Int
    public let current: GeneratedQuestion
    /// The one shown dimmed above. State, not a render trick — the screen shows
    /// it, so a lookahead drawn wrongly is visible before it is answered.
    public let next: GeneratedQuestion
    public let correct: Int
}

public struct RunResult: Sendable, Equatable {
    public let mode: Mode
    public let correct: Int
}

/// What the digits typed so far amount to.
///
/// `typing` is an entry that could still become the answer, `correct` is the
/// answer, and `dead` is one that cannot become it however many more keys are
/// pressed — a mistyped first digit, or a right answer with something after it.
public enum EntryVerdict: String, Sendable, Equatable {
    case typing, correct, dead
}

public enum Pulse: String, Sendable, Equatable {
    case calm, slow, fast, urgent
}

public enum SpeedRunError: Error, Equatable {
    /// The mode's specs are missing from the bundled resource, which would mean
    /// a build that shipped the engine without its data.
    case unknownMode(String)
}

public enum SpeedRun {

    /// Fixed, global, and never changes. A record is only comparable against
    /// itself, so the one number a run is measured in has to be the same number
    /// forever.
    public static let runMs = 90_000

    /// The run-up. The first question is already on screen behind it, so the
    /// clock starts on a question that has been read — without it the first
    /// seconds of every run are spent orienting, which makes the score partly a
    /// measure of reaction time.
    public static let countdownMs = 3_000

    /// How many redraws to spend avoiding a repeat before taking what comes.
    static let redraws = 8

    /// The question specs each mode draws from, loaded from the bundled JSON
    /// written by `tools/generate-speedrun-vectors.ts`.
    ///
    /// Loaded rather than declared: these are the TypeScript's own literals, so
    /// a bound cannot drift. A missing or unreadable resource is a build fault,
    /// not a runtime condition, so it traps rather than returning empty — an
    /// engine that silently drew no questions would be worse to diagnose.
    static let specs: [String: [QuestionSpec]] = {
        guard let url = Bundle.module.url(forResource: "speed-modes", withExtension: "json"),
              let data = try? Data(contentsOf: url)
        else { preconditionFailure("speed-modes.json is missing from the engine bundle") }

        do {
            return try JSONDecoder().decode([String: [QuestionSpec]].self, from: data)
        } catch {
            preconditionFailure("speed-modes.json could not be decoded: \(error)")
        }
    }()

    /// The question specs a mode draws from — one for most modes, four for a
    /// mixed one.
    public static func specsFor(_ mode: Mode) throws -> [QuestionSpec] {
        guard let found = specs[mode.key] else { throw SpeedRunError.unknownMode(mode.key) }
        return found
    }

    /// Each draw gets its own RNG seeded from (seed, draw, attempt), mirroring
    /// `Sessions.drawQuestion` — the seed alone fixes the whole sequence, so a
    /// run can be replayed from it. A mode's specs are picked between with the
    /// same rng before generating from whichever one is chosen.
    ///
    /// `avoid` is the prompt currently in the other slot: a mode like
    /// `multiply.2` has only twelve possible questions, so a few redraws are
    /// spent trying not to repeat it, then whatever comes is taken — never a
    /// hang.
    static func drawQuestion(
        _ mode: Mode, _ seed: String, _ draw: Int, _ avoid: String?
    ) throws -> GeneratedQuestion {
        let modeSpecs = try specsFor(mode)

        func draw1(_ attempt: Int) throws -> GeneratedQuestion {
            var rng = Rng(seed: "\(seed):\(draw):\(attempt)")
            // A single-spec mode does not spend a draw picking, which shifts
            // every value after it — so the branch is part of the sequence, not
            // an optimisation.
            let spec = modeSpecs.count == 1 ? modeSpecs[0] : rng.pick(modeSpecs)
            return try generate(spec, &rng, label: mode.key)
        }

        var question = try draw1(0)
        var attempt = 1
        while attempt < redraws && question.prompt == avoid {
            question = try draw1(attempt)
            attempt += 1
        }
        return question
    }

    public static func startRun(mode: Mode, seed: String, startedAt: Int) throws -> RunState {
        let current = try drawQuestion(mode, seed, 0, nil)
        let next = try drawQuestion(mode, seed, 1, current.prompt)

        return RunState(
            mode: mode, seed: seed, startedAt: startedAt,
            draw: 1, current: current, next: next, correct: 0)
    }

    /// Milliseconds left, never below zero — the clock face never counts
    /// negative.
    public static func remainingMs(_ state: RunState, _ now: Int) -> Int {
        max(0, state.startedAt + runMs - now)
    }

    /// An answer on the last millisecond still counts — see `answerRun`. Note
    /// the comparison is strict: `now == startedAt + runMs` is not over yet.
    public static func isOver(_ state: RunState, _ now: Int) -> Bool {
        now > state.startedAt + runMs
    }

    /// Grade the entry as it is being typed, character by character, rather than
    /// once it is submitted — there is nothing to submit with.
    ///
    /// The comparison is an exact string one on purpose, where the session's
    /// Check key grades numerically. Nothing here waits to be checked, so there
    /// is no later moment at which `07` could be read as 7: the leading zero is
    /// a keystroke the answer does not begin with, and it is dead the instant it
    /// lands. That is the honest reading of a pad with no Check on it.
    public static func judgeEntry(_ state: RunState, _ entry: String) -> EntryVerdict {
        // `String(answer)`, so a whole number is "12" and never "12.0".
        let expected = state.current.answer.stringValue
        if entry == expected { return .correct }
        return expected.hasPrefix(entry) ? .typing : .dead
    }

    /// A run moves on a right answer and on nothing else.
    ///
    /// There is no wrong answer to record here, so there is nothing to fold in
    /// for one: an entry that is not the answer leaves the state exactly as it
    /// was, and the question stays up until it is got right or the clock runs
    /// out. That makes the score and the number of questions answered the same
    /// number, which is why `RunResult` carries only the one.
    ///
    /// The guard is here rather than only on the screen so this stays the single
    /// place the rule is written down.
    public static func answerRun(
        _ state: RunState, _ response: String, _ now: Int
    ) throws -> RunState {
        if isOver(state, now) { return state }
        if judgeEntry(state, response) != .correct { return state }

        let draw = state.draw + 1

        return RunState(
            mode: state.mode,
            seed: state.seed,
            startedAt: state.startedAt,
            draw: draw,
            current: state.next,
            next: try drawQuestion(state.mode, state.seed, draw, state.next.prompt),
            correct: state.correct + 1)
    }

    public static func runResult(_ state: RunState) -> RunResult {
        RunResult(mode: state.mode, correct: state.correct)
    }

    /// Steps at 30s, 15s and 5s remaining. Named states rather than a raw number
    /// so the view can key off it instead of re-deriving the thresholds itself.
    public static func pulseFor(_ remaining: Int) -> Pulse {
        if remaining > 30_000 { return .calm }
        if remaining > 15_000 { return .slow }
        if remaining > 5_000 { return .fast }
        return .urgent
    }
}
