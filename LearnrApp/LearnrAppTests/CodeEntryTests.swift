import Testing
import Foundation
@testable import LearnrApp

/// The filter behind the sign-in field.
///
/// This screen is the one place the app uses the system keyboard, which means
/// it is the one place a child can type something the code cannot contain. The
/// field is a filter rather than a free text box, and this is that filter.
@MainActor
struct CodeEntryTests {

    @Test("lowercase is uppercased, because the charset is upper")
    func uppercases() {
        #expect(CodeEntryView.clean("kmz7") == "KMZ7")
    }

    @Test("characters outside the charset are dropped as they land")
    func dropsUntypeable() {
        // O, I and L are excluded from the charset precisely because a child
        // misreads them for 0, 1 and 1 — so they must never reach a box.
        #expect(CodeEntryView.clean("O") == "")
        #expect(CodeEntryView.clean("I") == "")
        #expect(CodeEntryView.clean("L") == "")
        #expect(CodeEntryView.clean("0") == "")
        #expect(CodeEntryView.clean("1") == "")

        // And the ones that stand in for them do.
        #expect(CodeEntryView.clean("KM29") == "KM29")
    }

    @Test("a pasted code survives its spaces and dashes")
    func filtersPunctuation() {
        // The same filter is what makes paste work: a grown-up sending the code
        // in a message may well send it spaced or hyphenated.
        #expect(CodeEntryView.clean("K M 2 9") == "KM29")
        #expect(CodeEntryView.clean("km-29") == "KM29")
    }

    @Test("nothing past the fourth character is kept")
    func capsAtLength() {
        #expect(CodeEntryView.clean("KM29XYZ") == "KM29")

        // Including when the overflow is only there because earlier characters
        // were dropped — the cut happens after the filter, not before it.
        #expect(CodeEntryView.clean("KOIL M29") == "KM29")
    }

    @Test("an empty entry stays empty")
    func empty() {
        #expect(CodeEntryView.clean("") == "")
        #expect(CodeEntryView.clean("oil") == "", "a word of nothing but excluded letters")
    }
}
