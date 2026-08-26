import Foundation

/// The named shapes and where their lines of symmetry are, ported from
/// `src/lib/figures/polygon.ts`.
///
/// **Every shape is jittered, within what keeps its name true.** That is the
/// anchoring rule made arithmetic: a rectangle varies its aspect but stays a
/// rectangle, an isosceles triangle varies its apex and base but keeps exactly
/// two sides equal, a scalene keeps all three unequal. A child who sees the
/// same rectangle every time learns that picture rather than the property.
///
/// The regular shapes — `equilateral`, `square`, `pentagon` through `octagon` —
/// are the honest exception: their proportions are fixed by the name, so there
/// is nothing left to vary but size and rotation. Size does not survive the
/// uniform fit, so their whole variation is the rotation the builder supplies.
/// That is why `rotation` jitters by default and pinning it is deliberate.
///
/// Everything here is in the ordinary maths frame: x right, y up, angles
/// anticlockwise from east. Vertices come back centred on their own mean, which
/// is the centre every axis of symmetry passes through — a reflection permutes
/// the vertices, so it fixes their mean.

/// One of two bands, so a value can be kept clear of the one that changes the
/// shape's name.
private func eitherBand(
    _ rng: inout Rng,
    _ band: (Double, Double),
    _ other: (Double, Double)
) -> Double {
    // Two draws, always: the choice and then the jitter. The order is what the
    // JavaScript spends, so it is what this spends.
    let pick = rng.next() < 0.5 ? band : other
    return jitter(&rng, pick.0, pick.1)
}

/// Vertices of a regular n-gon on the unit circle, the first at `start` degrees.
private func regular(_ sides: Int, _ start: Double) -> [Point] {
    (0..<sides).map { index in
        let angle = (start + 360 * Double(index) / Double(sides)) * .pi / 180
        return Point(Foundation.cos(angle), Foundation.sin(angle))
    }
}

/// A triangle from its three side lengths, laid on its base.
///
/// Built this way rather than by moving a vertex around because the property
/// that must survive the jitter — two sides equal, or all three unequal — is a
/// fact about the lengths, so drawing from the lengths makes it true by
/// construction instead of by rejection.
private func triangle(_ base: Double, _ left: Double, _ right: Double) -> [Point] {
    let x = (left * left - right * right + base * base) / (2 * base)
    let y = (Swift.max(0, left * left - x * x)).squareRoot()
    return [Point(0, 0), Point(base, 0), Point(x, y)]
}

/// Shift a shape so its vertex mean sits on the origin, where its axes cross.
private func centred(_ points: [Point]) -> [Point] {
    let n = Double(points.count)
    let mx = points.reduce(0) { $0 + $1.x } / n
    let my = points.reduce(0) { $0 + $1.y } / n
    return points.map { Point($0.x - mx, $0.y - my) }
}

func unitPolygon(_ shape: String, _ rng: inout Rng) -> [Point] {
    centred(polygonVertices(shape, &rng))
}

