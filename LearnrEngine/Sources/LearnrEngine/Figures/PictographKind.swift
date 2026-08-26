import Foundation

/// The `pictograph` kind, ported from `src/lib/figures/pictograph-kind.ts`:
/// rows of a repeated icon, a key saying what one icon stands for, and
/// optionally a name against each row.
///
/// The count *is* the answer, so a row has to stay countable: the icon pitch is
/// measured against report-scale type, because a row that reads as "a wall" in
/// a 64px thumbnail is the one thing a picture graph must not be.

private let epsilon = 1e-9

private let labelGap = 0.03
private let keyTextGap = 0.03
private let keyRowRatio = 1.3
private let iconSlotFill = 0.78

/// How much of its row's pitch an icon fills. The jitter that survives a fully
/// pinned graph.
private let sizeBand = (0.45, 0.8)

/// The keys a graph is offered when the template does not pin one.
private let keyLadder: [Double] = [1, 2, 5, 10]

/// Where a `counts` nobody could read lands.
private let fallbackCounts: [Double] = [3, 5, 2]

/// A hard stop on how much is drawn at all, well past what validation reports.
///
/// A stored figure is refused over `maxMarks` when read back, so a count of ten
/// thousand at a key of one would draw a graph that could never be shown again
/// in a parent's report. This is a silent truncation, and it is safe only
/// because it is unreachable by anything that validates.
private let maxDrawnRows = 10
private let maxDrawnIcons = 12

/// The pitch between two rows, given how many there are and how tall an icon is
/// drawn.
///
/// Solved so the whole drawing is at most 1 tall: the vertical rule reaches
/// half a pitch above the top row, and the key icon half its own height below
/// the key line, which sits `keyRowRatio` pitches under the bottom row.
private func rowPitch(_ rows: Int, _ fill: Double) -> Double {
    1 / (Double(rows) - 0.5 + keyRowRatio + fill / 2)
}

/// The tallest an icon is ever drawn at this many rows.
private func maxIconHeight(_ rows: Int) -> Double {
    rowPitch(rows, sizeBand.1) * sizeBand.1
}

/// A row is never squeezed past this, however long the labels: one icon at the
/// pitch two icons need to be told apart.
private let minRowSpan = pitchShare

struct PictographBuilder: FigureKindBuilder {
    let kind = "pictograph"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let read = stringValue(readField(spec["counts"], scope))
        let parsed = read.flatMap(parseStrictNumbers)
        let counts = (parsed ?? fallbackCounts)
            .prefix(maxDrawnRows)
            // A row has no room to the left of its own axis, so a negative
            // count is drawn as nothing.
            .map { Swift.max($0, 0) }

        let readLabels = stringValue(readField(spec["labels"], scope))
        let names = readLabels.map(commaList) ?? []
        let labelChars = counts.indices.reduce(0.0) { longest, index in
            Swift.max(longest, Double(index < names.count ? names[index].count : 0))
        }

        let halves = truthy(readField(spec["halves"], scope))
        // Exactly one draw whichever path this takes, pinned or not: a figure
        // that spends a variable number of draws reshuffles the distractors of
        // the very question it illustrates.
        let key = rng.pick(keyCandidates(
            Array(counts), halves, iconBudget(labelChars),
            numberValue(readField(spec["key"], scope))
        ))

        let drawn = counts.map {
            Swift.min(iconsFor($0, key, halves), Double(maxDrawnIcons))
        }
        let rows = counts.count
        let slots = slotsFor(Array(counts), key, halves)
        let keyText = formatKey(key)
        let layout = layoutFor(rows, labelChars, slots, Double(keyText.count))

        let shape = rng.pick(iconShapes)
        let fill = jitter(&rng, sizeBand.0, sizeBand.1)
        let pitch = rowPitch(rows, fill)
        let iconSize = Swift.min(pitch * fill, layout.iconPitch * iconSlotFill)
        let half = leftHalf(shape)

        let keyY = -keyRowRatio * pitch

        // The two rules first, because they are what the fit measures the
        // drawing by: every label's ink ends inside them, so nothing here can
        // be clipped.
        var marks: [Mark] = [
            rule(Point(0, -pitch / 2), Point(0, Double(rows - 1) * pitch + pitch / 2)),
            rule(Point(-layout.gutter, -pitch / 2), Point(layout.right, -pitch / 2)),
        ]

