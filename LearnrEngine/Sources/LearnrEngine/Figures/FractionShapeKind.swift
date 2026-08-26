import Foundation

/// The `fraction-shape` kind, ported from
/// `src/lib/figures/fraction-shape-kind.ts`: a shape cut into equal parts with
/// some of them shaded.
///
/// **Never simplified.** 2/4 is drawn as quarters with two shaded, not as a
/// half — the picture is the question, and simplifying it would answer a
/// different one.

let fractionShapes = ["circle", "rectangle", "strip"]

private let minDenominator: Double = 2
private let fallbackDenominator: Double = 4
private let fallbackNumerator: Double = 1
private let hardMaxDenominator: Double = 60

private let stripHeight = 0.4

/// How many real report-row pixels one unit of a fitted drawing is worth.
private let reportPxPerUnit = drawnSpan * (reportBoxPx / figureBox)

/// The smallest segment that reads as a region rather than a thick line.
private let minSegmentPx = reportStrokePx * 3

/// The most equal parts a straight run can be cut into and still be counted.
let maxLinearParts = Int((reportPxPerUnit / minSegmentPx).rounded(.down))

/// The most equal sectors a disc can be cut into and still be counted.
let maxCircleParts = Int((360 / minSectorDegrees).rounded(.down))

struct FractionShapeBuilder: FigureKindBuilder {
    let kind = "fraction-shape"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let denominator = drawableDenominator(
            numberValue(readField(spec["denominator"], scope))
        )
        let numerator = drawableNumerator(
            numberValue(readField(spec["numerator"], scope)), denominator
        )

        // Every one of these four is drawn whether or not the field it might
        // feed is pinned, so a figure's appetite off the question's shared
        // `Rng` never depends on what a template chose to fix.
        let spunShape = rng.pick(fractionShapes)
        let spunRotation = jitter(&rng, 0, 360)
        let offset = rng.int(0, Int(denominator) - 1)
        let pairs = gridFactorPairs(Int(denominator))
        let (rows, columns) = rng.pick(
            pairs.isEmpty ? [(1, Int(denominator))] : pairs
        )

        let readShape = stringValue(readField(spec["shape"], scope))
        let requestedShape = (readShape.map(fractionShapes.contains) == true)
            ? readShape! : spunShape
        let shape = resolvedShape(requestedShape, Int(denominator))

        let rotation = numberValue(readField(spec["rotation"], scope)) ?? spunRotation
        let shaded = shadedSlots(Int(denominator), Int(numerator), offset)

        if shape == "circle" { return circleMarks(Int(denominator), shaded, rotation) }
        if shape == "strip" { return stripMarks(Int(denominator), shaded) }
        return rectangleMarks(rows, columns, shaded)
    }
}

let fractionShapeBuilder = FractionShapeBuilder()

/// The ways a denominator can be laid out as a grid of at least two by two.
///
/// Both orientations of an asymmetric split appear as separate entries — `(2, 6)`
/// and `(6, 2)` both turn up for a denominator of 12 — which is what lets
/// "which way round the grid runs" be a real lever.
func gridFactorPairs(_ denominator: Int) -> [(Int, Int)] {
    var pairs: [(Int, Int)] = []
    var rows = 2
    while rows <= denominator / 2 {
        defer { rows += 1 }
        if denominator % rows != 0 { continue }
        let columns = denominator / rows
        if columns < 2 { continue }
        if Swift.max(rows, columns) > maxLinearParts { continue }
        pairs.append((rows, columns))
    }
    return pairs
}

/// Whether this shape can draw `denominator` equal parts at all, let alone
/// legibly.
private func shapeSupports(_ shape: String, _ denominator: Int) -> Bool {
    if shape == "circle" { return denominator <= maxCircleParts }
    if shape == "strip" { return denominator <= maxLinearParts }
    return !gridFactorPairs(denominator).isEmpty
}

private func drawableDenominator(_ value: Double?) -> Double {
    guard let value, value.isFinite, value >= minDenominator else {
        return fallbackDenominator
    }
    return clamp(JSNumber.round(value), minDenominator, hardMaxDenominator)
}

private func drawableNumerator(_ value: Double?, _ denominator: Double) -> Double {
    guard let value, value.isFinite, value >= 0 else {
        return Swift.min(fallbackNumerator, denominator)
    }
    return clamp(JSNumber.round(value), 0, denominator)
}

/// A shape a jitter or a broken pin landed on, resolved into one this
/// denominator can actually be drawn on.
///
/// Tried in a fixed order — circle, then strip, then rectangle — so the
/// substitution is a deterministic function of `(requested, denominator)` and
/// costs no extra draw off the `Rng`.
private func resolvedShape(_ requested: String, _ denominator: Int) -> String {
    if shapeSupports(requested, denominator) { return requested }
    if shapeSupports("circle", denominator) { return "circle" }
    if shapeSupports("strip", denominator) { return "strip" }
    return "rectangle"
}

