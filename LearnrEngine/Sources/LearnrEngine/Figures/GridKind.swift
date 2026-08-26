import Foundation

/// The `grid` kind, ported from `src/lib/figures/grid-kind.ts`: a marked point
/// on a grid — the Stage 2 map read by cell, or the Stage 3 coordinate plane
/// read on the lines.
///
/// **`axisLabels` is not decoration: it is the spelling of the answer.** Column
/// 2 is drawn `2` on a numbered grid and `B` on a lettered one, so a template
/// answered `B3` with this left open is illustrated by a grid saying `2,3` on
/// about half of all draws. A template pins it on any question whose answer
/// names a cell; the web app's validation reports a missing pin.

private let labelModes = ["numbers", "letters", "none"]
private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

private let gridEpsilon = 1e-9

private let minGridDimension = 2

/// Daylight between the grid's edge and the ink of the names beside it.
private let gridLabelGap = 0.02

/// How close two of this grid's lines may be drawn, as a share of the drawn
/// span.
///
/// A grid is the sharpest case there is for measuring against the report row
/// rather than the play screen: the child counts squares across and up to say
/// where the mark is, and a thumbnail where the lines have merged into a grey
/// block is a picture that cannot answer its own question.
private let minLinePitch = (minMarkGapPx / reportBoxPx) * (figureBox / drawnSpan)

/// The widest grid the builder will ever *choose* for itself.
///
/// Derived, not picked: an unlabelled grid's cell is `1 / max(columns, rows)`,
/// so this is the largest side whose lines still clear `minLinePitch`, and no
/// label arrangement can beat it because labels only ever take room away.
private let maxCandidateDimension = Int((1 / minLinePitch).rounded(.down))

/// A hard ceiling on what is *drawn* for a pinned dimension, for the
/// never-throw contract. Forty by forty is 165 marks, inside `maxMarks`.
private let maxDrawnDimension = 40

/// A positive cell for a spec whose labels have eaten the whole frame.
private let minDrawnCell = 1e-3

private let fallbackAt = Point(1, 1)

struct GridBuilder: FigureKindBuilder {
    let kind = "grid"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let onLines = truthy(readField(spec["onLines"], scope))
        let read = stringValue(readField(spec["at"], scope))
        let point = drawablePoint(read.flatMap(parseAt), onLines)
        let askedColumns = numberValue(readField(spec["columns"], scope))
        let askedRows = numberValue(readField(spec["rows"], scope))

        // **Two draws, always, whichever fields a template pinned.** One `Rng`
        // runs through the figure into the question's own choice building, so a
        // figure whose appetite depended on what was pinned would reshuffle the
        // distractors of the very question it illustrates. A pick from a
        // single-item list is still a pick.
        let labels = rng.pick(labelModesFor(spec, scope, onLines))
        let extent = rng.pick(extentsToDraw(
            point, askedColumns, askedRows, labels, onLines
        ))

        return gridMarks(
            layoutFor(extent.0, extent.1, labels, onLines), point
        )
    }
}

let gridBuilder = GridBuilder()

/// The name of a column, 1-based: `A` to `Z`, then `AA`, `AB`, … — one to one
/// over every index of 1 or more, so no column is ever unnamed and no two share
/// a name.
func columnLabel(_ index: Int) -> String {
    var remaining = Swift.max(1, index)
    var text = ""
    while remaining > 0 {
        text = String(alphabet[(remaining - 1) % 26]) + text
        remaining = (remaining - 1) / 26
    }
    return text
}

/// The point, or nothing. Strict: a hole in `"2,"` is a typo, not a coordinate
/// of 0.
private func parseAt(_ text: String) -> Point? {
    let pieces = commaList(text)
    guard pieces.count == 2, !pieces.contains(where: { $0.isEmpty }) else { return nil }
    guard let x = Double(pieces[0]), let y = Double(pieces[1]),
          x.isFinite, y.isFinite else { return nil }
    return Point(x, y)
}

/// The smallest column or row number there is: a cell grid starts at 1, a plane
/// at 0.
private func axisFloor(_ onLines: Bool) -> Double { onLines ? 0 : 1 }

/// A whole point inside the first quadrant. Rounding and clamping rather than
/// refusing, because `build` owes a child a drawing.
private func drawablePoint(_ point: Point?, _ onLines: Bool) -> Point {
    guard let point else { return fallbackAt }
    let floor = axisFloor(onLines)
    return Point(
        Swift.max(JSNumber.round(point.x), floor),
        Swift.max(JSNumber.round(point.y), floor)
    )
}

/// The notations this grid could be drawn in.
///
/// A readable `axisLabels` pins it; anything else asks for the jitter — and on
/// a coordinate plane the jitter has only one face, since a lettered axis
/// cannot say a coordinate. That makes this the one optional field whose
/// absence is not a free coin toss.
private func labelModesFor(_ spec: FigureSpec, _ scope: Scope, _ onLines: Bool) -> [String] {
    let asked = stringValue(readField(spec["axisLabels"], scope))
    if let asked, labelModes.contains(asked) { return [asked] }
    return onLines ? ["numbers"] : ["numbers", "letters"]
}

