import Foundation

extension JSNumber {

    /// JavaScript's `Number(string)`, which grades every typed answer.
    ///
    /// Swift's `Double(_:)` is close enough to look interchangeable and is not.
    /// Six differences, each of which decides whether a child's answer is
    /// marked right:
    ///
    /// | input | `Number()` | `Double(_:)` |
    /// | --- | --- | --- |
    /// | `""`, `"   "` | `0` | `nil` |
    /// | `"0b101"` | `5` | `nil` |
    /// | `"0o17"` | `15` | `nil` |
    /// | `"0x1p4"` | `NaN` | `16` |
    /// | `"nan"`, `"inf"` | `NaN` | `nan`, `inf` |
    /// | `"1d5"` | `NaN` | `nil` (same verdict) |
    ///
    /// The empty string is the one that matters most in both directions.
    /// `Number("")` is `0`, so a child who submits nothing would be marked
    /// *correct* on any question whose answer is zero — `grade.ts` guards that
    /// with an explicit `trimmed !== ''` rather than relying on the parse, and
    /// `gradeAnswer` here keeps that guard for the same reason.
    ///
    /// Hex, binary and octal are not answers a child would type on purpose, but
    /// they are answers the oracle accepts, and a port that quietly refused
    /// them would diverge on a case the vectors pin.
    public static func parse(_ text: String) -> Double {
        // `Number` trims the ECMA-262 whitespace and line terminator set, which
        // is what `.whitespacesAndNewlines` covers, plus U+FEFF.
        let trimmed = text.trimmingCharacters(
            in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))

        // The empty (or all-whitespace) string is zero, not a failure.
        if trimmed.isEmpty { return 0 }

        // The three radix prefixes, which Swift's parser does not accept and
        // which take no sign and no exponent in JS.
        if trimmed.count > 2, trimmed.first == "0" {
            let marker = trimmed[trimmed.index(after: trimmed.startIndex)]
            let digits = String(trimmed.dropFirst(2))
            switch marker {
            case "x", "X": return radix(digits, 16)
            case "b", "B": return radix(digits, 2)
            case "o", "O": return radix(digits, 8)
            default: break
            }
        }

        // `Infinity` is spelled with a capital I and nothing else is accepted -
        // Swift would take "inf", "infinity" and "nan" in any case.
        let core = trimmed.hasPrefix("+") || trimmed.hasPrefix("-")
            ? String(trimmed.dropFirst())
            : trimmed
        if core == "Infinity" {
            return trimmed.hasPrefix("-") ? -.infinity : .infinity
        }

        // What remains must be a decimal literal: digits, at most one point, an
        // optional exponent. Validated here rather than left to `Double(_:)`,
        // which additionally accepts hex floats ("0x1p4"), the words "inf" and
        // "nan", and a bare "0x" prefix.
        guard isDecimalLiteral(core) else { return .nan }
        guard let value = Double(trimmed) else { return .nan }
        return value
    }

    /// A whole number in the given radix. Empty or ill-formed digits are `NaN`,
    /// matching `Number("0x")` and `Number("0xzz")`.
    private static func radix(_ digits: String, _ base: Int) -> Double {
        guard !digits.isEmpty else { return .nan }

        var result = 0.0
        for character in digits {
            guard let digit = character.hexDigitValue, digit < base else { return .nan }
            // Accumulated in `Double` rather than `Int`, so a literal past
            // `Int.max` saturates towards infinity the way JS does instead of
            // overflowing.
            result = result * Double(base) + Double(digit)
        }
        return result
    }

    /// `StrDecimalLiteral` without its sign: `1`, `1.`, `.5`, `1.5e-3`.
    private static func isDecimalLiteral(_ text: String) -> Bool {
        var chars = Substring(text)

        let intDigits = chars.prefix(while: \.isASCIIDigit)
        chars = chars.dropFirst(intDigits.count)

        var fractionDigits = Substring("")
        if chars.first == "." {
            chars = chars.dropFirst()
            fractionDigits = chars.prefix(while: \.isASCIIDigit)
            chars = chars.dropFirst(fractionDigits.count)
        }

        // At least one digit, on one side of the point or the other.
        if intDigits.isEmpty && fractionDigits.isEmpty { return false }

        if chars.first == "e" || chars.first == "E" {
            chars = chars.dropFirst()
            if chars.first == "+" || chars.first == "-" { chars = chars.dropFirst() }
            let exponentDigits = chars.prefix(while: \.isASCIIDigit)
            if exponentDigits.isEmpty { return false }
            chars = chars.dropFirst(exponentDigits.count)
        }

        return chars.isEmpty
    }
}

extension Character {
    /// ASCII `0`–`9` only. `isNumber` would also take `٣` and `½`, neither of
    /// which is a digit `Number()` accepts.
    var isASCIIDigit: Bool { self >= "0" && self <= "9" }
}
