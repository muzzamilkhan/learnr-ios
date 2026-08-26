import Foundation

/// Type and legibility constants, ported from `src/lib/figures/labels.ts`.
///
/// These are facts about how a figure is *rendered*, not about any one kind:
/// the size a label is drawn at, how much room a character takes, and how far
/// apart two strokes must be to read as two. Several kinds derive a limit from
/// them, and private copies would disagree the first time the report's density
/// was tuned — which is why the web app keeps them in one file and why this
/// port does too.
///
/// The measurements that matter are taken in a **parent's report row**, not on
/// the play screen: the report draws the same figure in a 64px square, so it is
/// the tighter of the two and the one a legibility budget has to clear.

/// The type size a figure is drawn at in a parent's report, in the fitted box's
/// own units. Every share below derives from this one number.
let reportLabelSize: Double = 16

/// The type size the same figure is drawn at on the play screen, where the box
/// is the child's whole question rather than a thumbnail.
let playLabelSize: Double = 7

/// The report row itself: a 64px square drawn at a stroke of 1.5 real pixels.
/// Both are exact rather than estimated.
let reportBoxPx: Double = 64
let reportStrokePx: Double = 1.5

/// How far apart two strokes have to be, in a report row's real pixels, to read
/// as two marks rather than one thick one: two stroke widths, so a whole stroke
/// of daylight stands between them.
let minMarkGapPx = reportStrokePx * 2

/// How many points a whole turn of a disc's rim is sampled at.
///
/// A multiple of four, and from a fixed zero rather than from any jittered
/// angle, so the sampled polygon has a vertex on each axis and its bounding box
/// is the true circle's whatever the rest of the drawing does. Seventy-two is 5
/// degrees a step, which at the report's ~28px radius bulges 0.03px inside the
/// true circle — a circle, not a polygon.
let discRimPoints = 72

/// What `fit` leaves a disc drawn at radius 1, in the box's own units.
let fittedDiscRadius = (figureBox - 2 * figurePadding) / 2

/// How much of a turn one real report-row pixel of rim is worth. Every angular
/// legibility limit is a number of stroke widths through it.
let degreesPerRimPx = 360 / (2 * Double.pi * (fittedDiscRadius / figureBox) * reportBoxPx)

/// The smallest sector that reads as a *region* rather than a thick line: half
/// a stroke belongs to each of the two boundary lines that bound it, and two
/// clear strokes of daylight between them is what makes the wedge visible —
/// three stroke widths in total.
let minSectorDegrees = degreesPerRimPx * reportStrokePx * 3

/// About what one character costs, as a share of the type size.
///
/// **Before tuning this — or `figurePadding`, or `figurePrecision` — know what
/// the three are holding up.** A kind that budgets for label ink solves for it
/// *exactly*, and exact leaves nothing over: in `bar`, at the tightest legal
/// shape, the binding label's ink lands 0.01 units inside the box with a
/// six-character axis, where one character is 9.28 units wide. The entire
/// clearance is a single rounding term, there to absorb `fit`'s rounding rather
/// than to leave room.
let charRatio = 0.58

/// Ink height for digits and capitals, as a share of the type size.
let inkRatio = 0.72

/// Daylight between two stacked lines of it, so a column of numbers reads as one.
let lineClearance = 1.15

/// `lineClearance`'s sideways twin: clear air between two labels laid out
/// *along* a rule, in characters — what a space between them would be worth.
/// Two labels closer than their own half-widths plus this are touching.
let labelDaylight = 0.5

/// What `fit` leaves a drawing inside the box once its padding is taken off
/// both sides. Derived rather than restated, so a change to either constant
/// cannot leave a kind measuring against a box that no longer exists.
let drawnSpan = figureBox - 2 * figurePadding

/// The three above as shares of a drawing's own span — which is what makes them
/// usable at all.
///
/// Lay a figure out in a frame whose larger side is exactly 1 and the fit's
/// scale is exactly `drawnSpan`, so a report-scale label is a *constant*
/// fraction of your own geometry and can be compared against your own gaps with
/// no knowledge of the fit. Measured any other way the conversion is circular.
let charShare = (reportLabelSize * charRatio) / drawnSpan
let inkShare = (reportLabelSize * inkRatio) / drawnSpan
/// Centre to centre, for two labels stacked one above the other.
let pitchShare = inkShare * lineClearance

/// How wide a label of this many characters is drawn in a report, in fitted
/// units.
func reportLabelWidth(_ characters: Double) -> Double {
    characters * reportLabelSize * charRatio
}
