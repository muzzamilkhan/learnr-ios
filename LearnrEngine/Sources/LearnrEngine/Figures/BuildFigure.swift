import Foundation

/// Turning an authored `FigureSpec` into a drawing, ported from
/// `src/lib/figures/build.ts`.
///
/// **`buildFigure` never throws.** It runs mid-session with a child waiting, so
/// an unknown shape name or a 400-degree angle degrades into something
/// drawable, exactly as the choice count clamps a fifth option away rather than
/// refusing the question. Evaluation *does* fail — on an unbound variable or a
/// malformed expression — and every such failure reads as an absent field.
///
/// What each kind draws is the kind's own file. What lives here is what every
/// kind shares: the frame, and the fit.
///
/// The two halves of the coordinate system meet here. Shapes and angles are
/// built in the maths frame, y up, because that is the frame rotations and
/// symmetry axes are named in; `fit` scales the lot into the box and turns y
/// over on the way out, so a renderer needs no flip of its own. The scale is
/// **uniform**, which is not a detail: a separate x and y scale would fill the
/// box more neatly and turn every square into a rectangle doing it.

/// One kind of figure: how it is drawn.
///
/// The web app's module also carries `fields`, `issues` and `answerIssues` —
/// all three are authoring-time validation, which runs before content ships and
/// is deliberately not ported. What a device needs is `build`.
protocol FigureKindBuilder: Sendable {
    var kind: String { get }
    /// The marks this kind draws, in the **maths frame**: x right, y *up*,
    /// degrees anticlockwise from east, at whatever scale suits the shape.
    /// `fit` turns y over and scales afterwards, so that flip stays at the one
    /// boundary rather than being remembered by eleven kinds.
    ///
    /// Like `buildFigure` itself, it never throws: a field it cannot read
    /// degrades into something drawable.
    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark]
}

/// Every kind, keyed by name.
///
/// A lookup by a string off authored content, so an unknown key comes back
/// empty rather than finding something inherited — the reason the web app uses
/// a `Map` and the expression language uses null-prototype tables.
private let figureKindBuilders: [String: FigureKindBuilder] = {
    var map: [String: FigureKindBuilder] = [:]
    for builder in allFigureKindBuilders {
        map[builder.kind] = builder
    }
    return map
}()

func figureKindBuilder(_ kind: String) -> FigureKindBuilder? {
    figureKindBuilders[kind]
}

/// Build a figure from a spec and the scope its question was bound in.
public func buildFigure(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> Figure {
    // An unrecognised kind lands on the polygon path and, with no shape it
    // knows, on an equilateral triangle — the same fallback an unknown shape
    // name gets, because "something drawable" is the whole contract here.
    let builder = figureKindBuilder(spec.kind) ?? polygonBuilder
    return fit(builder.build(spec, scope, &rng))
}

/// Scale and centre the marks into the box, turn y over, and round.
///
/// Rounding is where `-0` has to be swept up: the point of rounding is that two
/// figures can be compared as strings, and `-0` and `0` are the same coordinate
/// written two ways.
func fit(_ marks: [Mark]) -> Figure {
    guard let bounds = boundsOf(marks) else {
        return Figure(width: figureBox, height: figureBox, marks: [])
    }

    let span = Swift.max(bounds.maxX - bounds.minX, bounds.maxY - bounds.minY)
    let scale = span > 0 ? (figureBox - 2 * figurePadding) / span : 1
    let midX = (bounds.minX + bounds.maxX) / 2
    let midY = (bounds.minY + bounds.maxY) / 2

    func place(_ p: Point) -> Point {
        Point(
            round(clamp(figureBox / 2 + (p.x - midX) * scale, 0, figureBox)),
            // Minus, because the figure leaves here in screen coordinates: the
            // one flip lives at the boundary rather than in every shape above.
            round(clamp(figureBox / 2 - (p.y - midY) * scale, 0, figureBox))
        )
    }

    return Figure(
        width: figureBox,
        height: figureBox,
        marks: marks.map { mark in
            switch mark {
            case .arc(let at, let radius, let from, let to):
                return .arc(at: place(at), radius: round(radius * scale),
                            from: round(from), to: round(to))
            case .path(let points, let closed, let fill, let dashed):
                return .path(points: points.map(place), closed: closed,
                             fill: fill, dashed: dashed)
            case .dot(let at):
                return .dot(at: place(at))
            case .label(let at, let text):
                return .label(at: place(at), text: text)
            }
        }
    )
}

/// Round to `figurePrecision`, sweeping `-0` back to `0`.
///
/// `JSNumber.round`, not Swift's `rounded()`: JavaScript breaks ties toward
/// +Infinity, and a coordinate landing on an exact half is far from
/// hypothetical here — the geometry is full of halves and quarters of a box
/// whose side is 100.
func round(_ value: Double) -> Double {
    let factor = Foundation.pow(10.0, Double(figurePrecision))
    let rounded = JSNumber.round(value * factor) / factor
    // `+ 0` in the JavaScript, for the same purpose: turn a -0 back into a 0 so
    // two figures that are the same drawing are also the same string.
    return rounded == 0 ? 0 : rounded
}

private struct Bounds {
    var minX, minY, maxX, maxY: Double
}

/// The box everything drawn occupies, or nothing at all if there is nothing to
/// draw.
private func boundsOf(_ marks: [Mark]) -> Bounds? {
    var b = Bounds(minX: .infinity, minY: .infinity, maxX: -.infinity, maxY: -.infinity)

    func include(_ p: Point, _ radius: Double = 0) {
        b.minX = Swift.min(b.minX, p.x - radius)
        b.minY = Swift.min(b.minY, p.y - radius)
        b.maxX = Swift.max(b.maxX, p.x + radius)
        b.maxY = Swift.max(b.maxY, p.y + radius)
    }

    for mark in marks {
        switch mark {
        // An arc is bounded by its whole circle rather than by its sweep. It
        // gives away a little room on a quarter turn, which costs a slightly
        // smaller drawing; measuring the sweep exactly would risk clipping the
        // one mark whose extent is not written down in its own points.
        case .arc(let at, let radius, _, _): include(at, radius)
        case .path(let points, _, _, _): points.forEach { include($0) }
        case .dot(let at): include(at)
        case .label(let at, _): include(at)
        }
    }

    guard b.minX.isFinite, b.minY.isFinite, b.maxX.isFinite, b.maxY.isFinite else {
        return nil
    }
    return b
}
