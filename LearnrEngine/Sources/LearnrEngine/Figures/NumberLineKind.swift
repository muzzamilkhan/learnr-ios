import Foundation

/// The `number-line` kind, ported from `src/lib/figures/number-line-kind.ts`: a
/// ruled line, its numbers, and an arrow pointing at a value.
///
/// A range the builder picks for itself always has a tick under the arrow, so
/// the child can read the answer off it. A range **pinned** by the author is
/// drawn as written, arrow between two ticks and all: estimating is a real
/// question to ask, and only the builder's own choice is the builder's to
/// answer for.

private let nlEpsilon = 1e-9

/// Comparing a value against a lattice it was computed onto — looser than
/// `nlEpsilon`, since the arithmetic that got here has already rounded.
private let latticeTolerance = 1e-6

/// The longest a tick's number may be, in characters.
private let maxLabelChars = Int((1 / charShare - labelDaylight) / 2)

/// The most labelled gaps a line may be cut into.
private let maxLabelGaps = Int((1 - charShare) / ((1 + labelDaylight) * charShare))

private let minLineSpan = 0.1

/// How close two of this line's ticks may be drawn, as a share of the drawn
/// span — the shared stroke-gap rule turned into this kind's own frame.
private let minTickGap = (minMarkGapPx / reportBoxPx) * (figureBox / drawnSpan)

/// How many parts a labelled step may be cut into by minor ticks.
private let minorParts = [2, 4, 5, 10]

/// The span widths a builder-chosen line is offered, against `at`'s magnitude.
private let spanBases: [Double] = [1, 2, 5, 10, 20]

private let tickBand = (0.05, 0.085)
private let minorTickRatio = 0.55
private let nlLabelGap = 0.03
private let arrowBand = (0.09, 0.15)
private let arrowGap = 0.012
private let arrowHeadHalf = 0.022
private let arrowStemHalf = 0.007
private let arrowHeadRatio = 0.45

private let fallbackAtValue: Double = 5

/// Where a range whose arithmetic has run out lands.
private let lastResortRange = (0.0, 10.0)

struct NumberLineBuilder: FigureKindBuilder {
    let kind = "number-line"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let at = numberValue(readField(spec["at"], scope)) ?? fallbackAtValue
        let askedFrom = numberValue(readField(spec["from"], scope))
        let askedTo = numberValue(readField(spec["to"], scope))
        let pinnedStep = numberValue(readField(spec["step"], scope))

        let minorsAllowed = minorsAllowedBy(spec["minorTicks"], scope)

        // **Five draws, always, whichever of these is pinned.** One `Rng` runs
        // through the figure into the question's own choice building, so a
        // figure whose appetite depended on what a template pinned would
        // reshuffle the distractors of the very question it illustrates. A pick
        // from a single candidate is still a pick.
        let picked = rng.pick(linesToDraw(at, askedFrom, askedTo, pinnedStep, minorsAllowed))
        let (from, to) = drawableRange(picked)
        let step = rng.pick(stepsToDraw(from, to, at, pinnedStep, minorsAllowed))
        let minorsJittered = rng.next() < 0.5
        let tickLength = jitter(&rng, tickBand.0, tickBand.1)
        let arrowLength = jitter(&rng, arrowBand.0, arrowBand.1)

        let span = to - from
        let gaps = Swift.max(tickCount(from, to, step), 1)
        let texts = tickTexts(from, step, gaps)
        let chars = widestLabel(texts)
        let lineSpan = lineSpanFor(chars)
        let overhang = frameOverhangFor(chars)

        // The small ticks are only free to come and go where the arrow is
        // already standing on a numbered one — otherwise they are the answer,
        // not decoration.
        let minorsOn = !minorsAllowed
            ? false
            : (onLattice(at, from, step) ? minorsJittered : true)
        let parts = minorsOn ? minorPartsFor(from, step, gaps, at, chars) : nil

        func along(_ value: Double) -> Double { ((value - from) / span) * lineSpan }
        var marks: [Mark] = [rule(Point(-overhang, 0), Point(lineSpan + overhang, 0))]

        for index in 0...gaps {
            marks.append(tickAt(along(from + Double(index) * step), tickLength))
        }

        if let parts {
            for index in 0...(gaps * parts) {
                // The ones a labelled tick already stands on are skipped: a
                // short stroke under a long one is a heavier line, not a
                // countable mark.
                if index % parts == 0 { continue }
                marks.append(tickAt(
                    along(from + (Double(index) * step) / Double(parts)),
                    tickLength * minorTickRatio
                ))
            }
        }

