import Foundation

/// The `timeline` kind, ported from `src/lib/figures/timeline-kind.ts`: a rule
/// across the page with its two ends labelled with their years, unlabelled
/// ticks between them carrying the scale, and each event a dot on the rule with
/// a letter above it.
///
/// It is a data display rather than a number line, which is why it is a kind of
/// its own: a number line is a scale with one value on it, and a timeline
/// carries labelled events at positions, so the questions it answers are "how
/// many years between A and B?", "which came first?" and "what year was C?".
///
/// **Two labelled years, not five.** `charShare` is 0.105 of the line per
/// character at report scale, so a four-digit year costs 0.42 and the two ends
/// alone take 84% of the width. A third never fits, and a rule that labelled a
/// middle rung only when the years were short enough would make a timeline's
/// readability depend on which century it was about.
///
/// **The rule is drawn from 0 to 1 whatever years it stands for, and the rungs
/// are inset by half the widest label's ink.** So the rule's extent and the
/// outermost label's ink edge are the same quantity, and clipping is impossible
/// by construction rather than by a solved inequality.
///
/// **Letters are authored or assigned by index, never by position.** A kind
/// that lettered left to right would answer "which came first?" off the
/// alphabet.
///
/// Only the builder's half is ported, as with every other kind: `issues` is the
/// validator's, it runs before content ships, and nothing on a child's device
/// calls it.

/// Comparing years and lattice positions that came out of floating-point
/// arithmetic.
private let tlEpsilon = 1e-9

/// How far apart two ticks have to be in this kind's own frame units to read as
/// two marks rather than one thick one. `number-line`'s conversion, written
/// again rather than shared because what a pixel of daylight costs *a line of
/// this width* is this kind's arithmetic.
private let minTimelineTickGap = (minMarkGapPx / reportBoxPx) * (figureBox / drawnSpan)

/// The most divisions a line can be cut into and still be counted along in a
/// 64px report row — derived from the gap above rather than chosen.
private let maxIntervals = Int(1 / minTimelineTickGap)

/// Fewer than two divisions is a line with nothing between its ends.
private let minIntervals = 2

/// The divisions a line is cut into when none is pinned — round years, coarsest
/// first.
private let stepLadder: [Double] = [1000, 500, 250, 200, 100, 50, 25, 20, 10, 5, 2, 1]

/// How far past the outermost events the line runs, in divisions. It never runs
/// to zero, so an end label is never sitting on an event: a timeline whose first
/// dot is under the `1900` would answer "what year was A?" with its own axis.
private let overshoot: [Double] = [1, 2, 3]

/// A minor tick's length as a share of the frame, and the ratio the two labelled
/// end rungs are drawn longer at.
private let timelineTickBand = (0.06, 0.11)
private let majorRatio = 1.8

/// How far above the rule an event's letter sits.
private let eventGapBand = (0.1, 0.17)

/// From the foot of an end rung to its year, clear of half a line of the year's
/// own ink.
private let yearGap = inkShare / 2 + 0.01

/// Where a `years` nobody could read lands — still a timeline, just not the
/// asked one.
private let fallbackYears: [Double] = [1900, 1940, 1960]

private let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")

/// A hard stop on how much is drawn at all, well past what the validator
/// reports. `parseFigure` refuses a figure over `maxMarks` (200) when it is read
/// back out of an `Attempt`, so a line pinned `from: 0, to: 2000, step: 1` would
/// otherwise draw two thousand ticks and could never be shown again in a
/// parent's report.
private let maxDrawnTicks = maxIntervals * 2
private let maxDrawnEvents = 20

/// One end of the line, and the pair of them is what the frame's inset is
/// measured from.
private struct TimelineLine {
    let from: Double
    let to: Double
    let step: Double
}

/// The year as it is **drawn**, which is the string the inset is measured
/// against. A year is an integer in every timeline anyone teaches, but `from`
/// and `to` are expressions, so the tail a float would leave is rounded off here
/// rather than being allowed to print twenty characters of it.
///
/// `JSNumber.toString` and `JSNumber.round` rather than Swift's own: `String(2.0)`
/// is `"2.0"` where JavaScript's is `"2"`, and this string is drawn on the
/// figure a child reads.
private func formatYear(_ year: Double) -> String {
    JSNumber.toString(JSNumber.round(year * 1000) / 1000 + 0)
}

/// Whether a year sits on a tick of this line — the test that makes it readable.
private func onLattice(_ year: Double, _ from: Double, _ step: Double) -> Bool {
    guard step > 0 else { return false }
    let steps = (year - from) / step
    return abs(steps - JSNumber.round(steps)) < tlEpsilon
}