        for index in counts.indices {
            let y = Double(rows - 1 - index) * pitch
            let name = index < names.count ? names[index] : ""
            if !name.isEmpty {
                // Right-aligned against the axis, so the anchor moves left as
                // the name gets longer and the ink always ends inside the left
                // bound.
                marks.append(.label(
                    at: Point(-(labelGap + (Double(name.count) * charShare) / 2), y),
                    text: name
                ))
            }
            let whole = Int((drawn[index] + epsilon).rounded(.down))
            for icon in 0..<Swift.max(0, whole) {
                marks.append(iconAt(
                    (Double(icon) + 0.5) * layout.iconPitch, y, iconSize, shape
                ))
            }
            if drawn[index] - Double(whole) > epsilon {
                marks.append(iconAt(
                    (Double(whole) + 0.5) * layout.iconPitch, y, iconSize, half
                ))
            }
        }

        marks.append(iconAt(-layout.gutter + layout.keySlot / 2, keyY, iconSize, shape))
        marks.append(.label(
            at: Point(
                -layout.gutter + layout.keySlot + keyTextGap
                    + (Double(keyText.count) * charShare) / 2,
                keyY
            ),
            text: keyText
        ))

        return marks
    }
}

let pictographBuilder = PictographBuilder()

/// The icons a row is drawn with.
///
/// Not `count / key`: a picture graph draws whole icons, or halves where
/// `halves` allows them, so what reaches the page is rounded **up** to the
/// nearest one it can draw. Up rather than to nearest, so a count that is not
/// zero is never drawn as nothing.
private func iconsFor(_ count: Double, _ key: Double, _ halves: Bool) -> Double {
    let unit: Double = halves ? 2 : 1
    if count <= 0 { return 0 }
    return (((count / key) * unit - epsilon).rounded(.up)) / unit
}

/// Whether the key can say this count exactly, or only round it.
private func isExact(_ count: Double, _ key: Double, _ halves: Bool) -> Bool {
    let unit: Double = halves ? 2 : 1
    let steps = (count / key) * unit
    return Swift.abs(steps - JSNumber.round(steps)) < epsilon
}

/// The slots the widest row takes — a half icon still stands in a whole one.
private func slotsFor(_ counts: [Double], _ key: Double, _ halves: Bool) -> Int {
    let widest = counts.reduce(0.0) { Swift.max($0, iconsFor($1, key, halves)) }
    return Swift.max(1, Swift.min(Int(widest.rounded(.up)), maxDrawnIcons))
}

/// The gutter the row labels take, ink included — it is exactly the left bound.
private func gutterFor(_ labelChars: Double) -> Double {
    labelChars > 0 ? labelGap + labelChars * charShare : 0
}

/// The most icons a row of *this* graph can carry and still be countable at
/// report scale.
///
/// The room an icon has is settled by the data — the counts and the key the
/// template asked for — against a gutter the template's own labels decide, so
/// it is computed from the layout this graph will actually get.
private func iconBudget(_ labelChars: Double) -> Int {
    let available = Swift.max(1 - gutterFor(labelChars), minRowSpan)
    return Swift.max(1, Int((available / pitchShare).rounded(.down)))
}

private struct PictographLayout {
    var gutter: Double
    var available: Double
    var iconPitch: Double
    var keySlot: Double
    var right: Double
}

/// The half of the layout that depends on nothing random.
///
/// The key legend is left-aligned with the **drawing's** left edge rather than
/// with the icons, so its width is measured against the whole frame instead of
/// against what the gutter left over. A key that fits with no labels therefore
/// fits with them too.
private func layoutFor(
    _ rows: Int, _ labelChars: Double, _ slots: Int, _ keyChars: Double
) -> PictographLayout {
    let gutter = gutterFor(labelChars)
    let available = Swift.max(1 - gutter, minRowSpan)
    let iconPitch = available / Double(Swift.max(slots, 1))
    let keySlot = Swift.min(maxIconHeight(rows), iconPitch * iconSlotFill)
    let keyRight = -gutter + keySlot + keyTextGap + keyChars * charShare
    return PictographLayout(
        gutter: gutter, available: available, iconPitch: iconPitch,
        keySlot: keySlot, right: Swift.max(available, keyRight)
    )
}

