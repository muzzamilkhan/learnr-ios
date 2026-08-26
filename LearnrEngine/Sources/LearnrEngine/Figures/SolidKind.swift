import Foundation

/// The `solid` kind, ported from `src/lib/figures/solid-kind.ts`: seven solids,
/// each drawn either as an object in oblique projection or as the net it folds
/// up from.
///
/// **A solid has no upright**, so which of the eight ways round a net lies, and
/// which side an object's depth leans towards, stay free whatever `rotation`
/// says. That is deliberate: it is what lets a pinned rotation still satisfy
/// the anchoring check, where a regular polygon's pinned rotation has to be
/// refused outright.

let solids = [
    "cube", "cuboid", "sphere", "cone", "cylinder",
    "square-pyramid", "triangular-prism",
]

private let solidViews = ["object", "net"]

/// The solids that cannot be unfolded flat.
private let netless = ["sphere"]

private let fallbackSolid = "cube"

/// How many points a whole turn of a curved rim is sampled at. Sixty is 6
/// degrees a step, which on a report thumbnail's ~28px radius bulges 0.04px
/// inside the true circle: a circle, not a polygon.
private let curvePoints = 60

/// Which way the depth axis leans, in degrees above the horizontal.
///
/// It stays under 56 for a reason the triangular prism sets: the far corner of
/// a triangular face is behind the near one only while the lean is shallower
/// than the face's own sides, and the shallowest side this file draws rises at
/// `2 * 0.75` to 1 — about 56.3 degrees.
private let leanDegrees = (28.0, 55.0)

/// How far the back of a solid sits from its front, as a share of the shortest
/// side of the face it recedes behind.
///
/// **Under one, which is the whole proof that a far corner is always buried**:
/// the offset is no longer than the near face's shortest side, so neither of
/// its two components can reach past that face, whatever the lean is.
private let depthShare = (0.35, 0.55)

private let cuboidMiddle = (0.62, 0.72)
private let cuboidShort = (0.3, 0.42)

private let pyramidHeight = (0.85, 1.5)
private let prismApex = (0.75, 1.05)
private let prismLength = (0.8, 1.9)
private let cylinderHeight = (1.2, 2.4)
private let coneHeight = (1.4, 2.6)
private let rimSquash = (0.2, 0.38)
/// The only thing that varies about a sphere at all: a ball has no proportion,
/// so where the child is standing is the whole of what one seed can differ by.
private let sphereSquash = (0.16, 0.4)
/// Over a half, and that floor is not taste: four triangles shorter than half
/// the square they stand on cannot reach one another when they fold up.
private let pyramidSlant = (0.62, 1.15)
private let cylinderNetHeight = (1.6, 4.0)
private let coneNetHeight = (1.2, 3.0)
private let coneBaseAlong = 0.3

/// The eleven nets of a cube, as the grid cells each one fills — column right,
/// row down.
///
/// Eleven is the whole answer up to turning and flipping, not a selection.
/// Which one a child sees is the anchoring answer: it is the reason a cube's
/// net cannot be pinned to a picture.
let cubeNets: [[(Int, Int)]] = [
    // A row of four with a flap above and below — six of the eleven.
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (0, 2)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (1, 2)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (2, 2)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (3, 1), (3, 2)],
    [(1, 0), (0, 1), (1, 1), (1, 2), (2, 2), (1, 3)],
    [(1, 0), (0, 1), (1, 1), (2, 1), (1, 2), (1, 3)],
    // Two, three and one: three more.
    [(0, 0), (0, 1), (1, 1), (1, 2), (1, 3), (2, 3)],
    [(0, 0), (0, 1), (1, 1), (1, 2), (2, 2), (1, 3)],
    [(0, 0), (0, 1), (1, 1), (2, 1), (1, 2), (1, 3)],
    // The staircase, and the one made of two rows of three.
    [(0, 0), (0, 1), (1, 1), (1, 2), (2, 2), (2, 3)],
    [(0, 0), (0, 1), (0, 2), (1, 2), (1, 3), (1, 4)],
]

struct SolidBuilder: FigureKindBuilder {
    let kind = "solid"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        // **One value off the question's own `Rng`, expanded into a stream of
        // its own.** A figure that took a different number of values for a
        // cube's net than for a sphere would reshuffle the distractors of the
        // very question it illustrates — and adding `view: 'net'` to a template
        // would silently change that template's own choices. Everything below
        // draws from the private stream, so this kind's appetite is one, always.
        var stream = Rng(seed: "solid-\(JSNumber.toString(rng.next()))")

