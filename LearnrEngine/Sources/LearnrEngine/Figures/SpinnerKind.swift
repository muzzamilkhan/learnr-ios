import Foundation

/// The `spinner` kind, ported from `src/lib/figures/spinner-kind.ts`: a disc
/// cut into sectors, some shaded, with a hub at the centre.
///
/// The sector list is a **multiset**: how many parts each sector is worth is
/// the question, and where each one sits round the disc is the builder's to
/// vary — which is the one arrangement a chance question's answer survives.

private let radius: Double = 1

/// Where an unreadable `sectors` lands.
private let fallbackSectors: [Double] = [1, 1, 2]

/// A ceiling on how many sectors are drawn at all, for the never-throw
/// contract.
private let maxDrawnSectors = 80

struct SpinnerBuilder: FigureKindBuilder {
    let kind = "spinner"

    func build(_ spec: FigureSpec, _ scope: Scope, _ rng: inout Rng) -> [Mark] {
        let read = stringValue(readField(spec["sectors"], scope))
        let parsed = read.flatMap(parseParts)
        // A negative part has no sector to be drawn in, so it is drawn as
        // nothing. It is reported by validation; here it only has to be
        // drawable.
        let asked = (parsed ?? fallbackSectors)
            .prefix(maxDrawnSectors)
            .map { Swift.max($0, 0) }
        // Parts adding to nothing would divide the turn by zero, and
        // mid-session the contract is a drawing rather than a throw.
        let parts = asked.reduce(0, +) > 0 ? Array(asked) : fallbackSectors

        let readFills = stringValue(readField(spec["fills"], scope))
        let names = readFills.map(commaList)
        let inked = inkedSectors(parts.count, names)

        // Drawn whether or not it is used, so pinning `rotation` cannot change
        // how many values a spinner takes off the `Rng` the question's own
        // choices are shuffled with afterwards.
        let spun = jitter(&rng, 0, 360)
        let rotation = numberValue(readField(spec["rotation"], scope)) ?? spun

        let angles = sectorAngles(parts)
        // The pairs move together — the size and the appearance of one sector
        // are one thing, and separating them is what would change the answer.
        let arranged = arrangementOf(parts.count, &rng).map {
            (angle: angles[$0], inked: inked[$0])
        }

        // Shaded wedges first: a renderer draws marks in order, so the rim and
        // the boundary lines have to come after the fill they sit on.
        var marks: [Mark] = []
        var turn = rotation
        for sector in arranged {
            if sector.inked && sector.angle > 0 {
                marks.append(wedgePath(turn, sector.angle))
            }
            turn += sector.angle
        }

        marks.append(rimPath())

        turn = rotation
        for sector in arranged {
            marks.append(boundaryPath(turn))
            turn += sector.angle
        }

        // The hub the arrow would turn about — and the one mark that says this
        // is a spinner rather than a pie chart.
        marks.append(.dot(at: Point(0, 0)))

        return marks
    }
}

let spinnerBuilder = SpinnerBuilder()

/// The turn each sector is worth, in degrees.
///
/// `part * 360 / total`, never `part / total * 360`: the first is exact for the
/// thirds and sixths this content is full of, and the second is not.
func sectorAngles(_ parts: [Double]) -> [Double] {
    let total = parts.reduce(0, +)
    return parts.map { ($0 * 360) / total }
}

/// The comma-joined list, or nothing at all.
///
/// Strict: `Number('')` is 0 in JavaScript, so a list with a hole in it would
/// read as a sector the arrow can never land on rather than as the typo it is.
private func parseParts(_ text: String) -> [Double]? {
    let pieces = commaList(text)
    if pieces.contains(where: { $0.isEmpty }) { return nil }
    let parts = pieces.map { Double($0) }
    guard parts.allSatisfy({ $0?.isFinite == true }) else { return nil }
    return parts.map { $0! }
}

/// Which sectors are shaded, **in the order the author wrote them**, which is
/// the order the pairing is built in before anything is permuted.
///
/// Reading it off the drawn order instead would let the arrangement move which
/// appearance covers the most of the disc, and that is the answer.
///
/// The first group named takes the ink. With no names at all the sectors
/// alternate, which is only there so neighbouring parts can be told apart.
private func inkedSectors(_ count: Int, _ names: [String]?) -> [Bool] {
    guard let names, let first = names.first else {
        return (0..<count).map { $0 % 2 == 0 }
    }
    return (0..<count).map { index in
        index < names.count && names[index] == first
    }
}

/// Which slot round the disc each sector takes, as a permutation of the
/// authored order.
///
/// **One value off the shared `Rng`, expanded into a stream of its own.** A
/// Fisher-Yates shuffle wants one draw per sector, and a single `Rng` is
/// threaded through the figure into the question's own choice building — so a
/// figure whose appetite grew with its own data would reshuffle the distractors
/// of the very question it illustrates, differently for a three-part spinner
/// than for a four-part one. Seeding a private stream from a single draw keeps
/// a spinner at exactly two values whatever it is asked to draw.
private func arrangementOf(_ count: Int, _ rng: inout Rng) -> [Int] {
    // The seed is the JavaScript's template literal, so the private stream is
    // seeded with byte-identical text: `String(0.5)` is "0.5", which is what
    // `JSNumber.toString` reproduces.
    var spread = Rng(seed: "spinner-arrangement-\(JSNumber.toString(rng.next()))")
    var order = Array(0..<count)
    var index = order.count - 1
    while index > 0 {
        let swap = spread.int(0, index)
        order.swapAt(index, swap)
        index -= 1
    }
    return order
}

private func onRim(_ degrees: Double) -> Point {
    let radians = degrees * .pi / 180
    return Point(Foundation.cos(radians) * radius, Foundation.sin(radians) * radius)
}

/// The disc itself, and the reason the fit never moves: fixed sample angles,
/// four of them exactly on the axes, so the bounding box is the circle's
/// whatever the sectors inside are doing.
private func rimPath() -> Mark {
    .path(
        points: (0..<discRimPoints).map { onRim(Double($0) * 360 / Double(discRimPoints)) },
        closed: true, fill: false, dashed: false
    )
}

/// One sector boundary: the centre out to the rim.
private func boundaryPath(_ degrees: Double) -> Mark {
    .path(points: [Point(0, 0), onRim(degrees)], closed: false, fill: false, dashed: false)
}

/// A shaded sector: the centre, the arc between its two boundaries, and back.
private func wedgePath(_ from: Double, _ sweep: Double) -> Mark {
    let step = 360 / Double(discRimPoints)
    let samples = Swift.max(1, Int((sweep / step).rounded(.up)))
    var points: [Point] = [Point(0, 0)]
    for index in 0...samples {
        points.append(onRim(from + (sweep * Double(index)) / Double(samples)))
    }
    return .path(points: points, closed: true, fill: true, dashed: false)
}
