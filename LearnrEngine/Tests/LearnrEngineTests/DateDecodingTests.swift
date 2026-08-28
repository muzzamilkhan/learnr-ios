import Testing
import Foundation
@testable import LearnrEngine

/// The one date format the API speaks, decoded.
///
/// Ten contract fields carry `format: date-time` (L1). None of the
/// hand-written models types one as a `Date` yet - `RedeemResponse.expiresAt`
/// is a `String` - so nothing decodes one today and nothing would notice this
/// being wrong. It bites the moment the generator lands, which emits `Date`
/// for all ten, and it would bite as "The data couldn't be read" on a device
/// with no way to tell which field or why. So the strategy is fixed and pinned
/// first, and separately, exactly as `L1` sequences it.
@Suite(.serialized)
struct DateDecodingTests {

    private struct Dated: Codable, Equatable {
        let at: Date
    }

    private func decode(_ iso: String) throws -> Date {
        let body = Data(#"{"at":"\#(iso)"}"#.utf8)
        return try ApiCoding.decoder().decode(Dated.self, from: body).at
    }

    /// 2023-11-14T22:13:20Z. Hand-derived: 1_700_000_000 seconds since the
    /// epoch, not computed by the code under test.
    private static let epoch = 1_700_000_000.0

    @Test("a stamp with fractional seconds decodes")
    func decodesWithFractionalSeconds() throws {
        // What `JSON.stringify` of a JS `Date` produces - `toISOString()` always
        // writes three decimal places. `ISO8601DateFormatter`'s default options
        // omit `.withFractionalSeconds`, so this shape is the one a strategy
        // built on them can stop accepting; pinned here so it cannot regress
        // silently under a toolchain move.
        let at = try decode("2023-11-14T22:13:20.123Z")
        #expect(at.timeIntervalSince1970 == Self.epoch + 0.123)
    }

    @Test("a stamp without fractional seconds decodes")
    func decodesWithoutFractionalSeconds() throws {
        // Whole-second stamps are what `.iso8601` alone accepts, and they must
        // keep working: the two shapes have to decode through one strategy,
        // because the client cannot know per-field which it will be sent.
        let at = try decode("2023-11-14T22:13:20Z")
        #expect(at.timeIntervalSince1970 == Self.epoch)
    }

    @Test("an offset other than Z decodes to the same instant")
    func decodesAnOffset() throws {
        // 22:13:20Z is 09:13:20 the next morning in Sydney (+11 in November).
        // A stamp is an instant, not a wall clock, so both must land together.
        let utc = try decode("2023-11-14T22:13:20Z")
        let sydney = try decode("2023-11-15T09:13:20+11:00")
        #expect(utc == sydney)
    }

    @Test("a value that is not a date fails as a decoding error, not a crash")
    func rejectsNonsense() {
        #expect(throws: (any Error).self) { try decode("not a date") }
    }

    @Test("the encoder writes the format the contract asks for")
    func encodesISO8601() throws {
        // `POST /speed/runs` sends a `playedAt`, so the encoder has to speak the
        // same dialect it reads.
        let data = try ApiCoding.encoder().encode(Dated(at: Date(timeIntervalSince1970: Self.epoch)))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("2023-11-14T22:13:20"))
    }

    @Test("the client itself decodes a date-time field, not just the strategy")
    func clientDecodesADate() async throws {
        // The strategy is worthless if `ApiClient` does not use it, so this goes
        // through a real endpoint and a real model. `RedeemResponse.expiresAt`
        // is the first of the ten `format: date-time` fields to be typed as a
        // `Date` rather than carried as a String - it reddens if `decode` goes
        // back to a bare `JSONDecoder()`, which is the defect L1 named.
        let session = StubProtocol.session { _ in
            (200, Data("""
            {"token":"t","childId":"c","expiresAt":"2023-11-14T22:13:20.123Z"}
            """.utf8), [:])
        }
        let client = ApiClient(baseURL: URL(string: "http://localhost:3001")!,
                               tokens: MemoryTokenStore(), session: session)

        let response = try await client.redeem(code: "ABCD")

        #expect(response.expiresAt.timeIntervalSince1970 == Self.epoch + 0.123)
    }

    @Test("a round trip through both preserves the instant")
    func roundTrips() throws {
        let original = Dated(at: Date(timeIntervalSince1970: Self.epoch + 0.5))
        let data = try ApiCoding.encoder().encode(original)
        let back = try ApiCoding.decoder().decode(Dated.self, from: data)
        #expect(back.at.timeIntervalSince1970 == original.at.timeIntervalSince1970)
    }
}