        let name = solidName(readField(spec["solid"], scope)) ?? fallbackSolid
        let asked = viewName(readField(spec["view"], scope))
        let view: String
        if netless.contains(name) {
            view = "object"
        } else if let asked {
            view = asked
        } else {
            view = stream.next() < 0.5 ? "object" : "net"
        }

        let drawn = view == "net"
            ? netLines(name, &stream)
            : objectLines(name, &stream)

        // A net has no upright, so all eight ways round a square are open to
        // it; an object has one, and only the side its depth leans towards is
        // free. Both are lifted out of the turn below because a mirror is not a
        // rotation, and because a quarter turn done exactly beats one done in
        // cosines.
        let flip = stream.next() < 0.5
        let quarters = view == "net" ? stream.int(0, 3) : 0
        let placed = movePoints(drawn) {
            quarterTurned(flip ? flipped($0) : $0, quarters)
        }

        // Drawn last, so a pinned rotation leaves everything above untouched.
        let rotation = numberValue(readField(spec["rotation"], scope))
            ?? jitter(&stream, 0, 360)
        return movePoints(placed) { turned($0, rotation) }
    }
}

let solidBuilder = SolidBuilder()

private func degreesToRadians(_ degrees: Double) -> Double { degrees * .pi / 180 }

private func seen(_ points: [Point], _ closed: Bool = false) -> Mark {
    .path(points: points, closed: closed, fill: false, dashed: false)
}

/// An edge the solid itself is in the way of. Never closed: it is always part
/// of a face.
private func unseen(_ points: [Point]) -> Mark {
    .path(points: points, closed: false, fill: false, dashed: true)
}

private func movePoints(_ lines: [Mark], _ move: (Point) -> Point) -> [Mark] {
    lines.map { mark in
        guard case .path(let points, let closed, let fill, let dashed) = mark else {
            return mark
        }
        return .path(points: points.map(move), closed: closed, fill: fill, dashed: dashed)
    }
}

private func turned(_ p: Point, _ degrees: Double) -> Point {
    let angle = degreesToRadians(degrees)
    return Point(
        p.x * Foundation.cos(angle) - p.y * Foundation.sin(angle),
        p.x * Foundation.sin(angle) + p.y * Foundation.cos(angle)
    )
}

/// A quarter turn, done by swapping coordinates rather than by `turned(90)`: a
/// cosine of 90 degrees is 6e-17 rather than 0, and four of the eight ways a
/// net can lie would each be a hair's breadth off the axis for no reason.
private func quarterTurned(_ p: Point, _ quarters: Int) -> Point {
    switch ((quarters % 4) + 4) % 4 {
    case 1: return Point(-p.y, p.x)
    case 2: return Point(-p.x, -p.y)
    case 3: return Point(p.y, -p.x)
    default: return p
    }
}

private func flipped(_ p: Point) -> Point { Point(-p.x, p.y) }

/// Points on an ellipse, anticlockwise from east, both ends included.
private func arcPoints(
    _ centre: Point, _ rx: Double, _ ry: Double, _ from: Double, _ to: Double
) -> [Point] {
    let steps = Swift.max(2, Int(JSNumber.round((Swift.abs(to - from) / 360) * Double(curvePoints))))
    return (0...steps).map { index in
        let angle = degreesToRadians(from + ((to - from) * Double(index)) / Double(steps))
        return Point(
            centre.x + rx * Foundation.cos(angle),
            centre.y + ry * Foundation.sin(angle)
        )
    }
}

/// The whole rim, as a closed path. One sample short of a full turn, since it
/// closes itself.
private func ring(_ centre: Point, _ rx: Double, _ ry: Double) -> Mark {
    seen(Array(arcPoints(centre, rx, ry, 0, 360).dropLast()), true)
}

private func rectangle(_ x: Double, _ y: Double, _ width: Double, _ height: Double) -> [Point] {
    [Point(x, y), Point(x + width, y), Point(x + width, y + height), Point(x, y + height)]
}

/// Whether a point is strictly inside a convex polygon — the test that finds
/// the corner a solid hides behind itself.
///
/// Doing it rather than hard-coding "the far bottom corner" is what keeps the
/// dashed edges right for every proportion and every lean, instead of for the
/// ones that were drawn while it was written.
private func inside(_ p: Point, _ polygon: [Point]) -> Bool {
    if polygon.count < 3 { return false }
    var side = 0.0
    for index in polygon.indices {
        let a = polygon[index]
        let b = polygon[(index + 1) % polygon.count]
        let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
        if cross == 0 { return false }
        let now = JSNumber.sign(cross)
        if side == 0 { side = now } else if side != now { return false }
    }
    return true
}

