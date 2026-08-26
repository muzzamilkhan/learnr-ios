import SwiftUI
import LearnrEngine

/// A figure the child has to *look* at: the picture is the question and the
/// prompt is its caption.
///
/// The native counterpart of `src/components/diagram.tsx`, and the dumb half in
/// the same way: marks to shapes, no geometry and no decisions. `buildFigure`
/// already made that true of the data — coordinates arrive rounded, y already
/// increasing downward, in a square box of `figureBox` units.
///
/// **Stroke width is in points, not box units.** The web renderer gets this from
/// `vectorEffect="non-scaling-stroke"`, which pins a line's weight in real
/// pixels however the viewBox is scaled; `Canvas` has no equivalent, so the
/// scaling is undone explicitly — the transform scales coordinates and every
/// stroke width is divided back out by the same factor. The effect is the one
/// the web gets for free: a line reads at the same weight whether the figure is
/// filling the play screen or sitting in a 64pt thumbnail.
struct DiagramView: View {
    let figure: Figure

    /// Points, the way `strokeWidth` is real pixels on the web. Roughly 3-4 on
    /// the play screen, 1.5-2 in a small thumbnail — the caller's call, because
    /// it is the caller that knows which of the two very differently sized
    /// places this is.
    var strokeWidth: CGFloat = 3.5

    /// Box units, not points — the same quantity as the web's `labelSize`, and
    /// unlike `strokeWidth` it scales with the figure. Roughly 7 on the play
    /// screen, roughly 16 in a report row.
    ///
    /// It cannot be derived from `strokeWidth`: that is a line weight chosen for
    /// visual emphasis, and treating it as a proxy for box size means a thicker
    /// line silently resizes every label.
    var labelSize: CGFloat = 7

    var body: some View {
        Canvas { context, size in
            // `preserveAspectRatio="xMidYMid meet"`: uniform scale, centred.
            let scale = min(size.width / figure.width, size.height / figure.height)
            guard scale > 0, scale.isFinite else { return }

            let drawn = CGSize(width: figure.width * scale, height: figure.height * scale)
            context.translateBy(
                x: (size.width - drawn.width) / 2,
                y: (size.height - drawn.height) / 2)
            context.scaleBy(x: scale, y: scale)

            // Undoing the scale is what stands in for `non-scaling-stroke`.
            let stroke = strokeWidth / scale

            for mark in figure.marks {
                draw(mark, in: &context, stroke: stroke)
            }
        }
        .accessibilityElement()
        // Deliberately not a description of the picture. "A shape with three
        // sides" *is* the answer to half of what this draws, so the label says
        // only that a diagram is there and narration reads the prompt.
        .accessibilityLabel("Diagram for this question")
    }

    private func draw(_ mark: Mark, in context: inout GraphicsContext, stroke: CGFloat) {
        switch mark {
        case .path(let points, let closed, let fill, let dashed):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            if closed { path.closeSubpath() }

            if fill {
                context.fill(path, with: .color(Palette.brandSoft))
            }
            context.stroke(
                path,
                with: .color(Palette.ink),
                style: StrokeStyle(
                    lineWidth: stroke,
                    lineCap: .round,
                    lineJoin: .round,
                    // Proportioned to the line weight rather than a fixed
                    // length, so a figure does not go from a handful of dashes
                    // at one size to a wall of them at another.
                    dash: dashed ? [stroke * 2.5, stroke * 1.5] : []))

        case .arc(let at, let radius, let from, let to):
            context.stroke(
                arcPath(at: at, radius: radius, from: from, to: to),
                with: .color(Palette.ink),
                style: StrokeStyle(lineWidth: stroke, lineCap: .round))

        case .dot(let at):
            // A dot noticeably heavier than the line it marks, so "the arms
            // alone do not say which end is the corner" still holds at a glance.
            let diameter = stroke * 3
            let rect = CGRect(
                x: at.x - diameter / 2, y: at.y - diameter / 2,
                width: diameter, height: diameter)
            context.fill(Path(ellipseIn: rect), with: .color(Palette.ink))

        case .label(let at, let text):
            var resolved = context.resolve(
                Text(text)
                    .font(.system(size: labelSize, weight: .medium, design: .rounded)))
            resolved.shading = .color(Palette.ink)
            // `textAnchor="middle" dominantBaseline="middle"` — centred on the
            // point in both axes, which is what `.center` anchoring gives.
            context.draw(resolved, at: CGPoint(x: at.x, y: at.y), anchor: .center)
        }
    }

    /// One `arc` mark as a path.
    ///
    /// This is the one place the figure's two coordinate frames meet, and
    /// getting it backwards is the easiest mistake here. `at` is already in
    /// screen coordinates — `fit` put it there, y increasing downward — but
    /// `from` and `to` never left the maths frame the figure was authored in:
    /// degrees, anticlockwise-positive, 0 = east. A point on the sweep is
    /// `(cx + r·cos θ, cy − r·sin θ)`, **minus** on the y term, because turning
    /// y downward without turning the angle around would spin every sweep the
    /// wrong way.
    ///
    /// SwiftUI's `addArc` measures clockwise in its own y-down space, so the
    /// negated angles are handed straight to it and `clockwise` is read off the
    /// sign of the delta: walking from `from` to `to` in the direction of
    /// increasing degrees is anticlockwise in the maths frame, which after the
    /// flip is clockwise in this one.
    func arcPath(at: Point, radius: Double, from: Double, to: Double) -> Path {
        var path = Path()
        path.addArc(
            center: CGPoint(x: at.x, y: at.y),
            radius: radius,
            startAngle: .degrees(-from),
            endAngle: .degrees(-to),
            clockwise: to >= from)
        return path
    }
}

// MARK: - Previews

/// Every shipped kind, drawn from the real builders. The fastest way to see
/// that a renderer change did not quietly break one of eleven pictures.
#Preview("Every figure kind") {
    let kinds = figureKinds
    return ScrollView {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 16)], spacing: 16) {
            ForEach(kinds, id: \.self) { kind in
                VStack(spacing: 6) {
                    DiagramView(figure: {
                        var rng = Rng(seed: "preview:\(kind)")
                        return buildFigure(FigureSpec(kind: kind), [:], &rng)
                    }())
                    .frame(height: 150)
                    Text(kind)
                        .font(.caption)
                        .foregroundStyle(Palette.inkSoft)
                }
                .padding(8)
                .background(Palette.card, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding()
    }
    .background(Palette.paper)
}
