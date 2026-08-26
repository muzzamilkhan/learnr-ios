import Foundation

/// The `angle` kind, ported from `src/lib/figures/angle.ts` and
/// `angle-kind.ts`: a vertex, two arms, and the sweep between them.
///
/// **The arms are deliberately unequal.** Two arms the same length every time
/// is an anchor of exactly the kind this feature exists to avoid, and it feeds
/// a misconception ACARA names outright: children read a longer pair of arms as
/// a bigger angle. Drawing the same angle with a long arm and a short one, then
/// with two middling ones, is what says the arms are not the measurement.
///
/// **There is never a right-angle square.** A little box in the corner is how a
/// right angle is conventionally marked, and it would answer "what kind of
/// angle is this?" before the child had looked at it. A right angle here is
/// drawn like any other and has to be recognised.

/// How far out the sweep is drawn, as a share of the shorter arm.
private let arcShare = 0.3

/// How long an angle's arms are drawn, before the fit rescales everything.
private let armBand = (0.6, 1.0)

/// Where a broken or missing `degrees` lands — still an angle, just not the
/// asked one.
private let degreesBand = (15.0, 345.0)

/// The angles that can be drawn at all: a zero is no angle and a full turn is
/// none either.
private let degreesRange = (1.0, 359.0)

struct AngleBuilder: FigureKindBuilder {
    let kind = "angle"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let asked = numberValue(readField(spec["degrees"], scope))
        let degrees = asked.map { clamp($0, degreesRange.0, degreesRange.1) }
            ?? jitter(&rng, degreesBand.0, degreesBand.1)
        let rotation = numberValue(readField(spec["rotation"], scope))
            ?? jitter(&rng, 0, 360)

        // A pinned arm length makes both arms that length — pinning is pinning.
        // What it really says is "the same", since the fit rescales the drawing
        // and only the ratio between the two arms survives it.
        let pinned = numberValue(readField(spec["armLength"], scope))
        let arms: (Double, Double)
        if let pinned, pinned > 0 {
            arms = (pinned, pinned)
        } else {
            // Two separate draws, in this order. One draw used for both arms
            // would make them equal, which is the anchor this kind refuses.
            let first = jitter(&rng, armBand.0, armBand.1)
            let second = jitter(&rng, armBand.0, armBand.1)
            arms = (first, second)
        }

        let arc = readField(spec["arc"], scope)
        // Absent means true here, unlike the usual falsy reading: the sweep is
        // drawn unless a template says not to.
        return angleMarks(degrees, rotation, arms, arc == nil ? true : truthy(arc))
    }
}

let angleBuilder = AngleBuilder()

func angleMarks(
    _ degrees: Double,
    _ rotation: Double,
    _ armLength: (Double, Double),
    _ arc: Bool
) -> [Mark] {
    let (first, second) = armLength
    let start = rotation
    let end = rotation + degrees

    var marks: [Mark] = [
        // One polyline through the vertex rather than two segments meeting
        // there: the corner is the thing being asked about, and a join drawn
        // twice is a join that can be drawn twice differently.
        .path(
            points: [along(start, first), Point(0, 0), along(end, second)],
            closed: false, fill: false, dashed: false
        ),
        // The arms alone do not say which end is the corner — at a glance a
        // shallow angle is two lines that happen to cross.
        .dot(at: Point(0, 0)),
    ]

    if arc {
        // Inside the shorter arm, so the sweep never runs off the end of the
        // thing it is measuring between.
        marks.append(.arc(
            at: Point(0, 0),
            radius: Swift.min(first, second) * arcShare,
            from: start,
            to: end
        ))
    }

    return marks
}

private func along(_ degrees: Double, _ distance: Double) -> Point {
    let radians = degrees * .pi / 180
    return Point(Foundation.cos(radians) * distance, Foundation.sin(radians) * distance)
}