/// How far the back of a solid is drawn from its front, as one 2D offset.
private struct Depth {
    var x: Double
    var y: Double
}

private func depthOf(_ rng: inout Rng, _ across: Double) -> Depth {
    let lean = degreesToRadians(jitter(&rng, leanDegrees.0, leanDegrees.1))
    let share = jitter(&rng, depthShare.0, depthShare.1) * across
    return Depth(x: share * Foundation.cos(lean), y: share * Foundation.sin(lean))
}

/// `z` is a share of the whole depth, so 0 is the near face and 1 the far one.
private func project(_ x: Double, _ y: Double, _ z: Double, _ depth: Depth) -> Point {
    Point(x + z * depth.x, y + z * depth.y)
}

private func shifted(_ points: [Point], _ depth: Depth) -> [Point] {
    points.map { Point($0.x + depth.x, $0.y + depth.y) }
}

/// A solid swept straight back from one face: a cuboid from a rectangle, a
/// triangular prism from a triangle.
///
/// The far copy of the face has at most one corner behind the near face, and
/// that corner's three edges are the ones you cannot see. If no corner is
/// behind — which the ranges are chosen to prevent — every edge is drawn solid.
private func sweptLines(_ face: [Point], _ depth: Depth) -> [Mark] {
    let back = shifted(face, depth)
    let corners = face.count
    let buried = back.firstIndex { inside($0, face) }
    var lines: [Mark] = [seen(face, true)]

    guard let buried else {
        lines.append(seen(back, true))
        return lines + face.indices.map { seen([face[$0], back[$0]]) }
    }

    func at(_ offset: Int) -> Point {
        back[((buried + offset) % corners + corners) % corners]
    }
    lines.append(seen((1..<corners).map { at($0) }))
    lines.append(unseen([at(-1), at(0), at(1)]))

    return lines + face.indices.map { index in
        index == buried
            ? unseen([face[index], back[index]])
            : seen([face[index], back[index]])
    }
}

/// A cuboid's three edges, longest first before they are dealt out to the axes.
///
/// **The whole of "this is a cuboid and not a cube"**: every pair is far enough
/// apart that no seed can draw one with edges near enough to equal to answer a
/// different question. Which axis gets the longest edge is dealt out too, so a
/// cuboid is tall on one seed and wide on the next.
func cuboidEdges(_ rng: inout Rng) -> (Double, Double, Double) {
    let edges = [
        1.0,
        jitter(&rng, cuboidMiddle.0, cuboidMiddle.1),
        jitter(&rng, cuboidShort.0, cuboidShort.1),
    ]
    let orders = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
    let order = orders[rng.int(0, orders.count - 1)]
    return (edges[order[0]], edges[order[1]], edges[order[2]])
}

private func boxEdges(_ name: String, _ rng: inout Rng) -> (Double, Double, Double) {
    name == "cube" ? (1, 1, 1) : cuboidEdges(&rng)
}

/// Which two of the three edges you are looking straight at is a choice of its
/// own, so a cuboid is tall on one seed and wide on the next. **The third is
/// not drawn to scale and cannot be** — the depth is a convention, a share of
/// the near face rather than a measurement.
private func boxObject(_ name: String, _ rng: inout Rng) -> [Mark] {
    let (width, height, _) = boxEdges(name, &rng)
    return sweptLines(
        rectangle(0, 0, width, height),
        depthOf(&rng, Swift.min(width, height))
    )
}

private func pyramidObject(_ rng: inout Rng) -> [Mark] {
    let height = jitter(&rng, pyramidHeight.0, pyramidHeight.1)
    let depth = depthOf(&rng, Swift.min(1, height))
    let base = [
        project(0, 0, 0, depth), project(1, 0, 0, depth),
        project(1, 0, 1, depth), project(0, 0, 1, depth),
    ]
    let apex = project(0.5, height, 0.5, depth)

    // The far base corner is the one hidden behind the face you are looking at,
    // which is the triangle the near base edge and the apex make.
    let front = [base[0], base[1], apex]
    let buried = base.indices.first { $0 >= 2 && inside(base[$0], front) }

    guard let buried else {
        return [seen(base, true)] + base.map { seen([$0, apex]) }
    }

    func at(_ offset: Int) -> Point {
        base[((buried + offset) % base.count + base.count) % base.count]
    }
    return [
        seen((1..<base.count).map { at($0) }),
        unseen([at(-1), at(0), at(1)]),
    ] + base.indices.map { index in
        index == buried ? unseen([base[index], apex]) : seen([base[index], apex])
    }
}

