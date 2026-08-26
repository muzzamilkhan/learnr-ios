import Foundation

/// The `bar` kind, ported from `src/lib/figures/bar-kind.ts`: a value axis, a
/// category axis, and one mark per value — a column, a dot or a point on a line.
///
/// The label geometry here is solved *exactly*, and exact leaves nothing over:
/// at the tightest legal shape the binding label's ink lands a hundredth of a
/// unit inside the box, and the whole clearance is one rounding term. That is
/// why `plotShape` reads the way it does.

private let barStyles = ["column", "dot", "line"]

/// Which styles an omitted `style` jitters between. `line` is left out: a line
/// graph asserts the categories are ordered, which a bar graph's are not.
private let jitteredStyles = ["column", "dot"]

private let barEpsilon = 1e-9

private let topOverhang = 0.06
private let rightOverhang = 0.05
private let stepGap = 0.035
private let categoryBand = 0.12
private let tick = 0.02

private let minPlotWidth = 0.2

private let plotHeightConstant = 1 - topOverhang - categoryBand

/// The most steps a value axis can be cut into and still have its numbers read
/// as separate lines at report scale.
private let maxSteps = Int((plotHeightConstant / pitchShare).rounded(.down))
private let minSteps = 2

private let scaleLadder: [Double] = [1, 2, 5, 10]

/// A hard stop on how much is drawn at all, past what validation reports.
private let maxDrawnValues = 12

/// How much of the available width the plot takes, and how much of its slot a
/// bar takes. The two jitters that survive a fully pinned graph.
private let widthBand = (0.86, 1.0)
private let barBand = (0.5, 0.72)

struct BarBuilder: FigureKindBuilder {
    let kind = "bar"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let read = stringValue(readField(spec["values"], scope))
        let parsed = read.flatMap(parseStrictNumbers)
        let values = (parsed ?? fallbackValues(&rng))
            .prefix(maxDrawnValues)
            // A bar graph has no room below its own axis, so a negative value
            // is drawn as nothing.
            .map { Swift.max($0, 0) }

        let readLabels = stringValue(readField(spec["labels"], scope))
        let names = readLabels.map(commaList) ?? []
        let labelled = names.contains { !$0.isEmpty }

        let readStyle = stringValue(readField(spec["style"], scope))
        let style = (readStyle.map(barStyles.contains) == true)
            ? readStyle! : rng.pick(jitteredStyles)

        let maxValue = values.reduce(0.0) { Swift.max($0, $1) }
        let scale = scaleFor(
            Array(values), maxValue,
            numberValue(readField(spec["scale"], scope)), &rng
        )
        let steps = stepsFor(maxValue, scale)

        // The frame: height exactly 1, width never more than that, so the fit's
        // scale is `drawnSpan` and every share above is a real measurement.
        let plotHeight = 1 - topOverhang - (labelled ? categoryBand : 0)
        let stepHeight = plotHeight / Double(steps)

        let stepTexts = (0...steps).map { formatStep(Double($0) * scale) }
        // Measured at its true width, never clamped: a label budgeted narrower
        // than it is drawn is the one thing worse than a wide one, since the
        // geometry then leaves room that does not exist.
        let stepChars = stepTexts.reduce(0.0) { Swift.max($0, Double($1.count)) }
        let categoryChars = labelled
            ? values.indices.reduce(0.0) { longest, index in
                Swift.max(longest, Double(index < names.count ? names[index].count : 0))
            }
            : 0

        let plotWidth = plotShape(stepChars, categoryChars).width
            * jitter(&rng, widthBand.0, widthBand.1)

        let slot = plotWidth / Double(Swift.max(values.count, 1))
        let barWidth = slot * jitter(&rng, barBand.0, barBand.1)
        func at(_ value: Double) -> Double { (value / scale) * stepHeight }
        func centre(_ index: Int) -> Double { (Double(index) + 0.5) * slot }

        var marks: [Mark] = [
            line(Point(0, 0), Point(0, plotHeight + topOverhang)),
            line(Point(0, 0), Point(plotWidth + rightOverhang, 0)),
        ]

        // The ticks, then the numbers beside them: a label with nothing on the
        // axis to point at is a number floating next to a graph.
        for step in 1...Swift.max(1, steps) where steps >= 1 {
            marks.append(line(
                Point(-tick, Double(step) * stepHeight),
                Point(0, Double(step) * stepHeight)
            ))
        }
        for (step, text) in stepTexts.enumerated() {
            // Right-aligned against the axis, which is where a value axis reads
            // from — so the anchor moves left as the number gets longer.
            let width = Double(text.count) * charShare
            marks.append(.label(
                at: Point(-(stepGap + width / 2), Double(step) * stepHeight),
                text: text
            ))
        }