/// The numbers written along an axis: 1..n between the lines, 0..n on them.
private func axisValues(_ count: Int, _ onLines: Bool) -> [Int] {
    onLines ? Array(0...count) : (0..<count).map { $0 + 1 }
}

/// How far along the axis the k-th of those sits, in frame units.
private func alongAxis(_ index: Int, _ onLines: Bool, _ cell: Double) -> Double {
    onLines ? Double(index) * cell : (Double(index) + 0.5) * cell
}

private func widestText(_ texts: [String]) -> Double {
    texts.reduce(0.0) { Swift.max($0, Double($1.count)) }
}

/// The room two neighbouring names need between their centres.
///
/// Asked of every adjacent *pair* rather than of the widest name, because the
/// two that crowd each other are not always the two longest.
private func widestNeighbours(_ texts: [String]) -> Double {
    var widest = 0.0
    var index = 0
    while index + 1 < texts.count {
        let pair = (Double(texts[index].count) + Double(texts[index + 1].count)) / 2
            + labelDaylight
        widest = Swift.max(widest, pair * charShare)
        index += 1
    }
    return widest
}

/// A grid resolved into frame units, with its larger side exactly 1 — the
/// normalisation the label shares are stated against.
private struct GridLayout {
    var columns: Int
    var rows: Int
    var labels: String
    var onLines: Bool
    var cell: Double
    var columnTexts: [String]
    var rowTexts: [String]
    var left: Double
    var bottom: Double
    var rightOverhang: Double
    var topOverhang: Double
}

private func layoutFor(
    _ columns: Int, _ rows: Int, _ labels: String, _ onLines: Bool
) -> GridLayout {
    let lettered = labels == "letters"
    let columnTexts: [String] = labels == "none" ? [] : axisValues(columns, onLines).map {
        // On a plane the letters start at the origin line, so `A` is 0 and no
        // two lines share a name.
        lettered ? columnLabel(onLines ? $0 + 1 : $0) : String($0)
    }
    // Rows carry numbers in both notations: "B3" is the map convention, and a
    // lettered *row* would leave a cell with two letters and no number.
    let rowTexts: [String] = labels == "none" ? [] : axisValues(rows, onLines).map(String.init)

    let labelled = labels != "none"
    let rowInk = widestText(rowTexts) * charShare
    let firstColumnInk = Double(columnTexts.first?.count ?? 0) * charShare
    let lastColumnInk = Double(columnTexts.last?.count ?? 0) * charShare

    let left = labelled
        ? Swift.min(-(gridLabelGap + rowInk), onLines ? -firstColumnInk / 2 : 0)
        : 0
    let bottom = labelled ? -(gridLabelGap + inkShare) : 0
    let rightOverhang = labelled && onLines ? lastColumnInk / 2 : 0
    let topOverhang = labelled && onLines ? inkShare / 2 : 0

    // The larger side comes out exactly 1, which is what makes the fit's scale
    // exactly `drawnSpan` and the label shares directly comparable with the
    // geometry here. The one exception is the frame the labels have eaten
    // entirely, where the clamp keeps the cell positive.
    let cell = Swift.max(
        Swift.min(
            (1 - (rightOverhang - left)) / Double(columns),
            (1 - (topOverhang - bottom)) / Double(rows)
        ),
        minDrawnCell
    )

    return GridLayout(
        columns: columns, rows: rows, labels: labels, onLines: onLines, cell: cell,
        columnTexts: columnTexts, rowTexts: rowTexts, left: left, bottom: bottom,
        rightOverhang: rightOverhang, topOverhang: topOverhang
    )
}

/// The smallest cell this grid can be drawn at and still be read in a parent's
/// 64px report row.
///
/// A per-figure budget rather than a constant: how many columns a template
/// asked for is data, so the limit is computed from the layout that figure will
/// actually get.
private func neededCell(_ layout: GridLayout) -> Double {
    var cell = minLinePitch

    if layout.labels != "none" {
        if pitchShare > cell { cell = pitchShare }
        let along = widestNeighbours(layout.columnTexts)
        if along > cell { cell = along }
    }

    return cell
}

private func isLegible(_ layout: GridLayout) -> Bool {
    layout.cell + gridEpsilon >= neededCell(layout)
}

/// A pinned dimension as it will really be drawn, or nothing where the builder
/// is choosing.
private func pinnedDimension(_ asked: Double?) -> Int? {
    guard let asked else { return nil }
    return Int(clamp(JSNumber.round(asked), 1, Double(maxDrawnDimension)))
}

