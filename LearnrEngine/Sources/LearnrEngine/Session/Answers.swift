import Foundation

/// How a question is answered, decided from the question itself so the play
/// screen only has to render what it is told.
///
/// Ported from `src/lib/session/answers.ts`. Pure, like everything else here.

/// Values are graded and recorded; labels are what the child reads.
public struct AnswerOption: Sendable, Equatable {
    public let value: String
    public let label: String
}

/// `tap` answers commit on the first touch — there is nothing to review, so no
/// Check button. `number` and `text` are typed and then checked.
public enum AnswerMode: String, Sendable, Equatable {
    case number, text, tap
}

public enum Answers {

    public static let booleanOptions: [AnswerOption] = [
        AnswerOption(value: "true", label: "True"),
        AnswerOption(value: "false", label: "False"),
    ]

    public static func answerMode(_ question: GeneratedQuestion) -> AnswerMode {
        if question.answerType == .boolean || question.choices != nil { return .tap }
        return question.answerType == .text ? .text : .number
    }

    /// The buttons to render for a tapped question; empty for a typed one.
    public static func answerOptions(_ question: GeneratedQuestion) -> [AnswerOption] {
        if question.answerType == .boolean { return booleanOptions }
        return (question.choices ?? []).map {
            // `String(choice)` on both — the value is graded and the label read,
            // and for a number both are the JS spelling: 2, never 2.0.
            AnswerOption(value: $0.stringValue, label: $0.stringValue)
        }
    }

    /// The correct answer as a child should read it, e.g. after getting it
    /// wrong. A boolean reads as True/False; everything else is `String(value)`.
    public static func formatAnswer(_ question: GeneratedQuestion) -> String {
        if case .boolean(let b) = question.answer { return b ? "True" : "False" }
        return question.answer.stringValue
    }

    /// Longest typed number, e.g. "1234.56". Long enough for any answer we ask
    /// for.
    public static let maxNumberLength = 8

    /// Add one keypress to a typed number. Digits, a single leading minus and at
    /// most one decimal point get through; anything else leaves the entry alone,
    /// so the pad and a physical keyboard can share one rule.
    public static func appendNumeric(_ entry: String, _ key: String) -> String {
        // `entry.length` is UTF-16 code units in JS. Every entry this builds is
        // ASCII, so `count` agrees — but the cap is checked before anything is
        // appended, which is what makes that true rather than assumed.
        if entry.count >= maxNumberLength { return entry }

        // A bare "." is not a number a child would write, so seed the zero.
        if key == "." {
            if entry.contains(".") { return entry }
            return entry.isEmpty ? "0." : entry + "."
        }
        if key == "-" { return entry.isEmpty ? "-" : entry }

        // A *string* range check in the TypeScript, not a character one, and it
        // is looser than it looks: "12" is lexicographically between "0" and
        // "9", so a two-digit key appends whole and can carry the entry one past
        // `maxNumberLength`. Swift compares strings the same way, so this is
        // written as the same comparison rather than as a digit test — a port
        // that tightened it to one character would diverge on a key no real
        // keypad sends today, and would be the wrong kind of correct.
        return key >= "0" && key <= "9" ? entry + key : entry
    }
}