private func polygonVertices(_ shape: String, _ rng: inout Rng) -> [Point] {
    switch shape {
    case "equilateral": return regular(3, 90)
    // From 45 degrees, so the square sits square on the page before rotation.
    case "square": return regular(4, 45)
    case "pentagon": return regular(5, 90)
    case "hexagon": return regular(6, 90)
    case "heptagon": return regular(7, 90)
    case "octagon": return regular(8, 90)

    case "isosceles":
        // The legs are equal by construction; what has to be watched is the
        // base accidentally joining them. A leg is `sqrt(b² + h²)` against a
        // base of `2b`, so the two meet at `h = √3·b` — the equilateral — and
        // the height is drawn from a band either side of it, never across it.
        let half = jitter(&rng, 0.35, 0.75)
        let height = eitherBand(&rng, (0.7 * half, 1.3 * half), (2 * half, 3 * half))
        let leg = (half * half + height * height).squareRoot()
        return triangle(2 * half, leg, leg)

    case "scalene":
        // Three lengths from three bands that do not overlap, so no two can
        // come out equal, and whose worst case still clears the triangle
        // inequality by a wide margin — a scalene drawn as a sliver is one
        // nobody can see the three unequal sides of.
        let shortest = 1.0
        let middle = jitter(&rng, 1.2, 1.4)
        let longest = jitter(&rng, 1.55, 1.8)
        return triangle(longest, shortest, middle)

    case "right-triangle":
        // The legs are kept unequal on purpose: equal legs are an isosceles
        // right triangle, which has a line of symmetry, and `symmetryAxes`
        // answers per name — it cannot say "sometimes".
        let other = eitherBand(&rng, (0.45, 0.8), (1.25, 2))
        return [Point(0, 0), Point(1, 0), Point(0, other)]

    case "rectangle":
        let short = jitter(&rng, 0.35, 0.75)
        // Upright as often as it is laid down. Rotation would eventually get
        // there, but an author who pinned rotation to 0 would only see one.
        let (w, h) = rng.next() < 0.5 ? (1.0, short) : (short, 1.0)
        return [Point(-w, -h), Point(w, -h), Point(w, h), Point(-w, h)]

    case "rhombus":
        // Diagonals along the axes, which is how a rhombus is drawn and where
        // its two lines of symmetry are. Kept unequal so it is not a square.
        let other = eitherBand(&rng, (0.45, 0.8), (1.25, 1.8))
        return [Point(1, 0), Point(0, other), Point(-1, 0), Point(0, -other)]

    case "parallelogram":
        // A slanted rectangle. The slant is never zero, so it is never a
        // rectangle, and the bands keep the slanted side shorter than the base,
        // so it is never a rhombus either — both of which have symmetry this
        // shape is defined by not having.
        let half = jitter(&rng, 0.4, 0.7)
        let slant = jitter(&rng, 0.3, 0.55)
        return [
            Point(-1 - slant, -half), Point(1 - slant, -half),
            Point(1 + slant, half), Point(-1 + slant, half),
        ]

    case "trapezium":
        // Always isosceles, and that is a decision rather than a shortcut:
        // `symmetryAxes` is keyed by name, so a trapezium with an axis on some
        // draws and not others would make "is the dashed line a line of
        // symmetry?" a question with no knowable answer.
        let top = jitter(&rng, 0.3, 0.7)
        let half = jitter(&rng, 0.35, 0.7)
        return [
            Point(-1, -half), Point(1, -half), Point(top, half), Point(-top, half),
        ]

    case "kite":
        // Two pairs of adjacent equal sides: the vertical diagonal is the axis,
        // and the two halves of it differ so the kite is not a rhombus.
        let top = jitter(&rng, 0.8, 1.2)
        let bottom = jitter(&rng, 0.35, 0.6)
        let half = jitter(&rng, 0.4, 0.7)
        return [Point(0, top), Point(half, 0), Point(0, -bottom), Point(-half, 0)]

    default:
        // Unreachable through `shapeName`, which maps anything unknown to
        // `equilateral` before this is called.
        return regular(3, 90)
    }
}

/// The angles, in degrees in the shape's own unrotated frame, of every line of
/// symmetry — normalised into `[0, 180)`, because a line at 210 degrees and a
/// line at 30 are the same line.
///
/// This is what lets `mirror: 'true'` draw a real axis and `mirror: 'false'`
/// draw a plausible wrong one, so it has to agree with `unitPolygon` exactly
/// rather than approximately: a shape whose claimed axis is a degree off would
/// make the true case of a symmetry question quietly false.
func symmetryAxes(_ shape: String) -> [Double] {
    switch shape {
    case "equilateral": return regularAxes(3, 90)
    case "square": return regularAxes(4, 45)
    case "pentagon": return regularAxes(5, 90)
    case "hexagon": return regularAxes(6, 90)
    case "heptagon": return regularAxes(7, 90)
    case "octagon": return regularAxes(8, 90)

    // The one axis is the vertical: the apex over the middle of the base, the
    // long diagonal of the kite, the line between the two parallel sides.
    case "isosceles", "trapezium", "kite": return [90]

    // Both diagonals of a rhombus, and both midlines of a rectangle.
    case "rectangle", "rhombus": return [0, 90]

    // None, by definition — and `right-triangle` joins them because its legs
    // are drawn unequal.
    case "scalene", "right-triangle", "parallelogram": return []

    default: return []
    }
}

/// A regular n-gon has n axes.
///
/// With an odd number of sides each runs from a vertex to the middle of the
/// side opposite, so the axes are the vertices themselves as lines; with an
/// even number they come in two interleaved sets — vertex to vertex and side to
/// side — which is the same thing as a half step.
private func regularAxes(_ sides: Int, _ start: Double) -> [Double] {
    let step = sides % 2 == 0 ? 180.0 / Double(sides) : 360.0 / Double(sides)
    let axes = (0..<sides).map { normaliseAxis(start + step * Double($0)) }
    // Deduplicated and sorted, matching the JavaScript's `Set` then `sort`.
    return Array(Set(axes)).sorted()
}

/// A line has no direction, so every axis angle folds into `[0, 180)`.
private func normaliseAxis(_ degrees: Double) -> Double {
    let m = degrees.truncatingRemainder(dividingBy: 180)
    return (m + 180).truncatingRemainder(dividingBy: 180)
}
