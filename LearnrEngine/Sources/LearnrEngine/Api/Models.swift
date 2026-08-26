import Foundation

/// The wire types the child client needs, transcribed from
/// `learnr-api/contract/openapi.yaml`.
///
/// Where the contract declares a real schema, these mirror it exactly. Three of
/// the endpoints this app calls declare `schema: {}` instead - `/me`,
/// `/speed/runs` and `/speed/records` - so those models are transcribed from
/// the server's TypeScript rather than generated, and are marked below. See
/// learnr-api#1; when that is fixed these should be regenerated and the
/// hand-written ones deleted.

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

/// `GET /me`. **Hand-transcribed** from `Account` in the server's
/// `src/data/accounts.ts` - the contract says `schema: {}` (learnr-api#1).
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
/// `src/data/speed-records.ts` - the contract says `schema: {}` (learnr-api#1).
public struct SpeedOutcome: Codable, Sendable {
    public let previousBest: Int?
    public let best: Int
    public let isRecord: Bool
}

// MARK: - Errors

public struct ApiErrorBody: Codable, Sendable {
    public let error: String
}