private func prismObject(_ rng: inout Rng) -> [Mark] {
    let apex = jitter(&rng, prismApex.0, prismApex.1)
    let face = [Point(0, 0), Point(1, 0), Point(0.5, apex)]
    return sweptLines(face, depthOf(&rng, Swift.min(1, apex)))
}

private func cylinderObject(_ rng: inout Rng) -> [Mark] {
    let height = jitter(&rng, cylinderHeight.0, cylinderHeight.1)
    let squash = jitter(&rng, rimSquash.0, rimSquash.1)
    return [
        ring(Point(0, height), 1, squash),
        // The near half of the bottom rim is the half below its widest points;
        // the far half is behind the cylinder itself.
        seen(arcPoints(Point(0, 0), 1, squash, 180, 360)),
        unseen(arcPoints(Point(0, 0), 1, squash, 0, 180)),
        seen([Point(-1, 0), Point(-1, height)]),
        seen([Point(1, 0), Point(1, height)]),
    ]
}

private func coneObject(_ rng: inout Rng) -> [Mark] {
    let height = jitter(&rng, coneHeight.0, coneHeight.1)
    let squash = jitter(&rng, rimSquash.0, rimSquash.1)
    // The sloping sides touch the base rim, and where they touch is not its
    // widest point: squash the picture back into a circle, take the tangent
    // from the apex, and squash the answer again. Drawing them to the widest
    // points instead puts a visible kink where the side meets the rim.
    let reach = height / squash
    let touch = Foundation.atan2(1 / reach, (reach * reach - 1).squareRoot() / reach) * 180 / .pi
    let right = Point(
        Foundation.cos(degreesToRadians(touch)),
        squash * Foundation.sin(degreesToRadians(touch))
    )
    let left = Point(-right.x, right.y)
    let apex = Point(0, height)

    return [
        seen(arcPoints(Point(0, 0), 1, squash, 180 - touch, 360 + touch)),
        unseen(arcPoints(Point(0, 0), 1, squash, touch, 180 - touch)),
        seen([apex, right]),
        seen([apex, left]),
    ]
}

private func sphereObject(_ rng: inout Rng) -> [Mark] {
    let squash = jitter(&rng, sphereSquash.0, sphereSquash.1)
    return [
        ring(Point(0, 0), 1, 1),
        // The line round the middle is what says this is a ball rather than a
        // circle, and its near half is the half you can see.
        seen(arcPoints(Point(0, 0), 1, squash, 180, 360)),
        unseen(arcPoints(Point(0, 0), 1, squash, 0, 180)),
    ]
}

private func objectLines(_ name: String, _ rng: inout Rng) -> [Mark] {
    switch name {
    case "cube", "cuboid": return boxObject(name, &rng)
    case "square-pyramid": return pyramidObject(&rng)
    case "triangular-prism": return prismObject(&rng)
    case "cylinder": return cylinderObject(&rng)
    case "cone": return coneObject(&rng)
    case "sphere": return sphereObject(&rng)
    default: return boxObject("cube", &rng)
    }
}

private func cubeNet(_ rng: inout Rng) -> [Mark] {
    let cells = cubeNets[rng.int(0, cubeNets.count - 1)]
    // The table counts rows downwards and this frame counts y upwards, which
    // costs a minus and nothing else: a net turned over is still that net.
    return cells.map { seen(rectangle(Double($0.0), -Double($0.1), 1, 1), true) }
}

/// A cuboid's net: the four faces round one axis in a row, with the two ends
/// flapped off any of them.
private func cuboidNet(_ rng: inout Rng) -> [Mark] {
    let e = cuboidEdges(&rng)
    let edges = [e.0, e.1, e.2]
    let axis = rng.int(0, 2)
    let along = edges[axis]
    let rest = edges.indices.filter { $0 != axis }.map { edges[$0] }
    let (first, second) = (rest[0], rest[1])
    let widths = [first, second, first, second]
    let lefts = widths.indices.map { widths[0..<$0].reduce(0, +) }
    // The flap on a face of width `first` is the end face the other way round.
    func flap(_ index: Int) -> Double { index % 2 == 0 ? second : first }

    let above = rng.int(0, 3)
    let below = rng.int(0, 3)

    return widths.indices.map {
        seen(rectangle(lefts[$0], 0, widths[$0], along), true)
    } + [
        seen(rectangle(lefts[above], along, widths[above], flap(above)), true),
        seen(rectangle(lefts[below], -flap(below), widths[below], flap(below)), true),
    ]
}