        if style == "line" {
            marks.append(.path(
                points: values.indices.map { Point(centre($0), at(values[$0])) },
                closed: false, fill: false, dashed: false
            ))
        } else {
            for index in values.indices {
                if style == "dot" {
                    marks.append(.dot(at: Point(centre(index), at(values[index]))))
                    continue
                }
                let left = centre(index) - barWidth / 2
                let right = centre(index) + barWidth / 2
                marks.append(.path(
                    points: [
                        Point(left, 0), Point(left, at(values[index])),
                        Point(right, at(values[index])), Point(right, 0),
                    ],
                    closed: true, fill: true, dashed: false
                ))
            }
        }

        if labelled {
            for index in values.indices {
                guard index < names.count, !names[index].isEmpty else { continue }
                marks.append(.label(
                    at: Point(centre(index), -categoryBand), text: names[index]
                ))
            }
        }

        return marks
    }
}

let barBuilder = BarBuilder()

/// Where a `values` nobody could read lands — still a graph, just not the asked
/// one. Two draws plus one per value, exactly as the JavaScript spends them.
private func fallbackValues(_ rng: inout Rng) -> [Double] {
    let count = rng.int(3, 4)
    return (0..<count).map { _ in Double(rng.int(1, maxSteps)) }
}

/// How many steps an axis is cut into at this scale — at least one, always.
private func stepsFor(_ maxValue: Double, _ scale: Double) -> Int {
    Swift.max(1, Int((maxValue / scale - barEpsilon).rounded(.up)))
}

/// The step the value axis is drawn in.
///
/// A pinned scale is kept unless it asks for an axis that cannot be labelled,
/// which is the one case where drawing what was asked for is worse than drawing
/// something readable. Left open it jitters, preferring the scales every value
/// is a multiple of: a column that stops between two ticks is a column nobody
/// can read a number off.
private func scaleCandidates(
    _ values: [Double], _ maxValue: Double, _ pinned: Double?
) -> [Double] {
    if let pinned, pinned > 0, stepsFor(maxValue, pinned) <= maxSteps { return [pinned] }

    let fits = scaleLadder.filter { step in
        let steps = stepsFor(maxValue, step)
        return steps >= minSteps && steps <= maxSteps
    }
    let exact = fits.filter { step in
        values.allSatisfy {
            Swift.abs($0 / step - JSNumber.round($0 / step)) < barEpsilon
        }
    }
    let pool = !exact.isEmpty ? exact : fits
    if !pool.isEmpty { return pool }

    // Past the ladder's reach — a step of the data's own, so the axis fits.
    return [Swift.max(barEpsilon, (maxValue / Double(maxSteps)).rounded(.up))]
}

/// **Exactly one draw whichever path this takes.**
///
/// A pick from one candidate is still a pick, and that is the point. One `Rng`
/// runs from the binding through the figure into the question's own choice
/// building, so a figure that spent a variable number of draws would shift
/// everything drawn after it: adding a `scale` pin to a template would silently
/// reshuffle that template's own distractors, in the very question the figure
/// illustrates.
private func scaleFor(
    _ values: [Double], _ maxValue: Double, _ pinned: Double?, _ rng: inout Rng
) -> Double {
    rng.pick(scaleCandidates(values, maxValue, pinned))
}

/// How wide the plot is drawn, given what the labels around it need.
///
/// Solved so the ink of the widest label lands inside the box at report scale,
/// with a single rounding step to spare — `fit` rounds every coordinate, and
/// this bound is otherwise tight enough that the binding label's ink lands on
/// the box edge exactly.
private func plotShape(
    _ stepChars: Double, _ categoryChars: Double
) -> (leftBand: Double, width: Double) {
    let leftBand = stepGap + stepChars * charShare
    let available = Swift.max(1 - leftBand - rightOverhang, minPlotWidth)

    let stepInk = reportLabelWidth(stepChars) / 2
    let categoryInk = Swift.max(
        reportLabelWidth(categoryChars) / 2 - rightOverhang * drawnSpan, 0
    )
    let roomForInk =
        (figureBox / 2 - Swift.max(stepInk, categoryInk)
            - Foundation.pow(10.0, -Double(figurePrecision)))
        / (drawnSpan / 2)
    let outside = rightOverhang + leftBand - (stepChars * charShare) / 2
    let widest = clamp((roomForInk - outside) / available, minPlotWidth, 1)

    return (leftBand: leftBand, width: available * widest)
}

/// A step's label, without the tail a floating-point step would leave on it.
private func formatStep(_ value: Double) -> String {
    let rounded = JSNumber.round(value * 1000) / 1000
    return JSNumber.toString(rounded == 0 ? 0 : rounded)
}

private func line(_ from: Point, _ to: Point) -> Mark {
    .path(points: [from, to], closed: false, fill: false, dashed: false)
}
