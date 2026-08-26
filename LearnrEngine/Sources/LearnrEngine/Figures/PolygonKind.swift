import Foundation

/// The `polygon` kind, ported from `src/lib/figures/polygon-kind.ts`: a named
/// shape, turned, optionally ticked at its square corners and optionally
/// crossed by a line that is or is not an axis of symmetry.

/// A right-angle tick, as a share of the shorter of the two edges meeting there.
private let tickShare = 0.15

/// How far a mirror line runs past the shape it crosses, as a share of the
/// shape's own size.
///
/// An overhang on top of what the shape occupies *along that line* rather than
/// a multiple of the whole shape: the fit scales everything drawn, so a line
/// measured against the widest part of the shape rather than the part it
/// crosses shrinks the shape to make room for daylight nobody asked for.
private let mirrorOverhang = 0.12

/// Two edges are square when their directions are this close to perpendicular.
private let squareEnough = 1e-6

/// How near the best available angle a candidate mirror line has to be to count
/// as "not an axis".
///
/// A share rather than a fixed number of degrees because the room available
/// depends on the shape: a rectangle has 45 degrees of daylight between its
/// axes and an octagon has 11, and a fixed tolerance wide enough to mean
/// anything on the rectangle is unsatisfiable on the octagon.
private let offAxisShare = 0.8

struct PolygonBuilder: FigureKindBuilder {
    let kind = "polygon"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let shape = shapeName(readField(spec["shape"], scope))
        let points = unitPolygon(shape, &rng)
        let rotation = numberValue(readField(spec["rotation"], scope))
            ?? jitter(&rng, 0, 360)
        let turned = points.map { rotate($0, rotation) }

        var marks: [Mark] = [
            .path(points: turned, closed: true, fill: false, dashed: false)
        ]

        if truthy(readField(spec["rightAngles"], scope)) {
            marks.append(contentsOf: rightAngleTicks(turned))
        }

        // Absent is the one state that draws nothing. Present and false is a
        // question with a false answer, which needs a line to be false *about*.
        //
        // Read against the raw field rather than the evaluated value: a
        // `mirror` that fails to evaluate is absent to `readField`, and absent
        // draws no line at all.
        if spec["mirror"] != nil {
            let mirror = readField(spec["mirror"], scope)
            marks.append(
                mirrorLine(turned, symmetryAxes(shape), truthy(mirror), rotation, &rng)
            )
        }

        return marks
    }
}

let polygonBuilder = PolygonBuilder()

/// A tick at every corner that is square, drawn as a three-point open path.
///
/// Which corners those are is read off the geometry rather than kept in a table
/// per shape, so a square, a rectangle and a right triangle all get theirs from
/// the same four lines, and a shape that stops having one stops being ticked.
private func rightAngleTicks(_ points: [Point]) -> [Mark] {
    var marks: [Mark] = []

    for index in points.indices {
        let corner = points[index]
        let before = points[(index - 1 + points.count) % points.count]
        let after = points[(index + 1) % points.count]

        let toBefore = Point(before.x - corner.x, before.y - corner.y)
        let toAfter = Point(after.x - corner.x, after.y - corner.y)
        let lengthBefore = (toBefore.x * toBefore.x + toBefore.y * toBefore.y).squareRoot()
        let lengthAfter = (toAfter.x * toAfter.x + toAfter.y * toAfter.y).squareRoot()
        if lengthBefore == 0 || lengthAfter == 0 { continue }

        let u = Point(toBefore.x / lengthBefore, toBefore.y / lengthBefore)
        let v = Point(toAfter.x / lengthAfter, toAfter.y / lengthAfter)
        if Swift.abs(u.x * v.x + u.y * v.y) > squareEnough { continue }

        let step = tickShare * Swift.min(lengthBefore, lengthAfter)
        marks.append(.path(
            points: [
                Point(corner.x + u.x * step, corner.y + u.y * step),
                Point(corner.x + (u.x + v.x) * step, corner.y + (u.y + v.y) * step),
                Point(corner.x + v.x * step, corner.y + v.y * step),
            ],
            closed: false, fill: false, dashed: false
        ))
    }

    return marks
}

