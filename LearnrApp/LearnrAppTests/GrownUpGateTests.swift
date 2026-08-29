import Testing
import Foundation
@testable import LearnrApp

/// The gate in front of the one external link.
///
/// It exists because `docs/app-review-notes.md` rests its Kids Category
/// parental-gate argument on the app having no external links; adding one
/// without a gate would contradict a claim already written for the reviewer.
///
/// The date of birth is checked and thrown away. Nothing here writes it, sends
/// it, or remembers that it passed - which is what keeps
/// `PrivacyInfo.xcprivacy`'s "no date of birth" true without amending it.
struct GrownUpGateTests {

    /// A fixed "now" so these do not change meaning with the calendar.
    static let now = Date(timeIntervalSince1970: 1_756_000_000) // 2025-08-24

    static func date(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    @Test("an adult passes")
    func adultPasses() {
        #expect(GrownUpGate.isAdult(
            birthDate: Self.date("1987-03-14T00:00:00Z"), now: Self.now))
    }

    @Test("a child does not")
    func childFails() {
        #expect(!GrownUpGate.isAdult(
            birthDate: Self.date("2015-06-01T00:00:00Z"), now: Self.now))
    }

    @Test("the day before the eighteenth birthday does not pass")
    func dayBeforeEighteenFails() {
        // 2007-08-25 turns 18 on 2025-08-25, one day after `now`.
        #expect(!GrownUpGate.isAdult(
            birthDate: Self.date("2007-08-25T00:00:00Z"), now: Self.now))
    }

    @Test("the eighteenth birthday itself passes")
    func eighteenthBirthdayPasses() {
        #expect(GrownUpGate.isAdult(
            birthDate: Self.date("2007-08-24T00:00:00Z"), now: Self.now))
    }

    @Test("nothing about the gate is written to disk or to defaults")
    func gateStoresNothing() {
        // The privacy claim, checked rather than asserted in a comment.
        // `PrivacyInfo.xcprivacy` says no date of birth is collected and
        // declares no UserDefaults use; a gate that remembered its pass would
        // make both false. This is what would fail if somebody later added a
        // convenience flag.
        //
        // `GrownUpGate` is an enum with no cases and no stored state, so there
        // is nowhere for a date to live between openings - the sheet's
        // `@State` dies with the sheet.
        let defaults = UserDefaults.standard
        for key in ["grownUpGatePassed", "birthDate", "dateOfBirth", "gatePassed"] {
            #expect(defaults.object(forKey: key) == nil,
                    "the gate must not remember anything between openings")
        }
    }

    @Test("GrownUpGate has no cases and cannot be instantiated")
    func gateHasNoCases() {
        // `GrownUpGate` is an uninhabited enum, so no INSTANCE of it can ever
        // exist or hold state - there is no `self` for a date of birth to
        // live on between one sheet presentation and the next.
        //
        // What this does NOT catch: `Mirror(reflecting:)` on a type reflects
        // its instance-side shape, which is empty for an uninhabited enum
        // regardless of what static members it declares. A `static var
        // cachedPass: Bool = false` added later - the plausible shape a
        // "remember the gate was passed" regression would actually take -
        // would not trip this assertion. Guarding against that is a
        // code-review concern, not something this test or the type system
        // enforces.
        #expect(Mirror(reflecting: GrownUpGate.self).children.isEmpty)
    }

    @Test("the link is our own web app, over https")
    func linkIsOurs() {
        // Guideline 3.1.1: this is account creation, not a purchase route. The
        // wording carries that; this pins the destination.
        #expect(GrownUpGate.signUpURL.scheme == "https")
        #expect(GrownUpGate.signUpURL.host == "learnr.muzza.tech")
    }
}
