import Foundation

/// Reading an authored expression into something drawable, ported from the
/// builder's half of `src/lib/figures/fields.ts`.
///
/// Absent, malformed and unbound all come back as nothing, and the kind draws a
/// fallback. The web app has a second reading of the same fields — the
/// validator's, which says in words what the builder swallowed — and that half
/// is deliberately not ported: it runs before content ships, in the repo where
/// content is authored, and nothing on a child's device calls it.

/// Evaluate a field, or nothing at all: absent, malformed and unbound all read
/// the same here.
func readField(_ expr: Expr?, _ scope: Scope) -> Value? {
    guard let expr, !expr.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
    return try? evaluate(expr, scope)
}

/// A field that has to be a number the geometry can use.
///
/// Non-finite is rejected as well as non-numeric, and that is not tidiness:
/// `NaN` is a number to JavaScript's `typeof` and fails every comparison, so a
/// `degrees` of `x / y` with both zero would pass a type check and a range
/// check and then be undrawable. The expression language does not guard
/// division, so `0 / 0`, `mod(x, 0)` and `sqrt(-1)` all arrive here looking
/// like numbers. Throwing one away and jittering instead is what the web app
/// does, so it is what this does.
func numberValue(_ value: Value?) -> Double? {
    guard case .number(let n) = value, n.isFinite else { return nil }
    return n
}

/// A field that has to be a string.
func stringValue(_ value: Value?) -> String? {
    guard case .string(let s) = value else { return nil }
    return s
}

/// The same reading of truth the expression language itself uses.
///
/// Note this is JavaScript truthiness for a non-boolean, which is the trap
/// `Value.truthy` documents: `""` is falsy but `"0"` is **truthy**.
func truthy(_ value: Value?) -> Bool {
    guard let value else { return false }
    if case .boolean(let b) = value { return b }
    return value.truthy
}

/// A number somewhere in `[low, high)` — what omitting an optional field asks
/// for.
///
/// One `next()`, always, whether or not the caller ends up using the result.
/// That matters more than it looks: the draws are a sequence, so a kind that
/// skips a jitter it does not need shifts every value drawn after it.
func jitter(_ rng: inout Rng, _ low: Double, _ high: Double) -> Double {
    low + rng.next() * (high - low)
}

func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
    Swift.min(Swift.max(value, low), high)
}

/// Split a comma-joined field into its parts, trimming each.
///
/// The list fields (`bar.values`, `spinner.sectors`, `pictograph.counts` and
/// the label lists beside them) are authored as one string because a figure
/// field is an expression and the language has no array type.
func commaList(_ text: String) -> [String] {
    text.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

/// A comma-joined field read as numbers, dropping the parts that are not.
func commaNumbers(_ text: String) -> [Double] {
    commaList(text).compactMap { part in
        // `Number(part)` in the JavaScript: an empty or non-numeric part is
        // NaN there and is filtered out, so it is dropped here too.
        guard !part.isEmpty, let n = Double(part), n.isFinite else { return nil }
        return n
    }
}
