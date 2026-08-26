import Testing
import SwiftUI
import LearnrEngine
@testable import LearnrApp

/// `arcPath` is the one piece of the renderer that is arithmetic rather than
/// markup, and it is where the figure's two coordinate frames meet: an arc's
/// centre `at` is in screen coordinates (y down, where `fit` left it) while
/// `from`/`to` are maths-frame degrees (anticlockwise, 0 = east).
///
/// The web has a test for exactly this, for exactly this reason, and these are
/// its cases — the same worked example and the same bearings. **The geometry is
/// asserted, never the path's internals**: what matters is where the endpoints
/// land and which way round the arc walks between them.
struct DiagramTests {

    static let view = DiagramView(figure: Figure(width: 100, height: 100, marks: []))

    /// How far a point sits from the arc's centre.
    static func radius(from centre: Point, to point: CGPoint) -> Double {
        hypot(point.x - centre.x, point.y - centre.y)
    }

    /// The maths-frame bearing of a point about the centre — the inverse of
    /// what the renderer does, so a wrong sign on the y term shows up as a
    /// reflected angle rather than as nothing at all. Normalised into 0–360.
    static func bearing(from centre: Point, to point: CGPoint) -> Double {
        let degrees = atan2(centre.y - point.y, point.x - centre.x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Where the arc starts and ends, and how far round it went.
    ///
    /// `currentPoint` is the honest source for the endpoint: `Path.forEach`
    /// reports a flattened arc as Bézier `.curve` elements, and the `to` of the
    /// last one is a *control* point, not where the pen finished. Reading that
    /// instead is what made the first version of this test fail against a
    /// renderer that was already correct.
    ///
    /// The element count stands in for the sweep's extent. A quarter turn
    /// flattens to one curve and a three-quarter turn to three, so counting
    /// them distinguishes the short way round from the long way — which is the
    /// property the `clockwise` flag actually decides, and the one the SVG
    /// large-arc flag pins on the web.
    static func trace(_ path: Path) -> (start: CGPoint, end: CGPoint, curves: Int)? {
        var start: CGPoint?
        var curves = 0

        path.forEach { element in
            switch element {
            case .move(let to): if start == nil { start = to }
            case .line: curves += 1
            case .quadCurve, .curve: curves += 1
            case .closeSubpath: break
            }
        }

        guard let start, let end = path.currentPoint else { return nil }
        return (start, end, curves)
    }

    static func arc(at centre: Point, radius: Double, from: Double, to: Double)
        -> (start: CGPoint, end: CGPoint, curves: Int) {
        let path = view.arcPath(at: centre, radius: radius, from: from, to: to)
        guard let traced = trace(path) else {
            Issue.record("the arc drew no points")
            return (.zero, .zero, 0)
        }
        return traced
    }

    @Test("starts on one arm and ends on the other, for the angle buildFigure draws")
    func workedExample() throws {
        // The same worked example the web test uses: 90 degrees, rotation
        // pinned to 0, both arms 1. `buildFigure` puts the vertex at
        // [26.31, 73.69], the horizontal arm running right and the vertical one
        // running up.
        let spec = FigureSpec(
            kind: "angle", fields: ["degrees": "90", "rotation": "0", "armLength": "1"])
        var rng = Rng(seed: "arc-path-worked-example")
        let figure = buildFigure(spec, [:], &rng)

        guard case .path(let points, _, _, _)? = figure.marks.first(where: {
            if case .path = $0 { return true } else { return false }
        }) else {
            Issue.record("expected arms")
            return
        }
        guard case .arc(let at, let radius, let from, let to)? = figure.marks.first(where: {
            if case .arc = $0 { return true } else { return false }
        }) else {
            Issue.record("expected an arc")
            return
        }

        // The figure the Swift engine builds is the one the TypeScript builds —
        // this is the same assertion the web test opens with, and it is what
        // makes the rest of this a test of the renderer rather than of the
        // builder.
        #expect(points == [Point(94, 73.69), Point(26.31, 73.69), Point(26.31, 6)])
        #expect(at == Point(26.31, 73.69))
        #expect(radius == 20.31)
        #expect(from == 0)
        #expect(to == 90)

        let (start, end, curves) = Self.arc(at: at, radius: radius, from: from, to: to)

        // On the horizontal arm: same y as the vertex, further right, at the
        // arc's own radius. This is the assertion the minus on the y term is
        // load bearing for — drop it and the sweep leaves from below the vertex.
        #expect(abs(start.y - at.y) < 0.001)
        #expect(start.x > at.x)
        #expect(abs(Self.radius(from: at, to: start) - radius) < 0.001)

        // On the vertical arm: same x as the vertex, above it — which in screen
        // coordinates means a *smaller* y.
        #expect(abs(end.x - at.x) < 0.001)
        #expect(end.y < at.y)
        #expect(abs(Self.radius(from: at, to: end) - radius) < 0.001)

        // A quarter turn is the short way round: one flattened curve. This is
        // what the `clockwise` flag decides, and the assertion that would catch
        // it being inverted - both endpoints stay put either way, and only the
        // path between them changes.
        #expect(curves == 1)
    }

    @Test("puts both endpoints on the bearings it was given")
    func bearingsHold() {
        let centre = Point(40, 60)
        let (start, end, curves) = Self.arc(at: centre, radius: 12, from: 20, to: 110)

        #expect(abs(Self.bearing(from: centre, to: start) - 20) < 0.001)
        #expect(abs(Self.bearing(from: centre, to: end) - 110) < 0.001)
        #expect(abs(Self.radius(from: centre, to: start) - 12) < 0.001)
        #expect(abs(Self.radius(from: centre, to: end) - 12) < 0.001)
        // 90 degrees: the short way.
        #expect(curves == 1)
    }

    @Test("a minor angle keeps both endpoints where it was told")
    func minorAngle() {
        let centre = Point(50, 50)
        let (start, end, curves) = Self.arc(at: centre, radius: 15, from: 30, to: 75)

        #expect(abs(Self.bearing(from: centre, to: start) - 30) < 0.001)
        #expect(abs(Self.bearing(from: centre, to: end) - 75) < 0.001)
        // 45 degrees, well under a half turn.
        #expect(curves == 1)
    }

    @Test("a reflex angle sweeps the long way round")
    func reflexAngle() {
        let centre = Point(50, 50)
        let (start, end, curves) = Self.arc(at: centre, radius: 15, from: 0, to: 300)

        #expect(abs(Self.bearing(from: centre, to: start) - 0) < 0.001)
        #expect(abs(Self.bearing(from: centre, to: end) - 300) < 0.001)
        // 300 degrees is the long way round - the case SVG sets its large-arc
        // flag for, and the one an inverted sweep would draw as 60 degrees.
        #expect(curves > 1)
    }

    @Test("crosses 180 degrees without either endpoint moving")
    func crossesDueWest() {
        // A sweep straddling due west, which is where a frame flip done half
        // way would show: 150 and 210 are mirror images about the horizontal,
        // so getting the sign wrong swaps them and the arc still looks
        // plausible.
        let centre = Point(50, 50)
        let (start, end, curves) = Self.arc(at: centre, radius: 20, from: 150, to: 210)

        #expect(abs(Self.bearing(from: centre, to: start) - 150) < 0.001)
        #expect(abs(Self.bearing(from: centre, to: end) - 210) < 0.001)
        // Above the centre going in, below it coming out — screen coordinates,
        // so "above" is the smaller y.
        #expect(start.y < centre.y)
        #expect(end.y > centre.y)
        // 60 degrees: still the short way, despite straddling due west.
        #expect(curves == 1)
    }

    @Test("stays put for a near-full turn")
    func nearFullTurn() {
        let centre = Point(50, 50)
        let (start, end, curves) = Self.arc(at: centre, radius: 18, from: 1, to: 359)

        #expect(abs(Self.bearing(from: centre, to: start) - 1) < 0.001)
        #expect(abs(Self.bearing(from: centre, to: end) - 359) < 0.001)
        // 358 degrees: as long as a sweep gets.
        #expect(curves > 1)
    }

    @Test("walks the other way when the arc runs backwards")
    func backwards() {
        // Nothing the angle builder produces today has `to` below `from`, but
        // the sign is read rather than assumed, and a reader deserves to see
        // which way that falls before relying on it.
        let centre = Point(50, 50)
        let (start, end, curves) = Self.arc(at: centre, radius: 15, from: 90, to: 30)

        #expect(abs(Self.bearing(from: centre, to: start) - 90) < 0.001)
        #expect(abs(Self.bearing(from: centre, to: end) - 30) < 0.001)
        // 60 degrees walked backwards is still 60 degrees of arc.
        #expect(curves == 1)
    }

    /// Every shipped figure kind, drawn once, to prove the renderer takes what
    /// the builders produce without trapping on any of it.
    @Test("every figure kind renders without trapping")
    func everyKindDraws() {
        for kind in figureKinds {
            var rng = Rng(seed: "render:\(kind)")
            let figure = buildFigure(FigureSpec(kind: kind), [:], &rng)
            #expect(figure.width > 0, "\(kind): width")
            #expect(!figure.marks.isEmpty, "\(kind): marks")

            // Walk every mark the way the renderer does, so a mark shape it
            // cannot build shows up here rather than on a child's screen.
            for mark in figure.marks {
                if case .arc(let at, let radius, let from, let to) = mark {
                    let path = Self.view.arcPath(at: at, radius: radius, from: from, to: to)
                    #expect(!path.isEmpty, "\(kind): an arc drew nothing")
                }
            }
        }
    }
}
