import Foundation
import OpenAPIRuntime

/// The wire types, **generated** from `Contract/openapi.yaml` by
/// `swift-openapi-generator` and named here.
///
/// They were transcribed by hand until ledger `L1`. The transcription had
/// already drifted twice by the time it was replaced - `SpeedOutcome.standing`
/// was missing altogether, and `AttemptInput.figure` still is - which is the
/// whole argument for generating them: a field the contract declares and the
/// client omits is invisible until something reads it.
///
/// **These are aliases, not definitions.** The shapes live in the generated
/// `Components.Schemas` and `Operations`, which are rebuilt from the contract
/// on every build and never committed. Renaming them here keeps `ApiClient` and
/// the app reading in this app's vocabulary rather than the generator's, and
/// keeps the diff when a schema moves confined to this file.
///
/// What is still written by hand, and why:
///
/// - `YearLevel`, because the generator's enum has neither `label` nor
///   `schoolOrder` and spells its cases `_3`. `YearLevelMatchesContract` in the
///   tests is what stops it drifting.
/// - `ApiCoding` and `ISO8601`, because how a date is parsed is this client's
///   policy and is not in the document.
/// - The two `Account` helpers, which are product rules rather than shape.

// MARK: - Levels

/// Australian school year. Note the contract orders `K` last in its enum, even
/// though it sorts first everywhere in the product.
///
/// Deliberately **not** an alias for `Components.Schemas.YearLevel`. The
/// generated enum spells its cases `_1`...`_6` and `K`, carries neither `label`
/// nor `schoolOrder`, and exists twice - `YearLevel` for what the server sends
/// and `YearLevelInput` for what it accepts - so aliasing would put a
/// conversion between the read and write paths and `._3` in every call site.
///
/// The risk that costs is drift, and `YearLevelMatchesContract` covers it: it
/// asserts these raw values are exactly the generated ones, in both directions,
/// so a year added or respelled in the contract reddens the suite here rather
/// than failing to decode on a device.
public enum YearLevel: String, Codable, CaseIterable, Sendable {
    case k = "K"
    case one = "1", two = "2", three = "3"
    case four = "4", five = "5", six = "6"

    /// K first, then numerically - the order a person expects.
    public static let schoolOrder: [YearLevel] = [.k, .one, .two, .three, .four, .five, .six]

    public var label: String {
        self == .k ? "Kindergarten" : "Year \(rawValue)"
    }

    /// For the write paths, which the contract types with its own enum.
    public var input: Components.Schemas.YearLevelInput {
        .init(rawValue: rawValue)!
    }
}

// MARK: - Auth

/// `POST /auth/redeem`. The body and the 200 are declared inline on the
/// operation rather than as named schemas, so they generate under `Operations`.
public typealias RedeemRequest = Operations.redeemLoginCode.Input.Body.jsonPayload
public typealias RedeemResponse = Operations.redeemLoginCode.Output.Ok.Body.jsonPayload

/// `GET /me`.
public typealias Account = Components.Schemas.Account

extension Account {
    /// A managed child - the only kind this app can sign in.
    ///
    /// `role` is an `allOf`-wrapped `$ref`, so the shared `Role` enum arrives
    /// behind `value1` (ledger `L24`). That wrapper is what lets the null the
    /// contract permits decode to `nil` instead of throwing.
    public var isManagedChild: Bool { role?.value1 == .child && parentId != nil }

    /// A signed-in child whose account has not been read yet.
    ///
    /// The narrow case behind `L17`: a launch with no network and nothing
    /// cached, which is a device that signed in and was force-quit before
    /// `GET /me` ever came back. The token is good, so the child is in; there
    /// is simply no name to greet them by until the server can be reached.
    ///
    /// Deliberately not a managed child: `isManagedChild` is false here,
    /// because nothing has confirmed it and guessing the affirmative is how a
    /// client ends up trusting a role the server never gave it.
    public static let unread = Account(id: "")
}

// MARK: - Play

public typealias CreateSessionRequest = Components.Schemas.CreateSessionInput
public typealias SessionResponse = Components.Schemas.Session