/// The dashed line across the shape: a real axis of symmetry, or a plausible
/// wrong one.
///
/// Which of the true axes, and which of the wrong lines, is the builder's to
/// vary — a symmetry question whose true case always drew the vertical would
/// teach the picture rather than the property.
///
/// A shape with no axes asked for a true mirror is a clamp, not a refusal: it
/// gets a wrong line like any other, and validation says so at authoring time,
/// where somebody can fix the template.
private func mirrorLine(
    _ points: [Point],
    _ axes: [Double],
    _ wanted: Bool,
    _ rotation: Double,
    _ rng: inout Rng
) -> Mark {
    let base = wanted && !axes.isEmpty ? rng.pick(axes) : offAxis(axes, &rng)
    let angle = base + rotation
    let radians = angle * .pi / 180
    let cos = Foundation.cos(radians)
    let sin = Foundation.sin(radians)

    // `Math.max(...values, 0)` in the JavaScript: the trailing 0 is a floor, so
    // an empty point list still yields 0 rather than -Infinity.
    let crossed = points.reduce(0.0) { Swift.max($0, Swift.abs($1.x * cos + $1.y * sin)) }
    let size = points.reduce(0.0) { Swift.max($0, ($1.x * $1.x + $1.y * $1.y).squareRoot()) }
    let half = crossed + size * mirrorOverhang
    let step = Point(cos * half, sin * half)

    return .path(
        points: [Point(-step.x, -step.y), Point(step.x, step.y)],
        closed: false, fill: false, dashed: true
    )
}

/// An angle as far from every axis as the shape allows, jittered among the
/// candidates that come close to it.
///
/// Asking for "at least n degrees off" would be unanswerable for an octagon,
/// whose axes are 22.5 degrees apart; asking for the roomiest angle available
/// is answerable for every shape, and for a shape with no axes at all it is
/// simply any angle.
private func offAxis(_ axes: [Double], _ rng: inout Rng) -> Double {
    if axes.isEmpty { return jitter(&rng, 0, 180) }

    let best = bestClearance(axes)
    let candidates = candidateLines.filter {
        clearanceAt($0, axes) >= best * offAxisShare
    }
    return rng.pick(candidates)
}

/// Every line worth considering, to the degree.
private let candidateLines: [Double] = (0..<180).map(Double.init)

/// How far one line is from the nearest axis — 90, the most there is, when
/// there are none.
private func clearanceAt(_ degrees: Double, _ axes: [Double]) -> Double {
    axes.isEmpty ? 90 : axes.map { separation(degrees, $0) }.min()!
}

/// The most daylight any line can find between a shape's axes.
private func bestClearance(_ axes: [Double]) -> Double {
    candidateLines.map { clearanceAt($0, axes) }.max()!
}

/// How far apart two lines are, in degrees — never more than 90, since a line
/// has no direction.
private func separation(_ a: Double, _ b: Double) -> Double {
    let raw = (a - b).truncatingRemainder(dividingBy: 180)
    let gap = (raw + 180).truncatingRemainder(dividingBy: 180)
    return Swift.min(gap, 180 - gap)
}

/// Anything unknown falls back to an equilateral triangle — "something
/// drawable" is the contract mid-session.
private func shapeName(_ value: Value?) -> String {
    guard let name = stringValue(value), polygonShapes.contains(name) else {
        return "equilateral"
    }
    return name
}

private func rotate(_ p: Point, _ degrees: Double) -> Point {
    let radians = degrees * .pi / 180
    let cos = Foundation.cos(radians)
    let sin = Foundation.sin(radians)
    return Point(p.x * cos - p.y * sin, p.x * sin + p.y * cos)
}
