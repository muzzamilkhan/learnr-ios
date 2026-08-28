import Foundation

/// The wire types the child client needs, transcribed by hand from the
/// contract at `learnr/apps/api/contract/openapi.yaml` - served live at
/// `https://learnr-api-syd.fly.dev/openapi.json`, which is how to read it from
/// a machine with no `learnr` clone.
///
/// The contract is complete now: 32 paths, and the four endpoints that once
/// declared `schema: {}` - `/me`, `/play/state`, `/speed/runs` and
/// `/speed/records` - all carry real schemas. `learnr#4` is closed, and these
/// models have been checked field for field against it.
///
/// They remain hand-written. Replacing them with generated ones means taking on
/// `swift-openapi-generator` and reshaping every call site, which is a trade
/// nobody has made - ledger item `L1`.
///
/// Ten contract fields carry `format: date-time`. `ApiClient` no longer decodes
/// with a bare `JSONDecoder()` - it reads and writes through `ApiCoding` below,
/// so generated `Date`-typed properties decode the day they arrive. Only
/// `RedeemResponse.expiresAt` is typed as a `Date` so far; the other nine are
/// still unmodelled and follow with the generator.

/// Australian school year. Note the contract orders `K` last in its enum, even
/// though it sorts first everywhere in the product.
public enum YearLevel: String, Codable, CaseIterable, Sendable {
    case k = "K"
    case one = "1", two = "2", three = "3"
    case four = "4", five = "5", six = "6"

    /// K first, then numerically - the order a person expects.
    public static let schoolOrder: [YearLevel] = [.k, .one, .two, .three, .four, .five, .six]

    public var label: String {
        self == .k ? "Kindergarten" : "Year \(rawValue)"
    }
}

// MARK: - Auth

public struct RedeemRequest: Codable, Sendable {
    public let code: String
    public init(code: String) { self.code = code }
}

public struct RedeemResponse: Codable, Sendable {
    public let token: String
    public let childId: String
    /// A hundred years out in practice: the code is the short-lived half of
    /// signing in, not the session it buys.
    ///
    /// The first of the contract's ten `format: date-time` fields to be typed
    /// as a `Date` rather than carried as an unparsed String. It decodes only
    /// because `ApiClient` reads through `ApiCoding`; the remaining nine follow
    /// with the generator under `L1`.
    public let expiresAt: Date
}

/// `GET /me`. **Hand-written** (ledger `L1`), originally from `Account` in
/// `apps/api/src/data/accounts.ts`, and since checked field for field against
/// the contract's `GET /me`, which now declares all seven.
public struct Account: Codable, Sendable, Equatable {
    public let id: String
    public let role: String?
    public let parentId: String?
    public let name: String?
    public let avatar: String?
    public let image: String?
    public let photo: String?

    /// A managed child - the only kind this app can sign in.
    public var isManagedChild: Bool { role == "child" && parentId != nil }
}

// MARK: - Play

public struct CreateSessionRequest: Codable, Sendable {
    public let id: String
    public let subject: String
    public let level: YearLevel
    public let seed: String

    public init(id: String, subject: String, level: YearLevel, seed: String) {
        self.id = id
        self.subject = subject
        self.level = level
        self.seed = seed
    }
}

public struct SessionResponse: Codable, Sendable {
    public let id: String
}

/// One answered question, as it was answered.
///
/// `id` is the client's to choose, and the server dedupes on it: a retried
/// offline flush must write each answer once, or the child's skill row counts
/// their answers twice.
public struct AttemptPayload: Codable, Sendable, Equatable {
    public let id: String
    public let templateId: String
    public let subject: String
    public let topic: String
    public let level: YearLevel
    public let prompt: String
    public let expected: String
    public let response: String
    public let correct: Bool
    public let timeTakenMs: Int
    /// Milliseconds since the epoch.
    public let answeredAt: Int
    /// Minutes east of UTC, -840...840. The server has no timezone; this is
    /// what lets a parent in another one still see their child's evenings as
    /// evenings.
    public let offsetMinutes: Int

    public init(
        id: String = UUID().uuidString.lowercased(),
        templateId: String, subject: String, topic: String, level: YearLevel,
        prompt: String, expected: String, response: String, correct: Bool,
        timeTakenMs: Int, answeredAt: Int, offsetMinutes: Int
    ) {
        self.id = id
        self.templateId = templateId
        self.subject = subject
        self.topic = topic
        self.level = level
        self.prompt = prompt
        self.expected = expected
        self.response = response
        self.correct = correct
        self.timeTakenMs = timeTakenMs
        self.answeredAt = answeredAt
        self.offsetMinutes = offsetMinutes
    }
}

