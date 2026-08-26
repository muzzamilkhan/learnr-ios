import Foundation

/// JavaScript's `Number::toString` and `Math.round`, which Swift's own
/// equivalents get wrong in ways that matter here.
public enum JSNumber {

    /// ECMA-262 `Number::toString(x, 10)`.
    ///
    /// Swift's `"\(d)"` is also shortest-round-trip, but lays the digits out
    /// differently: it writes `2.0` where JS writes `2`, `-0.0` where JS writes
    /// `0`, `1e+20` where JS writes the full 100000000000000000000, and
    /// `inf`/`nan` where JS writes `Infinity`/`NaN`. Every one of those would
    /// reach a child as the text of a question, so the layout is redone here
    /// per the spec rather than borrowed.
    public static func toString(_ x: Double) -> String {
        if x.isNaN { return "NaN" }
        if x.isInfinite { return x > 0 ? "Infinity" : "-Infinity" }
        if x == 0 { return "0" }               // covers -0, which JS prints as "0"

        if x < 0 { return "-" + toString(-x) }

        // Swift's description is the shortest round-tripping decimal, which is
        // the same digit string the spec calls for. Take its digits and
        // exponent, then re-lay them out the way JS does.
        let (digits, pointPos) = decompose(x)
        let k = digits.count
        let n = pointPos

        if k <= n && n <= 21 {
            return digits + String(repeating: "0", count: n - k)
        }
        if 0 < n && n <= 21 {
            let i = digits.index(digits.startIndex, offsetBy: n)
            return String(digits[..<i]) + "." + String(digits[i...])
        }
        if -6 < n && n <= 0 {
            return "0." + String(repeating: "0", count: -n) + digits
        }

        // Scientific. Note JS does not zero-pad the exponent: 1e-7, not 1e-07.
        let first = String(digits.first!)
        let rest = String(digits.dropFirst())
        let mantissa = rest.isEmpty ? first : "\(first).\(rest)"
        let exponent = n - 1
        return "\(mantissa)e\(exponent >= 0 ? "+" : "-")\(abs(exponent))"
    }

    /// The significant digits of `x` with no trailing zeros, and the position
    /// of the decimal point relative to the start of those digits — so that
    /// `x == 0.digits * 10^pointPos`.
    private static func decompose(_ x: Double) -> (digits: String, pointPos: Int) {
        var repr = "\(x)"                      // shortest round-trip, e.g. "1.5", "1e-07"
        var exponent = 0

        if let eIndex = repr.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            exponent = Int(repr[repr.index(after: eIndex)...]) ?? 0
            repr = String(repr[..<eIndex])
        }

        var intPart = repr
        var fracPart = ""
        if let dot = repr.firstIndex(of: ".") {
            intPart = String(repr[..<dot])
            fracPart = String(repr[repr.index(after: dot)...])
        }

        var digits = intPart + fracPart
        // pointPos counts the integer digits, adjusted by any exponent.
        var pointPos = intPart.count + exponent

        // Strip leading zeros, each one moving the point left.
        while digits.count > 1 && digits.hasPrefix("0") {
            digits.removeFirst()
            pointPos -= 1
        }
        // Strip trailing zeros; they do not change where the point sits.
        while digits.count > 1 && digits.hasSuffix("0") {
            digits.removeLast()
        }
        if digits == "0" { return ("0", 1) }

        return (digits, pointPos)
    }

    /// `Math.round`: ties go toward **+Infinity**, not away from zero.
    ///
    /// This is the difference that would quietly change answers. Swift's
    /// `rounded()` gives -3 for -2.5; JavaScript gives -2, and the content was
    /// authored against JavaScript. No test in the web app covers a negative
    /// half, so nothing there would catch a port that got this wrong.
    public static func round(_ x: Double) -> Double {
        if x.isNaN || x.isInfinite || x == 0 { return x }
        if x > 0 && x < 0.5 { return 0 }
        if x < 0 && x >= -0.5 { return -0.0 }
        let floored = x.rounded(.down)
        return (x - floored >= 0.5) ? floored + 1 : floored
    }

    /// `Math.sign`, which returns a signed Double and preserves -0 and NaN.
    public static func sign(_ x: Double) -> Double {
        if x.isNaN { return Double.nan }
        if x == 0 { return x }                 // keeps -0 as -0
        return x > 0 ? 1 : -1
    }

    /// JS `**`, which differs from C `pow` at NaN: `pow(NaN, 0)` is 1 in C but
    /// NaN in JavaScript, and `1 ** NaN` is NaN rather than 1.
    public static func pow(_ a: Double, _ b: Double) -> Double {
        if a.isNaN && b == 0 { return Double.nan }
        if b.isNaN { return Double.nan }
        return Foundation.pow(a, b)
    }
}
