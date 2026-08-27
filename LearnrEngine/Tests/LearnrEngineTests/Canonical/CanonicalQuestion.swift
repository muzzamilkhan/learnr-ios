import Foundation
@testable import LearnrEngine

/// A `GeneratedQuestion` in canonical form, mirroring `canonicalQuestion` in
/// `scripts/fixtures/canonical.ts`.
///
/// **Field order is contract.** The fields are emitted in the order declared
/// here and the TypeScript declares the same order; a reordering on either side
/// changes every digest without changing any behaviour, which is why neither
/// side is free to tidy it.
///
/// The TypeScript's completeness guard is the compiler's — `CanonicalCovers`
/// compares key sets against `GeneratedQuestion` both ways, because a field left
/// out of the form is invisible forever. Swift has no equivalent trick for a
/// struct's stored properties, so the guard here is `CanonicalQuestionTests`'
/// fully-populated value: every field it sets must appear in the output. A
/// property added to `GeneratedQuestion` and forgotten here is caught by the
/// digest going red against a corpus that does account for it.
extension Canonical {
    static func question(_ q: GeneratedQuestion) -> [Field] {
        var fields: [Field] = [
            (name: "prompt", value: q.prompt),
            (name: "answer", value: q.answer.stringValue),
            (name: "answerType", value: q.answerType.rawValue),
        ]
        if let choices = q.choices {
            fields.append((name: "choices", value: choices.map(\.stringValue).joined(separator: "|")))
        }
        if let hint = q.hint {
            fields.append((name: "hint", value: hint))
        }
        fields.append(contentsOf: scope("vars", q.vars))
        if let figure = q.figure {
            fields.append(contentsOf: self.figure(figure))
        }
        return fields
    }

    /// A figure flattens rather than nesting: the box, then one field per mark
    /// in emitted order.
    static func figure(_ figure: Figure) -> [Field] {
        var fields: [Field] = [
            (name: "figure.width", value: JSNumber.toString(figure.width)),
            (name: "figure.height", value: JSNumber.toString(figure.height)),
        ]
        for (i, mark) in figure.marks.enumerated() {
            fields.append((name: "figure.mark.\(i)", value: self.mark(mark)))
        }
        return fields
    }

    /// A mark's kind, then its fields in the order the `Mark` type declares
    /// them, joined by `|`.
    ///
    /// The four kinds are a closed set — it is what lets the renderer stay
    /// dumb — so this switch is exhaustive by construction. A fifth kind is a
    /// decision that has escaped the engine, and it breaks this loudly rather
    /// than quietly.
    static func mark(_ mark: Mark) -> String {
        switch mark {
        case .path(let points, let closed, let fill, let dashed):
            return [
                "path",
                points.map(point).joined(separator: " "),
                String(closed),
                String(fill),
                String(dashed),
            ].joined(separator: "|")
        case .arc(let at, let radius, let from, let to):
            return [
                "arc",
                point(at),
                JSNumber.toString(radius),
                JSNumber.toString(from),
                JSNumber.toString(to),
            ].joined(separator: "|")
        case .dot(let at):
            return ["dot", point(at)].joined(separator: "|")
        case .label(let at, let text):
            return ["label", point(at), text].joined(separator: "|")
        }
    }

    /// `Point` is a tuple on the TypeScript side, `readonly [number, number]` —
    /// not an object with `x` and `y`. Both coordinates go through the JS
    /// number rendering, so a whole number is `12` and never `12.0`.
    static func point(_ p: Point) -> String {
        "\(JSNumber.toString(p.x)),\(JSNumber.toString(p.y))"
    }
}