/// The keys the graph could be drawn with.
///
/// A pinned key is always kept — it is the author's statement about what the
/// picture means. Left open it jitters over the ladder, preferring keys that
/// say every count exactly: a key that has to round is a key that draws two
/// different rows the same, which is the failure this kind exists to avoid.
private func keyCandidates(
    _ counts: [Double], _ halves: Bool, _ budget: Int, _ pinned: Double?
) -> [Double] {
    if let pinned, pinned > 0 { return [pinned] }

    let fits = keyLadder.filter { slotsFor(counts, $0, halves) <= budget }
    let exact = fits.filter { key in counts.allSatisfy { isExact($0, key, halves) } }
    let pool = !exact.isEmpty ? exact : fits
    if !pool.isEmpty { return pool }

    // Past the ladder's reach — a key of the data's own, so the row still fits.
    let most = counts.reduce(0.0) { Swift.max($0, $1) }
    return [Swift.max(epsilon, (most / Double(Swift.max(budget, 1))).rounded(.up))]
}

/// The key's own text, without the tail a floating-point key would leave on it.
private func formatKey(_ key: Double) -> String {
    // `String(...)` in the JavaScript, so `= 10` and not `= 10.0`.
    let rounded = JSNumber.round(key * 1000) / 1000
    return "= \(JSNumber.toString(rounded == 0 ? 0 : rounded))"
}

/// A shape stretched to fill `[-0.5, 0.5]` in both directions.
private func normalise(_ points: [Point]) -> [Point] {
    let xs = points.map(\.x)
    let ys = points.map(\.y)
    let width = xs.max()! - xs.min()!
    let height = ys.max()! - ys.min()!
    let midX = (xs.max()! + xs.min()!) / 2
    let midY = (ys.max()! + ys.min()!) / 2
    return points.map { Point(($0.x - midX) / width, ($0.y - midY) / height) }
}

/// The icons, each normalised to fill the unit square exactly.
///
/// **Filling it is what makes the shape a free jitter**: every shape has the
/// same extent, so picking between them changes the picture without moving a
/// single bound.
private let iconShapes: [[Point]] = [
    normalise([Point(-1, -1), Point(1, -1), Point(1, 1), Point(-1, 1)]),
    normalise([Point(0, 1), Point(1, 0), Point(0, -1), Point(-1, 0)]),
    normalise([Point(0, 1), Point(1, -1), Point(-1, -1)]),
    normalise([Point(0, 1), Point(1, 0.2), Point(1, -1), Point(-1, -1), Point(-1, 0.2)]),
    normalise((0..<5).map { index in
        let angle = Double.pi / 2 + (Double(index) * 2 * Double.pi) / 5
        return Point(Foundation.cos(angle), Foundation.sin(angle))
    }),
]

/// The left half of an icon, cut down its middle rather than squashed to half
/// the width: a narrow pentagon is a different icon, and a pentagon with its
/// right side missing is half of one. Convex shapes only, which is all of them.
private func leftHalf(_ points: [Point]) -> [Point] {
    var out: [Point] = []
    for index in points.indices {
        let from = points[index]
        let to = points[(index + 1) % points.count]
        let fromIn = from.x <= 0
        let toIn = to.x <= 0
        if fromIn { out.append(from) }
        if fromIn != toIn {
            let along = -from.x / (to.x - from.x)
            out.append(Point(0, from.y + along * (to.y - from.y)))
        }
    }
    return out
}

/// The comma-joined list, or nothing at all.
///
/// Strict: `Number('')` is 0 in JavaScript, so a list with a hole in it would
/// read as a row of no icons rather than as the typo it is.
func parseStrictNumbers(_ text: String) -> [Double]? {
    let parts = commaList(text)
    if parts.contains(where: { $0.isEmpty }) { return nil }
    let values = parts.map { Double($0) }
    guard values.allSatisfy({ $0?.isFinite == true }) else { return nil }
    return values.map { $0! }
}

private func iconAt(_ cx: Double, _ cy: Double, _ size: Double, _ points: [Point]) -> Mark {
    .path(
        points: points.map { Point(cx + $0.x * size, cy + $0.y * size) },
        closed: true, fill: true, dashed: false
    )
}

private func rule(_ from: Point, _ to: Point) -> Mark {
    .path(points: [from, to], closed: false, fill: false, dashed: false)
}
