import Foundation
@testable import LearnrEngine

/// Expressions whose expected values were written by a human, not read off the
/// engine — transcribed from `scripts/fixtures/expr-traps.ts`.
///
/// **This file is the one place in the suite that asserts rather than records.**
/// Everywhere else the TypeScript is the oracle and a digest proves agreement,
/// which means a bug on that side would be faithfully reproduced here and both
/// engines would stay green. These are the cases where idiomatic Swift silently
/// diverges from the JavaScript the content was authored against.
///
/// Harvesting from content cannot reach them: the 505 shipped templates use `^`
/// **not once**, and never use `ceil`, `trunc`, `sign`, `sqrt` or `isInt`.
///
/// **Order is contract.** The cases are hashed in sequence, so this list must
/// stay in the order the TypeScript declares. It is transcribed by hand, and
/// the digest is what catches a transcription slip — a mistyped expectation
/// changes the `traps` hash and the set goes red.
///
/// **When this file and the engine disagree, decide which is wrong.** Do not
/// edit an expectation to match the engine without saying why.
enum ExprTraps {
    struct Case {
        let expr: String
        let scope: [String: Answer]
        let expect: Answer

        init(_ expr: String, scope: [String: Answer] = [:], _ expect: Answer) {
            self.expr = expr
            self.scope = scope
            self.expect = expect
        }
    }

    static let all: [Case] = [
        // Rounding at .5, on both sides of zero. `Math.round` is half-up;
        // Swift's `rounded()` is half-away-from-zero, so the negatives are
        // where they part.
        Case("round(2.5)", .number(3)),
        Case("round(3.5)", .number(4)),
        Case("round(-2.5)", .number(-2)),
        Case("round(-3.5)", .number(-3)),
        Case("round(2.4)", .number(2)),
        Case("round(-2.4)", .number(-2)),

        // Unary minus against the power operator. `^` binds tighter, so this is
        // the negation of a square rather than the square of a negative.
        Case("-2 ^ 2", .number(-4)),
        Case("(-2) ^ 2", .number(4)),
        Case("2 ^ 3 ^ 2", .number(512)),
        Case("-2 ^ 3", .number(-8)),

        // `&&` and `||` yield booleans here, not the operand.
        Case("1 && 2", .boolean(true)),
        Case("0 || 3", .boolean(true)),
        Case("0 && 1", .boolean(false)),
        Case("!0", .boolean(true)),
        Case("!2", .boolean(false)),

        // `%` follows the dividend's sign, as in JavaScript.
        Case("-7 % 3", .number(-1)),
        Case("7 % -3", .number(1)),
        Case("-7 % -3", .number(-1)),
        Case("7 % 3", .number(1)),

        // **`mod()` is not `%`**, which is the trap nothing else here would
        // catch. It is written `((a % b) + b) % b`, so it takes the *divisor's*
        // sign where the operator takes the dividend's.
        Case("mod(-7, 3)", .number(2)),
        Case("mod(7, -3)", .number(-2)),
        Case("mod(-7, -3)", .number(-1)),
        Case("mod(7, 3)", .number(1)),

        // Division producing a whole number. The value is what a prompt hole
        // stringifies, and `"2.0"` there marks a correct answer wrong.
        Case("x / 2", scope: ["x": .number(4)], .number(2)),
        Case("x / 4", scope: ["x": .number(2)], .number(0.5)),
        Case("6 / 3", .number(2)),
        Case("1 / 3", .number(0.3333333333333333)),

        // The five functions no shipped template uses.
        Case("ceil(2.1)", .number(3)),
        Case("ceil(-2.1)", .number(-2)),
        Case("trunc(2.9)", .number(2)),
        Case("trunc(-2.9)", .number(-2)),
        Case("sign(-4)", .number(-1)),
        Case("sign(0)", .number(0)),
        Case("sign(4)", .number(1)),
        Case("sqrt(9)", .number(3)),
        Case("sqrt(2)", .number(1.4142135623730951)),
        Case("isInt(4)", .boolean(true)),
        Case("isInt(4.5)", .boolean(false)),
        Case("isInt(-4)", .boolean(true)),

        // Floor and abs across zero, where truncation and flooring part company.
        Case("floor(-2.1)", .number(-3)),
        Case("floor(2.9)", .number(2)),
        Case("abs(-3)", .number(3)),
        Case("abs(-3.5)", .number(3.5)),

        // The remaining named functions, on the awkward arguments.
        Case("gcd(12, 18)", .number(6)),
        Case("gcd(7, 13)", .number(1)),
        Case("lcm(4, 6)", .number(12)),
        Case("pow(2, 10)", .number(1024)),
        Case("pow(2, 0.5)", .number(1.4142135623730951)),
        Case("min(3, -3)", .number(-3)),
        Case("max(3, -3)", .number(3)),
        Case("isEven(0)", .boolean(true)),
        Case("isEven(-2)", .boolean(true)),
        Case("isOdd(-3)", .boolean(true)),

        // Precedence and associativity of the ordinary operators.
        Case("2 + 3 * 4", .number(14)),
        Case("(2 + 3) * 4", .number(20)),
        Case("10 - 3 - 2", .number(5)),
        Case("100 / 10 / 2", .number(5)),
        Case("1 + 2 > 2", .boolean(true)),
        Case("2 * 3 == 6", .boolean(true)),

        // The ternary, and strings.
        Case("x > 3 ? \"big\" : \"small\"", scope: ["x": .number(5)], .string("big")),
        Case("x > 3 ? \"big\" : \"small\"", scope: ["x": .number(1)], .string("small")),
        Case("\"a\" == \"a\"", .boolean(true)),

        // **`+` concatenates when either side is a string**, and that is the
        // stringification trap again in a branch nothing else reaches.
        // Left-associativity decides whether the numbers are summed first or
        // concatenated one at a time — the last two differ for that reason.
        Case("1 + \"a\"", .string("1a")),
        Case("\"a\" + 1", .string("a1")),
        Case("2 + \"0\"", .string("20")),
        Case("\"n\" + (x / 2)", scope: ["x": .number(4)], .string("n2")),
        Case("1 + 2 + \"a\"", .string("3a")),
        Case("\"a\" + 1 + 2", .string("a12")),

        // Float accumulation, which both engines must get wrong identically.
        Case("0.1 + 0.2", .number(0.30000000000000004)),
        Case("0.1 * 3", .number(0.30000000000000004)),
    ]
}