/// Which physical parts are shaded: a contiguous run of `numerator` slots out
/// of `denominator`, starting at `offset` and wrapping round.
///
/// Contiguous because that is how an area model is drawn in every classroom
/// resource this content is written against — a scattered set of shaded cells
/// answers the same fraction but is not the picture a child has been shown.
private func shadedSlots(_ denominator: Int, _ numerator: Int, _ offset: Int) -> Set<Int> {
    var shaded: Set<Int> = []
    for step in 0..<Swift.max(0, numerator) {
        shaded.insert((offset + step) % denominator)
    }
    return shaded
}

private func closedPath(_ points: [Point], _ fill: Bool) -> Mark {
    .path(points: points, closed: true, fill: fill, dashed: false)
}

private func openPath(_ points: [Point]) -> Mark {
    .path(points: points, closed: false, fill: false, dashed: false)
}

private func rectangleCorners(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> [Point] {
    [Point(x0, y0), Point(x1, y0), Point(x1, y1), Point(x0, y1)]
}

/// A disc cut into `denominator` equal sectors.
///
/// `step` is computed once and reused for every sector's start angle, which is
/// the whole of "equal parts are exactly equal" for this shape: there is one
/// division, not `denominator` of them, so there is nothing for per-sector
/// arithmetic to disagree about.
private func circleMarks(_ denominator: Int, _ shaded: Set<Int>, _ rotation: Double) -> [Mark] {
    let step = 360 / Double(denominator)
    func onRim(_ degrees: Double) -> Point {
        let radians = degrees * .pi / 180
        return Point(Foundation.cos(radians), Foundation.sin(radians))
    }

    var marks: [Mark] = []

    for sector in 0..<denominator {
        if !shaded.contains(sector) { continue }
        let from = rotation + Double(sector) * step
        let samples = Swift.max(1, Int((step / (360 / Double(discRimPoints))).rounded(.up)))
        var points: [Point] = [Point(0, 0)]
        for index in 0...samples {
            points.append(onRim(from + (step * Double(index)) / Double(samples)))
        }
        marks.append(closedPath(points, true))
    }

    marks.append(closedPath(
        (0..<discRimPoints).map { onRim(Double($0) * 360 / Double(discRimPoints)) },
        false
    ))

    for sector in 0..<denominator {
        marks.append(openPath([Point(0, 0), onRim(rotation + Double(sector) * step)]))
    }

    return marks
}

/// A bar cut into `denominator` equal vertical segments.
private func stripMarks(_ denominator: Int, _ shaded: Set<Int>) -> [Mark] {
    let width = 1 / Double(denominator)
    var marks: [Mark] = []

    for segment in 0..<denominator {
        if !shaded.contains(segment) { continue }
        let x0 = Double(segment) * width
        marks.append(closedPath(rectangleCorners(x0, 0, x0 + width, stripHeight), true))
    }

    marks.append(closedPath(rectangleCorners(0, 0, 1, stripHeight), false))

    for segment in 1..<Swift.max(1, denominator) {
        let x = Double(segment) * width
        marks.append(openPath([Point(x, 0), Point(x, stripHeight)]))
    }

    return marks
}

/// A `rows` by `columns` grid of equal square cells.
///
/// **Shaded cells are emitted by walking every index in order, not by iterating
/// the set itself.** Two different offsets that shade the same cells would
/// otherwise serialise two different mark arrays for one identical on-screen
/// picture — a lever the anchoring check would pass and a child could not see.
/// Swift's `Set` has no defined order at all, so walking by index is what makes
/// this reproducible as well as what makes it right.
private func rectangleMarks(_ rows: Int, _ columns: Int, _ shaded: Set<Int>) -> [Mark] {
    let cell = 1 / Double(Swift.max(rows, columns))
    let width = Double(columns) * cell
    let height = Double(rows) * cell
    var marks: [Mark] = []

    for index in 0..<(rows * columns) {
        if !shaded.contains(index) { continue }
        // Row 0 is the *top* row, read left to right then down like a page.
        // Maths-frame y grows upward and `fit` flips it on the way to the
        // screen, so the row meant to land at the top carries the largest y.
        let row = rows - 1 - index / columns
        let column = index % columns
        let x0 = Double(column) * cell
        let y0 = Double(row) * cell
        marks.append(closedPath(rectangleCorners(x0, y0, x0 + cell, y0 + cell), true))
    }

    marks.append(closedPath(rectangleCorners(0, 0, width, height), false))

    for column in 1..<Swift.max(1, columns) {
        let x = Double(column) * cell
        marks.append(openPath([Point(x, 0), Point(x, height)]))
    }
    for row in 1..<Swift.max(1, rows) {
        let y = Double(row) * cell
        marks.append(openPath([Point(0, y), Point(width, y)]))
    }

    return marks
}