        for (index, text) in texts.enumerated() {
            marks.append(.label(
                at: Point(
                    along(from + Double(index) * step),
                    -(tickLength / 2 + nlLabelGap)
                ),
                text: text
            ))
        }

        // Clamped, not refused: an `at` outside the line is reported, and here
        // it only has to be drawable.
        let arrowX = clamp(along(at), 0, lineSpan)
        marks.append(arrowAt(arrowX, arrowLength))
        marks.append(.dot(at: Point(arrowX, 0)))

        return marks
    }
}

let numberLineBuilder = NumberLineBuilder()

/// A tick's number, without the tail a floating-point step would leave on it.
///
/// The rounding is skipped where it would overflow: multiplying to round to
/// three places turns an enormous but ordinary number into a tick reading
/// `Infinity`, a label that is no longer the number it came from.
private func formatTick(_ value: Double) -> String {
    let rounded = JSNumber.round(value * 1000) / 1000
    let out = rounded.isFinite ? rounded : value
    return JSNumber.toString(out == 0 ? 0 : out)
}

/// How many whole steps fit along the line — the number of labelled gaps.
private func tickCount(_ from: Double, _ to: Double, _ step: Double) -> Int {
    guard step > 0, step.isFinite else { return 0 }
    let gaps = ((to - from) / step + nlEpsilon).rounded(.down)
    guard gaps.isFinite else { return 0 }
    return Swift.max(Int(gaps), 0)
}

private func tickTexts(_ from: Double, _ step: Double, _ gaps: Int) -> [String] {
    (0...gaps).map { formatTick(from + Double($0) * step) }
}

private func widestLabel(_ texts: [String]) -> Double {
    texts.reduce(0.0) { Swift.max($0, Double($1.count)) }
}

/// Half the widest label's ink, which is exactly how far the line runs past its
/// end ticks — the identity that makes clipping impossible rather than merely
/// unlikely.
private func frameOverhangFor(_ chars: Double) -> Double {
    Swift.max((chars * charShare) / 2, arrowHeadHalf)
}

/// What is left for the line itself once both overhangs are paid for.
private func lineSpanFor(_ chars: Double) -> Double {
    Swift.max(1 - 2 * frameOverhangFor(chars), minLineSpan)
}

/// Whether every number this step draws fits, and clears the one beside it.
///
/// **Asked of every adjacent pair rather than of the widest label**, because
/// the two neighbours that crowd each other are not always the two longest
/// strings: `0, 5, 10, 15, 20` is roomiest at its left end and tightest in the
/// middle.
private func labelsFit(_ texts: [String]) -> Bool {
    let gaps = texts.count - 1
    if gaps < 1 { return false }
    let chars = widestLabel(texts)
    if chars > Double(maxLabelChars) { return false }

    let pitch = lineSpanFor(chars) / Double(gaps)
    var index = 0
    while index + 1 < texts.count {
        let needed = ((Double(texts[index].count) + Double(texts[index + 1].count)) / 2
            + labelDaylight) * charShare
        if pitch + nlEpsilon < needed { return false }
        index += 1
    }
    return true
}

/// Whether the small ticks may be drawn at all.
///
/// Absent means allowed, so an omitted field asks for the jitter rather than
/// turning them off.
private func minorsAllowedBy(_ expr: Expr?, _ scope: Scope) -> Bool {
    let asked = readField(expr, scope)
    return asked == nil || truthy(asked)
}

/// Whether a value lands on a lattice of this spacing starting at `from`.
private func onLattice(_ value: Double, _ from: Double, _ spacing: Double) -> Bool {
    guard spacing > 0, spacing.isFinite else { return false }
    let steps = (value - from) / spacing
    guard steps.isFinite else { return false }
    return Swift.abs(steps - JSNumber.round(steps)) < latticeTolerance
}

/// How many parts one labelled step is cut into, or nothing if there is no room
/// for minor ticks at all.
///
/// The fewest that puts `at` on a tick, so the child counts as few small marks
/// as the number allows; failing that the fewest that fit. Deterministic on
/// purpose — it is a consequence of the step and the value, not a lever of its
/// own.
private func minorPartsFor(
    _ from: Double, _ step: Double, _ gaps: Int, _ at: Double, _ chars: Double
) -> Int? {
    let span = lineSpanFor(chars)
    let legible = minorParts.filter {
        span / Double(gaps * $0) >= minTickGap - nlEpsilon
    }
    let expressing = legible.filter { onLattice(at, from, step / Double($0)) }
    return expressing.first ?? legible.first
}

