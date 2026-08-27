import Testing
import Foundation
@testable import LearnrEngine

/// The grading set: draw 0 of every template, graded against a constructed
/// response list, mirroring `scripts/fixtures/grading.ts`.
///
/// **The near-misses are the content.** `gradeAnswer` compares a numeric answer
/// with `EPSILON` (1e-9), so `answer + 1e-10` must be correct and
/// `answer + 1e-8` must not — a port choosing a different tolerance, or
/// comparing exactly, parts company on exactly one of those two and on nothing
/// else. The rest of the list is the surrounding shape: padding, case, the
/// empty string, junk, and the eight boolean spellings.
///
/// One draw a template rather than all hundred, because grading reads the
/// answer and the answer type and nothing else about how the question was
/// drawn. What varies usefully is the response, which is why that list is
/// constructed rather than sampled.
struct GradingDigestTests {
    /// What a child may have tapped or typed for a true/false question.
    static let booleanSpellings = ["true", "yes", "t", "y", "false", "no", "f", "n"]

    /// The responses each question is graded against, in the order
    /// `responsesFor` builds them — order is contract, because the cases are
    /// hashed in sequence.
    ///
    /// Deduplicated in **first-insertion order**, matching the TypeScript's
    /// `[...new Set(responses)]`. Swift has no ordered set, so this is a
    /// deliberate ordered dedupe rather than a `Set`.
    static func responses(for q: GeneratedQuestion) -> [String] {
        let answer = q.answer.stringValue
        var responses = [
            answer,
            " \(answer) ",
            answer.uppercased(),
            answer.lowercased(),
            "",
            "abc",
            "0",
        ]

        // `answerType === 'boolean' || typeof answer === 'boolean'`, both arms,
        // because the two can disagree: a `choice` question whose answer
        // happens to be a boolean takes this branch on the oracle's side too.
        var isBoolean = q.answerType == .boolean
        if case .boolean = q.answer { isBoolean = true }
        if isBoolean { responses.append(contentsOf: booleanSpellings) }

        // The same shape for numbers. `Number(question.answer)` coerces where
        // the answer is not already one — `Number("cat")` is `NaN`, and
        // `String(NaN + 1e-10)` is `"NaN"`, which is a response the oracle
        // records rather than skips.
        var isNumber = q.answerType == .number
        if case .number = q.answer { isNumber = true }
        if isNumber {
            let n = JSNumber.parse(q.answer.stringValue)
            // Every derived value goes back through the JS rendering, so the
            // strings match what the oracle wrote.
            responses.append(contentsOf: [
                JSNumber.toString(n + 1e-10),
                JSNumber.toString(n - 1e-10),
                JSNumber.toString(n + 1e-8),
                JSNumber.toString(n - 1e-8),
                JSNumber.toString(n + 1),
                "\(JSNumber.toString(n)).0",
                "0\(JSNumber.toString(n))",
            ])
        }

        for choice in q.choices ?? [] { responses.append(choice.stringValue) }

        var seen = Set<String>()
        return responses.filter { seen.insert($0).inserted }
    }

    @Test("grading reproduces the oracle's digest, template for template")
    func gradingDigestsMatch() throws {
        let oracle = Fixtures.digest(set: "grading")
        var checked = 0

        for template in Fixtures.templates {
            var rng = Rng(seed: Fixtures.seed(template.id, 0))
            let q = try generateQuestion(template, &rng).question

            let cases = try Self.responses(for: q).map { response -> String in
                let grade = Grading.gradeAnswer(q, response)
                return try Canonical.canonicalise([
                    (name: "answer", value: q.answer.stringValue),
                    (name: "answerType", value: q.answerType.rawValue),
                    (name: "response", value: JSQuote.quote(response)),
                    (name: "correct", value: String(grade.correct)),
                    (name: "recorded", value: JSQuote.quote(grade.response)),
                ])
            }

            #expect(
                Canonical.digest(cases) == oracle.groups[template.id],
                "\(template.id) grades differently from the oracle — run `npm run fixtures:emit \(template.id)` in ../learnr"
            )
            checked += 1
        }

        #expect(checked == 505)
    }
}

/// `JSON.stringify` on a single string, which the grading set needs and which
/// `JSONEncoder` cannot supply — see `JSQuote`.
struct JSQuoteTests {
    @Test("a plain string is quoted and otherwise untouched")
    func plain() {
        #expect(JSQuote.quote("4") == "\"4\"")
        #expect(JSQuote.quote("") == "\"\"")
    }

    /// The reason the grading set quotes at all: padding has to survive into
    /// the diff, and the empty response has to be distinguishable from it.
    @Test("padding survives, and is visible")
    func padding() {
        #expect(JSQuote.quote(" 5 ") == "\" 5 \"")
    }

    /// **Non-ASCII passes through as itself.** This is where a general JSON
    /// encoder would diverge, and every one of these characters appears in a
    /// prompt.
    @Test("the characters a prompt carries are emitted unescaped")
    func nonASCII() {
        #expect(JSQuote.quote("3 − 2 × 4 ÷ 2 ° $") == "\"3 − 2 × 4 ÷ 2 ° $\"")
    }

    @Test("quote and backslash take their short escapes")
    func shortEscapes() {
        #expect(JSQuote.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
        #expect(JSQuote.quote("a\nb") == "\"a\\nb\"")
        #expect(JSQuote.quote("a\tb") == "\"a\\tb\"")
    }

    /// A control character with no short escape takes the lowercase four-digit
    /// form — and these are exactly the characters that would otherwise collide
    /// with the canonical form's own separators.
    @Test("a separator character is escaped rather than emitted raw")
    func controlCharacters() {
        #expect(JSQuote.quote("a\u{001f}b") == "\"a\\u001fb\"")
        #expect(JSQuote.quote("a\u{001e}b") == "\"a\\u001eb\"")
    }
}