public struct AttemptsRequest: Codable, Sendable {
    public let attempts: [AttemptPayload]
    public init(attempts: [AttemptPayload]) { self.attempts = attempts }
}

public struct AttemptResult: Codable, Sendable {
    public let streak: Int
    public let streakAdvanced: Bool
}

public struct AwardRoundResponse: Codable, Sendable {
    /// Null when nothing was banked - a round already paid for, or a read that
    /// failed. Not an error either way: stars are best-effort.
    public let stars: Int?
}

public struct AwardTargetRequest: Codable, Sendable {
    public let offsetMinutes: Int
    public init(offsetMinutes: Int) { self.offsetMinutes = offsetMinutes }
}

public struct AwardTargetResponse: Codable, Sendable {
    public let awarded: Bool
}

// MARK: - Play state

/// Everything the play screen needs before its first question, in one call.
///
/// **Hand-written** (ledger `L1`), originally from the route's return in
/// `apps/api/src/routes/play.ts`, and since checked against the contract's
/// `GET /play/state`, which now declares it.
///
/// This endpoint exists because assembling it from parts was five sequential
/// reads. Over the wire that is five round trips before a child sees anything,
/// which is the wrong trade on a school-run connection.
public struct PlayState: Codable, Sendable, Equatable {
    public let player: PlayerState
    public let profile: LearnerProfile
    public let recentTopics: [String]
    /// A two-day window, and empty when the child has no target - the server
    /// skips the read rather than paying for an answer it would throw away.
    public let targetAnswers: [TargetAnswer]
}

public struct PlayerState: Codable, Sendable, Equatable {
    /// As stored. Resolve it against the content before trusting it: a level
    /// that is no longer a school year is not worth steering questions with.
    public let selectedLevel: String?
    public let streak: PlayStreak
    public let stars: Int
    public let target: DailyTarget?
    /// The last local day the target's stars were banked.
    public let targetDay: Int?
}

public struct PlayStreak: Codable, Sendable, Equatable {
    /// Consecutive local days with at least one answer on them.
    public let days: Int
    public let lastDay: Int?
}

public struct DailyTarget: Codable, Sendable, Equatable {
    /// "questions" or "minutes".
    public let kind: String
    public let value: Int
}

public struct TargetAnswer: Codable, Sendable, Equatable {
    public let answeredAt: Int
    public let timeTakenMs: Int
}

public struct LearnerProfile: Codable, Sendable, Equatable {
    public let skills: [TopicSkill]

    public static let empty = LearnerProfile(skills: [])
}

/// What a child can do on one topic at one year, folded from their attempts.
public struct TopicSkill: Codable, Sendable, Equatable {
    public let topic: String
    public let level: YearLevel
    public let attempts: Int
    public let correct: Int
    /// Recency-weighted accuracy in [0, 1] - what the child can do now, not on
    /// average.
    public let strength: Double
    /// Correct answers in a row. A run, not one right answer, is the signal.
    public let streak: Int
    /// Distinct local days with at least one right answer: the count that says
    /// a topic is known rather than merely warm.
    public let correctDays: Int
    public let lastCorrectDay: Int?
    public let totalTimeMs: Int
    public let lastAnsweredAt: Int
}

public struct SetLevelRequest: Codable, Sendable {
    public let level: YearLevel
    public init(level: YearLevel) { self.level = level }
}

// MARK: - Speed

public struct SpeedRunRequest: Codable, Sendable {
    public let id: String
    public let mode: String
    public let correct: Int
    /// ISO 8601, as the contract's `format: date-time` requires. Omitted
    /// entirely when there is nothing to say, rather than sent as null - the
    /// field is optional and the server stamps receipt in its absence.
    public let playedAt: String?

    public init(
        id: String = UUID().uuidString.lowercased(),
        mode: String, correct: Int, playedAt: String? = nil
    ) {
        self.id = id
        self.mode = mode
        self.correct = correct
        self.playedAt = playedAt
    }

    /// Formats the stamp at the boundary, from the epoch milliseconds the
    /// engine and the queue speak.
    public init(id: String, mode: String, correct: Int, playedAtMs: Int?) {
        self.init(id: id, mode: mode, correct: correct,
                  playedAt: playedAtMs.map(ISO8601.string(fromEpochMs:)))
    }
}