/// Whether the arrow would have something under it to stand on.
private func standsOnATick(
    _ from: Double, _ step: Double, _ gaps: Int, _ at: Double,
    _ chars: Double, _ minorsAllowed: Bool
) -> Bool {
    if onLattice(at, from, step) { return true }
    if !minorsAllowed { return false }
    guard let parts = minorPartsFor(from, step, gaps, at, chars) else { return false }
    return onLattice(at, from, step / Double(parts))
}

/// The steps this line could be labelled in, biggest first.
///
/// A pinned step is kept unless it asks for a line that cannot be labelled.
/// Left open, the candidates are the span cut into 1, 2, … equal parts, so a
/// builder-chosen step divides the range evenly by construction and the last
/// tick is always the end of the line.
private func stepCandidates(_ from: Double, _ to: Double, _ pinned: Double?) -> [Double] {
    let span = to - from

    if let pinned, pinned > 0 {
        let gaps = tickCount(from, to, pinned)
        if gaps >= 1, gaps <= maxLabelGaps, labelsFit(tickTexts(from, pinned, gaps)) {
            return [pinned]
        }
    }

    var steps: [Double] = []
    for gaps in 1...Swift.max(1, maxLabelGaps) {
        let step = span / Double(gaps)
        if labelsFit(tickTexts(from, step, gaps)) { steps.append(step) }
    }
    // Past what any step can label — a line to a million. Drawn with one gap so
    // there is still a drawing.
    return !steps.isEmpty ? steps : [span]
}

/// The steps the builder actually picks between, arrow readability preferred.
private func stepsToDraw(
    _ from: Double, _ to: Double, _ at: Double,
    _ pinned: Double?, _ minorsAllowed: Bool
) -> [Double] {
    let pool = stepCandidates(from, to, pinned)
    let expressing = pool.filter { step in
        let gaps = tickCount(from, to, step)
        if gaps < 1 { return false }
        let chars = widestLabel(tickTexts(from, step, gaps))
        return standsOnATick(from, step, gaps, at, chars, minorsAllowed)
    }
    return !expressing.isEmpty ? expressing : pool
}

/// Any line at all containing `at` — where a range nobody could read lands.
private func fallbackRange(
    _ at: Double, _ from: Double?, _ to: Double?
) -> (Double, Double) {
    let low = (from != nil && from! <= at) ? from! : at - 1
    let high = (to != nil && to! > low && to! >= at)
        ? to!
        : low + Swift.max(2, Swift.abs(at - low) * 2)
    return (low, high)
}

/// The ranges a builder-chosen line could take: nice spans around `at`'s own
/// magnitude, each offered twice — started at the multiple of itself at or
/// below `at`, and again half a span along.
///
/// That is what puts a 7 on 0–10 and on 5–15 — the same number, two different
/// pictures — which is the whole of this kind's answer to the anchoring rule.
private func rangeCandidates(
    _ at: Double, _ from: Double?, _ to: Double?
) -> [(Double, Double)] {
    if let from, let to { return to > from ? [(from, to)] : [] }

    let magnitude = Foundation.pow(
        10.0, (Foundation.log10(Swift.max(Swift.abs(at), 1))).rounded(.down)
    )
    var seen: Set<String> = []
    var ranges: [(Double, Double)] = []

    func offer(_ low: Double, _ span: Double) {
        let high = low + span
        // A span that has overflowed to infinity — which the biggest bases do
        // for an `at` near the top of what a double holds — is not a line.
        guard high > low, high.isFinite,
              at >= low - nlEpsilon, at <= high + nlEpsilon else { return }
        let key = "\(JSNumber.toString(low)):\(JSNumber.toString(high))"
        if seen.contains(key) { return }
        seen.insert(key)
        ranges.append((low, high))
    }

    for base in spanBases {
        let span = base * magnitude
        let low: Double
        if let from {
            low = from
        } else if let to {
            low = to - span
        } else {
            low = (at / span).rounded(.down) * span
        }
        offer(low, span)

        // The second framing of the same width. Only where the builder is
        // choosing both ends: an author who gave one has said where it starts.
        if from == nil && to == nil, let shifted = shiftedStart(at, low, span) {
            offer(shifted, span)
        }
    }

    return ranges
}