/// The smallest grid that could hold a point this far along one axis.
private func leastFor(_ coordinate: Double) -> Int {
    Swift.max(minGridDimension, Int(coordinate))
}

/// The extents the builder picks between: every grid wide and tall enough to
/// hold the point that still reads in a report row.
///
/// A dimension the author pinned is the only candidate for that dimension — it
/// is their grid — and it is still filtered, so a pinned extent nobody could
/// read leaves this empty and falls through.
private func extentCandidates(
    _ point: Point, _ askedColumns: Double?, _ askedRows: Double?,
    _ labels: String, _ onLines: Bool
) -> [(Int, Int)] {
    func spread(_ pinned: Int?, _ least: Int) -> [Int] {
        if let pinned { return [pinned] }
        guard least <= maxCandidateDimension else { return [] }
        return Array(least...maxCandidateDimension)
    }

    let columnsList = spread(pinnedDimension(askedColumns), leastFor(point.x))
    let rowsList = spread(pinnedDimension(askedRows), leastFor(point.y))

    var pairs: [(Int, Int)] = []
    for columns in columnsList {
        for rows in rowsList {
            if isLegible(layoutFor(columns, rows, labels, onLines)) {
                pairs.append((columns, rows))
            }
        }
    }
    return pairs
}

/// The grid drawn when nothing legible holds the point: the smallest one that
/// holds it at all, or exactly what the author pinned.
///
/// **Honouring an illegible pinned extent is deliberate.** The extent is what
/// the grid *is*, and a prompt saying "this 8 by 8 grid" over a 5 by 5 one is a
/// figure contradicting its own question, which is worse than one merely
/// cramped.
private func fallbackExtent(
    _ point: Point, _ askedColumns: Double?, _ askedRows: Double?
) -> (Int, Int) {
    // The point's own reach is capped here for `build`'s sake alone: a
    // hand-authored `at: '1000000000,1'` would otherwise ask for a billion
    // rules and hang the very screen this exists to keep drawing.
    (
        pinnedDimension(askedColumns) ?? Swift.min(leastFor(point.x), maxDrawnDimension),
        pinnedDimension(askedRows) ?? Swift.min(leastFor(point.y), maxDrawnDimension)
    )
}

private func extentsToDraw(
    _ point: Point, _ askedColumns: Double?, _ askedRows: Double?,
    _ labels: String, _ onLines: Bool
) -> [(Int, Int)] {
    let candidates = extentCandidates(point, askedColumns, askedRows, labels, onLines)
    return !candidates.isEmpty
        ? candidates
        : [fallbackExtent(point, askedColumns, askedRows)]
}

private func rule(_ from: Point, _ to: Point) -> Mark {
    .path(points: [from, to], closed: false, fill: false, dashed: false)
}

/// The drawing, in index order throughout.
///
/// Nothing here iterates a set or a dictionary: an order that depends on
/// insertion is variation the JSON sees and a child does not, which is how a
/// picture can pass the anchoring check while anchoring.
private func gridMarks(_ layout: GridLayout, _ point: Point) -> [Mark] {
    let cell = layout.cell
    let width = Double(layout.columns) * cell
    let height = Double(layout.rows) * cell
    var marks: [Mark] = []

    // The bottom and left edges, run out to where the label ink ends — the
    // overhang that makes containment an identity.
    marks.append(rule(Point(layout.left, 0), Point(width + layout.rightOverhang, 0)))
    marks.append(rule(Point(0, layout.bottom), Point(0, height + layout.topOverhang)))

    for column in 1...Swift.max(1, layout.columns) where layout.columns >= 1 {
        marks.append(rule(
            Point(Double(column) * cell, 0), Point(Double(column) * cell, height)
        ))
    }
    for row in 1...Swift.max(1, layout.rows) where layout.rows >= 1 {
        marks.append(rule(
            Point(0, Double(row) * cell), Point(width, Double(row) * cell)
        ))
    }

    let rowLabelX = -(gridLabelGap + (widestText(layout.rowTexts) * charShare) / 2)
    let columnLabelY = layout.bottom + inkShare / 2

    for (index, text) in layout.columnTexts.enumerated() {
        marks.append(.label(
            at: Point(alongAxis(index, layout.onLines, cell), columnLabelY), text: text
        ))
    }
    for (index, text) in layout.rowTexts.enumerated() {
        marks.append(.label(
            at: Point(rowLabelX, alongAxis(index, layout.onLines, cell)), text: text
        ))
    }

    // Clamped into the grid, not refused: a point outside it is reported, and
    // here it only has to be drawable.
    let floor = axisFloor(layout.onLines)
    let column = clamp(point.x, floor, Double(layout.columns))
    let row = clamp(point.y, floor, Double(layout.rows))
    marks.append(.dot(at: layout.onLines
        ? Point(column * cell, row * cell)
        : Point((column - 0.5) * cell, (row - 0.5) * cell)
    ))

    return marks
}