/// Half the widest label's ink, which is exactly how far inside the rule's own
/// ends the outermost rung and the outermost event have to sit. Measured against
/// both label families at once: the end years are usually the wider, and a
/// two-character event letter at the very end of the line is what makes that
/// *usually* rather than *always*.
private func insetFor(_ line: TimelineLine, _ eventChars: Int) -> Double {
    let yearChars = max(formatYear(line.from).count, formatYear(line.to).count)
    return (Double(max(yearChars, eventChars)) * charShare) / 2
}

/// Where a year lands across the frame, between the two rungs the inset leaves
/// room for.
private func positionFor(_ year: Double, _ line: TimelineLine, _ inset: Double) -> Double {
    let span = line.to - line.from
    let across = span == 0 ? 0.5 : (year - line.from) / span
    return inset + across * (1 - 2 * inset)
}

/// How far apart two events' letters have to be drawn to read as two letters —
/// their own half-widths plus `labelDaylight`'s clear air. It is about three
/// times `minTimelineTickGap`, so what limits a timeline is almost always its
/// letters and hardly ever its ticks.
private func letterPitch(_ chars: Int) -> Double {
    (Double(chars) + labelDaylight) * charShare
}

/// How far apart the nearest two events are drawn on this line, in frame units.
private func closestPair(
    _ years: [Double], _ line: TimelineLine, _ inset: Double
) -> Double {
    let xs = years.map { positionFor($0, line, inset) }.sorted()
    var closest = Double.infinity
    for index in 1..<max(xs.count, 1) where index < xs.count {
        closest = Swift.min(closest, xs[index] - xs[index - 1])
    }
    return closest
}

/// Whether every neighbouring pair of events is drawn far enough apart to read
/// as two.
private func lettersStandApart(
    _ years: [Double], _ line: TimelineLine, _ inset: Double, _ eventChars: Int
) -> Bool {
    closestPair(years, line, inset) >= letterPitch(eventChars) - tlEpsilon
}

/// The lines this timeline could be drawn on. A pinned field is always kept — it
/// is the author's statement about which stretch of history the question is
/// about, and anything wrong with it is reported by the validator rather than
/// overridden here.
///
/// Left open, a division is taken from the ladder coarsest first and the two
/// ends from `overshoot`, keeping every combination that puts a tick under every
/// event and still reads at report scale.
private func linesFor(
    _ years: [Double], _ eventChars: Int,
    _ pinnedFrom: Double?, _ pinnedTo: Double?, _ pinnedStep: Double?
) -> [TimelineLine] {
    guard let lo = years.min(), let hi = years.max() else { return [] }

    let steps: [Double]
    if let pinnedStep {
        steps = [pinnedStep]
    } else {
        steps = stepLadder.filter { step in years.allSatisfy { onLattice($0, lo, step) } }
    }

    var lines: [TimelineLine] = []
    for step in steps {
        guard step > 0 else { continue }
        let froms = pinnedFrom.map { [$0] } ?? overshoot.map { lo - $0 * step }
        let tos = pinnedTo.map { [$0] } ?? overshoot.map { hi + $0 * step }

        for from in froms {
            for to in tos {
                let line = TimelineLine(from: from, to: to, step: step)
                guard to > from else { continue }
                if from > lo + tlEpsilon || to < hi - tlEpsilon { continue }
                let intervals = (to - from) / step
                if abs(intervals - JSNumber.round(intervals)) > tlEpsilon { continue }
                if intervals < Double(minIntervals) || intervals > Double(maxIntervals) { continue }
                if !years.allSatisfy({ onLattice($0, from, step) }) { continue }
                // The ticks have to be countable along the stretch the *rungs*
                // get, which is what the labels' inset left over rather than the
                // whole frame.
                let inset = insetFor(line, eventChars)
                if (1 - 2 * inset) / intervals < minTimelineTickGap - tlEpsilon { continue }
                // And the events themselves have to stand apart on it. A filter
                // rather than a report because it is a limit the geometry can
                // honour by choosing differently.
                if !lettersStandApart(years, line, inset, eventChars) { continue }
                lines.append(line)
            }
        }
    }
    return lines
}

/// A line to draw when nothing in `linesFor` survived — still something a child
/// can look at rather than an empty box. It honours whatever was pinned, so the
/// picture in front of the child is the one the author asked for even where that
/// picture is the mistake.
private func fallbackLine(
    _ years: [Double], _ pinnedFrom: Double?, _ pinnedTo: Double?, _ pinnedStep: Double?
) -> TimelineLine {
    let lo = years.min() ?? 0
    let hi = years.max() ?? 0
    let step: Double
    if let pinnedStep, pinnedStep > 0 {
        step = pinnedStep
    } else {
        step = Swift.max((hi - lo) / 4, tlEpsilon)
    }
    return TimelineLine(
        from: pinnedFrom ?? lo - step,
        to: pinnedTo ?? hi + step,
        step: step)
}

