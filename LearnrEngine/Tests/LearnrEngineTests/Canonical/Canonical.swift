import Foundation
import CryptoKit
@testable import LearnrEngine

/// The canonical form both engines hash, and the reason it is not JSON.
///
/// This mirrors `scripts/fixtures/canonical.ts` in `learnr`. Two JSON encoders
/// in two languages have to agree about escaping before their output can be
/// compared, and a rendered prompt carries the minus sign, times, divide,
/// degree and dollar — exactly where they differ on when to escape non-ASCII.
/// So the form is written out by hand on both sides instead.
///
/// **Every value is its JavaScript `String(v)` form**, which is the rule that
/// earns its keep. `generateQuestion` already keys the expected answer and the
/// distractor dedup off `String(value)`, so a port yielding `"2.0"` where the
/// oracle says `"2"` marks a correct answer wrong *and* can offer a distractor
/// identical to the answer. Hashing this form makes the digest test the thing
/// this port had to get right anyway. `Answer.stringValue` and
/// `JSNumber.toString` are where that lives in the engine, so nothing here
/// reimplements it — this file only arranges values that the engine rendered.
///
/// It lives in the test target rather than in `LearnrEngine` because the app
/// never hashes a question. Shipping it would be dead code in the binary and a
/// wider public API to keep stable.
enum Canonical {
    /// Between a field's name and its value.
    static let nameSep = "\u{001f}"
    /// Between the fields of one case.
    static let fieldSep = "\u{001e}"
    /// Between cases. A rendered prompt is one line by construction.
    static let caseSep = "\n"

    /// A named value. The name is always emitted, so an absent optional field
    /// is distinguishable from one that is present and empty.
    typealias Field = (name: String, value: String)

    private static let separators: Set<Character> = ["\u{001e}", "\u{001f}", "\n"]

    /// One case's fields, joined.
    ///
    /// Throws on a value containing a separator, so the assumption that none
    /// can occur is a check rather than a hope — the same guard the TypeScript
    /// makes, and it has to fail on the same inputs.
    static func canonicalise(_ fields: [Field]) throws -> String {
        try fields.map { field in
            guard !field.value.contains(where: separators.contains) else {
                throw CanonicalError.separatorInValue(name: field.name, value: field.value)
            }
            return "\(field.name)\(nameSep)\(field.value)"
        }
        .joined(separator: fieldSep)
    }

    /// Twelve hex characters of sha256 over the joined cases — `content-packs`'
    /// function and truncation, on both sides.
    static func digest(_ cases: [String]) -> String {
        let joined = cases.joined(separator: caseSep)
        let hash = SHA256.hash(data: Data(joined.utf8))
        return hash.map { String(format: "%02x", $0) }.joined().prefix(12).description
    }

    /// A scope's entries, sorted by key and named `<prefix>.<key>`.
    ///
    /// **Sorted because a Swift dictionary has no insertion order to borrow.**
    /// The TypeScript sorts for exactly this reason, so that the two agree
    /// without either depending on how a map happened to be built.
    ///
    /// The sort is `<` on the raw strings, matching the TypeScript's
    /// `(a, b) => (a < b ? -1 : 1)`. Swift's `<` on `String` is a Unicode
    /// canonical ordering while JavaScript's compares UTF-16 code units; the
    /// two agree over the ASCII identifiers a variable name can be, which is
    /// what `vars` and every harvested scope hold.
    static func scope(_ prefix: String, _ scope: [String: Answer]) -> [Field] {
        scope.keys.sorted().map { (name: "\(prefix).\($0)", value: scope[$0]!.stringValue) }
    }

    /// The same, for the `Value`-typed scope `evaluate` takes. One rule, two
    /// entry points — written twice rather than generically so that neither can
    /// sort differently from the other, which is the failure the TypeScript
    /// avoids by having `canonicalScope` be the single function.
    static func scopeOfValues(_ prefix: String, _ scope: Scope) -> [Field] {
        scope.keys.sorted().map { (name: "\(prefix).\($0)", value: scope[$0]!.stringValue) }
    }
}

enum CanonicalError: Error, CustomStringConvertible {
    case separatorInValue(name: String, value: String)

    var description: String {
        switch self {
        case .separatorInValue(let name, let value):
            return "Canonical value for \(name) contains a separator: \(value.debugDescription)"
        }
    }
}
