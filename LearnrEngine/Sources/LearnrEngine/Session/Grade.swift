import Foundation

/// Ported from `src/lib/session/grade.ts`.
public struct Grade: Sendable, Equatable {
    public let correct: Bool
    /// The child's response, trimmed — recorded as typed for later analysis.
    public let response: String
}

public enum Grading {

    /// Floating point answers only ever come from decimal templates, so this is
    /// generous enough.
    static let epsilon = 1e-9

    /// What a child may have tapped or typed for a true/false question. The play
    /// screen sends "true"/"false", but a template could label the buttons
    /// yes/no, and a physical keyboard could type either — so accept both.
    static let truthy: Set<String> = ["true", "yes", "t", "y"]
    static let falsy: Set<String> = ["false", "no", "f", "n"]

    public static func gradeAnswer(_ question: GeneratedQuestion, _ response: String) -> Grade {
        // `String.prototype.trim` strips the ECMA-262 whitespace and line
        // terminator set plus U+FEFF, which is what this matches.
        let trimmed = response.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))

        if question.answerType == .boolean, case .boolean(let expected) = question.answer {
            // `toLowerCase`, not `lowercased()` — the latter is locale-sensitive
            // in some Foundation paths, and a Turkish locale maps "I" to "ı",
            // which would stop "TRUE" grading as true.
            let said = trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
            return Grade(correct: expected ? truthy.contains(said) : falsy.contains(said),
                         response: trimmed)
        }

        // The TypeScript tests `answerType === 'boolean' || typeof answer ===
        // 'boolean'`, so a boolean answer under any declared type grades this
        // way. Split from the branch above because the answer may be a boolean
        // while the type says otherwise.
        if case .boolean(let expected) = question.answer {
            let said = trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
            return Grade(correct: expected ? truthy.contains(said) : falsy.contains(said),
                         response: trimmed)
        }

        if question.answerType == .number || isNumber(question.answer) {
            let parsed = JSNumber.parse(trimmed)
            let expected = numericValue(question.answer)
            // The empty-string guard is load-bearing and not redundant:
            // `Number('')` is 0, so without it a child who submits nothing is
            // marked correct on every question whose answer is zero.
            let correct = !trimmed.isEmpty
                && !parsed.isNaN
                && abs(parsed - expected) < epsilon
            return Grade(correct: correct, response: trimmed)
        }

        let expected = question.answer.stringValue
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines
                .union(CharacterSet(charactersIn: "\u{FEFF}")))
        return Grade(
            correct: trimmed.lowercased(with: Locale(identifier: "en_US_POSIX"))
                == expected.lowercased(with: Locale(identifier: "en_US_POSIX")),
            response: trimmed)
    }

    private static func isNumber(_ answer: Answer) -> Bool {
        if case .number = answer { return true }
        return false
    }

    /// `Number(question.answer)` — the answer coerced, whatever it is declared
    /// as. A `number` answerType carrying a string answer still grades
    /// numerically, which the vectors pin.
    private static func numericValue(_ answer: Answer) -> Double {
        switch answer {
        case .number(let n): return n
        case .string(let s): return JSNumber.parse(s)
        case .boolean(let b): return b ? 1 : 0
        }
    }
}