/// How the client reads and writes the contract's `format: date-time`.
///
/// Ten fields carry it, and `ApiClient` decoded with a bare `JSONDecoder()`
/// until this existed - so a `Date`-typed property would simply fail, and fail
/// as "The data couldn't be read" with no field named. None of the hand-written
/// models types one as a `Date` yet, which is why nothing was red; the generator
/// under `L1` emits `Date` for all ten at once, which is why this lands first
/// and on its own.
///
/// **The wire form, confirmed** (ledger `L16`): always fractional, always
/// exactly three digits, always a literal `Z`. Nothing in the chain formats a
/// date - `z.date()` validates a `Date` and yields the same `Date`, so what
/// reaches `JSON.stringify` is live and `Date.prototype.toJSON` calls
/// `toISOString`, whose shape ECMA-262 pins. The fraction is what the language
/// emits, not a convention the server chose.
///
/// **So why parse leniently rather than take `.iso8601`.** Two reasons, and
/// neither is the one this was first written for - measured on Swift 6.3.3 /
/// macOS 26.5.1, `.iso8601` accepts both shapes, so it would work today:
///
/// - Nothing on the server pins the three digits with a test. Its serialization
///   suite asserts only that the field is a string `Date.parse` can read, so a
///   serializer swap would redden nothing there and surface here, on a device,
///   as "The data couldn't be read".
/// - `ISO8601DateFormatter`'s default options omit `.withFractionalSeconds` by
///   documented behaviour, so the strategy's tolerance is a Foundation version's
///   convenience rather than a guarantee. Being explicit means a toolchain or
///   deployment-target move cannot change what parses.
///
/// The web client is lenient the same way - `ISO_TIMESTAMP` in
/// `src/lib/revive.ts` makes the fraction optional - so this matches it rather
/// than hedging against it.
///
/// **Not every time-shaped field is a `Date`.** `answeredAt` and
/// `lastAnsweredAt` are epoch-millisecond integers, because the engine does its
/// day and recency arithmetic in numbers and a `Date` there would put a
/// conversion in front of `nextSkill` and `buildProfile` - the two things the
/// digests hold this port to. The nine response fields are the complete set.
public enum ApiCoding {
    nonisolated(unsafe) private static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let withoutFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Parses either shape, and any offset - a stamp is an instant, not a wall
    /// clock, so `+11:00` and `Z` land on the same `Date`.
    public static func date(from text: String) -> Date? {
        withFraction.date(from: text) ?? withoutFraction.date(from: text)
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = Self.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Not an ISO 8601 date-time: \(text)"))
            }
            return date
        }
        return decoder
    }

    /// Writes what the contract asks for, fractional seconds included: the
    /// server tie-breaks `playedAt` finer than a second.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.withFraction.string(from: date))
        }
        return encoder
    }
}

/// The one date format the client writes by hand.
///
/// Fixed to UTC and to `en_US_POSIX` rather than taking the device's locale or
/// zone: a child in Sydney and a child in London must send the same instant the
/// same way, and a formatter that reads the system locale is one that produces
/// Arabic-Indic digits or a Buddhist year on somebody's phone. Milliseconds are
/// included because the contract's `format: date-time` accepts them and the
/// server's tie-break on `playedAt` is finer than a second.
public enum ISO8601 {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    public static func string(fromEpochMs ms: Int) -> String {
        formatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }
}

/// `POST /speed/runs`. **Hand-transcribed** from `SpeedOutcome` in the server's
/// `apps/api/src/data/speed-records.ts`, and since checked against the
/// contract's `GET /speed/records`, which now declares it.
public struct SpeedOutcome: Codable, Sendable {
    public let previousBest: Int?
    public let best: Int
    public let isRecord: Bool
    /// Where this run left the child on the family board, and where they were
    /// before. Null when the run placed nowhere.
    ///
    /// The contract marks it `required`; this model omitted it altogether
    /// until the `L1` spike generated the types and the two were diffed. It
    /// decodes today only because nothing reads it - which is the whole
    /// argument for generating these rather than transcribing them, and the
    /// reason this drift is worth a commit of its own rather than waiting on
    /// `L18`.
    public let standing: StandingChange?
}

/// A run's place on the family board, and the place it displaced.
public struct StandingChange: Codable, Sendable, Equatable {
    public let place: Int
    /// Null when the child had no place before this run.
    public let previousPlace: Int?
    /// How many others are on the board.
    public let rivals: Int
}

// MARK: - Errors

public struct ApiErrorBody: Codable, Sendable {
    public let error: String
}
