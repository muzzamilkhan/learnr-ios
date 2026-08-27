import Testing
import Foundation
@testable import LearnrEngine

/// The canonical form is the contract between this port and the TypeScript
/// oracle, so these hold it to the shape `scripts/fixtures/canonical.ts`
/// produces — separator for separator, field for field.
///
/// A digest mismatch says a template diverged and nothing finer. These are what
/// make that diagnosable: if the form itself is wrong, every group in every set
/// goes red at once and one of these says why.
struct CanonicalTests {
    @Test("the separators are the three the TypeScript names")
    func separators() {
        #expect(Canonical.nameSep == "\u{001f}")
        #expect(Canonical.fieldSep == "\u{001e}")
        #expect(Canonical.caseSep == "\n")
    }

    @Test("a case joins name to value, and field to field")
    func canonicaliseJoins() throws {
        let out = try Canonical.canonicalise([
            (name: "prompt", value: "What is 7 − 3?"),
            (name: "answer", value: "4"),
        ])
        #expect(out == "prompt\u{001f}What is 7 − 3?\u{001e}answer\u{001f}4")
    }

    /// The guard the TypeScript makes, failing on the same inputs. Without it a
    /// value carrying a separator would read as two fields and the digest would
    /// agree with nothing.
    @Test("a value carrying a separator is refused, not silently emitted")
    func separatorInValueThrows() {
        for bad in ["a\u{001f}b", "a\u{001e}b", "a\nb"] {
            #expect(throws: CanonicalError.self) {
                try Canonical.canonicalise([(name: "prompt", value: bad)])
            }
        }
    }

    @Test("an empty value is fine, and distinguishable from an absent field")
    func emptyValueIsNotASeparator() throws {
        let out = try Canonical.canonicalise([(name: "hint", value: "")])
        #expect(out == "hint\u{001f}")
    }

    /// Twelve hex characters of sha256 over the joined cases. Pinned against
    /// values computed by `node:crypto` so the truncation and the join are both
    /// held, not just the hash function.
    @Test("the digest is twelve hex characters of sha256 over the joined cases")
    func digestMatchesNodeCrypto() {
        // echo -n "" | shasum -a 256  ->  e3b0c44298fc...
        #expect(Canonical.digest([""]) == "e3b0c44298fc")
        // echo -n "abc" | shasum -a 256  ->  ba7816bf8f01...
        #expect(Canonical.digest(["abc"]) == "ba7816bf8f01")
        // Two cases join with a newline: "a\nb"
        #expect(Canonical.digest(["a", "b"]) == Canonical.digest(["a\nb"]))
    }

    /// **Sorted, because a Swift dictionary has no insertion order to borrow.**
    @Test("a scope sorts by name and prefixes every entry")
    func scopeSorts() {
        let fields = Canonical.scope("vars", ["b": .number(2), "a": .number(1), "c": .string("x")])
        #expect(fields.map(\.name) == ["vars.a", "vars.b", "vars.c"])
        #expect(fields.map(\.value) == ["1", "2", "x"])
    }

    /// Trap two of the four: `String(2.0)` is `"2"`, and this text reaches a
    /// child in a prompt.
    @Test("every value is its JavaScript String(v) form")
    func valuesUseJavaScriptRendering() {
        let fields = Canonical.scope("vars", [
            "whole": .number(2.0),
            "negZero": .number(-0.0),
            "flag": .boolean(true),
        ])
        #expect(fields.first { $0.name == "vars.whole" }?.value == "2")
        #expect(fields.first { $0.name == "vars.negZero" }?.value == "0")
        #expect(fields.first { $0.name == "vars.flag" }?.value == "true")
    }
}

/// The question, figure and mark forms.
struct CanonicalQuestionTests {
    /// **The completeness guard.** The TypeScript's is the compiler's, comparing
    /// key sets against `GeneratedQuestion` both ways, because a field left out
    /// of the form is invisible forever — no test can miss what it never
    /// hashes. Swift has no equivalent for stored properties, so this stands in
    /// its place: a fully-populated question, with every optional present, and
    /// an assertion naming every field that must appear.
    ///
    /// A property added to `GeneratedQuestion` and forgotten in
    /// `Canonical.question` does not fail here — but it does fail the corpus
    /// digest, against an oracle that accounts for it.
    @Test("every field of a fully-populated question is emitted, in declared order")
    func questionCoversEveryField() {
        let q = GeneratedQuestion(
            prompt: "What is 7 − 3?",
            answer: .number(4),
            answerType: .number,
            choices: [.number(4), .number(5)],
            hint: "Count back.",
            vars: ["b": .number(3), "a": .number(7)],
            figure: Figure(width: 100, height: 50, marks: [.dot(at: Point(1, 2))])
        )

        let names = Canonical.question(q).map(\.name)
        #expect(names == [
            "prompt", "answer", "answerType", "choices", "hint",
            "vars.a", "vars.b",
            "figure.width", "figure.height", "figure.mark.0",
        ])
    }

    /// Absent optionals are omitted rather than emitted empty, and every field
    /// carries its name — so omission and emptiness stay distinguishable.
    @Test("absent optionals are omitted, not emitted as empty")
    func absentOptionalsAreOmitted() {
        let q = GeneratedQuestion(
            prompt: "Say something",
            answer: .string("cat"),
            answerType: .text,
            choices: nil,
            hint: nil,
            vars: [:],
            figure: nil
        )
        #expect(Canonical.question(q).map(\.name) == ["prompt", "answer", "answerType"])
    }

    @Test("choices join with a pipe, in their JavaScript rendering")
    func choicesJoin() {
        let q = GeneratedQuestion(
            prompt: "p", answer: .number(2), answerType: .choice,
            choices: [.number(2.0), .number(3.5), .string("x")],
            hint: nil, vars: [:], figure: nil
        )
        let choices = Canonical.question(q).first { $0.name == "choices" }
        #expect(choices?.value == "2|3.5|x")
    }

    /// The four kinds are a closed set, each with its fields in the order the
    /// `Mark` type declares them.
    @Test("each mark kind writes its fields in declared order")
    func markKinds() {
        #expect(Canonical.mark(.path(
            points: [Point(12.5, 80), Point(45, 80)], closed: true, fill: false, dashed: false
        )) == "path|12.5,80 45,80|true|false|false")

        #expect(Canonical.mark(.arc(at: Point(10, 20), radius: 5, from: 0, to: 90))
            == "arc|10,20|5|0|90")

        #expect(Canonical.mark(.dot(at: Point(3, 4))) == "dot|3,4")

        #expect(Canonical.mark(.label(at: Point(0, 0), text: "12")) == "label|0,0|12")
    }

    /// A point is `x,y`, and both coordinates take the JS rendering — a whole
    /// number is `12`, never `12.0`.
    @Test("a point renders both coordinates the JavaScript way")
    func pointRendering() {
        #expect(Canonical.point(Point(12, 80)) == "12,80")
        #expect(Canonical.point(Point(12.5, -0.0)) == "12.5,0")
    }

    @Test("a figure flattens to its box and one field per mark")
    func figureFlattens() {
        let fields = Canonical.figure(Figure(
            width: 100, height: 50,
            marks: [.dot(at: Point(1, 2)), .label(at: Point(3, 4), text: "A")]
        ))
        #expect(fields.map(\.name) == ["figure.width", "figure.height", "figure.mark.0", "figure.mark.1"])
        #expect(fields.map(\.value) == ["100", "50", "dot|1,2", "label|3,4|A"])
    }
}