/// One answered question, as it was answered.
///
/// `id` is the client's to choose, and the server dedupes on it: a retried
/// offline flush must write each answer once, or the child's skill row counts
/// their answers twice.
///
/// **`figure` is declared and never sent.** The hand-written model omitted the
/// property entirely; this one has it and leaves it `nil`, which is the same
/// request on the wire. Filling it would add the resolved figure - kilobytes -
/// to every attempt in every flush, which is a product change and not one a
/// regeneration should make quietly. Raised on the ledger.
public typealias AttemptPayload = Components.Schemas.AttemptInput

public typealias AttemptsRequest = Components.Schemas.AttemptsBodyInput
public typealias AttemptResult = Components.Schemas.AttemptResult

public typealias AwardRoundResponse = Operations.awardRound.Output.Ok.Body.jsonPayload
public typealias AwardTargetRequest = Operations.awardDailyTarget.Input.Body.jsonPayload
public typealias AwardTargetResponse = Operations.awardDailyTarget.Output.Ok.Body.jsonPayload

// MARK: - Play state

/// Everything the play screen needs before its first question, in one call.
///
/// This endpoint exists because assembling it from parts was five sequential
/// reads. Over the wire that is five round trips before a child sees anything,
/// which is the wrong trade on a school-run connection.
public typealias PlayState = Components.Schemas.PlayState
public typealias PlayerState = Components.Schemas.PlayerState
public typealias PlayStreak = Components.Schemas.PlayStreak
public typealias DailyTarget = Components.Schemas.DailyTarget
public typealias TargetAnswer = Components.Schemas.TargetAnswer
public typealias LearnerProfile = Components.Schemas.LearnerProfile

/// What a child can do on one topic at one year, folded from their attempts.
///
/// The wire form. `SkillRow` is the engine's, and `PlaySession.loadProfile`
/// maps one to the other - the conversion stays at the boundary rather than in
/// front of `nextSkill` and `buildProfile`, which are what the digests hold
/// this port to (ledger `L16`).
public typealias TopicSkill = Components.Schemas.TopicSkill

public typealias SetLevelRequest = Operations.writeSelectedLevel.Input.Body.jsonPayload

extension LearnerProfile {
    public static let empty = LearnerProfile(skills: [])
}

// MARK: - Speed

/// `POST /speed/runs`. Body declared inline on the operation.
public typealias SpeedRunRequest = Operations.submitSpeedRun.Input.Body.jsonPayload

extension SpeedRunRequest {
    /// Takes the stamp as the epoch milliseconds the engine and the queue
    /// speak, and hands the generated model the `Date` it types.
    ///
    /// The formatting moved to `ApiCoding.encoder()` with this: the contract
    /// declares `playedAt` as `format: date-time`, so the generator emits a
    /// `Date` where the hand-written model carried a pre-formatted `String`.
    /// The bytes on the wire are the same either way - both write the
    /// fractional-`Z` form, and `ISO8601StampTests` is what says so.
    ///
    /// `playedAt` is omitted entirely when there is nothing to say, rather than
    /// sent as null: the field is optional and the server stamps receipt in its
    /// absence (ledger `L14`).
    public init(
        id: String = UUID().uuidString.lowercased(),
        mode: String, correct: Int, playedAtMs: Int?
    ) {
        self.init(id: id, mode: mode, correct: correct,
                  playedAt: playedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1000) })
    }
}

/// `POST /speed/runs`, and `GET /speed/records`.
public typealias SpeedOutcome = Components.Schemas.SpeedOutcome

/// A run's place on the family board, and the place it displaced.
public typealias StandingChange = Components.Schemas.StandingChange

// MARK: - Errors

public typealias ApiErrorBody = Components.Schemas._Error

// MARK: - Dates

/// How the client reads and writes the contract's `format: date-time`.
///
/// Ten fields carry it, and `ApiClient` decoded with a bare `JSONDecoder()`
/// until this existed - so a `Date`-typed property would simply fail, and fail
/// as "The data couldn't be read" with no field named. The generated models
/// type all ten as `Date`, which is what this exists to read.
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
/// digests hold this port to. The generator agrees, because the contract types
/// them `integer`.
///
/// **One field that looks like a date and is not**: `POST /auth/redeem`'s
/// `expiresAt` is declared a bare `string` with no `format`, so it generates as
/// `String` where `LoginCode.expiresAt` generates as `Date`. The hand-written
/// model typed it a `Date` and so was stricter than the contract. Left as the
/// document says rather than corrected here - noted on the ledger.
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