/// Four triangles round a square, which is the only way this net is drawn — a
/// pyramid has nothing like a cube's eleven.
private func pyramidNet(_ rng: inout Rng) -> [Mark] {
    let slant = jitter(&rng, pyramidSlant.0, pyramidSlant.1)
    return [
        seen(rectangle(0, 0, 1, 1), true),
        seen([Point(0, 0), Point(1, 0), Point(0.5, -slant)], true),
        seen([Point(1, 0), Point(1, 1), Point(1 + slant, 0.5)], true),
        seen([Point(1, 1), Point(0, 1), Point(0.5, 1 + slant)], true),
        seen([Point(0, 1), Point(0, 0), Point(-slant, 0.5)], true),
    ]
}

/// Three rectangles in a row with a triangle flapped off two of them.
///
/// The triangle on a band face is placed by its own side lengths rather than
/// copied and turned: the face of width `sides[k]` folds up to the edge between
/// corners k and k+1, so the apex is the third corner. Getting that the wrong
/// way round draws a triangle the same size that does not fold.
private func prismNet(_ rng: inout Rng) -> [Mark] {
    let apex = jitter(&rng, prismApex.0, prismApex.1)
    let long = jitter(&rng, prismLength.0, prismLength.1)
    let leg = (0.5 * 0.5 + apex * apex).squareRoot()
    let sides = [1.0, leg, leg]
    let lefts = sides.indices.map { sides[0..<$0].reduce(0, +) }

    func cap(_ index: Int, _ up: Bool) -> Mark {
        let base = sides[index]
        let fromLeft = sides[(index + 2) % 3]
        let fromRight = sides[(index + 1) % 3]
        let x = (base * base + fromLeft * fromLeft - fromRight * fromRight) / (2 * base)
        let y = (Swift.max(fromLeft * fromLeft - x * x, 0)).squareRoot()
        let foot = up ? long : 0
        return seen([
            Point(lefts[index], foot),
            Point(lefts[index] + base, foot),
            Point(lefts[index] + x, up ? foot + y : -y),
        ], true)
    }

    let capUp = rng.int(0, 2)
    let capDown = rng.int(0, 2)
    return sides.indices.map {
        seen(rectangle(lefts[$0], 0, sides[$0], long), true)
    } + [cap(capUp, true), cap(capDown, false)]
}

/// The curved face unrolls into a rectangle exactly as wide as the rim is long,
/// and the two ends roll off it anywhere along their edges.
private func cylinderNet(_ rng: inout Rng) -> [Mark] {
    let width = 2 * Double.pi
    let height = jitter(&rng, cylinderNetHeight.0, cylinderNetHeight.1)
    return [
        seen(rectangle(0, 0, width, height), true),
        ring(Point(jitter(&rng, 1, width - 1), height + 1), 1, 1),
        ring(Point(jitter(&rng, 1, width - 1), -1), 1, 1),
    ]
}

/// A sector and a circle. The sector's angle is not free: its arc has to be
/// exactly as long as the base circle's rim, so it is the base's circumference
/// over the slant height.
private func coneNet(_ rng: inout Rng) -> [Mark] {
    let height = jitter(&rng, coneNetHeight.0, coneNetHeight.1)
    let slant = (1 + height * height).squareRoot()
    let sweep = 360 / slant
    let from = 90 - sweep / 2
    let along = 90 + jitter(&rng, -coneBaseAlong, coneBaseAlong) * sweep
    let centre = Point(
        (slant + 1) * Foundation.cos(degreesToRadians(along)),
        (slant + 1) * Foundation.sin(degreesToRadians(along))
    )

    return [
        seen([Point(0, 0)] + arcPoints(Point(0, 0), slant, slant, from, from + sweep), true),
        ring(centre, 1, 1),
    ]
}

private func netLines(_ name: String, _ rng: inout Rng) -> [Mark] {
    switch name {
    case "cube": return cubeNet(&rng)
    case "cuboid": return cuboidNet(&rng)
    case "square-pyramid": return pyramidNet(&rng)
    case "triangular-prism": return prismNet(&rng)
    case "cylinder": return cylinderNet(&rng)
    case "cone": return coneNet(&rng)
    // A sphere is never asked for a net: the view never jitters into one and a
    // pinned one becomes the object, which is the sphere itself.
    case "sphere": return sphereObject(&rng)
    default: return cubeNet(&rng)
    }
}

private func solidName(_ value: Value?) -> String? {
    guard let name = stringValue(value), solids.contains(name) else { return nil }
    return name
}

private func viewName(_ value: Value?) -> String? {
    guard let view = stringValue(value), solidViews.contains(view) else { return nil }
    return view
}
