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
/// One trap if that ever happens: ten contract fields carry `format: date-time`,
/// and `ApiClient` decodes with a bare `JSONDecoder()`. Generating `Date`-typed
/// properties needs `dateDecodingStrategy = .iso8601` in the same change.

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
    /// ISO 8601. A hundred years out in practice: the code is the short-lived
    /// half of signing in, not the session it buys.
    public let expiresAt: String
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

    public init(id: String = UUID().uuidString.lowercased(), mode: String, correct: Int) {
        self.id = id
        self.mode = mode
        self.correct = correct
    }
}

/// `POST /speed/runs`. **Hand-transcribed** from `SpeedOutcome` in the server's
/// `apps/api/src/data/speed-records.ts`, and since checked against the
/// contract's `GET /speed/records`, which now declares it.
public struct SpeedOutcome: Codable, Sendable {
    public let previousBest: Int?
    public let best: Int
    public let isRecord: Bool
}

// MARK: - Errors

public struct ApiErrorBody: Codable, Sendable {
    public let error: String
}