/// The same span started half a span along, or nothing where that would draw
/// uglier numbers than the span grid already does.
///
/// **Why there is a second offset at all.** One start per span means a value
/// the grid can only frame one way gets exactly one line, on every seed — 36 of
/// the integers 0–100, measured. Their pictures still differed, because the
/// step and the two proportional jitters still moved, so a whole-figure
/// anchoring check passed them. That is worse than a check failing: a child
/// answering 11 saw the same line every time and could learn "the tick after
/// the 10" instead of reading the number.
///
/// The roundness test is asked of the **text that gets drawn**: an endpoint
/// that prints longer than the one the span grid would have used has grown a
/// decimal, and the candidate is dropped. No second candidate beats an ugly one.
private func shiftedStart(_ at: Double, _ low: Double, _ span: Double) -> Double? {
    let half = span / 2
    // Whichever of the two neighbouring half-grid starts still contains `at`.
    let shifted = at <= low + half + nlEpsilon ? low - half : low + half

    // These three guards are transcribed from the source and no vector can
    // prove any of them: removing all three changes no drawing. `offer` drops a
    // candidate that does not contain `at`, and `labelsFit` drops one whose
    // numbers will not fit, so every range these refuse is refused again
    // downstream. Measured over `at` in 0...60 on 25 seeds each - no endpoint
    // ever comes out negative or carrying a decimal either way. They stay
    // because this is a port, and because the *reason* differs: these say the
    // candidate is ugly, where the checks below say it is unusable, and a
    // future span base could separate the two.
    if at >= 0 && shifted < 0 { return nil }
    if !shifted.isFinite { return nil }
    // Longer text is a decimal the span grid did not have: 10 → 5 is fine,
    // 5 → 2.5 is not, and neither end may grow.
    if formatTick(shifted).count > formatTick(low).count { return nil }
    if formatTick(shifted + span).count > formatTick(low + span).count { return nil }

    return shifted
}

/// The lines the builder actually picks between.
///
/// Where it is choosing, it keeps only the ranges whose ticks can express `at`.
/// Falling back to the whole list is `build` keeping its side of the bargain —
/// it draws *something* mid-session and never refuses.
private func linesToDraw(
    _ at: Double, _ from: Double?, _ to: Double?,
    _ pinnedStep: Double?, _ minorsAllowed: Bool
) -> [(Double, Double)] {
    let ranges = rangeCandidates(at, from, to)
    let standing = ranges.filter { lineStands($0, at, pinnedStep, minorsAllowed) }
    let pool = !standing.isEmpty ? standing : ranges
    return !pool.isEmpty ? pool : [fallbackRange(at, from, to)]
}

/// Whether any step this line could be labelled in leaves a tick under the
/// arrow.
private func lineStands(
    _ range: (Double, Double), _ at: Double,
    _ pinnedStep: Double?, _ minorsAllowed: Bool
) -> Bool {
    let (low, high) = range
    return stepsToDraw(low, high, at, pinnedStep, minorsAllowed).contains { step in
        let gaps = tickCount(low, high, step)
        if gaps < 1 { return false }
        let chars = widestLabel(tickTexts(low, step, gaps))
        return standsOnATick(low, step, gaps, at, chars, minorsAllowed)
    }
}

/// A range with a positive, finite width, or the last resort.
private func drawableRange(_ range: (Double, Double)) -> (Double, Double) {
    let span = range.1 - range.0
    return (range.0.isFinite && span > 0 && span.isFinite) ? range : lastResortRange
}

private func rule(_ from: Point, _ to: Point) -> Mark {
    .path(points: [from, to], closed: false, fill: false, dashed: false)
}

/// A tick, straddling the line so it reads as a mark *on* it rather than beside
/// it.
private func tickAt(_ x: Double, _ length: Double) -> Mark {
    rule(Point(x, -length / 2), Point(x, length / 2))
}

/// The arrow: one closed outline, tip down on the line, shaft up out of it.
private func arrowAt(_ x: Double, _ length: Double) -> Mark {
    let head = length * arrowHeadRatio
    let tip = arrowGap
    return .path(
        points: [
            Point(x, tip),
            Point(x - arrowHeadHalf, tip + head),
            Point(x - arrowStemHalf, tip + head),
            Point(x - arrowStemHalf, tip + length),
            Point(x + arrowStemHalf, tip + length),
            Point(x + arrowStemHalf, tip + head),
            Point(x + arrowHeadHalf, tip + head),
        ],
        closed: true, fill: true, dashed: false
    )
}
