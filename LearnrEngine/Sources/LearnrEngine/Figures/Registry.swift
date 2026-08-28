import Foundation

/// The registrations, listed here rather than run as a side effect inside each
/// kind's own file — the same choice `src/lib/figures/registry.ts` makes, and
/// for a reason that survives the port: a list in one file is one line per new
/// kind, in the place a reader looks to find out what kinds exist.
///
/// Kinds not yet ported are simply absent, and an absent kind falls back to the
/// polygon builder in `buildFigure`. That fallback is the web app's behaviour
/// for an unknown kind, so a partially ported registry degrades exactly as
/// authored content with a typo would, rather than in some new way.
let allFigureKindBuilders: [FigureKindBuilder] = [
    polygonBuilder,
    angleBuilder,
    arrayBuilder,
    spinnerBuilder,
    clockBuilder,
    fractionShapeBuilder,
    pictographBuilder,
    barBuilder,
    solidBuilder,
    gridBuilder,
    numberLineBuilder,
    timelineBuilder,
]
