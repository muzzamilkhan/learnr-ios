import Foundation

/// The `array` kind, ported from `src/lib/figures/array-kind.ts`: a grid of
/// dots, `rows` by `columns` — the picture equal groups and multiplication are
/// actually taught from.
///
/// **`orientation` does not vary the answer — it decides which answer.**
/// Transposing a 3-row, 4-column array into 4 rows of 3 is a different picture
/// answering a different "how many rows?", even though "how many dots
/// altogether?" is unmoved. Every other kind's jitter leaves every possible
/// question about it still true; this one's does not. A template pins
/// `orientation` whenever the answer means a dimension — that obligation is the
/// author's, and the web app's validation is what reports a missing pin.
///
/// The lever that survives a fully pinned array is the **cell aspect**: the
/// vertical spacing between rows against the fixed horizontal spacing between
/// columns, drawn whether or not anything else is pinned, with no field that
/// can turn it off. That is a proportion rather than a size, so `fit` does not
/// normalise it away.

/// Where an unreadable `rows` or `columns` lands — a small, valid, drawable
/// array.
private let fallbackDimension: Double = 3

/// A safety ceiling well past what validation allows, for `build`'s "never
/// throw, always draw something" contract.
private let hardMaxDimension: Double = 14

/// How far the cell-aspect jitter may stretch or squash a row's height against
/// a column's width.
///
/// Wide enough that two draws differ well past the rounding; narrow enough that
/// every array still reads as a grid of squarish cells rather than a strip of
/// dominoes. `aspectMax` is the reciprocal, and that is load-bearing rather
/// than cosmetic: it makes stretching one axis by exactly as much as the other
/// is squashed, which is what keeps the legibility worst case a true minimum
/// over the whole range.
let aspectMin = 0.9
private let aspectMax = 1 / aspectMin

struct ArrayBuilder: FigureKindBuilder {
    let kind = "array"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let rows = drawableDimension(numberValue(readField(spec["rows"], scope)))
        let columns = drawableDimension(numberValue(readField(spec["columns"], scope)))

        // Both drawn unconditionally, whatever the spec pins — the same reason
        // `spinner` always spends a draw on `rotation`: a figure whose Rng
        // appetite depended on which fields were pinned would reshuffle the
        // question's own choices differently template to template.
        let spunOrientation = rng.next() < 0.5 ? "rows" : "columns"
        let aspect = jitter(&rng, aspectMin, aspectMax)

        let read = stringValue(readField(spec["orientation"], scope))
        let orientation = (read == "rows" || read == "columns") ? read! : spunOrientation

        // 'columns' is the transpose: what was asked for as `columns` is drawn
        // as the row count, and vice versa.
        let drawnRows = orientation == "columns" ? columns : rows
        let drawnColumns = orientation == "columns" ? rows : columns

        var marks: [Mark] = []
        for row in 0..<Int(drawnRows) {
            for col in 0..<Int(drawnColumns) {
                // x is the unsquashed axis (pitch 1); y carries the aspect.
                marks.append(.dot(at: Point(Double(col), Double(row) * aspect)))
            }
        }
        return marks
    }
}

let arrayBuilder = ArrayBuilder()

/// A whole, drawable count.
///
/// Missing, non-finite or non-positive all land on `fallbackDimension` rather
/// than on 0 or a negative clamp — a grid with a zero-length side draws no dots
/// at all, which is a worse "something drawable" than the one other kinds
/// settle for. The mistake is still reported by the web app's validation; this
/// only decides what a child sees in the meantime.
private func drawableDimension(_ value: Double?) -> Double {
    guard let value, value >= 1 else { return fallbackDimension }
    // `JSNumber.round`, not Swift's `rounded()` — the values here are positive
    // so the two agree today, but the rule is that a port matches the source.
    return clamp(JSNumber.round(value), 1, hardMaxDimension)
}