/// The comma-joined list, or nothing at all — `Number('')` is 0, so a hole is a
/// typo rather than a year.
private func parseYears(_ text: String) -> [Double]? {
    let parts = text.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    if parts.contains(where: { $0.isEmpty }) { return nil }

    var years: [Double] = []
    for part in parts {
        guard let year = jsNumber(part), year.isFinite else { return nil }
        years.append(year)
    }
    return years
}

/// JavaScript's `Number(string)`, which is what the oracle's `parts.map(Number)`
/// calls. Swift's `Double(_:)` refuses several strings JS accepts - a leading
/// `+`, a hex literal, whitespace - and accepts a few it does not, so the
/// conversion is spelled out rather than taken from the standard library.
private func jsNumber(_ text: String) -> Double? {
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { return 0 }
    if trimmed == "Infinity" || trimmed == "+Infinity" { return .infinity }
    if trimmed == "-Infinity" { return -.infinity }
    // `Double("0x1f")` parses as a hex float in Swift; JavaScript reads it as
    // the integer 31. Neither reaches a real timeline, but the two must not
    // disagree about which strings are numbers at all.
    if trimmed.lowercased().hasPrefix("0x") || trimmed.lowercased().hasPrefix("-0x") {
        return nil
    }
    return Double(trimmed)
}

private func parseLabels(_ text: String) -> [String] {
    text.split(separator: ",", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
}

/// The letters, whether the template named them or left them to run A, B, C.
private func lettersFor(_ names: [String], _ count: Int) -> [String] {
    (0..<count).map { index in
        if index < names.count { return names[index] }
        return String(alphabet[index % 26])
    }
}

private func openPath(_ from: Point, _ to: Point) -> Mark {
    .path(points: [from, to], closed: false, fill: false, dashed: false)
}

struct TimelineBuilder: FigureKindBuilder {
    let kind = "timeline"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let read = readField(spec["years"], scope)
        let parsed = stringValue(read).flatMap(parseYears)
        let years = Array((parsed ?? fallbackYears).prefix(maxDrawnEvents))

        let names = stringValue(readField(spec["labels"], scope)).map(parseLabels) ?? []
        let letters = lettersFor(names, years.count)
        let eventChars = Swift.max(letters.map(\.count).max() ?? 1, 1)

        let pinnedFrom = numberValue(readField(spec["from"], scope))
        let pinnedTo = numberValue(readField(spec["to"], scope))
        let pinnedStep = numberValue(readField(spec["step"], scope))

        let candidates = linesFor(years, eventChars, pinnedFrom, pinnedTo, pinnedStep)
        // Exactly one draw whichever path this takes, pinned or not: a figure
        // that spends a variable number of draws reshuffles the distractors of
        // the very question it illustrates.
        let line = rng.pick(
            candidates.isEmpty
                ? [fallbackLine(years, pinnedFrom, pinnedTo, pinnedStep)]
                : candidates)
        let inset = insetFor(line, eventChars)

        let tick = jitter(&rng, timelineTickBand.0, timelineTickBand.1)
        let eventGap = jitter(&rng, eventGapBand.0, eventGapBand.1)
        let major = tick * majorRatio

        // The rule first, because it is what the fit measures the drawing by:
        // every label's ink ends inside it, so nothing here can be clipped.
        var marks: [Mark] = [openPath(Point(0, 0), Point(1, 0))]

        let intervals = Swift.min(
            Swift.max(Int(JSNumber.round((line.to - line.from) / line.step)), 1),
            maxDrawnTicks)
        for index in 0...intervals {
            let year = line.from + Double(index) * line.step
            let end = (index == 0 || index == intervals) ? major : tick
            let x = positionFor(year, line, inset)
            marks.append(openPath(Point(x, 0), Point(x, -end)))
        }

        for end in [line.from, line.to] {
            marks.append(.label(
                at: Point(positionFor(end, line, inset), -(major + yearGap)),
                text: formatYear(end)))
        }

        for (index, year) in years.enumerated() {
            let x = positionFor(year, line, inset)
            marks.append(.dot(at: Point(x, 0)))
            let letter = letters[index]
            if !letter.isEmpty {
                marks.append(.label(at: Point(x, eventGap), text: letter))
            }
        }

        return marks
    }
}

let timelineBuilder = TimelineBuilder()
